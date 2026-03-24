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
