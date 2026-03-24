-- ============================================================================
-- SecureVote: Election Administration Database
-- Database: securevote_election
--
-- PURPOSE: Stores election definitions, ballot content, candidate/measure
-- registrations, precinct configurations, voting machine inventory, and
-- the signed Ballot Definition Files (BDFs).
--
-- SECURITY BOUNDARY: This database contains NO voter identity information
-- and NO vote selections. It is reference data shared (read-only) with
-- voting machines and tabulation systems.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS securevote_election
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE securevote_election;

-- ============================================================================
-- JURISDICTION & GEOGRAPHY
-- ============================================================================

-- ---------------------------------------------------------------------------
-- jurisdictions: States, counties, and municipalities.
-- ---------------------------------------------------------------------------
CREATE TABLE jurisdictions (
    jurisdiction_id         VARCHAR(50)         NOT NULL COMMENT 'Hierarchical ID: e.g., US-CA, US-CA-037 (LA County)',
    parent_jurisdiction_id  VARCHAR(50)         NULL,
    jurisdiction_type       ENUM('FEDERAL', 'STATE', 'COUNTY', 'MUNICIPALITY', 'TOWNSHIP') NOT NULL,
    name                    VARCHAR(200)        NOT NULL,
    fips_code               VARCHAR(10)         NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (jurisdiction_id),
    INDEX idx_parent (parent_jurisdiction_id),
    INDEX idx_type (jurisdiction_type),
    CONSTRAINT fk_jurisdiction_parent FOREIGN KEY (parent_jurisdiction_id)
        REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Jurisdiction hierarchy (federal > state > county > municipality)';


-- ---------------------------------------------------------------------------
-- precincts: Smallest voting unit. Each voter belongs to exactly one.
-- ---------------------------------------------------------------------------
CREATE TABLE precincts (
    precinct_id             VARCHAR(20)         NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    
    name                    VARCHAR(200)        NOT NULL,
    polling_place_name      VARCHAR(200)        NULL,
    polling_place_address   VARCHAR(500)        NULL,
    
    -- Capacity
    registered_voter_count  INT UNSIGNED        NOT NULL DEFAULT 0,
    machine_count           TINYINT UNSIGNED    NOT NULL DEFAULT 0,
    
    -- Status
    is_active               BOOLEAN             NOT NULL DEFAULT TRUE,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (precinct_id),
    INDEX idx_jurisdiction (jurisdiction_id),
    CONSTRAINT fk_precinct_jurisdiction FOREIGN KEY (jurisdiction_id)
        REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Voting precincts with polling place details';


-- ============================================================================
-- ELECTION & BALLOT CONTENT
-- ============================================================================

-- ---------------------------------------------------------------------------
-- elections: Master election record.
-- ---------------------------------------------------------------------------
CREATE TABLE elections (
    election_id             VARCHAR(50)         NOT NULL COMMENT 'e.g., general-2026-11-03',
    jurisdiction_id         VARCHAR(50)         NOT NULL COMMENT 'Highest jurisdiction this election covers',
    
    election_type           ENUM('GENERAL', 'PRIMARY', 'SPECIAL', 'RUNOFF', 'RECALL', 'LOCAL') NOT NULL,
    title                   VARCHAR(300)        NOT NULL,
    election_date           DATE                NOT NULL,
    
    -- Polls
    polls_open_time         TIME                NOT NULL COMMENT 'Local time polls open',
    polls_close_time        TIME                NOT NULL COMMENT 'Local time polls close',
    
    -- Key dates
    registration_deadline   DATE                NOT NULL,
    pin_mailing_start       DATE                NOT NULL COMMENT 'When election PINs start mailing',
    early_voting_start      DATE                NULL,
    early_voting_end        DATE                NULL,
    
    -- Status
    status                  ENUM(
                                'DRAFT',
                                'BDF_PENDING',
                                'BDF_SIGNED',
                                'MACHINES_LOADED',
                                'ACTIVE',
                                'POLLS_CLOSED',
                                'TABULATING',
                                'AUDITING',
                                'CERTIFIED',
                                'ARCHIVED'
                            )                   NOT NULL DEFAULT 'DRAFT',
    certified_at            DATETIME            NULL,
    certified_by            VARCHAR(200)        NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (election_id),
    INDEX idx_date (election_date),
    INDEX idx_jurisdiction (jurisdiction_id),
    INDEX idx_status (status),
    CONSTRAINT fk_election_jurisdiction FOREIGN KEY (jurisdiction_id)
        REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Master election definitions';


-- ---------------------------------------------------------------------------
-- races: Individual contests within an election.
-- ---------------------------------------------------------------------------
CREATE TABLE races (
    race_id                 VARCHAR(80)         NOT NULL COMMENT 'e.g., race-us-president-2026',
    election_id             VARCHAR(50)         NOT NULL,
    
    title                   VARCHAR(300)        NOT NULL COMMENT 'Display title: "President of the United States"',
    race_type               ENUM('FEDERAL', 'STATE', 'COUNTY', 'MUNICIPAL', 'JUDICIAL', 'SCHOOL_BOARD', 'OTHER') NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL COMMENT 'Jurisdiction this race applies to',
    
    -- Voting rules
    voting_rule             ENUM('CHOOSE_ONE', 'CHOOSE_N', 'RANKED_CHOICE', 'APPROVAL') NOT NULL DEFAULT 'CHOOSE_ONE',
    max_selections          TINYINT UNSIGNED    NOT NULL DEFAULT 1,
    write_in_allowed        BOOLEAN             NOT NULL DEFAULT FALSE,
    
    -- Display
    display_order           SMALLINT UNSIGNED   NOT NULL COMMENT 'Order on ballot',
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (race_id),
    INDEX idx_election (election_id),
    INDEX idx_jurisdiction (jurisdiction_id),
    CONSTRAINT fk_race_election FOREIGN KEY (election_id) REFERENCES elections(election_id),
    CONSTRAINT fk_race_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Individual races/contests within an election';


-- ---------------------------------------------------------------------------
-- candidates: People running in races.
-- ---------------------------------------------------------------------------
CREATE TABLE candidates (
    candidate_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    race_id                 VARCHAR(80)         NOT NULL,
    
    -- Identity
    legal_full_name         VARCHAR(200)        NOT NULL,
    display_name            VARCHAR(200)        NOT NULL COMMENT 'Name as shown on ballot',
    party                   VARCHAR(100)        NULL,
    
    -- Cryptographic binding
    candidate_hash_salt     CHAR(32)            NOT NULL COMMENT 'Random salt for this candidate',
    candidate_hash          CHAR(64)            NOT NULL COMMENT 'SHA-256(legal_full_name || party || race_id || election_id || salt)',
    
    -- Display
    display_order           SMALLINT UNSIGNED   NOT NULL,
    
    -- Status
    is_qualified            BOOLEAN             NOT NULL DEFAULT TRUE COMMENT 'Has met filing requirements',
    is_withdrawn            BOOLEAN             NOT NULL DEFAULT FALSE,
    withdrawn_at            DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (candidate_id),
    UNIQUE KEY uk_candidate_hash (candidate_hash),
    INDEX idx_race (race_id),
    INDEX idx_race_order (race_id, display_order),
    CONSTRAINT fk_candidate_race FOREIGN KEY (race_id) REFERENCES races(race_id)
) ENGINE=InnoDB
  COMMENT='Candidates in each race with cryptographic hash binding';


-- ---------------------------------------------------------------------------
-- ballot_measures: Propositions, referendums, initiatives.
-- ---------------------------------------------------------------------------
CREATE TABLE ballot_measures (
    measure_id              VARCHAR(80)         NOT NULL COMMENT 'e.g., measure-ca-prop-99',
    election_id             VARCHAR(50)         NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    
    title                   VARCHAR(300)        NOT NULL,
    summary                 TEXT                NOT NULL COMMENT 'Official summary text',
    full_text_url           VARCHAR(500)        NULL COMMENT 'Link to full measure text',
    
    -- Display
    display_order           SMALLINT UNSIGNED   NOT NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (measure_id),
    INDEX idx_election (election_id),
    INDEX idx_jurisdiction (jurisdiction_id),
    CONSTRAINT fk_measure_election FOREIGN KEY (election_id) REFERENCES elections(election_id),
    CONSTRAINT fk_measure_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Ballot measures (propositions, referendums, etc.)';


-- ---------------------------------------------------------------------------
-- measure_options: The choices for each ballot measure (Yes/No, etc.).
-- ---------------------------------------------------------------------------
CREATE TABLE measure_options (
    option_id               BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    measure_id              VARCHAR(80)         NOT NULL,
    
    display_name            VARCHAR(100)        NOT NULL COMMENT 'e.g., "Yes", "No", "For", "Against"',
    option_hash_salt        CHAR(32)            NOT NULL,
    option_hash             CHAR(64)            NOT NULL COMMENT 'SHA-256(display_name || measure_id || election_id || salt)',
    display_order           SMALLINT UNSIGNED   NOT NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (option_id),
    UNIQUE KEY uk_option_hash (option_hash),
    INDEX idx_measure (measure_id),
    CONSTRAINT fk_option_measure FOREIGN KEY (measure_id) REFERENCES ballot_measures(measure_id)
) ENGINE=InnoDB
  COMMENT='Options for ballot measures with cryptographic hash binding';


-- ============================================================================
-- BALLOT DEFINITION FILE (BDF)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- ballot_definitions: The signed, canonical ballot specification.
-- ---------------------------------------------------------------------------
CREATE TABLE ballot_definitions (
    bdf_id                  BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL COMMENT 'BDF may vary by precinct (different local races)',
    
    -- Version control
    version                 SMALLINT UNSIGNED   NOT NULL DEFAULT 1,
    is_current              BOOLEAN             NOT NULL DEFAULT TRUE,
    supersedes_bdf_id       BIGINT UNSIGNED     NULL COMMENT 'If revised, points to previous version',
    
    -- Content
    bdf_json                LONGTEXT            NOT NULL COMMENT 'The full BDF as canonical JSON',
    bdf_hash                CHAR(64)            NOT NULL COMMENT 'SHA-256 of bdf_json',
    
    -- Signing status
    signing_status          ENUM('DRAFT', 'PENDING_SIGNATURES', 'PARTIALLY_SIGNED', 'FULLY_SIGNED', 'PUBLISHED') NOT NULL DEFAULT 'DRAFT',
    required_signatures     TINYINT UNSIGNED    NOT NULL DEFAULT 3 COMMENT '3-of-5 threshold',
    current_signatures      TINYINT UNSIGNED    NOT NULL DEFAULT 0,
    published_at            DATETIME            NULL,
    
    -- Publication
    transparency_log_id     VARCHAR(200)        NULL COMMENT 'ID in public Certificate-Transparency-style log',
    transparency_log_url    VARCHAR(500)        NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (bdf_id),
    UNIQUE KEY uk_election_precinct_version (election_id, precinct_id, version),
    INDEX idx_election_current (election_id, is_current),
    INDEX idx_bdf_hash (bdf_hash),
    CONSTRAINT fk_bdf_election FOREIGN KEY (election_id) REFERENCES elections(election_id),
    CONSTRAINT fk_bdf_precinct FOREIGN KEY (precinct_id) REFERENCES precincts(precinct_id),
    CONSTRAINT fk_bdf_supersedes FOREIGN KEY (supersedes_bdf_id) REFERENCES ballot_definitions(bdf_id)
) ENGINE=InnoDB
  COMMENT='Signed Ballot Definition Files mapping human names to cryptographic hashes';


-- ---------------------------------------------------------------------------
-- bdf_signatures: Individual signatures on a BDF (multi-party threshold).
-- ---------------------------------------------------------------------------
CREATE TABLE bdf_signatures (
    signature_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    bdf_id                  BIGINT UNSIGNED     NOT NULL,
    
    signer_role             VARCHAR(100)        NOT NULL COMMENT 'e.g., "Secretary of State", "Democratic Observer"',
    signer_name             VARCHAR(200)        NOT NULL,
    signer_public_key       TEXT                NOT NULL COMMENT 'Base64-encoded Ed25519 public key',
    signature               TEXT                NOT NULL COMMENT 'Base64-encoded Ed25519 signature over bdf_hash',
    algorithm               VARCHAR(50)         NOT NULL DEFAULT 'Ed25519',
    
    signed_at               DATETIME            NOT NULL,
    
    -- Verification
    is_valid                BOOLEAN             NULL COMMENT 'Set by verification process; NULL = not yet verified',
    verified_at             DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (signature_id),
    INDEX idx_bdf (bdf_id),
    CONSTRAINT fk_sig_bdf FOREIGN KEY (bdf_id) REFERENCES ballot_definitions(bdf_id)
) ENGINE=InnoDB
  COMMENT='Individual multi-party signatures on Ballot Definition Files';


-- ============================================================================
-- VOTING MACHINES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- voting_machines: Hardware inventory and status.
-- ---------------------------------------------------------------------------
CREATE TABLE voting_machines (
    machine_id              VARCHAR(50)         NOT NULL COMMENT 'Unique hardware ID',
    
    -- Hardware details
    manufacturer            VARCHAR(100)        NOT NULL,
    model                   VARCHAR(100)        NOT NULL,
    serial_number           VARCHAR(100)        NOT NULL,
    firmware_version        VARCHAR(50)         NOT NULL,
    firmware_hash           CHAR(64)            NOT NULL COMMENT 'SHA-256 of installed firmware binary',
    expected_firmware_hash  CHAR(64)            NOT NULL COMMENT 'SHA-256 of official firmware build',
    firmware_match          BOOLEAN             GENERATED ALWAYS AS (firmware_hash = expected_firmware_hash) STORED,
    
    -- TPM attestation
    tpm_public_key          TEXT                NOT NULL COMMENT 'Machine identity key from TPM',
    last_attestation_at     DATETIME            NULL,
    last_attestation_passed BOOLEAN             NULL,
    
    -- Assignment
    assigned_precinct_id    VARCHAR(20)         NULL,
    assigned_election_id    VARCHAR(50)         NULL,
    
    -- Status
    machine_status          ENUM(
                                'IN_STORAGE',
                                'LAT_TESTING',
                                'LAT_PASSED',
                                'DEPLOYED',
                                'ACTIVE_VOTING',
                                'POLLS_CLOSED',
                                'QUARANTINED',
                                'DECOMMISSIONED'
                            )                   NOT NULL DEFAULT 'IN_STORAGE',
    
    -- Canary test results
    canary_test_passed      BOOLEAN             NULL,
    canary_test_at          DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (machine_id),
    UNIQUE KEY uk_serial (serial_number),
    INDEX idx_precinct (assigned_precinct_id),
    INDEX idx_election (assigned_election_id),
    INDEX idx_status (machine_status),
    INDEX idx_firmware_match (firmware_match),
    CONSTRAINT fk_machine_precinct FOREIGN KEY (assigned_precinct_id) REFERENCES precincts(precinct_id),
    CONSTRAINT fk_machine_election FOREIGN KEY (assigned_election_id) REFERENCES elections(election_id)
) ENGINE=InnoDB
  COMMENT='Voting machine inventory, firmware attestation, and deployment status';


-- ---------------------------------------------------------------------------
-- machine_seal_log: Tamper-evident seal tracking.
-- ---------------------------------------------------------------------------
CREATE TABLE machine_seal_log (
    seal_log_id             BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    machine_id              VARCHAR(50)         NOT NULL,
    
    action                  ENUM('SEALED', 'VERIFIED_INTACT', 'BROKEN', 'REPLACED') NOT NULL,
    seal_serial_number      VARCHAR(50)         NOT NULL,
    
    performed_by            VARCHAR(100)        NOT NULL,
    witness                 VARCHAR(100)        NULL COMMENT 'Second-party witness',
    performed_at            DATETIME            NOT NULL,
    
    notes                   TEXT                NULL,
    photo_hash              CHAR(64)            NULL COMMENT 'SHA-256 of photo evidence',
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (seal_log_id),
    INDEX idx_machine (machine_id, performed_at),
    INDEX idx_seal_serial (seal_serial_number),
    CONSTRAINT fk_seal_machine FOREIGN KEY (machine_id) REFERENCES voting_machines(machine_id)
) ENGINE=InnoDB
  COMMENT='Chain-of-custody seal tracking for each voting machine';


-- ============================================================================
-- ELECTION WORKERS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- election_workers: Authorized personnel for election operations.
-- ---------------------------------------------------------------------------
CREATE TABLE election_workers (
    worker_id               VARCHAR(50)         NOT NULL,
    
    full_name               VARCHAR(200)        NOT NULL,
    party_affiliation       VARCHAR(100)        NULL COMMENT 'For bipartisan pairing requirements',
    role                    ENUM(
                                'POLL_WORKER',
                                'CHIEF_JUDGE',
                                'ELECTION_SUPERVISOR',
                                'TABULATION_OFFICER',
                                'AUDIT_OBSERVER',
                                'TECHNICAL_SUPPORT'
                            )                   NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    
    -- Certification
    is_certified            BOOLEAN             NOT NULL DEFAULT FALSE,
    certification_date      DATE                NULL,
    certification_expires   DATE                NULL,
    training_completed      JSON                NULL COMMENT 'Array of completed training modules',
    
    -- Authentication
    credential_hash         CHAR(128)           NOT NULL COMMENT 'Argon2id hash of worker credential',
    credential_salt         CHAR(32)            NOT NULL,
    
    -- Status
    is_active               BOOLEAN             NOT NULL DEFAULT TRUE,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (worker_id),
    INDEX idx_jurisdiction (jurisdiction_id),
    INDEX idx_role_party (role, party_affiliation),
    CONSTRAINT fk_worker_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES jurisdictions(jurisdiction_id)
) ENGINE=InnoDB
  COMMENT='Authorized election workers with certification and party affiliation tracking';


-- ============================================================================
-- AUDIT LOG
-- ============================================================================

CREATE TABLE db_audit_log (
    audit_id                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    table_name              VARCHAR(100)        NOT NULL,
    operation               ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
    primary_key_value       VARCHAR(255)        NOT NULL,
    old_values_hash         CHAR(64)            NULL,
    new_values_hash         CHAR(64)            NULL,
    changed_columns         JSON                NULL,
    db_user                 VARCHAR(100)        NOT NULL,
    application_user        VARCHAR(100)        NULL,
    source_ip               VARCHAR(45)         NULL,
    previous_entry_hash     CHAR(64)            NULL,
    entry_hash              CHAR(64)            NOT NULL,
    created_at              DATETIME(6)         NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    
    PRIMARY KEY (audit_id),
    INDEX idx_table_time (table_name, created_at),
    INDEX idx_hash_chain (entry_hash)
) ENGINE=InnoDB
  COMMENT='Database-level audit log. INSERT-only for audit service account.';
