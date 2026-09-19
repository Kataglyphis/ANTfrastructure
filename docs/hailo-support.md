# Hailo support — image-chain integration plan

**Status: PLAN (2026-09-19). Nothing on this page is implemented; no published
image carries Hailo today.** Host-side `.hef` compilation and the PCIe driver
already have procedures — [`linux-accelerator-images.md` § Edge
accelerators](linux-accelerator-images.md#edge-accelerators). This page owns what
would change in the Dockerfiles, what upstream facts the design rests on, and
what must be proven before a first build.

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

### Toggle and layers

- **`ENABLE_HAILO=true`** on `build-cross-chain.sh`, reaching the media stage
  the way `ENABLE_NVIDIA` does.
- **`linux/Dockerfile.hailo`** — `FROM :cross-sdk-<arch>`; builds `libhailort` +
  `hailortcli` + `pyhailort` from the pinned commit with
  `HAILO_BUILD_GSTREAMER=OFF`, installs under `/opt/hailo/<version>`, exports
  `HAILO_PREFIX` and `LD_LIBRARY_PATH`. No GStreamer here, so it can sit where
  `Dockerfile.nvidia` sits.
- **`linux/Dockerfile.media`** — when `ENABLE_HAILO=true`, build the `hailonet`
  element against the image's GStreamer and stage it into
  `$GSTREAMER_PREFIX/lib/gstreamer-1.0`. (Alternative with a smaller blast
  radius: one post-media `Dockerfile.hailo` layer built `FROM` the media image
  that does both halves. Decide at the spike; the toggle and the gates are the
  same either way.)
- **`linux/Dockerfile.package`** — COPY the runtime, the CLI, the Python wheel
  and the plugin; extend the media ENV block (`HAILO_PREFIX`, plugin path) in
  step with `03-media/runtime/media-env.sh`.
- **`Dockerfile.torch` / app wheelhouse** — carry the `pyhailort` wheel in
  `/opt/app-wheels` so `/opt/venv` can import it without network.
- **`Dockerfile.android`** — untouched.

### Pins (`versions.env`, single source)

`HAILORT_BRANCH` (`hailo8` | `master`), `HAILORT_VERSION`, `HAILORT_COMMIT` —
**the peeled commit, not the annotated tag object** (the LLVM_COMMIT incident:
`git ls-remote` prints both lines, and the first one is the tag object),
`HAILORT_DRIVER_VERSION` (documentation only — the host installs the driver),
and the TAPPAS pair only if phase 2 happens. Source tarballs are
`download_verified_file` with a SHA256 in the same file.

### Gates that must learn Hailo in the same commit

| Gate | Change |
| --- | --- |
| `03-media/runtime/verify-media-artifacts.sh` | a `hailo` stage row |
| `06-packaging/smoke-runtime-image.sh` | presence checks (`hailortcli --version`, `gst-inspect-1.0 hailonet`), device-dependent checks gated on a device, riscv64 exemption in `_parity_exempt` |
| `bundle-runtime-closure.sh` / `check-bundle-closure.sh` | Hailo libs and plugin in the allowlist with their own `$ORIGIN` rpath — RUNPATH is not transitive |
| `docs/deps/deps.json` + `third-party-licenses.md` | MIT and LGPL-2.1-or-later rows, source pointers for the copyleft pair |
| SBOM (`docs/deps/sbom-curated.spdx.json`) | the source-built components |
| `lint-env-knobs` / env-knob prefixes | `ENABLE_HAILO` follows the `ENABLE_NVIDIA` spelling |

### Host and run contract

- Host: PCIe driver (GPL-2.0, DKMS) and `modprobe hailo_pci` — already in the
  Edge accelerators section; link, do not restate.
- Run: `--device=/dev/hailo0` (plus the `video` group where the board needs
  it). The runtime image's run instructions gain one line.
- Consumer contract: `import hailort` from `/opt/venv`, `hailonet` on
  `GST_PLUGIN_PATH`, and the `.hef` path supplied by the app (a
  `KATAGLYPHIS_HAILO_HEF`-style knob only if a consumer asks for one).

## Phased rollout

1. **Phase 0 — decisions (owner).** Which family: Hailo-8/8L (`hailo8`,
   HailoRT 4.24.x) or Hailo-10H (`master`, 5.4.x)? The default assumption here
   is **Hailo-8L/8** — the M.2 cards. TAPPAS yes/no: default no (option (a)).
2. **Phase 1 — HailoRT userspace.** Spike `hailonet` against the image's
   GStreamer; then `Dockerfile.hailo` + media wiring + package/bundle + gates,
   amd64 first, then arm64. One real build proves the phase.
3. **Phase 2 — TAPPAS (optional, timeboxed).** Only if a consumer needs its
   pipelines; evaluate option (b) and stop if the patches grow.
4. **Phase 3 — Windows HailoRT (optional).** Separate lane, separate gates.
5. **Phase 4 — consumer adoption.** The image ships the runtime; the consumer
   repos document the device passthrough and model path, and the cat-detection
   stream can move from ONNX CPU to `.hef` on the device.

## Open questions

- Which device does the consumer actually run? That answer selects the branch
  and every pin.
- Does `hailonet` configure and load against the image's GStreamer? One build
  answers it; nothing else should be designed before that.
- pyhailort's build path (`hailort/libhailort/bindings/python`) and wheel name
  under the repo's Python pins.
- Does the protobuf/gRPC FetchContent pin cleanly, or do the externals need
  vendoring?
