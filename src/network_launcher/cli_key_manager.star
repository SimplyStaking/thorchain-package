def configure_cli_keys(plan, service_name, preload_keys=None, prefunded_accounts=None):
    preload_keys = preload_keys or []
    prefunded_accounts = prefunded_accounts or {}

    script = """
set -eu
python3 - <<'PY'
import json
import subprocess
import sys
from pathlib import Path

preload_keys = %(preload_keys)r
prefunded_accounts = %(prefunded_accounts)r

prefunded_amounts = {}
if isinstance(prefunded_accounts, dict):
    for addr, amount in prefunded_accounts.items():
        if isinstance(addr, str):
            try:
                prefunded_amounts[addr] = str(int(amount))
            except Exception:
                prefunded_amounts[addr] = str(amount)

def log(msg):
    print("[cli-preload] {}".format(msg))

def run_cmd(cmd, input_str=None, ignore_errors=False):
    proc = subprocess.run(cmd, input=input_str, text=True, capture_output=True)
    if proc.returncode != 0 and not ignore_errors:
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise subprocess.CalledProcessError(proc.returncode, cmd, proc.stdout, proc.stderr)
    return proc

def extract_address(output):
    try:
        data = json.loads(output or "{}")
        addr = data.get("address")
        if isinstance(addr, str):
            return addr
    except Exception:
        pass
    return ""

def fetch_address(name):
    proc = run_cmd(["thornode","keys","show",name,"--keyring-backend","test","--output","json"], ignore_errors=True)
    if proc.returncode != 0:
        return ""
    return extract_address(proc.stdout)

def import_from_mnemonic(name, mnemonic, label):
    mnemonic = (mnemonic or "").strip()
    if not mnemonic:
        log("Skipping import for key '{}' - empty mnemonic".format(label or name))
        return ""
    run_cmd(["thornode","keys","delete",name,"--keyring-backend","test","--yes"], ignore_errors=True)
    run_cmd(
        ["thornode","keys","add",name,"--keyring-backend","test","--recover","--output","json"],
        input_str=mnemonic + "\\n",
    )
    addr = fetch_address(name)
    label_txt = label or name
    if addr:
        log("Imported key '{}' -> {}".format(label_txt, addr))
    else:
        log("Imported key '{}'".format(label_txt))
    return addr

def create_random_default():
    run_cmd(["thornode","keys","delete","default","--keyring-backend","test","--yes"], ignore_errors=True)
    proc = run_cmd(
        ["thornode","keys","add","default","--keyring-backend","test","--output","json"],
        input_str="\\n",
    )
    addr = extract_address(proc.stdout) or fetch_address("default")
    if addr:
        log("Generated new 'default' key -> {}".format(addr))
    else:
        log("Generated new 'default' key")
    return addr

def ensure_default_exists():
    addr = fetch_address("default")
    if addr:
        return addr
    return create_random_default()

prefunded_alias_options = ["prefunded_account", "prefunded_user_account"]
assigned_prefunded_aliases = []

def reserve_prefunded_alias():
    for alias in prefunded_alias_options:
        if alias not in assigned_prefunded_aliases:
            assigned_prefunded_aliases.append(alias)
            return alias
    return ""

preloaded_info = {}
preload_order = []
selected_name = ""
selected_addr = ""

# Import preload keys first (before faucet)
for entry in preload_keys:
    if not isinstance(entry, dict):
        continue
    name = entry.get("name")
    mnemonic = entry.get("mnemonic", "")
    if not isinstance(name, str) or not name:
        continue
    addr = import_from_mnemonic(name, mnemonic, name)
    final_name = name
    if addr and prefunded_amounts and addr in prefunded_amounts:
        alias = reserve_prefunded_alias()
        if alias:
            if alias != name:
                log("Renaming prefunded key '{}' -> '{}'".format(name, alias))
                run_cmd(["thornode","keys","delete",name,"--keyring-backend","test","--yes"], ignore_errors=True)
                addr = import_from_mnemonic(alias, mnemonic, alias)
            final_name = alias
        else:
            log("⚠ Prefunded key '{}' cannot reserve canonical alias; keeping original name".format(name))
    preload_order.append(final_name)
    preloaded_info[final_name] = {"address": addr, "mnemonic": mnemonic}
    if addr and prefunded_amounts:
        amount = prefunded_amounts.get(addr)
        if amount:
            log("✓ Key '{}' matches prefunded account {} base units".format(final_name, amount))
        else:
            log("⚠ Key '{}' ({}) not found in prefunded_accounts; it will start empty".format(final_name, addr))

if preload_order:
    selected_name = preload_order[0]
    selected_addr = preloaded_info.get(selected_name, {}).get("address") or fetch_address(selected_name)
    if selected_addr:
        log("Using preload key '{}' as CLI default ({})".format(selected_name, selected_addr))
    else:
        log("⚠ Preload key '{}' missing address; CLI keyring may be empty".format(selected_name))
else:
    selected_name = "default"
    selected_addr = ensure_default_exists()
    if selected_addr:
        log("No preload keys supplied; generated '{}' key -> {}".format(selected_name, selected_addr))
    else:
        log("⚠ No preload keys supplied and failed to create 'default' key")

state_path = Path("/root/.thornode/.cli_default_account")
try:
    state_path.write_text(json.dumps({"name": selected_name, "address": selected_addr}, indent=2))
except Exception as exc:
    log("⚠ Failed to persist CLI default metadata: {}".format(exc))
PY
""" % {
        "preload_keys": preload_keys,
        "prefunded_accounts": prefunded_accounts,
    }

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/sh", "-lc", script],
        ),
        description="Configure CLI keyring",
    )
