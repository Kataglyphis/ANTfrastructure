#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# No -Force in scripts the chain runs in-process: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level

Describe 'chain-invoked build scripts: no -Force module imports' {

    It 'no script that a chain runs in-process re-imports a module with -Force' {
        $buildDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build'
        Assert-True (Test-Path $buildDir) "build script dir not found: $buildDir"

        # Everything reachable from a $stages table, i.e. anything running while a module function is on the stack.
        $entrypoints = @(Get-ChildItem -Path $buildDir -Filter 'Build-*All.ps1' -File)
        $stageScripts = @()
        foreach ($e in $entrypoints) {
            $raw = Get-Content -Raw $e.FullName
            $stageScripts += [regex]::Matches($raw, "Script\s*=\s*'([^']+\.ps1)'") |
                ForEach-Object { $_.Groups[1].Value }
        }
        $stageScripts = @($stageScripts | Sort-Object -Unique)
        Assert-True ($stageScripts.Count -gt 0) 'no stage scripts discovered - the $stages shape changed, this test would pass vacuously'

        $offenders = @()
        foreach ($name in $stageScripts) {
            $p = Join-Path $buildDir $name
            if (-not (Test-Path $p)) { continue }
            $hits = @(Select-String -Path $p -Pattern '^\s*Import-Module\s+\$\w+.*-Force')
            foreach ($h in $hits) {
                $offenders += ('{0}:{1}  {2}' -f $name, $h.LineNumber, $h.Line.Trim())
            }
        }

        Assert-Equal 0 $offenders.Count (
            "-Force import in a chain-invoked script destroys the RUNNING module instance:`n  " +
            ($offenders -join "`n  ") +
            "`n  Use: if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension(`$path)))) { Import-Module `$path }")
    }

    It 'the guarded pattern is actually in place in the leaf builders' {
        # Rot guard: if the leaves stopped importing modules the test above would prove nothing.
        $buildDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build'
        $guarded = @(Select-String -Path (Join-Path $buildDir 'Build-*FromSource.ps1') `
                -Pattern 'if \(-not \(Get-Module -Name .*\)\) \{ Import-Module')
        Assert-True ($guarded.Count -ge 5) "expected the guarded import in the leaf builders, found $($guarded.Count)"
    }
}
