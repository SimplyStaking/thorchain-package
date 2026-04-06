"""
Midgard indexer launcher for THORChain mocknet.

Launches TimescaleDB (Postgres) and Midgard, which indexes THORChain blocks
and exposes a REST API used by aggregators and frontends for swap status,
pool history, and action queries (/v2/actions, /v2/health, /v2/pools, etc.).
"""

TIMESCALEDB_IMAGE = "timescale/timescaledb:2.13.0-pg15"
MIDGARD_IMAGE = "registry.gitlab.com/thorchain/midgard:2.34.1"

DB_USER = "midgard"
DB_PASSWORD = "password"
DB_NAME = "midgard"

def launch_midgard(plan, chain_name):
    """Launch Midgard indexer with TimescaleDB backend.

    Args:
        plan: Kurtosis plan object.
        chain_name: Name of the THORChain network (e.g. "thorchain").

    Returns:
        dict with keys:
            - name: midgard service name
            - service: Kurtosis service object
            - api_url: internal API URL (http://midgard:8080)
    """
    node_service = plan.get_service(name="{}-node".format(chain_name))

    # --- TimescaleDB ---
    timescaledb_name = "{}-midgard-db".format(chain_name)
    timescaledb_service = plan.add_service(
        name=timescaledb_name,
        config=ServiceConfig(
            image=TIMESCALEDB_IMAGE,
            ports={
                "db": PortSpec(number=5432, transport_protocol="TCP", wait=None),
            },
            env_vars={
                "POSTGRES_USER": DB_USER,
                "POSTGRES_PASSWORD": DB_PASSWORD,
                "POSTGRES_DB": DB_NAME,
            },
            # TimescaleDB benefits from larger shared memory for query plans
            cmd=["postgres", "-c", "plan_cache_mode=force_custom_plan"],
            min_cpu=250,
            min_memory=512,
        ),
    )

    # Wait for TimescaleDB to be fully ready.
    # pg_isready is insufficient — it returns success as soon as the socket
    # accepts connections, before extensions are loaded and the DB is queryable.
    # Midgard connects immediately on startup and crashes if the DB isn't
    # ready to handle queries (observed as "Failed to look up 'constants' table"
    # followed by exit code 1, which Kurtosis then reports as exit 137).
    plan.exec(
        service_name=timescaledb_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh", "-c",
                """set -eu; i=0; while [ $i -lt 30 ]; do
          if psql -U {user} -d {db} -tAc "SELECT count(*) FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null | grep -q "1"; then
            echo 'TimescaleDB ready (extension loaded)'; exit 0;
          fi;
          sleep 1; i=$((i+1));
        done; echo 'TimescaleDB timeout'; exit 1""".format(user=DB_USER, db=DB_NAME),
            ],
        ),
        description="Wait for TimescaleDB to be ready (extension verified)",
    )

    # --- Midgard config ---
    node_ip = node_service.ip_address
    rpc_port = node_service.ports["rpc"].number
    api_port = node_service.ports["api"].number
    db_ip = timescaledb_service.ip_address
    db_port = timescaledb_service.ports["db"].number

    # Go template for Midgard config.json — Kurtosis render_templates uses Go text/template
    config_template = """{
  "listen_port": 8080,
  "max_block_age": "600s",
  "thorchain": {
    "tendermint_url": "http://{{ .NodeIP }}:{{ .RpcPort }}/websocket",
    "thornode_url": "http://{{ .NodeIP }}:{{ .ApiPort }}/thorchain",
    "last_chain_backoff": "7s",
    "fetch_batch_size": 100,
    "parallelism": 4,
    "read_timeout": "32s"
  },
  "timescale": {
    "host": "{{ .DbIP }}",
    "port": {{ .DbPort }},
    "user_name": "{{ .DbUser }}",
    "password": "{{ .DbPass }}",
    "database": "{{ .DbName }}",
    "sslmode": "disable",
    "commit_batch_size": 100,
    "max_open_conns": 20
  },
  "websockets": {
    "enable": false,
    "connection_limit": 100
  }
}"""

    config_artifact = plan.render_templates(
        config={
            "config.json": struct(
                template=config_template,
                data={
                    "NodeIP": node_ip,
                    "RpcPort": rpc_port,
                    "ApiPort": api_port,
                    "DbIP": db_ip,
                    "DbPort": db_port,
                    "DbUser": DB_USER,
                    "DbPass": DB_PASSWORD,
                    "DbName": DB_NAME,
                },
            ),
        },
        name="{}-midgard-config".format(chain_name),
    )

    # Verify DB accepts queries right before launching Midgard.
    # This guards against the race where TimescaleDB briefly drops
    # connections between the readiness check and Midgard's startup.
    plan.exec(
        service_name=timescaledb_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh", "-c",
                """psql -U {user} -d {db} -c 'SELECT 1' >/dev/null 2>&1 && echo 'DB query OK' || (echo 'DB query failed'; exit 1)""".format(
                    user=DB_USER, db=DB_NAME,
                ),
            ],
        ),
        description="Verify DB accepts queries before Midgard launch",
    )

    # --- Midgard service ---
    midgard_name = "{}-midgard".format(chain_name)
    midgard_service = plan.add_service(
        name=midgard_name,
        config=ServiceConfig(
            image=MIDGARD_IMAGE,
            ports={
                "api": PortSpec(number=8080, transport_protocol="TCP", wait=None),
            },
            files={
                "/config": config_artifact,
            },
            cmd=["./midgard", "/config/config.json"],
            min_cpu=250,
            min_memory=512,
        ),
    )

    # Wait for Midgard to start syncing (health endpoint returns 200).
    # Timeout increased to 90s (from 60s) and poll interval reduced to 1s
    # to catch Midgard startup faster. The previous 60s/2s combination was
    # too tight on slower hosts where the DB connection + initial sync takes
    # longer.
    plan.exec(
        service_name=midgard_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh", "-c",
                """set -eu; i=0; while [ $i -lt 90 ]; do
          if wget -qO- http://localhost:8080/v2/health >/dev/null 2>&1; then
            echo 'Midgard API ready'; exit 0;
          fi;
          sleep 1; i=$((i+1));
        done; echo 'Midgard health timeout after 90s'; exit 1""",
            ],
        ),
        description="Wait for Midgard API to be ready",
    )

    api_url = "http://{}:8080".format(midgard_name)
    plan.print("✓ Midgard indexer ready at {}".format(api_url))

    return {
        "name": midgard_name,
        "service": midgard_service,
        "api_url": api_url,
    }
