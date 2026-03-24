#!/usr/bin/env bash
cd "$(dirname "$0")/.."
echo "Stopping SecureVote..."
docker compose down
echo "Done."
