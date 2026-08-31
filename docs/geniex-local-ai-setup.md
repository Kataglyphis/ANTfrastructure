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
| **Qwen3.8-2B-Distill** (`empero-ai`) | 1.31 GB | ✅ **16.9 tok/s** | ✅ ~16 tok/s | ✅ | ✅ |
| **Qwen3-4B** (`unsloth`) | 2.2 GB | ✅ **15.2 tok/s** | ✅ 14.1 tok/s | ✅ 13.2 tok/s | ✅ slow |
| **Qwen3.8-9B-Distill** (`empero-ai`) | 5.78 GB | ❌ over HTP budget | ✅ **7.5 tok/s** (20.9 s round-trip incl. load) | ✅ 6.5 tok/s | ✅ |
| **Qwen3.8-27B** Q4_0 (`unsloth`) | 16.1 GB | ❌ | ❌ crashes (`dspqueue_read failed: 0x00000072`) | ❌ OOM | ✅ slow |
| **Qwen3.8-27B** Q3_K_XL | 13.1 GB | ❌ | ❌ **no crash, but unusable** — server never answers within 600 s | ⚠️ loads, then thrashes (2.0 tok/s) | ✅ slow |

**Hybrid wins for models that straddle the HTP budget.** The 9B distill does
not fit the ~3 GB (2,93 GiB) HTP alone, but `--compute hybrid` offloads the
layers that fit and runs the rest on CPU — landing **7.5 tok/s, faster than
the GPU's 6.5 tok/s** on the same model. For models that fully fit (2B, 4B),
hybrid adds CPU hand-off overhead, so pure NPU is faster (16.9 / 15.2 vs
~14–16). Re-verified after the WSL2 RAM tuning: the freed host RAM did **not**
change the hybrid/NPU numbers, because the HTP limit is on-die vmem, not host
RAM.

**Nothing combines GPU+NPU on one model.** `hybrid` = NPU + CPU only. The 27B
Q4_0 crashes on both NPU and hybrid (the single HTP cannot even stage a
fraction); the 27B Q3_K_XL does not crash but neither completes a request in
a practical time on hybrid or GPU — for 27B, CPU is the only reliable path.

**Best Qwen3.8-class GGUF for hybrid: `Qwen3.8-9B-Distill` Q4_K_M** — the
largest that runs *and* responds in ~21 s round-trip; pure NPU can't hold it,
the GPU is slower, the 27B doesn't deliver in any accelerated mode.

**But the best model overall on this machine is not a GGUF at all.** The QAIRT
bundle `qualcomm/Qwen3-4B-Instruct-2507:W4A16` beats every row of this table
end-to-end (19.5 tok/s and no `<think>` tax — ~6x faster to a finished answer
than the 4B GGUF). See § Getting the most out of this machine.

### Measured compute envelope (Lenovo Snapdragon X, 2026-08-31, AFTER NPU driver update)

All speeds are token/s on short replies; first-token latency in parentheses.

| Compute | 2B-Distill Q4_K_M | 4B Q4_0 | 9B-Distill Q4_K_M | 27B Q4_0 | 27B Q3_K_XL |
|---|---|---|---|---|---|
| **NPU** (Hexagon HTP) | **16.9** (0.2 s) | **15.2** (0.2 s) | ❌ over HTP budget | ❌ `dspqueue_read failed: 0x00000072` | ❌ over HTP budget |
| **hybrid** (HTP + CPU) | ~16 | 14.1 (2.6 s) | **7.5** (3.1 s) | ❌ crashes | ❌ no answer in 600 s |
| **GPU** (Adreno X1-45) | ~13 | 13.2 | 6.5 (0.6 s) | ❌ OOM (Q4_0) | ⚠️ 2.0 tok/s, thrashes |
| **CPU** (WSL2) | ~8–10* | ~5* | ~2–3* | ~1 (224 s incl. load) | ~1* |

\* CPU token/s for 2B/4B/9B/27B-Q3_K_XL are estimates scaled from the measured
27B Q4_0 CPU time (224 s for a short reply incl. model load). NPU/GPU/hybrid
numbers are all measured.

**The HTP vmem limit — what it is and why RAM tuning did not change it:**

The Hexagon HTP is a separate on-die DSP block, not the host CPU/RAM. Each HTP
session gets a **virtual-memory budget of 2,93 GiB** (`3145728000` bytes,
printed at load: `vmem 3145728000`) for weights + activations + KV cache.
Model graphs above that limit fail at compute with
`dspqueue_read failed: 0x00000072`; `hybrid` can only offload the layers that
fit inside that budget and runs the rest on CPU. That is why freeing ~20 GB of
host RAM changed nothing for NPU/hybrid — the ceiling is on-die, not host
memory. (It did matter for the GPU path, see § Making room.)

**The 27B quant ladder (what fits the Adreno's unified memory)**

The GPU OOMs at 16.1 GB (Q4_0) but loads 12.0 GB (IQ3_S). The usable window is
roughly **≤ 13 GB**. From `unsloth/Qwen3.8-27B-GGUF`:

| Quant | File size | On this GPU |
|---|---|---|
| `Q4_0` | 16.1 GB | ❌ OOM |
| `IQ4_XS` | 14.3 GB | ❌ likely OOM |
| `Q3_K_XL` | 13.1 GB | ⚠️ borderline — test |
| `IQ3_S` | 12.0 GB | ✅ loads, but 3-bit quality degrades badly (whitespace/garbage output) |

If you must run a 27B on this exact machine, `Q3_K_XL` is the last quant worth
trying above 12 GB; below that the quality loss makes the model unusable for
coding. The realistic on-device choice here is the 4B on the NPU.

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

### 2. Run NPU + GPU lanes — they compose almost perfectly

One server = one request at a time. Throughput scales only by adding servers,
and *which* servers you add matters:

| Topology | NPU | GPU | hybrid | aggregate |
|---|---|---|---|---|
| NPU alone | 19.5 | — | — | 19.5 tok/s |
| GPU alone | — | 12.5 | — | 12.5 tok/s |
| **NPU + GPU** | **19.25** | **12.11** | — | **31.4 tok/s** |
| NPU + GPU + hybrid | 12.84 | 11.16 | 10.12 | 34.1 tok/s |
| NPU + hybrid | 13.89 | — | 15.65 | 29.5 tok/s |

**NPU + GPU is the sweet spot.** The Hexagon HTP and the Adreno are separate
silicon, so the two lanes cost each other ~1–3 % (19.5 → 19.25, 12.5 → 12.11).
Adding `hybrid` buys +2.7 tok/s aggregate but **costs the NPU lane a third of
its speed** (19.25 → 12.84), because `hybrid` is NPU+CPU and contends for the
same single HTP. Run two lanes by default; add the third only when you really
have three concurrent streams and care about total tokens, not per-answer
latency.

This does *not* make one answer faster — nothing here splits a single model
across GPU and NPU. It makes *n* concurrent agents faster.

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
| `--compute hybrid` server accepts the request but never answers (HTTP 000 after 600 s), unlike NPU which crashes fast | 27B Q3_K_XL straddles the HTP budget: the HTP stages what fits, the CPU portion is so large it never finishes in practical time — neither crashes nor completes | The 27B is CPU-only territory on this machine. Use the 9B-Distill for hybrid (7.5 tok/s) instead |
| `CL_OUT_OF_RESOURCES` / `GGML_ASSERT(0) failed` at `ggml-opencl.cpp` on `--compute gpu` | 27B Q4_0 (16 GB) exceeds the Adreno's allocatable unified memory | Pull a smaller quant; the usable window is ≤ ~13 GB (see quant ladder above) |
| `geniex serve` answers on Windows but not from WSL2 via the LAN IP | Windows Firewall (Ethernet on `Public` profile) blocks inbound | Prefer `127.0.0.1` with mirrored networking; otherwise add an inbound allow rule for TCP 18181 (elevated) |
| `geniex pull` needs a TTY on every invocation | Chipset picker re-triggers when no chipset is stored | Set the chipset once (above) |
| GPU server on port 18182 answers `/v1/models`, but a 13 GB model request hangs with HTTP 000 | The Adreno is thrashing in/out of unified memory — the model loads but generation makes no progress (observed on the 27B Q3_K_XL) | Not practical on this machine. Kill the server (`Stop-Process`) — it holds 14+ GB RSS. Stick to NPU models (2B/4B) or the GPU 9B-Distill |
| Agent feels slow even though `tok/s` looks fine | The GGUF Qwen3/Qwen3.8-Distill models are **reasoning** models — 1600–2000 `<think>` tokens before the answer. Decode rate is fine; token *count* is the cost | Switch to `qualcomm/Qwen3-4B-Instruct-2507:W4A16` (no thinking, 19.5 tok/s) — ~6x faster to a finished answer |
| QAIRT bundle returns nothing on a long prompt, though `--nctx` is large | QAIRT bundles carry a **hard-compiled context** (4096 here). `--nctx` is llama.cpp-only and does not raise it | Keep QAIRT requests under 4096 tokens; use a GGUF lane for long context |
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
