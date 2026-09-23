# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# #108: repo layout is scripts/<group>/ while container mounts stay FLAT, so shared
# assets sit beside this script (flat) or one level up (repo).
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
# G2's gate: modules\ in the repo, a per-file mount under ortmods\ in the container (never the shared closure).
$ortGateModule = @('modules', 'ortmods') | ForEach-Object { Join-Path $scriptAssetRoot $_ 'WindowsOrtProvenance.Build.psm1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Import-Module ($ortGateModule ?? $(throw 'WindowsOrtProvenance.Build.psm1 (the G2 ORT gate) is not mounted')) -DisableNameChecking

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# GenAI runs LAST in media-core (the Dockerfile's order, deliberately NOT the
# $components order), so ORT already exists with USE_DML=ON on both lanes (#113).
$genaiTargetArch = Get-WindowsTargetArch
$genaiCross      = Test-WindowsCrossTarget -Arch $genaiTargetArch

$OnnxGenAiVersion = Get-SourceBuildVersion -Value $OnnxGenAiVersion -EnvironmentVariables @('ONNXRUNTIME_GENAI_VERSION', 'ONNX_GENAI_VERSION') -DefaultValue '0.15.2' -StripVPrefix

Write-Host "=== ONNX Runtime GenAI source build (v$OnnxGenAiVersion, Ninja+clang-cl) ==="
Write-Host "SourceDir: $SourceDir"
Write-Host "InstallDir: $InstallDir"

$genaiInstallDir = Join-Path $InstallDir 'lib\onnxruntime-genai-source'

$py = Get-SourceBuildPython
if (-not (Test-Path $py.Exe)) { throw "Python not found at $($py.Exe)" }
Write-Host "Using Python: $($py.Exe)"

# Install pip (source-built Python doesn't include it; idempotent shared helper)
Install-CpythonPip -Python $py

# No cmake/ninja here: the image ships both on PATH (scoop).
Write-Host 'Installing requests, setuptools, wheel via pip...'
Invoke-CpythonPip -Python $py -Arguments @('install', 'requests', 'setuptools', 'wheel', '--no-warn-script-location', '--quiet')

Initialize-ToolchainPythonEnvironment | Out-Null

Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime-genai.git' -Tag "v$OnnxGenAiVersion" -SourceDir $SourceDir -Recursive | Out-Null

Set-Location $SourceDir

# DML: genai's RESTORE_PACKAGES nuget-restores DXC only to regenerate HLSL shaders that
# already ship as checked-in DXIL -- a pointless network dep that can stall a restricted build.
$genaiCml = Join-Path $SourceDir 'CMakeLists.txt'
Invoke-InlineRegexPatch -Path $genaiCml -Guard 'add_dependencies\(onnxruntime-genai RESTORE_PACKAGES\)' `
    -Pattern 'add_dependencies\(onnxruntime-genai RESTORE_PACKAGES\)' -Replacement '# [genai DML] RESTORE_PACKAGES dep dropped: shaders are pre-generated, dxc.exe unused' `
    -Description 'genai CMakeLists: drop RESTORE_PACKAGES dependency (pre-generated shaders)' `
    -WarnMessage "genai CMakeLists: add_dependencies(onnxruntime-genai RESTORE_PACKAGES) not found -- genai layout may have changed; a USE_DML build may stall on the DXC nuget restore. Verify $genaiCml." | Out-Null
Invoke-InlineRegexPatch -Path $genaiCml -Guard 'RESTORE_PACKAGES ALL' `
    -Pattern 'RESTORE_PACKAGES ALL' -Replacement 'RESTORE_PACKAGES' `
    -Description 'genai CMakeLists: de-ALL RESTORE_PACKAGES so it is not in the default build' `
    -WarnMessage "genai CMakeLists: 'RESTORE_PACKAGES ALL' not found -- verify the DXC restore target is not force-built. $genaiCml." | Out-Null

# Build ONNX GenAI directly with cmake (bypass build.py which always builds examples)
$genaiBuildDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
# USE_CUDA=ON is REQUIRED for GPU: a CPU build strips GenAI's own .cu kernels and does NOT
# fall back to ORT's CUDA EP. nvcc's host compiler must be cl.exe (it rejects clang-cl).
# GENAI_FORCE_CPU=1 is a dev-only escape hatch (skips the slow nvcc kernels); media-core never sets it.
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'GENAI_FORCE_CPU'
# Decided by the TARGET, never the host: Get-GpuEnvironment probes the x64 build host.
# #176 phase 2 (2026-09-20): the cross lane builds the CUDA kernels too when the IMAGE
# carries the arm64 payload (lib\arm64) -- the same positive signal ORT uses; a cross
# image without it stays CPU + DML.
$genaiCudaUsable = $gpuEnv.HasCuda -and ((-not $genaiCross) -or (Test-CudaWindowsArm64Payload -CudaRoot $gpuEnv.CudaRoot))
if ($genaiCudaUsable) {
    $cudaRoot  = $gpuEnv.CudaRoot
    $cudaArch  = Get-CudaArchitectureList -Decoration '-real'
    # C++20, not 17 (std::span in cuda_topk.cu); /wd4996 for the CUDA 13.x curand
    # deprecation-as-error (genai #1877).
    $genaiCudaArgs = @('-DUSE_CUDA=ON') +
        (Get-NvccCudaCmakeArgs -CudaRoot $cudaRoot -CudaStandard '20' -ExtraCudaFlags '-Xcompiler=/wd4996' -IncludeToolkitRoot)
    # genai's Python .pyd is a MODULE target, which the CMAKE_SHARED_LINKER_FLAGS /LIBPATH below
    # does NOT reach; put the CPython lib dir on LIB so lld-link resolves the auto-linked python*.lib.
    $env:LIB = "$($py.LibDir);$env:LIB"
    Write-Host "CUDA ENABLED for ONNX GenAI (arch $cudaArch; nvcc host = cl.exe; C++ = clang-cl)"
} else {
    $genaiCudaArgs = @('-DUSE_CUDA=OFF')
    # "not wired for THIS component", not "impossible": phase 2 is in tree (2026-09-20),
    # so a cross build reaching here means the image has no arm64 CUDA payload.
    $genaiCudaWhy = if ($genaiCross) { "cross-compiling for $genaiTargetArch -- no arm64 CUDA payload staged in this image (Install-Cuda.ps1 -TargetArch arm64, #176)" }
                    else { 'CPU-only lane -- no nvidia GPU detected' }
    Write-Host "CUDA disabled for ONNX GenAI build ($genaiCudaWhy)"
}

# -- cross-lane switches, each decided by the TARGET arch --
# USE_DML: ON for BOTH lanes (#118) -- ORT's arm64 DML EP is built and arch-gate-verified
# (#113), and the DirectML / D3D12 Agility nugets do ship arm64 payloads.
$genaiDmlArg = '-DUSE_DML=ON'
# Python bindings ON on both lanes (#120 step 2, docs/windows-cross-builds.md). In the OFF
# path ENABLE_PYTHON is the load-bearing switch: BUILD_WHEEL=OFF alone (a cmake_dependent_option
# on it) still builds and mis-links src/python.
$tpy = Get-TargetBuildPython
$genaiPythonOn = (-not $genaiCross) -or $tpy.Available
$genaiPythonArgs = if ($genaiPythonOn) { @('-DBUILD_WHEEL=ON') } else {
    Write-Warning "GenAI: python bindings OFF -- no target CPython import lib at $($tpy.Lib)"
    @('-DENABLE_PYTHON=OFF', '-DBUILD_WHEEL=OFF')
}
# The triple must ride in THIS script's CMAKE_CXX_FLAGS string: -DCMAKE_CXX_FLAGS on the
# command line DEFINES the cache var, so Get-CMakeCrossArgs' *_INIT never applies.
$genaiTargetFlag = if ($genaiCross) { " --target=$(Get-ClangTargetTriple -Arch $genaiTargetArch)" } else { '' }
# No host-arch library on a LINK line: every python link input names the TARGET build.
# LIBPATH covers the shared targets, $env:LIB the MODULE target (see the CUDA branch).
$genaiPyLinkArgs = if ($genaiPythonOn) { @("-DCMAKE_SHARED_LINKER_FLAGS:STRING=/LIBPATH:$($tpy.LibDir)") } else { @() }
if ($genaiCross -and $genaiPythonOn) {
    $env:LIB = "$($tpy.LibDir);$env:LIB"
    Write-Host "GenAI: python bindings ON for the cross lane (#120 step 2) -- TARGET import lib dir $($tpy.LibDir) on LIB + LIBPATH"
}

$cmakeExtraGenAi = @(
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
    '-DUSE_TRT_RTX=OFF', $genaiDmlArg
    # $genaiPythonArgs is appended with + below, never inline: a comma-separated array
    # literal does not flatten, and the [string[]] coercion space-joins it into one token.
    '-DENABLE_JAVA=OFF', '-DUSE_GUIDANCE=OFF'
    # Telemetry is ON by default in 0.15: its bundled zlib feeds `-std=c11` to clang-cl
    # under -Werror (hard break), and we ship no phone-home.
    '-DENABLE_TELEMETRY=OFF'
    '-DPUBLISH_JAVA_MAVEN_LOCAL=OFF'
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=/GR /EHsc -D_SILENCE_CLANG_COROUTINE_MESSAGE $(Get-WarningNoiseSuppressionFlags)$genaiTargetFlag"
) + $genaiPythonArgs + $genaiPyLinkArgs + $genaiCudaArgs
# Both spellings, two finders: `Python_*` for genai's find_package(Python), `PYTHON_*` for
# its vendored pybind11, whose FindPythonLibsNew cannot locate the in-tree import lib alone.
$cmakeExtraGenAi += Get-PythonCMakeHintArgs -Python $tpy -Prefix @('Python', 'PYTHON')
# QNN EP (#121): GenAI uses ORT as its backend, so the QNN EP is inherited
# from the ORT build. Stage the QNN runtime DLLs beside the GenAI install.
$qnnSdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256
if ($qnnSdk) {
    Write-Host "GenAI: QNN runtime staged from $($qnnSdk.LibDir) -- backlog #121"
    [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $genaiInstallDir)
}

# Forward slashes, no quotes, no trailing separator: the form CMake prints the paths the ORT gates compare.
function ConvertTo-GenaiCmakePath {
    param([AllowEmptyString()][string]$Path)
    $Path.Trim().Trim('"').Replace('\', '/').TrimEnd('/')
}

# Every lane builds against the CHAIN's ORT. ortlib.cmake wants ORT_HOME\include\onnxruntime_c_api.h and ORT_HOME\lib\
# onnxruntime.dll beside its import library; the chain has include\onnxruntime\ and bin\, so this copy stands in.
function New-GenaiOrtHome {
    param([Parameter(Mandatory)][string]$OrtRoot, [Parameter(Mandatory)][string]$ShimRoot)
    $headerDir = Join-Path $OrtRoot 'include\onnxruntime'
    $linkFiles = @((Join-Path $OrtRoot 'lib\onnxruntime.lib'), (Join-Path $OrtRoot 'bin\onnxruntime.dll'))
    $required = @((Join-Path $headerDir 'onnxruntime_c_api.h'), (Join-Path $headerDir 'dml_provider_factory.h')) + $linkFiles
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "GenAI: the chain ONNX Runtime has no $file; ORT is built before GenAI, with USE_DML=ON on every lane"
        }
    }
    if (Test-Path -LiteralPath $ShimRoot) { Remove-Item -LiteralPath $ShimRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $ShimRoot 'include'), (Join-Path $ShimRoot 'lib')
    Copy-Item -Path (Join-Path $headerDir '*') -Destination (Join-Path $ShimRoot 'include') -Recurse -Force
    Copy-Item -LiteralPath $linkFiles -Destination (Join-Path $ShimRoot 'lib') -Force
    ConvertTo-GenaiCmakePath $ShimRoot
}

# ORT_HOME is typed because ortlib.cmake reads it undeclared. Both FETCHCONTENT_SOURCE_DIR_* aim a download fallback
# (ortlib; onnxruntime-extensions' onnxruntime) at an empty dir, so that path fails configure instead of fetching.
function Get-GenaiOrtCmakeArgs {
    param([Parameter(Mandatory)][string]$OrtHome, [Parameter(Mandatory)][string]$FetchBlockDir)
    $blocked = ConvertTo-GenaiCmakePath $FetchBlockDir
    "-DORT_HOME:PATH=$(ConvertTo-GenaiCmakePath $OrtHome)"
    "-DFETCHCONTENT_SOURCE_DIR_ORTLIB:PATH=$blocked"
    "-DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME:PATH=$blocked"
}

# Every-lane gate on what configure wrote: ortlib.cmake took the shim as ORT_HOME, nothing names a fetched ORT, the fetch
# block reached the cache, and every GenAI compile and every link of onnxruntime.lib reads the shim.
function Get-GenaiOrtConfigureFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigureLog,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CMakeCache,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuildNinja,
        [Parameter(Mandatory)][string]$OrtHome,
        [Parameter(Mandatory)][string]$FetchBlockDir
    )
    $shim = ConvertTo-GenaiCmakePath $OrtHome
    $isPath = { param([string]$Seen, [string]$Want) (ConvertTo-GenaiCmakePath $Seen) -ieq $Want }
    $fetchMark = '(?i)Using ONNX Runtime package|ONNX Runtime URL:|pkgs\.dev\.azure\.com|Microsoft\.ML\.OnnxRuntime|onnxruntime/releases/download|/_deps/(ortlib|onnxruntime)-(src|subbuild|build)\b'
    $logLines = [string[]]@($ConfigureLog -split '\r?\n')
    $logLines | Where-Object { $_.Replace('\', '/') -match $fetchMark } | ForEach-Object { "configure names a downloaded ONNX Runtime: $($_.Trim())" }
    $grab = { param([string]$Pattern) foreach ($logLine in $logLines) { if ($logLine -match $Pattern) { $Matches['v'] } } }
    $homeSeen = @(& $grab 'Using ONNX Runtime from:\s*(?<v>.*?)\s*\[absolute\]')
    if ($homeSeen.Count -eq 0) { "the configure log has no 'Using ONNX Runtime from: ... [absolute]' line, so ortlib.cmake did not take ORT_HOME" }
    $homeSeen | Where-Object { -not (& $isPath $_ $shim) } | ForEach-Object { "ortlib.cmake took ORT_HOME '$_', not the chain shim $shim" }
    foreach ($dirVar in @(@{ Name = 'ORT_HEADER_DIR'; Want = "$shim/include" }, @{ Name = 'ORT_LIB_DIR'; Want = "$shim/lib" })) {
        $dirSeen = @(& $grab "(?<![\w-])$($dirVar.Name):\s*(?<v>.*?)\s*$")
        if ($dirSeen.Count -eq 0) { "the configure log has no $($dirVar.Name) line" }
        $dirSeen | Where-Object { -not (& $isPath $_ $dirVar.Want) } | ForEach-Object { "ortlib.cmake set $($dirVar.Name) to '$_', not $($dirVar.Want)" }
    }
    $cacheVars = [ordered]@{}
    foreach ($entry in ($CMakeCache -split '\r?\n')) {
        if ($entry -match '^(?<name>[A-Za-z_][\w.+-]*)(:[A-Za-z_]+)?=(?<value>.*)$') { $cacheVars[$Matches['name']] = $Matches['value'] }
    }
    $blocked = ConvertTo-GenaiCmakePath $FetchBlockDir
    $pins = [ordered]@{ ORT_HOME = $shim; FETCHCONTENT_SOURCE_DIR_ORTLIB = $blocked; FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME = $blocked }
    if ($cacheVars.Count -eq 0) { 'CMakeCache.txt is missing or has no entries, so ORT_HOME and the fetch block cannot be checked' }
    else {
        foreach ($name in $pins.Keys) {
            if (-not $cacheVars.Contains($name)) { "CMakeCache.txt has no $name" }
            elseif (-not (& $isPath $cacheVars[$name] $pins[$name])) { "CMakeCache.txt has $name=$($cacheVars[$name]), not $($pins[$name])" }
        }
    }
    $cacheVars.Keys | Where-Object { $cacheVars[$_].Replace('\', '/') -match $fetchMark } |
        ForEach-Object { "CMakeCache.txt names a downloaded ONNX Runtime: $_=$($cacheVars[$_])" }
    if ([string]::IsNullOrWhiteSpace($BuildNinja)) { return 'build.ninja is missing or empty, so the compile and link lines cannot be checked' }
    Get-GenaiOrtNinjaFinding -BuildNinja $BuildNinja -Shim $shim
}

# build.ninja half of the gate: a statement is its `build` line plus the indented `name = value` lines right under it.
function Get-GenaiOrtNinjaFinding {
    param([Parameter(Mandatory)][string]$BuildNinja, [Parameter(Mandatory)][string]$Shim)
    $ninja = $BuildNinja.Replace('\', '/')
    $incFlag = "(?i)(^|\s)`"?[-/]I\s*`"?$([regex]::Escape("$Shim/include"))`"?(\s|$)"
    $libPathFlag = "(?i)[-/]LIBPATH:`"?$([regex]::Escape("$Shim/lib"))`"?(\s|$)"
    $unshimmed = [System.Collections.Generic.List[string]]::new()
    $compiles = 0
    $genaiLinks = 0
    foreach ($chunk in [regex]::Split($ninja, '(?m)^(?=build )')) {
        if ($chunk -notmatch '^build (?<out>(?:\$.|[^:$\r\n])+):') { continue }
        $outputs = $Matches['out'].Trim()
        $varBlock = [regex]::Match($chunk, '\A[^\r\n]*\r?\n(?<vars>(?:[ \t]+\w+[ \t]*=[^\r\n]*(?:\r?\n|\z))*)').Groups['vars'].Value
        $var = if ($varBlock.Trim()) { ConvertFrom-StringData -StringData $varBlock } else { @{} }
        if ($outputs -match '/onnxruntime-genai-obj\.dir/') {
            $compiles++
            if ("$($var['INCLUDES'])" -notmatch $incFlag) { $unshimmed.Add($outputs) }
        }
        $linked = "$($var['LINK_LIBRARIES'])"
        if ($linked -notmatch '(?i)(^|[\s"/])onnxruntime\.lib("|\s|$)') { continue }
        if ($outputs -match '(^|[\s/])onnxruntime-genai\.dll(\s|$)') { $genaiLinks++ }
        if ("$($var['LINK_PATH'])" -notmatch $libPathFlag) { "$outputs links onnxruntime.lib without $Shim/lib on its LINK_PATH" }
        foreach ($abs in [regex]::Matches($linked, '(?i)"?(?<p>[^\s"]*/onnxruntime\.lib)"?')) {
            if ($abs.Groups['p'].Value -ine "$Shim/lib/onnxruntime.lib") { "$outputs links $($abs.Groups['p'].Value), not the chain shim's import library" }
        }
    }
    if ($compiles -eq 0) { 'build.ninja has no compile statement for onnxruntime-genai-obj' }
    if ($unshimmed.Count -gt 0) { "$($unshimmed.Count) of $compiles GenAI compiles lack -I$Shim/include, first: $($unshimmed[0])" }
    if ($genaiLinks -eq 0) { 'build.ninja has no onnxruntime-genai.dll link that names onnxruntime.lib' }
    if ($ninja -match '(?i)/_deps/(ortlib|onnxruntime)-(src|subbuild|build)\b|Microsoft\.ML\.OnnxRuntime') { "build.ninja names a downloaded ONNX Runtime ($($Matches[0]))" }
}

# Every file named like a chain ORT file must carry the chain's bytes; -ForbidCopies (an install dir) wants none at all.
# ORT archives and FetchContent'd ORT dirs fail either way. NOT covered: a foreign ORT under a name the chain lacks.
function Get-GenaiOrtTreeFinding {
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$OrtRoot, [switch]$ForbidCopies)
    $walk = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; AttributesToSkip = [System.IO.FileAttributes]0; IgnoreInaccessible = $false }
    $flatWalk = [System.IO.EnumerationOptions]@{ AttributesToSkip = [System.IO.FileAttributes]0; IgnoreInaccessible = $false }
    $chainSha = @{}
    foreach ($ref in @(@{ Dir = 'include\onnxruntime'; Walk = $walk }, @{ Dir = 'lib'; Walk = $flatWalk }, @{ Dir = 'bin'; Walk = $flatWalk })) {
        $refDir = Join-Path $OrtRoot $ref.Dir
        if (-not (Test-Path -LiteralPath $refDir -PathType Container)) { continue }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($refDir, '*', $ref.Walk)) {
            $leaf = [System.IO.Path]::GetFileName($file)
            if ($leaf -notmatch '(?i)^onnxruntime|_provider_factory\.h$') { continue }
            if (-not $chainSha.ContainsKey($leaf)) { $chainSha[$leaf] = [System.Collections.Generic.List[string]]::new() }
            $chainSha[$leaf].Add((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)
        }
    }
    foreach ($anchor in 'onnxruntime_c_api.h', 'onnxruntime.lib', 'onnxruntime.dll') {
        if (-not $chainSha.ContainsKey($anchor)) { "the chain ONNX Runtime at $OrtRoot has no $anchor to compare against" }
    }
    if (-not (Test-Path -LiteralPath $TreeRoot -PathType Container)) { return "no tree at $TreeRoot to check" }
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($TreeRoot, '*', $walk)) {
        if ([System.IO.Path]::GetFileName($dir) -match '^(ortlib|onnxruntime)-(src|subbuild|build)$') { "FetchContent populated ONNX Runtime content at $dir" }
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($TreeRoot, '*', $walk)) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($leaf -match '(?i)^(microsoft\.ml\.)?onnxruntime(?![_-](genai|extensions)).*\.(zip|nupkg|tgz|txz|tar|gz|xz|bz2|7z|whl|aar)$') { "an ONNX Runtime archive sits in the tree: $file" }
        if (-not $chainSha.ContainsKey($leaf)) { continue }
        if ($ForbidCopies) { "an ONNX Runtime file ships inside the GenAI install: $file"; continue }
        if ($chainSha[$leaf] -notcontains (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) { "$file is not the chain's $leaf (foreign ONNX Runtime bytes)" }
    }
}

$genaiOrtRoot = Join-Path $InstallDir 'lib\onnxruntime-source'
$genaiOrtHome = New-GenaiOrtHome -OrtRoot $genaiOrtRoot -ShimRoot (Join-Path $SourceDir 'ort-home')
$genaiOrtBlock = Join-Path $SourceDir 'ort-fetch-blocked'
$null = New-Item -ItemType Directory -Force -Path $genaiOrtBlock
$genaiOrtArgs = @(Get-GenaiOrtCmakeArgs -OrtHome $genaiOrtHome -FetchBlockDir $genaiOrtBlock)
$cmakeExtraGenAi += $genaiOrtArgs
Write-Host "GenAI ONNX Runtime: the chain's at $genaiOrtRoot through $genaiOrtHome; ortlib/onnxruntime FetchContent blocked at $genaiOrtBlock"
$genaiCfgLog = Get-PersistentBuildLogPath -FallbackDir $genaiBuildDir -Name 'onnx-genai-configure.log'
Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $genaiBuildDir -ExtraArgs $cmakeExtraGenAi -InstallPrefix $genaiInstallDir 2>&1 |
    Tee-Object -FilePath $genaiCfgLog
$genaiRecord = @{}
foreach ($recordFile in @($genaiCfgLog, (Join-Path $genaiBuildDir 'CMakeCache.txt'), (Join-Path $genaiBuildDir 'build.ninja'))) {
    $genaiRecord[(Split-Path $recordFile -Leaf)] = if (Test-Path -LiteralPath $recordFile -PathType Leaf) { [System.IO.File]::ReadAllText($recordFile) } else { '' }
}
$genaiOrtCfg = @(Get-GenaiOrtConfigureFinding -ConfigureLog $genaiRecord['onnx-genai-configure.log'] -CMakeCache $genaiRecord['CMakeCache.txt'] `
        -BuildNinja $genaiRecord['build.ninja'] -OrtHome $genaiOrtHome -FetchBlockDir $genaiOrtBlock) +
    @(Get-GenaiOrtTreeFinding -TreeRoot $SourceDir -OrtRoot $genaiOrtRoot)
if ($genaiOrtCfg.Count -gt 0) { throw "GenAI ONNX Runtime configure gate ($genaiCfgLog): $($genaiOrtCfg -join '; ')" }
Write-Host "GenAI ONNX Runtime gate OK ($genaiCfgLog): ORT_HOME is the chain shim, no ORT fetched, every ORT file in the tree is the chain's"

# Resolve MSVC tools path dynamically (avoid hardcoded version)
$msvcVersionDir = Get-MsvcToolsRoot
Write-Host "Using MSVC tools: $msvcVersionDir"

# Inline, NOT .patch files: these target the installed MSVC STL headers, whose toolset
# version floats. See docs/windows-builds.md "Source Patch Policy".

# Neutralize MSVC STL's clang-incompatible static_asserts: wrapping the _EMIT_STL_ERROR
# define no-ops EVERY STL error code under clang-cl, so this one edit carries the load.
$yvalsCore = Join-Path $msvcVersionDir 'include\yvals_core.h'
$yvalsOld = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
$yvalsNew = '#ifdef __clang__
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)
#else
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)
#endif'
[void](Invoke-InlineRegexPatch -Path $yvalsCore -Guard '#define _EMIT_STL_ERROR' `
        -Pattern ([regex]::Escape($yvalsOld)) -Replacement $yvalsNew `
        -Description 'MSVC yvals_core.h for clang compat')
# Loud drift assertion: the define present but the exact target line gone means a future MSVC
# changed the macro format -- fail here, not as resurfaced static_asserts mid-compile.
if (Test-Path $yvalsCore) {
    $yvalsText = [System.IO.File]::ReadAllText($yvalsCore)
    if (($yvalsText -match '#define _EMIT_STL_ERROR') -and
        ($yvalsText -notmatch '#ifdef __clang__\r?\n#define _EMIT_STL_ERROR\(NUMBER, MESSAGE\)')) {
        $msvcVer = Split-Path $msvcVersionDir -Leaf
        throw "yvals_core.h: _EMIT_STL_ERROR is present but the exact patch target did not match (MSVC $msvcVer likely changed the macro format). Update `$yvalsOld in Build-OnnxGenaiFromSource.ps1 -- clang static_asserts will otherwise resurface mid-build."
    }
}

# Patch build.ninja to strip MSVC-only flags clang-cl errors on
Update-NinjaFile -NinjaFile (Join-Path $genaiBuildDir 'build.ninja') -StripPatterns @(
    '/Qspectre',
    '(?<=\s)/WX(?=\s)'
)

# -LogFile is required (#43): without it this stage produced no ninja log at all, not even
# the 50-line failure tail that is gated on it.
$genaiLog = Get-PersistentBuildLogPath -Name 'onnx-genai-ninja.log' -FallbackDir $genaiBuildDir
# MemGBPerJob 2, not 4 (#74): measured peak per-process WorkingSet 998 MB on the same nvcc
# workload (ONNX vertex, 9274 samples); the retry ladder drops to -j1 on an OOM-shaped failure.
Invoke-NinjaBuildWithRetry -BuildDir $genaiBuildDir -RetryJobs 1 -MemGBPerJob 2 -Install -LogFile $genaiLog
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

Write-Host "Installing to $genaiInstallDir..."
if (Test-Path $genaiBuildDir) {
    Copy-BuildArtifact -BuildDir $genaiBuildDir -InstallDir $genaiInstallDir -Map @(
        @{ Filter = '*.h'; Dest = 'include' }
        @{ Filter = @('*.lib', '*.dll', '*.pyd'); Dest = 'lib' }
    )
} else {
    # Unreachable in principle; a silent skip would ship an empty install dir as green.
    Write-Warning "genai build dir missing at $genaiBuildDir -- NO artifacts staged to $genaiInstallDir"
}
# Optional layout variant: absence is normal, but a FAILED copy must not be silent.
$altOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Windows\Release'
if (Test-Path $altOutDir) {
    try {
        Copy-Item -Path (Join-Path $altOutDir '*') -Destination "$genaiInstallDir\lib" -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "copy from alternate output dir $altOutDir failed: $_"
    }
}

# Floor (#158): Copy-BuildArtifact reports counts but never throws, so an empty or
# partial install used to ship green. Root-recursive, like Test-Container's check.
$genaiHdrs = @(Get-ChildItem -Path $genaiInstallDir -Filter '*.h' -File -Recurse -ErrorAction SilentlyContinue)
$genaiDlls = @(Get-ChildItem -Path $genaiInstallDir -Filter 'onnxruntime-genai*.dll' -File -Recurse -ErrorAction SilentlyContinue)
$genaiLibs = @(Get-ChildItem -Path $genaiInstallDir -Filter 'onnxruntime-genai*.lib' -File -Recurse -ErrorAction SilentlyContinue)
if ($genaiHdrs.Count -eq 0 -or $genaiDlls.Count -eq 0 -or $genaiLibs.Count -eq 0) {
    throw ("genai install floor: expected headers plus onnxruntime-genai*.dll/.lib under $genaiInstallDir " +
        "(headers=$($genaiHdrs.Count), dll=$($genaiDlls.Count), lib=$($genaiLibs.Count)) -- the copy staged an incomplete payload.")
}

# DML: onnxruntime-genai.dll loads D3D12Core.dll from its own module dir at runtime, and the
# wheel's POST_BUILD copy is the only other one -- so stage it next to the genai DLL.
# Pin the filter to the TARGET's nuget dir ('win-arm64' -> 'arm64'): an unqualified -Recurse
# picks arm64 alphabetically and then fails DML device init on an x64 image.
$d3d12ArchDir = (Get-WindowsRuntimeIdentifier) -replace '^win-', ''
Copy-SidecarDll -SidecarName 'D3D12Core.dll' -SearchDir $genaiBuildDir `
    -SidecarFilter { $_.FullName -match '_deps' -and $_.Directory.Name -eq $d3d12ArchDir } `
    -Destination (Join-Path $genaiInstallDir 'lib') `
    -Reason 'the DML runtime will fail to init the Agility SDK device. Verify the Microsoft.Direct3D.D3D12 FetchContent'

# -- Python wheel -- pack what BUILD_WHEEL=ON assembled into build\wheel; --no-build-isolation
# reuses the deps installed above. Must run BEFORE Remove-SourceBuildTree.
$genaiWheelDir = Join-Path $genaiBuildDir 'wheel'
# #126: upstream's setup.py.in derives the ORT requirement from the package name (-cuda ->
# `onnxruntime-gpu`), but this bundle ships its combined ORT wheel as plain `onnxruntime` --
# left alone the Requires-Dist names a PyPI package we never stage (see -NoDeps below).
if (Test-Path (Join-Path $genaiWheelDir 'setup.py')) {
    # Invoke-InlineRegexPatch only WARNS on a missing pattern, and a silent miss would ship
    # the wrong Requires-Dist -- so the return value is the gate.
    if (-not (Invoke-InlineRegexPatch -Path (Join-Path $genaiWheelDir 'setup.py') `
            -Pattern 'dependency = "onnxruntime-(directml|gpu|trt-rtx)"' `
            -Replacement 'dependency = "onnxruntime"' -Require `
            -Description 'genai setup.py: ORT dependency -> the bundle''s combined `onnxruntime` wheel (#126)')) {
        throw "genai setup.py: the _onnxruntime_dependency() mapping was not found -- upstream layout changed; the wheel would declare a PyPI onnxruntime-<suffix> the bundle never stages (#126)"
    }
    if (Select-String -Path (Join-Path $genaiWheelDir 'setup.py') -Pattern 'dependency = "onnxruntime-' -Quiet) {
        throw "genai setup.py still names a suffixed onnxruntime package after the #126 fix-up -- upstream changed _onnxruntime_dependency(); update the pattern"
    }
}
if (-not $genaiPythonOn) {
    # BUILD_WHEEL=OFF, so cmake configured no setup.py: the hard gate in the final else
    # must not fire here -- its premise is "BUILD_WHEEL=ON is set above".
    Write-Host "genai python wheel skipped (BUILD_WHEEL=OFF -- no target CPython import lib on this $genaiTargetArch cross lane)"
} elseif ($genaiCross -and (Test-Path (Join-Path $genaiWheelDir 'setup.py'))) {
    # Cross: bdist_wheel, not `pip wheel` -- the target tag must be forced with --plat-name
    # (-CrossStage appends it; pip has no clean pass-through). Built + staged, never imported.
    Invoke-PythonWheelBuild -Python $py -WorkingDir $genaiWheelDir `
        -Arguments 'setup.py bdist_wheel -d dist' `
        -ModuleName 'onnxruntime_genai' -CrossStage | Out-Null
} elseif (Test-Path (Join-Path $genaiWheelDir 'setup.py')) {
    Write-Host 'Building onnxruntime-genai python wheel...'
    # -NoDeps is LOAD-BEARING: letting pip resolve genai-cuda's `onnxruntime-gpu` pulled the
    # PyPI wheel over ours and the interpreter silently lost DmlExecutionProvider.
    Invoke-PythonWheelBuild -Python $py -WorkingDir $genaiWheelDir `
        -Arguments '-m pip wheel . --no-deps --no-build-isolation -w dist' `
        -ModuleName 'onnxruntime_genai' -NoDeps | Out-Null
} else {
    # BUILD_WHEEL=ON is set above, so a missing setup.py means the wheel (and its embed
    # libs) silently vanish from the image.
    throw "genai wheel dir has no setup.py under $genaiWheelDir although BUILD_WHEEL=ON -- BUILD_WHEEL layout changed? Wheel would NOT be staged."
}

# Again after the build (a build-time fetch lands in the tree too), and the install must hold no ORT copy of its own.
$genaiOrtPost = @(Get-GenaiOrtTreeFinding -TreeRoot $SourceDir -OrtRoot $genaiOrtRoot) + @(Get-GenaiOrtTreeFinding -TreeRoot $genaiInstallDir -OrtRoot $genaiOrtRoot -ForbidCopies)
# G2 throws on those findings too (one throw point), and stamps GenAI for G1 only on a clean pass.
Assert-ChainOrtOnly -Consumer 'genai' -OrtRoot $genaiOrtRoot -TreeRoot $SourceDir -Shim $genaiOrtHome -Log $genaiCfgLog -Finding $genaiOrtPost `
    -Record (Join-Path $genaiBuildDir 'CMakeCache.txt'), (Join-Path $genaiBuildDir 'build.ninja')

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0