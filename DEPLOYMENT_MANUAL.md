# THORChain Local Mocknet Manual

Comprehensive reference for the non-forking local THORChain deployment: what it enables, how to bootstrap pools, execute cross-chain swaps, deploy ERC-20 tokens, and extend the setup with new chains and assets.

For installation and basic deployment commands, see [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [What Ships in Genesis](#2-what-ships-in-genesis)
3. [Exchange Rates and Pool Economics](#3-exchange-rates-and-pool-economics)
4. [Pool Bootstrapping](#4-pool-bootstrapping)
5. [Executing Swaps](#5-executing-swaps)
6. [ERC-20 Tokens](#6-erc-20-tokens)
7. [Key Architecture Decisions](#7-key-architecture-decisions)
8. [Extending: New EVM Chains](#8-extending-new-evm-chains)
9. [Extending: New UTXO Chains](#9-extending-new-utxo-chains)
10. [Extending: New ERC-20 Tokens](#10-extending-new-erc-20-tokens)
11. [API Reference](#11-api-reference)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

### Services

```
┌─────────────────────────────────────────────────────────────┐
│  Kurtosis Enclave                                           │
│                                                             │
│  ┌───────────────┐   gRPC :50051    ┌──────────────┐        │
│  │  thorchain-   │◄───────────────►│   bifrost     │        │
│  │  node         │   (eBifrost     │               │        │
│  │               │   attestations) │  Observers:   │        │
│  │  Validator    │                 │   BTC scanner │        │
│  │  API :1317    │                 │   ETH scanner │        │
│  │  RPC :26657   │                 │               │        │
│  │  gRPC :9090   │                 │  Signer:      │        │
│  └──────┬────────┘                 │   THOR scanner│        │
│         │                          │   Signs txs   │        │
│  ┌──────┴────────┐                 └───┬───────┬───┘        │
│  │  thorchain-   │                     │       │            │
│  │  faucet :8090 │                     │       │            │
│  └───────────────┘                     │       │            │
│                              RPC :18443│       │RPC :8545   │
│                          ┌─────────────┘       └──────┐     │
│                          ▼                            ▼     │
│                   ┌───────────┐              ┌───────────┐  │
│                   │ bitcoin   │              │ ethereum  │  │
│                   │ regtest   │              │ (Anvil)   │  │
│                   │           │              │           │  │
│                   │ 101 pre-  │              │ 10 funded │  │
│                   │ mined     │              │ accounts  │  │
│                   │ blocks    │              │ + Router  │  │
│                   └───────────┘              └───────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### How it differs from mainnet

| Aspect | Mainnet | This mocknet |
|---|---|---|
| Validators | 100+ independent nodes | Single validator |
| Key signing | TSS (threshold multi-party) | Direct single-key signing |
| Address prefix | `thor1` | `tthor1` |
| Consensus | BFT with real stake | Instant finality (1s blocks) |
| Chain nodes | Public networks | Local regtest/Anvil |
| Observations | Supermajority quorum | Single observer = immediate quorum |
| Network fees | Observed from real chains | Seeded in genesis |

The core swap logic, pool accounting, fee deduction, and outbound scheduling are **identical to mainnet**. Only the consensus and observation layers are simplified.

---

## 2. What Ships in Genesis

The `single_node_launcher.star` patches genesis with the following state for non-forking mode:

### Validator and Vault

- One `Active` validator node account with `signer_membership` set to the secp256k1 pubkey
- One `ActiveVault` Asgard vault with `chains: [THOR, BTC, ETH]` and `membership: [secp256k1_pubkey]`
- The vault's `routers` field includes the ETH router contract address
- Node `ip_address` set to `bifrost` (Kurtosis DNS)

### MIMIR Values

| Key | Value | Purpose |
|---|---|---|
| `JailTimeKeygen` | 720 | 12 min in blocks; must exceed Bifrost's 5 min keygen timeout |
| `JailTimeKeysign` | 60 | 1 min in blocks |
| `WASMPERMISSIONLESS` | 1 | Allow permissionless WASM deployment |
| `EVMAllowanceCheck-ETH` | 1 | Enable Bifrost auto-approval of router for ERC-20 `transferFrom` |

### Network Fees

| Chain | `transaction_size` | `transaction_fee_rate` | Units |
|---|---|---|---|
| BTC | 250 | 25 | vbytes / sat per vbyte |
| ETH | 80000 | 30 | gas units / gwei |

These seed values allow the outbound pipeline to price gas from block 1. Bifrost overwrites them with observed values once chains are scanned.

### Chain Heights and Contracts

- `last_chain_heights`: BTC=1, ETH=1 (prevents `/thorchain/lastblock` returning null)
- `last_signed_height`: 1
- `chain_contracts`: ETH router at `0x5FbDB2315678afecb367f032d93F642f64180aa3`

---

## 3. Exchange Rates and Pool Economics

### How rates work

THORChain has **no oracle and no configured exchange rate**. All prices are emergent from pool liquidity ratios using the constant product formula (`x * y = k`).

When you create a pool by adding 10 BTC and 100,000 RUNE, you are implicitly setting:

```
1 BTC = 10,000 RUNE
```

Cross-pool swaps chain through RUNE. A BTC→ETH swap is actually BTC→RUNE→ETH, with each leg priced by its respective pool.

### Setting initial rates

You control the exchange rate entirely through **how much asset and RUNE you add** during pool bootstrapping:

| Pool | Asset Added | RUNE Added | Implied Rate |
|---|---|---|---|
| BTC.BTC | 10 BTC | 100,000 RUNE | 1 BTC = 10,000 RUNE |
| ETH.ETH | 100 ETH | 100,000 RUNE | 1 ETH = 1,000 RUNE |
| ETH.USDC | 100,000 USDC | 10,000 RUNE | 1 USDC = 0.1 RUNE |

Cross-pool derived rates from the above:
- 1 BTC ≈ 10 ETH (via 10,000 RUNE / 1,000 RUNE-per-ETH)
- 1 BTC ≈ 100,000 USDC
- 1 ETH ≈ 10,000 USDC

These are **starting** rates. Every swap shifts the ratio, exactly as an AMM does.

### Slippage

The constant product formula means that swap output depends on trade size relative to pool depth. For a swap of amount `x` into a pool with depth `X` (same-side balance):

```
output = (x * Y) / (x + X)
slip    = x / (x + X)
```

Where `Y` is the other side of the pool. Larger trades relative to pool depth produce more slippage. With the example pools above:

| Swap | Input | Pool Depth | Slip | Output |
|---|---|---|---|---|
| 0.1 BTC → RUNE | 0.1 BTC | 10 BTC | ~1% | ~990 RUNE |
| 1.0 BTC → RUNE | 1.0 BTC | 10 BTC | ~9% | ~9,090 RUNE |
| 5.0 BTC → RUNE | 5.0 BTC | 10 BTC | ~33% | ~33,333 RUNE |

Cross-pool swaps apply slippage **twice** (once in each pool), so a BTC→ETH swap on shallow pools has roughly double the slip of a single-pool swap.

### Practical implications for testing

- **Small swaps** (< 1% of pool depth) behave close to the implied exchange rate
- **Large swaps** produce significant slippage — this is by design and matches mainnet behavior
- If you need tighter rates for testing, add more liquidity to the pools
- The pools do **not** rebalance or converge to any external price — arbitrageurs do that on mainnet, but on a local testnet there are no arb bots

### Fees deducted from swaps

Every swap has fees deducted from the output:

1. **Liquidity fee** (slip-based): retained by the pool as LP yield, equals `slip * output`
2. **Outbound fee**: gas cost for the destination chain transaction, deducted from the output coin. Based on the seeded `network_fees` values:
   - BTC outbound: ~6,250 sat (250 vbytes × 25 sat/vbyte)
   - ETH outbound: ~2,400,000 gwei (80,000 gas × 30 gwei), displayed as 240,000 in THORChain 8-decimal units
3. **Affiliate fee**: 0 unless specified in the memo

For small test swaps (e.g., 0.01 BTC → ETH), the outbound fee can be a significant fraction of the output. This matches mainnet behavior where dust swaps are uneconomical.

---

## 4. Pool Bootstrapping

Pools require dual-sided liquidity: an asset deposit (observed by Bifrost on the external chain) paired with a RUNE deposit (MsgDeposit on THORChain).

### Workflow

```
1. Send asset to vault address on external chain with memo:
     ADD:<ASSET>:<THOR_ADDRESS>

2. Wait for Bifrost to observe and THORNode to finalize the inbound
   (check /thorchain/pool/<ASSET> — pending_inbound_asset should be non-zero)

3. Send matching RUNE on THORChain with memo:
     ADD:<ASSET>:<EXTERNAL_SENDER_ADDRESS>

4. Pool activates with balance_asset > 0 and balance_rune > 0
```

The paired address in each memo links the two sides together. The RUNE memo must reference the external address that sent the asset, and the asset memo must reference the THOR address that will send the RUNE.

### BTC.BTC Pool

```bash
# Variables (get from `kurtosis enclave inspect` and /thorchain/inbound_addresses)
VAULT_BTC="bcrt1q..."          # from /thorchain/inbound_addresses, chain=BTC
POOLCREATOR="tthor1..."        # your funded THORChain address
BTC_SENDER="bcrt1q..."         # the BTC address that will send (from your wallet)

# Step 1: Send BTC to vault with OP_RETURN memo
CLI="bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain -rpcwallet=thorchain"
MEMO="ADD:BTC.BTC:$POOLCREATOR"
MEMO_HEX=$(printf '%s' "$MEMO" | od -A n -t x1 | tr -d ' \n')

# Get a spendable UTXO, create raw tx with vault output + OP_RETURN + change
UTXO=$($CLI listunspent 1 | ...)  # pick a spendable UTXO
RAW=$($CLI createrawtransaction \
  "[{\"txid\":\"$TXID\",\"vout\":$VOUT}]" \
  "[{\"$VAULT_BTC\":10.0},{\"data\":\"$MEMO_HEX\"},{\"$CHANGE_ADDR\":$CHANGE}]")
SIGNED=$($CLI signrawtransactionwithwallet "$RAW" | grep '"hex"' | ...)
$CLI sendrawtransaction "$SIGNED"

# Mine blocks for confirmation
$CLI -generate 5

# Step 2: Wait for observation (~15-20 seconds)
curl -s http://127.0.0.1:<API_PORT>/thorchain/pool/BTC.BTC
# Should show pending_inbound_asset > 0

# Step 3: Send matching RUNE (10 BTC paired with 100k RUNE = 1 BTC = 10k RUNE)
thornode tx thorchain deposit 10000000000000 rune \
  "ADD:BTC.BTC:$BTC_SENDER" \
  --from poolcreator --keyring-backend test \
  --chain-id thorchain-localnet --fees 2000000rune --yes
```

### ETH.ETH Pool

ETH deposits go through the router contract's `depositWithExpiry` function:

```bash
VAULT_ETH="0x..."              # from /thorchain/inbound_addresses, chain=ETH
ROUTER="0x5FbDB2315678afecb367f032d93F642f64180aa3"
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Step 1: Deposit ETH through the router
cast send "$ROUTER" \
  "depositWithExpiry(address,address,uint256,string,uint256)" \
  "$VAULT_ETH" "0x0000000000000000000000000000000000000000" \
  "100000000000000000000" \
  "ADD:ETH.ETH:$POOLCREATOR" "$EXPIRY" \
  --value 100000000000000000000 \
  --private-key "$DEPLOYER_KEY" \
  --rpc-url http://localhost:8545

# Step 2: Wait for observation (~15-20 seconds)

# Step 3: Send matching RUNE
thornode tx thorchain deposit 10000000000000 rune \
  "ADD:ETH.ETH:$DEPLOYER_ADDR" \
  --from poolcreator --keyring-backend test \
  --chain-id thorchain-localnet --fees 2000000rune --yes
```

For native ETH deposits: `asset` parameter = zero address, `amount` = `msg.value` (must match exactly, or the router reverts with "TC:eth amount mismatch").

### Common Errors

| Error | Cause | Fix |
|---|---|---|
| `total asset in the pool is zero` | RUNE sent before BTC/ETH observation finalized | Wait for `pending_inbound_asset > 0` before sending RUNE |
| `memo paired address must be non-empty` | RUNE memo missing the external sender address | Include the BTC/ETH sender address in the RUNE deposit memo |
| Pool stays at `pending_inbound_asset` | BTC not confirmed enough or Bifrost not scanning | Mine more BTC blocks; check Bifrost logs for scan progress |

---

## 5. Executing Swaps

### BTC → ETH

```bash
# Send BTC with SWAP memo (OP_RETURN)
MEMO="SWAP:ETH.ETH:0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
# Or abbreviated: "=:ETH.ETH:0x70997..."
# Build raw tx with OP_RETURN as in the pool bootstrap section
```

### ETH → BTC

```bash
# Deposit ETH through the router with SWAP memo
cast send "$ROUTER" \
  "depositWithExpiry(address,address,uint256,string,uint256)" \
  "$VAULT_ETH" "0x0000000000000000000000000000000000000000" \
  "1000000000000000000" \
  "SWAP:BTC.BTC:bcrt1q..." "$EXPIRY" \
  --value 1000000000000000000 \
  --private-key "$DEPLOYER_KEY" \
  --rpc-url http://localhost:8545
```

### ERC-20 → BTC (e.g., USDC → BTC)

```bash
# Approve router first (if not already done)
cast send "$USDC_ADDRESS" "approve(address,uint256)" "$ROUTER" 1000000000000000 \
  --private-key "$KEY" --rpc-url http://localhost:8545

# Deposit ERC-20 through router (msg.value = 0 for ERC-20)
cast send "$ROUTER" \
  "depositWithExpiry(address,address,uint256,string,uint256)" \
  "$VAULT_ETH" "$USDC_ADDRESS" 500000000 \
  "=:BTC.BTC:bcrt1q..." "$EXPIRY" \
  --private-key "$KEY" --rpc-url http://localhost:8545
```

### Monitoring Swap Progress

```bash
# Check swap status (use uppercase TX hash)
curl -s http://127.0.0.1:<API_PORT>/thorchain/tx/status/<TX_HASH> | jq .

# Key stages to watch:
#   inbound_observed.completed    — Bifrost saw the inbound
#   inbound_finalised.completed   — enough confirmations
#   swap_finalised.completed      — pool balances updated
#   outbound_signed.completed     — outbound tx broadcast

# Check outbound queue
curl -s http://127.0.0.1:<API_PORT>/thorchain/queue/outbound | jq .

# Check keysign for a specific block height
curl -s http://127.0.0.1:<API_PORT>/thorchain/keysign/<HEIGHT> | jq .
```

### The Outbound Pipeline

After a swap executes, the outbound follows this path:

```
swap handler
  └─► TryAddTxOutItem()
        ├─ GetGasDetails() — reads network_fees, must be valid
        ├─ prepareTxOutItem() — vault selection, fee deduction, dust check
        ├─ CalcTxOutHeight() — delay based on RUNE value (small swaps = no delay)
        └─ AppendTxOut(height, item) — stored at target block height

Bifrost signer (THOR block scanner)
  └─► GetKeysign(height, pubkey) — polls each new block
        └─ SignTx() — chain-specific signing
              ├─ ERC-20: checkAndApproveAllowance() then transferOut
              └─ BTC: build and sign UTXO transaction

External chain broadcast
  └─► Bifrost observes outbound via MsgObservedTxOut
        └─ vault.SubFunds() — vault balance decremented
```

---

## 6. ERC-20 Tokens

### Token Whitelisting

Bifrost's EVM block scanner has a **compile-time token whitelist** embedded in the binary. Only tokens at whitelisted addresses are recognized during inbound observation. This list cannot be modified at runtime.

The `thornode:mocknet` image includes these whitelisted Ethereum token addresses:

| Address | Symbol | Decimals | Notes |
|---|---|---|---|
| `0xA3910454bF2Cb59b8B3a401589A3bAcC5cA42306` | USDT | 6 | Best choice for USDC/USDT testing |
| `0x6f67873ebc41ed88B08A9265Bd16480f819e4348` | USDT | 6 | Alternative USDT address |
| `0x8E3f9E9b5B26AAaE9d31364d2a8e8a9dd2BE3B82` | TKN18 | 18 | Generic 18-decimal test token |
| `0x52C84043CD9c865236f11d9Fc9F56aa003c1f922` | TKN | 18 | Generic test token |
| `0x3b7FA4dd21c6f9BA3ca375217EAD7CAb9D6bF483` | TKN | 18 | Generic test token |
| `0x983e2cC84Bb8eA7b75685F285A28Bde2b4D5aCDA` | TKN | 18 | Generic test token |
| `0x17aB05351fC94a1a67Bf3f56DdbB941aE6c63E25` | TKN | 18 | Generic test token |
| `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | WBTC | 8 | For wrapped BTC testing |
| `0x0a44986b70527154e9F4290eC14e5f0D1C861823` | WETH | 18 | For wrapped ETH testing |
| `0xd601c6A3a36721320573885A8d8420746dA3d7A0` | RUNE | 18 | Test RUNE ERC-20 |
| `0x4d704dda8099305ee9803f02343129bf6ba55ff1` | RUNE | 18 | Alternative test RUNE |
| `0x6cA13a4ab78dd7D657226b155873A04DB929A3A4` | UST | 18 | Legacy wrapped UST |
| `0x8626DB1a4f9f3e1002EEB9a4f3c6d391436Ffc23` | XRUNE | 18 | XRUNE token |
| `0xe247EFF2915Cb56Ec7a4DB3aE7b923326752E92C` | THOR | 18 | THORSwap token |
| `0x73d6e26896981798526b6ead48d0fab76e205974` | TGT | 18 | THORWallet governance token |
| `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDC | 18 | Note: chainId=56, 18 decimals (not standard USDC) |

### Deploying a Custom ERC-20 at a Whitelisted Address

Since you cannot add new addresses to the whitelist, deploy your custom ERC-20 contract at a temp address, then use Anvil cheatcodes to clone it to a whitelisted address.

```bash
# 1. Compile and deploy to a temporary address
forge build
BYTECODE=$(cat out/MyToken.sol/MyToken.json | grep -o '"bytecode":{"object":"[^"]*"' | ...)
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(uint256)" 1000000000000000)
cast send --private-key $KEY --rpc-url $RPC --create "${BYTECODE}${CONSTRUCTOR_ARGS}"
# → deployed at 0xTEMP_ADDRESS

# 2. Copy runtime code to whitelisted address
TARGET="0xA3910454bF2Cb59b8B3a401589A3bAcC5cA42306"  # whitelisted USDT slot
RUNTIME_CODE=$(cast code $TEMP_ADDRESS --rpc-url $RPC)
cast rpc anvil_setCode "$TARGET" "$RUNTIME_CODE" --rpc-url $RPC

# 3. Copy storage slots (name, symbol, decimals, totalSupply, balances)
for SLOT in 0 1 2 3; do
    VAL=$(cast storage $TEMP_ADDRESS $SLOT --rpc-url $RPC)
    SLOT_HEX=$(printf '0x%064x' $SLOT)
    cast rpc anvil_setStorageAt "$TARGET" "$SLOT_HEX" "$VAL" --rpc-url $RPC
done

# 4. Copy deployer's balance (mapping at slot 4 for Solidity default layout)
BALANCE_SLOT=$(cast keccak256 $(cast abi-encode "x(address,uint256)" $DEPLOYER 4))
BALANCE_VAL=$(cast storage $TEMP_ADDRESS "$BALANCE_SLOT" --rpc-url $RPC)
cast rpc anvil_setStorageAt "$TARGET" "$BALANCE_SLOT" "$BALANCE_VAL" --rpc-url $RPC

# 5. Verify
cast call $TARGET "symbol()(string)" --rpc-url $RPC
cast call $TARGET "balanceOf(address)(uint256)" $DEPLOYER --rpc-url $RPC
```

The THORChain asset identifier for the token will be `ETH.<SYMBOL>-<ADDRESS_UPPERCASE>`, e.g., `ETH.USDC-0XA3910454BF2CB59B8B3A401589A3BACC5CA42306`. Bifrost reads the `symbol()` from the on-chain contract, not from the whitelist JSON.

### Router Approval for ERC-20 Outbounds

The V6 THORChain router uses `transferFrom(vault, dest, amount)` for ERC-20 outbounds, which requires the vault to have approved the router. The `EVMAllowanceCheck-ETH` MIMIR (set to 1 in genesis) enables Bifrost's built-in auto-approval flow:

1. Before each ERC-20 outbound, Bifrost checks the vault's allowance for the router
2. If insufficient, it signs and broadcasts an `approve(router, maxUint256)` transaction
3. The approval must be mined before gas estimation succeeds
4. If gas estimation fails (approval not yet mined), the outbound is skipped and rescheduled after `SigningTransactionPeriod` (300 blocks)
5. On the next attempt, the approval is on-chain and the outbound goes through

This means the **first ERC-20 outbound for a new token may take ~300 extra blocks** (5 minutes at 1s/block) while the approval is mined. Subsequent outbounds for the same token are instant.

### OP_RETURN Memo Size for BTC Swaps

Bitcoin OP_RETURN payloads default to 80 bytes. ERC-20 asset names like `ETH.USDC-0XA3910454BF2CB59B8B3A401589A3BACC5CA42306` are 52 characters, plus a destination ETH address (42 chars), plus the `=:` prefix — totaling ~96 bytes. This exceeds the 80-byte limit.

The Bitcoin launcher does **not** increase `-datacarriersize` — it uses the default 80-byte limit, matching mainnet Bitcoin Core behavior. Aggregators must abbreviate contract addresses in swap memos to fit. THORChain supports fuzzy matching of abbreviated asset identifiers to the deepest pool:

- `ETH.USDC-0xA3910454BF2CB59B8B3A401589A3BACC5CA42306` → `ETH.USDC` (ticker-only, resolves to deepest USDC pool)
- `ETH.USDC-2306` (last 4 hex chars, for disambiguation when multiple pools share a ticker)
- `SWAP:` → `=:` or `s:` (action shorthand)
- Native assets: `ETH.ETH` → `e`, `BTC.BTC` → `b` (THORChain shorthand codes)

> **Future work**: Expose `-datacarriersize` as a configurable parameter in `bitcoin_launcher.star` (default: leave unset, matching Bitcoin Core's 83-byte / 80-byte-payload default). This would allow developers to opt in to a higher limit for testing without memo abbreviation, while keeping the default aligned with mainnet behavior.

---

## 7. Key Architecture Decisions

### Network Fees in Genesis

**Problem**: THORNode's `prepareTxOutItem()` calls `GetGasDetails(chain)` which requires a valid `NetworkFee` record (both `TransactionSize > 0` and `TransactionFeeRate > 0`). On a fresh chain with no Bifrost observations, this call fails, preventing **all** L1 outbounds from being created.

**Symptom**: Swaps execute (pool balances change) but `out_txs` is null, `/thorchain/queue/outbound` is empty, and `/thorchain/keysign/{height}` returns no items.

**Fix**: Seed `network_fees` in genesis (in `single_node_launcher.star`). Bifrost overwrites these with observed values once it scans chain blocks.

### EVMAllowanceCheck MIMIR

**Problem**: The V6 router's `transferOut()` for ERC-20 tokens calls `token.transferFrom(vault, dest, amount)`. The vault must have approved the router. Bifrost has built-in approval logic in `checkAndApproveAllowance()` but it's gated behind `EVMAllowanceCheck-{CHAIN}` (off by default).

**Symptom**: Bifrost logs show `"execution reverted: TC:transfer failed"` during gas estimation. The outbound is skipped and rescheduled repeatedly.

**Fix**: Set `EVMAllowanceCheck-ETH: 1` in genesis MIMIRs.

### eBifrost gRPC (Port 50051)

THORChain v3.x replaced legacy `MsgObservedTxIn` broadcasts with attestation-based gRPC. The eBifrost gRPC server runs inside **thornode** (not Bifrost) on port 50051. Bifrost connects as a client to submit observations.

The server must bind to `0.0.0.0:50051` (not `localhost`) for cross-container access. This is set via `sed` in `app.toml` during genesis setup.

Bifrost env var: `BIFROST_THORCHAIN_CHAIN_EBIFROST=thorchain-node:50051`

### File Keyring

THORNode's keysign endpoint requires the validator key in the **file-based keyring** (not the test keyring). The key must be named `thorchain`. During genesis setup:

```bash
(echo '<mnemonic>'; echo 'TestPassword!'; echo 'TestPassword!') | \
  thornode keys add thorchain --recover --keyring-backend file
```

The thornode start command also references this key:
```bash
printf 'thorchain\nTestPassword!\n' | thornode start
```

### Signer Block Scanner Start Height

`BIFROST_SIGNER_BLOCK_SCANNER_START_BLOCK_HEIGHT=0` tells the signer to start from the latest observed height (from `/thorchain/lastblock`). Setting this to `1` would cause the signer to scan from block 1, taking minutes to catch up on a chain that has been running.

### Single-Validator Simplifications

With one validator, `signer_membership` in the genesis vault is `[secp256k1_pubkey]` — a list containing just the validator's public key. This means:

- No TSS keygen ceremony is needed
- Bifrost signs outbounds directly with the validator's key
- Observation quorum is reached immediately (1 of 1)
- No key rotation or vault migration

---

## 8. Extending: New EVM Chains

To add support for an additional EVM chain (e.g., AVAX, BSC, BASE):

### Checklist

1. **Create a launcher** (`src/<chain>/<chain>_launcher.star`):
   - Start an Anvil instance for the chain
   - Deploy the THORChain router contract (same bytecode as ETH)
   - Return the service name, RPC URL, and router address

2. **Update `bifrost_launcher.star`**:
   - Remove the `BIFROST_CHAINS_<CHAIN>_DISABLED=true` env var
   - Add `BIFROST_CHAINS_<CHAIN>_RPC_HOST=<chain_service>:8545`

3. **Update `single_node_launcher.star` genesis patching**:
   - Add the chain to `vault_chains` list
   - Add `chain_contracts` entry with the router address
   - Add `vault_routers` entry
   - Add `network_fees` entry (e.g., `{"chain": "AVAX", "transaction_size": "80000", "transaction_fee_rate": "30"}`)
   - Add `last_chain_heights` entry (e.g., `{"chain": "AVAX", "height": "1"}`)
   - Add `EVMAllowanceCheck-<CHAIN>: 1` to MIMIR defaults (if ERC-20 swaps needed)

4. **Update `main.star`**:
   - Add a config flag (e.g., `avax_enabled`)
   - Call the new launcher
   - Pass chain info to Bifrost launcher

5. **Update `examples/bifrost-no-fork.yaml`**:
   - Add the `<chain>_enabled: true` flag

6. **Router deployment**: The THORChain router bytecode in `src/ethereum/router-bytecode.txt` is chain-agnostic. Deploy it the same way on any EVM chain.

### EVM chain Bifrost env var patterns

```
BIFROST_CHAINS_<CHAIN>_RPC_HOST=<host>:<port>
BIFROST_CHAINS_<CHAIN>_BLOCK_SCANNER_START_BLOCK_HEIGHT=0
BIFROST_CHAINS_<CHAIN>_DISABLED=true/false
```

The chain identifiers used by Bifrost match THORChain's chain constants: `ETH`, `AVAX`, `BSC`, `BASE`, `POL`.

---

## 9. Extending: New UTXO Chains

To add support for DOGE, LTC, or BCH:

### Checklist

1. **Create a launcher** (`src/<chain>/<chain>_launcher.star`):
   - Start a regtest node for the chain (e.g., `dogecoin` Docker image)
   - Configure RPC credentials
   - Create a wallet and mine initial blocks
   - Bitcoin-like chains need `-deprecatedrpc=create_bdb` for legacy wallet support (if v26+ based)
   - Note: Bitcoin Core defaults to 80-byte OP_RETURN (matching mainnet). Aggregators must abbreviate ERC-20 contract addresses in swap memos. See [§6 OP_RETURN Memo Size](#op_return-memo-size-for-btc-swaps).

2. **Update `bifrost_launcher.star`**:
   - Remove `<CHAIN>_DISABLED=true` (e.g., `DOGE_DISABLED`)
   - Add RPC host, username, password env vars:
     ```
     BIFROST_CHAINS_<CHAIN>_RPC_HOST=<host>:<port>/wallet/<wallet_name>
     BIFROST_CHAINS_<CHAIN>_USERNAME=<user>
     BIFROST_CHAINS_<CHAIN>_PASSWORD=<pass>
     BIFROST_CHAINS_<CHAIN>_HTTP_POST_MODE=1
     BIFROST_CHAINS_<CHAIN>_DISABLE_TLS=1
     ```

3. **Update genesis** (same pattern as BTC):
   - Add to `vault_chains`
   - Add `network_fees` entry with appropriate `transaction_size` and `transaction_fee_rate`
   - Add `last_chain_heights` entry

4. **Update `main.star`** and config YAML.

### Chain-specific notes

| Chain | Regtest flag | Default RPC port | Wallet quirks |
|---|---|---|---|
| DOGE | `-regtest` | 18332 | Uses `dogecoin-cli` |
| LTC | `-regtest` | 18332 | Uses `litecoin-cli` |
| BCH | `-regtest` | 18332 | Uses `bitcoin-cli` (BCH fork), different address format |

---

## 10. Extending: New ERC-20 Tokens

### Using an existing whitelisted address

This is the fastest approach. Pick an unused address from the [whitelist table](#token-whitelisting), deploy your ERC-20 to a temp address, then clone it using `anvil_setCode` and `anvil_setStorageAt` (see [Section 6](#deploying-a-custom-erc-20-at-a-whitelisted-address)).

### Building a custom thornode image

For testing with arbitrary token addresses (not in the whitelist):

1. Clone the thornode repo: `git clone https://gitlab.com/thorchain/thornode.git`
2. Edit `common/tokenlist/ethtokens/eth_mocknet_latest.json`:
   ```json
   {
     "chainId": 4,
     "address": "0xYOUR_TOKEN_ADDRESS",
     "symbol": "MYTKN",
     "name": "My Test Token",
     "decimals": 18,
     "tags": []
   }
   ```
3. Build the Docker image:
   ```bash
   make docker-gitlab-build
   # or
   docker build -t thornode:custom-mocknet --build-arg TAG=mocknet .
   ```
4. Reference your custom image in `examples/bifrost-no-fork.yaml`:
   ```yaml
   participants:
     - image: "thornode:custom-mocknet"
   ```

### Multiple tokens on the same chain

You can deploy multiple ERC-20 tokens, each at a different whitelisted address. Each needs its own pool (separate `ADD:<ASSET>` + RUNE deposits). Cross-pool swaps between tokens work through RUNE: `TOKEN_A → RUNE → TOKEN_B`.

---

## 11. API Reference

### THORNode Endpoints

| Endpoint | Description |
|---|---|
| `GET /thorchain/inbound_addresses` | Vault addresses, gas rates, halt status per chain |
| `GET /thorchain/pools` | All pools with balances, units, status |
| `GET /thorchain/pool/{asset}` | Single pool detail |
| `GET /thorchain/tx/{hash}` | Observation detail for an inbound TX |
| `GET /thorchain/tx/status/{hash}` | Full lifecycle: stages, planned/actual outbounds |
| `GET /thorchain/queue` | Swap queue depth, outbound counts, scheduled value |
| `GET /thorchain/queue/outbound` | Pending outbound items with height, vault, coin |
| `GET /thorchain/keysign/{height}` | TxOut items assigned to a block for signing |
| `GET /thorchain/keysign/{height}/{pubkey}` | Filtered by vault pubkey |
| `GET /thorchain/nodes` | Validator node accounts, status, bond |
| `GET /thorchain/vaults/asgard` | Asgard vault state: coins, chains, routers |
| `GET /thorchain/mimir` | Active MIMIR key-value overrides |
| `GET /thorchain/lastblock` | Last observed chain heights |
| `GET /thorchain/constants` | Protocol constants (non-MIMIR defaults) |
| `POST /thorchain/deposit` | Not used directly; use `thornode tx thorchain deposit` CLI |

### Cosmos SDK Endpoints

| Endpoint | Description |
|---|---|
| `GET /cosmos/bank/v1beta1/balances/{address}` | RUNE balance for a THORChain address |
| `GET /cosmos/tx/v1beta1/txs/{hash}` | Transaction result with code and raw_log |

### Bitcoin RPC

```bash
# All commands need: -regtest -rpcuser=thorchain -rpcpassword=thorchain
# For wallet operations add: -rpcwallet=thorchain
bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain -rpcwallet=thorchain <command>

# Useful commands:
getblockchaininfo        # chain height, verification progress
listunspent              # spendable UTXOs
getnewaddress            # generate a receive address
-generate <n>            # mine n blocks
sendrawtransaction <hex> # broadcast a signed transaction
```

### Ethereum (Anvil) RPC

```bash
# Anvil standard JSON-RPC at http://<host>:8545
# Foundry's `cast` tool is available inside the ethereum container

cast block-number --rpc-url http://localhost:8545
cast balance <address> --rpc-url http://localhost:8545 --ether
cast call <contract> "symbol()(string)" --rpc-url http://localhost:8545
cast send <to> "function(args)" --private-key <key> --rpc-url http://localhost:8545

# Anvil cheatcodes (useful for testing):
cast rpc anvil_setCode <address> <bytecode> --rpc-url http://localhost:8545
cast rpc anvil_setStorageAt <address> <slot> <value> --rpc-url http://localhost:8545
cast rpc anvil_mine <blocks> --rpc-url http://localhost:8545
cast rpc anvil_setBalance <address> <wei_hex> --rpc-url http://localhost:8545
```

### Router Contract ABI (Key Functions)

```solidity
// Native ETH deposit (msg.value must equal amount)
function depositWithExpiry(
    address payable vault,
    address asset,       // 0x0 for native ETH
    uint256 amount,
    string memory memo,
    uint256 expiry
) external payable;

// ERC-20 deposit (caller must have approved router)
// Same function, but asset = token address, msg.value = 0

// Outbound transfer (called by Bifrost via vault's signed tx)
function transferOut(
    address payable to,
    address asset,
    uint256 amount,
    string memory memo
) public payable;
```

Router address (deterministic, deployed from Anvil account 0 at nonce 0):
`0x5FbDB2315678afecb367f032d93F642f64180aa3`

---

## 12. Troubleshooting

### "token: 0x... is not whitelisted"

**Cause**: The ERC-20 token contract is not at a whitelisted address in Bifrost's compiled token list.

**Fix**: Deploy your token at one of the [whitelisted addresses](#token-whitelisting) using the `anvil_setCode` cloning pattern. See [Section 6](#deploying-a-custom-erc-20-at-a-whitelisted-address).

### "execution reverted: TC:transfer failed"

**Cause**: The `EVMAllowanceCheck-ETH` MIMIR is not set. Bifrost skips the router approval step, so the vault has zero allowance for the router to call `transferFrom`.

**Fix**: Ensure `EVMAllowanceCheck-ETH: 1` is in genesis MIMIRs. If the MIMIR was missing at deploy time, set it at runtime:
```bash
thornode tx thorchain mimir "EVMAllowanceCheck-ETH" 1 \
  --from validator --keyring-backend test \
  --chain-id thorchain-localnet --fees 2000000rune --yes
```
The existing outbound will be rescheduled after 300 blocks (~5 min) and succeed on retry.

### "network fee for chain(X) is invalid"

**Cause**: No `network_fees` entry for the chain in genesis. `GetGasDetails()` fails and no outbound can be created.

**Fix**: Add a `network_fees` entry in the genesis patching section of `single_node_launcher.star`. Both `transaction_size` and `transaction_fee_rate` must be greater than zero.

### Outbound scheduled but never signed

**Check**: Look at Bifrost logs for errors during signing:
```bash
docker logs <bifrost_container> 2>&1 | grep -i "ERR.*sign\|fail.*sign\|revert"
```

**Common causes**:
- Router not deployed (check `chain_contracts` in genesis)
- Vault has insufficient balance of the outbound asset
- Gas estimation failure (check for revert messages)
- Bifrost signer scanner not caught up (check `gap=` values in scan logs)

### OP_RETURN too long (BTC memo rejected)

**Cause**: Bitcoin Core's default `-datacarriersize` is 83 bytes (80 payload). ERC-20 asset names in swap memos can exceed this.

**Fix**: The Bitcoin launcher uses the default 80-byte OP_RETURN limit (matching mainnet). Aggregators must abbreviate ERC-20 contract addresses in swap memos — THORChain resolves abbreviated identifiers via fuzzy matching to the deepest pool. See [§6 OP_RETURN Memo Size](#op_return-memo-size-for-btc-swaps) for abbreviation strategies. You can also use memo action shorthands:
- `SWAP:` → `=:` or `s:`
- `ADD:` → `+:` or `a:`

### Pool stays at pending_inbound_asset forever

**Cause**: The asset-side inbound was observed but the RUNE deposit either failed or used the wrong paired address.

**Fix**: Check the RUNE deposit transaction result:
```bash
curl -s http://127.0.0.1:<API_PORT>/cosmos/tx/v1beta1/txs/<RUNE_TX_HASH> | jq .tx_response.raw_log
```
Ensure the memo includes the correct external sender address (the address that sent BTC/ETH, not the vault address).

### Bifrost shows "not active" for network fee attestation

This is expected on a single-validator mocknet. The `skipping attest network fee: not active` message means Bifrost is not participating in network fee consensus (it uses the genesis-seeded values instead). This does not affect functionality.

### First ERC-20 outbound takes ~5 minutes

This is expected behavior. The first ERC-20 outbound for a new token triggers the auto-approval flow: Bifrost signs and broadcasts an `approve(router, maxUint256)` transaction, but gas estimation for the outbound fails because the approval isn't mined yet. The outbound is rescheduled after `SigningTransactionPeriod` (300 blocks). On the next attempt, the approval is on-chain and the outbound succeeds immediately. All subsequent outbounds for that token are instant.
