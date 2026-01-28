#!/bin/bash

# Helper script to check withdrawal proof status
# Usage: ./scripts/get-withdrawal-status.sh <nonce> <sender> <target> <value> <gas_limit>

set -e

if [ $# -lt 5 ]; then
    echo "Usage: $0 <nonce> <sender> <target> <value> <gas_limit>"
    echo ""
    echo "Example:"
    echo "  $0 1766847064778384329583297500742918515827483896875618958121606201292619777 \\"
    echo "      0xB0F557D10b9355F39977e8D5d7404Fb676425b3C \\"
    echo "      0xB0F557D10b9355F39977e8D5d7404Fb676425b3C \\"
    echo "      1000000000000000 \\"
    echo "      100000"
    exit 1
fi

NONCE=$1
SENDER=$2
TARGET=$3
VALUE=$4
GAS_LIMIT=$5
DATA=0x

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/.env" ]; then
    source "$ROOT_DIR/.env"
fi

PORTAL="${OPTIMISM_PORTAL:-0xce730af662e8d53913e8570eb3516a411adee8a5}"
L1_RPC_URL="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

# Calculate withdrawal hash
echo "Calculating withdrawal hash..."
WHASH=$(cast keccak256 $(cast abi-encode "f(uint256,address,address,uint256,uint256,bytes)" \
    $NONCE $SENDER $TARGET $VALUE $GAS_LIMIT $DATA))

PROVER=$SENDER

echo ""
echo "============================================"
echo "Withdrawal Status Check"
echo "============================================"
echo "Withdrawal Hash: $WHASH"
echo "Prover Address:  $PROVER"
echo "Portal:          $PORTAL"
echo ""

# Call provenWithdrawals
echo "Checking proof status..."
RESULT=$(cast call "$PORTAL" \
    "provenWithdrawals(bytes32,address)(address,uint256)" \
    "$WHASH" "$PROVER" \
    --rpc-url "$L1_RPC_URL" 2>&1)

if echo "$RESULT" | grep -q "error"; then
    echo "Error: $RESULT"
    exit 1
fi

# Parse result (returns: disputeGame address, timestamp)
# Handle both single line and multi-line output
DISPUTE_GAME=$(echo "$RESULT" | head -1 | tr -d '[:space:]')
TIMESTAMP_RAW=$(echo "$RESULT" | tail -1 | tr -d '[:space:]' | sed 's/\[.*\]//')
# Convert timestamp - handle both decimal and scientific notation
if echo "$TIMESTAMP_RAW" | grep -q 'e'; then
    # Scientific notation - convert using awk
    TIMESTAMP=$(echo "$TIMESTAMP_RAW" | awk '{printf "%.0f", $1}')
else
    TIMESTAMP=$(printf "%.0f" "$TIMESTAMP_RAW" 2>/dev/null || echo "$TIMESTAMP_RAW")
fi

if [ "$DISPUTE_GAME" = "0x0000000000000000000000000000000000000000" ] || [ "$TIMESTAMP" = "0" ]; then
    echo "Status: NOT PROVEN"
    echo ""
    echo "The withdrawal has not been proven yet."
else
    echo "Status: PROVEN"
    echo "Dispute Game: $DISPUTE_GAME"
    echo "Proven At:    $TIMESTAMP ($(date -r $TIMESTAMP 2>/dev/null || echo "timestamp"))"
fi

# Check if finalized
echo ""
echo "Checking finalization..."
FINALIZED=$(cast call "$PORTAL" "finalizedWithdrawals(bytes32)(bool)" "$WHASH" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "false")
if [ "$FINALIZED" = "true" ]; then
    echo "Finalized:    YES"
    echo ""
    echo "This withdrawal has been finalized; ETH has been sent to L1."
else
    echo "Finalized:    NO"
    if [ "$DISPUTE_GAME" != "0x0000000000000000000000000000000000000000" ]; then
        echo ""
        echo "Proven but not yet finalized. Resolve the dispute game, wait for finality, then call finalizeWithdrawalTransaction."
    fi
fi

echo ""
echo "To check again, run:"
echo "  cast call $PORTAL \\"
echo "    'provenWithdrawals(bytes32,address)(address,uint256)' \\"
echo "    $WHASH $PROVER \\"
echo "    --rpc-url $L1_RPC_URL"
