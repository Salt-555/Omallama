# Omallama

An Omarchy (Quickshell) bar widget and control plane for managing a local
llama.cpp `llama-server` — live status, VRAM, tok/s of the last run, and
one-click model switching with automatic model discovery.

![status](https://img.shields.io/badge/port-6969-blue) ![platform](https://img.shields.io/badge/Omarchy-Quattro-purple)

## What it does

- **Bar widget** (`salt.llama-server`): shows server status (idle / encoding
  `E` / decoding `D` / offline), the runtime in use (llama.cpp or Gufo), and
  the decode tok/s of the last completed run. Click opens a control panel;
  right-click forces a poll refresh.
- **Panel**: last-run rates (encode + decode tok/s), time to first token,
  VRAM, start / restart / stop buttons, and a searchable model dropdown.
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
**Vulkan**, not CUDA — llama.cpp's ROCm/HIP path is unreliable on this chip.
(That is a llama.cpp verdict, not a silicon one: Gufo's dedicated gfx1151 HIP
kernels below run great.) You need
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

### 3. Gufo (compliance-first runtime, automatic)

[Gufo](https://github.com/gufo-org/gufo) is a Strix-Halo-only inference engine
with hand-written HIP kernels for gfx1151 (Wave32, no Triton/CK/MIOpen). On
Flash-Next it measures ~1629 tok/s prefill, 3.4x llama.cpp's throughput at 8
concurrent users, and a ~15s model load. It ships as the official
`gufo-runtime` container — no toolchain to build.

Gufo only serves its own curated, audited artifacts (the file lists on its
model pages map 1:1 to HF repos). The dispatcher routes a model to Gufo
automatically when it is on that compliance list — the rule lives in
`modelctl.sh` (`resolve-backend`) and a preset's explicit `"backend"` field
overrides it. Serving anything else on Gufo is undefined behavior, which is
exactly why both backends stay in the dispatcher.

```sh
# one-time: the official runtime container
docker pull ghcr.io/gufo-org/toolboxes/gufo-runtime:latest

# the gufo-compliant Flash-Next quant (unsloth UD-Q4_K_XL + MTP sidecar)
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --include "UD-Q4_K_XL/*" "MTP/*" "mmproj-BF16*" \
  --local-dir ~/.lmstudio/models/unsloth/Qwen3.8-Flash-Next-GGUF
```

`config/serve-gufo.sh` runs it on the standard bridge (port 6969, served name
ALLMIND like every other widget model) with `--device /dev/kfd --device /dev/dri
--ulimit memlock=-1`. Nothing is needed when just running a model; these only
matter at load time and all avoid kernel parameters and reboots: memlock
(`ulimit -l` must not cap the container), and optionally a larger GTT window
for giant prefill batches. Measured on the 96/32 split: 91.2 GiB of the 96 GiB
carve, host side untouched.

The widget's phase labels come from gufo's `--log-progress` events (prefill
chunk / decode boundary), and encode/decode rates and TTFT come straight from
its per-request timing logs.

Point the dispatcher at the builds (defaults shown):

```bash
export LLAMA_STRIX_SERVE=~/llamacpp-strix-halo/serve.sh
export LLAMA_QWEN_NEXT_DIR=~/llamacpp-qwen-next
```

Each directory's `serve.sh` hardcodes its own model paths and flags — edit
them for your model locations, or just use the widget's model picker, which
discovers GGUFs from `~/.lmstudio/models` and writes the active path to
`~/.config/llama-server/model.json`.

### Models

The sweet spot on a 96 GiB carve is the **GSQ-RCO IQ3_XXS** quant
(ISTA-DASLab) — ~47G resident weights + a 28.8G per-layer n-gram PLE table
that streams from SSD, leaving plenty of room for context:

```sh
pip install -U "huggingface_hub[cli]"
hf download ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
  --include "IQ3_XXS/*" "mmproj-*" \
  --local-dir ~/.lmstudio/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
```

The MTP draft head is a separate, tiny file — unsloth ships it under
`MTP/mtp-Qwen3.8-Flash-Next-*.gguf` in `unsloth/Qwen3.8-Flash-Next-GGUF`
(use the `shared-Q8_0` variant as `-md`; quantizing the draft below Q8 costs
acceptance rate for no meaningful memory win).

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
llama-server`) are the only things that launch it. The Gufo container rides
the same unit (`docker run --rm`, attached): starting the service loads it,
stopping the service stops and removes it, and model switches are restarts.
Nothing of it stays resident between sessions. If you genuinely want the
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
| `LLAMA_DEFAULT_MODEL` | unsloth Qwen3.8-27B Q4 path | config/serve.sh |
| `GUFO_SESSIONS` | `4` | config/serve-gufo.sh |
| `GUFO_CONTEXT` | `65536` | config/serve-gufo.sh |
| `GUFO_CACHE_DIR` | `~/.cache/gufo` | config/serve-gufo.sh (runtime + artifact digest cache) |

Edit `config/serve.sh` to add or change routes — it pattern-matches the active
model path and execs the right build. Each target build's serve script owns its
own flags (KV cache, speculative decoding, mmap strategy, etc.).

### presets.json

Discovery names every servable GGUF after its filename (shard suffixes
stripped). Use `presets.json` to override a name or spec, or to hide a file:

```json
[
  { "name": "My 27B (MTP)", "model": "/path/to/model.gguf", "spec": "mtp" },
  { "name": "My Gufo model", "model": "/path/to/ud-q4.gguf", "spec": "mtp", "backend": "gufo" },
  { "model": "/path/to/draft.gguf", "exclude": true }
]
```

`spec` (`dflash` / `mtp`) is written into `model.json` on selection; the spec
rule lives in one place (`modelctl.sh`'s `spec_for`), which also guesses from
the filename for unknown models. `backend` (`gufo` / `llama`) forces the
serving runtime for that preset and wins over the automatic path rule; run
`modelctl.sh resolve-backend <path>` to see what would be chosen.

## CLI

`modelctl.sh` is usable standalone:

```bash
modelctl.sh presets            # name<TAB>path<TAB>spec, discovered from disk
modelctl.sh current            # active model path
modelctl.sh set <name|path>    # switch (widget then restarts the service)
modelctl.sh resolve-backend <name|path>  # gufo|llama: which runtime serves it
modelctl.sh add <path> [name]  # record a name/spec override
```

## How switching works

1. Widget writes the selection to `model.json` via `modelctl.sh set`.
2. Widget runs `systemctl --user restart llama-server.service`.
3. `serve.sh` reads `model.json` and execs the right backend: a gufo
   container (`serve-gufo.sh`) or the matching llama.cpp build.
4. Widget polls `/health` + `/metrics` until the new model reports ok (with a
   watchdog so a failed load surfaces as an error, not an eternal spinner).

## Requirements

- Omarchy (Quattro shell / Quickshell) for the widget
- llama.cpp server builds reachable at the paths in `config/serve.sh`
- `jq`, `curl`, `systemd` user session
- Docker (user in the `docker` group) for the Gufo backend only
- AMD Strix Halo assumed for VRAM readout (`mem_info_vram_*`); falls back to "—"

## License

MIT
