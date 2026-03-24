# SecureVote — Network Topology & Security Architecture

## Design Principle: Assume the Network is Hostile

Every network segment in SecureVote is designed under the assumption that it has already been compromised. No security property depends on network confidentiality alone. The system works even if an attacker has full read access to every packet on every wire. This is achieved through defense-in-depth: physical isolation, encryption in transit, mutual authentication, and application-layer integrity checks that remain valid even if transport security fails.

The corollary: **the most important machines in the system are on no network at all.**

---

## Network Zones Overview

SecureVote operates across **six network zones**, each physically or logically isolated. No device belongs to more than one zone. No traffic flows directly between non-adjacent zones.

| Zone | Name | Classification | Connectivity | Contains |
|---|---|---|---|---|
| Zone 0 | **Air Gap** | TOP SECRET | None | Tabulation machines, forensic audit stations |
| Zone 1 | **Polling Place LAN** | RESTRICTED | Isolated per-precinct; no internet | Voting machines, local ID verification server |
| Zone 2 | **Transport** | RESTRICTED | Physical media (encrypted USB drives) | USB drives moving data between Zones 0, 1, and 3 |
| Zone 3 | **County Election Network** | CONFIDENTIAL | Private WAN; no internet | County election servers, result aggregation |
| Zone 4 | **Admin Network** | CONFIDENTIAL | Restricted LAN; no internet | sv-admin servers, BDF management, machine provisioning |
| Zone 5 | **Public DMZ** | PUBLIC | Internet-facing | sv-verify portal, Merkle tree publication, transparency log |

### Zone Adjacency (What Can Talk to What)

```
Zone 0 (Air Gap)  ←──USB──→  Zone 2 (Transport)  ←──USB──→  Zone 1 (Polling Place)
                                    │
                               ──USB──
                                    │
                                    ▼
                              Zone 3 (County Network)
                                    │
                              ──one-way──
                                    │
                                    ▼
                              Zone 5 (Public DMZ)

Zone 4 (Admin)  ──mTLS──→  Zone 3 (County Network)
                ──mTLS──→  Zone 1 (Polling Place, pre-election only)
```

Key rules:
- Zone 0 has NO network interface. Data enters and exits only via Zone 2 (encrypted USB).
- Zone 1 machines have NO internet access. The polling place LAN is a closed loop.
- Zone 3 publishes results to Zone 5 via a **one-way data diode** (hardware-enforced unidirectional link). Zone 5 cannot send any data back into Zone 3.
- Zone 4 can reach Zone 3 and Zone 1, but only over mTLS with client certificates. Zone 4 cannot reach Zone 0 or Zone 5.
- Zone 5 is the only zone connected to the public internet. It serves read-only data. It has no write path to any other zone.

---

## Zone 0: Air Gap (Tabulation)

### What Lives Here

- **Tabulation machines** (running sv-tabulator)
- **Forensic audit workstations** (for post-election machine examination)
- **Merkle tree computation servers** (if the workload exceeds a single machine)
- **HSM (Hardware Security Module)** for key ceremonies (BDF signing, firmware signing)

### Network Configuration

None. These machines have:
- No Ethernet port (or the port is physically disabled: RJ45 jack filled with epoxy)
- No Wi-Fi (hardware removed or disabled in firmware + no antenna trace on board)
- No Bluetooth
- No cellular modem
- No infrared

### Data Flow

Data enters and exits Zone 0 exclusively through Zone 2 (encrypted USB drives):

**Inbound**: After polls close, bipartisan transport teams carry encrypted USB drives from each precinct (Zone 1) to the tabulation center (Zone 0). Each USB drive contains that precinct's vote records, encrypted with a key derived from the election's master transport key (sealed in the HSM).

**Outbound**: After tabulation, Merkle roots and aggregated results are exported to encrypted USB drives and physically carried to the County Election Network (Zone 3) for publication.

### Physical Security

- The tabulation room is access-controlled (badge + biometric entry)
- All entry/exit is logged and recorded on camera
- Bipartisan observers are present during all tabulation operations
- USB drives are carried in tamper-evident bags with serial numbers matching the chain-of-custody log

---

## Zone 1: Polling Place LAN

### What Lives Here

- **Voting machines** (4-8 per precinct, running sv-machine)
- **Local Authentication Server (LAS)** — one per precinct
- **Network switch** — managed, VLAN-capable
- **Uninterruptible Power Supply (UPS)** for network equipment

### Network Topology

```
                    ┌─────────────────────────────────────┐
                    │         Polling Place LAN            │
                    │         (No Internet Access)         │
                    │                                      │
                    │  ┌────────────────────────────────┐  │
                    │  │   Managed Switch (VLAN-aware)  │  │
                    │  │   8-16 port, PoE optional      │  │
                    │  └──┬─────┬─────┬─────┬──────┬───┘  │
                    │     │     │     │     │      │       │
                    │     │     │     │     │      │       │
                    │  ┌──┴──┐┌─┴──┐┌─┴──┐┌┴───┐┌─┴────┐ │
                    │  │ VM1 ││VM2 ││VM3 ││VM4 ││ LAS  │ │
                    │  └─────┘└────┘└────┘└────┘└──────┘ │
                    │                                      │
                    │  Optional uplink to County (Zone 3): │
                    │  ┌──────────────────────────────┐    │
                    │  │  Cellular/VPN Gateway         │    │
                    │  │  (disabled after polls close)  │    │
                    │  └──────────────────────────────┘    │
                    │                                      │
                    └─────────────────────────────────────┘
```

### Local Authentication Server (LAS)

The LAS is the critical piece that enables voting machines to operate with minimal network dependency. It is a hardened appliance (same CM5 hardware as the voting machine, different firmware) that:

1. **Caches the precinct voter roll** — a full, encrypted copy of the voter registration data for this precinct, loaded from an encrypted USB drive before polls open.
2. **Issues blind-signed VoterTokens** — when a voting machine authenticates a voter, the LAS verifies eligibility and issues the blinded token. The blind signature private key for this precinct is loaded from the HSM during pre-election provisioning and stored in the LAS's TPM.
3. **Tracks "token issued" flags** — prevents the same voter from receiving two tokens. This is the LAS's most critical function.
4. **Optionally syncs with County** — if the cellular/VPN uplink to Zone 3 is available, the LAS can check for cross-precinct voting (a voter who already voted at another precinct). If the uplink is down, the LAS operates on its local cache and cross-precinct checks happen during post-election reconciliation.

### VLANs

The managed switch enforces two VLANs:

| VLAN | Name | Members | Purpose |
|---|---|---|---|
| VLAN 10 | Auth | Voting machines + LAS | ID verification, token issuance |
| VLAN 20 | Mgmt | LAS uplink port only | Optional county sync, machine health telemetry |

Voting machines are on VLAN 10 only. They can talk to the LAS and nothing else. The LAS bridges between VLAN 10 (auth requests from machines) and VLAN 20 (uplink to county). Voting machines have no route to the uplink — even if the uplink is compromised, no traffic can reach the machines.

### Firewall Rules (on the managed switch and LAS)

```
# VLAN 10 (Auth) — voting machines to LAS only
ALLOW  VM_any → LAS:4430/tcp   (mTLS auth API)
ALLOW  LAS:4430 → VM_any       (response)
DENY   VM_any → ANY            (everything else)

# VLAN 20 (Mgmt) — LAS to county gateway only
ALLOW  LAS → GW:8443/tcp       (mTLS county sync)
ALLOW  GW:8443 → LAS           (response)
DENY   LAS → ANY               (everything else on VLAN 20)

# Cross-VLAN
DENY   VLAN_10 → VLAN_20       (machines cannot reach uplink)
DENY   VLAN_20 → VLAN_10       (uplink cannot reach machines)
# Exception: LAS is dual-homed on both VLANs
```

### Protocol: Machine ↔ LAS Communication

All communication between voting machines and the LAS uses **mTLS** (mutual TLS 1.3) over TCP port 4430.

- Each voting machine has a unique TLS client certificate, issued during provisioning, with the machine's TPM-backed private key. The certificate is bound to the machine's hardware identity.
- The LAS has a server certificate signed by the election authority's CA.
- Both sides verify certificates before any application data flows.
- Certificate revocation is checked against a local CRL (no OCSP dependency on external networks).

### What Happens When the Network Goes Down

The system is designed to function with **zero network connectivity**. Here's the degradation path:

| Component Down | Impact | Mitigation |
|---|---|---|
| LAS unreachable from a machine | Machine cannot issue new tokens | Machine switches to **offline mode**: voter scans ID, biometric check runs locally, but vote is recorded as PROVISIONAL. Token is issued when LAS is restored. |
| County uplink down | No cross-precinct checking | LAS issues tokens based on local voter roll. Cross-precinct duplicates caught during post-election reconciliation. |
| LAS hardware failure | All machines lose auth capability | Backup LAS (identical hardware, identical data load) is brought online. Every precinct has one backup LAS in storage. |
| Switch failure | All machines isolated | Each machine continues in fully offline mode. Votes are PROVISIONAL. Paper ballot fallback activated. |
| Total power failure (UPS exhausted) | Everything stops | Paper ballot fallback. The election continues on paper. |

The key insight: **no network failure can stop voting.** It can degrade the digital verification, but the voter always has a path to cast a ballot (provisional digital or paper).

---

## Zone 2: Transport (Physical Media)

### What It Is

Zone 2 is not a network — it is a physical chain-of-custody process for moving encrypted data between air-gapped zones. The "medium" is a set of **hardware-encrypted USB drives** with tamper-evident seals.

### USB Drive Specifications

| Property | Specification |
|---|---|
| Encryption | AES-256 hardware encryption (FIPS 140-2 Level 3) |
| Authentication | PIN-protected (8+ digits, entered on the drive's physical keypad) |
| Tamper protection | Epoxy-potted internals; self-destructs data after 10 wrong PIN attempts |
| Capacity | 32GB (far more than needed; largest precinct ~200MB) |
| Write protection | Physical read-only switch for outbound result drives |
| Connector | USB-A (universal compatibility) |
| Example product | Apricorn Aegis Secure Key 3NXC or equivalent |

### Transport Procedures

**Election Night: Polling Place → Tabulation Center**

1. Polls close. The voting machine exports its vote records to the USB drive, encrypted with the precinct transport key.
2. The chief judge and a bipartisan witness both enter their PINs on the USB drive to lock it.
3. The USB drive is placed in a tamper-evident bag, sealed with a numbered security seal.
4. The seal number is recorded in the chain-of-custody log, signed by both the chief judge and the witness.
5. A bipartisan transport team carries the bag to the tabulation center.
6. At the tabulation center, the seal number is verified against the log. The bag is opened in the presence of observers.
7. The USB drive is inserted into the tabulation machine. The tabulation officer and a witness enter their PINs to unlock the drive.
8. Data is ingested. The USB drive is ejected, re-sealed, and stored as evidence.

**Tabulation Center → County Network**

1. After tabulation, results and Merkle roots are exported to a separate USB drive (write-once, read-only switch engaged after export).
2. Same sealing and chain-of-custody process.
3. The drive is carried to the County Election Network room and ingested via the data diode interface.

### Why Not a Network?

A network between the tabulation center and polling places would be the highest-value target in the entire system. Any compromise of that link could allow:
- Vote injection (fabricated votes inserted during transport)
- Vote modification (selections altered in transit)
- Denial of service (results delayed or blocked)
- Metadata leakage (precinct-level results before official release)

Physical transport with hardware-encrypted drives, tamper-evident bags, bipartisan custody, and serial-number-tracked seals makes all of these attacks require physical presence, conspiracy between parties, and the ability to defeat hardware encryption — a dramatically harder attack than any network exploit.

---

## Zone 3: County Election Network

### What Lives Here

- **County Election Server** — receives results from Zone 2, aggregates county totals
- **State Sync Node** — forwards county results to the state election authority
- **Voter Roll Master** — the authoritative voter registration database for the county
- **Data Diode Gateway** — hardware-enforced one-way link to Zone 5

### Network Topology

```
┌──────────────────────────────────────────────────────┐
│              County Election Network                  │
│              (Private WAN, No Internet)               │
│                                                       │
│  ┌────────────┐    ┌─────────────┐    ┌───────────┐ │
│  │ County     │    │ Voter Roll  │    │ State     │ │
│  │ Election   │◄───│ Master DB   │    │ Sync Node │ │
│  │ Server     │    │             │    │           │ │
│  └─────┬──────┘    └─────────────┘    └─────┬─────┘ │
│        │                                     │       │
│        │        ┌──────────────┐             │       │
│        └────────│ Internal     │─────────────┘       │
│                 │ Switch       │                      │
│                 └──────┬───────┘                      │
│                        │                              │
│  ┌─────────────────────┴────────────────────────┐    │
│  │            Data Diode                         │    │
│  │  (Hardware-enforced unidirectional gateway)   │    │
│  │  TX only → Zone 5. RX physically impossible.  │    │
│  └──────────────────────┬───────────────────────┘    │
│                         │ (fiber, TX laser only)      │
└─────────────────────────┼────────────────────────────┘
                          │
                          ▼
                    Zone 5 (Public DMZ)
```

### Data Diode

The data diode is the most important network security device in the entire architecture. It is a hardware device that physically enforces one-way communication:

- It transmits data from Zone 3 to Zone 5 using a **fiber optic link with only a transmit laser** on the Zone 3 side. There is no receive photodiode on the Zone 3 side. It is physically impossible for Zone 5 to send any data back.
- Commercial products: Owl Cyber Defense, Waterfall Security, Fox-IT DataDiode.
- The diode transmits: Merkle roots, aggregated vote counts, signed BDF hashes, and RLA results.
- The diode cannot transmit: arbitrary commands, database queries, network probes, or any interactive protocol.

The data format across the diode is a simple, one-way UDP broadcast of signed JSON blobs. The Zone 5 receiver validates the signature and publishes the data. If a blob is corrupted in transit, Zone 5 simply waits for the next retransmission (Zone 3 retransmits every 30 seconds until acknowledged — though it can never receive an acknowledgment, so it retransmits for a fixed window).

### County-to-State Communication

Counties connect to the state election authority over a **dedicated, private WAN** (leased lines or VPN over a private backbone — not the public internet). This network carries:

- Aggregated county results → state aggregation server
- Cross-precinct voting alerts (voter who received tokens at multiple precincts)
- Administrative commands (election status changes, emergency alerts)

The WAN uses **IPsec tunnels** with pre-shared keys distributed during pre-election provisioning. Each county has a unique tunnel to the state. Counties cannot communicate with each other — only with the state.

---

## Zone 4: Admin Network

### What Lives Here

- **sv-admin servers** (election setup, BDF management, machine provisioning, worker management, PIN generation)
- **Admin workstations** (used by authorized election administrators)
- **BDF signing stations** (where multi-party BDF signing ceremonies occur)
- **Machine provisioning stations** (where firmware is loaded onto USB drives for deployment)

### Network Configuration

Zone 4 is a restricted LAN in the election authority's offices. It has:
- **No internet access** (physically disconnected from any internet-connected network)
- **mTLS connections to Zone 3** (for pushing election definitions, pulling voter roll data)
- **mTLS connections to Zone 1** (during pre-election only, for loading voter rolls onto LAS devices and provisioning machines)
- **Physical access control** (badge + PIN entry to the admin room)

### Admin Workstation Hardening

Admin workstations are dedicated machines (not shared-use PCs):
- Run a hardened OS (same minimal Linux as voting machines, plus a web browser for the sv-admin UI)
- Have mTLS client certificates issued to specific administrators
- Require multi-factor authentication (badge + PIN + certificate)
- Log all actions to a tamper-evident audit log
- Are inventoried and tracked like voting machines

---

## Zone 5: Public DMZ

### What Lives Here

- **sv-verify servers** (public verification portal)
- **Transparency log mirror** (public read-only copy of BDF hashes and Merkle roots)
- **Static result publication servers** (public election results pages)
- **CDN edge nodes** (for high-traffic result pages on election night)

### Network Topology

```
┌──────────────────────────────────────────────────────────┐
│                    Public DMZ (Zone 5)                     │
│                                                           │
│  ┌──────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │ sv-verify │    │ Transparency │    │ Results        │  │
│  │ (portal)  │    │ Log Mirror   │    │ Publication    │  │
│  └─────┬─────┘    └──────┬───────┘    └───────┬────────┘  │
│        │                 │                     │           │
│  ┌─────┴─────────────────┴─────────────────────┴───────┐  │
│  │                Load Balancer / WAF                   │  │
│  │     (Rate limiting, DDoS mitigation, TLS term)      │  │
│  └──────────────────────┬──────────────────────────────┘  │
│                         │                                  │
└─────────────────────────┼──────────────────────────────────┘
                          │
                     Public Internet
                          │
                    ┌─────┴─────┐
                    │  Voters,  │
                    │  Media,   │
                    │  Auditors │
                    └───────────┘
```

### Security Controls

Zone 5 is the only zone exposed to the public internet. It is hardened accordingly:

**Web Application Firewall (WAF)**:
- Rate limiting: 10 requests per IP per minute for the verification API
- DDoS protection: commercial DDoS mitigation (Cloudflare, AWS Shield, or equivalent)
- Input validation: all API inputs are validated and sanitized before processing
- SQL injection protection: parameterized queries only (no dynamic SQL)

**sv-verify Database Access**:
- sv-verify connects to a **read-only replica** of securevote_votes
- The replica is fed by the data diode (Zone 3 → Zone 5). It is never directly connected to the primary database.
- The replica contains only the tables needed for verification: `vote_casts` (existence check only — no selections column exposed), `merkle_trees`, `merkle_nodes`, and `verification_attempts`.
- The database user has `SELECT` privileges only, on specific views that expose no voter tokens, no selections, and no biometric hashes.

**TLS Configuration**:
- TLS 1.3 only (no fallback to 1.2)
- Strong cipher suites only: TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256
- HSTS enabled with 1-year max-age and preload
- Certificate pinning in the verification mobile app (if one exists)

**Monitoring**:
- All access logs shipped to a SIEM (Security Information and Event Management) system
- Anomaly detection on request patterns (e.g., someone querying thousands of VoteRecordIDs)
- Alerting on any unexpected outbound connections (sv-verify should never initiate outbound traffic)

---

## Cross-Zone Data Flows

### Election Day: Voter Authentication Flow

```
Voter → [Voting Machine (Zone 1)]
             │
             │  mTLS on VLAN 10
             ▼
        [LAS (Zone 1)]
             │
             │  Checks local voter roll cache
             │  Issues blind-signed token
             │
             │  Optionally (if uplink available):
             │  mTLS on VLAN 20
             ▼
        [County Voter Roll (Zone 3)]
             │
             │  Cross-precinct check
             │  Returns OK or ALREADY_VOTED
```

### Election Night: Result Publication Flow

```
[Voting Machine (Zone 1)]
       │
       │ Exports to encrypted USB
       ▼
[USB Drive (Zone 2)]
       │
       │ Physical transport
       ▼
[Tabulation Machine (Zone 0)]
       │
       │ Builds Merkle tree, tabulates
       │ Exports results to USB
       ▼
[USB Drive (Zone 2)]
       │
       │ Physical transport
       ▼
[County Election Server (Zone 3)]
       │
       │ Aggregates county totals
       │ Transmits via data diode (one-way)
       ▼
[sv-verify / Results Server (Zone 5)]
       │
       │ Published on public internet
       ▼
[Voters, Media, Auditors]
```

### Post-Election: Voter Verification Flow

```
Voter (phone/computer)
       │
       │ HTTPS (TLS 1.3)
       ▼
[Load Balancer / WAF (Zone 5)]
       │
       │ Rate limited, DDoS protected
       ▼
[sv-verify (Zone 5)]
       │
       │ SELECT on read-only replica
       ▼
[Votes DB Read Replica (Zone 5)]
       │
       │ Returns: vote exists (yes/no)
       │ Returns: Merkle proof
       │ Does NOT return: selections
       ▼
[sv-verify (Zone 5)]
       │
       │ JSON response
       ▼
Voter sees: "Your vote was counted. ✓"
```

---

## DNS, NTP, and Supporting Services

### DNS

- Zone 1 (Polling Place): **No DNS.** All communication uses IP addresses hardcoded in the machine configuration. DNS is a dependency and an attack surface that provides no value in a closed LAN.
- Zone 3 (County): Internal DNS for county services. No external DNS resolution.
- Zone 5 (Public DMZ): Standard DNS for public-facing domains (`verify.securevote.gov`). DNSSEC enabled.

### NTP (Time Synchronization)

Accurate timestamps are critical for audit trails and Merkle tree ordering. Each zone has its own time source:

- **Zone 0**: GPS-disciplined NTP server (receives time from GPS satellites, no network needed).
- **Zone 1**: The LAS runs an NTP server for the polling place LAN. Its time source is either the county uplink (if available) or a local GPS module.
- **Zone 3**: GPS-disciplined NTP server.
- **Zone 5**: Standard NTP from trusted upstream servers (NIST, USNO).

Voting machines sync time with the LAS at boot and every 30 minutes during operation. If the time skew between a machine and the LAS exceeds 30 seconds, the machine logs an anomaly alert.

### Logging

All network-connected devices ship structured logs to a central log collector within their zone:
- Zone 1: Logs aggregated on the LAS, exported to USB with vote data.
- Zone 3: County-level SIEM aggregation.
- Zone 5: Cloud-based SIEM with real-time alerting.

Logs are append-only, hash-chained (same pattern as the database audit logs), and signed by the originating device's TPM key. Tampering with logs requires breaking the hash chain, which is detectable.

---

## Threat Mitigations by Zone

| Attack | Zone Targeted | Mitigation |
|---|---|---|
| Man-in-the-middle on polling LAN | Zone 1 | mTLS with client certificates (attacker cannot forge machine identity) |
| Rogue voting machine on LAN | Zone 1 | mTLS — LAS rejects connections from unknown certificates; switch has MAC address filtering |
| ARP spoofing | Zone 1 | Static ARP entries on managed switch; 802.1X port authentication |
| Physical network tap | Zone 1 | All traffic is encrypted (mTLS); passive sniffing reveals no plaintext |
| DNS poisoning | Zone 1 | No DNS used; all IPs are static configuration |
| DDoS on verification portal | Zone 5 | WAF + CDN + rate limiting; verification portal is read-only so DDoS cannot affect vote integrity |
| SQL injection on verification portal | Zone 5 | Parameterized queries; DB user has SELECT-only on restricted views |
| Data exfiltration from county network | Zone 3 | Data diode ensures no inbound traffic from Zone 5; county network has no internet |
| Compromised USB drive | Zone 2 | Hardware encryption (PIN + self-destruct after failed attempts); data integrity verified by Merkle hashes on ingest |
| Insider with network access | Any | Logs are hash-chained and TPM-signed; cannot be tampered without detection |

---

## Hardware Bill of Materials (Network Equipment)

### Per Polling Place

| Equipment | Model Class | Purpose | Est. Cost |
|---|---|---|---|
| Managed switch | Cisco CBS250-8P or equiv. | VLAN enforcement, 802.1X | $200-$350 |
| LAS appliance | SecureVote CB-1 (same as voting machine) | Local auth, voter roll cache, token issuance | $500 |
| Backup LAS | Identical to primary | Hot spare | $500 |
| UPS for network | APC Back-UPS 600VA | Powers switch + LAS during outage | $80 |
| Ethernet cables | Cat6, various lengths | Machine ↔ switch, LAS ↔ switch | $30 |
| Cellular gateway (optional) | Sierra Wireless or equiv. | County uplink for cross-precinct checks | $150-$300 |
| Locking network cabinet | Small wall-mount rack | Physical security for switch, LAS, UPS | $100-$200 |

**Total per polling place (network equipment)**: $1,560-$1,930

### County Level

| Equipment | Purpose | Est. Cost |
|---|---|---|
| Data diode | Hardware one-way gateway (Owl or Waterfall) | $8,000-$15,000 |
| County election server | Result aggregation, voter roll master | $5,000-$10,000 |
| Firewall | Zone boundary enforcement | $2,000-$5,000 |
| Switch infrastructure | Internal county network | $1,000-$3,000 |
| GPS NTP server | Stratum 1 time source | $500-$1,500 |
| Rack, UPS, cabling | Physical infrastructure | $3,000-$5,000 |

**Total per county**: $19,500-$39,500

---

## Network Monitoring & Incident Response

### Real-Time Monitoring

Each zone has monitoring appropriate to its classification:

- **Zone 1**: The LAS monitors all traffic on the polling place LAN. It detects and alerts on unknown MAC addresses (rogue devices), certificate validation failures (spoofed machines), and unusual traffic patterns (port scanning, high packet rates). Alerts are shown on the poll worker dashboard.
- **Zone 3**: Standard network monitoring (Nagios/Zabbix or equivalent) with alerting to the county IT team.
- **Zone 5**: Full-stack monitoring: network (traffic analysis), application (request latency, error rates), and security (WAF alerts, anomalous query patterns).

### Incident Response

| Incident | Detection | Response |
|---|---|---|
| Unknown device on polling LAN | LAS MAC detection | Switch port disabled; poll worker alerted; incident logged |
| mTLS handshake failure spike | LAS connection logs | Potential MITM attack; affected machine taken offline; manual inspection |
| LAS unresponsive | Machine connection timeout | Machines switch to offline/provisional mode; backup LAS activated |
| Data diode failure | Zone 5 stops receiving updates | County IT alerted; manual USB transport of results as fallback |
| DDoS on Zone 5 | WAF traffic analysis | Mitigation activates automatically; no impact on vote recording or counting |
| Rogue USB drive detected | Drive fails decryption / signature check | Drive quarantined; entire precinct's results verified against VVPAT paper trail |
