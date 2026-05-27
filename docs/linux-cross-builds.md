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

Manual staged build with plain `nerdctl` (current GCC 16 cross lane):

Run these commands from the repository root. Keep every trailing `\` as the last character on its line, and keep the final `.` because it is the Docker build context.

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

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee "${LOG_DIR}/compiler-cross-amd64.log"

for target_arch in amd64 arm64 riscv64; do
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact-${target_arch}" \
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
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-cross-${target_arch}" \
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
  nerdctl build --platform linux/amd64 -t "ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross-${target_arch}" \
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
    -f linux/Dockerfile \
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
- `torch-package-${target_arch}` rebuilds a clean target runtime surface from `android-cross-${target_arch}` by copying the cross-built payloads and wheelhouse into a real `linux/${target_arch}` image.
- `torch-cross-${target_arch}` now performs only the final Torch `/opt/venv` and `uv sync` step on `linux/${target_arch}` under QEMU. Use `TORCH_APP_MODE=install` when you only need a reusable `/opt/venv`; switch back to `all` to keep the emulated import smoke checks during the build.
- The final cross output is now `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`, built by publishing clean per-arch `linux/Dockerfile.base` images, layering the target-built `android-cross-${target_arch}` payload onto them with `linux/Dockerfile.package`, building `linux/Dockerfile.torch` on top of that packaged image, wrapping each result with `linux/Dockerfile`, and then publishing one multi-architecture manifest.

Think of the target-platform handoff like this:

- `linux/Dockerfile.base` -> `linux/Dockerfile.package` -> `linux/Dockerfile.torch` -> `linux/Dockerfile` produces `latest-cross-${target_arch}`.
- `linux/Dockerfile.base` -> `linux/Dockerfile.package` -> `linux/Dockerfile.torch` produces `torch-cross-${target_arch}`.

`linux/Dockerfile.package` is the point where the amd64-hosted cross artifacts are copied into a clean real target root filesystem. For foreign-architecture runtime images, that package stage must receive a real target-native `/opt/llvm-target` tree from the artifact image and must wire `/usr/bin/clang` to `/usr/local/llvm-target/bin/clang`; do not fall back to distro `/usr/local/llvm-22` on `arm64` or `riscv64`, or the final manifest can pick up a host-architecture Clang binary. After that, `linux/Dockerfile.torch` becomes the shared parent for both the exported Torch image and the final `latest-cross-${target_arch}` wrapper. The example above still uses separate `torch-base-*` and `torch-package-*` tags to keep the Torch logs and handoff tags explicit, but if you already built per-arch base/package images for `latest-cross`, you can reuse those same images for the Torch stage instead of rebuilding them.

The existing multi-platform sequential `sdk`, `media`, `android`, `torch`, and `latest` commands above still remain supported and unchanged.

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

## Cross packaging to multi-arch manifest (experimental)

The new end-goal path is split into two steps so the old QEMU lane keeps working:

1. Keep the existing multi-platform build for compatibility.
2. Build target artifacts host-side with the cross builder.
3. Assemble one runtime image per architecture from a clean per-arch `linux/Dockerfile.base` image plus the target-built payload from `android-cross-${target_arch}`.
4. Publish a single multi-architecture manifest.

`linux/Dockerfile.package` is the shared runtime packaging layer for this path. It starts from a clean per-arch base image, copies only the selected target payload from the chosen artifact image, replays the final runtime dependency setup, and then becomes the `BASE_IMAGE` for the final `linux/Dockerfile` wrapper. In `cross` mode that artifact image still runs on amd64 (`android-cross-${target_arch}`); in `native` mode it can be the target-platform sequential image directly.

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
    -f linux/Dockerfile \
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

The same package handoff now works for `linux/Dockerfile.torch` too. Build the heavy media/android payloads with the amd64-hosted cross compiler first, then feed `android-cross-${target_arch}` through `linux/Dockerfile.package`, build `linux/Dockerfile.torch` on `linux/${target_arch}`, and use that Torch image as the `BASE_IMAGE` for the final `linux/Dockerfile` wrapper. `TORCH_APP_MODE=install` keeps that QEMU Torch stage focused on creating `/opt/venv`, and the dedicated `venv-export` target lets you export only `/opt/venv` for later `COPY` into a matching real target image.

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

That path was validated for both `arm64` and `riscv64` with `clang version 22.1.6`, manual `update-alternatives` wiring to `/usr/local/llvm-target/bin/clang`, native `clang-22` binaries under `/usr/local/llvm-target/bin/`, and the optional runtime payloads under `/usr/local/lib/onnxruntime-genai`, `/usr/local/lib/onnxruntime-gpu`, `/usr/local/include/tflite`, `/usr/local/include/tensorflow`, and `/usr/local/lib/pkgconfig/litert.pc`.

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

The resulting image reported `clang version 22.1.6`, target `x86_64-unknown-linux-gnu`, and `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`.

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
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
  .
```
