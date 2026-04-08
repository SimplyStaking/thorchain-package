#!/usr/bin/env bash
#
# Bootstrap liquidity pools on a local THORChain mocknet.
#
# Deploys ERC-20 USDC, then bootstraps BTC.BTC, ETH.ETH, and ETH.USDC pools
# with dual-sided liquidity so cross-chain swaps work immediately.
#
# Usage:
#   ./scripts/bootstrap-pools.sh [ENCLAVE_NAME]
#
# Default enclave name: thorchain-testnet
#
# Prerequisites:
#   - Kurtosis enclave running with bifrost-no-fork.yaml config
#   - cast (foundry) installed locally
#   - curl, python3, jq available
#
# Pool ratios (determines exchange rates):
#   BTC.BTC:  10 BTC   = 100,000 RUNE  → 1 BTC  = 10,000 RUNE
#   ETH.ETH:  100 ETH  = 100,000 RUNE  → 1 ETH  = 1,000 RUNE
#   ETH.USDC: 100k USDC = 100,000 RUNE → 1 USDC = 1 RUNE
#
# Cross-pool rates (via RUNE):
#   1 BTC  = 10 ETH
#   1 BTC  = 100,000 USDC
#   1 ETH  = 10,000 USDC

set -euo pipefail

ENCLAVE="${1:-thorchain-testnet}"
CLI="bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain -rpcwallet=thorchain"

# Anvil deployer (account 0 from default mnemonic)
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Whitelisted USDC address in Bifrost's mocknet token list
USDC_TARGET="0xA3910454bF2Cb59b8B3a401589A3bAcC5cA42306"

# Pool sizing (in base units)
BTC_AMOUNT="10.00000000"       # 10 BTC
BTC_RUNE="10000000000000"      # 100k RUNE (1e8 base)
ETH_AMOUNT="100000000000000000000"  # 100 ETH (wei)
ETH_RUNE="10000000000000"      # 100k RUNE
USDC_AMOUNT="100000000000"     # 100k USDC (6 decimals)
USDC_RUNE="10000000000000"     # 100k RUNE

# ─── Helper functions ───────────────────────────────────────────────────────

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; }

kexec() {
    local svc="$1"; shift
    local container
    container=$(docker ps --filter "name=${svc}--" --format '{{.ID}}' | head -1)
    if [ -z "$container" ]; then
        err "Container for service '$svc' not found"
        return 1
    fi
    # Pipe "y" to stdin for commands that prompt for confirmation (e.g. thornode keys add).
    # Harmless on macOS Docker Desktop where no prompt appears — the extra input is ignored.
    echo "y" | docker exec -i "$container" sh -c "$*" 2>&1
}

# Get a mapped host port for a service
get_port() {
    local svc="$1" port_name="$2"
    kurtosis enclave inspect "$ENCLAVE" 2>&1 \
        | grep "^[a-f0-9]" \
        | grep "$svc" \
        | grep -oE "${port_name}: [0-9]+/tcp -> 127\.0\.0\.1:[0-9]+" \
        | grep -oE '[0-9]+$'
}

wait_for_observation() {
    local pool="$1" field="$2" max_wait="${3:-60}"
    local i=0
    while [ $i -lt $max_wait ]; do
        local val
        val=$(curl -sf "$API/thorchain/pool/$pool" 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('$field','0'))" 2>/dev/null || echo "0")
        if [ "$val" != "0" ] && [ -n "$val" ]; then
            ok "$pool $field = $val"
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    err "Timeout waiting for $pool $field (${max_wait}s)"
    return 1
}

wait_for_pool_active() {
    local pool="$1" max_wait="${2:-30}"
    local i=0
    while [ $i -lt $max_wait ]; do
        local asset rune
        asset=$(curl -sf "$API/thorchain/pool/$pool" 2>/dev/null \
            | python3 -c "import json,sys; p=json.load(sys.stdin); print(p.get('balance_asset','0'))" 2>/dev/null || echo "0")
        rune=$(curl -sf "$API/thorchain/pool/$pool" 2>/dev/null \
            | python3 -c "import json,sys; p=json.load(sys.stdin); print(p.get('balance_rune','0'))" 2>/dev/null || echo "0")
        if [ "$asset" != "0" ] && [ "$rune" != "0" ]; then
            ok "$pool active: asset=$asset rune=$rune"
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    err "Timeout waiting for $pool activation (${max_wait}s)"
    return 1
}

# Send BTC to vault with OP_RETURN memo. Prints "txid sender_address" on stdout.
send_btc_with_memo() {
    local vault="$1" amount="$2" memo="$3"
    local memo_hex
    memo_hex=$(printf '%s' "$memo" | od -A n -t x1 | tr -d ' \n')

    # Get largest UTXO
    local utxo_json txid vout utxo_amount sender change change_addr
    utxo_json=$(kexec bitcoin "$CLI listunspent 1 9999999" \
        | python3 -c "
import json, sys
utxos = json.load(sys.stdin)
utxos.sort(key=lambda x: float(x['amount']), reverse=True)
u = utxos[0]
print(json.dumps({'txid': u['txid'], 'vout': u['vout'], 'amount': float(u['amount']), 'address': u['address']}))")
    txid=$(echo "$utxo_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['txid'])")
    vout=$(echo "$utxo_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['vout'])")
    utxo_amount=$(echo "$utxo_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['amount'])")
    sender=$(echo "$utxo_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['address'])")
    change=$(python3 -c "print(f'{$utxo_amount - $amount - 0.0001:.8f}')")
    change_addr=$(kexec bitcoin "$CLI getnewaddress" | tr -d '[:space:]')

    local raw signed hex btc_txid
    raw=$(kexec bitcoin "$CLI createrawtransaction '[{\"txid\":\"$txid\",\"vout\":$vout}]' '[{\"$vault\":$amount},{\"data\":\"$memo_hex\"},{\"$change_addr\":$change}]'" | tr -d '[:space:]')
    signed=$(kexec bitcoin "$CLI signrawtransactionwithwallet $raw")
    hex=$(echo "$signed" | python3 -c "import json,sys; print(json.load(sys.stdin)['hex'])")
    btc_txid=$(kexec bitcoin "$CLI sendrawtransaction $hex" | tr -d '[:space:]')

    # Mine to confirm
    kexec bitcoin "$CLI -generate 5" >/dev/null

    echo "$btc_txid $sender"
}

# ─── Resolve ports ──────────────────────────────────────────────────────────

log "Resolving service ports for enclave '$ENCLAVE'"

API_PORT=$(get_port "thorchain-node" "api")
FAUCET_PORT=$(get_port "thorchain-faucet" "api")
ETH_PORT=$(get_port "ethereum" "rpc")

if [ -z "$API_PORT" ] || [ -z "$FAUCET_PORT" ] || [ -z "$ETH_PORT" ]; then
    err "Could not resolve all ports. Is the enclave running?"
    echo "  API_PORT=$API_PORT FAUCET_PORT=$FAUCET_PORT ETH_PORT=$ETH_PORT"
    exit 1
fi

API="http://127.0.0.1:$API_PORT"
FAUCET="http://127.0.0.1:$FAUCET_PORT"
ETH_RPC="http://127.0.0.1:$ETH_PORT"

ok "THORNode API: $API"
ok "Faucet: $FAUCET"
ok "Ethereum RPC: $ETH_RPC"

# ─── Get vault addresses ────────────────────────────────────────────────────

log "Fetching vault addresses"

INBOUND=$(curl -sf "$API/thorchain/inbound_addresses")
BTC_VAULT=$(echo "$INBOUND" | python3 -c "import json,sys; addrs=json.load(sys.stdin); print([a['address'] for a in addrs if a['chain']=='BTC'][0])")
ETH_VAULT=$(echo "$INBOUND" | python3 -c "import json,sys; addrs=json.load(sys.stdin); print([a['address'] for a in addrs if a['chain']=='ETH'][0])")
ROUTER=$(echo "$INBOUND" | python3 -c "import json,sys; addrs=json.load(sys.stdin); print([a['router'] for a in addrs if a['chain']=='ETH'][0])")

ok "BTC vault: $BTC_VAULT"
ok "ETH vault: $ETH_VAULT"
ok "Router: $ROUTER"

# ─── Create pool creator account ────────────────────────────────────────────

log "Creating pool creator account"

POOLCREATOR_JSON=$(kexec thorchain-node "thornode keys add poolcreator --keyring-backend test --output json 2>&1")
POOLCREATOR=$(echo "$POOLCREATOR_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['address'])")

ok "Pool creator: $POOLCREATOR"

# Fund it
curl -sf -X POST "$FAUCET/fund" -H "Content-Type: application/json" \
    -d "{\"address\": \"$POOLCREATOR\", \"amount\": 500000000000000}" >/dev/null
sleep 6
ok "Funded with 500k RUNE"

# ─── Deploy USDC ERC-20 ────────────────────────────────────────────────────

log "Deploying USDC ERC-20 token"

# Pre-compiled USDC contract: uses Anvil RPC to inject bytecode + storage directly.
# This avoids needing `forge` (which may be unavailable or killed on some hosts).
# The bytecode is from a minimal ERC-20 with: name="USD Coin", symbol="USDC",
# decimals=6, totalSupply=1e15 (1B USDC), all minted to deployer (account 0).
#
# If `forge` is available, use it for a fresh compile. Otherwise fall back to
# direct Anvil state injection with pre-computed values.

# Prefer pre-compiled bytecode when available — it's faster and avoids forge/solc
# issues on servers with security policies that block or hang on compilation.
# Only fall back to forge if the hex file is missing.
_precompiled="$(dirname "$0")/../data/usdc-runtime.hex"
if [ -f "$_precompiled" ] && [ -s "$_precompiled" ]; then
    _forge_ok=false
elif command -v forge &>/dev/null && forge --version &>/dev/null; then
    _forge_ok=true
else
    _forge_ok=false
fi
if [ "$_forge_ok" = true ]; then
    # ── Forge available: compile and deploy, then clone to target ──
    USDC_SOL=$(mktemp /tmp/USDC.XXXXX.sol)
    cat > "$USDC_SOL" << 'SOLEOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
contract USDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    constructor() {
        totalSupply = 1000000000 * 10**6;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
SOLEOF
    TEMP_ADDR=$(forge create "$USDC_SOL:USDC" \
        --private-key "$DEPLOYER_KEY" \
        --rpc-url "$ETH_RPC" \
        --broadcast 2>&1 | grep "Deployed to:" | awk '{print $3}')
    rm -f "$USDC_SOL"
    if [ -z "$TEMP_ADDR" ]; then
        err "Failed to deploy USDC contract via forge"
        exit 1
    fi
    ok "Temp USDC at $TEMP_ADDR"

    RUNTIME_CODE=$(cast code "$TEMP_ADDR" --rpc-url "$ETH_RPC")
    cast rpc anvil_setCode "$USDC_TARGET" "$RUNTIME_CODE" --rpc-url "$ETH_RPC" >/dev/null
    for SLOT in 0 1 2 3; do
        VAL=$(cast storage "$TEMP_ADDR" "$SLOT" --rpc-url "$ETH_RPC")
        cast rpc anvil_setStorageAt "$USDC_TARGET" "$(printf '0x%064x' $SLOT)" "$VAL" --rpc-url "$ETH_RPC" >/dev/null
    done
    BALANCE_SLOT=$(cast index address "$DEPLOYER_ADDR" 4)
    BAL_VAL=$(cast storage "$TEMP_ADDR" "$BALANCE_SLOT" --rpc-url "$ETH_RPC")
    cast rpc anvil_setStorageAt "$USDC_TARGET" "$BALANCE_SLOT" "$BAL_VAL" --rpc-url "$ETH_RPC" >/dev/null
else
    # ── No forge: inject pre-compiled bytecode directly via Anvil RPC ──
    ok "forge unavailable — using pre-compiled USDC bytecode"

    # Runtime bytecode (compiled from the contract above with solc 0.8.x)
    RUNTIME_CODE=$(cat "$(dirname "$0")/../data/usdc-runtime.hex" 2>/dev/null || echo "")
    if [ -z "$RUNTIME_CODE" ]; then
        err "Pre-compiled USDC bytecode not found at data/usdc-runtime.hex"
        err "Generate it: forge inspect USDC.sol:USDC deployedBytecode > data/usdc-runtime.hex"
        exit 1
    fi

    cast rpc anvil_setCode "$USDC_TARGET" "$RUNTIME_CODE" --rpc-url "$ETH_RPC" >/dev/null

    # Storage layout:
    #   slot 0: name   = "USD Coin" (short string encoding)
    #   slot 1: symbol = "USDC"     (short string encoding)
    #   slot 2: decimals = 6
    #   slot 3: totalSupply = 1000000000 * 10^6 = 1e15
    #   slot keccak256(deployer, 4): balanceOf[deployer] = totalSupply
    cast rpc anvil_setStorageAt "$USDC_TARGET" "0x0000000000000000000000000000000000000000000000000000000000000000" "0x55534420436f696e000000000000000000000000000000000000000000000010" --rpc-url "$ETH_RPC" >/dev/null
    cast rpc anvil_setStorageAt "$USDC_TARGET" "0x0000000000000000000000000000000000000000000000000000000000000001" "0x5553444300000000000000000000000000000000000000000000000000000008" --rpc-url "$ETH_RPC" >/dev/null
    cast rpc anvil_setStorageAt "$USDC_TARGET" "0x0000000000000000000000000000000000000000000000000000000000000002" "0x0000000000000000000000000000000000000000000000000000000000000006" --rpc-url "$ETH_RPC" >/dev/null
    cast rpc anvil_setStorageAt "$USDC_TARGET" "0x0000000000000000000000000000000000000000000000000000000000000003" "0x00000000000000000000000000000000000000000000000000038d7ea4c68000" --rpc-url "$ETH_RPC" >/dev/null

    BALANCE_SLOT=$(cast index address "$DEPLOYER_ADDR" 4)
    cast rpc anvil_setStorageAt "$USDC_TARGET" "$BALANCE_SLOT" "0x00000000000000000000000000000000000000000000000000038d7ea4c68000" --rpc-url "$ETH_RPC" >/dev/null
fi

# Verify
USDC_SYM=$(cast call "$USDC_TARGET" "symbol()(string)" --rpc-url "$ETH_RPC")
USDC_DEC=$(cast call "$USDC_TARGET" "decimals()(uint8)" --rpc-url "$ETH_RPC")
ok "USDC deployed at $USDC_TARGET ($USDC_SYM, $USDC_DEC decimals)"

# ─── Bootstrap BTC.BTC pool ─────────────────────────────────────────────────

log "Bootstrapping BTC.BTC pool (10 BTC + 100k RUNE)"

BTC_RESULT=$(send_btc_with_memo "$BTC_VAULT" "$BTC_AMOUNT" "ADD:BTC.BTC:$POOLCREATOR")
BTC_TXID=$(echo "$BTC_RESULT" | awk '{print $1}')
BTC_SENDER=$(echo "$BTC_RESULT" | awk '{print $2}')
ok "BTC sent: $BTC_TXID (sender: $BTC_SENDER)"

wait_for_observation "BTC.BTC" "pending_inbound_asset" 60

kexec thorchain-node "thornode tx thorchain deposit $BTC_RUNE rune 'ADD:BTC.BTC:$BTC_SENDER' --from poolcreator --keyring-backend test --chain-id thorchain-localnet --fees 2000000rune --yes --broadcast-mode sync" >/dev/null
ok "RUNE deposit sent"

wait_for_pool_active "BTC.BTC" 30

# ─── Bootstrap ETH.ETH pool ────────────────────────────────────────────────

log "Bootstrapping ETH.ETH pool (100 ETH + 100k RUNE)"

EXPIRY=$(python3 -c "import time; print(int(time.time()) + 3600)")

cast send "$ROUTER" \
    "depositWithExpiry(address,address,uint256,string,uint256)" \
    "$ETH_VAULT" "0x0000000000000000000000000000000000000000" \
    "$ETH_AMOUNT" "ADD:ETH.ETH:$POOLCREATOR" "$EXPIRY" \
    --value "$ETH_AMOUNT" \
    --private-key "$DEPLOYER_KEY" \
    --rpc-url "$ETH_RPC" >/dev/null 2>&1
ok "ETH deposit sent"

wait_for_observation "ETH.ETH" "pending_inbound_asset" 60

kexec thorchain-node "thornode tx thorchain deposit $ETH_RUNE rune 'ADD:ETH.ETH:$DEPLOYER_ADDR' --from poolcreator --keyring-backend test --chain-id thorchain-localnet --fees 2000000rune --yes --broadcast-mode sync" >/dev/null
ok "RUNE deposit sent"

wait_for_pool_active "ETH.ETH" 30

# ─── Bootstrap ETH.USDC pool ───────────────────────────────────────────────

log "Bootstrapping ETH.USDC pool (100k USDC + 100k RUNE)"

USDC_ASSET="ETH.USDC-0xA3910454BF2CB59B8B3A401589A3BACC5CA42306"
EXPIRY=$(python3 -c "import time; print(int(time.time()) + 3600)")

# Approve router
cast send "$USDC_TARGET" "approve(address,uint256)" "$ROUTER" "1000000000000000" \
    --private-key "$DEPLOYER_KEY" --rpc-url "$ETH_RPC" >/dev/null 2>&1

# Deposit USDC through router
cast send "$ROUTER" \
    "depositWithExpiry(address,address,uint256,string,uint256)" \
    "$ETH_VAULT" "$USDC_TARGET" "$USDC_AMOUNT" \
    "ADD:$USDC_ASSET:$POOLCREATOR" "$EXPIRY" \
    --private-key "$DEPLOYER_KEY" \
    --rpc-url "$ETH_RPC" >/dev/null 2>&1
ok "USDC deposit sent"

wait_for_observation "$USDC_ASSET" "pending_inbound_asset" 60

kexec thorchain-node "thornode tx thorchain deposit $USDC_RUNE rune 'ADD:$USDC_ASSET:$DEPLOYER_ADDR' --from poolcreator --keyring-backend test --chain-id thorchain-localnet --fees 2000000rune --yes --broadcast-mode sync" >/dev/null
ok "RUNE deposit sent"

wait_for_pool_active "$USDC_ASSET" 30

# ─── Summary ────────────────────────────────────────────────────────────────

log "Pool bootstrapping complete!"

echo ""
echo "Pools:"
curl -sf "$API/thorchain/pools" | python3 -c "
import json, sys
pools = json.load(sys.stdin)
for p in pools:
    if p['status'] == 'Available':
        asset = int(p['balance_asset'])
        rune = int(p['balance_rune'])
        print(f\"  {p['asset']}: asset={asset:,} rune={rune:,}\")
"

MIDGARD_PORT=$(get_port "thorchain-midgard" "api" 2>/dev/null || true)
BTC_PORT=$(get_port "bitcoin" "rpc" 2>/dev/null || true)
BTC_RPC=""
if [ -n "$BTC_PORT" ]; then
    BTC_RPC="http://127.0.0.1:$BTC_PORT"
fi

echo ""
echo "Service URLs:"
echo "  THORNode API:  $API"
if [ -n "$MIDGARD_PORT" ]; then
    MIDGARD="http://127.0.0.1:$MIDGARD_PORT"
    echo "  Midgard API:   $MIDGARD"
fi
echo "  Ethereum RPC:  $ETH_RPC"
if [ -n "$BTC_RPC" ]; then
    echo "  Bitcoin RPC:   $BTC_RPC  (user: thorchain, pass: thorchain)"
fi
echo "  Faucet:        $FAUCET"

echo ""
echo "Pegasus configuration:"
echo "  PEGASUS_THORCHAIN_NODE_URL=$API"
if [ -n "$MIDGARD_PORT" ]; then
    echo "  PEGASUS_THORCHAIN_MIDGARD_URL=$MIDGARD"
fi
echo "  PEGASUS_DISABLE_PROVIDERS=maya,openocean"

echo ""
echo "Anvil accounts (for swap testing):"
echo "  Account 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo "    Key:     0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
echo "  Account 2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
echo "    Key:     0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
