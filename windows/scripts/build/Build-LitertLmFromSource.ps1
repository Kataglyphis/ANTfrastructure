# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\litert-lm-src',
    [string]$InstallDir = '',
    [string]$LiteRtLmVersion = '',
    [string]$VcpkgRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast before module import

# Shared assets sit beside this script in the flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.17.1'
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

#region Phase 1 | Resolve version + clone LiteRT-LM (git-lfs)
Switch-BuildPhase '1. Resolve version + clone LiteRT-LM (git-lfs)'
Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive | Out-Null

Write-Host 'Setting up git-lfs...'
# Shielded: git lfs progress on stderr is terminating under PS 5.1 EAP=Stop, even with 2>&1.
[void](Invoke-ShieldedNative -Quiet -Label 'git lfs install' -CommandLine 'git lfs install --skip-repo')
[void](Invoke-ShieldedNative -Quiet -Label 'git lfs pull' -CommandLine "cd /d `"$SourceDir`" && git lfs pull")

# The OSS-export bridge, one deletable file dot-sourced for this scope's modules. See docs/windows-builds.md § Source Patch Policy
. (Join-Path $PSScriptRoot 'Export-LitertLmBridge.ps1')
Invoke-LiteRtLmExportStubs -SourceDir $SourceDir
Invoke-LiteRtLmSupportGraft -SourceDir $SourceDir
#endregion

#region Phase 2 | Toolchain acquisition (vcpkg + host protoc 31.1 + Temurin JRE)
Switch-BuildPhase '2. Toolchain acquisition (vcpkg + host protoc 31.1 + Temurin JRE)'
# vcpkg paths: prefer -VcpkgRoot param, then $env:VCPKG_ROOT, then the container default.
$VcpkgRoot = Get-SourceBuildVersion -Value $VcpkgRoot -EnvironmentVariables @('VCPKG_ROOT') -DefaultValue 'C:\vcpkg'
# Triplet, not a literal: the base image carries both x64- and arm64-windows trees.
$vcpkgInstalledX64 = Join-Path $VcpkgRoot "installed\$(Get-VcpkgTriplet)"

# Chain stages run in-process, so the finally at the end restores what Phases 2-4 change.
$litertLmEnvSnapshot = @{}
foreach ($envName in @('CMAKE_PREFIX_PATH', 'LIB', 'CXXFLAGS', 'CCC_OVERRIDE_OPTIONS', 'CXXFLAGS_x86_64_pc_windows_msvc')) {
    $litertLmEnvSnapshot[$envName] = [Environment]::GetEnvironmentVariable($envName)
}
try {

$env:CMAKE_PREFIX_PATH = "$vcpkgInstalledX64;$env:CMAKE_PREFIX_PATH"
$protobufTools = Join-Path $vcpkgInstalledX64 'tools\protobuf'
if (Test-Path $protobufTools) { $env:PATH = "$protobufTools;$env:PATH" }

# The PK magic-byte check turns an HTML error page into an early failure, not a later Expand-Archive one.
function Install-PortableZipTool {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description,
        # Returns the tool's path/item when present, $null/empty otherwise.
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    $found = & $Probe
    if ($found) { return $found }
    Write-Host "Downloading $Description from $Url"
    Invoke-DownloadWithRetry -Url $Url -DestinationPath $ZipPath -Description $Description -ExpectSignature PK
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
    $found = & $Probe
    if (-not $found) { throw "Failed to obtain $Description under $Destination" }
    return $found
}

# Must match the from-source protobuf runtime: vcpkg's protoc is another major, and a source-built one fails to link.
$protocVer = Get-SourceBuildVersion -EnvironmentVariables @('PROTOC_VERSION') -DefaultValue '35.1'
$hostProtocDir = "C:\temp\protoc-$protocVer"
$hostProtoc = Join-Path $hostProtocDir 'bin\protoc.exe'
[void](Install-PortableZipTool -Url "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVer/protoc-$protocVer-win64.zip" `
        -ZipPath "C:\temp\protoc-$protocVer-win64.zip" -Destination $hostProtocDir `
        -Description "version-matched protoc v$protocVer" `
        -Probe { if (Test-Path $hostProtoc) { $hostProtoc } })
Write-Host "Using version-matched host protoc: $hostProtoc ($(& $hostProtoc --version))"

# The build runs the prebuilt ANTLR jar and the media base ships no Java; a JRE is enough.
$jreVer = Get-SourceBuildVersion -EnvironmentVariables @('JRE_VERSION') -DefaultValue '21'
$jreDir = 'C:\temp\jre'
$javaExe = Install-PortableZipTool -Url "https://api.adoptium.net/v3/binary/latest/$jreVer/ga/windows/x64/jre/hotspot/normal/eclipse" `
    -ZipPath 'C:\temp\temurin-jre.zip' -Destination $jreDir `
    -Description "Temurin $jreVer JRE (for ANTLR codegen)" `
    -Probe { Get-ChildItem -Path $jreDir -Recurse -Filter java.exe -ErrorAction SilentlyContinue | Select-Object -First 1 }
$env:PATH = "$($javaExe.Directory.FullName);$env:PATH"
Write-Host "Using Java for ANTLR codegen: $($javaExe.FullName)"

#endregion

#region Phase 3 | Windows link-lib + POSIX header shims (rt/pthread/dl/z, dlfcn/unistd/alloca, LIB)
Switch-BuildPhase '3. Windows link-lib + POSIX header shims (rt/pthread/dl/z, dlfcn/unistd/alloca, LIB)'
# lld-link gets CMake's POSIX -lrt/-lpthread/-ldl/-lz as .libs: empty archives for the #ifdef'd-out three, vcpkg's zlib.
$stubLibDir = 'C:\temp\winstublibs'
New-Item -ItemType Directory -Force $stubLibDir | Out-Null
$llvmLib = (Get-Command llvm-lib.exe -ErrorAction Stop).Source
foreach ($stub in @('rt', 'pthread', 'dl')) {
    $stubLibPath = Join-Path $stubLibDir "$stub.lib"
    $stubOut = & $llvmLib "/out:$stubLibPath" /llvmlibempty 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $stubLibPath)) {
        # A missing stub only surfaces much later as 'lld-link: could not open <stub>.lib'.
        throw "llvm-lib failed to create link-lib stub $stub.lib (exit $LASTEXITCODE): $(@($stubOut) -join [Environment]::NewLine)"
    }
}
$vcpkgZlib = Join-Path $vcpkgInstalledX64 'lib\z.lib'
if (Test-Path $vcpkgZlib) { Copy-Item $vcpkgZlib (Join-Path $stubLibDir 'z.lib') -Force }

# dynamic_loading.cc includes <dlfcn.h> unguarded; the shim maps dl* onto LoadLibrary/GetProcAddress.
$winShimDir = 'C:\temp\winshims'
New-Item -ItemType Directory -Force $winShimDir | Out-Null
Copy-Item (Join-Path $scriptAssetRoot 'shims\dlfcn.h') $winShimDir -Force

# Its unguarded <unistd.h> needs only the POSIX permission-mode constants; access() is in <io.h>.
Copy-Item (Join-Path $scriptAssetRoot 'shims\unistd.h') $winShimDir -Force

# LiteRT's Qualcomm vendor code includes <alloca.h>; the CRT puts alloca in <malloc.h>.
Copy-Item (Join-Path $scriptAssetRoot 'shims\alloca.h') $winShimDir -Force
Write-Host "Wrote Windows <dlfcn.h> + <unistd.h> + <alloca.h> shims to $winShimDir"
# clang auto-detects the system lib dirs only while LIB is unset, so a set LIB must carry them or links lose kernel32.
$clangHome = Split-Path (Split-Path (Get-Command clang++.exe -ErrorAction Stop).Source)
# One token for both trees: the MSVC and SDK lib dirs spell the arch identically.
$msvcLibArch = Get-MsvcTargetLibDir
$sysLibGlobs = @(
    "C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\$msvcLibArch",
    "C:\Program Files (x86)\Windows Kits\10\Lib\*\ucrt\$msvcLibArch",
    "C:\Program Files (x86)\Windows Kits\10\Lib\*\um\$msvcLibArch",
    (Join-Path $clangHome "lib\clang\*\lib\$(Get-ClangTargetTriple)"),
    (Join-Path $clangHome 'lib\clang\*\lib\windows')
)
$sysLibDirs = @(foreach ($g in $sysLibGlobs) {
    $d = Get-ChildItem $g -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($d) { $d.FullName }
})
# Fail NOW with the glob list instead of hours later inside the ExternalProject.
if ($sysLibDirs.Count -lt 3) {
    throw "resolved only $($sysLibDirs.Count) MSVC/SDK/clang system lib dir(s) for LIB (need MSVC + ucrt + um at minimum); globs: $($sysLibGlobs -join ' | ')"
}
$env:LIB = (@($stubLibDir) + $sysLibDirs) -join ';'
Write-Host "Created Windows link-lib shims (rt/pthread/dl empty; z=vcpkg zlib); LIB = shim + $(@($sysLibDirs).Count) MSVC/SDK/clang lib dirs"

# Cargo: honor the existing $env:CARGO_HOME (set in Dockerfile.base); only fall back to a default if unset.
if ([string]::IsNullOrWhiteSpace($env:CARGO_HOME)) { $env:CARGO_HOME = Join-Path $env:USERPROFILE '.cargo' }
$cargoBin = Join-Path $env:CARGO_HOME 'bin'
if (($env:PATH -notlike "*$cargoBin*") -and (Test-Path $cargoBin)) { $env:PATH = "$cargoBin;$env:PATH" }

#endregion

#region Phase 4 | clang++ compiler environment (CXXFLAGS / CCC_OVERRIDE_OPTIONS)
Switch-BuildPhase '4. clang++ compiler environment (CXXFLAGS / CCC_OVERRIDE_OPTIONS)'
# Target-scoped to the cc/cxx crate bridge only, as the inner clang++ configure check rejects stray flags.
$env:CXXFLAGS_x86_64_pc_windows_msvc = (@($env:CXXFLAGS_x86_64_pc_windows_msvc, '-std=c++17', '-D_DLL', '-D_MT', '-Xclang', '--dependent-lib=msvcrt') | Where-Object { $_ }) -join ' '
Write-Host "Set CXXFLAGS_x86_64_pc_windows_msvc for the cxx/cc bridge: $($env:CXXFLAGS_x86_64_pc_windows_msvc)"

# Every sub-build seeds from $ENV{CXXFLAGS}; -fdelayed-template-parsing is deprecated past C++20, so check it on an LLVM bump.
$env:CXXFLAGS = (@($env:CXXFLAGS, (Get-WarningNoiseSuppressionFlags), '-fdelayed-template-parsing', '-Wno-delayed-template-parsing-in-cxx20', '-isystem C:/temp/winshims', '-DNOMINMAX', '-DNOGDI', '-include unistd.h', '-D_USE_MATH_DEFINES') | Where-Object { $_ }) -join ' '
Write-Host "Set CXXFLAGS (delayed template parsing + dlfcn/unistd/alloca shim + NOMINMAX/NOGDI + force-include unistd.h) for CMake sub-builds: $env:CXXFLAGS"

# Deletes -fPIC and gemmlowp's cl.exe flags from clang's command line; only `x` edits, as `+` also hits the .rc compiler.
$env:CCC_OVERRIDE_OPTIONS = '#x-fPIC x/bigobj x/nologo x/EHsc x/GF x/MP x/Gm- x/wd4800 x/wd4805 x/wd4244'
Write-Host "Set CCC_OVERRIDE_OPTIONS to strip -fPIC + gemmlowp MSVC flags from clang++ (windows-msvc target rejects them)"

#endregion

#region Phase 5 | Source tree & CMake winfix patches (clang-cl/lld-link port)
Switch-BuildPhase '5a. Source tree + dependency-pin bumps (absl/litert)'
# Upstream typo leaves minja's examples on to fail its -Werror; \b keeps the fix idempotent.
$fetchContentCmake = Join-Path $SourceDir 'cmake\modules\fetch_content.cmake'
[void](Edit-SourceFile -Path $fetchContentCmake -Description 'fetch_content.cmake: MINJA_EXAMPLE_ENABLE -> MINJA_EXAMPLE_ENABLED (disable minja example programs)' -Transform {
    param($c)
    $c -replace 'MINJA_EXAMPLE_ENABLE\b', 'MINJA_EXAMPLE_ENABLED'
})

# Upstream's cmake proto list is stale (that lane has no CI) and misses four protos the sources include.
$llmPkgCmake = Join-Path $SourceDir 'cmake\packages\litert_lm\CMakeLists.txt'
[void](Edit-SourceFile -Path $llmPkgCmake -Marker 'embedding_metadata\.proto' -Description 'litert_lm CMakeLists: add the four 0.15.0 protos missing from the stale cmake list' -WarnMessage 'litert_lm proto-list anchor (token.proto) not found; embedding_metadata.pb.h will be missing at compile' -Transform {
    param($c)
    $llmAnchor = '"${LITERTLM_PROJECT_ROOT}/runtime/proto/token.proto"'
    $llmAdd = $llmAnchor + "`n" +
    '  "${LITERTLM_PROJECT_ROOT}/runtime/proto/embedding_metadata.proto"' + "`n" +
    '  "${LITERTLM_PROJECT_ROOT}/runtime/proto/embedding_model_type.proto"' + "`n" +
    '  "${LITERTLM_PROJECT_ROOT}/runtime/proto/executor_metadata.proto"' + "`n" +
    '  "${LITERTLM_PROJECT_ROOT}/runtime/proto/litert_lm_metrics.proto"'
    $c.Replace($llmAnchor, $llmAdd)
})

# Upstream's absl pin predates the status_macros.h its sources include; bump absl_external to ABSEIL_VERSION.
$abslPkgCmake = Join-Path $SourceDir 'cmake\packages\absl\absl.cmake'
$abseilPin = Get-SourceBuildVersion -EnvironmentVariables @('ABSEIL_VERSION') -DefaultValue '20260817.0'
$abseilPinMarker = [regex]::Escape($abseilPin)
[void](Edit-SourceFile -Path $abslPkgCmake -Marker $abseilPinMarker -Description "absl.cmake: bump stale upstream absl pin 20260107.1 -> $abseilPin (status_macros.h)" -WarnMessage 'absl.cmake GIT_TAG anchor not found; status_macros.h includes will fail' -Transform {
    param($c)
    $c -replace '(GIT_TAG\s*\r?\n\s*)20260107\.1', ('${1}' + $abseilPin)
})

# Patch anchors, not versions.env pins: upstream's stale cmake SHA corrected to its own bazel WORKSPACE.
$litertPkgCmake = Join-Path $SourceDir 'cmake\packages\litert\litert.cmake'
[void](Edit-SourceFile -Path $litertPkgCmake -Marker '3cb830ad9c94f9922f0a88dd431b005413628919' -Description 'litert.cmake: bump stale upstream litert pin fb16353a -> 3cb830ad (bazel WORKSPACE truth; SetEnableYNNPack/RunAsync APIs)' -WarnMessage 'litert.cmake GIT_TAG anchor fb16353a not found; executor API-skew compile errors will follow' -Transform {
    param($c)
    $c -replace 'fb16353a648922cb6c67a8e9a7a9ebc946360ad2', '3cb830ad9c94f9922f0a88dd431b005413628919'
})

# LITERTLM_HOST_FLATC names a cross prebuild flatc a native build never makes; use flatbuffers_external's.
$flatbuffersCmake = Join-Path $SourceDir 'cmake\packages\flatbuffers\flatbuffers.cmake'
[void](Edit-SourceFile -Path $flatbuffersCmake -Marker 'native win flatc' -Description 'flatbuffers.cmake: force native flatc.exe for compile_schemas (WIN32)' -Transform {
    param($c)
    $anchor = 'ExternalProject_Add_Step(flatbuffers_external compile_schemas'
    $inject = @(
        'if(WIN32)',
        'set(FLATC_EXECUTABLE "${FLATBUFFERS_INSTALL_PREFIX}/bin/flatc.exe" CACHE INTERNAL "native win flatc" FORCE)',
        'endif()',
        ''
    ) -join "`n"
    $c.Replace($anchor, $inject + $anchor)
})

# The inner EP defaults to Debug, whose STL breaks protobuf's constinit empty string; anchored on the unique flatc arg.
$superCmake = Join-Path $SourceDir 'CMakeLists.txt'
[void](Edit-SourceFile -Path $superCmake -Marker 'force-release-buildtype' -Description 'CMakeLists.txt: force inner litert_lm CMAKE_BUILD_TYPE=Release' -Transform {
    param($c)
    $btAnchor = '"-DLITERTLM_HOST_FLATC_BIN_DIR=${LITERTLM_HOST_FLATC_BIN_DIR}"'
    $btRepl = $btAnchor + "`n        `"-DCMAKE_BUILD_TYPE=Release`"  # force-release-buildtype"
    $c.Replace($btAnchor, $btRepl)
})

Switch-BuildPhase '5b. externals: protobuf / sentencepiece / tokenizers'
# protoc-gen-upb/-upbdefs fail to link (abseil) and nothing runs them; libupb.a is built separately.
$protobufPatcher = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf_patcher.cmake'
$upbPatch = Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\protobuf-upb-generators-skip.cmake')
[void](Add-FileBlockOnce -Path $protobufPatcher -Marker 'LiteRTLM-winfix upb_generators' -Content $upbPatch `
        -Description 'protobuf_patcher.cmake: skip protoc-gen-upb/-upbdefs tools (unused, abseil link failure)')

# protobuf's protoc.exe fails the same link and codegen uses the host one: import that via WITH_PROTOC.
$protobufPkg = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf.cmake'
[void](Edit-SourceFile -Path $protobufPkg -Marker 'WITH_PROTOC' -Description 'protobuf.cmake: -DWITH_PROTOC=host protoc (skip building protoc.exe; abseil link failure)' -WarnMessage 'protobuf.cmake anchor for WITH_PROTOC not found; protoc.exe may still build' -Transform {
    param($c)
    $anchor = '-Dprotobuf_BUILD_PROTOBUF_BINARIES=ON'
    $repl = $anchor + "`n        " + '-DWITH_PROTOC=${LITERTLM_HOST_PROTOC}'
    $c.Replace($anchor, $repl)
})

# clang takes sentencepiece's `if(NOT MSVC)` branch and its -fPIC, an error on windows-msvc.
$spPatcher = Join-Path $SourceDir 'cmake\packages\sentencepiece\sentencepiece_patcher.cmake'
$spPatch = Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\sentencepiece-winfix.cmake')
[void](Add-FileBlockOnce -Path $spPatcher -Marker 'LiteRTLM-winfix sentencepiece-fpic' -Content $spPatch `
        -Description 'sentencepiece_patcher.cmake: strip -fPIC + skip spm CLI tools (windows-msvc/abseil link)')

# tokenizers-cpp's configure has no -G (the VS default uses CL.exe), builds with `make`, and expects a GNU-named rust lib.
$tokenizersCmake = Join-Path $SourceDir 'cmake\packages\tokenizers\tokenizers.cmake'
if ((Test-Path $tokenizersCmake) -and ((Get-Content -Raw $tokenizersCmake) -notmatch '<BINARY_DIR> -GNinja')) {
    $tk = [System.IO.File]::ReadAllText($tokenizersCmake)
    $tkAnchor = '-S <SOURCE_DIR> -B <BINARY_DIR>'
    $tkPrefixArg = '"-DCMAKE_PREFIX_PATH=${ABSL_INSTALL_PREFIX};${PROTO_INSTALL_PREFIX};${SENTENCE_INSTALL_PREFIX}"'
    $tkCfgAnchor = 'CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env'
    if ($tk.Contains($tkAnchor) -and $tk.Contains($tkPrefixArg) -and $tk.Contains($tkCfgAnchor)) {
        # (1) Ninja generator
        $tk = $tk.Replace($tkAnchor, '-S <SOURCE_DIR> -B <BINARY_DIR> -GNinja')
        # (2) explicit build/install commands (no `make`)
        $tkBuildInstall = $tkPrefixArg + "`n    BUILD_COMMAND " + '${CMAKE_COMMAND}' + " --build <BINARY_DIR>`n    INSTALL_COMMAND " + '${CMAKE_COMMAND}' + " --build <BINARY_DIR> --target install"
        $tk = $tk.Replace($tkPrefixArg, $tkBuildInstall)
        # (3a) PATCH_COMMAND to fix the fetched tokenizers-cpp CMakeLists rust-lib name
        $tkPatchScript = Join-Path (Split-Path $tokenizersCmake) 'tokenizers_libname_patch.cmake'
        Copy-Item (Join-Path $scriptAssetRoot 'patches\litert-lm\tokenizers_libname_patch.cmake') $tkPatchScript -Force
        $tkPatchCmd = 'PATCH_COMMAND ${CMAKE_COMMAND} -DTK_SRC=<SOURCE_DIR> -P ${CMAKE_CURRENT_LIST_DIR}/tokenizers_libname_patch.cmake' + "`n    " + $tkCfgAnchor
        $tk = $tk.Replace($tkCfgAnchor, $tkPatchCmd)
        # (3b) litert-lm's own imports of the rust lib (leaves libtokenizers_cpp.a untouched)
        if (-not $tk.Contains('libtokenizers_c.a')) {
            Write-Warning 'tokenizers.cmake: libtokenizers_c.a not found — upstream renamed the rust lib import; the link will fail with unresolved tokenizers_c symbols'
        }
        $tk = $tk.Replace('libtokenizers_c.a', 'tokenizers_c.lib')
        [System.IO.File]::WriteAllText($tokenizersCmake, $tk)
        Write-Host 'Patched tokenizers.cmake: -GNinja + cmake --build + rust lib -> tokenizers_c.lib'
    }
    else {
        Write-Host 'WARNING: tokenizers.cmake anchors not found; may still use CL.exe/make/libtokenizers_c.a'
    }
}

# TFLite already generates these protos, so a second generate_protobuf collides in ninja and at link.
$tfliteShims = Join-Path $SourceDir 'cmake\packages\tflite\tflite_shims.cmake'
[void](Edit-SourceFile -Path $tfliteShims -Marker 'LiteRTLM-winfix tflite-profiling-proto' -Description 'tflite_shims.cmake: drop redundant tflite_profiling proto gen + exclude Android-only atrace_profiler.cc' -WarnMessage 'tflite_shims.cmake generate_protobuf(tflite_profiling) anchor not found' -Transform {
    param($c)
    $tsAnchor = 'generate_protobuf(tflite_profiling ${TENSORFLOW_SOURCE_DIR})'
    $tsRepl = @'
# [LiteRTLM-winfix tflite-profiling-proto] TFLite's profiling/proto/CMakeLists already emits
# profiling_info.pb.cc / model_runtime_info.pb.cc into {profiling,model_runtime}_info_proto,
# which the aggregate links; regenerating them here produced a second ninja rule for the same
# output ("multiple rules generate profiling_info.pb.cc") and duplicate proto symbols at link.
# Depend on TFLite's generated headers instead of recompiling the protos into tflite_profiling.
set_source_files_properties(${PROFILING_SRCS} PROPERTIES OBJECT_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/tensorflow/lite/profiling/proto/profiling_info.pb.h;${CMAKE_CURRENT_BINARY_DIR}/tensorflow/lite/profiling/proto/model_runtime_info.pb.h")
'@
    $c = $c.Replace($tsAnchor, $tsRepl)
    # atrace_profiler.cc is Android-only (dlopens libandroid) and the glob only drops *_test.cc.
    $c.Replace('EXCLUDE REGEX "_test\\.cc$"', 'EXCLUDE REGEX "(_test|atrace_profiler)\\.cc$"')
})

# clang++'s MSVC friend extension binds model_building.h's friends to an outer namespace; via the patcher, as the EP git-resets.
$tflitePatcher = Join-Path $SourceDir 'cmake\packages\tflite\tflite_patcher.cmake'
$mbPatch = Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\tflite-model-building-friend.cmake')
[void](Add-FileBlockOnce -Path $tflitePatcher -Marker 'LiteRTLM-winfix model_building-friend' -Content $mbPatch -Encoding ASCII `
        -Description 'tflite_patcher.cmake: model_building.h friend forward-declarations')

Switch-BuildPhase '5c. litert core winfixes (POSIX->Win32 narrowing)'
# litert's CXX flags miss the flatbuffers include the Qualcomm plugin's flexbuffers.h needs.
$litertCmake = Join-Path $SourceDir 'cmake\packages\litert\litert.cmake'
[void](Edit-SourceFile -Path $litertCmake -Marker '-isystem \$\{FLATBUFFERS_INCLUDE_DIR\}' -Description 'litert.cmake: add flatbuffers install include to litert CXX flags' -WarnMessage 'litert.cmake CXX flags anchor not found; flexbuffers.h may be missing' -Transform {
    param($c)
    $lcAnchor = '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -w"'
    $c.Replace($lcAnchor, '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -isystem ${FLATBUFFERS_INCLUDE_DIR} -w"')
})

# std::filesystem::path is wide on Windows, so dynamic_loading.cc needs .string(); via the patcher, as the EP git-resets.
$litertPatcher = Join-Path $SourceDir 'cmake\packages\litert\litert_patcher.cmake'
$dlPatch = Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\litert-patcher-winfix.cmake')
# Print what THIS container read: makes stale-bind vs. non-execution decidable from the log.
Write-Host ("litert-patcher-winfix.cmake read: {0} chars; examples REMOVE_RECURSE block present: {1}" -f $dlPatch.Length, $dlPatch.Contains('REMOVE_RECURSE'))
[void](Add-FileBlockOnce -Path $litertPatcher -Marker 'LiteRTLM-winfix dynamic-loading' -Content $dlPatch -Encoding ASCII `
        -Description 'litert_patcher.cmake: dynamic_loading.cc std::filesystem::path narrowing')

# SetWeightCacheFd takes a POSIX fd and GPU is off here; this repo's own source, so patched directly.
$execUtils = Join-Path $SourceDir 'runtime\executor\litert_compiled_model_executor_utils.cc'
[void](Edit-SourceFile -Path $execUtils -Marker 'LiteRTLM-winfix.*SetWeightCacheFd' -Description 'litert_compiled_model_executor_utils.cc: guard SetWeightCacheFd on Windows' -WarnMessage 'SetWeightCacheFd anchor not found in executor utils' -Transform {
    param($c)
    $euAnchor = 'gpu_options.SetWeightCacheFd(fd);'
    $euRepl = "#if !defined(_WIN32)`n      gpu_options.SetWeightCacheFd(fd);`n#else`n      (void)fd;  // [LiteRTLM-winfix] litert::GpuOptions has no fd-based weight cache on Windows`n#endif"
    $c.Replace($euAnchor, $euRepl)
})

# Setters the Windows litert build lacks; [^;] spans the multi-line call, as it matches newlines in .NET.
$settingsUtils = Join-Path $SourceDir 'runtime\executor\llm_executor_settings_utils.cc'
[void](Edit-SourceFile -Path $settingsUtils -Marker 'LiteRTLM-winfix' -Description 'llm_executor_settings_utils.cc: guard Windows-absent GpuOptions/RuntimeOptions setters' -Transform {
    param($su)
    foreach ($m in @('gpu_compilation_options.SetKernelBatchSize', 'runtime_options.SetDisableDelegateClustering')) {
        $pat = [regex]::Escape($m) + '\([^;]*\);'
        $su = [regex]::Replace($su, $pat, {
            param($mm)
            "#if !defined(_WIN32)  // [LiteRTLM-winfix] litert GpuOptions/RuntimeOptions setter absent on Windows`n      " + $mm.Value + "`n#endif"
        })
    }
    $su
})

# Guarding whole blocks, not calls, leaves the params non-quantized; the NPU executor is dead on Windows anyway.
$npuExec = Join-Path $SourceDir 'runtime\executor\llm_litert_npu_compiled_model_executor.cc'
[void](Edit-SourceFile -Path $npuExec -Marker 'LiteRTLM-winfix' -Description 'llm_litert_npu_compiled_model_executor.cc: guard Windows-absent SimpleTensor quantization API' -Transform {
    param($ne)
    $blocks = @(
        'if \(tensor_expected->HasQuantization\(\)\) \{[\s\S]*?q_params\.zero_point = pq\.zero_point;\s*\}',
        'if \(logits_tensor\.HasQuantization\(\)\) \{[\s\S]*?<< "\)\.";\s*\}'
    )
    foreach ($b in $blocks) {
        $ne = [regex]::Replace($ne, $b, {
            param($mm)
            "#if !defined(_WIN32)  // [LiteRTLM-winfix] litert::SimpleTensor quantization API absent on Windows (NPU off)`n" + $mm.Value + "`n#endif"
        })
    }
    $ne
})

# The Windows litert build lacks GoogleTensorOptions' perf mode; guard the whole block so no bound reference dangles.
Get-ChildItem (Join-Path $SourceDir 'runtime\executor') -Filter '*_litert_compiled_model_executor.cc' -ErrorAction SilentlyContinue | ForEach-Object {
    $gtFile = $_.FullName
    $gtRaw = Get-Content -Raw $gtFile
    if (($gtRaw -match 'GoogleTensorOptions::PerformanceMode') -and ($gtRaw -notmatch 'LiteRTLM-winfix google_tensor')) {
        $gt = [regex]::Replace($gtRaw, 'LITERT_ASSIGN_OR_RETURN\(auto& google_tensor_options,[\s\S]*?PerformanceMode::kBurst\);', {
            param($mm)
            "#if !defined(_WIN32)  // [LiteRTLM-winfix google_tensor] GoogleTensorOptions perf-mode API absent on Windows`n      " + $mm.Value + "`n#endif"
        })
        [System.IO.File]::WriteAllText($gtFile, $gt)
        Write-Host "Patched $($_.Name): guard Windows-absent GoogleTensorOptions::SetPerformanceMode"
    }
}

# The OSS export stripped three sources the CMake still names and wired the real engine into no target.
$coreCmake = Join-Path $SourceDir 'runtime\core\CMakeLists.txt'
[void](Edit-SourceFile -Path $coreCmake -Marker 'LiteRTLM-winfix' -Description 'runtime/core/CMakeLists.txt: point runtime_core_engine_impl at engine_advanced_impl.cc' -Transform {
    param($c)
    # ' STATIC' excludes the _cpu_only target sharing this prefix; the engine in both would double-define.
    [regex]::Replace($c,
        '(runtime_core_engine_impl STATIC\s+)engine_impl\.cc',
        '${1}engine_advanced_impl.cc  # [LiteRTLM-winfix] engine_impl.cc stripped from OSS; real engine is engine_advanced_impl.cc')
})

$strippedStubs = @{
    'runtime\core\session_basic.cc'   = 'session_basic'
    'runtime\core\session_factory.cc' = 'session_factory'
    'runtime\core\engine_impl.cc'     = 'engine_impl'
}
foreach ($rel in $strippedStubs.Keys) {
    $stubPath = Join-Path $SourceDir $rel
    if (-not (Test-Path $stubPath)) {
        $tag = $strippedStubs[$rel]
        @"
// [LiteRTLM-winfix] Placeholder for $tag.cc, which runtime/core/CMakeLists.txt references but which
// the LiteRT-LM OSS release (v0.13.1) does not ship ($tag.cc and $tag.h are both 404 upstream). No
// translation unit includes $tag.h or names its symbols, so this empty TU satisfies the otherwise-
// dangling target and its link edges. (The real engine is compiled from engine_advanced_impl.cc.)
namespace litert::lm::winfix_${tag}_placeholder {}
"@ | Set-Content -LiteralPath $stubPath -Encoding UTF8
        Write-Host "Created placeholder $tag.cc (not shipped in LiteRT-LM OSS v0.13.1)"
    }
}

# Sources only Bazel lists (cpu_affinity_utils.cc and others) go into the engine lib, which litert_lm_main links.
$engineCmake = Join-Path $SourceDir 'runtime\engine\CMakeLists.txt'
[void](Edit-SourceFile -Path $engineCmake -Marker 'LiteRTLM-winfix cpu_affinity' -Description 'runtime/engine/CMakeLists.txt: compile cpu_affinity_utils.cc + 6 orphan sources into runtime_engine_litert_lm_lib' -Transform {
    param($c)
    [regex]::Replace($c,
        '(add_litertlm_library\(runtime_engine_litert_lm_lib STATIC\s+litert_lm_lib\.cc)',
        "`$1`n  cpu_affinity_utils.cc  # [LiteRTLM-winfix cpu_affinity] compiled by Bazel but omitted from the CMake target`n  ../conversation/channel_util.cc  # [LiteRTLM-winfix orphans]`n  ../components/preprocessor/image_preprocessor_utils.cc`n  ../conversation/model_data_processor/fastvlm_data_processor.cc`n  ../conversation/model_data_processor/gemma4_data_processor.cc`n  ../util/litert_util.cc`n  ../components/constrained_decoding/llg_tool_call_utils.cc`n  ../components/model_resources_streaming.cc`n  ../core/session_advanced.cc`n  ../executor/litert/kv_cache.cc`n  ../executor/llm_litert_npu_compiled_model_executor_utils.cc`n  ../framework/execution_queue.cc`n  ../framework/resource_management/context_handler/context_handler.cc`n  ../framework/resource_management/resource_manager.cc`n  ../framework/resource_management/serial_execution_manager.cc`n  ../framework/resource_management/threaded_execution_manager.cc`n  ../framework/resource_management/utils/resource_manager_utils.cc`n  ../util/data_stream.cc`n  ../util/file_data_stream.cc`n  ../util/litert_lm_streaming_loader.cc`n  ../util/log_tensor_buffer.cc")
})
# v0.14 orphans/subsystems/deps live in the export bridge; the caller owns the write cycle.
$engineTxt = [System.IO.File]::ReadAllText($engineCmake)
$engineBridged = Add-LiteRtLmV014OrphanSources -EngineCmakeText $engineTxt -SourceDir $SourceDir
if ($engineBridged -ne $engineTxt) {
    [System.IO.File]::WriteAllText($engineCmake, $engineBridged)
    Write-Host '[LiteRTLM-winfix orphans] engine lib source list updated'
}

Switch-BuildPhase '5d. runtime CMake retargets (engine/util/logger winfixes)'
# The pinned litert core lacks Tag::kMinLoggerSeverity, and the block only pushes an optional env option.
foreach ($rel in @('runtime\util\litert_util.cc', 'runtime\framework\resource_management\resource_manager.cc')) {
    # Edit-SourceFile, not a raw write: a raw write logs "Patched" on a no-op match.
    [void](Edit-SourceFile -Path (Join-Path $SourceDir $rel) `
            -Marker 'LiteRTLM-winfix kMinLoggerSeverity' `
            -Description "$(Split-Path $rel -Leaf) (compile out kMinLoggerSeverity env option, absent in pinned litert core)" `
            -Transform {
            param($t)
            [regex]::Replace($t,
                '(if \(auto severity = GetMinLogSeverity\(\)\) \{[\s\S]*?kMinLoggerSeverity[\s\S]*?\)\}\);\s*\})',
                "#if 0  // [LiteRTLM-winfix kMinLoggerSeverity] litert core pinned here has no such Tag`n      `$1`n#endif")
        })
}

# rust std's #[link] libs are lost through the C++ driver and CMake cannot reach the link spec; #pragma comment(lib) can.
$cpuAffCc = Join-Path $SourceDir 'runtime\engine\cpu_affinity_utils.cc'
$pragmaBlock = Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\cpu-affinity-rust-syslibs.cc')
[void](Add-FileBlockOnce -Path $cpuAffCc -Marker 'LiteRTLM-winfix rust-syslibs' -Content $pragmaBlock -Prepend `
        -Description 'cpu_affinity_utils.cc: #pragma comment(lib) rust-std windows system libs into litert_lm_main')

# re2's EP passes no build type, so its _ITERATOR_DEBUG_LEVEL=2 fails lld-link's /failifmismatch.
$re2Cmake = Join-Path $SourceDir 'cmake\packages\re2\re2.cmake'
[void](Edit-SourceFile -Path $re2Cmake -Marker 'LiteRTLM-winfix re2-idl' -Description 're2.cmake: force Release/NDEBUG + dynamic CRT (fix _ITERATOR_DEBUG_LEVEL mismatch)' -Transform {
    param($c)
    $inject = "CMAKE_ARGS`n        -DCMAKE_BUILD_TYPE=" + '${CMAKE_BUILD_TYPE}' + "  # [LiteRTLM-winfix re2-idl] NDEBUG -> _ITERATOR_DEBUG_LEVEL=0 to match the rest`n        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    $c.Replace('CMAKE_ARGS', $inject)
})

# ANTLR defaults to the static CRT, which lld-link's /failifmismatch rejects next to the dynamic rest.
$fetchContent = Join-Path $SourceDir 'cmake\modules\fetch_content.cmake'
[void](Edit-SourceFile -Path $fetchContent -Marker 'LiteRTLM-winfix WITH_STATIC_CRT' -Description 'fetch_content.cmake: force antlr WITH_STATIC_CRT OFF (dynamic CRT to match)' -Transform {
    param($c)
    $c.Replace(
        'set(ANTLR_BUILD_STATIC ON)',
        'set(ANTLR_BUILD_STATIC ON)
  set(WITH_STATIC_CRT OFF CACHE BOOL "" FORCE)  # [LiteRTLM-winfix WITH_STATIC_CRT] match the dynamic CRT (/MD) of the rest; avoids lld-link /failifmismatch')
})

# clang++ takes the GNU link branch, whose --whole-archive/--start-group lld-link silently ignores.
$litertLmPkg = Join-Path $SourceDir 'cmake\packages\litert_lm\CMakeLists.txt'
[void](Edit-SourceFile -Path $litertLmPkg -Marker 'LiteRTLM-winfix link-spec' -Description 'litert_lm/CMakeLists.txt: route Windows clang++/lld-link to the MSVC /WHOLEARCHIVE link spec (-Wl, prefixed)' -Transform {
    param($c)
    $c = [regex]::Replace($c,
        'if\(CMAKE_CXX_COMPILER_ID MATCHES "Clang\|GNU"\)(\s*if\(APPLE\))',
        'if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU" AND NOT WIN32)  # [LiteRTLM-winfix link-spec] lld-link ignores GNU --whole-archive/--start-group; route Windows to the MSVC branch$1')
    $c = [regex]::Replace($c,
        'elseif\(MSVC\)(\s*#\s*Windows Linker)',
        'elseif(MSVC OR WIN32)$1')
    # CMake reads a leading-'/' link item as an input file, so -Wl, forwards these through clang++.
    $c = $c.Replace('set(_LITERTLM_LINK_MULTIDEF "/FORCE:MULTIPLE")', 'set(_LITERTLM_LINK_MULTIDEF "-Wl,/FORCE:MULTIPLE")')
    $c.Replace('set(_LITERTLM_LINK_WHOLE_START "/WHOLEARCHIVE")', 'set(_LITERTLM_LINK_WHOLE_START "-Wl,/WHOLEARCHIVE")')
})

Switch-BuildPhase '5e. link spec: clean-link + CRT compat + lib aliasing'
# [LiteRTLM-winfix clean-link] CRT data globals, an uncompiled flatbuffers symbol and __imp_ abseil carriers, fixed for a one-pass link.
$cleanCml = Join-Path $SourceDir 'cmake\packages\litert_lm\CMakeLists.txt'
if ((Test-Path $cleanCml) -and ((Get-Content -Raw $cleanCml) -notmatch 'LiteRTLM-winfix clean-link')) {
    # (a) CRT-compat shim as a real compiled source alongside litert_lm_main.cc
    $crtCc = Join-Path $SourceDir 'runtime\engine\crtcompat.cc'
    Copy-Item (Join-Path $scriptAssetRoot 'shims\crtcompat.cc') $crtCc -Force
    # (b) an empty object used to truncate the protobuf carriers to empty archives
    $emptyCc = Join-Path $SourceDir 'winfix_empty.cc'
    $emptyObj = Join-Path $SourceDir 'winfix_empty.obj'
    Set-Content -Path $emptyCc -Value '// [LiteRTLM-winfix] intentionally empty' -Encoding ASCII
    # Gate the compile: a missing obj only surfaces later as an opaque llvm-ar error.
    $emptyCompileOut = & (Get-Command clang++.exe).Source -c $emptyCc -o $emptyObj 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $emptyObj)) {
        throw "clang++ failed to compile the winfix empty object $emptyObj (exit $LASTEXITCODE): $(@($emptyCompileOut) -join [Environment]::NewLine)"
    }
    $emptyObjFwd = $emptyObj -replace '\\', '/'
    $llvmArFwd = ((Get-Command llvm-ar.exe).Source) -replace '\\', '/'
    # (c) inject sources + CRT alternatenames + PRE_LINK neutralize into the litert_lm_main target
    $winAlts = @('timezone=_timezone', 'daylight=_daylight', 'tzname=_tzname', 'sys_nerr=_sys_nerr', 'sys_errlist=_sys_errlist', 'environ=_environ',
        '__imp_timezone=__imp__timezone', '__imp_daylight=__imp__daylight', '__imp_tzname=__imp__tzname', '__imp_sys_nerr=__imp__sys_nerr', '__imp_sys_errlist=__imp__sys_errlist', '__imp_environ=__imp__environ')
    $altLines = ($winAlts | ForEach-Object { "    `"LINKER:/alternatename:$_`"" }) -join "`n"
    # Single-quoted, no backtick: ${CMAKE_BINARY_DIR} must reach CMake verbatim, and PS will not re-expand it.
    $protoLibDir = '${CMAKE_BINARY_DIR}/external/protobuf/install/lib'
    $fbUtil = '${CMAKE_BINARY_DIR}/external/flatbuffers/src/flatbuffers_external/src/util.cpp'
    $fbInc = '${CMAKE_BINARY_DIR}/external/flatbuffers/install/include'
    $inject = @"

# [LiteRTLM-winfix clean-link] link a CRT-compat shim + flatbuffers util.cpp into litert_lm_main, alias
# the POSIX/__imp_ CRT global variants onto the shim, and empty the protobuf __imp_-abseil carriers
# (protoc.lib/protobuf-lite.lib) right before the link. Makes ninja link the exe in one pass.
# crtcompat.cc AND util.cpp are compiled in ISOLATION (own custom commands, clean flags) rather than as
# target sources: litert_lm_main's flags force -include unistd.h -> UCRT stdlib.h/time.h, which #define
# the deprecated CRT globals (_environ/_sys_nerr/...) as accessor-wrapping MACROS, so the shim's
# definitions would macro-expand into garbage ("illegal initializer"). The clean flags below match the
# standalone recipe that was link-validated to 0 undefined symbols.
if(WIN32)
    add_custom_command(
        OUTPUT "`${CMAKE_BINARY_DIR}/crtcompat_winfix.obj"
        COMMAND "`${CMAKE_CXX_COMPILER}" -c "`${LITERTLM_PROJECT_ROOT}/runtime/engine/crtcompat.cc" -o "`${CMAKE_BINARY_DIR}/crtcompat_winfix.obj" -O2 -DNDEBUG -D_DLL -D_MT -Xclang --dependent-lib=msvcrt
        DEPENDS "`${LITERTLM_PROJECT_ROOT}/runtime/engine/crtcompat.cc"
        COMMENT "[LiteRTLM-winfix] compiling crtcompat shim in isolation (clean CRT flags)"
        VERBATIM
    )
    add_custom_command(
        OUTPUT "`${CMAKE_BINARY_DIR}/fbutil_winfix.obj"
        COMMAND "`${CMAKE_CXX_COMPILER}" -c "$fbUtil" -o "`${CMAKE_BINARY_DIR}/fbutil_winfix.obj" -O2 -DNDEBUG -D_DLL -D_MT -I "$fbInc" -Xclang --dependent-lib=msvcrt
        DEPENDS flatbuffers_external
        COMMENT "[LiteRTLM-winfix] compiling flatbuffers util.cpp in isolation (defines ClassicLocale::instance_)"
        VERBATIM
    )
    set_source_files_properties("`${CMAKE_BINARY_DIR}/crtcompat_winfix.obj" "`${CMAKE_BINARY_DIR}/fbutil_winfix.obj" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
    target_sources(litert_lm_main PRIVATE
        "`${CMAKE_BINARY_DIR}/crtcompat_winfix.obj"
        "`${CMAKE_BINARY_DIR}/fbutil_winfix.obj"
    )
    if(TARGET flatbuffers_external)
        add_dependencies(litert_lm_main flatbuffers_external)
    endif()
    target_link_options(litert_lm_main PRIVATE
$altLines
    )
    # v0.14.0+: Gemma model constraint provider is upstream's prebuilt-only DLL
    # component; the import lib must be on the EXE link (engine-lib PUBLIC linkage
    # does not reach litert_lm_main's assembled link spec -- proven by hand-link
    # 2026-08-03: adding this lib + the injected orphans closed the last 4
    # undefined symbols and produced a RUNNING exe).
    if(EXISTS "`${LITERTLM_PROJECT_ROOT}/prebuilt/windows_x86_64/libGemmaModelConstraintProvider.lib")
        target_link_libraries(litert_lm_main PRIVATE "`${LITERTLM_PROJECT_ROOT}/prebuilt/windows_x86_64/libGemmaModelConstraintProvider.lib")
    endif()
    add_custom_command(TARGET litert_lm_main PRE_LINK
        COMMAND "`${CMAKE_COMMAND}" -E rm -f "$protoLibDir/protoc.lib" "$protoLibDir/protobuf-lite.lib"
        COMMAND "$llvmArFwd" rcs "$protoLibDir/protoc.lib" "$emptyObjFwd"
        COMMAND "$llvmArFwd" rcs "$protoLibDir/protobuf-lite.lib" "$emptyObjFwd"
        COMMENT "[LiteRTLM-winfix] neutralizing protoc.lib/protobuf-lite.lib (abseil __imp_ MixingHashState carriers)"
        VERBATIM
    )
endif()
"@
    $cc = [System.IO.File]::ReadAllText($cleanCml)
    [System.IO.File]::WriteAllText($cleanCml, $cc + $inject)
    Write-Host 'Patched litert_lm/CMakeLists.txt [clean-link]: crtcompat + flatbuffers util sources, CRT alternatenames, PRE_LINK protoc/protobuf-lite neutralize'
}

# The target maps name GNU libabsl_*.a, which the stub sweep fills with empty archives; the real libs are absl_*.lib.
foreach ($abslCmakeRel in @('cmake\packages\absl\absl_import_static_lib.cmake', 'cmake\packages\absl\absl_target_map.cmake')) {
    [void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir $abslCmakeRel) `
            -Pattern 'libabsl_([A-Za-z0-9_]+)\.a' -Replacement 'absl_$1.lib' -Guard 'libabsl_[A-Za-z0-9_]+\.a' `
            -Description "$abslCmakeRel : libabsl_*.a -> absl_*.lib (point at the real MSVC abseil libs)")
}

# The same naming mismatch for protobuf, whose symbols would otherwise vanish at link.
[void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir 'cmake\packages\protobuf\protobuf_target_map.cmake') `
        -Pattern '/lib([a-z0-9_-]+)\.a' -Replacement '/$1.lib' -Guard '/lib[a-z0-9_-]+\.a' `
        -Description 'protobuf_target_map.cmake : /lib*.a -> /*.lib (point at the real MSVC protobuf libs)')

# The rust cxx-bridge libs come out as *.lib where lib*.a is expected; copies under the GNU names suffice for lld-link.
$findCopy = Get-ChildItem $SourceDir -Recurse -Filter 'find_and_copy_cxxbridge.cmake' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $findCopy) {
    Write-Warning 'find_and_copy_cxxbridge.cmake not found under the source tree -- rust cxx-bridge libs will NOT be staged as lib*.a (expect undefined rust::cxxbridge1 symbols at the litert_lm_main link)'
} elseif ((Get-Content -Raw $findCopy.FullName) -notmatch 'LiteRTLM-winfix rust-lib-stage') {
    Add-Content -LiteralPath $findCopy.FullName -Value (Get-Content -Raw (Join-Path $scriptAssetRoot 'patches\litert-lm\rust-lib-stage.cmake'))
    Write-Host 'Patched find_and_copy_cxxbridge.cmake: stage rust litert_lm_deps.lib + litertlm_cxx_bridge.lib as lib*.a'
}

# protobuf's EP defaults to the static CRT, which /failifmismatch rejects once those libs really link.
$protoCmake = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf.cmake'
[void](Edit-SourceFile -Path $protoCmake -Marker 'protobuf_MSVC_STATIC_RUNTIME' -Description 'protobuf.cmake: force protobuf dynamic CRT (protobuf_MSVC_STATIC_RUNTIME=OFF)' -Transform {
    param($pc)
    $pc.Replace(
        '-Dprotobuf_BUILD_TESTS=OFF',
        "-Dprotobuf_BUILD_TESTS=OFF`n        -Dprotobuf_MSVC_STATIC_RUNTIME=OFF`n        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL  # [LiteRTLM-winfix] dynamic CRT to match the rest (lld-link /failifmismatch)")
})

# An INTERFACE runtime_util_logging never compiles logging.cc's SetMinLogSeverity; STATIC with PUBLIC requirements does.
$utilCmake = Join-Path $SourceDir 'runtime\util\CMakeLists.txt'
if ((Test-Path $utilCmake) -and ((Get-Content -Raw $utilCmake) -match 'add_litertlm_library\(runtime_util_logging INTERFACE\)')) {
    $uc = [System.IO.File]::ReadAllText($utilCmake)
    $uc = [regex]::Replace($uc, 'add_litertlm_library\(runtime_util_logging INTERFACE\)', "add_litertlm_library(runtime_util_logging STATIC`n  logging.cc`n)")
    $uc = [regex]::Replace($uc, '(target_include_directories\(runtime_util_logging\s+)INTERFACE', '${1}PUBLIC')
    $uc = [regex]::Replace($uc, '(target_link_libraries\(runtime_util_logging\s+)INTERFACE', '${1}PUBLIC')
    [System.IO.File]::WriteAllText($utilCmake, $uc)
    Write-Host 'Patched runtime/util/CMakeLists.txt: runtime_util_logging INTERFACE -> STATIC (compile logging.cc for SetMinLogSeverity)'
}

# Bazel groups llg_fc_tool_calls.cc + llg_python_tool_calls.cc into this target; CMake does not.
$cdCmake = Join-Path $SourceDir 'runtime\components\constrained_decoding\CMakeLists.txt'
[void](Edit-SourceFile -Path $cdCmake -Marker 'llg_fc_tool_calls\.cc' -Description 'constrained_decoding/CMakeLists.txt: add llg_fc_tool_calls.cc + llg_python_tool_calls.cc to llguidance_schema_utils' -Transform {
    param($cd)
    [regex]::Replace($cd,
        '(add_litertlm_library\(runtime_components_constrained_decoding_llguidance_schema_utils STATIC\s+llguidance_schema_utils\.cc)',
        "`$1`n  llg_fc_tool_calls.cc`n  llg_python_tool_calls.cc")
})

# The same lib-name mismatch across the remaining target maps.
foreach ($rel in @(
        'cmake\packages\litert\litert_target_map.cmake',
        'cmake\packages\sentencepiece\sentencepiece_target_map.cmake',
        'cmake\packages\sentencepiece\sentencepiece.cmake',
        'cmake\packages\tflite\tflite_target_map.cmake',
        'cmake\packages\tflite\tflite.cmake',
        'cmake\packages\re2\re2_target_map.cmake',
        'cmake\packages\re2\re2.cmake',
        'cmake\packages\tokenizers\tokenizers.cmake',
        'cmake\packages\tokenizers\tokenizers_target_map.cmake',
        'cmake\packages\flatbuffers\flatbuffers_target_map.cmake')) {
    [void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir $rel) `
            -Pattern 'lib([a-zA-Z0-9_-]+)\.a' -Replacement '$1.lib' -Guard 'lib[a-zA-Z0-9_-]+\.a' `
            -Description "$rel : lib*.a -> *.lib (real MSVC litert/sentencepiece/tflite libs)")
}

#endregion

#region Phase 6 | CMake configure + proto codegen
Switch-BuildPhase '6. CMake configure + proto codegen'
$buildDir = Join-Path $SourceDir 'build_ninja'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'
$litertCmakeDir = Join-Path $litertInstallDir 'cmake'
if (-not (Test-Path $litertCmakeDir)) {
    $litertCmakeDir = Join-Path $litertInstallDir 'lib\cmake\LiteRT'
}
$gpuEnv = Get-GpuEnvironment

$cmakeExtra = @(
    "-DCMAKE_PREFIX_PATH=$litertInstallDir;$litertCmakeDir"
)
if ($gpuEnv.HasCuda) { $cmakeExtra += '-DUSE_CUDA=ON' }
if (Test-Path $litertCmakeDir) { $cmakeExtra += "-DLiteRT_DIR=$litertCmakeDir" }

Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra | Out-Null

# $hostProtoc below is the version-matched protoc 31.1 (== protobuf_external 6.31.1); NOT vcpkg's libprotoc 33.4
$protoDir = Join-Path $SourceDir 'runtime\proto'
foreach ($outSubDir in @('proto', 'protobuf')) {
    $protoOutDir = Join-Path $SourceDir "build_ninja\litert_lm\build\runtime\$outSubDir"
    New-Item -Path $protoOutDir -ItemType Directory -Force | Out-Null
    if ((Test-Path $hostProtoc) -and (Test-Path $protoDir)) {
        Get-ChildItem -Path $protoDir -Filter '*.proto' | ForEach-Object {
            $protocOut = & $hostProtoc --proto_path="$SourceDir" --cpp_out="$protoOutDir" $_.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "protoc codegen failed for $($_.Name) (exit $LASTEXITCODE): $(@($protocOut) -join [Environment]::NewLine)"
            }
        }
        Write-Host "Generated proto files to $protoOutDir"
    }
}
$protoInstallBin = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\bin'
New-Item -Path $protoInstallBin -ItemType Directory -Force | Out-Null
Copy-Item $hostProtoc (Join-Path $protoInstallBin 'protoc.exe') -Force
Copy-Item $hostProtoc (Join-Path $protoInstallBin 'protoc') -Force

#endregion

#region Phase 7 | Ninja build + ExternalProject lib stubs
Switch-BuildPhase '7. Ninja build + ExternalProject lib stubs'
$litertBuildDir = Join-Path $buildDir 'litert_lm\build'
$llvmAr = (Get-Command llvm-ar.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source

Write-Host 'Running ExternalProject steps 1-4 (mkdir/download/update/patch)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-mkdir litert_lm/stamps/litert_lm-download litert_lm/stamps/litert_lm-update litert_lm/stamps/litert_lm-patch 2>&1
# Only a warning: ninja re-drives a failed stamp, and the configure gate below throws.
if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: mkdir/download/update/patch step exited $LASTEXITCODE (the configure gate below will fail if this was real)" }

Write-Host 'Running ExternalProject step 5 (configure)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-configure 2>&1
if ($LASTEXITCODE -ne 0) {
    # Hard gate: a failed inner configure means nothing below can build.
    throw "inner litert_lm configure failed (exit $LASTEXITCODE)"
}

$buildNinjaFile = Join-Path $litertBuildDir 'build.ninja'
$stubCount = 0
$stubFailCount = 0
# Paths, not a tally, so they match lld-link's later "could not open <path>".
$stubFailedPaths = [System.Collections.Generic.List[string]]::new()
if (Test-Path $buildNinjaFile) {
    Get-Content $buildNinjaFile | ForEach-Object {
        [regex]::Matches($_, "[\x27""]?([^\x27""\s]+\.(?:a|lib))[\x27""]?") | ForEach-Object {
            $aRel = $_.Groups[1].Value
            # A bare name is a system lib found via LIB, bar the known cases; stubbing our own libs is harmless.
            $hasDir = $aRel -match '[\\/]'
            $isAllowedBare = ($aRel -match '\.a$') -or ($aRel -match '(?:tokenizers_c|absl_[A-Za-z0-9_]+|protobuf(?:-lite)?|protoc|upb|utf8_validity|litert_[A-Za-z0-9_]+|sentencepiece(?:_train)?|tensorflow-lite|tflite_profiling)\.lib$')
            if (-not $hasDir -and -not $isAllowedBare) { return }
            $aPath = if ($aRel -match '^[a-zA-Z]:') { $aRel -replace '/', '\' } else { Join-Path $litertBuildDir $aRel }
            if (-not (Test-Path $aPath)) {
                $parent = Split-Path $aPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
                    try { $null = New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "stub parent dir best-effort skip: $_" }
                }
                # A native non-zero exit raises no PS exception -- gate on $LASTEXITCODE + the file.
                $null = & $llvmAr rcs $aPath -- 2>&1
                if ($LASTEXITCODE -eq 0 -and (Test-Path $aPath)) {
                    $stubCount++
                } else {
                    $stubFailCount++
                    $stubFailedPaths.Add($aPath)
                    Write-Verbose "stub archive creation failed (exit $LASTEXITCODE): $aPath"
                }
            }
        }
    }
    Write-Host "Created $stubCount ExternalProject lib stubs (.a/.lib referenced by the aggregate but not yet built); $stubFailCount failed"
    if ($stubFailCount -gt 0) {
        # Capped, and the cap is stated so the list is not mistaken for the whole story.
        $shown = @($stubFailedPaths | Select-Object -First 10)
        $suffix = if ($stubFailCount -gt $shown.Count) { " (+$($stubFailCount - $shown.Count) more)" } else { '' }
        Write-Warning ("$stubFailCount lib stub(s) could not be created -- lld-link may fail with 'could not open' on " +
            "these paths${suffix}:`n  " + ($shown -join "`n  "))
    }
}

Write-Host 'Running ExternalProject step 6 (build)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-build 2>&1
# Parallel clangs on one header can storm into ACCESS_DENIED; a -j8 retry heals that, a real error fails all passes.
$ninjaRetries = 0
while ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 101 -and $ninjaRetries -lt 2) {
    $ninjaRetries++
    Write-Host "ninja build step exited with code $LASTEXITCODE -- incremental retry $ninjaRetries/2 at -j8 (transient file-lock storms)"
    & $ninja -C $buildDir -j8 litert_lm/stamps/litert_lm-build 2>&1
}
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 101) { Write-Host "WARNING: ninja build step exited with code $LASTEXITCODE after $ninjaRetries retries" }
Write-Host "Build step completed with exit code: $LASTEXITCODE"

#endregion

#region Phase 8 | Stage litert_lm_main.exe + smoke test + restore vcpkg headers
Switch-BuildPhase '8. Stage litert_lm_main.exe + smoke test + restore vcpkg headers'
# Stage the exe and its runtime DLLs to run standalone: the tree is wiped below unless LITERTLM_KEEP_BUILD_TREE.
$mainExe = Join-Path $litertBuildDir 'litert_lm_main.exe'
if (Test-Path $mainExe) {
    # clang/lld warnings on stderr must not trip EAP=Stop; success is decided by Test-Path.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Write-Host "litert_lm_main.exe linked by ninja ($([math]::Round((Get-Item $mainExe).Length / 1MB, 1)) MB)"
    $binOut = Join-Path $litertLmInstallDir 'bin'
    New-Item -ItemType Directory -Force -Path $binOut | Out-Null
    Copy-Item $mainExe $binOut -Force
    Copy-Item (Join-Path $litertBuildDir 'litert_lm_main.pdb') $binOut -Force -ErrorAction SilentlyContinue
    # The Gemma model constraint provider is prebuilt-only upstream; the exe imports its DLL.
    $prebuiltWin = Join-Path $SourceDir 'prebuilt\windows_x86_64'
    if (Test-Path $prebuiltWin) {
        foreach ($dll in @(Get-ChildItem $prebuiltWin -Filter '*.dll' -ErrorAction SilentlyContinue)) {
            Copy-Item $dll.FullName $binOut -Force
            Write-Host "staged prebuilt runtime DLL: $($dll.Name)"
        }
    }
    # vcpkg's zlib and upstream's kissfft are DLLs, or the exe dies 0xC0000135; copy before the tree is removed.
    foreach ($rt in @(
            (Join-Path $vcpkgInstalledX64 'bin\z.dll'),
            (Join-Path $buildDir 'litert_lm\build\_deps\kissfft_lib-build\kissfft-float.dll'))) {
        if (Test-Path $rt) {
            Copy-Item $rt $binOut -Force
            Write-Host "staged runtime DLL: $(Split-Path $rt -Leaf)"
        } else {
            Write-Warning "expected runtime DLL not found (exe may not launch): $rt"
        }
    }
    # dynamic-CRT redist DLLs (targeted glob into the VS redist tree)
    $redist = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\$(Get-MsvcTargetLibDir)\Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($redist) { Copy-Item (Join-Path $redist.FullName '*.dll') $binOut -Force -ErrorAction SilentlyContinue }
    # Not in a bare Server Core System32: search the resolved MSVC toolset, not all of Program Files.
    $msvcRoot = try { Get-MsvcToolsRoot } catch { $null }
    foreach ($d in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'concrt140.dll', 'ucrtbase.dll')) {
        if (-not (Test-Path (Join-Path $binOut $d))) {
            $sys = Join-Path $env:SystemRoot "System32\$d"
            if (Test-Path $sys) { Copy-Item $sys $binOut -Force -ErrorAction SilentlyContinue }
            elseif ($msvcRoot) { $found = Get-ChildItem $msvcRoot -Recurse -Filter $d -File -ErrorAction SilentlyContinue | Select-Object -First 1; if ($found) { Copy-Item $found.FullName $binOut -Force -ErrorAction SilentlyContinue } }
        }
    }
    $vcpkgBin = Join-Path $vcpkgInstalledX64 'bin'
    if (Test-Path $vcpkgBin) { Copy-Item (Join-Path $vcpkgBin '*.dll') $binOut -Force -ErrorAction SilentlyContinue }
    # Co-locate every real imported DLL built in the tree; api-ms-win-* are virtual API-set forwarders.
    $readobj = (Get-Command llvm-readobj.exe -ErrorAction SilentlyContinue).Source
    if ($readobj) {
        $imps = & $readobj --coff-imports $mainExe 2>$null | Select-String 'Name:' | ForEach-Object { ($_ -replace '.*Name:\s*', '').Trim() } | Where-Object { $_ -match '\.dll$' } | Sort-Object -Unique
        Write-Host ("litert_lm_main.exe imports: " + ($imps -join ', '))
        $treeDlls = @{}
        Get-ChildItem $buildDir -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { if (-not $treeDlls.ContainsKey($_.Name)) { $treeDlls[$_.Name] = $_.FullName } }
        foreach ($imp in $imps) {
            if ($imp -match '^api-ms-win-') { continue }
            if ((Test-Path (Join-Path $binOut $imp)) -or (Test-Path (Join-Path $env:SystemRoot "System32\$imp"))) { continue }
            if ($treeDlls.ContainsKey($imp)) { Copy-Item $treeDlls[$imp] $binOut -Force -ErrorAction SilentlyContinue }
        }
        $missing = $imps | Where-Object { $_ -notmatch '^api-ms-win-' -and -not (Test-Path (Join-Path $binOut $_)) -and -not (Test-Path (Join-Path $env:SystemRoot "System32\$_")) }
        if ($missing) { Write-Host ("  STILL-MISSING DLLs (not found anywhere): " + ($missing -join ', ')) }
    }
    $env:PATH = "$binOut;$env:PATH"
    # Run it: a missing DLL or abseil's flag ODR abort shows only at start; the flag is set first for StrictMode.
    $script:litertLmRuntimeBroken = $false
    $smokeExe  = Join-Path $binOut 'litert_lm_main.exe'
    $smokeOut  = & cmd /c "`"$smokeExe`" --help 2>&1"
    $smokeExit = $LASTEXITCODE
    $smokeText = ($smokeOut | Out-String)
    if ($smokeText -match 'Inconsistency between flag|ODR violation|duplicate flags') {
        Write-Host "*** litert_lm_main.exe BROKEN at runtime: abseil flag ODR violation (duplicate abseil linked). exit=$smokeExit ***"
        ($smokeOut | Select-Object -First 3) | ForEach-Object { Write-Host "    $_" }
        $script:litertLmRuntimeBroken = $true
    } elseif ($smokeExit -eq -1073741515 -or $smokeExit -eq 3221225781) {
        Write-Host "*** litert_lm_main.exe BROKEN at runtime: missing DLL (0xC0000135). exit=$smokeExit ***"
        $script:litertLmRuntimeBroken = $true
    } else {
        Write-Host "litert_lm_main.exe smoke-run OK (exit $smokeExit = launches + runs)."
    }
    Write-Host "litert_lm_main.exe staged to $binOut"
    $ErrorActionPreference = $prevEAP
    # Hard gate; skipped only under LITERTLM_KEEP_BUILD_TREE so the link diagnostics still run.
    if ($script:litertLmRuntimeBroken -and -not $env:LITERTLM_KEEP_BUILD_TREE) {
        throw "litert_lm_main.exe is non-functional at runtime (smoke-run flagged it BROKEN above). Set LITERTLM_KEEP_BUILD_TREE=1 to keep the build tree + dump link diagnostics."
    }
}
elseif ($env:LITERTLM_KEEP_BUILD_TREE) {
    # Debug escape hatch only: keep going so the link-diagnostics dump below can run.
    Write-Host "WARNING: ninja did not produce litert_lm_main.exe -- continuing under LITERTLM_KEEP_BUILD_TREE for diagnostics"
}
else {
    # Without the exe the image is silently degraded, and the merge would ship it.
    throw "ninja did not produce litert_lm_main.exe (configure or link failed above). Set LITERTLM_KEEP_BUILD_TREE=1 to keep the tree + dump link diagnostics."
}

Write-Host 'Installing...'
& cmake --install $buildDir --config Release 2>&1
# The exit code proves nothing, as this install has exited 0 writing no file; Build-LitertLmBazel.ps1 holds the live guard.
$installedNow = @(Get-ChildItem -LiteralPath $litertLmInstallDir -Recurse -File -ErrorAction SilentlyContinue)
Write-Host ("cmake --install left {0} file(s) in {1}: {2}" -f $installedNow.Count, $litertLmInstallDir,
    (@($installedNow | ForEach-Object { $_.Directory.Name } | Sort-Object -Unique) -join ', '))
if ($LASTEXITCODE -ne 0) {
    # Hard gate; warn instead under the KEEP_BUILD_TREE escape hatch so diagnostics still run.
    if ($env:LITERTLM_KEEP_BUILD_TREE) {
        Write-Warning "cmake --install failed (exit $LASTEXITCODE) -- continuing under LITERTLM_KEEP_BUILD_TREE for diagnostics"
    } else {
        throw "cmake --install failed (exit $LASTEXITCODE) -- headers/libs missing from $litertLmInstallDir"
    }
}

if ($env:LITERTLM_KEEP_BUILD_TREE) {
    Write-Host 'LITERTLM_KEEP_BUILD_TREE set: dumping litert_lm_main link diagnostics (and KEEPING the tree)'
    & (Join-Path $PSScriptRoot 'Debug-LitertlmLink.ps1') -SourceDir $SourceDir
}
else { Remove-SourceBuildTree -Path $SourceDir }

#endregion

} catch {
    # Name the failing phase before the throw reaches the chain wrapper.
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'litert-lm'
    throw
} finally {
    # $null removes the variable: SetEnvironmentVariable($null) leaves it defined-empty for children.
    foreach ($envName in @($litertLmEnvSnapshot.Keys)) {
        if ($null -eq $litertLmEnvSnapshot[$envName]) { Remove-Item -Path "Env:$envName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($envName, $litertLmEnvSnapshot[$envName]) }
    }
}

Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'litert-lm'
Write-Host '=== LiteRT-LM source build completed ==='
# pwsh -File would otherwise return the last native exit code, and every real failure above throws.
exit 0

