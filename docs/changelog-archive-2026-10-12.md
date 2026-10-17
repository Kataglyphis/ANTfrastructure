<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Changelog archive — 2026-10-08 through 2026-10-12

Entries moved out of the root `CHANGELOG.md` on 2026-10-17 so the live file stays
readable (its own rule: archive past ~700 lines, never delete). Newest-first, running
back to where [`changelog-archive-2026-10-07.md`](changelog-archive-2026-10-07.md) picks up. One mechanical edit, no
rewording: relative links are re-based on this directory.

## 2026-10-12 — ai-edge-litert for Python 3.15, built from source with clang-cl (CON91)

- **The Windows images build ai-edge-litert themselves.** No release has a cp315 `win_amd64` wheel or sdist, so
  media-litert's second RUN builds upstream's own target `//ci/tools/python/wheel:litert_wheel` at `LITERT_VERSION`
  (`Build-LitertWheelBazel.ps1`). The merge copies the wheel into `C:\runtime\wheels`, and the torch venvs install it.
- **Compiler and pins:**
  - Bazel 7.7.0 (pinned by SHA256) builds with its own clang-cl toolchain from `C:\llvm-patched`. An aquery gate fails
    the stage on any action that is not clang-cl, lld-link or llvm-lib.
  - Bazel's hermetic Python is the image's CPython 3.15, with a hash-pinned numpy/setuptools/wheel lock.
  - Only the closed-source WebGPU accelerator comes from the pinned PyPI wheel.
  - The floating `@litert_prebuilts` zip and the unhashed OpenVINO nightly are never fetched.
- **Proven by probe P12.** The production driver built the wheel in 272 s (530 s for the RUN); all 4522 compile,
  link and archive actions ran LLVM tools. It passed the wheel contract and a CPU smoke through both Python APIs.
- **The rocm check now needs CompiledModel and Environment.create().** An interpreter-only wheel with the accelerator
  copied in can no longer pass it. `WindowsBazel.Common` now owns the helpers both bazel drivers share. Rides the next
  chain.

## 2026-10-12 — the torch venv's sdists compile with clang-cl and link (CON93)

- **The in-tree CPython links extensions like an install.** Under 3.15, line-profiler 5.0.2 and pyyaml 6.0.3 have no
  cp315 wheel, so the torch stage's `uv sync` builds them. setuptools then failed `LNK1104 python315.lib`: it links
  against `sys.base_exec_prefix\libs`, which the in-tree build lacked. The toolchain stage now copies `python3XY.lib`
  and `python3.lib` there (`Install-CpythonInTreeImportLib`), and smoke section 2 checks them.
- **The sdists compile with clang-cl, not VS's cl.** setuptools took VS's `cl.exe` and `link.exe`. The torch stage now
  syncs with copies of clang-cl, lld-link and llvm-lib first on `PATH` as `cl`, `link` and `lib`, under
  `DISTUTILS_USE_SDK`. A gate fails the stage when a PE of a distribution uv built from source carries MSVC's Rich
  header. Probe P13 built and imported line-profiler that way on the 3.15 image. Rides the next chain.

## 2026-10-12 — meson in the Windows images verifies TLS through CryptoAPI (CON88)

- **truststore beside every meson the chain installs.** Python in Server Core trusts only the store's 18 roots, so
  meson's `ogg` wrap failed `CERTIFICATE_VERIFY_FAILED` on downloads.xiph.org (whose chain ends at emSign) and fell back
  to a GitHub mirror unnoticed. meson's `wrap.py` uses truststore whenever it imports, and truststore lets CryptoAPI
  fetch the missing root. truststore 0.10.4 (`PY_TRUSTSTORE_VERSION`) now installs with meson in the GStreamer and
  FFmpeg-codec builds, media-core's site-packages carry it into the image for consumers' meson too, and smoke section 2
  imports it beside `mesonbuild`. The next chain proves it: no `CERTIFICATE_VERIFY_FAILED` in the merge log.

## 2026-10-12 — every pip install in the Windows chain is pinned (CON89)

- **No build installs a floating Python package any more.** FFmpeg's codecs installed an unpinned `meson`, and the
  ONNX Runtime, GenAI, OpenCV, IREE and TVM builds installed numpy, setuptools, wheel, packaging, requests,
  scikit-build-core, setuptools-scm, typing_extensions, ml_dtypes, cloudpickle and psutil at whatever PyPI served that
  day. `Install-CpythonPipPin` (`WindowsSourceBuild.Common`) installs each at its `PY_*_VERSION` pin and throws for a
  package without one; five pins are new (requests 2.34.2, typing_extensions 4.16.0, ml_dtypes 0.6.0, cloudpickle
  3.1.2, psutil 7.2.2, each with a cp315, abi3 or pure wheel). The Cython both media branches install comes through
  it too. `Build.PipPins.Tests.ps1` fails on a bare package name in any `Invoke-CpythonPip install`. Rides the next
  chain.

## 2026-10-12 — the LiteRT-LM bazel build fetches only pinned, checked tools (#185)

- **bazelisk, the JDK and git-lfs are pinned by version and SHA256.** `Build-LitertLmBazel.ps1` took bazelisk from
  `releases/latest`, fell back to Adoptium's `latest/21/ga` JDK when the pinned asset failed, and installed git-lfs
  through scoop; nothing was SHA-checked, so a cold tool cache took whatever was newest. `Get-PinnedTool` now fetches
  bazelisk v1.29.0, Temurin 21.0.5+11 and git-lfs v3.8.0 from their release URLs, checks each against its
  `versions.env` pin (the releases' own digests), re-fetches a corrupt cache entry and refuses anything else. The pins
  reach `media-litert-env` as ARGs and stay out of the merge.

## 2026-10-12 — CON91, second half: the Windows build side names no Python, and the twin store is Linux's

- **The arm64 tvm-ffi wheels carry the pin's tag.** `New-TvmFfiCrossWheel`'s tags defaulted to cp314: on 3.15 the GIL
  wheel would have been tagged cp314 around a `core.pyd` linking `python315.lib`, and the twin `cp314-cp315t`. The GIL
  call passes the pin's `cpXY`, the twin's python tag drops the ABI's `t`, and both tags are mandatory.
- **No literal 3.14 is left on the build side.** `Get-CpythonFreeThreadedExeName`, `Get-FreeThreadedAbiTag` and the
  placeholder `python314.lib` take `Get-PinnedPythonVersion`; OpenCV's `FindPythonInterp` stub asks the interpreter
  for its version; `Test-Container` fails without a pin instead of grading 3.14.
- **The twin store is `C:\runtime\wheels-free-threaded` (`PYTHON_WHEELS_FREE_THREADED`)**, Linux's name, in the
  merge stage's ENV and COPY, both producers' default, the ORT census, the bundle manifest and the smoke's env
  contract. Every reader still takes `PYTHON_WHEELS_CP314T`, and the device gate the `wheels-cp314t` folder of an
  older bundle. `Test-Container` fails when the image names a store that is not there, where it skipped.

## 2026-10-12 — GStreamer compiles through sccache (#182), and two vendored builds stop flooding the logs (#183)

- **#182:** meson's `compilers/detect.py` keeps an `sccache` prefix for MSVC's compiler class and drops it for
  clang-cl, so the `CC='sccache clang-cl'` of 2026-08-04 never cached a compile: 16 sccache requests for 5,143 ninja
  steps, and every merge rebuild compiled GStreamer cold (515-663 s). `New-SccacheCompilerShim` builds a `clang-cl.exe`
  that runs sccache with the pinned clang-cl and the caller's arguments, meson gets it as `CC`/`CXX`, and the stage
  fails when sccache counted fewer than 100 compile requests. Proven by a local buildctl probe; the next chain proves
  it at scale.
- **#183:** the Vulkan validation layers' and x265's GCC-style `-Wall` reaches clang-cl as `-Weverything`: the arm64
  VVL alone was 6,228,195 lines, 752 MB of a 768 MB merge log, and x265 added 27,423 `-Wunsafe-buffer-usage` lines to
  every ffmpeg branch. Both builds run with `CL=/w`, which clang-cl reads before its own flags and sccache does not
  hash, and restore the caller's `CL` after it. The first fix used `_CL_`, which clang-cl appends: behind CMake's
  `-- <source>` the `/w` read as a file name and failed x265's compiler check (bk-20261012-190400).

## 2026-10-12 — CON91, first half: the Windows drivers and syncs follow the Python pin

- **`Get-PinnedPythonVersion`** (`WindowsPythonWheel.Common`) is the Windows twin of `python_pinned_major_minor`:
  the image's `PYTHON_VERSION`, else `versions.env`, as X.Y, `cpXY` and `cpXYt`; no literal fallback. It is not in
  `WindowsScripts.Shared`, which `Dockerfile.base` copies above `Install-Vs`, so an edit there would re-key VS.
- **The drivers name no Python.** `Invoke-CiPackaging.ps1`, `Invoke-CiStaticAnalysis.ps1` and
  `Invoke-PythonTestLegs.ps1` defaulted to 3.14; empty now takes the pin, and a leg list reads `pinned`/`pinnedt`
  as `ci_tests.sh` does. `python-ci-windows.yml`'s `arm64-python-versions` defaults to empty (WebDavClient, its only
  caller, passes its legs). `Test-ExperimentalPython`'s default is the pin's X.Yt.
- **Inside our images the Windows sync installs no PyPI ORT**, as Linux's since 2227be6e: `Sync-UvProjectDependencies`
  passes `--no-install-package` for every ORT entry of `uv.lock` (the unlocked retry too), and the reconcile installs
  the chain wheels for those, uninstalling only what reached the venv. PyPI's onnxruntime has no cp315 wheel.
- **The arm64 bundle's pytest stack** moves its three native wheels to cp315 `win_arm64` (PyPI's SHA256s), and
  `Build.Arm64WheelStack` takes the stack's tag from `PYTHON_VERSION`: red on the cp314 pins, green on these.
- **ai-edge-litert:** no release has a cp315 `win_amd64` wheel, so the torch app stage leaves it out of `uv sync`
  (with a warning) until the chain builds one from source (owner decision). The rocm lane's PyPI extra and its cp314
  pin are gone; the pin becomes the source build's accelerator carrier, and the accelerator DLL's own SHA256 is pinned
  (the same bytes in the cp313 and cp314 wheels). `Torch.Rocm.Tests.ps1` is green again.

## 2026-10-12 — the LiteRT layer exports in 53 s instead of 19 min (#181); #184's review fixes

- **#181: bazel's trees leave the LiteRT layer.** `Build-LitertLmBazel.ps1` left `C:\bzl` (the output base), `C:\llm`
  (the checkout with its git-LFS prebuilts), `C:\bzl-tools` and the bazel log in the layer, and the merge copies only
  `lib\litert-lm` out of it. After the install's contract check, `Remove-LitertLmBuildTree` now stops the bazel
  server's `java.exe` and removes them; a junction inside never takes its target along (tested). On a local
  media-litert stage (bk-20261012-152007) 8.7 GB left the layer, and its export took 52.9 s against 1,126 s. The
  unpack, 1,047 s there, varies with the host. Bazel's output streams to the stage log, its progress throttled to one
  line per 30 s, where `Select-Object -Last 20` used to hide 450 s.
- **#184's adversarial review found four defects, all fixed.**
  - A throw between stages was charged to the stage that had just passed.
  - The failure manifest could read a caller's `$started`.
  - A snapshot-mount contention retry was recorded twice.
  - `-ConcurrentAux` children shared one driver log and manifest. The parent now passes `-ParentRunId`, and a child's
    run is `<parent>-<branch>`.

  The manifest culture test runs under de-DE, so an en-US runner catches that regression too. The first real run with
  the driver log showed `done in 2.415,0s`, so its timed records are culture-invariant now.

## 2026-10-12 — the patched clang-cl relinks reproducibly (#180), and a stopped BuildKit run keeps its record (#184)

- **#180: LLVM builds with the pinned clang-cl, so `/Brepro` applies.** CMake's default compiler for the patched LLVM was
  MSVC `cl`, and LLVM's `HandleLLVMOptions.cmake` appends `/Brepro` only for a Clang compiler. Every relink therefore
  stamped `clang-cl.exe` with the link time, and sccache, which keys on the compiler's bytes, missed nearly every media
  compile after a toolchain re-run (#153: onnx 9/1332, litert 0/5374). `Build-LlvmFromSource.ps1` now names the base
  image's clang-cl (`LLVM_USER_BIN`) and refuses to fall back to `cl`. `Assert-ReproducibleLink` fails the stage when
  `clang-cl.exe` still carries a link-time PE stamp. A local toolchain stage (bk-20261012-144845) compiled LLVM cold
  with clang-cl in about 12 min, and the new `clang-cl.exe` carries the content hash 0x35341D1A. This re-keys the
  toolchain stage, so the next full chain rebuilds the media lane once (CON89).
- **#184: the driver records what the console alone lost.**
  - The manifest carries `status=ok`, or, written from the `finally`, `status=failed:<stage>` with every finished stage.
    Stage seconds use the invariant culture: a German host wrote `patched-llvm=778,9` beside `total_s=13058`.
  - `bk-<run>-driver.log` records the run, stage starts, ends and failures, retry verdicts with the line that made them
    transient, and disk-gate verdicts.
  - The resource CSV gains `diskFreeGB`, and the summary `MinDiskFreeGB`.
  - buildctl's output is decoded as UTF-8, so an em dash no longer arrives as `ÔÇö`.

## 2026-10-12 — CON90: consumers name no Python version, and the image's ORT no longer waits for PyPI

- **`pinned` in a leg list.** `ci_tests.sh` reads `pinned` as the pinned X.Y and `pinnedt` as its twin, so a row that
  picks its legs (OrchestrANT's riscv64 row wants the GIL one only) names no version; `ci_build_docs.sh` publishes the
  default leg's reports as `pytest-report.html`/`.md` and `pytest-report-free-threaded.html` beside the versioned ones.
- **Inside our images the Linux sync installs no PyPI ORT.** `uv_sync_project` passes `--no-install-package` for every
  ORT entry of the lock when `ORT_CHAIN_WHEEL_DIR` is set, and the reconcile installs the chain wheels in their place.
  Measured with uv 0.13.0 on python-build-standalone 3.15.0: a locked sync of a lock naming onnxruntime 1.31.0 fails
  (`only has wheels with ... cp314, cp314t`), and with the flag it syncs the rest. A free-threaded venv also finds the
  twins under the older images' `PYTHON_WHEELS_CP314T`. Windows' sync: BACKLOG CON91.

## 2026-10-12 — CON90: Python 3.15.0, and an upgrade is one line

- **`PYTHON_VERSION=3.15.0`** (owner request; released 2026-10-09). `PYTHON_TGZ_SHA256` was computed from python.org's
  tarball twice, by hand and by `bump_versions.py`. uv moves to 0.13.0, the first release that knows 3.15.0; numpy to
  2.5.4, which ships cp315 and cp315t wheels (its twin-table row re-read at that pin).
- **The images ship the source-built interpreter on every arch.** `Dockerfile.package` mounts the toolchain's staged
  `/opt/python-cross/<arch>` into its setup RUN, and `install_staged_target_python` installs it without the fat-LTO
  static libpython and checks it reports `PYTHON_VERSION` exactly. The distro `python3` (Ubuntu's 3.14) stays apt's
  alone. arm64 and riscv64 no longer copy apt's numpy, gi, cairo and contourpy into the venvs (they were built for the
  distro interpreter); uv builds them from sdists, and the `pycairo==1.27.0` constraint that matched apt's copy is gone.
- **Nothing else names a version.** X.Y, the wheel tags and the drivers' defaults derive from the pin
  (`python_pinned_major_minor`, `PYTHON_ABI_TAG`/`PYTHON_FT_ABI_TAG`); `ci_tests.sh` runs X.Y, plus X.Yt for a project
  that declares free-threading; the free-threaded store is `/opt/wheels-free-threaded` (`PYTHON_WHEELS_FREE_THREADED`),
  which Windows' readers take first too; the uv seed, the app bundle, the GStreamer cross paths, the smokes and the
  hub's own workflows read the pin; Renovate's rule names no version; `bump_versions.py` refills the tarball checksum
  after a hand-edited minor. `Dockerfile.toolchain` declares the Python ARGs right above the CPython RUN, so the next
  upgrade leaves GCC, LLVM and Rust cached. The procedure: `docs/python-ci.md` § Upgrading Python.
- **Not built yet:** the chain (BACKLOG CON90), and the Windows half (CON91).

## 2026-10-12 — CON42: `nvblender` stays unusable, and the helper libraries stay out of `lib/gst-plugins/`

Two owner calls, taken with the recommended option:
- **No `nvblender` shim.** The `LD_PRELOAD` shim that restores `GstMapInfo` after unmap makes its blends succeed, but it
  switches GStreamer's check off for every caller in the process, and the two-input hang is NVIDIA's own (1.24.2 too).
  `nvblender` stays documented as "do not use"; a forum draft for NVIDIA waits for the owner's review, unposted.
- **NVIDIA's stock configs keep needing one edit.** A plugins-only link target would let `config_preprocess.txt` name
  `lib/gst-plugins/libcustom2d_preprocess.so` unchanged, but the registry scan would then segfault for anyone who puts
  NVIDIA's documented `lib/gst-plugins/` on `GST_PLUGIN_PATH` (it `dlclose()`s the helper libraries). The stock config
  fails loudly instead (`Could not parse custom lib path`), and `docs/consumer-image-contract.md` names the edit.

## 2026-10-12 — CON66: the suite on the installed cp314t wheel is a hub step

- **`linux/scripts/02-toolchain/python/test-free-threaded-wheel.sh`** runs a project's tests on the `cp314t` wheel
  `ci_packaging.sh` left in `dist/`: a fresh venv of the image's free-threaded interpreter gets the lock's set (`uv export
  --locked --no-emit-project`, `--extra` if given) and the wheel with `--no-deps`, and pytest runs in a directory outside
  the checkout that holds only the `--copy` paths, so the sources cannot shadow the compiled modules. `--env` reaches the
  pytest process, `--isolated` adds `python -I`, and the arguments after `--` go to pytest. It skips where the driver
  builds no twin (a cross build, `PYTHON_FREE_THREADED_WHEEL=off`, `auto` without the classifier), and fails on a declared
  project without a `cp314t` wheel of this arch. It replaces OrchestrANT's `ci_free_threaded_wheel_tests.sh` and
  WebDavClient's `test-free-threaded-wheel.sh`, which differed only in those knobs (`docs/python-ci.md` § The suite on the
  installed wheel). `tests/test-python-free-threaded-wheel-tests.sh`, 36 assertions, drives it against a fake uv.

## 2026-10-12 — CON83 closes: OrchestrANT imports pyplot lazily, its other two calls stay

- **`import orchestrant` loads no `matplotlib.pyplot` (OrchestrANT 9dbb86b).** pyplot was 0.72 s of the import's
  0.80 s on x64, and under riscv64 QEMU the import cost 31-37 s per subprocess (`bench_agent.py --list` took 41.9 s
  against a 60 s timeout). Now 86 ms on x64. `MetricsPlotter` imports pyplot on its first plot, and a test fails when
  the package import loads it again; no test patched `plotting.plt`, and the Cython build needs nothing new.
- **The other two owner calls stay as they are.** bench_agent's own grading keeps the venv's pytest plugins: its
  self-tests already disable their autoload for nested runs, where the QEMU cost was, and a native run pays 1 s, so a
  change would only move verdicts against older reports. The process ceiling stays probed once per process, so it
  cannot drift between launch and assertion (`bench_coding._nproc_ceiling`).

## 2026-10-12 — two WCOW probes settle #177's precondition and narrow #179; clang-cl needs `initialize()` first

- **#177: a secret reaches a Windows RUN as an env var, and leaves no trace.** A buildctl probe over `bk-windows-toolchain`
  (buildkitd v0.33.0) sets `SCCACHE_WEBDAV_ENDPOINT` through `--mount=type=secret,…,env=` in its RUN. The next RUN no
  longer sees it, and no file is left behind. The file form (`target=`) does leak on WCOW: the file stays in the
  snapshot, so the next RUN reads it and the layer carries it. Left: the ten compiling stages, at one planned re-key.
- **#179: the ~120 s tail follows sccache's graceful end.** One RUN per variant shows the tail with
  `sccache --stop-server` on either backend, with or without a compile, and with the server process already gone. A
  server killed with `Stop-Process -Force` costs 1 s, as no sccache does. TIME_WAIT under Windows' 120 s
  `TcpTimedWaitDelay` is the leading suspect, not yet isolated.
- **`docs/python-ci.md`: a project that sets the compiler's `cc` to `clang-cl` must `initialize()` it first.** The first
  `compile()` initializes lazily and puts `cl.exe` back. OrchestrANT (563e0fb) and WebDavClient (3a7aa8c) compiled
  their first extension with MSVC's `cl` until today. setuptools 84 never calls a `spawn` hook, so one cannot catch it.

## 2026-10-12 — #153 closes on three fresh chains; CON75's wheel loads on the device

- **#153, the step-time and silent-retry sweep, is done.** The 2026-09-01/02 logs it named were pruned, so it read the
  three complete chains left: bk-20261011-184301 and bk-20261011-233025 (amd64, the second rocm) and bk-20261010-121545
  (arm64), 51 logs in all. The 441.3 s lifecycle floor is gone, since a trivial RUN takes 4.9 to 9.0 s. One silent retry
  turned up in three chains: an `ActivateLayer 0x20` on rocm-llama's first RUN, green on attempt 2/3. No log has clipped
  output.
- **What it found beyond its question is seven new rows**, `docs/windows-refactor-backlog.md` #179 to #185:
  - #179: every RUN that started an sccache server idles ~120 s before DONE, 16 to 27 min per chain.
  - #180: a toolchain re-run relinks clang-cl, and the media stages then compile almost cold.
  - #181: the LiteRT layer keeps bazel's output base and checkout, which costs 25 to 44 min of export.
  - #182: GStreamer's meson build bypasses sccache on both arches, although the docs called it done.
  - #183: vendored code compiles under clang-cl's `/Wall`, so the arm64 VVL vertex is 97.9 % of a 768 MB log.
  - #184: the driver keeps no manifest of a failed run.
  - #185: bazelisk, the LiteRT JDK fallback and git-lfs are fetched unpinned and unchecked.

  CON89 points at #183 and #185, and the failure-modes and lanes docs are corrected where the sweep contradicts them.
- **CON75 is done.** OrchestrANT run 38221408508 (9964cc1, hub 7a5ab23c) built `cp314-cp314t-win_arm64` on the cross
  lane. Its `windows-11-arm` job imported all 64 compiled modules on free-threaded 3.14.8 with the GIL disabled.

## 2026-10-12 — the arm64 device gate runs an inference, not only an import (CON30)

- `Test-Arm64Bundle.ps1` has an eighteenth step, and the floor follows to 18. It builds an ONNX Runtime session over
  `Test-Container.ps1`'s 63-byte Identity model and asserts that `Identity(42.0)` returns 42.0 on the CPU EP. The step
  before it only imported onnxruntime and listed its providers, which proves the DLLs load and nothing computes.
- DirectML is tried first and its outcome printed, never graded: a `windows-11-arm` runner has no adapter. The CPU run
  is the step's last command, so its exit code alone decides, also under the workflow's
  `$PSNativeCommandUseErrorActionPreference`. In `:winamd64` the step passed with DirectML falling back on
  `No devices detected that match the filter criteria`.
- `Get-IdentityOnnxHex` in `TestHarness.psm1` reads the model's bytes from `Test-Container.ps1`. The arm64 gate's copy
  and the WebGPU probe's are both held equal to it. A mutation test runs the step's own body against a stand-in
  python that fails DirectML or the CPU run.
- `docs/windows-cross-builds.md`, `docs/windows-refactor-backlog.md` and `BACKLOG.md` CON30 no longer say that nothing
  executes on arm64 or that the gate has nine or seventeen steps. A camera and a GPU EP are what stays unproven.

## 2026-10-12 — the device gate's twin proof installs again: a one-element array no longer splats into characters

- Since a2ce8627 (CON79), `Invoke-TwinDeviceProof` built pip's arguments as `$resolve = if (...) { @(...) } else { @('--no-deps') }`.
  PowerShell unrolls a one-element array that an `if` returns into a string, and `@resolve` then splatted it one character
  per argument. pip refused `-` for all four twins, so `windows-arm64.yml` failed three runs in a row (38180134179,
  38205155401, 38209436310). OrchestrANT's CON75 kit runs the same proof, so its device run would have failed the same way.
- `Get-TwinInstallArgument` returns the words as a `[string[]]` in every case. A behavioural test splats them into
  `cmd /c echo` and expects `--no-deps` whole, and `--find-links` on the store and its `deps\` when that exists.
- `WindowsFormatting.Common.psm1` had the same shape: without a format config, `$mode + @($cmakeFile)` concatenated
  `--check` onto the file name. It is wrapped in `@()` now.
- `Lint.ScalarSplat.Tests.ps1` scans `windows\scripts` for an `if/else` with a one-element `@(...)` branch whose variable is
  splatted. It allows one known site, the `vswhere -latest` selector in `WindowsScripts.Shared.psm1`, and BACKLOG CON89 keeps
  it. That splat is why every chain logs `vswhere returned no installation; using filesystem fallback`. Fixing it re-keys
  `Dockerfile.base`, so it waits for the next planned full rebuild.
- `windows-arm64.yml` also runs on a change to `WindowsPythonWheel.Common.psm1`, which the gate now imports.

## 2026-10-12 — the canonical `.clang-format` no longer reflows comments; CON71 is done

- `shared/config/.clang-format` sets `ReflowComments: Never`, by owner decision today. With `true` at
  `ColumnLimit: 120`, clang-format split a one-line comment over 120 columns into two lines, which
  `verify_comment_size.py` rejects. OmniAccelerANT's plugin sweep hit it (`linux/runtime_paths.cc:1`, shortened in
  its 39833e7). `Never` is the spelling clang-format 23.1.3 dumps.
- Measured in `:latest` (`b52f8c34…`) over each consumer's format file set: nothing changes in AccelerANTgine (39
  files) or OmniAccelerANT's plugin (15). In BeschleunigerBallett 2 of 217 files change: three two-line trailing
  comments lose the alignment of their second line. `shared/config/README.md` § *`ReflowComments: Never`* says to join
  such a pair into one line.
- **CON71 is done and pruned from BACKLOG.md.** The Linux half shipped in the `:latest` of 2026-10-09 (hub 655a2c4e),
  the Windows half in `:winamd64` `e96203a8…` (21 tools at 23.1.3). Every consumer formats and checks with 23.1.3:
  AccelerANTgine e96b31b and its Linux format check, BeschleunigerBallett's sweep d59d210f, and OmniAccelerANT's
  plugin f3a0994 with its gate eca72a0.

## 2026-10-12 — `tensorrt.conf` only where a TensorRT build put its lib dir (CON31)

- The published `:latest-nvidia` (`23e3cc9e…`) carried `/etc/ld.so.conf.d/tensorrt.conf` naming `/usr/local/tensorrt/lib`,
  which no nvidia build ships with `ENABLE_TENSORRT=false`. `configure-runtime.sh`'s `write_tensorrt_conf` writes it only
  when the lib dir exists, and removes a stale one otherwise; DeepStream's TensorRT 10 keeps its own
  `010-deepstream-tensorrt.conf`. `test-soname-precedence.sh` covers both; the next nvidia chain proves it in the image.

## 2026-10-12 — DeepStream runs on the published `:latest-nvidia`; `nvblender` does not (CON42, CON31)

- **The GPU run on the published image passed.** `:latest-nvidia`, index sha256:810f36b3 (amd64
  sha256:23e3cc9e), ran as pulled on the RTX 2080 (driver 595.58.03, CDI, rootless nerdctl). Every row of
  the 2026-10-01 table holds:
  - the gate engine was built for sm_75, and 1442 frames with 30214 objects went through `nvdsosd`;
  - the NvDCF tracker, the demux and `nvurisrcbin` ran, all as uid 1001 too;
  - `deepstream-verify.sh` with `DSV_WIRED=1` passed with the GPU attached.
- **15 of the 21 prebuilt plugin files ran with sample data** (CON42's open question). All reached EOS
  with sound output, except the known legacy mux and:
  - `nvblender` takes its output surface from `GstMapInfo.data` after unmap, which GStreamer ≥ 1.28
    clears. An unmap shim and GStreamer 1.24.2 each give it a valid surface.
  - The AV1 encoder fails because Turing has none.

  `nvblender` also stalls with two inputs on 1.24.2.
- **Consumer facts, in a new `consumer-image-contract.md` § DeepStream in `:latest-nvidia`:**
  - The toolkit's `enable-cuda-compat` hook may run CUDA on the image's compat libcuda. DeepStream ran on
    it and on the host's.
  - A GStreamer registry scanned without a GPU keeps DeepStream blacklisted.
  - NVIDIA's `config_preprocess.txt` names a helper path the image moved.
  - `nvdewarper` needs `num-surfaces-per-frame` on the new mux.
  - uid 1001 needs a writable engine path.
- **CON31:** the published image has no TensorRT 11. Its only `libnvinfer` is DeepStream's TensorRT
  10.16.1, which `ldconfig -p` resolves. `tensorrt.conf` names a `/usr/local/tensorrt/lib` that does not
  exist.
- `docs/linux-accelerator-images.md` no longer calls `:latest-nvidia` unpublished, and no longer claims
  the compat libcuda is for data-centre GPUs only.

## 2026-10-12 — the Linux backlog closes CON72, the CON83 lane and CON66's consumer half; CON78 Linux and CON79 1b proved

- **CON72 is done:** every consumer is green on its post-image pin, Linux and Windows lanes alike: OmniAccelerANT
  5a6492c, OrchestrANT b599448, WebDavClient 5ab44f4, BeschleunigerBallett b693d37, AccelerANTgine 2aefb1d/4b5dffd,
  OxidANT 4412001, jotrockenmitlocken 401acff.
- **CON79 1b is done:** the `:latest` of 2026-10-11 (index sha256:b52f8c34, run 20261011-125540) proves the riscv64
  torch twin in `FT-STORE` and every cross twin on arm64 and riscv64.
- **CON83's lane is done:** OrchestrANT run 38171396906 (riscv64) restored the uv cache seed, built no numpy, passed the
  cross wheel's smoke and ran its bench rows with shellcheck and hadolint; 2539 tests green. The owner calls stay `[b]`.
- **CON66's consumer half is done:** both consumers' `3.14` and `3.14t` legs log `the image's own interpreter,
  UV_PYTHON_DOWNLOADS=never` on x64 and arm64, OrchestrANT's riscv64 `3.14` leg too, and `uv_venv_create 3.14t` in the
  published riscv64 child took `/opt/python-freethreaded` 3.14.8 with the GIL off.
- **CON78, Linux 0–3:** read in the published `:latest-rocm` — `extras-10` copied, no absolute or dangling link under
  `/opt/rocm`, `000-rocm.conf` resolving `libmigraphx_c` and `libamdhip64`, the MIGraphX provider library loading.
- **CON82's last Linux item:** OmniAccelerANT's app flatpak (Linux x64 run 38158462860) and its cat cam flatpak (web run
  38158462452, x64 and arm64, installed and removed by `test-catcam-package.sh`) build on `org.freedesktop.Platform/26.08`.
- **CON84 (3):** OmniAccelerANT's Dart and Flutter floors follow its lock (467ca34), with the frb bindings and l10n
  regenerated rather than hand-formatted.

## 2026-10-12 — the Windows arm64 cross lane ships a free-threaded wheel and proves it on the device (CON75)

- `Invoke-CiPackaging.ps1` no longer skips `cp314t` on a cross arch. It starts `New-CrossFreeThreadedWheel.ps1`, which
  builds the wheel and gates it.
  - **The build.** The host's x64 3.14t runs it in VS's x64_arm64 environment, from a venv that pins `EXT_SUFFIX` to the
    target. A `DIST_EXTRA_CONFIG` names the target for every `build_ext` and `bdist_wheel` instance. The link uses the
    target tree's `python314t.lib`.
  - **The gates.** It checks the tags, the `python314t.dll` imports and the ARM64 machine of every PE member.
  - **The kit.** It packs the wheel into `dist\windows-arm64\free-threaded\` with the target interpreter and the proof.
- `container-ci-windows.yml`'s arm64 run job proves the wheel there with `Test-FreeThreadedWheel.ps1`. A product without
  the directory passes with one line.
- `Invoke-TwinDeviceProof` moved from `Test-Arm64Bundle.ps1` into `WindowsPythonWheel.Common.psm1`, so the bundle gate
  and the consumer kit run one proof. The gate imports its modules through `Import-GateModule`, and
  `Export-Arm64Bundle.ps1` packs the wheel module beside it.
- `Get-FreeThreadedWheelPlan` takes `-TargetLib`. A cross arch is skipped only when the image has no target tree.
- In `:winarm64` (`ba6bfaae…`), OrchestrANT 0.0.30 built `orchestrant-0.0.30-cp314-cp314t-win_arm64.whl` this way.
  The wheel passed all three gates, and the kit came out complete. The project's half is one line: `clang-cl` needs
  `--target=aarch64-pc-windows-msvc` on a cross build.

## 2026-10-12 — the rocm chain builds without the HIP/MSVC `<cmath>` overlay (CON78)

- Hub 28daad33's `:winamd64-rocm` chain (20261011-233025, then `-Stages final` as 20261012-051453) built every stage with
  TheRock's clang as AMD ships it, with no `clang.cfg` and no overlay:
  - MIGraphX 2.18.0 and its EP in 11:44 min;
  - `ggml-hip` with device code for gfx1201 and gfx1200;
  - torch 2.14.1+rocm10.1.0 (HIP 7.16.26385) and torchvision 0.29.1 in 59 min.
- Smoke gate: 265 passed, 0 failed, 1 skipped. All eleven rocm-checks passed, among them `kernel compiled for gfx1201`.
  The publish gate was clean, and the image's manifest is `cea5c3fb…`.
- The first run stopped before the final stage on the disk gate: 18.4 GB free, below the stage's 40 GB. BuildKit freed
  space on its own, so `-Stages final` ran on cached stages at 46.8 GB.
- The llama stage's first RUN failed at layer activation with `0x20` (CON86), and the driver's retry built it.

## 2026-10-11 — the arm64 bundle carries its cp314t twins' dependencies (CON79)

- The `:winarm64` bundle has shipped `cp314t` twins of onnxruntime, av, apache-tvm-ffi and iree-base-runtime since
  2026-10-07. Their dependencies were staged for cp314 only, so a consumer installed a twin with `--no-deps`, and the
  device proof did the same.
- `Copy-TargetPythonDeps.ps1` now runs a second pass after the GIL store. It reads each twin's `Requires-Dist` and
  downloads the requirements for the target into `wheels-cp314t\deps`, as `cp314t` or ABI-free wheels. It passes no
  `abi3`, which the free-threaded ABI cannot load.
- The pass fails when a staged wheel carries another ABI, or when a twin's or a dependency's requirement resolves in
  neither directory. The store's top keeps the twins alone, so the merge's mirror gate reads it as before.
- PyPI carries all six dependencies today: numpy 2.5.4 and ml_dtypes 0.6.0 as `cp314t-win_arm64`, and flatbuffers,
  packaging, protobuf and typing-extensions as pure wheels.
- The device gate installs each twin with `--find-links` on both directories, offline, before `free-threaded-wheel.py
  prove`. A bundle without `deps\` still gets each twin alone.
- The download and the requirement gate are now functions that both passes share (`Save-TargetRequirement`,
  `Get-UnresolvedTargetRequirement`), and `SourceBuild.StageTargetPythonDeps.Tests.ps1` covers them.

## 2026-10-11 — TheRock's clang ships as AMD builds it: the HIP/MSVC `<cmath>` overlay is retired (CON78)

- Since 2026-09-25 the rocm image has carried `windows/scripts/hip`: two wrapper headers that rename `isgreater` and its five
  siblings around clang's HIP math headers, loaded by a `clang.cfg` and `clang++.cfg` beside TheRock's `clang.exe`. Without
  them, every HIP compile against MSVC 14.51's `<cmath>` failed with 20 errors.
- TheRock 10.1.0 no longer needs them. In the published `:winamd64-rocm` (`32c7cc51…`; MSVC 14.51.36231, AMD clang
  24.0.0git), the probe compiled its kernel with `--no-default-config`, which drops the overlay, through `hipcc`,
  `clang -x hip` and `amdclang++ -x hip`.
- `Dockerfile.rocm` no longer installs the configs or the headers. The overlay, both configs and the probe
  `Test-HipMsvcCmath.ps1` left the tree, and `Rocm.Migraphx.Tests.ps1` now holds every rocm Dockerfile free of them.
- The smoke gate's one-line `hipcc` kernel stays the canary: a toolset or TheRock bump that brings the clash back fails it
  with the same 20 errors. The next rocm chain has to build MIGraphX, the EP, `ggml-hip` and torch without the overlay.

## 2026-10-11 — CON63, CON80, CON82 and CON87 proved, CON71's Windows half done

- **CON63:** the hub's own device gate passed 17 of 17 on `windows-11-arm`, the WebRTC loopback included
  (`windows-arm64.yml` run 38170783445 on 5bcd214c, `:winarm64` `ba6bfaae…`). The arm64 WebRTC contract holds:
  the cross-built gst-plugins-rs and the aarch64 `ffi-7.dll` (proved at the 2026-10-10 merge) carry a
  webrtcsink → webrtcsrc call over DTLS-SRTP on the device.
- **CON80:** the in-place site-packages merge passes in the published images. In `:winamd64` (`e96203a8…`, smoke run
  2026-10-11), `Cython.Shadow` imports and all 31 RECORD files spell their entries as on disk. The `:winarm64`
  (`ba6bfaae…`) passed the same two checks over its 12 distributions at its chain's smoke gate (run
  20261010-121545).
- **CON82, the Windows items:**
  - The published `:winamd64` resolves `VULKAN_SDK` to scoop's vulkan 1.4.363.0, with `Bin-ARM64` and
    `Lib-ARM64`.
  - The published `:winamd64-rocm` (`32c7cc51…`) ships the 1.4.363.0 loader (`C:\vulkan-loader` and the lavapipe
    copy). Its FFmpeg lists the `vulkan` hwaccel, and `llama-cli --version` reports build 11476, commit 988190680.
  - x265 4.2 built and verified its SHA256 in the 2026-10-11 chain.
  - The arm64 Vulkan-ValidationLayers load in `vulkaninfo` on the device (run 38170783445).
  - OmniAccelerANT built and installed its flatpaks on runtime 26.08: `web.yml` run 38158462452 and Linux x64 run
    38158462860, both on fafa9f3.

  With the Linux half proved on 2026-10-09, the row is closed.
- **CON87:** the Windows chain no longer rebuilds over a Linux-only `versions.env` edit.
  - The first full chain on it (20261011-184301, 3:37 h) rebuilt above base once. Smoke: 268 passed, 0 failed,
    1 skipped.
  - Then `CMAKE_VERSION_RISCV64` moved 4.4.4 → 4.4.9, a temporary edit, and the next chain (20261011-222153) took
    14 min. base, toolchain, all seven media stages and the merge came back CACHED, with the same manifests as the
    run before (base `1b332f1d…`, toolchain `f1353638…`).
  - Only torch re-ran, because OrchestrANT's develop had moved 179e1e1 → b599448f. final followed it.
  - Smoke: 268 passed, 0 failed, 1 skipped. The publish gate was clean.
- **CON71, Windows:** the published `:winamd64` passes `Test-Container.ps1`'s 21-tool check, every tool at 23.1.3.
  The native plugin's reformat in OmniAccelerANT is the row's last item.
- **CON88, new:** Python in the Windows images trusts only the 18 roots that the Server Core store ships, so
  `ftp.osuosl.org`, the target of downloads.xiph.org's redirect, fails `CERTIFICATE_VERIFY_FAILED`. Meson's
  wraps fall back to GitHub; `truststore` verifies the same URL. Cause and fix in the BACKLOG.

## 2026-10-11 — a Python leg in the image takes the image's interpreter or fails; it never downloads one (CON66)

- `uv_venv_create` (`linux/scripts/01-core/python_uv.sh`) runs `uv venv` with `UV_PYTHON_DOWNLOADS=never` for
  `PYTHON_MAJOR_MINOR` and its `t` twin when the shipped image's ENV (`PYTHON_MAJOR_MINOR`, `PYTHON_CROSS_ACTIVE_ROOT`)
  says the image ships them, and `uv_ensure_python_available` no longer runs `uv python install` for those. A missing
  one fails the leg with `python3.14t is missing, though this image ships it`. Other versions, runs outside the image
  and a caller's own `UV_PYTHON_DOWNLOADS` keep their behaviour.
- Proved in the `:latest` amd64 child against WebDavClient 3096c57: the `3.14` leg took `/usr` 3.14.4 and the `3.14t`
  leg `/opt/python-freethreaded` 3.14.8, both with downloads off, 22 and 23 tests green. With `python3.14t` hidden from
  `PATH`, the previous code downloaded a free-threaded CPython and the leg passed; this one fails it.
- `test-uv-python-request.sh` covers the image, a missing interpreter, the GIL leg, a version the image does not ship,
  the caller's override and a bare host; with the image check disabled, 5 of its 21 assertions fail.

## 2026-10-11 — the WebRTC loopback waits for the producer to register (CON63)

- The first `windows-arm64.yml` run uploaded the loopback's logs, and they show a race in the harness, not a broken
  bundle. The consumer started as soon as the signalling server listened, and its `list` reached the server 19 ms
  before webrtcsink registered as a producer. With `connect-to-first-producer` and no listener role it never heard of
  the producer, and the pipeline sat in PLAYING until the 90 s timeout.
- On arm64 webrtcsink needs ~0.8 s to pick its H.264 encoder: it probes Media Foundation devices and lands on
  `mfh264enc`. On amd64 the choice is quick, so the producer won the race there.
- `Invoke-GstWebRtcLoopback` now waits up to 30 s for `registered as [Producer]` in the server's log before it starts the
  consumer, and fails with that sentence if the line never comes. It still passes in `:winamd64`.


## 2026-10-11 — the hub gates its own arm64 bundle; no consumer lane hosts it any more

- The bundle device gate grades the image's whole `C:\runtime`: GStreamer and WebRTC, HailoRT, IREE, ORT and the
  Python wheels. Since 2026-10-03 it ran inside consumer cross lanes that set `bundle-artifact-name`, and only
  BeschleunigerBallett did. Its first WebRTC failure (run 38156104572) turned the renderer's lane red and skipped its
  GPU suites, which hang off the whole `container-ci-windows.yml` call, over a component the renderer never uses.
- `windows-arm64.yml` ("Windows arm64 · bundle device gate") now runs it, daily and on a push to the gate's files. A
  `windows-2025` job pulls the published `:winarm64` and packs its bundle with `Export-Arm64Bundle.ps1`. A
  `windows-11-arm` job runs `Test-Arm64Bundle.ps1`, and uploads `winarm64-bundle-webrtc-logs` when it fails.
- `container-ci-windows.yml` loses `bundle-artifact-name`, its export and upload steps and the `bundle-gate` job.
  BeschleunigerBallett dropped the input first (9e029676).

## 2026-10-11 — the WebRTC loopback says why it stalls, and the arm64 device job keeps its logs (CON63)

- Its first device run timed out: BeschleunigerBallett run 38156104572 passed 16 of 17 on `windows-11-arm`, and
  webrtcsrc reached PLAYING and decoded nothing in 90 s without a single error line from either process.
- `Invoke-GstWebRtcLoopback` sets `GST_DEBUG` to warnings plus INFO for webrtcsink, webrtcsrc, webrtcbin, nice and
  DTLS when the caller set none, and restores it. A failure now carries 12 lines of all four logs and their path.
  In `:winamd64` the loopback still passes, with 66 INFO lines in its stderr logs.
- The device gate writes them under `RUNNER_TEMP`, and `container-ci-windows.yml` uploads them as
  `<bundle-artifact-name>-webrtc-logs` when the gate fails.

## 2026-10-11 — the arm64 device gate runs all 17 steps on every bundle, the WebRTC loopback among them (CON63, CON64, CON67)

- The published `:winarm64` (`ba6bfaae…`) passed its device gate on `windows-11-arm` in BeschleunigerBallett run
  38100828628: 16 of 16, the validation layer loading in `vulkaninfo` (CON64) and the pinned pytest stack, pytest 9.1.1,
  installing offline from the wheel store (CON67). OrchestrANT's arm64 run 38086634226 staged its tests from that store.
- So the four steps that ran only in a bundle that shipped their component (the free-threaded interpreter, the cp314t
  twins, the pytest stack, the validation layer) now run on every bundle, and `Invoke-ShippedBundleStep` is gone.
- A new step runs the amd64 smoke gate's WebRTC loopback with the bundle's `gst-launch-1.0.exe`: webrtcsink to
  webrtcsrc, 60 frames over DTLS-SRTP (CON63). Both gates grade it through the new `Assert-GstWebRtcLoopback`, which
  `Test-Container.ps1`'s copy of that verdict moved into. `Export-Arm64Bundle.ps1` puts `WindowsGstPlugins.Common.psm1`
  and its arch sibling beside the gate. In that layout the step passed in `:winamd64`.
  Its first device run is the next BeschleunigerBallett arm64 run on a hub pin that has it.
- `-MinPassed` defaults to 17, every step, and `Smoke.Arm64Bundle.Tests.ps1` holds the floor to the step count.

## 2026-10-11 — a Linux-only `versions.env` edit leaves the Windows chain cached (CON87)

- `Dockerfile.base` copied all of `linux/scripts/01-core/versions.env`, and the toolchain stage mounted it into
  its LLVM RUN, so a riscv64 pin bump (655a2c4e) turned the 2026-10-09 `:winamd64-rocm` publish into a 4:45 h
  rebuild. `Build-Buildkit.ps1` now writes `windows/generated/versions.env` on every run
  (`Write-WindowsVersionsEnv`), and the base COPY, both toolchain mounts and the merge re-COPY read it instead.
- The filtered file keeps every key in source order and drops comments, plus the Linux-only keys: those
  `$script:LinuxOnlyVersionKeyPattern` matches (Android, DeepStream, Chrome, riscv64, Linux tarballs and the like),
  unless the name says `WINDOWS` or a Windows script, Dockerfile or mounted Linux file names it. Today that is 101 of
  412 keys; `CMAKE_POLICY_VERSION_MINIMUM`, which CMake reads from the environment, stays.
- Proved on the base stage: with `CMAKE_VERSION_RISCV64` and `DEEPSTREAM_VERSION` moved and a comment added, a
  second `-Stages base` was CACHED end to end, manifest `1b332f1d…` both times. The next chain run rebuilds above
  base once. `BuildDriver.WindowsVersionsEnv.Tests.ps1` checks the filter, that every key a Windows stage is
  forwarded or declares stays, and that no chain Dockerfile reads the unfiltered file. The context-path gate
  (`verify_dockerfile_context_paths.py`) lists the file under `GENERATED` with the driver as its producer.

## 2026-10-11 — the arch gate reports pip's and setuptools' launcher templates instead of failing on them

- OrchestrANT's Windows x64 app bundle failed its gate on the new pin (run 38086634222): `4 violation(s)`, all in the
  runtime's `ensurepip\_bundled\pip-26.2.1-py3-none-any.whl` — distlib's `t32`/`w32` (I386) and `t64-arm`/`w64-arm`
  (ARM64). The gate machine-checks wheel members since fbf9c369, and pip ships one launcher template per arch on
  purpose: the installer copies the target's when it writes a script. The image gate never saw it, because the
  Dockerfile's `ARCH_GATE_HOST_TOOLS` already names those paths; `New-PythonAppBundle.ps1` passes no pattern.
- `Test-TargetArch.ps1 -LauncherTemplatePattern` (on by default) lists distlib's `t32`, `t64`, `t64-arm`, `w32`, `w64`,
  `w64-arm` and setuptools' `cli`/`gui` launchers per arch as templates, prints them and leaves them out of the count. A new test
  packs all six into a pip wheel: the amd64 bundle passes, and an ARM64 binary that is no template still fails beside them.

## 2026-10-11 — the hub's own lanes are green again: the wheel smoke grades the import, two Windows tests caught up

- **The riscv64 wheel smoke passed a package whose import raises.** Since 9e3b7cba, `free-threaded-wheel.py`'s
  `enclose()` registers a package whose import fails with its body unrun, so the compiled modules under it can load.
  `wheel-smoke.py` called `load_all` first, and its own `import_module` then returned that stub without an error.
  `test-wheel-smoke.sh` failed on it in every preflight since, and the three `wheel-smoke.*` mutations read as vacuous.
  The smoke now imports the package before `load_all`; 18/18 assertions pass in `:latest` and all three mutations bite.
- **`media-core-view` and `media-tvm-view` redeclare `WINDOWS_TARGET_ARCH`**, as `TargetArch.Common.Tests.ps1` asks of
  every stage that RUNs over an external image (CON86's views had none). The next Windows chain rebuilds the two empty
  views and the merge above them.
- **`Get-FreeThreadedTwinPlan`'s test names an unlisted distribution that stays unlisted.** It used `numpy`, which
  6276a9be added to the twin table (`twin:FT_TORCH_TWIN`), so the expected throw never came.

## 2026-10-11 — the nvidia and rocm ORT cp314t twins are proved in the published images (CON79 1)

- BACKLOG CON79 1 listed them as open ("one call each"). The call has been in `30-build-native-nvidia.sh` and
  `30-build-native-amd.sh` since e2651106 (2026-10-07), and both published GPU images already carry and prove the twin.
  The build logs show it:
  - **rocm**, chain run 20261009-152508 (`:latest-rocm`, index sha256:a5d68fbe). The MIGraphX pass over
    `build_native_gpu_migraphx` took 57 s and rebuilt no HIP object (the GIL pass built 590) and 106 C++ objects. It
    stored `onnxruntime_migraphx-1.30.0-cp314-cp314t`.
  - **nvidia**, media run 20261010-202726 (`:latest-nvidia`, index sha256:810f36b3, run 20261011-040056). The CUDA pass
    over `build_native_gpu` took 32 s, 192 s on the first run, 20261010-125556. It rebuilt no CUDA object (the GIL pass
    built 578), and its 664 C++ compiles came from the compiler cache. It stored `onnxruntime_gpu-1.30.0-cp314-cp314t`.
  - Both runtime smokes pass `FT-STORE`, with the flavour's twin and `onnxruntime_dnnl` loaded with the GIL off. They
    pass the ORT census, which grades the twin's members against the GPU `ort-provenance-cp314t.sha256`.
- **Proved without a chain: the pass compiles against `3.14t`.** It reruns `build.sh` with the GPU build's own
  `BUILD_ARGS` and build dir and appends only `Python_EXECUTABLE=<3.14t venv>`. On a scratch project with ORT's
  `find_package(Python 3.10 COMPONENTS Interpreter Development.Module NumPy)`, CMake 4.4.4 then re-resolved a warm GIL
  cache to the `3.14t` include dir, NumPy include and `cpython-314t` SOABI, and its module built behind an
  `#ifndef Py_GIL_DISABLED #error` guard. With a GIL `Python_INCLUDE_DIR` carried in the args, the include dir stayed
  the GIL one: the riscv64 torch twin's bug of 2026-10-10.
- **Tests.**
  - `test-free-threaded-wheels.sh` runs `onnx_build_free_threaded_wheel` against a stub `build.sh` with CUDA-shaped
    and MIGraphX-shaped args. The pass must keep the GIL args (same `--build_dir`) and put the venv interpreter last,
    in argv and in the environment. It must name no include dir and store into `<output>/wheels-cp314t`. A failed
    pass stores nothing, and a cross MIGraphX build without `--build_wheel` runs none. The wiring case also holds
    each `30-build-native*.sh` to ending on the pass over its own `BUILD_ARGS`, with no Python include define.
    8 mutations, all red: drop or reorder the override, add a GIL include, drop the env, store into `wheels`,
    use a fresh build dir, move the nvidia call up, add an include define to the rocm args.
  - `test-free-threaded-store.sh`: `FT-STORE` requires the installed flavour's own twin for `onnxruntime_migraphx`
    as well as `onnxruntime_gpu`, and fails it unproved.
  - `test-uv-chain-ort.sh`: in a GPU image, a `3.14t` venv's reconcile takes the `onnxruntime_gpu` or
    `onnxruntime_migraphx` twin and never the `onnxruntime_dnnl` one beside it. It fails when the flavour filter in
    `_uv_chain_ort_wheels` is dropped.
- Docs: `consumer-image-contract.md` § *The free-threaded wheels* (the GPU rows of the twin-pass table, why the warm
  reconfigure takes the `3.14t` headers, and the GPU images' `FT-STORE`), `linux-accelerator-images.md`.

## 2026-10-11 — `:latest-nvidia` published with DeepStream 9.1 (CON42)

- Index sha256:810f36b38714b423652902ed35f4b221d36f868639a83a3b4da47c476b4a033e (amd64
  sha256:23e3cc9e5bbbfc64d8395e1d171faa56c89e9b09cbb95bedcba225110fe4bdd5), chain run 20261011-040056-e2d41cc6 on hub aabebdbc;
  media and android from runs 20261010-202726 (c9f638f0 + 804227fd).
- The first nvidia build with `ENABLE_DEEPSTREAM=true` by default: 48 DeepStream components built from 581889df, the media
  stage's DeepStream gates and the runtime smoke's `check_deepstream` pass, wrapper-smoke and the 15/15 runtime checks pass.

## 2026-10-11 — the registry blacklist check scans a GPU-less nvidia image with the CUDA driver stubs (CON42)

- The first `:latest-nvidia` runtime smoke with DeepStream (run 20261011e) passed `check_deepstream` but failed
  `_gst_check_blacklist`: 30 DeepStream plugins link the driver's `libcuda.so.1`, which a GPU-less smoke container lacks, so
  the core registry blacklisted them.
- The probe now links `libcuda.so.1` and `libnvidia-ml.so.1` to `${CUDA_HOME}/lib64/stubs` on a private registry when the image
  has the stubs and no driver libcuda, as `deepstream-verify.sh`'s element check does. In that image only
  `libnvdsgst_ucx.so` stays blacklisted (`libucs.so.0`, documented in `DSV_ALLOWED_MISSING`), which the check reports as a
  documented exception; every other blacklisted plugin still fails it. `test-gst-validate-ssim.sh` covers both.


## 2026-10-10 — `Get-SelectedConfigurations` returns the set, and a cleared selection selects nothing

- BeschleunigerBallett's `Build-Windows.ps1 -SkipBuild` died after its format gate: `Cannot bind argument to parameter
  'SelectedConfigurations' because it is an empty string`. The bare `return` unrolled the HashSet into an array, whose
  `.Clear()` only nulls the elements, and a single selection (its agentic loop's `-Configurations clangcl-debug`) came
  back a string that has no `.Clear()` at all.
- `Get-SelectedConfigurations` returns the set itself (`return , $set`), and `Test-ConfigurationSelected` takes an empty
  one (`[AllowEmptyCollection()]`). A test in `WindowsConfig.Common.Tests.ps1` needs both; without either half it fails.

## 2026-10-10 — DeepStream's build-stage gates load /opt/gstreamer's core, as the final image does (CON42)

- With the components building, run 20261010-193517 stopped in `deepstream-verify.sh`: `one GStreamer` (every plugin's
  `libgst*` resolved to `/usr/lib/x86_64-linux-gnu`), `soname closure` (`libgstrtspserver-1.0.so.0` not found) and six
  of nine elements not registering (`nvinfer`, `nvstreammux`, `nvtracker`, `nvdsosd`, `nvstreamdemux`, `nvurisrcbin`).
- Cause, reproduced with `--target deepstream`: the `gstreamer` stage carries a distro GStreamer 1.28 core (the
  toolchain's `software-properties-common` -> `packagekit` -> `libgstreamer1.0-0`; the gstreamer stage's
  `gir1.2-gstreamer-1.0` and `libgtk-4-dev` add base, GL and extra) and no `000-gstreamer.conf`. `ld.so` handed even
  `/opt/gstreamer/bin/gst-inspect-1.0` the 1.28 core, and `GST_DEBUG=2` shows it refusing each component built against
  1.29: `has incompatible version (plugin: 1.29, gst: 1.28), not loading`. NVIDIA's prebuilt plugins registered,
  which is why three elements passed. The final image purges the distro packages and writes the conf, so the
  2026-10-01 spike never saw this.
- `ds_build` now writes the same `000-gstreamer.conf` that `configure-runtime.sh` writes (`ds_write_gst_ldconf`) before
  its gates. The stage's `/etc` stays in the stage: the image copies only `/opt/nvidia` from it.
- A new gate, `dsv_check_gst_core`, fails when `gst-inspect-1.0` itself loads a core outside `/opt/gstreamer`, so a
  registration verdict can no longer be made against another GStreamer. The local stage build passes every gate
  (48 components, 9/9 elements). `test-deepstream.sh` covers the conf, its order in `ds_build` and the new gate.


## 2026-10-10 — DeepStream's components find /opt/gstreamer through pkg-config in the media build stage (CON42)

- The first nvidia chain with DeepStream on by default (run 20261010-125556) stopped in `Dockerfile.media`'s `deepstream`
  stage: `Package 'gstreamer-1.0' not found`. The spike ran FROM the published image, whose final stage exports a
  `PKG_CONFIG_PATH` naming `/opt/gstreamer`; the build stage (FROM `gstreamer`) exports none.
- `ds_build_components` now prepends the directory of `/opt/gstreamer`'s `gstreamer-1.0.pc` (`ds_gst_pkgconfig_path`), and
  refuses by name when there is none. `test-deepstream.sh` covers both.

## 2026-10-10 — `:latest` republished: the cross cp314t twins, the riscv64 uv seed and the lint tools are in (CON75, CON79 1b, CON83)

- Index sha256:30dea85c2b3fbb89b79f042333cfd5e4940eb20027b44ed5c35639bd49fb0eea (amd64 ef6b32bd, arm64 f2a72d27,
  riscv64 0043342b), chain runs 20261010-002002 (riscv64 media) and 20261010-010337 (android, runtime) on hub 381431d1.
- `FT-STORE` passes on all three arches. amd64 keeps its five native twins; arm64 and riscv64 each prove apache-tvm-ffi,
  av, iree-base-runtime and onnxruntime_webgpu under the target 3.14t with the GIL off. `FT_TORCH_TWIN` was 0 for this
  run; the fixed torch twin (9e3b7cba) lands with the next chain.
- riscv64 builds hadolint 2.15.1 from source once (about 4 h under QEMU) and seeds `/opt/uv-cache-seed` with 8 wheels,
  proved by a fresh sync that builds nothing. Every arch's contract reads `OK lint-tools shellcheck=0.11.0 hadolint=2.15.1`.
- Runtime smokes: amd64 and arm64 15/15; riscv64 14/15 with its known warning (no `iree.compiler` on riscv64).

## 2026-10-10 — the arm64 fan-in: VVL compiles without sccache, and the target deps gate reads markers

- **The arm64 VVL build hung in sccache, twice.** On Vulkan SDK 1.4.363 the compile of
  `vk_validation_error_messages.cpp` sat in the sccache server with no compiler running: 70 minutes at `-j9`, then
  again in the driver's `-j1` retry, until both processes were stopped by hand. The file emits thousands of
  `-Wc++98-compat` warnings. Without sccache it compiles in 82 s. `Build-VulkanValidationLayers.ps1` now
  clears the C/C++ launchers for the layer itself; its dependencies keep sccache. Only the arm64 lane builds the
  layer from source, since amd64 takes the SDK's.
- **The target deps gate failed on two requirements that do not apply.** pytest 9.1.1, now a bundle wheel, declares
  `exceptiongroup>=1; python_version < "3.11"` and `tomli>=1; python_version < "3.11"`. The pip download skipped them
  for cp314, but `Copy-TargetPythonDeps.ps1`'s gate dropped only `extra ==` markers, so it called both missing.
  `Select-ActiveRequirement` now evaluates each marker for the target (python_version, `platform_machine` from the
  wheel tag, win32) with pip's vendored packaging, and a marker it cannot evaluate fails the gate. The next arm64
  solve passed it: 53 wheels, every Requires-Dist resolved. `SourceBuild.StageTargetPythonDeps.Tests.ps1` covers it
  with three cases on the host Python.
- **The arm64 arch gate then failed on 26 launcher EXEs in pure wheels**: pip's distlib `t32/t64/w32/w64.exe` and
  setuptools' `cli/gui(-32|-64).exe`, in both target CPythons' `ensurepip` and `test\wheeldata` and in the store's
  setuptools 84.0.0. The merge Dockerfile's `ARCH_GATE_HOST_TOOLS` default already skips those launchers, but
  `Build-Buildkit.ps1` replaces it on the cross lane with an older list that never had them. The launchers only
  arrived with the two target CPythons of 2026-10-07. The driver's pattern now repeats every alternative of the
  default, and `Driver.ArchGateHostTools.Tests.ps1` fails when one is dropped; against the old driver it names the two.

## 2026-10-10 — HailoRT's patch 001 guards the x86 include too, so arm64 compiles with the patches

- **The first `:winarm64` chain after CON85 stopped in `hailort.cpp`.** clang's `immintrin.h` refused the aarch64
  target (`This header is only meant to be used on x86 and x64 architecture`). `quantization.hpp` includes it under
  `#if defined(_MSC_VER)`, which clang-cl defines on every arch. `001-quantization-msvc-guard.patch` had narrowed only
  the guard in `bankers_round`, while the inline fallback that ran in every build until CON85 rewrote every
  `#if defined(_MSC_VER)` in the file. So the patch was never complete, and the fallback hid it.
- **Fix:** 001 narrows the include guard too, regenerated with `git diff` against the 5.4.0 tarball. Its result now
  equals the fallback's except for the comment block. GNU patch and `git apply` take all four forward and reverse, and
  the patch gate passes them. 002 to 004 already matched their fallbacks.

## 2026-10-10 — the riscv64 torch twin compiles against the target 3.14t, and a failed proof is never silent (CON79 1b)

- **Root cause.** The twin pass appended its Python overrides to the GIL pass's `CMAKE_ARGS`, which kept
  `-DPYTHON_INCLUDE_DIR=/opt/python-cross/riscv64/usr/local/include/python3.14`. `torch/CMakeLists.txt` puts that dir
  first on `torch_python`'s include path, so the "twin" recompiled nothing. Its `libtorch_python.so` and `_C` were
  byte-identical to the GIL wheel's (sha256 `b3978f91…`). That library imports `_Py_Dealloc` and no free-threaded
  refcount symbol. Under qemu-riscv64 the target 3.14t segfaulted in `dlopen`, in its initializers, and printed nothing.
- **The fix.** `_torch_build_free_threaded_wheel` builds its arguments afresh through `_torch_cmake_args`, now shared
  with the GIL pass. `append_common_cross_cmake_args` takes the target from `CROSS_PYTHON_*` when set. The twin adds
  `-U _Python* -U Python_NumPy* -U Python3_NumPy*`. The pass takes 233 s warm instead of 70 s, and its
  `libtorch_python.so` imports `_Py_DecRefShared`, `_Py_MergeZeroLocalRefcount` and `PyUnstable_Module_SetGIL`.
- **The proof could not prove any torch.** `torch._C`'s init imports `torch`, whose body needs `typing_extensions`, which
  a `--no-deps` venv lacks. PyPI's amd64 cp314t torch failed the same way. With `typing_extensions` present, the body
  re-imported `torch._C` inside its own init (`SystemError: bad call flags`). `free-threaded-wheel.py` now imports a
  module's enclosing package first. When that fails, it registers the package unrun, as an import in progress leaves
  it. numpy, av, apache-tvm-ffi, onnxruntime, pyyaml and markupsafe from PyPI give the same verdicts as before.
- **Never an empty reason.** The helper enables `faulthandler` and writes the module it is loading to `FT_PROVE_TRACE`.
  `_ft_prove_verdict` adds the exit status or signal. The unfixed twin now reads `… (killed by SIGSEGV, exit status
  139; it died loading torch._C) (on riscv64 under qemu-riscv64)` after the stack.
- **Proved.** A full riscv64 `build_torch_wheel` in `:cross-sdk-riscv64` stored the twin: `1 compiled module(s) of torch
  loaded on free-threaded 3.14.8; the GIL stayed disabled (on riscv64 under qemu-riscv64)`. `import torch` there runs
  with the GIL off. `FT_TORCH_TWIN=1` again in `versions.env` and both `Dockerfile.media` ARGs.
- Tests, red before and green after: the twin's arguments carry no GIL path; a crash names the signal and the module;
  `FT_PROVE_TRACE`; the enclosing-package import and its fallback.

## 2026-10-10 — FT_TORCH_TWIN off until the riscv64 torch twin's qemu proof works (CON79 1b)

- Run 20261009-233208 proved every arm64 and riscv64 cross twin but torch: riscv64's cp314t torch built in 70 s in the warm
  tree, and its qemu-riscv64 proof returned non-zero with no output. `build_torch_wheel` then returned 1, which drops the
  whole riscv64 torch cross wheel to the native torch stage, and the store would expect a twin that never landed.
- `FT_TORCH_TWIN=0` in `versions.env` and both `Dockerfile.media` ARGs; the store records `skip torch FT_TORCH_TWIN=0`.
  BACKLOG CON79 1b keeps the root cause open.

## 2026-10-10 — a cross stage's store defers a twin that only lacks target libraries to the target image (CON79 1b)

- **Run 20261009-224520** proved all four arm64 twins at build time (tvm-ffi, ORT, PyAV with 50 modules, IREE runtime),
  then the final media RUN's store re-proof failed PyAV: `cannot load av._core: libgme.so.0: cannot open shared object
  file`. A cross media stage installs host packages only (`:<target>` installs conflict there), so FFmpeg's target codec
  libs are absent; the twin's earlier proof ran in the `pyav` stage, which has them.
- **Fix** (`free-threaded-store.sh`, `_ft_store_prove`): in a cross build, a re-proof whose every `ERROR:` is a missing
  shared object is logged as deferred, naming the libraries; the runtime image smoke's FT-STORE proves the twin on the
  target, where the closure is installed. A GIL re-enable, a bad symbol or a wrong arch still fails; native builds are
  unchanged. `test-free-threaded-store.sh` 86 -> 90, two failing without the fix.


## 2026-10-10 — the IREE cross twin's reconfigure moves both FindPython spellings (CON79 1b)

- **Run 20261009-215702** proved arm64's tvm-ffi and ORT twins (the libstdc++ fix held:
  `onnxruntime_webgpu-…-cp314t-linux_aarch64.whl: 1 compiled module(s) … the GIL stayed disabled (on arm64 under
  qemu-aarch64)`), then IREE's twin reconfigure failed: `Could NOT find Python (missing: Development.Module
  Development.SABIModule NumPy)` at IREE's `CMakeLists.txt:780`. The GIL cross configure's toolchain file caches
  `Python_INCLUDE_DIR`/`Python_LIBRARY` at the target GIL headers; the twin moved only the `Python3_*` spellings, so
  `find_package(Python)` met GIL headers beside a 3.14t interpreter.
- **Fix** (`_iree_free_threaded_rebuild`): it also passes `Python_INCLUDE_DIR`/`Python_LIBRARY` and drops the cached
  FindPython results (`-U _Python* -U Python_NumPy* -U Python3_NumPy*`). Reproduced in `cross-sdk-arm64` with a minimal
  project configured the GIL way and reconfigured both ways: the old arguments fail with that message, the new ones find
  `/opt/python-cross-ft/arm64/.../include/python3.14t`. `test-iree-wheelhouse-stages.sh` 76 -> 80, three failing without
  the fix.

## 2026-10-09 — the host 3.14t helpers drop a GIL cross build's target sysconfig (CON79 1b)

- **The next cross run** (20261009-211609) proved arm64's tvm-ffi twin, then stopped at IREE: `/opt/python-freethreaded/
  bin/python3.14t is not a --disable-gil build`. `build-app-wheelhouse.sh` evals the target GIL Python's sysconfig export
  (`_PYTHON_SYSCONFIGDATA_NAME`, `PYTHONPATH`) for its IREE cross wheels and leaves it set; `ft_python_resolve`, the GIL
  version lookups and `uv venv`/`uv pip install` then ran the host 3.14t against the target GIL sysconfig, which `-I` does
  not drop. The riscv64 torch twin would have met it the same way.
- **Fix** (`free-threaded-wheels.sh`, `_ft_host`): those host steps run without `_PYTHON_SYSCONFIGDATA_NAME`,
  `_PYTHON_HOST_PLATFORM` and `PYTHONPATH`; the twin builds keep setting the target 3.14t's own through `ft_target_env`.
  `test-free-threaded-wheels.sh` 187 -> 188, failing without the fix.

## 2026-10-09 — the cross cp314t proof loads the twin against the cross GCC's own libstdc++ (CON79 1b)

- **The first chain with cross twins** (run 20261009-202203) stopped at arm64's ORT step:
  `onnxruntime_webgpu-1.30.0-cp314-cp314t-linux_aarch64.whl is not proved: ... /lib/aarch64-linux-gnu/libstdc++.so.6:
  version GLIBCXX_3.4.36 not found`. The twin is built by the cross GCC 16, whose target libstdc++ carries 3.4.36; the
  qemu proof's `LD_LIBRARY_PATH` named only the 3.14t prefix and the sysroot, whose distro libstdc++ is older. The shipped
  image puts GCC 16's runtime on the loader path, so only the build-time proof was wrong.
- **Fix** (`free-threaded-wheels.sh`, `_ft_target_cxx_runtime_dir`): the proof asks `<triplet>-g++ -print-file-name=
  libstdc++.so.6` and puts that directory right after the 3.14t prefix. In the sdk image it resolves to
  `/opt/gcc-16.2.0/aarch64-linux-gnu/lib64` (AArch64, has GLIBCXX_3.4.36) and `/opt/gcc-16.2.0/riscv64-linux-gnu/lib`.
  `test-free-threaded-wheels.sh` 186 -> 187, failing without the fix.

## 2026-10-09 — the riscv64 wheel smoke warns, not fails, on a consumer pin older than CON83

- `python-ci-linux.yml` resolves at `@develop`, so eda97a90's pin check ("missing ci-wheel-smoke.sh") would have turned
  OrchestrANT's riscv64 row red on its next run, before its own hub gitlink could move. The check now writes
  `present=false` and a `::warning`, and the smoke step runs only when `present == 'true'`. `test-wheel-smoke.sh`
  asserts the gated step.

## 2026-10-09 — the riscv64 Python lane: a uv cache seed, the cross wheel installed, shellcheck and hadolint (CON83)

In source; the chain must prove it in the image. OrchestrANT's riscv64 lane spent 108 min of its 6 h job building
numpy, matplotlib, contourpy, pillow, line-profiler, psutil and pyyaml under QEMU, never installed the riscv64 wheel it
cross-builds, and graded its coding bench without shellcheck or hadolint.

- **A uv cache seed, not a wheel store** (`06-packaging/uv-cache-seed.sh`, `PYTHON_UV_CACHE_SEED=/opt/uv-cache-seed`).
  A locked `uv sync` installs what the lock names by URL and hash, so a `--find-links` wheel is never used; uv finds a
  built sdist in its cache by that same source. The torch stage fetches the app at `APP_REF`, syncs `--locked --dev
  --extra test` without the project through the `uv-seed-<arch>` cache mount, and keeps a `uv cache prune --ci` copy
  holding only the versions the sync installed. riscv64 only; the other arches get a `seeded no` record.
- **Proved at build:** a fresh copy syncs the same lock into a fresh venv and must build nothing (no `Built` line, no new
  wheel under `sdists-v*/`). `uv sync --no-build` cannot be the proof: it refused pyyaml with a cached build present
  (`can't be installed because it is marked as --no-build but has no binary distribution`, uv 0.12.23).
- **Measured in `:latest`'s riscv64 child under QEMU** (index `af7252a0…`, 32-core host), OrchestrANT 3bdf80a7: cold
  3172 s, 8 wheels (the 7 above plus the pure-Python sdist antlr4-python3-runtime), seed 21 MB; warm 89 s; the proof
  passed and `verify` read `seeded for riscv64: 8 wheel(s), proved`.
- **Consumers copy it.** `ci_tests.sh` and the new `ci-wheel-smoke.sh` call `uv_cache_seed_restore` (`ci-common.sh`),
  which copies a seed of the running arch into `uv cache dir`. Probe, as uid 1001 in the riscv64 image: a lock with
  pyyaml and psutil synced with no build from the seed; without it, `Building psutil`, `Building pyyaml`.
- **The cross wheel is installed where it runs.** `python-ci-linux.yml`'s riscv64 row with `package-emulated` runs
  `ci-wheel-smoke.sh` in the riscv64 image after packaging: the one `cp314` riscv64 wheel from `dist/`, over the lock's
  core deps, `import <package>` outside the checkout and every compiled module loaded (`wheel-smoke.py`). A host step
  fails the row first when the consumer's hub pin lacks the script. Probe in the riscv64 image: a C-extension wheel
  passed (`import smokeapp and 1 compiled module(s) of smokeapp load on riscv64`), and the same wheel with an x86_64
  `.so` failed it.
- **shellcheck and hadolint in the image, every arch** (the published amd64 child had neither on `PATH` either; the same install ran there green) (`install-lint-tools.sh`, the `tool-pins.env` pins, SHA-verified,
  each binary run on input it must flag). shellcheck has a riscv64 release (`SHELLCHECK_LINUX_RISCV64_SHA256`, also
  `lint-shell.sh`'s riscv64 arm). hadolint has none: `Dockerfile.torch`'s `hadolint-build` stage builds the release
  tag's source (`HADOLINT_SOURCE_SHA256`) with Ubuntu's GHC 9.10.3 at `HADOLINT_HACKAGE_INDEX_STATE`, and caches the
  binary by those pins. The Hackage release alone does not resolve (`time` against language-docker 16); the tag's
  `cabal.project` carries upstream's `allow-newer: time`. Measured in `ubuntu:26.04` riscv64
  under QEMU: apt 469 s, `cabal update` 138 s, the build 18221 s (5.1 h, ~105 packages), and the binary reports
  `Haskell Dockerfile Linter 2.15.1` and flags DL3008/DL3015. It needs libgmp, libffi and libnuma, which `:latest`'s
  riscv64 child has: `install-lint-tools.sh` installed it there beside the SHA-verified riscv64 shellcheck and both
  passed their checks.
- **Gates:** the `lint-tools` and `uv-cache-seed` contract rows; `test-uv-cache-seed.sh`, `test-wheel-smoke.sh` and
  `test-lint-tools.sh`, 11 mutations (all bite). `bump_versions.py` refreshes the new SHA pins with their versions.
- **Left for the chain:** see BACKLOG CON83.

## 2026-10-09 — the CPU ORT build no longer takes ROCm 10.1's flatbuffers 25 (CON78)

The rocm chain `20261009-131840` stopped in the media stage's ORT **CPU** step:
`ort.fbs.h:11: static assertion failed: Non-compatible flatbuffers version included`, `(25 == 23)`, in
`flatbuffers_utils.cc` and `lora/adapter_format_utils.h`.

- **Cause.** The gpu stage's only flatbuffers is `/opt/rocm/core-10.1/include/flatbuffers` (25.x), from
  `amdrocm-dnn-dev10.1` (hipDNN). In 10.1 `/opt/rocm/lib` is the merged `core-10.1/lib`, so its CMake config
  sits at `/opt/rocm/lib/cmake/flatbuffers`. `/opt/rocm/bin` is on `PATH`, and CMake searches each `PATH`
  entry's parent, so ORT's `FIND_PACKAGE_ARGS` took it (`flatbuffers_DIR=/opt/rocm/lib/cmake/flatbuffers`,
  and `nlohmann_json_DIR=/opt/rocm/share/cmake/nlohmann_json` beside it). `-I/opt/rocm/include` reached
  `onnxruntime_flatbuffers` with no pinned flatbuffers include at all. Reproduced by configuring the CPU step
  in the run's gpu-stage image (`sha256:fb44a2d5…`).
- **Fix.** `append_onnx_native_base_build_args` passes `CMAKE_DISABLE_FIND_PACKAGE_flatbuffers=TRUE` to
  every native ORT build; the MIGraphX build's own copy of that define goes. The new
  `append_onnx_rocm_isolation_args` gives the CPU build `CMAKE_IGNORE_PREFIX_PATH=${ROCM_HOME:-/opt/rocm}`
  when the root exists, so no ROCm package reaches it. Rerun in the same image: no `flags.make` names
  `/opt/rocm`, nlohmann_json and flatbuffers are fetched, and `cmake --build . --target onnxruntime_flatbuffers`
  builds; so do the whole CPU `onnxruntime` target and, through `--step gpu`, `onnxruntime_providers_migraphx`
  against `/opt/rocm/extras-10`. `test-onnx-build-summary.sh` runs both helpers (red before, green after).
  Docs: `docs/linux-accelerator-images.md` § *Where ROCm 10.1 puts MIGraphX*.

## 2026-10-09 — WEBDAVCLIENT_REF to WebDavClient's develop head

- `4f3f116d` -> `050dfb2c` (23 commits: lock maintenance, the free-threading declaration, a manylinux packaging extra,
  unit tests). `webdav-download.sh` installs the client from the commit's archive: the new archive installs into a 3.14
  venv, and every call `download-webdav-files.py` makes keeps its signature; `webdavclient.py`'s diff is comments only.
  `bump_versions.py --check` had reported it NEWER AVAILABLE since c40dc4bb.

## 2026-10-09 — the cp314t twins on the Linux cross lanes: arm64 cross and riscv64 (CON75 Linux half, CON79 1b)

In source; the chain must prove them. `:latest` of 2026-10-09 ran `FT-STORE` with `cross-built arch:
no twins yet, as recorded` on arm64 and riscv64. Those arches now build the native table's twins, and
the smoke holds them to it.

- **Build** (`03-media/free-threaded-wheels.sh`). `ft_twin_wanted` no longer skips a cross build.
  `ft_target_resolve` reads the target's `3.14t` from `/opt/python-cross-ft/<arch>`: the
  interpreter, headers, `libpython3.14t.so`, the `EXT_SUFFIX` from its `_sysconfigdata_t_*.py`
  (read, not run) and the platform tag. A missing tree fails the twin. `ft_target_env` gives a
  wheel build the target's sysconfig and platform, which the host `3.14t` then reports.
  - PyAV compiles against the target headers with the target suffix.
  - tvm-ffi reruns in the cross pass's build dir.
  - IREE reconfigures its runtime-only tree with the target `3.14t` include dir and library.
  - ORT passes `Python_INCLUDE_DIR` and retags the twin.
  - The riscv64 torch reruns its warm tree (below).
- **Gate.** `ft_soabi_gate` takes the target suffix in a cross build. It now also fails a platform
  tag for another machine, such as a riscv64 module in a `linux_x86_64` wheel.
- **Proof on the target.** `ft_prove_wheel_on_target` unpacks the twin, `.data` included, and runs
  `free-threaded-wheel.py prove` with the target's own `3.14t` under qemu-user. `-L` names the root
  holding the target's loader, and the target tree's `lib` leads `LD_LIBRARY_PATH`.
  `free-threaded-store.sh` proves the repaired store the same way, and the runtime smoke proves it
  again in the target image.
- **Store and smoke.**
  - A cross store is held to the table like a native one, and a cross GIL wheel without a row now
    fails too.
  - The record names each expected family (`want <family>`).
  - `FT-STORE` wants exactly those twins, so PyPI's torch (amd64, arm64) and PyPI's IREE compiler
    (cross arches) get an `OK` line rather than a demand.
- **torch and numpy rows.** The new `twin:<KNOB>` verdict is a twin only while that `versions.env`
  key is 1.
  - `torch` (`Module.cpp`: `PyUnstable_Module_SetGIL(module, Py_MOD_GIL_NOT_USED)`, v2.14.1) and
    `numpy` (`{Py_mod_gil, Py_MOD_GIL_NOT_USED}`, 2.5.3) are `twin:FT_TORCH_TWIN`.
  - `FT_TORCH_TWIN=1` is in `versions.env` and in both `Dockerfile.media` ARGs.
  - The riscv64 torch twin reruns the persistent scikit-build tree with the target `3.14t` on the
    command line. Only `torch_python`/`_C` see Python, so an estimated 10-20 min on the 1121 s GIL
    torch build. That is not the doubling that would have put it behind an off knob.
  - No chain build ships numpy, so nothing expects its twin.
  - Windows reads a knob row as no twin, and its table test accepts the form.
- **Proved without a chain**, in the published riscv64 `:latest` (sha256:af7252a0), under QEMU from
  an amd64 build container with the hub's library:
  - A minimal C module: `ftprobe-1.0-cp314-cp314t-linux_riscv64.whl: 1 compiled module(s) of
    ftprobe loaded on free-threaded 3.14.8; the GIL stayed disabled (on riscv64 under
    qemu-riscv64)`. Its control without `Py_mod_gil` was refused: `the GIL was re-enabled, first
    by gilprobe._m`.
  - PyAV 19.0.1, cross-built in 47 s against the image's riscv64 FFmpeg, gated
    `.cpython-314t-riscv64-linux-gnu.so`. `FT-STORE`'s probe and verdict in the riscv64 image gave
    `OK av-19.0.1-cp314-cp314t-linux_riscv64.whl: 50 compiled module(s) of av loaded on
    free-threaded 3.14.8; the GIL stayed disabled`.
- **Tests.** `test-free-threaded-wheels.sh` (186 assertions) and `test-free-threaded-store.sh` (86)
  fail 34 and 15 assertions on the old library. There are seven new or rewritten mutations: the
  target resolve, the target-suffix gate, the platform machine, the proof on the target, the knob,
  the record's `want` lines and the unclassified cross wheel. `FT_TORCH_TWIN` is in
  `bump_versions.py`'s non-version filter.

## 2026-10-09 — CON84 item 3: jotrockenmitlocken on sqlite3 3.7.0; ANThology has no lock to maintain

- **jotrockenmitlocken** 93083c3: `sqlite3 ^3.7.0`, lock 3.6.0 -> 3.7.0 (nothing else moved), and `web/sqlite3.wasm`
  replaced (it was still 3.3.1) by the 3.7.0 asset, sha256 `fbcd2e82…` = `SQLITE3_WASM_SHA256`. Dart gate in `:latest`:
  122 tests; CI runs 37933329919 (web build + deploy) and 37933328272 (CodeQL) green.
- **ANThology** is a library: `pubspec.lock` is gitignored, and Renovate reported nothing behind, so there is no commit.
  A fresh `flutter pub upgrade` resolves sqlite3 3.7.0 and go_router 18.0.2 within its constraints; its gate passes (42
  tests).

## 2026-10-09 — clone-into-short-path proved on a pull_request merge ref in CI (CON84 item 2)

- **Why the selftest never hit it:** `actions-selftest.yml` had the `pull_request` trigger, but the hub had never had a
  PR, so every run was a `push` or `schedule`, where the SHA is already in the clone. The action also failed for a ref
  NAME such as `refs/pull/<n>/merge`: the fetch fills only `FETCH_HEAD`, so the checkout of the name found nothing.
- **Fix** (05ea8a26): the action checks out `FETCH_HEAD` after fetching a ref name and reports a `fetched` output; the
  selftest asserts `fetched` per event and, on a PR, clones `refs/pull/<n>/merge` by name and checks it is a two-parent
  merge whose second parent is the PR head.
- **Proved:** draft PR #3 (closed unmerged, branch deleted), run 37931553972: `refs/pull/3/merge is not in the clone;
  fetching it from origin`, `Checked out refs/pull/3/merge at 6d90b8fe… (fetched=true)`, `merge ref checked out at
  6d90b8fe… (base 05ea8a26…, PR head b4f86936…)`, every job green.

## 2026-10-09 — `bump_versions.py --audit-unclassified`: all 441 pin-file keys classified, 62 were not

- **What failed:** `--check`'s self-audit listed 62 keys in no class. It only printed them, so nothing went red.
  `--audit-unclassified` now runs the same check offline and exits 1, and `test-bump-versions.sh` runs it on
  the real pin files. Before the fix it named all 62 keys (rc 1). A key added with no class still turns it red.
- **13 derived:** a spec writes these as extras of an owner key, and `derived_keys()` reads them from that spec's
  own table:
  - ten `CUDA_WINDOWS_ARM64_*_VERSION` from `spec_cuda`'s redist manifest;
  - `DEEPSTREAM_{CIVETWEB,PROMETHEUS_CPP,OPENTELEMETRY_CPP}_VERSION` and their commits. `deepstream_pins` now reads
    these from upstream's `install_opensource_deps.sh` at the DeepStream tag.
- **3 REPORT specs:**
  - `X264_MESON_BRANCH`: the `x264.wrap` revision at `GSTREAMER_VERSION`. A bump re-pins `X264_MESON_COMMIT` to the
    head of that branch.
  - `PYTORCH_ROCM_INDEX`: the newest `rocmX.Y` line on download.pytorch.org with a cp314 x86_64 torch at
    `PYTORCH_VERSION`.
  - `WEBDAVCLIENT_REF`: the head of WebDavClient's default branch.
- **42 wheel URLs** are in the new `WHEEL_URL_GROUPS`: 31 `PYTEST_WINDOWS_ARM64_*` and 11 `TORCH_WINDOWS_ARM64_*`.
  Each group gives one reason. A `*_URL` qualifies only with its `*_SHA256` beside it.
- **2 MANUAL:** `DEEPSTREAM_TENSORRT_{CUDA,REPO}`, the CUDA line and apt repo that NVIDIA builds TensorRT 10 for.
- **2 non-version:** `ROCM_WINDOWS_GFX_FAMILY` is a GPU target set, like `CUDA_ARCHITECTURES`. `APP_REF` is a
  tracked branch.
- **Verified against upstream:** all 13 derived values and the x264 commit match their sources at the pinned
  versions. All 42 wheel SHAs match PyPI's or download.pytorch.org's published digest. The full `--check` had 0
  lookup failures. One finding: WebDavClient's default branch is at `050dfb2c`, ahead of the pinned `4f3f116d`. It is
  reported as NEWER AVAILABLE and was not bumped. No pinned value changed.

## 2026-10-09 — CON79: the Linux ORT twin proved in the published `:latest` amd64

- **Image:** `:latest` index sha256:af7252a0 (hub 655a2c4e). `/opt/wheels-cp314t` holds
  `onnxruntime_dnnl-1.30.0-cp314-cp314t`, and FT-STORE passed it plus `PYTHON_WHEELS_CP314T` in chain run 20261009-022859.
- **ORT census:** `check-ort-provenance.sh --image` passes in a fresh container. It reads the twin's four `.so`
  members as `BIN` rows rooted at `/opt/onnxruntime` and matches them to `ort-provenance-cp314t.sha256`.
- **Reconcile:** a `python3.14t` venv got PyPI onnxruntime 1.31.0, and `uv_reconcile_chain_ort` (the image's
  `python_uv.sh`) replaced it with the twin. The venv census passed. `import onnxruntime` kept the GIL off, and the
  loaded `onnxruntime_pybind11_state.so` and `libonnxruntime_providers_shared.so` match the manifest. Eight threads
  ran one `InferenceSession` with the GIL off.
- **Not a defect:** the twin's `libonnxruntime.so.1.30.0` differs from `/usr/local/lib/onnxruntime-cpu/lib`'s, and so
  does the GIL wheel's. The wheels' own manifests are the reference. The pybind module links ORT statically.

## 2026-10-09 — CON82: `bump_versions.py --audit-sha-pairs` passes; 49 SHA pins gained refresh specs

- **What failed:** 93 `*_SHA256` keys had no refresh spec, hold or exemption, so Renovate or a hand bump could move
  their version while the SHA stayed put. `SHELLCHECK_LINUX_AARCH64_SHA256` was the plain bug: `spec_shellcheck`
  refreshed the other two shellcheck assets but not this one.
- **49 specced**, each from the URL its consumer script downloads:
  - SAFE tier: cargo-audit/deny/tarpaulin, wasm-pack, gitleaks, mold, Renovate's Node (same major) and lavapipe.
  - REPORT tier: flutter_rust_bridge, sqlite3.wasm, x265, DeepStream and its TensorRT debs, HailoRT, TAPPAS,
    libzmq, cppzmq and the Windows ROCm tarball.
  - Slaved derivations: dav1d from GStreamer's `dav1d.wrap` and HailoRT's protobuf from its `protobuf.cmake`.
  - Extras: `spec_cuda` refreshes the ten Windows-arm64 CUDA redists from the same manifest, and `spec_cudnn`
    refreshes the arm64 cuDNN zip.
- **44 not specced:** 42 wheel SHAs sit beside the `*_URL` that is their version. No tool moves that URL, so the
  audit accepts such a pair unless the URL is Renovate-annotated. Two more were added to the new `SHA_PAIR_EXEMPT`
  with reasons: `QNN_SDK_LINUX_ZIP_SHA256` (login-gated) and `LLVM_WINDOWS_AARCH64_RT_SHA256` (slaved to MANUAL
  `LLVM_WINDOWS_VERSION`).
- **The audit is stricter:** only a quoted key counts as specced, so a comment naming a key no longer covers it.
- **Verified:** every new spec's pins were recomputed at the current versions and compared with the pin files. All
  64 values matched (the refactored `NODE_*` pair included). 24 were hashed from fresh downloads, the rest read from
  sums files, NVIDIA's manifests, the CUDA apt index, GitHub's asset digests and GStreamer's wrap. The ROCm tarball (~2.2 GB) was only probed. `--check` finished with
  0 lookup failures.
- **Two lookup fixes:** the GitHub token now goes only to GitHub hosts, because Bitbucket answers a foreign bearer
  with 400. `artifact_exists` sends a one-byte GET instead of HEAD, because a token-authenticated GitHub release
  redirect answers HEAD with 401. That had made `spec_llama_cpp_hip` fail under `GITHUB_TOKEN`.
- **Tests:** `test-bump-versions.sh` now runs the audit on the real pin files and checks that one added key fails
  it. It also covers URL pairing, comment-only keys and the new parsers (70 -> 90 assertions). 13 of them fail
  against the old script.

## 2026-10-09 — CON76: the free-threaded proof runs for real in the hub suite

- **`test-python-free-threaded-wheel.sh` runs `prove` on a real 3.14t** (CON76). It compiles two C extensions
  against `/opt/python-freethreaded/bin/python3.14t` (or `FT_PYTHON`) into a fresh venv, each installed as a
  distribution: `ftfix_free` declares `Py_mod_gil = Py_MOD_GIL_NOT_USED`, `ftfix_gil` does not. The first must prove
  (`1 compiled module(s) of ftfix_free loaded on free-threaded 3.14.8; the GIL stayed disabled`, rc 0), the second
  must fail (`ERROR: the GIL was re-enabled, first by ftfix_gil; …`, rc 1). The stubbed cases are unchanged.
- **Where:** in the published `:latest` (hub 655a2c4e) on amd64, and on arm64 and riscv64 under QEMU: 58 -> 66
  assertions on all three. A host without a free-threaded interpreter, CI's included, prints a `SKIP [<case>]`
  line and stays at 58.
- **Mutation-checked:** ignoring the GIL verdict, a GIL-warning regex that no longer matches, and a `load_all` that
  never creates the module each turned the suite red in the image (2, 1 and 2 failures); every stubbed case passed
  all three.

## 2026-10-09 — `:latest` published from hub 655a2c4e; CON56/58/65 closed, CON66/71/72/79/82 Linux halves proven

- **Published** `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`, index
  `sha256:af7252a01f7e5099e54265337fea42c94cc6cf79a0dea1ab9fde0aaa2853af58`: amd64 `sha256:ba3115f1…`, arm64
  `sha256:15a905c6…`, riscv64 `sha256:81db10eb…`, each labelled revision 655a2c4e. Runtime stage from chain run
  20261009-022859-db31d92c; earlier stages from runs 20261007-221241, 20261007-233233, 20261008-103605 and
  20261008-113607. All three wrapper smokes passed, the runtime-image smoke had 0 failures on every arch.
- **Closed:** CON56 (`rg` 15.1.0), CON58 (`aarch64-linux-android` installed) and CON65 (`cargo-qa-tools` row on
  amd64 and arm64), all three arches where they apply. **Linux halves proven** (BACKLOG): CON66 (python3.14t 3.14.8,
  GIL off), CON71 (26 LLVM tools at 23.1.3), CON72 (the 2026-10-07 pins), CON79 (FT-STORE on amd64 with the av,
  IREE and tvm-ffi twins) and CON82 (Vulkan 1.4.363.0, Chrome for Testing 155, Node 26.11.0, the 26.08 flatpak
  refs, vvdec 3.2.1).
- **The chain needed** c0fb66be, df0736cd, 815cfebe, 537b60f2, 6c11da0c, 02801990, d5b6d9db, f3b9ebb4 and 655a2c4e,
  each with its own entry above or below.

## 2026-10-09 — the media fan-in binds view stages, not the branch images

- **The rocm chain stopped at the site-packages merge three times on 2026-10-09.** robocopy reported
  `ERROR 3 … cannot find the path specified` for every entry of the bind-mounted `media-tvm` tree, after a first
  attempt failed with `hcsshim::ActivateLayer … (0x20)`. buildctl probes showed the RUN listed the image's 49 entries
  but could open none. The same files open in a RUN on the image and through a stage with one empty `RUN` layer on
  top. A `-NoCacheStage media-tvm` rebuild and a restart of containerd and buildkitd did not change it. The same merge
  passed three times on 2026-10-07/08. The cause is not established (`docs/failure-modes.md`).
- **Fix:** `Dockerfile.media-merge-builder` adds `media-core-view` and `media-tvm-view` (`RUN cmd /c exit 0` over each
  branch image), and the merge `RUN` binds those. The `COPY --from=` steps still read the images. The next rocm solve
  merged both trees: 31 distributions, every RECORD entry spelled as on disk.

## 2026-10-09 — riscv64 advertises the cmake it runs: the venv's pip wheel

- **The riscv64 runtime-image smoke failed one row** (chain run 20261008-200606; amd64 and arm64 clean): `the riscv64
  image ADVERTISES CMAKE_VERSION=4.4.2 but actually has 4.4.4`. In that image `cmake` on PATH is
  `/opt/python/.venv/bin/cmake`, the runtime venv's pip wheel at `PY_CMAKE_VERSION` (4.4.4 since the 2026-10-07 Renovate
  bump); apt's `/usr/bin/cmake` behind it is 4.2.3. `CMAKE_VERSION_RISCV64=4.4.2` was right only while the wheel was 4.4.2,
  and its comment credited the Ubuntu archive.
- **Fix** (`01-core/versions.env`): `CMAKE_VERSION_RISCV64=4.4.4`, the comment names the wheel, and
  `test-version-forwarding.sh` now asserts the riscv64 forward equals `PY_CMAKE_VERSION`, so a wheel bump alone fails it
  (proved by moving the wheel pin to 4.4.5). Only riscv64's forwarded value changes; amd64 and arm64 keep their cache.


## 2026-10-08 — HailoRT's `.patch` files apply again, and the patch gate runs GNU patch too (CON85)

- **The four `windows/scripts/patches/hailo/*.patch` had never applied in a build.** HailoRT comes from a
  tarball, which is no git repo, so `Invoke-SourcePatch` applies its patches with GNU patch (Git for Windows'
  `usr\bin\patch.exe` in the image). All four carried a hand-written `index 0000000..0000000` line, which GNU
  patch reads as a new file (`which already exists!`); 003 also had 6 lines of leading context against 1
  trailing, which GNU patch anchors at end of file. Every build since at least 2026-10-04 logged four
  `ERROR: … does not apply cleanly` and went green on the inline fallbacks. `git apply` forgives both, and
  that is all `Test-PatchesApplyClean.ps1` ran.
- **Fix:** the four regenerated with `git diff` against the SHA-pinned 5.4.0 tarball. The changes are the
  same; the index lines are real and the context is git's 3/3. GNU patch 2.7.6 and `git apply` both take
  them, forward and reverse, on a fresh non-git extract.
- **Gate:** `Test-PatchesApplyClean.ps1` now also dry-runs GNU patch (`--force`, never prompting) on each
  clone, cloned with `core.autocrlf=false` so the tree is LF like the tarball. It takes Git for Windows'
  GNU patch, not the first `patch.exe` on `PATH`: Strawberry Perl's patch 2.5.9, first on the dev host's
  `PATH`, asserts on every patch. The old four FAIL there and the new four pass; all 20 patches pass both
  checks at their pinned refs. `windows/scripts/patches/README.md` says how to write a patch GNU patch takes.


## 2026-10-08 — the arm64/riscv64 images drop the Vulkan SDK's builder-arch vkprofiles (CON82)

- **The runtime-image smoke failed one row on arm64** (chain run 20261008-141457; amd64 0 failures):
  `tree-arch: /opt/vulkan ships 1 X86-64 object(s) in the arm64 image, e.g. /opt/vulkan/1.4.363.0/aarch64/bin/vkprofiles`.
  Vulkan-Profiles at `vulkan-sdk-1.4.363.0` builds its new `vkprofiles` unconditionally with PyInstaller
  (`add_pyinstaller_target`, no option), which bundles the BUILDER's Python, so a cross build installs an x86-64
  executable into the target prefix. Earlier SDKs had no such tool, so no foreign-arch image loses one it had.
- **Fix** (`06-packaging/prune-vulkan-host-sdk.sh`, `_prune_host_built_tools`): before the `/opt/vulkan` COPY, an ELF in a
  foreign target prefix's `bin/` whose machine is not the target's is removed and logged. Libraries are not touched, so a
  wrong-arch library still fails the smoke. Run against the real `cross-android-arm64` artifact: it removes exactly
  `aarch64/bin/vkprofiles`, and no foreign ELF is left among the prefix's 52 tools. `test-vulkan-host-sdk-prune.sh`
  36 -> 41, two failing without the fix.

## 2026-10-08 — OpenCV's libwebpdemux2 survives the package stage's GTK 4 drop

- **The wrapper smoke's media check failed on gst's `opencv` plugin** (chain run 20261008-132402, amd64), with the
  compiler smoke now clean. A full `ldd` sweep of the package image found `libwebpdemux.so.2` missing for 13 OpenCV
  libraries and the plugin: it arrived only as a GTK 4 dependency, and `drop_redundant_distro_gtk4`'s purge left it to
  the autoremove.
- **Fix**: the native list in `03-media/runtime/install-deps.sh`, which the package stage runs as `final/install-deps.sh`,
  now names `libwebpdemux2` beside `libavif16` and `libhdf5-310`, so it is installed as manual. Proved in the package
  image: the autoremove keeps it, `gst-inspect-1.0 opencv` loads, and the whole `wrapper-smoke` RUN
  (`validate-compilers.sh smoke`, `smoke-media.sh`, `smoke-torch-venv.sh`, `smoke-cross-all-arches.sh amd64`) passes.

## 2026-10-08 — the Vulkan SDK's DXC llvm-tblgen no longer shadows the pinned one (CON71)

- **The runtime stage's compiler smoke failed one row** (chain run 20261008-113607, amd64):
  `llvm-tblgen MISSING is not LLVM_RELEASE 23.1.3`, while the other 25 tools passed. The pinned `llvm-tblgen` was built,
  installed, wired into `/usr/bin` and `/usr/local/bin`, and runs. But the image's `PATH` starts with
  `/opt/vulkan/active/bin`, and the Vulkan SDK ships DXC's `llvm-tblgen` (its LLVM 3.7 fork), which answers `--version`
  with `Unknown command line argument`. A consumer typing `llvm-tblgen` got that fork. A sweep of every PATH dir ahead of
  `/usr/local/bin` in the package image found no other clash.
- **Fix** (`06-packaging/package-image-wiring.sh`, `unshadow_pinned_llvm_tools`, called after `wire_pinned_llvm_tools`): a
  Vulkan SDK executable whose name the pinned LLVM also has moves to `vulkan-sdk-<name>`. Proved in the package image:
  `llvm-tblgen` then resolves to `/usr/local/bin` and reports 23.1.3, and the compiler smoke passes.
  `test-package-image-wiring.sh` 46 -> 53.

## 2026-10-08 — Android LiteRT takes Samsung's LiteCore headers from a pinned, hashed download

- **The android stage failed in LiteRT v2.2.0's Samsung plugin** (chain run 20261008-103605): `ai_litecore_manager.h:20:
  fatal error: 'graph_wrapper_api.h' file not found`. LiteRT's default `LITECORE_HEADERS_URL`
  (`…/download-file/1.1.0/ai-litecore-ubuntu2404-v1.1.0.tar.gz`) now answers HTTP 404 with a JSON body, and its
  `file(DOWNLOAD)` checks neither status nor hash, so the Samsung NPU plugin was configured against an empty tree. The
  pin did not move (v2.2.0 since 2026-08-18); the vendor's URL did. Upstream main already drops the `1.1.0/` segment.
- **Fix** (`litert/android/build-android.sh`): the script fetches that new URL itself, checks sha256
  `7d79a04d…a07b2` (21.4 MB, measured 2026-10-08), and hands `exynos-ai-litecore-v1.1.0/include` to
  `LITECORE_HEADERS_DIR`, so upstream downloads nothing. Samsung dispatch keeps building, as it did before the 404.

## 2026-10-08 — the media smoke's FFmpeg registry checks survive SIGPIPE; OpenCV's avif/hdf5 in the media stage

- **Third failure of the media stage, now in its smoke** (chain run 20261008-100008): with FFmpeg's runtime manifest
  installed (previous entry), ffmpeg runs in the media sandbox, so `smoke-media.sh` stopped deferring its FFmpeg and
  GStreamer checks there and failed 8 of them.
- **Seven were false.** `ffmpeg -encoders | grep -q x265` under `pipefail`: grep exits at the match, ffmpeg dies of
  SIGPIPE, and the pipeline reads as "not registered". Measured in the stage's image: `rc=141 PIPESTATUS=141 0`, while
  the captured 222-line list carries libx265, libdav1d, libsvtav1, libvpx, libopus, `drawtext` and `scale_vulkan`.
  FFmpeg 9.0.2's longer lists make the race likely; the package-stage smoke runs the same lines. The registry, buildconf
  and filter lists are now captured once and searched.
- **One was real.** gst's `opencv` plugin did not load: `libavif.so.16 => not found`. A full `ldd` sweep of `/opt/opencv5`,
  `/opt/gstreamer`, `/opt/ffmpeg` and `/usr/local/lib` in that image found two distro libs missing, `libavif16` (12 OpenCV
  libraries and the plugin) and `libhdf5-310` (`opencv_hdf`); the native media stage now installs both, as the package
  stage already does.

## 2026-10-08 — the media stage installs FFmpeg's runtime manifest before the cp314t store proves PyAV (CON79)

- **Second failure of the same run, one RUN later** (chain run 20261008-085555, after the `pyav` fix proved and stored
  the twin): `free-threaded-store.sh` re-proves every twin in the final media RUN, and `av` could not load
  `libopencore-amrwb.so.0`. `emit_runtime_apt_manifest` records FFmpeg's apt runtime libs in
  `/opt/ffmpeg/runtime-apt-packages.txt`, but only the package stage (`setup-torch-venv.sh`) installed them.
- **Fix** (`03-media/runtime/install-deps.sh`): a native build adds the manifest to the final-stage packages. The
  package stage installs the same list, so the shipped image is unchanged; cross builds prove no twin there and keep
  their package set.


## 2026-10-08 — Windows FFmpeg links x265 4.2 again: its .pc gains advapi32

- **The x265 4.1 → 4.2 bump of 2026-10-07 broke `:winamd64`'s FFmpeg configure**: `ERROR: x265 not found using
  pkg-config`. config.log shows the cause: 4.2's `threadpool.cpp` reads the CPU frequency from the registry
  (`RegOpenKeyExA`, `RegQueryValueExA`, `RegCloseKey`), so the static `x265.lib` needs `advapi32.lib`, and the
  `x265.pc` that x265 generates does not list it. `Build-FfmpegCodecs.ps1` now appends `-ladvapi32` to that `Libs:`
  line (`Add-CodecPcSystemLib`, once, whole-name match), which FFmpeg's msvc filter turns into `advapi32.lib`.
  `SourceBuild.FfmpegCodecs.Tests.ps1` covers it.

## 2026-10-08 — the PyAV cp314t proof sees the chain ORT (CON79)

- **The amd64 media stage failed at `PyAV: no proved cp314t twin`** (chain run 20261007-233233): every module of
  `av-19.0.1-cp314-cp314t-linux_x86_64.whl` failed to load with `libonnxruntime.so.1: cannot open shared object file`.
  `libavfilter` needs the chain ORT and carries no RUNPATH; the `ffmpeg` stage bind-mounts ORT for its build RUN only,
  so the `pyav` stage built FROM it has none. The GIL wheel is never loaded there, which is why only the twin's proof
  (CON79, which imports every compiled module) found it.
- **Fix** (`Dockerfile.media`, the `pyav` RUN): the same read-only bind of `onnxruntime-cpu` from the `onnxruntime`
  stage, with its `lib` first on `LD_LIBRARY_PATH`, which is how `media-inputs` and the image load it.

## 2026-10-08 — the cross lldb finds zlib.h (CON71's compiler stage)

- **The arm64 compiler stage failed at `SymbolFileCTF.cpp:42: fatal error: zlib.h: No such file or directory`**
  (chain run 20261007-221241, 3092 s into the LLVM 23.1.3 build). CON71 added lldb to the cross superset; its CTF plugin
  includes `zlib.h` under `LLVM_ENABLE_ZLIB` but links no `ZLIB::ZLIB`, so it never gets `/usr/include`, and the cross
  GCC (`/opt/gcc-16.2.0/bin/aarch64-linux-gnu-g++ --sysroot=/`) does not search it. LLVM's own zlib users get the dir
  from the imported target, which is why only lldb broke, and only off the build arch.
- **Fix** (`02-toolchain/llvm-cross.sh`): `llvm_cross_stage_zlib_headers` copies the sysroot's `zlib.h` and `zconf.h`
  (Multi-Arch: same) into `<build_root>/<triplet>-zlib-include`, and the C/CXX/ASM flag inits add it as `-isystem`. A
  dir holding only those two keeps the host's glibc headers out of the target's search path, which
  `-isystem /usr/include` would not. `test-llvm-cross-stanza.sh` 61 -> 65.

## 2026-10-08 — the lock maintenance report says how far behind each lock is (CON84 1)

- **Each `LOCK FILE MAINTENANCE` row ends with the tool's own dry-run count** (`maint_behind` in
  `renovate-locks.sh`), in report mode only: `uv.lock  uv lock --upgrade  (3 entries would move)`. Counted from
  `cargo update --dry-run`, `uv lock --upgrade --dry-run` and `dart`/`flutter pub upgrade --dry-run`, each output
  measured against a held-back lock (cargo 1.96.0, uv 0.9.18, Dart 3.13.3 in `:latest`), none of which wrote it.
- **Anything else is `behind: unknown -- <why>`, never 0**: npm 9.2.0, poetry 2.5.1 and pdm 2.29.2 have no dry run
  that diffs the lock (measured; npm's said `up to date` over a lock its real run moved), pnpm has none known, and a
  missing tool, a failing dry run or output without the tool's summary line say so too. The lock is hashed before
  and after; one that changed is put back. `--apply` runs no count.
- `test-renovate-lockmaint.sh` 25 -> 45 assertions (M11-M16, verbatim tool outputs replayed by stubs; 15 fail
  without the change), 3 new mutations; docs/dependency-updates.md#how-far-behind-a-maintained-lock-is.

## 2026-10-08 — prune-safe.sh survives a store with no layer records; CON53 closed

- **`_disk_guard_du_json` reads buildctl's `null` as `[]`** (`01-core/disk-guard.sh`). `buildctl du --filter
  type==regular --format '{{json .}}'` prints `null`, not `[]`, when no record matches, and the old empty-only fallback
  passed it on: `prune-safe.sh`'s in-use count died in jq (`Cannot iterate over null`) before it pruned anything, on a
  store that held only cache mounts. `test-disk-guard.sh` 121 -> 123, failing without the fix.
- **CON53 closed.** Measured 2026-10-08 on the dev host with no chain running: 130 `exec.cachemount` records
  (275 GB), every cache id with exactly one record. The 52 GB of surplus records the item listed is gone, so there is
  nothing left for `PRUNE_DUP_CACHEMOUNTS=1` to remove.
