#requires -Version 7.0
# WindowsSourceBuild.Common re-exports ~22 names it does not define (from
# Shared/Cuda/Patches/Native), and its nested imports are CONDITIONALLY
# skipped when the module is already loaded — so Export-ModuleMember can
# silently no-op on an absent name depending on load order. That class
# produced two production CommandNotFound incidents (the module's own
# comments record them). This suite is the deterministic version of that
# check: a FRESH child pwsh imports ONLY WindowsSourceBuild.Common and
# every name in its export list must resolve. In-process would be useless —
# this session's earlier imports are exactly the pollution being tested for.

Describe 'WindowsSourceBuild.Common re-export integrity (fresh session)' {

    It 'every exported name resolves after a cold import' {
        $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSourceBuild.Common.psm1'
        Assert-True (Test-Path $modPath) "module not found at $modPath"

        # The export list, parsed from the file (self-updating: a name added
        # to Export-ModuleMember is automatically covered here).
        $raw = Get-Content -Raw $modPath
        $names = [regex]::Matches($raw, "(?m)^\s*'([A-Za-z]+-[A-Za-z0-9]+)',?\s*$") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        Assert-True ($names.Count -ge 40) "parsed only $($names.Count) export names — the Export-ModuleMember layout changed; update this parser"

        $probe = @"
Import-Module '$modPath' -Force -DisableNameChecking
`$missing = @('$($names -join "','")') | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) }
if (`$missing) { `$missing -join ','; exit 1 }
exit 0
"@
        $out = & pwsh -NoProfile -NonInteractive -Command $probe 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ("exported names missing after cold import (the silent re-export no-op class): " + $out.Trim())
    }
}
