# Linux Build Basics

> **Build logging:** All orchestrator scripts accept `--log-dir ./out/build-logs` to write per-stage build logs. For manual `nerdctl build` commands, capture output with `2>&1 | tee ./out/build-logs/<name>.log`. The standard location for build logs is `out/build-logs/`.

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
as `CROSS_STAGE_ORDER`. Stage orchestration (build, push, pin) is handled by shared functions
in `linux/scripts/01-core/cross-stage-build.sh`.  See `docs/linux-cross-builds.md` for the
full stage graph API and digest-pinning details.

See `AGENTS.md` § Quick Reference for the canonical build commands (orchestrator, single-stage, compiler, verification, dry-run).

## Rootless Build Networking (host tuning)

This host's rootless BuildKit is tuned for fast build-time downloads. The OCI worker runs with `--oci-worker-net=host` (via `~/.config/systemd/user/buildkit.service.d/override.conf`), so every `RUN` step (for example the LLVM `git fetch` in the cross-compiler build) uses host networking instead of the slow rootless bridge/slirp path. With this in place, a plain `nerdctl build` already uses host networking; you do not need `--network host`. Docker Hub pulls are mirrored through `mirror.gcr.io`, but mirrors only speed up `FROM ...` image pulls, not in-build `git`/`curl` downloads. See `docs/project-info.md` for the exact drop-in files and how to re-apply them. Do not regress these settings.

## Build

```bash
# Recommended: cross-lane digest-pinned release
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
# on Windows you must expose ports one by one
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross

# Alternative: QEMU/binfmt multi-platform build:
# sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
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
  . 2>&1 | tee ./out/build-logs/nerdctl-build.log
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
mkdir -p ./out/build-logs && \
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-cross-wrapper-smoke-amd64 \
  -f linux/Dockerfile.package \
  --target wrapper-smoke \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:base \
  --build-arg ARTIFACT_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --build-arg ARTIFACT_PLATFORM=linux/amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=native \
  . 2>&1 | tee ./out/build-logs/wrapper-smoke-native.log
```

Cross-mode variant (validates cross-assembled artifacts):

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
  . 2>&1 | tee ./out/build-logs/wrapper-smoke-cross.log
```

The `build-runtime-manifest.sh` helper uses the same local-only handoff internally, so `--skip-manifest` and other non-push runs do not require a registry-visible base/package tag.
- `build-runtime-manifest.sh --manifest-only` (alias `--repair`) creates/pushes the manifest only,
  useful for repairing a manifest from existing per-arch wrappers without rebuilding images.
The runtime helpers still run the Torch stage on the real target platform so the final image includes `/opt/venv`.

See `docs/linux-cross-builds.md` for details on the riscv64 app wheelhouse, GCC compilation patterns (native vs Canadian cross), clang/cc symlink setup, LLVM_RELEASE forwarding through SDK rebuilds, and Dockerfile-specific ignore files.


Not supported / not needed:

- `linux/webserver/Dockerfile` is not wired for this flag.
- `windows/Dockerfile` does not use apt.

## Multi-Arch Build

> **QEMU/binfmt:** If foreign-architecture builds/runs fail with `exec format error`, register the QEMU emulators first. On this **rootless** host use `linux/scripts/setup-rootless-binfmt.sh` (**no sudo**) — a plain `nerdctl run --rm --privileged tonistiigi/binfmt --install all` prints "OK" but does **not** take effect rootless (it registers in a throwaway namespace). See *Host prerequisite: QEMU/binfmt* in `docs/linux-cross-builds.md` for why, and note that `build-runtime-manifest.sh` now auto-registers before its runtime smokes. Registration is per-boot; `--install-service` makes it persistent.

### RISC-V64 example

```bash
mkdir -p ./out/build-logs && \
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.29.2 --no-cache \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:riscv -f linux/Dockerfile.media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee ./out/build-logs/riscv64-build.log
```

`linux/Dockerfile.torch` is the final wrapper image; build it through the orchestrator or via the `wrapper-smoke` target in `Dockerfile.package` for cheaper packaging validation (see `docs/linux-cross-builds.md` § "Single-Stage Builds").

For media-build validation before kicking off the slow gstreamer+libcamera serial tail, `Dockerfile.media` exposes a `media-smoke` alias that stops at the `media-inputs` aggregation stage:

```bash
mkdir -p ./out/build-logs && \
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:media-smoke-amd64 \
  -f linux/Dockerfile.media --target media-smoke \
  --build-arg BASE_IMAGE=local/kataglyphis:cross-sdk-amd64 \
  . 2>&1 | tee ./out/build-logs/media-smoke-amd64.log
```

For a full hands-off cross build of `:latest-cross`, prefer the orchestrator `linux/scripts/build-cross-chain.sh`. It chains `base -> compiler -> sdk -> media -> android -> runtime` with digest-pinned stage handoff. See `docs/linux-cross-builds.md` for the full pipeline and `AGENTS.md` for the stage handoff rules.

## Consumer bash libraries (`linux/scripts/lib/`)

Reusable libraries consumer repos source directly from the submodule:

- `agentic-loop.sh` — planner/executor loop core (see
  `docs/windows-agentic-loop.md` for the config contract; the bash side is
  its parity twin and reads the same `shared/agentic-loop/prompts/`).
- `app-runner.sh` — generic application launcher: `--exe-name/--build-dir/
  --build-type` arg parsing, executable discovery (candidate ladder +
  bounded find fallback), `LD_LIBRARY_PATH` export, and caller hooks
  (`app_runner_post_vulkan_hook`, `app_runner_env_hook`,
  `APP_RUNNER_ENABLE_SHADER_CLEAN`). Consumers keep only per-profile
  wrappers (defaults + hooks); see BeschleunigerBallett
  `Scripts/Linux/run-{debug,profile,release}.sh` for the pattern.
