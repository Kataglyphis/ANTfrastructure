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
repo's `Scripts/Linux/setup-dependencies.sh` (skipped with a warning when
absent); `install-uv: true` installs the Astral uv package manager.

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
