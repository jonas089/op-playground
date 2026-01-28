#!/bin/bash
set -e

# =============================================================================
# L1 -> L2 Deposit Script
# Deposits ETH from L1 (Sepolia) to L2 via OptimismPortal.depositTransaction()
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment variables
if [ -f "$ROOT_DIR/.env" ]; then
    source "$ROOT_DIR/.env"
fi

# Configuration
OPTIMISM_PORTAL="0xce730af662e8d53913e8570eb3516a411adee8a5"
L1_RPC_URL="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
L2_RPC_URL="${L2_RPC_URL:-http://localhost:8545}"
DEPOSIT_AMOUNT="${1:-0.01ether}"  # Default 0.01 ETH
GAS_LIMIT=100000

# Get wallet address
WALLET_ADDRESS=$(cast wallet address --private-key "0x$PRIVATE_KEY")

echo "============================================"
echo "L1 -> L2 Deposit"
echo "============================================"
echo "Wallet:          $WALLET_ADDRESS"
echo "Deposit Amount:  $DEPOSIT_AMOUNT"
echo "OptimismPortal:  $OPTIMISM_PORTAL"
echo "L1 RPC:          $L1_RPC_URL"
echo "L2 RPC:          $L2_RPC_URL"
echo ""

# Check L1 and L2 balances before deposit
echo "Checking balances before deposit..."
L1_BALANCE_BEFORE=$(cast balance "$WALLET_ADDRESS" --rpc-url "$L1_RPC_URL")
L2_BALANCE_BEFORE=$(cast balance "$WALLET_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "L1 Balance: $(cast from-wei "$L1_BALANCE_BEFORE") ETH"
echo "L2 Balance: $(cast from-wei "$L2_BALANCE_BEFORE") ETH"
echo ""

# Deposit transaction
# Function signature: depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes _data)
echo "Initiating deposit on L1..."
TX_HASH=$(cast send "$OPTIMISM_PORTAL" \
    "depositTransaction(address,uint256,uint64,bool,bytes)" \
    "$WALLET_ADDRESS" \
    0 \
    $GAS_LIMIT \
    false \
    "0x" \
    --value "$DEPOSIT_AMOUNT" \
    --rpc-url "$L1_RPC_URL" \
    --private-key "0x$PRIVATE_KEY" \
    --json | jq -r '.transactionHash')

echo "L1 Transaction Hash: $TX_HASH"
echo ""

# Wait for L1 transaction confirmation
echo "Waiting for L1 transaction confirmation..."
cast receipt "$TX_HASH" --rpc-url "$L1_RPC_URL" --json | jq '{blockNumber, status, gasUsed}'
echo ""

# Wait for the deposit to appear on L2
echo "Waiting for deposit to appear on L2 (this may take 30-60 seconds)..."
echo "Polling L2 balance..."

MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    L2_BALANCE_CURRENT=$(cast balance "$WALLET_ADDRESS" --rpc-url "$L2_RPC_URL")
    if [ "$L2_BALANCE_CURRENT" != "$L2_BALANCE_BEFORE" ]; then
        echo ""
        echo "Deposit confirmed on L2!"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    printf "."
    sleep 2
done
echo ""

# Check final balances
echo "Checking balances after deposit..."
L1_BALANCE_AFTER=$(cast balance "$WALLET_ADDRESS" --rpc-url "$L1_RPC_URL")
L2_BALANCE_AFTER=$(cast balance "$WALLET_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "L1 Balance: $(cast from-wei "$L1_BALANCE_AFTER") ETH"
echo "L2 Balance: $(cast from-wei "$L2_BALANCE_AFTER") ETH"
echo ""

# Calculate changes
L1_DIFF=$((L1_BALANCE_BEFORE - L1_BALANCE_AFTER))
L2_DIFF=$((L2_BALANCE_AFTER - L2_BALANCE_BEFORE))
echo "============================================"
echo "Deposit Summary"
echo "============================================"
echo "L1 Spent:    $(cast from-wei "$L1_DIFF") ETH (includes gas)"
echo "L2 Received: $(cast from-wei "$L2_DIFF") ETH"
echo ""
echo "Deposit complete!"
