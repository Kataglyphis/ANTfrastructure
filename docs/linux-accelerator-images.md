# Linux Accelerator Images

## Optional NVIDIA GPU image chain

Optional NVIDIA GPU image chain, built as a **variant chain** since 2026-09-22:
`CROSS_VARIANT=nvidia bash linux/scripts/build-cross-chain.sh --target-arches amd64`
(`ENABLE_NVIDIA=true` alone implies the variant). The chain inserts a `gpu`
stage (`Dockerfile.nvidia`) between the SHARED sdk and media, and every tag it
writes from there on carries `-nvidia` — `:cross-toolchain-nvidia-<arch>`,
`:cross-media-nvidia-<arch>`, `:cross-android-nvidia-<arch>`,
`:latest-nvidia-<arch>`, `:latest-nvidia` — so it can never overwrite the
default chain's tags. Before 2026-09-22 `ENABLE_NVIDIA=true` changed only the
build args, and a GPU run pushed its bytes under the default `cross-media-<arch>`
and `:latest`. The rules: [`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags).

- `linux/Dockerfile.nvidia`: CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.27.0.42<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.3.0.99<!-- /generated:tensorrt --> (off by default), NCCL, cuBLAS/cuSPARSE/cuFFT, NVTX. The chain's `gpu` stage, after `:cross-sdk-<arch>`.
- `linux/Dockerfile.media`: Builds media stack with NVIDIA codec headers + ORT CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true`.
- `linux/Dockerfile.android`: Android SDK/NDK on top of the NVIDIA media layer.
- `linux/Dockerfile.torch`: Torch/Python add-on on top of the Android NVIDIA layer.
- `linux/Dockerfile.torch`: Final entrypoint image (`:latest-nvidia-<arch>` wrapper, indexed as `:latest-nvidia`).

## NVIDIA GPU Build (Linux)

> **Tag: `:latest-nvidia`** (a manifest; today one per-arch wrapper,
> `:latest-nvidia-amd64` — arm64 joins when the cross-sbsa lane exists),
> per [`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags).
> **Not published yet.** The old single-arch `:nvidia` (a 2026-04-22 build on
> the Ubuntu 24.04 base) and its stage tags were deleted from the registry on
> 2026-09-22.

> **Requirements:**
> - Host driver >= 590.44 (for CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->).
> - `nvidia-container-toolkit` installed and configured on the host.
> - `--runtime=nvidia` or `--gpus all` passed to `docker run`.

The NVIDIA variant chain inserts `Dockerfile.nvidia` as its `gpu` stage **after** the shared `:cross-sdk-<arch>` and before media. The later stages are the standard Dockerfiles with `ENABLE_NVIDIA=true`, which the chain derives from the variant.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.nvidia` | Installs CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.27.0.42<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.3.0.99<!-- /generated:tensorrt -->, NCCL, cuBLAS, cuSPARSE, cuFFT, NVTX |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the NVIDIA media image |
| `linux/Dockerfile.torch` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/build/onnxruntime/build/30-build-native-nvidia.sh` | ORT build script with CUDA, TensorRT, cuDNN EPs |

**Build (orchestrated, amd64):**

```bash
CROSS_VARIANT=nvidia bash linux/scripts/build-cross-chain.sh \
  --target-arches amd64 --parallel-archs --log-dir ./out/build-logs/nvidia
```

What the variant changes, all in `build-cross-chain.sh` / `stage-defs.sh`:

- **It starts at `gpu`** and refuses `--from-stage base|compiler|sdk`: those are
  the default chain's, so run that chain first when they are stale.
- **`ENABLE_TENSORRT=false` by default** (owner decision 2026-09-22): the runtime
  payload carries no `libnvinfer` yet. Set `ENABLE_TENSORRT=true` only together
  with that copy.
- **amd64 only, and it pushes only from `CROSS_BUILD_PLATFORM=linux/amd64`.**
  Every target must BE the build platform's arch: `Dockerfile.nvidia` installs
  the build platform's CUDA and the ORT/OpenCV/TVM CUDA builds compile for it,
  so an arm64 target would get x86_64 GPU libraries under an arm64 tag. And the
  shared `:cross-sdk-<arch>` it builds on is the amd64 lane's (no build-host
  infix), so off linux/amd64 a variant may only run `--no-push` — the
  [Jetson lane below](#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson),
  which stays local. `build-cross-stage.sh` applies the same refusals.
- **Its own state:** `chain-status-nvidia.json` and `out/build-logs/nvidia/`.
  Chains run **strictly one at a time**: a second chain refuses to start while
  the pidfile names a live one.
- **The runtime lane budgets 180 GB** (`CROSS_RUNTIME_LANE_GB`), not 120.
- The wrappers take `onnxruntime-gpu` + `pytorch-cu130` unless you pin
  `ONNX_PACKAGE` / `PYTORCH_EXTRA`, and only that one onnxruntime flavour: the
  amd64 CPU `onnxruntime_dnnl` wheel is pruned from a GPU venv. The manifest is
  `:latest-nvidia` over the `:latest-nvidia-<arch>` the run built. There is no
  route yet to add an arm64 entry: the Jetson lane's image is host-infixed and
  local, and once the cross-sbsa lane exists it builds BOTH arches in one run —
  after which an amd64-only run is refused by the completeness gate, as for
  `:latest`.
- **The standalone runtime helpers refuse a default output tag** under a
  variant: `build-runtime-artifacts.sh` / `build-runtime-manifest.sh` read the
  variant's android, so a prefix without `-nvidia` (a plain `:latest`) is an
  error, and `build-runtime-artifacts.sh` defaults to `:latest-nvidia`.

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --gpus all ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-nvidia

# or with nvidia runtime explicitly
sudo nerdctl run --rm -it --runtime=nvidia ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-nvidia
```

**Version overrides** (all have sensible defaults): `CUDA_VERSION`,
`CUDNN_VERSION` and `TENSORRT_VERSION` are `versions.env` pins, forwarded to
every stage as build-args. Change them there, not per command. The apt forms
(the `<major>-<minor>` package suffix, cuDNN major) are derived inside `Dockerfile.nvidia`.

**Key differences from the standard build:**

| Feature | Standard build | NVIDIA build |
| --- | --- | --- |
| CUDA Toolkit | Not installed | CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda --> |
| cuDNN | Not installed | cuDNN 9 |
| TensorRT | Not installed | TensorRT <!-- generated:tensorrt -->11.3.0.99<!-- /generated:tensorrt --> with `ENABLE_TENSORRT=true` (off by default) |
| NCCL | Not installed | Installed |
| cuBLAS/cuSPARSE/cuFFT | Not installed | Installed |
| NVTX | Not installed | Installed |
| GStreamer nvcodec | Auto-detected (off in builds) | Always enabled |
| ORT native EP | CPU only | CPU + CUDA + cuDNN (+ TensorRT when enabled) |
| ORT Python Package | `onnxruntime` (the `ONNX_PACKAGE` ARG default in `linux/Dockerfile.torch`) | `onnxruntime-gpu` (via `ONNX_PACKAGE`) |
| PyTorch Extra | `pytorch-cpu` | `pytorch-cu130` (via `PYTORCH_EXTRA`) |
| ORT output dir | `/usr/local/lib/onnxruntime-cpu` | Both cpu and `/usr/local/lib/onnxruntime-gpu` |
| Image tag | `:latest` (3-arch manifest) | `:latest-nvidia` (manifest; not published yet) |

The standard build's release target is the multi-arch manifest `:latest`
([`linux-build-basics.md` § Image Hierarchy](linux-build-basics.md#image-hierarchy)
owns the tag scheme). `:latest-cross` is its retired old name; details in
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).

## NVIDIA on arm64 (SBSA): one image for servers and Jetson

The arm64 GPU chain uses NVIDIA's **SBSA** CUDA repository (the Arm-server
build), not JetPack. The same image targets a Grace-class server GPU and a
Jetson Orin, because newer L4T releases run SBSA CUDA against their Tegra
driver. Built natively on a Jetson AGX Orin (L4T R39) on 2026-09-21/22, base to
runtime, and run on its GPU: PyTorch, the ONNX Runtime CUDA EP, OpenCV CUDA and
an `nvcc -arch=sm_87` kernel, each checked against a CPU result.

### Building it on an arm64 host

This is the sequence that ran on the Orin, before the chain had a `gpu` stage;
the names below are the variant names it would write today. It stays by hand
because every stage is `--no-push` there, and the orchestrator refuses a
`--no-push` run that resumes mid-chain (the variant chain always starts at
`gpu`). `--no-push` keeps every
stage local, so each child reads its parent from an OCI layout exported with
`nerdctl save <tag> | tar -x -C <dir>`:

```bash
export CROSS_BUILD_PLATFORM=linux/arm64   # build on, and only for, this host
A=(--target-arches arm64 --cross-targets arm64 --no-push)
R=ghcr.io/kataglyphis/kataglyphis_beschleuniger

# 1. base -> compiler -> sdk
bash linux/scripts/build-cross-chain.sh --to-stage sdk "${A[@]}"

# 2. the GPU layer on the sdk (export the sdk to an OCI layout first)
nerdctl build --platform linux/arm64 -f linux/Dockerfile.nvidia \
  -t "$R:cross-toolchain-nvidia-arm64" \
  --build-context "$R:cross-sdk-arm64=oci-layout://$SDK_OCI" \
  --build-arg BASE_IMAGE="$R:cross-sdk-arm64" --build-arg UBUNTU_VERSION=26.04 \
  --build-arg ENABLE_TENSORRT=false --build-arg CUDA_INSTALL_COMPAT=0 .

# 3. media and android, each FROM its parent's layout
export ENABLE_NVIDIA=true ENABLE_TENSORRT=false TVM_USE_CUDA=1
CROSS_MEDIA_BASE_IMAGE="$R:cross-toolchain-nvidia-arm64" CROSS_MEDIA_BASE_CONTEXT="$NVIDIA_OCI" \
  bash linux/scripts/build-cross-chain.sh --only media "${A[@]}"
CROSS_ANDROID_BASE_IMAGE="$R:cross-media-nvidia-arm64" CROSS_ANDROID_BASE_CONTEXT="$MEDIA_OCI" \
  bash linux/scripts/build-cross-chain.sh --only android "${A[@]}"

# 4. runtime: call the helper directly, with the android layout as the artifact
#    (the directory must be named <root>-arm64)
CROSS_NO_PUSH=1 ARTIFACT_CONTEXT_ROOT="$ANDROID_OCI_ROOT" ARTIFACT_CONTEXT_MODE=oci \
  bash linux/scripts/build-runtime-manifest.sh --image "$R:latest-nvidia-hostarm64" \
  --target-arches arm64 --artifact-image-prefix "$R:cross-android-nvidia-hostarm64" \
  --artifact-build-mode cross --skip-manifest
```

Step 4 does not go through `build-cross-chain.sh --only runtime`: a runtime run
whose android stage was not built in the same run PULLS the android image from
the registry, and would package the published generation instead of this one.
Every pin must match the one the lower stages were built with; the wrapper
smoke refuses a toolchain whose `clang --version` differs from `LLVM_RELEASE`.

The knobs that exist for this lane:

| Knob | Default | What it does |
|---|---|---|
| `ENABLE_TENSORRT` | `true` | `false` builds CUDA + cuDNN with no TensorRT anywhere: there are no SBSA TensorRT packages for this pin, and GenAI then skips `--use_trt_rtx`. |
| `CUDA_INSTALL_COMPAT` | `1` | `0` skips `cuda-compat`, the datacenter forward-compat driver. On a Jetson the driver comes from L4T and the compat `libcuda` can shadow it. |
| `CUDA_MB_PER_CICC` | `3500` | Memory budget per `cicc` process for the ORT GPU job count. Heavy CUDA files peak at 3.5-6 GB; the average lies, because they are staggered. |
| `NVCC_PREPEND_FLAGS` | `-allow-unsupported-compiler` | nvcc rejects the image's GCC 16 by version. Set in `Dockerfile.media` and `Dockerfile.package`. |

`CUDA_ARCHITECTURES` carries `87` (Orin). The list stays ascending for
readability only: since 2026-09-23 nothing depends on its order, because the
trailing-`90` → `90a` rewrite ORT used to need is gone (AGENTS.md § GPU
architecture coverage). OpenCV ignores
`CMAKE_CUDA_ARCHITECTURES` on its default path and gets `CUDA_ARCH_BIN` in its
own dotted form. Build with the image's GCC 16, never a downgraded
`CUDAHOSTCXX`: a GCC 15 host compiler produced the `GLIBCXX` link failures it
seemed to avoid.

What does NOT build on an arm64 host: the Android payloads. Google ships the
NDK and SDK build tools for x86_64 Linux only, so `Dockerfile.android` skips
them there and the stage passes media through.

### What the runtime lane adds for a GPU image

With `ENABLE_NVIDIA=true` the package copies the CUDA toolkit, cuDNN and NCCL
out of the media artifact (`copy-media-payloads.sh`), puts `nvcc` on `PATH`,
and fails when the toolkit is missing. The wrapper then resolves
`ONNX_PACKAGE=onnxruntime-gpu` and `PYTORCH_EXTRA=pytorch-cu130` unless an
operator pinned them, and its own gates assert `torch.version.cuda` and
`CUDAExecutionProvider`. A `--no-push` run hands the wrapper the android wheels
as a directory context; why not an OCI one is in
[`failure-modes.md`](failure-modes.md#a-no-push-wrapper-build-cannot-find-its-own-android-image).

### Running it on a Jetson

Rootless nerdctl needs three extra flags, each answering one failure:
[`linux-host-setup.md` § B2b](linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
[`linux/jetson-webcam/`](../linux/jetson-webcam/README.md) is a working example:
USB-camera object detection at 30 fps with 13 ms GPU inference.

### Known limits

- The official PyTorch `cu130` wheels warn that they do not target compute
  capability 8.7. What was run worked; a kernel with no Orin code will fail.
  ORT, OpenCV and TVM are built here with native `sm_87`.
- No TensorRT on this lane (see `ENABLE_TENSORRT`).
- Nothing from this lane is published. A `--no-push` build on a Jetson tags
  `latest-nvidia-hostarm64-arm64` locally (an image built before the variant
  naming is `latest-cross-hostarm64-arm64`). It does not become
  `:latest-nvidia-arm64`: the published arm64 entry is to come from a cross-sbsa
  lane on the amd64 host, which does not exist yet (`BACKLOG.md` CON31: no arm64
  route).

## DeepStream (nvidia variant)

> **On in every amd64 nvidia build, and never in `:latest` or `:latest-rocm`.** Since
> 2026-10-07 an nvidia chain on an amd64 build platform sets `ENABLE_DEEPSTREAM=true` itself
> (`stage-defs.sh`), and `ENABLE_DEEPSTREAM=false` opts one run out. An arm64 nvidia build gets
> no default, because DeepStream has no route there yet. A default or rocm chain refuses the
> flag. The owner allowed publishing it on 2026-10-01 (§ [Licence](#licence-the-owner-decision))
> and chose the full TensorRT 10 builder resources on 2026-10-07, so the image keeps every GPU
> generation, the RTX 2080's sm_75 included. Tracked as CON42 in [`BACKLOG.md`](../BACKLOG.md).

[NVIDIA DeepStream](https://github.com/NVIDIA/DeepStream) 9.1 is two things. Its
GStreamer plugins, utilities and apps are Apache-2.0 source. Its runtime (`nvvideoconvert`,
`nvv4l2decoder`, the tiler, `libnvbufsurface`, the tracker's `libnvds_nvmultiobjecttracker`,
the `nvds_*` libraries) is a prebuilt `.deb` under NVIDIA's SDK licence. The image unpacks
the `.deb` and builds the source against the image's own GStreamer 1.29.2, not against the
Ubuntu 24.04 GStreamer 1.24 that NVIDIA targets.

```bash
CROSS_VARIANT=nvidia bash linux/scripts/build-cross-chain.sh \
  --target-arches amd64 --parallel-archs --log-dir ./out/build-logs/nvidia
```

### What ships

| Path | What |
| --- | --- |
| `/opt/nvidia/deepstream/deepstream-9.1/` | the runtime `.deb`'s tree, plus the components built from `DEEPSTREAM_COMMIT` installed into it, as NVIDIA's `build/build.sh` does |
| `/opt/nvidia/deepstream/deepstream` | a link to it, which some upstream Makefiles and configs name |
| `…/deepstream-9.1/sources/includes/` | the SDK headers, for building custom parsers and plugins |
| `…/deepstream-9.1/LicenseAgreement.pdf` | NVIDIA's licence, as the `.deb` ships it |
| `/opt/nvidia/deepstream/tensorrt-10.16.1.11/` | DeepStream's own TensorRT 10 (§ TensorRT 10 beside 11) |
| `/opt/gstreamer/lib/<triplet>/gstreamer-1.0/deepstream` | a link to `…/lib/gst-plugins`; the registry scan follows it, so no `GST_PLUGIN_PATH` is needed |
| `/etc/ld.so.conf.d/010-deepstream-tensorrt.conf` | the TensorRT 10 lib dir, the only DeepStream path on the loader path |
| `/usr/lib/<triplet>/libnvinfer_builder_resource_*.so.10.16.1` | links into the TensorRT 10 prefix, which an engine build `dlopen()`s by file name (§ [TensorRT builder resources, by file name](#tensorrt-builder-resources-by-file-name)) |
| `/usr/lib/<triplet>/libv4l/plugins/libcuvidv4l2_plugin.so` | a link to NVIDIA's NVDEC plugin, so the distro `libv4l2` loads it (§ [NVDEC through the distro libv4l2](#nvdec-through-the-distro-libv4l2)) |
| `ENV USE_NEW_NVSTREAMMUX=yes` | the new `nvstreammux`; the legacy one fails on GStreamer ≥ 1.28 (§ [nvstreammux: the new one only](#nvstreammux-the-new-one-only)) |

`deepstream-9.1/lib` is deliberately **not** on the loader path. `libnvv4l2.so` there
carries the SONAME `libv4l2.so.0`, so `ldconfig` would hand NVIDIA's copy to every V4L2
user in the image (NVIDIA's `install.sh` does exactly that, with an `update-alternatives`
entry). The libraries find each other through their `RUNPATH`
(`/opt/nvidia/deepstream/deepstream-9.1/lib`); measured 2026-10-01, every element resolves
that way with `LD_LIBRARY_PATH` unset.

The script is `linux/scripts/05-frameworks/deepstream.sh` (`build` in the media stage,
`stage-runtime` or `assert-absent` in the package stage). Every download is pinned in
`versions.env` (`DEEPSTREAM_*`) with a SHA256: the release `.deb` (GitHub's asset digest),
the six TensorRT 10 debs (from the CUDA repo's `Packages` index), and the source commits.

### What needs a GPU host

- **The driver's own libraries**: `libcuda.so.1` and `libnvidia-ml.so.1` come from the host,
  injected by `nvidia-container-toolkit` (`--gpus all`, or `--device nvidia.com/gpu=all`
  through CDI; rootless nerdctl: [`linux-host-setup.md` § B2c](linux-host-setup.md#b2c-a-gpu-container-on-an-x86-desktop-with-rootless-nerdctl)).
  NVIDIA states driver 595.58.03 or newer for DeepStream 9.1. The image's `cuda-compat`
  libcuda is forward compatibility for data-centre GPUs only, so a GeForce card needs a new
  enough host driver itself.
- **Everything beyond registration.** Without a GPU the gates prove the elements load and
  register. Measured without a driver, `nvstreammux` stops at PAUSED with
  `Cuda failure: status=100` and `Unable to set device in gst_nvstreammux_change_state`
  (100 is `cudaErrorNoDevice`).

The gate command, from the sample data asset (`deepstream-sample-data_9.1.0.deb`, sha256
`21ee7ddc…5e98`, not in the image), in the image's environment, which sets
`USE_NEW_NVSTREAMMUX=yes` (§ [nvstreammux: the new one only](#nvstreammux-the-new-one-only)):

```bash
cd /opt/nvidia/deepstream/deepstream-9.1/samples/configs/deepstream-app
gst-launch-1.0 -e filesrc location=../../streams/sample_720p.h264 ! h264parse ! nvv4l2decoder \
  ! mux.sink_0 nvstreammux name=mux batch-size=1 \
  ! nvinfer config-file-path=config_infer_primary.txt ! fakesink
```

`config_infer_primary.txt` builds an FP16 engine from `resnet18_trafficcamnet_pruned.onnx`
on first use. The new mux has no `width`/`height` properties; `nvinfer` scales.

### The GPU run (2026-10-01)

**Passed**, on an RTX 2080 (sm_75, compute capability 7.5), host driver 595.58.03 through
CDI with rootless nerdctl. It ran in a throwaway container FROM the published `:latest` amd64
child as root: the variant's CUDA 13.4.2 + cuDNN 9.26.0.51 installed the way
`Dockerfile.nvidia` does (`ENABLE_TENSORRT=false`), then `deepstream.sh build` and
`deepstream.sh stage-runtime`. The pipelines ran in the package stage's environment (no CUDA
on `LD_LIBRARY_PATH`). Pass/fail and functional facts only; the licence forbids publishing
benchmark results (§ [Licence](#licence-the-owner-decision)).

| Check | Result |
| --- | --- |
| The nine gate elements register against the real driver, fresh registry | pass, no `Cuda failure` during the scan |
| TensorRT engine build for sm_75 (engine file removed first) | pass: `serialize cuda engine to file: …onnx_b30_gpu0_fp16.engine successfully` |
| `nvv4l2decoder` (NVDEC) with the distro `libv4l2` 1.32.0 | pass **with** the plugin link (§ [NVDEC through the distro libv4l2](#nvdec-through-the-distro-libv4l2)); without it, fail |
| decode → `nvstreammux` → `nvinfer` → `nvvideoconvert` → `nvdsosd` (`process-mode=1`, GPU) | pass: a pad probe on `nvdsosd` counted 1442 frames, all `NVBUF_MEM_CUDA_DEVICE`, 30214 objects in four classes |
| Two sources, batch 2, `nvinfer` → `nvtracker` (NvDCF, `config_tracker_NvDCF_perf.yml`) → `nvmultistreamtiler` → `nvdsosd` | pass: 2884 frames from both pads, every object carries a tracker id |
| `nvstreamdemux` back to two branches; `nvurisrcbin` on an MP4 | pass, both to EOS |
| An `nvdsosd` frame copied out to JPEG | pass: boxes and labels drawn on the cars and people |
| The same pipeline as the runtime user (uid 1001) | pass |
| CUDA 13.4 runs the 13.2-built kernels (phase 3) | pass: `libnvbufsurftransform.so` and the tracker (RUNPATH `/usr/local/cuda-13.2/lib64`, absent) load `libcudart.so.13.4.92` and run their sm_75 SASS; TensorRT 10.16 (a CUDA 13.2 build, `getInferLibVersion()` 101601) builds and runs the engine |
| The legacy `nvstreammux` (`USE_NEW_NVSTREAMMUX` unset) | **fail**, every time: § [nvstreammux: the new one only](#nvstreammux-the-new-one-only) |

Reproduce it in the package stage's environment, not with `Dockerfile.nvidia`'s `ENV`. That
stage puts `lib64/stubs` on `LD_LIBRARY_PATH` (the package stage replaces the variable).
There, the registry scan's `hip` plugin `dlopen()`s `libcuda.so`, gets the stub, and the
stub's SONAME `libcuda.so.1` then stands in for the driver for the rest of the scan: measured,
`nvh264dec`, `nvh264enc` and `cudaconvert` vanish from the registry and DeepStream's
`plugin_init` logs `Cuda failure: status=34` (`cudaErrorStubLibrary`). The build stages have
no GPU, so only a hand-run gate meets this.

Three defects surfaced, each fixed in the source (they need an nvidia chain run to reach an
image): the builder-resource links, the libv4l2 plugin link, and the mux switch below. A
fourth, outside DeepStream, turned the first into a segfault:
[`failure-modes.md` § An exception through std::call_once segfaults in libunwind](failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind).

### TensorRT builder resources, by file name

The first engine build stopped with
`Error Code 6: API Usage Error (Unable to load library: libnvinfer_builder_resource_sm75.so.10.16.1 … No such file or directory)`.
`libnvinfer.so.10` `dlopen()`s its builder resources by file name. Their SONAME is
`do_not_link_against_nvinfer_builder_resource_sm75`, and `ld.so.cache` holds only SONAMEs, so
the `ld.so.conf` entry for the private prefix does not help; `dlopen()` finds the file name
only in a default directory. A distro TensorRT lives there, the private copy does not.
`deepstream.sh` therefore links each `libnvinfer_builder_resource_*.so.10.16.1` into
`/usr/lib/<triplet>/` (in both `build` and `stage-runtime`), and the gates check the links.
The names carry the full TensorRT version, so they cannot collide with TensorRT 11's.

### NVDEC through the distro libv4l2

Without the link, `nvv4l2decoder` opened `/dev/nvidia0` as a plain V4L2 node:
`Error getting capabilities for device '/dev/nvidia0': It isn't a v4l2 driver`. NVDEC is
NVIDIA's libv4l2 plugin (`lib/libv4l/plugins/libcuvidv4l2_plugin.so`), and the distro
`libv4l2` loads plugins only from `/usr/lib/<triplet>/libv4l/plugins/` (a compile-time path,
no environment override). `stage-runtime` links the plugin there; with the link the decoder
runs on the distro `libv4l2`, so the SONAME hijack in NVIDIA's `install.sh` stays out.
Measured on a non-NVIDIA node (`v4l2_open("/dev/null")`): the plugin's `init` returns NULL
and `libv4l2` moves on. Without a driver its `dlopen()` fails on `libcuda.so.1`, which
`libv4l2` also skips. GStreamer's own `v4l2src` does not use `libv4l2` by default.

### nvstreammux: the new one only

NVIDIA's legacy `nvstreammux` is a prebuilt static archive
(`libnvdsgst_multistream_legacy.a`) linked into the source-built plugin, and it is the
default unless `USE_NEW_NVSTREAMMUX=yes`. On GStreamer 1.29.2 it accepts the first buffer and
returns `GST_FLOW_ERROR` with no message; the pipeline reports only
`h264parse0: Internal data stream error … reason error (-5)`. Traced instruction by
instruction: the legacy chain maps the input buffer, unmaps it, and then reads
`GstMapInfo.data`. Since GStreamer 1.28, `gst_memory_unmap()` calls `gst_map_info_clear()`,
which sets `memory`, `flags` and `data` to NULL to catch exactly that use-after-unmap, so the
check sees NULL and fails. GStreamer 1.24, which NVIDIA builds against, left the struct
alone.

The new mux (`gst-nvmultistream2`, Apache-2.0 source, built here) has no such read, and
NVIDIA's other readers of the switch (`libnvdsgst_customhelper.so`, `libnvds_yml_parser.so`)
follow the same variable. So `Dockerfile.package` sets `ENV USE_NEW_NVSTREAMMUX=yes` when
`ENABLE_DEEPSTREAM=true` and leaves it empty otherwise. Applications built for the legacy mux
must use the new mux's properties (`config-file-path`, no `width`/`height`).

Other prebuilt NVIDIA plugins may carry the same read. The run exercised `nvvideoconvert`,
`nvv4l2decoder`, `nvmultistreamtiler` and the tracker library, all without failures; the
rest of the prebuilt plugins (`deepstream_bins`, `dewarper`, `of`, `segvisual`, …) were not
run.

**GPU architectures.** NVIDIA's prebuilt kernels carry SASS for sm_75, 80, 89, 90, 100,
110, 120 and 121, plus PTX for sm_90. The two source components with CUDA code
(`nvdsinfer`, `nvll_osd`) build with nvcc's default, sm_75 SASS plus sm_75 PTX, so they run
on every card from Turing on (newer ones JIT the PTX once). TensorRT 10.16 ships builder
resources for sm_75, 80, 86, 89, 90, 100 and 120. So the RTX 2080 (sm_75) can run
DeepStream, although the variant's `CUDA_ARCHITECTURES` (86;87;89;120) leaves it out of
ONNX Runtime and OpenCV.

### TensorRT 10 beside 11

DeepStream 9.1 needs TensorRT 10, and the variant pins 11.3:

- NVIDIA's prebuilt `libnvds_nvmultiobjecttracker.so`, `libnvds_inferutils.so` and
  `libnvds_utils.so` link `libnvinfer.so.10` (and `libnvonnxparser.so.10`).
- The Apache-2.0 `nvdsinfer` does not compile against TensorRT 11.3: 56 errors, from
  `IInt8Calibrator`, `BuilderFlag::kINT8`/`kFP16`, `kEXPLICIT_BATCH`,
  `IBuilder::platformHasFastFp16`, `ITensor::setType` and `ILayer::setPrecision`, all
  removed in 11.

So the image carries TensorRT 10.16.1.11 privately. NVIDIA publishes it only in the
`ubuntu2404` CUDA repo, built for CUDA 13.2. The sonames differ (`.10` vs `.11`), so the two
do not collide on disk or in `ld.so.cache`.

**One process must not have TensorRT 11 in its global symbol scope.** Both libraries
export the same unversioned symbols (`createInferBuilder_INTERNAL`, `getInferLibVersion`,
…). Measured 2026-10-01 with a library linked against `libnvinfer.so.10`, loaded after
`libnvinfer.so.11`:

| TensorRT 11 opened with | the `.10` library's `getInferLibVersion()` |
| --- | --- |
| `RTLD_LOCAL` | 101601 (its own, correct) |
| `RTLD_GLOBAL` | 110300 (TensorRT 11's, the wrong ABI) |

GStreamer loads plugins with local binding, and ONNX Runtime opens its TensorRT EP the same
way, so the image's own consumers stay apart. An application that links `libnvinfer.so.11`
directly, or `dlopen`s it with `RTLD_GLOBAL`, must not also run DeepStream's `nvinfer` or
`nvtracker`.

`ENABLE_TENSORRT` stays `false` for the variant; DeepStream does not need it.

### CUDA 13.2 vs 13.4

The runtime is built against CUDA 13.2, the variant ships 13.4.2. Measured: every CUDA
soname the tree needs (`libcudart.so.13`, `libcublas.so.13`, `libcufft.so.12`,
`libnpp*.so.13`, `libnvjpeg.so.13`) resolves against 13.4.2 through `ld.so.conf`, and `ldd -r`
reports no missing symbol in any library whose sonames all resolve. The `RUNPATH` entry
`/usr/local/cuda-13.2/lib64` in NVIDIA's binaries simply does not exist here. The kernels
run on 13.4 as well ([§ The GPU run](#the-gpu-run-2026-10-01)).

### What the build changes against upstream

Each of these is a measured failure of NVIDIA's own `build/build.sh` flow in this image:

- **GCC 16.** Its libstdc++ no longer includes `<cstdint>` and `<algorithm>` transitively,
  and `-Werror` turns its new `non-c-typedef-for-linkage` warning into an error. The build
  pre-includes a compat header through `CXX`, `CC` and `NVCC_PREPEND_FLAGS`, and adds
  `-Wno-error=non-c-typedef-for-linkage` where the compiler is C++. Each Makefile keeps its
  own compiler: `gstnvcustomhelper` compiles C with `CXX:=gcc` (g++ rejects its enum
  conversions), `nvds_analytics` compiles C++ with make's default `cc`, and a `CC:=g++`
  must stay g++ or libstdc++ goes unlinked. Affected: `nvds_analytics`, `gst-nvdsmetamux`,
  `gst-nvdspreprocess` and two `ds3d` CUDA libraries.
- **nvcc and `/usr/include/gstreamer-1.0`.** `gst-nvvideotestsrc` hard-codes the distro
  include path for its CUDA file; the build hands nvcc `/opt/gstreamer`'s through
  `NVCC_CFLAGS`, which that Makefile appends to.
- **Only plugins in `lib/gst-plugins/`.** Upstream installs `libpostprocess_impl.so` and
  `libcustom2d_preprocess.so` there. The registry scan `dlclose()`s them, which unloads
  libraries that registered static quark strings, and the next plugin segfaults in
  `g_quark_from_static_string` (seen with `nvmultistreamtiler`, from a clean registry). The
  build moves them to `lib/`.
- **Headers at `sources/includes`**, placed before the build: `ds3d/dataloader/lidarsource`
  includes from there, the full SDK's layout.
- **`/opt/nvidia/deepstream/deepstream`**, also before the build: `nvmsgbroker`,
  `gst-nvdynamicsrcbin` and others link from it.
- **protoc**: Ubuntu 26.04's `protoc` is 3.21.12, the version upstream downloads, so the
  build uses it rather than a second copy.
- **opentelemetry-cpp without gRPC**: `nvds_rest_server` uses only the OTLP HTTP exporter.

Not built, each with its reason in `DS_EXCLUDED` (`deepstream.sh`): the Triton pair
(`nvdsinferserver`, `gst-nvinferserver`; no Triton server in the image), the two Azure IoT
adaptors (no azure-iot-sdk-c), `gst-nvdsudp` (NVIDIA's login-gated Rivermax SDK) and
`gst-dsexample-cuda` (an example; upstream skips it too).

### The gates

`linux/scripts/05-frameworks/deepstream-verify.sh`, run at the end of the media build, in
the package stage (against the wired plugin link) and by the runtime smoke
(`check_deepstream`, which also fails a tree in any non-nvidia image):

- **Soname closure** with `LD_LIBRARY_PATH` unset. `libcuda.so.1` and `libnvidia-ml.so.1`
  are the driver's. Eleven other misses are documented exceptions (UCX, RealSense, libtorch,
  NVIDIA Maxine, the Triton filter, and `libnvdsgst_sparse4d.so`, whose `RUNPATH` NVIDIA left
  pointing at `deepstream-9.0`); an exception that stops applying fails as stale. The
  third-party libraries built for `nvds_rest_server` get an `$ORIGIN` `RUNPATH`, since their
  own install paths do not exist in the image.
- **One GStreamer**: every plugin resolves `libgst*-1.0.so.0` from `/opt/gstreamer`, and the
  tree ships no GStreamer core library.
- **No libv4l2 hijack**: the lib dir is on no `ld.so.conf`, and `libv4l2.so.0` resolves to the
  distro's.
- **Only plugins in `gst-plugins/`**, and a registry scan that does not crash. The check
  reads `nm` to the end: a `grep -q` under `pipefail` SIGPIPEs `nm` on a large plugin, and
  the first run moved `libgstnvvideo4linux2.so` out that way.
- **The `dlopen()` links**: every TensorRT builder resource resolves by file name from the
  default directory (build and package), and the package's `libv4l2` plugin dir holds the
  NVDEC plugin (`DSV_WIRED=1` only).
- **Registration** of `nvinfer`, `nvstreammux`, `nvvideoconvert`, `nvtracker`, `nvdsosd`,
  `nvv4l2decoder`, `nvmultistreamtiler`, `nvstreamdemux` and `nvurisrcbin`, with CUDA's stub
  `libcuda`/`libnvidia-ml` standing in for the driver.

Not covered by the gates: inference, NVDEC, a TensorRT engine build. The GPU run above
covered them once; no lane has a GPU.

### Licence: the owner decision

The runtime `.deb` ships NVIDIA's *Software License Agreement for NVIDIA Software
Development Kits* (v. September 14, 2021) with a *DeepStream Supplement*, as
`LicenseAgreement.pdf`. The repository's README says all release assets fall under it. The
passages that decide publishing on GHCR:

- § 1.1 (iii): the licence to "Distribute those portions of the SDK that are identified in
  this Agreement as distributable, as incorporated in object code format into a software
  application that meets the distribution requirements".
- § 1.2 (i): "Your application must have material additional functionality, beyond the
  included portions of the SDK."
- § 2.2: "you may not distribute or sublicense the SDK as a stand-alone product."
- Supplement § 1: "The following portions of the SDK are distributable under the Agreement:
  the runtime files ending with “.so” as part of your application".
- Supplement § 3 I: "You are not permitted to disclose the results of any benchmarking or
  other competitive analysis relating to the SDK without the prior written permission from
  NVIDIA". So this page records no DeepStream timings.
- Supplement § 3 II: "The SDK is licensed for use with a computer system incorporating one
  or more NVIDIA GPU hardware products and running NVIDIA software drivers."

What the image would redistribute that is not a `.so`: `LicenseAgreement.pdf`, the static
`libnvdsgst_multistream_legacy.a` and `libnvds_service_maker_utils.a`, and the
`pyservicemaker` wheel. TensorRT 10 falls under its own EULA, like the TensorRT 11 question
already open for `:winamd64` (`docs/third-party-licenses.md`, `eula-review`).

Whether a general-purpose development image counts as an "application" with "material
additional functionality" is a legal question, not a build one.

**Decided 2026-10-01: the owner allows publishing it** in `:latest-nvidia`. The chain no
longer refuses a push with `ENABLE_DEEPSTREAM=true`. What ships is held to the supplement's
words where that costs nothing: the package stage deletes the two static `.a` archives (a
build-time input only), and `LicenseAgreement.pdf` ships beside the runtime. The
`pyservicemaker` wheel stays. No page here records DeepStream timings (Supplement § 3 I).

## The media fan-out strategy, as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

`Dockerfile.media` uses a parallel multi-stage DAG (BuildKit runs independent stages concurrently):

```
base ─┬─ onnxruntime ───────┐
      ├─ litert ────────────┤
      ├─ opencv ────────────┼─ media-inputs ─ gstreamer ─ libcamera ─ final
      ├─ ffmpeg ────────────┤
      └─ app-wheelhouse ────┘
```

- `--mount=type=cache` (apt/ccache/sccache/uv/pip/cargo) keyed per-arch via `id=...-${TARGETARCH}`, `sharing=locked`.
- `--mount=type=bind,readonly` for per-library build scripts — no COPY layer, so editing one library's scripts invalidates only that RUN, not downstream layers.
- `--mount=type=tmpfs` for `/tmp` scratch (no layer bloat).
- `COPY --link` for layer-parallel copying from independent build stages.
- Shared/common files (`core/common.sh`, `activate-cross-python.sh`, `verify-media-artifacts.sh`, 01-core helpers) are COPY'd in the `base` stage (rarely change → stable cache).
- Runtime scripts are COPY'd only in the `final` stage (must persist in the published image; build scripts are NOT shipped).

## Torch Add-on (Linux)

Builds on the package image (`BASE_IMAGE`, default `:latest-package-<arch>`), and
the runtime lane builds it as the per-arch wrapper `:latest-<arch>`
(`build-runtime-manifest.sh`). The old standalone `:torch` tag was deleted from
the registry on 2026-08-27. A local build:

```bash
nerdctl build -t local/kataglyphis:torch-amd64 -f linux/Dockerfile.torch .
```

## AMD GPU Build (Linux)

> **Tag: `:latest-rocm`** (a manifest; per-arch wrapper `:latest-rocm-amd64`) —
> spelled `rocm`, not `amd`, because a variant never reads like an architecture
> (`:latest-amd-amd64`). **Not published yet.** The old single-arch `:amd` (a
> 2026-04-24 build on the Ubuntu 24.04 base) and its stage tags were deleted from
> the registry on 2026-09-22.

> **Requirements:**
> - Host driver compatible with ROCm 10.1 (see the [compatibility matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html)).
> - `--device=/dev/kfd --device=/dev/dri` passed to `docker run`.

The ROCm variant chain inserts `Dockerfile.amd` as its `gpu` stage **after** the shared `:cross-sdk-amd64` and before media; the later stages run with `ENABLE_AMD=true`.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.amd` | Installs ROCm 10.1 + MIGraphX 2.18 from AMD TheRock repo (HIP, MIOpen, RCCL, rocBLAS, rocFFT, MIGraphX) |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with MIGraphX EP when `ENABLE_AMD=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the AMD media image |
| `linux/Dockerfile.torch` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/build/onnxruntime/build/30-build-native-amd.sh` | ORT build script with MIGraphX EP |

**Notes:**
- The ROCm version is pinned by `ROCM_VERSION` in `linux/scripts/01-core/versions.env`.
  `linux/scripts/01-core/setup-rocm-repo.sh` adds the TheRock apt repos in deb822
  `.sources` format (`stable.repo.amd.com`), with core ROCm and MIGraphX as
  separate repo stanzas sharing the same GPG key and Origin ("AMD ROCm").
  Package names use the `amdrocm-*` prefix, and every name the script installs
  carries the ROCm release ([below](#the-rocm-release-is-in-every-package-name)).
  `MIGRAPHX_VERSION` moves together with `ROCM_VERSION`.
- MIGraphX packages come from a separate repo path (`/rocm/migraphx/packages/ubuntu2604/`) on the same `stable.repo.amd.com` host. The toolchain image pins the AMD repo to provide only ROCm/MIGraphX packages via an apt pin on Origin "AMD ROCm".
- The ONNX Runtime MIGraphX Execution Provider replaces the older ROCm EP. The build script passes `--use_migraphx --migraphx_home <MIGraphX's prefix>` (`/opt/rocm/extras-10` on 10.1, [below](#where-rocm-101-puts-migraphx)) instead of `--use_rocm`.
- The build produces an `onnxruntime-migraphx` Python wheel (instead of `onnxruntime-rocm`).
- The media stage strips all external apt sources from the SDK base image and configures clean resolute-only sources to prevent cross-distro package conflicts. 01-core modules are bind-mounted into build stages so `media_common_init()` can locate cross-build helpers.

**Build (orchestrated):**

```bash
CROSS_VARIANT=rocm bash linux/scripts/build-cross-chain.sh \
  --target-arches amd64 --log-dir ./out/build-logs/rocm
```

Same variant rules as NVIDIA (starts at `gpu`, own state, one chain at a time),
plus: **amd64 only** — any other `--target-arches` is refused. The runtime lane
copies `/opt/rocm` into the package (`copy-media-payloads.sh`
`copy_rocm_payload`; `publish_rocm_ld_path` writes `/etc/ld.so.conf.d/000-rocm.conf`), and the wrappers
take `onnxruntime-migraphx` + the app's `pytorch-rocm10` extra. That extra reads
the same wheel line as the pinned `PYTORCH_ROCM_INDEX` (`rocm7.14`, the newest
carrying torch 2.14 for cp314 — there is no rocm10 line), so
`assemble-torch-app.sh`'s re-install of the `PYTORCH_VERSION` pair from it (with
deps, so `triton-rocm` moves with it) only acts if the two drift. The extra was
`pytorch-rocm71` up to OrchestrANT v0.0.28; the wrapper builds the app's
`develop` since 2026-09-29
([`linux-cross-builds.md`](linux-cross-builds.md#the-app-the-wrapper-builds)).

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --device=/dev/kfd --device=/dev/dri ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-rocm
```

### The ROCm release is in every package name

AMD's `stable` suite is rolling: ROCm 10.1 joined it on 2026-09-30, beside 10.0.
A versionless metapackage such as `amdrocm-core-dev` depends on the newest
release's package (`amdrocm-core-dev10.1`), so `ROCM_VERSION=10.0` did not pin
the install. `amdrocm-migraphx` 2.17.0 still needs the 10.0 libraries, so one
install got both trees: 262 packages of 10.1 and 73 of 10.0 (`apt-get install
-s`, 2026-10-07).

`setup-rocm-repo.sh` therefore installs versioned names only. `rocm_packages`
builds them from `ROCM_VERSION` and `MIGRAPHX_VERSION`:

| Package | ROCm 10.0 | ROCm 10.1 and later 10.x |
| --- | --- | --- |
| core, runtime, blas, dnn, hipblas-common, fft, rccl, sparse, solver | `amdrocm-<name>-dev10.0` | `amdrocm-<name>-dev10.1` |
| MIGraphX and its `-dev` | `amdrocm-migraphx=<MIGRAPHX_VERSION>+rocm10.0.*` | `amdrocm10-migraphx=<MIGRAPHX_VERSION>-*` |
| ASAN (`ENABLE_ROCM_ASAN=true`) | `amdrocm-asan10.0` | `amdrocm-asan10.1` |

- Any other release stops the script before its first download:
  `no MIGraphX package name known for ROCm <release>`. Add the release's
  MIGraphX name to `rocm_packages` first.
- A `MIGRAPHX_VERSION` that the release does not ship stops `apt-get install`:
  `Version '2.18.0+rocm10.0.*' for 'amdrocm-migraphx' was not found`.
- After the last install, every installed `amdrocm*` package whose name carries a
  release must carry `ROCM_VERSION`. Otherwise the build stops and lists them.
- `test-rocm-packages.sh` fails when `versions.env` names a release that
  `rocm_packages` does not know, so a ROCm bump cannot skip this table.

Measured with `apt-get install -s` on 2026-10-07: the 10.0 list selects 251
packages, 249 named `…10.0` plus the two MIGraphX ones (`2.17.0+rocm10.0.0`).
With ASAN it is 281, again all 10.0. The 10.1 list, the pin since that day,
selects 264: 262 named `…10.1` (all `10.1.0-3`) plus `amdrocm10-migraphx` and
`amdrocm10-migraphx-dev` at `2.18.0-1`. With ASAN it is 298, again all 10.1. The
real install is 7.0 GB of downloads and 21.7 GB on disk, and the release check
passes on it.

### Where ROCm 10.1 puts MIGraphX

Measured on 2026-10-07: the 10.1 list installed in `:latest`, and the 10.0
packages' file lists (`dpkg-deb -c`):

| What | ROCm 10.0 (`amdrocm-migraphx` 2.17.0) | ROCm 10.1 (`amdrocm10-migraphx` 2.18.0) |
| --- | --- | --- |
| MIGraphX headers, `migraphx-config.cmake`, `libmigraphx_c.so.3` | `/opt/rocm/{include,lib/cmake/migraphx,lib}` | `/opt/rocm/extras-10/{include,lib/cmake/migraphx,lib}` |
| The other MIGraphX libraries, behind `libmigraphx_c`'s RUNPATH | `/opt/rocm/lib/migraphx/lib` | `/opt/rocm/extras-10/lib/migraphx/lib` |
| `migraphx-driver` | `/opt/rocm/bin` | `/opt/rocm/extras-10/bin`, on no `PATH` |
| `/opt/rocm/lib` | MIGraphX's directory, with no HIP in it | the `rocm-lib` alternative, `core-10.1/lib` |

In 10.1, `/opt/rocm/{core,bin,include,lib}` are all alternatives links into
`core-10.1`, beside a new `core-10` link. `core-10.1` carries HIP 7.16.26385 and
AMD clang 24.

Three places followed MIGraphX out of `/opt/rocm/lib`:

- **`setup-rocm-repo.sh`** writes the directory holding `libmigraphx_c` into
  `/etc/ld.so.conf.d/rocm.conf`, beside `/opt/rocm/lib`. It finds `migraphx.hpp`
  anywhere under `/opt/rocm`, and fails unless `ldconfig -p` lists
  `libmigraphx_c`. The first 10.1 install stopped at `migraphx.hpp not found`.
- **`30-build-native-amd.sh`** passes ORT MIGraphX's own prefix as
  `--migraphx_home`. It is the directory above `lib/cmake/migraphx`, found under
  `MIGRAPHX_HOME`, which stays the ROCm root for the HIP probe. ORT's
  `find_package(migraphx REQUIRED PATHS /opt/rocm)` does not reach `extras-10`.
  A CMake probe that copies ORT v1.30.0's lookup failed with `/opt/rocm`. With
  `/opt/rocm/extras-10` it found MIGraphX 2.18.0 and the external-data API, and
  linked and ran without a GPU. The script itself then built ORT v1.30.0 against
  the install in a throwaway `:latest` container. It made an
  `onnxruntime_migraphx-1.30.0` cp314 wheel that lists
  `MIGraphXExecutionProvider`. With no GPU, a session loads the EP and stops at
  `HIP failure 100: no ROCm-capable device`, then falls back to CPU.
- **`publish_rocm_ld_path`** adds the same directory to the runtime image's
  `000-rocm.conf`, because `libonnxruntime_providers_migraphx.so` needs
  `libmigraphx_c.so.3`.

TheRock's LLVM is clang 24 now. `Dockerfile.package` borrows libFuzzer only from
a same-major `clang/23` copy, so a rocm image no longer finds one to borrow.
That changes nothing while the image's own LLVM 23 ships libFuzzer, which
`:latest` does.

## ROCm: what the first `:latest-rocm` run must carry (planned, 2026-09-22)

Measured against AMD's current docs and the live repo indexes before the first
rocm chain run. Everything here is verified against **TheRock** packages
(`stable.repo.amd.com`, `amdrocm-*`) on **Ubuntu 26.04**, which is what
`setup-rocm-repo.sh` installs — not the classic `repo.radeon.com` `rocm-*` set
most AMD pages still describe.

### ASAN: a separate image, never `:latest-rocm`

The owner asked for the AddressSanitizer packages alongside the normal ones
([install/asan.html](https://rocm.docs.amd.com/en/latest/install/asan.html?fam=all&os=ubuntu&ubuntu-ver=26.04&i=tar)).
They exist for ROCm 10.0 / Ubuntu 26.04, in a parallel repo path
(`.../core/packages-asan/ubuntu2604/`, same signing key), as
`amdrocm-asan10.0`, `amdrocm-core-devel-asan10.0`,
`amdrocm-developer-tools-asan10.0`, `amdrocm-opencl-asan10.0`,
`amdrocm-core-sdk-asan10.0`. Four facts decide the shape:

1. **Size.** Measured from that repo's `Packages.gz` on 2026-09-22: 143
   packages, `amdrocm-llvm-dev-asan10.0` alone **61.7 GiB** installed,
   `amdrocm-llvm-asan10.0` 29.3 GiB, **134.8 GiB** for the full set. A
   `:latest-rocm` that carries this is not shippable.
2. **GPU coverage.** Every one of the 30 gfx-specific ASAN packages is
   gfx942 or gfx950 (MI300/MI350). On any other AMD GPU the instrumented
   libraries do nothing.
3. **Not the headline feature.** There is no ASAN MIGraphX and no ASAN PyTorch
   wheel line, so the two things this image exists for stay uninstrumented.
4. **Co-installing hijacks `update-alternatives`.** The ASAN debs register the
   same alternatives as the normal packages (`core`, `rocm-lib`, `rocm-bin`,
   `hipcc`, …) with the same priority, so `/opt/rocm/lib`, `/opt/rocm/bin` and
   `/usr/bin/hipcc` can silently resolve into `/opt/rocm/core-asan-10.0`. The
   outcome is a coin flip between rebuilds, not a deterministic last-wins.

ROCm 10.1 (the same `Packages.gz`, 2026-10-07) is far smaller but not otherwise
different. It has 94 ASAN packages and 47.0 GiB for the full set, and
`amdrocm-llvm-dev-asan10.1` is 2.0 GiB. Counted the same way, 10.0 has 91
packages and 134.8 GiB. The gfx-specific packages are still gfx942 and gfx950
only.

**Decided and implemented (owner, 2026-09-22): optional, and OFF.** A >100 GiB
image is not acceptable as the default, so `ENABLE_ROCM_ASAN` (`Dockerfile.amd`,
default `false`) gates the whole thing:

- The parallel `packages-asan` repo stanza is only written when the knob is on,
  and only `amdrocm-asan${ROCM_VERSION}` is installed — not the SDK metapackage
  that drags in the 61.7 GiB `amdrocm-llvm-dev-asan10.0`.
- After that install, `setup-rocm-repo.sh` re-`--set`s every alternative whose
  value points into `core-asan-*` back to `core-${ROCM_VERSION}` and then
  ASSERTS that `/opt/rocm/{core,lib,bin}` and `hipcc` resolve to the normal
  tree. The build fails if they do not.
- `copy_rocm_payload` deletes `/opt/rocm/core-asan-*` from the payload unless
  the knob is on, so a default `:latest-rocm` cannot carry it even if a builder
  installed it by hand.
- Runtime stays the consumer's business and is never baked: `HSA_XNACK=1` and
  `LD_LIBRARY_PATH`/`LD_PRELOAD` into the ASAN prefix, documented in the run
  recipe. The ASAN directories never enter `/etc/ld.so.conf.d/`:
  `publish_rocm_ld_path` prunes `core-asan-*`, whose `lib` holds a
  `libamdhip64` of its own.

The **tarball** install the owner's URL selects (`i=tar`) stays the better shape
if the alternatives dance ever misbehaves: it unpacks to a prefix we choose and
registers no alternatives at all. The apt route is what is wired, because it
keeps the signed-repo supply chain we already pin.

**The install half ran once, in a throwaway container (10.1, 2026-10-07).** No
image build has run it. `setup-rocm-repo.sh` ran with `ENABLE_ROCM_ASAN=true`
over the installed 10.1 list and exited 0:

- It added 34 ASAN packages, a 6.2 GB download and 29 GB in
  `/opt/rocm/core-asan-10.1`.
- No alternative points into `core-asan` afterwards, and
  `/opt/rocm/{core,lib,bin}` and `hipcc` resolve into `core-10.1`.
- The release check passed over all 298 packages.

That run also showed that `publish_rocm_ld_path` would have put
`core-asan-10.1/lib` on the loader path.

The ASAN libraries only do anything on gfx942/gfx950 hardware, which no lane
has.

### The non-ASAN work the same sweep turned up

| # | Change | Why |
| --- | --- | --- |
| 1 | Install per-gfx metapackages instead of the all-architecture ones | `amdrocm-core-dev10.0` pulls all 25 gfx targets (19.6 GiB). The single largest size win: ~18.4 GiB → 9-13 GiB. |
| 2 | `ROCM_PATH`, `HIP_PATH` and `/opt/rocm/bin` on `PATH` in the shipped image | The wrapper has none of them today; every consumer recipe starts by setting them. |
| 3 | Assert the installed ROCm and MIGraphX versions at the end of `Dockerfile.amd` | **Done 2026-10-07**, in `setup-rocm-repo.sh`: every name carries the release, MIGraphX is pinned through apt, and a package of another release fails the build ([§ The ROCm release is in every package name](#the-rocm-release-is-in-every-package-name)). |
| 4 | Write the RESOLVED path into `/etc/ld.so.conf.d/000-rocm.conf` | It currently writes the literal `/opt/rocm/lib`, which re-resolves through alternatives in a derived image. |
| 5 | `/dev/kfd` access for uid 1001, documented with numeric host GIDs (or the udev rule), plus `--device /dev/kfd --device /dev/dri --group-add`, `--ipc=host`, `--shm-size` | Our documented run line is incomplete; the image runs non-root and cannot open the device as shipped. |
| 6 | Do NOT add `--security-opt seccomp=unconfined` to the documented run command, and never bake `HSA_OVERRIDE_GFX_VERSION` | Both are cargo-cult carried from old ROCm guides; the first weakens every consumer's sandbox, the second silently lies about the GPU. |
| 7 | Writable MIOpen cache/db paths | The image is designed to run `--read-only`; MIOpen writes on first use. |
| 8 | Build-time self-check that works with NO GPU | `hipconfig`, `rocm_agent_enumerator`, `migraphx-driver`, `ldd`, and ONNX Runtime listing `MIGraphXExecutionProvider` all work GPU-less; `rocminfo`/`amd-smi` need a device. Write `amd-smi`, not `rocm-smi` (deprecated in ROCm 10.0). |
| 9 | Point consumers at AMD's Container Runtime Toolkit (CDI), which supports nerdctl | Cleaner than hand-rolled device flags, and it covers Ubuntu 26.04. |
| 10 | Fix the Renovate comment on `ROCM_VERSION` | It watches a TheRock git tag, not the apt package we install. |

Checked and NOT applicable: `PYTORCH_ROCM_ARCH` (a source-build knob; we install
prebuilt wheels) and `GPU_TARGETS`/`AMDGPU_TARGETS` (no such knob for the
MIGraphX EP build). The kernel driver stays on the HOST — the image ships
userspace only, and that is correct.

## Hailo (in the standard image)

HailoRT + `hailortcli` + the `hailonet` element + **TAPPAS** (`hailofilter`,
`hailocropper`, `hailooverlay`, `hailoaggregator`, `hailotracker`, ...) +
pyhailort are built into the **standard runtime** (`:latest`) for amd64 and
arm64, for hosts with a Hailo-10H accelerator (Hailo-8 support was dropped
2026-09-20; riscv64 has no HailoRT support). There is **no separate Hailo tag**:
the standalone `:hailo` variant and `linux/Dockerfile.hailo` were retired on
2026-09-22 as a duplicate of this build (owner directive: a variant exists only
for a stack that cannot ship in `:latest`). Design, upstream matrix and pins:
[`hailo-support.md`](hailo-support.md). The PCIe kernel driver is host-only
(GPL-2.0, DKMS) — the image needs `--device=/dev/hailo0`.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.torch` | The Hailo `RUN` in the standard wrapper: builds the payload natively in the runtime image (amd64/arm64; riscv64 skips) |
| `linux/scripts/03-media/build/hailo/build-hailort.sh` | Verified sources → offline CMake build → self-checks (`hailortcli --version`, `gst-inspect-1.0 hailonet`) |
| `linux/scripts/03-media/build/hailo/hailo-build-lib.sh` | The build's two switches, `HAILO_NESTED_CACHE` and `HAILO_PYHAILORT_IPO`, and the checks behind them |
| `linux/scripts/01-core/versions.env` | `HAILORT_*`, `HAILO_PROTOBUF_*`, `TAPPAS_*` pins (also the Dockerfile ARG defaults) |

**Build:** the normal chain (`make cross-build`, or `build-cross-chain.sh`) —
nothing Hailo-specific to run. Two switches pick between the default (the
cached nested build, a real pyhailort) and the build as it was before
2026-09-24: [`hailo-support.md`](hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches).

**Run:**

```bash
nerdctl run --rm -it --device=/dev/hailo0 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

## Edge accelerators

These are host/device procedures for the boards the runtime artifacts get
deployed to. Host-side driver and performance setup is
[Linux Host Setup](linux-host-setup.md). The images themselves are covered
elsewhere: Hailo-10H is built into `:latest`
([`hailo-support.md`](hailo-support.md)), and a Jetson runs the arm64 SBSA GPU
image ([above](#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson)).

### Hailo-10H: compiling an ONNX model to `.hef`

The Hailo toolchain does not consume ONNX at runtime. A model goes through
three stages — parse, quantize, compile — and each emits an intermediate `.har`.

**1. Parse.** Let the parser infer the graph boundaries first:

```bash
hailo parser onnx /local/shared_with_docker/model.onnx --hw-arch hailo10h
```

If it cannot resolve the ends of the graph, pin them explicitly. The node names
are model-specific — read them off the failure message or a Netron dump:

```bash
hailo parser onnx /local/shared_with_docker/model.onnx \
  --hw-arch hailo10h \
  --start-node-names images \
  --end-node-names Conv_1058 Conv_1065 Conv_1088 \
  --tensor-shapes "[1,3,640,640]"
```

**2. Quantize.** Needs a model script (`.alls`) and a calibration set:

```bash
hailo optimize /local/shared_with_docker/model.har \
  --hw-arch hailo10h \
  --output /local/shared_with_docker/model_quantized.har \
  --model-script /local/shared_with_docker/model.alls \
  --use-random-calib-set
```

A minimal `.alls`:

```
post_quantization_optimization(finetune, policy=enabled, learning_rate=1e-5, epochs=3, batch_size=16, dataset_size=64)
performance_param(compiler_optimization_level=2)
```

`--use-random-calib-set` is for smoke-testing the pipeline only — accuracy will
be poor. For a real run, supply images:

```bash
wget http://images.cocodataset.org/zips/val2017.zip
mkdir -p /local/shared_with_docker/coco/
unzip val2017.zip -d /local/shared_with_docker/coco/
```

Some tools want a single `.npy` instead of a directory:

```python
import os
import numpy as np
from PIL import Image

image_dir = "./images_for_calibration"
output_file = "calib_data.npy"
image_size = (640, 640)   # match the model input
num_images = 100

all_images = []
for i, file in enumerate(sorted(os.listdir(image_dir))):
    if i >= num_images:
        break
    if file.lower().endswith((".jpg", ".jpeg", ".png")):
        img = Image.open(os.path.join(image_dir, file)).convert("RGB")
        img = img.resize(image_size)
        all_images.append(np.array(img, dtype=np.uint8))   # uint8 for Hailo

np.save(output_file, np.stack(all_images))
print(f"Saved {len(all_images)} images to {output_file}")
```

**3. Compile:**

```bash
hailo compiler /local/shared_with_docker/model_quantized.har \
  --output-dir /local/shared_with_docker/
```

For a model the Hailo Model Zoo already knows, the three steps collapse into one:

```bash
hailomz compile yolov9c \
  --ckpt /local/shared_with_docker/yolov9c.onnx \
  --classes 80 --hw-arch hailo10h \
  --calib-path /local/shared_with_docker/coco/val2017/val2017
```

Inspect a compiled graph with `hailo visualizer /path/to/model.har`.

For a calibration set in TFRecord form rather than a directory of images, the
Model Zoo ships the converters:

```bash
python hailo_model_zoo/datasets/create_coco_tfrecord.py val2017
python hailo_model_zoo/datasets/create_coco_tfrecord.py calib2017
```

Format reference:
[hailo_model_zoo DATA.rst](https://github.com/hailo-ai/hailo_model_zoo/blob/master/docs/DATA.rst).

### Hailo-10H: the driver

The PCIe module is not loaded automatically — after every reboot:

```bash
sudo modprobe hailo_pci
```

Before installing a **new** driver version, remove the old one or the DKMS build
will collide with the loaded module:

```bash
lsmod | grep hailo
sudo modprobe -r hailo_pci
sudo dkms status
sudo dkms remove <module>/<version> --all
```

On a Raspberry Pi this sometimes requires a kernel built from source — see the
[Raspberry Pi kernel documentation](https://www.raspberrypi.com/documentation/computers/linux_kernel.html).

### NVIDIA Jetson

Identify the board and capture a full spec dump before filing anything:

```bash
cat /proc/device-tree/model     # e.g. NVIDIA Jetson Orin NX ...
inxi -Fxxx > jetson-specs.txt
```

Power mode gates clock speeds and therefore every benchmark number:

```bash
sudo nvpmodel -q                # query the active mode
```

**Never let unattended-upgrades touch Docker on a Jetson.** In
`/etc/apt/apt.conf.d/50unattended-upgrades`, the `"Nvidia:jetson"` origin is
fine; adding `"Docker:jammy"` is not — the upgrade breaks the Jetson container
runtime integration and `docker` fails to start
([NVIDIA forum thread](https://forums.developer.nvidia.com/t/failed-to-start-docker/324791/3)).

If it already happened, pin back:

```bash
sudo apt-get install -y --allow-downgrades \
  docker-ce=5:27.5.1-1~ubuntu.22.04~jammy \
  docker-ce-cli=5:27.5.1-1~ubuntu.22.04~jammy
```

The torchvision note below applies to NVIDIA's JetPack wheels installed on the
board itself. The SBSA image above needs none of it:
[NVIDIA on arm64 (SBSA)](#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson).

**torchvision must be built from source.** The Jetson PyTorch wheels come from
NVIDIA, not PyPI, and the matching torchvision is not published — installing it
with pip pulls a build against the wrong torch:

```bash
sudo apt-get update
sudo apt-get install -y libjpeg-dev zlib1g-dev
# check the pytorch site for the torchvision tag matching your torch version
git clone --branch v0.20.0 https://github.com/pytorch/vision.git
cd vision
pip3 install -r requirements.txt
python3 setup.py install
```

If the board cannot reach any host, its resolver is the usual cause — see
[TLS handshake failures](linux-host-setup.md#b5-tls-handshake-failures-inside-containers).
