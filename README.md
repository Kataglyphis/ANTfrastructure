<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>Kataglyphis-ContainerHub</h1>

  <h4>Docker templates for GPU-friendly Linux dev stacks, a slim nginx webserver, and a Windows build image.</h4>
</div>

[![CI](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml)
[![ghcr-cleanup](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)

---

Prebuilt container images and the build system that produces them: a multi-arch
Linux stack (`amd64`/`arm64`/`riscv64`) carrying GCC, LLVM/Clang, Vulkan and a
full media/inference layer (ONNX Runtime, OpenCV, FFmpeg, GStreamer, LiteRT,
TVM, IREE — riscv64 carries two documented exemptions, listed in AGENTS.md's
Linux build rules); a slim nginx webserver; and a Windows Server Core build image with
MSVC, CUDA and the same media stack.

Pull an image and start working, or build the chain yourself — both are below.

## Quick Start 🏁

### Linux 🐧

```bash
nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross

# The default CMD is a shell — nothing listens until you start a server.
# Publishing 8443 only helps once one is running inside; the separate
# :webserver image is the one that serves HTTP, on 80/443.
nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
```

Rootful nerdctl needs `sudo`. The sudo-less route is the rootless
containerd + BuildKit stack this repo builds with — not the `docker` group,
which nerdctl never consults (containerd's socket is `root:root 0660`).

Build workflows: [Linux Build Basics](docs/linux-build-basics.md) ·
[Linux Cross Builds](docs/linux-cross-builds.md) ·
[Linux Accelerator Images](docs/linux-accelerator-images.md).
**Fresh host?** Start at [Linux Host Setup](docs/linux-host-setup.md).

### Windows 🪟

The toolchain is **containerd + BuildKit + nerdctl** with process isolation.

```pwsh
# BUILD — non-admin shell, buildctl against buildkitd
.\windows\build-buildkit.ps1 -Gpu

# INSPECT / RUN — ADMIN shell; containerd's pipe is admin-only upstream
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit images
```

**Fresh machine?** Start at [Windows Host Setup](docs/windows-host-setup.md) —
after Stevedore and a reboot, the scriptable half of bring-up is one elevated
run of `windows\scripts\host\setup-new-host.ps1` (`-ReportOnly` first).

Lane mechanics, why the classic-docker lane was removed, and every host gate:
[Windows Build Lanes](docs/windows-build-lanes.md).

### Clone the repository

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
```

### If something fails on first touch

Look the error message up in
**[docs/failure-modes.md](docs/failure-modes.md)** — symptom, cause and fix for
every failure this repo has hit live, on both lanes. The two that catch people
first:

- `exec format error` on a foreign arch — QEMU/binfmt is not registered
  ([fix](docs/failure-modes.md#exec-format-error-on-a-foreign-arch-build)).
- `hcsshim::ActivateLayer 0x20` on a Windows host with an **AMD RDNA4 dGPU** —
  build inside the toggle window
  ([fix](docs/failure-modes.md#hcsshimactivatelayer-0x20-on-an-amd-radeon-host)).
- Every Windows RUN step takes the **same implausible time** (e.g. `DONE 2841.2s`)
  regardless of what it runs — the container's exit notification is lost and the
  shim waits out its whole teardown timeout; cap it via the shim's env knob
  ([diagnosis](docs/failure-modes.md#every-run-step-reports-done-28412s--the-same-number-whatever-it-runs)).

## Documentation

**[docs/INDEX.md](docs/INDEX.md) is the map** — topic to owning document, for
this repo and for every project that consumes it. Start there; it is also what
a consumer repo should link to instead of restating a procedure.

The entry points people actually want:

| I want to… | Read |
|---|---|
| **Wire a new project to this repo** | [docs/adopting-in-a-new-project.md](docs/adopting-in-a-new-project.md) |
| See what is published and what is in it | [docs/overview.md](docs/overview.md) |
| Build the Linux images | [docs/linux-build-basics.md](docs/linux-build-basics.md) |
| Build the Windows image | [docs/windows-builds.md](docs/windows-builds.md) |
| Look up an error message | [docs/failure-modes.md](docs/failure-modes.md) |
| Know what is inside an image, and under which licence | [docs/third-party-licenses.md](docs/third-party-licenses.md) · [docs/sbom.md](docs/sbom.md) · [docs/vulnerability-scanning.md](docs/vulnerability-scanning.md) |
| Run a coding agent fully on-device on a Snapdragon (GenieX, OpenAI-compatible) | [docs/geniex-local-ai-setup.md](docs/geniex-local-ai-setup.md) |

**Working on this repo as an automated agent?** [`AGENTS.md`](AGENTS.md) holds
the guardrails: project priorities, the canonical build commands, shell-safety
conventions, caching discipline and the repo map. Windows-specific rules are
[docs/windows-build-invariants.md](docs/windows-build-invariants.md).

## Published images

Registry: `ghcr.io/kataglyphis/kataglyphis_beschleuniger`

| Tag | What |
|-----|------|
| `:latest-cross` | Multi-arch release index (amd64/arm64/riscv64) — the stable API |
| `:latest-cross-<arch>` | Per-architecture wrapper |
| `:cross-media-<arch>` | Media libraries layer |
| `:webserver` | Slim nginx webserver |
| `:winamd64` | Windows build image |

Full matrix with platforms, tag hints and per-stage intermediates:
[docs/overview.md](docs/overview.md).

**Check the live index before relying on its arch coverage** —
`nerdctl manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
On 2026-08-31 it carried **riscv64 only**: a single-arch run had replaced the
3-arch index. `build-runtime-manifest.sh` now refuses to shrink an already
published index (`--force`, or `RUNTIME_MANIFEST_COMPLETENESS=0`, overrides), so
a partial run cannot do it again —
[docs/cross-build-verification.md](docs/cross-build-verification.md). The next full-fanout
run restores all three arches.

## Architecture

Multi-stage chain, one Dockerfile per stage, so BuildKit caches the expensive
layers and rebuilds only what changed.

```
linux/
├── Dockerfile.base          ubuntu:26.04 + CMake/Node/uv
├── Dockerfile.toolchain     GCC + LLVM/Clang + Python (FROM base)
├── Dockerfile.sdk           Vulkan SDK + Flutter (FROM toolchain)
├── Dockerfile.media         ONNX Runtime (+GenAI) · LiteRT · OpenCV · FFmpeg · GStreamer · libcamera · TVM · IREE · Arm NN (FROM sdk)
├── Dockerfile.android       Android SDK/NDK + native GCC swap (FROM media)
├── Dockerfile.package       lean runtime assembly + validation (FROM base + android)
├── Dockerfile.torch         final wrapper: entrypoint, labels, runtime scripts (FROM package)
├── Dockerfile.nvidia        optional CUDA/cuDNN/TensorRT layer (FROM sdk)
├── Dockerfile.amd           optional MIGraphX layer (FROM sdk)
└── scripts/                 01-core … 06-packaging — see AGENTS.md § Repo Map
```

```
  Phase 1     Phase 2      Phase 3       Phase 4
  ───────     ───────      ───────       ───────
  Base   →   Compiler  →   SDK      →    Media
  (amd64)    (amd64)       (per-arch)    (per-arch)
                                          ↓
                                     Android
                                          ↓
                                     Package + Torch (runtime lane)
```

Three lanes:

- **Cross** (`linux/amd64` host, cross-compiles every arch):
  `base → compiler → sdk → media → android → runtime` (`CROSS_STAGE_ORDER`).
  The runtime stage is where `package`/`wrapper` get built, with the android
  image as their artifact source — so android is not optional.
- **Runtime** (native or QEMU per arch): `base → package → wrapper`
- **Windows** (native Windows Containers):
  `base → sdk → toolchain → media → torch → final`

Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows **host**:
`windows/amd64`.

> **riscv64 `onnxruntime-genai` is self-built and UNVALIDATED.** Upstream ships
> no riscv64 wheel and runs no riscv64 CI, so the cross lane builds it from
> source (toggle `GENAI_ALLOW_RISCV64`, default on). A real riscv64 build has
> since **compiled and linked it and produced a `linux_riscv64` wheel**; what is
> still unproven is whether `generate()` emits sane tokens — upstream's one
> RISC-V field report compiled, imported and emitted nonsense.
> The patch, the gates and the first-build watch list:
> [docs/gen1-riscv64-genai.md](docs/gen1-riscv64-genai.md).

> **Windows-on-ARM is a cross target, not an image.** Microsoft publishes no
> arm64 `servercore`/`nanoserver` base and Windows Server has no arm64 release,
> so a *runnable* arm64 Windows container cannot exist
> ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)).
> The lane cross-compiles inside the same `windows/amd64` container with
> `clang-cl --target=aarch64-pc-windows-msvc` and emits an **artifact bundle**.
> Its `:winarm64` tag labels a `windows/amd64` image, so it must never be
> published with `--platform windows/arm64`. Current status, coverage and gates:
> [docs/windows-cross-builds.md](docs/windows-cross-builds.md).
>
> **Re-measured 2026-08-29** — both lanes build green (amd64 smoke 192/0/1,
> arch gate 1134/0; arm64 smoke 97/0/15, arch gate 992/0). The patched LLVM
> toolchain (#135, `BUILD_PATCHED_LLVM=1`) is now the default — the AArch64
> workarounds have been removed. The Qualcomm QNN SDK (QAIRT 2.31.0) is
> staged in `windows/qnn-sdk/` and wired into ONNX Runtime, GenAI, LiteRT,
> TVM, and IREE (QAIRT 2.44.0, QNN API 2.33.0 — compatible with ORT 1.29). See
> [`docs/windows-cross-builds.md`](docs/windows-cross-builds.md) § QNN.

## Engineering principles

Three goals, optimized **at once** — never one at the expense of the others:
**speed** (layered caching end-to-end plus opt-in parallelism levers),
**stability** (digest-pinned handoffs, machine-checked ancestry, gates that
fail loudly instead of passing on fallbacks) and **tests** (unit suites, lint
gates, a fast preflight, and runtime smokes that assert real behavior against
the pins).

The rules that implement them — each carrying the incident that produced it —
are [`AGENTS.md` § Project priorities](AGENTS.md).
Caching is mapped in
[docs/linux-build-basics.md § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where)
for Linux and in
[docs/windows-build-resources.md](docs/windows-build-resources.md) for Windows.

## LLM stack

An Ollama + Open WebUI serving stack lives in
[`linux/llm-stack/`](linux/llm-stack/README.md) — CPU-only by default, with an
opt-in GPU override for NVIDIA machines, and a VRAM/context sizing table so a
256K-listed model is only configured at a context the GPUs can actually hold.

It also carries the **measurement tooling** for any OpenAI-compatible server,
not just its own. Endpoints are named in `backends.json` (`ollama` is the
default; the Snapdragon GenieX lanes are listed too), so a sweep can be pointed
at another backend without editing anything:

| Tool | Answers |
|---|---|
| [`benchmark_openai_api.py`](linux/llm-stack/benchmark_openai_api.py) | How fast — and, with `--correctness`, **whether the model is working at all** |
| [`bench_lanes.py`](linux/llm-stack/bench_lanes.py) | Does one server batch concurrent requests? Do several servers add up, or fight? |
| [`inspect_gguf.py`](linux/llm-stack/inspect_gguf.py) | Is this GGUF sane? (tensor-type histogram, header-only read) |

The correctness probe exists because **a broken model is fast**: sub-4-bit
i-quant kernels on one runtime produced fluent nonsense that every throughput
metric rated as an excellent run. Speed alone cannot tell a working model from
a broken one, so `run_benchmarks.sh` gates its sweep on a verifiable-answer
check before spending hours measuring.

## CI

| Workflow | Purpose |
|----------|---------|
| `ubuntu24.04.yml` | On push/PR: the shell preflight gate suite + docs validation/build |
| `build-docs.yml` | Reusable workflow for docs build |
| `windows-scripts.yml` | PowerShell lint + the `windows/scripts/tests` suite |
| `python-ci-linux.yml` | Reusable (`workflow_call`) — Python lint/tests on Linux, for consumer repos; never triggers here |
| `python-ci-windows.yml` | Reusable (`workflow_call`) — the same for Windows |
| `llm-stack-tests.yml` | Push/PR, path-filtered on `linux/llm-stack/**` |
| `ghcr-cleanup.yml` | Scheduled (Sundays): retains last 3 per tag, 14-day safety net |
| `sbom.yml` | Scheduled (Mondays): SBOM generation |
| `stale-docs-check.yml` | Scheduled (Mondays): stale doc references and broken script paths |

**Contributing?** Run `make hooks` once. It installs a pre-commit gate that
costs **~4 seconds**: the cheap whole-tree checks, `shellcheck` on the shell
files you actually staged, and the doc gates only when you touched `docs/`. It
is a deliberate subset — the full suite takes minutes (the secret scan alone is
~170 s), and a hook that slow just teaches everyone to type `--no-verify`. Run
`make preflight` yourself before a rebuild or a push; CI runs it on every push
regardless.

The first row's suite is `bash linux/scripts/preflight.sh`. Newest gates in it
(2026-09-01): **`pkg-names`** resolves every package name the tree asks apt for
against the live Ubuntu indices, and **`advert-keys`** fails when a
version-shaped `ENV`/`ARG` is neither checked by the runtime smoke nor excused
with a reason. Before them, **`code-dupes`** — token-normalised duplication over
shell, Dockerfiles and the Markdown outside `docs/`, so it catches *renamed*
clones the prose gate cannot see; deliberate twins are budgeted in
`docs/scripts/code-dupes.allow`.

**None of these builds a container image.** The image lanes are not CI here —
they run on the build host (`windows/build-buildkit.ps1`, `linux/scripts/…`).
The `[build-win]` / `[build-arm]` commit-message opt-ins are the convention of
the *consuming* application repos, not of this one: no workflow above reacts to
those tokens. See [docs/ci-build-triggers.md](docs/ci-build-triggers.md), which
says so in its own opening note.

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 23.1.0, GCC 16, CMake 4.4.3, Vulkan SDK 1.4.357.0 |
| Android layer | Android SDK 15859902, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 26.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.357.0, GStreamer 1.29.2, CUDA 13.3.1, ONNX Runtime v1.29.0 |
<!-- generated:version-snapshot:end -->

## License

MIT — see [`LICENSE`](LICENSE). Every source file carries a matching
`SPDX-License-Identifier: MIT` header and the published images declare
`org.opencontainers.image.licenses="MIT"`.

Bundled upstream software keeps its own terms:
[docs/third-party-licenses.md](docs/third-party-licenses.md).
