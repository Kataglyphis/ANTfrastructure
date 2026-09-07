#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# `Import-Module <repo module> -Force` inside a script that the build chain
# invokes IN-PROCESS is a delayed-action bug, and an expensive one.
#
# 2026-08-21, media-core/ONNX: the chain entrypoint imported
# WindowsSourceBuild.Common with -Force (module instance M1) and called
# Invoke-SourceBuildChain, which runs the leaf builders in-process
# (`& (Join-Path $ScriptDir $stage.Script)`). Build-OnnxFromSource.ps1 then
# did its own `Import-Module ... -Force`, which REMOVES M1 while
# Invoke-SourceBuildChain is still on the stack. ONNX compiled fine for 53
# minutes; the chain tail then died on
#   The term 'Stop-LingeringBuildProcess' is not recognized
# because that helper is deliberately UNEXPORTED and only ever lived in M1's
# scope. The exported call one line above it (Write-SccacheStats) still worked
# — it resolves through the global command table — which is exactly what makes
# this so confusing to read in a log.
#
# The repo already banned -Force for the nested imports INSIDE modules
# (2026-08-04). This extends the same rule to the scripts the chain invokes,
# which is where it actually bit.

Describe 'chain-invoked build scripts: no -Force module imports' {

    It 'no script that a chain runs in-process re-imports a module with -Force' {
        $buildDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build'
        Assert-True (Test-Path $buildDir) "build script dir not found: $buildDir"

        # The leaf builders + their chain entrypoints: everything reachable
        # from a $stages table, i.e. everything that can be running while a
        # module function is on the stack.
        # 'Build-*All.ps1', not 'build-*-all.ps1': the build scripts were
        # renamed to Verb-Noun in the approved-verb sweep and this glob was left
        # on the old kebab-case shape, so it matched nothing. The Assert-True
        # below is exactly the rot guard for that and did its job -- it went red
        # instead of passing vacuously. Same story for the sibling glob below.
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
        # Rot guard: if the leaves stopped importing modules altogether the
        # test above would pass while proving nothing.
        $buildDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build'
        $guarded = @(Select-String -Path (Join-Path $buildDir 'Build-*FromSource.ps1') `
                -Pattern 'if \(-not \(Get-Module -Name .*\)\) \{ Import-Module')
        Assert-True ($guarded.Count -ge 5) "expected the guarded import in the leaf builders, found $($guarded.Count)"
    }
}
