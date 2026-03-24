#!/usr/bin/env python3
"""SecureVote Card Issuance System — Password-protected, 2x resolution cards, audit logging."""
import subprocess,json,os,hashlib,io,random,secrets,time
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
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"]:
        if os.path.exists(p):return ImageFont.truetype(p,size)
    return ImageFont.load_default()

def qdb(sql):
    r=subprocess.run(["mariadb","-h",os.environ.get("DB_HOST","db-registration"),"-u",os.environ.get("DB_USER","sv_reg_user"),"-p"+os.environ.get("DB_PASS","sv-reg-pw-2026"),os.environ.get("DB_NAME","securevote_registration"),"-N","-B","-e",sql],capture_output=True,text=True)
    if r.returncode!=0:return[]
    return[l.split("\t")for l in r.stdout.strip().split("\n")if l.strip()]

def edb(sql):
    subprocess.run(["mariadb","-h",os.environ.get("DB_HOST","db-registration"),"-u",os.environ.get("DB_USER","sv_reg_user"),"-p"+os.environ.get("DB_PASS","sv-reg-pw-2026"),os.environ.get("DB_NAME","securevote_registration"),"-e",sql],capture_output=True,text=True)

def auth(user,pw):
    rows=qdb("SELECT operator_id,username,password_hash,password_salt,legal_first_name,legal_last_name,access_level,is_active,failed_login_count,COALESCE(locked_until,'') FROM card_operators WHERE username='"+user.replace("'","")+"' LIMIT 1")
    if not rows:return None,"Invalid username or password"
    r=rows[0];oid,ph,sa,fn,ln,lv,ac,fc=r[0],r[2],r[3],r[4],r[5],r[6],r[7],int(r[8])
    if ac!="1":return None,"Account deactivated"
    lu=r[9]
    if lu and lu not in("","NULL","\\N"):
        try:
            if datetime.now()<datetime.strptime(lu,"%Y-%m-%d %H:%M:%S"):return None,"Locked until "+lu
        except:pass
    if hashlib.sha256((sa+pw).encode()).hexdigest()!=ph:
        nf=fc+1;lk=", locked_until=DATE_ADD(NOW(), INTERVAL 30 MINUTE)" if nf>=5 else ""
        edb("UPDATE card_operators SET failed_login_count="+str(nf)+lk+" WHERE operator_id="+str(oid))
        rem=5-nf
        if rem>0:return None,"Invalid credentials ("+str(rem)+" left)"
        return None,"Account locked 30 min"
    edb("UPDATE card_operators SET failed_login_count=0,locked_until=NULL,last_login_at=NOW() WHERE operator_id="+str(oid))
    t=secrets.token_hex(32);sessions[t]={"oid":oid,"un":r[1],"nm":fn+" "+ln,"lv":lv,"ex":time.time()+STL}
    return t,None

def gs(ch):
    if not ch:return None
    c=SimpleCookie();c.load(ch)
    if "sv_session" not in c:return None
    s=sessions.get(c["sv_session"].value)
    if not s or time.time()>s["ex"]:return None
    return s

def gv(vid):
    rows=qdb("SELECT voter_id,voter_uuid,legal_first_name,COALESCE(legal_middle_name,''),legal_last_name,COALESCE(legal_suffix,''),date_of_birth,registration_number,registration_date,registration_status,state_code,county_code,precinct_id,COALESCE(mailing_address_line1,''),COALESCE(mailing_city,''),COALESCE(mailing_state,'FL'),COALESCE(mailing_zip,'') FROM voters WHERE voter_id="+str(vid)+" LIMIT 1")
    if not rows:return None
    r=rows[0];return dict(voter_id=r[0],uuid=r[1],first=r[2],middle=r[3],last=r[4],suffix=r[5],dob=r[6],reg_number=r[7],reg_date=r[8],status=r[9],state=r[10],county=r[11],precinct=r[12],address=r[13],city=r[14],addr_state=r[15],zip=r[16])

def vhash(v):return hashlib.sha256((v['reg_number']+"|"+v['last']+"|"+v['first']+"|"+v['dob']).encode()).hexdigest()[:16].upper()

def logi(oid,vid,fmt,data,ip):
    ch=hashlib.sha256(data).hexdigest();ri=hashlib.sha256((str(oid)+"|"+str(vid)+"|"+ch).encode()).hexdigest()
    edb("INSERT INTO card_issuance_log(operator_id,voter_id,card_format,card_hash,issuer_ip,reason,row_integrity_hash)VALUES("+str(oid)+","+str(vid)+",'"+fmt.upper()+"','"+ch+"','"+str(ip or "").replace("'","")+"','NEW_ISSUANCE','"+ri+"')")

def mkqr(data,sz=400):
    q=qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H,box_size=10,border=1);q.add_data(data);q.make(fit=True)
    return q.make_image(fill_color=NAVY,back_color=WH).resize((sz,sz),Image.LANCZOS)

def draw_front(v):
    c=Image.new("RGB",(CW,CH),BG);d=ImageDraw.Draw(c)
    d.rectangle([(0,0),(CW,144)],fill=NAVY)
    for i in range(13):d.line([(CW-240,8+i*10),(CW-20,8+i*10)],fill=(200,60,60)if i%2==0 else WH,width=6)
    d.rectangle([(CW-240,8),(CW-148,76)],fill=(20,35,90))
    for sx in range(CW-232,CW-152,20):
        for sy in range(16,72,16):d.text((sx,sy),"*",fill=WH,font=lf(12))
    d.text((40,16),"SECUREVOTE",fill=WH,font=lf(56,True))
    d.text((420,28),"VOTER IDENTIFICATION CARD",fill=CB,font=lf(28,True))
    d.text((40,84),"UNITED STATES OF AMERICA",fill=(150,160,180),font=lf(28,True))
    d.rectangle([(0,144),(CW,152)],fill=CB)
    px,py,pw,ph=40,180,280,350;d.rectangle([(px,py),(px+pw,py+ph)],fill=LG,outline=MG,width=2)
    cx,cy=px+pw//2,py+ph//2-20;d.ellipse([(cx-50,cy-60),(cx+50,cy+40)],fill=MG);d.ellipse([(cx-90,cy+40),(cx+90,cy+160)],fill=MG)
    d.text((px+80,py+ph-40),"PHOTO",fill=DG,font=lf(22))
    nx=360;nm=v['last'].upper()+", "+v['first'].upper()
    if v['middle']:nm+=" "+v['middle'][0].upper()+"."
    if v['suffix']:nm+=" "+v['suffix']
    d.text((nx,170),"NAME",fill=MG,font=lf(22,True));d.text((nx,198),nm,fill=NAVY,font=lf(58,True))
    bc=GR if v['status']=='ACTIVE'else RD;bx=CW-220
    d.rounded_rectangle([(bx,172),(bx+180,220)],radius=8,fill=bc);d.text((bx+20,180),v['status'],fill=WH,font=lf(28,True))
    fy=290;c1,c2=360,1000
    d.text((c1,fy),"DATE OF BIRTH",fill=MG,font=lf(22,True));d.text((c1,fy+28),v['dob'],fill=DG,font=lf(32,True))
    d.text((c2,fy),"REGISTRATION NO.",fill=MG,font=lf(22,True));d.text((c2,fy+28),v['reg_number'],fill=DG,font=lf(32,True))
    fy+=84;d.text((c1,fy),"REGISTERED",fill=MG,font=lf(22,True));d.text((c1,fy+28),v['reg_date'],fill=DG,font=lf(28))
    d.text((c2,fy),"COUNTY",fill=MG,font=lf(22,True));d.text((c2,fy+28),v['county'],fill=DG,font=lf(28))
    fy+=84;d.text((c1,fy),"ADDRESS",fill=MG,font=lf(22,True))
    ad=v['address'][:38]+"..."if len(v['address'])>40 else v['address']
    d.text((c1,fy+28),ad,fill=DG,font=lf(28));d.text((c1,fy+60),v['city']+", "+v['addr_state']+" "+v['zip'],fill=DG,font=lf(28))
    d.text((c2,fy),"PRECINCT",fill=MG,font=lf(22,True));d.text((c2,fy+28),v['precinct'],fill=DG,font=lf(32,True))
    d.rectangle([(0,CH-100),(CW,CH)],fill=NAVY);vh=vhash(v)
    d.text((40,CH-84),"VERIFICATION",fill=MG,font=lf(18));d.text((40,CH-60),vh,fill=(180,190,210),font=lf(28,True))
    d.text((400,CH-84),"STATE",fill=MG,font=lf(18));d.text((400,CH-60),v['state'],fill=(180,190,210),font=lf(28,True))
    d.text((CW-400,CH-84),"ISSUED",fill=MG,font=lf(18));d.text((CW-400,CH-60),datetime.now().strftime("%Y-%m-%d"),fill=(180,190,210),font=lf(28))
    d.rectangle([(0,CH-8),(CW,CH)],fill=CB);return c

def draw_back(v):
    c=Image.new("RGB",(CW,CH),BG);d=ImageDraw.Draw(c)
    d.rectangle([(0,0),(CW,80)],fill=NAVY);d.text((40,16),"SECUREVOTE \u2014 VOTER IDENTIFICATION",fill=WH,font=lf(36,True))
    d.rectangle([(0,80),(CW,86)],fill=CB)
    qd=json.dumps({"sv":"1.0","reg":v['reg_number'],"uuid":v['uuid'],"hash":vhash(v),"state":v['state'],"county":v['county'],"precinct":v['precinct']},separators=(',',':'))
    c.paste(mkqr(qd,400),(60,120));d.text((140,530),"SCAN TO VERIFY",fill=MG,font=lf(22))
    d.rectangle([(0,CH-160),(CW,CH-90)],fill=(30,30,30));random.seed(hash(v['reg_number']));x=40
    while x<CW-40:
        w=random.choice([2,2,4,2,6,2,4])
        if random.random()>.4:d.rectangle([(x,CH-152),(x+w,CH-98)],fill=(200,200,200))
        x+=w+random.choice([2,4,2])
    m1=("SVID<<"+v['last'].upper()+"<"+v['first'].upper()+"<"+v['reg_number'])[:50].ljust(50,'<')
    m2=(v['state']+v['county']+v['precinct']+"<"+v['dob'].replace('-','')+"<"+vhash(v))[:50].ljust(50,'<')
    d.text((40,CH-84),m1,fill=MG,font=lf(20));d.text((40,CH-56),m2,fill=MG,font=lf(20))
    ix,iy=520,130;d.text((ix,iy),"This card is the property of the",fill=DG,font=lf(22));d.text((ix,iy+28),"SecureVote Election Authority.",fill=DG,font=lf(22))
    iy+=72;d.text((ix,iy),"INSTRUCTIONS",fill=NAVY,font=lf(26,True));iy+=40
    for ln in["1. Present this card at your polling place","2. Insert into the ID scanner slot","3. Look at the camera for verification","4. Follow on-screen voting instructions"]:d.text((ix,iy),ln,fill=DG,font=lf(22));iy+=32
    iy+=24;d.text((ix,iy),"If found, return to any polling place",fill=MG,font=lf(18));d.text((ix,iy+24),"or post office. Do not destroy.",fill=MG,font=lf(18))
    iy+=60;d.text((ix,iy),"Card ID: SV-"+str(v['voter_id'])+"-"+vhash(v)[:8],fill=MG,font=lf(22))
    d.rectangle([(0,CH-8),(CW,CH)],fill=CB);return c

def gbytes(v,fmt="png"):
    fr=draw_front(v);bk=draw_back(v);buf=io.BytesIO()
    if fmt=="pdf":fr.save(buf,"PDF",resolution=DPI,save_all=True,append_images=[bk]);return buf.getvalue(),"application/pdf"
    combo=Image.new("RGB",(CW,CH*2+40),WH);combo.paste(fr,(0,0));combo.paste(bk,(0,CH+40))
    combo.save(buf,"PNG",dpi=(DPI,DPI));return buf.getvalue(),"image/png"

# ---- HTML ----
LOGIN='''<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SecureVote Card Login</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&display=swap');*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Atkinson Hyperlegible',system-ui,sans-serif;background:#0c0f19;color:#e2e8f0;min-height:100vh;display:flex;justify-content:center;align-items:center}.lb{width:100%;max-width:400px;padding:32px;background:#141724;border-radius:12px;border:1px solid #2a2d3e;text-align:center}h1{font-size:20px;color:#fff}h1 span{color:#2563EB}.sub{color:#6b7280;font-size:13px;margin:4px 0 24px}.sh{width:56px;height:56px;border-radius:50%;background:#1B2A4A;display:flex;align-items:center;justify-content:center;margin:0 auto 16px;font-size:24px}label{display:block;font-size:12px;font-weight:700;color:#6b7280;margin-bottom:4px;margin-top:12px;text-align:left}input{width:100%;padding:12px 14px;border:2px solid #2a2d3e;border-radius:8px;font-size:15px;font-family:inherit;background:#1a1d2e;color:#e2e8f0;outline:none}input:focus{border-color:#2563EB}.btn{width:100%;padding:14px;border-radius:8px;font-size:15px;font-weight:700;cursor:pointer;border:none;font-family:inherit;background:#2563EB;color:#fff;margin-top:20px}.err{background:#450a0a;border:1px solid #7f1d1d;color:#fca5a5;padding:10px;border-radius:8px;font-size:13px;margin-top:12px}.nt{font-size:11px;color:#4b5563;margin-top:16px}</style></head><body>
<div class="lb"><div class="sh">&#x1f6e1;</div><h1>SECURE<span>VOTE</span></h1><div class="sub">Card Issuance System</div>
<form method="POST" action="/idcard/login"><label>USERNAME</label><input type="text" name="username" required autofocus><label>PASSWORD</label><input type="password" name="password" required><button type="submit" class="btn">Sign In</button></form>
__ERR__<div class="nt">All access is logged and monitored.</div></div></body></html>'''

APP='''<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SecureVote Card Issuance</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&display=swap');*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Atkinson Hyperlegible',system-ui,sans-serif;background:#0c0f19;color:#e2e8f0;min-height:100vh;display:flex;justify-content:center}.w{width:100%;max-width:800px;padding:20px}h1{font-size:22px;color:#fff}h1 span{color:#2563EB}h2{font-size:16px;color:#fff;margin:16px 0 8px}.hb{background:#1B2A4A;padding:16px 20px;border-radius:10px;margin-bottom:20px;display:flex;justify-content:space-between;align-items:center}.ui{text-align:right;font-size:12px;color:#94a3b8}.ui .nm{font-weight:700;color:#fff;font-size:14px}.sb{display:flex;gap:8px;margin-bottom:16px}input{flex:1;padding:12px 14px;border:2px solid #333;border-radius:8px;font-size:15px;font-family:inherit;background:#1a1d2e;color:#e2e8f0;outline:none}input:focus{border-color:#2563EB}button{padding:12px 20px;border-radius:8px;font-size:14px;font-weight:700;cursor:pointer;border:none;font-family:inherit;background:#2563EB;color:#fff}.bs{padding:8px 14px;font-size:12px}.bo{background:transparent;color:#2563EB;border:2px solid #2563EB}.br{background:transparent;color:#f87171;border:1px solid #7f1d1d;font-size:12px;padding:6px 12px;text-decoration:none;border-radius:6px}.vr{padding:14px 16px;background:#1a1d2e;border:1px solid #2a2d3e;border-radius:8px;margin-bottom:6px;display:flex;justify-content:space-between;align-items:center}.vr:hover{border-color:#2563EB}.nm2{font-weight:700;color:#fff;font-size:15px}.dt{font-size:12px;color:#6b7280;margin-top:2px}.cp{text-align:center;margin:20px 0}.cp img{max-width:100%;border-radius:8px;box-shadow:0 4px 24px rgba(0,0,0,.4)}.dl{display:flex;gap:8px;justify-content:center;margin-top:12px}.tg{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700}.tg-g{background:#166534;color:#fff}.em{color:#6b7280;font-size:14px;padding:20px;text-align:center}.le{padding:8px 12px;background:#111322;border-radius:6px;margin-bottom:4px;font-size:12px;display:flex;justify-content:space-between}.le .tm{color:#6b7280}.st{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:16px}.sc{background:#1a1d2e;border-radius:8px;padding:12px;text-align:center}.sc .v{font-size:22px;font-weight:700;color:#fff}.sc .l{font-size:11px;color:#6b7280;margin-top:2px}</style></head><body>
<div class="w"><div class="hb"><div><h1>SECURE<span>VOTE</span> Card Issuance</h1><div style="color:#6b7280;font-size:13px">Voter ID Card Generation System</div></div><div class="ui"><div class="nm">__NM__</div><div>__LV__ &middot; __UN__</div><a href="/idcard/logout" class="br" style="display:inline-block;margin-top:4px">Sign Out</a></div></div>
<div class="st" id="st"></div><div class="sb"><input type="text" id="q" placeholder="Search voter by name, ID, or registration number..." autofocus><button onclick="S()">Search</button></div><div id="rs"></div><div id="pv" class="cp"></div><h2>Recent Issuances</h2><div id="lg"></div></div>
<script>
const q=document.getElementById('q');q.addEventListener('keydown',e=>{if(e.key==='Enter')S()});LS();LL();
async function LS(){const r=await fetch('/idcard/api/stats');const s=await r.json();document.getElementById('st').innerHTML='<div class="sc"><div class="v">'+s.total_voters+'</div><div class="l">Registered</div></div><div class="sc"><div class="v">'+s.cards_issued_today+'</div><div class="l">Cards Today</div></div><div class="sc"><div class="v">'+s.cards_issued_total+'</div><div class="l">Total Cards</div></div>';}
async function LL(){const r=await fetch('/idcard/api/log');const l=await r.json();let h='';if(!l.length)h='<div class="em">No cards issued yet.</div>';else l.forEach(e=>{h+='<div class="le"><span>'+e.voter_name+' ('+e.voter_id+')</span><span>'+e.format+'</span><span class="tm">'+e.issued_at+'</span></div>';});document.getElementById('lg').innerHTML=h;}
async function S(){const v=q.value.trim();if(!v)return;const r=await fetch('/idcard/api/search?q='+encodeURIComponent(v));const vs=await r.json();let h='';if(!vs.length)h='<div class="em">No voters found.</div>';else vs.forEach(v=>{h+='<div class="vr"><div><div class="nm2">'+v.last+', '+v.first+(v.middle?' '+v.middle:'')+' <span class="tg tg-g">'+v.status+'</span></div><div class="dt">ID: '+v.voter_id+' | DOB: '+v.dob+' | '+v.reg_number+' | Precinct '+v.precinct+'</div><div class="dt">'+v.address+', '+v.city+' '+v.state+' '+v.zip+'</div></div><div style="display:flex;gap:6px"><button class="bs" onclick="G('+v.voter_id+',\'png\')">PNG</button><button class="bs bo" onclick="G('+v.voter_id+',\'pdf\')">PDF</button></div></div>';});document.getElementById('rs').innerHTML=h;document.getElementById('pv').innerHTML='';}
function G(id,f){if(f==='pdf'){window.open('/idcard/api/generate?voter_id='+id+'&format=pdf');setTimeout(()=>{LL();LS()},1500);return;}const u='/idcard/api/generate?voter_id='+id+'&format=png&t='+Date.now();document.getElementById('pv').innerHTML='<img src="'+u+'"><div class="dl"><a href="'+u+'" download><button class="bs">Download PNG</button></a><a href="/idcard/api/generate?voter_id='+id+'&format=pdf" download><button class="bs bo">Download PDF</button></a></div>';setTimeout(()=>{LL();LS()},1500);}
</script></body></html>'''

class H(BaseHTTPRequestHandler):
    def log_message(self,f,*a):print("[IDCard] "+str(a[0]))
    def cip(self):return self.headers.get("X-Real-IP",self.client_address[0])
    def do_GET(self):
        p=urlparse(self.path);pa=p.path.rstrip("/");pr=parse_qs(p.query)
        if pa in("/idcard","","/idcard/login"):
            if gs(self.headers.get("Cookie")):self.rd("/idcard/app");return
            self.htm(LOGIN.replace("__ERR__",""));return
        if pa=="/idcard/logout":
            c=SimpleCookie();c["sv_session"]="";c["sv_session"]["path"]="/idcard";c["sv_session"]["max-age"]="0"
            self.send_response(302);self.send_header("Set-Cookie",c["sv_session"].OutputString());self.send_header("Location","/idcard");self.end_headers();return
        ss=gs(self.headers.get("Cookie"))
        if not ss:self.rd("/idcard");return
        if pa=="/idcard/app":self.htm(APP.replace("__NM__",ss["nm"]).replace("__LV__",ss["lv"]).replace("__UN__",ss["un"]));return
        if pa=="/idcard/api/search":
            q=pr.get("q",[""])[0].replace("'","")
            if not q:self.jsr(200,[]);return
            rows=qdb("SELECT voter_id,legal_first_name,COALESCE(legal_middle_name,''),legal_last_name,date_of_birth,registration_number,registration_status,precinct_id,COALESCE(mailing_address_line1,''),COALESCE(mailing_city,''),COALESCE(mailing_state,'FL'),COALESCE(mailing_zip,'') FROM voters WHERE registration_status='ACTIVE' AND(legal_last_name LIKE'%"+q+"%'OR legal_first_name LIKE'%"+q+"%'OR registration_number LIKE'%"+q+"%'OR CAST(voter_id AS CHAR)='"+q+"')LIMIT 20")
            self.jsr(200,[{"voter_id":r[0],"first":r[1],"middle":r[2],"last":r[3],"dob":r[4],"reg_number":r[5],"status":r[6],"precinct":r[7],"address":r[8],"city":r[9],"state":r[10],"zip":r[11]}for r in rows]);return
        if pa=="/idcard/api/generate":
            vid=pr.get("voter_id",[None])[0];fmt=pr.get("format",["png"])[0]
            if not vid:self.send_error(400);return
            v=gv(vid)
            if not v:self.send_error(404);return
            data,ct=gbytes(v,fmt);logi(ss["oid"],v["voter_id"],fmt,data,self.cip())
            ext="pdf"if fmt=="pdf"else"png"
            self.send_response(200);self.send_header("Content-Type",ct)
            self.send_header("Content-Disposition","inline; filename=\"voter_id_"+v["last"]+"_"+v["first"]+"_"+str(vid)+"."+ext+"\"")
            self.send_header("Content-Length",str(len(data)));self.end_headers();self.wfile.write(data);return
        if pa=="/idcard/api/stats":
            tv=qdb("SELECT COUNT(*)FROM voters WHERE registration_status='ACTIVE'")
            ct=qdb("SELECT COUNT(*)FROM card_issuance_log WHERE DATE(issued_at)=CURDATE()")
            ca=qdb("SELECT COUNT(*)FROM card_issuance_log")
            self.jsr(200,{"total_voters":tv[0][0]if tv else"0","cards_issued_today":ct[0][0]if ct else"0","cards_issued_total":ca[0][0]if ca else"0"});return
        if pa=="/idcard/api/log":
            rows=qdb("SELECT cl.voter_id,CONCAT(v.legal_first_name,' ',v.legal_last_name),cl.card_format,cl.issued_at FROM card_issuance_log cl JOIN voters v ON cl.voter_id=v.voter_id ORDER BY cl.issued_at DESC LIMIT 20")
            self.jsr(200,[{"voter_id":r[0],"voter_name":r[1],"format":r[2],"issued_at":r[3]}for r in rows]);return
        if pa=="/idcard/api/health":self.jsr(200,{"status":"healthy"});return
        self.send_error(404)
    def do_POST(self):
        pa=urlparse(self.path).path.rstrip("/")
        if pa=="/idcard/login":
            ln=int(self.headers.get("Content-Length",0));bd=self.rfile.read(ln).decode();pm=parse_qs(bd)
            un=pm.get("username",[""])[0];pw=pm.get("password",[""])[0]
            tok,err=auth(un,pw)
            if err:self.htm(LOGIN.replace("__ERR__",'<div class="err">'+err+'</div>'),401);return
            c=SimpleCookie();c["sv_session"]=tok;c["sv_session"]["path"]="/idcard";c["sv_session"]["httponly"]=True;c["sv_session"]["samesite"]="Lax";c["sv_session"]["max-age"]=str(STL)
            self.send_response(302);self.send_header("Set-Cookie",c["sv_session"].OutputString());self.send_header("Location","/idcard/app");self.end_headers();return
        self.send_error(404)
    def htm(self,c,code=200):b=c.encode();self.send_response(code);self.send_header("Content-Type","text/html");self.send_header("Content-Length",str(len(b)));self.end_headers();self.wfile.write(b)
    def jsr(self,code,d):b=json.dumps(d).encode();self.send_response(code);self.send_header("Content-Type","application/json");self.send_header("Content-Length",str(len(b)));self.end_headers();self.wfile.write(b)
    def rd(self,u):self.send_response(302);self.send_header("Location",u);self.end_headers()

if __name__=="__main__":
    port=int(os.environ.get("PORT","8090"));print("[IDCard] Card Issuance System on :"+str(port));HTTPServer(("0.0.0.0",port),H).serve_forever()

