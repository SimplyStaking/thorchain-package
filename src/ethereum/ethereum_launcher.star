"""
Ethereum node launcher for THORChain cross-chain testing.

Launches an Anvil (Foundry) Ethereum node with prefunded accounts
for THORChain's Bifrost signer.
"""

def launch_ethereum(plan):
    """Launch an Anvil Ethereum node.

    Anvil starts with 10 prefunded accounts (1000 ETH each) using
    deterministic keys derived from the default Anvil mnemonic:
      test test test test test test test test test test test junk

    Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    Private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

    Args:
        plan: Kurtosis plan object.

    Returns:
        dict with keys:
            - name: service name
            - service: Kurtosis service object
            - rpc_url: internal RPC URL (http://ethereum:8545)
    """
    service_name = "ethereum"

    ports = {
        "rpc": PortSpec(number=8545, transport_protocol="TCP", wait=None),
    }

    # Upload the THORChain router bytecode so it's available inside the container
    router_artifact = plan.upload_files(src="/src/ethereum/router-bytecode.txt")

    service = plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image="ghcr.io/foundry-rs/foundry:latest",
            ports=ports,
            entrypoint=["anvil"],
            cmd=[
                "--host", "0.0.0.0",
                "--port", "8545",
                "--chain-id", "1337",
                "--block-time", "1",
                "--accounts", "10",
                "--balance", "1000",
                "--gas-limit", "30000000",
            ],
            min_cpu=250,
            min_memory=512,
            files={
                "/opt/contracts": router_artifact,
            },
        ),
    )

    # Wait for Anvil RPC to be ready
    # The Foundry image only has anvil/cast/forge/chisel -- use cast for health check
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                """set -eu; export FOUNDRY_DISABLE_NIGHTLY_WARNING=1; i=0; while [ $i -lt 60 ]; do
          if cast block-number --rpc-url http://localhost:8545 >/dev/null 2>&1; then
            echo 'Anvil RPC ready'; exit 0;
          fi;
          sleep 1; i=$((i+1));
        done; echo 'Anvil RPC timeout'; exit 1""",
            ],
        ),
        description="Wait for Anvil RPC to be ready",
    )

    rpc_url = "http://{}:8545".format(service_name)

    # Deploy the THORChain router contract from Anvil account 0 (nonce 0).
    # The router handles ETH/ERC-20 deposits and outbound transfers for Bifrost.
    # Deploying at nonce 0 from the default Anvil account gives a deterministic
    # address: 0x5FbDB2315678afecb367f032d93F642f64180aa3
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                "set -eu; export FOUNDRY_DISABLE_NIGHTLY_WARNING=1; BYTECODE=$(cat /opt/contracts/router-bytecode.txt | tr -d '\\n'); cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url http://localhost:8545 --create $BYTECODE >/dev/null 2>&1; echo 'Router deployed at 0x5FbDB2315678afecb367f032d93F642f64180aa3'",
            ],
        ),
        description="Deploy THORChain router contract",
    )

    # The router address is deterministic (account 0, nonce 0)
    router_address = "0x5FbDB2315678afecb367f032d93F642f64180aa3"

    plan.print("✓ Ethereum (Anvil) node ready at {}".format(rpc_url))
    plan.print("  Router contract: {}".format(router_address))

    return {
        "name": service_name,
        "service": service,
        "rpc_url": rpc_url,
        "router_address": router_address,
    }
