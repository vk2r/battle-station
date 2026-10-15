# Development notes

Technical details moved out of `README.md`, which now covers only installation and usage.

## Languages and settings

The interface is built in in eight languages: English, German (Deutsch), French (Français), Spanish (Español), Italian (Italiano), Portuguese (Português), Dutch (Nederlands) and Polish (Polski). Omarchy has no interface-language setting of its own, so the language is picked automatically from the active Hyprland keyboard layout (e.g. `es` or `latam` â EspaÃ±ol); when the layout is English or has no translation, the system locale (`LC_ALL`, `LC_MESSAGES`, `LANG`) decides, then English. To pick another one, open the **gear (⚙)** at the top right of the panel → **Language**. The translations ship with the plugin: nothing is downloaded or generated, and the plugin makes no extra requests for them. The choice is stored in the widget's own entry in `~/.config/omarchy/shell.json` (`"language"`); **Automatic (…)** removes it again.

The settings page opens from the gear and closes with **← Back**, Backspace or Esc.

The settings page also has a **GPU** dropdown: it picks the card the monitor follows everywhere (bar chip, panel gauges, per-runtime VRAM). Until one is picked, the card with the most memory is followed, and the choice is stored in the widget's own `shell.json` entry (`"gpu"`).

The **Plugin** section of the settings page picks which items the bar shows on its **Items** row: **CPU** and **RAM** (in the bar's colour), **LOAD** (in the followed card's colour) and **MODELS** (the models ring, in the theme accent). The bar and its tooltip update at once, and the choices are stored in the widget's own `shell.json` entry (`"showCpu"`, `"showRam"`, `"showLoad"`, `"showModels"` — a hidden item is stored as `false`, switching it back on removes the key again). The models ring only appears while a model is resident.

## How it works

An engine written in Rust (`bin/engine`, source in `engine/`) runs while the widget is loaded and streams one JSON snapshot every two seconds (under 1 % of one CPU core, ~30 MiB RAM).

- **Read-only by default.** It reads `/proc`, the GPU (through all-smi) and the runtimes' local status endpoints on `127.0.0.1` (llama.cpp 8080, Ollama 11434, LM Studio 1234, vLLM 8000 or its `--port`) **only while that runtime is already running**. It never starts, stops or reconfigures a runtime by itself and sends nothing to the network.
- **Runtimes are told apart by systemd unit and executable path**, because Ollama and LM Studio both ship an engine named `llama-server`.
- **One-shot llama.cpp tools** (`llama-tts`, `llama-cli`, `llama-mtmd-cli`, ...) count as llama.cpp while they run, e.g. Simple Reader's Qwen voices. They have no HTTP API, so they show the model, VRAM, CPU, RAM and the program that started them, but no context or output buffers.
- **GPU memory per runtime** comes from all-smi's per-process GPU memory. On AMD, memory the driver evicted to system RAM because VRAM ran full is read from DRM `fdinfo` (`amd-requested-vram` minus `drm-resident-vram`) and reported separately (the `!` in the bar); other drivers do not expose it.
- **Context and output buffers.** llama.cpp: tokens from `/slots`; the KV-cache size is projected once per model load with `llama-fit-params` from the same llama.cpp build (CPU only, nothing is loaded onto the GPU). vLLM: KV-cache fill from `/metrics` (`kv_cache_usage_perc`, pool size from `cache_config_info`); vLLM does not report a per-reply output limit, so it has no output-buffer row. Ollama and LM Studio report only the configured context size.
- **Installed or not** is checked about once a minute (command on `PATH`, systemd unit or LM Studio's `~/.lmstudio`), so a runtime you never installed shows _not installed_ instead of _stopped_.

### Free GPU memory (the only action that changes anything)

Only when you click **Free GPU memory**, `scripts/free-gpu.sh` runs:

- **llama.cpp router:** `POST /models/unload` for every loaded model; the router keeps running and loads a model again on the next request.
- **Ollama:** `keep_alive: 0` for every model in memory; the service keeps running.
- **LM Studio:** `lms unload --all` if its daemon is running (the daemon keeps running).
- **llama-server without the router, and vLLM**, which cannot unload a model: the user systemd unit that owns the process is stopped, whatever its name. User units only, never root.

This frees the models for every program using them at that moment.

## Development

The build tools are pinned in `mise.toml`: Rust, `protoc` (all-smi's build script compiles a protobuf file), the all-smi release that provides `liball_smi_amd.so`, and `cargo-about` for the third-party license notice.

```sh
mise install          # Rust, protoc, all-smi, cargo-about
mise run build        # rebuild bin/engine and copy bin/liball_smi_amd.so beside it
mise run licenses     # regenerate licenses/THIRD-PARTY.txt (after changing dependencies)
mise run snapshot     # print one snapshot (bin/engine --once)
mise run validate     # omarchy plugin validate .
```

Cargo builds into `~/.cache/battle-station-engine/target`, outside the plugin folder: Omarchy reloads a plugin whenever a file in it changes. Commit `bin/engine`, `bin/liball_smi_amd.so` and `engine/Cargo.lock` together after a rebuild, and run `mise run licenses` + commit `licenses/THIRD-PARTY.txt` when the dependencies changed; Omarchy installs plugins with a plain `git clone` and never runs a build. The all-smi crate (`engine/Cargo.toml`) and the all-smi tool in `mise.toml` must stay on the same version, because the engine loads the companion library through a versioned ABI. On other architectures (e.g. aarch64), run `mise run build` once in the plugin folder.

The JSON the engine prints is the contract with the QML (`BarWidget.qml` → `Panel.qml`); keep its shape when changing the engine.

`preview.png` is composed from the real screenshots in `screenshots/`; the values it shows are sample data.

## Verifying the bundled binaries

`bin/engine` and `bin/liball_smi_amd.so` are built by GitHub Actions ([`build-engine.yml`](.github/workflows/build-engine.yml)) from the exact commit, with the toolchain pinned in `mise.toml` (`mise run build`). Each file carries a build provenance attestation, and `bin/SHA256SUMS` lists their digests.

Check them with the [GitHub CLI](https://cli.github.com/):

```sh
cd bin && sha256sum -c SHA256SUMS && cd ..
gh attestation verify bin/engine --repo vk2r/battle-station
gh attestation verify bin/liball_smi_amd.so --repo vk2r/battle-station
```

The attestation names the workflow run and the source commit that produced each file. [`verify-binaries.yml`](.github/workflows/verify-binaries.yml) runs these checks on every push and also confirms that the attested source commit has the same `engine/`, `mise.toml` and `scripts/build-engine.sh` as the current commit, so the binaries are never older than the code. `liball_smi_amd.so` is the unmodified file from the all-smi release pinned in `mise.toml`.

The build is not bit-for-bit reproducible: building the same source twice gives different `engine` files. That is why the binaries are built once, committed, and verified through their attestation, not rebuilt to compare.

### Releasing a new engine

1. Change `engine/` (or `mise.toml`, `scripts/build-engine.sh`) and push to `main`.
2. **Build engine** runs by itself, attests the new binaries and commits `bin/` to `main` (`🤖 build binaries from <sha>`). It can also be started by hand from the Actions tab.
3. **Verify binaries** must be green on that commit. Pull before doing anything else.
4. To publish a release, push a `v*` tag on that commit. **Release** verifies the committed binaries and publishes them as they are; it never rebuilds.
