# Adopting ANTfrastructure in a New Project

This repo is not only a set of Dockerfiles. It ships the build/run/automation
tooling that consuming projects import instead of copying: Windows container
builds (Stevedore), Linux container builds (Rancher Desktop / CI), the
planner–executor agentic loop, reusable PowerShell modules and bash libraries,
and CI composite actions.

This page is the checklist for wiring a **new** project to all of it.
BeschleunigerBallett is the reference consumer — when a detail here
is ambiguous, read how that repo does it.

## 0. Add the submodule

```bash
git submodule add https://github.com/Kataglyphis/ANTfrastructure.git third_party/ANTfrastructure
git submodule update --init --recursive
```

Everything below assumes that path. Consumers pin a commit like any other
submodule; bump the pin and the consuming change in the same commit, and push
ANTfrastructure `main` **before** the consumer, because CI resolves composite
actions at `@main`.

## Submodule maintenance

### Bumping the pin

```bash
git submodule update --remote --merge --recursive
```

Commit the resulting pointer change together with the consuming change, and push
ANTfrastructure `main` **first** — CI resolves composite actions at `@main`.

### Resolving a submodule conflict on merge

Merges that touch the pin from both sides leave `third_party/` paths unmerged,
and `git checkout --theirs` alone does not resolve them: the conflict is over
*which commit the superproject records*, not over file contents.

The situation this arises in: two branches whose histories diverged far enough
that you want one side wholesale. Set the merge up so it stages nothing
automatically, then resolve:

```bash
git fetch origin
git checkout main
git reset --hard origin/main

# take develop's content, but stop before committing
git merge --allow-unrelated-histories --no-commit -X theirs develop
```

```bash
# what is actually unmerged
git diff --name-only --diff-filter=U

# take the incoming side's commit for every conflicted submodule
for p in $(git diff --name-only --diff-filter=U | grep '^third_party/' || true); do
  echo "Resolving submodule conflict: $p"
  git submodule update --init --recursive "$p" || true
  git checkout --theirs -- "$p"
  git add "$p"
done

# then the ordinary file conflicts
git checkout --theirs -- .
git add -A
git commit

# and materialize the commits that were just recorded
git submodule update --init --recursive
```

Run `git submodule update --init --recursive` **after** committing as well as
before. Staging the pointer does not check the submodule out at that commit, so
skipping it leaves a working tree that does not match what you just recorded.

> `-X theirs` on the merge itself resolves file contents but still leaves
> submodule pointers conflicted. The loop above is the part that is easy to
> forget, and the resulting "resolved" merge silently pins the wrong commit.

### Recovering a broken submodule checkout

When a clone left submodules half-initialised — wrong commit, empty directory,
or a `.git` file pointing nowhere — reset them rather than deleting the tree:

```bash
git submodule deinit -f --all
git submodule update --init --recursive
```

`deinit -f` discards local submodule working trees, so commit or stash anything
inside them first.

### Long paths (Windows consumers)

This repo's nesting plus a deep build directory exceeds `MAX_PATH` quickly.
Beyond the host-level `LongPathsEnabled` setting in
[`windows-host-setup.md`](windows-host-setup.md), git needs telling separately:

```bash
git config --global core.longpaths true
```

Without it, clone or checkout fails with `Filename too long` on files that are
perfectly legal for the filesystem.

### Resetting to a clean tree

```bash
git clean -fdx
git reset --hard
```

`-x` also removes ignored files — build outputs, `.venv`, cached toolchains.
That is usually the point, but it means a rebuild from cold.

### `git pull` hanging in PowerShell

An SSH remote needs the agent running as a Windows service; without it the
client waits on a passphrase prompt nothing is displaying:

```powershell
Start-Service ssh-agent
ssh-add "$env:USERPROFILE\.ssh\id_ed25519"
```

`Set-Service -Name ssh-agent -StartupType Automatic` makes it stick.

### Shallow fetches

Full history of every submodule is rarely needed on a build agent:

```bash
git fetch --depth=1 origin <branch>
git reset --hard FETCH_HEAD
```

## 1. The one file that cannot live here

Each consumer needs a tiny bootstrap that *finds* this submodule, since it runs
before anything upstream is importable. Copy
[`shared/windows/templates/Resolve-BuildModule.ps1`](../shared/windows/templates/README.md)
to `scripts/windows/Resolve-BuildModule.ps1` and adjust
`$script:RepoRootRelativeToHere` if the script does not sit exactly two
directories below the repo root. It resolves a module
name to
`third_party/ANTfrastructure/windows/scripts/modules/<Name>.psm1`
first, then a local `modules/` fallback beside itself, and throws with both
paths if neither exists.

Copy the template, do not re-author it. All four consumers had written this
file independently and they had drifted — different search orders, different
error text, one missing `-Global` on the import.

That preference order is the whole contract: **put reusable modules upstream
and they win automatically**; keep only genuinely project-specific modules in
the local fallback directory. If a second consumer needs it, it belongs here
instead — that test is what moved `WindowsTesting.Common` and
`WindowsClang.Common` upstream on 2026-08-11.

Bash consumers have the same problem and the same answer: copy
[`shared/linux/templates/antfrastructure.sh`](../shared/linux/templates/README.md)
to `scripts/linux/lib/antfrastructure.sh` (or `scripts/lib/` in a flat Flutter
repo), adjust `KATAGLYPHIS_REPO_ROOT_RELATIVE`, and declare it as
`antfrastructure-sh` in `.antfrastructure-shared.manifest` so the drift gate
watches it. It resolves paths from `${BASH_SOURCE[0]}`, never from the caller's
working directory, and its failure message names the fix.

**A consumer with no submodule is supported.** The bootstrap takes
`$ANTFRASTRUCTURE_DIR` first (a container mounts the workspace somewhere else
than the host, so an explicit answer always wins), then
`third_party/ANTfrastructure`, then a plain sibling clone at
`<repo>/antfrastructure-tools`. Its error text follows the same fact: it offers
`git submodule update` only when `.gitmodules` actually names that path, and
otherwise tells you to clone or to export `ANTFRASTRUCTURE_DIR`.

## 2. Windows container builds (Stevedore)

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (clang-cl,
CMake, Ninja, Vulkan SDK, Rust, sccache preinstalled).

Import `WindowsContainerBuild.Reuse` through the resolver and build on its
functions rather than re-implementing the pattern:

| Function | Purpose |
|---|---|
| `Resolve-DockerExe` | Find Stevedore's `docker.exe` (nerdctl is not viable on Windows) |
| `Get-ContainerIsolationArgs` | Process vs Hyper-V isolation, CPU/memory args |
| `Get-ReusableBuildContainer` | Reuse/start/recreate one long-lived build container; recreates on image change |
| `Copy-IntoBuildContainer` / `Copy-FromBuildContainer` | tar-pipe transfers with mandatory exclusion support |
| `Initialize-ContainerPwsh` | Ensure PowerShell 7 exists inside the container |
| `Remove-StaleContainerSources` | Prune deleted sources on reuse (tar never deletes) |
| `Test-BuildArtifactsDelivered` | Fail when a "green" build produced or delivered nothing |
| `Test-ContainerBindMount` / `Remove-BuildContainerSafe` | Bind-mount probe; wcifs-tolerant removal |
| `Wait-ContainerExit` | Trust the container's state, not the docker client's exit code, when the CLI drops its pipe mid-run (needs a named run, never `--rm`) |

Read [`windows-container-build-performance.md`](windows-container-build-performance.md)
before designing your flow — it documents both transports and their setup, why
the build tree must not live on a named volume, the Windows path limit that
silently truncates tar transfers, and the container-reuse measurements.

Three rules that cost real debugging time to learn:

- **Mount/stream to the same in-container path under every transport.** CMake
  bakes absolute paths into `CMakeCache.txt` and rejects a cache generated
  elsewhere.
- **A green build is not proof of delivery.** Always end with
  `Test-BuildArtifactsDelivered`; both "built nothing" and "delivered nothing"
  have happened silently.
- **A red docker client is not proof of failure.** The CLI drops its pipe
  mid-run on this host while the container keeps building. Name the run, leave
  `--rm` off, and take the verdict from `Wait-ContainerExit`.

## 3. Linux container builds (Rancher Desktop / CI)

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`.

Local runs go through one driver, so the image tag, the mount layout, the git
safe.directory and the Git Bash path-mangling escape are answered in one place
rather than re-typed per repo:

```bash
bash third_party/ANTfrastructure/linux/scripts/run-in-ci-image.sh . -- \
  bash scripts/linux/cmake-configure-build.sh --preset <preset> \
       --build-dir /tmp/build --cargo-cache-dir /cargo-cache
```

A cargo-cache volume is still yours to create and mount; everything else —
image, mount layout, safe.directory, engine, the Git Bash escape — is the
driver's, and
[`shared-script-libraries.md` § `run-in-ci-image.sh`](shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image)
owns the explanation.

Three constraints worth internalising:

- **The CMake build directory must be container-native** (`/tmp/...`), not on
  the bind-mounted host tree: FetchContent's rename and cargo's temp-file
  cleanup both fail on that filesystem.
- **Persist cargo via a named volume** (`--cargo-cache-dir`), because the
  image's `CARGO_HOME` is root-owned and otherwise gets redirected to a
  container-local path that dies with the container.
- **Never assume a tool is present because it is on your dev box.** `jq`, for
  instance, is *not* in the Linux image; `python3` is. A hard dependency on the
  former silently broke shader precompilation and left CI with no artifacts.

Prefer `linux/scripts/01-core/` helpers (logging, retry, downloads with SHA
verification, uv/python env, parallelism) over new implementations.

## 4. The agentic loop

Reusable core, already written:

- PowerShell: `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`
- Bash: `linux/scripts/lib/agentic-loop.sh`
- Default task prompts: `shared/agentic-loop/prompts/{planner,refactor-planner,executor}.md`
  — the single source both platforms read. Never hard-code prompt text in a
  consumer wrapper; that is precisely how the two platforms drifted apart.

Start from the copy-and-edit templates in
[`shared/agentic-loop/templates/`](../shared/agentic-loop/templates/README.md)
(config with every project-specific field marked `TODO`, plus both runner
wrappers). A consumer supplies four things:

1. **`BACKLOG.md`** with the checkbox protocol: `- [ ]` actionable, `- [b]`
   blocked (skipped, and excluded from the pending count so a blocked-only
   backlog lets the planner run again), `- [x]` completed (pruned; history
   lives in git).
2. **A config JSON.** Shape (see the reference consumer's
   `scripts/agentic-loop/AgenticLoop.config.json`): `engine`, per-engine model
   and prompt settings under `engines.*`, cadences and timeouts under
   `intervals.*`, per-platform `buildMatrix.{windows,linux}` entries
   (`name`/`sanitizer`/`buildDir`/`buildType`/`testCommand`), `build.*`
   commands, `git.*` auto-commit settings, `backlog.*` policy, `logging.logDir`.
3. **Thin runner wrappers** — `Invoke-AgenticLoop.ps1` / `.sh`. These load the
   config, resolve the module/library, and call `Invoke-AgenticLoop` /
   `run_agentic_loop`. Build configs and prompts both default from the config
   and the shared prompt files, so the wrappers stay tiny.
4. **Project role-prompt overlays** — `scripts/agentic-loop/prompts/planner-overlay.md`
   and `executor-overlay.md`, wired via the config's top-level `promptOverlays`
   block. Write only your project's delta. The loop composes
   `shared/agentic-loop/system-prompts/<role>.md` + your overlay once and
   delivers that one text to both engines: to `claude` via
   `--append-system-prompt-file`, and to `opencode` by GENERATING
   `.opencode/agents/<role>.md`, which is its only role-prompt channel. Add
   `.opencode/agents/` to `.gitignore` — the loop warns if you have not. A
   tracked, hand-edited copy of that file is how one consumer ended up with two
   full copies of the role prompt that had drifted 271 lines apart, the stale
   one having lost the executor's incident narrative, its `timeout: 600000`
   guidance and the `- [b]` commit step.

API reference: [`windows-agentic-loop.md`](windows-agentic-loop.md).
Build-matrix semantics and sanitizer env handling:
[`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md).

**Operational lesson worth inheriting:** an autonomous loop does not watch CI,
and it auto-commits with `git add -A`. Expect it to keep committing over a red
pipeline, and do not run interactive work in the same tree without checking
whether the loop is live.

## 5. Application launchers

`linux/scripts/lib/app-runner.sh` provides argument parsing
(`--exe-name/--build-dir/--build-type`), executable discovery with a bounded
fallback search, `LD_LIBRARY_PATH` export, and hooks
(`app_runner_post_vulkan_hook`, `app_runner_env_hook`,
`APP_RUNNER_ENABLE_SHADER_CLEAN`). Consumers keep only per-profile wrappers
holding defaults and hooks.

## 6. CI

Composite actions live in [`.github/actions/`](../.github/actions/README.md)
and are referenced from a consumer workflow as
`Kataglyphis/ANTfrastructure/.github/actions/<name>@main`:

All twelve, with every input and output, are listed once in
[`.github/actions/README.md`](../.github/actions/README.md) — that page is the
list, and a table here would be a second copy of it to keep in sync. They
replace the hand-rolled `docker run` blocks that otherwise accumulate (in the
reference consumer, twenty-plus copies across two workflows), and they include
`deploy-over-ftp`, the one FTP publish policy for the family
([`ftp-deploys.md`](ftp-deploys.md)).

**One ordering rule does not live in that page, because it is about your
workflow rather than about an action:** on a Windows runner, `set-docker-data-root`
runs **FIRST**. It moves docker's data root to the big `D:` drive — the ~54 GB
image does not fit on a stock `windows-2025` runner's `C:`, and a pull without
the move dies late with `hcsshim::ImportLayer 0x70` (measured; see
[windows-build-resources.md](windows-build-resources.md)).

Two lanes are reusable workflows rather than actions: `lint-gates.yml` (the
consumer lint gates, § 9) and `submodule-pins.yml` (the pin suite, § 9), both
called with
`uses: Kataglyphis/ANTfrastructure/.github/workflows/<name>.yml@main`.

Because actions resolve at `@main`, a consumer workflow change that depends on
an action change requires the ANTfrastructure push to land first.

### Workflow file names and display names

Owner decision 2026-09-24, for every repository in the family, this one
included.

- **Files are kebab-case, and a build gets one file per platform and arch:**
  `linux-x64.yml`, `linux-arm64.yml`, `windows-x64.yml`,
  `windows-arm64-cross.yml`, `android.yml`, `web.yml`. A lane every repo has
  carries the same file name everywhere: `lint-gates.yml`, `submodule-pins.yml`,
  `codeql.yml`, `docs.yml`. A reusable workflow that lives in a consumer is
  `reusable-<platform>.yml`.
- **Display names read `<Platform> <Arch> · <what>`** for a build (`Linux x64 ·
  preflight + mutation gate`) and `<Area> · <what>` for anything else (`Docs ·
  stale check`, `GHCR · cleanup`). The separator is U+00B7, the middle dot. The
  shared lanes are `Lint gates`, `Submodule pins`, `CodeQL` and `Docs · …`; a
  consumer's reusable workflow is `<Platform> · reusable build`.
- **This hub's reusable workflows keep their file names.** Every consumer calls
  them as `Kataglyphis/ANTfrastructure/.github/workflows/<file>@main`, so a
  rename breaks the fleet at once. Only their display names changed, and they
  end in `(reusable)`: `Docs · build (reusable)`, `Lint gates (reusable)`,
  `Python CI · Linux (reusable)`, `Python CI · Windows (reusable)`,
  `Submodule pins (reusable)`.
- **Splitting a Python lane per arch** needs no copied job:
  `python-ci-linux.yml`'s `arches` input picks the rows
  ([`python-ci.md`](python-ci.md#one-arch-per-caller-the-arches-input)).

The rename across the fleet, old name to new:

| Repository | Before | After |
|---|---|---|
| ANTfrastructure | `ubuntu26.04.yml` | `linux-x64.yml` |
| ANTfrastructure | `windows-scripts.yml` | `windows-x64.yml` |
| OxidANT | `rust_ubuntu26_04.yml` | `linux-x64.yml` + `linux-arm64.yml` |
| OxidANT | `rust_windows2025.yml` | `windows-x64.yml` |
| AccelerANTgine | `linux_run.yml` | `reusable-linux.yml` |
| AccelerANTgine | `linux_run_x86.yml` | `linux-x64.yml` |
| AccelerANTgine | `linux_run_arm.yml` | `linux-arm64.yml` |
| AccelerANTgine | `windows_run.yml` | `windows-x64.yml` |
| OmniAccelerANT | `dart_on_native_linux.yml` | `linux-x64.yml` + `linux-arm64.yml` |
| OmniAccelerANT | `dart_on_native_windows.yml` | `windows-x64.yml` |
| OmniAccelerANT | `dart_build_android_app.yml` | `android.yml` |
| OmniAccelerANT | `dart_on_web_linux.yml` | `web.yml` |
| BeschleunigerBallett | `Linux.yml` | `reusable-linux.yml` |
| BeschleunigerBallett | `Linux_x86.yml` | `linux-x64.yml` |
| BeschleunigerBallett | `Linux_arm.yml` | `linux-arm64.yml` |
| BeschleunigerBallett | `Windows.yml` | `windows-x64.yml` |
| OrchestrANT, WebDavClient | `windows-2025.yml` | `windows-x64.yml` |
| OrchestrANT, WebDavClient | `ubuntu-26.04-amd64-arm64.yml` | kept until `arches` reaches hub `main`, then `linux-x64.yml` + `linux-arm64.yml` |
| jotrockenmitlocken | `dart.yml` | `web.yml` |
| ANThology | `dart.yml` | `docs.yml` |
| DocumANTation | `docs-pages.yml` | `docs.yml` |

A hub page that cites a consumer workflow with a LINE number from before the
rename (the table in [`ftp-deploys.md`](ftp-deploys.md)) is a dated record and
keeps the old name; this table translates it.

## 7. Certificates / packaging (Windows)

`windows/scripts/certificates/` holds MSIX certificate generation and import
(`README.md` there). The `WindowsMsix.Common`, `WindowsMsix.Signing` and
`WindowsWebDav.Common` modules drive it.

The WebDAV downloader that fetches those signing certificates in CI (rather than
committing them) is **not** Windows-specific and no longer lives there: it is
`linux/scripts/01-core/download-webdav-files.py`, with a shim at the old
`windows/scripts/certificates/download_webdav_files.py` path because the
PowerShell module resolves it relative to itself. A Linux lane calls it through
`webdav_download_tree`
([`shared-script-libraries.md`](shared-script-libraries.md#01-corewebdav-downloadsh)).
Both halves install the client at `WEBDAVCLIENT_REF` from `versions.env`.

## 8. Calling conventions (what every consumer looks like)

Seven repos consume this one. The shapes below are what they converged on;
a new consumer that follows them is immediately legible to anyone who has read
another. Recorded 2026-08-11 after measuring all seven, because until then the
convention was folklore and had drifted.

**Windows entry point** — `<scripts>/windows/Build-Windows.ps1`, PascalCase
`Verb-Noun` like every other PowerShell file. It must:

```powershell
#requires -Version 7.0          # every module here declares it; pwsh, never powershell
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @('WindowsScripts.Shared', 'WindowsBuild.Common', ...)
```

Run the app with a sibling `Start-Windows.ps1`. Project-specific modules go in
`<scripts>/windows/modules/`, which the resolver checks after this repo.

**The verb carries the meaning**, and the family uses three of PowerShell's
approved ones with narrower senses than the approved-verb list gives them:
`Start-` launches the built application, `Invoke-` runs a build step or a tool,
and `Build-` produces artifacts. `Build-Windows.ps1` builds, `Start-Windows.ps1`
runs, `Invoke-Lint.ps1` lints. **PowerShell lives under `scripts/windows/`**
regardless of which lane it drives — a `.ps1` that starts a *Linux* container is
still PowerShell and still belongs there, because the question a reader asks is
"which shell do I need", not "which OS does it target".

**Bash entry points** — `set -euo pipefail`, resolve the script's own directory,
then source a per-repo bridge that pulls in `01-core/common.sh`:

```bash
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/ci_common.sh"          # or lib/common.sh
source "${_SCRIPT_DIR}/../../third_party/ANTfrastructure/linux/scripts/lib/<lib>.sh"
```

Long flags are `--kebab-case value`. A wrapper around one of the `lib/*.sh`
drivers should be ~30 lines: source the library, set the project's defaults,
call its `*_main`. `BeschleunigerBallett/scripts/linux/run-ctest.sh`
is the canonical example.

**Shell safety** — the five bug classes in this repo's `AGENTS.md`
(§ *Shell safety conventions*) apply to consumer scripts too. Every one of them
falsified or killed a real build here; they are not style preferences.

**Directory layout is uniform across the five consumers that have a Windows
lane** (BeschleunigerBallett, OmniAccelerANT, OrchestrANT, AccelerANTgine,
OxidANT; normalised 2026-08-11): lowercase `scripts/`, with `scripts/windows/`,
`scripts/linux/`, `scripts/windows/modules/` and — where the agentic loop is
wired up — `scripts/agentic-loop/`. The two Linux-only Flutter repos
(jotrockenmitlocken, ANThology) keep a flat `scripts/`, with the bootstrap at
`scripts/lib/` and that path declared in `.antfrastructure-shared.manifest`.
Two repos used `Scripts/` + `Scripts/Windows/` until that sweep. Use lowercase
in a new consumer; there is no per-repo casing rule to look up any more.

**Bash filenames still differ**, but not the way this note used to claim.
Measured 2026-09-14: kebab-case everywhere except OrchestrANT, where the four
`ci_*.sh` wrappers mirror the hub's own snake_case drivers under
`linux/scripts/02-toolchain/python/` by name and `benchmarks/run_benchmarks.sh`
kept its name from the hub's llm-stack; its other scripts are kebab. The old
wording said "snake_case in the rest" and was wrong about OxidANT and
AccelerANTgine — both are kebab. That one is
left alone deliberately: unlike a directory rename it buys no structural
consistency, and renaming every script would churn history for a purely lexical
preference. Match the repo you are in.

`set -euo pipefail` applies to **entry points**, not to sourced libraries — a
file-scope `set -e` in a library leaks into whoever sources it. `lib/common.sh`
in BeschleunigerBallett says so in its own header.

### The rest of the naming rules, in one place

Small decisions that were folklore until 2026-09-15. Each is one line because
each is genuinely one line; the point is that the answer exists and is findable.

- **Version file.** Where a repo has one, it is `VERSION.txt` at the repo root —
  the default every entry point of
  [`02-toolchain/rust/version_util.sh`](../linux/scripts/02-toolchain/rust/version_util.sh)
  falls back to. A repo whose ecosystem already carries the version (a
  `pyproject.toml`, a `pubspec.yaml`, a workspace `Cargo.toml`) does not add a
  second one.
- **CHANGELOG.** A repo that publishes a package (PyPI, pub.dev, crates.io)
  keeps `CHANGELOG.md` **at the package root**, because that is what the registry
  renders. Applications rely on git history; do not add an unmaintained file to
  look tidy.
- **Instruction file.** `AGENTS.md` is the **only** instruction file. Anything an
  agent-specific tool wants at its own path (`.github/copilot-instructions.md`,
  `CLAUDE.md`, a `.cursorrules`) is a two-line pointer to `AGENTS.md`, never a
  second copy — the copies drift, and the one nobody re-reads wins.
- **Sphinx layout.** Consumers keep their Sphinx sources under `docs/source/`,
  which is `docs-build.sh`'s default. This hub and DocumANTation are the
  exception: they keep `docs/conf.py` beside the pages.
- **Package names.** A package name is unique within its registry. Reusing one
  *across* registries is allowed only when the two artifacts are the same
  capability in two languages, and the reuse is recorded here. There is exactly
  one: `kataglyphis_inference` is OxidANT's `crates/inference` (an ONNX Runtime
  Rust crate) and AccelerANTgine's staged Python binding around the same C++
  inference path. Neither is published, the registries are disjoint, and they
  are two faces of one capability — so both keep the name. A third use, or a
  publish, reopens this.
- **Environment-variable prefixes.** `KATAGLYPHIS_*` for build/tree knobs shared
  by every family repo, `ANTFRASTRUCTURE_*` for knobs that configure this hub's
  own machinery (the pin suite, the shared-config sync), `AGENTIC_*` for the
  agentic loop, and the repo's own name for consumer-private knobs
  (`ORCHESTRANT_*`). The hub's registry gate
  ([`code-quality-tooling.md` § `env-knobs`](code-quality-tooling.md#env-knobs--a-stale-allow-row-always-fails))
  grades the hub's own knobs against that vocabulary.
- **Workflow files.** Kebab-case, one per platform and arch, display names
  `<Platform> <Arch> · <what>`: § 6,
  [Workflow file names and display names](#workflow-file-names-and-display-names).

### The pre-commit hook, by reference

A consumer gets the whole lint aggregator on every commit with one config line
and no copied file:

```bash
git config core.hooksPath third_party/ANTfrastructure/shared/linux/templates/git-hooks
```

That directory holds a single `pre-commit` that `cd`s to the toplevel and runs
`run-lint-gates.sh` over it. It is deliberately **not** a
`shared-assets.manifest` row: a copied hook is a fork nobody re-syncs, and a
stale hook is invisible because it keeps passing. The hub's own hooks under
`linux/host-config/git-hooks/` are a different pair — they gate this
repository's internals and are not for consumers.

## 9. Quality gates

Every gate the hub runs over itself has a consumer-facing half; a consumer wires
four things and gets all of it:

1. **The shared-asset manifest.** `.antfrastructure-shared.manifest` at the
   consumer root declares which hub-owned files the repo holds a copy of
   (configs, the two bootstrap templates); `sync-shared-config.sh --repo-root .
   --check` is the drift gate, `--write` refreshes. The registry of asset ids and
   the rules are in [`../shared/config/README.md`](../shared/config/README.md).
2. **The lint aggregator.** `bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh .`
   runs shellcheck, actionlint + CI image refs, gitleaks (with a self-test),
   ruff, the manifest drift check and the consumer pin-forwarding check, all
   from pinned and SHA-verified binaries — see
   [`shared-script-libraries.md`](shared-script-libraries.md) § run-lint-gates.sh.
   Keep a ~5-line `scripts/linux/run-lint-gates.sh` wrapper so the dev-box
   command and the CI step are the same string, and call the reusable lane from
   CI: `jobs: lint: uses: Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@main`
   (inputs: `exclude`, `submodules`, `hub-checkout` for a consumer without a
   submodule). Add `--ratchets` once the eight `<gate>.allow` freeze files are
   seeded and committed; that switches on the measurement gates (code size,
   complexity, dead functions, comment size, stdout returns, masked
   declarations, trailing conditionals, shellcheck warnings) over the consumer's
   own shell.
3. **The pin suite.** `Submodule.Pins.Tests.ps1` asserts every submodule sits at
   its recorded, remotely reachable commit; consumers call
   `uses: Kataglyphis/ANTfrastructure/.github/workflows/submodule-pins.yml@main`
   (the AGENTS.md template's § 3 names the suite) instead of copying the job.
4. **Python repos** get the whole CI surface from the reusable
   `python-ci-linux.yml` / `python-ci-windows.yml` workflows —
   [`python-ci.md`](python-ci.md).

5. **The docs gates take `--root` too** (2026-09-15). `doc-links` runs in the
   `--ratchets` step — it has no freeze file, so it is safe the first time —
   and grades every tracked Markdown page, which is what finally puts a
   consumer's own `README.md` into the cross-reference graph. `doc-dupes` and
   `code-dupes` take `--root` as well, with budgets at `<root>/doc-dupes.allow`
   and `<root>/code-dupes.allow`, and stay off until a consumer seeds one: a
   duplication ratchet with no budget is red on its first run by construction.

Still hub-only: the versioned git hooks under `linux/host-config/git-hooks/`
`cd` into the hub layout and gate this repository's internals. Consumers get the
hook of § 8 instead, which runs the aggregator and nothing hub-specific.

## Checklist

- [ ] Submodule added; `Resolve-BuildModule.ps1` copied
- [ ] Entry points named and shaped as in § 8
- [ ] Windows build script built on `WindowsContainerBuild.Reuse`, ending in a delivery check (where the consumer has a Windows lane)
- [ ] Linux build uses a container-native build dir and a cargo cache volume
- [ ] No consumer copy of anything that exists upstream (check before writing) — the manifest drift gate and the lint aggregator of § 9 are the mechanism
- [ ] `.antfrastructure-shared.manifest` declared; `sync-shared-config.sh --check` green
- [ ] `run-lint-gates.sh` wired as a wrapper and as the reusable `lint-gates.yml` lane; ratchets on with freeze files committed
- [ ] `submodule-pins.yml` lane called (any repo with a submodule)
- [ ] `core.hooksPath` pointed at `third_party/ANTfrastructure/shared/linux/templates/git-hooks` (§ 8)
- [ ] `BACKLOG.md` + loop config + thin runners in place, prompts left upstream
- [ ] Role prompts are overlays only; `.opencode/agents/` gitignored, never hand-edited
- [ ] Workflows call the composite actions, FTP publishes through `deploy-over-ftp`
- [ ] Workflow files and display names follow § 6 (`linux-x64.yml`, `Linux x64 · …`)
- [ ] Consumer AGENTS.md links to these docs instead of restating them

### When the push is refused

`main` is usually protected, so the merge above cannot be pushed directly. Do
not force it — put the result on a branch and open a PR:

```bash
git push origin main || {
  git branch overwrite-main-from-develop
  git push origin overwrite-main-from-develop
}
```

### Repointing a remote

After a rename, a transfer, or moving from HTTPS to SSH:

```bash
git remote set-url origin git@github.com:<org>/<repo>.git
git remote -v
```
