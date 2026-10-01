# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**State 2026-09-30.** Published: `:latest` (2026-09-30, hub 9e9d9828; amd64 `502a5e9d…`,
arm64 `4446422d…`, riscv64 `d5e4db6b…`), `:winamd64` and `:winamd64-nvidia` (2026-09-27, hub
a33a460b), `:winamd64-rocm` (2026-09-28), `:latest-rocm` (2026-09-28, hub 1754a1dd).
`:latest-nvidia` is not published. Every Linux image gap up to CON41 shipped and was checked
in the published children (git history). Decisions and gaps checked closed live in
[`docs/image-decisions.md`](docs/image-decisions.md). **Re-derive before acting; a number
here is a date's measurement.**

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [ ] **CON45 — Follow-ups of the `:winamd64` published 2026-09-27** [M, ★★]. CON12 shipped:
      `:winamd64` (15:44) and `:winamd64-nvidia` (16:33) were built at a33a460b, which carries
      every fix CON9, CON10, CON25, CON28 and CON29 were blocked on (checked by git ancestry
      2026-09-30: a93d5144, 57bec177, 738d07e3, d8c31072). No Windows host has checked them in the
      published image yet, and the consumers still carry the workarounds (checked 2026-09-30):
      - Prove in the published image on a Windows host: `clang_rt.profile-x86_64.lib` and a
        clang-cl coverage run (CON9); `C:\llvm-patched\bin\clang-tidy.exe` reads a clang-cl
        C++23 BMI (CON10); `vulkan-1.dll` from `C:\vulkan-loader` on PATH (CON25); LiteRT
        Python in the app venv and `gstgdkpixbuf.dll` (CON28); no `VOLUME C:\workspace`
        (CON29); no LAN sccache endpoint in the ENV; one DirectML G-API session.
      - BeschleunigerBallett: `myproject_ENABLE_COVERAGE` in `x64-ClangCL-Windows-Base` is still
        OFF (CON9), and `-SkipTidy` is still passed by `Build-Windows-Container.ps1` and
        `Invoke-WindowsLane.ps1` (CON10).
      - AccelerANTgine: `Build-Windows.ps1` still sets the module-file skip
        (`ModuleImportPattern`); set `'(?!)'` so clang-tidy reads every `Src/` TU (CON10).
      - Consumers: drop `Clear-UnreachableSccacheEndpoint` from the hub path once no published
        image carries the endpoint (it was the first CON12 problem).

## Open — Linux image (all arches)

- [b] **CON44 — `LP_NATIVE_VECTOR_WIDTH=256` in the image** [S, ★★]. Mesa 26.0.8's lavapipe
      compiles its BVH radix sort (`lvp_acceleration_structure.c`, `subgroup_size_log2 = 3`) for
      8-lane subgroups; llvmpipe's subgroup is its vector width / 32, so 4 lanes on arm64 NEON,
      and the sort's scatter writes through garbage addresses: every lavapipe draw that builds an
      acceleration structure SEGVs on arm64 (BeschleunigerBallett run 36746313937, root-caused
      2026-09-30 from a core: a 4-lane `st1` in `rs_scatter_smem`; x64 with 128 reproduces it,
      arm64 with 256 draws). riscv64 has 4-lane subgroups too (`vulkaninfo`, 2026-10-01).
      **Fixed in source (2026-10-01), package stage:** `ENV LP_NATIVE_VECTOR_WIDTH=256` for every
      arch, and the runtime smoke's `check_lavapipe_subgroup` fails a variable other than 256 or
      a lavapipe `subgroupSize` other than 8 (`docs/failure-modes.md`). Ships with the `:latest`
      rebuild started 2026-10-01. Then: check it in the published children, and
      BeschleunigerBallett drops its own export in `run-ctest.sh` (2ac0e785). Retire it once the
      image's Mesa has upstream ebcfbe60 (2026-08-22), which deletes that sort.

- [b] **CON47 — `libgstvalidatessim.so` fails to load in the published `:latest`** [S, ★].
      Seen 2026-10-01 by the CON42 spike in the amd64 child (`502a5e9d…`). Measured 2026-10-01:
      no loader error; `ldd -r` is clean, and `gst-inspect-1.0 -b` blacklists it because its
      `plugin_init` returns FALSE outside gst-validate, while the core registry scans
      `gstreamer-1.0/validate/` too. Under `gst-validate-1.0` it works. arm64 and riscv64 ship no
      gst-devtools (cross builds disable it) and blacklist nothing.
      **Fixed in source (2026-10-01), media stage (gstreamer):** patch `007` returns TRUE there,
      proven by building gst-devtools 1.29.2 with the hub's patcher in a container FROM `:latest`
      amd64 (blacklist 1 → 0; gst-validate's SSIM override writes its frames both ways). The
      runtime smoke's plugin-health check now fails on any undocumented blacklisted plugin, and
      `check_gst_validate_ssim` runs the override on amd64. Ships with the `:latest` rebuild
      started 2026-10-01; then check it in the published amd64 child.

## Open — Linux arm64 and riscv64

None open.

## Open — Windows `:winamd64`

- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Blocked upstream (checked 2026-09-26): microsoft/STL#6294
      is open, its fix #6298 awaits review, and neither 14.52 nor 14.53 Preview carries it.
      The toolset is VS 18's stable channel, not a pin that could move.
      BeschleunigerBallett's `find_if` stands (a2793e6c). Never set
      `_USE_STD_VECTOR_ALGORITHMS=0` image-wide: it turns every vectorized algorithm off.
      Close when a production toolset ships #6298.
## Open — the Windows arm64 bundle and unpublished variants

- [b] **CON30 — The `:winarm64` bundle** [L, ★]. Blocked on hardware and owner
      decisions.
      - No aarch64 ASan runtime.
      - The CUDA payload lacks nvrtc, nvtx and cupti.
      - No LiteRT QNN dispatch (#155: five upstream defects).
      - Absent by construction: the TVM/IREE compilers, LiteRT-LM, the torch
        stage, Flutter, classic TensorRT, TAPPAS.
      - Its binaries now run on real arm64 hardware, but only as far as loading.
        The consumer cross lanes' run jobs on `windows-11-arm` (2026-09-25; runs
        36136967538, 36142875090, 36142882316) load the bundle's VC++ runtime and
        GLib/GStreamer, and AccelerANTgine's also loads its chain ONNX Runtime (a
        static import). Nothing runs an inference, a GStreamer pipeline or a
        plugin, and the bundle's own tools and Python never execute
        (`docs/windows-cross-builds.md` § Consumer cross lanes).
- [b] **CON31 — Variants that are not published** [L, ★]. Blocked on owner decisions.
      - `:latest-nvidia`: no `libnvinfer` in the runtime payload, and no arm64 route.
      - `:latest-rocm`: the wrapper lacks `ROCM_PATH`/`HIP_PATH` and cannot open
        the device as shipped.
      - `:winamd64-rocm`: published 2026-09-28 (built at ad08bc30); record the redistribution
        decision that allowed it in `docs/windows-rocm.md` § Redistribution.

      Sources: `docs/linux-accelerator-images.md` and `docs/windows-rocm.md`.
- [ ] **CON43 — The Windows arm64 lanes become `build + test`** [M, ★★]. Owner request
      2026-09-30. Every `Windows arm64 · cross build + run` lane cross-builds on amd64 and then
      only STARTS the product on `windows-11-arm`; none runs a test there, so arm64 has no
      test verdict at all on Windows. What the run jobs do today (checked 2026-09-30):
      BeschleunigerBallett `GraphicsEngine.exe --version` (LunarG's arm64 Vulkan runtime on
      `PATH`), AccelerANTgine `AccelerANTgine.exe`, OxidANT four `kataglyphis_cli.exe`
      subcommands, OmniAccelerANT (its own hybrid workflow, not this one) a 20 s launch smoke.

      Plan:
      1. **This hub: `container-ci-windows.yml` carries tests to the arm64 runner.** New inputs
         beside `run-command`: `test-artifact-dir` (what the cross build stages for tests,
         uploaded as a second artifact) and `test-command` (PowerShell run in it on
         `windows-11-arm`, after `run-command`; any failing native command fails the lane, and
         the job summary reports the pass/fail/skip counts it prints). A `Test-TargetArch.ps1`
         gate over the test artifact too, so an amd64 test binary cannot pass on arm64 by
         emulation (Windows on Arm runs x64 code transparently — that is exactly the false
         green to rule out). Document the inputs in `.github/actions/README.md` and
         `docs/windows-cross-builds.md`.
      2. **Measure before wiring, per consumer:** does the cross build produce the test
         binaries at all (ctest targets, `cargo test --no-run --target
         aarch64-pc-windows-msvc`), and do they run from a different directory? CTest's
         `CTestTestfile.cmake` embeds the container's absolute build paths (`C:\ws\…`), so
         either stage the build tree at the same path on the runner, or run the test
         executables directly from a generated list, or `ctest --test-dir` with the paths
         rewritten. Pick per repo by what actually runs.
      3. **BeschleunigerBallett:** the Release test suites the x64 lane runs, minus the same
         `$gpuOnlySuites`/`gpu_excluded_suites` (no GPU driver on the runner; LunarG's loader
         alone has no ICD). Pester already runs on x64 and needs no arm64 run.
      4. **AccelerANTgine:** its ctest suites (Release). Pester as for BeschleunigerBallett.
      5. **OxidANT:** the workspace's test executables from `cargo test --no-run` for the arm64
         target. The WebGPU renderer tests need an adapter: check whether `windows-11-arm`
         offers WARP/D3D12 or GL through wgpu; if not, they skip exactly as the x64 lane's
         Server Core skip does, with the reason printed, not silently.
      6. **OmniAccelerANT** (tracked in its own BACKLOG): the app job already has Flutter on the
         arm64 runner, so `flutter test` runs natively there, plus the plugin's C ABI check.
      7. **Rename** each lane to `Windows arm64 · cross build + test` only once its tests run
         and gate; the name must keep telling the truth. The lane-name tables (e.g.
         `docs/ci-build-triggers.md`) move with it.

      Order: the hub inputs first (consumers call it at `@develop`, so push it before any
      consumer uses the new inputs), then one consumer at a time, each proven by its green
      arm64 run with a non-zero test count.
      **Status 2026-10-01:** step 1 is in. The inputs, the arch gate over the test tree, the
      `TESTS:` verdict and `Invoke-StagedTests.ps1` are in place, with Pester tests. Steps 2-7
      (the consumers) are open.
- [ ] **CON46 — Renovate detects and bumps the CMake third-party deps** [M, ★★]. Owner request
      2026-10-01. The consumers declare C++ dependencies in CMake, and the shared preset
      (`default.json`) has no `customManagers` at all, so Renovate sees none of them (checked
      2026-10-01):
      - `FetchContent_Declare(googletest URL https://github.com/google/googletest/archive/<sha>.zip)`:
        AccelerANTgine and BeschleunigerBallett `third_party/CMakeLists.txt`, OmniAccelerANT's
        plugin `linux/` and `windows/CMakeLists.txt` (the same commit in all four).
      - `GIT_REPOSITORY … GIT_TAG …`: abseil (BeschleunigerBallett through `set(ABSL_TAG …)`),
        microsoft/GSL, and corrosion at `GIT_TAG master` — a floating ref, so no build is
        reproducible until it is pinned.

      Plan:
      1. Inventory every `FetchContent_Declare`, `ExternalProject_Add`, `CPMAddPackage` and
         `set(<X>_TAG …)` feeding one, across the fleet (`.github/consumers.json`), skipping
         vendored trees.
      2. Pin the floating refs (corrosion `master`) to a tag or commit first.
      3. Add regex `customManagers` to `default.json`: the archive-URL form (datasource
         `github-tags` with `currentDigest`, or `git-refs`), the `GIT_REPOSITORY`/`GIT_TAG` form
         across lines, and the `set(<X>_TAG …)` indirection. Where a declaration is too irregular
         for a safe regex, a `# renovate: datasource=… depName=…` comment above it (one convention,
         documented in `docs/dependency-updates.md`).
      4. Make `renovate-local.sh --apply` rewrite what those managers report (it rewrites the
         manifests Renovate reports today); a SHA-pinned archive URL must move to the new
         commit's archive, and a `URL_HASH`, where present, with it.
      5. Tests: fixtures for each form in the renovate test suite (detect, then apply), and
         a mutation entry per manager.
      6. Prove it with a report run over the fleet (`Invoke-Renovate.ps1 -Recurse`, report-first:
         `-Apply` only on the owner's word), each dep listed with its current and newest version.
- [b] **CON42 — DeepStream in `:latest-nvidia`** [L, ★★]. Owner request 2026-09-30. Spike
      (phases 1–3) done 2026-10-01, the GPU gate passed the same day; phases 4 and 6 are in
      the source, off by default (`ENABLE_DEEPSTREAM=false`). Blocked on one thing outside the
      build:
      1. **An nvidia variant chain run** with `ENABLE_DEEPSTREAM=true`, owner-approved. It has
         never run; everything below was proven in throwaway containers FROM the published
         `:latest` amd64 child plus the variant's CUDA install. It is also the first build of
         the GPU run's three fixes and of GStreamer and libcamera without libunwind. That one
         is in every variant by owner decision (2026-10-01, "everywhere"), so it reaches
         `:latest` with the rebuild started 2026-10-01 and `:latest-rocm` with its next chain.
         Its libcamera half is measured too (2026-10-01, `docs/failure-modes.md`).

      Measured 2026-10-01 (DeepStream v9.1.0, commit 581889df; runtime
      `deepstream-binaries-x86_9.1.0_amd64.deb`; GStreamer 1.29.2; CUDA 13.4.2; GCC 16.2):
      - **Phase 1 — passes.** 48 source components build against `/opt/gstreamer`; all nine
        checked elements register without a GPU. Fixes, exclusions and the soname closure:
        `docs/linux-accelerator-images.md` § DeepStream.
      - **Phase 2 — passes on the GPU** (RTX 2080, sm_75, driver 595.58.03, CDI with rootless
        nerdctl): TensorRT 10.16 builds the sample engine for sm_75, NVDEC decodes through the
        distro `libv4l2`, and decode → `nvstreammux` → `nvinfer` → `nvtracker` →
        `nvmultistreamtiler` → `nvdsosd` (GPU mode) runs with detections and tracker ids in the
        metadata, as root and as uid 1001. `nvstreamdemux` and `nvurisrcbin` run too. TensorRT 10
        sits beside the variant's 11 (`ENABLE_TENSORRT` stays false; DeepStream does not need it).
        Pass/fail only; the licence forbids publishing benchmark results.
      - **Phase 3 — passes.** NVIDIA's CUDA 13.2 builds (`libnvbufsurftransform`, the tracker,
        TensorRT 10.16) run their sm_75 kernels on CUDA 13.4.92.
      - **The GPU run found four defects, all fixed in the source** (doc § The GPU run): the
        builder resources TensorRT `dlopen()`s by file name need links in the default lib dir;
        NVDEC needs NVIDIA's plugin linked into the distro `libv4l2`'s plugin dir; NVIDIA's
        prebuilt legacy `nvstreammux` reads `GstMapInfo.data` after unmap, which GStreamer
        ≥ 1.28 clears, so the image sets `USE_NEW_NVSTREAMMUX=yes`; and `libunwind.so.8`, linked
        by GStreamer core and libcamera, turned an exception through `std::call_once` into a
        segfault (`docs/failure-modes.md`).
      - **Phases 4 and 6 — in the source.** `05-frameworks/deepstream.sh` (media stage `build`,
        package `stage-runtime` / `assert-absent`), `deepstream-verify.sh` (closure, one
        GStreamer, no `libv4l2` hijack, the two `dlopen()` links, plugin dir, registration; also
        `check_deepstream` in the runtime smoke), `DEEPSTREAM_*` pins with SHA256s, the
        `ENABLE_DEEPSTREAM` refusals outside the nvidia variant, `test-deepstream.sh` and 22
        `deepstream.*` mutation entries.
      - **Phase 5 — decided**: the owner allowed publishing it (doc § Licence).

      Still to do:
      - Other prebuilt NVIDIA plugins may read `GstMapInfo` after unmap like the legacy mux.
        The GPU run exercised `nvvideoconvert`, `nvv4l2decoder`, `nvmultistreamtiler` and the
        tracker; `deepstream_bins`, `dewarper`, `of`, `segvisual` and the rest were not run.
      - Size: TensorRT 10 alone is 2.6 GB (builder resources for every GPU generation).
        Trimming them to `CUDA_ARCHITECTURES` would drop the 2080's sm_75: an owner call.
      - **Phase 7 (arm64)**: out of scope until CON31 has an arm64 CUDA route. The Jetson
        runtime `.deb` is pinned (`DEEPSTREAM_BINARIES_ARM64_SHA256`); nothing installs it.
      - **Phase 8**: `consumer-image-contract.md` names (`DEEPSTREAM_ROOT`, the plugin link,
        `USE_NEW_NVSTREAMMUX`) and OmniAccelerANT's `nvinfer` path, after a published image exists.
      - Renovate reports `DEEPSTREAM_VERSION` (github-releases, report-only). The v9.1.0 release
        also hosts 9.1.1 assets for NVIDIA's `develop` branch; the pin stays on 9.1.0.
- [b] **CON34 — The rocm image's HIP/MSVC `<cmath>` overlay is installed by the llama
      stage, not by `Dockerfile.rocm`** [S, ★]. Blocked on the next rocm build (owner):
      it re-keys from base anyway since `versions.env` changed, so the move adds no rebuild
      then, and only that build proves it (MIGraphX has never compiled with the config files
      active). The 2026-09-26 scope adds one step: `Rocm.Install.Tests.ps1`'s check that no
      `llvm\bin` appears in `Dockerfile.rocm` must narrow to the PATH value. MSVC 14.51's `constexpr` `isgreater`
      and its five siblings broke every HIP compile in the image. `windows/scripts/hip/`
      fixes that with config files beside TheRock's clang (`docs/windows-rocm.md`
      § HIP compiles against MSVC 14.51, 2026-09-25). They sit at the end of
      `Dockerfile.rocm-llama` only because an edit to `Dockerfile.rocm` re-keys the
      whole chain. At the next full rocm rebuild:
      - install them with TheRock in `Dockerfile.rocm`;
      - drop MIGraphX's own `-isystem` overlay (`Write-HipMsvcCmathOverlay`), since
        TheRock's `clang++` then loads the config itself;
      - drop the parity test that holds the two copies equal.

      Retire the overlay itself when `Test-HipMsvcCmath.ps1` reports that the
      `--no-default-config` compile passes too.
