-- ============================================================================
-- SecureVote: Vote Recording Database
-- Database: securevote_votes
--
-- PURPOSE: Stores cast votes, ballot selections, Merkle trees, canary
-- records, and tabulation results. This is the most security-critical
-- database in the system.
--
-- SECURITY BOUNDARY: This database knows HOW people voted (every ballot
-- selection) but NEVER knows WHO cast each vote. Voter identity does not
-- exist here. Votes are linked only to blinded VoterTokens, which cannot
-- be traced back to a voter's identity.
--
-- CRITICAL INVARIANT: There must be NO foreign key or data link between
-- this database and securevote_registration. The only shared value is
-- election_id and precinct_id (reference data from securevote_election).
-- The VoterToken in this database is cryptographically unlinkable to
-- any record in securevote_registration.
--
-- PARTITIONING: vote_casts and vote_selections are partitioned by
-- precinct_id for write distribution and query performance on election day.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS securevote_votes
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE securevote_votes;

-- ============================================================================
-- CORE VOTE TABLES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- vote_casts: One record per ballot cast. The central table.
--
-- NOTE: voter_token is the UNBLINDED, signed token. The registration
-- database only ever saw the BLINDED version. These two values are
-- cryptographically unlinkable without the blinding factor, which
-- exists only in volatile memory on the voting machine during the
-- session and is destroyed afterward.
-- ---------------------------------------------------------------------------
CREATE TABLE vote_casts (
    vote_cast_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    vote_record_id          CHAR(36)            NOT NULL COMMENT 'UUIDv4 — the public-facing vote identifier',
    
    -- Election context
    election_id             VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    
    -- Anonymized voter proof
    voter_token             VARBINARY(512)      NOT NULL COMMENT 'Unblinded, blind-signed token proving a registered voter cast this',
    voter_token_hash        CHAR(64)            NOT NULL COMMENT 'SHA-256 of voter_token for fast lookup',
    voter_token_signature   VARBINARY(512)      NOT NULL COMMENT 'Election authority blind signature on the token',
    
    -- Biometric binding (one-way hash only; original template NOT stored here)
    biometric_hash          CHAR(64)            NOT NULL COMMENT 'SHA-256 of biometric template at time of auth',
    
    -- Machine and timing
    machine_id              VARCHAR(50)         NOT NULL,
    cast_timestamp          DATETIME(3)         NOT NULL COMMENT 'Millisecond precision',
    session_start           DATETIME(3)         NOT NULL COMMENT 'When voter was authenticated',
    session_end             DATETIME(3)         NOT NULL COMMENT 'When ballot was finalized',
    session_duration_sec    SMALLINT UNSIGNED   GENERATED ALWAYS AS (
                                TIMESTAMPDIFF(SECOND, session_start, session_end)
                            ) STORED,
    
    -- Cryptographic nonce (ensures unique hash even for identical selections)
    nonce                   CHAR(64)            NOT NULL COMMENT '256-bit random hex',
    
    -- Status
    status                  ENUM('VALID', 'SPOILED', 'TOMBSTONED', 'CANARY', 'PROVISIONAL') NOT NULL DEFAULT 'VALID',
    
    -- Spoiled vote tracking
    spoiled_reason          VARCHAR(255)        NULL COMMENT 'If SPOILED: why',
    replaced_by_vote_id     CHAR(36)            NULL COMMENT 'If SPOILED: the vote_record_id that replaced this',
    
    -- Tombstone tracking (Tier 2 correction)
    tombstone_reason        VARCHAR(500)        NULL,
    tombstone_authorizer_1  VARCHAR(100)        NULL COMMENT 'First authorizer (worker_id)',
    tombstone_authorizer_2  VARCHAR(100)        NULL COMMENT 'Second authorizer (different party)',
    tombstone_auth_1_party  VARCHAR(100)        NULL,
    tombstone_auth_2_party  VARCHAR(100)        NULL,
    tombstoned_at           DATETIME            NULL,
    replaced_by_corrected   CHAR(36)            NULL COMMENT 'If TOMBSTONED: the corrected vote_record_id',
    
    -- VVPAT reference
    vvpat_sequence_number   INT UNSIGNED        NULL COMMENT 'Position in the paper audit trail roll',
    vvpat_confirmed         BOOLEAN             NOT NULL DEFAULT FALSE COMMENT 'Voter confirmed paper matches intent',
    
    -- Merkle tree (populated after tree construction, post-polls-close)
    merkle_leaf_hash        CHAR(64)            NULL COMMENT 'SHA-256 of this entire VoteCast record',
    merkle_leaf_index       INT UNSIGNED        NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL COMMENT 'SHA-256 over all columns except this one and auto-increment ID',
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (vote_cast_id),
    UNIQUE KEY uk_vote_record_id (vote_record_id),
    UNIQUE KEY uk_voter_token_hash (voter_token_hash) COMMENT 'Enforces one vote per token',
    INDEX idx_election_precinct (election_id, precinct_id),
    INDEX idx_machine (machine_id),
    INDEX idx_status (status),
    INDEX idx_precinct_status (precinct_id, status),
    INDEX idx_cast_time (cast_timestamp),
    INDEX idx_biometric_hash (biometric_hash),
    INDEX idx_merkle_leaf (merkle_leaf_hash)
) ENGINE=InnoDB
  ROW_FORMAT=DYNAMIC
  COMMENT='Cast ballots. Contains selections via voter_token but NO voter identity.';


-- ---------------------------------------------------------------------------
-- vote_selections: Individual candidate/measure choices within a ballot.
-- Normalized from vote_casts for efficient tabulation queries.
-- ---------------------------------------------------------------------------
CREATE TABLE vote_selections (
    selection_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    vote_cast_id            BIGINT UNSIGNED     NOT NULL,
    vote_record_id          CHAR(36)            NOT NULL COMMENT 'Denormalized for fast lookups',
    
    -- What was selected
    race_id                 VARCHAR(80)         NOT NULL COMMENT 'References securevote_election.races',
    selection_hash          CHAR(64)            NOT NULL COMMENT 'CandidateHash or OptionHash that was chosen',
    
    -- Ranked choice / multi-select support
    rank_position           TINYINT UNSIGNED    NULL COMMENT 'For ranked-choice voting: 1 = first choice, etc.',
    
    -- Write-in handling
    is_write_in             BOOLEAN             NOT NULL DEFAULT FALSE,
    write_in_text_hash      CHAR(64)            NULL COMMENT 'SHA-256 of write-in name (original stored in encrypted write-in table)',
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamp
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (selection_id),
    INDEX idx_vote_cast (vote_cast_id),
    INDEX idx_vote_record (vote_record_id),
    INDEX idx_race_selection (race_id, selection_hash),
    INDEX idx_race_status (race_id),
    CONSTRAINT fk_selection_vote FOREIGN KEY (vote_cast_id) REFERENCES vote_casts(vote_cast_id)
) ENGINE=InnoDB
  ROW_FORMAT=DYNAMIC
  COMMENT='Individual selections per ballot, normalized for tabulation';


-- ---------------------------------------------------------------------------
-- write_in_entries: Encrypted write-in candidate names.
-- Stored separately because write-ins need human review during tabulation
-- but should remain encrypted until that point.
-- ---------------------------------------------------------------------------
CREATE TABLE write_in_entries (
    write_in_id             BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    selection_id            BIGINT UNSIGNED     NOT NULL,
    vote_record_id          CHAR(36)            NOT NULL,
    race_id                 VARCHAR(80)         NOT NULL,
    
    -- Encrypted write-in text (decrypted only during tabulation by authorized personnel)
    write_in_text_encrypted VARBINARY(1024)     NOT NULL COMMENT '[APP_ENCRYPTED] The actual write-in name',
    write_in_text_hash      CHAR(64)            NOT NULL COMMENT 'SHA-256 for matching against vote_selections',
    
    -- Tabulation
    resolved_candidate_hash CHAR(64)            NULL COMMENT 'If write-in maps to a known candidate, their hash',
    tabulation_status       ENUM('PENDING', 'RESOLVED', 'INVALID', 'ADJUDICATED') NOT NULL DEFAULT 'PENDING',
    adjudicated_by          VARCHAR(100)        NULL,
    adjudicated_at          DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamp
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (write_in_id),
    INDEX idx_selection (selection_id),
    INDEX idx_race (race_id),
    INDEX idx_status (tabulation_status),
    CONSTRAINT fk_writein_selection FOREIGN KEY (selection_id) REFERENCES vote_selections(selection_id)
) ENGINE=InnoDB
  COMMENT='Encrypted write-in entries, decrypted only during authorized tabulation';


-- ============================================================================
-- MERKLE TREE
-- ============================================================================

-- ---------------------------------------------------------------------------
-- merkle_trees: One tree per precinct per election.
-- ---------------------------------------------------------------------------
CREATE TABLE merkle_trees (
    tree_id                 BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    
    -- Tree properties
    leaf_count              INT UNSIGNED        NOT NULL COMMENT 'Total leaves (including canary and spoiled)',
    valid_vote_count        INT UNSIGNED        NOT NULL COMMENT 'Leaves with status VALID',
    tree_depth              TINYINT UNSIGNED    NOT NULL,
    
    -- Root
    merkle_root             CHAR(64)            NOT NULL COMMENT 'The root hash of this precinct tree',
    
    -- BDF binding
    genesis_bdf_hash        CHAR(64)            NOT NULL COMMENT 'BDF hash embedded as tree genesis; must match published BDF',
    
    -- Computation metadata
    computed_at             DATETIME            NOT NULL,
    computation_time_ms     INT UNSIGNED        NOT NULL COMMENT 'Time to build tree in milliseconds',
    computed_by_machine_id  VARCHAR(50)         NULL COMMENT 'Tabulation machine that built the tree',
    
    -- Publication
    published_at            DATETIME            NULL,
    transparency_log_id     VARCHAR(200)        NULL,
    
    -- Verification
    independently_verified  BOOLEAN             NOT NULL DEFAULT FALSE,
    verified_by             VARCHAR(200)        NULL COMMENT 'Organization that verified the tree',
    verified_at             DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (tree_id),
    UNIQUE KEY uk_election_precinct (election_id, precinct_id),
    INDEX idx_merkle_root (merkle_root),
    INDEX idx_election (election_id)
) ENGINE=InnoDB
  COMMENT='Precinct-level Merkle trees. One tree per precinct per election.';


-- ---------------------------------------------------------------------------
-- merkle_nodes: All internal nodes of the Merkle tree.
-- Stored for full public verifiability — anyone can recompute from leaves.
-- ---------------------------------------------------------------------------
CREATE TABLE merkle_nodes (
    node_id                 BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    tree_id                 BIGINT UNSIGNED     NOT NULL,
    
    -- Position in tree
    tree_level              SMALLINT UNSIGNED   NOT NULL COMMENT '0 = leaves, increasing toward root',
    node_index              INT UNSIGNED        NOT NULL COMMENT 'Position at this level (0-indexed)',
    
    -- Hash
    node_hash               CHAR(64)            NOT NULL,
    left_child_hash         CHAR(64)            NULL COMMENT 'NULL for leaf nodes',
    right_child_hash        CHAR(64)            NULL COMMENT 'NULL for leaf nodes; equals left if odd count padding',
    
    -- Leaf data reference (only for level 0)
    vote_record_id          CHAR(36)            NULL COMMENT 'Non-NULL only at level 0; references vote_casts',
    
    -- Timestamp
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (node_id),
    UNIQUE KEY uk_tree_level_index (tree_id, tree_level, node_index),
    INDEX idx_node_hash (node_hash),
    INDEX idx_vote_record (vote_record_id),
    CONSTRAINT fk_node_tree FOREIGN KEY (tree_id) REFERENCES merkle_trees(tree_id)
) ENGINE=InnoDB
  COMMENT='All Merkle tree nodes (leaves and internal) for full public verification';


-- ---------------------------------------------------------------------------
-- merkle_hierarchy: County and state level Merkle aggregation.
-- ---------------------------------------------------------------------------
CREATE TABLE merkle_hierarchy (
    hierarchy_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    
    -- Level
    level_type              ENUM('COUNTY', 'STATE', 'NATIONAL') NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    
    -- Aggregated root
    aggregated_root         CHAR(64)            NOT NULL COMMENT 'Merkle root of child roots',
    child_count             INT UNSIGNED        NOT NULL COMMENT 'Number of child trees/nodes',
    
    -- Child roots (JSON array of hashes for compact storage)
    child_roots_json        LONGTEXT            NOT NULL COMMENT 'JSON array of child Merkle roots in order',
    child_roots_hash        CHAR(64)            NOT NULL COMMENT 'SHA-256 of child_roots_json for integrity',
    
    -- Publication
    computed_at             DATETIME            NOT NULL,
    published_at            DATETIME            NULL,
    transparency_log_id     VARCHAR(200)        NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (hierarchy_id),
    UNIQUE KEY uk_election_level_jurisdiction (election_id, level_type, jurisdiction_id),
    INDEX idx_aggregated_root (aggregated_root)
) ENGINE=InnoDB
  COMMENT='County/state/national level Merkle tree aggregation';


-- ============================================================================
-- CANARY VOTES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- canary_definitions: Pre-determined test votes loaded before polls open.
-- ---------------------------------------------------------------------------
CREATE TABLE canary_definitions (
    canary_id               BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    machine_id              VARCHAR(50)         NOT NULL,
    
    -- Expected selections (JSON for flexibility)
    expected_selections     JSON                NOT NULL COMMENT 'Array of {race_id, selection_hash} pairs',
    expected_selections_hash CHAR(64)           NOT NULL COMMENT 'SHA-256 of canonical JSON',
    
    -- The vote_record_id that will be assigned to this canary
    assigned_vote_record_id CHAR(36)            NOT NULL,
    
    -- Defined by
    defined_by              VARCHAR(100)        NOT NULL,
    witness                 VARCHAR(100)        NOT NULL COMMENT 'Bipartisan witness',
    defined_at              DATETIME            NOT NULL,
    
    -- Verification result (populated after polls close)
    verification_status     ENUM('PENDING', 'PASSED', 'FAILED') NOT NULL DEFAULT 'PENDING',
    actual_selections_hash  CHAR(64)            NULL COMMENT 'SHA-256 of what was actually recorded',
    mismatch_details        TEXT                NULL COMMENT 'If FAILED: description of discrepancy',
    verified_at             DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (canary_id),
    UNIQUE KEY uk_canary_vote (assigned_vote_record_id),
    INDEX idx_election_machine (election_id, machine_id),
    INDEX idx_status (verification_status)
) ENGINE=InnoDB
  COMMENT='Pre-defined canary test votes for machine integrity verification';


-- ============================================================================
-- TABULATION
-- ============================================================================

-- ---------------------------------------------------------------------------
-- tabulation_results: Aggregated vote counts per race per precinct.
-- ---------------------------------------------------------------------------
CREATE TABLE tabulation_results (
    result_id               BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    race_id                 VARCHAR(80)         NOT NULL,
    
    -- Counts
    selection_hash          CHAR(64)            NOT NULL COMMENT 'CandidateHash or OptionHash',
    vote_count              INT UNSIGNED        NOT NULL,
    write_in_count          INT UNSIGNED        NOT NULL DEFAULT 0,
    
    -- Total context
    total_ballots_cast      INT UNSIGNED        NOT NULL COMMENT 'Total VALID ballots in this precinct',
    undervotes              INT UNSIGNED        NOT NULL DEFAULT 0 COMMENT 'Ballots with no selection in this race',
    overvotes               INT UNSIGNED        NOT NULL DEFAULT 0 COMMENT 'Ballots with too many selections (should be 0 with digital)',
    
    -- Tabulation metadata
    tabulated_at            DATETIME            NOT NULL,
    tabulated_by_machine    VARCHAR(50)         NULL,
    
    -- Certification
    is_certified            BOOLEAN             NOT NULL DEFAULT FALSE,
    certified_at            DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (result_id),
    UNIQUE KEY uk_result (election_id, precinct_id, race_id, selection_hash),
    INDEX idx_election_race (election_id, race_id),
    INDEX idx_precinct (precinct_id)
) ENGINE=InnoDB
  COMMENT='Aggregated tabulation results per candidate per race per precinct';


-- ---------------------------------------------------------------------------
-- tabulation_aggregates: County/state roll-ups.
-- ---------------------------------------------------------------------------
CREATE TABLE tabulation_aggregates (
    aggregate_id            BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    aggregation_level       ENUM('COUNTY', 'STATE', 'NATIONAL') NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    race_id                 VARCHAR(80)         NOT NULL,
    
    selection_hash          CHAR(64)            NOT NULL,
    vote_count              INT UNSIGNED        NOT NULL,
    write_in_count          INT UNSIGNED        NOT NULL DEFAULT 0,
    total_ballots_cast      INT UNSIGNED        NOT NULL,
    undervotes              INT UNSIGNED        NOT NULL DEFAULT 0,
    precinct_count          INT UNSIGNED        NOT NULL COMMENT 'Number of precincts included',
    precincts_reporting     INT UNSIGNED        NOT NULL DEFAULT 0,
    percent_reporting       DECIMAL(5,2)        GENERATED ALWAYS AS (
                                IF(precinct_count > 0, (precincts_reporting / precinct_count) * 100, 0)
                            ) STORED,
    
    -- Certification
    is_certified            BOOLEAN             NOT NULL DEFAULT FALSE,
    certified_at            DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (aggregate_id),
    UNIQUE KEY uk_aggregate (election_id, aggregation_level, jurisdiction_id, race_id, selection_hash),
    INDEX idx_race (election_id, race_id)
) ENGINE=InnoDB
  COMMENT='County/state/national vote count aggregations';


-- ============================================================================
-- RISK-LIMITING AUDIT (RLA)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- rla_sessions: One audit session per election per jurisdiction.
-- ---------------------------------------------------------------------------
CREATE TABLE rla_sessions (
    rla_id                  BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    jurisdiction_id         VARCHAR(50)         NOT NULL,
    race_id                 VARCHAR(80)         NOT NULL COMMENT 'RLA is per-race',
    
    -- Parameters
    risk_limit              DECIMAL(5,4)        NOT NULL COMMENT 'e.g., 0.0500 for 5%',
    random_seed             VARCHAR(200)        NOT NULL COMMENT 'Publicly generated random seed (e.g., dice ceremony)',
    audit_type              ENUM('BALLOT_COMPARISON', 'BALLOT_POLLING') NOT NULL DEFAULT 'BALLOT_COMPARISON',
    
    -- Sample sizing
    total_ballots           INT UNSIGNED        NOT NULL,
    initial_sample_size     INT UNSIGNED        NOT NULL,
    current_sample_size     INT UNSIGNED        NOT NULL,
    
    -- Results
    discrepancies_found     INT UNSIGNED        NOT NULL DEFAULT 0,
    status                  ENUM('IN_PROGRESS', 'PASSED', 'ESCALATED', 'FULL_RECOUNT') NOT NULL DEFAULT 'IN_PROGRESS',
    
    -- Timing
    started_at              DATETIME            NOT NULL,
    completed_at            DATETIME            NULL,
    
    -- Authorization
    initiated_by            VARCHAR(100)        NOT NULL,
    observer_party_a        VARCHAR(100)        NOT NULL,
    observer_party_b        VARCHAR(100)        NOT NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (rla_id),
    UNIQUE KEY uk_rla (election_id, jurisdiction_id, race_id),
    INDEX idx_status (status)
) ENGINE=InnoDB
  COMMENT='Risk-limiting audit sessions with parameters and outcomes';


-- ---------------------------------------------------------------------------
-- rla_samples: Individual ballot samples pulled during an RLA.
-- ---------------------------------------------------------------------------
CREATE TABLE rla_samples (
    sample_id               BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    rla_id                  BIGINT UNSIGNED     NOT NULL,
    
    -- Which ballot
    vote_record_id          CHAR(36)            NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    vvpat_sequence_number   INT UNSIGNED        NOT NULL,
    
    -- Comparison result
    digital_selection_hash  CHAR(64)            NOT NULL COMMENT 'What the digital record says',
    paper_selection_hash    CHAR(64)            NULL COMMENT 'What the paper ballot says (entered by auditor)',
    
    is_match                BOOLEAN             NULL COMMENT 'NULL until paper is reviewed',
    discrepancy_type        ENUM('NONE', 'SELECTION_MISMATCH', 'PAPER_DAMAGED', 'PAPER_MISSING', 'DIGITAL_MISSING') NULL,
    discrepancy_notes       TEXT                NULL,
    
    -- Who reviewed
    auditor_id              VARCHAR(100)        NOT NULL,
    witness_id              VARCHAR(100)        NOT NULL,
    reviewed_at             DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (sample_id),
    INDEX idx_rla (rla_id),
    INDEX idx_vote_record (vote_record_id),
    CONSTRAINT fk_sample_rla FOREIGN KEY (rla_id) REFERENCES rla_sessions(rla_id)
) ENGINE=InnoDB
  COMMENT='Individual ballot samples in a risk-limiting audit';


-- ============================================================================
-- VERIFICATION PORTAL
-- ============================================================================

-- ---------------------------------------------------------------------------
-- verification_attempts: Logged attempts to verify a vote via the portal.
-- ---------------------------------------------------------------------------
CREATE TABLE verification_attempts (
    attempt_id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    
    -- What was looked up
    vote_record_id_queried  CHAR(36)            NOT NULL,
    election_id             VARCHAR(50)         NOT NULL,
    
    -- Result
    was_found               BOOLEAN             NOT NULL,
    pin_auth_passed         BOOLEAN             NULL COMMENT 'NULL if vote not found (PIN not attempted)',
    merkle_proof_returned   BOOLEAN             NOT NULL DEFAULT FALSE,
    
    -- Anti-abuse tracking
    source_ip_hash          CHAR(64)            NOT NULL COMMENT 'SHA-256 of IP; we dont store raw IPs',
    attempt_number          SMALLINT UNSIGNED   NOT NULL COMMENT 'Nth attempt from this IP in the current window',
    was_rate_limited        BOOLEAN             NOT NULL DEFAULT FALSE,
    
    -- Timestamp
    attempted_at            DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (attempt_id),
    INDEX idx_vote_record (vote_record_id_queried, attempted_at),
    INDEX idx_ip_time (source_ip_hash, attempted_at),
    INDEX idx_rate_limit (source_ip_hash, was_rate_limited)
) ENGINE=InnoDB
  COMMENT='Logged verification portal access attempts for anti-abuse monitoring';


-- ============================================================================
-- MACHINE SESSION LOG
-- ============================================================================

-- ---------------------------------------------------------------------------
-- machine_sessions: Tracks every voting session on every machine.
-- Useful for anomaly detection (unusual session times, high spoil rates, etc).
--
-- NOTE: This table contains NO voter identity. machine_session_id is
-- internal; the voter never sees it.
-- ---------------------------------------------------------------------------
CREATE TABLE machine_sessions (
    session_id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    machine_id              VARCHAR(50)         NOT NULL,
    precinct_id             VARCHAR(20)         NOT NULL,
    
    -- Session timing
    session_start           DATETIME(3)         NOT NULL,
    session_end             DATETIME(3)         NULL COMMENT 'NULL if session abandoned',
    duration_sec            SMALLINT UNSIGNED   NULL,
    
    -- Authentication outcome (no identity, just result)
    auth_result             ENUM('AUTO_PASS', 'MANUAL_PASS', 'MANUAL_FAIL', 'TIMEOUT', 'ABORT') NOT NULL,
    biometric_confidence_a  DECIMAL(5,4)        NULL,
    biometric_confidence_b  DECIMAL(5,4)        NULL,
    manual_review_required  BOOLEAN             NOT NULL DEFAULT FALSE,
    
    -- Voting outcome
    vote_cast               BOOLEAN             NOT NULL DEFAULT FALSE COMMENT 'Did a VALID vote result?',
    vote_record_id          CHAR(36)            NULL COMMENT 'If cast, the vote_record_id',
    was_spoiled             BOOLEAN             NOT NULL DEFAULT FALSE,
    spoil_count             TINYINT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'How many times voter spoiled and re-did',
    
    -- Continuous presence monitoring
    presence_alerts         TINYINT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'Times face disappeared or changed',
    presence_pause_sec      SMALLINT UNSIGNED   NOT NULL DEFAULT 0 COMMENT 'Total seconds session was paused',
    
    -- Anomaly flags
    is_flagged              BOOLEAN             NOT NULL DEFAULT FALSE,
    flag_reason             VARCHAR(255)        NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (session_id),
    INDEX idx_election_machine (election_id, machine_id),
    INDEX idx_precinct (precinct_id),
    INDEX idx_vote_record (vote_record_id),
    INDEX idx_flagged (is_flagged),
    INDEX idx_session_time (session_start)
) ENGINE=InnoDB
  COMMENT='Per-session machine activity log for anomaly detection. No voter identity.';


-- ============================================================================
-- ANOMALY DETECTION
-- ============================================================================

-- ---------------------------------------------------------------------------
-- anomaly_alerts: System-generated alerts for suspicious patterns.
-- ---------------------------------------------------------------------------
CREATE TABLE anomaly_alerts (
    alert_id                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    election_id             VARCHAR(50)         NOT NULL,
    
    -- What triggered it
    alert_type              ENUM(
                                'HIGH_SPOIL_RATE',
                                'UNUSUAL_SESSION_DURATION',
                                'PRESENCE_LOSS_PATTERN',
                                'BIOMETRIC_MISMATCH_SPIKE',
                                'CANARY_FAILURE',
                                'MERKLE_INTEGRITY_FAILURE',
                                'TOKEN_COUNT_MISMATCH',
                                'FIRMWARE_HASH_MISMATCH',
                                'SEAL_BROKEN',
                                'NETWORK_ANOMALY',
                                'STATISTICAL_OUTLIER',
                                'MANUAL_REPORT'
                            )                   NOT NULL,
    severity                ENUM('INFO', 'WARNING', 'CRITICAL', 'EMERGENCY') NOT NULL,
    
    -- Context
    precinct_id             VARCHAR(20)         NULL,
    machine_id              VARCHAR(50)         NULL,
    description             TEXT                NOT NULL,
    evidence_json           JSON                NULL COMMENT 'Structured data supporting the alert',
    
    -- Response
    status                  ENUM('OPEN', 'ACKNOWLEDGED', 'INVESTIGATING', 'RESOLVED', 'FALSE_POSITIVE') NOT NULL DEFAULT 'OPEN',
    assigned_to             VARCHAR(100)        NULL,
    resolution_notes        TEXT                NULL,
    resolved_at             DATETIME            NULL,
    
    -- Row integrity
    row_integrity_hash      CHAR(64)            NOT NULL,
    
    -- Timestamps
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    PRIMARY KEY (alert_id),
    INDEX idx_election (election_id),
    INDEX idx_type_severity (alert_type, severity),
    INDEX idx_status (status),
    INDEX idx_precinct (precinct_id),
    INDEX idx_machine (machine_id)
) ENGINE=InnoDB
  COMMENT='System-generated anomaly alerts for investigation';


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


-- ============================================================================
-- VIEWS FOR COMMON QUERIES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tabulation view: Count valid votes per race per candidate per precinct.
-- This is the core tabulation query as a view.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_tabulation AS
SELECT
    vc.election_id,
    vc.precinct_id,
    vs.race_id,
    vs.selection_hash,
    COUNT(*)                    AS vote_count,
    SUM(vs.is_write_in)        AS write_in_count
FROM vote_casts vc
JOIN vote_selections vs ON vs.vote_cast_id = vc.vote_cast_id
WHERE vc.status = 'VALID'
GROUP BY vc.election_id, vc.precinct_id, vs.race_id, vs.selection_hash;


-- ---------------------------------------------------------------------------
-- Reconciliation view: Token count vs vote count per precinct.
-- These numbers MUST match. Any discrepancy is an emergency.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_reconciliation AS
SELECT
    election_id,
    precinct_id,
    COUNT(*)                                                    AS total_vote_casts,
    SUM(status = 'VALID')                                       AS valid_votes,
    SUM(status = 'SPOILED')                                     AS spoiled_votes,
    SUM(status = 'TOMBSTONED')                                  AS tombstoned_votes,
    SUM(status = 'CANARY')                                      AS canary_votes,
    SUM(status = 'PROVISIONAL')                                 AS provisional_votes,
    SUM(status IN ('VALID', 'PROVISIONAL'))                     AS expected_token_count
FROM vote_casts
GROUP BY election_id, precinct_id;


-- ---------------------------------------------------------------------------
-- Machine health view: Session statistics per machine for anomaly detection.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_machine_health AS
SELECT
    election_id,
    machine_id,
    precinct_id,
    COUNT(*)                                                    AS total_sessions,
    SUM(vote_cast)                                              AS successful_votes,
    SUM(was_spoiled)                                            AS spoiled_sessions,
    SUM(auth_result = 'MANUAL_FAIL')                            AS auth_failures,
    SUM(manual_review_required)                                 AS manual_reviews,
    AVG(duration_sec)                                           AS avg_session_sec,
    MAX(duration_sec)                                           AS max_session_sec,
    SUM(presence_alerts)                                        AS total_presence_alerts,
    SUM(is_flagged)                                             AS flagged_sessions
FROM machine_sessions
GROUP BY election_id, machine_id, precinct_id;
