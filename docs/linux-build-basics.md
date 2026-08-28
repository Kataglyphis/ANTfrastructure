# Linux Build Basics

**Building in and against the Linux images**: the stage hierarchy, single-image
builds, multi-arch runs, the caching map, and the apt-mirror workaround. The
cross-compiler lane that produces these images is
[`linux-cross-builds.md`](linux-cross-builds.md); a specific error message is
[`failure-modes.md`](failure-modes.md).

> **Build logging** — which orchestrators accept `--log-dir`, and how to capture
> the ones that do not:
> [`linux-cross-builds.md`](linux-cross-builds.md#build-logging).

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

The stage graph itself — `CROSS_STAGE_ORDER`, the orchestration helpers, and
the digest-pinning API — is owned by
[`linux-cross-builds.md`](linux-cross-builds.md#stage-graph-management-functions-stage-defssh).

See `AGENTS.md` § Quick Reference for the canonical build commands (orchestrator, single-stage, compiler, verification, dry-run).

## Rootless Build Networking (host tuning)

This host's rootless BuildKit is tuned for fast build-time downloads. The OCI worker runs with `--oci-worker-net=host` (via `~/.config/systemd/user/buildkit.service.d/override.conf`), so every `RUN` step (for example the LLVM `git fetch` in the cross-compiler build) uses host networking instead of the slow rootless bridge/slirp path. With this in place, a plain `nerdctl build` already uses host networking; you do not need `--network host`. Docker Hub pulls are mirrored through `mirror.gcr.io`, but mirrors only speed up `FROM ...` image pulls, not in-build `git`/`curl` downloads. See `docs/project-info.md` for the exact drop-in files and how to re-apply them. Do not regress these settings.

## Caching Layers (what is cached where)

The chain caches at every level it can; know the map before "optimizing":

| Layer | Mechanism | Notes |
|---|---|---|
| Image layers | BuildKit layer cache (per RUN/COPY vertex) | The foundation. The expensive compiler RUNs bind-mount ONLY their per-file source closure so unrelated edits don't bust them. |
| Cross-run stage cache | `--cache-to type=local` exports under `~/.cache/kata-buildcache/<stage-slug>` | Written by every chain stage; the between-stage disk guard LRU-prunes but PROTECTS slugs of stages still to run. |
| Other hosts | inline registry cache (`--cache-to type=inline` on push) | Embedded in the image config — immune to ghcr's oversized-blob 400s. |
| Rust | sccache through the guarded launcher (`01-core/sccache-launcher.sh`), ON by default since 2026-08-27 | `setup_sccache` exports `RUSTC_WRAPPER=<launcher>` (`compiler-cache.sh:233`) and `setup-gstreamer.sh:50` runs it before `build-gstreamer-monorepo.sh:581` tests `[ -z "${RUSTC_WRAPPER+x}" ]`, so gst-plugins-rs is wired without `ENABLE_SCCACHE_RUST` — that gate now only covers the `media_common_init` copy of the call (`03-media/core/common.sh:144`). The 2026-08-20 disable (server dying at 99%) was the shared-TCP-port server reaching a sibling step's daemon; `SCCACHE_SERVER_UDS` cured it, and the launcher makes a hiccup cost hits rather than the build. Opt out by exporting `RUSTC_WRAPPER=""` — what `Dockerfile.toolchain:58` and `Dockerfile.package:173` do. Full multi-tier design (ccache `remote_storage` for C/C++ + shared backend with the Windows lane's sccache) is specced in the backlog. |
| C/C++ objects | **sccache** since 2026-08-26 (owner decision, reversing the 2026-08-17 "full switch rejected"), with **ccache as the automatic fallback** — every launcher resolves through `compiler_cache_launcher()` in `01-core/common.sh`: GCC via `build-gcc.sh --ccache` (the flag name is historical; it means "use the compiler cache"), LLVM via `CMAKE_*_COMPILER_LAUNCHER`, media via `compiler-cache.sh`. Relativization is launcher-specific: `CCACHE_BASEDIR` for ccache, `SCCACHE_BASEDIRS` for sccache (which is why `SCCACHE_LINUX_VERSION` is pinned at 0.17.0 — the distro 0.13.0 lacks it). sccache's sloppiness knobs (`file_stat_matches`, `ignore_time_macros`) have no env path and live in `/etc/sccache/config.toml`, baked into `Dockerfile.base`; direct mode does have one, `SCCACHE_DIRECT`, and `common.sh:418` sets it to `false` — which overrides the `use_preprocessor_cache_mode = true` in that file. Both cache mounts are present on every heavy RUN, because the fallback needs somewhere to persist. |
| Package managers | apt / cargo / uv / pip cache mounts | `sharing=locked` throughout. |
| Sources | GCC tarball shared across host+targets (`GCC_TARBALL_CACHE_DIR`); LLVM source under `/var/cache/llvm-src`; ONNX-web + ffmpeg-sdks version-keyed mounts | The remaining media clones (opencv/gstreamer/ffmpeg/onnx) re-fetch on a cache bust — see the backlog item before adding mounts: `clone_or_update_repo` needs corrupt-dir hardening first, or a killed run poisons the shared source cache. |
| GC budget | `~/.config/buildkit/buildkitd.toml` pins `gckeepstorage` | Without it, buildkit's DEFAULT GC decided whether the multi-hour layers survive between runs. Restart buildkitd BETWEEN runs only (`systemctl --user restart buildkit`) — never while a build solves. |

### Why compiler caches AND BuildKit layer caching — the multiplication

The two mechanisms work at different granularities and cover each other's
blind spots; neither replaces the other:

- **BuildKit layer cache** is binary at RUN-step granularity: hit = 0 seconds,
  miss = the whole step re-executes. Its blind spot is precisely the moment
  you pay — a one-character edit to any file in a step's mount closure re-runs
  the entire multi-hour compile.
- **Compiler caches** (ccache/sccache) work at translation-unit granularity:
  when the layer MISSES, they turn a from-scratch compile into mostly cache
  lookups — one changed file re-links, thousands of unchanged objects hit.
- **They multiply:** layer cache is the fast path for "nothing changed";
  the compiler cache is the amortizer for "something changed". A closure edit
  that costs hours cold costs minutes warm.
- **Defense in depth:** compiler caches live in `--mount=type=cache` volumes
  that survive layer-cache loss (GC, evictions, worker resets — see the
  2026-08-08 unexplained base cache-miss), and a remote tier survives even
  cache-mount loss and extends across hosts.

### Why sccache for C/C++, with ccache kept as the fallback (SUPERSEDES the old HYBRID)

> This section used to argue that ccache should own C/C++ and sccache only Rust.
> The owner reversed that on 2026-08-26 and the C/C++ switch shipped. The
> arguments below are updated rather than deleted, because all three still
> hold — the hit-rate one included. The switch accepted that cost rather than
> refuting it.

- **The old "ccache wins C/C++" argument was conditional, and its condition
  holds today.** It rested on sccache's C/C++ path "always preprocessing",
  which is true whenever preprocessor-cache mode (sccache's analogue of
  ccache's direct mode) is off — and it is off. `Dockerfile.base:118-130` still
  writes `use_preprocessor_cache_mode = true` into `/etc/sccache/config.toml`
  (`SCCACHE_CONF`), but `01-core/common.sh:418` exports
  `SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"` on every launcher resolution, and
  the environment wins over the file. The mode was turned off on 2026-08-26
  after it broke two builds: it re-reads the INPUT FILE to store the entry
  AFTER the compile, CMake's TryCompile probes delete their scratch dir
  immediately, and the re-read's ENOENT is FATAL to sccache — it killed
  OpenCV's compiler test, then onnxruntime's, three times running. Cost is hit
  rate, not correctness; `SCCACHE_DIRECT=true` re-enables it. So sccache's C/C++
  hit costs a preprocess that ccache's direct-mode hit does not.
- **The real operating difference is failure behaviour, not hit rate.** sccache
  HARD-FAILS on a compiler it cannot identify; ccache just execs it. That is why
  ccache stays installed and mounted as the fallback, and why
  `linux/scripts/02-toolchain/probe-sccache.sh` exists: run it inside the
  compiler image before committing hours to a change, and it asserts per
  compiler shape that the compile survives AND that cache activity was recorded.
- **sccache is irreplaceable for Rust AND the GPU compilers**: ccache cannot
  wrap rustc, and nvcc's device compiles (plus hipcc for ROCm) are equally out
  of its reach — sccache handles all three first-class. With
  `CUDA_ARCHITECTURES="80;86;89;90"` every CUDA kernel compiles FOUR times;
  for the GPU onnxruntime/opencv builds this is the single biggest cache
  lever in the repo. Gates: `ENABLE_SCCACHE_RUST` (only the
  `media_common_init` call — the gstreamer lane wires Rust regardless, see the
  Rust row above), `ENABLE_SCCACHE_CUDA` (one gate for nvcc + hipcc launchers
  in the ONNX GPU/AMD builds and OpenCV's CUDA config; default 0, so nvcc
  stays uncached).
- Both need **measurement to stderr** (the stream the 2MiB step-log clip never
  cuts) — an unmeasured cache regresses invisibly (proved live: the launcher
  never reached LLVM's nested sub-builds, 0% gain on identical inputs).
- `compiler-cache.sh::setup_sccache` has documented this exact division of
  labor all along; 2026-08-08 wired the Rust half behind a gate, and
  2026-08-27 put it on by default through the guarded launcher (4200f7b, plus
  54fc1df — `setup_sccache` had been exporting bare `sccache` unconditionally,
  which defeated the wiring entirely).

**Roadmap to "everything cached" (all specced, closure-batched):** ccache
`remote_storage` + `SCCACHE_REDIS` against one host-local backend (shared
infra with the Windows lane's sccache; no cross-OS hits, shared plumbing) →
launcher forwarding into LLVM's nested sub-builds → version-keyed source-tree
mounts once `clone_or_update_repo` is corrupt-dir-hardened → NDK download
cache. Cache-mount coverage in the Dockerfiles is already complete where work
happens (verified 2026-08-08: the thin-looking package/torch counts are
symlink/validation steps with nothing to cache).

**Process rule that beats every mechanism:** between chain runs that should
cache-hit each other, do not touch anything in the base/toolchain closures
(01-core, 02-toolchain, versions.env, the bundled smoke scripts, the
Dockerfiles) — identical context bytes are what turn the next run into a pure
re-export. (`--no-push` full-chain runs are broken on OCI-worker hosts; see
`docs/linux-cross-builds.md` for the correct push-mode flow.)

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

`linux/Dockerfile.torch` is the final wrapper image; build it through the orchestrator or via the `wrapper-smoke` target in `Dockerfile.package` for cheaper packaging validation (see `docs/linux-cross-builds.md` § "Local wrapper smoke validation").

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
  `scripts/linux/run-{debug,profile,release}.sh` for the pattern.
- `ctest-run.sh` — ctest runner with a perf-baseline comparator (fails on
  regression against a stored baseline).
- `docs-build.sh` — Sphinx docs build helper (not to be confused with the
  `02-toolchain/python/ci_build_docs.sh` CI helper).
- `rust-toolchain.sh` — rustup/toolchain bootstrap for consumer repos.

  (The last three were invisible until the 2026-08-08 orphan sweep: genuinely
  useful, shipped into the images, referenced by nothing — including any doc.)
