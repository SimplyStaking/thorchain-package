def run_toolchain_setup(plan, service_name):
    """Ensure Rust 1.77.x toolchain and wasm utilities are installed inside the service."""
    setup_script = r"""
set -euxo pipefail

APT_UPDATED=0

ensure_pkg() {
  pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    if [ "${APT_UPDATED:-0}" -eq 0 ]; then
      apt-get update
      APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

ensure_base_packages() {
  ensure_pkg curl
  ensure_pkg build-essential
  ensure_pkg pkg-config
  ensure_pkg libssl-dev
  ensure_pkg bash
}

ensure_binaryen() {
  if ! command -v wasm-opt >/dev/null 2>&1; then
    ensure_pkg binaryen
  fi
}

ensure_rustup() {
  if ! command -v rustup >/dev/null 2>&1; then
    curl --retry 5 --retry-connrefused --retry-delay 2 https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
  fi
  source "$HOME/.cargo/env"
  if ! rustup toolchain list | grep -q "1\.77\.1"; then
    rustup toolchain install 1.77.1
  fi
  export RUSTUP_TOOLCHAIN=1.77.1
}

ensure_wasm_tools() {
  source "$HOME/.cargo/env"
  if ! command -v wasm-tools >/dev/null 2>&1; then
    cargo +1.77.1 install wasm-tools --locked
  fi
}

ensure_base_packages
ensure_rustup
ensure_binaryen
ensure_wasm_tools
"""

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/bash", "-lc", setup_script],
        ),
        description="Install Rust 1.77.1 toolchain and wasm tooling",
    )
