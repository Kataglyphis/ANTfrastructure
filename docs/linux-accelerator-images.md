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
  --build-arg CUDNN_VERSION=9.25.0.15 \
  --build-arg TENSORRT_VERSION=11.2.1.2 \
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

## Edge accelerators

Neither of these has an image chain in this repo yet — they are host/device
procedures for the boards the runtime artifacts get deployed to. Host-side
driver and performance setup is [Linux Host Setup](linux-host-setup.md).

### Hailo-8: compiling an ONNX model to `.hef`

The Hailo toolchain does not consume ONNX at runtime. A model goes through
three stages — parse, quantize, compile — and each emits an intermediate `.har`.

**1. Parse.** Let the parser infer the graph boundaries first:

```bash
hailo parser onnx /local/shared_with_docker/model.onnx --hw-arch hailo8
```

If it cannot resolve the ends of the graph, pin them explicitly. The node names
are model-specific — read them off the failure message or a Netron dump:

```bash
hailo parser onnx /local/shared_with_docker/model.onnx \
  --hw-arch hailo8 \
  --start-node-names images \
  --end-node-names Conv_1058 Conv_1065 Conv_1088 \
  --tensor-shapes "[1,3,640,640]"
```

**2. Quantize.** Needs a model script (`.alls`) and a calibration set:

```bash
hailo optimize /local/shared_with_docker/model.har \
  --hw-arch hailo8 \
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
  --classes 80 --hw-arch hailo8 \
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

### Hailo-8: the driver

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
