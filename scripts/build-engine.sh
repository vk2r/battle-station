#!/usr/bin/env bash
# Build bin/engine and place all-smi's AMD companion (liball_smi_amd.so) beside it.
# Tools come from mise.toml: `mise install`, then `mise run build`.
#
# Cargo builds outside the plugin folder: Omarchy reloads a plugin whenever a file
# under ~/.config/omarchy/plugins/ changes, and a target/ dir there would keep
# triggering reloads during a build.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/battle-station-engine/target}"

cargo build --locked --release --manifest-path "$root/engine/Cargo.toml"

mkdir -p "$root/bin"
install -m 755 "$CARGO_TARGET_DIR/release/engine" "$root/bin/engine"

# The companion must come from the same all-smi release as the crate (shared ABI).
all_smi="$(mise where github:lablup/all-smi 2>/dev/null || true)"
if [[ -f $all_smi/liball_smi_amd.so ]]; then
  install -m 755 "$all_smi/liball_smi_amd.so" "$root/bin/liball_smi_amd.so"
else
  echo "build-engine: liball_smi_amd.so not found (run 'mise install'); AMD GPUs will not be read" >&2
fi

ls -l "$root/bin"
