#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Public Windows bases ship only PowerShell 5.1, so a pwsh SHELL fails every RUN with a misleading CreateProcess error.

Describe 'Dockerfiles: no pwsh SHELL before pwsh exists in the image' {

    It 'every public-base Dockerfile installs pwsh before switching SHELL to it' {
        $winRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $dockerfiles = @(Get-ChildItem -Path $winRoot -Recurse -File -Filter 'Dockerfile*' |
                Where-Object { $_.FullName -notmatch '\\archive\\' })
        Assert-True ($dockerfiles.Count -gt 0) 'no Dockerfiles found - the test is looking in the wrong place'

        $offenders = @()
        foreach ($f in $dockerfiles) {
            # Comments are blanked: one mentioning bootstrap-pwsh must not satisfy the check.
            $lines = Get-Content -LiteralPath $f.FullName | ForEach-Object {
                if ($_ -match '^\s*#') { '' } else { $_ }
            }

            # A local or earlier-stage FROM inherits whatever that stage installed.
            $fromPublic = $false
            foreach ($l in $lines) {
                if ($l -match '^\s*(ARG\s+BASE=|FROM\s+)') {
                    if ($l -match 'mcr\.microsoft\.com/windows/(servercore|nanoserver)') { $fromPublic = $true }
                }
            }
            if (-not $fromPublic) { continue }

            $shellIdx = -1
            $installIdx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($shellIdx -lt 0 -and $lines[$i] -match '^\s*SHELL\s*\[\s*"pwsh"') { $shellIdx = $i }
                # Anything that puts pwsh into the image before that point.
                if ($installIdx -lt 0 -and $lines[$i] -match 'bootstrap-pwsh|PWSH_ZIP|PWSH_VERSION') { $installIdx = $i }
            }

            if ($shellIdx -ge 0 -and ($installIdx -lt 0 -or $installIdx -gt $shellIdx)) {
                $offenders += ('{0} (line {1}: pwsh SHELL on a public base with no pwsh install before it)' -f
                    $f.FullName.Replace($winRoot, ''), ($shellIdx + 1))
            }
        }

        Assert-Equal 0 $offenders.Count ("pwsh SHELL before pwsh exists:`n  " + ($offenders -join "`n  "))
    }

    It 'the isolation probe in particular uses the 5.1 shell' {
        # This probe decides the isolation mode, so a broken shell here manufactures a verdict.
        $probe = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\diagnostics\Dockerfile.isolation-probe'
        Assert-True (Test-Path $probe) "isolation probe Dockerfile not found at $probe"
        $raw = Get-Content -Raw $probe
        Assert-Match '(?m)^SHELL \["powershell"' $raw 'the isolation probe no longer uses the always-present 5.1 shell'
        Assert-False ($raw -match '(?m)^SHELL \["pwsh"') 'the isolation probe is back on a pwsh SHELL its base image does not have'
    }
}
