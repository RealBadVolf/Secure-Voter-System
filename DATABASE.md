# SecureVote — Database Architecture

## Overview

SecureVote uses **three physically separate MariaDB databases**, each running on its own server with independent credentials, network segments, and backup systems. This separation is the single most important security decision in the entire data layer.

---

## Why Three Databases?

The core security property of SecureVote is **unlinkability** — no single system breach should allow an attacker to connect a voter's identity to their ballot selections. If voter registration data and vote records live in the same database, a compromised DBA or a SQL injection could `JOIN voters ON votes` and destroy ballot secrecy instantly.

The three databases enforce this separation structurally:

| Database | Knows WHO | Knows HOW | Purpose |
|---|---|---|---|
| `securevote_registration` | Yes — full voter identity | No — never touches vote content | Voter enrollment, ID records, eligibility, token issuance tracking |
| `securevote_election` | No | No | Election definitions, ballot content, precincts, machines, workers. Shared reference data. |
| `securevote_votes` | No — only blinded tokens | Yes — full ballot selections | Vote recording, Merkle trees, tabulation, audit |

An attacker who fully compromises `securevote_registration` learns who voted but not how. An attacker who fully compromises `securevote_votes` learns every ballot selection but not whose they are. Only by compromising both databases **and** breaking the blind signature scheme can an attacker link identity to selections — and even then, the blinding makes that computationally infeasible.

---

## Database Topology

```
┌─────────────────────────────────────────────────────────┐
│                   ISOLATED NETWORK A                     │
│  ┌─────────────────────────────────────────────────┐    │
│  │       securevote_registration (MariaDB)          │    │
│  │  Voter identity, IDs, biometrics, PINs, tokens  │    │
│  └─────────────────────────────────────────────────┘    │
│  Access: Registration terminals, Auth module only        │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                   ISOLATED NETWORK B                     │
│  ┌─────────────────────────────────────────────────┐    │
│  │         securevote_election (MariaDB)             │    │
│  │  Elections, races, candidates, BDFs, machines     │    │
│  └─────────────────────────────────────────────────┘    │
│  Access: Admin consoles, voting machines (read-only),    │
│          tabulation systems (read-only)                  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                   ISOLATED NETWORK C                     │
│  ┌─────────────────────────────────────────────────┐    │
│  │          securevote_votes (MariaDB)               │    │
│  │  VoteCasts, selections, Merkle trees, audits      │    │
│  └─────────────────────────────────────────────────┘    │
│  Access: Voting machines (write), tabulation (read),     │
│          verification portal (read, limited)             │
└─────────────────────────────────────────────────────────┘
```

No application server or service account has credentials to more than one database. The authentication module connects to `securevote_registration`. The ballot rendering module connects to `securevote_election`. The vote recording module connects to `securevote_votes`. There is no service that bridges them.

---

## Encryption Strategy

### At Rest

All three databases use MariaDB's InnoDB tablespace encryption with AES-256-CBC. Encryption keys are managed by a hardware security module (HSM) — the database server itself never holds the master key in plaintext.

Specific high-sensitivity columns (biometric templates, ID images, election PINs) are additionally encrypted at the application level using AES-256-GCM before being written to the database. This means even a full database dump with the tablespace key is insufficient — you also need the application-level keys, which are stored in the HSM.

### In Transit

All database connections use TLS 1.3 with mutual authentication (client certificates). No plaintext database connections are permitted, even within the isolated network.

### Key Hierarchy

```
HSM Master Key (never leaves hardware)
├── Tablespace Encryption Key (securevote_registration)
├── Tablespace Encryption Key (securevote_election)
├── Tablespace Encryption Key (securevote_votes)
├── Application Encryption Key: biometric templates
├── Application Encryption Key: ID document images
├── Application Encryption Key: election PINs
├── Application Encryption Key: audit archive
└── Blind Signature Private Key (voter token issuance)
```

---

## Hashing Strategy

Hashing is used extensively for integrity verification and irreversible data protection. All hashes use SHA-256 unless otherwise noted.

| Data | Hash Purpose | Stored In |
|---|---|---|
| Voter biometric template | Irreversible identity binding in vote record | `securevote_votes.vote_casts.biometric_hash` |
| Voter password/PIN | Authentication (with salt + Argon2id) | `securevote_registration.voter_election_pins.pin_hash` |
| Candidate identity | Tamper-evident candidate binding | `securevote_election.candidates.candidate_hash` |
| VoteCast record | Merkle tree leaf | `securevote_votes.merkle_leaves.leaf_hash` |
| Ballot Definition File | Integrity of entire ballot spec | `securevote_election.ballot_definitions.bdf_hash` |
| ID document metadata | Integrity check without storing raw data | `securevote_registration.voter_id_documents.document_hash` |
| Audit log entries | Tamper evidence for log chain | All `*_audit_log` tables |

---

## Row-Level Integrity

Every table that stores critical data includes a `row_integrity_hash` column. This hash is computed over all other columns in the row (excluding the hash itself and auto-increment IDs) at write time. Any direct database manipulation that bypasses the application layer will cause a hash mismatch, detectable during audits.

```sql
-- Example: row integrity for a vote_cast record
row_integrity_hash = SHA2(CONCAT(
    vote_record_id, voter_token, cast_timestamp,
    biometric_hash, machine_id, status, nonce
), 256)
```

---

## Audit Logging

Every database has a dedicated audit log table that records all INSERT, UPDATE, and DELETE operations. Audit logs are append-only — the application database user does not have DELETE or UPDATE privileges on audit tables. A separate, restricted service account is used for audit log writes.

Each audit log entry includes a `previous_entry_hash` field, creating a hash chain. If any log entry is deleted or altered, the chain breaks, and the tampering is detectable.

---

## Access Control Summary

| Role | registration | election | votes |
|---|---|---|---|
| Registration Clerk | READ/WRITE (voters, IDs) | None | None |
| Election Administrator | None | READ/WRITE | None |
| Voting Machine (auth module) | READ + token issuance | READ (BDF) | None |
| Voting Machine (vote module) | None | None | WRITE (vote_casts) |
| Tabulation System | None | READ | READ |
| Verification Portal | None | None | READ (limited: vote existence + Merkle proofs only) |
| Auditor (bipartisan, 2-person) | READ (with HSM key ceremony) | READ | READ |
| Public | None | READ (published BDF + Merkle roots) | READ (published Merkle trees, no voter tokens) |

---

## Schema Files

The full SQL schema is defined in three files:

- [`01_securevote_registration.sql`](01_securevote_registration.sql) — Voter identity and enrollment
- [`02_securevote_election.sql`](02_securevote_election.sql) — Election administration and ballot definitions
- [`03_securevote_votes.sql`](03_securevote_votes.sql) — Vote recording, Merkle trees, and auditing

Each file is self-contained and creates its own database.

---

## Backup & Recovery

- All databases are backed up every 6 hours during non-election periods and every 30 minutes on election day.
- Backups are encrypted with a separate HSM key and stored in geographically distributed, air-gapped storage.
- Point-in-time recovery is enabled via MariaDB binary logs (also encrypted).
- Backup integrity is verified weekly by restoring to a test environment and running checksums.
- During election day, `securevote_votes` binary logs are additionally mirrored to write-once media (optical disc or WORM storage) for forensic preservation.

---

## Performance Considerations

- `securevote_votes.vote_casts` is the highest-write-volume table on election day. It is partitioned by `precinct_id` for write distribution and query performance.
- `securevote_votes.merkle_leaves` and `merkle_nodes` are written in batch after polls close, not during voting. The Merkle tree is computed from the `vote_casts` table post-election.
- `securevote_registration.voters` is read-heavy on election day (authentication lookups). A read replica local to each polling place (the "precinct voter roll cache") handles this load.
- All hash columns are indexed for fast lookups during verification and audit.
