def _build_env(chain_cfg):
    env_vars = {}
    chain_id = chain_cfg.get("chain_id", "")
    rpc_url = chain_cfg.get("rpc_url", "")
    api_url = chain_cfg.get("api_url", "")
    faucet_url = chain_cfg.get("faucet_url", "")

    if chain_id:
        env_vars["THORCHAIN_CHAIN_ID"] = chain_id
    if rpc_url:
        env_vars["THORCHAIN_REMOTE_RPC"] = rpc_url
    if api_url:
        env_vars["THORCHAIN_REMOTE_API"] = api_url
    if faucet_url:
        env_vars["THORCHAIN_REMOTE_FAUCET"] = faucet_url

    env_vars["THORCHAIN_PROFILE"] = chain_cfg.get("profile", chain_cfg.get("name", "thorchain"))
    return env_vars


toolchain = import_module("./toolchain.star")

def launch_cli_only(plan, chain_cfg):
    network_name = chain_cfg.get("name", "thorchain-cli")
    service_name = chain_cfg.get("service_name", "{}-cli".format(network_name))
    persistent_key = chain_cfg.get("persistent_key", "cli-{}-thornode-home".format(network_name))
    image = chain_cfg.get("cli_image", "tiljordan/thornode-forking:1.0.17")

    plan.print("Launching THORChain CLI utility container '{}'".format(service_name))

    # Ensure deterministic initialization script
    plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image=image,
            entrypoint=["/bin/sh", "-lc", "sleep infinity"],
            env_vars=_build_env(chain_cfg),
            min_cpu=chain_cfg.get("min_cpu", 250),
            min_memory=chain_cfg.get("min_memory", 256),
            files={
                "/root/.thornode": Directory(
                    persistent_key=persistent_key,
                    size=chain_cfg.get("persistent_size", 2048),
                ),
            },
        ),
    )

    # Prepare thornode home directory
    plan.exec(
        service_name,
        ExecRecipe(
            command=[
                "/bin/sh",
                "-lc",
                "mkdir -p /root/.thornode/config && touch /root/.thornode/config/.cli-placeholder",
            ],
        ),
        description="Initialize thornode home for CLI operations",
    )

    ensure_default_key = """
set -eu
thornode keys show default --keyring-backend test --output json >/tmp/default-key.json 2>/dev/null || \
thornode keys add default --keyring-backend test --output json >/tmp/default-key.json
"""

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/sh", "-lc", ensure_default_key],
        ),
        description="Ensure default CLI key exists",
    )

    metadata_script = """
python3 - <<'PY'
import json
import subprocess
from pathlib import Path

def read_key():
    try:
        proc = subprocess.run(
            ["thornode", "keys", "show", "default", "--keyring-backend", "test", "--output", "json"],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return {}
    try:
        return json.loads(proc.stdout or "{}")
    except Exception:
        return {}

data = {
    "profile": %(profile)r,
    "chain_id": %(chain_id)r,
    "rpc_url": %(rpc)r,
    "api_url": %(api)r,
    "faucet_url": %(faucet)r,
    "default_key": read_key(),
}
Path("/root/.thornode/cli_context.json").write_text(json.dumps(data, indent=2))
PY
""" % {
        "profile": chain_cfg.get("profile", network_name),
        "chain_id": chain_cfg.get("chain_id", ""),
        "rpc": chain_cfg.get("rpc_url", ""),
        "api": chain_cfg.get("api_url", ""),
        "faucet": chain_cfg.get("faucet_url", ""),
    }

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/sh", "-lc", metadata_script],
        ),
        description="Write CLI context metadata",
    )

    toolchain.run_toolchain_setup(plan, service_name)

    return {
        "name": service_name,
        "profile": chain_cfg.get("profile", network_name),
        "chain_id": chain_cfg.get("chain_id", ""),
        "rpc_url": chain_cfg.get("rpc_url", ""),
        "api_url": chain_cfg.get("api_url", ""),
        "faucet_url": chain_cfg.get("faucet_url", ""),
    }
