# SecureVote — Docker Deployment Guide

## Overview

SecureVote runs as a multi-container Docker stack with **10 services** across **7 isolated networks**, mirroring the production security architecture. No service can access a database it doesn't need.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        HOST MACHINE                               │
│                                                                    │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ sv-db-           │  │ sv-db-          │  │ sv-db-          │  │
│  │ registration     │  │ election        │  │ votes           │  │
│  │ (MariaDB 11.4)  │  │ (MariaDB 11.4)  │  │ (MariaDB 11.4)  │  │
│  │ Port: 13306     │  │ Port: 13307     │  │ Port: 13308     │  │
│  │ 6GB RAM, 8 CPU  │  │                 │  │                 │  │
│  │ sv-net-reg      │  │ sv-net-elec     │  │ sv-net-votes    │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
│           │                    │                    │              │
│  ┌────────┴────────────────────┴──────┐    ┌──────┴───────────┐  │
│  │ sv-machine-sim (Go)               │    │ sv-db-votes-     │  │
│  │ Voting Machine Simulator          │    │ readonly         │  │
│  │ Port: 18080                       │    │ Port: 13309      │  │
│  │ Networks: reg + elec + votes      │    │ sv-net-votes-ro  │  │
│  └───────────────────────────────────┘    └──────┬───────────┘  │
│                                                   │              │
│  ┌───────────────────────────────────┐    ┌──────┴───────────┐  │
│  │ sv-idcard (Python)                │    │ sv-verify (Go)   │  │
│  │ Admin Portal + Card Issuance      │    │ Verification API │  │
│  │ Port: 18090                       │    │ Port: 18443      │  │
│  │ Networks: reg + elec + admin      │    │ Networks: ro +   │  │
│  └───────────────────────────────────┘    │ public           │  │
│                                            └──────┬───────────┘  │
│  ┌───────────────────────────────────┐    ┌──────┴───────────┐  │
│  │ sv-admin (Go)                     │    │ sv-nginx         │  │
│  │ Election Admin API                │    │ Reverse Proxy    │  │
│  │ Port: 9443                        │    │ Ports: 10443,    │  │
│  │ Networks: reg + elec + admin      │    │ 10080            │  │
│  └───────────────────────────────────┘    │ sv-net-public    │  │
│                                            └──────────────────┘  │
│  ┌───────────────────────────────────┐                           │
│  │ sv-tabulator (Go) — on demand     │                           │
│  │ Networks: votes + elec            │                           │
│  └───────────────────────────────────┘                           │
└──────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
cd /Dockers/SecureVote
docker compose up -d
```

## Services

| Container | Image | Port | Purpose |
|---|---|---|---|
| `sv-db-registration` | MariaDB 11.4 | 13306 | Voter identity, IDs, biometrics, PINs, tokens |
| `sv-db-election` | MariaDB 11.4 | 13307 | Elections, races, candidates, BDFs |
| `sv-db-votes` | MariaDB 11.4 | 13308 | Cast ballots, Merkle trees, tabulation |
| `sv-db-votes-readonly` | MariaDB 11.4 | 13309 | Read-only replica for verification (Zone 5) |
| `sv-machine-sim` | Go | 18080 | Voting machine simulator with web UI |
| `sv-idcard` | Python | 18090 | Admin portal: card issuance + election management |
| `sv-admin` | Go | 9443 | Election administration API |
| `sv-verify` | Go | 18443 | Public vote verification API |
| `sv-nginx` | Nginx | 10443/10080 | Reverse proxy with TLS and rate limiting |
| `sv-tabulator` | Go | — | On-demand tabulation (not a daemon) |

## Networks (Isolated Security Zones)

| Network | Type | Connected Services |
|---|---|---|
| `sv-net-reg` | Internal (no external) | db-registration, sv-admin, sv-machine-sim, sv-idcard |
| `sv-net-elec` | Internal | db-election, sv-admin, sv-machine-sim, sv-idcard, sv-tabulator |
| `sv-net-votes` | Internal | db-votes, sv-machine-sim, sv-tabulator |
| `sv-net-votes-ro` | Internal | db-votes-readonly, sv-verify |
| `sv-net-admin` | Bridged | sv-admin, sv-idcard |
| `sv-net-machine` | Bridged | sv-machine-sim |
| `sv-net-public` | Bridged | sv-nginx, sv-verify |

**Key security property:** `sv-verify` can only reach the read-only votes database. It cannot access voter identity (registration) or election definition data.

## Database Connections

```bash
# Registration (17M voters)
mysql -h 127.0.0.1 -P 13306 -u sv_reg_user -psv-reg-pw-2026 securevote_registration

# Election
mysql -h 127.0.0.1 -P 13307 -u sv_elec_user -psv-elec-pw-2026 securevote_election

# Votes
mysql -h 127.0.0.1 -P 13308 -u sv_votes_user -psv-votes-pw-2026 securevote_votes

# Votes read-only (Zone 5 simulation)
mysql -h 127.0.0.1 -P 13309 -u sv_verify_user -psv-ro-pw-2026 securevote_votes
```

**Note:** Database networks are `internal: true`. Direct host connections use Docker's port mapping. If connections fail, use `docker exec` instead:

```bash
docker exec sv-db-registration mariadb -u sv_reg_user -psv-reg-pw-2026 securevote_registration -e "SELECT COUNT(*) FROM voters"
```

## Common Operations

### Start / Stop

```bash
# Start all services
docker compose up -d

# Stop all services (data is preserved)
docker compose down

# Restart a single service
docker compose restart sv-machine-sim

# Rebuild a service after code changes
docker compose build --no-cache sv-machine-sim
docker compose up -d sv-machine-sim
```

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f sv-idcard

# Last 50 lines
docker compose logs --tail 50 sv-machine-sim
```

### Run Tabulator (On-Demand)

```bash
docker compose run --rm sv-tabulator tabulate --election=general-2026-11-03
```

### Start Dev Tools (Adminer DB Browser)

```bash
docker compose --profile dev up -d
# Then open http://localhost:8888
```

### Rebuild Everything

```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

## Data Persistence

All database data is stored in `./data/` on the host machine:

```
data/
├── registration/    # 17M voters — DO NOT DELETE
├── election/        # Election definitions
├── votes/           # Cast ballots
├── votes-readonly/  # Read-only replica
└── exports/         # Tabulation exports
```

**CRITICAL:** Never run `docker compose down -v` or `rm -rf data/` unless you intend to destroy all data. A normal `docker compose down` preserves everything.

## Registration Database Tuning

The registration database is tuned for 17M rows with a custom MariaDB config at `docker/db-registration/securevote.cnf`:

| Setting | Value | Purpose |
|---|---|---|
| `innodb_buffer_pool_size` | 4GB | Cache indexes and hot data in RAM |
| `innodb_buffer_pool_instances` | 4 | Parallel buffer pool access |
| `innodb_log_file_size` | 512MB | Larger redo log for bulk operations |
| `join_buffer_size` | 256MB | Fast JOINs for voter search |
| `sort_buffer_size` | 64MB | Fast ORDER BY |

The container is limited to 6GB RAM and 8 CPUs via `deploy.resources.limits`.

## Importing Florida Voter Data

```bash
# Load raw SQL dumps into temp database
./scripts/import-florida.sh load /path/to/voters_voters.sql /path/to/voters_address.sql

# Import all counties (17M voters)
./scripts/import-florida.sh import ALL 99999999

# Clean up temp data
./scripts/import-florida.sh cleanup
```

Before bulk import, disable safety checks for speed:

```bash
docker exec sv-db-registration mariadb -u root -psv-reg-root-2026 -e "
SET GLOBAL innodb_flush_log_at_trx_commit=0;
SET GLOBAL sync_binlog=0;
SET GLOBAL foreign_key_checks=0;
SET GLOBAL unique_checks=0;
"
```

Re-enable after:

```bash
docker exec sv-db-registration mariadb -u root -psv-reg-root-2026 -e "
SET GLOBAL innodb_flush_log_at_trx_commit=2;
SET GLOBAL sync_binlog=1;
SET GLOBAL foreign_key_checks=1;
SET GLOBAL unique_checks=1;
"

docker exec sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration -e "
ANALYZE TABLE voters;
ANALYZE TABLE voter_id_documents;
ANALYZE TABLE voter_biometrics;
ANALYZE TABLE voter_election_pins;
"
```

## Nginx (Host-Level Reverse Proxy)

The host's nginx (not the Docker nginx) proxies `vote.badvolf.com`:

```
vote.badvolf.com/          → sv-machine-sim (port 18080)
vote.badvolf.com/admin     → sv-idcard admin portal (port 18090)
```

Config: `/etc/nginx/sites-available/vote.badvolf.com`

## SSL Certificates

Host-level SSL via Certbot:

```bash
certbot --nginx -d vote.badvolf.com
```

The Docker nginx container uses self-signed certs for internal traffic only.

## Troubleshooting

### Container won't start — port in use

```bash
# Find what's using the port
ss -tlnp | grep 18080
# Remap in docker-compose.yml: change "18080:8080" to "19080:8080"
```

### Database tables missing after rebuild

Tables are only created on first startup. If you wiped `data/`, the init scripts run again. If the SQL has errors (like the `CURDATE()` issue), tables stop being created silently. Check:

```bash
docker exec sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration -e "SHOW TABLES"
```

### Search is slow

Add indexes:

```bash
docker exec sv-db-registration mariadb -u root -psv-reg-root-2026 securevote_registration -e "
CREATE INDEX idx_first_name ON voters(legal_first_name);
ANALYZE TABLE voters;
"
```

### Container exits immediately

Check logs:

```bash
docker compose logs sv-idcard
docker exec -it sv-idcard python3 /app/admin_portal.py
```

## Environment Variables

All credentials are in `.env`:

```
DB_REG_ROOT_PW=sv-reg-root-2026
DB_REG_PW=sv-reg-pw-2026
DB_ELEC_ROOT_PW=sv-elec-root-2026
DB_ELEC_PW=sv-elec-pw-2026
DB_VOTES_ROOT_PW=sv-votes-root-2026
DB_VOTES_PW=sv-votes-pw-2026
DB_RO_ROOT_PW=sv-ro-root-2026
DB_RO_PW=sv-ro-pw-2026
```

**Change these for production.** The defaults are development-only.
