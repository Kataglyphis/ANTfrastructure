# Adopting ContainerHub in a New Project

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
git submodule add https://github.com/Kataglyphis/ContainerHub.git third_party/ContainerHub
git submodule update --init --recursive
```

Everything below assumes that path. Consumers pin a commit like any other
submodule; bump the pin and the consuming change in the same commit, and push
ContainerHub `main` **before** the consumer, because CI resolves composite
actions at `@main`.

## Submodule maintenance

### Bumping the pin

```bash
git submodule update --remote --merge --recursive
```

Commit the resulting pointer change together with the consuming change, and push
ContainerHub `main` **first** — CI resolves composite actions at `@main`.

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
`third_party/ContainerHub/windows/scripts/modules/<Name>.psm1`
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

Bash consumers have no equivalent bootstrap problem — they source libraries by
relative path directly, e.g.
`third_party/ContainerHub/linux/scripts/lib/app-runner.sh`. Resolve
that path from `${BASH_SOURCE[0]}` rather than assuming the caller's working
directory is the repo root, and fail loudly (naming the
`git submodule update --init --recursive` command) when the submodule is not
checked out. OmniAccelerANT's `scripts/linux/lib/containerhub.sh`
is a two-function example.

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

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.

Local runs go through Rancher Desktop's `nerdctl`. From Git Bash you must
disable path mangling or the mount argument is destroyed:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' rdctl shell nerdctl run --rm --user root \
  -v cargo-cache:/cargo-cache \
  -v /mnt/d/path/to/repo:/workspace -w /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  bash -c 'bash scripts/linux/cmake-configure-build.sh --preset <preset> --build-dir /tmp/build --cargo-cache-dir /cargo-cache'
```

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
4. **Optional project system prompts** passed per engine
   (`--append-system-prompt-file` for the claude engine) describing that
   project's conventions.

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
`Kataglyphis/ContainerHub/.github/actions/<name>@main`:

| Action | Use |
|---|---|
| `run-in-linux-container` | One `docker run` in the Linux image, optional `tee` log and extra args |
| `run-in-windows-container` | Same for the Windows image (CPU clamp, bind mount, pwsh payload) |
| `set-docker-data-root` | **Use this FIRST on Windows runners**: moves docker's data root to the big D: drive — the ~54 GB image does not fit on a stock windows-2025 runner's C:, and a pull without the move dies late with `hcsshim::ImportLayer 0x70` (measured; see [windows-build-resources.md](windows-build-resources.md)) |
| `assert-docker-disk-space` | Fail fast when the runner cannot hold the image, instead of minutes into the pull |
| `cleanup-disk-space` | Free space on Windows runners — the historical, destructive fallback; prefer the two rows above |

They replace the hand-rolled `docker run` blocks that otherwise accumulate — in
the reference consumer, twenty-plus copies across two workflows.

Because actions resolve at `@main`, a consumer workflow change that depends on
an action change requires the ContainerHub push to land first.

## 7. Certificates / packaging (Windows)

`windows/scripts/certificates/` holds MSIX certificate generation and import
(`README.md` there) plus `download_webdav_files.py`, a generic WebDAV tree
downloader (`--extension`, Windows path sanitisation) used to fetch signing
certificates in CI instead of committing them. The `WindowsMsix.Common`,
`WindowsMsix.Signing` and `WindowsWebDav.Common` modules drive it.

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

**Bash entry points** — `set -euo pipefail`, resolve the script's own directory,
then source a per-repo bridge that pulls in `01-core/common.sh`:

```bash
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/ci_common.sh"          # or lib/common.sh
source "${_SCRIPT_DIR}/../../third_party/ContainerHub/linux/scripts/lib/<lib>.sh"
```

Long flags are `--kebab-case value`. A wrapper around one of the `lib/*.sh`
drivers should be ~30 lines: source the library, set the project's defaults,
call its `*_main`. `BeschleunigerBallett/scripts/linux/run-ctest.sh`
is the canonical example.

**Shell safety** — the five bug classes in this repo's `AGENTS.md`
(§ *Shell safety conventions*) apply to consumer scripts too. Every one of them
falsified or killed a real build here; they are not style preferences.

**Directory layout is now uniform across all seven consumers** (normalised
2026-08-11): lowercase `scripts/`, with `scripts/windows/`, `scripts/linux/`,
`scripts/windows/modules/` and — where the agentic loop is wired up —
`scripts/agentic-loop/`. Two repos used `Scripts/` + `Scripts/Windows/` until
that sweep. Use lowercase in a new consumer; there is no per-repo casing rule
to look up any more.

**Bash filenames still differ**, but not the way this note used to claim.
Measured 2026-09-06: kebab-case everywhere except OrchestrANT, which is
snake_case in 4 of its 5 scripts. The old wording said "snake_case in the rest"
and was wrong about OxidANT and AccelerANTgine — both are kebab. That one is
left alone deliberately: unlike a directory rename it buys no structural
consistency, and renaming every script would churn history for a purely lexical
preference. Match the repo you are in.

`set -euo pipefail` applies to **entry points**, not to sourced libraries — a
file-scope `set -e` in a library leaks into whoever sources it. `lib/common.sh`
in BeschleunigerBallett says so in its own header.

## Checklist

- [ ] Submodule added; `Resolve-BuildModule.ps1` copied
- [ ] Entry points named and shaped as in § 8
- [ ] Windows build script built on `WindowsContainerBuild.Reuse`, ending in a delivery check
- [ ] Linux build uses a container-native build dir and a cargo cache volume
- [ ] No consumer copy of anything that exists upstream (check before writing)
- [ ] `BACKLOG.md` + loop config + thin runners in place, prompts left upstream
- [ ] Workflows call the composite actions
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
