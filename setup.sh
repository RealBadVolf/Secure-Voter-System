#!/usr/bin/env bash
# ============================================================================
# SecureVote — One-Command Setup
# ============================================================================
#   git clone https://github.com/RealBadVolf/Secure-Voter-System.git
#   cd Secure-Voter-System
#   chmod +x setup.sh && ./setup.sh
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${BLUE}[SecureVote]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; exit 1; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}  SecureVote — Election System Setup${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Check dependencies
log "Step 1: Checking dependencies..."
command -v docker &>/dev/null || fail "Docker not installed. See https://docs.docker.com/engine/install/"
ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' || echo 'found')"
docker compose version &>/dev/null || fail "Docker Compose not found."
ok "Docker Compose available"
command -v openssl &>/dev/null || fail "openssl not installed: apt install openssl"
ok "OpenSSL available"
echo ""

# Step 2: Create directories
log "Step 2: Creating data directories..."
mkdir -p data/registration data/election data/votes data/votes-readonly data/exports logs/nginx certs
if [ "$(id -u)" -eq 0 ]; then
    chown -R 999:999 data/registration data/election data/votes data/votes-readonly
fi
ok "Directories created"
echo ""

# Step 3: SSL certs
log "Step 3: Generating SSL certificates..."
if [ ! -f certs/dev.crt ]; then
    openssl req -x509 -nodes -days 365 -subj "/C=US/ST=FL/O=SecureVote/CN=securevote.local" \
        -newkey rsa:2048 -keyout certs/dev.key -out certs/dev.crt 2>/dev/null
    ok "Self-signed certificate generated"
else
    ok "Certificates already exist"
fi
echo ""

# Step 4: Port check
log "Step 4: Checking for port conflicts..."
CONFLICT=0
for p in 13306 13307 13308 13309 9443 18443 18080 18090 10443 10080; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then warn "Port ${p} in use"; CONFLICT=1; fi
done
[ "$CONFLICT" -eq 0 ] && ok "All ports available" || warn "Remap conflicting ports in docker-compose.yml"
echo ""

# Step 5: Build
log "Step 5: Building containers..."
if [ ! -f src/go.sum ]; then
    docker run --rm -v "$(pwd)/src:/build" -w /build golang:1.22-alpine sh -c "go mod tidy" 2>/dev/null
    ok "go.sum generated"
fi
docker compose build --quiet 2>&1 | tail -3
ok "All containers built"
echo ""

# Step 6: Start
log "Step 6: Starting stack..."
docker compose up -d 2>&1 | grep -v "^$"
ok "Containers started"
log "  Waiting for databases..."
for i in $(seq 1 30); do
    R=$(docker inspect --format='{{.State.Health.Status}}' sv-db-registration 2>/dev/null || echo "waiting")
    E=$(docker inspect --format='{{.State.Health.Status}}' sv-db-election 2>/dev/null || echo "waiting")
    V=$(docker inspect --format='{{.State.Health.Status}}' sv-db-votes 2>/dev/null || echo "waiting")
    [ "$R" = "healthy" ] && [ "$E" = "healthy" ] && [ "$V" = "healthy" ] && break
    printf "\r  %ds... reg=%s elec=%s votes=%s    " "$((i*2))" "$R" "$E" "$V"
    sleep 2
done
echo ""
ok "Databases healthy"
sleep 5
echo ""

# Step 7: Registration tables (CURDATE workaround)
log "Step 7: Ensuring registration tables..."
DB_REG="docker exec -i sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration"
TC=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='securevote_registration' AND table_name='voter_id_documents'" | $DB_REG -N 2>/dev/null || echo "0")
if [ "$TC" = "0" ]; then
    log "  Creating missing tables..."
    $DB_REG << 'SQL'
CREATE TABLE IF NOT EXISTS voter_id_documents(document_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,document_type ENUM('DRIVERS_LICENSE','STATE_ID','PASSPORT','MILITARY_ID','TRIBAL_ID','VOTER_ID_CARD')NOT NULL,issuing_state CHAR(2)NULL,document_number_hash CHAR(64)NOT NULL,expiration_date DATE NULL,front_scan_encrypted MEDIUMBLOB NULL,back_scan_encrypted MEDIUMBLOB NULL,scan_quality_score DECIMAL(5,4)NULL,extracted_data_hash CHAR(64)NOT NULL,document_hash CHAR(64)NOT NULL,verified_by VARCHAR(100)NULL,verified_at DATETIME NULL,is_primary BOOLEAN NOT NULL DEFAULT FALSE,is_reported_stolen BOOLEAN NOT NULL DEFAULT FALSE,stolen_reported_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(document_id),INDEX idx_voter(voter_id),CONSTRAINT fk_doc_voter FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_biometrics(biometric_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,template_encrypted MEDIUMBLOB NOT NULL,template_hash CHAR(64)NOT NULL,template_algorithm VARCHAR(50)NOT NULL,capture_quality_score DECIMAL(5,4)NOT NULL,captured_at DATETIME NOT NULL,capture_source ENUM('REGISTRATION','POLLING_PLACE','UPDATE')NOT NULL,capture_machine_id VARCHAR(50)NULL,is_active BOOLEAN NOT NULL DEFAULT TRUE,superseded_by BIGINT UNSIGNED NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(biometric_id),INDEX idx_voter_active(voter_id,is_active),CONSTRAINT fk_bio_voter FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_election_pins(pin_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NOT NULL,pin_hash CHAR(128)NOT NULL,pin_salt CHAR(32)NOT NULL,mailed_at DATETIME NULL,mailing_address_hash CHAR(64)NULL,delivery_confirmed BOOLEAN NOT NULL DEFAULT FALSE,is_active BOOLEAN NOT NULL DEFAULT TRUE,failed_attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,locked_until DATETIME NULL,last_used_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(pin_id),UNIQUE KEY uk_vep(voter_id,election_id),CONSTRAINT fk_pin_voter FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_token_issuance(issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NOT NULL,precinct_id VARCHAR(20)NOT NULL,blinded_token_hash CHAR(64)NOT NULL,issued_at DATETIME NOT NULL,issuing_machine_id VARCHAR(50)NOT NULL,auth_method ENUM('BIOMETRIC_AUTO','BIOMETRIC_MANUAL','MANUAL_OVERRIDE','PIN_FALLBACK')NOT NULL,biometric_confidence_a DECIMAL(5,4)NULL,biometric_confidence_b DECIMAL(5,4)NULL,manual_verifier_id VARCHAR(100)NULL,is_void BOOLEAN NOT NULL DEFAULT FALSE,void_reason VARCHAR(255)NULL,voided_by VARCHAR(100)NULL,voided_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(issuance_id),UNIQUE KEY uk_vte(voter_id,election_id),CONSTRAINT fk_iss_voter FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS registration_ledger(ledger_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,action ENUM('REGISTERED','STATUS_CHANGED','ADDRESS_CHANGED','NAME_CHANGED','PRECINCT_CHANGED','ID_ADDED','ID_REMOVED','BIOMETRIC_ENROLLED','BIOMETRIC_UPDATED','PIN_ISSUED','TOKEN_ISSUED','TOKEN_VOIDED','CANCELLED','REINSTATED','PURGE_FLAGGED','PURGE_CHALLENGED','PURGE_EXECUTED')NOT NULL,action_details JSON NULL,performed_by VARCHAR(100)NOT NULL,secondary_authorizer VARCHAR(100)NULL,previous_entry_hash CHAR(64)NULL,entry_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(ledger_id),INDEX idx_vc(voter_id,created_at),CONSTRAINT fk_ledger_voter FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS db_audit_log(audit_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,table_name VARCHAR(100)NOT NULL,operation ENUM('INSERT','UPDATE','DELETE')NOT NULL,primary_key_value VARCHAR(255)NOT NULL,old_values_hash CHAR(64)NULL,new_values_hash CHAR(64)NULL,changed_columns JSON NULL,db_user VARCHAR(100)NOT NULL,application_user VARCHAR(100)NULL,source_ip VARCHAR(45)NULL,previous_entry_hash CHAR(64)NULL,entry_hash CHAR(64)NOT NULL,created_at DATETIME(6)NOT NULL DEFAULT CURRENT_TIMESTAMP(6),PRIMARY KEY(audit_id),INDEX idx_tt(table_name,created_at))ENGINE=InnoDB;
SQL
    ok "Registration tables created"
else
    ok "Registration tables exist"
fi
echo ""

# Step 8: Operator tables + admin user
log "Step 8: Setting up admin portal..."
OC=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='securevote_registration' AND table_name='card_operators'" | $DB_REG -N 2>/dev/null || echo "0")
if [ "$OC" = "0" ]; then
    $DB_REG << 'SQL'
CREATE TABLE IF NOT EXISTS card_operators(operator_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,username VARCHAR(50)NOT NULL,password_hash CHAR(64)NOT NULL,password_salt CHAR(32)NOT NULL,legal_first_name VARCHAR(100)NOT NULL,legal_last_name VARCHAR(100)NOT NULL,employee_id VARCHAR(50)NOT NULL,title VARCHAR(100)NOT NULL,department VARCHAR(100)NOT NULL,email VARCHAR(200)NOT NULL,phone VARCHAR(20)NOT NULL,office_address VARCHAR(300)NOT NULL,office_city VARCHAR(100)NOT NULL,office_state CHAR(2)NOT NULL,office_zip VARCHAR(10)NOT NULL,access_level ENUM('OPERATOR','SUPERVISOR','ADMIN')NOT NULL DEFAULT 'OPERATOR',jurisdiction_id VARCHAR(50)NULL,is_active BOOLEAN NOT NULL DEFAULT TRUE,activated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,deactivated_at DATETIME NULL,deactivated_by VARCHAR(50)NULL,last_login_at DATETIME NULL,last_login_ip VARCHAR(45)NULL,failed_login_count TINYINT UNSIGNED NOT NULL DEFAULT 0,locked_until DATETIME NULL,created_by VARCHAR(50)NOT NULL DEFAULT 'SYSTEM',row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(operator_id),UNIQUE KEY uk_un(username),UNIQUE KEY uk_eid(employee_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS card_issuance_log(issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,operator_id BIGINT UNSIGNED NOT NULL,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NULL,card_format ENUM('PNG','PDF')NOT NULL,card_hash CHAR(64)NOT NULL,issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,issuer_ip VARCHAR(45)NULL,reason VARCHAR(200)NULL,row_integrity_hash CHAR(64)NOT NULL,PRIMARY KEY(issuance_id),INDEX idx_op(operator_id),INDEX idx_vt(voter_id),CONSTRAINT fk_co FOREIGN KEY(operator_id)REFERENCES card_operators(operator_id),CONSTRAINT fk_cv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
SQL
    ok "Operator tables created"
else
    ok "Operator tables exist"
fi
AC=$(echo "SELECT COUNT(*) FROM card_operators WHERE username='admin001'" | $DB_REG -N 2>/dev/null || echo "0")
if [ "$AC" = "0" ]; then
    $DB_REG << 'SQL'
SET @s=LEFT(SHA2(RAND(),256),32);
INSERT INTO card_operators(username,password_hash,password_salt,legal_first_name,legal_last_name,employee_id,title,department,email,phone,office_address,office_city,office_state,office_zip,access_level,is_active,created_by,row_integrity_hash)VALUES('admin001',SHA2(CONCAT(@s,'Admin001PWord'),256),@s,'System','Administrator','SV-EMP-0001','System Administrator','SecureVote','admin@securevote.local','(000)000-0000','N/A','N/A','FL','00000','ADMIN',TRUE,'SYSTEM',SHA2('admin001',256));
SQL
    ok "Admin user created (admin001 / Admin001PWord)"
else
    ok "Admin user exists"
fi
echo ""

# Step 9: Seed election data
log "Step 9: Seeding election data..."
DB_ELEC="docker exec -i sv-db-election mariadb -u sv_elec_user -psv-elec-pw-2026 securevote_election"
EC=$(echo "SELECT COUNT(*) FROM elections" | $DB_ELEC -N 2>/dev/null || echo "0")
if [ "$EC" = "0" ]; then
    $DB_ELEC << 'SQL'
INSERT IGNORE INTO jurisdictions VALUES('US',NULL,'FEDERAL','United States of America',NULL,SHA2('US',256)),('US-FL','US','STATE','Florida','12',SHA2('US-FL',256));
INSERT IGNORE INTO elections(election_id,jurisdiction_id,election_type,title,election_date,polls_open_time,polls_close_time,status,row_integrity_hash)VALUES('general-2026-11-03','US-FL','GENERAL','General Election — November 3, 2026','2026-11-03','06:00:00','19:00:00','ACTIVE',SHA2('general-2026-11-03',256));
INSERT IGNORE INTO races(race_id,election_id,title,race_type,jurisdiction_id,voting_rule,max_selections,write_in_allowed,display_order,row_integrity_hash)VALUES('race-us-president','general-2026-11-03','President of the United States','FEDERAL','US','CHOOSE_ONE',1,1,1,SHA2('r1',256)),('race-us-senate-fl','general-2026-11-03','United States Senator — Florida','FEDERAL','US-FL','CHOOSE_ONE',1,1,2,SHA2('r2',256)),('race-fl-governor','general-2026-11-03','Governor of Florida','STATE','US-FL','CHOOSE_ONE',1,0,3,SHA2('r3',256)),('race-fl-ag','general-2026-11-03','Attorney General of Florida','STATE','US-FL','CHOOSE_ONE',1,0,4,SHA2('r4',256)),('race-fl-cfo','general-2026-11-03','Chief Financial Officer of Florida','STATE','US-FL','CHOOSE_ONE',1,0,5,SHA2('r5',256));
INSERT IGNORE INTO candidates(race_id,legal_full_name,display_name,party,candidate_hash_salt,candidate_hash,display_order,is_qualified,is_withdrawn,row_integrity_hash)VALUES('race-us-president','Jane Elizabeth Smith','Jane Smith','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c1',256),1,1,0,SHA2('c1r',256)),('race-us-president','John Robert Jones','John Jones','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c2',256),2,1,0,SHA2('c2r',256)),('race-us-president','Maria Luisa Garcia','Maria Garcia','Independent',LEFT(SHA2(RAND(),256),32),SHA2('c3',256),3,1,0,SHA2('c3r',256)),('race-us-senate-fl','Robert Wei Chen','Robert Chen','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c4',256),1,1,0,SHA2('c4r',256)),('race-us-senate-fl','Sarah Mae Williams','Sarah Williams','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c5',256),2,1,0,SHA2('c5r',256)),('race-fl-governor','Patricia Ann Reeves','Patricia Reeves','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c6',256),1,1,0,SHA2('c6r',256)),('race-fl-governor','Michael Antonio Torres','Michael Torres','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c7',256),2,1,0,SHA2('c7r',256)),('race-fl-ag','Diane Louise Park','Diane Park','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c8',256),1,1,0,SHA2('c8r',256)),('race-fl-ag','Thomas James Burke','Thomas Burke','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c9',256),2,1,0,SHA2('c9r',256)),('race-fl-cfo','Angela Rose Martinez','Angela Martinez','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c10',256),1,1,0,SHA2('c10r',256)),('race-fl-cfo','William Earl Henderson','William Henderson','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c11',256),2,1,0,SHA2('c11r',256));
INSERT IGNORE INTO ballot_measures(measure_id,election_id,jurisdiction_id,title,summary,display_order,row_integrity_hash)VALUES('measure-fl-prop-1','general-2026-11-03','US-FL','Proposition 1: Infrastructure Bond Act','Shall the State of Florida authorize $10 billion in general obligation bonds for transportation infrastructure improvements?',6,SHA2('m1',256));
INSERT IGNORE INTO measure_options(measure_id,display_name,option_hash_salt,option_hash,display_order,row_integrity_hash)VALUES('measure-fl-prop-1','Yes',LEFT(SHA2(RAND(),256),32),SHA2('o1',256),1,SHA2('o1r',256)),('measure-fl-prop-1','No',LEFT(SHA2(RAND(),256),32),SHA2('o2',256),2,SHA2('o2r',256));
SQL
    ok "Election seeded: 5 races, 11 candidates, 1 measure"
else
    ok "Election data exists (${EC} election(s))"
fi
echo ""

# Step 10: Verify
log "Step 10: Verifying..."
RT=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='securevote_registration'" | $DB_REG -N 2>/dev/null || echo "?")
ET=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='securevote_election'" | $DB_ELEC -N 2>/dev/null || echo "?")
ok "Registration: ${RT} tables | Election: ${ET} tables"

S1=$(curl -s http://localhost:18080/api/health 2>/dev/null | grep -c healthy || echo 0)
S2=$(curl -s http://localhost:18090/admin 2>/dev/null | grep -c SecureVote || echo 0)
S3=$(curl -s http://localhost:18443/api/v1/health 2>/dev/null | grep -c healthy || echo 0)
[ "$S1" -gt 0 ] && ok "Voting simulator: running" || warn "Voting simulator: starting..."
[ "$S2" -gt 0 ] && ok "Admin portal: running" || warn "Admin portal: starting..."
[ "$S3" -gt 0 ] && ok "Verify API: running" || warn "Verify API: starting..."
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  SecureVote is running!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Voting Simulator  → http://localhost:18080"
echo "  Admin Portal      → http://localhost:18090/admin"
echo "  Verify API        → http://localhost:18443/api/v1/health"
echo ""
echo "  Admin Login:  admin001 / Admin001PWord"
echo ""
echo "  Databases:"
echo "    Registration → localhost:13306"
echo "    Election     → localhost:13307"
echo "    Votes        → localhost:13308"
echo ""
echo "  Next steps:"
echo "    Import voters:  ./scripts/import-florida.sh --help"
echo "    Demo voters:    ./scripts/seed.sh"
echo "    Read the docs:  DOCKER.md  ADMIN.md  STANDALONE.md"
echo ""
echo "  Commands:"
echo "    Stop:     docker compose down"
echo "    Start:    docker compose up -d"
echo "    Logs:     docker compose logs -f"
echo "    Rebuild:  docker compose build --no-cache && docker compose up -d"
echo ""
