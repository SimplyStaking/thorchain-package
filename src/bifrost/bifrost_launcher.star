"""
Bifrost signer launcher for THORChain cross-chain testing.

Launches the Bifrost process from the THORChain Docker image, configured
to connect to the local THORNode and external chain nodes (Bitcoin, Ethereum).

The mocknet image ships with /scripts/bifrost.sh which:
  1. Sources /scripts/core.sh (validates SIGNER_NAME, SIGNER_PASSWD)
  2. Waits for THORChain API via /scripts/wait-for-thorchain-api.sh
  3. Creates the signer key via create_thor_user()
  4. Execs into the CMD (bifrost binary)
"""

# Default seed phrase for the Bifrost signer in localnet mode.
# This is the standard THORChain localnet seed -- NOT for production use.
LOCALNET_SEED_PHRASE = "dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog dog fossil"

def launch_bifrost(plan, thornode_service_name, bitcoin_info, ethereum_info, validator_mnemonic=""):
    """Launch a Bifrost signer connected to THORNode and external chains.

    Args:
        plan: Kurtosis plan object.
        thornode_service_name: Name of the THORNode service in the enclave.
        bitcoin_info: dict from bitcoin_launcher (name, rpc_url, rpc_user, rpc_pass).
            None if Bitcoin is disabled.
        ethereum_info: dict from ethereum_launcher (name, rpc_url).
            None if Ethereum is disabled.
        validator_mnemonic: The validator's mnemonic phrase. Bifrost must sign as the
            validator so that THORNode recognizes it as a whitelisted node account.

    Returns:
        dict with keys:
            - name: service name
            - service: Kurtosis service object
    """
    service_name = "bifrost"

    # Both use bare host:port. The Go code handles protocol prefixes internally.
    thornode_rpc = "{}:26657".format(thornode_service_name)
    thornode_api = "{}:1317".format(thornode_service_name)

    # Use the validator mnemonic so Bifrost derives the same address that is
    # registered in genesis node_accounts.  Fall back to the default localnet seed.
    signer_seed = validator_mnemonic if validator_mnemonic else LOCALNET_SEED_PHRASE

    # Environment variables expected by /scripts/core.sh and /scripts/bifrost.sh.
    # SIGNER_NAME + SIGNER_PASSWD are required by core.sh (validated on startup).
    # The bifrost.sh script calls create_thor_user(SIGNER_NAME, SIGNER_PASSWD, SIGNER_SEED_PHRASE)
    # which imports the key into the thornode keyring (file backend).
    env_vars = {
        # THORNode connection -- set both the legacy env vars AND the full Viper keys
        "CHAIN_API": thornode_api,
        "CHAIN_RPC": thornode_rpc,
        "BIFROST_THORCHAIN_CHAIN_HOST": thornode_api,
        "BIFROST_THORCHAIN_CHAIN_RPC": thornode_rpc,
        "BIFROST_SIGNER_BLOCK_SCANNER_RPC_HOST": thornode_rpc,

        # eBifrost attestation gRPC -- in v3.x, observations are submitted via
        # the eBifrost gRPC service running inside thornode (port 50051), not via
        # legacy MsgObservedTxIn broadcasts. Point Bifrost at thornode's gRPC.
        "BIFROST_THORCHAIN_CHAIN_EBIFROST": "{}:50051".format(thornode_service_name),

        # Signer identity -- SIGNER_NAME is required by core.sh
        "SIGNER_NAME": "thorchain",
        "SIGNER_PASSWD": "password",
        "SIGNER_SEED_PHRASE": signer_seed,

        # General
        "NET": "mocknet",
        "CHAIN_ID": "thorchain-localnet",

        # Override Bifrost signer keygen/keysign timeouts to be shorter than
        # the JailTimeKeygen/JailTimeKeysign constants (10 blocks = 10s in mocknet).
        # Without this, Bifrost fatals: "keygen timeout must be shorter than jail time".
        # Viper key: bifrost.signer.keygen_timeout -> env: BIFROST_SIGNER_KEYGEN_TIMEOUT
        "BIFROST_SIGNER_KEYGEN_TIMEOUT": "8s",
        "BIFROST_SIGNER_KEYSIGN_TIMEOUT": "8s",

        # The signer's THORChain block scanner needs to start near the current chain
        # height so it can immediately process outbound transactions. Setting 0 tells
        # GetStartHeight() to use the latest observed height from /thorchain/lastblock.
        # This works because we seed last_chain_heights in genesis.
        # Viper path: bifrost.signer.block_scanner.start_block_height
        "BIFROST_SIGNER_BLOCK_SCANNER_START_BLOCK_HEIGHT": "0",

        # Disable all chains we are NOT running. The default config enables all chains
        # and Bifrost fatals if it can't find an RPC host for any enabled chain.
        "GAIA_DISABLED": "true",
        "DOGE_DISABLED": "true",
        "LTC_DISABLED": "true",
        "AVAX_DISABLED": "true",
        "BIFROST_CHAINS_BCH_DISABLED": "true",
        "BIFROST_CHAINS_BSC_DISABLED": "true",
        "BIFROST_CHAINS_BASE_DISABLED": "true",
        "BIFROST_CHAINS_TRON_DISABLED": "true",
        "BIFROST_CHAINS_XRP_DISABLED": "true",
        "BIFROST_CHAINS_SOL_DISABLED": "true",
        "BIFROST_CHAINS_POL_DISABLED": "true",
        "BIFROST_CHAINS_ZEC_DISABLED": "true",
        "BIFROST_CHAINS_NOBLE_DISABLED": "true",
        "BIFROST_CHAINS_SUI_DISABLED": "true",
        "BIFROST_CHAINS_ADA_DISABLED": "true",
    }

    # Bitcoin chain client config
    if bitcoin_info:
        # Append /wallet/thorchain to the RPC URL so the Bitcoin RPC routes
        # to the named wallet (required by Bitcoin Core v26+ multi-wallet).
        btc_wallet_url = bitcoin_info["rpc_url"] + "/wallet/thorchain"
        env_vars["BTC_HOST"] = btc_wallet_url
        env_vars["BIFROST_CHAINS_BTC_RPC_HOST"] = btc_wallet_url
        env_vars["BIFROST_CHAINS_BTC_USERNAME"] = bitcoin_info["rpc_user"]
        env_vars["BIFROST_CHAINS_BTC_PASSWORD"] = bitcoin_info["rpc_pass"]
        env_vars["BIFROST_CHAINS_BTC_HTTP_POST_MODE"] = "1"
        env_vars["BIFROST_CHAINS_BTC_DISABLE_TLS"] = "1"
    else:
        env_vars["BIFROST_CHAINS_BTC_DISABLED"] = "true"

    # Ethereum chain client config
    if ethereum_info:
        env_vars["BIFROST_CHAINS_ETH_RPC_HOST"] = ethereum_info["rpc_url"]
        env_vars["ETH_HOST"] = ethereum_info["rpc_url"]
    else:
        env_vars["BIFROST_CHAINS_ETH_DISABLED"] = "true"

    ports = {
        "p2p": PortSpec(number=5040, transport_protocol="TCP", wait=None),
        "rpc": PortSpec(number=6040, transport_protocol="TCP", wait=None),
    }

    # Use the image's own /scripts/bifrost.sh as entrypoint.
    # It sources core.sh, waits for the THORChain API, creates the signer key,
    # then execs into the CMD we pass (the bifrost binary).
    service = plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image="registry.gitlab.com/thorchain/thornode:mocknet",
            ports=ports,
            entrypoint=["/scripts/bifrost.sh"],
            cmd=["bifrost", "-p"],
            env_vars=env_vars,
            min_cpu=500,
            min_memory=1024,
        ),
    )

    plan.print("Bifrost signer launched")

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
while [ $i -lt 60 ]; do
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
echo "WARNING: Not all chains registered after 60s. Check Bifrost logs."
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
