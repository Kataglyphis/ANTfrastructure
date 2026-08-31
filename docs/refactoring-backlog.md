# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**LB**=llm-stack benchmark harness ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-31, after the A1 closure window. **The entire A1 work
section is CLOSED** (ERR-trap bug, complexity queue, modules.sh refuted) and so
is **GEN1**, which was built and wired ON. What that left open is not more
refactoring — it is **validation**: two lanes (QNN-LINUX and the new riscv64
GenAI) are wired but have never been proven by a real build, and one of them is
deliberately gate-red until that build happens. The LLM-BENCH group (2026-08-31, § D) is
also CLOSED — kept for one wave so its measured numbers stay beside the
code that produced them.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
2. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, SH1 retry
   semantics, SH2 non-exiting error(), DUPN2 two-pass arg mirror) —
   re-verified intentional across five sweep rounds. **modules.sh's candidate
   ORDER and its dir-walker join this list (2026-08-31, closed by refutation).**
3. Disk reclaim mid-run: prune-safe.sh → targeted rmi of pushed tags →
   NEVER system/image prune while a chain runs (removes TAGGED locals).
   SHARPENED 2026-08-21: `nerdctl system prune` ALSO wipes the buildkit
   store INCLUDING exec.cachemount records (35→1 observed) — even with no
   chain running it costs the compile caches. It is the last-resort hammer
   ONLY; prune-safe + rmi + kata-buildcache/archive-log trims come first.
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.
5. **A test that cannot fail is worse than no test.** Two 2026-08-31 findings
   were gates that looked green while proving nothing (see the archive: the
   ugrep `--`-as-option bug, and `rc==1` passing for the wrong reason). When you
   add a regression test, MUTATE the thing it guards and confirm the test goes
   red. State in the header exactly what is and is not covered.

## A. Needs a real BUILD to close (not more code)

### A1. GEN1 validation — the riscv64 GenAI lane is WIRED but UNPROVEN [★★★]

Built and wired ON 2026-08-31. Nothing here has seen a riscv64 build; it is all
source-read. **This is the highest-value thing the next media-riscv64 build can
settle.**

Mechanism, the full watch-list and the back-out procedure live in
[`gen1-riscv64-genai.md`](gen1-riscv64-genai.md) — that page owns them. What is
OPEN, i.e. what a build must still settle:

- **Does it compile, link and generate sane tokens on riscv64?** Seven things
  can bite, in a known order (compile → target python dev files → llguidance
  linking → `EXT_SUFFIX` → `-latomic` → performance → crates.io fetch). Token
  sanity is the one no gate here can prove: upstream #594 is a RISC-V build that
  compiled, imported and emitted nonsense, and smoke tiers 1-3 pass in that
  state. Arm tier 4 with `GENAI_MODEL_DIR`.
- **Did the `--use_guidance` preflight FIRE?** `60-build-genai.sh` drops the flag
  with only a WARN when rustup lacks the riscv64 std. The wheel then ships
  WITHOUT llguidance and is parity-divergent from amd64/arm64 — and NO gate can
  see it. Grep the riscv64 genai stage log for `dropping --use_guidance`; if it
  fired, fix `install-rust.sh`/`CROSS_TARGETS` and rebuild rather than shipping.
- **ARCH-PARITY is RED ON PURPOSE until that build lands** — every
  currently-shipped riscv64 image now fails the genai assertion. Do not "fix" it
  by re-adding the exemption.
- **Raise the riscv64 app-wheel floor 12 → 13 only after a real run PRINTS 13.**
  Raising a floor a run cannot reach reds the gate for the wrong reason.
- **The new `validate-media-runtime.sh` genai NEEDED scan has never run against
  a real image** on any arch. It is expected to be a no-op on amd64/arm64.

### A2. QNN-LINUX — fan-out validation, BLOCKED on the login-gated SDK

- **CORRECTED 2026-08-31 — three of the four fan-out flags were invented.** The
  wiring "mirrors Windows #121 exactly", and Windows #154 established that
  `TFLITE_ENABLE_QNN`, `USE_QNN` and `IREE_TARGET_BACKEND_QNN` are not upstream
  options: CMake drops an undeclared `-D` silently and exits 0, so all three logged
  success and did nothing. Only ORT's `onnxruntime_USE_QNN` was ever real. TVM and
  IREE have no Qualcomm path at all and their flags are gone. LiteRT's IS real but
  under a different name — `LITERT_ENABLE_QUALCOMM`, auto-forced ON by
  `QAIRT_HEADERS_DIR` — and this lane already configures the right tree (`litert/`),
  so it is now correctly wired for the first time.
  **A second defect fell out of the same reading, and it is live on every build:**
  `litert/vendors/CMakeLists.txt` `file(DOWNLOAD)`s QAIRT 2.47.0.260601 from
  softwarecenter.qualcomm.com whenever `QAIRT_HEADERS_DIR` is empty — ~1.5 GB, **no
  `EXPECTED_HASH`, no `STATUS` check**, and NOT gated on `LITERT_ENABLE_QUALCOMM`, so
  it fired on every LiteRT configure including builds that want no NPU. It cannot be
  dodged with a stub path (any non-empty value force-enables Qualcomm with headers we
  do not have), so `_litert_disable_qairt_header_download` short-circuits the guard
  when no SDK is staged. MediaTek's NeuroPilot fetch from AWS S3 and the Samsung
  LiteCore fetch are suppressed with stub header dirs — both gate on the header
  EXISTING, so a stub is safe there.
  **Still unvalidated by a build** — see below; this corrects the wiring, it
  does not prove it.

Wiring is LANDED and fail-safe (no zip = byte-identical behaviour on every arch,
validated by the 2026-08-30 media rebuilds). ORT was PROVEN on real QAIRT
v2.49.0.260730. What is unproven is the OPPOSITE direction: with a REAL zip
staged on arm64, do the two builds that really have a QNN path (ORT, LiteRT)
stay GREEN and do the staged libs land? That one run also answers LiteRT's
QNN-manager header fetch and the wheel-staging question.

**Owner action — smaller than previously written.** `QNN_SDK_LINUX_ZIP_SHA256`
is already IMPLEMENTED and POPULATED with the v2.49.0.260730 hash, so
re-staging **that exact version needs NO re-pin** — the existing hash validates
it and a mismatch means a different build was downloaded. Only a NEWER SDK needs
`sha256sum <zip>` + a versions.env update in the same commit. Steps: download
the Linux AArch64 SDK from qpm.qualcomm.com (Qualcomm ID + EULA), drop the zip
in `linux/qnn-sdk/`, rebuild media-arm64, remove the zip afterwards (README
discipline). `QNN_SDK_LINUX_LIBDIR` (default `aarch64-oe-linux-gcc11.2`) is the
single knob if a newer SDK renames the lib subdir. Corrected README: 2026-08-31.

## B. Flagged, deliberately NOT fixed (blast radius > value right now)

Found during the 2026-08-31 GEN1 review. The two RISK-REDUCING ones were fixed
the same day (see the archive); this is what deliberately remains.

- **The genai RUN in Dockerfile.media mounts no cargo registry/git cache** [S·★],
  so llguidance's crates are fetched from crates.io on every uncached build
  behind only `retry 3 10`. Already true for arm64, so fixing it changes that
  lane's cache behaviour — it is risk-NEUTRAL for correctness and would re-key
  the arm64 genai layer, which is why it was left out of the 2026-08-31 window.
  Note it if the riscv64 genai stage flakes on the network.

## C. Pre-existing, found while auditing 2026-08-31

- **`test-preflight-slugs.sh` feeds `comm` unsorted input** [S·★★] — every run
  prints `comm: file 1 is not in sorted order` (×2) and still reports
  `5 assertion(s) passed`. `comm` on unsorted input does not compute a correct
  set difference, so its `_missing` / `_orphan` assertions may be passing
  VACUOUSLY. Not touched by the 2026-08-31 window (the file is unmodified), but
  it is exactly the toothless-gate class standing rule 5 is about. Sort both
  inputs, then re-check that the assertions still pass for the right reason.

## D. LLM-BENCH — GenieX session harvested into `linux/llm-stack` (CLOSED 2026-08-31)

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

**Closed since the original harvest:** context-length quality scaling
(`bench_coding.py --context-tokens`, § 1e of the GenieX page) and tool/function
calling correctness (`bench_tools.py`, § 1f) — the latter found the one result
that does not crown the coding winner.

**Still open for a general LLM toolkit** (listed so it is not forgotten):

- **LB10 — embedding benchmarks** [M·★★] `tests/test_v1_api.py` exercises the
  embedding endpoints but nothing measures them. Relevant the moment a RAG or
  code-search path is added.
- **LB11 — run-to-run regression comparison** [S·★★] Every tool writes a JSON
  report and nothing diffs two of them. Without it a model swap or a runtime
  bump can silently cost accuracy or speed. Probably the highest-value item
  left: it turns a pile of one-off measurements into a tripwire.
- **LB12 — energy per token** [M·★] The interesting axis on a battery device,
  and the NPU's real argument over the CPU lane (165 % vs 752 % of 800 % CPU
  says something about power but does not measure it).
- **LB13 — measurements not yet run on this host** [S·★] hybrid lane on coding
  tasks, `nctx` scaling below 16384, `--ngl` on the GPU lane, and the model
  candidates never tried: `Qwen3-8B` W4A16 (the winner's direct competitor —
  same fast prefill, same 4096 ceiling, twice the parameters), a
  code-specialised GGUF such as `Qwen2.5-Coder-7B`, and the other QAIRT bundles
  (`Ministral-3-3B-Instruct`, `Gemma-4-E2B-it`). **Every model measured so far
  is from one family (Qwen3/Qwen3.8)** — that is the largest gap in the
  ranking's authority.

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
- **MESON-GI — meson 1.12 breaks gobject-introspection's glib-subproject
  resolution (riscv64 cross gst)** [S·★, WATCH]. Pin in place:
  `setup-gstreamer.sh` installs `meson==1.11.2` for riscv64 cross only
  (amd64 native + arm64 no-introspection are fine on 1.12).
  **RE-PROBED 2026-08-31: still 1.12.0.** `git ls-remote mesonbuild/meson`
  shows no 1.12.x point release and no 1.13 — so no released meson fixes it yet
  and the pin stays. (Note: the repo pins `GOBJECT_INTROSPECTION_VERSION=1.86.0`;
  earlier notes here said "g-i 1.84", which was stale.) Retest by removing the
  pin in a closure window once meson moves.
- **NODE-RV — riscv64 ships Node v22 (pin: 26.8.1)** [S·★, WATCH].
  ubuntu-ports has no 26.x for riscv64; the install falls back fail-open with a
  WARN (by design, seen in every wave-4 smoke log).
  **RE-PROBED 2026-08-31: ports `resolute` (26.04) riscv64 universe still ships
  `nodejs 22.22.1+dfsg+~cs22.19.15-1ubuntu1`** — no 26.x, so the fallback stays
  correct. Re-check at each bump window.
  NB (2026-08-27): the pin moved 26.8.0 → 26.8.1 because the OFFICIAL v26.8.0
  tarball self-reports `26.8.0-alpha.0.0.0` and its own bundled npm then refuses
  it (semver puts a prerelease outside `>=22.9.0`). Re-check the REPORTED
  version, not just the tarball name, at every bump — the gate that missed it
  compared a PREFIX and has since been tightened to an exact match.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.
