<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# GenieX on Snapdragon — on-device OpenAI-compatible server

How to run **Qualcomm GenieX** — the on-device LLM/VLM runtime for Snapdragon —
so an AI coding agent inside WSL2 talks to a local OpenAI-compatible API
backed by the Windows host's **Adreno GPU** (and, when the driver cooperates,
the **Hexagon NPU**).

GenieX runs GGUF models from Hugging Face (llama.cpp backend) or pre-compiled
bundles from Qualcomm AI Hub (QAIRT backend) on **NPU, GPU or CPU**. One C SDK,
exposed through a CLI, Python bindings, Docker and an OpenAI-compatible server.
It is the community version of Qualcomm GENIE — BSD-3-Clause.

> **Why this page lives here.** The Kataglyphis coding agents are meant to be
> runnable entirely on the hardware you own. This page is the Snapdragon half
> of that: how to stand up a local OpenAI-compatible endpoint with Qualcomm's
> GenieX and point an agent at it, with every failure mode hit live on
> 2026-08-31 recorded as symptom → cause → fix (including the NPU driver
> mismatch that a driver update resolves).

---

## At a glance — which lane, which model

Everything below is measured on this host (Snapdragon X X126100, 8x Oryon,
Adreno X1-45, single Hexagon HTP). Full method and caveats in
§ Getting the most out of this machine.

| You want | Use | Speed |
|---|---|---|
| **The fastest finished answer** (default for a coding agent) | `--compute npu` + `qualcomm/Qwen3-4B-Instruct-2507:W4A16` | 19.5 tok/s, **26.8 s to a full answer**, 1.65 cores. Also **3/3 on the executed-code benchmark, 4.3x faster than any other model that scored 3/3** (§ 1d) |
| The fastest GGUF, machine to yourself | `--compute cpu` + any GGUF | 2B 46.5 · 4B 23.7 · 9B 15.2 tok/s, but **7.5 of 8 cores** |
| Max total throughput, n parallel agents | NPU + CPU lanes (add GPU for a third) | **39.7 tok/s** (45.4 with all three) |
| Long context (> 4096) | any GGUF lane with `--nctx 16384` | QAIRT bundles are hard-capped at 4096 |
| **Best quality on-device**, willing to wait | `--compute cpu` + `unsloth/Qwen3.8-27B-GGUF:Q4_0` | 5.6 tok/s, correct output, 16 GB RAM |
| Nothing | `--compute hybrid` | Slower than CPU on every model, and it damages a concurrent NPU lane |

**Three counter-intuitive results worth knowing before you tune anything:**

1. **The CPU beats the Hexagon NPU ~2x on GGUF models** (4B: 23.7 vs 11.9).
   llama.cpp's ARM kernels are mature; the `ggml-hexagon` backend is not. The
   NPU's value is QAIRT bundles and its tiny CPU footprint, not raw speed.
2. **tok/s is the wrong metric.** `Qwen3-1.7B` is the fastest model here at
   31.7 tok/s and the *slowest* to a finished answer (60.8 s), because it is a
   reasoning model that spends ~1900 tokens thinking. Measure time-to-answer.
3. **Prefill, not decode, is what an agent waits on.** A 2.5k-token prompt costs
   13.1 s before the first token. Context discipline beats every other tuning
   knob here.

---

## The architecture that actually works

**WSL2 has no NPU/GPU passthrough.** The Hexagon NPU and Adreno GPU are
Windows-side devices (`/dev/fastrpc*` does not exist inside WSL2). Running
GenieX *inside* WSL2 therefore pins you to CPU.

The correct topology:

```
WSL2 (client)                         Windows host (server)
┌────────────────────┐                ┌──────────────────────────┐
│ coding agent       │  OpenAI API    │ geniex serve --compute   │
│ (opencode) ────────┼────────────────► gpu    ← Adreno GPU      │
│ base_url=          │ 127.0.0.1:     │ (or npu  ← Hexagon NPU)  │
│ 127.0.0.1:18181/v1 │ 18181          │                          │
└────────────────────┘  mirrored net  └──────────────────────────┘
```

Windows runs the accelerated GenieX server; WSL2's agent is a plain OpenAI
client. With **WSL2 mirrored networking** (the default on modern WSL2 +
Windows 11 24H2+), `127.0.0.1:18181` inside WSL2 *is* the Windows server — no
firewall rule, no LAN exposure needed.

## Install

### On the Windows host (this is where the NPU/GPU live)

1. Download the official Windows ARM64 installer from
   <https://github.com/qualcomm/GenieX/releases> and run it.
2. Verify from WSL2 (PowerShell interop):

   ```bash
   powershell.exe -NoProfile -Command "& 'C:\Users\<you>\AppData\Local\GenieX CLI\geniex.exe' --version"
   ```

### Inside WSL2 / native Linux ARM64 (optional — CPU only)

```bash
curl -fsSL https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-geniex/install.sh | sh
```

No `sudo`; installs to `~/.local/share/geniex` with a launcher in
`~/.local/bin`. Verify the installer's SHA256 sidecar is checked before use
(it is — Qualcomm ships a `.sha256` and the installer verifies it).

## First-run chipset (headless)

`geniex pull` fails on a fresh install with
`No chipset configured. Please select your chipset first.` and then dies
because the interactive picker needs a TTY. Set the chipset non-interactively:

```bash
geniex config set chipset qualcomm-snapdragon-x-elite
```

Valid ids come from Qualcomm AI Hub's `platform.json` (28 chipsets as of
2026-08-31). On an Oryon Snapdragon X use `qualcomm-snapdragon-x-elite`; other
ids include `qualcomm-snapdragon-8-elite`, `qualcomm-qcs9075`, etc.

## Model management

Pull (prompts for precision — append `:Q4_0` to skip the prompt):

```bash
geniex pull unsloth/Qwen3.8-27B-GGUF:Q4_0
```

### Reuse a model across Windows and WSL2 (no re-download)

GenieX's model cache is a plain directory of GGUF files + a `geniex.json`
manifest. The WSL2 and Windows caches live at:

| Side | Cache path |
|---|---|
| WSL2 / Linux | `~/.cache/geniex/models/<org>/<repo>/` |
| Windows | `C:\Users\<you>\.cache\geniex\models\<org>\<repo>\` |

`/mnt/c` makes the Windows cache writable from WSL2, so a model pulled once
can be copied across **locally** — 16 GB with no bandwidth cost:

```bash
mkdir -p "/mnt/c/Users/<you>/.cache/geniex/models/unsloth/Qwen3.8-27B-GGUF"
cp -a ~/.cache/geniex/models/unsloth/Qwen3.8-27B-GGUF/. \
      "/mnt/c/Users/<you>/.cache/geniex/models/unsloth/Qwen3.8-27B-GGUF/"
```

Verify with `geniex list` on the Windows side.

## Serve from Windows with acceleration

One command starts the measured-optimal fleet (NPU + GPU lanes, correct
`--nctx` and `--keepalive`):

```powershell
pwsh -File windows/scripts/host/start-geniex-servers.ps1 -Restart
# add -WithHybrid for a third (contending) lane on 18183
```

Equivalent by hand:

```powershell
$gx = "$env:LOCALAPPDATA\GenieX CLI\geniex.exe"
# Lane 1 — NPU, the primary agent endpoint
& $gx serve --compute npu --host 0.0.0.0:18181 --nctx 16384 --keepalive 86400
# Lane 2 — GPU, fully concurrent with lane 1 (separate silicon)
& $gx serve --compute gpu --host 0.0.0.0:18182 --nctx 16384 --keepalive 86400
```

> **`--nctx` and `--keepalive` defaults are both wrong for agent use.**
> `--nctx` defaults to **4096** — smaller than the 8192 this page's opencode
> config used to advertise; overflowing it does not raise an error, the server
> just crawls (a 6.4k-token prompt did not return within 400 s on any lane).
> `--keepalive` defaults to **300 s**, so every five-minute pause in a coding
> session costs a ~15 s cold reload. Set both explicitly.

- `--compute gpu` → Adreno GPU (OpenCL). **The working accelerated path before
  the NPU driver update** (see below).
- `--compute npu` → Hexagon NPU. **Works after updating the Qualcomm Hexagon NPU
  driver** (see below). With the old Nov-2024/Feb-2025 driver both NPU backends
  failed.
- `--compute hybrid` → **per-tensor NPU scheduler** (device resolves to
  `DeviceID:""` + `ngl != 0`, classified as NPU in the plugin). The HTP runs
  the layers that fit and CPU picks up the rest. It is **not** "GPU+NPU at
  once" — a single model runs on either HTP(+CPU fallback) or GPU, never both
  simultaneously. Measured: 14.1 tok/s on the 4B (pure NPU: 15.2 tok/s).
- `--compute HTP0,HTP1,...` (with `GGML_HEXAGON_NDEV`) spreads one model across
  **multiple HTP cores**. Only relevant on chipsets with more than one HTP
  (e.g. some QCS platforms); this Snapdragon X (X126100) has a **single** HTP
  (hwinfo: `threads 4, hvx 4, hmx 1, vtcm 8 MB`), so the list degenerates to
  one device here.
- **QAIRT bundles (`ai-hub-models/*`) are NPU-only** — `--compute cpu/gpu`
  on one is coerced back to NPU with a warning.

**Serving multiple accelerators at once:** one `geniex serve` binds one
`--compute` **and serves one request at a time** — there is no batching. A
second request to the same server waits for the first to finish completely
(measured: request #2 got its first token after 27.6 s, exactly the duration of
request #1), and while a server generates it will not even answer
`/v1/models`. Aggregate throughput therefore only comes from running several
servers. See § Getting the most out of this machine for which combination
actually adds up.

- `--host 0.0.0.0:18181` so WSL2 can reach it. The default binds loopback only.

Keep it running in a hidden window. With mirrored networking, WSL2 reaches it
at `127.0.0.1:18181`.

**Port-shadowing trap:** if a WSL-side GenieX server is still listening on
`127.0.0.1:18181`, WSL2's localhost-forwarding shadows that port on the Windows
side and the Windows server fails to bind (`listen tcp 0.0.0.0:18181: Only one
usage ...`). Stop the WSL-side server first (`fuser -k 18181/tcp` inside WSL2).

### SoX (audio support)

`geniex serve` warns `SoX is not installed, some features may not work`. Install
it, then put it on PATH:

```powershell
winget install --id=ChrisBagwell.SoX -e
# find the exe, e.g. ...\WinGet\Packages\ChrisBagwell.SoX_...\sox-14.4.2\sox.exe
[Environment]::SetEnvironmentVariable('Path',
  [Environment]::GetEnvironmentVariable('Path','User').TrimEnd(';') +
  ';<that dir>', 'User')
```

Then restart the server so it inherits the new PATH. The warning is cosmetic for
text chat — SoX only enables audio input.

## Wire the coding agent (opencode)

**The recommended model is `qualcomm/Qwen3-4B-Instruct-2507:W4A16` on the NPU
lane** — 19.5 tok/s and, because it does not emit `<think>`, ~6x faster to a
finished answer than any GGUF here (see § Getting the most out of this machine
for the numbers, including why the *faster-per-token* 1.7B is the wrong pick).

### Step 1 — pull the model (once)

The precision must be appended, otherwise the CLI opens an interactive picker
that fails in a non-TTY shell:

```bash
GX="/mnt/c/Users/<you>/AppData/Local/GenieX CLI/geniex.exe"
"$GX" pull qualcomm/Qwen3-4B-Instruct-2507:W4A16 --model-hub aihub
```

~3.0 GiB. Confirm with `"$GX" list` — it should show `W4A16` under PRECISIONS.

### Step 2 — start the server lane

```powershell
pwsh -File windows/scripts/host/start-geniex-servers.ps1 -Restart
```

This binds the NPU lane on **18181** (and a GPU lane on 18182) with
`--keepalive 86400 --nctx 16384`. Leave it running; with WSL2 mirrored
networking, `127.0.0.1:18181` inside WSL2 *is* the Windows server.

### Step 3 — declare the provider in opencode

opencode has no built-in GenieX provider, so it is registered as a generic
OpenAI-compatible endpoint via `@ai-sdk/openai-compatible`. Edit
`~/.config/opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "geniex": {
      "npm": "@ai-sdk/openai-compatible",   // generic OpenAI-compatible driver
      "name": "GenieX (Snapdragon NPU)",     // shown in opencode's model picker
      "options": {
        "baseURL": "http://127.0.0.1:18181/v1",  // note the /v1 suffix
        "apiKey": "geniex"                        // not validated; must be non-empty
      },
      "models": {
        // The key MUST match the id from /v1/models EXACTLY, precision included.
        // HARD 4096 context — compiled into the QAIRT binary; --nctx applies to
        // llama.cpp/GGUF models only, never to a QAIRT bundle.
        "qualcomm/Qwen3-4B-Instruct-2507:W4A16": {
          "name": "Qwen3 4B Instruct W4A16 (NPU) — primary",
          "limit": { "context": 4096, "output": 2048 }
        }
      }
    },
    "geniex-gpu": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "GenieX (Snapdragon GPU)",
      "options": {
        "baseURL": "http://127.0.0.1:18182/v1",
        "apiKey": "geniex"
      },
      "models": {
        // GGUF lane: --nctx applies here, so the context can be raised
        "unsloth/Qwen3-4B-GGUF:Q4_0": {
          "name": "Qwen3 4B (GPU lane)",
          "limit": { "context": 16384, "output": 4096 }
        }
      }
    }
  }
}
```

Four things that silently break this:

| Pitfall | Consequence |
|---|---|
| Model key ≠ the id in `/v1/models` (dropping `:W4A16`) | opencode sends an unknown model; the server errors or falls back |
| `baseURL` without `/v1` | 404 on every request |
| Empty `apiKey` | The SDK refuses to send; GenieX itself never checks the value |
| `context` > 4096 on the QAIRT model | Overflow returns nothing at all — no error |

### Step 4 — select it in opencode

```bash
opencode
# then: /models  →  pick "GenieX (Snapdragon NPU)" → Qwen3 4B Instruct W4A16
```

Pin it as the default for a session with `opencode --model geniex/qualcomm/Qwen3-4B-Instruct-2507:W4A16`
(the form is `<provider-key>/<model-key>`).

### Step 5 — verify before blaming the agent

```bash
curl -s http://127.0.0.1:18181/v1/models   # NPU lane   (primary)
curl -s http://127.0.0.1:18182/v1/models   # GPU lane   (second stream)
curl -s http://127.0.0.1:18183/v1/models   # hybrid lane (opt-in)

# end-to-end, should answer in ~2 tokens
curl -s http://127.0.0.1:18181/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qualcomm/Qwen3-4B-Instruct-2507:W4A16",
       "messages":[{"role":"user","content":"Reply with exactly one word: OK"}]}'
```

If that curl works and opencode does not, the fault is in the config block, not
in GenieX.

**Request timing (measured):** the first request after a server start includes
the model load — ~14 s for the QAIRT 4B, ~46 s for the 9B on hybrid. Set the
agent client's request timeout to **≥ 90 s**; afterwards the server answers
immediately (0.1–0.2 s TTFT warm). With `--keepalive 86400` the model stays
resident, so the cold load happens once per server start rather than after
every 5-minute pause.

**Budget the 4096 context deliberately.** It is the binding constraint of this
lane, not the speed: an agent system prompt plus one medium file can exhaust
it. Keep the agent's context lean, and move long-context work to a GGUF lane
(`--nctx 16384`) or off-box.

### Which Qwen3.8-class models fit this machine (all measured 2026-08-31, incl. post-RAM-tuning re-test)

| Model | Size (Q4) | NPU only | **hybrid** (NPU+CPU) | GPU | CPU |
|---|---|---|---|---|---|
| **Qwen3.8-2B-Distill** (`empero-ai`) | 1.31 GB | ✅ 16.9 tok/s | ✅ ~16 tok/s | ✅ | ✅ **46.5 tok/s — best** |
| **Qwen3-4B** (`unsloth`) | 2.2 GB | ✅ 11.9 tok/s | ✅ 9.96 tok/s | ✅ 12.5 tok/s | ✅ **23.7 tok/s — best** |
| **Qwen3.8-9B-Distill** (`empero-ai`) | 5.78 GB | ❌ over HTP budget | ✅ 7.5 tok/s | ✅ 6.5 tok/s | ✅ **15.2 tok/s — best** |
| **Qwen3.8-27B** Q4_0 (`unsloth`) | 16.1 GB | ❌ | ❌ crashes (`dspqueue_read failed: 0x00000072`) | ❌ OOM | ✅ slow |
| **Qwen3.8-27B** Q3_K_XL | 13.1 GB | ❌ | ❌ **no crash, but unusable** — server never answers within 600 s | ⚠️ loads, then thrashes (2.0 tok/s) | ✅ slow |

**Correction (re-measured): hybrid does not win anything.** The original
conclusion here — "hybrid wins for models that straddle the HTP budget" —
compared hybrid only against the NPU and the GPU, never against the **CPU**.
Once the CPU lane is measured, hybrid loses everywhere:

| Model | hybrid | **CPU** | GPU | NPU |
|---|---|---|---|---|
| Qwen3-4B `Q4_0` | 9.96 tok/s | **23.7** | 12.5 | 11.9 |
| Qwen3.8-9B-Distill `Q4_K_M` | 7.5 tok/s | **15.2** | 6.5 | ❌ over HTP budget |

The 9B — the model hybrid was supposedly *for* — runs **2x faster on plain
CPU** (15.2 vs 7.5), with a first token in 0.44 s instead of 26.6 s.

**`--ngl` does not rescue it.** Sweeping the layer-offload knob on the 9B in
hybrid mode changes nothing meaningful:

| `--ngl` | decode | TTFT |
|---|---|---|
| `-1` (all, default) | 7.32 tok/s | 26.6 s |
| `32` | 7.20 tok/s | 19.3 s |
| `16` | 6.18 tok/s | 15.6 s |
| `8` | 7.83 tok/s | 13.9 s |
| — *(pure CPU, for scale)* | **15.17 tok/s** | **0.44 s** |

Every hybrid configuration sits at 6–8 tok/s, roughly half the CPU lane, with a
15–27 s first token. The bottleneck is not how the layers are split; it is that
any HTP participation drags the whole graph down to the `ggml-hexagon` backend's
speed.

**Verdict: there is no reason to run `--compute hybrid` on this machine.** It is
slower than the CPU for every model tested, it is the only mode that damages a
concurrently running NPU lane (19.25 → 12.84 tok/s, shared HTP), and its first
token is 30–60x slower. Use `cpu` for GGUF models and `npu` for QAIRT bundles.

**Nothing combines GPU+NPU on one model.** `hybrid` = NPU + CPU only. The 27B
Q4_0 crashes on both NPU and hybrid (the single HTP cannot even stage a
fraction); the 27B Q3_K_XL does not crash but neither completes a request in
a practical time on hybrid or GPU — for 27B, CPU is the only reliable path.

**Best lane for any GGUF here: `--compute cpu`.** It is the fastest backend for
every GGUF measured (2B 46.5, 4B 23.7, 9B 15.2 tok/s) — the price is that it
saturates the machine (7.5 of 8 cores).

**But the best model overall on this machine is not a GGUF at all.** The QAIRT
bundle `qualcomm/Qwen3-4B-Instruct-2507:W4A16` beats every row of this table
end-to-end (19.5 tok/s and no `<think>` tax — ~6x faster to a finished answer
than the 4B GGUF). See § Getting the most out of this machine.

### Measured compute envelope (Lenovo Snapdragon X, 2026-08-31, AFTER NPU driver update)

All speeds are token/s on short replies; first-token latency in parentheses.

| Compute | 2B-Distill Q4_K_M | 4B Q4_0 | 9B-Distill Q4_K_M | 27B Q4_0 | 27B Q3_K_XL |
|---|---|---|---|---|---|
| **NPU** (Hexagon HTP) | **16.9** (0.2 s) | **15.2** (0.2 s) | ❌ over HTP budget | ❌ `dspqueue_read failed: 0x00000072` | ❌ over HTP budget |
| **hybrid** (HTP + CPU) | ~16 | 14.1 / 9.96† (2.6 s) | 7.5 (3.1 s) | ❌ crashes | ❌ no answer in 600 s |
| **GPU** (Adreno X1-45) | ~13 | 13.2 | 6.5 (0.6 s) | ❌ OOM (Q4_0) | ⚠️ 2.0 tok/s, thrashes |
| **CPU** (Windows host, 8x Oryon) | **46.5** | **23.2** | **15.2** (0.4 s) | ~1 (224 s incl. load) | n/m |

CPU figures for the 2B and 4B are now **measured on the Windows host** via a
`--compute cpu` lane, and they beat the NPU on the same GGUF by ~2x — see
§ 1b. (The earlier "~5 tok/s" estimates, scaled from a 27B WSL2 run, were wrong
by ~4.6x.) The 27B Q4_0 number remains a single measured WSL2 data point.

† Two methodologies are mixed in this table. The original rows used short
replies; the re-measurement in § 1b / § 2 used one fixed prompt with the full
answer streamed, which is why the 4B reads 15.2 on the NPU here and 11.9 there,
and hybrid 14.1 here and 9.96 there. **Within** a comparison the numbers are
consistent; do not compare a § 1b figure against an original-row figure. The
re-measured set is the one to trust for lane choice, since it also ran with the
other lanes resident.

**The HTP vmem limit — what it is and why RAM tuning did not change it:**

The Hexagon HTP is a separate on-die DSP block, not the host CPU/RAM. Each HTP
session gets a **virtual-memory budget of 2,93 GiB** (`3145728000` bytes,
printed at load: `vmem 3145728000`) for weights + activations + KV cache.
Model graphs above that limit fail at compute with
`dspqueue_read failed: 0x00000072`; `hybrid` can only offload the layers that
fit inside that budget and runs the rest on CPU. That is why freeing ~20 GB of
host RAM changed nothing for NPU/hybrid — the ceiling is on-die, not host
memory. (It did matter for the GPU path, see § Making room.)

**The 27B quant ladder — the full picture (measured 2026-08-31)**

The 27B runs on exactly one lane: **CPU**. What limits the quant is host RAM —
31.6 GB total, minus WSL2's cap (10 GB via `.wslconfig`) and Windows itself,
leaves **~22–24 GB** for the model with the other lanes stopped. (The Adreno is
irrelevant here: it OOMs at Q4_0 and returns HTTP 500.)

| Quant | Size | Verdict |
|---|---|---|
| `UD-IQ1_S` / `UD-IQ1_M` | 6.2 / 6.7 GB | ❌ i-quant — expected broken (untested) |
| `UD-IQ2_XXS` / `UD-IQ2_S` | 7.3 / 8.4 GB | ❌ i-quant — expected broken (untested) |
| `UD-Q2_K_XL` | 9.8 GB | ❌ i-quant-heavy — expected broken (untested) |
| `UD-IQ3_XXS` | 10.9 GB | ❌ i-quant — expected broken (untested) |
| `UD-IQ3_S` | 12.0 GB | ❌ **measured: garbage — i-quant bug** |
| `UD-Q3_K_XL` | 13.1 GB | ❌ **measured: garbage — i-quant bug** |
| `UD-IQ4_XS` | 14.3 GB | untested |
| `UD-Q4_K_S` | 15.4 GB | untested |
| **`Q4_0`** | **16.1 GB** | ✅ **5.62 tok/s, TTFT 1.06 s — recommended** |
| `UD-Q4_K_M` | 16.5 GB | ✅ 5.08 tok/s, TTFT 2.38 s — **10 % slower, no visible quality gain** |
| `Q4_1` / `UD-Q4_K_XL` | 17.5 / 17.6 GB | fits, untested |
| `UD-Q5_K_S` | 18.7 GB | ⚠️ practical ceiling; tight against the WSL2 cap |
| `UD-Q5_K_M` / `UD-Q5_K_XL` | 19.8 / 20.9 GB | ⚠️ very tight, likely swaps |
| `UD-Q6_K` and above | 22 GB+ | ❌ does not fit |
| `Q8_0` | 29 GB | ❌ does not fit |

**The sub-Q4 failures are a GenieX bug, not a quality floor** — see
§ Debugged: i-quants below 4 bits are broken. Short version: the garbage output
is not degraded quality, it is broken inference in the i-quant kernels, and it
hits *every* model, not just this one. K-quants at 3 bits are fine. Since this
repo only offers **i-quant-based** variants below `Q4_0`, the practical advice
("do not go under `Q4_0` here") stands — but the reason matters, because a
plain `Q3_K_M` from another uploader would likely work, and a GenieX update may
fix it outright.

**Going *up* from `Q4_0` did not pay off either.** `UD-Q4_K_M` was pulled and
measured head to head: **5.08 vs 5.62 tok/s (~10 % slower)** with a 2.2x worse
first token, while both produced equivalent output on a code task and both
answered an arithmetic check with a verifiable result correctly
(`847 * 293` → `248171`). The likely cause of the speed gap: llama.cpp repacks
legacy `Q4_0` into ARM-optimised kernels (`Q4_0_4_8` / i8mm) that K-quants do
not get — the same mechanism that makes the CPU lane fast in the first place.

> **Caveat on the quality half of that comparison.** Two prompts is not a
> quality evaluation. `UD-Q4_K_M` is in principle the better quantisation; the
> honest finding is only that **no difference was demonstrable here, while the
> 10 % speed cost was**. If 27B quality matters to you, benchmark it properly
> instead of trusting either row.

**Bottom line: `Q4_0` on the CPU lane is the 27B setup to use.** For interactive
coding the realistic choice remains the QAIRT 4B on the NPU; the 27B on CPU is
the quality option for work you are willing to wait for.

## Getting the most out of this machine (measured 2026-08-31)

The first pass of this page optimised the wrong variable: it compared *compute
units* on GGUF models and concluded the 4B on the NPU at 15.2 tok/s was the
ceiling. Re-measuring end-to-end — the number a coding agent actually waits on —
found three larger wins.

### 1. Use the QAIRT bundle, not the GGUFs — ~6x faster end-to-end

`qualcomm/Qwen3-4B-Instruct-2507:W4A16` is a pre-compiled Qualcomm AI Hub
bundle. It wins twice over:

| | GGUF `unsloth/Qwen3-4B:Q4_0` | QAIRT `qualcomm/Qwen3-4B-Instruct-2507:W4A16` |
|---|---|---|
| decode | 11.5 tok/s | **18.9–19.5 tok/s** |
| tokens emitted for one short coding answer | ~1889 | **522** |
| wall clock for that answer (warm) | 164.8 s | **26.8 s** |
| cold load | 6.8 s | 14.3 s |

**tok/s is the wrong metric — the 1.7B proves it.** `qualcomm/Qwen3-1.7B:W4A16`
is the fastest model measured on this machine per token, and the slowest to a
finished answer:

| | Qwen3-1.7B W4A16 | **Qwen3-4B-Instruct-2507 W4A16** |
|---|---|---|
| decode | **31.7 tok/s** | 19.5 tok/s |
| tokens per answer | 1921 (it reasons) | **522** |
| **time to a finished answer** | 60.8 s | **26.8 s** |

1.6x the token rate, 2.3x the wait. Pick the model by *time to a finished
answer*, never by tok/s alone.

The decode gain is 1.7x; the rest is the **`<think>` tax**. The Qwen3.8-Distill
and Qwen3 GGUFs are *reasoning* models — asked to "reply with exactly one word:
OK" the 2B spends 21 tokens thinking about it, and a real question costs
1600–2000 tokens of chain-of-thought before the answer starts. The
Instruct-2507 bundle answers in 2 tokens. For an agent that is doing tool calls
rather than maths olympiad, the thinking is pure latency.

> **The catch: QAIRT bundles have a hard-compiled context.** This one is
> **4096 tokens** (`genie_config.json` → `"context": {"size": 4096}`), and
> `--nctx` does *not* apply to them — it is a llama.cpp-only flag. Overflow it
> and the request returns nothing. That is the real cost of this lane: you trade
> context length for ~6x speed. Long-context work belongs on the GGUF lanes
> (`--nctx 16384`) or off-box.

> **QAIRT also sidesteps the HTP vmem wall.** The 4B W4A16 bundle is **3.0 GiB**
> — larger than the ~2,93 GiB budget that makes GGUF models fail with
> `dspqueue_read failed: 0x00000072`. That limit is a property of the bundled
> llama.cpp `ggml-hexagon` backend, **not** of the NPU. QAIRT bundles are the
> way to run bigger graphs on the HTP.

### 1b. The CPU is the fastest llama.cpp backend on this machine

This page previously listed CPU speeds as *estimates scaled from a 27B run*
("~5 tok/s" for the 4B). Measured on the Windows host — 8 Oryon cores,
`--compute cpu`, identical model, identical quant, identical prompt — that
estimate was wrong by ~4.6x:

| Model (GGUF) | CPU (8x Oryon) | NPU (Hexagon HTP) | CPU advantage |
|---|---|---|---|
| Qwen3-4B `Q4_0` | **23.2 tok/s** | 11.9 tok/s | **1.95x** |
| Qwen3.8-2B-Distill `Q4_K_M` | **46.5 tok/s** | 16.9 tok/s | **2.75x** |

**For GGUF models the Hexagon NPU is the slower option, by a factor of two.**
llama.cpp's ARM CPU kernels (NEON / dotprod / i8mm, and `Q4_0` in particular is
repacked for them) are mature; the bundled `ggml-hexagon` backend is not.

The catch is what it costs the machine:

| Lane | Decode | CPU load during inference |
|---|---|---|
| `--compute cpu`, 4B GGUF | 23.2 tok/s | **752 % of 800 %** — 7.5 of 8 cores |
| `--compute npu`, 4B QAIRT | 19.5 tok/s | **165 % of 800 %** — 1.65 cores |

CPU inference **saturates the machine**; the NPU lane leaves ~6.5 cores free
(`genie_config.json` pins it to `n-threads: 3`, `cpu-mask 0xe0`). Note the
worker is a *separate* `geniex` process from the one holding the port — measure
the child, not the listener, or you will read ~11 % and conclude nothing is
happening.

**So: is the NPU worth using?** For raw tok/s on a GGUF, no — the CPU wins
2x. The NPU earns its place on two other axes: it runs QAIRT bundles (which the
CPU cannot load at all, and which are non-thinking and therefore fastest
*end-to-end*), and it does so at a fifth of the CPU cost, which is what lets a
coding agent answer while the machine is also compiling. On battery, the gap
widens further in the NPU's favour.

**Best end-to-end, all lanes considered:**

| Setup | tok/s | tokens/answer | time to answer | cores used |
|---|---|---|---|---|
| **QAIRT 4B-Instruct on NPU** | 19.5 | **522** | **26.8 s** | **1.65** |
| GGUF 4B on CPU | **23.2** | 2048 | 88.4 s | 7.5 |
| GGUF 4B on NPU | 11.9 | ~1400–2048 | 122.9 s | ~1.7 |

The QAIRT/NPU lane still wins the thing that matters — *and* leaves the machine
usable. But that win comes from the model not reasoning, not from the silicon.

### 1c. The full Qwen3.8 matrix — every model against every lane

One prompt, one methodology, all four lanes, measured 2026-08-31 after the
lane work above. **The CPU wins every single row.**

| Qwen3.8 model | Size | NPU | GPU | hybrid | **CPU** |
|---|---|---|---|---|---|
| **2B-Distill** `Q4_K_M` | 1.3 GB | 18.2 | 23.1 | 20.7 | **47.6 tok/s** |
| **9B-Distill** `Q4_K_M` | 5.8 GB | 8.4 | 6.8 | 7.35 | **15.2 tok/s** |
| **27B** `Q3_K_XL` | 13.1 GB | ❌ | ❌ | ❌ | ⚠️ **broken quant** |
| **27B** `Q4_0` | 16.1 GB | ❌ | ❌ HTTP 500 | ❌ | **5.6 tok/s** ✅ |

Three things this table settles:

**The accelerator ranking flips with model size, and it does not matter.** On
the 2B the order is GPU > hybrid > NPU; on the 9B it inverts to NPU > hybrid >
GPU. Either way the CPU is 2–2.6x ahead of whichever accelerator happens to win.

**The 27B is usable after all — at Q4_0, on the CPU.** This page previously
called the 27B "CPU-only territory... ~1 tok/s" and effectively wrote it off.
Measured on the Windows host it does **5.6 tok/s warm with a 1.06 s first
token**, and the output is correct, well-structured code. That is slow for
interactive chat but perfectly usable for batch or background work — and it is
the best *quality* any lane on this machine can produce.

**`Q3_K_XL` is not "borderline", it is broken.** The page previously listed it
as "the last quant worth trying above 12 GB". It loads and it answers, but the
answer is garbage — a real request returned `'0\n\n\n\n\n\n\n\n -\n0\n0'`
(12 tokens, `finish_reason: stop`). Same failure mode already noted for
`IQ3_S`. **Below Q4, this 27B is unusable at any speed.** Use `Q4_0` on the CPU
lane, or do not run the 27B.

> **Do not mix QAIRT and GGUF models on the NPU lane — it crashes the server.**
> Reproduced deterministically: a fresh lane serves a GGUF fine, then serves a
> QAIRT bundle fine, and the *next* GGUF request kills the process (connection
> reset, PID gone). Since an opencode provider lists several models against one
> `baseURL`, switching model in the UI is enough to trigger it. Keep the NPU
> lane QAIRT-only and put GGUFs on the CPU lane — which is faster for them
> anyway.

### 1d. Which model writes code that actually runs (measured 2026-08-31)

Every claim above is about speed. This one is about *output*: each model was
given three coding tasks with an exact required signature, its code was
extracted and **executed** against hidden tests
(`linux/llm-stack/bench_coding.py`). Nothing judged by eye.

| Model | Lane | Pass | Cut | Total | ø/task | ø TTFT | ø tokens | think |
|---|---|---|---|---|---|---|---|---|
| **QAIRT Qwen3-4B-Instruct-2507 W4A16** | NPU | **3/3** | 0 | **30.2 s** | **10.1 s** | 0.17 s | 188 | **0 %** |
| GGUF Qwen3.8-27B `Q4_0` | CPU | 3/3 | 0 | 128.7 s | 42.9 s | 14.8 s | 149 | 0 % |
| GGUF Qwen3.8-9B-Distill `Q4_K_M` | CPU | 3/3 | 0 | 251.1 s | 83.7 s | 3.7 s | 1151 | 51 % |
| GGUF Qwen3.8-2B-Distill `Q4_K_M` | CPU | 2/3 | 0 | 32.2 s | 10.7 s | 0.31 s | 485 | 37 % |
| GGUF Qwen3-4B `Q4_0` | CPU | 2/3 | 1 | 227.2 s | 75.7 s | 0.48 s | 1639 | 61 % |
| QAIRT Qwen3-1.7B W4A16 | NPU | 1/3 | 2 | 173.8 s | 57.9 s | 0.13 s | 1829 | 31 % |

**Three models solve all three tasks; the tiebreaker is time, and it is not
close.** The QAIRT 4B-Instruct is **4.3x faster than the 27B** and **8.3x faster
than the 9B** to the same score, because it does not reason: 188 tokens per task
against the 9B's 1151.

**The 27B beats the 9B despite decoding at 5.6 vs 15.2 tok/s** — the classic
demonstration that ranking by tok/s picks the wrong model. It writes 149 tokens
of correct code where the 9B writes 1151 tokens of mostly thinking.

**A hard 2048-token output cap decides more than model quality here.** GenieX
stops generating at 2048 tokens and ignores `max_tokens` entirely
(`max_tokens=3000` produced 642 tokens; `max_tokens=500` produced 1249). A
reasoning model spends that budget inside `<think>` and is cut mid-function.
The 4B GGUF's `balanced` solution finished at **1896 tokens — 152 short of the
cap**; a little more deliberation and it would have scored as a failure. This
is why the benchmark reports *cut* separately from *wrong*: the first run of it
scored that model 0/3, all three "failures" truncation artefacts.

**Repeated 3x per task, because a single run measures one draw.** GenieX
ignores `temperature` exactly as it ignores `max_tokens`: five identical
requests to the 2B produced **five different answers**, four passing the same
task and one failing it. The single-run scores above are therefore indicative
for the close calls; these are the defensible numbers:

| Model | Pass rate | wrong | cut | per attempt |
|---|---|---|---|---|
| **QAIRT Qwen3-4B-Instruct-2507** | **9/9 = 100 %** | 0 | 0 | 10.2 s |
| GGUF Qwen3.8-2B-Distill | 4/9 = 44 % | 5 | 0 | 10.5 s |
| GGUF Qwen3-4B `Q4_0` | 4/9 = 44 % | **0** | 5 | 101.9 s |

Per task (P=pass, F=fail, C=cut):

| Model | merge_sorted | balanced | parse_version |
|---|---|---|---|
| QAIRT 4B-Instruct | `PPP` | `PPP` | `PPP` |
| GGUF 2B-Distill | `PPP` | `PFF` | `FFF` |
| GGUF Qwen3-4B `Q4_0` | `CPP` | `CPP` | `CCC` |

Three things that only repeats could show:

- **The winner is byte-identical deterministic.** Four identical requests per
  task yielded **one** unique output each — the QAIRT/QNN path does not sample.
  Its 100 % is not luck, and repeats on that lane only cost time.
- **The 2B has a real capability hole, not bad luck**: `parse_version` fails
  every single time. Its flakiness is confined to `balanced`.
- **The 4B GGUF is never *wrong* — it is *cut off*.** Zero wrong answers in
  nine attempts; every failure is the 2048-token cap. Given room it would
  likely match the winner, but on this server it cannot deliver, and it needs
  **10x the time** per attempt.

**Tuning the NPU lane does nothing** (measured, config restored afterwards):
`n-threads` 3 → 6 → 8 with `cpu-mask` widened to all cores gives 18.76 / 19.03
/ 18.76 tok/s — noise. The HTP does the work; those threads only orchestrate.
`perf_profile` is already `burst`.

**Caveat.** Three tasks is a smoke test, not a capability benchmark, and all
three are self-contained functions — no multi-file work, no tool calls, and
short prompts rather than the long context an agent really sends. It separates
"writes working code" from "does not"; it does not rank senior engineers.

### 1e. Under a realistic agent context (measured 2026-08-31)

Everything above uses ~40-token prompts. An agent sends a system prompt plus
files — thousands of tokens. Re-run with real repository source prepended
(`bench_coding.py --context-tokens N`):

| Context | Pass | TTFT | Output tokens |
|---|---|---|---|
| none | **3/3** | 0.13 s | 129–284 |
| +1000 | 2/3 | 1.03 s | 92–222 |
| +2000 | 2/3 | 2.05 s | 102–294 |
| +3000 | 2/3 | 3.20 s | 118–294 |
| +5000 | **0/3** | **0.00 s** | **0** |

**The 4096-token limit is input *plus* output, and it fails silently.** Probing
the edge with one task:

| Context | Output tokens | Behaviour |
|---|---|---|
| ~3800 | 127 | normal |
| ~4000 | **15** | nearly mute — almost no room left to answer |
| ~4500 | **0** | **instant empty reply, 0.00 s, no error** |

That last row is the one to design around. Over the limit the server returns
**nothing at all, immediately, with no error message** — an agent sees an empty
answer, not "your prompt was too long". Budget the context yourself; nothing
will warn you. With ~300 output tokens needed for a function, the practical
input ceiling is **~3700 tokens**.

**Accuracy also decays before the wall:** 3/3 with no context, 2/3 from 1000
tokens on. The failing task moves around (`balanced` at 1–2k, `parse_version`
at 3k), which is *not* sampling noise here — the QAIRT path is deterministic,
so each of these is reproducible. Irrelevant context makes this model worse.

**Prefill is where the NPU earns its place — 10x the CPU lane:**

| Lane | Measured | Prefill rate |
|---|---|---|
| **NPU (QAIRT 4B)** | 1000→1.0 s, 2000→2.1 s, 3000→3.2 s, 3800→4.5 s | **~930 tok/s** |
| CPU (GGUF 4B) | 3000→34.2 s / 31.9 s | ~91 tok/s |

A 3000-token prompt costs **3.2 s on the NPU against 34 s on the CPU**, and the
CPU lane's whole task ran 142–198 s versus the NPU's 12–25 s. This inverts the
short-prompt picture, where the CPU lane was the *faster* GGUF backend: under a
realistic agent context the NPU lane wins on both prefill and total time.

(An earlier one-off measurement on this page put NPU prefill at ~190 tok/s. The
swept figures above supersede it — that single sample mis-estimated its own
prompt length.)

**The real trade-off for an agent, then:** the NPU lane is 10x faster to first
token but capped at ~3700 usable input tokens, and it goes silent past that.
The GGUF lanes carry `--nctx 16384` but pay ~34 s of prefill per 3000 tokens.
There is no configuration here that is both long-context and fast.

**What is still unmeasured:** the hybrid lane on coding tasks, `nctx` scaling
below 16384, and `--ngl`. The lane question itself *is* settled: Qwen3-4B `Q4_0` scores identically on CPU and GPU (2/3 + 1 cut,
the same task cut on both), with the GPU 1.78x slower — **the lane changes
speed, not correctness**.

**And the binding constraint is still context, not skill.** The winning bundle
is capped at **4096 tokens** (§ 1a), which an agent's system prompt plus one
medium file can exhaust. For code that must see a lot of repository at once,
the 27B on the CPU lane is the only on-device option with both correctness and
room — at 43 s per task.

### 1f. Tool calling — where the coding winner is weakest (measured 2026-08-31)

An agent lives on tool calls: a model that writes flawless code but cannot emit
a valid one never reads a file, runs a test, or applies a patch. Measured with
`linux/llm-stack/bench_tools.py` (four advertised tools, six cases, 2 repeats).

**GenieX supports tool calling natively** on both lanes —
`finish_reason: tool_calls`, correct names, correctly extracted arguments.

| Model | Tool calls | Coding | Time |
|---|---|---|---|
| **GGUF Qwen3-4B `Q4_0` (CPU)** | **12/12 = 100 %** | 44 % (cut-limited) | 88 s |
| **QAIRT 4B-Instruct (NPU)** | **8/12 = 67 %** | **100 %** | **25 s** |
| GGUF Qwen3.8-2B (CPU) | 2/12 = 17 % | 44 % | 55 s |

**This is the one result that does not crown the coding winner.** Per case:

| Case | QAIRT 4B | GGUF 2B | GGUF 4B |
|---|---|---|---|
| `simple_read` | `FF` | `FF` | `PP` |
| `pick_from_several` | `PP` | `FF` | `PP` |
| `argument_extraction` | `PP` | `FF` | `PP` |
| `optional_argument` | `FF` | `FF` | `PP` |
| `no_args_tool` | `PP` | `FF` | `PP` |
| `no_tool_needed` | `PP` | `PP` | `PP` |

The QAIRT bundle's two failures are reproducible (deterministic path) and
specific — and **one of them is yours to fix**:

- **`simple_read`: picked `list_files` instead of `read_file`.** A tool-*selection*
  error, and it disappears with a sharper description: spelling out that
  `read_file` returns *contents* and `list_files` returns *names only, not
  contents* flips it from FAIL to PASS. **Write your tool descriptions
  contrastively** — this model distinguishes tools by their text, not by their
  names.
- **`optional_argument`: emitted the arguments as message *text* instead of a
  tool call** — `{"case_sensitive": true, "query": "Foo"}`. The values are
  *correct*; only the channel is wrong. Forcing `tool_choice: "required"` does
  **not** fix it (verified). An agent with a fallback that parses a bare JSON
  object out of the content would recover this turn; opencode out of the box
  will not.

**Both are fixed by a system prompt — measured 12/12.** opencode does *not*
allow overriding its built-in tools' descriptions (its schema exposes
`instructions`, `mcp`, `permission` and `agent`, but no tool-description hook),
so the sharper-description fix above is not actually available there. Delivering
the same disambiguation through the system prompt works, and works *better* —
it repairs the text-instead-of-call case that neither a better description nor
`tool_choice: "required"` could:

| | Tool calls |
|---|---|
| QAIRT 4B-Instruct, no system prompt | 8/12 |
| **QAIRT 4B-Instruct + `prompts/tool-disambiguation.md`** | **12/12, 24.1 s** |
| GGUF Qwen3-4B `Q4_0` (for comparison) | 12/12, 88.1 s |

`linux/llm-stack/prompts/tool-disambiguation.md` is that file, and
`bench_tools.py --system <file>` is how it was verified rather than assumed.
Wired into this host's `~/.config/opencode/opencode.jsonc` via `instructions`.

**With it, the coding winner also wins here** — same perfect score as the GGUF
4B at 3.7x the speed.

**Every model got `no_tool_needed` right**, so over-eager tool calling is not a
problem here — including on the 2B, which failed everything else.

**Does this change the recommendation?** Not once the system prompt is in
place — the QAIRT bundle then matches the GGUF 4B's 12/12 at 3.7x the speed.
Without it, the trade-off below is real.
The GGUF 4B is perfect at tool calls and hopeless at agent latency: § 1e
measured 34 s of prefill at 3000 tokens of context and 151 s at 8000, against
the NPU lane's 3.2 s. An agent loop pays that on *every* turn, and a tool-using
loop has many turns. The QAIRT bundle stays the practical choice for
interactive work — with contrastive tool descriptions, and knowing roughly one
call in six will arrive as text rather than as a call.

### 2. Run NPU + GPU lanes — they compose almost perfectly

One server = one request at a time. Throughput scales only by adding servers,
and *which* servers you add matters:

| Topology | NPU | GPU | CPU | hybrid | aggregate |
|---|---|---|---|---|---|
| NPU alone | 18.6–19.5 | — | — | — | 19.5 tok/s |
| GPU alone | — | 12.5 | — | — | 12.5 tok/s |
| CPU alone | — | — | 23.7 | — | 23.7 tok/s |
| NPU + GPU | 19.25 | 12.11 | — | — | 31.4 tok/s |
| **NPU + CPU** | **18.85** | — | **20.81** | — | **39.7 tok/s** |
| **NPU + GPU + CPU** | **18.66** | **11.13** | **15.64** | — | **45.4 tok/s** |
| NPU + GPU + hybrid | 12.84 | 11.16 | — | 10.12 | 34.1 tok/s |
| NPU + hybrid | 13.89 | — | — | 15.65 | 29.5 tok/s |

**The NPU lane is immune to contention.** Across every combination above it
holds 18.6–19.25 tok/s — adding a CPU lane, a GPU lane or both costs it
nothing measurable. It is isolated silicon with a small, *pinned* CPU footprint
(`n-threads: 3`, `cpu-mask 0xe0`). The CPU and GPU lanes, by contrast, fight
each other for the same 8 Oryon cores: the CPU lane drops 23.7 → 20.8 → 15.6 as
lanes are added, the GPU lane 12.5 → 11.1.

**Max aggregate is NPU + GPU + CPU at 45.4 tok/s**; the best two-lane pairing is
**NPU + CPU at 39.7 tok/s** (better than NPU+GPU's 31.4, because the CPU lane is
the strongest GGUF backend). `hybrid` remains the one to avoid — it is the only
mode that damages the NPU lane, because it shares the same HTP.

**NPU + GPU is the sweet spot.** The Hexagon HTP and the Adreno are separate
silicon, so the two lanes cost each other ~1–3 % (19.5 → 19.25, 12.5 → 12.11).
Adding `hybrid` buys +2.7 tok/s aggregate but **costs the NPU lane a third of
its speed** (19.25 → 12.84), because `hybrid` is NPU+CPU and contends for the
same single HTP. Run two lanes by default; add the third only when you really
have three concurrent streams and care about total tokens, not per-answer
latency.

**None of this makes one answer faster.** Aggregate throughput only
materialises if you genuinely have *n* concurrent requests — three parallel
subagents, or three opencode sessions. A single agent waiting for a single
reply still sees 18.6 tok/s on the NPU lane, no matter how many lanes are up.
And with all three lanes busy the machine is saturated (the 3-lane run took
194.7 s wall, paced by its slowest lane), so interactive work suffers.

Splitting *one* model across NPU and CPU is a different thing entirely — that
is `--compute hybrid`, and for a model that fits the HTP it is slower than
either lane alone (14.1 vs 15.2 tok/s on the 4B).

### 3. Fix the two server defaults

| Flag | Default | Set it to | Why |
|---|---|---|---|
| `--keepalive` | 300 s | `86400` | The model unloads after 5 idle minutes; the next prompt pays a 14–15 s cold load. A coding session pauses constantly. |
| `--nctx` | 4096 | `16384` | Smaller than the context the agent config advertises. Overflow does not error — a 6.4k-token prompt never returned within 400 s. |

`windows/scripts/host/start-geniex-servers.ps1` sets both and brings up both
lanes in one command.

### What is still slow, honestly

- **Prefill is the agent bottleneck, not decode.** A ~2.5k-token prompt costs
  **13.1 s before the first token** (~190 tok/s prefill) and drags decode down
  from 19.5 to 13.0 tok/s. Long system prompts and pasted files hurt far more
  than the decode rate does. Keep the agent's context lean.
- **No batching, no speculative decoding.** `geniex serve` exposes only
  `--host/--origins/--keepalive/--nctx/--ngl/--compute` (+TLS). There is no
  draft-model or parallel-slot flag to turn on.
- **`max_tokens` is not honoured** — a request capped at 16 returned 21 tokens,
  and streamed requests ran to the model's own stop. Budget by prompt, not by
  the parameter.

## Debugged: i-quants below 4 bits are broken in this GenieX build

The 27B's `Q3_K_XL` and `IQ3_S` answer with garbage. The first explanation on
this page — "3-bit quality collapses, there is a hard floor at Q4" — was wrong.
Walking the hypotheses down:

| Hypothesis | Test | Result |
|---|---|---|
| Sampling artefact | `temperature=0`, prompt `"Say hello."` | ❌ still garbage (`'\n\n\n....\n\n'`); `Q4_0` answers `'Hello! How can I help you today?'` |
| Corrupt download | byte size + SHA256 vs the Hugging Face LFS oid | ❌ **byte-perfect** (`8c2a45ff…a67a5e`, 13,146,393,504 bytes) |
| CPU-backend bug | same file on the GPU (OpenCL) lane | ❌ fails there too |
| "Unsloth UD quants are bad" | `UD-Q4_K_M` from the same repo | ❌ works fine (5.08 tok/s, correct code) |
| "3 bits is simply too few" | `Qwen3-4B:Q3_K_M` (3-bit **K**-quant) | ❌ **works perfectly** — coherent output |
| **i-quant kernels are broken** | `Qwen3-4B:IQ3_XXS` — different model, different arch, i-quants | ✅ **garbage on both CPU and GPU** |

**The answer is the tensor *type*, not the bit width.** Dumping the GGUF tensor
histograms makes the split obvious:

| File | i-quant content | Works? |
|---|---|---|
| `Qwen3.8-27B-Q4_0` | none | ✅ |
| `Qwen3.8-27B-UD-Q4_K_M` | `IQ4_XS` 117, `IQ4_NL` 7, `IQ3_S` **4** | ✅ |
| `Qwen3-4B-Q3_K_M` | none (`Q3_K` 144, `Q4_K` 104) | ✅ |
| `Qwen3.8-27B-UD-Q3_K_XL` | `IQ3_S` 111, `IQ3_XXS` 34, `IQ2_*` 21 | ❌ |
| `Qwen3.8-27B-UD-IQ3_S` | `IQ3_S` 127, `IQ3_XXS` 77, `IQ2_*` 45, `IQ1_S` 2 | ❌ |
| `Qwen3-4B-UD-IQ3_XXS` | `IQ3_XXS` 144, `IQ2_S` 52, `IQ3_S` 41 | ❌ |

**`IQ4_XS` and `IQ4_NL` are fine; `IQ3_S`, `IQ3_XXS`, `IQ2_*` and `IQ1_*` are
not.** A file survives a handful of IQ3_S tensors (the working `Q4_K_M` has 4)
but not a hundred of them. The failure reproduces across two model families
(`qwen3` and `qwen35`), two model sizes (4B and 27B) and both compute lanes, on
files verified byte-identical to what Hugging Face published — so it is neither
a bad download nor a bad quantisation, but the **i-quant dequantisation path in
the llama.cpp build GenieX v0.5.0 ships** (runtime hash `873e5d8`, aarch64).

The two failure signatures differ but are equally incoherent: the 27B emits
whitespace and punctuation (`'\n\n\n....\n\n'`), the 4B emits real-but-random
multilingual tokens (`' majorityathersyreyrelicht reconciliation…'`).

**What this means in practice**

- Do not pull any `IQ1_*`, `IQ2_*`, `IQ3_*` GGUF for this setup, of any model.
  `UD-Q2_K_XL` is i-quant-heavy too and should be assumed broken.
- **3-bit itself is fine** — a plain `Q3_K_M`/`Q3_K_L` works. It is worth
  looking for a non-`UD` 3-bit build of a model you want to squeeze in.
- `IQ4_XS` is safe, so `UD-Q4_K_M`-class files are safe.
- This is worth reporting upstream to <https://github.com/qualcomm/GenieX>;
  re-test after a GenieX or llama.cpp runtime bump before trusting any i-quant.

## The NPU problem — root cause AND resolution (2026-08-31)

**Both NPU paths failed on the original driver** (Qualcomm FastRPC 1.0.4175.2700
from 20.11.2024; CDSP `libcdsprpc.dll` 30.0.0140.1000 from 16.02.2025), and
they failed for the **same underlying reason**: the installed Qualcomm
CDSP/FastRPC driver predated the runtimes GenieX v0.5.0 bundles.

| Path | Symptom on the OLD driver | Root cause |
|---|---|---|
| llama.cpp Hexagon backend (GGUF models, `--compute npu`) | `ggml-hex: failed to dlsym dspqueue_create`, then `Device 'HTP0' not found` → `SDKError(Invalid input parameters or handle)` | The bundled llama.cpp `ggml-hexagon` backend dlsyms the **`dspqueue_*`** CDSP API (`dspqueue_create/read/write/export/close`, `dspqueue_read_noblock`, `fastrpc_mmap/munmap`). The old `libcdsprpc.dll` exported only the **legacy FastRPC** API (`remote_handle_open`, `remote_session_control`) — verified per-symbol with `GetProcAddress`. |
| QAIRT / QNN HTP backend (`ai-hub-models/*`, `--compute npu`) | `Exception 0xc00000fd` (**STATUS_STACK_OVERFLOW**) during `geniex_llm_create` | QNN v2.45.0's HTP runtime init stack-overflows against the same old CDSP transport — a different symptom, same stale-driver family. |

### The fix: update the Qualcomm Hexagon NPU driver

1. **Windows Settings → Windows Update → Advanced → Optional updates → Driver
   updates**, or download from Lenovo's support page for this model.
2. Install, **reboot**.
3. Re-run the probe:
   `pwsh -File windows/scripts/diagnostics/probe-geniex-npu-driver.ps1` — it must
   report the **active** `libcdsprpc.dll` with all `dspqueue_*` symbols **OK**.

On this host the update took `libcdsprpc.dll` **30.0.0140.1000 → 30.0.0220.3000**
and the Hexagon NPU device to driver **30.0.220.3000**. After the reboot the
4B runs on the NPU at 15.2 tok/s.

> The Windows DriverStore keeps **stale copies** of old drivers. The probe
> deliberately checks the copy matching the Hexagon NPU device's installed
> driver version, so an old store copy can never produce a false "MISSING".

### Remaining limit: HTP memory (~2,93 GiB vmem)

Even with the NPU working, the Hexagon HTP has a **virtual memory budget of
~2,93 GiB** (`vmem 3145728000` in the load log) for weights + activations +
KV cache — the on-die DSP limit, unrelated to host RAM. Models whose graph
exceeds it fail *at graph compute* with `dspqueue_read failed: 0x00000072`.
This is the same class as upstream
[ggml-org/llama.cpp#26123](https://github.com/ggml-org/llama.cpp/issues/26123)
("reproducible at 4B+ params"). The 4B fits; the 27B does not.

**This ceiling belongs to the llama.cpp path only.** The QAIRT bundle
`qualcomm/Qwen3-4B-Instruct-2507:W4A16` is 3.0 GiB — above the same budget —
and runs on the HTP at 19.5 tok/s. If you need a bigger graph on the NPU, reach
for a pre-compiled AI Hub bundle rather than a larger GGUF.

## Troubleshooting

Every row below was hit live on 2026-08-31.

| Symptom | Cause | Fix |
|---|---|---|
| `No chipset configured. Please select your chipset first.` then `could not open a new TTY` | Fresh install; the picker needs an interactive TTY, absent from scripts/CI | `geniex config set chipset qualcomm-snapdragon-x-elite` (non-interactive) |
| Windows `geniex serve` exits with `bind: Only one usage of each socket address` | A WSL-side GenieX server on `127.0.0.1:18181` shadows the port through localhost forwarding | Stop the WSL server (`fuser -k 18181/tcp`) |
| `SDKError(Invalid input parameters or handle)` on `--compute npu`; log shows `ggml-hex: failed to dlsym dspqueue_create` and `Device 'HTP0' not found` | Installed Qualcomm CDSP driver's `libcdsprpc.dll` does not export the `dspqueue_create`/`read`/`write`/`export`/`close` symbols the bundled llama.cpp Hexagon backend needs — a stale driver/backend mismatch | **Update the Qualcomm Hexagon NPU driver** (Windows Update optional updates / Lenovo support), reboot, re-run `windows/scripts/diagnostics/probe-geniex-npu-driver.ps1`. Full analysis: § The NPU problem |
| QAIRT bundle `--compute npu` crashes with `Exception 0xc00000fd` (STACK_OVERFLOW) in native code | QNN HTP runtime init stack-overflows against the old CDSP transport | Same driver update (above) |
| `dspqueue_read failed: 0x00000072` during generation on `--compute npu` | **Model too large for the HTP** (~2,93 GiB vmem budget) — a memory limit, not a driver bug | Use a smaller model (4B fits at 15.2 tok/s) or a different compute. Matches upstream ggml-org/llama.cpp#26123 |
| `--compute hybrid` server accepts the request but never answers (HTTP 000 after 600 s), unlike NPU which crashes fast | 27B Q3_K_XL straddles the HTP budget: the HTP stages what fits, the CPU portion is so large it never finishes in practical time — neither crashes nor completes | The 27B is CPU-only territory on this machine. Do not use hybrid at all — plain `--compute cpu` beats it on every model (9B: 15.2 vs 7.5 tok/s) |
| `CL_OUT_OF_RESOURCES` / `GGML_ASSERT(0) failed` at `ggml-opencl.cpp` on `--compute gpu` | 27B Q4_0 (16 GB) exceeds the Adreno's allocatable unified memory | Pull a smaller quant; the usable window is ≤ ~13 GB (see quant ladder above) |
| `geniex serve` answers on Windows but not from WSL2 via the LAN IP | Windows Firewall (Ethernet on `Public` profile) blocks inbound | Prefer `127.0.0.1` with mirrored networking; otherwise add an inbound allow rule for TCP 18181 (elevated) |
| `geniex pull` needs a TTY on every invocation | Chipset picker re-triggers when no chipset is stored | Set the chipset once (above) |
| GPU server on port 18182 answers `/v1/models`, but a 13 GB model request hangs with HTTP 000 | The Adreno is thrashing in/out of unified memory — the model loads but generation makes no progress (observed on the 27B Q3_K_XL) | Not practical on this machine. Kill the server (`Stop-Process`) — it holds 14+ GB RSS. Stick to NPU models (2B/4B) or the GPU 9B-Distill |
| Agent feels slow even though `tok/s` looks fine | The GGUF Qwen3/Qwen3.8-Distill models are **reasoning** models — 1600–2000 `<think>` tokens before the answer. Decode rate is fine; token *count* is the cost | Switch to `qualcomm/Qwen3-4B-Instruct-2507:W4A16` (no thinking, 19.5 tok/s) — ~6x faster to a finished answer |
| QAIRT bundle returns nothing on a long prompt, though `--nctx` is large | QAIRT bundles carry a **hard-compiled context** (4096 here). `--nctx` is llama.cpp-only and does not raise it | Keep QAIRT requests under 4096 tokens; use a GGUF lane for long context |
| NPU lane dies mid-session (connection reset, process gone) | A GGUF was requested after a QAIRT bundle on the same lane — reproducible crash | Keep the NPU lane QAIRT-only; serve GGUFs from the CPU lane |
| Model answers with whitespace, punctuation, or random multilingual tokens | The GGUF is **i-quant** based (`IQ3_*`, `IQ2_*`, `IQ1_*`) — broken in this GenieX build, on every model and both lanes. Not a quality issue | Use a non-i-quant file: `Q4_0`, `Q4_K_M`, or a plain `Q3_K_M`. Full analysis: § Debugged: i-quants below 4 bits |
| Every prompt after a short break stalls ~15 s | `--keepalive` default 300 s unloaded the model | Start servers with `--keepalive 86400` (the launcher does) |
| A long prompt never returns; server stops answering `/v1/models` too | Prompt exceeded `--nctx` (default 4096). It does not error, it crawls; and a busy server serves nothing else, because there is no batching | Start with `--nctx 16384`; keep agent context lean (prefill is ~190 tok/s) |
| Second concurrent request waits for the whole first answer | One `geniex serve` has no batching — strictly one request at a time | Run a second lane (`--compute gpu` on 18182). NPU+GPU cost each other ~1–3 % |
| Starting the hybrid lane slowed the NPU lane down | `hybrid` is NPU+CPU and contends for the single HTP (19.25 → 12.84 tok/s) | Run NPU+GPU only, unless you genuinely need a third stream |

## Making room: WSL2 RAM tuning (so the Windows host can fit bigger models)

GenieX runs on the **Windows host**, and WSL2's default config can hoard most of
the machine's RAM as a *guest* memory cap + page cache, starving the host that
actually loads the models. Measured case (2026-08-31): `.wslconfig` capped WSL2
at **30.3 GB of a 31.6 GB host**, leaving ~2 GB free for Windows — the 27B
Q3_K_XL OOM'd on the GPU the moment it was pulled. After tuning, the host had
**~18–21 GB free**.

### 1. Cap WSL2 and return unused memory (`C:\Users\<you>\.wslconfig`)

```ini
[wsl2]
networkingMode=Mirrored
memory=10GB            # pick what the agent inside WSL needs (VS Code server, opencode); NOT the model RAM
autoMemoryReclaim=gradual
swap=4GB
```

`autoMemoryReclaim` (Win11 22H2+) returns WSL's freed page cache to Windows
automatically. Apply with `wsl --shutdown` from a Windows shell, then restart
WSL.

### 2. Clear orphaned containers and services inside WSL

A rootful `containerd.service` can leave orphaned containers running for weeks
(Elasticsearch + Collabora/LibreOffice alone held ~2.5 GB here; both were not
listening on any port). From an **elevated** WSL shell:

```bash
sudo systemctl stop containerd && sudo pkill -9 -f coolwsd; sudo pkill -9 -f elasticsearch; sudo systemctl disable containerd
sudo pkill -9 -f 'clamd|freshclam'; sudo pkill -9 -f '^postgres|/postgres '
```

Check before/after with `free -h` and `ss -tlnp` (nothing of the stopped
services should listen). Keep containers you actually use (e.g. the llm-stack
`glances` monitor).

### 3. Reality check: what the freed RAM did and did not buy

- **Fixed:** the 27B Q3_K_XL (13.1 GB) now *loads* on the Adreno GPU instead of
  `CL_OUT_OF_RESOURCES`.
- **Still not practical:** its generation thrashes memory (2.0 tok/s, 9 s first
  token, server hang under the first real request). Bigger models than the 9B
  are CPU/NPU-only on this class of machine.
- **Where the freed RAM matters most:** headroom for the host's normal workload
  while GenieX serves, and avoiding whole-machine swap storms.

## References

- **GenieX repository**: <https://github.com/qualcomm/GenieX>
- **GenieX docs — local server**: <https://geniex.aihub.qualcomm.com/en/run/cli/local-server>
- **GenieX docs — Linux install**: <https://geniex.aihub.qualcomm.com/en/run/linux/install>
- **GenieX releases (Windows ARM64 installer)**: <https://github.com/qualcomm/GenieX/releases>
- **Models / precisions**: <https://geniex.aihub.qualcomm.com/en/models/supported>
