# Linux Cross Builds

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
nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  . 2>&1 | tee -a output.log
```

Then build the dedicated amd64-hosted compiler image in cross mode for amd64, arm64, and riscv64 targets:

```bash
nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee -a output.log
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

Manual staged build with plain `nerdctl` (current GCC 16 cross lane):

Run these commands from the repository root. Keep every trailing `\` as the last character on its line, and keep the final `.` because it is the Docker build context.

These commands assume `nerdctl` is already usable from your current shell without `sudo`.

```bash
set -o pipefail

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  . 2>&1 | tee -a output.log

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee -a output.log

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch},push=true" \
    -f linux/Dockerfile.sdk \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee -a output.log
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch},push=true" \
    -f linux/Dockerfile.media \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee -a output.log
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch},push=true" \
    -f linux/Dockerfile.android \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee -a output.log
done

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-cross-${target_arch}" \
    --output "type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-cross-${target_arch},push=true" \
    -f linux/Dockerfile.torch \
    --build-arg USE_FAST_UBUNTU_MIRROR=true \
    --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
    --build-arg BASE_IMAGE="ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${target_arch}" \
    . 2>&1 | tee -a output.log
done

./linux/scripts/build-runtime-artifacts.sh \
  --target-arches amd64,arm64,riscv64 \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  2>&1 | tee -a output.log

./linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --artifacts-root out/linux-runtime \
  --push 2>&1 | tee -a output.log
```

`linux/Dockerfile.sdk` now serves both the sequential SDK build and the amd64-hosted cross SDK artifact lane. The cross path still consumes one `TARGET_ARCH` per `nerdctl build`, so the loops above intentionally fan that out one target at a time for `amd64`, `arm64`, and `riscv64`.

The later cross builds above are additive and still intentionally conservative:

- `media-cross-${target_arch}` now runs the native C/C++ stages with target compilers and target pkg-config/sysroot settings on the amd64 host.
- `android-cross-${target_arch}` now keys off the amd64 build host for SDK/NDK setup while still selecting the requested Android target ABI from `TARGET_ARCH`.
- `torch-cross-${target_arch}` is currently a structural cross stage only. It preserves the image chain but skips the live Python environment assembly because target wheels cannot be safely installed and imported inside an amd64 build container.
- The final cross output is now `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`, built by exporting one final runtime rootfs per target with `linux/Dockerfile` and then publishing a single multi-architecture manifest.

The existing multi-platform sequential `sdk`, `media`, `android`, `torch`, and `latest` commands above still remain supported and unchanged.

This image is a single amd64 builder image, not a replacement for the full multi-platform Linux chain yet. It keeps the current native/emulated flow intact while adding source-built GCC 16 target compilers like `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc`, plus convenience wrappers such as `clang-amd64`, `clang-arm64`, and `clang-riscv64` for host-side cross builds.

## SDK rootfs artifacts (first host-side build step)

The first additive artifact path is now the SDK stage. It reuses `linux/Dockerfile.sdk` in `BUILD_MODE=cross`, builds target-specific SDK root filesystems for amd64, arm64, and riscv64 on a fast amd64 host, and exports them to disk while the existing QEMU/binfmt multi-platform build above remains unchanged.

Build the first SDK artifacts for amd64, arm64, and riscv64 while streaming everything to both the terminal and `output.log`:

```bash
set -o pipefail
./linux/scripts/build-sdk-artifacts.sh --target-arches amd64,arm64,riscv64 --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  2>&1 | tee -a output.log
```

Build all three SDK artifact targets directly with `nerdctl` and log them the same way:

```bash
set -o pipefail
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
    . 2>&1 | tee -a output.log
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

## Cross-artifacts to multi-arch manifest (experimental)

The new end-goal path is split into two steps so the old QEMU lane keeps working:

1. Keep the existing multi-platform build for compatibility.
2. Build target rootfs artifacts host-side with the cross builder.
3. Assemble one runtime image per architecture.
4. Publish a single multi-architecture manifest.

The additive runtime Dockerfile for this path is `linux/Dockerfile.runtime-artifact`. It is copy-only and meant for prebuilt rootfs trees.

Export the final runtime rootfs trees from `linux/Dockerfile` first:

```bash
set -o pipefail
./linux/scripts/build-runtime-artifacts.sh \
  --target-arches amd64,arm64,riscv64 \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  2>&1 | tee -a output.log
```

Expected artifact layout:

```text
out/linux-runtime/amd64/rootfs/
out/linux-runtime/amd64/artifact.env
out/linux-runtime/arm64/rootfs/
out/linux-runtime/arm64/artifact.env
out/linux-runtime/riscv64/rootfs/
out/linux-runtime/riscv64/artifact.env
```

That helper builds `linux/Dockerfile` once per target architecture in `BUILD_MODE=cross`, using the published `android-cross-${target_arch}` images as inputs. The final cross step is therefore no longer a per-target published `latest-cross-${target_arch}` wrapper. Instead, it exports the final runtime filesystem for each target and then assembles one real multi-architecture `latest-cross` image tag from those exported rootfs trees.

Once these rootfs artifacts exist, build one image per architecture and create a single manifest with nerdctl:

```bash
set -o pipefail
./linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --artifacts-root out/linux-runtime \
  --push 2>&1 | tee -a output.log
```

This helper only adds a second lane. It does not modify the current QEMU-based multi-platform build commands above.