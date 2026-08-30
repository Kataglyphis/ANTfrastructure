# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-28 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-30 (added QNN-LINUX Snapdragon plan A2 + landed scaffold dir; trimmed done sub-narrative: compiler-cache GPU sites, --no-push guard, MESON-GI pin — all confirmed shipped)

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

## F. Refactor candidates found while switching ccache -> sccache (2026-08-26)

Collected DURING the switch and the staged rebuild, each with the evidence that
produced it. None of these blocks the current run; they are the debt the switch
either created or exposed.

- **sccache caches NOTHING in the OpenCV step** [M·★★★, OPEN 2026-08-26] The
  TryCompile root cause is fixed and the guarded launcher keeps the build alive
  (1451 saves, 0 aborts), but in the opencv step sccache fails on EVERY compile
  — now with the main build dir `/tmp/opencv-1/build` as cwd, not a deleted
  scratch dir. So OpenCV builds fully UNCACHED while every other step caches
  normally. The guard makes this survivable and VISIBLE; it does not fix it.
  Do not re-run these nine disproven hypotheses: missing compiler; dangling
  update-alternatives (never ran in that stage); apt reinstalling sccache
  (it did not); the two sccache versions (0.13 apt vs 0.17 pinned — both work,
  PATH prefers the pinned one); our own `rm -rf` (targets iree-build-HOST);
  a cleared environment; the custom-prefix GCC without LD_LIBRARY_PATH; a
  214-variable environment plus a 120-flag command line; memory or disk
  pressure. Also note an out-of-band `nerdctl run` repro is NOT faithful — it
  cannot recreate BuildKit cache mounts and produced a phantom google-benchmark
  regex failure that appears in no real chain log.
- **Compiler-cache abstraction consolidation** [L·★★, OPEN] 8/9 call sites
  resolve through `compiler_cache_launcher()`; the one duplicate
  (compiler-cache.sh) is a bootstrap layer that cannot source 01-core and
  repeats the resolution inline. Merge all sites onto one resolver; the
  launcher helper is the seam. Needs a closure window.

## A. Window inventory — needs WORK in the wave

### A1. Work items

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★, NEEDS THE REBUILD] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.

### A2. QNN-LINUX — Qualcomm QAIRT/QNN SDK on the Linux ARM64 lane (Snapdragon)

Mirror the Windows QNN EP (#121, `windows/qnn-sdk/`) onto the Linux `arm64`
lane for Snapdragon NPU inference. Same opt-in contract (login-gated zip
dropped by hand, build skips gracefully when absent), **different SDK**:
Linux AArch64 extracts to `qairt/<version>/lib/aarch64-oe-linux-gcc11.2/`
(not `aarch64-windows-msvc`). Scaffold landed: `linux/qnn-sdk/README.md` +
root `.gitignore` rule. Work items 2–6 edit the 03-media / 01-core closure
and MUST batch at a closure window (standing rule #1 — versions.env is
COPY'd in `Dockerfile.sdk:111`, so even a comment busts sdk→media).

1. **Drop dir + .gitignore** [S, DONE 2026-08-30] `linux/qnn-sdk/README.md`
   + root `.gitignore` `linux/qnn-sdk/*` rule. Zero cache impact (new dir,
   not in any closure). `.dockerignore` does NOT exclude it (the bare
   `*.zip` matches root-level only) so a staged zip rides the context —
   stage right before a media rebuild, remove after (TensorRT discipline).
2. **versions.env pin** [S·★, CLOSURE] Add `QNN_SDK_LINUX_ZIP_SHA256=` (empty
   = unpinned, `# noforward`) to `linux/scripts/01-core/versions.env` near
   the existing `QNN_SDK_ZIP_SHA256` (Windows hash — do NOT reuse it). Update
   the comment block (lines ~824-830) to cover both lanes. Empty now; fill on
   first staged Linux zip. BUSTS: versions.env is COPY'd in
   `Dockerfile.sdk:111` → sdk → media rebuild.
3. **Resolve helper** [M·★★, CLOSURE] A bash `resolve_qnn_sdk` in a 01-core
   helper (or the ORT build lib) mirroring `Resolve-QnnSdk`: locate the one
   zip, verify sha256 if pinned, extract, anchor on
   `include/QNN/QnnInterface.h`, assert `lib/aarch64-oe-linux-gcc11.2/`
   backend exists, QNN_OP_STFT canary for ORT version compat, return
   `QNN_HOME` + lib dir (or empty → QNN off). Gated to `arm64` only.
   UPSTREAM RISK: ORT's CMake `onnxruntime_QNN_HOME` may hardcode the
   `aarch64-android` ABI path; Linux needs `aarch64-oe-linux-gcc11.2` —
   verify against the ORT QNN EP CMake before assuming it works.
4. **ORT build wiring** [M·★★, CLOSURE] `30-build-native.sh`: after the
   oneDNN block (~line 86), if `resolve_qnn_sdk` returns a home on arm64,
   append `--use_qnn` + `onnxruntime_QNN_HOME`; stage `libQnn*.so` +
   `hexagon-v*` skel beside the ORT install. amd64/riscv64 stay QNN-off.
   `lib/common.sh:append_onnx_native_base_build_args` is the seam.
5. **Dockerfile.media mount** [S·★, CLOSURE] Add
   `--mount=type=bind,source=linux/qnn-sdk,target=/opt/scripts/qnn-sdk,readonly`
   to the `--step cpu` RUN (`Dockerfile.media:298-304`) and the genai RUN.
   Empty dir = no-op (graceful skip). Stages the zip into the build.
6. **Validation** [S·★, CLOSURE] `validate-media-runtime.sh`
   `VENDOR_ARCH_SKIP_PATTERNS` already lists `libQnn*` (line ~310) — no
   change needed, CONFIRM on first run. Add a `verify-media-artifacts.sh`
   assertion that staged QNN libs land beside ORT only when QNN was on.

Framework fan-out (each gated to arm64, QNN-off when no zip):

| Framework | CMake flag | Linux source |
|---|---|---|
| **ONNX Runtime** | `onnxruntime_USE_QNN=ON` | `30-build-native.sh` (work item 4) |
| **ONNX Runtime GenAI** | inherits from ORT | stage QNN libs beside GenAI install |
| **LiteRT** | `TFLITE_ENABLE_QNN=ON` | `build-litert.sh:236` — `LITERT_ENABLE_NPU=OFF` becomes conditional |
| **TVM** | `USE_QNN=ON` | `05-frameworks/tvm-config.sh` — no QNN today |
| **IREE** | `IREE_TARGET_BACKEND_QNN=ON` | `05-frameworks/torch/build-app-wheelhouse.sh` |

No zip = QNN off with one notice on every framework. The verification
ceiling is the same as Windows/DirectML's: a green build proves the right
bytes ship, never NPU execution — that needs real Snapdragon hardware.

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff + dual-path collapse** [M·★★, OPEN] The
  multi-stage refusal guard is landed (see archive-2026-08-27 § Closed
  2026-08-28). Remaining: the full OCI-layout export + `--build-context`
  handoff (which would make `--no-push` multi-stage actually safe) and the
  dual-path collapse.

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation** — ⚠ the stated trigger has ALREADY
  passed TWICE without validating anything: the flag defaults to 0, so the
  2026-08-24 and 2026-08-25 compiler rebuilds both took the sequential path.
  It is not waiting on a rebuild, it is waiting on someone putting
  `GCC_PARALLEL_TARGETS=1` on the LAUNCH COMMAND. Do that or it will be missed
  a third time.
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
