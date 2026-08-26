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

- **#116 — TVM + IREE on arm64.** XL · ★ · ✅ **DONE 2026-08-24/25 as RUNTIME-ONLY** (tvm_runtime + IREE target tools/libs in the bundle, compilers named `COMPILER-ABSENT-ON-ARM64`; proven arm64 runs 11–19 — the measured findings are the body below)
  Lowest priority: highest cost, narrowest benefit, medium confidence. First, a retraction: an
  earlier note claimed TVM's "codegen cannot emit aarch64 … not fixable in this repository" — false
  since it was written, because `LLVM_TARGETS_TO_BUILD=X86;NVPTX` is set **by this repo** in
  `build-tvm-from-source.ps1`, in an array the script fully controls. **Phase 0 is worth doing on
  its own merits and is amd64-only:** adding `AArch64` to that list is a one-token edit that
  lets the **x64** image's TVM emit aarch64 code (`tvm.build(target='llvm -mtriple=aarch64-…')`) for
  one extra LLVM target of build time. It does **not** unblock the arm64 branch — do not conflate
  the two. The **real** remaining cross cost is that `USE_LLVM=<path>` must *execute*
  `llvm-config.exe`, which an x64 host cannot do against a target-arch LLVM — the cross lane needs a
  host-tools/target-libs split of the minimal-LLVM build. **IREE rides this same dropped branch and
  must be named wherever the absent branches are listed** (it was a silent casualty of TVM-only
  phrasings); upstream already supports the split there via `IREE_HOST_BIN_DIR`. Everything past
  Phase 0 (cross-capable minimal LLVM, IREE's in-tree LLVM and its host tools) is genuinely large.
  **Phase 0 DONE 2026-08-24, measured:** the amd64 full regression (media all-branches + merge +
  final + smoke) built TVM's LLVM with `LLVM_TARGETS_TO_BUILD=X86;AArch64;NVPTX` and passed —
  `media-tvm-built` green in 21:17 (sccache carried the LLVM rebuild; 9110 compile requests,
  8388/8389 targets incl. IREE), then arch gate 1134/0 and smoke 220/0/0. The x64 image's TVM
  can now emit aarch64 code.
  **Runtime-only cross IMPLEMENTED 2026-08-24 evening (the scope that needs no host-tools split
  for TVM at all, and only upstream's documented one for IREE):** the arm64 bundle ships
  `tvm_runtime.dll` + `tvm_ffi.dll` (+ import libs, headers) and IREE's runtime tools/libs; the
  compilers and python packages stay amd64-only and are named ABSENT in `COMPILER-ABSENT-ON-ARM64.txt`.
  Mechanics: TVM configures `USE_LLVM=OFF`, python OFF, builds `ninja tvm_runtime` alone (a
  `-Targets` parameter on `Invoke-NinjaBuildWithRetry`, so `tvm_compiler` never builds) and stages
  by hand with an in-stage PE gate; IREE configures the same tree twice — a native runtime-only
  host build installed to `build-host\install` (asserted to hold `iree-flatcc-cli.exe` +
  `iree-c-embed-data.exe` (IREE 3.x's name; the pre-rename `generate_embed_data` was asserted first and run 5 caught it)), then the target configure with `IREE_HOST_BIN_DIR`,
  `IREE_BUILD_COMPILER=OFF`, python OFF — with a static PE gate replacing the compile+run gate.
  `media-tvm` left `$crossBlockedBranches` (the driver-level refusal list, removed altogether on 2026-08-25 in #131 once empty), all three branches are
  merge-required on both lanes, and the `media-branch-absent` stand-in stage is retired. Full
  description in `docs/windows-cross-builds.md` § "TVM and IREE cross-build runtime-only".
  **Measured on the way (arm64 runs 3–4):** (1) TVM runtime cross-builds in under a minute — 4
  runtime binaries, all `0xAA64` — but the header copy hit 0.26's layout: `dmlc-core` is gone and
  `dlpack` lives inside the `tvm-ffi` submodule's own `3rdparty`; the copy is now layout-searched
  and asserts `tvm\runtime\c_backend_api.h`, `tvm\runtime\device_api.h`, `tvm\ffi\c_api.h`,
  `dlpack\dlpack.h` landed (the first anchor tried, `c_runtime_api.h`, is itself gone with the
  FFI split — run 4 caught that, which is what the assert is for). (2) The
  IREE host pass died in its first try-compile: `msvcrtd.lib(exe_main.obj): machine type arm64
  conflicts with x64` — VsDevCmd `-arch=arm64` leaves `LIB` on the ARM64 CRT and lld-link reads
  only `LIB` (CMake calls it directly, no clang-driver auto-detection). Exactly the "necessary but
  not sufficient" the choke point's comment warned about. `Invoke-WithHostArchLibraryEnvironment`
  now rewrites the arch segment of every `LIB`/`LIBPATH` entry (`\arm64` → `\x64`) for the duration
  of the host pass and restores it (`SourceBuild.HostArchLibEnv.Tests.ps1`), without re-entering
  VsDevCmd (a second invocation appends rather than resets). (3) With the host tools built, the
  target ninja died on `'build-host/install/bin/iree-flatcc-cli', needed by '…/dummy_reader.h',
  missing and no known rule to make it` — IREE composes `${IREE_HOST_BIN_DIR}/<tool>` **without the
  `.exe` suffix** (Linux-shaped), and ninja wants that exact file as a dependency. An **upstream
  gap for Windows hosts** (draft: `out/upstream-issue-iree-host-bin-dir-exe.md`); the script stages a
  suffix-less twin of each host tool next to the `.exe` — ninja sees the file, `CreateProcess`
  appends `.exe` when launching an extension-less full path, same bytes either way. Also caught on
  the way: the host tool is `iree-c-embed-data.exe` in IREE 3.x, not the pre-rename
  `generate_embed_data`. (4) With the host tools resolved, the **target** build reached IREE's
  arm_64 ukernels and died the MLAS/XNNPACK way: `always_inline function 'vfmaq_f16' requires
  target feature 'fullfp16'` — upstream hands each feature kernel its `-march=armv8.2-a+<feat>`
  through `iree_select_compiler_opts(CLANG_OR_GCC …)`, and clang-cl is classified as MSVC there,
  so the flags are dropped; plus bare `asm(...)` (GNU keyword, off under MS compat) in
  `mmt4d_arm_64_fp16fml.c`. Same remedy, same discipline as the other two: post-configure
  per-TU tagging of `build.ninja` (`/clang:-march=armv8.2-a+{fp16,fp16fml,bf16,dotprod,i8mm}`
  on the five feature kernels, floor **5** — the pre-fix state tags 0 — and `-Dasm=__asm__` on
  every arm_64 ukernel TU). (5) Past the ukernels, `iree_hal_local_elf_arch.lib` failed to
  archive: `x86_64_msvc.obj: file machine type x64 conflicts with library machine type arm64` —
  **upstream bug**, `hal/local/elf/CMakeLists.txt` adds the x86-64 MASM trampoline whenever
  `MSVC_C_ARCHITECTURE_ID MATCHES 64`, and `ARM64` matches `64` (draft:
  `out/upstream-issue-iree-elf-arch-arm64-msvc.md`). Inline-patched to an exact x64 match on both
  lanes (on amd64 the id is `x64`; nothing changes there), verified post-patch. (6) With that,
  the **entire ARM64 runtime compiled** (608/659) and the tools failed only to *link*:
  `undefined symbol: iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm`. Checked file by file:
  it is upstream's one non-static C `inline` definition in the arm_64 kernel set, and the entry
  point takes its address — under C99 inline semantics (clang's default in C mode) an `inline`
  definition without `extern` emits no external symbol. Per-TU `/clang:-fgnu89-inline` was tried
  first (run 10) and did **not** produce the symbol under clang-cl, so the definition itself is
  inline-patched to a plain `void …(` — `inline` buys nothing for a function used by address;
  verified after applying, inert on amd64 (the arm_64 dir is not compiled there). How upstream's
  own Linux/clang builds link this is not verified here; flagged as a question, not asserted.
  ✅ **DONE 2026-08-24 evening, measured (arm64 run 11):** `media-tvm-built` green in 7:59 —
  TVM runtime 4 binaries, IREE 14 target binaries under `bin\`, every one PE `0xAA64` in-stage;
  merge 34:50 with the arch gate at **950 inspected / 0 violations** (up from 931: the TVM/IREE
  runtimes are now in the bundle); final + smoke **97/0/15**. Runtime-only is the shipped scope;
  the compilers and python packages stay amd64-only and are named ABSENT in
  `COMPILER-ABSENT-ON-ARM64.txt`. Execution proof, as for everything on this lane, is owed to a
  native host.

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

- **#128 — GStreamer arm64 lacks `webrtc`/`nice` and `gst-ptp-helper`; two lane-identical Meson
  bugs found on the way.** M · ★★ (opened 2026-08-25, from a log diff of the two merge stages)
  Measured (amd64 `bk-…-merge…` vs arm64 run 11): plugin lists identical except **`webrtc` only on
  amd64** (104 vs 105 in gst-plugins-bad), `gstwebrtcnice-1.0-0.dll` + libnice + gst-examples only
  on amd64. Cause: the cross file defines host `[binaries]` only, meson finds no **build-machine**
  C compiler (`Compiler for language c for the build machine not found`, 93×), the build-machine
  glib fallback dies, and libnice's by-name `subprojects/glib` lookup then fails although the host
  glib configured fine (`glib-2.0 for host machine found: YES 2.86.3 (overridden)`).
  `gst-ptp-helper` is Rust and has no `rustc --target=aarch64-pc-windows-msvc` in the cross file.
  **Fix:** a native file with the x64 compilers for the build machine (and the rust target), then
  add `nice`/`webrtc` to the plugin contract or a lane plugin-inventory diff gate. **Both lanes,
  not parity:** `-Dcairo:win32=disabled` and `-Dgst-devtools:dots-viewer=disabled` are *unknown
  options* in these versions and disable cairo, pango and gst-devtools everywhere; amd64 builds
  562 glib **test** targets (`tests: true`) that ship nothing.
  **Implemented 2026-08-25, proof pending arm64 run 20 + the next amd64 regression:** (1) the
  cross branch now also writes a meson **native file** (`meson-native-amd64.ini`: the same
  clang-cl/llvm-lib/llvm-rc without `--target`, i.e. what amd64 runs) so the build machine has a
  C compiler; (2) **rust for the target** is probed, not assumed — `rustup target add
  aarch64-pc-windows-msvc` (idempotent, the container has network) then a one-line staticlib
  compile; only a passing probe puts `rust = [rustc, --target=…]` into the cross file (a declared
  but broken rust compiler fails meson setup, an absent one merely skips `gst-ptp-helper`, and
  either outcome is logged); (3) `webrtc` and `nice` joined the plugin contract on BOTH lanes as
  `Detection = 'meson'` entries carrying their meson option (`gst-plugins-bad:webrtc`,
  `libnice:gstreamer`), which the build passes as `=enabled` and the DLL + gst-inspect gate proves
  like every other entry; (4) `-Dglib:tests=false`. **Correction to the finding above:** the two
  "unknown options" are deliberate — `-Dcairo:win32=disabled` is the documented way to keep cairo
  (and so pango) out because its win32 backend crashes LLVM 22's clang-cl (`mmintrin.h
  __builtin_shufflevector`), and `-Dgst-devtools:dots-viewer=disabled` keeps a Rust dev tool whose
  crates.io fetch fails offline out; both stay as they are, now with that reason recorded here.
  **Measured on arm64 run 23:** (a) the native file alone was not enough — meson detected the
  build-machine `clang-cl`, but its sanity check LINKED against the target's CRT (`msvcrt.lib
  (exe_main.obj): machine type arm64 conflicts with x64`; the RUN's `LIB` names `lib\arm64` /
  `um\arm64` and lld-link reads only `LIB`), so the build-machine C compiler stayed "not found",
  glib's build-machine configure died, and that failure poisoned the by-name `glib` lookup that
  libnice's anonymous `dependency('', fallback: ['glib', …])` needs (the gio-2.0 lookup works via
  override, the anonymous one cannot). First fix attempt (run 24): `[built-in options]
  c_link_args = ['/LIBPATH:<x64 dir>', …]` in the native file — **measured wrong**: meson hands
  the build machine's link args to the clang-cl DRIVER also *before* `/link` (the sanity check
  command carries them twice), and clang-cl reads a path-shaped `/LIBPATH:C:/…` there as an input
  file (`no such file or directory`) — `/LIBPATH` can never ride `c_link_args` with clang-cl.
  Fix: `c_link_args/cpp_link_args = ['/vctoolsdir:<VC\Tools\MSVC\<ver>>', '/winsdkdir:<Windows
  Kits\10>', '/winsdkversion:<ver>']` — options BOTH the driver and lld-link understand; lld-link
  adds their `lib\<machine>` dirs to the search path AHEAD of the `LIB` entries and picks the arch
  from `/machine:`, so the build machine links x64 while the host (arm64) compiles of the same meson
  run keep `LIB` as it is. Both roots are derived from the RUN's `LIB` entries, not assumed. (b) The
  rust probe failed as
  designed and stayed out of the cross file: `rustup target add aarch64-pc-windows-msvc` pulls from
  the image's OFFLINE dist mirror (`file:///…/rustup-dist/…`), which carries the x64 std only —
  `gst-ptp-helper` stays absent on arm64 until the base image preseeds the aarch64 `rust-std`
  (a base rebuild; owner's call).
  **Measured on arm64 run 25 (2026-08-26):** `/vctoolsdir`+`/winsdkdir` work — every subproject
  logs `C compiler for the build machine: clang-cl (clang-cl 22.1.8)` / `C linker … lld-link`, the
  C and C++ sanity checks link x64, and glib's build-machine configure runs to its LAST statement.
  There it dies on a **meson bug**, not a toolchain one: `glib-2.86.3/meson.build:2777:0:
  Exception: Summary section 'Build environment' already have key 'host cpu'`. meson 1.12.0 (and
  `master`, checked the same day) keys `Interpreter.summary` by subproject **name** and shares it
  across nested interpreters, while `Interpreter.subprojects` is keyed `[machine][name]` — so the
  build-machine run of a subproject that the host already configured re-adds the same summary keys
  and throws; `_print_summary` would then `KeyError` on a build-only name anyway. Meson marks
  glib(build) `buildable: NO`, the same by-name libnice lookup fails as in run 23, and webrtc/nice
  take gst-plugins-bad down (`gst-libs/gst/webrtc/nice/meson.build:16:14: ERROR: Subproject
  "subprojects/libnice" required but not found`). **Fix:** `Invoke-MesonBuildSubprojectSummaryPatch`
  (defined in `build-gstreamer-from-source.ps1` — deliberately NOT in a module: `/bkmods` is
  bind-mounted whole into all six media RUNs, so a one-line module edit re-keys every branch on
  both lanes, while the gst script is mounted into the merge RUN only) rewrites the pip-installed
  `mesonbuild/interpreter/interpreter.py` before
  `meson setup` — `summary_impl` returns early when `self.build.for_machine is MachineChoice.BUILD`
  (set only by `Build.copy_for_build_machine()` for `native: true` subprojects; summaries are
  cosmetic; non-cross lanes never create such an interpreter, so amd64 is untouched). Located via
  `python -c "import mesonbuild.interpreter.interpreter as m; print(m.__file__)"`, idempotent by
  marker, throws on layout drift (load-bearing on the cross lane). Fixture test
  `SourceBuild.MesonSummaryPatch.Tests.ps1` pins the 1.12.0 layout + indentation; upstream draft
  `out/upstream-issue-meson-summary-build-subproject.md` (not filed — owner's call). Proof: run 26.
  Side fix from the same run: a failed `meson setup` used to stream the whole `meson-log.txt`
  through `log` — 425k lines on runs 23/24, 800k+ on run 25, i.e. 30–60 min per failed attempt,
  longer than the configure itself. `Select-MesonLogExcerpt` (gst script, fixture-tested) now
  logs the diagnostic lines with numbers (ERROR/Exception/"required but not found"/"conflicts
  with"/"buildable: NO"), the block after each "Sanity check" header, and the last 300 lines;
  the full file stays in the preserved container and the retry classification still scans it all
  for the hard error. Second side fix, same run: the transient-vs-deterministic classifier
  matched `SSLError` case-insensitively and without word boundaries, and the SDK constant
  `BINDINFO_OPTIONS_IGNORE_SSLERRORS_ONCE` (urlmon.h, inlined from a probe source into
  meson-log.txt) turned run 25's deterministic failure into a "transient" retry — full wrap
  re-download, identical failure, second dump, ~1 h for nothing. `Get-MesonSetupFailureClass`
  (gst script, fixture-tested against exactly that line and the two measured real network
  shapes) now scans meson's stdout plus only the log's last 400 lines for network signatures,
  with `\b` around the exception names; a fatal download error always ends the log.
  **Measured on arm64 run 26 (2026-08-26):** the meson patch holds — `Patched meson
  build-subproject summary fix` at 15 s, glib(build) configures (gstreamer core 219 targets vs
  124 on run 25; glib 198), libnice passes its lines 214–219 with warnings only, `meson setup
  completed` at 550 s with 5772 ninja targets. The compile then died at target 694 in the
  **build-machine libffi**: the libffi meson port preprocesses `x86_win64_intel.S` with `cl /EP`
  and assembles with `ml64`, both `find_program`'d, and on the build-machine subproject both
  resolved through PATH — which under `VsDevCmd -arch=arm64` leads with `bin\HostX64\ARM64`. An
  ARM64-targeting `cl.exe` defines `_M_ARM64`, `ffitarget.h` never enters its `X86_WIN64`
  branch, and ml64 stops on `A2006: undefined symbol : FFI_TYPE_SMALL_STRUCT_4B` (the host
  libffi is fine: it wants the ARM64 cl + `armasm64`). Fix: the native file's `[binaries]` now
  names `cl` and `ml64` explicitly as `<VC tools root>/bin/HostX64/x64/…` (meson consults the
  machine file before PATH); `Resolve-BuildMachineMsvcTool` (gst script, fixture-tested) throws
  when the x64 pair is missing instead of failing 40 min later in ninja.
  **Measured on arm64 run 27 (2026-08-26):** cl/ml64 resolved from the native file, libffi(build)
  fine — and the build-machine **glib** compile died next: `'glibconfig.h' file not found` for
  every `build.subprojects/glib-2.86.3/glib/*.obj`. Third meson bug of the family: targets and
  include dirs of a build-only subproject live under `build.<subdir>` (`BuildProject.prefix`),
  but `configure_file` writes to the unprefixed `self.subdir` — the build machine's
  `glibconfig.h`/`config.h`/`fficonfig.h` land in, and overwrite, the **host** subproject's build
  dir. Reading meson for that surfaced the actual poison behind run 25 too: `do_subproject`'s
  failure paths call `disabled_subproject(subp_name, exception=e)` **without `for_machine`**
  (default HOST), so a failed glib(build) overwrote the healthy host glib holder — hence
  libnice's by-name failure and the 30+ re-configures. And nothing ever *needs* a build-machine
  glib: the only requester is meson's gnome module (`mkenums_simple` → `find_tool` →
  `dependency('glib-2.0', native: true, required: false)`), which falls through to the host
  override (python scripts) when it is absent. **Strategy change:** the summary patch is
  withdrawn (a glib(build) that configures is one that compiles, into meson's unprefixed
  `current_build_dir()` next); `Invoke-MesonBuildSubprojectPatch` now applies two fixes —
  `for_machine=for_machine` at both `disabled_subproject` failure sites, and the project prefix on
  `configure_file`'s output path + returned File — so glib(build) still fails at the summary bug,
  is recorded under BUILD only, clobbers nothing, and libnice/webrtc configure against the host
  glib. Fixture test `SourceBuild.MesonBuildSubprojectPatch.Tests.ps1` (5 tests). Proof: run 28.
  ✅ **DONE 2026-08-26 (arm64 run 28, `[bk] Done in 00:29:32`).** glib(build) attempted exactly
  **once** per configure (run 25: 30+), `required but not found`: **0**, libnice's anonymous host
  fallback `found: YES 2.86.3`, libnice 340 targets, gst-plugins-bad 603; the plugin gate passed
  **all six** contract entries — `gstwebrtc.dll` and `gstnice.dll` with `gst_plugin_*_get_desc`
  exported and their imports resolving — `All 6 mandatory GStreamer plugins verified present`;
  arch gate `980 inspected, 0 violations` (run 19: 970 — the ten new PEs are libnice and the two
  plugins), import walk `577 walked, 0 unresolved` (571), deps 7/0, smoke 97/0/15. **Plugin
  inventory diff (ninja "Linking target" DLLs, run 28 vs amd64 run 7): 200 = 200, no name on
  one side only.** `gdkpixbuf` is absent on BOTH lanes — arm64 for `glib-compile-resources` (a
  build-machine glib C tool), amd64 for a missing `rst2man` — so it is not a lane difference.
  (`gst-ptp-helper`: first recorded here as "linked on neither lane" — wrong, a grep for "Linking
  target" misses Rust links; amd64 run 7 installs `gst-ptp-helper.exe`, arm64 got it on run 29
  via #133 (a). Corrected 2026-08-26.) **amd64 regression (run 7,
  2026-08-26, `[bk] Done 02:12:20`):** the same script and contract on the native lane — the meson
  patch applies and is inert (no build-only subprojects without a cross file), `meson setup
  completed` at 465 s, the gate loads all six plugins through `gst-inspect` (`webrtcbin`,
  `nicesrc`/`nicesink` among them), manifest 6 DLL homes / image CPython / 6 wheels / 0 absent,
  arch gate 1134/0 (unchanged), smoke **222/0/0** (220 before — the two new contract entries).

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
  bundled amd64 + arm64 regression that followed.** What landed: **helpers** `Add-NinjaPerTuFlags`
  (one per-TU tagging pass with floor + idempotency marker, replacing the MLAS/XNNPACK/IREE copies),
  `Assert-PeTargetMachine` / `Assert-DirectoryTargetArch` / `Assert-PythonExtensionTag` (the static
  PE gates, in the dependency-free arch module), `Write-AbsentOnCrossMarker` (one marker convention),
  `Get-PythonCMakeHintArgs` (the FindPython trio per prefix), `Invoke-HostToolCmakeBuild` (host
  target + host LIB + retry ladder — LiteRT's flatc pass gained the LIB swap and a persistent log),
  `Invoke-PythonWheelBuild -CrossStage` (ORT/GenAI/PyAV wheels through one call),
  `Invoke-InlineRegexPatch -SkipIfMatch/-AssertGone` (the six hand-rolled verify pairs),
  `Resolve-QnnSdk` / `Copy-QnnRuntime` (the QNN block, now fixture-tested with a fake SDK zip),
  `Invoke-OnnxDmlClangClPatch` moved into the Patches module (80 lines of embedded C++ out of the
  build script). **Deleted:** the dead `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags`, the
  false "no arm64 CPython" warning, the unreachable `$crossBlockedBranches` mechanism, the cpython
  script's private PE reader and the two inline reads in the smoke test, ~120 lines of HISTORY
  comments now pointing at the docs, the stale nvcc-launcher comment. **Structure:** named
  `Gpu/Cpu/Arm64` smoke-floor columns (the calibration test parses the new shape), `$onnxCross`
  resolved once at the top of the ORT script. **Tests added:** `SourceBuild.CrossHelpers`
  (tagging, marker, hints, target python fixture, patch guards, PE asserts), `SourceBuild.NinjaTargets`,
  `SourceBuild.Qnn`, `TargetArch.CrossArgs`, `TargetArch.PeInspection`; `FindPythonPrefix` rewritten
  against the helper; the test runner now prints the assertion message under a red `FAIL` line.
  Original findings, kept for the record: **duplication** — per-TU `build.ninja` FLAGS
  tagging with a floor exists three times (MLAS `build-onnx`, XNNPACK `build-litert`, IREE ukernels
  `build-iree`) → one `Add-NinjaPerTuFlags -NinjaFile -Select -Floor -Label` helper; static PE
  gates over directories/lists exist in tvm, iree, cv2, `Assert-WheelTargetArch`, cpython (a
  private `Get-StagedPeMachine` clone of `Get-PeFileMachine`) and two inline reads in the smoke
  test → `Assert-PeTargetMachine` / `Assert-DirectoryTargetArch` in the dependency-free arch
  module; ABSENT markers written three ways → `Write-AbsentOnCrossMarker`; `Invoke-InlineRegexPatch`
  + hand-rolled "verify gone or throw" pairs (six sites) → `-AssertGone`/`-SkipIfMatch`; the
  Python CMake hint trio composed three ways → `Get-PythonCMakeHintArgs -Prefix`; the cross
  wheel build/stage/assert shape (ORT, GenAI, hand-rolled PyAV) → `Invoke-PythonWheelBuild
  -CrossStage`; the host-tool pass (IREE with the LIB swap, LiteRT's flatc **without** it — safe
  today only because that script never enters VsDevCmd) → `Invoke-HostToolCmakeBuild`.
  **Dead/false:** `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags` have no callers (comment
  mentions only); `Get-SourceBuildPython`'s "no arm64 CPython is built on this lane" warning is
  now false and fires twice per green arm64 run (via `Get-TargetBuildPython`);
  `WindowsTargetArch.Common.psm1` claims the inline PE reads were removed — they were not;
  `$crossBlockedBranches = @()` is an unreachable mechanism contradicting the "ship your own marker"
  convention (drop it); the LiteRT-LM Bazel blocker paragraph lives in five places; 36-line
  HISTORY comments in the ORT/GenAI/OpenCV scripts restate `docs/windows-cross-builds.md`.
  **Hot spots:** `build-onnx-from-source.ps1` (811 lines: DML patch fn, QNN block, python args,
  MLAS tagging → move the DML patch into the Patches module and QNN into a `WindowsSourceBuild.Qnn`
  module with a fake-zip test); the IREE cross branch; the TVM cross branch; the positional
  three-column smoke floor table (→ named `Gpu/Cpu/Arm64` keys). **Test gaps:** `Get-PeFileMachine`,
  `Assert-WheelTargetArch`, `Get-TargetBuildPython`, `-Targets`, `Get-QnnSdkLibDirName`, the QNN
  block, the tagging helper, `Get-CMakeCrossArgs`' ASM pair — all cheaply fixture-testable
  (synthetic 0x46-byte PE header, fake `build.ninja`, fake SDK zip, stub ninja). **Order:** wave 0
  deletions → wave 1 helpers + fixture tests (no call-site change) → wave 2 call-site migration
  proven by one bundled amd64 + arm64 regression against today's recorded counts (MLAS 11/25,
  XNNPACK 569 + 335, IREE 5; gates 1134/0 and 950/0; smoke 220/0/0 and 97/0/15) → wave 3
  structural extractions.
  **Proof, after landing on `main` (2026-08-25):** amd64 regression run 5 green (`[bk] Done in
  02:01:31`, arch gate 1134/0, smoke 220/0/0, MLAS 11 through the new helper, 158 x86asm object
  lines, GenAI `setup.py` patch, Windows-Update guard in every RUN). The arm64 regression found
  two defects the worktree's 662 tests and the parse gate could not see, both fixed and pinned:
  (1) four `Get-PeFileMachine -Path$x` calls (no space — a parameter literally named `Path$x`;
  now the third AST lint trap, `Native.ArgQuoting.Tests.ps1`); (2) `Invoke-WithHostArchLibraryEnvironment`
  "restoring" a captured `$null` with `SetEnvironmentVariable` left `LIB=` defined-empty, so
  lld-link skipped its MSVC/SDK auto-detection in the one cross script that never enters VsDevCmd
  (LiteRT: "could not open 'kernel32.lib'" right after the host flatc pass; runs 16/17, probed
  with the env dump that now stays in the script) — `Remove-Item Env:` on a null snapshot, same
  fix applied to the LiteRT-LM snapshot restore, its bazel NDK unset and the agentic-loop sanitizer
  restore; pin `SourceBuild.HostArchLibEnv.Tests.ps1`, invariant (d) in
  `docs/windows-build-invariants.md`. Run 18 then passed LiteRT (XNNPACK 569 + 335, MLAS 25 through
  the helpers) and exposed (3): `Invoke-HostToolCmakeBuild` returned its block's whole pipeline
  output — every teed ninja line, path last — so IREE's `Join-Path $ireeHostBinDir $tool` died with
  "A drive with the name 'ninja' does not exist" (LiteRT never noticed: it `[void]`s the call).
  `| Out-Host` inside the helper keeps the lines in the log and off the pipeline; pin: the
  chatty-ninja case in `SourceBuild.NinjaTargets.Tests.ps1`. **arm64 run 19 is the proof** (`[bk]
  Done in 01:10:51`): MLAS 25, XNNPACK 569 + 335, IREE 15 + 5 through the helpers; OpenSSL 2
  runtime DLLs staged (deduplicated from 8 package copies); deps 7 wheels / 0 unresolved; arch gate
  970/0; import walk 571 / 0 unresolved / 3 external / 6 device-OS; smoke 97/0/15 — every number
  identical to the pre-refactor run 14. With amd64 run 5 (1134/0, 220/0/0) the refactor is proven
  on both lanes; the worktree is removed.

- **VERIFY RIDE — MOSTLY CLOSED 2026-08-24 by the amd64 full regression** (media all
  branches + merge + final + smoke: arch gate 1134/0, smoke 220/0/0, `[bk] Done`), **and
  re-confirmed by a second full amd64 regression the same night** (2026-08-25 01:2x, `[bk] Done in
  02:15:51`, arch gate 1134/0, smoke 220/0/0) after the evening's changes — the `Python_*`
  FindPython fix, #119 x86asm, the QNN off-path, the IREE inline patches, the `-Targets` and
  host-arch-LIB module additions. That ride
  covered, on the BuildKit lane, every risk surface the 2026-08-20/21 landings listed:
  ffmpeg/onnx trap-phase tables, litert-lm phases 5a-5e, the chain Invoke-stage shape
  (build-litert-all), Find-TensorRtZipIn newest-by-version (zip-less skip path), the checked-in
  cpython Directory.Build.props COPY, the unified SHELL guard lines, merge sccache ARG parity.
  **Still open, exactly one surface:** the **classic-lane smoke gate** (`build.ps1`, docker-run
  form with the directory mount) — only a classic ride proves it, and none has run since
  2026-08-21. Assert-Elevated at the host sites is exercised by host scripts, not by a ride.
  Follow-ups that were chained to this: re-measure the at-scale sccache hit rate (the 2026-08-24
  runs show warm hits on every rebuild — e.g. TVM's LLVM rebuild in 21 min), and the log
  forensics against the first fully-captured chain (details under Pending).
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
- **#133 — the three amd64-only components, re-verified 2026-08-26 (owner asked "are you sure?").**
  M–L · ★ (opened 2026-08-26, not started — owner's call). What the arm64 bundle names ABSENT is
  three things, and only one of them is a real upstream wall:
  (1) **LiteRT-LM** — the wall is the *active Bazel path* (no windows-arm64 config in `.bazelrc`,
  the x86_64-only `libGemmaModelConstraintProvider` prebuilt in the default Windows graph; upstream
  `v0.16.1` ships prebuilts for `windows_x86_64`, `linux_arm64`, `macos_arm64`, `android_arm64` —
  no `windows_arm64`, verified against the tree). It is NOT "not fixable downstream": upstream's
  own **CMake path** (root `CMakeLists.txt` + `CMakePresets.json` + `cmake/`, present at `v0.16.1`)
  carries `cmake/patches/stubs/gemma_model_constraint_provider.cc`, a no-op provider that prints
  "Gemma Constraint Provider is STUBBED/DISABLED" — i.e. upstream itself builds without the
  prebuilt at the price of grammar-constrained decoding. A cross-build of `litert_lm_main` for
  arm64 through that path (clang-cl, our LiteRT core from #115, WebGPU/dawn prebuilts absent →
  CPU only) is a **work item**, unproven, with the repo's retired CMake builder
  (`build-litert-lm-from-source.ps1`) as the starting point.
  (2) **TVM compiler + `tvm` python** — needs an LLVM built FOR aarch64-windows (cross-building
  LLVM with clang-cl is feasible, ~hours) plus a host `llvm-config`; the python package is pure
  python + DLLs, so a `win_arm64` wheel can be assembled on the host exactly like the ORT/av
  wheels (#120) — the ABSENT marker's "needs the target interpreter" is imprecise: it needs the
  target's *link inputs*, which the aarch64 CPython provides. Not attempted; PyPI `apache-tvm`
  0.26.0 has `win_amd64` only (verified).
  (3) **IREE compiler + `iree.compiler` / `iree.runtime` python** — the compiler is LLVM/MLIR for
  the target (same cross-LLVM cost as (2), no upstream precedent for win_arm64: PyPI
  `iree-base-compiler`/`iree-base-runtime` 3.11.0 ship `win_amd64` only, verified); the *runtime*
  python package is a pybind extension against the runtime we already cross-build, so it is the
  #120 pattern again. Not attempted.
  Everything else in the bundle is at parity with amd64 (GStreamer plugin-DLL sets 200 = 200).
  The permanent walls stay: CUDA/cuDNN/TensorRT/NVENC (no Windows-on-ARM CUDA), the torch app
  stage (`uv sync` must run the target interpreter), and — orthogonal to all of this — no arm64
  binary has ever been *executed*; the `windows-11-arm` runner is the only path to that proof.
  **In progress 2026-08-26 ("solve them, as easy as possible"), smallest viable path per item:**
  (a) **Rust for the target** — the actual blocker under both `gst-ptp-helper` and LiteRT-LM:
  `Install-RustTargetStdFromPinnedManifest` (gst script) fetches the aarch64 `rust-std` tarball
  the image's *pinned* channel manifest already names (with upstream's sha256) from
  static.rust-lang.org into the `file:///…rustup-dist/…` path the manifest points at, so
  `rustup target add` verifies and installs it; proof = `gst-ptp-helper` on arm64 (run 29).
  ✅ **(a) DONE 2026-08-26 (arm64 run 29, `[bk] Done 01:24:55`):** `rust-std aarch64-pc-windows-msvc:
  fetched …/dist/2026-08-20/rust-std-1.98.0-aarch64-pc-windows-msvc.tar.xz (22 MB)` → `rustup:
  downloading component rust-std` (hash-verified against the pin) → `staticlib probe OK` → meson
  `Rust compiler for the host machine: rustc --target=aarch64-pc-windows-msvc -C linker=link` →
  `gst-ptp-helper.exe` compiled (5056 targets, 5051 before) and installed to
  `C:\runtime\libexec\gstreamer-1.0`; arch gate **981/0** (+1 = the helper), walk **578/0**,
  plugins 6/6, deps 7/0, smoke 97/0/15. amd64 had the helper all along (run 7 installs it) — both
  lanes now ship it. Rust for the target is thereby available to any later stage (LiteRT-LM).
  (b)/(c) did NOT run on run 29: the tvm branch starts from the media-core fan-in, not from the
  ONNX layer that builds the target CPython, so `Get-TargetBuildPython.Available` was false in
  both scripts — `build-media-tvm-all.ps1` now runs `build-target-cpython.ps1` first (~90 s, same
  contract as media-core; BK mounts + classic COPY carry it, parity test B6). Proof: run 30.
  **Run 30 (2026-08-26):** the target CPython now builds in the branch (91 s, `python.exe`
  0xAA64) and the wheel path switched on — then `ninja: unknown target 'tvm_ffi_cython'`:
  tvm-ffi's CMakeLists `return()`s as soon as it is a **subproject** ("only triggered when the
  project is the root"), so `TVM_FFI_BUILD_PYTHON_MODULE` on TVM's configure was never read
  (CMake: "Manually-specified variables were not used"). Fix: the cross python block configures
  `3rdparty/tvm-ffi` as its own root project (cross args from the choke point, `Python_*` hints,
  tests off), builds `tvm_ffi_cython`, and ships that build's `tvm_ffi.dll`/`.lib` beside
  `core.<target>.pyd`; TVM's own configure carries no python knobs again. Proof: run 31.
  (b) **IREE runtime python** — `iree.runtime` is a nanobind extension over the runtime the tvm
  branch already cross-builds: `IREE_BUILD_PYTHON_BINDINGS=ON` on the target configure with
  `Python3_*`+`Python_*` hints (host exe / neutral include / TARGET `python314.lib` / host-probed
  numpy headers), then the build tree's synthesized `runtime/setup.py bdist_wheel --plat-name
  win_arm64` via `Invoke-PythonWheelBuild -CrossStage` (staged + PE/name-checked). The compiler
  package stays ABSENT (proof: run 29). (c) **TVM runtime python** — next: TVM 0.26 supports a
  runtime-only mode natively (`_RUNTIME_ONLY` falls back when `tvm_compiler` is absent);
  `tvm_ffi`'s Cython `core` module cross-builds through the tvm-ffi CMake target
  (`TVM_FFI_BUILD_PYTHON_MODULE`, `python_add_library WITH_SOABI` → target EXT_SUFFIX), and both
  `apache-tvm-ffi` and `apache-tvm` wheels are assembled from the package sources + the cross-built
  binaries (scikit-build-core would rebuild the compiler and cannot tag win_arm64 from a host
  interpreter). (d) **LiteRT-LM** — stays a port, not a switch, after reading upstream `v0.16.1`:
  its CMake path is an ExternalProject orchestrator with a host prebuild phase, Unix-flavoured link
  flags plus an MSVC branch, and a Rust crate (`tokenizers`+`onig`, `llguidance`, `antlr4rust`,
  `minijinja`, `cxx`) that must be built for the target through corrosion; (a) is its
  prerequisite, the rest is days of iteration at ~1 h per attempt — deferred, not declared
  impossible. The compilers (TVM, IREE) stay out: a cross-built LLVM for aarch64-windows, no
  upstream precedent.

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
