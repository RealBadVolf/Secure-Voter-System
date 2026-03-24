#!/usr/bin/env bash
# ============================================================================
# SecureVote Docker Environment Setup
# ============================================================================
#
# Creates the full SecureVote development and demo environment:
#   - 3 MariaDB instances (registration, election, votes) on isolated networks
#   - 1 read-only MariaDB replica (votes-readonly, simulates Zone 5)
#   - sv-admin service (election administration API)
#   - sv-verify service (public verification portal)
#   - sv-tabulator service (runs on demand, air-gap simulated)
#   - sv-machine-sim service (voting machine simulator for demos)
#   - nginx reverse proxy (public-facing, routes to sv-verify)
#   - Adminer (database UI for development only)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#   cd /Dockers/SecureVote
#   docker compose up -d
#
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[SecureVote]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }

BASE="/Dockers/SecureVote"

log "SecureVote Docker Environment Setup"
log "Target: ${BASE}"
echo ""

# ============================================================================
# Directory Structure
# ============================================================================
log "Creating directory structure..."

mkdir -p "${BASE}/docker/db-registration" "${BASE}/docker/db-election" "${BASE}/docker/db-votes" "${BASE}/docker/db-votes-readonly"
mkdir -p "${BASE}/docker/sv-admin" "${BASE}/docker/sv-verify" "${BASE}/docker/sv-tabulator" "${BASE}/docker/sv-machine-sim" "${BASE}/docker/nginx"
mkdir -p "${BASE}/src/cmd/sv-machine" "${BASE}/src/cmd/sv-tabulator" "${BASE}/src/cmd/sv-admin" "${BASE}/src/cmd/sv-verify"
mkdir -p "${BASE}/src/internal/crypto" "${BASE}/src/internal/machine" "${BASE}/src/internal/merkle" "${BASE}/src/internal/auth"
mkdir -p "${BASE}/src/internal/ballot" "${BASE}/src/internal/recorder" "${BASE}/src/internal/db" "${BASE}/src/internal/config"
mkdir -p "${BASE}/src/internal/audit" "${BASE}/src/internal/verify"
mkdir -p "${BASE}/src/pkg/models" "${BASE}/src/pkg/protocol" "${BASE}/src/pkg/testutil"
mkdir -p "${BASE}/migrations/registration" "${BASE}/migrations/election" "${BASE}/migrations/votes"
mkdir -p "${BASE}/configs" "${BASE}/scripts"
mkdir -p "${BASE}/data/registration" "${BASE}/data/election" "${BASE}/data/votes" "${BASE}/data/votes-readonly" "${BASE}/data/exports"
mkdir -p "${BASE}/logs/nginx" "${BASE}/certs"

ok "Directory structure created"

# ============================================================================
# Docker Compose
# ============================================================================
log "Writing docker-compose.yml..."

cat > "${BASE}/docker-compose.yml" << 'COMPOSE_EOF'
# ============================================================================
# SecureVote — Docker Compose
# ============================================================================
#
# Architecture:
#   Network "sv-net-reg"     → db-registration (isolated)
#   Network "sv-net-elec"    → db-election (isolated)
#   Network "sv-net-votes"   → db-votes, db-votes-readonly (isolated)
#   Network "sv-net-admin"   → sv-admin ↔ db-registration, db-election
#   Network "sv-net-verify"  → sv-verify ↔ db-votes-readonly
#   Network "sv-net-public"  → nginx ↔ sv-verify (internet-facing)
#   Network "sv-net-machine" → sv-machine-sim ↔ db-registration, db-election, db-votes
#
# No service touches more than the databases it needs.
# ============================================================================

services:

  # --------------------------------------------------------------------------
  # DATABASE TIER — Three isolated MariaDB instances
  # --------------------------------------------------------------------------

  db-registration:
    build:
      context: ./docker/db-registration
    container_name: sv-db-registration
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_REG_ROOT_PW:-sv-reg-root-2026}
      MARIADB_DATABASE: securevote_registration
      MARIADB_USER: sv_reg_user
      MARIADB_PASSWORD: ${DB_REG_PW:-sv-reg-pw-2026}
    volumes:
      - ./data/registration:/var/lib/mysql
      - ./migrations/registration:/docker-entrypoint-initdb.d:ro
    ports:
      - "13306:3306"
    networks:
      - sv-net-reg
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_REG_ROOT_PW:-sv-reg-root-2026}"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  db-election:
    build:
      context: ./docker/db-election
    container_name: sv-db-election
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ELEC_ROOT_PW:-sv-elec-root-2026}
      MARIADB_DATABASE: securevote_election
      MARIADB_USER: sv_elec_user
      MARIADB_PASSWORD: ${DB_ELEC_PW:-sv-elec-pw-2026}
    volumes:
      - ./data/election:/var/lib/mysql
      - ./migrations/election:/docker-entrypoint-initdb.d:ro
    ports:
      - "13307:3306"
    networks:
      - sv-net-elec
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ELEC_ROOT_PW:-sv-elec-root-2026}"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  db-votes:
    build:
      context: ./docker/db-votes
    container_name: sv-db-votes
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_VOTES_ROOT_PW:-sv-votes-root-2026}
      MARIADB_DATABASE: securevote_votes
      MARIADB_USER: sv_votes_user
      MARIADB_PASSWORD: ${DB_VOTES_PW:-sv-votes-pw-2026}
    volumes:
      - ./data/votes:/var/lib/mysql
      - ./migrations/votes:/docker-entrypoint-initdb.d:ro
    ports:
      - "13308:3306"
    networks:
      - sv-net-votes
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_VOTES_ROOT_PW:-sv-votes-root-2026}"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  db-votes-readonly:
    build:
      context: ./docker/db-votes-readonly
    container_name: sv-db-votes-readonly
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_RO_ROOT_PW:-sv-ro-root-2026}
      MARIADB_DATABASE: securevote_votes
      MARIADB_USER: sv_verify_user
      MARIADB_PASSWORD: ${DB_RO_PW:-sv-ro-pw-2026}
    volumes:
      - ./data/votes-readonly:/var/lib/mysql
      - ./migrations/votes:/docker-entrypoint-initdb.d:ro
    ports:
      - "13309:3306"
    networks:
      - sv-net-votes-ro
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_RO_ROOT_PW:-sv-ro-root-2026}"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  # --------------------------------------------------------------------------
  # APPLICATION TIER
  # --------------------------------------------------------------------------

  sv-admin:
    build:
      context: .
      dockerfile: docker/sv-admin/Dockerfile
    container_name: sv-admin
    depends_on:
      db-registration:
        condition: service_healthy
      db-election:
        condition: service_healthy
    environment:
      SV_DB_REG_HOST: db-registration
      SV_DB_REG_PORT: 3306
      SV_DB_REG_USER: sv_reg_user
      SV_DB_REG_PASS: ${DB_REG_PW:-sv-reg-pw-2026}
      SV_DB_REG_NAME: securevote_registration
      SV_DB_ELEC_HOST: db-election
      SV_DB_ELEC_PORT: 3306
      SV_DB_ELEC_USER: sv_elec_user
      SV_DB_ELEC_PASS: ${DB_ELEC_PW:-sv-elec-pw-2026}
      SV_DB_ELEC_NAME: securevote_election
      SV_ADMIN_ADDR: ":9443"
    ports:
      - "9443:9443"
    networks:
      - sv-net-reg
      - sv-net-elec
      - sv-net-admin
    volumes:
      - ./logs:/app/logs
      - ./configs:/app/configs:ro
    restart: unless-stopped

  sv-verify:
    build:
      context: .
      dockerfile: docker/sv-verify/Dockerfile
    container_name: sv-verify
    depends_on:
      db-votes-readonly:
        condition: service_healthy
    environment:
      SV_DB_VOTES_HOST: db-votes-readonly
      SV_DB_VOTES_PORT: 3306
      SV_DB_VOTES_USER: sv_verify_user
      SV_DB_VOTES_PASS: ${DB_RO_PW:-sv-ro-pw-2026}
      SV_DB_VOTES_NAME: securevote_votes
      SV_VERIFY_ADDR: ":8443"
    ports:
      - "8443:8443"
    networks:
      - sv-net-votes-ro
      - sv-net-public
    volumes:
      - ./logs:/app/logs
    restart: unless-stopped

  sv-machine-sim:
    build:
      context: .
      dockerfile: docker/sv-machine-sim/Dockerfile
    container_name: sv-machine-sim
    depends_on:
      db-registration:
        condition: service_healthy
      db-election:
        condition: service_healthy
      db-votes:
        condition: service_healthy
    environment:
      SV_DB_REG_HOST: db-registration
      SV_DB_REG_PORT: 3306
      SV_DB_REG_USER: sv_reg_user
      SV_DB_REG_PASS: ${DB_REG_PW:-sv-reg-pw-2026}
      SV_DB_REG_NAME: securevote_registration
      SV_DB_ELEC_HOST: db-election
      SV_DB_ELEC_PORT: 3306
      SV_DB_ELEC_USER: sv_elec_user
      SV_DB_ELEC_PASS: ${DB_ELEC_PW:-sv-elec-pw-2026}
      SV_DB_ELEC_NAME: securevote_election
      SV_DB_VOTES_HOST: db-votes
      SV_DB_VOTES_PORT: 3306
      SV_DB_VOTES_USER: sv_votes_user
      SV_DB_VOTES_PASS: ${DB_VOTES_PW:-sv-votes-pw-2026}
      SV_DB_VOTES_NAME: securevote_votes
      SV_SIM_ADDR: ":8080"
    ports:
      - "8080:8080"
    networks:
      - sv-net-reg
      - sv-net-elec
      - sv-net-votes
      - sv-net-machine
    volumes:
      - ./logs:/app/logs
    restart: unless-stopped

  sv-tabulator:
    build:
      context: .
      dockerfile: docker/sv-tabulator/Dockerfile
    container_name: sv-tabulator
    depends_on:
      db-votes:
        condition: service_healthy
      db-election:
        condition: service_healthy
    environment:
      SV_DB_VOTES_HOST: db-votes
      SV_DB_VOTES_PORT: 3306
      SV_DB_VOTES_USER: sv_votes_user
      SV_DB_VOTES_PASS: ${DB_VOTES_PW:-sv-votes-pw-2026}
      SV_DB_VOTES_NAME: securevote_votes
      SV_DB_ELEC_HOST: db-election
      SV_DB_ELEC_PORT: 3306
      SV_DB_ELEC_USER: sv_elec_user
      SV_DB_ELEC_PASS: ${DB_ELEC_PW:-sv-elec-pw-2026}
      SV_DB_ELEC_NAME: securevote_election
    networks:
      - sv-net-votes
      - sv-net-elec
    volumes:
      - ./data/exports:/app/exports
      - ./logs:/app/logs
    # No restart — tabulator runs on demand, not as a daemon
    # Use: docker compose run sv-tabulator tabulate --election=general-2026
    profiles:
      - tabulator
    command: ["echo", "Tabulator ready. Run with: docker compose run sv-tabulator <command>"]

  # --------------------------------------------------------------------------
  # REVERSE PROXY — Public-facing (simulates Zone 5 boundary)
  # --------------------------------------------------------------------------

  nginx:
    build:
      context: ./docker/nginx
    container_name: sv-nginx
    depends_on:
      - sv-verify
    ports:
      - "443:443"
      - "80:80"
    networks:
      - sv-net-public
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./logs/nginx:/var/log/nginx
    restart: unless-stopped

  # --------------------------------------------------------------------------
  # DEV TOOLS (optional, not started by default)
  # --------------------------------------------------------------------------

  adminer:
    image: adminer:latest
    container_name: sv-adminer
    ports:
      - "8888:8080"
    networks:
      - sv-net-reg
      - sv-net-elec
      - sv-net-votes
      - sv-net-votes-ro
    profiles:
      - dev
    restart: unless-stopped

# ============================================================================
# NETWORKS — Isolated per security zone
# ============================================================================

networks:
  sv-net-reg:
    name: sv-net-reg
    driver: bridge
    internal: true  # No external access

  sv-net-elec:
    name: sv-net-elec
    driver: bridge
    internal: true

  sv-net-votes:
    name: sv-net-votes
    driver: bridge
    internal: true

  sv-net-votes-ro:
    name: sv-net-votes-ro
    driver: bridge
    internal: true

  sv-net-admin:
    name: sv-net-admin
    driver: bridge

  sv-net-machine:
    name: sv-net-machine
    driver: bridge

  sv-net-public:
    name: sv-net-public
    driver: bridge
COMPOSE_EOF

ok "docker-compose.yml"

# ============================================================================
# Environment File
# ============================================================================
log "Writing .env..."

cat > "${BASE}/.env" << 'ENV_EOF'
# ============================================================================
# SecureVote Environment Variables
# ============================================================================
# CHANGE THESE IN PRODUCTION. These are development defaults.
# ============================================================================

# Database passwords (one per isolated instance)
DB_REG_ROOT_PW=sv-reg-root-2026
DB_REG_PW=sv-reg-pw-2026

DB_ELEC_ROOT_PW=sv-elec-root-2026
DB_ELEC_PW=sv-elec-pw-2026

DB_VOTES_ROOT_PW=sv-votes-root-2026
DB_VOTES_PW=sv-votes-pw-2026

DB_RO_ROOT_PW=sv-ro-root-2026
DB_RO_PW=sv-ro-pw-2026

# Service configuration
SV_LOG_LEVEL=info
SV_ENVIRONMENT=development
ENV_EOF

ok ".env"

# ============================================================================
# Database Dockerfiles (all identical base, different init)
# ============================================================================
log "Writing database Dockerfiles..."

for db in db-registration db-election db-votes db-votes-readonly; do
cat > "${BASE}/docker/${db}/Dockerfile" << 'DB_DOCKER_EOF'
FROM mariadb:11.4

# Harden: remove test database, set character set
RUN echo "[mysqld]\n\
character-set-server=utf8mb4\n\
collation-server=utf8mb4_unicode_ci\n\
innodb_file_per_table=1\n\
innodb_flush_log_at_trx_commit=1\n\
max_connections=100\n\
log_error=/var/log/mysql/error.log\n\
general_log=0\n\
slow_query_log=1\n\
slow_query_log_file=/var/log/mysql/slow.log\n\
long_query_time=2\n\
" > /etc/mysql/conf.d/securevote.cnf

RUN mkdir -p /var/log/mysql && chown mysql:mysql /var/log/mysql

EXPOSE 3306
DB_DOCKER_EOF
ok "  ${db}/Dockerfile"
done

# Add readonly grants init script for votes-readonly
cat > "${BASE}/docker/db-votes-readonly/init-readonly.sql" << 'RO_SQL_EOF'
-- Applied after schema init. Restricts sv_verify_user to SELECT-only.
-- This simulates the Zone 5 read-only replica access controls.

USE securevote_votes;
REVOKE ALL PRIVILEGES ON securevote_votes.* FROM 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.vote_casts TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_trees TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_nodes TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_hierarchy TO 'sv_verify_user'@'%';
GRANT SELECT, INSERT ON securevote_votes.verification_attempts TO 'sv_verify_user'@'%';
FLUSH PRIVILEGES;
RO_SQL_EOF

# Append the readonly init to the votes-readonly Dockerfile
cat >> "${BASE}/docker/db-votes-readonly/Dockerfile" << 'APPEND_EOF'

COPY init-readonly.sql /docker-entrypoint-initdb.d/99_readonly_grants.sql
APPEND_EOF

ok "  db-votes-readonly grants"

# ============================================================================
# Go Service Dockerfiles (multi-stage builds)
# ============================================================================
log "Writing service Dockerfiles..."

# --- Base Go builder (shared) ---
cat > "${BASE}/docker/go-builder.dockerfile" << 'GO_BUILDER_EOF'
# Shared multi-stage builder for all Go services
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /build
COPY src/go.mod src/go.sum ./
RUN go mod download

COPY src/ ./

ARG SERVICE_NAME
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG BUILD_TIME=unknown

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w -X main.version=${BUILD_VERSION} -X main.commitSHA=${BUILD_COMMIT} -X main.buildTime=${BUILD_TIME}" \
    -o /app/service ./cmd/${SERVICE_NAME}/
GO_BUILDER_EOF

# --- sv-admin ---
cat > "${BASE}/docker/sv-admin/Dockerfile" << 'ADMIN_DOCKER_EOF'
# ============================================================================
# sv-admin — Election Administration Service
# ============================================================================
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /build
COPY src/go.mod src/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY src/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w" \
    -o /app/sv-admin ./cmd/sv-admin/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svadmin
COPY --from=builder /app/sv-admin /usr/local/bin/sv-admin
USER svadmin
WORKDIR /app
EXPOSE 9443
ENTRYPOINT ["sv-admin"]
CMD ["--config=/app/configs/admin.toml"]
ADMIN_DOCKER_EOF
ok "  sv-admin/Dockerfile"

# --- sv-verify ---
cat > "${BASE}/docker/sv-verify/Dockerfile" << 'VERIFY_DOCKER_EOF'
# ============================================================================
# sv-verify — Public Verification Portal
# ============================================================================
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /build
COPY src/go.mod src/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY src/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w" \
    -o /app/sv-verify ./cmd/sv-verify/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svverify
COPY --from=builder /app/sv-verify /usr/local/bin/sv-verify
USER svverify
WORKDIR /app
EXPOSE 8443
ENTRYPOINT ["sv-verify"]
CMD ["--config=/app/configs/verify.toml"]
VERIFY_DOCKER_EOF
ok "  sv-verify/Dockerfile"

# --- sv-tabulator ---
cat > "${BASE}/docker/sv-tabulator/Dockerfile" << 'TAB_DOCKER_EOF'
# ============================================================================
# sv-tabulator — Air-Gapped Tabulation Service (CLI)
# ============================================================================
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /build
COPY src/go.mod src/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY src/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w" \
    -o /app/sv-tabulator ./cmd/sv-tabulator/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svtab
COPY --from=builder /app/sv-tabulator /usr/local/bin/sv-tabulator
USER svtab
WORKDIR /app
ENTRYPOINT ["sv-tabulator"]
TAB_DOCKER_EOF
ok "  sv-tabulator/Dockerfile"

# --- sv-machine-sim (voting machine simulator — web UI for demos) ---
cat > "${BASE}/docker/sv-machine-sim/Dockerfile" << 'SIM_DOCKER_EOF'
# ============================================================================
# sv-machine-sim — Voting Machine Simulator (Demo/Dev)
# ============================================================================
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata
WORKDIR /build
COPY src/go.mod src/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY src/ ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w" \
    -o /app/sv-machine-sim ./cmd/sv-machine/

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 svmachine
COPY --from=builder /app/sv-machine-sim /usr/local/bin/sv-machine-sim
USER svmachine
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["sv-machine-sim"]
CMD ["--config=/app/configs/machine.toml"]
SIM_DOCKER_EOF
ok "  sv-machine-sim/Dockerfile"

# ============================================================================
# Nginx Configuration
# ============================================================================
log "Writing nginx configuration..."

cat > "${BASE}/docker/nginx/Dockerfile" << 'NGINX_DOCKER_EOF'
FROM nginx:1.26-alpine

RUN apk add --no-cache openssl

# Generate self-signed cert for development
RUN mkdir -p /etc/nginx/certs && \
    openssl req -x509 -nodes -days 365 \
    -subj "/C=US/ST=FL/O=SecureVote/CN=securevote.local" \
    -newkey rsa:2048 \
    -keyout /etc/nginx/certs/dev.key \
    -out /etc/nginx/certs/dev.crt

COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80 443
NGINX_DOCKER_EOF

cat > "${BASE}/docker/nginx/nginx.conf" << 'NGINX_CONF_EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/json;

    # Security headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Logging
    log_format securevote '$remote_addr - $remote_user [$time_local] '
                          '"$request" $status $body_bytes_sent '
                          '"$http_referer" "$http_user_agent" '
                          'rt=$request_time';
    access_log /var/log/nginx/access.log securevote;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=verify_api:10m rate=10r/m;
    limit_req_zone $binary_remote_addr zone=general:10m rate=30r/m;

    # Timeouts
    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 10s;
    keepalive_timeout 60s;

    # Max body size (no file uploads on verify)
    client_max_body_size 1k;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF_EOF

cat > "${BASE}/docker/nginx/default.conf" << 'NGINX_DEFAULT_EOF'
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

# HTTPS — Public Verification Portal
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/certs/dev.crt;
    ssl_certificate_key /etc/nginx/certs/dev.key;
    ssl_protocols       TLSv1.3;
    ssl_ciphers         TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256;

    # Health check (no rate limit)
    location /api/v1/health {
        proxy_pass http://sv-verify:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Verification API (strict rate limiting)
    location /api/v1/verify {
        limit_req zone=verify_api burst=5 nodelay;
        limit_req_status 429;

        proxy_pass http://sv-verify:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Public Merkle roots and BDF hashes (moderate rate limiting)
    location /api/v1/election/ {
        limit_req zone=general burst=10 nodelay;

        proxy_pass http://sv-verify:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Block everything else
    location / {
        return 404 '{"error":"not_found","message":"SecureVote Verification Portal. Use /api/v1/verify"}';
    }
}
NGINX_DEFAULT_EOF
ok "  nginx config"

# ============================================================================
# Go Module and Source Stubs
# ============================================================================
log "Writing Go source files..."

cat > "${BASE}/src/go.mod" << 'GOMOD_EOF'
module github.com/securevote/securevote

go 1.22.0

require (
	github.com/go-sql-driver/mysql v1.8.1
	github.com/google/uuid v1.6.0
	golang.org/x/crypto v0.24.0
)

require filippo.io/edwards25519 v1.1.0 // indirect
GOMOD_EOF

cat > "${BASE}/src/go.sum" << 'GOSUM_EOF'
filippo.io/edwards25519 v1.1.0 h1:FNf4A+zCnkMDiMGHOuKBBjnHHrP+HLSKTf9aoGIvUCY=
filippo.io/edwards25519 v1.1.0/go.mod h1:BxyFTGdWcka3PhytdK4V28tE5sGfRvvvRV7EaN4VDT4=
github.com/go-sql-driver/mysql v1.8.1 h1:LedoTUt/eAbIkAH0z+czuR1cQ09QFzKXgfnwkMYNb9s=
github.com/go-sql-driver/mysql v1.8.1/go.mod h1:wEBSXgmK//2ZFJyE+qWnIsVGmvmEKlqwuVSjsCm7DZg=
github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
golang.org/x/crypto v0.24.0 h1:mnl8DM0o513X8fdIkmyFE/5hTYxbwYOjDS/5gHBrd9s=
golang.org/x/crypto v0.24.0/go.mod h1:Z1PMYSOR5nyMcyAVAIQSKCDwalqy85Aqn1x3Ws4L5DM=
GOSUM_EOF

ok "  go.mod + go.sum"

# ============================================================================
# Configs
# ============================================================================
log "Writing config files..."

cat > "${BASE}/configs/admin.toml" << 'ADMIN_TOML_EOF'
[server]
addr = ":9443"

[logging]
level = "info"
format = "json"

[database.registration]
host = "db-registration"
port = 3306
user = "sv_reg_user"
name = "securevote_registration"

[database.election]
host = "db-election"
port = 3306
user = "sv_elec_user"
name = "securevote_election"
ADMIN_TOML_EOF

cat > "${BASE}/configs/verify.toml" << 'VERIFY_TOML_EOF'
[server]
addr = ":8443"

[logging]
level = "info"
format = "json"

[database.votes]
host = "db-votes-readonly"
port = 3306
user = "sv_verify_user"
name = "securevote_votes"

[ratelimit]
requests_per_ip_per_hour = 10
pin_lockout_after_failures = 3
pin_lockout_duration_hours = 24
VERIFY_TOML_EOF

cat > "${BASE}/configs/machine.toml" << 'MACHINE_TOML_EOF'
[server]
addr = ":8080"

[machine]
id = "SIM-0001"
precinct = "1042"
election = "general-2026"

[biometric]
auto_approve_threshold = 0.92
manual_review_threshold = 0.80

[session]
ballot_timeout_minutes = 15
max_spoil_attempts = 3
presence_lost_seconds = 10

[logging]
level = "debug"
format = "json"
MACHINE_TOML_EOF
ok "  config files"

# ============================================================================
# Management Scripts
# ============================================================================
log "Writing management scripts..."

cat > "${BASE}/scripts/start.sh" << 'START_EOF'
#!/usr/bin/env bash
# Start the full SecureVote stack
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Starting SecureVote..."
docker compose up -d

echo ""
echo "Waiting for databases..."
sleep 10

echo ""
echo "==================================="
echo " SecureVote is running"
echo "==================================="
echo ""
echo " Services:"
echo "   sv-admin        → https://localhost:9443"
echo "   sv-verify       → https://localhost:443"
echo "   sv-machine-sim  → http://localhost:8080"
echo ""
echo " Databases:"
echo "   registration    → localhost:13306"
echo "   election        → localhost:13307"
echo "   votes           → localhost:13308"
echo "   votes-readonly  → localhost:13309"
echo ""
echo " Management:"
echo "   Logs      → docker compose logs -f"
echo "   Stop      → docker compose down"
echo "   Reset DBs → ./scripts/reset-data.sh"
echo "   Tabulate  → docker compose run --rm sv-tabulator tabulate"
echo "   Dev tools → docker compose --profile dev up -d"
echo "   Adminer   → http://localhost:8888 (dev profile)"
echo ""
START_EOF
chmod +x "${BASE}/scripts/start.sh"

cat > "${BASE}/scripts/stop.sh" << 'STOP_EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/.."
echo "Stopping SecureVote..."
docker compose down
echo "Done."
STOP_EOF
chmod +x "${BASE}/scripts/stop.sh"

cat > "${BASE}/scripts/reset-data.sh" << 'RESET_EOF'
#!/usr/bin/env bash
# WARNING: This destroys all data and recreates databases from scratch
set -euo pipefail
cd "$(dirname "$0")/.."

echo "⚠ This will DELETE all SecureVote data. Press Ctrl+C to cancel."
read -p "Type 'RESET' to confirm: " confirm
if [ "$confirm" != "RESET" ]; then
    echo "Cancelled."
    exit 1
fi

echo "Stopping containers..."
docker compose down -v

echo "Removing data..."
rm -rf data/registration/* data/election/* data/votes/* data/votes-readonly/*

echo "Rebuilding..."
docker compose up -d

echo "Done. Databases have been reset."
RESET_EOF
chmod +x "${BASE}/scripts/reset-data.sh"

cat > "${BASE}/scripts/run-tests.sh" << 'TEST_EOF'
#!/usr/bin/env bash
# Run the integration test suite against the Docker environment
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Running SecureVote test suite..."

# Ensure test DBs are up
docker compose up -d db-registration db-election db-votes db-votes-readonly
sleep 10

# Run tests
cd src
SV_INTEGRATION_TESTS=1 \
  SV_DB_REG_PORT=13306 \
  SV_DB_ELEC_PORT=13307 \
  SV_DB_VOTES_PORT=13308 \
  SV_DB_RO_PORT=13309 \
  go test -race -count=1 -timeout=300s ./...

echo ""
echo "All tests passed."
TEST_EOF
chmod +x "${BASE}/scripts/run-tests.sh"

cat > "${BASE}/scripts/tabulate.sh" << 'TAB_SCRIPT_EOF'
#!/usr/bin/env bash
# Run the tabulator (simulates the air-gapped tabulation process)
set -euo pipefail
cd "$(dirname "$0")/.."

ELECTION="${1:-general-2026}"
echo "Running tabulation for election: ${ELECTION}"

docker compose run --rm sv-tabulator tabulate --election="${ELECTION}"

echo "Tabulation complete."
TAB_SCRIPT_EOF
chmod +x "${BASE}/scripts/tabulate.sh"

ok "  management scripts"

# ============================================================================
# .dockerignore and .gitignore
# ============================================================================
log "Writing ignore files..."

cat > "${BASE}/.dockerignore" << 'DI_EOF'
data/
logs/
certs/
*.md
.git
.env.production
DI_EOF

cat > "${BASE}/.gitignore" << 'GI_EOF'
# Data volumes (never commit database data)
data/registration/*
data/election/*
data/votes/*
data/votes-readonly/*
data/exports/*
!data/*/.gitkeep

# Logs
logs/*
!logs/.gitkeep

# Certificates
certs/*
!certs/.gitkeep

# Environment (production secrets)
.env.production

# Go
src/vendor/
*.exe
*.dll
*.so
*.dylib

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db
GI_EOF

# Create .gitkeep files
touch "${BASE}/data/registration/.gitkeep"
touch "${BASE}/data/election/.gitkeep"
touch "${BASE}/data/votes/.gitkeep"
touch "${BASE}/data/votes-readonly/.gitkeep"
touch "${BASE}/data/exports/.gitkeep"
touch "${BASE}/logs/.gitkeep"
touch "${BASE}/logs/nginx/.gitkeep"
touch "${BASE}/certs/.gitkeep"

ok "  .dockerignore + .gitignore"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  SecureVote Docker environment created!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Location: ${BASE}"
echo ""
echo "  Next steps:"
echo ""
echo "    1. Copy your Go source into ${BASE}/src/"
echo "       (or extract securevote-full-src.tar.gz there)"
echo ""
echo "    2. Copy your SQL migrations into ${BASE}/migrations/"
echo "       ├── registration/001_initial.sql"
echo "       ├── election/001_initial.sql"
echo "       └── votes/001_initial.sql"
echo ""
echo "    3. Start everything:"
echo "       cd ${BASE}"
echo "       ./scripts/start.sh"
echo ""
echo "    4. Or manually:"
echo "       cd ${BASE}"
echo "       docker compose up -d"
echo ""
echo "  Services:"
echo "    sv-admin        → https://localhost:9443  (election admin API)"
echo "    sv-verify       → https://localhost:443   (public verification)"
echo "    sv-machine-sim  → http://localhost:8080   (voting machine demo)"
echo "    Adminer (dev)   → http://localhost:8888   (DB browser)"
echo ""
echo "  Networks (isolated):"
echo "    sv-net-reg       db-registration only"
echo "    sv-net-elec      db-election only"
echo "    sv-net-votes     db-votes only"
echo "    sv-net-votes-ro  db-votes-readonly (Zone 5 sim)"
echo "    sv-net-public    nginx ↔ sv-verify"
echo ""
echo "  Commands:"
echo "    ./scripts/start.sh          Start all services"
echo "    ./scripts/stop.sh           Stop all services"
echo "    ./scripts/reset-data.sh     Destroy and recreate databases"
echo "    ./scripts/run-tests.sh      Run integration tests"
echo "    ./scripts/tabulate.sh       Run tabulation"
echo "    docker compose logs -f      Tail all logs"
echo "    docker compose --profile dev up -d   Start with Adminer"
echo ""
