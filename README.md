# NexGenVote: A Next-Generation Election System Architecture

## Executive Summary

NexGenVote is a proposed end-to-end verifiable (E2E-V) election system designed to address known vulnerabilities in current American voting infrastructure. It combines biometric voter authentication, cryptographic ballot integrity, Merkle-tree-based vote immutability, and rigorous audit mechanisms — while preserving ballot secrecy and maintaining a paper backup trail.

This document serves as the foundational architecture specification. It is intended for public review, critique, and iteration.

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [System Overview](#2-system-overview)
3. [Voter Authentication](#3-voter-authentication)
4. [Ballot Design & Integrity](#4-ballot-design--integrity)
5. [Vote Recording & Immutability](#5-vote-recording--immutability)
6. [Voter Receipt & Verification](#6-voter-receipt--verification)
7. [Error Handling & Vote Correction](#7-error-handling--vote-correction)
8. [Tabulation & Reporting](#8-tabulation--reporting)
9. [Audit Framework](#9-audit-framework)
10. [Threat Model & Mitigations](#10-threat-model--mitigations)
11. [Infrastructure & Network Architecture](#11-infrastructure--network-architecture)
12. [Open Questions & Future Work](#12-open-questions--future-work)
13. [Glossary](#13-glossary)

---

## 1. Design Principles

Every design decision in NexGenVote is governed by five non-negotiable principles, listed in priority order:

1. **Ballot Secrecy**: No voter can be coerced into proving how they voted. No external party can link a voter's identity to their selections outside of a formal, multi-party audit.
2. **Immutability**: Once a vote is recorded, it cannot be altered, deleted, or reordered without detection.
3. **Verifiability**: Every voter can independently confirm that their vote was included in the final tally — without revealing their selections.
4. **Transparency**: All software, algorithms, and procedures are open-source and publicly auditable. Security is achieved through design, not obscurity.
5. **Resilience**: The system degrades gracefully. No single component failure — network, hardware, software, or human — can prevent voting or corrupt results. Paper backup is always available.

---

## 2. System Overview

NexGenVote operates across four layers:

**Layer 1 — Voter Authentication**: Confirms the voter is who they claim to be and is eligible to vote.

**Layer 2 — Ballot Presentation & Capture**: Displays the ballot, records the voter's selections, and generates cryptographic commitments.

**Layer 3 — Vote Recording & Immutability**: Writes the vote to a precinct-level Merkle tree, generates the voter receipt, and queues the record for tabulation.

**Layer 4 — Tabulation, Audit & Reporting**: Aggregates precinct results into county/state totals, runs automatic risk-limiting audits, and publishes results with full cryptographic proofs.

Each layer is isolated. A compromise at one layer should not cascade to others.

---

## 3. Voter Authentication

### 3.1 Required Credentials

Every voter presents two factors:

- **Government-issued photo ID** (scanned on both sides by the voting machine)
- **Biometric confirmation** (facial geometry captured by an on-device camera, compared against the ID photo)

An optional third factor is available:

- **Election PIN** — a unique, random alphanumeric code mailed to the voter's registered address 2–4 weeks before election day. This replaces any use of Social Security numbers, which are widely compromised and unsuitable as authentication secrets.

### 3.2 ID Scanning & Validation

When the voter inserts or scans their ID:

1. The machine captures high-resolution images of both sides.
2. OCR extracts the ID number, name, date of birth, and address.
3. The extracted ID number is checked against the **precinct voter roll cache** (a local, encrypted copy of the registered voter database for that precinct, loaded before polls open).
4. If network connectivity is available, a real-time query confirms the ID has not been reported lost/stolen and has not already been used to vote in this election.
5. If the network is unavailable, the local cache is authoritative. Any ID flagged during post-election reconciliation triggers a provisional ballot process.

The ID is marked as "used" in both the local cache and the central database. This prevents the same ID from being presented at another precinct.

### 3.3 Biometric Matching

The on-device camera captures the voter's face and computes a facial geometry template (a mathematical representation — not a stored photograph).

- The template is compared against the photo on the scanned ID using a dual-algorithm approach: two independent facial recognition models must both return a confidence score above the threshold.
- **If both models agree with high confidence**: the voter proceeds.
- **If either model is uncertain**: the machine flags the session and alerts a poll worker for manual identity verification. The voter is not turned away — they are assisted.
- **Continuous presence detection**: the camera remains active throughout the voting session to ensure the authenticated voter is the one casting the ballot. If the detected face changes or disappears for more than 10 seconds, the session is paused and a poll worker is alerted.

### 3.4 Biometric Data Handling

Raw facial images and biometric templates are **never stored permanently on the voting machine**. After the authentication check completes:

- The raw image is discarded.
- A one-way hash of the biometric template is stored in the vote record for audit purposes. This hash cannot be reversed to reconstruct the voter's face.
- The original biometric template is encrypted and transferred to a separate, air-gapped audit archive accessible only under multi-party authorization during formal audits.

### 3.5 Universal ID Access

To ensure the ID requirement does not disenfranchise eligible voters, NexGenVote assumes a companion policy:

- Free government-issued voter ID, available at any post office, DMV, library, or mobile registration unit.
- Automatic voter registration triggered by any government interaction (tax filing, benefits enrollment, license renewal, selective service registration).
- A 90-day pre-election enrollment window where any citizen can obtain a free ID with minimal documentation (birth certificate or equivalent).

The system requires ID. The system also guarantees access to ID. These are inseparable.

### 3.6 Optional Two-Factor Authentication (Voter-Initiated)

Voters who opt in during registration can enable 2FA:

- When their ID is scanned at the polling place, the system sends a one-time code to their registered phone number or email.
- The voter enters this code on the machine to proceed.
- If the voter does not have their phone or the message fails to deliver, they fall back to the Election PIN or manual poll-worker verification.

This is strictly optional and does not gate the ability to vote.

---

## 4. Ballot Design & Integrity

### 4.1 Candidate Identification: Cryptographic Hashes

Every candidate and ballot measure is assigned a unique **Candidate Hash** before election day. This hash is derived from:

```
CandidateHash = SHA-256(FullLegalName + Party + RaceID + ElectionID + Salt)
```

The ballot displays human-readable names and descriptions. What gets recorded in the vote record is the CandidateHash. This defends against the **name-swap attack** — an adversary who gains database access cannot simply rename candidates, because the hashes are derived from the original identities and independently verifiable.

### 4.2 Ballot Definition File (BDF)

The BDF is the master mapping between human-readable ballot content and CandidateHashes. It is:

1. **Created** by the election authority at least 30 days before election day.
2. **Signed** by a multi-party committee (representatives of each major party, an independent auditor, and the election authority) using a threshold signature scheme (e.g., 3-of-5 signers required).
3. **Published** on a public, append-only ledger (a transparency log similar to Certificate Transparency) so that any citizen, journalist, or watchdog organization can download and verify it.
4. **Embedded** as the genesis record of each precinct's Merkle tree. Any post-publication alteration to the BDF would invalidate the entire tree.

### 4.3 Ballot Rendering

The voting machine renders the ballot from the signed BDF at boot time. The rendering code is open-source and deterministic — given the same BDF, every machine produces the same ballot layout. Random candidate ordering (where legally required) is seeded from the precinct ID + election ID, so it is consistent within a precinct but verifiable.

---

## 5. Vote Recording & Immutability

### 5.1 What Gets Recorded Per Vote

Each vote record (called a **VoteCast**) contains:

| Field | Description |
|---|---|
| `VoteRecordID` | A unique, random UUID generated at the moment of casting |
| `VoterToken` | A blinded, anonymized token derived from the voter's ID — links the vote to a registered voter without revealing identity (see §5.2) |
| `Timestamp` | Precise time of casting (UTC) |
| `Selections` | An array of CandidateHashes representing the voter's choices |
| `Nonce` | A cryptographically random value unique to this vote |
| `BiometricHash` | One-way hash of the voter's biometric template at time of authentication |
| `MachineID` | The unique identifier of the voting machine |
| `Status` | `VALID`, `SPOILED`, or `TOMBSTONED` |
| `MerkleProof` | The path from this vote's leaf to the precinct Merkle root (populated after tree construction) |

### 5.2 Voter Anonymization (Blinded Tokens)

To preserve ballot secrecy while still preventing double-voting, NexGenVote uses a **blind signature scheme**:

1. At authentication time, the machine generates a random VoterToken.
2. The token is "blinded" (mathematically obscured) and sent to the authentication module, which signs it after confirming the voter is registered and has not yet voted.
3. The signed, blinded token is "unblinded" by the machine, yielding a valid signed token that proves "a registered voter cast this ballot" without revealing which voter.
4. The VoterToken is included in the VoteCast. It is cryptographically signed by the election authority, proving legitimacy, but cannot be traced back to the voter's identity.

This is the same mathematical technique used in privacy-preserving digital cash systems.

### 5.3 Precinct-Level Merkle Trees

Rather than a single, sequential blockchain (which would be too slow for election-night tabulation), each precinct maintains a **Merkle tree**:

- Each VoteCast is a leaf node, hashed with SHA-256.
- Leaves are paired and hashed up the tree until a single **Merkle Root** is produced.
- The Merkle Root represents a tamper-evident fingerprint of every vote in that precinct. Changing any single vote would alter the root.

At close of polls, each precinct publishes its Merkle Root. County-level systems then build a **higher-order Merkle tree** from all precinct roots. The state publishes the final state-level root.

This hierarchical structure allows parallel processing (every precinct computes independently) while maintaining a single, verifiable root hash for the entire election.

### 5.4 Paper Backup Trail

Simultaneously with the digital recording, the voting machine prints a **Voter-Verified Paper Audit Trail (VVPAT)** — a physical paper record of the voter's selections. The voter reviews the paper printout through a window, confirms it matches their intent, and approves it. The paper drops into a sealed, tamper-evident box.

The paper trail is the ultimate fallback. If any digital component is compromised, the paper ballots are the authoritative record.

---

## 6. Voter Receipt & Verification

### 6.1 The Secrecy Constraint

A voter receipt that shows actual vote selections would enable vote buying and coercion. Therefore, the receipt proves inclusion without revealing content.

### 6.2 What the Voter Receives

At the end of the voting session, the machine prints (or displays for phone capture) a receipt containing:

- **VoteRecordID**: the unique ID of their vote
- **Precinct Merkle Root** (once computed — this may be added post-election to a publicly accessible lookup)
- **QR Code**: encoding a URL to the public verification portal
- **Election PIN reminder**: a note to retain their Election PIN for verification

The receipt does **not** contain the voter's selections, their identity, or any biometric data.

### 6.3 Post-Election Verification Portal

After results are certified, a public web portal allows any voter to:

1. Scan their QR code or enter their VoteRecordID.
2. Authenticate with their Election PIN (the unique code mailed to them or generated at the poll).
3. View confirmation that a vote with their VoteRecordID exists in the certified Merkle tree.
4. View the Merkle proof linking their VoteRecordID to the published precinct root.

They can confirm: "My vote was counted." They cannot confirm: "My vote was for Candidate X." This is by design.

### 6.4 Full Selection Verification (Controlled Environment Only)

If a voter wishes to verify their specific selections — for example, during a formal audit, legal challenge, or recount — they may do so at a designated **Audit Verification Center**:

- Staffed by bipartisan observers.
- The voter presents their ID and Election PIN.
- An auditor decrypts the linkage between VoteRecordID and selections using a multi-party key ceremony (no single person holds the full decryption key).
- The voter confirms or disputes their selections on the record.
- This process is logged but the results are not provided in a form the voter can take with them (preventing coercion use).

---

## 7. Error Handling & Vote Correction

### 7.1 Tier 1 — Immediate Correction (Same Session)

If the voter makes an error before finalizing:

- The voter requests a redo on the machine.
- The original VoteCast record is marked `Status: SPOILED`.
- A new VoteCast is created with a new VoteRecordID and nonce.
- The spoiled record remains in the Merkle tree (nothing is ever deleted) but is excluded from tabulation.
- The VVPAT paper for the spoiled ballot is marked as void.

No external authorization is required. The voter simply corrects their ballot, similar to spoiling a paper ballot today.

### 7.2 Tier 2 — Post-Session Correction (Voter Has Left)

If an error is discovered after the voter has left the machine (e.g., a machine malfunction recorded incorrect selections):

- Two independent verification officials from **different political parties** must both authorize the correction.
- The original VoteCast is marked `Status: TOMBSTONED` with a signed reason code and the identities of both authorizing officials.
- A corrected VoteCast is appended with a reference to the tombstoned record.
- Both records remain in the Merkle tree permanently. The audit trail shows exactly what happened and who authorized it.

### 7.3 Tier 3 — Systemic Error (Multiple Votes Affected)

If a machine malfunction, software bug, or tampering is suspected to have affected multiple votes:

- The machine is immediately taken out of service and quarantined for forensic examination.
- All VoteCasts from that machine are flagged for review.
- Affected voters are identified (via the blinded token system — the election authority can determine which tokens were issued by the compromised machine without revealing voter identities).
- A precinct-level revote may be ordered for affected voters under emergency procedures, with full observer access and heightened security.
- All original records are preserved. The revote produces new records that supersede the flagged ones.

---

## 8. Tabulation & Reporting

### 8.1 Precinct-Level Tabulation

At close of polls:

1. The voting machine exports its VoteCast records to encrypted, tamper-evident storage media (USB drives with cryptographic seals).
2. Two bipartisan election workers transport the media to the precinct tabulation center.
3. The tabulation system — an air-gapped computer with no network connectivity — ingests the records, verifies the Merkle tree integrity, and tallies the votes.
4. The precinct Merkle Root is computed and published.
5. Precinct results are reported to the county via a dedicated, isolated network or physical transport.

### 8.2 County & State Aggregation

County-level systems receive precinct roots and results, build the county-level Merkle tree, and aggregate totals. State-level systems repeat this process. At each level, the Merkle root is published, creating a verifiable chain from individual vote to statewide result.

### 8.3 Results Publication

The public results include:

- Total votes per candidate per race, at precinct, county, and state levels.
- The complete Merkle tree structure (all intermediate hashes), published on a public transparency log.
- The signed Ballot Definition File.
- Machine-by-machine vote counts (for auditability).

Any person with the published data can independently verify that the Merkle roots are correctly computed from the underlying votes and that the BDF has not been altered.

---

## 9. Audit Framework

### 9.1 Pre-Election Audits

**Canary Votes**: Before polls open, election officials cast a known set of test votes through each machine. These votes have predetermined selections. After polls close, canary votes are checked first. If any are incorrect, that machine's entire output is flagged.

**Parallel Testing**: On election day, a random subset of machines (at least 5% statewide) are pulled from voter service and subjected to continuous simulated voting by auditors. Their results are checked in real time. This catches malware that activates only on election day.

**Logic and Accuracy Testing (LAT)**: Standard pre-election testing of every machine with known inputs and expected outputs, conducted publicly with observer access.

### 9.2 Post-Election Audits

**Risk-Limiting Audits (RLAs)**: Mandatory, automatic, and conducted before results are certified. A statistically rigorous random sample of VVPAT paper ballots is hand-counted and compared against the digital record. If the discrepancy exceeds a calculated threshold (based on the margin of victory), the audit escalates to a full hand recount. RLAs provide a mathematical guarantee that the announced winner is correct with a specified confidence level (typically 95% or higher).

**Merkle Tree Verification**: Independent organizations (universities, watchdog groups, political parties) download the published Merkle trees and verify:

- Every leaf hashes correctly.
- The tree structure is sound.
- The published totals match the leaves.
- The BDF genesis record is unchanged.

**Cross-System Reconciliation**: The total number of VoterTokens issued (voters authenticated) must equal the total number of non-spoiled VoteCast records. Any discrepancy triggers an investigation.

### 9.3 Continuous Public Auditability

Because all software is open-source and all cryptographic proofs are published, any member of the public can audit any aspect of the election at any time. This is not a privilege granted by the government — it is a structural property of the system.

---

## 10. Threat Model & Mitigations

### 10.1 Threats to Voter Authentication

| Threat | Description | Mitigation |
|---|---|---|
| Forged ID | High-quality fake ID passes scan | Real-time database validation; biometric cross-check; anomaly detection on ID metadata |
| Stolen ID | Attacker uses a legitimate voter's real ID | Biometric mismatch triggers poll worker review; voter can report fraud post-election via VoterToken audit |
| Impersonation | Attacker physically resembles the ID holder | Dual-algorithm biometric matching; continuous presence detection; optional 2FA |
| Database poisoning | Attacker alters voter rolls before election day | Voter roll maintained on an append-only ledger with multi-party signing; bulk changes require public notice and challenge period |
| DoS via false rejections | Attacker triggers mass biometric failures to slow voting | Poll worker manual override available; paper ballot fallback always available; multiple machines per precinct |

### 10.2 Threats to Ballot Integrity

| Threat | Description | Mitigation |
|---|---|---|
| Name-swap attack | Attacker swaps candidate labels in the database | CandidateHashes derived from identity; BDF signed by multi-party committee and published pre-election; BDF hash embedded in Merkle genesis |
| Ballot definition tampering | Attacker alters the BDF after publication | BDF on public transparency log; any alteration detectable by comparing against pre-published copies held by multiple parties |
| Ballot rendering manipulation | Machine displays one candidate but records another | VVPAT paper trail allows voter to verify; open-source rendering code is auditable; parallel testing catches discrepancies |

### 10.3 Threats to Vote Recording

| Threat | Description | Mitigation |
|---|---|---|
| Vote alteration | Attacker changes a recorded vote | Merkle tree makes any change detectable; VVPAT provides independent record; RLAs catch discrepancies |
| Vote deletion | Attacker removes votes from the record | VoterToken count must match VoteCast count; Merkle tree integrity check detects missing leaves |
| Vote injection | Attacker adds fabricated votes | Every VoteCast requires a signed VoterToken; tokens are issued only after authentication; token count is bounded by registered voters |
| Replay attack | Attacker duplicates a legitimate vote | Each VoteCast has a unique nonce and VoteRecordID; duplicates are detectable and rejected |

### 10.4 Threats to Infrastructure

| Threat | Description | Mitigation |
|---|---|---|
| Supply chain compromise | Malware installed on machines during manufacturing | Open-source software with reproducible builds; hardware attestation via TPM; random forensic audits of machines |
| Network attack | Attacker compromises the ID verification network | Machines function fully offline with local voter roll cache; network is dedicated and isolated from public internet |
| Insider threat | Election worker manipulates machines or records | All administrative actions require two-person authorization from different parties; tamper-evident seals with serial number tracking; comprehensive logging |
| Physical tampering | Attacker gains physical access to a machine | Tamper-evident enclosures; chain-of-custody logging; machines stored in monitored, secured locations |
| Power failure | Power outage disrupts voting | Battery backup on all machines; paper ballot fallback procedures activated within 30 minutes |

### 10.5 Threats to Voter Privacy

| Threat | Description | Mitigation |
|---|---|---|
| Receipt-based coercion | Coercer demands proof of how voter voted | Receipt proves inclusion, not selections; full verification only at controlled Audit Centers |
| Biometric surveillance | Stored biometric data used for non-election purposes | Raw biometrics are never stored on voting machines; only one-way hashes in vote records; encrypted templates in air-gapped audit archive with strict access controls |
| Traffic analysis | Attacker correlates voter check-in times with vote timestamps | VoterTokens are blinded; timestamps in VoteCasts are randomized within a window (e.g., +/- 5 minutes) |
| Side-channel observation | Someone watches the voter's screen | Privacy screens on machines; voting booth enclosures; same physical privacy measures as current systems |

### 10.6 Future Threats

| Threat | Description | Mitigation |
|---|---|---|
| Quantum computing | Future quantum computers break SHA-256 or signature schemes | System designed to be algorithm-agile; cryptographic primitives can be swapped to post-quantum alternatives (e.g., CRYSTALS-Dilithium, SPHINCS+) without redesigning the architecture |
| Advanced deepfakes | AI-generated faces defeat biometric matching | Multi-modal biometrics (face + fingerprint); liveness detection (blink, head turn); hardware-level presentation attack detection |

---

## 11. Infrastructure & Network Architecture

### 11.1 Voting Machine Specifications

- Air-gapped during voting (no network required to cast a vote).
- TPM chip for firmware attestation.
- Dedicated camera and fingerprint reader (no shared sensors).
- Thermal printer for VVPAT and receipt.
- Battery backup (minimum 4 hours).
- Tamper-evident physical enclosure with serialized seals.
- Open-source firmware and software, reproducible from public source code.

### 11.2 Network Topology

- **Polling place network** (optional): Dedicated, encrypted, isolated — used only for real-time ID validation and VoterToken issuance. Not connected to the public internet.
- **Tabulation network**: Physically separate from the polling place network. Used post-election for precinct-to-county result transmission. Alternatively, physical media transport (sneakernet) with cryptographic seals.
- **Public verification portal**: Standard web infrastructure, serving only published Merkle trees and verification endpoints. Read-only. No connection to election infrastructure.

### 11.3 Data Flow

```
[Voter] → [Voting Machine (air-gapped)]
              ├── VoteCast → [Encrypted USB] → [Tabulation (air-gapped)]
              ├── VVPAT → [Sealed Paper Box]
              └── Receipt → [Voter keeps]

[Tabulation] → [Precinct Root] → [County Aggregation] → [State Root]
                                                              ↓
                                                    [Public Transparency Log]
                                                              ↓
                                                    [Verification Portal]
```

---

## 12. Open Questions & Future Work

The following questions remain unresolved and require further research, public debate, or pilot testing:

1. **Accessibility**: How does the biometric system accommodate voters with physical disabilities, facial disfigurement, or conditions that affect biometric capture? The system must comply with ADA requirements. Fallback authentication paths must be robust and non-stigmatizing.

2. **Scalability of Merkle tree publication**: For large precincts (50,000+ voters), the full Merkle tree data could be substantial. What is the optimal publication format and hosting infrastructure?

3. **Voter education**: This system is significantly more complex than current voting. What training, outreach, and UX design is needed to ensure voters understand and trust the process?

4. **Cost**: Per-unit cost of machines with biometric sensors, TPM chips, and printers; ongoing software maintenance; audit infrastructure; universal ID issuance. A cost-benefit analysis against current systems is needed.

5. **Legal framework**: Many states have specific statutory requirements for voting systems (e.g., no internet connectivity, specific recount procedures). What legislative changes are required?

6. **Pilot program design**: Which jurisdictions would be suitable for initial pilots? What metrics define success?

7. **Handling of mail-in and absentee voting**: This architecture is designed for in-person voting. A parallel track is needed for absentee/mail-in ballots that preserves as many of these guarantees as possible.

8. **Provisional ballots**: When authentication fails or a voter's eligibility is disputed, the system must support provisional voting with a clear adjudication pathway.

9. **Multi-language and multi-format support**: Ballot rendering must support multiple languages, large print, audio, and other accessibility formats — all derived deterministically from the same signed BDF.

10. **Election worker training and certification**: The system introduces new procedures (biometric fallback, Merkle verification, two-person authorization). A comprehensive training program is required.

---

## 13. Glossary

| Term | Definition |
|---|---|
| **BDF** | Ballot Definition File — the signed master mapping between human-readable ballot content and CandidateHashes |
| **Blind Signature** | A cryptographic technique that allows a message to be signed without the signer seeing its content — used to anonymize VoterTokens |
| **CandidateHash** | A SHA-256 hash uniquely identifying a candidate or ballot measure, derived from their legal name, party, race, and election ID |
| **Canary Vote** | A pre-determined test vote cast before polls open to verify machine integrity |
| **E2E-V** | End-to-End Verifiable — a property of voting systems where every voter can confirm their vote was recorded and counted correctly |
| **Election PIN** | A unique, random code issued to each voter for use in post-election verification; replaces SSN or other compromised identifiers |
| **Merkle Root** | The single top-level hash of a Merkle tree, representing a tamper-evident fingerprint of all underlying data |
| **Merkle Tree** | A hash-based data structure where each leaf is a data item and each node is the hash of its children; any change to any leaf alters the root |
| **Nonce** | A random value used once, included in a VoteCast to ensure uniqueness |
| **RLA** | Risk-Limiting Audit — a statistical audit method that provides a known confidence level that the election outcome is correct |
| **Tombstoned** | A VoteCast marked as voided after the voter has left, with a signed reason and dual authorization |
| **VoteCast** | The complete record of a single vote, including selections, cryptographic metadata, and status |
| **VoteRecordID** | A unique UUID assigned to each VoteCast at the time of casting |
| **VoterToken** | A blinded, signed token proving that a registered voter cast a ballot, without revealing which voter |
| **VVPAT** | Voter-Verified Paper Audit Trail — a physical paper record of the voter's selections, reviewed by the voter before deposit |

---

## Contributing

This is a living document. If you identify a vulnerability, an unconsidered attack vector, a usability concern, or an improvement, open an issue or submit a pull request. The strength of this system depends on public scrutiny.

---

## License

This specification is released under [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/). You are free to share and adapt this material for any purpose, provided you give appropriate credit.
