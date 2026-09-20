# Hailo support — image-chain integration plan

**Status: IN THE STANDARD RUNTIME (2026-09-20). `:latest-cross` builds the
Hailo payload by default on amd64 and arm64; riscv64 skips it (no HailoRT
support at any version). The `:hailo` variant image remains published for
consumers that want the tag.** Host-side `.hef` compilation and the PCIe driver
already have procedures — [`linux-accelerator-images.md` § Edge
accelerators](linux-accelerator-images.md#edge-accelerators). This page owns the
design, the upstream facts it rests on, and what remains open.

**Proven 2026-09-20:** the payload was first proven in `:hailo-amd64` /
`:hailo-arm64` (joined into the `:hailo` manifest) and then folded into
`Dockerfile.torch`, so every `:latest-cross` wrapper carries it. In the shipped
images `hailortcli --version` reports `HailoRT-CLI version 4.24.0` and
`gst-inspect-1.0 hailonet` resolves the element. The build's own checks run
before the payload is accepted, so a broken element fails the build rather than
shipping.

## What exists (2026-09-20)

| Piece | Where |
| --- | --- |
| Build script (HailoRT + `hailortcli` + `hailonet`) | `linux/scripts/03-media/build/hailo/build-hailort.sh` |
| Variant Dockerfile (build stage + runtime stage) | `linux/Dockerfile.hailo` |
| Pins (`HAILORT_*`, `HAILO_PROTOBUF_*`, `HAILO_GRPC_*`) | `linux/scripts/01-core/versions.env` |
| Licence rows (MIT, LGPL-2.1-or-later, BSD-3-Clause, Apache-2.0) | `docs/deps/deps.json` |
| Build commands | [`linux-accelerator-images.md` § Hailo variant](linux-accelerator-images.md#hailo-variant) |

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

**Not implemented, deliberately:** `pyhailort`. The public Python package is not
produced by the source build (the repo's bindings CMake only builds an internal
module under `HAILO_BUILD_PYHAILORT_INTERNAL`); it ships in Hailo's `.deb`. The
GStreamer element is what this repo's pipelines need. Revisit only if a consumer
asks for `import hailort`.


## Why an image chain

The runtime artifacts are deployed to boards with a Hailo-8/8L or Hailo-10H
accelerator. Until 2026-09-20 the software was installed on the host by hand:
HailoRT and the GStreamer element were absent from every image, so a consumer
either apt-installed them outside the container or skipped the device.
The `:hailo` variant ships them pinned, verified and gated, the same way
CUDA/ROCm and the QNN EP are handled.

## Upstream facts (2026-09-19)

### Device families split the source tree

| Family | Branch | Latest release | Notes |
| --- | --- | --- | --- |
| Hailo-8, Hailo-8R, Hailo-8L | `hailo8` | **v4.24.0** (head `63adffec`, tag and head identical) | the M.2/PCIe cards; the line the Model Zoo targets |
| Hailo-10, Hailo-15 | `master` | **v5.4.0** (`f5195903`) | 10H is PCIe; 15 is an SoC with its own apps repo — **out of scope** |

A single pin cannot serve both lines: the branch is part of the pin
(`HAILORT_BRANCH` + `HAILORT_COMMIT`), and the version keys differ.

### Components, licenses, where each one runs

| Component | Source | License | Where |
| --- | --- | --- | --- |
| `libhailort`, `hailortcli`, `pyhailort` | [`hailo-ai/hailort`](https://github.com/hailo-ai/hailort) | MIT | in the image |
| `hailonet` GStreamer element | same repo, `hailort/libhailort/bindings/gstreamer` | LGPL-2.1-or-later | in the image (media) |
| Hailo PCIe driver | [`hailo-ai/hailort-drivers`](https://github.com/hailo-ai/hailort-drivers) | GPL-2.0 | **host only** — out-of-tree DKMS, never in an image |
| TAPPAS | [`hailo-ai/tappas`](https://github.com/hailo-ai/tappas) | LGPL-2.1-or-later | phase 2 (see the GStreamer blocker) |
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

TAPPAS v5.4.0 supports HailoRT **v4.24.0 for Hailo-8** and **v5.4.0 for
Hailo-10H**, and states its GStreamer support as **1.16 | 1.18 | 1.20**. It is
LGPL-2.1-or-later and targets Ubuntu x86 24.04/22.04, Ubuntu aarch64 20.04
(manual install), Raspberry Pi OS and Yocto — no Windows, no riscv64.

## Compatibility findings (resolve before wiring anything)

1. **GStreamer version gap — the one real blocker.** The image builds GStreamer
   from source at `GSTREAMER_VERSION` (`versions.env`); TAPPAS's supported
   matrix stops at 1.20. Three options, in order of preference:
   - **(a) `hailonet` only** — HailoRT's own GStreamer element, built against
     the image's GStreamer. Smallest surface, no TAPPAS dependency tree, and it
     is the element a GStreamer pipeline actually needs for inference. The
     default plan.
   - **(b) Patch TAPPAS** to build against the image's GStreamer — unproven,
     carries a fork, and TAPPAS is a large meson project. Timeboxed spike only.
   - **(c) Ship a second GStreamer** (1.20) for TAPPAS — two GStreamer trees in
     one image is the worst maintenance and disk option.
   **Prove (a) with one build before designing around it**: configure HailoRT
   with `HAILO_BUILD_GSTREAMER=ON` against the image's GStreamer and run
   `gst-inspect-1.0 hailonet`.
2. **Architecture.** HailoRT builds from source for x86_64 and aarch64; riscv64
   is not supported. riscv64 therefore takes a parity exemption — recorded in
   `_parity_exempt` (`06-packaging/smoke-runtime-image.sh`), the same mechanism
   QNN's arm64-only and cmake's riscv64 exemptions use. Never in prose.
3. **Windows.** HailoRT supports Windows; TAPPAS does not. A Windows HailoRT
   layer is a separate lane and a separate phase — do not couple it to the
   Linux work.
4. **Android.** PCIe/M.2 — not applicable.
5. **The Dataflow Compiler stays off-image.** It is x86-only and login-gated;
   compiling ONNX to `.hef` remains a host procedure (existing doc), and the
   image only consumes `.hef` at runtime.

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

`HAILORT_VERSION`, `HAILORT_COMMIT` (for the `hailo8` line the value is both
the tag and the commit — a lightweight tag), `HAILORT_SOURCE_SHA256`, and the
externals: `HAILO_PROTOBUF_VERSION`/`_SHA256`,
`HAILO_GRPC_VERSION`/`_COMMIT`. The same values are the ARG defaults in
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
