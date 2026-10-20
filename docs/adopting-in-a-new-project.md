# Adopting ANTfrastructure in a New Project

The checklist for wiring a **new** project to the hub's tooling, which consumers import instead of
copying: Windows container builds (Stevedore), Linux container builds (Rancher Desktop / CI), the
planner–executor agentic loop, reusable PowerShell modules and bash libraries, and CI composite
actions. BeschleunigerBallett is the reference consumer: when a detail here is ambiguous, read how
that repo does it.

## 0. Add the submodule

```bash
git submodule add https://github.com/Kataglyphis/ANTfrastructure.git third_party/ANTfrastructure
git submodule update --init --recursive
```

Everything below assumes that path. Consumers pin a commit like any other submodule; bump the pin
and the consuming change in the same commit, and push ANTfrastructure `develop` **before** the
consumer, because CI resolves composite actions at `@develop` (§ 6 says why not `@main`).

### Submodule URLs are https, never `git@`

Every `.gitmodules` url in the family is `https://github.com/Kataglyphis/<repo>.git`. An ssh url
needs a key, and nothing that resolves these has one: a hosted runner, the `:latest` container the
Renovate runner starts, an anonymous clone, and a recursive checkout from a superproject, which
inherits the submodule's `.gitmodules`. `actions/checkout` installs a `url.<https>.insteadOf`
rewrite that hides an ssh url; a bare `git submodule update` gets no such rewrite and dies with
`Permission denied (publickey)` on a public repository. To change one:

```bash
git config -f .gitmodules submodule.<path>.url https://github.com/Kataglyphis/<repo>.git
git submodule sync   # moves the existing checkout's remote too
```

## Submodule maintenance

### Bumping the pin

The family moves gitlinks with Renovate as a local CLI
([`dependency-updates.md`](dependency-updates.md)): `renovate-local.sh`, called through the
wrapper template in `shared/linux/templates/`, reports what is behind; `--apply` moves the gitlink.
By hand, name the path and leave `--recursive` out:

```bash
git submodule update --remote --merge third_party/ANTfrastructure
```

A bare `git submodule update --remote` is forbidden in this family (`AGENTS.md`
§ Dependency Updates). `--remote` follows the `branch =` that `.gitmodules` declares for the
submodule. Commit the pointer with the consuming change and push the hub's `develop` first (§ 0).

### Putting every checkout on its branch

`git submodule update` leaves each submodule on a detached HEAD at its recorded commit. To work on
the latest tip of every repo instead, run from the superproject:

```bash
bash third_party/ANTfrastructure/linux/scripts/git-sync-branches.sh --dry-run   # the plan
bash third_party/ANTfrastructure/linux/scripts/git-sync-branches.sh             # do it
```

It checks out the superproject's default branch, then walks every submodule, parents before
children, onto the `branch =` that `.gitmodules` declares for it, else the remote's default
branch. It only fast-forwards: a submodule with uncommitted changes is skipped (`SKIP`); a local
branch diverged from its remote fails the run (`FAIL`) while the rest still syncs.

- **Every submodule moves, third-party ones included** (owner decision 2026-10-07). To hold a
  third-party library at a release, declare that release branch as its `branch =`. `--owned-only`
  leaves every submodule hosted under another owner than the superproject's (`github.com/nlohmann`
  vs `github.com/Kataglyphis`) at its recorded commit (`PIN`).
- **A submodule inside a third-party submodule cannot be recorded** by any repo you own, so after
  a run it stays listed as moved until that upstream bumps it.
- **It moves working trees, never gitlinks.** It ends by listing every submodule no longer at its
  recorded commit. The next `git submodule update`, or a git GUI that runs one, puts them back. To
  keep them, commit the gitlinks in each parent, innermost repo first, through the pin bump above.
- A submodule that a newer parent commit **adds** is not initialised; run
  `git submodule update --init <path>` for it.

### After a history rewrite

When a repository's history is rewritten on GitHub (big blobs purged, every commit id new), an
existing checkout still holds the old commits and their blobs, and a plain `git pull` merges the
two histories. Instead, run this once per checkout, from the superproject, on every machine
(Windows: Git Bash):

```bash
bash third_party/ANTfrastructure/linux/scripts/git-adopt-rewritten-history.sh --dry-run   # the plan
bash third_party/ANTfrastructure/linux/scripts/git-adopt-rewritten-history.sh             # do it
```

- **Nothing local is lost.** Before anything moves, uncommitted changes, stashes, commits that
  never reached origin and local-only tags go to `~/git-rewrite-backup/<timestamp>/`
  (`--backup DIR`) as patches and lists; the uncommitted changes are re-applied (staged) afterwards.
- **A rewritten commit is told from unpushed work by its twin**: origin has a commit with the same
  author, author date and subject. So an IDE's background fetch before the run does not hide the
  rewrite.
- **The old blobs leave the disk**: in each rewritten repository the reflogs are expired and
  `gc --prune=now` runs. A repository whose remote was not rewritten is only fast-forwarded and
  keeps its reflog.
- A detached submodule moves to the superproject's new gitlink; one on a branch, as
  `git-sync-branches.sh` leaves it, moves with that branch.
- **It names what it cannot clean**: another remote (a fork), a linked worktree, a local branch
  without an upstream that origin lacks commits of, and `refs/original/` (a local `filter-branch`)
  may still hold the old history, and their objects stay until they are removed. Bundle such a
  branch (`git bundle create`) before deleting it.

### Resolving a submodule conflict on merge

A merge that touches the pin from both sides leaves `third_party/` paths unmerged, and
`git checkout --theirs` alone does not resolve them: the conflict is over *which commit the
superproject records*, not over file contents. It arises when two branches diverged far enough that
you want one side wholesale. Set the merge up so it stages nothing automatically, then resolve:

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

Run `git submodule update --init --recursive` **after** committing as well as before: staging the
pointer does not check the submodule out at that commit, so skipping it leaves a working tree that
does not match what you just recorded.

`-X theirs` on the merge resolves file contents but leaves submodule pointers conflicted. The loop
above is the part that is easy to forget, and without it the "resolved" merge silently pins the
wrong commit.

### Recovering a broken submodule checkout

When a clone left submodules half-initialised (wrong commit, empty directory, a `.git` file
pointing nowhere), reset them instead of deleting the tree:

```bash
git submodule deinit -f --all
git submodule update --init --recursive
```

`deinit -f` discards local submodule working trees: commit or stash anything inside them first.

### Long paths (Windows consumers)

The hub's nesting plus a deep build directory exceeds `MAX_PATH` quickly. Besides the host-level
`LongPathsEnabled` setting in [`windows-host-setup.md`](windows-host-setup.md), git needs its own:

```bash
git config --global core.longpaths true
```

Without it, clone or checkout fails with `Filename too long` on files the filesystem accepts.

### Resetting to a clean tree

```bash
git clean -fdx
git reset --hard
```

`-x` also removes ignored files (build outputs, `.venv`, cached toolchains): usually the point, but
the next build starts cold.

### `git pull` hanging in PowerShell

An SSH remote needs the agent running as a Windows service; without it the client waits on a
passphrase prompt nothing displays:

```powershell
Start-Service ssh-agent
ssh-add "$env:USERPROFILE\.ssh\id_ed25519"
```

`Set-Service -Name ssh-agent -StartupType Automatic` makes it stick.

### Shallow fetches

A build agent rarely needs every submodule's full history:

```bash
git fetch --depth=1 origin <branch>
git reset --hard FETCH_HEAD
```

## 1. The one file that cannot live here

Each consumer needs a small bootstrap that *finds* this submodule, since it runs before anything
upstream is importable. Copy
[`shared/windows/templates/Resolve-BuildModule.ps1`](../shared/windows/templates/README.md)
to `scripts/windows/Resolve-BuildModule.ps1` and adjust `$script:RepoRootRelativeToHere` if the
script does not sit exactly two directories below the repo root. It resolves a module name to
`third_party/ANTfrastructure/windows/scripts/modules/<Name>.psm1`
first, then a local `modules/` fallback beside itself, and throws with both paths if neither
exists.

**Copy the template, do not re-author it.** All four consumers had written this file
independently and drifted: different search orders, different error text, one missing `-Global`
on the import.

The search order is the whole contract: **put reusable modules upstream and they win
automatically**; the local fallback holds only project-specific modules. A module a second
consumer needs belongs here; that test moved `WindowsTesting.Common` and `WindowsClang.Common`
upstream on 2026-08-11.

Bash consumers: copy
[`shared/linux/templates/antfrastructure.sh`](../shared/linux/templates/README.md)
to `scripts/linux/lib/antfrastructure.sh` (or `scripts/lib/` in a flat Flutter repo), adjust
`KATAGLYPHIS_REPO_ROOT_RELATIVE`, and declare it as `antfrastructure-sh` in
`.antfrastructure-shared.manifest` so the drift gate watches it. It resolves paths from
`${BASH_SOURCE[0]}`, never from the caller's working directory, and its failure message names the
fix.

**A consumer with no submodule is supported.** The bootstrap takes `$ANTFRASTRUCTURE_DIR` first (a
container mounts the workspace elsewhere than the host, so an explicit answer always wins), then
`third_party/ANTfrastructure`, then a sibling clone at `<repo>/antfrastructure-tools`. Its error
offers `git submodule update` only when `.gitmodules` names that path, and otherwise tells you to
clone or to export `ANTFRASTRUCTURE_DIR`.

## 2. Windows container builds (Stevedore)

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (clang-cl, CMake, Ninja, Vulkan
SDK, Rust, sccache preinstalled). Import `WindowsContainerBuild.Reuse` through the resolver and
build on its functions instead of re-implementing the pattern:

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

Read [`windows-container-build-performance.md`](windows-container-build-performance.md) before
designing your flow: both transports and their setup, why the build tree must not live on a named
volume, the Windows path limit that silently truncates tar transfers, and the container-reuse
measurements.

Three rules, each learned by debugging:

- **Mount/stream to the same in-container path under every transport.** CMake bakes absolute
  paths into `CMakeCache.txt` and rejects a cache generated elsewhere.
- **A green build is not proof of delivery.** Always end with `Test-BuildArtifactsDelivered`;
  both "built nothing" and "delivered nothing" have happened silently.
- **A red docker client is not proof of failure.** The CLI drops its pipe mid-run on this host
  while the container keeps building. Name the run, leave `--rm` off, and take the verdict from
  `Wait-ContainerExit`.

## 3. Linux container builds (Rancher Desktop / CI)

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`.

Local runs go through one driver, which answers the image tag, the mount layout, the git
safe.directory, the engine and the Git Bash path-mangling escape in one place instead of per repo
([`shared-script-libraries.md` § `run-in-ci-image.sh`](shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image)
owns the explanation):

```bash
bash third_party/ANTfrastructure/linux/scripts/run-in-ci-image.sh . -- \
  bash scripts/linux/cmake-configure-build.sh --preset <preset> \
       --build-dir /tmp/build
```

It mounts the checkout and nothing else, and has no option for a second mount (2026-09-25): a
cargo cache that outlives the run (below) needs a plain `nerdctl run`/`docker run` with the image
from `ci-image-ref.sh` and a named volume.

Three constraints:

- **The CMake build directory must be container-native** (`/tmp/...`), not on the bind-mounted
  host tree: FetchContent's rename and cargo's temp-file cleanup both fail on that filesystem.
- **Persist cargo via a named volume** (`--cargo-cache-dir`, which `lib/cmake-build.sh` turns into
  `CARGO_HOME` and `CARGO_TARGET_DIR`). The image's own `CARGO_HOME` is writable
  ([`consumer-image-contract.md`](consumer-image-contract.md), promise 2), but it lives in the
  container and dies with it.
- **Never assume a tool is present because it is on your dev box.** `jq` is *not* in the Linux
  image; `python3` is. A hard `jq` dependency silently broke shader precompilation and left CI
  with no artifacts.

Prefer `linux/scripts/01-core/` helpers (logging, retry, downloads with SHA verification,
uv/python env, parallelism) over new implementations.

## 4. The agentic loop

Reusable core:

- PowerShell: `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`
- Bash: `linux/scripts/lib/agentic-loop.sh`
- Default task prompts: `shared/agentic-loop/prompts/{planner,refactor-planner,executor}.md`, the
  single source both platforms read. Never hard-code prompt text in a consumer wrapper; that is
  how the two platforms drifted apart.

Start from the copy-and-edit templates in
[`shared/agentic-loop/templates/`](../shared/agentic-loop/templates/README.md)
(config with every project-specific field marked `TODO`, plus both runner wrappers, which
`.antfrastructure-shared.manifest` declares as `agentic-loop-sh` and `agentic-loop-ps1` so the
shared-config gate watches them). A consumer supplies four things:

1. **`BACKLOG.md`** with the checkbox protocol: `- [ ]` actionable, `- [b]` blocked (skipped, and
   excluded from the pending count so a blocked-only backlog lets the planner run again), `- [x]`
   completed (pruned; history lives in git).
2. **A config JSON.** Shape (see the reference consumer's
   `scripts/agentic-loop/AgenticLoop.config.json`): `engine`, per-engine model and prompt settings
   under `engines.*`, cadences and timeouts under `intervals.*`, per-platform
   `buildMatrix.{windows,linux}` entries (`name`/`sanitizer`/`buildDir`/`buildType`/`testCommand`),
   `build.*` commands, `git.*` auto-commit settings, `backlog.*` policy, `logging.logDir`.
3. **Thin runner wrappers**: `Invoke-AgenticLoop.ps1` / `.sh`. They load the config, resolve the
   module/library, and call `Invoke-AgenticLoop` / `run_agentic_loop`. Build configs and prompts
   both default from the config and the shared prompt files, so the wrappers stay tiny.
4. **Project role-prompt overlays**: `scripts/agentic-loop/prompts/planner-overlay.md` and
   `executor-overlay.md`, wired via the config's top-level `promptOverlays` block. Write only your
   project's delta. The loop composes `shared/agentic-loop/system-prompts/<role>.md` + your overlay
   once and delivers that one text to both engines (the opencode engine needs opencode **v2**,
   [install](windows-agentic-loop.md#opencode-v2)): to `claude` via `--append-system-prompt-file`,
   and to `opencode` by GENERATING `.opencode/agents/<role>.md`, its only role-prompt channel. Add
   `.opencode/agents/` to `.gitignore`; the loop warns if you have not. A tracked, hand-edited copy
   of that file left one consumer with two full copies of the role prompt 271 lines apart, the
   stale one missing the executor's incident narrative, its `timeout: 600000` guidance and the
   `- [b]` commit step.

API reference: [`windows-agentic-loop.md`](windows-agentic-loop.md).
Build-matrix semantics and sanitizer env handling:
[`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md).

**The loop does not watch CI, and it auto-commits with `git add -A`.** Expect it to keep committing
over a red pipeline, and check whether it is live before running interactive work in the same tree.

## 5. Application launchers

`linux/scripts/lib/app-runner.sh` provides argument parsing
(`--exe-name/--build-dir/--build-type`), executable discovery with a bounded
fallback search, `LD_LIBRARY_PATH` export, and hooks
(`app_runner_post_vulkan_hook`, `app_runner_env_hook`,
`APP_RUNNER_ENABLE_SHADER_CLEAN`). Consumers keep only per-profile wrappers
holding defaults and hooks.

## 6. CI

Composite actions live in [`.github/actions/`](../.github/actions/README.md) and are referenced
from a consumer workflow as `Kataglyphis/ANTfrastructure/.github/actions/<name>@develop`.

**`@develop`, not `@main`** (owner directive 2026-09-25). Work lands on `develop`; `main` is a
release branch that lags it, and its `versions.env` still names the retired `:latest-cross`, whose
tags were deleted on 2026-09-29, so an action at `@main` fails at `docker pull`. The same ref
applies to the reusable workflows below, and a consumer workflow change that depends on a hub
change needs the hub push first (§ 0).

All fifteen, with every input and output, are listed once in
[`.github/actions/README.md`](../.github/actions/README.md); this page keeps no second copy. They
replace hand-rolled `docker run` blocks (twenty-plus copies across two workflows in the reference
consumer) and include `deploy-over-ftp`, the family's one FTP publish policy
([`ftp-deploys.md`](ftp-deploys.md)).

**One ordering rule is about your workflow, not an action, so it lives here:** on a Windows runner,
`set-docker-data-root` runs **FIRST** (`prepare-windows-container-host` runs it before its own
pull). It moves docker's data root to the big `D:` drive: the ~54 GB image does not fit on a stock
`windows-2025` runner's `C:`, and a pull without the move dies late with
`hcsshim::ImportLayer 0x70` (measured; see
[windows-build-resources.md](windows-build-resources.md)).

Five lanes are reusable workflows, each called with
`uses: Kataglyphis/ANTfrastructure/.github/workflows/<name>.yml@develop`:

- `lint-gates.yml`: the consumer lint gates (§ 9).
- `submodule-pins.yml`: the pin suite (§ 9).
- `python-ci-linux.yml` / `python-ci-windows.yml`: the Python pair (§ 9).
- `build-docs.yml`: builds, checks and publishes a docs site from the repository's own `docs.yml`
  (inputs, secrets and each repository's move:
  [`docs-sites.md`](docs-sites.md#the-reusable-workflow)).
- `container-ci-windows.yml`: the Windows container lane. Its caller names a build script, the
  script's arguments and the directory the product lands in (`dist/windows-x64` or
  `dist/windows-arm64` in every caller, with the DLL closure the product needs);
  `target-arch: arm64` adds the arch gate and a run on `windows-11-arm`
  ([`windows-cross-builds.md` § Consumer cross lanes](windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml)).
  Since 2026-09-26 the `windows-x64.yml` and `windows-arm64-cross.yml` of OxidANT, AccelerANTgine
  and BeschleunigerBallett call it. A caller hands its own secrets to the container through the
  `CONTAINER_SECRET_ENV` secret, one `KEY=value` per line, which reaches docker as an
  `--env-file`.

### Workflow file names and display names

Owner decision 2026-09-24, for every repository in the family, this one included.

- **Files are kebab-case, and a build gets one file per platform and arch:** `linux-x64.yml`,
  `linux-arm64.yml`, `windows-x64.yml`, `windows-arm64-cross.yml`, `android.yml`, `web.yml`. A lane
  every repo has carries the same file name everywhere: `lint-gates.yml`, `submodule-pins.yml`,
  `codeql.yml`, `docs.yml`. A reusable workflow that lives in a consumer is
  `reusable-<platform>.yml`.
- **Display names read `<Platform> <Arch> · <what>`** for a build (`Linux x64 ·
  preflight + mutation gate`) and `<Area> · <what>` for anything else (`Docs ·
  stale check`, `GHCR · cleanup`). The separator is U+00B7, the middle dot. The shared lanes are
  `Lint gates`, `Submodule pins`, `CodeQL` and `Docs · …`; a consumer's reusable workflow is
  `<Platform> · reusable build`.
- **This hub's reusable workflows keep their file names.** Every consumer calls them as
  `Kataglyphis/ANTfrastructure/.github/workflows/<file>@develop`, so a rename breaks the fleet at
  once. Only their display names changed, and they end in `(reusable)`:
  `Docs · build + publish (reusable)`, `Lint gates (reusable)`, `Python CI · Linux (reusable)`,
  `Python CI · Windows (reusable)`, `Submodule pins (reusable)`, and
  `Container CI · Windows (reusable)`, new on 2026-09-25.
- **Splitting a Python lane per arch** needs no copied job: `python-ci-linux.yml`'s `arches` input
  picks the rows ([`python-ci.md`](python-ci.md#one-arch-per-caller-the-arches-input)).

The rename across the fleet, old name to new:

| Repository | Before | After |
|---|---|---|
| ANTfrastructure | `ubuntu26.04.yml` | `linux-x64.yml` |
| ANTfrastructure | `windows-scripts.yml` | `windows-x64.yml` |
| OxidANT | `rust_ubuntu26_04.yml` | `linux-x64.yml` + `linux-arm64.yml`, sharing `reusable-linux.yml` |
| OxidANT | `rust_windows2025.yml` | `windows-x64.yml` |
| AccelerANTgine | `linux_run.yml` | `reusable-linux.yml` |
| AccelerANTgine | `linux_run_x86.yml` | `linux-x64.yml` |
| AccelerANTgine | `linux_run_arm.yml` | `linux-arm64.yml` |
| AccelerANTgine | `windows_run.yml` | `windows-x64.yml` |
| OmniAccelerANT | `dart_on_native_linux.yml` | `linux-x64.yml` + `linux-arm64.yml`, sharing `reusable-linux.yml` |
| OmniAccelerANT | `dart_on_native_windows.yml` | `windows-x64.yml` |
| OmniAccelerANT | `dart_build_android_app.yml` | `android.yml` |
| OmniAccelerANT | `dart_on_web_linux.yml` | `web.yml` |
| BeschleunigerBallett | `Linux.yml` | `reusable-linux.yml` |
| BeschleunigerBallett | `Linux_x86.yml` | `linux-x64.yml` |
| BeschleunigerBallett | `Linux_arm.yml` | `linux-arm64.yml` |
| BeschleunigerBallett | `Windows.yml` | `windows-x64.yml` |
| OrchestrANT, WebDavClient | `windows-2025.yml` | `windows-x64.yml` |
| WebDavClient | `ubuntu-26.04-amd64-arm64.yml` | `linux-x64.yml` + `linux-arm64.yml` (2026-09-25, through `arches`) |
| OrchestrANT | `ubuntu-26.04-amd64-arm64.yml` | kept for now; the same split is open to it (`arches`) |
| jotrockenmitlocken | `dart.yml` | `web.yml` |
| ANThology | `dart.yml` | `docs.yml` |
| DocumANTation | `docs-pages.yml` | `docs.yml` |

A hub page that cites a consumer workflow with a LINE number from before the rename (the table in
[`ftp-deploys.md`](ftp-deploys.md)) is a dated record and keeps the old name; this table
translates it.

## 7. Certificates / packaging (Windows)

`windows/scripts/certificates/` holds MSIX certificate generation and import (`README.md` there),
driven by the `WindowsMsix.Common`, `WindowsMsix.Signing` and `WindowsWebDav.Common` modules.

- **Signing:** `Invoke-MsixPackage -Sign -SigningRoot <repo root>` signs with the `*.pfx` it finds
  in that directory (not recursively; the family keeps it there, gitignored) and
  `MSIX_PFX_PASSWORD`. Since 2026-09-25 `-Sign` without `-SigningRoot` throws before anything is
  staged.
- **A failed signing only warns**, so a package that must install passes `-RequireSignature` (with
  `-SignerSubject` for the manifest's publisher): it throws when the MSIX comes out unsigned, or
  signed by another subject.
- **A throwaway certificate for a test signature** comes from `New-TestSigningCertificate`
  (`WindowsMsix.Signing`): made in memory, no certificate store touched, the `.pfx` optionally
  protected with `-Password`. `certificates/GenerateCertificateMSIX.ps1` stays the manual tool for
  a long-lived, AES-protected developer certificate.
- **An MSI** built from the project's own `.wxs` goes through `Invoke-MsiPackage`
  (`WindowsMsix.Common`, since 2026-10-05). It runs `wix build` with `Version`, `ExeSource`,
  `LicenseRtf`, `ProductName` and `Manufacturer` as preprocessor variables. With `-PayloadFiles`
  it also writes a fragment for `<ComponentGroupRef Id='PayloadFiles'/>`, one component per file.
  OxidANT is the first caller; a CMake repo builds its MSI through CPack's WiX generator instead.

The consumer stages what a package carries, with two hub helpers. A product's DLL closure comes
from `Copy-PeImportClosure` (`WindowsCrossBundle.Common`,
[`windows-cross-builds.md`](windows-cross-builds.md)). ONNX Runtime comes from
`WindowsOrtPayload.Common`: stage the chain copy with `Copy-ChainOrtBeside`, then prove the payload
with `New-OrtProvenPayload` or `Assert-ChainOrtTree`
([`onnxruntime-single-source.md` § The shared Windows glue](onnxruntime-single-source.md#the-shared-windows-glue)).

The WebDAV downloader that fetches those signing certificates in CI (instead of committing them) is
**not** Windows-specific and no longer lives there: it is
`linux/scripts/01-core/download-webdav-files.py`, with a shim at the old
`windows/scripts/certificates/download_webdav_files.py` path because the PowerShell module
resolves it relative to itself. A Linux lane calls it through `webdav_download_tree`
([`shared-script-libraries.md`](shared-script-libraries.md#01-corewebdav-downloadsh)). Both halves
install the client at `WEBDAVCLIENT_REF` from `versions.env`.

## 8. Calling conventions (what every consumer looks like)

Eight repos consume this one (`.github/consumers.json`). The shapes below are what they converged
on, so a new consumer that follows them reads like every other. Recorded 2026-08-11 after measuring
the seven consumers of that day (WebDavClient joined the list later); until then the convention
was folklore and had drifted.

**Windows entry point**: `<scripts>/windows/Build-Windows.ps1`, PascalCase `Verb-Noun` like every
other PowerShell file. It must:

```powershell
#requires -Version 7.0          # every module here declares it; pwsh, never powershell
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @('WindowsScripts.Shared', 'WindowsBuild.Common', ...)
```

Run the app with a sibling `Start-Windows.ps1`. Project-specific modules go in
`<scripts>/windows/modules/`, which the resolver checks after this repo.

**The verb carries the meaning.** The family uses three of PowerShell's approved verbs in narrower
senses than the approved-verb list gives them: `Start-` launches the built application, `Invoke-`
runs a build step or a tool, `Build-` produces artifacts. `Build-Windows.ps1` builds,
`Start-Windows.ps1` runs, `Invoke-Lint.ps1` lints. **PowerShell lives under `scripts/windows/`**
whatever lane it drives: a `.ps1` that starts a *Linux* container is still PowerShell and belongs
there, because a reader asks "which shell do I need", not "which OS does it target".

**Bash entry points**: `set -euo pipefail`, resolve the script's own directory, then source a
per-repo bridge that pulls in the bootstrap of § 1, and reach a hub file through it, never through
a `../../third_party/...` literal:

```bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"          # sources lib/antfrastructure.sh
antfrastructure_source linux/scripts/lib/<lib>.sh
```

Long flags are `--kebab-case value`. A wrapper around one of the `lib/*.sh` drivers should be ~30
lines: source the library, set the project's defaults, call its `*_main`.
`BeschleunigerBallett/scripts/linux/run-ctest.sh` is the canonical example.

**Shell safety**: the five bug classes in this repo's `AGENTS.md` (§ *Shell safety conventions*)
apply to consumer scripts too. Each one falsified or killed a real build here; they are not style
preferences.

**Directory layout is uniform across the six consumers that have a Windows lane**
(BeschleunigerBallett, OmniAccelerANT, OrchestrANT, AccelerANTgine, OxidANT, WebDavClient;
normalised 2026-08-11, WebDavClient checked 2026-09-25): lowercase `scripts/`, with
`scripts/windows/`, `scripts/linux/` and, where the agentic loop is wired up,
`scripts/agentic-loop/`, plus `scripts/windows/modules/` for a repo with project-specific modules
and `scripts/windows/container/` for scripts that run inside the Windows image, not on the host
(OxidANT's `Invoke-StevedoreBuild` callees). Two repos used `Scripts/` + `Scripts/Windows/` until
that sweep; use lowercase in a new consumer, there is no per-repo casing rule to look up. Two
exceptions: jotrockenmitlocken, a Linux-only Flutter repo, keeps a flat `scripts/`, with the
bootstrap at `scripts/lib/` and that path declared in `.antfrastructure-shared.manifest`; ANThology
has no hub submodule and no bootstrap, and its `scripts/lib/find-hub.sh` looks for a hub checkout
instead.

**Bash filenames are kebab-case everywhere except OrchestrANT** (measured 2026-09-14). There the
four `ci_*.sh` wrappers mirror the hub's own snake_case drivers under
`linux/scripts/02-toolchain/python/` by name, and `benchmarks/run_benchmarks.sh` kept its name
from the hub's llm-stack; its other scripts are kebab. An older wording said "snake_case in the
rest" and was wrong about OxidANT and AccelerANTgine, both kebab. That exception stays: unlike a
directory rename it buys no structural consistency, and renaming every script would churn history
for a purely lexical preference. Match the repo you are in.

`set -euo pipefail` applies to **entry points**, not to sourced libraries: a file-scope `set -e`
in a library leaks into whoever sources it. The hub's own libraries follow the same rule
(`AGENTS.md` § Development Rules).

### Reach for these before writing a helper

Every row was first written locally in a consumer and later found here, usually in a better form
and twice with a bug the local copy did not have. The list moved here from OxidANT's `AGENTS.md`
on 2026-10-05 (CON55), so each consumer links one list instead of keeping its own.

| Need | Use | Defined in | Not |
| --- | --- | --- | --- |
| `docker.exe` discovery (Stevedore) | `Resolve-DockerExe` | [`WindowsContainerBuild.Reuse.psm1`](../windows/scripts/modules/WindowsContainerBuild.Reuse.psm1) | a hand-rolled candidate list |
| `nerdctl` discovery (Rancher Desktop, never Stevedore's) | `Resolve-NerdctlExe` (`-AllowMissing` for a guard) | same file | `Get-Command nerdctl` plus a Rancher path per script |
| A bash command in a Linux container from Windows: named volumes chowned by the run's image, `-Privileged`, `-Device`, `-Env`, `-ExtraMount` | `Invoke-InLinuxContainerBuild` | [`WindowsBuildSweep.Common.psm1`](../windows/scripts/modules/WindowsBuildSweep.Common.psm1), [`rancher-desktop-linux-containers.md`](rancher-desktop-linux-containers.md#use-nerdctl-not-docker) | a hand-built `nerdctl run` with its own volume chown |
| `--isolation process` and friends | `Get-ContainerIsolationArgs` | same file | inline flags |
| Container teardown | `Remove-BuildContainerSafe` | same file | `docker rm -f`, which misses the wcifs teardown lock |
| Bind-mount probe, artifact delivery | `Test-ContainerBindMount`, `Test-BuildArtifactsDelivered` | same file | assuming a green build delivered something |
| Stage, manifest, pack and sign one MSIX; `-RequireSignature` refuses an unsigned one | `Invoke-MsixPackage` | [`WindowsMsix.Common.psm1`](../windows/scripts/modules/WindowsMsix.Common.psm1) | a local makeappx/assets/tokens/pack sequence, or a `Get-AuthenticodeSignature` check after it |
| A throwaway code-signing certificate, no store touched | `New-TestSigningCertificate` | [`WindowsMsix.Signing.psm1`](../windows/scripts/modules/WindowsMsix.Signing.psm1) | `New-SelfSignedCertificate` into `Cert:\CurrentUser\My` and an `Export-PfxCertificate` |
| The `TESTS: passed=<n> failed=<n> skipped=<n>` verdict of staged tests, graded | `Invoke-StagedTests.ps1 -AssertVerdict`, `Assert-StagedTestVerdict` | [`windows-cross-builds.md`](windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml) | a `Select-String` of the line and three `throw`s per script |
| A CMake product's `dist\windows-<arch>\{bundle,packages}`: install tree, DLL closure, installers | `New-PortableBundle` (`-RequireCompleteInstall`) | [`WindowsCrossBundle.Common.psm1`](../windows/scripts/modules/WindowsCrossBundle.Common.psm1), [`windows-cross-builds.md`](windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml) | an install, `Copy-PeImportClosure` and installer copy per build script |
| The version to stamp a package with: `VERSION.txt`, or `-VersionFile` (a `Cargo.toml`, `pubspec.yaml`, `pyproject.toml` or `CMakeLists.txt`, read as `version_util.sh --file-version` does); `-Required` throws instead of the `0.0.1.0` fallback | `Get-PackageVersion` | same file | reading a version file inline, with a different fallback per step |
| SDK tools (makeappx, signtool) | `Resolve-WindowsSdkToolPath` | same file | `Get-ChildItem -Recurse` over the Kits tree |
| Manifest tokens, XML escaping, placeholder PNGs | `Expand-XmlTemplateTokens`, `ConvertTo-XmlSafeText`, `New-TransparentPng` | same file | `-replace`, or a local redefinition |
| A clang-format of the pinned LLVM, or a refusal | `code_quality_require_pinned_clang_format` (bash), `Invoke-ClangFormatCheck` (its default `-ExpectedVersion`) | [`code-quality-tooling.md` § The pinned clang-format](code-quality-tooling.md#the-pinned-clang-format) | a `clang-format --version` grep per script |
| Config access | `Get-OrDefault`, `Get-ConfigValue` | [`WindowsConfig.Common.psm1`](../windows/scripts/modules/WindowsConfig.Common.psm1) | copies |
| One `Build.Configurations` row of a `Build-Windows.config.psd1`, its `BuildDirEnv` / `PresetEnv` overrides applied | `Get-BuildConfigurationRow` | same file | a `Get-BuildConfiguration` per build script |
| Build logging and steps | `New-BuildContext`, `Invoke-BuildStep`, `Invoke-BuildExternal`, `Write-BuildLog*` | [`WindowsBuild.Common.psm1`](../windows/scripts/modules/WindowsBuild.Common.psm1) | ad-hoc `Write-Host` wrappers |
| `CI_COMPILER_CACHE` into container-local directories and back, and whether this sccache may keep a clang-cl module build's cache | `Restore-CiCompilerCache`, `Save-CiCompilerCache`, `Test-SccacheModuleSafe` | same file, [`build-cache-tiers.md`](build-cache-tiers.md) | a robocopy `/MOVE` pair in the build script |
| A Python repo's Windows CI build: pytest legs, gating static analysis, packaging | `Invoke-PythonCiBuild.ps1` and a `scripts\windows\python-ci.psd1` | [`python-ci.md` § The Windows build driver](python-ci.md#the-windows-build-driver) | a `Build-Windows.ps1` with its own `Write-Log*`, `Invoke-Step` and uv shims |
| Tool guards, workspace paths, a hub pin from `versions.env` | `Assert-Command`, `Resolve-WorkspacePath`, `Get-ANTfrastructurePin` | [`WindowsScripts.Shared.psm1`](../windows/scripts/modules/WindowsScripts.Shared.psm1) | a second implementation, or a `versions.env` regex |
| Logging inside a container | `Start-ContainerLog`, `Write-ContainerLog`, `Invoke-ContainerLoggedCommand` | [`WindowsContainerLog.Common.psm1`](../windows/scripts/modules/WindowsContainerLog.Common.psm1) | a `Say`/`Run-Logged` pair per script |
| CI version stamping (bash) | `version_util.sh --github-env`, `--resolve-ci`, `--normalize` | [`version_util.sh`](../linux/scripts/02-toolchain/rust/version_util.sh) | re-reading `VERSION.txt` or `Cargo.toml` yourself |
| In-container cargo steps | `cargo_debug.sh`, `cargo_release.sh`, `cargo_test.sh`, `cargo_coverage.sh`, `cargo_fmt_clippy.sh` (`CARGO_CLIPPY_ARGS`), … | [`02-toolchain/rust/`](https://github.com/Kataglyphis/ANTfrastructure/tree/develop/linux/scripts/02-toolchain/rust) | inline cargo invocations |
| Publishing a GitHub release: `v<version>` from `pubspec.yaml`, `Cargo.toml` or `VERSION.txt`, the CHANGELOG section as notes, a `SHA256SUMS` | `publish-github-release.sh --check` / `--assets` | [`publish-github-release.sh`](../linux/scripts/06-packaging/publish-github-release.sh) | a per-repo release script |
| A `release.yml`'s version check and release job | `release-publish.yml`, `stage: check` and `stage: publish` | [`release-publish.yml`](../.github/workflows/release-publish.yml) | copying another repo's two jobs |
| The lanes' uploads as one flat directory of release files | `collect-release-assets.sh` with `--include`, `--rename`, `--zip`, `--expect`, … | [`collect-release-assets.sh`](../linux/scripts/06-packaging/collect-release-assets.sh) | a per-repo `collect-release-assets.sh` |
| Every library a bundle's ELFs need, copied into it (Linux) | `elf-closure.sh` with `--from`, `--search`, `--ldconfig` or `--ldd`, `--exclude` | [`elf-closure.sh`](../linux/scripts/06-packaging/elf-closure.sh), [`linux-build-basics.md`](linux-build-basics.md#the-elf-closure-walker) | a per-repo `walk_queue` or `ldd` loop |
| Models and scenes a lock pins: cache, hash checks, atomic writes, the scene stamp | `fetch-data-lock.py`; from CMake `kataglyphis_fetch_data` | [`data-repositories.md`](data-repositories.md#the-hubs-fetcher) | a per-repo fetcher in bash, PowerShell, Python or CMake |
| A bash suite's asserts and its exit code | `t_case`, `t_assert_rc`, `t_assert_grep`, … `t_summary` | [`lib/test-harness.sh`](shared-script-libraries.md#libtest-harnesssh) | an `expect`/`check` pair and a `passed` counter per suite |
| Linux packaging (tar, deb, AppImage, Flatpak) | `package_archive.sh` | [`package_archive.sh`](../linux/scripts/06-packaging/package_archive.sh) | bespoke packaging |
| CI job plumbing | `prepare-linux-ci-host`, `run-in-linux-container`, `run-in-windows-container`, `clone-into-short-path`, `cleanup-disk-space`, `assert-docker-disk-space` | [`.github/actions/`](../.github/actions/README.md) | hand-written `docker run` blocks |
| Linting workflows locally | `lint-workflows.sh <root>` (pinned, SHA-verified actionlint) | [`lint-workflows.sh`](../linux/scripts/lint-workflows.sh) | bootstrapping your own |
| The agentic loop | config and runner templates | [`shared/agentic-loop/templates/`](../shared/agentic-loop/templates/README.md) | writing one from scratch |
| Bash helpers: logging, retry, SHA-checked downloads, parallelism | `logging.sh`, `downloads.sh`, `parallelism.sh`, … | [`linux/scripts/01-core/`](https://github.com/Kataglyphis/ANTfrastructure/tree/develop/linux/scripts/01-core) | new implementations |

Two caveats:

- **A module's own imports are private to it.** `WindowsBuild.Common` importing
  `WindowsScripts.Shared` does not re-export it to you. Import each module you call into directly,
  or the first run of that code path stops with "command not found".
- **Change the hub, not a local copy.** The same owner may edit this repo, but every consumer reads
  it: change it here, push, then move the consumer's pin.

### The rest of the naming rules, in one place

Small decisions that were folklore until 2026-09-15, one line each.

- **Version file.** Where a repo has one, it is `VERSION.txt` at the repo root, the default every
  entry point of
  [`02-toolchain/rust/version_util.sh`](../linux/scripts/02-toolchain/rust/version_util.sh)
  falls back to. A repo whose ecosystem already carries the version (a `pyproject.toml`, a
  `pubspec.yaml`, a workspace `Cargo.toml`) does not add a second one.
- **CHANGELOG** (owner, 2026-10-20). A repo with a release keeps `CHANGELOG.md`, because
  [`release-publish.yml`](../.github/workflows/release-publish.yml) takes each release's notes from
  its `## <version>` or `## [<version>]` section; one without a release (jotrockenmitlocken) needs
  none. A package published to a registry (PyPI, pub.dev, crates.io) keeps it at the package root,
  which the registry renders. ModelANT and AssetANT release per asset, with notes from its
  `model.json` or `asset.json`, and keep none.
- **Instruction file.** `AGENTS.md` is the **only** instruction file. Anything an agent-specific
  tool wants at its own path (`.github/copilot-instructions.md`, `CLAUDE.md`, a `.cursorrules`) is
  a two-line pointer to `AGENTS.md`, never a second copy: the copies drift, and the one nobody
  re-reads wins.
- **Sphinx layout.** Consumers keep their Sphinx sources under `docs/source/`, which is
  `docs-build.sh`'s default. This hub and DocumANTation are the exception: they keep
  `docs/conf.py` beside the pages.
- **Package names.** A package name is unique within its registry. Reusing one *across* registries
  is allowed only when the two artifacts are the same capability in two languages, and the reuse
  is recorded here. There is exactly one: `kataglyphis_inference` is OxidANT's `crates/inference`
  (an ONNX Runtime Rust crate) and AccelerANTgine's staged Python binding around the same C++
  inference path. Neither is published, the registries are disjoint, and they are two faces of one
  capability, so both keep the name. A third use, or a publish, reopens this.
- **Environment-variable prefixes.** `KATAGLYPHIS_*` for build/tree knobs shared by every family
  repo, `ANTFRASTRUCTURE_*` for knobs that configure this hub's own machinery (the pin suite, the
  shared-config sync), `AGENTIC_*` for the agentic loop, and the repo's own name for
  consumer-private knobs (`ORCHESTRANT_*`). The hub's registry gate
  ([`code-quality-tooling.md` § `env-knobs`](code-quality-tooling.md#env-knobs--a-stale-allow-row-always-fails))
  grades the hub's own knobs against that vocabulary.
- **Workflow files.** Kebab-case, one per platform and arch, display names
  `<Platform> <Arch> · <what>`: § 6,
  [Workflow file names and display names](#workflow-file-names-and-display-names).

### The pre-commit hook, by reference

A consumer gets the whole lint aggregator on every commit with one config line and no copied file:

```bash
git config core.hooksPath third_party/ANTfrastructure/shared/linux/templates/git-hooks
```

That directory holds a single `pre-commit` that `cd`s to the toplevel and runs
`run-lint-gates.sh` over it, and nothing hub-specific. It is **not** a `shared-assets.manifest`
row: a copied hook is a fork nobody re-syncs, and a stale hook is invisible because it keeps
passing. The hub's own versioned hooks under `linux/host-config/git-hooks/` are a different pair:
they `cd` into the hub layout, gate this repository's internals, and stay hub-only.

## 9. Quality gates

Every gate the hub runs over itself has a consumer-facing half; a consumer wires the items below
and gets all of it:

1. **The shared-asset manifest.** `.antfrastructure-shared.manifest` at the consumer root declares
   which hub-owned files the repo holds a copy of (configs, the two bootstrap templates);
   `sync-shared-config.sh --repo-root . --check` is the drift gate, `--write` refreshes. The
   registry of asset ids and the rules are in
   [`../shared/config/README.md`](../shared/config/README.md).
2. **The lint aggregator.** `bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh .`
   runs shellcheck, actionlint + CI image refs, gitleaks (with a self-test), ruff, the manifest
   drift check and the consumer pin-forwarding check, all from pinned and SHA-verified binaries:
   [`shared-script-libraries.md`](shared-script-libraries.md) § run-lint-gates.sh.
   Keep a ~5-line `scripts/linux/run-lint-gates.sh` wrapper so the dev-box command and the CI step
   are the same string, and call the reusable lane from CI:
   `jobs: lint: uses: Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@develop`
   (inputs: `exclude`, `submodules`, `hub-checkout` for a consumer without a submodule). Add
   `--ratchets` (the lane's `ratchets: true`) once the eight `<gate>.allow` freeze files are seeded
   and committed; that switches on the measurement gates (code size, complexity, dead functions,
   comment size, stdout returns, masked declarations, trailing conditionals, shellcheck warnings)
   over the consumer's own shell. The same step grades the consumer's pages against the hub's
   (`doc-dupes --against-hub`), off until `doc-dupes-hub.allow` is committed.
3. **The pin suite.** `Submodule.Pins.Tests.ps1` asserts every submodule sits at its recorded,
   remotely reachable commit; consumers call
   `uses: Kataglyphis/ANTfrastructure/.github/workflows/submodule-pins.yml@develop`
   (the AGENTS.md template's § 3 names the suite) instead of copying the job.
   **The generated-artifacts suite**, `shared/windows/tests/Repo.GeneratedArtifacts.Tests.ps1`,
   fails on a tracked file that `.gitignore` also excludes, and on one under the repo's
   generated-output pathspecs in `scripts/windows/generated-artifacts.txt` (one per line, `#`
   starts a comment). Run it with `run-pester-suite`, `path:` set to that suite under
   `third_party/ANTfrastructure/`, on a Windows runner checked out with `submodules: true`. A
   wildcard pathspec ending in `/` (`**/__pycache__/`, `build*/`) matches no file in git, so the
   suite refuses it: write `**/__pycache__/*`.
4. **Python repos** get the whole CI surface from the reusable
   `python-ci-linux.yml` / `python-ci-windows.yml` workflows: [`python-ci.md`](python-ci.md).
5. **The docs gates take `--root` too** (2026-09-15). `doc-links` runs in the `--ratchets` step
   (it has no freeze file, so it is safe the first time) and grades every tracked Markdown page,
   which puts a consumer's own `README.md` into the cross-reference graph. `doc-dupes` and
   `code-dupes` take `--root` as well, with budgets at `<root>/doc-dupes.allow` and
   `<root>/code-dupes.allow`, and stay off until a consumer seeds one: a duplication ratchet with
   no budget is red on its first run by construction.

Still hub-only: the hub's own git hooks; consumers get the hook of § 8
([The pre-commit hook, by reference](#the-pre-commit-hook-by-reference)).

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
- [ ] A Windows lane whose logic lives in one build script is a thin caller of `container-ci-windows.yml` (§ 6)
- [ ] Workflow files and display names follow § 6 (`linux-x64.yml`, `Linux x64 · …`)
- [ ] Consumer AGENTS.md links to these docs instead of restating them

### When the push is refused

`main` is usually protected, so the merge of
[Resolving a submodule conflict on merge](#resolving-a-submodule-conflict-on-merge) cannot be
pushed directly. Do not force it; put the result on a branch and open a PR:

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
