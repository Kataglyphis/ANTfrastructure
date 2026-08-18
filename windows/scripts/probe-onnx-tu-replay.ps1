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
# ---- 6b. machine diff: plan host-step defines vs sccache's host arg vector --
# The dropped symbols are all double instantiations, and nvcc's plan gives the
# FINAL host cl.exe step arch defines (__CUDA_ARCH__=900 etc.) that typically
# guard double code paths. If sccache rebuilds that host step with a different
# define set, that is the mechanism. Tokenize both and diff.
Set-Location $build
$planLines = & cmd.exe /S /C "$cmd --dryrun" 2>&1
$planHost = ($planLines | Select-String 'cl\.exe' | Select-Object -Last 1).Line
$planTokens = @([regex]::Matches($planHost, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
$execLine = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'bias_softmax_impl\.cu\.obj\]: get_cached_or_compile' | Select-Object -Last 1).Line
$execTokens = @([regex]::Matches($execLine, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
$planD = @($planTokens | Where-Object { $_ -match '^[-/](D|FI|I)' } | Sort-Object -Unique)
$execD = @($execTokens | Where-Object { $_ -match '^[-/](D|FI|I)' } | Sort-Object -Unique)
Write-Host ("plan host-step -D/-FI/-I tokens: {0}; sccache host-step: {1}" -f $planD.Count, $execD.Count)
Compare-Object $planD $execD | ForEach-Object {
    $tag = if ($_.SideIndicator -eq '<=') { 'ONLY-IN-PLAN' } else { 'ONLY-IN-EXEC' }
    Write-Host ("  {0}: {1}" -f $tag, $_.InputObject)
}

# ---- 6e. THE define delta: plan host-preprocess vs sccache's preprocess ----
# sccache's cudafe++ consumes x_0.cpp4.ii, an .ii sccache preprocessed itself
# (probe5) - so the define set of THAT preprocess decides which #ifdef
# branches ever reach stub generation. Probe3 counted 48 exec -D tokens vs
# 59-64 in the plan. Compute the exact missing set.
$planPPLine = ($planLines | Select-String '\-EP |/EP ' | Select-Object -Last 1).Line
$execPPLine = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'preprocess' | Select-Object -First 1).Line
if ($planPPLine -and $execPPLine) {
    $planDefs = @([regex]::Matches($planPPLine, '-D\s*"?([^"\s]+)"?') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    $execDefs = @([regex]::Matches($execPPLine, '\\?"-D"?,?\s*\\?"([^"\\]+)\\?"|"-D([^"]+)"') | ForEach-Object { if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value } }) | Sort-Object -Unique
    if ($execDefs.Count -eq 0) {
        # Rust Debug vector form: "...", "-DFOO", ... - fall back to plain -D capture
        $execDefs = @([regex]::Matches($execPPLine, '-D([^"\\]+)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    Write-Host ("define delta: plan={0} exec={1}" -f $planDefs.Count, $execDefs.Count)
    Compare-Object $planDefs $execDefs | ForEach-Object {
        $tag = if ($_.SideIndicator -eq '<=') { 'LOST-BY-SCCACHE' } else { 'ADDED-BY-SCCACHE' }
        Write-Host ("  {0}: {1}" -f $tag, $_.InputObject)
    }
} else {
    Write-Host ("define delta: line capture failed (plan={0} exec={1})" -f [bool]$planPPLine, [bool]$execPPLine)
}

# ---- 6d. FULL lines, no summarizing: original cmd truth + both preprocess
# and cudafe++ invocations, chunked for the log. The 6c accounting used two
# different regexes on the two sides and produced contradictory-looking
# numbers - raw lines don't lie.
function Write-Chunked([string]$Prefix, [string]$Line) {
    if (-not $Line) { Write-Host "$Prefix <absent>"; return }
    for ($i = 0; $i -lt $Line.Length; $i += 230) {
        Write-Host ("{0} {1}" -f $Prefix, $Line.Substring($i, [Math]::Min(230, $Line.Length - $i)))
    }
}
Write-Host ("truth: original command carries -DUSE_CUDA: " + [bool]($cmd -match '[-/]DUSE_CUDA'))
$planPP = ($planLines | Select-String ' -E |\-EP |/EP ' | Select-Object -First 1).Line
Write-Chunked 'planPP|' $planPP
$planFE = ($planLines | Select-String 'cudafe\+\+' | Select-Object -First 1).Line
Write-Chunked 'planFE|' $planFE
$execPP = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'msvc\] preprocess' | Select-Object -First 1).Line
Write-Chunked 'execPP|' $execPP
$execFE = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'module_id\]: get_cached_or_compile' | Select-Object -First 1).Line
Write-Chunked 'execFE|' $execFE

# ---- 6c. per-step -DUSE_CUDA accounting ------------------------------------
# The dropped double instantiation is guarded by a plain `#ifdef USE_CUDA`.
# The final host step's define set matches the plan (6b), so the loss must be
# in an EARLIER step's input: the preprocess feeding cudafe++ (which GENERATES
# the host stubs). One column tells the story: does each step still carry
# -DUSE_CUDA?
Write-Host '--- per-step USE_CUDA accounting (plan) ---'
$planLines | Select-String 'cudafe|cicc|cl\.exe.*-E|cl\.exe.*/E|cl\.exe' | ForEach-Object {
    $l = $_.Line
    $label = if ($l -match 'cudafe\+\+') { 'cudafe++' } elseif ($l -match 'cicc') { 'cicc' }
             elseif ($l -match '-EP|/EP|-E |/E ') { 'preprocess' } else { 'host-cl' }
    Write-Host ("plan  {0,-11} -D count={1,3}  USE_CUDA={2}" -f $label, ([regex]::Matches($l, '[-/]D')).Count, ($l -match 'DUSE_CUDA'))
}
Write-Host '--- per-step USE_CUDA accounting (sccache executed) ---'
Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'get_cached_or_compile|msvc\] preprocess|creating.*command' | ForEach-Object {
    $l = $_.Line
    $label = if ($l -match 'module_id') { 'cudafe++' } elseif ($l -match 'compute_\d+\.ptx') { 'cicc' }
             elseif ($l -match 'preprocess') { 'preprocess' } elseif ($l -match '\.cu\.obj') { 'host-cl' } else { 'other' }
    Write-Host ("exec  {0,-11} -D count={1,3}  USE_CUDA={2}" -f $label, ([regex]::Matches($l, '"-D|\\"-D|[-/]D')).Count, ($l -match 'USE_CUDA'))
}

# ---- 6. mechanism evidence: nvcc's own plan vs sccache's executed steps ----
# The container fs dies with the RUN, so everything upstream needs lands in
# stdout here. Filter to the sub-command lines; cap so the log stays sane.
Set-Location $build
& cmd.exe /S /C "$cmd --dryrun" 2>&1 | Select-String 'cicc|ptxas|cudafe|fatbinary' |
    Select-Object -First 40 | ForEach-Object { "plan| $($_.Line.Trim().Substring(0, [Math]::Min(300, $_.Line.Trim().Length)))" }
if (Test-Path $env:SCCACHE_ERROR_LOG) {
    Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'cicc|ptxas|cudafe|fatbinary' |
        Select-Object -First 120 | ForEach-Object { "exec| $($_.Line.Trim().Substring(0, [Math]::Min(300, $_.Line.Trim().Length)))" }
}

Write-Host 'probe complete'
exit 0
