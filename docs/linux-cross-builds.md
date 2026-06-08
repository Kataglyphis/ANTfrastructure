# Linux Cross Builds

> Build-time download speed: the cross-compiler/SDK builds fetch the LLVM source with `git` inside a `RUN` step. On this host that is fast because rootless BuildKit runs with `--oci-worker-net=host` (host networking for `RUN` steps). Registry mirrors do not help that `git fetch`; the host-net setting does. See `docs/project-info.md` for the drop-in config and `AGENTS.md` for the do-not-regress note. For repeated LLVM rebuilds, prefer caching the source on the host over re-fetching.

## Cross-Compiler builder (nerdctl, amd64 host; amd64/arm64/riscv64 targets)

The existing multi-platform build above stays unchanged. Treat it as the compatibility lane for the current QEMU/binfmt-based end-to-end build.

The cross-compiler path below is additive. It does not replace the existing QEMU workflow. Instead, it prepares a single amd64-hosted builder image that contains cross toolchains for amd64, arm64, and riscv64 for a future artifact-based multi-architecture endbuild.

This lane intentionally builds only a `linux/amd64` container image. The three architectures are the compiler targets installed inside that image via `CROSS_TARGETS=amd64,arm64,riscv64`, not three separate compiler container manifests.

For the cross-compiler path, the helper can bootstrap the base image locally when needed, so you do not have to rely on a remote `base` intermediate tag surviving in GHCR.

Fastest entry point:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/
```

Use `--fast-ubuntu-mirror-url URL` to override the default mirror (`https://archive.ubuntu.com/ubuntu/`). For example: `--fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/`.

The helper script only uses `nerdctl`. It first tries to reuse a local `ghcr.io/kataglyphis/kataglyphis_beschleuniger:base`, then tries to pull that tag, and if that fails it rebuilds the base image locally before building `ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64`. It only pushes when you pass `--push`. In `BUILD_MODE=cross`, that compiler image builds GCC 16 from source into `/opt/gcc-16.1.0` for the amd64 host compiler and the target-prefixed `aarch64-linux-gnu-*` and `riscv64-linux-gnu-*` toolchains.

If you only need the downstream SDK or media cross stages and want to reuse the published compiler image, pull it first:

```bash
nerdctl pull --platform linux/amd64 \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64
```

Build the local amd64 base image:

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-cross-base"
mkdir -p "${LOG_DIR}"

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  . 2>&1 | tee "${LOG_DIR}/base.log"
```

Then build the dedicated amd64-hosted compiler image in cross mode for amd64, arm64, and riscv64 targets:

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-cross-compiler"
mkdir -p "${LOG_DIR}"

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee "${LOG_DIR}/compiler-cross-amd64.log"
```

The explicit `nerdctl build --output ... push=true` commands above already push the intermediary images to GHCR. Only the helper script keeps the images local by default unless you pass `--push`.

Expected compiler result inside that image:

- `gcc` and `g++` resolve to `/opt/gcc-16.1.0/bin/*` and report GCC 16.x on the amd64 host compiler path.
- `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc` resolve to `/opt/gcc-16.1.0/bin/*` and report GCC 16.x.
- `clang-amd64`, `clang-arm64`, and `clang-riscv64` still exist, but now point Clang at `/opt/gcc-16.1.0` as the GCC toolchain root.

Expected result: the build log ends with `ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64`. That is correct for this cross lane because the builder container itself runs on amd64 while shipping source-built GCC 16 host and cross compilers for all three target architectures.

Or let the helper do the push too:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror --push
```

## Recommended: digest-pinned orchestrator (`build-cross-chain.sh`)

For a hands-off, agent-proof end-to-end cross build, prefer the orchestrator over
the manual `nerdctl` loops:

```bash
./linux/scripts/build-cross-chain.sh \
  --target-arches amd64,arm64,riscv64 \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --log-dir "logs/$(date -u +'%Y%m%dT%H%M%SZ')-cross-chain"
```

It runs `base -> compiler -> sdk -> media -> android -> runtime` and, after each
cross stage is pushed, captures that stage's **registry-resolvable manifest
digest** and feeds it to the next stage as
`--build-arg BASE_IMAGE=<repo>@sha256:<digest>`. The final `runtime` stage
delegates to `build-runtime-manifest.sh` to build the per-arch
`base -> package -> torch -> wrapper` images on the real target platform and
publish the multi-arch `:latest-cross` manifest.

### Stale-check (`--verify-chain`)

Before a full build, verify whether downstream registry images are stale without
performing any builds:

```bash
./linux/scripts/build-cross-chain.sh \
  --target-arches amd64,arm64,riscv64 \
  --verify-chain
```

This resolves all upstream registry digests and reports mismatches so you can
decide whether a full rebuild is needed.

### Why the handoff must be pinned by digest

Each cross stage is a separate `nerdctl build` whose next stage does
`FROM ${BASE_IMAGE}`. If `BASE_IMAGE` is a **mutable tag** such as
`:media-cross-arm64`, the downstream build can silently consume a **stale,
locally-cached** image instead of the one you just built, because:

- `--output type=image,name=...,push=true` pushes the new digest to the registry
  but does **not** reliably refresh the local containerd tag to that digest, and
- BuildKit's default `FROM` resolution prefers an image already present locally
  (it does not re-pull unless told to).

So a rebuild of `media` followed by a build of `android` can quietly use the old
`media`. Two defenses, in order of strength:

1. **Digest pinning (used by `build-cross-chain.sh`):** content-addressed
   `repo@sha256:...` references can never resolve to a stale image. This is the
   robust fix and the path you should instruct automated agents to use.
2. **`--pull=true` on every downstream stage (used in the manual loops below):**
   forces BuildKit to re-pull the freshly pushed base tag from the registry.
   Lighter, but still relies on mutable tags.

> Do **not** capture the pin from the local image store's `RepoDigests`. On this
> host BuildKit pushes a converted `docker.v2+json` manifest whose digest differs
> from the local OCI manifest, so `RepoDigests` is **not** registry-resolvable.
> Use `nerdctl manifest inspect --verbose <tag>` → `.Descriptor.digest`
> (this is exactly what the `registry_pin_ref` helper in
> `linux/scripts/01-core/artifact-common.sh` does).

Partial runs are supported, e.g. resume from media for one arch:

```bash
./linux/scripts/build-cross-chain.sh --target-arches arm64 --from-stage media --to-stage android
```

When resuming mid-chain, the required upstream digest is resolved from the parent
stage's current registry tag automatically.

### Trap: stale-base propagation across orchestrator invocations

Digest pinning only prevents drift **within a single orchestration run.** Across
**separate** invocations, a registry tag may have been updated — but downstream
images still pin the old digest. For example:

1. You build the full chain (`compiler → sdk → media → android`).
2. You rebuild and re-push the **compiler** image (e.g. adding
   `/opt/gcc-16.1.0-native-arm64`).
3. You run `--from-stage media --to-stage android`. The orchestrator resolves the
   sdk pin from the registry tag `sdk-artifact-arm64` — which was built from the
   **old** compiler and is missing the new content.
4. The new media rebuild inherits from the stale sdk, and the new compiler
   content never reaches the final image.

**How to avoid this:**

- After replacing any base image (compiler, sdk, etc.), **rebuild from the
  replaced stage** — not a later one. E.g. after a compiler push, start from
  `--from-stage sdk`, not `--from-stage media`.
- **Verify** downstream images contain the expected new content before relying on
  them (e.g. check that `/opt/gcc-16.1.0-native-arm64` exists in the pinned sdk
  digest with `nerdctl run --rm <repo>@<digest> ls -d /opt/gcc-16.1.0-native-arm64`).
- **The `--from-stage` flag only controls where execution starts; it does NOT
  update the base image of the first stage it runs.** If the stage just before
  your `--from-stage` inherits from a stale upstream, so will your rebuild.
- For partial runs after a compiler update, always use `--from-stage sdk` as the
  minimum starting point.

## Manual staged build with plain `nerdctl` (current GCC 16 cross lane)

Run these commands from the repository root. Keep every trailing `\` as the last character on its line, and keep the final `.` because it is the Docker build context.

The manual loops below add `--pull=true` to every stage that consumes a
`BASE_IMAGE` tag so each stage re-pulls the freshly pushed base instead of a
stale local copy. This is the lighter of the two defenses described above; the
orchestrator's digest pinning is stronger.

These commands assume `nerdctl` is already usable from your current shell without `sudo`.

```bash
set -o pipefail
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-cross-manual"
mkdir -p "${LOG_DIR}"

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  . 2>&1 | tee "${LOG_DIR}/base.log"

nerdctl build --platform linux/amd64 --pull=true -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee "${LOG_DIR}/compiler-cross-amd64.log"

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 --pull=true -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch},push=true" \
    -f linux/Dockerfile.sdk \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/sdk-artifact-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 --pull=true -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch},push=true" \
    -f linux/Dockerfile.media \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/media-cross-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 --pull=true -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch},push=true" \
    -f linux/Dockerfile.android \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/android-cross-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-base-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-base-${target_arch},push=true" \
    -f linux/Dockerfile.base \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
    . 2>&1 | tee "${LOG_DIR}/torch-base-${target_arch}.log"
done

sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
# ^ If the agent reports "exec format error" during foreign-arch builds, run this command
#   manually in a terminal first, then retry.

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-package-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-package-${target_arch},push=true" \
    -f linux/Dockerfile.package \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-base-${target_arch}" \
    --build-arg ARTIFACT_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch}" \
    --build-arg ARTIFACT_PLATFORM=linux/amd64 \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/torch-package-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-cross-${target_arch},push=true" \
    -f linux/Dockerfile.torch \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-package-${target_arch}" \
    --build-arg TORCH_APP_MODE=install \
    . 2>&1 | tee "${LOG_DIR}/torch-cross-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-${target_arch},push=true" \
    -f linux/Dockerfile.torch \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-cross-${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/latest-cross-${target_arch}.log"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" \
    -f linux/Dockerfile.torch \
    --target venv-export \
    --output "type=local,dest=out/torch-venv/${target_arch}" \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-package-${target_arch}" \
    --build-arg TORCH_APP_MODE=install \
    . 2>&1 | tee "${LOG_DIR}/torch-venv-${target_arch}.log"
done
```

`linux/Dockerfile.sdk` now serves both the sequential SDK build and the amd64-hosted cross SDK artifact lane. The cross path still consumes one `TARGET_ARCH` per `nerdctl build`, so the loops above intentionally fan that out one target at a time for `amd64`, `arm64`, and `riscv64`.

The later cross builds above are additive and still intentionally conservative:

- `media-cross-${target_arch}` now runs the native C/C++ stages with target compilers and target pkg-config/sysroot settings on the amd64 host.
- `android-cross-${target_arch}` now keys off the amd64 build host for SDK/NDK setup while still selecting the requested Android target ABI from `TARGET_ARCH`.
The final cross output is now `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`, built by publishing clean per-arch `linux/Dockerfile.base` images, layering the target-built `android-cross-${target_arch}` payload onto them with `linux/Dockerfile.package`, and then building the final `linux/Dockerfile.torch` wrapper (which includes Torch venv, app, and runtime scripts). A single multi-architecture manifest is then published.

Think of the target-platform handoff like this:

- `linux/Dockerfile.base` -> `linux/Dockerfile.package` -> `linux/Dockerfile.torch` produces `latest-cross-${target_arch}`.
- `Dockerfile.torch` includes a `venv-export` scratch stage for exporting `/opt/venv` separately.

`linux/Dockerfile.package` is the point where the amd64-hosted cross artifacts are copied into a clean real target root filesystem. For foreign-architecture runtime images, that package stage must receive a real target-native `/opt/llvm-target` tree from the artifact image and must wire `/usr/bin/clang` to `/usr/local/llvm-target/bin/clang`; do not fall back to distro `/usr/local/llvm-22` on `arm64` or `riscv64`, or the final manifest can pick up a host-architecture Clang binary. The stage also receives a target-native `/opt/gcc-16.1.0` that was cross-compiled from source (Canadian cross) during the toolchain stage and swapped in by `Dockerfile.android`. A hard-fail validation step verifies that `cc -dumpmachine` matches `TARGET_ARCH`, asserts the ELF machine type of the `cc` binary itself (via `readelf -h`, the real discriminator between a target-native compiler and a host-arch cross-compiler), and runs a cc1 compile-to-object smoke under the target platform. After that, `linux/Dockerfile.torch` directly produces the final `latest-cross-${target_arch}` wrapper image.

The existing multi-platform sequential `sdk`, `media`, and `android` commands above still remain supported and unchanged.

### OpenCV 5.x GStreamer compatibility (applies to all architectures)

OpenCV 5.x reorganized several modules relative to OpenCV 4.x. GStreamer's bundled `gst-plugins-bad` "opencv" plugin (1.29.x) still targets the 4.x layout, so it fails to compile against the source-built OpenCV 5 in this image. The build system applies an automatic source patch via `patch-gstreamer-sources.sh` → `patch_gstreamer_opencv5_compat()` that addresses three upstream API changes:

1. **`contourArea`/`approxPolyDP`/`convexHull`** moved from `imgproc` to the new `geometry` module → adds `#include <opencv2/geometry.hpp>` to `gstsegmentation.cpp`.
2. **`findChessboardCorners`/`findCirclesGrid`/`drawChessboardCorners` + `CALIB_CB_*`** moved from `calib3d` into `objdetect` → adds `#include <opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`.
3. **`cv::CascadeClassifier`** + `CASCADE_*` (legacy Haar cascade detection) were **removed** from OpenCV 5 → the three cascade-dependent GStreamer elements (`faceblur`, `facedetect`, `handdetect`) are dropped from the monolithic `libgstopencv.so`. The remaining 22 elements (dilate, sobel, smooth, edgedetect, tracker, grabcut, retinex, segmentation, cameracalibrate, etc.) build and function normally.

Additionally, `build-opencv.sh` creates an `opencv4.pc` → `opencv5.pc` compatibility alias because GStreamer's meson dependency lookup queries `dependency('opencv4', '>= 4.0.0')`.

This image is a single amd64 builder image, not a replacement for the full multi-platform Linux chain yet. It keeps the current native/emulated flow intact while adding source-built GCC 16 target compilers like `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc`, plus convenience wrappers such as `clang-amd64`, `clang-arm64`, and `clang-riscv64` for host-side cross builds.

## SDK rootfs artifacts (first host-side build step)

The first additive artifact path is now the SDK stage. It reuses `linux/Dockerfile.sdk` in `BUILD_MODE=cross`, builds target-specific SDK root filesystems for amd64, arm64, and riscv64 on a fast amd64 host, and exports them to disk while the existing QEMU/binfmt multi-platform build above remains unchanged.

Build the first SDK artifacts for amd64, arm64, and riscv64 while saving this run under one timestamped `logs/` directory:

```bash
set -o pipefail
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-sdk-artifacts"
mkdir -p "${LOG_DIR}"

./linux/scripts/build-sdk-artifacts.sh --target-arches amd64,arm64,riscv64 --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  2>&1 | tee "${LOG_DIR}/build-sdk-artifacts.log"
```

Build all three SDK artifact targets directly with `nerdctl` and keep one log per target:

```bash
set -o pipefail
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-sdk-artifacts-direct"
mkdir -p "${LOG_DIR}"

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 \
    -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch},push=true" \
    -f linux/Dockerfile.sdk \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee "${LOG_DIR}/sdk-artifact-${target_arch}.log"
done
```

Use `--fast-ubuntu-mirror-url URL` if you want to override the default mirror, for example `--fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/`.

If you want this helper to reuse the published compiler image instead of bootstrapping it locally, pull the compiler tag first:

```bash
nerdctl pull --platform linux/amd64 \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64
```

The helper accepts `TARGET_ARCHES=amd64,arm64,riscv64`, `TARGET_ARCH=amd64,arm64,riscv64`, or `--target-arches amd64,arm64,riscv64` and then fans that list out into one `TARGET_ARCH=<arch>` build per target.

Expected output layout:

```text
out/linux-sdk/amd64/rootfs/
out/linux-sdk/amd64/artifact.env
out/linux-sdk/arm64/rootfs/
out/linux-sdk/arm64/artifact.env
out/linux-sdk/riscv64/rootfs/
out/linux-sdk/riscv64/artifact.env
```

This helper uses `linux/Dockerfile.sdk` with `BUILD_MODE=cross` and the amd64-hosted cross compiler image. During successful cross SDK builds, CMake should identify the active C++ compiler as `GNU 16.1.0` rather than the Ubuntu 26.04 system GCC toolchain. It is the first real host-side rootfs export step toward a full multi-architecture non-QEMU endbuild, but it does not yet replace the full `:latest` pipeline.

`linux/Dockerfile.sdk` also forwards the checked-in `LLVM_RELEASE` pin into the `target-clang` step, so rebuilding an SDK artifact from an older `compiler-cross-amd64` base still refreshes `/opt/llvm-target` to the repository pin instead of inheriting a stale base-image environment value.

## Cross packaging to multi-arch manifest (experimental)

The new end-goal path is split into two steps so the old QEMU lane keeps working:

1. Keep the existing multi-platform build for compatibility.
2. Build target artifacts host-side with the cross builder.
3. Assemble one runtime image per architecture from a clean per-arch `linux/Dockerfile.base` image plus the target-built payload from `android-cross-${target_arch}`.
4. Publish a single multi-architecture manifest.

`linux/Dockerfile.package` is the shared runtime packaging layer for this path. It starts from a clean per-arch base image, copies only the selected target payload from the chosen artifact image, replays the final runtime dependency setup, and then becomes the `BASE_IMAGE` for the final `linux/Dockerfile.torch` wrapper. In `cross` mode that artifact image still runs on amd64 (`android-cross-${target_arch}`); in `native` mode it can be the target-platform sequential image directly.

For day-to-day work on this host, prefer the helper scripts below over the long manual `nerdctl` loops. The manual sequence remains useful as a low-level reference, but the helpers already encode the verified local-context handoff and push semantics.

The main repo-root Linux Dockerfiles also now carry Dockerfile-specific ignore files so helper/manual cross builds do not send `linux/webserver/` and the large exported `out/*` trees back through the default build context on every stage.

Run the final publish flow directly with `nerdctl` only when you intentionally need the fully manual path. The per-arch `latest-cross-base-*`, `latest-cross-package-*`, `latest-cross-torch-*`, and `latest-cross-*` tags are internal publish tags used to assemble the public `latest-cross` manifest:

```bash
IMAGE_REPO=ghcr.io/kataglyphis/kataglyphis_beschleuniger

MIRROR_ARGS=(
  --build-arg USE_FAST_UBUNTU_MIRROR=true
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/
  --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/
)

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" \
    -t "${IMAGE_REPO}:latest-cross-base-${target_arch}" \
    -f linux/Dockerfile.base \
    "${MIRROR_ARGS[@]}" \
    . && \
  nerdctl push "${IMAGE_REPO}:latest-cross-base-${target_arch}"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" \
    -t "${IMAGE_REPO}:latest-cross-package-${target_arch}" \
    -f linux/Dockerfile.package \
    --build-arg BASE_IMAGE="${IMAGE_REPO}:latest-cross-base-${target_arch}" \
    --build-arg ARTIFACT_IMAGE="${IMAGE_REPO}:android-cross-${target_arch}" \
    --build-arg ARTIFACT_PLATFORM=linux/amd64 \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    "${MIRROR_ARGS[@]}" \
    . && \
  nerdctl push "${IMAGE_REPO}:latest-cross-package-${target_arch}"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" \
    -t "${IMAGE_REPO}:latest-cross-torch-${target_arch}" \
    -f linux/Dockerfile.torch \
    --build-arg BASE_IMAGE="${IMAGE_REPO}:latest-cross-package-${target_arch}" \
    --build-arg TORCH_APP_MODE=install \
    . && \
  nerdctl push "${IMAGE_REPO}:latest-cross-torch-${target_arch}"
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform "linux/${target_arch}" \
    -t "${IMAGE_REPO}:latest-cross-${target_arch}" \
    -f linux/Dockerfile.torch \
    --build-arg BASE_IMAGE="${IMAGE_REPO}:latest-cross-torch-${target_arch}" \
    . && \
  nerdctl push "${IMAGE_REPO}:latest-cross-${target_arch}"
done

nerdctl manifest rm "${IMAGE_REPO}:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "${IMAGE_REPO}:latest-cross" \
  "${IMAGE_REPO}:latest-cross-amd64" \
  "${IMAGE_REPO}:latest-cross-arm64" \
  "${IMAGE_REPO}:latest-cross-riscv64"
nerdctl manifest push --purge "${IMAGE_REPO}:latest-cross"
nerdctl manifest inspect "${IMAGE_REPO}:latest-cross"
```

If you do not need the mirror override, remove `MIRROR_ARGS` and the `"${MIRROR_ARGS[@]}"` arguments from the base and package build loops.

This flow still adds a second lane. It does not modify the current QEMU-based multi-platform build commands above.

The same package handoff now works for `linux/Dockerfile.torch` too. Build the heavy media/android payloads with the amd64-hosted cross compiler first, then feed `android-cross-${target_arch}` through `linux/Dockerfile.package`, build `linux/Dockerfile.torch` on `linux/${target_arch}` (which now includes the runtime scripts + entrypoint directly). `TORCH_APP_MODE=install` keeps that QEMU Torch stage focused on creating `/opt/venv`, and the dedicated `venv-export` target lets you export only `/opt/venv` for later `COPY` into a matching real target image.

The helper scripts now follow the same runtime path too:

- `linux/scripts/build-runtime-manifest.sh` builds `base -> package -> torch -> wrapper -> manifest`.
- `linux/scripts/build-runtime-artifacts.sh` builds that same `base -> package -> torch -> wrapper` chain and exports the final wrapper rootfs instead of creating a manifest.
- Both helpers accept `--target-arches`, `TARGET_ARCHES`, or `TARGET_ARCH` for architecture selection.
- Both helpers accept `ARTIFACT_BUILD_MODE=cross` or `ARTIFACT_BUILD_MODE=native` for selecting the package artifact source.
- In `cross` mode, `ARTIFACT_IMAGE_PREFIX` is treated as a prefix like `ghcr.io/...:android-cross` and the helper fans out `-${target_arch}` automatically.
- In `native` mode, `ARTIFACT_IMAGE_PREFIX` is treated as the exact artifact image ref, for example `ghcr.io/...:android`.
- In `cross` mode, the media artifact lane now also makes a best-effort `riscv64` app wheelhouse on the amd64 host for the locked `torch`, `torchvision`, and `opencv-python` git-source dependencies used by `Kataglyphis-Orchestr-ANT-ion`, and carries those wheels forward through the existing `/opt/wheels` handoff when the build succeeds.
- The helper still runs `linux/Dockerfile.torch` on the real target platform in both modes so `/opt/venv` is populated in the final runtime image.
- The final Torch install now keeps the upstream `uv.lock` when it is present, runs `uv sync --frozen`, and skips reinstalling any packages that already exist in `/opt/wheels` before force-reinstalling the local wheelhouse.
- If a reused cross artifact has an empty `/opt/wheels`, the Torch install step now keeps the packages that `uv sync` already resolved instead of uninstalling them and trying to install a literal `/opt/wheels/*.whl` glob.
- When images stay local, the helpers keep the intermediate runtime handoff off-registry by default. `base` is exported as a plain rootfs directory, while `package` and `torch` are exported as OCI layouts and then consumed through named build contexts.
- `ARTIFACT_CONTEXT_ROOT` lets the runtime helpers consume previously saved runtime artifacts from disk instead of pulling `android-cross-*` from a registry.
- `ARTIFACT_CONTEXT_MODE=oci` makes each `ARTIFACT_CONTEXT_ROOT/<arch>` resolve as `oci-layout://...`. That is the verified path for the saved `out/local-oci/android/{arm64,riscv64}` artifacts.
- On this host, one build still fails when it consumes two named OCI image contexts at once. The working workaround is to keep `runtime_artifact` as an OCI layout context and `runtime_base` as a plain rootfs directory context.
- Each local stage context is deleted as soon as the downstream build finishes consuming it, which keeps non-push runs off `/tmp` and reduces peak disk usage.
- `build-runtime-artifacts.sh --push` pushes the final per-architecture wrapper images even when the helper keeps `base -> package -> torch` in local stage contexts.
- `build-runtime-manifest.sh --push` is shorthand for `--push-images --push-manifest`.
- Use `--push-all` only when you also want the `base`, `package`, and `torch` intermediates pushed.

Verified local foreign-architecture rebuild on this host:

```bash
ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android" \
ARTIFACT_CONTEXT_MODE=oci \
RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts" \
bash linux/scripts/build-runtime-artifacts.sh \
  --target-arches arm64,riscv64 \
  --image-prefix docker.io/library/opencode-local:latest-cross \
  --artifact-image-prefix docker.io/library/opencode-local:android-cross \
  --artifact-build-mode cross \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/
```

That path was validated for both `arm64` and `riscv64` with `gcc version 16.1.0`, `clang version 22.1.6`, `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-16.1.0/bin/gcc`, native `gcc-16` binaries under `/opt/gcc-16.1.0/bin/`, and the optional runtime payloads under `/usr/local/lib/onnxruntime-genai`, `/usr/local/lib/onnxruntime-gpu`, `/usr/local/include/tflite`, `/usr/local/include/tensorflow`, and `/usr/local/lib/pkgconfig/litert.pc`. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) so `/opt/gcc-16.1.0/bin/gcc` is a target-native binary. The build-time guard in `Dockerfile.package` verifies that `cc -dumpmachine` matches the target architecture, asserts the ELF machine type of the `cc` binary itself (via `readelf -h`), and runs a cc1 compile-to-object smoke under the target platform.

After the runtime helper cleanup in this repository, the same helper path was re-validated for `amd64` with:

```bash
RUNTIME_CONTEXT_ROOT="/tmp/opencode/runtime-contexts" \
bash linux/scripts/build-runtime-artifacts.sh \
  --target-arches amd64 \
  --output-root /tmp/opencode/runtime-smoke \
  --image-prefix docker.io/library/opencode-local:latest-cross-smoke \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross \
  --artifact-build-mode cross \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/
```

The resulting image reported `gcc version 16.1.0`, `clang version 22.1.6`, target `x86_64-unknown-linux-gnu`, `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-16.1.0/bin/gcc`, and `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`.

For local wrapper smoke validation without pushing anything, build the checked-in smoke target directly:

```bash
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-cross-wrapper-smoke-amd64 \
  -f linux/Dockerfile.package \
  --target wrapper-smoke \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg ARTIFACT_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-amd64 \
  --build-arg ARTIFACT_PLATFORM=linux/amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=cross \
  --build-arg GCC_VERSION=16.1.0 \
  --build-arg LLVM_RELEASE=22.1.6 \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
  .
```

## Centralized Version Management

All version numbers are now tracked in a single file: `linux/scripts/01-core/versions.env`. Update this file when bumping versions — do NOT scatter version changes across individual Dockerfiles.

`common.sh` and `artifact-common.sh` both source `versions.env` at load time with `set -a`, so all build scripts and orchestrators automatically receive canonical values. The per-Dockerfile ARG defaults are kept as safety nets and should match `versions.env`.

After bumping versions, run `python3 docs/scripts/sync_versions.py --write` to update the version snapshot in `README.md`.

## Five Critical Fixes To Maintain

To prevent regressions during updates, always preserve the following five vital fixes in the Linux cross pipeline:

1. **Fix 1 (gst-python staged libpython):** In `build_python.sh`, the `rewrite_staged_python_pc()` helper rewrites the staged `python-3.14.pc` file's `libdir` and `includedir` to point correctly at the compiler's cross directory so `gst-python` builds succeed.
2. **Fix 2 (libcamera abseil):** In `build-litert.sh`, the build must copy the required Abseil header `absl/types/span.h` into the LiteRT installation directory to prevent downstream `libcamera` build errors.
3. **Fix 3 (cross lib-dynload dangling symlinks):** In `build_python.sh` (`build_cross_target_python_payload()`), standard CPython build steps create standard cross-build library symlinks that end up dangling when packaged. We use `cp -a -L` to dereference those symlinks, copy the safety-net Modules, and enforce a hard-fail guard `find ... -xtype l` to ensure absolutely zero dangling symlinks remain in the target's `lib-dynload` subdirectory. This prevents C-extension import failures (e.g. `import _struct` failing under QEMU/binfmt). Since target-packaged Python is staged into the compiler-cross image, the compiler itself must be rebuilt if this helper logic is changed.
4. **Fix 4 (cross GCC architecture guard):** In `Dockerfile.package`, the GCC alternatives registration wires `/opt/gcc-16.1.0/bin/gcc` as the system `cc`/`c++` on all architectures. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) using the cross-compiler built in the same toolchain image; `Dockerfile.android` swaps the amd64-hosted GCC for the target-native GCC at the end of the Android stage. The build hard-fails if the runtime `cc` is the wrong architecture, using three layered guards: (a) `cc -dumpmachine` must match `TARGET_ARCH`; (b) the ELF machine type of the `cc` binary itself (via `readelf -h`) must match the target — this is the real discriminator, because `-dumpmachine` reports the *target* triple and cannot tell a target-native compiler from a host-arch cross-compiler that merely targets the same triple; and (c) a cc1 compile-to-object smoke (`cc -x c - -c -o`) plus an ELF-machine check on the produced object, run under the target platform (QEMU for foreign arch). `Dockerfile.android` additionally asserts the ELF machine type of the swapped GCC right after the swap. The `wrapper-smoke` target uses `linux/scripts/06-packaging/smoke-wrapper.sh` for end-to-end verification.
5. **Fix 5 (OpenCV 5 GStreamer compat):** `patch-gstreamer-sources.sh` → `patch_gstreamer_opencv5_compat()` patches the GStreamer `gst-plugins-bad` opencv plugin sources at build time for OpenCV 5.x compatibility. Three API changes are handled: (a) `contourArea`/`approxPolyDP`/`convexHull` moved to new `geometry` module → adds `#include <opencv2/geometry.hpp>` to `gstsegmentation.cpp`; (b) chessboard/circles-grid detection (`findChessboardCorners`/`findCirclesGrid`/`CALIB_CB_*`) moved to `objdetect` module → adds `#include <opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`; (c) `cv::CascadeClassifier` removed from OpenCV 5 → drops the three cascade-dependent GStreamer elements (`faceblur`, `facedetect`, `handdetect`) from the monolithic `libgstopencv.so`. Additionally, `build-opencv.sh` creates an `opencv4.pc` → `opencv5.pc` compatibility alias because GStreamer's meson dependency lookup queries `dependency('opencv4')`. All patches are idempotent (guarded with grep before applying). When changing OpenCV or GStreamer versions, verify the patch still applies correctly.
