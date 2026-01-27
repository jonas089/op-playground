#!/usr/bin/env bash
set -euo pipefail

# Submit a new state root to the DisputeGameFactory on L1.
# Creates a new FaultDisputeGame with the output root from the L2 op-node.
#
# Usage:
#   ./scripts/submit-state-root.sh            # uses latest safe L2 block
#   ./scripts/submit-state-root.sh <block>    # uses specific L2 block number

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_JSON="$ROOT_DIR/deployer/.deployer/state.json"

# Load env
if [ -f "$ROOT_DIR/.env" ]; then
    set -a; source "$ROOT_DIR/.env"; set +a
fi

L1_RPC="${L1_RPC_URL:?L1_RPC_URL not set}"
# For PermissionedDisputeGame (type 1), must use the proposer's private key.
# Falls back to PRIVATE_KEY if PROPOSER_PRIVATE_KEY is not set.
PROPOSER_KEY_FILE="$ROOT_DIR/deployer/addresses/proposer_private_key.txt"
if [ -f "$PROPOSER_KEY_FILE" ]; then
    PK=$(cat "$PROPOSER_KEY_FILE" | sed 's/^0x//')
else
    PK="${PRIVATE_KEY:?PRIVATE_KEY not set}"
fi
OP_NODE_RPC="${OP_NODE_RPC:-http://localhost:9545}"

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
echo "Op-node RPC: $OP_NODE_RPC"
echo ""

# Determine L2 block number
if [ -n "${1:-}" ]; then
    L2_BLOCK="$1"
    echo "Using specified L2 block: $L2_BLOCK"
else
    # Get the latest safe head from op-node
    SYNC_STATUS=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
        "$OP_NODE_RPC")
    L2_BLOCK=$(echo "$SYNC_STATUS" | jq -r '.result.safe_l2.number')
    if [ -z "$L2_BLOCK" ] || [ "$L2_BLOCK" = "null" ] || [ "$L2_BLOCK" = "0" ]; then
        # Safe head may be 0 if L1 hasn't finalized yet; fall back to unsafe head
        L2_BLOCK=$(echo "$SYNC_STATUS" | jq -r '.result.unsafe_l2.number')
        if [ -z "$L2_BLOCK" ] || [ "$L2_BLOCK" = "null" ] || [ "$L2_BLOCK" = "0" ]; then
            echo "Error: No L2 blocks available yet." >&2
            exit 1
        fi
        echo "Using latest unsafe L2 block (safe head not yet available): $L2_BLOCK"
    else
        echo "Using latest safe L2 block: $L2_BLOCK"
    fi
fi

# Get the output root at this block from op-node
echo "Fetching output root for block $L2_BLOCK..."
OUTPUT_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_outputAtBlock\",\"params\":[\"$(printf '0x%x' "$L2_BLOCK")\"],\"id\":1}" \
    "$OP_NODE_RPC")

OUTPUT_ROOT=$(echo "$OUTPUT_RESPONSE" | jq -r '.result.outputRoot')
if [ -z "$OUTPUT_ROOT" ] || [ "$OUTPUT_ROOT" = "null" ]; then
    echo "Error: Could not get output root from op-node." >&2
    echo "Response: $OUTPUT_RESPONSE" >&2
    exit 1
fi

echo "Output root: $OUTPUT_ROOT"
echo ""

# Encode extraData as the L2 block number (abi-encoded uint256)
EXTRA_DATA=$(cast abi-encode "f(uint256)" "$L2_BLOCK")

# Determine available game type from factory
# Type 1 = PermissionedDisputeGame (default for new deployments)
# Type 0 = FaultDisputeGame (cannon, requires prestate setup)
GAME_TYPE="${GAME_TYPE:-1}"

# Verify the game type has an implementation
IMPL=$(cast call "$FACTORY" "gameImpls(uint32)(address)" "$GAME_TYPE" --rpc-url "$L1_RPC")
if [ "$IMPL" = "0x0000000000000000000000000000000000000000" ]; then
    echo "Error: Game type $GAME_TYPE has no implementation in the factory." >&2
    echo "Checking available game types..." >&2
    for t in 0 1 2 255; do
        IMPL_CHECK=$(cast call "$FACTORY" "gameImpls(uint32)(address)" "$t" --rpc-url "$L1_RPC")
        if [ "$IMPL_CHECK" != "0x0000000000000000000000000000000000000000" ]; then
            echo "  Game type $t: $IMPL_CHECK" >&2
        fi
    done
    exit 1
fi

echo "Submitting state root to DisputeGameFactory..."
echo "  Game type:  $GAME_TYPE"
echo "  Root claim: $OUTPUT_ROOT"
echo "  L2 block:   $L2_BLOCK"
echo ""

# Call create(gameType, rootClaim, extraData) on the factory
TX_HASH=$(cast send "$FACTORY" \
    "create(uint32,bytes32,bytes)(address)" \
    "$GAME_TYPE" "$OUTPUT_ROOT" "$EXTRA_DATA" \
    --private-key "$PK" \
    --rpc-url "$L1_RPC" \
    --json | jq -r '.transactionHash')

echo "Transaction submitted: $TX_HASH"
echo ""

# Verify the game count increased
NEW_COUNT=$(cast call "$FACTORY" "gameCount()(uint256)" --rpc-url "$L1_RPC")
echo "Total games after submission: $NEW_COUNT"
echo ""
echo "State root submitted successfully."
echo "Run ./scripts/get-latest-state-root.sh to verify."
