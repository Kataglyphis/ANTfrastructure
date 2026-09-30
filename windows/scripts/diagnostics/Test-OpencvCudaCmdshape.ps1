#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Dissects the shape of OpenCV's CUDA nvcc commands (rsp layout, lengths) and why sccache forwards them.
.DESCRIPTION
    Configure-only: clones OpenCV at the pinned ref, configures with CUDA, then replays one real .cu command.
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
# The CUDA kernels live in opencv_contrib; without it WITH_CUDA=ON configures green with zero .cu targets.
if (-not (Test-Path 'contrib\.git')) {
    & git clone --depth 1 --branch $ver https://github.com/opencv/opencv_contrib.git contrib 2>&1 | Select-Object -Last 1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "contrib clone failed" }
}
# OpenCV's CMake rejects clang-cl for CUDA; production's clang-cl-compat patch gets past it.
Set-Location ocv
& git apply 'C:\bkmnt\patches\opencv\001-cmake-clang-cl-compat.patch'
if ($LASTEXITCODE -ne 0) { throw "clang-cl compat patch failed ($LASTEXITCODE)" }
Write-Host 'applied: 001-cmake-clang-cl-compat.patch'
Set-Location $WorkDir

$cuda = $env:CUDA_PATH
$cudaFwd = $cuda -replace '\\', '/'
$env:CUDACXX = "$cuda\bin\nvcc.exe"
& cmake -S ocv -B build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_LINKER=lld-link "-DCMAKE_AR=llvm-lib" `
    -DWITH_CUDA=ON -DWITH_CUDNN=ON -DWITH_CUBLAS=ON -DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON `
    -DOPENCV_DNN_CUDA=ON `
    "-DCUDAToolkit_ROOT=$cudaFwd" "-DCUDA_TOOLKIT_ROOT_DIR=$cudaFwd" `
    "-DOPENCV_EXTRA_MODULES_PATH=$WorkDir\contrib\modules" `
    "-DCMAKE_CUDA_COMPILER:FILEPATH=$cudaFwd/bin/nvcc.exe" `
    "-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real" `
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_python3=OFF `
    2>&1 | Tee-Object -FilePath configure.log | Select-Object -Last 4 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "configure failed" }
# opencv's own verdict: why would it drop CUDA/modules? Print the summary.
Get-Content configure.log | Select-String 'CUDA|NVCC|cudev|Unavailable|Disabled|To be built' |
    Select-Object -First 25 | ForEach-Object { "cfg| $($_.Line.Trim())" }
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

# Flag bisection: executed=0 means uncacheable, and the first variant that flips names the culprit token.
$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_LOG = 'debug'
$variants = [ordered]@{
    'full'          = $cmd
    'no-Fd'         = ($cmd -replace '-Xcompiler=-Fd\S+', '')
    'no-space-def'  = ($cmd -replace '-DOPENCV_ALLOCATOR_STATS_COUNTER_TYPE="[^"]*"', '')
    'no-depflags'   = ($cmd -replace '-MD -MT \S+ -MF \S+', '')
    'no-fwd-unknown' = ($cmd -replace '-forward-unknown-to-host-compiler', '')
}
$i = 0
foreach ($name in $variants.Keys) {
    $i++
    # An empty pattern would make -replace interleave the replacement between every character.
    if (-not $target) { throw 'target empty - refusing to build variants from garbage' }
    $v = $variants[$name] -replace [regex]::Escape($target), "replay$i.obj"
    $v = $v -replace '-MF \S+', "-MF replay$i.d"
    $env:SCCACHE_DIR = Join-Path $WorkDir "rcache$i"
    $env:SCCACHE_ERROR_LOG = Join-Path $WorkDir "rlog$i.log"
    $env:SCCACHE_SERVER_PORT = "43$($i)0"
    & $sccache --stop-server 2>&1 | Out-Null
    & $sccache --start-server 2>&1 | Out-Null
    # Direct spawn (cmd.exe dies at 8191 chars); tokens keep mixed-quote args like -Xcompiler="-O2 -Ob2" whole.
    $tokens = @([regex]::Matches($v, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value -replace '"', '' })
    Write-Host ("  len={0} tokens={1}" -f $v.Length, $tokens.Count)
    if ($name -eq 'full') {
        # Control: the same tokens through bare nvcc; a failure here is the harness, not sccache.
        $bareOut = & $tokens[0] @($tokens[1..($tokens.Count-1)] | ForEach-Object { $_ -replace 'replay1', 'bare0' }) 2>&1
        Write-Host ("  bare-control exit={0}" -f $LASTEXITCODE)
        if ($LASTEXITCODE -ne 0) { ($bareOut | Select-Object -Last 2) | ForEach-Object { "  bare| $_" } }
    }
    $out = & $sccache @tokens 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { ($out | Where-Object { $_ } | Select-Object -Last 3) | ForEach-Object { "  err| $_" } }
    $stats = & $sccache --show-stats 2>&1
    $exe = (($stats | Select-String 'requests executed' | Select-Object -First 1).Line -replace '\D+', '')
    $why = (Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue | Select-String 'CannotCache|cannot cache|NotCompilation' | Select-Object -First 1)
    if ($rc -ne 0) {
        Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue |
            Select-String 'which|binary|Error|failed|dryrun' | Select-Object -Last 4 |
            ForEach-Object { "  srv| $($_.Line.Trim().Substring(0, [Math]::Min(220, $_.Line.Trim().Length)))" }
        # The full CannotCache line, chunked: its token list names the mis-detected second input.
        $cc = (Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue | Select-String 'CannotCache' | Select-Object -First 1).Line
        if ($cc) { for ($p = 0; $p -lt $cc.Length; $p += 220) { Write-Host ("  cc| {0}" -f $cc.Substring($p, [Math]::Min(220, $cc.Length - $p))) } }
    }
    & $sccache --stop-server 2>&1 | Out-Null
    Write-Host ("variant {0,-15} exit={1} executed={2} why='{3}'" -f $name, $rc, $exe, $why)
}

Write-Host 'probe complete'
