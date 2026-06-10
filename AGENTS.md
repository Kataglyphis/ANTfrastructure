# Kataglyphis-ContainerHub

## Start Here

CRITICAL: For any task that touches Linux image builds, runtime packaging, or publish flows, read these files first with the Read tool:

- `docs/linux-cross-builds.md`
- `docs/linux-build-basics.md`
- `docs/project-info.md`

For runtime helper changes, also read:

- `linux/scripts/01-core/artifact-common.sh`
- `linux/scripts/build-runtime-artifacts.sh`
- `linux/scripts/build-runtime-manifest.sh`

These files document host-specific workarounds that are easy to regress if you improvise.

## Quick Reference

Most common build commands — prefer these over ad hoc `nerdctl build`:

```bash
# Full cross-build chain (base → compiler → sdk → media → android → runtime)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64

# Compiler image only (amd64-hosted, contains cross toolchains for all arches)
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64

# Verify chain freshness without building
bash linux/scripts/build-cross-chain.sh --verify-chain

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot
sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
```

## Two Build Lanes

This project has two distinct build paths, both must be kept working:

- **QEMU/binfmt lane:** `nerdctl build --platform linux/{arm64,riscv64}` runs foreign-arch containers via QEMU emulation. Used for native-arch runtime packaging.
- **Cross-build lane:** Everything compiles on `linux/amd64` using cross-compilers. Produces the `:cross-*` tagged images. The orchestrator `build-cross-chain.sh` drives this lane.

## Repo Map

- `linux/`: Linux Dockerfiles for base, toolchain, SDK, media, Android, package, Torch, and runtime-common images. `Dockerfile.torch` is the final wrapper (includes runtime scripts + entrypoint) and the canonical source for shared final-stage elements (entrypoint, labels, runtime scripts). `Dockerfile.runtime-common` is a documentation-only reference.
- `linux/scripts/`: helper scripts for cross-compiler, SDK artifacts, runtime artifacts, and runtime manifest publishing.
- `docs/`: the canonical build and troubleshooting instructions.
- `windows/`: Windows container images.
- `out/`: generated build artifacts (OCI layouts, rootfs exports). Subdirectories: `out/local-oci/android/<arch>`, `out/linux-sdk/<arch>`, `out/linux-runtime/<arch>`. Excluded from Docker build context via `.dockerignore`.
- `docs/scripts/sync_versions.py`: keeps the source-controlled version snapshot in `README.md` aligned with the Dockerfiles and setup scripts.

## Code Organization

Key shared utilities and where to find them:

- **Architecture resolution:** `platform.sh` provides `canonical_target_arch()` and `canonical_resolve_arch()` as the single source of truth for target architecture resolution. All scripts should use these instead of ad-hoc `dpkg` / `uname -m` chains.
- **Module loading:** `modules.sh` provides `source_modules_framework()` for the standard "find modules.sh in repo or container layout" bootstrap pattern. Call it after sourcing `modules.sh`.
- **CC validation:** `validate-compilers.sh` provides `_validate_cc_target()` which centralizes the dumpmachine/ELF/cc1-compile-to-object/link smoke checks used by both `validate_package()` and `validate_smoke()`.
- **Cross-chain tags:** `artifact-common.sh` provides `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()` for consistent tag naming across orchestrators and helpers.
- **Retry logic:** `logging.sh` provides `retry <max_attempts> <sleep_sec> <description> <command...>` for standardized retry loops.
- **Mirror args:** `artifact-common.sh` provides `append_mirror_build_args_from_env()` to DRY the mirror argument fallback chain. Use this instead of repeating the `USE_FAST_UBUNTU_MIRROR` / `FAST_UBUNTU_MIRROR_URL` / `FAST_UBUNTU_PORTS_MIRROR_URL` expansion.
- **Download checksums:** SHA256 checksums for Node.js and uv downloads live in `versions.env` (`NODE_AMD64_SHA256`, `NODE_ARM64_SHA256`, `UV_AMD64_SHA256`, `UV_ARM64_SHA256`, `UV_RISCV64_SHA256`).
- **Runtime stage elements:** `linux/Dockerfile.torch` final stage is the canonical source for the COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, and OCI labels. `Dockerfile.runtime-common` exists as a documentation-only reference and is not consumed by any build.
- **Artifact COPY list:** In `Dockerfile.package`, the `artifact-source-local` and `package-image` stages carry comments marking the canonical artifact COPY list that must be kept consistent. Run `linux/scripts/verify-artifact-copy-parity.sh` to check.
- **Orchestrator stale-check:** `build-cross-chain.sh --verify-chain` resolves all upstream registry digests and reports whether downstream images may be stale, without performing any builds.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper with `BUILDKIT_HOST` support. Use it instead of ad hoc `nerdctl build` command assembly.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl` and `ctr` commonly fail here with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working. Do not break one to fix the other.
- `linux/scripts/build-cross-compiler.sh` builds one `linux/amd64` compiler image that contains cross toolchains for `amd64`, `arm64`, and `riscv64`. It is not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features just to make foreign-arch builds pass. Foreign-architecture runtime images must keep source-built `clang 22.1.6` and must not fall back to the Ubuntu `clang 22.1.2` packages. The source-built `gcc 16.1.0` at `/opt/gcc-16.1.0` is the default system `cc`/`c++` compiler on all architectures. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) using the cross-compiler built in the same toolchain image; the resulting native GCC is swapped into `/opt/gcc-16.1.0` at the end of the Android stage via `Dockerfile.android`.
- Preserve the optional runtime payloads and LLVM normalization in `linux/Dockerfile.package`. Do not silently drop the `/usr/local/lib/onnxruntime-*` (includes `onnxruntime-cpu`, `onnxruntime-gpu`, `onnxruntime-genai`), LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage's next stage does `FROM ${BASE_IMAGE}`: `base -> compiler -> sdk -> media
-> android -> package -> torch -> wrapper -> manifest`. The base-image handoff
between these stages MUST NOT rely on a bare mutable tag, or a stage can silently
consume a STALE locally-cached image instead of the one just built. Concretely:
`--output type=image,name=...,push=true` pushes the new digest to the registry
but does not reliably refresh the local containerd tag, and BuildKit's default
`FROM` resolution prefers an already-present local image (it does not re-pull).
So rebuilding `media` then building `android` can quietly reuse the old `media`.

### Stale-base propagation across orchestrator invocations (critical)

The orchestrator's digest pinning prevents intra-invocation drift (media->android
within the same run), but **across separate orchestrator invocations** the digest
of a tag may point to a newer image while downstream images still inherit from an
older digest that was built from a previous version of that tag.

For a detailed walkthrough of how this manifests, see `docs/linux-cross-builds.md`
§ "Trap: stale-base propagation across orchestrator invocations".

Rules:

1. **Whenever ANY base image in the registry tag hierarchy is replaced,** you MUST
   either (a) rebuild every downstream image starting from the replaced stage, or
   (b) explicitly verify that the downstream images were already rebuilt from the
   new base by checking they contain the new content (e.g. verify
   `/opt/gcc-16.1.0-native-arm64` exists in the pinned sdk digest).
2. **The `--from-stage` flag only controls where execution starts; it does NOT
   update the base image of the first stage it runs.** If the existing registry
   tag for the stage BEFORE your `--from-stage` was built from a stale upstream,
   your rebuild inherits that staleness.
3. **After pushing a rebuilt compiler image**, run the orchestrator from
   `--from-stage sdk` (not `media`) so the sdk is built from the new compiler
   before media inherits it.
4. **Do NOT use `--from-stage android`** unless you have verified the media tag
   already contains the content the compiler provides (e.g., the native GCC
   directories).
5. To run the full cross chain, prefer the orchestrator `linux/scripts/build-cross-chain.sh`.
   It captures each cross stage's registry-resolvable manifest digest after push and
   feeds it to the next stage as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`,
   so stale reuse is structurally impossible. It supports `--target-arches`,
   `--from-stage`, `--to-stage`, and `--only` for partial/per-arch runs.
6. When you must drive the manual `nerdctl` cross loops instead, pass `--pull=true`
   on every stage that consumes a `BASE_IMAGE` tag so it re-pulls the freshly
   pushed base. This is the weaker defense; digest pinning is preferred.
7. Capture pinnable digests with `nerdctl manifest inspect --verbose <tag>` ->
   `.Descriptor.digest` (the `registry_pin_ref` helper in
   `linux/scripts/01-core/artifact-common.sh`). Do NOT use the local image store's
   `RepoDigests`: on this host BuildKit pushes a converted `docker.v2+json`
   manifest whose digest differs from the local OCI manifest, so `RepoDigests` is
   not registry-resolvable and will fail to pin.

## Verified Runtime Packaging Path On This Host

- Prefer helper scripts over ad hoc `nerdctl build` sequences (see Quick Reference above).
- The runtime helpers accept `--target-arches`, `TARGET_ARCHES`, and `TARGET_ARCH` for architecture selection.
- For local foreign-architecture runtime rebuilds, prefer saved OCI layouts under `out/local-oci/android/<arch>`.
- When reusing saved local artifacts, use:
  - `ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android"`
  - `ARTIFACT_CONTEXT_MODE=oci`
  - `RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts"`
- The working host workaround is mixed context types: keep `runtime_artifact` as an `oci-layout://...` build context and keep `runtime_base` as a plain rootfs directory context. Do not switch both named contexts to OCI in one build on this host.
- The repo-root `.dockerignore` excludes `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so large exported artifacts do not get sent back as later Docker build contexts.
- Prefer the saved OCI layouts over the plain directory exports in `out/local-android-dir/<arch>`. The plain directory path is much larger and previously dropped runtime payload during OCI-to-directory conversion.

## Five Critical Fixes To Maintain

Always preserve these five vital fixes to prevent build/runtime regressions.
Full implementation details are in `docs/linux-cross-builds.md` § "Five Critical Fixes".

### Fix 1 (gst-python staged libpython)

In `build_python.sh`, use `rewrite_staged_python_pc()` to rewrite the staged `python-3.14.pc` file's `libdir` and `includedir` to point correctly at the compiler's cross directory.

### Fix 2 (libcamera abseil)

In `build-litert.sh`, copy the required Abseil header `absl/types/span.h` into the LiteRT installation directory to prevent `libcamera` build errors.

### Fix 3 (cross lib-dynload dangling symlinks)

In `build_python.sh` (`build_cross_target_python_payload()`), use `cp -a -L` to dereference standard Python cross-build library symlinks, copy the safety-net Modules, and enforce a hard-fail guard `find ... -xtype l` to ensure absolutely zero dangling symlinks remain in the `lib-dynload` subdirectory. This prevents C-extension import failures (e.g. `import _struct` failing under QEMU/binfmt). Note that since this Python is packaged into the compiler cross image, the compiler itself must be rebuilt when modifying this python helper.

### Fix 4 (cross GCC architecture guard)

The build hard-fails if the runtime `cc` is the wrong architecture using three layered guards. The GCC alternatives in `Dockerfile.package` wire `/opt/gcc-16.1.0/bin/gcc` as the system `cc`/`c++` on all architectures — on `amd64` it is built natively, on `arm64`/`riscv64` it is cross-compiled from source (Canadian cross) and swapped via `swap-native-gcc.sh`.

The three guards:

- **(a) `cc -dumpmachine` must match `TARGET_ARCH`.** Verifies the reported target triple.
- **(b) ELF machine type of the `cc` binary via `readelf -h` must match the target.** This is the real discriminator — `-dumpmachine` reports the *target* triple and cannot tell a target-native compiler from a host-arch cross-compiler that targets the same triple.
- **(c) cc1 compile-to-object smoke test** (`cc -x c - -c -o`) plus an ELF-machine check on the produced object, run under the target platform (QEMU for foreign arch).

`Dockerfile.android` additionally asserts the ELF machine type of the swapped GCC right after the swap (in `swap-native-gcc.sh`). End-to-end verification uses the `wrapper-smoke` target via `smoke-wrapper.sh` -> `validate-compilers.sh`.

### Fix 5 (OpenCV 5 GStreamer compat)

`patch-gstreamer-sources.sh` -> `patch_gstreamer_opencv5_compat()` patches `gst-plugins-bad` for OpenCV 5.x:

- **(a)** `contourArea`/`approxPolyDP`/`convexHull` -> adds `#include <opencv2/geometry.hpp>` to `gstsegmentation.cpp`
- **(b)** `findChessboardCorners`/`findCirclesGrid`/`CALIB_CB_*` -> adds `#include <opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`
- **(c)** `cv::CascadeClassifier` removed from OpenCV 5 -> drops `faceblur`, `facedetect`, `handdetect` from `libgstopencv.so`

`build-opencv.sh` creates `opencv4.pc` -> `opencv5.pc` compatibility alias. All patches are idempotent (guarded with grep). When changing OpenCV/GStreamer versions, verify the patch still applies.

## Push And Publish Rules

- For the runtime helpers, `build-runtime-artifacts.sh --push` should push only the final per-architecture wrapper images.
- `build-runtime-manifest.sh --push` should push those final wrapper images plus the final manifest.
- Use `--push-all` only when the user explicitly wants the `base` and `package` intermediates published too.
- Final cross release target: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Final wrapper tags:
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64`
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64`
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64`
- Before rebuilding expensive foreign-architecture wrappers, inspect the remote tags with `nerdctl manifest inspect`. If the per-architecture wrapper images already exist remotely, recreate the final manifest directly instead of rebuilding them.
- The direct manifest repair flow is:

```bash
nerdctl manifest rm "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64"
nerdctl manifest push --purge "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"
nerdctl manifest inspect "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"
```

## Validation

- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs`, because absolute symlinks resolve against the host root.
- Confirm all of the following for runtime image validation:
  - `clang --version` reports `22.1.6` on all architectures
  - the reported target triple matches the architecture (`cc -dumpmachine`)
  - On all architectures: `gcc --version` reports `16.1.0`, and:
    - `/usr/bin/cc -> /etc/alternatives/cc -> /opt/gcc-16.1.0/bin/gcc`
    - `/usr/bin/c++ -> /etc/alternatives/c++ -> /opt/gcc-16.1.0/bin/g++`
    - `/usr/bin/gcc -> /etc/alternatives/gcc -> /opt/gcc-16.1.0/bin/gcc`
    - `/usr/bin/g++ -> /etc/alternatives/g++ -> /opt/gcc-16.1.0/bin/g++`
  - `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`
  - the optional runtime payloads are still present
  - See `validate-compilers.sh` for the shared `_validate_cc_target()` used by both the `package` hard-fail and `smoke` modes.
- Use the `wrapper-smoke` target (documented in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md`) for cheaper packaging validation before large publish runs.
- Current automated validation is documentation-focused. Do not claim there is already a single full end-to-end CI workflow.

## Host Constraints

- QEMU/binfmt works for `arm64` and `riscv64` on this host. It may need to be reinstalled after a host reboot. If foreign-architecture builds (or even simple `nerdctl run --platform linux/arm64 alpine uname -m`) fail with `exec format error`, run `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` in a terminal first before resuming the agentic session.
- Plain local image tags such as `docker.io/library/opencode-local:*` may be treated like remote registry references here. Do not rely on them as reusable `FROM` sources for the runtime packaging chain.
- Disk pressure is common during runtime rebuilds. When free space is tight, build and push one architecture at a time. To free space: `nerdctl system prune -a -f && rm -rf out/local-* out/linux-*`.
- `gh` may be unavailable on this host. Use `nerdctl` and regular git commands unless GitHub CLI is actually installed.
- Rootless BuildKit on this host is already tuned for fast build-time downloads. Do not regress these settings. Full details in `docs/project-info.md`.

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `exec format error` | QEMU/binfmt not registered after host reboot | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | Disk full from cached images/artifacts | `nerdctl system prune -a -f && rm -rf out/local-*` |
| Stale downstream images | Base image rebuilt but downstream not refreshed | Use `--verify-chain` or rebuild from replaced stage |
| `registry_pin_ref` fails on fresh push | Registry hasn't propagated the new manifest | Now uses `retry()` with 5 attempts; wait a few seconds and retry |
| Terminal freeze during long build | Build output overwhelms terminal | Use `setsid` / `disown` for very long builds |

## Version Bumping

When bumping dependency versions across the Linux Dockerfiles, follow this checklist:

### Centralized Version File

**The single source of truth for ALL versions is `linux/scripts/01-core/versions.env`.** Update it first, then verify the downstream consumers are in sync.

`common.sh` and `artifact-common.sh` both source `versions.env` at load time with `set -a`, so all build scripts automatically receive the canonical values. Orchestrator scripts inherit versions through `artifact-common.sh`. The old per-Dockerfile ARG defaults are kept as safety nets and should match `versions.env`.

### Version Map

| Software | Where defined |
|----------|---------------|
| **All Linux versions** | `linux/scripts/01-core/versions.env` (canonical) |
| **BuildKit syntax** | `# syntax=docker/dockerfile:VERSION` line 1 in every `linux/Dockerfile*` |
| **LLVM/Clang** | `versions.env` then forwarded by `Dockerfile.toolchain`, `Dockerfile.sdk`, `Dockerfile.package` |
| **GCC** | `versions.env` then forwarded by `Dockerfile.toolchain`, `Dockerfile.android`, `Dockerfile.package` |
| **Python** | `versions.env` then forwarded by `Dockerfile.toolchain`, `Dockerfile.package` |
| **CMake** | `versions.env` then forwarded by `Dockerfile.base` |
| **Node.js** | `versions.env` then forwarded by `Dockerfile.base` |
| **uv** | `versions.env` then forwarded by `Dockerfile.base` |
| **Vulkan SDK** | `versions.env` then forwarded by `Dockerfile.base`, `Dockerfile.sdk` |
| **ONNX Runtime** | `versions.env` then forwarded by `Dockerfile.media` |
| **ONNX Runtime GenAI** | `versions.env` then forwarded by `Dockerfile.media` |
| **LiteRT** | `versions.env` then forwarded by `Dockerfile.media` |
| **OpenCV** | `versions.env` then forwarded by `Dockerfile.media` |
| **GStreamer** | `versions.env` then forwarded by `Dockerfile.media`, `Dockerfile.package` |
| **CUDA** | `versions.env` then forwarded by `Dockerfile.nvidia` |
| **cuDNN** | `versions.env` then forwarded by `Dockerfile.nvidia` |
| **TensorRT** | `versions.env` then forwarded by `Dockerfile.nvidia` |
| **ROCm** | `versions.env` then forwarded by `Dockerfile.amd` |
| **Apache TVM** | `Dockerfile.sdk` only (ARG TVM_REF) |
| **Android SDK** | `versions.env` then forwarded by `Dockerfile.android`, `Dockerfile.package` |
| **Android NDK** | `versions.env` then forwarded by `Dockerfile.android`, `Dockerfile.package` |
| **Android Build Tools** | `versions.env` then forwarded by `Dockerfile.android`, `Dockerfile.package` |
| **Android CMake** | `versions.env` then forwarded by `Dockerfile.android`, `Dockerfile.package` |
| **Android SDK/API** | `versions.env` then forwarded by `Dockerfile.android`, `Dockerfile.package` |
| **Ubuntu** | `FROM ubuntu:...` in `Dockerfile.base` and `webserver/Dockerfile` |
| **Webserver Ubuntu** | `FROM ubuntu:...` in `linux/webserver/Dockerfile` |

### Version Verification Sources

Check these URLs for the latest versions:
- LLVM/Clang: `https://github.com/llvm/llvm-project/releases`
- Python: `https://www.python.org/downloads/`
- Node.js: `https://nodejs.org/en/download`
- CMake: `https://cmake.org/download/`
- uv: `https://github.com/astral-sh/uv/releases`
- Vulkan SDK: `https://vulkan.lunarg.com/sdk/home`
- ONNX Runtime: `https://github.com/microsoft/onnxruntime/releases`
- ONNX Runtime GenAI: `https://github.com/microsoft/onnxruntime-genai/releases`
- LiteRT: `https://github.com/google-ai-edge/LiteRT/releases`
- GStreamer: `https://gstreamer.freedesktop.org/releases/`
- CUDA: `https://developer.nvidia.com/cuda-toolkit-archive`
- ROCm: `https://repo.radeon.com/rocm/apt/` (browse directory listing)
- TVM: `https://github.com/apache/tvm/releases`
- Android SDK/NDK: `https://developer.android.com/studio#command-line-tools-only`
- Docker BuildKit: `https://github.com/moby/buildkit/releases`

### Post-Bump Steps

After changing any versions:
1. Run `python3 docs/scripts/sync_versions.py --check`. If it reports drift, run `--write`.
2. Update version references in `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, and `AGENTS.md`.
3. Update cross-file consistency: several versions appear in multiple Dockerfiles (e.g., GCC, Python, Android SDK, Vulkan, GStreamer). Make sure they stay in sync.

### Versions Tracked by sync_versions.py

The script extracts these versions for the README snapshot:
- `linux_ubuntu`: `FROM ubuntu:...` from `Dockerfile.base`
- `linux_cmake`: `ARG CMAKE_VERSION` from `Dockerfile.base`
- `linux_vulkan`: `ARG VULKAN_VERSION` from `Dockerfile.base`
- `linux_llvm`: major version from `common.sh`
- `linux_gcc`: major version from `common.sh`
- `android_sdk`, `android_ndk`, `android_cmake`: from `Dockerfile.android`
- `webserver_ubuntu`: `FROM ubuntu:...` from `webserver/Dockerfile`
- Windows versions are also tracked but are in `windows/` Dockerfiles.

### GPU Version Constraints

When bumping CUDA or ROCm, verify:
- CUDA: minimum driver requirement (check NVIDIA release notes)
- ROCm: the `UBUNTU_CODENAME` ARG in `Dockerfile.amd` must match a supported Ubuntu codename for that ROCm version. Default is `plucky` (26.04). The same codename variable is used in `Dockerfile.nvidia` for the CUDA keyring URL.
- Both: confirm the repo URL format (`repo.radeon.com/rocm/apt/${ROCM_VERSION}`) is still valid

## Documentation Maintenance

- If Dockerfiles or Linux build helpers change, update these docs in the same commit:
  - `docs/linux-cross-builds.md`
  - `docs/linux-build-basics.md`
  - `docs/project-info.md`
- If source-controlled version defaults change, run `python3 docs/scripts/sync_versions.py --write`.
- For verification-only checks, run `python3 docs/scripts/sync_versions.py --check`.
