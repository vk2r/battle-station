# Development notes

Technical details for contributors. `README.md` covers installation and usage.

## Settings

Open the **gear (⚙)** at the top right of the panel. Choices are stored in the widget's entry in `~/.config/omarchy/shell.json`.

- **Language** (`"language"`): eight bundled languages (en, de, fr, es, it, pt, nl, pl). By default it follows the Hyprland keyboard layout, then the system locale, then English.
- **GPU** (`"gpu"`): the card the monitor follows. Default: the card with the most memory.
- **Items** (`"showCpu"`, `"showRam"`, `"showLoad"`, `"showModels"`): what the bar shows. A hidden item is stored as `false`.

## How it works

A Rust engine (`bin/engine`, source in `engine/`) prints one JSON snapshot every two seconds. That JSON is the contract with the QML (`BarWidget.qml` → `Panel.qml`), so keep its shape.

- It only **reads**: `/proc`, the GPU (through all-smi) and the local APIs of running runtimes (llama.cpp 8080, Ollama 11434, LM Studio 1234, vLLM 8000). It never starts or stops anything and sends nothing to the network.
- Runtimes are told apart by systemd unit and executable path.
- On AMD, VRAM evicted to system RAM is shown as `!` in the bar.

The only action that changes anything is **Free GPU memory** (`scripts/free-gpu.sh`): it unloads the models from llama.cpp, Ollama and LM Studio, and stops the user systemd unit for llama-server without the router, and for vLLM.

## Building

The tools are pinned in `mise.toml`.

```sh
mise install          # install the toolchain
mise run build        # build bin/engine
mise run snapshot     # print one snapshot
mise run bench        # measure the running engine's CPU and memory
mise run licenses     # regenerate licenses/THIRD-PARTY.txt after changing dependencies
mise run validate     # validate the plugin manifest
```

Omarchy installs plugins with `git clone` and never builds them, so the binaries in `bin/` are committed. Build locally only to test: the committed binaries must come from GitHub Actions (see below).

Keep the all-smi version the same in `engine/Cargo.toml` and `mise.toml`.

## Releasing a new engine

1. Push your changes to `engine/`.
2. Run the **Build engine** workflow and download its `bin` artifact.
3. Copy `engine`, `liball_smi_amd.so` and `SHA256SUMS` into `bin/`, run `chmod +x bin/engine bin/liball_smi_amd.so`, then commit and push.
4. To publish a release, push a `v*` tag.

The **Verify binaries** workflow checks every push to make sure the binaries in `bin/` match the ones built by the workflow. To check them yourself:

```sh
cd bin && sha256sum -c SHA256SUMS && cd ..
gh attestation verify bin/engine --repo vk2r/battle-station
gh attestation verify bin/liball_smi_amd.so --repo vk2r/battle-station
```
