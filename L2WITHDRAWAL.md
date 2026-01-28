# End-to-End Testing Guide

This guide walks through the full bridging lifecycle: starting the network, depositing ETH from L1 to L2, withdrawing ETH from L2 to L1 with a merkle proof, resolving the dispute game, and finalizing the withdrawal.

---

## Prerequisites

- Docker and Docker Compose
- Foundry (`cast` CLI)
- jq, curl
- `.env` file with private key and L1 RPC URLs
- L1 contracts deployed via `make setup`

---

## ⚠️ Important: Contract Addresses Change on Redeployment

**All contract addresses (OptimismPortal, DisputeGameFactory, AnchorStateRegistry, etc.) change every time you run `make setup`.**

Always get the current addresses from your deployment:

```bash
# Get all contract addresses
jq -r '.opChainDeployments[0]' deployer/.deployer/state.json

# Or get specific addresses
jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json
jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' deployer/.deployer/state.json
```

**Do not use hardcoded addresses from examples** - they are from a specific deployment and will not work after redeployment.

---

## 1. Starting and Stopping the Network

### Start All Services

```bash
make up
```

Containers:

| Service | Port | Role |
|---------|------|------|
| op-geth | 8545 / 8546 | L2 execution |
| op-node | 9545 | L2 consensus |
| op-batcher | 8548 | Batching |
| op-proposer | 8560 | State roots |

Verify:

```bash
cast block-number --rpc-url http://localhost:8545
cast chain-id --rpc-url http://localhost:8545
```

Expected chain ID: `16585`

---

### Stop Services

```bash
make down
make clean
```

---

### Utilities

```bash
make status
make logs
make logs-op-node
make restart
```

---

### Stop L2 Only

```bash
./scripts/stop-l2.sh
```

---

## 2. Deposit ETH (L1 → L2)

### Using Script

```bash
./scripts/deposit.sh 0.002ether
```

### Manual Deposit

```bash
source .env

# Get the portal address from your deployment (addresses change on redeployment!)
PORTAL=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json)
WALLET=$(cast wallet address --private-key 0x$PRIVATE_KEY)

# IMPORTANT: The _value parameter (3rd arg) must match --value
# Use cast to-unit to convert amounts like "0.005ether" to wei
cast send $PORTAL \
  "depositTransaction(address,uint256,uint64,bool,bytes)" \
  $WALLET $(cast to-unit 0.005ether wei) 100000 false "0x" \
  --value 0.005ether \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

**Important Notes:**
- The `_value` parameter (3rd argument) must match the ETH amount sent via `--value`. This is the amount that will be credited to the recipient on L2.
- **Contract addresses change when you re-run `make setup`** - always get the current portal address from `deployer/.deployer/state.json`

Deposits do not require proofs or challenge periods.

---

## 3. Withdraw ETH (L2 → L1)

### Using Script

```bash
./scripts/withdraw-with-proof.sh 0.001ether
```

This script:

1. Initiates withdrawal on L2
2. Ensures a state root exists
3. Generates a Merkle proof
4. Proves on L1
5. Prints the required resolution/finalization commands

After the script finishes, you must still resolve the dispute game and finalize manually.

---

### Step 1: Initiate Withdrawal (L2)

```bash
cast send 0x4200000000000000000000000000000000000016 \
  "initiateWithdrawal(address,uint256,bytes)" \
  $WALLET 100000 "0x" \
  --value 0.001ether \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url http://localhost:8545
```

This emits a `MessagePassed` event with a `withdrawalHash`.

---

### Step 2: State Root Submission

A dispute game must exist covering the L2 block that contains the withdrawal.

The script will:

- Check the latest game
- Fetch an output root if needed
- Create a new game using the proposer key

---

### Step 3: Merkle Proof

The script:

- Computes the storage slot
- Calls `eth_getProof`
- Fetches state root and block hash
- Builds the output root proof

---

### Step 4: Prove on L1

The script calls:

```
proveWithdrawalTransaction(...)
```

After success, it prints:

- Withdrawal hash
- Prover address
- Game proxy
- Game index
- Correct resolve/finalize commands

---

## 4. Important Values

After running `withdraw-with-proof.sh`, the script prints:

```
Withdrawal hash: <hash>
Prover address:  <address>
Game proxy:      <address>
Game index:      <index>
```

These are required for debugging and manual steps.

### withdrawalHash

Unique identifier of the withdrawal.

Source:

- `MessagePassed` event on L2
- `WithdrawalProven` / `WithdrawalFinalized` on L1

You can re-fetch:

```bash
cast receipt <TX_HASH> --rpc-url $L1_RPC_URL
```

Use `topics[1]`.

---

### prover

The L1 address that submitted `proveWithdrawalTransaction`.

Chek status:

```bash
cast receipt <PROVE_TX_HASH> --rpc-url $L1_RPC_URL
```

Use the `from` field.

Usually your wallet.

---

### GAME_PROXY

The dispute game contract address.

**Sources:**

- Printed by the script
- Or queried from DisputeGameFactory

**Manual lookup:**

```bash
# Get factory address from your deployment (addresses change on redeployment!)
FACTORY=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' deployer/.deployer/state.json)

cast call $FACTORY 'gameCount()(uint256)' --rpc-url $L1_RPC_URL

cast call $FACTORY 'games(uint256)(address)' <INDEX> --rpc-url $L1_RPC_URL
```

---

## 5. Resolve the Dispute Game

Wait ~90 seconds after game creation.

### Resolve Root Claim

```bash
cast send <GAME_PROXY> \
  'resolveClaim(uint256,uint256)' 0 0 \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

### Resolve Game

```bash
cast send <GAME_PROXY> \
  'resolve()' \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

### Verify

```bash
cast call <GAME_PROXY> 'status()(uint8)' --rpc-url $L1_RPC_URL
```

Result:

- `2` = DEFENDER_WINS (accepted)

---

## 6. Wait for Registry Finality

After status = 2, wait ~60 seconds.

Optional check:

```bash
# Get registry address from your deployment (addresses change on redeployment!)
REG=$(jq -r '.opChainDeployments[0].AnchorStateRegistryProxy' deployer/.deployer/state.json)

cast call $REG \
  'isGameFinalized(address)(bool)' \
  <GAME_PROXY> \
  --rpc-url $L1_RPC_URL
```

Must return `true`.

---

## 7. Finalize Withdrawal

After finality:

```bash
# Get portal address from your deployment (addresses change on redeployment!)
PORTAL=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json)

cast send $PORTAL \
  'finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))' \
  '(<NONCE>,<FROM>,<TO>,<VALUE>,100000,0x)' \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

ETH will be transferred to L1.

**Note:** If you get `OptimismPortal_AlreadyFinalized`, the withdrawal has already been finalized. Check with `finalizedWithdrawals` to confirm.

---

## 8. Check Withdrawal Status

### Understanding provenWithdrawals vs finalizedWithdrawals

**Important:** `provenWithdrawals` is a **mapping**, not a list. Each call checks ONE specific (withdrawalHash, prover) pair.

- **`provenWithdrawals[withdrawalHash][prover]`** → Returns `(address disputeGame, uint256 timestamp)` - who proved it and when
- **`finalizedWithdrawals[withdrawalHash]`** → Returns `bool` - whether the withdrawal has been finalized

**Withdrawal Lifecycle:**
1. **Initiate** on L2 → withdrawal transaction created
2. **Prove** on L1 → stored in `provenWithdrawals` mapping
3. **Finalize** on L1 → stored in `finalizedWithdrawals` mapping → ETH sent to L1

If a withdrawal is finalized, it **must** have been proven first. The `provenWithdrawals` data persists even after finalization.

---

### Check if Withdrawal is Proven

This deployment stores:

```
(address disputeGame, uint256 timestamp)
```

Set variables:

```bash
# Get portal address from your deployment (addresses change on redeployment!)
PORTAL=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json)
WHASH=<withdrawalHash>
PROVER=<prove_tx_sender>  # Usually your wallet address
L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
```

Query:

```bash
cast call "$PORTAL" \
  'provenWithdrawals(bytes32,address)(address,uint256)' \
  "$WHASH" "$PROVER" \
  --rpc-url "$L1_RPC_URL"
```

**Returns:**
- First line: Dispute game address (or `0x0000...` if not proven)
- Second line: Timestamp when proven (or `0` if not proven)

**Do NOT use `(bytes32,uint128,uint128)`** — that ABI is incorrect for this deployment.

---

### Check if Withdrawal is Finalized

```bash
cast call "$PORTAL" \
  'finalizedWithdrawals(bytes32)(bool)' \
  "$WHASH" \
  --rpc-url "$L1_RPC_URL"
```

**Returns:**
- `true` = Finalized (ETH has been sent to L1)
- `false` = Not finalized

---

### Calculate Withdrawal Hash

If you have the withdrawal parameters but not the hash:

```bash
# Withdrawal parameters
NONCE=<withdrawal_nonce>
SENDER=<sender_address>
TARGET=<target_address>
VALUE=<value_in_wei>
GAS_LIMIT=100000
DATA=0x

# Calculate hash
WHASH=$(cast keccak256 $(cast abi-encode "f(uint256,address,address,uint256,uint256,bytes)" \
  $NONCE $SENDER $TARGET $VALUE $GAS_LIMIT $DATA))
```

---

### Find All Your Withdrawals

Query `WithdrawalFinalized` events to find all your finalized withdrawals:

```bash
# Get portal address from your deployment (addresses change on redeployment!)
PORTAL=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json)
L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com

# Find all WithdrawalFinalized events
cast logs --from-block <start_block> --to-block latest \
  "WithdrawalFinalized(bytes32,bool)" \
  --address "$PORTAL" \
  --rpc-url "$L1_RPC_URL"
```

The `topics[1]` field contains the withdrawal hash for each event.

---

### Using the Helper Script

A helper script is available to check withdrawal status:

```bash
./scripts/get-withdrawal-status.sh <nonce> <sender> <target> <value> <gas_limit>
```

Example:

```bash
./scripts/get-withdrawal-status.sh \
  1766847064778384329583297500742918515827483896875618958121606201292619777 \
  0xB0F557D10b9355F39977e8D5d7404Fb676425b3C \
  0xB0F557D10b9355F39977e8D5d7404Fb676425b3C \
  1000000000000000 \
  100000
```

This script will:
- Calculate the withdrawal hash
- Check if it's proven
- Check if it's finalized
- Display all relevant information

---

## 9. Contract Addresses

**⚠️ IMPORTANT:** Contract addresses **change every time you run `make setup`**. The addresses below are examples from one deployment. Always get the current addresses from your deployment's `state.json` file.

**Get all contract addresses from your deployment:**

```bash
jq -r '.opChainDeployments[0] | "OptimismPortal: \(.OptimismPortalProxy)\nDisputeGameFactory: \(.DisputeGameFactoryProxy)\nAnchorStateRegistry: \(.AnchorStateRegistryProxy)"' deployer/.deployer/state.json
```

**Or get individual addresses:**

```bash
# OptimismPortal
jq -r '.opChainDeployments[0].OptimismPortalProxy' deployer/.deployer/state.json

# DisputeGameFactory
jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' deployer/.deployer/state.json

# AnchorStateRegistry
jq -r '.opChainDeployments[0].AnchorStateRegistryProxy' deployer/.deployer/state.json
```

**Example addresses from one deployment (yours will differ):**

| Contract | Address |
|----------|----------|
| OptimismPortal | 0xce730af662e8d53913e8570eb3516a411adee8a5 |
| DisputeGameFactory | Check state.json |
| AnchorStateRegistry | Check state.json |
| L2ToL1MessagePasser | 0x4200000000000000000000000000000000000016 |

---

## 10. Troubleshooting

### OptimismPortal_InvalidRootClaim

Cause:

- Game not resolved
- Registry not finalized
- Finalizing too early

Fix:

- Resolve game
- Wait finality
- Retry

---

### OptimismPortal_AlreadyFinalized

The withdrawal has already been finalized. This is expected if you try to finalize the same withdrawal twice.

Check finalization status:
```bash
cast call $PORTAL 'finalizedWithdrawals(bytes32)(bool)' $WHASH --rpc-url $L1_RPC_URL
```

If `true`, the withdrawal is complete and ETH has been sent to L1.

---

### OutOfOrderResolution

Clock not expired.

Wait 60s and retry.

---

### ProofNotOldEnough

Proof maturity delay not passed.

Wait and retry.

---

### GameAlreadyExists

Existing game already covers block.

Safe to continue.

---

### Deposit Missing

If deposits don't appear on L2:

1. **Check if op-node is running:**
   ```bash
   docker compose ps op-node
   ```

2. **Check op-node logs:**
   ```bash
   docker compose logs op-node --tail 50
   ```

3. **Verify L1 transaction was confirmed:**
   ```bash
   cast receipt <TX_HASH> --rpc-url $L1_RPC_URL
   ```

4. **Check sync status:**
   ```bash
   curl -s -X POST http://localhost:9545 \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' | jq
   ```

5. **Common issues:**
   - Safe L2 chain stuck at block 0 → batcher may not be running
   - Deposits should still appear in unsafe blocks
   - Try restarting op-node: `docker compose restart op-node`

6. **Verify deposit event on L1:**
   ```bash
   cast logs --from-block <block> --to-block latest \
     "TransactionDeposited(address,address,uint256,bytes)" \
     --address $PORTAL \
     --rpc-url $L1_RPC_URL
   ```

---

### L2 RPC Down

```bash
make status
make restart
make logs-op-geth
```

---

End of guide.
