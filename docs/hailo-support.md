# Hailo support — image-chain integration plan

**Status: HAILO-10H IN THE STANDARD RUNTIME (2026-09-20). `:latest-cross`
builds the Hailo payload by default on amd64 and arm64; riscv64 skips it (no
HailoRT support at any version). Hailo-8/8R/8L support was DROPPED the same
day — those devices need the `hailo8` branch (HailoRT 4.24.x), a different
source tree.** Host-side `.hef` compilation and the PCIe driver already have
procedures — [`linux-accelerator-images.md` § Edge
accelerators](linux-accelerator-images.md#edge-accelerators). This page owns the
design, the upstream facts it rests on, and what remains open.

**Proven 2026-09-20:** the payload was first proven as a variant
(`:hailo-amd64` / `:hailo-arm64` — the per-arch **wrappers** of the variant
manifest `:latest-cross-hailo`, per the tag convention in
[`AGENTS.md`](../AGENTS.md#image-and-tag-naming-published-tags)) and then folded
into `Dockerfile.torch`, so
every `:latest-cross` wrapper carries it. The build's own checks run before the
payload is accepted, so a broken element fails the build rather than shipping.
**pyhailort is built from source** (scikit-build-core, the `platform/`
directory) and installed into `/opt/venv`. One honest caveat: upstream declares
`requires-python <3.14` and the image runs 3.14, so the wheel's metadata is
relaxed before the build and the install is followed by an import test — a
failure is REPORTED, never hidden. The wheel also stays staged at
`/opt/hailo/wheels/` for a ≤3.13 environment. If `import hailo_platform` fails
on 3.14, that is upstream's declared boundary, not a packaging accident.
**TAPPAS IS built** (2026-09-20). Its README names GStreamer 1.16–1.20 as the
*tested* matrix, but the meson constraint is `>= 1.0` and it builds clean
against this image's 1.29.2 — the two load-bearing fixes are build-args, not
code patches: `libargs` is a Meson ARRAY (comma-separated elements, or only the
last survives) and the `open_source` include paths are explicit. Its
`hailofilter`/`hailocropper`/`hailooverlay`/`hailoaggregator`/`hailotracker` and
the rest load in the shipped image; libzmq is built in for the two zmq
elements. **The Dataflow
Compiler is staged, not fetched** — it is login-gated and x86_64-only; drop the
wheel into `linux/hailo-sdk/` and the amd64 wrapper installs it
(`linux/hailo-sdk/README.md`). The Model Zoo stays a host-side tool.

## What exists (2026-09-20)

| Piece | Where |
| --- | --- |
| Build script (HailoRT + `hailortcli` + `hailonet` + pyhailort wheel + TAPPAS + libzmq) | `linux/scripts/03-media/build/hailo/build-hailort.sh` |
| Standard runtime build (amd64/arm64, riscv64 skips) | `linux/Dockerfile.torch` |
| Standalone variant | `linux/Dockerfile.hailo` |
| Pins (`HAILORT_*`, `HAILO_PROTOBUF_*`, `TAPPAS_*`, `HAILO_LIBZMQ_*`) | `linux/scripts/01-core/versions.env` |
| Dataflow Compiler drop point (login-gated, gitignored) | `linux/hailo-sdk/` |
| Licence rows (MIT, LGPL-2.1-or-later, BSD-3-Clause) | `docs/deps/deps.json` |
| Build commands | [`linux-accelerator-images.md` § Hailo variant](linux-accelerator-images.md#hailo-variant) |

## Phase 3: Windows HailoRT (LANDED 2026-09-21)

**The Windows lane builds HailoRT (library + `hailortcli`) on amd64 and arm64.**
TAPPAS stays Linux-only and pyhailort's Windows wheel is still open; what ships
today is the device runtime every Windows consumer needs.

| Piece | Where |
| --- | --- |
| Build script | `windows/scripts/build/Build-HailortFromSource.ps1` |
| Media branch (`media-core-built-hailo`, between opencv and the core merge) | `windows/Dockerfile.media-builder` |
| Driver stage + pins forwarding | `windows/Build-Buildkit.ps1` (`Get-Ver 'HAILORT_*'`) |
| Patches (three upstream Windows/clang-cl gaps) | `windows/scripts/patches/hailo/` |
| Smoke section 24 + the `HAILO_ROOT`/`HAILO_BIN` pointers | `windows/scripts/build/Test-Container.ps1` |
| Payload layout | `C:\runtime\hailo\{bin,lib,include}` (`libhailort.dll`, `hailopp.dll`, `hailortcli.exe`) |

Same shape as the Linux lane, with two Windows-specific facts:

- **Offline externals, pinned 1:1.** Upstream's `prepare_externals` clones ten
  repositories at configure time, unpinned. The script stages each at the SAME
  commits the Linux lane pins (plus protobuf 21.12 from its SHA-verified tarball)
  and configures with `HAILO_OFFLINE_COMPILATION=ON`.
- **Three upstream gaps, all patched** (probe-proven 2026-09-21,
  `out/build-logs/probe-hailo-amd64-*`):
  1. `quantization.hpp`'s `bankers_round` guard keys on `_MSC_VER`, which clang-cl
     defines on EVERY arch → the x86 intrinsics fail on ARM64 and on a bare x64
     clang-cl without `-msse4.1` (`__builtin_ia32_roundss needs target feature
     sse4.1`). The guard is now `MSVC && !clang && (x64||x86)`.
  2. `driver_os_specific.cpp` defines explicit-specialization members without
     `template<>`; clang-cl enforces the prefix MSVC tolerates.
  3. `os/windows/filesystem.cpp` is a stub that omits `LockedFile::~LockedFile()`
     while the header declares it → `hailortcli` fails to link
     (`undefined symbol: hailort::LockedFile::~LockedFile`). The destructor is
     added (the stub's `create()` returns `HAILO_NOT_IMPLEMENTED`, so there is
     nothing to release).

**Not yet on Windows**: TAPPAS, the pyhailort wheel, the GStreamer `hailonet`
element (`HAILO_BUILD_GSTREAMER` stays OFF — the binding exists upstream for
Windows but is a separate gate), the Dataflow Compiler (host-side tool anyway)
and any device execution (no Hailo device on the build host).

The shape mirrors the NVIDIA/AMD variants: `Dockerfile.hailo` builds HailoRT in
the **runtime image itself** (native GCC 16.2.0 + the GStreamer dev files are
already there), then copies the payload into the same image — so the variant is
`:latest-cross` plus `/opt/hailo`, and the plugin links against exactly the
GStreamer the runtime ships. The first design built in `cross-android-<arch>`
instead; it works for amd64 but dies for arm64, because those images are
amd64-hosted cross toolchains and HailoRT's FetchContent externals invoke their
own nested cmake, which a cross `CMAKE_C_COMPILER` cannot reach
(`as: unrecognized option '-EL'`, then a Ninja/RPATH "not ELF-based" error from
a stale cross cache). Native is slower on arm64 (QEMU) and correct.

**Build-args, not patches.** TAPPAS needed no GStreamer source changes: the
Meson `libargs` array (comma-separated) carries the HailoRT include paths and
`libxtensor`/`libcxxopts`/`librapidjson` point at `core/open_source/`, whose
header-only dependencies (xtensor, xtl, cxxopts, pybind11, rapidjson, Catch2)
are staged at pinned commits — upstream clones them from branches, including
`rapidjson: master`.


## Why an image chain

The runtime artifacts are deployed to boards with a Hailo-10H accelerator.
Until 2026-09-20 the software was installed on the host by hand: HailoRT and
the GStreamer element were absent from every image, so a consumer either
apt-installed them outside the container or skipped the device. The standard
runtime now ships them pinned, verified and gated, the same way CUDA/ROCm and
the QNN EP are handled.

## Upstream facts (2026-09-19)

### Device families split the source tree

| Family | Branch | Latest release | Notes |
| --- | --- | --- | --- |
| Hailo-8, Hailo-8R, Hailo-8L | `hailo8` | v4.24.0 | **DROPPED 2026-09-20.** These devices need this branch (HailoRT 4.24.x), a different source tree and pin set; restore it only by re-adding a second pin set |
| Hailo-10 | `master` | **v5.4.0** (`f5195903`) | **the supported family**; 10H is PCIe |
| Hailo-15 | `master` | v5.4.0 | an SoC with its own apps repo — **out of scope** |

A single pin cannot serve both lines: the branch is part of the pin
(`HAILORT_BRANCH` + `HAILORT_COMMIT`), and the version keys differ.

### Components, licenses, where each one runs

| Component | Source | License | Where |
| --- | --- | --- | --- |
| `libhailort`, `hailortcli`, `pyhailort` | [`hailo-ai/hailort`](https://github.com/hailo-ai/hailort) | MIT | in the image |
| `hailonet` GStreamer element | same repo, `hailort/libhailort/bindings/gstreamer` | LGPL-2.1-or-later | in the image (media) |
| Hailo PCIe driver | [`hailo-ai/hailort-drivers`](https://github.com/hailo-ai/hailort-drivers) | GPL-2.0 | **host only** — out-of-tree DKMS, never in an image |
| TAPPAS | [`hailo-ai/tappas`](https://github.com/hailo-ai/tappas) | LGPL-2.1-or-later | **in the image** (with libzmq, MPL-2.0, for the zmq elements) |
| Hailo Model Zoo | [`hailo-ai/hailo_model_zoo`](https://github.com/hailo-ai/hailo_model_zoo) | MIT | host-side, with the login-gated Dataflow Compiler |

Both copyleft rows need a source pointer in
[`third-party-licenses.md`](third-party-licenses.md) when the dependency lands;
`spdx` is mandatory in `deps.json`.

### HailoRT build knobs (CMake)

`HAILO_BUILD_GSTREAMER` (the `hailonet` plugin), `HAILO_BUILD_TOOLS`,
`HAILO_BUILD_EXAMPLES`, `HAILO_BUILD_USB`, `HAILO_BUILD_HAILORT_SERVER`,
`HAILO_BUILD_GENAI_SERVER`, `HAILO_BUILD_OLLAMA`, and
`HAILO_OFFLINE_COMPILATION`. The default build fetches protobuf and gRPC with
FetchContent, so the supply-chain rule applies: either vendor them or pin the
fetch with verification — an unverified network fetch inside a `RUN` is the
class this repo refuses everywhere else.

### TAPPAS pairing

TAPPAS v5.4.0 pairs with HailoRT **v5.4.0 for Hailo-10H** (the Hailo-8 line
went with that family's drop). It is LGPL-2.1-or-later and targets Ubuntu x86
24.04/22.04, Ubuntu aarch64 20.04 (manual install), Raspberry Pi OS and Yocto —
no Windows, no riscv64. Its README's **1.16 | 1.18 | 1.20** is the *tested*
matrix; the meson constraint is `>= 1.0`, and 1.29.2 builds clean (proven).

## Compatibility findings (resolved 2026-09-20)

1. **GStreamer: no gap in practice.** The image's 1.29.2 builds TAPPAS clean —
   the only fixes are build-args (`libargs` comma-array, explicit `open_source`
   paths). No GStreamer source patches, no second GStreamer tree.
2. **Architecture.** amd64 + arm64; riscv64 unsupported (HailoRT and TAPPAS
   both). The script refuses it.
3. **Windows.** HailoRT supports Windows; TAPPAS does not — a separate phase.
4. **Android.** PCIe/M.2 — not applicable.
5. **The Dataflow Compiler stays off-image** unless staged (login-gated,
   x86_64-only; `linux/hailo-sdk/`).

## Integration design (Linux lane)

The standard runtime builds the payload itself, and the `:hailo` variant stays
as a convenience tag. [`linux-accelerator-images.md`](linux-accelerator-images.md)
owns the variant mechanics; this is the Hailo instance of them.

### Layers (as implemented)

- **`linux/Dockerfile.torch`** (the standard wrapper, per arch) — before the
  runtime user is created, it runs `build-hailort.sh` with
  `HAILO_BUILD_GSTREAMER=ON` and `HAILO_OFFLINE_COMPILATION=ON` (externals
  staged from verified sources), installs the plugin into
  `${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0`, writes
  `/etc/ld.so.conf.d/000-hailo.conf`, symlinks `hailortcli`, and self-checks
  both. riscv64 prints a skip line and builds nothing. The image has GCC 16.2.0,
  cmake, ninja and the GStreamer dev files, so the build is native.
- **`linux/Dockerfile.hailo`** — the same payload as a standalone variant
  (`:hailo-<arch>`, `:hailo`), for consumers that want the tag rather than the
  standard one. It builds in `latest-cross-<arch>` and copies the payload in.
- **`Dockerfile.media` / `Dockerfile.package` / `Dockerfile.android`** —
  untouched; the build lives where the compiler and GStreamer dev files already
  are, so the media stage's fan-out is not re-keyed.
- **riscv64 skips by construction** — HailoRT has no riscv64 support, the script
  refuses it, and the Dockerfile branches around it. That is the documented
  exemption, not a gap.

### Pins (`versions.env`, single source)

`HAILORT_VERSION`, `HAILORT_COMMIT` (for v5.4.0 the value is both the tag and
the commit — a lightweight tag), `HAILORT_SOURCE_SHA256`, and the externals:
`HAILO_PROTOBUF_VERSION`/`_SHA256`, plus `TAPPAS_VERSION`/`_SHA256` and
`HAILO_LIBZMQ_VERSION`/`_SHA256` (TAPPAS's zmq elements). master has no
`grpc.cmake` (the hailo8 branch did), so there are no gRPC keys; TAPPAS's own
header-only externals are commit-pinned in the build script. The same values are the ARG defaults in
`Dockerfile.torch` and `Dockerfile.hailo`, and `sync_versions.py --check` keeps
them in step.

### Gates

| Gate | State |
| --- | --- |
| Build-stage self-check (`hailortcli --version`, `gst-inspect-1.0 hailonet`) | in `build-hailort.sh`, fails the build |
| Runtime-stage self-check (`gst-inspect-1.0 hailonet` after the copy) | in `Dockerfile.hailo` stage 2 |
| `docs/deps/deps.json` + `third-party-licenses.md` | MIT, LGPL-2.1-or-later (with source pointer), BSD-3-Clause, Apache-2.0 rows added |
| `verify-media-artifacts.sh` / `smoke-runtime-image.sh` | **not wired** — those gates grade the standard chain, which carries no Hailo; a variant gate would run in the variant's own build |
| Bundle closure | not applicable — the variant is a full image, not a bundle |

### Host and run contract

- Host: PCIe driver (GPL-2.0, DKMS) and `modprobe hailo_pci` — already in the
  Edge accelerators section; link, do not restate.
- Run: `--device=/dev/hailo0` (plus the `video` group where the board needs it).
- Consumer contract: the `hailonet` element on the image's `GST_PLUGIN_PATH`,
  `hailortcli` on `PATH`, and the `.hef` path supplied by the app.

## Phased rollout

1. **Phase 0 — decisions.** Family: **Hailo-8L/8** (`hailo8`, HailoRT 4.24.x),
   the M.2 cards; Hailo-10H (`master`, 5.4.x) needs a second pin set. TAPPAS:
   **no** — `hailonet` only (option (a) below).
2. **Phase 1 — HailoRT userspace + `hailonet`: amd64 DONE.** Built, verified
   and published as `:hailo-amd64`; arm64 is the next build (QEMU, needs a disk
   window).
3. **Phase 2 — TAPPAS (optional, timeboxed).** Only if a consumer needs its
   pipelines; evaluate option (b) and stop if the patches grow.
4. **Phase 3 — Windows HailoRT (optional).** Separate lane, separate gates.
5. **Phase 4 — consumer adoption.** Consumer repos document the device
   passthrough and model path, and the cat-detection stream can move from ONNX
   CPU to `.hef` on the device.

## Open questions

- Does `hailonet` configure and load against the image's GStreamer? **Answered
  2026-09-20: yes** — built and loaded on amd64 (see the status block).
- Does the protobuf/gRPC offline staging configure cleanly, and how long does
  the gRPC submodule clone take? **Answered: yes**; all 16 commit-pinned
  externals are staged by `stage_remaining_externals` (protobuf as a verified
  tarball, gRPC as a tag clone with submodules).
- Which device does the consumer actually run? That answer may add the
  Hailo-10H pin set.
- `pyhailort`, if ever needed: it ships in Hailo's `.deb`, not the source build.
