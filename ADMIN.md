# SecureVote — Admin Portal User Guide

## Overview

The SecureVote Admin Portal is the government operator's interface for managing elections and issuing voter identification cards. It runs at:

```
https://vote.badvolf.com:8443/admin
```

All actions are logged. All operators must authenticate. Every card issued creates an audit trail entry.

## Login

| Field | Value |
|---|---|
| URL | `https://vote.badvolf.com:8443/admin` |
| Admin username | `admin001` |
| Admin password | `Admin001PWord` |
| Operator username | `operator002` |
| Operator password | `Operator2Pass` |

### Security

- **5 failed login attempts** locks the account for 30 minutes
- Failed attempt counter resets on successful login
- Sessions last 8 hours, then require re-authentication
- All logins are recorded with timestamp and IP address

### Access Levels

| Level | Card Issuance | View Elections | Edit Elections |
|---|---|---|---|
| OPERATOR | ✓ | ✓ | ✗ |
| SUPERVISOR | ✓ | ✓ | ✓ |
| ADMIN | ✓ | ✓ | ✓ |

## Dashboard Tab

The landing page after login. Shows at a glance:

- **Voters** — Total registered voters in the database
- **Elections** — Number of active elections
- **Races** — Total races across all elections
- **Candidates** — Total candidates across all races
- **Cards Today** — ID cards generated today by all operators
- **Cards Total** — Lifetime card generation count

Below the stats: a log of the most recent 20 card issuances with voter name, format (PNG/PDF), and timestamp.

## ID Cards Tab

### Searching for Voters

Type in the search box using one of these formats:

| Search Format | Example | What it does |
|---|---|---|
| Last name (4+ chars) | `Smith` | Searches last names starting with "Smith" |
| Last, First | `Smith, John` | Last name + first name (3+ chars each) |
| Last, First, Middle | `Smith, John, A` | All three name fields |
| Short last name + comma | `Li,` | Forces search on 2-char last name |
| Voter ID number | `12345` | Exact match on voter_id |
| Registration number | `FL-0000012345` | Match on registration number |

**Results are limited to 50.** If you see the yellow warning bar, add a comma and first name to narrow down.

### Generating Cards

Each voter row shows two buttons:

- **PNG** — Generates a combined front+back card image (2024x1276 per side). Displays inline with download option.
- **PDF** — Opens in a new tab as a 2-page PDF (front and back). Print-ready at credit card size.

### Card Contents

**Front:**
- SecureVote header with American flag element
- Photo placeholder (for scanner camera capture on real machines)
- Full legal name
- Date of birth
- Registration number
- Registration date
- County code
- Precinct assignment
- Mailing address
- ACTIVE/INACTIVE status badge
- Verification hash (SHA-256 derived, first 16 hex chars)
- State code
- Issue date

**Back:**
- QR code containing JSON payload:
  ```json
  {
    "sv": "1.0",
    "reg": "FL-0000012345",
    "uuid": "voter-uuid",
    "hash": "verification-hash",
    "state": "FL",
    "county": "PAL",
    "precinct": "PAL-001"
  }
  ```
- Barcode strip (simulated magnetic stripe)
- Machine-readable zone (MRZ, passport-style)
- Usage instructions
- Card ID number

### Audit Trail

Every card generated is logged in the `card_issuance_log` table:

| Field | Description |
|---|---|
| `operator_id` | Who generated it |
| `voter_id` | Which voter |
| `card_format` | PNG or PDF |
| `card_hash` | SHA-256 of the generated file |
| `issuer_ip` | IP address of the operator |
| `issued_at` | Timestamp |
| `reason` | NEW_ISSUANCE, REPLACEMENT, etc. |

## Elections Tab

### Adding a Jurisdiction

Before creating an election, you need jurisdictions in the hierarchy. The system supports:

```
US (FEDERAL)
└── US-FL (STATE)
    ├── US-FL-PAL (COUNTY) — Palm Beach
    ├── US-FL-BRO (COUNTY) — Broward
    └── US-FL-DAD (COUNTY) — Miami-Dade
```

| Field | Example | Description |
|---|---|---|
| ID | `US-FL-PAL` | Unique identifier, hierarchical by convention |
| Parent | `US-FL` | Parent jurisdiction ID (blank for top-level) |
| Type | `COUNTY` | FEDERAL, STATE, COUNTY, or MUNICIPAL |
| Name | `Palm Beach County` | Display name |
| FIPS Code | `099` | Federal code (optional) |

### Adding an Election

| Field | Example | Description |
|---|---|---|
| Election ID | `general-2026-11-03` | Unique identifier |
| Jurisdiction ID | `US-FL` | Which jurisdiction runs this election |
| Title | `Florida General Election 2026` | Display title |
| Type | `GENERAL` | GENERAL, PRIMARY, SPECIAL, RUNOFF, RECALL |
| Election Date | `2026-11-03` | Date picker |
| Polls Open | `06:00` | Opening time |
| Polls Close | `19:00` | Closing time |
| Status | `ACTIVE` | DRAFT, ACTIVE, CLOSED, CERTIFIED |

**Status workflow:** DRAFT → ACTIVE → CLOSED → CERTIFIED

### Current Data

The Elections tab shows two tables:
- **Elections** — All elections with ID, title, date, status, jurisdiction
- **Jurisdictions** — Full hierarchy with parent relationships

## Races & Candidates Tab

### Adding a Race

| Field | Example | Description |
|---|---|---|
| Race ID | `race-fl-governor` | Unique identifier |
| Election ID | `general-2026-11-03` | Which election this race belongs to |
| Title | `Governor of Florida` | Display title on ballot |
| Type | `STATE` | FEDERAL, STATE, COUNTY, MUNICIPAL |
| Jurisdiction | `US-FL` | Which jurisdiction |
| Display Order | `3` | Order on the ballot (1 = first) |
| Voting Rule | `CHOOSE_ONE` | CHOOSE_ONE, CHOOSE_N, RANKED_CHOICE |
| Write-in | `Yes` | Allow write-in candidates |

### Adding a Candidate

| Field | Example | Description |
|---|---|---|
| Race ID | `race-fl-governor` | Must match an existing race |
| Legal Full Name | `Patricia Ann Reeves` | Official legal name |
| Display Name | `Patricia Reeves` | Name shown on ballot |
| Party | `Democratic Party` | Party affiliation |
| Display Order | `1` | Order within the race |

The system automatically generates:
- `candidate_hash_salt` — Random 32-char hex salt
- `candidate_hash` — SHA-256 of (legal name + party + race ID)
- `row_integrity_hash` — Tamper-detection hash

### Current Data

Shows a table of all races with candidate counts. Candidates added through this interface immediately appear on the voting machine at `vote.badvolf.com`.

## Measures Tab

### Adding a Ballot Measure

| Field | Example | Description |
|---|---|---|
| Measure ID | `measure-fl-prop-1` | Unique identifier |
| Election ID | `general-2026-11-03` | Which election |
| Jurisdiction | `US-FL` | Which jurisdiction |
| Title | `Proposition 1: Infrastructure Bond` | Display title |
| Summary | Full text of the proposition | Shown to voters on ballot |
| Display Order | `6` | Order on ballot (after races) |

### Adding Options

Each measure needs at least two options (typically Yes/No):

| Field | Example | Description |
|---|---|---|
| Measure ID | `measure-fl-prop-1` | Must match existing measure |
| Option Name | `Yes` | Display text |
| Display Order | `1` | Order of options |

Add "Yes" as order 1 and "No" as order 2, or whatever options the measure requires.

## Workflow: Setting Up a Complete Election

1. **Create jurisdictions** (if not already present):
   - US (FEDERAL)
   - US-FL (STATE)
   - Any needed counties

2. **Create the election:**
   - Set status to DRAFT while building
   - Set polls open/close times

3. **Add races in display order:**
   - Federal races first (President, Senate)
   - State races (Governor, AG, etc.)
   - County/local races last

4. **Add candidates to each race:**
   - Include party affiliation
   - Set display order (often alphabetical or by party)

5. **Add ballot measures:**
   - Add the measure with full summary text
   - Add Yes/No options

6. **Change election status to ACTIVE:**
   - (Currently requires direct DB update — UI edit coming)

7. **Verify on voting machine:**
   - Go to `vote.badvolf.com`
   - Search for any voter
   - Confirm all races and candidates appear correctly

## Adding New Operators

Currently done via SQL:

```bash
docker exec -i sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration << 'SQL'
SET @salt = LEFT(SHA2(RAND(), 256), 32);
INSERT INTO card_operators (
    username, password_hash, password_salt,
    legal_first_name, legal_last_name, employee_id,
    title, department,
    email, phone, office_address, office_city, office_state, office_zip,
    access_level, jurisdiction_id, is_active,
    created_by, row_integrity_hash
) VALUES (
    'newuser',
    SHA2(CONCAT(@salt, 'ThePassword123'), 256),
    @salt,
    'First', 'Last', 'SV-EMP-0003',
    'Card Issuance Clerk', 'Elections Office',
    'user@example.gov', '(555) 555-0100',
    '123 Main St', 'City', 'FL', '33401',
    'OPERATOR', 'US-FL', TRUE,
    'admin001',
    SHA2(CONCAT('newuser', 'Last', 'SV-EMP-0003'), 256)
);
SQL
```

## Technical Details

### Stack

- **Runtime:** Python 3.12 (slim)
- **Image generation:** Pillow + qrcode
- **Database client:** mariadb CLI (via subprocess)
- **Web server:** Python http.server (built-in)
- **Authentication:** Salted SHA-256 password hashing
- **Sessions:** In-memory (resets on container restart)

### Docker

```yaml
sv-idcard:
  build: ./docker/sv-idcard
  ports: 18090:8090
  networks: sv-net-reg, sv-net-elec, sv-net-admin
  depends_on: db-registration, db-election
```

### Files

```
docker/sv-idcard/
├── Dockerfile          # Python 3.12-slim + Pillow + qrcode + mariadb-client
└── admin_portal.py     # Complete admin portal (622 lines)
```

### API Endpoints

All require authentication (session cookie).

| Method | Path | Description |
|---|---|---|
| GET | `/admin` | Login page |
| POST | `/admin/login` | Authenticate |
| GET | `/admin/app` | Main application |
| GET | `/admin/logout` | End session |
| GET | `/admin/api/stats` | Dashboard statistics |
| GET | `/admin/api/card/search?q=` | Search voters |
| GET | `/admin/api/card/generate?voter_id=&format=` | Generate ID card |
| GET | `/admin/api/card/log` | Recent issuance log |
| GET | `/admin/api/jurisdiction/list` | List jurisdictions |
| POST | `/admin/api/jurisdiction/add` | Create jurisdiction |
| GET | `/admin/api/election/list` | List elections |
| POST | `/admin/api/election/add` | Create election |
| GET | `/admin/api/race/list` | List races with candidate counts |
| POST | `/admin/api/race/add` | Create race |
| POST | `/admin/api/candidate/add` | Add candidate to race |
| GET | `/admin/api/measure/list` | List ballot measures |
| POST | `/admin/api/measure/add` | Create ballot measure |
| POST | `/admin/api/measure/add-option` | Add option to measure |
