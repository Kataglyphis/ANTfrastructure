# Linux Cross Builds

> **See also:** [`docs/linux-build-basics.md`](linux-build-basics.md) for build fundamentals, caching, and troubleshooting. [`AGENTS.md`](../AGENTS.md) for agent guardrails and the full repo map.

> Build-time download speed: the cross-compiler/SDK builds fetch the LLVM source with `git` inside a `RUN` step. On this host that is fast because rootless BuildKit runs with `--oci-worker-net=host` (host networking for `RUN` steps). Registry mirrors do not help that `git fetch`; the host-net setting does. See `docs/project-info.md` for the drop-in config and `AGENTS.md` for the do-not-regress note. For repeated LLVM rebuilds, prefer caching the source on the host over re-fetching.

<a id="build-logging"></a>

> **Build logging:** `build-cross-chain.sh` and `build-cross-stage.sh` accept `--log-dir ./out/build-logs` to write per-stage build logs. The other orchestrators (`build-cross-compiler.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`) do not — capture their output, and any manual `nerdctl build`, with `2>&1 | tee ./out/build-logs/<name>.log`. The standard location for build logs is `out/build-logs/`.

## Cross-Compiler builder (nerdctl, amd64 host; amd64/arm64/riscv64 targets)

The existing multi-platform build above stays unchanged. Treat it as the compatibility lane for the current QEMU/binfmt-based end-to-end build.

The cross-compiler path below is additive. It does not replace the existing QEMU workflow. Instead, it prepares a single amd64-hosted builder image that contains cross toolchains for amd64, arm64, and riscv64 for a future artifact-based multi-architecture end-to-end build.

This lane intentionally builds only a `linux/amd64` container image. The three architectures are the compiler targets installed inside that image via `CROSS_TARGETS=amd64,arm64,riscv64`, not three separate compiler container manifests. This image is a single amd64 builder image, not a replacement for the full multi-platform Linux chain yet. It keeps the current native/emulated flow intact while adding source-built GCC 16 target compilers like `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc`, plus convenience wrappers such as `clang-amd64`, `clang-arm64`, and `clang-riscv64` for host-side cross builds.

For the cross-compiler path, the helper can bootstrap the base image locally when needed, so you do not have to rely on a remote `base` intermediate tag surviving in GHCR.

Fastest entry point:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \
  --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/
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

- `gcc` and `g++` resolve to `/opt/gcc-16.2.0/bin/*` and report GCC 16.x on the amd64 host compiler path.
- `x86_64-linux-gnu-gcc`, `aarch64-linux-gnu-gcc`, and `riscv64-linux-gnu-gcc` resolve to `/opt/gcc-16.2.0/bin/*` and report GCC 16.x.
- `clang-amd64`, `clang-arm64`, and `clang-riscv64` still exist, but now point Clang at `/opt/gcc-16.2.0` as the GCC toolchain root.

Expected result: the build log ends with `ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-compiler-amd64`. That is correct for this cross lane because the builder container itself runs on amd64 while shipping source-built GCC 16 host and cross compilers for all three target architectures.

Or let the helper do the push too:

```bash
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror --push
```

## Recommended: digest-pinned orchestrator (`build-cross-chain.sh`)

For a hands-off, agent-proof end-to-end cross build, prefer the orchestrator
(see `AGENTS.md` § Quick Reference for the canonical command).
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
`init_runtime_flow_defaults()`. Both `build-runtime-artifacts.sh` and
`build-runtime-manifest.sh` reach it by sourcing `lib-orchestrator.sh`, which
loads it inside `runtime_flow_preamble()`.

See `AGENTS.md` § Quick Reference for standalone single-stage rebuild commands.

### `--no-push` full chains: FIXED 2026-08-30 via local OCI-layout handoff

**History worth keeping:** on this host builds run on BuildKit's **OCI worker**,
which has its own image store. `nerdctl build -t` loads results into
**containerd's** store — which the next build's `FROM` never consults. The
mutable parent tag resolved against the **registry**, so every downstream stage
of a `--no-push` chain silently built on the last PUSHED parent, not the one
just built (two full runs were lost to sdk stages compiled on a months-old
compiler before the digest trail exposed it — the freshly built compiler had
`/opt/gcc-16.2.0`, the sdk image it "inherited from" had `/opt/gcc-16.1.0`).

**The fix (cross-stage-build.sh, 2026-08-30), mirroring the runtime lane's
proven mechanism:** on `--no-push` chains every stage built locally is exported
to an OCI layout (`export_image_to_oci_layout` from context-management.sh) at
`${CROSS_CONTEXT_ROOT:-~/.cache/opencode/cross-stage-contexts}/cross-flow.*/<stage>-<arch>`,
and each child's parent resolution appends
`--build-context <parent-tag>=oci-layout://<dir>` so its FROM resolves to the
image THIS RUN built. The android image is additionally exported to
`<workdir>/android-artifacts-<arch>` and handed to the runtime lane as
`ARTIFACT_CONTEXT_ROOT` (mode `oci`), so the no-push package build copies from
the locally-built android, not the registry. The workdir is minted once per run
and reclaimed on exit (age-based sweep for killed runs). The multi-stage
refusal guard now allows full chains (from base) and only refuses mid-chain
resumes (`--from-stage` after base), which cannot serve the missing prefix.
Opt-outs: `CROSS_LOCAL_CONTEXT_HANDOFF=0` (reverts to the refusal) and
`CROSS_NO_PUSH_FORCE=1`. Mechanism proven on the live host 2026-08-30 with a
two-stage test build: stage B's FROM resolved from the exported layout
(`--pull=false`, content marker verified), never the registry.
`CROSS_CONTEXT_ROOT` is free space ~= the built stages' aggregate size (media +
android are multi-GB) — transient, deleted at chain exit.

### The flow that is correct today: push mode, manifest last

```bash
# Build and push every cross stage with digest-pinned handoffs; stop before the
# runtime stage if you do not want to touch the published manifest yet:
bash linux/scripts/build-cross-chain.sh --target-arches amd64 \
  --to-stage android --log-dir ./out/build-logs

# Runtime lane: build+push+smoke the per-arch wrappers WITHOUT recreating the
# multi-arch :latest-cross manifest (so a single-arch run cannot clobber it):
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64 \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --artifact-build-mode cross --push --skip-manifest

# When ALL arches' wrappers exist, publish the manifest in one shot:
bash linux/scripts/build-runtime-manifest.sh --image ...:latest-cross \
  --target-arches amd64,arm64,riscv64 --manifest-only
```

Push mode is also what arms the ancestry annotations — the machine-checked
stale-ancestor guard exists only for pushed stages.

### Opt-in: concurrent per-target GCC builds

`GCC_PARALLEL_TARGETS=1` builds the arm64/riscv64 cross+Canadian GCCs
concurrently inside the compiler stage (~30 % off that RUN at 3 targets).
The driver runs a serial apt pre-pass first (dpkg lock), divides `JOBS`
across the concurrent builds, and writes per-target logs (replayed on
failure). Default `0` = the sequential flow, byte-identical. The host GCC
always builds first (alternatives registration), and the build-arch target is
symlink-only. See `gcc.sh::_gcc_build_cross_targets_parallel`.

### Stale-check (`--verify-chain` and `verify-cross-chain.sh`)

Before a full build, verify whether downstream registry images are stale without
performing any builds.  The verification logic is shared via
`linux/scripts/01-core/chain-verify.sh` (sourced by both entry points).
See `AGENTS.md` § Quick Reference for the chain verification commands. Both resolve all upstream registry digests and report mismatches so you can
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
   `/opt/gcc-16.2.0-native-arm64`).
3. You run `--from-stage media --to-stage android`. The orchestrator resolves the
   sdk pin from the registry tag `cross-sdk-arm64` — which was built from the
   **old** compiler and is missing the new content.
4. The new media rebuild inherits from the stale sdk, and the new compiler
   content never reaches the final image.

**This is now checked automatically.** `linux/scripts/01-core/ancestry.sh` turns
the rule below into a machine-enforced invariant, so a partial run can no longer
silently build on a stale ancestor:

- **Write:** every pushed cross stage records the digest-pinned reference it was
  actually built `FROM` as an OCI manifest annotation
  (`org.kataglyphis.parent-digest`, plus `org.kataglyphis.parent-stage`). This is
  free — it rides along in the manifest the push already writes.
- **Read:** `nerdctl manifest inspect --verbose` returns the verbatim registry
  manifest in its base64 `Raw` field, so the annotation is readable without
  pulling the image or fetching config blobs (`01-core/manifest-annotation.py`).
- **Assert:** before a run with `--from-stage` after `base`, the orchestrator
  walks the ancestor chain feeding that stage. For each `child → parent` link the
  digest the child **records** must equal the digest the parent tag **currently**
  resolves to. A mismatch aborts the run before anything is built, naming the
  stage to restart from.

Failure semantics are deliberately asymmetric:

| situation | verdict | why |
|---|---|---|
| annotation present, digests match | pass | ancestry proven current |
| annotation present, digests differ | **hard fail** | positive evidence of a stale ancestor |
| annotation absent | warn | image predates the annotation; provenance unknown, not known-bad |
| parent tag unresolvable | warn | that is the build's error to report, not an ancestry violation |

Only the digest half of the reference is compared, so `--image-repo` may move the
chain to another registry path without tripping the check.

Escape hatch when you knowingly accept a stale ancestor:
`--no-verify-ancestry`, or `CROSS_VERIFY_ANCESTRY=0`.

A full `--from-stage base` run pays nothing for this: there are no prior stages
that could be stale, so the check returns immediately.

**The manual discipline this replaces** (still worth understanding, and still
what the check tells you to do):

- After replacing any base image (compiler, sdk, etc.), **rebuild from the
  replaced stage** — not a later one. E.g. after a compiler push, start from
  `--from-stage sdk`, not `--from-stage media`.
- **Verify** downstream images contain the expected new content before relying on
  them (e.g. check that `/opt/gcc-16.2.0-native-arm64` exists in the pinned sdk
  digest with `nerdctl run --rm <repo>@<digest> ls -d /opt/gcc-16.2.0-native-arm64`).
- **The `--from-stage` flag only controls where execution starts; it does NOT
  update the base image of the first stage it runs.** If the stage just before
  your `--from-stage` inherits from a stale upstream, so will your rebuild.
- For partial runs after a compiler update, always use `--from-stage sdk` as the
  minimum starting point.

> Note the division of labour: **digest pinning** keeps a *single* orchestrator
> run internally consistent; the **ancestry check** is the cross-run half. Neither
> subsumes the other.

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
- A target-native `/opt/gcc-16.2.0` (cross-compiled from source via Canadian cross, swapped in by `Dockerfile.android`)
- A hard-fail CC validation guard (dumpmachine, ELF type, cc1 smoke test)

`linux/Dockerfile.torch` produces the final `:latest-cross-<arch>` wrapper images (torch venv, app, runtime scripts, entrypoint).
The per-arch wrappers are assembled into the `:latest-cross` multi-arch manifest.

### OpenCV 5.x GStreamer compatibility (applies to all architectures)

OpenCV 5.x reorganized several modules relative to OpenCV 4.x. GStreamer's bundled `gst-plugins-bad` "opencv" plugin (1.29.x) still targets the 4.x layout, so it fails to compile against the source-built OpenCV 5 in this image. The build system applies an automatic source patch via `patch-gstreamer-sources.sh` → `patch_gstreamer_sources()` that addresses three upstream API changes:

1. **`contourArea`/`approxPolyDP`/`convexHull`** moved from `imgproc` to the new `geometry` module → adds `#include <opencv2/geometry.hpp>` to `gstsegmentation.cpp`.
2. **`findChessboardCorners`/`findCirclesGrid`/`drawChessboardCorners` + `CALIB_CB_*`** moved from `calib3d` into `objdetect` → adds `#include <opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`.
3. **`cv::CascadeClassifier`** + `CASCADE_*` (legacy Haar cascade detection) were **removed** from OpenCV 5 → the three cascade-dependent GStreamer elements (`faceblur`, `facedetect`, `handdetect`) are dropped from the monolithic `libgstopencv.so`. The remaining 22 elements (dilate, sobel, smooth, edgedetect, tracker, grabcut, retinex, segmentation, cameracalibrate, etc.) build and function normally.

Additionally, `build-opencv.sh` creates an `opencv4.pc` → `opencv5.pc` compatibility alias because GStreamer's meson dependency lookup queries `dependency('opencv4', '>= 4.0.0')`.

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

This helper uses `linux/Dockerfile.sdk` with `BUILD_MODE=cross` and the amd64-hosted cross compiler image. During successful cross SDK builds, CMake should identify the active C++ compiler as `GNU 16.2.0` rather than the Ubuntu 26.04 system GCC toolchain. It is the first real host-side rootfs export step toward a full multi-architecture non-QEMU end-to-end build, but it does not yet replace the full `:latest-cross` pipeline.

`linux/Dockerfile.sdk` also forwards the checked-in `LLVM_RELEASE` pin into the `target-clang` step, so rebuilding an SDK artifact from an older `cross-compiler-amd64` base still refreshes `/opt/llvm-target` to the repository pin instead of inheriting a stale base-image environment value.

## Cross packaging to multi-arch manifest (experimental)

### Overview

The new end-goal path keeps the existing QEMU lane for compatibility while adding:
1. Cross-compile target artifacts host-side with the cross builder.
2. Assemble one runtime image per architecture from a clean per-arch `linux/Dockerfile.base` plus the target-built payload from `cross-android-${TARGET_ARCH}`.
3. Publish a single multi-architecture manifest.

`linux/Dockerfile.package` is the shared runtime packaging layer. It starts from a clean per-arch base, copies the selected target payload from the artifact image, replays final runtime dependency setup, and becomes `BASE_IMAGE` for `linux/Dockerfile.torch`. In `cross` mode the artifact image runs on amd64 (`cross-android-${TARGET_ARCH}`); in `native` mode it uses the target-platform sequential image directly.

### Host prerequisite: QEMU/binfmt for the emulated runtime legs

The `sdk`/`media`/`android` stages cross-compile *on amd64* and need no emulation
by design — but note the registration is load-bearing even there: nested NATIVE
tool sub-builds (e.g. IREE's bundled-LLVM tblgen) historically only survived
because qemu silently executed a wrong-arch binary. That specific case is fixed
at the source (`CROSS_TOOLCHAIN_FLAGS_NATIVE` pins the host compilers), but keep
binfmt registered — it is the safety net for the whole class.

**Lifetime:** the registration lives in the rootlesskit namespace and dies on
host reboot **and on `systemctl --user restart containerd`** (this bit the
2026-08-08 foreign chain: the shim-failure restart earlier that day had silently
wiped it, and media-arm64's IREE build failed with `Exec format error`).
`--install-service` below installs a systemd --user unit so it re-registers
automatically.
The **runtime** stage is different: `build-runtime-manifest.sh` builds the per-arch
`base → package → torch` wrappers **on the real target platform**
(`nerdctl build --platform linux/arm64|riscv64`). For foreign architectures those
`RUN` steps (e.g. `base-image.sh bootstrap-ca`, `copy-media-payloads.sh`, `apt`,
`dpkg`) execute under QEMU user-mode emulation, which requires QEMU emulators
registered in `binfmt_misc` in the namespace where builds run.

#### Rootless setup (this host — no sudo)

Run the helper once per boot (it is idempotent, and `--install-service` makes it
persistent via a systemd --user unit):

```bash
linux/scripts/setup-rootless-binfmt.sh                    # register arm64,riscv64 now
linux/scripts/setup-rootless-binfmt.sh --install-service  # + auto-register on every login/boot
linux/scripts/setup-rootless-binfmt.sh --verify           # check current state
```

You normally don't run it by hand: **`build-runtime-manifest.sh` invokes it for you
(no sudo)** right before the per-arch runtime-image smokes, for whichever target
arches are non-native (`ensure_foreign_binfmt`). Set `RUNTIME_REGISTER_BINFMT=0` to
skip that auto-registration (e.g. a rootful/CI host where qemu is already registered
via `docker run --privileged tonistiigi/binfmt` or `update-binfmts`). The standalone
invocations above are for registering ahead of time or debugging.

Why the helper is needed (and why the "obvious" commands don't work rootless):

- **`sudo apt install qemu-user-static` is not required and not wanted here** — this
  host runs rootless containerd + BuildKit and must stay sudo-free.
- **A plain `nerdctl run --privileged --rm tonistiigi/binfmt --install all` does NOT
  work** even though it prints `arm64 OK`. A rootless `--rm` container registers
  binfmt inside its *own* ephemeral user namespace, which is destroyed on exit — the
  registration never reaches the namespace where real containers/builds run. Symptom:
  `exec format error` on any nested exec, e.g. a `-d` container that returns an ID but
  immediately exits `255` with `exec /docker-entrypoint.sh: exec format error`, or a
  build step dying at `uname` / `apt`.
- **The key insight this host relies on:** buildkitd is launched *nsenter'd into
  containerd's rootlesskit namespace*
  (`systemctl --user cat buildkit.service` → `ExecStart=... containerd-rootless-setuptool.sh nsenter -- buildkitd ...`),
  so `nerdctl run` and `nerdctl build` **share one persistent rootless namespace**.
  The helper registers QEMU *once* in that shared namespace (entering it the same way,
  via `containerd-rootless-setuptool.sh nsenter`), so both emulate correctly. Because
  `binfmt_misc` is user-namespace-mountable on this kernel, the helper overmounts a
  fresh, namespace-owned (writable) `binfmt_misc` there without any host privilege.

Registration flags matter — the helper uses **`POCF`**:

| flag | meaning | why it's needed |
|------|---------|-----------------|
| `P`  | preserve-argv[0] | **critical** — without it qemu drops `argv[1]`; `sh -c CMD` loses `-c` and dash treats `CMD` as a filename (`cannot open …: No such file`) |
| `O`  | open-binary as fd | lets qemu run a target that isn't on the interpreter's path |
| `C`  | credentials | setuid/setgid handling |
| `F`  | fix-binary | kernel opens the interpreter fd at registration time, so it is inherited into nested build/run namespaces where the qemu path isn't mounted |

Symptom in an orchestrator run when binfmt is missing/misregistered: the `runtime`
stage's arm64/riscv64 legs die with
`error: failed to solve: process "/dev/.buildkit_qemu_emulator ... bootstrap-ca ..."
did not complete successfully: exit code: 1`, while amd64 (native, no emulation)
succeeds.

Verify emulation actually works (not just "registered") before a runtime run:

```bash
# both should print the target machine, NOT "Exec format error"
nerdctl run --rm --platform linux/arm64  ubuntu:26.04 uname -m   # -> aarch64
nerdctl run --rm --platform linux/riscv64 ubuntu:26.04 uname -m  # -> riscv64
```

> `tonistiigi/binfmt`'s "OK" output means "a registration was written in my
> namespace", **not** "emulation works". Always confirm with the run test above — a
> `-d` container that returns an ID can still have exited immediately with `exec
> format error`.

#### Rootful hosts

On a rootful Docker/containerd host the standard
`docker run --privileged --rm tonistiigi/binfmt --install all` (or
`apt install qemu-user-static`) registers in the host `binfmt_misc` and works
directly, because containers there share the host (init) user namespace. The
rootless helper above is only needed when the daemon runs rootless.

The per-arch `latest-cross-base-*`, `latest-cross-package-*`, and `latest-cross-*`
tags are internal publish tags used to assemble the public `latest-cross` manifest.
Prefer the runtime helpers (see `AGENTS.md` § Runtime Helpers for the canonical commands).
Run with `--dry-run` to print the commands without building.

### Runtime helper scripts

Two helpers manage the `base → package → torch → wrapper → manifest` chain:

- **`build-runtime-manifest.sh`** — builds the full chain and publishes the multi-arch manifest.
- **`build-runtime-artifacts.sh`** — builds the chain and exports the final wrapper rootfs instead of creating a manifest.

Both accept `--target-arches`, `TARGET_ARCHES`, or `TARGET_ARCH` for architecture selection, and `ARTIFACT_BUILD_MODE=cross|native` for the package artifact source. In `cross` mode, `ARTIFACT_IMAGE_PREFIX` is a prefix (e.g. `ghcr.io/...:cross-android`) that fans out `-${TARGET_ARCH}`; in `native` mode it is the exact artifact image ref.

The riscv64 app wheelhouse is built on the amd64 host for `torch`, `torchvision`, and `opencv-python` git dependencies and carried through `/opt/wheels`. The final `linux/Dockerfile.torch` stage runs on the real target platform in both modes so `/opt/venv` is correct for the target architecture.

**Local handoff behavior:**
- When images stay local, `base` is exported as a plain rootfs directory, `package` and `torch` as OCI layouts consumed through named build contexts.
- `ARTIFACT_CONTEXT_ROOT` lets helpers consume previously saved artifacts from disk instead of pulling from a registry.
- `ARTIFACT_CONTEXT_MODE=oci` resolves each `<arch>` within `ARTIFACT_CONTEXT_ROOT` as `oci-layout://...` (verified path for `out/local-oci/android/{arm64,riscv64}`).
- One build still fails when consuming two named OCI contexts at once; the workaround is `runtime_artifact` as OCI layout + `runtime_base` as plain rootfs directory.
- Each local stage context is deleted after the downstream build consumes it.
- `--manifest-only` (alias `--repair`) creates/pushes the manifest without rebuilding images — the recommended way to repair `:latest-cross` from existing per-arch wrappers.

### Verified local foreign-architecture rebuild

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
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/
```

Previously validated for both `arm64` and `riscv64` (2026-08 runs, before the LLVM 23.1.0 bump): `gcc 16.2.0`, `clang 22.1.8`, `/usr/bin/cc → /etc/alternatives/cc → /opt/gcc-16.2.0/bin/gcc`, and optional runtime payloads under `/usr/local/lib/onnxruntime-*`, `/usr/local/include/tflite`, `/usr/local/include/tensorflow`, `/usr/local/lib/pkgconfig/litert.pc`.

After the runtime helper cleanup, validated for `amd64` with:

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
  --fast-ubuntu-ports-mirror-url http://ports.ubuntu.com/ubuntu-ports/
```

Result at the time (previously, on the LLVM 22 pin): `gcc 16.2.0`, `clang 22.1.8`, target `x86_64-unknown-linux-gnu`, `/usr/bin/cc → /etc/alternatives/cc → /opt/gcc-16.2.0/bin/gcc`, `/usr/bin/clang → /etc/alternatives/clang → /usr/local/llvm-target/bin/clang`.

### Local wrapper smoke validation

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
  --build-arg GCC_VERSION=16.2.0 \
  --build-arg LLVM_RELEASE=23.1.0 \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --build-arg FAST_UBUNTU_PORTS_MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports/ \
  . 2>&1 | tee ./out/build-logs/wrapper-smoke.log
```

## Centralized Version Management

All version numbers are now tracked in a single file: `linux/scripts/01-core/versions.env`. Update this file when bumping versions — do NOT scatter version changes across individual Dockerfiles.

`common.sh` and `artifact-common.sh` both source `versions.env` at load time with `set -a`, so all build scripts and orchestrators automatically receive canonical values. The per-Dockerfile ARG defaults are kept as safety nets and should match `versions.env`.

After bumping versions, run `python3 docs/scripts/sync_versions.py --write` to update the version snapshot in `README.md`.

### versions.env feature toggles (Linux lane)

Besides pins, `versions.env` carries **feature switches** for optional,
build-cost-heavy capabilities. They are probe-gated: turning one on never
hard-fails a build where the dependency is genuinely unavailable — the probe
falls back to disabled. Current toggles:

| Toggle | Effect | Notes |
|---|---|---|
| `FFMPEG_ENABLE_X265` | libx265 (HEVC) encoding in FFmpeg | Probe-gated; historically off because FFmpeg master could fail against bleeding-edge x265. |
| `FFMPEG_ENABLE_TF` | FFmpeg **TensorFlow** DNN backend (amd64 only) | **Default OFF** (2026-08-14). When off, the TF C SDK is never downloaded and ~500 MB of `libtensorflow*` never enters the image; the ONNX DNN backend stays always-on regardless. Set `=1` to restore it. |
| `ORT_ENABLE_WEBGPU` | ONNX Runtime WebGPU EP (Dawn) | Master switch; Dawn needs the GCC-16 `-Wno-invalid-constexpr` fix (2026-07-20). |
| `ORT_WEBGPU_ALLOW_CROSS` | Allow the WebGPU EP on cross arches | Dawn cross-build is the risky part; amd64-only unless set. |

**QNN EP (Qualcomm QAIRT SDK, backlog QNN-LINUX):** opt-in for the **arm64**
lane, targeting Snapdragon NPU. No environment toggle — staging a zip in
`linux/qnn-sdk/` is the switch. When a Linux AArch64 SDK zip is present,
`resolve_qnn_sdk` (shared module `01-core/qnn-sdk.sh`, loaded by
`media_common_init`) extracts it, verifies the SHA-256 against
`QNN_SDK_LINUX_ZIP_SHA256` in `versions.env` (if pinned), checks version
compat (`QNN_OP_STFT` canary), and each framework wires its own flag
(mirroring Windows #121): ORT `onnxruntime_USE_QNN=ON +
onnxruntime_QNN_HOME=<root> + QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` (ORT
CMake defaults to `aarch64-android` on Linux aarch64, overridable via `-D` —
it is a cache var guarded by `if(NOT QNN_ARCH_ABI)`). **ORT is the only framework
with a build-time QNN flag** — corrected 2026-08-31, see Windows backlog #154:
LiteRT's `TFLITE_ENABLE_QNN`, TVM's `USE_QNN` and IREE's
`IREE_TARGET_BACKEND_QNN` do not exist upstream, so CMake dropped all three
silently while the scripts logged success. LiteRT's real switch is
`LITERT_ENABLE_QUALCOMM`, auto-forced ON by `QAIRT_HEADERS_DIR=<root>/include/QNN`
(the dir holding `Qnn*.h` — [`qnn-linux.md`](qnn-linux.md) explains why the
include root does not work), which this lane now passes; TVM and IREE have no Qualcomm path at all.
Backend `.so` + `hexagon-v*` skel dirs are staged beside
each framework's install by `stage_qnn_runtime`. No zip = QNN off with a
notice. Different SDK from the Windows lane (`aarch64-oe-linux-gcc11.2/`,
not `aarch64-windows-msvc`). See `linux/qnn-sdk/README.md`.
**PROVEN 2026-08-30** on a staged QAIRT v2.49.0.260730 zip —
`cross-media-arm64` build GREEN, ORT provider wired (`build results in
`docs/refactoring-backlog.md` A2. QNN-LINUX). Framework fan-out to
GenAI/LiteRT/TVM/IREE is WIRED (same 2026-08-30 change), and the validation
build ran 2026-09-03 against a real v2.49.0.260730 staged on arm64 — see
[`qnn-linux.md`](qnn-linux.md), which owns the results and the
`QAIRT_HEADERS_DIR` defect that run exposed.

Because `versions.env` sits in the media build's cache-key closure, toggle
flips re-run the affected media compiles — batch them with planned pin bumps
(see `docs/refactoring-backlog.md`, standing rules). After a toggle flip, force
a fresh runtime wrapper build with **`RUNTIME_NO_CACHE=1`** (scoped to the
runtime package + wrapper; lighter than whole-chain `NO_CACHE=1`) so the shipped
image actually reflects the new media. The shipped **bytes** are now checked
automatically: `verify-shipped-wrapper.sh` runs in its own pass over every arch
and asserts the shipped `/opt/ffmpeg` lib set matches the versions.env toggles
(so `FFMPEG_ENABLE_TF=0` ⇒ `libtensorflow*` must be absent). Set
`WRAPPER_CONTENT_GATE=0` to downgrade that gate to advisory.

> **Why the explicit `RUNTIME_NO_CACHE`:** the runtime wrapper once shipped
> `:latest-cross` byte-identical five times because
> `nerdctl build --output type=image,name=X` never creates a local containerd
> tag on this rootless host, so push + manifest kept resolving a **stale** prior
> tag (root cause **RTCACHE3**; the earlier "registry cache-hit" theory,
> RTCACHE1, was a red herring). The fix switched `append_runtime_image_output`
> to plain `-t`; the byte gate above is the belt-and-suspenders check. Always
> verify shipped bytes, not just that the manifest pushed.

### TVM is pinned by COMMIT, not by tag

`TVM_REF=v0.26.0` is not what the build clones. `TVM_COMMIT` in `versions.env`
wins over the tag (`tvm.sh`'s `${TVM_COMMIT:-$ref}`) and is currently set,
because **TVM v0.26.0 does not compile against `LLVM_RELEASE=23.1.0`** — LLVM 23
dropped `TargetOptions::{NoInfsFPMath,NoNaNsFPMath}`, renamed
`SubtargetSubTypeKV::Key`/`SubtargetFeatureKV::Key` to `key()`, and changed
`getMCSubtargetInfo()` from pointer to reference, across three files. amd64
never hit it because it links the *distro* `llvm-config-21`; only the cross
lane links the chain's own LLVM.

Upstream `main` carries `TVM_LLVM_VERSION >= 230` guards for all of it and no
tagged release does, so the commit is pinned rather than the port reproduced. A
hand-written patch was tried first and removed: measured on a real arm64 build
it fixed four of five sites in one of the three files while logging success.

Two things follow, both proven on 2026-08-27:

* `RUNTIME_CONTEXT_KEEP_HOURS` (default 24) governs the orphaned-stage-context
  sweep — unrelated to TVM, but the other knob added the same day.
* Setting `TVM_COMMIT` for the first time exposed that the SHA clone path never
  initialised submodules: it clones **without** `--recursive` and the submodule
  update only fired when the checkout MOVED `HEAD`. Pinning the default-branch
  HEAD moves nothing, so CMake died on an empty `3rdparty/tvm-ffi`. Fixed.

Drop `TVM_COMMIT` back to empty the moment a TVM release ships the guards.

### Operational env knobs (not versions.env)

Runtime/orchestration switches that are **not** pins or feature toggles. The
cache-related ones are only half the story — what each cache tier covers, what
destroys it, and what replacing it costs is in
[`docs/build-cache-tiers.md`](build-cache-tiers.md):

| Knob | Effect |
|---|---|
| `NO_CACHE=1` | `--no-cache` across the whole chain. |
| `RUNTIME_NO_CACHE=1` | `--no-cache` on just the runtime package + wrapper builds (use after a media toggle flip). |
| `CROSS_NO_LOCAL_CACHE_EXPORT=1` | Write-only cache (skip the local cache export; disk relief on big rebuilds). |
| `NO_CACHE_EXPORT=1` | Drop everything registry-facing (inline cache export + registry cache reads). The manual recovery for the ghcr `DeadlineExceeded`/`httpReadSeeker` import flake — which the chain now also does by itself after two such failures. |
| `CROSS_REGISTRY_CACHE=max` | **DESIGN ONLY — setting it is a silent no-op.** The T4 pilot was declined and its implementation reverted; the `--cache-to type=registry` it describes no longer exists, and `verify-critical-fixes.sh` actively forbids the dead `<tag>-buildcache` ref from returning. Kept as a row only so the name resolves to its history — see [`build-cache-tiers.md` § 4](build-cache-tiers.md). |
| `WRAPPER_CONTENT_GATE=0` | Downgrade the shipped-wrapper byte gate to advisory. |
| `MEDIA_STRIP=0` | Disable the media-prefix symbol-strip pass (default on; ffmpeg/gstreamer/libcamera). |
| `VULKAN_CROSS_STRICT=1` | Promote the Vulkan cross-components gate (`vulkan.sh`) from advisory WARN to fatal. It fires when all three cross-components — loader/SPIRV-Tools/glslang — failed, an env-shaped toolchain cause. |
| `CROSS_GCC_TOOLCHAIN_PATH` | GCC root that `export_clang_gcc_toolchain_env` (`01-core/cross-gcc.sh`) points clang at via `--gcc-toolchain`; defaults to `gcc_toolchain_prefix` (`/opt/gcc-$GCC_VERSION`). Renamed 2026-09-04 from `MYPROJECT_GCC_TOOLCHAIN_PATH`, a template leftover — the old name is no longer read anywhere, so an operator still exporting it silently gets the default. **Reviewed 2026-09-04 and the knob currently changes nothing:** `export_clang_gcc_toolchain_env` has no caller in the build, and the one place clang IS the compiler — the `clang-<arch>`/`clang++-<arch>` wrappers `install_cross_clang_wrappers` writes (`02-toolchain/llvm.sh`) — bakes `--gcc-toolchain=<prefix>` into its own `exec` line from the same `gcc_toolchain_prefix`, so this knob is not what points those at the GCC. Note the two disagree on the missing-prefix case: the wrapper falls back to `/usr`, the function warns and exports nothing. See `refactoring-backlog.md` CL3 before wiring or deleting either. |
| `WHEEL_SOABI_STRICT=1` | Promote the vendored-wheel SOABI gate (`verify-wheels.sh`) from advisory WARN to fatal. It fires when a vendored wheel's native `.cpython-*.so` carries a SOABI for a different arch than the target triple — a host-SOABI leak that only fails at `import`. The triple is derived from `TARGET_ARCH`, not the running interpreter. |

### IREE (Linux lane)

IREE (`IREE_VERSION` in versions.env, currently v3.11.0) ships 3-arch in the
media image since 2026-07-14, with a deliberately split strategy per arch.

No arch installs an upstream wheel: PyPI ships `iree-base-{compiler,runtime}`
as `cp312-abi3` for x86_64+aarch64 only, riscv64 has none, and we need
version-specific `cp314` everywhere — so every arch source-builds
(`build-app-wheelhouse.sh:744-749`). What differs is *which* wheels come out:

- **amd64** — NATIVE build (target arch == build arch), `IREE_BUILD_COMPILER=ON`
  (`build-app-wheelhouse.sh:1183`): ships **both** `iree_base_compiler` and
  `iree_base_runtime`.
- **arm64 / riscv64** — CROSS build, **RUNTIME-ONLY**
  (`-DIREE_BUILD_COMPILER=${IREE_CROSS_BUILD_COMPILER:-OFF}`,
  `build-app-wheelhouse.sh:1140`), so only `iree_base_runtime` ships. This is
  not a preference: IREE imports host tools only under
  `if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)`, so `COMPILER=ON` makes
  the target ignore `IREE_HOST_BIN_DIR`, build its own `iree-tblgen` **for the
  target arch**, and then run it on the amd64 host — `Exec format error`,
  `[code=126]` on `VMOpEncoder.cpp.inc` (`build-app-wheelhouse.sh:1055-1074`).
  Set `IREE_CROSS_BUILD_COMPILER=ON` to re-try both wheels once IREE supports
  the combination. Models are compiled on amd64 and *executed* on the cross
  arches.

The cross path's companion **host** stage (amd64 has none — one cmake
configure does everything) supplies `iree-c-embed-data`, `iree-flatcc-cli`
and `iree-tblgen` via `IREE_HOST_BIN_DIR`. It probes `IREE_BUILD_COMPILER=OFF`
first and escalates to `ON` (the full-LLVM compile you see in the
`app-wheelhouse` stage) only when a required tool is missing
(`build-app-wheelhouse.sh:975-1026`).

Build home: `linux/scripts/05-frameworks/torch/build-app-wheelhouse.sh`
(`build_iree_wheels`), which stages host tools + target runtime and is smoked
both natively and via the Python import path. The riscv64 builder iterates on
real rebuilds — treat first-failure there as expected tuning, not regression.

### verify-parity.sh (on-demand diagnostic, not a gate)

`06-packaging/verify-parity.sh <native-image> <cross-image>` diffs two BUILT
images across `packages,python,versions,files,libs,imports`. It needs two
images, so it can never be a preflight gate (preflight's `artifact-parity`
slug is the UNRELATED `verify-artifact-copy-parity.sh`). Use it when a cross
image misbehaves where the native one doesn't — it localizes the divergence
in minutes.

## Five Critical Fixes To Maintain

To prevent regressions during updates, always preserve the following five vital fixes in the Linux cross pipeline:

1. **Fix 1 (gst-python staged libpython):** In `build_python.sh`, `python_stage_finalize()` runs `fix_python_pc_file()` over the staged `python-<mm>.pc` and `-embed.pc` so their `libdir`/`includedir` point at the compiler's cross directory, and symlinks `python3.pc` to them, so `gst-python` builds succeed.
2. **Fix 2 (libcamera abseil):** In `build-litert.sh`, the build must copy the required Abseil header `absl/types/span.h` into the LiteRT installation directory to prevent downstream `libcamera` build errors.
3. **Fix 3 (cross lib-dynload dangling symlinks):** In `build_python.sh` (`build_cross_target_python_payload()`), standard CPython build steps create standard cross-build library symlinks that end up dangling when packaged. We use `cp -a -L` to dereference those symlinks, copy the safety-net Modules, and enforce a hard-fail guard `find ... -xtype l` to ensure absolutely zero dangling symlinks remain in the target's `lib-dynload` subdirectory. This prevents C-extension import failures (e.g. `import _struct` failing under QEMU/binfmt). Since target-packaged Python is staged into the compiler-cross image, the compiler itself must be rebuilt if this helper logic is changed.
4. **Fix 4 (cross GCC architecture guard):** In `Dockerfile.package`, GCC alternatives wire `/opt/gcc-16.2.0/bin/gcc` as `cc`/`c++`. On `amd64`, GCC is built natively. On `arm64`/`riscv64`, it is Canadian-cross-compiled; `Dockerfile.android` swaps the amd64-hosted GCC for the target-native binary. The build hard-fails with three layered guards: (a) `cc -dumpmachine` must match `TARGET_ARCH`; (b) `readelf -h` on the `cc` binary itself checks ELF machine type (the real discriminator — `-dumpmachine` only reports the *target* triple, not the host arch); and (c) a cc1 compile-to-object smoke plus ELF check on the produced object, run under the target platform (QEMU for foreign arches). `wrapper-smoke` (Dockerfile.package target) runs validate-compilers.sh, smoke-media.sh, smoke-torch-venv.sh and smoke-cross-all-arches.sh for end-to-end verification.
5. **Fix 5 (OpenCV 5 GStreamer compat):** `patch-gstreamer-sources.sh` → `patch_gstreamer_sources()` patches the GStreamer `gst-plugins-bad` opencv plugin sources at build time for OpenCV 5.x compatibility. Three API changes are handled: (a) `contourArea`/`approxPolyDP`/`convexHull` moved to new `geometry` module → adds `#include <opencv2/geometry.hpp>` to `gstsegmentation.cpp`; (b) chessboard/circles-grid detection (`findChessboardCorners`/`findCirclesGrid`/`CALIB_CB_*`) moved to `objdetect` module → adds `#include <opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`; (c) `cv::CascadeClassifier` removed from OpenCV 5 → drops the three cascade-dependent GStreamer elements (`faceblur`, `facedetect`, `handdetect`) from the monolithic `libgstopencv.so`. Additionally, `build-opencv.sh` creates an `opencv4.pc` → `opencv5.pc` compatibility alias because GStreamer's meson dependency lookup queries `dependency('opencv4')`. All patches are idempotent (guarded with grep before applying). When changing OpenCV or GStreamer versions, verify the patch still applies correctly.

## Cross env contract

The cross environment set up by `linux/scripts/01-core/cross-env.sh`
(`setup_linux_cross_env`) is organized in three tiers. Run
`linux/scripts/01-core/cross-env-doctor.sh <arch>` (or source it and call
`cross_env_doctor`) to validate the contract, print the effective
configuration, and compile-smoke-check that `$CC` really emits target-arch
ELF objects.

### Tier 1 — core toolchain contract

Always exported when a cross build is active: `TARGET_ARCH`, `TARGETARCH`,
`TARGETPLATFORM`, `BUILDARCH`, `CROSS_TARGET_TRIPLET`, and the tool variables
`CC`, `CXX`, `AR`, `AS`, `LD`, `NM`, `RANLIB`, `STRIP`, `OBJCOPY`, plus
`PKG_CONFIG_LIBDIR`, `PKG_CONFIG_SYSROOT_DIR`, `PKG_CONFIG_ALLOW_CROSS`.
`CC`/`CXX` must be absolute paths to existing executables. Consumers must use
these variables — never bare `cc`/`gcc` from PATH — for target-side compiles.

### Tier 2 — rust / cmake derivations

Derived from Tier 1: `CROSS_RUST_TARGET`, `CARGO_BUILD_TARGET`,
`CARGO_TARGET_DIR`, `CARGO_TARGET_<TRIPLE>_LINKER` / `_AR`, the cc-crate vars
`CC_<triple>` / `CXX_<triple>` / `AR_<triple>` / `RANLIB_<triple>` (for both
target and build triples), and the `CMAKE_*` toolchain variables
(`CMAKE_SYSTEM_NAME/PROCESSOR`, `CMAKE_C/CXX_COMPILER`, `CMAKE_AR`,
`CMAKE_RANLIB`, `CMAKE_FIND_ROOT_PATH_MODE_*`, ...).

### Tier 3 — PATH policy and bare tool names (opt-in)

`/opt/cross-bin` is prepended to PATH but contains **only triplet-prefixed**
tool names (`<triplet>-gcc`, `<triplet>-ld`, ...), which can never shadow the
host toolchain. Bare names (`gcc`, `cc`, `as`, `ld`, ...) live in
`/opt/cross-bin/bare`, which is deliberately **not** on PATH — bare cross
names fronting PATH historically broke every host-side compile (e.g. the
riscv64 host-protoc "Exec format error" bug). The few consumers that
genuinely need bare names (gcc `-B` tool lookup, rust cc-crate fallbacks)
opt in per scope via `cross_bare_bin_path()`:

```bash
bare="$(cross_bare_bin_path)" && exec "${CC}" -B"${bare}/" "$@"
```

### Android SDK environment in the runtime image

`Dockerfile.package` COPYs `/opt/android-sdk` unconditionally, so the tree is in
**all three** shipped `:latest-cross-<arch>` images — measured 2026-09-04, 3.6 GB
and byte-identical on amd64/arm64/riscv64, with `build-tools/36.0.0`,
`cmdline-tools/latest`, `licenses`, `ndk/29.0.14206865`, `platforms/android-36`
and `platform-tools` all present. Nothing advertised it until then, so
`flutter build apk` stopped at `[!] No Android SDK found`; under CodeQL's
`database create --command=…` that exit aborts before the database is finalized
and the lane finally reports a missing bundle directory, three steps from the
cause. The image now sets:

| variable | value | true on |
| --- | --- | --- |
| `ANDROID_HOME` | `/opt/android-sdk` | all three arches |
| `ANDROID_SDK_ROOT` | `/opt/android-sdk` | all three arches |

`PATH` gains `${ANDROID_HOME}/cmdline-tools/latest/bin` and
`${ANDROID_HOME}/platform-tools`, **appended**, where `Dockerfile.android`
prepends. Appending is the whole non-shadowing argument: `platform-tools` ships
its own `mke2fs`, `make_f2fs` and `sqlite3`, and fronting `PATH` with it would
put an x86-64 `mke2fs` ahead of `/usr/sbin/mke2fs` on every arch. Appended,
those directories can only win names nothing else provides — `adb`, `sdkmanager`,
`avdmanager`, `apkanalyzer`, none of which were on `PATH` before. `build-tools`
is deliberately left off: it carries a renderscript-era `lld` that would shadow
`/usr/bin/lld` on a compiler image. Gradle and AGP find build-tools and the NDK
under `$ANDROID_HOME` without help. Measured on all three shipped images with the
new value injected: `mke2fs` still resolves to `/usr/sbin/mke2fs` and `lld` to
`/usr/bin/lld`, while `adb`, `sdkmanager`, `avdmanager` and `apkanalyzer` resolve
for the first time. The one other new name is `sqlite3`, which nothing on `PATH`
provided before and which — like `adb` — only executes in the amd64 image.

**The SDK's host tooling is `linux-x86_64` only, on every arch.** `adb`,
`fastboot`, `aapt2` and `zipalign` are x86-64 ELF and the NDK's only prebuilt
toolchain is `linux-x86_64`, so on arm64/riscv64 they are data, not programs
(`adb` there exits `cannot execute: required file not found`). That is upstream's
shape, not a packaging defect, and it is why `/opt/android-sdk` is already an
`_RT_TREE_ARCH_EXEMPT` tree —
[`artifact-copy-completeness.md`](artifact-copy-completeness.md#what-is-exempt-and-why-the-arm-names-the-tree).
Build Android artifacts from the amd64 image.

**No JDK ships in any arch.** `java`, `javac` and `keytool` are absent and
`/usr/lib/jvm` does not exist, so the SDK's Java wrappers (`sdkmanager`,
`avdmanager`, `apkanalyzer`, `d8`, `apksigner`) and `flutter build apk` still
need one supplied by the consumer. Setting `ANDROID_HOME` is necessary, not
sufficient.

The built image is asserted by `smoke-runtime-image.sh`'s `android-home`
consumer-contract row; that the Dockerfile ever sets it, and appends rather than
fronts, is asserted by `tests/test-dockerfile-env-order.sh`.

### Cross Python wheels (setuptools knobs)

A hand-rolled `setup.py bdist_wheel` cross-builds correctly only when these are
set — setuptools itself reads them
(`setuptools/_distutils/compilers/C/unix.py` `configure_system`,
`setuptools/command/build_ext.py` `get_ext_filename`). Users:
`03-media/build/pyav/build-pyav.sh`,
`05-frameworks/torch/build-app-wheelhouse.sh`,
`03-media/build/onnxruntime/build/60-build-genai.sh`.

### onnxruntime-genai on riscv64 (GEN1, 2026-08-31)

> **Full reference:** [`gen1-riscv64-genai.md`](gen1-riscv64-genai.md) — the
> patch, the toggle wiring, the smoke tiers, the first-build watch list, and
> what is MEASURED versus REASONED. This section is the summary.

The riscv64 cross lane BUILDS `onnxruntime-genai` from source. Upstream ships
no riscv64 wheel, runs no riscv64 CI, and closed its one RISC-V field report
([onnxruntime-genai#594](https://github.com/microsoft/onnxruntime-genai/issues/594),
Phi-3 int4 emitting nonsense on a XuanTie C910) as not-planned — so this is a
self-build. **Validated 2026-09-03**: it builds, and `generate()` on the
shipped image emits ids identical to an amd64 control, so #594 does not
reproduce here — [`gen1-riscv64-genai.md`](gen1-riscv64-genai.md).

* **Toggle:** `GENAI_ALLOW_RISCV64` (`versions.env`, default `true`;
  `Dockerfile.media` ARG → ENV on the `onnxruntime` stage). Anything but
  `true` restores the pre-GEN1 behaviour exactly: `60-build-genai.sh` creates
  a placeholder output tree and exits 0, and `verify-media-artifacts.sh` SKIPs
  the genai stage in agreement. Deliberately riscv64-scoped — `BUILD_GENAI` is
  the all-arch master switch and would take amd64/arm64 down with it.
* **Upstream patch:** `linux/scripts/patches/onnxruntime-genai/001-riscv64-target-platform.patch`
  adds a `riscv64` arm to `cmake/target_platform.cmake`, whose Linux branch
  otherwise `FATAL_ERROR`s at configure time on an unknown
  `CMAKE_SYSTEM_PROCESSOR`. The variable it sets (`genai_target_platform`) is
  read only by MSVC/WinML/Java code, so the patch is inert on this lane apart
  from removing the abort. Applied only when `ARCH=riscv64`.
* **`--use_guidance` stays ON** (llguidance via Corrosion —
  `riscv64gc-unknown-linux-gnu` is a rustc Tier-2-with-host-tools target and
  `install-rust.sh` adds its std for every `CROSS_TARGETS` arch). A
  riscv64-only preflight drops the flag if `rustup target list --installed`
  positively lacks the triple, so a missing std warns instead of aborting a
  multi-hour stage.
* **Performance note:** ORT v1.29's riscv64 MLAS uses the SCALAR reference
  kernels — the RVV ones need `onnxruntime_USE_RVV` plus an `rv64gcv` compile
  probe, neither of which this repo sets. Expect generation to be slow.
* **Gates:** the producer's own cross wheel check (`assert_elf_arch` over every
  `.so` in the wheel + the target `EXT_SUFFIX` assert),
  `verify-media-artifacts.sh onnxruntime-genai`, `smoke-torch-venv.sh`'s pin
  assertion (riscv64 absence is now a FAILURE unless the toggle is off), the
  ARCH-PARITY table (its `riscv64:onnxruntime_genai` exemption is deleted), and
  `smoke-runtime-image.sh`'s `check_genai_binding`.

| Variable | Why it is load-bearing |
| --- | --- |
| `CC` | Replaces the interpreter's compiler. May be multi-word (`ccache <cross-gcc>`) — `set_executables` shlex-splits it. |
| `LDSHARED` | Explicit `<cross-gcc> -shared`. Without it the link command is derived from the **host** interpreter's sysconfig. |
| `CFLAGS` | **Replaces** (does not append to) the sysconfig CFLAGS, and lands *before* the extension's own `-I` dirs — which is what makes the TARGET Python headers win over the host ones `build_ext` always appends. Must carry `-O2` itself, since the sysconfig optimisation flags are replaced with it. |
| `SETUPTOOLS_EXT_SUFFIX` | The target SOABI suffix. Without it extensions are named `.cpython-<mm>-x86_64-linux-gnu.so`, which the target interpreter never even considers at import time (`importlib` `EXTENSION_SUFFIXES`) — the wheel installs and the `import` dies. `runtime/verify-wheels.sh` asserts the suffix. |
| `_PYTHON_HOST_PLATFORM` | Makes `get_platform()`, and hence the wheel platform tag, the target one — so the wheel is born correctly tagged and `runtime/repair-wheels.sh`'s blanket retag is only a safety net. |

## Runtime lane helper commands

Building and publishing the per-arch wrappers and the multi-arch manifest, plus manifest repair. The canonical chain commands are in [`../AGENTS.md`](../AGENTS.md) § Quick Reference; these are the runtime-lane half.

```bash
# Build and push per-arch wrappers + manifest
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --push

# Build local artifacts only (no push)
bash linux/scripts/build-runtime-artifacts.sh \
  --image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64

# Dry-run: print what would be built without executing
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --dry-run

# Manifest repair (rebuild manifest from existing per-arch wrappers)
nerdctl manifest rm "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64"
nerdctl manifest push --purge "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"

# Or use the helper: rebuild just the manifest (no image rebuilds)
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --manifest-only --push-manifest

# Shorthand: --repair is an alias for --manifest-only
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --repair --push-manifest
```

## Orchestrator stage selection

Resuming mid-chain, building one stage, and the parallel-arch knobs.

```bash
# Resume mid-chain (e.g., after rebuilding compiler)
bash linux/scripts/build-cross-chain.sh --from-stage sdk --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Build only one stage for one architecture
bash linux/scripts/build-cross-chain.sh --only media --target-arches arm64 --log-dir ./out/build-logs

# Build per-arch stages in parallel (faster on multi-core machines).
# PAR4 (VALIDATED through wave-4, 2026-08-21): cross_build_mem_divisor
# multiplies the arch count by PAR_INTRA_STEP_BUDGET (default 2) for
# PER-ARCH stages, and uses divisor 1 for SHARED stages (base/compiler run
# alone — the ×budget throttled the compiler to 1/3 jobs once). Across ~12
# parallel media rounds: ONE isolated OOM kill, absorbed by retries. If a
# lane OOMs repeatedly raise PAR_INTRA_STEP_BUDGET=3 or use
# PARALLEL_STAGES=sdk,android. Details: docs/build-parallelism-memory-tuning.md.
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --parallel-archs --log-dir ./out/build-logs

# Build a single cross stage standalone (with digest-pinned parent when --push)
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
```
