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

- **#122 — CUDA 13.4 (preview) on arm64: Phase 0 probe, then decide.** Probe S, wiring L · ★
  Phase 0 (~30 min, NO chain rebuild): arch-parameterize the literal `windows-x86_64` in
  `setup-cuda.ps1` (the audit found it hardcoded at the download-URL composition), HEAD the
  already-200-verified arm64 cuDNN archive at the exact pin, pull the CUDA 13.4 preview installer
  and confirm arm64 device `.lib`s are machine `0xAA64`. Only if all three hold: re-key the ORT
  CUDA branch on "an arm64 CUDA root exists" rather than "this is a cross build", point nvcc at
  the already-installed `Hostx64\arm64` MSVC toolset, and patch GenAI's `ortlib.cmake` CUDA
  package-name branch (it keys on `CMAKE_GENERATOR_PLATFORM`, empty under Ninja, so a naive flip
  fetches the x64-only nuget). **Do not relax the `-Gpu` driver refusal until both hold** — the
  image-state hazard it guards is real and unrelated. Value stays low while CUDA-on-WoA is a
  preview; the entry exists so the next reader starts from facts, not from the retracted
  "does not exist at all".

**Permanently out of reach — do not re-litigate without new upstream facts:** classic TensorRT
(genuinely x64-only — NVIDIA's support matrix has no ARM64 row), and the `torch` app stage (`uv
sync` must **execute** the target interpreter — uv can cross-RESOLVE into a directory, but the
synced venv is the stage's contract — and PyTorch builds no `win_arm64` wheel for **Python 3.14**,
this repo's cp314 pin). **Two premises originally recorded in this block (2026-08-23) were wrong
and are retracted (2026-08-24 parity audit):** "CUDA / cuDNN / TensorRT: no Windows-on-ARM builds
exist at all" — false: the cuDNN windows-arm64 9.25.0.15 archive exists at this repo's exact pin
(HTTP 200, 421 MB, `lib/arm64` inside), CUDA 13.4 (preview) advertises Windows ARM64 incl.
x86_64-hosted cross-compile, and TensorRT-RTX publishes Windows-on-Arm packages for CUDA 13.4 —
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
  (`2752685f` + docs `80f2258f`); STILL UNPROVEN — four acceptance attempts on 2026-08-26, none
  completed, and only ONE died of a #134 defect.**
  Run 37 found the re-export omission (fixed, `9bf0ef41`). The next three died of things that moved
  underneath the tree, not of this wave: a Vulkan pin with no Windows installer (`0dfd7c47`), an
  LLVM pin scoop could no longer install after upstream reshaped the artifact (`6bbcea65`), and the
  AArch64 `fixup value out of range` that the forced clang bump brought with it (#135, `20c4fc7e`).
  Each is in `docs/failure-modes.md`. The current attempt has cleared base, sdk, toolchain, onnx,
  ffmpeg and — since the #135 branch-range fix on 2026-08-27 — **opencv**: all 1,870 objects, the
  FFmpeg backend and provenance gates, and the `cv2.cp314-win_arm64.pyd` static gate. The media
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
  This confounds #134 with the bumps; the mitigation is that the compiler is unchanged
  (`LLVM_WINDOWS_VERSION` stays 22.1.8 — upstream ships no win64 installer for 23.1.0, verified
  404), so nothing that shapes compiled output moved.
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
  concurrent child solves (`build-buildkit.ps1:669-712`) — and the mount is inert anyway
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

- **#135 — LLVM 23.1.0 AArch64 codegen: both failures fixed; the second one's earlier diagnosis
  was wrong from end to end.** M · ★★ (opened 2026-08-26, closed 2026-08-27)
  The forced clang-cl bump to 23.1.0 broke the cross build of OpenCV in two places. They share one
  root signature — **LLVM lays a function out a few bytes SHORT of what it then emits**, so a pass
  picks an encoding the assembler then rejects — and `docs/failure-modes.md` § AArch64 cross
  compile aborts carries the symptom-first write-up, the four "do NOT"s and the local-repro recipe.
  **(1) Jump-table entry width — FIXED (`eb13d2a2`).** `AArch64CompressJumpTables` picks 1-byte
  entries from an estimate; every `N` measured sat just past the 1020-byte ceiling (256 = 1024 B,
  258, 259, 260, 262, 272, 281, 284). `-Xclang -target-feature -Xclang +force-32bit-jump-tables`
  keeps every table on 4-byte entries. `value evaluated as` went 4 → **0** in the cross build.
  Cost 4522 → 4650 bytes of object, ~2.8 %, all jump-table DATA; full `/O2` retained.
  **(2) `tbnz` just out of branch range — FIXED (2026-08-27,** per-TU `/Ob1` in
  `build-opencv-from-source.ps1`**).** At `/O2` the whole baseline median filter collapses into ONE
  function, `cv::cpu_baseline::medianBlur`, 8,465 instructions ≈ 33,860 bytes, and
  `tbnz w9, #31, .LBB546_847` inside it must reach a block ~32,916 bytes away against the ±32,768
  a 14-bit displacement encodes. `BranchRelaxation` exists to catch that and its estimate came out
  short. `/Ob1` on the offending TUs (via `Add-NinjaPerTuFlags`) stops the inliner gluing
  file-static helpers into one oversized function — no optimisation level is lowered; every kernel
  keeps `/O2`, vectorisation and unrolling, at the cost of one call per `medianBlur()`. The
  largest function in that TU drops 33,860 → 10,620 bytes: 3.1× headroom, not a 148-byte miss.
  **The list is a census:** `NINJA_KEEP_GOING=1` (→ `ninja -k 0`) compiled all 1,870 objects in
  one run and named every offender — `median_blur.dispatch.cpp` and `multiview_calibration.cpp`,
  and no third. Re-run it that way after an OpenCV bump.
  **WHAT THE EARLIER ENTRY GOT WRONG** — recorded so nobody re-derives it. It described (2) as an
  `adr` reach problem "in a function larger than ~1 MB", blamed it on
  `-aarch64-enable-compress-jump-tables=false` having removed the pass's `adr` check, and credited
  `+force-32bit-jump-tables` with "keeping the pass enabled". Every part of that is false:
  the feature makes the pass `return false` before it scans anything (source, 23.1.0) and emits
  **byte-identical** asm to `=false` (measured); with the pass off the `adr` is self-relative and
  cannot overflow; the largest function in the TU is 33 KB, not >1 MB; and the failing instruction
  is a `tbnz`, with no jump table involved at all (`-fno-jump-tables` fails identically).
  **Ruled out by measurement on the real TU, keep them ruled out:** `-fno-jump-tables`, dropping
  `+force-32bit-jump-tables`, `-mllvm -inline-threshold=100` and `=25` (single-call-site statics
  are inlined regardless of threshold — this is why `/Ob1` works where a threshold does not);
  `-max-jump-table-size` (caps entry COUNT, the ceiling is a byte SPAN); `-align-all-*` (kills
  clang-cl through the SEH unwind writer, llvm#122707 / llvm#47432); `/Od` and `/O1` (move the
  failure to the next TU, three times).
  **Upstream: two reportable LLVM 23.1.0 bugs, neither a prerequisite for this repo.**
  (a) The layout estimate that comes out short, which drives BOTH failures above — reportable on
  the evidence in hand (a `tbnz` left ~150 bytes out of reach is a `BranchRelaxation` miss, and the
  jump-table `N` values are the same defect one pass over).
  (b) **New, found 2026-08-27:** the asm printer emits a catch funclet's block address as
  `add x0, x0, .LBB0_903` — the `:lo12:` specifier is MISSING — so `/FA` output does not round-trip
  through LLVM's own assembler (`expected compatible register, symbol or integer in range
  [0, 4095]`). Object emission is unaffected. Reproduced locally in 15 lines: one `try`/`catch`
  whose body pushes the continuation block past 4 KB. This one matters beyond cosmetics: it blocks
  the `/FA` diagnostic route that `failure-modes.md` prescribes, until you repair the listing
  (the recipe there does).
  Check upstream HEAD before filing either — `out/` holds the drafts of previous reports.
  **(b) FILED 2026-08-27: [llvm/llvm-project#219200](https://github.com/llvm/llvm-project/pull/219200)**,
  from `Kataglyphis/llvm-project` branch `aarch64-catchret-lo12` — one commit ahead of `llvm/main`
  (the fork's `main` is 0 ahead / 12 behind, and that branch is its only non-upstream work).
  **It does NOT retire either workaround, and the tempting inference that it does is wrong.**
  The commit's own verification says so: the relocations were always correct
  (`PAGEBASE_REL21` + `PAGEOFFSET_12A`, checked by assembling the fixed output against
  `-filetype=obj`) and the change is `-S` / `/FA` only. Both #135 aborts happen during OBJECT
  emission, which that patch leaves byte-identical. What it buys is the diagnostic route:
  `failure-modes.md` prescribes `/FA` for exactly these no-source-location errors, and on
  Windows-on-ARM with C++ exceptions that route was closed. **(a) turned out to be TWO independent
  defects, not one — see the root-cause block below.**
  **Settling any future candidate:** don't reason about it, run
  `windows\scripts\diagnostics\repro-llvm-aarch64-layout.ps1` — the five real offenders frozen as
  preprocessed `.i`, compiled with the workaround OFF, with the stock compiler's reproduce-and-
  suppress arms gating the verdict so a stale corpus reports `INVALID` instead of a false fix.
  A `FIXED` verdict licenses the `NINJA_KEEP_GOING=1` census; it does not replace it.

  ### 2026-08-27 root cause: (a) is TWO defects, and this entry's "one signature at two sites" framing was wrong

  They do not share a cause. One is a known upstream bug with an existing fix; the other is still
  open but is now narrowed to a single measurable quantity.

  **(a1) `tbnz` / `fixup value out of range` — ROOT CAUSE FOUND, FIX EXISTS UPSTREAM.**
  [`c6e184686cd7` — *[AArch64][CodeGen] Fix trampoline basic block offset*](https://github.com/llvm/llvm-project/pull/202716),
  on `main` since 2026-07-21. Trampoline blocks are created with offset **zero**, so
  `isBlockInRange()` decides reach from offsets the code itself calls "slight underestimates" — a
  branch judged in range that is not, left unrelaxed, rejected at the MC layer.
  **Not in 23.1.0:** `release/23.x` forked 2026-07-14, one week *before* it landed. **Not
  cherry-picked onto `release/23.x`** either — checked by subject AND by PR number, because a
  cherry-pick carries a different SHA and SHA-ancestry alone cannot answer this (that hole cost one
  wrong "not backported" claim before it was closed properly).
  **Proven load-bearing, not assumed:** reverting only that commit on `main` and re-running its own
  `llvm/test/CodeGen/AArch64/branch-relax-tbz.mir` changes the result — with the fix the `TBZW`
  survives and targets a trampoline chain; without it the branch is inverted and the block layout
  changes.
  **Decision 2026-08-27 (owner): move the Windows toolchain to LLVM `main`; do NOT request a
  `release/23.x` backport.** A backport request was drafted and deliberately not filed. Note the
  timing that follows from that: the fix reaches a tagged release only in **24.1.0** (~Feb–Mar 2027
  at the observed 6-month major cadence — 22.1.0 was 2026-02-24, 23.1.0 was 2026-08-25); **no
  23.1.x will carry it unasked**, so `/Ob1` stays until the toolchain actually moves.

  **(a2) Jump-table entry width — NOT fixed on `main`, and now narrowed to one thing.**
  `AArch64CompressJumpTables.cpp` is **byte-identical** between `llvmorg-23.1.0` and `main`; the
  AsmPrinter's jump-table emission is untouched (its one commit since 23.1.0 is PAC-only);
  `getInstSizeInBytes`'s body is unchanged and no pseudo's `.td` `Size` moved. **Moving to `main`
  will not retire `+force-32bit-jump-tables`.**
  The pass is **sound given correct instruction sizes**: offsets are upper bounds, that inflation
  accumulates monotonically in layout order, so `Span = MaxOffset - MinOffset` is *over*-estimated,
  which selects a LARGER entry. It can therefore only fail if some instruction reports **fewer**
  bytes than it emits. The measured values (256, 258, 259, 260, 262, 272, 281, 284) put that
  under-count at **4–116 bytes**, between the table's lowest and highest target block.

  **The tool that will name it.** LLVM's AsmPrinter already verifies reported size against emitted
  bytes and aborts printing the function, the `MachineInstr` and both sizes — but the check is
  **inert on AArch64**: `TargetInstrInfo::getInstSizeVerifyMode()` defaults to `NoVerify` and
  AArch64 never overrides it (only AMDGPU and PowerPC do). The opt-in is written and committed:
  `D:\GitHub\llvm-project`, branch `aarch64-instsize-verify`, commit `65a5bd5601fe` — **local only,
  unpushed**. Build clang with it and compile
  `3rdparty/protobuf/.../descriptor.cc` in the container; the abort names the instruction and the
  fix is then a one-line `Size`.
  Two scans, both at `aarch64-pc-windows-msvc`, and keep them distinct: the **size verifier** over
  the 2,925 `.ll` files (2,049 compiled) reported **zero under-counts**; a separate **signature
  scan** over 3,347 files (`.ll` + `.mir`) reported **zero genuine reproductions** of either
  abort. So the offending construct is one LLVM's own tests never build. The single apparent
  `fixup value out of range` hit was an artifact of forcing a Linux/PIC test onto a Windows triple
  (it produces an `:abs_g3:` relocation COFF cannot encode); under its own triple it compiles clean.
  **Ruled out by reading the code, keep them ruled out:** `JumpTableDest8/16/32` (declares
  `Size = 12`, pessimistic BY DESIGN — the `.td` comment says "optimization occurs after branch
  relaxation so be pessimistic"); block alignment (modelled by `BasicBlockInfo::postOffset`);
  EH-funclet alignment (`beginCodeAlignment` is implemented only by `DwarfDebug`, emits no code
  bytes, unused on COFF); `CATCHRET` (lowers to a single 4-byte `RET`, and its ADRP/ADD are already
  real instructions before the estimating passes run).

  **A third LLVM bug, found on the way, and NOT the cause of either failure — now FIXED.** Every
  `SEH_*` pseudo reported **4 bytes and emitted 0** (538 of the 2,925 `.ll` files). That is the
  *over*-estimate direction, so it is conservative for both consumers — but it inflated every
  Windows-AArch64 size estimate by 4 bytes per SEH directive, and a prologue emits one per saved
  register. Two commits, **local and unpushed**, on `D:\GitHub\llvm-project` branch
  `aarch64-instsize-verify`: `1e6148bc4b9c` (the fix) and `f533c8e88038` (the verifier opt-in that
  found it). Mismatches **558 → 45**, all 45 remaining being over-estimates in unrelated pseudos;
  `check-llvm-codegen-aarch64` 4197 passed / 0 failed. **The `.td` route does not work** — the
  default case tests `if (Desc.getSize())`, so a declared `Size = 0` is indistinguishable from
  "unset" and still yields 4; it must be a C++ early return on `isSEHInstruction`. Full PR handover,
  including the two build-environment traps that each cost a run:
  [`out/upstream-llvm-aarch64-seh-instsize.md`](../out/upstream-llvm-aarch64-seh-instsize.md).
  **It does not retire `+force-32bit-jump-tables`**: removing an over-count moves the estimate
  toward the true value but never below it.

  ### 2026-08-27, second attempt at (a2): a sensitive detector, and it still did not fire

  The error-signature scans could only ever catch the defect if a span landed on the 1020-byte
  knife edge. The defect itself is `Span_est < Span_true` at ANY magnitude, so the pass was
  instrumented to dump its estimate and a checker computes the TRUE span from the emitted assembly
  — making every jump table a test. Instrumentation patch (not upstreamable, keep it):
  `D:\llvm-patches\jtspan-instrumentation.patch`.

  **Measured, all at `aarch64-pc-windows-msvc`, all with a validity gate that fails the run when
  nothing was actually measured:**

  | corpus | jump tables measured | `Span_est < Span_true` |
  |---|---|---|
  | 598 real C++ modules (LLVM's own sources) | 1,902 | 0 |
  | 400 synthetic MSVC-EH funclet + jump-table modules | 400 | 0 |
  | **the three real offenders** (`descriptor.cc`, `generated_message_reflection.cc`, `wire_format.cc`, from OpenCV's own bundled protobuf) | **28** | **0** |

  So the estimate held as an upper bound on ~2,350 real jump tables, including the exact source
  files that fail in the lane. **The one remaining difference is the one that cannot be closed on a
  host without MSVC:** that IR was produced by clang targeting `x86_64-w64-windows-gnu` (libstdc++,
  Itanium EH), because the Windows SDK is not present. The lane compiles it with clang-cl for
  `aarch64-pc-windows-msvc` under `/EHa` — MSVC STL, MSVC EH, different functions, different jump
  tables. **That gap is the whole remaining hypothesis space, and closing it needs the container.**

  ### 2026-08-27 — (a2) SOLVED. `EH_LABEL` under `/EHa` emits a 4-byte nop counted as zero

  **Root cause.** `AsmPrinter::emitFunctionBody()`, in the `EH_LABEL` case, emits a **NOP** when the
  module flag `eh-asynch` is set and the next instruction may load/store or raise an FP exception —
  so an async fault lands in the right EH region. `EH_LABEL` is a meta-instruction, so
  `getInstSizeInBytes` returns **0** for it while **4 bytes** are emitted. Every consumer of
  MIR-level block sizes is then short by 4 bytes per such label. That is the under-count this entry
  predicted, and its magnitude (4–116 bytes) is exactly 1–29 labels.

  **How it was isolated, and where the earlier corpora went wrong.** The whole hunt over LLVM's
  tests, synthetic IR and 598 real modules missed it for one reason: that IR was produced by clang
  targeting `x86_64-w64-windows-gnu`, which never sets `eh-asynch`. The lane compiles with `/EHa`.
  Flag bisection on the real TUs shows **`/EHa` is the sole trigger** — `/EHsc` plus any combination
  of `/Gy /Oi /bigobj /fp:precise -TP` compiles clean.

  **Measured A/B, one binary, same bitcode, toggling only the fix:**

  | TU | fix OFF | fix ON |
  |---|---|---|
  | `descriptor.cc` | `value evaluated as` **258**, **281** | clean, 1,457,567-byte object |
  | `generated_message_reflection.cc` | **284** | clean, 335,461-byte object |
  | `wire_format.cc` | **260** | clean, 233,801-byte object |

  Those are this entry's own recorded values. **The fix is committed** as `f072f90a9e37` on
  `aarch64-instsize-verify` (local, unpushed); `check-llvm-codegen-aarch64` 4197 passed / 0 failed.

  **Reproducing it costs ~10 seconds, not a lane run.** The
  `bk-windows-media-core-opencv-arm64` image already carries clang-cl 23.1.0, MSVC and the ARM64
  SDK; `buildctl` reaches buildkitd over `npipe:////./pipe/buildkitd` **without elevation**. Copy
  OpenCV's `3rdparty/protobuf/src` into a build context and compile one TU with
  `--target=aarch64-pc-windows-msvc /O2 /Ob2 /EHa`. Dockerfiles kept in `D:\pb-probe`.

  ### 2026-08-27 — a way to get the fixes into the lane without waiting for a release

  Both fixes **apply cleanly to the pinned `llvmorg-23.1.0`** (verified with
  `git apply --check`), which is what makes this cheap. Building the pinned release
  plus the two patches keeps the banner at `clang version 23.1.0`, so
  `verify-toolchain.ps1`'s provenance gate passes with `LLVM_WINDOWS_VERSION`
  untouched and every clang-cl-shaped source patch (`#129` probes, `mlasi.h`,
  `softfloat`) stays valid. Moving to LLVM `main` would disturb all of that for no
  extra benefit — the fixes are the only delta that matters.

  * `windows/scripts/patches/llvm/001-aarch64-ehlabel-size.patch` and
    `002-aarch64-seh-pseudo-size.patch` — the two upstream commits
    ([llvm#219275](https://github.com/llvm/llvm-project/pull/219275),
    [llvm#219276](https://github.com/llvm/llvm-project/pull/219276)).
  * `windows/scripts/build/build-llvm-from-source.ps1` — downloads the SAME pinned
    tarball and SHA256 the TVM stage already uses (so the no-unpinned-download rule,
    #47, is satisfied by a pin already in the repo), applies both patches through
    `Invoke-SourcePatch`, builds clang+lld, and **throws if the patched source does
    not carry `eh-asynch`** — a silently unpatched compiler would rebuild the exact
    bug this stage removes and only resurface hours later in the OpenCV stage.
  * `Dockerfile.toolchain-builder` gains an **opt-in** `patched-llvm` stage
    (`BUILD_PATCHED_LLVM=1`, off by default) and prepends `C:\llvm-patched\bin` to
    `PATH`. That is the entire integration: every build script resolves the compiler
    by bare name (`$env:CC = 'clang-cl'`, `--cc=clang-cl`), so shadowing the scoop
    shim needs no build-script change.

  **Not yet run end-to-end.** The stage is written and lints clean, but no full lane
  build has used it — and one cannot happen until the runhcs shim patch is
  redeployed after the Stevedore upgrade, or heavy media layers die at finalize with
  `ExportLayer 0x3` after paying the whole compile.

  **Strong open hypothesis — this may also be (a1), i.e. `/Ob1`.** `BranchRelaxation` consumes the
  same size function, `median_blur.dispatch.cpp` and `multiview_calibration.cpp` are also compiled
  with `/EHa`, and the miss there was ~150 bytes ≈ 37 labels. If so this single fix retires **both**
  workarounds and llvm#202716 is a separate, additional defect rather than the explanation. Test it
  the same way before assuming either.

  **Local build assets (not in this repo):** `D:\GitHub\llvm-project` (blobless clone) and
  `D:\llvm-build` (`llc`/`llvm-objdump`/`llvm-nm`, Release+assertions, AArch64-only, built with the
  Strawberry MinGW g++ 13.2 that ships with this host — there is no MSVC here, which is also why a
  Windows-ARM64 object cannot be produced outside the container).

- **#136 — the Windows base's Visual Studio RUN never caches across runs; it is now the dominant
  iteration cost.** M · ★★★ (opened 2026-08-26)
  Every launch replays `#9 RUN setup-vs.ps1` while `#6` (a RUN with a bind mount), `#7` and `#8`
  (the COPY of that very script) all report CACHED. Reproducible across five consecutive launches
  on 2026-08-26.
  **The cost is NOT constant, and the first version of this entry overstated it.** Cold it was
  ~22 min of build plus ~7 min of export; on the very next launch the same step reported
  `#9 DONE 363.2s` — six minutes — because the VS installer finds its downloads already present.
  So the tax per iteration is roughly 6–10 min warm and ~30 min cold, not a flat 30. Still worth
  fixing (it multiplies every Windows experiment), but do not plan around the cold figure.
  **Ruled out by measurement, not by reasoning:** GC eviction (`buildctl du` reports
  `Reclaimable: 4.27MB` of a 499.9 GB store, and the two ~37.6/37.8 GB VS-class records are
  present); a build-arg that varies per run (the driver passes only version pins — no timestamp,
  VCS ref or GUID reaches this stage); `-NoCache`/`-NoCacheStage` (not passed); and a changed COPY
  input, since `#8` — the COPY of `setup-vs.ps1` itself — is CACHED, so its parent chain and that
  file are byte-identical.
  **SOLVED 2026-08-26 (`916c91f0`) — it was the GC reserve, and the answer was inside
  `buildkitd.toml` itself.** Its sizing note concludes "150GB is the floor this file's own sizing
  note gives" and "keep reservedSpace >= 150 GB regardless"; the value directly beneath it read
  **40GB** — below the single ~37 GB VS-class layer, so the spine could not survive between runs.
  `maxUsedSpace` compounded it: the store had grown to 545 GB, above BOTH ceilings (400/450 GB), so
  GC was evicting on every run no matter what the reserve said. My earlier "GC ruled out because
  `du` reports `Reclaimable: 0B`" was the wrong reading — `0B` is what a store already pruned to
  its floor looks like, not a store that is never pruned. That inversion is the lesson worth
  keeping.
  **Fixed:** reservedSpace 40→150 GB, maxUsedSpace 400→650 GB (tier 1) and 450→700 GB (tier 2).
  Arithmetic at edit time: C: 824 GB free of 1861 GB, store 545 GB, other content ~492 GB — so
  150 GB is comfortably satisfiable, unlike the 2026-08-08 deadlock at 214.75 GB when only ~294 GB
  was available to buildkit. Three docs claimed a third number (200 GB) matching neither the config
  nor `windows-build-lanes.md`'s own "150GB now"; all aligned.
  **This was the second half of a fix only half-made on 2026-08-11**, which raised `maxUsedSpace`
  after GC evicted "the base/sdk/toolchain spine between driver runs → every run re-solved the
  prefix" — verbatim this symptom — and left the reserve alone.
  **DEPLOYED AND PROVEN 2026-08-26 23:10 (owner ran the elevated apply).** Verified by effect, not
  exit code, as that script has reported success while leaving the old value before (2026-08-08):
  the live daemon reports `Reserved space: 161.0612736GB` on rules 1 and 2 with
  `Maximum used space` 697.93/751.62GB. **The proof is the next build**, not the config dump — the
  very first launch afterwards reported `#6 #7 #8 #9 #10 CACHED`, the first time `#9` had cached in
  six attempts that day. Base went from ~4–7 min of VS install plus ~7 min of export to under a
  minute. Six attempts on 2026-08-26 would have cost ~2.5 h in cold prefix alone.
  My "this run probably will not benefit yet, the records were already evicted" caveat was wrong:
  the previous run's records were still present, and the raised ceiling simply stopped GC from
  taking them.
  **One doc trap this exposed, now fixed:** `buildctl debug workers -v` prints GB while the toml
  takes GiB, and uses different labels (`Reserved space:` vs `reservedSpace`). A 150 GiB pin shows
  as `161.0612736GB`, so the verification instruction "must read 150GB" — which I had just written
  into two pages — would make a correct deploy look failed.

- **#137 — sccache: the local patch and the source build may both be droppable (owner's PRs were
  accepted upstream).** S–M · ★★ (opened 2026-08-26, owner's news)
  `Dockerfile.base` builds sccache from source at `SCCACHE_GIT_REV=ffac4a59` and applies
  `windows/upstream/sccache-nvcc-quote-fix/0003-nvcc-accept-the-diag-error-diag-suppress-diag-warn-f.patch`
  on top (`setup-rust-toolchain.ps1`). With the PRs merged upstream, the patch is redundant, and if
  a RELEASE contains them the source build can collapse back to the pinned binary
  (`SCCACHE_WINDOWS_VERSION` / `SCCACHE_LINUX_VERSION`, both 0.17.0) — removing a cargo build from
  the base entirely.
  **Order matters:** confirm the fixes are in the target rev/release FIRST (the patch header names
  what it fixes; `probe-sccache-patch-verify.ps1` and `probe-sccache-2726-repro.ps1` exist for
  exactly this), then drop the patch, then decide rev-vs-release. Do NOT fold this into an
  acceptance run — it is a base-layer change and would confound #134/#135, which are already
  carrying a forced compiler bump. Give it its own window. Files: `versions.env` (3 pins),
  `setup-rust-toolchain.ps1`, `windows/upstream/sccache-nvcc-quote-fix/`, and the four probe
  scripts under `windows/scripts/diagnostics/`.

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
