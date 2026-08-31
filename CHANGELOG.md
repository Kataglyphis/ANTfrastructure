# Changelog

> **Older entries** (2026-08-13 and before) are in
> [`docs/changelog-archive-2026-08-13.md`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete.


## 2026-08-31 — 2-bit measured; GenieX session harvested into an llm-stack backlog

**2-bit K-quants work; i-quants at any width do not.** `Qwen3-4B:Q2_K` is a
pure K-quant file (Q2_K 144, Q3_K 72, Q4_K 36, no i-quants) and produces
coherent output -- so the sub-Q4 failures really are the i-quant bug, not bit
width. It does cost accuracy: on a six-question verifiable battery at
temperature 0, Q4_0 scored 6/6 and Q2_K 4/6, losing exactly the two reasoning
items (letter counting 3->2, the machines/widgets puzzle 5->1) while keeping
arithmetic and factual recall. Six questions is a probe, not a benchmark, and
perplexity is not measurable through the OpenAI API. For the 27B it is moot:
the only sub-Q4 variants in that repo are i-quant based.

**New backlog group B/LLM-BENCH** (`docs/refactoring-backlog.md`): nine items
harvesting this session into `linux/llm-stack`, which already has a 502-line
benchmark harness, a sweep script and a React viewer. Every wrong conclusion
this session produced traces to a metric that harness does not collect:

- LB1 [M/3-star] a correctness probe -- it measures only speed, so the i-quant
  garbage would have scored *excellently* (fast, fluent nonsense)
- LB2 [S/3-star] TTFT/prefill; there is no first-token measurement at all,
  and prefill is what an agent actually waits on
- LB3 [S/3-star] report time-to-finished-answer; headlining tok/s ranks models
  wrongly (1.7B: fastest tok/s, slowest answer)
- LB4 [M/2-star] multi-endpoint + concurrent lane aggregate
- LB5 [S/2-star] batching/serialization probe
- LB6 [S/2-star] GGUF tensor-type introspection -- what actually diagnosed the
  i-quant bug, since no benchmark could
- LB7-LB9 [S/1-star] de-Ollama the harness (hardcoded gemma4:26b at line 171),
  worker-vs-listener resource attribution, Linux-only hardware info

## 2026-08-31 — CORRECTION: the sub-Q4 garbage is a GenieX i-quant bug, not a quality floor

The previous entry claimed "a hard quality floor at Q4 -- both 3-bit quants
answer with garbage, everything below is smaller still". The observation was
right; the explanation was wrong, and the extrapolation was unfounded.

Hypotheses walked down in order:

  sampling artefact   temperature=0, "Say hello."      still garbage; Q4_0 fine
  corrupt download    SHA256 vs the HF LFS oid         byte-perfect
  CPU-backend bug     same file on the GPU lane        fails there too
  "UD quants are bad" UD-Q4_K_M from the same repo     works fine
  "3 bits is too few" Qwen3-4B:Q3_K_M (3-bit K-quant)  works perfectly
  i-quant kernels     Qwen3-4B:IQ3_XXS                 garbage on BOTH lanes

The discriminator is the tensor *type*, not the bit width. GGUF tensor
histograms: the working files carry no i-quants below 4 bits (Q4_0: none;
UD-Q4_K_M: IQ4_XS 117, IQ3_S 4; Q3_K_M: pure K-quants), the broken ones are
dominated by them (UD-Q3_K_XL: IQ3_S 111 + IQ3_XXS 34 + IQ2_* 21; UD-IQ3_S:
IQ3_S 127 + IQ3_XXS 77 + IQ2_* 45 + IQ1_S 2; Qwen3-4B-UD-IQ3_XXS: IQ3_XXS 144
+ IQ2_S 52 + IQ3_S 41).

So: IQ4_XS and IQ4_NL are fine; IQ3_S, IQ3_XXS, IQ2_* and IQ1_* are broken in
the llama.cpp build GenieX v0.5.0 ships (runtime hash 873e5d8, aarch64). It
reproduces across two architectures (qwen3, qwen35), two sizes (4B, 27B) and
both compute lanes, on files verified byte-identical to Hugging Face -- so
neither a bad download nor a bad quantisation.

Consequences: never pull IQ1_*/IQ2_*/IQ3_* for this setup, for any model
(UD-Q2_K_XL is i-quant-heavy too and should be assumed broken); 3-bit itself is
fine, so a plain Q3_K_M is worth seeking out; the practical "do not go under
Q4_0 in this repo" advice survives, but only because this repo's sub-Q4
offerings all happen to be i-quant based. Worth reporting upstream to
qualcomm/GenieX, and worth re-testing after a runtime bump.

## 2026-08-31 — 27B quant ladder mapped end to end; Q4_0 stays

Enumerated every quant `unsloth/Qwen3.8-27B-GGUF` offers (22 variants, IQ1_S
6.2 GB through Q8_0 29 GB) and bounded them against the real constraint: host
RAM. 31.6 GB total minus WSL2's 10 GB cap and Windows leaves ~22-24 GB, so
Q6_K (22 GB) and up cannot run at all and Q5_K_S (18.7 GB) is the ceiling.

Pulled `UD-Q4_K_M` (16.5 GB) and measured it head to head against `Q4_0`:

  Q4_0      5.62 tok/s   TTFT 1.06 s
  UD-Q4_K_M 5.08 tok/s   TTFT 2.38 s    (~10% slower)

Output was equivalent on a code task, and both answered a verifiable arithmetic
check correctly (847 * 293 -> 248171). Likely cause of the gap: llama.cpp
repacks legacy Q4_0 into ARM kernels (Q4_0_4_8 / i8mm) that K-quants do not get
-- the same mechanism that makes the CPU lane fast at all.

Two prompts is not a quality evaluation, and the docs say so: UD-Q4_K_M is in
principle the better quantisation; the honest finding is only that no quality
difference was demonstrable while the 10% speed cost was.

Also documented: a hard quality floor at Q4. Both 3-bit quants (IQ3_S,
Q3_K_XL) load, answer, and return garbage, and everything below them is
smaller still -- so nothing under Q4_0 is worth pulling.

Bottom line unchanged: Q4_0 on the CPU lane is the 27B setup to use.

## 2026-08-31 — full Qwen3.8 lane matrix; 27B rehabilitated, Q3_K_XL retired

Every cached Qwen3.8 model against every lane, one prompt, one methodology:

| Model | Size | NPU | GPU | hybrid | **CPU** |
|---|---|---|---|---|---|
| 2B-Distill `Q4_K_M` | 1.3 GB | 18.2 | 23.1 | 20.7 | **47.6 tok/s** |
| 9B-Distill `Q4_K_M` | 5.8 GB | 8.4 | 6.8 | 7.35 | **15.2 tok/s** |
| 27B `Q3_K_XL` | 13.1 GB | ❌ | ❌ | ❌ | garbage output |
| 27B `Q4_0` | 16.1 GB | ❌ | HTTP 500 | ❌ | **5.6 tok/s** |

The CPU wins every row. The accelerator ranking flips with model size (2B:
GPU > hybrid > NPU; 9B: NPU > hybrid > GPU) and it makes no difference — the CPU
is 2-2.6x ahead of whichever one wins.

**The 27B was written off too early.** This page said "CPU-only territory...
~1 tok/s". Measured on the Windows host: **5.6 tok/s warm, 1.06 s TTFT, correct
well-structured code**. Slow for chat, fine for batch, and the best quality any
lane here can produce.

**`Q3_K_XL` is broken, not borderline.** Previously "the last quant worth trying
above 12 GB". It loads, answers, and returns garbage -- a real request gave
`'0\n\n\n\n\n\n\n\n -\n0\n0'` (12 tokens, finish_reason stop), the same
failure already noted for IQ3_S. Below Q4 this 27B is unusable at any speed.

**New crash found: mixing QAIRT and GGUF on the NPU lane kills the server.**
Deterministic -- fresh lane serves GGUF fine, serves a QAIRT bundle fine, and
the next GGUF request resets the connection and the process is gone. An opencode
provider lists several models against one baseURL, so switching model in the UI
is enough to trigger it. opencode.jsonc now keeps the NPU lane QAIRT-only and
gains a `geniex-cpu` provider for the GGUFs (which are faster there anyway).

## 2026-08-31 — hybrid falsified: no `--ngl` setting beats plain CPU

`--compute hybrid` was previously documented as "the sweet spot for models that
straddle the HTP budget". That conclusion compared hybrid against the NPU and
the GPU — **never against the CPU**. With the CPU lane measured, hybrid loses
everywhere:

| Model | hybrid | **CPU** | GPU | NPU |
|---|---|---|---|---|
| Qwen3-4B `Q4_0` | 9.96 tok/s | **23.7** | 12.5 | 11.9 |
| Qwen3.8-9B-Distill `Q4_K_M` | 7.5 tok/s | **15.2** | 6.5 | over HTP budget |

The 9B — the model hybrid supposedly existed for — is **2x faster on plain CPU**
(15.2 vs 7.5), first token 0.44 s instead of 26.6 s.

Swept `--ngl` on the 9B in hybrid mode to check whether the layer split was
simply mistuned: `-1` → 7.32, `32` → 7.20, `16` → 6.18, `8` → 7.83 tok/s. Every
configuration sits at 6–8 tok/s with a 14–27 s first token. The split is not the
bottleneck; any HTP participation drags the graph to `ggml-hexagon` speed.

**Verdict: `--compute hybrid` has no use on this machine.** Slower than CPU on
every model, 30–60x worse TTFT, and the only mode that damages a concurrent NPU
lane (19.25 → 12.84, shared HTP). Docs, launcher help and AGENTS.md now say so.

Also added: an § At a glance decision table at the top of the page, measured 9B
CPU figures in the model matrix, and a note that the original short-reply rows
and the re-measured full-stream rows are two methodologies that must not be
compared across.

## 2026-08-31 — Measured: the CPU beats the Hexagon NPU 2x on GGUF

The CPU rows on this page were *estimates scaled from a 27B WSL2 run* (~5 tok/s
for the 4B). Measured properly against a `--compute cpu` lane on the Windows
host (8x Oryon), same model, same quant, same prompt, they were wrong by ~4.6x:

| Model (GGUF) | CPU | NPU | CPU advantage |
|---|---|---|---|
| Qwen3-4B `Q4_0` | **23.2 tok/s** | 11.9 tok/s | **1.95x** |
| Qwen3.8-2B-Distill `Q4_K_M` | **46.5 tok/s** | 16.9 tok/s | **2.75x** |

llama.cpp's ARM CPU kernels (NEON/dotprod/i8mm; `Q4_0` is repacked for them) are
simply more mature than the bundled `ggml-hexagon` backend.

The NPU still earns its place, on two other axes: it runs QAIRT bundles (which
the CPU cannot load at all, and which are non-thinking and therefore fastest
end-to-end — 26.8 s vs 88.4 s to a finished answer), and it does so at
**165 % of 800 % CPU vs the CPU lane's 752 %** — a fifth of the cost, which is
what keeps the machine usable while the agent answers. Measurement note: the
inference worker is a *separate* `geniex` process from the port holder; sampling
the listener reads ~11 % and tells you nothing.

- `start-geniex-servers.ps1`: new `-WithCpu` opt-in lane on 18184
- docs: new § 1b, and the estimated CPU row replaced with measured numbers

## 2026-08-31 — GenieX throughput pass: QAIRT bundle + NPU/GPU dual lane (~6x faster agent answers)

Re-measured the Snapdragon on-device agent end-to-end rather than per compute
unit. The previous "4B on the NPU at 15.2 tok/s is the ceiling" conclusion
optimised the wrong variable; three larger wins were found and applied.

### The QAIRT bundle beats every GGUF here (~6x end-to-end)

`qualcomm/Qwen3-4B-Instruct-2507:W4A16` was cached but never benchmarked:

| | GGUF 4B Q4_0 | QAIRT 4B W4A16 |
|---|---|---|
| decode | 11.5 tok/s | **18.9–19.5 tok/s** |
| tokens per short answer | ~1889 | **522** |
| wall clock (warm) | 164.8 s | **26.8 s** |

Re-tested against `qualcomm/Qwen3-1.7B:W4A16`, which is *faster per token and
slower in practice*: **31.7 tok/s but 1921 tokens per answer = 60.8 s**, versus
the 4B's 19.5 tok/s / 522 tokens / **26.8 s**. Time-to-finished-answer is the
metric; tok/s alone picks the wrong model.

1.7x of that is decode; the rest is the **`<think>` tax** — the Qwen3/Qwen3.8
GGUFs are reasoning models (21 tokens to answer "reply with exactly one word"),
the Instruct-2507 bundle is not (2 tokens). It also runs at **3.0 GiB, above the
~2,93 GiB HTP vmem wall** — that ceiling is a property of the bundled llama.cpp
`ggml-hexagon` backend, not of the NPU.

### One server = one request; NPU + GPU compose, hybrid contends

`geniex serve` does no batching — a second request waits for the first to finish
completely (27.6 s TTFT), and a busy server will not even answer `/v1/models`.
Measured topologies: **NPU+GPU = 19.25 + 12.11 = 31.4 tok/s** (~1–3 % mutual
cost, separate silicon), while adding `hybrid` (NPU+CPU, same HTP) buys
+2.7 tok/s aggregate but drops the NPU lane to 12.84.

### Two defaults were wrong for agent use

`--keepalive` 300 s unloaded the model on every pause (14–15 s cold reload);
`--nctx` 4096 was *below* the 8192 the opencode config advertised, and overflow
does not error — a 6.4k-token prompt never returned within 400 s.

- New `windows/scripts/host/start-geniex-servers.ps1`: brings up the NPU + GPU
  lanes with `--nctx 16384 --keepalive 86400`, `-WithHybrid` for the third lane,
  `-Restart` to recycle. Validated live.
- `~/.config/opencode/opencode.jsonc`: QAIRT bundle promoted to primary, new
  `geniex-gpu` provider for the second lane.
- **QAIRT bundles carry a hard-compiled 4096 context** (`genie_config.json`
  → `"context": {"size": 4096}`); `--nctx` is llama.cpp-only and does not raise
  it. Overflow returns nothing rather than erroring. The opencode limit for the
  QAIRT model is set to 4096 accordingly — this is the binding constraint of the
  NPU lane, not its speed.
- § Wire the coding agent rewritten as a 5-step opencode integration guide
  (pull → serve → provider block → model select → verify) with the four silent
  misconfigurations that break it.
- [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): new
  § Getting the most out of this machine, plus five troubleshooting rows.

Still slow, honestly: **prefill dominates agent latency** — a 2.5k-token prompt
costs 13.1 s to first token (~190 tok/s) and pulls decode down to 13.0 tok/s.
No batching or speculative-decoding knobs exist in `geniex serve`, and
`max_tokens` is not honoured.


## 2026-08-31 — QNN SDK integrated into the arm64 cross build (#121 proven) + GStreamer compiler-rt self-heal (#135 follow-up)

### QNN EP build-time path PROVEN on the arm64 cross lane (#121)

The staged QAIRT SDK (qairt-2.44.0.260225, SHA-pinned) was exercised end-to-end
for the first time on a full `-TargetArch arm64` cross run:

- `Resolve-QnnSdk` verified the SHA, extracted the SDK and enabled
  `onnxruntime_USE_QNN=ON` with the `aarch64-windows-msvc` backend set
- ONNX Runtime built the QNN provider (symbol file `['cpu', 'qnn', 'dml']`),
  `QNN_SDK_ZIP_SHA256` forwarded driver → Dockerfile ARG → ENV → build script
- The run reached the merge stage (the last arm64 acceptance gate); the only
  failure was the unrelated GStreamer link below

### GStreamer cross-lane compiler-rt self-heal (#135 follow-up)

`C:\llvm-patched` (the source-built default toolchain) ships
`clang_rt.builtins-x86_64.lib` only, so the arm64 GStreamer link died on
`__udivti3` in the merge stage. `build-gstreamer-from-source.ps1` § 5d now
self-heals on the cross lane: it mines `clang_rt.builtins-aarch64.lib` from the
official LLVM release archive next to the x86_64 lib (same recipe as
`setup-scoop-tools.ps1`), then re-runs its candidate search. The first live
attempt used the GNU tar on PATH, which parses `C:\...` as a remote-host spec
("Cannot connect to C:") — the extract now forces System32's bsdtar (the same
trap build-llvm-from-source.ps1 already avoids). Chosen over adding the lib to
the toolchain layer because the media branches derive FROM
`bk-windows-toolchain` — that would have re-paid ~2 h of media compiles for one
lib. Regression test: `SourceBuild.GstreamerCompilerRt.Tests.ps1` (4 tests).
Docs: `docs/windows-cross-builds.md` § aarch64 compiler-rt;
`docs/windows-refactor-backlog.md` #135 follow-up.

The compiler-rt fix unmasked the speculative cross-lane opus intrinsics
enablement (added 2026-08-30), which had never reached a real compile: the RTCD
path applies `-mfpu=neon` (ARM32-only; clang-cl rejects it for aarch64) and its
CPU probe `celt/arm/armcpu.c` uses MSVC's `__emit` (absent from clang-cl).
REVERTED to the proven 2026-08-26 shape — `-Dopus:intrinsics=disabled` on both
lanes; the working enablement recipe (`intrinsics=enabled` + `rtcd=disabled`,
which needs a real-device smoke because it presumes NEON+dotprod) is recorded in
`docs/windows-cross-builds.md` and the backlog. Regression test extended to 6
assertions.

The arch-gate import walk then flagged the staged QNN runtime: the QAIRT HTP
stub DLLs import `libcdsprpc.dll`/`libadsprpc.dll` — Qualcomm's FastRPC
drivers, which ship in every Windows-on-Snapdragon OS image (never in the SDK
zip). Added to the gate's client-OS allowance (`ClientOsPattern`); regression
assertion in `SourceBuild.VerifyTargetArch.Tests.ps1`.


## 2026-08-31 — WSL2 RAM tuning: host gets ~20 GB back; 27B loads on GPU but stays impractical

The GenieX models run on the Windows host, but the host `.wslconfig` had capped
WSL2 at **30.3 GB of 31.6 GB**, and WSL contained ~4.3 GB of orphaned dead
weight. Both fixed:

- `.wslconfig`: `memory=10GB` + `autoMemoryReclaim=gradual` + `swap=4GB`
  (backup of the old file kept). WSL now reports ~9.7 GB total; the Windows
  host went from ~2 GB free to **~18–21 GB free**.
- WSL cleanup (elevated commands, documented): rootful `containerd.service`
  stopped+disabled (killed orphaned Elasticsearch + Collabora containers,
  ~2.5 GB) and `pkill` of orphaned clamd/freshclam + postgres (~1.1 GB).
  Containers from a running compose (llm-stack glances) kept.
- **What the RAM buy actually gives:** the 27B Q3_K_XL (13.1 GB) now *loads* on
  the Adreno GPU (was `CL_OUT_OF_RESOURCES`), but generation is still
  impractical there — 2.0 tok/s, 9.1 s first token, and the server hung under
  the first real request (HTTP 000, 14.4 GB RSS, killed to release RAM). The
  honest bottom line is now in the docs: on this machine, the GPU serves up to
  the 9B-Distill; the 27B stays CPU territory; the NPU serves 2B/4B fastest.
- New docs section "Making room: WSL2 RAM tuning" in
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): the
  `.wslconfig` cap + `autoMemoryReclaim`, the elevated cleanup commands, and
  the reality check (what freed RAM did and did not buy).

## 2026-08-31 — hybrid actually measured: 9B distill runs at 7.5 tok/s (faster than GPU)

Tested `--compute hybrid` against every Qwen3.8-class model on this Snapdragon
X, with the surprise that **hybrid is the right path for models that straddle
the HTP budget**:

- **Qwen3.8-9B-Distill Q4_K_M (5.78 GB)** does not fit the ~3 GB HTP alone but
  runs on `--compute hybrid` at **7.5 tok/s — faster than the same model on the
  GPU (6.5 tok/s)**. Hybrid offloads the layers that fit the HTP and runs the
  rest on CPU.
- **Qwen3.8-27B Q4_0 crashes on hybrid too** (like pure NPU): the single HTP
  cannot even stage a fraction, so there is no partial-offload win. 27B stays
  CPU-only territory (or GPU Q3_K_XL at degraded quality).
- Full measured envelope table added to
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): NPU
  16.9 (2B) / 15.2 (4B), hybrid 7.5 (9B), GPU 13.2 (4B) / 6.5 (9B). CPU numbers
  for 2B/4B/9B are marked as estimates; NPU/GPU/hybrid are all measured.
- Bottom line: **no single model combines GPU+NPU** (hybrid = NPU+CPU only);
  you cannot add the GPU to hybrid. Docs now state this plainly and recommend
  2B-Distill (NPU) / 4B (NPU) / 9B-Distill (hybrid) per task weight.

## 2026-08-31 — hybrid compute truth + Qwen3.8 model matrix

Clarified what GenieX v0.5.0 can and cannot do with all three accelerators, and
which Qwen3.8-class models fit this Snapdragon X — all verified live:

- **`--compute hybrid` is the per-tensor NPU scheduler, NOT "GPU+NPU at once".**
  The device alias resolves to `DeviceID:""` + `ngl != 0`, which the llama_cpp
  plugin classifies as NPU; the HTP runs the layers that fit and CPU takes the
  rest. Measured 14.1 tok/s on the 4B (pure NPU: 15.2). A single model runs on
  HTP(+CPU fallback) or GPU, never both simultaneously.
- **Multi-HTP device lists** (`--compute HTP0,HTP1,...` + `GGML_HEXAGON_NDEV`)
  spread a model across several HTP cores — but this X126100 has a single HTP
  (hwinfo `threads 4, hvx 4, hmx 1`), so the list degenerates to one device.
- **QAIRT bundles are NPU-only** — `--compute cpu/gpu` on one is coerced back
  to NPU with a warning.
- **Run both accelerators at once**: one `geniex serve` binds one default
  compute; run a second server on another port (`--host 0.0.0.0:18182`) and
  point the agent at the right base URL per model.
- **Qwen3.8 model matrix** (verified): `Qwen3.8-2B-Distill` Q4_K_M 1.31 GB →
  NPU 16.9 tok/s (fits ~3 GB HTP); `Qwen3-4B` Q4_0 → NPU 15.2 / GPU 13.2;
  `Qwen3.8-9B-Distill` Q4_K_M 5.78 GB → GPU only (over HTP budget);
  `Qwen3.8-27B` → CPU territory (see quant ladder); `Qwen3.8-Flash-Next` too
  large for this class of machine. Docs updated with the matrix and an
  NPU-first opencode provider example.

## 2026-08-31 — GenieX NPU FIXED by a Qualcomm Hexagon NPU driver update + NPU probe

**The NPU now works.** Updating the Qualcomm Hexagon NPU driver
(`libcdsprpc.dll` 30.0.0140.1000 → 30.0.0220.3000; Hexagon NPU device driver
30.0.220.3000, installed via Windows Update optional driver updates + reboot)
fixed both NPU backends. Root cause (documented in
[`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md) § The NPU
problem): the old driver's `libcdsprpc.dll` exported only the legacy FastRPC
API, not the `dspqueue_*` symbols GenieX v0.5.0's bundled llama.cpp
`ggml-hexagon` backend dlsyms (`dspqueue_create` etc. — verified per-symbol
with `GetProcAddress`). QAIRT/QNN showed a different symptom of the same root
cause: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in HTP runtime init.

- Measured after the fix: **4B on NPU at 15.2 tok/s (0.2 s first token)** —
  faster than the Adreno GPU (13.2 tok/s) and far faster than CPU. Verified
  end-to-end through the OpenAI server from WSL2.
- Remaining limit: the Hexagon HTP has ~3 GB vmem (`vmem 3145728000` in the
  load log), so the 27B fails at graph compute with `dspqueue_read failed:
  0x00000072` — a memory limit, not a driver bug (same class as
  ggml-org/llama.cpp#26123).
- New probe `windows/scripts/diagnostics/probe-geniex-npu-driver.ps1`: checks
  the **active** CDSP `libcdsprpc.dll` (matched by Hexagon-NPU device driver
  version, so stale DriverStore copies cannot falsify the verdict) for the
  `dspqueue_*` symbols. Reporting-only, never throws on a negative. Documented
  in `docs/windows-builds.md` § Script Reference.
- Docs updated: measured envelope now NPU-first; troubleshooting table covers
  the pre-fix `dlsym` failure, the QAIRT stack overflow, and the post-fix HTP
  memory limit.

## 2026-08-31 — GenieX on-device OpenAI server for Snapdragon (docs + host tooling)

New page [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md):
run Qualcomm GenieX (BSD-3-Clause) so a coding agent inside **WSL2** talks to a
local OpenAI-compatible API backed by the Windows host's **Adreno GPU** (or
Hexagon NPU). WSL2 has no NPU/GPU passthrough, so the server runs on Windows
and WSL2 reaches it at `127.0.0.1:18181` via mirrored networking.

- Deployed and measured live on a Lenovo Snapdragon X (2026-08-31): GPU 4B at
  13.2 tok/s, clean output, verified end-to-end through the OpenAI API; the
  27B's usable quant window on the Adreno is ≤ ~13 GB (Q4_0 @ 16 GB OOMs with
  `CL_OUT_OF_RESOURCES -5`; IQ3_S @ 12 GB loads but 3-bit quality is unusable —
  whitespace output).
- **NPU root cause documented** (not just "broken"): both NPU backends fail
  against the installed Qualcomm CDSP/FastRPC driver (1.0.4175.2700,
  20.11.2024; `libcdsprpc.dll` v30.0.0140.1000):
  - llama.cpp Hexagon backend: `failed to dlsym dspqueue_create` — the driver
    exports only the older FastRPC API (`remote_handle_open`), not the
    `dspqueue_*` symbols the bundled backend needs (verified per-symbol).
  - QAIRT/QNN backend: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in the
    QNN v2.45.0 HTP runtime init — same stale-driver family, different symptom.
  - Fix is a **Qualcomm CDSP/FastRPC driver update** (Windows Update optional
    updates / Lenovo driver page); GenieX v0.5.0 is already the latest release.
    Until then `--compute gpu` is the working accelerated path.
- Also handled: SoX install + user-PATH for the serve warning; non-interactive
  chipset config (`geniex config set chipset qualcomm-snapdragon-x-elite`);
  local cache copy across Windows/WSL2 to avoid re-downloading 16 GB; the WSL2
  localhost port-shadowing trap that prevents the Windows server from binding.
- Docs wiring: `docs/INDEX.md`, `docs/index.rst` (toctree), `README.md`,
  `AGENTS.md` § GenieX on Snapdragon, and a `deps.json` entry under Host Build
  Infrastructure (BSD-3-Clause) — licence pages and curated SBOM regenerated.

## 2026-08-30 — rebuild window: GCC_PARALLEL_TARGETS validated (2 bugs found+fixed), F2 media validation, launcher server-death gap fixed

The tasks that needed a real rebuild, run and closed:

### GCC_PARALLEL_TARGETS validation — PASS, and it surfaced two real bugs

- **92fb9646 — the launch flag was silently dropped (the real "missed four
  times" cause).** No `ARG GCC_PARALLEL_TARGETS` in Dockerfile.toolchain and no
  `--build-arg` in the compiler-stage args, so a launch-time
  `GCC_PARALLEL_TARGETS=1` never reached the container and the sequential path
  won every time. Fixed: ARG + ENV in Dockerfile.toolchain (mirrors
  `GCC_HOST_BOOTSTRAP`), `append_optional_build_arg` forwarding in
  stage-defs.sh's compiler case (only when set; Dockerfile defaults stay
  authoritative), pinned by test-stage-defs.sh. Dry-runs now emit
  `--build-arg GCC_PARALLEL_TARGETS=1` when set, absent when not.
- **5e8b2470 — the first parallel launch collided on the dpkg apt lock.**
  The concurrent per-target `build-gcc.sh` invocations each ran their own
  "Installing build dependencies..." apt_install; two apt-get at once die on
  `/var/lib/apt/lists/lock`. Fixed: `GCC_SKIP_BUILD_DEPS=1` gates build-gcc.sh's
  apt step (deps already installed by `build_host_gcc`, which runs first) and
  the parallel driver exports it after the serial pre-pass. Sequential path
  unchanged.
- **Result:** local compiler build with `GCC_PARALLEL_TARGETS=1` GREEN —
  amd64 linked serially, arm64 + riscv64 cross-GCC concurrent (JOBS=16 each),
  both OK; two cross targets in ~531s wall vs ~984s sequential (~30% GCC-RUN
  saving, as documented). Full toolchain smoke 41/41 PASS, image
  `cross-compiler-amd64` loaded. This also validated TG1/TG3 (trimmed per-RUN
  mounts) and F2's toolchain call sites (`sccache gcc/g++` live).
- Follow-up logged: the ERR-trap in logging.sh `_install_trap` fired with
  `action` unbound under set -u when triggered outside the function's dynamic
  scope, masking the real apt error. Not in this wave.

### F2 media validation — PASS (sdk→media→android, amd64)

Full chain from sdk pushed for amd64. The one-resolver cache consolidation was
exercised in every media RUN: `compiler cache enabled:
launcher=/opt/scripts/core/sccache-launcher.sh`, **100 % C/C++ cache-hit
rate**, 27 artifact-verify OK, android built and pushed. modules.sh reorder and
the QNN-off fan-out path (litert/tvm/app-wheelhouse/genai with no zip) all ran
the new code without regression.

### 0371d164 — sccache-launcher server-death gap FOUND live + FIXED

The validation build caught a second failure class the guarded launcher did
not handle: the sccache **server died mid-build** under full concurrent-media
load and sccache reported `sccache: error: failed to execute compile / caused
by: Failed to send data to or receive data from server / failed to fill whole
buffer`. The launcher only bypassed on `sccache: encountered fatal error` (the
TryCompile ENOENT class), so it handed the dead-server error to ninja as a REAL
failure and killed the TVM step. Fixed by widening the bypass classification to
any sccache-prefixed internal error (`sccache: (encountered fatal error|error:|
caused by:)`) — safe because sccache prefixes only its own failures with
`sccache:`; a real compiler error is echoed un-prefixed and passes through.
Pinned by the new tests/test-sccache-launcher.sh (8 assertions incl. a
mutation case proving the old narrow match would NOT have bypassed). The media
rebuild running after this lands re-validates the fix live and restores the
TVM wheel lost to the dead server (the failure was non-fatal by design).

### QNN-LINUX fan-out validation — BLOCKED on the login-gated SDK

The real QAIRT zip is not on the host (removed after the PROVEN build per the
qnn-sdk README discipline; /tmp/qnn-sdk-extract now holds only a synthetic test
stub). Re-staging is the owner's move (qpm.qualcomm.com, EULA), then re-pin
`QNN_SDK_LINUX_ZIP_SHA256`. The no-zip fail-safe path across every framework
was validated by the media builds above.

## 2026-08-30 — second pass: --no-push chains SAFE (OCI-layout handoff) + source_module recursion fix

Backlog item C is closed: **full `--no-push` chains are no longer refused** —
every stage built locally is exported to an OCI layout and handed to the child
via `--build-context <parent-tag>=oci-layout://<dir>`, so a child's FROM never
resolves against the registry (the 2026-08-08 stale-parent bug). The android
image is additionally exported for the runtime lane, and the mid-chain resume
case stays refused (no locally-built prefix to serve).

- `01-core/cross-stage-build.sh` — `cross_local_handoff_enabled()`,
  `cross_ensure_local_context_workdir()` (per-run
  `${CROSS_CONTEXT_ROOT:-~/.cache/opencode/cross-stage-contexts}/cross-flow.*`,
  age-based orphan sweep), `cross_stage_context_dir()`; parent resolution in
  `_cross_stage_run_resolve_parent` appends the `--build-context` when the
  parent was built this run; `cross_stage_run` exports every local stage after
  the build, and android to `<workdir>/android-artifacts/<arch>`.
- `build-cross-chain.sh` — guard relaxed (full chain allowed, mid-chain
  refused; `CROSS_LOCAL_CONTEXT_HANDOFF=0` reverts, `CROSS_NO_PUSH_FORCE=1`
  bypasses), parse-time message + `--no-push` usage text updated,
  `run_runtime_stage` passes `ARTIFACT_CONTEXT_ROOT`+`ARTIFACT_CONTEXT_MODE=oci`
  to the helper under `--no-push`, `_chain_on_exit` reclaims the workdir.
- `01-core/modules.sh` — `source_module` resolves FRAMEWORK dirs before
  `${caller_dir}/${name}`. The old order made a bare
  `source` of ONNX's `build/lib/common.sh` (SCRIPT_DIR unset) resolve
  `source_module "common.sh"` to that very file — an infinite re-source loop
  ending in a stack-overflow SIGSEGV. All `source_module` names are 01-core
  modules, so the caller-local slot is now only a last resort.
- New suites: `tests/test-cross-oci-handoff.sh` (15 assertions — parent-context
  append, registry fallback when unbuilt, push=1 never, guard matrix incl.
  mutation-style refusal cases) and `tests/test-module-resolution.sh`
  (5 assertions — order, the ORT recursion shape under timeout, caller-local
  last resort; mutation-verified against the pre-fix `modules.sh`: 3/5 fail).
- Live-proven on the host: two-stage test build — stage B's `FROM` resolved
  from the exported layout (`--pull=false`, content marker verified), never
  the registry.
- Docs: AGENTS.md quick-ref, `docs/linux-cross-builds.md` § "--no-push full
  chains: FIXED", backlog C closed, archive entry.

## 2026-08-30 — Backlog sweep: F-entries closed (OpenCV-sccache refuted), one-resolver cache consolidation, QNN-LINUX fan-out wired

Three parallel threads, one day: the two remaining F-section items are gone
from the open backlog, the cache launcher resolution has exactly one resolver,
and the QNN-LINUX framework fan-out (GenAI/LiteRT/TVM/IREE) is wired on the
shared SDK module — all fail-safe by construction (no zip = byte-identical
existing behavior).

### OpenCV-sccache entry REFUTED, F2 DONE (docs/refactoring-backlog-archive-2026-08-30.md)

- **"sccache caches NOTHING in the OpenCV step" — closed by REFUTATION.** Log
  forensics on the staged-media* and media-arm64 logs showed the 2359 bypass
  messages the entry cited were the pre-UDS wrong-server bug (concurrent
  BuildKit steps reaching each other's sccache server on the fixed TCP port;
  `caused by: No such file or directory (os error 2)` — exactly what
  docs/build-cache-tiers.md § 5.1 already recorded as fixed by
  b4078ad1 + 4aa92fb6), and that the faults appeared in the ORT step too —
  not OpenCV-exclusive as claimed. Every post-UDS run has 0 bypass messages,
  including the 2026-08-30 QNN-LINUX arm64 media build, where OpenCV compiled
  all 1660 objects through the launcher and the sibling ffmpeg step recorded a
  99.64 % hit rate. No code change needed; the misdiagnosis is archived with
  the evidence so it is not re-discovered.
- **F2 — compiler-cache abstraction consolidation: DONE.** New
  `_resolve_compiler_cache_launcher()` in `01-core/compiler-cache.sh` routes
  every launcher decision through common.sh's `compiler_cache_launcher()`
  (all media/ORT callers) with an inline bootstrap fallback for the android
  preamble, which sources compiler-cache.sh standalone. Both paths implement
  the identical decision (guarded launcher > sccache > ccache, never empty);
  `setup_ccache` and `setup_sccache` both consume it; the
  verify-critical-fixes.sh gate still passes without edits. Pinned by the new
  suite `linux/scripts/tests/test-compiler-cache.sh` (8 assertions, incl.
  mutation checks and the "Rust keeps sccache-class on a ccache verdict"
  property). Behavior-identical by construction; a media run validates the
  stats lines.

### QNN-LINUX framework fan-out WIRED (validation build pending)

- **NEW `01-core/qnn-sdk.sh`** — shared QAIRT resolution + runtime staging,
  moved out of ORT's lib/common.sh (which now sources it and hard-requires the
  two functions). Unit-tested end-to-end against a synthetic QAIRT zip:
  resolution, sha256 verification, `libQnn*.so` + `hexagon-v*` staging, and
  the arm64/no-zip gates.
- `03-media/core/common.sh` — `media_common_init` loads `qnn-sdk.sh`
- `60-build-genai.sh` — stage QNN backend libs beside the GenAI install
- `build-litert.sh` — `TFLITE_ENABLE_QNN=ON -DQNN_HOME=<home>` + NPU=ON when
  a zip is staged (else the NPU=OFF/`QNN=OFF` defaults), in BOTH the cmake
  configure and the wheel `EXTRA_CMAKE_FLAGS`, plus post-install staging
- `tvm-config.sh` / `tvm.sh` — `USE_QNN=ON -DQNN_HOME=<home>` (else explicit
  `-DUSE_QNN=OFF`) in `append_tvm_cmake_args`, post-install staging in main;
  `tvm.sh` loads the module
- `build-app-wheelhouse.sh` — `IREE_TARGET_BACKEND_QNN=ON -DQNN_HOME=<home>`
  (else `OFF`); no runtime staging on Linux (wheel-only cross lane)
- `Dockerfile.media` — `linux/qnn-sdk` bind mount added to the litert, tvm
  and app-wheelhouse RUNs (was cpu/genai only)
- Every path is gated on a staged zip: no zip = today's behavior byte-for-byte
  (verified per-arch by the module tests). The validation build (staged QAIRT
  v2.49 on arm64) answers whether all five flags stay green and the libs land.


## 2026-08-30 — QNN-LINUX: Qualcomm QAIRT/QNN EP wired + PROVEN for Linux ARM64 (Snapdragon)

Wired the ONNX Runtime QNN execution provider onto the Linux `arm64` lane,
targeting Snapdragon NPU inference. Same opt-in contract as the Windows QNN
EP (#121): login-gated SDK zip dropped by hand in `linux/qnn-sdk/`; no zip =
QNN off with a notice. Different SDK from Windows: Linux AArch64 extracts to
`lib/aarch64-oe-linux-gcc11.2/`, not `aarch64-windows-msvc`.

**PROVEN on real SDK (2026-08-30):** staged QAIRT v2.49.0.260730,
`cross-media-arm64` build GREEN. `libonnxruntime_providers_qnn.so` compiled
and linked; 45 `libQnn*.so` backend libs + 7 `hexagon-v*` skel dirs staged
beside ORT; `verify-media-artifacts.sh onnxruntime-cpu` PASS; smoke suite 0
failures. The upstream QNN_ARCH_ABI risk is RESOLVED: ORT CMake accepts
`-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` (cache var, not hardcoded).

- `linux/qnn-sdk/README.md` — opt-in drop point + contract
- `.gitignore` — `linux/qnn-sdk/*` rule (symmetric with `windows/qnn-sdk/*`)
- `versions.env` — `QNN_SDK_LINUX_ZIP_SHA256` pinned to the staged zip's sha256
  (`32de9b5b...`, `# noforward`)
- `onnxruntime/build/lib/common.sh` — `resolve_qnn_sdk` (locate/verify/extract
  the SDK, QNN_OP_STFT canary) + `stage_qnn_runtime` (copy `libQnn*.so` +
  `hexagon-v*` skel beside ORT install). `info()` redirected to `stderr` (>&2)
  inside both functions to keep `$(...)` capture clean.
- `30-build-native.sh` — `resolve_qnn_sdk` called after oneDNN block; if
  arm64 + zip present, appends `onnxruntime_USE_QNN=ON` +
  `onnxruntime_QNN_HOME=<root>` + `QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2`;
  stages runtime after finalize
- `Dockerfile.media` — `linux/qnn-sdk` bind-mounted at `/opt/scripts/qnn-sdk`
  on the `--step cpu` and `--step genai` RUNs
- `verify-media-artifacts.sh` — `onnxruntime-cpu` stage: if QNN provider .so
  is present, asserts `libQnn*.so` are staged beside it
- `docs/linux-cross-builds.md` — QNN EP section in the toggles area
- `docs/refactoring-backlog.md` — `A2. QNN-LINUX` items 1-6 DONE+PROVEN;
  framework fan-out (GenAI, LiteRT, TVM, IREE) OPEN
4a3f379c05bd3affa3d9b2550f1b2cb4f9b3


## 2026-08-29 — #135 closed: patched LLVM is default, workarounds removed

### `BUILD_PATCHED_LLVM=1` is now the DEFAULT (#135 item 1+3 DONE)

The patched clang toolchain (llvm#219275 + #219276, the `EH_LABEL` size fix) is
now the default toolchain. Changes:

- `Dockerfile.toolchain-builder`: `ARG BUILD_PATCHED_LLVM=0` → `1`
- `build-buildkit.ps1`: `patched-llvm` is the default target; new `-StockLlvm`
  switch opts out (for patch debugging only); `-PatchedLlvm` kept as a no-op
  for backwards compatibility
- `build-opencv-from-source.ps1`: both AArch64 workarounds REMOVED — the
  `+force-32bit-jump-tables` flag and the per-TU `/Ob1` pass for
  `median_blur.dispatch` / `multiview_calibration`. The patched toolchain fixes
  the root cause (EH_LABEL under `/EHa` emits a 4-byte nop counted as zero by
  `getInstSizeInBytes`).
- `BuildKit.PatchedLlvm.Tests.ps1`: updated for the new default
- `SourceBuild.CrossHelpers.Tests.ps1`: removed the /Ob1 selector test (the
  selector it tested no longer exists)
- `docs/failure-modes.md`: updated the AArch64 codegen section — root cause
  found, workarounds removed, patched toolchain is the fix


## 2026-08-29 — amd64 acceptance build GREEN (#134 closed)

### #134 amd64 acceptance PASSED — three build fixes

The amd64 rebuild verified the `TVM_COMMIT` LLVM 23 fix and closed #134.
Smoke gate: **192 passed / 0 failed / 1 skipped**. Arch gate: **1134/0**.

Three bugs surfaced during the build, all fixed:

1. **`Invoke-GitClone` commit-hash support** — `git clone --branch <hash>`
   fails for commit hashes ("Remote branch not found"). Added commit-hash
   detection: clone without `--branch`, then `git fetch --depth 1 origin <hash>`
   + `git checkout <hash>`. Mirrors the Linux lane's tvm.sh approach.

2. **`SETUPTOOLS_SCM_PRETEND_VERSION` for TVM_COMMIT** — when `TVM_COMMIT`
   (a 40-char hash) wins over `TVM_REF` (a tag), the pretend-version was set
   to the hash, which crashes `packaging.version.InvalidVersion`. Now falls
   back to the tag's version (`0.26.0`) when the resolved version is a hash.

3. **`ARCH_GATE_MIN_INSPECTED` amd64 floor** — 950 was calibrated against the
   PE-binary count (1134) but the same value gates the import-walk count
   (701). Same miscalibration that was fixed for arm64 (840→580). Corrected
   to 650.

4. **Smoke section 10 CPU floor** — floor was 5 but the CPU lane produces
   exactly 4 assertions (the 5th is a GPU-only CUDA check). Corrected to 4.


## 2026-08-28 — Layer headroom dispute settled + backlog renewed

### Layer headroom settled — final image sits at ~75, not ~108

The docs said the final Windows image sat at "~108/125" layers; the audit
computed ~78. Counting the inherited chain's layer-creating instructions
(base 16 + nvidia 3 + toolchain 4 + media-merge 15 + torch 3 + final 2 = 43,
plus 20 ENV layers and ~12 from servercore = ~75) confirms the audit was
correct. The ~108 figure was the pre-ENV-consolidation count — the merge
builder's 28 ENV lines collapsed into 5 blocks removed ~23 layers. Updated
`docs/windows-build-invariants.md` and closed the backlog item.


## 2026-08-28 — Windows backlog #134 free follow-ups: smoke floor, pin parity, TVM fixtures, resource sampler


### Resource sampler wired into build-buildkit.ps1 (#134 free follow-up)

The per-run resource CSV (`build-resource-sampler.ps1`) was wired into the
classic `build.ps1` but not the BK driver, so no building driver produced it.
The BK driver now starts the detached sampler after preflight gates pass,
writes phase transitions at each `Invoke-BkStage` via `Set-BuildPhase`, and
stops it with a per-phase exhaustion summary in the `finally` block.
`-NoResourceLog` disables it; `-ConcurrentAux` children inherit
`-NoResourceLog` (the parent's sampler covers the whole machine). Pinned by
`BuildDriver.ResourceSampler.Tests.ps1` (6 tests).

## 2026-08-28 — Windows backlog #134 free follow-ups: smoke floor, pin parity, TVM fixtures

### Arm64 smoke floor RECALIBRATED — 85 was above the section sum (#134)

The arm64 global smoke floor was raised 66 → 85 in the earlier "tightened"
entry below, but 85 EXCEEDS the arm64 section-floor sum of 72
(`Smoke.FloorCalibration.Tests.ps1` enforces `armFloor ≤ armSum`). A run
sitting exactly at every section floor — a legitimate result — would have
FAILED the global gate. Reverted to 66 (≤ 72, ≥ 90% of 72). The §19 PROVISIONAL
marker in `smoke-test-container.ps1` removed: three green arm64 runs confirmed
the floor.

### SourceBuild.PinParity — TVM_REF → TVM_COMMIT (#134 follow-up)

`build-tvm-from-source.ps1` now reads `TVM_COMMIT` first (the commit-hash
override for the LLVM 23.1.0 break). The pin-parity scanner-rot guard still
expected `TVM_REF` as the resolved key and compared the `-DefaultValue 'v0.26.0'`
against `TVM_COMMIT=994e0216...` (a commit hash, not a tag). Fixed: the
scanner-rot guard expects `TVM_COMMIT`; a `DefaultValueKeyOverride` map
redirects the DefaultValue comparison to `TVM_REF` (the tag the fallback is
actually baked from), so the tag-fallback semantics are preserved.

### TVM assembled-wheel fixtures — single-quoted backtick-n fixed (#134 follow-up)

Two `SourceBuild.TvmAssembledWheel.Tests.ps1` fixtures passed single-quoted
`` `n `` to `Get-VendoredTvmFfiVersion` and `Get-PyprojectDependencies`. In
single-quoted PowerShell strings `` `n `` is the literal two characters
backtick-n, NOT a newline — the pyproject parse was never exercised against
its real input shape. Converted to double-quoted strings with real newlines.

### Merge-stage script test coverage (#134 free follow-up — the last open item)

The three arm64 cross-lane correctness scripts had no dedicated test suite.
All three now do (39 tests total, all green):

- `SourceBuild.VerifyTargetArch.Tests.ps1` (20 tests) — lifts
  `Get-CoffMachine`, `Get-ArchiveMachine`, `Format-Machine` out of the
  script's AST and tests against synthetic PE/COFF/archive fixtures. Covers
  AMD64/ARM64/ARM64EC PE images, COFF objects, short-import and raw-object
  archives, linker-member skipping, and the malformed/truncated/missing-file
  null paths — including the `Get-ArchiveMachine` bound that was fixed in
  production (the +6 bound was two bytes short), not by a test.
- `SourceBuild.StageTargetPythonDeps.Tests.ps1` (10 tests) — lifts
  `Get-WheelDistName`, `Get-RequirementName`, `Get-WheelRequirements` and
  tests PEP 427 name extraction, requirement parsing (version bounds,
  parenthesised versions, extras-dropping), and wheel METADATA reading via
  synthetic .whl ZIP archives.
- `SourceBuild.BundleManifest.Tests.ps1` (9 tests) — runs
  `write-bundle-manifest.ps1` against a synthetic bundle tree with
  `WINDOWS_TARGET_ARCH` set, verifying the three output files
  (`BUNDLE-ENV.cmd`, `BUNDLE-ENV.ps1`, `BUNDLE-README.md`) for both amd64
  and arm64, including ENV-var registration, the cross-build caveat, and
  ABSENT-marker recording.

Suite total: 726 → 765 tests (764 pass; 1 pre-existing environmental
`Assert-ShimPatch` #48 failure — the shim IS installed on this host, so the
"no shim" branch can't throw).


## 2026-08-28 — TVM-vs-LLVM-23.1.0 fix, sccache pin bump, deps gate floor, smoke floor tightened

### TVM LLVM 23.1.0 API break — FIXED (code, not yet rebuilt)

The Windows TVM build used `TVM_REF=v0.26.0` (the tag without LLVM 23 guards).
The Linux lane already used `TVM_COMMIT=994e0216` (upstream main, with
`TVM_LLVM_VERSION >= 230` guards). Fix: `build-tvm-from-source.ps1` now reads
`TVM_COMMIT` first; `Dockerfile.media-builder` ARG/ENV updated to forward it.

### sccache — #137 DONE

`SCCACHE_GIT_REV` bumped `ffac4a5` to `8ab39266` (main HEAD, both PRs #2811 +
#2816 merged). The 0003 patch file and `windows/upstream/sccache-nvcc-quote-fix/`
deleted. `Dockerfile.base` COPY of the patch dir removed. Comments updated in
`setup-rust-toolchain.ps1`, `Dockerfile.base`, `Dockerfile.media-builder`.

### Target python deps gate — floor added (#134 free follow-up)

`stage-target-python-deps.ps1` gains `-MinBundleWheels` and
`-MinFirstTouchRequirements` parameters — a drop in wheel or requirement count
is now a hard failure (the run-34/35 defect class: empty `Requires-Dist` from a
CRLF regex bug made the gate greener, not red). Wired through
`Dockerfile.media-merge-builder` ARGs and `build-buildkit.ps1` arch-args
(amd64: 6 wheels / 10 reqs; arm64: 6 wheels / 8 reqs).

### Arm64 smoke floor tightened (#134 free follow-up)

`armMinPassed` 66 to 85, `armMaxSkipped` 25 to 20. The old floor tolerated
losing 32% of assertions; three green runs (97 passed) justify tightening to
~12% headroom.



### #134 acceptance run

**ARM64: ALL GATES GREEN** (run `bk-20260828-171914`, ~1 h 10 min). arch gate
992/0; import walk 606/0 (3 allowlisted, 6 device-OS); smoke 97/0/15;
GStreamer contract plugins 6/6; OpenCV 1870/1870 with zero #135 codegen
errors; `tvmmods` stage mounted and built clean; TVM runtime wheels
(`apache_tvm`, `apache_tvm_ffi`) + IREE runtime wheel all `0xAA64`. This
proves the module-closure unshare, the three leaf modules, `tvmmods`, and
the deleted classic stages are sound on the cross lane.

**AMD64: BLOCKED in TVM compiler** (run `bk-20260828-190313`). TVM 0.26's
`codegen_llvm.cc` uses `llvm::Intrinsic::matchIntrinsicSignature` /
`MatchIntrinsicTypes_*` removed/renamed in LLVM 23.1.0 — 8 compile errors.
The arm64 lane is unaffected (runtime-only, no compiler). Media-core,
FFmpeg, OpenCV, LiteRT, and LiteRT-LM all passed on amd64. This is a
TVM-vs-LLVM API break, not a #134 defect, but it blocks the amd64
acceptance criterion until patched or `LLVM_WINDOWS_VERSION` is reverted
for the TVM compiler build.

### Three fixes that landed during the acceptance run

1. **`SCOOP_INSTALLER_SHA256`** bumped `84242117…` to `94f983b1…` — scoop
   rotated `get.scoop.sh` again (verified against GitHub raw master, Unlicense
   header, 787 lines). Updated `versions.env` + `Dockerfile.base` ARG default.
2. **Arm64 OpenSSL URL** bumped `Win64ARMOpenSSL-4_0_1` to `4_0_2` — slproweb
   404'd the old version. Updated `setup-scoop-tools.ps1` (URL + SHA256:
   `5d2653ef…`). Without this, the arm64 GStreamer merge stage throws on the
   missing `C:\opt\openssl-arm64\libcrypto.lib`.
3. **`ARCH_GATE_MIN_INSPECTED`** for arm64 corrected 840 to 580 — 840 was set
   against the arch-gate binary count (992 minus 15%), not the import-walk file
   count (606). Updated `build-buildkit.ps1`. The gate was failing a healthy
   run that inspected exactly the expected 606 files.

### Backlog changes

- **#122** (CUDA on arm64) — CLOSED by owner decision (no near-term plan).
  Phase-0 probe moved to `windows-backlog-archive-2026-08-26.md`.
- **#136** (VS RUN never cached) — archived (solved + deployed 2026-08-26).
  Narrative moved to `windows-backlog-archive-2026-08-26.md`.
- **#137** (sccache patch droppable) — probe done: both PRs merged upstream,
  0003 patch fails `git apply --check` against `8ab39266` (main HEAD). Plan
  written; not executed (base-layer change, own window).

### Doc updates

- `windows-build-lanes.md` — a Stevedore *update* (not just a reinstall) can
  wipe the buildkitd service `Environment`; check after any update.
- AGENTS.md — same note added to the "Four things an agent gets wrong" section.

## 2026-08-28 — Closure window: enable + decision batch

Closed six backlog items (LOG12, GCC_HOST_BOOTSTRAP, LOG2, two-caches-installed,
GPU bare-sccache sites, TVM launcher) in one commit. All touch closure files
(01-core / 02-toolchain / 03-media / 05-frameworks), so batching minimizes
cache invalidation.

- **LOG12** — `build-armnn.sh`: added `-DARMCOMPUTENEON=1` to enable the ACL
  NEON (CPU SIMD) backend. CL stays OFF (no GPU in cross-build container).
  A real build may surface an ACL cross-link break — the backlog item's
  predicted "actual news".
- **GCC_HOST_BOOTSTRAP** — `Dockerfile.toolchain`: changed default from 1 to 0.
  The flag already existed (gcc.sh:171-200); `=0` skips the ~1231 s bootstrap
  for validating rebuilds, `=1` only when the GCC pin moves. Decision owed
  since 2026-08-10.
- **LOG2** — The WASM asyncify/jspi build passes already existed
  (`40-build-wasm.sh` passes 4+5, `ORT_WASM_WEBGPU_FLAVORS=true` by default).
  Updated the stale versions.env comment that said "not built". Watch: a real
  build must confirm the artifacts ship on all arches.
- **GPU bare-sccache** — `build-opencv.sh`, `30-build-native-nvidia.sh`,
  `30-build-native-amd.sh`: replaced bare `sccache` with
  `compiler_cache_launcher()` resolution (sccache-class only — ccache can't
  wrap nvcc/hipcc). The guarded sccache-launcher.sh is preferred when mounted.
- **TVM launcher** — `tvm-config.sh`: added `CMAKE_C/CXX_COMPILER_LAUNCHER`
  via `compiler_cache_launcher()` in `append_tvm_cmake_args()`. Overrides
  TVM's internal `USE_CCACHE=AUTO`.
- **Two-caches-installed** — `compiler-cache.sh`: documented the decision:
  both ccache and sccache stay mounted. sccache is primary; ccache is the
  documented fallback. The ~27 GB warm ccache is the intentional cost.

Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (closure window — enable + decision batch)".


## 2026-08-28 — Closure window: 01-core/02-toolchain backlog batch

Closed six backlog items (LOG8, LOG13, LOG14, LOG17, LOG18, LOG19) plus the
ffmpeg/pyav compiler-cache resolution, all in one commit. These touch files
in the 01-core / 02-toolchain / 03-media bind-mount closure, so batching
minimizes cache invalidation (one edit re-runs hours of compiles). LOG12 was
documented (reference-backend-only by design) but remains OPEN as a decision
item.

- **LOG8** — `Dockerfile.media`: added per-stage apt mount ids to the six
  parallel media head stages (onnx, litert, tvm, opencv, app-wheelhouse,
  ffmpeg). Each head vertex now holds its own apt lock instead of a shared
  one, so they no longer serialize the intra-lane fan-out. The memory
  caveat (peak 43.6 GB) still applies — PAR4-hard remains the real cap.
- **LOG13** — `android-build-preamble.sh`: `android_build_preamble_init` now
  sources `compiler-cache.sh`, calls `setup_ccache` + `setup_lld_linker`. The
  android stage gets the same `compiler_cache_launcher()` resolution as the
  media lane; android-iree (was the only genuinely uncached android lib) now
  resolves through the launcher. RUN blocks stay byte-identical.
- **LOG14** — `vulkan.sh`: added nine host-only Vulkan components to the
  `_vulkan_skip` map for cross builds (ValidationLayers, shaderc,
  SPIRV-Cross, SPIRV-Reflect, Vulkan-Profiles, Vulkan-ExtensionLayer, volk,
  VMA, vul). Cross lanes no longer build ~390 s/lane of host x86_64 components
  with no cross consumer.
- **LOG17** — `versions.env`: added `ANDROID_AGP_VERSION=8.3.1` and
  `ANDROID_GRADLE_VERSION=8.7` as visibility pins. The actual version still
  lives in the ORT AGP patch; a bump must sync both. The Gradle 9.0
  deprecation warning is now visible to `bump_versions.py --check`.
- **LOG18** — `cpython-dev-packages.sh`: added `libmpdec-dev optional _decimal`
  row to `_CPYTHON_EXT_DEV_PKG_TABLE`. Marked OPTIONAL because promoting to
  required flips all three arches to dynamic `libmpdec.so` with so-package-map
  consequences. Documents the gap; harmless until Python 3.16 (~Oct 2027).
- **LOG19** — Replaced positional `head -N` with `grep -E` for sccache stats
  in `compiler-cache.sh`, `build-gcc.sh`, `probe-sccache.sh`,
  `03-media/core/common.sh`. Added `dump_compiler_cache_stats()` to
  `compiler-cache.sh` (post-build stats dump with dead-cache WARN), wired via
  an EXIT trap in `media_common_init` so every media step reports cache
  telemetry at END of build, not at t≈0.165 s before the first object.
- **ffmpeg/pyav** — `build-ffmpeg.sh` and `build-pyav.sh`: replaced hardcoded
  `ccache ${CC}` with `compiler_cache_launcher()` resolution so sccache is
  actually asked (was always ccache).
- **LOG12** — `build-armnn.sh`: added documentation comment explaining the
  reference-backend-only design. The decision (turn on backends or drop ACL)
  remains OPEN.

Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (closure window — 01-core/02-toolchain batch)".


## 2026-08-28 — Closure window: 03-media/06-packaging backlog batch

Closed seven backlog items (LOG9, LOG21, LOG24, LOG26, LOG31-COPY'd, LOG32,
LOG35) in one commit — all touch files in the 03-media/06-packaging bind-mount
closure, so batching minimizes cache invalidation (one edit re-runs hours of
media compiles).

- **LOG31 (COPY'd half)** — `validate-media-runtime.sh`: DENIED class
  (source-built SONAME missing) now exits 1 instead of WARNING. The broader
  unresolved/unmappable classes stay advisory (vendor trees need excluding
  first). `smoke-android.sh`: ndk-build and aapt2/zipalign/apksigner now have
  fail branches.
- **LOG32** — Added Vulkan smoke to `smoke-media.sh`: vulkan.h present, active
  symlink resolves, glslangValidator runs. ~7 GB of Vulkan SDK now gated.
- **LOG35** — `verify-media-artifacts.sh`: replaced broken `verify_A || verify_B`
  lib→lib64 fallback with `verify_any_lib`. Added `libvvdec` to FFmpeg codec
  check loop. Added `/opt/cmake` functional assertion to `smoke-media.sh`.
- **LOG9** — `build-gstreamer-monorepo.sh`: arm64 cross builds now keep
  introspection ENABLED when qemu g-i wrappers exist (pre-setup.sh already
  creates them for arm64). Was 0 .typelib on arm64; should match riscv64's 38.
- **LOG21** — Documented OpenCV cross arches as headless-by-design (GTK's
  libpango1.0-dev not multiarch-coinstallable). Added smoke assertion that
  confirms `GUI: NONE` is deliberate on cross, fails on native.
- **LOG24** — OpenCV DNN ONNX Runtime backend enabled
  (`-DWITH_ONNXRUNTIME=ON -DDOWNLOAD_ONNXRUNTIME=OFF`). Added smoke assertion
  for the ORT backend via `cv2.dnn.getAvailableBackends()`.
- **LOG26** — OpenCV: added `-DWITH_AVIF=ON -DWITH_HDF5=ON
  -DOPENCV_ENABLE_NONFREE=ON` + `libavif-dev`/`libhdf5-dev` to install-deps.
  Documented riscv64-only `USE_OPENMP=0` rationale in build-app-wheelhouse.sh.
  FFmpeg: added `libpulse-dev` for PulseAudio indev/outdev.

## 2026-08-28 — Host-only backlog fixes (LOG33, LOG31-preflight, Section C)

Closed three backlog items that touched only host-only scripts (not COPY'd or
bind-mounted into any Dockerfile), so no closure window was needed.

- **LOG33** — `verify-shipped-wrapper.sh`: promoted onnxruntime .so presence
  (check 3) from advisory to HARD — the image is built around ORT, so its
  absence is always a defect. Promoted AP4 strip (check 5) from advisory to
  HARD when the sentinel lib was successfully extracted — a surviving .symtab
  means the MEDIA_STRIP pass regressed. Kept advisory only when extraction
  failed. Four hard assertions now (was two).
- **LOG31 (preflight half)** — `lint-env-knobs.sh` was advisory by default
  (exits 0 unless KNOB_GATE=1) and preflight invoked it without KNOB_GATE=1;
  also its `if [ -f ]` guard had no `else` (silent drop on missing file).
  Fixed: preflight now passes `KNOB_GATE=1` and has the FAIL-not-skip `else`
  contract. Three unowned operator knobs (BUILD_ATTEST, CROSS_DISK_GUARD_GB,
  NO_CACHE_EXPORT) added to `lint-env-knobs.allow`. `verify-runtime-paths.sh`
  was "ADVISORY ONLY — never fails" — now fails hard on infrastructure errors
  (missing reference/Dockerfiles) while keeping heuristic path-mismatch WARNs
  advisory. The COPY'd half (validate-media-runtime.sh, smoke-android.sh)
  remains open — needs a closure window.
- **Section C** — `build-cross-chain.sh`: added `_chain_no_push_guard()` that
  refuses `--no-push` for multi-stage runs on this host (BuildKit's OCI worker
  resolves FROM against the registry — two runs lost 2026-08-08). Single-stage,
  dry runs, and `CROSS_NO_PUSH_FORCE=1` escape hatch allowed. Updated AGENTS.md
  Quick Reference and usage text.

Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (host-only fixes)".


## 2026-08-28 — ROCm 10.0 migration (TheRock distribution)

Migrated the AMD GPU lane from ROCm 7.2.4 to 10.0, moving from the legacy
`repo.radeon.com` apt layout to AMD's new "TheRock" distribution at
`stable.repo.amd.com`.

**Changes:**
- `versions.env`: `ROCM_VERSION` 7.2.4 → 10.0, `MIGRAPHX_VERSION` 2.14.0 → 2.17.0,
  `ROCM_GPG_KEY_SHA256` updated for the new signing key.
- `setup-rocm-repo.sh`: rewritten to deb822 `.sources` format with two repo
  stanzas (core + migraphx) at `stable.repo.amd.com`, suite "stable", for
  Ubuntu 26.04 (resolute). Package names migrated to `amdrocm-*` prefix.
  apt pin Origin changed from `repo.radeon.com` to `AMD ROCm`.
- `Dockerfile.amd`: ARG defaults updated; comment updated to reflect TheRock.
- `bump_versions.py`: `rocm_apt_latest()` now parses the TheRock Packages.gz
  instead of scraping the old directory listing.
- Docs updated: AGENTS.md GPU constraints note, linux-accelerator-images.md.
- No more noble (24.04) fallback — resolute is natively supported by TheRock.

**Not yet verified with a real build** — the post-install assertions
(`hipcc`, `migraphx.hpp`, library names in ldconfig) are carried over from
the old script and may need adjustment if TheRock installs to different paths.


## 2026-08-28 — Linux backlog maximality audit: 16 code fixes

Closed 16 open Linux backlog items (LOG10,11,15,16,20,22,23,25,29,30,36,37,38,
39,40,41) found in the 2026-08-28 maximality audit. Each fix includes the
assertion or smoke check the backlog asked for. Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (code fixes)".

**Build fixes (01-core / 03-media closure — needs a rebuild to land):**
- LOG16: `CMAKE_POLICY_VERSION_MINIMUM` lifted to `versions.env`; 8 bare `=3.5`
  literals across 6 files replaced with `${CMAKE_POLICY_VERSION_MINIMUM:-3.5}`
  (or `:=3.5` in android scripts to avoid the version-forwarding tripwire).
- LOG20: FFmpeg `drawtext` filter — added `libharfbuzz-dev` + `libfontconfig1-dev`
  and `--enable-libharfbuzz`/`--enable-libfontconfig` probes.
- LOG22: FFmpeg `*_vulkan` filters — added `glslang-tools` to `install_deps_preamble`
  so `glslangValidator` is on PATH at configure time.
- LOG23: CPython readline + curses — added `libreadline-dev` (required) and
  `libncurses-dev` (optional) to `_CPYTHON_EXT_DEV_PKG_TABLE`.
- LOG11: OpenCV TBB on all arches — moved `libtbb-dev` from host to
  `target_packages` so cross lanes pull the target-arch package.
- LOG15: android OpenCV `BUILD_JAVA=ON` → `OFF` (produced no Java wrappers anyway).
- LOG10: Fixed false RVV comment in `opencv/android/build-android.sh`.
- LOG25: Added rationale comment for LiteRT GPU/NPU delegates OFF.
- LOG36: Added `libtvm*.so` to `copy-media-payloads.sh` allowlist +
  `so-package-map.txt` + `verify-media-artifacts.sh` media-inputs stage.

**Gate fixes (06-packaging / smoke):**
- LOG29: `_runtime_run_package_smoke()` in `runtime-build-fns.sh` builds the
  `--target wrapper-smoke` stage between package and wrapper (`WRAPPER_SMOKE_GATE=0`
  to skip). Unit test `test-runtime-smoke-gate.sh` (8 assertions).
- LOG30: `_smoke_optimization_level()` in `validate-compilers.sh` checks CPython
  `sysconfig.get_config_var('OPT')` for `-O0`/missing `-O`.
- LOG11/15/20/22: Added smoke assertions: TBB parallel framework, Java wrappers
  absent, `drawtext` registered, `scale_vulkan` registered.

**Doc fixes:**
- LOG37: `cross-build-verification.md` — wrapper-smoke runs as a separate
  `--target wrapper-smoke` build.
- LOG38: AGENTS.md — corrected the `PartOf` binfmt claim.
- LOG39: `linux-accelerator-images.md` — fixed all NVIDIA/AMD build recipes
  (`:sdk` → `:cross-sdk-amd64`, `--output type=image` → `-t ... --push`).
- LOG41: `overview.md` / `linux-cross-builds.md` — removed `:latest` references.
- LOG40: Verified license/SBOM gates green — no drift.

## 2026-08-28 — correction: the `/Ob1` half was NOT llvm#202716, and the census says so

**Correcting the entry below, not deleting it.** The 2026-08-27 pass credited the
`tbnz` / `/Ob1` half of #135 to
[llvm#202716](https://github.com/llvm/llvm-project/pull/202716). That
attribution is wrong.

**The argument is the patch set, not the census.** The two local patches in
`AArch64InstrInfo.cpp::getInstSizeInBytes` fix the lane on pinned LLVM 23.1.0,
a compiler that contains **no** #202716 — the release branch forked before it
and nobody backported it, which is the entry below's own finding. A fix that is
absent cannot be the fix that worked.

**The 1,869-object census is a claim, not an artifact.** It was run by hand
inside the container and left no `bk-` log; nothing in `out/windows-build-logs/`
mentions either knob or `llvm-patched`. Re-run it through the driver and keep
the log before deleting either OpenCV workaround. Corrected here the same day
it was written.

**Both OpenCV workarounds trace to the SAME under-count.** `EH_LABEL` is a meta
instruction and reports 0 bytes, but under async EH (`/EHa`, module flag
`eh-asynch`) `AsmPrinter` emits a 4-byte nop after it when the next instruction
can fault. Four bytes go missing per label. `AArch64CompressJumpTables` picks a
too-small entry from the short span; `BranchRelaxation` believes a branch is in
reach when it is not. One defect, two consumers, two different error strings —
which is why they looked like two bugs for as long as they did.

**Same inference error, third occurrence.** Each time: an upstream commit whose
description matched the symptom, credited without checking whether the compiler
under test actually contained it. The rule that catches it is cheap — name the
artifact that decides the claim, then confirm the claim is falsifiable against
it.

**What changed on disk:** the root-cause blocks in `docs/failure-modes.md`,
`docs/windows-refactor-backlog.md` § #135 and
`out/upstream-llvm-aarch64-seh-instsize.md` now say EH_LABEL, not #202716. Both
workarounds STAY in `build-opencv-from-source.ps1` until `BUILD_PATCHED_LLVM`
defaults to on — the patched compiler is opt-in, and the stock one still
miscounts.

## 2026-08-27 (second pass) — #135 was two bugs wearing one signature; one is fixed upstream and nobody backported it

**The "one defect at two sites" reading was wrong, and it cost an investigation.**
`fixup value out of range` and `value evaluated as <N> is out of range` share a
sentence — *LLVM lays a function out a few bytes short* — and nothing else.

**The `tbnz` half: root cause found, fix already exists.**
[llvm#202716](https://github.com/llvm/llvm-project/pull/202716) (`c6e184686cd7`)
creates trampoline blocks with offset **zero**, so `isBlockInRange()` decides
branch reach from offsets the code itself calls "slight underestimates". On
`main` since 2026-07-21 — but `release/23.x` forked **2026-07-14**, one week
earlier, so 23.1.0 ships without it, and no cherry-pick exists on the branch.
Checked by subject AND PR number, not just SHA ancestry: a cherry-pick carries a
different SHA, and that hole produced one wrong "not backported" claim before it
was closed properly. **Proven load-bearing rather than assumed** — reverting only
that commit and re-running its own `branch-relax-tbz.mir` changes the output: with
the fix the `TBZW` survives onto a trampoline chain, without it the branch is
inverted and the layout moves.

**The jump-table half: NOT fixed on `main`, and narrowed to one number.**
`AArch64CompressJumpTables.cpp` is **byte-identical** between 23.1.0 and `main`.
The pass is provably sound *given correct instruction sizes* — offsets are upper
bounds, the inflation accumulates in layout order, so `Span` is over-estimated,
which picks a **larger** entry. It can only fail on an instruction that reports
**fewer** bytes than it emits, and the measured `N` bound that under-count to
**4–116 bytes**.

**LLVM already ships the tool that would name it — and AArch64 never turned it
on.** `AsmPrinter` verifies reported size against emitted bytes and aborts naming
the instruction, but `getInstSizeVerifyMode()` defaults to `NoVerify` and only
AMDGPU and PowerPC override it. The AArch64 opt-in is written and committed
locally (`aarch64-instsize-verify`, `65a5bd5601fe`, unpushed). Over the **2,925**
`.ll` files in `test/CodeGen/AArch64` at `aarch64-pc-windows-msvc` (2,049 compiled):
**zero under-counts**; a separate signature scan over 3,347 files (`.ll` + `.mir`)
found **zero genuine reproductions**. So the culprit is a construct LLVM's own
tests never build — it needs the real `descriptor.cc`, in the container. The one
apparent hit was self-inflicted, a Linux/PIC test forced onto a Windows triple.

**A third bug fell out of that scan:** every `SEH_*` pseudo reports 4 bytes and
emits **0** (538 of the 2,925). Over-estimate, so it is conservative and causes
neither failure — but it inflates every Windows-AArch64 estimate.

**Decision (owner): move the Windows toolchain to LLVM `main`; do not request a
`release/23.x` backport.** A request was drafted and deliberately not filed. The
consequence to plan around: the fix reaches a tagged release only in **24.1.0**
(~Feb–Mar 2027 on the observed 6-month major cadence), so `/Ob1` stays until the
toolchain actually moves, and **`+force-32bit-jump-tables` stays regardless**.

**Also landed:** `repro-llvm-aarch64-layout.ps1`, the A/B that settles "does this
compiler retire the workaround" in seconds instead of a lane run — the real
offenders frozen as preprocessed `.i`, gated on control arms that must reproduce
the abort and then suppress it, so a stale corpus reports `INVALID` instead of a
false green. Its command-line surgery is pinned by
`Diagnostics.Llvm135Repro.Tests.ps1` against the real ninja command line; writing
those tests caught two live bugs in it, both the case-insensitive `-match` trap.
The `:lo12:` catchret PR ([llvm#219200](https://github.com/llvm/llvm-project/pull/219200))
was rebased onto latest `main`.

## 2026-08-27 — the registry gets a second tool, and Rust caching turns out to have been bare all along

**Registry: 81 -> 34 tags, 204 -> 134 versions, 0 failures.**
`ghcr-prune-package.sh` deliberately keeps every TAGGED version, which left the
other half of the mess untouched. New sibling **`ghcr-delete-tags.sh`** deletes
NAMED tags from an explicit list — it never decides what is legacy — with the
same fail-closed keep-set: abort if any kept tag is unreadable, skip a version
that shares a digest with a kept index child, carries a tag not on the list, or
is younger than `KEEP_DAYS`.

What went: 22 `*-buildcache` tags that nothing has written since the cache
self-defeat fix (`verify-critical-fixes.sh` already *forbids* their return), 19
tags from a naming scheme the chain abandoned (`media-cross-amd64` ->
`cross-media-amd64`, `latest-cross-runtime-*` -> `latest-cross-*`), and the six
long-dangling index tags. All 47 had zero references anywhere in the repo.

**`:latest` was already broken and is now gone.** Its three children had been
404 for months — `python-ci-linux.yml:118` had quietly worked around it. Worth
stating plainly: it will not come back by itself. Every orchestrator under
`linux/scripts/` is a `build-cross-*` script, so the native lane has no build
path any more; keeping it means writing one, not running one.

Both tools now source **`ghcr-common.sh`**. The thirteen byte-identical lines
were the visible half; the important half is that the Accept header is now
defined ONCE. Listing the index media types makes a multi-arch tag resolve to
its index so its children are visible — omit them and the tag collapses to one
platform manifest, which is precisely how a prune tool builds a short keep-set
and deletes something it should not.

**`setup_sccache` pointed `RUSTC_WRAPPER` at BARE sccache.** The Rust caching
reinstated in 4200f7b never took effect: `build-gstreamer-monorepo.sh` only
assigns the wrapper when the variable is UNSET, and `setup-gstreamer.sh:50`
calls `setup_sccache` first, which exported `RUSTC_WRAPPER="sccache"`
unconditionally. Measured on the live media lane — the run logged
`RUSTC_WRAPPER=sccache`. Every Rust compile in gst-plugins-rs went through the
one thing AGENTS.md forbids; an sccache hiccup would have aborted the build at
99% instead of costing cache hits. Third time this class has shipped inert, so
it now has a gate in `verify-critical-fixes.sh` rather than another comment,
mutation-checked in both directions.

A 12-agent documentation audit (every finding adversarially refuted, 71 raw ->
**40 confirmed**) is recorded in the backlog. `docs/build-cache-tiers.md` alone
carries 11 and still argues from the ccache world.

**The runtime stage died on a missing emulator, and the guard that should have
caught it sat after the builds it protects.** The 2026-08-26 nerdctl-full
upgrade restarted the rootless daemons; the QEMU binfmt registration lives in
the rootlesskit namespace and went with it. Media and android never noticed —
they cross-compile on amd64. Both foreign-arch wrappers then died with a
BuildKit step that printed nothing at all. `ensure_foreign_binfmt()` already
existed and was correct; it was called from the SMOKE block. Moved before the
build loop and upgraded from best-effort registration to a hard verify that
looks inside the rootlesskit namespace, because the host's own
`/proc/sys/fs/binfmt_misc` shows nothing even on a healthy machine.

The durable cause was one line deeper. `setup-rootless-binfmt.sh
--install-service` writes a unit with `After=`/`Wants=` only — startup ordering,
no restart propagation — and `Type=oneshot` + `RemainAfterExit=yes` makes
systemd treat it as permanently done. On this host the unit last ran
2026-08-09 while containerd restarted 2026-08-26: enabled, "successful", and
its effect gone for seventeen days. The template now sets
`PartOf=containerd.service`.

**The index was never gated for freshness.** `verify-shipped-wrapper.sh` gates
each wrapper's content and the chain runs it; the only manifest check was
`nerdctl manifest inspect >/dev/null`. New
`linux/scripts/verify-manifest-freshness.sh` asserts every index child equals
its per-arch tag and that all children share one run-id. Sensitivity-checked
against a genuinely stale live index, which showed both assertions are
individually blind: child and tag agreed because both were old, and the run-ids
matched because all three came from the previous run. Agreement is not
freshness; only `EXPECT_RUN_ID` pins it. Not yet wired into the chain.

**Gate hygiene, three findings.** The shellcheck sweep never covered
`linux/host-config` — seven scripts outside it, including the one that replaces
the container daemon and the two that delete from the registry (263 files now).
`test-compiler-cache-launcher.sh` had been inert since the day after it landed
(`_COMMON_SH_DIR` unset under `set -u`), so the suite written to catch a stdout
leak caught nothing; fixed and extended with the guarded-launcher preference
case. And the secret scan was reading 5.3 GB of gitignored build logs, where
its only nine "leaks" were one public GPG-key checksum — scoped out, 2.42 GB
and clean.

Documentation: the 40 confirmed defects from the audit are repaired (see
above), and `nerdctl compose build webserver` turned out to be broken —
`security-headers.conf` was the one COPY source without a `.dockerignore`
negation, found by running the documented command instead of reading it.

### Later the same day — the pre-rebuild sweep, and what it cost to be sure

Before committing to another multi-hour run, a 12-agent sweep plus five
targeted 42-second tvm-stage probes went looking for whatever would break it.
Seven things would have.

**TVM had not shipped on arm64 or riscv64 for some time, and four separate
causes were stacked on top of each other** — each only visible once the one
before it was fixed:
1. v0.26.0 does not compile against LLVM 23 (three files, two API redesigns).
   amd64 escaped it by linking the distro `llvm-config-21`.
2. Pinning `TVM_COMMIT` to upstream's fix exposed that the SHA clone path
   never initialised submodules — it clones without `--recursive` and the
   submodule update only fires when the checkout MOVES `HEAD`, which pinning
   the default-branch HEAD does not. CMake died on an empty `3rdparty/tvm-ffi`.
3. The target-Python sysconfigdata lookup used `-maxdepth 2` while this chain
   stages the file at depth 3. The miss is silent in effect: the wheel then
   carries the BUILD-HOST SOABI and is correctly withdrawn, so the stage
   reported "TVM build OK" and shipped an image without `import tvm`.
4. A hand-written LLVM-23 patch, tried first, fixed four of five sites in one
   of three files and logged success. Removed rather than grown — a patch that
   cannot succeed but says it did is worse than none.

Result, measured: `apache_tvm-0.26.dev1-py3-none-linux_aarch64.whl` plus its
correctly-stamped `cp314` ffi sibling, where the stage previously died at
object 334.

**Two defects would have aborted the chain outright.** `build-cross-chain.sh`
ran `du … | cut -f1` twice without `|| true`, which under `set -euo pipefail`
kills the orchestrator with a bare exit 1 right after a stage SUCCEEDS — the
identical bug was already found and fixed 86 lines above, comment and all.
And the runtime package OCI export dropped its exit status while the next line
deleted the local image, so a ~27 GB `nerdctl save | tar -x` dying on ENOSPC
was reported as a successful build with its only copy destroyed. errexit cannot
help there: `run_parallel_arch_loop` disables it for the whole call tree, which
is exactly why the base path 42 lines below already carried `|| return 1`.

**The shipped Node.js is an alpha.** `node --version` in the published amd64
image returns `26.8.0-alpha.0.0.0`, and the bundled npm 11.19.0 refuses it —
semver puts a prerelease outside `^20.17.0 || >=22.9.0`. The binary is the
official tarball, so this is an upstream stamping bug in that one release;
v26.8.1 reports cleanly. Bumped, with both SHA256s from the published
SHASUMS256.txt. The gate that should have caught it used
`grep "^v${NODE_VERSION}"`, and `^v26.8.0` matches `v26.8.0-alpha.0.0.0`
happily — the suffix being the entire point. Now an exact compare.

**Orphaned stage contexts are reclaimed.** `runtime_cleanup_local_context_chain`
only removed the workdir the current process created, so any hard kill leaked
its tree; a 3.3 GB `runtime-flow.*` from 2026-07-25 had survived 33 days on a
filesystem at 93%. The new sweep is age-based so a concurrent chain's young
workdir is never robbed, and was proven selective in isolation.

One reported defect was **refuted rather than fixed**: arm64 ships a PyPI
`iree-base-compiler 3.11.0` beside a source-built
`iree-base-runtime 3.11.0.dev0+e4a3b04`, which looks like a version skew and is
not one — `refs/tags/v3.11.0^{}` resolves to that same commit. No gate was
added; a version-equality assert would fail on a cosmetic difference. The
comment claiming "amd64/arm64 install the PyPI compiler+runtime" was the thing
actually wrong, and now describes the real per-arch split.

### And then the shipped IMAGES were audited, not just the code

A second 10-agent sweep read the shipped run's logs rather than the tree, and
every claim was re-checked against the published bytes before being acted on.
Eleven defects, one refutation.

**Four things shipped wrong.** `Dockerfile.package` set FFMPEG_PREFIX and
LIBCAMERA_PREFIX inside the same ENV instruction that consumes them, and Docker
substitutes within one instruction using the value from BEFORE it -- empty. The
published amd64 image therefore carried two phantom `/bin` entries in PATH, two
`/lib/pkgconfig`, two `/lib`, and a GST_PLUGIN_PATH pointing at
`/lib/gstreamer-1.0`, so libcamera's GStreamer plugin was unreachable through
the standard variables. The Android ONNX Runtime shipped with Microsoft's 1DS
telemetry SDK compiled in, because ORT 1.29 defaults it ON and only the native
lane passed `--no_telemetry`. amd64 alone shipped a setuid-root
`gst-ptp-helper`, since its disable was gated on `cross_build_is_active` while
its own rationale ("useless in a container image") is arch-independent -- the
cross arches got that hardening as a side effect of a link-failure workaround.
And Node.js was an alpha: the official v26.8.0 tarball self-reports
`26.8.0-alpha.0.0.0`, which puts it outside its own npm's supported range.

**Three gates reported success over things they never tested.** `check_ffmpeg`
resolved the binary as `command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg` --
falling back to the absolute path exactly when PATH reachability, the thing it
checks, is broken. The app-wheel smoke exits 0 whenever failures==0 and counts a
missing component as a warning, so one identical PASS covered 15/15, 14/15 and
12/15; it now carries a per-arch ratchet that may only be raised. The
shipped-content byte gate shared a loop with the boot smoke and ran second, so
riscv64's smoke failure meant the riscv64 wrapper in the index was never
content-checked; the two are separate passes now, content first.

**Two silent swallows.** Provenance was resolved per arch inside the build loop,
so a commit landing between two arch builds split the index -- today's carries
two different `org.opencontainers.image.revision` values. And a riscv64 uv
exemption written for "extras that cannot resolve under QEMU" swallowed
`Timeout (300s) when waiting for lock` twice, assembling the venv with no
regenerated lock while the log said "expected".

**libvidstab needed two fixes, not one.** amd64 shipped 31 FFmpeg libraries and
arm64 30, the delta being `--enable-libvidstab`. Diagnosed against the real
cross-media image because the logs were inconclusive (the install layer was
CACHED and printed nothing): `libvidstab-dev` was never installed for the
target even though it exists for both cross arches, AND `-lgomp` has no dev
symlink there -- `libgomp1:<arch>` ships only the versioned file and the cross
toolchain carries a libgomp for the HOST only. Installing the dev package alone
still failed on `cannot find -lgomp`; both together link.

Refuted rather than fixed: "riscv64 exports ONNXRUNTIME_ROOT_ANDROID at an empty
directory". The variable is set on no arch at all, so the empty directory points
nowhere.

### Closing the day: four backlog items, one of them retracted

The highest-rated open item, "`preflight.sh` exits 0 on failure" (★★★), turned
out **not to be a bug** — and I had re-confirmed it earlier the same day, so the
retraction is mine. The summary block ends `exit 0` / `exit 1` / `exit 2` and
those propagate: an unknown `PREFLIGHT_ONLY` slug returns 2 when the script runs
directly. Both "observations" were one measurement error —
`bash preflight.sh | tail | sed; echo $?` reports SED's status, not the
script's. Demonstrated: `(exit 1) | tail -1 | sed 's/^//'; echo $?` prints 0
while `(exit 1); echo $?` prints 1. `exit 1` has been in place since 928e745.
The lesson is worth more than the entry was: **never measure an exit code
through a pipe.**

All five UNOWNED env knobs are registered in `lint-env-knobs.allow` with reader
and reason, and verified under `KNOB_GATE=1` — which is precisely the failure
the entry predicted for its first strict use. The `-nostdinc++` libstdc++ c++23
watch note moved from the LLVM block to the GCC pin, where the patch lives.

And the binfmt unit was re-installed and then **tested against the exact
failure that cost this morning 5.5 hours**: restarting containerd re-ran
rootless-binfmt.service in the same second, with both emulators answering
afterwards. `PartOf=containerd.service` works; a daemon restart no longer
strips foreign-arch emulation.

Final state: preflight 31/31 with a real exit code of 0 (measured directly,
not through a pipe), 27 unit-test suites / 678 assertions green, shellcheck
clean over 263 files.

## 2026-08-26 — host toolchain: scripted nerdctl-full upgrade, and the audit that rewrote it

`buildctl` on this host comes from the `nerdctl-full` bundle — there is no
separate BuildKit package — so bumping buildkitd means replacing the bundle.
That was a hand-run sequence of stop/extract/restart steps whose half-done
state fails much later with a confusing symptom. It is now
**`linux/host-config/install-nerdctl-full.sh`**: dry-run by default, SHA256
verified against the published `SHA256SUMS`, backup + `--rollback`, refuses
while a build is running, and a cache-mount census around the swap.

**Then a 20-agent audit against the LIVE host layout — every finding
adversarially refuted — found 13 real defects in it, and the worst were not the
expected ones.**

The host runs the rootless stack (`systemd --user`) *and* a rootful
containerd + buildkitd, all executing the same `/usr/local/bin` binaries plus
the unit files the bundle ships in `/usr/local/lib/systemd/system`. The
installer only stopped the `--user` units. Measured rather than assumed: GNU
tar 1.35 and `cp -a` **both unlink-and-recreate**, so there is no `ETXTBSY` and
no error at all — the root daemons keep executing the now-deleted inode, and
`Restart=always` then performs the real version jump unattended. One audit lens
called this a critical `ETXTBSY` abort; a running-binary experiment refuted
that, and the claim was dropped instead of shipped. The script now refuses
until the operator picks `NERDCTL_INCLUDE_ROOTFUL=1` or
`NERDCTL_IGNORE_ROOTFUL=1` — blocking the act, not the look: a dry run still
prints the plan and the choice.

Gates that could not fail, now able to:

- The cache census counted `buildctl du`'s **header row** (51 records read as
  52) and returned 0 for an unreachable daemon — indistinguishable from "caches
  gone", and a before-count of 0 made `after >= before` unfailable.
- Cache-mount **loss only warned**, so an upgrade that ate hours of
  ccache/sccache still exited 0 and printed `done.` It now fails the run.
- `systemctl is-active` on a `Type=simple` wrapper was the only BuildKit
  assertion: a daemon with no usable worker passed. Now polls `buildctl debug
  workers`.
- The version proof read **on-disk client** binaries, which only prove `tar`
  ran. Now compares **daemon-reported** versions captured before and after.
- The "already on target" early-out compared `2.3.4` to `v2.3.5` — dead code.
  Worse than a wasted re-install: a second run overwrote the backup with the
  already-new binaries, destroying the only way back.
- The refuse guard missed a `buildctl build` solve; widened, and it now honours
  the repo's own `CROSS_CHAIN_PIDFILE` (read defensively, so an empty file
  cannot become `kill -0 0` and refuse every run).

**The upgrade then ran for real** (`NERDCTL_INCLUDE_ROOTFUL=1`): nerdctl
2.3.4 → **2.3.5**, buildctl v0.31.1 → **v0.31.2**, and — the part the old script
could not have shown — the *daemons themselves* report v0.31.2 and containerd
**v2.3.3**. Cache-mount records **51 → 51**, one worker, all four services
active, both rootful daemons back on new pids (not stranded on deleted inodes),
`NeedDaemonReload=no`. The driver was moby/buildkit#6915, a
"concurrent map iteration and map write" daemon crash that reproduces under
concurrent builds — this chain runs three arch lanes at once. It does **not**
cure BKD1 session rot (no upstream fix; still stop-chain → restart), and the
parallel-build cache-miss fix (moby/buildkit#6954) is in v0.32.0, which no
nerdctl-full ships yet.

Reference run, both gotchas that bit during it, and the rootful knobs are in
[`docs/linux-host-setup.md` § B3b](docs/linux-host-setup.md).

## 2026-08-25 (eighth pass) — SBOM run for real, on both images, and documented

The SBOM machinery landed the pass before with an honest caveat: the `syft` job
had never run. It has now, locally, against both published images — and the
results correct something the previous entry asserted.

- **`docs/sbom.md` (new)** — how to generate both halves, and, the part usually
  left out, **what to do with the result**: CVE scanning with `grype` straight
  off the SBOM (seconds instead of a multi-gigabyte pull), answering a
  procurement request, diffing two releases to catch a dependency nobody chose
  to add, policy gates, Dependency-Track for the "image did not change, the
  world did" case, and CRA context. Plus what it cannot tell you.

**Linux `:latest-cross` (linux/amd64):** 4,112 packages, 2,202 distinct names —
maven 1,340, deb 1,255, cargo 1,072, pypi 228, npm 149, go 13. Breadth no human
maintains by hand. But **73 % declare no licence and 94 % conclude none**, and
for the copyleft components the scan reports the DISTRO copy at a different
version: FFmpeg as `62.x`/`7:8.0.1-3ubuntu2` rather than the source-built `n9.0`
GPLv3 build, GStreamer as Ubuntu's `1.28.2-1` rather than `1.29.2`. OpenCV, TVM,
Abseil and VVdeC are absent entirely. **A source-offer question cannot be
answered from the scanner SBOM** — which is a far stronger justification for the
curated half than the previous entry gave.

**Windows `:winamd64`:** 26,253 packages, six times the Linux count and mostly
noise — 14,014 are PE version resources read out of every DLL ("Microsoft®
Windows Repair Disc", "JP Japanese Keyboard Layout for NEC PC-9800"), i.e.
operating-system files, not chosen dependencies. **98.5 % carry no licence.**
The earlier prediction that Windows would yield FEWER packages was wrong in the
opposite direction; package count is not a quality signal.

> **The Windows scan also caught real drift.** It reports ONNX Runtime `1.27.0`,
> TVM `0.25.0` and FFmpeg `8.0.git` while `versions.env` pins `v1.29.0`,
> `v0.26.0` and `n9.0`. **The published `:winamd64` is behind the current pins**,
> so the curated SBOM and both licence pages — all generated from `versions.env`
> — describe the next build rather than the published tag. Recorded as a limit
> on the SBOM page.

- **`docs/scripts/compare_sbom.py` (new)** measures the blind spot instead of
  asserting it. Two bugs were found in it before its output was trusted: it
  conflated package count with distinct names, and it compared a Linux scan
  against the Windows and Documentation-image rows, which reported Ghostscript
  and TeX Live as "invisible to the scanner" when they are simply not in that
  image. Its name matcher also failed on `GStreamer` vs `gstreamer1.0` and
  `PyTorch` vs `torch`; letters-only containment fixes that while still
  correctly refusing to match OpenCV against anything.

Routed from `docs/INDEX.md` and the Sphinx toctree. Sphinx build warning-free;
`doc-links`, `doc-dupes`, `sbom` and `version-snapshot` green; ruff clean.

## 2026-08-25 (seventh pass) — SBOM, in two halves, because one cannot cover the image

An image scanner catalogues components that carry package METADATA: dpkg/apt,
Python site-packages, npm, Go and Rust binaries. It cannot see a C/C++ library
built from source into `/opt` — ONNX Runtime, OpenCV, FFmpeg, GStreamer and
libcamera leave no manifest behind. Those are also the components under copyleft
licences here, so a scan alone would produce an SBOM that silently omits every
entry carrying a corresponding-source obligation.

Hence two halves, both published, deliberately distinguishable by
`creationInfo.creators`:

- **`docs/scripts/generate_sbom.py` (new)** emits `docs/deps/sbom-curated.spdx.json`
  — SPDX 2.3, 97 packages, from `deps.json` + `versions.env`. Each package
  carries its SPDX licence expression, its upstream download location, and
  `licenseComments` naming the obligations it triggers, the corresponding-source
  upstream and revision, the build flags where those determine the licence, and
  any patches applied. The two coarse buckets are declared properly as
  `hasExtractedLicensingInfos` rather than smuggled in as invalid ids.
  The document is **byte-reproducible** (fixed timestamp, stable namespace, a
  digest-suffixed SPDXID so `FFmpeg` in two sections cannot collide), which is
  what lets it be gated at all.
- **`.github/workflows/sbom.yml` (new)** runs `syft` against the **published**
  image, per architecture, emitting SPDX and CycloneDX. It reads from ghcr
  directly (`registry:`), so it needs no build host, no daemon and no disk for
  the rootfs — which matters because these images are built on a workstation,
  not in this repository's pipelines. `:latest-cross` is a manifest list, so
  each arch is scanned explicitly; a scan without `--platform` silently picks
  one. A result under 50 packages fails the job rather than publishing it: that
  means a broken reference or a cataloguer regression, not a clean image.

- **Valid SPDX syntax, corrected.** `Apache-2.0-with-LLVM-exception` and
  `GPL-3.0-or-later-with-GCC-exception` are not SPDX ids. They are now
  `Apache-2.0 WITH LLVM-exception` and `GPL-3.0-or-later WITH GCC-exception-3.1`,
  and the expression splitter keeps a `WITH` pair intact — splitting it would
  look up a base id whose obligations differ from the exception-bearing one.
- **Gated** as preflight slug `sbom`, in the pre-commit hook and
  `stale-docs-check.yml`. Negative-tested: dropping a package from the committed
  document fails with the regeneration command.
- **Routed** from `docs/INDEX.md`, and the Sphinx landing page regained its
  **Third-Party Licences** card — the 2026-08-25 `index.rst` rewrite had dropped
  it, leaving the page reachable only from the toctree. It is the page a
  production or procurement question lands on first.

**Verified here:** the curated document validates structurally (unique
well-formed SPDXIDs, 97 packages, 26 flagged source-required), regenerates
byte-identically across runs, and the gate fails on drift. **Not verified here:**
the `syft` job has never run — syft is not installed on this workstation and the
published image is not present, so its first CI run is its first real test.

## 2026-08-25 (sixth pass) — the licence list now says what each licence REQUIRES

A list that names licences answers "what is in here". It does not answer the
question that matters when you publish to a public registry: **what does each
of those licences oblige me to do?** The published runtime image ships a GPLv3
FFmpeg (`--enable-gpl --enable-version3`) and a GPLv3 GCC, and carried no
corresponding-source offer at all.

- **`docs/scripts/license_obligations.py` (new)** maps SPDX id → the concrete
  things a distributor must do: keep the notice, ship the text, state changes,
  propagate NOTICE, offer corresponding source, allow relinking, AGPL section 13
  network source, same-licence for derivatives, and "this is a vendor EULA, the
  question is whether you may redistribute at all". Dual licences render as the
  UNION of both arms, not the cheaper one, because the project has not recorded
  an election — record a single SPDX id to narrow it.
- **Every one of the 97 `deps.json` entries now carries an `spdx` field**,
  mapped from the 43 free-text licence strings by a reviewed table. Free text
  cannot be turned into an obligation; an SPDX id can.
- **All 26 copyleft components now carry a corresponding-source pointer** — the
  exact upstream, the revision (resolved from the same `versions.env` pin the
  build uses, so it cannot drift), the patches applied on top, and, where the
  build configuration is what *determines* the licence, the configure flags.
  FFmpeg's entry says in as many words that `--enable-gpl --enable-version3`
  is what makes the shipped binary GPLv3 rather than LGPL. GCC's says the
  Runtime Library Exception covers programs compiled with GCC, not shipping
  GCC itself — which the runtime image does.
- **Three components are now marked as modified** (sccache, and the Windows
  FFmpeg and GStreamer builds, which carry patches). Apache-2.0 section 4(b)
  and the GPL family both require saying so. This also corrects a factual
  error: sccache was listed as coming from "Ubuntu apt" when it is built from
  source at a pinned git rev with a local patch series.
- **Both pages carry all of it** — the published website page and the repo's
  own `third-party-licenses.md`. A developer reading the repo is exactly the
  person who needs to know that shipping the image carries a source-offer duty,
  so splitting that across two pages is how it gets missed.
- **Gated.** `generate-website-licenses.py` now fails when an entry has no
  `spdx`, when an SPDX id has no obligation mapping, or when a copyleft
  component has no `source` block. It runs on `--write` as well as `--check`,
  and reaches the pre-commit hook and both docs workflows through the existing
  `version-snapshot` slug. Negative-tested: removing FFmpeg's source pointer
  fails with both its Linux and Windows entries named.

**Not addressed, and it is the bigger question.** The published `:winamd64`
image contains CUDA, Visual Studio Build Tools and Windows Server Core under
vendor EULAs. Those entries are now flagged `eula-review`, but a flag is not an
answer: whether they may be redistributed in a public image at all is a legal
question, and no amount of documentation changes it.

Still open too: licence **texts** are not yet shipped inside the images. The
obligations page now says they must be, which makes the gap visible rather than
invisible — collecting `LICENSE`/`COPYING` into `/usr/share/licenses/` during
packaging is the next step.

## 2026-08-25 (fifth pass) — the published webserver was serving a stale licence list

Asked whether the open-source licence lists are current and whether anything
keeps them current. The generated ones were current. The **served** one was not,
and nothing was watching the difference.

- **`docs/third-party-licenses.md` and
  `linux/webserver/license-assets/documents/footer/openSourceLicenses{En,De}.md`
  are generated** from `docs/deps/deps.json` + `versions.env` by
  `generate-website-licenses.py`, and they **are** gated: `sync_versions.py
  --check` shells out to it and ORs the result, so the `version-snapshot`
  preflight slug covers them — in `.githooks/pre-commit`, `build-docs.yml` and
  the weekly `stale-docs-check.yml`. That half was working.
- **The webserver image did not serve those files.** `linux/webserver/dist/`
  ships its own build-time copy of the same page, and the Dockerfile overlays
  `license-assets/` on top — but the overlay targeted `/var/www/html/assets/`,
  one directory too shallow. Flutter serves declared assets under its own
  `assets/` root, so the app fetches `/assets/assets/documents/footer/…`. The
  generated file landed at a URL nothing requests, and the image served the
  `dist/` copy: **last regenerated 2026-07-22, 142 lines against the current
  236, missing ~25 components** — Arm NN, BuildKit, CPython, Emscripten, GNU,
  Ghostscript, ImageMagick, LiteRT-LM, Meson, Ninja, Ollama, Pandoc, Pygments,
  Scoop and more.
  Nothing caught it because nothing *could*: both files existed, both were valid
  Markdown, both were tracked, and only the URL told them apart. The generator
  writes `license-assets/` only, so no amount of regeneration would have fixed
  the served page.
- **Fixed** by pointing the overlay at `/var/www/html/assets/assets/`, and
  **gated** so it cannot drift back: `generate-website-licenses.py` now asserts
  the Dockerfile's overlay target, and that every `openSourceLicenses*.md` the
  `dist/` bundle ships is one the generator owns. That check runs on `--write`
  as well as `--check`, because an overlay path is a property of the image that
  regenerating file contents cannot fix — and must not mask. Negative-tested:
  restoring the old target fails the gate with the exact remedy.
  `dist/`'s stale copy is left in place deliberately — it is a vendored build
  artifact from the app repo, and the overlay is the designed mechanism for
  superseding it. The new check is what guarantees the overlay still covers it.

**Answering the question directly:** the lists themselves were up to date and
are kept so automatically. What was not automatic — and is now — is that the
*shipped* page is the generated one.

## 2026-08-25 (fourth pass) — the gates reach the pre-commit hook; the guard stops denying prose

Clearing what the third pass left open, plus one defect the newly-runnable
PowerShell suite surfaced.

- **`doc-links` and `doc-dupes` now run in `.githooks/pre-commit`**, not only in
  CI. Both were added the same day and wired into `stale-docs-check.yml` and
  `build-docs.yml` — but a broken anchor or a copied passage still reached a
  commit locally and waited for a pipeline round trip to be noticed. They add
  ~2 s together, so deferring them bought nothing.
- **The delete guard no longer denies documentation.** `nvidia|adrenalin|radeon`
  was the only protected pattern that is not path-shaped — every other one
  carries a `\` or a drive letter — so it matched bare English anywhere in a
  text. A page saying "an ENABLED AMD RDNA4 dGPU" that also showed a
  `nerdctl run --rm` example was denied, because `--rm` matches `\brm\b`. That
  fired on six ordinary edits in one day, including the changelog entry
  describing it.
  The fix is **proximity, not same-line**: the vendor pattern now requires a
  delete verb within 200 characters. Same-line was considered and rejected —
  a real script assigns the path on one line and deletes on the next, and a
  line-scoped rule would stop seeing exactly the shape that matters. Every other
  pattern stays unscoped, and the window is measured on quote-retaining text, so
  a quoted verb nearby still denies: the conservative direction.
  Six cases pinned in `Guard.DestructiveDeletes.Tests.ps1`, which previously had
  **no coverage of this pattern at all** — including the 2026-08-21 paste-a-script
  vector, the multi-line variant, and the false positive itself.
- **The last smear tables are gone.** `windows-cross-builds.md` (14 long rows)
  and `build-cache-tiers.md` (4) got the same treatment as
  `windows-builds.md` earlier: two-column tables became linkable definition
  sections, the four-column one kept its scannable columns and moved the long
  free-text column into per-row detail. Repo-wide, rows over 400 characters fell
  from 39+18 to 8, and every remainder is a genuine multi-column row.
- **Pester installed (user scope)** so `windows/scripts/tests/Invoke-Tests.ps1`
  actually runs. It had been exiting 0 while silently skipping every test, which
  reads as green — the suite had not executed once all day, including against
  the `verify-target-arch.ps1` change that arrived with the merge. **668 tests
  now run: 667 pass.** The one remaining failure is environmental, not code:
  `Assert-ShimPatch` finds no patched containerd shim installed on this host.
- **Three patch files were CRLF in the worktree against an LF index**
  (`windows/scripts/patches/README.md`, `iree/enable-ehsc.cmake`,
  `litert-lm/cpu-affinity-rust-syslibs.cc`), failing
  `Dockerfile.EolAttributes.Tests.ps1`. Re-materialised from the index with the
  remedy `preflight.sh` already prescribes for `.sh` files. This is the class
  AGENTS.md warns about: an EOL flip busts a media layer and costs hours.

**Still open, and not ours to close:** whether `VULKAN_VERSION` should be
`1.4.357.0` (what `versions.env` says, and therefore what every doc now says) or
`1.4.357.1` (what the docs claimed before the sync). If `.1` was intended,
`versions.env` is the file to change.

## 2026-08-25 (third pass) — docs: a duplication gate, and the copies three manual passes missed

`docs/INDEX.md` opens with the reason this matters: one Dev Drive command in
three places, all three wrong the same way. That rule was written down and
enforced by nobody. Three manual de-duplication passes in one day each declared
the tree clean — and each measured **verbatim lines**, which is the wrong
instrument, because prose gets reflowed. A paragraph reworded across two pages
shares no whole line while still being the same paragraph.

- **`docs/scripts/verify_doc_dupes.py` (new) — preflight slug `doc-dupes`,**
  wired into `stale-docs-check.yml` and `build-docs.yml`. Every paragraph is
  reduced to its 8-word shingles; two paragraphs in different files sharing more
  than 12 are reported. Shingles owned by many files are ignored as shared
  vocabulary. Records (archives, backlogs, `CHANGELOG.md`) are excluded — they
  narrate the same work on purpose and must never be edited to satisfy a gate.
  Negative-tested both ways: a paragraph copied between pages fails it, and so
  does an allowlist entry whose overlap has disappeared.
- **It found 27 copied passages** on a tree that had just been declared clean.
  The largest was a **3,673-character single paragraph** in `AGENTS.md`
  § Quick Reference that also duplicated `cross-build-verification.md` in full —
  flagged as a wall of text in the very first review of this work and walked
  past three times since. It is now build logs, chain stopping, a three-row
  cache-knob table, and a two-sentence summary of the shipped-BYTES saga that
  points at the page which owns it.
- **Reduced to 9 pairs, all deliberate**, each recorded in
  `docs/scripts/doc-dupes.allow` with a budget and a reason — almost all of them
  a RULE page and a MECHANISM page naming the same script or failure. The
  allowlist is a ratchet, not an exemption: growth past a budget fails, and so
  does a stale entry.
- **What got one owner along the way:** the RDNA4 layer-lock story (the
  `windows-host-setup.md` copy ran 78 lines of superseded history; it is now a
  24-line actionable check that links to the lane doc — the same duplication a
  previous pass reported as fixed without re-measuring), the CNI
  `.conf`/`.conflist` rule, the TensorRT owner directive, the sccache wiring
  block, the containerd host-config entry, the apt-mirror advice (stated twice
  in one file), the CI trigger markers, three over-long `failure-modes.md` fix
  cells, and the twin preambles on the two reference pages.
- **`linux-build-basics.md` now opens by saying what it is** instead of with a
  build-logging admonition — it was the only page of 38 without orientation in
  its first line.

**Verified:** `doc-dupes` and `doc-links` both green; preflight green across
doc-links, doc-dupes, version-snapshot, arg-consistency, mirror-consistency,
crlf-guard, shellcheck, dockerfile-lint, workflow-lint, python-lint; Sphinx
build warning-free; ruff clean on the full ruleset; every distinctive fact from
the 55 removed lines confirmed still present in its owning page.

## 2026-08-25 (later) — docs: a gate that keeps the structure honest, plus the leftovers

The structural pass earlier today fixed the *state* and nothing kept it fixed.
This closes that, and clears the items that pass deliberately left open.

- **`docs/scripts/verify_doc_links.py` (new) — preflight slug `doc-links`.**
  Checks the four ways this tree rots silently: a relative link whose target
  moved, a `file.md#heading` deep link whose heading was renamed, the repo's own
  `file.md § Heading` prose convention (the worst of them — nothing renders
  those, so nothing complains), and index coverage against BOTH `docs/INDEX.md`
  and the Sphinx toctree. Wired into `stale-docs-check.yml` and
  `build-docs.yml`. Archives and `CHANGELOG.md` are exempt from the anchor and
  section checks by design: they are dated records, and a heading renamed later
  must not force an edit to history. Negative-tested — a renamed heading, a
  dropped toctree entry and a renamed section target each fail it; ruff-clean on
  the full ruleset.
  **It immediately earned its place**: 10 real stale references, two of them
  introduced by the morning's split (`docs/upstream/` was outside the first
  rewrite pass; two lane refs still pointed at `AGENTS.md § Isolation policy`
  after that content moved INTO the lane doc). It then rejected two references
  in prose written for this very entry.
- **The smear tables are gone.** `windows-builds.md` had 39 table rows over 400
  characters — the exact defect called out in the failure-modes table and then
  walked past in its twin. § Windows Script Reference (47 entries) is now
  grouped, linkable sections with a scan list; Component Build Matrix and Source
  Patch Policy keep their scannable columns and move the long free-text column
  into per-row subsections. 39 → 1.
- **Zero verbatim duplicate prose lines** across all non-archive docs. The last
  two were commands — a `gh --jq` recipe and a `Set-Service` line — which is the
  exact class the Dev Drive incident in `INDEX.md` is about. Each now has one
  owner and a pointer.
- **The provenance heading is gone.** `windows-build-lanes.md` carried a section
  named "Driver behaviour and lane selection (from AGENTS.md)" — named after
  where the content came from, not what it is. Now "Driver preflight gates and
  isolation policy".
- **`AGENTS.md` 1,205 → 1,110 lines** by moving reference out to the pages that
  own it: the runtime-lane and orchestrator command blocks to
  `linux-cross-builds.md`, `WindowsContainerBuild.Reuse` to `windows-builds.md`,
  the Sphinx theme package to `project-info.md`, and the build-performance
  summary down to its motivating number plus a pointer.
- **Version drift cleared** via the sanctioned `sync_versions.py --write`.
  Note two real corrections it made: `windows/Dockerfile.base`'s
  `FLUTTER_VERSION` default was 3.47.0 while `versions.env` says 3.47.1 (the ARG
  sits BELOW the VS Build Tools layer, so this costs a scoop re-run, not the
  expensive layer — the ARG-placement rule doing its job), and the docs claimed
  Vulkan 1.4.357.1 while `versions.env` says 1.4.357.0. The SSOT won. **If .1
  was the intent, `versions.env` is the file to change — not the docs.**
- **The Sphinx build is warning-free** (was 29). Four code blocks used an
  unknown `cmd` lexer; the 2026-08-21 backlog archive jumped H1 to H3 in 26
  places. The archive's heading levels were corrected and a dated editorial note
  added where it points at content this morning's split moved — the entries
  themselves are untouched, because it is the record.

**Not fixed, and why.** `AGENTS.md` is 1,110 lines, not the ~600 previously
proposed. That number was wrong: what remains is rules, not reference, and
cutting further would delete hard-won knowledge to hit an arbitrary target.
`windows-build-lanes.md` is 1,461 lines and remains the largest non-archive
page; it is one coherent topic and splitting it again would scatter a story that
reads in order. `windows-cross-builds.md` still has 14 long table rows.

## 2026-08-25 - docs: structural pass — one index, five new pages, AGENTS.md halved

A review of `AGENTS.md`, `README.md` and `docs/` found the content strong but
the containers wrong: three competing indexes that disagreed, one 3,139-line
Windows page, a 1,559-line agent file with no TOC, and the RDNA4 story told in
full five times. No knowledge was dropped — every line was moved, promoted to a
heading, or reformatted in place.

- **One index, and it is discoverable.** `docs/INDEX.md` was linked only from
  `AGENTS.md` and two reference pages — not from `README.md`, not from the
  Sphinx toctree. It is now the first card and first toctree entry on the docs
  site and the head of README's Documentation section. Its coverage gaps are
  closed: `overview`, `project-info`, `third-party-licenses`,
  `build-cache-tiers`, both refactor backlogs and every archive are listed.
  `build-cache-tiers.md` (24 KB) had been reachable from **none** of the three
  indexes. `docs/index.rst` gained six captioned toctrees; every `docs/*.md`
  now appears in exactly one.
- **`AGENTS.md`: 1,559 -> 1,202 lines (154 KB -> 84 KB, ~39k -> ~22k tokens).**
  It is loaded every session, so its size is a per-session tax. It gained a
  contents block and a charter that says what it is *for*; the circular pointer
  is gone (it claimed build commands live in README.md, while README.md pointed
  back at it — they live in its own § Quick Reference).
- **`docs/windows-build-invariants.md` (new).** The 380-line flat bullet list
  under one `###` is now 44 entries in eight groups, each individually linkable.
  Nothing was rewritten; each rule keeps its incident and date.
- **`docs/failure-modes.md` (new).** The Common Failure Modes table — rows of
  1,200-2,400 characters, unreadable on GitHub and impossible to deep-link — is
  now 34 symptom sections with Symptom / Cause / Fix, grouped by lane. Every
  entry has an anchor; README and `AGENTS.md` link into specific ones.
- **`windows-builds.md` split 3,139 -> 660 lines**, into
  `windows-build-lanes.md` (BuildKit, nerdctl, classic; isolation, preflight
  gates, RDNA4 A/B history), `windows-build-resources.md` (CPU/memory envelope,
  sccache, GPU, the 125-layer budget), `windows-stevedore-and-docker.md` and
  `windows-refactor-backlog.md`. The pseudo-sections other pages cite as
  "§ Store GC", "§ VHDX-backed checkouts" and "§ DEFECT SOLVED" were never
  headings; they now carry named anchors.
- **Duplication removed where it was drifting.** The RDNA4 layer-lock story was
  told in full in README **twice**, `AGENTS.md` twice, `windows-builds.md`
  seven times and `windows-host-setup.md` four — each copy repeating the
  superseded 2026-08-09 verdict. It now has one owner
  (`windows-build-lanes.md`), one triage row (`failure-modes.md`) and one-line
  pointers elsewhere. Same treatment for the Windows-on-ARM blockquote (README
  and `AGENTS.md` carried it near-verbatim) and README's Engineering
  Principles, which restated `AGENTS.md` § Project priorities in different
  prose.
- **`README.md`: 308 -> 226 lines, Quick Start moved from line 245 to line 25.**
  A first-time reader met a 56-line caching essay, a 1,900-character
  architecture paragraph and a generated version table before a single runnable
  command. The generated version-snapshot block is byte-identical.
- **`CHANGELOG.md`: 2,493 -> 661 lines.** Entries through 2026-08-13 moved to
  `docs/changelog-archive-2026-08-13.md`, following the backlog-archive
  pattern. Archive again past ~700 lines.
- **Scratch is now ignored by construction** (`.gitignore` + `.dockerignore`).
  One-shot helper scripts land in the repo ROOT — that is where a `uv run` or
  `bash` invocation resolves relative paths — which is exactly where `git add -A`
  sweeps them into a commit. No tracked file at the root is a script, so
  root-level `*.py`/`*.sh`/`*.ps1`/`*.psm1`/`*.tmp`/`*.bak` are ignored
  outright, plus a `.scratch/` tree for everything else throwaway. Checked
  before landing: no tracked file is shadowed, both lint gates discover from
  directory allowlists that exclude the root, `crlf-guard` reads
  `git ls-files`, and no Dockerfile COPYs a root-level script. The
  `.dockerignore` half matters on its own — an untracked probe is invisible to
  git but still rides along in the root build context that ~9 solves upload per
  full classic run. A helper that earns a second use is not scratch: it moves to
  `linux/scripts/` or `docs/scripts/` with a header and a test.
- **Verified, not assumed:** 0 broken relative links and 0 bad anchors across
  README, AGENTS and all of `docs/` (including 97 same-file TOC anchors); a
  line-level conservation check accounts for every line of the split files;
  `preflight.sh` green on `runtime-paths,crlf-guard,dockerfile-lint`.

**Known guard false positive, filed not patched.**
`.claude/hooks/guard-destructive-deletes.ps1` matches its delete verbs and its
protected-path patterns against the WHOLE text independently, so a doc that
mentions a GPU vendor anywhere and contains a container cleanup flag anywhere
is denied — the flag matches the two-letter delete verb. Editing this README
and this entry both trip it. Prose that merely mentions a vendor and a CLI flag
is not the 2026-08-21 vector. Per the repo's own rule, relaxing a guard regex
is a reviewed change with a test — so the fix is proposed, not applied: require
the verb and the protected token on the *same line*, and add a
prose-false-positive case to `Guard.DestructiveDeletes.Tests.ps1`.

**Pre-existing and untouched:** `sync_versions.py --check` reports the README
snapshot, `overview.md` inline markers, the deps table and
`windows/Dockerfile.base` ARG defaults as stale. That drift predates this pass
(the README block is byte-identical to `HEAD`) and the fix touches a Dockerfile
ARG, so it is left for a deliberate `--write` run.

## 2026-08-25 - docs: remote desktop, media/OCR — `04_Software` and `RemoteDesktop.md` retired

`docs/linux-reference.md` gains two sections, emptying the last two note folders
that still held transferable material.

**Remote desktop on a headless box.** The source had `xrdp`+GNOME Flashback and
`gnome-remote-desktop` as two disconnected walkthroughs, the second in German.
Restructured as a decision — Wayland-native vs X11, and the note that both bind
3389 so running both is a conflict, not a fallback. The system-vs-user mode
distinction in `grdctl` is called out, since picking the wrong one is the usual
first mistake on a box you dial into.

Two fixes to the source while transferring: its rollback removed
`/etc/polkit-1/rules.d/02-allow-colord.rules`, and its summary table listed that
file, but no step ever created it — the rule is now written out, attached to the
troubleshooting row for the colord auth popup it actually fixes. And step 4 read
`südöstliche mkdir -p` where it meant `sudo mkdir -p`.

**Media and document conversion.** `ffmpeg` trim/convert/frame-extract/metadata
repair and the OCR pre-processing filter, plus the `ocrmypdf` toolchain. The
source's filter read `scale=iw8:ih8`, which is not valid ffmpeg — corrected to
`scale=iw*8:ih*8`. Cross-linked both ways with `windows-reference.md`, which
keeps the genuinely Windows-specific capture side (DirectShow, `gdigrab`).

Verified command-by-command rather than by token match, after two earlier checks
returned garbage — one reported every command present because a broken `sed`
left the search key empty, making `grep -F ""` match anything. 43 of 52 source
commands match verbatim; all 9 others confirmed present as formatting variants.

## 2026-08-25 - docs: Linux Wake-on-LAN, CIFS mounts, rsync mirroring

Last transferable material from `Nextcloud\...\Debian based\Ubuntu`, all into
`docs/linux-reference.md`.

- **Wake-on-LAN (Linux)** — closes an asymmetry: `windows-reference.md` had the
  Windows side but there was no Linux equivalent. `ethtool` for the current
  boot, a oneshot unit to persist it, and the NetworkManager form, which matters
  because NM reapplies its own setting and silently undoes `ethtool`. Plus
  `tcpdump` on ether proto 0x0842 to prove the magic packets actually arrive
  before blaming the NIC. Cross-links to the Windows page for the firmware
  layer, since that part is OS-independent.
- **SMB/CIFS mounts** — credentials in a `chmod 600` file rather than inline in
  world-readable `/etc/fstab`, and `uid`/`gid` in the mount options, without
  which every file appears root-owned and a non-root build cannot write.
- **rsync mirroring** — with the two things that bite: the trailing slash on the
  source, and `--delete` emptying the target if the source path is wrong.

That folder is otherwise where this repo's exclusion list lives: two `.pfx`
private keys (one an Elster tax certificate), `.smbcredentials`, a `Save.keyx`,
a 40 MB licensed installer, and 19 zero-byte placeholder files. None of it
transferred, and the notes still referencing a NAS address, share names and a
real account are excluded with it.

## 2026-08-25 - docs: `windows-reference.md`, plus the last real gaps in both note folders

Symmetric counterpart to `linux-reference.md` from the previous entry, and a
final probe-driven pass over both Nextcloud note folders for anything still
uncovered.

**New: `docs/windows-reference.md`.** Same quarantine header as its Linux twin —
general Windows/PowerShell knowledge, explicitly *not* verified against a build
lane, with a stated promotion path if an entry turns out to be load-bearing.
Covers disk and folder-size analysis, `Set-ExecutionPolicy -Scope Process`,
exe debugging via `Tee-Object` + `$LASTEXITCODE`, LOC counting, services and
`PSWindowsUpdate`, shutdown/recovery, PATH in `cmd`, OpenSSH **server** setup on
Windows, Wake-on-LAN (the three layers that must agree, including the firmware
setting a CMOS reset takes with it), clang ABI detection, `dart format`,
orphaned-uninstall registry cleanup, `diskpart` media recovery, and ffmpeg
capture/trim recipes.

Deliberately omitted a bare recursive force-delete recipe that the source note
carried: this repo routes host reclaim through
`windows\scripts\host\free-disk-space.ps1`, which is allowlisted and report-only
by default, and a general-purpose delete-a-tree snippet in the docs would
contradict that. The page points at the script instead.

**Three gaps closed, found by probing rather than re-reading:**

- **Compose-level secrets** (`docs/build-secrets.md`). The page covered
  BuildKit `--secret` for build time but nothing for a *running* container.
  Compose mounts at the same `/run/secrets/<id>` path from a `secrets:` block —
  and the environment variable holds the **path**, not the value, which is the
  detail people get wrong on the way to putting the secret in `docker inspect`.
- **MTA setup** (`docs/linux-host-setup.md` § E2). `Unattended-Upgrade::Mail`
  was documented as needing "an MTA installed and working" with no way to get
  one; `msmtp` relay config now follows it, including the mode-600 requirement
  and the app-password caveat.
- **MSIX Developer Mode.** `windows/scripts/certificates/README.md` already owns
  certificate generation and the `TrustedPeople` import, but Windows still
  refuses to install a self-signed `.msix` until Developer Mode is on. Noted in
  `windows-reference.md` § Certificates and MSIX.

**Now confirmed exhausted.** Probes for every remaining candidate across both
folders — watchtower, CIFS mounts, VNC/xrdp, RustDesk, MQTT, Folding@Home,
`Get-StartApps`, the Group Policy scheduled task — come back either already
covered or genuinely out of scope. What is left in Nextcloud is homelab
services, desktop access, and device-specific notes, several carrying LAN
addresses, MAC addresses, a machine SID, an employer domain account, an OEM
product key and a personal mailbox. None of that belongs in a public repo.

## 2026-08-24 - docs: `linux-reference.md` — general Linux knowledge, deliberately quarantined

The notes folder still held ~20 files of ordinary Linux knowledge: disk and file
handling, log filtering with grep/awk, user and permission basics, network and
port triage, SSH key/agent handling, firmware, mounts, swap, keyboard layout on
a headless box, and general git. All correct and worth keeping; none of it
specific to this repo.

Rather than fold it into the existing pages, it goes in a **separate**
`docs/linux-reference.md` whose header states the distinction outright: every
other page records something that broke in a lane, with its incident; this page
does not, and nothing on it is verified against a build lane. The header also
names the promotion path — if an entry here turns out to be load-bearing, move
it to its owning page in `INDEX.md` and give it the *why*.

That separation is the point. `linux-host-setup.md` is trustworthy because every
line is a specific failure with a fix; mixing `uname -r` and `useradd` into it
would cost exactly the property that makes it worth reading. Keeping the general
material addressable but clearly labelled gets the reference value without
paying that.

Cross-links rather than restates: container networking and resolver failures
stay in `linux-host-setup.md` § B5/B6, build-log mining in
`build-resource-monitoring.md`, swap/zram for small hosts in
`build-parallelism-memory-tuning.md`, submodule work in
`adopting-in-a-new-project.md`.

Also closed a gap from the previous pass: the submodule conflict-resolution loop
had been transferred **without** the `git merge --allow-unrelated-histories
--no-commit -X theirs` that creates the situation, or the protected-branch push
fallback. Both now in `adopting-in-a-new-project.md`, along with
`git remote set-url`.

Scrubbed on the way in: LAN subnets, `/home/jsh/.ssh`, a board hostname, a NAS
home path, personal user paths, a `NOPASSWD` sudoers line naming a real user,
and a client project name that appeared in a sample log line. Two deliberate
omissions: the blanket wipe of everything under /tmp (the docs carry a safer
find-based form plus the mode-1777 warning), and a personal miniconda `PATH`
export. gitleaks clean.

## 2026-08-24 - docs: Windows ops notes folded in; second Linux pass

Same treatment as the Linux notes folder, applied to
`Nextcloud\Dokumente\Windows` (30 files), plus a second Linux pass that caught
what a first triage-by-directory-name had missed. +518 lines across 7 docs.

**Windows.** The Windows lane already owned long paths, `core.longpaths`,
`Optimize-VHD`, MSIX signing and `dumpbin`, so those were left alone. What was
genuinely absent:

- **`docker login ghcr.io` fails on Windows with `--password-stdin`** — the
  documented form for the registry this repo publishes to. Fix is clearing
  `credsStore` (the same helper whose SYSTEM-context failure AGENTS.md already
  lists) or writing the base64 auth entry directly. Now in `windows-builds.md`
  along with `--network=host` being Linux-only, `host.docker.internal`,
  `--memory` for heavy Windows containers, DNS via `daemon.json`, service
  recovery, and the WinGet/MSBuildTools image gotchas.
- **WSL2 setup** in `rancher-desktop-linux-containers.md`: store-less install via
  DISM + `wsl --import` from a cloud rootfs, `appendWindowsPath=false` (Windows
  binaries shadowing Linux ones inside a build script), `ext4.vhdx` reclaim, the
  VPN no-network fix, and `usbipd` passthrough including the modprobe/bind step
  that attaching alone does not do.
- **Host odds and ends** in `windows-host-setup.md`: Defender *performance mode*
  (complements the existing exclusions), `Set-ExecutionPolicy -Scope Process`,
  in-place `PATH` reload, non-interactive VS update, `winget --force --version`
  for an exact SDK pin, a WSL firewall rule, `bcdedit /bootsequence` (the
  counterpart to `grub-reboot`), and `pnputil` driver removal.
- **Git recovery** in `adopting-in-a-new-project.md`: `submodule deinit -f --all`
  for a half-initialised checkout, `core.longpaths`, `git clean -fdx`, and the
  `ssh-agent` service that a hanging `git pull` in PowerShell is waiting on.

**Second Linux pass.** Three more transfers, all previously misjudged by folder
name rather than content — the same mistake twice over:

- **UFW drops container traffic** unless `DEFAULT_FORWARD_POLICY="ACCEPT"`. This
  is the Linux twin of the Windows CNI `.conf` requirement AGENTS.md records as
  "without it RUN steps have NO network": same failure, same invisibility.
- **Host suspend kills a multi-hour chain.** `logind.conf` covers only keys and
  the lid; the sleep *targets* need masking separately.
- **APT pinning** as the other half of `Package-Blacklist` — blacklist stops
  upgrades, pinning forces the source. Carries a real trap: APT preferences need
  each field on its own line, and a single-line `echo` writes a file APT ignores
  with no error.

Plus the two stranded residues: the riscv64 `libgst*.so*` cleanup and the
prebuilt Android GStreamer tarball, both in `runtime-services.md`.

**Excluded, as before.** `ProductKey.md` holds a real OEM licence key; a
scheduled-task XML carries an employer domain account and a machine SID; several
notes carry hostnames, a device public key and personal paths. None transferred.
Verified with gitleaks (working tree, repo config: no leaks, `.gitleaksignore`
unchanged) plus a manual sweep for those identifiers, which gitleaks does not
flag. Incidental find: `Nextcloud\...\GenerateCertificateMSIX.ps1` is an older,
weaker copy of `windows/scripts/certificates/GenerateCertificateMSIX.ps1` — the
repo's is parameterized, uses a KSP provider and exports AES256_SHA256.

## 2026-08-24 - docs: personal Linux ops notes folded into `docs/` (38 of 94), two new pages

`C:\Users\jsh\Nextcloud\Dokumente\Linux` had accumulated 94 markdown notes
(~8,700 words) of Linux administration knowledge, unversioned and outside any
review. The subset that is genuinely this repo's domain is now in `docs/`,
English, deduplicated against what the repo already owns, and reachable from
`docs/INDEX.md`. +649 lines across 9 files, plus two new pages.

**New: `docs/linux-host-setup.md` (618 lines).** The counterpart to the 836-line
`docs/windows-host-setup.md`, which had no Linux equivalent — probes confirmed
`scaling_governor`, `rocm-smi`, `ubuntu-drivers`, `journalctl`,
`nvidia-container-runtime` appeared NOWHERE in the repo before this. Phases A–E:
NVIDIA driver + CUDA install and the full purge/recovery path, AMD firmware,
container runtime host config (nvidia `default-runtime`, log rotation,
`nerdctl-full` verification, resolver fixes), CPU governor + `rocm-smi`
performance mode, GCC/clang alternatives, apt mirror + unattended-upgrade
policy. Troubleshooting covers `journalctl -b -1`, the PSU-starved dual-GPU
`nvidia-smi` failure, GRUB rescue, disk and `/tmp` exhaustion.

**New: `docs/build-secrets.md`.** BuildKit `--secret` + `.netrc` for private
clones. `mount=type=secret` had zero hits repo-wide despite `secret-scan` being
an enforcing gate — the sanctioned pattern was undocumented.

**Extended:** edge accelerators (Hailo ONNX→HEF pipeline, Jetson) in
`linux-accelerator-images.md`; raw `gst-launch-1.0` pipelines and device
source-builds in `runtime-services.md`; detached containers + tmux and
bind-mount ownership in `rancher-desktop-linux-containers.md`; CPU capping and a
memory-constrained-host section (swap/zram/`-j1`) in
`build-parallelism-memory-tuning.md`; build-log failure mining in
`build-resource-monitoring.md`; submodule maintenance in
`adopting-in-a-new-project.md`.

**Two findings worth keeping.** (1) A measured incident now in § E1: `apt update`
took 107 s on a 254 Mbit/s link because `security.ubuntu.com` round-robin DNS
resolved to an unhealthy node; the regional mirror took it under 3 s. That cost
is paid on every uncached image layer, not just the host. (2) `-X theirs` on a
merge resolves file contents but leaves submodule POINTERS conflicted — a merge
can look resolved while pinning the wrong ContainerHub commit. The resolution
loop is now in `adopting-in-a-new-project.md` § Submodule maintenance.

**Nothing sensitive crossed over.** The source tree holds live secrets — two
`.pfx` private keys (one an Elster tax certificate), `.smbcredentials`, a
WireGuard config with a private key, a `Save.keyx`, a GitLab `.env` — and this
repo is public. None were transferred, referenced or quoted. Verified by the
enforcing gate (gitleaks 8.30.1, repo config, working tree: **no leaks found**,
`.gitleaksignore` unchanged) plus a manual sweep for LAN IPs, usernames, home
paths, a MAC address and personal machine names, which gitleaks does not flag.
Also scrubbed: `?utm_source=chatgpt.com` tracking params on ~8 GRUB links and
the LLM-conversation tails ("Want me to drop this into a markdown file?") that
two notes ended with.

**Deliberately NOT transferred**, per the `docs/INDEX.md` anti-duplication rule:
`buildx imagetools create` multi-arch tagging, already owned by
`linux/scripts/build-runtime-manifest.sh` and `docs/linux-cross-builds.md`. The
remaining 56 notes are homelab (NAS, Mail, RustDesk, WireGuard, WOL,
RemoteDesktop) or one-line stubs, and stay out.

**Open:** the source notes are not yet stubbed to point here, so that content
exists in two places until they are — the exact drift `docs/INDEX.md` documents.
`.claude/hooks/guard-destructive-deletes.ps1` blocks agent writes under
`C:\Users`, so this is an operator step; mapping for all 38 files was handed
over separately.

## 2026-08-24 - ghcr registry cleanup: 771 -> 167 package versions, zero failures

New operator tool `linux/host-config/ghcr-prune-package.sh` (adversarially
reviewed before first use; three found defects fixed pre-commit, including a
SIGPIPE that made the dry run exit 141 and a fail-open zero-tag path that
would have turned a collapsed keep-set into a registry wipe). First confirmed
run deleted 604 stale untagged versions — the residue of every re-pushed
moving tag since June — with 0 failures and 0 skips; afterwards the
`:latest-cross` index, all three arch manifests and every cross-stage tag
verified HTTP 200, and the concurrently running wave7b build was untouched
(its pushes sat inside the KEEP_DAYS=7 in-flight guard, visibly counted by
the tool). Incidental finding: legacy tags android/compiler/latest/media/
sdk/torch were ALREADY dangling (all 18 index children 404) before any
pruning — pre-existing damage, operator decision pending on whether to
delete or re-point them.

## 2026-08-24 - WAVE-6 SHIPPED: the gate-truth build (three blind gates now actually work)

`:latest-cross` = amd64 `a25a38c5` / arm64 `bd9953a9` / riscv64 `d3710282`,
run id `20260823-223111-d0336283`. cv2 GStreamer:YES + FFMPEG:YES holds on the
new bytes; runtime smokes 0 failures x3.

This build existed to validate the three gates the wave-5 post-audit found
INERT. All three now produce real verdicts:

1. **XC3 provenance** — `per-arch wrapper generation check: OK` with NO
   "wrapper tag(s) carry no run-id" warning; that line read 3/3 on every
   previous ship. All three wrappers carry run-id / parent-stage /
   parent-digest as image LABELS, verified by reading the REGISTRY copy's
   config blob (registry-config-label.py), not the local store. Ancestry now
   reports `android→wrapper (<arch>): OK` with real digests on 3/3 — it used
   to bail at "records no parent digest". The label saying *android* also
   confirms the XC2-STAGE fix: the writer stamped the android pin while the
   check resolved runtime_stage_parent's answer ("package"), which would have
   produced a false STALE ANCESTOR on every run the moment provenance came
   back.
2. **AP4 strip gate** — `AP4 strip verified: libavcodec.so.63.1.100 has no
   .symtab`. Every prior ship printed `check skipped (could not extract ...)`
   while the wrapper gate still said PASS, because `tar --occurrence=1` exits
   after the first match, SIGPIPEs the exporter, and `pipefail` turned the
   early exit into a failure.
3. **SMK1** — the cv2 media assert is now hard on all three arches, including
   riscv64, which used to be exempted with the printed rationale "gstreamer OFF
   by design" on the very line where the probe reported YES.

**CERB-CACHE validated the hard way.** wave6a lost all three lanes to five
freedesktop 503/404 flaps (an outage that also proved cerbero's DEFAULT_MIRRORS
path 503s unconditionally while the `/data/` primary answers 200 — the fallback
is not merely single-homed, it is always dead). But the cerbero state survived
on the cachemounts (15.7 GB / 14.5 GB), so wave6b restarted WARM
(`HIT: resuming from /var/cache/cerbero ... 13G / 20G`) and completed with ZERO
fetch failures. Before this, wave5k and 5l discarded the entire ~50-minute
bootstrap on every flap.

Also in this window (backlog sweep waves 1-3, commits ee8de5e / ece1c37 /
2276c8c): log hygiene armed by default, smoke depth (a real GStreamer pipeline
and an ONNX InferenceSession instead of string greps), per-arch component
parity, a GCC-default SSOT plus a fatal drift gate with a site floor, TS8, the
NVIDIA deb pick made deterministic and self-reporting, and eigen/cerbero
network resilience. Five mechanisms were REVERTED rather than shipped after
review proved them inert or unsafe: PAR5's live-lane divisor (a build-arg
cannot change mid-build), the cerbero seed cache (nothing mounted it), two
cargo mounts on RUNs that never invoke cargo, and S3 (it reintroduced the
`${tag}-buildcache` ref that fix7 forbids — the preflight failed on it).

Tests grew 417 -> 638 assertions across 25 suites over this window.

## 2026-08-23 - WAVE-5 SHIPPED: closure window 2 — cv2 media stack complete on all three arches

`:latest-cross` = amd64 `54ab7f01` / arm64 `7bb70a4b` / riscv64 `fb701200`.
**The window's goal is MET and verified on the SHIPPED BYTES** (local tag
digests matched against the registry-side OCI index, plus a
docker-content-digest HEAD — never the push log): cv2 5.0.0 reports
**GStreamer:YES (1.29.2) and FFMPEG:YES (avcodec/avformat 63.1.100) on
amd64, arm64 AND riscv64**. riscv64 had been stuck at wave-3 parity
(GStreamer: NO). Verification went one level deeper than the gate: real
one-frame GStreamer pipelines and an FFmpeg roundtrip were executed inside
all three shipped images, so this is runtime-proven, not string-grepped.
Runtime smokes: 0 failures x3. Wheel smokes: 13/15, 13/15, 11/15 (the
riscv64 delta is genai-absent + freetype-OFF, both documented).

What landed in this window:

1. **OCV-FF1 (FFMPEG:NO -> YES)** - true root was detect_ffmpeg's
   try_compile getting the four -l names but no link dir for the custom
   /opt/ffmpeg prefix ("Can't build ffmpeg test code"), NOT the swresample
   theory. Fix = LDFLAGS -L/-rpath-link for the ffmpeg AND gstreamer
   libdirs + a deterministic last-wins -DCMAKE_EXE_LINKER_FLAGS (the
   helpers' own -D beat the env). That exposed a second wall: opencv 5.0.0
   has no FFmpeg-8 migration (AVCodec.pix_fmts / .supported_framerates were
   removed; 4.x master has avcodec_get_supported_config, the 5.x branch does
   not) -> new backport patch
   `patches/opencv/002-ffmpeg8-avcodec-config-api.patch`, guarded by
   LIBAVCODEC_VERSION_MAJOR >= 62.
2. **riscv64 GStreamer re-lift (RV1-GST-PC largely closed)** - the
   introspection break turned out to be MESON-GI (meson 1.12 breaks
   g-i-1.84's `subproject('glib')`, reproduced on a clean sysroot, so the
   ports-.pc poison theory was falsified). Scoped pin meson==1.11.2 for the
   riscv64 cross gst build; with introspection back, /opt/gstreamer exports
   usable glib .pcs again, pass-2 gst links into videoio, and the libcamera
   gst element returns. Only freetype-OFF remains (RV1-FREETYPE).
3. **PKGCFG-MIRROR** - cerbero bootstraps pkg-config-0.29.2 from
   pkgconfig.freedesktop.org (host dead) with a src/mirror fallback that
   404s, so every COLD android bootstrap died on curl (22). Redirected to
   the macports distfiles mirror (byte-identical tarball; the recipe
   checksum still guards). **v1 of this fix was a heisenbug**: it chose the
   file to patch with `grep -rl … | grep -m1`, which is readdir-order
   dependent — inside the container it sed'd a stray .patch file and still
   echoed success, so the 404 kept happening while the host reproduced
   "correct". v2 patches the known recipe explicitly plus every other
   dead-host reference and echoes the RESULTING url line as proof.
4. **ORT version-shadow (the runtime smoke failure)** - `import cv2` died
   with `libonnxruntime.so.1.27.0: version VERS_1.29.0 not found`. The
   locally built wheel is named `onnxruntime_dnnl-*.whl` (the DNNL EP
   renames the dist) and `wheel_family()` listed gpu/migraphx/webgpu but not
   _dnnl, so `have_onnx_family` stayed false: PyPI onnxruntime 1.27 was
   neither skipped at `uv sync` nor uninstalled, and since both dists own
   `site-packages/onnxruntime/`, the 1.27 capi lib survived next to the
   1.29-linked cv2. Fix = classifier + uninstall list + skip-package on
   sync. Verified in the shipped bytes: exactly ONE ORT distribution per
   image (dnnl on amd64, webgpu on arm64/riscv64 - by design).

Mines survived (external and self-inflicted):

- **FD-OUTAGE** - a freedesktop-wide 503 window took all three android
  lanes down twice (pixman, then gst-plugins-bad). Not patchable: cerbero's
  DEFAULT_MIRRORS live on the SAME infra as its primaries. Filed with a
  cached_sources pre-seed option.
- **CERB-ICONV** - proven NONDETERMINISTIC: `undefined symbol:
  libiconv_open` killed a cold riscv64 cerbero link in one wave and passed
  in the next with no code change.
- **ENOSPC** - a runtime-stage run fell 117G -> 2G and died on a layer
  extract because nothing pruned mid-run. Cured with an auto-prune guard
  (prune-safe.sh below 55G); it fired 4x in the successful run, always with
  all 30 cachemount records surviving.

Gate-truth findings from the post-ship audit (the release is real, three
gates are not — all filed, none release-blocking):

- **AP4-SIGPIPE** - the strip gate has NEVER executed: `nerdctl export |
  tar --occurrence=1` under `set -o pipefail` returns non-zero when tar
  exits early, so the check self-reports "skipped" on 3/3 arches while the
  wrapper gate prints PASS. It hides ~1.9 GB of unstripped foreign
  cross-compiler binaries in the amd64 wrapper.
- **XC3-INERT** - run-id/parent-digest annotations are never written
  (`append_runtime_image_output` is `-t` only), so the mixed-generation gate
  cannot fail. Concretely: this manifest mixes two source revisions
  (amd64 58e6c325, arm64+riscv64 5105da8f), visible only via image labels.
- **SMK1-3ARCH** - smoke-torch-venv.sh still exempts riscv64 from the cv2
  GStreamer assert and prints "riscv64: gstreamer OFF by design" on the same
  line where the probe reports GStreamer=YES.

## 2026-08-21 - WAVE-4 SHIPPED: the 9-mine validating rebuild (closure window + 21 bumps)

`:latest-cross` = amd64 `73927a45` / arm64 `345096db` / riscv64 `da763dc3`
(manifest `98d90db6`). Byte-gate PASS x3; cv2 GStreamer:YES verified on
shipped amd64 AND arm64 bytes. The rebuild validated the entire closure
window (21 Linux version bumps, RV1, NET1 mirrors, DF1-4, AP3-correct,
PAR2/PAR4+amend, CCACHE_COMPILERCHECK=content, BT1/BT2) and flushed NINE
real defects only a live build could find:

1. VULKAN_SDK_SHA256 not in the bump tool's refresh net (killed sdk x3) -> BT1.
2. TENSORFLOW_C 2.21 is a git tag with NO artifact (2.19+ tarballs 404) -> BT2
   + the sha256('') empty-download trap, now rejected.
3. ORT 1.29 flipped telemetry DEFAULT-ON -> pulls cpp_client_telemetry whose
   vendored sqlite dies on GCC-16 -Werror (arm64) -> --no_telemetry (also a
   hygiene win: no MS telemetry SDK in shipped images).
4. PAR4-amend: the x-budget divisor over-throttled SHARED stages (compiler at
   1/3 jobs); shared stages now divisor 1. LLVM 50 min vs 11h projected after
   the ccache-content fix.
5. RV1's ports glib-2.0.pc expands prefix/libdir EMPTY in cross pkg-config ->
   poisons every glib lookup (5 distinct failure shapes) -> reverted for
   riscv64; precise root cause filed as RV1-GST-PC.
6. gobject-introspection-1.84 glib-subproject break under the new sysroot ->
   riscv64 introspection off (arm64 parity).
7. sccache rustc-wrapper server death x3 at 99% of gstreamer -> silent wrapper
   disabled (returns via controlled ENABLE_SCCACHE_RUST/SCC1).
8. opencv contrib freetype cross-links HOST harfbuzz on riscv64 -> module off.
9. buildkitd session rot after ~1-2h parallel load (grpc cancels at export,
   DeadlineExceeded) -> BKD1 filed; interim: restarts (cachemounts survive,
   proven 12x by prune-safe with ~1 TB reclaimed, zero losses).

riscv64 shipped state: wave-3 parity minus the libcamera gst element
(documented RV1-GST-PC residual). PAR1: sdk 2.9x stands; clean full-chain
timing deferred to one undisturbed run.


## 2026-08-18 - WAVE-3 SHIPPED: :latest-cross re-ship + the parallel-archs hardening saga (PAR2/PAR3/PUSH1/PAR4/CACHE1)

Fresh 3-arch `:latest-cross` (amd64 `fd0d8d74` / arm64 `6153d76b` / riscv64
`549789b8`), byte-gate PASS ×3, cv2 GStreamer:YES re-proven on shipped bytes.
The run doubled as the first real `--parallel-archs` hardening campaign:

- **CACHE1 SHIPPED+PROVEN**: `linux/host-config/prune-safe.sh` (filtered
  buildctl prune) + buildkitd gcpolicy pair applied live. 5 mid-run prunes,
  ~350G reclaimed total, **0 cachemount losses** (proven before/after each);
  ccache persistence confirmed (7.3 GB after mount release).
- **PAR2 SHIPPED+VALIDATED**: cache-mount ids split per ${TARGET_ARCH} (the
  ${TARGETARCH}=amd64 collision serialized all lanes on locked apt mounts —
  onnxruntime deps+fetch held them ~90 min). Post-fix: all 3 lanes compiled
  simultaneously (load 27-35 vs 4).
- **PAR4 INCIDENT+FIX**: removing PAR2's accidental serialization exposed the
  divisor's blind spot — 3 lanes hit IREE simultaneously, OOM-killed cc1plus
  ×2. Root cause: BUILD_MEM_DIVISOR ignored buildkitd max-parallelism
  intra-build steps. Fix: divisor ×= PAR_INTRA_STEP_BUDGET (default 2) under
  --parallel-archs (3-way → 6). Fully documented (tuning doc § second-order
  trap, AGENTS.md recipe note).
- **PAR3 SHIPPED**: PARALLEL_STAGES=all|csv per-stage parallelism control.
- **PUSH1 SHIPPED+MEASURED**: zstd layer compression on cross-stage pushes —
  media pushes ~10 min (vs 23-30 min gzip class).
- **OCV-FF1 RESOLVED**: shipped /opt/ffmpeg/lib HAS libswresample.so+.pc →
  opencv-5.0.0 FindFFMPEG probe quirk (fix on opencv side, next window).
- Ops lessons hardened into memory/docs: registry-cache DeadlineExceeded
  flake class (NO_CACHE_EXPORT=1 recovery), `nerdctl system prune` removes
  TAGGED non-container images (registry-pinned handoffs saved the run),
  wrapper smokes (SMK1-3) live-gated all three shipped wrappers.

## 2026-08-17 - BATCH-2 BIG WAVE SHIPPED: full 3-arch rebuild, opencv two-pass proven, GPU-lane fixes

Full base→:latest-cross rebuild (owner-chosen "everything incl. TG1 in one
rebuild") shipped FRESH digests amd64 `0cba6b61` / arm64 `ebc7562` / riscv64
`6a87341d`. Byte-gate PASS ×3 (libtensorflow absent). Manual byte-verification
of the shipped amd64 wrapper:

- **opencv ⇄ gstreamer TWO-PASS PROVEN**: `cv2.getBuildInformation()` reports
  **GStreamer: YES** — the shipped OpenCV links the source-built GStreamer
  (new `opencv-gst` pass-2 stage). Follow-up OCV-FF1: FFMPEG backend still NO
  (pre-existing, now visible) — likely opencv-5.0.0 vs ffmpeg n9.0.
- **AP2**: /opt/venv byte-compiled (.pyc present) — no more per-start re-parse.
- **AP4 complete**: media libs stripped across all prefixes (.symtab=0 verified).
- **AP1**: cross wheels stripped (RECORD-safe). **AP5**: CPython --with-lto.
- **TG1 (bounded)**: cmake/vulkan lazy + toolchain mounts trimmed — survived the
  full compiler stage; a cmake/vulkan edit no longer re-runs the 3655s GCC build.
- **Guard-helper wiring** live in both common.sh lanes.
- Regressions held: S2 (TF absent), GST1 (dev surface resolves), RP6 (PATH clean),
  torch 2.13.0 intact.
- **AP3 REVERTED mid-run** (80a81eb): the wheelhouse bind-mount sat in the wrong
  RUN — Dockerfile.torch (FROM package) is where setup-torch-venv reads
  /opt/wheels and it has no artifact-source stage → all 3 wrappers failed;
  reverted + runtime stage re-run. Re-filed with the correct approach.

Same day, GPU lane (opt-in, commit e51a0da): **GPU7** — broken `_trt_deb`
substitution (`|| true` OUTSIDE `$()`) made the default no-EULA-deb nvidia build
die at deb staging; **GPU1** TensorRT silent-skip fixed (apt-get update before
the NVIDIA-repo path; the shared apt-lists cache had been wiped by an earlier
RUN); **GPU2/3** verification now CUDA_STACK_STRICT=1 (was fail-open with ALL
components missing); **GPU4** in-cache-mount lists-rms dropped; **GPU5** ROCm
amd64 guard enforced; **GPU6** COPY --link. Awaiting one nvidia/amd lane build.

Also: backlog deep-look additions from the first GPU-lane sweep, shipped-image
posture sweep (POS1 app .git ships in image, PROV1 empty OCI labels), build-log
mining (LOG1-7 incl. libfuse3-3 absent on resolute + onnxruntime-web missing
webgpu JS), PAR1 measured (--parallel-archs ready: media 8.5h sequential vs
~3.5h parallel, divisor wiring verified), and smoke-gap self-review (SMK1-3).

## 2026-08-16 - FULL 3-ARCH REBUILD: Batch-2 subset shipped; :latest-cross re-shipped (fresh digests); 2 real bugs flushed

A full base→:latest-cross rebuild (all 3 arches) validated the 2026-08-15 staged
Batch-2 subset and re-shipped `:latest-cross` with FRESH per-arch digests amd64
`509027696e16` / arm64 `bdb46c953954` / riscv64 `28e3ded96f72` (all differ from
the prior d92cc0fb/99531bbe/252ca5e8). Byte-gate PASSED 3/3 (`libtensorflow
absent`); a manual pull of the amd64 wrapper confirmed libtensorflow gone,
ffmpeg 9.0 intact, GST1 `multiarch -> lib/x86_64-linux-gnu` resolves (no
self-link), `/root/.local/bin` gone from PATH, stripped prefix sizes.

- **DONE + LIVE**: AP7 media-half (per-prefix size report), RP6 (dropped dead
  `/root/.local/bin` from the shipped PATH), GST1 root fix (configure-runtime
  resolves the real gstreamer libdir — "dev surface resolves" 3/3), AP4 strip
  (ffmpeg/gstreamer/libcamera), TS1 (appimagetool pinned to 1.9.1).
- **Bug flushed — smoke-media cv2/numpy** (`0b2b306`): the native cv2 import test
  hard-failed because numpy is absent in the media BUILD sandbox (it is a
  /opt/venv packaging dep). Gated on `import numpy`; absent → defer to the
  runtime torch-venv smoke, exactly like the onnxruntime test. Killed media-amd64
  first — invisible to the runtime-lane validations because they skip smoke-media.
- **Bug flushed — GST1 self-referential multiarch symlink** (`22fb812`):
  `configure-runtime.sh` runs a SECOND time in the package stage on a payload
  that already carries `lib/multiarch`; the resolver glob matched it and
  re-pointed multiarch at itself, and the fail-loud assert killed riscv64 before
  the repair net could act. Fixed: rm the stale link + skip it in the resolver +
  downgrade the assert to WARN (the pkg-config gate is the fail-loud authority).

## 2026-08-15 - VALIDATING REBUILD: RP1/RP2/RP3/AP7 proven live; :latest-cross re-shipped (fresh digests)

A full runtime-lane rebuild (build-runtime-manifest.sh on the TF-less android
pins) validated this session's staged runtime-hygiene changes against a real
3-arch build + on-target smokes, and re-shipped :latest-cross with FRESH per-arch
digests amd64 `d92cc0fb` / arm64 `99531bbe` / riscv64 `252ca5e8`.

- **RP1 (setuid-sudo purge)** — `check_setuid_inventory` reported "no setuid sudo
  in the shipped image" on all 3 arches; pulling the amd64 wrapper confirmed
  `/usr/bin/sudo` + `/usr/local/bin/sudo` are ABSENT. Security win proven live.
- **RP2 (apt cache-mount guards)** — the package + torch builds succeeded on all
  3 arches with the `mountpoint -q` guards in place.
- **RP3 (HEALTHCHECK 5s→30s)** — the shipped wrapper reports `Timeout:30`.
- **AP7 (size observability, runtime half)** — `check_size_observability` emitted
  the per-prefix `du` breakdown on all 3 arches.
- **Regression checks held**: the RTCACHE3 `-t` fix produced three FRESH wrapper
  tags again (no stale reuse); the byte-gate PASSed on all 3 (content matches
  toggles); S2 held (libtensorflow still absent from the pulled wrapper); all
  on-target smokes 0 failures.

RP1/RP2/RP3 + AP7-runtime-half are now closed. AP7 media-half remains open.

## 2026-08-15 - backlog: gate/dead-code hardening (A1, forensic#3, TS6, cross-wheel SOABI, litert-web integrity)

Static-validated code-only fixes (no rebuild), each verified against the failure
it addresses:

- **litert-web npm dist.integrity verification (install-litert-web.sh)**:
  `_fetch_npm_package` downloaded the @litertjs/* tarballs with NO integrity
  check. It now fetches the registry packument's published `dist.integrity`
  (sha512) and verifies the downloaded tarball against it — a MISMATCH refuses
  the package (return 1), and since litert-web vendoring is already non-fatal the
  image ships WITHOUT a tampered/corrupted dependency instead of installing it;
  metadata-unavailable warns + proceeds (no worse than before). Validated against
  the live registry: real @litertjs/core@2.5.3 matches, a 1-byte-tampered tarball
  is refused.

- **cross-wheel SOABI/default-triple assert (verify-wheels.sh)**: the filename-tag
  loop only checks the Python tag (cp314), which is host==target — so it cannot
  catch a native extension stamped with the wrong arch SOABI (a cross build that
  leaked the host BUILD_PYTHON's `.cpython-314-x86_64-linux-gnu.so` into a riscv64
  wheel), which installs fine and only fails at `import` on-target. Added a pass
  that reads each wheel (python zipfile — no unzip) and checks native
  `.cpython-*.so` members against the expected `.cpython-XY-<target-triplet>.so`.
  Crucially derives the triplet from TARGET_ARCH, NOT the running interpreter's
  EXT_SUFFIX (this script runs on the amd64 host during a cross build, so the host
  suffix would falsely reject every correct cross wheel). abi3 + pure-python +
  bundled non-extension .so are skipped. Advisory (WARN) by default so a wrong
  triple map can never break an un-revalidatable build; WHEEL_SOABI_STRICT=1 makes
  it fatal. Unit-tested: correct/wrong-arch/abi3/pure-py/generic all classified
  right; triplet map matches test-arch-mapping.sh.

- **A1 (dead-alias)**: removed the never-set, undocumented `${UBUNTU_PORTS_MIRROR_URL:-}`
  inner fallback at cross-env.sh:17 (only the `FAST_`-prefixed variant is a real
  operator knob). ARCHITECTURES was found NOT dead (documented alias + live 3rd
  fallback in resolve_arch_list) and kept — the backlog premise was wrong.
- **forensic#3 (smoke-media)**: the opencv cv2-import else-branch no longer PASSes
  unconditionally. It now `cross_build_is_active`-gates — cross build → legitimate
  PASS-with-caveat (foreign-arch extension can't import on the host), NATIVE build
  → `fail` with the real import error surfaced. The old "import failed in build
  sandbox — will work at runtime" masked a genuinely-broken native cv2 as green.
- **TS6 (vulkan cross-targets)**: `_build_vulkan_targets` now tracks attempted/built
  per component (loader/SPIRV-Tools/glslang), logs an "N/M component(s) built"
  summary, and on ALL-attempted-failed WARNs loudly (an env-shaped cause — broken
  cross toolchain — that used to exit 0 silently); `VULKAN_CROSS_STRICT=1` promotes
  it to fatal. The arch-independent header-staging cp guards were split so a cp
  that fails with the source dir PRESENT warns instead of being masked as "source
  absent" by the old `2>/dev/null || true`. Success path byte-unchanged
  (conservative: no default hard-die on a load-bearing toolchain fn with no build
  to validate against).

## 2026-08-15 - S2 SHIPPED: libtensorflow removed from ffmpeg (−~500MB), :latest-cross re-shipped with FRESH digests after root-causing a 5× stale-ship bug

- **`:latest-cross` re-shipped with genuinely fresh per-arch wrappers** — manifest
  now indexes amd64 `f1a205a6`, arm64 `d5ae1470`, riscv64 `6024f28a` (the stale
  `35c1f1df`/`e677e4f8`/`5002954385` are GONE; 0 stale refs in the index). All 3
  on-target smokes 0 failures.
- **S2 verified live**: pulled the shipped amd64 wrapper and confirmed
  `opt/ffmpeg/lib/libtensorflow.so.2` + `libtensorflow_framework.so.2` are ABSENT
  (−~500MB), ffmpeg (`libavcodec.so.63`) intact, onnxruntime still present.
  `FFMPEG_ENABLE_TF=0` is the default (versions.env + Dockerfile.media ARG).
- **ROOT CAUSE of the 5× stale-ship saga — RTCACHE3** (`runtime-build-fns.sh`
  `append_runtime_image_output`): the runtime lane tagged the wrapper with the XC2
  provenance exporter `--output type=image,name=<tag>,annotation.*`. On this
  rootless nerdctl+containerd host that exporter builds the image into buildkit's
  content store but **creates NO local containerd tag** (proven with a minimal
  busybox repro: `--output type=image,name=X` → X absent; `-t X` → X present). So
  the freshly built wrapper was invisible — `runtime_push_tag` (`nerdctl push`)
  and `nerdctl manifest create` both resolved the STALE pre-existing tag from a
  prior run, shipping byte-identical every time. It only ever "worked" because the
  first-ever build had no stale tag to be stuck on. The annotations never reached
  the registry either (the perennial "carry no run-id annotation … provenance
  unverifiable" WARN was the visible symptom). **Fix**: use plain `-t` on both
  paths (reliably creates AND overwrites the local tag); inert annotations dropped.
- **Red herring corrected**: the earlier RTCACHE1 diagnosis (runtime wrapper
  registry-cache-hit) was WRONG — the fresh media (`f3c64fbb`) and android
  (`dee9049d`) were pulled and found already TF-less; the problem was purely the
  tag never moving. Lesson reinforced: **verify the shipped BYTES (pull+inspect),
  never trust "manifest pushed" = "fresh shipped"** — this manual check caught all
  five stale ships.
- **New escape hatch — `RUNTIME_NO_CACHE=1`** (`runtime-build-fns.sh`): gates
  `--no-cache` on the runtime package+wrapper builds as a hard guarantee against
  BuildKit worker-cache reuse of a stale `COPY /opt/ffmpeg` layer. Distinct from
  `NO_CACHE=1` (whole chain) and `CROSS_NO_LOCAL_CACHE_EXPORT=1` (write-only).
- **New automated byte-gate — `verify-shipped-wrapper.sh`** wired into
  `build-runtime-manifest.sh`'s per-arch loop BEFORE the manifest is assembled.
  It lists each wrapper's rootfs (`nerdctl export | tar -t` — arch-agnostic, no
  qemu) and asserts the shipped `/opt/ffmpeg` lib set matches the versions.env
  toggles: `FFMPEG_ENABLE_TF` ⇒ `libtensorflow` present/absent, ffmpeg intact
  (`libavcodec`). A toggle-mismatched or stale wrapper now aborts before
  `:latest-cross` goes live — the manual pull+grep that caught all five stale
  ships, automated. Tested: PASS on the fresh f1a205a6, FAIL on a synthetic
  TF-present-with-toggle-off image and on an empty-ffmpeg image.
  `WRAPPER_CONTENT_GATE=0` downgrades it to advisory.
