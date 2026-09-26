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

## Protocol

The agentic loop's format (`docs/windows-agentic-loop.md`):

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★, as in the refactoring backlog.

## Open — getting fixes to consumers

- [b] **CON11 — Republish the Linux `:latest`** [S, ★★★]. Blocked on the owner, because
      a push is the owner's call. These fixes are in source and in no published image:
      - CON7: libsanitizer in the arm64/riscv64 GCC (e2de5852).
      - CON8: multiarch in the arm64/riscv64 GCC (2026-09-25).
      - CON14: API 37, behind a cache id that finally names it (2026-09-26).
      - CON15–CON21, CON23 and CON36: the toolchain, Python, Vulkan, tool, libcamera and
        strip fixes of 2026-09-26. `docs/consumer-image-contract.md` § What changes with the image
        after CON11 lists them for consumers.
      - pyhailort: a real module instead of the empty one
        (889417c7/0ef22316; `docs/hailo-support.md`).

      Afterwards:
      - Re-run AccelerANTgine's `Linux arm64 · build + test`. Its `gcc` job must
        compile abseil with ASan.
      - Re-run BeschleunigerBallett's `Linux arm64 · build + test`. Both GNU presets
        must find X11.
      - Check `platforms/android-37.0` in the image, then drop OmniAccelerANT's
        `permission_handler_android` pin.
      - Check that `import hailo_platform` works on amd64 and arm64.
      - Retire the consumer workarounds the contract table names: the injected
        `--gcc-toolchain` (BeschleunigerBallett, OmniAccelerANT, AccelerANTgine), the
        `unset VIRTUAL_ENV UV_PYTHON` lines (WebDavClient, OrchestrANT), the Pi runners'
        `--entrypoint` bypass (OxidANT), WebDavClient's Python 3.13 pin for atheris and
        BeschleunigerBallett's GPU-suite exclusions. OxidANT sets `KATAGLYPHIS_REQUIRE_GPU=1`.

      `versions.env` and `01-core` changed after the published image's commit
      (7a43905a), so the chain rebuilds from base anyway; none of the above adds a re-key.
- [b] **CON12 — Republish `:winamd64`** [M, ★★★]. Blocked on the owner. The published
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
      CON29 (no baked `C:\workspace`), and 7.1 GB less image, because the patched LLVM's
      source and Ninja tree no longer stay in its layer. `versions.env` changed after
      0d85b8c1, so the chain rebuilds from base anyway.

      The first local rebuild (2026-09-26) found one more: with Blackwell in the arch set,
      ORT's LLM kernels compile as PTX only on MSVC, and sccache 0.18 aborts those nvcc
      compiles (mozilla/sccache#2862). ORT's nvcc now stays bare for such an arch list.

      After the rebuild, grade the ENV gate (`Assert-ImageEnvPublishable`) and the
      G6 census. Then run one DirectML G-API session, set BeschleunigerBallett's
      ClangCL coverage back ON and drop its container `-SkipTidy` (CON9, CON10), and
      let AccelerANTgine tidy every `Src/` TU.
- [b] **CON13 — Retire `:latest-cross` for good** [S, ★]. Blocked on the owner. Consumer
      CI no longer depends on it: since 2026-09-25 the fleet calls this hub at
      `@develop`, whose `versions.env` names `:latest` (AGENTS.md § Image and tag
      naming). `main` still names `:latest-cross`, and the two tags are one GHCR
      version. Make the old name a version of its own first, then delete it;
      `ghcr-delete-tags.sh` refuses the unsafe order.
- [b] **CON14 — API 37 reaches the image** [S, ★★]. Blocked on CON11. Root cause
      (2026-09-26): `Dockerfile.android`'s `android-sdk-shared` cache id never named the
      two API 37 pins, so every build after 2bb0410f restored the SDK tree cached on
      2026-08-22, skipped the install, and passed a smoke that checked build-tools 36
      only. Fixed in source:
      - the id names every pin in `android-sdk.sh`'s `sdk_components`, and
        `tests/test-android-sdk-cache-key.sh` holds it (it names the two pins against
        the old Dockerfile);
      - a restored tree is checked against the list by the paths sdkmanager records in
        each `package.xml`: what it lacks is installed and the cache refreshed
        (`android-sdk shared cache STALE`), and any package still missing fails the stage;
      - `smoke-android.sh` checks every platform and the extra build-tools.

      Proven in a container on `ec4bb68b`'s own stale tree: STALE, install, refresh,
      then a clean HIT with `android-37.0` and `37.0.0`.

## Open — Linux image (all arches)

- [b] **CON15 — The LLVM tools on PATH are clang's own** [S, ★★]. Blocked on CON11.
      Measured on `ec4bb68b`: `clang` is 23.1.1, but `clang-tidy`, `llvm-profdata`,
      `llvm-cov`, `llvm-nm`, `llvm-symbolizer`, `llvm-objdump` and `ld.lld` resolve to LLVM
      21. Fixed in source (2026-09-26): `setup-package-image.sh` `wire_clang_llvm_tools`
      links 21 of clang's own tools into `/usr/local/bin`, ahead of `/usr/bin`, and
      `validate-compilers.sh smoke` fails a tool that is not clang's version. Decided:
      `clang-format` stays 21, since its version is a formatting verdict the fleet pins
      (AccelerANTgine keeps 21), and so does `llvm-config`, since llvm-target's libLLVM is
      not all-targets (CON35). `lib/compiler-llvm-tools.sh` stays for older images.
- [b] **CON16 — A bare `clang++` selects the image's GCC** [S, ★★]. Blocked on CON11.
      Measured: `Selected GCC installation: /usr/lib/gcc/x86_64-linux-gnu/16`, and linking
      the chain ONNX Runtime fails on undefined `std::format` symbols. Fixed in source
      (2026-09-26): `write_clang_gcc_toolchain_cfg` puts `<native-triple>-clang.cfg` and
      `-clang++.cfg`, holding `--gcc-toolchain=${GCC_PREFIX}`, beside the compiler. Clang
      reads them for a native build only; a `--target` build loads neither. Proven on
      `ec4bb68b`: `/opt/gcc-16.2.0` selected, and the ORT program links and runs. The
      smoke fails a bare `clang++` that selects anything else.
- [b] **CON17 — The image's clang ships libFuzzer** [S, ★★]. Blocked on CON11.
      `llvm-cross.sh` had `COMPILER_RT_BUILD_LIBFUZZER=OFF` with no stated reason. Fixed in
      source (2026-09-26): ON, with `COMPILER_RT_USE_LIBCXX=OFF`, so no private-libc++
      ExternalProject rides a cross build. Proven by building compiler-rt 23.1.1 with those
      options and the image's clang: an ASan fuzz target links and finds a planted crash,
      and atheris' probe (`-print-file-name=libclang_rt.fuzzer_no_main.a`) resolves. The
      smoke links and runs a fuzz target.
- [b] **CON18 — `VIRTUAL_ENV` and `UV_PYTHON` no longer point uv at `/opt/venv`**
      [S, ★★]. Blocked on CON11. Fixed in source (2026-09-26): `Dockerfile.torch` empties
      both, because Docker cannot unset what the toolchain stage exported and uv reads empty
      as unset, and the entrypoint unsets them; `/opt/venv/bin` stays first on PATH.
      Measured on `ec4bb68b`: an activated venv's `uv pip install` went to `/opt/venv`
      before and lands in the venv after. uv 0.12's plain `uv sync` already used the
      project's `.venv`.
- [b] **CON19 — A software Vulkan device** [S, ★★]. Blocked on CON11. Fixed in source
      (2026-09-26): `mesa-vulkan-drivers` in the package stage. Measured on `ec4bb68b`: the
      runtime user sees `llvmpipe` as a CPU device. Afterwards OxidANT sets
      `KATAGLYPHIS_REQUIRE_GPU=1` and BeschleunigerBallett drops its GPU-suite exclusions.
- [b] **CON20 — Tools a consumer needs** [S each, ★]. Blocked on CON11 for four of the
      six. `linux-perf` (26.04 moved `perf` there, out of `linux-tools`), gperftools
      (`libgoogle-perftools-dev`), `jq` and `xvfb` join the package stage (2026-09-26,
      measured working on `ec4bb68b`; `perf stat` counts in a container). They unblock
      AccelerANTgine's profile lane and `-pg` fallback, BeschleunigerBallett's and this
      hub's `python3` JSON reads, and OmniAccelerANT's first-frame check. `cargo-audit`,
      `cargo-deny` and `pwsh` are decisions in § Deliberate.
- [b] **CON21 — The distro GStreamer runtime beside `/opt/gstreamer`** [S, ★]. Blocked on
      CON11. What pulls it in: Ubuntu's `libgtk-4-1`, which `install-deps.sh` adds after it
      purges the distro GStreamer. Fixed in source for amd64 (2026-09-26):
      `drop_redundant_distro_gtk4` purges the five packages when `/opt/gstreamer` carries its
      own GTK 4, and keeps them with a warning if anything else would go with them. Measured
      on `ec4bb68b`: the registry (308 plugins, 1601 features), `gtk4paintablesink` and
      OpenCV's GStreamer backend are unchanged. arm64 and riscv64: § Deliberate.
- [ ] **CON35 — amd64's TVM cannot generate code** [S–M, ★★]. `libtvm_compiler.so` was
      linked against an all-targets `libLLVM.so.23.1`, and at run time the loader finds
      `/usr/local/llvm-target/lib`'s x86-only copy first (`copy-media-payloads.sh`):
      `undefined symbol: LLVMInitializeAArch64TargetInfo`. `tvm/base.py` then falls back to
      the runtime silently, so `tvm.target.Target` does not exist and nothing fails loudly.
      riscv64 is unverified. Found 2026-09-26 in the CON24 sweep. Close by resolving
      `libtvm_compiler.so` against the LLVM it was built with (RUNPATH or a staged copy),
      with a smoke that compiles one PrimFunc.
- [b] **CON36 — amd64's GCC carries 4.4 GB of unstripped cross compilers** [S, ★].
      Blocked on CON11. `/opt/gcc-16.2.0` is 4.9 GB, and 52 of its 99 x86-64 binaries are
      unstripped: the `aarch64-` and `riscv64-linux-gnu` compilers' (their `cc1plus` 444 and
      534 MB). `build-gcc.sh` stripped with `${TARGET_TRIPLET}-strip` alone, which cannot read
      an x86-64 executable, and swallowed the error. Fixed in source (2026-09-26): the build
      machine's `strip` runs too. Proven on `ec4bb68b`: the new step takes `/opt/gcc-16.2.0`
      from 4.9 to 1.4 GB, and the cross and host compilers still compile. Found in the
      CON22 sweep.

## Open — Linux arm64 and riscv64

- [b] **CON7 — The arm64/riscv64 native GCC has no libsanitizer** [S, ★★]. Blocked on
      CON11.
      - Symptom: AccelerANTgine's `Linux arm64 · build + test` `gcc` job, runs
        36045732850 and 36052808210, fails at
        `absl/base/internal/dynamic_annotations.h:369:10: fatal error:
        sanitizer/common_interface_defs.h: No such file or directory`. The `clang`
        job passes.
      - Fixed in source by e2de5852 (committed 2026-09-24):
        `_gcc_extra_target_libs` in `linux/scripts/02-toolchain/build-gcc.sh`; see
        [`cross-build-verification.md` § The native GCC ships libsanitizer](docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer).
      - riscv64 has the same defect. No riscv64 consumer lane exercises it.
- [b] **CON8 — On arm64, CMake with the image's GCC does not find libX11** [M, ★★].
      Blocked on CON11.
      - Symptom: BeschleunigerBallett's `Linux arm64 · build + test` (run
        36042437555). Both GNU 16.2.0 presets stop at `Could NOT find X11 (missing:
        X11_X11_LIB)`, while the same run's Clang 23.1.1 preset prints
        `Found X11: /usr/include`.
      - Cause, measured 2026-09-25 in `:latest` `ec4bb68b` under qemu: the arm64
        Canadian-native GCC prints no `-print-multiarch`, its implicit link dirs
        hold no `/usr/lib/aarch64-linux-gnu`, and CMake leaves
        `CMAKE_LIBRARY_ARCHITECTURE` empty. `--with-native-system-header-dir`
        switches GCC's multiarch auto-check off. amd64's full-make GCC prints
        `x86_64-linux-gnu`.
      - Fixed in source (2026-09-25): `_gcc_native_multiarch` in
        `linux/scripts/02-toolchain/build-gcc.sh` passes `--enable-multiarch` to the
        Canadian native, and `swap-native-gcc.sh` refuses a GCC that prints another
        triplet; see
        [`cross-build-verification.md` § The native GCC has multiarch](docs/cross-build-verification.md#the-native-gcc-has-multiarch).
      - riscv64 has the same defect. No riscv64 consumer lane exercises it.
- [b] **CON23 — A Raspberry Pi run with the host's libcamera needs no bypass** [M, ★].
      Blocked on CON11. The image's upstream libcamera 0.7.2 still cannot drive Pi cameras,
      so the host swap stays, but its two traps are fixed in source (2026-09-26):
      - `libcamera-env.sh` appends the image's libcamera after whatever the caller set,
        instead of prepending it;
      - the entrypoint puts `${GCC_PREFIX}`'s runtime ahead of a caller's
        `LD_LIBRARY_PATH`. `GLIBCXX_3.4.36 not found` was reproduced and fixed on amd64,
        with the distro libstdc++ standing in for a Pi host's.

      Afterwards the Pi runners drop `--entrypoint` (OxidANT `run-producer-pi.sh`,
      OmniAccelerANT `camera-streaming.md`).

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
- [b] **CON26 — `:winamd64` does not fit a stock `windows-2025` runner** [M, ★★].
      Blocked on an owner decision.
      - The ~54 GB of layers exhausted `C:` (`hcsshim::ImportLayer … not enough
        space on the disk (0x70)`, BeschleunigerBallett, root-caused 2026-07-21).
      - The `set-docker-data-root` action moves the data root to `D:` and is the
        documented workaround.
      - BeschleunigerBallett proposes a slim `:winamd64-toolchain`
        (`-Stages base,sdk,toolchain`, no `-Gpu`) for lanes that need no
        media/ML stack.
      - CON12 takes 7.1 GB off the image: the patched LLVM's source and Ninja tree no
        longer stay in its layer (found 2026-09-26).
- [b] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. Blocked upstream (checked 2026-09-26): microsoft/STL#6294
      is open, its fix #6298 awaits review, and neither 14.52 nor 14.53 Preview carries it.
      The toolset is VS 18's stable channel, not a pin that could move.
      BeschleunigerBallett's `find_if` stands (a2793e6c). Never set
      `_USE_STD_VECTOR_ALGORITHMS=0` image-wide: it turns every vectorized algorithm off.
      Close when a production toolset ships #6298.
- [ ] **CON28 — Smaller Windows absences** [S, ★]. Swept 2026-09-26:
      - LiteRT Python is fixed in source and ships with CON12. Its exclusion from `uv sync`
        outlived its reason (2.1.3 had no cp314 wheel; the locked 2.1.6 has one). Measured
        in `:winamd64`'s app venv: it installs, and the app smoke passes it (13/15, 0 failed).
      - TAPPAS, `cargo-cbuild`, opus SIMD, Hailo's Windows pyhailort and `hailonet` are
        decided (§ Deliberate).
      - Open: GStreamer's `gdkpixbuf` plugin on amd64: gdk-pixbuf 2.44.6 defaults `man=true` and
        fails without rst2man, so the plugin falls out of auto-features. Pass
        `-Dgdk-pixbuf:man=false` in `Build-GstreamerFromSource.ps1`, as the Linux riscv64
        build does, and prove it with the next merge build (arm64 also needs a
        build-machine `glib-compile-resources`: § Deliberate).
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
- Windows (CON28): no TAPPAS (upstream supports Ubuntu, Raspberry Pi OS and Yocto only); no
  `cargo-cbuild` (no Windows consumer builds a Rust GStreamer plugin); opus SIMD off on
  both lanes, performance only (arm64's RTCD passes `-mfpu=neon` and `__emit`, which
  clang-cl rejects, and opus's meson gives clang-cl no per-file SSE4.1/AVX2 flags); no
  Windows pyhailort wheel or `hailonet` (no Windows consumer and no Hailo device); no
  `gdkpixbuf` on arm64 (it needs a build-machine `glib-compile-resources`).
