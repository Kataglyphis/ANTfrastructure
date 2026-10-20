#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The rust step runs before the base bakes versions.env, so a pin it reads without an ARG fails the chain at Dockerfile.base.

Describe 'Dockerfile.base: Install-RustToolchain.ps1 gets every pin it reads' {

    It 'declares each versions.env key the script reads as an ARG above its RUN, at the pinned value (mutation)' {
        $root = Get-RepoRoot
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path $root 'linux\scripts\01-core\versions.env')
        $script = [IO.File]::ReadAllText((Join-Path $root 'windows\scripts\host\Install-RustToolchain.ps1'))
        $read = @([regex]::Matches($script, '\$env:([A-Z][A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $pins.Contains($_) })
        Assert-True ($read -contains 'SCCACHE_DOWNLOAD_BASE') 'the scan sees the sccache pins'
        $base = [IO.File]::ReadAllText((Join-Path $root 'windows\Dockerfile.base'))
        $above = $base.Substring(0, $base.IndexOf("RUN & 'C:\temp\scripts\Install-RustToolchain.ps1'"))
        $missing = @($read | Where-Object { -not $above.Contains("ARG $_=$($pins[$_])") })
        Assert-Equal '' ($missing -join ', ') 'pins the script reads with no ARG at their value above the rust RUN'
    }
}
