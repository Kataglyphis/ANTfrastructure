# Reusable GitHub composite actions

Shared, project-agnostic composite actions so every Kataglyphis repo can reuse
them instead of copy-pasting. This repo is **public**, so reference them
cross-repo with the fully-qualified path:

```yaml
- name: Cleanup disk space
  uses: Kataglyphis/Kataglyphis-ContainerHub/.github/actions/cleanup-disk-space@main
```

Pin `@main` for latest, or `@<sha>` for reproducibility.

## Available actions

### `cleanup-disk-space`
Aggressively frees space on **Windows** runners so large container images (e.g.
the ~54 GB `:winamd64`) can be pulled/imported. Removes Visual Studio, the whole
`hostedtoolcache`, dotnet, SDKs, DB engines, host toolchains, caches, and prunes
Docker, then prints per-drive free space before and after. Fully self-contained
(pure PowerShell) — no inputs, no consumer-repo dependencies. Best-effort:
individual removals never fail the job (`exit 0`).

### `install-deps`
Prepares a Linux runner's toolchain PATH: cargo/rustup (installs a stable
default toolchain when missing), the Vulkan SDK bin dir (input
`vulkan-version` — pass it explicitly; the default can drift from
ContainerHub's `versions.env`, which composite actions cannot read, and has
drifted before), plus packaging utilities. `require-rust` (default `'true'`)
controls the rustc gate: with `'false'` the Rust toolchain block is skipped
with a notice instead of failing, so uv-only consumers can use the action on
runners without Rust. Optional: `run-setup-script: true` runs the consuming
repo's `scripts/linux/setup-dependencies.sh` (skipped with a warning when
absent); `install-uv: true` installs the Astral uv package manager.

### `set-docker-data-root`
Points the Docker daemon's data-root at another drive **before the image is
pulled**, so a multi-GB Windows image lands where there is room. Inputs:
`data-root` (default `D:\docker`), `service-name`, `required-free-gb`,
`ready-timeout-seconds`. Outputs: `data-root`, `free-gb`.

Why it exists, measured on a windows-2025 runner 2026-08-11:

```
DriveLetter FreeGB SizeGB FileSystemLabel
          C  29.90 149.40 Windows
          D 219.50 220.00 Temp
```

Docker on Windows keeps its data-root under the system drive, and the winamd64
image needs ~54 GB to import — more than C: has. `cleanup-disk-space` claws C:
back to ~68 GB by deleting Visual Studio and the tool caches, which works but is
destructive and slow, and leaves a 220 GB drive at 219.5 GB free.

Order matters: run it **before** the pull. Changing the data-root makes images
under the old one invisible — harmless on a fresh runner, wasteful after a pull.
It merges into any existing `daemon.json` rather than overwriting it, so runner
defaults (mirrors, log options) survive. On a self-hosted runner set `data-root`
to somewhere persistent; `D:` on a hosted runner is the ephemeral temp disk and
is wiped between jobs.

### `assert-docker-disk-space`
Resolves the Docker daemon's data-root and fails FAST when its drive has less
free space than a large image import needs, instead of letting `docker pull`
grind ~40 minutes into hcsshim::ImportLayer "not enough space on the disk
(0x70)". Inputs: `required-free-gb` (required), `fallback-data-root`,
`probe-attempts`, `probe-interval-seconds`. Outputs: `data-root`, `free-gb`.

Complements `set-docker-data-root`: move the data-root first, then assert the
drive it now lives on is big enough.

Do not simplify the probe back to a one-shot `docker info --format
'{{.DockerRootDir}}' 2>$null`. On runner image win25-vs2026/20260728.188 that
returns an empty string and a non-zero exit (it printed the path on
20260714.173), `2>$null` hides the reason, and the GitHub pwsh wrapper's
trailing `exit $LASTEXITCODE` turns the failed QUERY into the STEP's result -
a real pipeline died of exactly that on 2026-08-05 with the gate itself happy.

### `clone-into-short-path`
Clones the repo and submodules into a short directory (default `/d/ws`) because
actions/checkout cannot on Windows with a deep submodule chain: the workspace is
`D:\<repo>\<repo>` before any content, and `.git/modules/.../config` then
passes 260 characters, which `core.longpaths` does not reliably bypass for
child clones. Also rewrites `git@github.com:` submodule URLs to token HTTPS,
since a hosted runner has no SSH key. Inputs: `token` (required), `target`,
`repository`, `ref`, `submodules`.

### `run-pester-suite`
Installs a PINNED Pester and runs a suite, printing Describe/Name plus the
assertion's `FailureMessage` and `StackTrace` for every failure - the test name
alone costs a round trip to learn what was compared. Pinning matters because
Pester 3.x and 5.x are different dialects: a 3.4 suite (`Should Be 0`) does not
parse under the Pester 5 on the runner. Inputs: `path` (required), `version`.

### `prepare-linux-ci-host`
The prologue every containerised Linux job repeats: free runner disk, check
out (submodules recursive, full history by default), log in to the registry
and `docker pull` the image with retries and a per-attempt timeout.
Inputs: `image` (required), `registry`, `registry-username`,
`registry-password` (login is skipped when empty, so fork PRs without secrets
still pull public images), `fetch-depth`, `submodules`, `checkout`,
`free-disk-space`, `pull-attempts`, `pull-timeout-seconds`.

Written for **fan-out**: a pipeline that splits its builds across parallel
jobs pays this prologue once per job, so the four steps stop being
boilerplate in one place and become boilerplate in ten - and drift between
those copies (a different retry count, a missing submodule flag) produces
failures that reproduce in only one lane.

### `run-in-linux-container`
Runs a bash command inside a Linux container image (`docker run --rm`).
Inputs: `image` (required), `script` (bash fragment, verbatim), `workdir`,
`log-file` (tee target), `extra-args` (verbatim extra `docker run` args).
Used by consumer repos to run their build/test steps inside the published
`:latest-cross` images.

> **Warning — script injection surface:** `script`, `extra-args` and
> `log-file` are substituted **verbatim** into the action's `run:` block.
> Never feed untrusted text (PR titles/bodies, fork branch names, issue
> content, ...) into these inputs — it would execute as shell on the runner.
> The Windows sibling delivers its payload via environment variables and does
> not share this surface.

### `run-in-windows-container`
Runs PowerShell inside a Windows container image. Exactly one of `command`
(pwsh `-Command`) or `file` (pwsh `-File`, with `file-args` — ONE argv element
per line) must be set; the payload travels via `env:` so secret values never
pass through the PowerShell parser (an apostrophe in a secret used to be a
`ParserError`). `extra-args` is also one-argv-per-line (unlike the Linux
sibling's verbatim fragment — Windows argv must stay literal). Other inputs:
`cpus` (default: all runner CPUs, min 2), `memory` (default `16g`),
`mount-source`/`mount-target` (default `D:\ws` → `C:\ws`). Values containing
newlines cannot be expressed in the per-line inputs.

## Adding a new reusable action
Create `.github/actions/<name>/action.yml` here, keep it self-contained (no
hard-coded consumer paths unless input-gated), and reference it cross-repo as
above.
