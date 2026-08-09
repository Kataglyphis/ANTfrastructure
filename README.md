<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>Kataglyphis-ContainerHub</h1>

  <h4>Docker templates for GPU-friendly Linux dev stacks, a slim nginx webserver, and a Windows build image.</h4>
</div>

> add the current user to the docker group so you can push to ghcr.io without sudo:
> `sudo usermod -aG docker $USER`

[![CI](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml)
[![ghcr-cleanup](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)

---

## Engineering principles

This build system optimizes for three goals **at once** — never one at the
expense of the others:

- **Speed** — layered caching end-to-end (BuildKit layers with narrow cache
  keys, local cache exports, the ccache/sccache HYBRID — ccache for C/C++,
  sccache for Rust; layer cache and compiler cache multiply, they don't
  compete — pinned buildkitd GC budget) and opt-in parallelism levers. Map: [`docs/linux-build-basics.md`
  § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where).
  That map is the **Linux** lane. The **Windows** lane caches by deliberate
  layer ordering plus a two-tier sccache (local `disk` L0 in front of the
  WebDAV L2) covering C/C++ **and** CUDA, and a uv/pip wheel cache — see
  [`AGENTS.md` § Caching discipline](AGENTS.md) rule 5, which also records why
  sccache is built from source there (released builds cannot wrap `nvcc` on
  CUDA 13.3).
- **Stability** — digest-pinned stage handoffs, machine-checked cross-run
  ancestry (`org.kataglyphis.parent-digest` manifest annotations), verified
  version pins in a single source of truth (`linux/scripts/01-core/versions.env`),
  and gates that fail loudly instead of passing on fallbacks.
- **Tests** — unit suites (`linux/scripts/tests/`), lint gates (shellcheck,
  IFS-safety, hadolint, actionlint), a fast preflight
  (`linux/scripts/preflight.sh`) that catches error classes in seconds instead
  of hours, and runtime smokes that assert real behavior against the pins.

Rules an automated agent must follow live in [`AGENTS.md`](AGENTS.md)
(§ Project priorities, § Shell safety conventions, § Caching discipline).

## Architecture

Four-tier dependency chain with shared script tree:

```
linux/
├── Dockerfile.base          ubuntu:26.04 + CMake/Node/uv
├── Dockerfile.toolchain     GCC 16.2.0 + LLVM/Clang 22.1.8 + Python 3.14 (FROM base)
├── Dockerfile.sdk           Vulkan SDK + TVM (FROM toolchain)
├── Dockerfile.media         ONNX Runtime · LiteRT · OpenCV · FFmpeg · GStreamer · libcamera (FROM sdk)
├── Dockerfile.android       Android SDK/NDK + native GCC swap (FROM media)
├── Dockerfile.package       lean runtime assembly + validation (FROM base + android)
├── Dockerfile.torch         final wrapper: entrypoint, labels, runtime scripts (FROM package)
├── Dockerfile.nvidia        optional CUDA/cuDNN/TensorRT layer (FROM sdk)
├── Dockerfile.amd           optional MIGraphX layer (FROM sdk)
└── scripts/
    ├── 01-core/             shared utilities — the maintained list lives in AGENTS.md § Repo Map
    ├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
    ├── 03-media/            media library build scripts
    │   ├── core/common.sh   single DRY bootstrap — sourced by every media script
    │   ├── build/           per-library build scripts (onnxruntime, litert, opencv, ffmpeg, gstreamer, libcamera)
    │   └── runtime/         artifact collection, runtime config, verification, media-env.sh
    ├── 04-runtime/          entrypoint + env scripts
    ├── 05-frameworks/       TVM, Torch, Flutter
    └── 06-packaging/        assembly + smoke tests
```

### 4-Tier Build Dependency Graph

```
  Phase 1     Phase 2      Phase 3       Phase 4
  ───────     ───────      ───────       ───────
  Base   →   Compiler  →   SDK      →    Media
  (amd64)    (amd64)       (per-arch)    (per-arch)
                                          ↓
                                     Android (optional)
                                          ↓
                                     Package + Torch (optional)
```

**Cross lane** (`linux/amd64` host, cross-compiles all arches): `base → compiler → sdk → media → android → package → torch`
**Runtime lane** (native/QEMU per arch): `base → package → wrapper`
**Windows lane** (native Windows Containers): `base → sdk → toolchain → media → torch → final` — built via **BuildKit + containerd with process isolation** (the preferred lane since 2026-08: full host CPUs, real layer caching; `windows/build-buildkit.ps1`), with the docker-classic Hyper-V run+commit lane (`windows/build.ps1`) as fallback. The lane runs **direct solves** on every stage: the host snapshotter defect that used to break heavy media layers (`ExportLayer 0x3` on heavy-churn container finalize) was root-caused on 2026-08-06 to a hardcoded 30 s teardown timeout in the containerd runhcs shim — it terminated a teardown that takes ~117 s for OpenCV, permanently poisoning the scratch disk — and is fixed by a locally patched shim, submitted upstream as [microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855). **Every Stevedore/containerd update reverts that patch**, so `windows/scripts/deploy-shim-patch.ps1 -ReportOnly` belongs in your post-update routine. The older warm/materialize workaround is retired (kept in git history as the rollback path), and the Defender exclusions remain load-bearing for a separate family of transient finalize flakes — see [`docs/windows-builds.md`](docs/windows-builds.md) § BuildKit/containerd lane and [`docs/windows-host-setup.md`](docs/windows-host-setup.md) C4. **Two client lanes are supported:** `buildctl` builds the chain from a normal shell (buildkitd is ACL'd to `docker-users`), while `nerdctl` — from an **admin** shell, since containerd's pipe is Administrator-only upstream — runs, inspects and administers the resulting images, and can build as well; recipes in [`docs/windows-builds.md`](docs/windows-builds.md) § nerdctl lane. On hosts where build-`COPY`-into-layer is broken (root-caused 2026-08-09 to a FAULTY AMD ADRENALINE install — a reinstall fixes it, GPU-disable does not; see AGENTS.md Common Failure Modes), the docker-classic **run+commit** lane still works (CommitLayer) and is the partial fallback - see docs/windows-builds.md § Build isolation and CPU parallelism.

Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows: `windows/amd64`.

## Published Images

Registry: `ghcr.io/kataglyphis/kataglyphis_beschleuniger`

| Tag | What |
|-----|------|
| `:latest-cross` | Multi-arch release (amd64/arm64/riscv64) — the stable API |
| `:latest-cross-<arch>` | Per-architecture wrapper |
| `:cross-media-<arch>` | Media libraries layer (ONNX Runtime, LiteRT, OpenCV, FFmpeg, GStreamer, libcamera) |
| `:webserver` | Slim nginx webserver |
| `:winamd64` | Windows build image |

## Build the Full Cross Chain Locally

Build logs are written to `out/build-logs/` by passing `--log-dir` to `build-cross-chain.sh` or `build-cross-stage.sh`; for the other orchestrators, pipe output through `2>&1 | tee ./out/build-logs/<name>.log`.
See `AGENTS.md` § Quick Reference for the canonical build commands (orchestrator, single-stage, compiler, verification, dry-run).

Caching is layered end-to-end (BuildKit layers, per-stage local cache exports,
ccache for GCC/LLVM/media, apt/cargo/uv mounts, shared source caches, and a
pinned buildkitd GC budget) — see
[`docs/linux-build-basics.md` § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where)
for the full map and the one process rule that matters: freeze the toolchain
closures between chain runs that should cache-hit each other. (Note:
`--no-push` full-chain runs are broken on OCI-worker hosts — see
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) for the correct
push-mode flow.)

## Reinstall QEMU/binfmt After a Host Reboot

If foreign-architecture builds fail with `exec format error`:

- **Rootless hosts (this repo's primary dev host):** run
  `linux/scripts/setup-rootless-binfmt.sh` (idempotent; `--install-service`
  makes it persistent). A plain `nerdctl run --privileged tonistiigi/binfmt`
  does **not** work rootless — it registers inside its own ephemeral user
  namespace, which vanishes on exit. `build-runtime-manifest.sh` invokes the
  helper automatically for non-native target arches.
- **Rootful Docker/containerd hosts:** the classic
  `docker run --rm --privileged tonistiigi/binfmt --install all` works.

Details: [`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Host prerequisite.

## LLM Stack

An Ollama + Open WebUI serving stack lives in
[`linux/llm-stack/`](linux/llm-stack/README.md) — CPU-only by default, with an
opt-in GPU override (`docker-compose.gpu.yml`) for NVIDIA machines. Docs
include a VRAM/context sizing table so a 256K-listed model is only configured
at a context the GPUs can actually hold.

## CI

| Workflow | Purpose |
|----------|---------|
| `ubuntu24.04.yml` | Trigger on push/PR: Sphinx docs + version-consistency checks |
| `build-docs.yml` | Reusable workflow for docs build |
| `ghcr-cleanup.yml` | Retains last 3 per tag, 14-day safety net |
| `stale-docs-check.yml` | Scheduled scan for stale doc references and broken script paths |

## Documentation

| Topic | Doc |
|-------|-----|
| **Wiring a new project to this repo (start here)** | [docs/adopting-in-a-new-project.md](docs/adopting-in-a-new-project.md) |
| Published images, feature snapshot | [docs/overview.md](docs/overview.md) |
| Local runs, multi-arch, buildx, mirrors | [docs/linux-build-basics.md](docs/linux-build-basics.md) |
| Cross-compiler lane, artifacts, manifest publishing | [docs/linux-cross-builds.md](docs/linux-cross-builds.md) |
| NVIDIA / AMD / Torch variants | [docs/linux-accelerator-images.md](docs/linux-accelerator-images.md) |
| Webserver, display forwarding, WebRTC | [docs/runtime-services.md](docs/runtime-services.md) |
| Windows containers | [docs/windows-builds.md](docs/windows-builds.md) |
| **New Windows machine? Ordered bring-up checklist (host + gates)** | [docs/windows-host-setup.md](docs/windows-host-setup.md) |
| Building consumer projects inside the Windows image (reuse pattern, transports) | [docs/windows-container-build-performance.md](docs/windows-container-build-performance.md) |
| Reusable CI composite actions (run-in-*-container, cleanup-disk-space) | [.github/actions/README.md](.github/actions/README.md) |
| MSIX certificates: generation, import, WebDAV retrieval | [windows/scripts/certificates/README.md](windows/scripts/certificates/README.md) |
| Prerequisites, tests, troubleshooting | [docs/project-info.md](docs/project-info.md) |
| Third-party licenses | [docs/third-party-licenses.md](docs/third-party-licenses.md) |

**Agent context:** see [AGENTS.md](AGENTS.md) for the build-system guardrails, critical fixes, and script-organization rules that LLM agents must follow.

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 22.1.8, GCC 16, CMake 4.4.2, Vulkan SDK 1.4.357.0 |
| Android layer | Android SDK 15859902, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 26.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.357.0, GStreamer 1.29.2, CUDA 13.3.1, ONNX Runtime v1.28.0 |
<!-- generated:version-snapshot:end -->

## Quick Start 🏁

### Linux 🐧

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
```

If you run the container from Windows, expose required ports explicitly, for example with `-p 8443:8443`.

Detailed Linux build workflows live in [Linux Build Basics](docs/linux-build-basics.md), [Linux Cross Builds](docs/linux-cross-builds.md), and [Linux Accelerator Images](docs/linux-accelerator-images.md).

### Windows 🪟

The Windows toolchain is **containerd + BuildKit + nerdctl** (process isolation,
full host CPUs, real layer caching — one-time setup in
[Windows Build Image](docs/windows-builds.md) § BuildKit/containerd lane;
**fresh machine? start at [docs/windows-host-setup.md](docs/windows-host-setup.md)** — once Stevedore is in and the host rebooted, the scriptable half of bring-up is one elevated run (`windows\scripts\setup-new-host.ps1`; `-ReportOnly` first):

```pwsh
# BUILD (non-admin shell; buildctl against buildkitd):
.\windows\build-buildkit.ps1 -Gpu

# INSPECT / RUN the built images (ADMIN shell; nerdctl against containerd —
# containerd's pipe is admin-only upstream, build stays non-admin):
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit images
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit run --rm `
    docker.io/local/kataglyphis:bk-windows-media-core pwsh -c "python -c 'import onnxruntime'"
```

Fallback (docker classic, Hyper-V run+commit — for hosts without the BuildKit
setup) and all further commands: [Windows Build Image](docs/windows-builds.md)
§ Build Commands.

> **Host with a broken BK lane (`hcsshim::ActivateLayer 0x20` on `COPY`/layer
> commit, both engines)?** Run the committed 3-layer probe first
> (`windows\scripts\probe-build-copy.ps1`), then **reinstall a faulty AMD
> Adrenaline install** (GPU+chipset; GPU-disable is NOT the fix), and if
> multi-layer commits still fail, do a **Windows in-place repair upgrade**
> (official ISO, same build, keep files+apps). Residual export-time 0x20 on a
> single host = host-residual: use the classic lane there or the healthy host.
> Full evidence: AGENTS.md Common Failure Modes.

### Clone The Repository

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
```

### License

MIT — see [`LICENSE`](LICENSE). Every source file carries a matching
`SPDX-License-Identifier: MIT` header and the published images declare
`org.opencontainers.image.licenses="MIT"`.

Bundled upstream software keeps its own terms: see
[docs/third-party-licenses.md](docs/third-party-licenses.md).
