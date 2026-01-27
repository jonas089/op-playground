#!/usr/bin/env bash
set -euo pipefail

# Get the latest state root from the DisputeGameFactory on L1.
# Reads the DisputeGameFactoryProxy address from deployer state.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_JSON="$ROOT_DIR/deployer/.deployer/state.json"

# Load env
if [ -f "$ROOT_DIR/.env" ]; then
    set -a; source "$ROOT_DIR/.env"; set +a
fi

L1_RPC="${L1_RPC_URL:?L1_RPC_URL not set}"

# Get factory address
if [ ! -f "$STATE_JSON" ]; then
    echo "Error: state.json not found. Run 'make setup' first." >&2
    exit 1
fi

FACTORY=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' "$STATE_JSON")
if [ -z "$FACTORY" ] || [ "$FACTORY" = "null" ]; then
    echo "Error: DisputeGameFactoryProxy not found in state.json." >&2
    exit 1
fi

echo "DisputeGameFactory: $FACTORY"
echo "L1 RPC: $L1_RPC"
echo ""

# Get total game count
GAME_COUNT=$(cast call "$FACTORY" "gameCount()(uint256)" --rpc-url "$L1_RPC")
echo "Total games: $GAME_COUNT"

if [ "$GAME_COUNT" -eq 0 ]; then
    echo ""
    echo "No state roots have been submitted yet."
    exit 0
fi

# Get the latest game (index = gameCount - 1)
LATEST_IDX=$((GAME_COUNT - 1))

# gameAtIndex returns (gameType, timestamp, proxy)
GAME_DATA=$(cast call "$FACTORY" "gameAtIndex(uint256)(uint32,uint64,address)" "$LATEST_IDX" --rpc-url "$L1_RPC")

# Parse output (cast returns space-separated values)
GAME_TYPE=$(echo "$GAME_DATA" | sed -n '1p')
TIMESTAMP=$(echo "$GAME_DATA" | sed -n '2p')
GAME_PROXY=$(echo "$GAME_DATA" | sed -n '3p')

echo ""
echo "Latest game (index $LATEST_IDX):"
echo "  Game type:  $GAME_TYPE"
echo "  Timestamp:  $TIMESTAMP"
echo "  Game proxy: $GAME_PROXY"

# Get the root claim (state root) from the game proxy
ROOT_CLAIM=$(cast call "$GAME_PROXY" "rootClaim()(bytes32)" --rpc-url "$L1_RPC")
echo "  Root claim: $ROOT_CLAIM"

# Get L2 block number from extraData
L2_BLOCK_HEX=$(cast call "$GAME_PROXY" "l2BlockNumber()(uint256)" --rpc-url "$L1_RPC")
echo "  L2 block:   $L2_BLOCK_HEX"

# Get game status: 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS
STATUS_RAW=$(cast call "$GAME_PROXY" "status()(uint8)" --rpc-url "$L1_RPC")
case "$STATUS_RAW" in
    0) STATUS_STR="IN_PROGRESS" ;;
    1) STATUS_STR="CHALLENGER_WINS" ;;
    2) STATUS_STR="DEFENDER_WINS" ;;
    *) STATUS_STR="UNKNOWN($STATUS_RAW)" ;;
esac
echo "  Status:     $STATUS_STR"
