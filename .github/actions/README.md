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
Installs the Vulkan SDK (input `vulkan-version`, default `1.4.321.1`) and,
optionally (`run-setup-script: true`), runs the consuming repo's
`Scripts/Linux/setup-dependencies.sh`. The setup-script step is repo-specific;
leave it off for repos that don't ship that script.

## Adding a new reusable action
Create `.github/actions/<name>/action.yml` here, keep it self-contained (no
hard-coded consumer paths unless input-gated), and reference it cross-repo as
above.
