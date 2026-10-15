# AGENT.md — Working guide for AI agents

For what the plugin does, read `README.md`; for how it works, `DEVELOPMENT.md`.

## The two copies

The repo is the **source of truth**, but it is not what runs. The plugin runs
from the user plugin directory as a **plain copy** (not a symlink, not a
worktree):

```
Repo (edit here):      /home/vk/Projects/Software/battle-station
Deployed copy (runs):  ~/.config/omarchy/plugins/io.github.vk2r.battle-station/
```

Never edit the deployed copy except to deploy into it. Dev-only files that do
**not** need to be kept in sync there: `README.md`, `DEVELOPMENT.md`, `mise.toml`, `AGENT.md`,
`engine/target/`, `engine/about.*`, `licenses/THIRD-PARTY.txt`, `preview.png`.

## Workflow: edit → validate → sync → reload

1. Edit files in the repo.

2. Validate:
   - **QML**: editor diagnostics for the touched file; keep it at zero errors
     and warnings.
   - **`I18n.js` / `lang/*.js`**: the first line (`.pragma library`) is a QML
     directive and breaks plain `node --check`; strip it first (`I18n.js` also
     has `.import` lines, so check the language files individually):

     ```sh
     tail -n +2 lang/pl.js > /tmp/i18n-check.js && node --check /tmp/i18n-check.js
     ```

   - **Manifest** (only if touched): `mise run validate`.

3. Sync exactly the files that changed, after diffing both sides (the user
   edits the repo directly between agent sessions, and may also have touched
   the deployed copy — mtimes tell you which side is newer):

   ```sh
   diff -rq . ~/.config/omarchy/plugins/io.github.vk2r.battle-station --exclude=.git --exclude=preview.png
   cp Panel.qml I18n.js ~/.config/omarchy/plugins/io.github.vk2r.battle-station/
   cp -r panel lang ~/.config/omarchy/plugins/io.github.vk2r.battle-station/
   ```

4. Reload:

| What changed                         | How to reload                                                                                   |
| ------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `.qml` files only                    | `omarchy-shell shell rescanPlugins`                                                             |
| `I18n.js`, `lang/*.js` (any `.pragma library` JS) | `omarchy restart shell` — **`rescanPlugins` is not enough**: the QML engine caches JS libraries |
| `EngineHub.qml`, `qmldir` (singleton) | `omarchy restart shell` — a singleton survives `rescanPlugins` |
| `manifest.json`                      | `omarchy restart shell`                                                                         |
| `engine/` (Rust)                     | `mise run build`, deploy `bin/`, then `omarchy restart shell`                                   |

Prefer `rescanPlugins` when only QML changed: faster, and it does not blink
the whole bar. Symptom of a stale cached `I18n.js`: the UI shows a raw
lowercase key (e.g. `output` instead of `Output`) — `I18n.tr` falls back to the
key itself when missing.

## Conventions

- **Communicate in Spanish**, keep code, comments, commits and docs in English.
- **Iterate visually**: after each accepted change, deploy + reload so the user
  can check the live panel; they reply with screenshots and tweak requests.
  Keep edits surgical — one visual concern at a time.
- **Percentages have no space**: `(23%)`, never `(23 %)` — also in i18n strings
  with `{N}%` placeholders. `Panel.pct()` already emits `N%`.
- **Every user-visible string goes through i18n** and must exist in all 8
  language files: `lang/{en,de,fr,es,it,pt,nl,pl}.js`. When a UI change removes
  the last use of a key, delete the key from all 8 files in the same change.
- **Layout**: `Panel.qml` is the shell (state, helpers, flickable); the pages
  live in `panel/Home.qml` and `panel/Settings.qml` (the dropdown is `components/CompactDropdown.qml`).
  They reach the panel through `host` (the former `root`). Each language is one
  file in `lang/`; `I18n.js` holds the logic and the `STRINGS` table that
  imports them, so a new language needs a file, a `LANGUAGES` entry and an
  `.import` line.
- **Spacing** uses `Style.space(N)`; bar and fill colours use
  `levelColor(fraction)` (green → yellow → orange → red, shared with the bar
  chip).
- **Engine JSON is the contract with the QML**: keep its shape when touching
  the engine (see `DEVELOPMENT.md` → Development).
