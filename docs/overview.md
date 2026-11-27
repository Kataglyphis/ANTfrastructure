# Project Overview

## About The Project

Ready-to-build Dockerfiles for multiple targets in one repo, plus the reusable tooling consumer
projects build on:

- PowerShell modules (`windows/scripts/modules/`)
- bash libraries (`linux/scripts/lib/`: agentic-loop, app-runner, cmake-build, code-quality and
  more)
- cross-platform shared data (`shared/agentic-loop/prompts/`)
- CI composite actions (`.github/actions/`, see its README)
- the reusable workflows consumers call at `@develop` (`python-ci-*`, `build-docs`, `lint-gates`,
  `submodule-pins`, `container-ci-windows`)

The [Repo map](#repo-map) below is the authoritative index of that half of the repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/ANTfrastructure/pkgs/container/kataglyphis_beschleuniger)
— the multi-arch Linux `:latest`, the Windows build image `:winamd64` and the `:winarm64` bundle.
Every tag: [Published Images and Tag Hints](#published-images-and-tag-hints).

## Repo map

One line per top-level directory, each linking what describes it. No counts: every count written
here has gone stale, and `ls` answers faster.

| Directory | What lives there |
|---|---|
| `cmake/` | The shared CMake modules consumers `include()` — sanitizers, static analysers, cache, tests. |
| `shared/config/` | The canonical `.clang-format`, `.clang-tidy`, `.cmake-format.yaml`, `gcovr.cfg`, `.pre-commit-config.yaml`, plus the sync tool and the manifest that says which of them a consumer takes. `analysis_options.yaml` is the Dart analyzer config, which Dart consumers `include:` by reference instead. [README](../shared/config/README.md) |
| `shared/linux/templates/` | Copy-and-edit bash: the `antfrastructure.sh` bootstrap, the `renovate-local.sh` wrapper, the consumer `git-hooks/`. [README](../shared/linux/templates/README.md) |
| `shared/windows/` | The `Resolve-BuildModule.ps1` bootstrap template and the shared Pester suites consumers run (`Submodule.Pins.Tests.ps1`). [README](../shared/windows/templates/README.md) |
| `shared/templates/` | The consumer `AGENTS.md` skeleton. [README](../shared/templates/README.md) |
| `shared/agentic-loop/` | Cross-platform loop data: the planner/refactor/executor task prompts and the role system prompts both lane implementations read, plus the copy-and-edit consumer templates. [Templates](../shared/agentic-loop/templates/README.md) |
| `docs/scripts/` | The docs gates and version tooling — `verify_doc_links.py`, `verify_doc_dupes.py`, `verify_code_dupes.py`, `sync_versions.py`, `bump_versions.py`, the SBOM pair, `mutations.json`. [Gate registry](code-quality-gates.md) |
| `.github/actions/` | The composite actions consumers call `@develop`. [README](../.github/actions/README.md) |
| `.github/workflows/` | This repo's own lanes plus the `workflow_call` ones consumers reuse (`python-ci-*`, `python-static`, `python-refactor`, `powershell-quality`, `code-quality-report`, `mutation-gates`, `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, which builds, checks and publishes every docs site: [`docs-sites.md`](docs-sites.md), and `release-publish`, every `release.yml`'s version check and publish: [`branch-and-release-strategy.md`](branch-and-release-strategy.md#the-reusable-release-workflow)). [Triggers](ci-build-triggers.md) |
| `linux/scripts/` | The Linux build system: `01-core` (shared utilities), `02-toolchain` (GCC/LLVM/Rust/Python/CMake/Vulkan), `03-media` (per-library builds), `04-runtime` (entrypoint + env), `05-frameworks` (TVM, Torch, Flutter), `06-packaging` (assembly + smoke), plus the orchestrators and gates at its root. [Libraries](shared-script-libraries.md) |
| `linux/llm-stack/` | The Ollama + Open WebUI serving stack. [README](../linux/llm-stack/README.md) |
| `linux/jetson-webcam/` | A USB-camera object-detection PoC on a Jetson GPU, run in the arm64 GPU wrapper image. [README](../linux/jetson-webcam/README.md) |
| `linux/webserver/` | The slim nginx image and the reusable Flutter-web helpers. [README](../linux/webserver/README.md) |
| `linux/host-config/` | Host configuration as code: `buildkitd.toml`, the systemd drop-in, the apply/verify pair, the ghcr tools, and this repo's OWN git hooks (not the consumer ones). [Host setup](linux-host-setup.md) |
| `linux/homeassistant/`, `linux/nextcloud-aio/`, `linux/ansible/` | The owner's personal operations stacks, deliberately carried here ([`docs/overview.md` § Home-lab stacks](overview.md#home-lab-stacks-deliberately-here)). [HA](../linux/homeassistant/README.md) · [Nextcloud](../linux/nextcloud-aio/README.md) · [Ansible](../linux/ansible/README.md) |
| `linux/vulkan/`, `linux/qnn-sdk/`, `linux/nvidia-local-debs/` | Staged SDK inputs. The QNN and NVIDIA trees are gitignored except their READMEs — login-gated, EULA-bound, never committed. |
| `windows/scripts/` | The Windows lane, grouped into `build/`, `host/`, `diagnostics/`, with `modules/*.psm1` as the reusable surface and `tests/` as its Pester suites. [Windows builds](windows-builds.md) |
| `windows/upstream/` | Prepared upstream submissions, one directory per submission. NOT build inputs, and NOT to be posted without the owner saying so. [README](../windows/upstream/README.md) |
| `windows/qnn-sdk/` | As `linux/qnn-sdk/`: gitignored but for its README. |
| `third_party/DocumANTation/` | The brand and style submodule every docs build reads. |
| `out/` | Generated artifacts (OCI layouts, rootfs exports). Gitignored and excluded from every build context. |

Before deleting anything under `linux/scripts/lib/`, `02-toolchain/rust/`, `02-toolchain/python/`
or `06-packaging/`, grade it with the consumer inventory. Those four hold consumer surface this
repo's own lanes barely or never call. In-repo, only `preflight.sh` and `flutter_checks.sh` source
`lib/code-quality.sh`. `06-packaging/` also holds the images' own packaging and smoke scripts.
A sweep once deleted `package_archive.sh` as "zero-reference" while a consumer's release job
was calling it. The rule and the mechanism: `AGENTS.md` § Contributing Reusable Work Here and
[`consumer-inventory.md`](consumer-inventory.md).

## The architecture summary AGENTS.md carried

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), with the two sections after it;
corrected since where the code moved. The RULES stayed there; this is the reference behind them.

Three build lanes ([Linux Image Chain](#linux-image-chain)).

- **Linux arches:** `amd64`, `arm64`, `riscv64`.
- **Windows host:** `windows/amd64` only. **Windows targets:** `amd64` (image, production) and
  `arm64` (cross-compiled artifact bundle).
- **The arm64 lane**: plumbing landed 2026-08-22, and the lane **BUILDS** since 2026-08-23.
  **Nothing it produces runs on the build host**: Windows x64 has no ARM64 emulation, so every
  arm64 signal there is a static PE machine-type check; the bundle runs on an arm64 device or a
  `windows-11-arm` runner (`Test-Arm64Bundle.ps1`, first device run 2026-10-03,
  [`windows-cross-builds.md`](windows-cross-builds.md)). `Build-Buildkit.ps1 -TargetArch arm64`
  just works: `torch` is dropped from the DEFAULT stage list with a notice; asking for it **explicitly**
  still throws, because it runs `uv sync`, which must execute the target interpreter. Which
  components are through: the status banner of `docs/windows-cross-builds.md`. It moves, so do
  not restate it here.
- **RUNTIME parity since 2026-08-26:** the same GStreamer plugin set (200 DLLs, six contract
  plugins, `gst-ptp-helper`; the contract has fourteen since CON183 on 2026-11-04, and the seven
  WebRTC ones run on an arm64 device since 2026-10-11), the same media/inference surface and the
  same six python wheels. The TVM/IREE **runtime** python packages are cross-built and assembled
  on this lane (#133).
- **amd64-only, a short closed list:** classic TensorRT (CUDA/cuDNN are cross-built since #176,
  2026-09-20), the TVM and IREE **compilers** (target-arch LLVM), LiteRT-LM, the torch app
  stage. The bundle names each with an `ABSENT-ON-ARM64.txt` / `COMPILER-ABSENT-ON-ARM64.txt`
  marker, so a consumer never has to guess.

> **Never publish the arm64 lane's output with `--platform windows/arm64`.** It is a cross build
> out of the same `windows/amd64` container, and its product is an artifact bundle, not a
> runnable image; that flag yields a manifest nothing can run. Why no arm64 Windows container can
> exist, and the lane's current coverage: [`docs/windows-cross-builds.md`](windows-cross-builds.md).
>
> **The shared base installs four arm64-only prerequisites UNCONDITIONALLY.** Never gate them on
> an arch ARG: that re-pays the chain's most expensive layers on every lane switch. The base only
> warns (`Test-Arm64Prereqs.ps1` reports on all four); the GStreamer build **throws** on the ones
> it needs. `WINDOWS_ARM64_STRICT=1` promotes the base checks to hard gates, but only as a
> build-arg (`-BuildArg WINDOWS_ARM64_STRICT=1`; a host env var alone does nothing), and it never
> reaches `Install-Vs.ps1`'s MSVC `lib\arm64` check (that RUN sits above the `ARG` declaration in
> `Dockerfile.base`). The prerequisite list, rationale and traps: `docs/windows-cross-builds.md`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` (stable apt deps only; copies no project scripts — stays cache-stable) |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:latest-base-<arch>` + `:cross-android-<arch>` | `:latest-package-<arch>` |
| `Dockerfile.torch` | `:latest-package-<arch>` | `:latest-<arch>` (incl. the Hailo payload on amd64/arm64) |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | `:cross-toolchain-<variant>-<arch>`: a variant chain's `gpu` stage (CUDA or ROCm/MIGraphX); its media builds FROM it, and every later tag carries `-<variant>`. nvidia's stage tags live in the private `<repo>-stages` package |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64` (a **manifest** over `windows/amd64`; variants as `:winamd64-<variant>`), or `:winarm64` under `-TargetArch arm64` — the arm64 **artifact bundle**, still a `windows/amd64` image, never a manifest entry ([§ Tag naming](#tag-naming)) |

## Supported platforms, as AGENTS.md listed them

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` by default; `CROSS_BUILD_PLATFORM=linux/arm64` builds natively on an arm64 host ([Non-amd64 build hosts](linux-cross-builds.md#non-amd64-build-hosts)) | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |
| Windows cross lane | `windows/amd64` | `arm64` artifact bundle (clang-cl `aarch64-pc-windows-msvc`), shipped as `:winarm64`, a `windows/amd64` image; **never** a `windows/arm64` one |

riscv64's feature-parity exemptions: [`linux-cross-builds.md` § Rules for the Linux lane](linux-cross-builds.md#rules-for-the-linux-lane).

## Expected outputs, as AGENTS.md listed them

A successful `build-cross-chain.sh` run pushes to GHCR:

- every cross-lane intermediate image
- the per-architecture wrapper images (`:latest-<arch>`)
- the multi-arch manifest (`:latest`)

A variant chain (`CROSS_VARIANT=nvidia|rocm`) writes `:latest-<variant>-<arch>` and
`:latest-<variant>` instead; `--no-push` builds every stage locally and pushes nothing.

## Published Images and Tag Hints

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | The default **manifest** — the current cross-lane release, Hailo and (when staged) QNN included. Built via digest-pinned stage chain (`base → compiler → sdk → media → android → package → torch → wrapper → manifest`). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | nvidia: linux/amd64 and linux/arm64; rocm: linux/amd64 | `latest-nvidia`, `latest-rocm` | A variant's **manifest** over its runtime arches, for a stack that cannot ship in `latest` (`<variant>` is a feature, never an architecture). NVIDIA's plugin index passed all six consumers on amd64 and native arm64; ROCm's plugin-only index passed them on amd64. [Receipts and exact digests](image-acceptance.md#evidence-and-limits). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64 | `base`, `cross-compiler-amd64`, `cross-sdk-<arch>`, `cross-toolchain-rocm-<arch>`, `cross-media-[rocm-]<arch>`, `cross-android-[rocm-]<arch>` | Cross-lane intermediate images (amd64-hosted, cross-compiled for target arches; the `cross-toolchain-` tag is a variant chain's `gpu` stage). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger-stages (**private**) | linux/amd64 | `cross-toolchain-nvidia-<arch>`, `cross-media-nvidia-<arch>`, `cross-android-nvidia-<arch>` | The nvidia chain's stages, which carry TensorRT's SDK (owner 2026-10-21, [accelerator images § Stage images](linux-accelerator-images.md#stage-images-a-private-package)). Pulling needs a login. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | per-arch native | `latest-base-<arch>`, `latest-package-<arch>`, `latest-<arch>`, `latest-<variant>-<arch>` | Runtime lane per-arch **wrapper** images the manifests are assembled from (internal). The chain pushes `latest-<arch>`; `latest-base-`/`latest-package-` go out only with `--push-all`. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest-cross`, `latest-cross-<arch>` | **Retired** old name of `latest`; the tags were deleted from the registry on 2026-09-29 ([§ Tag naming](#tag-naming)). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | as built | `webserver` | Minimal nginx static webserver image, built by hand from a named build context ([`linux/webserver/README.md`](../linux/webserver/README.md)). No `webserver` tag is in the registry on 2026-09-25. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX — a **manifest** over `windows/amd64`, CPU + DirectML; variants as `:winamd64-<variant>`: `:winamd64-nvidia` (CUDA), `:winamd64-rocm` (ROCm). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | windows/amd64 (arm64 **bundle**) | `winarm64` | The arm64 cross artifact bundle: a `windows/amd64` image carrying the aarch64 payload, its own tag. Not a platform, not a manifest entry, never `--platform windows/arm64` — see [§ Tag naming](#tag-naming). `:winarm64-nvidia` carries the arm64 CUDA payload. |

**Check the live index before relying on its arch coverage**:
`nerdctl manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`. On 2026-08-31 it
(then `:latest-cross`) carried **riscv64 only**: a single-arch run had replaced the 3-arch index.
`build-runtime-manifest.sh` now refuses to shrink an already published index (`--force`, or
`RUNTIME_MANIFEST_COMPLETENESS=0`, overrides), so a partial run cannot do it again
([cross-build-verification.md](cross-build-verification.md)). The 2026-09-02 full-fanout run
restored it: the live index carries amd64/arm64/riscv64 again.

### Accelerators in the default image

Moved from the README on 2026-10-19. An accelerator whose runtime fits the default image is built
into it, not into a variant:

| Accelerator | In `:latest` | Arches |
|---|---|---|
| Hailo-10H (HailoRT, `hailortcli`, `hailonet`, TAPPAS, pyhailort: a real module in images built with the `HAILO_PYHAILORT_IPO` switch at its default, which fails the build on a module without `PyInit__pyhailort`; `import hailo_platform` on the image's Python is checked but only warns, proven on 3.14 and amd64 only (the 3.15 pin is not built yet), [`hailo-support.md`](hailo-support.md#pyhailort)) | always | amd64, arm64 (riscv64: no upstream support) |
| Qualcomm QNN (ORT QNN EP) | only when a QAIRT zip is staged in `linux/qnn-sdk/` at build time ([`qnn-linux.md`](qnn-linux.md)) - **the current release was built without it** | arm64 |
| NVIDIA CUDA / AMD ROCm | no - `:latest-nvidia` / `:latest-rocm`; published variant platforms are listed above | NVIDIA: amd64 and arm64 (SBSA); ROCm: amd64 |
| NVIDIA DeepStream 9.1 | no - enabled in NVIDIA builds; arm64 uses the staged [SBSA payload](linux-accelerator-images.md#deepstream-on-arm64-sbsa), with `ENABLE_DEEPSTREAM=false` as the explicit opt-out | amd64, arm64 (SBSA) |

**`:latest-nvidia` carries compiled kernels for the compute capabilities `CUDA_ARCHITECTURES`
names and nothing else** (86, 87, 89 and 120; owner decision 2026-09-23). There is no PTX to fall
back on, so a card outside that list fails at session creation rather than running slowly. The
hardware behind each number, what is left out, and how to change the set:
[`AGENTS.md` § GPU architecture coverage](../AGENTS.md#gpu-architecture-coverage-how-to-turn-an-arch-on-or-off).

## Tag naming

One published tag is one manifest, carrying every architecture its variant supports, on both
lanes. Both lanes publish into the same registry repo, so only one owns the bare `:latest`: Linux
does, and Windows keeps its lane qualifier.

| | Default manifest | Variant manifest | Per-arch wrapper (internal) | Cross bundle (NOT a platform) |
| --- | --- | --- | --- | --- |
| Linux | `:latest` | `:latest-<variant>` | `:latest-<arch>`, `:latest-<variant>-<arch>` | — |
| Windows | `:winamd64` | `:winamd64-<variant>` | — (one platform) | `:winarm64` |

- The grammar is `<version>[-<variant>][-<arch>]`. `latest` fills the version slot, so a pinned
  release is `:2026.09` / `:2026.09-nvidia` with no new rule. Tags are parsed by position, which
  makes the next bullet a hard rule.
- `<variant>` names what makes the image different (`nvidia`, `rocm`), never an architecture.
  `:latest-amd64` must stay unambiguous, which is why `amd` is spelled `rocm`. A new architecture
  adds an entry to a variant's manifest; a new variant adds a tag.
- A variant exists only for a stack that cannot ship in `:latest`. CUDA and ROCm are multi-GB,
  driver-bound and mutually exclusive. An accelerator whose runtime fits is built into the default
  image: Hailo-10H (amd64/arm64, `Dockerfile.torch`) and QNN (arm64, from the pinned public QAIRT
  Community zip — [qnn-linux.md](qnn-linux.md)).
- There is no `:latest-hailo` or `:latest-qnn`. The standalone `:hailo` variant and
  `Dockerfile.hailo` were retired as a duplicate of the standard build.
- A variant chain builds a variant (`AGENTS.md` § Build Workflow), never `ENABLE_*` flipped on the
  default one: that pushed GPU bytes under the default tags.
- The per-arch images (`:latest-<arch>`, the stage tags `:latest-base-<arch>` /
  `:latest-package-<arch>`) are the wrappers the manifest is assembled from: implementation detail,
  consumers resolve the manifest.
- nvidia's cross stages (`gpu`, `media`, `android`) push to a separate, private package,
  `<repo>-stages`. They carry TensorRT's SDK, which may ship only as runtime files, and GHCR sets
  visibility per package. Everything else stays in `<repo>`
  ([`linux-accelerator-images.md` § Stage images](linux-accelerator-images.md#stage-images-a-private-package)).
- `:latest-cross` is retired, the old name of `:latest`. Nothing composes or pushes it, and
  `verify_ci_image_refs.py` rejects it under `.github/`. The fleet calls this repo's composite
  actions and reusable workflows at `@develop`, whose `versions.env` names `:latest`. `main` still
  carries `CI_IMAGE_LINUX_TAG=latest-cross`, frozen at the last release that published it.
- The `:latest-cross` registry tags are gone. Republishing `:latest` left `:latest-cross` alone on
  the old index, and `ghcr-delete-tags.sh` deleted it and the three `:latest-cross-<arch>` wrappers.
  A lane still at `@main` fails at `docker pull`; move it to `@develop`.
- A new variant = a new manifest tag. The manifest lane refuses to shrink a published index
  (`AGENTS.md` § Push and Publish Rules), so a partial run cannot drop an architecture from one.
- Windows follows the variant rule for CUDA too. `Build-Buildkit.ps1 -Gpu` (`-Variant nvidia`)
  builds under `bk-*-nvidia` stage tags and publishes `:winamd64-nvidia`, or `:winarm64-nvidia` for
  the cross bundle; `:winamd64` is CPU + DirectML. `Resolve-BkVariant` refuses a push to any other
  tag. Before that the nvidia build wrote the default tags, so a `:winamd64` published before the
  variant rule carries CUDA until that tag's next publish.
- Windows is the documented exception, a platform fact, not a convention. `windows/arm64` does not
  exist as a platform. Microsoft publishes no arm64 `servercore`/`nanoserver` base and Windows
  Server has no arm64 release
  ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)).
- The arm64 lane cross-compiles inside the `windows/amd64` container and emits an artifact bundle,
  so both Windows outputs are `windows/amd64` images. Two entries with the same platform cannot
  share a manifest, and the bundle must never be published as `windows/arm64`. So it keeps its own
  tag (`:winarm64`, documented as a bundle) and never joins `:winamd64`.

## Images in This Repository

- `linux/Dockerfile.torch`: the final Linux wrapper image — Torch/Python layer + runtime scripts +
  entrypoint.
- `linux/webserver/Dockerfile`: minimal nginx static webserver (config at
  `linux/webserver/nginx.conf`).
- `windows/Dockerfile.base`, `windows/Dockerfile.nvidia` or `windows/Dockerfile.rocm` (optional
  GPU layer), `windows/Dockerfile.toolchain-builder`, `windows/Dockerfile.media-merge-builder`
  (+ per-branch media builders), `windows/Dockerfile.rocm-migraphx` and
  `windows/Dockerfile.rocm-llama` (rocm variant only), `windows/Dockerfile.torch` (the
  OrchestrANT app stage), `windows/Dockerfile` (driven by `windows/Build-Buildkit.ps1`): Windows
  Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

## Linux Image Chain

The Linux images build as a chain of separate Dockerfiles, one per stage, so BuildKit caches the
expensive layers and rebuilds only what changed; the chain ends in the `linux/Dockerfile.torch`
wrapper. Dockerfile → FROM → produced tag: the table
[above](#the-architecture-summary-agentsmd-carried). Per-stage contents (moved from the README on
2026-10-19):

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
└── scripts/                 01-core … 06-packaging — see § Repo map
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
  `base → compiler → sdk → media → android → runtime` (`CROSS_STAGE_ORDER`). The runtime stage
  builds `package`/`wrapper` with the android image as their artifact source, so android is not
  optional.
- **Runtime** (native or QEMU per arch): `base → package → wrapper`
- **Windows** (native Windows Containers): `base → sdk → toolchain → media → torch → final`; the
  variant stages in that order: [`AGENTS.md` § Build Workflow](../AGENTS.md#build-workflow).

Per-stage mechanics: [Linux build basics](linux-build-basics.md) and
[Linux cross builds](linux-cross-builds.md), including `Dockerfile.sdk`'s reuse for amd64-hosted
cross SDK artifact builds via `BUILD_MODE=cross` and `Dockerfile.package`'s clean-base runtime
assembly in both native and cross flows.

## What You Get

- Multi-arch builds via nerdctl + BuildKit.
- Vulkan + toolchains ready for GPU passthrough.
- The Torch/Python runtime in the final Linux image chain.
- Static web content served by nginx.

## Key Features

| Category | Feature | Status |
| --- | --- | :---: |
| Cross-build | Multi-arch cross toolchain (amd64, arm64, riscv64) | ✔️ |
| Cross-build | Digest-pinned stage handoff | ✔️ |
| Cross-build | Runtime packaging via QEMU/binfmt | ✔️ |
| GPU acceleration | NVIDIA CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN, TensorRT | ✔️ |
| GPU acceleration | DirectML (Windows, vendor-agnostic — ONNX Runtime + GenAI DML EP) | ✔️ |
| GPU acceleration | AMD MIGraphX | ✔️ |
| GPU acceleration | Vulkan SDK <!-- generated:vulkan -->1.4.363.0<!-- /generated:vulkan --> | ✔️ |
| Media | ONNX Runtime <!-- generated:onnx -->1.31.1<!-- /generated:onnx --> | ✔️ |
| Media | GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer -->, OpenCV <!-- generated:opencv -->5.0.0<!-- /generated:opencv -->, LiteRT | ✔️ |
| Media | libcamera, FFmpeg | ✔️ |
| Compiler | GCC <!-- generated:gcc -->16.2.0<!-- /generated:gcc -->, LLVM/Clang <!-- generated:llvm -->23.1.5<!-- /generated:llvm --> | ✔️ |
| Language runtime | Python <!-- generated:python -->3.15.2<!-- /generated:python -->, Node.js <!-- generated:node -->26.13.0<!-- /generated:node --> | ✔️ |
| Android | SDK <!-- generated:android_sdk -->15859902<!-- /generated:android_sdk -->, NDK <!-- generated:android_ndk -->30.0.16248370<!-- /generated:android_ndk --> | ✔️ |
| Windows | MSVC Build Tools, CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer --> | ✔️ |
| Windows | Vulkan SDK <!-- generated:vulkan -->1.4.363.0<!-- /generated:vulkan -->, ONNX Runtime <!-- generated:onnx -->1.31.1<!-- /generated:onnx --> | ✔️ |
| Windows-on-ARM | Cross-built **artifact bundle** (`:winarm64` labels a `windows/amd64` image; publishing: [above](#the-architecture-summary-agentsmd-carried)): media + inference measured at runtime parity with amd64 on 2026-08-26 (statically verified only; HEAD carries unvalidated changes since). **CUDA/cuDNN and HailoRT cross-built since 2026-09-20/21 (#176 + Phase 3: arm64 toolkit payload, ORT CUDA EP, GenAI CUDA, OpenCV CUDA modules, TVM CUDA, `libhailort.dll` + `hailortcli`, all 0xAA64; running them needs an arm64 device).** Not included: classic TensorRT, TAPPAS, the pyhailort wheel, the TVM/IREE compilers, LiteRT-LM, the torch app. [Details](windows-cross-builds.md) | ✔️ |

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started

License information on bundled software: [Third-Party Licenses](third-party-licenses.md).

## Home-lab stacks, deliberately here

Moved from the README on 2026-10-19.

Besides the build images and the shared CI surface, this repository carries the owner's
**personal operations stacks**: Home Assistant under
[`linux/homeassistant/`](../linux/homeassistant/README.md), Nextcloud AIO under
[`linux/nextcloud-aio/`](../linux/nextcloud-aio/README.md), and the Ansible install on the host
(pip in a venv, per the official docs) under [`linux/ansible/`](../linux/ansible/README.md). They
are not build infrastructure, and not here by accident: one owner, one host, one place for the
compose files, the `.env.example` contracts and the runbooks that go with them. Anything in this
repository that claims it is build infrastructure *only* is wrong; the declared topic includes
these stacks. They go through the same gates as everything else (crlf-guard, shellcheck, secret scan),
and nothing else in the tree depends on them.
