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

## Repo Map

- `linux/`: Linux Dockerfiles for base, toolchain, SDK, media, Android, package, Torch, and wrapper images.
- `linux/scripts/`: helper scripts for cross-compiler, SDK artifacts, runtime artifacts, and runtime manifest publishing.
- `docs/`: the canonical build and troubleshooting instructions.
- `windows/`: Windows container images.
- `docs/scripts/sync_versions.py`: keeps the source-controlled version snapshot in `README.md` aligned with the Dockerfiles and setup scripts.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl` and `ctr` commonly fail here with permission errors.
- Keep the existing QEMU/binfmt multi-platform Linux lane working while extending the additive cross-build lane.
- `linux/scripts/build-cross-compiler.sh` builds one `linux/amd64` compiler image that contains cross toolchains for `amd64`, `arm64`, and `riscv64`. It is not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features just to make foreign-arch builds pass. Foreign-architecture runtime images must keep source-built `clang 22.1.6` and must not fall back to the Ubuntu `clang 22.1.2` packages. The source-built `gcc 16.1.0` at `/opt/gcc-16.1.0` is the default system `cc`/`c++` compiler on all architectures. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) using the cross-compiler built in the same toolchain image; the resulting native GCC is swapped into `/opt/gcc-16.1.0` at the end of the Android stage via `Dockerfile.android`.
- Preserve the optional runtime payloads and LLVM normalization in `linux/Dockerfile.package`. Do not silently drop the `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Verified Runtime Packaging Path On This Host

- Prefer helper scripts over ad hoc `nerdctl build` sequences:
  - `./linux/scripts/build-cross-compiler.sh`
  - `bash linux/scripts/build-runtime-artifacts.sh`
  - `bash linux/scripts/build-runtime-manifest.sh`
- The runtime helpers accept `--target-arches`, `TARGET_ARCHES`, and `TARGET_ARCH` for architecture selection.
- For local foreign-architecture runtime rebuilds, prefer saved OCI layouts under `out/local-oci/android/<arch>`.
- When reusing saved local artifacts, use:
  - `ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android"`
  - `ARTIFACT_CONTEXT_MODE=oci`
  - `RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts"`
- The working host workaround is mixed context types: keep `runtime_artifact` as an `oci-layout://...` build context and keep `runtime_base` as a plain rootfs directory context. Do not switch both named contexts to OCI in one build on this host.
- Keep `.dockerignore` excluding `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so large exported artifacts do not get sent back as later Docker build contexts.
- Prefer the saved OCI layouts over the plain directory exports in `out/local-android-dir/<arch>`. The plain directory path is much larger and previously dropped runtime payload during OCI-to-directory conversion.

## Four Critical Fixes To Maintain

Always preserve these four vital fixes to prevent build/runtime regressions:
1. **Fix 1 (gst-python staged libpython):** In `build_python.sh`, use `rewrite_staged_python_pc()` to rewrite the staged `python-3.14.pc` file's `libdir` and `includedir` to point correctly at the compiler's cross directory.
2. **Fix 2 (libcamera abseil):** In `build-litert.sh`, copy the required Abseil header `absl/types/span.h` into the LiteRT installation directory to prevent `libcamera` build errors.
3. **Fix 3 (cross lib-dynload dangling symlinks):** In `build_python.sh` (`build_cross_target_python_payload()`), use `cp -a -L` to dereference standard Python cross-build library symlinks, copy the safety-net Modules, and enforce a hard-fail guard `find ... -xtype l` to ensure absolutely zero dangling symlinks remain in the `lib-dynload` subdirectory. This prevents C-extension import failures (e.g. `import _struct` failing under QEMU/binfmt). Note that since this Python is packaged into the compiler cross image, the compiler itself must be rebuilt when modifying this python helper.
4. **Fix 4 (cross GCC architecture guard):** In `Dockerfile.package`, the GCC alternatives registration wires `/opt/gcc-16.1.0/bin/gcc` as the system `cc`/`c++` on all architectures. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) using the cross-compiler built in the same toolchain image; `Dockerfile.android` swaps the amd64-hosted GCC for the target-native GCC at the end of the Android stage. The build validates `cc -dumpmachine` against `TARGET_ARCH` as a hard-fail guard to prevent an amd64 `cc` from leaking into foreign-arch runtime images. The `wrapper-smoke` target uses `linux/scripts/06-packaging/smoke-wrapper.sh` for end-to-end verification.

## Push And Publish Rules

- For the runtime helpers, `build-runtime-artifacts.sh --push` should push only the final per-architecture wrapper images.
- `build-runtime-manifest.sh --push` should push those final wrapper images plus the final manifest.
- Use `--push-all` only when the user explicitly wants the `base`, `package`, and `torch` intermediates published too.
- Final cross release target: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Final wrapper tags are:
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
  - The build-time validation in `Dockerfile.package` verifies `cc -dumpmachine` matches `TARGET_ARCH` and fails the build if it does not
- Use the checked-in `wrapper-smoke` target documented in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md` for cheaper packaging validation before large publish runs. The smoke verification logic lives in `linux/scripts/06-packaging/smoke-wrapper.sh`.
- Current automated validation is documentation-focused. Do not claim there is already a single full end-to-end CI workflow that builds every Linux, accelerator, and Windows image variant on each change.

## Host Constraints

- QEMU/binfmt works for `arm64` and `riscv64` on this host. It may need to be reinstalled after a host reboot. If foreign-architecture builds (or even simple `nerdctl run --platform linux/arm64 alpine uname -m`) fail with `exec format error`, run `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` in a terminal first before resuming the agentic session.
- Plain local image tags such as `docker.io/library/opencode-local:*` may be treated like remote registry references here. Do not rely on them as reusable `FROM` sources for the runtime packaging chain.
- Disk pressure is common during runtime rebuilds. When free space is tight, build and push one architecture at a time.
- `gh` may be unavailable on this host. Use `nerdctl` and regular git commands unless GitHub CLI is actually installed.
- Rootless BuildKit on this host is already tuned for fast build-time downloads. Do not regress these settings:
  - `~/.config/systemd/user/buildkit.service.d/override.conf` runs `buildkitd` with `--oci-worker-net=host --allow-insecure-entitlement network.host`. This makes every `RUN` step (e.g. the LLVM `git fetch` in `linux/scripts/02-toolchain/build-clang.sh`) use host networking instead of the slow rootless bridge/slirp path. With this in place, plain `nerdctl build` already uses host networking; you do not need `--network host`.
  - `~/.config/systemd/user/containerd.service.d/override.conf` sets `CONTAINERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns`, `..._MTU=65520`, `..._DETACH_NETNS=true`, `..._PORT_DRIVER=builtin` to speed up `nerdctl pull/push/build`.
  - `~/.config/containerd/certs.d/docker.io/hosts.toml` (referenced by `~/.config/nerdctl/nerdctl.toml`) and `~/.config/buildkit/buildkitd.toml` mirror Docker Hub pulls through `mirror.gcr.io`. Mirrors only speed up image pulls (`FROM ...`), NOT in-build `git`/`curl` downloads.
  - After editing any of these, run `systemctl --user daemon-reload && systemctl --user restart containerd buildkit`.
  - Registry mirrors do NOT speed up the LLVM source download; that is a `git fetch` inside the build. The host-net change is what helps it. For repeated LLVM rebuilds, prefer caching the source on the host over re-fetching.

## Version Bumping

When bumping dependency versions across the Linux Dockerfiles, follow this checklist:

### Version Map

Versions live in multiple places. Update all of them:

| Software | Where defined |
|----------|---------------|
| **BuildKit syntax** | `# syntax=docker/dockerfile:VERSION` line 1 in every `linux/Dockerfile*` |
| **LLVM/Clang** | `ARG LLVM_RELEASE=...` in `Dockerfile.toolchain`; comments in `Dockerfile.package` L209, `Dockerfile.sdk` L51; validation text in `AGENTS.md`, `docs/linux-cross-builds.md` |
| **GCC** | `ARG GCC_VERSION=...` in `Dockerfile.toolchain` and `Dockerfile.package`; doc refs use major only (`16`) |
| **Python** | `ARG PYTHON_VERSION=...` in `Dockerfile.toolchain` and `Dockerfile.package`; `ARG PYTHON_MAJOR_MINOR=...` in `Dockerfile.package` |
| **CMake** | `ARG CMAKE_VERSION=...` in `Dockerfile.base` |
| **Node.js** | `ARG NODE_VERSION=...` in `Dockerfile.base` |
| **uv** | `ARG UV_VERSION=...` in `Dockerfile.base` |
| **Vulkan SDK** | `ARG VULKAN_VERSION=...` in `Dockerfile.base` and `Dockerfile.sdk`; `VULKAN_VERSION_DEFAULT` in `common.sh` |
| **ONNX Runtime** | `ARG ONNXRUNTIME_VERSION=...` in `Dockerfile.media` |
| **ONNX Runtime GenAI** | `ARG ONNXRUNTIME_GENAI_VERSION=...` in `Dockerfile.media` |
| **LiteRT** | `ARG LITERT_VERSION=...` in `Dockerfile.media` |
| **OpenCV** | `ARG OPENCV_VERSION=...` in `Dockerfile.media` |
| **GStreamer** | `ARG GSTREAMER_VERSION=...` in `Dockerfile.media` and `Dockerfile.package` |
| **CUDA** | `ARG CUDA_VERSION=...` and `ARG CUDA_VERSION_MAJOR_MINOR=...` in `Dockerfile.nvidia` |
| **cuDNN** | `ARG CUDNN_VERSION=...` (major only) in `Dockerfile.nvidia` |
| **TensorRT** | `ARG TENSORRT_VERSION=...` (major only) in `Dockerfile.nvidia` |
| **ROCm** | `ARG ROCM_VERSION=...` in `Dockerfile.amd` |
| **Apache TVM** | `ARG TVM_REF=...` in `Dockerfile.sdk` |
| **Android SDK** | `ARG ANDROID_SDK_VERSION=...` in `Dockerfile.android` and `Dockerfile.package` |
| **Android NDK** | `ARG ANDROID_NDK_VERSION=...` in `Dockerfile.android` and `Dockerfile.package` |
| **Android Build Tools** | `ARG ANDROID_BUILD_TOOLS=...` in `Dockerfile.android` and `Dockerfile.package` |
| **Android CMake** | `ARG ANDROID_CMAKE_VERSION=...` in `Dockerfile.android` and `Dockerfile.package` |
| **Android SDK/API** | `ARG ANDROID_COMPILE_SDK=...` and `ARG ANDROID_API_LEVEL=...` in `Dockerfile.android` and `Dockerfile.package` |
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
1. Run `python3 docs/scripts/sync_versions.py --check` to verify the generated snapshot is current.
2. If any version tracked by the script changed, run `python3 docs/scripts/sync_versions.py --write`.
3. Update version references in `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, and `AGENTS.md`.
4. Update cross-file consistency: several versions appear in multiple Dockerfiles (e.g., GCC, Python, Android SDK, Vulkan, GStreamer). Make sure they stay in sync.

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

### Kernel-Specific GPU Version Constraints

When bumping CUDA or ROCm, verify:
- CUDA: minimum driver requirement (check NVIDIA release notes)
- ROCm: `UBUNTU_VERSION` in `Dockerfile.amd` must match a supported Ubuntu codename for that ROCm version
- Both: confirm the repo URL format (`repo.radeon.com/rocm/apt/${ROCM_VERSION}`) is still valid

## Documentation Maintenance

- If Dockerfiles or Linux build helpers change, update these docs in the same change:
  - `docs/linux-cross-builds.md`
  - `docs/linux-build-basics.md`
  - `docs/project-info.md`
- If source-controlled version defaults change, run `python3 docs/scripts/sync_versions.py --write`.
- For verification-only checks, run `python3 docs/scripts/sync_versions.py --check`.
