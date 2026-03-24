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
