def read_json_file(file_path):
    local_contents = read_file(src=file_path)
    return json.decode(local_contents)

# Paths to the default JSON files
DEFAULT_THORCHAIN_FILE = "./thorchain_defaults.json"

def _is_valid_cli_key_name(name):
    if not name or type(name) != "string":
        return False
    # Check if name contains only alphanumeric, hyphen, or underscore
    # Use index-based iteration since string iteration may not work in all Starlark versions
    for i in range(len(name)):
        ch = name[i]
        if ("a" <= ch and ch <= "z") or ("A" <= ch and ch <= "Z") or ("0" <= ch and ch <= "9"):
            continue
        if ch in ["-", "_"]:
            continue
        return False
    return True

def _validate_cli_preload_config(context, preload_keys):
    if preload_keys == None:
        preload_keys = []
    if type(preload_keys) != "list":
        fail("{} preload_keys must be a list".format(context))

    seen_names = {}
    for idx, entry in enumerate(preload_keys):
        if type(entry) != "dict":
            fail("{} preload_keys entry at index {} must be a dictionary".format(context, idx))

        name = entry.get("name")
        mnemonic = entry.get("mnemonic")

        if type(name) != "string" or not name:
            fail("{} preload key entry {} must include a non-empty 'name'".format(context, idx))
        if not _is_valid_cli_key_name(name):
            fail("{} preload key name '{}' must use alphanumeric, '-' or '_' characters".format(context, name))
        if name in seen_names:
            fail("{} preload key name '{}' is duplicated".format(context, name))
        seen_names[name] = True

        if type(mnemonic) != "string" or not mnemonic.strip():
            fail("{} preload key '{}' must include a mnemonic string".format(context, name))
        words = [w for w in mnemonic.strip().split(" ") if w]
        if len(words) < 12:
            fail("{} preload key '{}' mnemonic must contain at least 12 words".format(context, name))

    return seen_names.keys()

def apply_chain_defaults(chain, defaults):
    # Simple key-value defaults
    chain["name"] = chain.get("name", defaults["name"])
    chain["type"] = chain.get("type", defaults["type"])
    chain["chain_id"] = chain.get("chain_id", defaults["chain_id"])
    chain["genesis_delay"] = chain.get("genesis_delay", defaults["genesis_delay"])
    chain["chain_contracts"] = chain.get("chain_contracts", defaults["chain_contracts"])
    chain["app_version"] = chain.get("app_version", defaults["app_version"])
    chain["reserve_amount"] = chain.get("reserve_amount", defaults["reserve_amount"])
    chain["node_persistent_size_mb"] = chain.get(
        "node_persistent_size_mb", defaults.get("node_persistent_size_mb", 16384)
    )

    # Nested defaults
    chain["denom"] = chain.get("denom", {})
    for key, value in defaults["denom"].items():
        chain["denom"][key] = chain["denom"].get(key, value)

    chain["faucet"] = chain.get("faucet", {})
    for key, value in defaults["faucet"].items():
        chain["faucet"][key] = chain["faucet"].get(key, value)

    chain["consensus"] = chain.get("consensus", {})
    for key, value in defaults["consensus"].items():
        chain["consensus"][key] = chain["consensus"].get(key, value)

    chain["modules"] = chain.get("modules", {})
    for module, module_defaults in defaults["modules"].items():
        chain["modules"][module] = chain["modules"].get(module, {})
        for key, value in module_defaults.items():
            chain["modules"][module][key] = chain["modules"][module].get(key, value)

    # Apply defaults to participants
    if "participants" not in chain:
        chain["participants"] = defaults["participants"]
    else:
        default_participant = defaults["participants"][0]
        participants = []
        for participant in chain["participants"]:
            for key, value in default_participant.items():
                participant[key] = participant.get(key, value)
            participants.append(participant)
        chain["participants"] = participants

    # Apply defaults to additional services
    if "additional_services" not in chain:
        chain["additional_services"] = defaults["additional_services"]

    # Apply defaults to prefunded_accounts
    if "prefunded_accounts" not in chain:
        chain["prefunded_accounts"] = {}

    # Apply defaults to forking
    chain["forking"] = chain.get("forking", {})
    for key, value in defaults["forking"].items():
        chain["forking"][key] = chain["forking"].get(key, value)

    # Apply defaults to mimir
    chain["mimir"] = chain.get("mimir", {})
    for key, value in defaults["mimir"].items():
        if key == "values":
            # Handle nested mimir values
            chain["mimir"][key] = chain["mimir"].get(key, {})
            for mimir_key, mimir_value in value.items():
                chain["mimir"][key][mimir_key] = chain["mimir"][key].get(mimir_key, mimir_value)
        else:
            chain["mimir"][key] = chain["mimir"].get(key, value)

    # Apply defaults for the companion CLI service consumed by MCP tooling.
    cli_defaults = defaults.get("cli_defaults", {})
    chain_name = chain.get("name", defaults.get("name", "thorchain"))
    chain["cli_service"] = chain.get("cli_service", {})
    cli_service = chain["cli_service"]

    cli_service["name"] = cli_service.get("name", "{}-cli".format(chain_name))
    cli_service["image"] = cli_service.get(
        "image", cli_defaults.get("image", defaults["participants"][0]["image"]))
    cli_service["persistent_key"] = cli_service.get(
        "persistent_key", "cli-{}-thornode-home".format(chain_name))
    cli_service["persistent_size"] = cli_service.get(
        "persistent_size", cli_defaults.get("persistent_size", 2048))
    cli_service["min_cpu"] = cli_service.get(
        "min_cpu", cli_defaults.get("min_cpu", 250))
    cli_service["min_memory"] = cli_service.get(
        "min_memory", cli_defaults.get("min_memory", 128))
    cli_service["skip_toolchain_setup"] = cli_service.get(
        "skip_toolchain_setup", False)
    cli_service["preload_keys"] = cli_service.get("preload_keys", [])
    chain["deploy_cli"] = chain.get("deploy_cli", defaults.get("deploy_cli", False))

    return chain

def validate_input_args(input_args):
    if not input_args or "chains" not in input_args:
        fail("Input arguments must include the 'chains' field.")

    chain_names = []
    for chain in input_args["chains"]:
        if "name" not in chain or "type" not in chain:
            fail("Each chain must specify a 'name' and a 'type'.")
        if chain["name"] in chain_names:
            fail("Duplicate chain name found: " + chain["name"])
        if chain["type"] != "thorchain":
            fail("Unsupported chain type: "+ chain["type"])
        chain_names.append(chain["name"])

        # Validate prefunded_accounts if present
        if "prefunded_accounts" in chain:
            prefunded = chain["prefunded_accounts"]

            # Must be a dict
            if type(prefunded) != "dict":
                fail("prefunded_accounts must be a dictionary mapping addresses to amounts")

            # Validate each entry
            for addr in prefunded:
                amount = prefunded[addr]

                # Validate address format
                if type(addr) != "string":
                    fail("prefunded_accounts keys must be strings (thor1... addresses)")

                if not addr.startswith("thor1"):
                    fail("prefunded_accounts address '{}' must start with 'thor1'".format(addr))

                addr_len = len(addr)
                if addr_len < 40 or addr_len > 64:
                    fail("prefunded_accounts address '{}' must be between 40 and 64 characters (got {})".format(addr, addr_len))

                # Validate amount type and convert to int
                value_type = type(amount)
                if value_type != "int" and value_type != "string":
                    fail("prefunded_accounts amount for '{}' must be an integer or numeric string".format(addr))

                # Convert to int (will fail with clear error if string is not numeric)
                amt_int = int(amount)

                if amt_int <= 0:
                    fail("prefunded_accounts amount for '{}' must be positive (got {})".format(addr, amount))

        config_type = chain.get("config_type", "network")
        if config_type == "cli_only":
            preload_keys = chain.get("preload_keys", [])
            context = "CLI-only '{}'".format(chain["name"])
        else:
            cli_cfg = chain.get("cli_service", {})
            preload_keys = cli_cfg.get("preload_keys", [])
            context = "CLI service for '{}'".format(chain["name"])

        _validate_cli_preload_config(context, preload_keys)

def input_parser(input_args=None):
    thorchain_defaults = read_json_file(DEFAULT_THORCHAIN_FILE)
    cli_defaults = thorchain_defaults.get("cli_defaults", {})
    cli_profiles = thorchain_defaults.get("cli_profiles", {})

    result = {"chains": []}

    if not input_args:
        input_args = {"chains": [thorchain_defaults]}

    validate_input_args(input_args)

    if "chains" not in input_args:
        result["chains"].append(thorchain_defaults)
    else:
        for chain in input_args["chains"]:
            chain_type = chain.get("type", "thorchain")
            if chain_type == "thorchain":
                defaults = thorchain_defaults
            else:
                fail("Unsupported chain type: " + chain_type)

            config_type = chain.get("config_type", "network")
            if config_type == "cli_only":
                profile_name = chain.get("profile", chain.get("name", "thorchain"))
                profile_defaults = cli_profiles.get(profile_name, {})

                cli_chain = {
                    "name": chain.get("name", profile_name),
                    "type": "thorchain",
                    "config_type": "cli_only",
                    "profile": profile_name,
                    "service_name": chain.get("service_name", "{}-cli".format(chain.get("name", profile_name))),
                    "chain_id": chain.get("chain_id", profile_defaults.get("chain_id", defaults.get("chain_id", "thorchain"))),
                    "rpc_url": chain.get("rpc_url", profile_defaults.get("rpc_url", "")),
                    "api_url": chain.get("api_url", profile_defaults.get("api_url", "")),
                    "faucet_url": chain.get("faucet_url", profile_defaults.get("faucet_url", "")),
                    "cli_image": chain.get("cli_image", chain.get("image", cli_defaults.get("image", defaults["participants"][0]["image"]))),
                    "persistent_key": chain.get("persistent_key", "cli-{}-thornode-home".format(profile_name)),
                    "min_cpu": chain.get("min_cpu", cli_defaults.get("min_cpu", 250)),
                    "min_memory": chain.get("min_memory", cli_defaults.get("min_memory", 256)),
                    "persistent_size": chain.get("persistent_size", cli_defaults.get("persistent_size", 2048)),
                    "preload_keys": chain.get("preload_keys", []),
                    "prefunded_accounts": chain.get("prefunded_accounts", {}),
                }

                result["chains"].append(cli_chain)
                continue

            # Apply defaults to chain
            chain_config = apply_chain_defaults(chain, defaults)

            result["chains"].append(chain_config)

    return result
