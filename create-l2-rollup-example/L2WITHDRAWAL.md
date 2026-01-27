# End-to-End Testing Guide

This guide walks through the full bridging lifecycle: starting the network, depositing ETH from L1 to L2, withdrawing ETH from L2 to L1 with a merkle proof, resolving the dispute game, and finalizing the withdrawal.

## Prerequisites

- Docker and Docker Compose
- [Foundry](https://book.getfoundry.sh/) (`cast` CLI)
- `jq`, `curl`
- The `.env` file configured with your private key and L1 RPC URLs
- L1 contracts already deployed via `make setup`

## 1. Starting and Stopping the Network

### Start all services

```bash
make up
```

This starts 4 Docker containers:

| Service | Port | Role |
|---------|------|------|
| **op-geth** | 8545 (HTTP), 8546 (WS) | L2 execution client |
| **op-node** | 9545 | L2 consensus client / sequencer |
| **op-batcher** | 8548 | Batches L2 txs to L1 calldata |
| **op-proposer** | 8560 | Submits state roots to L1 every 60s |

Verify L2 is running:

```bash
cast block-number --rpc-url http://localhost:8545
cast chain-id --rpc-url http://localhost:8545   # should return 16585
```

### Stop all services

```bash
make down        # stop and remove containers
make clean       # also remove volumes
```

### Other useful commands

```bash
make status      # show container status
make logs        # tail all logs
make logs-op-node    # tail specific service logs
make restart     # restart everything
```

### Stop L2 only (keep L1 accessible)

```bash
./scripts/stop-l2.sh
```

## 2. Deposit ETH (L1 to L2)

Deposits send ETH from L1 (Sepolia) into your L2 via the OptimismPortal contract.

### Using the deposit script

```bash
./scripts/deposit.sh 0.005ether
```

This script:
1. Calls `OptimismPortal.depositTransaction()` on L1
2. Waits for the L1 tx to confirm
3. Polls L2 until the deposit appears (~30-60 seconds)
4. Prints before/after balances

### Manual deposit

```bash
source .env
PORTAL="0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909"
WALLET=$(cast wallet address --private-key 0x$PRIVATE_KEY)

cast send $PORTAL "depositTransaction(address,uint256,uint64,bool,bytes)" \
    $WALLET 0 100000 false "0x" \
    --value 0.005ether \
    --private-key 0x$PRIVATE_KEY \
    --rpc-url $L1_RPC_URL
```

### How deposits work

1. You call `depositTransaction()` on the OptimismPortal (L1)
2. The portal emits a `TransactionDeposited` event
3. op-node picks up the event from L1 and includes a corresponding deposit tx in the next L2 block
4. The ETH appears in your L2 account after op-node processes the L1 block (~30s)

No proof or challenge period is needed for deposits. They are secured by L1 finality.

## 3. Withdraw ETH (L2 to L1)

Withdrawals are more involved because L1 cannot directly read L2 state. You must prove to L1 that the withdrawal happened on L2 using a merkle proof against a posted state root.

### Using the withdrawal script

```bash
./scripts/withdraw-with-proof.sh 0.001ether
```

This script automates all 4 steps described below. After it completes, you still need to **resolve the dispute game** and **finalize the withdrawal** (steps 5-6).

### Step-by-step breakdown

#### Step 1: Initiate withdrawal on L2

The script calls `L2ToL1MessagePasser.initiateWithdrawal()` on L2 (predeploy at `0x4200000000000000000000000000000000000016`):

```bash
cast send 0x4200000000000000000000000000000000000016 \
    "initiateWithdrawal(address,uint256,bytes)" \
    $WALLET 100000 "0x" \
    --value 0.001ether \
    --private-key 0x$PRIVATE_KEY \
    --rpc-url http://localhost:8545
```

This emits a `MessagePassed` event containing a `withdrawalHash`. The script captures the nonce and block number from the receipt.

#### Step 2: Ensure a state root covers the withdrawal block

For L1 to verify the withdrawal, a state root that includes the withdrawal's L2 block must exist on L1. The script checks whether the latest proposed state root already covers the withdrawal block. If not, it submits a new one.

The script:
1. Queries `DisputeGameFactory.gameCount()` and checks the latest game's `l2BlockNumber()`
2. If the latest game doesn't cover the withdrawal block, it fetches the output root from op-node via `optimism_outputAtBlock`
3. Calls `DisputeGameFactory.create(1, outputRoot, extraData)` using the **proposer's private key** (required for game type 1 = PermissionedDisputeGame)

#### Step 3: Generate a merkle proof

The withdrawal is stored in the `L2ToL1MessagePasser` contract's `sentMessages` mapping. The script:

1. Computes the storage slot: `keccak256(abi.encode(withdrawalHash, 0))`
2. Calls `eth_getProof` on the L2 RPC to get a merkle storage proof for that slot
3. Fetches the L2 state root and block hash for the proof block
4. Fetches the output root from op-node to construct the `OutputRootProof`

#### Step 4: Prove the withdrawal on L1

The script calls `OptimismPortal.proveWithdrawalTransaction()` on L1 with:
- The withdrawal transaction struct (nonce, sender, target, value, gasLimit, data)
- The dispute game index
- The output root proof (version=0, stateRoot, messagePasserStorageRoot, blockHash)
- The merkle storage proof array

After proving, the script prints the finalization command.

### Step 5: Resolve the dispute game

The dispute game must be resolved before the withdrawal can be finalized. With the upgraded contracts, the game's clock duration is 60 seconds.

Wait ~90 seconds after the game was created, then:

```bash
# First resolve the root claim
cast send <GAME_PROXY> 'resolveClaim(uint256,uint256)' 0 0 \
    --private-key 0x$PRIVATE_KEY \
    --rpc-url $L1_RPC_URL

# Then resolve the game itself
cast send <GAME_PROXY> 'resolve()' \
    --private-key 0x$PRIVATE_KEY \
    --rpc-url $L1_RPC_URL
```

Verify it resolved:

```bash
# 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS
cast call <GAME_PROXY> 'status()(uint8)' --rpc-url $L1_RPC_URL
```

Status `2` (DEFENDER_WINS) means the state root is accepted.

### Step 6: Finalize the withdrawal

After the game resolves, wait for the proof maturity delay (60 seconds) and finality delay (60 seconds), then finalize:

```bash
source .env
PORTAL="0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909"

cast send $PORTAL \
    'finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))' \
    '(<NONCE>,<YOUR_ADDRESS>,<YOUR_ADDRESS>,<VALUE_WEI>,100000,0x)' \
    --private-key 0x$PRIVATE_KEY \
    --rpc-url $L1_RPC_URL
```

Replace `<NONCE>`, `<YOUR_ADDRESS>`, and `<VALUE_WEI>` with the values printed by the withdrawal script.

The ETH will be transferred to your L1 address.

### Full withdrawal timeline (with upgraded contracts)

| Step | Duration | Cumulative |
|------|----------|------------|
| Initiate on L2 | instant | 0s |
| State root submission + L1 confirm | ~15-30s | ~30s |
| Game clock expires | 60s | ~90s |
| Resolve game | ~15s (L1 tx) | ~105s |
| Proof maturity delay | 60s | ~165s |
| Finalize | ~15s (L1 tx) | ~3 min total |

## 4. State Root Proposals and the op-proposer

### How op-proposer works

The `op-proposer` Docker service automatically submits state roots to L1 at a regular interval. It is configured in `proposer/.env`:

```
OP_PROPOSER_GAME_TYPE=1
OP_PROPOSER_PROPOSAL_INTERVAL=60s
```

This means every 60 seconds, op-proposer calls `DisputeGameFactory.create()` with the latest L2 output root, creating a new PermissionedDisputeGame on L1.

### Manual state root submission

You can also submit state roots manually:

```bash
./scripts/submit-state-root.sh              # latest safe L2 block
./scripts/submit-state-root.sh <block_num>  # specific block
```

### Query the latest state root

```bash
./scripts/get-latest-state-root.sh
```

### Avoiding conflicts with op-proposer

When you manually submit a state root (either via `submit-state-root.sh` or through `withdraw-with-proof.sh`), you might conflict with the op-proposer service which is submitting roots concurrently. Here's what can happen and how to handle it:

**The conflict**: Each dispute game must have a unique combination of `(gameType, rootClaim, extraData)`. The `extraData` encodes the L2 block number. If both you and op-proposer try to submit a root for the same L2 block, the second transaction will revert with `GameAlreadyExists`.

**Why it's usually fine**: In practice, conflicts are rare because:
- op-proposer uses the latest **safe** L2 block, while the withdrawal script uses the latest **unsafe** head
- op-proposer submits every 60 seconds, so the block numbers will usually differ
- Even if a conflict occurs, it's harmless — the game already exists, and the withdrawal script checks the latest game anyway

**If you hit a conflict**: The withdrawal script handles this gracefully. It checks whether the latest proposed state root already covers the withdrawal block before trying to submit a new one. If op-proposer already submitted a root that covers your withdrawal, the script skips submission entirely.

**Option: Stop op-proposer during testing**: If you want full control over state root submission, stop the proposer:

```bash
docker compose stop proposer
```

Then submit roots manually:

```bash
./scripts/submit-state-root.sh
```

Restart it when done:

```bash
docker compose start proposer
```

**Option: Let op-proposer handle everything**: If you don't need immediate withdrawal proving, just wait for op-proposer to submit a root that covers your withdrawal block. The withdrawal script will detect it automatically in Step 2.

## 5. Contract Addresses

| Contract | Address |
|----------|---------|
| OptimismPortal | `0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909` |
| DisputeGameFactory | `0xb980d58c642a11667bcbafac34d2529df07a8ac4` |
| L1StandardBridge | `0xe69ad7d911b3adb5508cd6ab0625398f7992e003` |
| SystemConfig | `0x594af773714f0623706f57e3a85f8bc39446063f` |
| AnchorStateRegistry | `0x440eE8853273111b9B3aB46f9C1B9161E04D2a19` |
| L2ToL1MessagePasser | `0x4200000000000000000000000000000000000016` |
| L2CrossDomainMessenger | `0x4200000000000000000000000000000000000007` |

## 6. L2 Chain Details

| Parameter | Value |
|-----------|-------|
| Chain ID | 16585 |
| L2 RPC (HTTP) | `http://localhost:8545` |
| L2 RPC (WS) | `ws://localhost:8546` |
| Op-node RPC | `http://localhost:9545` |
| L1 Network | Sepolia |
| Block time | 2 seconds |

## 7. Challenge Period Configuration

The contracts have been upgraded with shortened delays for testing:

| Parameter | Value | Contract |
|-----------|-------|----------|
| Proof maturity delay | 60s | OptimismPortal2 |
| Dispute game finality delay | 60s | AnchorStateRegistry |
| Game clock duration | 60s | PermissionedDisputeGame |
| Clock extension | 30s | PermissionedDisputeGame |
| Preimage oracle challenge period | 30s | PreimageOracle |

These values allow the full withdrawal cycle to complete in ~3 minutes instead of the production default of ~10.5 days.

## 8. Troubleshooting

### `OptimismPortal_ProofNotOldEnough`
The proof maturity delay hasn't passed yet. Wait 60 seconds after proving and try again.

### `InvalidClockExtension`
The dispute game implementation's clock parameters are incompatible. This was fixed by deploying custom PreimageOracle, MIPS VM, and PermissionedDisputeGame contracts with shorter durations.

### `OutOfOrderResolution`
The game's clock hasn't expired yet. Wait for `maxClockDuration` (60 seconds) to pass after game creation, then call `resolveClaim(0, 0)` followed by `resolve()`.

### `BadAuth` on game creation
Game type 1 (PermissionedDisputeGame) requires the **proposer's private key** (`deployer/addresses/proposer_private_key.txt`), not the admin key. The `withdraw-with-proof.sh` script handles this automatically.

### `GameAlreadyExists`
A game with the same output root and block number already exists. This usually means op-proposer already submitted a root for that block. The existing game can be used — no action needed.

### Deposit not appearing on L2
Deposits rely on op-node processing L1 blocks. Wait up to 60 seconds. Check that op-node is healthy:

```bash
docker compose logs op-node --tail 20
```

### L2 RPC not responding
```bash
make status          # check container health
make restart         # restart all services
make logs-op-geth    # check op-geth logs
```
