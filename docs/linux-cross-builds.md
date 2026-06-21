# Linux Cross Builds

> **See also:** [`docs/linux-build-basics.md`](linux-build-basics.md) for build fundamentals, caching, and troubleshooting. [`AGENTS.md`](../AGENTS.md) for agent guardrails and the full repo map.

> Build-time download speed: the cross-compiler/SDK builds fetch the LLVM source with `git` inside a `RUN` step. On this host that is fast because rootless BuildKit runs with `--oci-worker-net=host` (host networking for `RUN` steps). Registry mirrors do not help that `git fetch`; the host-net setting does. See `docs/project-info.md` for the drop-in config and `AGENTS.md` for the do-not-regress note. For repeated LLVM rebuilds, prefer caching the source on the host over re-fetching.

> **Build logging:** All orchestrator scripts accept `--log-dir ./out/build-logs` to write per-stage build logs. For manual `nerdctl build` commands, capture output with `2>&1 | tee ./out/build-logs/<name>.log`. The standard location for build logs is `out/build-logs/`.

## Cross-Compiler builder (nerdctl, amd64 host; amd64/arm64/riscv64 targets)

The existing multi-platform build above stays unchanged. Treat it as the compatibility lane for the current QEMU/binfmt-based end-to-end build.

The cross-compiler path below is additive. It does not replace the existing QEMU workflow. Instead, it prepares a single amd64-hosted builder image that contains cross toolchains for amd64, arm64, and riscv64 for a future artifact-based multi-architecture endbuild.

This lane intentionally builds only a `linux/amd64` container image. The three architectures are the compiler targets installed inside that image via `CROSS_TARGETS=amd64,arm64,riscv64`, not three separate compiler container manifests.

For the cross-compiler path, the helper can bootstrap the base image locally when needed, so you do not have to rely on a remote `base` intermediate tag surviving in GHCR.

Fastest entry point:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --log-dir ./out/build-logs
```

Use `--fast-ubuntu-mirror-url URL` to override the default mirror (`https://archive.ubuntu.com/ubuntu/`). For example: `--fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/`.

The helper script only uses `nerdctl`. It first tries to reuse a local image, then tries to pull from the registry, and if that fails it rebuilds the base image locally before building the compiler image. It only pushes when you pass `--push`. Internally the script delegates to the shared stage graph (`stage-defs.sh`) and build helpers — the same infrastructure used by the full orchestrator. The `--image-repo` flag switches the registry prefix; there are no legacy env var overrides.

If you only need the downstream SDK or media cross stages and want to reuse the published compiler image, pull it first:

```bash
mkdir -p ./out/build-logs && \
nerdctl pull --platform linux/amd64 \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64 \
  2>&1 | tee ./out/build-logs/pull-compiler.log
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

nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64 \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg BUILD_MODE=cross \
  --build-arg CROSS_TARGETS=amd64,arm64,riscv64 \
  . 2>&1 | tee "${LOG_DIR}/cross-compiler-amd64.log"
```

The explicit `nerdctl build --output ... push=true` commands above already push the intermediary images to GHCR. Only the helper script keeps the images local by default unless you pass `--push`.

Expected compiler result inside that image:

- `gcc` and `g++` resolve to `/opt/gcc-16.1.0/bin/*` and report GCC 16.x on the amd64 host compiler path.
- `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc` resolve to `/opt/gcc-16.1.0/bin/*` and report GCC 16.x.
- `clang-amd64`, `clang-arm64`, and `clang-riscv64` still exist, but now point Clang at `/opt/gcc-16.1.0` as the GCC toolchain root.

Expected result: the build log ends with `ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64`. That is correct for this cross lane because the builder container itself runs on amd64 while shipping source-built GCC 16 host and cross compilers for all three target architectures.

Or let the helper do the push too:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror --push --log-dir ./out/build-logs
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

The cross-lane stage chain is defined declaratively in
`linux/scripts/01-core/stage-defs.sh`.  Each stage entry (Dockerfile, parent
stage, tag function, per-arch flag) is defined in `CROSS_STAGE_ORDER` so both
the build loop and `--verify-chain` consume the same single source of truth.
To add or reorder stages, update `CROSS_STAGE_ORDER` in that file.

### Stage graph management functions (stage-defs.sh)

`stage-defs.sh` now provides self-contained stage graph management:

- **`cross_stage_init_pins()`** — Declares all digest-pin variables (scalar for shared
  stages, associative arrays for per-arch stages) derived from the stage graph.
  Call once before entering the build loop.  Previously the orchestrator had to
  manually declare `BASE_PIN`, `COMPILER_PIN`, `SDK_PIN`, `MEDIA_PIN`,
  `ANDROID_PIN`, and `ANDROID_BUILT_THIS_RUN` — adding a stage required touching
  both files.  Now the graph is the single source of truth for pin variables too.

- **`cross_stage_validate_graph()`** — Runs before every build to check internal
  consistency: parent references resolve to valid stages, tags produce non-empty
  results, no dependency cycles exist.  Hard-fails if the graph is inconsistent,
  catching configuration errors early.

- **`cross_stage_ensure_parent_available()`** — For the runtime handoff: ensures the
  parent stage images (e.g. `cross-android-<arch>`) are locally available before
  delegating to `build-runtime-manifest.sh`.  Images built in the current run are
  already local; images from prior builds are pulled from the registry.  Replaces
  the old `_refresh_android_images()` with graph-driven resolution.

Stage build/pin orchestration functions are shared in
`linux/scripts/01-core/cross-stage-build.sh` (sourced via `artifact-common.sh`).
These functions (`cross_stage_run()`, `cross_stage_build_and_push()`,
`cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `resolve_pin()`)
are used by both the orchestrator and the standalone
`build-cross-stage.sh` helper.  `cross_stage_build_local()` handles local-only
(non-push) builds, while `cross_stage_build_and_push()` handles registry-pushed
builds with cache support.

`cross_stage_run()` is the shared entry point for all stage builds. It accepts a
`push` flag (3rd argument, default `1`):
- `push=1`: resolves the parent via digest-pinned reference, pushes the stage
  image to the registry, and captures the digest pin for downstream stages.
- `push=0`: resolves the parent via mutable tag, builds locally only, does not
  push or pin.

Both the orchestrator (`push=1` for all stages), the single-stage builder
(`build-cross-stage.sh`), and the standalone compiler
(`build-cross-compiler.sh`) use this same function, eliminating duplicated
build/pin logic across scripts.

The runtime helpers share initialization logic via
`linux/scripts/01-core/runtime-flow-common.sh`, which provides
`init_runtime_flow_defaults()` and `runtime_flow_export_setup()`.  Both
`build-runtime-artifacts.sh` and `build-runtime-manifest.sh` source this
directly after `artifact-common.sh`.

```bash
# Rebuild a single cross stage independently:
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push --log-dir ./out/build-logs
```

### Stale-check (`--verify-chain` and `verify-cross-chain.sh`)

Before a full build, verify whether downstream registry images are stale without
performing any builds.  The verification logic is shared via
`linux/scripts/01-core/chain-verify.sh` (sourced by both entry points).
Two entry points:

```bash
# Via the orchestrator (same process):
./linux/scripts/build-cross-chain.sh \
  --target-arches amd64,arm64,riscv64 \
  --verify-chain \
  --log-dir ./out/build-logs

# Standalone (lighter, no orchestrator flags needed):
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64
bash linux/scripts/verify-cross-chain.sh --target-arches arm64
```

Both resolve all upstream registry digests and report mismatches so you can
decide whether a full rebuild is needed.  The standalone script is useful for
quick checks without loading the full orchestrator.

### Describe chain (`--describe-chain`)

Print the full stage graph with tag names and parent chains without building:

```bash
# Via the orchestrator:
./linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Via the standalone verifier:
bash linux/scripts/verify-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64
```

This shows which Dockerfile produces each stage, the expected tags per
architecture, and the parent→child relationships.

### Why the handoff must be pinned by digest

Each cross stage is a separate `nerdctl build` whose next stage does
`FROM ${BASE_IMAGE}`. If `BASE_IMAGE` is a **mutable tag** such as
`:cross-media-arm64`, the downstream build can silently consume a **stale,
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
> `linux/scripts/01-core/digest-pinning.sh` does — sourced by
> `artifact-common.sh`).

Partial runs are supported, e.g. resume from media for one arch:

```bash
./linux/scripts/build-cross-chain.sh --target-arches arm64 --from-stage media --to-stage android --log-dir ./out/build-logs
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
   sdk pin from the registry tag `cross-sdk-arm64` — which was built from the
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

## Manual staged build (low-level reference)

For full hands-off builds, prefer the orchestrator `build-cross-chain.sh` with
digest-pinned stage handoff.  Each cross stage maps to one Dockerfile and one
tag; the orchestrator and `build-cross-stage.sh` handle the per-arch fan-out,
build arg assembly, and pin capture for you.  Use the helpers unless you are
debugging a specific stage in isolation.

If you must drive individual builds manually, refer to the helper scripts for
the canonical argument set (or run them with `--dry-run` to print the commands
they would execute).  The essential pattern for each cross-lane stage is:

```bash
nerdctl build --platform linux/amd64 --pull=true \
  --output 'type=image,name=<tag>,push=true' \
  -f <dockerfile> \
  --build-arg BASE_IMAGE=<parent_tag_or_pinned_digest> \
  --build-arg BUILD_MODE=cross \
  [--build-arg TARGET_ARCH=<arch> if per-arch] \
  .
```

For the runtime lane, prefer `build-runtime-manifest.sh`.  The helper handles
the `base -> package -> torch` chain and multi-arch manifest creation.
`--manifest-only` / `--repair` can recreate the manifest from existing per-arch
wrappers without rebuilding any images.

`linux/Dockerfile.sdk` serves both the sequential SDK build and the amd64-hosted cross SDK artifact lane.
The cross path consumes one `TARGET_ARCH` per `nerdctl build`, fanned out per architecture.

`linux/Dockerfile.package` is the handoff point where amd64-hosted cross artifacts are copied into a clean
target-native root filesystem. For foreign-architecture images, the package stage must receive:
- A target-native `/opt/llvm-target` tree, wired to `/usr/bin/clang`
- A target-native `/opt/gcc-16.1.0` (cross-compiled from source via Canadian cross, swapped in by `Dockerfile.android`)
- A hard-fail CC validation guard (dumpmachine, ELF type, cc1 smoke test)

`linux/Dockerfile.torch` produces the final `:latest-cross-<arch>` wrapper images (torch venv, app, runtime scripts, entrypoint).
The per-arch wrappers are assembled into the `:latest-cross` multi-arch manifest.

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

For individual SDK artifact builds, use `build-cross-stage.sh`:
```bash
for arch in amd64 arm64 riscv64; do
  bash linux/scripts/build-cross-stage.sh --stage sdk --arch "${arch}" --push --log-dir ./out/build-logs
done
```

If you want this helper to reuse the published compiler image instead of bootstrapping it locally, pull the compiler tag first:

```bash
mkdir -p ./out/build-logs && \
nerdctl pull --platform linux/amd64 \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64 \
  2>&1 | tee ./out/build-logs/pull-compiler.log
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

`linux/Dockerfile.sdk` also forwards the checked-in `LLVM_RELEASE` pin into the `target-clang` step, so rebuilding an SDK artifact from an older `cross-compiler-amd64` base still refreshes `/opt/llvm-target` to the repository pin instead of inheriting a stale base-image environment value.

## Cross packaging to multi-arch manifest (experimental)

The new end-goal path is split into two steps so the old QEMU lane keeps working:

1. Keep the existing multi-platform build for compatibility.
2. Build target artifacts host-side with the cross builder.
3. Assemble one runtime image per architecture from a clean per-arch `linux/Dockerfile.base` image plus the target-built payload from `cross-android-${TARGET_ARCH}`.
4. Publish a single multi-architecture manifest.

`linux/Dockerfile.package` is the shared runtime packaging layer for this path. It starts from a clean per-arch base image, copies only the selected target payload from the chosen artifact image, replays the final runtime dependency setup, and then becomes the `BASE_IMAGE` for the final `linux/Dockerfile.torch` wrapper. In `cross` mode that artifact image still runs on amd64 (`cross-android-${TARGET_ARCH}`); in `native` mode it can be the target-platform sequential image directly.

For day-to-day work on this host, prefer the helper scripts below over the long manual `nerdctl` loops. The manual sequence remains useful as a low-level reference, but the helpers already encode the verified local-context handoff and push semantics.

The main repo-root Linux Dockerfiles also now carry Dockerfile-specific ignore files so helper/manual cross builds do not send `linux/webserver/` and the large exported `out/*` trees back through the default build context on every stage.

The per-arch `latest-cross-base-*`, `latest-cross-package-*`, and `latest-cross-*`
tags are internal publish tags used to assemble the public `latest-cross` manifest.
Prefer the runtime helpers:

```bash
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --push \
  --log-dir ./out/build-logs
```

Run with `--dry-run` to print the commands it would execute without building.

The same package handoff now works for `linux/Dockerfile.torch` too. Build the heavy media/android payloads with the amd64-hosted cross compiler first, then feed `cross-android-${TARGET_ARCH}` through `linux/Dockerfile.package`, build `linux/Dockerfile.torch` on `linux/${TARGET_ARCH}` (which now includes the runtime scripts + entrypoint directly). `TORCH_APP_MODE=install` keeps that QEMU Torch stage focused on creating `/opt/venv`, and the dedicated `venv-export` target lets you export only `/opt/venv` for later `COPY` into a matching real target image.

The helper scripts now follow the same runtime path too:

- `linux/scripts/build-runtime-manifest.sh` builds `base -> package -> torch -> wrapper -> manifest`.
- `linux/scripts/build-runtime-artifacts.sh` builds that same `base -> package -> torch -> wrapper` chain and exports the final wrapper rootfs instead of creating a manifest.
- Both helpers accept `--target-arches`, `TARGET_ARCHES`, or `TARGET_ARCH` for architecture selection.
- Both helpers accept `ARTIFACT_BUILD_MODE=cross` or `ARTIFACT_BUILD_MODE=native` for selecting the package artifact source.
- In `cross` mode, `ARTIFACT_IMAGE_PREFIX` is treated as a prefix like `ghcr.io/...:cross-android` and the helper fans out `-${TARGET_ARCH}` automatically.
- In `native` mode, `ARTIFACT_IMAGE_PREFIX` is treated as the exact artifact image ref, for example `ghcr.io/...:android`.
- In `cross` mode, the media artifact lane now also makes a best-effort `riscv64` app wheelhouse on the amd64 host for the locked `torch`, `torchvision`, and `opencv-python` git-source dependencies used by `Kataglyphis-Orchestr-ANT-ion`, and carries those wheels forward through the existing `/opt/wheels` handoff when the build succeeds.
- The helper still runs `linux/Dockerfile.torch` on the real target platform in both modes so `/opt/venv` is populated in the final runtime image.
- The final Torch install now keeps the upstream `uv.lock` when it is present, runs `uv sync --frozen`, and skips reinstalling any packages that already exist in `/opt/wheels` before force-reinstalling the local wheelhouse.
- If a reused cross artifact has an empty `/opt/wheels`, the Torch install step now keeps the packages that `uv sync` already resolved instead of uninstalling them and trying to install a literal `/opt/wheels/*.whl` glob.
- When images stay local, the helpers keep the intermediate runtime handoff off-registry by default. `base` is exported as a plain rootfs directory, while `package` and `torch` are exported as OCI layouts and then consumed through named build contexts.
- `ARTIFACT_CONTEXT_ROOT` lets the runtime helpers consume previously saved runtime artifacts from disk instead of pulling `cross-android-*` from a registry.
- `ARTIFACT_CONTEXT_MODE=oci` makes each `ARTIFACT_CONTEXT_ROOT/<arch>` resolve as `oci-layout://...`. That is the verified path for the saved `out/local-oci/android/{arm64,riscv64}` artifacts.
- On this host, one build still fails when it consumes two named OCI image contexts at once. The working workaround is to keep `runtime_artifact` as an OCI layout context and `runtime_base` as a plain rootfs directory context.
- Each local stage context is deleted as soon as the downstream build finishes consuming it, which keeps non-push runs off `/tmp` and reduces peak disk usage.
- `build-runtime-artifacts.sh --push` pushes the final per-architecture wrapper images even when the helper keeps `base -> package -> torch` in local stage contexts.
- `build-runtime-manifest.sh --push` is shorthand for `--push-images --push-manifest`.
- `build-runtime-manifest.sh --manifest-only` (or its alias `--repair`) creates/pushes the manifest only without rebuilding any images. This is the recommended way to repair a :latest-cross manifest from existing per-arch wrapper images.
- Use `--push-all` only when you also want the `base`, `package`, and `torch` intermediates pushed.

Verified local foreign-architecture rebuild on this host:

```bash
ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android" \
ARTIFACT_CONTEXT_MODE=oci \
RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts" \
bash linux/scripts/build-runtime-artifacts.sh \
  --target-arches arm64,riscv64 \
  --image-prefix docker.io/library/opencode-local:latest-cross \
  --artifact-image-prefix docker.io/library/opencode-local:cross-android \
  --artifact-build-mode cross \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/ \
  --log-dir ./out/build-logs
```

That path was validated for both `arm64` and `riscv64` with `gcc version 16.1.0`, `clang version 22.1.6`, `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-16.1.0/bin/gcc`, native `gcc-16` binaries under `/opt/gcc-16.1.0/bin/`, and the optional runtime payloads under `/usr/local/lib/onnxruntime-genai`, `/usr/local/lib/onnxruntime-gpu`, `/usr/local/include/tflite`, `/usr/local/include/tensorflow`, and `/usr/local/lib/pkgconfig/litert.pc`. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) so `/opt/gcc-16.1.0/bin/gcc` is a target-native binary. The build-time guard in `Dockerfile.package` verifies that `cc -dumpmachine` matches the target architecture, asserts the ELF machine type of the `cc` binary itself (via `readelf -h`), and runs a cc1 compile-to-object smoke under the target platform.

After the runtime helper cleanup in this repository, the same helper path was re-validated for `amd64` with:

```bash
RUNTIME_CONTEXT_ROOT="/tmp/opencode/runtime-contexts" \
bash linux/scripts/build-runtime-artifacts.sh \
  --target-arches amd64 \
  --output-root /tmp/opencode/runtime-smoke \
  --image-prefix docker.io/library/opencode-local:latest-cross-smoke \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --artifact-build-mode cross \
  --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/ \
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/ \
  --log-dir ./out/build-logs
```

The resulting image reported `gcc version 16.1.0`, `clang version 22.1.6`, target `x86_64-unknown-linux-gnu`, `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-16.1.0/bin/gcc`, and `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`.

For local wrapper smoke validation without pushing anything, build the checked-in smoke target directly:

```bash
mkdir -p ./out/build-logs && \
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-cross-wrapper-smoke-amd64 \
  -f linux/Dockerfile.package \
  --target wrapper-smoke \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg ARTIFACT_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android-amd64 \
  --build-arg ARTIFACT_PLATFORM=linux/amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=cross \
  --build-arg GCC_VERSION=16.1.0 \
  --build-arg LLVM_RELEASE=22.1.6 \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
  . 2>&1 | tee ./out/build-logs/wrapper-smoke.log
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
