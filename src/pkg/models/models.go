// Package models defines the core domain types shared across all SecureVote services.
// These types are public (in pkg/) so external auditors and verification tools can
// import and use them to independently verify election data.
package models

import "time"

// --- Session States ---

// SessionState represents the current state of a voter's interaction with the machine.
type SessionState string

const (
	StateIdle              SessionState = "IDLE"
	StateIDScanning        SessionState = "ID_SCANNING"
	StateBiometricMatching SessionState = "BIOMETRIC_MATCHING"
	StateManualReview      SessionState = "MANUAL_REVIEW"
	StateTwoFactor         SessionState = "TWO_FACTOR"
	StateTokenIssuance     SessionState = "TOKEN_ISSUANCE"
	StateBallotActive      SessionState = "BALLOT_ACTIVE"
	StatePaused            SessionState = "PAUSED"
	StateSpoiled           SessionState = "SPOILED"
	StateVVPATReview       SessionState = "VVPAT_REVIEW"
	StateRecording         SessionState = "RECORDING"
	StateReceipt           SessionState = "RECEIPT"
	StateAuthFailed        SessionState = "AUTH_FAILED"
	StateSessionEnd        SessionState = "SESSION_END"
)

// --- Vote Status ---

// VoteStatus indicates the current state of a VoteCast record.
type VoteStatus string

const (
	VoteStatusValid       VoteStatus = "VALID"
	VoteStatusSpoiled     VoteStatus = "SPOILED"
	VoteStatusTombstoned  VoteStatus = "TOMBSTONED"
	VoteStatusCanary      VoteStatus = "CANARY"
	VoteStatusProvisional VoteStatus = "PROVISIONAL"
)

// --- Authentication ---

// AuthMethod records how the voter was authenticated.
type AuthMethod string

const (
	AuthBiometricAuto   AuthMethod = "BIOMETRIC_AUTO"
	AuthBiometricManual AuthMethod = "BIOMETRIC_MANUAL"
	AuthManualOverride  AuthMethod = "MANUAL_OVERRIDE"
	AuthPINFallback     AuthMethod = "PIN_FALLBACK"
)

// BiometricResult holds the output of a dual-model biometric match.
type BiometricResult struct {
	ModelAConfidence float64 `json:"model_a_confidence"`
	ModelBConfidence float64 `json:"model_b_confidence"`
	AutoApproved     bool    `json:"auto_approved"`
	RequiresManual   bool    `json:"requires_manual"`
	Rejected         bool    `json:"rejected"`
	TemplateHash     string  `json:"template_hash"` // SHA-256 of the biometric template
}

// IDScanResult holds the output of scanning a voter's ID.
type IDScanResult struct {
	DocumentType     string  `json:"document_type"`
	DocumentNumHash  string  `json:"document_number_hash"` // SHA-256 of document number
	FullName         string  `json:"full_name"`
	DateOfBirth      string  `json:"date_of_birth"`
	IssuingState     string  `json:"issuing_state"`
	ExpirationDate   string  `json:"expiration_date"`
	IsExpired        bool    `json:"is_expired"`
	ScanQualityScore float64 `json:"scan_quality_score"`
	FrontImageHash   string  `json:"front_image_hash"`
	BackImageHash    string  `json:"back_image_hash"`
	DocumentHash     string  `json:"document_hash"` // SHA-256 of both images combined
}

// --- Voter & Registration ---

// Voter represents a registered voter (from securevote_registration).
type Voter struct {
	VoterID            int64  `json:"voter_id"`
	VoterUUID          string `json:"voter_uuid"`
	LegalFirstName     string `json:"legal_first_name"`
	LegalMiddleName    string `json:"legal_middle_name,omitempty"`
	LegalLastName      string `json:"legal_last_name"`
	DateOfBirth        string `json:"date_of_birth"`
	RegistrationNumber string `json:"registration_number"`
	RegistrationStatus string `json:"registration_status"`
	StateCode          string `json:"state_code"`
	CountyCode         string `json:"county_code"`
	PrecinctID         string `json:"precinct_id"`
	TwoFactorEnabled   bool   `json:"two_factor_enabled"`
	TwoFactorMethod    string `json:"two_factor_method"`
}

// EligibilityResult is the outcome of checking whether a voter can vote in an election.
type EligibilityResult struct {
	IsEligible       bool   `json:"is_eligible"`
	Reason           string `json:"reason,omitempty"`            // If not eligible, why
	TokenAlreadyUsed bool   `json:"token_already_issued"`       // Has a token been issued for this election?
	IDReportedStolen bool   `json:"id_reported_stolen"`
}

// --- Blind Tokens ---

// BlindToken is the anonymized proof that a registered voter cast a ballot.
type BlindToken struct {
	Token          []byte `json:"token"`           // The unblinded token
	TokenHash      string `json:"token_hash"`      // SHA-256 of Token
	Signature      []byte `json:"signature"`       // Blind signature from election authority
	BlindedHash    string `json:"blinded_hash"`    // SHA-256 of the blinded form (stored in registration DB)
}

// TokenIssuance records that a token was issued (stored in securevote_registration).
type TokenIssuance struct {
	VoterID            int64      `json:"voter_id"`
	ElectionID         string     `json:"election_id"`
	PrecinctID         string     `json:"precinct_id"`
	BlindedTokenHash   string     `json:"blinded_token_hash"`
	IssuedAt           time.Time  `json:"issued_at"`
	IssuingMachineID   string     `json:"issuing_machine_id"`
	AuthMethod         AuthMethod `json:"auth_method"`
	BiometricConfidA   float64    `json:"biometric_confidence_a,omitempty"`
	BiometricConfidB   float64    `json:"biometric_confidence_b,omitempty"`
	ManualVerifierID   string     `json:"manual_verifier_id,omitempty"`
}

// --- Election & Ballot ---

// Election represents a master election record.
type Election struct {
	ElectionID           string    `json:"election_id"`
	JurisdictionID       string    `json:"jurisdiction_id"`
	ElectionType         string    `json:"election_type"`
	Title                string    `json:"title"`
	ElectionDate         string    `json:"election_date"`
	PollsOpenTime        string    `json:"polls_open_time"`
	PollsCloseTime       string    `json:"polls_close_time"`
	Status               string    `json:"status"`
}

// Race represents a single contest within an election.
type Race struct {
	RaceID         string `json:"race_id"`
	ElectionID     string `json:"election_id"`
	Title          string `json:"title"`
	RaceType       string `json:"race_type"`
	VotingRule     string `json:"voting_rule"`
	MaxSelections  int    `json:"max_selections"`
	WriteInAllowed bool   `json:"write_in_allowed"`
	DisplayOrder   int    `json:"display_order"`
}

// Candidate represents a person running in a race.
type Candidate struct {
	CandidateID   int64  `json:"candidate_id"`
	RaceID        string `json:"race_id"`
	DisplayName   string `json:"display_name"`
	Party         string `json:"party,omitempty"`
	CandidateHash string `json:"candidate_hash"` // SHA-256(name || party || race || election || salt)
	DisplayOrder  int    `json:"display_order"`
	IsQualified   bool   `json:"is_qualified"`
}

// BallotDefinition is the parsed, verified BDF for a specific precinct.
type BallotDefinition struct {
	ElectionID  string            `json:"election_id"`
	PrecinctID  string            `json:"precinct_id"`
	Version     int               `json:"version"`
	BDFHash     string            `json:"bdf_hash"`
	Races       []Race            `json:"races"`
	Candidates  map[string][]Candidate `json:"candidates"` // keyed by race_id
	Measures    []BallotMeasure   `json:"measures"`
	Signatures  []BDFSignature    `json:"signatures"`
	IsFullySigned bool            `json:"is_fully_signed"`
}

// BallotMeasure represents a proposition or referendum.
type BallotMeasure struct {
	MeasureID    string          `json:"measure_id"`
	Title        string          `json:"title"`
	Summary      string          `json:"summary"`
	Options      []MeasureOption `json:"options"`
	DisplayOrder int             `json:"display_order"`
}

// MeasureOption represents a choice on a ballot measure (Yes/No, etc).
type MeasureOption struct {
	DisplayName  string `json:"display_name"`
	OptionHash   string `json:"option_hash"`
	DisplayOrder int    `json:"display_order"`
}

// BDFSignature is one signer's signature on a Ballot Definition File.
type BDFSignature struct {
	SignerRole  string `json:"signer_role"`
	SignerName  string `json:"signer_name"`
	PublicKey   string `json:"public_key"`
	Signature   string `json:"signature"`
	Algorithm   string `json:"algorithm"`
}

// --- Vote Recording ---

// Selection represents a single choice the voter made in one race.
type Selection struct {
	RaceID        string `json:"race_id"`
	SelectionHash string `json:"selection_hash"` // CandidateHash or OptionHash
	RankPosition  int    `json:"rank_position,omitempty"` // For ranked-choice
	IsWriteIn     bool   `json:"is_write_in"`
	WriteInText   string `json:"write_in_text,omitempty"` // Cleartext, encrypted before storage
}

// VoteCast is the complete record of a single cast ballot.
type VoteCast struct {
	VoteRecordID        string     `json:"vote_record_id"`  // UUIDv4
	ElectionID          string     `json:"election_id"`
	PrecinctID          string     `json:"precinct_id"`
	VoterToken          []byte     `json:"voter_token"`
	VoterTokenHash      string     `json:"voter_token_hash"`
	VoterTokenSignature []byte     `json:"voter_token_signature"`
	BiometricHash       string     `json:"biometric_hash"`
	MachineID           string     `json:"machine_id"`
	CastTimestamp       time.Time  `json:"cast_timestamp"`
	SessionStart        time.Time  `json:"session_start"`
	SessionEnd          time.Time  `json:"session_end"`
	Nonce               string     `json:"nonce"` // 256-bit random hex
	Status              VoteStatus `json:"status"`
	Selections          []Selection `json:"selections"`
	VVPATSequenceNumber int        `json:"vvpat_sequence_number"`
	VVPATConfirmed      bool       `json:"vvpat_confirmed"`
	MerkleLeafHash      string     `json:"merkle_leaf_hash,omitempty"`
	MerkleLeafIndex     int        `json:"merkle_leaf_index,omitempty"`
	RowIntegrityHash    string     `json:"row_integrity_hash"`
}

// --- Receipts ---

// Receipt is what the voter takes home.
type Receipt struct {
	VoteRecordID    string `json:"vote_record_id"`
	ElectionID      string `json:"election_id"`
	PrecinctID      string `json:"precinct_id"`
	CastAt          string `json:"cast_at"`
	VerificationURL string `json:"verification_url"`
	QRPayload       string `json:"qr_payload"`
}

// --- Merkle Tree ---

// MerkleTree represents a precinct's complete Merkle tree.
type MerkleTree struct {
	TreeID          int64     `json:"tree_id"`
	ElectionID      string    `json:"election_id"`
	PrecinctID      string    `json:"precinct_id"`
	LeafCount       int       `json:"leaf_count"`
	ValidVoteCount  int       `json:"valid_vote_count"`
	TreeDepth       int       `json:"tree_depth"`
	MerkleRoot      string    `json:"merkle_root"`
	GenesisBDFHash  string    `json:"genesis_bdf_hash"`
	ComputedAt      time.Time `json:"computed_at"`
	ComputationMs   int       `json:"computation_time_ms"`
}

// MerkleNode is a single node in the tree (leaf or internal).
type MerkleNode struct {
	TreeID        int64  `json:"tree_id"`
	TreeLevel     int    `json:"tree_level"`  // 0 = leaf
	NodeIndex     int    `json:"node_index"`
	NodeHash      string `json:"node_hash"`
	LeftChildHash string `json:"left_child_hash,omitempty"`
	RightChildHash string `json:"right_child_hash,omitempty"`
	VoteRecordID  string `json:"vote_record_id,omitempty"` // Only at level 0
}

// MerkleProof is the path from a leaf to the root, proving inclusion.
type MerkleProof struct {
	VoteRecordID string   `json:"vote_record_id"`
	LeafHash     string   `json:"leaf_hash"`
	LeafIndex    int      `json:"leaf_index"`
	Siblings     []string `json:"siblings"` // Sibling hashes from leaf to root
	Root         string   `json:"root"`
}

// PublicMerkleProof is the subset of MerkleProof exposed to the verification portal.
// It proves a vote exists without revealing selections.
type PublicMerkleProof struct {
	VoteRecordID string   `json:"vote_record_id"`
	LeafIndex    int      `json:"leaf_index"`
	Siblings     []string `json:"siblings"`
	PrecinctRoot string   `json:"precinct_root"`
	StateRoot    string   `json:"state_root"`
	Verified     bool     `json:"verified"`
}

// --- Machine & Session Logging ---

// MachineSession is the log record for a single voter session on a machine.
type MachineSession struct {
	SessionID           string       `json:"session_id"`
	ElectionID          string       `json:"election_id"`
	MachineID           string       `json:"machine_id"`
	PrecinctID          string       `json:"precinct_id"`
	SessionStart        time.Time    `json:"session_start"`
	SessionEnd          *time.Time   `json:"session_end,omitempty"`
	DurationSec         int          `json:"duration_sec,omitempty"`
	AuthResult          string       `json:"auth_result"`
	BiometricConfidA    float64      `json:"biometric_confidence_a,omitempty"`
	BiometricConfidB    float64      `json:"biometric_confidence_b,omitempty"`
	ManualReviewRequired bool        `json:"manual_review_required"`
	VoteCast            bool         `json:"vote_cast"`
	VoteRecordID        string       `json:"vote_record_id,omitempty"`
	WasSpoiled          bool         `json:"was_spoiled"`
	SpoilCount          int          `json:"spoil_count"`
	PresenceAlerts      int          `json:"presence_alerts"`
	PresencePauseSec    int          `json:"presence_pause_sec"`
	IsFlagged           bool         `json:"is_flagged"`
	FlagReason          string       `json:"flag_reason,omitempty"`
}

// AnomalyAlert is a system-generated alert for suspicious activity.
type AnomalyAlert struct {
	ElectionID  string `json:"election_id"`
	AlertType   string `json:"alert_type"`
	Severity    string `json:"severity"`
	PrecinctID  string `json:"precinct_id,omitempty"`
	MachineID   string `json:"machine_id,omitempty"`
	Description string `json:"description"`
	Evidence    string `json:"evidence_json,omitempty"` // JSON string
}

// --- Canary ---

// CanaryDefinition is a pre-determined test vote for machine integrity checking.
type CanaryDefinition struct {
	CanaryID              int64       `json:"canary_id"`
	ElectionID            string      `json:"election_id"`
	MachineID             string      `json:"machine_id"`
	ExpectedSelections    []Selection `json:"expected_selections"`
	ExpectedSelectionsHash string    `json:"expected_selections_hash"`
	AssignedVoteRecordID  string      `json:"assigned_vote_record_id"`
}

// CanaryResult records whether a canary vote matched expectations.
type CanaryResult struct {
	Passed              bool   `json:"passed"`
	ActualSelectionsHash string `json:"actual_selections_hash"`
	MismatchDetails     string `json:"mismatch_details,omitempty"`
}

// --- Tombstone (Tier 2 Correction) ---

// TombstoneRequest is the data needed to void a vote after the voter has left.
type TombstoneRequest struct {
	VoteRecordID    string `json:"vote_record_id"`
	Reason          string `json:"reason"`
	Authorizer1ID   string `json:"authorizer_1_id"`
	Authorizer1Party string `json:"authorizer_1_party"`
	Authorizer2ID   string `json:"authorizer_2_id"`
	Authorizer2Party string `json:"authorizer_2_party"`
	CorrectedVoteID string `json:"corrected_vote_record_id,omitempty"`
}
