# Adopting ContainerHub in a New Project

This repo is not only a set of Dockerfiles. It ships the build/run/automation
tooling that consuming projects import instead of copying: Windows container
builds (Stevedore), Linux container builds (Rancher Desktop / CI), the
planner–executor agentic loop, reusable PowerShell modules and bash libraries,
and CI composite actions.

This page is the checklist for wiring a **new** project to all of it.
Kataglyphis-BeschleunigerBallett is the reference consumer — when a detail here
is ambiguous, read how that repo does it.

## 0. Add the submodule

```bash
git submodule add https://github.com/Kataglyphis/Kataglyphis-ContainerHub.git ExternalLib/Kataglyphis-ContainerHub
git submodule update --init --recursive
```

Everything below assumes that path. Consumers pin a commit like any other
submodule; bump the pin and the consuming change in the same commit, and push
ContainerHub `main` **before** the consumer, because CI resolves composite
actions at `@main`.

## 1. The one file that cannot live here

Each consumer needs a tiny bootstrap that *finds* this submodule, since it runs
before anything upstream is importable. Copy
[`shared/windows/templates/Resolve-BuildModule.ps1`](../shared/windows/templates/README.md)
to `Scripts/Windows/Resolve-BuildModule.ps1` (or `scripts/windows/`, matching
your repo's casing) and adjust `$script:RepoRootRelativeToHere` if the script
does not sit exactly two directories below the repo root. It resolves a module
name to
`ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/<Name>.psm1`
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
`ExternalLib/Kataglyphis-ContainerHub/linux/scripts/lib/app-runner.sh`. Resolve
that path from `${BASH_SOURCE[0]}` rather than assuming the caller's working
directory is the repo root, and fail loudly (naming the
`git submodule update --init --recursive` command) when the submodule is not
checked out. Kataglyphis-Inference-Engine's `scripts/linux/lib/containerhub.sh`
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

Read [`windows-container-build-performance.md`](windows-container-build-performance.md)
before designing your flow — it documents both transports and their setup, why
the build tree must not live on a named volume, the Windows path limit that
silently truncates tar transfers, and the container-reuse measurements.

Two rules that cost real debugging time to learn:

- **Mount/stream to the same in-container path under every transport.** CMake
  bakes absolute paths into `CMakeCache.txt` and rejects a cache generated
  elsewhere.
- **A green build is not proof of delivery.** Always end with
  `Test-BuildArtifactsDelivered`; both "built nothing" and "delivered nothing"
  have happened silently.

## 3. Linux container builds (Rancher Desktop / CI)

Image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.

Local runs go through Rancher Desktop's `nerdctl`. From Git Bash you must
disable path mangling or the mount argument is destroyed:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' rdctl shell nerdctl run --rm --user root \
  -v cargo-cache:/cargo-cache \
  -v /mnt/d/path/to/repo:/workspace -w /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  bash -c 'bash Scripts/Linux/cmake-configure-build.sh --preset <preset> --build-dir /tmp/build --cargo-cache-dir /cargo-cache'
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
   `Scripts/AgenticLoop/AgenticLoop.config.json`): `engine`, per-engine model
   and prompt settings under `engines.*`, cadences and timeouts under
   `intervals.*`, per-platform `buildMatrix.{windows,linux}` entries
   (`name`/`sanitizer`/`buildDir`/`buildType`/`testCommand`), `build.*`
   commands, `git.*` auto-commit settings, `backlog.*` policy, `logging.logDir`.
3. **Thin runner wrappers** — `Run-AgenticLoop.ps1` / `.sh`. These load the
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
`Kataglyphis/Kataglyphis-ContainerHub/.github/actions/<name>@main`:

| Action | Use |
|---|---|
| `run-in-linux-container` | One `docker run` in the Linux image, optional `tee` log and extra args |
| `run-in-windows-container` | Same for the Windows image (CPU clamp, bind mount, pwsh payload) |
| `cleanup-disk-space` | Free space on Windows runners |

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

## Checklist

- [ ] Submodule added; `Resolve-BuildModule.ps1` copied
- [ ] Windows build script built on `WindowsContainerBuild.Reuse`, ending in a delivery check
- [ ] Linux build uses a container-native build dir and a cargo cache volume
- [ ] No consumer copy of anything that exists upstream (check before writing)
- [ ] `BACKLOG.md` + loop config + thin runners in place, prompts left upstream
- [ ] Workflows call the composite actions
- [ ] Consumer AGENTS.md links to these docs instead of restating them
