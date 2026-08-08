# Linux Accelerator Images

## Optional NVIDIA GPU image chain

Optional NVIDIA GPU image chain. Two ways to enable:

- **Orchestrated (since 2026-08-08):** `ENABLE_NVIDIA=true bash linux/scripts/build-cross-chain.sh ...` — the env toggle now reaches the cross media stage (it used to be silently dropped by the cross lane while the runtime lane honored it, leaving a GPU-configured runtime on CPU-only media artifacts).
- **Hand-run:** passing `--build-arg ENABLE_NVIDIA=true` to the standard Dockerfiles:

- `linux/Dockerfile.nvidia`: CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.25.0.15<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.2.1.2<!-- /generated:tensorrt -->, NCCL, cuBLAS/cuSPARSE/cuFFT, NVTX. (Inserts after `:sdk`)
- `linux/Dockerfile.media`: Builds media stack with NVIDIA codec headers + ORT CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true`.
- `linux/Dockerfile.android`: Android SDK/NDK on top of the NVIDIA media layer.
- `linux/Dockerfile.torch`: Torch/Python add-on on top of the Android NVIDIA layer.
- `linux/Dockerfile.torch`: Final entrypoint image (`:nvidia` tag).

## NVIDIA GPU Build (Linux)

> **Requirements:**
> - Host driver >= 590.44 (for CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda -->).
> - `nvidia-container-toolkit` installed and configured on the host.
> - `--runtime=nvidia` or `--gpus all` passed to `docker run`.

The NVIDIA variant inserts a new `Dockerfile.nvidia` layer **after** `:sdk` and before the media stage. Subsequent stages reuse the standard Dockerfiles by passing `--build-arg ENABLE_NVIDIA=true`.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.nvidia` | Installs CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda -->, cuDNN <!-- generated:cudnn -->9.25.0.15<!-- /generated:cudnn -->, TensorRT <!-- generated:tensorrt -->11.2.1.2<!-- /generated:tensorrt -->, NCCL, cuBLAS, cuSPARSE, cuFFT, NVTX |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the NVIDIA media image |
| `linux/Dockerfile.torch` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/build/onnxruntime/build/30-build-native-nvidia.sh` | ORT build script with CUDA, TensorRT, cuDNN EPs |

**Sequential build (nerdctl):**

If apt is slow in this chain, add `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/` to each Ubuntu-based build command below. The helper rewrites archive mirror entries only by default and leaves `security.ubuntu.com` untouched.

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-nvidia"
mkdir -p "${LOG_DIR}"

# Step 1: NVIDIA layer (builds on top of existing :sdk from standard chain)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia,push=true' \
  -f linux/Dockerfile.nvidia \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia \
  . 2>&1 | tee "${LOG_DIR}/toolchain-nvidia.log"

# Step 2: media-nvidia (GStreamer nvcodec + ORT with CUDA/TRT/cuDNN EPs)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia,push=true' \
  -f linux/Dockerfile.media \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-nvidia \
  . 2>&1 | tee "${LOG_DIR}/media-nvidia.log"

# Step 3: android-nvidia
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia,push=true' \
  -f linux/Dockerfile.android \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-nvidia \
  . 2>&1 | tee "${LOG_DIR}/android-nvidia.log"

# Step 4: torch-nvidia
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia \
  --build-arg ONNX_PACKAGE="onnxruntime-gpu" \
  --build-arg PYTORCH_EXTRA="pytorch-cu130" \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-nvidia \
  . 2>&1 | tee "${LOG_DIR}/torch-nvidia.log"

# Step 5: final nvidia image
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-nvidia \
  . 2>&1 | tee "${LOG_DIR}/nvidia.log"
```

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --gpus all ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia

# or with nvidia runtime explicitly
sudo nerdctl run --rm -it --runtime=nvidia ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia
```

**Version overrides** (all have sensible defaults). The full semvers are
shared with the Windows build; the apt forms (`13-3` package suffix, cuDNN
major) are derived inside `Dockerfile.nvidia` automatically:

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-nvidia-overrides"
mkdir -p "${LOG_DIR}"

sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia,push=true' \
  -f linux/Dockerfile.nvidia \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --build-arg CUDA_VERSION=13.3.0 \
  --build-arg CUDNN_VERSION=9.23.2.1 \
  --build-arg TENSORRT_VERSION=11.1.0.106 \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia \
  . 2>&1 | tee "${LOG_DIR}/toolchain-nvidia.log"
```

**Key differences from the standard build:**

| Feature | Standard build | NVIDIA build |
| --- | --- | --- |
| CUDA Toolkit | Not installed | CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda --> |
| cuDNN | Not installed | cuDNN 9 |
| TensorRT | Not installed | TensorRT <!-- generated:tensorrt -->11.2.1.2<!-- /generated:tensorrt --> |
| NCCL | Not installed | Installed |
| cuBLAS/cuSPARSE/cuFFT | Not installed | Installed |
| NVTX | Not installed | Installed |
| GStreamer nvcodec | Auto-detected (off in builds) | Always enabled |
| ORT native EP | CPU only | CPU + CUDA + TensorRT + cuDNN |
| ORT Python Package | `onnxruntime-webgpu` | `onnxruntime-gpu` (via `ONNX_PACKAGE`) |
| PyTorch Extra | `pytorch-cpu` | `pytorch-cu130` (via `PYTORCH_EXTRA`) |
| ORT output dir | `/usr/local/lib/onnxruntime-cpu` | Both cpu and `/usr/local/lib/onnxruntime-gpu` |
| Image tag | `:latest` | `:nvidia` |

## Torch Add-on (Linux)

Builds on the base image:

```bash
nerdctl build -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch -f linux/Dockerfile.torch .
```

## AMD GPU Build (Linux)

> **Requirements:**
> - Host driver >= 6.0 (for ROCm 7.1).
> - `--device=/dev/kfd --device=/dev/dri` passed to `docker run`.

The AMD variant inserts a new `Dockerfile.amd` layer **after** `:sdk` and before the media stage. Subsequent stages reuse the standard Dockerfiles by passing `--build-arg ENABLE_AMD=true`.

**Files involved:**

| File | Purpose |
| --- | --- |
| `linux/Dockerfile.amd` | Installs ROCm 7.1 + MIGraphX 2.14 from AMD repo (HIP, MIOpen, RCCL, rocBLAS, rocFFT, MIGraphX) |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with MIGraphX EP when `ENABLE_AMD=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the AMD media image |
| `linux/Dockerfile.torch` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/build/onnxruntime/build/30-build-native-amd.sh` | ORT build script with MIGraphX EP |

**Notes:**
- MIGraphX packages come from the AMD ROCm repository (`repo.radeon.com`) targeting Ubuntu 24.04 (noble), compatible with Ubuntu 26.04 (resolute). The toolchain image pins the AMD repo to provide only ROCm/MIGraphX packages to avoid noble-vs-resolute apt version conflicts.
- The ONNX Runtime MIGraphX Execution Provider replaces the older ROCm EP. The build script passes `--use_migraphx --migraphx_home /opt/rocm` instead of `--use_rocm`.
- The build produces an `onnxruntime-migraphx` Python wheel (instead of `onnxruntime-rocm`).
- The media stage strips all external apt sources from the SDK base image and configures clean resolute-only sources to prevent cross-distro package conflicts. 01-core modules are bind-mounted into build stages so `media_common_init()` can locate cross-build helpers.

**Sequential build (nerdctl):**

If apt is slow in this chain, add `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/` to each Ubuntu-based build command below. The helper rewrites archive mirror entries only by default and leaves `security.ubuntu.com` untouched.

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-amd"
mkdir -p "${LOG_DIR}"

# Step 1: AMD layer (builds on top of existing :sdk from standard chain)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd,push=true' \
  -f linux/Dockerfile.amd \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-amd \
  . 2>&1 | tee "${LOG_DIR}/toolchain-amd.log"

# Step 2: media-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd,push=true' \
  -f linux/Dockerfile.media \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-amd \
  . 2>&1 | tee "${LOG_DIR}/media-amd.log"

# Step 3: android-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd,push=true' \
  -f linux/Dockerfile.android \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-amd \
  . 2>&1 | tee "${LOG_DIR}/android-amd.log"

# Step 4: torch-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd \
  --build-arg ONNX_PACKAGE="onnxruntime-migraphx" \
  --build-arg PYTORCH_EXTRA="pytorch-rocm71" \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-amd \
  . 2>&1 | tee "${LOG_DIR}/torch-amd.log"

# Step 5: final amd image
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-amd \
  . 2>&1 | tee "${LOG_DIR}/amd.log"
```

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --device=/dev/kfd --device=/dev/dri ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd
```
