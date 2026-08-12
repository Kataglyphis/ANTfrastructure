# Windows consumer templates

Copy-and-edit starting points for a project adopting this repo's Windows build
modules.

| File | Copy to | Then |
|---|---|---|
| `Resolve-BuildModule.ps1` | `scripts/windows/Resolve-BuildModule.ps1` (or `scripts/windows/`) | Adjust `$script:RepoRootRelativeToHere` if the script does not sit exactly two directories below the repo root. Nothing else. |

## Why this one file is copied rather than imported

It is the bootstrap: it *finds* the submodule, so it necessarily runs before
anything in the submodule is importable. Everything else a consumer needs
belongs in `windows/scripts/modules/` and is resolved *through* it.

The template exists because the four consumers had each written this file
independently and they had drifted — different search orders, different error
text, one missing `-Global` on the import. One copied file is fine; four
different ones is the failure mode.

## The contract

```powershell
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')

Import-BuildModule @(
    'WindowsScripts.Shared'   # dependency order matters: Shared first,
    'WindowsBuild.Common'     # then Build, then everything built on them
    'WindowsCMake.Common'
    'MyProject.Paths'         # project-specific -> scripts/windows/modules/
)
```

`Resolve-BuildModule <Name>` probes
`ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/<Name>.psm1`
**first**, then `<script dir>/modules/<Name>.psm1`, and throws naming both
paths when neither exists (the message includes the `git submodule update`
command, because that is nearly always the cause).

Put a module upstream and it wins automatically — a consumer can therefore
never keep silently building against a stale vendored copy. Keep only
genuinely project-specific modules in the local fallback directory; if two
consumers need it, it belongs here instead.
