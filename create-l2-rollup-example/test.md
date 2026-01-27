# Running the L2 Rollup

Contracts are deployed on Sepolia. To run:

```bash
cd /Users/chef/Desktop/optimism-fresh/create-l2-rollup-example

# Start L2
docker compose up -d

# Run the scripts
./scripts/get-latest-state-root.sh    # query state root from L1
./scripts/submit-state-root.sh        # submit new state root to L1
./scripts/stop-l2.sh                  # stop L2, keep L1 running
```

## Bridging ETH

### Deposit L1 → L2

```bash
source .env
PORTAL="0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909"

# Deposit 0.01 ETH
cast send $PORTAL "depositTransaction(address,uint256,uint64,bool,bytes)" \
    $(cast wallet address --private-key $PRIVATE_KEY) \
    0 100000 false "0x" \
    --value 0.01ether \
    --private-key $PRIVATE_KEY \
    --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

Wait ~30 seconds for the deposit to appear on L2.

### Withdraw L2 → L1 (with manual merkle proof)

```bash
./scripts/withdraw-with-proof.sh 0.005ether
```

This script:
1. Initiates withdrawal on L2 via L2ToL1MessagePasser
2. Submits a state root covering the withdrawal block
3. Generates a merkle proof using `eth_getProof`
4. Proves the withdrawal on L1 via OptimismPortal

**Note:** The challenge period is **7 days** (proofMaturityDelaySeconds=604800) plus a finality delay of **3.5 days** (disputeGameFinalityDelaySeconds=302400). These are hardcoded in OPCM and cannot be shortened for production deployments.

After the challenge period (~10.5 days), finalize with:
```bash
cast send $PORTAL 'finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))' \
    '(<nonce>,<sender>,<target>,<value>,<gasLimit>,0x)' \
    --private-key $PRIVATE_KEY \
    --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

## Contract Addresses

| Contract | Address |
|----------|---------|
| OptimismPortal | `0xDf40156F6AC2E57dCdB1b2a2BDA00f740499F909` |
| DisputeGameFactory | `0xb980d58c642a11667bcbafac34d2529df07a8ac4` |
| L1StandardBridge | `0xe69ad7d911b3adb5508cd6ab0625398f7992e003` |
| SystemConfig | `0x594af773714f0623706f57e3a85f8bc39446063f` |
| L2ToL1MessagePasser | `0x4200000000000000000000000000000000000016` |

## L2 Chain Details

| Parameter | Value |
|-----------|-------|
| Chain ID | 16585 |
| L2 RPC | http://localhost:8545 |
| Block time | 2 seconds |
