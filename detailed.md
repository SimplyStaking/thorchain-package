# Prefunded Accounts Support – Detailed Plan

## 1. System Context
- **Configuration ingestion** happens in `src/package_io/input_parser.star`, which merges `src/package_io/thorchain_defaults.json` with the user-supplied YAML and performs validation before any services are launched.
- **Network bootstrapping** is orchestrated by `src/network_launcher/single_node_launcher.star`. It performs four important phases relevant to prefunding:
  1. Generates validator/faucet accounts and builds `/tmp/accounts_fragment.json` plus `/tmp/balances_fragment.json` (initially rune-only balances) and `/tmp/rune_supply.txt`.
  2. Fetches upstream bank supply from NineRealms and produces `/tmp/merged_balances_fragment.json` and `/tmp/supply_fragment.json`, which contain the multi-denom faucet snapshot and supply adjustments.
  3. Applies all fragments to the forked genesis via two `sed` passes, then runs a Python sanity check that recalculates bank supply from the merged balances and writes `/tmp/merged_balances_str.txt` + `/tmp/supply_str.json`.
  4. Runs a final JSON patch that recomputes `app_state.bank.supply` from the actual `balances`. These steps make sure the faucet’s synthetic funds are reflected everywhere in the genesis.
- **Faucet logic** drives the denomination list: every denom reported by NineRealms is funded with the configured faucet amount. Prefunded accounts must reuse this codepath so they inherit the same denom coverage and supply adjustments.
- **CLI containers** (both CLI-only deployments and the optional CLI service that accompanies a network) previously imported the faucet key and generated a random `default` account. They now need a dedicated path to import user-supplied mnemonics, warn when those keys are not prefunded, and optionally set the `default` key to one of the imported entries—all without ever requiring prefunded accounts to expose private keys.

## 2. Prefunded Accounts Requirements
1. **Configuration format** – YAML takes an address→amount map:
   ```yaml
   thorchain:
     prefunded_accounts:
       thor1qpwyke4xyxjaa4rv6r46fflzs2w0vey0yf3kzs: 1000000000000000
       thor1e0lmk5juawc46jwjwd0xfz587njej7ay5fh6cd: 500000000000000
   ```
   Only bech32 `thor1…` addresses are accepted; users manage their own mnemonics offline.
2. **Funding scope** – Each prefunded account must receive the requested amount for *every* denom fetched from mainnet, exactly like the faucet.
3. **Supply integrity** – `__RUNE_SUPPLY__`, `/tmp/supply_fragment.json`, `/tmp/merged_balances_fragment.json`, and the final `app_state.bank.supply` must reflect the additional coins so the chain starts with a consistent ledger.
4. **Observability** – The launcher should log how many prefunded accounts were configured and the total RUNE minted for them, so users immediately see what will be injected into genesis.

## 3. CLI Key Preloading Requirements
1. **Isolation from prefunding** – `prefunded_accounts` remains address-only to avoid exposing keys. CLI key import lives under `cli_service.preload_keys` (for network deployments) or `preload_keys` (for CLI-only launches).
2. **Config shape** – Each entry needs a `name` and `mnemonic`. A `default_account` flag controls which key (faucet, random, or one of the imported names) should be aliased as the CLI’s `default`.
   ```yaml
   cli_service:
     preload_keys:
       - name: alice
         mnemonic: "<24-word mnemonic>"
     default_account: alice  # options: default, faucet, or key name
   ```
3. **Importer behavior**
   - Import mnemonics idempotently (delete existing key first).
   - Warn if the derived address is **not** in the prefunded set (only when prefunding is configured).
   - Preserve previously generated `default` keys unless an override is explicitly requested.
   - Support both CLI-with-network (which also imports the faucet mnemonic) and CLI-only deployments.

## 4. Implementation Touchpoints
### 3.1 Defaults (`src/package_io/thorchain_defaults.json`)
- Add an explicit `"prefunded_accounts": {}` entry so templates without prefunding do not error out during parsing.

### 3.2 Input parser (`src/package_io/input_parser.star`)
- Extend `validate_input_args` to verify:
  * `prefunded_accounts` is a dict.
  * Keys are strings that start with `thor1` and have a sane bech32 length (40–64 chars to accommodate all valid addresses).
  * Values are ints or numeric strings that convert via `int()` and are strictly positive.
- This prevents cryptic launcher failures when invalid data propagates into the network phase.

### 3.3 Network launcher (`src/network_launcher/single_node_launcher.star`)
1. **Configuration extraction**
   - Convert the dict into a `prefunded_list` of `{address, amount}` pairs once, summing a `prefunded_rune_total` used for logging and rune-supply math.
2. **Accounts/Balances fragments**
   - Append every prefunded address to the `accounts` and `balances` arrays before writing `/tmp/accounts_fragment.json` and `/tmp/balances_fragment.json`.
3. **Total rune supply**
   - Update `total_rune_supply` (written to `/tmp/rune_supply.txt`) to include the validator balance, faucet amount, *and* the total prefunded rune amount. This value later populates the reserve placeholder in genesis.
4. **NineRealms merge step**
   - Reuse the faucet denom list: for each denom, append a balance entry per prefunded account so `/tmp/merged_balances_fragment.json` contains `len(prefunded_accounts)` additional rows mirroring the faucet coins. Also add their amounts into every denom entry inside `/tmp/supply_fragment.json`.
5. **Genesis patch helper**
   - When recalculating supply after the first `sed` pass, prefer `/tmp/merged_balances_fragment.json` (if it exists) instead of the raw `/tmp/balances_fragment.json`. This preserves the multi-denom faucet/prefund snapshot during the sanity-check phase and guarantees the `__SUPPLY__` placeholder plus the final post-processing script include every prefunded coin.
6. **CLI preload validation**
   - Validate `cli_service.preload_keys` (or CLI-only `preload_keys`) to ensure well-formed names, 12+ word mnemonics, and `default_account` values that are either `default`, `faucet`, or one of the defined names.
7. **CLI key manager helper (`src/network_launcher/cli_key_manager.star`)**
   - Shared utility invoked by both `single_node_launcher` (for the optional CLI service) and `cli_only_launcher`.
   - Responsibilities: import faucet mnemonic, ensure/override the `default` key, loop through preload entries, print success/warning messages depending on prefunding, and keep behavior idempotent across restarts.
8. **Launchers**
   - `single_node_launcher.star`: after provisioning the CLI container, fetch the faucet mnemonic and call the helper with the configured `preload_keys`, prefunded map, and desired default target.
   - `cli_only_launcher.star`: call the helper with an empty faucet mnemonic so CLI-only deployments can still preload mnemonics and set the default key even when no network services are running.

## 5. Step-by-Step Implementation Plan
1. **Defaults** – Add `"prefunded_accounts": {}` to `thorchain_defaults.json`.
2. **Parser validation** – Insert the validation block described above inside `validate_input_args` so invalid YAML aborts early.
3. **Launcher setup**
   - Build `prefunded_list` (with `int(amount)` conversion) and compute `prefunded_rune_total` for logs and rune supply math.
   - Pass both values into the Python template that prepares `/tmp/accounts_fragment.json`, `/tmp/balances_fragment.json`, and `/tmp/rune_supply.txt` so the genesis fragments contain the new accounts from the very beginning.
4. **Multi-denom funding**
   - In the script that fetches NineRealms supply, iterate `prefunded_list` when constructing balances and supplies so each account mirrors the faucet’s per-denom distribution.
5. **Genesis merge + supply recompute**
   - Update the validation Python snippet to read `/tmp/merged_balances_fragment.json` when available, ensuring the recomputed `merged_balances_str.txt` and `supply_str.json` retain the prefunded coins.
6. **CLI key helper & launchers**
   - Add `src/network_launcher/cli_key_manager.star` and invoke it from both launchers. Feed it the faucet mnemonic (if available), the prefunded map (for warning/success messaging), `cli_service.preload_keys`, and `default_account`.
   - Ensure CLI-only launches include `preload_keys` fields so the helper can run independently of any network deployment.
7. **Documentation / examples**
   - Provide an end-to-end reference (`examples/prefunded-accounts.yaml`) demonstrating both prefunding and CLI preload syntax, plus this `detailed.md` walkthrough so future contributors understand the moving pieces.

## 6. Testing & Verification Checklist
1. **Happy path** – Run `kurtosis run . --args-file examples/prefunded-accounts.yaml` and confirm:
   - `thorchain-node` genesis contains the prefunded addresses under both `auth.accounts` and `bank.balances` with hundreds of denoms each.
   - `bank.supply` entries increased by `faucet_amount + Σ(prefunded_amount)` for every denom.
   - `app_state.thorchain.reserve` (or whichever field consumes `__RUNE_SUPPLY__`) matches `mainnet_rune_supply + validator_balance + faucet_amount + Σ(prefunded_amount)`.
2. **Invalid configs** – Intentionally break the YAML (non-string key, value of `0`, address not starting with `thor1`) and ensure `kurtosis` fails during parsing with the new validation errors.
3. **Edge cases** – Try 0 prefunded accounts (should just log zero), multiple addresses with different amounts, and large integers (greater than faucet) to make sure `int()` coercion and supply updates handle big numbers.
4. **Runtime probes** – After launch, exec into the node and run:
   ```sh
   thornode query bank balances <prefunded-address>
   thornode query bank balances <prefunded-address> --denom btc-btc
   thornode query bank balances <prefunded-address> --denom eth-eth
   ```
   to verify that every denom is credited with the configured amount.
5. **CLI preloading**
   - For network deployments with `deploy_cli: true`, exec into the CLI container and run `thornode keys list --keyring-backend test` to ensure each preloaded key is present.
   - Observe launcher logs for `✓` vs `⚠` messages indicating whether imported keys match prefunded accounts.
   - Verify that `thornode keys show default` resolves to the requested `default_account` (faucet, random, or named key), and that CLI-only deployments behave identically.

Following this plan keeps prefunded accounts consistent with the faucet implementation, maintains supply integrity, and documents the entire workflow for future maintainers.
