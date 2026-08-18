#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Replays ONE real ONNX Runtime CUDA TU (bias_softmax_impl.cu - a TU whose
    instantiations the sccache nvcc decomposition verifiably lost) bare vs
    sccache-wrapped and diffs the symbol tables.

.DESCRIPTION
    The synthetic probes (probe-sccache-nvcc-instantiation.ps1) do NOT
    reproduce the 2026-08-18 dropped-instantiation miscompile - plain args,
    rsp (turns out: rsp = passthrough, no caching at all), -t4 and the expt
    flags all came back symbol-identical. So the trigger lives in the real
    TU's content or its full flag set. This probe:
      1. shallow-clones ORT at the pinned ref
      2. configures with this chain's CUDA settings (NO launcher, DML/TRT
         off - they do not shape the bias_softmax command)
      3. extracts the TU's exact nvcc command via `ninja -t commands`
      4. runs it bare, then sccache-wrapped (private local cache, own
         server), and diffs llvm-nm symbol tables
    A MISSING list = the miscompile, pinned to one command anyone can replay.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-ort',
    [string]$OrtRef = 'v1.28.0',
    [string]$Tu = 'bias_softmax_impl.cu',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== ONNX TU replay probe ($Tu @ $OrtRef) nonce=$Nonce ==="

Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir

# ---- 1. source ----------------------------------------------------------
if (-not (Test-Path 'ort\.git')) {
    & git clone --depth 1 --branch $OrtRef --recurse-submodules --shallow-submodules `
        https://github.com/microsoft/onnxruntime.git ort 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "clone failed ($LASTEXITCODE)" }
}

# ---- 2. configure (no launcher anywhere - we want the RAW command) -------
$cuda = $env:CUDA_PATH
$build = Join-Path $WorkDir 'build'
& cmake -S ort\cmake -B $build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_LINKER=lld-link "-DCMAKE_AR=llvm-lib" `
    -Donnxruntime_BUILD_SHARED_LIB=ON -Donnxruntime_BUILD_UNIT_TESTS=OFF `
    -Dprotobuf_MSVC_STATIC_RUNTIME=OFF `
    -Donnxruntime_USE_CUDA=ON `
    "-DCMAKE_CUDA_COMPILER:FILEPATH=$cuda\bin\nvcc.exe" `
    "-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real;89-real;90-real" `
    -DCMAKE_CUDA_STANDARD:STRING=17 `
    "-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/wd4067 -Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING" `
    "-DCUDNN_ROOT=$env:CUDNN_ROOT" "-Donnxruntime_CUDNN_HOME=$env:CUDNN_ROOT" `
    "-Donnxruntime_CUDA_HOME=$cuda" `
    2>&1 | Select-Object -Last 8 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }

# ---- 3. the TU's exact command -------------------------------------------
Set-Location $build
$objLine = & ninja -t targets all 2>$null | Select-String -SimpleMatch $Tu | Select-String 'providers_cuda' | Select-Object -First 1
if (-not $objLine) { throw "TU $Tu not found in ninja targets" }
$obj = ($objLine.Line -split ':')[0].Trim()
Write-Host "target: $obj"
$cmd = (& ninja -t commands $obj | Select-String -SimpleMatch $Tu | Select-Object -Last 1).Line
if (-not $cmd) { throw "no command for $obj" }
Write-Host "command: $($cmd.Substring(0, [Math]::Min(500, $cmd.Length))) ..."
Set-Content -Path replay-cmd.txt -Value $cmd

# ninja emits `cmd /S /C "<real command>"`- strip that wrapper if present.
if ($cmd -match '^\s*C?:?.*cmd(\.exe)? /S /C "(.*)"\s*$') { $cmd = $Matches[2] }

# ---- 4. bare vs wrapped ----------------------------------------------------
& cmd.exe /S /C "$cmd" 2>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "bare compile failed ($LASTEXITCODE)" }
Copy-Item $obj "$WorkDir\bare.obj" -Force

$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'sccache-debug.log'
$env:SCCACHE_LOG = 'debug'
$env:SCCACHE_SERVER_PORT = '4236'
& $sccache --stop-server 2>&1 | Out-Null
& $sccache --start-server 2>&1 | Out-Null
Remove-Item $obj -Force
& cmd.exe /S /C "`"$sccache`" $cmd" 2>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
$wrappedExit = $LASTEXITCODE
& $sccache --show-stats 2>&1 | Select-String 'Compile requests|Cache hits |Cache misses ' | ForEach-Object { "$_" }
& $sccache --stop-server 2>&1 | Out-Null
if ($wrappedExit -ne 0) { throw "wrapped compile failed ($wrappedExit)" }
Copy-Item $obj "$WorkDir\wrapped.obj" -Force

# ---- 5. verdict -------------------------------------------------------------
$bareSyms = (& llvm-nm --defined-only "$WorkDir\bare.obj" 2>$null) -replace '^\S+\s+\S+\s+', '' | Sort-Object -Unique
$wrapSyms = (& llvm-nm --defined-only "$WorkDir\wrapped.obj" 2>$null) -replace '^\S+\s+\S+\s+', '' | Sort-Object -Unique
$missing = @(Compare-Object $bareSyms $wrapSyms | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
Write-Host ("bare symbols: {0}  wrapped symbols: {1}" -f $bareSyms.Count, $wrapSyms.Count)
if ($missing.Count -gt 0) {
    Write-Host "[FAIL] wrapped object MISSING $($missing.Count) symbol(s):"
    $missing | Select-Object -First 40 | ForEach-Object { Write-Host "  MISSING: $_" }
} else {
    Write-Host '[ OK ] wrapped object contains every bare-object symbol (this TU does not reproduce)'
}
Write-Host 'probe complete'
exit 0
