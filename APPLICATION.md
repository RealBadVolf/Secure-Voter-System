# SecureVote — Application Layer Architecture

## Why Go

The application layer is written entirely in Go (1.22+). This decision is non-negotiable for several reasons that align directly with the system's security and deployment requirements:

**Single static binary.** Every service compiles to one binary with zero runtime dependencies. No JVM, no Python interpreter, no Node.js, no DLL hell. A voting machine's application is a single file that can be checksummed, signed, and verified. This dramatically shrinks the supply chain attack surface — there is no `node_modules` folder with 1,400 transitive dependencies to audit.

**Memory safety without a runtime.** Go is garbage-collected and bounds-checked. Buffer overflows, use-after-free, and out-of-bounds reads — the classic attack vectors against C/C++ voting systems — do not exist. Unlike Rust, Go's learning curve allows a larger pool of auditors and contributors to review the code.

**Strong standard library cryptography.** Go's `crypto` package provides audited, constant-time implementations of SHA-256, AES-GCM, RSA, ECDSA, and Ed25519. No third-party crypto libraries are needed for core operations.

**Built-in concurrency.** Goroutines handle concurrent voting sessions, parallel Merkle tree computation, and async audit logging without the complexity of thread management or the overhead of process-per-request models.

**Cross-compilation.** A single `GOOS=linux GOARCH=arm64 go build` produces a binary for the voting machine's ARM hardware. No toolchain installation on the target device.

**Reproducible builds.** `go build` with pinned module versions and `-trimpath` produces bit-for-bit identical binaries across build environments. Anyone can verify that the binary on a voting machine was compiled from the published source code.

---

## Service Architecture

SecureVote is decomposed into **seven services**, each compiled as a separate Go binary. No service has access to more than one database. Services communicate over mTLS (mutual TLS) on isolated networks, or not at all (air-gapped services communicate via encrypted physical media).

```
┌─────────────────────────────────────────────────────────────────────┐
│                     VOTING MACHINE (AIR-GAPPED)                     │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │  sv-auth     │  │  sv-ballot   │  │  sv-recorder             │  │
│  │  (auth svc)  │  │  (ballot svc)│  │  (vote recording svc)    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────────┘  │
│         │                 │                      │                  │
│  ┌──────┴─────────────────┴──────────────────────┴───────────────┐  │
│  │                    sv-machine (orchestrator)                   │  │
│  │          Manages UI, session state, hardware I/O              │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────┐
│         TABULATION CENTER (AIR-GAPPED)      │
│  ┌──────────────────────────────────────┐  │
│  │  sv-tabulator                         │  │
│  │  Merkle tree construction, counting   │  │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘

┌────────────────────────────────────────────┐
│         ELECTION ADMIN (RESTRICTED NET)     │
│  ┌──────────────────────────────────────┐  │
│  │  sv-admin                             │  │
│  │  Election setup, BDF management,      │  │
│  │  machine provisioning, worker mgmt    │  │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘

┌────────────────────────────────────────────┐
│         PUBLIC INTERNET                     │
│  ┌──────────────────────────────────────┐  │
│  │  sv-verify                            │  │
│  │  Voter verification portal            │  │
│  │  Read-only, rate-limited              │  │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘
```

### Service Summary

| Service | Binary | Database Access | Network | Runs On |
|---|---|---|---|---|
| `sv-machine` | `sv-machine` | None (delegates to sub-services) | Air-gapped | Voting machine |
| `sv-auth` | embedded in `sv-machine` | `securevote_registration` (read + token write) | Isolated polling network (optional) | Voting machine |
| `sv-ballot` | embedded in `sv-machine` | `securevote_election` (read-only) | None | Voting machine |
| `sv-recorder` | embedded in `sv-machine` | `securevote_votes` (write-only) | None | Voting machine |
| `sv-tabulator` | `sv-tabulator` | `securevote_votes` (read/write), `securevote_election` (read) | Air-gapped | Tabulation center |
| `sv-admin` | `sv-admin` | `securevote_election` (read/write), `securevote_registration` (read/write) | Restricted admin network | Admin workstation |
| `sv-verify` | `sv-verify` | `securevote_votes` (read, limited views only) | Public internet | Cloud/data center |

Note: On the voting machine, `sv-auth`, `sv-ballot`, and `sv-recorder` are compiled into the `sv-machine` binary as internal packages, not separate processes. This eliminates inter-process communication overhead and local network attack surface on the machine itself. They are logically separate (different packages, different database connection pools, different permission scopes) but physically one binary.

---

## Project Structure

```
securevote/
├── cmd/                          # Entry points (one per binary)
│   ├── sv-machine/
│   │   └── main.go               # Voting machine orchestrator
│   ├── sv-tabulator/
│   │   └── main.go               # Tabulation service
│   ├── sv-admin/
│   │   └── main.go               # Election administration
│   └── sv-verify/
│       └── main.go               # Public verification portal
│
├── internal/                     # Private packages (cannot be imported externally)
│   ├── auth/                     # Voter authentication logic
│   │   ├── biometric.go          # Dual-model facial matching
│   │   ├── biometric_test.go
│   │   ├── idscan.go             # ID scanning and OCR
│   │   ├── idscan_test.go
│   │   ├── liveness.go           # Liveness detection challenges
│   │   ├── presence.go           # Continuous presence monitoring
│   │   ├── token.go              # Blind signature token issuance
│   │   ├── token_test.go
│   │   ├── twofactor.go          # Optional 2FA
│   │   └── service.go            # Auth service coordinator
│   │
│   ├── ballot/                   # Ballot rendering and management
│   │   ├── bdf.go                # BDF parsing and signature verification
│   │   ├── bdf_test.go
│   │   ├── renderer.go           # Deterministic ballot rendering
│   │   └── service.go
│   │
│   ├── recorder/                 # Vote recording
│   │   ├── votecast.go           # VoteCast construction and signing
│   │   ├── votecast_test.go
│   │   ├── spoil.go              # Ballot spoiling logic
│   │   ├── tombstone.go          # Tier 2 correction logic
│   │   ├── receipt.go            # Receipt and QR code generation
│   │   ├── receipt_test.go
│   │   └── service.go
│   │
│   ├── merkle/                   # Merkle tree operations
│   │   ├── tree.go               # Tree construction
│   │   ├── tree_test.go
│   │   ├── proof.go              # Proof generation and verification
│   │   ├── proof_test.go
│   │   ├── hierarchy.go          # County/state aggregation
│   │   └── verify.go             # Independent verification
│   │
│   ├── tabulation/               # Vote counting
│   │   ├── counter.go            # Core tabulation logic
│   │   ├── counter_test.go
│   │   ├── canary.go             # Canary vote verification
│   │   ├── reconcile.go          # Token-count reconciliation
│   │   ├── aggregate.go          # County/state roll-ups
│   │   └── service.go
│   │
│   ├── audit/                    # Audit subsystems
│   │   ├── rla.go                # Risk-limiting audit engine
│   │   ├── rla_test.go
│   │   ├── anomaly.go            # Anomaly detection rules
│   │   ├── anomaly_test.go
│   │   ├── hashchain.go          # Audit log hash chain management
│   │   └── integrity.go          # Row integrity verification
│   │
│   ├── crypto/                   # Cryptographic primitives wrapper
│   │   ├── hash.go               # SHA-256, Argon2id wrappers
│   │   ├── hash_test.go
│   │   ├── blind.go              # RSA blind signature implementation
│   │   ├── blind_test.go
│   │   ├── encrypt.go            # AES-256-GCM application-level encryption
│   │   ├── encrypt_test.go
│   │   ├── sign.go               # Ed25519 / ECDSA signing
│   │   ├── sign_test.go
│   │   ├── hsm.go                # HSM interface (PKCS#11)
│   │   ├── provider.go           # CryptoProvider interface (algorithm agility)
│   │   └── provider_test.go
│   │
│   ├── machine/                  # Voting machine orchestration
│   │   ├── session.go            # Voter session state machine
│   │   ├── session_test.go
│   │   ├── hardware.go           # Camera, printer, scanner interface
│   │   ├── attestation.go        # TPM firmware attestation
│   │   ├── canary.go             # Pre-election canary test execution
│   │   └── orchestrator.go       # Main event loop
│   │
│   ├── admin/                    # Election administration
│   │   ├── election.go           # Election CRUD
│   │   ├── bdfmanager.go         # BDF creation and signing workflow
│   │   ├── machinemanager.go     # Machine provisioning and deployment
│   │   ├── workermanager.go      # Election worker management
│   │   ├── precinct.go           # Precinct configuration
│   │   ├── pinmailer.go          # Election PIN generation and mailing
│   │   └── service.go
│   │
│   ├── verify/                   # Public verification portal
│   │   ├── handler.go            # HTTP handlers
│   │   ├── handler_test.go
│   │   ├── ratelimit.go          # Rate limiting and anti-abuse
│   │   └── service.go
│   │
│   ├── db/                       # Database access layer
│   │   ├── registration.go       # securevote_registration connection and queries
│   │   ├── election.go           # securevote_election connection and queries
│   │   ├── votes.go              # securevote_votes connection and queries
│   │   ├── auditlog.go           # Audit log writer (shared pattern)
│   │   ├── integrity.go          # Row integrity hash computation
│   │   ├── migrate.go            # Schema migration runner
│   │   └── pool.go               # Connection pool configuration
│   │
│   └── config/                   # Configuration management
│       ├── config.go             # Typed config structs
│       ├── loader.go             # Load from file, env, flags
│       └── validate.go           # Config validation
│
├── pkg/                          # Public packages (shared types, could be imported by auditors)
│   ├── models/                   # Domain models
│   │   ├── voter.go
│   │   ├── election.go
│   │   ├── ballot.go
│   │   ├── votecast.go
│   │   ├── merkle.go
│   │   └── receipt.go
│   │
│   ├── protocol/                 # Wire protocol definitions
│   │   ├── auth.go               # Auth request/response types
│   │   ├── ballot.go
│   │   ├── vote.go
│   │   └── verify.go
│   │
│   └── testutil/                 # Test utilities
│       ├── fixtures.go           # Test data generators
│       ├── mockdb.go             # Database mocks
│       └── mockhardware.go       # Hardware mocks for testing without physical devices
│
├── migrations/                   # SQL migration files
│   ├── registration/
│   │   └── 001_initial.sql
│   ├── election/
│   │   └── 001_initial.sql
│   └── votes/
│       └── 001_initial.sql
│
├── configs/                      # Configuration templates
│   ├── machine.example.toml
│   ├── tabulator.example.toml
│   ├── admin.example.toml
│   └── verify.example.toml
│
├── scripts/                      # Build and deployment scripts
│   ├── build.sh                  # Reproducible build script
│   ├── verify-build.sh           # Verify binary matches source
│   ├── provision-machine.sh      # Initial machine setup
│   └── generate-canaries.sh      # Generate canary vote definitions
│
├── docs/                         # Documentation
│   ├── README.md
│   ├── ARCHITECTURE.md
│   ├── DATABASE.md
│   └── APPLICATION.md            # This file
│
├── go.mod
├── go.sum
└── Makefile
```

---

## Session State Machine

The voting machine orchestrator (`sv-machine`) manages each voter's session as a finite state machine. Every state transition is logged. Invalid transitions are rejected and trigger anomaly alerts.

```
                                    ┌──────────┐
                                    │  IDLE    │
                                    │ (waiting │
                                    │ for voter)│
                                    └────┬─────┘
                                         │ ID inserted/scanned
                                         ▼
                                ┌──────────────────┐
                                │  ID_SCANNING     │
                                │  OCR + DB lookup  │
                                └────┬────────┬────┘
                                     │        │
                              ID valid    ID invalid/not found
                                     │        │
                                     ▼        ▼
                            ┌─────────────┐  ┌──────────────┐
                            │ BIOMETRIC   │  │ AUTH_FAILED  │
                            │ _MATCHING   │  │ (offer help) │
                            └──┬──────┬───┘  └──────┬───────┘
                               │      │             │
                        Auto pass  Uncertain    ┌───┘
                               │      │         │
                               │      ▼         ▼
                               │  ┌──────────┐  ┌───────────┐
                               │  │ MANUAL   │  │ SESSION   │
                               │  │ _REVIEW  │  │ _END      │
                               │  └──┬───┬───┘  └───────────┘
                               │     │   │
                               │  Pass  Fail ──────► SESSION_END
                               │     │
                               ▼     ▼
                          ┌──────────────────┐
                          │ TWO_FACTOR       │ (if enabled)
                          │ (optional)       │
                          └────────┬─────────┘
                                   │
                                   ▼
                          ┌──────────────────┐
                          │ TOKEN_ISSUANCE   │
                          │ Blind-sign token │
                          └────────┬─────────┘
                                   │
                                   ▼
                          ┌──────────────────┐
                          │ BALLOT_ACTIVE    │◄──── Voter making selections
                          │                  │      (continuous presence
                          └──┬──────┬────┬───┘       monitoring active)
                             │      │    │
                      Confirm │  Spoil  Presence lost
                             │      │    │
                             │      │    ▼
                             │      │  ┌──────────────┐
                             │      │  │ PAUSED       │
                             │      │  │ (re-verify)  │
                             │      │  └──┬───────┬───┘
                             │      │     │       │
                             │      │  Verified  Failed
                             │      │     │       │
                             │      │     │       ▼
                             │      │     │    SESSION_END
                             │      ▼     │
                             │  ┌─────────┴──┐
                             │  │ SPOILED    │
                             │  │ (mark void │
                             │  │  re-start) │
                             │  └─────┬──────┘
                             │        │
                             │        ▼
                             │   BALLOT_ACTIVE (new ballot)
                             │
                             ▼
                      ┌──────────────────┐
                      │ VVPAT_REVIEW     │
                      │ Voter checks     │
                      │ paper printout   │
                      └──┬───────────┬───┘
                         │           │
                      Confirms    Rejects ──► SPOILED
                         │
                         ▼
                      ┌──────────────────┐
                      │ RECORDING        │
                      │ Write VoteCast   │
                      │ + Merkle leaf    │
                      └────────┬─────────┘
                               │
                               ▼
                      ┌──────────────────┐
                      │ RECEIPT          │
                      │ Print/display    │
                      │ QR code          │
                      └────────┬─────────┘
                               │
                               ▼
                      ┌──────────────────┐
                      │ SESSION_END      │
                      │ Cleanup, log,    │
                      │ return to IDLE   │
                      └──────────────────┘
```

### State Transition Rules

Every transition is governed by a strict transition table. The orchestrator rejects any transition not in this table.

| From State | To State | Trigger | Required Conditions |
|---|---|---|---|
| `IDLE` | `ID_SCANNING` | ID inserted | Machine status is `ACTIVE_VOTING` |
| `ID_SCANNING` | `BIOMETRIC_MATCHING` | ID valid | ID found in voter roll, not already used, not expired |
| `ID_SCANNING` | `AUTH_FAILED` | ID invalid | ID not found, already used, reported stolen, or expired |
| `BIOMETRIC_MATCHING` | `TWO_FACTOR` | Auto pass (2FA enabled) | Both models >= threshold |
| `BIOMETRIC_MATCHING` | `TOKEN_ISSUANCE` | Auto pass (no 2FA) | Both models >= threshold |
| `BIOMETRIC_MATCHING` | `MANUAL_REVIEW` | Uncertain | Either model below threshold but above reject |
| `BIOMETRIC_MATCHING` | `AUTH_FAILED` | Both reject | Both models below minimum |
| `MANUAL_REVIEW` | `TOKEN_ISSUANCE` | Worker approves | Worker ID recorded, requires worker auth |
| `MANUAL_REVIEW` | `AUTH_FAILED` | Worker rejects | Worker ID recorded |
| `TWO_FACTOR` | `TOKEN_ISSUANCE` | Code verified | Correct OTP entered |
| `TWO_FACTOR` | `TOKEN_ISSUANCE` | Fallback | 2FA failed but PIN verified or worker override |
| `TOKEN_ISSUANCE` | `BALLOT_ACTIVE` | Token issued | Blind signature completed, token stored in session |
| `BALLOT_ACTIVE` | `VVPAT_REVIEW` | Voter confirms | All required races have selections |
| `BALLOT_ACTIVE` | `SPOILED` | Voter requests | Spoil count < max (default 3) |
| `BALLOT_ACTIVE` | `PAUSED` | Presence lost | Camera detects face gone > 10 sec |
| `PAUSED` | `BALLOT_ACTIVE` | Re-verified | Same biometric template re-matched |
| `PAUSED` | `SESSION_END` | Re-verify fails | Different face or timeout |
| `SPOILED` | `BALLOT_ACTIVE` | New ballot | Previous VoteCast marked SPOILED, new session started |
| `VVPAT_REVIEW` | `RECORDING` | Voter confirms paper | VVPAT paper matches digital |
| `VVPAT_REVIEW` | `SPOILED` | Voter rejects paper | Paper did not match intent |
| `RECORDING` | `RECEIPT` | Vote recorded | VoteCast written, Merkle leaf computed |
| `RECEIPT` | `SESSION_END` | Receipt printed/shown | Receipt generated |
| `SESSION_END` | `IDLE` | Cleanup complete | Session log written, volatile data wiped |
| `AUTH_FAILED` | `SESSION_END` | Always | After displaying help message |

### Timeouts

| State | Max Duration | On Timeout |
|---|---|---|
| `ID_SCANNING` | 30 seconds | → `SESSION_END` |
| `BIOMETRIC_MATCHING` | 15 seconds | → `MANUAL_REVIEW` |
| `MANUAL_REVIEW` | 5 minutes | → `SESSION_END` |
| `TWO_FACTOR` | 2 minutes | → fallback to PIN/manual |
| `BALLOT_ACTIVE` | 15 minutes | Warning at 12 min, → `SESSION_END` at 15 |
| `PAUSED` | 60 seconds | → `SESSION_END` |
| `VVPAT_REVIEW` | 2 minutes | Warning at 90 sec, → `SESSION_END` at 2 min |

---

## Key Interfaces

The application is built around Go interfaces that enforce the separation of concerns and enable testing. Here are the critical ones:

### CryptoProvider (Algorithm Agility)

```go
// CryptoProvider abstracts all cryptographic operations.
// Swap implementations for post-quantum migration.
type CryptoProvider interface {
    // Hashing
    Hash(data []byte) [32]byte
    HashMulti(parts ...[]byte) [32]byte

    // Application-level encryption (AES-256-GCM)
    Encrypt(plaintext []byte, keyID string) (ciphertext []byte, err error)
    Decrypt(ciphertext []byte, keyID string) (plaintext []byte, err error)

    // Digital signatures
    Sign(data []byte, keyID string) (signature []byte, err error)
    Verify(data []byte, signature []byte, publicKey []byte) (bool, error)

    // Blind signatures (for VoterTokens)
    BlindSign(blindedMessage []byte, keyID string) (blindSignature []byte, err error)
    VerifyBlindSignature(message []byte, signature []byte, publicKey []byte) (bool, error)

    // Password/PIN hashing (Argon2id)
    HashPassword(password string) (hash string, err error)
    VerifyPassword(password string, hash string) (bool, error)

    // Key management
    GenerateNonce() ([32]byte, error)
    GenerateUUID() (string, error)
}
```

### VoterSession (State Machine)

```go
// VoterSession represents a single voter's interaction with the machine.
type VoterSession interface {
    // State queries
    CurrentState() SessionState
    SessionID() string
    ElapsedTime() time.Duration

    // State transitions (each returns error if transition is invalid)
    BeginIDScan(idImages IDScanImages) error
    RecordBiometricResult(result BiometricResult) error
    RecordManualReview(workerID string, approved bool) error
    RecordTwoFactor(result TwoFactorResult) error
    IssueToken() (*BlindToken, error)
    ActivateBallot(bdf *BallotDefinition) error
    RecordSelections(selections []Selection) error
    ConfirmVVPAT() error
    RejectVVPAT() error
    SpoilBallot(reason string) error
    PauseSession(reason string) error
    ResumeSession(biometricResult BiometricResult) error
    RecordVote() (*VoteCast, error)
    GenerateReceipt() (*Receipt, error)
    EndSession() (*SessionLog, error)

    // Monitoring
    OnStateChange(callback func(from, to SessionState))
    OnTimeout(callback func(state SessionState))
    OnPresenceAlert(callback func(alert PresenceAlert))
}
```

### Hardware Abstraction

```go
// HardwareInterface abstracts all physical device interactions.
// Implementations exist for real hardware and for test mocks.
type HardwareInterface interface {
    // ID Scanner
    ScanID() (*IDScanImages, error)
    IsIDPresent() bool

    // Camera
    CaptureFrame() (*image.Image, error)
    StartContinuousCapture(fps int) (<-chan *image.Image, error)
    StopContinuousCapture() error

    // Biometric processor
    ExtractTemplate(img *image.Image) (*BiometricTemplate, error)
    MatchTemplates(a, b *BiometricTemplate) (*MatchResult, error)
    DetectLiveness(frames []*image.Image, challenge LivenessChallenge) (*LivenessResult, error)

    // Printer
    PrintVVPAT(record *VVPATRecord) error
    PrintReceipt(receipt *Receipt) error
    PrinterStatus() PrinterStatus

    // Display
    RenderBallot(bdf *BallotDefinition) error
    ShowScreen(screen ScreenType, data interface{}) error

    // TPM
    Attest() (*AttestationResult, error)
    GetMachineID() (string, error)

    // Status
    SelfTest() (*DiagnosticResult, error)
}
```

### Database Access (Per-Database Isolation)

```go
// RegistrationDB provides access to securevote_registration.
// Only the auth module receives an instance of this interface.
type RegistrationDB interface {
    // Voter lookup
    FindVoterByRegistration(stateCode, regNumber string) (*Voter, error)
    FindVoterByDocumentHash(docHash string) (*Voter, error)
    CheckVoterEligibility(voterID int64, electionID string) (*EligibilityResult, error)

    // Token issuance
    HasTokenBeenIssued(voterID int64, electionID string) (bool, error)
    RecordTokenIssuance(issuance *TokenIssuance) error

    // Biometric
    GetActiveBiometric(voterID int64) (*BiometricRecord, error)

    // PIN
    GetElectionPIN(voterID int64, electionID string) (*PINRecord, error)
    RecordPINAttempt(pinID int64, success bool) error

    // ID documents
    GetPrimaryDocument(voterID int64) (*IDDocument, error)
    IsDocumentReportedStolen(docHash string) (bool, error)
}

// ElectionDB provides access to securevote_election.
// The ballot module and tabulator receive this interface (read-only).
type ElectionDB interface {
    // Election
    GetElection(electionID string) (*Election, error)
    GetActiveElection(jurisdictionID string) (*Election, error)

    // Ballot
    GetBDF(electionID, precinctID string) (*BallotDefinition, error)
    VerifyBDFSignatures(bdfID int64) (*SignatureVerification, error)

    // Races and candidates
    GetRaces(electionID string) ([]*Race, error)
    GetCandidates(raceID string) ([]*Candidate, error)
    VerifyCandidateHash(candidateID int64) (bool, error)

    // Machines
    GetMachine(machineID string) (*VotingMachine, error)
    UpdateMachineStatus(machineID string, status MachineStatus) error
}

// VotesDB provides access to securevote_votes.
// The recorder module gets write access; tabulator and verify get read access.
type VotesDB interface {
    // Vote recording
    InsertVoteCast(vc *VoteCast) error
    InsertVoteSelections(selections []*VoteSelection) error
    MarkSpoiled(voteRecordID string, reason string, replacedBy string) error
    MarkTombstoned(voteRecordID string, tombstone *TombstoneRequest) error

    // Merkle tree
    InsertMerkleTree(tree *MerkleTree) error
    InsertMerkleNodes(nodes []*MerkleNode) error
    GetMerkleProof(voteRecordID string) (*MerkleProof, error)

    // Tabulation
    GetValidVoteCasts(electionID, precinctID string) ([]*VoteCast, error)
    InsertTabulationResults(results []*TabulationResult) error
    GetReconciliation(electionID, precinctID string) (*Reconciliation, error)

    // Verification (limited — used by sv-verify)
    VoteExists(voteRecordID string) (bool, error)
    GetPublicMerkleProof(voteRecordID string) (*PublicMerkleProof, error)

    // Canary
    GetCanaryDefinitions(electionID, machineID string) ([]*CanaryDefinition, error)
    RecordCanaryResult(canaryID int64, result *CanaryResult) error

    // Anomaly
    InsertAnomalyAlert(alert *AnomalyAlert) error
    InsertMachineSession(session *MachineSession) error
}
```

---

## API Design

### Internal APIs (Machine Subservices)

Since `sv-auth`, `sv-ballot`, and `sv-recorder` are compiled into `sv-machine` as packages, they communicate via direct Go function calls — no network API, no serialization overhead, no attack surface. The interfaces defined above are the API.

### sv-admin API (REST over mTLS)

The admin service exposes a REST API on the restricted admin network. All requests require mTLS client certificates issued to authorized admin workstations.

```
POST   /api/v1/elections                    # Create election
GET    /api/v1/elections/:id                # Get election details
PUT    /api/v1/elections/:id/status         # Update election status
POST   /api/v1/elections/:id/bdf           # Upload/create BDF
POST   /api/v1/elections/:id/bdf/sign      # Submit a BDF signature
GET    /api/v1/elections/:id/bdf/status    # Check BDF signing status

POST   /api/v1/machines/provision           # Register a new machine
PUT    /api/v1/machines/:id/assign         # Assign machine to precinct
PUT    /api/v1/machines/:id/status         # Update machine status
GET    /api/v1/machines/:id/attestation    # Get latest attestation result

POST   /api/v1/workers                     # Register election worker
GET    /api/v1/workers/:id                 # Get worker details
PUT    /api/v1/workers/:id/certify        # Mark worker as certified

POST   /api/v1/pins/generate               # Generate election PINs for voters
POST   /api/v1/pins/mail                   # Trigger PIN mailing batch

GET    /api/v1/precincts/:id/readiness     # Pre-election readiness check
```

### sv-verify API (Public REST, Rate-Limited)

```
POST   /api/v1/verify                      # Verify a vote exists
       Request:  { "vote_record_id": "...", "election_id": "...", "pin": "..." }
       Response: { "status": "VERIFIED", "merkle_proof": {...}, ... }

GET    /api/v1/election/:id/merkle-root    # Get published Merkle root
GET    /api/v1/election/:id/bdf-hash       # Get published BDF hash
GET    /api/v1/health                      # Service health check
```

Rate limiting: 10 requests per IP per hour. PIN lockout after 3 failures per VoteRecordID.

### sv-tabulator API

The tabulator has **no network API**. It runs on an air-gapped machine. Input arrives via encrypted USB drives. Output (Merkle roots, tabulation results) is exported to encrypted USB drives for transport.

The tabulator operates as a CLI:

```bash
# Ingest vote data from a precinct's encrypted USB
sv-tabulator ingest --precinct=1042 --source=/mnt/usb/precinct-1042.enc

# Verify canary votes
sv-tabulator verify-canaries --election=general-2026-11-03

# Build Merkle tree for a precinct
sv-tabulator merkle-build --precinct=1042

# Run tabulation
sv-tabulator tabulate --election=general-2026-11-03

# Run reconciliation (token count vs vote count)
sv-tabulator reconcile --election=general-2026-11-03

# Export results for transport
sv-tabulator export --election=general-2026-11-03 --dest=/mnt/usb/results.enc
```

---

## Security Hardening

### Build Security

- **Reproducible builds**: The `Makefile` uses `go build -trimpath -ldflags="-s -w" -buildvcs=false` with exact module versions from `go.sum`. Any person can reproduce the exact binary.
- **SBOM generation**: Every build produces a Software Bill of Materials listing all dependencies and their hashes.
- **Dependency policy**: Direct dependencies are minimized. No dependency may include CGo (pure Go only). All dependencies are vendored (`go mod vendor`) and the vendor directory is committed and auditable.
- **No CGo**: The entire application is pure Go. CGo introduces C compiler dependencies, breaks reproducible builds, and opens C-level vulnerabilities. The biometric models run as separate, sandboxed processes called via IPC — they are not linked into the Go binary.

### Runtime Security

- **Minimal OS**: Voting machines run a hardened, minimal Linux (custom image, no package manager, no shell access, no SSH, read-only root filesystem).
- **Seccomp profiles**: Each binary runs with a strict seccomp profile allowing only the syscalls it needs.
- **No dynamic loading**: No `plugin` package, no `dlopen`, no dynamic library loading.
- **Memory wiping**: Sensitive data in memory (biometric templates, unblinded tokens, PINs) is explicitly zeroed after use using a `memwipe()` utility that prevents compiler optimization from eliding the wipe.
- **No logging of secrets**: The logging framework has a `Redact` wrapper that prevents sensitive fields from appearing in logs. All log output is structured (JSON) for machine parsing.

### Dependency Inventory

Only the following external Go modules are permitted:

| Module | Purpose | Justification |
|---|---|---|
| `github.com/go-sql-driver/mysql` | MariaDB driver | Required for database access; widely audited |
| `github.com/skip2/go-qrcode` | QR code generation | Receipt QR codes; small, no dependencies |
| `golang.org/x/crypto` | Argon2id, additional crypto | Official Go extended crypto; maintained by Go team |
| `github.com/google/uuid` | UUID generation | Industry standard; tiny footprint |
| `github.com/pelletier/go-toml/v2` | Config file parsing | TOML config files; minimal |
| `github.com/miekg/pkcs11` | HSM interface | PKCS#11 binding for HSM key management |

No web frameworks. The HTTP servers in `sv-admin` and `sv-verify` use Go's `net/http` standard library with a minimal router. No ORMs — all SQL is hand-written and parameterized.

---

## Testing Strategy

### Unit Tests

Every package has `_test.go` files. Test coverage target: 90% line coverage for `internal/` packages, 100% for `internal/crypto/`.

### Integration Tests

A Docker Compose environment spins up three MariaDB instances (one per database) and runs end-to-end flows:

- Full voter session: ID scan → auth → ballot → vote → receipt
- Spoil and re-vote flow
- Tombstone (Tier 2 correction) flow
- Canary vote injection and verification
- Merkle tree construction and proof verification
- RLA sample selection and comparison
- Verification portal lookup

### Fuzz Testing

Go's built-in fuzzing (`go test -fuzz`) targets:

- `internal/crypto/blind.go` — blind signature edge cases
- `internal/merkle/tree.go` — tree construction with malformed inputs
- `internal/ballot/bdf.go` — BDF parsing with malformed JSON
- `internal/verify/handler.go` — verification API with adversarial inputs

### Hardware-in-the-Loop Testing

A test rig with actual voting machine hardware runs the full binary in a simulated election. This is the final gate before firmware release.

### Red Team / Penetration Testing

Before each election cycle, independent security firms conduct:

- Source code audit of all changes since last election
- Binary verification (compiled binary matches published source)
- Network penetration testing of `sv-admin` and `sv-verify`
- Physical penetration testing of voting machine enclosures
- Social engineering testing of election worker procedures

---

## Deployment & Updates

### Firmware Image

The voting machine firmware image is:

1. Built from the published source using the reproducible build process.
2. Signed with the election authority's firmware signing key (stored in HSM, requires 3-of-5 key holders).
3. Published on the transparency log with its hash.
4. Distributed to machines via encrypted USB during the pre-election provisioning window.
5. Verified by the machine's TPM at boot (the TPM checks the firmware signature against the expected public key burned into the chip at manufacture).

### Update Policy

No firmware updates are permitted within 30 days of an election. All updates undergo the full security review process. Emergency patches require:

- Identification of a critical vulnerability
- Patch development and review
- 3-of-5 signing authority approval
- Mandatory re-execution of LAT (Logic and Accuracy Testing) on all patched machines
- Public disclosure of the vulnerability and patch

---

## Error Handling Philosophy

Go's explicit error handling is a feature, not a burden, in this context. Every error is handled. No errors are silently swallowed. The codebase follows these rules:

1. **No panics in production code.** Panics are used only in tests and init-time assertions (e.g., "crypto self-test failed at startup — panic is appropriate because the machine cannot function").
2. **Errors are wrapped with context.** Every error return includes the operation that failed: `fmt.Errorf("recording vote for session %s: %w", sessionID, err)`.
3. **Errors are categorized.** The `internal/errors` package defines categories: `ErrAuth`, `ErrIntegrity`, `ErrHardware`, `ErrDatabase`, `ErrTimeout`. These drive different recovery behaviors.
4. **Critical errors halt the machine.** If a database write fails, a Merkle hash doesn't compute, or a signature verification fails, the machine stops accepting votes and alerts a poll worker. Silence is never the response to failure.
5. **All errors are logged with structured context.** Every log entry includes session ID, machine ID, precinct ID, timestamp, error category, and stack trace.
