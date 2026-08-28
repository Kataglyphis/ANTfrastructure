<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows container chain — refactor backlog

Open work, standing directives and pending host/upstream actions for the
Windows container chain. Settled items are archived under
`docs/windows-backlog-archive-*.md`.

The Linux-side equivalent is [`refactoring-backlog.md`](refactoring-backlog.md).

> **COUNTING NOTE:** item numbers are HISTORICAL and never reused — the highest
> number is not the item count. Resolved narratives move to the dated archives
> (`windows-backlog-archive-*.md`); a bare "#N" that is not in this file
> resolves there. Lean-OPEN-only is the owner''s standing policy.

## OPEN

### ARM64 parity (opened 2026-08-23)

**LAST MEASURED STATE — arm64 run 36 / amd64 run 8, both on 2026-08-26 midday, numbers re-read
from the run logs rather than carried forward.** On that tree the `:winarm64` cross lane reached
runtime parity with `:winamd64` apart from the four exclusions listed below. **HEAD is not that
tree** — see #134 for what has landed since and why none of the four acceptance attempts has
completed. Read the table as the last known good.

| | arm64 cross (`bk-20260826-122019`) | amd64 native (`bk-20260826-130136`) |
|---|---|---|
| arch gate | **992 binaries, 0 violations** | 1134, 0 |
| import walk | **606 files, 0 unresolved** (3 allowlisted externals) | — |
| target python deps | **12 wheels, 0 unresolved requirement edges** | — |
| bundle manifest | 6 DLL homes, **6 wheels**, 3 ABSENT markers | — |
| GStreamer contract plugins | **6/6** — `libav opencv onnx webrtc nice tflite` | 6/6 |
| smoke gate | **97 passed / 0 failed / 15 skipped** (floors 66/25) | **222 / 0 / 0** |
| wall clock | ~40 min (media+final) | 2 h 18 min |

**Exactly three components are ABSENT on arm64**, each marked in the bundle by an
`ABSENT-ON-ARM64.txt` (call sites: `build-tvm-from-source.ps1:525`,
`build-iree-from-source.ps1:331`, `build-litert-all.ps1:85`): the **TVM compiler**, the **IREE
compiler** (both need an LLVM cross-built for aarch64-windows) and **LiteRT-LM** (Bazel + an x86_64
prebuilt `.lib`; a CMake port exists upstream — #133(d)). Their *python packages* DO now ship
(`apache_tvm`, `apache_tvm_ffi`, `iree.runtime` — closed by #133), which earlier revisions of this
paragraph wrongly listed as absent. Also excluded by owner decision or construction: **CUDA**
(#122, no Windows-on-ARM CUDA), the **torch app stage** (`uv sync` must execute the target
interpreter), and the **QNN EP**, which is wired but needs a hand-staged SDK (#121).

**The honest caveat, unchanged:** nothing the arm64 lane produces has ever been *executed*. Its
wheels ship staged, not installed, and every verdict above is a static check — PE machine type,
import resolution, exported symbols. The 15 skipped smoke assertions are the ones that would have
to run the aarch64 payload on an x64 host.

*History, for readers of old revisions:* the 2026-08-25 consumer-side audit found that "builds" was
not "usable at first touch" — `vcruntime140.dll` (#124), no target `sitecustomize` (#125), no
staged runtime deps (#126), no import walk (#127); all four closed 2026-08-25. The two silent
degradations it named are also closed: GStreamer's missing `webrtc`/`nice` (#128, DONE 2026-08-26)
and OpenCV's empty NEON dispatch (#129, DONE 2026-08-25).

Each item below carries a
**verified** blocker — every one was researched against the actual code and upstream, then
adversarially re-checked, because an optimistic "solvable" here costs 25 min to several hours
of build time per attempt. Ordered by leverage ÷ risk, which is the order they should be done in.

- **#121 — QNN execution provider (Qualcomm AI Engine Direct / QAIRT).** L–XL · ★★★ strategically ·
  **SCAFFOLD DONE 2026-08-24 — opt-in, unproven until an SDK zip is staged.**
  The one accelerator whose entire reason to exist is the hardware `:winarm64` actually targets:
  Microsoft's own Snapdragon guidance points at the **QNN** EP, not DirectML, for NPU inference on
  Windows-on-ARM. The 2026-08-24 parity audit found **zero code** for it on either lane and — more
  importantly — **no blocker to cite**: the obstacles are SDK acquisition and verification, not
  platform support. The verification ceiling is exactly DirectML's: a green cross build proves the
  right bytes ship, never that the EP runs — NPU execution needs Snapdragon hardware, which not even
  a `windows-11-arm` CI runner guarantees.
  **What landed (2026-08-24 evening):** the vendor-zip pattern, adapted — `windows/qnn-sdk/` is the
  hand-staging drop (git-ignored except its README, which carries the download/EULA/layout facts),
  bind-mounted into the media-core `onnx` RUN; `QNN_SDK_ZIP_SHA256` in `versions.env` is the
  optional integrity pin (media-core-env ARG/ENV, driver map, `bump_versions.py` allowlist — the
  TensorRT contract); `build-onnx-from-source.ps1` extracts, anchors the SDK root on
  `include\QNN\QnnInterface.h`, asserts the target's `lib\<arch>\QnnCpu.dll`
  (`Get-QnnSdkLibDirName` in the arch table), passes `-Donnxruntime_USE_QNN=ON -Donnxruntime_QNN_HOME`
  on both lanes, and post-install asserts `onnxruntime_providers_qnn.dll` and stages the backend
  DLLs + `hexagon-v*` skels beside `onnxruntime.dll`. **No zip = EP off with one notice**, which is
  the only path any run has exercised — this host never held the SDK, so the SDK-present branch is
  a scaffold whose asserts are written to fail loudly on the first staged zip. Full description in
  `docs/windows-cross-builds.md` § QNN. Open: stage a real SDK, run once, then a native Snapdragon
  host for execution.

- **#122 — CUDA on arm64: CLOSED 2026-08-28 (owner decision: no near-term CUDA-in-Windows
  plan).** Phase-0 probe done: cuDNN arm64 ships (~90 MB at the pin, NOT the 421 MB recorded
  before); CUDA itself does not — no `windows-arm64` redist or installer at 13.4 or any 12.x/13.3.x.
  Full probe narrative and the corrected "421 MB" figure:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md) § #122.
  Re-open only if NVIDIA publishes a `windows-arm64` CUDA toolkit AND the owner wants to wire it.
  One parked free fix (arch-parameterise the cuDNN URL in `setup-cuda.ps1:138`) lives there too.

**Permanently out of reach — do not re-litigate without new upstream facts:** classic TensorRT
(genuinely x64-only — NVIDIA's support matrix has no ARM64 row), and the `torch` app stage (`uv
sync` must **execute** the target interpreter — uv can cross-RESOLVE into a directory, but the
synced venv is the stage's contract — and PyTorch builds no `win_arm64` wheel for **Python 3.14**,
this repo's cp314 pin). **Two premises originally recorded in this block (2026-08-23) were wrong
and are retracted (2026-08-24 parity audit):** "CUDA / cuDNN / TensorRT: no Windows-on-ARM builds
exist at all" — false: the cuDNN windows-arm64 9.25.0.15 archive exists at this repo's exact pin
(HTTP 200, **~90 MB** re-measured 2026-08-28; the "421 MB" here was never re-fetched and is wrong
— see #122), `lib/arm64` inside), CUDA 13.4 (preview) advertises Windows ARM64 incl.
x86_64-hosted cross-compile (but as of 2026-08-28 no CUDA 13.4 installer or `windows-arm64`
redist exists — #122 probe), and TensorRT-RTX publishes Windows-on-Arm packages for CUDA 13.4 —
wiring CUDA into the cross lane is unscheduled backlog work, not fiction; and "the pinned PyTorch
publishes no `win_arm64` wheel" — false as an absolute: download.pytorch.org does publish
`win_arm64` `+cpu` wheels, just none for cp314. The verdicts stand on the corrected reasons.
**Note the meta-lesson: a false premise inside a do-not-re-litigate block is precisely how such
errors survive — the block shields its reasons from checking, so the reasons recorded here must be
verified facts, never remembered summaries.**

**A measurement that used to sit in the tree was retracted and has since been re-taken:** the PyAV
note in `build-ffmpeg-from-source.ps1` ("`ImportError: DLL load failed while importing Utils`") was
recorded while `Initialize-PythonPlatformTag` was still stamping the **target** tag on the **host**
interpreter — so pip resolved a `win_arm64` Cython into the x64 host Python. The bug and its fix
landed in the same commit (`ed2a04d4`). **Re-measured 2026-08-24 evening (#120 step 2): PyAV
cross-builds.** `setup.py --ffmpeg-dir=<arm64 ffmpeg> build_ext --plat-name win-arm64 bdist_wheel
--plat-name win_arm64` produced `av-18.1.0-cp314-cp314-win_arm64.whl` with 49 native members, all
`0xAA64` — setuptools' `x86_arm64` vcvars spec (`Hostx86\arm64\cl.exe`) did the compiling, which
confirms the second half of the old parenthesis too: PyAV is the one consumer compiled by `cl.exe`
on both lanes, the documented PyAV-shaped hole in the clang-cl rule.

- **#133 — the three amd64-only components.** M–L · ★ (opened 2026-08-26 after the owner asked
  "are you sure?"; solved on request the same day) · ✅ **(a)+(b)+(c) DONE 2026-08-26, (d) deferred**
  (a) **Rust for the target** — the real blocker under both `gst-ptp-helper` and LiteRT-LM. The
  image's rustup was installed from a local mirror its own installer deletes, so `rustup target
  add` died fetching `file:///…rustup-dist/…`. The cached channel manifest still names every
  tarball WITH upstream's sha256, so `Install-RustTargetStdFromPinnedManifest` fetches exactly
  that file from static.rust-lang.org into the path the manifest names and rustup verifies it
  against the pin. **arm64 run 29:** `gst-ptp-helper.exe` built + installed, gate 981/0, walk
  578/0. amd64 always had the helper — both lanes ship it now.
  (b) **`iree.runtime`** — nanobind extension over the runtime this branch cross-builds anyway:
  bindings ON with `Python3_*`+`Python_*` hints (host exe / neutral include / TARGET
  `python314.lib` / host-probed numpy), then the build tree's synthesized `runtime/setup.py
  bdist_wheel --plat-name win_arm64` through `Invoke-PythonWheelBuild -CrossStage`.
  (c) **`apache-tvm` + `apache-tvm-ffi`** — TVM 0.26 supports runtime-only python natively
  (`tvm/base.py` falls back to `_RUNTIME_ONLY` when `tvm_compiler` is absent) and tvm-ffi's Cython
  `core` builds through a STANDALONE tvm-ffi configure (its CMakeLists `return()`s as a
  subproject). scikit-build-core cannot cross, so the two wheels are assembled from the package
  sources + the cross-built binaries and packed with `python -m wheel pack`.
  **arm64 run 36 (`[bk] Done 00:40:51`):** 6 wheels (= amd64), every member `0xAA64`; deps store
  **12 wheels / 0 unresolved edges**; arch gate **992/0**; import walk **606/0**; smoke 97/0/15.
  **amd64 run 8:** native paths untouched — `iree native gate OK`, `iree python gate OK: abs(-5) =
  5.0`, `import tvm`, arch gate **1134/0**, smoke **222/0/0**.
  (d) **LiteRT-LM stays deferred — as a PORT, not a wall.** Its ACTIVE Bazel path is blocked twice
  (no windows-arm64 config, x86_64-only `libGemmaModelConstraintProvider` in the default graph),
  but upstream `v0.16.1` ships a CMake path with `cmake/patches/stubs/gemma_model_constraint_provider.cc`
  — a no-op provider that trades grammar-constrained decoding for buildability. With (a) in place
  the remaining work is corrosion/Rust for the target plus days of iteration at ~1 h per attempt.
  The **compilers** (`tvm_compiler.dll`, `iree-compile.exe`, `iree.compiler`) stay amd64-only:
  they need an LLVM cross-built for aarch64-windows, with no upstream precedent (PyPI ships
  `win_amd64` only for `iree-base-compiler` and `apache-tvm`, verified 2026-08-26).
  **Seven fix-and-rerun cycles (runs 29–36), each a measured defect** — the target CPython missing
  in the tvm branch, tvm-ffi returning early as a subproject, `/EHsc` dropped by an explicit
  `CMAKE_CXX_FLAGS`, the bare `core.pyd` FindPython emits on Windows, `classifiers = [` swallowing
  the dependency list, a `core.pyd` importing an unstaged `tvm_ffi_testing.dll` (caught by the
  import walk), and .NET's multiline `$` never matching before `\r` on the container's CRLF
  checkout (which emptied `Requires-Dist` — a defect no gate can see, since fewer requirement
  edges only make it greener). Full run-by-run record:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md).
- **#134 — post-#133 cleanup wave: unshare the module closure, de-duplicate the AST test
  boilerplate, condense the docs.** M · ★★ (opened 2026-08-26, owner's request; planned against the
  Dockerfiles, not against memory — see the correction below) · **CODE LANDED 2026-08-26
  (`2752685f` + docs `80f2258f`); ARM64 ACCEPTANCE PASSED 2026-08-28; amd64 BLOCKED on TVM-vs-LLVM-23.1.0.**
  **ARM64 acceptance run (2026-08-28, run `bk-20260828-171914`): ALL GATES GREEN.** arch gate
  **992/0**; import walk **606/0** (3 allowlisted, 6 device-OS); smoke **97/0/15**; GStreamer
  contract plugins 6/6; `tvmmods` stage mounted and built clean; IREE runtime wheel
  `iree_base_runtime-...-win_arm64.whl` (11 members, all `0xAA64`); TVM runtime wheels
  `apache_tvm-0.26.0-cp314-win_arm64.whl` + `apache_tvm_ffi-...-win_arm64.whl`. OpenCV 1870/1870
  with **zero #135 codegen errors**. This proves the module-closure unshare, the leaf modules,
  `tvmmods`, and the deleted classic stages are sound on the cross lane.
  **AMD64 acceptance run (2026-08-28, run `bk-20260828-190313`): was BLOCKED in TVM compiler —
  FIX LANDED, needs rebuild.** TVM 0.26's `codegen_llvm.cc` uses
  `llvm::Intrinsic::matchIntrinsicSignature` / `MatchIntrinsicTypes_*` which were removed/renamed
  in LLVM 23.1.0 (the forced `LLVM_WINDOWS_VERSION` bump from 22.1.8, #135). 8 compile errors in
  `codegen_llvm.cc` + 1 in `llvm_module.cc`. The arm64 lane is unaffected (runtime-only, no
  compiler). **Fix: `build-tvm-from-source.ps1` now uses `TVM_COMMIT` (pinned to upstream main
  `994e0216`, which carries `TVM_LLVM_VERSION >= 230` guards) instead of `TVM_REF=v0.26.0` (the
  tag without the guards). `Dockerfile.media-builder` ARG/ENV updated to forward `TVM_COMMIT`.**
  Needs an amd64 rebuild to verify the fix.
  **Four fixes landed during the acceptance run (not #134 defects, but preconditions):**
  1. `SCOOP_INSTALLER_SHA256` bumped 84242117→94f983b1 (scoop rotated `get.scoop.sh` again).
  2. arm64 OpenSSL URL bumped `Win64ARMOpenSSL-4_0_1`→`4_0_2` (slproweb removed 4_0_1, 404).
  3. `ARCH_GATE_MIN_INSPECTED` for arm64 corrected 840→580 (840 was set against the arch-gate
  4. `TVM_COMMIT` now used by the Windows build instead of `TVM_REF` (the LLVM 23 API break fix).
  binary count, not the import-walk file count of 606).
  branches past media-core are the next gate; nothing downstream of it has been re-run yet.
  **The acceptance run, and why it is the proof rather than the suite.** Three runs off
  `80f2258f`, in this order (arm64 first: it exercises more of the new code — the cross paths, all
  three leaf modules, `tvmmods` — and costs ~40 min against amd64's ~2 h 20, so a defect surfaces
  cheap). Preconditions verified before launch: sccache `http://192.168.188.116:5000` HTTP 200,
  RDNA4 dGPU DISABLED (`ConfigManagerErrorCode 22` — an enabled one fails every process-isolated
  layer commit), buildkitd Running, 875 GB free on C:.
  (A) `build-buildkit.ps1 -TargetArch arm64 -Stages media,final` → arch gate **992/0**, import walk
  **606/0** (3 allowlisted externals), target python deps **12 wheels / 0 unresolved edges**,
  bundle **6 wheels + 3 ABSENT markers**, contract plugins **6/6**, smoke **97/0/15**.
  (B) the CACHE-KEY PROOF, the one thing only a build can answer: touch one byte of
  `WindowsTvm.Common.psm1`, re-run arm64 `media` — **only `media-tvm-built` may re-run**; ONNX,
  FFmpeg, OpenCV, media-core-built and media-litert-built must all report CACHED. If any of them
  re-runs, `tvmmods` bought nothing and the whole wave is decoration.
  (C) `build-buildkit.ps1 -Stages media,final` → arch gate **1134/0**, smoke **222/0/0**.
  The host suite structurally cannot see what these check: #131's ride found three defects the
  tests could not, which is why the bundled regression is the acceptance criterion and 704/704 is
  only the entry ticket.
  **RUN 37 (arm64, 2026-08-26) FAILED — and it proved the point above.** media-core, media-litert
  and media-tvm ALL BUILT (so `tvmmods`, the leaf modules and the deleted classic stages are
  sound); the merge stage then died two hours in at `PHASE: 6. meson setup` with
  `The term 'Resolve-BuildMachineMsvcTool' is not recognized`. Cause: promoting that function into
  `WindowsTargetArch.Common` and exporting it THERE, while `build-gstreamer-from-source.ps1` reaches
  the arch API through `WindowsSourceBuild.Common`'s RE-EXPORT list, which I did not extend.
  `Modules.ReExport.Tests.ps1` checks the opposite direction only. Fixed in `9bf0ef41`, together
  with a gate for the class — `Modules.ScriptCallClosure.Tests.ps1` proves, in a FRESH pwsh
  importing only what each script imports, that every module function a build script CALLS resolves.
  It immediately found a second, unplanted instance: `build-tvm-from-source.ps1` calls
  `Get-PreferredToolPath`, latent because its call site sits in `elseif (-not $llvmConfig)` — skipped
  on cross (runtime-only) and on amd64 (scoop puts llvm-config on PATH). Note the gate replaced a
  2 h build with a 7 s check for this defect class: it reproduces the container's exact condition
  (cold session, only the declared imports). 705/705.
  **The run plan changed after run 37.** A version bump landed mid-run (`4665bad4` + `51b0768b`):
  `CMAKE_VERSION` 4.4.2→4.4.3 and `PWSH_VERSION` 7.6.4→7.6.5 both hit `Dockerfile.base`, and
  `smoke-test-container.ps1:242` HARD-asserts cmake against the pin — so every Windows build fails
  its own smoke gate until the base is rebuilt, and PWSH is layer 1, which invalidates the whole
  chain anyway. There is therefore no cheap re-run: the fix itself is in `WindowsSourceBuild.Common`,
  a tier-1 module mounted into every media RUN. Acceptance is now ONE full chain from `base`
  (arm64 first — it exercises more of the new code), then amd64 `media,final` on the shared base.
  This confounds #134 with the bumps. **The mitigation recorded here has since evaporated and the
  correction is kept, because the confounding is real:** it read "the compiler is unchanged
  (`LLVM_WINDOWS_VERSION` stays 22.1.8 — upstream ships no win64 installer for 23.1.0, verified
  404), so nothing that shapes compiled output moved". `versions.env:456` now pins
  **`LLVM_WINDOWS_VERSION=23.1.0`** — scoop reshaped the artifact and forced the bump (`6bbcea65`),
  which is exactly what brought #135 in. So the compiler DID move, and any #134 acceptance run from
  that period is confounded by a compiler change as well as by the module wave.
  **What landed.** Three leaf modules, each mounted only by the RUNs that call it:
  `WindowsMeson.Common` (the 3 meson helpers + `Invoke-WrapDownload` + `Expand-SubprojectArchive`)
  and `WindowsRustToolchain.Common` (`Install-RustTargetStdFromPinnedManifest`) in the merge
  `buildmods`; `WindowsTvm.Common` (`Get-VendoredTvmFfiVersion`) behind a new
  `FROM buildmods AS tvmmods` that `media-tvm-built` alone mounts. Two helpers promoted to the
  shared closure deliberately (`Write-AssembledWheelDistInfo` + `Get-PyprojectDependencies` are
  generic to any cross consumer scikit-build-core cannot build; `Resolve-BuildMachineMsvcTool` is a
  TARGET-vs-BUILD fact, so `WindowsTargetArch.Common`). Bodies byte-identical except the two
  admitted deltas (`-Logger`, plus `-Generator` on the wheel writer). Classic surface deleted:
  `media-core-env`, `media-core`, `media-litert`, `media-tvm`, `merge`, `builder-classic`, and the
  six-module COPY into `common` — media-builder 603→462 lines. All five ride-alongs landed
  (`sharing=shared`, `cuda-runtime-stage` on `${BASE_IMAGE}` after verifying CUDA_ROOT/CUDNN_ROOT
  come from `Dockerfile.nvidia` via `windows-sdk`, `ARCH_GATE_*` moved below the two RUNs that
  never read them, arch gate mounts 1 module not 10, `KATA_ARCH_PROBE` removed together with its
  reader). New `BuildKit.ModuleClosure.Tests.ps1` (4 tests, scanner-rot floor) — **mutation-proven**:
  TVM leaf into `buildmods` → 1 failure, a second `tvmmods` consumer → 3. TwinParity lost its two
  classic tests; the one that mattered was REPLACED, not deleted — the per-stage key union is now
  checked against `Get-MediaBranchVersionArg`'s map (a cross-FILE check) instead of against the
  deleted `media-core-env`. Suite 704/704, LINT OK.
  **What remains: the acceptance run** (below), plus the follow-ups this wave deliberately did not
  take: merging `Expand-SubprojectArchive` with `Expand-ArchiveSubdirectory`/`Expand-SourceTarball`,
  and B4 following `FROM buildmods AS <x>` chains (ModuleClosure covers that property now, and
  making B4 chain-aware would break its superset assertion, since `tvmmods` legitimately holds a
  module the merge closure does not).
  **Root cause, corrected.** Six helper functions ended up inside `build-gstreamer-from-source.ps1`
  (now 2246 lines, 9 functions) and three inside `build-tvm-from-source.ps1` during #128/#133,
  each with a comment claiming "the whole modules dir is bind-mounted into every media RUN". **That
  is false** — `windows/Dockerfile.media-builder` builds `FROM ${BASE_IMAGE} AS buildmods` and
  COPYs exactly SIX `.psm1` (the merge Dockerfile: eight), and its own comment says a whole-dir
  mount "remains wrong". The true cause is twofold: (a) those six ARE the import closure
  (`WindowsSourceBuild.Common.psm1` imports the other five; every mounted script imports it), so
  the mounted set cannot be shrunk and all **11** media/merge RUNs key on all six; and (b) the
  classic lane COPYs the same six into the **`common`** stage, which is the ancestor of every BK
  compile stage — so a module edit re-keys the branches a second time through the image graph.
  No branch can have a private module today.
  **Mechanism.** (1) Move the module COPY out of `common` into the three classic leaf stages that
  already COPY scripts (`media-core`, `media-litert`, `media-tvm`). (2) Add `FROM buildmods AS
  tvmmods` + the TVM leaf module, and point ONLY the `media-tvm-built` RUN at it — that branch is
  parallel to ONNX, so a TVM-private module costs zero on the ~75 min ONNX branch. (3) In the merge
  Dockerfile extend `buildmods` directly: all five of its RUNs are sequential layers in ONE stage
  with GStreamer first, so a derived stage there would buy nothing.
  **Moves.** New merge-lane leaves `WindowsMeson.Common.psm1` (`Invoke-MesonBuildSubprojectPatch`,
  `Select-MesonLogExcerpt`, `Get-MesonSetupFailureClass`, `Invoke-WrapDownload`,
  `Expand-SubprojectArchive`) and `WindowsRustToolchain.Common.psm1`
  (`Install-RustTargetStdFromPinnedManifest`); promote `Resolve-BuildMachineMsvcTool` to
  `WindowsTargetArch.Common.psm1` and `Write-AssembledWheelDistInfo` +
  `Get-PyprojectDependencies` to `WindowsSourceBuild.Common.psm1`. Stay stage-local: `log` (a
  closure over `$logContext`), the nested `Get-UnresolvedDeps`, `Get-VendoredTvmFfiVersion` (TVM
  leaf). One semantic hazard: `Invoke-WrapDownload` calls `log` — give it `-Logger [scriptblock]`
  like `Install-RustTargetStdFromPinnedManifest`'s `-Downloader`. `Expand-SubprojectArchive` is a
  near-duplicate of `Expand-ArchiveSubdirectory`/`Expand-SourceTarball` — NOT merged in this wave,
  recorded as its follow-up.
  **Tests.** `Get-ScriptFunctionDefinition -ScriptPath -FunctionName` in `TestHarness.psm1`
  (returns a scriptblock; callers keep the dot-source, because `.` inside a module function defines
  into module scope) — 8 files, 9 lift sites (`Driver.ClosureScope` and `SourceBuild.PinParity`
  SCAN files rather than lift functions and must not be converted). Extend
  `BuildKit.SolveOrderParity.Tests.ps1` B6 (blind to `.psm1` today) and B4 (must follow
  `FROM buildmods AS <x>` chains), and add `BuildKit.ModuleClosure.Tests.ps1`: the transitive
  `Import-Module` closure of every mounted script ⊆ its stage's COPY list — the Windows analogue of
  `linux/scripts/verify-script-copy-coverage.py`, which globs `linux/Dockerfile.*` only and never
  policed this.
  **Docs.** #128 (138 lines), #133 (124), #131 (91), #116 (83) collapse to verdict + numbers, with
  the run-by-run narrative moved to a dated archive (the convention exists: three such archives,
  and this file's header already says a bare #N not found here resolves there). Same for the
  status banner of `docs/windows-cross-builds.md` (990 lines), which has become a changelog.
  **Ordering — one paid rebuild.** FREE (verified by `Invoke-Tests.ps1` alone, no mount content
  changes): the test harness helper + conversions, the doc condensation, CREATING the new leaf
  modules and their fixture tests without touching any Dockerfile list, and the new/extended
  parity tests. PAID (one bundled amd64 + arm64 regression): the `common` unshare, `tvmmods`, the
  merge `buildmods` extension, deleting the stage-local bodies, `-Logger`, the core promotions,
  and the three stale comments — because that landing changes `common`'s digest, the full media
  rebuild is already bought, so the core promotions must ride along rather than pay it twice.
  **Acceptance:** amd64 arch gate 1134/0 and smoke 222/0/0; arm64 992/0, walk 606/0/3/6, deps
  12/0, smoke 97/0/15, plugins 6/6, 200 = 200 linked plugin DLLs; plus a cache-key proof (edit one
  byte of the TVM leaf → only `media-tvm-built` re-runs, everything else CACHED) and byte-identical
  function extents for every move except the two admitted deltas (`-Logger`, `Export-ModuleMember`).
  Develop in an isolated worktree like #131 — whose ride found three defects the host tests
  structurally could not see, which is why the bundled regression, not the suite, is the proof.
  **Pre-rebuild audit, 2026-08-26 — three findings correct the plan above and five more ride
  along.** Corrections first: (i) **step (1) as written turns ONE module list into THREE.** Use
  `COPY --from=buildmods C:\bkmods C:\temp\scripts\modules` in the three classic leaves instead —
  same result, one list, and it anchors the classic lane on `buildmods`. (ii) **Step (1) alone buys
  no cache granularity**: every build script imports `WindowsSourceBuild.Common.psm1`, which hard-
  requires all five siblings, so all six RUNs legitimately mount all six modules before AND after.
  The entire win is step (2), `tvmmods`. Land (1) as the enabler, not as a saving. (iii) **The
  classic merge lane is structurally red** and that changes this wave''s shape: its `merge` stage
  runs none of `build-opencv-gstreamer-plugin.ps1`, `write-bundle-manifest.ps1`,
  `stage-target-python-deps.ps1`, `verify-target-arch.ps1`, while `build.ps1` ends the chain in a
  smoke gate that hard-asserts `cv2.videoio_registry.hasBackend(CAP_GSTREAMER)`
  (`smoke-test-container.ps1:1527`) — a backend only the BK lane''s plugin provides. So B6 polices
  COPY lists for a lane that cannot pass its own gate. **Decide the classic lane''s status before
  spending the rebuild**; if it is retired, steps (1) and (iii) collapse. Corroborating find:
  `windows/scripts/build/build-merge-all.ps1` existed (deleted 2026-08-26, see the decision below),
  was referenced by **nothing** (no Dockerfile,
  no driver, no doc), and its own header describes fixing exactly this gap — somebody wrote the
  classic lane's chained merge and never wired it. Deleting it is free; wiring it needs a
  `merge`-stage COPY plus a `-RunCommand` change. Either is fine — leaving a dead fix script for
  a known-broken lane is not.
  **DECIDED 2026-08-26 (owner): the classic lane is RETIRED.** Landed free, no rebuild:
  `build.ps1` throws unless `-AcceptRetiredLane` (the four structural reasons are in its header
  and in `docs/windows-build-lanes.md` § The classic lane was retired); `build-merge-all.ps1`
  deleted; parity check **B6 removed** from `BuildKit.SolveOrderParity.Tests.ps1` (702→701 tests,
  floor 690 unchanged) because its only possible failure became "the retired lane would break";
  AGENTS.md, README.md, `docs/{overview,project-info,windows-builds,windows-build-lanes,
  windows-host-setup}.md` corrected — `windows-builds.md` had said the lane "remains fully
  supported". Verified while landing: the four missing steps sit behind `FROM merge-fanin AS built`
  (`Dockerfile.media-merge-builder:229`) while classic pins `merge` (`:208`), AND all four are
  `RUN --mount=type=bind`, which dockerd cannot execute — so reviving the lane is a redesign into
  COPY stages, not a target-pin move. That closes finding (iii): **step (1) collapses** (no classic
  leaves to re-anchor on `buildmods`) and the wave is now step (2) `tvmmods` plus the ride-alongs.
  **New ride-along, PAID (re-keys media layers, hence #134 and not free):** delete the now-unpoliced
  classic-only surface from `Dockerfile.media-builder` — the `--target media-core|media-litert|
  media-tvm` COPY stages — and the `builder-classic` and `merge` targets in
  `Dockerfile.toolchain-builder` / `Dockerfile.media-merge-builder`. Until that lands the COPY
  lists are dead code with no gate on them; the removal comment in the B6 slot says so.
  **Exact cut list (mapped 2026-08-26, every line verified against the tree).** Dockerfile stages
  that become unreachable: `builder-classic` (`Dockerfile.toolchain-builder:51`), `media-core`
  (`media-builder:271`), **`media-core-env`** (`:236`), `media-litert` (`:305`), `media-tvm`
  (`:338`), `merge` (`media-merge-builder:208`). **Do NOT cut** the shared parents —
  `media-litert-env` (`:288`), `media-tvm-env` (`:329`), `builder`
  (`toolchain-builder:17`), `merge-fanin` (`media-merge-builder:74`) — nor either `buildmods`
  stage, which is BK-only, not classic (this corrects the "B4/B6 are twins" framing). One excision
  inside a SHARED stage: `media-builder:188-194` COPYs six `.psm1` into `C:\temp\scripts\modules`
  in `common` for the classic leaves only, so it currently re-keys BK's cache for a retired lane's
  benefit. Driver-side: eight local functions in `build.ps1` (`Invoke-RunCommitStage:589`,
  `Invoke-MediaBranchRunCommit:736`, `Invoke-ResumeRunCommit:791`, …) and six
  `WindowsBuildDriver.Common.psm1` exports with no BK caller (`Set-BuildDriverIsolation:54`,
  `Invoke-DockerWithRetry:124`, `Get-DockerBuildArgList:201`, `Assert-ImageExists:227`,
  `Resolve-BuildIsolation:245`, `Assert-DockerDaemon:518`; trim the export list at `:943-951`).
  `Test-TransientDockerFailure`/`Invoke-TransientCooldown` are SHARED — keep. The isolation-probe
  chain (`diagnostics/test-process-isolation-commit.ps1`, `Dockerfile.isolation-probe`) is
  classic-only; `toggle-rdna4-gpu.ps1` is NOT — both lanes reach it.
  Tests: ~15 fully classic-specific tests survive the free half — whole file
  `Driver.PreflightParity.Tests.ps1` (4/4), `BuildDriver.Retry.Tests.ps1` `Invoke-DockerWithRetry`
  + `Get-DockerBuildArgList` (6/17), `BuildKit.TwinParity.Tests.ps1` `:122` + `:150` (plus `:95`
  and `:109` need the `Classic` key dropped from the `$branches` table at `:59-62`),
  `Driver.ClosureScope.Tests.ps1:91`, `Dockerfile.ProbeShell.Tests.ps1:66`, and
  `BuildDriver.HostGates.Tests.ps1:235` needs its classic label shapes trimmed. **Do not simply
  delete `TwinParity:150`** — it is the LAST gate proving the four BK per-component version-key
  sets are collectively complete (it reads `media-core-env`'s ARG union). Killing `media-core-env`
  without a replacement gate silently removes that coverage; write the replacement against the BK
  stage union in the same commit. CI impact is zero except through `Invoke-Tests.ps1`
  auto-discovery — no workflow invokes `build.ps1`. Housekeeping: four stale allowlist entries in
  `.claude/settings.local.json:9,10,14,15`.
  **Capability actually lost, needs an owner call:** the per-run resource CSV
  (`out\windows-build-logs\resources-<ts>.csv`) is wired into `build.ps1:910` and NOWHERE else, so
  no building driver produces it today; `build-resource-sampler.ps1` still works by hand. Wiring it
  into `build-buildkit.ps1` is a free driver-only change — do it, or drop the sampler. Likewise
  `-ResumeStage` (15 refs, classic-only): BK's per-stage layer cache covers the common case, but
  the preserved-container recovery path has no BK equivalent.
  Ride along (all PAID, none worth its own rebuild): **`sharing=locked` on the sccache mount**
  (`Dockerfile.media-builder:576,593`) serialises the two branches `-ConcurrentAux` runs as
  concurrent child solves (`build-buildkit.ps1:519-559`) — and the mount is inert anyway
  (`SCCACHE_MULTILEVEL_CHAIN=""`), so the lock is pure loss; **`cuda-runtime-stage`**
  (`Dockerfile.media-merge-builder:32`) descends from the media-core branch image although the
  toolchain base carries the same CUDA install — it makes the fan-in, already the flakiest stage
  (`-MaxAttempts 5`), re-run on every branch rebuild; **`ARCH_GATE_*` ARGs** (`:327-328`) sit above
  a manifest write and a network `pip download` that never read them; **the arch-gate RUN mounts
  all 8 modules** while `verify-target-arch.ps1` imports exactly one; and **`KATA_ARCH_PROBE`**
  (`Dockerfile.media-builder:470-476`), a diagnostic ENV whose question was answered.
  Free follow-ups the audit found, not yet done: no suite covers `verify-target-arch.ps1`,
  `stage-target-python-deps.ps1` or `write-bundle-manifest.ps1` (the arm64 lane''s primary
  correctness signal is untested, and its `Get-ArchiveMachine` bound was fixed in production, not
  by a test); `stage-target-python-deps.ps1` still gets greener as requirements DISAPPEAR (the
  run-34/35 defect class — needs `-MinFirstTouchRequirements`/`-MinBundleWheels`); the arm64 smoke
  floor tolerates losing 32% of its assertions and §19''s floor is still marked PROVISIONAL after
  three green runs; two TVM fixtures use single-quoted `` `n `` and prove nothing; `Assert-Equal`,
  the test-count floor and the amd64 arch-gate floor are FIXED (commit `ebc7e525`). Layer headroom
  is disputed — docs say ~108/125, the audit computes ~78; settle it with one elevated
  `ctr`/`nerdctl` inspect before anyone plans around either number.

- **#135 — LLVM 23.1.0 AArch64 codegen: both failures FIXED, workarounds stay until patched
  toolchain is default.** M · ★★ (opened 2026-08-26, both fixes landed 2026-08-27, in-container
  verification 2026-08-28)
  Root cause: `EH_LABEL` under `/EHa` emits a 4-byte nop counted as zero by
  `getInstSizeInBytes`; `AArch64CompressJumpTables` and `BranchRelaxation` pick
  encodings the assembler rejects. Two fixes: (1) `+force-32bit-jump-tables`,
  (2) per-TU `/Ob1` on the offending OpenCV TUs. Two upstream PRs filed
  (llvm#219275, llvm#219276); patched toolchain path proven
  (`build-buildkit.ps1 -PatchedLlvm`, 2026-08-28: 3/3 protobuf + 151/151
  OpenCV imgproc objects clean, no workaround flags). Full saga, the wrong
  earlier diagnosis, and the upstream bug list:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md) § #135.
  **Remaining work:**
  1. **Both workarounds STAY** until `BUILD_PATCHED_LLVM=0` flips to default —
     delete the flags from `build-opencv-from-source.ps1` in the SAME change
     that flips the default, never before.
  2. **Run the `NINJA_KEEP_GOING=1` census through the driver** with both
     workarounds removed and keep the log — currently CLAIMED BUT UNLOGGED (no
     artifact in `out/windows-build-logs/` mentions either knob).
  3. **Open hypothesis:** the `EH_LABEL` fix may also retire `/Ob1`
     (BranchRelaxation consumes the same size function) — test before assuming.
  4. Upstream bug (a) layout estimate — reportable but not a prerequisite;
     (b) asm printer missing `:lo12:` — FILED as llvm#219200.

- **#136 — VS RUN never cached across runs: SOLVED + DEPLOYED 2026-08-26, archived.** The
  GC reserve in `windows/buildkitd.toml` was below the single ~37 GB VS-class layer
  (`reservedSpace` 40 GB, `maxUsedSpace` 400/450 GB); raised to 150/650/700 GB and proven
  by the next build (`#9 CACHED` for the first time). Full narrative + the `0B` = "already
  pruned to floor" inversion lesson:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md) § #136.

- **#137 — sccache: DONE 2026-08-28 (pin bumped, 0003 deleted, patch dir removed).**
  `SCCACHE_GIT_REV` bumped `ffac4a5…` to `8ab39266…` (main HEAD, carries both
  PRs). The 0003 patch file and `windows/upstream/sccache-nvcc-quote-fix/`
  deleted. `Dockerfile.base` COPY of the patch dir removed.
  `setup-rust-toolchain.ps1` takes the stock `cargo install --git --rev` path
  (no patches = no local-apply branch). Comment blocks updated in
  `setup-rust-toolchain.ps1`, `Dockerfile.base`, `Dockerfile.media-builder`.
  **This is a base-layer change that re-keys every media stage — needs a
  rebuild to land.**

- **#31 [owner decision] registry push** — push the verified images to a
  registry instead of local-only tags. Parked until the owner wants it
  (#59 branch protection was DECLINED, #31 was not).

## STANDING DIRECTIVES (survive their archived entries — do not re-litigate)

- **NEVER trim CUDA_ARCHITECTURES** (80;86;89;90 in ALL builds, incl. dev
  iterations; pinned by Pins.CanonicalValues).
- **CUDA compiles stay BARE nvcc** — the sccache launcher-default question is
  CLOSED (miscompile is storage-independent and cold-cache; archive #99/P0b).
- **Do NOT collapse the media-core checkpoints** (#72: export is ~1.2% of the
  chain; resume granularity is worth more than ~60 s).
- **Do not re-propose** branch protection (#59) or a scheduled nightly/weekly
  chain run (#111) — DECLINED by owner 2026-08-17; manual launches are the
  verification cadence.
- **No logging-idiom sweep** (#110): chain scripts use Write-Host, gstreamer
  keeps its structured `log`, Write-BuildLog stays host-driver territory;
  enforcement is review, not a cache-busting mass edit.
- **GES `_commit` retry is DORMANT INSURANCE** (#77): re-open only if its
  retry marker reappears in a gstreamer build.
- **Restore `disk,webdav` only after WCOW cache mounts are PROVEN** (#99
  re-verification recipe in the archive; also listed under Pending).

## Pending host/upstream actions (not refactors — do not let these evaporate)


> The elevated between-runs window (buildkitd step-log env restore, GC-budget
> deploy = #34, poisoned probe-chain prune, diagnostic tag cleanup) and the dufs
> SYSTEM-service migration were APPLIED by the owner 2026-08-13 — see the archive
> addendum. Sanity-check the GC deploy with `buildctl debug workers -v` — the
> output says `Reserved space: 161.0612736GB` for a healthy 150 GiB pin, NOT
> "150GB": the toml takes GiB and buildctl prints GB, and the labels differ too.

- **UPSTREAM, consolidated 2026-08-17 (was scattered across #99''s body and two
  Open-items entries):**
  1. **moby/buildkit — WCOW cache mounts lose writes into an inherited
     directory.** Cause, A/B measurements and the 2-minute repro are in the
     archive (#99). Strengthen before filing: reproduce with PLAIN file writes
     (no sccache). Goes to moby/buildkit, NOT mozilla/sccache.
  2. **mozilla/sccache#2808 addendum** — the issue''s "WebDAV cache was largely
     empty" reasoning is now explained by the BuildKit mount defect (writes
     never reached the remote because L0 failed first under the default
     write-error-policy=l0). Core findings (nvcc deadlock + miscompile) stand;
     a two-sentence correction protects the report''s credibility. Also note
     CUDA is launcher-off by default since 2026-08-10, so the deadlock repro
     needs SCCACHE_CUDA_LAUNCHER=1.
  3. **Restore `disk,webdav`** once WCOW cache mounts stop losing inherited
     writes — owner intent; two-step re-verification recipe in the archive
     (#99): probe twice (ON-mount row must be clean on the SECOND, inheriting
     run), then one media build with the chain re-enabled and genai at 0 write
     errors.
- **hcsshim follow-ups still unfiled** (package README status header,
  re-checked 2026-08-21): the ISSUE.md issue and the
  Windows-Containers#547 comment for microsoft/hcsshim#2855 (the draft
  PR itself IS filed; the package's submission recipe is now marked
  HISTORICAL so nobody files a duplicate).
- **Post the upstream issues** — POSTED 2026-08-13:
  mozilla/sccache → https://github.com/mozilla/sccache/issues/2808 (nvcc
  deadlock + miscompile), google-ai-edge/LiteRT-LM →
  https://github.com/google-ai-edge/LiteRT-LM/issues/3245 (CMake-lane
  staleness, four findings). **POSTED 2026-08-24:** opencv/opencv#29788
  (dnn/ORT `char*` vs `wchar_t`, from out/upstream-issue-opencv-ort-wchar.md) —
  our `004-dnn-ort-profiling-wchar.patch` stays until it lands upstream.
  **NEW DRAFTS (2026-08-24 evening, not posted — owner's call), both found by #116's
  first cross runs:** out/upstream-issue-iree-host-bin-dir-exe.md — `IREE_HOST_BIN_DIR`
  composes host tool paths without `.exe` on a Windows host;
  out/upstream-issue-iree-elf-arch-arm64-msvc.md — `MSVC_C_ARCHITECTURE_ID MATCHES 64`
  matches `ARM64`, archiving the x64 MASM object into an ARM64 library.
- **Post-run diagnostics queue — DEMOTED 2026-08-14: the sccache half is
  CLOSED.** The forensics had escalated this to "sccache has never worked, on
  any run" (0 hits / 189,861 failed writes across 94 stat blocks). **That was
  stale evidence, not a live defect** — the newest sccache stats in the whole
  corpus are from 2026-08-13 19:43, the dufs SYSTEM-service migration landed
  the same day, and every run since had media-core CACHED, so nothing could
  have shown the improvement. A direct probe (real cache mount, real WebDAV
  endpoint, one TU compiled twice) returned **miss → store → HIT, 0 write
  errors, 0 read errors**, and confirmed `HEAD`/`GET`/`PUT` succeed **from
  inside a container** — the direction `Assert-SccacheEndpoint` never tests.
  `SCCACHE_ERROR_LOG` is no longer "the missing artifact": the cache mount was
  found EMPTY, so there was never a log to recover.
  What remains here: (1) the exact-TU replay (`bias_softmax_impl.cu`) for the
  miscompile mechanism and the nvcc/CUDA sccache crash — **untested by the
  clang-cl probe and still genuinely open** (it is what drives #75's silent
  `-j` downgrade ladder); (2) one `probe-build-copy.ps1 -Heavy` smoke after the
  poisoned-chain prune; (3) re-measure the at-scale hit rate on the first real
  media build after 2026-08-13 — until then it is simply unmeasured.
  VERIFIED 2026-08-14: the buildkitd service env now really does carry
  `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `..._MAX_SPEED=-1` (checked at the service
  registry key, and today's base build no longer emits the clip warning) — so
  the next full chain will be the FIRST fully-captured one. The 49-run corpus
  analysed above predates this: 28 of those logs contain real clip events, the
  green reference run is 49 % blind in its merge step, and historical ONNX
  steps are 83 % blind. Re-run the forensics against a full captured chain.
