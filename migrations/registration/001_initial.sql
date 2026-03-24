-- ============================================================================
-- SecureVote: Voter Registration Database
-- Database: securevote_registration
--
-- PURPOSE: Stores voter identity, enrollment, ID documents, biometric
-- templates, election PINs, and token issuance records.
--
-- SECURITY BOUNDARY: This database knows WHO voted (token issued) but
-- NEVER stores HOW they voted. No vote content exists here.
--
-- ENCRYPTION: InnoDB tablespace encryption (AES-256-CBC) + application-level
-- AES-256-GCM on high-sensitivity columns (marked with [APP_ENCRYPTED]).
-- ============================================================================

CREATE DATABASE IF NOT EXISTS securevote_registration
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE securevote_registration;

-- ============================================================================
-- CORE VOTER TABLES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- voters: Master voter record. One row per registered voter.
-- ---------------------------------------------------------------------------
CREATE TABLE voters (
    voter_id                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_uuid              CHAR(36)            NOT NULL COMMENT 'Public-facing unique ID (UUIDv4)',
    
    -- Legal identity
    legal_first_name        VARCHAR(100)        NOT NULL,
    legal_middle_name       VARCHAR(100)        NULL,
    legal_last_name         VARCHAR(100)        NOT NULL,
    legal_suffix            VARCHAR(20)         NULL COMMENT 'Jr, Sr, III, etc.',
    date_of_birth           DATE                NOT NULL,
    
    -- Registration details
    registration_number     VARCHAR(50)         NOT NULL COMMENT 'State-assigned voter registration number',
    registration_date       DATE                NOT NULL,
    registration_status     ENUM(
                                'ACTIVE',
                                'INACTIVE',
                                'SUSPENDED',
                                'CANCELLED',
                                'PENDING_VERIFICATION'
                            )                   NOT NULL DEFAULT 'PENDING_VERIFICATION',
    status_reason           VARCHAR(255)        NULL COMMENT 'Reason for non-ACTIVE status',
    status_changed_at       DATETIME            NULL,
    status_changed_by       VARCHAR(100)        NULL COMMENT 'Operator or system that changed status',
    
    -- Jurisdiction
    state_code              CHAR(2)             NOT NULL COMMENT 'FIPS state code',
    county_code             VARCHAR(10)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    congressional_district  VARCHAR(10)         NULL,
    state_senate_district   VARCHAR(10)         NULL,
    state_house_district    VARCHAR(10)         NULL,
    
    -- Contact (optional, used for PIN mailing and 2FA)
    mailing_address_line1   VARCHAR(200)        NULL,
    mailing_address_line2   VARCHAR(200)        NULL,
    mailing_city            VARCHAR(100)        NULL,
    mailing_state           CHAR(2)             NULL,
    mailing_zip             VARCHAR(10)         NULL,
    phone_number_encrypted  VARBINARY(512)      NULL COMMENT '[APP_ENCRYPTED] For optional 2FA',
    email_encrypted         VARBINARY(512)      NULL COMMENT '[APP_ENCRYPTED] For optional notifications',
    
    -- Opt-in features
    two_factor_enabled      BOOLEAN             NOT NULL DEFAULT FALSE,
    two_factor_method       ENUM('SMS', 'EMAIL', 'NONE') NOT NULL DEFAULT 'NONE',
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL COMMENT 'SHA-256 over all other columns',
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (voter_id),
    UNIQUE KEY uk_voter_uuid (voter_uuid),
    UNIQUE KEY uk_registration_number (state_code, registration_number),
    INDEX idx_precinct (precinct_id),
    INDEX idx_name_dob (legal_last_name, legal_first_name, date_of_birth),
    INDEX idx_status (registration_status),
    INDEX idx_county (state_code, county_code)
) ENGINE=InnoDB
  ROW_FORMAT=DYNAMIC
  COMMENT='Master voter registration records';


-- ---------------------------------------------------------------------------
-- voter_id_documents: Scanned ID records. Multiple IDs per voter possible.
-- ---------------------------------------------------------------------------
CREATE TABLE voter_id_documents (
    document_id             BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_id                BIGINT UNSIGNED     NOT NULL,
    
    -- Document details
    document_type           ENUM(
                                'DRIVERS_LICENSE',
                                'STATE_ID',
                                'PASSPORT',
                                'MILITARY_ID',
                                'TRIBAL_ID',
                                'VOTER_ID_CARD'
                            )                   NOT NULL,
    issuing_state           CHAR(2)             NULL COMMENT 'NULL for federal/tribal docs',
    document_number_hash    CHAR(64)            NOT NULL COMMENT 'SHA-256 of document number; original not stored',
    expiration_date         DATE                NULL,
    is_expired              BOOLEAN             GENERATED ALWAYS AS (expiration_date < CURDATE()) STORED,
    
    -- Scanned images (application-level encrypted, stored as blobs)
    front_scan_encrypted    MEDIUMBLOB          NULL COMMENT '[APP_ENCRYPTED] Front of ID',
    back_scan_encrypted     MEDIUMBLOB          NULL COMMENT '[APP_ENCRYPTED] Back of ID',
    scan_quality_score      DECIMAL(5,4)        NULL COMMENT 'OCR confidence score 0.0000-1.0000',
    
    -- Extracted data hash (for verification without storing cleartext)
    extracted_data_hash     CHAR(64)            NOT NULL COMMENT 'SHA-256 of OCR-extracted fields',
    
    -- Metadata
    document_hash           CHAR(64)            NOT NULL COMMENT 'SHA-256 of both scan images combined',
    verified_by             VARCHAR(100)        NULL COMMENT 'Operator who verified, or SYSTEM',
    verified_at             DATETIME            NULL,
    is_primary              BOOLEAN             NOT NULL DEFAULT FALSE COMMENT 'Primary ID for this voter',
    is_reported_stolen      BOOLEAN             NOT NULL DEFAULT FALSE,
    stolen_reported_at      DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (document_id),
    INDEX idx_voter (voter_id),
    INDEX idx_doc_number_hash (document_number_hash),
    INDEX idx_stolen (is_reported_stolen),
    CONSTRAINT fk_doc_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB
  ROW_FORMAT=DYNAMIC
  COMMENT='Voter identification documents (scans encrypted at app level)';


-- ---------------------------------------------------------------------------
-- voter_biometrics: Encrypted biometric templates. One active per voter.
-- ---------------------------------------------------------------------------
CREATE TABLE voter_biometrics (
    biometric_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_id                BIGINT UNSIGNED     NOT NULL,
    
    -- Template data (NEVER store raw images here; only mathematical templates)
    template_encrypted      MEDIUMBLOB          NOT NULL COMMENT '[APP_ENCRYPTED] Facial geometry template',
    template_hash           CHAR(64)            NOT NULL COMMENT 'SHA-256 of unencrypted template; used in vote records',
    template_algorithm      VARCHAR(50)         NOT NULL COMMENT 'Algorithm version that generated this template',
    
    -- Quality and capture metadata
    capture_quality_score   DECIMAL(5,4)        NOT NULL COMMENT 'Biometric capture quality 0.0000-1.0000',
    captured_at             DATETIME            NOT NULL,
    capture_source          ENUM('REGISTRATION', 'POLLING_PLACE', 'UPDATE') NOT NULL,
    capture_machine_id      VARCHAR(50)         NULL,
    
    -- Status
    is_active               BOOLEAN             NOT NULL DEFAULT TRUE,
    superseded_by           BIGINT UNSIGNED     NULL COMMENT 'If replaced, points to new biometric_id',
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (biometric_id),
    INDEX idx_voter_active (voter_id, is_active),
    INDEX idx_template_hash (template_hash),
    CONSTRAINT fk_bio_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id),
    CONSTRAINT fk_bio_superseded FOREIGN KEY (superseded_by) REFERENCES voter_biometrics(biometric_id)
) ENGINE=InnoDB
  ROW_FORMAT=DYNAMIC
  COMMENT='Voter biometric templates (encrypted at app level)';


-- ============================================================================
-- ELECTION PIN & AUTHENTICATION TABLES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- voter_election_pins: Unique PINs issued per voter per election.
-- ---------------------------------------------------------------------------
CREATE TABLE voter_election_pins (
    pin_id                  BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_id                BIGINT UNSIGNED     NOT NULL,
    election_id             VARCHAR(50)         NOT NULL COMMENT 'References securevote_election.elections.election_id',
    
    -- PIN storage (Argon2id hashed, never stored in cleartext)
    pin_hash                CHAR(128)           NOT NULL COMMENT 'Argon2id hash of the election PIN',
    pin_salt                CHAR(32)            NOT NULL COMMENT 'Unique salt for this PIN',
    
    -- Delivery tracking
    mailed_at               DATETIME            NULL,
    mailing_address_hash    CHAR(64)            NULL COMMENT 'SHA-256 of address PIN was mailed to',
    delivery_confirmed      BOOLEAN             NOT NULL DEFAULT FALSE,
    
    -- Usage tracking
    is_active               BOOLEAN             NOT NULL DEFAULT TRUE,
    failed_attempts         TINYINT UNSIGNED    NOT NULL DEFAULT 0,
    locked_until            DATETIME            NULL COMMENT 'Set after max failed attempts',
    last_used_at            DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (pin_id),
    UNIQUE KEY uk_voter_election_pin (voter_id, election_id),
    INDEX idx_election (election_id),
    CONSTRAINT fk_pin_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB
  COMMENT='Election-specific PINs for post-election vote verification';


-- ---------------------------------------------------------------------------
-- voter_token_issuance: Records that a blind-signed token was issued.
--
-- CRITICAL: This table records that voter X received a token for election Y.
-- It does NOT store the token itself or any information about how the voter
-- voted. The token value is blinded — the system that issues it never sees
-- the unblinded form, so even this database cannot link to a VoteCast.
-- ---------------------------------------------------------------------------
CREATE TABLE voter_token_issuance (
    issuance_id             BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_id                BIGINT UNSIGNED     NOT NULL,
    election_id             VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    
    -- Token metadata (NOT the token itself)
    blinded_token_hash      CHAR(64)            NOT NULL COMMENT 'SHA-256 of the BLINDED token (not the unblinded token)',
    issued_at               DATETIME            NOT NULL,
    issuing_machine_id      VARCHAR(50)         NOT NULL,
    
    -- Authentication details for this issuance
    auth_method             ENUM('BIOMETRIC_AUTO', 'BIOMETRIC_MANUAL', 'MANUAL_OVERRIDE', 'PIN_FALLBACK') NOT NULL,
    biometric_confidence_a  DECIMAL(5,4)        NULL COMMENT 'Model A confidence score',
    biometric_confidence_b  DECIMAL(5,4)        NULL COMMENT 'Model B confidence score',
    manual_verifier_id      VARCHAR(100)        NULL COMMENT 'Poll worker ID if manual verification used',
    
    -- Status
    is_void                 BOOLEAN             NOT NULL DEFAULT FALSE,
    void_reason             VARCHAR(255)        NULL,
    voided_by               VARCHAR(100)        NULL,
    voided_at               DATETIME            NULL,
    
    -- Integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (issuance_id),
    UNIQUE KEY uk_voter_election (voter_id, election_id) COMMENT 'One token per voter per election',
    INDEX idx_election_precinct (election_id, precinct_id),
    INDEX idx_machine (issuing_machine_id),
    INDEX idx_blinded_hash (blinded_token_hash),
    CONSTRAINT fk_issuance_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB
  COMMENT='Tracks that a blinded token was issued to a voter; cannot link to actual vote';


-- ============================================================================
-- VOTER REGISTRATION LEDGER (append-only change history)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- registration_ledger: Every change to a voter record is logged here.
-- This table implements the append-only ledger for voter roll integrity.
-- ---------------------------------------------------------------------------
CREATE TABLE registration_ledger (
    ledger_id               BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    voter_id                BIGINT UNSIGNED     NOT NULL,
    
    -- What changed
    action                  ENUM(
                                'REGISTERED',
                                'STATUS_CHANGED',
                                'ADDRESS_CHANGED',
                                'NAME_CHANGED',
                                'PRECINCT_CHANGED',
                                'ID_ADDED',
                                'ID_REMOVED',
                                'BIOMETRIC_ENROLLED',
                                'BIOMETRIC_UPDATED',
                                'PIN_ISSUED',
                                'TOKEN_ISSUED',
                                'TOKEN_VOIDED',
                                'CANCELLED',
                                'REINSTATED',
                                'PURGE_FLAGGED',
                                'PURGE_CHALLENGED',
                                'PURGE_EXECUTED'
                            )                   NOT NULL,
    action_details          JSON                NULL COMMENT 'Structured details of the change',
    
    -- Who authorized it
    performed_by            VARCHAR(100)        NOT NULL COMMENT 'Operator ID, system name, or "VOTER_SELF"',
    secondary_authorizer    VARCHAR(100)        NULL COMMENT 'Second authorizer for sensitive changes (e.g., purges)',
    
    -- Hash chain (tamper-evident log)
    previous_entry_hash     CHAR(64)            NULL COMMENT 'SHA-256 of the previous ledger entry for this voter; NULL for first entry',
    entry_hash              CHAR(64)            NOT NULL COMMENT 'SHA-256 of this entire entry',
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (ledger_id),
    INDEX idx_voter_chronological (voter_id, created_at),
    INDEX idx_action (action),
    INDEX idx_hash_chain (voter_id, entry_hash),
    INDEX idx_purge_tracking (action, created_at),
    CONSTRAINT fk_ledger_voter FOREIGN KEY (voter_id) REFERENCES voters(voter_id)
) ENGINE=InnoDB
  COMMENT='Append-only change ledger for voter registration. Hash-chained for tamper evidence.';


-- ============================================================================
-- AUDIT LOG (database-level operations)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- db_audit_log: Captures all data modifications for forensic review.
-- Written by a SEPARATE service account with INSERT-only privileges.
-- ---------------------------------------------------------------------------
CREATE TABLE db_audit_log (
    audit_id                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    
    -- What happened
    table_name              VARCHAR(100)        NOT NULL,
    operation               ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
    primary_key_value       VARCHAR(255)        NOT NULL COMMENT 'PK of the affected row',
    
    -- Change data
    old_values_hash         CHAR(64)            NULL COMMENT 'SHA-256 of old row values (NULL for INSERT)',
    new_values_hash         CHAR(64)            NULL COMMENT 'SHA-256 of new row values (NULL for DELETE)',
    changed_columns         JSON                NULL COMMENT 'List of columns that changed (for UPDATE)',
    
    -- Who/what performed the operation
    db_user                 VARCHAR(100)        NOT NULL,
    application_user        VARCHAR(100)        NULL,
    source_ip               VARCHAR(45)         NULL,
    
    -- Hash chain
    previous_entry_hash     CHAR(64)            NULL,
    entry_hash              CHAR(64)            NOT NULL,
    
    -- Timestamp
    created_at              DATETIME(6)         NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT 'Microsecond precision',
    
    PRIMARY KEY (audit_id),
    INDEX idx_table_time (table_name, created_at),
    INDEX idx_operation (operation, created_at),
    INDEX idx_hash_chain (entry_hash)
) ENGINE=InnoDB
  COMMENT='Database-level audit log. INSERT-only access for the audit service account.';
