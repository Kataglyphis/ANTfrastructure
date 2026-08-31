# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-28 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md);
the 2026-08-30 round is in
[`refactoring-backlog-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**LB**=llm-stack benchmark harness ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-30 (cleanup after the rebuild window). Everything the
2026-08-30 waves closed is in the archive — this file holds only what is still
open: the A1 closure-window style debt (incl. the logging.sh ERR-trap bug found
2026-08-30), GEN1, the QNN-LINUX fan-out validation (blocked on a login-gated
SDK re-stage), the new B/LLM-BENCH group (2026-08-31, harvesting the GenieX
measurement session into `linux/llm-stack`), and the E-section trigger watches.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
2. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, SH1 retry
   semantics, SH2 non-exiting error(), DUPN2 two-pass arg mirror) —
   re-verified intentional across four sweep rounds.
3. Disk reclaim mid-run: prune-safe.sh → targeted rmi of pushed tags →
   NEVER system/image prune while a chain runs (removes TAGGED locals).
   SHARPENED 2026-08-21: `nerdctl system prune` ALSO wipes the buildkit
   store INCLUDING exec.cachemount records (35→1 observed) — even with no
   chain running it costs the compile caches. It is the last-resort hammer
   ONLY; prune-safe + rmi + kata-buildcache/archive-log trims come first.
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.

## A. Window inventory — needs WORK in the wave

### A1. Work items (all need a closure window — edits to 01-core/03-media
invalidate compiler/media cache)

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; build_iree_wheels; parse_options
  116-liner; modules.sh dir-walker. (`_cross_stage_build_impl` is already a
  single impl behind two thin wrappers — part of C, closed 2026-08-30; do not
  re-add it.)
- **logging.sh ERR-trap dynamic-scope bug** [S·★, found live 2026-08-30]
  `_install_trap`'s `on_err` reads `${action}` under `set -u`; when the ERR trap
  fires outside the function's dynamic scope the var is unbound and prints
  `action: unbound variable` — REPLACING the real error (it masked the parallel
  GCC apt-lock failure). Fix: capture the handler name in the trap string so it
  is self-contained (e.g. `trap 'on_err "..." ...' ERR` with the action baked
  in), and add a regression test. logging.sh is in the base/compiler/media
  closures, so batch with A1 in a closure window.
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.

### A2. QNN-LINUX — Qualcomm QAIRT/QNN SDK on the Linux ARM64 lane (Snapdragon)

Mirror the Windows QNN EP (#121, `windows/qnn-sdk/`) onto the Linux `arm64`
lane for Snapdragon NPU inference. Same opt-in contract (login-gated zip
dropped by hand, build skips gracefully when absent), **different SDK**:
Linux AArch64 extracts to `qairt/<version>/lib/aarch64-oe-linux-gcc11.2/`
(not `aarch64-windows-msvc`).

**What is DONE (2026-08-30, all in the archive):** drop dir + .gitignore,
versions.env pin, the shared `01-core/qnn-sdk.sh` resolve/stage helper (moved
out of ORT's lib), ORT build wiring PROVEN on real SDK v2.49.0.260730, the
Dockerfile.media mounts, artifact verification, and the framework fan-out
wiring (GenAI/LiteRT/TVM/IREE) — every flag mirrors Windows #121 exactly.

- **Fan-out validation build — BLOCKED on the login-gated SDK.** The wiring is
  in place and fail-safe (no zip = byte-identical behavior on every arch; that
  path was validated by the 2026-08-30 media rebuilds). What is still unproven
  is the OPPOSITE direction: with a REAL QAIRT zip staged on arm64, do all five
  builds stay GREEN and do the staged libs land? (Storm the open items —
  LiteRT's own QNN-manager header fetch, the wheel-staging question — are
  answered by that same run.) The real zip is NOT on the host (removed after
  the PROVEN build per the qnn-sdk README discipline; the buildkit `/tmp` tmpfs
  discarded the in-RUN extraction). **Owner action required:** re-stage from
  qpm.qualcomm.com (Qualcomm ID + EULA), then re-pin `QNN_SDK_LINUX_ZIP_SHA256`
  in versions.env — a fake/round-tripped zip hard-fails the sha check by
  design. QNN_SDK_LINUX_LIBDIR (default `aarch64-oe-linux-gcc11.2`) is the
  single knob if a newer SDK changes the lib subdir.

## B. LLM-BENCH — harvest the GenieX session into `linux/llm-stack`

Added 2026-08-31 after the Snapdragon/GenieX measurement session. That session
re-derived, ad hoc in a scratchpad, a set of capabilities `linux/llm-stack`
already *almost* has — and every wrong conclusion it produced traces to a
metric the existing harness does not collect. `benchmark_openai_api.py` (502
lines) + `run_benchmarks.sh` + the React viewer are a good base; these are the
gaps, ordered by what actually cost time.

- **LB1 — correctness probe beside the speed numbers** [M·★★★] The harness
  measures *only* speed. A model emitting garbage scores **excellently**: the
  GenieX i-quant bug produced fast, fluent nonsense (`'\n\n\n....\n\n'`,
  `' majorityathersyre…'`) that every tok/s metric would have rated as a good
  run. Add a small battery of prompts with **verifiable** answers (arithmetic,
  a capital city, letter counting, a one-step logic puzzle) run at
  `temperature=0`, and record `correct/total` in the result JSON beside
  `tokens_per_sec`. Cheap, and it is the difference between "is it fast" and
  "is it working". Proven discriminating: Qwen3-4B `Q4_0` 6/6 vs `Q2_K` 4/6 vs
  i-quant 0/6.
- **LB2 — TTFT / prefill as a first-class metric** [S·★★★] There is **no
  time-to-first-token measurement at all** (`grep first_token` → nothing). The
  session's central finding is that **prefill, not decode, is what an agent
  waits on**: 13.1 s to first token on a 2.5k-token prompt, while decode fell
  from 19.5 to 13.0 tok/s. Add `ttft_s` and a derived `prefill_tok_per_s`
  (`prompt_tokens / ttft_s`) to the schema and the viewer. Requires `--stream`,
  which the harness already supports.
- **LB3 — report time-to-finished-answer, not tok/s** [S·★★★] The data is
  already collected (`completion_tokens`, `latency_s`) but the table and the
  viewer headline `tokens_per_sec`, which **ranks models wrongly**: Qwen3-1.7B
  is the fastest model measured (31.7 tok/s) and the *slowest* to a finished
  answer (60.8 s) because it is a reasoning model spending ~1900 tokens
  thinking; the 4B-Instruct is 19.5 tok/s and 26.8 s. Add `wall_s_to_answer`
  and sort by it. Consider a `thinking_token_share` derived from a `</think>`
  split — it explains most surprises.
- **LB4 — multi-endpoint + concurrent lane aggregate** [M·★★] `OLLAMA_BASE_URL`
  is a single module-level global. Generalise to N *named* endpoints and add a
  mode that drives them **simultaneously**, reporting per-lane and aggregate
  throughput. This is what produced the whole lane matrix (NPU+GPU 31.4,
  NPU+CPU 39.7, all three 45.4 tok/s) and the finding that the NPU lane is
  immune to contention while CPU and GPU fight for cores. Un-derivable from
  sequential single-endpoint runs.
- **LB5 — batching/serialization probe** [S·★★] Fire two concurrent requests at
  one endpoint: if #2's TTFT ≈ #1's total duration, the server does not batch.
  GenieX does not (measured: 27.6 s), and a busy server stops answering
  `/v1/models` entirely. One cheap check that decides whether capacity comes
  from concurrency or from more servers.
- **LB6 — GGUF introspection as a diagnostic** [S·★★] The tensor-type histogram
  is what actually diagnosed the i-quant bug — **no benchmark could have**,
  because the broken files were fast. A ~40-line GGUF header reader (magic →
  KV metadata → tensor type counts) separates "bad weights" from "bad kernel"
  in seconds and reads only the file head. Pairs with LB1: LB1 detects, LB6
  explains.
- **LB7 — de-Ollama the harness** [S·★] It is Ollama-shaped in ways that block
  reuse: `OLLAMA_BASE_URL`, a hardcoded `"gemma4:26b"` in
  `detect_model_via_api` (line 171, a latent bug — it probes `/api/show` for a
  model that may not exist), the Ollama-only `/api/show` path, and `num_ctx`
  passed via `--extra-params`. Rename to a neutral `LLM_BASE_URL` (keep the old
  name as a fallback), make detection `/v1/models`-first, and treat the
  Ollama-specific bits as one backend among several. Prerequisite for pointing
  it at GenieX, llama.cpp or vLLM.
- **LB8 — attribute resources to the *worker*, not the listener** [S·★] Today's
  sampling is system-wide (Glances/psutil), which is safe. If per-process
  attribution is ever added, note the trap this session fell into: the GenieX
  inference worker is a **different process** from the one holding the port —
  sampling the listener read 11 % of 800 % and suggested the lane was idle,
  while the real worker was at 752 %. Resolve the worker, not the socket owner.
- **LB9 — hardware info is Linux-only** [S·★] `collect_hardware_info()` reads
  `/proc/cpuinfo` and `/proc/meminfo` behind bare `except: pass`, so on a
  non-Linux host it silently records nothing. The GenieX lane runs on a
  **Windows** host, so any cross-host comparison currently loses its
  reproducibility metadata exactly where it is needed. Add a fallback
  (`platform` + `psutil`) and, better, fail loudly when a field is missing.

**Explicitly NOT for llm-stack:** `windows/scripts/host/start-geniex-servers.ps1`
stays where it is — it is Windows-host lane management, not benchmarking. Only
the *measurement* belongs here.

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS on a full push chain** — validated locally 2026-08-30
  (green, ~30 % GCC-RUN saving); the next full chain that wants the parallel
  GCC must pass `GCC_PARALLEL_TARGETS=1` on its command line (it now reaches
  the container — the plumbing fix 92fb9646).
- **gcc-prereq measurement facets** (sig-cache, LIBRARY_PATH leak, verify
  coverage, dup-compile overlap) — needs ccache stats from a real build;
  the "unify prereq paths" reading is CLOSED (deliberately different).
- **post-restart base cache-miss** — observe at the next host reboot.
- **LOG7 — sdkmanager CLI deprecated** — bit-rot watch before Google
  removes it.
- **MESON-GI — meson 1.12 breaks g-i-1.84 glib-subproject resolution
  (riscv64 cross gst)** [S·★, WATCH] Pin is in place:
  `setup-gstreamer.sh` installs `meson==1.11.2` for riscv64 cross only
  (amd64 native + arm64 no-introspection are fine on 1.12). Re-bump when
  upstream meson/g-i fix the `subproject('glib')` resolution — retest by
  removing the pin in a closure window.
- **NODE-RV — riscv64 ships Node v22 (pin: 26.8.1)** [S·★, watch] ubuntu-ports
  has no 26.x for riscv64; the install falls back fail-open with a WARN (by
  design, seen in every wave-4 smoke log). Lift when ports ships 26.x —
  check via `apt-cache policy nodejs` on the ports snapshot at each bump
  window; until then the riscv64 image runs the distro v22.
  NB (2026-08-27): the pin moved 26.8.0 -> 26.8.1 because the OFFICIAL
  v26.8.0 tarball self-reports `26.8.0-alpha.0.0.0` and its own bundled npm
  then refuses it (semver puts a prerelease outside `>=22.9.0`). Re-check the
  reported version, not just the tarball name, at every bump — the gate that
  missed it compared a PREFIX and has since been tightened to an exact match.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.
