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
