# Image decisions and closed checks

What the images deliberately do not carry, and gaps that were checked and found closed.
Moved out of the root [`BACKLOG.md`](../BACKLOG.md) on 2026-09-30 so the backlog holds only
open work. Nothing here is a task; re-open an entry only with a new measurement.

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

## Checked 2026-10-01 and closed — CON45's claims hold in the published `:winamd64`

The `:winamd64` published 2026-09-30 (`676980e3…`, hub 18b08cc4) was checked in
throwaway process-isolated containers on the owner's host, with the RX 9070 XT
passed in. Every claim the backlog listed holds:

- `clang_rt.profile-x86_64.lib` is there, and a clang-cl coverage build runs to
  an `llvm-cov` report (CON9).
- `C:\llvm-patched\bin\clang-tidy.exe` (LLVM 23.1.1) reads the BMI of a
  CMake + Ninja `FILE_SET CXX_MODULES` project built with clang-cl (CON10).
- `vulkan-1.dll` resolves first from `C:\vulkan-loader` (CON25).
- `gstgdkpixbuf.dll` registers and `ai-edge-litert` 2.1.6 imports in the app
  venv (CON28).
- The image config has no volume (CON29), and no published Windows tag
  (`:winamd64`, `-nvidia`, `-rocm`, `:winarm64`) names a remote sccache
  endpoint.
- An ORT session (`DmlExecutionProvider`) and an OpenCV G-API ONNX session with
  `cv2.gapi.onnx.ep.DirectML(0)` both run.

The consumer workarounds are gone: BeschleunigerBallett's coverage is ON again
and neither container script passes `-SkipTidy` (31ae0c51); AccelerANTgine's
clang-tidy step sets `ModuleImportPattern` to `'(?!)'` (cab49ae).
`Clear-UnreachableSccacheEndpoint` stays: it is a no-op without an endpoint and
still guards a host whose own environment names an unreachable one.
`:winamd64-rocm` still bakes `VOLUME C:\workspace` until its next build (CON34).

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
  OxidANT's renderer tests do. (Vulkan is the exception since 2026-10-04, CON50: Mesa's
  lavapipe — mmozeiko/build-mesa's unsigned build — ships in `C:\runtime\lavapipe` with
  an HKLM ICD registration, because the loader ignores `VK_DRIVER_FILES` in an elevated
  process, and `LP_NATIVE_VECTOR_WIDTH=256`.)
- No slim `:winamd64-toolchain` tag (owner decision 2026-09-28, CON26). `:winamd64`'s
  ~54 GB of layers exhaust a stock `windows-2025` runner's `C:` (`hcsshim::ImportLayer …
  not enough space on the disk (0x70)`, BeschleunigerBallett, 2026-07-21); the
  `set-docker-data-root` action, which moves the data root to `D:`, stays the answer for
  every lane. CON12 takes 7.1 GB off the image regardless.
- Windows (CON28): no TAPPAS (upstream supports Ubuntu, Raspberry Pi OS and Yocto only); no
  `cargo-cbuild`, although a Windows consumer now uses Rust GStreamer plugins (2026-10-05):
  OmniAccelerANT's WebRTC stream needs gst-plugins-rs's `webrtcsink`/`webrtcsrc` there too, so the image builds
  `rswebrtc` and `rsrtp` itself, with a plain `cargo build` whose cdylibs are the plugin DLLs; cargo-c
  makes C-ABI libraries and `.pc` files, which neither plugin needs
  ([`windows-builds.md` § gst-plugins-rs on Windows](windows-builds.md#gst-plugins-rs-on-windows)); opus SIMD off on
  both lanes, performance only (arm64's RTCD passes `-mfpu=neon` and `__emit`, which
  clang-cl rejects, and opus's meson gives clang-cl no per-file SSE4.1/AVX2 flags); no
  Windows pyhailort wheel or `hailonet` (no Windows consumer and no Hailo device); no
  `gdkpixbuf` on arm64 (it needs a build-machine `glib-compile-resources`).
