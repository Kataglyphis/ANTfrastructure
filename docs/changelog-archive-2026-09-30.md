<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Changelog archive — 2026-09-22 through 2026-09-30

Entries moved out of the root `CHANGELOG.md` on 2026-10-17 so the live file stays
readable (its own rule: archive past ~700 lines, never delete). Newest-first, running
back to where [`changelog-archive-2026-09-21.md`](changelog-archive-2026-09-21.md) picks up. One mechanical edit, no
rewording: relative links are re-based on this directory.

## 2026-09-30 - GStreamer: a meson inherited without its launcher is reinstalled

- **What went wrong.** The default `:winamd64` merge stopped in `Build-GstreamerFromSource.ps1`
  with `meson.exe not found after pip install`. The FFmpeg stage, rebuilt that day, pip-installs
  meson into the source CPython. The merge copies media-core's `Lib\site-packages` but not its
  `Scripts`, so `pip install meson` answered "Requirement already satisfied" and wrote no
  `meson.exe`. On 2026-09-27 the FFmpeg layer came from cache without meson, and the merge's pip
  installed it fresh.
- **The fix.** When no `meson.exe` is found after the install, the script runs
  `pip install --force-reinstall --no-deps meson`, which writes the launcher again, and then
  looks once more. It still refuses if that fails.
- **Proven with a scratch venv.** With the launcher removed, pip reports "already satisfied" and
  writes nothing. The forced reinstall restores it: `meson.exe --version` prints 1.12.1.


## 2026-09-30 - OpenCV: gapi's fluid SSE4.1 kernels build under clang-cl

- **What went wrong.** The first BuildKit run of the default (CPU + DirectML) `:winamd64` stopped in
  `media-core-built-opencv`:
  `gfluidcore_simd_sse41.hpp(308,35): error: use of undeclared identifier '_mm_setr_epi64x'`, five
  times. opencv_contrib 5.0.0 takes MSVC's `_mm_setr_epi64x` under `#ifdef _MSC_VER`. clang-cl
  defines `_MSC_VER`, and its intrinsic headers have no such function.
- **The fix.** `windows/scripts/patches/opencv_contrib/003-gapi-fluid-clangcl-setr-epi64x.patch`
  takes that branch only for real MSVC (`&& !defined(__clang__)`). clang-cl then uses the portable
  `_mm_setr_epi64` branch. It is the only file in contrib's gapi that names the intrinsic.
  `git apply --check` is clean against the 5.0.0 tag (755e5067).


## 2026-09-30 - Windows base: both OpenSSL installers come from the LAN preseed

- **What went wrong.** A `:winamd64` base build sat 3.6 h in `scoop install main/openssl`,
  then failed. scoop purged its cache and started again. slproweb serves each connection at
  ~9–25 KB/s, and the x64 installer is 251 MB.
- **Measured.** One connection gets 1 MB in 41 s. Eight connections each get their 1 MB inside
  45 s, so the throttle is per connection, not per host.
- **The fix, on the pattern of the Vulkan preseed.**
  - `Build-Buildkit.ps1` reads scoop's `openssl.json`.
  - `Save-ParallelRangeDownload` (`WindowsBuildDriver.Common`) fetches both installers host-side
    in 32 ranges, joins them and checks their SHA256. It then puts them on the WebDAV under
    `preseed/`.
  - `Install-ScoopTools.ps1` drops the x64 installer into scoop's cache under scoop's own name,
    through `Copy-PreseedToScoopCache`, which the Vulkan preseed now uses too. The aarch64 step
    fetches from the preseed first. Both fall back to slproweb, and both hashes are still checked.
- **Measured after.** 251.1 MB in 269 s and 219.6 MB in 234 s, both hash-verified.
  `BuildDriver.RangeDownload.Tests.ps1` holds the range split to exact, gapless coverage; an
  off-by-one overlap fails it.


## 2026-09-30 - Windows base: aarch64 OpenSSL follows scoop's manifest instead of a pin

- **What went wrong.** `Install-ScoopTools.ps1` fetched a literal `Win64ARMOpenSSL-4_0_2.exe`.
  slproweb had replaced it with 4.0.3, so the URL answered 404. The step only warns, so
  that day's `:winamd64` base build went on without `C:\opt\openssl-arm64`. The next `:winarm64`
  GStreamer cross build would have thrown on it. This is the second time: the 4.0.1 → 4.0.2
  bump in `docs/changelog-archive-2026-08-28.md` was the same break.
- **The fix.** The URL and SHA256 come from `architecture.arm64` in
  `buckets\main\bucket\openssl.json`. The x64 `scoop install main/openssl` reads the same
  manifest, so both architectures move together and the hash is still verified. Checked against
  the live bucket: 4.0.3, `Win64ARMOpenSSL-4_0_3.exe`, `afc17720…`.
- **Not proven in a container yet.** It takes effect with the next base build.
  `docs/windows-cross-builds.md` § *aarch64 OpenSSL is a base prerequisite too* records the rule.


## 2026-09-30 - SBOM: the amd64 and arm64 scans get swap

- **What went wrong.** Every SBOM run since at least 2026-08-31 lost amd64 and arm64 with
  "The runner has received a shutdown signal". riscv64, the smallest image, passed.
- **The cause, measured.** syft 1.52 on `:latest` amd64 indexes the image's files into 11 GB
  before any cataloguer runs, then peaks at 24 GB unconstrained. The runner has 16 GB, so the
  kernel killed the runner. Under a 15 GB cap:
  - `GOMEMLIMIT=10GiB` still died;
  - `SYFT_PARALLELISM=4` still died, because the index is live heap;
  - 16 GB of swap finished in 15.5 minutes with the same 4056 packages.
- **The fix.** `sbom.yml` adds a 24 GB swap file on `/mnt` before the scan. The job timeout goes
  from 30 to 60 minutes, because paging doubles the scan time. `docs/sbom.md` § *Generating
  them* records the budget.


## 2026-09-30 - python-ci-linux: a pull request no longer publishes the docs

- **What went wrong.** The *Sync files to domain* step ran on every event. On a Dependabot pull
  request the FTP secrets are empty, so WebDavClient's PR builds failed with `Input required and
  not supplied: server`. A PR opened from the repository itself has the secrets, and its docs
  would have replaced the live site.
- **The fix.** The step also needs `github.event_name == 'push'`, the gate `build-docs.yml`
  already had. A push to a caller's branches publishes as before.


## 2026-09-30 - Windows: the source-built CPython reports win-amd64 in a venv again

- **What went wrong.** `Py_GetVersion()` keeps 80 characters of `COMPILER`. For clang, CPython
  writes `__clang_version__` there, and Visual Studio's clang puts its git URL and hash in it. So
  `64 bit (AMD64)` fell off `sys.version`.
- **The effect.** `sysconfig.get_platform()` read `win32` in every venv of the image's CPython.
  uv, pip and `bdist_wheel` then treated the x64 interpreter as 32-bit. OrchestrANT's Windows lane
  has failed on this since it was created: `onnxruntime-genai-cuda` has no win32 wheel.
- **The fix.** `windows/scripts/patches/cpython/001-short-clang-compiler-id.patch` names clang by
  major.minor.patch (`[Clang 22.1.3] 64 bit (AMD64) …`). `Build-ToolchainAll.ps1` applies it and
  refuses a `sys.version` without `AMD64`. `Test-PatchesApplyClean.ps1` now maps `cpython` to
  `PYTHON_VERSION`.
- **Proven** by rebuilding CPython in the published `:winamd64`, with the later `Include\pyconfig.h`
  copy removed as a fresh build has it:
  - the venv reports `win-amd64`;
  - uv resolves `onnxruntime-genai-cuda` 0.15.2.
- **Takes effect** with the next image build.


## 2026-09-30 - GHCR prune: the keep-set gate counts digests, not tag names

- **What went wrong.** `ghcr-prune-package.sh` refused on 2026-09-27 with "keep-set smaller than tag
  count": 22 tags, 21 kept digests, because two tags named one image during the `:latest-cross`
  rename. The weekly `GHCR · cleanup` run has been red since then.
- **The fix.** The gate now requires every tag's live digest to be readable and in the keep-set.
  An unreadable digest aborts; the old code dropped it silently.
- **Test:** `linux/scripts/tests/test-ghcr-prune-keepset.sh`. With the old gate put back, it fails
  with the 2026-09-27 message.
- **Docs:** [`linux-host-setup.md`](linux-host-setup.md).


## 2026-09-30 - One-line comments, only the why, in every language

- **The rule.** `AGENTS.md` § *Comments: one line, only the why* replaces the two-line ceiling
  and is the owner rule for every repo of the family; the consumer `AGENTS.md` template links it.
  One line, only the why; API docs stay, short; a trap that needs more gets a paragraph in its
  `docs/` page and a one-line pointer; no history, dates or commented-out code.
- **The sweep.** Every tracked source file is held to it (about 880 files, 38.9k lines out, 8.6k
  in). Traps moved to their pages first, among them `build-cache-tiers.md`, `linux-cross-builds.md`,
  `vulkan-foreign-arch-sdk.md`, `windows-build-resources.md` and `slang-shader-compilation.md`.
  Apart from the gate, its tests and the fixes below, code is unchanged: every file was compared
  token for token with its comments stripped. The empty CMake branches in
  `ProjectOptionsCommon.cmake` keep a one-line why.
- **The comment-size gate reads every language.** `verify_comment_size.py` grades shell, Python,
  PowerShell, Dockerfiles, YAML, TOML, CMake and the `//` / `/* */` languages at one line
  (`COMMENT_SIZE_LIMIT`). Heredocs, here-strings and multi-line strings are data; licence headers,
  tool directives and `///` / `//!` / `/** */` API docs are exempt. The 32 blocks it still finds
  (the guard hooks, CMake function docs, help texts, scripts inside strings) are frozen in
  `comment-size.allow` ([`code-quality-tooling.md`](code-quality-tooling.md#comment-size-comment-size)).
- **What leaned on comments.** `test-cuda-cross-sbsa.sh` sliced the script at a comment and now
  slices at `cuda_cross_packages()`. The gate registry credits a mutation by the target naming
  its gate, so `lint-root.sh`, `lint-workflows.sh` and `linux-x64.yml` keep one line naming
  `lint-shell.sh`, `workflow-conventions.allow` and `verify_mutations.py`.
- **Budgets.** `code-dupes.allow`: `Install-ScoopTools.ps1` with itself 16 -> 26 (the notes that
  split its two fetch arms moved to `windows-cross-builds.md`), and `test-prevention-gates.sh` with
  itself at 12 (one case per language). `file-size.allow`: seven shrinks, four stale rows dropped.
- **Cost.** Every edited Dockerfile and baked script re-keys its layer, so the next Linux and
  Windows image builds run cold from the first edited step.


## 2026-09-30 - CON38-CON40, and the code-dupes gate green again

- **CON39: clang-tidy selects the image's GCC.** Clang reads `<triple>-<driver>.cfg` from the
  directory it was reached through, and clang-tidy reaches it as the compile database's
  `/usr/bin/clang++`, where no cfg was: it selected the distro GCC 16 on all three arches.
  `write_clang_gcc_toolchain_cfg` now writes the pair into every directory of `/usr/bin` and
  `/usr/local/bin` that links to the driver; the smoke grades clang-tidy too. Package stage.
- **CON38: atheris finds libFuzzer.** Its `find_libfuzzer.sh` probes only the pre-per-target name
  `lib/linux/libclang_rt.fuzzer_no_main-<arch>.a`. `link_compiler_rt_legacy_names` links the fuzzer,
  asan and ubsan archives there, and the smoke runs atheris' probe. atheris 3.0.0 and upstream build
  from source on 3.14 in the published image with the links recreated. Package stage.
- **CON40: a `3.14` venv after a `3.14t` one is a GIL venv.** uv 0.12 lets a plain `3.14` take a
  cached free-threaded build, and `uv_ensure_python_available` stripped the `t`. `uv_venv_create`
  asks uv for `3.14+gil`, and `python3.14` no longer satisfies `3.14t`
  ([`python-ci.md`](python-ci.md#free-threaded-and-gil-legs-in-one-container)). Lane-time only.
- **code-dupes:** the torch and torchvision builders share one owner for their repeated steps
  (`Save-TorchRocmTree`, `Get-TorchRocmPythonTag`, `Install-TorchRocmBuiltWheel`,
  `Copy-TorchRocmEnv`); the test harness owns the module-import closure two suites spelled
  (`Get-ModuleImportClosure`), and `Torch.Rocm.Tests.ps1` one refusal assertion. The rest are
  recorded with a measured reason, six shrunk budgets written down and two stale rows dropped.
  The builder edit re-keys the Windows rocm `torch-rocm-wheels` stage.


## 2026-09-30 - The arm64 and riscv64 Vulkan loaders carry X11, XCB and Wayland (CON41)

- **Measured on the `:latest` of 2026-09-29.** amd64's LunarG loader lists 26 instance extensions,
  including `VK_KHR_xcb_surface`, `_xlib_` and `_wayland_`. The cross-built arm64 and riscv64 loaders
  list 22 and none of those three, so vkcube under `xvfb-run` with lavapipe aborts there. That is
  what stops BeschleunigerBallett's windowed GPU suites on arm64 (run 36615897603).
- **Cause:** `_vulkan_target_build_loader` passed `BUILD_WSI_{XCB,XLIB,WAYLAND}_SUPPORT=OFF` on
  purpose, from when TVM's compute-only use was the loader's only consumer.
- **Fix (sdk stage, `02-toolchain/vulkan.sh`):** the three options, plus `BUILD_WSI_XLIB_XRANDR_SUPPORT`,
  are `ON`. Upstream makes each one a REQUIRED pkg-config lookup. A new export check
  (`_vulkan_loader_wsi_missing`, via `readelf`) fails the REQUIRED `vulkan-loader` component when
  `vkCreate{Xcb,Xlib,Wayland}SurfaceKHR` is missing. The loader still needs only `libc`.
- **Smoke:** `check_vulkan_loader` also lists the instance extensions (this needs no ICD and no
  display). `_vk_wsi_verdict` then fails any arch, amd64 included, whose loader lacks `VK_KHR_surface`
  or one of the three platform surfaces.
- **Proven without the chain:** the loader was cross-built through the real
  `_vulkan_target_build_loader` for both arches, with Ubuntu's cross GCC. Both builds export all three
  entry points and list 26 extensions. Swapped into the published images, vkcube renders on llvmpipe
  over xcb on arm64 and riscv64. With the target xcb/x11 dev packages missing, the configure fails.
- **Tests:** `test-vulkan-target-decomposition.sh` (the WSI-on argv, and a WSI-less or absent loader is
  fatal) and `test-runtime-image-gates.sh` (the verdict's cases). Seven new mutations, all of which bite.
- **Docs:** [`vulkan-foreign-arch-sdk.md` § The loader carries the window systems](vulkan-foreign-arch-sdk.md#the-loader-carries-the-window-systems).
  The change ships with the next `:latest`. The rebuild starts at the sdk stage.


## 2026-09-30 — Home Assistant configuration pass

* **Grid statistics corruption found**: the bitshake smartmeter emitted
  `-1.4e13 kWh` twice in 24 h; `total_increasing` turned each glitch into a
  multi-trillion-kWh jump in the grid import/export `sum`. New trigger-based
  template sensors `sensor.netzbezug` / `sensor.netzeinspeisung` reject
  non-positive, decreasing or >1000 kWh-jump readings (guard simulated against
  the logged glitch values). The energy dashboard now uses them; the grid
  statistics (hourly and 5-minute, back to 2026-09-02) were recomputed from the
  per-hour meter states, skipping implausible values, and copied onto the new
  sensors — daily import now reads 10–22 kWh instead of ~10¹² kWh. Verified that
  post-restart 5-minute stats continue the repaired sum without a jump. DB
  backup: `~/ha-pre-statsrepair-20260930/`.
* **Backups**: deleted the two pre-password manual archives (Oct 2025, May 2026)
  that held `secrets.yaml` and `.storage` unencrypted; only encrypted automatic
  backups remain.
* **Registry cleanup** (HA stopped, files backed up to
  `~/ha-pre-registrycleanup-20260930/`): removed the 15 orphaned `automation.*`
  entity-registry entries left behind when the automations were dropped, their
  4 `exposed_entities` rows, and the 5 stale `automation.*` repair records
  (already dismissed, non-persistent). The dismissed `sun`
  `deprecated_sun_solar_rising` record stays so it cannot resurface.
* **Recorder**: also excludes P110 voltage/current and day/month counters and
  two phone sensors (~49% of last week's state rows); verified after restart
  that the excluded entities stop being written and energy-dashboard sensors
  are untouched.
* **Logger**: silenced the `habluetooth.manager` / `aiodhcpwatcher` permission
  errors that a rootless container always hits.
* **Dead shell commands removed**: `turn_on_rechenkiste`, the three F@H
  commands and `send_mail` had no caller since the automations were dropped,
  and could not run anyway (`wakeonlan`/`mail` are not in the image, no SSH
  private key). `turn_off_rechenkiste` stays but needs its key restored.


## 2026-09-29 - Windows ROCm torch source build: first rocm build green, after three fixes

`-Variant rocm -Stages torch,final` on the 2026-09-28 rocm parent is green: `BUILD_RC=0`, smoke gate 215
assertions (1 skipped), `rocm-checks\Torch.ps1` reports torch 2.14.0+rocm10.0.0 (HIP 7.15.26333) and
torchvision 0.29.0+rocm10.0.0 compiled for gfx1200 and gfx1201. The first three runs each died on one of these:

- **The build venv reported `win32`.** The image's clang-built CPython needs the base `sitecustomize.py` shim,
  and a venv does not load it: uv resolved 32-bit wheels (pyyaml's sdist build then died on a 32-bit Cython).
  `Copy-TorchRocmVenvShim` copies the shim and `python3.dll` in, as `Build-TorchApp.ps1` does, and the builder
  stops unless the venv reports `win-amd64`.
- **No `libomp140.x86_64.dll` in the VS 18 redist.** MSVC 14.51 ships the release DLL only under
  `debug_nonredist`, so the wheel no longer carries it. `torch_cpu.dll` resolves it from System32, where the
  image's VS install puts it, and `Assert-TorchRocmSystemLibomp` checks that before the compile.
- **torchvision's import check had no PIL, and took a finished torch build with it.** torch and torchvision
  are now two RUNs (new `Build-TorchvisionRocmFromSource.ps1`, with pillow and on the torch RUN's venv). The
  torchvision ARGs sit below the torch RUN, so a torchvision failure, edit or bump keeps the torch layer.

Measured: torch 4051 s cold, 1719 s with sccache warm; torchvision 228 s; the whole driver run 54 min.
Also: `failure-modes.md` gains the containerd snapshot sweep that stalled every new RUN for 50 minutes on the
same evening (about 440 GB deleted, nothing wrong), and a driver comment now points at `windows-rocm.md`.


## 2026-09-29 - compiler caches save on the default branch only

- **`compiler-cache-save`'s `enabled: auto` now saves on pushes to the default branch only**, and
  `container-ci-windows.yml`'s save step does the same. It used to save on every push, and the
  deletion of older entries works per branch: a release push to `main` would have stored a
  second generation of every key, about 7.3 GB more in BeschleunigerBallett.
- **Nothing is lost on other branches:** every other branch, pull request and dispatch restores
  the default branch's entry, which GitHub lets any branch read.
- **Docs:** [`build-cache-tiers.md`](build-cache-tiers.md#keeping-the-compiler-cache-across-ci-runs)
  and the actions README.


## 2026-09-29 - compiler caches keep one entry per key

- **`compiler-cache-save` deletes the key's entries from older runs on the same ref before it saves.**
  Each save adds a per-run entry, and the superseded ones stayed until GitHub's quota eviction.
  That eviction takes the least recently used entry of the whole repository, not of the key.
  BeschleunigerBallett reached 11.2 GB and OxidANT 12.4 GB of the 10 GB quota, and Ballett's TSan
  job restored nothing because its only entry went while stale x64 duplicates survived.
- **What the saving job needs:** `permissions: actions: write`. Without it the step warns and
  saves anyway. An empty or missing directory deletes nothing.
- **New inputs and outputs:** `path` (what to save) and `token` inputs, and a `pruned` output.
- **New action `compiler-cache-prune`**, the same deletion (`prune.sh`, shared with the save).
  It is for lanes that save elsewhere. `container-ci-windows.yml`'s job grants only
  `contents: read`, and a reusable workflow cannot ask for more than every caller grants, so a
  caller setting `compiler-cache-key` prunes from a later job.
- **Self-test:** it now asserts that no older selftest entry survives a save, and that
  compiler-cache-prune then finds nothing.
- **`compiler-cache-prune` deletes only once this run saved its own entry** (`require-saved`,
  default `true`), so a build that died before its save keeps the older one.
- **Docs:** [`build-cache-tiers.md`](build-cache-tiers.md#keeping-the-compiler-cache-across-ci-runs)
  and the actions README.
- **BeschleunigerBallett's `permissions` census row is deleted.** Its `reusable-linux.yml` now
  declares `contents: read` at the top and `actions: write` on the four cache writers, which
  takes the census from 11 to 0.


## 2026-09-29 - `-DisableSccache` beats the preset; the sccache-on-modules docs are corrected

- **`Invoke-CmakeConfigureAndBuild -DisableSccache` now disables sccache.** It only cleared environment
  variables, and a preset with `COMPILER_CACHE=sccache` made `Cache.cmake` set the launcher again. A reused
  build tree kept it in `CMakeCache.txt` as well. The configure line is built by the new, exported
  `Get-CmakeConfigureArgs`, which puts `-DCOMPILER_CACHE=` and both empty `CMAKE_<LANG>_COMPILER_LAUNCHER`
  after the caller's arguments. Tested in `WindowsCMake.Common.Tests.ps1`.
- **The docs said sccache "caches nothing" on a C++23 modules build.** That was wrong, and the "harmless to
  leave wired up" that followed was dangerous. The released 0.18.0 with clang-cl caches importers without
  hashing the BMIs they import, so after an interface edit a warm cache returns stale objects (reproduced on
  BeschleunigerBallett and AccelerANTgine). Rewritten from measurement:
  [`windows-container-build-performance.md` § sccache on a C++23 modules build](windows-container-build-performance.md#sccache-on-a-c23-modules-build),
  with the one-liners in `windows-builds.md` and `windows-build-resources.md`.


## 2026-09-29 - Windows ROCm: torch 2.14.0 / torchvision 0.29.0 built from source against ROCm 10.0

Owner decision: the Windows rocm image builds PyTorch here instead of installing AMD's wheels.
AMD's ROCm 10.0 Windows wheels stop at torch 2.13.0, the app locks 2.14.0, and `Assert-TorchRocmVenvMatch`
refused the pair as soon as the torch stage tracked the app's `develop`.

- **`Dockerfile.torch` gains a `torch-rocm-wheels` stage** (`Build-TorchRocmFromSource.ps1`). It builds on the rocm
  `BASE_IMAGE`, never on `app`, so an app move cannot re-run the compile, and only `rocm-1` mounts it, so cpu and
  nvidia never build it.
- **Sources** are upstream `v2.14.0` / `v0.29.0` at `PYTORCH_VERSION` / `TORCHVISION_VERSION`, fetched by the
  new `TORCH_ROCM_WINDOWS_PYTORCH_COMMIT` / `_TORCHVISION_COMMIT`. They are compiled against the image's TheRock
  SDK for the `ROCM_WINDOWS_GFX_FAMILY` targets (gfx1200, gfx1201).
- **The recipe is TheRock's** `external-builds/pytorch/build_prod_wheels.py`: HIPIFY, TheRock's clang-cl,
  `torch/_rocm_init.py` and `rocm[libraries]==<release>`, so the wheels load ROCm like AMD's.
- **Off in this first build:** AOTriton (flash / memory-efficient SDPA; its CMake fetches unpinned sources at
  build time), `torch.distributed` and torchvision's image IO.
- **`Install-TorchRocm.ps1`** installs the two built wheels (exactly one each, `+rocm<release>`, hashed on the
  spot) with AMD's pinned runtime: `rocm`, `rocm-sdk-core`, `rocm-sdk-libraries` and a device wheel per GPU.
  The eight AMD torch, torchvision, device and bootstrap pin pairs are gone from `versions.env`.
- **`rocm-checks\Torch.ps1`** now asserts torch was compiled for every GPU rocBLAS serves
  (`torch._C._cuda_getArchFlags()`), instead of AMD's per-GPU torch device wheels.
- **The driver** forwards `PYTORCH_VERSION`, `TORCHVISION_VERSION`, `ROCM_WINDOWS_GFX_FAMILY` and the sccache
  endpoint to the torch solve on rocm only.
- **Records:** `deps.json`, the curated SBOM and the licence tables describe the source build;
  `bump_versions.py` registers the two commits.
- **Tests:** `Torch.Rocm.Tests.ps1` rewritten for the new set, `Torch.RocmSourceBuild.Tests.ps1` for the
  builder's pure parts. `Rocm.Migraphx.Tests.ps1` lets only that one rocm-only stage mount
  `WindowsMigraphx.Common`.
- **Not yet proven:** no rocm build has run this stage. Building against AMD's SDK tarball rather than the
  `rocm-sdk-devel` wheel has no public precedent:
  [`windows-rocm.md` § PyTorch on the rocm lane](windows-rocm.md#pytorch-on-the-rocm-lane-torch-stage).


## 2026-09-29 - The torch stage builds OrchestrANT's `develop`, at the commit it points to

Owner decision: the images take the app from its `develop` branch, and a fix the build
needs goes to `develop` directly instead of into a release tag. `APP_REF` in `versions.env`
is now `develop` and names what to track.

- **Resolved to a commit when the run starts, never used as a name.** BuildKit keys the
  torch RUN on its build args, so a fixed `develop` would reuse the first clone forever and
  ship a stale app behind a green build. `runtime_resolve_app_ref` (Linux, once per run
  before the per-arch loop) and `Resolve-TorchAppRef` / `Resolve-GitRefCommit` (Windows)
  resolve the ref with `git ls-remote`. The torch layer then rebuilds exactly when the app
  moved, every arch of one index builds the same commit, and the commit is the image's
  version label. A 40-hex `APP_REF` is built as given.
- **Fetched as a commit.** `assemble-torch-app.sh` and `Build-TorchApp.ps1` fetch a 40-hex
  ref with `git init` + `fetch --depth 1` + `checkout FETCH_HEAD`; a name still clones, with
  a warning, for a plain `docker build`.
- **The ROCm extra is `pytorch-rocm10`** (`runtime_gpu_backend_pair`, `smoke-torch-venv.sh`),
  as the app names it on `develop`.
- **Cost:** the `versions.env` edit re-keys the Linux chain once; later app moves rebuild the
  torch stage only. An unreachable remote stops a real run; `--dry-run` only warns.
- **Known gap:** the Windows ROCm variant installs AMD's ROCm 10 wheels, which stop at torch
  2.13.0, and refuses an app lock on 2.14 (`Assert-TorchRocmVenvMatch`), so `-Variant rocm`
  on Windows fails its torch stage until torch 2.14 is built from source here.
- **Removed:** `bump_versions.py`'s unregistered `spec_app_ref`, which proposed the newest
  release tag for `APP_REF`.
- Tests: `test-app-ref.sh` (resolution, precedence, failure, the commit fetch, both entry
  points wired) and `BuildDriver.AppRef.Tests.ps1`.
  [`linux-cross-builds.md`](linux-cross-builds.md#the-app-the-wrapper-builds).


## 2026-09-29 - Linux lanes can keep their compiler cache across runs

Two new actions, `compiler-cache-restore` and `compiler-cache-save`, carry a Linux container
lane's `/var/cache/{sccache,ccache}` between CI runs through `actions/cache`. Until now every
run compiled cold, because each step's `--rm` container took the cache with it. In
AccelerANTgine's linux-x64 lane, measured against a same-time control, the clang job fell from
25.1 to 14.4 min. Saves happen on pushes only, one key per lane, sized for the 10 GB repository
quota: `docs/build-cache-tiers.md` § Keeping the compiler cache across CI runs. Windows lanes
are not covered yet.

`actions-selftest.yml` exercises both actions (a write through the mount, read back on the host)
and now compares the Windows deep lane's action-directory count with the host checkout instead
of a literal 11, which had been wrong since the twelfth action.

`container-ci-windows.yml` takes a `compiler-cache-key` too. It restores the cache into the
workspace and hands the container `CI_COMPILER_CACHE`; the build script moves it into
container-local directories, because sccache cannot write to a mounted one on Windows. Not for
clang-cl module builds until mozilla/sccache#2876 ships.


## 2026-09-29 - The consumer-pins gate holds torch, torchvision and onnxruntime-genai

`consumer_pins.py` compared only a consumer's ruff pins with `versions.env`. The image build
force-installs `PYTORCH_VERSION` and `TORCHVISION_VERSION` over the app lock, so OrchestrANT's
`torch==2.13.0` meant 2.13.0 on a dev box and 2.14.0 in the image, and no gate said so.

- **Five new rows:** the `"torch=="` and `"torchvision=="` pins, their riscv64
  `pytorch.git@v<tag>` / `vision.git@v<tag>` source pins, and `"onnxruntime-genai[-cuda]=="`.
  The unpinned `onnxruntime-genai-directml` is not a mention.
- **A leading `v` is dropped before comparing.** These three keys carry the GitHub tag
  (`v2.14.0`); a consumer pins the bare number.
- **Proven:** new cases in `test-version-snapshot.sh`, and the gate's first two mutations
  (`version-snapshot.consumer-pins-tag-prefix`, `version-snapshot.consumer-pins-torch-row`).
- **Rollout:** a consumer's `lint-gates.yml` runs this from `develop`, so a lagging consumer goes
  red on its next push. OrchestrANT moved first (`febd7ea`: torch 2.14.0 / torchvision 0.29.0),
  so its lane stays green.
  [`code-quality-tooling.md`](code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons).
- **OrchestrANT's ROCm extra is now `pytorch-rocm10`** (the `rocm7.14` wheel line, as
  `PYTORCH_ROCM_INDEX`). The ROCm wrapper keeps passing `pytorch-rocm71`, which the pinned
  `APP_REF=v0.0.28` defines; the change that moves `APP_REF` must switch
  `runtime_gpu_backend_pair` and `smoke-torch-venv.sh` with it:
  [`linux-accelerator-images.md`](linux-accelerator-images.md).


## 2026-09-28 - Windows images: faster native libraries, KleidiAI on arm64

An audit of the Windows build before the CON12 rebuild found four things that left runtime
speed on the table. All four ship with the next `:winamd64`/`:winarm64` build:

- **GStreamer (both arches)** passes `-Dbuildtype=release`, as the Linux lane does. Without it
  the monorepo's `default_options` gave `debugoptimized`: `/Zi` objects, and GLib's
  `glib_debug` checks switched on in every shipped GLib.
- **OpenCV (amd64)** sets `CPU_BASELINE=AVX2`. Every TU was already compiled for AVX2+FMA, but
  OpenCV's baseline universal intrinsics stayed at SSE3/128-bit. A configure gate fails if the
  baseline does not report AVX2.
- **LiteRT (amd64)** gets the image's AVX2 baseline through `CMAKE_*_FLAGS_INIT`. Its own
  kernels had built at SSE2.
- **ONNX Runtime (arm64)** builds MLAS with KleidiAI, runtime-dispatched. Only `build.py` turns
  it on, and this script configures through CMake. XNNPACK, OpenCV (KleidiCV), Arm NN and ACL
  have no usable Windows-on-Arm KleidiAI/ACL path at the pinned versions:
  `docs/windows-cross-builds.md`.

Then, the same day, the owner took the four follow-ups:

- **KleidiAI's `.S` kernels are assembled through a preprocess step.** Upstream's `ASM_MARMASM`
  rule hands them raw to armasm64, which has no C preprocessor and rejects the `/arch:armv8.2`
  KleidiAI adds. Measured in `:winamd64`: A2029, then A2003/A2230/A2034, until the rule became
  `clang-cl /P /EP /TC /U__clang__` then armasm64 (178/178 objects). ORT gets that patched tree
  through `FETCHCONTENT_SOURCE_DIR_KLEIDIAI`; configure fails if its rule is not the wrapper.
- **ONNX Runtime ThinLTO** on the CPU and arm64 builds (not with CUDA, as ORT itself withholds
  `/LTCG` there). A probe of the image's clang-cl + llvm-lib + lld-link produced bitcode objects
  and a linked DLL for amd64 and arm64. `versions.env`'s `ORT_ENABLE_LTO` stays the Linux knob.
- **GStreamer** also passes `-Db_ndebug=if-release`, so every subproject drops `assert()`.
- **FFmpeg on every native amd64 lane** gains AMD AMF (was rocm-only) and NVENC/NVDEC/CUVID (was
  nvidia-only). Both are header-only and load the vendor DLL at run time, so the CPU image imports
  nothing new. Vulkan stays rocm's. The smoke gate lists `h264_amf`/`hevc_amf` and the NVENC
  encoders on the CPU image.
- **FFmpeg software codecs (amd64)**: `Build-FfmpegCodecs.ps1` builds static dav1d (AV1 decode),
  x264 and x265 (H.264/HEVC encode) and links them into FFmpeg's DLLs, so no codec DLL can meet
  GStreamer's. They use the static CRT, as FFmpeg's DLLs do (`avcodec` imports no CRT DLL).
  x265 4.1's two OLD policies are set NEW, because CMake 4 refuses them. dav1d and x264 are the sources GStreamer's own wraps pin; the six pins live in
  `versions.env` and travel as media-core build args. The arm64 cross lane has none yet: it needs
  GStreamer's meson cross file and aarch64 asm shim reproduced first.


## 2026-09-27 - `:winamd64` is CPU + DirectML; the CUDA build is `:winamd64-nvidia`

The owner decided that Windows follows the variant rule in `AGENTS.md` § Image and tag
naming. `Build-Buildkit.ps1 -Gpu` (`-Variant nvidia`) now writes `bk-*-nvidia` stage tags
and a `winamd64-nvidia` final image, or `winarm64-nvidia` for the cross bundle, and
`Resolve-BkVariant` refuses to push it under any other tag. `:winamd64` is the build without
`-Gpu`. Until now the nvidia build wrote the default tags, so the `:winamd64` published on
2026-09-22 carries CUDA until that tag is republished. No consumer needs CUDA from the
Windows image, so the switch needs no consumer commit (BACKLOG CON12).


## 2026-09-26 - The image backlog, swept: fixed in source, decided, or the owner's

Every open item of `BACKLOG.md` was worked. Most are image fixes that ship with the next
publish (CON11 for `:latest`, CON12 for `:winamd64`), each proven against the published
image in a throwaway container or a buildkit probe; the rest are recorded decisions or wait
on the owner. Both chains rebuild from base at the next publish anyway (`versions.env`
changed since each published image), so none of this adds a re-key.

- Hub scripts, effective now. `Copy-MediaRuntimeBundle` finds the family image's GStreamer
  through `GSTREAMER_BIN` (`C:\runtime\bin`); AccelerANTgine run 36044940426 had staged
  only ONNX Runtime (CON33). The Rust driver checks for `cargo fmt`/`cargo clippy` instead
  of `rustup component add` (CON32).
- Android API 37 (CON14). The `android-sdk-shared` cache id never named the two API 37
  pins, so every build since 2bb0410f restored an SDK tree cached on 2026-08-22. The id
  names every pin (`tests/test-android-sdk-cache-key.sh`); a restored tree is checked
  against sdkmanager's `package.xml` records, completed and refreshed; the smoke checks
  every platform.
- The Linux toolchain (CON15-CON17). A bare `clang`/`clang++` selects `${GCC_PREFIX}`
  through `<native-triple>-clang{,++}.cfg`; clang's own `clang-tidy`, `llvm-profdata`,
  `llvm-cov`, `llvm-symbolizer`, `ld.lld` and 16 more are on `PATH` (`clang-format` and
  `llvm-config` stay 21 on purpose); compiler-rt builds libFuzzer. `validate-compilers.sh
  smoke` checks all three.
- The Linux runtime (CON18, CON19, CON20, CON21, CON23). `VIRTUAL_ENV`/`UV_PYTHON` no
  longer send uv at the root-owned `/opt/venv`; lavapipe gives a CPU Vulkan device; `perf`,
  `jq`, `Xvfb` and gperftools ship; amd64 drops the unused distro GTK 4 and GStreamer 1.28
  runtime; `libcamera-env.sh` and the entrypoint let a caller's `LD_LIBRARY_PATH` win
  without shadowing GCC 16.2's `libstdc++`. `consumer-image-contract.md` § What changes
  with the image after CON11 is the consumer's list.
- The Windows image (CON9, CON10, CON25, CON28, CON29). The patched LLVM builds
  `clang_rt.profile` and a clang-tidy that reads its own BMIs, both proven by rebuilding the
  tree that ships in `:winamd64`, and its 7.1 GB source tree no longer stays in the layer;
  the final stage puts LunarG's `vulkan-1.dll` on PATH (never System32; OpenGL stays
  host-only, the owner's decision); the app venv
  installs `ai-edge-litert` from the lock; GStreamer's `gdkpixbuf` plugin builds on amd64,
  `enabled` so its next loss fails meson setup; no baked `C:\workspace`. The first local
  rebuild with Blackwell in the arch set found that sccache 0.18 aborts ORT's PTX-only LLM
  kernels (mozilla/sccache#2862), so ORT's nvcc stays bare for such an arch list.
- Decided (§ Deliberate): arm64/riscv64's distro GStreamer (CON21), their thin GCC
  (CON22), riscv64 TVM/IREE targets (CON24, with the flags in
  `riscv64-rva23-baseline.md`), lane-installed `cargo-audit`/`cargo-deny` and no Linux
  `pwsh` (CON20), five Windows absences (CON28), and OpenGL in the Windows image, host-only
  by the owner's decision (CON25). CON27 waits on microsoft/STL#6298.
- Found on the way: amd64's GCC carried 4.4 GB of unstripped cross compilers, because
  `build-gcc.sh` stripped with the target's `strip` alone; the build machine's runs too now
  (CON36). amd64's TVM could not load its compiler library: a native build linked apt's
  bootstrap LLVM, which the image lacks. It links the LLVM the image ships now, and the venv
  smoke fails a TVM that cannot compile (CON35).


## 2026-09-26 - The reusable Windows lane takes a caller's secrets

BeschleunigerBallett's x64 lane could not become a thin caller of `container-ci-windows.yml`:
its build fetches the MSIX signing certificate over WebDAV, and the reusable lane accepted
no secret but `GHCR_PAT`.

- `container-ci-windows.yml` takes an optional `CONTAINER_SECRET_ENV` secret, one `KEY=value`
  per line, which the caller composes from its own secrets. The compose step masks each value
  and writes the pairs to an `--env-file` in `RUNNER_TEMP` (LF, UTF-8 without BOM), so no value
  enters a command line, a step output or the job environment. A line that is not `KEY=value`
  is refused without being echoed.
- `windows-cross-builds.md` § Consumer cross lanes and the adoption guide describe it.


## 2026-09-25 — Home Assistant 2026.9.1 → 2026.9.3

* Upgraded the live container. glances was already current (4.5.6).
* README § Updating: `up -d` alone does NOT pick up a pulled image under
  nerdctl compose; the documented command now carries `--force-recreate`, and
  warns that the "orphaned" container reported for a single-service `up` is
  the other live service, not debris.


## 2026-09-25 - One Windows module stages and proves a consumer's ONNX Runtime

OxidANT, OmniAccelerANT and AccelerANTgine each carried the same glue around G6, as
local modules under three names: the ORT family's names, "replace the ORT beside the
exe with the chain's", and the proof of a shipped tree. It is
`WindowsOrtPayload.Common` now, a consumer-side module.

- `Copy-ChainOrtBeside` stages the core, the provider bridge and `DirectML.dll` from
  the chain install; `-All` stages every DLL of its `lib\` and `bin\`, EP sidecars
  included. It goes through `Get-OnnxChainLayout`, so a non-chain or wrong-arch
  `ONNX_ROOT` throws before anything is copied. Two of the three copies only
  checked that `bin\onnxruntime.dll` existed.
- `Assert-ChainOrtTree` is G6 over a tree, plus what G6 does not grade: MISSING
  `onnxruntime.dll` where the exe looks, a STRAY family name the chain has not got,
  a CHANGED `DirectML.dll`. STRAY is judged against the chain's own file names, not
  a fixed list, so a chain with a CUDA or QNN provider does not trip it, and those
  names include the chain GenAI install's when `ONNX_GENAI_ROOT` is set:
  AccelerANTgine's staged `bin\` carries `onnxruntime-genai.dll`.
  `-WaiveUnresolved` keeps AccelerANTgine's Python-package mode.
- `New-OrtProvenPayload` builds and proves a package payload in a fresh directory;
  `-IncludeDirectory` carries a tree beside the exe with it (OxidANT's
  `lib\gstreamer-1.0`), graded by G6 with the rest.
- `OrtPayload.Common.Tests.ps1` holds OxidANT's cases, moved, plus `-All`, a chain
  provider that is not STRAY, and `-WaiveUnresolved`. `onnxruntime-single-source.md`
  § The shared Windows glue documents it; the consumers drop their copies when their
  hub pins move.


## 2026-09-25 - The arm64/riscv64 native GCC has multiarch (CON8)

BeschleunigerBallett's arm64 GNU presets could not find X11, while its Clang preset
could. Measured in the published `:latest` (`ec4bb68b`) under qemu: the arm64 GCC
printed no `-print-multiarch`, its link line held no `/usr/lib/aarch64-linux-gnu`, so
CMake left `CMAKE_LIBRARY_ARCHITECTURE` empty and `find_library` never looked there.
The amd64 GCC prints `x86_64-linux-gnu`. The arm64 and riscv64 GCC is the Canadian
native, and `build-gcc.sh` configures every `--target` build with
`--with-native-system-header-dir`, which switches GCC's multiarch auto-check off.

- `build-gcc.sh` passes `--enable-multiarch` when `--host` equals `--target`
  (`_gcc_native_multiarch`). `_gcc_is_canadian_native` is now the one owner of that
  test, shared with libsanitizer's helper. Plain cross compilers are unchanged.
- `swap-native-gcc.sh` stops the build when the relocated GCC prints another
  multiarch, where the build host can run it.
- `test-native-gcc-multiarch.sh` and the `native-gcc-ma.*` mutations prove the helper,
  its wiring and the gate. `cross-build-verification.md` § The native GCC has
  multiarch has the measurements.
- In source only: it ships with libsanitizer in the next Linux `:latest` (CON11).


## 2026-09-25 - MSIX `-Sign` takes the signing root from the caller

`Invoke-MsixPackage -Sign` looked for the signing `.pfx` in the staging directory's
parent. Every consumer stages inside a build directory, so none could use it.
AccelerANTgine and BeschleunigerBallett called `Invoke-MsixSign` themselves with their
repository root, and OxidANT never signed.

- `-Sign` now needs `-SigningRoot`, the directory that holds the `.pfx`: the
  repository root, where the family keeps it gitignored. Without it the call throws
  before it stages anything. No caller in the family's checkouts passed `-Sign`, so
  nothing that worked breaks.
- `Invoke-MsixSign`'s warning names the directory it searched. It used to say
  "repository root" whatever it had been handed.
- `WindowsMsix.Common.Tests.ps1` pins both halves, and each new case fails against
  the old code. Its packer cases now share one makeappx stub and one resolver mock.


## 2026-09-25 - x64 lanes move onto the reusable Windows lane: `version-file`, `host-command`

The family's next sharing step (owner request): the consumers' `windows-x64.yml`
lanes become thin callers of `container-ci-windows.yml`, one repo at a time,
OxidANT first. Two things an x64 lane did by hand had no input.

- `version-file`: the hub's `version_util.sh` resolves `VERSION` and
  `MSIX_VERSION` on the host, from the file, the ref name and the run number. The
  container gets both as environment.
- `host-command`: PowerShell on the runner host after the container build, in the
  workspace the container built into. It is for what Server Core cannot run (no
  `opengl32.dll`), such as OxidANT's WebGPU renderer tests and a run of its x64
  product.
- Every native command in `host-command` and `run-command` counts
  (`$PSNativeCommandUseErrorActionPreference`). Before, `run-command` failed the
  lane only through the exit code of its last line.
- `windows-cross-builds.md` § Consumer cross lanes and the workflow's header
  describe both.

`lint-workflows.sh` is clean.


## 2026-09-25 - x64 packages carry the same DLL closure as arm64

Owner decision: the consumers' x64 packages ship what their binaries import,
as the arm64 ones do. A clean x64 PC lacks the media stack and may lack the
VC++ runtime too, and AccelerANTgine's x64 MSIX carried neither.

- `Get-ProductDllSearchPath` (`WindowsCrossBundle.Common`) gives one search
  order for every consumer's closure:
  1. the chain ORT (`ONNX_ROOT\bin`), so an ORT-family import resolves to it;
  2. the image's `C:\runtime\bin`;
  3. the target arch's `VCToolsRedistDir` CRT.
  Only existing directories are returned.
- `cmake/CPackCommon.cmake`: `kataglyphis_install_package_dlls` installs the
  DLLs of a directory named at configure time (`KATAGLYPHIS_PACKAGE_DLL_DIR`)
  beside the executables. A build script fills it with the closure before
  packaging, so the CPack packages ship it too.
- `windows-cross-builds.md` § Consumer cross lanes describes both.

Tests:
- `CrossBundle.Common.Tests.ps1` 8 pass. Reordering the search, ignoring the
  arch or dropping the existence filter each fails it.
- `test-cmake-windows-arch.sh` 8 pass. Two new `cmake-arch.*` mutations (the
  install rule, the `*.dll` filter) bite.


## 2026-09-25 - The three consumer cross lanes are green; arm64 binaries ran

OxidANT, AccelerANTgine and BeschleunigerBallett each gained
`windows-arm64-cross.yml`, a thin caller of `container-ci-windows.yml`. All
three went green on their first runs (36136967538, 36142875090, 36142882316).
Each cross-built in the arm64 bundle and passed the arch gate: 12, 22 and 8
arm64 binaries, no unresolved import. Each product then ran natively on
`windows-11-arm`. It is the first execution of any binary from the bundle on
arm64 hardware, though only as far as loading.

- `BACKLOG.md` CON30 says what that proves and what it does not.
- `windows-cross-builds.md` § Consumer cross lanes records the three runs.
  It also records how BeschleunigerBallett's run job borrows the Khronos Vulkan
  loader, pinned by hash, on the GPU-less runner.


## 2026-09-25 - A CMake consumer's cross build names its target

AccelerANTgine and BeschleunigerBallett build with CMake, and nothing they
call told CMake, Corrosion, FindVulkan, the hardening flags or CPack that the
target was arm64. Each of those follows the host by default.

- `Get-CrossConfigureArgs` (`WindowsCrossBundle.Common`): empty on amd64. On
  arm64 it returns `Get-CMakeCrossArgs`, plus `Rust_CARGO_TARGET` under
  `-Corrosion` and `Vulkan_LIBRARY` from the SDK's `Lib-ARM64` under `-Vulkan`.
  A missing arm64 import library throws and names the optional SDK component.
- `Get-WindowsPackageArch`: `x64` or `arm64`, the one spelling an AppxManifest's
  `ProcessorArchitecture`, `wix build -arch` and the VC++ redist directory share.
- `cmake/Hardening.cmake`: `/CETCOMPAT` on x64 targets only. An ARM64 link
  refuses it, and the flag was unconditional under `MSVC`, which clang-cl sets.
- `cmake/CPackCommon.cmake`: `CPACK_WIX_ARCHITECTURE` is `arm64` when the
  package arch is `aarch64`. Left unset, CPack derived x64 from the pointer size.
  An arm64 package also installs the VC++ runtime without `vcruntime140_1.dll`
  (`kataglyphis_arm64_system_runtime_libs`). The arm64 redist folder carries that
  file as ARM64EC, an x64-machine PE, and AccelerANTgine's first cross build
  shipped it and failed the arch gate. `CMake` identified the target correctly:
  the file really is in the arm64 folder.
- `windows-cross-builds.md` § Consumer cross lanes: the configure side, and why a
  cross lane builds Release only.

Tests:
- `test-cmake-windows-arch.sh` (new) configures a compiler-less project with
  MSVC faked: AMD64 keeps `/CETCOMPAT`, and `ARM64`, `arm64` and `aarch64` drop
  it, and the arm64 runtime list keeps everything but `vcruntime140_1.dll`. 6
  pass, and four `cmake-arch.*` mutations (a new declared family) bite.
- `CrossBundle.Common.Tests.ps1` 7 pass. Dropping the host shortcut, reading
  the x64 Vulkan `Lib` or ignoring `-Corrosion` each fails it.


## 2026-09-25 - A cross lane's product carries its DLL closure

The arm64 run job needs a folder that runs on a clean device. The CRT, ONNX
Runtime and everything they import have to be in it, and nothing in the hub
could collect them.

- `WindowsCrossBundle.Common` (new): `Copy-PeImportClosure -Path <binaries>
  -SearchDirectory <dirs> -Destination <dir> -Arch arm64`. It walks static and
  delay-load imports (the set the import walk grades) transitively and copies what
  the search directories hold, the first directory winning. Names found nowhere are left to the device, and a closure DLL of the
  wrong machine throws through `Assert-PeTargetMachine`, the media gates' own
  check. It is a new module because `WindowsTargetArch.Common`,
  where the PE readers live, is mounted into every media stage.
- The synthetic PE builders (`New-OrtTestPe`, `New-OrtTestExportTable`) moved
  from the census suite into `TestHarness.psm1`. `New-OrtTestPe` takes a
  `-Machine` and writes a delay-load table for `-DelayImport`.
- `windows-cross-builds.md` § Consumer cross lanes says what the folder must hold.
- WebDavClient's Linux lane split into `linux-x64.yml` + `linux-arm64.yml`; the
  rename table and `python-ci.md` record it. OrchestrANT's split stays open.

Tests: `CrossBundle.Common.Tests.ps1` 3 pass. Dropping the transitive enqueue,
the delay-load table, the first-directory rule or the machine check each fails
it. The census suite still passes 25 with its builders moved. The dupes
allowlist moves the builders' two rows to `TestHarness.psm1` unchanged.


## 2026-09-25 - The Windows arm64 cross lanes get a hub lane; the gate knows the bundle

Owner decisions of 2026-09-25: `windows-arm64-cross.yml` lanes for OxidANT,
AccelerANTgine and BeschleunigerBallett, built in the arm64 bundle on the amd64
runner, plus a job that runs the product natively on GitHub's `windows-11-arm`.
Lanes share through hub reusable workflows with thin callers. Until now nothing in
the family could even name the bundle in CI: `verify_ci_image_refs.py` accepted
exactly two canonical tags and had no route for a third.

- `versions.env`: `CI_IMAGE_WINDOWS_ARM64_TAG=winarm64` (noforward). Like any
  edit to that file it re-keys the next image build.
- `prepare-windows-container-host` and `run-in-windows-container`:
  - `target-arch: amd64|arm64` (default amd64; anything else fails in the first
    step);
  - an `image-arm64` input whose default is the bundle;
  - the prepare action outputs the `image` it pulled.
- `verify_ci_image_refs.py`: the arm64 ref is canonical.
  - Check A grades every image input of an action, so six defaults now instead
    of four.
  - Check C takes the ref of the input a literal is handed to.
  - The bundle spelled out anywhere is still a copy (check D).
- `ci-image-ref.sh --windows-arm64` and `Get-CiImageReference -Windows -TargetArch
  arm64` ask for the same ref.
- `container-ci-windows.yml` ("Container CI · Windows (reusable)"): one Windows
  container lane for `target-arch: amd64` and `arm64`. The job:
  1. prepare;
  2. run the caller's build script in the image;
  3. on arm64, run `Test-TargetArch.ps1 -Arch arm64 -ImportWalk` over the
     product, in the same image, from the caller's own hub submodule;
  4. upload the product.
  With a `run-command`, a `windows-11-arm` job then downloads the product and
  runs it natively.
- `actions-selftest.yml` passes `target-arch` to both actions and reads the new
  `image` output. `windows-cross-builds.md` § Consumer cross lanes, the actions
  README and `INDEX.md` describe all of it.

Tests: `test-ci-image-ref.sh` 53 pass, with new fixtures for a Windows action
carrying both inputs:
- a wrong or missing `image-arm64` default fails;
- the bundle handed to `image:`, or the amd64 image handed to `image-arm64:`,
  fails;
- `target-arch: arm64` with no image passes.

All 13 mutations on the gate and on `ci-image-ref.sh` bite, three of them new.
`lint-workflows.sh` is clean, 26 YAML files. No suite covered
`Get-CiImageReference`, although `ci-image-ref.sh`'s header says the two are
held equal. `ContainerImage.CiRef.Tests.ps1` now does: all three refs against
versions.env, arm64 refused without `-Windows`, and a missing arm64 key throws.
Breaking the arm64 key lookup fails it.


## 2026-09-25 - An APISIX gateway in front of the GenieX lanes (P1: the lab only)

`linux/llm-stack` gains a gateway: APISIX 3.18.0, pinned by digest, on
`127.0.0.1:9080`. Clients ask for an alias (`chat`, `chat-long`, `agent`) with
their own key (`webui`, `lab`, `agent`), and the gateway applies the GenieX rules
the lab measured. `chat` goes to the NPU. A request estimated too large for its
4k context goes to the GPU before anything is sent, and an NPU
`400 context_length_exceeded` is sent to the GPU once. With tools, the request
gets the tools prompt P8.1 measured, pinned by the sha256 of its raw bytes. T=0 is
made greedy on the GGUF lanes only. The NPU times out at 300 s and the GGUF lanes
at 1800 s. Nothing is retried once a reply has started, and nothing probes a lane.
`raw-<lane>` routes, lab key only, skip the shaping; they are the transparency
path for the acceptance runs.

Everything is rendered from a new top-level `serving` block in `backends.json`
by `gateway/render_apisix.py`, which refuses an unknown lane or key, a GGUF on
the QAIRT lane, a missing prompt, a prompt sha mismatch, a listener off
loopback, a route id emitted twice and a lane that is the gateway itself.
`scripts/serve-stack.sh up|reload|down|status|keys|validate` boots each
candidate in a throwaway container before it goes live, rewrites `apisix.json` in
place and waits until `/gateway/info` reports the new config sha. APISIX alone
cannot do four of the rules, so a custom plugin (`geniex-shape`) and a hook
(`geniex_hook`) that patches four APISIX internals carry them. That hook is why
an APISIX bump now needs the new e2e suite green (AGENTS.md § LLM Stack).

The registry: `geniex-gpu` now names the Instruct-2507 GGUF (the chat-long lane,
an owner decision; earlier `geniex-gpu` runs measured the base 4B GGUF). The 9B
agent lane is a NEW entry, `geniex-cpu-9b`, because re-pointing `geniex-cpu`
would change what the lab's existing commands measure. Six `lab-*` entries reach
the lanes through the gateway with `GW_KEY_LAB` and `probe: false`.
`Start-GeniexServers.ps1` takes `-BindAddress` (default `0.0.0.0`, unchanged),
and warns when a lane it skips as already running listens somewhere else.

Tests: `test_gateway_render.py` (52 offline, with the overlay and `serve-stack.sh
keys`), and `tests/gateway_e2e/`, 79 tests against the real image and three fake
lanes (`GATEWAY_E2E=1`; CI job `gateway-e2e` on x64 and arm64). All 79 passed
live under rootless nerdctl on the arm64 dev host. Removing each hook patch, the
worker `envs` or the prompt insert turned the suite red where it should. That
run also found a reload rollback that restored `apisix.json` but not
`render.json`; fixed. An adversarial review then found and fixed, each with a
test that was red first: `live/runtime.env` (every key in clear) left 0644 by
the install's `chmod -R a+rX`; `geniex-shape` re-encoding a shaped body with
cjson's 14 significant digits (a seed of 123456789012345 reached the lane as
123456789012340); route ids an alias could repeat, which APISIX resolves by
silently keeping the last; a lane pointing at the gateway itself; and an
acceptance step (raise `budget_tokens` past the NPU's context) the renderer
refuses. The review also added the R5 cases (no request sent twice, no 429,
no cap, a client hang-up closes the lane's connection), loopback-only
listeners and the hook surviving a hot reload. Details:
`linux/llm-stack/README.md` § Gateway.

Merging it into `develop` (`6b1532a8`) would have turned preflight's
`workflow-lint` slug red. The two `gateway-e2e` matrix rows were one-line flow
mappings (`- { arch: x64, runs_on: ubuntu-26.04 }`), which the YAML subset that
`verify_workflow_conventions.py` reads cannot parse. That failed
`lint-workflows.sh`, the shipped-census assertion in `test-workflow-lint.sh`
and the *actionlint + CI image refs* gate of `run-lint-gates.sh`. The rows are
block mappings now, and the matrix GitHub reads is unchanged.


## 2026-09-25 - HIP compiles in the rocm image: TheRock's clang loads the `<cmath>` overlay

With torch through (entry below), the rocm chain built `bk-winamd64-rocm` and the
smoke gate passed 215 assertions. `Test-RocmImage.ps1` then failed on one item:
`[FAIL] hipcc could not compile a kernel for gfx1201`. It was the same clash MIGraphX
hit: MSVC 14.51's `constexpr` `isgreater` and its five siblings against clang's HIP
math headers, 20 errors for a one-line kernel. MIGraphX only got past it with its own
`-isystem` overlay, so no HIP compile worked in the image as shipped.

A new diagnostic, `Test-HipMsvcCmath.ps1`, measured the choices in the image. The
overlay fixes the compile given as `-isystem`, through `HIPCC_COMPILE_FLAGS_APPEND`
(`hipcc` only), through `CPATH`, and through `clang.cfg`/`clang++.cfg` beside
TheRock's `clang.exe`. TheRock ships no `*.cfg`, so the config files overwrite
nothing. They reach every driver name (`clang`, `clang++`, `amdclang++`, `hipcc`),
and CMake's HIP language too, and no user environment can undo them.

`windows/scripts/hip/` now holds the two headers and both config files. Two `COPY`s at
the end of `Dockerfile.rocm-llama` install them, as `C:\runtime\opt\hip-msvc-cmath`
and beside TheRock's clang. That is the first rocm stage every rocm build has after
the media stages, and being last keeps its llama RUNs cached. The files belong in
`Dockerfile.rocm`, but that re-keys the whole chain, so they move at the next full
rocm rebuild (`BACKLOG.md` CON34). MIGraphX keeps its generated copy for now. A
parity test holds the shipped headers equal to `Write-HipMsvcCmathOverlay`'s output,
and a second test holds both configs to the directory the Dockerfile installs into.
The probe also compiles with `--no-default-config`, which reports when a toolset
stops needing the overlay. On the unfixed image it measured MSVC 14.51.36231 with
TheRock 10.0.0: all three drivers fail, and the overlay is still needed.

**The rocm chain is through.** The rebuild took 24:44 from cache, with
`Stages: base, sdk, toolchain, media, migraphx, llama, torch, final (rocm)`. The smoke
gate passed 215 assertions (1 skipped), and `ROCm image checks: all passed (root
C:\TheRock\build, kernel compiled for gfx1201)`. The publish gate passed too. On the
rebuilt image the probe reads both configs back, and `hipcc`, `clang -x hip` and
`amdclang++ -x hip` all compile as the image ships them. `--no-default-config` still
fails with the same 20 errors, so the overlay stays.


## 2026-09-25 - The torch ROCm wheels download straight into the cache, with no rename

With MIGraphX, the EP and llama.cpp through, the torch stage built and verified the
app venv. Its ROCm half then downloaded and SHA-verified three pinned wheels and
stopped: `Move-Item: C:\bkmnt\Install-TorchRocm.ps1:324 ... Could not find a part of
the path`. `Save-TorchRocmWheel` downloaded each file to `<file>.part` in the
hash-keyed cache (`C:\uvcache\torch-rocm\<sha256>\`) and renamed it into place.
torch (51-character file name) and torchvision (57) moved. The first 68-character
name, `amd_torch_device_gfx1201-...`, did not. The download had just created the
`.part` there, five characters longer still. So the failing operation is the rename
on the BuildKit cache mount, the create-then-rename class in
`windows-build-lanes.md` § *Run-side wcifs symptoms*. The containerd store is
admin-only, so the host-side path length behind the mount was not measured.

Each file now downloads to its cache path directly. The rename bought nothing the
existing checks do not already give: a failed download deletes what it wrote, and
every reuse re-hashes the cached copy. The four cache tests still pass (layout,
offline reuse, tampered copy re-fetched, mismatch leaves nothing). A new one fails
if a rename comes back, and was mutation-checked by re-adding one.
`Torch.Rocm.Tests.ps1`: 57 pass.


## 2026-09-25 - The EP stage's G2 gate no longer finds its own source's `.tar`

With the seeds extracting (entry below), `migraphx-ep.dll` configured, built in
284 s and staged, and then phase 5 failed. `ORT gate (amdgpu-ep) FAIL: an ONNX
Runtime archive: C:\temp\ort-amdgpu-ep-work\onnxruntime-ep-amdgpu-src\onnxruntime-ep-amdgpu.tar`.
That file is the intermediate tar from the first 7-Zip pass over the EP's own
`.tar.gz`. `Expand-SourceTarball` never deletes it, and G2's archive rule matches
any `onnxruntime*` archive in the tree (only GenAI and extensions are excepted).
The finding was the only one.

`Expand-PinnedArchive` now deletes the intermediate `.tar` once its pass has
unpacked it. The gate is unchanged. The pinned EP tarball, checked on the host,
now unpacks with no `.tar` left and no file matching G2's archive rule.
`Rocm.Migraphx.Tests.ps1`: 58 pass.


## 2026-09-25 - The ORT AMDGPU EP's flatbuffers seed extracts despite 7-Zip's link refusals

With MIGraphX built (entry below), the EP stage stopped in phase 1:
`7z extraction of 'C:\temp\ort-amdgpu-ep-work\flatbuffers.zip' failed (exit 2):
Sub items Errors: 9`. The archive matched its pin. 7-Zip 25+ refuses every
symlink whose target climbs with `..`, even one that stays inside the tree, and
flatbuffers 25.12.19 carries nine: six Java test dirs, `ts/package.json`,
`ts/pnpm-lock.yaml` and a test `.npmrc`. Reproduced on the host with 7-Zip 26.03.
The other eight EP seeds extract cleanly, and no flatbuffers CMake file reads those
paths.

`Save-PinnedSource` now extracts through `Expand-PinnedArchive`. It runs the same
two 7-Zip passes as `Expand-SourceTarball`, but hands each pass to
`Get-SevenZipSkippedLink`. An exit 2 made only of those refusals is skipped with a
warning that names each link. Any other ERROR line, another exit code, or an exit 2
that names nothing still throws, now quoting 7-Zip's own ERROR lines. The links are
never written, so the refusal keeps its point. The fix lives in
`WindowsMigraphx.Common` because `WindowsSourceBuild.Common` is mounted into every
media layer; fold it in at the next deliberate media rebuild. Checked on the host
against the zip, a `.tar.gz`, a `.tar.xz` and a truncated zip (which still throws).
`Rocm.Migraphx.Tests.ps1`: 57 pass.


## 2026-09-25 - MIGraphX links with MLIR off: upstream's stubs, backported

With HIP compiling (entry below), the build reached `migraphx_gpu.dll` and stopped
at the link: `is_module_fusible`, `adjust_param_shapes`, `dump_mlir_to_file` and
`dump_mlir_to_mxr` were undefined. At `rocm-10.0`, `mlir.cpp` declares them for
every build but defines them only when `MIGRAPHX_MLIR` is set, and the rocm lane
builds MLIR off because TheRock ships no rocMLIR. Upstream fixed this on `develop`
in 5a80dc91ba (#5154, 2026-08-24), after the tag.

`windows/scripts/patches/migraphx/001-mlir-off-stubs.patch` carries that commit's
four definitions verbatim. Their signatures were checked against the pinned
`mlir.hpp`. Phase 1 git-inits the tarball and applies the patch with
`Invoke-SourcePatch`, and `Dockerfile.rocm-migraphx` mounts the directory.
`upstream-windows-patches.md` lists it as fixed upstream, to retire on a bump.

`Test-PatchesApplyClean.ps1` now maps `migraphx` to `MIGRAPHX_WINDOWS_COMMIT`.
That is a commit, and `git clone --branch` takes only names, so a 40-hex ref
clones through `--revision` (git 2.49 or later). A `-PatchRoot` holding a single
patch no longer dies on `.Count`. The whole catalogue passes, 20 of 20.
`Rocm.Migraphx.Tests.ps1` covers placement, the patch and the mount: 54 pass.


## 2026-09-25 - MIGraphX's HIP code compiles against MSVC 14.51's `<cmath>`

With the configure through, every HIP source in `migraphx_device` failed (114
errors): `__device__ function 'isgreater' cannot overload __host__ __device__
function 'isgreater'`, with the previous declaration at MSVC 14.51's
`cmath:688`, `_CLANG_BUILTIN2(isgreater)`. Under clang that `<cmath>` defines the
six two-argument comparisons as `constexpr` builtin wrappers. HIP makes those
`__host__ __device__`, so clang's HIP headers can no longer add their `__device__`
versions. Upstream MIGraphX's Windows GPU job avoids this by building with VS 2022
17.13.

The owner chose to keep the image's own clang/MSVC 14.51 toolchain. The first
try, `-Xclang -fno-cuda-host-device-constexpr`, cleared all 114 errors but broke
device code instead (`reference to __host__ function 'operator unsigned int'`,
`std::integral_constant` at `xtr1common:34`). It was dropped before any push.

`Write-HipMsvcCmathOverlay` now writes an `-isystem` directory ahead of clang's
resource dir. The wrapper includes both headers with `<>`, so the overlay reaches
them. Each overlay header renames those six names, `#include_next`s the untouched
original and restores them, so device code calls MSVC's builtin versions. No
TheRock file is copied or edited. The flag is inert for non-HIP sources, which
never include these headers. `Rocm.Migraphx.Tests.ps1` covers the overlay;
51 cases pass.


## 2026-09-25 - MIGraphX takes TheRock's nlohmann_json through a natvis shim

With its own rocm-cmake (entry below), MIGraphX got past
`rocm_add_version_resource`, then stopped at `src/CMakeLists.txt:389`:
`Cannot find source file: C:/TheRock/build/nlohmann_json.natvis`. TheRock's
nlohmann_json 3.12.0 was installed by an MSVC-style build. Its exported target
therefore lists `<prefix>/nlohmann_json.natvis`, a debugger visualizer, as an
interface source, and TheRock's dist does not carry that root-level file. It was
the only missing source.

`Write-NlohmannJsonConfigShim` writes a two-file package into the deps prefix:
- The config includes TheRock's own config by absolute path, then clears
  `INTERFACE_SOURCES` on `nlohmann_json::nlohmann_json`.
- The version file includes TheRock's.

`nlohmann_json_DIR` points at the shim. Headers, version and the staged licence
notice all stay TheRock's. `Rocm.Migraphx.Tests.ps1` covers the shim's content,
its refusal when TheRock lacks the package, and the new configure argument.


## 2026-09-25 - MIGraphX builds with its own rocm-cmake pin

The rocm chain got through LiteRT (1:17:33), TVM (2:55:07) and the media merge
(42:20), then stopped in `rocm-migraphx` at the MIGraphX configure:
`src/CMakeLists.txt:184: Unknown CMake command "rocm_add_version_resource"`.
MIGraphX `rocm-10.0` calls that function in five CMakeLists, and rocm-cmake added
it in 33541cd51f ("Add versioning for Windows", 2026-04-17). MIGraphX pins
`ROCm/rocm-cmake@6a7c5b73` in its own `requirements.txt` (6 commits past it). The
build took rocm-cmake from TheRock instead, and every TheRock tag points at
10155d7272, 4 commits before it.

Phase 2 of `Build-MigraphxFromSource.ps1` now does three things:
- It reads the commit from the pinned MIGraphX tree's `requirements.txt`
  (`Get-MigraphxRocmCmakeCommit`, which accepts only a 40-hex id).
- It fetches exactly that commit (`Save-GitCommitSource`). git verifies every
  object against the id and HEAD is re-read.
- It installs rocm-cmake into the deps prefix, which precedes TheRock on
  `CMAKE_PREFIX_PATH`.

MIGraphX does `find_package(ROCmCMakeBuildTools REQUIRED)`, so it now finds this
copy. The owner chose deriving it over a new `versions.env` pin: `versions.env` is
baked into `Dockerfile.base`, so a pin there would re-key the whole Windows chain,
while this change re-keys only the MIGraphX stage. It also makes a MIGraphX bump
carry its own rocm-cmake. `Rocm.Migraphx.Tests.ps1` covers the parse, both
refusals, the parameter guard, and where phase 2 stages it.
`docs/windows-rocm.md` § Supply chain records the exception.


## 2026-09-25 - `BACKLOG.md`: every known image gap, measured

The root `BACKLOG.md`, in the agentic loop's `- [ ]` / `- [b]` format, now lists
every gap in `:latest`, `:winamd64` and the `:winarm64` bundle that a consumer
hits or works around. There are CON7–CON33, grouped by image, each with its
evidence and what closes it. CON7–CON10 moved there from
`docs/refactoring-backlog.md`, which now points at it.

**Sources.** Nine consumers and this hub's own docs were swept for image notes and
workarounds. Each Linux candidate was then measured in `:latest` (`ec4bb68b`,
amd64, uid 1001, through the entrypoint). Windows and arm64 items cite runs and
hub documents.

**Found:**
- **CON14: a stale stage.** API 37 was added to source on 2026-09-18, but the
  image built on 2026-09-22 has no `ANDROID_EXTRA_*` ENV and only
  `platforms/android-36`.
- **CON17:** the image's clang has no libFuzzer runtime (`llvm-cross.sh:201`),
  which breaks WebDavClient's atheris build.
- **CON15:** LLVM 21 `clang-tidy`/`llvm-profdata`/`llvm-cov`/`ld.lld` sit first on
  PATH next to clang 23.
- **CON12:** the published `:winamd64` builds OpenCV/GenAI against an ONNX
  Runtime that is not the chain's.

**Closed by the measurement.** Eleven gaps that consumers still describe turned out
closed. Among them: `CARGO_HOME` ownership, rustup, wasm32,
`GSTREAMER_ROOT_ANDROID`, and a second ONNX Runtime in `/opt/opencv5/lib` that is
the chain build, byte for byte. `BACKLOG.md` lists all eleven so nobody files them
again. `docs/riscv64-rva23-baseline.md`'s pointer for the
TVM/IREE RVV codegen item now names CON24, and `docs/INDEX.md` lists the file.


## 2026-09-25 - The fleet calls this hub at `@develop`, not `@main`

Owner directive. Work lands on `develop`. `main` is a release branch that has
lagged it since 2026-09-16, and its `versions.env` still sets
`CI_IMAGE_LINUX_TAG=latest-cross`. The composite actions read that file at the ref
they were called at. So every consumer lane pulled `:latest-cross`, which no
release moves any more, and a Linux image fix such as CON7 would never have
reached one. Both tags are one GHCR version today, so nothing changes in what CI
runs until the next publish.

- **In the hub:** `prepare-windows-container-host` now calls its three sub-actions
  at `@develop`, and the reusable workflows call their 15 action references at
  `@develop`. `lint-gates.yml` checks the tooling out at `ref: develop`, and the
  consumer registry's hub entry now reads `develop`.
- **Docs and templates:** AGENTS.md's tag note, `.github/actions/README.md`, six
  docs pages and `shared/templates/AGENTS.md.template` now say `@develop`.
  `adopting-in-a-new-project.md` § 6 says why.
- **In the consumers:** 110 references across eight repositories move in their
  own commits.
- **What this means for `:latest-cross`:** it is deletable once it is a GHCR
  version of its own. `python-ci.md` notes that OrchestrANT and WebDavClient no
  longer wait for `main` before splitting their `amd64-arm64` workflow.


## 2026-09-24 - Backlog: four image gaps the consumer lanes hit (CON7–CON10)

`docs/refactoring-backlog.md` gains two arm64 GCC gaps and two Windows LLVM gaps. Each
cites the run that showed it and says what closes it. CON7 (no libsanitizer in the
arm64 GCC) is fixed in source by e2de5852 and waits only for a published image. CON8
(arm64 GCC configures cannot find libX11) comes with a hypothesis and the check that
decides it. CON9 (`clang_rt.profile`) and CON10 (clang-tidy) are the two components
the patched Windows LLVM does not build. No code changed.


## 2026-09-24 - ONNX Runtime GenAI is configured without its own tests (`ENABLE_TESTS=OFF`)

With FFmpeg fixed, the rocm chain got through OpenCV (25:36) and Hailo (8:09), then failed in
`media-core-built` at ONNX Runtime GenAI v0.15.2: `unit_tests.exe` would not link
(`undefined symbol: Generators::Log`, `Generators::g_log`, `SetLogBool`, `GetEnv`). GenAI
gates `test\` on its own `ENABLE_TESTS` option (default ON) and ignores the `BUILD_TESTING=OFF`
this script already passed. Its `unit_tests` links the shared `onnxruntime-genai` and uses
internals that DLL does not export. Only the CUDA variant, which every earlier chain run built,
compiles those sources into the test itself, so the rocm lane's CPU build was the first to hit
it. Nothing in the chain runs GenAI's tests, so `Build-OnnxGenaiFromSource.ps1` now passes
`-DENABLE_TESTS=OFF` on every lane. That also drops the CUDA kernel tests from the CUDA
lanes' build time. `SourceBuild.GenaiOrt.Tests.ps1` pins the flag, and its case fails with
the flag removed.


## 2026-09-24 - `lib/compiler-llvm-tools.sh`: the LLVM tools of the compiler that built a tree

BeschleunigerBallett's coverage lane failed with `error: no profile can be merged`: its
`build-coverage-llvm.sh` calls this hub's `coverage.sh`, which runs `llvm-profdata` and
`llvm-cov` by bare name, and PATH's copies are an older LLVM than the image's clang.
AccelerANTgine had hit and fixed the same thing locally (`compiler_llvm_tool` and
`use_compiler_llvm_tools` in its `scripts/linux/ci-common.sh`). With a second consumer
needing them, both functions move up unchanged into `linux/scripts/lib/compiler-llvm-tools.sh`.
`test-compiler-llvm-tools.sh` covers them with two fake LLVM installs (the tree's compiler,
and a different `clang++` first on PATH): 6 assertions. Three new mutations bite, family
`compiler-llvm-tools`. `docs/shared-script-libraries.md` lists the library and describes it.
The consumers switch to it with their next hub pin.


## 2026-09-24 - makedef hands llvm-nm its object list as @file: xargs died in the rocm lane's environment

The refusal below paid off on the first rerun. The rocm FFmpeg stage stopped at
`makedef: 'C:/llvm-patched/bin/llvm-nm.exe' listed no global symbol in 116 object(s)`, and
the captured stderr was not llvm-nm's at all:
`assertion "bc_ctl.arg_max >= LINE_MAX" failed: file "xargs.c", line 512`. Git for Windows'
xargs subtracts the whole environment block from the ~32 000-character command-line limit.
The rocm lane's environment is large enough (hundreds of version variables, among them
the long `TORCH_ROCM_*` wheel URLs) that nothing was left, so xargs aborted before it ran
llvm-nm. The amd64 lane's smaller environment stayed under the line, which is why the same
FFmpeg linked there four times. The previous `2>/dev/null` had turned the abort into an
empty export list.

`makedef` no longer uses xargs. It writes the object list, one per line, to
`<version script>.nm-objects` and runs `llvm-nm --defined-only -g @<that file>`, so no
command line carries the list. LLVM tools expand response files, and the real llvm-nm 23.1.0
read it and exported exactly the `av*` symbols from clang's COFF objects. Reproduced on this
host with Git for Windows' shell: past ~33 KB of environment, the xargs version fails
(`xargs: environment is too large for exec`) at 33, 41 and 50 KB, and the `@file` version
passes at all three. `test-ffmpeg-makedef.sh` asserts one llvm-nm run with one `@file`
argument and no object on its command line (19/19). The new
`ffmpeg-makedef.objects-by-response-file` mutation, which puts xargs back, bites.


## 2026-09-24 - FFmpeg's makedef refuses an empty export list and runs the compiler's own llvm-nm

The rocm chain (hub a943dd94) built base, the ROCm SDK layer, the patched toolchain and ONNX
Runtime, then failed FFmpeg n9.0.2's `make + install`: `swresample-7.dll` and `swscale-10.dll`
could not resolve a single libavutil symbol (`av_mallocz`, `av_log`, `av_channel_layout_*`).
`avutil-61.dll` had linked, but with an empty export list. The replacement
`windows/scripts/patches/ffmpeg/makedef` writes each DLL's `.def` from an `llvm-nm` dump.
It sent `llvm-nm`'s stderr to `/dev/null` and wrote `EXPORTS` with nothing under it
whenever the dump came back empty. Its own header records the same symptom from the
replacement before it. The same FFmpeg linked four times on the plain amd64 lane
(09-21, 09-22). The rocm lane adds AMF and Vulkan, and the FFmpeg script puts scoop's shims
first on the PATH its Git-bash `make` sees, so a bare `llvm-nm` is not necessarily the
compiler's.

- `makedef` keeps `llvm-nm`'s stderr in `<version script>.nm-errors`. It exits 1, naming the
  tool, the object count and that stderr, when the dump is empty or when no symbol matches
  the version script's globs. Nothing reaches the `.def` on either refusal.
- It runs `$LLVM_NM`, with bare `llvm-nm` only as the fallback. `Build-FfmpegFromSource.ps1`
  sets it on the clang-cl toolchain to the `llvm-nm.exe` beside the `clang-cl` that this
  PATH resolves (`Get-FfmpegLlvmNm`), and throws if there is none.

`linux/scripts/tests/test-ffmpeg-makedef.sh` drives `makedef` with a stub `llvm-nm` whose
"objects" are nm-format text, so it runs on any host. It passes 15/15 here, and 11/15 fail
against the old script, which ignored `LLVM_NM` and on a host with no `llvm-nm` wrote an empty
`EXPORTS` list: the rocm signature, reproduced. The four new mutations bite
(`ffmpeg-makedef.*`, a family declared in `gate-proofs.allow`). `SourceBuild.FfmpegRocm.Tests.ps1`
covers `Get-FfmpegLlvmNm`; its throw case fails when the throw is removed. Against real COFF
objects from clang 23.1.0 and its llvm-nm, in the Linux image, `makedef` exported exactly the
`av*` symbols and refused an nm that could not read them. What emptied the rocm dump is not
pinned yet: the next rocm run either links with the compiler's own `llvm-nm`, or stops at
`makedef` with that tool's own error.


## 2026-09-24 - The WebDAV client installs from its commit archive, not through git

BeschleunigerBallett's Windows lane (run 36020442781) died before its build, inside the
early WebDAV download. `uv pip install git+https://github.com/Kataglyphis/WebDavClient@<pin>`
makes uv run `git submodule update --recursive --init`. The pinned commit still carries
`ExternalLib/Kataglyphis-ContainerHub`, whose nested DocumANTation and LaTeX submodules
overflow Git for Windows' gitdir limit inside uv's cache: `fatal: '$GIT_DIR' too big`. A
shorter cache root cannot help, because the limit is on the gitdir chain.

Both halves now install
`kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/<pin>.tar.gz`:
the same commit's tree, with no git and no submodules. The package needs nothing from
them. The Windows half builds that string in one function, `Get-WebDavClientRequirement`,
which refuses anything but a full 40-character commit SHA. Its Pester cases pin the form
and the refusal (3/3). `webdav-download.sh` uses the same form. Checked on this host: an
archive install of the pinned commit into a fresh venv imports `WebDavClient`, which has
`download_all_files_iterative`.

`versions.env`'s comment above `WEBDAVCLIENT_REF` still says "installed from git". It
moves with the next change to that file, because any byte changed there rebuilds the
Windows chain from `Dockerfile.base`'s `COPY versions.env` onward.


## 2026-09-24 - The pre-commit hook checks the derived doc numbers when their inputs move

7482747c added two consumer-inventory mutations and left `docs/code-quality-tooling.md`
quoting 1332 entries. The hook said OK. CI's preflight then failed `test-doc-numbers.sh`,
and every `doc-numbers.*` mutation in all four shards reported a baseline that already
failed (run 36022089345). 2bba2833 fixed the digit. The hook now runs
`test-doc-numbers.sh` whenever `docs/scripts/mutations.json`, the hook itself,
`docs/code-quality-tooling.md`, `docs/cross-build-verification.md` or `AGENTS.md` is
staged, and it refuses the commit with the `--update` command to run. It does not run
when none of them is staged. The new block sits after the doc-duplication gate, so the
two hook spans the docs quote do not move. `test-precommit-hook.sh` gains the abort case
and the skip case (42 assertions), and three new mutations bite:
`pre-commit.doc-numbers-aborts`, `pre-commit.doc-numbers-trigger-names-the-manifest` and
`pre-commit.doc-numbers-only-when-an-input-moves`. The manifest now holds 1337 entries.


## 2026-09-24 - `Invoke-WithAsanOptions -Options ''` adds nothing instead of refusing to bind

`Invoke-WithRuntimePath` takes an optional `[string]$AsanOptions` and hands it to
`Invoke-WithAsanOptions`, whose `-Options` was a mandatory `[string]`. PowerShell refuses
an empty string there, so `Invoke-WithRuntimePath -AsanOptions ''` could never run.
AccelerANTgine's `Start-Windows.ps1` passes exactly that for its full-application runs, to
opt out of the test-binary defaults. Its Windows lane got past its container build for the
first time in weeks (run 36020001871) and then stopped at the CLI version check: `Cannot bind
argument to parameter 'Options' because it is an empty string`. `-Options` now takes
`[AllowEmptyString()]`, and an empty value runs the block with `ASAN_OPTIONS` exactly as the
caller had it: nothing prepended, not even a separator. `Testing.Asan.Tests.ps1` has both
shapes; both cases fail against the old module with that same message.


## 2026-09-24 - The consumer inventory counts a consumer's own modules as its own

`verify_consumer_inventory.py` failed its first run after the fleet renames (36019965353):
`OxidANT names a hub path that does not exist: scripts/windows/New-ReleaseArchive.ps1:18 ->
WindowsOrtPayload.Common.psm1`. That module is OxidANT's own, in `scripts/windows/modules/`,
where `Resolve-BuildModule` falls back to it. It dates from 2026-09-23 and is the first local
module whose name starts with `Windows`. The gate assumed every `Windows*` name was the hub's.
`dangling_modules` now skips a name the consumer tracks as a `.psm1` outside its test trees
(a fixture's `.psm1` exists to be absent and still counts as dangling).
`test-consumer-inventory.sh` covers both. Two new mutations,
`consumer-inventory.own-module-is-not-dangling` and `consumer-inventory.fixture-psm1-is-not-own`,
bite. Against the live fleet: CONSUMER INVENTORY OK, 0 dangling.


## 2026-09-24 - Workflow names follow the fleet convention; `arches` for the Python Linux lane

The owner set one naming rule for the workflows of every repository in the family:
kebab-case files, one file per platform and arch for a build, display names
`<Platform> <Arch> · <what>` (or `<Area> · <what>`). The hub goes first. The rule and
the fleet's rename table:
[`adopting-in-a-new-project.md` § Workflow file names and display names](adopting-in-a-new-project.md#workflow-file-names-and-display-names).

The consumer renames cleared most of the workflow-convention backlog, so
`workflow-conventions.allow` drops twelve CENSUS rows that now measure zero
(OmniAccelerANT, OxidANT and AccelerANTgine all three checks, jotrockenmitlocken
job-timeout and permissions, ANThology job-timeout) and lowers BeschleunigerBallett's
job-timeout 15 → 13 and permissions 12 → 11, each measured with
`verify_workflow_conventions.py` on the renamed tree. OrchestrANT keeps its 2 until its
Linux lane splits on `arches`. `test-workflow-lint.sh`'s ramp cases graded a fixture
named OxidANT against the REAL allow file, so they passed only while the real OxidANT
still had a backlog; they now carry their own census. `third_party/DocumANTation` moves
to `2e861fc`, its own rename (`docs.yml`, `linux-x64.yml`).

- **Renamed.** `ubuntu26.04.yml` → `linux-x64.yml` ("Linux x64 · preflight + mutation
  gate") and `windows-scripts.yml` → `windows-x64.yml` ("Windows x64 · script tests").
  Their concurrency groups follow the file (`linux-x64-…`, `windows-x64-…`), and
  `windows-x64.yml`'s path filter names itself. The README badge moved; a Windows x64
  badge is new.
- **Display names only.** `actions-selftest.yml` "Composite actions · self-test",
  `consumer-inventory.yml` "Consumers · inventory", `ghcr-cleanup.yml` "GHCR · cleanup",
  `llm-stack-serving.yml` "LLM stack · serving", `sbom.yml` "SBOM",
  `stale-docs-check.yml` "Docs · stale check" (its issue footer too; the issue is still
  found by its title).
- **The reusable workflows keep their FILE names**, because every consumer calls them
  at `@main`: `build-docs.yml` "Docs · build (reusable)", `lint-gates.yml` "Lint gates
  (reusable)", `python-ci-linux.yml` "Python CI · Linux (reusable)",
  `python-ci-windows.yml` "Python CI · Windows (reusable)", `submodule-pins.yml`
  "Submodule pins (reusable)". AGENTS.md now states that as a rule.
- **`python-ci-linux.yml` takes `arches`** (string, default `"x64 arm64"`), so
  OrchestrANT and WebDavClient can split into `linux-x64.yml` and `linux-arm64.yml`. The
  default runs both rows with the same job and artifact names as before. A new `plan`
  job builds the matrix and fails on an unknown, repeated or empty name; a static matrix
  cannot be filtered, because GitHub adds an excluded `include:` row back. Callers see
  one more check, `<job> / plan`.
  [`python-ci.md` § One arch per caller](python-ci.md#one-arch-per-caller-the-arches-input).
- **Tests.** New `tests/test-reusable-linux-lane.sh` (33 assertions) runs the plan step
  itself: the default rows equal the old static matrix, one name gives one row, the
  refusals fire, and no row uses a `*-latest` label. That last one is needed because
  the labels now sit in a `run:` block, which the workflow-convention gate cannot read.
  Seven new mutations in a new family, `linux-lane` (declared in `gate-proofs.allow`), each
  seen biting; the manifest goes 1325 -> 1332. The three `mutations.ci-*` entries and
  `test-mutation-gate.sh` point at `linux-x64.yml`. `code-dupes.allow` gains two rows
  for the new suite's preamble, the same row the Windows lane's suite has.
- **Fleet references.** Hub prose that names a consumer workflow uses the new name, with
  the old one beside it where the text is dated: the `consumers.json` notes, the CENSUS
  reasons in `workflow-conventions.allow` (counts unchanged), `shellcheck-warnings.allow`,
  `code-quality-tooling.md`, `shared-script-libraries.md`, `dependency-updates.md`,
  `cross-build-verification.md`, `New-Archive.ps1`'s header, and
  `github-cli-pipeline-monitoring.md` (now `gh run list --workflow linux-x64.yml`).
  `ftp-deploys.md`'s 2026-09-09 table keeps its old names and line numbers as a dated
  record and points at the rename table. Left alone on purpose:
  `02-toolchain/rust/cargo_fmt_clippy.sh` quotes `rust_ubuntu26_04.yml:134-139` as a
  dated citation, and that file sits in `Dockerfile.toolchain`'s
  `COPY linux/scripts/02-toolchain/`, so a comment edit would re-key the toolchain stage.
- **For the consumers.** A split that adds caller files without a top-level
  `permissions:` raises that repo's `permissions` count above its CENSUS row, and its
  lint lane fails; give each new file its own block. `arches` reaches a caller only once
  this is on hub `main`.
- **What re-keys:** nothing. No `versions.env`, `01-core`, Dockerfile or other
  image-closure file changed.


## 2026-09-24 - Hailo: review fixes

A review of the entry below found a check that could be skipped, an old-path guarantee
that no test held, and docs claims that went further than the evidence.
`HAILO_NESTED_CACHE` behaves as it did. Under `HAILO_PYHAILORT_IPO=off` the install is
stricter; `upstream` warns as it always did.
[`hailo-support.md` § pyhailort](hailo-support.md#pyhailort).

- **Under `off`, a failed install into `/opt/venv`, or no wheel at all, stops the
  build.** The installed-module check ran only inside `if uv pip install ...; then`, so a
  failed install only warned, the `RUN` stayed green, and an image could ship without
  pyhailort in `/opt/venv` while the docs called the check fatal. `install_pyhailort` now
  prints uv's own error and dies, naming `HAILO_PYHAILORT_IPO=upstream`, which keeps the
  old warning. `import hailo_platform` still only warns in both modes, and the gates
  table now says so. A run without `/opt/venv`, outside the image, still only stages the
  wheel.
- **Found on the way:** the `ls | head` that finds the wheel was unguarded under
  `pipefail`, so "no wheel" never reached its `return 0`: the build died with rc 2 and no
  message (shell-safety class 2). Guarded; no wheel is now an error under `off` and a
  warning under `upstream`.
- **The old nested build's `HOME` has a test.** The fake cmake recorded the `HOME` it ran
  with, and nothing read it. `off`, and `carry` without a launcher, now assert the
  caller's `HOME`, and `carry` the carrier. The carrier test's login file sets `PATH` and
  `SCCACHE_DIR` itself, which pins that the carrier's exports come after it.
- **Docs.** README and `failure-modes.md` tied a working pyhailort to a build date, but no
  image has this change yet, the arm64 import is untested, and an image built from
  `develop` that day still carries the stub. Both now name the switch and say the import
  only warns and is proven on amd64 only; `hailo-support.md` too. The Hailo `RUN`'s cache
  mounts are the chain's own on whichever arch `CROSS_BUILD_PLATFORM` names, so on the
  Jetson the old 10G cap could trim `sccache-arm64` too, not only `sccache-amd64` on the
  cross host: `build-cache-tiers.md` and the entry below are corrected. `hailo-support.md` § pyhailort
  now says the shipped module depends on floating `scikit-build-core>=0.10` and
  `pybind11>=2.13.6,<3` resolves from PyPI, which reach the image now that the module is
  real. Pinning them waits for the next planned `versions.env` re-key (an open question on
  that page). The entry below also gave `# noforward` as a reason for scikit-build-core,
  which was wrong: the Hailo `RUN` loads the image's `versions.env` and can read
  `PY_SCIKIT_BUILD_CORE_VERSION` today. Only pybind11 needs a new key.
- **`code-dupes.allow`:** two budgets go back up by one and two rows come back, all four
  as they were before 2026-09-20. `install_pyhailort` no longer holds the shingle
  `[ -n "S" ] || return N`, so the shingle falls from 7 owners to 6, under the idiom
  cutoff, and counts for those pairs again. No file in those pairs changed.
- **Tests.** `test-hailo-build.sh` 110 -> 139 assertions: the `HOME` each mode configures
  with, the login-file order, and `install_pyhailort` itself, run under `set -e` against a
  fake uv and a sandbox venv in both modes (installed, stub, failed install, failed import,
  no wheel, no venv). Six new mutations, each seen biting: `hailo.off-keeps-home`,
  `hailo.no-launcher-no-carrier`, `hailo.carrier-login-first`,
  `hailo.install-failure-fatal`, `hailo.install-no-wheel-fatal` and
  `hailo.install-no-wheel-guard`. All 36 `hailo.*` bite; the manifest goes 1252 -> 1258.
- **What re-keys:** the wrapper's Hailo `RUN` (`build-hailort.sh`), which the entry below
  already re-keys and no host has built yet. No `versions.env`, `01-core` or Dockerfile
  change.
- **Verified here:** on the Windows host, the suites that read the touched files (the two
  that fail, `test-version-snapshot` and `test-mutation-gate`, fail on the same assertions
  at the parent commit), all 36 `hailo.*` mutations, shellcheck and its warning ratchet,
  the hook's fast gates, the doc gates and the manifest's `--stale-check`. In the local
  amd64 image: `test-hailo-build.sh` as uid 1001 (139 passed) with the six new mutations
  biting there too, and `install_pyhailort` alone as root against the image's uv and
  `/opt/venv`, with a stub wheel, a truncated wheel and no wheel under both values, each
  with the exit code above. **Not verified:** a full `build-hailort.sh` run with these
  changes, and everything the entry below lists.


## 2026-09-24 - Hailo: the nested protobuf build is cached, pyhailort is a real module, the old build one switch away

arm64's Hailo `RUN` took 595 s in the 2026-09-22 lane, and 384 s of that was HailoRT's
configure: it builds a host protobuf (200 objects) under `env -i`, so the compiler cache
never reached it, while every other compile hit. The same diagnosis found that every image
shipped pyhailort as an empty module. Speedup item `hailo-arm64`, with its challenge's
corrections. **Owner decision: both options**, each default the fast or fixed path and the
old build one switch away.
[`hailo-support.md` § two switches](hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches).

- **`HAILO_NESTED_CACHE=carry|off`**, default `carry`. Only HailoRT's configure runs with
  `HOME` at a new directory in the `RUN`'s tmpfs. It mirrors the real `HOME`, and its
  `.bash_profile` runs the real login file, then exports every exported `SCCACHE_*` and
  `CCACHE_*` variable (not `versions.env`'s pins) and both CMake launchers, with the
  parent's own `sccache` and `ccache` first on `PATH`. `off` is the old uncached nested
  build. Measured natively on amd64: the configure took 9 s warm under `carry` and 32 s
  under `off`, and 243 requests reached the cache for the 200 nested objects.
- **Found on the way:** the clean `PATH` resolves the distro sccache 0.13 in `/bin` before
  the pinned 0.17. Its stats requests fail against the 0.17 server, and with no server
  running it starts a 0.13 one on the same socket. The carrier puts the parent's binaries
  first, so client and server are one binary.
- **The gate** (`hailo_assert_nested_cache_reached`). Under `carry` with a launcher it fails
  the build when the cache saw fewer requests than half the nested objects, or when the
  nested build left no `.ninja_log`; a spawner without the exact `env -i` line fails
  before the configure. Everything else warns. `USE_SCCACHE=0` keeps it armed on ccache;
  `USE_CCACHE=0` and `off` only warn. One `[CACHE] hailo/<phase>: secs= requests= hits=
  misses= launcher= cap=` line per phase: configure, build, pyhailort, libzmq, TAPPAS.
- **`HAILO_PYHAILORT_IPO=off|upstream`**, default `off`. Upstream forces IPO, and lld
  cannot link GCC's slim LTO objects, so every image carried a 4 KB `_pyhailort` without
  `PyInit__pyhailort`. `off` patches the forced IPO out of the cached source; the twelve
  sources compile at `compute_cpp_heavy_jobs` and cache; `hailo_check_pyext` checks the
  wheel's module and the installed one (ELF machine, a defined `PyInit__pyhailort`),
  fatal under `off` (a failed install too, since the review entry above), a warning under
  `upstream`, which rebuilds the old stub. Measured on amd64: a 1.7 MB module, and
  `import hailo_platform` works on Python 3.14.
- **Cache caps.** The Hailo `RUN` passes `Dockerfile.base`'s `SCCACHE_CACHE_SIZE=30G` and
  `CCACHE_MAXSIZE=30G`. The runtime image lost base's ENV, so `compiler-cache.sh`'s 10G
  applied there and trimmed the shared mount, which is the chain's own cache on the arch
  `CROSS_BUILD_PLATFORM` names: `sccache-amd64` on the cross host, `sccache-arm64` on the
  Jetson (corrected in the review entry above). The suite pins the pair to base.
- **Where the code is.** New `03-media/build/hailo/hailo-build-lib.sh` (the switches, the
  carrier, the counters, the gate, the IPO patch, the module check) and
  `probe-hailo-nested-cache.sh`, a seconds-long check inside an image: `off`, then `carry`
  cold and warm. `build-hailort.sh` routes its configure through the carrier and refuses a
  typo. `lib-orchestrator.sh` forwards both switches only when set and sources the lib;
  `build-cross-chain.sh` and both runtime orchestrators refuse a typo (exit 2) before
  they build anything.
- **Challenge corrections applied.** Both switches exist (the design had none for the cache
  fix, against the owner's rule); only exported variables are carried, so the unexported
  10G default never becomes a nested server's cap; the `HOME` redirect keeps the real
  `HOME`'s reads through the mirror; the gate follows the code's `USE_*` semantics; the
  cap scope is the build platform's arch, not only amd64 (the review entry above); the
  pybind build is capped; the twelve TUs are twelve.
- **Not done, and why.** The design's Unit 2: its stats fix is already in
  `compiler-cache.sh`, and moving the carrier into `01-core` would re-key the chain from
  the compiler stage. Unit 3, the opt-in cross fast path: the recorded `-EL` cross failure
  is not diagnosed, and the wrapper's final stage would need a restructure no BuildKit
  here could test. Pinning scikit-build-core and pybind11: `PY_PYBIND11_VERSION` is 3.x
  while pyhailort needs <3, so pybind11 needs a new `versions.env` key, which re-keys every
  stage from base; both are left for that re-key (the review entry above says why it now
  matters).
- **What re-keys:** per lane, the wrapper's Hailo `RUN` (`Dockerfile.torch` and the
  `hailo/` directory it COPYs) and the small `RUN` after it, which re-run on every lane
  anyway. No `versions.env`, `01-core` or other Dockerfile is touched, and the
  orchestrators and `lib-orchestrator.sh` are outside every image closure. The first run
  compiles the nested protobuf and the pybind11 sources cold, once.
- **Tests.** `tests/test-hailo-build.sh` (new, 110 assertions): the switches, the carrier
  through a real `env -i ... bash -l`, every variable `setup_ccache` exports, the configure
  wrapper against a fake cmake that spawns its nested build the same way, the gate's
  thresholds, the counters' anchoring, the IPO patch both ways, the module check on the
  shipped stub's symbol table, cap parity and the wiring. `t_stage_build_args` in
  `test-harness.sh` is now the one owner of the forwarding probe `test-web-lane-tools.sh`
  had, because `code-dupes` caught the second copy. 30 `hailo.*` mutations, all seen
  biting; `mutation-family:hailo` registered; `file-size.allow` +1 line for
  `build-cross-chain.sh`.
- **Verified here.** In the local amd64 image, as root with this tree's scripts at the
  image paths: `build-hailort.sh` end to end under `carry` cold and warm, `off`,
  `upstream` and `USE_SCCACHE=0` (every run exit 0, numbers in the doc), the probe as root
  and as uid 1001, and every suite as uid 1001 (the failures there are the baseline
  tree's too). On the Windows host: the touched suites, all 30 new mutations and the 25
  existing ones on touched files (11 of those in the image, where their suites run),
  shellcheck and its warning ratchet on every touched shell file, and the preflight gates.
  **Not verified:** arm64 under QEMU, where the saving is (estimated at 2.5 to 4 minutes per
  arm64 lane), the BuildKit `RUN` itself, the Jetson and the X100. The commands for the
  build host are in the doc.


## 2026-09-24 - The wrapper's wheelhouse: review fixes

A review of the entry below found that `RUNTIME_WHEELS_SOURCE=export` cannot run on
the cross host's `--no-push` chains, which that entry and the docs did not say, plus
three smaller gaps; rerunning its suites in the CI image found a fourth. No behaviour
changed: `image` and `export` do what they did.
[`linux-cross-builds.md` § The wrapper's wheelhouse](linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).

- **`export` is refused on a `--no-push` chain whose android tag is published**, which
  is every default or variant `--no-push` chain on the amd64 cross host. Such a chain
  threads no android pin, so `runtime_android_pin` resolves the published tag's
  registry digest, and this run's android layout never has it. The arch stops at the
  runtime lane, before its base build, with both digests named; the remedy is
  `RUNTIME_WHEELS_SOURCE=image`. `failure-modes.md` had suggested re-exporting the
  layout from the tag the lane names, which would have switched the package build to
  the published android as well; it now says never. Making `export` read this run's
  tag there would give up "the same image as `image` mode", so that is left to the
  owner. The same resolution means `image` mode on such a chain builds the venv from
  the PUBLISHED android's wheels while the package copies from this run's layout. That
  predates the knob and is unchanged; it is now documented and a test pins it.
- **The A/B runs through the chain.** The runtime lane's disk watch, whose mid-lane
  prune is the suspected eviction, runs only in `build-cross-chain.sh`, so the
  standalone `build-runtime-manifest.sh` A/B could not reproduce the wait. The primary
  A/B is now `CROSS_LOCAL_CONTEXT_HANDOFF=0 RUNTIME_WHEELS_SOURCE=<m>
  build-cross-chain.sh --only runtime --no-push`, and the standalone run is a
  mechanism check only. An arch counts only when its image-mode run shows the
  `wheels-source` extraction. The runtime lane writes no stage log, so the recipe
  greps the tee'd transcript, not a `runtime.log` that never existed.
- **Tests.** `test-runtime-wheels-source.sh` (91 -> 101 assertions) checks every
  `[runtime-timing]` step in both modes, and the published-tag `--no-push` case:
  `export` refuses whether or not the registry's copy was pulled, and `image` mounts
  the registry's digest. The shared nerdctl stub answers `image inspect` per ref. Two
  new mutations, both seen biting: `wheels-source.timed-steps` (unwrapping the
  wrapper step's timer used to survive) and `wheels-source.nopush-published-ref`.
- **Both wheels suites are hermetic.** In the CI image they failed 7 of 91 and 5 of
  21 assertions, at 736dea8a too: the image exports `ONNX_PACKAGE=onnxruntime` and
  `PYTORCH_EXTRA=pytorch-cpu`, which the wrapper forwards as operator pins.
  `rw_hermetic_env` (in `runtime-wheels-fixtures.sh`) now clears what the wrapper path
  and the fixtures read before any case sets its own; an exported `ENABLE_NVIDIA=true`,
  `RUNTIME_NO_CACHE=1` or `NERDCTL_BIN` no longer decides a case either. The
  dead-function census counts the new helper (508 -> 509 in `code-quality-tooling.md`).
- **Two stale hook-span references on this branch**, both fixed on `develop` already
  and repeated here verbatim so this commit could pass the hook:
  `cross-build-verification.md` quoted the staged-shell block as `:101-118` (it is
  `:102-119` since 57bec177), and the two `pre-commit.doc-span-*` mutations searched
  for the old spans (as 1b941556 did). The Windows-host floor fix for
  `verify_doc_links.py` came over from `develop`'s 5a1648d8 as its own commit, de8aed49.
- **What re-keys**, correcting the entry below: `Dockerfile.package` COPYs `01-core`
  whole (`:372`), so the package image re-keys from that COPY on, its setup RUNs and
  `wrapper-smoke` included. That is free on a full chain, where android changes
  anyway, and one package rebuild per arch on a runtime-only rerun with an unchanged
  android. This entry's own code edit is one comment in `01-core/runtime-build-fns.sh`
  (it said the pin is always empty under `--no-push`): the same re-key set as the
  entry below, and nothing more while no host has built that entry.
- **Verified here:** on the Windows host, both wheels suites (also under a hostile
  exported env), all 23 `wheels-source.*` mutations, the whole manifest's
  `--stale-check`, `build-cross-chain.sh --dry-run` of the new A/B command in both
  modes (it hands the lane `--skip-manifest` and no `--push`), and the helper's dry
  run showing `export` naming the registry digest; in the local `:latest-cross` image,
  the touched suites green. **Not verified:** no BuildKit ran, so neither the refusal
  against a real `nerdctl save` layout nor the chain-driven A/B has run.


## 2026-09-24 - The wrapper's wheelhouse: `RUNTIME_WHEELS_SOURCE=image|export`, image the default

In the 2026-09-22 lane the torch RUN waited 161 / 565 / 661 s (amd64 / arm64 /
riscv64) before `uv venv` wrote its first file; on 2026-09-21 it waited 96 / 1 / 2 s
with the same scripts. The likely cause: to bind-mount `/opt/wheels` (about 0.1 GB)
BuildKit must hold and checksum the whole android snapshot (about 12.7 GB), and pulls
it again when something evicted it after the package build. Inferred, not proven.
**Owner decision: both options**, the current one the default until a host lane
confirms the other. Speedup item `uv-wait`, with its challenge's corrections. How to
pick: [`linux-cross-builds.md` § The wrapper's wheelhouse](linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).

- **`RUNTIME_WHEELS_SOURCE=auto|image|export`**, default `auto` = `image`. `image` is
  the old delivery, byte for byte: the wrapper's argument vector is identical to the
  pre-change code over 32 combinations of pin, host infix, variant,
  `ARTIFACT_CONTEXT_ROOT` and GPU. `export` builds only `Dockerfile.torch`'s new
  `wheels-export` stage (`--output type=local`) before each arch's base and package
  builds. It copies `/opt/wheels` out of the image image mode would mount, seals it
  with a sha256 manifest, and the wrapper mounts that directory
  (`WHEELS_IMAGE=runtime_wheels`). Any other value exits 2, at the chain's start too.
- **Challenge corrections applied.** The export reads the ref image mode reads
  (`runtime_wheels_image_ref`, moved out of `append_wrapper_build_args`), not the
  package's `ARTIFACT_IMAGE`, so an empty pin, a custom prefix or
  `--artifact-build-mode native` cannot switch the source. Under `ARTIFACT_CONTEXT_ROOT`
  it reads the android OCI layout only when its digest equals the containerd image's,
  otherwise it stops (always, on a `--no-push` chain whose android tag is published:
  the review entry above). The staging root is minted in the main shell, so `--push-all`
  works. The wrapper re-checks the whole manifest; there is no fallback between
  modes. `image` needs no `ARTIFACT_CONTEXT_ROOT` refusal: it is the old code for both
  lane modes, so the design's separate `containerd` value is gone.
- **Diagnostics in both modes**: `[runtime-timing]` per step, `[wheels]` for the
  export, `[torch-run] start` as the torch RUN's first statement, `[torch-venv]
  wheelhouse` (a content digest equal to the host's) and `[torch-venv:timing]` after
  every `setup-torch-venv.sh` step. [The measurement recipe and the A/B](cross-build-verification.md#measuring-the-torch-runs-wait-before-uv-venv).
- **Where the code is.** `linux/scripts/lib-runtime-wheels.sh` (new, outside every
  image closure, loaded by `lib-orchestrator.sh`) holds the modes, the export, the
  seal and the arch loop both runtime orchestrators now run. `01-core/runtime-build-fns.sh`
  gains the resolver, the `image` arm, a two-way branch in `append_wrapper_build_args`
  and `_runtime_timed`: the wrapper's arguments are built there, so this part could
  not live elsewhere.
- **What re-keys.** `01-core` is mounted whole by `Dockerfile.toolchain`'s verify
  layer and COPY'd whole after it, so the next full chain rebuilds the compiler image
  from that layer on (its GCC and LLVM layers still hit), then sdk, media and android
  for every arch on warm compiler caches; the variant chains' `Dockerfile.nvidia` and
  `Dockerfile.amd` RUNs likewise. That rebuild is ALREADY due: the published
  `cross-compiler-amd64` dates from 2026-09-22 12:15Z, and 57bec177 and d8c31072
  (2026-09-23) changed `01-core` and `versions.env`, which re-keys from base. So this
  adds nothing to the next chain, if it lands before that chain. Per lane:
  `Dockerfile.torch` (the torch RUN, hailo and final) and `setup-torch-venv.sh`, which
  re-run every lane anyway. `Dockerfile.package` itself is untouched, but it COPYs
  `01-core` whole, so the package re-keys from that COPY on (the review entry above).
- **Tests.** `tests/test-runtime-wheels-source.sh` (new, 91 assertions, hermetic)
  shares `tests/runtime-wheels-fixtures.sh` with `test-runtime-wheels-context.sh`,
  which now extracts the moved helpers; `test-env-contract.sh` counts the lib as the
  knob's consumer. 21 `wheels-source.*` mutations, each seen biting;
  `mutation-family:wheels-source` registered. Two `code-dupes.allow` rows (the in-RUN
  digest twin, and a self-pair that shrank because of the new files) and one
  `file-size.allow` row (+2 lines in `build-cross-chain.sh`).
- **Verified here** (Windows host): the suites above, dry runs of
  `build-runtime-artifacts.sh` in both modes and with a typo, and the chain's typo
  refusal. **Not verified:** no BuildKit ran. The `wheels-export` build, the named
  directory context on the host's rootless OCI worker (0.31.2), the layout digest
  check against real `nerdctl save` output, and whether `export` removes the wait at
  all are for the host A/B in the recipe above.


## 2026-09-24 - A mutation-gate timeout on a Windows host is a verdict, not a crash

- **`verify_mutations.py`**: `_run_test` killed a timed-out test's tree with `os.killpg`,
  which a Windows python does not have, so the first slow test there ended the whole gate
  in an `AttributeError` with no verdicts (seen on the pre-push gate of 2026-09-24, on
  `test-web-lane-tools.sh` under parallel load). Without process groups it now runs
  `taskkill /T` on the shell's tree. On Linux nothing changes.
- **`test-mutation-gate.sh`**: the timeout case asserts the verdict and the absence of a
  traceback on every host; only its grandchild check stays POSIX-only. Measured on Git
  Bash: fails before the fix, passes after (98/98 with `MSYS=winsymlinks:nativestrict`,
  which the suite's symlink cases need there). No mutation entry: CI's Linux python has
  `os.killpg`, so a mutant of the Windows branch could not bite there.


## 2026-09-24 - The doc-links git-free floor works under a Windows python

- **`verify_doc_links.py`**: `_static_ignores` compared `str(path)` with the `/`-spelled
  `UNTRACKED_OUTPUT` rows, and a Windows python spells a relative path with `\`, so
  without git the floor excluded nothing there. It matches the POSIX form and still
  returns the caller's `str()`; on Linux nothing changes. `test-doc-links.sh` said so on
  a Windows host (`the floor skips 0 of 3 output paths`), which failed the commit hook
  whenever it sampled a doc-links entry there. That suite also needs a one-word
  `PREFLIGHT_PYTHON` (it quotes the value) and `PYTHONUTF8=1` on such a host.


## 2026-09-24 - ORT census: an ORT under another name is found by the entry point it defines

**Closes a G6 hole a review found.** Take an ORT with its fingerprints stripped,
rename it (`libhelper.so`), and give it an `$ORIGIN` RUNPATH beside the chain ORT.
The census called it an importer, modelled its `dlopen` onto the chain copy, and
passed it. OmniAccelerANT's packer gives exactly that RUNPATH to every ELF holding
`OrtGetApiBase`. The whole-path fingerprint (the earlier 2026-09-24 census entry)
had also widened the hole a little: an ORT whose source paths lost their NUL passed too, where it
was `STALE` before. Details:
[`onnxruntime-single-source.md` § An ORT under another name](onnxruntime-single-source.md#an-ort-under-another-name).

- **Rule:** a file that DEFINES `OrtGetApiBase` is an ORT instance under any name,
  graded by its bytes; with no fingerprint it is `UNPROVEN` ("an ORT under another
  name"). A consumer only imports it or `dlsym`s it.
- **Linux:** `elf_defines` in `ort_census_probe.py` looks the symbol up through
  `DT_GNU_HASH`, or `DT_HASH` when there is no GNU table, as `ld.so` does, and
  ignores an undefined (imported) entry. Such a BIN line ends in `def`, which
  `check-ort-provenance.sh` uses for the message.
- **Windows:** `Get-PeExportNames` is new in `WindowsTargetArch.Common`, beside
  `Get-PeImportNames`. Both now read the headers through one private
  `Read-PeLayout`, and the import results are unchanged on 87 real PEs. A
  forwarded export is left out, so a DLL that forwards `OrtGetApiBase` to
  `onnxruntime.dll` stays an importer. `WindowsOrtProvenance.Common` sets `Defines` on
  such a fact and makes it an instance.
- **Measured** in a local `:latest-cross` (e8eb8a42), with the image's chain ORT
  renamed and stripped two ways, beside the chain copy: the census before this
  change passed both, and this change gives `UNPROVEN` for both. Whole-image census: no verdict moved
  outside those scratch files. The 2026-09-17 OmniAccelerANT release bundle still
  passes. OmniAccelerANT's bundle-gate suites pass: 13/13 as committed, and 17/17
  for its liboxidant cases. On the Windows host, the three consumers' ORT suites
  pass against this hub.
- **Tests:**
  - `test-ort-census.sh` 122 → 132 assertions (a GNU- and a SysV-hashed
    definition is `UNPROVEN` and red, an import through either stays a green
    importer);
  - `Smoke.OrtCensus.Tests.ps1`: the loader table gains four rows (names the
    chain directory, the same with no ORT, exports `OrtGetApiBase`, forwards
    it), and the separate oxidant case folds into them (26 → 25 tests);
  - `TargetArch.PeInspection.Tests.ps1` 5 → 6 (kernel32's own exports versus its
    forwarders).
  6 new mutation entries (`ort-census.probe-defines*`, `-gnu-hash`, `-sysv-hash`,
  `ort-census.unproven-def`), each verified to bite. 5 Windows mutations were run
  by hand on scratch copies, and each bit.
- **Code-dupes budgets moved with it:** the Smoke suite's self-pair 17 → 26 (the
  export table pokes fields the way the PE header does), GenAI/G2 48 → 46, and the
  FFmpeg/rocm-Torch row is gone (below the threshold now). The two unchanged
  pairs moved because shingle-owner counts shift.
- **Not covered:** an ORT that is renamed, stripped AND rebuilt without the
  `OrtGetApiBase` export; archive members (name and fingerprint only).


## 2026-09-24 - riscv64 web-lane tools: `legacy` is the old build verbatim; review fixes

A review of the entry below found that `WEB_LANE_TOOLS_SOURCE=native` is not the
build riscv64 had before, as that entry and the docs claimed, and that no knob
combination reached it. How to pick a path:
[`consumer-image-contract.md` § Building the web-lane tools from source](consumer-image-contract.md#building-the-web-lane-tools-from-source).

- **`WEB_LANE_TOOLS_SOURCE=legacy`** (new): the package stage's pre-2026-09-23
  from-source leg, verbatim. `cargo install --locked <tool> --version <pin>` into
  `CARGO_HOME` (so cargo records it in `.crates.toml`), in the stage's own env: no
  forced C env, no gate, no cache, no provenance line, and a failed install only
  WARNs. It reads neither the cross artifact nor `WEB_LANE_TOOLS_CACHE`.
- **What `native` is, said plainly** in the contract, the knob table, AGENTS.md and
  the failure-mode entry: the package stage with rv64gc Rust, plus four differences
  from the old build. It forces vendored static C. It installs a bare binary, so a
  consumer's `cargo install <tool>` stops on `binary already exists` without
  `--force`, as it already does on amd64 and arm64. Its gate is fatal. It reads the
  cache first.
- **Every guard now has a test and a mutation.** Twelve new `rust.web-lane-*`
  entries: the producer's 30-minute `timeout` (a recording stub), `unset BUILDARCH
  BUILDPLATFORM` (an inherited `BUILDARCH=arm64` must still record `cross:amd64`),
  the "at least one GLIBC_ entry" refusal, a fatal empty `getconf`, a fatal failed
  `install`, the producer's sysroot GLIBC ceiling, the up-front knob check in
  `setup-package-image.sh` (a typo stops amd64 even when its prebuilt succeeds),
  both no-`rustc` branches and three for `legacy`. With no `rustc -V` release,
  `cross` is now an ERROR wherever an artifact was expected; a `skipped` arch still
  WARNs.
- **Both suites are hermetic.** `test-web-lane-tools.sh` took `TARGET_ARCH` from the
  caller: in the CI image (`TARGET_ARCH=amd64`) it failed 39 of 194 assertions, and
  an exported `WEB_LANE_TOOLS_SOURCE=native` failed 11. `_wlt` now clears the arch
  and Rust build env (the fixture arch is `WLT_T_ARCH`). `test-setup-package-image.sh`
  read the image's own `versions.env` and failed 3 there; its sandbox now clears
  that, the `*_SHA256` pins and the `WEB_LANE_TOOLS_*` switches.
- **What re-keys**, against the entry below: android's `web-lane-tools` producer RUN
  and package's setup RUN, per arch, because both bind-mount the edited library. No
  `versions.env`, `01-core` or other Dockerfile instruction changed; the
  `Dockerfile.package` edit is a comment.
- **Verified here:** both suites on the Windows host (the two JAVA_HOME symlink
  failures in `test-setup-package-image.sh` are host-only and predate this) and in
  the `:latest-cross` image with its own env, all green there; every mutation tied
  to either suite bites in that image. **Not verified:** no chain has run either
  entry. `legacy`'s command is the one the 2026-09-22 riscv64 chain ran, but no
  chain has reached it through the switch.


## 2026-09-24 - ORT census: a consumer that names the chain directory is not an ORT build

**Fixes G6 failing OmniAccelerANT's Linux lane** (run 35928030957, x64 and arm64):
`UNPROVEN /lib/liboxidant.so -- an ORT-named binary with no source fingerprint`. The
bundle was correct: it held the chain ORT, byte for byte. The census got the file
wrong. Details and measurements:
[`docs/onnxruntime-single-source.md` § What "the chain ORT" is](onnxruntime-single-source.md#what-the-chain-ort-is).

- **Cause 1: a directory string counted as a fingerprint.** OxidANT's loader keeps
  `/opt/onnxruntime/onnxruntime/core/` as a string to check the ORT it loads. The
  census treated any file holding `onnxruntime/core/` as an ORT build. Now a
  fingerprint is a whole source-file path ending in NUL (`.cc`, `.cpp`, `.cxx`, `.c`,
  `.h`, `.hpp`, `.inc`, `.cu`, `.cuh`), the shape `__FILE__` leaves. Changed in
  `ort_census_probe.py` (`MARK`) and in the Windows twin
  (`WindowsOrtProvenance.Common.psm1`, `$script:OrtPathMarker`), where `oxidant.dll`
  would have been `STALE`. `liboxidant.so` is now an importer, and G6 checks that it
  resolves to the chain ORT, which it used to skip. Every fingerprint of the chain ORT
  1.29 (592), its dnnl EP (23) and the Android build (545) still matches.
- **Cause 2: a relative root printed as "no fingerprint".** rustc packs string
  literals with no NUL between them, so the text before the directory became a
  relative root (`''`), which `emit()` prints as `-`. The probe now prints it as `.`,
  and `check-ort-provenance.sh` reads `.` as relative. A lone relative root is
  `FOREIGN` (relative), as on Windows, not `UNPROVEN`.
- **The same false positive hit G1 on FFmpeg.** FFmpeg compiles its configure line
  into every lib and tool, and the chain's passes
  `-I/usr/local/lib/onnxruntime-cpu/include/onnxruntime/core/session`
  (`ffmpeg-dnn-backends.sh`). The old rule made every FFmpeg ELF an ORT build with
  no fingerprint. Whole-image census of a local `:latest-cross` (e8eb8a42), old vs new
  probe: `UNPROVEN` 14 → 1 (10 FFmpeg ELFs and 3 scratch `liboxidant.so` copies gone).
  `libavfilter` is now the registered `ffmpeg` consumer it is, graded by RES and
  STAMP, and the other nine are not ORT at all. The runtime smoke's census
  (SHIPPED-TRUTH E) would have reported the same ten on the next image.
- **Stricter, on purpose:** a reference file whose roots are all relative is now
  `FOREIGN`, where `-` passed before. It matches Windows. e8eb8a42 has no such
  reference: its two unfingerprinted ones (`libonnxruntime_providers_shared.so`, the
  Android `libonnxruntime4j_jni.so`) still print `-` and pass as before. The CI image
  (ec4bb68b) was not available here to check.
- **Tests:** `test-ort-census.sh` 110 → 122 assertions (the fingerprint shape, a
  rustc-packed consumer passing beside the chain ORT, then failing with no ORT or a
  one-byte-off one, a relative-only ORT). 6 new mutation entries (`ort-census.probe-*`,
  `ort-census.relative-dot`), each verified. `Smoke.OrtCensus.Tests.ps1` 24 → 26.
- **Reproduced in a local `:latest-cross` (e8eb8a42)** with the REAL `liboxidant.so`
  built from OxidANT f018bec with the lane's features, inside the 2026-09-17 release
  bundle, through OmniAccelerANT's own packer and bundle checks. Hub a7ccc896 gives
  CI's line and `bundle closure: 1 failure(s) across 42 ELF file(s)`; this change
  gives `ORT census PASS`. Five mutations of that bundle (ORT removed, one byte off,
  foreign, no `$ORIGIN`, a renamed re-rooted ORT) each still fail.
- **Consumers pick it up with a hub pin bump, and their Windows ORT test fixtures
  need one edit.** OxidANT's loader does not change: the consumer rule is "name the
  chain directory, never embed a whole ORT source path". The rule is in `AGENTS.md`
  § Linux Build Rules and in the section 25 bullet of
  `docs/windows-build-invariants.md`. But a fixture that fakes an ORT as
  `"$chainSrc OrtGetApiBase"` has no fingerprint under the new rule. At this commit,
  OmniAccelerANT's `OrtRunner.Tests.ps1` fails 2 of 6, and OxidANT's
  `OrtPayload.Tests.ps1` and AccelerANTgine's `OrtBundle.Tests.ps1` fail one case
  each (`UNPROVEN` where `STALE` is expected). Ending the fake path with a NUL
  (`` "$chainSrc`0OrtGetApiBase" ``) fixes all three and passes at either hub:
  [`onnxruntime-single-source.md`](onnxruntime-single-source.md#what-the-chain-ort-is).
  (Corrected on 2026-09-24. This bullet first said nothing in the consumers changes.)


## 2026-09-24 - Review follow-ups to the sccache-endpoint fix

Six review findings on the entry below, each verified before it was applied.

- **A parent the run did not build is graded before a stage inherits it.** `FROM` copies the
  parent image's config ENV (the merge Dockerfile's comment said it does not; corrected). With
  the merge `built` stage's own ENV gone, a `bk-windows-toolchain` from before the fix passed
  its endpoint straight through to the published image, and only the final gate, hours later,
  would have seen it. `Invoke-BkStage` now solves `Dockerfile.publish-gate` on every
  `BASE_IMAGE` the run neither built nor graded, before the stage; a stale parent fails in
  seconds and the error says to rebuild it. The fresh toolchain is graded right after its
  solve. All three sites go through `Invoke-BkPublishGate`. **A run started before this commit
  has no gate: restart the chain with `toolchain` in `-Stages` from a fresh driver process;
  never resume it.** [`windows-build-resources.md` § An image this run did not build](windows-build-resources.md#an-image-this-run-did-not-build).
- **The Windows gate's default path is tested.** The gate's RUN passes no `-Scopes`, and no
  test did either. Now a uniquely named leaking Process variable must make a bare
  `Assert-ImageEnvPublishable` throw, the Process/Machine/User list is pinned from the AST, and
  an in-suite mutant for each proves it bites.
- **The Linux image-env gate has no switch.** Check 6 of `verify-shipped-wrapper.sh` sat
  inside the `RUNTIME_IMAGE_SMOKE=1` block and never ran on `--manifest-only`/`--repair`. It is
  now `_manifest_image_env_gate`, the first step of `create_manifest`, on every path that
  creates an index; check 6 is gone. The `make` help and four `image-env.manifest-*`
  mutations (replacing the two `image-env.wrapper-*`) follow.
- **The consumer probe tries every address at once.** `Test-TcpEndpointReachable` now
  resolves within the budget and connects to every address in parallel. Before, an IPv4-only
  listener behind `http://localhost:<port>` was removed after 2049 ms, because Windows refuses
  `::1` only after ~2 s; now it is kept in 37 ms. New cases: that one, a 200 ms bound against
  a closed port, and an unresolvable name, with an in-suite mutant per case.
- **The build host keeps its remote tier.** Consumer builds on the build host reached WebDAV
  only through the leaked ENV and would have lost it silently. `Invoke-ContainerBuild` now
  forwards this host's `SCCACHE_WEBDAV_ENDPOINT` and `SCCACHE_MULTILEVEL_CHAIN` into the
  container at run time (`Add-HostSccacheRemoteEnv`) unless `-CacheEnv` sets them (`''` opts
  out). A `docker run` by hand still passes `-e` itself:
  [`windows-build-resources.md` § The build host's remote tier, at run time](windows-build-resources.md#the-build-hosts-remote-tier-at-run-time).
- **Two things this host needed to commit it through the hook.** `verify_doc_links.py`'s git-free
  floor compared `str(path)` with POSIX entries, so on Windows it ignored nothing and
  `test-doc-links.sh` failed at baseline; it now matches the POSIX spelling (a no-op on Linux).
  And `build-cross-chain.sh`'s `_CHAIN_RUNTIME_GATES` does not name the new Linux gate yet:
  staging that file samples `test-chain-lifecycle.sh`, whose symlink cases fail on a Windows
  host, so that one-line edit is for a Linux host.
- **Re-key set: nothing beyond the entry below.** The driver, the tests and the Linux host
  scripts are in no image closure, the merge Dockerfile edit is a comment (no LLB change), and
  the two edited modules are copied only by the final `windows/Dockerfile`, which re-keys
  anyway. Base, the sdk slot and the toolchain are untouched. Linux: nothing re-keys.


## 2026-09-23 - The preflight timeout was a regression from 57bec177: fix11 is fast again, the mutation gate is sharded, and four hidden reds are fixed

**This was our regression.** On `a7ccc896` the Ubuntu 26.04 `preflight` job was killed
at its 45-minute timeout inside the mutation gate. `57bec177` had made fix11 run one awk
pass over its corpus per rule (~50 per gate run), and `test-critical-fixes.sh` ran the
whole gate once or twice per knocked-out row: the suite went from 4.4 s to 45-59 s on the
runner, and its 68 mutation entries each re-ran it (43% of the gate's serial cost). The
killed job printed nothing the gate had found, because the report was buffered.

- **fix11 judges its corpus in one awk pass.** The checks queue rules (`_f11_deny`,
  `_f11_require`, `_f11_pair`, `_f11_count`); `_f11_judge` answers them all, rules outside
  and lines inside, so gawk compiles each regex once. `_f11_env_writes` gives each of its
  seven forms its own `match()` site (gawk recompiled one shared site seven times per line:
  22 s of the runner's 32 s real-tree run). A pass that returns fewer verdicts than rules
  is a FAIL. Real tree, CI-parity container: gawk 10.1 s → 0.7 s.
- **`test-critical-fixes.sh`** builds the fixture once, `cp -a`s it per row, and runs only
  the knocked-out fix, extracted with `t_fn_src`; a case proves the extraction prints
  exactly what the gate prints, and the fix11 Cargo case still runs the real gate, so a
  FAIL is proven to reach its exit code (`critical-fixes.summary-reaches-exit`).
  52.5-64 s → 6.5-8.2 s (gawk, CI-parity container, paired runs). All 75 entries bite.
  The gate's serial cost, one lab session: 11469 s → 6633 s.
- **The mutation gate is its own CI job, in four shards.** `preflight` runs with
  `PREFLIGHT_SKIP=mutations`; the `mutations` job (matrix `shard: [0, 1, 2, 3]`, 30 min,
  same setup steps) runs `PREFLIGHT_ONLY=mutations PREFLIGHT_MUTATION_SHARD=K/4`, which
  preflight passes on as the new `verify_mutations.py --shard K/N` (`entries[K::N]`).
  Locally, `make preflight` still runs every entry.
- **`verify_mutations.py` streams.** Each verdict is printed, flushed and tagged `[j/J]`
  as its entry completes; a closing line names the failures in manifest order.
- **Four reds the timeout hid**, all from `e785e82d`/`57bec177`:
  `test-version-snapshot.sh` counted 11 `Build-*FromSource.ps1` subjects (13 since the
  MIGraphX and AMD GPU EP scripts); `cross-build-verification.md` cited the hook's
  staged-shell block as `:101-118` (now `:102-119`); `pre-commit.doc-span-fast-slugs` was
  stale; and `test-smoke-arch-parity.sh`'s sandbox lacked `check-ort-provenance.sh`, which
  `smoke-runtime-image.sh` now sources (39 assertions read empty). The 20 entries of the
  first two suites had been vacuous.

Docs: [`code-quality-tooling.md` § The mutation gate in CI, sharded](code-quality-tooling.md#the-mutation-gate-in-ci-sharded),
[`onnxruntime-single-source.md` § How G4 runs](onnxruntime-single-source.md#how-g4-runs-one-judging-pass).
Unverified until CI runs: the per-shard wall time on the runner (projected at about 10-16 of
its 30 minutes, slice 1 up to 4 more, scaled from `41a07927`'s measured CI gate time) and the
gawk real-tree time there.


## 2026-09-23 - riscv64 web-lane tools: cross-built in android, cached, native one switch away

riscv64's package stage compiled `wasm-pack` and `flutter_rust_bridge_codegen` under
QEMU on every chain: 960 s + 1,665 s of a 3,384 s RUN (riscv64 layer file times,
2026-09-22). **Owner decision: both options.** A cross build on the build host is
the default; the native build stays, one switch away. Speedup item `riscv-tools`,
with its challenge's corrections. How to pick a path:
[`consumer-image-contract.md` § Building the web-lane tools from source](consumer-image-contract.md#building-the-web-lane-tools-from-source).

- **Producer.** New stage `web-lane-tools` in `Dockerfile.android`, FROM
  `android-sdk`, i.e. before `final` swaps the amd64-hosted cross GCC out. It runs
  `06-packaging/web-lane-tools.sh produce`: `cargo install --target <triple>` under
  the hub's own `setup_linux_cross_env`, a 30-minute bound, vendored static C, its
  own cachemounts. It writes a manifest per tool. A failed cargo or gate records
  `status=failed` and android stays green. `final` COPYs the output as its LAST
  instruction, so a producer change re-keys nothing above it.
- **Package side.** `install_web_lane_toolchain` keeps the prebuilt-first path, so
  amd64 and arm64 install the same bytes as before. Its from-source leg is now
  `wlt_install_from_source`: the cross artifact or a gated native `cargo install
  --locked` in the package stage, chosen by `WEB_LANE_TOOLS_SOURCE=auto|cross|native`
  (default `auto`), through a version-keyed binary cache
  (`WEB_LANE_TOOLS_CACHE=on|refresh|off`). `legacy`, the old build verbatim, came
  a day later (2026-09-24 entry).
- **Fail loud on a claim.** Every from-source binary passes `wlt_assert_binary` on
  its staged bytes before install: ELF64, machine, lp64d, loader, a `NEEDED`
  allowlist, the image's GLIBC ceiling, `--version`. Artifacts and cache entries
  must also match their sha256. A binary that claims to be good and fails is fatal
  in every mode, and so is a bad knob or `cross` without an artifact. Availability
  misses still only WARN (`rust.web-lane-non-fatal`, retargeted to the new file).
- **Native hosts.** A build host whose arch is the target (the X100, a Jetson on
  `CROSS_BUILD_PLATFORM=linux/arm64`) gets `skipped: native-build-platform`, so
  `auto` builds natively there with nothing set.
- **Where it deviates from the design, and why.** The COPY sits after the GCC swap,
  not before it (the challenge: above the swap, every producer change re-ran a
  prefix-sized copy). The producer loads 01-core by explicit path from per-file
  mounts, never `source_module`, which would find `android-sdk`'s older copy.
  `cross` builds natively on a `skipped` manifest, so amd64 and arm64 do not turn a
  failed prebuilt download into an error. The native leg keeps the old build's
  rv64gc Rust, but not its command, its C env or its failure policy (corrected in
  the 2026-09-24 entry). The knobs are forwarded by `lib-orchestrator.sh`, not by
  new `versions.env` lines (Phase 2 of the design), and the library is bind-mounted
  into the setup RUN rather than COPYed, so no image gains a file. The producer
  keys on the rustc it actually runs, and its registry cache id is per target.
- **What re-keys on the next chain.** base, compiler, sdk and media: nothing. No
  `versions.env` or `01-core` edit, and `lib-orchestrator.sh` is in no Docker
  closure. android, per arch: the new producer vertex (seconds for amd64/arm64,
  which only write skip manifests; the cross compile for riscv64) and `final`'s new
  last layer; the five library stages and the GCC swap hit the cache. package, per
  arch: the setup RUN and what follows it, which re-run on every chain anyway. New
  cachemount ids: `web-lane-tools-cross-<target>`,
  `cargo-registry-web-lane-tools-<target>`, `web-lane-tools-bin-<arch>`.
- **Verified here:** `tests/test-web-lane-tools.sh` (new, off-target, stubbed
  readelf/cargo plus real-readelf cases), `tests/test-setup-package-image.sh`
  (now drives the real library), 30 new `rust.web-lane-*` mutations, the preflight
  gates. **Not verified:** no chain has run it. The producer has never run inside
  `android-sdk`; the design's probe ran the cross build in the amd64 runtime image
  with apt cross binutils. What to watch for on the first run is in
  `docs/build-watch-list.md`.


## 2026-09-23 - The arm64 and riscv64 GCC ship libsanitizer

**What was broken.** In the published `:latest` (index `ec4bb68b`), the arm64
(`b867d353`) and riscv64 (`66f4dea1`) images' `/opt/gcc-16.2.0` had no
`include/sanitizer/` and no `libasan`, `libubsan`, `liblsan` or `libtsan`. Any
`-fsanitize=address` build there failed with `fatal error:
sanitizer/common_interface_defs.h: No such file or directory`. It was found through
AccelerANTgine's `linux-debug-GNU` preset, where abseil's `dynamic_annotations.h`
includes that header. amd64 was not affected. Mechanism, gates and cost:
[`docs/cross-build-verification.md` § The native GCC ships libsanitizer](cross-build-verification.md#the-native-gcc-ships-libsanitizer).

- **Cause.** Those images' `cc` is the Canadian-native GCC (host == target), and
  `build-gcc.sh` built and installed only libgcc, libstdc++-v3 and libatomic for every
  `--target` build.
- **Fix.** `build-gcc.sh` adds `target-libsanitizer` to the make and install targets
  when `--host` equals `--target`. The plain cross compilers and the full-make host GCC
  are unchanged. No configure flag, `gcc.sh` or Dockerfile changed.
- **Gates.** `build-gcc.sh` fails when libsanitizer installed no header or `libasan`,
  because its configure can switch itself off silently. `swap-native-gcc.sh` checks the
  header and `libasan`/`libubsan`/`liblsan`/`libtsan` (plus `libhwasan` on amd64 and
  arm64), each with the image's ELF machine, on every build-host shape. The native
  Jetson and X100 lanes' own full-make GCC is checked too. The wrapper smoke compiles
  and links `-fsanitize=address,undefined` against the header and requires both
  runtimes in `NEEDED`. The runtime-image battery runs that binary only where the build
  host's arch is the image's, since qemu-user cannot host ASan/LSan reliably. Both
  smokes' TU shifts by a variable (`(8 >> c)`): GCC 16 defaults to C++20, which drops
  the shift-base check, and a TU with no UBSan call loses `libubsan` under
  `--as-needed`. New suite `test-native-gcc-sanitizers.sh`, which runs both smokes
  against a modelled GCC and executes the battery's container body; 23 mutations
  `native-gcc-san.*`.
- **What re-keys.** `build-gcc.sh` is in the compiler image's closure (Dockerfile.toolchain
  RUN 1, the LLVM RUN, RUN 3c and the `/opt/scripts/toolchain` COPY). The next Linux
  chain therefore rebuilds the one compiler image: the host GCC, both plain crosses,
  both Canadian natives (now with libsanitizer), then LLVM, Rust and CPython on the new
  digest. Every stage below it rebuilds on all three arches: sdk, media, android,
  runtime package, wrapper-smoke, wrapper and the manifest. Three more edits land in
  stages that re-run anyway on their new parents: `swap-native-gcc.sh` (the android
  final COPY), `validate-compilers.sh` (Dockerfile.package's artifact-source bind and
  its COPY) and `build-gcc.sh` again (Dockerfile.package's `02-toolchain/` COPY). Base
  is untouched. `smoke-runtime-image.sh` runs on the host and is in no image. The
  compile caches survive the re-key, because the sccache/ccache mounts are outside the
  image digest. The host and plain-cross GCC configure lines are unchanged, so their
  compiles should hit; the run's sccache stats will show whether they do. The nvidia
  and rocm variant images were never affected (their GCC is the build host's full
  make). Their chains re-key on the next run because they build on the new shared sdk,
  with no change in their GCC. Consumers that still pull `:latest-cross` through the
  hub's actions at `@main` keep the frozen image.
- **The next run must include the compiler stage.** On arm64 and riscv64 a partial
  rebuild on the old images now fails on purpose, instead of shipping without the
  runtime: a `--from-stage sdk|media|android` run on the old compiler digest stops at
  the android swap, and a `--from-stage runtime` run (or `build-runtime-artifacts.sh` /
  `build-runtime-manifest.sh`) on the published android images stops at the wrapper
  smoke with `COMPILER FAIL [gcc-sanitizers]`. No arm64 or riscv64 wrapper can be
  rebuilt from a partial stage until a chain from the compiler stage down has run.
  amd64 is unaffected.
- **Size.** About +79 MB uncompressed in the arm64 `/opt/gcc-16.2.0`, the size of
  amd64's set (79.3 MB, mostly unstripped `lib*san.a`). riscv64 has no hwasan, but its
  static archives are about 3x amd64's (`libstdc++.a` 171 MB against 55 MB), so expect
  roughly +190-200 MB there. The compiler, sdk, media and android images carry both
  native prefixes (roughly +270-280 MB), but those images are not shipped. None of this
  is measured on a built image; the compressed delta is not known.
- **Unverified until the Linux chain runs on the build host:** that libsanitizer
  configures and builds in the Canadian cross at all (libstdc++-v3 builds the same way,
  which is the main evidence it will); how much time the two libsanitizer builds add
  (not measured); the compressed size; and the sanitizer RUN on amd64. The arm64 and
  riscv64 RUNs happen only on a Jetson or X100 build host. TSan on riscv64 needs an
  sv39 or sv48 VMA, unverified on the X100. The static and stubbed tests ran on a
  Windows host. The suite also ran in a local amd64 `:latest-cross`, where the wrapper
  smoke compiled, linked and passed with the real GCC 16.2.0, and the smoke TU ran
  natively under ASan+UBSan.
- **Still missing on arm64 and riscv64, out of scope:** libgomp (`omp.h`), libitm and
  gfortran, and a target `libasan` for the amd64 image's plain cross compilers.


## 2026-09-23 - The published image no longer carries the build host's sccache endpoint

**What broke.** `:winamd64` (digest `3137eebe…`, built 2026-09-22 from hub `0d85b8c1`)
shipped `SCCACHE_WEBDAV_ENDPOINT=http://<webdav-lan-ip>:5000` — the owner's LAN WebDAV — plus
the build host's chain, force-local and cache settings, from the ENV blocks of four
Dockerfiles (`patched-llvm` from #164, media-builder's `common`, the merge `built` stage,
`rocm-migraphx`). The consumer wiring turns the sccache launchers on whenever sccache is on
PATH; on a GitHub runner sccache 0.18's server fails its storage check (`tcp connect error`)
and exits, every client times out after 10-12 s, and CMake calls clang-cl broken. That turned
AccelerANTgine and OmniAccelerANT red (runs 35921977157, 35912798986), and nobody could see
why, because `$null = Invoke-ContainerBuild` discarded the build's stdout. Account and table:
[`docs/windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries).

- **(1) ARGs, not ENV.** `SCCACHE_WEBDAV_ENDPOINT`, `SCCACHE_MULTILEVEL_CHAIN` and
  `SCCACHE_FORCE_LOCAL` are ARGs with no default, redeclared in every stage whose RUN
  compiles through sccache: `patched-llvm`; media-core-built-onnx/-ffmpeg/-opencv/-hailo,
  media-core-built, media-litert-built and media-tvm-built; the merge `built` stage;
  `rocm-migraphx`. An ARG does not cross a FROM, and the media-core chain crosses solves. The
  ENV blocks keep only the container-local runtime defaults (`SCCACHE_DIR`,
  `SCCACHE_CACHE_SIZE`, `SCCACHE_ERROR_LOG`, `SCCACHE_LOG`, `SCCACHE_IDLE_TIMEOUT`), with
  unchanged values. `Dockerfile.sccache-write-probe` follows (it ships nothing).
- **(2) Publish gates.** Windows: `windows/Dockerfile.publish-gate` + `WindowsImageEnv.Common.psm1`,
  solved by `Build-Buildkit.ps1` after the smoke gate and before `-FinalTar`/`-PushRef`, not
  skippable by `-SkipSmokeGate`; it grades the Process, Machine and User scopes. Linux: check 6
  of `verify-shipped-wrapper.sh` reads each wrapper's config ENV, hard even under
  `WRAPPER_CONTENT_GATE=0`. Static, both lanes: `linux/scripts/verify_image_env.py --dockerfile`
  as pass 0b of `lint-dockerfiles.sh`, which also refuses a compiling Windows RUN whose stage
  lacks the endpoint ARG. A leak is a build-host sccache name or an RFC1918/link-local address
  in a host position; `linux/scripts/tests/image-env-cases.json` grades the PowerShell and the
  Python matcher alike.
- **(3) Consumer defense for images already published.** `Enable-SccacheCompilerWrapper`, the
  choke point of `Initialize-BuildCacheEnvironment` and `Invoke-CmakeConfigureAndBuild`, now
  calls `Clear-UnreachableSccacheEndpoint` (exported): a 2 s TCP probe of the endpoint; if it
  fails, the variable (and a chain naming webdav) is removed for the process with one WARN, and
  sccache falls back to local disk. A reachable endpoint is untouched.
- **(4) Container output is visible.** Every unconsumed docker call in
  `WindowsContainerBuild.Reuse.psm1` ends in `| Out-Host` — the tar-pipe `docker exec`, the
  bind-mount `docker run`, the stale-cache cleanups, the output-directory probe and the source
  prune — so `$null = Invoke-ContainerBuild` no longer swallows the build. `$LASTEXITCODE` and
  the returned object are unchanged.
- **Re-key set.** Windows: the `patched-llvm` stage (so `bk-windows-toolchain`), every
  media-builder stage below `common` plus `buildmods`/`tvmmods`, the whole merge Dockerfile, and
  on the rocm lane `rocm-migraphx`; everything after them re-keys because its parent does
  (llama, torch, final; final also COPYs the modules dir). NOT re-keyed: `Dockerfile.base`, the
  sdk slot (CPU alias, `Dockerfile.nvidia`, `Dockerfile.rocm`) and the toolchain's `builder`
  and `built` (CPython) stages — no file they COPY or mount changed. Linux: no Dockerfile
  changed, nothing re-keys.
- **Not covered, recorded.** BuildKit writes a RUN's build args into the layer history, so the
  final image's history still names the endpoint; nothing reads it at run time. Backlog #177
  (a secret mount) owns it. Hostnames, loopback and files inside the image are out of the
  matchers' scope.
- **Tests.** Windows: `ImageEnv.PublishGate.Tests.ps1` (fixture parity, one in-suite mutant
  per rule, the driver's call order and two driver mutants), `Build.SccacheEndpointProbe.Tests.ps1`
  (closed and listening loopback ports, both wiring sites, one WARN, a mutant),
  `ContainerBuild.Output.Tests.ps1` (child-session visibility, an AST guard with two mutants)
  and a new case in `Modules.Orchestrators.Tests.ps1`. Linux: `test-image-env.sh` (a
  fake-nerdctl run of the wrapper gate included). Fifteen new `mutations.json` entries
  (`dockerfile-lint.image-env-*`, `image-env.*`), each proven to bite. Docs:
  `windows-build-resources.md`, `build-cache-tiers.md`, `windows-builds.md`,
  `windows-build-invariants.md` (49 rules now), `failure-modes.md`, `code-quality-tooling.md`,
  the #164 archive entry, backlog #177 and `AGENTS.md` § Push And Publish Rules.


## 2026-09-23 - Windows Scripts CI is green again: an unmounted CUDA root reads as absent, and the Hailo patches are checked

- **`WindowsSourceBuild.Cuda.psm1`.** `ad5b7d8f` (#176) built `Get-CudnnLibraryDir`'s and
  `Test-CudaWindowsArm64Payload`'s paths with `Join-Path`, which resolves the root's drive
  and throws `DriveNotFoundException` on an unmounted one; the contract (and the
  `SourceBuild.Resolve` `X:\` cases) is `$null` / `$false`. Every `lint-and-test` run
  since 2026-09-20 failed on it, on the runner and on any host without an `X:`. The paths
  are interpolated now; the rocm lane gate in `Get-GpuEnvironment` had the same latent
  shape and changes with them. The tests stay as the regression cases.
- **`Test-PatchesApplyClean.ps1`** maps `patches/hailo/` to `hailo-ai/hailort` at
  `v<HAILORT_VERSION>` (the tag `Build-HailortFromSource.ps1` downloads). Without it the
  four Hailo patches failed `patch-drift` unchecked since `da14e043`; all four apply
  cleanly at v5.4.0.


## 2026-09-23 - ONNX Runtime has one source: the chain

**Owner rule: every component that compiles against, links or loads ONNX Runtime uses
the ORT this repo builds from source**, on both lanes and in the consumer repos. No
NuGet, PyPI, release-zip, apt, bundled or pyke copy, and no exceptions; a plugin EP
counts as ORT. Every consumer, the six guards and what each cannot see:
[`docs/onnxruntime-single-source.md`](onnxruntime-single-source.md) (new). The rule
itself: `docs/windows-build-invariants.md` (48 rules now) and `AGENTS.md` § Linux Build
Rules.

- **What was broken.** Windows OpenCV downloaded `onnxruntime-win-x64-1.25.1.zip` at
  configure time (arm64 zip on the cross lane) and linked it, unpinned. Windows GenAI
  compiled against NuGet `Microsoft.ML.OnnxRuntime.DirectML` 1.24.4 from a feed, unhashed.
  The rocm venv carried PyPI `onnxruntime-ep-webgpu`. Neither the OpenCV nor the GenAI
  download showed in the shipped image. Correction to the 2026-09-23 `-Variant rocm`
  sdk-slot entry below: its "Found, not fixed (every lane)" OpenCV line was true of the
  Windows lanes only; Linux pre-set `HAVE_ONNXRUNTIME` all along.
- **Windows OpenCV** (every lane): a nested-header shim over the chain ORT,
  `-DHAVE_ONNXRUNTIME=ON`, both CMake packages disabled, and a configure gate. G-API's
  DirectML EP is compiled in for the first time, delay-loading dxcore/d3d12/dxgi/DirectML
  through an OpenCV CMake hook. dnn and G-API now need `onnxruntime.dll` 1.30 or later.
- **Windows GenAI**: an `ORT_HOME` shim; the `ortlib`/`onnxruntime` FetchContent names point
  at an empty dir, so a fallback fails configure. Configure and tree gates; the configure
  log is kept. `DirectML.h`/`D3D12Core.dll` and a DXC restore are still unhashed NuGet
  fetches (not ORT), recorded as follow-ups.
- **WebGPU EP**: the rocm spike builds ORT's in-tree WebGPU EP (Dawn on D3D12) into the
  chain `onnxruntime.dll`, with a pinned DXC release beside it. The PyPI plugin and its
  `TORCH_ROCM_WINDOWS_ORT_EP_WEBGPU_*` pins are gone; five `ORT_WEBGPU_WINDOWS_*` pins are
  new. `-NoRocmSpikes` builds without it.
- **G2, the build gate + stamp**: `Assert-ChainOrtOnly` (`WindowsOrtProvenance.Build.psm1`)
  and `ort_assert_chain_only` (`linux/scripts/03-media/ort-provenance.sh`) end every
  consumer build: OpenCV, GenAI, FFmpeg, GStreamer, and the AMD GPU EP. They grade the
  tree, fetch caches, build records and logs, and a pass writes the stamp G1 requires.
  Placed outside the census module and `03-media/core/`, per-file mounted, for the cache.
- **G1, the ORT census on the shipped image**: Windows smoke section 25; Linux
  SHIPPED-TRUTH E (`check-ort-provenance.sh`, `ort_census_probe.py`). Byte identity with
  the image's own chain ORT, the loader order per importer, the consumer contract, stamps.
- **G3**: both final images set `ORT_LIB_LOCATION`, `ORT_PREFER_DYNAMIC_LINK=1`,
  `ORT_SKIP_DOWNLOAD=1` and `ORT_DYLIB_PATH`, so an `ort-sys` build there cannot fetch
  pyke's ORT. Asserted by section 19 and the new contract row `ort-crate-env`.
- **G4**: `verify-critical-fixes.sh` fix11, a static denylist over both lanes' scripts,
  plus the G1/G2/G3 wiring. **G6**: `Test-OrtProvenanceTree` / `check-ort-provenance.sh
  <dir>` for consumer bundles.
- **App venv**: one census, `ort-venv-census.py`, purges by name pattern and package
  ownership (no fixed lists) and fails the torch stage unless every ORT distribution is a
  chain wheel byte for byte. A missing Linux chain wheel is fatal (it used to fall back to
  PyPI 1.27.0). Smoke section 21 adds DirectML and chain-wheel checks on every amd64 lane
  (floor 2 → 4). The nvidia smoke counts any GenAI flavour as the GenAI. The Windows app
  `uv sync` no longer installs the lock's PyPI ORT and GenAI before the purge: each
  `onnxruntime*` name in `uv.lock` is `--no-install-package`, and one without a chain
  wheel of its family stops the stage.
- **Consumer CI venvs** (`python-ci-*`): inside our images, `uv_sync_project` /
  `Sync-UvProjectDependencies` reconcile onto the chain wheels and fail unless the census
  and an import prove it. Linux gains `ORT_CHAIN_WHEEL_DIR=/opt/onnxruntime-wheels`.
  Owner decision: the 3.13 legs go (the chain wheels are cp314, the images carry 3.14
  only). `ci_tests.sh` `PY_VERSIONS` and `ci_build_docs.sh` `COVERAGE_VERSION` default to
  3.14 and OrchestrANT drops its 3.13 legs. WebDavClient (no ORT) needs
  `docs-python-version: '3.13'` in its workflow no later than the commit that moves its hub
  pin past this, or its docs job syncs atheris on 3.14 and fails. The Windows image COPYs
  the census to `C:\temp\scripts\`, beside its module copy, which failed every sync without it.
- **Linux**: a missing chain ORT stops OpenCV (no more silent build without it); dnn's
  copies in `/opt/opencv5/lib` become links to the chain; `000-onnxruntime.conf`; FFmpeg's
  chain `-L` goes first, a chain its probe cannot link stops FFmpeg (it used to skip the
  backend), and a link gate reads `config.mak`; a gate over the gst `onnx` plugin's
  `build.ninja`; apt ORT denied in code, by an apt-plan gate and a dpkg gate. The chain
  wheel manifest G1 reads follows the wheel through `repair-wheels.sh`'s cross strip and
  retag, and a twin of its name stops the stage. G2's default fetch caches match Windows
  (pyke, pip, uv, NuGet) plus cargo and the FFmpeg SDK cache; uv counts only wheels it
  downloaded, since its mount keeps old chain wheels. GenAI's G2 RUN mounts its build's caches.
- **Hub consumer API**: `WindowsOnnx.Common` refuses NuGet ORT, `Get-OnnxPackageLayout`
  throws, `Get-OnnxChainLayout` is new, and `WindowsMediaRuntime.Common` stages the chain only.
- **Consumer repos** (working trees; gitlinks not moved): OxidANT drops
  `download-binaries` for `load-dynamic`, loads only fingerprinted chain files, gates its
  lock, and ships the chain DLLs in its zip/MSIX/MSI; AccelerANTgine's CMake requires the
  fingerprinted chain prefix; OmniAccelerANT stages and stamps the chain ORT beside its
  runner, refuses anything else at launch, and drops the System32 fallback.
- **No in-box ORT in the images, now asserted.** A one-`RUN` probe over `bk-windows-base`
  (servercore:ltsc2025, OS 26100.33438) found no `onnxruntime*`, Windows ML or DirectML
  DLL anywhere on `C:\`. Smoke § 25 gains `ORT in-box` on every amd64 lane (verdict
  `INBOX`, floor 4 → 5; the cross lane skips it), and no exemption can waive an in-box path.
  A base that ships one keeps the previous `WINDOWS_BASE_DIGEST`: app-local chain copies
  cannot clear the census today, and fix11 refuses a script line that deletes or patches
  an in-box ORT under `C:\Windows`.
- **Re-keys: the full chain, on both lanes.** `versions.env` changed. Windows imports it
  in `Dockerfile.base`'s last layers, so every stage after base rebuilds on every lane.
  Linux mounts it into its base, so everything after base rebuilds on every arch. The
  script edits alone would re-key most of the Linux media build too: `Dockerfile.media`
  mounts `01-core` (`python_uv.sh` changed) whole into most of its RUNs, and the
  `onnxruntime` script dir (`60-build-genai.sh` changed) whole into the GPU ORT, GenAI,
  wasm and js/pkgconfig RUNs. Images built before this fail the STAMP check until rebuilt.
- **Not proven by a build.** Nothing but that probe ran in a container. Likeliest first
  reds, all fail-closed: GenAI and G-API's DirectML EP against the 1.30 headers under
  clang-cl; Dawn under clang-cl; a Linux package depending on `libonnxruntime1.x`; a G2
  false positive on a real record path.


## 2026-09-23 - Windows rocm lane: remaining AMD GPU paths

**The rocm lane fills its AMD GPU gaps: OpenCL, Vulkan, FFmpeg Vulkan, llama.cpp Vulkan,
gfx1200 and LiteRT, and the TVM ROCm spike builds again.** All of it is gated on
`HasRocm`; cpu and nvidia keep their flags. Details: [`docs/windows-rocm.md`](windows-rocm.md).

- **TVM ROCm spike.** It had failed the whole media-tvm RUN (IREE included): the
  minimal-LLVM branch never ran on amd64, because the patched toolchain LLVM
  (`AArch64;X86`) is always on PATH. `Get-TvmLlvmChoice` now treats a PATH llvm-config
  without AMDGPU as absent on the spike and builds `X86;AArch64;NVPTX;AMDGPU`.
  `ROCM-FEATURES.txt` records the read-back target list, and `TVM.ps1` compares it with
  what TVM links (`amdgpu`, or `amdgcn` before LLVM 23).
- **OpenCL ICD.** `Install-Rocm.ps1` registers TheRock's `amdocl64.dll` under
  `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`. Before, nothing did, and the loader found no
  platform.
- **Vulkan loader.** New `Install-VulkanLoader.ps1` puts LunarG's signed `vulkan-1.dll`
  into System32 (FFmpeg's `dlopen` and Python never read PATH), with the pinned copy and
  its licence in `C:\vulkan-loader`. New pin `VULKAN_RT_WINDOWS_ZIP_SHA256`, refreshed by
  `spec_vulkan`. New smoke `rocm-checks/GpuLoaders.ps1`; amfcodec is now load-probed.
- **FFmpeg** gets `--enable-vulkan` against the SDK's headers and glslc: the vulkan
  hwdevice, 9 hwaccels, 5 encoders, 18 filters, swscale's SPIR-V backend. A 35-symbol
  `config.mak` gate and new smoke listings. libplacebo stays off.
- **llama.cpp Vulkan.** The same build's official Vulkan zip in
  `C:\runtime\opt\llama.cpp-vulkan`, its own layer, off PATH. `Install-LlamaCppHip.ps1`
  is now `Install-LlamaCpp.ps1 -Backend hip|vulkan`, and `LlamaCpp.ps1` grades both. New
  pin `LLAMA_CPP_VULKAN_SHA256`; the bump spec takes the newest build with both zips.
- **Torch venv.** Device wheels for gfx1200 next to gfx1201 (six new pins), and a gate that
  refuses a rocBLAS GPU without device pins. `ai-edge-litert` 2.2.0 with its WebGPU
  accelerator. The PyPI WebGPU plugin EP added here the same morning was replaced by the
  chain's own WebGPU EP (entry above).
- **Licences.** `deps.json` rows for the Vulkan loader, the llama.cpp Vulkan build (libomp
  in both zips), `ai-edge-litert`, and gfx1200 in the PyTorch row.
- **Re-keys: the full chain, on both lanes.** The new pins live in `versions.env`, which
  Windows imports in `Dockerfile.base`'s last layers and Linux mounts into its base. So
  every Windows stage after base rebuilds on every lane, and every Linux stage after base
  on every arch. cpu/nvidia output is unchanged. The media-tvm script edit alone would
  re-key that RUN on every lane (the script is bind-mounted).
- **Nothing here ran in a container or on a GPU.** Likeliest first breaks: AMD's PAL
  initialising in a GPU-less Server Core (every OpenCV T-API check now loads it); the
  AMDGPU minimal LLVM's time and memory; FFmpeg's Vulkan sources under clang-cl. Windows
  Defender flags `llama-gguf-split.exe` as `Wacatac.B!ml` on this host.


## 2026-09-23 - Windows `-Variant rocm`: the ROCm layer moves into the sdk slot, and media turns on AMD GPU features

**The ROCm layer now sits where `Dockerfile.nvidia` sits** (owner directive), so toolchain
and media build on `GPU_TYPE=rocm`: base → sdk=rocm → toolchain → media → migraphx → llama
→ torch → final. This supersedes the 2026-09-22 "forks after media" entry. Every feature is
gated on the new `(Get-GpuEnvironment).HasRocm`; the cpu and nvidia lanes keep their flags
and outputs, locked by tests in every touched suite. What each component enables, with
evidence: [`docs/windows-rocm.md`](windows-rocm.md).

- **Driver.** Every rocm tag after `bk-windows-base` carries a `-rocm` infix
  (`bk-windows-sdk-rocm` … `bk-winamd64-rocm`), so a rocm run never overwrites a default
  image (golden test for cpu/nvidia on amd64 and arm64). New rocm-only stages `migraphx` and
  `llama`; `-Stages rocm` is refused. New `-NoRocmSpikes` (drops migraphx, passes
  `TVM_ROCM=0`). `TVM_ROCM` and `TORCH_ROCM` + pins go to the rocm lane only
  (`Get-BkRocmStageArg`), also through the `-ConcurrentAux` children. A rocm `-Stages` list
  with a gap in the post-media chain is refused as a stale parent (backlog #39).
  `Dockerfile.rocm` gets a 45 GB disk floor. `bk-windows-rocm` is orphaned: remove it by hand.
- **Contract.** `Get-GpuEnvironment` returns `HasRocm`/`RocmRoot` and throws on
  `GPU_TYPE=rocm` without `lib\cmake\hip` (the rocm twin of #45). `Invoke-CmakeConfigure`
  appends `-DCMAKE_IGNORE_PREFIX_PATH=<ROCm tree>` on the rocm lane so TheRock's
  flatbuffers/nlohmann_json/zlib never reach a non-HIP build; HIP consumers pass
  `-AllowRocmPrefix`. Meson (GStreamer), Bazel (LiteRT-LM), FFmpeg and TVM scrub the tree
  themselves and prove it with a post-configure gate. HIP device code compiles only with
  TheRock's clang++ by absolute path.
- **Media, rocm lane only.**
  - GStreamer: `hip`, `amfcodec`, `d3d11`, `d3d12` pinned `enabled` (meson `auto` already
    built them everywhere).
  - FFmpeg: AMD AMF (`--enable-amf`, header-only `AMF_HEADERS_*` pin): h264/hevc/av1 encoders,
    h264/hevc/av1/vp9 decoders, vpp/sr/frc filters, `amf` hwdevice. A generic H.264/HEVC
    encoder lookup now resolves to `*_amf` on this lane.
  - OpenCV: OpenCL T-API was already on everywhere; the clBLAS/clFFT probes are pinned off and
    a configure gate proves no ROCm leak.
  - IREE: HIP HAL driver and `rocm` compiler target, with a carried patch so the driver finds
    `amdhip64_7.dll`; `IREE_ROCM_DEVICE_BC_SHA256` mirrors IREE's bitcode pin.
  - TVM: OpenCL runtime; ROCm codegen + runtime as a spike. Fixed on the way: TVM's
    `find_rocm` read `ROCM_PATH` even with `USE_ROCM=OFF`.
  - LiteRT-LM: GPU backend (WebGPU over Dawn on D3D12) with four `LITERT_LM_*_SHA256` pins.
- **New rocm stages.** `Dockerfile.rocm-llama` installs llama.cpp's official Windows ROCm
  build b11115 (SHA256-pinned, off PATH, `LLAMA_CPP_HIP_HOME`). `Dockerfile.rocm-migraphx`
  (spike) builds MIGraphX 2.17.0 from source (`MLIR=OFF`, a configuration no upstream CI
  builds) and AMD's ORT plugin EP `migraphx-ep.dll`; all 17 archives SHA256-pinned, the EP's
  hash-less FetchContent pre-seeded and disconnected.
- **Torch.** `Dockerfile.torch` ends `FROM rocm-${TORCH_ROCM}`: cpu/nvidia build the
  unchanged `app` stage; the rocm lane installs torch 2.13.0+rocm10.0.0 and torchvision
  0.28.0+rocm10.0.0 offline from 10 URL+SHA256 pins (`Install-TorchRocm.ps1`).
- **ONNX Runtime** stays CPU + DirectML; the dead `onnxruntime_USE_ROCM` branch is gone.
- **Smoke.** `Test-RocmImage.ps1` runs every `windows/scripts/build/rocm-checks/*.ps1`
  (GStreamer, FFmpeg, OpenCV, IREE, TVM, LiteRtLm, Torch, LlamaCpp, MIGraphX), all GPU-less.
- **Test harness.** `Get-GpuEnvironment` rocm cases and `Get-CMakeRocmIsolationArgs` in
  `SourceBuild.Resolve`; new suites per component, each mutation-checked.
- **Licences.** `deps.json` gains TheRock, the AMF headers, the AMD PyTorch wheels, the
  llama.cpp and MIGraphX/EP closures and the LiteRT-LM GPU payload. The HIP/OpenCL runtime
  has no licence file: a public push of `:winamd64-rocm` is an owner decision.
- **Cost.** The touched modules and scripts are bind-mounted into the toolchain and media
  RUNs, so every lane rebuilds patched LLVM and media once with unchanged flags.
- **Found, not fixed (every lane, owner decision):** OpenCV's dnn module downloads
  `onnxruntime-win-x64-1.25.1.zip` unpinned at configure time; LiteRT-LM is cloned by tag.
- **Nothing here has been seen running on a GPU yet**; see the open points in
  `docs/windows-rocm.md`.


## 2026-09-23 - CUDA_ARCHITECTURES: Hopper (90) retired too

Same day, same owner, one entry lighter: `86;87;89;120`. 90 (H100/H200) joins
80 (A100/A30) on the commented line in `versions.env`; re-adding either is
inserting the number in ascending order. The CUDA compile now runs four cubins
per source file instead of five, and the image supports exactly the hardware
the owner has: RTX 30xx/A10/A40, Jetson Orin, Ada, and RTX 50 / RTX PRO
Blackwell. The absence stays a HARD edge -- no PTX, so an H100 would fail at
session creation, which is why both retired numbers are documented rather than
deleted.


## 2026-09-23 - CUDA_ARCHITECTURES: 80 retired, Blackwell (120) added

Owner decision. The set is now `86;87;89;90;120` — RTX 30xx/A10/A40, Jetson
Orin, Ada, Hopper, and GeForce RTX 50 / RTX PRO Blackwell. 80 (Ampere GA100)
is retired and kept as a commented line in `versions.env`, because its absence
is a HARD edge: ORT embeds no PTX, so an A100 or A30 now fails at session
creation rather than running a slow path.

Three facts, verified against NVIDIA's docs and a real nvcc before the edit,
decide why the value is spelled exactly this way:

- **Neighbours cover nothing.** A cubin runs on its own major at an
  equal-or-higher minor: 86 does not reach 87, 90 does not reach 120.
- **ONNX Runtime narrows it further.** v1.30.0 rewrites every entry to
  `sm_<cc>a-real` — arch-specific, cubin-only. In the ORT artefact `120` covers
  12.0 and NOT 12.1 (GB10/DGX Spark); `100` would cover B100/B200 but not B300
  (10.3). The owner's hardware is RTX-50-class, hence 120 alone.
- **Jetson Thor is 110**, its own major, reachable from nothing else — the same
  shape as Orin's 87, and a deliberate not-yet for the arm64 lane.

The trailing-`90`→`90a` rewrite in `30-build-native-nvidia.sh` is GONE. ORT
appends the `a` itself, so it was redundant — and being a suffix match it would
have silently stopped firing the moment the list no longer ended in 90, which
is exactly what this change does. Its removal also retires the "keep this list
ascending" constraint that `versions.env` warned about.

Thirteen places carried the literal list; all moved together, including the
Windows Pester pin whose comment stated a standing owner directive ("NEVER
trim") that this decision supersedes. The directive survives in its real
meaning — no trimming as a speed lever — with the set named as a decision.

How to turn an arch on or off, with the four rules and the cost, is now in
`AGENTS.md` § GPU architecture coverage; the user-facing card list is in
README.md § Which GPUs `:latest-nvidia` runs on.


## 2026-09-22 - hcsshim fork rebased: `Install-NewHost` builds `5e9df53c` and re-pins a reused work dir; `Invoke-WithEnv` really removes

**`Kataglyphis/hcsshim@feature/configurable-teardown-timeout` is rebased onto upstream
`main` `0e1f18b7`.** The head moves from `19251429` to `5e9df53c`, and PR
microsoft/hcsshim#2855 follows it. The patch is unchanged: same patch-id, and none of the
26 new upstream commits touch `cmd/containerd-shim-runhcs-v1`, `internal/hcs`, `cow`,
`jobcontainers` or `uvm`. The new build is 25 890 304 bytes with Go 1.27.1, sha256
`7A4BF6A3…`, `vcs.modified=false`. `gofmt`, `go vet` and the shim package tests pass.

- `Install-NewHost.ps1` pins `$forkPin = 5e9df53c…`. The old commit is on no branch any
  more, so a fetch by its SHA works only as long as GitHub keeps the object.
- `Sync-ShimForkCheckout` is new. It also re-pins a `%TEMP%\kataglyphis-hcsshim-fork`
  left behind by an earlier run. Before this, a reused work dir skipped the fetch
  entirely, so a pin bump could quietly rebuild the old tree.
  - Tests: `NewHost.ShimFork.Tests.ps1` (3 cases).
  - Mutation-checked by hand against three broken copies of the function: re-pin
    skipped, always fetch, fetch error swallowed. Each one made a case fail.
- **The test harness's `Invoke-WithEnv` now really removes a variable.** A PowerShell
  `$null` reaches .NET's `SetEnvironmentVariable` as `''`. That leaves the variable set
  to an EMPTY value, which child processes still see. It had two effects:
  - `$null` in `-Vars` never removed a variable.
  - A variable that was unset before the call was left behind as empty, although the
    comment said "removing".
  - Measured on PS 7.6.6 / .NET 10: git then reads `GIT_DIR=''` and stops with
    `fatal: not a git repository: ''`. `cmd`'s `if defined` calls the same variable
    undefined, which is why nothing noticed before.
  - The fix passes `[NullString]::Value`. `Harness.WithEnv.Tests.ps1` (2 cases) and the
    shim-fork suite fail against the old version.
  - The budgets of two code-dupes pairs involving `TestHarness.psm1` shrank as a result
    (47 → 34, 35 → 28).
- Docs:
  - `windows-host-setup.md` § R1 has the new build numbers, the new stock size after
    Stevedore's 2026-09-21 update (25 975 296), and how to update an existing clone
    after a rebase.
  - `windows-build-lanes.md` and `failure-modes.md` name the new binary.
  - The `hcsshim-teardown-timeout/README.md` status header now records the rebase.


## 2026-09-22 - Windows `-Variant rocm`: the driver builds `:winamd64-rocm`

**`Build-Buildkit.ps1 -Variant rocm` builds the ROCm image.** It runs the default chain
up to media, then `Dockerfile.rocm` → torch → final under its own tags
(`bk-windows-rocm`, `bk-windows-torch-rocm`, `bk-winamd64-rocm`), so a rocm run never
overwrites the default images. `-Variant rocm -Stages rocm,torch,final` reuses an
existing default media.

- `-Variant ''|nvidia|rocm`; `-Gpu` stays and means nvidia. `Resolve-BkVariant` refuses
  before buildkitd is touched: rocm on arm64, `-Gpu` with rocm, `-Stages rocm` on another
  variant, and a push tag that does not match the variant (only rocm may push to
  `:winamd64-rocm`).
- `Install-Rocm.ps1` refuses a media base that carries `GPU_TYPE`, `CUDA_ROOT` or
  `CUDA_PATH`: the shared media tag can hold a leftover `-Gpu` build.
- Smoke: `EXPECT_ROCM=1` runs `Test-RocmImage.ps1` after the CPU suite. It checks the env
  contract, the absence of CUDA, that AMD's LLVM does not shadow `clang-cl`/`lld-link`,
  `.info\version`, the device bitcode, and a `hipcc --offload-arch=gfx1201` compile.
- Torch stays CPU until OrchestrANT has a Windows ROCm extra.
- The nvidia and default runs are unchanged: same tags, same push behaviour.
- Tests: `Driver.Variant.Tests.ps1` (8) and `Rocm.Install.Tests.ps1` (17).


## 2026-09-22 - Hooks on a Windows host: pre-push clears git's environment, the shellcheck ratchet grades again

**Git exports `GIT_DIR` (and `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_PREFIX`) to hooks,
and the pre-push hook passed them straight to the mutation gate.** Its fixtures run
`git -C <tmp> init`. With `GIT_DIR` set, each init re-initialised the REAL gitdir
instead of the temp one. For a submodule gitdir (`.git/modules/<name>`, a path that
does not end in `/.git`) git guesses "bare" and writes `core.bare = true`. Seen on a
push from this repo's checkout inside OmniAccelerANT: from then on every git command
warned `core.bare and core.worktree do not make sense`, `git status` refused to run,
and `git check-attr` found nothing, so the EOL-attribute suite failed on 64 files. The
branches and the index stayed untouched.

- `linux/host-config/git-hooks/pre-push` now runs `unset GIT_DIR GIT_WORK_TREE
  GIT_INDEX_FILE GIT_PREFIX` first, exactly as pre-commit already did.
- `test-prepush-hook.sh` runs the hook with all four variables exported and asserts that
  none reaches a gate. Mutation `mutations.push-clears-git-env` turns the `unset` into a
  no-op, and the test goes red.
- Recovery and the symptom text:
  [`docs/failure-modes.md`](failure-modes.md#a-push-leaves-the-repo-bare-corebare-and-coreworktree-do-not-make-sense).

**The shellcheck warning ratchet never graded a file on a Windows host.** Two bugs:
- A bare `bash` in `subprocess` resolves to System32's WSL launcher before PATH. That
  launcher mangles the `C:\` script path, so every staged `.sh` failed the pre-commit
  ratchet.
- `--files` paths came back with `\`, while lint-shell.sh's scope uses `/`, so each file
  counted as "outside the scope" (0 of 394 graded).

`verify_shellcheck_warnings.py` now takes PATH's `bash` (`_bash()`), converts the MSYS
`--print-bin` answer with `cygpath -w`, and normalises `--files` to `/`. All three are
no-ops on Linux. Mutation `shellcheck-warnings.bash-from-path` bites the new
`test-shellcheck-warnings.sh` case. The suite itself still has 4 Linux-only assertions on
Windows, where it runs fake `shellcheck` scripts through native Python; at HEAD, 51 of
its 68 assertions failed there.


## 2026-09-22 - Windows ROCm layer: `windows/Dockerfile.rocm` + `Install-Rocm.ps1` (not wired yet)

**ROCm on Windows now has a build path.** It uses AMD's documented Windows tar
install: the same TheRock 10.0.0 release, from the same `stable.repo.amd.com` host,
that `setup-rocm-repo.sh` installs on Linux. The driver does not build it yet.
`-Variant rocm` is the next step.

- `windows/scripts/host/Install-Rocm.ps1`:
  - refuses anything but amd64;
  - downloads `therock-dist-windows-<family>-<release>.tar.gz` and verifies it
    against the pinned SHA256, refusing an empty pin;
  - extracts it with System32 `tar.exe` into `C:\TheRock\build`;
  - asserts the layout (hipcc, hipconfig, hipInfo, `amdhip64_*.dll`, the HIP
    headers, AMD's clang, the device bitcode, `.info\version` = the pin);
  - runs `hipcc --version` inside the container.
- `windows/Dockerfile.rocm` forks after media, right before torch, because nothing
  in the Windows media chain can consume ROCm: MIGraphX is Linux-only. It sets
  AMD's variables but never puts `lib\llvm\bin` (AMD's `clang-cl.exe`) on PATH, and
  appends `bin\` last.
- `versions.env`: `ROCM_WINDOWS_RELEASE=10.0.0`, `ROCM_WINDOWS_GFX_FAMILY=gfx120X-all`,
  `ROCM_WINDOWS_TARBALL_SHA256`. AMD publishes no checksum, so it is self-measured
  like `ROCM_GPG_KEY_SHA256`.
- `Rocm.Install.Tests.ps1` covers the URL guard, the amd64 refusal, the layout gate
  (each required file removed in turn must fail it) and the PATH rules.
- Why, the measured hashes and sizes, and the licence inventory:
  [`docs/windows-builds.md` § ROCm layer](windows-builds.md#rocm-layer-dockerfilerocm).


## 2026-09-22 - ROCm ASAN is optional and OFF; the plan for the first `:latest-rocm` run

The owner asked for AMD's AddressSanitizer packages alongside the normal ones,
then decided against them as a default once the size was measured: >100 GiB in a
container image is not acceptable. So `ENABLE_ROCM_ASAN` (`Dockerfile.amd`,
default `false`) gates the parallel `packages-asan` repo stanza, the install of
`amdrocm-asan${ROCM_VERSION}`, and whether `copy_rocm_payload` lets
`/opt/rocm/core-asan-*` into the shipped image at all.

Measured against the live repo index on 2026-09-22, which is why it is off:
`amdrocm-llvm-dev-asan10.0` is **61.7 GiB** installed, the full ASAN set
**134.8 GiB** (the normal image is ~19 GiB), all 30 gfx-specific ASAN packages
are gfx942/gfx950 only, and there is no ASAN MIGraphX and no ASAN torch wheel —
so the two things this image exists for stay uninstrumented either way.

Co-installing also collides on `update-alternatives`: the ASAN debs register the
same names at the same priority, so `/opt/rocm/{core,lib,bin}` and `hipcc` can
resolve into the ASAN tree, and which one wins flips between rebuilds. The knob
therefore re-`--set`s every hijacked alternative back and then ASSERTS the normal
tree owns them, failing the build if not. None of this path has run yet.

Ten non-ASAN items from the same sweep are written up in
`docs/linux-accelerator-images.md` § ROCm, largest first: per-gfx metapackages
(~18.4 GiB -> 9-13 GiB), `ROCM_PATH`/`PATH` missing in the shipped image,
asserting the installed versions (`stable` is a ROLLING suite, so our
`ROCM_VERSION` pin is a label, not a constraint), the resolved `ld.so.conf`
path, `/dev/kfd` access for uid 1001, no `seccomp=unconfined` and no baked
`HSA_OVERRIDE_GFX_VERSION`, writable MIOpen caches, a GPU-less build-time
self-check (`amd-smi`, not the deprecated `rocm-smi`), AMD's CDI container
toolkit, and a Renovate comment that watches a git tag instead of the apt
package.


## 2026-09-22 - `:latest-cross` is retired, not deprecated

The alias lived for one day. The owner decided against a deprecation window, so
the mechanism is gone rather than disabled: `CROSS_LEGACY_ALIAS_TAG`,
`cross_final_image_legacy_alias` and the second `manifest push` in
`build-runtime-manifest.sh` are deleted. From here on a release publishes
`:latest` and nothing else.

**The registry tags stay, and deleting them would take the fleet's Linux CI down
with them.** Every consumer resolves its container ref
through this repo's composite actions pinned at `@main` (98 `...@main` refs
across six repos, none passing an explicit `image:`), and `main` is 56 commits
behind: it still says `CI_IMAGE_LINUX_TAG=latest-cross` and both action defaults
still name the old tag. So the tag the fleet actually pulls today is
`:latest-cross`. The owner decided to stay on `develop`, so that merge is not scheduled:
`:latest-cross` remains the fleet's CI ref, frozen at the last release that
published it. It is documented as do-not-delete rather than pending.

The deletion itself is also not a plain "delete the version": `:latest` and
`:latest-cross` are ONE GHCR package version (`sha256:e0de6c95…`, and the same
for the arm64/riscv64 pairs), and GHCR deletes by version, not by tag. The old
name has to be made a version of its own first, or the deletion has to wait for
the release after which `:latest` has moved on and `:latest-cross` is frozen
alone. `ghcr-delete-tags.sh` already refuses the unsafe form: it skips a version
whose digest is shared with a tag being kept, so running it today is a no-op,
not a disaster (`docs/linux-host-setup.md` § B8).

`test-tag-naming.sh` keeps a regression guard: no tag function may compose the
old name again. Dated history keeps it, because the tag really was called that.


## 2026-09-22 - GPU variant chains: `CROSS_VARIANT=nvidia|rocm` builds `:latest-nvidia` / `:latest-rocm`

**A GPU image is now a variant CHAIN, not a toggle on the default one.**
Before this change `ENABLE_NVIDIA=true` / `ENABLE_AMD=true` changed only the
build args. A GPU run would have pushed CUDA bytes under the default
`cross-media-<arch>`, `cross-android-<arch>`, `:latest-<arch>` and `:latest`. The
NVIDIA/AMD layers were not stages at all, only hand-run commands whose tags were
deleted from the registry this morning.

- **Tags.** `CROSS_VARIANT` (implied by `ENABLE_NVIDIA`/`ENABLE_AMD`; both is an
  error) adds `-<variant>` to every tag from the new `gpu` stage on:
  `:cross-toolchain-<v>-<arch>`, `:cross-media-<v>-<arch>`,
  `:cross-android-<v>-<arch>`, `:latest-<v>-<arch>` and the manifest
  `:latest-<v>`. Base, compiler and sdk stay shared. A variant never gets the
  `:latest-cross` alias.
- **Stage graph.** `gpu` (`Dockerfile.nvidia` / `Dockerfile.amd`) goes between
  sdk and media when a variant is set. The default graph is unchanged.
- **Refusals** (`stage-defs.sh` `cross_variant_refusal`, shared by
  `build-cross-chain.sh` and `build-cross-stage.sh`):
  - A variant starts at `gpu` and refuses to build base, compiler or sdk.
  - Every target must be the build platform's arch, because CUDA/ROCm are
    installed for and compiled against it. rocm is amd64-only.
  - A pushing variant must build on `linux/amd64`, because the shared
    `:cross-sdk-<arch>` it builds on is the amd64 lane's.
  - The Jetson lane (native, `--no-push`) stays allowed.
  - The variant's `ENABLE_*` / `ENABLE_TENSORRT` are exported where the graph
    is built. Otherwise a single-stage rebuild wrote CPU bytes under
    `-nvidia` tags.
- **Runtime helpers.** `build-runtime-artifacts.sh` and
  `build-runtime-manifest.sh` refuse an output prefix without `-<variant>`, and
  `build-runtime-artifacts.sh` defaults to `cross_final_image_tag`. Before
  this, `ENABLE_NVIDIA=true build-runtime-artifacts.sh --push` published a
  CUDA wrapper as `:latest-amd64`.
- **Strictly serial** (owner decision). The pidfile is claimed atomically
  (noclobber) at the check, and a live chain makes a second one refuse to
  start. Chains share the buildkit store and the disk guard, and the guard
  evicts whatever the running chain does not protect. A variant keeps its own
  `chain-status-<v>.json` and `out/build-logs/<v>/` (also when `make`
  passes the default `--log-dir`). Its runtime lane budgets 180 GB.
- **NVIDIA defaults.** `ENABLE_TENSORRT=false` (no `libnvinfer` in the runtime
  payload yet). The wrappers take `onnxruntime-gpu` + `pytorch-cu130`.
- **ROCm runtime.** `copy_rocm_payload` copies `/opt/rocm` into the package,
  and `000-rocm.conf` puts its libraries on the loader path. Before this, the
  MIGraphX EP had nothing to load.
  - TheRock's absolute `update-alternatives` links are resolved hop by hop
    inside the artifact and re-made relative.
  - A tree without `libamdhip64` is fatal.
  - `Dockerfile.package` now passes `ENABLE_AMD` to the copy; without it the
    copy never ran. The wrappers take `onnxruntime-migraphx` +
  the app's `pytorch-rocm71` extra. That index stops at torch 2.13, so the pin
  enforcement now re-installs the `PYTORCH_VERSION` pair from the new
  `PYTORCH_ROCM_INDEX=rocm7.14` (there is no rocm10 line). The old code's CPU
  fallback would have swapped a ROCm torch for a CPU one without a word.
- **One onnxruntime flavour per GPU venv.** The amd64 CPU `onnxruntime_dnnl`
  (and a plain `onnxruntime`) are pruned next to `onnxruntime_gpu` /
  `onnxruntime_migraphx`. Before this, both force-installed into one
  `site-packages/onnxruntime/`, and ARCH-PARITY refused the image. The parity
  table knows `ENABLE_AMD` → `onnxruntime_migraphx`, and the rocm wrapper gets
  the build-time twin of the CUDA check: `torch.version.hip` plus
  `MIGraphXExecutionProvider`.
- **Reviewed before merge.** An adversarial review (34 findings, 22 upheld by
  two independent skeptics) produced the items above. It also raised
  `test-gpu-variant.sh` (45 assertions, through the real entry points in
  read-only modes) and env-isolated the default tag suites.
- **The Jetson lane's names** follow the variant: the example image is
  `:latest-nvidia-hostarm64-arm64`.
- **arm64 CUDA from an amd64 host is feasible but not built.** NVIDIA's
  `ubuntu2604/cross-linux-sbsa` repo carries `cuda-cross-sbsa-13-4`, the cross
  cuBLAS/cuFFT/cuSPARSE/cuRAND and `libcudnn9-cross-sbsa-cuda-13`. NCCL exists
  only as a native sbsa `.deb` (unpack it into the target tree). Wiring it needs
  the ORT/OpenCV/TVM CUDA cross flags and an ELF-machine gate. Until then, the
  arm64 half of `:latest-nvidia` is built natively.


## 2026-09-22 - `:latest-cross` becomes `:latest`; variants are `:latest-<variant>`; the `:hailo` variant is retired

**The Linux default manifest is `:latest`** (owner directive 2026-09-22). The
old name was historical. `CI_IMAGE_LINUX_TAG=latest`, and every derived tag
follows the prefix: wrappers `:latest-<arch>`, runtime stages
`:latest-base-<arch>` / `:latest-package-<arch>`, host-infixed runs
`:latest-hostarm64`. The registry was switched without a rebuild. The live
3-arch index (`sha256:e0de6c95…`) and its three children were re-tagged
`:latest` and `:latest-{amd64,arm64,riscv64}`, so `:latest` and `:latest-cross`
resolve to identical bytes. The old dead `:latest` from the ghcr-cleanup bug
was already gone (404), so nothing was overwritten.

**`:latest-cross` stays as a deprecated alias until 2026-10-31.**
`build-runtime-manifest.sh` now also pushes the same index under the name in
`CROSS_LEGACY_ALIAS_TAG` (`cross_final_image_legacy_alias` in `tag-naming.sh`).
That happens only for the amd64 lane's default image, and only after `:latest`
passed every gate. After the date, empty the key and delete the tag. The
freshness check now receives `--tag` for the index the run actually wrote,
instead of always reading the default.

**Variant grammar: `<version>[-<variant>][-<arch>]`.** Variants exist only for
stacks that cannot ship in `:latest`, which today means `:latest-nvidia` and
`:latest-rocm` (`rocm`, not `amd`, so a variant never reads like an arch).
**Neither is published yet.** The registry's `:nvidia` / `:amd` tags are
single-arch 2026-04 builds on the Ubuntu 24.04 base and were deliberately *not*
promoted. Hailo and QNN are built into `:latest` instead. The current release
carries HailoRT 5.4.0 + `hailonet` on amd64/arm64 (verified in the shipped
wrappers). It carries no QNN, because no QAIRT zip was staged in
`linux/qnn-sdk/` for that build.

**The standalone Hailo variant is gone.** `linux/Dockerfile.hailo` is deleted,
along with its two `code-dupes.allow` rows. The published `:hailo` (run
`20260919-…`) was a generation older than the standard wrapper that already
carried the same payload.

**Registry cleanup (same day):** 21 stale tagged versions deleted after
proving no kept index referenced any of them: `:hailo`, `:hailo-amd64`,
`:hailo-arm64`; the April GPU chains (`:nvidia`, `:amd`, `toolchain-`/`media-`/
`android-`/`torch-` `nvidia`/`amd`, `toolchain-amd`, `latest-cross-nvidia-amd64`);
the old-name runtime intermediates `latest-cross-{base,package}-{amd64,arm64,riscv64}`;
and the pre-chain `:toolchain`. No `buildcache-*` tags existed.


## 2026-09-22 - The arm64 GPU runtime image runs on a Jetson

The runtime lane (base -> package -> wrapper) had never carried a GPU. Built
natively on a Jetson AGX Orin with `ENABLE_NVIDIA=true`, it now ships CUDA,
cuDNN and NCCL into the package, and installs `pytorch-cu130` and
`onnxruntime-gpu` in the wrapper. On the Orin's GPU (see
`docs/linux-host-setup.md` § B2b for the rootless call):

- PyTorch: `cuda available: True`, device `Orin (8, 7)`, a matmul matching the CPU.
- ONNX Runtime 1.29: a MatMul served by `CUDAExecutionProvider`.
- OpenCV 5.0 CUDA: one device, `cuda.threshold` bit-identical to the CPU.
- `nvcc -arch=sm_87` in the image: a kernel over 1M elements, 0 wrong.

Fixed on the way, each with a suite that goes red when the fix is removed:
`--no-push` wrapper builds could not see the android wheels (now a directory
context), the torch pin step swapped CUDA torch back to CPU, a read-only
`/opt/wheels` made the ORT-variant prune fail silently, GenAI asked for TRT-RTX
without TensorRT, the Vulkan prune left 1.8 GB of x86-64 in the arm64 image on
a non-amd64 builder, and the arm64 gtk4 exception now follows the loader rather
than the arch.

A USB camera works too: `linux/jetson-webcam/run.sh` streams SSDLite
detections from the Orin's GPU to a browser at the camera's 30 fps, 13 ms per
inference. torchvision's own call managed 9 fps: its per-class postprocess spent
182 ms launching kernels. The app replays the network from a CUDA graph and runs
one vectorized NMS, with the same detections.

Not yet: the image's media layer predates the 2026-09-18 pin wave (ORT 1.29,
GenAI still `trt-rtx`), and the official PyTorch `cu130` wheels warn that they
do not target compute capability 8.7.
