def run_toolchain_setup(plan, service_name):
    verify_script = r"""
set -euo pipefail

missing=""
for bin in rustup cargo wasm-tools wasm-opt; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    missing="$missing $bin"
  fi
done

if [ -n "${missing}" ]; then
  echo "Missing required toolchain components:${missing}" >&2
  exit 1
fi

if ! rustup toolchain list | grep -q "1\.77\.1"; then
  echo "Rust toolchain 1.77.1 not installed (rustup toolchain list)" >&2
  exit 1
fi

echo "✓ Rust 1.77.1 toolchain and wasm utilities detected"
"""

    plan.exec(
        service_name,
        ExecRecipe(
            command=["/bin/bash", "-lc", verify_script],
        ),
        description="Verify Rust 1.77.1 toolchain and wasm tooling",
    )
