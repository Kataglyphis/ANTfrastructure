<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# riscv64 cross lanes: build on amd64, test under QEMU

**Owner decision 2026-10-01 (CON48).** A consumer's riscv64 lane cross-compiles on the
amd64 GitHub runner and runs only the tests under QEMU user-mode. It is the Linux
counterpart of the Windows arm64 hybrid: build fast natively, exercise the target arch
where it matters. A fully emulated riscv64 build was rejected: QEMU riscv64 measured
20-30x slower than native amd64 (cargo installs 87 s / 113 s on amd64 against 1813 s /
3500 s on riscv64, [`consumer-image-contract.md`](consumer-image-contract.md)), which
puts the C++ repos past GitHub's 6 h job limit.

Consumers: OxidANT (the pilot), AccelerANTgine, BeschleunigerBallett. OmniAccelerANT waits:
the riscv64 image carries no Flutter SDK.

## The pieces

| piece | where it runs | what it does |
| --- | --- | --- |
| `.github/actions/setup-riscv64-cross` | runner host | registers QEMU's riscv64 binfmt handler with the `F` flag, builds the sysroot, outputs `docker-args` |
| `linux/scripts/02-toolchain/riscv64-sysroot.sh` | runner host or dev box | exports an allowlist of the family image's riscv64 child into a directory |
| `linux/scripts/lib/riscv64-cross.sh` | inside the amd64 image | `riscv64_cross_env`: compiler wrappers, Cargo, cc-rs, pkg-config, CMake and QEMU settings; fails when riscv64 ELF cannot run |
| `cmake/toolchains/riscv64-linux-gnu.cmake` | CMake | the cross toolchain; `$RISCV64_CMAKE_TOOLCHAIN_FILE` names it |
| `.github/workflows/container-ci-riscv64.yml` | GitHub | the reusable lane: host prep, the action, the compiler cache, one container step |

A consumer lane is one `uses:` onto the reusable workflow and one script that sources the
library:

```bash
antfrastructure_source linux/scripts/lib/riscv64-cross.sh
riscv64_cross_env
cargo test --workspace --locked --target riscv64gc-unknown-linux-gnu   # or:
cmake --preset <one whose toolchainFile is $env{RISCV64_CMAKE_TOOLCHAIN_FILE}> && cmake --build ... && ctest
```

A **Python** consumer skips the sysroot and the script: `python-ci-linux.yml`'s
`arches: riscv64` row runs the riscv64 image under QEMU on an amd64 runner, tests
only unless `package-emulated: true` adds the arch-specific wheel
(`docs/python-ci.md` § riscv64).

Nothing names `qemu`: binfmt runs riscv64 binaries directly, so `cargo test`, `ctest`, a
test that spawns another riscv64 binary (`assert_cmd`) and CMake's `try_run` all work
unchanged. The toolchain's `CMAKE_CROSSCOMPILING_EMULATOR` is `/usr/bin/env` for that
reason: it only tells CMake it may execute target binaries.

Locally (rootless nerdctl), binfmt is already registered in containerd's namespace by
`setup-rootless-binfmt.sh`; build the sysroot once and mount it read-only:

```bash
bash linux/scripts/02-toolchain/riscv64-sysroot.sh --dest ~/rv/sysroot --engine nerdctl
nerdctl run --rm -v ~/rv/sysroot:/opt/riscv64-sysroot:ro -e RISCV64_SYSROOT=/opt/riscv64-sysroot \
  -v "$PWD:/workspace" -w /workspace ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  bash -lc '<the lane script>'
```

## The building blocks, measured (2026-10-01)

On `:latest` index `1a913b84` (amd64 `502a5e9d`, riscv64 `d5e4db6b`).

**Compiler: the distro clang, not the image's.** The image's clang 23.1.1
(`/usr/local/llvm-target`) is built for X86 only: `llc --version` lists `x86` and `x86-64`,
and `--target=riscv64-linux-gnu` fails with `No available targets are compatible with
triple "riscv64-unknown-linux-gnu"`. Ubuntu's clang 22.1.2 (`/usr/lib/llvm-22`, installed
by the package stage as the LLVM floor) has the RISCV backend, `ld.lld`, `llvm-ar` and
`clang-scan-deps`. `riscv64_cross_llvm_dir` picks the newest `/usr/lib/llvm-*` whose `llc`
lists `riscv64`, so a later distro LLVM takes over by itself.

**The amd64 image's cross GCC cannot be used as it ships** (CON22: no binutils, no
sysroot). `riscv64-linux-gnu-gcc` 16.2.0 is there and its default `-march` is the
baseline, but `/opt/gcc-16.2.0/bin/riscv64-linux-gnu-{as,ld,ar}` link to
`/usr/bin/riscv64-linux-gnu-*`, which do not exist, so GCC falls back to the host `as`:
`Fatal error: invalid -march= option`. Its libc headers are expected at
`/usr/riscv64-linux-gnu/include`, also absent: `fatal error: features.h`. The clang route
needs neither.

**Sysroot: the riscv64 child of the same index.** The libraries a test binary links and
loads are the target image's own: glibc, GCC 16.2.0's libstdc++ (`/opt/gcc-16.2.0/lib`),
GStreamer, ONNX Runtime, OpenCV, the Vulkan SDK prefix, Mesa. `riscv64-sysroot.sh` takes
the index digest the local tag was pulled from (`RepoDigests`), looks up its
`linux/riscv64` manifest, and exports an allowlist (`RISCV64_SYSROOT_PATHS`): 4.9 GB, 90 s
locally. A path missing from the image fails the export: the contract moved. 149
absolute symlinks (`/etc/alternatives`, `.so` dev links) are made relative, or they would
resolve against the build container's root. `etc/ld.so.cache` comes along, so the riscv64
loader finds every prefix of the image under QEMU.

**Rust:** `riscv64gc-unknown-linux-gnu` is installed for 1.98.1. The linker is the clang
wrapper; `CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_RUSTFLAGS` carries the image's
`+v,+zvl128b`, which rustc 1.98 still reports as unstable features (a warning per crate).

**QEMU: 10.2.3, `rva23u64`.** The action registers `tonistiigi/binfmt:qemu-v10.2.3-68`,
pinned by digest; its `qemu-riscv64` is byte-identical (`3ddd4d6e…`) to the one this dev
host's rootless binfmt uses, so a local run is the CI run. The image's glibc needs RVV 1.0
([`riscv64-rva23-baseline.md`](riscv64-rva23-baseline.md)), and the CPU model decides
whether it runs at all:

| `-cpu` | the image's riscv64 `coreutils`, `gst-inspect-1.0` (289 plugins) |
| --- | --- |
| default, `max`, `rva23u64` | run |
| `rv64`, `rva22u64` | `Illegal instruction`, rc 132 |

Ubuntu 26.04's `qemu-user` 10.2.1 runs them too. `riscv64_cross_env` sets
`QEMU_CPU=rva23u64`: the profile the image is built for, not whatever `max` grows into.

## Traps, each found by a failing run

- **The image's arch-neutral paths are what make QEMU work.** `QEMU_LD_PREFIX` makes every
  absolute `open()` look in the sysroot first. The amd64 image's `LD_LIBRARY_PATH`,
  `GST_PLUGIN_PATH` and `ORT_DYLIB_PATH` name `/opt/gstreamer/lib/multiarch`,
  `/usr/local/lib/onnxruntime-cpu` and the like, so a riscv64 process reading them lands on
  riscv64 files. Two variables are arch-specific and `riscv64_cross_env` overrides them. The
  entrypoint sourcing LunarG's `setup-env.sh` pins them, not the image ENV; from the next
  `:latest` it leaves them on `/opt/vulkan/active` (CON48,
  [why](failure-modes.md#vulkan-env-names-an-arch-specific-sdk-dir)), and the override becomes a no-op:
  - `VK_ADD_LAYER_PATH` names `/opt/vulkan/1.4.357.0/x86_64/...`. A riscv64 loader then
    fails `libVkLayer_khronos_validation.so`, instance creation fails, and wgpu falls back
    to GL: `headless adapter 'llvmpipe' is the OpenGL backend` — Vulkan looked absent.
  - `VULKAN_SDK` (from the same `setup-env.sh`) names the x86_64 prefix:
    `Could NOT find Vulkan (missing: Vulkan_LIBRARY Vulkan_INCLUDE_DIR)`.
    `/opt/vulkan/active` re-roots to riscv64 in CMake and stays x86_64 for `glslc`.
- **`execve` is not remapped.** A riscv64 process that starts `/opt/.../tool` gets the
  amd64 tool, natively. That is right for helper tools, wrong for GStreamer's plugin
  scanner, so `GST_REGISTRY_FORK=no`.
- **clang does not look in a cross GCC's `lib/`** for `libstdc++`: `unable to find library
  -lstdc++`. The wrappers add `-L<sysroot>/opt/gcc-16.2.0/lib`.
- **Link flags on a compile line warn** (`argument unused during compilation`), which a
  `-Werror` build turns into a failure; the wrappers wrap them in
  `--start-no-unused-arguments`.
- **CMake must not pick the image's tools.** The image's `clang-scan-deps` has no riscv64
  backend (C++ modules), and `riscv64-linux-gnu-ar` on `PATH` dangles; the toolchain file
  names the distro LLVM's `clang-scan-deps` and `llvm-*`.
- **The reusable workflow's cache input is `cache-lane`, not `cache-key`.** A consumer's
  literal value under a key named `cache-key` (`riscv64-clang`, say) is a `generic-api-key`
  finding for gitleaks (entropy 3.5), so every caller's secret scan would go red.
- **Corrosion needs `Rust_CARGO_TARGET=riscv64gc-unknown-linux-gnu`**, like the Windows
  arm64 lane's `-Corrosion` switch.

## What the lanes do not run, and why

- **GPU suites.** No GPU under QEMU. lavapipe does run: OxidANT's whole workspace with
  `KATAGLYPHIS_REQUIRE_GPU=1` passed on riscv64 lavapipe in 16 min 55 s on this 32-core
  host, against 2 min 52 s without it, which on a 4-vCPU runner would eat most of the
  budget. The lanes skip GPU suites and keep a knob to run them.
- **Sanitizers and coverage.** The cross clang (22) has no riscv64 compiler-rt; the
  image's riscv64 runtimes belong to LLVM 23 and pair only with its instrumentation. The
  amd64 and arm64 lanes keep both.
- **Benchmarks and perf suites.** Timing under emulation measures QEMU.

## Status

| repo | lane | runs | excluded |
| --- | --- | --- | --- |
| OxidANT | `linux-riscv64.yml` | `cargo test --workspace`: 358 tests (local 2 min 52 s) | GPU rendering (skips without an adapter; `RISCV64_GPU_TESTS=1`) |
| AccelerANTgine | `linux-riscv64.yml` | Debug ctest (commit, compile, FuzzTest unit mode) + `first_fuzz_test` | sanitizers, coverage, TSan build, perf |
| BeschleunigerBallett | `linux-riscv64.yml` | Debug ctest | `Integration`, `GoldenRender` (GPU), sanitizers, coverage |
| OrchestrANT | `linux-riscv64.yml` | pytest + the arch-specific Cython wheel through `python-ci-linux.yml`'s `arches: riscv64` row with `package-emulated` (the riscv64 image under QEMU, `test` extra): 139 min tests-only on 2026-10-02, the 300-minute budget since 2026-10-03 | static analysis, docs, the `3.14t` leg, the amd64-arm64 app packages |
| OmniAccelerANT | none | — | waits for Flutter in the riscv64 image |

**Not covered.** A riscv64 *product* build (packages, AppImage) — these lanes test, they do
not ship. The sysroot follows the pulled tag, so a lane is only as fresh as `:latest`.
