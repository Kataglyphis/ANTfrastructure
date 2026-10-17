<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Changelog archive — 2026-10-01 through 2026-10-07

Entries moved out of the root `CHANGELOG.md` on 2026-10-17 so the live file stays
readable (its own rule: archive past ~700 lines, never delete). Newest-first, running
back to where [`changelog-archive-2026-09-30.md`](changelog-archive-2026-09-30.md) picks up. One mechanical edit, no
rewording: relative links are re-based on this directory.

## 2026-10-07 — IREE: every Linux target tree settles before its GIL build; the compiler twin proved on both lanes (CON81, CON79 1)

- **Every Linux IREE target tree configures twice before it builds** (`_iree_configure_settled`, native and cross;
  owner approval 2026-10-07). IREE adds `runtime/`, whose `iree::base` links `${IREE_LIBBACKTRACE_TARGET}`, before
  `build_tools/third_party/libbacktrace` caches it (v3.12.0 lines 1199/1236, v3.11.0 1149/1186), so only a second
  configure puts `IREE_HAVE_LIBBACKTRACE=1` on the compile lines that see `iree::base` (1187 of 6700 on the amd64
  compiler tree). The twin's reconfigure used to be that second configure and recompiled them all. An aarch64 cross
  configure moves 377 of 474 lines the same way, so the cross target trees settle too; the host stage configures once.
- **The GIL wheels' bytes do not change** (correcting CON81's premise): release builds run `IREE_STATUS_MODE` 2, which
  compiles the stack-trace path out. The settled build's 28 native files are byte-identical to `:latest`'s.
- **Linux, proved in `:latest` amd64** through `build-app-wheelhouse.sh` with the full in-tree LLVM, cold, `-j16`, on
  **IREE v3.11.0** (the published image's ENV `IREE_VERSION` won over the tree's v3.12.0 pin in that local run):
  configure 55 s (17 s of it the settle), build 2334 s; twin pass 25 s, **58 objects, all Python bindings** (an
  unsettled tree changed 1272 compile lines). `prove` loaded 14 compiler modules and the runtime module with the GIL
  off; in a 3.14t venv MLIR parsed in-process, a VMFB compiled and ran on `local-task` from 8 threads, and the twins'
  `iree-compile`/`iree-run-module` ran. `libIREECompiler.so` and the ten runtime tools are byte-identical between the
  GIL wheels and the twins. Tests: `test-iree-wheelhouse-stages.sh` 66 -> 76, 3 mutations.
- **Windows, proved in `:winamd64` on IREE v3.12.0 (2b05c5db)**, `Build-IreeFromSource.ps1` unchanged, compiler and
  in-tree LLVM: both clang-cl fixes held on the full tree; GIL pass 8696 edges in 23 min at `-j20`; twin pass 94 s, 137
  edges (80 reach Python; 56 follow the VM ISA genrule, which re-runs for the venv's Python and relinks
  `IREECompiler.dll` and the tools, differing only in the COFF `TimeDateStamp`). `prove` loaded all 13 compiler modules
  and the runtime module with the GIL off; `compile_str` plus `local-task` ran in eight threads at once.

## 2026-10-07 — Lock file maintenance in the preset; sqlite3.wasm 3.7.0; pandoc 3.12; PR merge refs on Windows

- **Every lockfile moves to the newest release its manifest allows** (owner rule 2026-10-07). `default.json` sets
  `lockFileMaintenance` (enabled, schedule "at any time"). Before it, WebDavClient's uv.lock sat 41 packages behind,
  DocumANTation's 19 and OmniAccelerANT's pubspec.lock 17, while every manager reported them up to date.
- **Under `--platform=local` Renovate builds the update and never reports it** (44.140.0: `dryRun=lookup` skips the
  branch phase, the report's `branches` stays empty), so `renovate-local.sh` carries it: `renovate_planner.py lockmaint`
  reads the resolved config, the report lists each maintained lock once with its command, and `--apply` runs Renovate's
  own command per lock (uv lock --upgrade, cargo update, pub upgrade, poetry, pdm, npm, pnpm) through the existing
  pre-flight, copies, undo, read-back and collateral guard; yarn is NOT CARRIED (exit 2). Tests:
  `test-renovate-lockmaint.sh` (M1-M10), 4 mutations; docs/dependency-updates.md#lock-file-maintenance. End to end with
  real Renovate over DocumANTation: `--apply` moved 19 packages, the same lock a hand-run `uv lock --upgrade` wrote.
- **The preset reads pubspec `environment: flutter:` floors with npm versioning**, moved from OmniAccelerANT's config.
- **`SQLITE3_WASM_VERSION` 3.3.1 -> 3.7.0** (SHA256 by full download = GitHub's asset digest), with OmniAccelerANT's
  sqlite3 package; jotrockenmitlocken (locks 3.6.0) must follow.
- **pandoc 3.11 -> 3.12** (`PANDOC_SHA256_AMD64/ARM64` at GitHub's digests; `pandoc --version` ran from the measured
  bytes), with DocumANTation's Dockerfile ARGs (gitlink 7c89684 -> ce1498b, which also carries its lock maintenance,
  the ruff 0.16.10 pin and its lint fixes).
- **`clone-into-short-path` fetches a pull request's merge commit.** A clone lacks `refs/pull/<n>/merge`, so every PR's
  Windows container jobs died `fatal: unable to read tree` in "Prepare Windows container host" (OmniAccelerANT #45, which
  looked like a go_router failure). It now fetches the ref by SHA when the clone lacks it, as actions/checkout does.
- **DocumANTation is declared in `.github/consumers.json`**, so workflow-lint grades it.

## 2026-10-07 — riscv64: the cross wheel link takes the sysroot's libc

- **fix(riscv64):** `ci_packaging.sh`'s cross mode puts `-L<sysroot>/lib/riscv64-linux-gnu
  -L<sysroot>/usr/lib/riscv64-linux-gnu` first in `LDSHARED` and drops the `-Wl,-m,elf64lriscv` pin. setuptools
  appends the host interpreter's LIBDIR, `-lc` then found the host `libc.so`, and its `OUTPUT_FORMAT(elf64-x86-64)`
  made lld refuse every riscv64 object (OrchestrANT runs 37196119524, 37329297990; its riscv64 packaging had failed
  since 2026-10-04). Reproduced and fixed in `:latest` with the riscv64 sysroot: the wheel builds (64 compiled modules),
  and a compiled module imports under QEMU and returns bit-identical floats to the pure-Python source.

## 2026-10-07 — Windows arm64: cp314t twins of the chain wheels on the cross lane (CON79 item 2)

- **The arm64 cross lane builds the `win_arm64` twins `:winamd64` builds**: `onnxruntime`, `av`, `apache-tvm-ffi` and
  `iree-base-runtime` (no compiler on this lane), in `C:\runtime\wheels-cp314t`. The host's x64 3.14t runs each build;
  the target tree's `python314t.lib` (CON74) is what each module links.
  - `New-FreeThreadedBuildPython` links `Get-TargetBuildPython -FreeThreaded` and pins the cross venv's `EXT_SUFFIX` to
    `.cp314t-win_arm64.pyd`; `Invoke-PythonWheelBuild -FreeThreaded` adds `--plat-name`.
  - PyAV links with `build_ext -L <target libs>` (setuptools' host `libs\` came first and failed `LNK2001
    __imp_PyModuleDef_Init`). ORT re-applies its cross MLAS flags after the twin's re-configure, IREE its ukernel flags
    (`Update-IreeCrossNinjaFile`). `New-TvmFfiCrossWheel` assembles both tvm-ffi wheels; `apache-tvm`'s cross wheel is
    `py3-none-win_arm64` now, as upstream builds it.
  - media-tvm builds the free-threaded target tree too, and that tree stages `python3t.lib`: IREE's FindPython requires
    `Development.SABIModule`.
- **Static gates on the build host, the proof on the device.** A cross twin is stored after its tags, a new import gate
  (`Get-FreeThreadedWheelImportFinding`, on amd64 too) and its PE machine. At the merge, `Write-BundleManifest.ps1`
  refuses a cross store that does not mirror the GIL store, and `Test-TargetArch.ps1 -ImportWalk` machine-checks every
  wheel's members and fails a `cp3XYt` module that imports a GIL runtime. `Test-Arm64Bundle.ps1` proves each twin in a
  `python3.14t -m venv` with the `free-threaded-wheel.py` that `Export-Arm64Bundle.ps1` now ships beside it.
- Proved in `:winarm64` (an x64 3.14t and the ARM64 trees from this checkout): twin passes 107 s PyAV, 72 s tvm-ffi, 90 s
  ORT (DLLs byte-identical to the GIL wheel's), 36 s IREE runtime; every member `0xAA64`, every module importing
  `python314t.dll`; manifest check and arch gate (1275 inspected, 0 violations) green. Only `windows-11-arm` can load
  the twins (CON79).

## 2026-10-07 — Pins: Renovate's hub report (Vulkan SDK 1.4.363.0, flatpak 26.08, llama.cpp b11476, Node 26.11.0, …)

- **Owner rule (2026-10-07): every update Renovate reports is taken, majors and runtime branches included.**
- **Vulkan SDK 1.4.357.0 → 1.4.363.0** (LunarG's latest on linux, windows and warm alike). `VULKAN_SDK_SHA256`,
  `VULKAN_RT_WINDOWS_ZIP_SHA256` and `VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256` re-measured by full download, each equal to
  LunarG's `sdk/sha/` digest; every Dockerfile ARG and install-deps' default follow. The SDK's slang carries PR #12305,
  so the riscv64 slang patch, its `_vulkan_patch_component` arm and its `Dockerfile.sdk` COPY are retired.
  `spec_vulkan` now refreshes the warm/ ARM64 loader zip too.
- **Flatpak runtime 24.08 → 26.08.** Since 25.08 the GL sibling branch is `<ver>-extra` and the codecs ride
  `codecs-extra//<ver>-extra` (FFmpeg, x264, x265, libde265); the openh264 ref and `FLATPAK_OPENH264_VERSION` are gone
  (2.6.0 was never on flathub, so the old install had been failing with only a warning). `packaging-deps.sh` installed
  7/7 refs in `:latest`; Platform//26.08 carries glibc 2.44, and a minimal flatpak-builder build ran on it.
- **llama.cpp b11472 → b11476** with the whole `LLAMA_CPP_*` set (commit, source archive, CPU and Vulkan zips at
  GitHub's digests). **Node 26.9.0 → 26.11.0**, **x265 4.1 → 4.2** (`Build-FfmpegCodecs.ps1` now refuses any OLD CMake
  policy; 4.2 dropped the two it patched), **vvdec v3.2.1**, **binaryen version_133**, **Chrome for Testing
  155.0.8059.39**, **Renovate 44.144.1** (engines.node still `^24.11.0`), **upload-artifact v7.0.2 /
  download-artifact v8.0.2**. Every SHA256 by full download, checked against a second source; Node, pandoc, wasm-opt,
  Chrome for Testing and the SDK tools ran from the measured bytes in `:latest`.
- Held: protobuf 36.2 (slaved to LiteRT-LM 0.18.0's v36.1, still its newest release).

## 2026-10-07 — One cp314t twin table for both lanes; Linux 3.14t venvs take the chain ORT twin (CON79 4, 1c)

- **The twin verdicts live in one file both lanes read**, `linux/scripts/03-media/free-threaded-twins.txt`
  (`dist|verdict|PIN=value|evidence`, `#` comments). Linux's `ft_wheel_table` and Windows' `Get-FreeThreadedTwinTable`
  both parse it, so their verdicts cannot drift. They had: `torchvision` (none) was only on Windows, `libcamera` (gil) only
  on Linux, and four evidence texts were worded apart. The file holds the union, 12 rows, with the fuller evidence.
  - Linux mounts it per file beside `free-threaded-wheels.sh` in the six RUNs that build or store a twin. Windows mounts
    it at `C:\bkmnt\free-threaded-twins.txt` in the three twin RUNs of `Dockerfile.media-builder`, and the final stage's
    one COPY bakes it into `C:\temp\scripts`, where Test-Container section 20 reads it. No other RUN re-keys on it.
  - A missing table stops a run instead of reading as unclassified, on both lanes and in the smoke.
  - Tests: both lanes keep their pin re-check, and each asserts its parse equals the file row for row and that neither
    reader holds a row literal. 7 mutations; the Pester guards were proved by hand (7 edits, all bite).
- **A `cp3XYt` venv inside `:latest` takes the chain ORT twin (CON79 1c).** `Dockerfile.torch` names `/opt/wheels-cp314t`
  in `PYTHON_WHEELS_CP314T`, Windows' variable, after the store's late COPY. `uv_reconcile_chain_ort` reads it for a
  `cp3XYt` venv and proves the venv against the twin store, taking only the twins of the flavours `ORT_CHAIN_WHEEL_DIR`
  holds (a GPU image's twin store carries two ORT flavours). Without the variable the leg is refused on the ABI as before,
  and the FT-STORE gate wants it on every arch.
  - Proved in the published `:latest` amd64 with a 3.14.8t built by `build_python.sh`: a 3.14t venv holding PyPI's cp314t
    onnxruntime 1.30.0, refused by the previous `python_uv.sh`, was reconciled onto `onnxruntime_dnnl-1.30.0-cp314-cp314t`
    (census PASS, GIL off). The twins were pure-Python stand-ins; a real cp314t ORT twin needs the GIL ORT build tree.
    A GIL venv with the variable set still took the image's real chain wheels. Tests: `test-uv-chain-ort.sh`,
    `test-free-threaded-store.sh`; 5 mutations.

## 2026-10-07 — Windows: the media fan-in merges site-packages in place (CON80)

- **`import Cython` failed in `:winamd64` and `:winarm64` (2026-10-04): `Cython\shadow.py`, while its RECORD
  names `Shadow.py`.** A Windows container layer that replaces a file a lower layer holds stores the new name
  lowercased, and BuildKit's `COPY` replaces every file it overwrites. The fan-in COPYed media-core's and then
  media-tvm's site-packages; both carry Cython, numpy, pip, setuptools, wheel and packaging, so the second COPY
  lowercased all 451 of their RECORD entries. NTFS opens either spelling, CPython's import does not, and Cython
  is the one with CamelCase modules (docs/windows-build-invariants.md, docs/failure-modes.md).
- **The two COPYs are one `RUN`**: both branch trees bind-mounted, merged by `Merge-SitePackageTree`
  (`WindowsSitePackages.Common.psm1`) with robocopy, which overwrites in place. It refuses a distribution at
  two versions and any RECORD entry spelled otherwise on disk afterwards.
- **Both branches install `cython==PY_CYTHON_VERSION`**, forwarded as a build-arg to `media-core-built-ffmpeg`
  and `media-tvm-env`.
- **Smoke section 2** imports `Cython.Shadow` at the pin and checks every base-interpreter RECORD against the
  disk, case-sensitively; section floor 6 -> 8.
- Proved by a replay of the fan-in on the local stage images: 451 mismatches and the ModuleNotFoundError before,
  0 over 31 distributions and a working import after (9.9 s). Tests: `SitePackages.Merge.Tests.ps1` (10).

## 2026-10-07 — Linux: proved cp314t twins of the media wheels whose code declares free-threading

- **Every wheel the media stage builds natively for a package whose own code declares free-threading also ships
  as a proved `cp314t` twin**, in `/opt/wheels-cp314t` (owner request 2026-10-07). The GIL wheels are built as
  before. One table decides, `ft_wheel_table` in `03-media/free-threaded-wheels.sh`, each row read at a
  `versions.env` pin that a test re-checks; it holds the same verdicts as Windows' `Get-FreeThreadedTwinTable`.
  - Each build reruns in its warm tree on a 3.14t venv pinned to the GIL build venv's executors; `ft_soabi_gate`
    and `free-threaded-wheel.py prove` run before a twin is stored, and `free-threaded-store.sh` proves the store
    again after the repair.
  - `verify-wheels.sh` is ABI-exact on both stores, the ORT twin has its own `ort-provenance-cp314t.sha256`, and a
    native build fails on a missing or stray twin or an unclassified wheel. Cross builds build no twin (CON79).
  - `:latest` ships the store; the runtime smoke's FT-STORE gate proves each twin on `python3.14t` and wants
    exactly `/opt/venv`'s twin families on a native arch.
- **`free-threaded-wheel.py` counts a bare `.so` as a module only when it exports `PyInit_<name>`**, so ORT's
  `libonnxruntime_providers_shared.so` no longer fails the proof.
- Proved in `:latest` amd64: ORT CPU, PyAV, tvm-ffi and the IREE runtime twins, twin passes 97 s / 28 s / 29 s /
  130 s cold (11-40 s warm for ORT); in a 3.14t venv numpy, onnxruntime, av, tvm_ffi and iree.runtime import
  with the GIL off. Tests: `test-free-threaded-wheels.sh`, `test-free-threaded-store.sh`, 33 mutations.

## 2026-10-07 — Windows: cp314t twins of the chain wheels that declare free-threading

- **Owner request 2026-10-07: every chain wheel twice, `cp314t` only where the code declares it.** Checked in
  upstream source at the pinned tags: onnxruntime (`py::mod_gil_not_used()`), PyAV (`freethreading_compatible`),
  apache-tvm-ffi (`# cython: freethreading_compatible = True`) and IREE runtime and compiler (nanobind
  `FREE_THREADED`) get a twin; apache-tvm (a py3 wheel) and torchvision carry no CPython module; onnxruntime-genai,
  LiteRT, pyhailort, libcamera and cv2 declare nothing and stay GIL-only. The verdicts live in
  `Get-FreeThreadedTwinTable` with the pin each was read at, and a pin bump fails a test until the evidence is
  re-read.
- **`:winamd64` builds them beside the unchanged cp314 ones**, in `C:\runtime\wheels-cp314t`
  (`PYTHON_WHEELS_CP314T`). Each twin is built in a uv venv on `C:\python-freethreaded` with the GIL pass's tool
  versions, tag-checked (`cp3XY-cp3XYt`, `win_amd64`, every `.pyd`), installed alone into a fresh venv and proved
  with `free-threaded-wheel.py prove` before it is stored. `Save-PythonWheel` refuses a cp3XYt wheel in the GIL
  store, nothing installs into `C:\python-freethreaded`, and smoke section 20 checks the store's exact set.
  - **ORT** re-configures the GIL build tree for the venv's Python and rebuilds only `onnxruntime_pybind11_state`;
    the twin's DLLs must be byte-identical to the GIL wheel's, and the ORT census takes both wheels as chain
    references (`Get-OrtChainWheel -Abi`). A 3.14t venv's chain-ORT reconcile reads the twin store.
  - **IREE** forces abi3 off (upstream only knows a `cpython-NNt` SOABI), clears nanobind's cached GIL suffix,
    and drops the GIL pass's leftover `_runtime.pyd` before the twin packs.
  - Measured in `:winamd64`: ORT twin pass 60 s, PyAV 43 s, tvm-ffi 34 s, IREE runtime 20 s; each proved with
    the GIL off. A module without the declaration was refused. The clang-built 3.14t reports `win-amd64`, so no
    platform-tag shim is needed.
- **`Invoke-CmakeConfigure -Settle`.** CMake 4.4's Ninja generator writes `\` paths on a tree's first configure
  and `/` after, so every re-configure recompiled all 1474 ORT edges; the GIL pass now configures twice when a
  twin follows.
- **IREE v3.12.0 on clang-cl.** Its VM ISA genrules ran a bare `python3`, which no Windows image has; they run
  `Python3_EXECUTABLE`. Its profile statistics sink needs `__udivti3`, so every IREE link gets
  `clang_rt.builtins-<arch>.lib`. Both broke the pinned build regardless of the twin.

## 2026-10-07 — ROCm 10.1 (TheRock `therock-10.1`), MIGraphX 2.18.0 and llama.cpp b11472 (CON73)

- **Owner decision: TheRock 10.1, MIGraphX 2.18.0 and the newest llama.cpp, all three.** Renovate has reported
  TheRock 10.1 since its annotation reads `versioning=loose`; the bump was made by hand, since every pin carries a
  paired value. `MIGRAPHX_VERSION` is shared by both lanes.
- **Linux (`:latest-rocm`).** `ROCM_VERSION=10.1`, `MIGRAPHX_VERSION=2.18.0`. The list resolves to 262 packages at
  `10.1.0-3` plus `amdrocm10-migraphx{,-dev}` `2.18.0-1` (298 with ASAN, all 10.1). `PYTORCH_ROCM_INDEX` stays
  `rocm7.14`: `rocm7.14.1`, `7.15`, `7.16`, `8.0`, `10`, `10.0` and `10.1` answer 403.
  - **MIGraphX left `/opt/rocm/lib`.** 10.1 installs it under `/opt/rocm/extras-10/`; the first 10.1 install
    stopped at `migraphx.hpp not found`. `setup-rocm-repo.sh` writes `libmigraphx_c`'s directory into
    `rocm.conf`, finds `migraphx.hpp` anywhere under `/opt/rocm` and fails unless `ldconfig -p` lists
    `libmigraphx_c`; `30-build-native-amd.sh` hands ORT MIGraphX's own prefix as `--migraphx_home` (ORT's
    `find_package(migraphx PATHS /opt/rocm)` misses `extras-10`) and drops the dead `2.14.0` default;
    `publish_rocm_ld_path` publishes the same directory and no longer publishes `core-asan-*`.
  - Proved in `:latest`: the real 10.1 install (7.0 GB, 21.7 GB on disk) and the ASAN branch pass the script and
    its release check, and the script built ORT v1.30.0 with the MIGraphX EP, whose provider loads GPU-less.
    `test-rocm-packages.sh` 22 → 36 assertions, 10 mutations.
- **Windows (`:winamd64-rocm`).** `ROCM_WINDOWS_RELEASE` 10.0.0 → 10.1.0: the gfx120X-all tarball
  (2,244,477,973 B) and the `rocm` sdist, `rocm-sdk-core`, `rocm-sdk-libraries` and the gfx1201/gfx1200 device
  wheels, every SHA256 self-measured by full download. 10.1.0 names hiprtc `hiprtc0716.dll`; every check derives
  the name.
  - **MIGraphX 2.18.0** is the head of `release/rocm-rel-10.1` (`95672916`; no `rocm-10.1` tag yet). It carries
    upstream 5a80dc91ba, so `001-mlir-off-stubs.patch` is gone. It built to the end in 58 min in a `:winamd64`
    container (`prefuse_ops.cpp` alone about 50 min on one core), and the ORT AMDGPU EP built against it.
  - **llama.cpp b11460 → b11472, with `ggml-hip.dll` built here.** Upstream still ships only `win-rocm-10.0` zips.
    `Build-LlamaCppHipFromSource.ps1` builds upstream's `windows-rocm` recipe from the tag's source archive with
    TheRock's AMD clang for gfx1200/gfx1201, with nothing that downloads at build time (3 min 27 s cold).
    `Install-LlamaCpp.ps1 -Backend hip` puts it beside the tag's `win-cpu-x64` zip (`llama-server`/`llama-cli`
    and the CPU backends, SHA-pinned as `LLAMA_CPP_CPU_SHA256`), as upstream's own ROCm zip merges them: a full
    source build would fetch the server's web UI and BoringSSL unpinned. No ROCm DLL sits beside it; the
    directory is 178 MB, down from about 1.24 GB. The Vulkan build stays upstream's zip at the same tag.
  - `rocm-checks\LlamaCpp.ps1` checks that no ROCm DLL sits beside llama-server, walks ggml-hip's imports into
    ROCm's bin and runs `llama-cli --list-devices`. `WindowsMigraphx.Common` gains `Invoke-RocmClangConfigure`
    and `Assert-RocmBuiltPe`. TheRock 10.1's clang compiles HIP against MSVC 14.51 without the `hip-msvc-cmath`
    overlay, which stays until an image build proves it can go (CON78).
- What only the published images prove is BACKLOG CON78.

## 2026-10-07 — The arm64 bundle carries a free-threaded CPython too (CON74, half 1)

- **`:winarm64`'s `C:\runtime` gains `python-freethreaded`** beside the GIL target interpreter.
  Media-core's `Build-TargetCpython.ps1` builds the target checkout twice with the image's VS 2026
  ClangCL toolset (`Invoke-CpythonPcbuild -Platform ARM64`, then `-FreeThreaded`, both with
  `/p:PreferredToolArchitecture=x64`) and stages each tree right after its own build.
  - **One staging function, `Install-CpythonTargetTree`**, is the old block: the PE-machine gate,
    the host-arch CRT replacement, the `vcruntime140_1` drop, headers, `Lib`, an empty
    `site-packages`, the CRT beside the exe and the ensurepip check. On the same build output the
    GIL tree and `C:\runtime\bin` are byte-identical to the old code's.
  - **The free-threaded tree** holds `python3.14t.exe` and `libs\python314t.lib`, no `python.exe`,
    no DLL-directory shim, and `venvlaunchert.exe`/`venvwlaunchert.exe` in `Lib\venv\scripts\nt`:
    without them `uv venv` refuses a tree with no `python.exe` to copy.
  - **media-tvm passes `-SkipFreeThreaded`**, since the merge takes only media-core's trees.
  - **`BUNDLE-ENV`** sets `KATA_PYTHON_FREETHREADED` and appends the tree last to `PATH`.
- **The merge gate's import walk threw on the second of two same-named wheels.** Both trees ship
  ensurepip's `pip-26.2.1` wheel; `Test-TargetArch.ps1` now extracts each into its own directory.
- **`Test-Arm64Bundle.ps1` runs `python3.14t.exe -I`** in a bundle that has it and fails unless the
  GIL is off, `Py_GIL_DISABLED` is 1 and `sys.version` says `ARM64`. The steps a bundle may lack
  share `Invoke-ShippedBundleStep`.
- Measured in `:winamd64` on a fresh v3.14.8 checkout (32 CPUs): ARM64 GIL build 65-96 s,
  free-threaded 67-79 s. The free-threaded tree has 2793 files and 82.5 MB, and all 61 of its PE
  files are `0xAA64`. The merge gate over both trees inspected 131 binaries and walked 157, with 0
  unresolved. The same function on an x64 free-threaded build gave a tree that uv took with
  `UV_PYTHON_DOWNLOADS=never`, and its venv ran with the GIL off. Only `windows-11-arm` can run the
  ARM64 tree. A media-stage change: `:winarm64` rebuilds from media-core on.

## 2026-10-07 — A proved free-threaded wheel beside the GIL one

- **A project that declares free-threading ships a `cp314t` wheel too** (owner request
  2026-10-07: two wheels, the free-threaded one only where the project supports it).
  `ci_packaging.sh` and `Invoke-CiPackaging.ps1` read `pyproject.toml`'s official `Programming
  Language :: Python :: Free Threading` classifier (any level) through the shared
  `free-threaded-wheel.py`.
  - The `CYTHONIZE=True` build runs again on the image's 3.14t, found by `uv python find` and never
    downloaded, and must leave one `cp314t` wheel (auditwheel-repaired on Linux).
  - A fresh 3.14t venv installs the shipped wheel and loads every compiled module; the step fails
    when the GIL is back on, naming the first module that turned it on.
  - The sdist and the pure wheel are built once. Undeclared projects build what they built before,
    plus one log line. `PYTHON_FREE_THREADED_WHEEL=auto|on|off` (Windows also
    `-FreeThreadedWheel`) overrides; the riscv64 and Windows arm64 cross lanes skip it with a
    reason (CON75). New module `WindowsPythonWheel.Common.psm1`.
  - **A consumer moves its hub pin only once its images resolve `3.14t`** (`:latest` amd64/arm64,
    `:winamd64`): a declared project's packaging step fails without one, by design.
- **The Linux GIL build asks uv for `3.14+gil`**, as Windows does: `uv build` ignores the venv.
- **`free-threaded-wheel` input** (CON77): `python-ci-linux.yml` and `python-ci-windows.yml` pass
  `auto`/`on`/`off` to the drivers as `PYTHON_FREE_THREADED_WHEEL`, so a caller can switch the
  wheel off without dropping its classifier.
- **auditwheel runs on Linux at last.** It is PATH's, else the binary packaging venv's; PATH never
  had one, so every Cython wheel shipped as `linux_<arch>` under a log line calling it pure.
- **`python-app-bundle.sh` picks the wheel by its runtime's ABI**, like `Select-PythonAppWheel`.
- Proved on OrchestrANT (64 compiled modules, manylinux2014/manylinux_2_17 and win_amd64) and
  WebDavClient (3 modules) in `:latest` and `:winamd64`, with a uv-fetched 3.14.7t standing in for
  the images' own until they ship it. Tests: `test-python-free-threaded-wheel.sh`,
  `PythonWheel.FreeThreaded.Tests.ps1`, 14 mutations.

## 2026-10-07 — The free-threaded CPython is built from source, on every arch (CON66)

- **Owner decision: `3.14.8t` comes from the toolchain stage, not uv's python-build-standalone
  download.** `build_python.sh` builds `PYTHON_VARIANTS` (`gil,freethreaded`) in turn from the one
  SHA256-verified tarball, and `/usr/local/bin/python3.14t` stays the contract path.
  - The GIL build is unchanged. Against the old script, its staged cross trees list the same 9600
    paths at the same sizes, and every file but `libpython` (its build date) is byte-identical.
  - The twin is `--disable-gil --without-static-libpython` in `/opt/python-freethreaded`: PGO and
    LTO natively, LTO alone per cross arch. Its rpath goes in through `LDFLAGS_NODIST`, so a
    `cp314t` wheel built against it inherits none.
  - Each arch's tree is staged at `/opt/python-cross-ft/<arch>/opt/python-freethreaded`. The build
    arch's is hardlinks and is staged in native mode too, so `Dockerfile.package` takes the target
    arch's with one COPY (`runtime-artifacts.manifest`, `ALLOWED_RELOCATIONS`).
  - A cross tree is a `make altinstall` (bytecode, `python3.14t-config`) and keeps `_ctypes`, which
    the GIL cross trees build without. `_python_dynload_audit` makes `_ssl`, `_hashlib`,
    `_sqlite3`, `zlib`, `_bz2`, `_lzma` and `_ctypes` fatal there.
  - `install_free_threaded_python` links and checks the COPY'd tree and refuses a missing one;
    nothing downloads.
- **Gates.**
  - `smoke-toolchain.sh` runs the twin and checks every staged arch.
  - The `free-threaded-python` row also wants `sysconfig`'s prefix `/opt/python-freethreaded` and
    the stdlib imports, so a python-build-standalone tree fails it.
  - The tree-arch gate scans `/opt/python-freethreaded`.
  - New suite `test-build-python-variants.sh`; eight new mutations.
- **Measured in `:latest` on 32 cores.** The image's flags (cross amd64/arm64/riscv64) took 624 s:
  6.5 min native (4.7 of them the PGO profile run) and under 2 min per cross arch. Shipped trees:
  138 MB amd64, 120 MB arm64, 233 MB riscv64.
  - Each tree, installed by the new package-stage code, reports `3.14.8 False` and passes the row;
    arm64 and riscv64 ran under QEMU.
  - uv 0.12.17 finds it for `3.14t` and not for `3.14+gil`.

## 2026-10-07 — The Windows image builds its free-threaded CPython from source

- **`:winamd64` carries `PYTHON_VERSION` twice, both source-built with the image's VS 2026 / MSVC
  14.51 and the ClangCL toolset** (owner request 2026-10-07). Until now every Windows `3.14t` leg
  had uv download a python-build-standalone interpreter.
  - `Build-ToolchainAll.ps1` builds the GIL tree as before, then the same checkout with
    `PCbuild\build.bat --disable-gil` into its own trees (`PCbuild\freethreaded`,
    `PCbuild\obj\freethreaded`).
  - CPython's own `PC\layout --include-freethreaded --include-dev --include-venv --include-stable`
    installs it into `C:\python-freethreaded` (`PYTHON_FREETHREADED_BIN`, 36 MB). It sits last on
    `PATH`, has no `python.exe` and starts with an empty `site-packages`.
  - uv resolves `3.14t` to `C:\python-freethreaded\python3.14t.exe` with
    `UV_PYTHON_DOWNLOADS=never`. `3.14`, `3.14+gil` and a bare `python` stay on
    `C:\temp\cpython\PCbuild\amd64\python.exe`. Measured in `:winamd64` on a fresh v3.14.8
    checkout: GIL build 120-207 s, free-threaded 104-124 s (32 CPUs). `uv build --python 3.14t`
    built a `cp314-cp314t-win_amd64` wheel.
  - The stage stops unless both interpreters report the pin, the `AMD64` marker and their GIL
    state (`Assert-CpythonInterpreter`). Smoke section 2 checks the free-threaded one and uv's
    resolution again.
  - `Select-CpythonImportLib` owns the import-library pick: `python314.lib` for GIL callers,
    `python314t.lib` with `-FreeThreaded`. `Get-SourceBuildPython -FreeThreaded` is new.
  - A toolchain-stage change: every stage after it rebuilds once. The arm64 bundle has no
    free-threaded interpreter yet (BACKLOG CON74).

## 2026-10-07 — `:latest-rocm` installs one ROCm tree again: every package name carries `ROCM_VERSION`

- **The bug.** `setup-rocm-repo.sh` installed versionless metapackages (`amdrocm-core-dev`,
  `-runtime-dev`, `-blas-dev`, `-dnn-dev`, `-hipblas-common-dev`, `-fft-dev`, `-rccl-dev`,
  `-sparse-dev`, `-solver-dev`). AMD's `stable` suite is rolling and gained ROCm 10.1 on
  2026-09-30, so each one resolved to `10.1.0-3` while `versions.env` pins `ROCM_VERSION=10.0`.
  `amdrocm-migraphx` 2.17.0+rocm10.0.0 still pulls the 10.0 libraries, so the image carried two
  trees: `apt-get install -s` selected 262 packages of 10.1 and 73 of 10.0.
- **The fix.** `rocm_packages` builds the list from `ROCM_VERSION` and `MIGRAPHX_VERSION`.
  - The nine libraries are `amdrocm-<name>-dev10.0`.
  - MIGraphX is pinned through apt: `amdrocm-migraphx{,-dev}=<ver>+rocm10.0.*` for 10.0, and
    `amdrocm10-migraphx{,-dev}=<ver>-*` from 10.1, where AMD renamed it.
  - The ASAN package stays `amdrocm-asan${ROCM_VERSION}`.
  - An unknown release, or a `ROCM_VERSION` that is not `X.Y`, fails before the first download.
  - `Dockerfile.amd` now passes `MIGRAPHX_VERSION` to the script.
- **New hard gate.** After the last install, any installed `amdrocm*` package whose name carries a
  release other than `ROCM_VERSION` fails the build and is listed.
- **Proof.** `apt-get install -s` against the live repo in `:latest`, through the script's own repo
  setup.
  - The 10.0 list selects 251 packages: 249 named `…10.0` and the two MIGraphX ones at
    `2.17.0+rocm10.0.0`.
  - With ASAN it selects 281, again all 10.0.
  - A real install of `amdrocm-hipblas-common-dev10.0` passes the check, and adding its 10.1 twin
    fails it.
- **Tests.** New `test-rocm-packages.sh` (22 assertions) and 13 `rocm-stack.*` mutations, all
  biting. The family is declared in `gate-proofs.allow`.
- **Docs.** `linux-accelerator-images.md` § *The ROCm release is in every package name*; row 3 of
  the ROCm sweep table (assert the installed versions) is done.

## 2026-10-07 — Renovate names the pins it skips, and eight skipped pins are readable again

- **Eight annotated pins were invisible to every report.** The custom manager reads
  `versions.env` and `tool-pins.env` with `semver` unless an annotation names a scheme. A
  value semver cannot parse is skipped as `invalid-value`, and a skipped dependency is never
  behind. So `ROCM_VERSION=10.0` hid TheRock 10.1 (released 2026-10-05) from the 2026-10-07
  bumps. The other seven were `VULKAN_VERSION`, `ABSEIL_VERSION`, `NASM_WINDOWS_VERSION`,
  `PANDOC_VERSION`, `PY_PATCHELF_VERSION`, `PY_PACKAGING_VERSION` and `BINARYEN_VERSION`, as
  the new list showed over the unfixed tree. Each annotation now names `loose`, `pep440` or a
  `regex:`. `UBUNTU_VERSION` was read, and now names `ubuntu` so only an LTS counts as stable.
- **Newly visible:** binaryen 133, Vulkan SDK 1.4.363.0, pandoc 3.12 and TheRock 10.1.
- **Five independent pins had no annotation at all**, and four of them hid a release: x265 4.2 (bitbucket-tags), the
  freedesktop runtime 25.08/26.08 for the flatpak (gitlab-tags), Chrome for Testing 155.0.8059.39
  (a new `custom.chrome-for-testing` datasource, Stable channel), plus HailoRT and TAPPAS (current
  at 5.4.0). The pins still left unannotated, and why, are in docs/dependency-updates.md.
- **A value pin no longer moves to npm's integrity hash.** npm reports `newDigest` (the
  tarball's `sha512-…`) on every update, and the planner preferred it over `newValue`, so the
  report showed Renovate 44.142.1 as `sha512-prNFz`. An apply would have written that into
  `RENOVATE_VERSION`, had the approval rule not refused it. Only a digest pin moves by digest.
- **`renovate-local.sh` ends its report with a NOT CHECKED list.** It names every dependency
  Renovate skipped or failed to look up, with the reason and the file. By-design skips (path
  dependencies, `disabled`, `unspecified-version`, …) are counted on one line. The planner's
  new `skipped` mode reads them, and `test-renovate-local.sh` covers both kinds.
- **`test-renovate-annotations.sh` parses every annotated value with its scheme**, so a value
  Renovate would skip fails before any run. It catches the old `ROCM_VERSION` line.
- Renovate keeps updating itself: `RENOVATE_VERSION` and `RENOVATE_NODE_VERSION` are annotated
  like every other pin (docs/dependency-updates.md § *A skipped pin is not up to date*).


## 2026-10-07 — The Renovate bumps of 2026-10-07: every patch and feature release (CON72)

- **Owner choice: bump everything Renovate reported that is a patch or feature release.** The
  report was `custom.regex` plus the default managers over the hub. Every pin was moved by hand with
  its paired SHA256, commit or source change. Each SHA256 comes from a full download and was
  checked against a second source: GitHub's asset digest, the publisher's sums file, python.org,
  NVIDIA's redist manifest, `releases_linux.json` or the PyTorch index.
- **Toolchain.** LLVM 23.1.3 on both lanes (`LLVM_COMMIT` 0d261d1c), Rust 1.99.0, CPython 3.14.8,
  CMake 4.4.4, uv 0.12.23 (and its installer pin).
  - Both AArch64 size patches still apply to 23.1.3, and the patched file passes
    `Build-LlvmFromSource.ps1`'s assertions.
  - uv 0.12.23 offers `3.14.8t` for linux x86_64/aarch64/riscv64 and windows x64/arm64 (CON66).
  - **The CPython clang patch is gone.** 3.14.8's `PC/pyconfig.h` names clang by
    major.minor.patch itself; `Build-ToolchainAll.ps1` still refuses a `sys.version` without
    `AMD64`.
  - Consumers that gate rustc's stamp (OmniAccelerANT `check-rust-toolchain.sh`) follow once they
    move their hub pin after the image is published.
- **Media.** TVM v0.27.0, IREE v3.12.0, onnxruntime-genai v0.17.0, LiteRT-LM 0.18.0, PyAV 19.0.1,
  OpenVINO 2026.4.1, ComputeLibrary v53.3.1, libpng 1.6.59, AMF headers v1.5.3.
  - **`TVM_COMMIT` is now the v0.27.0 tag's commit, and must never be emptied.** apache/tvm also
    has a branch `v0.27.0`, and `clone --branch` takes the branch.
  - **GenAI is 0.17.0, not Renovate's 0.17.1**, which is on PyPI but has no GitHub tag. Its
    `D3D12Core.dll` now comes from a NuGet restore into `__nuget`; the Windows sidecar filter
    matches it.
  - **protoc is 36.1 and Python protobuf 7.36.1, not Renovate's 36.2.** Both stay slaved to
    LiteRT-LM 0.18.0's `LITERTLM_PROTOBUF_TAG`, which `bump_versions.py` can now read.
  - **LiteRT-LM 0.18's GPU DLLs import `webgpu_dawn.dll`.** The rocm lane stages and pins that
    file instead of `libwebgpu_dawn.dll`.
- **Apps.** torch 2.14.1 and torchvision 0.29.1 (with the rocm source commits and the win-arm64
  wheel), llama.cpp b11460, Ollama 0.40.0, Flutter 3.47.6, cuDNN 9.27.0.42.
  - llama.cpp b11461 had a tag and no release yet; b11460 is the newest build with both zips.
- **Tools.** ruff 0.16.10, syft v1.54.1, Renovate 44.140.0, meson 1.12.1, scikit-build-core
  1.1.1, setuptools-scm 10.3.4, cargo-tarpaulin 0.37.5, Git for Windows 2.56.0, lavapipe 26.2.4,
  the `ubuntu:26.04` digest, `docker/dockerfile` 1.27.1.
  - **APISIX 3.19.0** for the llm-stack gateway: the gateway e2e passed 79 of 79 on it (and on
    3.18.0 before), so `geniex_hook.lua` is proven on 3.19.0.
- **Consumers follow before the next chain.** OrchestrANT pins ruff 0.16.10, torch 2.14.1 and
  torchvision 0.29.1, and onnxruntime-genai(-cuda) 0.17.0; the hub's consumer-pins gate is red in
  its lint lane until it does. Its `uv.lock` also needs iree-base-compiler 3.12.0, because a 3.12
  runtime does not load a 3.11 VMFB.
- What only a chain can prove is BACKLOG CON72.

## 2026-10-07 — `git-sync-branches.sh` moves third-party submodules by default

- **Owner decision: the newest commits everywhere, not just in the family's repos.** Every
  submodule now goes to the tip of its `branch =`. A library held at a release declares that
  release branch, as AccelerANTgine does for FUZZTEST.
- **`--owned-only` replaces `--all`** and keeps the earlier behaviour: submodules under another
  owner stay at their recorded commit.

## 2026-10-07 — `git-sync-branches.sh`: every checkout on its branch tip

- **New entry point `linux/scripts/git-sync-branches.sh`.** It checks out the superproject's
  default branch and, recursively, each submodule's `branch =` (or its remote's default),
  fast-forward only. OmniAccelerANT needed it after a pull left its submodules detached.
- **Only the superproject owner's submodules move.** Third-party ones stay at their recorded
  commit unless `--all` is passed. Dirty trees are skipped, and a diverged branch fails the run.
- **It commits no gitlink**, so it is not the forbidden bare `git submodule update --remote`.
  It lists what drifted from the recorded commits.
- `test-git-sync-branches.sh` runs it against bare-repo fixtures under two owners.

## 2026-10-07 — DeepStream is in every amd64 nvidia build (CON42)

- **Owner decision: DeepStream ships with every `:latest-nvidia` build, at full size.**
  TensorRT 10's builder resources for every GPU generation stay (2.6 GB), so the RTX 2080's
  sm_75 keeps working.
- **`stage-defs.sh` now defaults `ENABLE_DEEPSTREAM=true` for an nvidia chain on an amd64
  build platform**, the way it defaults `ENABLE_TENSORRT=false`. Until now every run had to ask.
  - `ENABLE_DEEPSTREAM=false` opts a run out.
  - An arm64 (Jetson) nvidia build gets no default, because `deepstream.sh` refuses arm64
    (phase 7).
  - A default or rocm chain still refuses the flag.
- `test-gpu-variant.sh` covers the default, the opt-out, arm64 and rocm. Two new mutations
  bite.


## 2026-10-07 — The Windows clang-format check can gate

- **`Invoke-ClangFormatCheck` only ever reported.** BeschleunigerBallett swept its sources to zero
  deviations with clang-format 23.1.1 (d59d210f) and re-counted them in its own `Build-Windows.ps1`
  to fail the build.
- **Two switches, the default unchanged:**
  - `-FailOnDeviation` throws on any deviating file, and on a missing clang-format instead of
    skipping.
  - `-ExpectedVersion` refuses a clang-format of another release (CON71).
- **The report no longer names BB's backlog entry.** `WindowsFormatting.ClangFormatCheck.Tests.ps1`
  covers both switches and the default.


## 2026-10-07 — A consumer's CMake sccache goes through the guarded launcher

- **`Cache.cmake` handed CMake the bare `sccache`.** When its server died, every compile of
  the job failed (BeschleunigerBallett run 37509585546, `Connection refused`), and BB patched
  around it in its own `ProjectOptions.cmake` (05c7a338).
- **`myproject_enable_cache` now sets the hub's `sccache-launcher.sh` off Windows**, which
  retries once and then compiles directly. ccache and Windows keep their binary.
- `test-cmake-cache-launcher.sh` covers sccache, ccache and no cache, and the new mutation
  `sccache.cmake-guarded-launcher` bites. BB's override becomes a no-op once its hub pin
  includes this.


## 2026-10-06 — Every LLVM tool is the pinned release (CON71, in source)

- **Owner decision: no LLVM tool may come from another version**, clang-format included.
  It reverses CON15, which kept `clang-format` and `llvm-config` at LLVM 21.
- **Linux, measured on the published `:latest`:** 86 unversioned `/usr/bin` LLVM names were
  Ubuntu's LLVM 21, among them `clang-format`, `/usr/bin/clang-tidy`, `clang-cl` and `llvm-config`.
- **The package stage diverts every one of them.** `wire_pinned_llvm_tools` points each name the
  pinned LLVM has into `/usr/local/llvm-target/bin` and moves the rest off `PATH`. The `-NN` names
  stay LLVM 21 for explicit callers.
- **The toolchain stage builds lldb and installs the LLVM utilities**, so `lldb`, `FileCheck`,
  `yaml2obj` and `llvm-tblgen` are 23.1.1 too. This rebuilds LLVM on all three arches.
- **The compiler smoke grades 26 tools against `LLVM_RELEASE`**, no longer against clang's own
  version, and fails any distro LLVM left under an unversioned name.
- **Windows:** IREE's `clang`, `llvm-link` and `FileCheck` and the MSVC `llvm-symbolizer`
  (all 23.0.0git) came first on `PATH`.
  - The entrypoint now puts `C:\llvm-patched\bin` first.
  - The patched LLVM installs its utilities, so `FileCheck` comes from it.
  - `Test-Toolchain.ps1` and `Test-Container.ps1` check every LLVM tool against the pin.
- **Proven before the chain:**
  - The wiring on a throwaway `:latest`: 86 names moved, a reinstall kept them, clang++ still links.
  - An LLVM 23.1.1 configure with the new flags installs all 13 missing names.
  - The new entrypoint on `:winamd64`: 20 of 21 tools pass, and only IREE's `FileCheck` waits for
    the rebuild.
  - Seven new mutations, all caught.


## 2026-10-06 — The chain wheels are proven once in every `:latest` child (CON52 closed)

- **The fix shipped with the `:latest` of 2026-10-03.** Its three children come from one chain
  run (`20261002-211215-63e1803b`, hub b4d5fdd5), which carries 9ff5e2a3:
  `reconcile_local_wheels` is the one install point, and `assert_chain_wheels_installed` fails
  the torch stage, under `set -Eeuo pipefail`, when a staged wheel is not the venv's.
- **Read back from the published venvs on 2026-10-06.** In amd64 and arm64 (under QEMU), every
  chain wheel is installed from its `/opt/wheels` file: `ai-edge-litert`, `onnxruntime-genai`,
  `iree-base-runtime`, `av`, `libcamera`, TVM and the arch's ORT. torch and torchvision come
  from the lock. The riscv64 child was published from the same run.

## 2026-10-06 — riscv64 consumer lanes are in place; Flutter is a new row (CON48 closed)

- **The hub half and three consumers have been green since 2026-10-01:** `setup-riscv64-cross`,
  `container-ci-riscv64.yml`, `lib/riscv64-cross.sh` and the CMake toolchain, used by OxidANT,
  AccelerANTgine and BeschleunigerBallett. The Vulkan-variable override went 2026-10-06.
- **OmniAccelerANT's lane needs a riscv64 Flutter engine, which upstream does not publish**
  (flutter/flutter#99963). That is CON70, blocked on an owner decision.


## 2026-10-06 — Every test runs on every arch lane (CON50 closed)

- **The owner goal of 2026-10-01 is met in all six consumers.** The last open parts closed
  this week:
  - OmniAccelerANT's release APK runs on the emulator in CI (83f4596).
  - OrchestrANT's `benchmarks/tests` joined `testpaths` and runs on every lane (7e0d47c,
    green on 80a587f).
  - WebDavClient's client has real unit tests (a9ef2cf).
- **What is left belongs to CON64:** BeschleunigerBallett's Windows arm64 GPU suites validate
  once a published `:winarm64` carries the validation layer. The row moved there.


## 2026-10-06 — The published `:latest-rocm` passes the three media checks (CON51 closes)

- **What was open.** The rocm chain of 2026-10-02 (hub b4d5fdd5) republished
  `:latest-rocm`, amd64 manifest `bdfcb731…`. Nobody had read its runtime smoke verdicts
  for the 2026-10-01 media fixes.
- **Measured instead, on the published image.** Pulled on 2026-10-06, created
  2026-10-02 20:50. The three checks ran as `smoke-runtime-image.sh` runs them:
  - `check_no_libunwind_closure`: none of 1487 shared objects under `/opt` and
    `/usr/local` needs `libunwind.so.8`;
  - `check_lavapipe_subgroup`: `LP_NATIVE_VECTOR_WIDTH=256`, and lavapipe reports
    `subgroupSize 8` (CON44);
  - `_gst_check_blacklist`: the GStreamer registry blacklists nothing, and
    gst-validate's SSIM override writes 3 frames (CON47).
- **Every variant now has GStreamer and libcamera without libunwind** except
  `:latest-nvidia`, which gets them from the chain run CON42 waits on.

## 2026-10-06 — A consumer's pytest stack ships in the `:winarm64` wheel store (CON67)

- **OrchestrANT's arm64 lane fetched its test runner from PyPI**, unpinned, at cross-build
  time: pytest and six plugins for win_arm64.
- **The merge stage stages them now.** `versions.env` pins 31 cp314 wheels by URL and SHA256
  (`PYTEST_WINDOWS_ARM64_*`). They are pytest 9.1.1, pytest-cov 7.1.0, pytest-benchmark 5.2.3,
  pytest-html 4.2.0, pytest-md 0.2.0, pytest-md-report 0.8.0 and requests 2.34.2, with their
  closure. `Copy-Arm64TorchWheels.ps1` stages them beside the torch stack and checks the
  three native ones' target arch. Every SHA256 equals PyPI's.
- **`Test-Arm64Bundle.ps1` proves them on the device**: an offline install into the bundle's
  interpreter, then an import, in a bundle that carries them.


## 2026-10-06 — The free-threaded Python ships in `:latest` (CON66)

- **Every `3.14t` leg downloaded its interpreter.** OrchestrANT's and WebDavClient's
  free-threaded legs had uv fetch a `3.14.Nt`, its patch unpinned, on every run.
- **The package stage installs it now, on all three arches.** `install_free_threaded_python`
  runs `uv python install <PYTHON_VERSION>t` into `/opt/python-freethreaded`, outside uv's
  store, and links `/usr/local/bin/python3.14t`. uv checks the download against the SHA256
  its pinned release embeds. The stage stops unless the interpreter reports
  `PYTHON_VERSION` with the GIL off.
- **The smoke gate checks it** in a `free-threaded-python` contract row, with no exemption.
- Proven in a `:latest` container: `uv venv --python 3.14t` used it with
  `UV_PYTHON_DOWNLOADS=never`, and a plain `3.14` request still took the GIL build.


## 2026-10-06 — cargo-audit, cargo-deny and cargo-tarpaulin ship in `:latest` (CON65)

- **Every OxidANT run built them from crates.io.** `cargo_security_checks.sh` and
  `cargo_coverage.sh` ran `cargo install` for all three on every run; no image carried them.
- **The package stage installs them now, on amd64 and arm64.** `install_cargo_qa_tools`
  downloads each upstream release binary and verifies it against a new
  `CARGO_*_LINUX_{X86_64,AARCH64}_SHA256` pin; cargo-audit's aarch64 build is a glibc one.
  A missing pin or a failed download stops the stage. riscv64 ships none: no upstream
  binary, and its lanes cross-build on amd64.
- **The smoke gate checks them.** A `cargo-qa-tools` consumer-contract row compares each
  binary's reported version with its pin, exempt on riscv64 and re-checked by its own fact.
- **The scripts skip a tool the image already has.** `cargo_install_pinned` in
  `_cargo_wrapper.sh` builds one only when the pinned version is not on `PATH`. A plain
  `cargo install` would fail on a binary cargo did not install, so consumers need this hub
  commit before the image publishes.
- Renovate no longer auto-applies their bumps: each version now moves with two SHA pins.
  `docs/image-decisions.md` records why CON20's "stay lane-installed" no longer holds.

## 2026-10-06 — The WebRTC loopback no longer fails a run whose frames arrived (CON68 closes)

- **What the failures were.** Classified across 25 loopbacks under load, every failure looked
  the same:
  - the consumer reached EOS after 2.15 s, the same as the passing runs, so its 60 frames
    at 30/s had arrived;
  - its only error was webrtcsrc's own signaller in teardown, `send failed because
    receiver is gone` from `imp.rs:1736`;
  - gst-launch then exited 1.
- **How often.** 1 run in 30 idle and 5 in 25 under load. The race is upstream, in
  gst-plugins-rs, not in the image's WebRTC.
- **Two fixes were measured first and dropped.**
  - Waiting for the producer's registration did not help: it is listed 28 ms after the
    port listens.
  - One retry still failed 3 times in 30 under load.
- **`Get-GstLoopbackTeardownError`** passes a consumer that exits 1 only when all of
  these hold:
  - it reached EOS;
  - its frames flowed for at least `Frames/30` s;
  - every element error is `webrtcsrc0`'s, and the signaller's is that teardown message.
- **The smoke test prints such a pass as a `[WARN]`**, so the rate stays visible.
- **Tests.** Five harness tests, built from a real failing run's logs, cover the pass and
  the four ways it must still fail. 25 loopbacks under load had no failures, and 6 of them
  passed with the error named.

## 2026-10-06 — The Vulkan validation layer in `C:\runtime\vulkan-layers` (CON64)

- **arm64 had no layer to stage.** The image's Vulkan SDK 1.4.357.0 ships `VkLayer_khronos_validation`
  as x64 only (`Bin-ARM64` lacks it), and LunarG's ARM64 SDK installer is an ARM64 executable the
  amd64 container cannot run. BeschleunigerBallett's Windows arm64 GPU suites therefore ran
  unvalidated.
- **The merge stage now stages it on both arches.** `Build-VulkanValidationLayers.ps1` copies the
  SDK's layer on amd64 and, on arm64, builds Khronos Vulkan-ValidationLayers at
  `vulkan-sdk-<VULKAN_VERSION>` with the dependency commits its `known_good.json` pins.
  `Build.VulkanValidationLayers.Tests.ps1` covers the dependency plan and the manifest check.
- **The device gate loads it.** `Test-Arm64Bundle.ps1` forces the layer into a `vulkaninfo`
  instance when the bundle carries it; an older bundle is named and not counted, so the floor stays
  12 until `:winarm64` is republished. The bundle README says how to register it.

## 2026-10-06 — WiX's firewall extension ships in `:winamd64`'s final stage

- **Consumers' MSIs can declare `fw:FirewallException` now.** `windows/Dockerfile` runs
  `wix extension add --global WixToolset.Firewall.wixext/$WIX_FIREWALL_EXT_VERSION`.
  - The pin is new in `versions.env` (7.0.0).
  - Renovate's WiX 7 lock and `bump_versions.py`'s same-major rule cover it, like the
    UI extension.
- **It lands in the final stage, not in base beside the UI extension.** A change to base
  rebuilds the whole chain; the final stage rebuilds in minutes, as it did for the Vulkan
  loader (CON25). `Build-Buildkit.ps1` passes the pin with the final stage's other args.
- **The smoke gate asserts it** in section 4 (`WiX firewall extension`).
- **A process-isolated container has no Windows Firewall.** `MpsSvc` and `BFE` are disabled
  in the image, so an exception installs there only with `IgnoreFailure='yes'`.
  OmniAccelerANT's cat cam MSI carries one, LAN-only and bound to its exe, and its install
  test passed 14 of 14 in the image with it.
- **Published the same day as `sha256:ea8c3c6e`**, with `Build-Buildkit.ps1 -Stages final
  -PushRef …`. Only the final stage was rebuilt, and the push took 5 s. The first attempt's
  smoke gate stopped on one WebRTC loopback failure, filed as CON68. The retry's gate had
  no failures.

## 2026-10-06 — `:winamd64` republished: WebRTC works, Rust is pinned, ripgrep ships (CON60 closes)

- **What the image is.** A local BuildKit chain from hub f4c0e2be, on a host whose
  Stevedore had first been repaired (Phase R: the patched runhcs shim, buildkitd's
  step-log env and `--config`, containerd's teardown variable). It was pushed with
  `Build-Buildkit.ps1 -PushRef ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`:
  manifest `sha256:5dbc0291`, replacing 2026-10-04's `sha256:65c0dc1f`. OmniAccelerANT's
  Windows lane passed all 26 steps on it before the push finished.
- **What its smoke gate passed: 229 assertions, 1 skipped.**
  - The WebRTC loopback (`webrtcsink -> webrtcsrc` decoding 60 frames over DTLS-SRTP).
  - The lavapipe checks.
  - `Rust at RUST_VERSION` and `flutter_rust_bridge_codegen at FLUTTER_RUST_BRIDGE_VERSION`.
- **In its GStreamer:**
  - all 13 contract plugins;
  - `rswebrtc` and `rsrtp`;
  - `libffi type exports OK`;
  - the DTLS fix 17d22abe89.
- **CON60 closes:** a published `:winamd64` passes the Rust-pin asserts.
- **CON56 is half done:** the image answers `ripgrep 15.2.0`, but the published Linux
  `:latest` does not yet.
- **OmniAccelerANT's cat cam builds and installs on this image.** Its MSI passed 13 of
  13 install checks in it, including a `webrtcsrc` viewer decoding 60 frames.

## 2026-10-06 — `Invoke-ClangTidyFixStep`'s parallel default is bounded by memory

- **The core count alone ran out of memory.** BeschleunigerBallett's Windows x64 lane, with
  the module skip lifted, ran four clang-tidy processes on a 4-vCPU, 16 GB runner, and
  `App.cpp` died with `LLVM ERROR: out of memory` (run 37466488394).
- **Measured per file, peak working set in the `:winamd64` container:** module TUs up to
  10.4 GB (`VulkanRenderer.cpp`), 9.6 (`App.cpp`), 7.1 (`DeferredRasterizer.cpp`). The
  non-module TUs stay at 0.2-1.4 GB, apart from one at 5.3.
- **`-ThrottleLimit` 0 (the default) now means the core count capped at one process per
  6 GB of RAM**: two on a 16 GB runner, ten on a 61 GB, 32-core host. An explicit value
  still wins.

## 2026-10-06 — `Invoke-ClangTidyFixStep` tidies in parallel, and module TUs on request

- **One process per file, `-ThrottleLimit` at a time** (default: the core count). Each file's
  output is logged whole and in file order, and the step names every file that failed, not
  just the first. `-Fix` stays serial: two files' fixes can rewrite the same header.
- **Module TUs are tidyable.** The image's clang-tidy reads the build's BMIs (CON10), so a
  consumer passing `-ModuleImportPattern '(?!)'` tidies its `import`ing TUs too; the default
  still skips them. Measured 2026-10-06 in BeschleunigerBallett's clang-cl Debug container
  build: its 32 module TUs all exit 0 (797 s one at a time), and the step over all 43 `Src`
  TUs takes 112 s on 32 cores.
- `WindowsClang.Common.Tests.ps1` covers both paths with a fake clang-tidy.

## 2026-10-06 — `riscv64_cross_env` stops overriding the Vulkan variables (CON48)

- **The image no longer needs it.** The entrypoint used to leave `VULKAN_SDK` and
  `VK_ADD_LAYER_PATH` on `/opt/vulkan/<version>/x86_64`, which a riscv64 process under
  QEMU cannot use, so `riscv64_cross_env` re-pointed both at `/opt/vulkan/active`.
- **Checked in the `:latest` of 2026-10-03, amd64.** After the entrypoint, `VULKAN_SDK`,
  `VK_ADD_LAYER_PATH`, `PATH`, `LD_LIBRARY_PATH` and `PKG_CONFIG_PATH` all name
  `/opt/vulkan/active`. The two `export`s are gone. On an older image the riscv64 lane
  fails as `docs/riscv64-cross-test-lanes.md` describes.

## 2026-10-06 — the Windows merge stage's lavapipe step reads the version it logs

- **`Install-Lavapipe.ps1` threw on its own log line.** cc1846c2 moved the pins into
  `$pinValues`, and `Write-Host "Downloading the Vulkan loader ${vulkanVersion}: …"`
  kept the old local, which strict mode turns into *"The variable '$vulkanVersion'
  cannot be retrieved because it has not been set"*.
  - The first chain to reach the step, a local `:winamd64` rebuild on 2026-10-06, stopped
    there.
  - That was after the media merge's GStreamer had passed every WebRTC check.
- **Three other strings printed the hashtable.** `"lavapipe $pinValues.MesaVersion"`
  expands `$pinValues` and keeps `.MesaVersion` literally, so the log read
  `System.Collections.Hashtable.MesaVersion`. All four now use `$(…)`.
- **A regression test.** `Lavapipe.Install.Tests.ps1` parses the script and fails when it
  reads a variable that is neither a parameter, assigned, a loop variable nor automatic.
  It fails on the old script, naming `vulkanVersion`.

## 2026-10-06 — `Install-NewHost.ps1` redeploys a shim an update replaced

- **The record no longer stands in for the patch.** `Invoke-StepShim` skipped whenever
  `C:\ProgramData\kataglyphis\shim-patch.json` existed. A Stevedore/containerd update
  overwrites the shim and leaves that file, so a host repaired with Install-NewHost
  stayed on the stock shim, the one `Assert-ShimPatch` refuses. The skip now needs the
  live shim's SHA256 to equal the record's (`Test-RecordedShimLive`). A mismatch is
  logged and redeployed.
- Seen on 2026-10-06. Stevedore's 2026-09-21 update had wiped four things on this host:
  - the patched shim, replaced by the stock one at 25 975 296 B;
  - buildkitd's step-log environment;
  - buildkitd's `--config`;
  - containerd's teardown variable.
- Tests: `NewHost.ShimRecord.Tests.ps1`, 4 cases: a match, a shim the update replaced,
  a lowercase hash, and a missing, unreadable or hash-less record.

## 2026-10-06 — `package_archive.sh` builds the deb, AppImage and flatpak it always claimed

- **One release binary, four formats.** `06-packaging/package_archive.sh` wrote the tar and
  stopped: `create_deb()` went on 2026-08-08, and `--flatpak-manifest`, `--desktop-file`
  and `--appdata-file` were checked and never read. Two docs pages still listed
  "tar/deb/AppImage/Flatpak". It now stages the binary as a bundle and hands it to the
  bundle packagers the Flutter lanes use, by `--package-types`.
- **`app-packaging.sh` takes the bundle from its caller.** Seven knobs carry it:
  `APP_PACKAGING_BUNDLE_DIR`, `_VERSION`, `_DESKTOP_FILE`, `_ICON_FILE`, `_OUT_DIR`,
  `_DEB_DEPENDS` and `_APP_ID`. Each keeps the Flutter default when unset.
  - The project's desktop entry is used with `Exec`/`Icon` set per format
    (`app_packaging_adapt_desktop_file`).
  - An icon goes in the hicolor directory of its real size, read from the PNG header
    (`app_packaging_icon_size`); a non-PNG falls back to the old `512x512`.
  - The flatpak copies `lib/` and `data/` only when they exist.
- **Errors where it used to be silent:** an unknown package type stops the run before
  anything is built; `--flatpak-manifest` and `--appdata-file` say they were removed (the
  manifest is generated); the three bundle formats need `--arch`. Their two env rows left
  `lint-env-knobs.allow`.
- **Proof:** `test-package-archive.sh` (stubbed packagers, plus one real deb through the real
  library) and nine `packaging.*` mutations. In `:latest`, OxidANT's release CLI gave all
  four, and each ran: the deb's binary, the AppImage, and the flatpak via
  `flatpak run --command=oxidant` with its desktop entry and 128×128 icon exported.
  OmniAccelerANT's Flutter packages are unchanged: its icon is a real 512×512.


## 2026-10-06 — a crashed staged test names its exit code

- **`Invoke-StagedTests.ps1`**: a binary that dies before its summary used to stop the run
  with "no libtest 'test result:' line" and nothing else. OxidANT's arm64 WARP crash
  (run 36889467167) left only `running 39 tests`. The error now carries the exit code
  with its NTSTATUS name, e.g. `exit -1073741819 (0xC0000005 STATUS_ACCESS_VIOLATION)`.
  It adds the faulting module, offset and exception code when Windows Error Reporting
  logged an event 1000 for that binary since it started. That is best effort, and read from
  the event's data, not its message, which is localized. Each binary's `-> passed …` line names its exit
  code the same way. One new case in `StagedTests.Tests.ps1` proves both halves.
- CON50's OmniAccelerANT row: Chrome is closed (814da16, both Dart suites in Chrome since
  2026-10-05). The APK on an emulator is what stays open.


## 2026-10-06 — Windows-host follow-ups: the mutation gate skips too; the suites pass in the image

- **`verify_mutations.py` on a Git Bash host:**
  - A test that exits 77 is a `skip`, reported with its `SKIP` line. It used to read
    as a vacuous bite, so a Windows pre-push went red for the host, not the code.
  - A survivor is a `skip` too, never `SURVIVED`, when its suite skipped or waived a case
    on this host: the case that would catch it may never have run. The commit hook
    showed the need; four `mutations.*` entries survived there in `_posix_host` cases.
  - The closing line then counts the skips.
  - On Linux nothing changes: exit 77 is a vacuous bite, and nothing is waived.
  - `test-mutation-gate.sh` proves both sides by running the gate as itself and with
    `sys.platform` set to `msys`. Four mutations cover it.
- **`run-tests.sh`** lists its skips before the verdict, so a red Git Bash run still
  says what it never ran.
- **Eight suites failed inside `:latest` on a green tree.** Each test assumed a bare
  CI runner. They pass in the image now:
  - `compiler-cache-launcher`, `media-jobs`, `vulkan-host-sdk-prune` and
    `python-ci-packaging-arm` run copies of their scripts. The copies now point
    `/opt/scripts` at a path that does not exist; the image's real copy used to win
    over the fixture.
  - `compiler-cache` drops every directory holding an `sccache` from `PATH` for its
    "absent" fixture.
  - `cuda-runtime-payload` unsets `PYTORCH_ROCM_INDEX`, which the image exports.
  - `smoke-arch-parity` runs its stubbed pythons with `-S`. The image's venv has
    onnxruntime, and its site-packages start-up imports collided with the stubs.
  - **`verify-runtime-paths.sh` was vacuous wherever `envsubst` was missing**, the
    image included. Both lists it compares came out empty, so it passed having checked
    nothing. A bash `_envsubst` now does the same expansion (`${NAME}` and `$NAME`,
    exported variables only, byte-identical on every form tried). A test with a broken
    `envsubst` first on `PATH` holds it, and `runtime-paths.needs-no-envsubst` proves
    that test can fail.
- `New-PythonAppPackage.ps1` finds wix through `Resolve-WixExe` (`$env:WIX`, then
  `PATH`) instead of a bare `wix`.


## 2026-10-05 — WebRTC works on Windows: libffi, DTLS and the Rust plugins

- **libffi exported zeroed type descriptors on both Windows lanes.** Its meson port
  declares the twelve `ffi_type_*` as bare `dllexport` tentative definitions, which
  clang-cl's `-fno-common` turned into six strong definitions each; `/FORCE:MULTIPLE`
  hid the 60 duplicate-symbol errors and lld-link kept `prep_cif.c.obj`'s zeros. Every
  GObject signal with arguments then skipped its C handler, so `webrtcbin` never
  answered `create-offer`. `-fcommon` joins the C arguments (and the cross lane's
  native file), `/FORCE:MULTIPLE` is gone, and `Assert-LibffiTypeExport`
  (`WindowsMeson.Common.psm1`) reads the shipped `ffi-7.dll` before the plugin gate.
- **DTLS with OpenSSL 4.** `Build-GstreamerFromSource.ps1` carries upstream GStreamer
  17d22abe89 (an empty BIO read signals retry, not EOF) until `GSTREAMER_VERSION`
  moves past 1.29.2, and fails when the hunk neither applies nor is upstream. The
  OpenSSL DLLs gstdtls imports are staged into `<prefix>\bin` on amd64 too.
- **gst-plugins-rs `rswebrtc` and `rsrtp`** are built in a new phase `8b`, as on
  Linux: `gstreamer-$GSTREAMER_VERSION`, plain `cargo build --release --locked`
  (`Get-GstRustCargoPlan`), `--target aarch64-pc-windows-msvc` on the cross lane.
  gstreamer-rs is fetched from its GitHub mirror through a cargo source replacement
  (`Get-GstRustSourceMirrorConfig`, `--config`): gitlab.freedesktop.org served it at
  10-15 KiB/s, and a run stopped after 20 minutes was still cloning.
- **The plugin contract has thirteen entries** (CON28): `dtls`, `srtp`, `sctp`,
  `rtpmanager`, `openh264`, `rswebrtc`, `rsrtp` joined, on both lanes. The gate finds
  each DLL by its exact name, and smoke section 11 ends with a WebRTC loopback
  (`Invoke-GstWebRtcLoopback`, 60 decoded frames over DTLS-SRTP).
- **Smoke floors move by the eight new assertions:** section 11 to 20, the driver's
  defaults to 178 (CPU) and 198 (GPU), inside `Smoke.FloorCalibration.Tests.ps1`'s bounds.
- **meson is pinned to `PY_MESON_VERSION`.** `pip install meson` floated to 1.12.1
  under build-subproject patches written against 1.12.0.
- Docs: `windows-builds.md` (§ libffi's type exports, § DTLS with OpenSSL 4,
  § gst-plugins-rs on Windows), `windows-cross-builds.md`, `failure-modes.md`,
  `image-decisions.md` (CON28), `windows-build-invariants.md`, `windows-host-setup.md`,
  `overview.md`, the licence list.
- Tests: `SourceBuild.GstreamerWebRtc.Tests.ps1` (20 cases, synthetic PEs for the
  libffi guard) and the contract suite at thirteen entries. `code-dupes.allow`
  follows the measurement: 15 new idiom pairs, 20 budgets lowered, 2 stale rows gone.
- Measured on amd64 in a `:winamd64` container: no lld-link diagnostic in the whole
  build, `ffi_call` returns 42 where the old DLL's `ffi_prep_cif` failed, all thirteen
  plugins load, and the loopback decodes 60 frames in 2.1 s. arm64 is unproven (CON63).


## 2026-10-05 — an MSI function and the helper list; CON55 closes

- **`Invoke-MsiPackage`** in `WindowsMsix.Common` builds one MSI from a project's own
  `.wxs` with `wix build`. Every moving value is a preprocessor variable: `Version`,
  `ExeSource`, `LicenseRtf`, `ProductName`, `Manufacturer`, plus `PayloadFiles=1` with a
  generated fragment. It names a missing input before it runs anything, and fails when
  wix reports success without writing the file. Two helpers come with it:
  - `Resolve-WixExe` looks at `-OverridePath`, then `$env:WIX`, then `PATH`.
  - `New-WixPayloadFragment` writes one component per file, in `PayloadFiles` under
    `APPLICATIONFOLDER`, with a `Subdirectory` only where one is given.
- `Invoke-MsixPackage` and `Invoke-MsiPackage` share one private runner,
  `Invoke-PackagerTool`: clear the output, run the tool, fail when no file appears.
  `Resolve-WixExe` reads `$env:WIX` and hands the rest to `Resolve-WindowsSdkToolPath`.
- `New-PythonAppPackage.ps1` renames its script-local `Invoke-MsiPackage` to
  `Invoke-MsiAppPackage`, beside `Invoke-MsixAppPackage`, so it no longer shadows the
  module function of the same name.
- **Proof:** eight Pester cases in `WindowsMsix.Common.Tests.ps1`. A real WiX 7 build in
  `:winamd64` of OxidANT's `main.wxs` gave a 172 KB MSI. `msiexec /a` unpacked it with
  `a&b.dll` beside the exe and a plugin under `lib\gstreamer-1.0\`.
- **"Reach for these before writing a helper"**, in `adopting-in-a-new-project.md` § 8:
  the table of hub functions each consumer once rewrote, moved from OxidANT's
  `AGENTS.md`. All 22 were checked against their modules' exports. One row was wrong:
  `ConvertTo-XmlEscapedText` is internal, and the exported name is
  `ConvertTo-XmlSafeText`.
- `docs/INDEX.md` points at the list, and § 7 says when to call `Invoke-MsiPackage`.
- OxidANT turns both into deletions and moves its pin, which closes CON55.


## 2026-10-05 — the script suites skip on a Windows host, loudly (CON61)

- **`t_skip_unless <what> <cmd…>`**: a suite that needs what Git Bash lacks exits 77
  there with `SKIP [suite] this host lacks <what>`. `run-tests.sh` lists it as skipped
  and leaves it out of the suite count. On Linux the same line fails the suite, and so
  does a stray exit 77, so CI cannot shrink without a red line.
- **`t_needs <what> <cmd…>`** sits right after a `t_case`: on Git Bash it waives that one
  case's failures, and `t_summary` prints how many it waived. 24 suites use it, so the
  cases the host can run still run.
- **Probes:** `t_posix_symlinks`, `t_posix_modes`, `t_posix_python`, `t_is_elf`.
- **Guards:** 39 suites failed on a Git Bash host on a green tree. Eleven skip whole,
  through five guards:
  - `jq`: `test-agentic-loop.sh` and `test-prune-safe.sh`. The latter skipped by hand
    before, and then failed for running zero assertions.
  - Real symlinks: the seven `test-renovate-*`, through `renovate-fixtures.sh`.
  - A POSIX venv: `test-chain-wheels-installed.sh`.
  - `shellcheck`: `test-shellcheck-warnings.sh`.
- **Fixed instead of skipped:**
  - `verify_package_names.py` and `verify_stdout_returns.py` printed `linux\scripts\…`
    on Windows. The first also never matched its CPython table there.
  - `test-shared-config-sync.sh` counts its CRs; Git Bash's grep strips them first.
  - `test-harness-guards.sh` probes the harness file, not `/etc/passwd`.
- On Git Bash, `run-tests.sh` defaults `PYTHONUTF8=1`. Without it, Windows' python wrote
  its code page into the pipe, and every em dash a suite compared turned to `�`.
- **Proof:** `test-host-skips.sh` (26 assertions) and eight mutations (`gate-fixture.*`,
  `script-tests.skip-only-on-git-bash`).


## 2026-10-05 — host-tool pins leave the image's build inputs (CON59)

- **`01-core/tool-pins.env`** now holds the 30 pins no image build reads: shellcheck,
  gitleaks, hadolint, actionlint, mold, binaryen, ruff, syft, Renovate's Node and CLI.
  `Dockerfile.base` bind-mounts `versions.env`, so any edit to it re-keyed the compiler
  image, and a hadolint bump cost as much as a GCC bump. A bump here rebuilds nothing.
- **Readers:**
  - `lint-shell`, `lint-secrets`, `lint-dockerfiles`, `lint-workflows`, `lint-python`,
    `lib/wasm-opt.sh`, `lib/linker-select.sh` and `WindowsWasmOpt.Common` now read
    `tool-pins.env`.
  - `scan-image-sbom.sh` reads both files: the image tag stays in `versions.env`.
  - `renovate-local.sh` parses `tool-pins.env`; it used to `source` `versions.env`.
- **Bookkeeping reads both files:**
  - Renovate's two package rules and both custom managers.
  - `bump_versions.py`, which writes each key back to the file that holds it.
  - `sync_versions.py`'s pin table, which the consumer-pins check uses.
  - The env-knob gate counts `tool-pins.env` as an owner.
- Tests: `test-renovate-annotations.sh` reads both files and asserts that every custom
  manager matches both; `test-env-knobs.sh` gains a `tool-pins.env` owner case; eight
  suites read or fake their pin in the new file. Six mutations re-pointed, one added.


## 2026-10-05 — Windows Rust pinned; five of OxidANT's waiting rows land (CON60, CON55)

- **Windows Rust is pinned to `RUST_VERSION`** (owner decision). `Install-RustToolchain.ps1`
  mirrors `channel-rust-<RUST_VERSION>.toml` instead of `channel-rust-stable.toml`, and
  bakes `flutter_rust_bridge_codegen` at `FLUTTER_RUST_BRIDGE_VERSION` instead of the newest
  release. `Dockerfile.base` declares both `ARG`s above the Rust layer, and
  `Test-Container.ps1` asserts the values rather than a well-formed version. Ran in a
  throwaway `:winamd64` container: `1.98.1-x86_64-pc-windows-msvc`, codegen 2.13.0.
- **`_cargo_wrapper.sh` adds the `safe.directory` guard** (`CARGO_SAFE_DIRECTORY`, default
  `/workspace`, empty opts out, never added twice). Every `cargo_*.sh` driver now sources the
  wrapper, so release, doc, coverage, security and fmt/clippy also get the CARGO_HOME and
  toolchain guards. `test-cargo-wrapper.sh`: 12 assertions, three mutations.
- **`Get-ANTfrastructurePin` moves to `WindowsScripts.Shared.psm1`**, with a
  `-VersionsEnvPath` for tests, and `windows/scripts/rust/Build-Windows.ps1` is deleted
  (owner decision: no consumer; OxidANT owns its Windows Rust build).
- The MSIX trust steps (`Root` as well as `TrustedPeople`, `0x800B0109`, `Get-AppxLog`) move
  into `windows/scripts/certificates/README.md`. `docs/adopting-in-a-new-project.md` § 8
  names `scripts/windows/container/`.


## 2026-10-05 — the push gate counts from develop; lint tools install in one rename

- **pre-push** grades the mutations a push actually adds. git hands the hook each
  pushed ref's remote tip, which becomes `verify_mutations.py --changed --base <tip>`.
  `origin/main` stays the fallback for a new remote ref or an unfetched tip. Counting
  from `origin/main`, which lags `develop` by hundreds of entries, ran every hub push
  for 25 minutes and more, and ended it in `--no-verify`.
- **`download_verified_install`** (`01-core/downloads.sh`) downloads, verifies and
  unpacks in a stage beside the destination, then moves the binary into place in one
  rename. shellcheck, gitleaks, hadolint and actionlint use it. They used to write
  straight into the shared cache, where a parallel mutation job could run half a
  gitleaks: a clean scan failed in hub CI run 37329252097.
- **gitleaks runs on a Windows host.** `lint-secrets.sh` chose its asset by `uname -m`
  alone, so Git Bash fetched the Linux binary and every consumer's lint gates died with
  `Exec format error`. A `GITLEAKS_WINDOWS_X64_SHA256` pin (GitHub's digest, matching the
  release checksums) and an OS check now install `gitleaks.exe`.
- **The image adds `aarch64-linux-android`** to the pinned Rust toolchain
  (`install-rust.sh`), and `smoke-toolchain.sh` checks it (CON58). OmniAccelerANT's
  Cargokit builds with that toolchain now, and its Android lane was adding the target
  on every run.
- Backlog: CON59 (tool pins out of the base closure), CON60 (Windows Rust pin, the
  owner's call), CON61 (host-only suite skips), CON62 (WSL containers, blocked upstream).
- Tests: three new cases in `test-prepush-hook.sh`, one in `test-mutation-gate.sh`,
  and `test-download-verified-install.sh` (15 assertions). Seven mutations, each caught.


## 2026-10-05 — an opt-in linker: `KATAGLYPHIS_LINKER=lld|mold`

- `lib/linker-select.sh`: `linker_select_env` appends `-fuse-ld=<x>` to `LDFLAGS` (plus
  clang's LLVMgold.so for mold) and links the host Rust target through `$CC` with the same
  linker. Unset changes nothing. `cmake_build_prepare_env` and the cargo test/bench/debug
  wrappers call it.
- Fails, never falls back: 2 on an unknown value, 1 on a set `RUSTFLAGS`, a failing probe
  link or an unobtainable mold. mold comes from PATH, else the pinned, SHA-checked 3.0.0
  release (`MOLD_LINUX_*` in `versions.env`, noforward).
- Measured first: lld matches or beats mold on every family build, and mold 2.x cannot link
  AccelerANTgine. The table and the reasons are in `docs/shared-script-libraries.md`
  § *linker-select.sh*. CON57 holds baking mold into the image.
- `test-linker-select.sh`: 22 assertions, and nine mutations that each red it.
- WSL 3's `wslc` was evaluated beside it, against Rancher Desktop. It has faster bind
  mounts and a fixed credential pull. It has no `--privileged`, `--platform` or `--device`,
  so no lane moves (`docs/rancher-desktop-linux-containers.md` § *WSL containers*).


## 2026-10-05 — ripgrep is the family's search tool

- Owner rule: search with `rg`, not `grep -r` or `findstr`, in every repo of the family
  (`AGENTS.md` § *Searching the tree: ripgrep (`rg`)*); the consumer template links it.
- The images get it with their next chain (CON56): `ripgrep` in `setup-package-image.sh`
  with `rg` in its presence check, `main/ripgrep` among the floating scoop tools.


## 2026-10-05 — Windows CodeQL results honour the config's paths-ignore

- `database analyze` applied `paths-ignore` to traced C++ not at all: OmniAccelerANT's first
  complete scan reported 39 of its 63 cpp results, all four high-severity ones among them,
  from the ignored `third_party/AccelerANTgine/third_party`. `Invoke-BuildCodeQL` now drops
  results under the config's `paths-ignore` from each SARIF after the analysis and logs the
  count (`Remove-SarifIgnoredResult`). On that scan's SARIF it drops exactly those 39.
- CodeQL's path semantics: a plain path covers its subtree, `*` one segment, `**` any depth.
  No unfiltered copy is kept, since an uploader that globs `*.sarif` would send both.
- `CodeQL.SarifFilter.Tests.ps1`: four tests; a prefix match without the `/`, a lost `**` and
  a filter that is not written back each red one.


## 2026-10-05 — the Dart gate can test in Chrome

- `flutter_checks.sh --test-platform chrome` runs `flutter test --platform chrome` where the
  image sets `CHROME_EXECUTABLE`, and the VM where it does not (riscv64), so a lane never
  passes on zero tests. The default stays `vm`; an unknown platform is refused.
- `test-flutter-checks-platform.sh` drives the gate with stub `flutter`/`dart` over a tracked
  fixture: four cases, and dropping either branch reds one of them.
- OmniAccelerANT's web lane is the first caller (`docs/consumer-image-contract.md` § Browser
  tests run in Chrome for Testing).


## 2026-10-05 — a CodeQL-traced Windows build runs without sccache

- `Invoke-BuildCodeQL`'s `database create` hung for hours at near-zero CPU. The image's sccache
  server never exits (`SCCACHE_IDLE_TIMEOUT=0`), and one started under the CodeQL tracer keeps
  its client's output pipe, so the Rust extractor's `cargo metadata` waited forever. Killing the
  server freed one call, and the next started a new server and blocked again (OmniAccelerANT).
- `Disable-SccacheForTrace` clears `RUSTC_WRAPPER`, `CC_WRAPPER`, `CXX_WRAPPER` and both CMake
  launcher variables and sets `KATAGLYPHIS_NO_SCCACHE=1` before `database create`.
  `Initialize-BuildCacheEnvironment` leaves the launchers off under the marker, and
  `Get-SccacheStatsText` returns nothing, since asking for stats starts a server. A cache hit
  would also have hidden the compile from the extractor.
- `CodeQL.SccacheOff.Tests.ps1`, four tests; removing each guard reds its own test.
- Proven on OmniAccelerANT's scoped scan on the 2026-10-04 `:winamd64`: from a cold tree,
  `database create` and both analyses finished in 27 min (63 cpp and 10 rust results), with no
  sccache process left. `docs/failure-modes.md` § *CodeQL `database create` hangs for hours at
  near-zero CPU*.


## 2026-10-04 — the riscv64 cross wheel builds through pip, not uv

- `ci_packaging.sh`'s cross mode no longer exports `_PYTHON_HOST_PLATFORM`: uv reads it while
  inspecting the interpreter and refuses `Unknown operating system: linux_riscv64` at both
  `uv venv` and `uv build`, which killed OrchestrANT's packaging step one second in. The target
  tag travels as `PYTHON_HOST_PLATFORM_TARGET` and is set only on the wheel's
  `python -m pip wheel` command; the sdist stays on `uv build --sdist`.
- The arm suite pins both halves: the wheel commands carry the tag, uv's environment never does.


## 2026-10-04 — lavapipe ships in the Windows image and the arm64 bundle

- `Install-Lavapipe.ps1` stages Mesa's lavapipe (mmozeiko/build-mesa, SHA256-pinned;
  the only arm64 Windows build) and LunarG's Runtime Components loader for the target
  arch into `C:\runtime\lavapipe`, registers the ICD in HKLM on amd64 (the loader
  ignores `VK_DRIVER_FILES` in an elevated process) and verifies the PE machines.
- The media merge stage runs it before the bundle manifest, so `BUNDLE-ENV`/`README`
  name the ICD and `LP_NATIVE_VECTOR_WIDTH=256` (Mesa 26.2's BVH sort needs 8-lane
  subgroups, CON44); the image smoke runs `vulkaninfo --summary` and fails without
  llvmpipe, and `Test-Arm64Bundle.ps1` gains the device step (floor 11 to 12).
  - `:winamd64` was republished on 2026-10-04 (digest `65c0dc1f`): the smoke's
    `vulkaninfo --summary` lists the llvmpipe device and the lavapipe step passes;
    the `:winarm64` bundle is published and its device gate passed 12/12 on the Snapdragon X.


## 2026-10-04 — a root directory survives the tar-pipe exclude

- `Invoke-ContainerBuild` gains `-InboundItems` (default `.`): the top-level
  entries to stream. `--exclude` matches at every depth, so a pattern naming a
  root directory (`build`) also dropped
  `third_party/ANTinfrastructure/windows/scripts/build`, and no pattern form
  anchors; a caller omits the root directory from the item list instead.
- The module's contract suite pins the parameter and its forwarding; the
  performance page records the matching rule.


## 2026-10-03 — the riscv64 wheel is cross-built on the native row

- `ci_packaging.sh` gains cross mode (`PACKAGING_CROSS_TARGET=riscv64`): the wheel
  is built on the amd64 row under the five setuptools knobs
  (`CC`/`LDSHARED` = the riscv64 cross wrapper, `CFLAGS` with the staged target
  Python's include dir, `SETUPTOOLS_EXT_SUFFIX`, `_PYTHON_HOST_PLATFORM`), and the
  app-package skip now follows the target, not the host's `uname -m`.
- `python-ci-linux.yml`'s riscv64 row builds the sysroot (`sysroot: true`) and runs
  the packaging step on `linux/amd64` with it mounted; the test step stays on the
  emulated riscv64 image. The emulated compile hung four hours on one Cython unit
  (run 37127505865) and could not fit the 360-minute job.


## 2026-10-03 — a cross lane gates the arm64 bundle on a device per push

- `container-ci-windows.yml` gains `bundle-artifact-name`: the build job packs the image's own
  runtime bundle (`windows/scripts/build/Export-Arm64Bundle.ps1`, ~290 MB zipped) beside
  `Test-Arm64Bundle.ps1`, and a `windows-11-arm` job extracts the zip and runs the gate. The
  bundle's device half was a manual run until now; the floor stays the gate's own default, so a
  device that ran nothing cannot look green.
- The bundle travels as `C:\runtime` (~0.63 GB, 9k files), not the 15 GB image: the export runs in
  the same container the build already pulled.


## 2026-10-03 — the clang-cl ASan runtime follows the target arch

- `cmake/Sanitizers.cmake` picks the ASan link dir and lib names from `CMAKE_SYSTEM_PROCESSOR`:
  MSVC keeps x64 in `lib/x64` with `-x86_64` libs and arm64 in `lib/arm64` with `-aarch64`,
  so an arm64 cross build links Microsoft's runtime instead of LLVM's, whose aarch64 runtime
  the image does not carry. Native x64 configures unchanged.
- `Copy-Arm64VsRuntime.ps1` gains `-Flat`: stage beside a staged test tree's exes instead of
  its `bin\`, which an arm64 ASan suite needs on the runner.

## 2026-10-03 — the arm64 bundle carries the VS runtimes its payloads link

- `Copy-Arm64VsRuntime.ps1` (was `Copy-Arm64AsanRuntime.ps1`) also stages the aarch64
  `vcomp140.dll` from the VS redist: the cp313 torch stack's `torch_cpu.dll` imports the
  MSVC OpenMP runtime, and the arch gate wants a CRT inside the bundle on a cross lane.
- `Test-TargetArch.ps1` counts `python313.dll` as an external: the cp313 wheels target a
  device-provided 3.13 interpreter, which the bundle does not ship.
- The device gate checks both runtimes; a suite case pins the allowance.

## 2026-10-03 — compound extras markers stop reaching pip in the arm64 bundle

- `Copy-TargetPythonDeps.ps1` dropped only extras whose marker began right after the `;`;
  setuptools declares them compounded (`(python_version < '3.14') and extra == 'test-full'`),
  so the first arm64 rebuild with the torch stack sent marker'd requirements to
  `pip download`, where cmd.exe stripped their double quotes and pip rejected the marker.
  The filter now looks anywhere in the marker, and surviving markers go out single-quoted.

## 2026-10-03 — the emulated riscv64 packaging leg stops syncing all extras

- `ci_packaging.sh` honours the lane's `SYNC_EXTRAS` input (mapped to `UV_SYNC_EXTRAS`),
  and the riscv64 row's test and packaging steps share
  `UV_CACHE_DIR=/workspace/.uv-cache`. Without both, the first OrchestrANT packaging
  run resolved 306 packages (all extras, opencv-python and torchvision from git among
  them) and was killed at the 300-minute budget.
- The riscv64 row's ceiling moves 300 -> 360: it covers a cold cache, where the packaging
  leg re-pays the test leg's measured 151-minute source builds beside its 169-minute
  test leg.

## 2026-10-03 — the Ansible fleet-update lane goes live

* **The cat cam joined as the third Pi**: `tabblscatcam` (Raspberry Pi 5,
  Debian 13) — found via mDNS, bootstrapped via `setup-fleet-host.sh tabblscatcam` (values
  from gitignored host_vars, like every host). Its FIRST run was real:
  apt updates applied, a pending bootloader EEPROM update staged, and the
  inline reboot+wait flashed it — `BOOTLOADER: up to date` after, second
  run idempotent. This closes the discovery question: the fleet is three
  Pis (pi-1, pi-2, tabblscatcam), one SpacemiT SBC and one Windows host.
  `ping.yml` learned a second play: the builtin ping cannot run on Windows,
  so the lane proof splits `fleet` (ping) from `windows` (win_ping) —
  summy-server had been failing the lane proof since it joined.

* **The microcontroller updates are now REAL, gated, and in the Sunday run**
  (owner directive): `update_tasmota.yml` flashes the stock plugs ONLY when
  the official release version differs from the installed one — the
  comparison is OURS, because the native `Upgrade 1` was probed live and
  re-flashes even at the same version; after a flash it waits for the
  reboot and asserts MQTT health. `update-bitshake.yml` joined the weekly
  run behind the same kind of version gate (it flashes only when the
  manifest differs, with the magic-byte check and the post-flash health
  gate). The nerdctl toolchain stays REPORT-ONLY by design — it is build
  infrastructure and its upgrade is deliberately confirmed by hand.
  **A real bug found while proving this**: the nested playbook calls ran
  from `playbooks/` where no `ansible.cfg` lives — the inventory never
  resolved, every nested lane silently matched zero hosts and exited 0.
  The Sunday run had been green while doing nothing for the Tasmota,
  bitShake and Windows lanes. Fixed (run from `linux/ansible/`) and
  proven by fresh execution: the winget log carries the run's timestamp.

* **summy-server (Windows 11 ARM Pro) joined the fleet**: managed over
  OpenSSH with `ansible_shell_type: powershell` — WinRM stays closed. Three
  one-time traps, all encoded in `scripts/setup-openssh-ansible.ps1` (run
  once via SSH): the deploy key must go into
  `C:\ProgramData\ssh\administrators_authorized_keys` for an administrator
  account (user `authorized_keys` is ignored), the ACL must be set with
  SIDs not account names (a German-locale Windows does not resolve
  `Administrators`), and OpenSSH's `DefaultShell` must be PowerShell (the
  cmd default breaks ansible module result deserialization — symptom:
  `No start of json char found`). `update-windows.yml` installs
  PSWindowsUpdate from the gallery, applies all updates with
  `-AcceptAll -IgnoreReboot`, reports what remains (Defender signature
  updates are perpetual — new definitions release daily), and reboots
  inline only when the registry says pending. Wired into the weekly run
  via `manage_windows_updates`; a failing Windows lane is surfaced without
  failing the Pi lane. Also fixed in the same pass: both nested playbooks
  (tasmota report, windows update) had doubled `playbooks/playbooks/`
  paths — the tasmota one was silently masked by `failed_when: false`.
* **The stock Tasmota ESP8266 plugs joined the report lane**
  (`report-tasmota.yml`, wired into the weekly run via the `report_tasmota` host_vars flag): version
  against the official release plus an MQTT-health assertion. That assertion
  exists because one plug (`.128`, a NOUS A1T) was found with NO broker
  configured — registered in HA but silently dead. Root cause + fix: its
  `MqttHost` was empty; set via one HTTP command, live-verified by watching
  its `tele/…/SENSOR` messages arrive on the broker. All three plugs sit on
  the current official release (15.6.0, 2026-08-25) and on the ungated
  public OTA channel — unlike the bitShake device, they can self-update,
  and the flash stays deliberate either way.

* **The bitShake update is now a playbook** (`update-bitshake.yml`, on-demand
  — deliberately never scheduled): manifest fetch with the browser-gate
  header bypass, firmware download + magic-byte validation (the manifest
  sha256 is stale), upload through the device's own forms, a version-wait
  with timeout, SMR app install with retry (a first refusal after a flash
  is transient), and a final loud gate on firmware version, meter data and
  MQTT. Proven idempotent against the live, already-updated device
  (`ok=10 changed=0`, plan "firmware current, SMR app installed"). The
  manual procedure and the traps it encodes stay owned by the Home
  Assistant README.

* `playbooks/update.yml` (apt safe-upgrade + autoremove per Pi, reboot only
  when required) runs **Sundays 04:30 Berlin** via a user systemd timer
  (`systemd/`, installed by `playbooks/schedule.yml`, armed 2026-10-03).
  Proven with a real run on pi-1: `ok=14 failed=0` — fully current.
* The host's nerdctl-full bundle was upgraded **2.3.5 → 2.4.1** (containerd
  v2.4.1, buildkit v0.33.1) via `install-nerdctl-full.sh --include-rootful`:
  checksum-verified download, both containerd lanes stopped and restarted
  together, rollback backup in `~/.cache/nerdctl-full-backup`. The install
  warnings ("stale v0.31.2", "user buildkit.service won't start") were both
  an orphaned pre-upgrade daemon holding the user socket — this host has no
  user buildkit unit (rootless containerd for HA + rootful buildkit is its
  topology); reaped, all services verified on the new binaries.
* **Beyond apt**, per gitignored `host_vars` flags (pi-1 carries all three):
  the HA/glances containers update weekly (`compose pull` +
  `--force-recreate` — REQUIRED under nerdctl, which keeps a running
  container on its old image), a report-only nerdctl drift check (the
  upgrade stays deliberate behind `NERDCTL_INSTALL_CONFIRM=1`), and the
  ansible venv upgrades itself LAST so a broken release cannot take down
  the run that installs it.
* **Bootloader EEPROM is now covered too** (Pi 4/5; pi-2 is pre-Pi4 with no
  EEPROM): the playbook queries `rpi-eeprom-update` (exit 1 = update
  available — wording pinned from the tool source, not guessed), stages it
  with `-a` and makes it a reboot trigger. Without this, a bootloader-only
  apt update could sit unflashed indefinitely: the boot-time
  `rpi-eeprom-update.service` stages at reboot, but nothing guarantees a
  reboot happens. Branch logic mutation-tested (fires on rc 1, silent on
  rc 0 and missing register); both Pis ran green with the lane in place.
  The container-recreate tasks now carry an honest note: they report
  `changed` every run because `--force-recreate` (required under nerdctl)
  bounces the stack by design.
* Two traps are encoded in the playbook rather than left for the next
  session: the control node reboots LAST and DELAYED (`shutdown -r +2` — an
  inline reboot kills the running playbook mid-report, so inventory order is
  load-bearing, pi-1 last); and kernel staleness is compared within the
  running kernel's FLAVOR — this host runs `v8-16k+` while `v8-rt+` sorts
  last in `/lib/modules`, so a naive comparison would reboot-loop the Pi
  every Sunday. Debian carries no `/var/run/reboot-required` marker by
  default; the marker check stays for Ubuntu-family hosts.
* The second fleet Pi is discovered and staged (old-gen Pi MAC, Debian 13):
  deploy key generated, `known_hosts` pinned, inventory slot `pi-2`. Its
  address and login live in gitignored `host_vars/` — no LAN topology in the
  repo. It awaits the owner's one-time `ssh-copy-id` (done 2026-10-03, both
  Pis then ran the update playbook green).
* `serial: 1` in the update playbook: never two Pis down at once — pi-1
  carries Home Assistant.


## 2026-10-02 — Ansible lands on pi-1, via pip on the host

* **Installed per the official installation guide**: the `ansible` community
  package 14.4.0 (core 2.21.4) into `~/venvs/ansible` (Python 3.13.5) — the
  venv + pip path the docs prescribe, which is also the only one Ubuntu
  26.04's PEP 668 externally-managed Python permits. Proven with the ping
  playbook: `pi-1` answers over the local connection. Playbooks,
  inventory, `ansible.cfg` and `ssh_config` live in `linux/ansible/`, whose
  README documents the install, the upgrade path and the host facts.
* The first draft ran Ansible in a container next to Home Assistant; dropped
  by owner directive. Two findings worth keeping from that attempt: the
  official EE images (`ghcr.io/ansible-community/community-ee-*`) are
  amd64-only, so they were never an option on this aarch64 Pi; and
  `nerdctl compose run` hardcodes `--tty`, which dies with
  "provided file is not a console" outside an interactive shell.


## 2026-10-03 - the arm64 bundle gets its device gate, and passes it

- New `windows/scripts/build/Test-Arm64Bundle.ps1`: runs the shipped bundle's tools and Python
  on an arm64 device (HailoRT, a GStreamer pipeline, IREE, the offline wheel install, the ORT
  providers, cv2), every step exit-code-checked, with a passing floor so a device that ran
  nothing cannot look green. `Smoke.Arm64Bundle.Tests.ps1` pins the floor logic.
- First device run 2026-10-03 on a Snapdragon X against the published `:winarm64`: nine of nine
  steps pass - HailoRT-CLI 5.4.0, GStreamer 1.29.2, Python 3.14.7 with numpy 2.5.3,
  onnxruntime 1.30.0 (DirectML + CPU) and cv2 5.0.0. CON30's "loads only" no longer holds.

- The arm64 CUDA payload gains nvrtc and cupti (13.4.92, SHA-pinned from the redist) for
  consumers that compile kernels at run time or profile; nvtx is header-only on
  windows-arm64. Forwarded in Build-Buildkit.ps1, ARGs in Dockerfile.nvidia, and the
  staging script asserts both.

- The arm64 bundle ships Microsoft's aarch64 ASan runtime (clang_rt.asan_dynamic-aarch64.dll
  + the dbg twin) from VS 2026's toolset: staged in the merge stage, machine-checked by the
  arch gate, asserted by Test-Arm64Bundle.ps1 on the device. The smoke probe still skips on
  the x64 host, now for the real reason - it must execute an aarch64 exe.

- The arm64 bundle's wheel store gains the cp313 win-arm64 torch stack (torch
  2.14.0+cpu, torchvision 0.29.1a0+cpu, pillow, MarkupSafe and the pure-python
  first-touch deps), SHA-pinned from pytorch.org/PyPI. Upstream builds no cp314
  win-arm64 wheel (stable, test and nightly checked), so the bundle's own 3.14
  interpreter cannot install them - they serve a device that brings its own
  cp313 interpreter.


## 2026-10-02 - the Python lane grows a riscv64 row: the riscv64 image under QEMU

- `python-ci-linux.yml` takes `arches: riscv64`: the row registers QEMU's binfmt
  handler (`setup-riscv64-cross` with `sysroot: false`), runs the riscv64 image
  under QEMU on an amd64 runner, and tests only - static analysis, packaging and
  the docs build stay `x64`'s. The row carries its own 300-minute budget -
  the first packaging run hit the original 180 and was cancelled mid-way
  through the wheel build.
- New input `test-extras`, backed by `ci_tests.sh`'s `SYNC_EXTRAS`: every leg
  syncs only those extras. A riscv64 leg needs it because the full extra set
  builds wheels from source under emulation.
- Artifacts are named per arch (`test-reports-<arch>`, `packages-linux-<arch>-...`),
  so the riscv64 row cannot collide with `x64`'s uploads.
- **Follow-up (owner request same day): packaging on the row is opt-in through
  `package-emulated`.** A Cythonized app's wheel is arch-specific - without it
  the riscv64 wheel existed for no arch but this one. The wheels build under
  QEMU with the row; the app packages of a `packaging/app.json` app stay
  amd64-arm64 (`ci_packaging.sh` warns there: the image's AppImage tooling has
  no riscv64 build). Consumer: OrchestrANT's `linux-riscv64.yml`, renamed
  `Linux riscv64 · build + test`.


## 2026-10-02 - CON34: the HIP/<cmath> overlay installs with TheRock, and MIGraphX drops its copy

- `Dockerfile.rocm` now installs `windows/scripts/hip/` with TheRock: the headers into
  `C:\runtime\opt\hip-msvc-cmath`, both `*.cfg` beside TheRock's `clang.exe` - instead of the
  end of `Dockerfile.rocm-llama`. The move re-keys the rocm chain, which the next rebuild pays
  anyway.
- MIGraphX no longer passes its own `-isystem` overlay: `Write-HipMsvcCmathOverlay`,
  `Get-MigraphxCmakeArgs -HipMathOverlay` and the parity test are gone. The next rocm build
  proves MIGraphX compiles with the configs active (never measured before).


## 2026-10-02 - CON31's `:winamd64-rocm` record: the redistribution question is closed

- The Redistribution section of `docs/windows-rocm.md` still said the public push "is an
  owner decision to take before `:winamd64-rocm` is pushed" - stale since the tag was
  published on 2026-09-28. The record now states the decision and keeps
  `LicenseRef-Proprietary-EULA` for the runtime in `docs/deps/deps.json` (the id describes
  the licence, not the permission).


## 2026-10-02 - clang-tidy skips the files the build never compiled

- `Invoke-ClangTidyFixStep` now reads the compile database and tidies only the files
  it names. An option-gated subdirectory (`KATAGLYPHIS_BUILD_KOMPUTE_PLAYGROUND=OFF`
  in BeschleunigerBallett) is not compiled, so its files have no compile command;
  tidy ran them with defaults and failed the step on the first include
  (`'kompute/Algorithm.hpp' file not found`, run 36979869674). Skipped files are
  named in the build log.
- Regression: `windows/scripts/tests/WindowsClang.Common.Tests.ps1`.


## 2026-10-01 - The torch stage installs the chain wheels once, and proves them (CON52)

- **The detour is gone.** The 2026-10-01 chain installed `ai-edge-litert` and
  `onnxruntime-genai` from `/opt/wheels` before `uv sync`, which removed them again (an
  exact sync drops what `--no-install-package` excludes), and `reconcile_local_wheels`
  installed them a second time. `build_uv_sync_args` and `run_uv_sync_with_fallback`
  now install nothing, and `collect_locked_local_wheels` is gone: `reconcile_local_wheels`
  is the one install point.
- **`assert_chain_wheels_installed`** runs after the torch pins and fails the stage
  (`CHAIN-WHEEL FAIL`) unless every staged wheel is the venv's distribution of its name,
  by uv's `direct_url.json`. Exempt: TVM, source-bound OpenCV, riscv64 IREE.
- **OrchestrANT's lock stays on PyPI.** Routing a package to `/opt/wheels` makes
  `uv lock` fail off the image (`Failed to read --find-links directory`), and no marker
  tells the image apart. Doc: `docs/linux-cross-builds.md` § The chain wheels and the
  app's lock; failure mode `CHAIN-WHEEL FAIL`.
- Suite `test-chain-wheels-installed.sh`; six `wheels.chain-*` mutations.


## 2026-10-01 - The entrypoint leaves the Vulkan variables on `/opt/vulkan/active` (CON48)

- **Measured** in the published `:latest` children: the entrypoint sources LunarG's
  `setup-env.sh`, which resolves `VULKAN_SDK` to `/opt/vulkan/<version>/<uname -m>` and puts
  that dir into `VK_ADD_LAYER_PATH`, `PATH`, `LD_LIBRARY_PATH`, `PKG_CONFIG_PATH` and
  `CMAKE_PREFIX_PATH` (`x86_64` on amd64, `aarch64` on arm64). The image ENV alone
  (`--entrypoint bash`) keeps `/opt/vulkan/active`; the login shell sources nothing. A riscv64
  process under QEMU in the amd64 image re-roots `/opt/vulkan/active` into its sysroot, but
  not the `x86_64` dir, which is why `riscv64_cross_env` had to override two of them.
- **`vulkan_env_prefer_active_link`** (`01-core/vulkan-env.sh`) rewrites every component
  under the link's target back to `<root>/active`, without duplicating an entry the image ENV
  already has. `vulkan_env_source`, the entrypoint, and a new `vulkan_env_source_script`
  (now used by `lib/cmake-build.sh` and `lib/ctest-run.sh` for `--vulkan-setup-script`)
  call it. Natively nothing changes: the link resolves to the same dir. Checked by mounting
  the new files over the published amd64 and arm64 children: `vkarch=neutral`, the loader
  finds `VkLayer_khronos_validation.json` through the link, `glslc` runs.
- **The boot smoke** no longer requires `VULKAN_SDK` resolved past the link. It proves the
  entrypoint sourced `setup-env.sh` through `VK_ADD_LAYER_PATH` (`vkadd=yes`), and fails any
  of the six variables with a `/opt/vulkan/<version>/` component (`vkarch=`). The published
  children print `vkarch=VULKAN_SDK,VK_ADD_LAYER_PATH,PATH,LD_LIBRARY_PATH,PKG_CONFIG_PATH,CMAKE_PREFIX_PATH,`,
  so the next chain cannot ship the old shape.
- Suite `test-vulkan-env-active-link.sh`, probe cases in `test-runtime-image-gates.sh`, nine
  mutations (`vulkan.env-*`, `lib.*-vulkan-script-on-link`, `boot.vulkan-*`). Docs:
  [`failure-modes.md`](failure-modes.md#vulkan-env-names-an-arch-specific-sdk-dir).
  Ships with the next chain; `riscv64_cross_env` keeps its override until consumers run on it.


## 2026-10-01 - The layer-cache keep value means layer cache; surplus cache-mount records (CON53)

- **`--keep-storage` bounds the whole store**, cache mounts included (BuildKit v0.33.0
  `cache/manager.go` sums every unshared record before the type filter applies). Against
  196 GB of cache mounts, `PRUNE_KEEP_GB=100 prune-safe.sh` therefore deleted every idle
  layer record (0.17 GB left). `_disk_guard_regular_keep_mb` (`01-core/disk-guard.sh`) adds
  the unprunable records' size from `buildctl du --format '{{json .}}'`; `prune-safe.sh` and
  the chain's DISK1 fallback both pass that, so `PRUNE_KEEP_GB` and `CROSS_BUILDKIT_KEEP_GB`
  are GB of layers.
- **Surplus cache-mount records:** with `sharing=shared` BuildKit creates a second record for
  a cache id when the one it would reuse is locked mid-release, then keeps reusing the lowest
  record id. Six ids held 52 GB of surplus on this host. `prune-safe.sh` lists them, and
  `PRUNE_DUP_CACHEMOUNTS=1` removes them; it refuses while a build holds a record. It now reads
  the store as JSON (exact bytes; it needs `jq`) and rejects a non-numeric `PRUNE_KEEP_GB`.
- Suite `test-prune-safe.sh`, a `test-disk-guard.sh` case, seven `prune-safe`/`disk-guard`
  mutations (`mutation-family:prune-safe` declared).


## 2026-10-01 - A browser and an Android emulator in `:latest` (CON50 items 3 and 4)

- **Chrome for Testing on amd64 and arm64.** Google's Stable build and its chromedriver, a
  SHA256 per zip in `versions.env`, installed by `06-packaging/install-chrome-for-testing.sh`
  as the package stage's last RUN. `CHROME_EXECUTABLE=/usr/local/bin/chrome`, a wrapper adding
  `--no-sandbox --no-zygote --disable-dev-shm-usage`; empty on riscv64, which has no build.
  +0.45 GB per arch.
- **The Android emulator and `system-images;android-35;google_apis;x86_64` on amd64**, from
  Google's zips by `06-packaging/install-android-emulator.sh`. `android-avd.sh create|start|stop`
  in `/usr/local/bin` boots it headless on `/dev/kvm`. +4.66 GB on amd64. API 30's ARM
  translator SIGILLs on OmniAccelerANT's APK; API 35's runs it.
- **Proven on a throwaway image FROM the published `:latest`** (`sha256:1a913b84…`), not on a
  rebuilt chain: headless Chrome as uid 1001 on amd64, and on arm64 under QEMU; OmniAccelerANT's
  tests in Chrome (37 pass, two files need `dart:io`); the emulator booted in 25 s with KVM and
  ran the arm64-v8a release APK. Ships with the next `:latest` rebuild.
- **Gates.** The consumer contract gains the `chrome` and `android-emulator` rows (exempt on
  riscv64, and on arm64 and riscv64). `download_verified_cached` (`01-core/downloads.sh`)
  re-verifies a cache-mount copy before every reuse. `bump_versions.py` refreshes the CfT pins
  and holds the emulator's.
- Tests: `test-chrome-and-emulator.sh` (new), `test-runtime-image-gates.sh` (+8 cases), 11
  `chrome-emulator.*` mutations.


## 2026-10-01 - A runner-native pytest job on windows-11-arm (CON50 item 6)

- **`python-ci-windows.yml` gains `arm64-tests`** (default false), with
  `arm64-python-versions`, `arm64-extras`, `free-threaded-extras` and `test-paths`. The job
  checks the caller out and runs the new `windows/scripts/python/Invoke-PythonTestLegs.ps1`
  from its ANTfrastructure pin, with no container. Each leg has its own venv through
  `New-UvProjectEnvironment`, so a `3.14` leg after a `3.14t` leg still gets the GIL build.
  Every leg gates. The error names each leg that failed and the step: venv, sync or pytest.
  Page: `docs/python-ci.md` § Windows arm64: the runner-native test job.
- **`versions.env`: `UV_WINDOWS_ARM64_SHA256`** (noforward) pins uv's
  `uv-aarch64-pc-windows-msvc.zip`, matching the release's own `.sha256`.
  `bump_versions.py`'s `spec_uv` refreshes it with the Linux pins.
- **`Invoke-StagedTests.ps1` reads a `-q` pytest summary.** pytest drops the `=` frame
  around the counts line under `-q`, so `7 passed, 1 skipped in 0.42s` is now read as well.
- `test-reusable-windows-lane.sh` holds the job's contract: off by default, gated on the input,
  and inputs passed through env. Three new `windows-lane` mutations prove it bites.
  `windows-lane.powershell-lint-defaults-off` now names its own input, because a bare
  `default: false` matched twice.
- **`PythonApp.Cross.Tests.ps1` removes its fake `uv` again.** `Remove-Item
  function:global:uv` ignores the scope prefix, so the fake outlived its suite and answered
  every later suite's `uv` (the full run failed `PythonTestLegs.Tests.ps1` on it). It now uses
  `Remove-Item -Path Function:\uv`.
- Suite `PythonTestLegs.Tests.ps1`. Hand mutations bite: no `continue` after a failed sync,
  no SHA check, a free-threaded leg ignoring its extras, and a bare `--python`. A real run
  on an x64 host against WebDavClient, with legs `3.14t 3.14`, gave the 3.14 leg a GIL 3.14.7:
  10 passed.


## 2026-10-01 - riscv64 consumer lanes: cross-build on amd64, test under QEMU (CON48)

- **Owner decision:** a consumer's riscv64 lane builds on the amd64 runner and runs only
  the tests under QEMU user-mode. A fully emulated build is 20-30x slower and would pass
  the 6 h job limit for the C++ repos. Page: `docs/riscv64-cross-test-lanes.md`.
- **`setup-riscv64-cross` (action)** registers `tonistiigi/binfmt:qemu-v10.2.3` (pinned by
  digest) with the `F` flag and exports the image's riscv64 child into a sysroot with
  `linux/scripts/02-toolchain/riscv64-sysroot.sh` (allowlist, absolute links made
  relative, the index taken from the pulled amd64 image's `RepoDigests`).
- **`lib/riscv64-cross.sh`** (`riscv64_cross_env`): the distro clang (the image's clang 23
  is X86-only), triple-named wrappers over the sysroot and its GCC 16.2.0 libstdc++, the
  cc-rs/Cargo/pkg-config variables, `QEMU_CPU=rva23u64` (`rv64` and `rva22u64` SIGILL in
  the image's RVV glibc), and arch-neutral `VULKAN_SDK`/`VK_ADD_LAYER_PATH`.
  `cmake/toolchains/riscv64-linux-gnu.cmake` is the CMake side.
- **`container-ci-riscv64.yml`** (reusable) wraps host prep, the action, the compiler cache
  and one container step. Consumers: OxidANT, AccelerANTgine, BeschleunigerBallett;
  OmniAccelerANT waits for Flutter in the riscv64 image.
- Suite `test-riscv64-cross.sh`, seven mutations in the `riscv64-cross` family.


## 2026-10-01 - Python lanes run the whole suite, `3.14t` can gate, and arm64 runs pytest (CON50)

- **`ci_tests.sh` passes pytest no path of its own.** It used to hard-code `tests/unit`, so
  pytest never read the consumer's `testpaths`. WebDavClient's six WebDAV client tests and
  every consumer's `tests/integration` ran on no lane, on any arch. `PYTEST_PATHS` (input
  `test-paths`) still narrows it on request.
- **A free-threaded leg can be real.** With `free-threaded-extras` (`FREE_THREADED_SYNC_EXTRAS`),
  a `*t` leg syncs only the core and those extras, and gates. Without it the leg stays
  experimental, and a failed venv, sync or test run now prints a `::warning::` annotation
  instead of passing silently. On 2026-10-01 `3.14t` ran 0 tests on every lane of
  OrchestrANT and WebDavClient, with every job green.
- **`container-ci-windows.yml` takes a test tree with no binaries.** Set
  `test-arch-gate-min-inspected: 0` for a Python suite that the product's own interpreter
  runs: any PE file in the tree must still be arm64, but none is required and no import
  walk runs. `Invoke-StagedTests.ps1` gains the `pytest` kind, read from pytest's final
  summary line.
- Tests: `test-python-ci-defaults.sh` (+5 cases), three new `python.ci-tests-*` mutations, and
  `StagedTests.Tests.ps1` (pytest).
- BACKLOG CON50 holds the cross-consumer audit and the owner's decisions.


## 2026-10-01 - `:winarm64` rebuilt without NVIDIA; the arm64 lanes run tests

- **`:winarm64` is published again, at hub 59a4bca3.** The image of 2026-09-22 predated
  the variant split and carried CUDA, cuDNN and TensorRT (`GPU_TYPE=nvidia`). By owner
  decision that stack belongs in `:winarm64-nvidia`, as on amd64.
- **The rebuild drops the NVIDIA stack.** It is the default variant, so the sdk slot is an
  alias of base. Its config has no `CUDA_PATH`, `TENSORRT_ROOT` or `GPU_TYPE`.
- **The rebuild also brings WiX 7 and the CPython version-string fix.** The toolchain stage
  stops on a `sys.version` without `AMD64`, so a venv reports `win-amd64` again.
- **It took 2 h 46 min.** That includes a full base and toolchain rebuild, since WiX 7 changed
  the base. The smoke and publish gates passed.
- **The effect, in OrchestrANT's arm64 lane:**
  - zip 902 → 204 MB, MSI 793 → 167 MB, MSIX 924 → 207 MB;
  - 166 PE files under the arch gate;
  - `--self-test` passes on `windows-11-arm` for the bundle and the unzipped package.
- **CON43's consumer half is done.** AccelerANTgine, OxidANT, BeschleunigerBallett and
  OmniAccelerANT run their tests on `windows-11-arm`, and each lane is now "Windows arm64 ·
  cross build + test".


## 2026-10-01 - `Invoke-InLinuxContainerBuild` hands bash LF-only lines

- **What went wrong.** A caller builds its container command in a here-string, and a here-string
  keeps its file's line endings. OmniAccelerANT's `Invoke-Renovate.ps1` is checked out with
  CRLF, so bash received `set -e<CR>` and stopped at once: `set: -: invalid option`.
- **The fix.** `WindowsBuildSweep.Common`'s `Invoke-InLinuxContainerBuild` turns CRLF into LF
  before `bash -c`. Pester: `WindowsBuildSweep.Common.Tests.ps1`.


## 2026-10-01 - Python app bundles and their packages for Windows arm64

- **`Invoke-CiPackaging.ps1 -TargetArch arm64`** builds a consumer's app for arm64 in
  `:winarm64`. Empty takes the image's `WINDOWS_TARGET_ARCH`, so x64 runs as before. It
  builds only the pure wheel: no Cython step, which compiles for the host, and no host venv
  sync. The bundle and its zip, MSI and MSIX go to `dist\windows-arm64`.
- **`New-PythonAppBundle.ps1 -TargetArch arm64`:**
  - `New-PythonAppCrossRuntime` lays out the image's target CPython with `PC\layout --arch arm64`.
  - `Install-PythonAppCrossPackage` installs the lock with `uv pip install --target
    --python-platform aarch64-pc-windows-msvc`.
  - The chain cv2 comes from the target CPython, and the launchers are compiled for aarch64.
  - The self-test is deferred: `Test-PythonAppSelfTest.ps1`, now standalone, goes next to the
    bundle for the `windows-11-arm` job.
  - `bundle.json` records `arch` and `python`.
- **`New-PythonAppPackage.ps1`** reads the arch from `bundle.json`. It names the packages
  `windows-<x64|arm64>` and passes it to `wix build -arch` and to the AppxManifest's
  `ProcessorArchitecture`. An arm64 bundle is packed and signed, never started. The new
  `Get-WindowsPackageArch` is the one place that spells the arch the x64/arm64 way.
- **Proven** in `:winarm64` with OrchestrANT 0.0.29: the arch gate passed over 191 PE files, G6
  passed, and all three packages were built and the MSIX signed. They are three times the x64
  size (zip 902 MB), because the image's arm64 OpenCV is a CUDA build. That gap, and the
  image's host CPython that predates the version-string fix, are BACKLOG CON49.
- Pester: `PythonApp.Cross.Tests.ps1`, plus arm64 cases in the wheel, MSIX and target-arch suites.


## 2026-10-01 - A staged test can report its own skip; OrchestrANT's permissions census is at 0

- **`Invoke-StagedTests.ps1` reads an optional `skip_pattern` per `tests.json` entry.**
  A wgpu test without an adapter prints `SKIP: no GPU adapter` and returns, which cargo
  counts as passed. Each line matching the pattern moves one test from passed to skipped,
  so a windows-11-arm runner with no GPU no longer reports those tests as passed.
  OxidANT's renderer entry already names it. Pester: `StagedTests.Tests.ps1`.
- **`workflow-conventions.allow` drops `CENSUS | OrchestrANT | permissions | 2`.**
  OrchestrANT's lane files now set `permissions: contents: read` at the top, so the count
  is 0 and the row has nothing left to freeze.


## 2026-10-01 - Renovate reads and bumps CMake dependencies (CON46, hub part)

- **The shared preset (`default.json`) gains two regex `customManagers`** over every
  `CMakeLists.txt` and `*.cmake`. Every consumer inherits them through `extends`.
  - `GIT_REPOSITORY <GitHub URL>` then `GIT_TAG <tag>`, and a tag archive
    (`.../archive/refs/tags/<tag>.zip|.tar.gz`), both as `github-tags`.
  - A `# renovate: datasource=… depName=…` line directly above `GIT_TAG <v>`,
    `set(<NAME> <v>` or a quoted `"<v>"`.
  - Only a dotted value is a version: `master`, `main`, a SHA, `${VAR}` and a commit
    archive are skipped. The forms exclude each other, because Renovate's regex manager
    does not de-duplicate rows.
  - Measured with Renovate 44.82.0 and RE2 on AccelerANTgine's and BeschleunigerBallett's
    real files: each pin once, every floating ref skipped. `--strict` validation passes.
- **`renovate-local.sh --apply` rewrites those pins.** The locator runs the preset's own
  `matchStrings`; the audit reads the file with a new CMake tokenizer
  (`linux/scripts/renovate_cmake.py`) and refuses a tag archive behind `URL_HASH`/`URL_MD5`
  and a match inside a comment. `renovate_locator.syntax()` picks the reader per file, so one
  `regex` report can carry `versions.env` and CMake.
- Docs: [`docs/dependency-updates.md`](dependency-updates.md) § CMake dependencies.
  Test: `linux/scripts/tests/test-renovate-cmake.sh`; nine `renovate-cmake.*` mutations.
- Left for the consumers (BACKLOG CON46): pin corrosion, move googletest to a tag archive,
  drop the two repo-level CMake managers, then the fleet report run.


## 2026-10-01 - WiX 7 (OSMF EULA accepted) and arm64 tests on windows-11-arm (CON43, hub part)

- **WiX 4.0.6 → 7.0.0, with the owner's acceptance of the wix7 OSMF EULA (2026-10-01).**
  WiX 4 left community support on 2025-02-05.
  - `Install-ScoopTools.ps1` runs `wix eula accept wix7` after the install. Without it,
    every build stops with `WIX7015`, measured. It refuses any other major, since a new EULA
    is a new licence decision. Renovate's guard moves from `<5` to `<8`.
  - Measured in `:winamd64` with WiX 7.0.0:
    - OxidANT's `wix/main.wxs` (UI extension, payload fragment) builds, installs and
      uninstalls.
    - A CPack `WIX` package (`CPACK_WIX_VERSION 4` mode) builds.
    - OrchestrANT's Python app MSI builds, installs, starts, is on `PATH` and uninstalls.
  - The images carry WiX 7 from their next build. Until then they keep 4.0.6, whose sources
    are the same.
- **`container-ci-windows.yml` carries tests to the arm64 runner.**
  - New inputs `test-artifact-dir` and `test-command`. The staged tests get the product's
    arch gate, so an amd64 test cannot pass by emulation.
  - The run job demands one `TESTS: passed=<n> failed=<n> skipped=<n>` line, and fails
    without it, on a failure, or with nothing passed.
  - `windows/scripts/build/Invoke-StagedTests.ps1` prints that line from googletest,
    libtest and exit-code results. It is self-contained, because the runner has no checkout.
  - Docs: [`docs/windows-cross-builds.md`](windows-cross-builds.md) § Consumer cross
    lanes. Test: `windows/scripts/tests/StagedTests.Tests.ps1`.
  - The consumers follow one at a time (CON43).


## 2026-10-01 - Windows uv venvs install a missing version before asking for its GIL build

- **Fixed a regression from 88e27ab9.** A version the host lacked stopped the venv:
  `New-UvProjectEnvironment` asks for `X.Y+gil`, and uv downloads nothing for that request.
  - OmniAccelerANT's CMake format gate, which wants 3.12, failed with `No interpreter found
    for Python 3.12+gil` on its first run with hub 709d09f3.
  - The function now runs `uv python install X.Y` first when `uv python find` comes back
    empty, as Linux's `uv_ensure_python_available` does.
  - Measured in `:winamd64`: 3.12 is installed and its venv is GIL. 3.14 keeps the image's
    `C:\temp\cpython`.
  - Test: `windows/scripts/tests/Uv.PythonRequest.Tests.ps1`.
- `Invoke-CiPackaging.ps1` reads the binaries venv's base interpreter from its `pyvenv.cfg`,
  after that venv exists, instead of asking `uv python find` before it. The `LIB` fix then
  holds for a version the venv step had to install.


## 2026-10-01 - Python app packages: MSIX, Linux aarch64, and one chain ORT per Windows bundle

- **MSIX.** `New-PythonAppPackage.ps1` builds it by default, next to the zip and MSI.
  - `New-PythonAppAppxManifest` gives each script a full-trust console app with its own
    execution alias, so the CLIs reach `PATH` as the MSI's PATH entry does. Only `gui_script`
    is listed in Start.
  - `makeappx` packs the bundle in place through a mapping file.
  - The signature is a test certificate for `CN=<publisher>`, made in memory by
    `New-PythonAppSigningCertificate`, so no store is touched. Its `.cer` ships beside the MSIX.
  - Proven in `:winamd64`: the unpacked package starts, and inside the container
    `signtool verify /pa` passes once the `.cer` is trusted; the root is removed again.
    makeappx refuses `desktop4:Subsystem="console"` without `SupportsMultipleInstances`
    (80080204).
  - Test: `windows/scripts/tests/PythonApp.Msix.Tests.ps1`.
- **Linux aarch64 builds the bundle and its packages.** `ci_packaging.sh` no longer skips
  non-x86_64.
  - Proven under QEMU with the arm64 `:latest`: closure, G6 and self-test pass, and the tar.gz
    (232 MB) and deb (190 MB) each start once.
  - That image's chain ORT wheel is `onnxruntime_webgpu`. The AppImage needs a real arm64 host
    (`qemu-user` cannot load `appimagetool`), which CI's arm64 lane is.
- **One chain ORT per Windows bundle.** `Copy-ChainOpenCvPackage -SharedDirectory` searches
  the bundle's own `onnxruntime\capi` first and names it in cv2's `config.py`, instead of
  copying a second `onnxruntime.dll` and `DirectML.dll` into `cv2\bin`.
  - Proven in `:winamd64`: `import cv2` succeeds before `onnxruntime` is imported, and G6 and
    the import walk pass.
  - The bundle went from 561 to 550 MB.


## 2026-10-01 - lavapipe gets 8-lane subgroups, the SSIM validate plugin stops blacklisting itself, libunwind is gone from the media closure

For the `:latest` rebuild the owner approved on 2026-10-01. None of it is in a published image yet.

- **`ENV LP_NATIVE_VECTOR_WIDTH=256` in the package image, every arch (CON44).** Mesa 26.0.8's
  lavapipe sorts its BVH with 8-lane subgroups; llvmpipe gives 4 on arm64 and riscv64 (measured
  with `vulkaninfo` in the published `:latest`), and the scatter SEGVs. The runtime smoke's
  `check_lavapipe_subgroup` fails a variable other than 256 or a `subgroupSize` other than 8.
  BeschleunigerBallett can drop its own export once it runs on the new image.
- **The SSIM validate plugin no longer blacklists itself (CON47).** It was no loader error:
  `plugin_init` returned FALSE outside gst-validate, and the core registry scans
  `gstreamer-1.0/validate/` too. Patch `007` returns TRUE there, as the gapplication plugin does;
  proven by building gst-devtools 1.29.2 with the hub's patcher (blacklist 1 → 0, the override
  still writes its frames under gst-validate). The plugin-health check now FAILS on any
  undocumented blacklisted plugin, and `check_gst_validate_ssim` runs the override on amd64.
- **The libcamera half of the libunwind fix is measured, and the owner chose "everywhere".**
  `build-libcamera.sh` built with and without `-Dlibunwind=disabled`: without it
  `libcamera-base` NEEDs `libunwind.so.8` and a C host that loads it first segfaults on an
  exception through `std::call_once`; with it the exception is caught. A readelf sweep over all
  three published arches found no other user under `/opt` or `/usr/local`, only distro `Xvfb`
  and gperftools outside it. `check_no_libunwind_closure` now fails a shipped file that needs it.
- Tests: `test-lavapipe-vector-width.sh`, `test-gst-validate-ssim.sh`, `test-no-libunwind.sh`
  (extended); 18 mutation entries.


## 2026-10-01 - Windows Python lanes: static analysis runs at all, and wheels are built for the GIL

OrchestrANT's first Windows run on 5cfc5259 failed in three places, and the hub owned two of them.

- **`Invoke-CiStaticAnalysis.ps1` failed all six gates with `Cannot bind argument to parameter
  'Context' because it is null`.** Each gate's script block went through `GetNewClosure()`, and
  inside a closure's dynamic module `$script:BuildContext` is `$null`. This was in place since
  2026-09-12; earlier failures in the same lane had hidden it. The context is now bound to a
  local before the closure.
- **`uv build` built the Windows wheel free-threaded (`cp314-cp314t`).** It finds its own
  interpreter and ignores the venv's `+gil` one, so `Invoke-CiPackaging.ps1` passes it
  `--python X.Y+gil` too. See [`docs/python-ci.md`](python-ci.md) § *Free-threaded and GIL
  legs in one container*.
- **The GIL build then could not link (`LNK1104: python314.lib`).** The image's CPython is an
  in-tree build, and its import library sits beside `python.exe`, where setuptools never looks.
  The binaries step puts that directory on `LIB`. Proven in `:winamd64`: OrchestrANT builds
  `orchestrant-0.0.28-cp314-cp314-win_amd64.whl`.
- **The bundle builder picks the wheel by the runtime's ABI.** It used the first `win_amd64`
  wheel, so the GIL runtime tried to install that `cp314t` wheel. `Select-PythonAppWheel` takes
  `cp314` or `abi3`, and falls back to the pure wheel only when there is no binary at all. A
  binary for another ABI alone is an error. Test: `windows/scripts/tests/PythonApp.Wheel.Tests.ps1`.


## 2026-10-01 - DeepStream's GPU gate passes; four defects it found are fixed (CON42)

- **The GPU gate passed** on the build host's RTX 2080 (sm_75, driver 595.58.03, CDI through
  rootless nerdctl), in a throwaway container FROM the published `:latest` amd64 child plus
  the variant's CUDA 13.4.2: TensorRT 10.16 builds the sample engine for sm_75; NVDEC
  decodes; decode → `nvstreammux` → `nvinfer` → `nvtracker` → `nvmultistreamtiler` →
  `nvdsosd` (GPU mode) runs with detections and tracker ids in the metadata, as root and as
  uid 1001; `nvstreamdemux` and `nvurisrcbin` run; NVIDIA's CUDA 13.2 kernels run on 13.4.
  Pass/fail only: the licence forbids publishing benchmark results.
- **TensorRT builder resources are linked by file name.** An engine build `dlopen()`s
  `libnvinfer_builder_resource_sm75.so.10.16.1` by name, which `ld.so.cache` never holds;
  `deepstream.sh` links them into `/usr/lib/<triplet>/` and the gates check the links.
- **NVDEC works through the distro `libv4l2`**, with NVIDIA's `libcuvidv4l2_plugin.so` linked
  into its plugin dir by `stage-runtime` (and gated); no SONAME hijack.
- **The image selects the new `nvstreammux`** (`USE_NEW_NVSTREAMMUX=yes` with DeepStream,
  empty otherwise). NVIDIA's prebuilt legacy mux reads `GstMapInfo.data` after unmap, which
  GStreamer ≥ 1.28 clears; it failed every buffer with no message.
- **GStreamer core and libcamera build without libunwind**, in every variant.
  `libunwind.so.8` ahead of `libgcc_s` turned an exception through `std::call_once` into a
  segfault (`docs/failure-modes.md`); it took the TensorRT error above down with it.
  Backtraces fall back to glibc's `backtrace()`.
- **Host setup:** a GPU container on an x86 desktop with rootless nerdctl (`linux-host-setup.md`
  § B2c): the Secure Boot key, the CDI spec in `~/.config/cdi` plus `cdi_spec_dirs`, and
  regenerating it after every driver update.
- **Still open for CON42:** the owner-approved nvidia chain run with `ENABLE_DEEPSTREAM=true`.


## 2026-10-01 - Python app bundles become tar.gz, deb, AppImage, zip and MSI, each started once

- **Packagers.** `linux/scripts/06-packaging/python-app-package.sh` (tar.gz, deb, AppImage) and
  `windows/scripts/python/New-PythonAppPackage.ps1` (zip, MSI) wrap a finished bundle. They then
  start each package through `python-app-selftest.py` / `Invoke-PythonAppSelfTest -Root`, which
  also requires ONNX Runtime to load from inside it. The deb is installed with `dpkg -i`,
  started and removed when root. The MSI is installed, started, checked on the system `PATH`
  and removed, but only inside an elevated Windows container: on any other machine it is
  proven by an administrative unpack, so a developer's run changes nothing.
- **The lanes build them.** When a consumer has `packaging/app.json`, `ci_packaging.sh` and
  `Invoke-CiPackaging.ps1` build the bundle into `build/app-bundle` and the packages into
  `dist/packages`, which the lanes' `dist/` artifact already uploads. Linux does this on
  x86_64 only, until an aarch64 bundle is proven.
- **The deb's `Depends` is measured.** It is `libc6` at the newest `GLIBC_` any bundled ELF
  asks for, plus the `dpkg -S` owners of every library left to the host. A waived soname
  (`unresolved_allowed`, now in `bundle.json`) is skipped, and an unowned one fails. For
  OrchestrANT it is `libc6 (>= 2.43)` and six X/GL/GLib packages, so the Linux packages need
  Ubuntu 26.04 or newer, and the flatpak 24.08 runtime does not fit. Only the chain ORT (2 of
  142 ELF files) asks for 2.43; the next newest is 2.38.
- **Nothing writes into an installed package.** The builders compile all bytecode, and the
  launchers pass `-B`. Before this, the first start as admin or root left `__pycache__` that
  the removal did not delete.
- **MSI:** WiX 4.0.6 has no harvesting, so `New-PythonAppWxs` writes the tree out. It installs
  per machine, keys a major upgrade on `msi_upgrade_code`, adds a Start menu shortcut and the
  system `PATH` entry, and refuses paths past MAX_PATH. Windows' `tar.exe` has no `-s`, so the
  zip names its top folder by renaming the bundle while it zips.
- Tests: `linux/scripts/tests/test-python-app-selftest.sh`,
  `windows/scripts/tests/PythonApp.Msi.Tests.ps1`.


## 2026-10-01 - Python apps ship as relocatable bundles; Windows venvs get the image's OpenCV

- **Bundle builders.** A Python consumer can now turn its app into one folder: its own
  CPython, the locked wheels, the chain ORT, its data and one launcher per console script.
  `windows/scripts/python/New-PythonAppBundle.ps1` (module `WindowsPythonApp.Common`, C
  launcher in `windows/scripts/python/app-launcher/`) and
  `linux/scripts/06-packaging/python-app-bundle.sh` (+ `python-app-closure.sh`) both read the
  consumer's `packaging/app.json`. The gates are the import walk, G6 and the app's own
  self-test. Proven on OrchestrANT: Windows 561 MB, Linux 666 MB, each run again after being
  moved. See [`docs/python-app-bundles.md`](python-app-bundles.md).
- **`Test-TargetArch.ps1 -Standalone`.** On a native lane the import walk only reports, because
  the image's `PATH` supplies what is missing. A bundle has no image behind it, so `-Standalone`
  makes the walk fatal there, as it is on a cross lane. It caught the gap below by name, where the
  self-test had only said `DLL load failed`.
- **Windows: OpenCV comes from the image, in bundles and in CI venvs.** PyPI's `cv2.pyd`
  imports Media Foundation, which Server Core and Windows N lack. Copying the image's cv2 package
  was not enough: its `config.py` names only OpenCV's `bin`, while the image's base
  `sitecustomize.py` registers the other DLL homes. A venv or a bundle never runs that file, so
  `import cv2` failed in both. The PE walk showed five FFmpeg DLLs as the gap.
  - `Copy-ChainOpenCvPackage` walks the `.pyd`'s closure over the config dirs, `ONNX_ROOT\bin`
    and every `C:\runtime` dir on `PATH`. The bundle copies the closure (56 DLLs) into `cv2\bin`;
    a CI venv (`-ReferenceImage`) names the three image dirs instead.
  - `Sync-UvProjectDependencies` now ends with `Sync-UvChainOpenCv`. Measured in `:winamd64`:
    the CI venv imports cv2 5.0.0 with FFmpeg and DirectShow.
  - `Get-PeImportClosure` is split out of `Copy-PeImportClosure` for that walk.
- **Windows venvs ask uv for the GIL build.** `New-UvProjectEnvironment` passes
  `Get-UvPythonRequest`'s `X.Y+gil`, the twin of Linux's `uv_python_request`. A plain `3.14`
  took a free-threaded download in OrchestrANT's Windows CI.


## 2026-10-01 - DeepStream may be published: the owner's licence decision (CON42)

- **The owner allowed publishing NVIDIA's DeepStream runtime in `:latest-nvidia`.** The
  stage graph no longer refuses a pushing chain with `ENABLE_DEEPSTREAM=true`; its test now
  asserts the chain is accepted, and the gate's mutation entry is gone with the gate.
- **The image ships the runtime `.so` files, not the static archives.** The licence
  supplement makes "the runtime files ending with “.so”" distributable; the package stage's
  `deepstream.sh stage-runtime` deletes `libnvdsgst_multistream_legacy.a` and
  `libnvds_service_maker_utils.a`, which only a build links. `LicenseAgreement.pdf` ships.
- **Still open for CON42:** a GPU run (the host's driver is blocked by Secure Boot: the DKMS
  key is not enrolled) and an owner-approved nvidia variant chain run.
- **CON47:** `libgstvalidatessim.so` fails to load in the published `:latest`, found by the
  spike; tracked to be measured and fixed.


## 2026-10-01 - DeepStream for the nvidia variant (CON42): spike measured, source in, off by default

- **The spike (phases 1–3), without a chain.** In throwaway containers FROM the published
  `:latest` amd64 child plus the variant's CUDA 13.4.2: NVIDIA's DeepStream 9.1 runtime `.deb`
  unpacked, and its Apache-2.0 plugins and libraries built against `/opt/gstreamer` 1.29.2
  (not Ubuntu 24.04's 1.24). `nvinfer`, `nvstreammux`, `nvvideoconvert`, `nvtracker`,
  `nvdsosd`, `nvv4l2decoder`, `nvmultistreamtiler`, `nvstreamdemux` and `nvurisrcbin`
  register without a GPU. No GStreamer or GLib symbol is missing, and no CUDA symbol against
  13.4.2 (the runtime targets 13.2).
- **TensorRT 10 beside 11.** NVIDIA's tracker and infer utilities link `libnvinfer.so.10`, and
  the `nvdsinfer` source does not compile against 11.3 (56 errors, APIs removed in 11). The
  image carries TensorRT 10.16.1.11 privately. Measured: with TensorRT 11 in a process's
  global scope, a library linked against `.10` binds to 11's unversioned symbols.
- **Upstream fixes the build needs here.** GCC 16 (missing transitive `<cstdint>`/`<algorithm>`,
  a new `-Werror`), each Makefile keeping its own compiler (one compiles C with `CXX:=gcc`), an
  `$ORIGIN` RUNPATH for the `nvds_rest_server` dependencies, and helper libraries moved out of
  `gst-plugins/`: the registry scan `dlclose()`d them and the next plugin segfaulted in
  `g_quark_from_static_string`.
- **Proven with the hub script, not only the spike.** `deepstream.sh build` passes its gates in a
  fresh container (48 components, 2m58s warm with sccache), and `stage-runtime` passes on a clean
  `:latest` with only the runtime packages, as root and as the runtime user. The gates caught
  three real faults on the way there, each fixed: the otel libraries without a RUNPATH, NVIDIA's
  `libnvdsgst_sparse4d.so` whose RUNPATH names `deepstream-9.0`, and a `grep -q` whose SIGPIPE
  under `pipefail` classed `libgstnvvideo4linux2.so` as a helper library.
- **In the source, off by default.** `linux/scripts/05-frameworks/deepstream.sh` and
  `deepstream-verify.sh`, a gated `deepstream` stage in `Dockerfile.media`, the package's
  `stage-runtime` / `assert-absent` RUN, `check_deepstream` in the runtime smoke,
  `DEEPSTREAM_*` pins with SHA256s, `test-deepstream.sh`, new cases in `test-gpu-variant.sh`,
  and 19 mutation entries. `ENABLE_DEEPSTREAM=true` is refused outside the nvidia variant, and
  a DeepStream chain refuses to push until the owner decides whether NVIDIA's licence allows
  publishing it (the facts: `docs/linux-accelerator-images.md` § Licence: the owner decision).
- **cuDNN pin fix (found on the way).** The nvidia variant never installed its `CUDNN_VERSION`:
  `libcudnn9-dev-cuda-13=9.26.0.51*` depends on the exact `libcudnn9-headers-cuda-13`, apt took
  the newest headers, the pinned tier failed, and the unpinned tier installed 9.27.0.42.
  `install-cuda-stack.sh` now pins the headers package in the same call.
- **Cache cost.** `versions.env` is in the base closure, so this commit re-keys every chain from
  base on its next build, as any pin bump does.
- **Not done.** No GPU run (this host's NVIDIA driver is not loaded) and no variant chain
  run: `BACKLOG.md` CON42.
