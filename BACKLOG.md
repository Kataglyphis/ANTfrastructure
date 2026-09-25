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
      - CON14: API 37.
      - pyhailort: a real module instead of the empty one
        (889417c7/0ef22316; `docs/hailo-support.md`).

      Afterwards:
      - Re-run AccelerANTgine's `Linux arm64 · build + test`. Its `gcc` job must
        compile abseil with ASan.
      - Check `platforms/android-37.0` in the image, then drop OmniAccelerANT's
        `permission_handler_android` pin.
      - Check that `import hailo_platform` works on amd64 and arm64.
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

      After the rebuild, grade the ENV gate (`Assert-ImageEnvPublishable`) and the
      G6 census. Then run one DirectML G-API session.
- [b] **CON13 — Retire `:latest-cross` for good** [S, ★]. Blocked on the owner. Consumer
      CI no longer depends on it: since 2026-09-25 the fleet calls this hub at
      `@develop`, whose `versions.env` names `:latest` (AGENTS.md § Image and tag
      naming). `main` still names `:latest-cross`, and the two tags are one GHCR
      version. Make the old name a version of its own first, then delete it;
      `ghcr-delete-tags.sh` refuses the unsafe order.
- [ ] **CON14 — API 37 is in source but missing from the image built after it** [S, ★★].
      CON5 was closed on 2026-09-18 (2bb0410f: `ANDROID_EXTRA_COMPILE_SDK=37.0`,
      `ANDROID_EXTRA_BUILD_TOOLS=37.0.0`, installed by `android-sdk.sh`). But
      `ec4bb68b`, built 2026-09-22, has no `ANDROID_EXTRA_*` in its ENV, only
      `platforms/android-36` and only `build-tools/36.0.0`. A publish four days
      after the change that lacks it means a stale stage, not an unpublished fix.
      Find which Android layer the 2026-09-22 chain reused and why the key did not
      move, before CON11 publishes the same way. Consumer:
      OmniAccelerANT's `pubspec_overrides.yaml` pins `permission_handler_android`
      13.0.1 (Dependabot #43 blocked).

## Open — Linux image (all arches)

- [ ] **CON15 — The LLVM tools on PATH are LLVM 21; the compiler is LLVM 23** [S, ★★].
      Measured:
      - LLVM 23.1.1 (`/usr/local/llvm-target`): `clang`, `clang++`, `llvm-ar`.
      - LLVM 21.1.8 (`/usr/lib/llvm-21`): `clang-tidy`, `clang-format`,
        `llvm-profdata`, `llvm-cov`, `llvm-nm`, `llvm-symbolizer`, `ld.lld`.

      LLVM 23's own copies sit unused in `/usr/local/llvm-target/bin`, and a
      distro LLVM 22 is installed as well. Failures it caused:
      - BeschleunigerBallett coverage: `no profile can be merged` (2026-09-24).
      - AccelerANTgine clang-tidy refused all 18 `Src/` PCMs.

      Workaround: `lib/compiler-llvm-tools.sh`. Close by registering the rest in
      `register-llvm-alternatives.sh`. Decide `clang-format` on purpose, because a
      version change reformats the fleet (AccelerANTgine keeps 21 today).
- [ ] **CON16 — A bare `clang++` links against the distro GCC, not `/opt/gcc-16.2.0`**
      [S, ★★]. Measured: `Selected GCC installation: /usr/lib/gcc/x86_64-linux-gnu/16`.
      A trivial link works. Linking against the image's own GCC-16.2.0-built
      libraries fails (OmniAccelerANT `docs/source/platforms.md`: bare `clang` →
      `linker command failed`). So BeschleunigerBallett, OmniAccelerANT and
      AccelerANTgine each inject `--gcc-toolchain` (via `GCC_PREFIX` or
      `gcc_toolchain_prefix()`). The replacement this hub named for its deleted
      helper, `/usr/local/bin/clang-<arch>`, does not exist in the image. Close by
      shipping `clang.cfg`/`clang++.cfg` beside the compiler with
      `--gcc-toolchain=/opt/gcc-16.2.0`, or the wrappers.
- [ ] **CON17 — The image's clang has no libFuzzer runtime** [S, ★★].
      `llvm-cross.sh:201` sets `COMPILER_RT_BUILD_LIBFUZZER=OFF` with no stated
      reason. The only `libclang_rt.fuzzer*` in the image belong to the distro LLVM
      21 and 22. Effect: WebDavClient's atheris source build fails (`Failed to find
      libFuzzer`; last success was run 31823466662, 2026-08-14), so its lanes are
      pinned to Python 3.13 wheels. Any `-fsanitize=fuzzer` link with `clang` fails
      the same way. Close by building it, or by writing down why it is off.
- [ ] **CON18 — `VIRTUAL_ENV` and `UV_PYTHON` point every uv call at a root-owned venv**
      [S, ★★]. Measured: `VIRTUAL_ENV=/opt/venv`, `UV_PYTHON=/opt/venv/bin/python`,
      and `/opt/venv` is `root:root 755`. uv honours `UV_PYTHON` over an activated
      venv, so a uid-1001 `uv sync` or `uv pip install` dies with `Permission
      denied`. Four workarounds exist:
      - OrchestrANT (`ci_static_analysis.sh`).
      - WebDavClient (`unset VIRTUAL_ENV UV_PYTHON`, "drop this when upstream lands").
      - AccelerANTgine's `--python .venv/bin/python` pin.
      - This hub's own drivers (`docs/python-ci.md`).

      Close by not exporting the two, and keeping `/opt/venv/bin` on PATH.
- [ ] **CON19 — No software Vulkan device** [S, ★★]. Measured: `/etc/vulkan/icd.d/`
      holds only `nvidia_icd.json`. Effects:
      - OxidANT's ~40 headless golden tests self-skip and report passed
        (OxidANT BACKLOG, "Give CI a GPU adapter").
      - BeschleunigerBallett excludes its GPU suites by name.

      Close with `mesa-vulkan-drivers` (lavapipe). OxidANT then sets
      `KATAGLYPHIS_REQUIRE_GPU=1`.
- [ ] **CON20 — Tools a consumer needs that no image ships** [S each, ★].
      | Tool | Consumer and workaround |
      | --- | --- |
      | `perf` (`linux-perf`; 26.04's `linux-tools-common` has none) | AccelerANTgine's profile lane warns and runs a 10 s smoke window (run 35921977662, exit 127) |
      | gperftools `libprofiler` | AccelerANTgine's configure falls back to `-pg` |
      | `jq` | BeschleunigerBallett and this hub read JSON with `python3` |
      | `Xvfb` | OmniAccelerANT's first-frame check stays blocked |
      | `pwsh` | OmniAccelerANT runs its Pester suite in a separate job on the runner |
      | `cargo-audit`, `cargo-deny` (Linux and Windows) | built from source every run: this hub's `windows/scripts/rust/Build-Windows.ps1:136-137`, OxidANT's Windows driver |

      A tool with no consumer left is not a gap. Close each by adding it to the
      image or by recording a decision here.
- [ ] **CON21 — A distro GStreamer runtime sits beside `/opt/gstreamer`** [S, ★].
      Measured: the ld.so cache lists both
      `/usr/lib/x86_64-linux-gnu/libgstreamer-1.0.so.0` and the `/opt/gstreamer`
      copy (`/opt/gstreamer` sorts first). `ldd`-based bundling can pick the distro
      one; OmniAccelerANT resolves DT_NEEDED against pkg-config for that reason.
      Find what pulls the runtime in, and drop it or document it.

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
- [ ] **CON8 — On arm64, CMake with the image's GCC does not find libX11** [M, ★★].
      - Symptom: BeschleunigerBallett's `Linux arm64 · build + test` (run
        36042437555). Both GNU 16.2.0 presets stop at `Could NOT find X11 (missing:
        X11_X11_LIB)`, while the same run's Clang 23.1.1 preset prints
        `Found X11: /usr/include`.
      - amd64 is fine. Measured 2026-09-25, GCC and clang both derive
        `CMAKE_LIBRARY_ARCHITECTURE=x86_64-linux-gnu` and find `libX11.so`.
      - **Hypothesis, unverified:** arm64's `cc` is the Canadian-native GCC, whose
        implicit link directories give CMake no multiarch directory.
        `01-core/cross-meson.sh` already sets `CMAKE_LIBRARY_ARCHITECTURE` by hand
        for this hub's own builds.
      - First step: in the arm64 image, configure the two-line probe
        (`project(p C)` plus `message(STATUS "${CMAKE_LIBRARY_ARCHITECTURE}")`)
        with `CC=gcc` and with `CC=clang`, and read `gcc -print-search-dirs`.
- [ ] **CON22 — The arm64/riscv64 GCC toolchains are thinner than amd64's** [M, ★].
      - The arm64 and riscv64 GCCs lack libgomp (`omp.h`), libitm and gfortran,
        so `-fopenmp` and Fortran fail with the image's `cc`.
      - amd64's plain cross compilers have no target `libasan`.
      - Both are recorded as out of scope in
        `docs/cross-build-verification.md`. Close by building them, or by moving
        them to § Deliberate.
- [ ] **CON23 — The image's upstream libcamera cannot drive Raspberry Pi cameras** [M, ★].
      - The image ships libcamera 0.7.2 (measured) and libpisp 1.5. A Pi 5 on
        kernel 6.18 needs the renamed `rp1-cfe` entities and libpisp 1.7: no CFE
        match, then an IPA segfault.
      - On VC4/unicam Pis (Zero 2 W, Pi 4) the isolated IPA worker dies with
        `Failed to call start: -110`.
      - Consumers bind-mount the host's Raspberry Pi OS libcamera over the image's
        (OxidANT `scripts/linux/cat-stream/run-producer-pi.sh`, OmniAccelerANT
        `docs/source/camera-streaming.md`). The swap then trips two more traps:
        - The entrypoint sources `libcamera-env.sh`, which re-prepends
          `/opt/libcamera/lib` over any `LD_LIBRARY_PATH` (measured:
          `entrypoint.sh:30`), so the runner bypasses it with `--entrypoint`.
        - A host `LD_LIBRARY_PATH` shadows GCC 16.2's libstdc++, and the ONNX
          Runtime then fails with `GLIBCXX_3.4.36 not found` unless
          `/opt/gcc-16.2.0/lib64` comes first. Without the override `ld.so.conf`
          resolves it: measured on amd64.
      - Close by shipping the Raspberry Pi libcamera and libpisp on arm64, or by
        making `libcamera-env.sh` respect a caller's `LD_LIBRARY_PATH`.
- [ ] **CON24 — riscv64: TVM and IREE emit no vector (RVV) code** [L, ★]. Their shipped
      compilers generate code at run time, so this needs a codegen-target change,
      not a flag. It has been open since 2026-09-02
      (`docs/riscv64-rva23-baseline.md`, which used to point at the refactoring
      backlog, where it was never carried). The documented riscv64 absences are
      listed under § Deliberate.

## Open — Windows `:winamd64`

- [ ] **CON9 — The patched LLVM ships no `clang_rt.profile`** [M, ★].
      - `windows/scripts/build/Build-LlvmFromSource.ps1` sets
        `COMPILER_RT_BUILD_PROFILE=OFF` ("profile fails to compile under
        clang-cl"). So `cmake/Tests.cmake` stops any clang-cl coverage configure
        (`Coverage was requested, but the clang-cl profile runtime is missing`, run
        36042436962).
      - BeschleunigerBallett's ClangCL presets run with coverage OFF since
        2026-09-24.
      - Close by re-diagnosing the compile failure, building the runtime, and
        setting BeschleunigerBallett's `myproject_ENABLE_COVERAGE` in
        `x64-ClangCL-Windows-Base` back to ON.
- [ ] **CON10 — The patched LLVM ships no clang-tidy** [M, ★★].
      - The same script's `LLVM_ENABLE_PROJECTS=clang;lld` builds no
        `clang-tools-extra`, and a foreign clang-tidy cannot read its BMIs
        (AccelerANTgine run 36008508666: `module file '…pcm' built from a
        different branch () than the compiler`).
      - AccelerANTgine now tidies only its six self-contained `.ixx` interfaces.
        BeschleunigerBallett's container builds hard-code `-SkipTidy` and tidy only
        on the host.
      - Close by adding `clang-tools-extra` (a longer LLVM build), then checking
        that both consumers' tidy steps use it on every TU.
- [ ] **CON25 — Server Core has no OpenGL and, outside rocm, no Vulkan loader**
      [M, ★★]. There is no `opengl32.dll`:
      - Every wgpu-linked binary exits `0xc0000135` before `main`. OxidANT
        therefore builds its renderer tests in the container and runs them on the
        runner host (runs 36019995362, 36038436509), and never launches its GUI
        configurations.
      - `gsthip` cannot load (`gstgl-1.0-0.dll` imports `OPENGL32.dll`).

      `vulkan-1.dll` ships only in `Dockerfile.rocm` (`docs/windows-rocm.md`), so
      gstvulkan, IREE's Vulkan HAL, OpenCV vkcom and ggml-vulkan cannot load in the
      default or nvidia image. Close by adding the loader to the default image and
      deciding on a software OpenGL (Mesa llvmpipe as an app-local
      `opengl32.dll`), or by recording that these stay host-only.
- [b] **CON26 — `:winamd64` does not fit a stock `windows-2025` runner** [M, ★★].
      Blocked on an owner decision.
      - The ~54 GB of layers exhausted `C:` (`hcsshim::ImportLayer … not enough
        space on the disk (0x70)`, BeschleunigerBallett, root-caused 2026-07-21).
      - The `set-docker-data-root` action moves the data root to `D:` and is the
        documented workaround.
      - BeschleunigerBallett proposes a slim `:winamd64-toolchain`
        (`-Stages base,sdk,toolchain`, no `-Gpu`) for lanes that need no
        media/ML stack.
- [ ] **CON27 — MSVC STL 14.51 breaks `find`/`count`/`remove` on odd-sized structs
      under clang-cl** [S, ★]. The image's toolset enables its vectorized path for
      any type clang calls trivially equality-comparable, then `static_assert`s
      (`unexpected size`) unless the type is 1, 2, 4 or 8 bytes. This is an
      upstream bug, microsoft/STL#6294, still open. BeschleunigerBallett run
      36052511207 hit it (a2793e6c works around it with `find_if`). Watch the
      issue. Close when a toolset with the fix ships in the image.
- [ ] **CON28 — Smaller documented Windows absences** [S–M each, ★].
      - No LiteRT Python bindings (`ai-edge-litert` excluded from `uv sync`;
        `docs/windows-builds.md`).
      - Hailo is runtime-only: no TAPPAS, no pyhailort wheel, no `hailonet`.
      - GStreamer's optional `gdkpixbuf` plugin and anything needing
        `cargo-cbuild` are absent.
      - opus SIMD intrinsics are off on both lanes (performance only).
      - Each is a decision to record or work to do; none blocks a consumer lane
        today.
- [ ] **CON29 — The baked `VOLUME C:\workspace` is a mount trap** [S, ★]. Binding over
      a directory that exists in the image fails at `hcs::CreateComputeSystem`
      when the host and image OS builds differ, so every consumer mounts at
      `C:\ws` or `C:\ws-mnt` (documented in `docs/windows-builds.md`). Close by
      dropping the `VOLUME`/`WORKDIR` pair, or by leaving it and moving this item to
      § Deliberate.

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
- [ ] **CON34 — The rocm image's HIP/MSVC `<cmath>` overlay is installed by the llama
      stage, not by `Dockerfile.rocm`** [S, ★]. MSVC 14.51's `constexpr` `isgreater`
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

## Open — hub scripts out of step with the image

- [ ] **CON32 — `windows/scripts/rust/Build-Windows.ps1:143,150` runs `rustup component
      add`** [S, ★]. The image's rustup is offline: its dist server is a `file://`
      mirror that `Install-RustToolchain.ps1` deletes. rustfmt and clippy are baked
      in instead, so the call can only fail. OxidANT's own driver says "NEVER
      `rustup component add` here" (OxidANT BACKLOG, blocked on this). Replace it
      with a presence check.
- [ ] **CON33 — `Copy-MediaRuntimeBundle` looks for GStreamer where the SDK installer
      puts it, not in `C:\runtime\bin`, where this image builds it** [S, ★].
      AccelerANTgine run 36044940426 staged only the seven ONNX Runtime DLLs and
      missed `gstreamer-1.0-0.dll`, `glib-2.0-0.dll` and three more. AccelerANTgine
      now copies `C:\runtime\bin` itself (`GSTREAMER_BIN` overrides). Teach the
      helper the image's layout.

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
