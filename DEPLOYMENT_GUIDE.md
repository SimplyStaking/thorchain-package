# THORChain Local Deployment Guide

Step-by-step guide for deploying a local THORChain testnet with cross-chain swap support. Works on macOS, Linux, and any system with Docker.

## Prerequisites

### 1. Docker

Docker Desktop (macOS/Windows) or Docker Engine (Linux) must be installed and running.

```bash
# Verify Docker is running
docker info --format '{{.ServerVersion}}'
```

**Minimum resources**: 2 CPU cores, 10 GB RAM allocated to Docker.

### 2. Kurtosis CLI

**macOS (Homebrew):**
```bash
brew install kurtosis-tech/tap/kurtosis-cli
```

**Linux (apt):**
```bash
echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" | sudo tee /etc/apt/sources.list.d/kurtosis.list
sudo apt update
sudo apt install kurtosis-cli
```

**Other platforms:** See [Kurtosis install docs](https://docs.kurtosis.com/install).

```bash
# Verify installation
kurtosis version
```

### 3. Start the Kurtosis Engine

```bash
kurtosis engine start
```

This pulls several Docker images on first run (may take a few minutes).

---

## Deployment Configurations

### Quick Reference

| Config File | Use Case | Startup Time | Services |
|---|---|---|---|
| `examples/bifrost-no-fork.yaml` | Local swap testing | ~2-5 min | THORNode, Faucet, Bitcoin, Ethereum, Bifrost |
| `examples/forking-disabled.yaml` | Simple THORNode only | ~1-2 min | THORNode only |
| `examples/bifrost-enabled.yaml` | Cross-chain with mainnet state | ~10-20 min | THORNode (forked), Faucet, Bitcoin, Ethereum, Bifrost |
| `examples/forking-enabled.yaml` | Mainnet fork + CLI + MIMIR | ~10-20 min | THORNode (forked), Faucet, CLI |
| `examples/forking-genesis.yaml` | Mainnet fork (genesis template) | ~10-20 min | THORNode (forked), Faucet |
| `examples/prefunded-accounts.yaml` | Pre-funded test accounts | ~10-20 min | THORNode (forked), Faucet |
| `examples/cli-only.yaml` | CLI for remote networks | ~30 sec | CLI container only |

---

## Local Swap Testing (Recommended for Development)

This deploys a fresh THORChain with cross-chain bridge support -- no mainnet forking, no real fees, fast startup.

### Deploy

```bash
# From the repository root
kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
```

### What Gets Deployed

| Service | Image | Ports | Description |
|---|---|---|---|
| `thorchain-node` | `thorchain/thornode:mocknet` | RPC:26657, API:1317, gRPC:9090, P2P:26656, Metrics:26660 | THORChain validator node |
| `thorchain-faucet` | `thorchain/thornode:mocknet` | HTTP:8090 | Token faucet (free RUNE) |
| `bitcoin` | `lncm/bitcoind:v26.0` | RPC:18443, P2P:18444 | Bitcoin regtest node |
| `ethereum` | `foundry-rs/foundry:latest` | RPC:8545 | Ethereum Anvil node |
| `bifrost` | `thorchain/thornode:mocknet` | P2P:5040, RPC:6040 | Cross-chain bridge signer |

### Accessing Services

After deployment, Kurtosis maps container ports to your host. Get the actual mapped ports with:

```bash
kurtosis enclave inspect thorchain-testnet
```

Example output shows port mappings like `26657/tcp -> 127.0.0.1:32789`. Use the host port to connect.

### Getting Test Tokens

**RUNE (via faucet):**
```bash
# Replace <FAUCET_PORT> with the mapped port from `kurtosis enclave inspect`
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"address":"tthor1...your-address...","amount":"1000000000","denom":"rune"}' \
  http://127.0.0.1:<FAUCET_PORT>/fund
```

**Bitcoin:** 101 blocks are pre-mined with a `thorchain` wallet. RPC credentials: `thorchain` / `thorchain`.

**Ethereum:** Anvil starts with 10 prefunded accounts (1000 ETH each). Default mnemonic: `test test test test test test test test test test test junk`.

### Interacting with THORNode

```bash
# Query node status (replace <RPC_PORT>)
curl -s http://127.0.0.1:<RPC_PORT>/status | jq .

# Query Cosmos REST API (replace <API_PORT>)
curl -s http://127.0.0.1:<API_PORT>/cosmos/bank/v1beta1/balances/tthor1... | jq .

# Check inbound addresses (cross-chain vaults)
curl -s http://127.0.0.1:<API_PORT>/thorchain/inbound_addresses | jq .
```

### Quick Access (After Deployment)

Get the mapped ports for your deployment:
```bash
kurtosis enclave inspect thorchain-testnet
```

Then use the mapped ports (examples use placeholder `<PORT>`):

```bash
# Check THORNode status
curl -s http://127.0.0.1:<RPC_PORT>/status | jq .result.sync_info

# THORChain ping
curl -s http://127.0.0.1:<API_PORT>/thorchain/ping

# Check validator balance (use your validator address from deploy output)
curl -s http://127.0.0.1:<API_PORT>/cosmos/bank/v1beta1/balances/<tthor1...> | jq .

# Fund an address via the faucet
curl -X POST -H "Content-Type: application/json" \
  -d '{"address":"tthor1...","amount":"1000000000","denom":"rune"}' \
  http://127.0.0.1:<FAUCET_PORT>/fund

# Check inbound addresses (shows registered Bifrost chains)
curl -s http://127.0.0.1:<API_PORT>/thorchain/inbound_addresses | jq .

# Check MIMIR values
curl -s http://127.0.0.1:<API_PORT>/thorchain/mimir | jq .

# Bitcoin: query blockchain info
bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain \
  -rpcconnect=127.0.0.1 -rpcport=<BTC_RPC_PORT> getblockchaininfo

# Ethereum: query latest block via Anvil
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:<ETH_RPC_PORT>
```

---

## Simple THORNode (No Cross-Chain)

For basic THORChain testing without Bifrost/Bitcoin/Ethereum:

```bash
kurtosis run --enclave thorchain-simple . --args-file examples/forking-disabled.yaml
```

---

## Mainnet Fork with Cross-Chain

For testing against real mainnet state (slower startup, requires internet):

```bash
kurtosis run --enclave thorchain-fork . --args-file examples/bifrost-enabled.yaml
```

---

## Operations

### Inspect Running Services

```bash
# List all services and their ports
kurtosis enclave inspect thorchain-testnet

# View logs for a specific service
kurtosis service logs thorchain-testnet thorchain-node

# Follow logs in real-time
kurtosis service logs thorchain-testnet thorchain-node --follow

# Execute a command inside a service container
kurtosis service exec thorchain-testnet thorchain-node -- thornode status
```

### Stop and Cleanup

```bash
# Stop the enclave (keeps data)
kurtosis enclave stop thorchain-testnet

# Remove the enclave completely
kurtosis enclave rm thorchain-testnet

# Remove ALL enclaves
kurtosis clean -a

# Stop the Kurtosis engine
kurtosis engine stop
```

### Restart After Reboot

```bash
# Start the engine
kurtosis engine start

# Re-deploy (previous enclave data is lost after engine stop)
kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
```

---

## Deploying on Other Systems

### Remote Linux Server

```bash
# 1. Install Docker
curl -fsSL https://get.docker.com | sh

# 2. Install Kurtosis
echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" | sudo tee /etc/apt/sources.list.d/kurtosis.list
sudo apt update && sudo apt install -y kurtosis-cli

# 3. Start engine and deploy
kurtosis engine start
git clone <this-repository>
cd thorchain-package
kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
```

### CI/CD Pipeline

```yaml
# Example GitHub Actions step
- name: Deploy THORChain testnet
  run: |
    kurtosis engine start
    kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
    # Run your tests against the services...
    kurtosis enclave rm thorchain-testnet
```

### Deploy from Remote (Without Cloning)

```bash
# Deploy directly from GitHub (uses default config)
kurtosis run --enclave thorchain-testnet github.com/0xBloctopus/thorchain-package

# Deploy from GitHub with a specific config
kurtosis run --enclave thorchain-testnet github.com/0xBloctopus/thorchain-package \
  '{"chains":[{"name":"thorchain","type":"thorchain","bifrost_enabled":true,"bitcoin_enabled":true,"ethereum_enabled":true,"forking":{"enabled":false},"participants":[{"image":"registry.gitlab.com/thorchain/thornode:mocknet","count":1,"account_balance":1000000000000000,"bond_amount":300000000000000,"min_memory":2048,"gomemlimit":"1GiB"}],"faucet":{"faucet_amount":1000000000000000,"transfer_amount":10000000000000},"additional_services":["faucet"]}]}'
```

---

## Resource Requirements

| Configuration | CPU | RAM | Disk | Network |
|---|---|---|---|---|
| Simple THORNode | 1 core | 4 GB | 10 GB | None |
| Bifrost (no fork) | 2 cores | 8 GB | 15 GB | None |
| Mainnet fork | 2 cores | 10 GB | 20 GB | Internet (downloads mainnet state) |
| Full stack (fork + BDJuno) | 4 cores | 16 GB | 30 GB | Internet |

---

## Troubleshooting

### Engine won't start
```bash
# Check Docker is running
docker ps
# Restart the engine
kurtosis engine restart
```

### Service fails to start
```bash
# Check logs for the failing service
kurtosis service logs thorchain-testnet <service-name>
```

### Node not producing blocks
The node waits up to 30 minutes for the first block (especially with forking enabled). Check logs:
```bash
kurtosis service logs thorchain-testnet thorchain-node --follow
```

### Port already in use
Kurtosis auto-assigns host ports, so port conflicts are rare. If you have a stale enclave:
```bash
kurtosis clean -a
```

### Docker credential warnings
Warnings like `error executing credential helper 'docker-credential-osxkeychain'` are benign. Kurtosis falls back to unauthenticated pulls, which works for all public images used here.

### Bifrost `event_client` subscription errors

You may see repeated gRPC errors in Bifrost logs like:
```
Subscription error  error="rpc error: code = Unavailable desc = connection error:
  desc = \"transport: Error while dialing: dial tcp [::1]:50051: connect: connection refused\""
```

These are **benign**. The `event_client` tries to connect to the eBifrost attestation
gRPC service (port 50051) which is not running in a single-validator mocknet. Bifrost
falls back to standard block scanning and operates normally without it.

### Bifrost logs show `fail to get THORChain block height`

On a fresh chain, you may briefly see `failed to GetThorchainHeight` errors from
solvency checkers and block scanners while the chain bootstraps. These resolve
once the first few blocks are produced and `/thorchain/lastblock` is populated
from the genesis-seeded chain heights.

To check Bifrost health:
```bash
kurtosis service logs thorchain-testnet bifrost --follow
```

Look for `scan block ... healthy=true` entries for BTC and ETH chains, and
`node is now active, will begin observation and gossip` to confirm Bifrost is
operational.
