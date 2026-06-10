# Linux Build Basics

## Image Hierarchy

```
ubuntu:26.04
└── base                                (:base)
    ├── compiler/toolchain              (:cross-compiler-amd64)
    │   └── sdk                         (:cross-sdk-<arch>)
    │       ├── media                   (:cross-media-<arch>)
    │       │   └── android             (:cross-android-<arch>)
    │       ├── nvidia (optional)       (:toolchain-nvidia)
    │       └── amd (optional)          (:toolchain-amd)
    └── runtime-base                    (:latest-cross-base-<arch>)
        └── package                     (:latest-cross-package-<arch>)
            └── torch/wrapper           (:latest-cross-<arch>)
                └── manifest            (:latest-cross)
```

**Two Build Lanes:**

| Lane | Platform | Purpose | Tag prefix |
|------|----------|---------|------------|
| **Cross lane** | `linux/amd64` | Compile artifacts for all target arches | `:cross-*` |
| **Runtime lane** | Target platform | Package cross artifacts into target-native images | `:latest-cross-*` |

The final release target is the multi-arch manifest `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`, assembled from per-arch wrappers `:latest-cross-{amd64,arm64,riscv64}`.

See `AGENTS.md` for the full container architecture documentation.

## Build Flow

The full `:latest-cross` pipeline:

1. **Cross lane** (stages 1-5, all `linux/amd64`):
   - `base` → `compiler` → `sdk` → `media` → `android`
2. **Runtime lane** (stage 6, target platform via QEMU/binfmt for foreign arches):
   - `base` → `package` → `torch`/`wrapper` → `manifest`

The cross-lane stage chain is defined declaratively in `linux/scripts/01-core/stage-defs.sh`
as `CROSS_STAGE_ORDER`.  Each stage maps to its Dockerfile, parent, tag function, and
per-arch flag.  Both `build-cross-chain.sh` and `--verify-chain` consume this graph.

Stage build/pin functions live in `linux/scripts/01-core/cross-stage-build.sh` (sourced
via `artifact-common.sh`), providing `cross_stage_run()`, `cross_stage_build_and_push()`,
`cross_stage_resolve_parent_pin()`, and `resolve_pin()`.  These are consumed by all three
cross-lane entry points (orchestrator, single-stage builder, and standalone compiler).

Prefer the orchestrator for full chains:
```bash
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64
```

For single-stage rebuilds, use the standalone helpers:
```bash
bash linux/scripts/build-cross-stage.sh --stage compiler --push
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
```

For standalone compiler builds (same as `--stage compiler` above):
```bash
bash linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64
```

## Rootless Build Networking (host tuning)

This host's rootless BuildKit is tuned for fast build-time downloads. The OCI worker runs with `--oci-worker-net=host` (via `~/.config/systemd/user/buildkit.service.d/override.conf`), so every `RUN` step (for example the LLVM `git fetch` in the cross-compiler build) uses host networking instead of the slow rootless bridge/slirp path. With this in place, a plain `nerdctl build` already uses host networking; you do not need `--network host`. Docker Hub pulls are mirrored through `mirror.gcr.io`, but mirrors only speed up `FROM ...` image pulls, not in-build `git`/`curl` downloads. See `docs/project-info.md` for the exact drop-in files and how to re-apply them. Do not regress these settings.

## Build

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
# on Windows you must expose ports one by one
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

## Optional Ubuntu Apt Mirror Workaround

- Add both `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=...` when the default Ubuntu archive mirror is slow.
- Example German mirror override: `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/`.
- The helper rewrites archive mirror entries only by default; `security.ubuntu.com` stays untouched unless you explicitly opt into rewriting it.
- Helper scripts expose the same behavior via `--fast-ubuntu-mirror` and `--fast-ubuntu-mirror-url`.

Generic usage:

```bash
sudo nerdctl build \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  -f <dockerfile> \
  .
```

Supported Dockerfiles:

- `linux/Dockerfile.base`
- `linux/Dockerfile.toolchain`
- `linux/Dockerfile.sdk`
- `linux/Dockerfile.media`
- `linux/Dockerfile.android`
- `linux/Dockerfile.package`
- `linux/Dockerfile.nvidia`
- `linux/Dockerfile.amd`
- `linux/Dockerfile.torch`

Local smoke validation for the shared package+wrapper flow (native mode):

```bash
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-cross-wrapper-smoke-amd64 \
  -f linux/Dockerfile.package \
  --target wrapper-smoke \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg ARTIFACT_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --build-arg ARTIFACT_PLATFORM=linux/amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=native \
  .
```

Cross-mode variant (validates cross-assembled artifacts):

```bash
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-cross-wrapper-smoke-amd64 \
  -f linux/Dockerfile.package \
  --target wrapper-smoke \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg ARTIFACT_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android-amd64 \
  --build-arg ARTIFACT_PLATFORM=linux/amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=cross \
  .
```

The runtime helpers use the same local-only handoff internally, so `--skip-manifest` and other non-push runs do not require a registry-visible base/package tag. They still run the Torch stage on the real target platform so the final image includes `/opt/venv`. In cross mode, the media artifact lane now also makes a best-effort `riscv64` app wheelhouse on the amd64 host for the locked `torch`, `torchvision`, and `opencv-python` git-source dependencies used by `Kataglyphis-Orchestr-ANT-ion`, and the final Torch install keeps the upstream `uv.lock` when present so it can reuse those local wheels instead of re-resolving the same git sources under QEMU. If a reused cross artifact has an empty `/opt/wheels`, that Torch step now keeps the packages that `uv sync` already resolved instead of uninstalling them and trying to install a literal `/opt/wheels/*.whl` glob. The package stage must keep `/usr/bin/clang` pointed at the copied target-native `/usr/local/llvm-target/bin/clang` on all architectures; do not let it fall back to distro `/usr/local/llvm-22` on `arm64` or `riscv64`. On all architectures, `/usr/bin/cc` points to the source-built `/opt/gcc-16.1.0/bin/gcc`. On `amd64`, GCC is built natively. On `arm64` and `riscv64`, GCC is cross-compiled from source (Canadian cross) during the toolchain stage so `/opt/gcc-16.1.0/bin/gcc` is a target-native binary; `Dockerfile.android` swaps it in at the end of the Android stage. On this host, prefer `linux/scripts/build-runtime-artifacts.sh` and `linux/scripts/build-runtime-manifest.sh` over ad hoc `nerdctl build` loops.

When you rebuild a cross SDK artifact from an older `cross-compiler-amd64` base, `linux/Dockerfile.sdk` now forwards the checked-in `LLVM_RELEASE` into `target-clang` so `/opt/llvm-target` is refreshed to the repository pin instead of inheriting a stale base-image environment value.

Those temporary stage contexts now default to `${XDG_CACHE_HOME:-$HOME/.cache}/opencode/runtime-build-contexts` and each one is deleted after the next stage finishes using it. Both runtime helpers accept `--target-arches`, `TARGET_ARCHES`, and `TARGET_ARCH` for selecting target architectures.

The main repo-root Linux Dockerfiles now use Dockerfile-specific ignore files too, so routine Linux builds no longer send the large `linux/webserver/` tree through the base/toolchain/sdk/media/android/package/torch/wrapper contexts.

When you are feeding locally saved runtime artifacts back into later builds:

- Keep `.dockerignore` excluding `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so exported OCI layouts and rootfs trees do not get sent back as a later build context.
- Prefer saved OCI layouts such as `out/local-oci/android/<arch>` for foreign-architecture runtime packaging. The plain directory exports under `out/local-android-dir/<arch>` are much larger, and an earlier OCI-to-directory conversion dropped `/usr/local/lib/onnxruntime-cpu`.
- On this host, the verified local runtime path mixes context types: the heavy `runtime_artifact` input comes from an `oci-layout://...` context, while the intermediate `runtime_base` handoff stays a plain rootfs directory because one build still fails when it consumes two named OCI image contexts at once.
- `readlink -f` on symlinks inside `out/linux-runtime/*/rootfs` resolves absolute links against the host root, so use plain `readlink` or validate from inside the built image when checking `/usr/bin/cc`, `/usr/bin/clang`, `/etc/alternatives/cc`, and `/etc/alternatives/clang`.
- Local BuildKit and containerd stores can still grow very large during repeated runtime rebuilds, so prune old images and exported artifacts if disk pressure returns.


Not supported / not needed:

- `linux/webserver/Dockerfile` is not wired for this flag.
- `windows/Dockerfile` does not use apt.

## Multi-Arch Build

> **QEMU/binfmt:** If foreign-architecture builds fail with `exec format error`, run `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` in a terminal first. The binfmt registration may need to be reinstalled after a host reboot.

### RISC-V64 example

```bash
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.28.1 --no-cache \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:riscv -f linux/Dockerfile.media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
```

### Setup essentials

Always build with `--platform`:

```bash
docker buildx imagetools create --tag ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest_multiarch ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd64
```

```bash
cat > /tmp/buildkitd.toml <<'TOML'
# limit BuildKit worker parallelism to 2 (set to 1 on very small machines)
[worker.oci]
  max-parallelism = 2
TOML
```

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-multiarch"
mkdir -p "${LOG_DIR}"

nerdctl login ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -u Kataglyphis

sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all

nerdctl build \
  --platform=linux/amd64,linux/arm64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  -f linux/Dockerfile.torch . 2>&1 | tee "${LOG_DIR}/latest.log"
```

### Build & push (docker buildx)

```bash
docker buildx create --name wsl-limited --use --driver docker-container --driver-opt memory=12g --driver-opt cpu-period=100000 --driver-opt cpu-quota=800000
```

```bash
--builder wsl-limited
```

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-buildx"
mkdir -p "${LOG_DIR}"

sudo docker buildx build \
  -f linux/Dockerfile.torch \
  --platform linux/amd64,linux/arm64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:$(git rev-parse --short HEAD) \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  --push \
  . 2>&1 | tee "${LOG_DIR}/buildx-latest.log"
```

### Reset builder

```bash
docker buildx ls
docker buildx rm mybuilder 2>/dev/null || true
docker buildx create --name mybuilder --driver docker-container --buildkitd-config /tmp/buildkitd.toml --use --
```

### Sequential build (nerdctl)

If apt stalls on the default Ubuntu archive mirror, add `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/` to the Ubuntu-based build commands in this sequence.

Only the privileged `binfmt` install step below needs `sudo` in this sequential Linux flow.

```bash
LOG_DIR="logs/$(date -u +'%Y%m%dT%H%M%SZ')-sequential"
mkdir -p "${LOG_DIR}"

sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base,push=true' \
  -f linux/Dockerfile.base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-base,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-base \
  . 2>&1 | tee "${LOG_DIR}/base.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler \
  . 2>&1 | tee "${LOG_DIR}/compiler.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk,push=true' \
  -f linux/Dockerfile.sdk \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --build-arg USE_FAST_UBUNTU_MIRROR=true \
  --build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/ \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk \
  . 2>&1 | tee "${LOG_DIR}/sdk.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media,push=true' \
  -f linux/Dockerfile.media \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media \
  . 2>&1 | tee "${LOG_DIR}/media.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android,push=true' \
  -f linux/Dockerfile.android \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android \
  . 2>&1 | tee "${LOG_DIR}/android.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch \
  . 2>&1 | tee "${LOG_DIR}/torch.log"
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest \
  . 2>&1 | tee "${LOG_DIR}/latest.log"
```

`linux/Dockerfile.torch` now also exposes a `venv-export` stage for cases where you only want the built `/opt/venv` tree. Build with `--build-arg TORCH_APP_MODE=install` to skip the import smoke tests during image creation, then export just `/opt/venv` with:

```bash
docker buildx build \
  --platform linux/arm64 \
  -f linux/Dockerfile.torch \
  --target venv-export \
  --output type=local,dest=out/torch-venv/arm64 \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --build-arg TORCH_APP_MODE=install \
  .
```

The cross/QEMU variant of that flow is documented in `docs/linux-cross-builds.md` and uses `linux/Dockerfile.package` to copy the cross-built payloads into a real target-platform runtime image before the final Torch `/opt/venv` assembly step runs.

For a full hands-off cross build of `:latest-cross`, prefer the orchestrator `linux/scripts/build-cross-chain.sh`. It chains `base -> compiler -> sdk -> media -> android -> runtime` and hands each stage to the next by its registry-resolvable manifest digest (`<repo>@sha256:...`) rather than a mutable tag, so a downstream stage can never silently consume a stale locally-cached base image. The manual `nerdctl` cross loops in `docs/linux-cross-builds.md` carry `--pull=true` as a weaker fallback defense.

For single-stage rebuilds, use `linux/scripts/build-cross-stage.sh`:
```bash
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
```

See `AGENTS.md` → "Cross Chain Stage Handoff" for the do-not-regress rule.
