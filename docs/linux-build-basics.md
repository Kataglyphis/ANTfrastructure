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
    │       └── gpu (variant chain)     (:cross-toolchain-nvidia-<arch>, :cross-toolchain-rocm-<arch>)
    │           └── media → android     (:cross-media-<variant>-<arch> → :cross-android-<variant>-<arch>)
    └── runtime-base                    (:latest-base-<arch>)
        └── package                     (:latest-package-<arch>)
            └── torch/wrapper           (:latest-<arch>)
                └── manifest            (:latest)
```

**Two Build Lanes:**

| Lane | Platform | Purpose | Tag prefix |
|------|----------|---------|------------|
| **Cross lane** | `linux/amd64` | Compile artifacts for all target arches | `:cross-*` |
| **Runtime lane** | Target platform | Package cross artifacts into target-native images | `:latest-*` |

The final release target is the multi-arch manifest `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`, assembled from per-arch wrappers `:latest-{amd64,arm64,riscv64}`.

The stage graph with its tags and platforms, and what each stage contains, is
[`overview.md`](overview.md); a variant's tags are
[`linux-accelerator-images.md`](linux-accelerator-images.md).

## Build Flow

The full `:latest` pipeline:

1. **Cross lane** (stages 1-5, `linux/amd64`, or natively on the build host's
   own platform with `CROSS_BUILD_PLATFORM`):
   - `base` → `compiler` → `sdk` → `media` → `android`
2. **Runtime lane** (stage 6, target platform via QEMU/binfmt for foreign arches):
   - `base` → `package` → `torch`/`wrapper` → `manifest`

The stage graph itself — `CROSS_STAGE_ORDER`, the orchestration helpers, and
the digest-pinning API — is owned by
[`linux-cross-builds.md`](linux-cross-builds.md#stage-graph-management-functions-stage-defssh).

The canonical build commands (orchestrator, single-stage, compiler, verification, dry-run) are in [`linux-cross-builds.md` § The command reference AGENTS.md used to carry](linux-cross-builds.md#the-command-reference-agentsmd-used-to-carry).

## Rootless Build Networking (host tuning)

This host's rootless BuildKit is tuned for fast build-time downloads. The OCI worker runs with `--oci-worker-net=host` (via `~/.config/systemd/user/buildkit.service.d/override.conf`), so every `RUN` step (for example the LLVM `git fetch` in the cross-compiler build) uses host networking instead of the slow rootless bridge/slirp path. With this in place, a plain `nerdctl build` already uses host networking; you do not need `--network host`. Docker Hub pulls are mirrored through `mirror.gcr.io`, but mirrors only speed up `FROM ...` image pulls, not in-build `git`/`curl` downloads. See `docs/project-info.md` for the exact drop-in files and how to re-apply them. Do not regress these settings.

## Caching Layers (what is cached where)

The chain caches at every level it can; know the map before "optimizing":

| Layer | Mechanism | Notes |
|---|---|---|
| Image layers | BuildKit layer cache (per RUN/COPY vertex) | The foundation. The expensive compiler RUNs bind-mount ONLY their per-file source closure so unrelated edits don't bust them. |
| Cross-run stage cache | `--cache-to type=local` exports under `~/.cache/kata-buildcache/<stage-slug>` | Written by every chain stage; the between-stage disk guard LRU-prunes but PROTECTS slugs of stages still to run. |
| Other hosts | inline registry cache (`--cache-to type=inline` on push) | Embedded in the image config — immune to ghcr's oversized-blob 400s. |
| Rust | sccache through the guarded launcher (`01-core/sccache-launcher.sh`), ON by default since 2026-08-27 | `setup_sccache` exports `RUSTC_WRAPPER=<launcher>` (`compiler-cache.sh:199`) and `setup-gstreamer.sh:50` runs it before `build-gstreamer-monorepo.sh`'s `build_gstreamer_monorepo` tests `[ -z "${RUSTC_WRAPPER+x}" ]`, so gst-plugins-rs is wired without `ENABLE_SCCACHE_RUST` — that gate now only covers the `media_common_init` copy of the call (`03-media/core/common.sh`). The 2026-08-20 disable (server dying at 99%) was the shared-TCP-port server reaching a sibling step's daemon; `SCCACHE_SERVER_UDS` cured it, and the launcher makes a hiccup cost hits rather than the build. Opt out by exporting `RUSTC_WRAPPER=""` — what `Dockerfile.toolchain` and `Dockerfile.package` do. Full multi-tier design (ccache `remote_storage` for C/C++ + shared backend with the Windows lane's sccache) is specced in the backlog. |
| C/C++ objects | **sccache** since 2026-08-26 (owner decision, reversing the 2026-08-17 "full switch rejected"), with **ccache as the automatic fallback** — every launcher resolves through `compiler_cache_launcher()` in `01-core/common.sh`: GCC via `build-gcc.sh --ccache` (the flag name is historical; it means "use the compiler cache"), LLVM via `CMAKE_*_COMPILER_LAUNCHER`, media via `compiler-cache.sh`. Relativization is launcher-specific: `CCACHE_BASEDIR` for ccache, `SCCACHE_BASEDIRS` for sccache (which is why `SCCACHE_LINUX_VERSION` pins a release in `versions.env` — the distro 0.13.0 lacks it). sccache's sloppiness knobs (`file_stat_matches`, `ignore_time_macros`) have no env path and live in `/etc/sccache/config.toml`, baked into `Dockerfile.base`; direct mode does have one, `SCCACHE_DIRECT`, and `ensure_sccache_env` in `01-core/common.sh` sets it to `false` — which overrides the `use_preprocessor_cache_mode = true` in that file. Both cache mounts are present on every heavy RUN, because the fallback needs somewhere to persist. |
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
  ccache's direct mode) is off — and it is off. `Dockerfile.base` still
  writes `use_preprocessor_cache_mode = true` into `/etc/sccache/config.toml`
  (`SCCACHE_CONF`, not read at all while `SCCACHE_DIR` is set — see
  [`build-cache-tiers.md`](build-cache-tiers.md#the-shipped-images-cache-dirs)),
  and `ensure_sccache_env` in `01-core/common.sh` exports
  `SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"` on every launcher resolution. The
  mode was turned off on 2026-08-26
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
  `CUDA_ARCHITECTURES="86;87;89;120"` every CUDA kernel compiles FOUR times;
  for the GPU onnxruntime/opencv builds this is the single biggest cache
  lever in the repo. Gates: `ENABLE_SCCACHE_RUST` (only the
  `media_common_init` call — the gstreamer lane wires Rust regardless, see the
  Rust row above), `ENABLE_SCCACHE_CUDA` (nvcc in the ONNX GPU build and OpenCV's CUDA
  config; default 1 since 2026-10-17) and `ENABLE_SCCACHE_HIP` (hipcc in the
  ONNX AMD build; default 1 as well, [build-cache-tiers.md § 5.4](build-cache-tiers.md#nvcc--hipcc)).
- Both need **measurement to stderr** (the stream the 2MiB step-log clip never
  cuts) — an unmeasured cache regresses invisibly (proved live: the launcher
  never reached LLVM's nested sub-builds, 0% gain on identical inputs).
- `compiler-cache.sh::setup_sccache` has documented this exact division of
  labor all along; 2026-08-08 wired the Rust half behind a gate, and
  2026-08-27 put it on by default through the guarded launcher (32668ed, plus
  9cc5d72 — `setup_sccache` had been exporting bare `sccache` unconditionally,
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
re-export. (`--no-push` full chains from `base` are supported since 2026-08-30 via the
local OCI-layout handoff; only runs RESUMED mid-chain are refused — see
`docs/linux-cross-builds.md`.)

## Running the published image

```bash
nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest

# The default CMD is a shell — nothing listens until you start a server.
# Publishing 8443 only helps once one is running inside; the separate
# :webserver image is the one that serves HTTP, on 80/443.
nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

Rootful nerdctl needs `sudo`. The sudo-less route is the rootless
containerd + BuildKit stack this repo builds with — not the `docker` group,
which nerdctl never consults (containerd's socket is `root:root 0660`). That
stack can also be *installed* without sudo:
[`linux-host-setup.md` § B3c](linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).
On a Jetson, rootless nerdctl needs three extra flags:
[§ B2b](linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
The WebRTC signalling server behind port 8443 is
[`runtime-services.md` § WebRTC Streaming](runtime-services.md#webrtc-streaming).

### A lane under a rootless engine on a Linux host runs as root

Rootless nerdctl maps the host user to the container's root, so the image's uid 1001 lands on a
subuid that may not write a bind-mounted checkout: `Cannot open file, path =
'.dart_tool/package_config.json' (OS Error: Permission denied, errno = 13)`. Pass `--user 0:0`
when `nerdctl info` reports `name=rootless` on a Linux host; every file the lane writes is then the
host user's. As root, GNU tar also restores an archive's owners, and one beyond the engine's 65,536
subuids fails the extraction (Flutter's `gradle-wrapper.tgz` carries uid 397546: `Cannot change
ownership to uid 397546, gid 5000: Invalid argument`), so `TAR_OPTIONS=--no-same-owner` goes with
the user. A Windows host (Rancher) and CI, whose runner is uid 1001 itself, need neither.

## Optional Ubuntu Apt Mirror Workaround

- Add both `--build-arg USE_FAST_UBUNTU_MIRROR=true` and `--build-arg FAST_UBUNTU_MIRROR_URL=...` when the default Ubuntu archive mirror is slow.
- Example German mirror override: `--build-arg FAST_UBUNTU_MIRROR_URL=http://de.archive.ubuntu.com/ubuntu/`.
- The helper rewrites archive **and** `security.ubuntu.com` entries to the mirror by default (AS1: a host `-security` on a different archive than the target pocket reproduces the Multi-Arch:same skew); `FAST_UBUNTU_REWRITE_SECURITY=false` is the explicit opt-out, and a mirror must carry `-security` for the arches you build.
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

Local smoke validation for the shared package+wrapper flow (native mode). Native
mode takes an android image built natively for the target, and nothing publishes
one (the chain's is `:cross-android-<arch>`), so put your own in place of
`:android` below:

```bash
mkdir -p ./out/build-logs && \
nerdctl build --platform linux/amd64 \
  -t local/kataglyphis:latest-wrapper-smoke-amd64 \
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
  -t local/kataglyphis:latest-wrapper-smoke-amd64 \
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

See `docs/linux-cross-builds.md` for details on the app wheelhouse, GCC compilation patterns (native vs Canadian cross), clang/cc symlink setup, and LLVM_RELEASE forwarding through SDK rebuilds.


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
  . 2>&1 | tee ./out/build-logs/riscv64-build.log
```

`Dockerfile.media` builds FROM `BASE_IMAGE` (default `local/kataglyphis:sdk`),
which must be a riscv64 sdk image here. The example carries no registry cache
ref on purpose: ghcr rejects an oversized `mode=max` cache blob with
`400 Bad Request`, which fails the build
([`build-cache-tiers.md` § 4](build-cache-tiers.md)). The
chain's own riscv64 media is a cross build:
`build-cross-stage.sh --stage media --arch riscv64`.

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

For a full hands-off cross build of `:latest`, prefer the orchestrator `linux/scripts/build-cross-chain.sh`. It chains `base -> compiler -> sdk -> media -> android -> runtime` with digest-pinned stage handoff. See `docs/linux-cross-builds.md` for the full pipeline and `AGENTS.md` for the stage handoff rules.

## Linux packages that run outside the image

A package built in `:latest` links what only the image has, and the image hides that: every
library is there, so a check inside it passes. On 2026-10-16 AccelerANTgine 0.0.1's `.deb`,
tarball and AppImage started nowhere else: GCC 16.2's `libstdc++` (`GLIBCXX_3.4.36`, newer than
any distro's, Ubuntu 26.04's included) and the chain ONNX Runtime were neither bundled nor
declared, and the executable had no RUNPATH to its own `lib/`.

### What a package carries

`kataglyphis_install_linux_closure` in `cmake/CPackCommon.cmake` is the Linux twin of
`kataglyphis_install_package_dlls`. At install time, so in every CPack generator's staged tree and
in the flatpak's `cmake --install`, it runs the [ELF closure walker](#the-elf-closure-walker): every
library the installed files need goes to `lib/<PRIVATE_DIR>`, found through `$ORIGIN` RUNPATHs. The C++
compiler's runtime directory is searched first, since the image has two `libstdc++`. `SYSTEM` names
what the package's `Depends` bring instead (a distro's GStreamer); `PROTECT` copies the chain ORT
unpatched for G6. Never `lib/` itself: `ldconfig` would serve a bundled `libstdc++` to every
program. Only the top-level project's call counts: AccelerANTgine, embedded in OmniAccelerANT's
plugin by `add_subdirectory`, would otherwise rewrite the Flutter bundle, chain ORT included.

**Every bundled ELF needs its own `$ORIGIN` RUNPATH, because RUNPATH is not transitive.** It serves
the direct dependencies of the file that carries it, nothing else: a plugin the executable
`dlopen`s does not search the executable's `$ORIGIN/lib`, so a library that sits in the bundle but is
reachable only through the executable's RUNPATH is present and still not found (measured in
OmniAccelerANT's Flutter bundle). The closure therefore gives each user of a bundled library an
`$ORIGIN`-relative RUNPATH, and `--check` fails a file whose library is in the lib dir but not on
its own RUNPATH.

### The ELF closure walker

`06-packaging/elf-closure.sh --bundle DIR --lib-dir DIR [options]`; `python-app-closure.sh` is the
same script under the name `CPackCommon.cmake`, `python-app-bundle.sh` and the consumers call. Every
ELF in the bundle gets the libraries it lacks copied into the lib dir, under the name the loader asks
for, and by default an `$ORIGIN` RUNPATH to them.

- **Where a library comes from:** `--from SONAME-GLOB=DIR`, that directory or nowhere (the chain ORT,
  the compiler's `libstdc++`); then each `--search` in order; then `--ldconfig`, the ld.so cache.
- **`--ldd`** takes a file's libraries from `ldd` instead of its NEEDED entries: transitively, found
  where the loader finds them. A library that an excluded one needs therefore still travels.
- **Never copied:** the built-in glibc and desktop graphics list (`--no-default-system` drops it, for a
  bundle that carries its C runtime), `--system` (the package's `Depends` bring it) and `--exclude`
  (the target's own copy has to load: libcamera, whose IPA and tuning match the target's kernel).
- **`--relocatable`** counts a RUNPATH entry only inside the bundle: an image path such as
  `/opt/gstreamer/lib` resolves in the image and is dead on the target. **`--no-runpath`** copies
  and patches nothing else; **`--check`** copies nothing and fails on what a finished bundle lacks.

| Bundle | Options |
| --- | --- |
| A Flutter bundle | `--relocatable --no-runpath --no-default-system --system <its list> --from 'libonnxruntime*=<chain dir>' --from 'libstdc++.so.6=<compiler dir>' --from 'libgcc_s.so.1=<compiler dir>' --search <GStreamer libdir> --ldconfig` |
| A container-less GStreamer bundle | `--ldd --no-default-system --no-runpath --exclude 'libcamera.so.*' --exclude 'libcamera-base.so.*' --exclude 'libonnxruntime.so*'` |

Run against OmniAccelerANT's Flutter and ObservANT walkers and OxidANT's host-libcamera walker on
bundles of `:latest`'s own libraries (2026-10-19), each call above produced the same files, byte for
byte. Suite `tests/test-elf-closure.sh`; the `packaging.elf-closure-*` mutations prove it.

### glibc travels, and a newer host glibc wins

**glibc travels too, with `LOADER`** (2026-10-17). The image links against glibc 2.43, newer than
Debian 13's 2.41 and Ubuntu 24.04's 2.39. `06-packaging/bundle-loader.sh` moves each executable
into `lib/<PRIVATE_DIR>` beside the image's loader, puts glibc's libraries in its `glibc/`, and
leaves a launcher in its place.

**The launcher takes the bundled glibc only when the host's is older** (2026-10-17): it reads the
host loader's `--version`, and on the bundled version or newer it starts the program itself, under
its own name (`exec -a`). A host glibc newer than the bundled one must win, because the host's GL
drivers are built against it: the app flatpak aborted at start on org.freedesktop.Platform 26.08,
whose Mesa needs `GLIBC_2.44`, under the bundled 2.43 (`No provider of eglGetPlatformDisplayEXT
found`). The same holds for any distro newer than the image. On an older host it runs the program
through the bundled loader with `--library-path <lib>/glibc:<lib>`, as ObservANT's does; glibc sits
apart from `<lib>` so the host loader never finds it through a RUNPATH.
`KATAGLYPHIS_BUNDLED_GLIBC=1` forces that path, for a test or a host whose newer glibc misbehaves.

The bundled loader makes `/proc/self/exe` name the loader, so a program that finds its data from
there (a Flutter runner) takes `--beside`: it stays in its directory as `<name>.bin` with the loader
next to it, and only glibc goes to `<lib>/glibc`. A second run finds its own launcher and stops. The
launcher reads the host's version through a command substitution: with `read < <(...)` that child
outlived the `exec` as a stray child of the program, which Python's `forkserver` warns about. A
Python app bundle puts the same launcher on its interpreter
([`python-app-bundles.md`](python-app-bundles.md#the-images-glibc-travels)).

`LOADER` turns `dpkg-shlibdeps` off (it reads the bundled glibc as the system's and pins
`libc6 (<< 2.44)`), so `DEBIAN_DEPENDS` names what the system still brings, and hands CPack's
AppImage generator `patchelf-keep-glibc.sh`: it patches every library without a RUNPATH, and a
patched loader segfaults. AccelerANTgine's `.deb`, tarball and AppImage start on Debian 13
(himbeere2) and Ubuntu 26.04 this way. Without `LOADER` the packages need glibc 2.43: Ubuntu 26.04
and newer.

### GStreamer loads from the package alone

The family's packages carry the image's own GStreamer, never the host's (owner rule, 2026-10-17):
a host's `/usr/lib/*/gstreamer-1.0` plugins are built against another GStreamer. Four settings
make GStreamer use the package and nothing else:

| Variable | Value | Why |
| --- | --- | --- |
| `GST_PLUGIN_PATH` | the package's `gstreamer-1.0/` | the bundled plugins |
| `GST_PLUGIN_SYSTEM_PATH`, `GST_PLUGIN_SYSTEM_PATH_1_0` | empty | unset, GStreamer adds the host's plugin directories |
| `GST_REGISTRY_FORK` | `no` | no `gst-plugin-scanner` travels; GStreamer scans in-process instead of warning `External plugin loader failed` |
| `GST_REGISTRY` | one file per installed copy, under `$XDG_CACHE_HOME` | a copy never reads a registry another GStreamer wrote |

A launcher can write them (a Python app bundle's do:
[`python-app-bundles.md` § GStreamer](python-app-bundles.md#gstreamer)), or the library that starts
GStreamer sets them from an ELF constructor, each only when unset, so a user's value still wins
(AccelerANTgine's `bundled_gstreamer.cpp`, OmniAccelerANT's `runtime_paths.cc`). The plugins'
libraries come through the closure; the image reaches `/opt/gstreamer/lib`, `/opt/ffmpeg/lib` and
`/opt/libcamera/lib` only through `ld.so.conf`, so the closure's search list must name them.

`06-packaging/gstreamer-bundle.sh copy --dest DIR --plugin NAME...` copies the named plugins out of
the image (a missing `--plugin` fails, a missing `--optional` is named). `gstreamer-bundle.sh check
--plugins DIR ELEMENT...` asks the image's `gst-inspect-1.0` for each element under exactly the
environment above and fails on one that no bundled plugin provides or that loads from elsewhere. A
new element in a pipeline goes into the check's list and its plugin into the copy's, or the build
fails.

### The proof

The `clean-host-package-check` action, in a job on `ubuntu-26.04` / `ubuntu-26.04-arm` after the
lane. It installs the `.deb` with apt, which resolves `Depends` as on a user's machine, runs `ldd`
over every installed ELF, and starts a command with `LD_BIND_NOW=1`; the tarball unpacked anywhere
and the AppImage get the same. `linux/scripts/tests/test-linux-closure-install.sh` covers the CMake
function itself.

## Consumer bash libraries (`linux/scripts/lib/`)

Reusable libraries consumer repos source directly from the submodule. The full
set, one section each, is
[`shared-script-libraries.md`](shared-script-libraries.md); among them:

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
- `ctest-run.sh` — the test-phase twin of `cmake-build.sh`: runs ctest over an
  already-built tree (CI builds once and tests several: plain, ASan, TSan) with
  verbose, uploadable output.
- `docs-build.sh` — Sphinx docs build helper (not to be confused with the
  `02-toolchain/python/ci_build_docs.sh` CI helper).
- `rust-toolchain.sh` — Rust toolchain prerequisites that must not assume
  rustup (`ensure_wasm32_target`).

  (The last three were invisible until the 2026-08-08 orphan sweep: genuinely
  useful, referenced by nothing — including any doc. None of `lib/` is shipped
  into the images: no Dockerfile copies it. Consumers source it from their
  submodule, and in this repo `preflight.sh` and `flutter_checks.sh` source
  `lib/code-quality.sh`.)
