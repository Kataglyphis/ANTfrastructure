#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The smoke gate has TWO floors and they drifted apart unnoticed:
#   * per-section floors ($sectionFloors in smoke-test-container.ps1), lane-aware
#   * one global floor (-SmokeMinPassed, passed as MIN_PASSED by the drivers)
# On 2026-08-22 the global floor was 160 on BOTH lanes while the GPU sections
# alone floor at 190 — i.e. the global gate could not fire before the section
# gates did, and a GPU run could lose 60 of its 220 assertions unnoticed.
# A floor nobody can reach is decoration.
#
# This pins the relationship rather than the numbers: the global floor must not
# exceed the section floors of the lane it guards (or it fails runs that are
# legitimately at floor), and must not be so far below them that it is inert.

Describe 'smoke gate: the global floor is calibrated against the section floors' {

    It 'section floors parse and cover both lanes' {
        $s = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\smoke-test-container.ps1'
        Assert-True (Test-Path $s) "smoke test not found: $s"
        $block = [regex]::Match((Get-Content -Raw $s), '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        $pairs = [regex]::Matches($block, "'(\d+)'\s*=\s*@\((\d+),\s*(\d+)\)")
        Assert-True ($pairs.Count -ge 20) "expected the full section floor table, parsed $($pairs.Count) entries"
    }

    It 'the GPU floor the driver sends is neither above nor far below the section sum' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $s = Join-Path $root 'scripts\build\smoke-test-container.ps1'
        $block = [regex]::Match((Get-Content -Raw $s), '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        $pairs = [regex]::Matches($block, "'(\d+)'\s*=\s*@\((\d+),\s*(\d+)\)")
        $gpuSum = ($pairs | ForEach-Object { [int]$_.Groups[2].Value } | Measure-Object -Sum).Sum
        $cpuSum = ($pairs | ForEach-Object { [int]$_.Groups[3].Value } | Measure-Object -Sum).Sum

        $driver = Get-Content -Raw (Join-Path $root 'build-buildkit.ps1')
        $gpuFloor = [int][regex]::Match($driver, '\$effectiveMinPassed\s*=\s*(\d+)').Groups[1].Value
        $cpuFloor = [int][regex]::Match($driver, '\[int\]\$SmokeMinPassed\s*=\s*(\d+)').Groups[1].Value

        Assert-True ($gpuFloor -gt 0) 'the GPU lane floor is gone from build-buildkit.ps1'
        # Must not exceed the section sum: a run sitting exactly at every section
        # floor is legitimate and must not be failed by the global gate.
        Assert-True ($gpuFloor -le $gpuSum) "GPU global floor $gpuFloor exceeds the sum of the GPU section floors ($gpuSum)"
        Assert-True ($cpuFloor -le $cpuSum) "CPU global floor $cpuFloor exceeds the sum of the CPU section floors ($cpuSum)"
        # ...and must stay within reach of them, or it never fires.
        Assert-True ($gpuFloor -ge [int]($gpuSum * 0.9)) "GPU global floor $gpuFloor is inert against a section sum of $gpuSum"
        Assert-True ($cpuFloor -ge [int]($cpuSum * 0.9)) "CPU global floor $cpuFloor is inert against a section sum of $cpuSum"
    }
}
