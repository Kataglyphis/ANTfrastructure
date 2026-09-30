#requires -Version 7.0
# Export-ModuleMember skips absent names silently, so a fresh child pwsh imports only this module and every export must resolve.

Describe 'WindowsSourceBuild.Common re-export integrity (fresh session)' {

    It 'every exported name resolves after a cold import' {
        $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSourceBuild.Common.psm1'
        Assert-True (Test-Path $modPath) "module not found at $modPath"

        # Parsed from the file, so a name added to Export-ModuleMember is covered automatically.
        $raw = Get-Content -Raw $modPath
        # From Export-ModuleMember on, or any quoted Verb-Noun line in the file would match.
        $raw = $raw.Substring($raw.IndexOf('Export-ModuleMember'))
        $names = [regex]::Matches($raw, "(?m)^\s*'([A-Za-z]+(?:-[A-Za-z0-9]+)+)',?\s*$") |
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
