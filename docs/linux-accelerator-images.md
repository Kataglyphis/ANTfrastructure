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

The three stage tags live in a separate, private package,
`ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages` (`<repo>-stages`,
`tag-naming.sh` `cross_stage_repo`), because they carry TensorRT's SDK
([§ Stage images](#stage-images-a-private-package)). `:latest-nvidia` and its
`-<arch>` wrappers stay in the public package.

- `linux/Dockerfile.nvidia`: CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.27.0.42<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.4.0.106<!-- /generated:tensorrt --> (amd64, [§ TensorRT 11](#tensorrt-11)), NCCL, cuBLAS/cuSPARSE/cuFFT, NVTX. The chain's `gpu` stage, after `:cross-sdk-<arch>`.
- `linux/Dockerfile.media`: Builds media stack with NVIDIA codec headers + ORT CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true`.
- `linux/Dockerfile.android`: Android SDK/NDK on top of the NVIDIA media layer.
- `linux/Dockerfile.torch`: Torch/Python add-on on top of the Android NVIDIA layer.
- `linux/Dockerfile.torch`: Final entrypoint image (`:latest-nvidia-<arch>` wrapper, indexed as `:latest-nvidia`).

## NVIDIA GPU Build (Linux)

> **Tag: `:latest-nvidia`** (a manifest; today one per-arch wrapper,
> `:latest-nvidia-amd64` — arm64 joins when the cross-sbsa lane exists),
> per [`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags).
> **Published for amd64.** The 2026-10-11 index (`sha256:810f36b3…`) ran on a GPU on 2026-10-12
> ([§ The GPU run on the published image](#the-gpu-run-on-the-published-image-2026-10-12)).
> The old single-arch `:nvidia` (a 2026-04-22 build on the Ubuntu 24.04 base) and its stage
> tags were deleted from the registry on 2026-09-22.

> **Requirements:**
> - Host driver >= 590.44 (for CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->).
> - `nvidia-container-toolkit` installed and configured on the host.
> - `--runtime=nvidia` or `--gpus all` passed to `docker run`.

The NVIDIA variant chain inserts `Dockerfile.nvidia` as its `gpu` stage **after** the shared `:cross-sdk-<arch>` and before media. The later stages are the standard Dockerfiles with `ENABLE_NVIDIA=true`, which the chain derives from the variant.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.nvidia` | Installs CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.27.0.42<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.4.0.106<!-- /generated:tensorrt -->, NCCL, cuBLAS, cuSPARSE, cuFFT, NVTX |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the NVIDIA media image |
| `linux/Dockerfile.torch` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/build/onnxruntime/build/30-build-native-nvidia.sh` | ORT build script with CUDA, TensorRT, cuDNN EPs |

**Build (orchestrated, amd64):**

```bash
CROSS_VARIANT=nvidia bash linux/scripts/build-cross-chain.sh \
  --target-arches amd64 --parallel-archs --log-dir ./logs/build-logs/nvidia
```

What the variant changes, all in `build-cross-chain.sh` / `stage-defs.sh`:

- **It starts at `gpu`** and refuses `--from-stage base|compiler|sdk`: those are
  the default chain's, so run that chain first when they are stale.
- **TensorRT 11 on amd64** (owner 2026-10-20): `ENABLE_TENSORRT=true` by default on an amd64
  build platform, `false` elsewhere; `ENABLE_TENSORRT=false` opts one run out
  ([§ TensorRT 11](#tensorrt-11)). From 2026-09-22 to 2026-10-20 the default was `false`, and the
  only `libnvinfer` was DeepStream's TensorRT 10.
- **amd64 only, and it pushes only from `CROSS_BUILD_PLATFORM=linux/amd64`.**
  Every target must BE the build platform's arch: `Dockerfile.nvidia` installs
  the build platform's CUDA and the ORT/OpenCV/TVM CUDA builds compile for it,
  so an arm64 target would get x86_64 GPU libraries under an arm64 tag. And the
  shared `:cross-sdk-<arch>` it builds on is the amd64 lane's (no build-host
  infix), so off linux/amd64 a variant may only run `--no-push` — the
  [Jetson lane below](#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson),
  which stays local. `build-cross-stage.sh` applies the same refusals.
- **Its own state:** `chain-status-nvidia.json` and `logs/build-logs/nvidia/`.
  Chains run **strictly one at a time**: a second chain refuses to start while
  the pidfile names a live one.
- **The runtime lane budgets 180 GB** (`CROSS_RUNTIME_LANE_GB`), not 120.
- The wrappers take `onnxruntime-gpu` + `pytorch-cu130` unless you pin
  `ONNX_PACKAGE` / `PYTORCH_EXTRA`, and only that one onnxruntime flavour: the
  amd64 CPU `onnxruntime_dnnl` wheel is pruned from a GPU venv. Both flavours' `cp3XYt`
  twins stay in `/opt/wheels-free-threaded`, and an X.Yt venv takes the one its GIL store names
  ([free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)). The manifest is
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
| TensorRT | Not installed | TensorRT <!-- generated:tensorrt -->11.4.0.106<!-- /generated:tensorrt -->'s runtime `.so` files (amd64, [§ TensorRT 11](#tensorrt-11)) |
| NCCL | Not installed | Installed |
| cuBLAS/cuSPARSE/cuFFT | Not installed | Installed |
| NVTX | Not installed | Installed |
| GStreamer nvcodec | Auto-detected (off in builds) | Always enabled |
| ORT native EP | CPU only | CPU + CUDA + cuDNN (+ TensorRT when enabled) |
| ORT Python Package | `onnxruntime` (the `ONNX_PACKAGE` ARG default in `linux/Dockerfile.torch`) | `onnxruntime-gpu` (via `ONNX_PACKAGE`) |
| PyTorch Extra | `pytorch-cpu` | `pytorch-cu130` (via `PYTORCH_EXTRA`) |
| ORT output dir | `/usr/local/lib/onnxruntime-cpu` | Both cpu and `/usr/local/lib/onnxruntime-gpu` |
| Image tag | `:latest` (3-arch manifest) | `:latest-nvidia` (manifest, amd64 only) |

The standard build's release target is the multi-arch manifest `:latest`
([`linux-build-basics.md` § Image Hierarchy](linux-build-basics.md#image-hierarchy)
owns the tag scheme). `:latest-cross` is its retired old name; details in
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).

### TensorRT 11

> **On in every amd64 nvidia build** from the first chain after 2026-10-20 (owner decision,
> CON31). `ENABLE_TENSORRT=false` opts one run out; an arm64 nvidia build gets no default.

**What ships**: TensorRT <!-- generated:tensorrt -->11.4.0.106<!-- /generated:tensorrt -->'s runtime `.so` files in
`/usr/lib/x86_64-linux-gnu`, and nothing else of its SDK ([§ Redistribution](#redistribution)):

| Files | What |
| --- | --- |
| `libnvinfer.so.11`, `libnvinfer_plugin.so.11`, `libnvonnxparser.so.11` | the runtime, its plugins, its ONNX parser |
| `libnvinfer_lean.so.11`, `libnvinfer_dispatch.so.11`, `libnvinfer_vc_plugin.so.11` | the lean and dispatch runtimes, the version-compatibility plugin |
| `libnvinfer_builder_resource_{sm75,sm80,sm86,sm89,sm90,sm100,sm120,ptx}.so.11.4.0` | every GPU generation from Turing on, the RTX 2080's sm_75 included; `libnvinfer` `dlopen()`s them by file name from this default dir |
| `/usr/share/doc/libnvinfer*11`, `…/libnvonnxparsers11`, `…/tensorrt-11.4.0.106/README.txt` | the debs' notes; the README names the SLA |

`libnvinfer.so.11` needs only glibc, libgcc and libstdc++: it loads CUDA at run time and never
cuDNN.

**Where it comes from.** NVIDIA's CUDA apt repo for Ubuntu 26.04 (`ubuntu2604/x86_64`) serves
11.4.0.106 built for CUDA 13.4, the image's line. `install-tensorrt.sh` installs exactly
`${TENSORRT_VERSION}-1+cuda${TENSORRT_LINUX_CUDA}` (both in `versions.env`) and fails on
anything else. apt checks every deb against the repo's signed index, and the repo's keyring is
SHA-pinned (`CUDA_KEYRING_DEB_SHA256_X86_64`). It names twelve packages and never the
`tensorrt`, `tensorrt-libs` or `tensorrt-dev` metapackages, which pull
`libnvinfer-win-builder-resource11` (1.65 GB to download, 1.90 GB installed), which builds
Windows engines.
`TENSORRT_HOME=/usr/local/tensorrt` links TensorRT's own headers and libraries only, since
`Dockerfile.nvidia` puts its `lib` on `LD_LIBRARY_PATH`. The package stage copies the runtime
files above (`copy_tensorrt_payload`).

**The ORT TensorRT EP.** `30-build-native-nvidia.sh` adds `--use_tensorrt --use_full_protobuf
--tensorrt_home /usr/local/tensorrt` (ORT's built-in parser, the default). ORT v1.31.0 handles
TensorRT 11 in its source: networks are strongly typed, and the FP16/INT8 options only log a
warning. The EP ships in the native GPU tree and in the `onnxruntime-gpu` wheels. It links
`libnvinfer.so.11` and `libnvonnxparser.so.11` and `dlopen()`s `libnvinfer_plugin.so.11`, all
with local binding ([§ TensorRT 10 beside 11](#tensorrt-10-beside-11)). GenAI stays a plain CUDA
build: its `--use_trt_rtx` is TensorRT-RTX, whose wheel requires `onnxruntime-trt-rtx`, which
nothing here builds.

**Size**: +2.81 GB in the runtime image (14 files; 1.93 GB of debs), +2.82 GB in the `gpu` stage,
which media and android inherit, plus the EP library (957 KB). DeepStream's TensorRT 10 (2.6 GB)
stays beside it.

**Measured** on 2026-10-21 in a throwaway container on the published `:latest-nvidia`
(`sha256:0e9dec34…`, built 2026-10-19), as root, without a GPU:

| Step | Result |
| --- | --- |
| `setup-cuda-repo.sh`, then `install-tensorrt.sh` | the twelve packages at `11.4.0.106-1+cuda13.4` in 164 s: 1932 MB of debs, 2817 MB installed |
| `TENSORRT_HOME` | links to TensorRT's 20 headers and 24 library files, nothing else |
| The files `copy_tensorrt_payload` takes | 14 files, 2.81 GB |
| `getInferLibVersion()` of `libnvinfer.so.11` | 110400 |
| `ldconfig -p` | the `.so.11` files from `/usr/lib/x86_64-linux-gnu`, DeepStream's `.so.10` ones from its prefix |
| ORT v1.31.0 configured with `30-build-native-nvidia.sh`'s flags | 65 s: CUDA 13.4.92 with GCC 16.2.0, `NV_TENSORRT_MAJOR is 11`, `Find TensorRT libs at /usr/local/tensorrt/lib/libnvinfer.so;/usr/local/tensorrt/lib/libnvonnxparser.so` |
| The `onnxruntime_providers_tensorrt` target | built in 359 s at 8 jobs, 957 KB; it needs `libnvinfer.so.11`, `libnvonnxparser.so.11`, `libcudnn.so.9`, `libcublas.so.13` and `libcudart.so.13`, all resolved |

A session through the EP needs a GPU: the RTX 2080 run of the next build (`BACKLOG.md` CON31).

#### Redistribution

TensorRT ships under NVIDIA's *License Agreement for NVIDIA Software Development Kits*
(v. May 24, 2021) with its *TensorRT Supplement* (v. February 25, 2021):
[the SLA](https://docs.nvidia.com/deeplearning/tensorrt/latest/reference/sla.html), which the
debs' README names. Each deb's `copyright` file carries an Apache-2.0 header; the SLA is the
stricter text, and it is the one applied. The passages that decide:

- § 1.1: the licence to distribute the portions "identified in this Agreement as distributable",
  "as incorporated in object code format into a software application" that meets § 1.2.
- Supplement § 2: "The following portions of the SDK are distributable under the Agreement: the
  runtime files .so and .dll."
- § 1.2: the application must add material functionality beyond the SDK, and the distributable
  portions "shall only be accessed by your application". A developer tool not named as
  distributable is for internal use only.
- Supplement § 1: "The SDK is licensed for you to develop applications only for use in systems
  with NVIDIA GPUs."

**Decided 2026-10-20**: the owner asked for TensorRT 11 in `:latest-nvidia` if the SLA allows it.
It allows the runtime `.so` files under § 1.2, the conditions the owner accepted for DeepStream's
licence of the same family on 2026-10-01 (§ [Licence](#licence-the-owner-decision)). So only those
ship: no header, dev link, `trtexec` (`libnvinfer-bin`) or Python binding, and the GPU runtime
gate fails an image that carries a header or a dev link.

**Decided 2026-10-21: runtime files only, in every published image** (owner: "Rausnehmen").
Headers, dev links, `trtexec`, Python bindings and whole SDK trees serve a build stage and never
ship; a gate fails an image that carries one.

- **DeepStream's TensorRT 10.** `ds_stage_tensorrt` puts the three runtime debs' `.so.10*` files
  and their docs into the prefix, and the three header debs into `ds_build`'s tmp (`ds_trt_sdk`,
  with the dev links), which the components compile against and the same RUN deletes. The
  published `0e9dec34…` carried 13 headers (0.88 MB) and three dev links there; `lib/`'s 22
  runtime files and links (2.5 GB) stay. A custom `nvinfer` parser includes
  `nvdsinfer_custom_impl.h`, which includes `NvInfer.h`: build one in a stage that installs
  `libnvinfer-headers-dev` 10.16.1.11. No family repo builds one (searched 2026-10-21).
- **Windows** (`:winamd64-nvidia`; `:winamd64` is CPU and has no TensorRT): the DLLs ORT's TensorRT
  EP loads ([`windows-builds.md` § TensorRT setup](windows-builds.md#tensorrt-setup-gpu-lane-optional)).
  The published images are zip-less and carry none.

#### Stage images: a private package

**Decided 2026-10-21** (owner: "Auf privat stellen"): a pushed build stage that carries the SDK is
not public. The nvidia chain's `gpu`, `media` and `android` stages hold TensorRT 11's headers, dev
links and `/usr/local/tensorrt` (ORT's TensorRT EP and DeepStream's components compile there), and
GHCR sets visibility per package, so they push to `<repo>-stages`, never to `<repo>`:

| Stage | Tag |
| --- | --- |
| `gpu` | `ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages:cross-toolchain-nvidia-<arch>` |
| `media` | `…-stages:cross-media-nvidia-<arch>` |
| `android` | `…-stages:cross-android-nvidia[-host<arch>]-<arch>` |

The push, the inline registry cache it imports, the `GPU_PIN`/`MEDIA_PIN`/`ANDROID_PIN` digests, the
ancestry annotations and the runtime lane's `--artifact-image-prefix` all derive from these tags.
Unchanged: `base`, `compiler` and `sdk` (shared), every rocm stage, which hold no NVIDIA SDK file
(FFmpeg's `nv-codec-headers` are MIT), and `:latest-nvidia`, which ships the runtime files only.

- A new user package is **private** on its first push; linking a repository passes on its access
  permissions, never its visibility ([GitHub docs](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)).
  The Linux stages set no `org.opencontainers.image.source` anyway.
- Pulling takes a login with `read:packages`, which the build hosts have. No workflow pulls a stage tag.
- The first chain after the move starts at `gpu` (the variant default): the package is empty until
  then, so a `--from-stage media` resume has no parent.
- The Windows `-Gpu` chain pushes no stage: `trt-extract` (`bk-windows-tensorrt-sdk-nvidia`) and every
  other stage stay in the local containerd store, and only `-PushRef` pushes the final image.
  `-ExportCacheRef` (`mode=max`, every stage) refuses the public package on nvidia.
- The tags published before the move (`cross-toolchain-nvidia-amd64`, `cross-media-nvidia-amd64`,
  `cross-android-nvidia-amd64`) stay public until the owner deletes them (`BACKLOG.md` CON136).

## The GPU runtime gate

`check_gpu_runtime` (`linux/scripts/06-packaging/check-gpu-runtime.sh`) runs in the runtime smoke
on every image, without a GPU:

- **rocm**: `ROCM_PATH` and `HIP_PATH` are `/opt/rocm`, `/opt/rocm/bin` is on `PATH`, the
  `hipconfig` on `PATH` names `/opt/rocm`, `hipcc`'s clang is `/opt/rocm`'s, `hipcc` builds a HIP
  program for gfx1201, and ORT lists `MIGraphXExecutionProvider`. Any other image advertises no
  ROCm root.
- **`ENABLE_TENSORRT=true`**: `libnvinfer`, `libnvinfer_plugin` and `libnvonnxparser` of
  `TENSORRT_VERSION`'s major resolve from `/usr/lib/<triplet>`, `getInferLibVersion()` equals the
  pin, its builder resources are in that dir, the ORT TensorRT EP is in the native tree and the
  venv and resolves that TensorRT, and ORT lists `TensorrtExecutionProvider`. Without it, no
  TensorRT of that major and no TensorRT EP.
- **Every image**: no TensorRT header (under `/usr/include`, `/usr/local/include`,
  `/usr/local/tensorrt` or `/opt/nvidia`), no dev link (in the default lib dir or DeepStream's
  TensorRT prefix), no `trtexec` and no `tensorrt` Python package ([§ Redistribution](#redistribution)).
- A probe that printed nothing fails.

`deepstream-verify.sh` adds two: no DeepStream library resolves a TensorRT outside its own 10.x
prefix, and that prefix holds only runtime `.so` files, ldconfig's links and docs. On 2026-10-21
the published `:latest-rocm` failed six of the rocm rows (no roots, and `hipcc` could not link); the
published `:latest-nvidia` passed as an image without TensorRT, and failed the SDK row and
`deepstream-verify.sh` on DeepStream's 13 headers and three dev links.
`test-gpu-runtime-check.sh` keeps both probes.

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
R=ghcr.io/kataglyphis/kataglyphis_beschleuniger S="$R-stages"   # S: the nvidia stages' package

# 1. base -> compiler -> sdk
bash linux/scripts/build-cross-chain.sh --to-stage sdk "${A[@]}"

# 2. the GPU layer on the sdk (export the sdk to an OCI layout first)
nerdctl build --platform linux/arm64 -f linux/Dockerfile.nvidia \
  -t "$S:cross-toolchain-nvidia-arm64" \
  --build-context "$R:cross-sdk-arm64=oci-layout://$SDK_OCI" \
  --build-arg BASE_IMAGE="$R:cross-sdk-arm64" --build-arg UBUNTU_VERSION=26.04 \
  --build-arg ENABLE_TENSORRT=false --build-arg CUDA_INSTALL_COMPAT=0 .

# 3. media and android, each FROM its parent's layout
export ENABLE_NVIDIA=true ENABLE_TENSORRT=false TVM_USE_CUDA=1
CROSS_MEDIA_BASE_IMAGE="$S:cross-toolchain-nvidia-arm64" CROSS_MEDIA_BASE_CONTEXT="$NVIDIA_OCI" \
  bash linux/scripts/build-cross-chain.sh --only media "${A[@]}"
CROSS_ANDROID_BASE_IMAGE="$S:cross-media-nvidia-arm64" CROSS_ANDROID_BASE_CONTEXT="$MEDIA_OCI" \
  bash linux/scripts/build-cross-chain.sh --only android "${A[@]}"

# 4. runtime: call the helper directly, with the android layout as the artifact
#    (the directory must be named <root>-arm64)
CROSS_NO_PUSH=1 ARTIFACT_CONTEXT_ROOT="$ANDROID_OCI_ROOT" ARTIFACT_CONTEXT_MODE=oci \
  bash linux/scripts/build-runtime-manifest.sh --image "$R:latest-nvidia-hostarm64" \
  --target-arches arm64 --artifact-image-prefix "$S:cross-android-nvidia-hostarm64" \
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
| `ENABLE_TENSORRT` | `true` in `Dockerfile.nvidia`; the chain sets `false` off amd64 | `false` builds CUDA + cuDNN with no TensorRT anywhere: this lane has no TensorRT route. |
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
  --target-arches amd64 --parallel-archs --log-dir ./logs/build-logs/nvidia
```

### What ships

| Path | What |
| --- | --- |
| `/opt/nvidia/deepstream/deepstream-9.1/` | the runtime `.deb`'s tree, plus the components built from `DEEPSTREAM_COMMIT` installed into it, as NVIDIA's `build/build.sh` does |
| `/opt/nvidia/deepstream/deepstream` | a link to it, which some upstream Makefiles and configs name |
| `…/deepstream-9.1/sources/includes/` | the SDK headers, for building custom plugins; a custom `nvinfer` parser also needs TensorRT 10's headers, which do not ship ([§ Redistribution](#redistribution)) |
| `…/deepstream-9.1/LicenseAgreement.pdf` | NVIDIA's licence, as the `.deb` ships it |
| `/opt/nvidia/deepstream/tensorrt-10.16.1.11/` | DeepStream's own TensorRT 10: its runtime `.so` files and their docs (§ TensorRT 10 beside 11) |
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
the six TensorRT 10 debs (from the CUDA repo's `Packages` index; the three header debs serve the
build only), and the source commits.

### What needs a GPU host

- **The driver's own libraries**: `libcuda.so.1` and `libnvidia-ml.so.1` come from the host,
  injected by `nvidia-container-toolkit` (`--gpus all`, or `--device nvidia.com/gpu=all`
  through CDI; rootless nerdctl: [`linux-host-setup.md` § B2c](linux-host-setup.md#b2c-a-gpu-container-on-an-x86-desktop-with-rootless-nerdctl)).
  NVIDIA states driver 595.58.03 or newer for DeepStream 9.1.
- **The image's `cuda-compat` libcuda (615.71.09) can take over.** The CDI spec of
  `nvidia-container-toolkit` 1.20.1 runs `nvidia-cdi-hook enable-cuda-compat
  --host-driver-version=595.58.03`. In the container it left an
  `/etc/ld.so.conf.d/00-compat-<uuid>.conf` naming `/usr/local/cuda-13.4/compat`, so
  `libcuda.so.1` resolves to the image's compat driver before the host's, and `nvidia-smi`
  reports CUDA 13.4 (the host: 13.2). Measured 2026-10-12 on the RTX 2080, a GeForce card, with
  the 595.58.03 open kernel module: CUDA initialises through the compat libcuda, and DeepStream
  runs on it and on the host's own libcuda alike.
- **Everything beyond registration.** Without a GPU the gates prove the elements load and
  register. Measured without a driver, `nvstreammux` stops at PAUSED with
  `Cuda failure: status=100` and `Unable to set device in gst_nvstreammux_change_state`
  (100 is `cudaErrorNoDevice`).

The gate command, from the sample data asset (not in the image):
[`deepstream-sample-data_9.1.0.deb`](https://github.com/NVIDIA/DeepStream/releases/download/v9.1.0/deepstream-sample-data_9.1.0.deb),
671818070 bytes, sha256 `21ee7ddcfdda83d56924f25ed124e314689bf65af8ca971b7404fdb292685e98`
(GitHub's asset digest, checked against the download), installed with `dpkg -i`. It runs in
the image's environment, which sets
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

Three defects surfaced, each fixed in the source: the builder-resource links, the libv4l2
plugin link, and the mux switch below. The published image carries all three, and the
2026-10-12 run used each of them. A fourth, outside DeepStream, turned the first into a
segfault:
[`failure-modes.md` § An exception through std::call_once segfaults in libunwind](failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind).

### The GPU run on the published image (2026-10-12)

**Passed, except `nvblender`.** The published `:latest-nvidia` ran as pulled: index
`sha256:810f36b38714b423652902ed35f4b221d36f868639a83a3b4da47c476b4a033e`, amd64 manifest
`sha256:23e3cc9e5bbbfc64d8395e1d171faa56c89e9b09cbb95bedcba225110fe4bdd5`, built 2026-10-11 from
hub a6dd6992. The host is the one of 2026-10-01: the RTX 2080 (sm_75), driver 595.58.03 with
the open kernel module, rootless nerdctl 2.4.0 with CDI from `nvidia-container-toolkit` 1.20.1.
Every pipeline ran through the image's entrypoint, in its own `ENV`, as root unless a row says
uid 1001. A pad-probe program, compiled in the image against `sources/includes`, counted the
metadata. Pass/fail and functional facts only (§ [Licence](#licence-the-owner-decision)).

| Check | Result |
| --- | --- |
| `nvidia-smi` in the container | pass: driver 595.58.03, `CUDA Version: 13.4`, from the compat libcuda (§ [What needs a GPU host](#what-needs-a-gpu-host)) |
| The nine gate elements, fresh registry, real driver, as uid 1001 | pass: no `Cuda failure` and no segfault in the scan; only `libnvdsgst_ucx.so` is blacklisted, the documented UCX exception; `nvh264dec`, `nvh264enc` and `cudaconvert` register too |
| `deepstream-verify.sh` with `DSV_WIRED=1`, as `check_deepstream` runs it, GPU attached | pass: `DeepStream gates passed` |
| The gate command above, no engine file | pass: `serialize cuda engine to file: …onnx_b30_gpu0_fp16.engine successfully`, then `Got EOS from element "pipeline0"`. The process loaded `libnvinfer_builder_resource_sm75.so.10.16.1` through its default-dir link, and reached NVDEC through the distro `libv4l2` and the plugin link |
| decode → `nvstreammux` → `nvinfer` → `nvvideoconvert` → `nvdsosd` (`process-mode=1`) | pass: 1442 frames, all `NVBUF_MEM_CUDA_DEVICE`, 30214 objects in four classes, as on 2026-10-01. A frame copied out to JPEG shows boxes and labels |
| Two sources, batch 2, `nvinfer` → `nvtracker` (NvDCF) → `nvmultistreamtiler` → `nvdsosd` | pass: 2884 frames from both pads, every object carries a tracker id |
| `nvstreamdemux` to two branches; `nvurisrcbin` on an MP4 | pass: 1442 frames on each branch; 1442 frames |
| All of the above as uid 1001, with uid 1001 building the engine in its own copy of the samples | pass |
| CUDA 13.4 under NVIDIA's CUDA 13.2 builds | pass: `libcudart.so.13.4.92` |
| The host's libcuda 595.58.03 in place of the compat one | pass: the `nvdsosd` pipeline, same counts |
| The legacy `nvstreammux` (`USE_NEW_NVSTREAMMUX` unset) | **fail**, as documented: `streaming stopped, reason error (-5)` |

The plugins no run had covered (CON42's open question). Of the 40 files in `lib/gst-plugins/`,
21 are NVIDIA's prebuilt ones (their `.comment` reads Ubuntu GCC 13.3.0, marked P below); the
rest were built here with GCC 16.2.0.

| Element | Result |
| --- | --- |
| `nvv4l2h264enc`, `nvv4l2h265enc` (P) | pass: 1442 frames to MP4, decoded back to 1442 by `nvv4l2decoder`, clean |
| `nvv4l2av1enc` (P) | fail on this GPU: `Device '/dev/v4l2-nvenc' has no supported format`. Turing's NVENC has no AV1 encoder |
| `nvv4l2decoder` on H.265 (P) | pass: 1443 frames |
| `nvjpegdec`, `nvjpegenc` (P) | pass: a JPEG round trip, the MJPEG sample (1442 frames), 1442 frames encoded |
| `nvof` → `nvofvisual` (P) | pass: optical-flow metadata on all 1442 frames; the picture colours the moving bus, cyclist and car |
| `nvsegvisual` (P) | pass: a class map on all 1442 frames. The samples carry no segmentation model, so `nvinfer` (`network-type=2`) ran a 1x1-convolution ONNX exported in the image |
| `nvdslogger`, `nvdsxfer` (P) | pass: 1442 frames each |
| `nvinferaudio` (P) | pass: the SONYC classifier on the sample WAV, two sources batched, labels on all 490 audio frames |
| `deepstream_bins` (P): `nvinferbin` → `nvtrackerbin` → `nvtilerbin` → `nvosdbin` → `nvvideoencfilesinkbin`; `nvanalyticsbin`; `nvrtspoutsinkbin`; `nvdewarperbin` | pass: the MP4 decodes back to 1442 frames with boxes and tracker ids; analytics metadata on every frame; EOS; 120 frames dewarped to 480 surfaces |
| `nvunixfdsink` → `nvunixfdsrc` (P), two processes | pass for the frames: 1141 crossed as CUDA surfaces, intact. EOS does not cross the socket |
| `nv3dsink` (P), under the image's Xvfb | pass |
| `nveglglessink` (P) | not run: under Xvfb it gets Mesa's EGL, no `EGLDisplay`, and segfaults. It needs an NVIDIA-driven display |
| `nvblender` (P) | **fail**: § [nvblender](#nvblender-a-read-after-unmap-and-a-second-pad-it-ignores) |
| `nvds3dbridge`, `nvds3dfilter`, `nvds3dmixer`, `nvdsvisionencoder` (P) | not run: their samples need a RealSense camera, Triton (not built), a model outside the sample data, or a GL display |
| `nvdewarper`, built here around NVIDIA's `libnvds_dewarper.so` | pass: 120 frames to 480 coherent surfaces, once the new mux has `num-surfaces-per-frame=4` (§ [nvstreammux: the new one only](#nvstreammux-the-new-one-only)) |
| `nvmultiurisrcbin`, `nvdspreprocess`, `nvdspostprocess`, `nvdsvideotemplate`, `nvdsanalytics`, `nvvideotestsrc`, `nvimagedec`/`nvimageenc`, `dsexample`, all built here | pass, each to EOS. `nvdspreprocess` only once its config names `lib/libcustom2d_preprocess.so` (§ [What the build changes against upstream](#what-the-build-changes-against-upstream)) |

A pipeline that decodes an MP4 through `nvv4l2decoder` prints `gst_meta_api_type_has_tag:
assertion 'tag != 0' failed` two to four times. It does so on GStreamer 1.24.2 as well (below),
and nothing fails. Two consumer traps came out of the run, a registry scanned without a GPU and
an engine cache in the root-owned tree:
[`consumer-image-contract.md` § DeepStream in `:latest-nvidia`](consumer-image-contract.md#deepstream-in-latest-nvidia).

#### nvblender: a read after unmap, and a second pad it ignores

`nvblender` blends nothing on GStreamer 1.29.2. Every `NvBufSurfTransformCompositeBlend` call
fails with `Error(-3) in NvBufSurfTransformCompositeBlend dropping buffer`, and the plugin's
own debug line names the cause: `op_surf = (nil)`. It takes its output surface from
`GstMapInfo.data` after `gst_buffer_unmap()`, the read the legacy mux makes. Two measurements
prove it:

- An `LD_PRELOAD` shim that restores `GstMapInfo` after unmap, as GStreamer < 1.28 left it,
  gives a valid `op_surf` on every frame, and the blends succeed while input frames arrive. As
  a control, the same shim makes the legacy mux run: 1442 frames, 30214 objects.
- Ubuntu 24.04's GStreamer 1.24.2, loaded in the same container with NVIDIA's prebuilt
  plugins, gives a valid `op_surf` without the shim.

The second defect is NVIDIA's own. With two inputs `nvblender` never reaches EOS, on 1.24.2 as
on 1.29.2: it passes none of `sink_1`'s events (caps, segment, EOS) to `GstVideoAggregator`, so
the aggregator waits for `sink_1` forever. Its criticals (`invalid cast from 'GstNvblenderPad'
to 'GstVideoAggregatorConvertPad'`, a NULL debug category, `tag != 0`) appear on 1.24.2 too.

The image cannot fix either: the plugin is NVIDIA's binary, and the shim switches GStreamer's
check off for every caller in the process. Do not use `nvblender` in this image.

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
must use the new mux's properties (`config-file-path`, no `width`/`height`). A source with
several surfaces per frame, such as `nvdewarper`, needs `num-surfaces-per-frame` set: the new
mux asks upstream only when the property is 0, and it defaults to 1. Without it, measured on
2026-10-12, the mux takes no dewarped frame and pushes empty batches in a tight loop.

Other prebuilt NVIDIA plugins could carry the same read. The 2026-10-12 run drove 15 of the 21
prebuilt plugin files with sample data
([§ The GPU run on the published image](#the-gpu-run-on-the-published-image-2026-10-12)):
`nvblender` carries it. The others ran to EOS with sound output, apart from the legacy mux
itself and the AV1 encoder, which Turing lacks. Not run: the three ds3d
plugins and `nvdsvisionencoder` (nothing in the sample data drives them), `nveglglessink`
(needs an NVIDIA-driven display) and UCX (not loadable).

**GPU architectures.** NVIDIA's prebuilt kernels carry SASS for sm_75, 80, 89, 90, 100,
110, 120 and 121, plus PTX for sm_90. The two source components with CUDA code
(`nvdsinfer`, `nvll_osd`) build with nvcc's default, sm_75 SASS plus sm_75 PTX, so they run
on every card from Turing on (newer ones JIT the PTX once). TensorRT 10.16 ships builder
resources for sm_75, 80, 86, 89, 90, 100 and 120. So the RTX 2080 (sm_75) can run
DeepStream, although the variant's `CUDA_ARCHITECTURES` (86;87;89;120) leaves it out of
ONNX Runtime and OpenCV.

### TensorRT 10 beside 11

DeepStream 9.1 needs TensorRT 10, and the variant ships TensorRT 11:

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

Both ship from the first build after 2026-10-20 ([§ TensorRT 11](#tensorrt-11)): TensorRT 11's
runtime in `/usr/lib/<triplet>`, DeepStream's 10 in its prefix. `deepstream-verify.sh` fails a
DeepStream library that resolves a TensorRT outside that prefix, and the GPU runtime gate fails
an ORT TensorRT EP that resolves anything but TensorRT 11 from the default dir
([§ The GPU runtime gate](#the-gpu-runtime-gate)). Until then the image carried no TensorRT 11:
measured on 2026-10-12 and on the 2026-10-19 build (`sha256:0e9dec34…`), its only `libnvinfer`
is this TensorRT 10, ORT has the CUDA EP only, and no stale `tensorrt.conf` is left.

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
  build moves them to `lib/`. NVIDIA's configs still name the old place: measured 2026-10-12,
  the sample data's `config_preprocess.txt` stops with `Could not parse custom lib path` until
  its `custom-lib-path` names `lib/libcustom2d_preprocess.so`.
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
  tree ships no GStreamer core library. `gst-inspect-1.0`, which the registration gate runs,
  must load its core from there too.
- **No libv4l2 hijack**: the lib dir is on no `ld.so.conf`, and `libv4l2.so.0` resolves to the
  distro's.
- **Only plugins in `gst-plugins/`**, and a registry scan that does not crash. The check
  reads `nm` to the end: a `grep -q` under `pipefail` SIGPIPEs `nm` on a large plugin, and
  the first run moved `libgstnvvideo4linux2.so` out that way.
- **Runtime only**: the TensorRT 10 prefix holds its `.so.10*` files, ldconfig's
  `do_not_link_against_*` links and docs, nothing else (owner, 2026-10-21).
- **The `dlopen()` links**: every TensorRT builder resource resolves by file name from the
  default directory (build and package), and the package's `libv4l2` plugin dir holds the
  NVDEC plugin (`DSV_WIRED=1` only).
- **Registration** of `nvinfer`, `nvstreammux`, `nvvideoconvert`, `nvtracker`, `nvdsosd`,
  `nvv4l2decoder`, `nvmultistreamtiler`, `nvstreamdemux` and `nvurisrcbin`, with CUDA's stub
  `libcuda`/`libnvidia-ml` standing in for the driver.

**The build stage resolves like the final image.** The `deepstream` stage is FROM
`gstreamer`, which still carries a distro GStreamer 1.28 core: the toolchain's
`software-properties-common` pulls in `packagekit` and with it `libgstreamer1.0-0`, and the
gstreamer stage's `gir1.2-gstreamer-1.0` and `libgtk-4-dev` add the base, GL and extra
libraries. The final image purges them (`03-media/runtime/install-deps.sh`) and ranks
`/opt/gstreamer` first through `configure-runtime.sh`'s `000-gstreamer.conf`; the build
stage had neither. So `ld.so` gave even `/opt/gstreamer/bin/gst-inspect-1.0` the 1.28 core,
which refused every component built against 1.29 (`has incompatible version (plugin: 1.29,
gst: 1.28), not loading`), and `libgstrtspserver-1.0.so.0`, which only the prefix has, did
not resolve at all (run 20261010-193517). `ds_build` therefore writes the same
`000-gstreamer.conf` before its gates. The stage's `/etc` never reaches the image, which
copies only `/opt/nvidia` from it.

Not covered by the gates: inference, NVDEC, a TensorRT engine build. The GPU runs above
covered them, in a throwaway container on 2026-10-01 and on the published image on
2026-10-12; no lane has a GPU.

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
`pyservicemaker` wheel. TensorRT 10 falls under TensorRT's own SLA
([§ Redistribution](#redistribution)).

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
> (`:latest-amd-amd64`). **Published since 2026-10-09** (`BACKLOG.md`'s state line has its index). The old single-arch `:amd` (a
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
- The build produces an `onnxruntime-migraphx` Python wheel (instead of `onnxruntime-rocm`), and its `cp3XYt` twin from the same tree ([free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)).
- The media stage strips all external apt sources from the SDK base image and configures clean resolute-only sources to prevent cross-distro package conflicts. 01-core modules are bind-mounted into build stages so `media_common_init()` can locate cross-build helpers.

**Build (orchestrated):**

```bash
CROSS_VARIANT=rocm bash linux/scripts/build-cross-chain.sh \
  --target-arches amd64 --log-dir ./logs/build-logs/rocm
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

### Running it on an AMD GPU

The image runs as uid 1001, and `--device` keeps each node's host owner and mode: on Ubuntu
`/dev/kfd` and `/dev/dri/renderD*` are `root:render 0660`. Pass the host's group numbers:

```bash
sudo nerdctl run --rm -it --device=/dev/kfd --device=/dev/dri \
  --group-add "$(stat -c %g /dev/kfd)" --group-add "$(stat -c %g /dev/dri/renderD128)" \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-rocm
```

- Without them the node stays closed, and the entrypoint names the flag:
  `Warning: /dev/dri/renderD128 is closed to uid 1001: add --group-add 990 to the run`.
  Measured 2026-10-21 on a 0660 render node: `open()` fails as shipped and succeeds with
  `--group-add`.
- A rootless engine maps no host group into the container: the node shows group 65534, and
  `--group-add` cannot reach it. Make the nodes `0666` on the host (a udev rule), or run rootful.
- PyTorch's DataLoader workers need shared memory: add `--ipc=host` or `--shm-size`.

**The ROCm roots.** The wrapper sets `ROCM_PATH=/opt/rocm` and `HIP_PATH=/opt/rocm` and appends
`/opt/rocm/bin` to `PATH`; outside the rocm variant they are empty (`Dockerfile.package`, CON31).
The image holds two ROCm stacks:

| Stack | Used by |
| --- | --- |
| `/opt/rocm` → `core-10.1` (HIP 7.16.26385), MIGraphX 2.18 in `extras-10` | ORT's MIGraphX EP (through `000-rocm.conf`), GStreamer's `hip` plugin, every HIP build |
| `rocm-sdk` 7.14.1 in `/opt/venv` (HIP 7.14.60850), from torch's `rocm7.14` wheels | torch at run time. Its `hipcc`, `hipconfig`, `rocminfo` and `amd-smi` shims come first on `PATH` |

The venv's shims follow `ROCM_PATH`. Measured on the published image (`sha256:a5d68fbe…`, built
2026-10-09) on 2026-10-21: without the roots, `hipcc` compiles with the venv's clang 23 and cannot
link (`ld.lld: error: cannot open …/_rocm_sdk_core/lib/libamdhip64.so`; the venv SDK has no devel
files). With them it builds with `/opt/rocm`'s clang 24. `torch.utils.cpp_extension.ROCM_HOME`
follows as well, so a torch extension compiles against HIP 7.16 and runs on torch's HIP 7.14.

**A GPU run on a Windows host** (2026-10-21, Rancher Desktop's WSL VM). WSL has no `/dev/kfd`;
ROCm reaches the GPU through `/dev/dxg` and `librocdxg`, which both stacks ship. Run with
`--device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro -e LD_LIBRARY_PATH=/usr/lib/wsl/lib`, as uid 1001:

| Check | Result |
| --- | --- |
| `rocminfo`, both stacks | the Ryzen 9 9950X's iGPU (gfx1036). The RX 9070 XT (gfx1201) is not enumerated over DXG on this host |
| A HIP program from `hipcc`, roots set | builds and runs on gfx1036: 64 of 64 values right |
| The same, roots unset (as published) | does not link |
| The smoke's Add graph through ORT's MIGraphX EP | MIGraphX compiles and serves it, roots set or not |
| torch 2.14.1+rocm7.14 | sees the iGPU, then `hipErrorInvalidImage`: its wheels carry no gfx1036 kernels |

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

The 10.1 layout also reached the **CPU** ORT build, which never asks for ROCm.
`/opt/rocm/lib` is now the merged `core-10.1/lib`, so `/opt/rocm/lib/cmake` holds
the `amdrocm-dnn-dev10.1` (hipDNN) package's flatbuffers 25 config, and
`/opt/rocm/share/cmake` an nlohmann_json one. `/opt/rocm/bin` is on `PATH`, and
CMake searches the parent of every `PATH` entry, so ORT's `FIND_PACKAGE_ARGS`
took both and put `-I/opt/rocm/include` on `onnxruntime_flatbuffers`.
`ort.fbs.h` then stopped at `FLATBUFFERS_VERSION_MAJOR == 23` with `25 == 23`
(rocm chain `20261009-131840`, media stage). Two arguments keep ROCm out:

- **`append_onnx_native_base_build_args`** passes
  `CMAKE_DISABLE_FIND_PACKAGE_flatbuffers=TRUE` to every native ORT build, so
  only ORT's pinned 23.5.26 fetch serves flatbuffers. The MIGraphX build had
  carried that define on its own since 2026-09-27.
- **`append_onnx_rocm_isolation_args`** gives the CPU build
  `CMAKE_IGNORE_PREFIX_PATH=${ROCM_HOME:-/opt/rocm}` when that root exists,
  the Linux twin of the Windows rocm lane's isolation argument. Its configure
  then names `/opt/rocm` in no `flags.make`. The MIGraphX build does not call it.

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
| 2 | `ROCM_PATH`, `HIP_PATH` and `/opt/rocm/bin` on `PATH` in the shipped image | **Done 2026-10-21** in the source (CON31): without them `hipcc` could not link ([§ Running it on an AMD GPU](#running-it-on-an-amd-gpu)). |
| 3 | Assert the installed ROCm and MIGraphX versions at the end of `Dockerfile.amd` | **Done 2026-10-07**, in `setup-rocm-repo.sh`: every name carries the release, MIGraphX is pinned through apt, and a package of another release fails the build ([§ The ROCm release is in every package name](#the-rocm-release-is-in-every-package-name)). |
| 4 | Write the RESOLVED path into `/etc/ld.so.conf.d/000-rocm.conf` | It currently writes the literal `/opt/rocm/lib`, which re-resolves through alternatives in a derived image. |
| 5 | `/dev/kfd` access for uid 1001, documented with numeric host GIDs (or the udev rule), plus `--device /dev/kfd --device /dev/dri --group-add`, `--ipc=host`, `--shm-size` | **Done 2026-10-21** (CON31): the run line, and an entrypoint warning that names the missing `--group-add` ([§ Running it on an AMD GPU](#running-it-on-an-amd-gpu)). |
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
