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

> **Version matters more than usual on this page.** Every measurement dated
> 2026-08-31 to 2026-09-04 was taken on **GenieX v0.5.0** (llama.cpp
> `873e5d8`). The host now runs **v0.6.1** (llama.cpp `0eadefe`), and four of
> the constraints those measurements were built around are gone: the 2048-token
> output cap, `max_tokens` being ignored, the missing tool-call parsing, and the
> missing prefix cache. **§ 1n lists what changed and what did not** — read it
> before trusting a number below.

| You want | Use | Speed |
|---|---|---|
| **The fastest finished answer** (chat and completion) | `--compute npu` + `qualcomm/Qwen3-4B-Instruct-2507:W4A16` | 19.5 tok/s, **26.8 s to a full answer**, 1.65 cores. Also **3/3 on the executed-code benchmark, 4.3x faster than any other model that scored 3/3** (§ 1d). **Not for agents** — opencode's preamble is 2x its 4096 context (§ 1m) |
| **Driving a real coding agent** (opencode) | CPU lane + `Qwen3.8-9B-Distill:Q4_K_M`, tool set trimmed to four | **3/3 end-to-end tasks, verified by the repo's own tests**, ~3.5 min each on GenieX v0.6.1 (was 10-14 min on v0.5.0, which also needed `geniex_toolcall_shim.py` — § 1m, § 1n) |
| The fastest GGUF, machine to yourself | `--compute cpu` + any GGUF | 2B 46.5 · 4B 23.7 · 9B 15.2 tok/s, but **7.5 of 8 cores** |
| Max total throughput, n parallel agents | NPU + CPU lanes (add GPU for a third) | **39.7 tok/s** (45.4 with all three) |
| Long context (> 4096) | any GGUF lane with `--nctx 16384` | QAIRT bundles are hard-capped at 4096 |
| **Best quality on-device**, willing to wait | `--compute cpu` + `unsloth/Qwen3.8-27B-GGUF:Q4_0` | 5.6 tok/s, correct output, 16 GB RAM |
| Nothing | `--compute hybrid` | Slower than CPU on every model, and it damages a concurrent NPU lane |

**Four counter-intuitive results worth knowing before you tune anything:**

1. **The CPU beats the Hexagon NPU ~2x on GGUF models** (4B: 23.7 vs 11.9).
   llama.cpp's ARM kernels are mature; the `ggml-hexagon` backend is not. The
   NPU's value is QAIRT bundles and its tiny CPU footprint, not raw speed.
2. **tok/s is the wrong metric.** `Qwen3-1.7B` is the fastest model here at
   31.7 tok/s and the *slowest* to a finished answer (60.8 s), because it is a
   reasoning model that spends ~1900 tokens thinking. Measure time-to-answer.
3. **Prefill, not decode, is what an agent waits on.** A 2.5k-token prompt costs
   13.1 s before the first token; opencode's real 8,175-token preamble costs
   **135 s** on the fastest lane. Context discipline beats every other tuning
   knob here.
4. **The prefix cache is what makes agents viable — and it arrived in v0.6.**
   On v0.5.0 the identical request twice cost the same both times (126 s, then
   122 s): every agent turn re-prefilled the whole conversation, and that — not
   tok/s, not model quality — was the limit (§ 1m). On v0.6.1 the same repeat
   costs 0.1 s and appending ~800 tokens costs 0.9 s (§ 1n).

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

### Updating an existing install (from WSL2, unattended)

The CLI checks for updates on every invocation and prints the offer; `geniex
update` downloads the right installer for the host. It does **not** finish the
job on its own, and the two ways it surprises you are both silent:

```bash
GX="$env:LOCALAPPDATA\GenieX CLI\geniex.exe"

# 1. Stop every server first. Windows keeps a running .exe locked, and the
#    installer will not replace a file that is in use.
powershell.exe -NoProfile -Command "Get-Process geniex -EA SilentlyContinue | Stop-Process -Force"

# 2. Download. This leaves an installer in %TEMP% and LAUNCHES ITS GUI, which
#    then waits for a click nobody will give it in an automated run.
powershell.exe -NoProfile -Command "& \"$GX\" update"

# 3. Close that GUI and run the installer silently instead. It is Inno Setup.
powershell.exe -NoProfile -Command "Get-Process 'geniex-cli-setup*' -EA SilentlyContinue | Stop-Process -Force"
powershell.exe -NoProfile -Command \
  "Start-Process \"\$env:TEMP\geniex-cli-setup-windows-arm64-vX.Y.Z.exe\" \
   -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CLOSEAPPLICATIONS' -Wait"

# 4. VERIFY. `update` reporting success is not evidence that anything changed.
powershell.exe -NoProfile -Command "& \"$GX\" --version"
```

`--version` prints three lines, and all three matter — the CLI version, the
QAIRT runtime, and the **llama.cpp runtime hash**, which is what actually
decides GGUF behaviour:

```text
GenieX CLI Version:     v0.6.1
QAIRT Runtime Version:  2.45
LlamaCPP Runtime Hash:  0eadefe
```

Then **restart the lanes** (`windows/scripts/host/start-geniex-servers.ps1`)
and **re-check the assumptions your tooling encodes.** A minor release changed
four of them here (§ 1n): the output cap, `max_tokens`, tool-call parsing and
the prefix cache. The model cache in `%USERPROFILE%\.cache\geniex\models`
survives the update untouched — take `geniex list` before and after if you want
that in writing.

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
        // CHAT AND COMPLETION ONLY. opencode's own preamble is 8,175 tokens
        // (§ 1m), so agent runs on this lane fail before the model reads the
        // task. For agent work select the GGUF lane below.
        "qualcomm/Qwen3-4B-Instruct-2507:W4A16": {
          "name": "Qwen3 4B Instruct W4A16 (NPU) — chat/completion",
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
        // GGUF lane: --nctx applies here, so the context can be raised.
        // This is the lane to select for agent work — it is the only kind that
        // fits opencode's 8,175-token preamble (§ 1m).
        "unsloth/Qwen3-4B-GGUF:Q4_0": {
          "name": "Qwen3 4B (GPU lane) — agent work",
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
| Selecting the QAIRT model for **agent** use | Fails every task before the model reads it — opencode's preamble alone is 2x the whole context (§ 1m) |

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
lane, not the speed — and for agent use it is not a budget at all but a wall:
opencode's system prompt plus its ten tool schemas measure **8,175 tokens**, two
times the entire context, before your task is read (§ 1m). Use this lane for
chat and completion; run agents on a GGUF lane (`--nctx 16384`) or off-box.

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

**A hard 2048-token output cap decides more than model quality here.**
*(v0.5.0 only — gone in v0.6.x, § 1n. It shaped every number in this section,
which is why they are labelled with the version.)* GenieX v0.5.0 stopped
generating at 2048 tokens and ignored `max_tokens` entirely
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

> **Read the `cut` column against the rate (2026-09-04 audit).** These rates
> counted a cut attempt as a miss: the Q4_0 row is 4 passes, 0 wrong and 5
> cuts, which is 4/4 *measured* attempts, not 4/9. The tool now excludes cut
> attempts from the rate, the interval and the rank — they are listed, not
> scored — so a re-run prints this row as 4/4 with 5 cut. The table is left as
> published; the `wrong` column already told the truth.

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

**Correction (2026-08-31, second pass): the 3/3 was partly recall.** Those three
tasks are textbook problems. Re-run against a `novel` task set built from
formats invented in this repository — every rule stated in the prompt, so the
combination cannot have been memorised — the same model scores **2/3**. The
classic set overstates it.

**Two measurement errors in the numbers above, both since fixed:**

- **No warm-up.** The first task of each model carried its load time; ~34 s of
  the 27B's 128.7 s total was loading, **26 %** of the number that decided its
  rank. `bench_coding.py` and `bench_tools.py` now warm up by default.
- **A stated constraint was unenforced.** The merge task says "do not use
  `sorted()`" and nothing checked — `return sorted(a + b)` passed every
  assertion. Tasks now declare `forbidden` tokens.

**And the sample is smaller than the scores suggest.** On the QAIRT path every
repeat returns the identical answer, so "9/9" was 3 tasks counted three times,
not 9 independent observations. At that size the 95 % interval for 12/12 is
[75.7 %, 100 %] and for 8/12 is [39.1 %, 86.2 %] — they overlap, so the
tool-calling improvement is **not statistically significant on its own**. It is
believable because the two failure modes were identified and fixed
deterministically, which is stronger evidence than the count. The tools now
report `effective_n` rather than letting repeats inflate it.

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
is capped at **4096 tokens** (§ 1m), which an agent's system prompt plus one
medium file can exhaust -- in fact opencode's preamble alone is twice it. For code that must see a lot of repository at once,
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

### 1g. The full sweep — six models, every tool (measured 2026-08-31)

All six cached models through the complete suite: the verifiable-answer health
probe, 27 tool-calling cases, and 6 coding tasks (classic *and* novel).
Sequential by design — the lanes serve one request at a time and concurrent
lanes measurably slow each other, so fanning this out would corrupt every
timing it produced. 1 h 25 min.

| Model | Health | Tool calling | s | Coding | cut | s |
|---|---|---|---|---|---|---|
| **QAIRT 4B-Instruct** (NPU) | **6/6** | 25/27 = 93 % [77–98] | **79** | 5/6 = 83 % | 0 | **60** |
| QAIRT 1.7B (NPU) | 5/6 | 26/27 = 96 % [82–99] | 103 | 2/6 = 33 % | 4 | 353 |
| GGUF Qwen3-4B `Q4_0` (CPU) | **6/6** | **27/27 = 100 %** [88–100] | 432 | 2/6 = 33 % | 4 | 493 |
| GGUF Qwen3.8-2B (CPU) | 4/6 | 8/27 = 30 % [16–48] | 190 | 2/6 = 33 % | 0 | 66 |
| GGUF Qwen3.8-9B (CPU) | **6/6** | 9/27 = 33 % [19–52] | 602 | 5/6 = 83 % | 1 | 536 |
| GGUF Qwen3.8-27B (CPU) | 5/6 | 9/27 = 33 % [19–52] | 1466 | **6/6 = 100 %** | 0 | 226 |

**The sharpest structure in the data is the model FAMILY, not the size.**

| Family | Models | Tool calling |
|---|---|---|
| **Qwen3** | 1.7B, 4B-Instruct, 4B `Q4_0` | 25–27 / 27 |
| **Qwen3.8** | 2B, 9B, 27B | 8–9 / 27 |

Every Qwen3 model is strong and every Qwen3.8 model is weak, across 1.7 B to
27 B, across quantisations, across lanes and across two different publishers.
Nothing in the size ordering predicts it. The two groups' intervals do **not**
overlap ([77–100 %] vs [16–52 %]), so unlike most comparisons at this sample
size, this one is statistically separable — and it is the finding that matters:
**the Qwen3.8 family is unsuitable for agent use on this machine no matter how
well it codes.**

**Coding ability and tool calling are orthogonal.** The 27B is the best coder
in the field (6/6, the only perfect score) and among the worst tool callers
(9/27). The 1.7B is the inverse (26/27 tools, 2/6 coding — four tasks lost to
the 2048-token cap). A single headline metric would have picked the wrong model
either way; measuring both is what separates them.

**No model wins both, and the recommendation survives.** The QAIRT 4B-Instruct
is the only workable compromise: 93 % on tools *and* 83 % on coding, at **5.5x
less time than** the perfect-scoring GGUF 4B and **18x less** than the 27B. Its
25/27 and the GGUF 4B's 27/27 have overlapping intervals, so that gap is not
demonstrable; the time difference is not in doubt.

**What this sweep cannot support.** Six coding tasks carry almost nothing:
6/6 is [61–100 %] and 5/6 is [44–97 %], both overlapping even with 2/6. The
coding column separates nobody. The tool-calling column does, because it has 27
cases — which is exactly why the case count was raised.

### 1j. Qwen3-8B: the one model that could have changed the answer (measured 2026-09-04)

The winner's direct competitor on the NPU lane — same QAIRT path, same fast
prefill, twice the parameters. It does not change the recommendation, on any
axis.

| | QAIRT 4B-Instruct | QAIRT 8B |
|---|---|---|
| health probe | 6/6 | 6/6 |
| **tool calling** | **25/27 in 79 s** | 25/27 in **588 s** |
| context ceiling | 4096 | **4096** |
| **coding** | **17/27** in 631 s | **1/27** in 4971 s |

**Identical tool-calling score for 7.5x the time**, and no extra context: the
4096-token ceiling that § 1e identifies as the binding constraint for agent use
is the same on both, so the larger model buys capacity per token and no room to
use it.

**The coding result needs stating carefully.** 1/27 is not "the 8B cannot
code" — it produced **zero wrong answers**. All 26 failures are the 2048-token
output cap:

| | min | median | max |
|---|---|---|---|
| 4B tokens per task | 75 | **181** | 2048 |
| 8B tokens per task | **1636** | 2048 | 2048 |

The 8B's *shortest* answer was eight times the 4B's median, and its thinking
share is **0 %** — it is not deliberating, it simply does not stop. So its
coding ability here is **unmeasured**, while its usability on this server is
settled: it cannot deliver a complete function through a 2048-token cap.

This is the clearest case yet for reporting `CUT` apart from `FAIL`. Scored as
failures, 1/27 would read as a catastrophically bad model. What it actually
shows is a model whose output length is incompatible with this runtime — a
server limitation meeting a model habit, and a different problem entirely.

### 1k. Does a code-specialised model win? (measured 2026-09-04)

`Qwen2.5-Coder-7B-Instruct` `Q4_K_M` on the CPU lane, against the incumbent.

| | QAIRT 4B-Instruct (NPU) | Qwen2.5-Coder-7B (CPU) |
|---|---|---|
| health | 6/6 | 6/6 |
| **coding** | **17/27 = 63 % [44–78]** | **17/27 = 63 % [44–78]** |
| coding time | 631 s | **245 s** |
| tasks cut by the cap | 2 | **0** |
| mean tokens per task | 401 | **119** |
| **tool calling** | **25/27 in 79 s** | 27/27 in **378 s** |
| CPU cost | 1.65 of 8 cores | **7.5 of 8 cores** |

**Specialisation bought brevity, not correctness.** Identical scores, identical
intervals — and they fail *different* tasks: three each that the other solves.
That is the signature of two comparable models, not of one being better.

What the specialist does buy is **terseness**: 119 tokens per task against 401.
On this server that is worth real money, because it is the 2048-token cap that
distorts every coding number here — the Coder lost **nothing** to it while the
incumbent lost two tasks and Qwen3-8B lost twenty-six (§ 1j). Brevity is the
property that survives this runtime.

It also bears on the family question from § 1g — see § 1l, which **corrects**
the conclusion drawn there. Qwen2.5 scores 27/27, landing with Qwen3; but the
reason is not what "family" suggests.

**It does not displace the recommendation, and the reason is the agent loop.**
Its 27/27 over 25/27 is not separable, and it pays **4.8x the tool-call latency**
— the cost an agent pays on *every turn* — while occupying 7.5 of 8 cores
against the NPU lane's 1.65. For a coding agent the incumbent stays. For batch
code generation where latency does not matter and the output cap does, the
Coder is the better choice, and that is a real second use.

### 1i. The coding score at 27 tasks — and what six tasks were hiding

The six-task set said the QAIRT 4B-Instruct scored **5/6 = 83 % [44–97 %]**.
The 27-task set says **17/27 = 63 % [44–78 %]**. The small set both
*overstated* the model and carried an interval so wide it excluded almost
nothing — it could not have distinguished this model from one at 45 %.

| | tasks | score | 95 % interval |
|---|---|---|---|
| old set | 6 | 5/6 = 83 % | [44–97 %] |
| **`--task-set all`** (novel + extended + classic) | **27** | **17/27 = 63 %** | **[44–78 %]** |

**Partial credit changes what the failures mean.** Of the eight genuine
failures (two more were server truncations), **six are near-misses**:

| Task | assertions |
|---|---|
| `validation_parse_kv_pairs` | 20/21 |
| `validation_parse_range_spec` | 20/25 |
| `stateful_run_machine` | 16/18 |
| `lists_merge_pairs_longest_value_wins` | 12/14 |
| `strings_normalize_tag` | 11/12 |
| `strings_dominant_case` | 11/12 |
| `rank_quants` | 2/6 |
| `parsing_item_list` | no code produced |

So the model is not *incompetent* at these tasks — it is **mostly right and
loses edge cases**, which is a different engineering problem from "cannot do
it" and suggests different mitigations (a stricter prompt, a review pass)
rather than a different model. Pass/fail alone showed eight identical
failures and could not have told you that.

Two tasks still hit the 2048-token output cap. That cap remains the single
biggest distortion in every coding number on this page.

**A caveat on the fractions above (2026-09-04 audit).** The assertion
denominators counted setup lines and helper definitions in the hidden tests as
if they were assertions; nine of the 21 extended tasks carry such lines. The
harness now counts only statements that assert, so a re-run will report
slightly smaller denominators for those rows (e.g. 20/21 becomes 19/20). The
PASS/FAIL verdicts, the 17/27 and the interval are unaffected — those never
used the denominator. The table is left as measured rather than re-derived by
hand.

### 1h. The lane knobs, finally swept (measured 2026-09-01)

Two flags had been carried since the first day without ever being varied.

**`--nctx` costs nothing.** The suspicion was that a larger window allocates a
larger KV cache and so costs decode speed even on short prompts — which would
mean the 16384 this repo standardised on is paid for on every request. It is
not:

| `--nctx` | decode |
|---|---|
| 2048 | 10.5 tok/s (cold) |
| 4096 | 12.6 tok/s |
| 16384 | **12.9 tok/s** |

No cost, and the low first row is a cold-start artefact. Keep 16384.

**`--ngl` matters enormously, and its default is the worst setting.** On the
GPU lane, layers offloaded to the Adreno make it *slower*, monotonically:

| `--ngl` | TTFT | decode |
|---|---|---|
| `-1` (all layers — the default) | 6.5 s | 12.98 tok/s |
| `24` | 5.2 s | 14.40 tok/s |
| `12` | 4.2 s | 17.49 tok/s |
| **`0` (nothing on the GPU)** | **2.5 s** | **26.36 tok/s** |

**The GPU lane is at its fastest when it does not use the GPU** — `--ngl 0`
runs the model entirely on the CPU and lands at 26.4 tok/s, twice the default
and in line with the CPU lane's own 23.7. This is the § 1b finding (the CPU
beats the Adreno on GGUF) in its sharpest form: not only is the GPU the slower
unit, every layer you give it costs you.

Practical consequence: **there is no reason to run `--compute gpu` with the
default `--ngl` on this machine.** Either run the CPU lane directly, or — if
you want a second concurrent lane whose CPU footprint is small — accept that
the GPU lane trades throughput for staying out of the CPU's way, and say so
rather than believing it is an accelerator here.

### 1l. CORRECTION: it was never about the model family (measured 2026-09-04)

§ 1g reported that every Qwen3 model scores 25–27/27 on tool calling while
every Qwen3.8 model scores 8–9/27, and called Qwen3.8 an outlier. **The
observation held; the explanation was wrong.**

The first non-Qwen models on this host settle it. Llama-3.2-3B and
Phi-4-mini-instruct were pulled specifically because every model measured until
then was a Qwen, and a finding about "families" cannot be checked inside one
vendor:

| Model | Vendor | Tool calling |
|---|---|---|
| Qwen2.5-Coder-7B | Alibaba | 27/27 |
| Qwen3 1.7B / 4B / 4B-GGUF / 8B | Alibaba | 25–27/27 |
| Qwen3.8-2B | Alibaba | 7/27 |
| **Phi-4-mini-instruct** | **Microsoft** | **7/27** |
| **Llama-3.2-3B-Instruct** | **Meta** | **3/27** |

All three fail the same way *as far as the score is concerned* — no native
`tool_calls`, 18 of 21 single-turn failures each — so a score-only benchmark
files them under one heading. Reading the actual replies shows **three
different formats**:

| Model | What it emits instead |
|---|---|
| Llama-3.2-3B | `{"name": "read_file", "parameters": {"path": "README.md"}}` — valid JSON |
| **Qwen3.8-2B** | `<tool_call><function=read_file><parameter=path>…` — **Qwen's own canonical template** |
| Phi-4-mini | `file: read-file, path: README.md` — invented syntax, and the tool **renamed** |

None of this is a reasoning failure. It is whether the model's chat template
emits native tool calls under this runtime — and in Qwen3.8's case the model did
exactly what its own template prescribes; the runtime simply did not convert it.

**What this changes.** The practical consequence is unchanged — a model that
answers in prose is unusable in opencode, which reads `tool_calls`. But the
*remedy* is completely different from what a "bad family" conclusion implies:

- **Wrong remedy** (what § 1g implied): pick a different model family.
- **Partial remedy**: an agent-side fallback that parses a call out of the
  message content. `bench_tools.py --accept-text-json` implements one for both
  the JSON and the Qwen-template shapes, and **measures** what it is worth —
  because the first estimate written here ("three of five would go to
  near-perfect") was itself wrong, and measuring it was the only way to find
  that out:

| Model | without fallback | with fallback | recovered |
|---|---|---|---|
| Llama-3.2-3B | 3/27 | **18/27** | 16 cases |
| Qwen3.8-2B | 7/27 | 10/27 | 3 cases |
| Phi-4-mini | 7/27 | 7/27 | **none** |

  So the fallback is decisive for one model, marginal for a second, and useless
  for the third. Llama emits one consistent JSON shape, so almost everything is
  recoverable. Qwen3.8's output *varies* — 13 replies still yield nothing
  parseable — so the template hypothesis explains part of its failure and not
  most of it. Phi renames the tool (`read-file` for `read_file`) inside a syntax
  it invented, which no fallback should paper over: recovering that would mean
  guessing which tool the model meant.

  What survives the fallback is genuine: over-eager calling, wrong tool choice,
  and arguments typed as strings (`"true"` for `true`).

**On coding they are simply weaker**, and that part *is* about the models:

| Model | Coding | wrong | cut | time |
|---|---|---|---|---|
| QAIRT 4B-Instruct | **17/27 = 63 % [44–78]** | 8 | 2 | 631 s |
| Qwen2.5-Coder-7B | **17/27 = 63 % [44–78]** | 10 | 0 | 245 s |
| Phi-4-mini | 12/27 = 44 % [28–63] | 15 | 0 | 181 s |
| Llama-3.2-3B | 11/27 = 41 % [25–59] | 16 | 0 | 265 s |

The intervals still overlap — at 27 tasks a 63 % and a 41 % model are not
cleanly separable — but the ordering is consistent, and unlike the tool-calling
column these failures are genuine wrong answers rather than a channel problem.
Neither is a 3B, so nothing here says a small model cannot code; it says these
two, at this size, are behind.

**The methodological point is the sharper one.** A benchmark that reports only a
score would have produced "Qwen3.8, Llama and Phi are bad at tools" — a
plausible, actionable-looking and wrong conclusion. Recording *why* each case
failed turned three separate model verdicts into one runtime observation. The
family table in § 1g was a real pattern in the data and a false explanation of
it, and it took a model from outside the family to see that.

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

### 1m. The end-to-end agent run — the constraint every proxy missed (measured 2026-09-04)

Everything above this line measures an **endpoint**: a prompt goes in, tokens
come out, a grader scores them. You do not run an endpoint, you run an **agent**
— and the two had never been connected. `linux/llm-stack/bench_agent.py`
connects them: a scratch git repository, a task with a verifiable outcome, and
success defined as *the repository's tests pass afterwards*. Not the transcript.
An agent that says it fixed the bug and did not is exactly the failure a
transcript cannot catch.

Connecting them overturned this page's recommendation for agent use, and the
reason is not the models. **Every prompt in every benchmark above was short.**
The real one is not.

#### opencode's fixed preamble is 8,175 tokens, before your task is read

Captured off the wire with a logging proxy between opencode and the lane, so
these are the real bytes rather than an estimate:

| Part | Characters | ~Tokens |
|---|---:|---:|
| System prompt | 11,556 | 2,889 |
| 10 tool schemas | 21,144 | 5,286 |
| — `bash` alone | 5,310 | 1,328 |
| **Total, for a one-word user message** | **32,702** | **8,175** |

#### Consequence 1 — the QAIRT lane cannot run an agent at all

The QAIRT bundle has **4096 tokens compiled in**, shared between input and
output. The preamble is **2.0x that budget**. The result is not a low score, it
is no score:

| Lane / model | Tasks | Outcome |
|---|---|---|
| NPU, `qualcomm/Qwen3-4B-Instruct-2507:W4A16` | 3 | **0 reached the model.** `SDKError(Input prompt too long)`, **0 tool calls**, every task |

**No configuration rescues it** — arithmetic, not opinion:

| Trim | Preamble | Fits in 4096? |
|---|---:|---|
| All 10 tools (as shipped) | 8,170 | no — 2.0x over |
| Only 6 core tools (`bash read edit write grep glob`) | 6,008 | no — 1.5x over |
| **Zero tools** — system prompt alone | 2,889 | leaves **1,207 tokens** for the conversation *and* the answer |

An agent that cannot be given tools is not an agent. `--nctx` does not help: it
is a llama.cpp flag, and a QAIRT bundle ignores it.

#### Consequence 2 — the GGUF lanes fit, and are prefill-bound

Replaying that exact captured request:

| Lane | Model | TTFT | Prefill |
|---|---|---:|---:|
| GPU (Adreno) | `unsloth/Qwen3-4B-GGUF:Q4_0` | **213.0 s** | 38 tok/s |
| CPU (8x Oryon) | `empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M` | **134.8 s** | 61 tok/s |

That is time to the *first token* of the *first* turn. The GPU lane duly timed
out on the agent benchmark at a 600 s ceiling without finishing one task.

#### Consequence 3 — there was no prefix cache, so every turn paid it again

> **Fixed in v0.6.x — see § 1n.** This section describes v0.5.0. It is kept
> because it explains why the v0.5.0 agent numbers look the way they do, and
> because it is the measurement that was decisive at the time.

The measurement that decides whether any of this is viable. Same lane, same
model, three requests:

| Request | TTFT (v0.5.0) |
|---|---:|
| The preamble, cold | 126.2 s |
| **The identical request again** | **122.1 s** |
| Same prefix, ~500 tokens appended (a realistic turn 2) | 129.1 s |

A cache would have made the second request near-instant and the third cost only
its increment. Instead all three cost the same: **GenieX v0.5.0 re-prefilled the
whole conversation on every turn.** An agent loop therefore cost **~2 minutes
per turn** on the best lane before a single token of output, and a five-turn bug
fix was ten minutes of prefill alone.

#### Two levers: prompt size, and model size within one quant format

**Prompt size.** opencode honours a top-level `tools` block, so the schemas it
never needs for a coding task can simply be dropped — and every dropped schema
is paid back on *every* turn, because nothing is cached:

| Tool set | Preamble | Saved |
|---|---:|---:|
| All 10, as shipped | 8,175 | — |
| Minus `task`, `webfetch`, `todowrite`, `skill` | 5,822 | 29% |
| Also minus `grep`, `glob` (flat repo, not needed) | **5,234** | **36%** |

```jsonc
// ~/.config/opencode/opencode.jsonc — top level, beside "provider"
"tools": { "task": false, "webfetch": false, "todowrite": false,
           "skill": false, "grep": false, "glob": false },
```

**Model size — but only compared within one quantization format.** An earlier
draft of this section said shrinking the model does not help, on the strength of
a 4B that prefilled slower than a 9B. That was wrong, and the confound was
already flagged in the sentence that stated it: the 4B was `Q4_0` and the 9B
`Q4_K_M`. Comparing like with like on the same lane and the same 5,234-token
request:

| Model (all CPU lane) | Format | Prefill | TTFT |
|---|---|---:|---:|
| `Qwen3.8-2B-Distill` | Q4_K_M | **214 tok/s** | **24.5 s** |
| `Qwen3.8-9B-Distill` | Q4_K_M | 61 tok/s | 85.2 s |
| `Qwen3-4B` | Q4_0 | 50 tok/s | (8,175 tok: 163.9 s) |

Within `Q4_K_M`, the 2B prefills **3.5x** faster than the 9B. The 4B is the
outlier because of its format, not its size — `Q4_0` costs more per token here
than `Q4_K_M` does on a model more than twice as large. So: pick the smallest
model that can do the task, and do not compare prefill across quant formats.

#### The lane drops the tool call on the floor — and that looked like a weak model

Three GGUF models scored **zero tool calls** on the agent benchmark. That reads
as "these models cannot use tools". It is not what is happening. Asked to fix a
failing test, `Qwen3.8-9B-Distill` answers:

```text
I need to first run the test suite to see what's failing, then examine
the source code to find the bug.
</think>

<tool_call>
<function=bash>
<parameter=command>
cd /tmp/... && python -m pytest test_calc.py -v 2>&1
</parameter>
</function>
</tool_call>
```

That is a correct tool call in Qwen's chat template. GenieX returns it as
`content`, with `tool_calls` empty and `finish_reason` `"stop"` — it serves the
OpenAI API without parsing the model's template. Every OpenAI-compatible agent
therefore sees prose, executes nothing, and ends the turn.

**So the benchmark's "0 tool calls" was measuring the server, not the model.**
Worth stating plainly, because the same number would be produced by a genuinely
incapable model, and this suite spent a whole session learning to tell those two
apart.

The 2B is the control that keeps the finding honest: on the identical prompt it
emits markdown fences (` ```bash\nls -la\n``` `) and no template at all. It
really cannot do function calling. Both look like "0 tool calls" from outside.

| Model | What it actually emits | Recoverable? |
|---|---|---|
| `Qwen3.8-9B-Distill` Q4_K_M | `<tool_call><function=…>` template | **yes** |
| `Qwen3.8-2B-Distill` Q4_K_M | markdown code fences | no — it is not a call |

**`linux/llm-stack/geniex_toolcall_shim.py` does the translation** the server
does not: it sits between the agent and the lane, parses the template into
proper `tool_calls`, and sets `finish_reason` to `"tool_calls"` so the agent
loop continues instead of stopping.

```bash
python3 linux/llm-stack/geniex_toolcall_shim.py \
    --upstream http://localhost:18184 --port 18190
# then point the opencode provider at 18190 instead of 18184
```

It calls upstream without streaming even when the client asked for a stream — a
tool call cannot be recognised before its closing tag arrives — and re-emits the
answer as the stream the client expects. On v0.5.0 that cost nothing
measurable: there was no prefix cache and prefill dominated, so the response was
already one long wait. On v0.6.x it would cost the streaming experience — but
there the shim is not needed at all (§ 1n).

Two things it deliberately does **not** do. It never invents a call from
markdown fences: guessing there is how an agent runs a command the model never
asked for. And a call the model started but never closed yields no call at all —
only the half-written markup is removed, so it cannot reach the user as if it
were an answer. Both are pinned by tests, against output captured from the real
server rather than invented fixtures.

**With the shim in place, the loop works.** The same harness, the same models,
the same tasks — the only change is that the tool call is now visible:

| Task | Result | Wall | Tool calls | Events |
|---|---|---:|---:|---:|
| `fix_failing_test` | **PASS** | 656 s | 7 | 26 |
| `add_function_and_test` | **PASS** | 841 s | 9 | 31 |
| `multi_file_rename` | **PASS** | 621 s | 11 | 28 |

Score: **3/3** on `Qwen3.8-9B-Distill` Q4_K_M, CPU lane, tool set trimmed
to four. This is the first time this benchmark has ever *observed a pass* — and
that matters more than the number. Until now it had only ever seen failures, so
a bug that made everything fail would have looked exactly the same. The fixture
self-test proved the verification could go green; only this proves the whole
path can.

Read the wall-clock honestly: minutes per task, on tasks a competent junior
finishes in two. That is the prefill cost of § 1m, not a quality result. What
changed is that on-device agent work went from *impossible* to *slow*.

#### What this corrects

The QAIRT 4B on the NPU remains the fastest path to a finished *answer* on this
machine — § 1d, § 1f and § 1i all still stand, all measured through a compact
harness prompt. It is the right choice for chat and completion. It **cannot
drive opencode**, and no configuration changes that.

For agent work the recipe that actually completes tasks is:

1. a **GGUF lane** (`--nctx 16384`) — the QAIRT context is not negotiable, on
   any version;
2. **tool set trimmed** in `opencode.jsonc` — always worth it, and on a
   pre-cache build it was 36% off every turn;
3. on **GenieX v0.5.0 only**, `geniex_toolcall_shim.py` in front of the lane —
   without it that build discarded every tool call and the agent did nothing.
   v0.6.0 parses them itself (§ 1n);
4. and patience: **~3.5 minutes per task** on v0.6.1, 10-14 on v0.5.0.

The constraints stacked, and the order in which we found them is the order of
increasing embarrassment: the first was visible in an error message, the second
only in a wall-clock, and the third looked exactly like the models being bad at
their job.

**On-device agent work here went from impossible to slow, and then from slow to
usable** — the last step by a vendor release rather than by anything measured
here. That is the honest summary. It was never a throughput result and never a
quality result: the models were not the limit at any point.

#### The harness proves itself before it judges anything

With no strong control model reachable, a column of failures is unreadable —
broken fixture, or weak model? So `--self-test` applies a known-good solution to
each fixture by hand and asserts the verification is red before and green after:

```bash
python3 linux/llm-stack/bench_agent.py --self-test
#   fix_failing_test         OK   unsolved=fail solved=pass
#   add_function_and_test    OK   unsolved=fail solved=pass
#   multi_file_rename        OK   unsolved=fail solved=pass
#   Harness validated
```

The fixtures also refuse the two cheap ways to fake a pass, both covered by
tests: aliasing the old name (`fetch_data = format_record`) is not a rename, and
an `assert True` test does not count as testing a `clamp` that never clamps.

**Blocked runs are excluded from the score, not counted as zero.** A model that
never received the task did not fail it, so the denominator counts attempted
tasks only. Three blocked tasks report `0/0`, which the statistics layer renders
`n/a` over a [0%, 100%] interval — "not measurable here", never "0%, it cannot
code". Confusing those two is how a hardware limit gets written up as a model
being bad at its job.

### 1n. GenieX v0.6.1 — what the update changed (measured 2026-09-05)

The host ran **v0.5.0** (llama.cpp `873e5d8`) for every measurement dated
2026-08-31 to 2026-09-04. It now runs **v0.6.1** (llama.cpp `0eadefe`), pulled
with the CLI's own `geniex update`. Four of the constraints this page was
written around are gone. Three others are not — including the two that carry
the strongest conclusions.

Each row was re-measured on this host after the update, not read from a
changelog:

| v0.5.0 | v0.6.1 | How it was checked |
|---|---|---|
| Returned Qwen's `<tool_call>` template as plain `content`, `tool_calls` empty | **Parses it** | `Qwen3.8-9B-Distill` on the CPU lane: populated `tool_calls`, `finish_reason: "tool_calls"`, 16 s |
| Ignored `max_tokens` outright (3000 → 642, 500 → 1249) | **Honours it exactly** | 50 → 50 and 400 → 400 completion tokens, `finish_reason: "length"` |
| Hard **2048-token** output ceiling | **Gone** | `max_tokens: 3000` → 3000 completion tokens |
| **No prefix cache** — every turn re-prefilled the whole conversation | **Incremental prefill** | identical ~4k-token request: 13.9 s cold → **0.1 s** warm; same prefix with ~800 tokens appended: **0.9 s** |
| `temperature: 0` still sampled | **unchanged** | two identical requests, two different answers |
| QAIRT bundles hard-capped at 4096 context | **unchanged** — but a clean error | ~2.3k tokens answers; ~5.7k and ~9.1k return HTTP 400 `context_length_exceeded` instead of v0.5.0's `SDKError(Input prompt too long)` wrapped in a type-validation failure |
| Sub-4-bit **i-quants produce garbage** | **unchanged** | `IQ3_XXS` 0/3 on three trivial questions (`'一侧osesnce majority coli…'`); `Q4_0`, `Q3_K_M` and `Q2_K` all 3/3 |
| The 2B cannot do function calling | **unchanged** | same prompt, still markdown fences and no template |

Two of those deserve emphasis because they were load-bearing here.

**The i-quant bug survived a llama.cpp bump.** It was diagnosed on `873e5d8`
and is unchanged on `0eadefe` — same garbage, same clean K-quants beside it,
down to 2 bits. Two independent runtimes make it a property of these kernels
rather than of one build, which is stronger evidence than the original section
could claim. `inspect_gguf.py` still refuses these files, and should.

**The QAIRT 4096 ceiling is not negotiable.** It is compiled into the bundle,
not a server setting, so no release moves it. opencode's preamble is 8,175
tokens (§ 1m), and it still does not fit — the conclusion of § 1m stands
entirely. What changed is only the diagnosis: the lane now says
`context_length_exceeded` instead of failing schema validation on an error
shape the client could not read.

#### What this means for the tooling in this repository

- **`geniex_toolcall_shim.py` is obsolete on v0.6+.** It exists because v0.5.0
  dropped the tool call; v0.6.0 added the parsing. It is kept for older builds
  and is harmless in front of a new one — it skips any message the server
  already parsed — but the opencode provider now points straight at the lane.
- **`bench_coding.py` no longer assumes a 2048-token ceiling.** A cut is
  recognised from `finish_reason: "length"` first, then from
  `usage.completion_tokens`, and only then from the streamed delta count; the
  threshold is the request's own budget rather than a server constant. A fixed
  2048 would now report a long legitimate answer as CUT.
- **`--repeats` still earns its place.** `temperature: 0` samples, so a single
  run is still one draw rather than the model.
- The numbers in § 1d, § 1f, § 1g, § 1i and § 1m are **v0.5.0 measurements**
  and are left as measured. Where the cap or the missing cache distorted them,
  the section says so.

#### The end-to-end agent benchmark, re-run on v0.6.1

Same harness, same three tasks, same model and lane, scored the same way — by
running each scratch repository's own tests afterwards. The only differences
are the GenieX version and that the shim is gone:

| Task | v0.5.0 + shim | **v0.6.1, no shim** | Tool calls |
|---|---:|---:|---:|
| `fix_failing_test` | 655.8 s | **212.4 s** | 7 |
| `add_function_and_test` | 841.1 s | **225.8 s** | 7 |
| `multi_file_rename` | 621.2 s | **219.2 s** | 11 |
| **Total** | **2118.1 s** | **657.3 s** | — |

3/3 both times; **3.2x faster overall**, and the whole suite now costs what a
single task used to. The gain is the prefix cache: the work per turn did not
change, it stopped being paid again on every turn.

Reproduce with:

```bash
python3 linux/llm-stack/bench_agent.py --self-test    # prove the fixtures first
python3 linux/llm-stack/bench_agent.py \
    --model geniex-cpu/empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M --timeout 1800
```

## Debugged: i-quants below 4 bits are broken in GenieX's llama.cpp

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
the llama.cpp build GenieX ships** (aarch64).

**Re-verified on 2026-09-05 after updating to v0.6.1**, which bumps that build
from `873e5d8` to `0eadefe`: `IQ3_XXS` still answers three trivial questions
0/3 (`'一侧osesnce majority coli…'`) while `Q4_0`, `Q3_K_M` and `Q2_K` from the
same repository answer 3/3. Two independent runtimes, the same split — this is
a property of the i-quant kernels on this target, not of one release, which is
a stronger claim than the original diagnosis could make (§ 1n).

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
CDSP/FastRPC driver predated the runtimes GenieX bundles (v0.5.0 at the time;
v0.6.0 moved to bundling the QAIRT runtime by default, with `--qairt-lib` as an
override).

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

## Long unattended runs: keep the machine awake first

A multi-hour benchmark makes **no power request**. Windows sees background HTTP
traffic and a busy NPU as an idle system and enters Modern Standby on schedule —
and this host does not reliably come back from it while a GenieX lane holds a
model.

Measured the hard way on 2026-09-03: a 27-task run was left unattended, the
WLAN log shows `sleep, SLPM Exit, display off` cycling once a minute until
03:53, and the machine then had to be powered off by hand. Kernel-Power event
41 with `BugcheckCode 0` and no crash dump — a **hang, not a bluescreen**. The
run, and roughly an hour of measurement, were lost.

The idle timeouts on this host make it easy to hit:

| Power source | Standby after |
|---|---|
| AC | 5 hours |
| **Battery** | **10 minutes** |

Wrap any run longer than a few minutes:

```powershell
# hold it awake for the duration of a run started elsewhere
pwsh -ExecutionPolicy Bypass -File windows/scripts/host/keep-awake.ps1 -Minutes 240

# or run the command under it
pwsh -ExecutionPolicy Bypass -File windows/scripts/host/keep-awake.ps1 -Command "bash run-sweep.sh"
```

**`-ExecutionPolicy Bypass` is not optional from WSL, and leaving it out fails
silently.** This repository lives inside WSL, so Windows sees the script at
`\\wsl.localhost\...` — a UNC path, which it treats as a remote zone and
refuses to run unsigned:

```text
SecurityError: File \\wsl.localhost\...\keep-awake.ps1 cannot be loaded.
The file is not digitally signed.
```

Launched the usual way — `Start-Process pwsh ... -WindowStyle Hidden` — that
error goes to a hidden window nobody reads. The launcher reports success, no
guard is running, and the machine sleeps mid-run exactly as before. This was
hit live on 2026-09-04, an hour into an unattended agent benchmark. **Verify,
do not assume:**

```powershell
Get-Process pwsh | Select-Object Id, StartTime   # a guard must be listed
```

It uses `SetThreadExecutionState`, which is scoped to that process, so a crash
or Ctrl-C releases the request automatically. Changing the power scheme instead
would survive the run and quietly leave the machine unable to sleep at all —
trading one failure for a worse one.

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
