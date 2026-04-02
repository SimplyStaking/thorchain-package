# THORChain Mocknet

A Kurtosis package for deploying private THORChain mocknets with automated genesis generation, network launching, and auxiliary services.

## Overview

This package automates the deployment of complete THORChain networks through a coordinated orchestration pipeline:

1. **Configuration parsing** - Validates and applies defaults to user configuration
2. **Genesis file generation** - Creates blockchain initial state with validator keys and prefunded accounts
3. **Network deployment** - Launches THORChain nodes with proper seed node topology
4. **Service deployment** - Waits for first block production, then deploys auxiliary services

### Key Features
- **Automated genesis creation** with validator cryptographic material and account funding
- **Proper P2P topology** with first node as seed for network formation
- **Auxiliary services** including token faucets, blockchain indexers, and trading interfaces
- **State forking** support for testing against mainnet data
- **Flexible configuration** with comprehensive defaults and customization options
- **CosmWasm contract deployment** with mimir-based permission control

## Prerequisites

- [Kurtosis](https://docs.kurtosis.com/install) installed and running
- Basic understanding of THORChain and Cosmos SDK blockchain architecture
- Docker for running containerized services

## Quick Start

### Local Swap Testing (Recommended)

Deploy a THORChain mocknet with Bifrost, Bitcoin, and Ethereum for cross-chain swap testing:

```bash
kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
```

After deployment, bootstrap liquidity pools and run swaps:

```bash
./scripts/bootstrap-pools.sh
```

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for full walkthrough and [DEPLOYMENT_MANUAL.md](DEPLOYMENT_MANUAL.md) for pool bootstrapping, swap mechanics, and ERC-20 token deployment.

### Custom Configuration

Create a configuration file and deploy:

```bash
kurtosis run --enclave thorchain-testnet . --args-file your-config.yaml
```

Example minimal configuration:

```yaml
chains:
  - name: thorchain
    type: thorchain
    forking:
      enabled: false
    participants:
      - image: "registry.gitlab.com/thorchain/thornode:mocknet"
        count: 1
```

## Configuration

The package uses a comprehensive configuration system with defaults from `thorchain_defaults.json`. All parameters are optional and will fall back to sensible defaults.

### Chain Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `name` | Chain identifier for services | `"thorchain"` |
| `type` | Must be `"thorchain"` | `"thorchain"` |
| `chain_id` | Blockchain network ID | `"thorchain-localnet"` |
| `app_version` | THORChain application version | `"3.11.0"` |
| `participants` | Validator node configuration | 1 validator |
| `additional_services` | Services to deploy | `["faucet", "bdjuno"]` |
| `prefunded_accounts` | Genesis account funding | `{}` |
| `forking` | State forking configuration | Enabled (see note below) |

> **Note:** The default configuration has `forking.enabled: true` and references a Docker image (`tiljordan/thornode-forking`) that is **no longer available** on Docker Hub. You must explicitly set `forking.enabled: false` and provide a valid participant image (e.g., `registry.gitlab.com/thorchain/thornode:mocknet`) for deployment to succeed.

### Module Configuration

The package supports extensive Cosmos SDK module configuration including:
- **Consensus parameters** - Block size, gas limits, evidence parameters
- **Auth module** - Transaction limits, signature verification costs
- **Staking module** - Validator limits, minimum self-delegation
- **Mint module** - Inflation parameters, annual provisions
- **Bank module** - Token denomination and metadata

### Validator Configuration

```yaml
participants:
  - image: "registry.gitlab.com/thorchain/thornode:mocknet"
    account_balance: 1000000000000000
    bond_amount: "300000000000000"
    count: 1
    min_cpu: 500
    min_memory: 2048
    gomemlimit: "1GiB"
```

### CLI Container Configuration

The package can optionally deploy a CLI toolchain container alongside the network for local development workflows.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `deploy_cli` | boolean | `false` | Deploy CLI toolchain container with Rust 1.77, wasm-tools, CosmWasm build support |

**Note**: Package defaults to `false` for cloud efficiency. MCP tooling overrides to `true` for developer convenience.

**Enable CLI container for local development:**

```yaml
chains:
  - name: thorchain
    deploy_cli: true  # Rust toolchain, pre-configured faucet key, contract build tools
```

**Cloud deployment (minimal resources):**

```yaml
chains:
  - name: thorchain
  # deploy_cli: false (default) - saves ~250MB RAM, 250m CPU, 2GB disk
```

**CLI container features:**
- Rust 1.77.1 toolchain for CosmWasm contract compilation
- wasm-tools and wasm-opt for WASM optimization
- Pre-configured keyring with imported faucet account
- Direct network access to thornode RPC and API
- Persistent storage for build artifacts

### CLI-Only Container (Remote Networks)

Deploy a lightweight CLI container to interact with remote THORChain networks (mainnet, testnet, or custom endpoints) without running a full node.

| Parameter | Type | Description |
|-----------|------|-------------|
| `config_type` | string | Set to `"cli_only"` to deploy CLI-only container |
| `profile` | string | Use predefined profile (`"mainnet"`, `"octhornet"`) or custom name |
| `rpc_url` | string | Custom RPC endpoint (overrides profile) |
| `api_url` | string | Custom API endpoint (overrides profile) |
| `faucet_url` | string | Custom faucet endpoint (optional) |

**Built-in profiles** (defined in [thorchain_defaults.json](src/package_io/thorchain_defaults.json:91-104)):
- `mainnet`: thorchain-1, thornode.ninerealms.com
- `octhornet`: thorchain testnet, bloctopus.io endpoints

**Connect to mainnet:**

```yaml
chains:
  - name: mainnet
    config_type: cli_only
    profile: mainnet
```

**Connect to custom remote network:**

```yaml
chains:
  - name: my-remote
    config_type: cli_only
    chain_id: thorchain-testnet-v1
    rpc_url: https://rpc.example.com:443
    api_url: https://api.example.com
    faucet_url: https://faucet.example.com  # optional
```

**Environment variables set in container:**
- `THORCHAIN_CHAIN_ID`: Chain identifier
- `THORCHAIN_REMOTE_RPC`: RPC endpoint URL
- `THORCHAIN_REMOTE_API`: REST API endpoint URL
- `THORCHAIN_REMOTE_FAUCET`: Faucet endpoint URL (if configured)
- `THORCHAIN_PROFILE`: Profile/network name

### Available Services

The package supports four auxiliary services that are deployed after the network produces its first block:

- **`faucet`** - HTTP API for token distribution using the last generated validator mnemonic
- **`midgard`** - THORChain block indexer with TimescaleDB backend, provides `/v2/actions` API for swap status tracking
- **`bdjuno`** - Complete blockchain indexing stack with PostgreSQL database, Hasura GraphQL API, Big Dipper web explorer, and Nginx reverse proxy
- **`swap-ui`** - Web interface for token swapping with support for prefunded account integration

## Service Endpoints

After deployment, services are accessible at:

### THORChain Nodes
- **RPC**: `http://<node-ip>:26657` - Tendermint RPC
- **API**: `http://<node-ip>:1317` - Cosmos REST API  
- **gRPC**: `<node-ip>:9090` - Cosmos gRPC (local)
- **eBifrost**: `<node-ip>:50051` - eBifrost attestation gRPC
- **P2P**: `<node-ip>:26656` - Peer-to-peer networking
- **Metrics**: `http://<node-ip>:26660` - Prometheus metrics

### Faucet Service
- **API**: `http://<faucet-ip>:8090` - Token distribution endpoint (`POST /fund`)
- **Usage**:
  ```bash
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"address":"<tthor1...>","amount":"1000000000","denom":"rune"}' \
    http://<faucet-ip>:8090/fund
  ```

### Midgard (Block Indexer)
- **API**: `http://<midgard-ip>:8080` - Swap status, pool history (`/v2/actions`, `/v2/pools`)
- **Database**: `<midgard-db-ip>:5432` - TimescaleDB backing store

### Block Explorer (BdJuno)
- **Explorer**: `http://<explorer-ip>:80` - Web interface
- **GraphQL**: `http://<hasura-ip>:8080` - Hasura GraphQL API
- **Database**: `<postgres-ip>:5432` - PostgreSQL database

### Swap UI
- **Interface**: `http://<swap-ui-ip>:80` - Web trading interface

## Bifrost + Cross-Chain Swaps

The package can optionally deploy Bifrost (THORChain's cross-chain bridge signer) along with external chain nodes for real cross-chain swap testing.

### Enabling Bifrost

Set `bifrost_enabled: true` in your chain configuration:

```yaml
chains:
  - name: thorchain
    type: thorchain
    bifrost_enabled: true      # Launch Bifrost + external chains
    bitcoin_enabled: true      # Bitcoin regtest (default: true when bifrost enabled)
    ethereum_enabled: true     # Ethereum via Anvil (default: true when bifrost enabled)
```

### What Gets Deployed

When Bifrost is enabled, the package launches (in order):

1. **Bitcoin regtest** (`lncm/bitcoind:v26.0`) — RPC on port 18443, with a wallet and 101 pre-mined blocks
2. **Ethereum Anvil** (`ghcr.io/foundry-rs/foundry`) — RPC on port 8545, 10 prefunded accounts with 1000 ETH each
3. **Bifrost** (`registry.gitlab.com/thorchain/thornode:mocknet`) — connected to THORNode + both chain nodes

The launcher waits for Bifrost to register its chains with THORNode (visible at `/thorchain/inbound_addresses`).

### Disabling Individual Chains

You can disable specific chains while keeping Bifrost:

```yaml
chains:
  - name: thorchain
    bifrost_enabled: true
    bitcoin_enabled: true
    ethereum_enabled: false    # Skip Ethereum
```

### Quote-Only Mode (Fast)

For tests that only need THORChain's quote endpoints (no actual swaps), keep `bifrost_enabled: false` (the default). This skips all external chain nodes and Bifrost, giving you a much faster startup:

```yaml
chains:
  - name: thorchain
    type: thorchain
    # bifrost_enabled: false   # default — no Bifrost, no external chains
```

### Service Endpoints (Bifrost Mode)

| Service | Port | Description |
|---------|------|-------------|
| Bitcoin RPC | 18443 | `bitcoin-cli -regtest -rpcuser=thorchain -rpcpassword=thorchain` |
| Bitcoin P2P | 18444 | Peer-to-peer (regtest) |
| Ethereum RPC | 8545 | Standard JSON-RPC (Anvil) |
| Bifrost P2P | 5040 | Bifrost peer-to-peer |
| Bifrost RPC | 6040 | Bifrost RPC |

### Supported Chains

| Chain | Image | Status |
|-------|-------|--------|
| Bitcoin | `lncm/bitcoind:v26.0` | ✅ Regtest with wallet + pre-mined blocks |
| Ethereum | `ghcr.io/foundry-rs/foundry:latest` | ✅ Anvil with prefunded accounts |

### Known Limitations

- Bifrost env var names and startup scripts are based on the THORChain localnet convention and may need adjustment for different THORNode image versions. Check the `TODO` comments in `src/bifrost/bifrost_launcher.star`.
- The Bifrost image uses `registry.gitlab.com/thorchain/thornode:mocknet` — ensure this tag exists or update to match your THORNode version.
- Cross-chain swap end-to-end tests require additional setup (vault funding, chain client configuration) beyond what this launcher provides out of the box.

## Advanced Features

### Prefunded Accounts

Fund accounts at genesis time by listing THORChain addresses under `prefunded_accounts`. No private keys are required or stored; addresses simply appear in genesis with the requested balance for every denom. If you also deploy CLI containers, you can optionally preload mnemonics via `cli_service.preload_keys` so the CLI keyring has convenient access to those funded accounts while keeping prefunding and key management decoupled. See [examples/prefunded-accounts.yaml](examples/prefunded-accounts.yaml) for a working example.

### State Forking

> **Currently broken.** State forking requires the `tiljordan/thornode-forking` Docker image which is no longer available on Docker Hub. The forking configs and examples below are preserved for reference but will not work until a replacement image is published.

Fork from mainnet state for realistic testing. Requires a forking-enabled THORNode image that can fetch state from the specified RPC endpoint. The package supports caching and configurable gas costs for state fetching operations.

## Examples

### Cross-Chain Swap Testing (Recommended)
Deploy with Bifrost + Bitcoin + Ethereum for real cross-chain swap testing ([examples/bifrost-no-fork.yaml](examples/bifrost-no-fork.yaml)):
```bash
kurtosis run --enclave thorchain-testnet . --args-file examples/bifrost-no-fork.yaml
```

Then bootstrap liquidity pools:
```bash
./scripts/bootstrap-pools.sh
```

### Custom Services
Deploy specific auxiliary services:
```yaml
chains:
  - name: thorchain
    type: thorchain
    forking:
      enabled: false
    participants:
      - image: "registry.gitlab.com/thorchain/thornode:mocknet"
        count: 1
    additional_services: ["faucet", "midgard", "bdjuno"]
    faucet:
      transfer_amount: 50000000000000  # Custom faucet amount (500k RUNE)
```

### Remote Network Connection (CLI-Only)
Connect to remote networks without running a full node ([examples/cli-only.yaml](examples/cli-only.yaml)):
```yaml
chains:
  # Built-in profile (mainnet or octhornet)
  - name: mainnet
    config_type: cli_only
    profile: mainnet

  # OR custom remote network
  - name: my-testnet
    config_type: cli_only
    chain_id: thorchain-testnet-v1
    rpc_url: https://rpc.example.com:443
    api_url: https://api.example.com
```

### CLI Key Preloading
Supply mnemonics exclusively to the CLI toolchain so they are ready for transactions without exposing keys to the network launcher:
```yaml
chains:
  - config_type: cli_only
    name: thorchain-cli
    rpc_url: "https://thornode.ninerealms.com:443"
    preload_keys:
      - name: integration-bot
        mnemonic: "<24-word mnemonic>"
```
The CLI launcher imports each mnemonic, warns if the derived address is *not* listed under `prefunded_accounts`, and automatically uses the first imported key as the CLI default.

### Prefunded Accounts
Fund specific accounts at genesis time ([examples/prefunded-accounts.yaml](examples/prefunded-accounts.yaml)):
> **Note:** This example uses forking mode, which is currently broken (see State Forking below). The `prefunded_accounts` feature itself works in non-forking mode with RUNE only.

```yaml
chains:
  - name: thorchain
    type: thorchain
    prefunded_accounts:
      thor1qpwyke4xyxjaa4rv6r46fflzs2w0vey0yf3kzs: 1000000000000000  # 1M RUNE
      thor1e0lmk5juawc46jwjwd0xfz587njej7ay5fh6cd: 500000000000000   # 500K RUNE
    deploy_cli: true
    cli_service:
      preload_keys:
        - name: alice
          mnemonic: "<24-word mnemonic for thor1qpwyke4xyxjaa4rv6r46fflzs2w0vey0yf3kzs>"
```

### State Forking (Currently Broken)
> Requires `tiljordan/thornode-forking` Docker image which is no longer available on Docker Hub.

Fork from mainnet state with a minimal config (examples/forking-genesis.yaml):
```yaml
chains:
  - name: thorchain
    type: thorchain
    chain_id: "thorchain-1"
    app_version: "3.11.0"
    forking:
      enabled: true
      image: "tiljordan/thornode-forking:1.0.25-23761879"  # unavailable
      height: 23015000
    participants:
      - image: "tiljordan/thornode-forking:1.0.25-23761879"  # unavailable
        count: 1
        account_balance: 1000000000000
        bond_amount: 500000000000
    additional_services:
      - faucet
```

### Contract Development Workflow

1. **Network Deployment**: Deploy a local mocknet using `bifrost-no-fork.yaml`
2. **Mimir Configuration**: `WASMPERMISSIONLESS=1` is set by default in genesis
3. **Contract Upload**: Use `thornode tx wasm store` to upload contract bytecode
4. **Contract Instantiation**: Use `thornode tx wasm instantiate` to create contract instances

You can override the WASM permission mimir in your args YAML:

```yaml
chains:
  - name: thorchain
    type: thorchain
    mimir:
      enabled: true
      values:
        WASMPERMISSIONLESS: 0   # override default 1
```

#### WASM Runtime Limitations
**Current Limitation**: THORChain's WASM runtime doesn't support bulk memory operations.
- Contracts compile successfully but fail WASM validation during deployment
- Error: "bulk memory support is not enabled"
- This is a known limitation, not a deployment failure

## Network Architecture

The package implements proper seed node topology:
- First node starts without seeds (becomes the seed node)
- Subsequent nodes connect to the first node via `--p2p.seeds`
- Ensures reliable network formation and connectivity

## Cleanup

Remove the deployment:

```bash
kurtosis enclave rm thorchain-testnet
```

## Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Step-by-step deployment instructions, accessing services, troubleshooting
- [DEPLOYMENT_MANUAL.md](DEPLOYMENT_MANUAL.md) - Pool bootstrapping, swap mechanics, ERC-20 tokens, extending with new chains
- [kurtosis.yml](kurtosis.yml) - Kurtosis package description and configuration schema
- Service launcher implementations in `src/` directory for advanced customization
