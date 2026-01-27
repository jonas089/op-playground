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
./scripts/deposit.sh 0.005ether
```

### Manual Deposit

```bash
source .env

PORTAL=0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909
WALLET=$(cast wallet address --private-key 0x$PRIVATE_KEY)

cast send $PORTAL \
  "depositTransaction(address,uint256,uint64,bool,bytes)" \
  $WALLET 0 100000 false "0x" \
  --value 0.005ether \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

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

来源:

- Printed by the script
- Or queried from DisputeGameFactory

Manual lookup:

```bash
FACTORY=0xb980d58c642a11667bcbafac34d2529df07a8ac4

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
REG=0x440eE8853273111b9B3aB46f9C1B9161E04D2a19

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
cast send $PORTAL \
  'finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))' \
  '(<NONCE>,<FROM>,<TO>,<VALUE>,100000,0x)' \
  --private-key 0x$PRIVATE_KEY \
  --rpc-url $L1_RPC_URL
```

ETH will be transferred to L1.

---

## 8. Check Proof Status (Correct ABI)

This deployment stores:

```
(address disputeGame, uint256 timestamp)
```

Set:

```bash
PORTAL=0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909
WHASH=<withdrawalHash>
PROVER=<prove_tx_sender>
```

Query:

```bash
cast call $PORTAL \
  'provenWithdrawals(bytes32,address)(address,uint256)' \
  $WHASH $PROVER \
  --rpc-url $L1_RPC_URL
```

Do NOT use `(bytes32,uint128,uint128)` — that ABI is incorrect for this deployment.

---

## 9. Contract Addresses

| Contract | Address |
|----------|----------|
| OptimismPortal | 0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909 |
| DisputeGameFactory | 0xb980d58c642a11667bcbafac34d2529df07a8ac4 |
| AnchorStateRegistry | 0x440eE8853273111b9B3aB46f9C1B9161E04D2a19 |
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

Check op-node logs:

```bash
docker compose logs op-node --tail 20
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
