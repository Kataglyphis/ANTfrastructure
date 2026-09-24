<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>ANTfrastructure</h1>

  <h4>Multi-arch build images (Linux amd64/arm64/riscv64, a slim nginx webserver, Windows Server Core) plus the shared CI actions, reusable workflows, build/quality gates and agentic-loop tooling every Kataglyphis repo consumes.</h4>
</div>

[![CI](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ubuntu26.04.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ubuntu26.04.yml)
[![ghcr-cleanup](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/ghcr-cleanup.yml)
[![Consumer Inventory](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/consumer-inventory.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/consumer-inventory.yml)
[![Composite actions self-test](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/actions-selftest.yml/badge.svg)](https://github.com/Kataglyphis/ANTfrastructure/actions/workflows/actions-selftest.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)

---

Prebuilt container images and the build system that produces them: a multi-arch
Linux stack (`amd64`/`arm64`/`riscv64`) carrying GCC, LLVM/Clang, Vulkan and a
full media/inference layer (ONNX Runtime, OpenCV, FFmpeg, GStreamer, LiteRT,
TVM, IREE — riscv64 carries two documented exemptions, listed in AGENTS.md's
Linux build rules); a slim nginx webserver; and a Windows Server Core build image
with MSVC, CUDA and the same media stack, plus **HailoRT** and a **cross-built
arm64 artifact bundle** (CUDA/cuDNN, GenAI, OpenCV CUDA, TVM, HailoRT).

Pull an image and start working, or build the chain yourself — both are below.

## Quick Start 🏁

### Linux 🐧

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
stack can also be *installed* without sudo, into `$HOME/.local`.

Build workflows: [Linux Build Basics](docs/linux-build-basics.md) ·
[Linux Cross Builds](docs/linux-cross-builds.md) ·
[Linux Accelerator Images](docs/linux-accelerator-images.md).
**Fresh host?** Start at [Linux Host Setup](docs/linux-host-setup.md). The
container stack installs from the nerdctl-full bundle — rootless, into
`$HOME/.local`, no sudo: [B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).

### NVIDIA on arm64: Arm GPU servers and Jetson 🟩

The Linux chain also builds natively on an arm64 host with NVIDIA's **SBSA**
CUDA, cuDNN and NCCL — one image for an Arm server GPU and a Jetson. Built
end to end on a Jetson AGX Orin and run on its GPU: PyTorch, the ONNX Runtime
CUDA EP, OpenCV CUDA, and a USB-camera detection demo at 30 fps
([`linux/jetson-webcam/`](linux/jetson-webcam/README.md)). Not yet published
to ghcr; how to build it and what is still open:
[NVIDIA on arm64 (SBSA)](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson).
On a Jetson, rootless nerdctl needs three extra flags:
[B2b](docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).

### Windows 🪟

The toolchain is **containerd + BuildKit + nerdctl** with process isolation.

```pwsh
# BUILD — non-admin shell, buildctl against buildkitd
.\windows\Build-Buildkit.ps1 -Gpu

# INSPECT / RUN — ADMIN shell; containerd's pipe is admin-only upstream
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit images
```

**Fresh machine?** Start at [Windows Host Setup](docs/windows-host-setup.md) —
after Stevedore and a reboot, the scriptable half of bring-up is one elevated
run of `windows\scripts\host\Install-NewHost.ps1` (`-ReportOnly` first).

Lane mechanics, why the classic-docker lane was removed, and every host gate:
[Windows Build Lanes](docs/windows-build-lanes.md).

### Clone the repository

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/ANTfrastructure.git
```

### If something fails on first touch

Look the error message up in
**[docs/failure-modes.md](docs/failure-modes.md)** — symptom, cause and fix for
every failure this repo has hit live, on both lanes. The three that catch people
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
| **Upgrade dependencies** — Renovate as a local CLI | [docs/dependency-updates.md](docs/dependency-updates.md) |
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
| `:latest` | The default **manifest** (linux amd64/arm64/riscv64) — the stable API. Carries the Hailo runtime on amd64/arm64 (see below) |
| `:latest-<variant>` | A variant's **manifest** over all its arches, for a stack that cannot go into `:latest`: `:latest-nvidia` (CUDA), `:latest-rocm` (ROCm). `<variant>` names the feature, never an architecture |
| `:latest-<arch>`, `:latest-<variant>-<arch>` | Per-architecture wrappers the manifests are assembled from (internal) |
| `:cross-media-<arch>` | Media libraries layer (internal) |
| `:webserver` | Slim nginx webserver — built by hand from a named build context (`--build-context site=<jotrockenmitlocken>/build/web`), not from a directory tracked here; see [`linux/webserver/README.md`](linux/webserver/README.md) |
| `:winamd64` | Windows **manifest** (`windows/amd64`); variants as `:winamd64-<variant>` |
| `:winarm64` | Windows **artifact bundle** for arm64 — a `windows/amd64` image, its own tag, never a manifest entry and never `--platform windows/arm64` |

**One published tag is one manifest, over every architecture of its variant** —
the grammar, the variant policy and the Windows exception live in
[`AGENTS.md` § Image and tag naming](AGENTS.md#image-and-tag-naming-published-tags).
Accelerators whose runtime fits the default image are built into it instead:

| Accelerator | In `:latest` | Arches |
|---|---|---|
| Hailo-10H (HailoRT, `hailortcli`, `hailonet`, TAPPAS, pyhailort: a real module in images built with the `HAILO_PYHAILORT_IPO` switch at its default, which fails the build on a module without `PyInit__pyhailort`; `import hailo_platform` on Python 3.14 is checked but only warns, proven on amd64 only, [`docs/hailo-support.md`](docs/hailo-support.md#pyhailort)) | always | amd64, arm64 (riscv64: no upstream support) |
| Qualcomm QNN (ORT QNN EP) | only when a QAIRT zip is staged in `linux/qnn-sdk/` at build time ([`docs/qnn-linux.md`](docs/qnn-linux.md)) - **the current release was built without it** | arm64 |
| NVIDIA CUDA / AMD ROCm | no - `:latest-nvidia` / `:latest-rocm` (neither published yet) | NVIDIA: amd64, arm64 (SBSA/Jetson); ROCm: amd64 |

### Which GPUs `:latest-nvidia` runs on

The image carries compiled kernels for the compute capabilities below and
**nothing else** — there is no PTX to fall back on, so a card outside this list
fails at session creation rather than running slowly.

| CC | Hardware |
| --- | --- |
| 86 | RTX 3060-3090, A10, A40 |
| 87 | Jetson AGX Orin |
| 89 | RTX 4060-4090, L40/L40S |
| 120 | GeForce RTX 5050-5090, RTX PRO Blackwell |

**Not included**, each a one-token change in `versions.env`: Turing (75),
A100/A30 (80) and Hopper H100/H200 (90) — both retired 2026-09-23 —, B100/B200
(100), B300/GB300 (103), Jetson Thor (110), GB10/DGX Spark (121). Note that neighbouring numbers do NOT cover
each other: 120 is not 121, and 100 is not 103. How to change the set, and the
four rules that decide which number you need:
[`AGENTS.md` § GPU architecture coverage](AGENTS.md#gpu-architecture-coverage-how-to-turn-an-arch-on-or-off).
 The Windows lane is the
documented exception: `windows/arm64` is not a platform, so its arm64 output is a
bundle that cannot share `:winamd64`'s manifest. Rules and rationale:
[`AGENTS.md` § Image and tag naming](AGENTS.md#image-and-tag-naming-published-tags).

Full matrix with platforms, tag hints and per-stage intermediates:
[docs/overview.md](docs/overview.md).

**Check the live index before relying on its arch coverage** —
`nerdctl manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`.
On 2026-08-31 it (then `:latest-cross`) carried **riscv64 only**: a single-arch run had replaced the
3-arch index. `build-runtime-manifest.sh` now refuses to shrink an already
published index (`--force`, or `RUNTIME_MANIFEST_COMPLETENESS=0`, overrides), so
a partial run cannot do it again —
[docs/cross-build-verification.md](docs/cross-build-verification.md). The 2026-09-02
full-fanout run restored it: the live index carries amd64/arm64/riscv64 again.

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

> **riscv64 `onnxruntime-genai` is self-built, and VALIDATED since 2026-09-03.**
> Upstream ships no riscv64 wheel and runs no riscv64 CI, so the cross lane
> builds it from source (toggle `GENAI_ALLOW_RISCV64`, default on). It compiles,
> links and produces a `linux_riscv64` wheel — and `generate()` now has a
> measurement behind it: greedy decoding on the shipped riscv64 image is
> **token-for-token identical to an amd64 control**, so upstream's one RISC-V
> field report of nonsense output does not reproduce here. The remaining
> untested case is real riscv64 silicon; the run above was qemu-user.
> The patch, the gates and the measurement:
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
> **Re-measured 2026-09-22** — both lanes build green and are published
> (`:winamd64`, `:winarm64`). amd64: smoke **236/0/0** (GPU, with Hailo) /
> 198/0/1 (CPU), arch gate **1201/0**. arm64: smoke **127/0/15**, arch gate
> **1052/0**. The patched LLVM toolchain (#135, `BUILD_PATCHED_LLVM=1`) is the
> default. **CUDA/cuDNN is cross-built for arm64** (#176): the arm64 toolkit
> payload (`lib\arm64`, SHA-pinned redist components + cuDNN) feeds the ORT CUDA
> EP, GenAI CUDA, the OpenCV CUDA modules and TVM — all 0xAA64; running them
> needs an arm64 device. **HailoRT (Phase 3, 2026-09-21)** builds for Windows on
> both arches (`libhailort.dll` + `hailortcli`); TAPPAS stays Linux-only and the
> pyhailort wheel is open. The Qualcomm QNN SDK is staged in `windows/qnn-sdk/`
> and wired into ONNX Runtime (QAIRT 2.44.0.260225, QNN API 2.33.0 — compatible
> with ORT 1.29); the other frameworks' flags were dropped when #154 proved
> upstream never defined them. See
> [`docs/windows-cross-builds.md`](docs/windows-cross-builds.md) and
> [`docs/hailo-support.md`](docs/hailo-support.md).

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

It is the **reference server** for the family's benchmark lab, which lives in
[OrchestrANT](https://github.com/Kataglyphis/OrchestrANT/tree/main/benchmarks): the `orchestrant.benchmark` package ships the runner
(`orchestrant-bench speed` / `lanes` / `report`) and `benchmarks/` carries the
capability evals, the viewer and the tracked results. Endpoints are named in
`backends.json` (`ollama` is the default; the Snapdragon GenieX lanes are listed
too), so a sweep can be pointed at another backend without editing anything.

The correctness-first rationale — **a broken model is fast**, so a sweep gates
on a verifiable-answer check before spending hours measuring — is owned by the
lab's docs next to the tools that implement it.

## Home-lab stacks — deliberately here

Besides the build images and the shared CI surface, this repository carries the
owner's **personal operations stacks**: Home Assistant under
[`linux/homeassistant/`](linux/homeassistant/README.md) and Nextcloud AIO under
[`linux/nextcloud-aio/`](linux/nextcloud-aio/README.md). They are not build
infrastructure and they are not here by accident — one owner, one host, one
place to keep the compose files, the `.env.example` contracts and the runbooks
that go with them. Anything in this repository that claims it is build
infrastructure *only* is wrong; the declared topic includes these two stacks.
They consume the same gates as everything else (crlf-guard, shellcheck,
secret scan), and nothing else in the tree depends on them.

## CI

| Workflow | Purpose |
|----------|---------|
| `ubuntu26.04.yml` | On push/PR: the shell preflight gate suite, its mutation gate as four sharded jobs, + docs validation/build |
| `build-docs.yml` | Reusable workflow for docs build |
| `windows-scripts.yml` | PowerShell lint + the `windows/scripts/tests` suite |
| `python-ci-linux.yml` | Reusable (`workflow_call`) — Python lint/tests on Linux, for consumer repos; never triggers here |
| `python-ci-windows.yml` | Reusable (`workflow_call`) — the same for Windows |
| `llm-stack-serving.yml` | Push/PR, path-filtered on `linux/llm-stack/**` — compose shape and the backend registry. The NAS census test left with the census tool for OrchestrANT on 2026-09-15 |
| `ghcr-cleanup.yml` | Scheduled (Sundays): retains last 3 per tag, 14-day safety net |
| `sbom.yml` | Scheduled (Mondays): SBOM generation |
| `stale-docs-check.yml` | Scheduled (Mondays): stale doc references and broken script paths |
| `actions-selftest.yml` | The composite actions under `.github/actions/` exercised against themselves — push/PR on `.github/actions/**`, Mondays, and dispatch for the deep Windows lane |
| `consumer-inventory.yml` | Scheduled (Mondays): clones every repo in `.github/consumers.json` and grades who still calls each hub entry point; files an issue when a reference dangles |
| `submodule-pins.yml` | The submodule-pin invariant suite; also `workflow_call`, so a consumer runs it with `uses:` instead of copying the job |
| `lint-gates.yml` | Reusable (`workflow_call`) — `run-lint-gates.sh` over a consumer tree |

**Contributing?** Run `make hooks` once. It installs a pre-commit gate that
costs **~4 seconds**: the cheap whole-tree checks, `shellcheck` on the shell
files you actually staged, and the doc gates only when you touched `docs/`. It
is a deliberate subset — the full suite takes minutes (the secret scan alone is
~170 s), and a hook that slow just teaches everyone to type `--no-verify`. Run
`make preflight` yourself before a rebuild or a push; CI runs it on every push
regardless.

The first row's suite is `bash linux/scripts/preflight.sh` (the `KNOWN_SLUGS`
array in that file is the list). Newest
gates in it (2026-09-03): **`gate-registry`** is the meta-gate — every slug must
carry a proof, a suite naming its script or a mutation, or sit frozen in an
allowlist; **`code-complexity`** caps cyclomatic complexity and nesting,
**`dead-functions`** fails a shell function nothing calls, and
**`shellcheck-warnings`** ratchets the warning count per file and code. Before them
(2026-09-01), **`pkg-names`** resolves every package name the tree asks apt for
against the live Ubuntu indices, and **`advert-keys`** fails when a
version-shaped `ENV`/`ARG` is neither checked by the runtime smoke nor excused
with a reason. Before those, **`code-dupes`** — token-normalised duplication over
shell, Dockerfiles and the Markdown outside `docs/`, so it catches *renamed*
clones the prose gate cannot see; deliberate twins are budgeted in
`docs/scripts/code-dupes.allow`.

**None of these builds a container image.** The image lanes are not CI here —
they run on the build host (`windows/Build-Buildkit.ps1`, `linux/scripts/…`).
The `[build-win]` / `[build-arm]` commit-message opt-ins are the convention of
the *consuming* application repos, not of this one: no workflow above reacts to
those tokens. See [docs/ci-build-triggers.md](docs/ci-build-triggers.md), which
says so in its own opening note.

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 23.1.1, GCC 16, CMake 4.4.3, Vulkan SDK 1.4.357.0 |
| Android layer | Android SDK 15859902, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 26.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.357.0, GStreamer 1.29.2, CUDA 13.4.2, ONNX Runtime v1.30.0 |
<!-- generated:version-snapshot:end -->

## License

MIT — see [`LICENSE`](LICENSE). Every source file carries a matching
`SPDX-License-Identifier: MIT` header and the published images declare
`org.opencontainers.image.licenses="MIT"`.

Bundled upstream software keeps its own terms:
[docs/third-party-licenses.md](docs/third-party-licenses.md).
