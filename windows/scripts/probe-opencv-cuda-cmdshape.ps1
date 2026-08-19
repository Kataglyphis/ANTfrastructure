#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    What SHAPE are OpenCV's CUDA nvcc commands? (#115 facts: rsp layout,
    inline args, command lengths, dryrun sub-command lengths.)
.DESCRIPTION
    Configure-only (no compile): clone OpenCV at the pinned ref, configure
    with CUDA, then dissect build.ninja's CUDA rule (rspfile / rspfile_content)
    and one real .cu command: lengths inline vs rsp content, and the longest
    line nvcc --dryrun prints for it.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-ocv',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== opencv CUDA command-shape probe nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$ver = Get-SourceBuildVersion -EnvironmentVariables @('OPENCV_VERSION') -DefaultValue '5.0.0'
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
if (-not (Test-Path 'ocv\.git')) {
    & git clone --depth 1 --branch $ver https://github.com/opencv/opencv.git ocv 2>&1 | Select-Object -Last 1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "clone failed" }
}
# The CUDA kernels live in opencv_contrib (cudev/cudaarithm/...) - without
# it WITH_CUDA=ON configures green with ZERO .cu targets.
if (-not (Test-Path 'contrib\.git')) {
    & git clone --depth 1 --branch $ver https://github.com/opencv/opencv_contrib.git contrib 2>&1 | Select-Object -Last 1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "contrib clone failed" }
}
$cuda = $env:CUDA_PATH
& cmake -S ocv -B build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_LINKER=lld-link "-DCMAKE_AR=llvm-lib" `
    -DWITH_CUDA=ON -DWITH_CUDNN=OFF -DWITH_CUBLAS=ON -DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON `
    "-DOPENCV_EXTRA_MODULES_PATH=$WorkDir\contrib\modules" `
    "-DCMAKE_CUDA_COMPILER:FILEPATH=$cuda\bin\nvcc.exe" `
    "-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real" `
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_python3=OFF `
    2>&1 | Select-Object -Last 4 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "configure failed" }
# Fail-open guards (#94 family): opencv silently drops CUDA when unhappy.
if (-not (Select-String -Path 'build\CMakeCache.txt' -Pattern 'WITH_CUDA:BOOL=ON' -Quiet)) { throw 'WITH_CUDA not ON in the cache' }
$cuCount = @(& ninja -C build -t targets all 2>$null | Select-String '\.cu\.obj').Count
Write-Host "cu targets: $cuCount"
if ($cuCount -eq 0) { throw 'no .cu targets in the build graph' }

Set-Location build
# The CUDA compile rule: does it declare an rspfile, and what goes into it?
$rules = Get-Content 'CMakeFiles\rules.ninja' -Raw
$cudaRule = [regex]::Match($rules, "rule CUDA_COMPILER__\S+[\s\S]*?(?=\r?\nrule |\z)").Value
Write-Host '--- CUDA rule (rules.ninja) ---'
$cudaRule -split "`r?`n" | Select-Object -First 12 | ForEach-Object { "rule| $_" }

# One real .cu target: full command + rsp content length.
$target = (& ninja -t targets all | Select-String '\.cu\.obj' | Select-Object -First 1).Line -replace ':.*', ''
Write-Host "target: $target"
$cmd = (& ninja -t commands $target | Select-Object -Last 1)
Write-Host ("command length: {0}" -f $cmd.Length)
Write-Host ("command head: {0}" -f $cmd.Substring(0, [Math]::Min(300, $cmd.Length)))
Write-Host ("command tail: {0}" -f $cmd.Substring([Math]::Max(0, $cmd.Length - 300)))
$rspRef = [regex]::Match($cmd, '--options-file\s+("?[^"\s]+"?)|@(\S+\.rsp)')
Write-Host ("rsp reference in command: '{0}'" -f $rspRef.Value)

Write-Host 'probe complete'
