# ANTfrastructure — agent guardrails

**This file is the rulebook, not the manual**: what an agent must and must not do to keep the
build from regressing, plus the canonical build commands. A RULE an agent must not break belongs
here; the MECHANISM behind it, and reference data (what is in an image, per-component build
matrices, script tables), belong to the `docs/` page that owns the topic.
[`docs/INDEX.md`](docs/INDEX.md) maps topic → page.

| Before you… | Read |
|---|---|
| Edit anything under `windows/` | [`docs/windows-build-invariants.md`](docs/windows-build-invariants.md) — the load-bearing rules |
| Debug an error message | [`docs/failure-modes.md`](docs/failure-modes.md) — symptom → cause → fix |
| Launch or debug a Windows chain | [`docs/windows-build-lanes.md`](docs/windows-build-lanes.md) — BuildKit, nerdctl, classic (historical) |
| Wire a new project to this repo | [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md) |
| **Add or bump a dependency** | [`docs/third-party-licenses.md`](docs/third-party-licenses.md) § Maintaining this list — an `spdx` id is mandatory, copyleft needs a source pointer, and the build gates both |

## Contents

**Rules — never regress these.** [Project priorities](#project-priorities-owner-directive--optimize-for-all-three-always) ·
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

**Doing the work.** [Quick reference](#quick-reference) ·
[Build workflow](#build-workflow) · [Validation](#validation) ·
[Version bumping](#version-bumping) · [Dependency updates](#dependency-updates) ·
[Failure modes](#common-failure-modes)

**Orientation.** [Container architecture](#container-architecture) ·
[Repo map](#repo-map) · [Code organization](#code-organization-key-shared-utilities) ·
[Documentation maintenance](#documentation-maintenance)

## Project priorities (owner directive — optimize for ALL THREE, always)

1. **Fastest possible build.** Cache-first: narrow per-file closures, local cache exports, the
   compiler cache wired end to end AND measured (stats to stderr, the stream a clipped step log
   keeps), a pinned buildkitd GC budget, and the parallelism levers taken when proven safe. Idle
   cores are the standing wall-clock reserve. Re-measure before citing a number: a CPU figure
   quoted here for weeks came from a broken sampler. Correctness bounds every shortcut; speed
   that risks a silently wrong image is not speed.
2. **Maximum stability.** Digest-pinned handoffs, machine-checked ancestry, verified version pins
   (checksums from official sources), the five shell bug classes (§ Shell safety conventions)
   never reintroduced, and gates that FAIL LOUDLY: an assertion-free PASS ("will work at
   runtime") or an inner warning swallowed by an outer green is a defect, not a success.
3. **Many tests.** Every fix ships a regression test where testable: a unit suite under
   `linux/scripts/tests/` (auto-discovered, run by preflight's `script-tests` slug, NOT by the
   pre-commit hook), a lint gate, or a smoke assertion against a `versions.env` pin.
   **Mutation-test every new gate**: break what it guards, watch it go red, and say in its header
   what it does NOT cover. A gate that cannot fail is worse than no gate; two audits found one.
4. **Docs follow the change, in the same work unit.** A behavior, flag, workflow or invariant
   change updates AGENTS.md (rules, quick reference), README.md (user-facing pointers), the owning
   `docs/` page and `CHANGELOG.md` before it is done. A mechanism only git history knows does not
   exist for the next session.
   Image publication also requires the digest-specific consumer receipt before a public tag
   moves; see [image-acceptance.md](docs/image-acceptance.md) for replay and its coverage limits.
   Successful consumers must preserve versioned sources. Manual promotion also preserves
   the target's runtime platforms; an early shell-gate override cannot bypass acceptance.
   `--gates-only` exits before builds, candidate creation and promotion, including when
   combined with push flags; it provides no consumer acceptance receipt.
   Linux acceptance restores disposable rootful checkout ownership on every exit;
   failed container cleanup or ownership restoration cannot produce a passed receipt.
5. **Our build always wins over the distro copy** (owner directive 2026-09-01). Where a `/opt`
   tree and a distro package export the same soname, ours wins the `ld.so` lookup: write
   `000-<name>.conf` into `/etc/ld.so.conf.d` (read in SORT order) and never rely on a purge,
   because another dependency pulls the distro copy back in. The soname-precedence gate enforces
   it on the SHIPPED bytes. Same rule for `PATH`, `PKG_CONFIG_PATH` and `PYTHONPATH`.
6. **One-line comments, only the why**, in every repo of the family: § Comments: one line, only
   the why.
7. **Quality exceptions must shrink.** Refactor the code to satisfy duplication, complexity and size
   gates. Do not add an allowlist entry, increase a frozen budget, raise a threshold or narrow scan
   coverage to make a change pass unless the owner explicitly authorizes that exception. Existing
   entries are debt; remove them when the underlying finding is fixed. The function-size, complexity, comment-size
   and masked-declaration lists are empty; keep them empty. Share duplicated behavior; do not rename
   variables, reformat copies or add suppressions to evade a duplication finding.
   Copied runtime environments, shell CLI libraries and Windows launcher/uv modules carry their shared companions; do not restore private fallbacks.
   Windows module visibility suites share the cold-import probe; keep child failures and parent-session isolation observable.
   Architecture and UV test suites carry their shared fixture companions; use harness PE and wheel constructors for valid samples.
   Windows structural tests use the harness AST readers, command binder and Dockerfile stage parser; parse errors must fail before inspecting declarations.
   Windows probe transports share child cleanup and report parsing; retain stderr, timeout, exit and assertion accounting policies.
   Windows diagnostic and host scripts carry their shared module companions; keep required failures fatal and advisory failures visible.
   Windows disk probes distinguish zero from unknown; shared lavapipe acquisition retains caller PE, registry and environment verdicts.
   Source file-tree staging and patch sweeps share transport and accounting; keep caller selection, ordering and fatal minimums.
   Stateful Windows fixtures use the harness binding APIs; preserve collection identity, fake argv and nested-function restoration.
   Required Windows siblings import unforced into their owner scope and fail on missing companions; test cold, private-warm and global-warm visibility.
   Windows compiler-wrapper setup and removal share the canonical variable list; emptying an environment variable and removing it remain distinct.
   Windows source builders share Meson binaries, ARM per-file feature selection, handoff transfers and sccache commands; retain caller flags and failure policy.
   Windows mutation fixtures share module lifetime; import or parse failures cannot satisfy an expected assertion failure.
   Windows script workspaces share AST validation before allocation and cleanup; log and Cargo paths use the canonical rooted-path resolver.
   Windows suites share `New-TestDir -Prefix` and `Assert-Throws -MessagePattern`; suite-scoped directories retain their `AfterAll` cleanup.
   Fixture cleanup uses `Remove-TestDir` with literal paths; bracketed diagnostic prefixes must leave no temporary roots.
   Inline source patchers share the patch API; `-Quiet` transfers diagnostics to the caller without relaxing required inputs or postconditions.
   CMake/CTest library copies include `project-env.sh`, `log-bootstrap.sh` and the Vulkan leaf; SDK hooks keep precedence over explicit setup scripts.
   Renovate drivers require `renovate-cli.sh` and `renovate-git.sh` beside `renovate-say.sh`; preserve their distinct dry-run policies and nonempty-list advice.
   Shared harness mutation suites stay host-portable; native batch execution remains in the separately discovered Windows suite.
   Copied code-quality and coverage libraries carry `cli-value-options.sh`; preserve empty-argument filtering, prefixing and caller argv order.
   Core disk probes share validation without merging zero-disabled and nonnegative-free-space policies.
   Test workers use the harness optional-function emitter; keep required definitions mandatory.
   Named mutation-check suites carry their case-executor companion; failed controls and invalid recipes remain failed results.
   Shared mirror enumeration preserves source-file order and original shell-option behavior; artifact and image probes retain caller failure policies.
   ORT and GenAI provenance checks share hashing and chain-byte membership; keep their distinct archive and exemption policies.
   Copy `compiler-cache-utils.sh` beside `common.sh`, cache modules and standalone cache probes and `media-payloads.sh` beside packaging copy/validation scripts; preserve narrow mounts.
   Copy `elf-strip.sh` beside `build-helpers.sh` or a minimal toolchain bootstrap; keep its narrow GCC/LLVM mounts.
   Copies of `python_uv.sh` and `webdav-download.sh` carry `python-probe.sh`; missing companions fail rather than restoring interpreter-selection copies.
   Windows formatting preserves distinct C/C++ fallback and tracked-only Dart policies; copied source-build suites carry their retry and media wiring fixture companions.
   Repository refresh shares best-effort fetches; callers retain checkout failure policy. Linux parser destination maps preserve raw values and consumed-argument counts.
   Object smokes share compile/cleanup lifecycle while retaining caller ELF policies; allocation or cleanup failure cannot pass.
   Host probing preserves target/build precedence and failed/empty probe behavior; shared runtime transports retain Python guards and caller sentinel verdicts.
   Base, toolchain and required-platform entry points carry `module-bootstrap.sh` in copied and mounted closures; keep the per-file mounts narrow.
   Cross-verification shares target selection without merging caller fallback, skip-diagnostic or architecture-restoration policies.
   Native and cross LLVM builds share source-cache validation and eviction in `common.sh`; retain their distinct fetch and build-directory policies.
   Cross and Canadian GCC share builder invocation; both callers raise builder failures explicitly, even when installed tools already exist.
   Android CMake consumers use `android_cmake_target_args` for NDK, ABI and API selection; keep their project options in the caller.
   Libstdc++ repair and pinning share the foreign-target predicate; keep raw arch comparison, probe fallback and unconditional target resolution.
   Cross-Python path helpers share context and directory lookup; preserve staged precedence, argument forwarding and failure short circuits.
   Vulkan target components share launcher and accounting; preserve required-component verdicts, WSI checks and glslang pass order.
   TVM compiler validation and selection share GCC-name resolution; keep override validation and wrapper argument order.
   Logging prefixes share severity formatting; preserve ANSI bytes, streams and NO_COLOR precedence.
   Windows TCP reachability shares one bounded dual-stack socket probe; malformed URLs stay closed and the socket helper stays private.
   Standalone fallback registration keeps caller lookup policy; copied Abseil and payload entry points carry the logging bootstrap in its documented layout.
   Smoke ELF inspection carries its platform owner and preserves caller parser overrides without leaking platform initialization.
   Bundle packagers share scoped facts, bundle copying, desktop/icon staging and artifact verdicts; invoke renderers unconditionally so Bash errexit remains active.
   ONNX web steps share lockfile retries and JS artifact verdicts; keep install failures fatal and check both source and copied artifacts.
   Agentic build, test and quality phases share execution; preserve fatal build/test results and advisory quality results.
   Runtime and cross orchestrators share common CLI dispatch; preserve consumed-argument counts and help code 255.
   Critical source-pattern checks share verdict handling; failed probes increment the aggregate and must reach the failing summary.
   Python CI driver tests use `t_python_ci_fixture` for isolated script trees and workspace detection; keep tool stubs in each suite.
   Verified downloads must propagate fetch failures even under conditional calls; a matching stale archive does not excuse a failed fetch.
   Compiler-rt consumers share verified extraction and library discovery; keep base-stage advisory and source-build fatal policies distinct.
   Temporary process environments restore absent, empty and existing values after setup or callback failure; sanitizer overrides belong to the test child.
   Silo probes share wininit discovery, debugger transport and recursive read grants; preserve attach policy, raw status and manual handle mode.
   Cross-bundle DLL closure uses the architecture graph; retain first-directory precedence, machine checks, indexed API sets and system descendants.
   Git fixtures share checked local repository setup; native tool failures must fail the fixture without changing global identity.
   Windows native logging and DLL smoke probes share transport; preserve blank failure evidence, loader cleanup and caller coverage minimums. Smoke module copies carry Shared.
   Staging directories share literal-root setup; failed reset or allocation aborts before payload copy and proof.
   Windows archives share extraction lifecycle; strict failures remain the default and pinned link exceptions stay explicit.
   ORT directory indexing preserves caller recursion, filename and unreadable-file policies. Flutter sync preserves CMake-state exclusions and robocopy verdicts.
   Python CI suites carry their shared driver fixture; preserve child status, call logs and parent environment isolation.

## Container Architecture

One Dockerfile per stage, chained base → toolchain → sdk → media → android → package → torch,
with an optional `gpu` layer (`nvidia` or `amd`) between sdk and media in a variant chain. Each
stage is built and pushed on its own and pinned into its child by digest, which is what makes a
single-stage rebuild possible.

Stage graph, tags, platforms and what each stage contains: [`overview.md`](docs/overview.md) and
[`linux-cross-builds.md`](docs/linux-cross-builds.md). Naming rules that must not drift:
§ Windows-Specific Naming below and [`consumer-image-contract.md`](docs/consumer-image-contract.md).

### Image and tag naming (published tags)

**One published tag is one MANIFEST, carrying every architecture its variant supports** (owner
directive 2026-09-21), on both lanes. Both lanes publish into the SAME registry repo, so only one
owns the bare `:latest`: Linux does, and Windows keeps its lane qualifier (owner directive
2026-09-22).

| | Default manifest | Variant manifest | Per-arch wrapper (internal) | Cross bundle (NOT a platform) |
| --- | --- | --- | --- | --- |
| Linux | `:latest` | `:latest-<variant>` | `:latest-<arch>`, `:latest-<variant>-<arch>` | — |
| Windows | `:winamd64` | `:winamd64-<variant>` | — (one platform) | `:winarm64` |

- **The grammar is `<version>[-<variant>][-<arch>]`.** `latest` fills the version slot, so a
  pinned release is `:2026.09` / `:2026.09-nvidia` with no new rule. Tags are parsed by position,
  which makes the next bullet a hard rule.
- `<variant>` names what makes the image different (`nvidia`, `rocm`), NEVER an architecture:
  `:latest-amd64` must stay unambiguous, which is why `amd` is spelled `rocm`. A new architecture
  adds an ENTRY to a variant's manifest; a new variant adds a TAG.
- **A variant exists only for a stack that cannot ship in `:latest`** (owner directive
  2026-09-22): CUDA and ROCm are multi-GB, driver-bound and mutually exclusive. An accelerator
  whose runtime fits is built INTO the default image: Hailo-10H (amd64/arm64, `Dockerfile.torch`)
  and QNN (arm64, when the QAIRT zip is staged — `docs/qnn-linux.md`). There is no `:latest-hailo`
  or `:latest-qnn`; the standalone `:hailo` variant and `Dockerfile.hailo` were retired on
  2026-09-22 as a duplicate of the standard build. A variant chain builds a variant (§ Build
  Workflow), never `ENABLE_*` flipped on the default one: that pushed GPU bytes under the default
  tags.
- The per-arch images (`:latest-<arch>`, the stage tags `:latest-base-<arch>` /
  `:latest-package-<arch>`) are the wrappers the manifest is assembled from: implementation
  detail, consumers resolve the manifest.
- **nvidia's cross stages (`gpu`, `media`, `android`) push to a separate, private package,
  `<repo>-stages`** (owner decision 2026-10-21): they carry TensorRT's SDK, which may ship only as
  runtime files, and GHCR sets visibility per package. Everything else stays in `<repo>`
  ([`linux-accelerator-images.md` § Stage images](docs/linux-accelerator-images.md#stage-images-a-private-package)).
- **`:latest-cross` is RETIRED** (owner decision 2026-09-22), the old name of `:latest`. Nothing
  composes or pushes it, and `verify_ci_image_refs.py` rejects it under `.github/`. **The registry
  tags outlive the code, deliberately** (owner, 2026-09-22): work stays on `develop`. Since
  2026-09-25 the fleet calls this repo's composite actions and reusable workflows at `@develop`
  (owner directive; 110 refs across eight repos, none passing an explicit `image:`), whose
  `versions.env` names `:latest`; `main` still carries `CI_IMAGE_LINUX_TAG=latest-cross`, frozen
  at the last release that published it. **The registry tags are gone since 2026-09-29** (owner
  decision, CON13): republishing `:latest` left `:latest-cross` alone on the old index
  `ec4bb68b`, and `ghcr-delete-tags.sh` deleted it and the three `:latest-cross-<arch>` wrappers.
  A lane still at `@main` fails at `docker pull`; move it to `@develop`.
- A new variant = a new manifest tag. The manifest lane REFUSES to shrink a published index
  (§ Push and Publish Rules), so a partial run cannot drop an architecture from one.
- **Windows follows the variant rule for CUDA too** (owner decision 2026-09-27).
  `Build-Buildkit.ps1 -Gpu` (`-Variant nvidia`) builds under `bk-*-nvidia` stage tags and
  publishes `:winamd64-nvidia`, or `:winarm64-nvidia` for the cross bundle; `:winamd64` is CPU +
  DirectML. Before that the nvidia build wrote the default tags, so the `:winamd64` published on
  2026-09-22 carries CUDA until that tag's next publish. `Resolve-BkVariant` refuses a push to any
  other tag.
- **Windows is the documented exception, a platform fact, not a convention:** `windows/arm64` does
  not exist as a platform — Microsoft publishes no arm64 `servercore`/`nanoserver` base and Windows
  Server has no arm64 release
  ([Windows-Containers#586](https://github.com/microsoft/Windows-Containers/issues/586)). The arm64
  lane cross-compiles inside the `windows/amd64` container and emits an **artifact bundle**, so
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
`build.ps1`, **deleted 2026-08-31**: neither exists any more. Full build sequence:
`docs/windows-builds.md` § Build Commands.

---

## Quick Reference

Commands, knob tables and per-stage recipes:
[`linux-cross-builds.md` § The command reference AGENTS.md used to carry](docs/linux-cross-builds.md#the-command-reference-agentsmd-used-to-carry).
Four of them are RULES and stay here:

- **Never `pkill` the orchestrator.** `bash linux/scripts/stop-cross-chain.sh` finds the run by
  its pidfile and reaps the orphaned nerdctl/buildctl subtree; a `pkill` orphans the children and
  leaves the build solving.

- **Never edit a file in a running chain's closure**, and never restart buildkitd while a build
  solves (§ Caching discipline, rules 1 and 4).

- **Verify the shipped BYTES, never the push.** `:latest` (then `:latest-cross`) shipped STALE
  five times with every static gate and every smoke GREEN, because all of them checked the push,
  not the content. `verify-shipped-wrapper.sh` gates it in `build-runtime-manifest.sh`, over every
  arch, BEFORE the boot smokes and before the manifest is assembled; `WRAPPER_CONTENT_GATE=0`
  downgrades it to advisory, a decision and not a default. The saga and its root cause:
  [`cross-build-verification.md`](docs/cross-build-verification.md#verify-the-shipped-bytes).

- **`--log-dir` is not universal.** `build-cross-chain.sh` and `build-cross-stage.sh` tee each
  stage; the other three orchestrators do not take the flag, so pipe them through `tee` yourself.

### Windows Container Build

All stages use Ninja + clang-cl + lld-link on containerd + BuildKit + nerdctl, each tool where its
pipe ACL allows: build non-admin with `windows\Build-Buildkit.ps1`, inspect `bk-*` images from an
ADMIN shell. A fresh machine follows [`windows-host-setup.md`](docs/windows-host-setup.md), not a
reconstructed sequence. Role split, lane mechanics, isolation policy and recovery paths:
[`windows-builds.md` § The Windows lane as AGENTS.md carried it](docs/windows-builds.md#the-windows-lane-as-agentsmd-carried-it)
and [`windows-build-lanes.md`](docs/windows-build-lanes.md).

### Running Linux containers (Rancher Desktop)

Use `nerdctl`, never `docker`, and never assume a tool is in the image because your dev box has it
(`jq` is NOT in the Linux image; `python3` is). A GPU container on a Jetson needs three extra flags
under rootless nerdctl:
[`linux-host-setup.md` § B2b](docs/linux-host-setup.md#b2b-a-gpu-container-on-a-jetson-with-rootless-nerdctl).
Recipes, mount traps and the one driver that answers them (`run-in-ci-image.sh`):
[`rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).

### LLM Stack (Ollama + Open WebUI)

[`linux/llm-stack/`](linux/llm-stack/README.md) is a standalone serving stack, CPU-only by default,
GPU by opt-in override; it is the family's reference server, and the benchmark suite that points
at it lives in OrchestrANT. Two rules: **never put a key in `backends.json`, only the NAME of the
environment variable that holds it**, and **the context Ollama lists is the model's maximum, not
what fits**: size it against real VRAM before claiming a context length.

**The gateway in front of the GenieX lanes patches APISIX internals**
(`gateway/lua/geniex_hook.lua`): an APISIX bump is done only when
`GATEWAY_E2E=1 pytest linux/llm-stack/tests/gateway_e2e` is green on it, and its config changes
only through `scripts/serve-stack.sh`, which validates before it swaps:
[the llm-stack README's Gateway section](linux/llm-stack/README.md#gateway).

### GenieX on Snapdragon (on-device OpenAI server)

The Kataglyphis coding agents run **fully on-device on Snapdragon** (Adreno GPU or Hexagon NPU)
through an OpenAI-compatible server, with WSL2 clients pointing at the Windows host. Setup, model
matrix, measurements and the debugging trail:
[`geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md).

### Branches, CI rounds and releases

**Owner rule for every repo of the family (2026-10-15).** `develop` is the default branch; every
push to it runs the Linux x64 lane. Every other lane runs when a commit message asks for it
(`[ci windows]`, `[ci arm64]`, `[ci all]`, …) or when started by hand; every lane workflow has
`workflow_dispatch`. `main` moves only by a fast-forward to a `develop` commit whose full round is
green, and only the owner moves it, or an agent the owner tells to in that turn. Every push to
`main` runs every lane again and releases `v<version>` only when all are green. Tokens, merge
steps, workflow shape: [`docs/branch-and-release-strategy.md`](docs/branch-and-release-strategy.md).
Which repo follows it yet, and this repo's own triggers:
[`docs/ci-build-triggers.md`](docs/ci-build-triggers.md).

### Reading CI status with the GitHub CLI

**A skipped job is not a passed job.** `gh run view` prints both as a tick, and reading a required
lane's skip as success is how a red push looked green here. Check each job's conclusion, not the
run's summary glyph. Commands, and which jobs are still gated:
[`github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md) and
[`ci-build-triggers.md`](docs/ci-build-triggers.md).

### Searching the tree: ripgrep (`rg`)

**Owner rule for every repo of the family (2026-10-05).** Search with `rg`, not `grep -r` or
`findstr`. It honours `.gitignore`, so it skips the `build/`, `.dart_tool/` and vendored-SDK trees
that `grep -r` walks, and it skips binaries.

- Install: Windows `winget install --id BurntSushi.ripgrep.MSVC -e --scope user` (no admin), Linux
  `apt install ripgrep`. The `:latest` and `:winamd64` images carry it from their next chain
  (`BACKLOG.md` CON56).
- `rg -n PATTERN`, `rg -l PATTERN`, `rg --files -g '*.ps1'`; add `-uu` when the ignored trees are
  what you are looking for.
- A script that may run where `rg` is absent (a CI runner, an older image) keeps `grep`, or checks
  `command -v rg` first.
- Negative search assertions require the no-match status `1`; missing-tool `127` and search-error `2` must fail the fixture.

### Where does knowledge belong? (docs, not just code)

A fix that only exists in code is a fix the next reader re-derives. Write the WHY on the page that
owns the topic ([`docs/INDEX.md`](docs/INDEX.md) maps them and opens with the rule) and link it
from the code. A CONSUMER repo's split: [`shared/templates/README.md`](shared/templates/README.md).

### Comments: one line, only the why

**Owner rule for every repo of the family (2026-09-30).** Comment like an experienced developer:

- **One line.** No comment blocks.
- **Only the why**: a non-obvious reason, a trap, a load-bearing constraint. Code that needs a
  what-comment needs a better name instead.
- **No** narration, restated code, incident history, dates, decision prose, or commented-out code.
- **A trap that needs more** gets a short paragraph on the `docs/` page that owns the topic, and
  the code keeps a one-line pointer: `# See docs/build-cache-tiers.md § 5.1`.
- **API docs stay, but short**: a one-line docstring, `///` or `.SYNOPSIS`, with parameters only
  where they are not obvious.
- **Not comments**: license headers, shebangs, tool directives (`# shellcheck`, `# noqa`,
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
[`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md); read it before
hand-rolling any of that in a consumer.

When adding here:

- PowerShell 7 (pwsh) is the standard shell and the Windows containers' default SHELL. Every
  `.ps1`/`.psm1` declares `#requires -Version 7.0` on line 1 (or directly under the SPDX header),
  before any `param()`. Exactly two tracked files omit it, on purpose, both pinned 5.1-parsable by
  a suite: the script that INSTALLS pwsh, and the delete guard, which must not fail OPEN on a host
  without `pwsh`.
- **PowerShell file names.** Three shapes: PascalCase `Verb-Noun.ps1` with a `Get-Verb`-approved
  verb for scripts, `Windows<Area>.<Facet>.psm1` for modules, `<Subject>.Tests.ps1` for suites.
  Three tracked files sit outside all three on purpose: the delete guard, registered by that exact
  string, so a rename silently unregisters it, and `windows/scripts/build/rocm-checks/`, whose
  files are named after the component they check (`FFmpeg.ps1`, 2026-09-23). A
  `verb-noun-name.ps1` spelling anywhere is stale, not a variant: 101 scripts were renamed on
  2026-09-06.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`; consumers resolve
  them ANTfrastructure-first with a vendored fallback. The resolver is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](shared/windows/templates/README.md).
- **Exporting a function a build script calls directly is TWO edits**: `Export-ModuleMember` in
  the owning module, and the re-export list if the script reaches it through one. Module-INTERNAL
  use needs neither, so an omission is invisible on a dev box and surfaces as `CommandNotFound`
  hours into a container build. Two suites hold the two directions (every CALLED name resolves;
  every LISTED name exists); neither replaces the other.
- **The two-consumer test.** What a second consumer needs belongs here, not vendored twice. Moving
  one up, turn its project-specific values into parameters whose DEFAULTS keep the original
  behaviour, so the vendoring consumer can delete its copy with no behaviour change.
- Document the **symptom**, not just the fix: platform traps are found by recognising an error
  message, not by reading code.
- Keep functions free of consumer-specific paths, preset names and build directories; pass those
  in as parameters.
- **Deleting is a consumer change.** A hub file may be removed only when the consumer inventory
  (`linux/scripts/verify_consumer_inventory.py`, over every repo in `.github/consumers.json`)
  reports it *named by nobody*, and the deleting commit names the consumer commits that dropped the
  reference. A "zero callers" grep of THIS tree is no evidence: consumers pin a submodule commit
  and reach modules by NAME or by backslash path, so they neither break at delete time nor appear
  in the grep. Four sweeps made that mistake; the last deleted three live files, restored a week
  later.
- **Bash file names.** New files are kebab-case. The snake_case names under `linux/scripts/`
  (`02-toolchain/python/ci_*.sh` and `build_python.sh`, `02-toolchain/rust/cargo_*.sh`,
  `_*_guard.sh` and `_cargo_wrapper.sh`, `version_util.sh`, `01-core/python_uv.sh`,
  `05-frameworks/flutter/flutter_checks.sh`, `06-packaging/package_archive.sh`) and
  `linux/webserver/scripts/flutter_integration_smoke_test.sh` are frozen: consumer wrappers
  resolve them by path, so a rename breaks consumers for no structural gain.
- **Workflow file names** (owner decision 2026-09-24, fleet-wide): kebab-case, one file per
  platform and arch (`linux-x64.yml`, `windows-x64.yml`), display names
  `<Platform> <Arch> · <what>`. The hub's REUSABLE workflows (`python-ci-*`,
  `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, the docs-site lane, and
  `release-publish`) keep their file names for good: consumers call them at `@develop`, so a
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
[`docs/windows-build-invariants.md`](docs/windows-build-invariants.md). **Read it before editing
anything under `windows/`.** Each entry carries the incident that produced it; a rule whose
evidence no longer matches the code is a bug in the rule.

ROCm installers called from flat BuildKit mounts receive `-ModuleRoot` explicitly; direct
checkout calls default to `windows/scripts`. See [`windows-rocm.md`](docs/windows-rocm.md).

The three most often regressed:

- **pwsh 7 everywhere**: no `powershell.exe`, no `cmd` SHELL directives.
- **Every BK chain ends with a mandatory smoke gate**: `-SkipSmokeGate` is for chain iteration
  only, never for "it passed locally".
- **`versions.env` is the single source of truth**: never hardcode a version in a script or
  Dockerfile. Host-tool pins no image build reads live in `tool-pins.env` beside it (§ Version
  Bumping).

### TensorRT Setup (Optional)

EULA-gated, so nothing downloads it: stage the zip by hand and the Windows lane picks it up. Where
it goes and the layout it needs: [`windows-cross-builds.md`](docs/windows-cross-builds.md).

### QNN / Qualcomm AI Engine Direct Setup (Optional, #121)

Login-gated and EULA-bound like TensorRT: staged by hand, never committed, and only the README
rides along on each lane. Windows: [`windows-cross-builds.md`](docs/windows-cross-builds.md);
Linux ARM64: [`qnn-linux.md`](docs/qnn-linux.md).

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

**One source of truth: `CUDA_ARCHITECTURES` in `versions.env`.** Everything else is a fallback
default or an assertion that must move WITH it, so a trim cannot happen by accident. Changing the
set is an owner decision, never a speed lever for a dev iteration.

Today (owner decision 2026-09-23): **`86;87;89;120`**.

| CC | Architecture | Hardware |
| --- | --- | --- |
| 86 | Ampere GA10x | RTX 3060-3090, A10, A40 |
| 87 | Ampere GA10B | Jetson AGX Orin |
| 89 | Ada Lovelace | RTX 4060-4090, L40/L40S |
| 120 | Blackwell | GeForce RTX 5050-5090, RTX PRO Blackwell |

Not built, one token each: `75` Turing (T4, RTX 20xx) · `80` Ampere GA100 (A100, A30) · `90`
Hopper (H100, H200) · `100` B100/B200 · `103` B300/GB300 · `110` Jetson Thor · `121` GB10/DGX
Spark. 80 and 90 were **retired 2026-09-23**; their line stays commented in `versions.env`.
CUDA 13 floors at **75**: Maxwell, Pascal and Volta left the toolkit, so nothing below it can
come back while `CUDA_VERSION` is 13.x.

**To add or remove one**, edit these together (a gate fails otherwise, by design):

1. `linux/scripts/01-core/versions.env` — the value.
2. `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` — the pinned assertion.
3. `linux/scripts/tests/test-version-forwarding.sh` — forwards the literal twice.
4. `docs/scripts/mutations.json` — the mutation's find/replace text.
5. The `${CUDA_ARCHITECTURES:-…}` fallbacks (ORT, OpenCV) and
   `windows/Dockerfile.media-builder`'s ARG default + the psm1 fallback:
   `sync_versions.py --check` grades the Dockerfile, the rest are plain copies.

**Four facts decide WHICH number you need**; they are not interchangeable:

- **A cubin runs on its own major only, at an equal-or-higher minor.** 86 does not reach 87; 89
  does not reach 120. Neighbours buy nothing.
- **ONNX Runtime narrows it further.** It rewrites every entry to `sm_<cc>a-real` (arch-specific,
  `-real` = cubin only), so in the ORT artefact `120` covers 12.0 and NOT 12.1 (GB10), and `100`
  would cover B100/B200 but not B300 (10.3). Spell out the exact hardware you own.
- **There is no PTX to fall back on.** ORT embeds none and OpenCV leaves `CUDA_ARCH_PTX` empty, so
  a missing arch is a hard failure at session creation (`no kernel image is available`), not a
  slow path. That is what retiring 80 costs an A100.
- **No letter suffixes** (`90a`, `100f`): ORT appends the `a` itself, and OpenCV's dotted-form
  conversion mangles a suffixed entry. Digits only, ascending for readability; since 2026-09-23
  nothing depends on the order (the trailing-`90`→`90a` rewrite is gone: it silently did nothing
  once the list stopped ending in 90).

**Cost:** each entry is a full cubin per CUDA source file, so four arches compile every ONNX
Runtime and OpenCV CUDA kernel four times, the biggest lever on GPU build time.
`CUDA_ARCHITECTURES=120` alone cuts the CUDA compile to roughly a fifth for a local iteration.

**ROCm has the same question, unanswered.** `amdrocm-core-dev10.0` pulls all 25 gfx targets
(~19.6 GiB) because nothing selects. Per-gfx metapackages are the largest single size win there:
[`linux-accelerator-images.md` § ROCm](docs/linux-accelerator-images.md).

## Build Workflow

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
CROSS_VARIANT=nvidia|rocm       → (shared sdk) → gpu → media → android → runtime → manifest
```

**A variant chain is the only way to build a GPU image** (2026-09-22). `CROSS_VARIANT=nvidia` /
`rocm` (or `ENABLE_NVIDIA=true` / `ENABLE_AMD=true`, which imply it) is an ENVIRONMENT knob,
because `stage-defs.sh` builds the stage graph when it is sourced. It inserts the `gpu` stage,
suffixes every tag from there on with `-<variant>` (`tag-naming.sh` `cross_variant_infix`), pushes
nvidia's stages to the private `<repo>-stages` package (`cross_stage_repo`), starts
at `gpu` and refuses the shared stages, keeps its own `chain-status-<variant>.json` and
`out/build-logs/<variant>/`, and refuses what it cannot build (`stage-defs.sh`
`cross_variant_refusal`, shared with `build-cross-stage.sh`): rocm off amd64; any target that is
not the build platform's arch (CUDA/ROCm install for the BUILD platform, so a cross target would
ship its GPU libraries); and a PUSHING run off `CROSS_BUILD_PLATFORM=linux/amd64` (the shared
`:cross-sdk-<arch>` is the amd64 lane's). The runtime helpers refuse a default output tag under a
variant. **Chains run strictly one at a time**: the pidfile is claimed atomically at start, and a
live one makes a second chain refuse. Commands:
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md).

Stages 1-5 run on `linux/amd64`, or natively on an arm64 host with
`CROSS_BUILD_PLATFORM=linux/arm64` (run end to end on a Jetson AGX Orin,
[`linux-accelerator-images.md`](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson)).
Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches),
delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the
next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`, against stale cache reuse. The stage
graph: `linux/scripts/01-core/stage-defs.sh`; full pipeline: `docs/linux-cross-builds.md`.

The **Windows lane** is a separate staged build, `base → [nvidia|rocm] → toolchain → media →
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

**Stevedore** (`winget install stevedore` or `choco install stevedore`) provides nerdctl +
containerd for Windows Containers; **reboot** after installing it. Docker Desktop or Rancher
Desktop work too, with `docker` commands. nerdctl needs the CNI nat conf
(`docs/windows-build-lanes.md` § Getting it going, step 2) and runs from **admin** shells only;
Stevedore's `docker.exe` stays the publish/inspect tool. Run with `--isolation process` for the
host's full CPU count (Hyper-V isolation is capped at 2 CPUs): `docs/windows-builds.md` § Running
the Image. The 2026-08-03 history of the conf is on that page.

### Stevedore Fixes After Install

Apply the post-install fixes in `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes
(Defender exclusions, daemon.json cleanup, default runtime change, verification), the canonical
source.

**Two host fixes keep the BK lane's RUN steps from idling.** `Install-NewHost.ps1` (admin) sets
both, `Test-HostSetup.ps1` checks both, and the from-base chain of 2026-10-14 measured both:

- **The patched runhcs shim**
  ([`windows-host-setup.md` § R1](docs/windows-host-setup.md#r1-rebuild--deploy-the-patched-shim)).
  Every Stevedore update reverts it, and the driver's `Assert-ShimPatch` then refuses to build.
  With it, a RUN reaches DONE 1 to 3 s after its last output line.
- **`TcpTimedWaitDelay` = 30 s**
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
| `.github/workflows/` | This repo's own lanes plus the `workflow_call` ones consumers reuse (`python-ci-*`, `container-ci-windows`, `lint-gates`, `submodule-pins`, `build-docs`, which builds, checks and publishes every docs site: [`docs-sites.md`](docs/docs-sites.md), and `release-publish`, every `release.yml`'s version check and publish: [`branch-and-release-strategy.md`](docs/branch-and-release-strategy.md#the-reusable-release-workflow)). [Triggers](docs/ci-build-triggers.md) |
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

Guard empty arguments before associative-array lookups; an empty positional CMake
preset retains the caller-default behavior and its positional-array entry.

Each of these killed or falsified a real build before it was fixed. The full stories:
[`changelog-archive-2026-08-13.md`](docs/changelog-archive-2026-08-13.md) (2026-08-08);
`tests/test-ifs-safety.sh` lint-gates class 3. When writing or reviewing bash here:

1. **No `trap … RETURN` inside functions**: the trap survives the function and fires again on the
   CALLER's return, where the locals are gone (`set -u` abort AFTER a green run). Capture rc with
   `|| rc=$?` and clean up explicitly.
2. **Guard every pipeline whose empty result is legitimate**: `grep`/`find`/`ls`/`du`/`pgrep`/
   `dpkg -S`/`readelf` in `$(...)` under `set -euo pipefail` needs `|| true` when the code below
   handles the empty case. `find | head -1` also dies of SIGPIPE (rc 141) on multiple matches.
3. **Split comma lists with `IFS=',' read -r -a arr <<< "$list"`**, never `${list//,/ }` or
   `$(... tr ',' ' ')`: under a script's `IFS=$'\n\t'` those do not split, and the loop runs once
   with the whole list as one bogus item. Sourced 01-core functions run under the CALLER's IFS.
   The two list helpers (`arch_list_to_words`, `smoke_arch_words`) emit NEWLINE-separated words
   since 2026-08-08 so `for x in $(...)` splits under any IFS; keep that if you touch them
   (test-smoke-arch-parity.sh pins it).
4. **Source vendor scripts (SDK setup-env, venv activate) with nounset suspended**:
   `case $- in *u*) …; set +u;; esac` … `set -u` after. LunarG's setup-env.sh reads `$1`
   unguarded.
5. **Never end a function with a bare `[ cond ] && action`**: the false case becomes the
   function's return value 1, and under `set -e` the HEALTHY path kills the caller. End with
   `|| true`, `; return 0`, or an `if`.

Parallel result collection must explicitly propagate a failed harvest, including when
workers succeeded. Publish worker pins only after a successful, nonempty read;
conditional callers disable `errexit` throughout the helper's body.

**Host tool traps when you MEASURE a run.** These falsify your AUDIT, not the build; each produced
a wrong verdict on 2026-08-31, and none announces itself:

CMD fixture `COPY` calls take native Windows paths at that boundary, even when the
shared test helper emits forward slashes. Prove the copy before trusting its build result.

- **`grep` on this host is ugrep.** A pattern beginning `--` parses as an OPTION and silently
  matches nothing, so a fault-injection arm that never fires looks like a clean run. Always
  `grep -e "$pat"`. Symptom entry:
  [`docs/failure-modes.md`](docs/failure-modes.md#a-fault-injection-test-passes-and-proves-nothing-grep-is-ugrep).
- **`comm` needs `LC_ALL=C sort` on BOTH inputs.** Any other collation reports a wrong set
  difference that still looks like an answer: it turned "0 shared" into "36 shared" in one day's
  audits, and had made a preflight assertion pass vacuously.
- **Never count warnings by grepping a BuildKit log.** BuildKit echoes each RUN's command text, so
  a warning string written INSIDE a Dockerfile command counts as if it had fired. Match real
  output lines only.

## Background jobs and test processes (no ghosts)

On 2026-10-21 the build host carried a test fixture spinning at 100 % for 2.8 days and 24 headless
Chromes holding 22 GB, plus a watcher an agent had detached and another agent had to find in its
transcript. Each was a child that outlived whatever started it. So:

1. **An agent starts a background job as a named user unit**, never `setsid nohup … &`:
   `systemd-run --user --unit=<name> -p RuntimeMaxSec=<bound> bash <script>`. Then
   `systemctl --user list-units '<prefix>*'` shows what runs, `systemctl --user stop <name>` ends
   it with every child, and nothing outlives its bound. A job meant to outlive the session (a
   chain, a watcher) says so in its handoff, by unit name.
2. **A test fixture ends on its own.** A spin or a sleep has a bound (`while [ "${SECONDS}" -lt 60 ]`,
   `sleep 60`); a fixture that only a kill can end outlives every interrupted run.
   Fixtures unrelated to ref resolution use a synthetic immutable app identity;
   moving-ref resolution belongs to `test-app-ref.sh`, not a graph dry-run.
   Graph/runtime fixtures also use disposable context directories and immutable parent pins.
3. **Tests run as process groups that are killed whole.** `lib-ordered-jobs.sh` starts every job of
   `run-tests.sh` and `preflight.sh` as its own process group and kills it when the job ends, after
   `OJ_TIMEOUT` (`RUN_TESTS_SUITE_TIMEOUT`, 900 s per suite) and, through `oj_reap` in the runner's
   EXIT trap, when the run is interrupted. The mutation gate ends each test's session after it, and
   every live one when it is itself killed, SIGTERM first so a runner inside can reap its own. A new
   runner that starts tests uses one of the two (`test-run-tests-reaping.sh`, the reaping cases of
   `test-mutation-gate.sh`).
4. **A wait loop waits on a PID or a file, with a timeout.** `until ! pgrep -f <pattern>` matches
   its own `bash -c` and never ends; `pkill -f <pattern>` can kill the shell that runs it.

Runtime dry runs start no heartbeat. A live heartbeat terminates and waits for its current
child directly; a separate PID assignment leaves a signal window that leaks output pipes.

Shared Chrome cleanup is asynchronous: callers await child exit and profile cleanup;
an immediate process-exit hook only kills. Cleanup failures remain fatal, and every
browser finishes cleanup before one peer's failure is reported
([docs-sites.md](docs/docs-sites.md#the-sidebar-toggle-check)).
The launcher owns cleanup until it returns: endpoint/page discovery, WebSocket
connection and initial DevTools failures must release the group, profile and hooks.

`linux/host-config/ghost-watch.sh` is the net under all four: an hourly user timer that reports
orphans heavy on CPU or memory or shaped like test leftovers
([`linux-host-setup.md` § B10](docs/linux-host-setup.md#b10-ghost-watch)).

## Caching discipline (do not regress)

Map: [`linux-build-basics.md` § Caching Layers](docs/linux-build-basics.md#caching-layers-what-is-cached-where).
Tiers, measurements and every failure class: [`build-cache-tiers.md`](docs/build-cache-tiers.md).
Toggles: `USE_CCACHE`, `USE_SCCACHE`, `USE_LLD` accept `0/false/no/off`;
`ENABLE_SCCACHE_RUST`/`ENABLE_SCCACHE_CUDA` are strict `0/1`.

The Windows lane's compile cache has two levels since 2026-10-15: each host's WebDAV, then an S3
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

2. **`~/.config/buildkit/buildkitd.toml` pins the GC budget** (`gckeepstorage`) so the multi-hour
   layers survive between runs. Do not delete it; restart buildkitd only BETWEEN runs
   (`systemctl --user restart buildkit`), never while a build solves.

3. **One resolver decides which compiler cache runs**: `compiler_cache_launcher()` in
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
   `--ccache` is a flag NAME, not a tool choice. Before a multi-hour run rides on a change here,
   `bash linux/scripts/02-toolchain/probe-sccache.sh` inside the compiler image answers in seconds
   whether a cache was actually consulted, which a successful compile does not.
   [`build-cache-tiers.md` § 5](docs/build-cache-tiers.md#5-scc1--the-ccachesccache-hybrid).

4. **Never edit a running orchestrator's main script.** bash reads it incrementally by byte
   offset, so an edit can corrupt the in-flight process. Sourced libraries are safe to edit for
   FUTURE runs, but see rule 1.

5. **Rules 1-4 are about the LINUX chain. Windows caches on other mechanisms**: where a layer sits
   relative to the Visual Studio install, how narrowly a module mount is scoped, and a GC floor
   that silently evicts the expensive layers when set too low. A Dockerfile edit there must keep
   the first two (a Pester suite refuses a whole-directory module mount); check a cache miss that
   looks like a bad key against that floor first. Tiers, figures and the two incidents:
   [`windows-build-resources.md` § The Windows cache, tier by tier](docs/windows-build-resources.md#the-windows-cache-tier-by-tier).

## Code Organization (key shared utilities)

**A new environment knob takes the prefix of whoever owns the DECISION**, not of the file that
happens to read it. The four prefixes:
[`adopting-in-a-new-project.md` § 8](docs/adopting-in-a-new-project.md); the `env-knobs` gate
grades this repo's own surface against them.

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. The single source of truth; never ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from the canonical name + aliases with fallback; use it instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`, instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`, the bootstrap for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`: the one entry that sources the 01-core module framework; every media build script sources it instead of copying a preamble block. (The old `media_build_preamble_init` alias is gone: zero callers, no definition.)
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, `cross_stage_repo()` (nvidia's private stage package), the runtime tag functions. Never construct tags by hand.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`. Informational: it prints digests and gates nothing.
- **Stage ancestry (gating):** `ancestry.sh` → `ancestry_output_annotations()`, `ancestry_recorded_parent()`, `ancestry_assert_chain()`. Every pushed cross stage records the parent ref it was built FROM as the OCI manifest annotation `org.kataglyphis.parent-digest`; a run with `--from-stage` after `base` walks that chain and HARD-FAILS when a parent was re-pushed after the child that would be inherited. Read path: `manifest-annotation.py` (annotations live in the base64 `Raw` field of `manifest inspect --verbose`). Absent annotation = warn (predates the mechanism); present + mismatch = fail. Escape hatch: `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`.
- **Cross-stage build:** `cross-stage-build.sh` → `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `cross_stage_assemble_runtime_helper_args()`.
- **Runtime flow init:** `runtime-flow-common.sh` → `init_runtime_flow_defaults()` (loaded by `lib-orchestrator.sh` in `runtime_flow_preamble()`, not sourced directly).
- **Retry logic:** `logging.sh` → `retry <max> <sleep> <desc> <cmd...>`.
- **Mirror args:** `build-helpers.sh` → `append_mirror_build_args_from_env()`.
- **Version forwarding:** `version-forwarding.sh` → `append_version_build_args()` (auto-discovers from `versions.env`).
- **CMake cache/linker:** `cmake-cache-linker.sh` → `append_cmake_cache_linker_args <array_ref>`, sourced by `03-media/core/common.sh` automatically.
- **Install deps preamble:** `cross-apt.sh` → `install_deps_preamble [packages...]`.
- **Media ENV reference:** `03-media/runtime/media-env.sh` is the canonical definition of PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH/GI_TYPELIB_PATH; the `Dockerfile.media` and `Dockerfile.package` ENV blocks must stay in sync with it.
- **Media artifact verification:** `03-media/runtime/verify-media-artifacts.sh` checks that each media build stage produced output, called from `Dockerfile.media` RUN steps after every library build. Stages: `onnxruntime-cpu`, `onnxruntime-genai`, `onnxruntime-gpu`, `onnxruntime-pkgconfig`, `litert`, `litert-headers`, `opencv`, `opencv-core`, `ffmpeg`, `gstreamer`, `libcamera`, `armnn`, `app-wheels`, `media-inputs`, `sizes`.
- **Runtime stage elements:** the `Dockerfile.torch` final stage is canonical for the COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, the kataglyphis user, OCI labels.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper (`BUILDKIT_HOST` support); use it instead of an ad hoc `nerdctl build`.

### Module Loading Order

**Which loader a NEW script uses is a rule, not a preference.** A script that can run inside a
container loads through `source_module`, which resolves both layouts; host-only orchestration
sources `artifact-common.sh`. Mixing them breaks at `/opt/scripts`, and a suite freezes the load
order. The dependency order and the one known wart:
[`shared-script-libraries.md`](docs/shared-script-libraries.md).

## Cross Chain Stage Handoff (do not regress)

- **A stage's parent is pinned by DIGEST, never by tag.** A tag can move between the moment a
  child resolves it and the moment it builds; that is how a chain built on a stale parent and
  shipped it green.
- **Every image carries its ancestry annotation** (`org.kataglyphis.parent-digest`), which lets
  `--verify-chain` answer FRESH/STALE instead of guessing from timestamps.
- **A partial run asserts its ancestors before building** and REFUSES a stale one.
  `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0` is a deliberate override, not a workaround to
  reach for.

How the handoff is built, why the digest pin is load-bearing, and the stale-base propagation trap:
[`linux-cross-builds.md` § Why the handoff must be pinned by digest](docs/linux-cross-builds.md#why-the-handoff-must-be-pinned-by-digest).

## Five Critical Fixes To Maintain

Always preserve these. Canonical reference: `docs/linux-cross-builds.md` § "Five Critical Fixes";
CI validates them through `linux/scripts/verify-critical-fixes.sh`.

## Linux Build Rules

- Use `nerdctl` first on this host; `buildctl`/`ctr` commonly fail with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working.
- `build-cross-compiler.sh` builds one `linux/amd64` compiler image with cross toolchains for all
  arches, not a multi-arch compiler manifest.
- Never remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images
  must keep the source-built clang at `LLVM_RELEASE` (currently 23.1.3), not the Ubuntu distro
  clang. Source-built GCC (`GCC_VERSION`, currently 16.2.0) at `/opt/gcc-${GCC_VERSION}` is the
  default `cc`/`c++` on all arches; on `arm64`/`riscv64` it is cross-compiled (Canadian cross) and
  swapped in at the Android stage via `Dockerfile.android`.
- **The Canadian native GCC builds libsanitizer (host == target); never trim `build-gcc.sh`'s
  target list back to libgcc/libstdc++/libatomic.** The swap and the wrapper smoke fail an image
  without it:
  [`cross-build-verification.md`](docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer).
- **Supply-chain discipline.** Every network fetch is verified: `download_verified_file` is the
  default, `download_file` needs a reason, and the sha256 sits in `versions.env`. Python BUILD
  EXECUTORS (anything that runs code at build time or rewrites shipped binaries) are pinned
  through the `PY_*_VERSION` family and bumped together, deliberately, with a real build; never
  let an install site float back to `-U pkg`. Never `curl | sh`: clone at a tag with
  `--depth 1 --branch` and hard-fail on a missing tag rather than fall back to a branch.
- Keep the optional runtime payloads and LLVM normalization in `Dockerfile.package`: never drop
  `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or the
  `/usr/local/llvm-target` handling.
- **A miss reported by `install_target_packages` is not automatically an outage.** It prints the
  same line whether or not the caller guarded it, so read the CALL SITE before escalating: guarded
  is information, unguarded means the stage is genuinely short a library.
- **Our source-built prefixes must WIN the include path.** A later stage that installs a distro
  `-dev` package puts its headers on the same search path; a distro FFmpeg once displaced ours and
  killed a videoio build with an undeclared symbol. Put `-I${PREFIX}/include` ahead of the
  multiarch `-idirafter`/`-isystem` entries rather than trust the generator's ordering. The same
  class bites package NAMES across an Ubuntu release, and failed on one arch while passing on
  another in the same run: a green arch is no evidence for the others.
- **The arm64 GPU lane is SBSA CUDA: one image for Arm servers and Jetson.** Build with the
  image's GCC 16 (`NVCC_PREPEND_FLAGS=-allow-unsupported-compiler`), never a downgraded
  `CUDAHOSTCXX`, and keep `87` (Orin) in `CUDA_ARCHITECTURES` (ascending for readability only;
  nothing depends on the order since 2026-09-23). The chain's `gpu` stage cannot push from an
  arm64 build platform (the shared sdk is the amd64 lane's), so on the Jetson the lane stays
  `--no-push` and the layer is handed on by hand:
  [`linux-accelerator-images.md` § NVIDIA on arm64 (SBSA)](docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson).
- **Never give one nerdctl build two `oci-layout://` contexts.** nerdctl maps them onto one store
  id and one becomes unresolvable:
  [`failure-modes.md`](docs/failure-modes.md#a-no-push-wrapper-build-cannot-find-its-own-android-image).
- **riscv64 self-builds `onnxruntime-genai`** (GEN1); never re-add an arch guard.
  `GENAI_ALLOW_RISCV64=false` backs it out. What is proven, and the one caveat that is not (real
  silicon): [`gen1-riscv64-genai.md`](docs/gen1-riscv64-genai.md).
- **Feature parity has exactly TWO documented exemptions**, both riscv64: `cmake` (Kitware
  publishes no riscv64 archive) and `iree_base_compiler` (the IREE compiler cannot be
  cross-built). `_parity_exempt` in `06-packaging/smoke-runtime-image.sh` is the source of truth:
  record a new exception THERE, never in prose; the gate fails an exemption that no longer
  applies. The ORT flavour split and arm64-only QNN are deliberate, not gaps.
- **riscv64 builds WITH the vector extension**, set through `--with-arch` in
  `02-toolchain/build-gcc.sh`, never as a `CFLAGS` export: `-march` alone reaches neither OpenCV
  nor ORT nor Rust, each of which has its own switch. Do not "restore compatibility" by reverting
  it: an rv64gc-only board cannot run this image anyway, and changing it invalidates the warm
  riscv64 compiler cache. The ISA string, and why the profile NAME does not work:
  [`riscv64-rva23-baseline.md`](docs/riscv64-rva23-baseline.md).
- **riscv64's web-lane tools have two build paths; keep both** (owner decision 2026-09-23). By
  default android cross-builds `wasm-pack` and `flutter_rust_bridge_codegen`, and the package
  stage installs them after a fail-loud gate; `WEB_LANE_TOOLS_SOURCE=native` (plus
  `WEB_LANE_TOOLS_CACHE=refresh` for a fresh compile) is the gated in-stage native build, and
  `legacy` is the pre-2026-09-23 build verbatim. Never remove either, never let `legacy` drift
  from the old command, and never soften the gate on a binary that claims to be good:
  [`consumer-image-contract.md`](docs/consumer-image-contract.md#building-the-web-lane-tools-from-source).
- **The wrapper's `/opt/wheels` has two deliveries; keep both** (owner decision 2026-09-24).
  `RUNTIME_WHEELS_SOURCE=image` (what `auto`, the default, means today) mounts the android image
  as every published image did; `export` stages that image's wheelhouse, sealed, before each
  package build. Never add a fallback between them, and keep their logic in
  `linux/scripts/lib-runtime-wheels.sh`, outside every image closure, so a change there re-keys
  nothing. `export` refuses a `--no-push` chain whose android tag is published (every one on the
  amd64 cross host); never "fix" that by re-exporting the layout, since changing the ref it reads
  is the owner's call:
  [`linux-cross-builds.md`](docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).
- **The Hailo build has two switches; keep both** (2026-09-24). `HAILO_NESTED_CACHE=carry`
  (default) carries the compiler cache into the protobuf build HailoRT runs under `env -i`, and
  fails a `carry` build the cache did not reach; `off` is the old uncached build.
  `HAILO_PYHAILORT_IPO=off` (default) patches out upstream's forced LTO, so pyhailort is a real
  module, checked on the wheel and on `/opt/venv`, where a failed install or a missing wheel is
  fatal too; `upstream` is the old empty module, and warns. Never soften either check under its
  default, and keep the code in `03-media/build/hailo/`, outside `01-core`, so a change there
  re-keys only the wrapper's Hailo RUN:
  [`hailo-support.md`](docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches).
- **DeepStream is nvidia-variant only, and on in every amd64 nvidia build** (`ENABLE_DEEPSTREAM`,
  CON42; owner 2026-10-07, at full size). `ENABLE_DEEPSTREAM=false` opts one run out, an arm64
  nvidia build gets no default (no route, phase 7), and a default or rocm chain refuses it. The
  owner allowed publishing it (2026-10-01); the package stage ships its runtime `.so` files
  without the static archives. Never put `/opt/nvidia/deepstream/deepstream-*/lib` on
  `ld.so.conf`: its `libnvv4l2.so` carries the SONAME `libv4l2.so.0`. Its TensorRT is a private
  10.x beside the variant's 11.x, and no process may hold TensorRT 11 in its global symbol scope
  while it runs `nvinfer`:
  [`linux-accelerator-images.md` § DeepStream](docs/linux-accelerator-images.md#deepstream-nvidia-variant).
- **TensorRT 11 is on in every amd64 nvidia build** (`ENABLE_TENSORRT`, CON31; owner 2026-10-20),
  at exactly `TENSORRT_VERSION`-1+cuda`TENSORRT_LINUX_CUDA` from NVIDIA's apt repo. Every published
  image ships only TensorRT's runtime `.so`/`.dll` files, DeepStream's 10.x and the Windows lane's
  included (owner 2026-10-21): headers, dev links, `trtexec` and bindings serve build stages, and the
  gates fail an image that carries one. Never install the
  `tensorrt*` metapackages (the 1.9 GB Windows builder resource) and never ask GenAI for
  `--use_trt_rtx` (TensorRT-RTX, not TensorRT):
  [`linux-accelerator-images.md` § TensorRT 11](docs/linux-accelerator-images.md#tensorrt-11).
- **The image's Chrome starts through `/usr/local/bin/chrome`; its emulator is amd64-only**
  (CON50). `CHROME_EXECUTABLE` names that wrapper, which adds `--no-sandbox --no-zygote`: never
  point it at the binary, and never ship a setuid sandbox helper. Keep the emulator's system image
  at an API whose ARM translator runs arm64 apps (35; 30 SIGILLs):
  [`consumer-image-contract.md`](docs/consumer-image-contract.md#browser-tests-run-in-chrome-for-testing).
- **Nothing under `/opt` or `/usr/local` may need `libunwind.so.8`** (owner decision 2026-10-01:
  every variant). GStreamer core and libcamera build with `libunwind=disabled`: a C host that
  loads either first turns a C++ exception through `std::call_once` into a segfault.
  `libunwind-dev` stays installed, so the flags are the guard: never set them back to `auto` for
  backtraces. The runtime smoke fails a shipped file that needs it:
  [`failure-modes.md`](docs/failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind).
- **ONNX Runtime has exactly one source on both lanes: the chain build** (owner rule 2026-09-23,
  no exceptions). On Linux that is `/usr/local/lib/onnxruntime-cpu` on every variant, plus
  `/usr/local/lib/onnxruntime-gpu` on the GPU variants, and its wheel:
  - OpenCV, FFmpeg, gst-plugins-bad's `onnx` plugin and GenAI fail their build unless they
    resolve the chain, and each ends in `ort_assert_chain_only` (`03-media/ort-provenance.sh`,
    mounted per file, never under `core/` or `runtime/`).
  - `/opt/opencv5/lib/libonnxruntime*` are links into the chain, never copies. The chain's conf is
    `000-onnxruntime.conf`. No apt package may provide ORT, and the soname deny is in code: never
    map a `libonnxruntime*` soname to a distro package.
  - The app venv's ORT is the chain wheel byte for byte (`ort-venv-census.py`); a missing chain
    wheel fails the torch stage, with no PyPI fallback.
  - Linux app bundles exclude PyPI ORT providers before exporting the lock and pass the chain
    wheel to the first requirements install; a later replacement cannot rescue a failed resolver.
  - The census's ORT fingerprint is a whole NUL-terminated `__FILE__` source path, never the bare
    `onnxruntime/core/` directory: consumers name that directory as data (OxidANT's loader,
    FFmpeg's configure line) and must stay importers. A file that DEFINES `OrtGetApiBase` (ELF
    dynamic symbol, PE export) is ORT under any name.
  - The image census (SHIPPED-TRUTH E) and `verify-critical-fixes.sh` fix11 enforce it. Every
    consumer, guard and gap: [`onnxruntime-single-source.md`](docs/onnxruntime-single-source.md);
    the Windows rule:
    [`windows-build-invariants.md`](docs/windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23).

- **riscv64's Python lane gets a uv cache seed, not a wheel store** (CON83). `/opt/uv-cache-seed`
  (`PYTHON_UV_CACHE_SEED`) is a uv cache of the wheels the app lock's `test` extra builds from
  source, on `X.Y` and on `X.Yt` (CON110), which `ci_tests.sh` copies into its own cache. A locked `uv sync` takes a built sdist
  from the cache only, so never turn it into a `--find-links` store, and never prove it with
  `--no-build`, which refuses every sdist, cached or not. The torch stage also installs shellcheck
  and hadolint at their `tool-pins.env` pins on every arch; riscv64's hadolint is a source build
  in its own stage:
  [`consumer-image-contract.md` § The riscv64 uv cache seed](docs/consumer-image-contract.md#the-riscv64-uv-cache-seed).

- **A native media wheel whose own code declares free-threading ships a proved `cp3XYt` twin, in
  `/opt/wheels-free-threaded` and never in `/opt/wheels`** (owner request 2026-10-07).
  `03-media/free-threaded-twins.txt` decides, row by row against a `versions.env` pin, so a bump
  re-reads the evidence; it is the one table both lanes read (`ft_wheel_table`, Windows'
  `Get-FreeThreadedTwinTable`), so never copy a row into either reader. A wheel the table does not
  classify fails a native media build. `verify-wheels.sh` is ABI-exact on both stores. Never
  install a twin into a GIL venv, and keep the library and its table mounted per file, outside
  `01-core` and `runtime/`:
  [`consumer-image-contract.md` § The free-threaded wheels](docs/consumer-image-contract.md#the-free-threaded-wheels).

## Dockerfile.media BuildKit Strategy

The media stage fans out into parallel branches and merges them, so a change that serialises the
fan-out or widens a branch's mount costs hours per run. Read the strategy before editing that
Dockerfile: [`linux-accelerator-images.md`](docs/linux-accelerator-images.md) and
[`build-parallelism-memory-tuning.md`](docs/build-parallelism-memory-tuning.md).

## Push And Publish Rules

- **A red `develop` is fixed before anything else lands on it** (2026-10-20). Before every push in
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
- **The manifest lane REFUSES to shrink an already-published index.**
  `_manifest_completeness_gate` in `build-runtime-manifest.sh` compares the arch count of the live
  tag with the arches this run carries and stops. The older coherence gate only asks whether the
  arches AGREE on a generation, so a single-arch run assembled a coherent ONE-arch index and
  published it: that is how `:latest` (then `:latest-cross`) was found reduced to riscv64 alone.
  Recover by re-running the runtime lane for the missing arches. `--force` and
  `RUNTIME_MANIFEST_COMPLETENESS=0` only bypass the early shell check: final promotion
  still preserves the published runtime platforms. A partial-arch run should carry
  `--skip-manifest`; a different platform set gets its own tag.
- **A published image's environment names nothing outside the container** (2026-09-23, both
  lanes). A build-host setting (the sccache endpoint, a LAN mirror, a proxy) reaches a RUN as an
  ARG and never lands in an ENV: `:winamd64` shipped the owner's LAN WebDAV and broke every
  consumer's sccache. Three gates hold it, none with a skip switch: the static pass in
  `lint-dockerfiles.sh`; Windows' `Dockerfile.publish-gate`, solved on every parent a run inherits
  but did not build, on the fresh toolchain, and on the final image before any export or push
  (`-SkipSmokeGate` skips none of them); and `build-runtime-manifest.sh`'s image-env gate, first
  in `create_manifest` on every path, `--manifest-only` included. **Cross such a fix by restarting
  a chain, never by resuming one**: a driver started before it has no gate, and a parent built
  before it still carries the leak. Why, and what the gates cannot see:
  [`windows-build-resources.md` § What the published image carries](docs/windows-build-resources.md#what-the-published-image-carries).

## Validation

- **Four places run the gates, deliberately not the same set.**

  | when | what runs | cost |
  | --- | --- | --- |
  | every `git commit` | `linux/host-config/git-hooks/pre-commit` — the 20 cheap whole-tree slugs, `shellcheck` + the warning ratchet on STAGED shell, the doc gates only when `docs/` is staged, the derived doc numbers when a page that quotes them is staged, and the mutation gate on at most `PRECOMMIT_MUTATION_CAP` (default 16) staged entries, newest first | **8.0 s** one-file, **27.2 s** for a 43-file commit (measured 2026-09-04) |
  | every `git push` | `linux/host-config/git-hooks/pre-push` — the mutation gate's `--stale-check` over the whole manifest, then `--changed` for real ([`code-quality-tooling.md` § The pre-push hook](docs/code-quality-tooling.md#the-pre-push-hook)) | the staleness pass: 0.06 s over 378 entries (measured 2026-09-05); `--changed` depends on the push |
  | before a rebuild, by hand | `make preflight` — all slugs | minutes (the secret scan alone is ~170 s) |
  | every push | `.github/workflows/linux-x64.yml` — `preflight.sh` with `PREFLIGHT_SKIP=mutations`, plus the `mutations` slug as eight `PREFLIGHT_MUTATION_SHARD=K/8` jobs that together prove every entry | CI |

  Install the hooks once with **`make hooks`**: it sets `core.hooksPath` rather than copying into
  `.git/hooks`, so both hooks are version-controlled and arrive with a clone.
  `git commit --no-verify` bypasses the commit hook; then run `make preflight` before pushing.

  The hook is a SUBSET and its mutation step a SAMPLE on purpose: a pre-commit gate that takes
  minutes teaches everyone to type `--no-verify`. A sample never reports as full coverage; it
  prints how many of how many it ran. Why it is capped, and what it measured before:
  [`code-quality-tooling.md` § The pre-commit hook's cost budget](docs/code-quality-tooling.md#the-pre-commit-hooks-cost-budget).

  CI never samples: its eight `mutations` jobs split the manifest with `--shard` and together prove
  every entry. When the gate gets slow, fix the suite that got slow; never raise a timeout or
  sample in CI. The 2026-09-23 timeout and the layout:
  [`code-quality-tooling.md` § The mutation gate in CI, sharded](docs/code-quality-tooling.md#the-mutation-gate-in-ci-sharded).

- **Never retype a number a gate can measure.** Manifest sizes, per-prefix mutation counts and the
  hook's own slug list are pinned by `tests/test-doc-numbers.sh`, which reads them out of
  `mutations.json` and the hook and fails on drift (`--update` rewrites the pages). Wall-clock
  figures cannot be pinned: write them with the date they were measured, or leave the digit out.

- **`bash linux/scripts/preflight.sh` is the single source of the no-build gate list.** The
  inventory is its `KNOWN_SLUGS` array; do NOT enumerate it here (this paragraph once went stale
  by three slugs). `tests/test-preflight-slugs.sh` enforces that every slug has a registered check
  and vice versa. The commit hook runs a subset through `PREFLIGHT_ONLY` / `PREFLIGHT_SKIP`; never
  copy the check list into a new caller. On a Windows host:
  `PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh`. What each gate
  proves, and its allowlist: [`code-quality-gates.md`](docs/code-quality-gates.md) (generated) and
  [`code-quality-tooling.md`](docs/code-quality-tooling.md). Slugs, suites and shellcheck runs go
  side by side; `PREFLIGHT_JOBS=1`, `RUN_TESTS_JOBS=1` and `LINT_SHELL_JOBS=1` run them in turn
  ([§ The gates run side by side](docs/code-quality-tooling.md#the-gates-run-side-by-side)).

- **Linux host config is code.** `linux/host-config/` carries the canonical rootless-BuildKit
  `buildkitd.toml` and the systemd drop-in; `apply-host-config.sh` installs and
  `verify-host-config.sh` warn-diffs live vs repo. Reconcile drift through the repo, never by
  editing `~/.config` alone: a live-only toml edit silently regressed once.

- **Linux disk reclaim: `linux/host-config/prune-safe.sh`, NEVER `nerdctl builder prune -f`**, and
  `nerdctl system prune` / `nerdctl builder prune` are not steps on the list at all. The `-f`
  prune deletes `type==exec.cachemount` records (hours of compile time) together with the cheap
  layer cache. The measurements, the mid-run lever ORDER and the third cache store
  `prune-safe.sh` cannot reach:
  [`linux-host-setup.md` § B7](docs/linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches).

- **Host toolchain: install from the nerdctl-full bundle, and on a rootless-only host into
  `$HOME/.local`.** There is no separate buildkit package, so bumping buildkitd means installing
  a newer bundle; `linux/host-config/install-nerdctl-full.sh` dry-runs by default, verifies the
  release SHA256, backs up what it replaces (`--rollback`), refuses while a build runs, and counts
  BuildKit cache-mount records before and after.
  [`linux-host-setup.md` § B3b](docs/linux-host-setup.md#b3b-install-or-upgrade-nerdctl-full)
  and [§ B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).

- **riscv64 host tooling** needs more than the amd64 one-liner (no riscv64 wheels, so uv builds
  from source; the native RVA23 triple; an apt step that needs interactive sudo):
  [`linux-host-setup.md` § D4](docs/linux-host-setup.md#d4-python-cli-tools-that-build-from-source-on-riscv64).

- **ghcr REGISTRY hygiene: two tools over `ghcr-common.sh` and `ghcr_metadata.py`, and NEVER "delete all untagged" by
  hand.** `ghcr-prune-package.sh` deletes UNTAGGED versions; `ghcr-delete-tags.sh` deletes NAMED
  tags from an explicit list and never guesses what is legacy. The per-arch entries of a
  multi-arch index are themselves untagged manifests, and a pushing chain creates untagged
  manifests seconds before tagging them. Both dry-run by default. The keep-set rule, the one
  Accept header that makes it a safety property, and the run numbers:
  [`linux-host-setup.md` § B8](docs/linux-host-setup.md#b8-ghcr-registry-hygiene).

- **HOST DISK RECLAIM IS ALLOW-LISTED AND DEFAULT-DRY —
  `windows/scripts/host/Clear-DiskSpace.ps1`, and NOTHING ad hoc** (2026-08-21, the worst
  incident this repo has produced: a "let's free some space" command composed on the spot walked
  into the installed programs and the user profile and took the host with it). The rules, all
  permanent:
  - **The reclaim script is the only sanctioned path.** It resolves candidates from an ALLOWLIST,
    reports by default, needs `-Apply`, age-gates every live-directory rule, and aborts the WHOLE
    run if any candidate lands on a protected root: such a candidate means the resolution logic is
    wrong and the rest of the plan is untrustworthy too.
  - **A name is not a target.** A candidate containing a junction or symlink is skipped: a reparse
    point is where a name stops predicting what a recursive delete reaches.
  - **The compile caches are NOT cleanup targets.** sccache/ccache/cargo/uv read as "cache" and are
    the most expensive bytes on the disk.
  - **Daemon levers before filesystem levers, always.** `buildctl prune --free-storage`,
    `docker image prune`, the store-GC sequence in
    [`windows-build-lanes.md` § Store GC](docs/windows-build-lanes.md). Filesystem reclaim is a
    last resort limited to dead `*.bak-<stamp>` husks.
  - **Protected roots are OFF LIMITS to the agent, permanently**: `C:\Program Files`,
    `C:\Program Files (x86)`, `C:\Windows`, `C:\ProgramData` outside the container stores, any
    user profile under `C:\Users`, `AppData`, per-user tool directories (`.vscode`, `.ssh`,
    `scoop`, `.claude`), drive roots, and every installed-package or driver store. Not with a
    flag, not with a force switch, not "just this once". Space that only comes back by reaching in
    there is a reinstall, not a cleanup, and it is the user's call, run by the user.
  - **Uninstalling the user's software is never the agent's move.** No package manager, MSI or
    appx removals. Suggest, never do.
  - **The gate is mechanical, not advisory.** `.claude/hooks/guard-destructive-deletes.ps1` runs
    as a `PreToolUse` hook, in a Python and a PowerShell implementation so it fires on a host with
    no `pwsh`. It DENIES (a decision no prompt can override) any command touching a protected
    root, and it scans file CONTENT on Write/Edit too, because the 2026-08-21 vector was a script
    written for the user to paste, not a command the agent ran.
    `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1` is the incident in executable form.
    Relaxing a guard regex is a reviewed repo change with a test, never a bypass in the moment.

- **PowerShell gate:** `pwsh -File windows/scripts/Invoke-Lint.ps1` +
  `pwsh -File windows/scripts/tests/Invoke-Tests.ps1` (CI: `.github/workflows/windows-x64.yml`).
  The suite guards *classes* of defect, not instances: when you fix a bug here, prefer a guard for
  its class. Which classes, and why the linter exits 2 for an infrastructure failure:
  [`windows-builds.md`](docs/windows-builds.md).

- **Runtime verification happens inside a container, or against raw symlink targets.** Never use
  `readlink -f` against `out/linux-runtime/*/rootfs`: absolute symlinks resolve against the host
  root. Confirm on all arches that `clang --version` reports `LLVM_RELEASE`, `cc -dumpmachine`
  matches the arch, `gcc --version` reports the pinned GCC, and the `cc/c++/gcc/g++` and `clang`
  symlinks point into `/opt/gcc-*/bin` and `/usr/local/llvm-target/bin`.

- **The `wrapper-smoke` target in `Dockerfile.package` is a MANDATORY gate** in
  `runtime_build_chain()`: it builds after the package stage, reusing cached package layers, beside
  the wrapper build, and nothing of the arch is pushed or exported before it passes
  (`RUNTIME_SMOKE_OVERLAP=0` runs it first). `WRAPPER_SMOKE_GATE=0` skips it;
  `test-runtime-smoke-gate.sh` pins that it runs, `test-runtime-smoke-overlap.sh` that it gates.

## Dependency Updates

The rules; the mechanism is documented once in
[`dependency-updates.md`](docs/dependency-updates.md).

- **Upgrades are driven by Renovate run as a LOCAL CLI, in every repo of the family** (owner
  directive 2026-09-09), not by hand and not by waiting for a bot. The GitHub App is installed
  nowhere here and will not be: this is the permanent mechanism, not a stopgap.
- **A run REPORTS. `--apply` only when the owner asked for it in that turn** (owner directive
  2026-09-11). `linux/scripts/renovate-local.sh .` reports; `--apply --dry-run` prints the plan;
  `--apply` writes gitlinks, manifests and locks, for every ecosystem the repo has.
- **A bare `git submodule update --remote` is forbidden in this family.** For a submodule that
  declares no `branch =` it does not skip: it walks the pin to the remote's DEFAULT branch.
  `--apply` passes explicit paths, takes only submodules that declare a branch, and never uses
  `--recursive`.
- **`linux/scripts/git-sync-branches.sh` is not that command.** It puts working trees on their
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
  repository.** A literal anywhere else is a second source that will disagree; the ARG-consistency
  and advertised-key gates exist because it did.
- **Host-tool pins go in `01-core/tool-pins.env` instead** (CON59, 2026-10-05): shellcheck,
  gitleaks, hadolint, actionlint, mold, binaryen, ruff, syft, Renovate, dartdoc. `Dockerfile.base`
  bind-mounts `versions.env`, so any edit to it rebuilds the compiler image, even for a lint tool.
  A pin no early stage (base through android) reads goes in `tool-pins.env`; one such a stage
  reads stays in `versions.env`. The torch stage reads shellcheck's and hadolint's from
  `tool-pins.env` (CON83). Renovate, `bump_versions.py` and `sync_versions.py` read both files.
- **Dart API docs use the separately pinned generator.** The shared builder resolves it into
  the project's isolated `.dart_tool/dartdoc-tool` cache; keep redundant `dart doc` overrides
  out of consumers. Explicit custom commands still win. The SDK-bundled tool can lag fixes;
  see [the generator contract](docs/shared-script-libraries.md#the-api-generator).
- **Never hand-edit a derived file.** `python docs/scripts/sync_versions.py --write` propagates a
  pin into the docs, the deps table, the Dockerfile ARGs and the PowerShell defaults; `--check` is
  a preflight gate, so a hand edit is caught rather than shipped.
- **A version with a checksum moves with its checksum.** `bump_versions.py` owns those pairs: a
  pin updated without its digest is an unverified download that still looks pinned.

Key layout, coupled pairs and report tiers: [`dependency-updates.md`](docs/dependency-updates.md)
and [`cross-build-verification.md`](docs/cross-build-verification.md#per-arch-version-truth).

## Development Rules

- Every script starts with `#!/usr/bin/env bash`. `set -euo pipefail` is for **entry points**
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

**Write docs like a developer: short and precise** (owner, 2026-10-19). Say what a thing does,
how to run it and what breaks; no filler, no marketing, no repetition.

- **[`docs/INDEX.md`](docs/INDEX.md) decides which page owns which topic.** Add a row when you add
  a page; the `doc-links` gate fails a page that no row and no toctree entry names.
- **The docs gates run over this tree, not over a guess.** `doc-links` checks every
  cross-reference and every `docs/*.md` pointer in code; `doc-dupes` catches a passage reworded
  into a second page. Budgets live in `docs/scripts/*.allow` with a reason, and a stale row fails.
- **A consumer page that restates a hub page fails too**, once the consumer seeds
  `doc-dupes-hub.allow`: `doc-dupes --against-hub` in `run-lint-gates.sh --ratchets`
  ([`code-quality-tooling.md`](docs/code-quality-tooling.md#consumer-pages-against-the-hub-doc-dupes---against-hub)).
- **A README is an overview, in this repo and every consumer.** Procedures go to `docs/`,
  family-wide facts to this hub, and the README links to both:
  [`docs/repository-family.md` § The README rule](docs/repository-family.md#the-readme-rule). The
  `readme-length` gate fails a root README over 100 lines, here and through `run-lint-gates.sh` in
  every consumer.
- **The theme and the brand belong to DocumANTation.** Change `custom.css` there, not here.

How each gate decides, and what its allowlist means:
[`code-quality-tooling.md`](docs/code-quality-tooling.md).
