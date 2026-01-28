#!/usr/bin/env bash
set -euo pipefail

# Stop all L2 services while keeping L1 running.
# Since L1 is an external network (Sepolia), this stops all Docker containers
# that make up the L2 rollup stack.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "Stopping L2 services..."

docker compose stop

echo ""
echo "All L2 services stopped."

if [ -f .env ]; then
    set -a; source .env; set +a
    echo "L1 (Sepolia) remains accessible at: $L1_RPC_URL"
fi

echo ""
echo "To restart L2: docker compose up -d"
