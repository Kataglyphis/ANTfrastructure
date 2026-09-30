# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\litert-src',
    [string]$InstallDir = '',
    [string]$LiteRtVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# Shared assets sit beside this script in the flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# Export-LitertLmBridge.ps1 carries the same default: a LiteRT bump updates both.
$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue 'v2.2.0'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'

Write-Host "=== LiteRT source build ($LiteRtVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT.git' -Tag "$LiteRtVersion" -SourceDir $SourceDir -Recursive | Out-Null

$tfliteSrc = Join-Path $SourceDir 'tflite'

# Inline, not a .patch: the set of proto CMakeLists changes between versions. See docs/windows-builds.md § Source Patch Policy
$patchedIndex = 0
Get-ChildItem -Path $tfliteSrc -Filter 'CMakeLists.txt' -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -match 'proto\\CMakeLists\.txt'
} | ForEach-Object {
    $content = [System.IO.File]::ReadAllText($_.FullName)
    if ($content -match 'protobuf_generate|protoc') {
        $patchedIndex++
        $targetName = "proto_stub_$patchedIndex"
        $noopCmake = @"
cmake_minimum_required(VERSION 3.10)
project($targetName)
add_library($targetName INTERFACE)
"@
        Set-Content -Path $_.FullName -Value $noopCmake -Encoding ASCII
        Write-Host "Patched: $($_.FullName) (target=$targetName)"
    }
}

# gst's tflite plugin needs tensorflowlite_c; upstream's tflite/c project re-adds the whole tree, so inject the target.
$mainCmake = Join-Path $tfliteSrc 'CMakeLists.txt'
$capiSnippet = @'

# ---- tensorflowlite_c (TFLite C API) injected by Build-LitertFromSource.ps1 ----
if(NOT TARGET tensorflowlite_c)
  add_library(tensorflowlite_c SHARED
    ${TFLITE_SOURCE_DIR}/core/c/c_api.cc
    ${TFLITE_SOURCE_DIR}/core/c/c_api_experimental.cc
    ${TFLITE_SOURCE_DIR}/core/c/common.cc
    ${TFLITE_SOURCE_DIR}/core/c/operator.cc
  )
  target_compile_definitions(tensorflowlite_c PRIVATE TFL_COMPILE_LIBRARY)
  target_link_libraries(tensorflowlite_c tensorflow-lite)
  # tensorflow-lite adds -DTFL_STATIC_LIBRARY_BUILD as a PUBLIC compile option
  # (tflite/CMakeLists.txt), which this target INHERITS via the link above. In
  # c_api_types.h that macro is checked BEFORE TFL_COMPILE_LIBRARY and makes
  # TFL_CAPI_EXPORT expand to nothing -- so none of the C API (TfLiteInterpreter*
  # etc.) gets __declspec(dllexport) and the DLL exports zero C API symbols, so
  # gst-plugins-bad's tflite plugin fails to LINK. Let CMake generate a .def from
  # this target's own objects (c_api.cc, common.cc, ...) so the C API is exported
  # regardless of the macro -- independent of -D/-U ordering.
  set_target_properties(tensorflowlite_c PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
  # WINDOWS_EXPORT_ALL_SYMBOLS only exports THIS target's own object files
  # (c_api.cc, ...). The XNNPACK delegate C API (TfLiteXNNPackDelegate*) lives in
  # the linked-in tensorflow-lite static lib (TFLITE_ENABLE_XNNPACK=ON) and is
  # built without TFL_COMPILE_LIBRARY, so it is neither auto-exported nor
  # dllexport'd -- gst's tflite plugin needs it for the XNNPACK accelerator.
  # Force lld-link to pull those three from the static lib and export them.
  target_link_options(tensorflowlite_c PRIVATE
    /EXPORT:TfLiteXNNPackDelegateCreate
    /EXPORT:TfLiteXNNPackDelegateDelete
    /EXPORT:TfLiteXNNPackDelegateOptionsDefault
  )
endif()
'@
Add-Content -Path $mainCmake -Value $capiSnippet -Encoding ASCII
Write-Host "Injected tensorflowlite_c (TFLite C API) target into $mainCmake"

$buildDir = Join-Path $SourceDir 'build'
# Stale pkgRedirects break on path casing, so a failed delete must be loud.
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction Stop }
if (Test-Path (Join-Path $SourceDir 'BUILD')) { Remove-Item (Join-Path $SourceDir 'BUILD') -Recurse -Force -ErrorAction Stop }

$gpuEnv = Get-GpuEnvironment
$cmakeExtra = @(
    '-DTFLITE_ENABLE_INSTALL=OFF'
    '-DTFLITE_ENABLE_LABEL_IMAGE=OFF'
    '-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF'
    '-DTFLITE_ENABLE_RUY=ON'
    '-DTFLITE_ENABLE_RESOURCE=ON'
    # GPU delegate via Vulkan/OpenGL ES (primary GPU acceleration on Windows)
    '-DTFLITE_ENABLE_GPU=ON'
    '-DTFLITE_ENABLE_XNNPACK=ON'
    # External delegate support for custom CUDA/ROCm delegates
    '-DTFLITE_ENABLE_EXTERNAL_DELEGATE=ON'
    '-DTFLITE_ENABLE_MMAP=OFF'
    '-DTFLITE_ENABLE_NNAPI=OFF'
)
# The image's AVX2+FMA baseline via *_FLAGS_INIT, which keep the platform's /GR /EHsc that CMAKE_*_FLAGS would replace.
if (-not (Test-WindowsCrossTarget)) {
    $litertSimd = Get-WindowsTargetSimdFlags
    $cmakeExtra += @("-DCMAKE_C_FLAGS_INIT=$litertSimd", "-DCMAKE_CXX_FLAGS_INIT=$litertSimd")
}
# No QNN flags: LiteRT's Qualcomm support lives in the litert/ tree, not this tflite/ one; QAIRT below serves ORT.
$qnnSdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256

$cmakeExtra += Get-CudaToolkitRootArg -GpuEnv $gpuEnv

$cmakeExtra += Get-LlvmArchiverCmakeArg

# Cross needs a host flatc in TFLITE_HOST_TOOLS_DIR, built natively from this tree so its version cannot drift.
if (Test-WindowsCrossTarget) {
    $hostToolsBuild = Join-Path $SourceDir 'build-host-tools'
    if (Test-Path $hostToolsBuild) { Remove-Item $hostToolsBuild -Recurse -Force -ErrorAction Stop }
    Write-Host 'LiteRT cross: building HOST flatc (flatbuffers-flatc, native configure) for TFLITE_HOST_TOOLS_DIR...'
    # Composed first: `-ExtraArgs @(...) + (...)` would bind the `+` operand as a positional argument.
    $hostToolArgs = @(
        '-DTFLITE_ENABLE_INSTALL=OFF', '-DTFLITE_ENABLE_XNNPACK=OFF', '-DTFLITE_ENABLE_GPU=OFF',
        '-DTFLITE_ENABLE_RUY=OFF', '-DTFLITE_ENABLE_LABEL_IMAGE=OFF', '-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF'
    ) + @(Get-LlvmArchiverCmakeArg)
    # The link environment around the host pass is logged: a target configure after it once lost kernel32.lib.
    $probeVars = @('LIB', 'LIBPATH', 'VCToolsInstallDir', 'VSCMD_ARG_TGT_ARCH', 'WindowsSdkDir', 'UniversalCRTSdkDir')
    Write-Host ('LiteRT env probe BEFORE host pass: ' + (($probeVars | ForEach-Object { "$_=[$([Environment]::GetEnvironmentVariable($_, 'Process'))]" }) -join ' '))
    [void](Invoke-HostToolCmakeBuild -SourceDir $tfliteSrc -BuildDir $hostToolsBuild -InstallPrefix (Join-Path $SourceDir 'host-tools-prefix') `
        -ExtraArgs $hostToolArgs -Targets @('flatbuffers-flatc') -LogName 'litert-host-flatc-build.log' -Label 'LiteRT host flatc')
    Write-Host ('LiteRT env probe AFTER host pass: ' + (($probeVars | ForEach-Object { "$_=[$([Environment]::GetEnvironmentVariable($_, 'Process'))]" }) -join ' '))
    $flatc = Get-ChildItem -Path $hostToolsBuild -Recurse -Filter 'flatc.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $flatc) { throw "LiteRT cross: flatc.exe not found under $hostToolsBuild after the host-tools build" }
    Write-Host "LiteRT cross: host flatc at $($flatc.FullName)"
    $cmakeExtra += "-DTFLITE_HOST_TOOLS_DIR=$($flatc.DirectoryName)"

    # Cross degrades codegen to protoc on PATH; it must match the vendored protobuf (tflite's protobuf.cmake), not PROTOC_VERSION.
    $protocVer = Get-SourceBuildVersion -EnvironmentVariables @('LITERT_TFLITE_PROTOC_VERSION') -DefaultValue '21.9'
    $hostProtocDir = "C:\temp\protoc-$protocVer"
    $hostProtoc = Join-Path $hostProtocDir 'bin\protoc.exe'
    if (-not (Test-Path $hostProtoc)) {
        $protocZip = "C:\temp\protoc-$protocVer-win64.zip"
        Invoke-DownloadWithRetry -Url "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVer/protoc-$protocVer-win64.zip" `
            -DestinationPath $protocZip
        Expand-Archive -Path $protocZip -DestinationPath $hostProtocDir -Force
        Remove-Item $protocZip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $hostProtoc)) { throw "LiteRT cross: host protoc missing at $hostProtoc after fetch/extract" }
    Copy-Item $hostProtoc (Join-Path $flatc.DirectoryName 'protoc.exe') -Force
    $env:PATH = "$hostProtocDir\bin;$env:PATH"
    Write-Host "LiteRT cross: host protoc at $hostProtoc ($(& $hostProtoc --version)) - on PATH and beside flatc"
}

# InstallPrefix for generator expressions, even with TFLITE_ENABLE_INSTALL=OFF.
Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $buildDir -InstallPrefix $litertInstallDir -ExtraArgs $cmakeExtra | Out-Null

# XNNPACK adds per-kernel -march only for GNU frontends, so add it per TU and per family, never blanket, with a floor.
if (Test-WindowsCrossTarget) {
    # Ordered longest token first: matching stops at the first hit and names nest (neondotfp16arith, neonfp16arith).
    $xnnFeatureMap = [ordered]@{
        'neoni8mmbf16'  = 'i8mm+bf16'
        'neonbf16'      = 'bf16'
        'neondotfp16arith' = 'dotprod+fp16'
        'neondot'       = 'dotprod'
        'neonfp16arith' = 'fp16'
        'neonfp16'      = 'fp16'
        'fp16arith'     = 'fp16'
        'neoni8mm'      = 'i8mm'
        'neonsme2'      = ''   # SME needs armv9 + streaming mode: skip, dispatcher-gated out
        'neonsme'       = ''
    }
    # .S files are excluded: their features come from in-source .arch directives, prepended below.
    [void](Add-NinjaPerTuFlags -NinjaFile (Join-Path $buildDir 'build.ninja') -Label 'XNNPACK microkernel' -Floor 100 -AlreadyTaggedPattern 'armv8\.2-a' -Select {
        param($line)
        if ($line -match 'xnnpack-' -and $line -notmatch '\.S\.obj') {
            foreach ($tok in $xnnFeatureMap.Keys) {
                if ($line -match "-$tok[.-]") { if ($xnnFeatureMap[$tok]) { return "/clang:-march=armv8.2-a+$($xnnFeatureMap[$tok])" } else { return '' } }
            }
        }
        return ''
    })

    # Found by the *-asm-aarch64-*.S name, not the FetchContent layout, which LiteRT's FindXNNPACK wrapper moves.
    $xnnAsmPatched = 0
    $xnnAsmDirs = [System.Collections.Generic.HashSet[string]]::new()
    # The full feature union, unlike C: an assembler emits only the written mnemonics, and mixed kernels need several.
    foreach ($asm in (Get-ChildItem -Path @($buildDir, $SourceDir) -Recurse -Filter '*.S' -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match 'asm-aarch64' })) {
        $asmText = Get-Content -LiteralPath $asm.FullName -Raw
        if ($asmText -match '(?m)^\s*\.arch\b') { continue }
        Set-Content -LiteralPath $asm.FullName -Encoding ASCII -Value (".arch armv8.2-a+fp16+dotprod+i8mm+bf16`n" + $asmText)
        [void]$xnnAsmDirs.Add($asm.Directory.Parent.FullName)
        $xnnAsmPatched++
    }
    if ($xnnAsmDirs.Count -gt 0) { Write-Host "XNNPACK asm: kernel roots: $(@($xnnAsmDirs) -join '; ')" }
    if ($xnnAsmPatched -lt 10) {
        throw ("XNNPACK asm: prepended .arch to only $xnnAsmPatched aarch64 .S kernel(s), expected >= 10. " +
               "Either the FetchContent layout moved (searched $buildDir and $SourceDir) or the " +
               'filename convention changed; without the directive every asm-aarch64-neonfp16arith ' +
               'kernel fails in the integrated assembler.')
    }
    Write-Host "XNNPACK asm: prepended full-union .arch directives to $xnnAsmPatched aarch64 .S kernel(s)"
}

# A persistent log: inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'litert-build.log' -FallbackDir $buildDir
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# Manual install: TFLITE_ENABLE_INSTALL=OFF disables cmake --install.
Write-Host 'Installing LiteRT artifacts manually...'
Copy-BuildArtifact -BuildDir $buildDir -InstallDir $litertInstallDir -Recurse -Map @(
    @{ Filter = '*.dll'; Dest = 'bin' }
    @{ Filter = '*.lib'; Dest = 'lib' }
)
# LiteRT ships no include\; mirror its in-tree headers so consumers can #include "tflite/c/c_api.h".
Write-Host 'Copying LiteRT headers (tflite/ tree)...'
$includeRoot = Join-Path $litertInstallDir 'include\tflite'
New-Item -Path $includeRoot -ItemType Directory -Force | Out-Null
$headerCount = 0
Get-ChildItem -Path $tfliteSrc -Filter '*.h' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($tfliteSrc.Length).TrimStart('\')
    $dest = Join-Path $includeRoot $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
    Copy-Item $_.FullName $dest -Force
    $headerCount++
}
Write-Host "Copied $headerCount headers to $includeRoot"
# Copy-BuildArtifact is silent by design; a hollow install would only fail hours later in litert-lm.
if ($headerCount -eq 0) { throw "LiteRT manual install copied 0 headers to $includeRoot (source tree layout changed?)" }
$installedLibs = @(Get-ChildItem -Path (Join-Path $litertInstallDir 'lib') -Filter '*.lib' -File -ErrorAction SilentlyContinue)
if ($installedLibs.Count -lt 1) { throw "LiteRT manual install staged no .lib files into $(Join-Path $litertInstallDir 'lib') (build produced none under $buildDir?)" }
# gst's tflite plugin needs it; fail here, not hours later in the merge's meson configure.
if ('tensorflowlite_c.lib' -notin $installedLibs.Name) {
    throw ("LiteRT install is missing tensorflowlite_c.lib (the TFLite C API import lib) in $(Join-Path $litertInstallDir 'lib'). " +
        "The explicit tensorflowlite_c target build produced no import lib. Present: $($installedLibs.Name -join ', ')")
}
Write-Host "LiteRT manual install completed ($($installedLibs.Count) libs incl. tensorflowlite_c.lib)"

# Beside the install, so a QNN delegate consumer finds the backends on the DLL search path.
if ($qnnSdk) { [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $litertInstallDir) }

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== LiteRT source build completed ==='  # cleanup + banner + exit 0 (see module help)