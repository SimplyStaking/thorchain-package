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
        ),
    )

    # Wait for Anvil RPC to be ready
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                """set -eu; i=0; while [ $i -lt 60 ]; do
          if wget -qO- http://localhost:8545 --post-data='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | grep -q result; then
            echo 'Anvil RPC ready'; exit 0;
          fi;
          sleep 1; i=$((i+1));
        done; echo 'Anvil RPC timeout'; exit 1""",
            ],
        ),
        description="Wait for Anvil RPC to be ready",
    )

    rpc_url = "http://{}:8545".format(service_name)

    plan.print("✓ Ethereum (Anvil) node ready at {}".format(rpc_url))

    return {
        "name": service_name,
        "service": service,
        "rpc_url": rpc_url,
    }
