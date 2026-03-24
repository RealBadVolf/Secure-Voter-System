#!/usr/bin/env bash
# ============================================================================
# SecureVote — Interactive Setup
# ============================================================================
#
#   git clone https://github.com/RealBadVolf/Secure-Voter-System.git
#   cd Secure-Voter-System
#   chmod +x setup.sh && ./setup.sh
#
# Supports:
#   - Docker deployment (single machine or distributed)
#   - Standalone deployment (auto-installs dependencies)
#   - Component selection for multi-server architectures
#
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${BLUE}[SecureVote]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }

# Ask user y/n with default
ask_yn() {
    local prompt="$1" default="${2:-n}"
    local yn
    if [ "$default" = "y" ]; then
        read -p "  $prompt [Y/n]: " yn
        [[ ! "$yn" =~ ^[nN] ]]
    else
        read -p "  $prompt [y/N]: " yn
        [[ "$yn" =~ ^[yY] ]]
    fi
}

# Detect package manager
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
    else
        PKG_MGR="unknown"
    fi
}

# Install a package
pkg_install() {
    local pkg="$1"
    case "$PKG_MGR" in
        apt)    sudo apt-get install -y "$pkg" ;;
        dnf)    sudo dnf install -y "$pkg" ;;
        yum)    sudo yum install -y "$pkg" ;;
        pacman) sudo pacman -S --noconfirm "$pkg" ;;
        *)      fail "Unknown package manager. Install $pkg manually." ;;
    esac
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}${BLUE}  SECUREVOTE — Election System Installer${NC}"
echo -e "  Open-source end-to-end verifiable election system"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

detect_pkg_manager

# ============================================================================
# Deployment Mode Selection
# ============================================================================
header "STEP 1: Deployment Mode"
echo "  How would you like to deploy SecureVote on this machine?"
echo ""
echo -e "  ${BOLD}1) Docker${NC} (recommended)"
echo "     Uses Docker Compose to run each component in isolated containers."
echo "     Ideal for development, demos, and single-server deployments."
echo ""
echo -e "  ${BOLD}2) Standalone${NC}"
echo "     Installs components directly on this machine with no containers."
echo "     Ideal for production multi-server deployments."
echo "     Dependencies will be installed automatically if missing."
echo ""
echo -e "  ${BOLD}3) Quick Start${NC} (Docker — install everything, no questions)"
echo ""

while true; do
    read -p "  Select mode [1/2/3]: " MODE
    case "$MODE" in
        1|docker|Docker) MODE="docker"; break ;;
        2|standalone|Standalone) MODE="standalone"; break ;;
        3|quick|Quick) MODE="quick"; break ;;
        *) echo "  Please enter 1, 2, or 3." ;;
    esac
done
echo ""

# ============================================================================
# Component Selection
# ============================================================================
INST_DB_REG=0; INST_DB_ELEC=0; INST_DB_VOTES=0; INST_DB_RO=0
INST_SV_MACHINE=0; INST_SV_ADMIN_PORTAL=0; INST_SV_VERIFY=0
INST_SV_ADMIN_API=0; INST_SV_TABULATOR=0; INST_SV_NGINX=0
INST_ALL=0

if [ "$MODE" = "quick" ]; then
    INST_ALL=1; MODE="docker"
else
    header "STEP 2: Component Selection"
    echo "  Select which components to install on THIS machine."
    echo "  In a production deployment, spread these across multiple servers."
    echo ""
    echo -e "  ${BOLD}a) All Components${NC} (full system on one machine)"
    echo ""
    echo -e "  ${CYAN}── Databases ──${NC}"
    echo "  1) Registration DB     Voter identity, IDs, biometrics, PINs"
    echo "  2) Election DB         Elections, races, candidates, ballot definitions"
    echo "  3) Votes DB            Cast ballots, Merkle trees, tabulation results"
    echo "  4) Votes Read-Only DB  Read-only replica for public verification"
    echo ""
    echo -e "  ${CYAN}── Application Services ──${NC}"
    echo "  5) Voting Machine      Web-based voting simulator with full ballot flow"
    echo "  6) Admin Portal        Card issuance + election management (Python)"
    echo "  7) Verification API    Public vote verification endpoint"
    echo "  8) Admin API           Election administration REST API"
    echo "  9) Tabulator           On-demand vote tabulation service"
    echo ""
    echo -e "  ${CYAN}── Infrastructure ──${NC}"
    echo "  0) Nginx Proxy         Reverse proxy with TLS"
    echo ""

    read -p "  Enter selections (e.g. 'a' for all, or '1,2,5,6'): " SELECTIONS

    if [[ "$SELECTIONS" =~ [aA] ]]; then
        INST_ALL=1
    else
        IFS=',' read -ra SEL_ARRAY <<< "$SELECTIONS"
        for sel in "${SEL_ARRAY[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            case "$sel" in
                1) INST_DB_REG=1 ;;
                2) INST_DB_ELEC=1 ;;
                3) INST_DB_VOTES=1 ;;
                4) INST_DB_RO=1 ;;
                5) INST_SV_MACHINE=1 ;;
                6) INST_SV_ADMIN_PORTAL=1 ;;
                7) INST_SV_VERIFY=1 ;;
                8) INST_SV_ADMIN_API=1 ;;
                9) INST_SV_TABULATOR=1 ;;
                0) INST_SV_NGINX=1 ;;
                *) warn "Unknown selection: $sel" ;;
            esac
        done
    fi
fi

if [ "$INST_ALL" -eq 1 ]; then
    INST_DB_REG=1; INST_DB_ELEC=1; INST_DB_VOTES=1; INST_DB_RO=1
    INST_SV_MACHINE=1; INST_SV_ADMIN_PORTAL=1; INST_SV_VERIFY=1
    INST_SV_ADMIN_API=1; INST_SV_TABULATOR=1; INST_SV_NGINX=1
fi

# Derived flags
NEED_MARIADB=0; NEED_GO=0; NEED_PYTHON=0; NEED_NGINX=0; NEED_OPENSSL=0
[ "$INST_DB_REG" -eq 1 ] || [ "$INST_DB_ELEC" -eq 1 ] || [ "$INST_DB_VOTES" -eq 1 ] || [ "$INST_DB_RO" -eq 1 ] && NEED_MARIADB=1
[ "$INST_SV_MACHINE" -eq 1 ] || [ "$INST_SV_VERIFY" -eq 1 ] || [ "$INST_SV_ADMIN_API" -eq 1 ] || [ "$INST_SV_TABULATOR" -eq 1 ] && NEED_GO=1
[ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && NEED_PYTHON=1
[ "$INST_SV_NGINX" -eq 1 ] && { NEED_NGINX=1; NEED_OPENSSL=1; }

# Show summary
header "Installation Summary"
echo -e "  Mode: ${BOLD}${MODE}${NC}"
echo ""
echo "  Components:"
[ "$INST_DB_REG" -eq 1 ]          && echo -e "    ${GREEN}✓${NC} Registration Database"
[ "$INST_DB_ELEC" -eq 1 ]         && echo -e "    ${GREEN}✓${NC} Election Database"
[ "$INST_DB_VOTES" -eq 1 ]        && echo -e "    ${GREEN}✓${NC} Votes Database"
[ "$INST_DB_RO" -eq 1 ]           && echo -e "    ${GREEN}✓${NC} Votes Read-Only Database"
[ "$INST_SV_MACHINE" -eq 1 ]      && echo -e "    ${GREEN}✓${NC} Voting Machine Simulator"
[ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && echo -e "    ${GREEN}✓${NC} Admin Portal"
[ "$INST_SV_VERIFY" -eq 1 ]       && echo -e "    ${GREEN}✓${NC} Verification API"
[ "$INST_SV_ADMIN_API" -eq 1 ]    && echo -e "    ${GREEN}✓${NC} Admin API"
[ "$INST_SV_TABULATOR" -eq 1 ]    && echo -e "    ${GREEN}✓${NC} Tabulator"
[ "$INST_SV_NGINX" -eq 1 ]        && echo -e "    ${GREEN}✓${NC} Nginx Reverse Proxy"
echo ""

# Cross-server dependency warnings
if [ "$INST_SV_MACHINE" -eq 1 ] && { [ "$INST_DB_REG" -eq 0 ] || [ "$INST_DB_ELEC" -eq 0 ] || [ "$INST_DB_VOTES" -eq 0 ]; }; then
    warn "Voting Machine needs Registration, Election, and Votes databases."
fi
if [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && { [ "$INST_DB_REG" -eq 0 ] || [ "$INST_DB_ELEC" -eq 0 ]; }; then
    warn "Admin Portal needs Registration and Election databases."
fi
if [ "$INST_SV_VERIFY" -eq 1 ] && [ "$INST_DB_RO" -eq 0 ]; then
    warn "Verification API needs the Votes Read-Only database."
fi

read -p "  Proceed? [Y/n] " CONFIRM
if [[ "$CONFIRM" =~ ^[nN] ]]; then echo "  Aborted."; exit 0; fi
echo ""

# ============================================================================
# Remote Database Configuration
# ============================================================================
DB_REG_HOST="localhost"; DB_ELEC_HOST="localhost"; DB_VOTES_HOST="localhost"; DB_RO_HOST="localhost"
DB_REG_PORT="3306"; DB_ELEC_PORT="3306"; DB_VOTES_PORT="3306"; DB_RO_PORT="3306"

NEEDS_REMOTE=0
if { [ "$INST_SV_MACHINE" -eq 1 ] || [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] || [ "$INST_SV_VERIFY" -eq 1 ] || [ "$INST_SV_ADMIN_API" -eq 1 ]; } && \
   { [ "$INST_DB_REG" -eq 0 ] || [ "$INST_DB_ELEC" -eq 0 ] || [ "$INST_DB_VOTES" -eq 0 ]; }; then
    NEEDS_REMOTE=1
fi

if [ "$NEEDS_REMOTE" -eq 1 ]; then
    header "Remote Database Configuration"
    echo "  Some databases are not being installed here."
    echo "  Enter the host:port for each remote database."
    echo "  Press Enter for defaults."
    echo ""

    if [ "$INST_DB_REG" -eq 0 ] && { [ "$INST_SV_MACHINE" -eq 1 ] || [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] || [ "$INST_SV_ADMIN_API" -eq 1 ]; }; then
        read -p "  Registration DB host [localhost]: " DB_REG_HOST; DB_REG_HOST=${DB_REG_HOST:-localhost}
        read -p "  Registration DB port [3306]: " DB_REG_PORT; DB_REG_PORT=${DB_REG_PORT:-3306}
    fi
    if [ "$INST_DB_ELEC" -eq 0 ] && { [ "$INST_SV_MACHINE" -eq 1 ] || [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] || [ "$INST_SV_ADMIN_API" -eq 1 ]; }; then
        read -p "  Election DB host [localhost]: " DB_ELEC_HOST; DB_ELEC_HOST=${DB_ELEC_HOST:-localhost}
        read -p "  Election DB port [3306]: " DB_ELEC_PORT; DB_ELEC_PORT=${DB_ELEC_PORT:-3306}
    fi
    if [ "$INST_DB_VOTES" -eq 0 ] && { [ "$INST_SV_MACHINE" -eq 1 ] || [ "$INST_SV_TABULATOR" -eq 1 ]; }; then
        read -p "  Votes DB host [localhost]: " DB_VOTES_HOST; DB_VOTES_HOST=${DB_VOTES_HOST:-localhost}
        read -p "  Votes DB port [3306]: " DB_VOTES_PORT; DB_VOTES_PORT=${DB_VOTES_PORT:-3306}
    fi
    if [ "$INST_DB_RO" -eq 0 ] && [ "$INST_SV_VERIFY" -eq 1 ]; then
        read -p "  Votes Read-Only DB host [localhost]: " DB_RO_HOST; DB_RO_HOST=${DB_RO_HOST:-localhost}
        read -p "  Votes Read-Only DB port [3306]: " DB_RO_PORT; DB_RO_PORT=${DB_RO_PORT:-3306}
    fi
    echo ""
fi

# Docker mode uses container names
if [ "$MODE" = "docker" ]; then
    [ "$INST_DB_REG" -eq 1 ]   && DB_REG_HOST="db-registration" && DB_REG_PORT="3306"
    [ "$INST_DB_ELEC" -eq 1 ]  && DB_ELEC_HOST="db-election" && DB_ELEC_PORT="3306"
    [ "$INST_DB_VOTES" -eq 1 ] && DB_VOTES_HOST="db-votes" && DB_VOTES_PORT="3306"
    [ "$INST_DB_RO" -eq 1 ]    && DB_RO_HOST="db-votes-readonly" && DB_RO_PORT="3306"
fi

# ============================================================================
# DOCKER MODE
# ============================================================================
if [ "$MODE" = "docker" ]; then

    header "Checking Docker Dependencies..."

    # Docker
    if ! command -v docker &>/dev/null; then
        warn "Docker not found."
        if ask_yn "Install Docker?"; then
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker "$USER" 2>/dev/null || true
            ok "Docker installed"
        else
            fail "Docker is required for Docker mode."
        fi
    else
        ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' || echo 'found')"
    fi

    # Docker Compose
    if ! docker compose version &>/dev/null; then
        warn "Docker Compose plugin not found."
        if ask_yn "Install Docker Compose plugin?"; then
            sudo apt-get update -qq && sudo apt-get install -y docker-compose-plugin 2>/dev/null || \
            sudo dnf install -y docker-compose-plugin 2>/dev/null || \
            fail "Could not auto-install. See https://docs.docker.com/compose/install/"
            ok "Docker Compose installed"
        else
            fail "Docker Compose is required."
        fi
    else
        ok "Docker Compose available"
    fi

    # OpenSSL for certs
    if ! command -v openssl &>/dev/null; then
        log "Installing openssl..."
        pkg_install openssl
        ok "OpenSSL installed"
    fi
    echo ""

    # Create directories
    header "Creating directories..."
    mkdir -p data/registration data/election data/votes data/votes-readonly data/exports logs/nginx certs
    if [ "$(id -u)" -eq 0 ]; then
        chown -R 999:999 data/registration data/election data/votes data/votes-readonly 2>/dev/null || true
    fi
    ok "Directories created"

    # SSL certs
    if [ "$INST_SV_NGINX" -eq 1 ] && [ ! -f certs/dev.crt ]; then
        openssl req -x509 -nodes -days 365 -subj "/C=US/ST=FL/O=SecureVote/CN=securevote.local" \
            -newkey rsa:2048 -keyout certs/dev.key -out certs/dev.crt 2>/dev/null
        ok "SSL certificate generated"
    fi

    # go.sum
    if [ ! -f src/go.sum ]; then
        log "Generating go.sum..."
        docker run --rm -v "$(pwd)/src:/build" -w /build golang:1.22-alpine sh -c "go mod tidy" 2>/dev/null
        ok "go.sum generated"
    fi

    # Port check
    header "Checking for port conflicts..."
    CONFLICT=0
    PORT_MAP="13306:Registration_DB 13307:Election_DB 13308:Votes_DB 13309:Votes_RO_DB 18080:Voting_Machine 18090:Admin_Portal 9443:Admin_API 18443:Verify_API 10443:Nginx_HTTPS 10080:Nginx_HTTP"
    for pm in $PORT_MAP; do
        port="${pm%%:*}"; name="${pm##*:}"
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            warn "Port ${port} (${name}) in use"
            CONFLICT=1
        fi
    done
    [ "$CONFLICT" -eq 0 ] && ok "All ports available" || warn "Remap conflicting ports in docker-compose.yml"
    echo ""

    # Build
    header "Building selected containers..."
    SERVICES=""
    [ "$INST_DB_REG" -eq 1 ]          && SERVICES="$SERVICES db-registration"
    [ "$INST_DB_ELEC" -eq 1 ]         && SERVICES="$SERVICES db-election"
    [ "$INST_DB_VOTES" -eq 1 ]        && SERVICES="$SERVICES db-votes"
    [ "$INST_DB_RO" -eq 1 ]           && SERVICES="$SERVICES db-votes-readonly"
    [ "$INST_SV_MACHINE" -eq 1 ]      && SERVICES="$SERVICES sv-machine-sim"
    [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && SERVICES="$SERVICES sv-idcard"
    [ "$INST_SV_VERIFY" -eq 1 ]       && SERVICES="$SERVICES sv-verify"
    [ "$INST_SV_ADMIN_API" -eq 1 ]    && SERVICES="$SERVICES sv-admin"
    [ "$INST_SV_NGINX" -eq 1 ]        && SERVICES="$SERVICES nginx"

    docker compose build $SERVICES 2>&1 | tail -5
    ok "Containers built"

    # Start
    header "Starting services..."
    docker compose up -d $SERVICES 2>&1 | grep -v "^$"
    ok "Services started"

    # Wait for DBs
    if [ "$INST_DB_REG" -eq 1 ] || [ "$INST_DB_ELEC" -eq 1 ] || [ "$INST_DB_VOTES" -eq 1 ]; then
        log "Waiting for databases..."
        for i in $(seq 1 30); do
            AH=1
            [ "$INST_DB_REG" -eq 1 ]   && { S=$(docker inspect --format='{{.State.Health.Status}}' sv-db-registration 2>/dev/null || echo "w"); [ "$S" != "healthy" ] && AH=0; }
            [ "$INST_DB_ELEC" -eq 1 ]  && { S=$(docker inspect --format='{{.State.Health.Status}}' sv-db-election 2>/dev/null || echo "w"); [ "$S" != "healthy" ] && AH=0; }
            [ "$INST_DB_VOTES" -eq 1 ] && { S=$(docker inspect --format='{{.State.Health.Status}}' sv-db-votes 2>/dev/null || echo "w"); [ "$S" != "healthy" ] && AH=0; }
            [ "$AH" -eq 1 ] && break
            sleep 2
        done
        ok "Databases healthy"
        sleep 5
    fi

    # Registration tables (CURDATE workaround)
    if [ "$INST_DB_REG" -eq 1 ]; then
        header "Setting up Registration Database..."
        DB="docker exec -i sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration"
        TC=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='securevote_registration' AND table_name='voter_id_documents'" | $DB -N 2>/dev/null || echo "0")
        if [ "$TC" = "0" ]; then
            $DB << 'SQL'
CREATE TABLE IF NOT EXISTS voter_id_documents(document_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,document_type ENUM('DRIVERS_LICENSE','STATE_ID','PASSPORT','MILITARY_ID','TRIBAL_ID','VOTER_ID_CARD')NOT NULL,issuing_state CHAR(2)NULL,document_number_hash CHAR(64)NOT NULL,expiration_date DATE NULL,front_scan_encrypted MEDIUMBLOB NULL,back_scan_encrypted MEDIUMBLOB NULL,scan_quality_score DECIMAL(5,4)NULL,extracted_data_hash CHAR(64)NOT NULL,document_hash CHAR(64)NOT NULL,verified_by VARCHAR(100)NULL,verified_at DATETIME NULL,is_primary BOOLEAN NOT NULL DEFAULT FALSE,is_reported_stolen BOOLEAN NOT NULL DEFAULT FALSE,stolen_reported_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(document_id),INDEX idx_v(voter_id),CONSTRAINT fk_dv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_biometrics(biometric_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,template_encrypted MEDIUMBLOB NOT NULL,template_hash CHAR(64)NOT NULL,template_algorithm VARCHAR(50)NOT NULL,capture_quality_score DECIMAL(5,4)NOT NULL,captured_at DATETIME NOT NULL,capture_source ENUM('REGISTRATION','POLLING_PLACE','UPDATE')NOT NULL,capture_machine_id VARCHAR(50)NULL,is_active BOOLEAN NOT NULL DEFAULT TRUE,superseded_by BIGINT UNSIGNED NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(biometric_id),INDEX idx_va(voter_id,is_active),CONSTRAINT fk_bv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_election_pins(pin_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NOT NULL,pin_hash CHAR(128)NOT NULL,pin_salt CHAR(32)NOT NULL,mailed_at DATETIME NULL,mailing_address_hash CHAR(64)NULL,delivery_confirmed BOOLEAN NOT NULL DEFAULT FALSE,is_active BOOLEAN NOT NULL DEFAULT TRUE,failed_attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,locked_until DATETIME NULL,last_used_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(pin_id),UNIQUE KEY uk_vep(voter_id,election_id),CONSTRAINT fk_pv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS voter_token_issuance(issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NOT NULL,precinct_id VARCHAR(20)NOT NULL,blinded_token_hash CHAR(64)NOT NULL,issued_at DATETIME NOT NULL,issuing_machine_id VARCHAR(50)NOT NULL,auth_method ENUM('BIOMETRIC_AUTO','BIOMETRIC_MANUAL','MANUAL_OVERRIDE','PIN_FALLBACK')NOT NULL,biometric_confidence_a DECIMAL(5,4)NULL,biometric_confidence_b DECIMAL(5,4)NULL,manual_verifier_id VARCHAR(100)NULL,is_void BOOLEAN NOT NULL DEFAULT FALSE,void_reason VARCHAR(255)NULL,voided_by VARCHAR(100)NULL,voided_at DATETIME NULL,row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(issuance_id),UNIQUE KEY uk_vte(voter_id,election_id),CONSTRAINT fk_iv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS registration_ledger(ledger_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,voter_id BIGINT UNSIGNED NOT NULL,action ENUM('REGISTERED','STATUS_CHANGED','ADDRESS_CHANGED','NAME_CHANGED','PRECINCT_CHANGED','ID_ADDED','ID_REMOVED','BIOMETRIC_ENROLLED','BIOMETRIC_UPDATED','PIN_ISSUED','TOKEN_ISSUED','TOKEN_VOIDED','CANCELLED','REINSTATED','PURGE_FLAGGED','PURGE_CHALLENGED','PURGE_EXECUTED')NOT NULL,action_details JSON NULL,performed_by VARCHAR(100)NOT NULL,secondary_authorizer VARCHAR(100)NULL,previous_entry_hash CHAR(64)NULL,entry_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(ledger_id),INDEX idx_vc(voter_id,created_at),CONSTRAINT fk_lv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS db_audit_log(audit_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,table_name VARCHAR(100)NOT NULL,operation ENUM('INSERT','UPDATE','DELETE')NOT NULL,primary_key_value VARCHAR(255)NOT NULL,old_values_hash CHAR(64)NULL,new_values_hash CHAR(64)NULL,changed_columns JSON NULL,db_user VARCHAR(100)NOT NULL,application_user VARCHAR(100)NULL,source_ip VARCHAR(45)NULL,previous_entry_hash CHAR(64)NULL,entry_hash CHAR(64)NOT NULL,created_at DATETIME(6)NOT NULL DEFAULT CURRENT_TIMESTAMP(6),PRIMARY KEY(audit_id),INDEX idx_tt(table_name,created_at))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS card_operators(operator_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,username VARCHAR(50)NOT NULL,password_hash CHAR(64)NOT NULL,password_salt CHAR(32)NOT NULL,legal_first_name VARCHAR(100)NOT NULL,legal_last_name VARCHAR(100)NOT NULL,employee_id VARCHAR(50)NOT NULL,title VARCHAR(100)NOT NULL,department VARCHAR(100)NOT NULL,email VARCHAR(200)NOT NULL,phone VARCHAR(20)NOT NULL,office_address VARCHAR(300)NOT NULL,office_city VARCHAR(100)NOT NULL,office_state CHAR(2)NOT NULL,office_zip VARCHAR(10)NOT NULL,access_level ENUM('OPERATOR','SUPERVISOR','ADMIN')NOT NULL DEFAULT 'OPERATOR',jurisdiction_id VARCHAR(50)NULL,is_active BOOLEAN NOT NULL DEFAULT TRUE,activated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,deactivated_at DATETIME NULL,deactivated_by VARCHAR(50)NULL,last_login_at DATETIME NULL,last_login_ip VARCHAR(45)NULL,failed_login_count TINYINT UNSIGNED NOT NULL DEFAULT 0,locked_until DATETIME NULL,created_by VARCHAR(50)NOT NULL DEFAULT 'SYSTEM',row_integrity_hash CHAR(64)NOT NULL,created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,PRIMARY KEY(operator_id),UNIQUE KEY uk_un(username),UNIQUE KEY uk_eid(employee_id))ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS card_issuance_log(issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,operator_id BIGINT UNSIGNED NOT NULL,voter_id BIGINT UNSIGNED NOT NULL,election_id VARCHAR(50)NULL,card_format ENUM('PNG','PDF')NOT NULL,card_hash CHAR(64)NOT NULL,issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,issuer_ip VARCHAR(45)NULL,reason VARCHAR(200)NULL,row_integrity_hash CHAR(64)NOT NULL,PRIMARY KEY(issuance_id),INDEX idx_op(operator_id),INDEX idx_vt(voter_id),CONSTRAINT fk_co FOREIGN KEY(operator_id)REFERENCES card_operators(operator_id),CONSTRAINT fk_cv FOREIGN KEY(voter_id)REFERENCES voters(voter_id))ENGINE=InnoDB;
SQL
            ok "Registration tables created"
        else
            ok "Registration tables exist"
        fi
        # Seed admin
        AC=$(echo "SELECT COUNT(*) FROM card_operators WHERE username='admin001'" | $DB -N 2>/dev/null || echo "0")
        if [ "$AC" = "0" ]; then
            echo "SET @s=LEFT(SHA2(RAND(),256),32);INSERT INTO card_operators(username,password_hash,password_salt,legal_first_name,legal_last_name,employee_id,title,department,email,phone,office_address,office_city,office_state,office_zip,access_level,is_active,created_by,row_integrity_hash)VALUES('admin001',SHA2(CONCAT(@s,'Admin001PWord'),256),@s,'System','Administrator','SV-EMP-0001','System Administrator','SecureVote','admin@securevote.local','(000)000-0000','N/A','N/A','FL','00000','ADMIN',TRUE,'SYSTEM',SHA2('admin001',256));" | $DB
            ok "Admin user created (admin001 / Admin001PWord)"
        else
            ok "Admin user exists"
        fi
    fi

    # Election seed
    if [ "$INST_DB_ELEC" -eq 1 ]; then
        header "Setting up Election Database..."
        DBC="docker exec -i sv-db-election mariadb -u sv_elec_user -psv-elec-pw-2026 securevote_election"
        EC=$(echo "SELECT COUNT(*) FROM elections" | $DBC -N 2>/dev/null || echo "0")
        if [ "$EC" = "0" ]; then
            $DBC << 'SQL'
INSERT IGNORE INTO jurisdictions VALUES('US',NULL,'FEDERAL','United States of America',NULL,SHA2('US',256)),('US-FL','US','STATE','Florida','12',SHA2('US-FL',256));
INSERT IGNORE INTO elections(election_id,jurisdiction_id,election_type,title,election_date,polls_open_time,polls_close_time,status,row_integrity_hash)VALUES('general-2026-11-03','US-FL','GENERAL','General Election — November 3, 2026','2026-11-03','06:00:00','19:00:00','ACTIVE',SHA2('e1',256));
INSERT IGNORE INTO races(race_id,election_id,title,race_type,jurisdiction_id,voting_rule,max_selections,write_in_allowed,display_order,row_integrity_hash)VALUES('race-us-president','general-2026-11-03','President of the United States','FEDERAL','US','CHOOSE_ONE',1,1,1,SHA2('r1',256)),('race-us-senate-fl','general-2026-11-03','United States Senator — Florida','FEDERAL','US-FL','CHOOSE_ONE',1,1,2,SHA2('r2',256)),('race-fl-governor','general-2026-11-03','Governor of Florida','STATE','US-FL','CHOOSE_ONE',1,0,3,SHA2('r3',256)),('race-fl-ag','general-2026-11-03','Attorney General of Florida','STATE','US-FL','CHOOSE_ONE',1,0,4,SHA2('r4',256)),('race-fl-cfo','general-2026-11-03','Chief Financial Officer','STATE','US-FL','CHOOSE_ONE',1,0,5,SHA2('r5',256));
INSERT IGNORE INTO candidates(race_id,legal_full_name,display_name,party,candidate_hash_salt,candidate_hash,display_order,is_qualified,is_withdrawn,row_integrity_hash)VALUES('race-us-president','Jane Elizabeth Smith','Jane Smith','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c1',256),1,1,0,SHA2('c1r',256)),('race-us-president','John Robert Jones','John Jones','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c2',256),2,1,0,SHA2('c2r',256)),('race-us-president','Maria Luisa Garcia','Maria Garcia','Independent',LEFT(SHA2(RAND(),256),32),SHA2('c3',256),3,1,0,SHA2('c3r',256)),('race-us-senate-fl','Robert Wei Chen','Robert Chen','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c4',256),1,1,0,SHA2('c4r',256)),('race-us-senate-fl','Sarah Mae Williams','Sarah Williams','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c5',256),2,1,0,SHA2('c5r',256)),('race-fl-governor','Patricia Ann Reeves','Patricia Reeves','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c6',256),1,1,0,SHA2('c6r',256)),('race-fl-governor','Michael Antonio Torres','Michael Torres','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c7',256),2,1,0,SHA2('c7r',256)),('race-fl-ag','Diane Louise Park','Diane Park','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c8',256),1,1,0,SHA2('c8r',256)),('race-fl-ag','Thomas James Burke','Thomas Burke','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c9',256),2,1,0,SHA2('c9r',256)),('race-fl-cfo','Angela Rose Martinez','Angela Martinez','Democratic Party',LEFT(SHA2(RAND(),256),32),SHA2('c10',256),1,1,0,SHA2('c10r',256)),('race-fl-cfo','William Earl Henderson','William Henderson','Republican Party',LEFT(SHA2(RAND(),256),32),SHA2('c11',256),2,1,0,SHA2('c11r',256));
INSERT IGNORE INTO ballot_measures(measure_id,election_id,jurisdiction_id,title,summary,display_order,row_integrity_hash)VALUES('measure-fl-prop-1','general-2026-11-03','US-FL','Proposition 1: Infrastructure Bond Act','Shall Florida authorize $10 billion in bonds for transportation infrastructure?',6,SHA2('m1',256));
INSERT IGNORE INTO measure_options(measure_id,display_name,option_hash_salt,option_hash,display_order,row_integrity_hash)VALUES('measure-fl-prop-1','Yes',LEFT(SHA2(RAND(),256),32),SHA2('o1',256),1,SHA2('o1r',256)),('measure-fl-prop-1','No',LEFT(SHA2(RAND(),256),32),SHA2('o2',256),2,SHA2('o2r',256));
SQL
            ok "Election seeded: 5 races, 11 candidates, 1 measure"
        else
            ok "Election data exists"
        fi
    fi

# ============================================================================
# STANDALONE MODE
# ============================================================================
elif [ "$MODE" = "standalone" ]; then

    header "Installing Dependencies..."

    # --- MariaDB ---
    if [ "$NEED_MARIADB" -eq 1 ]; then
        if command -v mariadb &>/dev/null; then
            ok "MariaDB $(mariadb --version | grep -oP '\d+\.\d+' | head -1) already installed"
        else
            log "MariaDB not found. Installing..."
            case "$PKG_MGR" in
                apt)
                    sudo apt-get update -qq
                    if ! apt-cache show mariadb-server 2>/dev/null | grep -q "Version: 1[1-9]"; then
                        curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=mariadb-11.4 2>/dev/null
                    fi
                    sudo apt-get install -y mariadb-server mariadb-client
                    ;;
                dnf) sudo dnf install -y mariadb-server mariadb; sudo systemctl enable --now mariadb ;;
                yum) sudo yum install -y mariadb-server mariadb; sudo systemctl enable --now mariadb ;;
                pacman) sudo pacman -S --noconfirm mariadb; sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql; sudo systemctl enable --now mariadb ;;
                *) fail "Install MariaDB 11.4+ manually." ;;
            esac
            sudo systemctl enable --now mariadb 2>/dev/null || true
            ok "MariaDB installed and started"
        fi
    fi

    # --- Go ---
    if [ "$NEED_GO" -eq 1 ]; then
        if command -v go &>/dev/null; then
            GO_VER=$(go version | grep -oP '\d+\.\d+' | head -1)
            ok "Go ${GO_VER} already installed"
        else
            log "Go not found. Installing Go 1.22..."
            GO_TAR="go1.22.4.linux-$(dpkg --print-architecture 2>/dev/null || echo amd64).tar.gz"
            wget -q "https://go.dev/dl/${GO_TAR}" -O "/tmp/${GO_TAR}"
            sudo rm -rf /usr/local/go
            sudo tar -C /usr/local -xzf "/tmp/${GO_TAR}"
            rm -f "/tmp/${GO_TAR}"
            export PATH=$PATH:/usr/local/go/bin
            # Persist for future shells
            if ! grep -q '/usr/local/go/bin' /etc/profile.d/golang.sh 2>/dev/null; then
                echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/golang.sh >/dev/null
            fi
            ok "Go $(go version | grep -oP '\d+\.\d+\.\d+') installed"
        fi
    fi

    # --- Python + Pillow + qrcode ---
    if [ "$NEED_PYTHON" -eq 1 ]; then
        if command -v python3 &>/dev/null; then
            ok "Python $(python3 --version | grep -oP '\d+\.\d+') already installed"
        else
            log "Python3 not found. Installing..."
            case "$PKG_MGR" in
                apt) sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip ;;
                dnf) sudo dnf install -y python3 python3-pip ;;
                yum) sudo yum install -y python3 python3-pip ;;
                pacman) sudo pacman -S --noconfirm python python-pip ;;
                *) fail "Install Python 3.12+ manually." ;;
            esac
            ok "Python installed"
        fi

        # Pillow
        if python3 -c "import PIL" 2>/dev/null; then
            ok "Pillow already installed"
        else
            log "Installing Pillow..."
            pip3 install Pillow --break-system-packages 2>/dev/null || pip3 install Pillow
            ok "Pillow installed"
        fi

        # qrcode
        if python3 -c "import qrcode" 2>/dev/null; then
            ok "qrcode already installed"
        else
            log "Installing qrcode..."
            pip3 install qrcode --break-system-packages 2>/dev/null || pip3 install qrcode
            ok "qrcode installed"
        fi

        # Fonts
        if [ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ]; then
            ok "DejaVu fonts present"
        else
            log "Installing fonts..."
            case "$PKG_MGR" in
                apt) sudo apt-get install -y fonts-dejavu-core ;;
                dnf|yum) sudo $PKG_MGR install -y dejavu-sans-fonts ;;
                pacman) sudo pacman -S --noconfirm ttf-dejavu ;;
            esac
            ok "Fonts installed"
        fi

        # mariadb CLI (needed by admin portal)
        if ! command -v mariadb &>/dev/null; then
            log "Installing MariaDB client (needed by admin portal)..."
            case "$PKG_MGR" in
                apt) sudo apt-get install -y mariadb-client ;;
                dnf|yum) sudo $PKG_MGR install -y mariadb ;;
                pacman) sudo pacman -S --noconfirm mariadb-clients ;;
            esac
            ok "MariaDB client installed"
        fi
    fi

    # --- Nginx ---
    if [ "$NEED_NGINX" -eq 1 ]; then
        if command -v nginx &>/dev/null; then
            ok "Nginx already installed"
        else
            log "Installing Nginx..."
            case "$PKG_MGR" in
                apt) sudo apt-get update -qq && sudo apt-get install -y nginx ;;
                dnf|yum) sudo $PKG_MGR install -y nginx; sudo systemctl enable --now nginx ;;
                pacman) sudo pacman -S --noconfirm nginx; sudo systemctl enable --now nginx ;;
            esac
            ok "Nginx installed"
        fi
    fi

    if [ "$NEED_OPENSSL" -eq 1 ] && ! command -v openssl &>/dev/null; then
        pkg_install openssl
        ok "OpenSSL installed"
    fi
    echo ""

    # --- Create databases ---
    if [ "$NEED_MARIADB" -eq 1 ]; then
        header "Setting up databases..."
        echo "  This will create databases and users in your local MariaDB."
        read -p "  MariaDB root password (Enter for none): " -s DB_ROOT_PW
        echo ""
        MYSQL_ROOT="mariadb -u root"
        [ -n "${DB_ROOT_PW:-}" ] && MYSQL_ROOT="mariadb -u root -p${DB_ROOT_PW}"

        if [ "$INST_DB_REG" -eq 1 ]; then
            $MYSQL_ROOT -e "CREATE DATABASE IF NOT EXISTS securevote_registration CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'sv_reg_user'@'%' IDENTIFIED BY 'sv-reg-pw-2026'; GRANT ALL ON securevote_registration.* TO 'sv_reg_user'@'%'; FLUSH PRIVILEGES;" 2>/dev/null
            $MYSQL_ROOT securevote_registration < migrations/registration/001_initial.sql 2>/dev/null || true
            ok "Registration database created"
        fi
        if [ "$INST_DB_ELEC" -eq 1 ]; then
            $MYSQL_ROOT -e "CREATE DATABASE IF NOT EXISTS securevote_election CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'sv_elec_user'@'%' IDENTIFIED BY 'sv-elec-pw-2026'; GRANT ALL ON securevote_election.* TO 'sv_elec_user'@'%'; FLUSH PRIVILEGES;" 2>/dev/null
            $MYSQL_ROOT securevote_election < migrations/election/001_initial.sql 2>/dev/null || true
            ok "Election database created"
        fi
        if [ "$INST_DB_VOTES" -eq 1 ]; then
            $MYSQL_ROOT -e "CREATE DATABASE IF NOT EXISTS securevote_votes CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'sv_votes_user'@'%' IDENTIFIED BY 'sv-votes-pw-2026'; GRANT ALL ON securevote_votes.* TO 'sv_votes_user'@'%'; CREATE USER IF NOT EXISTS 'sv_verify_user'@'%' IDENTIFIED BY 'sv-ro-pw-2026'; GRANT SELECT ON securevote_votes.* TO 'sv_verify_user'@'%'; FLUSH PRIVILEGES;" 2>/dev/null
            $MYSQL_ROOT securevote_votes < migrations/votes/001_initial.sql 2>/dev/null || true
            ok "Votes database created"
        fi
    fi

    # Build Go services
    GO_SERVICES=""
    [ "$INST_SV_MACHINE" -eq 1 ]   && GO_SERVICES="$GO_SERVICES sv-machine"
    [ "$INST_SV_VERIFY" -eq 1 ]    && GO_SERVICES="$GO_SERVICES sv-verify"
    [ "$INST_SV_ADMIN_API" -eq 1 ] && GO_SERVICES="$GO_SERVICES sv-admin"
    [ "$INST_SV_TABULATOR" -eq 1 ] && GO_SERVICES="$GO_SERVICES sv-tabulator"

    if [ -n "$GO_SERVICES" ]; then
        header "Building Go services..."
        cd src && go mod tidy 2>/dev/null; cd ..
        mkdir -p bin
        for svc in $GO_SERVICES; do
            log "  Building $svc..."
            (cd src && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "../bin/$svc" "./cmd/$svc/")
            ok "$svc → bin/$svc"
        done
    fi

    # Write env files
    header "Writing environment files..."
    mkdir -p env

    if [ "$INST_SV_MACHINE" -eq 1 ]; then
        cat > env/machine.env << ENVEOF
SV_DB_REG_HOST=${DB_REG_HOST}
SV_DB_REG_PORT=${DB_REG_PORT}
SV_DB_REG_USER=sv_reg_user
SV_DB_REG_PASS=sv-reg-pw-2026
SV_DB_REG_NAME=securevote_registration
SV_DB_ELEC_HOST=${DB_ELEC_HOST}
SV_DB_ELEC_PORT=${DB_ELEC_PORT}
SV_DB_ELEC_USER=sv_elec_user
SV_DB_ELEC_PASS=sv-elec-pw-2026
SV_DB_ELEC_NAME=securevote_election
SV_DB_VOTES_HOST=${DB_VOTES_HOST}
SV_DB_VOTES_PORT=${DB_VOTES_PORT}
SV_DB_VOTES_USER=sv_votes_user
SV_DB_VOTES_PASS=sv-votes-pw-2026
SV_DB_VOTES_NAME=securevote_votes
SV_SIM_ADDR=:8080
ENVEOF
        ok "env/machine.env"
    fi

    if [ "$INST_SV_ADMIN_PORTAL" -eq 1 ]; then
        cat > env/admin-portal.env << ENVEOF
DB_HOST=${DB_REG_HOST}
DB_USER=sv_reg_user
DB_PASS=sv-reg-pw-2026
DB_NAME=securevote_registration
DB_ELEC_HOST=${DB_ELEC_HOST}
DB_ELEC_USER=sv_elec_user
DB_ELEC_PASS=sv-elec-pw-2026
DB_ELEC_NAME=securevote_election
PORT=8090
ENVEOF
        ok "env/admin-portal.env"
    fi

    if [ "$INST_SV_VERIFY" -eq 1 ]; then
        cat > env/verify.env << ENVEOF
SV_DB_VOTES_HOST=${DB_RO_HOST}
SV_DB_VOTES_PORT=${DB_RO_PORT}
SV_DB_VOTES_USER=sv_verify_user
SV_DB_VOTES_PASS=sv-ro-pw-2026
SV_DB_VOTES_NAME=securevote_votes
SV_VERIFY_ADDR=:8443
ENVEOF
        ok "env/verify.env"
    fi

    if [ "$INST_SV_ADMIN_API" -eq 1 ]; then
        cat > env/admin-api.env << ENVEOF
SV_DB_REG_HOST=${DB_REG_HOST}
SV_DB_REG_PORT=${DB_REG_PORT}
SV_DB_REG_USER=sv_reg_user
SV_DB_REG_PASS=sv-reg-pw-2026
SV_DB_REG_NAME=securevote_registration
SV_DB_ELEC_HOST=${DB_ELEC_HOST}
SV_DB_ELEC_PORT=${DB_ELEC_PORT}
SV_DB_ELEC_USER=sv_elec_user
SV_DB_ELEC_PASS=sv-elec-pw-2026
SV_DB_ELEC_NAME=securevote_election
SV_ADMIN_ADDR=:9443
ENVEOF
        ok "env/admin-api.env"
    fi

    echo ""
    header "Start Commands"
    [ "$INST_SV_MACHINE" -eq 1 ]      && echo "  Voting Machine:   set -a; source env/machine.env; set +a; ./bin/sv-machine"
    [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && echo "  Admin Portal:     set -a; source env/admin-portal.env; set +a; python3 docker/sv-idcard/admin_portal.py"
    [ "$INST_SV_VERIFY" -eq 1 ]       && echo "  Verify API:       set -a; source env/verify.env; set +a; ./bin/sv-verify"
    [ "$INST_SV_ADMIN_API" -eq 1 ]    && echo "  Admin API:        set -a; source env/admin-api.env; set +a; ./bin/sv-admin"
    [ "$INST_SV_TABULATOR" -eq 1 ]    && echo "  Tabulator:        set -a; source env/machine.env; set +a; ./bin/sv-tabulator"
    echo ""
    log "For systemd service setup, see STANDALONE.md"

fi

# ============================================================================
# Final Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  SecureVote setup complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$MODE" = "docker" ]; then
    echo "  Services:"
    [ "$INST_SV_MACHINE" -eq 1 ]      && echo "    Voting Simulator  → http://localhost:18080"
    [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && echo "    Admin Portal      → http://localhost:18090/admin"
    [ "$INST_SV_VERIFY" -eq 1 ]       && echo "    Verification API  → http://localhost:18443"
    [ "$INST_SV_ADMIN_API" -eq 1 ]    && echo "    Admin API         → https://localhost:9443"
    [ "$INST_SV_NGINX" -eq 1 ]        && echo "    Nginx Proxy       → https://localhost:10443"
elif [ "$MODE" = "standalone" ]; then
    echo "  Services (start manually — see commands above):"
    [ "$INST_SV_MACHINE" -eq 1 ]      && echo "    Voting Simulator  → http://localhost:8080"
    [ "$INST_SV_ADMIN_PORTAL" -eq 1 ] && echo "    Admin Portal      → http://localhost:8090/admin"
    [ "$INST_SV_VERIFY" -eq 1 ]       && echo "    Verification API  → http://localhost:8443"
    [ "$INST_SV_ADMIN_API" -eq 1 ]    && echo "    Admin API         → https://localhost:9443"
fi

if [ "$INST_SV_ADMIN_PORTAL" -eq 1 ]; then
    echo ""
    echo "  Admin Login:"
    echo "    Username: admin001"
    echo "    Password: Admin001PWord"
fi

echo ""
echo "  Documentation:"
echo "    DOCKER.md      — Docker deployment guide"
echo "    STANDALONE.md  — Standalone deployment guide"
echo "    ADMIN.md       — Admin portal user guide"
echo ""
echo "  Import voters:  ./scripts/import-florida.sh --help"
echo ""
