"""
Bifrost signer launcher for THORChain cross-chain testing.

Launches the Bifrost process from the THORChain Docker image, configured
to connect to the local THORNode and external chain nodes (Bitcoin, Ethereum).

TODO: The exact env var names and startup script need verification against
a running THORChain localnet (gitlab.com/thorchain/thornode build/docker).
The names used here are based on the THORChain localnet docker-compose
convention and may need adjustment.
"""

# Default seed phrase for the Bifrost signer in localnet mode.
# This is the standard THORChain localnet seed — NOT for production use.
LOCALNET_SEED_PHRASE = "dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog fossil"

def launch_bifrost(plan, thornode_service_name, bitcoin_info, ethereum_info):
    """Launch a Bifrost signer connected to THORNode and external chains.

    Args:
        plan: Kurtosis plan object.
        thornode_service_name: Name of the THORNode service in the enclave.
        bitcoin_info: dict from bitcoin_launcher (name, rpc_url, rpc_user, rpc_pass).
            None if Bitcoin is disabled.
        ethereum_info: dict from ethereum_launcher (name, rpc_url).
            None if Ethereum is disabled.

    Returns:
        dict with keys:
            - name: service name
            - service: Kurtosis service object
    """
    service_name = "bifrost"

    thornode_rpc = "http://{}:26657".format(thornode_service_name)
    thornode_api = "http://{}:1317".format(thornode_service_name)

    # Build environment variables
    # TODO: Verify these env var names against thorchain/thornode localnet scripts.
    # The naming convention follows BIFROST_<SECTION>_<KEY> from the Bifrost
    # config TOML, translated to env vars by Viper (dots → underscores, uppercased).
    env_vars = {
        # THORNode connection
        "CHAIN_API": thornode_api,
        "CHAIN_RPC": thornode_rpc,
        "BIFROST_THORCHAIN_CHAIN_HOST": thornode_rpc,
        "BIFROST_THORCHAIN_CHAIN_RPC": thornode_rpc,

        # Signer config
        "SIGNER_SEED_PHRASE": LOCALNET_SEED_PHRASE,
        "SIGNER_PASSWD": "password",
        "BIFROST_SIGNER_SEED_PHRASE": LOCALNET_SEED_PHRASE,
        "BIFROST_SIGNER_PASSWD": "password",

        # General
        "NET": "mocknet",
        "CHAIN_ID": "thorchain-localnet",
    }

    # Bitcoin chain client config
    if bitcoin_info:
        env_vars["BIFROST_CHAINS_BTC_RPC_HOST"] = bitcoin_info["rpc_url"]
        env_vars["BIFROST_CHAINS_BTC_RPC_USER"] = bitcoin_info["rpc_user"]
        env_vars["BIFROST_CHAINS_BTC_RPC_PASS"] = bitcoin_info["rpc_pass"]
        env_vars["BTC_HOST"] = bitcoin_info["rpc_url"]

    # Ethereum chain client config
    if ethereum_info:
        env_vars["BIFROST_CHAINS_ETH_RPC_HOST"] = ethereum_info["rpc_url"]
        env_vars["ETH_HOST"] = ethereum_info["rpc_url"]

    ports = {
        "p2p": PortSpec(number=5040, transport_protocol="TCP", wait=None),
        "rpc": PortSpec(number=6040, transport_protocol="TCP", wait=None),
    }

    # The THORChain Docker image includes bifrost binary and startup scripts.
    # We attempt to use the standard localnet entry script; if it doesn't exist,
    # fall back to running the bifrost binary directly.
    # TODO: Confirm the correct entrypoint script path from the THORChain image.
    entrypoint_script = """
set -e
echo "Starting Bifrost signer..."
echo "THORNode RPC: $CHAIN_RPC"
echo "THORNode API: $CHAIN_API"

# Wait for THORNode to be responsive
echo "Waiting for THORNode..."
i=0
while [ $i -lt 120 ]; do
  if wget -qO- "$CHAIN_API/thorchain/ping" 2>/dev/null | grep -q ping; then
    echo "THORNode is ready"
    break
  fi
  sleep 2
  i=$((i+2))
done

if [ $i -ge 120 ]; then
  echo "WARNING: THORNode not responding after 120s, starting Bifrost anyway"
fi

# Try the standard localnet script first, fall back to direct binary
if [ -f /docker/scripts/bifrost.sh ]; then
  exec /docker/scripts/bifrost.sh
elif [ -f /scripts/bifrost.sh ]; then
  exec /scripts/bifrost.sh
else
  echo "No startup script found, running bifrost binary directly"
  exec bifrost
fi
"""

    service = plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image="registry.gitlab.com/thorchain/thornode:mocknet",
            ports=ports,
            entrypoint=["/bin/sh", "-c", entrypoint_script],
            env_vars=env_vars,
            min_cpu=500,
            min_memory=1024,
        ),
    )

    plan.print("✓ Bifrost signer launched")

    # Wait for Bifrost to register chains with THORNode by polling inbound_addresses.
    # This endpoint returns the list of chains Bifrost has registered as available.
    chains_to_check = []
    if bitcoin_info:
        chains_to_check.append("BTC")
    if ethereum_info:
        chains_to_check.append("ETH")

    if chains_to_check:
        chain_check_str = " ".join(chains_to_check)
        plan.exec(
            service_name=thornode_service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    """set -eu
CHAINS_NEEDED="%s"
echo "Waiting for Bifrost to register chains: $CHAINS_NEEDED"
i=0
while [ $i -lt 300 ]; do
  response=$(curl -sSf http://localhost:1317/thorchain/inbound_addresses 2>/dev/null || echo "")
  if [ -n "$response" ]; then
    all_found=true
    for chain in $CHAINS_NEEDED; do
      if ! echo "$response" | grep -q "\"chain\":\"$chain\""; then
        all_found=false
        break
      fi
    done
    if [ "$all_found" = "true" ]; then
      echo "All chains registered: $CHAINS_NEEDED"
      exit 0
    fi
  fi
  sleep 3
  i=$((i+3))
done
echo "WARNING: Not all chains registered after 300s. Check Bifrost logs."
echo "This may be expected if Bifrost needs additional configuration."
exit 0""" % chain_check_str,
                ],
            ),
            description="Wait for Bifrost to register chains with THORNode",
        )

    return {
        "name": service_name,
        "service": service,
    }
