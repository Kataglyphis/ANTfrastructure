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

> **SUPERSEDED IN PART, same day:** the "live file" column above is only still true
> for **#133**. Tranche 2 (below) moved #116, #128 and #131 here in full, so their
> verdicts live in this file now, not in `windows-refactor-backlog.md`.

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

## Tranche 2 — nineteen fully resolved entries (moved 2026-08-26)

A status census on 2026-08-26 found 19 of the live file's 24 entries fully
resolved by their own text and still sitting under `## OPEN` — about 54% of the
file — against the lean-OPEN-only policy stated there. Each was spot-checked
against the tree before moving: #124-#127, #129, #130, #132 and #133(a-c) are all
implemented and wired into `Dockerfile.media-merge-builder`, so they read as open
work that no longer exists.

Moved whole, unedited, in entry order: **#112-#120** and **#123-#132**. What
stayed live: #121 (QNN scaffold, no SDK ever staged), #122 (CUDA probe never run),
#133 (only (d) LiteRT-LM is open), #134 (the paid cleanup wave) and #31 (owner
decision). Note this supersedes the tranche-1 table above for #116, #128 and
#131 — their verdicts now live HERE, not in the live file; only #133's does.
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

---

## #122 — CUDA on arm64: Phase-0 probe (DONE 2026-08-28, CLOSED by owner decision)

Moved here from `windows-refactor-backlog.md` on 2026-08-28 after the owner
confirmed no near-term plan to integrate CUDA into the Windows container
build. The probe ran on 2026-08-28 (no chain rebuild); the verdict closed the
entry. Kept for the measured facts, which correct two prior records.

**Verdict: cuDNN arm64 ships today; CUDA itself does not — not at 13.4, not
at any 13.3.x or 12.x.** Wiring is blocked on NVIDIA publishing a
`windows-arm64` CUDA redist, not on this repo.

**(1) The hardcoded `windows-x86_64` literal in `setup-cuda.ps1` — CONFIRMED,
one site.** `setup-cuda.ps1:138` builds the cuDNN URL with a literal
`windows-x86_64` segment:
`…/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-{0}_cuda{1}-archive.zip`.
The CUDA installer URL (`:40`) carries no arch — it is
`cuda_$CudaVersion_windows.exe`, a single x86_64 .exe. So arch-parameterising
means the cuDNN URL ONLY: swap `windows-x86_64` -> `windows-arm64` (and the
matching filename prefix) on the arm64 lane. No CUDA installer URL change is
possible because there is no arm64 installer.

**(2) cuDNN arm64 archive at the exact pin — CONFIRMED HTTP 200, but the size
previously recorded was WRONG.**
`https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-arm64/cudnn-windows-arm64-9.25.0.15_cuda13-archive.zip`
returns **HTTP 200, 90,177,536 bytes (~90 MB)** — NOT the 421 MB recorded on
2026-08-24. The x86_64 counterpart at the same pin is HTTP 200, 632,936,226
bytes (~633 MB). The 421 MB figure was never re-measured after it was first
recorded; the archive may have been re-cut, or the figure was always wrong
(the 2026-08-24 note says "421 MB" with no fetch). The cuDNN redist *manifest
JSON* (`redistrib_9.25.json` and every variant tried) 404s, so the SHA256 pin
in `versions.env` (`CUDNN_ZIP_SHA256`) cannot be re-derived from the manifest
— it must be computed from a download, which is what `versions.env:779`
already says. The archive's own `lib\arm64` contents were not inspected here
(extraction needs 7-Zip, not on this host's PATH); the 2026-08-24 note asserts
`lib/arm64` inside and the 90 MB size is consistent with an arm64-only slice
of the 633 MB x86_64 zip.

**(3) CUDA 13.4 arm64 device `.lib`s — NOT PUBLISHED. CUDA 13.4 does not exist
on NVIDIA's servers.**
`https://developer.download.nvidia.com/compute/cuda/13.4/local_installers/cuda_13.4_windows.exe`
returns HTTP 404. The same path at 13.4.0 and 13.4.1 also 404. The `/cuda/13.4/`
directory page returns NVIDIA's "Page Not Found" HTML. There is no CUDA 13.4
installer to pull, preview or otherwise. The CUDA redist manifest for 13.3.1
(HTTP 200, 47 KB) lists **only `windows-x86_64`** for Windows — zero
`windows-arm64` entries. Same for 13.3.0, and for every 12.x checked (12.5.1,
12.6.0, 12.6.3, 12.8.1): 0 `windows-arm64`, 62 `windows-x86_64` each. The only
arm64 CUDA target NVIDIA publishes anywhere is `linux-sbsa` (Linux ARM64
server). The staged `windows/downloads/cuda_13.3.0_windows.exe` is an i386
InstallShield launcher (PE machine `0x014C`) — the wrapper, not a payload
indicator; extracting its 2.5 GB embedded archive to look for arm64 `.lib`s
needs 7-Zip (not on PATH here), but the redist manifest is the authoritative
publication list and it has no arm64 row.

**What this means for the wiring plan.** The entry's "only if all three hold"
gate FAILS on (3): there is no CUDA arm64 installer and no `windows-arm64`
CUDA redist, so there are no arm64 device `.lib`s to point nvcc at and no CUDA
root for the ORT CUDA branch to key on. Re-keying ORT on "an arm64 CUDA root
exists" is correct in principle but vacuous until NVIDIA ships one. Do NOT
relax the `-Gpu` driver refusal — the image-state hazard it guards is real and
the prerequisite (a CUDA arm64 publish) does not exist. Re-open this entry ONLY
when NVIDIA publishes a `windows-arm64` CUDA redist or installer; check the
redist manifest, not the marketing page. The 2026-08-24 retraction of "CUDA
does not exist at all" was itself half-wrong: cuDNN exists, CUDA
(toolkit/nvcc/device libs) does not, and the distinction matters because
ORT's CUDA EP needs the toolkit, not just cuDNN.

**One free, build-free fix that fell out of this probe (PARKED, not done):
arch-parameterise the cuDNN URL in `setup-cuda.ps1:138`** so the arm64 GPU
lane fetches the 90 MB arm64 archive instead of the 633 MB x86_64 one. That is
a correctness fix for the arm64 GPU lane's cuDNN layer (it currently downloads
the wrong arch), independent of whether CUDA itself ever ships for arm64. Do
it in a base-layer window, not folded into #134/#135.

---

## #136 — VS RUN never cached across runs (SOLVED + DEPLOYED 2026-08-26)

Moved here from `windows-refactor-backlog.md` on 2026-08-28. The fix landed
and was proven on 2026-08-26; the entry was kept OPEN only because the
narrative had not been archived. Kept for the `0B` = "already pruned to floor"
inversion lesson, which is the general rule worth remembering.

Every launch replays `#9 RUN setup-vs.ps1` while `#6` (a RUN with a bind mount),
`#7` and `#8` (the COPY of that very script) all report CACHED. Reproducible
across five consecutive launches on 2026-08-26.

**The cost is NOT constant, and the first version of this entry overstated it.**
Cold it was ~22 min of build plus ~7 min of export; on the very next launch the
same step reported `#9 DONE 363.2s` — six minutes — because the VS installer
finds its downloads already present. So the tax per iteration is roughly 6–10
min warm and ~30 min cold, not a flat 30. Still worth fixing (it multiplies
every Windows experiment), but do not plan around the cold figure.

**Ruled out by measurement, not by reasoning:** GC eviction (`buildctl du`
reports `Reclaimable: 4.27MB` of a 499.9 GB store, and the two ~37.6/37.8 GB
VS-class records are present); a build-arg that varies per run (the driver
passes only version pins — no timestamp, VCS ref or GUID reaches this stage);
`-NoCache`/`-NoCacheStage` (not passed); and a changed COPY input, since `#8`
— the COPY of `setup-vs.ps1` itself — is CACHED, so its parent chain and that
file are byte-identical.

**SOLVED 2026-08-26 (`916c91f0`) — it was the GC reserve, and the answer was
inside `buildkitd.toml` itself.** Its sizing note concludes "150GB is the
floor this file's own sizing note gives" and "keep reservedSpace >= 150 GB
regardless"; the value directly beneath it read **40GB** — below the single
~37 GB VS-class layer, so the spine could not survive between runs.
`maxUsedSpace` compounded it: the store had grown to 545 GB, above BOTH ceilings
(400/450 GB), so GC was evicting on every run no matter what the reserve said.
My earlier "GC ruled out because `du` reports `Reclaimable: 0B`" was the wrong
reading — `0B` is what a store already pruned to its floor looks like, not a
store that is never pruned. That inversion is the lesson worth keeping.

**Fixed:** reservedSpace 40→150 GB, maxUsedSpace 400→650 GB (tier 1) and
450→700 GB (tier 2). Arithmetic at edit time: C: 824 GB free of 1861 GB, store
545 GB, other content ~492 GB — so 150 GB is comfortably satisfiable, unlike
the 2026-08-08 deadlock at 214.75 GB when only ~294 GB was available to
buildkit. Three docs claimed a third number (200 GB) matching neither the
config nor `windows-build-lanes.md`'s own "150GB now"; all aligned.

**This was the second half of a fix only half-made on 2026-08-11**, which
raised `maxUsedSpace` after GC evicted "the base/sdk/toolchain spine between
driver runs → every run re-solved the prefix" — verbatim this symptom — and
left the reserve alone.

**DEPLOYED AND PROVEN 2026-08-26 23:10 (owner ran the elevated apply).**
Verified by effect, not exit code, as that script has reported success while
leaving the old value before (2026-08-08): the live daemon reports
`Reserved space: 161.0612736GB` on rules 1 and 2 with `Maximum used space`
697.93/751.62GB. **The proof is the next build**, not the config dump — the
very first launch afterwards reported `#6 #7 #8 #9 #10 CACHED`, the first time
`#9` had cached in six attempts that day. Base went from ~4–7 min of VS
install plus ~7 min of export to under a minute. Six attempts on 2026-08-26
would have cost ~2.5 h in cold prefix alone.

My "this run probably will not benefit yet, the records were already evicted"
caveat was wrong: the previous run's records were still present, and the
raised ceiling simply stopped GC from taking them.

**One doc trap this exposed, now fixed:** `buildctl debug workers -v` prints
GB while the toml takes GiB, and uses different labels (`Reserved space:` vs
`reservedSpace`). A 150 GiB pin shows as `161.0612736GB`, so the verification
instruction "must read 150GB" — which I had just written into two pages —
would make a correct deploy look failed.
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

  **(a1) `tbnz` / `fixup value out of range` — SAME root cause as (a2), retired by the SAME patch.**
  `BranchRelaxation` consumes the same `getInstSizeInBytes`; `median_blur.dispatch.cpp` and
  `multiview_calibration.cpp` are also compiled `/EHa`; and the ~150-byte miss is 37 `EH_LABEL`
  nops counted as zero. **CLAIMED BUT UNLOGGED — do not treat this as measured.** A
  `NINJA_KEEP_GOING=1` census is recorded as having built all **1,869** objects green with BOTH
  `OPENCV_NO_JUMPTABLE_WORKAROUND=1` and `OPENCV_NO_OB1_WORKAROUND=1`, on pinned `llvmorg-23.1.0`
  plus only the two `getInstSizeInBytes` patches (llvm#219275, llvm#219276). It was run by hand
  inside the container, so it left no `bk-` log: **no artifact in `out/windows-build-logs/`
  mentions either knob or `llvm-patched`**, and the newest log there is `bk-20260827-083658`.
  Re-run it through the driver and keep the log before deleting either workaround.

  **THIRD INSTANCE OF THE SAME INFERENCE ERROR — read this before the next attribution.** This
  block previously read "ROOT CAUSE FOUND, FIX EXISTS UPSTREAM:
  [`c6e184686cd7`](https://github.com/llvm/llvm-project/pull/202716) (trampoline blocks created at
  offset zero), so `/Ob1` stays until the toolchain moves to LLVM `main`". **The census compiler
  contains no such commit** — it is the pinned 23.1.0 release plus two patches that touch only
  `getInstSizeInBytes` — so llvm#202716 cannot be a necessary cause here. It is a real upstream
  defect, kept for the record, and nothing more. What the `branch-relax-tbz.mir` revert actually
  proved was that the commit is load-bearing **for upstream's own test**, never anything about
  `median_blur.dispatch.cpp`. That is the same "evidence about X read as evidence about Y" mistake
  this entry already records twice above.
  **The 2026-08-27 decision to move the toolchain to LLVM `main` is WITHDRAWN** — superseded by the
  shipped path (pinned 23.1.0 + the two patches). No backport request is needed from anyone.

  **Both workarounds are now removable — but they STAY until the patched toolchain is the DEFAULT.**
  `windows/Dockerfile.toolchain-builder` still carries `ARG BUILD_PATCHED_LLVM=0`, so a stock image
  ships unpatched clang-cl 23.1.0 and still needs both settings. Delete the flags from
  `build-opencv-from-source.ps1` in the SAME change that flips that default, never before.

  **The stage is reachable since 2026-08-28: `build-buildkit.ps1 -PatchedLlvm`.** Until then it was
  not — the driver always targeted `built` and `BUILD_PATCHED_LLVM` appeared in no `.ps1` at all,
  so the plan above would have been a no-op found mid-build. Pinned by
  `windows/scripts/tests/BuildKit.PatchedLlvm.Tests.ps1`. The switch is opt-in because the extra
  RUN + `ENV PATH` re-key every media stage below the toolchain image.

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
  register. **Filed upstream 2026-08-27** as
  [llvm#219276](https://github.com/llvm/llvm-project/pull/219276) (`40f1b36c642e` on
  `origin/aarch64-seh-size`). The verifier opt-in that found it is NOT upstreamed — it waits on
  llvm#219275 and llvm#219276 landing, and lives on the local branch `aarch64-instsize-verify`.
  (The local development SHAs `1e6148bc4b9c` / `f533c8e88038` are rebase ancestors of the pushed
  commits; their patch-ids differ, so chase the PR numbers, not these.) Mismatches **558 → 45**, all 45 remaining being over-estimates in unrelated pseudos;
  `check-llvm-codegen-aarch64` 4197 passed / 0 failed. **The `.td` route does not work** — the
  default case tests `if (Desc.getSize())`, so a declared `Size = 0` is indistinguishable from
  "unset" and still yields 4; it must be a C++ early return on `isSEHInstruction`. Full PR handover,
  including the two build-environment traps that each cost a run:
  `out/upstream-llvm-aarch64-seh-instsize.md` (ephemeral handover document, not in repo).
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

  Those are this entry's own recorded values. **Filed upstream 2026-08-27** as
  [llvm#219275](https://github.com/llvm/llvm-project/pull/219275) (`c03f827dc49f` on
  `origin/aarch64-ehlabel-size`); `check-llvm-codegen-aarch64` 4197 passed / 0 failed. The local
  development SHA was `f072f90a9e37` — a rebase ancestor, not findable upstream.

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

  ### 2026-08-28 — BUILT AND MEASURED IN THE CONTAINER. The fork fixes it.

  The shim patch was redeployed (`gate hash MATCHES`, 25,937,920 bytes) and the whole
  path was run for real. `build-llvm-from-source.ps1` works end to end: pinned
  tarball, SHA256-checked, **both patches applied**, the `eh-asynch` drift assertion
  passed, install in **~9.5 min**, and the banner reads `clang version 23.1.0` — so
  `verify-toolchain.ps1`'s provenance gate accepts it. Image tagged
  `docker.io/local/kataglyphis:bk-llvm-patched`.

  **Stock clang-cl 23.1.0 vs the same 23.1.0 + the two fork patches. Same sources,
  same flags, same MSVC headers, same container, NO workaround flags:**

  | | stock | patched |
  |---|---|---|
  | protobuf `descriptor.cc` | `258`, `281` out of range | clean |
  | protobuf `generated_message_reflection.cc` | `284` out of range | clean |
  | protobuf `wire_format.cc` | `260` out of range | clean |
  | protobuf, objects produced | **0 / 3** | **3 / 3** |
  | OpenCV `imgproc` | 2 range errors (`277`, `258`), 150 objects | **0 errors, 151 objects** |

  Every value matches the ones this entry recorded from the lane logs. Objects are
  counted deliberately: zero errors with zero output would prove nothing.

  **Still NOT established, and the workarounds stay until it is.** This is
  `BUILD_LIST=imgproc` in a minimal configure — 151 objects against the lane's
  ~1,870 — and `median_blur.dispatch.cpp` never compiled here (OpenCL kernel-header
  generation), so **`/Ob1` and the whole BranchRelaxation half remain untested**. The
  rule this entry set still holds: this licenses the `NINJA_KEEP_GOING=1` census with
  both settings removed, it does not replace it.

  **Three environment problems solved on the way, each documented in
  `failure-modes.md`:**
  * `patch.exe` silently skipping every patch on a non-git source tree — a latent
    bug in `Invoke-SourcePatch`, found only because the drift assertion fired.
  * `atlbase.h` missing (ATL is not in the container's VS Build Tools) — fixed with
    `-DLLVM_ENABLE_DIA_SDK=OFF`.
  * `ImportLayer 0xb7` on image export — snapshot debris, cleared by `--no-cache`
    exactly as documented. Ruled out first: the shim (`gate hash MATCHES`) and the
    RDNA4 dGPU (`ConfigManagerErrorCode=22`, i.e. disabled).
    [docker/for-win#14977](https://github.com/docker/for-win/issues/14977) is still
    `open` and still `needs-triage` as of 2026-08-28, so the
    `toggle-rdna4-gpu.ps1 -Disable` workflow stays.

  **Strong open hypothesis — this may also be (a1), i.e. `/Ob1`.** `BranchRelaxation` consumes the
  same size function, `median_blur.dispatch.cpp` and `multiview_calibration.cpp` are also compiled
  with `/EHa`, and the miss there was ~150 bytes ≈ 37 labels. If so this single fix retires **both**
  workarounds and llvm#202716 is a separate, additional defect rather than the explanation. Test it
  the same way before assuming either.

  **Local build assets (not in this repo):** `D:\GitHub\llvm-project` (blobless clone) and
  `D:\llvm-build` (`llc`/`llvm-objdump`/`llvm-nm`, Release+assertions, AArch64-only, built with the
  Strawberry MinGW g++ 13.2 that ships with this host — there is no MSVC here, which is also why a
  Windows-ARM64 object cannot be produced outside the container).

- **#136 — VS RUN never cached across runs: SOLVED + DEPLOYED 2026-08-26, archived.** The

