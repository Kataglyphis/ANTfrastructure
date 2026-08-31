# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-28 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md);
the 2026-08-30 round (the OpenCV-sccache refutation, F2) is in
[`refactoring-backlog-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-30 (third pass, rebuild window) — TG1/TG3 CLOSED (both
were landed 2026-08-24, never closed; the validating toolchain rebuild is
running now with GCC_PARALLEL_TARGETS=1). GCC_PARALLEL_TARGETS validation
IN-PROGRESS (local compiler build, no push — the flag finally on a real launch
command). QNN-LINUX fan-out validation BLOCKED on the login-gated QAIRT zip:
the real SDK is NOT on the host (removed after the PROVEN build per the
qnn-sdk README discipline; /tmp/qnn-sdk-extract now holds only my synthetic
test stub, and the buildkit /tmp tmpfs discarded the in-RUN extraction). The
staged zip must be re-downloaded by the owner (qpm.qualcomm.com, EULA) and
re-pinned in versions.env before the multi-framework validation build can run;
the no-zip fail-safe path is validated by the media rebuild instead.

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
either created or exposed. Both entries were closed 2026-08-30 — see
[`refactoring-backlog-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md):
the OpenCV "uncached" entry was REFUTED (pre-UDS wrong-server fault, 0
faults on every post-UDS run) and the compiler-cache consolidation (F2)
landed as `_resolve_compiler_cache_launcher()` with the new
`linux/scripts/tests/test-compiler-cache.sh` suite.

## A. Window inventory — needs WORK in the wave

### A1. Work items

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; build_iree_wheels; parse_options
  116-liner; modules.sh dir-walker. (`_cross_stage_build_impl` is already a
  single impl behind two thin wrappers — part of C, closed 2026-08-30; do not
  re-add it.)
- **TG1 residual — fuller toolchain-closure trim** [M·★★, CLOSED 2026-08-30]
  The work described here was landed 2026-08-24 (f485c132 "TG1 bounded: lazy
  cmake/vulkan sourcing + trim their dead toolchain mounts" and the llvm-family
  exclusion in the GCC RUN — see the Dockerfile.toolchain RUN-1 comment audit,
  lines 64-76) but never CLOSED. The validation that remained was "needs a real
  toolchain rebuild" — that ran 2026-08-30 (GCC_PARALLEL_TARGETS=1 compiler
  build, see the archive). The trimmed closure is confirmed: editing an
  unmounted script leaves the compiler layers cached; RUN-3's per-file mounts
  still carry the llvm family, RUN-1's do not (deliberately different lists).
- **TG3 residual — collapse the two toolchain RUNs** [S·★, CLOSED 2026-08-30]
  RUN-3d was DELETED in 202634c1 (2026-08-24, "closure-window-3 wave") — the
  unified superset build in RUN-3 produces both /opt/llvm-cross/<triplet> and
  /opt/llvm-target-<arch>; 3d could only early-return or redo the identical
  build (mode now selects a log string). The gates that used to verify 3d's
  trees are named in the Dockerfile RUN-3 comment and are exercised by the
  2026-08-30 compiler rebuild. No further work.
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.

### A2. QNN-LINUX — Qualcomm QAIRT/QNN SDK on the Linux ARM64 lane (Snapdragon)

Mirror the Windows QNN EP (#121, `windows/qnn-sdk/`) onto the Linux `arm64`
lane for Snapdragon NPU inference. Same opt-in contract (login-gated zip
dropped by hand, build skips gracefully when absent), **different SDK**:
Linux AArch64 extracts to `qairt/<version>/lib/aarch64-oe-linux-gcc11.2/`
(not `aarch64-windows-msvc`).

**ORT wiring PROVEN on real SDK (2026-08-30 build):** staged QAIRT
v2.49.0.260730, built `cross-media-arm64` GREEN. `libonnxruntime_providers_qnn.so`
compiled and linked; 45 `libQnn*.so` backend libs + 7 `hexagon-v*` skel dirs
staged beside ORT; `verify-media-artifacts.sh onnxruntime-cpu` PASS ("QNN
EP present, backend libs staged"); smoke suite 0 failures. The upstream
QNN_ARCH_ABI risk is RESOLVED: ORT CMake accepts `-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2`
(it is a cache var guarded by `if(NOT QNN_ARCH_ABI)`, not a hardcoded `set()`).

1. **Drop dir + .gitignore** [S, DONE 2026-08-30] `linux/qnn-sdk/README.md`
   + root `.gitignore` `linux/qnn-sdk/*` rule. Zero cache impact (new dir,
   not in any closure). `.dockerignore` does NOT exclude it (the bare
   `*.zip` matches root-level only) so a staged zip rides the context —
   stage right before a media rebuild, remove after (TensorRT discipline).
2. **versions.env pin** [S·★, DONE 2026-08-30] `QNN_SDK_LINUX_ZIP_SHA256`
   pinned to the staged zip's sha256
   (`32de9b5b...`, `# noforward`).
3. **Resolve helper** [M·★★, DONE+PROVEN 2026-08-30] `resolve_qnn_sdk` +
   `stage_qnn_runtime`. Mirrors `Resolve-QnnSdk`/`Copy-QnnRuntime`: locate
   zip, verify sha256 if pinned, extract, anchor on `QnnInterface.h`, assert
   `lib/aarch64-oe-linux-gcc11.2/libQnnCpu.so`, QNN_OP_STFT canary.
   BUGFIX: `info()` writes to stdout (fd 1), so all `info` calls inside
   both functions redirect to `stderr` (>&2) to keep the `$(...)` capture
   clean — without this, QNN_HOME was polluted with log text.
   RELOCATED 2026-08-30 (fan-out): both now live in the shared
   `01-core/qnn-sdk.sh` module loaded by `media_common_init` (ORT's
   lib/common.sh sources it and now hard-requires the two functions —
   fail-loud if the module ever fails to load).
4. **ORT build wiring** [M·★★, DONE+PROVEN 2026-08-30] `30-build-native.sh`:
   `resolve_qnn_sdk` called after the oneDNN block; if non-empty, appends
   `--cmake_extra_defines onnxruntime_USE_QNN=ON onnxruntime_QNN_HOME=<path>
   QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2`. `stage_qnn_runtime` copies
   `libQnn*.so` + `hexagon-v*` skel beside ORT after
   `finalize_onnx_native_output`. arm64-only; amd64/riscv64 QNN-off.
5. **Dockerfile.media mount** [S·★, DONE+PROVEN 2026-08-30] Added
   `--mount=type=bind,source=linux/qnn-sdk,target=/opt/scripts/qnn-sdk,readonly`
   to the `--step cpu` and `--step genai` RUNs. Empty dir = no-op.
6. **Validation** [S·★, DONE+PROVEN 2026-08-30] `verify-media-artifacts.sh`
   `onnxruntime-cpu` stage: if `libonnxruntime_providers_qnn.so` is present,
   asserts `libQnn*.so` are staged. `validate-media-runtime.sh`
   `VENDOR_ARCH_SKIP_PATTERNS` already lists `libQnn*` — confirmed, no change
   needed.

7. **Framework fan-out wiring** [M·★★, WIRED 2026-08-30, validation build PENDING]
   New shared module `01-core/qnn-sdk.sh` (resolve_qnn_sdk + stage_qnn_runtime,
   moved from ORT's lib/common.sh, which now loads them via media_common_init;
   helper unit-tested end-to-end with a fake QAIRT zip: resolution, sha256,
   staging, arch/no-zip gates). Every framework wires through it, mirroring the
   Windows #121 flags exactly:

   | Framework | CMake flag (mirrors Windows #121) | Linux source | Status |
   |---|---|---|---|
   | **ONNX Runtime** | `onnxruntime_USE_QNN=ON` | `30-build-native.sh` | DONE+PROVEN |
   | **ONNX Runtime GenAI** | inherits from ORT — stage QNN libs beside GenAI install | `60-build-genai.sh` | WIRED, validation build PENDING |
   | **LiteRT** | `TFLITE_ENABLE_QNN=ON` + `QNN_HOME=<home>` + `LITERT_ENABLE_NPU=ON` (NPU=OFF default flips on only when a zip is staged) | `build-litert.sh` (configure + wheel-flag string + post-install staging) | WIRED, validation build PENDING |
   | **TVM** | `USE_QNN=ON` + `QNN_HOME=<home>` (else explicit `USE_QNN=OFF`) | `tvm-config.sh` append_tvm_cmake_args + post-install staging in `tvm.sh` | WIRED, validation build PENDING |
   | **IREE** | `IREE_TARGET_BACKEND_QNN=ON` + `QNN_HOME=<home>` (else `OFF`) | `build-app-wheelhouse.sh` build_iree_wheels | WIRED, validation build PENDING. NO runtime staging on Linux: the cross lane ships wheels only, and the arm64 target is runtime-only (no compiler) — whether the flag has any effect there is exactly what the validation build answers. |

   Fail-safe by construction: no zip staged = `resolve_qnn_sdk` returns empty on
   every arch → each framework takes its pre-existing default path byte-for-byte
   (verified for amd64/riscv64/no-zip by the module's unit tests). The pending
   check is the OPPOSITE direction: with a REAL QAIRT zip staged on arm64, do
   all five flags/builds stay GREEN and do the staged libs land? (Storm the
   open items — LiteRT's own QNN-manager header fetch and the wheel-staging
   question — are answered by that same run.) QNN_SDK_LINUX_LIBDIR
   (default `aarch64-oe-linux-gcc11.2`) is the single knob if a newer SDK ever
   changes the lib subdir.
   **BLOCKED 2026-08-30 on the login-gated SDK:** the real QAIRT zip is not on
   the host (removed after the PROVEN 2026-08-30 build per the qnn-sdk README
   discipline — "stage right before a media rebuild, remove after"; the
   buildkit `/tmp` tmpfs discarded the in-RUN extraction, and
   `/tmp/qnn-sdk-extract` now holds only a synthetic test stub). Re-staging is
   the owner's move (qpm.qualcomm.com, Qualcomm ID + EULA), then re-pin
   `QNN_SDK_LINUX_ZIP_SHA256` in versions.env — a fake/round-tripped zip would
   hard-fail the sha check (by design). The no-zip fail-safe path across every
   framework IS being validated by the 2026-08-30 media rebuilds.

No zip = QNN off with one notice on every framework. The verification ceiling
is the same as Windows/DirectML's: a green build proves the right bytes ship,
never NPU execution — that needs real Snapdragon hardware.

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff — DONE 2026-08-30.** Full narrative in
  `docs/linux-cross-builds.md` § "--no-push full chains: FIXED 2026-08-30".
  Every stage of a `--no-push` chain is exported to an OCI layout and handed to
  the child as `--build-context <parent-tag>=oci-layout://<dir>`; android is
  additionally exported to `ARTIFACT_CONTEXT_ROOT` for the runtime lane. The
  guard now allows full chains and refuses only mid-chain resumes. Mechanism
  proven end-to-end on the live host (two-stage test build: FROM resolved from
  the exported layout, never the registry) and pinned by
  `tests/test-cross-oci-handoff.sh` (15 assertions). See the archive for the
  why + the hook points.

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation — DONE + PASS 2026-08-30.** Two real bugs
  surfaced and were fixed (92fb9646 plumbing, 5e8b2470 apt-lock), then a local
  compiler build with the flag ran GREEN: arm64+riscv64 cross-GCC concurrent
  (both OK, ~531s wall for two targets vs ~984s sequential), full toolchain
  smoke 41/41. The flag now works as documented — `GCC_PARALLEL_TARGETS=1` on
  either orchestrator reaches the container. Not pushed (local validation);
  pass the flag on a full chain to adopt it. Full evidence in the archive.
- **F2 media validation — DONE + PASS 2026-08-30** (sdk→media→android, amd64,
  pushed). The one-resolver cache consolidation ran in every media RUN
  (launcher=sccache-launcher.sh, 100 % C/C++ hit rate), 27 artifact verifies
  OK, android pushed; modules.sh reorder + QNN-off fan-out exercised with no
  regression. THE FIND: the validation caught an sccache-launcher gap — the
  server-died class (`failed to execute compile / Failed to send data to or
  receive data from server`) was NOT bypassed by the launcher (only the ENOENT
  class was), killing the TVM step. Fixed in 0371d164 (bypass on any
  sccache-prefixed internal error; tests/test-sccache-launcher.sh). TVM is
  restored on the follow-up media rebuild.
- **QNN-LINUX fan-out validation — BLOCKED on the login-gated QAIRT SDK.**
  The real zip is not on the host (removed after the PROVEN build per the
  qnn-sdk README discipline; the buildkit /tmp tmpfs discarded the in-RUN
  extraction). Re-stage via qpm.qualcomm.com (Qualcomm ID + EULA) and re-pin
  QNN_SDK_LINUX_ZIP_SHA256; a round-tripped/fake zip would hard-fail the sha
  check by design. The no-zip fail-safe path was validated by the media builds.
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
