# Hailo support — image-chain integration plan

**Status: IMPLEMENTED as the opt-in `:hailo` variant (2026-09-20); the standard
`:latest-cross` is unchanged and carries no Hailo.** Host-side `.hef` compilation
and the PCIe driver already have procedures — [`linux-accelerator-images.md` §
Edge accelerators](linux-accelerator-images.md#edge-accelerators). This page owns
the variant's design, the upstream facts it rests on, and what remains open.

## What exists (2026-09-20)

| Piece | Where |
| --- | --- |
| Build script (HailoRT + `hailortcli` + `hailonet`) | `linux/scripts/03-media/build/hailo/build-hailort.sh` |
| Variant Dockerfile (build stage + runtime stage) | `linux/Dockerfile.hailo` |
| Pins (`HAILORT_*`, `HAILO_PROTOBUF_*`, `HAILO_GRPC_*`) | `linux/scripts/01-core/versions.env` |
| Licence rows (MIT, LGPL-2.1-or-later, BSD-3-Clause, Apache-2.0) | `docs/deps/deps.json` |
| Build commands | [`linux-accelerator-images.md` § Hailo variant](linux-accelerator-images.md#hailo-variant) |

The shape mirrors the NVIDIA/AMD variants: `Dockerfile.hailo`'s first stage runs
`FROM cross-android-<arch>` (which carries the media GStreamer, dev files
included), builds HailoRT offline against verified protobuf/gRPC sources, and
the second stage copies the payload into `latest-cross-<arch>`. The plugin and
`libhailort` are placed on the base image's existing `GST_PLUGIN_PATH` and
`LD_LIBRARY_PATH` entries, so the variant's environment is the runtime's —
no ENV surgery, one image shape.

**Not implemented, deliberately:** `pyhailort`. The public Python package is not
produced by the source build (the repo's bindings CMake only builds an internal
module under `HAILO_BUILD_PYHAILORT_INTERNAL`); it ships in Hailo's `.deb`. The
GStreamer element is what this repo's pipelines need. Revisit only if a consumer
asks for `import hailort`.


## Why an image chain

The runtime artifacts are deployed to boards with a Hailo-8/8L or Hailo-10H
accelerator, but the software is installed on the host by hand today: HailoRT,
its Python bindings and the GStreamer element are absent from every image, so a
consumer either apt-installs them outside the container or skips the device.
Bringing them into the chain gives consumers a pinned, verified, gated runtime
the same way CUDA/ROCm and the QNN EP are handled.

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

The shape mirrors the NVIDIA/AMD variants: an opt-in toggle, a vendor layer,
conditional consumers, and its own tag — the standard chain stays unchanged
when the toggle is off. [`linux-accelerator-images.md`](linux-accelerator-images.md)
owns the existing variant mechanics; this is the Hailo instance of them.

### Layers (as implemented)

- **`linux/Dockerfile.hailo`, stage 1** — `FROM cross-android-<arch>` (the
  media GStreamer with its dev files is there); runs
  `build-hailort.sh` with `HAILO_BUILD_GSTREAMER=ON` and
  `HAILO_OFFLINE_COMPILATION=ON`, externals staged from verified sources.
- **`linux/Dockerfile.hailo`, stage 2** — `FROM latest-cross-<arch>`; copies
  `/opt/hailo`, drops the plugin into the base image's
  `${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0` and `libhailort` into
  `/usr/local/lib`, and runs `ldconfig`. No ENV block changes: the variant's
  environment IS the runtime's.
- **No `ENABLE_HAILO` toggle in the chain, deliberately.** The variant builds
  after the runtime lane has published `latest-cross-<arch>`, exactly like the
  NVIDIA/AMD hand-run chains, so a Hailo experiment can never perturb the
  standard chain's cache or gates. Folding it into `:latest-cross` itself would
  re-key the media stage for every consumer and is not what the variant is for.
- **`Dockerfile.media` / `Dockerfile.package` / `Dockerfile.android`** —
  untouched.

### Pins (`versions.env`, single source)

`HAILORT_VERSION`, `HAILORT_COMMIT` (for the `hailo8` line the value is both
the tag and the commit — a lightweight tag), `HAILORT_SOURCE_SHA256`, and the
externals: `HAILO_PROTOBUF_VERSION`/`_SHA256`,
`HAILO_GRPC_VERSION`/`_COMMIT`. The same values are the ARG defaults in
`Dockerfile.hailo`, and `sync_versions.py --check` keeps the two in step.

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
2. **Phase 1 — HailoRT userspace + `hailonet`: implemented, build owed.** The
   script and Dockerfile exist and are pinned; the first amd64 build is the
   proof. arm64 follows once amd64 is green.
3. **Phase 2 — TAPPAS (optional, timeboxed).** Only if a consumer needs its
   pipelines; evaluate option (b) and stop if the patches grow.
4. **Phase 3 — Windows HailoRT (optional).** Separate lane, separate gates.
5. **Phase 4 — consumer adoption.** Consumer repos document the device
   passthrough and model path, and the cat-detection stream can move from ONNX
   CPU to `.hef` on the device.

## Open questions

- Does `hailonet` configure and load against the image's GStreamer? The first
  build answers it; the build-stage self-check fails loudly if not.
- Does the protobuf/gRPC offline staging configure cleanly, and how long does
  the gRPC submodule clone take? The build reports both.
- Which device does the consumer actually run? That answer may add the
  Hailo-10H pin set.
- `pyhailort`, if ever needed: it ships in Hailo's `.deb`, not the source build.
