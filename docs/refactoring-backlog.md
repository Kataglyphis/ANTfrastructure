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
SDK re-stage), and the E-section trigger watches. The B/LLM-BENCH group (2026-08-31) is
CLOSED — kept for one wave so its measured numbers stay beside the code.

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

## B. LLM-BENCH — GenieX session harvested into `linux/llm-stack` (CLOSED 2026-08-31)

All nine items implemented and validated live against GenieX lanes on the same
day they were filed. Kept here (not archived) for one wave so the measured
numbers stay next to the code that produced them.

- **LB1 — correctness probe** [DONE] `--correctness` / `--correctness-only`
  (exit non-zero on a wrong answer); `run_benchmarks.sh` gates the sweep on it
  (`BENCH_SKIP_CORRECTNESS=1` bypasses). Validated: Qwen3-4B `Q4_0` 6/6,
  `IQ3_XXS` 0/6 BROKEN — the case every speed metric rated as a good run.
- **LB2 — TTFT/prefill** [DONE] `ttft_s`, `prefill_tok_per_sec`,
  `decode_tok_per_sec` (the pre-existing `tokens_per_sec` divides by the whole
  request and so hides prefill inside what reads as a decode rate).
- **LB3 — time to a finished answer** [DONE] `wall_s_to_answer` +
  `thinking_char_share`. A live run showed **77–86 % of output was `<think>`**.
- **LB4 — multi-endpoint + concurrent aggregate** [DONE] new `bench_lanes.py
  --lanes`. Reproduced the manual finding within 0.5 %: NPU **+0 %** when a CPU
  lane joins, CPU **−18 %**, aggregate 39.9 tok/s = 1.57x the best single lane.
- **LB5 — batching probe** [DONE] `bench_lanes.py --batching`. Verdict
  `SERIALISED` on GenieX: second request's TTFT 74.27 s vs the first's 74.10 s
  total.
- **LB6 — GGUF introspection** [DONE] new `inspect_gguf.py`: header-only read,
  tensor-type histogram, OK / LIKELY OK / RISKY verdict, exit 1 on RISKY.
  Correctly separates the broken `IQ3_XXS` (97.6 % sub-4-bit i-quants) from the
  working 27B `UD-Q4_K_M` (0.8 %).
- **LB7 — de-Ollama'd** [DONE] `LLM_BASE_URL` (old name still honoured);
  `detect_model_via_api` asks `/v1/models` first and takes a `base_url`. The
  hardcoded `"gemma4:26b"` probe is gone — it returned that name on any 200,
  mislabelling every non-gemma host.
- **LB8 — worker vs listener** [DONE] `top_cpu_processes()` primes before and
  reads after each request, so the summary names the PID that actually burned
  CPU. Encodes the trap: GenieX's port owner read 11 % of 800 % while its
  worker sat at 752 %.
- **LB9 — cross-platform hardware info** [DONE] `platform`/`psutil` fallback
  after the `/proc` reads, plus an explicit `incomplete` list so a gap is
  visible instead of silent.

**Viewer + test debt closed 2026-08-31 (second pass).** The first pass wired
the new metrics into the result JSON but not into the React viewer, although
LB2/LB3 explicitly said "and the viewer" — the data flowed in and surfaced
nowhere. Now: a correctness banner above every speed number, time-to-answer as
the leading column, TTFT/decode/prefill/thinking-share in the comparison and
drill-down tables, the busiest process per request, and legacy runs degrading
to `-` (charts drop them rather than drawing a `0` that would claim an instant
first token). `bench_lanes.py` and `inspect_gguf.py` gained 15 unit tests
(synthetic GGUFs, an in-process SSE server), taking the suite to 30 unit tests
that need no running stack. A server-side smoke render (`npm run smoke`)
renders every component against the real manifest, because `vite build` only
proves the JSX compiles — it caught a silently-failed edit that made the
comparison table render empty cells.

**Probe calibration fix:** truncation is now reported apart from wrongness
(exit 2 = INCONCLUSIVE, exit 1 = genuinely wrong). A model cut off mid-thought
was not wrong, it was unmeasured, and scoring it as a failure made a healthy
model look degraded. The arithmetic probe also moved 847*293 -> 23*17: a
healthy 4B could not finish the former inside 4000 thinking tokens, so the
check cried wolf on good models.

**Two pre-existing bugs found while doing this**, both fixed:
- the SSE parser matched `"data: "` **with** the space (optional per spec).
  GenieX omits it → nothing parsed, 0 tok/s reported, no TTFT possible. The
  harness was effectively blind to every non-Ollama server.
- servers ignoring `stream_options.include_usage` yielded 0 tokens; now falls
  back to a counted chunk total flagged `tokens_estimated`.

**Still open for a general LLM toolkit** (out of scope of the original harvest,
listed so it is not forgotten): context-length quality scaling, tool/function
calling correctness, embedding benchmarks, energy per token, and run-to-run
regression comparison.

**Explicitly NOT for llm-stack:** `windows/scripts/host/start-geniex-servers.ps1`
stays where it is — Windows-host lane management, not benchmarking.

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
