#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# `SHELL ["pwsh", ...]` on a PUBLIC Windows base image is a silent trap: the
# servercore/nanoserver images ship Windows PowerShell 5.1 ONLY - pwsh arrives
# later in the real chain via Initialize-Pwsh.ps1. Every RUN under such a SHELL
# dies with `hcs::System::CreateProcess ... The system cannot find the file
# specified`, which does not look like "wrong shell" at all.
#
# Why this is a GUARD and not just a fixed bug (2026-08-21): the isolation
# probe had exactly this defect, so `docker build --isolation process` always
# failed, the driver read that as "this host cannot commit process-isolated
# layers", and EVERY classic-lane build silently fell back to Hyper-V
# isolation - 2 CPUs on a 32-core host, for months of builds, with only a
# WARNING line to show for it. A probe that cannot run is worse than no probe:
# it manufactures a verdict. AGENTS.md records two earlier bugs of this same
# pwsh-in-probe class in probe-build-copy (2026-08-10); this is the third, so
# it gets a test rather than another fix.

Describe 'Dockerfiles: no pwsh SHELL before pwsh exists in the image' {

    It 'every public-base Dockerfile installs pwsh before switching SHELL to it' {
        $winRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $dockerfiles = @(Get-ChildItem -Path $winRoot -Recurse -File -Filter 'Dockerfile*' |
                Where-Object { $_.FullName -notmatch '\\archive\\' })
        Assert-True ($dockerfiles.Count -gt 0) 'no Dockerfiles found - the test is looking in the wrong place'

        $offenders = @()
        foreach ($f in $dockerfiles) {
            # COMMENTS ARE NOT INSTRUCTIONS. Blanked before scanning: the first
            # cut of this test passed on a file that still had the bug, because
            # a comment ABOVE the SHELL line mentioned bootstrap-pwsh and that
            # was enough to satisfy the "pwsh gets installed first" condition.
            $lines = Get-Content -LiteralPath $f.FullName | ForEach-Object {
                if ($_ -match '^\s*#') { '' } else { $_ }
            }

            # Only PUBLIC bases are affected: a FROM local/... or a FROM of an
            # earlier stage inherits whatever that stage installed.
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
        # The specific regression: this probe decides the isolation mode for
        # every classic-lane build, so a broken shell here is expensive.
        $probe = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\diagnostics\Dockerfile.isolation-probe'
        Assert-True (Test-Path $probe) "isolation probe Dockerfile not found at $probe"
        $raw = Get-Content -Raw $probe
        Assert-Match '(?m)^SHELL \["powershell"' $raw 'the isolation probe no longer uses the always-present 5.1 shell'
        Assert-False ($raw -match '(?m)^SHELL \["pwsh"') 'the isolation probe is back on a pwsh SHELL its base image does not have'
    }
}
