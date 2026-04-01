toolchain = import_module("./toolchain.star")
cli_only_launcher = import_module("./cli_only_launcher.star")
cli_key_manager = import_module("./cli_key_manager.star")

def launch_single_node(plan, chain_cfg):
    chain_name = chain_cfg["name"]
    chain_id = chain_cfg["chain_id"]
    binary = "thornode"
    config_folder = "/root/.thornode/config"

    forking_config = chain_cfg.get("forking", {})
    forking_enabled = forking_config.get("enabled", True)

    participant = chain_cfg["participants"][0]

    # Use the participant image when forking is disabled; forking image when enabled.
    # Only reference the forking image when actually needed so Kurtosis does not
    # attempt to pull it during validation in non-forking runs.
    if forking_enabled:
        node_image = forking_config.get("image", "tiljordan/thornode-forking:1.0.25-23761879")
    else:
        node_image = participant.get("image", "registry.gitlab.com/thorchain/thornode:mainnet")
    node_volume_size = participant.get("persistent_size_mb", chain_cfg.get("node_persistent_size_mb", 16384))
    account_balance = int(participant["account_balance"])
    bond_amount = int(participant.get("bond_amount", "500000000000"))
    faucet_amount = int(chain_cfg["faucet"]["faucet_amount"])
    gomemlimit = participant.get("gomemlimit", "6GiB")

    app_version = chain_cfg["app_version"]

    # Determine which external chains are enabled (used in genesis vault seeding)
    bifrost_enabled = chain_cfg.get("bifrost_enabled", False)
    bitcoin_enabled = chain_cfg.get("bitcoin_enabled", False) if bifrost_enabled else False
    ethereum_enabled = chain_cfg.get("ethereum_enabled", False) if bifrost_enabled else False

    # Calculate genesis time
    genesis_delay = chain_cfg.get("genesis_delay", 5)
    plan.add_service(
        name="genesis-time-calc",
        config=ServiceConfig(
            image="python:3.11-alpine",
            entrypoint=["/bin/sh", "-c", "sleep infinity"],
        ),
    )
    genesis_time_result = plan.exec(
        service_name="genesis-time-calc",
        recipe=ExecRecipe(
            command=[
                "python",
                "-c",
                "from datetime import datetime,timedelta;import sys;sys.stdout.write((datetime.utcnow()+timedelta(seconds=%d)).strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ'))"
                % genesis_delay,
            ]
        ),
        description="Compute genesis_time (UTC now + {}s)".format(genesis_delay),
    )
    genesis_time = genesis_time_result["output"].strip().replace("\n", "").replace("\r", "")
    plan.remove_service("genesis-time-calc")

    # Consensus block config
    consensus = chain_cfg.get("consensus", {})
    consensus_block = {
        "block": {
            "max_bytes": str(consensus.get("block_max_bytes", "22020096")),
            "max_gas": str(consensus.get("block_max_gas", "50000000")),
        },
        "evidence": {
            "max_age_num_blocks": str(consensus.get("evidence_max_age_num_blocks", "100000")),
            "max_age_duration": str(consensus.get("evidence_max_age_duration", "172800000000000")),
            "max_bytes": str(consensus.get("evidence_max_bytes", "1048576")),
        },
        "validator": {"pub_key_types": consensus.get("validator_pub_key_types", ["ed25519"])},
    }
    # Bond module address prefix depends on the image (mainnet=thor1, mocknet=tthor1).
    # We detect this at runtime from the generated validator address.
    # Placeholder here; actual value set after validator key generation.
    bond_module_addr = None

    # Ports
    ports = {
        "rpc": PortSpec(number=26657, transport_protocol="TCP", wait=None),
        "p2p": PortSpec(number=26656, transport_protocol="TCP", wait=None),
        "grpc": PortSpec(number=9090, transport_protocol="TCP", wait=None),
        "api": PortSpec(number=1317, transport_protocol="TCP", wait=None),
        "prometheus": PortSpec(number=26660, transport_protocol="TCP", wait=None),
        "ebifrost": PortSpec(number=50051, transport_protocol="TCP", wait=None),
    }

    # Upload merge script to be mounted at service creation
    merge_artifact = plan.upload_files(src="/src/network_launcher/merge_patch.py")

    node_name = "{}-node".format(chain_name)

    # Phase A: add service with sleep entrypoint
    base_service = plan.add_service(
        name="base-service",
        config=ServiceConfig(
            image=node_image,
            ports=ports,
            entrypoint=["/bin/sh", "-lc", "sleep infinity"],
            min_cpu=participant.get("min_cpu", 500),
            min_memory=participant.get("min_memory", 1024),
            files={
                "/merge_patch": merge_artifact,
                "/tmp/execution-data": Directory(
                    persistent_key="node-data",
                    size=node_volume_size,
                )
            },
        ),
    )

    # a) Generate validator key
    res = plan.exec(
        "base-service",
        ExecRecipe(
            command=[ "/bin/sh","-lc", "{} keys add validator --keyring-backend test --output json".format(binary) ],
            extract={"validator_addr": "fromjson | .address", "validator_mnemonic": "fromjson | .mnemonic"},
        ),
        description="Generate validator key (addr + mnemonic)",
    )
    validator_addr = res["extract.validator_addr"].replace("\n", "")
    validator_mnemonic = res["extract.validator_mnemonic"].replace("\n", "")

    # Also import the validator key into the file-based keyring.
    # THORNode's keysign endpoint uses the file keyring by default, so the
    # validator key must be present there for outbound transaction signing.
    # The recover command reads: mnemonic, then password, then password again.
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                "(echo '{mnemonic}'; echo 'TestPassword!'; echo 'TestPassword!') | {bin} keys add thorchain --recover --keyring-backend file 2>&1 || true".format(
                    bin=binary,
                    mnemonic=validator_mnemonic,
                ),
            ]
        ),
        description="Import validator key into file-based keyring for keysign",
    )

    # Derive bond module address prefix from the validator address prefix.
    # mainnet uses "thor1", mocknet uses "tthor1". The module address suffix is fixed.
    if validator_addr.startswith("tthor1"):
        bond_module_addr = "tthor17gw75axcnr8747pkanye45pnrwk7p9c3uhzgff"
    else:
        bond_module_addr = "thor17gw75axcnr8747pkanye45pnrwk7p9c3uhzgff"

    # b) Init node
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                "printf '%s' '{}' | {} init base-service --recover --chain-id {}".format(
                    validator_mnemonic, binary, chain_id
                ),
            ],
        ),
        description="Initialize thornode home and config",
    )

    # c) Stage forked genesis (only when forking from mainnet)
    if forking_enabled:
        plan.exec(
            "base-service",
            ExecRecipe(command=["/bin/sh", "-lc", "cp /tmp/genesis.json {}/genesis.json".format(config_folder)]),
            description="Copy forked genesis into config",
        )


    # d) Get SECP bech32 pk
    secp_res = plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                "{0} keys show validator --pubkey --keyring-backend test | {0} pubkey | tr -d '\\n'".format(binary),
            ],
        ),
        description="Derive validator secp256k1 bech32 pubkey",
    )
    secp_pk = secp_res["output"]

    # e) Get validator consensus pubkeys (ed + cons)
    ed_res = plan.exec(
        "base-service",
        ExecRecipe(command=["/bin/sh", "-lc", "{0} tendermint show-validator | {0} pubkey | tr -d '\\n'".format(binary)]),
        description="Derive validator ed25519 bech32 pubkey",
    )
    ed_pk = ed_res["output"]
    cons_res = plan.exec(
        "base-service",
        ExecRecipe(
            command=["/bin/sh", "-lc", "{0} tendermint show-validator | {0} pubkey --bech cons | tr -d '\\n'".format(binary)]
        ),
        description="Derive validator consensus bech32 pubkey",
    )
    cons_pk = cons_res["output"]

    # f) Create faucet key
    f_res = plan.exec(
        "base-service",
        ExecRecipe(
            command=["/bin/sh", "-lc", "{} keys add faucet --keyring-backend test --output json".format(binary)],
            extract={"faucet_addr": "fromjson | .address", "faucet_mnemonic": "fromjson | .mnemonic"},
        ),
        description="Generate faucet key (addr + mnemonic)",
    )
    faucet_addr = f_res["extract.faucet_addr"].replace("\n", "")
    faucet_mnemonic = f_res["extract.faucet_mnemonic"].replace("\n", "")
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                "printf '%s' '{}' > /tmp/execution-data/faucet.mnemonic".format(faucet_mnemonic),
            ],
        ),
        description="Persist faucet mnemonic for downstream faucet launcher",
    )

    # Extract prefunded accounts from configuration
    prefunded_accounts = chain_cfg.get("prefunded_accounts", {})
    prefunded_list = []
    prefunded_rune_total = 0
    for addr in prefunded_accounts:
        amount = prefunded_accounts[addr]
        amount_int = int(amount)
        prefunded_list.append({"address": addr, "amount": amount_int})
        prefunded_rune_total = prefunded_rune_total + amount_int

    plan.print("Prefunded accounts configured: {}".format(len(prefunded_list)))
    for pf in prefunded_list:
        plan.print("  - {} with {} base units".format(pf["address"][:20] + "...", pf["amount"]))
    if prefunded_rune_total > 0:
        plan.print("Total RUNE distributed to prefunded accounts: {}".format(prefunded_rune_total))

    # g) Prepare JSON payloads and compute totals (single Python pass)
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                """
python3 - << 'PY'
import json
validator_addr = %(validator_addr)r
faucet_addr = %(faucet_addr)r
secp_pk = %(secp_pk)r
ed_pk = %(ed_pk)r
cons_pk = %(cons_pk)r
app_version = %(app_version)r
account_balance = %(account_balance)d
faucet_amount = %(faucet_amount)d
prefunded_list = %(prefunded_list)r
prefunded_rune_total = %(prefunded_rune_total)d
mainnet_rune_supply = 42537131234170029
total_rune_supply = mainnet_rune_supply + account_balance + faucet_amount + prefunded_rune_total

node_accounts = [{
  "active_block_height": "0",
  "bond": "%(bond_amount)d",
  "bond_address": validator_addr,
  "node_address": validator_addr,
  "pub_key_set": {"ed25519": ed_pk, "secp256k1": secp_pk},
  "signer_membership": [secp_pk],
  "status": "Active",
  "validator_cons_pub_key": cons_pk,
  "version": app_version,
}]

accounts = [
  {"@type": "/cosmos.auth.v1beta1.BaseAccount", "account_number": "0", "address": validator_addr, "pub_key": None, "sequence": "0"},
  {"@type": "/cosmos.auth.v1beta1.BaseAccount", "account_number": "0", "address": faucet_addr, "pub_key": None, "sequence": "0"},
]

balances = [
  {"address": validator_addr, "coins": [{"amount": str(account_balance), "denom": "rune"}]},
  {"address": faucet_addr, "coins": [{"amount": str(faucet_amount), "denom": "rune"}]},
]

# Add prefunded accounts
for pf in prefunded_list:
    accounts.append({
        "@type": "/cosmos.auth.v1beta1.BaseAccount",
        "account_number": "0",
        "address": pf["address"],
        "pub_key": None,
        "sequence": "0"
    })
    balances.append({
        "address": pf["address"],
        "coins": [{"amount": str(pf["amount"]), "denom": "rune"}]
    })

open("/tmp/node_accounts.json","w").write(json.dumps(node_accounts))
open("/tmp/accounts.json","w").write(json.dumps(accounts))
open("/tmp/balances.json","w").write(json.dumps(balances))
open("/tmp/accounts_fragment.json","w").write(", ".join(json.dumps(x) for x in accounts))
open("/tmp/balances_fragment.json","w").write(", ".join(json.dumps(x) for x in balances))
open("/tmp/rune_supply.txt","w").write(str(total_rune_supply))
open("/tmp/consensus_block.json","w").write(json.dumps(%(consensus_block)s))
open("/tmp/vault_membership.json","w").write(json.dumps([secp_pk]))
PY
""" % {
                    "validator_addr": validator_addr,
                    "faucet_addr": faucet_addr,
                    "secp_pk": secp_pk,
                    "ed_pk": ed_pk,
                    "cons_pk": cons_pk,
                    "app_version": app_version,
                    "account_balance": account_balance,
                    "faucet_amount": faucet_amount,
                    "bond_amount": bond_amount,
                    "consensus_block": consensus_block,
                    "prefunded_list": prefunded_list,
                    "prefunded_rune_total": prefunded_rune_total,
                },
            ]
        ),
        description="Prepare small JSON payloads and total RUNE supply",
    )

    # Build faucet balances and supply updates for all denoms
    if forking_enabled:
        # Forking mode: fetch all mainnet denoms and create balances for each
        plan.exec(
            "base-service",
            ExecRecipe(
                command=[
                    "/bin/sh",
                    "-lc",
                    """
set -e
curl -sS "https://thornode.ninerealms.com/cosmos/bank/v1beta1/supply?pagination.limit=500" -o /tmp/supply.json
python3 - << 'PY'
import json
from pathlib import Path
faucet_addr = %(faucet_addr)r
faucet_amount = %(faucet_amount)d
prefunded_list = %(prefunded_list)r
# Read supply from ninerealms
try:
    s = json.loads(Path("/tmp/supply.json").read_text() or "{}")
except Exception:
    s = {}
supply_list = s.get("supply", [])
denoms = []
for entry in supply_list:
    if isinstance(entry, dict):
        d = entry.get("denom")
        if isinstance(d, str):
            denoms.append(d)
# Build faucet balance for all denoms
coins = [{"amount": str(faucet_amount), "denom": d} for d in denoms]
faucet_balance = {"address": faucet_addr, "coins": coins}
Path("/tmp/faucet_balances_fragment.json").write_text(json.dumps(faucet_balance, separators=(",",":")))
# Merge into existing balances_fragment (ensure single faucet entry)
arr = []
try:
    existing = Path("/tmp/balances_fragment.json").read_text().strip()
    if existing:
        try:
            arr = json.loads(f"[{existing}]")
        except Exception:
            j = json.loads(existing)
            arr = j if isinstance(j, list) else [j]
except Exception:
    arr = []
arr = [b for b in arr if not (isinstance(b, dict) and b.get("address")==faucet_balance["address"])]
arr.append(faucet_balance)
# Add prefunded accounts with all denoms
for pf in prefunded_list:
    pf_coins = [{"amount": str(pf["amount"]), "denom": d} for d in denoms]
    pf_balance = {"address": pf["address"], "coins": pf_coins}
    # Remove any existing entry for this address
    arr = [b for b in arr if not (isinstance(b, dict) and b.get("address")==pf_balance["address"])]
    arr.append(pf_balance)
Path("/tmp/merged_balances_fragment.json").write_text(", ".join(json.dumps(x, separators=(",",":")) for x in arr))
# Compute updated supply = upstream supply + faucet_amount + prefunded amounts per denom
def add(a,b):
    try:
        return str(int(a)+int(b))
    except Exception:
        return str(a)
updated = []
for entry in supply_list:
    if not isinstance(entry, dict):
        continue
    d = entry.get("denom")
    a = entry.get("amount")
    if isinstance(d, str) and isinstance(a, (str,int)):
        # Add faucet amount
        total = add(str(a), str(faucet_amount))
        # Add all prefunded amounts
        for pf in prefunded_list:
            total = add(total, str(pf["amount"]))
        updated.append({"denom": d, "amount": total})
Path("/tmp/supply_fragment.json").write_text(json.dumps(updated, separators=(",",":")))
PY
""" % {"faucet_addr": faucet_addr, "faucet_amount": faucet_amount, "prefunded_list": prefunded_list},
                ],
            ),
            description="Prepare faucet and prefunded account multi-denom balances and updated supply from ninerealms",
        )
    else:
        # Non-forking mode: only use RUNE denom, no mainnet supply fetch needed
        plan.exec(
            "base-service",
            ExecRecipe(
                command=[
                    "/bin/sh",
                    "-lc",
                    """
python3 - << 'PY'
import json
from pathlib import Path
faucet_addr = %(faucet_addr)r
faucet_amount = %(faucet_amount)d
prefunded_list = %(prefunded_list)r
# In non-forking mode, we only have 'rune' denom
denoms = ["rune"]
# Build faucet balance
coins = [{"amount": str(faucet_amount), "denom": d} for d in denoms]
faucet_balance = {"address": faucet_addr, "coins": coins}
Path("/tmp/faucet_balances_fragment.json").write_text(json.dumps(faucet_balance, separators=(",",":")))
# Build merged balances from existing fragment
arr = []
try:
    existing = Path("/tmp/balances_fragment.json").read_text().strip()
    if existing:
        try:
            arr = json.loads(f"[{existing}]")
        except Exception:
            j = json.loads(existing)
            arr = j if isinstance(j, list) else [j]
except Exception:
    arr = []
arr = [b for b in arr if not (isinstance(b, dict) and b.get("address")==faucet_balance["address"])]
arr.append(faucet_balance)
# Add prefunded accounts
for pf in prefunded_list:
    pf_coins = [{"amount": str(pf["amount"]), "denom": d} for d in denoms]
    pf_balance = {"address": pf["address"], "coins": pf_coins}
    arr = [b for b in arr if not (isinstance(b, dict) and b.get("address")==pf_balance["address"])]
    arr.append(pf_balance)
Path("/tmp/merged_balances_fragment.json").write_text(", ".join(json.dumps(x, separators=(",",":")) for x in arr))
# Compute supply
from collections import defaultdict
tot = defaultdict(int)
for b in arr:
    if isinstance(b, dict):
        for c in (b.get("coins") or []):
            try: tot[str(c["denom"])] += int(str(c["amount"]))
            except: pass
supply_arr = [{"denom": d, "amount": str(tot[d])} for d in sorted(tot)]
Path("/tmp/supply_fragment.json").write_text(json.dumps(supply_arr, separators=(",",":")))
PY
""" % {"faucet_addr": faucet_addr, "faucet_amount": faucet_amount, "prefunded_list": prefunded_list},
                ],
            ),
            description="Prepare faucet balances and supply (non-forking, RUNE only)",
        )


    # h) Patch genesis with accounts, balances, node_accounts, and supply
    if forking_enabled:
        # Forking mode: sed-based placeholder replacement in the forked genesis
        plan.exec(
            "base-service",
            ExecRecipe(
                command=[
                    "/bin/sh",
                    "-lc",
                    """
set -e
CFG=%(cfg)s/genesis.json

# Read JSON fragments and tokens
cb=$(tr -d '\\n\\r' </tmp/consensus_block.json)
na=$(tr -d '\\n\\r' </tmp/node_accounts.json)
vm=$(tr -d '\\n\\r' </tmp/vault_membership.json)
ac=$(tr -d '\\n\\r' </tmp/accounts_fragment.json)
# Prefer merged balances if present (includes all denoms for faucet)
if [ -f /tmp/merged_balances_fragment.json ]; then
  bl=$(tr -d '\\n\\r' </tmp/merged_balances_fragment.json)
else
  bl=$(tr -d '\\n\\r' </tmp/balances_fragment.json)
fi
rs=$(tr -d '\\n\\r' </tmp/rune_supply.txt)
su=$(tr -d '\\n\\r' </tmp/supply_fragment.json)

# escape function
escape() { printf '%%s' "$1" | sed -e 's/[\\/&]/\\\\&/g'; }

# Apply replacements including __SUPPLY__
sed -i \
  -e "s/\\"__CONSENSUS_BLOCK__\\"/$(escape "$cb")/" \
  -e "s/\\"__NODE_ACCOUNTS__\\"/$(escape "$na")/" \
  -e "s/\\"__VAULT_MEMBERSHIP__\\"/$(escape "$vm")/" \
  -e "s/\\"__ACCOUNTS__\\"/$(escape "$ac")/" \
  -e "s/\\"__BALANCES__\\"/$(escape "$bl")/" \
  -e "s/\\"__SUPPLY__\\"/$(escape "$su")/" \
  -e "s/\\"__RUNE_SUPPLY__\\"/$(escape "$rs")/" \
  "$CFG"

# Validate JSON
python3 - << 'PY'
import json, collections
from pathlib import Path
faucet_addr = %(faucet_addr)r
faucet_amount = %(faucet_amount)d
def load_list_text(path):
    p=Path(path)
    if not p.exists(): return ""
    return p.read_text().strip()
def parse_list(txt):
    if not txt:
        return []
    try:
        return json.loads(f"[{txt}]")
    except Exception:
        try:
            j=json.loads(txt)
            return j if isinstance(j, list) else [j]
        except Exception:
            return []
def load_list(path):
    return parse_list(load_list_text(path))
def load_balances():
    merged = parse_list(load_list_text("/tmp/merged_balances_fragment.json"))
    if merged:
        return merged
    return load_list("/tmp/balances_fragment.json")
bl = load_balances()
denoms=set()
for b in bl:
    if isinstance(b, dict):
        for c in (b.get("coins") or []):
            try:
                denoms.add(str(c["denom"]))
            except Exception:
                pass
coins = [{"amount": str(faucet_amount), "denom": d} for d in sorted(denoms)]
faucet_balance = {"address": faucet_addr, "coins": coins}
addr = faucet_balance["address"]
bl = [b for b in bl if not (isinstance(b, dict) and b.get("address")==addr)]
bl.append(faucet_balance)
tot = collections.defaultdict(int)
for b in bl:
    if not isinstance(b, dict): 
        continue
    for c in (b.get("coins") or []):
        try:
            tot[str(c["denom"])] += int(str(c["amount"]))
        except Exception:
            pass
merged_balances_str = ", ".join(json.dumps(x, separators=(',',':')) for x in bl)
supply_arr = [{"denom": d, "amount": str(tot[d])} for d in sorted(tot)]
supply_str = json.dumps(supply_arr, separators=(",",":"))
Path("/tmp/merged_balances_str.txt").write_text(merged_balances_str)
Path("/tmp/supply_str.json").write_text(supply_str)
PY
bl="$(tr -d '\n\r' </tmp/merged_balances_str.txt || true)"
su="$(tr -d '\n\r' </tmp/supply_str.json || true)" 

# Scalars from launcher
GENESIS_TIME=%(genesis_time)s
CHAIN_ID=%(chain_id)s
APP_VERSION=%(app_version)s
RESERVE="$rs"

escape() { printf '%%s' "$1" | sed -e 's/[&/\\\\]/\\\\&/g'; }

sed -i \
  -e "s/\\"__GENESIS_TIME__\\"/\\"$(escape "$GENESIS_TIME")\\"/" \
  -e "s/\\"__CHAIN_ID__\\"/\\"$(escape "$CHAIN_ID")\\"/" \
  -e "s/\\"__APP_VERSION__\\"/\\"$(escape "$APP_VERSION")\\"/" \
  -e "s/\\"__RESERVE__\\"/\\"$(escape "$RESERVE")\\"/" \
  -e "s/\\"__CONSENSUS_BLOCK__\\"/$(escape "$cb")/" \
  -e "s/\\"__NODE_ACCOUNTS__\\"/$(escape "$na")/" \
  -e "s/\\"__VAULT_MEMBERSHIP__\\"/$(escape "$vm")/" \
  -e "s/\\"__ACCOUNTS__\\"/$(escape "$ac")/" \
  -e "s/\\"__BALANCES__\\"/$(escape "$bl")/" \
  -e "s/\\"__SUPPLY__\\"/$(escape "$su")/" \
  "$CFG"
python3 - << 'PY'
import json
from collections import defaultdict
p="%(cfg)s/genesis.json"
with open(p,"r") as f:
    j=json.load(f)
bank=j.get("app_state",{}).get("bank",{})
balances=bank.get("balances",[])
tot=defaultdict(int)
for b in balances:
    if isinstance(b,dict):
        for c in b.get("coins",[]) or []:
            try:
                tot[str(c["denom"])]+=int(str(c["amount"]))
            except Exception:
                pass
bank["supply"]=[{"denom": d, "amount": str(tot[d])} for d in sorted(tot)]
j["app_state"]["bank"]=bank
with open(p,"w") as f:
    json.dump(j,f,separators=(",",":"))
PY

""" % {
                        "cfg": config_folder,
                        "genesis_time": genesis_time,
                        "chain_id": chain_id,
                        "app_version": app_version,
                        "faucet_addr": faucet_addr,
                        "faucet_amount": faucet_amount,
                    },
                ]
            ),
            description="Apply placeholders via single sed pass (forking mode)",
        )
    else:
        # Non-forking mode: directly patch the standard thornode init genesis via Python
        plan.exec(
            "base-service",
            ExecRecipe(
                command=[
                    "/bin/sh",
                    "-lc",
                    """
set -e
python3 - << 'PY'
import json
from collections import defaultdict
from pathlib import Path

genesis_path = "%(cfg)s/genesis.json"
genesis_time = %(genesis_time)r
chain_id = %(chain_id)r
app_version = %(app_version)r
bond_module_addr = %(bond_module_addr)r
bitcoin_enabled = %(bitcoin_enabled)s
ethereum_enabled = %(ethereum_enabled)s

# Load pre-computed fragments
node_accounts = json.loads(Path("/tmp/node_accounts.json").read_text())
consensus_block = json.loads(Path("/tmp/consensus_block.json").read_text())
vault_membership = json.loads(Path("/tmp/vault_membership.json").read_text())

# Load balances
def parse_fragment(path):
    txt = Path(path).read_text().strip()
    if not txt:
        return []
    try:
        return json.loads(f"[{txt}]")
    except Exception:
        j = json.loads(txt)
        return j if isinstance(j, list) else [j]

balances = parse_fragment("/tmp/merged_balances_fragment.json")
accounts_list = parse_fragment("/tmp/accounts_fragment.json")
supply = json.loads(Path("/tmp/supply_fragment.json").read_text())
rune_supply = Path("/tmp/rune_supply.txt").read_text().strip()

# Load existing genesis
with open(genesis_path, "r") as f:
    g = json.load(f)

# Patch top-level fields
g["genesis_time"] = genesis_time
g["chain_id"] = chain_id

# Ensure app_state exists
app = g.setdefault("app_state", {})

# Patch consensus params
if "consensus" not in g:
    g["consensus"] = {}
g["consensus"]["params"] = consensus_block

# Patch auth accounts
auth = app.setdefault("auth", {})
existing_accounts = auth.get("accounts", [])
for acc in accounts_list:
    # Skip if already exists
    addr = acc.get("address", "")
    if not any(a.get("address") == addr for a in existing_accounts):
        existing_accounts.append(acc)
auth["accounts"] = existing_accounts

# Patch bank balances and supply
bank = app.setdefault("bank", {})
bank["balances"] = balances
# Recompute supply from actual balances
tot = defaultdict(int)
for b in balances:
    if isinstance(b, dict):
        for c in (b.get("coins") or []):
            try:
                tot[str(c["denom"])] += int(str(c["amount"]))
            except Exception:
                pass
bank["supply"] = [{"denom": d, "amount": str(tot[d])} for d in sorted(tot)]

# Patch thorchain module
tc = app.setdefault("thorchain", {})
tc["node_accounts"] = node_accounts
tc["reserve"] = rune_supply
tc["vaults"] = tc.get("vaults", [])

# Build the list of external chains enabled for Bifrost
vault_chains = ["THOR"]
if bitcoin_enabled:
    vault_chains.append("BTC")
if ethereum_enabled:
    vault_chains.append("ETH")

# Build router list for the vault (Bifrost reads routers from vault pubkeys)
vault_routers = []
if ethereum_enabled:
    vault_routers.append({"chain": "ETH", "router": "0x5FbDB2315678afecb367f032d93F642f64180aa3"})

# Ensure a single vault with membership and chains
if not tc["vaults"]:
    tc["vaults"] = [{
        "block_height": "0",
        "pub_key": vault_membership[0] if vault_membership else "",
        "coins": [],
        "type": "AsgardVault",
        "status": "ActiveVault",
        "membership": vault_membership,
        "chains": vault_chains,
        "inbound_tx_count": "0",
        "routers": vault_routers,
    }]
else:
    for v in tc["vaults"]:
        v["membership"] = vault_membership
        v["chains"] = vault_chains
        v["routers"] = vault_routers

# Set node IP address so Bifrost can register with THORNode.
# In a Kurtosis enclave, services resolve by name; the node's own
# container address is fine. We use a placeholder that works inside
# the Docker network.
for na in tc["node_accounts"]:
    if not na.get("ip_address"):
        na["ip_address"] = "bifrost"

# Seed last_chain_heights so /thorchain/lastblock returns data from block 1.
# Without this, Bifrost subsystems (solvency, IsChainPaused, signer scanner)
# keep erroring because GetBlockHeight() returns empty when there are no
# observed chain heights.
last_chain_heights = []
if bitcoin_enabled:
    last_chain_heights.append({"chain": "BTC", "height": "1"})
if ethereum_enabled:
    last_chain_heights.append({"chain": "ETH", "height": "1"})
tc["last_chain_heights"] = last_chain_heights

# Seed last_signed_height so the lastblock query includes the thorchain field.
# NOTE: Amino JSON codec requires int64/uint64 values to be quoted strings.
tc["last_signed_height"] = "1"

# Register chain contracts (router addresses) required by Bifrost for EVM chains.
# The ETH router is deployed deterministically at nonce 0 from Anvil account 0.
# Without a registered router, Bifrost cannot execute outbound ETH/ERC-20 transfers.
chain_contracts = tc.get("chain_contracts", [])
if ethereum_enabled:
    eth_router = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
    if not any(c.get("chain") == "ETH" for c in chain_contracts):
        chain_contracts.append({"chain": "ETH", "router": eth_router})
tc["chain_contracts"] = chain_contracts

# Seed network fees so the outbound transaction pipeline can price gas.
# Without valid network fees, GetGasDetails() fails in prepareTxOutItem(),
# which prevents TryAddTxOutItem() from scheduling ANY L1 outbound —
# swaps execute (pool balances change) but the outbound is never created.
# Bifrost will later overwrite these with observed values.
# Values: BTC = 250 vbytes @ 25 sat/vbyte, ETH = 80000 gas @ 30 gwei.
network_fees = tc.get("network_fees", [])
if bitcoin_enabled:
    if not any(nf.get("chain") == "BTC" for nf in network_fees):
        network_fees.append({
            "chain": "BTC",
            "transaction_size": "250",
            "transaction_fee_rate": "25",
        })
if ethereum_enabled:
    if not any(nf.get("chain") == "ETH" for nf in network_fees):
        network_fees.append({
            "chain": "ETH",
            "transaction_size": "80000",
            "transaction_fee_rate": "30",
        })
tc["network_fees"] = network_fees

# Patch denom metadata if missing
denom_meta = bank.get("denom_metadata", [])
if not any(m.get("base") == "rune" for m in denom_meta):
    denom_meta.append({
        "description": "RUNE coin",
        "denom_units": [
            {"denom": "rune", "exponent": 0, "aliases": []},
            {"denom": "RUNE", "exponent": 8, "aliases": []},
        ],
        "base": "rune",
        "display": "rune",
        "name": "rune",
        "symbol": "RUNE",
    })
bank["denom_metadata"] = denom_meta

# Set minimum gas prices in genesis (bank send_enabled)
bank["send_enabled"] = bank.get("send_enabled", [])

# Set MIMIR values required for Bifrost operation.
# JailTimeKeygen must be > KeygenTimeout (default 5m = 300 blocks at 1s/block).
# Without these, Bifrost fatals with "keygen timeout must be shorter than jail time".
mimirs = tc.get("mimirs", [])
mimir_defaults = {
    "JailTimeKeygen": 720,      # 12 minutes in blocks (> 5m keygen timeout)
    "JailTimeKeysign": 60,      # 1 minute in blocks
    "WASMPERMISSIONLESS": 1,    # allow permissionless WASM deployment
}
# EVM chains: enable the router allowance check so Bifrost auto-approves
# ERC-20 token transfers. Without this, the V6 router's transferOut()
# reverts because the vault hasn't approved the router to spend tokens.
# The key format is "EVMAllowanceCheck-{CHAIN}" where CHAIN = ETH, AVAX, etc.
if ethereum_enabled:
    mimir_defaults["EVMAllowanceCheck-ETH"] = 1
existing_keys = {m.get("key", ""): i for i, m in enumerate(mimirs)}
for key, val in mimir_defaults.items():
    if key in existing_keys:
        mimirs[existing_keys[key]]["value"] = str(val)
    else:
        mimirs.append({"key": key, "value": str(val)})
tc["mimirs"] = mimirs

# Write patched genesis
with open(genesis_path, "w") as f:
    json.dump(g, f, separators=(",", ":"))

print("Genesis patched successfully (non-forking mode)")
PY
""" % {
                        "cfg": config_folder,
                        "genesis_time": genesis_time,
                        "chain_id": chain_id,
                        "app_version": app_version,
                        "bond_module_addr": bond_module_addr,
                        "bitcoin_enabled": "True" if bitcoin_enabled else "False",
                        "ethereum_enabled": "True" if ethereum_enabled else "False",
                    },
                ]
            ),
            description="Patch genesis with accounts, balances, and node_accounts (non-forking mode)",
        )


    # j) Batch config updates
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                """
set -e
APP=%(cfg)s/app.toml
CFG=%(cfg)s/config.toml
sed -i 's/^minimum-gas-prices = ".*"/minimum-gas-prices = "0rune"/' "$APP"
sed -i 's/^enable = false/enable = true/' "$APP"
sed -i 's/^swagger = false/swagger = true/' "$APP"
sed -i 's/^pruning = "default"/pruning = "custom"/' "$APP"
sed -i 's/^pruning-keep-recent = "0"/pruning-keep-recent = "64"/' "$APP"
sed -i 's/^pruning-keep-every = "0"/pruning-keep-every = "0"/' "$APP"
sed -i 's/^pruning-interval = "0"/pruning-interval = "20"/' "$APP"
sed -i 's/^snapshot-interval = [0-9][0-9]*/snapshot-interval = 0/' "$APP"
sed -i 's/^iavl-cache-size = [0-9][0-9]*/iavl-cache-size = 131072/' "$APP"

sed -i 's/^timeout_commit = "5s"/timeout_commit = "1s"/' "$CFG"
sed -i 's/^timeout_propose = "3s"/timeout_propose = "1s"/' "$CFG"

sed -i 's/^addr_book_strict = true/addr_book_strict = false/' "$CFG"
sed -i 's/^pex = true/pex = false/' "$CFG"
sed -i 's/^persistent_peers = ".*"/persistent_peers = ""/' "$CFG"
sed -i 's/^seeds = ".*"/seeds = ""/' "$CFG"

sed -i 's/^laddr = "tcp:\\/\\/127.0.0.1:26657"/laddr = "tcp:\\/\\/0.0.0.0:26657"/' "$CFG"
sed -i 's/^cors_allowed_origins = \\[\\]/cors_allowed_origins = ["*"]/' "$CFG"

sed -i 's/^address = "localhost:9090"/address = "0.0.0.0:9090"/' "$APP"

sed -i 's/^address = "tcp:\\/\\/localhost:1317"/address = "tcp:\\/\\/0.0.0.0:1317"/' "$APP"
sed -i 's/^enabled-unsafe-cors = false/enabled-unsafe-cors = true/' "$APP"

sed -i 's/^prometheus = false/prometheus = true/' "$CFG"
sed -i 's/^prometheus_listen_addr = ":26660"/prometheus_listen_addr = "0.0.0.0:26660"/' "$CFG"

# Bind eBifrost gRPC to all interfaces so Bifrost (running in a separate container)
# can connect and submit attestation-based observations.
sed -i 's/^address = "localhost:50051"/address = "0.0.0.0:50051"/' "$APP"
""" % {"cfg": config_folder},
            ]
        ),
        description="Apply node configuration (API/RPC/gRPC/Prometheus/P2P)",
    )

    # # Copy thornode folder to persistent volume
    plan.exec(
        "base-service",
        ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                "set -e; rm -rf /tmp/execution-data/.thornode; cp -a /root/.thornode /tmp/execution-data/.thornode"
            ]
        )
    )

    plan.remove_service(
        "base-service",
        description = "removing base service"
    )

    node_service = plan.add_service(
        name=node_name,
        config=ServiceConfig(
            image=node_image,
            ports=ports,
            entrypoint=[
                "/bin/sh",
                "-lc",
                "set -e; THOR_HOME=/tmp/execution-data/.thornode; if [ ! -d \"$THOR_HOME\" ]; then echo 'missing thornode home in persistent volume' >&2; exit 1; fi; ln -sfn \"$THOR_HOME\" /root/.thornode; export GOMEMLIMIT='{gomemlimit}'; printf 'thorchain\\nTestPassword!\\n' | {bin} start --home \"$THOR_HOME\"".format(
                    bin=binary,
                    gomemlimit=gomemlimit,
                )
            ],
            min_cpu=participant.get("min_cpu", 500),
            min_memory=participant.get("min_memory", 1024),
            files={
                "/tmp/execution-data": Directory(
                    persistent_key="node-data",
                    size=5000
                )
            },
        ),
    )

    # Provision companion CLI utility container (optional, disabled by default for cloud efficiency)
    cli_cfg = chain_cfg.get("cli_service", {})
    cli_name = None
    if chain_cfg.get("deploy_cli", False):
        cli_name = cli_cfg.get("name", "{}-cli".format(chain_name))
        cli_payload = {
            "name": cli_name,
            "type": "thorchain",
            "config_type": "cli_only",
            "profile": chain_name,
            "service_name": cli_name,
            "node_service": node_name,
            "chain_id": chain_id,
            "rpc_url": "http://{}:26657".format(node_name),
            "api_url": "http://{}:1317".format(node_name),
            "faucet_url": chain_cfg.get("faucet", {}).get("endpoint", ""),
            "cli_image": cli_cfg.get("image", "fravlaca/thor-cli-toolchain:0.1.0"),
            "persistent_key": cli_cfg.get("persistent_key", "cli-{}-thornode-home".format(chain_name)),
            "persistent_size": cli_cfg.get("persistent_size", 2048),
            "min_cpu": cli_cfg.get("min_cpu", 250),
            "min_memory": cli_cfg.get("min_memory", 256),
            "skip_toolchain_setup": cli_cfg.get("skip_toolchain_setup", False),
            "preload_keys": cli_cfg.get("preload_keys", []),
            "prefunded_accounts": chain_cfg.get("prefunded_accounts", {}),
        }
        cli_only_launcher.launch_cli_only(plan, cli_payload)

        plan.print("CLI container '{}' provisioned".format(cli_name))
    else:
        plan.print("CLI container skipped (use deploy_cli: true to enable)")

    return {
        "name": node_name,
        "ip": node_service.ip_address,
        "cli_service": cli_name,
        "validator_mnemonic": validator_mnemonic,
    }
