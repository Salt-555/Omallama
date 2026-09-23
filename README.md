# Omallama

An Omarchy (Quickshell) bar widget and control plane for managing a local
llama.cpp `llama-server` — live status, VRAM, tok/s of the last run, and
one-click model switching with automatic model discovery.

![status](https://img.shields.io/badge/port-6969-blue) ![platform](https://img.shields.io/badge/Omarchy-Quattro-purple)

## What it does

- **Bar widget** (`salt.llama-server`): shows server status (idle / generating
  / offline) and the tok/s of the last completed generation. Click opens a
  control panel; right-click forces a poll refresh.
- **Panel**: status rows (state, activity, model, endpoint, VRAM), start /
  restart / stop buttons, and a searchable model dropdown.
- **Model discovery**: the dropdown is discovered live from disk
  (`~/.lmstudio/models` by default) every time it opens — new GGUFs appear
  automatically; projector files, draft models, and later shards are skipped.
- **Dispatcher**: one systemd user unit runs a `serve.sh` that routes the
  selected model to the right llama.cpp build (different forks for different
  architectures), so switching a model is just a `systemctl --user restart`.

## Repo layout

```
plugin/    Omarchy plugin (manifest + QML widget + panel + shell scripts)
config/    serve.sh dispatcher, systemd user unit, example presets
install.sh installer (never overwrites your existing config)
```

## Install

```bash
git clone https://github.com/Salt-555/Omallama.git
cd Omallama
./install.sh
omarchy plugin enable salt.llama-server   # only if not already in your bar
```

The plugin scripts and the dispatcher communicate through
`~/.config/llama-server/` (`model.json` = active model, `presets.json` =
overrides). `install.sh` will not touch files that already exist there.

## Autostart

The `llama-server.service` unit is **disabled by design**: it is never started
at boot, and it does not restart itself on failure (`Restart=no`). Loading a
40-90GB model is something that should happen when you ask for it — a crash
loop of automatic reloads at login is a real failure mode on unified-memory
APUs. The widget's Start/Stop buttons (or `systemctl --user start|stop
llama-server`) are the only things that launch it. If you genuinely want the
model resident from boot, `systemctl --user enable --now llama-server` is
available, but the default is off.

## Configuration

Environment variables (all optional, defaults shown):

| Variable | Default | Used by |
|---|---|---|
| `LLAMA_CFG_DIR` | `~/.config/llama-server` | modelctl.sh, monitor.sh, install.sh |
| `LLAMA_MODELS_DIR` | `~/.lmstudio/models` | modelctl.sh (discovery root) |
| `LLAMA_BASE_URL` | `http://127.0.0.1:6969` | monitor.sh |
| `LLAMA_STRIX_SERVE` | `~/CodingProjects/llamacpp-strix-halo/serve.sh` | config/serve.sh |
| `LLAMA_QWEN_NEXT_DIR` | `~/CodingProjects/llamacpp-qwen-next` | config/serve.sh |
| `LLAMA_ROCMFPX_SERVE` | `~/CodingProjects/llamacpp-rocmfpx/serve.sh` | config/serve.sh |
| `LLAMA_DEFAULT_MODEL` | unsloth Qwen3.8-27B Q4 path | config/serve.sh |

Edit `config/serve.sh` to add or change routes — it pattern-matches the active
model path and execs the right build. Each target build's serve script owns its
own flags (KV cache, speculative decoding, mmap strategy, etc.).

### presets.json

Discovery names every servable GGUF after its filename (shard suffixes
stripped). Use `presets.json` to override a name or spec, or to hide a file:

```json
[
  { "name": "My 27B (MTP)", "model": "/path/to/model.gguf", "spec": "mtp" },
  { "model": "/path/to/draft.gguf", "exclude": true }
]
```

`spec` (`dflash` / `mtp`) is written into `model.json` on selection; the spec
rule lives in one place (`modelctl.sh`'s `spec_for`), which also guesses from
the filename for unknown models.

## CLI

`modelctl.sh` is usable standalone:

```bash
modelctl.sh presets            # name<TAB>path<TAB>spec, discovered from disk
modelctl.sh current            # active model path
modelctl.sh set <name|path>    # switch (widget then restarts the service)
modelctl.sh add <path> [name]  # record a name/spec override
```

## How switching works

1. Widget writes the selection to `model.json` via `modelctl.sh set`.
2. Widget runs `systemctl --user restart llama-server.service`.
3. `serve.sh` reads `model.json` and execs the right llama.cpp build.
4. Widget polls `/health` + `/metrics` until the new model reports ok (with a
   watchdog so a failed load surfaces as an error, not an eternal spinner).

## Requirements

- Omarchy (Quattro shell / Quickshell) for the widget
- llama.cpp server builds reachable at the paths in `config/serve.sh`
- `jq`, `curl`, `systemd` user session
- AMD Strix Halo assumed for VRAM readout (`mem_info_vram_*`); falls back to "—"

## License

MIT
