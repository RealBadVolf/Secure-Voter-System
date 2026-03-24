# SecureVote — Standalone Deployment (No Docker)

This guide covers installing and running SecureVote directly on a Linux server without Docker. Tested on Ubuntu 22.04/24.04 and Debian 12.

## Prerequisites

| Software | Version | Purpose |
|---|---|---|
| MariaDB | 11.4+ | Three database instances |
| Go | 1.22+ | Application services |
| Python | 3.12+ | Admin portal + ID card generation |
| Nginx | 1.24+ | Reverse proxy (optional) |

## Step 1: Install Dependencies

### Ubuntu / Debian

```bash
# MariaDB
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
sudo apt install mariadb-server mariadb-client

# Go
wget https://go.dev/dl/go1.22.4.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc

# Python
sudo apt install python3 python3-pip python3-venv
pip install Pillow qrcode --break-system-packages

# Fonts (needed for ID card generation)
sudo apt install fonts-dejavu-core

# Nginx (optional, for reverse proxy)
sudo apt install nginx
```

Verify:

```bash
mariadb --version     # Should show 11.4+
go version            # Should show 1.22+
python3 --version     # Should show 3.12+
```

## Step 2: Set Up Databases

SecureVote uses three separate databases. In production, these run on separate servers. For development, one MariaDB instance with three databases and three users is fine.

### Create Databases and Users

```bash
sudo mariadb << 'SQL'

-- Create databases
CREATE DATABASE IF NOT EXISTS securevote_registration CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS securevote_election CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS securevote_votes CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Registration user (can only access registration)
CREATE USER IF NOT EXISTS 'sv_reg_user'@'localhost' IDENTIFIED BY 'sv-reg-pw-2026';
GRANT ALL PRIVILEGES ON securevote_registration.* TO 'sv_reg_user'@'localhost';

-- Election user (can only access election)
CREATE USER IF NOT EXISTS 'sv_elec_user'@'localhost' IDENTIFIED BY 'sv-elec-pw-2026';
GRANT ALL PRIVILEGES ON securevote_election.* TO 'sv_elec_user'@'localhost';

-- Votes user (can only access votes)
CREATE USER IF NOT EXISTS 'sv_votes_user'@'localhost' IDENTIFIED BY 'sv-votes-pw-2026';
GRANT ALL PRIVILEGES ON securevote_votes.* TO 'sv_votes_user'@'localhost';

-- Verify user (read-only on votes — simulates Zone 5)
CREATE USER IF NOT EXISTS 'sv_verify_user'@'localhost' IDENTIFIED BY 'sv-ro-pw-2026';
GRANT SELECT ON securevote_votes.vote_casts TO 'sv_verify_user'@'localhost';
GRANT SELECT ON securevote_votes.merkle_trees TO 'sv_verify_user'@'localhost';
GRANT SELECT ON securevote_votes.merkle_nodes TO 'sv_verify_user'@'localhost';
GRANT SELECT ON securevote_votes.merkle_hierarchy TO 'sv_verify_user'@'localhost';
GRANT SELECT, INSERT ON securevote_votes.verification_attempts TO 'sv_verify_user'@'localhost';

FLUSH PRIVILEGES;
SQL
```

### Run Schema Migrations

```bash
cd /path/to/SecureVote

# Election database (runs cleanly)
mariadb -u sv_elec_user -psv-elec-pw-2026 securevote_election < migrations/election/001_initial.sql

# Votes database (runs cleanly)
mariadb -u sv_votes_user -psv-votes-pw-2026 securevote_votes < migrations/votes/001_initial.sql

# Registration database — the migration has a known issue with CURDATE()
# in a generated column. Run it, then manually create the missing tables:
mariadb -u root -p securevote_registration < migrations/registration/001_initial.sql
```

The registration migration creates the `voters` table but stops at `voter_id_documents` due to a `CURDATE()` generated column that MariaDB rejects. Create the remaining tables manually:

```bash
mariadb -u root -p securevote_registration << 'SQL'

CREATE TABLE IF NOT EXISTS voter_id_documents (
    document_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    voter_id BIGINT UNSIGNED NOT NULL,
    document_type ENUM('DRIVERS_LICENSE','STATE_ID','PASSPORT','MILITARY_ID','TRIBAL_ID','VOTER_ID_CARD') NOT NULL,
    issuing_state CHAR(2) NULL,
    document_number_hash CHAR(64) NOT NULL,
    expiration_date DATE NULL,
    front_scan_encrypted MEDIUMBLOB NULL,
    back_scan_encrypted MEDIUMBLOB NULL,
    scan_quality_score DECIMAL(5,4) NULL,
    extracted_data_hash CHAR(64) NOT NULL,
    document_hash CHAR(64) NOT NULL,
    verified_by VARCHAR(100) NULL,
    verified_at DATETIME NULL,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    is_reported_stolen BOOLEAN NOT NULL DEFAULT FALSE,
    stolen_reported_at DATETIME NULL,
    row_integrity_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (document_id),
    INDEX idx_voter (voter_id),
    INDEX idx_doc_number_hash (document_number_hash),
    CONSTRAINT fk_doc_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS voter_biometrics (
    biometric_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    voter_id BIGINT UNSIGNED NOT NULL,
    template_encrypted MEDIUMBLOB NOT NULL,
    template_hash CHAR(64) NOT NULL,
    template_algorithm VARCHAR(50) NOT NULL,
    capture_quality_score DECIMAL(5,4) NOT NULL,
    captured_at DATETIME NOT NULL,
    capture_source ENUM('REGISTRATION','POLLING_PLACE','UPDATE') NOT NULL,
    capture_machine_id VARCHAR(50) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by BIGINT UNSIGNED NULL,
    row_integrity_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (biometric_id),
    INDEX idx_voter_active (voter_id, is_active),
    INDEX idx_template_hash (template_hash),
    CONSTRAINT fk_bio_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS voter_election_pins (
    pin_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    voter_id BIGINT UNSIGNED NOT NULL,
    election_id VARCHAR(50) NOT NULL,
    pin_hash CHAR(128) NOT NULL,
    pin_salt CHAR(32) NOT NULL,
    mailed_at DATETIME NULL,
    mailing_address_hash CHAR(64) NULL,
    delivery_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    failed_attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
    locked_until DATETIME NULL,
    last_used_at DATETIME NULL,
    row_integrity_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (pin_id),
    UNIQUE KEY uk_voter_election_pin (voter_id, election_id),
    CONSTRAINT fk_pin_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS voter_token_issuance (
    issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    voter_id BIGINT UNSIGNED NOT NULL,
    election_id VARCHAR(50) NOT NULL,
    precinct_id VARCHAR(20) NOT NULL,
    blinded_token_hash CHAR(64) NOT NULL,
    issued_at DATETIME NOT NULL,
    issuing_machine_id VARCHAR(50) NOT NULL,
    auth_method ENUM('BIOMETRIC_AUTO','BIOMETRIC_MANUAL','MANUAL_OVERRIDE','PIN_FALLBACK') NOT NULL,
    biometric_confidence_a DECIMAL(5,4) NULL,
    biometric_confidence_b DECIMAL(5,4) NULL,
    manual_verifier_id VARCHAR(100) NULL,
    is_void BOOLEAN NOT NULL DEFAULT FALSE,
    void_reason VARCHAR(255) NULL,
    voided_by VARCHAR(100) NULL,
    voided_at DATETIME NULL,
    row_integrity_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (issuance_id),
    UNIQUE KEY uk_voter_election (voter_id, election_id),
    CONSTRAINT fk_issuance_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS registration_ledger (
    ledger_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    voter_id BIGINT UNSIGNED NOT NULL,
    action ENUM('REGISTERED','STATUS_CHANGED','ADDRESS_CHANGED','NAME_CHANGED','PRECINCT_CHANGED','ID_ADDED','ID_REMOVED','BIOMETRIC_ENROLLED','BIOMETRIC_UPDATED','PIN_ISSUED','TOKEN_ISSUED','TOKEN_VOIDED','CANCELLED','REINSTATED','PURGE_FLAGGED','PURGE_CHALLENGED','PURGE_EXECUTED') NOT NULL,
    action_details JSON NULL,
    performed_by VARCHAR(100) NOT NULL,
    secondary_authorizer VARCHAR(100) NULL,
    previous_entry_hash CHAR(64) NULL,
    entry_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ledger_id),
    INDEX idx_voter_chronological (voter_id, created_at),
    CONSTRAINT fk_ledger_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS db_audit_log (
    audit_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name VARCHAR(100) NOT NULL,
    operation ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    primary_key_value VARCHAR(255) NOT NULL,
    old_values_hash CHAR(64) NULL,
    new_values_hash CHAR(64) NULL,
    changed_columns JSON NULL,
    db_user VARCHAR(100) NOT NULL,
    application_user VARCHAR(100) NULL,
    source_ip VARCHAR(45) NULL,
    previous_entry_hash CHAR(64) NULL,
    entry_hash CHAR(64) NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (audit_id),
    INDEX idx_table_time (table_name, created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS card_operators (
    operator_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    username VARCHAR(50) NOT NULL,
    password_hash CHAR(64) NOT NULL,
    password_salt CHAR(32) NOT NULL,
    legal_first_name VARCHAR(100) NOT NULL,
    legal_last_name VARCHAR(100) NOT NULL,
    employee_id VARCHAR(50) NOT NULL,
    title VARCHAR(100) NOT NULL,
    department VARCHAR(100) NOT NULL,
    email VARCHAR(200) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    office_address VARCHAR(300) NOT NULL,
    office_city VARCHAR(100) NOT NULL,
    office_state CHAR(2) NOT NULL,
    office_zip VARCHAR(10) NOT NULL,
    access_level ENUM('OPERATOR','SUPERVISOR','ADMIN') NOT NULL DEFAULT 'OPERATOR',
    jurisdiction_id VARCHAR(50) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    activated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deactivated_at DATETIME NULL,
    deactivated_by VARCHAR(50) NULL,
    last_login_at DATETIME NULL,
    last_login_ip VARCHAR(45) NULL,
    failed_login_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
    locked_until DATETIME NULL,
    created_by VARCHAR(50) NOT NULL DEFAULT 'SYSTEM',
    row_integrity_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (operator_id),
    UNIQUE KEY uk_username (username),
    UNIQUE KEY uk_employee_id (employee_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS card_issuance_log (
    issuance_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    operator_id BIGINT UNSIGNED NOT NULL,
    voter_id BIGINT UNSIGNED NOT NULL,
    election_id VARCHAR(50) NULL,
    card_format ENUM('PNG','PDF') NOT NULL,
    card_hash CHAR(64) NOT NULL,
    issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    issuer_ip VARCHAR(45) NULL,
    reason VARCHAR(200) NULL,
    row_integrity_hash CHAR(64) NOT NULL,
    PRIMARY KEY (issuance_id),
    INDEX idx_operator (operator_id),
    INDEX idx_voter (voter_id),
    CONSTRAINT fk_cil_operator FOREIGN KEY (operator_id) REFERENCES card_operators(operator_id),
    CONSTRAINT fk_cil_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB;

-- Seed admin user
SET @salt = LEFT(SHA2(RAND(), 256), 32);
INSERT IGNORE INTO card_operators (
    username, password_hash, password_salt,
    legal_first_name, legal_last_name, employee_id, title, department,
    email, phone, office_address, office_city, office_state, office_zip,
    access_level, jurisdiction_id, is_active, created_by, row_integrity_hash
) VALUES (
    'admin001', SHA2(CONCAT(@salt, 'Admin001PWord'), 256), @salt,
    'Admin', 'User', 'SV-EMP-0001',
    'System Administrator', 'SecureVote Admin',
    'admin@securevote.local', '(000) 000-0000',
    'N/A', 'N/A', 'FL', '00000',
    'ADMIN', NULL, TRUE, 'SYSTEM',
    SHA2(CONCAT('admin001', 'User', 'SV-EMP-0001'), 256)
);

SQL
```

Verify all tables exist:

```bash
mariadb -u root -p securevote_registration -e "SHOW TABLES"
mariadb -u root -p securevote_election -e "SHOW TABLES"
mariadb -u root -p securevote_votes -e "SHOW TABLES"
```

Expected:

- **Registration:** voters, voter_id_documents, voter_biometrics, voter_election_pins, voter_token_issuance, registration_ledger, db_audit_log, card_operators, card_issuance_log
- **Election:** jurisdictions, precincts, elections, races, candidates, ballot_definitions, ballot_measures, bdf_signatures, measure_options, voting_machines, machine_seal_log, election_workers, db_audit_log
- **Votes:** vote_casts, vote_selections, write_in_entries, merkle_trees, merkle_nodes, merkle_hierarchy, canary_definitions, tabulation_results, tabulation_aggregates, rla_sessions, rla_samples, verification_attempts, machine_sessions, anomaly_alerts, db_audit_log, plus views

## Step 3: MariaDB Tuning (For Large Datasets)

If you're loading millions of voters, add this to `/etc/mysql/mariadb.conf.d/99-securevote.cnf`:

```ini
[mysqld]
innodb_buffer_pool_size=4G
innodb_buffer_pool_instances=4
innodb_log_file_size=512M
innodb_log_buffer_size=64M
innodb_flush_log_at_trx_commit=2
innodb_flush_method=O_DIRECT
innodb_file_per_table=1
innodb_io_capacity=2000
innodb_read_io_threads=8
innodb_write_io_threads=8
join_buffer_size=256M
sort_buffer_size=64M
read_buffer_size=16M
tmp_table_size=256M
max_heap_table_size=256M
max_connections=200
```

Restart MariaDB:

```bash
sudo systemctl restart mariadb
```

## Step 4: Seed Election Data

```bash
mariadb -u sv_elec_user -psv-elec-pw-2026 securevote_election << 'SQL'

INSERT IGNORE INTO jurisdictions VALUES
('US', NULL, 'FEDERAL', 'United States of America', NULL, SHA2('US',256)),
('US-FL', 'US', 'STATE', 'Florida', '12', SHA2('US-FL',256));

INSERT IGNORE INTO elections (election_id, jurisdiction_id, election_type, title, election_date,
    polls_open_time, polls_close_time, status, row_integrity_hash) VALUES
('general-2026-11-03', 'US-FL', 'GENERAL', 'General Election — November 3, 2026',
 '2026-11-03', '06:00:00', '19:00:00', 'ACTIVE', SHA2('general-2026-11-03',256));

INSERT IGNORE INTO races (race_id, election_id, title, race_type, jurisdiction_id,
    voting_rule, max_selections, write_in_allowed, display_order, row_integrity_hash) VALUES
('race-us-president', 'general-2026-11-03', 'President of the United States', 'FEDERAL', 'US', 'CHOOSE_ONE', 1, 1, 1, SHA2('race-us-president',256)),
('race-us-senate-fl', 'general-2026-11-03', 'United States Senator — Florida', 'FEDERAL', 'US-FL', 'CHOOSE_ONE', 1, 1, 2, SHA2('race-us-senate-fl',256)),
('race-fl-governor', 'general-2026-11-03', 'Governor of Florida', 'STATE', 'US-FL', 'CHOOSE_ONE', 1, 0, 3, SHA2('race-fl-governor',256));

INSERT IGNORE INTO candidates (race_id, legal_full_name, display_name, party,
    candidate_hash_salt, candidate_hash, display_order, is_qualified, is_withdrawn, row_integrity_hash) VALUES
('race-us-president', 'Jane Elizabeth Smith', 'Jane Smith', 'Democratic Party', LEFT(SHA2(RAND(),256),32), SHA2('Jane Smith-Dem-pres',256), 1, 1, 0, SHA2('smith',256)),
('race-us-president', 'John Robert Jones', 'John Jones', 'Republican Party', LEFT(SHA2(RAND(),256),32), SHA2('John Jones-Rep-pres',256), 2, 1, 0, SHA2('jones',256)),
('race-us-senate-fl', 'Robert Wei Chen', 'Robert Chen', 'Democratic Party', LEFT(SHA2(RAND(),256),32), SHA2('Robert Chen-Dem-sen',256), 1, 1, 0, SHA2('chen',256)),
('race-us-senate-fl', 'Sarah Mae Williams', 'Sarah Williams', 'Republican Party', LEFT(SHA2(RAND(),256),32), SHA2('Sarah Williams-Rep-sen',256), 2, 1, 0, SHA2('williams',256)),
('race-fl-governor', 'Patricia Ann Reeves', 'Patricia Reeves', 'Democratic Party', LEFT(SHA2(RAND(),256),32), SHA2('Patricia Reeves-Dem-gov',256), 1, 1, 0, SHA2('reeves',256)),
('race-fl-governor', 'Michael Antonio Torres', 'Michael Torres', 'Republican Party', LEFT(SHA2(RAND(),256),32), SHA2('Michael Torres-Rep-gov',256), 2, 1, 0, SHA2('torres',256));

SQL
```

You can add more races, candidates, and ballot measures through the admin portal after setup.

## Step 5: Build Go Services

```bash
cd /path/to/SecureVote/src

# Download dependencies
go mod tidy

# Build all four binaries
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ../bin/sv-machine ./cmd/sv-machine/
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ../bin/sv-admin ./cmd/sv-admin/
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ../bin/sv-verify ./cmd/sv-verify/
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ../bin/sv-tabulator ./cmd/sv-tabulator/

ls -la ../bin/
```

## Step 6: Run Services

### Voting Machine Simulator

```bash
export SV_DB_REG_HOST=localhost
export SV_DB_REG_PORT=3306
export SV_DB_REG_USER=sv_reg_user
export SV_DB_REG_PASS=sv-reg-pw-2026
export SV_DB_REG_NAME=securevote_registration
export SV_DB_ELEC_HOST=localhost
export SV_DB_ELEC_PORT=3306
export SV_DB_ELEC_USER=sv_elec_user
export SV_DB_ELEC_PASS=sv-elec-pw-2026
export SV_DB_ELEC_NAME=securevote_election
export SV_DB_VOTES_HOST=localhost
export SV_DB_VOTES_PORT=3306
export SV_DB_VOTES_USER=sv_votes_user
export SV_DB_VOTES_PASS=sv-votes-pw-2026
export SV_DB_VOTES_NAME=securevote_votes
export SV_SIM_ADDR=:8080

./bin/sv-machine
```

Open `http://localhost:8080` in your browser.

### Admin Portal (Card Issuance + Election Management)

```bash
export DB_HOST=localhost
export DB_USER=sv_reg_user
export DB_PASS=sv-reg-pw-2026
export DB_NAME=securevote_registration
export DB_ELEC_HOST=localhost
export DB_ELEC_USER=sv_elec_user
export DB_ELEC_PASS=sv-elec-pw-2026
export DB_ELEC_NAME=securevote_election
export PORT=8090

python3 docker/sv-idcard/admin_portal.py
```

Open `http://localhost:8090/admin` — login with `admin001` / `Admin001PWord`.

**Important:** The admin portal uses `mariadb` CLI commands internally. On standalone, it connects to `localhost` instead of Docker container hostnames. The environment variables above handle this.

### Verification Portal

```bash
export SV_DB_VOTES_HOST=localhost
export SV_DB_VOTES_PORT=3306
export SV_DB_VOTES_USER=sv_verify_user
export SV_DB_VOTES_PASS=sv-ro-pw-2026
export SV_DB_VOTES_NAME=securevote_votes
export SV_VERIFY_ADDR=:8443

./bin/sv-verify
```

### Admin API

```bash
export SV_DB_REG_HOST=localhost
export SV_DB_REG_PORT=3306
export SV_DB_REG_USER=sv_reg_user
export SV_DB_REG_PASS=sv-reg-pw-2026
export SV_DB_REG_NAME=securevote_registration
export SV_DB_ELEC_HOST=localhost
export SV_DB_ELEC_PORT=3306
export SV_DB_ELEC_USER=sv_elec_user
export SV_DB_ELEC_PASS=sv-elec-pw-2026
export SV_DB_ELEC_NAME=securevote_election
export SV_ADMIN_ADDR=:9443

./bin/sv-admin
```

## Step 7: Run as systemd Services (Production)

Create a service file for each. Example for the voting machine simulator:

```bash
sudo tee /etc/systemd/system/sv-machine.service << 'EOF'
[Unit]
Description=SecureVote Voting Machine Simulator
After=mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=securevote
Group=securevote
WorkingDirectory=/opt/securevote
ExecStart=/opt/securevote/bin/sv-machine
EnvironmentFile=/opt/securevote/env/machine.env
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

Create the environment file at `/opt/securevote/env/machine.env`:

```
SV_DB_REG_HOST=localhost
SV_DB_REG_PORT=3306
SV_DB_REG_USER=sv_reg_user
SV_DB_REG_PASS=sv-reg-pw-2026
SV_DB_REG_NAME=securevote_registration
SV_DB_ELEC_HOST=localhost
SV_DB_ELEC_PORT=3306
SV_DB_ELEC_USER=sv_elec_user
SV_DB_ELEC_PASS=sv-elec-pw-2026
SV_DB_ELEC_NAME=securevote_election
SV_DB_VOTES_HOST=localhost
SV_DB_VOTES_PORT=3306
SV_DB_VOTES_USER=sv_votes_user
SV_DB_VOTES_PASS=sv-votes-pw-2026
SV_DB_VOTES_NAME=securevote_votes
SV_SIM_ADDR=:8080
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable sv-machine
sudo systemctl start sv-machine
sudo systemctl status sv-machine
```

Repeat for `sv-admin`, `sv-verify`, and the admin portal (as a Python service).

Example for the admin portal:

```bash
sudo tee /etc/systemd/system/sv-admin-portal.service << 'EOF'
[Unit]
Description=SecureVote Admin Portal
After=mariadb.service

[Service]
Type=simple
User=securevote
Group=securevote
WorkingDirectory=/opt/securevote
ExecStart=/usr/bin/python3 /opt/securevote/docker/sv-idcard/admin_portal.py
EnvironmentFile=/opt/securevote/env/admin-portal.env
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## Step 8: Nginx Reverse Proxy (Optional)

```bash
sudo tee /etc/nginx/sites-available/securevote << 'EOF'
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }

    location /admin {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/securevote /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Add SSL
sudo certbot --nginx -d your-domain.com
```

## Step 9: Import Voter Data (Optional)

The import script uses `docker exec` by default. For standalone, load the data directly:

```bash
# Load raw Florida data
mariadb -u root -p << 'SQL'
CREATE DATABASE IF NOT EXISTS fl_voter_raw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

# Import the SQL dumps (these are large — 1.7GB each)
mariadb -u root -p fl_voter_raw < /path/to/voters_voters.sql
mariadb -u root -p fl_voter_raw < /path/to/voters_address.sql

# Transform into SecureVote schema
mariadb -u root -p securevote_registration << 'SQL'
INSERT IGNORE INTO voters (
    voter_uuid, legal_first_name, legal_middle_name, legal_last_name,
    legal_suffix, date_of_birth, registration_number, registration_date,
    registration_status, state_code, county_code, precinct_id,
    mailing_address_line1, mailing_city, mailing_state, mailing_zip,
    two_factor_enabled, two_factor_method, row_integrity_hash
)
SELECT
    UUID(), COALESCE(TRIM(v.First),'UNKNOWN'), NULLIF(TRIM(v.Middle),''),
    TRIM(v.Last), NULLIF(TRIM(v.Suffix),''), COALESCE(v.DOB,'1900-01-01'),
    CONCAT('FL-',LPAD(v.VID,10,'0')), COALESCE(v.DOR,v.EntryDate,'2020-01-01'),
    'ACTIVE', 'FL', COALESCE(v.County,'UNK'),
    CONCAT(COALESCE(v.County,'UNK'),'-',LPAD(v.VID%50+1,3,'0')),
    COALESCE(TRIM(a.Add1),''), COALESCE(TRIM(a.City),''),
    COALESCE(TRIM(a.State),'FL'), COALESCE(TRIM(a.Zip),''),
    FALSE, 'NONE',
    SHA2(CONCAT(v.VID,v.Last,v.First,COALESCE(v.DOB,'')),256)
FROM fl_voter_raw.voters v
LEFT JOIN (SELECT VID,Add1,City,State,Zip FROM fl_voter_raw.address GROUP BY VID) a ON v.VID=a.VID
WHERE v.First IS NOT NULL AND v.Last IS NOT NULL AND TRIM(v.Last)!=''
GROUP BY v.VID;
SQL

# Add indexes for fast search
mariadb -u root -p securevote_registration -e "
CREATE INDEX idx_first_name ON voters(legal_first_name);
ANALYZE TABLE voters;
"

# Clean up
mariadb -u root -p -e "DROP DATABASE fl_voter_raw"
```

## Step 10: Generate ID Cards (CLI)

```bash
# Search by name
python3 scripts/generate-id.py --name Dougan

# Generate by voter ID
python3 scripts/generate-id.py --voter-id 42

# Generate PDF
python3 scripts/generate-id.py --voter-id 42 --format pdf --output /tmp/cards/
```

**Note:** The standalone `generate-id.py` script uses `docker exec` to query the database. For standalone mode, you'll need to modify the `query_db()` function to use `mariadb` directly:

```python
def query_db(sql):
    cmd = ["mariadb", "-u", "sv_reg_user", "-psv-reg-pw-2026",
           "securevote_registration", "-N", "-B", "-e", sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0: return []
    return [l.split("\t") for l in r.stdout.rstrip("\n").split("\n") if l]
```

## Directory Structure

```
SecureVote/
├── bin/                        # Compiled Go binaries (not in git)
├── configs/                    # Service configuration files
│   ├── admin.toml
│   ├── verify.toml
│   └── machine.toml
├── docker/                     # Docker-specific (ignore for standalone)
│   └── sv-idcard/
│       └── admin_portal.py     # Admin portal (runs standalone too)
├── migrations/                 # SQL schemas
│   ├── registration/001_initial.sql
│   ├── election/001_initial.sql
│   └── votes/001_initial.sql
├── scripts/                    # Utility scripts
│   ├── seed.sh
│   ├── import-florida.sh
│   └── generate-id.py
├── src/                        # Go source code
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/
│   │   ├── sv-machine/main.go
│   │   ├── sv-admin/main.go
│   │   ├── sv-verify/main.go
│   │   └── sv-tabulator/main.go
│   ├── internal/
│   │   ├── crypto/provider.go
│   │   ├── machine/session.go
│   │   └── merkle/tree.go
│   └── pkg/
│       └── models/models.go
├── README.md
├── STANDALONE.md               # This file
├── DOCKER.md                   # Docker deployment guide
└── ADMIN.md                    # Admin portal user guide
```

## Security Notes for Production

1. **Change all passwords** in the database user creation step
2. **Bind MariaDB to localhost only** — edit `/etc/mysql/mariadb.conf.d/50-server.cnf`:
   ```ini
   bind-address = 127.0.0.1
   ```
3. **Firewall** — only expose ports 80/443 (nginx), block all database ports
4. **Run services as a non-root user** — create a `securevote` user
5. **Use separate machines** for the three databases in production
6. **Enable MariaDB audit logging** for compliance
7. **Back up databases daily** — especially the registration database

## Differences from Docker Deployment

| Feature | Docker | Standalone |
|---|---|---|
| Database isolation | Separate containers on separate networks | Separate databases, separate users, same server |
| Service isolation | Each service in its own container | Each service as a systemd unit |
| Networking | Docker networks enforce access control | Firewall rules + DB grants enforce access |
| Deployment | `docker compose up -d` | Build binaries + configure systemd |
| Updates | Rebuild containers | Rebuild binaries + restart services |
| Scaling | Add more containers | Add more servers |
| Complexity | Higher (Docker knowledge required) | Lower (standard Linux admin) |
| Security | Network-level isolation built in | Manual firewall + grant configuration |
