# Backlog — image gaps

Every known gap in the images this hub publishes (`:latest`, `:winamd64`, the
`:winarm64` bundle) that a consumer lane hits or works around. The refactoring
registers stay in [`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).
The CON1–CON6 prefix history is in
[`…-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md).

**Measured 2026-09-25** against `:latest` index `ec4bb68b` (amd64 image built
2026-09-22), run as uid 1001 through the image's own entrypoint. Windows and
arm64 items rest on the CI runs and hub documents they cite. The same day's sweep
covered all nine repositories in `.github/consumers.json`. **Re-derive before
acting; a number here is a date's measurement.**

**Swept 2026-09-26.** Every open item was fixed in source, decided (§ Deliberate), or
is blocked on the owner. A fix in source is not a fix in an image: the Linux ones ship
with CON11, the Windows ones with CON12, and each item says what to check afterwards.
**CON11 shipped 2026-09-29** (`:latest` index `sha256:696642b2…`), and CON37 retired the
consumer workarounds it made unnecessary the same day (git history, 2026-09-29/30). The
consumers measured four gaps it did not close, CON38–CON41, and all four are closed: CON40
(a lane-time script) in source, CON38, CON39 and CON41 in the `:latest` of 2026-09-30 (amd64
`502a5e9d…`, arm64 `4446422d…`, riscv64 `d5e4db6b…`), checked in each published child as
uid 1001: atheris' `lib/linux/libclang_rt.fuzzer_no_main-<arch>.a`, clang-tidy through
`/usr/bin/clang{,++}` selecting `/opt/gcc-16.2.0`, the loader's xcb/xlib/wayland surfaces and
`vkcube` under `xvfb-run` on all three; gtk4 now loads on arm64, so the smoke's arm64 exception
is gone. riscv64 builds no `libgstgtk4.so` at all (unchanged).

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [b] **CON12 — Republish `:winamd64`, and publish `:winamd64-nvidia`** [M, ★★★]. Blocked on the owner. The published
      image (2026-09-22, hub 0d85b8c1) has three problems:
      - **A LAN sccache endpoint in its ENV.** It is the build host's LAN WebDAV,
        unreachable from CI, so sccache exits and CMake reports clang-cl as broken.
        Consumers survive only through `Clear-UnreachableSccacheEndpoint` in their
        hub pin (`docs/windows-build-resources.md`).
      - **ONNX Runtime from outside the chain.** OpenCV dnn/G-API was compiled
        against a downloaded ONNX Runtime zip and GenAI against a NuGet DirectML
        package, so G-API's DirectML EP is a stub that throws. 57bec177 fixes it,
        but no container build has run it yet (`docs/onnxruntime-single-source.md`).
      - **The old CUDA arch set, `80;86;87;89;90`.** It has no Blackwell `sm_120`,
        which README and AGENTS.md now advertise (d3f5fe42, d8c31072).

      In source since and shipped by the same rebuild (2026-09-26): CON9 and CON10
      (`clang_rt.profile` and a matching clang-tidy), CON25's Vulkan loader on PATH,
      CON28 (LiteRT Python and the `gdkpixbuf` plugin), CON29 (no baked
      `C:\workspace`), and 7.1 GB less image, because the patched LLVM's
      source and Ninja tree no longer stay in its layer. `versions.env` changed after
      0d85b8c1, so the chain rebuilds from base anyway.

      The first local rebuild (2026-09-26) found one more: with Blackwell in the arch set,
      ORT's LLM kernels compile as PTX only on MSVC, and sccache 0.18 aborts those nvcc
      compiles (mozilla/sccache#2862). ORT's nvcc now stays bare for such an arch list.

      The local rebuild of 2026-09-26/27 (`windows\Build-Buildkit.ps1 -Gpu`, at 6fe2992f and
      then 738d07e3) passed the ENV gate (`Assert-ImageEnvPublishable`), the ORT census and the
      smoke gate (245 passed, 0 skipped); ORT took 1:59 with its nvcc bare.

      **Two tags since 2026-09-27** (owner decision: Windows follows the variant rule). The
      `-Gpu` build is the nvidia variant and publishes as `:winamd64-nvidia`; `:winamd64`
      becomes the build without `-Gpu`, CPU + DirectML:
      - `:winamd64-nvidia`: `-Gpu -PushRef ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64-nvidia`
        at the rename's commit or later. The local run predates the rename, so its stages
        re-solve under the new `bk-*-nvidia` names.
      - `:winamd64`: the default build, not run yet. The consumers use its chain ORT (DirectML
        and `onnxruntime_providers_shared.dll`), its media runtime and its cp314 ORT wheels in
        `C:\runtime\wheels`, so those must stay.

      No consumer needs CUDA from the Windows image (all eight repos surveyed 2026-09-27).
      Every lane inherits `:winamd64` through the hub's actions at `@develop`, so publishing the
      default build moves them all with no consumer commit. A lane that wants CUDA later needs
      a variant input first: `container-ci-windows.yml` has no `image` input, and
      `Get-CiImageReference` has no variant. After the publishes, run one DirectML G-API session, set BeschleunigerBallett's
      ClangCL coverage back ON and drop its container `-SkipTidy` (CON9, CON10), and
      let AccelerANTgine tidy every `Src/` TU.

## Open — Linux image (all arches)

None open.

## Open — Linux arm64 and riscv64

None open.

## Open — Windows `:winamd64`

- [b] **CON9 — The patched LLVM ships `clang_rt.profile`** [M, ★]. Blocked on CON12.
      No record backed the "profile fails to compile under clang-cl" that switched it off,
      and the same list spelled libFuzzer's switch `COMPILER_RT_BUILD_FUZZER`, which names
      no option, so libFuzzer shipped all along. Fixed in source (2026-09-26):
      `COMPILER_RT_BUILD_PROFILE=ON`, `COMPILER_RT_BUILD_PROFILE_ROCM=OFF` (the HIP-offload
      twin new in 23.x; this LLVM has no AMDGPU target), libFuzzer's switch spelled right,
      and the stage fails without `clang_rt.profile-x86_64.lib`. Proven on 2026-09-26 by
      rebuilding the tree that ships in `:winamd64` with those deltas: the runtime builds,
      and clang-cl coverage runs to an `llvm-cov` report for `/MDd`, for `/MD` with ASan and
      through `cmake/Tests.cmake`. Afterwards
      set BeschleunigerBallett's `myproject_ENABLE_COVERAGE` in `x64-ClangCL-Windows-Base`
      back to ON.
- [b] **CON10 — The patched LLVM ships a clang-tidy that reads its BMIs** [M, ★★].
      Blocked on CON12. Fixed in source (2026-09-26): `clang-tools-extra` without clangd,
      and the stage fails without `clang-tidy.exe` and `clang-apply-replacements.exe`.
      Proven in the same rebuild: 501 clang-tools-extra TUs (7.5 min on a warm cache), and
      the new clang-tidy reads a clang-cl C++23 BMI that scoop's release clang-tidy refuses
      ("built from a different branch"). Afterwards AccelerANTgine tidies every `Src/` TU: its lookup already
      finds `C:\llvm-patched\bin\clang-tidy.exe`, but that branch keeps the hub's
      module-file skip (set `ModuleImportPattern='(?!)'`). BeschleunigerBallett drops its
      container `-SkipTidy`.
- [b] **CON25 — Server Core has no Vulkan loader outside rocm** [M, ★★]. Blocked on
      CON12. Fixed in source (2026-09-26): the final stage installs LunarG's pinned
      `vulkan-1.dll` into `C:\vulkan-loader` and appends it to PATH, never System32. Proven
      in `:winamd64`: a program importing `vulkan-1.dll` went from `0xC0000135` to running
      (zero devices, no ICD), and `gstvulkan` loads. OpenGL stays host-only (§ Deliberate).
- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Blocked upstream (checked 2026-09-26): microsoft/STL#6294
      is open, its fix #6298 awaits review, and neither 14.52 nor 14.53 Preview carries it.
      The toolset is VS 18's stable channel, not a pin that could move.
      BeschleunigerBallett's `find_if` stands (a2793e6c). Never set
      `_USE_STD_VECTOR_ALGORITHMS=0` image-wide: it turns every vectorized algorithm off.
      Close when a production toolset ships #6298.
- [b] **CON28 — Smaller Windows absences** [S, ★]. Blocked on CON12. Swept 2026-09-26:
      - LiteRT Python is fixed in source and ships with CON12. Its exclusion from `uv sync`
        outlived its reason (2.1.3 had no cp314 wheel; the locked 2.1.6 has one). Measured
        in `:winamd64`'s app venv: it installs, and the app smoke passes it (13/15, 0 failed).
      - TAPPAS, `cargo-cbuild`, opus SIMD, Hailo's Windows pyhailort and `hailonet` are
        decided (§ Deliberate).
      - GStreamer's `gdkpixbuf` plugin on amd64 is fixed in source (2026-09-26). gdk-pixbuf
        2.44.6 defaults `man=true` and fails setup without rst2man, so the plugin fell out
        of auto-features unseen. `Get-GstGdkPixbufMesonArgs` turns its man pages, tests and
        typelib off and passes `gst-plugins-good:gdk-pixbuf=enabled`, so the next such loss
        fails meson setup. Proven 2026-09-27 by the local CON12 rebuild at 738d07e3: the
        subproject configures, and `gdk_pixbuf-2.0-0.dll` and `gstgdkpixbuf.dll` link and
        install; the smoke gate still passes 245/0. arm64 keeps it off (§ Deliberate).
- [b] **CON29 — The baked `VOLUME C:\workspace`** [S, ★]. Blocked on CON12. Dropped in
      source with its `WORKDIR` (2026-09-26): nothing needed the directory, every caller
      passes `-w`, and the VOLUME left an anonymous volume per container.
      `Update-CTestMetadataPaths` takes `-ContainerRoot` (default `C:/workspace`). The old
      claim that every consumer mounts at `C:\ws` was wrong: `python-ci-windows.yml`,
      OrchestrANT and WebDavClient mount at `C:\workspace`, which works only on
      version-matched hosts today and on every host after CON12.

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
      - `:winamd64-rocm`: pushing it waits on a redistribution decision.

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
- [b] **CON42 — DeepStream in `:latest-nvidia`** [L, ★★]. Blocked on the running
      `:latest` rebuild (2026-09-30) and on CON31's `:latest-nvidia` amd64 publish; owner
      request 2026-09-30, planned for after that build.

      Today (checked 2026-09-30): the one GStreamer build (media stage, same options for
      every variant) ships gst-plugins-bad's `nvcodec` (NVDEC/NVENC + CUDA memory elements,
      driver loaded at run time) in every image, `:latest` included; nothing in
      `03-media/build/gstreamer/` reads `ENABLE_NVIDIA`, and nothing in the hub names
      DeepStream. Upstream is [NVIDIA/deepstream](https://github.com/nvidia/deepstream),
      tag `v9.1.0`: a monorepo whose `src/gst-plugins/`, `src/utils/` and sample/reference
      apps are source (Apache-2.0, `make && make install` per component, `build/build.sh`
      for all), while the runtime (`deepstream-binaries-{x86,aarch64}_9.1.0`,
      `deepstream-9.1_9.1.0-1_{amd64,arm64}.deb`, installed to
      `/opt/nvidia/deepstream/deepstream-9.1/`) is proprietary, under NVIDIA's SDK licence.
      It targets Ubuntu 24.04, CUDA 13.2, TensorRT 10.16.x, driver 595+; Jetson through
      JetPack 7.2; SBSA only inside NVIDIA's container.

      The gaps against this image:

      | | DeepStream 9.1 | `:latest-nvidia` source |
      | --- | --- | --- |
      | OS | Ubuntu 24.04 | Ubuntu 26.04 |
      | CUDA | 13.2 | 13.4.2 |
      | TensorRT | 10.16.x (`nvinfer`) | 11.3.0.99 pinned, `ENABLE_TENSORRT=false` |
      | GStreamer | the 24.04 distro 1.24 | the hub's own 1.29.2 |
      | arm64 | Jetson / SBSA container | no route yet (CON31) |

      Plan, one gate per phase; stop and record the measurement where a gate fails:
      1. **Feasibility spike, no chain.** In a throwaway container FROM the published
         `:latest-nvidia` amd64 child: build `src/gst-plugins/` and `src/utils/` against
         `/opt/gstreamer` (pkg-config from the image), install the x86 runtime `.deb`
         contents unpacked into a prefix (not `dpkg -i`, which pulls 24.04 deps), and run
         `gst-inspect-1.0` on `nvinfer`, `nvstreammux`, `nvvideoconvert`, `nvtracker`,
         `nvdsosd`. Record every unresolved soname (`ldd`, pkg-config, never a guess) and
         every GStreamer/GLib ABI symbol the binaries miss against 1.29.2.
         Gate: all five load. Otherwise decide between (a) pinning a GStreamer 1.24 build
         for this variant only, (b) waiting for a DeepStream built against newer
         GStreamer, (c) dropping CON42.
      2. **TensorRT.** `nvinfer` links TensorRT 10.16.x; the hub pins 11.3. Decide: a
         DeepStream-only 10.16 beside 11.3 (two sonames, `libnvinfer.so.10` vs `.11`,
         `RUNPATH` from DeepStream's libs), or moving the variant's pin to 10.16, or waiting
         for a DeepStream on TensorRT 11. Whichever wins also closes CON31's "no
         `libnvinfer` in the runtime payload", so it turns `ENABLE_TENSORRT` on for the
         nvidia variant (owner decision 2026-09-22 kept it off; this revisits it).
         Gate: `gst-launch-1.0` of `nvstreammux ! nvinfer config-file-path=<sample> !
         fakesink` runs on a real GPU (this host's RTX 2080 needs its NVIDIA driver loaded
         first, a root action) — and `nvinfer`'s TensorRT engine build succeeds on sm_75,
         which the variant's `CUDA_ARCHITECTURES` (86;87;89;120) does not compile for:
         note what that means for the 2080 or test on a newer card.
      3. **CUDA 13.4 vs 13.2.** The runtime is built against 13.2; confirm it loads and
         runs on 13.4.2 (minor-version compatibility) in the phase-2 run. If not, record
         the symbol and decide per phase-1 options.
      4. **Source, pins and provenance.** New `versions.env` pins: `DEEPSTREAM_VERSION=9.1.0`,
         the tag's commit, and a SHA256 per release asset and arch, checked like every
         other download (never a floating `latest` release). A new
         `05-frameworks/deepstream.sh` builds the open-source part against `/opt/gstreamer`
         and stages the runtime; a `Dockerfile.nvidia`- or media-stage RUN gated on
         `ENABLE_NVIDIA` + a new `ENABLE_DEEPSTREAM` (default false), so `:latest` and
         `:latest-rocm` never carry it. Renovate: add the GitHub release as a datasource,
         reported only (report-first).
      5. **Licence.** The runtime is proprietary: record what is redistributed in
         `docs/third-party-licenses.md`, ship NVIDIA's EULA text in the image, and get an
         owner decision on publishing it on GHCR at all (the same question as
         `:winamd64-rocm`'s redistribution decision in CON31). Fallback: install at lane
         time from the checksum-pinned asset instead of baking it in.
      6. **Gates in the image.** Smoke (wrapper and runtime-image smoke): the five
         elements `gst-inspect` clean without a GPU (they register; inference needs one),
         the runtime libraries resolve (DT_NEEDED against the image, the same closure
         discipline as `check-bundle-closure.sh`), and no second GStreamer copy wins a
         soname over `/opt/gstreamer` (SHIPPED-TRUTH D). Unit tests for the script's pin
         and checksum handling; mutation entries for each refusal.
      7. **arm64.** Only after CON31 has an arm64 CUDA route: Jetson (JetPack 7.2) and SBSA
         are different targets, and NVIDIA supports SBSA only in its container. Scope it as
         its own item then; amd64 first.
      8. **Consumers and docs.** `docs/linux-accelerator-images.md` gets a DeepStream
         section (what ships, what needs a driver, the licence); `consumer-image-contract.md`
         lists the new names (`DEEPSTREAM_ROOT`, the plugin path); OmniAccelerANT's Stream
         page is the first consumer to evaluate (an `nvinfer` path beside its ONNX Runtime
         one), as its own item there.

      Effort: phases 1-3 are a spike of a day or two and decide everything else; 4-6 are
      one chain run of the nvidia variant (amd64 only, ~hours with a warm cache).
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

## Checked 2026-09-25 and closed — the consumer notes are stale

Each item below is still described as a gap in a consumer file. The image says
otherwise. The consumer notes are theirs to update; do not re-open these here.

- **`CARGO_HOME`/`RUSTUP_HOME` are root-owned.** Both are writable by uid 1001.
  Stale in AccelerANTgine (`-e CARGO_HOME=/tmp/cargo`), OxidANT
  (`/tmp/cargo-home`) and BeschleunigerBallett (`common.sh` fallback).
- **No rustup, no wasm32 std.** rustup 1.29.1 is present, and 1.98.1 plus the
  dated `nightly-2026-06-28` both carry wasm32, aarch64 and riscv64.
  BeschleunigerBallett's `wasm-size-budget.sh` still carries a skip for it.
- **Adding a component to the baked nightly fails with EXDEV.** Not reproduced:
  `rustup component add llvm-tools` exits 0 (OmniAccelerANT BACKLOG).
- **`CCACHE_SECONDARY_STORAGE=true`.** Absent. `CCACHE_DIR` and `SCCACHE_DIR`
  are writable `/var/cache` paths.
- **`GSTREAMER_ROOT_ANDROID` is not exported.** It is:
  `/opt/android/gstreamer` (OmniAccelerANT AGENTS.md and BACKLOG).
- **slangc is below the WGSL floor.** It is 2026.13.1, with Vulkan SDK
  1.4.357.0 (BeschleunigerBallett BACKLOG and `getting_started.md`).
- **A second ONNX Runtime in `/opt/opencv5/lib`.** It is byte-identical to the
  chain build: same sha256, and both carry the chain's source path 127 times.
  The ld.so cache listing it first is therefore harmless.
- **Flutter differs between the images.** Both carry 3.47.4: Linux measured,
  and the Windows 2026-09-22 build log shows `FLUTTER_VERSION = 3.47.4`
  (OmniAccelerANT BACKLOG).
- **The Windows image has no pkg-config and scoop-only Rust.** Both are
  present: `Install-ScoopTools.ps1` installs `pkg-config`, and
  `Install-RustToolchain.ps1` installs rustup (OmniAccelerANT `platforms.md`).
- **`:latest`'s children 404.** `ec4bb68b` resolves and pulls
  (BeschleunigerBallett `ci-image-ref.sh`).
- **No patchelf.** `/usr/bin/patchelf` 0.18.0 is present (WebDavClient's lane
  `apt-get`).

## Deliberate — not gaps

These are recorded so nobody files them as gaps:
- No GTK4 dev headers.
- The distro `libgstreamer*-dev` packages are purged.
- CPython 3.14 only.
- The CUDA arch set is `86;87;89;120`, with no PTX.
- riscv64 is built for the RVA23 baseline.
- riscv64 uses the distro CMake 4.2.3.
- riscv64 has no IREE compiler, no `ml-ai` extra, no Flutter, appimagetool,
  Flatpak runtimes or Hailo, because upstream ships none for it.
- ORT QNN is opt-in on arm64.
- The Android host tools are x86-64 only (upstream's shape).
- `wasm-bindgen-cli` and `cxxbridge-cmd` are installed at lane time, because
  their version must match the consumer's own `Cargo.lock`.
- `:latest` is not pinned by digest.
- No GPU inside a Windows container.
- There is no ATL in the VS Build Tools. It affects only this hub's own builds.
- arm64 and riscv64 keep a distro GStreamer 1.28 runtime beside `/opt/gstreamer`: their
  cross-built GStreamer has no GTK, so `libgstgtk4.so` needs Ubuntu's `libgtk-4-1`, which
  depends on it. `000-gstreamer.conf` sorts ours first and SHIPPED-TRUTH D fails any
  soname a distro copy wins; bundle from pkg-config, not `ldd`, and never prepend
  `/usr/lib/<triplet>/gstreamer-1.0` to `GST_PLUGIN_PATH` (CON21).
- The arm64 and riscv64 GCC has no libgomp, libitm or gfortran, and amd64's plain cross
  GCCs no target libasan: no consumer uses OpenMP, Fortran, `-fgnu-tm` or a sanitized
  amd64-hosted GCC cross build (swept 2026-09-26). libgomp is `all-`/`install-target-libgomp`
  in `build-gcc.sh` the day one does; Fortran needs it in the plain cross compilers first
  (four compilers rebuilt cold); the image ships the cross GCCs no binutils or sysroot (CON22).
- riscv64 TVM's `llvm` target defaults to LLVM's generic CPU (soft-float, no vector), since
  TVM has no host-CPU default on any arch: name the baseline or `riscv/spacemit-k3`, and
  compile IREE for riscv64 elsewhere with explicit `--iree-llvmcpu-*` flags
  (`docs/riscv64-rva23-baseline.md`, CON24).
- `cargo-audit` and `cargo-deny` stay lane-installed at their `versions.env` pins. Shipping
  them takes per-arch release pins (riscv64 has no release binary), and a lane's
  `cargo install` of a binary cargo did not install then fails, so both lanes' install
  steps would change with it (CON20).
- No `pwsh` in the Linux image: Microsoft ships no riscv64 build, feature parity allows no
  third exemption, and OmniAccelerANT's Pester suite tests Windows modules on the Windows
  runner (CON20).
- No OpenGL in the Windows image (owner decision 2026-09-26, CON25): Server Core has no
  `opengl32.dll`, and the only software one, Mesa's llvmpipe, exists as unsigned
  third-party builds (pal1000/mesa-dist-win). wgpu-linked binaries run on the host, as
  OxidANT's renderer tests do. A lavapipe device would also need an HKLM ICD
  registration, because the loader ignores `VK_DRIVER_FILES` in an elevated process.
- No slim `:winamd64-toolchain` tag (owner decision 2026-09-28, CON26). `:winamd64`'s
  ~54 GB of layers exhaust a stock `windows-2025` runner's `C:` (`hcsshim::ImportLayer …
  not enough space on the disk (0x70)`, BeschleunigerBallett, 2026-07-21); the
  `set-docker-data-root` action, which moves the data root to `D:`, stays the answer for
  every lane. CON12 takes 7.1 GB off the image regardless.
- Windows (CON28): no TAPPAS (upstream supports Ubuntu, Raspberry Pi OS and Yocto only); no
  `cargo-cbuild` (no Windows consumer builds a Rust GStreamer plugin); opus SIMD off on
  both lanes, performance only (arm64's RTCD passes `-mfpu=neon` and `__emit`, which
  clang-cl rejects, and opus's meson gives clang-cl no per-file SSE4.1/AVX2 flags); no
  Windows pyhailort wheel or `hailonet` (no Windows consumer and no Hailo device); no
  `gdkpixbuf` on arm64 (it needs a build-machine `glib-compile-resources`).
