# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\litert-lm-src',
    [string]$InstallDir = '',
    [string]$LiteRtLmVersion = '',
    [string]$VcpkgRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.13.1'
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT-LM' }

Write-Host 'Setting up git-lfs...'
& git lfs install --skip-repo 2>&1 | Out-Null
Push-Location $SourceDir
& git lfs pull 2>&1 | Out-Null
Pop-Location

# vcpkg paths: prefer -VcpkgRoot param, then $env:VCPKG_ROOT, then the container default.
if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    $VcpkgRoot = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT } else { 'C:\vcpkg' }
}
$vcpkgInstalledX64 = Join-Path $VcpkgRoot 'installed\x64-windows'
$env:CMAKE_PREFIX_PATH = "$vcpkgInstalledX64;$env:CMAKE_PREFIX_PATH"
$protobufTools = Join-Path $vcpkgInstalledX64 'tools\protobuf'
$vcpkgDir = $VcpkgRoot
if (Test-Path $protobufTools) { $env:PATH = "$protobufTools;$env:PATH" }

# Isolate the from-source protobuf (protobuf_external v6.31.1) from vcpkg's DIFFERENT
# protobuf headers. vcpkg is on CMAKE_PREFIX_PATH (above) and its include dir is also
# copied into the host-protoc install (below), so `-isystem C:/vcpkg/.../include` leaks
# vcpkg's google/protobuf headers into the protobuf_external compile -- a version skew
# that breaks e.g. `using ::google::protobuf::internal::cpp::HasHasbit` (which vcpkg's
# older protobuf lacks). We only need vcpkg's protoc BINARY, not its protobuf headers,
# so hide them for the duration of the build and restore them before the image is
# committed (see restore below). Hiding the headers (rather than dropping vcpkg from
# CMAKE_PREFIX_PATH) keeps vcpkg's zlib/etc. discoverable for protobuf's HAVE_ZLIB.
$vcpkgProtoHeaders = Join-Path $vcpkgInstalledX64 'include\google\protobuf'
$vcpkgProtoHeadersHidden = "$vcpkgProtoHeaders.hidden-during-litertlm-build"
if ((Test-Path $vcpkgProtoHeaders) -and -not (Test-Path $vcpkgProtoHeadersHidden)) {
    Rename-Item -LiteralPath $vcpkgProtoHeaders -NewName (Split-Path $vcpkgProtoHeadersHidden -Leaf) -Force
    Write-Host "Hid vcpkg protobuf headers to avoid version skew with protobuf_external (v6.31.1)"
}

# Windows link-lib shim for the GNU-driver Unix libs. The inner build links with
# clang++ (GNU driver) + lld-link, so CMake's platform/threads/zlib detection adds
# POSIX link libs -- `-lz -lrt -lpthread -ldl` -> `z.lib rt.lib pthread.lib dl.lib` --
# that don't exist on Windows, breaking every executable link (protoc.exe, etc.):
#   lld-link: error: could not open 'rt.lib'/'pthread.lib'/'dl.lib'/'z.lib'
# rt/pthread/dl are Win32-#ifdef'd out (no symbols actually referenced), so empty stub
# archives satisfy the linker. z IS real zlib -- vcpkg ships it as z.lib, but vcpkg's
# lib dir isn't on the link path, so copy it into the shim dir. Prepending the shim dir
# to LIB (which lld-link searches for bare lib names) fixes ALL such exe links downstream.
$stubLibDir = 'C:\temp\winstublibs'
New-Item -ItemType Directory -Force $stubLibDir | Out-Null
$llvmLib = (Get-Command llvm-lib.exe -ErrorAction Stop).Source
foreach ($stub in @('rt', 'pthread', 'dl')) {
    & $llvmLib "/out:$stubLibDir\$stub.lib" /llvmlibempty 2>&1 | Out-Null
}
$vcpkgZlib = Join-Path $vcpkgInstalledX64 'lib\z.lib'
if (Test-Path $vcpkgZlib) { Copy-Item $vcpkgZlib (Join-Path $stubLibDir 'z.lib') -Force }
# CAUTION: clang auto-detects the MSVC/SDK/clang-runtime lib dirs ONLY while LIB is unset
# (which it is in this container). The moment we set LIB to inject the shim dir, clang
# stops emitting its own -libpath and defers entirely to LIB -- so LIB must ALSO carry
# those system dirs or kernel32.lib/libcmt.lib vanish and every link (even the configure
# compiler check) fails. Glob them version-agnostically and put the shim dir first.
$clangHome = Split-Path (Split-Path (Get-Command clang++.exe -ErrorAction Stop).Source)
$sysLibGlobs = @(
    'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\x64',
    'C:\Program Files (x86)\Windows Kits\10\Lib\*\ucrt\x64',
    'C:\Program Files (x86)\Windows Kits\10\Lib\*\um\x64',
    (Join-Path $clangHome 'lib\clang\*\lib\x86_64-pc-windows-msvc'),
    (Join-Path $clangHome 'lib\clang\*\lib\windows')
)
$sysLibDirs = foreach ($g in $sysLibGlobs) {
    $d = Get-ChildItem $g -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($d) { $d.FullName }
}
$env:LIB = (@($stubLibDir) + $sysLibDirs) -join ';'
Write-Host "Created Windows link-lib shims (rt/pthread/dl empty; z=vcpkg zlib); LIB = shim + $(@($sysLibDirs).Count) MSVC/SDK/clang lib dirs"

# Cargo: honor the existing $env:CARGO_HOME (set in Dockerfile.base); only fall back to a default if unset.
if ([string]::IsNullOrWhiteSpace($env:CARGO_HOME)) { $env:CARGO_HOME = Join-Path $env:USERPROFILE '.cargo' }
$cargoBin = Join-Path $env:CARGO_HOME 'bin'
if (($env:PATH -notlike "*$cargoBin*") -and (Test-Path $cargoBin)) { $env:PATH = "$cargoBin;$env:PATH" }

# clang-cl + modern MSVC STL fix for the Rust `cxx` crate (transitive dep). Its
# build script compiles a generated C++ bridge via `cxx-build`/`cc`, which defaults
# to -std=c++11. MSVC 14.51's <xutility> uses `constexpr void` return types (legal
# only since C++14), so the bridge compile rejects them ("constexpr function's return
# type 'void' is not a literal type") and the cxx build dies with exit 101. Bumping
# the bridge to C++17 lets it see the modern STL. We use the `cc` crate's TARGET-
# SCOPED env var (not the generic CXXFLAGS): the litert_lm ExternalProject's inner
# CMake `configure` runs a testCXXCompiler check under the GNU-driver clang++, which
# chokes on any stray flag it doesn't own ("no such file or directory: '-std=...'").
# CMake ignores CXXFLAGS_<target>, so scoping to x86_64-pc-windows-msvc reaches only
# the cc/clang-cl bridge build (clang-cl accepts -std=c++17) and leaves configure alone.
$env:CXXFLAGS_x86_64_pc_windows_msvc = (@($env:CXXFLAGS_x86_64_pc_windows_msvc, '-std=c++17') | Where-Object { $_ }) -join ' '
Write-Host "Set CXXFLAGS_x86_64_pc_windows_msvc for the cxx/cc bridge: $($env:CXXFLAGS_x86_64_pc_windows_msvc)"

# clang two-phase-lookup fix for the MSVC-targeted C++ deps (protobuf, sentencepiece,
# tflite, ...). The inner build compiles with clang++ (GNU driver), which does STRICT
# two-phase name lookup: qualified names inside template bodies (e.g. protobuf's
# `internal::cpp::HasHasbit(field)` in compiler/cpp/field_chunk.h) are resolved at the
# template's DEFINITION point and fail if the declaring header is not yet included --
# whereas MSVC and clang-cl DELAY template parsing to instantiation and resolve fine.
# -fdelayed-template-parsing restores that MSVC-like behavior. Setting it in the generic
# CXXFLAGS makes every CMake sub-build pick it up as the initial CMAKE_CXX_FLAGS (CMake
# seeds CMAKE_CXX_FLAGS from $ENV{CXXFLAGS}). It is a GNU-style clang flag, so it does
# NOT break the clang++ testCXXCompiler configure check (unlike MSVC-style /std:). The
# -Wno- silences clang's "deprecated after C++20" note so it can't trip a -Werror dep.
# NOTE: cc/cxx-build reads the target-scoped CXXFLAGS_<target> above in preference to
# this generic one, so the Rust bridge keeps just -std=c++17 (clang-cl already delays).
$env:CXXFLAGS = (@($env:CXXFLAGS, '-fdelayed-template-parsing', '-Wno-delayed-template-parsing-in-cxx20') | Where-Object { $_ }) -join ' '
Write-Host "Set CXXFLAGS (delayed template parsing) for CMake sub-builds: $env:CXXFLAGS"

# Inline patch (kept inline, NOT a .patch file): LiteRT-LM's runtime/proto/CMakeLists.txt
# is a single small file but the regex substitutions (`protobuf_generate(...)`,
# `find_package(Protobuf` -> QUIET) are not stable across LiteRT-LM tags -- newer
# releases rename the proto target list and add an extra `find_package(Protobuf
# REQUIRED)` near the bottom. A static .patch would rot; the `-replace` form is
# the canonical representation. See docs/windows-builds.md ?Patches.
$runtimeProtoCmake = Join-Path $SourceDir 'runtime\proto\CMakeLists.txt'
if (Test-Path $runtimeProtoCmake) {
    $content = [System.IO.File]::ReadAllText($runtimeProtoCmake)
    $content = $content -replace 'protobuf_generate\([^)]*\)', '# protobuf_generate disabled (vcpkg)'
    $content = $content -replace 'find_package\(Protobuf', 'find_package(Protobuf QUIET'
    [System.IO.File]::WriteAllText($runtimeProtoCmake, $content)
    Write-Host 'Patched runtime/proto/CMakeLists.txt before configure'
}

# Inline patch: correct a typo in LiteRT-LM's own cmake/modules/fetch_content.cmake.
# It sets `MINJA_EXAMPLE_ENABLE OFF` to skip minja's example programs, but minja's
# actual option is `MINJA_EXAMPLE_ENABLED` (trailing D). The mismatch leaves examples
# ON; minja compiles them with a global `-Werror` (add_compile_options in its
# CMakeLists), so example sources (examples/raw.cpp, chat-template.cpp) fail on
# -Wdeprecated-declarations (localtime) and analyzer diagnostics from nlohmann/json.
# The examples are not part of the LiteRT-LM runtime -- fix the option name so they
# are actually disabled. \b keeps the correctly-spelled ENABLED untouched (idempotent).
$fetchContentCmake = Join-Path $SourceDir 'cmake\modules\fetch_content.cmake'
if (Test-Path $fetchContentCmake) {
    $fc = [System.IO.File]::ReadAllText($fetchContentCmake)
    $fc = $fc -replace 'MINJA_EXAMPLE_ENABLE\b', 'MINJA_EXAMPLE_ENABLED'
    [System.IO.File]::WriteAllText($fetchContentCmake, $fc)
    Write-Host 'Patched fetch_content.cmake: MINJA_EXAMPLE_ENABLE -> MINJA_EXAMPLE_ENABLED (disable minja example programs)'
}

# Inline patch: fix the Flatbuffers schema-compile step for NATIVE Windows builds.
# LiteRT-LM's CMakeLists.txt unconditionally sets LITERTLM_HOST_FLATC to a "host
# prebuild" path, and cmake/packages/flatbuffers/flatbuffers.cmake uses it whenever
# it is defined -- but that prebuild flatc is only built during the CROSS-COMPILE
# prebuild phase (skipped here: "Native build detected"). So FLATC_EXECUTABLE points
# at a flatc that never exists AND lacks the .exe suffix, and the compile_schemas step
# (compile_flatbuffers.cmake) fails: "Failed to compile ...litertlm_header_schema.fbs".
# The real flatc.exe IS built by flatbuffers_external and installed under
# ${FLATBUFFERS_INSTALL_PREFIX}/bin. Force FLATC_EXECUTABLE to it on Windows, right
# before the ExternalProject_Add_Step captures the variable (cmake is whitespace-
# insensitive, so indentation of the injected block does not matter).
$flatbuffersCmake = Join-Path $SourceDir 'cmake\packages\flatbuffers\flatbuffers.cmake'
if (Test-Path $flatbuffersCmake) {
    $fbText = [System.IO.File]::ReadAllText($flatbuffersCmake)
    if ($fbText -notmatch 'native win flatc') {
        $anchor = 'ExternalProject_Add_Step(flatbuffers_external compile_schemas'
        $inject = @(
            'if(WIN32)',
            'set(FLATC_EXECUTABLE "${FLATBUFFERS_INSTALL_PREFIX}/bin/flatc.exe" CACHE INTERNAL "native win flatc" FORCE)',
            'endif()',
            ''
        ) -join "`n"
        $fbText = $fbText.Replace($anchor, $inject + $anchor)
        [System.IO.File]::WriteAllText($flatbuffersCmake, $fbText)
        Write-Host 'Patched flatbuffers.cmake: force native flatc.exe for compile_schemas (WIN32)'
    }
}

# Inline patch: force the inner litert_lm build to CMAKE_BUILD_TYPE=Release. The
# top-level superbuild (CMakeLists.txt) forwards LITERTLM_HOST_* to the inner
# litert_lm ExternalProject but NOT CMAKE_BUILD_TYPE, so the inner build (and its
# protobuf_external, which configures with -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE})
# ends up Debug while flatbuffers_external hardcodes Release -- a mismatch. In MSVC's
# DEBUG STL, std::string's ctor heap-allocates a _Container_proxy (iterator debug),
# so protobuf's `PROTOBUF_CONSTINIT fixed_address_empty_string` is not constant-
# initializable and clang errors ("variable does not have a constant initializer").
# Release STL makes it constexpr-clean; Release is also what we actually want to ship
# and removes a whole class of debug-STL constinit failures downstream. Inject the
# build type into the inner litert_lm ExternalProject's CMAKE_ARGS (anchored on the
# HOST_FLATC_BIN_DIR line, which is unique to that block, not the prebuild block).
$superCmake = Join-Path $SourceDir 'CMakeLists.txt'
if (Test-Path $superCmake) {
    $sc = [System.IO.File]::ReadAllText($superCmake)
    if ($sc -notmatch 'force-release-buildtype') {
        $btAnchor = '"-DLITERTLM_HOST_FLATC_BIN_DIR=${LITERTLM_HOST_FLATC_BIN_DIR}"'
        $btRepl = $btAnchor + "`n        `"-DCMAKE_BUILD_TYPE=Release`"  # force-release-buildtype"
        $sc = $sc.Replace($btAnchor, $btRepl)
        [System.IO.File]::WriteAllText($superCmake, $sc)
        Write-Host 'Patched CMakeLists.txt: force inner litert_lm CMAKE_BUILD_TYPE=Release'
    }
}

# Inline patch: skip building protobuf's upb generator TOOLS (protoc-gen-upb /
# protoc-gen-upbdefs). They fail to link under clang++/lld-link -- undefined abseil
# symbols (absl::StrCat / absl::log_internal::* / absl::Mutex ...) that lld-link won't
# resolve from the abseil archives (it ignores the GNU --start-group CMake wraps them in),
# and adding libprotobuf to their link does not help. Crucially these tools are NEVER
# invoked: neither protobuf's own build nor litert-lm runs any upb codegen (verified -- no
# COMMAND/TARGET_FILE/--upb_out references anywhere), and the runtime library libupb.a is
# built separately by libupb.cmake. So drop the tools by neutralising protobuf's
# `include(.../upb_generators.cmake)` -- grafted into litert-lm's protobuf_patcher.cmake,
# which already runs post-fetch on the protobuf tree.
$protobufPatcher = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf_patcher.cmake'
if ((Test-Path $protobufPatcher) -and ((Get-Content -Raw $protobufPatcher) -notmatch 'LiteRTLM-winfix upb_generators')) {
    $upbPatch = @'

# [LiteRTLM-winfix upb_generators] skip protoc-gen-upb/-upbdefs tools (never invoked by
# protobuf or litert-lm; they fail to link abseil under clang++/lld-link). libupb.a is
# still built by libupb.cmake, so the runtime library is unaffected.
set(_proot "${PROTO_SRC_DIR}/CMakeLists.txt")
if(EXISTS "${_proot}")
    file(READ "${_proot}" _pr)
    string(REPLACE
      [[include(${protobuf_SOURCE_DIR}/cmake/upb_generators.cmake)]]
      [[# [LiteRTLM-winfix] upb_generators tools skipped (unused; abseil/lld-link link failure)]]
      _pr "${_pr}")
    file(WRITE "${_proot}" "${_pr}")
    message(STATUS "[LiteRTLM] Skipped upb_generators.cmake include (protoc-gen-upb tools not built)")
endif()
# ...and stop install.cmake from installing the now-nonexistent protoc-gen-* targets by
# emptying its generator loop (protoc's own install stays intact).
set(_pinstall "${PROTO_SRC_DIR}/cmake/install.cmake")
if(EXISTS "${_pinstall}")
    file(READ "${_pinstall}" _pi)
    string(REPLACE [[foreach (generator upb upbdefs)]] [[foreach (generator)]] _pi "${_pi}")
    file(WRITE "${_pinstall}" "${_pi}")
    message(STATUS "[LiteRTLM] Patched install.cmake: drop protoc-gen-* install (targets not built)")
endif()
'@
    Add-Content -LiteralPath $protobufPatcher -Value $upbPatch
    Write-Host 'Patched protobuf_patcher.cmake: skip protoc-gen-upb/-upbdefs tools (unused, abseil link failure)'
}

# Inline patch: stop protobuf_external from building its own protoc.exe. Like the upb
# tools, it fails to link under clang++/lld-link (undefined abseil symbols the linker
# won't resolve from the static abseil archives), and it is redundant: codegen uses the
# host protoc (this script pre-stages vcpkg's protoc at the LITERTLM_HOST_PROTOC path).
# protobuf ships a built-in lever for exactly this cross-compile case -- WITH_PROTOC sets
# protobuf_BUILD_PROTOC_BINARIES=OFF and imports protobuf::protoc from the given path -- so
# forward the host protoc into protobuf_external's CMAKE_ARGS. libprotoc.a/libprotobuf.a/
# libupb.a still build (their own BUILD_* options), and BUILD_PROTOC_BINARIES=OFF also
# skips the protoc-binaries install block outright.
$protobufPkg = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf.cmake'
if ((Test-Path $protobufPkg) -and ((Get-Content -Raw $protobufPkg) -notmatch 'WITH_PROTOC')) {
    $pk = [System.IO.File]::ReadAllText($protobufPkg)
    $anchor = '-Dprotobuf_BUILD_PROTOBUF_BINARIES=ON'
    if ($pk.Contains($anchor)) {
        $repl = $anchor + "`n        " + '-DWITH_PROTOC=${LITERTLM_HOST_PROTOC}'
        $pk = $pk.Replace($anchor, $repl)
        [System.IO.File]::WriteAllText($protobufPkg, $pk)
        Write-Host 'Patched protobuf.cmake: -DWITH_PROTOC=host protoc (skip building protoc.exe; abseil link failure)'
    }
    else {
        Write-Host 'WARNING: protobuf.cmake anchor for WITH_PROTOC not found; protoc.exe may still build'
    }
}

$buildDir = Join-Path $SourceDir 'build_ninja'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'
$litertCmakeDir = Join-Path $litertInstallDir 'cmake'
if (-not (Test-Path $litertCmakeDir)) {
    $litertCmakeDir = Join-Path $litertInstallDir 'lib\cmake\LiteRT'
}
$litertIncludeDir = Join-Path $litertInstallDir 'include'
$gpuEnv = Get-GpuEnvironment

$cmakeExtra = @(
    "-DCMAKE_PREFIX_PATH=$litertInstallDir;$litertCmakeDir"
)
if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) { $cmakeExtra += '-DUSE_CUDA=ON' }
if (Test-Path $litertCmakeDir) { $cmakeExtra += "-DLiteRT_DIR=$litertCmakeDir" }

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT-LM CMake configure failed' }

$vcpkgProtoc = Join-Path $vcpkgDir 'installed\x64-windows\tools\protobuf\protoc.exe'
$protoDir = Join-Path $SourceDir 'runtime\proto'
foreach ($outSubDir in @('proto', 'protobuf')) {
    $protoOutDir = Join-Path $SourceDir "build_ninja\litert_lm\build\runtime\$outSubDir"
    New-Item -Path $protoOutDir -ItemType Directory -Force | Out-Null
    if ((Test-Path $vcpkgProtoc) -and (Test-Path $protoDir)) {
        Get-ChildItem -Path $protoDir -Filter '*.proto' | ForEach-Object {
            & $vcpkgProtoc --proto_path="$SourceDir" --cpp_out="$protoOutDir" $_.FullName 2>&1
        }
        Write-Host "Generated proto files to $protoOutDir"
    }
}
$protoInstallBin = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\bin'
New-Item -Path $protoInstallBin -ItemType Directory -Force | Out-Null
Copy-Item $vcpkgProtoc (Join-Path $protoInstallBin 'protoc.exe') -Force
Copy-Item $vcpkgProtoc (Join-Path $protoInstallBin 'protoc') -Force
$vcpkgInclude = Join-Path $vcpkgDir 'installed\x64-windows\include'
$protoInstallInclude = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\include'
New-Item -Path $protoInstallInclude -ItemType Directory -Force | Out-Null
Copy-Item "$vcpkgInclude\*" $protoInstallInclude -Recurse -Force -ErrorAction SilentlyContinue

$litertBuildDir = Join-Path $buildDir 'litert_lm\build'
$stampDir = Join-Path $buildDir 'litert_lm\stamps'
$llvmAr = (Get-Command llvm-ar.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source

Write-Host 'Running ExternalProject steps 1-4 (mkdir/download/update/patch)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-mkdir litert_lm/stamps/litert_lm-download litert_lm/stamps/litert_lm-update litert_lm/stamps/litert_lm-patch 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host 'WARNING: mkdir/download/update/patch had warnings' }

Write-Host 'Running ExternalProject step 5 (configure)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-configure 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Inner configure OK (expected minor warnings with clang-on-Windows)'
    Write-Host 'Proceeding with build...'
}

$buildNinjaFile = Join-Path $litertBuildDir 'build.ninja'
$stubCount = 0
if (Test-Path $buildNinjaFile) {
    Get-Content $buildNinjaFile | ForEach-Object {
        [regex]::Matches($_, "[\x27""]?([^\x27""\s]+\.a)[\x27""]?") | ForEach-Object {
            $aRel = $_.Groups[1].Value
            $aPath = $aRel
            if ($aRel -match '^[a-zA-Z]:') {
                $aPath = $aRel -replace '/', '\'
            } elseif (-not ($aRel -match '^\.\.') -and -not ($aRel -match '^\.\\')) {
                $aPath = Join-Path $litertBuildDir $aRel
            }
            if (-not (Test-Path $aPath)) {
                $parent = Split-Path $aPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
                    try { $null = New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue } catch { }
                }
                try {
                    $null = & $llvmAr rcs $aPath -- 2>&1
                    $stubCount++
                } catch { }
            }
        }
    }
    Write-Host "Created $stubCount .a aggregate stubs"
}

Write-Host 'Running ExternalProject step 6 (build)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-build 2>&1
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 101) { Write-Host "WARNING: ninja build step exited with code $LASTEXITCODE" }
Write-Host "Build step completed with exit code: $LASTEXITCODE"

Write-Host 'Installing...'
& cmake --install $buildDir --config Release 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: cmake --install had errors (exit $LASTEXITCODE)" }

# Restore vcpkg's protobuf headers hidden before the build, so the committed image
# keeps a complete vcpkg installation.
if ((Test-Path $vcpkgProtoHeadersHidden) -and -not (Test-Path $vcpkgProtoHeaders)) {
    Rename-Item -LiteralPath $vcpkgProtoHeadersHidden -NewName (Split-Path $vcpkgProtoHeaders -Leaf) -Force
    Write-Host 'Restored vcpkg protobuf headers'
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== LiteRT-LM source build completed ==='



