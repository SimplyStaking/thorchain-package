def configure_cli_keys(plan, service_name, faucet_mnemonic="", preload_keys=None, prefunded_accounts=None, default_account="default"):
    preload_keys = preload_keys or []
    prefunded_accounts = prefunded_accounts or {}
    default_account = default_account or "default"

    script = """
set -eu
python3 - <<'PY'
import json
import subprocess
import sys

preload_keys = %(preload_keys)r
prefunded_accounts = %(prefunded_accounts)r
default_account = %(default_account)r
faucet_mnemonic = %(faucet_mnemonic)r

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

if faucet_mnemonic and faucet_mnemonic.strip():
    faucet_addr = import_from_mnemonic("faucet", faucet_mnemonic, "faucet")
    if faucet_addr and faucet_addr in prefunded_amounts:
        log("Faucet address {} carries {} base units per denom".format(faucet_addr, prefunded_amounts[faucet_addr]))
else:
    log("No faucet mnemonic supplied; skipping faucet import")

default_target = (default_account or "default").strip() or "default"
preloaded_info = {}

for entry in preload_keys:
    if not isinstance(entry, dict):
        continue
    name = entry.get("name")
    mnemonic = entry.get("mnemonic", "")
    if not isinstance(name, str) or not name:
        continue
    addr = import_from_mnemonic(name, mnemonic, name)
    preloaded_info[name] = {"address": addr, "mnemonic": mnemonic}
    if addr and prefunded_amounts:
        amount = prefunded_amounts.get(addr)
        if amount:
            log("✓ Key '{}' matches prefunded account {} base units".format(name, amount))
        else:
            log("⚠ Key '{}' ({}) not found in prefunded_accounts; it will start empty".format(name, addr))

if default_target == "default":
    ensure_default_exists()
elif default_target == "faucet":
    if faucet_mnemonic and faucet_mnemonic.strip():
        addr = import_from_mnemonic("default", faucet_mnemonic, "default (faucet)")
        if addr:
            log("Set 'default' key to faucet address {}".format(addr))
    else:
        log("⚠ Requested faucet as default but no faucet mnemonic available; generating random 'default' key")
        create_random_default()
else:
    info = preloaded_info.get(default_target)
    if info and info.get("mnemonic"):
        addr = import_from_mnemonic("default", info["mnemonic"], "default ({})".format(default_target))
        if addr:
            log("Set 'default' key to '{}' ({})".format(default_target, addr))
    else:
        log("⚠ Requested default_account '{}' not found in preload_keys; leaving existing 'default' key".format(default_target))
        if not fetch_address("default"):
            create_random_default()

final_default = fetch_address("default")
if final_default:
    log("'default' key ready ({})".format(final_default))
else:
    create_random_default()
PY
""" % {
        "preload_keys": preload_keys,
        "prefunded_accounts": prefunded_accounts,
        "default_account": default_account,
        "faucet_mnemonic": faucet_mnemonic or "",
    }

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/sh", "-lc", script],
        ),
        description="Configure CLI keyring (faucet + preload keys)",
    )
