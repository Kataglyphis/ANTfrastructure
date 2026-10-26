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
and neither container script passes `-SkipTidy` (d98fd52d); AccelerANTgine's
clang-tidy step sets `ModuleImportPattern` to `'(?!)'` (93dd496).
`Clear-UnreachableSccacheEndpoint` stays: it is a no-op without an endpoint and
still guards a host whose own environment names an unreachable one.
`:winamd64-rocm` still bakes `VOLUME C:\workspace` until its next build (CON34).

## Checked 2026-10-23 — closures from the merged review

These records use the immutable Linux index observed on 2026-10-22,
`sha256:3c558d8828553ea2e3feedb97c99e15bb89a0820c6a056813876da4cd968d92c`
(image hub revision `c819278171c47b9c6462dcc239377808b324476e`). They do not assert
the present value of `:latest` or the state of a later GPU image.

- **CON149, Omni's local fallback fonts: closed.** `web/flutter_bootstrap.js` sets
  `fontFallbackBaseUrl`, and the web lane stages the locked fonts and requires
  `CHECK_FALLBACK_FONTS=1`. The actual Rust-Wasm/Flutter-WASM release check proved
  all 18 local fonts, 36 browser checks and 127 file requests. The changes are merged
  in [OmniAccelerANT PR48](https://github.com/Kataglyphis/OmniAccelerANT/pull/48).
  This closes the visitor's fallback-font download gap; image preloading without
  build-time font downloads remains CON147.
- **CON90/CON95, the old default-image baseline: superseded.** The recorded default
  image and x64 consumer runs use source-built Python 3.15 and chain ORT 1.31.0.
  WebDavClient and OrchestrANT have standalone sdist-to-wheel installation proofs;
  AccelerANTgine's binding checks and the real OrchestrANT bundle also pass there.
  The latter proves the chain wheel's DirectURL, CPU import and model self-tests.
  These packaging proofs do not establish every consumer's free-threaded leg.
  ROCm, per-ABI foreign-wheel verdicts, ARM PGO and the four-core timing remain open.
- **CON129, the x64 consumer blocker: closed.** OxidANT's mandatory GTK feature is
  enabled. Source run `39865676735` on `920ca1b7` passed 728 normal and 728 instrumented
  tests, none ignored, with real Xvfb/GTK and all unchanged coverage floors.
  Foreign arches and GPU-variant image verdicts remain CON129.
- **CON144's cleanup defects: closed separately from its host investigation.** Chrome
  startup failures and normal shutdown reap the process group before bounded profile
  removal; all callers await cleanup and failures remain fatal. The startup, cleanup
  and caller regressions passed in the full Hub suites and registered mutations.
  This does not explain the other build host's earlier HTTP-network-service stall.
  The mechanism is in [docs-sites.md](docs-sites.md#the-sidebar-toggle-check).

## Deliberate — not gaps

These are recorded so nobody files them as gaps:
- No TensorRT SDK in any published image: only the runtime `.so`/`.dll` files its SLA names
  distributable. Headers, dev links, `trtexec`, Python bindings and SDK trees stay in build stages;
  `check_gpu_runtime`, `deepstream-verify.sh` and the Windows smoke fail an image that carries one
  (owner, 2026-10-21: "Rausnehmen"; [`linux-accelerator-images.md` § Redistribution](linux-accelerator-images.md#redistribution)).
- nvidia's cross stages push to the private `kataglyphis_beschleuniger-stages` package, not the public
  one (owner, 2026-10-21: "Auf privat stellen"; [§ Stage images](linux-accelerator-images.md#stage-images-a-private-package)).
- The distro `libgstreamer*-dev` packages are purged.
- Only the pinned CPython (`PYTHON_VERSION`), once with the GIL and once free-threaded (owner,
  2026-10-20).
- The hub's own CI keeps the runner's Python: the preflight and mutation shards on `/usr/bin/python`,
  `stale-docs-check.yml`, `consumer-inventory.yml` and `sbom.yml` on `actions/setup-python` at
  `versions.env`'s X.Y, `llm-stack-serving.yml` on the runner's `python3` (owner, 2026-10-20: not the
  image, whose pull would cost ~13 GB and ~10 min on every hub push; was CON125).
- The exception: `develop-red.yml` runs on `actions/setup-python` at `versions.env`'s X.Y, a ~3 s
  download each run, not the image and not an `actions/github-script` port (owner, 2026-10-20).
- cmake-format stays at 0.6.13, its last release (2020-08-19), with `lib/cmakelang-py315.py`'s
  lexer patch for CPython 3.15 (owner, 2026-10-20: keep, do not replace). Re-open only when a
  later Python breaks the patch.
- The CUDA arch set is `86;87;89;120`, with no PTX.
- riscv64 is built for the RVA23 baseline.
- riscv64 uses the distro CMake 4.2.3.
- riscv64's GStreamer runs on Ubuntu's GLib: `yield_older_prefix_glib` drops the prefix's GLib when it is
  older than the distro's (2.86.3 vs 2.88.0), which GTK 4 4.22.4 and PyGObject need, as amd64 and arm64
  already do (owner, 2026-10-20: not a rebuilt GLib; CON129).
- riscv64 has no IREE compiler, no `ml-ai` extra, no Flutter, appimagetool,
  Flatpak runtimes or Hailo, because upstream ships none for it.
- riscv64 has no hadolint: upstream ships no riscv64 binary, and its QEMU source build cost about two
  hours a chain (owner, 2026-10-26: amd64 only for now; was CON151,
  [§ shellcheck and hadolint](consumer-image-contract.md#shellcheck-and-hadolint)).
- riscv64 has no pwsh and no PSScriptAnalyzer: PowerShell publishes no riscv64 build, so tests
  that drive pwsh skip there with their reason, `pwsh is not on PATH` (CON131).
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
- `cargo-audit` and `cargo-deny` stayed lane-installed at their `versions.env` pins until
  CON65 (owner rule 2026-10-06: what a lane needs goes into the image). Both reasons were
  met, not waived: the image takes per-arch release pins and skips riscv64, which has no
  release binary and no lane that runs them, and the hub's `cargo_install_pinned` keeps a
  lane from `cargo install`ing over a binary cargo did not install
  ([`consumer-image-contract.md` § The cargo QA tools](consumer-image-contract.md#the-cargo-qa-tools); CON20, CON65).
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
