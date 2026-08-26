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

The `:winarm64` cross lane completes end to end — since 2026-08-24 that includes the source-built
target CPython, plain LiteRT and the restored `tflite` GStreamer plugin, with all four mandatory
plugins shipping on BOTH lanes again — its arch gate passes **931 binaries, 0 violations** (the
390 recorded at opening predates those additions), and the smoke gate now RUNS on this lane:
**97 passed / 0 failed / 15 skipped** against floors 66/25. As of 2026-08-24 evening (arm64 run
11: all three media branches, arch gate 950/0, smoke 97/0/15) every component **builds** for the
target: the Python-binding consumers landed (#120 step 2) and TVM/IREE ship as runtimes (#116);
amd64-only by construction are the TVM/IREE *compilers* and their python packages, LiteRT-LM
(Bazel), CUDA (#122, deferred by the owner) and the torch app stage — each marked ABSENT inside
the bundle; the QNN EP is wired but needs a hand-staged SDK (#121). **CORRECTED 2026-08-25
(consumer-side audit, three reviewers, claims re-checked against code and configure logs): "built"
is not "usable at first touch".** The bundle's Python surface would fail on a clean
Windows-on-ARM machine before any user code runs — `python.exe` cannot find its own
`vcruntime140.dll` (#124), no `sitecustomize` registers the DLL directories for the target
interpreter (#125), no numpy/pip/runtime deps are staged for the target (#126) — and two
silent degradations no gate watches: GStreamer arm64 lacks `webrtc`/`nice` (#128) and OpenCV arm64
ships **zero dispatched NEON kernels** (#129). Entries #124–#131 below carry the evidence and the
fixes; every one is host-side and statically gateable. **FIXED 2026-08-25 (arm64 run 14, `[bk]
Done in 01:26:50`): #124–#127 are closed** — CRT beside `python.exe` and in `C:\runtime\bin`
(9 DLLs), a target `sitecustomize`, 7 wheels with every `Requires-Dist` resolving in the store, and
a whole-tree import walk as a hard merge gate (`970 inspected / 0 violations; 571 walked / 0
unresolved`); its first run had found 13 real gaps (OpenSSL runtime DLLs, `vcruntime140_threads`,
client-OS names), all now staged or classified. #128/#129 stay open as degradations, not blockers.
Each item below carries a
**verified** blocker — every one was researched against the actual code and upstream, then
adversarially re-checked, because an optimistic "solvable" here costs 25 min to several hours
of build time per attempt. Ordered by leverage ÷ risk, which is the order they should be done in.

- **#112 — FFmpeg aarch64 assembly.** ✅ **DONE 2026-08-24 (Route A, built and verified).**
  Route A needed **no new tooling**: `$confFlags += "--as=clang$ffCcTargetFlag"` replaced
  `--disable-asm`, letting clang's integrated assembler handle the GAS syntax that
  `gas-preprocessor.pl` + `armasm64` (Route B) would otherwise have been needed for. The
  precondition held: `--enable-cross-compile` disables configure's runtime probes, so configure only
  *assembles* its test fragments and never runs a produced binary — which is the only reason this is
  tractable on a host that cannot execute aarch64 at all.
  **Evidence, not inference:** the build log reports `NEON enabled yes`, `config.mak: ARCH=aarch64`
  and `config.mak: AS=clang --target=aarch64-pc-windows-msvc`, and of the **99 distinct
  `aarch64/*.o`** objects, **56 went through real `AS` steps** — `swscale_unscaled_neon.o`,
  `vf_bwdif_neon.o`, `aacencdsp_neon.o`, `ac3dsp_neon.o` and so on — while the other 43 are
  C-compiled `*_init*`/dispatch TUs. (Two earlier notes said 87 and then "99 assembled"; both were
  mis-counts — 99 is the total, 56 is the assembled subset, measured 2026-08-24 with `AS`-line
  extraction rather than filename counting.) The amd64 lane is untouched because the flag sits inside the
  cross-only branch and is composed solely from the cross-lane target flag. At the time this landed
  amd64 had **no** nasm path to keep — `--disable-x86asm` had been appended unconditionally since
  bd6adca4 (2026-06-25, it entered with the file itself), so FFmpeg built no external x86 assembly on
  either lane. That asymmetry (arm64 with NEON assembly, amd64 with none) was filed as #119 and
  closed the same day by enabling x86asm on the amd64 lane (see #119 below).

- **#113 — DirectML on arm64.** ✅ **DONE 2026-08-24 (ORT side; built and gate-verified).**
  Confirmed by byte inspection, not inference: `Microsoft.AI.DirectML` 1.15.4 *does* ship
  `bin/arm64-win/DirectML.lib` (COFF import archive, machine `0xAA64`). This was never a packaging
  gap, and the "no arm64 import library" verdict recorded until 2026-08-23 is retracted.
  `cmake/external/dml.cmake` declares the download's outputs lower-case as `bin/arm64-win`, while
  `cmake/onnxruntime_providers_dml.cmake` composes its consumer paths as
  `bin/${onnxruntime_target_platform}-win` — and `onnxruntime_target_platform` holds the verbatim,
  upper-case `ARM64`. The two spellings never meet, so the lane failed with
  `bin/ARM64-win/DirectML.lib ... missing and no known rule to make it`. That the failing message
  itself said `ARM64` is what proves the variable's casing, and therefore that `TOLOWER` lands on
  the directory that exists.
  **Fix:** two `Invoke-InlineRegexPatch` edits in `build-onnx-from-source.ps1` — one inserts
  `string(TOLOWER "${onnxruntime_target_platform}" onnxruntime_dml_redist_platform)` above the
  `if (NOT onnxruntime_USE_CUSTOM_DIRECTML)` block, the other reroutes both consumers through it;
  a re-read then throws if either edit misses, so upstream drift fails loudly instead of silently
  reverting to the broken path. Both were simulated against the real upstream file before building
  (TOLOWER inserted once at module scope, zero upper-case consumers left, two lower-case). A static
  `.patch` was written first and deleted — its hunk line counts were hand-computed, and the inline
  patcher is already this repo's drift-tolerant mechanism. `USE_DML` is now ON unconditionally in
  ORT.
  **Evidence it worked:** both patch lines logged at 33.5s; `ONNX: DirectML EP ON`;
  `[1116/1118] Linking CXX static library onnxruntime_providers_dml.lib`; `DirectML.dll` staged to
  `C:\runtime\lib\onnxruntime-source\bin`; 117 of 994 sccache requests missed — the DML translation
  units that had never compiled on this lane. The merge-stage arch gate then reported
  **390 binaries inspected, 0 violations** (389 before DirectML joined), with no allowlist skips.
  Since the gate's root is `C:\runtime`, `.dll` is in its extension set, and
  `Dockerfile.media-merge-builder:155` copies the whole `C:\runtime` tree, `DirectML.dll` was
  necessarily among the 390 — so the shipped DirectML is arm64.
  **Honest limit:** this proves the right *bytes* ship, not that the DML EP *runs*. Nothing arm64
  executes on this x64 host; only the `windows-11-arm` CI job can show that.
  **Follow-up — closed by #118 (2026-08-24):** GenAI (`-DUSE_DML`) and OpenCV (`WITH_DIRECTML`)
  were OFF when this entry was written; both are ON on both lanes since #118 landed the same
  day. Worth recording so the
  next reader does not re-investigate it: GenAI's `D3D12Core.dll` staging is *already* correct for
  arm64 — `$d3d12ArchDir = (Get-WindowsRuntimeIdentifier) -replace '^win-', ''` resolves through
  `Get-WindowsTargetArch`, i.e. the **target**, giving `arm64` on this lane, and the nuget's
  directory names are exactly those RID arch components. That was made target-derived deliberately
  (see the comment at `build-onnx-genai-from-source.ps1:286`) precisely for this eventuality.

- **#114 — aarch64 CPython, and the Python bindings it unblocks.** L · ★★★ · **SUPERSEDED-BY #120** (its Phase-0 questions still apply — answer them there first) · ✅ **CLOSED 2026-08-25 through #120** (target CPython from source, all four bindings staged, proven by arm64 run 14)
  The highest-leverage item: it is what keeps `cv2`, the ONNX Runtime wheel, ONNX GenAI's bindings
  and PyAV off the lane. **Do Phase 0 first** — a ~20 min probe (no chain rebuild) answering exactly
  three questions: does the image's VS ship `Platforms\ARM64\PlatformToolsets\ClangCL`, does
  `Hostx86\arm64\cl.exe` exist (setuptools' `x86_arm64` spec needs it for PyAV), and does
  `PCbuild\build.bat -p ARM64` actually run to completion. Could not be answered up front because
  `ctr`/`docker` need elevation on this host. **The decisive distinction** is between *compiling and
  linking a `.pyd` against the target's headers and import lib* (no execution, feasible) and
  *setuptools/pip wheel packaging*, which normally runs the interpreter (not feasible here).
  `Get-SourceBuildPython` must stay HOST-pinned — the cross lane runs builds with the host
  interpreter while linking against the target one. Those two must never be conflated again.

- **#115 — plain LiteRT without LiteRT-LM (would also restore the `tflite` GStreamer plugin).** L · ★★ · ✅ **DONE 2026-08-24 (built, merged, gate- and smoke-verified).**
  `media-litert` runs on arm64 — 146 libs staged incl. the aarch64 `tensorflowlite_c.lib`; the
  LiteRT-LM stage self-skips (citing its two real Bazel blockers, below) and stages the empty
  litert-lm stand-in tree so the merge COPY keeps working. Cross needs exactly TWO host tools, both
  from pinned sources: `flatc` built natively from the SAME tree (the `flatbuffers-flatc` target, a
  per-call `-TargetArch` host override on that one choke point) and protoc **21.9** (github release
  zip — the version derives from the VENDORED protobuf commit `90b73ac3` = C++ runtime 3.21.9, NOT
  the LM lane's `PROTOC_VERSION=31.1`, whose gencode needs a `google/protobuf/runtime_version.h`
  that 3.21.9 does not ship). XNNPACK needed the MLAS-class per-TU treatment, now in
  `build-litert-from-source.ps1`: 569 C microkernel TUs tagged per-FAMILY in `build.ninja`
  post-configure (families completed against upstream's `PROD_*` list; SME skipped; floor 100),
  while the 335 hand-written aarch64 `.S` kernels get a FULL-UNION in-source
  `.arch armv8.2-a+fp16+dotprod+i8mm+bf16` directive — an assembler validates but never emits, so
  the union is byte-neutral for asm, while C stays per-family because a compiler may auto-vectorize
  (floor 10). The green took **8 iterations**: two self-inflicted (a PowerShell
  plus-sign-outside-parameter binding bug; the legacy export-symbol assumption, next paragraph),
  the rest genuine cross gaps — the per-TU features, the chain-wide ASM triple
  (`Get-CMakeCrossArgs` now also sets `CMAKE_ASM_COMPILER_TARGET` / `CMAKE_ASM_FLAGS_INIT`; before
  that, any project enabling the ASM language assembled with the X64 default target, and an aarch64
  `-march` handed to that x86 driver was misread as a CPU name — amd64 untouched, its cross args
  stay empty), host `flatc`, host protoc + its version family, and the vcruntime redist copy (#120).
  **Durable measurement (2026-08-24), so no future gate re-asserts the wrong symbol:** the plugin
  contract demands all four mandatory plugins on BOTH lanes again (`Get-RequiredGstPlugin`'s
  `UnavailableOn.arm64` deleted), the tflite switch is presence-driven
  (`-Dgst-plugins-bad:tflite=enabled`, never auto), and the hardened cross plugin gate walks the
  dependency tree (dumpbin) AND asserts the per-plugin export marker — MEASURED: modern GStreamer
  (per-plugin registration since 1.14) exports `gst_plugin_<name>_get_desc` + `_register`, NOT the
  legacy `gst_plugin_desc` the gate's first version asserted; that version failed all four plugins
  incl. three amd64-proven ones and was recalibrated from dumped export tables.
  **History — the pre-build analysis below is kept as written (it dates its own corrections):**
  **Corrected twice — the 2026-08-23 correction that stood here was itself half-wrong (fixed
  2026-08-24):** the original note blamed ONLY the prebuilt `libGemmaModelConstraintProvider.lib`;
  the 2026-08-23 rewrite swung to blaming ONLY the `.bazelrc`. **Both halves are real** on
  LiteRT-**LM**'s active **Bazel** path: (a) `.bazelrc` has no windows-arm64 config (only
  android/macos/ios arm64 ones), and (b) the prebuilt **x86_64-only**
  `libGemmaModelConstraintProvider` *is* in the default Windows dependency graph via
  `gemma3_data_processor` — severable with the `litert_lm_fst_constraints_disabled` config_setting
  (`model_data_processor/BUILD:26-33`), so a removable blocker, not a wall. (The earlier "upstream's
  CMake path compiles the `gemma_model_constraint_provider.cc` stub instead" observation described
  the frozen CMake fallback, not the active Bazel path.) **Neither half applies to plain LiteRT**:
  pure CMake, no Bazel, no prebuilt — its only cross obstacle is upstream's `TFLITE_HOST_TOOLS_DIR`
  requirement for a host `flatc`, and `flatc` is already named on the merge gate's host-tool
  allowlist. That plain-LiteRT cross build is exactly this item. If it lands, the
  `media-branch-absent` stand-in shrinks and `Get-RequiredGstPlugin -Arch` can stop dropping `tflite`.

- **#116 — TVM and IREE on the cross lane.** L · ★★ (opened 2026-08-24) · ✅ **DONE 2026-08-24,
  extended 2026-08-26 by #133.** Runtime-only by design: `tvm_runtime.dll` + `tvm_ffi.dll` +
  headers, and 14 IREE target tools/libs under `C:\runtime\iree\bin`, built through upstream's
  documented host-tools/`IREE_HOST_BIN_DIR` split. The compilers need TARGET-arch LLVM libraries
  plus a HOST `llvm-config` at configure time — a split this repo does not build — so they are
  named ABSENT in the bundle rather than silently missing. Since #133 the two runtimes also ship
  their **python** packages. Narrative:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md).
- **#117 — the arch gate covers `C:\runtime` only; the CPython tree is outside it.** S · ★★ · ✅ **RESOLVED 2026-08-24 (see the resolution below; the question stands as history).**
  `Dockerfile.media-merge-builder:172` fans in `C:\temp\cpython\Lib\site-packages`, and the gate runs
  `-Path 'C:\runtime'`. So the arm64 image carries the **host x64 CPython and its site-packages**, and
  the binaries the gate reported were all genuinely arm64 — they just were not *everything*.
  **Not obviously a defect, which is why this is a question and not a fix:** that interpreter is the
  HOST tool that *runs* the builds and is legitimately x64, so simply adding `C:\temp\cpython` to
  `-Path` turns a correct build red. Decide first what `C:\temp` *is* — build residue or shipped
  payload — then either exclude it from the image on the cross lane or gate it with the host-tool
  allowlist. A first attempt at "just gate it too" was written and reverted on 2026-08-23 for exactly
  this reason. Resolve together with #114, which changes the answer.
  **Resolution (2026-08-24):** exactly as this entry predicted, #114's successor — #120 — changed
  the answer. The merge arch gate now scans `C:\runtime` AND `C:\temp\cpython\Lib\site-packages`,
  with `-IncludeArchives`; the 58 host x64 `.pyd`s in site-packages appear as REPORTED allowlist
  skips, and the green figure — **931 binaries, 0 violations** — is the whole-image statement this
  item asked for. The "is `C:\temp` payload?" half is settled by #120: the SHIPPED interpreter on
  arm64 is `C:\runtime\python`; the host CPython stays build tooling.

- **#118 — flip DirectML ON for GenAI and OpenCV now that ORT's arm64 DML is verified.** S · ★★ · ✅ **DONE 2026-08-24 (both flips built and gate-verified).**
  Unblocked by #113. Both are OFF **purely as sequencing**, not for any platform reason: GenAI links
  ORT, so a half-enabled DML there produces link errors that read like a GenAI bug, and OpenCV's
  `cv::dnn` would advertise a backend whose runtime half was unproven. ORT's side is now built,
  linked and gate-verified, so that reason has expired.
  **Two things already checked, so the next reader does not redo them:** (1) GenAI's `D3D12Core.dll`
  staging is already target-derived — `(Get-WindowsRuntimeIdentifier) -replace '^win-', ''` resolves
  through `Get-WindowsTargetArch`, yielding `arm64` here, and the `Microsoft.Direct3D.D3D12` nuget's
  directory names are exactly those RID arch components. (2) The Agility SDK does ship an arm64
  `D3D12Core.dll`. So this is close to two one-line flips plus a rebuild.
  **What to watch:** the arch gate count must rise again (each newly staged DLL is one more
  inspected binary, and `D3D12Core.dll` is not on the host-tool allowlist), and OpenCV's
  `WITH_DIRECTML=ON` pulls DirectML headers into `cv::dnn` TUs that have never seen them on this
  lane. Do GenAI first and OpenCV second — same reasoning as #113's ordering.
  **The limit stays the same as #113:** a green build proves the right bytes ship, never that the EP
  runs. Only the `windows-11-arm` CI job can show that.
  **Done (2026-08-24):** GenAI builds with `USE_DML=ON` on both lanes and stages the **arm64**
  `D3D12Core.dll` from the nuget's `bin/arm64` — the target-derived filter above resolved exactly
  as recorded, no re-investigation needed; OpenCV builds with `WITH_DIRECTML=ON`, consumed via the
  G-API EP. The arch gate count rose as predicted and the whole-image figure stands at
  **931 binaries, 0 violations** (see #117). The runtime limit above is unchanged: bytes proven,
  execution still owed to the `windows-11-arm` CI job.

- **#119 — amd64 FFmpeg ships with NO external x86 assembly, and arm64 now has more SIMD than it.** M · ★★
  ✅ **DONE 2026-08-24, proven the same evening on the amd64 regression:** configure reports
  `x86 assembler  …/nasm.exe`, the build assembled **154** `X86ASM` objects (`libavcodec/x86`,
  `libavfilter/x86`, `libswscale/x86`, …) and linked them under lld-link into `ffmpeg.exe` + the
  7 DLLs; the stage went green in 6:15 including the PyAV wheel and its `import av` gate. The
  lld-link-vs-nasm-object question the original entry raised is answered by that link step.
  Found 2026-08-24 while checking whether #112 could regress amd64. It cannot — but the check turned
  up something else: `build-ffmpeg-from-source.ps1` appended `--disable-x86asm` **unconditionally**
  (present since `bd6adca4`, 2026-06-25 -- it entered with the file itself; an earlier note here blamed `8c5c50e7`, which is only the relicense commit that MOVED the file), so FFmpeg built none of its hand-written x86 SIMD
  on either lane. After #112 the cross lane assembled 99 NEON objects while amd64 assembled zero —
  the arm64 bundle was, in this one respect, *ahead* of the shipped amd64 image.
  **The archaeology was done before the flip, as this entry demanded.** `git show bd6adca4` is a
  bare "fix" commit (5 files, 347 insertions) that added the whole FFmpeg script; the flag sits
  between `--toolchain=msvc` and the CUDA comment with **no rationale, no failing configure, no
  nasm/lld-link note** — a first-bring-up simplification that later got documented as a premise. The
  script now enables x86asm on the amd64 lane (`--x86asmexe=<pinned nasm>`, asserting nasm is on
  PATH — `verify-toolchain.ps1` already pins it) and keeps `--disable-x86asm` **explicitly** on the
  cross lane, where the knob is meaningless for aarch64. The comment at
  `build-ffmpeg-from-source.ps1:410` no longer calls the disabled state a premise of the toolchain
  choice; it was never load-bearing for the msvc-preset-plus-compiler-override approach (configure
  assembles nasm fragments independently of `--cc`).
  **What "proof" meant here, and what delivered it:** configure names the x86 assembler only when
  nasm assembled its test fragment, and the build log then carries `X86ASM` lines for the `.asm`
  kernels. The deciding artifact was the amd64 `media-core-built-ffmpeg` solve of 2026-08-24
  ~23:10 (see the DONE line above) — nasm invoked through its scoop shim, 154 objects, clean link.
  **The misattribution this uncovered** (three places claimed nasm was *FFmpeg's* assembler: the pins
  table, `verify-toolchain.ps1`, the old #112 text) was corrected the same morning — and then
  re-corrected the same evening, because the flip made the original attribution *true again*: nasm
  now shapes both GStreamer's openh264 (`build-gstreamer-from-source.ps1:482`) and FFmpeg's amd64
  kernels.

- **#120 — target aarch64 CPython built from source (`PCbuild -p ARM64`, ClangCL), and the
  bindings it unblocks.** L · ★★★ · ✅ **DONE 2026-08-24 — step 1 (the interpreter) in the
  morning, step 2 (all four binding consumers) in the evening** (opened 2026-08-24; supersedes #114)
  The gap it closes: the arm64 image advertises `PYTHON_WHEELS` while the wheel store
  `C:\runtime\wheels` is **empty** on that lane — no `cv2`, no ORT wheel, no GenAI bindings, no
  PyAV. Decided 2026-08-24: build the target CPython **from source** via `PCbuild\build.bat -p
  ARM64` under ClangCL, the same route the host CPython already takes; the alternative — fetching
  the upstream nuget arm64 CPython — was considered and **rejected by the owner** (2026-08-24), so
  do not resurrect it. #114's Phase-0 questions (ClangCL ARM64 platform toolset present?
  `Hostx86\arm64\cl.exe` present? does `PCbuild\build.bat -p ARM64` complete?) still apply and come
  first. #114's decisive distinction also carries over unchanged: `Get-SourceBuildPython` stays
  HOST-pinned — the cross lane runs builds with the host interpreter while linking against the
  target one; the two must never be conflated again.
  **Step 1 DONE (2026-08-24), measured:** `PCbuild\build.bat -e -p ARM64` with the repo's ClangCL
  props + `/p:PreferredToolArchitecture=x64` completes in ~91 s incl. the externals fetch;
  `python.exe` is PE `0xAA64`, verified IN-STAGE; **2864 files** staged to `C:\runtime\python`
  (interpreter, `python314.lib`, headers, stdlib). This answers #114's Phase-0 Q1 POSITIVELY: VS 18
  ships the ClangCL PlatformToolset for ARM64 — pythoncore's own "Toolset ClangCL is not used for
  official builds" warning fired, which proves the toolset resolved.
  **Durable fact (2026-08-24), so nobody hunts for a "missing" DLL:** `vcruntime140_1.dll` has NO
  ARM64 edition **by design** — it exists only to carry x64 FH4 exception helpers; ARM64 keeps
  everything in `vcruntime140.dll`. MSBuild's host-blind redist copy put the **x64** one into the
  ARM64 build output, the extended arch gate caught it (the single violation among 932 scanned),
  and the stage now self-polices every staged binary's PE machine and drops exactly that file under
  a tightly-guarded rule.
  **Step 2 DONE (2026-08-24 evening, arm64 run 3), measured — all four consumers build for the
  target:** `onnxruntime-1.29.0-cp314-cp314-win_arm64.whl` (4 native members, all `0xAA64`),
  `onnxruntime_genai_directml-0.15.2-cp314-cp314-win_arm64.whl` (3), `av-18.1.0-cp314-cp314-win_arm64.whl`
  (49), and `cv2.cp314-win_arm64.pyd` installed into the **target** interpreter's site-packages
  (`C:\runtime\python\Lib\site-packages`, inside the arch gate's scan root). The design that made it
  work, in one line each — full detail in `docs/windows-cross-builds.md` § "#120 step 2":
  the HOST interpreter *runs* every build (`Get-TargetBuildPython .Exe`), the TARGET import lib is
  what gets *linked* (`.Lib`/`.LibDir`); wheels are built with an explicit `--plat-name win_arm64`
  and **staged, never installed or imported** here (`Invoke-PythonWheelBuild -StageOnly`, since #131 the one-call `-CrossStage` →
  `Assert-WheelTargetArch`, which opens the wheel and PE-checks every native member **and** its
  `EXT_SUFFIX` name tag); cv2 gets the static equivalent of its import gate. Three findings the
  runs produced, each now pinned by code or test: (1) ORT's CMake reads `Python_*`, not
  `Python3_*` — the names passed for months were silently ignored on **every** lane ("Manually-
  specified variables were not used"), amd64 only worked by auto-detection; GenAI needs **both**
  `Python_*` (its own `find_package`) and the legacy `PYTHON_*` (its vendored pybind11 in classic
  mode) — `SourceBuild.FindPythonPrefix.Tests.ps1`. (2) `if (Test-WindowsCrossTarget -and -not
  …)` is parsed in *command mode* — `-and`/`-not` become arguments, the branch fires regardless —
  which is how run 2 skipped the ORT wheel with "python wheel 0s". (3) The host-pinned
  `sitecustomize` shim stamped the **host** `EXT_SUFFIX` on target modules
  (`cv2.cp314-win_amd64.pyd`, machine `0xAA64`: right bytes, unloadable name — an arm64 interpreter
  loads only `.cp314-win_arm64.pyd` or bare `.pyd`); the shim now pins `EXT_SUFFIX` to the target on
  the cross lane while `get_platform()` stays host (pip resolves downloads with it), verified
  standalone under a host python before the run. The `C:\runtime\wheels` store is no longer empty
  on arm64. What still cannot happen here: importing any of it — every arm64 signal stays static.

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

- **#123 — `llvm-ml` for the MASM-syntax assembly on amd64 (MLAS x64 kernels, IREE's
  `x86_64_msvc.asm`).** S–M · ★ (opened 2026-08-24 evening, owner's request)
  The "clang-cl everywhere" rule holds for compilers and linkers on both lanes and for every
  assembly path on arm64 (clang's integrated assembler: FFmpeg `--as=clang`, XNNPACK/MLAS `.S`,
  IREE inline `asm`). On amd64 two other assemblers are in the build: **nasm** for NASM-syntax
  kernels (FFmpeg since #119 — 154 objects, libjpeg-turbo in OpenCV, openh264 in GStreamer) and
  **MSVC's `ml64.exe`** for MASM-syntax sources — ONNX Runtime's `mlas/lib/amd64/*.asm`
  (`Building ASM_MASM object` in every ORT log; the assembler is CMake's default `ASM_MASM` search,
  `ml64` before `ml`, no `CMAKE_ASM_MASM_COMPILER` is set anywhere in this repo) and IREE's ELF
  trampoline (`add_custom_command COMMAND ml64` upstream). nasm has no LLVM replacement (LLVM
  ships no NASM-syntax assembler; dropping it means dropping the kernels). `ml64` does:
  **`llvm-ml`** is LLVM's MASM-compatible assembler and ships with the pinned LLVM. The work:
  `-DCMAKE_ASM_MASM_COMPILER=<llvm-ml.exe>` in `Invoke-CmakeConfigure` (same shape as the
  `CMAKE_AR=llvm-lib` archiver arg), an assert that the ORT configure reports `llvm-ml` as the
  ASM_MASM compiler, an amd64 ORT build proving MLAS's macro-heavy `.asm` files assemble and link
  under it, and for IREE a small patch of the `ml64` custom command (or leave that one file on
  ml64 and say so). **Unverified until built:** whether MLAS's MASM dialect is fully within
  llvm-ml's compatibility — that is the whole question this item answers. Ordering: after the
  current amd64 regression; it touches the ~50-min ORT stage.
  **Implemented 2026-08-25, proof pending the next amd64 regression:** `Get-LlvmMasmCmakeArg`
  (`WindowsSourceBuild.Common.psm1`, throws when `llvm-ml` is absent — a silent ml64 fallback is the
  exception this removes) → `-DCMAKE_ASM_MASM_COMPILER:FILEPATH=<llvm-ml>` on the native ORT
  configure, whose output is now tee'd to `onnxruntime-configure.log` and asserted to name llvm-ml
  in its ASM_MASM/assembler lines; IREE's `COMMAND ml64` custom command is patched to
  `${IREE_MASM_COMPILER}` (fail-loud when neither form is present) and both its configures
  (host tools and target) pass `-DIREE_MASM_COMPILER=<llvm-ml>` — on the cross lane the HOST tools
  pass assembles the x86_64 trampoline through it, so the arm64 run is the first proof of the IREE
  half; the MLAS half needs the amd64 lane. **First measurement (arm64 run 22, host pass):**
  `llvm-ml /nologo /Zi /c /Fo … x86_64_msvc.asm` → `.seh_* directives are not supported on this
  target` — not a dialect gap: llvm-ml assembles for **i386 unless told `-m64`**, and the file's
  x64 frame directives (`.PUSHREG`/`.SETFRAME`, which llvm-ml lowers to `.seh_*`) need the x86_64
  target. `-m64` is now part of the IREE command and of ORT's `CMAKE_ASM_MASM_FLAGS`.
  ✅ **DONE 2026-08-26 as a split, not a sweep — IREE on llvm-ml (arm64 run 23), MLAS stays on
  `ml64.exe` by measurement (amd64 run 6):** with `-DCMAKE_ASM_MASM_COMPILER=llvm-ml -m64` ORT's
  configure did report `Found assembler: …/llvm-ml.exe`, and then all four MLAS `.asm` kernels
  ninja reached failed on their **first line** — `.xlist` → `expected section directive before
  assembly directive` — followed by `INCLUDE mlasi.inc` → `Could not find include file` and ~6400
  cascaded errors. Root causes read from LLVM 22's `MasmParser.cpp` (release/22.x): it implements
  **no listing directives** (`.list`/`.xlist`/`.nolist` are absent from the directive map), and
  `INCLUDE` resolves through `SourceMgr.AddIncludeFile` with the `-I` dirs only — ml64 also
  searches the includer's directory, which is how `mlas/lib/amd64/*.asm` finds `mlasi.inc` without
  any `/I`. Behind that include sits the Windows SDK's MASM macro layer (`macamd64.inc`:
  `NESTED_ENTRY`, `rex_push_reg`, …). That is missing MASM coverage, not a flag, and rewriting ~40
  upstream kernels plus SDK includes is not this repo's job. Reverted in
  `build-onnx-from-source.ps1`: no ASM_MASM override on the native configure, the tee'd
  configure log now asserts **ml64** (a drift stops at configure, not 40 min into ninja), the
  reason sits beside the check. `Resolve-LlvmMasm`/`Get-LlvmMasmCmakeArg` stay in the module for
  IREE. AGENTS' assembler paragraph names the split. **amd64 run 7 (2026-08-26, `[bk] Done
  02:12:20`):** the configure log reports `The ASM_MASM compiler identification is MSVC … ml64.exe`,
  the ORT stage passes in 4:58 (sccache warm), arch gate 1134/0, smoke 222/0/0.

- **#124 — the target CPython cannot start on a clean Windows-on-ARM machine: `vcruntime140.dll`
  is staged into `DLLs\`, not beside `python.exe`.** S · ★★★ (opened 2026-08-25, consumer-side audit)
  `build-target-cpython.ps1:133-138` copies `python*.exe`/`python*.dll` to the root and every
  other DLL — the CRT included — into `DLLs\`. `python314.dll` imports `vcruntime140.dll` through
  the normal loader search (exe dir, System32, PATH); `DLLs\` is a *Python* search path, not a
  loader one. On a box with the ARM64 VC redist it works by accident; on a clean box the
  interpreter dies with 0xC0000135 before any Python runs. python.org's own layout keeps the CRT
  next to the exe. **Fix:** stage `vcruntime140.dll` (+ `msvcp140*.dll` when present) beside
  `python.exe`, keep the copy in `DLLs\` for the `.pyd`s, and extend the stage's self-check; the
  whole-tree import walk of #127 is what would have caught it.
  **DONE 2026-08-25 (arm64 run 14):** `build-target-cpython.ps1` stages the target-arch CRT set —
  `vcruntime140.dll`, `vcruntime140_threads.dll` (added after run 13's import walk), `msvcp140*.dll`,
  `concrt140.dll`, `vccorlib140.dll` — from the build output or the VS ARM64 redist, PE-checked,
  beside `python.exe` **and** into `C:\runtime\bin`; throws if `vcruntime140.dll` cannot be staged.
  Measured: `staged 9 CRT DLL(s)`; the #127 walk resolves every CRT import inside the bundle.

- **#125 — no `sitecustomize` for the TARGET interpreter: every first `import` of cv2/av/ORT on the
  device fails to find its DLLs.** S · ★★★ (opened 2026-08-25)
  `Initialize-PythonPlatformTag` writes the shim into the **host** tree only
  (`WindowsSourceBuild.Common.psm1`, `$CpythonDir\Lib\site-packages` = `C:\temp\cpython`); nothing
  writes one into `C:\runtime\python\Lib\site-packages`. Python ≥ 3.8 ignores `PATH` for
  extension-module dependencies, so `cv2.pyd → opencv_videoio500.dll → avcodec-63.dll` and
  `opencv_gapi → onnxruntime.dll` cannot resolve, and the PyAV wheel (49 `.pyd`, 0 bundled DLLs) is
  built on the same assumption (`build-ffmpeg-from-source.ps1` says its DLLs "resolve via the
  sitecustomize shim"). **Fix:** emit a second shim — DLL directories only, no `get_platform`
  override (the target reports `win-arm64` itself) — into the target site-packages at the
  target-cpython stage (arch-aware paths from the same table), and assert its presence in the
  merge.
  **DONE 2026-08-25 (arm64 run 14):** the shim writer is one function
  (`Write-PythonDllDirectoryShim`, used by `Initialize-PythonPlatformTag` for the host tree);
  `build-target-cpython.ps1` calls it for `C:\runtime\python\Lib\site-packages` with the arch-aware
  DLL homes and no platform/`EXT_SUFFIX` override, after emptying the target site-packages of the
  host tree's pip/setuptools. Measured in-stage: `wrote the DLL-directory sitecustomize shim for
  the target interpreter`.

- **#126 — no runtime deps and no pip for the target: numpy (ORT `import_array`, cv2), packaging,
  flatbuffers, protobuf, sympy, coloredlogs are absent; `C:\runtime\wheels` holds only our three
  wheels.** M · ★★★ (opened 2026-08-25)
  Every pip call in the chain runs the host interpreter; the cross wheel staging (`-CrossStage`) never resolves dependencies;
  no `pip download --platform win_arm64` exists anywhere. **Fix:** a `requirements-winarm64.txt`
  resolved on the host with `pip download --only-binary=:all: --platform win_arm64
  --python-version 3.14 -d C:\runtime\wheels` (pure wheels + the `win_arm64` numpy/protobuf —
  verify each pin publishes one for cp314 before relying on it), a bundle install note (`python
  -m ensurepip` works offline — `Lib\ensurepip\_bundled` ships with the stdlib copy; install ours
  with `--no-deps` so PyPI's `onnxruntime` never shadows the staged one), and a static gate that
  every `Requires-Dist` of the staged wheels resolves inside the wheel store.
  **Implemented 2026-08-25** as `windows/scripts/build/stage-target-python-deps.ps1`, a cross-only
  merge step before the arch gate: it reads `Requires-Dist` from every wheel in `C:\runtime\wheels`
  (extras dropped, numpy added for cv2), downloads with the HOST pip
  (`--only-binary=:all: --platform win_arm64 --python-version 3.14 --abi cp314/none/abi3`) only
  what the bundle does not provide itself, then gates that every wheel is pure or `win_arm64`
  (PE-checked) and that every requirement edge resolves inside the store. **Measured on arm64
  run 12:** the first `pip download` died on `onnxruntime-directml>=v1.29.0` ("from versions:
  none") — onnxruntime-genai's `setup.py.in` derives its ORT requirement from the package name
  (`onnxruntime-genai-directml` → `onnxruntime-directml`, `-cuda` → `onnxruntime-gpu`), but this
  bundle ships its combined CPU+DML(+CUDA) ORT wheel as plain `onnxruntime` (build-onnx passes no
  `--wheel_name_suffix` on purpose). Microsoft publishes no `win_arm64` `onnxruntime-directml`, and
  on amd64 the same edge makes a consumer's `pip install` pull a *second* onnxruntime over ours (the
  2026-07-13 DmlExecutionProvider loss that the build's `-NoDeps` only papers over). **Fix, both
  lanes:** `build-onnx-genai-from-source.ps1` rewrites the configured `build\wheel\setup.py`
  mapping to `dependency = "onnxruntime"` before packing (fail-loud when the pattern is gone), so
  the wheel declares `onnxruntime>=v1.29.0` — the package the store actually holds. numpy 2.5.2
  publishes a `cp314-win_arm64` wheel; flatbuffers, packaging, protobuf resolve as pure wheels.
  **DONE 2026-08-25 (arm64 run 14):** `store holds 7 wheel(s); 0 requirement edge(s) unresolved` —
  the three bundle wheels plus `numpy-2.5.2-cp314-cp314-win_arm64` (PE-checked),
  `flatbuffers-25.12.19`, `packaging-26.3`, `protobuf-7.36.0` (pure); pip itself comes from the
  target stdlib's `ensurepip\_bundled` (asserted in-stage). Install on the device with
  `python -m ensurepip` then `pip install --no-index --find-links C:\runtime\wheels <name>`.

- **#127 — whole-tree static import walk for the arm64 bundle.** M · ★★★ (opened 2026-08-25)
  Today `Get-UnresolvedDeps` runs for the four mandatory GStreamer plugins only; every other
  shipped `.dll/.exe/.pyd` and every wheel member gets a PE-machine check and nothing else. #124 is
  exactly the class that a dependency walk catches. **Fix:** run the same `dumpbin /dependents`
  (or `llvm-readobj --coff-imports`) walk over everything under `C:\runtime` plus extracted wheel
  members, resolving against the bundle and a Windows 11 ARM64 `System32` name list; report
  unresolved imports per file, floor on the file count, fail on any unresolved non-system import.
  **Implemented 2026-08-25** as `verify-target-arch.ps1 -ImportWalk` (merge arch gate, cross lane):
  a dependency-free PE import-table parser (`Get-PeImportNames`, import + delay-load directories,
  PE32/PE32+) walks every inspected PE plus the native members of every wheel and resolves each
  name against the bundle, the loader's `api-ms-`/`ext-ms-` API sets, this container's `System32`
  list (CRT family excluded from it on cross — a clean device has no redist), a driver/toolkit
  allowlist (`-ImportAllowlist`: nvcuda, vulkan-1, opengl32, d3d12core, Qnn*) and a **client-OS
  list** (`-ClientOsPattern`: `dsound`, `mf`/`mfplat`/`mfreadwrite`/`mfcore`, `winspool.drv` —
  DLLs every Windows client SKU ships but the Server Core reference does not). **Measured, arm64
  run 13 — the first walk over 567 files found 13 unresolved imports in three classes, all real:**
  (1) 6× `libcrypto-4-arm64.dll`/`libssl-4-arm64.dll` from `gsthls`/`gstdtls`/`gstaes` and gio's
  openssl TLS module — linked against `C:\opt\openssl-arm64`'s import libs, but the DLLs were never
  installed (amd64 gets scoop's x64 OpenSSL from the image PATH, which a bundle cannot rely on);
  fix: the GStreamer cross branch now stages them, PE-checked, into `C:\runtime\bin`. (2) 6×
  client-OS names (`DSOUND.dll` ← gstdirectsound*, `MF.dll`/`MFPlat`/`MFReadWrite` ←
  gstmediafoundation, `WINSPOOL.DRV` ← tcl9tk90.dll) — present on the device, absent on Server
  Core; classified, reported, not counted. (3) 1× `VCRUNTIME140_THREADS.dll` ← LiteRT's
  `tensorflowlite_c.dll` — the one CRT member missing from #124's staging list; added.
  **DONE 2026-08-25 (arm64 run 14):** `inspected 970, violations 0; import walk: 571 file(s)
  walked, 0 unresolved import(s), 3 allowlisted external(s), 6 device-OS (client SKU) import(s)` —
  the walk is a hard merge gate on the cross lane (`Dockerfile.media-merge-builder`, `-ImportWalk`).
  On the native lane the same walk runs **report-only** (measured amd64 run 4: 203 edges, all image
  facts — 186× `python314.dll` + 8× `python3.dll` because the host interpreter lives in
  `C:\temp\cpython\PCbuild\amd64`, outside the roots, and 6× scoop's `libcrypto/libssl-4-x64.dll`
  from the image PATH); the first native run threw on them and failed the amd64 regression, so the
  throw is now cross-only and the report groups edges by DLL name first.

- **#128 — GStreamer arm64 lacked `webrtc`/`nice`.** M · ★★ (opened 2026-08-25 from a lane log
  diff) · ✅ **DONE 2026-08-26 (arm64 run 28, `[bk] Done 00:29:32`; amd64 run 7 the same day).**
  Five layers, each measured: no build-machine C compiler in the cross file (→ a meson **native
  file**), the build machine linking the TARGET CRT (→ `/vctoolsdir` + `/winsdkdir`, because a
  path-shaped `/LIBPATH:` is read as an input FILE by the clang-cl driver), the build machine's
  `cl`/`ml64` coming from PATH which leads with `bin\HostX64\ARM64` (→ named explicitly in
  `[binaries]`), and **three meson 1.12.0 defects around build-only subprojects** — a failed
  `native: true` subproject is recorded under the HOST key and overwrites the healthy host holder
  (the actual poison behind libnice's by-name lookup), its `configure_file` outputs land in the
  host's build dir, and its `summary()` collides. The first two are patched before `meson setup`
  (`Invoke-MesonBuildSubprojectPatch`); the third is left to fail glib(build) cleanly, since
  nothing consumes it — only meson's gnome module ever asks for it.
  **Result:** `gstwebrtc.dll` + `gstnice.dll` on both lanes, `All 6 mandatory GStreamer plugins
  verified present`, arch gate 980/0, walk 577/0, smoke 97/0/15 (amd64: 1134/0, 222/0/0).
  Upstream draft for all three meson defects: `out/upstream-issue-meson-summary-build-subproject.md`
  (not filed — owner's call). Two side fixes the runs forced: a failed `meson setup` logs a
  numbered EXCERPT instead of 400k–800k lines (30–60 min per failure before), and the retry
  classifier scans stdout + the log tail with word-bounded signatures (an SDK constant
  `…_SSLERRORS_ONCE` had turned a deterministic failure into a "transient" retry). Run-by-run
  record: [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md).
- **#129 — OpenCV arm64 ships zero dispatched NEON kernels.** M · ★★ (opened 2026-08-25)
  The arm64 configure log (run of 2026-08-24 20:50) prints `Baseline: NEON` and an **empty**
  `Dispatched code generation:` — `HAVE_CPU_NEON_FP16_SUPPORT / _DOTPROD_ / _BF16_ - Failed`,
  "NEON_FP16 is not supported by C++ compiler": OpenCV's feature probe hands clang-cl GCC-style
  flags it rejects. amd64 gets `SSE4_1 SSE4_2 AVX FP16 AVX2 AVX512_SKX`. Same failure class as the
  MLAS/XNNPACK/IREE per-TU fixes, degrading silently (fp16/dotprod paths fall back to baseline
  NEON + carotene). **Fix:** on cross pass `CPU_DISPATCH=NEON_FP16;NEON_DOTPROD;NEON_BF16` with the
  `/clang:-march=armv8.2-a+…` spellings (OpenCV's `OPENCV_CPU_*` flag overrides or an inline patch
  of `OpenCVCompilerOptimizations.cmake`) and **gate on a non-empty dispatch line**.
  **Implemented 2026-08-25, proof pending arm64 run 20:** no source patch needed — upstream sets
  the per-feature flag variables with `ocv_update` (set-if-unset) and its `if(MSVC)` branch blanks
  them to `""` under clang-cl, so three cache definitions on the cross configure win:
  `-DCPU_NEON_FP16_FLAGS_ON=/clang:-march=armv8.2-a+fp16` (+ `_DOTPROD_`, `_BF16_`); the
  dispatch SET stays upstream's AArch64 default (`NEON_FP16;NEON_BF16;NEON_DOTPROD`). The gate
  parses `opencv-configure.log`: an empty `Dispatched code generation:` line fails BOTH lanes, and
  the cross lane must additionally list `NEON_FP16`.
  ✅ **DONE 2026-08-25 (arm64 run 22).** The flags alone were not enough: runs 20/21 dispatched
  `NEON_BF16` only (0 files), and the gate's `CMakeError.log` excerpt showed why — the probes
  `cmake/checks/cpu_neon_fp16.cpp` / `cpu_neon_dotprod.cpp` compile only under `__GNUC__ &&
  (__arm__ || __aarch64__)`; the `_MSC_VER && _M_ARM64` alternative is commented out upstream
  (opencv/opencv#25052: MSVC's `arm_neon.h`), so under clang-cl every probe ended in `#error "... is
  not supported"` whatever the flags. clang-cl ships clang's own `arm_neon.h`, so the cross branch
  now patches the probes to also accept `__clang__ && _M_ARM64` (search over `cmake/checks`, floor
  2 files). Result: `Dispatched code generation: NEON_DOTPROD NEON_FP16 NEON_BF16`, the OpenCV stage
  green in 4:54 with the dispatched kernels compiled. Still baseline-only: the scalar `FP16` probe
  (`cpu_fp16.cpp`, a different guard shape) — the fp16 conversions ride the NEON_FP16 dispatch.

- **#130 — bundle contract and small consumer-facing gaps.** S · ★ (opened 2026-08-25)
  (a) No file in the bundle names its own layout: all pointers are Dockerfile ENV of a
  windows/amd64 image, `PATH`'s python is the host x64 one, `C:\runtime\python` appears in no ENV —
  emit `C:\runtime\BUNDLE-ENV.cmd/.ps1` from the same table plus a bundle README. (b) GIO module
  cache absent (`gio-querymodules` skipped under DESTDIR) — document the one-time on-device run.
  (c) `Assert-WheelTargetArch` logs only a member *count* — log the names, so it is known whether
  the GenAI wheel embeds `onnxruntime.dll`. (d) Stale labels/comments: `windows\Dockerfile` LABEL
  and header still call TVM/IREE/LiteRT "empty markers on arm64", the merge Dockerfile says the
  arm64 site-packages "wait on #120", `WindowsGstPlugins.Common.psm1` says LiteRT "cannot be built
  for Windows-on-ARM", `healthcheck.ps1` says the arm64 contract drops tflite.
  **Implemented 2026-08-25, proof pending arm64 run 20:** (a)+(b) `write-bundle-manifest.ps1`
  runs in the merge stage on both lanes and writes `C:\runtime\BUNDLE-ENV.cmd`, `BUNDLE-ENV.ps1`
  (every existing DLL home from the merge ENV plus `C:\runtime\bin`, the target python and the
  wheel store) and `BUNDLE-README.md` (the arch facts, the `--no-index --find-links` install
  line, the one-time `gio-querymodules` run on a device, the plugin contract, and every
  `ABSENT-ON-*` / `COMPILER-ABSENT-*` marker in the branches' own words); (c)
  `Assert-WheelTargetArch` now logs the native member NAMES; (d) all four stale texts rewritten
  (the final Dockerfile header + LABEL, the merge fan-in comment, the plugin module header, the
  healthcheck fallback comment).
  ✅ **DONE 2026-08-26 (arm64 run 28).** In-container proof: `Bundle manifest (arm64): 6 DLL
  home(s), python=C:\runtime\python, 3 wheel(s), 3 absent marker(s), plugins [libav opencv onnx
  webrtc nice tflite] -> C:\runtime\BUNDLE-ENV.cmd, BUNDLE-ENV.ps1, BUNDLE-README.md`, followed by
  the deps store (7/0), the arch gate (980/0, walk 577/0) and the smoke gate (97/0/15) over the
  same tree. amd64 side (run 7, 2026-08-26): `Bundle manifest (amd64): 6 DLL home(s), python=image
  CPython, 6 wheel(s), 0 absent marker(s), plugins [libav opencv onnx webrtc nice tflite]`.

- **#131 — post-cross-phase cleanup (refactoring).** M · ★★ (opened 2026-08-25, owner's request) ·
  ✅ **DONE 2026-08-25 in four waves, developed in an isolated worktree, 662/662 tests, proof = the
  bundled both-lane ride.** Deletions first, then shared helpers with fixture tests, then the
  call-site migration. The ride is the lesson this repo keeps quoting: the worktree passed every
  host test and the parse gate, and the arm64 run still found three defects the host suites
  structurally could not see (`-Path$x` binding as a parameter named `Path$x`, a null-restore
  leaving `LIB=` defined-empty, a helper leaking its pipeline into the return value). Narrative:
  [`windows-backlog-archive-2026-08-26.md`](windows-backlog-archive-2026-08-26.md).
- **#132 — Windows Update inside the build container poisons a layer.** S · ★★★ (opened and
  **DONE 2026-08-25**, measured on the amd64 regression after #131)
  The `media-core-onnx` stage finished its 150 s RUN and then died in finalize, byte-identical on
  both retries: `failed to reimport snapshot: Files/Windows/SoftwareDistribution/Download/<id>/
  Windows11.0-KB5120233-x64.msu: unknown stream ID 9`. servercore ships `wuauserv` and the Update
  Orchestrator (`UsoSvc`), both trigger-started; the container has network; the client downloaded a
  cumulative update into the spool during the RUN, and BuildKit's Windows layer writer cannot carry
  that file's alternate stream. Retries cannot help — the RUN result is cached, only the finalize
  re-runs. **Fix:** `Disable-ContainerWindowsUpdate` (`WindowsSourceBuild.Common.psm1`) stops and
  disables both services and sets `NoAutoUpdate=1` as the first step of every build script
  (`Initialize-SourceBuildEnvironment`) and reports the spool count — an entry inherited from the
  parent image (1 item at RUN start on every media stage) is harmless, only a file written during
  the RUN lands in the diff. Deliberately prevention only: no script deletes under `C:\Windows`
  (protected-root rule); a poisoned layer is fixed by re-running its RUN with the guard in place
  (the module edit re-keys it). **Proven on the amd64 regression run 4:** the same
  `media-core-onnx` RUN finalized in 5:32 with the guard active at 4.7 s.
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
  Dockerfiles, not against memory — see the correction below) · NOT STARTED
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
> addendum. Sanity-check the GC deploy with `buildctl debug workers -v`
> (reservedSpace must read 200GB).

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
