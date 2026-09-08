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
`third_party/ContainerHub/windows/scripts/modules/<Name>.psm1`
**first**, then `<script dir>/modules/<Name>.psm1`, and throws naming both
paths when neither exists (the message includes the `git submodule update`
command, because that is nearly always the cause).

Put a module upstream and it wins automatically — a consumer can therefore
never keep silently building against a stale vendored copy. Keep only
genuinely project-specific modules in the local fallback directory; if two
consumers need it, it belongs here instead.

## Reaching the dot-sourced helpers

`Resolve-BuildModule` honours an explicit `.psm1` **or `.ps1`** extension and
appends `.psm1` only to a bare name. The `.ps1` arm exists for one file:
`windows/scripts/modules/Initialize-CiEnvironment.ps1`, which owns `New-CiSession`
and the `Write-CiLog*` / `Close-CiLog` family. Because the resolver used to append
`.psm1` unconditionally, that file was unreachable through the resolver and every
consumer hand-rolled the same CI-session preamble on top of the same modules.

```powershell
. (Resolve-BuildModule -Name 'Initialize-CiEnvironment.ps1')
$session = New-CiSession -RepoRoot $repoRoot -WithUvDelegates
```

`Import-BuildModule` **throws** on a `.ps1` rather than importing it: `Import-Module`
on a plain script runs it in a throwaway scope and defines nothing for the caller —
a silent no-op, which is worse than an error.

## Reconciliation record (2026-09-08)

Four copies existed — this template plus one each in BeschleunigerBallett,
OmniAccelerANT and OrchestrANT — and an audit reported "three distinct contents".
Measured, the picture is narrower and the fix is smaller:

| Copy | Body (`Set-StrictMode` onward) | Delta |
|---|---|---|
| `shared/windows/templates/Resolve-BuildModule.ps1` | sha `22f097e8` | — (owner) |
| BeschleunigerBallett `scripts/windows/` | sha `22f097e8` | header prose; **working tree is LF** while its own `.gitattributes` says `*.ps1 text eol=crlf` |
| OmniAccelerANT `scripts/windows/` | sha `22f097e8` | header prose (byte-identical to BB's apart from line endings) |
| OrchestrANT `scripts/windows/` | sha `22f097e8` | header prose + a "LOCAL DELTA vs the template" paragraph |

**Every body is byte-identical.** There was no behavioural drift to reconcile: the
three consumer deltas are all header comment, and the only mechanical difference is
BeschleunigerBallett's LF working-tree copy. Nothing in any consumer delta needs
preserving on a re-sync — a consumer adopting the new body can copy from
`Set-StrictMode` down and keep its own header. OrchestrANT's paragraph already says
exactly that, and it stays true.

The genuine drift was in the OTHER direction: this template had grown the
`ADJUST $script:RepoRootRelativeToHere` note that no consumer carries, and none of
the four could reach a `.ps1` helper. The second half is the change above.
