#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Renames the extracted TensorRT-<version>\ tree to a stable 'current\'; see docs/windows-builds.md § Set-TensorrtTree.ps1.
[CmdletBinding()]
param(
    [string]$TensorRtRoot = 'C:\tensorrt',
    # Reported only — never used to build a path.
    [string]$ExpectedVersion = $env:TENSORRT_VERSION
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stable = Join-Path $TensorRtRoot 'current'
# Skips the rename, never the DLL gate.
$alreadyStable = $false

if (-not (Test-Path $TensorRtRoot)) {
    Write-Host "TensorRT: '$TensorRtRoot' absent -> nothing to normalize (EP skipped downstream)."
    return
}
if (Test-Path $stable) {
    # No return: a pre-existing or half-populated 'current' must still pass the DLL gate.
    Write-Host "TensorRT: '$stable' already present -> verifying it rather than re-normalizing."
    $alreadyStable = $true
    $versionDir = $null
}

# Newest by [version]: a string sort ranks 11.2.1.2 above 11.10.0.1; matches Dockerfile.nvidia's zip selection.
if (-not $alreadyStable) {
    $versionDir = Get-ChildItem -LiteralPath $TensorRtRoot -Directory -Filter 'TensorRT-*' -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = {
                $v = $_.Name -replace '^TensorRT-', ''
                if ($v -match '^\d+(\.\d+)+$') { [version]$v } else { [version]'0.0' }
            }
        } -Descending | Select-Object -First 1
}

if (-not $alreadyStable -and -not $versionDir) {
    # Dockerfile.nvidia's PATH names only current\bin and current\lib, so a flat tree is folded into 'current'.
    $flatLib = Join-Path $TensorRtRoot 'lib'
    $flatBin = Join-Path $TensorRtRoot 'bin'
    if ((Test-Path $flatLib) -or (Test-Path $flatBin)) {
        Write-Host "TensorRT: flat layout at '$TensorRtRoot' -> folding into '$stable' so the ENV PATH resolves."
        $null = New-Item -ItemType Directory -Force -Path $stable
        foreach ($item in @(Get-ChildItem -LiteralPath $TensorRtRoot -Force | Where-Object { $_.Name -ne 'current' })) {
            Move-Item -LiteralPath $item.FullName -Destination $stable -Force
        }
        # Already named 'current' — skip the rename below, but DO reach the DLL gate.
        $alreadyStable = $true
    } else {
        Write-Host "TensorRT: '$TensorRtRoot' holds no versioned tree -> EP skipped (supported: no zip staged)."
        return
    }
}

$actual = if ($versionDir) { $versionDir.Name -replace '^TensorRT-', '' } else { 'flat' }
# No zip was extracted on a re-run, so a drift warning there would be a false positive.
if (-not $alreadyStable -and $ExpectedVersion -and $actual -ne $ExpectedVersion) {
    # Not fatal: the staged zip is this image's truth, and the Linux lane's apt may legitimately differ.
    Write-Warning ("TensorRT PIN DRIFT: versions.env says TENSORRT_VERSION=$ExpectedVersion but the staged zip " +
                   "extracted TensorRT-$actual. This image ships $actual and is internally consistent — but the " +
                   'pin no longer describes what ships. Re-stage the zip or correct the pin.')
}

if (-not $alreadyStable) { Rename-Item -LiteralPath $versionDir.FullName -NewName 'current' }

# Fail closed; TensorRT 10+ keeps its runtime DLLs in bin\, older releases in lib\, so accept either.
$binDir = Join-Path $stable 'bin'
$libDir = Join-Path $stable 'lib'
# The outer @() matters: one surviving dir is a bare scalar, whose .Count throws under StrictMode.
$dllDirs = @(@($binDir, $libDir) | Where-Object {
    Test-Path $_
} | Where-Object {
    @(Get-ChildItem -LiteralPath $_ -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count -gt 0
})
if ($dllDirs.Count -eq 0) {
    $present = @(Get-ChildItem -LiteralPath $stable -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    throw ("TensorRT tree '$(if ($versionDir) { $versionDir.Name } else { $stable })' carries no runtime DLLs in bin\ or lib\ (subdirs: $present) — " +
           'the EP would be dropped silently at runtime. Refusing to ship an unloadable TensorRT.')
}
$dllCount = @($dllDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.dll' -File }).Count
Write-Host "TensorRT $actual normalized to '$stable' ($dllCount runtime DLLs in: $(($dllDirs | Split-Path -Leaf) -join ', '))."
