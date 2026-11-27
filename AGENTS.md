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

1. **Fastest possible build.** Cache-first: narrow per-file closures, local cache exports, the
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

**One published tag is one MANIFEST, carrying every architecture its variant supports** (owner directive), on both lanes. Both lanes publish into the SAME registry repo, so only one
owns the bare `:latest`: Linux does, and Windows keeps its lane qualifier (owner directive).

| | Default manifest | Variant manifest | Per-arch wrapper (internal) | Cross bundle (NOT a platform) |
| --- | --- | --- | --- | --- |
| Linux | `:latest` | `:latest-<variant>` | `:latest-<arch>`, `:latest-<variant>-<arch>` | — |
| Windows | `:winamd64` | `:winamd64-<variant>` | — (one platform) | `:winarm64` |

- The grammar is `<version>[-<variant>][-<arch>]`. `latest` fills the version slot, so a
  pinned release is `:2026.09` / `:2026.09-nvidia` with no new rule. Tags are parsed by position,
  which makes the next bullet a hard rule.
- `<variant>` names what makes the image different (`nvidia`, `rocm`), NEVER an architecture:
  `:latest-amd64` must stay unambiguous, which is why `amd` is spelled `rocm`. A new architecture
  adds an ENTRY to a variant's manifest; a new variant adds a TAG.
- A variant exists only for a stack that cannot ship in `:latest` (owner directive): CUDA and ROCm are multi-GB, driver-bound and mutually exclusive. An accelerator
  whose runtime fits is built INTO the default image: Hailo-10H (amd64/arm64, `Dockerfile.torch`)
  and QNN (arm64, from the pinned public QAIRT Community zip — `docs/qnn-linux.md`). There is no `:latest-hailo`
  or `:latest-qnn`; the standalone `:hailo` variant and `Dockerfile.hailo` were retired on
  2026-09-22 as a duplicate of the standard build. A variant chain builds a variant (§ Build
  Workflow), never `ENABLE_*` flipped on the default one: that pushed GPU bytes under the default
  tags.
- The per-arch images (`:latest-<arch>`, the stage tags `:latest-base-<arch>` /
  `:latest-package-<arch>`) are the wrappers the manifest is assembled from: implementation
  detail, consumers resolve the manifest.
- nvidia's cross stages (`gpu`, `media`, `android`) push to a separate, private package,
  `<repo>-stages` (owner decision). They carry TensorRT's SDK, which may ship only as
  runtime files, and GHCR sets visibility per package. Everything else stays in `<repo>`
  ([`linux-accelerator-images.md` § Stage images](docs/linux-accelerator-images.md#stage-images-a-private-package)).
- `:latest-cross` is RETIRED (owner decision), the old name of `:latest`. Nothing
  composes or pushes it, and `verify_ci_image_refs.py` rejects it under `.github/`. The registry
  tags outlive the code, deliberately (owner decision): work stays on `develop`. Since
  2026-09-25 the fleet calls this repo's composite actions and reusable workflows at `@develop`
  (owner directive; 110 refs across eight repos, none passing an explicit `image:`), whose
  `versions.env` names `:latest`; `main` still carries `CI_IMAGE_LINUX_TAG=latest-cross`, frozen
  at the last release that published it. The registry tags are gone since 2026-09-29 (owner decision): republishing `:latest` left `:latest-cross` alone on the old index
  `ec4bb68b`, and `ghcr-delete-tags.sh` deleted it and the three `:latest-cross-<arch>` wrappers.
  A lane still at `@main` fails at `docker pull`; move it to `@develop`.
- A new variant = a new manifest tag. The manifest lane REFUSES to shrink a published index
  (§ Push and Publish Rules), so a partial run cannot drop an architecture from one.
- Windows follows the variant rule for CUDA too (owner decision).
  `Build-Buildkit.ps1 -Gpu` (`-Variant nvidia`) builds under `bk-*-nvidia` stage tags and
  publishes `:winamd64-nvidia`, or `:winarm64-nvidia` for the cross bundle; `:winamd64` is CPU +
  DirectML. Before that the nvidia build wrote the default tags, so the `:winamd64` published on
  2026-09-22 carries CUDA until that tag's next publish. `Resolve-BkVariant` refuses a push to any
  other tag.
- Windows is the documented exception, a platform fact, not a convention: `windows/arm64` does
  not exist as a platform — Microsoft publishes no arm64 `servercore`/`nanoserver` base and Windows
  Server has no arm64 release
  ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)). The arm64
  lane cross-compiles inside the `windows/amd64` container and emits an artifact bundle, so
  BOTH Windows outputs are `windows/amd64` images. Two entries with the same platform cannot share
  a manifest, and the bundle must never be published as `windows/arm64`, so it keeps its own tag
  (`:winarm64`, documented as a bundle) and never joins `:winamd64`.

### Windows-Specific Naming

`Get-BkTag` (`windows/Build-Buildkit.ps1`) names the lane's local intermediate tags
`docker.io/local/kataglyphis:bk-<name>[-<arch>]`: `bk-windows-base`, `bk-windows-sdk`,
`bk-windows-toolchain`, the media fan-out branches `bk-windows-media-core` / `-media-litert` /
`-media-tvm` (media-core itself splits into `bk-windows-media-core-onnx` / `-ffmpeg` / `-opencv` /
`-hailo`), the merged `bk-windows-media`, and `bk-windows-torch` for the app stage. The arch
suffix is omitted for `windows-base`/`-sdk`/`-toolchain` (shared by both lanes) and appended
(`-arm64`) for everything downstream. A variant (`-Variant rocm`, or `nvidia` through `-Gpu`) adds
a `-<variant>` infix to every tag after `bk-windows-base` (`bk-windows-sdk-rocm` …
`bk-winamd64-rocm`), so a variant run never overwrites a default image. The final image is
`ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (`:winarm64` on the cross lane);
§ Image and tag naming says what those two tags may be. The un-prefixed
`local/kataglyphis:windows-*` names and `Get-MediaBranchTag` belonged to the classic driver
`build.ps1`, deleted 2026-08-31: neither exists any more. Full build sequence:
`docs/windows-builds.md` § Build Commands.

---

## Quick Reference

Commands, knob tables and per-stage recipes:
[`linux-cross-builds.md` § The command reference AGENTS.md used to carry](docs/linux-cross-builds.md#the-command-reference-agentsmd-used-to-carry).
The rules below stay here:

- **Never `pkill` the orchestrator.** `bash linux/scripts/stop-cross-chain.sh` finds the run by
  its pidfile and reaps the orphaned nerdctl/buildctl subtree; a `pkill` orphans the children and
  leaves the build solving.

- Never edit a file in a running chain's closure, and never restart buildkitd while a build
  solves (§ Caching discipline, rules 1 and 4).

- Verify the shipped BYTES, never the push. `:latest` (then `:latest-cross`) shipped STALE
  five times with every static gate and every smoke GREEN, because all of them checked the push,
  not the content. `verify-shipped-wrapper.sh` gates it in `build-runtime-manifest.sh`, over every
  arch, BEFORE the boot smokes and before the manifest is assembled; `WRAPPER_CONTENT_GATE=0`
  downgrades it to advisory, a decision and not a default. The saga and its root cause:
  [`cross-build-verification.md`](docs/cross-build-verification.md#verify-the-shipped-bytes).

- `--log-dir` is not universal. `build-cross-chain.sh` and `build-cross-stage.sh` tee each
  stage; the other three orchestrators do not take the flag, so pipe them through `tee` yourself.

- Python packaging cache prefixes stay command-scoped. With `PYTHON_BUILD_COMPILER_CACHE=on`,
  pass explicit single-executable `CC` and `CXX`, use the shared resolver and preserve callback
  bindings and raw failures. Never export the cache-prefixed compiler strings into package assembly.

- Preserve recurring operational scripts in the repo. The canonical implementation must be Git-tracked; an ignored `logs/` copy is evidence only. Promote a recurring helper before its next use, retain its required companions and parameterize run-specific inputs. The [operational toolkit](docs/local-proof-workflows.md) owns the reusable proof, checkpoint and authorized cleanup drivers. Reuse and extend the canonical helper; do not regenerate regular preflight, monitoring or probe drivers in scratch space.

- Generated run artifacts belong under `logs/`. Use `logs/build-logs/` for Linux stage logs
  and resource metrics, `logs/windows-build-logs/` for Windows BuildKit runs, and
  `logs/test-results/` for Python test reports and `logs/code-quality/` for ty and annotation
  reports, mutation results and complexity metrics. The directory is ignored by Git.
  Live `chain-status*.json` stays at the repo root.

- Pin a verified hub SHA in one consumer with the shared helper. Run
  `python3 linux/scripts/pin-antfrastructure-submodule.py --repo <consumer> --branch <branch> --sha <full-sha>`
  from this checkout; it stages only the initialized hub gitlink after checking both remotes.
  Commit and push the consumer separately, after the hub commit is published and green.

- Measure before and after. `quality-report.sh` (with `--perf-host`), `fleet-health.py`, `security-audit.sh` and
  `bench-history`: [`fleet-health.md`](docs/fleet-health.md) and [`vulnerability-scanning.md`](docs/vulnerability-scanning.md).

- Preview Python refactors before accepting them. `bash linux/scripts/refactor-python.sh --check`
  reports formatter drift; `--apply -- <tracked.py>` makes pinned safe Ruff edits and saves a
  patch under ignored `logs/code-quality/`. The on-demand `python-refactor.yml` workflow uploads
  its patch with read-only repository permissions. Review the patch and run the relevant gates
  before committing it. The general agentic loop drains the whole backlog and may commit; do not
  use it as an unattended single-file refactor driver.

### Windows Container Build

All stages use Ninja + clang-cl + lld-link on containerd + BuildKit + nerdctl, each tool where its
pipe ACL allows. Build non-admin with `windows\Build-Buildkit.ps1`, inspect `bk-*` images from an
ADMIN shell. A fresh machine follows [`windows-host-setup.md`](docs/windows-host-setup.md), not a
reconstructed sequence. Role split, lane mechanics, isolation policy and recovery paths:
[`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)
and [`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Running Linux containers (Rancher Desktop)

Use `nerdctl`, never `docker`, and check the image contract rather than assuming a host tool is in
the image (`jq` and `python3` are in the current Linux image). A GPU container on a Jetson needs three extra flags
under rootless nerdctl:
[`linux-host-setup.md` § B2b](docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
Recipes, mount traps and the one driver that answers them (`run-in-ci-image.sh`):
[`rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).
For repeatable Ubuntu WSL2 quality checks, run `bash linux/scripts/wsl-quality.sh setup`, then
`bash linux/scripts/wsl-quality.sh check`; it installs pinned tools and writes reports below
ignored `logs/code-quality/wsl/`. The Windows test leg uses native `pwsh.exe` through WSL interop;
Linux PowerShell runs lint and complexity. `--jobs N` also bounds nested Bash suites and ShellCheck.

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

Owner rule for every repo of the family. `develop` is the default branch; every
push to it runs the Linux x64 lane. Every other lane runs when a commit message asks for it
(`[ci windows]`, `[ci arm64]`, `[ci all]`, …) or when started by hand; every lane workflow has
`workflow_dispatch`. `main` moves only by a fast-forward to a `develop` commit whose full round is
green, and only the owner moves it, or an agent the owner tells to in that turn. Every push to
`main` runs every lane again and releases `v<version>` only when all are green. Tokens, merge
steps, workflow shape: [`docs/branch-and-release-strategy.md`](docs/branch-and-release-strategy.md).
The hub's Linux x64 and Windows x64 quality workflows expose manual dispatch.
Which repo follows it yet, and this repo's own triggers:
[`docs/ci-build-triggers.md`](docs/ci-build-triggers.md).

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

Consumers push reusable work upstream rather than keep local copies (BeschleunigerBallett's
AGENTS.md states this as a rule). Wiring a NEW project to this repo (submodule, module resolver,
Windows and Linux container builds, the agentic loop, launchers, CI actions) is a checklist in
[`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md). Read it before
hand-rolling any of that in a consumer.

When adding here:

- Reuse before adding (owner directive for every owned repo). Search the current repository and its submodules for an existing implementation before creating functionality. Reuse or extend the canonical repo or submodule surface; when none exists, add it once to a shared repo and wire consumers to it. Keep consumer-specific values as parameters. If a hard technical boundary prevents reuse, record the reason and keep the copy tied to its canonical source.
- PowerShell 7 (pwsh) is the standard shell and the Windows containers' default SHELL. Every
  `.ps1`/`.psm1` declares `#requires -Version 7.0` on line 1 (or directly under the SPDX header),
  before any `param()`. Two tracked files omit it on purpose, both pinned 5.1-parsable by a suite:
  the script that INSTALLS pwsh, and the delete guard, which must not fail OPEN on a host without
  `pwsh`. The two scripts in `linux/ansible/scripts/` omit it too: they can run under Windows
  PowerShell 5.1 on a managed host. Two Pester suites also lack it:
  `HostMaintenance.ToolLookup.Tests.ps1` and `StevedoreInventory.Tests.ps1`.
- PowerShell file names. Three shapes: PascalCase `Verb-Noun.ps1` with a `Get-Verb`-approved
  verb for scripts, `Windows<Area>.<Facet>.psm1` for modules, `<Subject>.Tests.ps1` for suites.
  Three tracked files sit outside all three on purpose: the delete guard, registered by that exact
  string, so a rename silently unregisters it, and `windows/scripts/build/rocm-checks/`, whose
  files are named after the component they check (`FFmpeg.ps1`, 2026-09-23). A
  `verb-noun-name.ps1` spelling anywhere is stale, not a variant: 101 scripts were renamed on
  2026-09-06.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`; consumers resolve
  them ANTfrastructure-first with a vendored fallback. The resolver is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](shared/windows/templates/README.md).
- Exporting a function a build script calls directly is TWO edits: `Export-ModuleMember` in
  the owning module, and the re-export list if the script reaches it through one. Module-INTERNAL
  use needs neither, so an omission is invisible on a dev box and surfaces as `CommandNotFound`
  hours into a container build. Two suites hold the two directions (every CALLED name resolves;
  every LISTED name exists); neither replaces the other.
- The two-consumer test. What a second consumer needs belongs here, not vendored twice. Moving
  one up, turn its project-specific values into parameters whose DEFAULTS keep the original
  behaviour, so the vendoring consumer can delete its copy with no behaviour change.
- Avoid mutual submodule links. This hub vendors DocumANTation; that consumer calls reusable
  workflows with `hub-checkout: true` instead of linking this hub back into its Git tree.
- Document the symptom, not just the fix: platform traps are found by recognising an error
  message, not by reading code.
- Keep functions free of consumer-specific paths, preset names and build directories; pass those
  in as parameters.
- Deleting is a consumer change. A hub file may be removed only when the consumer inventory
  (`linux/scripts/verify_consumer_inventory.py`, over every repo in `.github/consumers.json`)
  reports it *named by nobody*, and the deleting commit names the consumer commits that dropped the
  reference. A "zero callers" grep of THIS tree is no evidence. Consumers pin a submodule commit
  and reach modules by NAME or by backslash path, so they neither break at delete time nor appear
  in the grep. Four sweeps made that mistake; the last deleted three live files, restored a week
  later.
- Bash file names. New files are kebab-case. The snake_case names under `linux/scripts/`
  (`02-toolchain/python/ci_*.sh` and `build_python.sh`, `02-toolchain/rust/cargo_*.sh`,
  `_*_guard.sh` and `_cargo_wrapper.sh`, `version_util.sh`, `01-core/python_uv.sh`,
  `05-frameworks/flutter/flutter_checks.sh`, `06-packaging/package_archive.sh`) and
  `linux/webserver/scripts/flutter_integration_smoke_test.sh` are frozen. Consumer wrappers
  resolve them by path, so a rename breaks consumers for no structural gain.
- Workflow file names (owner decision, fleet-wide): kebab-case, one file per
  platform and arch (`linux-x64.yml`, `windows-x64.yml`), display names
  `<Platform> <Arch> · <what>`. The hub's REUSABLE workflows (`python-ci-*`,
  `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, the docs-site lane, and
  `release-publish`) keep their file names for good. Consumers call them at `@develop`, so a
  rename breaks the fleet in one push. Convention and the fleet's rename table:
  [`adopting-in-a-new-project.md` § Workflow file names and display names](docs/adopting-in-a-new-project.md#workflow-file-names-and-display-names).

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

Windows can resume with `-Stages @('media-merge','torch','final')` after all three
media branches complete. Reuse requires matching image-producing inputs and
digest-bound branch evidence; publish-gate success alone is not that proof.
Keep all three reused-parent publish gates, the merge disk/retry gates, compiler
cache requirement and ROCm post-media closure. An explicit merge refuses a branch
subset even without downstream stages; ordinary `media` still builds every branch.
Each reused-parent gate needs its own phase/log label, distinct from final publication,
so none of its receipts or timing rows can overwrite another. Retain ordinary
publish-gate headroom for these parent probes.
See [the merge boundary](docs/windows-build-lanes.md#resume-from-completed-media-branches).

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
CROSS_VARIANT=nvidia|rocm       → (shared sdk) → gpu → media → android → runtime → manifest
```

**A variant chain is the only way to build a GPU image**. `CROSS_VARIANT=nvidia` /
`rocm` (or `ENABLE_NVIDIA=true` / `ENABLE_AMD=true`, which imply it) is an ENVIRONMENT knob,
because `stage-defs.sh` builds the stage graph when it is sourced. It inserts the `gpu` stage,
suffixes every tag from there on with `-<variant>` (`tag-naming.sh` `cross_variant_infix`), pushes
nvidia's stages to the private `<repo>-stages` package (`cross_stage_repo`), starts
at `gpu` and refuses the shared stages, keeps its own `chain-status-<variant>.json` and
`logs/build-logs/<variant>/`, and refuses what it cannot build (`stage-defs.sh`
`cross_variant_refusal`, shared with `build-cross-stage.sh`): rocm off amd64. Any target that is
not the build platform's arch (CUDA/ROCm install for the BUILD platform, so a cross target would
ship its GPU libraries), except nvidia arm64; and a PUSHING run off `CROSS_BUILD_PLATFORM=linux/amd64`
(the shared `:cross-sdk-<arch>` is the amd64 lane's). An nvidia chain on amd64 cross-builds arm64
(SBSA) by default (owner directive): bare, it builds `amd64,arm64`; `CROSS_NVIDIA_SBSA=0` opts out. The runtime helpers refuse a default output tag under a
variant. Chains run strictly one at a time: the pidfile is claimed atomically at start, and a
live one makes a second chain refuse. Commands:
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md).

Stages 1-5 run on `linux/amd64`, or natively on an arm64 host with
`CROSS_BUILD_PLATFORM=linux/arm64` (run end to end on a Jetson AGX Orin,
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson)).
Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches),
delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the
next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`, against stale cache reuse. The stage
graph: `linux/scripts/01-core/stage-defs.sh`; full pipeline: `docs/linux-cross-builds.md`.

The Windows lane is a separate staged build, `base → [nvidia|rocm] → toolchain → media →
[migraphx → llama] → torch → final` (the bracketed rocm stages on `-Variant rocm` only; torch
assembles the OrchestrANT app env, `bk-windows-torch`, and final builds FROM it), driven by
`windows/Build-Buildkit.ps1` (Stevedore's `buildctl` against buildkitd; the docker-classic driver
`windows/build.ps1` was retired 2026-08-26 and deleted 2026-08-31: the one-driver bullet in
[`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)).
`bk-windows-sdk` is either a plain re-tag of `bk-windows-base` (CPU lane, default) or the NVIDIA
GPU stage `Dockerfile.nvidia` (`-Gpu` switch, same as `-Variant nvidia`) for a CUDA-enabled image.
`-Variant rocm` (amd64 only) puts `Dockerfile.rocm` in that sdk slot, under `-rocm` tags that never
overwrite the default ones; every media feature it enables is gated on
`(Get-GpuEnvironment).HasRocm` ([`windows-rocm.md`](docs/windows-rocm.md)). Full build sequence and
prerequisites: `docs/windows-builds.md` § Build Commands.

### Prerequisites

A Linux host needs the rootless container stack, the GPU driver stack for the lane it builds, and
disk for the chain spine. What to install, in what order, and how to verify each piece:
[`linux-host-setup.md`](docs/linux-host-setup.md). Re-register QEMU/binfmt after a host reboot or
a containerd restart, or an emulated leg fails with `exec format error`.

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

Stevedore (`winget install stevedore` or `choco install stevedore`) provides nerdctl +
containerd for Windows Containers; reboot after installing it. Docker Desktop or Rancher
Desktop work too, with `docker` commands. nerdctl needs the CNI nat conf
(`docs/windows-build-lanes.md` § Getting it going, step 2) and runs from admin shells only;
Stevedore's `docker.exe` stays the publish/inspect tool. Run with `--isolation process` for the
host's full CPU count (Hyper-V isolation is capped at 2 CPUs): `docs/windows-builds.md` § Running
the Image. The 2026-08-03 history of the conf is on that page.

### Stevedore Fixes After Install

Apply the post-install fixes in `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes
(Defender exclusions, daemon.json cleanup, default runtime change, verification), the canonical
source.

Two host fixes keep the BK lane's RUN steps from idling. `Install-NewHost.ps1` (admin) sets
both, `Test-HostSetup.ps1` checks both, and the from-base chain of 2026-10-14 measured both:

- The patched runhcs shim
  ([`windows-host-setup.md` § R1](docs/windows-host-setup.md#r1-rebuild--deploy-the-patched-shim)).
  Every Stevedore update reverts it, and the driver's `Assert-ShimPatch` then refuses to build.
  With it, a RUN reaches DONE 1 to 3 s after its last output line.
- `TcpTimedWaitDelay` = 30 s
  ([§ C6](docs/windows-host-setup.md#c6-tcptimedwaitdelay--30-s-required-for-a-chain-without-idle-tails)):
  a RUN that started an sccache server reaches DONE ~30 s after its last line, not ~120 s (#179).

A RUN's tail names the missing one: ~120 s after an sccache RUN is the TIME_WAIT; ~180, ~450 and
~2841 s are the shim. `docs/failure-modes.md` § Every RUN step reports `DONE 2841.2s` decodes them.

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

One line per top-level directory, each linking what describes it. No counts: every count written
here has gone stale, and `ls` answers faster.

| Directory | What lives there |
|---|---|
| `cmake/` | The shared CMake modules consumers `include()` — sanitizers, static analysers, cache, tests. |
| `shared/config/` | The canonical `.clang-format`, `.clang-tidy`, `.cmake-format.yaml`, `gcovr.cfg`, `.pre-commit-config.yaml`, plus the sync tool and the manifest that says which of them a consumer takes. `analysis_options.yaml` is the Dart analyzer config, which Dart consumers `include:` by reference instead. [README](shared/config/README.md) |
| `shared/linux/templates/` | Copy-and-edit bash: the `antfrastructure.sh` bootstrap, the `renovate-local.sh` wrapper, the consumer `git-hooks/`. [README](shared/linux/templates/README.md) |
| `shared/windows/` | The `Resolve-BuildModule.ps1` bootstrap template and the shared Pester suites consumers run (`Submodule.Pins.Tests.ps1`). [README](shared/windows/templates/README.md) |
| `shared/templates/` | The consumer `AGENTS.md` skeleton. [README](shared/templates/README.md) |
| `shared/agentic-loop/` | Cross-platform loop data: the planner/refactor/executor task prompts and the role system prompts both lane implementations read, plus the copy-and-edit consumer templates. [Templates](shared/agentic-loop/templates/README.md) |
| `docs/scripts/` | The docs gates and version tooling — `verify_doc_links.py`, `verify_doc_dupes.py`, `verify_code_dupes.py`, `sync_versions.py`, `bump_versions.py`, the SBOM pair, `mutations.json`. [Gate registry](docs/code-quality-gates.md) |
| `.github/actions/` | The composite actions consumers call `@develop`. [README](.github/actions/README.md) |
| `.github/workflows/` | This repo's own lanes plus the `workflow_call` ones consumers reuse (`python-ci-*`, `python-static`, `python-refactor`, `powershell-quality`, `code-quality-report`, `mutation-gates`, `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, which builds, checks and publishes every docs site: [`docs-sites.md`](docs/docs-sites.md), and `release-publish`, every `release.yml`'s version check and publish: [`branch-and-release-strategy.md`](docs/branch-and-release-strategy.md#the-reusable-release-workflow)). [Triggers](docs/ci-build-triggers.md) |
| `linux/scripts/` | The Linux build system: `01-core` (shared utilities), `02-toolchain` (GCC/LLVM/Rust/Python/CMake/Vulkan), `03-media` (per-library builds), `04-runtime` (entrypoint + env), `05-frameworks` (TVM, Torch, Flutter), `06-packaging` (assembly + smoke), plus the orchestrators and gates at its root. [Libraries](docs/shared-script-libraries.md) |
| `linux/llm-stack/` | The Ollama + Open WebUI serving stack. [README](linux/llm-stack/README.md) |
| `linux/jetson-webcam/` | A USB-camera object-detection PoC on a Jetson GPU, run in the arm64 GPU wrapper image. [README](linux/jetson-webcam/README.md) |
| `linux/webserver/` | The slim nginx image and the reusable Flutter-web helpers. [README](linux/webserver/README.md) |
| `linux/host-config/` | Host configuration as code: `buildkitd.toml`, the systemd drop-in, the apply/verify pair, the ghcr tools, and this repo's OWN git hooks (not the consumer ones). [Host setup](docs/linux-host-setup.md) |
| `linux/homeassistant/`, `linux/nextcloud-aio/`, `linux/ansible/` | The owner's personal operations stacks, deliberately carried here ([`docs/overview.md` § Home-lab stacks](docs/overview.md#home-lab-stacks-deliberately-here)). [HA](linux/homeassistant/README.md) · [Nextcloud](linux/nextcloud-aio/README.md) · [Ansible](linux/ansible/README.md) |
| `linux/vulkan/`, `linux/qnn-sdk/`, `linux/nvidia-local-debs/` | Staged SDK inputs. The QNN and NVIDIA trees are gitignored except their READMEs — login-gated, EULA-bound, never committed. |
| `windows/scripts/` | The Windows lane, grouped into `build/`, `host/`, `diagnostics/`, with `modules/*.psm1` as the reusable surface and `tests/` as its Pester suites. [Windows builds](docs/windows-builds.md) |
| `windows/upstream/` | Prepared upstream submissions, one directory per submission. NOT build inputs, and NOT to be posted without the owner saying so. [README](windows/upstream/README.md) |
| `windows/qnn-sdk/` | As `linux/qnn-sdk/`: gitignored but for its README. |
| `third_party/DocumANTation/` | The brand and style submodule every docs build reads. |
| `out/` | Generated artifacts (OCI layouts, rootfs exports). Gitignored and excluded from every build context. |

**Before deleting anything under `linux/scripts/lib/`, `02-toolchain/rust/`, `02-toolchain/python/`
or `06-packaging/`, grade it with the consumer inventory.** Those four hold CONSUMER SURFACE this
repo's own lanes barely or never call (in-repo, only `preflight.sh` and `flutter_checks.sh` source
`lib/code-quality.sh`; `06-packaging/` also holds the images' own packaging and smoke scripts), and
a 2026-08-08 sweep deleted `package_archive.sh` as "zero-reference" while a consumer's release job
was calling it. The rule and the mechanism: § Contributing Reusable Work Here and
[`consumer-inventory.md`](docs/consumer-inventory.md).

## Shell safety conventions (five bug classes, all found live 2026-08-08)

Each of these killed or falsified a real build before it was fixed. The full stories:
[`changelog-archive-2026-08-13.md`](docs/changelog-archive-2026-08-13.md);
`tests/test-ifs-safety.sh` lint-gates class 3. When writing or reviewing bash here:

1. **No `trap … RETURN` inside functions**: the trap survives the function and fires again on the
   CALLER's return, where the locals are gone (`set -u` abort AFTER a green run). Capture rc with
   `|| rc=$?` and clean up explicitly.
2. Guard every pipeline whose empty result is legitimate: `grep`/`find`/`ls`/`du`/`pgrep`/
   `dpkg -S`/`readelf` in `$(...)` under `set -euo pipefail` needs `|| true` when the code below
   handles the empty case. `find | head -1` also dies of SIGPIPE (rc 141) on multiple matches.
   A large captured result must not flow through `printf | grep -q` under `pipefail`:
   an early match can close the pipe and turn a valid marker into `UNKNOWN`.
3. Split comma lists with `IFS=',' read -r -a arr <<< "$list"`, never `${list//,/ }` or
   `$(... tr ',' ' ')`. Under a script's `IFS=$'\n\t'` those do not split, and the loop runs once
   with the whole list as one bogus item. Sourced 01-core functions run under the CALLER's IFS.
   The two list helpers (`arch_list_to_words`, `smoke_arch_words`) emit NEWLINE-separated words
   since 2026-08-08 so `for x in $(...)` splits under any IFS; keep that if you touch them
   (test-smoke-arch-parity.sh pins it).
4. Source vendor scripts (SDK setup-env, venv activate) with nounset suspended:
   `case $- in *u*) …; set +u;; esac` … `set -u` after. LunarG's setup-env.sh reads `$1`
   unguarded.
5. Never end a function with a bare `[ cond ] && action`. The false case becomes the
   function's return value 1, and under `set -e` the HEALTHY path kills the caller. End with
   `|| true`, `; return 0`, or an `if`. Shell test predicates with an intentional false
   status use explicit `return 0` and `return 1` branches so the gate can distinguish intent.

Host tool traps when you MEASURE a run. These falsify your AUDIT, not the build; each produced
a wrong verdict on 2026-08-31, and none announces itself:

- `grep` on this host is ugrep. A pattern beginning `--` parses as an OPTION and silently
  matches nothing, so a fault-injection arm that never fires looks like a clean run. Always
  `grep -e "$pat"`. Symptom entry:
  [`docs/failure-modes.md`](docs/failure-modes.md#a-fault-injection-test-passes-and-proves-nothing-grep-is-ugrep).
- `comm` needs `LC_ALL=C sort` on BOTH inputs. Any other collation reports a wrong set
  difference that still looks like an answer. It turned "0 shared" into "36 shared" in one day's
  audits, and had made a preflight assertion pass vacuously.
- Never count warnings by grepping a BuildKit log. BuildKit echoes each RUN's command text, so
  a warning string written INSIDE a Dockerfile command counts as if it had fired. Match real
  output lines only.

## Background jobs and test processes (no ghosts)

On 2026-10-21 the build host carried a test fixture spinning at 100 % for 2.8 days and 24 headless
Chromes holding 22 GB, plus a watcher an agent had detached and another agent had to find in its
transcript. Each was a child that outlived whatever started it. So:

1. **An agent starts a background job as a named user unit**, never `setsid nohup … &`: `systemd-run
   --user --unit=<name> -p RuntimeMaxSec=<bound> bash <script>`. Then `systemctl --user list-units
   '<prefix>*'` shows what runs, `systemctl --user stop <name>` ends it with every child, and
   nothing outlives its bound. A job meant to outlive the session (a chain, a watcher) says so in
   its handoff, by unit name.
2. A test fixture ends on its own. A spin or a sleep has a bound (`while [ "${SECONDS}" -lt 60 ]`,
   `sleep 60`); a fixture that only a kill can end outlives every interrupted run.
   `run-tests.sh` gives each suite its own `TMPDIR` and fails one that leaves an entry there: use
   `t_mktemp`, or `t_private_tmpdir` when the code under test makes the trees.
3. Tests run as process groups that are killed whole. `lib-ordered-jobs.sh` starts every job of
   `run-tests.sh` and `preflight.sh` as its own process group and kills it when the job ends, after
   `OJ_TIMEOUT` (`RUN_TESTS_SUITE_TIMEOUT`, 900 s per suite) and, through `oj_reap` in the runner's
   EXIT trap, when the run is interrupted. The mutation gate ends each test's session after it, and
   every live one when it is itself killed, SIGTERM first so a runner inside can reap its own. A new
   runner that starts tests uses one of the two (`test-run-tests-reaping.sh`, the reaping cases of
   `test-mutation-gate.sh`).
4. A wait loop waits on a PID or a file, with a timeout. `until ! pgrep -f <pattern>` matches
   its own `bash -c` and never ends; `pkill -f <pattern>` can kill the shell that runs it.

`linux/host-config/ghost-watch.sh` is the net under all four: an hourly user timer that reports
orphans heavy on CPU or memory or shaped like test leftovers
([`linux-host-setup.md` § B10](docs/linux-host-setup.md#b10-ghost-watch)).

## Delegated Windows storage maintenance

Use only the installed delegated maintenance tasks and their fixed preview and reclaim policy. Use the
canonical selectors with full expected IDs; never force removal, lower a disk floor, terminate a build or
restart containerd. Every rule, and how a new host gets them:
[`windows-stevedore-and-docker.md` § Delegated maintenance invariants](docs/windows-stevedore-and-docker.md#delegated-maintenance-invariants).

## Caching discipline (do not regress)

Map: [`linux-build-basics.md` § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where).
Tiers, measurements and every failure class: [`build-cache-tiers.md`](docs/build-cache-tiers.md).
Toggles: `USE_CCACHE`, `USE_SCCACHE`, `USE_LLD` accept `0/false/no/off`;
`ENABLE_SCCACHE_RUST`/`ENABLE_SCCACHE_CUDA` are strict `0/1`.

The Windows lane's compile cache has two levels: each host's WebDAV, then an S3
bucket all hosts share, whose key travels only as BuildKit secrets
([`windows-build-resources.md` § Two cache levels](docs/windows-build-resources.md#two-cache-levels);
the server: [`linux/sccache-s3/README.md`](linux/sccache-s3/README.md)).

The rules:

1. **Freeze the closure.** A touched file inside it re-keys the compiler image, and everything
   downstream of that image recompiles. `Dockerfile.base` mounts named files rather than
   directories, so most edits are free; but a file a base RUN newly NEEDS (what it execs, not only
   what it sources) has to join those lists. Batch such edits into one commit at a planned
   rebuild boundary. Lists, costs and the one layer that still mounts whole directories:
   [`build-cache-tiers.md` § 1](docs/build-cache-tiers.md#1-the-tiers).

2. `~/.config/buildkit/buildkitd.toml` pins the GC budget (`gckeepstorage`) so the multi-hour
   layers survive between runs. Do not delete it; restart buildkitd only BETWEEN runs
   (`systemctl --user restart buildkit`), never while a build solves.
   The chain's disk guard does this itself once when a stopped run's records block its prune and
   no `buildctl` runs ([`build-cache-tiers.md`](docs/build-cache-tiers.md#a-stopped-chain-leaves-records-in-use)).

3. One resolver decides which compiler cache runs: `compiler_cache_launcher()` in
   `01-core/common.sh`, at RUNTIME, per call. Hence:
   - Never spell a cache tool's name at a call site: a literal in the SHARED
     `cmake-cache-linker.sh` decides for every consumer at once.
   - Send a new call site through the resolver; never copy the decision. Copies shipped inert
     twice, so `verify-critical-fixes.sh` refuses the shapes that did it.
   - Keep BOTH mounts on every heavy RUN: the fallback has to land somewhere.
   - Degrade, never disable: prefer `01-core/sccache-launcher.sh`, accept bare `sccache`, and
     treat "uncached" as a bug. `RUSTC_WRAPPER=""` is the one documented opt-out.
   - A build that runs its own compiles under `env -i` is out of the resolver's reach. HailoRT's
     nested protobuf build is the known case: `hailo-build-lib.sh` carries the cache into it, and
     a gate fails a build the cache did not reach.
   - A CMake build passes `append_cmake_compiler_cache_pin`'s defines and is gated by
     `cmake_assert_compiler_cache_pin`: pthreadpool and XNNPACK FORCE `CCACHE_BINARY` into the
     launchers, which beats the environment and a `-D` launcher alike
     ([`build-cache-tiers.md`](docs/build-cache-tiers.md#a-subproject-that-forces-its-own-launcher)).
   - Every RUN that compiles carries both cache mounts; its closing drain prints
     `sccache-stats|`, the number to read before calling a step cached.
   - The launcher's compile governor caps host-wide compiles by `flock` slots in the sccache mount.
     Keep its fd 9 off every child, and keep it on while `PAR_INTRA_STEP_BUDGET` is 2: it holds the peaks
     ([`build-parallelism-memory-tuning.md`](docs/build-parallelism-memory-tuning.md#the-compile-governor)).
   `--ccache` is a flag NAME, not a tool choice. Before a multi-hour run rides on a change here,
   `bash linux/scripts/02-toolchain/probe-sccache.sh` inside the compiler image answers in seconds
   whether a cache was actually consulted, which a successful compile does not.
   [`build-cache-tiers.md` § 5](docs/build-cache-tiers.md#5-scc1--the-ccachesccache-hybrid).

4. Never edit a running orchestrator's main script. bash reads it incrementally by byte
   offset, so an edit can corrupt the in-flight process. Sourced libraries are safe to edit for
   FUTURE runs, but see rule 1.

5. Rules 1-4 are about the LINUX chain. Windows caches on other mechanisms: where a layer sits
   relative to the Visual Studio install, how narrowly a module mount is scoped, and a GC floor
   that silently evicts the expensive layers when set too low. A Dockerfile edit there must keep
   the first two (a Pester suite refuses a whole-directory module mount). Check a cache miss that
   looks like a bad key against that floor first. Tiers, figures and the two incidents:
   [`windows-build-resources.md` § The Windows cache, tier by tier](docs/windows-build-resources.md#the-windows-cache-tier-by-tier).

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

- **A red `develop` is fixed before anything else lands on it**. Before every push in
  any family repository, `gh issue list -R Kataglyphis/ANTfrastructure -l develop-red`: an open
  issue names the repository, workflow and jobs that are red, with their runs. `develop-red.yml`
  opens it within half an hour of the red run and closes it when the jobs pass again
  ([`github-cli-pipeline-monitoring.md` § A red develop opens an issue](docs/github-cli-pipeline-monitoring.md#a-red-develop-opens-an-issue)).
- `build-runtime-artifacts.sh --push` pushes only the final per-arch wrapper images.
- `build-runtime-manifest.sh --push` pushes wrappers + the final manifest.
- `--push-all` only when explicitly requested (it publishes the `base`/`package` intermediates).
- Final cross release: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest` (the old
  `:latest-cross` name is retired and its registry tags were deleted on 2026-09-29, § Image and
  tag naming).
- Before rebuilding expensive foreign-arch wrappers, inspect the remote tags with
  `nerdctl manifest inspect`; if the wrappers exist remotely, recreate the manifest directly
  instead of rebuilding.
- The manifest lane REFUSES to shrink an already-published index.
  `_manifest_completeness_gate` in `build-runtime-manifest.sh` compares the arch count of the live
  tag with the arches this run carries and stops. The older coherence gate only asks whether the
  arches AGREE on a generation, so a single-arch run assembled a coherent ONE-arch index and
  published it. That is how `:latest` (then `:latest-cross`) was found reduced to riscv64 alone.
  Recover by re-running the runtime lane for the missing arches. `--force` and
  `RUNTIME_MANIFEST_COMPLETENESS=0` only bypass the early shell check: final promotion
  still preserves the published runtime platforms. A partial-arch run completes the
  published index only from children whose build key matches this run's, each gated and listed by
  digest ([`linux-cross-builds.md`](docs/linux-cross-builds.md#a-failed-arch-re-runs-alone));
  `RUNTIME_REUSE_CHILDREN=0` requires every arch in the run, and a different platform set gets its
  own tag.
- A published image's environment names nothing outside the container (2026-09-23, both
  lanes). A build-host setting (the sccache endpoint, a LAN mirror, a proxy) reaches a RUN as an
  ARG and never lands in an ENV: `:winamd64` shipped the owner's LAN WebDAV and broke every
  consumer's sccache. Three gates hold it, none with a skip switch: the static pass in
  `lint-dockerfiles.sh`; Windows' `Dockerfile.publish-gate`, solved on every parent a run inherits
  but did not build, on the fresh toolchain, and on the final image before any export or push
  (`-SkipSmokeGate` skips none of them); and `build-runtime-manifest.sh`'s image-env gate, first
  in `create_manifest` on every path, `--manifest-only` included. Cross such a fix by restarting
  a chain, never by resuming one: a driver started before it has no gate, and a parent built
  before it still carries the leak. Why, and what the gates cannot see:
  [`windows-build-resources.md` § What the published image carries](docs/windows-build-resources.md#what-the-published-image-carries).

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

**Write docs like a developer: short and precise.** Say what a thing does, how to run it and what
breaks. The rules and templates: [`docs/writing-docs.md`](docs/writing-docs.md); the `doc-prose`
gate holds each page to a census that may only fall.

- [`docs/INDEX.md`](docs/INDEX.md) decides which page owns which topic. Add a row when you add
  a page; the `doc-links` gate fails a page that no row and no toctree entry names.
- The docs gates run over this tree, not over a guess. `doc-links` checks every
  cross-reference and every `docs/*.md` pointer in code; `doc-dupes` catches a passage reworded
  into a second page. Budgets live in `docs/scripts/*.allow` with a reason, and a stale row fails.
- A consumer page that restates a hub page fails too, once the consumer seeds
  `doc-dupes-hub.allow`: `doc-dupes --against-hub` in `run-lint-gates.sh --ratchets`
  ([`code-quality-tooling.md`](docs/code-quality-tooling.md#consumer-pages-against-the-hub-doc-dupes---against-hub)).
- A README is an overview, here and in every consumer: at most 100 lines, 700 words and 160
  characters a line. Procedures go to `docs/`, family facts to this hub, and the README links to
  both: [`docs/repository-family.md` § The README rule](docs/repository-family.md#the-readme-rule).
  The `readme-length` gate checks it.
- The theme and the brand belong to DocumANTation. Change `custom.css` there, not here.
- Keep the docs lock current. Local docs builds sync `docs/uv.lock` through Astral uv; the
  image build checks it offline while using its shipped Sphinx stack. Change
  `docs/pyproject.toml` and the lock together; see
  [`docs/project-info.md`](docs/project-info.md#building-the-hubs-docs).

How each gate decides, and what its allowlist means:
[`code-quality-tooling.md`](docs/code-quality-tooling.md).
