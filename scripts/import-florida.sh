#!/usr/bin/env bash
# ============================================================================
# SecureVote — Florida Voter Data Import
# ============================================================================
#
# Imports real Florida voter registration data into SecureVote's
# registration database, mapping the FL schema to SecureVote's schema.
#
# Prerequisites:
#   1. The FL voter SQL dumps must be loaded into a temporary database first
#   2. SecureVote containers must be running
#
# Usage:
#   # Step 1: Load the raw FL data into a temp database
#   ./scripts/import-florida.sh load /path/to/voters_voters.sql /path/to/voters_address.sql
#
#   # Step 2: Transform and import into SecureVote (default: Palm Beach county, 1000 voters)
#   ./scripts/import-florida.sh import
#
#   # Or import a specific county and count:
#   ./scripts/import-florida.sh import PAL 5000
#   ./scripts/import-florida.sh import ALL 10000
#
#   # Step 3: Clean up temp database
#   ./scripts/import-florida.sh cleanup
# ============================================================================

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${BLUE}[Import]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

# Database connections
DB_REG="docker exec -i sv-db-registration mariadb -u root -psv-reg-root-2026"
DB_REG_USER="docker exec -i sv-db-registration mariadb -u sv_reg_user -psv-reg-pw-2026 securevote_registration"

ACTION="${1:-help}"

case "$ACTION" in

# ============================================================================
# STEP 1: Load raw FL data into a temp database inside the registration container
# ============================================================================
load)
    VOTERS_SQL="${2:?Usage: $0 load <voters_voters.sql> <voters_address.sql>}"
    ADDRESS_SQL="${3:?Usage: $0 load <voters_voters.sql> <voters_address.sql>}"

    log "Step 1: Loading raw Florida data into temp database..."

    # Create temp database
    echo "CREATE DATABASE IF NOT EXISTS fl_voter_raw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | $DB_REG
    ok "Created fl_voter_raw database"

    # Load voters table
    log "  Loading voters table (this may take a while for large files)..."
    # Pipe through sed to fix any MySQL 8 specific syntax that MariaDB might choke on
    cat "$VOTERS_SQL" | sed 's/ENGINE=MyISAM/ENGINE=InnoDB/g' | $DB_REG fl_voter_raw
    ok "Voters table loaded"

    # Load address table
    log "  Loading address table..."
    cat "$ADDRESS_SQL" | $DB_REG fl_voter_raw
    ok "Address table loaded"

    # Show counts
    VOTER_COUNT=$(echo "SELECT COUNT(*) FROM fl_voter_raw.voters" | $DB_REG -N fl_voter_raw)
    ADDR_COUNT=$(echo "SELECT COUNT(*) FROM fl_voter_raw.address" | $DB_REG -N fl_voter_raw)
    ok "Loaded ${VOTER_COUNT} voters, ${ADDR_COUNT} addresses"

    # Show available counties
    log "Available counties:"
    echo "SELECT County, COUNT(*) as cnt FROM fl_voter_raw.voters GROUP BY County ORDER BY cnt DESC LIMIT 20" | $DB_REG -t fl_voter_raw

    echo ""
    log "Next: ./scripts/import-florida.sh import [COUNTY_CODE] [LIMIT]"
    log "Example: ./scripts/import-florida.sh import PAL 5000"
    ;;

# ============================================================================
# STEP 2: Transform and import into SecureVote registration database
# ============================================================================
import)
    COUNTY="${2:-PAL}"
    LIMIT="${3:-1000}"

    log "Step 2: Importing into SecureVote registration database"
    log "  County filter: ${COUNTY}"
    log "  Limit: ${LIMIT} voters"
    echo ""

    # Check temp database exists
    echo "SELECT 1 FROM fl_voter_raw.voters LIMIT 1" | $DB_REG fl_voter_raw > /dev/null 2>&1 || {
        err "fl_voter_raw database not found. Run: $0 load <voters.sql> <address.sql>"
        exit 1
    }

    # Clear existing demo data from registration DB
    warn "Clearing existing voter data from securevote_registration..."
    $DB_REG_USER << 'CLEAR_SQL'
SET FOREIGN_KEY_CHECKS = 0;
DELETE FROM voter_election_pins;
DELETE FROM voter_token_issuance;
DELETE FROM voter_biometrics;
DELETE FROM voter_id_documents;
DELETE FROM registration_ledger;
DELETE FROM voters;
SET FOREIGN_KEY_CHECKS = 1;
CLEAR_SQL
    ok "Cleared existing data"

    # Build the county filter
    if [ "$COUNTY" = "ALL" ]; then
        COUNTY_WHERE="1=1"
    else
        COUNTY_WHERE="v.County = '${COUNTY}'"
    fi

    # Transform and insert voters
    log "Transforming and inserting voters..."
    $DB_REG << IMPORT_SQL
USE securevote_registration;
INSERT IGNORE INTO voters (
    voter_uuid,
    legal_first_name,
    legal_middle_name,
    legal_last_name,
    legal_suffix,
    date_of_birth,
    registration_number,
    registration_date,
    registration_status,
    state_code,
    county_code,
    precinct_id,
    mailing_address_line1,
    mailing_city,
    mailing_state,
    mailing_zip,
    two_factor_enabled,
    two_factor_method,
    row_integrity_hash
)
SELECT
    UUID(),
    COALESCE(TRIM(v.First), 'UNKNOWN'),
    NULLIF(TRIM(v.Middle), ''),
    TRIM(v.Last),
    NULLIF(TRIM(v.Suffix), ''),
    COALESCE(v.DOB, '1900-01-01'),
    CONCAT('FL-', LPAD(v.VID, 10, '0')),
    COALESCE(v.DOR, v.EntryDate, '2020-01-01'),
    'ACTIVE',
    'FL',
    COALESCE(v.County, 'UNK'),
    CONCAT(COALESCE(v.County, 'UNK'), '-', LPAD(v.VID % 50 + 1, 3, '0')),
    COALESCE(TRIM(a.Add1), ''),
    COALESCE(TRIM(a.City), ''),
    COALESCE(TRIM(a.State), 'FL'),
    COALESCE(TRIM(a.Zip), ''),
    FALSE,
    'NONE',
    SHA2(CONCAT(v.VID, v.Last, v.First, COALESCE(v.DOB, '')), 256)
FROM fl_voter_raw.voters v
LEFT JOIN (
    SELECT VID, Add1, City, State, Zip
    FROM fl_voter_raw.address
    GROUP BY VID
) a ON v.VID = a.VID
WHERE ${COUNTY_WHERE}
  AND v.First IS NOT NULL
  AND v.Last IS NOT NULL
  AND v.Last <> '*'
  AND TRIM(v.Last) != ''
GROUP BY v.VID
LIMIT ${LIMIT};


IMPORT_SQL
    IMPORTED=$(echo "SELECT COUNT(*) FROM securevote_registration.voters" | $DB_REG -N securevote_registration)
    ok "Imported ${IMPORTED} voters"

    # Generate ID documents for all imported voters
    log "Generating ID document records..."
    $DB_REG << 'ID_SQL'
USE securevote_registration;

INSERT IGNORE INTO voter_id_documents (
    voter_id, document_type, issuing_state, document_number_hash,
    expiration_date, extracted_data_hash, document_hash,
    verified_by, verified_at, is_primary, row_integrity_hash
)
SELECT
    v.voter_id,
    'DRIVERS_LICENSE',
    'FL',
    SHA2(CONCAT('FL-DL-', v.registration_number), 256),
    DATE_ADD(CURDATE(), INTERVAL FLOOR(1 + RAND() * 4) YEAR),
    SHA2(CONCAT(v.legal_first_name, v.legal_last_name, v.date_of_birth), 256),
    SHA2(CONCAT('doc-scan-', v.voter_id), 256),
    'SYSTEM',
    NOW(),
    TRUE,
    SHA2(CONCAT('id-', v.voter_id, v.registration_number), 256)
FROM voters v;
ID_SQL
    ok "ID documents generated"

    # Generate biometric templates
    log "Generating biometric templates..."
    $DB_REG << 'BIO_SQL'
USE securevote_registration;

INSERT IGNORE INTO voter_biometrics (
    voter_id, template_encrypted, template_hash, template_algorithm,
    capture_quality_score, captured_at, capture_source, is_active, row_integrity_hash
)
SELECT
    v.voter_id,
    UNHEX(SHA2(CONCAT('bio-template-', v.voter_id), 256)),
    SHA2(CONCAT('bio-template-', v.voter_id), 256),
    'ArcFace-v2.1+GeoNet-v1.3',
    0.9200 + (RAND() * 0.0800),
    DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 30) DAY),
    'REGISTRATION',
    TRUE,
    SHA2(CONCAT('bio-', v.voter_id), 256)
FROM voters v;
BIO_SQL
    ok "Biometric templates generated"

    # Generate election PINs
    log "Generating election PINs..."
    $DB_REG << 'PIN_SQL'
USE securevote_registration;

INSERT IGNORE INTO voter_election_pins (
    voter_id, election_id, pin_hash, pin_salt,
    mailed_at, delivery_confirmed, is_active, row_integrity_hash
)
SELECT
    v.voter_id,
    'general-2026-11-03',
    SHA2(CONCAT('pin-', v.voter_id, '-', FLOOR(RAND() * 999999)), 256),
    SUBSTRING(SHA2(RAND(), 256), 1, 32),
    DATE_SUB(NOW(), INTERVAL 14 DAY),
    TRUE,
    TRUE,
    SHA2(CONCAT('pin-', v.voter_id), 256)
FROM voters v;
PIN_SQL
    ok "Election PINs generated"

    # Also create precincts in the election database for the imported voters
    log "Syncing precincts to election database..."
    # Get unique precincts from the imported voters
    echo "SELECT DISTINCT precinct_id, county_code FROM securevote_registration.voters" | $DB_REG -N securevote_registration | while IFS=$'\t' read -r precinct county; do
        echo "INSERT IGNORE INTO securevote_election.precincts (precinct_id, jurisdiction_id, name, is_active, row_integrity_hash) VALUES ('${precinct}', 'US-FL', 'Florida Precinct ${precinct}', TRUE, SHA2('${precinct}', 256));" | $DB_REG securevote_election 2>/dev/null || true
    done
    ok "Precincts synced"

    # Make sure the FL jurisdiction exists
    $DB_REG << 'JURISDICTION_SQL'
INSERT IGNORE INTO securevote_election.jurisdictions (jurisdiction_id, parent_jurisdiction_id, jurisdiction_type, name, fips_code, row_integrity_hash) VALUES
('US-FL', 'US', 'STATE', 'Florida', '12', SHA2('US-FL', 256));
JURISDICTION_SQL
    ok "Florida jurisdiction created"

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}  Import complete!${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Voters imported:     ${IMPORTED}"
    echo "  ID documents:        ${IMPORTED}"
    echo "  Biometric records:   ${IMPORTED}"
    echo "  Election PINs:       ${IMPORTED}"
    echo ""
    echo "  County: ${COUNTY}"
    echo ""
    echo "  Test it:"
    echo "    Open https://vote.badvolf.com"
    echo "    Search for any last name"
    echo ""

    # Show sample of imported data
    log "Sample imported voters:"
    echo "SELECT voter_id, legal_first_name, legal_last_name, precinct_id, county_code FROM securevote_registration.voters ORDER BY RAND() LIMIT 10" | $DB_REG -t securevote_registration
    ;;

# ============================================================================
# STEP 3: Cleanup temp database
# ============================================================================
cleanup)
    log "Cleaning up temp database..."
    echo "DROP DATABASE IF EXISTS fl_voter_raw;" | $DB_REG
    ok "fl_voter_raw database dropped"
    ;;

# ============================================================================
# Help
# ============================================================================
*)
    echo ""
    echo "SecureVote — Florida Voter Data Import"
    echo ""
    echo "Usage:"
    echo "  $0 load <voters_voters.sql> <voters_address.sql>"
    echo "      Load raw FL data into temp database"
    echo ""
    echo "  $0 import [COUNTY_CODE] [LIMIT]"
    echo "      Transform and import into SecureVote"
    echo "      Default: PAL county, 1000 voters"
    echo "      Use ALL for all counties"
    echo ""
    echo "  $0 cleanup"
    echo "      Remove temp database"
    echo ""
    echo "Examples:"
    echo "  $0 load /path/to/voters_voters.sql /path/to/voters_address.sql"
    echo "  $0 import PAL 5000     # 5000 Palm Beach voters"
    echo "  $0 import ALL 10000    # 10000 from all counties"
    echo "  $0 cleanup"
    echo ""
    ;;

esac
