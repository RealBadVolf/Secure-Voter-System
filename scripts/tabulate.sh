#!/usr/bin/env bash
# Run the tabulator (simulates the air-gapped tabulation process)
set -euo pipefail
cd "$(dirname "$0")/.."

ELECTION="${1:-general-2026}"
echo "Running tabulation for election: ${ELECTION}"

docker compose run --rm sv-tabulator tabulate --election="${ELECTION}"

echo "Tabulation complete."
