# Development notes

Usage is in [README.md](README.md); this file covers what you need to change the plugin.

## Setup

The build tools are pinned in `mise.toml`: Rust, `protoc` (needed by all-smi's build script), the all-smi release that provides `liball_smi_amd.so`, and `cargo-about` for the third-party license notice.

```sh
mise install            # Rust, protoc, all-smi, cargo-about
mise run build          # rebuild bin/engine and copy bin/liball_smi_amd.so beside it
mise run licenses       # regenerate licenses/THIRD-PARTY.txt (after changing dependencies)
mise run snapshot       # print one snapshot (bin/engine --once)
mise run validate       # omarchy plugin validate .
mise run version 1.2.0  # set manifest.json to 1.2.0, commit and tag v1.2.0
```

- Cargo builds into `~/.cache/battle-station-engine/target`, outside the plugin folder, because Omarchy reloads a plugin whenever a file in it changes.
- Omarchy installs plugins with a plain `git clone` and never builds, so `bin/` is committed. CI builds it (see [Binaries and releases](#binaries-and-releases)); a local `mise run build` is only for testing, or for other architectures (e.g. aarch64), where it is run once in the plugin folder. Run `git config core.hooksPath .githooks` once per clone: its `pre-commit` hook refuses commits that touch `bin/` (drop local builds with `git restore bin/`).
- Commit `engine/Cargo.lock`, and `licenses/THIRD-PARTY.txt` after `mise run licenses`, when the dependencies change.
- The all-smi crate (`engine/Cargo.toml`) and the all-smi tool in `mise.toml` must stay on the same version: the engine loads the companion library through a versioned ABI.
- The JSON the engine prints is the contract with the QML (`EngineHub.qml` → `BarWidget.qml` / `Panel.qml`); keep its shape when changing the engine.

## Engine details

- **One-shot llama.cpp tools** (`llama-tts`, `llama-cli`, `llama-mtmd-cli`, ...) count as llama.cpp while they run. They have no HTTP API, so they show model, VRAM, CPU, RAM and the parent program, but no context or output buffers.
- **Evicted memory (AMD).** VRAM the driver moved to system RAM is read from DRM `fdinfo` (`amd-requested-vram` minus `drm-resident-vram`) and shown as the `!` in the bar; other drivers do not expose it.
- **Context and output buffers.** llama.cpp: tokens from `/slots`, with the KV-cache size projected once per model load by `llama-fit-params` (CPU only). vLLM: KV-cache fill from `/metrics`, no output limit. Ollama and LM Studio: configured context size only.
- **Installed or not** is checked about once a minute (command on `PATH`, systemd unit or `~/.lmstudio`), so a runtime never installed shows _not installed_ instead of _stopped_.
- **Detach** runs `scripts/free-gpu.sh`; it only touches user systemd units, never root.

## Settings and languages

Translations live in `lang/`. Without a choice, the language follows the Hyprland keyboard layout, then `LC_ALL` / `LC_MESSAGES` / `LANG`, then English.

Settings are stored in the widget's entry in `~/.config/omarchy/shell.json`: `language`, `gpu`, and `showCpu` / `showRam` / `showLoad` / `showModels` (only stored as `false`; the default removes the key).

## Binaries and releases

`bin/engine` and `bin/liball_smi_amd.so` are built by [`build-engine.yml`](.github/workflows/build-engine.yml) on every push to `main` that changes `engine/`, `mise.toml` or `scripts/build-engine.sh`. It signs a build provenance attestation, commits `bin/` (with `SHA256SUMS` and the attestation as `provenance.sigstore.json`) as `🤖 build binaries from <sha>`, and starts [`verify-binaries.yml`](.github/workflows/verify-binaries.yml). The build is not reproducible bit for bit, so binaries are verified through their attestation, not rebuilt.

To release:

1. Push your changes to `main` and wait for the bot commit.
2. `git pull`, then `mise run version 1.2.0`. It checks that `bin/` matches the current sources, updates `manifest.json`, commits and tags `v1.2.0`.
3. `git push origin main v1.2.0`. [`release.yml`](.github/workflows/release.yml) verifies the binaries and publishes them.

To check the binaries yourself:

```sh
(cd bin && sha256sum -c SHA256SUMS)
gh attestation verify bin/engine --repo vk2r/battle-station --bundle bin/provenance.sigstore.json
```
