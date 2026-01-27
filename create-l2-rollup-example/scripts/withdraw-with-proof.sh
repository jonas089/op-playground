#!/usr/bin/env bash
set -euo pipefail

# Withdraw ETH from L2 to L1 with manual merkle proof generation.
#
# This script:
# 1. Initiates a withdrawal on L2 via L2ToL1MessagePasser
# 2. Waits for the withdrawal to be included in a block
# 3. Submits a state root containing that block (if needed)
# 4. Generates a merkle proof for the withdrawal
# 5. Proves the withdrawal on L1 via OptimismPortal
# 6. Finalizes the withdrawal after the challenge period
#
# Usage:
#   ./scripts/withdraw-with-proof.sh <amount_in_wei>
#   ./scripts/withdraw-with-proof.sh 0.005ether

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_JSON="$ROOT_DIR/deployer/.deployer/state.json"

# Load env
if [ -f "$ROOT_DIR/.env" ]; then
    set -a; source "$ROOT_DIR/.env"; set +a
fi

# Configuration
L1_RPC="${L1_RPC_URL:?L1_RPC_URL not set}"
L2_RPC="${L2_RPC:-http://localhost:8545}"
OP_NODE_RPC="${OP_NODE_RPC:-http://localhost:9545}"
PK="${PRIVATE_KEY:?PRIVATE_KEY not set}"

# L2 predeploy addresses (standard for all OP Stack chains)
L2_TO_L1_MESSAGE_PASSER="0x4200000000000000000000000000000000000016"
L2_CROSS_DOMAIN_MESSENGER="0x4200000000000000000000000000000000000007"

# Get L1 contract addresses
PORTAL=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' "$STATE_JSON")
FACTORY=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' "$STATE_JSON")

OUR_ADDR=$(cast wallet address --private-key $PK)

echo "============================================"
echo "L2 → L1 Withdrawal with Manual Merkle Proof"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Our address:     $OUR_ADDR"
echo "  L1 RPC:          $L1_RPC"
echo "  L2 RPC:          $L2_RPC"
echo "  OptimismPortal:  $PORTAL"
echo "  L2ToL1MessagePasser: $L2_TO_L1_MESSAGE_PASSER"
echo ""

# Parse amount argument
AMOUNT="${1:-0.005ether}"
if [[ "$AMOUNT" == *"ether"* ]]; then
    AMOUNT_WEI=$(cast to-wei ${AMOUNT%ether})
else
    AMOUNT_WEI="$AMOUNT"
fi
echo "Withdrawal amount: $AMOUNT_WEI wei ($(cast from-wei $AMOUNT_WEI) ETH)"
echo ""

# Check L2 balance
L2_BAL=$(cast balance $OUR_ADDR --rpc-url $L2_RPC)
echo "L2 balance: $(cast from-wei $L2_BAL) ETH"
if [ $(echo "$L2_BAL < $AMOUNT_WEI" | bc) -eq 1 ]; then
    echo "Error: Insufficient L2 balance for withdrawal" >&2
    exit 1
fi

# ============================================
# STEP 1: Initiate withdrawal on L2
# ============================================
echo ""
echo "Step 1: Initiating withdrawal on L2..."

# The L2ToL1MessagePasser.initiateWithdrawal function:
# function initiateWithdrawal(address _target, uint256 _gasLimit, bytes memory _data)
# For a simple ETH withdrawal, we call it with our address as target, gas limit, and empty data
# The value we send becomes the withdrawal amount

WITHDRAWAL_TX=$(cast send $L2_TO_L1_MESSAGE_PASSER \
    "initiateWithdrawal(address,uint256,bytes)" \
    $OUR_ADDR \
    100000 \
    "0x" \
    --value $AMOUNT_WEI \
    --private-key $PK \
    --rpc-url $L2_RPC \
    --json)

WITHDRAWAL_TX_HASH=$(echo "$WITHDRAWAL_TX" | jq -r '.transactionHash')
WITHDRAWAL_BLOCK=$(echo "$WITHDRAWAL_TX" | jq -r '.blockNumber' | xargs printf "%d")

echo "Withdrawal TX: $WITHDRAWAL_TX_HASH"
echo "Included in L2 block: $WITHDRAWAL_BLOCK"

# Get the withdrawal receipt to find the MessagePassed event
RECEIPT=$(cast receipt $WITHDRAWAL_TX_HASH --rpc-url $L2_RPC --json)

# The MessagePassed event has this signature:
# event MessagePassed(uint256 indexed nonce, address indexed sender, address indexed target,
#                     uint256 value, uint256 gasLimit, bytes data, bytes32 withdrawalHash)
# Topic0: 0x02a52367d10742d8032712c1bb8e0144ff1ec5ffda1ed7d70bb05a2744955054

MESSAGE_PASSED_LOG=$(echo "$RECEIPT" | jq -r '.logs[] | select(.topics[0] == "0x02a52367d10742d8032712c1bb8e0144ff1ec5ffda1ed7d70bb05a2744955054")')

if [ -z "$MESSAGE_PASSED_LOG" ] || [ "$MESSAGE_PASSED_LOG" = "null" ]; then
    echo "Error: MessagePassed event not found in receipt" >&2
    exit 1
fi

# Extract nonce from topic1
NONCE_HEX=$(echo "$MESSAGE_PASSED_LOG" | jq -r '.topics[1]')
NONCE=$(cast to-dec $NONCE_HEX)
echo "Withdrawal nonce: $NONCE"

# Decode the log data to get withdrawalHash
# The data contains: value (uint256), gasLimit (uint256), data (bytes), withdrawalHash (bytes32)
LOG_DATA=$(echo "$MESSAGE_PASSED_LOG" | jq -r '.data')

# The withdrawalHash is the last 32 bytes of the log data
# But it's easier to compute it ourselves
# withdrawalHash = keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))
WITHDRAWAL_HASH=$(cast keccak256 $(cast abi-encode "f(uint256,address,address,uint256,uint256,bytes)" \
    $NONCE \
    $OUR_ADDR \
    $OUR_ADDR \
    $AMOUNT_WEI \
    100000 \
    "0x"))

echo "Withdrawal hash: $WITHDRAWAL_HASH"

# ============================================
# STEP 2: Wait for state root to be proposed
# ============================================
echo ""
echo "Step 2: Ensuring state root is proposed for block $WITHDRAWAL_BLOCK..."

# Check current game count
GAME_COUNT=$(cast call $FACTORY "gameCount()(uint256)" --rpc-url $L1_RPC)
echo "Current game count: $GAME_COUNT"

# We need a state root that covers our withdrawal block
# Check if we need to submit one
NEED_NEW_ROOT=true

if [ "$GAME_COUNT" -gt 0 ]; then
    # Check the latest game's L2 block number
    LATEST_IDX=$((GAME_COUNT - 1))
    GAME_DATA=$(cast call $FACTORY "gameAtIndex(uint256)(uint32,uint64,address)" $LATEST_IDX --rpc-url $L1_RPC)
    GAME_PROXY=$(echo "$GAME_DATA" | sed -n '3p')
    LATEST_L2_BLOCK=$(cast call $GAME_PROXY "l2BlockNumber()(uint256)" --rpc-url $L1_RPC)

    echo "Latest proposed L2 block: $LATEST_L2_BLOCK"

    if [ "$LATEST_L2_BLOCK" -ge "$WITHDRAWAL_BLOCK" ]; then
        NEED_NEW_ROOT=false
        echo "State root already covers our withdrawal block."
    fi
fi

if [ "$NEED_NEW_ROOT" = true ]; then
    echo "Submitting new state root..."

    # Get the proposer private key
    PROPOSER_KEY_FILE="$ROOT_DIR/deployer/addresses/proposer_private_key.txt"
    if [ -f "$PROPOSER_KEY_FILE" ]; then
        PROPOSER_PK=$(cat "$PROPOSER_KEY_FILE" | sed 's/^0x//')
    else
        echo "Error: Proposer private key not found" >&2
        exit 1
    fi

    # Wait for L2 to advance past our withdrawal block
    echo "Waiting for L2 to advance past withdrawal block $WITHDRAWAL_BLOCK..."
    while true; do
        SYNC_STATUS=$(curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
            "$OP_NODE_RPC")
        UNSAFE_HEAD=$(echo "$SYNC_STATUS" | jq -r '.result.unsafe_l2.number')
        if [ "$UNSAFE_HEAD" -gt "$WITHDRAWAL_BLOCK" ]; then
            echo "L2 unsafe head: $UNSAFE_HEAD"
            break
        fi
        echo "  Waiting... (unsafe head: $UNSAFE_HEAD)"
        sleep 5
    done

    # Use the current unsafe head as our target (it definitely includes the withdrawal)
    TARGET_BLOCK=$UNSAFE_HEAD

    OUTPUT_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_outputAtBlock\",\"params\":[\"$(printf '0x%x' "$TARGET_BLOCK")\"],\"id\":1}" \
        "$OP_NODE_RPC")

    OUTPUT_ROOT=$(echo "$OUTPUT_RESPONSE" | jq -r '.result.outputRoot')

    echo "Proposing state root for block $TARGET_BLOCK: $OUTPUT_ROOT"

    EXTRA_DATA=$(cast abi-encode "f(uint256)" "$TARGET_BLOCK")

    cast send $FACTORY \
        "create(uint32,bytes32,bytes)(address)" \
        1 "$OUTPUT_ROOT" "$EXTRA_DATA" \
        --private-key $PROPOSER_PK \
        --rpc-url $L1_RPC \
        --json > /dev/null

    echo "Waiting for L1 transaction to confirm..."
    sleep 15

    # Get the new game proxy
    GAME_COUNT=$(cast call $FACTORY "gameCount()(uint256)" --rpc-url $L1_RPC)
    LATEST_IDX=$((GAME_COUNT - 1))
    GAME_DATA=$(cast call $FACTORY "gameAtIndex(uint256)(uint32,uint64,address)" $LATEST_IDX --rpc-url $L1_RPC)
    GAME_PROXY=$(echo "$GAME_DATA" | sed -n '3p')

    echo "New dispute game created: $GAME_PROXY (for L2 block $TARGET_BLOCK)"
fi

# ============================================
# STEP 3: Generate Merkle Proof
# ============================================
echo ""
echo "Step 3: Generating Merkle proof..."

# The withdrawal is stored in L2ToL1MessagePasser at:
# sentMessages[withdrawalHash] = true
# The storage slot is keccak256(abi.encode(withdrawalHash, 0))
# where 0 is the slot number of the sentMessages mapping

STORAGE_SLOT=$(cast keccak256 $(cast abi-encode "f(bytes32,uint256)" $WITHDRAWAL_HASH 0))
echo "Storage slot: $STORAGE_SLOT"

# Get the L2 block that's covered by the latest state root
GAME_COUNT=$(cast call $FACTORY "gameCount()(uint256)" --rpc-url $L1_RPC)
LATEST_IDX=$((GAME_COUNT - 1))
GAME_DATA=$(cast call $FACTORY "gameAtIndex(uint256)(uint32,uint64,address)" $LATEST_IDX --rpc-url $L1_RPC)
FOUND_GAME_PROXY=$(echo "$GAME_DATA" | sed -n '3p')
PROOF_BLOCK=$(cast call $FOUND_GAME_PROXY "l2BlockNumber()(uint256)" --rpc-url $L1_RPC)
FOUND_GAME_IDX=$LATEST_IDX

echo "State root covers L2 block: $PROOF_BLOCK"

# Verify this block contains our withdrawal
if [ "$PROOF_BLOCK" -lt "$WITHDRAWAL_BLOCK" ]; then
    echo "Error: Latest state root (block $PROOF_BLOCK) doesn't cover withdrawal (block $WITHDRAWAL_BLOCK)"
    echo "A newer state root should have been submitted in Step 2."
    exit 1
fi
echo "Generating proof at L2 block: $PROOF_BLOCK"

# eth_getProof returns account proof and storage proofs
PROOF_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getProof\",\"params\":[\"$L2_TO_L1_MESSAGE_PASSER\",[\"$STORAGE_SLOT\"],\"$(printf '0x%x' "$PROOF_BLOCK")\"],\"id\":1}" \
    "$L2_RPC")

# Extract the proofs
ACCOUNT_PROOF=$(echo "$PROOF_RESPONSE" | jq -c '.result.accountProof')
STORAGE_PROOF=$(echo "$PROOF_RESPONSE" | jq -c '.result.storageProof[0].proof')
STORAGE_VALUE=$(echo "$PROOF_RESPONSE" | jq -r '.result.storageProof[0].value')

echo "Storage value (should be 0x1): $STORAGE_VALUE"

if [ "$STORAGE_VALUE" != "0x1" ]; then
    echo "Warning: Storage value is not 0x1, withdrawal may not be properly recorded"
fi

# Get the state root and other block info for the proof
L2_BLOCK_INFO=$(cast block $PROOF_BLOCK --rpc-url $L2_RPC --json)
L2_STATE_ROOT=$(echo "$L2_BLOCK_INFO" | jq -r '.stateRoot')
L2_BLOCK_HASH=$(echo "$L2_BLOCK_INFO" | jq -r '.hash')

echo "L2 state root: $L2_STATE_ROOT"
echo "L2 block hash: $L2_BLOCK_HASH"

# Get the output root for this block
OUTPUT_AT_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_outputAtBlock\",\"params\":[\"$(printf '0x%x' "$PROOF_BLOCK")\"],\"id\":1}" \
    "$OP_NODE_RPC")

OUTPUT_ROOT_FOR_PROOF=$(echo "$OUTPUT_AT_BLOCK" | jq -r '.result.outputRoot')
echo "Output root for proof: $OUTPUT_ROOT_FOR_PROOF"

# ============================================
# STEP 4: Prove withdrawal on L1
# ============================================
echo ""
echo "Step 4: Proving withdrawal on L1..."

# For OptimismPortal2 with fault proofs, we need to call proveWithdrawalTransaction
# The function signature is:
# function proveWithdrawalTransaction(
#     Types.WithdrawalTransaction memory _tx,
#     uint256 _disputeGameIndex,
#     Types.OutputRootProof calldata _outputRootProof,
#     bytes[] calldata _withdrawalProof
# )
#
# Types.WithdrawalTransaction is:
# struct WithdrawalTransaction {
#     uint256 nonce;
#     address sender;
#     address target;
#     uint256 value;
#     uint256 gasLimit;
#     bytes data;
# }
#
# Types.OutputRootProof is:
# struct OutputRootProof {
#     bytes32 version;
#     bytes32 stateRoot;
#     bytes32 messagePasserStorageRoot;
#     bytes32 latestBlockhash;
# }

# Get the message passer storage root from the proof response
MESSAGE_PASSER_STORAGE_ROOT=$(echo "$PROOF_RESPONSE" | jq -r '.result.storageHash')
echo "Message passer storage root: $MESSAGE_PASSER_STORAGE_ROOT"

# We already have the game from step 3
echo "Using dispute game at index $FOUND_GAME_IDX (proxy: $FOUND_GAME_PROXY)"

# Format the withdrawal proof array for solidity
# Convert the JSON array to a format cast can use
WITHDRAWAL_PROOF_FORMATTED=$(echo "$STORAGE_PROOF" | jq -r '.[]' | tr '\n' ',' | sed 's/,$//')

# Build the prove transaction
# This is complex because we need to ABI-encode a struct
# Let's use cast's abi-encode with the full signature

echo ""
echo "Calling proveWithdrawalTransaction..."
echo "  Dispute game index: $FOUND_GAME_IDX"
echo "  Withdrawal nonce: $NONCE"
echo "  Sender/Target: $OUR_ADDR"
echo "  Value: $AMOUNT_WEI"
echo "  Gas limit: 100000"

# The outputRootProof version is 0 for bedrock
# We need to encode this properly

# First, let's check if the withdrawal has already been proven
PROVEN_STATUS=$(cast call $PORTAL "provenWithdrawals(bytes32,address)(bytes32,uint128,uint128)" \
    $WITHDRAWAL_HASH \
    $FOUND_GAME_PROXY \
    --rpc-url $L1_RPC 2>/dev/null || echo "not_proven")

if [ "$PROVEN_STATUS" != "not_proven" ] && [ -n "$PROVEN_STATUS" ]; then
    echo "Withdrawal may already be proven"
fi

# Create a JSON file with the proof data for easier debugging
cat > /tmp/withdrawal_proof.json << EOF
{
    "withdrawalTransaction": {
        "nonce": "$NONCE",
        "sender": "$OUR_ADDR",
        "target": "$OUR_ADDR",
        "value": "$AMOUNT_WEI",
        "gasLimit": "100000",
        "data": "0x"
    },
    "disputeGameIndex": "$FOUND_GAME_IDX",
    "outputRootProof": {
        "version": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "stateRoot": "$L2_STATE_ROOT",
        "messagePasserStorageRoot": "$MESSAGE_PASSER_STORAGE_ROOT",
        "latestBlockhash": "$L2_BLOCK_HASH"
    },
    "withdrawalProof": $STORAGE_PROOF
}
EOF

echo "Proof data saved to /tmp/withdrawal_proof.json"

# The actual prove call is complex with structs - let's use cast with raw encoding
# proveWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes),uint256,(bytes32,bytes32,bytes32,bytes32),bytes[])

# Encode the withdrawal transaction tuple
WITHDRAWAL_TX_ENCODED=$(cast abi-encode "f((uint256,address,address,uint256,uint256,bytes))" \
    "($NONCE,$OUR_ADDR,$OUR_ADDR,$AMOUNT_WEI,100000,0x)")

# Encode the output root proof tuple
OUTPUT_PROOF_ENCODED=$(cast abi-encode "f((bytes32,bytes32,bytes32,bytes32))" \
    "(0x0000000000000000000000000000000000000000000000000000000000000000,$L2_STATE_ROOT,$MESSAGE_PASSER_STORAGE_ROOT,$L2_BLOCK_HASH)")

# For the withdrawal proof bytes array, we need special handling
# Let's try a simpler approach using the raw call

echo ""
echo "Submitting proof transaction to L1..."

# Use cast send with the function signature
PROVE_TX=$(cast send $PORTAL \
    "proveWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes),uint256,(bytes32,bytes32,bytes32,bytes32),bytes[])" \
    "($NONCE,$OUR_ADDR,$OUR_ADDR,$AMOUNT_WEI,100000,0x)" \
    $FOUND_GAME_IDX \
    "(0x0000000000000000000000000000000000000000000000000000000000000000,$L2_STATE_ROOT,$MESSAGE_PASSER_STORAGE_ROOT,$L2_BLOCK_HASH)" \
    "[$WITHDRAWAL_PROOF_FORMATTED]" \
    --private-key $PK \
    --rpc-url $L1_RPC \
    --json 2>&1) || {
    echo "Prove transaction failed. This might be due to:"
    echo "  - Incorrect proof data"
    echo "  - Output root mismatch"
    echo "  - Withdrawal already proven"
    echo ""
    echo "Error: $PROVE_TX"
    exit 1
}

PROVE_TX_HASH=$(echo "$PROVE_TX" | jq -r '.transactionHash')
echo "Prove TX: $PROVE_TX_HASH"

echo ""
echo "============================================"
echo "Withdrawal proven successfully!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Wait for the dispute game to resolve (challenge period)"
echo "2. Run: cast send $PORTAL 'finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))' '($NONCE,$OUR_ADDR,$OUR_ADDR,$AMOUNT_WEI,100000,0x)' --private-key \$PRIVATE_KEY --rpc-url $L1_RPC"
echo ""
echo "To check withdrawal status:"
echo "  cast call $PORTAL 'provenWithdrawals(bytes32,address)(bytes32,uint128,uint128)' $WITHDRAWAL_HASH $FOUND_GAME_PROXY --rpc-url $L1_RPC"
