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

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# LITERT REF SYNC: this default is the AUTHORITATIVE one. The v0.14
# support-graft in litert-lm-export-bridge.ps1 resolves the same LITERT_VERSION
# env with the same fallback -- a LiteRT bump must update BOTH defaults.
$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue 'v2.2.0'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'

Write-Host "=== LiteRT source build ($LiteRtVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT.git' -Tag "$LiteRtVersion" -SourceDir $SourceDir -Recursive | Out-Null

$tfliteSrc = Join-Path $SourceDir 'tflite'

# Inline patch (kept inline, NOT a .patch file): LiteRT ships ~17 proto/CMakeLists.txt
# files across nested subprojects, and the set of patched files varies between
# versions (new tables land in minor releases). The loop's predicate (presence of
# `protobuf_generate|protoc`) drives a per-file conditional stub. A static .patch
# against a pinned tag would silently rot when the proto set changes. Removed the
# orphaned windows/scripts/patches/litert/001-disable-proto-generation.patch (it
# only covered 2 of the ~15 files). See docs/windows-builds.md "Source Patch Policy".
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

# Inject the TFLite C API shared lib (tensorflowlite_c) into the MAIN build.
# gst-plugins-bad's tflite plugin resolves cc.find_library('tensorflowlite_c')
# FIRST and only falls back to the C++ `tensorflow-lite` lib -- which lacks the
# C API symbols like TfLiteInterpreterCreate -- when it is absent, so without
# this the gst tflite plugin fails meson configure. Upstream's own
# tflite/c/CMakeLists.txt CANNOT be reused: it is a STANDALONE project() that
# re-adds the whole tflite tree (a duplicate `tensorflow-lite` target) and
# hardcodes the pre-rename `tensorflow/lite/` layout that LiteRT no longer has.
# So append the target directly against THIS build's tensorflow-lite target and
# TFLITE_SOURCE_DIR (=CMAKE_CURRENT_LIST_DIR, the tflite dir). On WIN32,
# TFL_COMPILE_LIBRARY dllexports the C API and there are no version-script link
# flags, so it links cleanly under clang-cl. All four sources verified present.
$mainCmake = Join-Path $tfliteSrc 'CMakeLists.txt'
$capiSnippet = @'

# ---- tensorflowlite_c (TFLite C API) injected by build-litert-from-source.ps1 ----
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
# Clean any stale build artifacts (CMake pkgRedirects path casing issues).
# -ErrorAction Stop: this cleanup EXISTS to prevent stale caches -- silently
# leaving residue behind defeats its purpose, so a failed delete must be loud.
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction Stop }
if (Test-Path (Join-Path $SourceDir 'BUILD')) { Remove-Item (Join-Path $SourceDir 'BUILD') -Recurse -Force -ErrorAction Stop }

# Detect GPU environment via the canonical helper (single source of truth for CUDA/cuDNN/TRT).
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

# Add CUDA paths for external delegate compilation if available
$cmakeExtra += Get-CudaToolkitRootArg -GpuEnv $gpuEnv

# Fix CMAKE_AR path for llvm-lib (CMake resolves llvm-lib to C:\llvm-lib incorrectly)
$cmakeExtra += Get-LlvmArchiverCmakeArg

# Vulkan SDK is auto-detected by LiteRT via VULKAN_SDK env var; no need for explicit paths.

# CROSS LANE (#115, 2026-08-24): upstream's tflite/CMakeLists.txt FATAL_ERRORs
# under CMAKE_CROSSCOMPILING unless TFLITE_HOST_TOOLS_DIR names a directory with
# a HOST flatc.exe -- the schema compiler must RUN during the build. Exactly the
# knob upstream asks for, supplied the way upstream documents: configure the
# same tree NATIVELY (per-call -TargetArch override on the choke point, the
# same shape as TVM's minimal-LLVM host build) and build only the
# flatbuffers-flatc target. This keeps the flatc version pinned to whatever
# THIS LiteRT tree vendors -- no separate flatbuffers checkout to drift.
# NB flatc.exe is already on the merge arch gate's host-tool allowlist, and it
# never ships (build tree only).
# XNNPACK note, checked against the tree rather than assumed: its arch
# detection matches ^(aarch64|ARM64)$ case-exactly, which is what this repo's
# CMAKE_SYSTEM_PROCESSOR=ARM64 satisfies; the NEON_2_SSE shim is skipped
# off-x86. TFLITE_ENABLE_GPU stays ON deliberately -- first cross run is the
# probe for whether its GL/Vulkan path configures for aarch64-windows; if it
# breaks, THAT run names the flag, and OFF is the recorded fallback.
if (Test-WindowsCrossTarget) {
    $hostToolsBuild = Join-Path $SourceDir 'build-host-tools'
    if (Test-Path $hostToolsBuild) { Remove-Item $hostToolsBuild -Recurse -Force -ErrorAction Stop }
    Write-Host 'LiteRT cross: building HOST flatc (flatbuffers-flatc, native configure) for TFLITE_HOST_TOOLS_DIR...'
    # Composed FIRST, then passed: `-ExtraArgs @(...) + (...)` binds the `+` as a
    # POSITIONAL argument (it is outside the parameter expression), which put
    # garbage into -Platform and produced cmake's "No platform specified for -A"
    # (measured 2026-08-24, first cross run of this block). Same family as the
    # documented comma-doesn't-flatten trap in build-onnx-genai-from-source.ps1.
    $hostToolArgs = @(
        '-DTFLITE_ENABLE_INSTALL=OFF', '-DTFLITE_ENABLE_XNNPACK=OFF', '-DTFLITE_ENABLE_GPU=OFF',
        '-DTFLITE_ENABLE_RUY=OFF', '-DTFLITE_ENABLE_LABEL_IMAGE=OFF', '-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF'
    ) + @(Get-LlvmArchiverCmakeArg)
    Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $hostToolsBuild -InstallPrefix (Join-Path $SourceDir 'host-tools-prefix') `
        -TargetArch (Get-WindowsHostArch) -ExtraArgs $hostToolArgs | Out-Null
    & cmake --build $hostToolsBuild --target flatbuffers-flatc
    if ($LASTEXITCODE -ne 0) { throw 'LiteRT cross: host flatbuffers-flatc build failed' }
    $flatc = Get-ChildItem -Path $hostToolsBuild -Recurse -Filter 'flatc.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $flatc) { throw "LiteRT cross: flatc.exe not found under $hostToolsBuild after the host-tools build" }
    Write-Host "LiteRT cross: host flatc at $($flatc.FullName)"
    $cmakeExtra += "-DTFLITE_HOST_TOOLS_DIR=$($flatc.DirectoryName)"

    # protoc is the SECOND host tool (found 2026-08-24, run 9): natively the
    # example-proto codegen rule uses $<TARGET_FILE:protobuf::protoc> -- the
    # in-tree TARGET protoc, runnable on amd64 -- but under CMAKE_CROSSCOMPILING
    # that binary is aarch64, so upstream degrades the rule to a bare `protoc`
    # from PATH ("'protoc' is not recognized ..."). Reuse the proven pattern
    # from build-litert-lm-from-source.ps1: the official release protoc at the
    # PINNED version (PROTOC_VERSION is baked into media-litert-env; it must
    # match the vendored protobuf runtime or the generated .pb.cc #errors at
    # compile -- which is exactly the loud failure we want on a drift). Placed
    # BOTH on PATH (what the degraded rule resolves) and beside flatc in
    # TFLITE_HOST_TOOLS_DIR (what upstream's host-tools probing searches).
    # NB Install-PortableZipTool is a LOCAL function of the LM script, not a
    # module export (run-10 lesson: 'not recognized' inside this stage), so the
    # fetch goes through the module-level Invoke-DownloadWithRetry instead.
    #
    # VERSION: deliberately NOT $env:PROTOC_VERSION -- that pin (31.1) belongs
    # to LiteRT-LM's protobuf 6.31.x and generates gencode including
    # google/protobuf/runtime_version.h, which the protobuf THIS build vendors
    # does not ship (run-11 lesson: 'runtime_version.h file not found').
    # tflite/tools/cmake/modules/protobuf.cmake pins GIT_TAG 90b73ac3... =
    # protobuf 21.9 (C++ runtime 3.21.9, 2022-10-26); the host protoc must
    # match THAT. Moves with LITERT_VERSION: re-derive from the module file on
    # a LiteRT bump, and the loud gencode/#include clash is the drift detector.
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

# InstallPrefix passed for CMake generator expressions even though TFLITE_ENABLE_INSTALL=OFF
Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $buildDir -InstallPrefix $litertInstallDir -ExtraArgs $cmakeExtra | Out-Null

# CROSS LANE: per-TU feature flags for XNNPACK's aarch64 microkernels -- the
# EXACT failure class ORT's MLAS already documents (AGENTS.md § AVX-512/AMX):
# clang-cl gates NEON-extension intrinsics behind target features, and
# XNNPACK's CMake adds its per-file -march flags only on its GNU-frontend
# branch, so under the MSVC frontend every f16-*-neonfp16arith.c (measured
# 2026-08-24, first cross run: "FAILED ... f16-avgpool-9p-minmax-
# neonfp16arith.c.obj" et al.) compiles with bare armv8-a and dies.
#
# Same remedy, same discipline: append the feature per-TU in build.ninja
# post-configure -- these are runtime-dispatched microkernels, the only code
# allowed to assume the features -- and THROW below a floor, because a pattern
# that matches nothing succeeds silently (the MLAS lesson, twice-learned).
# Features are per-FAMILY from the filename token, never blanket: a plain-neon
# kernel runs on every core, so handing it +i8mm would let the compiler emit
# instructions the dispatcher never guarded.
if (Test-WindowsCrossTarget) {
    # ORDERED: longer/more-specific tokens first, because matching breaks on the
    # first hit and several names are substrings of others (neondotfp16arith ⊃
    # neonfp16arith ⊃ fp16arith). 'fp16arith' without the neon prefix is the
    # SCALAR FEAT_FP16 family (f16-vbinary/f16-vdivc-fp16arith-*.c, found run 7)
    # and needs +fp16 exactly like its vector sibling.
    # Complete against upstream's PROD_*_MICROKERNEL_SRCS family list (checked
    # 2026-08-24 rather than discovered one failing family per run): the ARM
    # families are neon/neonv8/neonfma (baseline on aarch64, no flag),
    # neonfp16, neonfp16arith, fp16arith (scalar), neondot, neondotfp16arith,
    # neonbf16, neoni8mm, neoni8mmbf16, neonsme/neonsme2 (skipped), plus the
    # aarch64 .S set handled below.
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
    $ninjaFile = Join-Path $buildDir 'build.ninja'
    $ninjaLines = Get-Content $ninjaFile
    $xnnTagged = 0
    $xnnFeature = ''
    for ($i = 0; $i -lt $ninjaLines.Count; $i++) {
        $line = $ninjaLines[$i]
        if ($line -match '^build ') {
            $xnnFeature = ''
            # .S statements are EXCLUDED. CORRECTED ROOT CAUSE (2026-08-24,
            # same day, two diagnoses later): the "unknown target CPU
            # 'armv8.2-a+fp16'" that this exclusion first blamed on a driver
            # gap was really the X86 driver reading an aarch64 -march value --
            # CMake's ASM language had no cross target at all until
            # Get-CMakeCrossArgs gained CMAKE_ASM_COMPILER_TARGET/FLAGS_INIT.
            # With the triple fixed the flags would work here too; the
            # in-source `.arch` directives (prepended below) are kept as the
            # feature mechanism because they survive independent of driver
            # translation, and double-tagging buys nothing.
            if ($line -match 'xnnpack-' -and $line -notmatch '\.S\.obj') {
                foreach ($tok in $xnnFeatureMap.Keys) {
                    if ($line -match "-$tok[.-]") { $xnnFeature = $xnnFeatureMap[$tok]; break }
                }
            }
        } elseif ($xnnFeature -and $line -match '^\s+FLAGS = ' -and $line -notmatch 'armv8\.2-a') {
            $ninjaLines[$i] = $line + " /clang:-march=armv8.2-a+$xnnFeature"
            $xnnTagged++
        }
    }
    # Floor rule (the one that failed amd64 MLAS when set too low): the first
    # measured run tags several hundred TUs; 100 is far under normal churn but
    # far over "the pattern matches nothing".
    if ($xnnTagged -lt 100) {
        throw ("build.ninja: tagged only $xnnTagged XNNPACK microkernel TU(s) with aarch64 feature flags, expected >= 100. " +
               'The XNNPACK ninja layout or filename convention changed; without these flags every neonfp16arith/neondot/' +
               'neoni8mm kernel fails to compile under clang-cl. Update the token map in build-litert-from-source.ps1.')
    }
    Set-Content -Path $ninjaFile -Value $ninjaLines
    Write-Host "build.ninja: added per-family aarch64 feature flags to $xnnTagged XNNPACK microkernel TU FLAGS line(s)"

    # The .S half of the same problem (see the exclusion note above): give each
    # hand-written aarch64 assembly kernel its feature set as an IN-SOURCE
    # `.arch` directive. The integrated assembler honors the directive exactly
    # like the flag, and no clang-cl driver translation is involved. Idempotent
    # (skips files already carrying a .arch line), family-mapped from the same
    # token table, floored like everything else in this class.
    # Located by SEARCHING for the kernels, not by assuming the FetchContent
    # layout: the first guess (_deps\xnnpack-src\src) found 0 files and the
    # floor below rightly killed the run (2026-08-24) -- LiteRT's
    # FindXNNPACK.cmake wrapper places the checkout elsewhere. The filename
    # convention (*-asm-aarch64-*.S) is the stable anchor; the directory is not.
    $xnnAsmPatched = 0
    $xnnAsmDirs = [System.Collections.Generic.HashSet[string]]::new()
    # Every .S gets the FULL feature union, deliberately NOT the per-family
    # mapping the C kernels use. The per-family rule exists because a COMPILER
    # may auto-vectorize un-guarded code with any enabled feature; an ASSEMBLER
    # emits nothing on its own -- it only validates the hand-written mnemonics,
    # so a broader .arch cannot change a single emitted byte. The per-family
    # attempt also demonstrably under-provisions: mixed kernels like
    # qd8-f16-...-neondot-ld128.S need fp16 AND dotprod while carrying only the
    # -neondot token (measured 2026-08-24, run 8).
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
               "Either the FetchContent layout moved off $xnnSrcRoot or the filename convention changed; " +
               'without the directive every asm-aarch64-neonfp16arith kernel fails in the integrated assembler.')
    }
    Write-Host "XNNPACK asm: prepended full-union .arch directives to $xnnAsmPatched aarch64 .S kernel(s)"
}

# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'litert-build.log' -FallbackDir $buildDir
# The injected tensorflowlite_c target (see above) is a normal add_library, so
# `all` builds it alongside tensorflow-lite -- no separate target invocation
# needed. The manual-install gate below hard-fails if its import lib is missing.
# MemGBPerJob 2, not 4 (backlog #74) — see the note in build-onnx-genai.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# Manual install (TFLITE_ENABLE_INSTALL=OFF disables cmake --install)
# -InstallPrefix is still passed to Invoke-CmakeConfigure because CMake generator
# expressions and INTERFACE targets reference CMAKE_INSTALL_PREFIX even when
# the install() commands are no-ops. Without it, header search paths and
# pkg-config .pc files may resolve incorrectly.
Write-Host 'Installing LiteRT artifacts manually...'
Copy-BuildArtifact -BuildDir $buildDir -InstallDir $litertInstallDir -Recurse -Map @(
    @{ Filter = '*.dll'; Dest = 'bin' }
    @{ Filter = '*.lib'; Dest = 'lib' }
)
# Copy headers. LiteRT ships NO include/ directory — its public headers live
# in-tree (tflite\c\c_api.h, tflite\interpreter.h, ...). Mirror the header tree
# under include\tflite\ preserving relative paths so consumers can
# #include "tflite/c/c_api.h".
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
# Hard gates on the manual install (Copy-BuildArtifact is silent-by-design):
# an empty header tree or a lib\ without a single .lib means the litert-lm
# stage would only fail hours later against a hollow install dir.
if ($headerCount -eq 0) { throw "LiteRT manual install copied 0 headers to $includeRoot (source tree layout changed?)" }
$installedLibs = @(Get-ChildItem -Path (Join-Path $litertInstallDir 'lib') -Filter '*.lib' -File -ErrorAction SilentlyContinue)
if ($installedLibs.Count -lt 1) { throw "LiteRT manual install staged no .lib files into $(Join-Path $litertInstallDir 'lib') (build produced none under $buildDir?)" }
# The TFLite C API import lib is a hard requirement for the gst-plugins-bad tflite
# plugin (fails loud HERE instead of hours later in the merge's meson configure).
if ('tensorflowlite_c.lib' -notin $installedLibs.Name) {
    throw ("LiteRT install is missing tensorflowlite_c.lib (the TFLite C API import lib) in $(Join-Path $litertInstallDir 'lib'). " +
        "The explicit tensorflowlite_c target build produced no import lib. Present: $($installedLibs.Name -join ', ')")
}
Write-Host "LiteRT manual install completed ($($installedLibs.Count) libs incl. tensorflowlite_c.lib)"

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== LiteRT source build completed ==='  # cleanup + banner + exit 0 (see module help)