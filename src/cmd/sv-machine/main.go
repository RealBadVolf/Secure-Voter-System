package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/google/uuid"
)

var (
	dbReg  *sql.DB
	dbElec *sql.DB
	dbVote *sql.DB
)

func main() {
	var err error
	dbReg, err = connectDB("SV_DB_REG")
	if err != nil {
		log.Fatalf("Registration DB: %v", err)
	}
	dbElec, err = connectDB("SV_DB_ELEC")
	if err != nil {
		log.Fatalf("Election DB: %v", err)
	}
	dbVote, err = connectDB("SV_DB_VOTES")
	if err != nil {
		log.Fatalf("Votes DB: %v", err)
	}
	log.Println("All databases connected")

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleUI)
	mux.HandleFunc("/api/health", handleHealth)
	mux.HandleFunc("/api/voters/search", handleVoterSearch)
	mux.HandleFunc("/api/voters/get", handleVoterGet)
	mux.HandleFunc("/api/voters/authenticate", handleAuthenticate)
	mux.HandleFunc("/api/ballot", handleGetBallot)
	mux.HandleFunc("/api/vote/cast", handleCastVote)
	mux.HandleFunc("/api/votes/recent", handleRecentVotes)
	mux.HandleFunc("/api/stats", handleStats)

	addr := os.Getenv("SV_SIM_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	log.Printf("SecureVote Machine Simulator on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func connectDB(prefix string) (*sql.DB, error) {
	host := envOr(prefix+"_HOST", "localhost")
	port := envOr(prefix+"_PORT", "3306")
	user := envOr(prefix+"_USER", "root")
	pass := envOr(prefix+"_PASS", "")
	name := envOr(prefix+"_NAME", "test")
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&multiStatements=true",
		user, pass, host, port, name)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(10)
	for i := 0; i < 30; i++ {
		if err = db.Ping(); err == nil {
			return db, nil
		}
		time.Sleep(time.Second)
	}
	return nil, fmt.Errorf("timeout: %v", err)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func jsonResp(w http.ResponseWriter, code int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(data)
}

func hashStr(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	jsonResp(w, 200, map[string]string{"status": "healthy"})
}

type VoterRow struct {
	ID     int64  `json:"voter_id"`
	UUID   string `json:"uuid"`
	First  string `json:"first_name"`
	Middle string `json:"middle_name"`
	Last   string `json:"last_name"`
	DOB    string `json:"dob"`
	Prec   string `json:"precinct"`
	Status string `json:"status"`
	Reg    string `json:"reg_number"`
	Voted  bool   `json:"has_voted"`
}

func handleVoterSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if q == "" {
		jsonResp(w, 200, []VoterRow{})
		return
	}

	parts := strings.Split(q, ",")
	var conditions []string
	var args []interface{}

	if len(parts) >= 2 {
		// Comma mode: Last, First[, Middle]
		last := strings.TrimSpace(parts[0])
		if last != "" {
			conditions = append(conditions, "legal_last_name LIKE ?")
			args = append(args, last+"%")
		}
		first := strings.TrimSpace(parts[1])
		if first != "" {
			conditions = append(conditions, "legal_first_name LIKE ?")
			args = append(args, first+"%")
		}
		if len(parts) >= 3 {
			middle := strings.TrimSpace(parts[2])
			if middle != "" {
				conditions = append(conditions, "COALESCE(legal_middle_name,'') LIKE ?")
				args = append(args, middle+"%")
			}
		}
	} else {
		// Single term: last name only, or exact voter ID / reg number
		last := strings.TrimSpace(parts[0])
		conditions = append(conditions, "(legal_last_name LIKE ? OR registration_number LIKE ? OR CAST(voter_id AS CHAR) = ?)")
		args = append(args, last+"%", "%"+last+"%", last)
	}

	if len(conditions) == 0 {
		jsonResp(w, 200, []VoterRow{})
		return
	}

	query := `SELECT voter_id, voter_uuid, legal_first_name, COALESCE(legal_middle_name,''),
		legal_last_name, date_of_birth, precinct_id, registration_status, registration_number
		FROM voters WHERE registration_status='ACTIVE' AND ` +
		strings.Join(conditions, " AND ") + " LIMIT 50"

	rows, err := dbReg.Query(query, args...)
	if err != nil {
		jsonResp(w, 500, map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()

	var out []VoterRow
	for rows.Next() {
		var v VoterRow
		var dob time.Time
		rows.Scan(&v.ID, &v.UUID, &v.First, &v.Middle, &v.Last, &dob, &v.Prec, &v.Status, &v.Reg)
		v.DOB = dob.Format("2006-01-02")
		var c int
		dbReg.QueryRow("SELECT COUNT(*) FROM voter_token_issuance WHERE voter_id=? AND election_id='general-2026-11-03'", v.ID).Scan(&c)
		v.Voted = c > 0
		out = append(out, v)
	}
	if out == nil {
		out = []VoterRow{}
	}
	jsonResp(w, 200, out)
}

func handleVoterGet(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		jsonResp(w, 400, map[string]string{"error": "id required"})
		return
	}
	var v VoterRow
	var dob time.Time
	err := dbReg.QueryRow(`SELECT voter_id, voter_uuid, legal_first_name,
		COALESCE(legal_middle_name,''), legal_last_name, date_of_birth,
		precinct_id, registration_status, registration_number
		FROM voters WHERE voter_id = ?`, id).Scan(
		&v.ID, &v.UUID, &v.First, &v.Middle, &v.Last, &dob, &v.Prec, &v.Status, &v.Reg)
	if err != nil {
		jsonResp(w, 404, map[string]string{"error": "not found"})
		return
	}
	v.DOB = dob.Format("2006-01-02")
	jsonResp(w, 200, v)
}

func handleAuthenticate(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jsonResp(w, 405, map[string]string{"error": "POST required"})
		return
	}
	var req struct {
		VoterID int64 `json:"voter_id"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	var first, last, precinct, status string
	err := dbReg.QueryRow(
		"SELECT legal_first_name, legal_last_name, precinct_id, registration_status FROM voters WHERE voter_id=?",
		req.VoterID).Scan(&first, &last, &precinct, &status)
	if err != nil {
		jsonResp(w, 404, map[string]string{"success": "false", "message": "Not found"})
		return
	}
	if status != "ACTIVE" {
		jsonResp(w, 403, map[string]string{"success": "false", "message": "Status: " + status})
		return
	}

	var tc int
	dbReg.QueryRow("SELECT COUNT(*) FROM voter_token_issuance WHERE voter_id=? AND election_id='general-2026-11-03'", req.VoterID).Scan(&tc)
	if tc > 0 {
		jsonResp(w, 403, map[string]string{"success": "false", "message": "Already voted"})
		return
	}

	confA := 0.90 + rand.Float64()*0.10
	confB := 0.88 + rand.Float64()*0.12
	tb := make([]byte, 32)
	rand.Read(tb)
	tokenHash := hashStr(string(tb))
	blindedHash := hashStr("blinded-" + tokenHash)

	_, err = dbReg.Exec(`INSERT INTO voter_token_issuance
		(voter_id, election_id, precinct_id, blinded_token_hash, issued_at,
		 issuing_machine_id, auth_method, biometric_confidence_a, biometric_confidence_b,
		 row_integrity_hash)
		VALUES (?,'general-2026-11-03',?,?,NOW(),'SIM-0001','BIOMETRIC_AUTO',?,?,
		 SHA2(CONCAT(?,?,?),256))`,
		req.VoterID, precinct, blindedHash, confA, confB, req.VoterID, precinct, blindedHash)
	if err != nil {
		jsonResp(w, 500, map[string]string{"success": "false", "message": err.Error()})
		return
	}

	jsonResp(w, 200, map[string]interface{}{
		"success": true, "message": "Identity verified",
		"voter_name": first + " " + last, "precinct": precinct,
		"token_hash": tokenHash, "confidence_a": confA, "confidence_b": confB,
	})
}

func handleGetBallot(w http.ResponseWriter, r *http.Request) {
	type C struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
		Party string `json:"party"`
		Hash string `json:"hash"`
	}
	type R struct {
		RaceID  string `json:"race_id"`
		Title   string `json:"title"`
		Rule    string `json:"voting_rule"`
		WriteIn bool   `json:"write_in_allowed"`
		Order   int    `json:"display_order"`
		Type    string `json:"type"`
		Summary string `json:"summary,omitempty"`
		Cands   []C    `json:"candidates"`
	}
	var races []R

	rows, _ := dbElec.Query("SELECT race_id, title, voting_rule, write_in_allowed, display_order FROM races WHERE election_id='general-2026-11-03' ORDER BY display_order")
	if rows != nil {
		for rows.Next() {
			var rc R
			rows.Scan(&rc.RaceID, &rc.Title, &rc.Rule, &rc.WriteIn, &rc.Order)
			rc.Type = "RACE"
			cr, _ := dbElec.Query("SELECT candidate_id, display_name, COALESCE(party,''), candidate_hash FROM candidates WHERE race_id=? AND is_qualified=1 ORDER BY display_order", rc.RaceID)
			if cr != nil {
				for cr.Next() {
					var c C
					cr.Scan(&c.ID, &c.Name, &c.Party, &c.Hash)
					rc.Cands = append(rc.Cands, c)
				}
				cr.Close()
			}
			races = append(races, rc)
		}
		rows.Close()
	}

	mr, _ := dbElec.Query("SELECT measure_id, title, summary, display_order FROM ballot_measures WHERE election_id='general-2026-11-03' ORDER BY display_order")
	if mr != nil {
		for mr.Next() {
			var rc R
			mr.Scan(&rc.RaceID, &rc.Title, &rc.Summary, &rc.Order)
			rc.Type = "MEASURE"
			rc.Rule = "CHOOSE_ONE"
			or, _ := dbElec.Query("SELECT option_id, display_name, '', option_hash FROM measure_options WHERE measure_id=? ORDER BY display_order", rc.RaceID)
			if or != nil {
				for or.Next() {
					var c C
					or.Scan(&c.ID, &c.Name, &c.Party, &c.Hash)
					rc.Cands = append(rc.Cands, c)
				}
				or.Close()
			}
			races = append(races, rc)
		}
		mr.Close()
	}

	if races == nil {
		races = []R{}
	}
	jsonResp(w, 200, races)
}

func handleCastVote(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jsonResp(w, 405, map[string]string{"error": "POST required"})
		return
	}
	var req struct {
		Token    string            `json:"token_hash"`
		Precinct string            `json:"precinct"`
		Sel      map[string]string `json:"selections"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Token == "" {
		jsonResp(w, 400, map[string]string{"success": "false", "message": "No token"})
		return
	}

	vid := uuid.New().String()
	nonce := hashStr(uuid.New().String())
	now := time.Now()

	var sp []string
	for k, v := range req.Sel {
		sp = append(sp, k+":"+v)
	}
	leaf := hashStr(fmt.Sprintf("%s|%s|%s|%s|%s|%s",
		vid, "general-2026-11-03", req.Precinct, req.Token, nonce, strings.Join(sp, ",")))
	ri := hashStr(fmt.Sprintf("%s|%s|%s|%s|SIM-0001|VALID|%s",
		vid, "general-2026-11-03", req.Precinct, req.Token, nonce))

	_, err := dbVote.Exec(`INSERT INTO vote_casts
		(vote_record_id, election_id, precinct_id, voter_token, voter_token_hash,
		 voter_token_signature, biometric_hash, machine_id, cast_timestamp,
		 session_start, session_end, nonce, status, vvpat_confirmed,
		 merkle_leaf_hash, row_integrity_hash)
		VALUES (?,'general-2026-11-03',?,UNHEX(SHA2(?,256)),?,UNHEX(SHA2(?,256)),
		 SHA2(?,256),'SIM-0001',?,DATE_SUB(?,INTERVAL 120 SECOND),?,?,'VALID',1,?,?)`,
		vid, req.Precinct, req.Token, req.Token, req.Token, req.Token,
		now, now, now, nonce, leaf, ri)
	if err != nil {
		jsonResp(w, 500, map[string]string{"success": "false", "message": err.Error()})
		return
	}

	for rID, cHash := range req.Sel {
		si := hashStr(fmt.Sprintf("%s|%s|%s", vid, rID, cHash))
		dbVote.Exec(`INSERT INTO vote_selections
			(vote_cast_id, vote_record_id, race_id, selection_hash, row_integrity_hash)
			VALUES ((SELECT vote_cast_id FROM vote_casts WHERE vote_record_id=?),?,?,?,?)`,
			vid, vid, rID, cHash, si)
	}

	jsonResp(w, 200, map[string]interface{}{
		"success": true, "vote_record_id": vid,
		"merkle_leaf": leaf, "message": "Vote recorded",
	})
}

func handleRecentVotes(w http.ResponseWriter, r *http.Request) {
	rows, _ := dbVote.Query(`SELECT vote_record_id, precinct_id, cast_timestamp, status,
		COALESCE(merkle_leaf_hash,'') FROM vote_casts
		WHERE election_id='general-2026-11-03' ORDER BY cast_timestamp DESC LIMIT 20`)
	if rows == nil {
		jsonResp(w, 200, []struct{}{})
		return
	}
	defer rows.Close()
	type VR struct {
		ID string `json:"record_id"`
		P  string `json:"precinct"`
		T  string `json:"cast_at"`
		S  string `json:"status"`
		M  string `json:"merkle_leaf"`
	}
	var out []VR
	for rows.Next() {
		var v VR
		var t time.Time
		rows.Scan(&v.ID, &v.P, &t, &v.S, &v.M)
		v.T = t.Format("15:04:05")
		out = append(out, v)
	}
	if out == nil {
		out = []VR{}
	}
	jsonResp(w, 200, out)
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	s := map[string]interface{}{}
	var tv, ti, vc int
	dbReg.QueryRow("SELECT COUNT(*) FROM voters WHERE registration_status='ACTIVE'").Scan(&tv)
	dbReg.QueryRow("SELECT COUNT(*) FROM voter_token_issuance WHERE election_id='general-2026-11-03'").Scan(&ti)
	dbVote.QueryRow("SELECT COUNT(*) FROM vote_casts WHERE election_id='general-2026-11-03' AND status='VALID'").Scan(&vc)
	s["total_registered_voters"] = tv
	s["tokens_issued"] = ti
	s["total_votes_cast"] = vc
	tp := 0.0
	if tv > 0 {
		tp = float64(vc) / float64(tv) * 100
	}
	s["turnout_percent"] = tp
	rows, _ := dbVote.Query("SELECT precinct_id, COUNT(*) FROM vote_casts WHERE election_id='general-2026-11-03' AND status='VALID' GROUP BY precinct_id")
	pm := map[string]int{}
	if rows != nil {
		defer rows.Close()
		for rows.Next() {
			var p string
			var c int
			rows.Scan(&p, &c)
			pm[p] = c
		}
	}
	s["votes_by_precinct"] = pm
	jsonResp(w, 200, s)
}

func handleUI(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(uiHTML))
}

const uiHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SecureVote Simulator</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Atkinson Hyperlegible',system-ui,sans-serif;background:#0c0f19;color:#e2e8f0;min-height:100vh;display:flex;justify-content:center}
.machine{width:100%;max-width:480px;min-height:100vh;background:#fff;color:#1f2937;display:flex;flex-direction:column}
.screen{flex:1;display:flex;flex-direction:column}
.hdr{padding:14px 20px;background:#1B2A4A;color:#fff;display:flex;justify-content:space-between;align-items:center;font-size:13px}
.hdr .logo{font-weight:700;font-size:16px}.hdr .logo span{color:#2563EB}
.prog{padding:12px 20px 8px;border-bottom:1px solid #f3f4f6}
.prog .lb{font-size:13px;font-weight:700;color:#1B2A4A;margin-bottom:6px;display:flex;justify-content:space-between}
.prog .bar{height:5px;border-radius:3px;background:#f3f4f6;overflow:hidden}
.prog .bar .fill{height:100%;background:#2563EB;border-radius:3px;transition:width .4s}
.cnt{flex:1;padding:20px;overflow-y:auto}
.ftr{padding:12px 20px;border-top:1px solid #f3f4f6;display:flex;justify-content:space-between;gap:10px}
h2{font-size:20px;color:#1B2A4A;margin-bottom:4px}
p{font-size:14px;color:#6b7280;line-height:1.5;margin-bottom:12px}
.btn{padding:14px 24px;border-radius:8px;font-size:15px;font-weight:700;cursor:pointer;border:none;font-family:inherit;transition:all .15s;text-align:center;width:100%}
.bp{background:#2563EB;color:#fff}.bp:hover{background:#1d4ed8}
.bs{background:#166534;color:#fff}
.bo{background:transparent;color:#2563EB;border:2px solid #2563EB}
.bg{background:transparent;color:#6b7280;border:1px solid #e5e7eb}
.sm{padding:8px 16px;font-size:13px;width:auto}
input{width:100%;padding:12px 14px;border:2px solid #e5e7eb;border-radius:8px;font-size:15px;font-family:inherit;outline:none}
input:focus{border-color:#2563EB}
.cd{padding:14px 16px;border:2px solid #e5e7eb;border-radius:10px;margin-bottom:8px;cursor:pointer;transition:all .15s}
.cd:hover{border-color:#93c5fd}.cd.sel{border-color:#2563EB;background:#eff6ff}
.cd .nm{font-size:16px;font-weight:700;color:#1B2A4A}
.cd .pt{font-size:13px;color:#6b7280;margin-top:2px}
.rd{width:20px;height:20px;border-radius:50%;border:2px solid #d1d5db;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;margin-right:12px}
.cd.sel .rd{border-color:#2563EB}
.cd.sel .rd::after{content:'';width:10px;height:10px;border-radius:50%;background:#2563EB}
.vr{padding:12px 14px;border:1px solid #e5e7eb;border-radius:8px;margin-bottom:6px;cursor:pointer;transition:all .15s;display:flex;justify-content:space-between;align-items:center}
.vr:hover{border-color:#2563EB;background:#f8faff}
.vr.vd{opacity:.5;cursor:not-allowed}
.tg{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700}
.tg-g{background:#dcfce7;color:#166534}
.tg-r{background:#fee2e2;color:#991b1b}
.ri{padding:10px 14px;border-radius:8px;margin-bottom:6px;display:flex;justify-content:space-between;align-items:center}
.ri.ok{background:#f0fdf4;border:1px solid #bbf7d0}
.ri.sk{background:#fef3c7;border:1px solid #fde68a}
.ri .rn{font-size:12px;color:#6b7280}
.ri .sl{font-size:14px;font-weight:700}
.si{width:72px;height:72px;border-radius:50%;background:#dcfce7;display:flex;align-items:center;justify-content:center;margin:0 auto 16px;font-size:36px}
.mn{font-family:monospace;font-size:12px;color:#1B2A4A;background:#f3f4f6;padding:8px 12px;border-radius:6px;word-break:break-all}
.sg{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px}
.sc{background:#f8fafc;border-radius:8px;padding:12px;text-align:center}
.sc .v{font-size:24px;font-weight:700;color:#1B2A4A}
.sc .l{font-size:11px;color:#6b7280;margin-top:2px}
.sp{display:inline-block;width:20px;height:20px;border:3px solid #e5e7eb;border-top-color:#2563EB;border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.br{width:160px;height:190px;border-radius:50%/40%;border:3px dashed #2563EB;display:flex;align-items:center;justify-content:center;margin:0 auto 16px;background:linear-gradient(135deg,#f0f4ff,#e8eeff);font-size:64px}
.fi{animation:fi .3s ease}
@keyframes fi{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
.pl{animation:pl 2s infinite}
@keyframes pl{0%,100%{opacity:1}50%{opacity:.5}}
.bb{height:4px;background:#2563EB;width:100%}
.hint{font-size:12px;color:#9ca3af;padding:8px 0}
.warn-bar{padding:8px 12px;font-size:12px;color:#92400e;background:#fef3c7;border-radius:6px;font-weight:700;margin-bottom:8px}
</style>
</head>
<body>
<div class="machine" id="app">
  <div class="hdr"><div class="logo">SECURE<span>VOTE</span></div><div>SIM-0001</div></div>
  <div class="screen" id="scr"></div>
  <div class="bb"></div>
</div>
<script>
var S = {step:'idle', voter:null, token:null, ballot:[], sel:{}, ri:0, res:null};
var $ = function(s){ return document.querySelector(s); };

function render(){
  var screens = {
    idle: screenIdle,
    search: screenSearch,
    auth: screenAuth,
    ballot: screenBallot,
    review: screenReview,
    confirm: screenConfirm,
    casting: screenCasting,
    success: screenSuccess,
    receipt: screenReceipt,
    dash: screenDash
  };
  var fn = screens[S.step] || screenIdle;
  $('#scr').innerHTML = fn();
  $('#scr').className = 'screen fi';
  afterRender();
}

function progBar(step, total, label){
  var pct = (step/total)*100;
  return '<div class="prog"><div class="lb"><span>'+label+'</span><span>Step '+step+' of '+total+'</span></div><div class="bar"><div class="fill" style="width:'+pct+'%"></div></div></div>';
}

function screenIdle(){
  return '<div class="cnt" style="display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;flex:1">'
    +'<div style="width:64px;height:64px;border-radius:50%;background:#2563EB;display:flex;align-items:center;justify-content:center;margin-bottom:20px;font-size:28px;color:#fff">&#10003;</div>'
    +'<h2 style="font-size:28px;margin-bottom:4px">SecureVote</h2>'
    +'<p style="font-size:12px;letter-spacing:2px;text-transform:uppercase;color:#2563EB;font-weight:700;margin-bottom:24px">Ready to Vote</p>'
    +'<p class="pl" style="font-size:18px;color:#1B2A4A;margin-bottom:32px">Touch the screen to begin</p>'
    +'<p style="font-size:12px">General Election 2026</p>'
    +'</div>'
    +'<div class="ftr"><button class="btn bp" onclick="goSearch()">Begin Voting &rarr;</button></div>'
    +'<div class="ftr" style="border-top:none;padding-top:0"><button class="btn bg sm" onclick="goDash()">&#128202; Dashboard</button></div>';
}

function screenSearch(){
  return progBar(1,4,'Identify Voter')
    +'<div class="cnt">'
    +'<h2>Find Voter</h2>'
    +'<p>Search by last name (4+ letters), or narrow with commas:</p>'
    +'<p style="font-size:13px;color:#1B2A4A;font-weight:700;margin-bottom:4px">Examples:</p>'
    +'<p style="font-size:12px;color:#6b7280;margin-bottom:12px">'
    +'<b>Smith</b> &mdash; search by last name<br>'
    +'<b>Smith, Joh</b> &mdash; last name + first name<br>'
    +'<b>Smith, John, A</b> &mdash; last + first + middle<br>'
    +'<b>Li,</b> &mdash; short last names: add comma to search</p>'
    +'<input type="text" id="searchInput" placeholder="Last, First, Middle &#8212; type or press Enter" autofocus>'
    +'<div id="searchResults" style="margin-top:12px"></div>'
    +'</div>'
    +'<div class="ftr"><button class="btn bg sm" onclick="goIdle()">&#8592; Cancel</button></div>';
}

function screenAuth(){
  var v = S.voter;
  return progBar(1,4,'Verify Identity')
    +'<div class="cnt" style="text-align:center;display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1">'
    +'<div class="br">&#128100;</div>'
    +'<h2>Verifying Identity</h2>'
    +'<p>'+v.first_name+' '+v.last_name+'<br>Precinct '+v.precinct+'</p>'
    +'<div style="margin-top:16px"><div class="sp"></div></div>'
    +'<p style="margin-top:12px;font-size:13px">Simulating biometric match...</p>'
    +'</div>';
}

function screenBallot(){
  var race = S.ballot[S.ri];
  if(!race) return '';
  var sel = S.sel[race.race_id] || null;
  var h = progBar(2,4,'Vote')
    +'<div style="padding:6px 20px 0;font-size:12px;color:#6b7280">Race '+(S.ri+1)+' of '+S.ballot.length+'</div>'
    +'<div class="cnt"><h2>'+race.title+'</h2>';
  if(race.type==='MEASURE' && race.summary){
    h += '<div style="padding:10px 12px;background:#f3f4f6;border-radius:8px;font-size:13px;color:#374151;line-height:1.5;margin-bottom:12px">'+race.summary+'</div>';
  } else {
    h += '<p style="color:#2563EB;font-weight:700;font-size:13px">Vote for ONE</p>';
  }
  for(var i=0; i<race.candidates.length; i++){
    var c = race.candidates[i];
    var isSel = sel === c.hash;
    h += '<div class="cd'+(isSel?' sel':'')+'" onclick="selectCandidate(\''+race.race_id+'\',\''+c.hash+'\')">'
      +'<div style="display:flex;align-items:center"><div class="rd"></div><div>'
      +'<div class="nm">'+c.name+'</div>'
      +(c.party ? '<div class="pt">'+c.party+'</div>' : '')
      +'</div></div></div>';
  }
  h += '</div><div class="ftr">';
  if(S.ri > 0) h += '<button class="btn bo sm" onclick="prevRace()">&#8592; Back</button>';
  else h += '<button class="btn bg sm" onclick="goSearch()">&#8592; Restart</button>';
  h += '<button class="btn bg sm" onclick="skipRace()" style="font-size:12px">Skip</button>';
  h += '<button class="btn bp sm" onclick="nextRace()">Next &rarr;</button>';
  h += '</div>';
  return h;
}

function screenReview(){
  var h = progBar(3,4,'Review Ballot')
    +'<div class="cnt"><h2>Review Selections</h2><p>Tap Change to modify.</p>';
  var skipped = 0;
  for(var i=0; i<S.ballot.length; i++){
    var race = S.ballot[i];
    var sel = S.sel[race.race_id];
    var cand = null;
    if(sel){
      for(var j=0; j<race.candidates.length; j++){
        if(race.candidates[j].hash === sel){ cand = race.candidates[j]; break; }
      }
    }
    var filled = !!cand;
    if(!filled) skipped++;
    h += '<div class="ri '+(filled?'ok':'sk')+'">'
      +'<div><div class="rn">'+race.title+'</div>'
      +'<div class="sl">'+(filled ? '&#10003; '+cand.name+(cand.party?' ('+cand.party+')':'') : '&#9888; Skipped')+'</div></div>'
      +'<button class="btn bo sm" onclick="changeRace('+i+')">Change</button></div>';
  }
  if(skipped > 0) h += '<div class="warn-bar">&#9888; '+skipped+' skipped</div>';
  h += '</div><div class="ftr">'
    +'<button class="btn bo sm" onclick="changeRace('+(S.ballot.length-1)+')">&#8592; Back</button>'
    +'<button class="btn bp" onclick="goConfirm()">Print Ballot &rarr;</button></div>';
  return h;
}

function screenConfirm(){
  return progBar(4,4,'Cast Vote')
    +'<div class="cnt" style="display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;text-align:center">'
    +'<div style="padding:16px 20px;border:2px dashed #6b7280;border-radius:12px;margin-bottom:20px;width:100%">'
    +'<div style="font-size:12px;font-weight:700;color:#6b7280">PAPER PRINTOUT WINDOW</div>'
    +'<div style="font-size:11px;color:#9ca3af;margin-top:4px">Printed ballot visible here on real machine.</div></div>'
    +'<h2>Does the paper match?</h2><p>This is final.</p>'
    +'<button class="btn bs" onclick="castVote()" style="margin-top:12px;max-width:320px">&#10003; Cast My Vote</button>'
    +'<button class="btn bo" onclick="goReview()" style="margin-top:8px;max-width:320px;border-color:#DC2626;color:#DC2626">&#10007; Go Back</button>'
    +'<p style="font-size:12px;color:#d97706;font-weight:700;margin-top:16px">&#9888; This action is final.</p></div>';
}

function screenCasting(){
  return '<div class="cnt" style="display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;text-align:center">'
    +'<div class="sp" style="width:40px;height:40px;border-width:4px;margin-bottom:20px"></div>'
    +'<h2>Recording Vote...</h2><p>Computing Merkle leaf hash.</p></div>';
}

function screenSuccess(){
  var v = S.res;
  return '<div class="cnt" style="display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;text-align:center">'
    +'<div class="si">&#10003;</div>'
    +'<h2 style="color:#166534;font-size:24px">Vote Recorded</h2>'
    +'<p>Your vote is in the immutable record.</p>'
    +'<div style="margin:16px 0"><div style="font-size:11px;color:#6b7280;margin-bottom:4px">Vote Record ID</div>'
    +'<div class="mn">'+v.vote_record_id+'</div></div>'
    +'<div style="margin-bottom:20px"><div style="font-size:11px;color:#6b7280;margin-bottom:4px">Merkle Leaf Hash</div>'
    +'<div class="mn" style="font-size:10px">'+v.merkle_leaf+'</div></div>'
    +'<button class="btn bp" onclick="goReceipt()">View Receipt &rarr;</button></div>';
}

function screenReceipt(){
  var v = S.res;
  var qr = '<div style="width:120px;height:120px;background:#f3f4f6;border:2px solid #e5e7eb;border-radius:8px;margin:0 auto 12px;display:grid;grid-template-columns:repeat(10,1fr);gap:1px;padding:6px">';
  for(var i=0;i<100;i++) qr += '<div style="background:'+(Math.random()>.45?'#1B2A4A':'transparent')+'"></div>';
  qr += '</div>';
  return '<div class="cnt" style="display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;text-align:center">'
    +'<h2>Your Receipt</h2>'+qr
    +'<div class="mn" style="font-size:10px;margin-bottom:12px">'+v.vote_record_id+'</div>'
    +'<p>Scan this QR code after certification to verify your vote was counted.</p>'
    +'<p style="font-size:12px;color:#2563EB;font-weight:700">Receipt does NOT show selections.</p>'
    +'</div><div class="ftr"><button class="btn bp" onclick="goIdle()">Done &rarr;</button></div>';
}

function screenDash(){
  return '<div class="cnt"><h2>Election Dashboard</h2><p>Live from SecureVote databases.</p>'
    +'<div id="dashStats">Loading...</div>'
    +'<h2 style="margin-top:16px;font-size:16px">Recent Votes</h2>'
    +'<div id="dashVotes">Loading...</div></div>'
    +'<div class="ftr"><button class="btn bg sm" onclick="goIdle()">&#8592; Back</button>'
    +'<button class="btn bo sm" onclick="loadDash()">&#8635; Refresh</button></div>';
}

// --- Navigation ---
function goIdle(){ S = {step:'idle',voter:null,token:null,ballot:[],sel:{},ri:0,res:null}; render(); }
function goSearch(){ S.step='search'; S.voter=null; S.token=null; S.sel={}; S.ri=0; render(); }
function goReview(){ S.step='review'; render(); }
function goConfirm(){ S.step='confirm'; render(); }
function goReceipt(){ S.step='receipt'; render(); }

function goDash(){
  S.step='dash'; render();
  loadDash();
}

function loadDash(){
  Promise.all([
    fetch('/api/stats').then(function(r){return r.json();}),
    fetch('/api/votes/recent').then(function(r){return r.json();})
  ]).then(function(results){
    var st = results[0];
    var vt = results[1];
    var h = '<div class="sg">'
      +'<div class="sc"><div class="v">'+st.total_registered_voters+'</div><div class="l">Registered</div></div>'
      +'<div class="sc"><div class="v">'+st.total_votes_cast+'</div><div class="l">Votes Cast</div></div>'
      +'<div class="sc"><div class="v">'+st.tokens_issued+'</div><div class="l">Tokens</div></div>'
      +'<div class="sc"><div class="v">'+(st.turnout_percent||0).toFixed(1)+'%</div><div class="l">Turnout</div></div></div>';
    if(st.votes_by_precinct){
      h += '<h2 style="font-size:14px;margin-bottom:8px">By Precinct</h2>';
      var entries = Object.entries(st.votes_by_precinct);
      for(var i=0;i<entries.length;i++){
        h += '<div style="display:flex;justify-content:space-between;padding:4px 0;font-size:13px"><span>Precinct '+entries[i][0]+'</span><strong>'+entries[i][1]+'</strong></div>';
      }
    }
    var ds = document.getElementById('dashStats');
    if(ds) ds.innerHTML = h;

    var vh = '';
    if(!vt.length) vh = '<p style="color:#9ca3af;font-size:13px">No votes yet.</p>';
    else {
      for(var i=0;i<vt.length;i++){
        var v = vt[i];
        vh += '<div style="padding:6px 0;border-bottom:1px solid #f3f4f6;font-size:12px;display:flex;justify-content:space-between">'
          +'<span class="mn" style="font-size:10px;background:none;padding:0">'+v.record_id.substr(0,13)+'...</span>'
          +'<span>P-'+v.precinct+'</span><span>'+v.cast_at+'</span>'
          +'<span class="tg tg-g">'+v.status+'</span></div>';
      }
    }
    var dv = document.getElementById('dashVotes');
    if(dv) dv.innerHTML = vh;
  });
}

// --- Voter Search ---
var searchTimer;
function doSearch(q){
  clearTimeout(searchTimer);
  var sr = document.getElementById('searchResults');
  if(!q || !q.trim()){ if(sr) sr.innerHTML=''; return; }

  var hasComma = q.indexOf(',') >= 0;
  var parts = q.split(',');
  var last = parts[0].trim();

  // Need 4+ chars for last name without comma
  if(!hasComma && last.length < 4){
    if(sr) sr.innerHTML = '<div class="hint">Type 4+ characters, or add a comma to search: <b>Li,</b> or <b>Smith, Joh</b></div>';
    return;
  }
  // Need 2+ chars for last name with comma
  if(hasComma && last.length < 2){
    if(sr) sr.innerHTML = '<div class="hint">Type at least 2 characters for last name.</div>';
    return;
  }
  // Need 3+ chars for first name if provided
  if(hasComma && parts.length > 1 && parts[1].trim().length > 0 && parts[1].trim().length < 3){
    if(sr) sr.innerHTML = '<div class="hint">Type 3+ characters for first name after the comma.</div>';
    return;
  }

  searchTimer = setTimeout(function(){
    fetch('/api/voters/search?q=' + encodeURIComponent(q))
      .then(function(r){ return r.json(); })
      .then(function(voters){
        var h = '';
        if(voters.length >= 50){
          h += '<div class="warn-bar">Showing first 50 results. Add a comma to narrow: Last, First</div>';
        }
        for(var i=0; i<voters.length; i++){
          var v = voters[i];
          var vd = v.has_voted;
          h += '<div class="vr'+(vd?' vd':'')+'" onclick="'+(vd ? '' : 'selectVoter('+v.voter_id+')')+'">'
            +'<div><strong>'+v.last_name+', '+v.first_name+(v.middle_name?' '+v.middle_name:'')+'</strong>'
            +'<div style="font-size:12px;color:#6b7280">'+v.dob+' &middot; P-'+v.precinct+' &middot; '+v.reg_number+'</div></div>'
            +(vd ? '<span class="tg tg-r">VOTED</span>' : '<span class="tg tg-g">ELIGIBLE</span>')
            +'</div>';
        }
        if(!voters.length) h = '<p style="color:#9ca3af;font-size:13px;margin-top:8px">No voters found.</p>';
        if(sr) sr.innerHTML = h;
      });
  }, 600);
}

function afterRender(){
  if(S.step === 'search'){
    var el = document.getElementById('searchInput');
    if(el){
      el.addEventListener('keydown', function(e){
        if(e.key === 'Enter'){ e.preventDefault(); doSearch(this.value); }
      });
      el.addEventListener('input', function(){
        doSearch(this.value);
      });
    }
  }
}

// --- Voter Selection & Auth ---
function selectVoter(id){
  // Find the voter from the last search results already on screen
  var rows = document.querySelectorAll('.vr');
  // We already have the data, just store the id and go to auth
  S.voter = {voter_id: id, first_name: '', last_name: '', precinct: ''};
  // Quick fetch by primary key only
  fetch('/api/voters/get?id=' + id)
    .then(function(r){ return r.json(); })
    .then(function(v){
      S.voter = v;
      S.step = 'auth';
      render();
      setTimeout(function(){
        fetch('/api/voters/authenticate', {
          method: 'POST',
          headers: {'Content-Type':'application/json'},
          body: JSON.stringify({voter_id: id})
        })
        .then(function(r){ return r.json(); })
        .then(function(ar){
          if(!ar.success){ alert(ar.message); goSearch(); return; }
          S.token = ar.token_hash;
          S.voter.precinct = ar.precinct;
          fetch('/api/ballot').then(function(r){ return r.json(); }).then(function(ballot){
            S.ballot = ballot;
            S.ri = 0;
            S.step = 'ballot';
            render();
          });
        });
      }, 2500);
    });
}
// --- Ballot Navigation ---
function selectCandidate(raceId, hash){
  if(S.sel[raceId] === hash) delete S.sel[raceId];
  else S.sel[raceId] = hash;
  render();
}
function nextRace(){
  if(S.ri < S.ballot.length - 1){ S.ri++; render(); }
  else { S.step = 'review'; render(); }
}
function prevRace(){ if(S.ri > 0){ S.ri--; render(); } }
function skipRace(){ delete S.sel[S.ballot[S.ri].race_id]; nextRace(); }
function changeRace(i){ S.ri = i; S.step = 'ballot'; render(); }

// --- Cast Vote ---
function castVote(){
  S.step = 'casting';
  render();
  fetch('/api/vote/cast', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({
      token_hash: S.token,
      precinct: S.voter.precinct,
      selections: S.sel
    })
  })
  .then(function(r){ return r.json(); })
  .then(function(result){
    if(!result.success){ alert(result.message); goReview(); return; }
    S.res = result;
    S.step = 'success';
    render();
  });
}

// --- Init ---
render();
</script>
</body>
</html>`
