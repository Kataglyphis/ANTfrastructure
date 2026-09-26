# ANTfrastructure — agent guardrails

**This file is the rulebook, not the manual.** It captures what an automated
agent must and must not do to avoid regressing the build, plus the canonical
build commands. Reference data — what is in an image, per-component build
matrices, script tables — lives in `docs/`; the map from topic to owning
document is [`docs/INDEX.md`](docs/INDEX.md).

Five companion pages carry what used to live here. Read the one that matches
what you are about to do:

| Before you… | Read |
|---|---|
| Edit anything under `windows/` | [`docs/windows-build-invariants.md`](docs/windows-build-invariants.md) — 49 load-bearing rules |
| Debug an error message | [`docs/failure-modes.md`](docs/failure-modes.md) — symptom → cause → fix |
| Launch or debug a Windows chain | [`docs/windows-build-lanes.md`](docs/windows-build-lanes.md) — BuildKit, nerdctl, classic (historical) |
| Wire a new project to this repo | [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md) |
| **Add or bump a dependency** | [`docs/third-party-licenses.md`](docs/third-party-licenses.md) § Maintaining this list — an `spdx` id is mandatory, copyleft needs a source pointer, and the build gates both |

## Contents

**Rules — never regress these.** [Project priorities](#project-priorities-owner-directive--optimize-for-all-three-always) ·
[Shell safety](#shell-safety-conventions-five-bug-classes-all-found-live-2026-08-08) ·
[Caching discipline](#caching-discipline-do-not-regress) ·
[Stage handoff](#cross-chain-stage-handoff-do-not-regress) ·
[Five critical fixes](#five-critical-fixes-to-maintain) ·
[Linux build rules](#linux-build-rules) ·
[Push and publish](#push-and-publish-rules) ·
[Development rules](#development-rules) ·
[`.dockerignore`](#dockerignore-guardrail) ·
[Contributing reusable work here](#contributing-reusable-work-here)

**Doing the work.** [Quick reference](#quick-reference) ·
[Build workflow](#build-workflow) · [Validation](#validation) ·
[Version bumping](#version-bumping) · [Dependency updates](#dependency-updates) ·
[Failure modes](#common-failure-modes)

**Orientation.** [Container architecture](#container-architecture) ·
[Repo map](#repo-map) · [Code organization](#code-organization-key-shared-utilities) ·
[Documentation maintenance](#documentation-maintenance)

Everything else this file used to carry is in `docs/`, which
[`docs/INDEX.md`](docs/INDEX.md) maps. The rule for what lives where: a RULE an
agent must not break belongs here; the MECHANISM behind it belongs on the page
that owns the topic.

## Project priorities (owner directive — optimize for ALL THREE, always)

1. **Fastest possible build.** Cache-first engineering: narrow per-file
   closures, local cache exports, the compiler cache wired end-to-end AND
   measured (stats to stderr, the stream a clipped step log keeps), a pinned
   buildkitd GC budget, and the parallelism levers taken when proven safe. Idle
   cores are the standing wall-clock reserve. Re-measure before citing any
   number — a CPU figure quoted here for weeks turned out to come from a broken
   sampler. Speed that risks a silently wrong image is not speed: correctness
   bounds every shortcut.
2. **Maximum stability.** Digest-pinned handoffs, machine-checked ancestry,
   verified version pins (checksums from official sources), the five shell
   bug classes (§ Shell safety conventions) never reintroduced, and gates
   that FAIL LOUDLY — an assertion-free PASS ("will work at runtime") or an
   inner warning swallowed by an outer green is a defect, not a success.
3. **Many tests.** Every fix ships with a regression test where testable: a
   unit suite under `linux/scripts/tests/` (auto-discovered, run by preflight's
   `script-tests` slug, NOT by the pre-commit hook), a lint gate, or a smoke
   assertion against a `versions.env` pin. **Mutation-test every new gate**:
   break the thing it guards and watch it go red before you trust it, and say
   in its header what it does NOT cover. A gate that cannot fail is worse than
   no gate — two audits have found one.
4. **Docs always follow the change — in the same work unit.** Any behavior,
   flag, workflow, or invariant change updates AGENTS.md (rules/quick-ref),
   README.md (user-facing pointers), the relevant `docs/` page, and
   `CHANGELOG.md` before the work is called done. A mechanism that only the
   git history knows about does not exist for the next session.
5. **Our build always wins over the distro copy** (owner directive
   2026-09-01). Where a `/opt` tree and a distro package export the same soname,
   ours must win the `ld.so` lookup: write `000-<name>.conf` into
   `/etc/ld.so.conf.d` (read in SORT order) and never rely on a purge, because
   another dependency pulls the distro copy back in. Enforced on the SHIPPED
   bytes by the soname-precedence gate. Same rule for `PATH`,
   `PKG_CONFIG_PATH` and `PYTHONPATH`.
6. **Short code comments. Long text goes in `docs/` and gets linked.** One or
   two lines at the point of use, only where the code cannot say it itself.
   Anything longer — forensics, dated evidence, why-not-the-obvious-thing,
   measured numbers, a failure narrative — moves into a `docs/*.md` page and the
   code carries a pointer to it. The owner reads code to read code; an essay in
   the middle of a function pushes the logic off screen. Full rule and worked
   example: § Comments: as few as possible, as short as possible.

## Container Architecture

One Dockerfile per stage, chained base → toolchain → sdk → media → android →
package → torch, with an optional `gpu` layer (`nvidia` or `amd`) between sdk
and media in a variant chain. Each stage is
built and pushed on its own and pinned into its child by digest, which is what
makes a single-stage rebuild possible at all.

The stage graph with its tags and platforms, and what each stage contains:
[`overview.md`](docs/overview.md) and
[`linux-cross-builds.md`](docs/linux-cross-builds.md). The naming rules that
must not drift are § Windows-Specific Naming below and
[`consumer-image-contract.md`](docs/consumer-image-contract.md).

### Image and tag naming (published tags)

**One published tag is one MANIFEST, and the manifest carries every architecture
its variant supports** (owner directive 2026-09-21). The same rule for both
lanes. The Linux and Windows lanes publish into the SAME registry repo, so only
one of them can own the bare `:latest`: Linux does, and Windows keeps its lane
qualifier (owner directive 2026-09-22).

| | Default manifest | Variant manifest | Per-arch wrapper (internal) | Cross bundle (NOT a platform) |
| --- | --- | --- | --- | --- |
| Linux | `:latest` | `:latest-<variant>` | `:latest-<arch>`, `:latest-<variant>-<arch>` | — |
| Windows | `:winamd64` | `:winamd64-<variant>` | — (one platform) | `:winarm64` |

- **The grammar is `<version>[-<variant>][-<arch>]`.** `latest` fills the
  version slot, so a pinned release is `:2026.09` / `:2026.09-nvidia` with no
  new rule. Tags are parsed by position, which is why the next bullet is a
  hard rule and not a style note.
- `<variant>` names what makes the image different — `nvidia`, `rocm`. It is
  NEVER an architecture (`:latest-amd64` must stay unambiguous, and `amd` is
  spelled `rocm` for exactly that reason): adding an architecture to a variant
  adds an ENTRY to the same manifest, and adding a variant adds a TAG.
- **A variant exists only for a stack that cannot ship in `:latest`** (owner
  directive 2026-09-22) — CUDA and ROCm are multi-GB, driver-bound and mutually
  exclusive. An accelerator whose runtime fits is built INTO the default image
  instead: Hailo-10H (amd64/arm64, `Dockerfile.torch`) and QNN (arm64, when the
  QAIRT zip is staged — `docs/qnn-linux.md`). There is no `:latest-hailo` or
  `:latest-qnn`; the standalone `:hailo` variant and `Dockerfile.hailo` were
  retired on 2026-09-22 as a duplicate of the standard build. A variant is
  built by a variant chain (§ Build Workflow), never by flipping `ENABLE_*` on
  the default one — that used to push GPU bytes under the default tags.
- The per-arch images (`:latest-<arch>`, the stage tags `:latest-base-<arch>` /
  `:latest-package-<arch>`) are the wrappers the manifest is assembled from.
  They are implementation detail; consumers resolve the manifest.
- **`:latest-cross` is RETIRED** (owner decision 2026-09-22): the old name of
  `:latest`. Nothing composes or pushes it any more, and `verify_ci_image_refs.py`
  rejects it under `.github/`. **The registry tags outlive the code,
  deliberately** (owner, 2026-09-22): work stays on `develop`. Since 2026-09-25
  the fleet calls this repo's composite actions and reusable workflows at
  `@develop` (owner directive; 110 refs across eight repos, none passing an
  explicit `image:`), whose `versions.env` names `:latest`. `main` still carries
  `CI_IMAGE_LINUX_TAG=latest-cross`, frozen at the last release that published
  it, so only a lane left at `@main` pulls `:latest-cross`. **Do not delete those
  tags yet.** The consumers leaving `@main` was the first condition; the second
  still holds: `:latest` and `:latest-cross` are ONE GHCR version, so the old name must
  become a version of its own first. `ghcr-delete-tags.sh` already refuses the
  unsafe form.
- A new variant = a new manifest tag. The manifest lane REFUSES to shrink a
  published index (§ Push and Publish Rules), so a partial run cannot silently
  drop an architecture from one.
- **Windows is the documented exception, and it is a platform fact, not a
  convention:** `windows/arm64` does not exist as a platform — Microsoft
  publishes no arm64 `servercore`/`nanoserver` base and Windows Server has no
  arm64 release
  ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)).
  The arm64 lane cross-compiles inside the `windows/amd64` container and emits an
  **artifact bundle**, so BOTH Windows outputs are `windows/amd64` images: two
  entries with the same platform cannot share a manifest, and the bundle must
  never be published as `windows/arm64`. The bundle therefore keeps its own tag
  (`:winarm64`, documented as a bundle) and never joins `:winamd64`.

### Windows-Specific Naming

The Windows lane names its local intermediate tags with `Get-BkTag`
(`windows/Build-Buildkit.ps1`), which yields
`docker.io/local/kataglyphis:bk-<name>[-<arch>]`: `bk-windows-base`,
`bk-windows-sdk`, `bk-windows-toolchain`, the media fan-out branches
`bk-windows-media-core` / `-media-litert` / `-media-tvm` (media-core is itself
split into `bk-windows-media-core-onnx` / `-ffmpeg` / `-opencv` / `-hailo`), the
merged `bk-windows-media`, and `bk-windows-torch` for the app stage. The arch
suffix is omitted for `windows-base`/`-sdk`/`-toolchain` (shared across both
lanes) and appended (`-arm64`) for everything downstream. `-Variant rocm` adds a `-rocm` infix to every tag after `bk-windows-base` (`bk-windows-sdk-rocm` … `bk-winamd64-rocm`), so a rocm run never overwrites a default image; nvidia still writes the default names. It publishes the final
image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (`:winarm64`
on the cross lane) — see § Image and tag naming for what those two tags are
allowed to be. The un-prefixed `local/kataglyphis:windows-*` names and
`Get-MediaBranchTag` belonged to the classic driver `build.ps1`, **deleted
2026-08-31** — neither the tags nor the helper exist any more. See
`docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

Commands, knob tables and the per-stage recipes live in
[`linux-cross-builds.md` § The command reference AGENTS.md used to carry](docs/linux-cross-builds.md#the-command-reference-agentsmd-used-to-carry).
Four things are RULES rather than reference, and stay here:

- **Never `pkill` the orchestrator.** `bash linux/scripts/stop-cross-chain.sh`
  finds the run by its pidfile and reaps the orphaned nerdctl/buildctl subtree;
  a `pkill` orphans the children and leaves the build solving.

- **Never edit a file in a running chain's closure**, and never restart
  buildkitd while a build solves. Both are § Caching discipline, rules 1 and 4.

- **Verify the shipped BYTES, never the push.** `:latest` (then `:latest-cross`) shipped STALE
  five times with every static gate and every smoke GREEN, because all of them
  checked the push rather than the content. `verify-shipped-wrapper.sh` gates
  this in `build-runtime-manifest.sh`, over every arch, BEFORE the boot smokes
  and before the manifest is assembled; `WRAPPER_CONTENT_GATE=0` downgrades it
  to advisory, which is a decision and not a default. The saga and its root
  cause: [`cross-build-verification.md`](docs/cross-build-verification.md#verify-the-shipped-bytes).

- **`--log-dir` is not universal.** `build-cross-chain.sh` and
  `build-cross-stage.sh` tee each stage; the other three orchestrators do not
  take the flag, so pipe them through `tee` yourself rather than assuming a log
  exists.

### Windows Container Build

All stages use Ninja + clang-cl + lld-link; the container toolchain is
containerd + BuildKit + nerdctl, and each tool is used where its pipe ACL allows
(build non-admin with `windows\Build-Buildkit.ps1`, inspect `bk-*` images from an
ADMIN shell). A fresh machine follows
[`windows-host-setup.md`](docs/windows-host-setup.md) rather than a
reconstructed sequence. The role split, the lane mechanics, the isolation policy
and the recovery paths:
[`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)
and [`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Running Linux containers (Rancher Desktop)

A GPU container on a Jetson needs three extra flags under rootless nerdctl:
[`linux-host-setup.md` § B2b](docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
Use `nerdctl`, never `docker`, and never assume a tool is present because it is
on your dev box (`jq` is NOT in the Linux image; `python3` is). The recipes, the
mount traps and the one driver that answers all of them
(`run-in-ci-image.sh`):
[`rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).

### LLM Stack (Ollama + Open WebUI)

A standalone serving stack lives in [`linux/llm-stack/`](linux/llm-stack/README.md)
— CPU-only by default, GPU by opt-in override. Two rules: **never put a key in
`backends.json`, only the NAME of the environment variable that holds it**, and
**the context Ollama lists is the model's maximum, not what fits** — size it
against real VRAM before claiming a context length. It is the family's reference
server, and the benchmark suite that points at it lives in OrchestrANT.

**The gateway in front of the GenieX lanes patches APISIX internals**
(`gateway/lua/geniex_hook.lua`), so an APISIX bump is not done until
`GATEWAY_E2E=1 pytest linux/llm-stack/tests/gateway_e2e` is green on it, and its
config only ever changes through `scripts/serve-stack.sh`, which validates before
it swaps: [the llm-stack README's Gateway section](linux/llm-stack/README.md#gateway).

### GenieX on Snapdragon (on-device OpenAI server)

The Kataglyphis coding agents can run **fully on-device on Snapdragon** (Adreno
GPU or Hexagon NPU) through an OpenAI-compatible server, with WSL2 clients
pointing at the Windows host. Setup, the model matrix, the measured numbers and
the debugging trail:
[`geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md).

### Which CI lanes run when

**Every platform lane in the family runs on every push and PR** (owner decision
2026-09-24): the `[build-win]` / `[build-arm]` commit-message opt-ins are
retired, and no platform job carries an `if:`. What is still path-filtered or
gated, and this repo's own triggers:
[`docs/ci-build-triggers.md`](docs/ci-build-triggers.md).

### Reading CI status with the GitHub CLI

**A skipped job is not a passed job.** `gh run view` prints both as a tick, and
reading a required lane's skip as success is how a red push looked green here.
Check the conclusion per job, not the run's summary glyph. The commands, and
which jobs are still gated:
[`github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md)
and [`ci-build-triggers.md`](docs/ci-build-triggers.md).

### Where does knowledge belong? (docs, not just code)

A fix that only exists in code is a fix the next reader re-derives. Write the
WHY where it belongs — [`docs/INDEX.md`](docs/INDEX.md) is the map of which page
owns which topic, and it opens with the rule — then link to it from the code.
For a CONSUMER repo, the shape of that split is
[`shared/templates/README.md`](shared/templates/README.md).

### Comments: as few as possible, as short as possible

**Owner rule (2026-08-28, restated 2026-09-01 as a project priority, number 6
today).** Code comments here had grown into essays. They are now held to this:

- Comment only where the code cannot say it: a non-obvious *why*, a trap, a
  load-bearing constraint.
- **Two lines is the ceiling.** If it needs a third, the content belongs in
  `docs/` and the comment becomes a one-line pointer — e.g.
  `# See docs/build-cache-tiers.md § 5.1`.
- No narration of what the code plainly does, no incident history, no
  restating a decision a doc already owns.

**Move it, never drop it.** This tree's comments often hold the ONLY record of a
real failure. When you shorten one, the detail must land in a `docs/` page in the
same edit — verify the page contains it before you delete the lines. Trimming a
comment down to nothing is data loss, not cleanup.

Worked example: an 8-line block in `01-core/runtime-build-fns.sh` became three
lines — what it does, the one knob pair, and a pointer — with the retry counts,
the classifier and the incident moved into
[`cross-build-verification.md`](docs/cross-build-verification.md).

**Why agents relapse here** (observed repeatedly, including 2026-09-01): the
surrounding code is full of older long comments, and "match the file's style"
pulls you back into writing essays. It does not apply to this rule. Match the
style for naming and structure; hold this line regardless of what the neighbours
look like. Do NOT go rewrite pre-existing long comments as a side quest either —
the rule governs what you write and what you touch, not a tree-wide sweep.

The same goes for prose written for the owner: short sentences, plain words.

### Contributing Reusable Work Here

Consumer projects are expected to push reusable work upstream rather than keep
local copies (BeschleunigerBallett's AGENTS.md states this as a rule).
Wiring a NEW project to this repo — submodule, module resolver, Windows and
Linux container builds, the agentic loop, launchers, CI actions — is a
checklist in [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md);
read it before hand-rolling any of that in a consumer.

When adding here:

- PowerShell 7 (pwsh) is the standard shell, and Windows containers use it as
  their default SHELL. Every `.ps1`/`.psm1` declares `#requires -Version 7.0` on
  line 1 (or directly under the SPDX header), always before any `param()`.
  Exactly two tracked files omit it, both deliberately and both pinned
  5.1-parsable by a suite: the script that INSTALLS pwsh, and the delete guard,
  which must not fail OPEN on a host where pwsh is missing.
- **PowerShell file names.** Three shapes: PascalCase `Verb-Noun.ps1` with a
  `Get-Verb`-approved verb for scripts, `Windows<Area>.<Facet>.psm1` for modules,
  `<Subject>.Tests.ps1` for suites. Three tracked files sit outside all three on
  purpose, the delete guard among them — it is registered by that exact string,
  so a rename silently unregisters it — plus `windows/scripts/build/rocm-checks/`,
  whose files are named after the component they check (`FFmpeg.ps1`,
  2026-09-23). A `verb-noun-name.ps1` spelling anywhere
  is stale, not a variant: 101 scripts were renamed on 2026-09-06.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`, and
  consumers resolve it ANTfrastructure-first with a vendored fallback. The resolver
  itself is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](shared/windows/templates/README.md).
- **Exporting a function is TWO edits when a build script calls it directly** —
  `Export-ModuleMember` in the owning module, and the re-export list if the
  script reaches it through one. Module-INTERNAL use needs neither, so an
  omission is invisible on a dev box and surfaces as `CommandNotFound` hours
  into a container build. Two suites hold the two directions (every CALLED name
  resolves; every LISTED name exists) and neither replaces the other.
- **The two-consumer test.** If a second consumer needs it, it belongs here,
  not vendored twice. When moving one up, turn its project-specific values into
  parameters whose DEFAULTS preserve the original behaviour, so the vendoring
  consumer can delete its copy without any behaviour change.
- Document the **symptom**, not just the fix — platform traps here are found by
  recognising an error message, not by reading code.
- Keep functions free of consumer-specific paths, preset names and build
  directories; pass those in as parameters.
- **Deleting is a consumer change.** A hub file may be removed only when the
  consumer inventory (`linux/scripts/verify_consumer_inventory.py`, over every
  repo in `.github/consumers.json`) reports it as *named by nobody*, and the
  deleting commit names the consumer commits that dropped the reference. A "zero
  callers" grep of THIS tree is not evidence: consumers pin a submodule commit
  and reach modules by NAME or by backslash path, so they neither break at
  delete time nor appear in the grep. Four sweeps have made that mistake; the
  last one deleted three live files and they were restored a week later.
- **Bash file names.** New files are kebab-case. The snake_case names that
  exist under `linux/scripts/` (`02-toolchain/python/ci_*.sh` and
  `build_python.sh`, `02-toolchain/rust/cargo_*.sh`, `_*_guard.sh` and `_cargo_wrapper.sh`,
  `version_util.sh`, `01-core/python_uv.sh`, `05-frameworks/flutter/flutter_checks.sh`,
  `06-packaging/package_archive.sh`) and `linux/webserver/scripts/flutter_integration_smoke_test.sh`
  are frozen: consumer wrappers resolve them by path, so a rename is a
  consumer-breaking change with no structural gain.
- **Workflow file names** (owner decision 2026-09-24, fleet-wide). Kebab-case,
  one file per platform and arch (`linux-x64.yml`, `windows-x64.yml`), display
  names `<Platform> <Arch> · <what>`. The hub's REUSABLE workflows
  (`python-ci-*`, `container-ci-windows`, `lint-gates`, `submodule-pins`, and
  `build-docs`, which only this repo calls) keep their file names for good:
  consumers call them at `@develop`, so a rename breaks the fleet in one push.
  The convention and the fleet's rename table:
  [`adopting-in-a-new-project.md` § Workflow file names and display names](docs/adopting-in-a-new-project.md#workflow-file-names-and-display-names).

### Reusable Module: WindowsContainerBuild.Reuse

The container-reuse API consumers build on:
[`docs/windows-builds.md`](docs/windows-builds.md) § Reusable module: WindowsContainerBuild.Reuse.

### Building Projects Inside the Windows Image (performance)

Everything write-heavy stays OFF the bind mount, and the CPU clamp is not
optional on this host. What to mount where, and the measured envelope:
[`windows-build-resources.md`](docs/windows-build-resources.md).

### Windows Build Invariants (do not regress)

49 load-bearing rules — pwsh discipline, the gates that must stay armed, probe
and log discipline, layer/scratch rules, lane and CNI rules, and the
build-input invariants — live in
[`docs/windows-build-invariants.md`](docs/windows-build-invariants.md),
grouped and individually linkable. **Read it before editing anything under
`windows/`.** Each entry carries the incident that produced it; a rule whose
evidence no longer matches the code is a bug in the rule.

The three most often regressed by someone who skipped that page:

- **pwsh 7 everywhere** — no `powershell.exe`, no `cmd` SHELL directives.
- **Every BK chain ends with a mandatory smoke gate** — `-SkipSmokeGate` is for
  chain iteration only, never for "it passed locally".
- **`versions.env` is the single source of truth** — never hardcode a version
  in a script or Dockerfile.

### TensorRT Setup (Optional)

EULA-gated, so nothing downloads it for you: stage the zip by hand and the
Windows lane picks it up. Where it goes and what the layout must look like:
[`windows-cross-builds.md`](docs/windows-cross-builds.md).

### QNN / Qualcomm AI Engine Direct Setup (Optional, #121)

Login-gated and EULA-bound, like TensorRT: staged by hand, never committed, and
only the README rides along on each lane. The Windows side is in
[`windows-cross-builds.md`](docs/windows-cross-builds.md); the Linux ARM64 side
is [`qnn-linux.md`](docs/qnn-linux.md).

### Windows Build Notes

The lane's own notes live with the lane:
[`windows-builds.md`](docs/windows-builds.md) and
[`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Orchestrator Stage Selection

Resume mid-chain, build one stage, or use `--parallel-archs`:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Orchestrator stage selection.

### Runtime Helpers

Wrapper builds, manifest publishing and manifest repair:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Runtime lane helper commands.

---

### GPU architecture coverage (how to turn an arch on or off)

**One source of truth: `CUDA_ARCHITECTURES` in `versions.env`.** Everything else
is a fallback default or an assertion that must move WITH it — that is the point,
so a trim cannot happen by accident. Changing the set is a deliberate owner
decision, never a speed lever on a dev iteration.

Today (owner decision 2026-09-23): **`86;87;89;120`**.

| CC | Architecture | Hardware |
| --- | --- | --- |
| 86 | Ampere GA10x | RTX 3060-3090, A10, A40 |
| 87 | Ampere GA10B | Jetson AGX Orin |
| 89 | Ada Lovelace | RTX 4060-4090, L40/L40S |
| 120 | Blackwell | GeForce RTX 5050-5090, RTX PRO Blackwell |

Not built, one token each: `75` Turing (T4, RTX 20xx) · `80` Ampere GA100
(A100, A30) · `90` Hopper (H100, H200) · `100` B100/B200 · `103` B300/GB300 ·
`110` Jetson Thor · `121` GB10/DGX Spark. 80 and 90 were **retired 2026-09-23**
and their line is kept commented in `versions.env`. CUDA 13 floors at **75**: Maxwell, Pascal and Volta were
removed from the toolkit, so nothing below it can ever be added back while
`CUDA_VERSION` is 13.x.

**To add or remove one**, edit these together (a gate fails otherwise, which is
the design):

1. `linux/scripts/01-core/versions.env` — the value.
2. `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` — the pinned assertion.
3. `linux/scripts/tests/test-version-forwarding.sh` — forwards the literal twice.
4. `docs/scripts/mutations.json` — the mutation's find/replace text.
5. The `${CUDA_ARCHITECTURES:-…}` fallbacks (ORT, OpenCV) and
   `windows/Dockerfile.media-builder`'s ARG default + the psm1 fallback:
   `sync_versions.py --check` grades the Dockerfile, the rest are plain copies.

**Four facts that decide WHICH number you need** — they are not interchangeable:

- **A cubin runs on its own major only, at an equal-or-higher minor.** 86 does
  not reach 87; 89 does not reach 120. Neighbours buy nothing.
- **ONNX Runtime narrows it further.** It rewrites every entry to
  `sm_<cc>a-real` (arch-specific, `-real` = cubin only). So in the ORT artefact
  `120` covers 12.0 and NOT 12.1 (GB10), and `100` would cover B100/B200 but not
  B300 (10.3). Spell out the exact hardware you own.
- **There is no PTX to fall back on.** ORT embeds none and OpenCV leaves
  `CUDA_ARCH_PTX` empty, so a missing arch is a hard failure at session
  creation (`no kernel image is available`), not a slow path. That is what
  retiring 80 costs an A100.
- **Do not write letter suffixes here** (`90a`, `100f`). ORT appends the `a`
  itself, and OpenCV's dotted-form conversion mangles a suffixed entry. Digits
  only, and the list stays ascending for readability — since 2026-09-23 nothing
  depends on the order any more (the trailing-`90`→`90a` rewrite is gone,
  because it silently did nothing as soon as the list stopped ending in 90).

**Cost:** each entry is a full cubin per CUDA source file. Four arches means
every ONNX Runtime and OpenCV CUDA kernel compiles four times — the single
biggest lever on GPU build time. `CUDA_ARCHITECTURES=120` alone cuts the CUDA
compile to roughly a fifth for a local iteration.

**ROCm has the same question, unanswered.** `amdrocm-core-dev` pulls all 25 gfx
targets (~19.6 GiB) because nothing selects. Per-gfx metapackages are the
largest single size win on that side:
[`linux-accelerator-images.md` § ROCm](docs/linux-accelerator-images.md).

## Build Workflow

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
CROSS_VARIANT=nvidia|rocm       → (shared sdk) → gpu → media → android → runtime → manifest
```

**A variant chain is the only way to build a GPU image** (2026-09-22).
`CROSS_VARIANT=nvidia` / `rocm` (or `ENABLE_NVIDIA=true` / `ENABLE_AMD=true`,
which imply it) is an ENVIRONMENT knob, because `stage-defs.sh` builds the stage
graph when it is sourced. It inserts the `gpu` stage, suffixes every tag from
there on with `-<variant>` (`tag-naming.sh` `cross_variant_infix`), starts at
`gpu` and refuses the shared stages, keeps its own `chain-status-<variant>.json`
and `out/build-logs/<variant>/`, and refuses what it cannot build
(`stage-defs.sh` `cross_variant_refusal`, shared with `build-cross-stage.sh`):
rocm off amd64; any target that is not the build platform's arch (CUDA/ROCm are
installed for the BUILD platform, so a cross target would ship its GPU
libraries); and a PUSHING run off `CROSS_BUILD_PLATFORM=linux/amd64` (the shared
`:cross-sdk-<arch>` is the amd64 lane's). The runtime helpers refuse a default
output tag under a variant. **Chains run strictly one at a time**: the pidfile
is claimed atomically at start, and a live one makes a second chain refuse.
Commands:
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md).

Stages 1-5 run on `linux/amd64`, or natively on an arm64 host with `CROSS_BUILD_PLATFORM=linux/arm64` (run end to end on a Jetson AGX Orin, [`linux-accelerator-images.md`](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson)). Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches), delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>` to prevent stale cache reuse. The stage graph is defined in `linux/scripts/01-core/stage-defs.sh`. See `docs/linux-cross-builds.md` for the full pipeline details.

The **Windows lane** follows a separate staged build (`base → [nvidia|rocm] → toolchain → media → [migraphx → llama] → torch → final`, the bracketed rocm stages on `-Variant rocm` only; torch assembles the OrchestrANT app env, `bk-windows-torch`, and final builds FROM it) driven by `windows/Build-Buildkit.ps1` (Stevedore's `buildctl` against buildkitd; the docker-classic driver `windows/build.ps1` was retired 2026-08-26 and deleted 2026-08-31 — see the one-driver bullet in [`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)). The `bk-windows-sdk` tag is either a plain re-tag of `bk-windows-base` (CPU lane, default) or the NVIDIA GPU stage `Dockerfile.nvidia` (`-Gpu` switch, same as `-Variant nvidia`) for a CUDA-enabled image. `-Variant rocm` (amd64 only) puts `Dockerfile.rocm` in that same sdk slot, under `-rocm` tags that never overwrite the default ones; every media feature it enables is gated on `(Get-GpuEnvironment).HasRocm` ([`windows-rocm.md`](docs/windows-rocm.md)). See `docs/windows-builds.md` § Build Commands for the full build sequence and prerequisites.

### Prerequisites

A Linux host needs the rootless container stack, the GPU driver stack for the
lane it builds, and enough disk for the chain spine. What to install, in what
order, and how to verify each piece came up:
[`linux-host-setup.md`](docs/linux-host-setup.md). QEMU/binfmt must be
re-registered after a host reboot or a containerd restart — an emulated leg
fails with `exec format error` when it is not.

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **CNI nat conf (historical note)**: before 2026-08-03 `nerdctl run` failed on this host (no CNI `nat` **conf**) and `nerdctl build` had broken DNS, so docker.exe was the only working tool. Since 2026-08-03 `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` is installed (see `docs/windows-build-lanes.md` § Getting it going, step 2 — including the subnet-drift trap) and nerdctl works — from **admin** shells only (containerd's pipe is admin-only). Stevedore's `docker.exe` remains the publish/inspect tool and needs no CNI plugin. Run with `--isolation process` for the host's full CPU count (Hyper-V isolation is capped at 2 CPUs). See `docs/windows-builds.md` § Running the Image.

### Stevedore Fixes After Install

Apply the post-install fixes documented in `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes (Defender exclusions, daemon.json cleanup, default runtime change, verification). Those instructions are the canonical source — keep them in sync instead of duplicating here.

### Supported Platforms

`linux/amd64`, `linux/arm64`, `linux/riscv64` on the Linux lane;
`windows/amd64` on the Windows one — `windows/arm64` is NOT a platform (the
arm64 output is a cross-built artifact bundle in a `windows/amd64` image; § Image
and tag naming). riscv64 carries two documented exemptions, and a platform that
is not on this list is not "probably fine": [`overview.md`](docs/overview.md).

### Expected Outputs

What a finished chain leaves behind, per stage and per arch, and which of it is
pushed rather than local: [`overview.md`](docs/overview.md) and
[`cross-build-verification.md`](docs/cross-build-verification.md).

## Repo Map

One line per top-level directory, each linking the thing that describes it in
detail. Counts are deliberately absent: every count written here has gone stale,
and `ls` answers faster than a stale number.

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
| `.github/workflows/` | This repo's own lanes plus the `workflow_call` ones consumers reuse (`python-ci-*`, `container-ci-windows`, `lint-gates`, `submodule-pins`); `build-docs` is `workflow_call` too, called only by this repo's `linux-x64.yml`. [Triggers](docs/ci-build-triggers.md) |
| `linux/scripts/` | The Linux build system: `01-core` (shared utilities), `02-toolchain` (GCC/LLVM/Rust/Python/CMake/Vulkan), `03-media` (per-library builds), `04-runtime` (entrypoint + env), `05-frameworks` (TVM, Torch, Flutter), `06-packaging` (assembly + smoke), plus the orchestrators and gates at its root. [Libraries](docs/shared-script-libraries.md) |
| `linux/llm-stack/` | The Ollama + Open WebUI serving stack. [README](linux/llm-stack/README.md) |
| `linux/jetson-webcam/` | A USB-camera object-detection PoC on a Jetson GPU, run in the arm64 GPU wrapper image. [README](linux/jetson-webcam/README.md) |
| `linux/webserver/` | The slim nginx image and the reusable Flutter-web helpers. [README](linux/webserver/README.md) |
| `linux/host-config/` | Host configuration as code: `buildkitd.toml`, the systemd drop-in, the apply/verify pair, the ghcr tools, and this repo's OWN git hooks (not the consumer ones). [Host setup](docs/linux-host-setup.md) |
| `linux/homeassistant/`, `linux/nextcloud-aio/` | The owner's personal operations stacks, deliberately carried here (README.md § Home-lab stacks). [HA](linux/homeassistant/README.md) · [Nextcloud](linux/nextcloud-aio/README.md) |
| `linux/vulkan/`, `linux/qnn-sdk/`, `linux/nvidia-local-debs/` | Staged SDK inputs. The QNN and NVIDIA trees are gitignored except their READMEs — login-gated, EULA-bound, never committed. |
| `windows/scripts/` | The Windows lane, grouped into `build/`, `host/`, `diagnostics/`, with `modules/*.psm1` as the reusable surface and `tests/` as its Pester suites. [Windows builds](docs/windows-builds.md) |
| `windows/upstream/` | Prepared upstream submissions, one directory per submission. NOT build inputs, and NOT to be posted without the owner saying so. [README](windows/upstream/README.md) |
| `windows/qnn-sdk/` | As `linux/qnn-sdk/`: gitignored but for its README. |
| `third_party/DocumANTation/` | The brand and style submodule every docs build reads. |
| `out/` | Generated artifacts (OCI layouts, rootfs exports). Gitignored and excluded from every build context. |

**Before deleting anything under `linux/scripts/lib/`, `02-toolchain/rust/`,
`02-toolchain/python/` or `06-packaging/`, grade it with the consumer
inventory.** Those four hold CONSUMER SURFACE that this repo's own lanes barely
or never call (in-repo, only `preflight.sh` and `flutter_checks.sh` source
`lib/code-quality.sh`; `06-packaging/` also holds the images' own packaging and
smoke scripts), and a 2026-08-08 sweep deleted `package_archive.sh` as
"zero-reference" while a consumer's release job was calling it. The rule and the mechanism are in
§ Contributing Reusable Work Here and
[`consumer-inventory.md`](docs/consumer-inventory.md).

## Shell safety conventions (five bug classes, all found live 2026-08-08)

Every one of these killed or falsified a real build before being fixed. The
full stories are in `CHANGELOG.md` (2026-08-08); `tests/test-ifs-safety.sh`
lint-gates class 3. When writing or reviewing bash in this repo:

1. **No `trap … RETURN` inside functions** — the trap survives the function and
   fires again on the CALLER's return, where the locals are gone (`set -u`
   abort AFTER a green run). Capture rc with `|| rc=$?`, clean up explicitly.
2. **Guard every pipeline whose empty result is legitimate** — `grep`/`find`/
   `ls`/`du`/`pgrep`/`dpkg -S`/`readelf` in `$(...)` under `set -euo pipefail`
   needs `|| true` when the code below handles the empty case. `find | head -1`
   additionally dies of SIGPIPE (rc 141) on multiple matches.
3. **Split comma lists with `IFS=',' read -r -a arr <<< "$list"`** — never
   `${list//,/ }` or `$(... tr ',' ' ')`: under a script's `IFS=$'\n\t'` those
   do not split and the loop runs once with the whole list as one bogus item.
   Sourced 01-core functions run under the CALLER's IFS. The two list helpers
   (`arch_list_to_words`, `smoke_arch_words`) emit NEWLINE-separated words
   since 2026-08-08 precisely so `for x in $(...)` splits under any IFS —
   keep that property if you touch them (test-smoke-arch-parity.sh pins it).
4. **Source vendor scripts (SDK setup-env, venv activate) with nounset
   suspended** — `case $- in *u*) …; set +u;; esac` … `set -u` after. LunarG's
   setup-env.sh reads `$1` unguarded.
5. **Never end a function with a bare `[ cond ] && action`** — the false case
   becomes the function's return value 1; under `set -e` the HEALTHY path kills
   the caller. End with `|| true`, `; return 0`, or an `if`.

**Host tool traps when you MEASURE a run.** These falsify your AUDIT, not the
build — each produced a wrong verdict on 2026-08-31, and none of them announces
itself:

- **`grep` on this host is ugrep.** A pattern beginning `--` is parsed as an
  OPTION and matches nothing, silently — a fault-injection arm that never
  fires looks exactly like a clean run. Always `grep -e "$pat"`. Symptom entry:
  [`docs/failure-modes.md`](docs/failure-modes.md#a-fault-injection-test-passes-and-proves-nothing-grep-is-ugrep).
- **`comm` needs `LC_ALL=C sort` on BOTH inputs.** Any other collation reports a
  set difference that is simply wrong while still looking like an answer — it
  turned "0 shared" into "36 shared" in one day's audits, and had been making a
  preflight assertion pass vacuously.
- **Never count warnings by grepping a BuildKit log.** BuildKit echoes each
  RUN's command text, so a warning string written INSIDE a Dockerfile command is
  counted as if it had fired. Match real output lines only.

## Caching discipline (do not regress)

Full map: [`linux-build-basics.md` § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where).
The tiers, the measurements and every failure class:
[`build-cache-tiers.md`](docs/build-cache-tiers.md). Toggles: `USE_CCACHE`,
`USE_SCCACHE`, `USE_LLD` accept `0/false/no/off`;
`ENABLE_SCCACHE_RUST`/`ENABLE_SCCACHE_CUDA` are strict `0/1`.

The rules an agent must never violate:

1. **Freeze the closure.** A touched file inside it re-keys the compiler image,
   and everything downstream of that image recompiles. `Dockerfile.base` mounts
   named files rather than directories, so most edits are free — but a file a
   base RUN newly NEEDS has to be added to those lists, and "needs" counts what
   it execs, not only what it sources. Batch such edits into one commit at a
   planned rebuild boundary. Lists, costs and the one layer that still mounts
   whole directories:
   [`build-cache-tiers.md` § 1](docs/build-cache-tiers.md#1-the-tiers).

2. **`~/.config/buildkit/buildkitd.toml` pins the GC budget** (`gckeepstorage`)
   so the multi-hour layers survive between runs. Do not delete it, and restart
   buildkitd only BETWEEN runs (`systemctl --user restart buildkit`), never
   while a build solves.

3. **One resolver decides which compiler cache runs** —
   `compiler_cache_launcher()` in `01-core/common.sh`, at RUNTIME, per call.
   Everything else here follows from that:
   - Do not spell a cache tool's name at a call site. A literal in the SHARED
     `cmake-cache-linker.sh` decides for every consumer at once.
   - Send a new call site through the resolver rather than copying the decision.
     Copies of it have shipped inert twice, so `verify-critical-fixes.sh` now
     refuses the shapes that did it.
   - Keep BOTH mounts on every heavy RUN. The fallback has to land somewhere.
   - Degrade, never disable: prefer `01-core/sccache-launcher.sh`, accept bare
     `sccache`, and treat "uncached" as a bug. `RUSTC_WRAPPER=""` is the one
     documented opt-out.
   - A build that runs its own compiles under `env -i` is out of the resolver's
     reach. HailoRT's nested protobuf build is the known case: `hailo-build-lib.sh`
     carries the cache into it, and a gate fails a build the cache did not reach.
   `--ccache` is a flag NAME, not a tool choice. Before a multi-hour run rides on
   a change here, `bash linux/scripts/02-toolchain/probe-sccache.sh` inside the
   compiler image answers in seconds whether a cache was actually consulted —
   which a successful compile does not.
   [`build-cache-tiers.md` § 5](docs/build-cache-tiers.md#5-scc1--the-ccachesccache-hybrid).

4. **Never edit a running orchestrator's main script.** bash reads it
   incrementally by byte offset, so an edit can corrupt the in-flight process.
   Sourced libraries are safe to edit for FUTURE runs — but see rule 1.

5. **Rules 1-4 are about the LINUX chain. Windows caches on other mechanisms**
   — where a layer sits relative to the Visual Studio install, how narrowly a
   module mount is scoped, and a GC floor that silently evicts the expensive
   layers when it is set too low. Any Dockerfile edit there has to preserve the
   first two (a Pester suite refuses a whole-directory module mount), and a
   cache miss that looks like a bad key is worth checking against that floor
   first. Tiers, figures and the two incidents:
   [`windows-build-resources.md` § The Windows cache, tier by tier](docs/windows-build-resources.md#the-windows-cache-tier-by-tier).

## Code Organization (key shared utilities)

**A new environment knob takes the prefix of whoever owns the DECISION**, not
of the file that happens to read it. The four prefixes and what each one means
are in [`adopting-in-a-new-project.md` § 8](docs/adopting-in-a-new-project.md);
the `env-knobs` gate grades this repo's own surface against them.

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. Single source of truth — never use ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from canonical name + aliases with fallback. Use instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`. Use instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`. Bootstrap pattern for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`. Single DRY entry that sources the 01-core module framework. Every media build script sources this instead of duplicating a preamble block. (The old `media_build_preamble_init` alias no longer exists — zero callers and zero definition remain.)
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, runtime tag functions. Never construct tags manually.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`. Informational only — it prints digests, it does not gate a build.
- **Stage ancestry (gating):** `ancestry.sh` → `ancestry_output_annotations()`, `ancestry_recorded_parent()`, `ancestry_assert_chain()`. Every pushed cross stage records the parent ref it was built FROM as the OCI manifest annotation `org.kataglyphis.parent-digest`; a run with `--from-stage` after `base` walks that chain and HARD-FAILS when a parent was re-pushed after the child that would be inherited. Read path: `manifest-annotation.py` (annotations live in the base64 `Raw` field of `manifest inspect --verbose`). Absent annotation = warn (predates the mechanism); present + mismatch = fail. Escape hatch: `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`.
- **Cross-stage build:** `cross-stage-build.sh` → `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `cross_stage_assemble_runtime_helper_args()`.
- **Runtime flow init:** `runtime-flow-common.sh` → `init_runtime_flow_defaults()` (loaded by `lib-orchestrator.sh` in `runtime_flow_preamble()`, not sourced directly).
- **Retry logic:** `logging.sh` → `retry <max> <sleep> <desc> <cmd...>`.
- **Mirror args:** `build-helpers.sh` → `append_mirror_build_args_from_env()`.
- **Version forwarding:** `version-forwarding.sh` → `append_version_build_args()` (auto-discovers from `versions.env`).
- **CMake cache/linker:** `cmake-cache-linker.sh` → `append_cmake_cache_linker_args <array_ref>`. Sourced by `03-media/core/common.sh` automatically.
- **Install deps preamble:** `cross-apt.sh` → `install_deps_preamble [packages...]`.
- **Media ENV reference:** `03-media/runtime/media-env.sh` is the canonical definition of PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH/GI_TYPELIB_PATH. `Dockerfile.media` and `Dockerfile.package` ENV blocks must stay in sync with this file.
- **Media artifact verification:** `03-media/runtime/verify-media-artifacts.sh` validates each media build stage produced output. Called from `Dockerfile.media` RUN steps after every library build. Stages: `onnxruntime-cpu`, `onnxruntime-genai`, `onnxruntime-gpu`, `onnxruntime-pkgconfig`, `litert`, `litert-headers`, `opencv`, `opencv-core`, `ffmpeg`, `gstreamer`, `libcamera`, `armnn`, `app-wheels`, `media-inputs`, `sizes`.
- **Runtime stage elements:** `Dockerfile.torch` final stage is canonical for COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, OCI labels.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper (`BUILDKIT_HOST` support). Use instead of ad hoc `nerdctl build`.

### Module Loading Order

**Which loader a NEW script uses is a rule, not a preference.** If it can run
inside a container, it loads through `source_module`, which resolves both
layouts; if it is host-only orchestration, it sources `artifact-common.sh`.
Mixing them breaks at `/opt/scripts`, and a suite freezes the load order.
The dependency order and the one known wart:
[`shared-script-libraries.md`](docs/shared-script-libraries.md).

## Cross Chain Stage Handoff (do not regress)

- **A stage's parent is pinned by DIGEST, never by tag.** A tag can move between
  the moment a child resolves it and the moment it builds; that is how a chain
  built on a stale parent and shipped it green.
- **Every image carries its ancestry annotation** (`org.kataglyphis.parent-digest`),
  which is what makes `--verify-chain` able to answer FRESH/STALE at all rather
  than guessing from timestamps.
- **A partial run asserts its ancestors before building** and REFUSES a stale
  one. `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0` is a deliberate
  override, not a workaround to reach for.

How the handoff is constructed, why the digest pin is load-bearing and the
stale-base propagation trap:
[`linux-cross-builds.md` § Why the handoff must be pinned by digest](docs/linux-cross-builds.md#why-the-handoff-must-be-pinned-by-digest).

## Five Critical Fixes To Maintain

Always preserve these. The canonical reference is `docs/linux-cross-builds.md` § "Five Critical Fixes"; CI validates them via `linux/scripts/verify-critical-fixes.sh`.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl`/`ctr` commonly fail with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working.
- `build-cross-compiler.sh` builds one `linux/amd64` compiler image with cross toolchains for all arches. Not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images must keep the source-built clang at `LLVM_RELEASE` (currently 23.1.1), not the Ubuntu distro clang. Source-built GCC (`GCC_VERSION`, currently 16.2.0) at `/opt/gcc-${GCC_VERSION}` is the default `cc`/`c++` on all arches. On `arm64`/`riscv64`, GCC is cross-compiled (Canadian cross) and swapped in at the Android stage via `Dockerfile.android`.
- **The Canadian native GCC builds libsanitizer (host == target); do not trim
  `build-gcc.sh`'s target list back to libgcc/libstdc++/libatomic.** The swap and
  the wrapper smoke fail an image without it:
  [`cross-build-verification.md`](docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer).
- **Supply-chain discipline.** Every network fetch is verified:
  `download_verified_file` is the default and `download_file` needs a reason,
  with the sha256 in `versions.env`. Python BUILD EXECUTORS — anything that runs
  code at build time or rewrites shipped binaries — are pinned through the
  `PY_*_VERSION` family and bumped together, deliberately, with a real build;
  never let an install site float back to `-U pkg`. Never `curl | sh`: clone at
  a tag with `--depth 1 --branch` and hard-fail on a missing tag rather than
  falling back to a branch.
- Preserve optional runtime payloads and LLVM normalization in `Dockerfile.package`. Do not drop `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.
- **A miss reported by `install_target_packages` is not automatically an
  outage.** It prints the same line whether or not the caller guarded it, so
  read the CALL SITE before escalating: guarded is information, unguarded means
  the stage is genuinely short a library.
- **Our source-built prefixes must WIN the include path.** A later stage that
  installs a distro `-dev` package puts its headers on the same search path, and
  a distro FFmpeg once displaced ours and killed a videoio build with an
  undeclared symbol. Put `-I${PREFIX}/include` ahead of the multiarch
  `-idirafter`/`-isystem` entries rather than trusting the generator's ordering.
  The same class bites package NAMES across an Ubuntu release, and it failed on
  one arch while passing on another in the same run — a green arch is not
  evidence for the others.
- **The arm64 GPU lane is SBSA CUDA: one image for Arm servers and Jetson.**
  Build with the image's GCC 16 (`NVCC_PREPEND_FLAGS=-allow-unsupported-compiler`),
  never a downgraded `CUDAHOSTCXX`, and keep `87` (Orin) in `CUDA_ARCHITECTURES`
  (ascending for readability only; nothing depends on the order since 2026-09-23).
  The chain's `gpu` stage cannot push from an arm64 build
  platform (the shared sdk is the amd64 lane's), so on the Jetson the lane stays
  `--no-push`, with the layer handed on by hand:
  [`linux-accelerator-images.md` § NVIDIA on arm64 (SBSA)](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson).
- **Never give one nerdctl build two `oci-layout://` contexts.** nerdctl maps
  them onto one store id and one becomes unresolvable:
  [`failure-modes.md`](docs/failure-modes.md#a-no-push-wrapper-build-cannot-find-its-own-android-image).
- **riscv64 self-builds `onnxruntime-genai`** (GEN1) — do not re-add an arch
  guard. `GENAI_ALLOW_RISCV64=false` backs it out. What is proven, and the one
  caveat that is not (real silicon):
  [`gen1-riscv64-genai.md`](docs/gen1-riscv64-genai.md).
- **Feature parity has exactly TWO documented exemptions**, both riscv64:
  `cmake` (Kitware publishes no riscv64 archive) and `iree_base_compiler` (the
  IREE compiler cannot be cross-built). `_parity_exempt` in
  `06-packaging/smoke-runtime-image.sh` is the source of truth — a new
  exception is recorded THERE, never in prose, and the gate fails an exemption
  that no longer applies. The ORT flavour split and arm64-only QNN are
  deliberate, not gaps.
- **riscv64 builds WITH the vector extension**, set through `--with-arch` in
  `02-toolchain/build-gcc.sh`, never as a `CFLAGS` export — `-march` alone
  reaches neither OpenCV nor ORT nor Rust, each of which has its own switch. Do
  not "restore compatibility" by reverting it: an rv64gc-only board cannot run
  this image regardless, and changing it invalidates the warm riscv64 compiler
  cache. The ISA string and why the profile NAME does not work:
  [`riscv64-rva23-baseline.md`](docs/riscv64-rva23-baseline.md).
- **riscv64's web-lane tools have two build paths; keep both** (owner decision
  2026-09-23). By default android cross-builds `wasm-pack` and
  `flutter_rust_bridge_codegen` and the package stage installs them after a
  fail-loud gate; `WEB_LANE_TOOLS_SOURCE=native` (plus `WEB_LANE_TOOLS_CACHE=refresh`
  for a fresh compile) is the gated in-stage native build, and `legacy` is the
  pre-2026-09-23 build verbatim. Never remove either, never let `legacy` drift
  from the old command, and never soften the gate on a binary that claims to be good:
  [`consumer-image-contract.md`](docs/consumer-image-contract.md#building-the-web-lane-tools-from-source).
- **The wrapper's `/opt/wheels` has two deliveries; keep both** (owner decision
  2026-09-24). `RUNTIME_WHEELS_SOURCE=image` (what `auto`, the default, means today)
  mounts the android image as every published image did; `export` stages that same
  image's wheelhouse, sealed, before each package build. Never add a fallback between
  them, and keep their logic in `linux/scripts/lib-runtime-wheels.sh`, outside every
  image closure, so a change there re-keys nothing. `export` refuses a `--no-push`
  chain whose android tag is published (every one on the amd64 cross host). Never
  "fix" that by re-exporting the layout; changing the ref it reads is the owner's call:
  [`linux-cross-builds.md`](docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).
- **The Hailo build has two switches; keep both** (2026-09-24).
  `HAILO_NESTED_CACHE=carry` (default) carries the compiler cache into the protobuf
  build HailoRT runs under `env -i`, and fails a `carry` build the cache did not reach;
  `off` is the old uncached build. `HAILO_PYHAILORT_IPO=off` (default) patches out
  upstream's forced LTO, so pyhailort is a real module, checked on the wheel and on
  `/opt/venv`, where a failed install or a missing wheel is fatal too; `upstream` is the
  old empty module, and warns. Never soften either check under its default, and keep
  the code in `03-media/build/hailo/`, outside `01-core`, so a change there re-keys only
  the wrapper's Hailo RUN:
  [`hailo-support.md`](docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches).
- **ONNX Runtime has exactly one source on both lanes: the chain build** (owner
  rule 2026-09-23, no exceptions). On Linux that is `/usr/local/lib/onnxruntime-cpu`
  on every variant, plus `/usr/local/lib/onnxruntime-gpu` on the GPU variants, and
  its wheel:
  - OpenCV, FFmpeg, gst-plugins-bad's `onnx` plugin and GenAI fail their build
    unless they resolve the chain, and each ends in `ort_assert_chain_only`
    (`03-media/ort-provenance.sh`, mounted per file, never under `core/` or
    `runtime/`).
  - `/opt/opencv5/lib/libonnxruntime*` are links into the chain, never copies. The
    chain's conf is `000-onnxruntime.conf`. No apt package may provide ORT, and the
    soname deny is in code: never map a `libonnxruntime*` soname to a distro package.
  - The app venv's ORT is the chain wheel byte for byte (`ort-venv-census.py`); a
    missing chain wheel fails the torch stage, with no PyPI fallback.
  - The census's ORT fingerprint is a whole NUL-terminated `__FILE__` source path,
    never the bare `onnxruntime/core/` directory: consumers name that directory as
    data (OxidANT's loader, FFmpeg's configure line), and must stay importers. A file
    that DEFINES `OrtGetApiBase` (ELF dynamic symbol, PE export) is ORT under any name.
  - The image census (SHIPPED-TRUTH E) and `verify-critical-fixes.sh` fix11 enforce
    it. Every consumer, guard and gap:
    [`onnxruntime-single-source.md`](docs/onnxruntime-single-source.md); the Windows
    rule: [`windows-build-invariants.md`](docs/windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23).

## Dockerfile.media BuildKit Strategy

The media stage fans out into parallel branches and merges them, so a change
that serialises the fan-out or widens a branch's mount costs hours per run.
Read the strategy before editing that Dockerfile:
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md) and
[`build-parallelism-memory-tuning.md`](docs/build-parallelism-memory-tuning.md).

## Push And Publish Rules

- `build-runtime-artifacts.sh --push` pushes only final per-arch wrapper images.
- `build-runtime-manifest.sh --push` pushes wrappers + final manifest.
- `--push-all` only when explicitly requested (publishes `base`/`package` intermediates).
- Final cross release: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`
  (the old `:latest-cross` name is retired; its registry tags stay until the
  conditions in § Image and tag naming are met).
- Before rebuilding expensive foreign-arch wrappers, inspect remote tags with `nerdctl manifest inspect`. If wrappers exist remotely, recreate the manifest directly instead of rebuilding.
- **The manifest lane REFUSES to shrink an already-published index.**
  `_manifest_completeness_gate` in `build-runtime-manifest.sh` compares the
  arch count of the live tag against the arches this run carries and stops.
  The older coherence gate only asks whether the arches AGREE on a generation,
  so a single-arch run assembled a perfectly coherent ONE-arch index and
  published it — which is how `:latest` (then `:latest-cross`) was found reduced to riscv64
  alone. Recover by re-running the runtime lane for the missing arches;
  `--force` / `RUNTIME_MANIFEST_COMPLETENESS=0` are for a deliberate shrink
  only. A partial-arch run should carry `--skip-manifest` and never reach here.
- **A published image's environment names nothing outside the container**
  (2026-09-23, both lanes). A build-host setting — the sccache endpoint, a LAN
  mirror, a proxy — reaches a RUN as an ARG and never lands in an ENV: `:winamd64`
  shipped the owner's LAN WebDAV and broke every consumer's sccache. Three gates hold
  it and none has a skip switch: the static pass in `lint-dockerfiles.sh`; Windows'
  `Dockerfile.publish-gate`, solved on every parent a run inherits but did not build,
  on the fresh toolchain, and on the final image before any export or push
  (`-SkipSmokeGate` skips none of them); and `build-runtime-manifest.sh`'s image-env
  gate, first in `create_manifest` on every path, `--manifest-only` included. **Cross
  such a fix by restarting a chain, never by resuming one**: a driver started before
  it has no gate, and a parent built before it still carries the leak. Why, and what
  the gates cannot see:
  [`windows-build-resources.md` § What the published image carries](docs/windows-build-resources.md#what-the-published-image-carries).

## Validation

- **Four places run the gates, and they are deliberately not the same set.**

  | when | what runs | cost |
  | --- | --- | --- |
  | every `git commit` | `linux/host-config/git-hooks/pre-commit` — the 18 cheap whole-tree slugs, `shellcheck` + the warning ratchet on STAGED shell, the doc gates only when `docs/` is staged, the derived doc numbers when a page that quotes them is staged, and the mutation gate on at most `PRECOMMIT_MUTATION_CAP` (default 16) staged entries, newest first | **8.0 s** one-file, **27.2 s** for a 43-file commit (measured 2026-09-04) |
  | every `git push` | `linux/host-config/git-hooks/pre-push` — the mutation gate's `--stale-check` over the whole manifest, then `--changed` for real ([`code-quality-tooling.md` § The pre-push hook](docs/code-quality-tooling.md#the-pre-push-hook)) | the staleness pass: 0.06 s over 378 entries (measured 2026-09-05); `--changed` depends on the push |
  | before a rebuild, by hand | `make preflight` — all slugs | minutes (the secret scan alone is ~170 s) |
  | every push | `.github/workflows/linux-x64.yml` — `preflight.sh` with `PREFLIGHT_SKIP=mutations`, plus the `mutations` slug as four `PREFLIGHT_MUTATION_SHARD=K/4` jobs that together prove every entry | CI |

  Install the hooks once with **`make hooks`**: it sets `core.hooksPath` rather
  than copying into `.git/hooks`, so both hooks are version-controlled and arrive
  with a clone. `git commit --no-verify` bypasses the commit hook — then run
  `make preflight` before pushing.

  The hook is deliberately a SUBSET and its mutation step is deliberately a
  SAMPLE, because a pre-commit gate that takes minutes teaches everyone to type
  `--no-verify`. A sample never reports as full coverage: it prints how many of
  how many it ran. Why it is capped, and what it measured before it was:
  [`code-quality-tooling.md` § The pre-commit hook's cost budget](docs/code-quality-tooling.md#the-pre-commit-hooks-cost-budget).

  CI never samples: its four `mutations` jobs split the manifest with `--shard`
  and together prove every entry. When the gate gets slow, fix the suite that got
  slow; do not raise a timeout or sample in CI. The 2026-09-23 timeout and the
  layout: [`code-quality-tooling.md` § The mutation gate in CI, sharded](docs/code-quality-tooling.md#the-mutation-gate-in-ci-sharded).

- **Never retype a number a gate can measure.** Manifest sizes, per-prefix
  mutation counts and the hook's own slug list are pinned by
  `tests/test-doc-numbers.sh`, which reads them out of `mutations.json` and the
  hook and fails on drift (`--update` rewrites the pages). Wall-clock figures
  cannot be pinned — write them with the date they were measured, or leave the
  digit out.

- **`bash linux/scripts/preflight.sh` is the single source of the no-build gate
  list.** The inventory is its `KNOWN_SLUGS` array — do NOT enumerate it here;
  this very paragraph went stale by three slugs once. `tests/test-preflight-slugs.sh`
  enforces that every slug has a registered check and vice versa. The commit hook
  runs a subset through `PREFLIGHT_ONLY` / `PREFLIGHT_SKIP`; never copy the check
  list into a new caller. On a Windows host:
  `PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh`.
  What each gate proves, and its allowlist:
  [`code-quality-gates.md`](docs/code-quality-gates.md) (generated) and
  [`code-quality-tooling.md`](docs/code-quality-tooling.md).

- **Linux host config is code.** `linux/host-config/` carries the canonical
  rootless-BuildKit `buildkitd.toml` and the systemd drop-in;
  `apply-host-config.sh` installs and `verify-host-config.sh` warn-diffs live vs
  repo. Reconcile drift through the repo, never by editing `~/.config` alone — a
  live-only toml edit silently regressed once.

- **Linux disk reclaim: `linux/host-config/prune-safe.sh`, NEVER
  `nerdctl builder prune -f`**, and `nerdctl system prune` / `nerdctl builder
  prune` are not steps on the list at all. The `-f` prune deletes
  `type==exec.cachemount` records — hours of compile time — together with the
  cheap-to-regenerate layer cache. The measurements, the mid-run lever ORDER and
  the third cache store `prune-safe.sh` cannot reach:
  [`linux-host-setup.md` § B7](docs/linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches).

- **Host toolchain: install from the nerdctl-full bundle, and on a rootless-only
  host into `$HOME/.local`.** There is no separate buildkit package here, so
  bumping buildkitd means installing a newer bundle;
  `linux/host-config/install-nerdctl-full.sh` dry-runs by default, verifies the
  release SHA256, backs up what it replaces (`--rollback`), refuses while a build
  is running, and counts BuildKit cache-mount records before and after.
  [`linux-host-setup.md` § B3b](docs/linux-host-setup.md#b3b-install-or-upgrade-nerdctl-full)
  and [§ B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).

- **riscv64 host tooling** needs more than the amd64 one-liner (no riscv64
  wheels, so uv builds from source; the native RVA23 triple; an apt step that
  needs interactive sudo):
  [`linux-host-setup.md` § D4](docs/linux-host-setup.md#d4-python-cli-tools-that-build-from-source-on-riscv64).

- **ghcr REGISTRY hygiene: two tools over `ghcr-common.sh`, and NEVER "delete
  all untagged" by hand.** `ghcr-prune-package.sh` deletes UNTAGGED versions;
  `ghcr-delete-tags.sh` deletes NAMED tags from an explicit list and never
  guesses what is legacy. The per-arch entries of a multi-arch index are
  themselves untagged manifests, and a chain that is pushing creates untagged
  manifests seconds before tagging them. Both dry-run by default. The keep-set
  rule, the one Accept header that makes it a safety property, and the run
  numbers: [`linux-host-setup.md` § B8](docs/linux-host-setup.md#b8-ghcr-registry-hygiene).

- **HOST DISK RECLAIM IS ALLOW-LISTED AND DEFAULT-DRY —
  `windows/scripts/host/Clear-DiskSpace.ps1`, and NOTHING ad hoc** (2026-08-21,
  the worst incident this repo has produced: a "let's free some space" command
  composed on the spot walked into the installed programs and the user profile
  and took the host with it). The rules, all of them permanent:
  - **The reclaim script is the only sanctioned path.** It resolves candidates
    from an ALLOWLIST, reports by default, needs `-Apply`, age-gates every
    live-directory rule, and aborts the WHOLE run if any candidate lands on a
    protected root — a candidate that lands there means the resolution logic is
    wrong and the rest of the plan is untrustworthy too.
  - **A name is not a target.** A candidate containing a junction or symlink is
    skipped: a reparse point is exactly where a name stops predicting what a
    recursive delete reaches.
  - **The compile caches are NOT cleanup targets.** sccache/ccache/cargo/uv read
    as "cache" and are the most expensive bytes on the disk.
  - **Daemon levers before filesystem levers, always.** `buildctl prune
    --free-storage`, `docker image prune`, the store-GC sequence in
    [`windows-build-lanes.md` § Store GC](docs/windows-build-lanes.md).
    Filesystem reclaim is a last resort limited to dead `*.bak-<stamp>` husks.
  - **Protected roots are OFF LIMITS to the agent, permanently**: `C:\Program
    Files`, `C:\Program Files (x86)`, `C:\Windows`, `C:\ProgramData` outside the
    container stores, any user profile under `C:\Users`, `AppData`, per-user tool
    directories (`.vscode`, `.ssh`, `scoop`, `.claude`), drive roots, and every
    installed-package or driver store. Not with a flag, not with a force switch,
    not "just this once". Space that only comes back by reaching in there is a
    reinstall, not a cleanup — and it is the user's call, run by the user.
  - **Uninstalling the user's software is never the agent's move.** No package
    manager, MSI or appx removals. Suggest, never do.
  - **The gate is mechanical, not advisory.**
    `.claude/hooks/guard-destructive-deletes.ps1` runs as a `PreToolUse` hook,
    in a Python and a PowerShell implementation so it fires on a host with no
    `pwsh`. It DENIES — a decision no prompt can override — any command touching
    a protected root, and it scans file CONTENT on Write/Edit too, because the
    2026-08-21 vector was a script written for the user to paste, not a command
    the agent ran. `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1` is
    the incident in executable form. Relaxing a guard regex is a reviewed repo
    change with a test, never a bypass in the moment.

- **PowerShell gate:** `pwsh -File windows/scripts/Invoke-Lint.ps1` +
  `pwsh -File windows/scripts/tests/Invoke-Tests.ps1` (CI:
  `.github/workflows/windows-x64.yml`). The suite guards *classes* of defect,
  not instances — when you fix a bug here, prefer a guard for its class. Which
  classes, and why the linter exits 2 for an infrastructure failure:
  [`windows-builds.md`](docs/windows-builds.md).

- **Runtime verification happens inside a container, or against raw symlink
  targets.** Do not use `readlink -f` against `out/linux-runtime/*/rootfs`:
  absolute symlinks resolve against the host root. Confirm on all arches that
  `clang --version` reports `LLVM_RELEASE`, `cc -dumpmachine` matches the arch,
  `gcc --version` reports the pinned GCC, and the `cc/c++/gcc/g++` and `clang`
  symlinks point into `/opt/gcc-*/bin` and `/usr/local/llvm-target/bin`.

- **The `wrapper-smoke` target in `Dockerfile.package` is a MANDATORY gate** in
  `runtime_build_chain()` — it builds between the package and wrapper stages,
  reusing cached package layers. `WRAPPER_SMOKE_GATE=0` skips it;
  `test-runtime-smoke-gate.sh` pins that it runs.

## Dependency Updates

Three rules; everything else is mechanism, and the mechanism is documented once
in [`dependency-updates.md`](docs/dependency-updates.md).

- **Upgrades are driven by Renovate run as a LOCAL CLI, in every repo of the
  family** (owner directive 2026-09-09), not by hand and not by waiting for a
  bot. The GitHub App is installed nowhere here and will not be, so this is the
  permanent mechanism rather than a stopgap.
- **A run REPORTS. `--apply` only when the owner asked for it in that turn**
  (owner directive 2026-09-11).
  `linux/scripts/renovate-local.sh .` reports;
  `--apply --dry-run` prints the plan; `--apply` writes gitlinks, manifests and
  locks, for every ecosystem the repo has.
- **A bare `git submodule update --remote` is forbidden in this family.** For a
  submodule that declares no `branch =` it does not skip — it walks the pin to
  the remote's DEFAULT branch. `--apply` passes explicit paths, takes only
  submodules that declare a branch, and never uses `--recursive`.

What `--platform=local` cannot do, why `--enabled-managers` is not enough, which
git must run the apply half, and what a stale lockfile does:
[`dependency-updates.md`](docs/dependency-updates.md).

## Common Failure Modes

Every failure this repository has diagnosed twice is written up once, with the
symptom that identifies it and the fix that actually worked:
[`failure-modes.md`](docs/failure-modes.md). Read it before theorising — the
expensive ones here all looked like something else first (a cache miss that was
a GC floor, a stale image that was a push-not-content check, an `fchmod` error
that was a host mount).

## Version Bumping

- **`linux/scripts/01-core/versions.env` is the single source of every version
  in this repository.** A literal anywhere else is a second source that will
  disagree; the ARG-consistency and advertised-key gates exist because it did.
- **Never hand-edit a derived file.** `python docs/scripts/sync_versions.py
  --write` propagates a pin into the docs, the deps table, the Dockerfile ARGs
  and the PowerShell defaults; `--check` is a preflight gate, so a hand edit is
  caught rather than shipped.
- **A version with a checksum moves with its checksum.** `bump_versions.py`
  owns those pairs, because a pin updated without its digest is an unverified
  download that still looks pinned.

The key layout, the coupled pairs and the report tiers:
[`dependency-updates.md`](docs/dependency-updates.md) and
[`cross-build-verification.md`](docs/cross-build-verification.md#per-arch-version-truth).

## Development Rules

- Every script starts with `#!/usr/bin/env bash`. `set -euo pipefail` is for **entry
  points** only — a sourced file must not change its caller's shell options. The
  libraries under `linux/scripts/lib/` set no shell options at all
  ([`docs/shared-script-libraries.md`](docs/shared-script-libraries.md)), and neither
  do the `01-core/` framework modules loaded through `source_module` (`logging.sh`,
  `common.sh`, `build-helpers.sh`, `platform.sh`, `verify.sh`, `downloads.sh`, …).
  Two deliberate exceptions, both documented at their own file scope:
  `01-core/python_uv.sh` (a consumer inherits strict mode from it) and the test
  suites, which run `set -u` without `-e` because the harness accumulates failed
  assertions and decides the exit code itself. Use `run()` from
  `build-helpers.sh`.
- Source `artifact-common.sh` for shared utilities. Use `parse_shared_orchestrator_args()`/`parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` before the build loop.
- Use centralized helpers: `resolve_arch_list()`, `is_dry_run()`, `append_mirror_build_args_from_env()`, `append_version_build_args()`, `normalize_target_arches()`.
- New OS packages → `Dockerfile.base`. Compiler changes → `Dockerfile.toolchain`. SDK/frameworks → `Dockerfile.sdk`. Media libs → `Dockerfile.media` + `03-media/build/`. Android → `Dockerfile.android`. GPU → `Dockerfile.nvidia`/`Dockerfile.amd`.
- New architecture: add to `CROSS_DEFAULT_ARCHES` in `versions.env`, update cross-target lists, add triple mapping in `platform.sh`, add checksums in `versions.env`, verify QEMU/binfmt.

## `.dockerignore` Guardrail

**Never exclude the `linux/` directory from `.dockerignore`.** Every Linux
Dockerfile `COPY`s from under it, so a blanket exclusion breaks each one with
`failed to compute cache key: ... not found`. Exclude specific large
subdirectories if a context needs shrinking — never the directory itself.

`linux/.dockerignore` is a SEPARATE allowlist for builds whose context is
`linux/` (the compose-built webserver image): every `COPY` source in
`webserver/Dockerfile` that comes from THAT context needs a negation there. The
built site is no longer one of them — it arrives through a named build context
(`--build-context site=...`), which this file does not filter at all.

## Reusable Sphinx Theme Package

The shared theme and its `conf.py` snippet:
[`docs/project-info.md`](docs/project-info.md) § Reusable Sphinx theme package.

## Documentation Maintenance

- **[`docs/INDEX.md`](docs/INDEX.md) decides which page owns which topic.** Add
  a row when you add a page; the `doc-links` gate fails a page that no row and
  no toctree entry names.
- **The docs gates run over this tree, not over a guess.** `doc-links` checks
  every cross-reference and every `docs/*.md` pointer in code; `doc-dupes`
  catches a passage reworded into a second page. Budgets live in
  `docs/scripts/*.allow` with a reason, and a stale row fails.
- **The theme and the brand belong to DocumANTation.** Change `custom.css`
  there, not here.

How each gate decides, and what its allowlist means:
[`code-quality-tooling.md`](docs/code-quality-tooling.md).
