<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.svg" alt="ANTfrastructure logo: an ant hauling a shipping container" width="200" />
  </a>

  <h1>ANTfrastructure</h1>

  <h4>The build images, CI actions, reusable workflows and quality gates every Kataglyphis repository builds on.</h4>
</div>

[![Linux x64](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/linux-x64.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/linux-x64.yml)
[![Windows x64](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/windows-x64.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/windows-x64.yml)
[![Windows arm64](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/windows-arm64.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/windows-arm64.yml)
[![GHCR cleanup](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ghcr-cleanup.yml)
[![Consumers inventory](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/consumer-inventory.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/consumer-inventory.yml)
[![Composite actions self-test](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/actions-selftest.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/actions-selftest.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)

[**Docs site**](https://containerization.jonasheinle.de)

Prebuilt container images and the build system that produces them: a multi-arch Linux stack (`amd64`/`arm64`/`riscv64`)
with GCC, LLVM/Clang, Vulkan and a full media and inference layer; a slim nginx webserver; and a Windows Server Core
build image with MSVC, CUDA and the same media stack, plus a cross-built arm64 artifact bundle. Around them sit the
composite actions, reusable workflows, shell libraries and gates every repository of the family calls at `@develop`.

## Highlights

- **One multi-arch `:latest`** for Linux: ONNX Runtime (+GenAI), OpenCV, FFmpeg, GStreamer, LiteRT, TVM, IREE.
- **A Windows build image**, `:winamd64`, with MSVC, clang-cl, DirectML and HailoRT; `:winarm64` is its arm64 bundle.
- **Accelerators**: Hailo-10H in `:latest`, CUDA and DeepStream in `:latest-nvidia`, MIGraphX in `:latest-rocm`.
- **The family's CI surface**: composite actions and reusable workflows, called at `@develop`.
- **Gates that fail loudly**: a shell preflight, a mutation gate that proves each gate can go red, runtime smokes.
- **Home-lab stacks, deliberately here**: an Ollama + Open WebUI server, Home Assistant, Nextcloud AIO, Ansible.

## Quick start

```bash
# use the image; its default CMD is a shell
nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest

git clone --recurse-submodules --branch develop https://github.com/Kataglyphis/ANTfrastructure.git
cd ANTfrastructure
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs
```

```pwsh
.\windows\Build-Buildkit.ps1          # the Windows image, :winamd64 (non-admin shell; -Gpu for :winamd64-nvidia)
```

A fresh host starts at [Linux Host Setup](docs/linux-host-setup.md) or [Windows Host Setup](docs/windows-host-setup.md).

## Published images

Registry `ghcr.io/kataglyphis/kataglyphis_beschleuniger`, one manifest per tag over every architecture of its variant
([AGENTS.md § Image and tag naming](AGENTS.md#image-and-tag-naming-published-tags)). Every tag, the accelerator matrix and the GPUs `:latest-nvidia` runs on: [docs/overview.md](docs/overview.md#published-images-and-tag-hints).

| Tag | What |
| --- | --- |
| `:latest` | Linux **manifest** over amd64, arm64 and riscv64; the Hailo runtime on amd64 and arm64 |
| `:latest-nvidia` | CUDA, cuDNN and DeepStream 9.1, amd64 |
| `:latest-rocm` | ROCm and MIGraphX, amd64 |
| `:winamd64` | Windows **manifest** (`windows/amd64`), CPU + DirectML; `:winamd64-nvidia`, `:winamd64-rocm` |
| `:winarm64` | Windows arm64 **artifact bundle**: a `windows/amd64` image, never `--platform windows/arm64` |

## Documentation

| I want to… | Read |
| --- | --- |
| Find the page that owns a topic | [docs/INDEX.md](docs/INDEX.md) |
| Wire a new project or reuse shared helpers | [Adoption](docs/adopting-in-a-new-project.md) · [Shared libraries](docs/shared-script-libraries.md) |
| Upgrade dependencies, Renovate as a local CLI | [docs/dependency-updates.md](docs/dependency-updates.md) |
| See what is published, how the chain is laid out, what is in it | [docs/overview.md](docs/overview.md) |
| Build and accept the Linux images | [Basics](docs/linux-build-basics.md) · [Cross builds](docs/linux-cross-builds.md) · [Accelerators](docs/linux-accelerator-images.md) · [Consumer acceptance](docs/image-acceptance.md) |
| Build the Windows image, and its arm64 bundle | [docs/windows-builds.md](docs/windows-builds.md) · [docs/windows-build-lanes.md](docs/windows-build-lanes.md) · [docs/windows-cross-builds.md](docs/windows-cross-builds.md) · [ROCm details](docs/windows-rocm.md) |
| Look up an error message | [docs/failure-modes.md](docs/failure-modes.md) |
| Know which workflow runs when | [docs/ci-build-triggers.md](docs/ci-build-triggers.md) |
| Know every quality gate, the exception policy and shared build behavior | [Quality tooling](docs/code-quality-tooling.md#the-allowlist-contract) · [Gate registry](docs/code-quality-gates.md) · [Test worker cleanup](docs/code-quality-tooling.md#the-gates-run-side-by-side) · [Linux paths, CLI, compiler and wheel helpers](docs/shared-script-libraries.md) · [Windows dependency graphs, bounded TCP probes and fixtures](docs/windows-builds.md#shared-windows-behavior) |
| Know what is inside an image, and under which licence | [docs/third-party-licenses.md](docs/third-party-licenses.md) · [docs/sbom.md](docs/sbom.md) · [docs/vulnerability-scanning.md](docs/vulnerability-scanning.md) |
| Serve LLMs on the family's reference server | [linux/llm-stack/README.md](linux/llm-stack/README.md) |
| Run a coding agent on-device on a Snapdragon (GenieX) | [docs/geniex-local-ai-setup.md](docs/geniex-local-ai-setup.md) |
| Rules for agents and contributors | [AGENTS.md](AGENTS.md) · [docs/windows-build-invariants.md](docs/windows-build-invariants.md) |
| Known work, and what changed | [BACKLOG.md](BACKLOG.md) · [CHANGELOG.md](CHANGELOG.md) |

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 23.1.3, GCC 16, CMake 4.4.4, Vulkan SDK 1.4.363.0 |
| Android layer | Android SDK 15859902, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 26.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.363.0, GStreamer 1.29.2, CUDA 13.4.3, ONNX Runtime v1.31.0 |
<!-- generated:version-snapshot:end -->

## Contributing and contact

ANTfrastructure is one of the [Kataglyphis repositories](docs/repository-family.md), which share one way to contribute
and one contact. Here: `make hooks` once, `make preflight` before a push ([AGENTS.md § Validation](AGENTS.md#validation)). Licence: MIT, see [LICENSE](LICENSE).
