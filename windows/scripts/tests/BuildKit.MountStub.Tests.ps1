#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: mounts outside C:\temp\scripts, and stages FROM another stage than base (graded against base's files only).

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

Describe 'BuildKit bind-mount targets' {
    function Add-CopiedScriptPath {
        param([string]$Line, [hashtable]$Present)
        if ($Line -notmatch '^COPY\s' -or $Line -match '--from=') { return }
        $parts = @(($Line -replace '^COPY\s+', '') -split '\s+' | Where-Object { $_ -and $_ -notmatch '^--' })
        $dest = $parts[-1]
        foreach ($source in $parts[0..($parts.Count - 2)]) {
            $leaf = Split-Path ($source -replace '/', '\') -Leaf
            if ($leaf -notmatch '\.') { $Present[$dest.TrimEnd('\') + '\'] = 'dir' }
            elseif ($dest.EndsWith('\')) { $Present[$dest + $leaf] = 'file' }
            else { $Present[$dest] = 'file' }
        }
    }

    function Test-ScriptPathPresent {
        param([string]$Target, [hashtable]$Present)
        if ($Present.ContainsKey($Target)) { return $true }
        return [bool]@($Present.Keys | Where-Object { $Present[$_] -eq 'dir' -and $Target.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
    }

    function Get-MountStubViolation {
        param([string]$BaseText, [hashtable]$Dockerfiles)
        $fromBase = @{}
        foreach ($line in (ConvertTo-TestDockerLogicalLine -Text $BaseText)) { Add-CopiedScriptPath -Line $line -Present $fromBase }
        foreach ($name in ($Dockerfiles.Keys | Sort-Object)) {
            $present = @{} + $fromBase
            foreach ($line in (ConvertTo-TestDockerLogicalLine -Text $Dockerfiles[$name])) {
                if ($line -match '^FROM\s') { $present = @{} + $fromBase; continue }
                Add-CopiedScriptPath -Line $line -Present $present
                if ($line -notmatch '^RUN\s') { continue }
                foreach ($m in [regex]::Matches($line, 'type=bind,(?:from=[^,]+,)?source=[^,\s]+,target=(C:\\temp\\scripts\\[^\s,`]+)')) {
                    if (-not (Test-ScriptPathPresent -Target $m.Groups[1].Value -Present $present)) { "${name}: $($m.Groups[1].Value)" }
                }
            }
        }
    }

    It 'binds no file under C:\temp\scripts that the image lacks, which would leave a directory final cannot replace (mutation)' {
        $windows = Join-Path (Get-RepoRoot) 'windows'
        $base = [IO.File]::ReadAllText((Join-Path $windows 'Dockerfile.base'))
        $files = @{}
        Get-ChildItem $windows -Filter 'Dockerfile*' -File | Where-Object Name -NE 'Dockerfile.base' |
            ForEach-Object { $files[$_.Name] = [IO.File]::ReadAllText($_.FullName) }
        $mounts = @($files.Values | ForEach-Object { [regex]::Matches($_, 'target=C:\\temp\\scripts\\') } )
        Assert-True ($mounts.Count -ge 2) 'the scan reaches the module mounts it grades'
        Assert-Equal '' (@(Get-MountStubViolation -BaseText $base -Dockerfiles $files) -join "`n") 'every bind target already exists in its stage'

        $fixtureBase = "FROM x`nCOPY windows\scripts\modules\A.psm1 C:\temp\scripts\modules\"
        $stub = "FROM y AS one`nCOPY m\B.psm1 C:\temp\scripts\modules\`nFROM y`nRUN --mount=type=bind,source=m/A.psm1,target=C:\temp\scripts\modules\A.psm1 --mount=type=bind,source=m/B.psm1,target=C:\temp\scripts\modules\B.psm1 x"
        Assert-Equal 'stub: C:\temp\scripts\modules\B.psm1' (@(Get-MountStubViolation -BaseText $fixtureBase -Dockerfiles @{ stub = $stub }) -join "`n") 'a copy in another stage does not count'
        $copied = "FROM y`nCOPY windows\scripts C:\temp\scripts`nRUN --mount=type=bind,source=m/B.psm1,target=C:\temp\scripts\modules\B.psm1 x"
        Assert-Equal 0 @(Get-MountStubViolation -BaseText $fixtureBase -Dockerfiles @{ copied = $copied }).Count 'a directory copy covers the files below it'
    }
}
