<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows backlog archive — 2026-08-26

Resolved narratives moved out of `windows-refactor-backlog.md` per the
lean-OPEN-only policy (COUNTING NOTE there), on 2026-08-26 as part of the #134
cleanup wave. This tranche is the **run-by-run measurement record** of four
entries whose verdicts and final numbers stay in the live file:

| Entry | What it was | Where the verdict lives now |
| --- | --- | --- |
| **#116** | TVM/IREE on the cross lane — runtime-only, compilers ABSENT | live file, #116 |
| **#128** | GStreamer arm64 `webrtc`/`nice`: a build-machine compiler gap, then three meson build-only-subproject defects (runs 11–29) | live file, #128 |
| **#131** | post-cross-phase refactor wave, four waves in a worktree | live file, #131 |
| **#133** | the three amd64-only components: rust-std pre-seed, `iree.runtime`, TVM runtime wheels (runs 29–36 + amd64 run 8) | live file, #133 |

Nothing here was edited — this is the same text, in entry order. The measured
facts (why a `$` anchor fails on CRLF, why tvm-ffi returns early as a
subproject, why `disabled_subproject` poisoned the host glib) are the reason
these narratives are kept rather than deleted. Rules that outlived their entry
live in [`../AGENTS.md`](../AGENTS.md), the failure symptoms in
[`failure-modes.md`](failure-modes.md), the invariants in
[`windows-build-invariants.md`](windows-build-invariants.md).

Earlier tranches: `windows-backlog-archive-2026-08-11.md`,
`windows-backlog-archive-2026-08-17.md`, `windows-backlog-archive-2026-08-21.md`.


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
  (defined in `build-gstreamer-from-source.ps1` — deliberately NOT in a module. **Correction
  2026-08-26:** this was first recorded here as "`/bkmods` is bind-mounted whole"; it is not —
  `buildmods` is a curated 6-module stage. The real reason is that those six ARE the import
  closure, they are mounted into all 11 media/merge RUNs, and the classic lane COPYs the same six
  into `common`, the ancestor of every BK compile stage, so any module edit re-keys every branch
  on both lanes twice over; a stage script is mounted per file, this one only into the merge RUN.
  #134 splits that) rewrites the pip-installed
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
  **Run 31:** the root configure works and compiles tvm-ffi — every TU with `cannot use 'throw'
  with exceptions disabled`: an explicit `CMAKE_CXX_FLAGS` replaces CMake's MSVC init flags
  (`/EHsc` among them) and, unlike TVM's own CMake, tvm-ffi as a root project does not add it
  back. `/EHsc` is now explicit on that configure. Proof: run 32.
  **Run 32:** tvm-ffi compiles, Cython transpiles `core.pyx`, the module links — as a bare
  `core.pyd`: FindPython reports no SOABI for CPython on Windows, so `python_add_library(...
  WITH_SOABI)` appends nothing (amd64 produces the same name). That is a valid import name the
  target interpreter loads; only my name check was over-strict (it demanded the target tag). It
  now rejects a HOST-tagged name only; the PE machine check is the arch gate. Proof: run 33.
  **Run 33:** the tvm branch is green — `apache_tvm_ffi-0.1.13.post2-cp314-cp314-win_arm64.whl`
  (`tvm_ffi\core.pyd` + `tvm_ffi\lib\tvm_ffi.dll`, 0xAA64), `apache_tvm-0.26.0-cp314-cp314-
  win_arm64.whl` (`tvm\lib\tvm_runtime.dll`), `iree_base_runtime-3.11.0.dev0+…-cp312-abi3-
  win_arm64.whl` (11 native members, `_runtime.pyd` + the runtime tools); manifest 6 wheels.
  The merge's deps gate then refused the tvm-ffi wheel's metadata — and rightly so:
  `Get-PyprojectDependencies` captured past tvm-ffi's ONE-LINE `dependencies = ["typing-
  extensions>=4.5"]` to the next `]` at a line start, i.e. through `[project.urls]` and the
  optional-dependencies, and the wheel declared its Homepage URL, `ninja`, `torch` and
  `setuptools` as requirements (`pip download` fails on the URL). The capture now closes at the
  first `]` that ends a line; fixture test covers the one-line shape and an extras marker.
  Proof: run 34.
  **Run 34 — two more, both found by gates, not by luck:** (i) the corrected regex forbade any
  `[` between `[project]` and `dependencies`, but `classifiers = [` / `authors = [{…}]` /
  `keywords = [` precede the list in BOTH pyprojects, so it matched nothing and the two wheels
  shipped with **no** `Requires-Dist` at all — a defect the deps gate structurally cannot catch
  (fewer requirements only make it greener; it showed up as `7 first-touch requirement(s)` where
  run 33 had 14). The parse is now two steps: isolate the `[project]` table body (up to the next
  `^[` header), then find the list inside it. (ii) With the metadata right, the **arch gate**
  caught the real hole: `1 unresolved import` — `core.pyd` imports `tvm_ffi_testing.dll`, which
  tvm-ffi links the Cython module against and upstream's own wheel ships beside `tvm_ffi.dll`;
  the assembled wheel now stages it too (both DLLs asserted present). Deps gate itself passed:
  `store holds 11 wheel(s); 0 requirement edge(s) unresolved`. Proof: run 35.
  ✅ **(b)+(c) DONE 2026-08-26 (arm64 run 35, `[bk] Done 00:41:22`).** The bundle now ships
  `apache_tvm_ffi-0.1.13.post2-cp314-cp314-win_arm64.whl` (3 native members: `core.pyd`,
  `tvm_ffi.dll`, `tvm_ffi_testing.dll`), `apache_tvm-0.26.0-cp314-cp314-win_arm64.whl`
  (`tvm_runtime.dll`) and `iree_base_runtime-3.11.0.dev0+…-cp312-abi3-win_arm64.whl` (11 members,
  `_runtime.pyd` + the runtime tools) — every member `0xAA64`. Manifest **6 wheels** (= amd64),
  deps store **11 wheels / 0 unresolved edges**, arch gate **992 / 0** with `606 walked, 0
  unresolved import(s)`, smoke 97/0/15. One metadata defect survived to be fixed after the fact:
  the two assembled wheels' `Requires-Dist` were EMPTY because .NET's multiline `$` matches only
  before `\n` and the container's git checkout is CRLF (the same text parsed correctly on the
  host, and the deps gate cannot see missing requirements — fewer edges only make it greener).
  Every anchor is `\r?$` now and the fixture asserts the CRLF variant. **Proven on run 36:** the
  deps gate reads **10** first-touch requirements (7 before), `apache-tvm-ffi>=0.1.13.post2` is
  resolved from the bundle's own wheel and `typing_extensions` is downloaded for the target
  (store 12 wheels), `0 requirement edge(s) unresolved`; arch gate 992/0, walk 606/0.
  **amd64 regression (run 8, 2026-08-26):** the native paths are untouched by all of this —
  `iree native gate OK (llvm-cpu compile + local-task run, abs(-5)=5)`, `iree python gate OK:
  abs(-5) = 5.0` (both wheels installed and interoperating), `import tvm` green, tvm branch 23:45,
  plugin gate 6/6, manifest 6 wheels / 0 markers, arch gate **1134/0**, smoke **222/0/0** —
  every number identical to run 7.
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

