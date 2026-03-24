#!/usr/bin/env python3
"""SecureVote Admin Portal — Card Issuance + Election Management."""
import subprocess,json,os,hashlib,io,random,secrets,time,html as htmlmod
from http.server import HTTPServer,BaseHTTPRequestHandler
from http.cookies import SimpleCookie
from urllib.parse import urlparse,parse_qs
from datetime import datetime
from PIL import Image,ImageDraw,ImageFont
import qrcode

sessions={};STL=3600*8
DPI=300;CW=2024;CH=1276
NAVY=(27,42,74);CB=(37,99,235);WH=(255,255,255);LG=(240,242,245)
MG=(140,148,160);DG=(60,65,75);GR=(22,101,52);RD=(180,40,40);BG=(250,251,253)

def lf(size,bold=False):
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(p):return ImageFont.truetype(p,size)
    return ImageFont.load_default()

def qreg(sql):
    r=subprocess.run(["mariadb","-h",os.environ.get("DB_HOST","db-registration"),"-u",os.environ.get("DB_USER","sv_reg_user"),"-p"+os.environ.get("DB_PASS","sv-reg-pw-2026"),os.environ.get("DB_NAME","securevote_registration"),"-N","-B","-e",sql],capture_output=True,text=True)
    if r.returncode!=0:return[]
    return[l.split("\t")for l in r.stdout.rstrip("\n").split("\n")if l]

def ereg(sql):
    subprocess.run(["mariadb","-h",os.environ.get("DB_HOST","db-registration"),"-u",os.environ.get("DB_USER","sv_reg_user"),"-p"+os.environ.get("DB_PASS","sv-reg-pw-2026"),os.environ.get("DB_NAME","securevote_registration"),"-e",sql],capture_output=True,text=True)

def qelec(sql):
    r=subprocess.run(["mariadb","-h",os.environ.get("DB_ELEC_HOST","db-election"),"-u",os.environ.get("DB_ELEC_USER","sv_elec_user"),"-p"+os.environ.get("DB_ELEC_PASS","sv-elec-pw-2026"),os.environ.get("DB_ELEC_NAME","securevote_election"),"-N","-B","-e",sql],capture_output=True,text=True)
    if r.returncode!=0:return[]
    return[l.split("\t")for l in r.stdout.strip().split("\n")if l.strip()]

def eelec(sql):
    r=subprocess.run(["mariadb","-h",os.environ.get("DB_ELEC_HOST","db-election"),"-u",os.environ.get("DB_ELEC_USER","sv_elec_user"),"-p"+os.environ.get("DB_ELEC_PASS","sv-elec-pw-2026"),os.environ.get("DB_ELEC_NAME","securevote_election"),"-e",sql],capture_output=True,text=True)
    return[l.split("\t")for l in r.stdout.strip().split("\n")if l.strip()]

def esc(s):return str(s).replace("'","''").replace("\\","\\\\")

def authenticate(user,pw):
    rows=qreg("SELECT operator_id,username,password_hash,password_salt,legal_first_name,legal_last_name,access_level,is_active,failed_login_count,COALESCE(locked_until,'') FROM card_operators WHERE username='"+esc(user)+"' LIMIT 1")
    if not rows:return None,"Invalid username or password"
    r=rows[0]
    if len(r)<10:return None,"Database schema mismatch"
    oid,ph,sa,fn,ln,lv,ac,fc=r[0],r[2],r[3],r[4],r[5],r[6],r[7],int(r[8])
    if ac!="1":return None,"Account deactivated"
    lu=r[9]
    if lu and lu not in("","NULL","\\N"):
        try:
            if datetime.now()<datetime.strptime(lu,"%Y-%m-%d %H:%M:%S"):return None,"Locked until "+lu
        except:pass
    if hashlib.sha256((sa+pw).encode()).hexdigest()!=ph:
        nf=fc+1;lk=", locked_until=DATE_ADD(NOW(), INTERVAL 30 MINUTE)" if nf>=5 else ""
        ereg("UPDATE card_operators SET failed_login_count="+str(nf)+lk+" WHERE operator_id="+str(oid))
        rem=5-nf
        if rem>0:return None,"Invalid credentials ("+str(rem)+" left)"
        return None,"Account locked 30 min"
    ereg("UPDATE card_operators SET failed_login_count=0,locked_until=NULL,last_login_at=NOW() WHERE operator_id="+str(oid))
    t=secrets.token_hex(32);sessions[t]={"oid":oid,"un":r[1],"nm":fn+" "+ln,"lv":lv,"ex":time.time()+STL}
    return t,None

def gs(ch):
    if not ch:return None
    c=SimpleCookie();c.load(ch)
    if "sv_admin" not in c:return None
    s=sessions.get(c["sv_admin"].value)
    if not s or time.time()>s["ex"]:return None
    return s

def gv(vid):
    rows=qreg("SELECT voter_id,voter_uuid,legal_first_name,COALESCE(legal_middle_name,''),legal_last_name,COALESCE(legal_suffix,''),date_of_birth,registration_number,registration_date,registration_status,state_code,county_code,precinct_id,COALESCE(mailing_address_line1,''),COALESCE(mailing_city,''),COALESCE(mailing_state,'FL'),COALESCE(mailing_zip,'') FROM voters WHERE voter_id="+str(vid)+" LIMIT 1")
    if not rows:return None
    r=rows[0];return dict(voter_id=r[0],uuid=r[1],first=r[2],middle=r[3],last=r[4],suffix=r[5],dob=r[6],reg_number=r[7],reg_date=r[8],status=r[9],state=r[10],county=r[11],precinct=r[12],address=r[13],city=r[14],addr_state=r[15],zip=r[16])

def vhash(v):return hashlib.sha256((v["reg_number"]+"|"+v["last"]+"|"+v["first"]+"|"+v["dob"]).encode()).hexdigest()[:16].upper()

def logi(oid,vid,fmt,data,ip):
    ch=hashlib.sha256(data).hexdigest();ri=hashlib.sha256((str(oid)+"|"+str(vid)+"|"+ch).encode()).hexdigest()
    ereg("INSERT INTO card_issuance_log(operator_id,voter_id,card_format,card_hash,issuer_ip,reason,row_integrity_hash)VALUES("+str(oid)+","+str(vid)+",'"+fmt.upper()+"','"+ch+"','"+esc(ip or "")+"','NEW_ISSUANCE','"+ri+"')")

def mkqr(data,sz=400):
    q=qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H,box_size=10,border=1);q.add_data(data);q.make(fit=True)
    return q.make_image(fill_color=NAVY,back_color=WH).resize((sz,sz),Image.LANCZOS)

def draw_front(v):
    c=Image.new("RGB",(CW,CH),BG);d=ImageDraw.Draw(c)
    d.rectangle([(0,0),(CW,144)],fill=NAVY)
    for i in range(13):d.line([(CW-240,8+i*10),(CW-20,8+i*10)],fill=(200,60,60)if i%2==0 else WH,width=6)
    d.rectangle([(CW-240,8),(CW-148,76)],fill=(20,35,90))
    d.text((40,16),"SECUREVOTE",fill=WH,font=lf(56,True));d.text((420,28),"VOTER IDENTIFICATION CARD",fill=CB,font=lf(28,True))
    d.text((40,84),"UNITED STATES OF AMERICA",fill=(150,160,180),font=lf(28,True));d.rectangle([(0,144),(CW,152)],fill=CB)
    px,py,pw,ph=40,180,280,350;d.rectangle([(px,py),(px+pw,py+ph)],fill=LG,outline=MG,width=2)
    cx,cy=px+pw//2,py+ph//2-20;d.ellipse([(cx-50,cy-60),(cx+50,cy+40)],fill=MG);d.ellipse([(cx-90,cy+40),(cx+90,cy+160)],fill=MG)
    d.text((px+80,py+ph-40),"PHOTO",fill=DG,font=lf(22))
    nm=v["last"].upper()+", "+v["first"].upper()
    if v["middle"]:nm+=" "+v["middle"][0].upper()+"."
    d.text((360,170),"NAME",fill=MG,font=lf(22,True));d.text((360,198),nm,fill=NAVY,font=lf(58,True))
    bc=GR if v["status"]=="ACTIVE" else RD;bx=CW-220
    d.rounded_rectangle([(bx,172),(bx+180,220)],radius=8,fill=bc);d.text((bx+20,180),v["status"],fill=WH,font=lf(28,True))
    fy=290;c1,c2=360,1000
    d.text((c1,fy),"DATE OF BIRTH",fill=MG,font=lf(22,True));d.text((c1,fy+28),v["dob"],fill=DG,font=lf(32,True))
    d.text((c2,fy),"REGISTRATION NO.",fill=MG,font=lf(22,True));d.text((c2,fy+28),v["reg_number"],fill=DG,font=lf(32,True))
    fy+=84;d.text((c1,fy),"REGISTERED",fill=MG,font=lf(22,True));d.text((c1,fy+28),v["reg_date"],fill=DG,font=lf(28))
    d.text((c2,fy),"COUNTY",fill=MG,font=lf(22,True));d.text((c2,fy+28),v["county"],fill=DG,font=lf(28))
    fy+=84;d.text((c1,fy),"ADDRESS",fill=MG,font=lf(22,True))
    ad=v["address"][:38]+"..."if len(v["address"])>40 else v["address"]
    d.text((c1,fy+28),ad,fill=DG,font=lf(28));d.text((c1,fy+60),v["city"]+", "+v["addr_state"]+" "+v["zip"],fill=DG,font=lf(28))
    d.text((c2,fy),"PRECINCT",fill=MG,font=lf(22,True));d.text((c2,fy+28),v["precinct"],fill=DG,font=lf(32,True))
    d.rectangle([(0,CH-100),(CW,CH)],fill=NAVY);vh=vhash(v)
    d.text((40,CH-84),"VERIFICATION",fill=MG,font=lf(18));d.text((40,CH-60),vh,fill=(180,190,210),font=lf(28,True))
    d.text((400,CH-84),"STATE",fill=MG,font=lf(18));d.text((400,CH-60),v["state"],fill=(180,190,210),font=lf(28,True))
    d.text((CW-400,CH-84),"ISSUED",fill=MG,font=lf(18));d.text((CW-400,CH-60),datetime.now().strftime("%Y-%m-%d"),fill=(180,190,210),font=lf(28))
    d.rectangle([(0,CH-8),(CW,CH)],fill=CB);return c

def draw_back(v):
    c=Image.new("RGB",(CW,CH),BG);d=ImageDraw.Draw(c)
    d.rectangle([(0,0),(CW,80)],fill=NAVY);d.text((40,16),"SECUREVOTE \u2014 VOTER IDENTIFICATION",fill=WH,font=lf(36,True))
    d.rectangle([(0,80),(CW,86)],fill=CB)
    qd=json.dumps({"sv":"1.0","reg":v["reg_number"],"uuid":v["uuid"],"hash":vhash(v),"state":v["state"],"county":v["county"],"precinct":v["precinct"]},separators=(",",":"))
    c.paste(mkqr(qd,400),(60,120));d.text((140,530),"SCAN TO VERIFY",fill=MG,font=lf(22))
    d.rectangle([(0,CH-160),(CW,CH-90)],fill=(30,30,30));random.seed(hash(v["reg_number"]));x=40
    while x<CW-40:
        w=random.choice([2,2,4,2,6,2,4])
        if random.random()>.4:d.rectangle([(x,CH-152),(x+w,CH-98)],fill=(200,200,200))
        x+=w+random.choice([2,4,2])
    m1=("SVID<<"+v["last"].upper()+"<"+v["first"].upper()+"<"+v["reg_number"])[:50].ljust(50,"<")
    m2=(v["state"]+v["county"]+v["precinct"]+"<"+v["dob"].replace("-","")+"<"+vhash(v))[:50].ljust(50,"<")
    d.text((40,CH-84),m1,fill=MG,font=lf(20));d.text((40,CH-56),m2,fill=MG,font=lf(20))
    ix,iy=520,130;d.text((ix,iy),"This card is the property of the",fill=DG,font=lf(22));d.text((ix,iy+28),"SecureVote Election Authority.",fill=DG,font=lf(22))
    iy+=72;d.text((ix,iy),"INSTRUCTIONS",fill=NAVY,font=lf(26,True));iy+=40
    for ln in["1. Present this card at your polling place","2. Insert into the ID scanner slot","3. Look at the camera for verification","4. Follow on-screen voting instructions"]:d.text((ix,iy),ln,fill=DG,font=lf(22));iy+=32
    iy+=24;d.text((ix,iy),"If found, return to any polling place",fill=MG,font=lf(18));d.text((ix,iy+24),"or post office. Do not destroy.",fill=MG,font=lf(18))
    iy+=60;d.text((ix,iy),"Card ID: SV-"+str(v["voter_id"])+"-"+vhash(v)[:8],fill=MG,font=lf(22))
    d.rectangle([(0,CH-8),(CW,CH)],fill=CB);return c

def gbytes(v,fmt="png"):
    fr=draw_front(v);bk=draw_back(v);buf=io.BytesIO()
    if fmt=="pdf":fr.save(buf,"PDF",resolution=DPI,save_all=True,append_images=[bk]);return buf.getvalue(),"application/pdf"
    combo=Image.new("RGB",(CW,CH*2+40),WH);combo.paste(fr,(0,0));combo.paste(bk,(0,CH+40))
    combo.save(buf,"PNG",dpi=(DPI,DPI));return buf.getvalue(),"image/png"

# ====================== HTML ======================

LOGIN_PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SecureVote Admin</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Atkinson Hyperlegible',system-ui,sans-serif;background:#0c0f19;color:#e2e8f0;min-height:100vh}
.login-box{width:100%;max-width:400px;padding:32px;background:#141724;border-radius:12px;border:1px solid #2a2d3e;text-align:center;margin:15vh auto}
h1{font-size:20px;color:#fff}h1 span{color:#2563EB}
.sub{color:#6b7280;font-size:13px;margin:4px 0 24px}
.sh{width:56px;height:56px;border-radius:50%;background:#1B2A4A;display:flex;align-items:center;justify-content:center;margin:0 auto 16px;font-size:24px}
.fg{margin-bottom:14px;text-align:left}
.fg label{display:block;font-size:12px;font-weight:700;color:#6b7280;margin-bottom:4px}
input{width:100%;padding:10px 12px;border:2px solid #2a2d3e;border-radius:8px;font-size:14px;font-family:inherit;background:#1a1d2e;color:#e2e8f0;outline:none}
input:focus{border-color:#2563EB}
button{width:100%;padding:14px;border-radius:8px;font-size:15px;font-weight:700;cursor:pointer;border:none;font-family:inherit;background:#2563EB;color:#fff;margin-top:8px}
.err{background:#450a0a;border:1px solid #7f1d1d;color:#fca5a5;padding:10px;border-radius:8px;font-size:13px;margin-top:12px}
</style></head><body>
<div class="login-box"><div class="sh">&#x1f6e1;</div><h1>SECURE<span>VOTE</span></h1>
<div class="sub">Admin Portal</div>
<form method="POST" action="/admin/login">
<div class="fg"><label>USERNAME</label><input type="text" name="username" required autofocus></div>
<div class="fg"><label>PASSWORD</label><input type="password" name="password" required></div>
<button type="submit">Sign In</button>
</form>__ERR__
<p style="font-size:11px;color:#4b5563;margin-top:16px">All access is logged and monitored.</p>
</div></body></html>"""

def app_page(sess):
    return """<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SecureVote Admin Portal</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Atkinson Hyperlegible',system-ui,sans-serif;background:#0c0f19;color:#e2e8f0;min-height:100vh}
.wrap{max-width:960px;margin:0 auto;padding:20px}
h1{font-size:22px;color:#fff}h1 span{color:#2563EB}
h2{font-size:18px;color:#fff;margin:20px 0 10px}
h3{font-size:15px;color:#94a3b8;margin:12px 0 8px}
p{font-size:14px;color:#6b7280;line-height:1.5;margin-bottom:12px}
.hdr{background:#1B2A4A;padding:16px 20px;border-radius:10px;margin-bottom:20px;display:flex;justify-content:space-between;align-items:center}
.ui{text-align:right;font-size:12px;color:#94a3b8}.ui .nm{font-weight:700;color:#fff;font-size:14px}
.br-link{background:transparent;color:#f87171;border:1px solid #7f1d1d;font-size:12px;padding:6px 12px;text-decoration:none;border-radius:6px;display:inline-block}
.tabs{display:flex;gap:4px;margin-bottom:20px;flex-wrap:wrap}
.tab{padding:10px 20px;border-radius:8px 8px 0 0;cursor:pointer;font-size:14px;font-weight:700;color:#6b7280;background:#141724;border:1px solid #2a2d3e;border-bottom:none}
.tab:hover{color:#fff}.tab.active{background:#2563EB;color:#fff;border-color:#2563EB}
.panel{display:none}.panel.active{display:block}
.sb{display:flex;gap:8px;margin-bottom:16px}
input,select,textarea{padding:10px 12px;border:2px solid #2a2d3e;border-radius:8px;font-size:14px;font-family:inherit;background:#1a1d2e;color:#e2e8f0;outline:none;width:100%}
input:focus,select:focus,textarea:focus{border-color:#2563EB}
textarea{min-height:80px;resize:vertical}
button{padding:10px 18px;border-radius:8px;font-size:14px;font-weight:700;cursor:pointer;border:none;font-family:inherit;background:#2563EB;color:#fff}
button:hover{background:#1d4ed8}
.bs{padding:8px 14px;font-size:12px}
.bo{background:transparent;color:#2563EB;border:2px solid #2563EB}
.card-row{padding:14px 16px;background:#1a1d2e;border:1px solid #2a2d3e;border-radius:8px;margin-bottom:6px;display:flex;justify-content:space-between;align-items:center}
.card-row:hover{border-color:#2563EB}
.nm2{font-weight:700;color:#fff;font-size:15px}
.dt{font-size:12px;color:#6b7280;margin-top:2px}
.cp{text-align:center;margin:20px 0}.cp img{max-width:100%;border-radius:8px;box-shadow:0 4px 24px rgba(0,0,0,.4)}
.dl{display:flex;gap:8px;justify-content:center;margin-top:12px}
.tg{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700}
.tg-g{background:#166534;color:#fff}.tg-b{background:#1e40af;color:#fff}.tg-y{background:#854d0e;color:#fff}
.em{color:#6b7280;font-size:14px;padding:20px;text-align:center}
.le{padding:8px 12px;background:#111322;border-radius:6px;margin-bottom:4px;font-size:12px;display:flex;justify-content:space-between}
.le .tm{color:#6b7280}
.sg{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:16px}
.sc{background:#1a1d2e;border-radius:8px;padding:12px;text-align:center}.sc .v{font-size:22px;font-weight:700;color:#fff}.sc .l{font-size:11px;color:#6b7280;margin-top:2px}
.fg{margin-bottom:14px}.fg label{display:block;font-size:12px;font-weight:700;color:#6b7280;margin-bottom:4px}
.fr{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.fr3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}
.ok-msg{background:#052e16;border:1px solid #166534;color:#4ade80;padding:10px;border-radius:8px;font-size:13px;margin-bottom:12px}
.err-msg{background:#450a0a;border:1px solid #7f1d1d;color:#fca5a5;padding:10px;border-radius:8px;font-size:13px;margin-bottom:12px}
.dt-table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px}
.dt-table th{text-align:left;padding:8px 10px;background:#141724;color:#94a3b8;font-size:11px;text-transform:uppercase;border-bottom:2px solid #2a2d3e}
.dt-table td{padding:8px 10px;border-bottom:1px solid #1a1d2e;color:#e2e8f0}
.dt-table tr:hover{background:#141724}
.warn-bar{padding:8px 12px;font-size:12px;color:#92400e;background:#fef3c7;border-radius:6px;font-weight:700;margin-bottom:8px}
</style></head><body>
<div class="wrap">
<div class="hdr"><div><h1>SECURE<span>VOTE</span> Admin Portal</h1>
<div style="color:#6b7280;font-size:13px">Election Management &amp; Card Issuance</div></div>
<div class="ui"><div class="nm">"""+sess["nm"]+"""</div><div>"""+sess["lv"]+""" &middot; """+sess["un"]+"""</div>
<a href="/admin/logout" class="br-link" style="margin-top:4px">Sign Out</a></div></div>

<div class="tabs" id="tabBar"></div>
<div id="panels"></div>
</div>

<script>
var tabs = [
  {id:"dash", label:"Dashboard"},
  {id:"cards", label:"ID Cards"},
  {id:"elections", label:"Elections"},
  {id:"races", label:"Races & Candidates"},
  {id:"measures", label:"Measures"}
];

var currentTab = "dash";

function renderTabs(){
  var h = "";
  for(var i=0;i<tabs.length;i++){
    var t = tabs[i];
    h += '<div class="tab'+(currentTab===t.id?' active':'')+'" data-tab="'+t.id+'">'+t.label+'</div>';
  }
  document.getElementById("tabBar").innerHTML = h;
  document.querySelectorAll(".tab").forEach(function(el){
    el.addEventListener("click", function(){
      currentTab = this.getAttribute("data-tab");
      renderTabs();
      renderPanel();
    });
  });
}

function renderPanel(){
  var p = document.getElementById("panels");
  var fn = {dash:panelDash, cards:panelCards, elections:panelElections, races:panelRaces, measures:panelMeasures};
  p.innerHTML = (fn[currentTab]||panelDash)();
  afterPanel();
}

function panelDash(){
  return '<div class="sg" id="dashStats"></div><h2>Recent Card Issuances</h2><div id="dashLog"></div>';
}

function panelCards(){
  return '<h2>Issue Voter ID Card</h2>'
    +'<p>Search by last name (4+ chars) or use commas: <b>Smith, John</b></p>'
    +'<div class="sb"><input type="text" id="cardSearch" placeholder="Last, First, Middle"><button id="cardSearchBtn">Search</button></div>'
    +'<div id="cardResults"></div><div id="cardPreview" class="cp"></div>';
}

function panelElections(){
  return '<h2>Manage Elections</h2><div id="elecList"></div>'
    +'<h3>Add Jurisdiction</h3><div id="jurMsg"></div>'
    +'<div class="fr3"><div class="fg"><label>ID (e.g. US-FL)</label><input id="jurId"></div>'
    +'<div class="fg"><label>Parent (e.g. US)</label><input id="jurParent"></div>'
    +'<div class="fg"><label>Type</label><select id="jurType"><option>FEDERAL</option><option>STATE</option><option>COUNTY</option><option>MUNICIPAL</option></select></div></div>'
    +'<div class="fr"><div class="fg"><label>Name</label><input id="jurName"></div>'
    +'<div class="fg"><label>FIPS Code</label><input id="jurFips"></div></div>'
    +'<button class="bs" id="btnAddJur">Add Jurisdiction</button>'
    +'<h3 style="margin-top:24px">Add Election</h3><div id="elecMsg"></div>'
    +'<div class="fr"><div class="fg"><label>Election ID</label><input id="eId"></div>'
    +'<div class="fg"><label>Jurisdiction ID</label><input id="eJur"></div></div>'
    +'<div class="fg"><label>Title</label><input id="eTitle"></div>'
    +'<div class="fr3"><div class="fg"><label>Type</label><select id="eType"><option>GENERAL</option><option>PRIMARY</option><option>SPECIAL</option></select></div>'
    +'<div class="fg"><label>Date</label><input type="date" id="eDate"></div>'
    +'<div class="fg"><label>Status</label><select id="eStatus"><option>DRAFT</option><option>ACTIVE</option><option>CLOSED</option></select></div></div>'
    +'<div class="fr"><div class="fg"><label>Polls Open</label><input type="time" id="eOpen" value="06:00"></div>'
    +'<div class="fg"><label>Polls Close</label><input type="time" id="eClose" value="19:00"></div></div>'
    +'<button class="bs" id="btnAddElec">Add Election</button>'
    +'<h3 style="margin-top:24px">Jurisdictions</h3><div id="jurList"></div>';
}

function panelRaces(){
  return '<h2>Races &amp; Candidates</h2>'
    +'<h3>Add Race</h3><div id="raceMsg"></div>'
    +'<div class="fr"><div class="fg"><label>Race ID</label><input id="rId"></div>'
    +'<div class="fg"><label>Election ID</label><input id="rElec"></div></div>'
    +'<div class="fg"><label>Title</label><input id="rTitle"></div>'
    +'<div class="fr3"><div class="fg"><label>Type</label><select id="rType"><option>FEDERAL</option><option>STATE</option><option>COUNTY</option><option>MUNICIPAL</option></select></div>'
    +'<div class="fg"><label>Jurisdiction</label><input id="rJur"></div>'
    +'<div class="fg"><label>Display Order</label><input type="number" id="rOrder" value="1"></div></div>'
    +'<div class="fr"><div class="fg"><label>Voting Rule</label><select id="rRule"><option>CHOOSE_ONE</option><option>CHOOSE_N</option><option>RANKED_CHOICE</option></select></div>'
    +'<div class="fg"><label>Write-in</label><select id="rWriteIn"><option value="1">Yes</option><option value="0">No</option></select></div></div>'
    +'<button class="bs" id="btnAddRace">Add Race</button>'
    +'<h3 style="margin-top:24px">Add Candidate</h3><div id="candMsg"></div>'
    +'<div class="fr"><div class="fg"><label>Race ID</label><input id="cRace"></div>'
    +'<div class="fg"><label>Legal Full Name</label><input id="cLegal"></div></div>'
    +'<div class="fr3"><div class="fg"><label>Display Name</label><input id="cDisplay"></div>'
    +'<div class="fg"><label>Party</label><input id="cParty"></div>'
    +'<div class="fg"><label>Order</label><input type="number" id="cOrder" value="1"></div></div>'
    +'<button class="bs" id="btnAddCand">Add Candidate</button>'
    +'<h3 style="margin-top:24px">Current Races</h3><div id="raceList"></div>';
}

function panelMeasures(){
  return '<h2>Ballot Measures</h2>'
    +'<h3>Add Measure</h3><div id="measMsg"></div>'
    +'<div class="fr"><div class="fg"><label>Measure ID</label><input id="mId"></div>'
    +'<div class="fg"><label>Election ID</label><input id="mElec"></div></div>'
    +'<div class="fg"><label>Jurisdiction</label><input id="mJur"></div>'
    +'<div class="fg"><label>Title</label><input id="mTitle"></div>'
    +'<div class="fg"><label>Summary</label><textarea id="mSummary"></textarea></div>'
    +'<div class="fg"><label>Display Order</label><input type="number" id="mOrder" value="1"></div>'
    +'<button class="bs" id="btnAddMeas">Add Measure</button>'
    +'<h3 style="margin-top:16px">Add Option</h3><div id="optMsg"></div>'
    +'<div class="fr3"><div class="fg"><label>Measure ID</label><input id="oMeasure"></div>'
    +'<div class="fg"><label>Option (e.g. Yes)</label><input id="oName"></div>'
    +'<div class="fg"><label>Order</label><input type="number" id="oOrder" value="1"></div></div>'
    +'<button class="bs" id="btnAddOpt">Add Option</button>'
    +'<h3 style="margin-top:24px">Current Measures</h3><div id="measList"></div>';
}

function afterPanel(){
  if(currentTab==="dash") loadDash();
  if(currentTab==="cards"){
    var btn=document.getElementById("cardSearchBtn");
    var inp=document.getElementById("cardSearch");
    if(btn) btn.addEventListener("click", searchCards);
    if(inp) inp.addEventListener("keydown", function(e){if(e.key==="Enter")searchCards()});
  }
  if(currentTab==="elections"){
    loadElections();loadJurisdictions();
    var b1=document.getElementById("btnAddJur"); if(b1) b1.addEventListener("click",addJurisdiction);
    var b2=document.getElementById("btnAddElec"); if(b2) b2.addEventListener("click",addElection);
  }
  if(currentTab==="races"){
    loadRaces();
    var b3=document.getElementById("btnAddRace"); if(b3) b3.addEventListener("click",addRace);
    var b4=document.getElementById("btnAddCand"); if(b4) b4.addEventListener("click",addCandidate);
  }
  if(currentTab==="measures"){
    loadMeasures();
    var b5=document.getElementById("btnAddMeas"); if(b5) b5.addEventListener("click",addMeasure);
    var b6=document.getElementById("btnAddOpt"); if(b6) b6.addEventListener("click",addOption);
  }
}

function api(method,url,body){
  var opts={method:method,headers:{"Content-Type":"application/json"}};
  if(body)opts.body=JSON.stringify(body);
  return fetch(url,opts).then(function(r){return r.json()});
}
function g(id){var el=document.getElementById(id);return el?el.value.trim():"";}

function loadDash(){
  api("GET","/admin/api/stats").then(function(s){
    var el=document.getElementById("dashStats");
    if(el) el.innerHTML='<div class="sc"><div class="v">'+s.total_voters+'</div><div class="l">Voters</div></div>'
      +'<div class="sc"><div class="v">'+s.elections+'</div><div class="l">Elections</div></div>'
      +'<div class="sc"><div class="v">'+s.races+'</div><div class="l">Races</div></div>'
      +'<div class="sc"><div class="v">'+s.candidates+'</div><div class="l">Candidates</div></div>'
      +'<div class="sc"><div class="v">'+s.cards_today+'</div><div class="l">Cards Today</div></div>'
      +'<div class="sc"><div class="v">'+s.cards_total+'</div><div class="l">Cards Total</div></div>';
  });
  api("GET","/admin/api/card/log").then(function(l){
    var el=document.getElementById("dashLog");
    if(!el)return;
    var h="";
    if(!l.length)h='<div class="em">No cards issued yet.</div>';
    else l.forEach(function(e){h+='<div class="le"><span>'+e.voter_name+' ('+e.voter_id+')</span><span>'+e.format+'</span><span class="tm">'+e.issued_at+'</span></div>';});
    el.innerHTML=h;
  });
}

function searchCards(){
  var q=g("cardSearch");if(!q)return;
  api("GET","/admin/api/card/search?q="+encodeURIComponent(q)).then(function(vs){
    var el=document.getElementById("cardResults");if(!el)return;
    var h="";
    if(vs.length>=50)h='<div class="warn-bar">Showing 50 results. Narrow with commas.</div>';
    if(!vs.length)h='<div class="em">No voters found.</div>';
    else vs.forEach(function(v){
      h+='<div class="card-row"><div><div class="nm2">'+v.last+', '+v.first+(v.middle?' '+v.middle:'')
        +' <span class="tg tg-g">'+v.status+'</span></div><div class="dt">ID: '+v.voter_id
        +' | '+v.dob+' | '+v.reg_number+' | P-'+v.precinct+'</div><div class="dt">'
        +v.address+', '+v.city+' '+v.state+' '+v.zip+'</div></div>'
        +'<div style="display:flex;gap:6px">'
        +'<button class="bs" data-vid="'+v.voter_id+'" data-fmt="png">PNG</button>'
        +'<button class="bs bo" data-vid="'+v.voter_id+'" data-fmt="pdf">PDF</button>'
        +'</div></div>';
    });
    el.innerHTML=h;
    el.querySelectorAll("button[data-vid]").forEach(function(btn){
      btn.addEventListener("click",function(){
        genCard(parseInt(this.getAttribute("data-vid")),this.getAttribute("data-fmt"));
      });
    });
    document.getElementById("cardPreview").innerHTML="";
  });
}

function genCard(id,fmt){
  if(fmt==="pdf"){window.open("/admin/api/card/generate?voter_id="+id+"&format=pdf");setTimeout(loadDash,1500);return;}
  var u="/admin/api/card/generate?voter_id="+id+"&format=png&t="+Date.now();
  var el=document.getElementById("cardPreview");
  if(el){
    el.innerHTML='<img src="'+u+'">'
      +'<div class="dl"><a href="'+u+'" download><button class="bs">Download PNG</button></a>'
      +'<a href="/admin/api/card/generate?voter_id='+id+'&format=pdf" download><button class="bs bo">Download PDF</button></a></div>';
  }
  setTimeout(loadDash,1500);
}

function loadElections(){
  api("GET","/admin/api/election/list").then(function(rows){
    var el=document.getElementById("elecList");if(!el)return;
    if(!rows.length){el.innerHTML='<div class="em">No elections.</div>';return;}
    var h='<table class="dt-table"><tr><th>ID</th><th>Title</th><th>Date</th><th>Status</th><th>Jurisdiction</th></tr>';
    rows.forEach(function(r){h+="<tr><td>"+r[0]+"</td><td>"+r[1]+"</td><td>"+r[2]+'</td><td><span class="tg tg-b">'+r[3]+"</span></td><td>"+r[4]+"</td></tr>";});
    el.innerHTML=h+"</table>";
  });
}

function loadJurisdictions(){
  api("GET","/admin/api/jurisdiction/list").then(function(rows){
    var el=document.getElementById("jurList");if(!el)return;
    if(!rows.length){el.innerHTML='<div class="em">No jurisdictions.</div>';return;}
    var h='<table class="dt-table"><tr><th>ID</th><th>Parent</th><th>Type</th><th>Name</th></tr>';
    rows.forEach(function(r){h+="<tr><td>"+r[0]+"</td><td>"+(r[1]||"-")+'</td><td><span class="tg tg-y">'+r[2]+"</span></td><td>"+r[3]+"</td></tr>";});
    el.innerHTML=h+"</table>";
  });
}

function addJurisdiction(){
  api("POST","/admin/api/jurisdiction/add",{id:g("jurId"),parent:g("jurParent"),type:g("jurType"),name:g("jurName"),fips:g("jurFips")}).then(function(r){
    var el=document.getElementById("jurMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Jurisdiction added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadJurisdictions();
  });
}

function addElection(){
  api("POST","/admin/api/election/add",{id:g("eId"),jurisdiction:g("eJur"),type:g("eType"),title:g("eTitle"),date:g("eDate"),open:g("eOpen"),close:g("eClose"),status:g("eStatus")}).then(function(r){
    var el=document.getElementById("elecMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Election added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadElections();
  });
}

function loadRaces(){
  api("GET","/admin/api/race/list").then(function(rows){
    var el=document.getElementById("raceList");if(!el)return;
    if(!rows.length){el.innerHTML='<div class="em">No races.</div>';return;}
    var h='<table class="dt-table"><tr><th>Race</th><th>Election</th><th>Title</th><th>Candidates</th></tr>';
    rows.forEach(function(r){h+="<tr><td>"+r[0]+"</td><td>"+r[1]+"</td><td>"+r[2]+"</td><td>"+r[3]+"</td></tr>";});
    el.innerHTML=h+"</table>";
  });
}

function addRace(){
  api("POST","/admin/api/race/add",{id:g("rId"),election:g("rElec"),title:g("rTitle"),type:g("rType"),jurisdiction:g("rJur"),rule:g("rRule"),order:parseInt(g("rOrder"))||1,write_in:g("rWriteIn")==="1"}).then(function(r){
    var el=document.getElementById("raceMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Race added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadRaces();
  });
}

function addCandidate(){
  api("POST","/admin/api/candidate/add",{race:g("cRace"),legal_name:g("cLegal"),display_name:g("cDisplay"),party:g("cParty"),order:parseInt(g("cOrder"))||1}).then(function(r){
    var el=document.getElementById("candMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Candidate added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadRaces();
  });
}

function loadMeasures(){
  api("GET","/admin/api/measure/list").then(function(rows){
    var el=document.getElementById("measList");if(!el)return;
    if(!rows.length){el.innerHTML='<div class="em">No measures.</div>';return;}
    var h='<table class="dt-table"><tr><th>ID</th><th>Election</th><th>Title</th><th>Options</th></tr>';
    rows.forEach(function(r){h+="<tr><td>"+r[0]+"</td><td>"+r[1]+"</td><td>"+r[2]+"</td><td>"+(r[3]||"none")+"</td></tr>";});
    el.innerHTML=h+"</table>";
  });
}

function addMeasure(){
  api("POST","/admin/api/measure/add",{id:g("mId"),election:g("mElec"),jurisdiction:g("mJur"),title:g("mTitle"),summary:g("mSummary"),order:parseInt(g("mOrder"))||1}).then(function(r){
    var el=document.getElementById("measMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Measure added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadMeasures();
  });
}

function addOption(){
  api("POST","/admin/api/measure/add-option",{measure:g("oMeasure"),name:g("oName"),order:parseInt(g("oOrder"))||1}).then(function(r){
    var el=document.getElementById("optMsg");
    if(el)el.innerHTML=r.ok?'<div class="ok-msg">Option added.</div>':'<div class="err-msg">'+r.error+'</div>';
    loadMeasures();
  });
}

renderTabs();
renderPanel();
</script>
</div></body></html>"""

# ====================== HTTP Handler ======================
class H(BaseHTTPRequestHandler):
    def log_message(self,f,*a):print("[Admin] "+str(a[0]))
    def cip(self):return self.headers.get("X-Real-IP",self.client_address[0])

    def do_GET(self):
        p=urlparse(self.path);pa=p.path.rstrip("/");pr=parse_qs(p.query)
        if pa in("/admin","","/admin/login"):
            if gs(self.headers.get("Cookie")):self.rd("/admin/app");return
            self.htm(LOGIN_PAGE.replace("__ERR__",""));return
        if pa=="/admin/logout":
            c=SimpleCookie();c["sv_admin"]="";c["sv_admin"]["path"]="/admin";c["sv_admin"]["max-age"]="0"
            self.send_response(302);self.send_header("Set-Cookie",c["sv_admin"].OutputString());self.send_header("Location","/admin");self.end_headers();return
        ss=gs(self.headers.get("Cookie"))
        if not ss:self.rd("/admin");return
        if pa=="/admin/app":self.htm(app_page(ss));return
        if pa=="/admin/api/stats":
            tv=qreg("SELECT COUNT(*) FROM voters WHERE registration_status='ACTIVE'")
            ct=qreg("SELECT COUNT(*) FROM card_issuance_log WHERE DATE(issued_at)=CURDATE()")
            ca=qreg("SELECT COUNT(*) FROM card_issuance_log")
            el=qelec("SELECT COUNT(*) FROM elections")
            rc=qelec("SELECT COUNT(*) FROM races")
            cn=qelec("SELECT COUNT(*) FROM candidates")
            self.jsr(200,{"total_voters":tv[0][0]if tv else"0","cards_today":ct[0][0]if ct else"0","cards_total":ca[0][0]if ca else"0","elections":el[0][0]if el else"0","races":rc[0][0]if rc else"0","candidates":cn[0][0]if cn else"0"});return
        if pa=="/admin/api/card/search":
            q=pr.get("q",[""])[0].replace("'","")
            if not q:self.jsr(200,[]);return
            parts=q.split(",");last=parts[0].strip();conds=[]
            if len(parts)>=2:
                first=parts[1].strip()
                conds.append("legal_last_name LIKE '"+esc(last)+"%'")
                if first:conds.append("legal_first_name LIKE '"+esc(first)+"%'")
                if len(parts)>=3:
                    mid=parts[2].strip()
                    if mid:conds.append("COALESCE(legal_middle_name,'') LIKE '"+esc(mid)+"%'")
            else:
                conds.append("(legal_last_name LIKE '"+esc(last)+"%' OR registration_number LIKE '"+esc(last)+"%' OR CAST(voter_id AS CHAR)='"+esc(last)+"')")
            rows=qreg("SELECT voter_id,legal_first_name,COALESCE(legal_middle_name,''),legal_last_name,date_of_birth,registration_number,registration_status,precinct_id,COALESCE(mailing_address_line1,''),COALESCE(mailing_city,''),COALESCE(mailing_state,'FL'),COALESCE(mailing_zip,'') FROM voters WHERE registration_status='ACTIVE' AND "+(" AND ".join(conds))+" LIMIT 50")
            self.jsr(200,[{"voter_id":r[0],"first":r[1],"middle":r[2],"last":r[3],"dob":r[4],"reg_number":r[5],"status":r[6],"precinct":r[7],"address":r[8],"city":r[9],"state":r[10],"zip":r[11]}for r in rows]);return
        if pa=="/admin/api/card/generate":
            vid=pr.get("voter_id",[None])[0];fmt=pr.get("format",["png"])[0]
            if not vid:self.send_error(400);return
            v=gv(vid)
            if not v:self.send_error(404);return
            data,ct=gbytes(v,fmt);logi(ss["oid"],v["voter_id"],fmt,data,self.cip())
            ext="pdf"if fmt=="pdf"else"png"
            self.send_response(200);self.send_header("Content-Type",ct)
            self.send_header("Content-Disposition","inline; filename=\"voter_id_"+v["last"]+"_"+v["first"]+"_"+str(vid)+"."+ext+"\"")
            self.send_header("Content-Length",str(len(data)));self.end_headers();self.wfile.write(data);return
        if pa=="/admin/api/card/log":
            rows=qreg("SELECT cl.voter_id,CONCAT(v.legal_first_name,' ',v.legal_last_name),cl.card_format,cl.issued_at FROM card_issuance_log cl JOIN voters v ON cl.voter_id=v.voter_id ORDER BY cl.issued_at DESC LIMIT 20")
            self.jsr(200,[{"voter_id":r[0],"voter_name":r[1],"format":r[2],"issued_at":r[3]}for r in rows]);return
        if pa=="/admin/api/jurisdiction/list":self.jsr(200,qelec("SELECT jurisdiction_id,COALESCE(parent_jurisdiction_id,''),jurisdiction_type,name FROM jurisdictions ORDER BY jurisdiction_id"));return
        if pa=="/admin/api/election/list":self.jsr(200,qelec("SELECT election_id,title,election_date,status,jurisdiction_id FROM elections ORDER BY election_date DESC"));return
        if pa=="/admin/api/race/list":self.jsr(200,qelec("SELECT r.race_id,r.election_id,r.title,(SELECT COUNT(*) FROM candidates c WHERE c.race_id=r.race_id) FROM races r ORDER BY r.election_id,r.display_order"));return
        if pa=="/admin/api/measure/list":self.jsr(200,qelec("SELECT m.measure_id,m.election_id,m.title,(SELECT GROUP_CONCAT(display_name) FROM measure_options o WHERE o.measure_id=m.measure_id) FROM ballot_measures m ORDER BY m.election_id,m.display_order"));return
        self.send_error(404)

    def do_POST(self):
        pa=urlparse(self.path).path.rstrip("/")
        ln=int(self.headers.get("Content-Length",0));bd=self.rfile.read(ln).decode()
        if pa=="/admin/login":
            pm=parse_qs(bd);un=pm.get("username",[""])[0];pw=pm.get("password",[""])[0]
            tok,err=authenticate(un,pw)
            if err:self.htm(LOGIN_PAGE.replace("__ERR__",'<div class="err" style="margin-top:12px">'+err+'</div>'),401);return
            c=SimpleCookie();c["sv_admin"]=tok;c["sv_admin"]["path"]="/admin";c["sv_admin"]["httponly"]=True;c["sv_admin"]["samesite"]="Lax";c["sv_admin"]["max-age"]=str(STL)
            self.send_response(302);self.send_header("Set-Cookie",c["sv_admin"].OutputString());self.send_header("Location","/admin/app");self.end_headers();return
        ss=gs(self.headers.get("Cookie"))
        if not ss:self.jsr(401,{"ok":False,"error":"Not authenticated"});return
        try:d=json.loads(bd)if bd.strip().startswith("{")else{}
        except:d={}
        if pa=="/admin/api/jurisdiction/add":
            ok,err=eelec("INSERT INTO jurisdictions(jurisdiction_id,parent_jurisdiction_id,jurisdiction_type,name,fips_code,row_integrity_hash)VALUES('"+esc(d.get("id",""))+"',NULLIF('"+esc(d.get("parent",""))+"',''),'"+esc(d.get("type","STATE"))+"','"+esc(d.get("name",""))+"',NULLIF('"+esc(d.get("fips",""))+"',''),SHA2('"+esc(d.get("id",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        if pa=="/admin/api/election/add":
            ok,err=eelec("INSERT INTO elections(election_id,jurisdiction_id,election_type,title,election_date,polls_open_time,polls_close_time,status,row_integrity_hash)VALUES('"+esc(d.get("id",""))+"','"+esc(d.get("jurisdiction",""))+"','"+esc(d.get("type","GENERAL"))+"','"+esc(d.get("title",""))+"','"+esc(d.get("date",""))+"','"+esc(d.get("open","06:00"))+"','"+esc(d.get("close","19:00"))+"','"+esc(d.get("status","DRAFT"))+"',SHA2('"+esc(d.get("id",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        if pa=="/admin/api/race/add":
            wi="1"if d.get("write_in")else"0"
            ok,err=eelec("INSERT INTO races(race_id,election_id,title,race_type,jurisdiction_id,voting_rule,max_selections,write_in_allowed,display_order,row_integrity_hash)VALUES('"+esc(d.get("id",""))+"','"+esc(d.get("election",""))+"','"+esc(d.get("title",""))+"','"+esc(d.get("type","FEDERAL"))+"','"+esc(d.get("jurisdiction",""))+"','"+esc(d.get("rule","CHOOSE_ONE"))+"',1,"+wi+","+str(d.get("order",1))+",SHA2('"+esc(d.get("id",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        if pa=="/admin/api/candidate/add":
            ok,err=eelec("INSERT INTO candidates(race_id,legal_full_name,display_name,party,candidate_hash_salt,candidate_hash,display_order,is_qualified,is_withdrawn,row_integrity_hash)VALUES('"+esc(d.get("race",""))+"','"+esc(d.get("legal_name",""))+"','"+esc(d.get("display_name",""))+"','"+esc(d.get("party",""))+"',LEFT(SHA2(RAND(),256),32),SHA2(CONCAT('"+esc(d.get("legal_name",""))+"','"+esc(d.get("party",""))+"','"+esc(d.get("race",""))+"'),256),"+str(d.get("order",1))+",1,0,SHA2('"+esc(d.get("display_name",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        if pa=="/admin/api/measure/add":
            ok,err=eelec("INSERT INTO ballot_measures(measure_id,election_id,jurisdiction_id,title,summary,display_order,row_integrity_hash)VALUES('"+esc(d.get("id",""))+"','"+esc(d.get("election",""))+"','"+esc(d.get("jurisdiction",""))+"','"+esc(d.get("title",""))+"','"+esc(d.get("summary",""))+"',"+str(d.get("order",1))+",SHA2('"+esc(d.get("id",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        if pa=="/admin/api/measure/add-option":
            ok,err=eelec("INSERT INTO measure_options(measure_id,display_name,option_hash_salt,option_hash,display_order,row_integrity_hash)VALUES('"+esc(d.get("measure",""))+"','"+esc(d.get("name",""))+"',LEFT(SHA2(RAND(),256),32),SHA2(CONCAT('"+esc(d.get("name",""))+"','"+esc(d.get("measure",""))+"'),256),"+str(d.get("order",1))+",SHA2('"+esc(d.get("name",""))+"',256))")
            self.jsr(200,{"ok":ok,"error":err});return
        self.send_error(404)

    def htm(self,c,code=200):b=c.encode();self.send_response(code);self.send_header("Content-Type","text/html");self.send_header("Content-Length",str(len(b)));self.end_headers();self.wfile.write(b)
    def jsr(self,code,d):b=json.dumps(d).encode();self.send_response(code);self.send_header("Content-Type","application/json");self.send_header("Content-Length",str(len(b)));self.end_headers();self.wfile.write(b)
    def rd(self,u):self.send_response(302);self.send_header("Location",u);self.end_headers()

if __name__=="__main__":
    port=int(os.environ.get("PORT","8090"))
    print("[Admin] SecureVote Admin Portal on :"+str(port))
    HTTPServer(("0.0.0.0",port),H).serve_forever()
