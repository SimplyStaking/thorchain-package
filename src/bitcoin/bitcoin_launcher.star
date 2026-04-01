"""
Bitcoin Core regtest node launcher for THORChain cross-chain testing.

Launches a Bitcoin Core node in regtest mode with RPC access configured
for THORChain's Bifrost signer.
"""

def launch_bitcoin(plan):
    """Launch a Bitcoin Core regtest node.

    Args:
        plan: Kurtosis plan object.

    Returns:
        dict with keys:
            - name: service name
            - service: Kurtosis service object
            - rpc_url: internal RPC URL (http://bitcoin:18443)
            - rpc_user: RPC username
            - rpc_pass: RPC password
    """
    service_name = "bitcoin"

    ports = {
        "rpc": PortSpec(number=18443, transport_protocol="TCP", wait=None),
        "p2p": PortSpec(number=18444, transport_protocol="TCP", wait=None),
    }

    service = plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image="lncm/bitcoind:v26.0",
            ports=ports,
            cmd=[
                "-regtest",
                "-rpcuser=thorchain",
                "-rpcpassword=thorchain",
                "-rpcallowip=0.0.0.0/0",
                "-rpcbind=0.0.0.0",
                "-txindex=1",
                "-fallbackfee=0.0002",
                "-server=1",
                "-listen=1",
                "-deprecatedrpc=create_bdb",
            ],
            min_cpu=250,
            min_memory=512,
        ),
    )

    # Wait for Bitcoin RPC to be ready
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                """set -eu; i=0; while [ $i -lt 60 ]; do
          if bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain getblockchaininfo >/dev/null 2>&1; then
            echo 'Bitcoin RPC ready'; exit 0;
          fi;
          sleep 1; i=$((i+1));
        done; echo 'Bitcoin RPC timeout'; exit 1""",
            ],
        ),
        description="Wait for Bitcoin RPC to be ready",
    )

    # Generate initial blocks so there are spendable coins
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                """bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain createwallet "thorchain" false false "" false false && \
bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain -generate 101""",
            ],
        ),
        description="Create wallet and mine initial 101 blocks",
    )

    rpc_url = "http://{}:18443".format(service_name)

    plan.print("✓ Bitcoin regtest node ready at {}".format(rpc_url))

    return {
        "name": service_name,
        "service": service,
        "rpc_url": rpc_url,
        "rpc_user": "thorchain",
        "rpc_pass": "thorchain",
    }
