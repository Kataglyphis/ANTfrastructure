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
**CON11 shipped 2026-09-29** (`:latest` index `sha256:696642b2…`); what the consumers still
have to do is CON37.

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [ ] **CON37 — Consumers retire the workarounds `:latest` made unnecessary** [M, ★★].
      CON11 shipped on 2026-09-29: `:latest` is index `sha256:696642b2…` (amd64 `e1bc35af…`,
      arm64 `116cd03c…`, riscv64 `b3d0919d…`), built at 53c1d502. Proven in the published
      children as uid 1001 through the entrypoint, amd64 native and arm64/riscv64 under QEMU:
      - API 37 (`platforms/android-37.0`, `build-tools/37.0.0`) on all three (CON14);
      - `clang-tidy`, `llvm-profdata`, `llvm-cov`, `llvm-nm`, `llvm-symbolizer`, `llvm-objdump`
        and `ld.lld` are 23.1.1, `clang-format` 21.1.8 (CON15);
      - a bare `clang++` selects `/opt/gcc-16.2.0` (CON16);
      - an ASan fuzz target links, runs and finds a planted crash, and atheris' probe
        resolves (CON17);
      - `VIRTUAL_ENV` and `UV_PYTHON` unset (CON18), `llvmpipe` as a CPU Vulkan device (CON19);
      - `perf`, `jq`, `xvfb-run` and `libprofiler.so` (CON20);
      - no distro `libgstreamer1.0-0` on amd64, kept on arm64/riscv64 as § Deliberate says (CON21);
      - `smoke-torch-venv.sh`: `PASS tvm codegen` on all three (CON35);
      - `/opt/gcc-16.2.0` at 1.4 GB on amd64 (CON36);
      - `sanitizer/common_interface_defs.h` and `-print-multiarch` on arm64/riscv64 (CON7, CON8);
      - `import hailo_platform` 5.4.0 on amd64 and arm64.
      - the consumers' `Linux arm64 · build + test` re-ran green on it the same day:
        AccelerANTgine run 36568033223 (its `gcc` job compiles abseil with ASan, CON7) and
        BeschleunigerBallett run 36580604128 (all nine jobs, both GNU presets find X11, CON8).
      - OmniAccelerANT (2026-09-29, its native, android and web lanes run locally on the published
        amd64 child): no injected `--gcc-toolchain`, compileSdk 37 and no
        `permission_handler_android` pin. API 37 also needed a Cargokit patch: AGP reports
        `android-37.0`, which upstream Cargokit's `substring(8) as int` cannot parse.

      The media lanes first died in GenAI's G2 on a bare `/` record token (53c1d502).

      Left for the consumers, one commit each, proven by the consumer's own lane:
      - The injected `--gcc-toolchain` goes (BeschleunigerBallett, AccelerANTgine).
      - WebDavClient and OrchestrANT drop their `unset VIRTUAL_ENV UV_PYTHON` lines, and
        WebDavClient its Python 3.13 pin for atheris.
      - OxidANT's Pi runners drop `--entrypoint` (CON23), and OxidANT sets `KATAGLYPHIS_REQUIRE_GPU=1`.
      - BeschleunigerBallett drops its GPU-suite exclusions (CON19).
      - `riscv64` ships no `clang-format` (none on `PATH`); nothing in the fleet lints on riscv64 today.
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

None open. CON15–CON21, CON35 and CON36 shipped with CON11 on 2026-09-29 (CON37 has the proof).

## Open — Linux arm64 and riscv64

None open. CON7, CON8 and CON23 shipped with CON11 on 2026-09-29 (CON37 has the proof).

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
