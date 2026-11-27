# ANTfrastructure — agent guardrails

**This file is the rulebook, not the manual**: what an agent must and must not do to keep the
build from regressing, plus the canonical build commands. A RULE an agent must not break belongs
here. The MECHANISM behind it, and reference data (what is in an image, per-component build
matrices, script tables), belong to the `docs/` page that owns the topic.
[`docs/INDEX.md`](docs/INDEX.md) maps topic → page.

| Before you… | Read |
|---|---|
| Edit anything under `windows/` | [`docs/windows-build-invariants.md`](docs/windows-build-invariants.md) — the load-bearing rules |
| Debug an error message | [`docs/failure-modes.md`](docs/failure-modes.md) — symptom → cause → fix |
| Launch or debug a Windows chain | [`docs/windows-build-lanes.md`](docs/windows-build-lanes.md) — BuildKit, nerdctl, classic (historical) |
| Wire a new project to this repo | [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md) |
| Add or bump a dependency | [`docs/third-party-licenses.md`](docs/third-party-licenses.md) § Maintaining this list — an `spdx` id is mandatory, copyleft needs a source pointer, and the build gates both. The bump steps: [`docs/dependency-updates.md`](docs/dependency-updates.md#version-bumping-as-agentsmd-carried-it) |

## Contents

Rules — never regress these. [Project priorities](#project-priorities-owner-directive--optimize-for-all-of-them-always) ·
[Shell safety](#shell-safety-conventions-five-bug-classes-all-found-live-2026-08-08) ·
[No ghost processes](#background-jobs-and-test-processes-no-ghosts) ·
[Caching discipline](#caching-discipline-do-not-regress) ·
[Stage handoff](#cross-chain-stage-handoff-do-not-regress) ·
[Five critical fixes](#five-critical-fixes-to-maintain) ·
[Linux build rules](#linux-build-rules) ·
[Push and publish](#push-and-publish-rules) ·
[Development rules](#development-rules) ·
[`.dockerignore`](#dockerignore-guardrail) ·
[Contributing reusable work here](#contributing-reusable-work-here)

Doing the work. [Quick reference](#quick-reference) ·
[Build workflow](#build-workflow) · [Validation](#validation) ·
[Version bumping](#version-bumping) · [Dependency updates](#dependency-updates) ·
[Failure modes](#common-failure-modes)

Orientation. [Container architecture](#container-architecture) ·
[Repo map](#repo-map) · [Code organization](#code-organization-key-shared-utilities) ·
[Documentation maintenance](#documentation-maintenance)

## Project priorities (owner directive — optimize for all of them, always)

1. Fastest possible build. Cache-first: narrow per-file closures, local cache exports, the
   compiler cache wired end to end AND measured (stats to stderr, the stream a clipped step log
   keeps), a pinned buildkitd GC budget, and the parallelism levers taken when proven safe. Idle
   cores are the standing wall-clock reserve. Re-measure before citing a number: a CPU figure
   quoted here for weeks came from a broken sampler. Correctness bounds every shortcut; speed
   that risks a silently wrong image is not speed.
2. Maximum stability. Digest-pinned handoffs, machine-checked ancestry, verified version pins
   (checksums from official sources), the five shell bug classes (§ Shell safety conventions)
   never reintroduced, and gates that FAIL LOUDLY. An assertion-free PASS ("will work at
   runtime") or an inner warning swallowed by an outer green is a defect, not a success.
3. Many tests. Every fix ships a regression test where testable: a unit suite under
   `linux/scripts/tests/` (auto-discovered, run by preflight's `script-tests` slug, NOT by the
   pre-commit hook), a lint gate, or a smoke assertion against a `versions.env` pin.
   Mutation-test every new gate: break what it guards, watch it go red, and say in its header
   what it does NOT cover. A gate that cannot fail is worse than no gate; two audits found one.
4. Docs follow the change, in the same work unit. `AGENTS.md` changes only for a new or
   changed rule, and `README.md` only for a new entry point. The mechanism goes to the `docs/` page
   that owns the topic, and the history to `CHANGELOG.md`. Dates, decision ids, run ids and hashes
   belong only in `CHANGELOG.md`, `BACKLOG.md` and `docs/decisions.md`, never inside instructions.
5. Our build always wins over the distro copy (owner directive). Where a `/opt`
   tree and a distro package export the same soname, ours wins the `ld.so` lookup. Write
   `000-<name>.conf` into `/etc/ld.so.conf.d` (read in SORT order) and never rely on a purge,
   because another dependency pulls the distro copy back in. The soname-precedence gate enforces
   it on the SHIPPED bytes. Same rule for `PATH`, `PKG_CONFIG_PATH` and `PYTHONPATH`.
6. One-line comments, only the why, in every repo of the family: § Comments: one line, only
   the why.
7. Quality exceptions must shrink. Refactor the code to satisfy duplication, complexity and size
   gates. Do not add an allowlist entry, increase a frozen budget, raise a threshold or narrow scan
   coverage to make a change pass unless the owner explicitly authorizes that exception. Existing
   entries are debt; remove them when the underlying finding is fixed. The function-size, complexity, comment-size
   and masked-declaration lists are empty; keep them empty. Share duplicated behavior; do not rename
   variables, reformat copies or add suppressions to evade a duplication finding.

The one-line invariants under each priority live on the page that owns their topic:
[INDEX.md § Invariants by topic](docs/INDEX.md#invariants-by-topic) lists those sections.

## Container Architecture

One Dockerfile per stage, chained base → toolchain → sdk → media → android → package → torch,
with an optional `gpu` layer (`nvidia` or `amd`) between sdk and media in a variant chain. Each
stage is built and pushed on its own and pinned into its child by digest, which is what makes a
single-stage rebuild possible.

Stage graph, tags, platforms and what each stage contains: [`overview.md`](docs/overview.md) and
[`linux-cross-builds.md`](docs/linux-cross-builds.md). Naming rules that must not drift:
§ Windows-Specific Naming below and [`consumer-image-contract.md`](docs/consumer-image-contract.md).

### Image and tag naming (published tags)

One published tag is one manifest, carrying every architecture its variant supports, on both lanes.
Linux owns the bare `:latest`; Windows keeps its lane qualifier (`:winamd64`). The tag table and
the reasons: [overview.md § Tag naming](docs/overview.md#tag-naming).

- Tags are `<version>[-<variant>][-<arch>]`, parsed by position. A variant names a feature
  (`nvidia`, `rocm`), never an architecture.
- A variant exists only for a stack that cannot ship in `:latest`. Build it with a variant chain,
  never by flipping `ENABLE_*` on the default chain.
- `:latest-cross` is retired. Move a lane still at `@main` to `@develop`.
- The Windows arm64 output is a bundle under its own `:winarm64` tag. Never publish it as
  `windows/arm64` or add it to `:winamd64`.

### Windows-Specific Naming

Take every local Windows intermediate tag from `Get-BkTag` (`windows/Build-Buildkit.ps1`), and keep
the `-<variant>` infix, so a variant run never overwrites a default image
([windows-build-lanes.md](docs/windows-build-lanes.md#local-intermediate-tags)).

---

## Quick Reference

Commands, knob tables and per-stage recipes:
[`linux-cross-builds.md` § The command reference AGENTS.md used to carry](docs/linux-cross-builds.md#the-command-reference-agentsmd-used-to-carry).
The rules below stay here:

- Stop a chain with `bash linux/scripts/stop-cross-chain.sh`, never `pkill`: a `pkill` orphans the
  children and leaves the build solving.
- Never edit a file in a running chain's closure, and never restart buildkitd while a build
  solves (§ Caching discipline, rules 1 and 4).
- Verify the shipped bytes, never the push: keep `verify-shipped-wrapper.sh` gating
  `build-runtime-manifest.sh`
  ([§ Verify the shipped bytes](docs/cross-build-verification.md#verify-the-shipped-bytes)).
- `--log-dir` is not universal. `build-cross-chain.sh` and `build-cross-stage.sh` tee each
  stage; the other three orchestrators do not take the flag, so pipe them through `tee` yourself.
- Never export the cache-prefixed compiler strings into package assembly
  ([python-ci.md](docs/python-ci.md)).
- Keep a recurring operational script Git-tracked and reuse it; never regenerate a preflight,
  monitoring or probe driver in scratch space
  ([operational toolkit](docs/local-proof-workflows.md#run-artifacts-and-operational-scripts)).
- Generated run artifacts belong under the ignored `logs/`; live `chain-status*.json` stays at the
  repo root ([§ Run artifacts and operational scripts](docs/local-proof-workflows.md#run-artifacts-and-operational-scripts)).
- Pin a verified hub SHA in a consumer with `linux/scripts/pin-antfrastructure-submodule.py`, after
  the hub commit is published and green
  ([dependency-updates.md](docs/dependency-updates.md)).
- Measure before and after. `quality-report.sh` (with `--perf-host`), `fleet-health.py`, `security-audit.sh` and
  `bench-history`: [`fleet-health.md`](docs/fleet-health.md) and [`vulnerability-scanning.md`](docs/vulnerability-scanning.md).
- Review a Python refactor patch from `linux/scripts/refactor-python.sh` before committing it
  ([code-quality-tooling.md](docs/code-quality-tooling.md)).

### Windows Container Build

Build non-admin with `windows\Build-Buildkit.ps1`, inspect `bk-*` images from an admin shell, and
set up a fresh machine with [`windows-host-setup.md`](docs/windows-host-setup.md). The lane:
[`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)
and [`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Running Linux containers (Rancher Desktop)

Use `nerdctl`, never `docker`, and check the image contract rather than assume a host tool is in
the image: [`rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).
WSL2 quality checks: [`windows-host-setup.md`](docs/windows-host-setup.md).

### LLM Stack (Ollama + Open WebUI)

[`linux/llm-stack/`](linux/llm-stack/README.md) is a standalone serving stack, CPU-only by default,
GPU by opt-in override; it is the family's reference server, and the benchmark suite that points
at it lives in OrchestrANT. Two rules: never put a key in `backends.json`, only the NAME of the
environment variable that holds it, and the context Ollama lists is the model's maximum, not
what fits. Size it against real VRAM before claiming a context length.

The gateway in front of the GenieX lanes patches APISIX internals
(`gateway/lua/geniex_hook.lua`). An APISIX bump is done only when
`GATEWAY_E2E=1 pytest linux/llm-stack/tests/gateway_e2e` is green on it, and its config changes
only through `scripts/serve-stack.sh`, which validates before it swaps:
[the llm-stack README's Gateway section](linux/llm-stack/README.md#gateway).

### GenieX on Snapdragon (on-device OpenAI server)

The Kataglyphis coding agents run fully on-device on Snapdragon (Adreno GPU or Hexagon NPU)
through an OpenAI-compatible server, with WSL2 clients pointing at the Windows host. Setup, model
matrix, measurements and the debugging trail:
[`geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md).

### Branches, CI rounds and releases

Owner rule for every repo of the family. `develop` is the default branch, and every push to it
runs the Linux x64 lane; every other lane runs when a commit message asks for it (`[ci windows]`,
`[ci arm64]`, `[ci all]`, …) or when started by hand. `main` moves only by a fast-forward to a
`develop` commit whose full round is green, and only the owner moves it, or an agent the owner
tells to in that turn ([strategy](docs/branch-and-release-strategy.md),
[triggers](docs/ci-build-triggers.md)).

### Reading CI status with the GitHub CLI

A skipped job is not a passed job. `gh run view` prints both as a tick, and reading a required
lane's skip as success is how a red push looked green here. Check each job's conclusion, not the
run's summary glyph. Commands, and which jobs are still gated:
[`github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md) and
[`ci-build-triggers.md`](docs/ci-build-triggers.md).

### Searching the tree: ripgrep (`rg`)

Owner rule for every repo of the family. Search with `rg`, not `grep -r` or
`findstr`. It honours `.gitignore`, so it skips the `build/`, `.dart_tool/` and vendored-SDK trees
that `grep -r` walks, and it skips binaries.

- Install: Windows `winget install --id BurntSushi.ripgrep.MSVC -e --scope user` (no admin), Linux
  `apt install ripgrep`. The `:latest` and `:winamd64` images carry it from their next chain.
- `rg -n PATTERN`, `rg -l PATTERN`, `rg --files -g '*.ps1'`; add `-uu` when the ignored trees are
  what you are looking for.
- A script that may run where `rg` is absent (a CI runner, an older image) keeps `grep`, or checks
  `command -v rg` first.

### Where does knowledge belong? (docs, not just code)

A fix that only exists in code is a fix the next reader re-derives. Write the WHY on the page that
owns the topic ([`docs/INDEX.md`](docs/INDEX.md) maps them and opens with the rule) and link it
from the code. A CONSUMER repo's split: [`shared/templates/README.md`](shared/templates/README.md).

### Comments: one line, only the why

Owner rule for every repo of the family. Comment like an experienced developer:

- One line. No comment blocks.
- Only the why: a non-obvious reason, a trap, a load-bearing constraint. Code that needs a
  what-comment needs a better name instead.
- No narration, restated code, incident history, dates, decision prose, or commented-out code.
- A trap that needs more gets a short paragraph on the `docs/` page that owns the topic, and
  the code keeps a one-line pointer: `# See docs/build-cache-tiers.md § 5.1`.
- API docs stay, but short: a one-line docstring, `///` or `.SYNOPSIS`, with parameters only
  where they are not obvious.
- Not comments: license headers, shebangs, tool directives (`# shellcheck`, `# noqa`,
  `#requires`, `// NOLINT`, ...) and markers a tool or test reads.

The comment-size gate (`linux/scripts/verify_comment_size.py`) holds every tracked source file, in
every language, to this:
[`code-quality-tooling.md`](docs/code-quality-tooling.md#comment-size-comment-size). Older text
around it is no excuse; hold the line. Prose for the owner follows the same rule: short sentences,
plain words.

### Contributing Reusable Work Here

Consumers push reusable work upstream rather than keep local copies. Wire a new project with
[`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md) before hand-rolling any
of it in a consumer. When adding here
([repository-family.md § Contributing reusable work](docs/repository-family.md#contributing-reusable-work)):

- Reuse before adding: extend the canonical implementation, and keep consumer-specific values as
  parameters whose defaults keep the original behaviour.
- PowerShell is pwsh 7: every `.ps1`/`.psm1` declares `#requires -Version 7.0`, and its file name
  follows one of the three documented shapes.
- Exporting a function a build script calls directly is two edits: `Export-ModuleMember` and the
  re-export list.
- Never rename a frozen snake_case Bash file or a reusable workflow file: consumers resolve them by
  path.
- Delete a hub file only when the consumer inventory reports it named by nobody.

### Reusable Module: WindowsContainerBuild.Reuse

The container-reuse API consumers build on:
[`docs/windows-builds.md`](docs/windows-builds.md) § Reusable module: WindowsContainerBuild.Reuse.

### Building Projects Inside the Windows Image (performance)

Everything write-heavy stays OFF the bind mount, and the CPU clamp is not optional on this host.
What to mount where, and the measured envelope:
[`windows-build-resources.md`](docs/windows-build-resources.md).

### Windows Build Invariants (do not regress)

The load-bearing rules — pwsh discipline, the gates that must stay armed, probe and log
discipline, layer/scratch rules, lane and CNI rules, the build-input invariants — live grouped and
individually linkable in
[`docs/windows-build-invariants.md`](docs/windows-build-invariants.md). Read it before editing
anything under `windows/`. Each entry carries the incident that produced it; a rule whose
evidence no longer matches the code is a bug in the rule.

The three most often regressed:

- pwsh 7 everywhere: no `powershell.exe`, no `cmd` SHELL directives.
- Every BK chain ends with a mandatory smoke gate: `-SkipSmokeGate` is for chain iteration
  only, never for "it passed locally".
- `versions.env` is the single source of truth: never hardcode a version in a script or
  Dockerfile. Host-tool pins no image build reads live in `tool-pins.env` beside it (§ Version
  Bumping).

### TensorRT Setup

The Windows `-Gpu` lane downloads the pinned TensorRT zip and checks its SHA256; a zip staged in
`windows/downloads/` wins. A missing TensorRT fails the nvidia lane; never restore the graceful
skip. Layout and rules: [`windows-cross-builds.md`](docs/windows-cross-builds.md).
ORT's CUDA and TensorRT EPs are plugins on that lane; never restore `USE_TENSORRT` or the
provider-bridge CUDA EP: [the plugin EPs](docs/windows-cross-builds.md#the-cuda-and-tensorrt-plugin-eps).

### QNN / Qualcomm AI Engine Direct Setup (Optional, #121)

Windows stages the login-gated, EULA-bound zip by hand, never committed, only the README riding
along: [`windows-cross-builds.md`](docs/windows-cross-builds.md). Linux arm64 fetches the public
Community zip at `QNN_SDK_VERSION` through the asset mirror; a zip in `linux/qnn-sdk/` is the
override and must match the pin: [`qnn-linux.md`](docs/qnn-linux.md).

### Windows Build Notes

The lane's notes live with the lane: [`windows-builds.md`](docs/windows-builds.md) and
[`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Orchestrator Stage Selection

Resume mid-chain, build one stage, or `--parallel-archs`:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Orchestrator stage selection.

### Runtime Helpers

Wrapper builds, manifest publishing and manifest repair:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Runtime lane helper commands.

---

### GPU architecture coverage (how to turn an arch on or off)

`CUDA_ARCHITECTURES` in `versions.env` is the one source of truth for the CUDA arches, and changing
the set is an owner decision, never a speed lever. How to add or remove one, and which number you
need: [`linux-accelerator-images.md` § GPU architecture coverage](docs/linux-accelerator-images.md#gpu-architecture-coverage).

## Build Workflow

Resume Windows with `-Stages @('media-merge','torch','final')` only after all three media branches
complete, and keep every reused-parent publish gate
([the merge boundary](docs/windows-build-lanes.md#resume-from-completed-media-branches)).

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
CROSS_VARIANT=nvidia|rocm       → (shared sdk) → gpu → media → android → runtime → manifest
```

A variant chain is the only way to build a GPU image. Set `CROSS_VARIANT=nvidia` or `rocm` in the
environment, and run chains strictly one at a time
([§ A variant chain](docs/linux-cross-builds.md#a-variant-chain-starts-at-gpu--and-inherits-the-shared-sdk)).
Each stage's registry digest is pinned into the next; the full pipeline is
[`linux-cross-builds.md`](docs/linux-cross-builds.md).

The Windows lane is a separate staged build driven by `windows/Build-Buildkit.ps1`:
`docs/windows-builds.md` § Build Commands.

### Prerequisites

A Linux host needs the rootless container stack, the GPU driver stack for the lane it builds, and
disk for the chain spine. What to install, in what order, and how to verify each piece:
[`linux-host-setup.md`](docs/linux-host-setup.md). Re-register QEMU/binfmt after a host reboot or
a containerd restart, or an emulated leg fails with `exec format error`.

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

Install Stevedore and reboot; run nerdctl from admin shells only, with the CNI nat conf, and run
images with `--isolation process`: `docs/windows-builds.md` § Prerequisites.

### Stevedore Fixes After Install

Apply the post-install fixes in `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes.
Keep the patched runhcs shim and `TcpTimedWaitDelay` = 30 s on every Windows build host
([`windows-host-setup.md` § R1](docs/windows-host-setup.md#r1-rebuild--deploy-the-patched-shim),
[§ C6](docs/windows-host-setup.md#c6-tcptimedwaitdelay--30-s-required-for-a-chain-without-idle-tails)).

### Supported Platforms

`linux/amd64`, `linux/arm64`, `linux/riscv64` on the Linux lane; `windows/amd64` on the Windows
one. `windows/arm64` is NOT a platform: the arm64 output is a cross-built artifact bundle in a
`windows/amd64` image (§ Image and tag naming). riscv64 carries two documented exemptions, and a
platform not on this list is not "probably fine": [`overview.md`](docs/overview.md).

### Expected Outputs

What a finished chain leaves behind, per stage and arch, and which of it is pushed rather than
local: [`overview.md`](docs/overview.md) and
[`cross-build-verification.md`](docs/cross-build-verification.md).

## Repo Map

One line per top-level directory, each linking what describes it:
[`overview.md` § Repo map](docs/overview.md#repo-map).

Grade a deletion in `lib/`, `02-toolchain/rust/`, `02-toolchain/python/` or `06-packaging/` with
the consumer inventory first; consumers call those trees more than this repo does: § Contributing Reusable Work Here and
[`consumer-inventory.md`](docs/consumer-inventory.md).

## Shell safety conventions (five bug classes, all found live 2026-08-08)

Write and review bash against the five bug classes, each of which broke a real build:
no `trap … RETURN` in a function, `|| true` on a pipeline whose empty result is legitimate,
comma lists split with `IFS=',' read -r -a`, vendor scripts sourced with nounset suspended, and
no function that ends in a bare `[ cond ] && action`. When you measure a run, use `grep -e`,
sort both `comm` inputs with `LC_ALL=C`, and never count warnings in a BuildKit log. Each class
and trap, with its fix:
[`shared-script-libraries.md` § Shell safety conventions](docs/shared-script-libraries.md#shell-safety-conventions).

## Background jobs and test processes (no ghosts)

No child may outlive what started it. Start a background job through `systemd-run --user` as a
named unit with `RuntimeMaxSec`, never through `setsid nohup`.
A test fixture ends on its own, tests run as process groups that are killed whole, and a wait
loop waits on a PID or a file with a timeout. The four rules and the ghost-watch net:
[`linux-host-setup.md` § B11](docs/linux-host-setup.md#b11-background-jobs-and-test-processes).

## Delegated Windows storage maintenance

Reclaim Windows storage only through the installed delegated maintenance tasks and their fixed
policy. Every rule, and how a new host gets them:
[`windows-stevedore-and-docker.md` § Delegated maintenance invariants](docs/windows-stevedore-and-docker.md#delegated-maintenance-invariants).

## Caching discipline (do not regress)

Freeze the base and toolchain closure between runs that should hit the cache, and keep
`buildkitd.toml`'s GC budget. Restart buildkitd only between runs. One resolver,
`compiler_cache_launcher()`, decides the compiler cache: never name a cache tool at a call site,
never copy the decision, and keep both cache mounts on every RUN that compiles. Never edit a
running orchestrator's main script. Windows caches on other mechanisms. The five rules:
[`build-cache-tiers.md` § Caching discipline](docs/build-cache-tiers.md#caching-discipline);
tiers and failure classes: [`build-cache-tiers.md`](docs/build-cache-tiers.md).

## Code Organization (key shared utilities)

A new environment knob takes the prefix of whoever owns the DECISION, not of the file that
happens to read it. The four prefixes:
[`adopting-in-a-new-project.md` § 8](docs/adopting-in-a-new-project.md); the `env-knobs` gate
grades this repo's own surface against them.

Use the shared helper for arch resolution, dry runs, tags, the stage graph, ancestry, version
forwarding and the nerdctl build, never a local copy:
[`shared-script-libraries.md` § Key shared utilities](docs/shared-script-libraries.md#key-shared-utilities)
names each one.

### Module Loading Order

**Which loader a NEW script uses is a rule, not a preference.** A script that can run inside a
container loads through `source_module`, which resolves both layouts; host-only orchestration
sources `artifact-common.sh`. Mixing them breaks at `/opt/scripts`, and a suite freezes the load
order. The dependency order and the one known wart:
[`shared-script-libraries.md`](docs/shared-script-libraries.md).

## Cross Chain Stage Handoff (do not regress)

- **`CROSS_ARCH_PIPELINE=1` is opt-in, and its per-lane disk guard removes only named tags of arches
  that finished**; never a prune with a lane in flight
  ([one pipeline per arch](docs/linux-cross-builds.md#one-pipeline-per-arch)).

- A stage's parent is pinned by DIGEST, never by tag. A tag can move between the moment a
  child resolves it and the moment it builds; that is how a chain built on a stale parent and
  shipped it green.
- Every image carries its ancestry annotation (`org.kataglyphis.parent-digest`), which lets
  `--verify-chain` answer FRESH/STALE instead of guessing from timestamps.
- A partial run asserts its ancestors before building and REFUSES a stale one.
  `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0` is a deliberate override, not a workaround to
  reach for.

How the handoff is built, why the digest pin is load-bearing, and the stale-base propagation trap:
[`linux-cross-builds.md` § Why the handoff must be pinned by digest](docs/linux-cross-builds.md#why-the-handoff-must-be-pinned-by-digest).

## Five Critical Fixes To Maintain

Always preserve these. Canonical reference: `docs/linux-cross-builds.md` § "Five Critical Fixes";
CI validates them through `linux/scripts/verify-critical-fixes.sh`.

## Linux Build Rules

Each rule links the page that explains it.

- Build with `nerdctl`, and keep both the QEMU multi-platform lane and the cross-build lane
  working ([§ Rules for the Linux lane](docs/linux-cross-builds.md#rules-for-the-linux-lane)).
  The other rules without a link of their own are explained there too.
- Never remove LLVM or Clang features to make a foreign-arch build pass, and never swap the
  source-built clang or GCC for the distro copy.
- Never trim `build-gcc.sh`'s target list back to libgcc, libstdc++ and libatomic: the native GCC
  must ship libsanitizer
  ([§ The native GCC ships libsanitizer](docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer)).
- Verify every network fetch against a sha256 in `versions.env`, pin every Python build executor,
  and never `curl | sh`.
- Never drop the optional runtime payloads or the LLVM normalization from `Dockerfile.package`.
- Read the call site before you escalate a miss from `install_target_packages`: a guarded miss is
  information, an unguarded one a missing library.
- Our source-built prefixes must win the include path: put `-I${PREFIX}/include` ahead of the
  multiarch entries, and do not take a green arch as proof for the others.
- The arm64 GPU lane is SBSA CUDA, built with the image's GCC and with `87` in
  `CUDA_ARCHITECTURES`
  ([§ NVIDIA on arm64 (SBSA)](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson)).
- Never give one nerdctl build two `oci-layout://` contexts
  ([failure-modes.md](docs/failure-modes.md#a-no-push-wrapper-build-cannot-find-its-own-android-image)).
- riscv64 builds `onnxruntime-genai` itself; never re-add an arch guard.
- riscv64 cross probes read only target pkg-config metadata; keep the native `PKG_CONFIG_PATH`
  out of `riscv64_cross_env`.
- Record a feature-parity exemption only in `_parity_exempt` in
  `06-packaging/smoke-runtime-image.sh`, never in prose.
- The runtime VENV-SET probe skips only when `packaging` or the app distribution is absent.
- Never revert the ISA floors: riscv64 builds with the vector extension and amd64 for
  `x86-64-v3`, both through `--with-arch` in `build-gcc.sh`
  ([riscv64-rva23-baseline.md](docs/riscv64-rva23-baseline.md),
  [amd64-x86-64-v3-baseline.md](docs/amd64-x86-64-v3-baseline.md)).
- Intel's GPU user space is the free build in every amd64 image; never install
  `intel-media-va-driver-non-free`
  ([§ Intel GPU user space](docs/linux-accelerator-images.md#intel-gpu-user-space)).
- Keep both build paths of riscv64's web-lane tools
  ([§ Building the web-lane tools from source](docs/consumer-image-contract.md#building-the-web-lane-tools-from-source)).
- Keep both deliveries of the wrapper's `/opt/wheels`, with no fallback between them
  ([§ The wrapper's wheelhouse](docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries)).
- Keep both Hailo switches, and never soften either check under its default
  ([hailo-support.md](docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches)).
- DeepStream is on in every amd64 nvidia build; never put its `lib` directory on `ld.so.conf`
  ([§ DeepStream](docs/linux-accelerator-images.md#deepstream-nvidia-variant)).
- TensorRT 11 is on in every amd64 nvidia build, and a published image ships only its runtime
  files ([§ TensorRT 11](docs/linux-accelerator-images.md#tensorrt-11)).
- `CHROME_EXECUTABLE` names the `/usr/local/bin/chrome` wrapper, never the binary
  ([§ Browser tests](docs/consumer-image-contract.md#browser-tests-run-in-chrome-for-testing)).
- Nothing under `/opt` or `/usr/local` may need `libunwind.so.8`
  ([failure-modes.md](docs/failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind)).
- ONNX Runtime has exactly one source on both lanes, the chain build, and every EP that has a
  plugin is the plugin ([§ The rules on Linux](docs/onnxruntime-single-source.md#the-rules-on-linux);
  Windows: [windows-build-invariants.md](docs/windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23)).
- riscv64's Python lane gets a uv cache seed, never a `--find-links` wheel store
  ([§ The riscv64 uv cache seed](docs/consumer-image-contract.md#the-riscv64-uv-cache-seed)).
- A free-threaded media wheel goes to `/opt/wheels-free-threaded`, decided by
  `03-media/free-threaded-twins.txt`
  ([§ The free-threaded wheels](docs/consumer-image-contract.md#the-free-threaded-wheels)).

## Dockerfile.media BuildKit Strategy

The media stage fans out into parallel branches and merges them, so a change that serialises the
fan-out or widens a branch's mount costs hours per run. Read the strategy before editing that
Dockerfile: [`linux-accelerator-images.md`](docs/linux-accelerator-images.md) and
[`build-parallelism-memory-tuning.md`](docs/build-parallelism-memory-tuning.md).

## Push And Publish Rules

Fix a red `develop` first: before you push to any family repository, look for an open
`develop-red` issue in the hub. Push only the final
wrappers and manifest; `--push-all` only when asked. A manifest run never shrinks a published
index, and a published image's environment names nothing outside the container. Every rule:
[`linux-cross-builds.md` § Push and publish rules](docs/linux-cross-builds.md#push-and-publish-rules).

## Validation

Four places run the gates, each a different set on purpose: the commit hook, the push hook,
`make preflight` by hand and CI on every push. Install the hooks once with `make hooks`. What each
runs and what it costs: [code-quality-tooling.md § The pre-commit hook's cost budget](docs/code-quality-tooling.md#the-pre-commit-hooks-cost-budget)
and [§ The pre-push hook](docs/code-quality-tooling.md#the-pre-push-hook).

- Push with `--no-verify` only with a by-hand `--changed` proof named in the report. After
  `git commit --no-verify`, run `make preflight` before pushing.
- CI never samples the mutation gate, and a slow gate means a slow suite to fix, not a timeout to
  raise ([§ The mutation gate in CI, sharded](docs/code-quality-tooling.md#the-mutation-gate-in-ci-sharded)).
- Keep the hub workflow's ref-scoped concurrency, so an active `develop` preflight finishes
  ([ci-build-triggers.md § This repository's lanes](docs/ci-build-triggers.md#this-repositorys-lanes)).
- Never close, reopen or edit a develop-red issue to make a push go through
  ([A red develop opens an issue](docs/github-cli-pipeline-monitoring.md#a-red-develop-opens-an-issue)).
- Never retype a number a gate can measure
  ([§ Doc numbers are derived](docs/code-quality-tooling.md#doc-numbers-are-derived)).
- `linux/scripts/preflight.sh` is the single source of the gate list. Never copy its slugs into a
  page or a new caller ([§ The gates run side by side](docs/code-quality-tooling.md#the-gates-run-side-by-side)).
- Keep new Ansible shell scripts in the default ShellCheck scan
  ([ShellCheck warning ratchet](docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings)).
- Linux host config is code: reconcile drift through `linux/host-config/`, never by editing
  `~/.config` alone ([§ Phase B](docs/linux-host-setup.md#phase-b--container-runtime-host-config)).
- Reclaim Linux disk only with `linux/host-config/prune-safe.sh`, never `nerdctl builder prune -f`
  ([§ B7](docs/linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches)).
- Remove unused QA environments only with `cleanup-qa-venvs.py` and a reviewed list
  ([§ Unused QA environments](docs/local-proof-workflows.md#unused-qa-environments)).
- Install or upgrade the host toolchain only from the nerdctl-full bundle
  ([§ B3b](docs/linux-host-setup.md#b3b-install-or-upgrade-nerdctl-full),
  [§ B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo)); riscv64 needs
  more ([§ D4](docs/linux-host-setup.md#d4-python-cli-tools-that-build-from-source-on-riscv64)).
- Never "delete all untagged" ghcr versions by hand
  ([§ B8](docs/linux-host-setup.md#b8-ghcr-registry-hygiene)).
- Reclaim Windows host disk only with `windows/scripts/host/Clear-DiskSpace.ps1`
  ([§ Host disk reclaim](docs/windows-host-setup.md#host-disk-reclaim)).
- Never add an exception or raise a limit to silence a PowerShell lint, test or complexity finding
  ([§ Windows PowerShell complexity](docs/code-quality-tooling.md#windows-powershell-complexity)).
- Verify a runtime image inside a container, never with `readlink -f` against
  `out/linux-runtime/*/rootfs` ([§ Runtime verification](docs/cross-build-verification.md#runtime-verification)).
- The `wrapper-smoke` gate is mandatory: nothing of an arch is pushed or exported before it passes
  ([§ The wrapper-smoke gate](docs/linux-cross-builds.md#the-wrapper-smoke-gate-runs-beside-the-wrapper-build)).

## Dependency Updates

The rules; the mechanism is documented once in
[`dependency-updates.md`](docs/dependency-updates.md).

- **Upgrades are driven by Renovate run as a LOCAL CLI, in every repo of the family** (owner directive), not by hand and not by waiting for a bot. The GitHub App is installed
  nowhere here and will not be: this is the permanent mechanism, not a stopgap.
- A run REPORTS. `--apply` only when the owner asked for it in that turn (owner directive). `linux/scripts/renovate-local.sh .` reports; `--apply --dry-run` prints the plan;
  `--apply` writes gitlinks, manifests and locks, for every ecosystem the repo has.
- Gitlink pins, the CLI self-check, owner-wide runs, custom regex managers, the riscv64 Torch pair, the
  default submodule sweep and consumer bootstraps each have their rules in
  [`dependency-updates.md` § Renovate driver invariants](docs/dependency-updates.md#renovate-driver-invariants).
- `linux/scripts/git-sync-branches.sh` is not that command. It puts working trees on their
  branch tip for local work, fast-forward only, third-party submodules included unless
  `--owned-only`, and commits no gitlink:
  [`adopting-in-a-new-project.md` § Putting every checkout on its branch](docs/adopting-in-a-new-project.md#putting-every-checkout-on-its-branch).

What `--platform=local` cannot do, why `--enabled-managers` is not enough, which git must run the
apply half, and what a stale lockfile does: [`dependency-updates.md`](docs/dependency-updates.md).

## Common Failure Modes

Every failure this repository diagnosed twice is written up once, with the symptom that
identifies it and the fix that worked: [`failure-modes.md`](docs/failure-modes.md). Read it before
theorising: the expensive ones here all looked like something else first (a cache miss that was a
GC floor, a stale image that was a push-not-content check, an `fchmod` error that was a host
mount).

## Version Bumping

- **`linux/scripts/01-core/versions.env` is the single source of every version in this
  repository.** A literal anywhere else is a second source that will disagree. The ARG-consistency
  and advertised-key gates exist because it did.
- Host-tool pins go in `01-core/tool-pins.env` instead: shellcheck,
  gitleaks, hadolint, actionlint, mold, binaryen, ruff, syft, Renovate, dartdoc. `Dockerfile.base`
  bind-mounts `versions.env`, so any edit to it rebuilds the compiler image, even for a lint tool.
  A pin no early stage (base through android) reads goes in `tool-pins.env`; one such a stage
  reads stays in `versions.env`. The torch stage reads shellcheck's and hadolint's from
  `tool-pins.env`. Renovate, `bump_versions.py` and `sync_versions.py` read both files.
- Dart API docs use the separately pinned generator. The shared builder resolves it into
  the project's isolated `.dart_tool/dartdoc-tool` cache; keep redundant `dart doc` overrides
  out of consumers. Explicit custom commands still win. The SDK-bundled tool can lag fixes;
  see [the generator contract](docs/shared-script-libraries.md#the-api-generator).
- Never hand-edit a derived file. `python docs/scripts/sync_versions.py --write` propagates a
  pin into the docs, the deps table, the Dockerfile ARGs and the PowerShell defaults; `--check` is
  a preflight gate, so a hand edit is caught rather than shipped.
- A version with a checksum moves with its checksum. `bump_versions.py` owns those pairs: a
  pin updated without its digest is an unverified download that still looks pinned.

Key layout, coupled pairs and report tiers: [`dependency-updates.md`](docs/dependency-updates.md)
and [`cross-build-verification.md`](docs/cross-build-verification.md#per-arch-version-truth).

## Development Rules

- Every script starts with `#!/usr/bin/env bash`. `set -euo pipefail` is for entry points
  only: a sourced file must not change its caller's shell options. The libraries under
  `linux/scripts/lib/` set no shell options at all
  ([`docs/shared-script-libraries.md`](docs/shared-script-libraries.md)), and neither do the
  `01-core/` framework modules loaded through `source_module` (`logging.sh`, `common.sh`,
  `build-helpers.sh`, `platform.sh`, `verify.sh`, `downloads.sh`, …). Two deliberate exceptions,
  each documented at its own file scope: `01-core/python_uv.sh` (a consumer inherits strict mode
  from it) and the test suites, which run `set -u` without `-e` because the harness accumulates
  failed assertions and decides the exit code itself. Use `run()` from `build-helpers.sh`.
- Source `artifact-common.sh` for shared utilities. Use
  `parse_shared_orchestrator_args()`/`parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` before the build loop.
- Use the centralized helpers: `resolve_arch_list()`, `is_dry_run()`,
  `append_mirror_build_args_from_env()`, `append_version_build_args()`,
  `normalize_target_arches()`.
- New OS packages → `Dockerfile.base`. Compiler changes → `Dockerfile.toolchain`. SDK/frameworks →
  `Dockerfile.sdk`. Media libs → `Dockerfile.media` + `03-media/build/`. Android →
  `Dockerfile.android`. GPU → `Dockerfile.nvidia`/`Dockerfile.amd`.
- New architecture: add it to `CROSS_DEFAULT_ARCHES` in `versions.env`, update the cross-target
  lists, add its triple mapping in `platform.sh` and its checksums in `versions.env`, and verify
  QEMU/binfmt.

## `.dockerignore` Guardrail

**Never exclude the `linux/` directory from `.dockerignore`.** Every Linux Dockerfile `COPY`s from
under it, so a blanket exclusion breaks each one with `failed to compute cache key: ... not found`.
Exclude specific large subdirectories if a context needs shrinking, never the directory itself.

`linux/.dockerignore` is a SEPARATE allowlist for builds whose context is `linux/` (the
compose-built webserver image): every `COPY` source in `webserver/Dockerfile` from THAT context
needs a negation there. The built site is not one of them: it arrives through a named build
context (`--build-context site=...`), which this file does not filter.

## Reusable Sphinx Theme Package

The shared theme and its `conf.py` snippet:
[`docs/project-info.md`](docs/project-info.md) § Reusable Sphinx theme package.

## Documentation Maintenance

Write docs like a developer: short and precise. Say what a thing does, how to run it and what
breaks. The rules and templates: [`docs/writing-docs.md`](docs/writing-docs.md); the `doc-prose`
gate holds each page to a census that may only fall.

- [`docs/INDEX.md`](docs/INDEX.md) decides which page owns which topic. Add a row when you add
  a page.
- A README is an overview, here and in every consumer: at most 100 lines, 700 words and 160
  characters a line ([`docs/repository-family.md` § The README rule](docs/repository-family.md#the-readme-rule)).
- The theme and the brand belong to DocumANTation. Change `custom.css` there, not here.
- Change `docs/pyproject.toml` and `docs/uv.lock` together
  ([`docs/project-info.md`](docs/project-info.md#building-the-hubs-docs)).

How each docs gate decides, and what its allowlist means:
[`code-quality-tooling.md`](docs/code-quality-tooling.md).
