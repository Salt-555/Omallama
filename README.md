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

## The llama.cpp builds

The dispatcher routes each model to a build that actually supports its
architecture. On Strix Halo (Radeon 8060S, gfx1151) all of these build with
**Vulkan**, not CUDA — ROCm/HIP is unreliable on this chip. You need
`vulkan-radeon`, `vulkan-headers`, `glslc`, `spirv-headers`, and a 96 GiB GPU
UMA carve-out (`cat /sys/class/drm/card*/device/mem_info_vram_total` should
report ~96G; on most boards this is set in BIOS as "UMA frame buffer" /
dedicated VRAM).

Common Vulkan build invocation (run inside the llama.cpp checkout):

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON -DGGML_VULKAN_SHADERS=ON -DGGML_CUDA=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++
cmake --build build -j$(nproc) --target llama-server
```

### 1. General / Qwen3.8-27B (DFlash2 speculative decoding)

Plain `ggml-org/llama.cpp` plus PR #27342 (DFlash2 block-diffusion drafting):

```sh
git clone https://github.com/ggml-org/llama.cpp llamacpp-strix-halo/llama.cpp
git -C llamacpp-strix-halo/llama.cpp fetch origin pull/27342/head:pr-27342
git -C llamacpp-strix-halo/llama.cpp switch pr-27342
# ...common build invocation...
```

Uses the unsloth Qwen3.8-27B GGUF as target + the incoai DFlash2 Q8_0 draft.
KV cache: keep default f16 (q4_0 measured slower; q8_0 acceptable).

### 2. Qwen3.8-Flash-Next (qwen4exp) with the MTP head

Flash-Next is a Qwen4/`qwen4exp` MoE that neither mainline llama.cpp nor LM
Studio's bundled build can load. The MTP (NextN draft-head) speculative
decoding support ships in **PR #28243**, which also includes the qwen4exp
architecture (originally PR #27742). One build covers both:

```sh
git clone https://github.com/ggml-org/llama.cpp llamacpp-qwen-next/llama.cpp
git -C llamacpp-qwen-next/llama.cpp fetch origin pull/28243/head:pr-28243
git -C llamacpp-qwen-next/llama.cpp switch pr-28243
cmake -B build-mtp-new -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON -DGGML_VULKAN_SHADERS=ON -DGGML_CUDA=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++
cmake --build build-mtp-new -j$(nproc) --target llama-server
```

Run with `-md <MTP-draft.gguf> --spec-type draft-mtp` (the MTP draft GGUF ships
alongside the model from the same quant publisher). Flash-Next specifics:

- **KV cache must stay f16** on this PR — q8_0 KV crashes the qwen4exp
  sparse-attention path.
- `GGML_VK_MAX_MB_PER_SUBMIT=2048` if you raise `-ub` to 2048 (keeps
  command-buffer dispatches inside the AMDGPU watchdog limit).
- `-ngl 999 -fa on --jinja -np 1`; mmap on (96G carve + 32G host pool).

### 3. ROCmFP4-quantized Flash-Next

For the ROCmFP4 quant format (charlie12345/ROCmFPx), use
[LaurentZuijdwijk's fork](https://github.com/LaurentZuijdwijk/llama.cpp):

```sh
git clone https://github.com/LaurentZuijdwijk/llama.cpp llamacpp-rocmfpx/llama.cpp
git -C llamacpp-rocmfpx/llama.cpp switch vulkan/qwen4exp-rocmfpx
# ...common build invocation into build/...
```

This fork tolerates q8_0 KV cache with qwen4exp (`-ctk q8_0 -ctv q8_0`), which
the mainline PR does not.

### Wiring it up

Point the dispatcher at the builds (defaults shown):

```bash
export LLAMA_STRIX_SERVE=~/llamacpp-strix-halo/serve.sh
export LLAMA_QWEN_NEXT_DIR=~/llamacpp-qwen-next
export LLAMA_ROCMFPX_SERVE=~/llamacpp-rocmfpx/serve.sh
```

Each directory's `serve.sh` hardcodes its own model paths and flags — edit
them for your model locations, or just use the widget's model picker, which
discovers GGUFs from `~/.lmstudio/models` and writes the active path to
`~/.config/llama-server/model.json`.

### Models

```sh
pip install -U "huggingface_hub[cli]"
hf download unsloth/Qwen3.8-Flash-Next-GGUF --local-dir ~/.lmstudio/models/unsloth/Qwen3.8-Flash-Next-GGUF
```

The MTP draft head ships in the same HF repo: unsloth puts it under
`MTP/mtp-Qwen3.8-Flash-Next-*.gguf`; other quant publishers use a
`*-MTP-draft*` file in their model repo. Use the `shared-Q8_0` or `Q8_0`
variant as `-md` (the draft is tiny; quantizing it below Q8 costs acceptance
rate for no meaningful memory win). Pick a quant that fits the 96 GiB carve: Q3_K_XL /
IQ4_XS-class quants (~84-88 GiB) fit with room for context; Q4_K_XL (~111 GiB)
does not.

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
