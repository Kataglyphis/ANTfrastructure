<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Documentation index — who owns which topic

**This page exists so consumer repos can link ONE hop.** A consuming project's
`AGENTS.md` should point here (or at a heading in one of these files) instead of
restating a procedure. Then reorganising the docs means fixing this page, not
hunting links across seven repositories.

Why it matters, concretely: on 2026-08-11 the Dev Drive filter command was
written out in three separate places — `windows-builds.md` here, plus
Kataglyphis-Inference-Engine's `AGENTS.md` and `docs/source/platforms.md`. All
three copies were **wrong** in the same way (unquoted filter list, missing
`/volume`), and `windows-container-build-performance.md` had the correct version
the whole time *plus* a warning that people get it wrong exactly that way.
Copying is what caused it.

## Where does a piece of knowledge belong?

One question decides it:

> **Would this still be true in a different project?**

- **Yes** → it belongs here. The consumer links to it.
- **No** → it belongs in the consumer.

The two halves of one topic often split:

| Knowledge | Owner | Why |
|---|---|---|
| How to allow the `bindFlt`/`wcifs` filters on a Dev Drive | **here** | True for any repo on a Dev Drive |
| Dart's `copySync`/`renameSync` failing on a bind mount | Inference-Engine | Only matters because that app is Flutter |
| `--isolation process` caps, and never using it for `docker build` | **here** | A property of the engine and image |
| Which CMake presets a project ships | the project | Nobody else has those presets |
| The `#requires -Version 7.0` rule for the build modules | **here** | A property of the modules |
| Which of those modules a project imports | the project | Its own build |

## Topic → owning document

### Windows

| Looking for | Read |
|---|---|
| The image itself: what is installed, entrypoint, known traps | [`windows-builds.md`](windows-builds.md) |
| **Building for Windows-on-ARM**: why there is no arm64 image, the clang-cl cross lane, arch gates | [`windows-cross-builds.md`](windows-cross-builds.md) |
| Bind mount vs tar-pipe, **Dev Drive filter setup**, container reuse, measured timings | [`windows-container-build-performance.md`](windows-container-build-performance.md) |
| **The image does not fit on C:** — moving Docker's data-root to the big drive | [`windows-container-build-performance.md`](windows-container-build-performance.md#the-image-does-not-fit-on-c-and-that-is-the-default) |
| Setting up a brand-new Windows host | [`windows-host-setup.md`](windows-host-setup.md) |
| The agentic loop's PowerShell module and its API | [`windows-agentic-loop.md`](windows-agentic-loop.md) |
| Build matrix and sanitizer env for the loop | [`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md) |

### Linux

| Looking for | Read |
|---|---|
| Building in the Linux image, presets, the basics | [`linux-build-basics.md`](linux-build-basics.md) |
| Running Linux containers on a Windows host | [`rancher-desktop-linux-containers.md`](rancher-desktop-linux-containers.md) |
| Cross-compilation chain and its stages | [`linux-cross-builds.md`](linux-cross-builds.md) |
| Failure classes seen in cross builds | [`cross-build-verification.md`](cross-build-verification.md) |
| CUDA / ROCm / accelerator image variants | [`linux-accelerator-images.md`](linux-accelerator-images.md) |
| **Setting up a Linux build host**: GPU drivers, CUDA, runtime config, performance mode, GRUB recovery | [`linux-host-setup.md`](linux-host-setup.md) |
| Hailo `.hef` compilation and Jetson board procedures | [`linux-accelerator-images.md`](linux-accelerator-images.md#edge-accelerators) |
| Raw `gst-launch-1.0` pipelines, and building GStreamer from source on a device | [`runtime-services.md`](runtime-services.md#raw-gst-launch-10-pipelines-debugging-below-the-app) |
| Detached containers, tmux, and bind-mount file ownership | [`rancher-desktop-linux-containers.md`](rancher-desktop-linux-containers.md#long-running-work-detached-containers--tmux) |
| Slow `apt update`, unattended-upgrade policy, excluding Docker from auto-upgrades | [`linux-host-setup.md`](linux-host-setup.md#phase-e--package-sources-and-automatic-updates) |
| What filled the disk, and `/tmp` exhaustion during a build | [`linux-host-setup.md`](linux-host-setup.md#finding-what-filled-the-disk) |

### Build, CI and tooling

| Looking for | Read |
|---|---|
| **Wiring a new project to this repo** — start here | [`adopting-in-a-new-project.md`](adopting-in-a-new-project.md) |
| Python CI: the shared lanes, and the two `uv` traps (`--all-extras` vs declared conflicts, `UV_PYTHON` beating the venv) | [`python-ci.md`](python-ci.md) |
| clang-format / clang-tidy / cmake-format, and the shared configs | [`code-quality-tooling.md`](code-quality-tooling.md) |
| Job counts, per-job memory, why a build got OOM-killed | [`build-parallelism-memory-tuning.md`](build-parallelism-memory-tuning.md) |
| Watching resource use during a build | [`build-resource-monitoring.md`](build-resource-monitoring.md) |
| **Giving a build a credential** without baking it into a layer | [`build-secrets.md`](build-secrets.md) |
| Finding the real error in a large build log | [`build-resource-monitoring.md`](build-resource-monitoring.md#mining-a-build-log-for-the-actual-failure) |
| Capping CPU so a build leaves the host usable | [`build-parallelism-memory-tuning.md`](build-parallelism-memory-tuning.md#capping-cpu-so-the-host-stays-usable) |
| Building on an SBC or small VM: swap, zram, forcing `-j1` | [`build-parallelism-memory-tuning.md`](build-parallelism-memory-tuning.md#the-other-end-building-on-a-memory-constrained-host) |
| **Submodule conflicts on merge**, bumping the pin, shallow fetches | [`adopting-in-a-new-project.md`](adopting-in-a-new-project.md#submodule-maintenance) |
| Opting a commit into the heavy CI lanes | [`ci-build-triggers.md`](ci-build-triggers.md) |
| Reading pipeline status from the terminal | [`github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md) |

### Also owned here, not under `docs/`

| Looking for | Where |
|---|---|
| The five shell-safety bug classes (all found live) | [`../AGENTS.md`](../AGENTS.md) § *Shell safety conventions* |
| Reusable PowerShell modules | `windows/scripts/modules/` — resolved via the consumer's `Resolve-BuildModule.ps1` |
| Reusable bash libraries | `linux/scripts/lib/` and `linux/scripts/01-core/` |
| Generic Python CI drivers | `linux/scripts/02-toolchain/python/ci_*.sh` |
| CI composite actions | [`../.github/actions/README.md`](../.github/actions/README.md) |
| Canonical `.clang-format`, `.clang-tidy`, `gcovr.cfg`, `.pre-commit-config.yaml` | [`../shared/config/README.md`](../shared/config/README.md) |
| Copy-and-edit templates (`Resolve-BuildModule.ps1`, `containerhub.sh`, `AGENTS.md` skeleton, agentic-loop config) | [`../shared/windows/templates/`](../shared/windows/templates/README.md), [`../shared/linux/templates/`](../shared/linux/templates/README.md), `../shared/templates/`, `../shared/agentic-loop/templates/` |
| Reusable CI workflows (`workflow_call`) — the Python Linux lane, docs build | [`../.github/workflows/python-ci-linux.yml`](../.github/workflows/python-ci-linux.yml), `../.github/workflows/build-docs.yml` |

## If you are about to write a procedure in a consumer repo

Check this page first. If the topic is listed, link instead — one sentence of
orientation plus the link, then whatever is genuinely specific to your project.
Kataglyphis-BeschleunigerBallett's `AGENTS.md` does this well: it states the
Dev Drive command and its one gotcha, links here for setup/verify/revert, and
keeps only *its own measured transport numbers* locally.
