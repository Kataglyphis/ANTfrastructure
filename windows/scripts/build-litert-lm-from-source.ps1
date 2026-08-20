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

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.16.1'
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

#region Phase 1 | Resolve version + clone LiteRT-LM (git-lfs)
Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive | Out-Null

Write-Host 'Setting up git-lfs...'
# Canonical stderr-shield (git lfs writes progress to stderr; PS 5.1 EAP=Stop
# would turn that into a terminating NativeCommandError even with 2>&1).
[void](Invoke-ShieldedNative -Quiet -Label 'git lfs install' -CommandLine 'git lfs install --skip-repo')
[void](Invoke-ShieldedNative -Quiet -Label 'git lfs pull' -CommandLine "cd /d `"$SourceDir`" && git lfs pull")

# v0.14.0 OSS-export bridge (stubs for deleted components + LiteRT support/
# graft) — extracted to litert-lm-export-bridge.ps1 so the version-scoped,
# self-retiring shim is deletable in one piece when upstream's CMake catches
# up. Dot-sourced: the bridge uses this scope's imported modules.
. (Join-Path $PSScriptRoot 'litert-lm-export-bridge.ps1')
Invoke-LiteRtLmExportStubs -SourceDir $SourceDir
Invoke-LiteRtLmSupportGraft -SourceDir $SourceDir
#endregion

#region Phase 2 | Toolchain acquisition (vcpkg + host protoc 31.1 + Temurin JRE)
# vcpkg paths: prefer -VcpkgRoot param, then $env:VCPKG_ROOT, then the container default.
$VcpkgRoot = Get-SourceBuildVersion -Value $VcpkgRoot -EnvironmentVariables @('VCPKG_ROOT') -DefaultValue 'C:\vcpkg'
$vcpkgInstalledX64 = Join-Path $VcpkgRoot 'installed\x64-windows'

# ENV HYGIENE: media-chain stages run IN-PROCESS (Invoke-SourceBuildChain), so
# every process-env mutation below -- the CMAKE_PREFIX_PATH prepend here, the
# $env:LIB overwrite and CXXFLAGS / CCC_OVERRIDE_OPTIONS / CXXFLAGS_<target>
# injections in Phases 3-4 -- would otherwise leak into the NEXT stage's
# compiles. Snapshot them now; the matching finally at the end of the main work
# restores each (null snapshot = variable removed again).
$litertLmEnvSnapshot = @{}
foreach ($envName in @('CMAKE_PREFIX_PATH', 'LIB', 'CXXFLAGS', 'CCC_OVERRIDE_OPTIONS', 'CXXFLAGS_x86_64_pc_windows_msvc')) {
    $litertLmEnvSnapshot[$envName] = [Environment]::GetEnvironmentVariable($envName)
}
try {

$env:CMAKE_PREFIX_PATH = "$vcpkgInstalledX64;$env:CMAKE_PREFIX_PATH"
$protobufTools = Join-Path $vcpkgInstalledX64 'tools\protobuf'
if (Test-Path $protobufTools) { $env:PATH = "$protobufTools;$env:PATH" }

# Shared shape for the two portable zip-tool fetches below (protoc + JRE): probe
# first, download with a PK magic-byte guard (an HTML error page served in place
# of the zip used to surface hours later as a cryptic Expand-Archive failure),
# extract, re-probe, throw when the expected file still is not there.
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

# (The vcpkg-protobuf header hide/restore dance was DELETED 2026-08-03: vcpkg
# ships zlib-only since the same date — setup-vcpkg.ps1 — and every image in
# the current chain is built from that base, so the "older base images" case
# the legacy block served is unreachable. History: the block isolated
# protobuf_external v6.31.1 from vcpkg's different-major protobuf headers.)

# Version-matched host protoc. The from-source runtime is protobuf 6.31.1, but vcpkg's
# protoc is a DIFFERENT major (libprotoc 33.4). Using it for codegen emits .pb.h/.cc that
# use newer macros (PROTOBUF_FUTURE_ADD_NODISCARD) and a gencode version stamp the 6.31.1
# headers reject ("Protobuf C++ gencode is built with an incompatible version" #error).
# Building a matching 6.31.1 protoc from source fails to link (abseil under clang++/lld-
# link), so fetch the official prebuilt protoc for release v31.1 (== runtime 6.31.1) and
# use it for every codegen step below (litert-lm protos, sentencepiece, WITH_PROTOC import).
$protocVer = Get-SourceBuildVersion -EnvironmentVariables @('PROTOC_VERSION') -DefaultValue '31.1'
$hostProtocDir = "C:\temp\protoc-$protocVer"
$hostProtoc = Join-Path $hostProtocDir 'bin\protoc.exe'
[void](Install-PortableZipTool -Url "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVer/protoc-$protocVer-win64.zip" `
        -ZipPath "C:\temp\protoc-$protocVer-win64.zip" -Destination $hostProtocDir `
        -Description "version-matched protoc v$protocVer" `
        -Probe { if (Test-Path $hostProtoc) { $hostProtoc } })
Write-Host "Using version-matched host protoc: $hostProtoc ($(& $hostProtoc --version))"

# litert-lm generates its tool-call JSON parser at build time by running the ANTLR jar
# (java -jar antlr-4.13.2-complete.jar ...), so the build needs a JRE. The media base image
# doesn't ship Java, so fetch a portable Temurin JRE and put java.exe on PATH. (No JDK
# needed -- ANTLR only runs the prebuilt jar.)
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
    $stubLibPath = Join-Path $stubLibDir "$stub.lib"
    $stubOut = & $llvmLib "/out:$stubLibPath" /llvmlibempty 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $stubLibPath)) {
        # A missing stub only surfaces much later as 'lld-link: could not open <stub>.lib'.
        throw "llvm-lib failed to create link-lib stub $stub.lib (exit $LASTEXITCODE): $(@($stubOut) -join [Environment]::NewLine)"
    }
}
$vcpkgZlib = Join-Path $vcpkgInstalledX64 'lib\z.lib'
if (Test-Path $vcpkgZlib) { Copy-Item $vcpkgZlib (Join-Path $stubLibDir 'z.lib') -Force }

# LiteRT's core dynamic-loading path (litert/core/dynamic_loading.cc and the delegate/plugin
# loaders) does `#include <dlfcn.h>` with no _WIN32 guard, so it fails "'dlfcn.h' file not
# found" on Windows. Drop a header-only <dlfcn.h> shim on the include path that maps the POSIX
# dl* API onto Win32 LoadLibrary/GetProcAddress. Header-only (static inline) => nothing extra to
# link. Placed on CXXFLAGS below so every external that ports Unix dl code picks it up.
$winShimDir = 'C:\temp\winshims'
New-Item -ItemType Directory -Force $winShimDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'shims\dlfcn.h') $winShimDir -Force

# LiteRT's dynamic_loading.cc also does an unguarded `#include <unistd.h>` and calls
# access(path, R_OK). MSVC's CRT already declares access() in <io.h> (deprecated -> _access);
# the POSIX permission-mode constants are all it's missing. (Its `#include <link.h>` is under
# `#if __has_include(<link.h>)`, so it simply drops out on Windows -- no shim needed there.)
Copy-Item (Join-Path $PSScriptRoot 'shims\unistd.h') $winShimDir -Force

# LiteRT's Qualcomm vendor code (vendors/qualcomm/compiler/qnn_compose_graph.cc) includes
# <alloca.h>, which doesn't exist on Windows -- the CRT puts alloca (_alloca) in <malloc.h>.
Copy-Item (Join-Path $PSScriptRoot 'shims\alloca.h') $winShimDir -Force
Write-Host "Wrote Windows <dlfcn.h> + <unistd.h> + <alloca.h> shims to $winShimDir"
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
$sysLibDirs = @(foreach ($g in $sysLibGlobs) {
    $d = Get-ChildItem $g -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($d) { $d.FullName }
})
# LIB must carry MSVC + SDK (ucrt/um) + clang runtime dirs or every link -- even
# the configure compiler check -- dies on missing kernel32.lib/libcmt.lib. Fail
# NOW with the glob list instead of hours later inside the ExternalProject.
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
# Also force the dynamic CRT here: the rest of the build gets it from CMake's default
# CMAKE_MSVC_RUNTIME_LIBRARY (MultiThreadedDLL), but the cc-crate bridge build (cxx, link-cplusplus)
# is outside CMake and its clang++ GNU driver defaults to the STATIC CRT (MT_StaticRelease), which
# makes lld-link's /failifmismatch reject libcxxbridge1.a(cxx.o) against the MD_DynamicRelease rest
# at the final litert_lm_main link. The cc bridge uses the GNU-driver clang++ (it rejects the
# clang-cl-style /MD as a filename), so select the dynamic CRT the GNU-driver way, matching exactly
# what CMake emits for every other object: -D_DLL -D_MT -Xclang --dependent-lib=msvcrt.
$env:CXXFLAGS_x86_64_pc_windows_msvc = (@($env:CXXFLAGS_x86_64_pc_windows_msvc, '-std=c++17', '-D_DLL', '-D_MT', '-Xclang', '--dependent-lib=msvcrt') | Where-Object { $_ }) -join ' '
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
# Also put the Windows <dlfcn.h>/<unistd.h> shim dir (written above) on the system include
# path so LiteRT's Unix-style includes resolve; forward slashes + two tokens so it survives
# being split out of CMAKE_CXX_FLAGS. And define NOMINMAX/NOGDI globally: LiteRT pulls in
# <windows.h> (directly and via our dlfcn shim) but -- unlike TFLite -- its build doesn't set
# these, so the `min`/`max` (and GDI `ERROR`) macros clobber std::max / absl and break
# headers like litert_tensor_buffer_requirements.h ("expected unqualified-id" on std::max).
# LiteRT is configured from ${CMAKE_CXX_FLAGS} (litert.cmake), which CMake seeds from
# $ENV{CXXFLAGS}, so all of this reaches it.
# Force-include the <unistd.h> shim into every C++ TU: LiteRT's vendor backends (Qualcomm
# qnn_manager.cc, Google Tensor dispatch, ...) call setenv()/close() WITHOUT including
# <unistd.h> (they rely on it being pulled in transitively on POSIX), so the shim being on the
# include path isn't enough -- it has to be injected. -include also brings <io.h>'s close()/
# access(). It's harmless where unused (include-guarded, static-inline). The Rust cxx/cc bridge
# reads the target-scoped CXXFLAGS_<target> instead, so it is unaffected.
# LLVM-BUMP TRIPWIRE (noted 2026-08-07): `-fdelayed-template-parsing` is
# DEPRECATED after C++20 — clang already warns, which is why the matching
# -Wno- rides along. Since versions.env now PINS the Windows clang
# (LLVM_WINDOWS_VERSION), this is no longer a drifting risk but a SCHEDULED one:
# whenever that pin moves, check here first. If the flag has been removed rather
# than deprecated, this line stops the litert-lm build, and the fix is to drop
# both flags and re-test the MSVC-like two-phase-lookup behaviour they restore.
$env:CXXFLAGS = (@($env:CXXFLAGS, (Get-WarningNoiseSuppressionFlags), '-fdelayed-template-parsing', '-Wno-delayed-template-parsing-in-cxx20', '-isystem C:/temp/winshims', '-DNOMINMAX', '-DNOGDI', '-include unistd.h', '-D_USE_MATH_DEFINES') | Where-Object { $_ }) -join ' '
Write-Host "Set CXXFLAGS (delayed template parsing + dlfcn/unistd/alloca shim + NOMINMAX/NOGDI + force-include unistd.h) for CMake sub-builds: $env:CXXFLAGS"

# Globally strip -fPIC from every clang++ invocation. Several bundled deps (sentencepiece
# -- both litert-lm's own sentencepiece_external AND the copy vendored inside tokenizers-
# cpp) hardcode `-fPIC` in an `if(NOT MSVC)` branch, which clang++ takes because its
# compiler id is Clang, not MSVC. -fPIC is a HARD error on the windows-msvc target
# ("unsupported option '-fPIC'") and is meaningless on Windows anyway. clang's driver
# honours CCC_OVERRIDE_OPTIONS to edit the command line: `#` silences the notice, `x-fPIC`
# deletes every literal `-fPIC` arg. This fixes all current and future -fPIC occurrences in
# one place (more robust than patching each vendored CMakeLists).
#
# Same mechanism also strips gemmlowp's MSVC-only cl.exe flags: its contrib/CMakeLists.txt
# gates `add_definitions(/bigobj /nologo /EHsc /GF /MP /Gm- /wd4800 /wd4805 /wd4244)` on
# WIN32 (not MSVC), so clang++'s GNU driver receives them and dies ("no such file or
# directory: '/bigobj'"). Delete each. NB: only `x` (delete) edits are safe here -- a `+`
# (append) edit hits EVERY clang invocation including the resource compiler (.rc -> .res),
# which rejects C/C++ flags; so big-object handling, if gemmlowp ever needs it, must be done
# in a CXX-only channel, not via a global CCC_OVERRIDE_OPTIONS append.
$env:CCC_OVERRIDE_OPTIONS = '#x-fPIC x/bigobj x/nologo x/EHsc x/GF x/MP x/Gm- x/wd4800 x/wd4805 x/wd4244'
Write-Host "Set CCC_OVERRIDE_OPTIONS to strip -fPIC + gemmlowp MSVC flags from clang++ (windows-msvc target rejects them)"

#endregion

#region Phase 5 | Source tree & CMake winfix patches (clang-cl/lld-link port)
# NOTE: LiteRT-LM v0.13.1 ships runtime/proto/ as Bazel-only (BUILD + *.proto, no CMakeLists.txt),
# so the former runtime/proto/CMakeLists.txt patch (disable protobuf_generate / find_package Protobuf
# QUIET) was a permanent no-op: the target file never exists at patch time, and the build succeeds
# without it (verified across full media-litert rebuilds -- it never logged "Patched"). Removed to cut
# dead weight. If a future LiteRT-LM tag reintroduces a committed runtime/proto/CMakeLists.txt that
# needs the vcpkg-protobuf handling, re-add an Edit-SourceFile block here.

# Inline patch: correct a typo in LiteRT-LM's own cmake/modules/fetch_content.cmake.
# It sets `MINJA_EXAMPLE_ENABLE OFF` to skip minja's example programs, but minja's
# actual option is `MINJA_EXAMPLE_ENABLED` (trailing D). The mismatch leaves examples
# ON; minja compiles them with a global `-Werror` (add_compile_options in its
# CMakeLists), so example sources (examples/raw.cpp, chat-template.cpp) fail on
# -Wdeprecated-declarations (localtime) and analyzer diagnostics from nlohmann/json.
# The examples are not part of the LiteRT-LM runtime -- fix the option name so they
# are actually disabled. \b keeps the correctly-spelled ENABLED untouched (idempotent).
$fetchContentCmake = Join-Path $SourceDir 'cmake\modules\fetch_content.cmake'
[void](Edit-SourceFile -Path $fetchContentCmake -Description 'fetch_content.cmake: MINJA_EXAMPLE_ENABLE -> MINJA_EXAMPLE_ENABLED (disable minja example programs)' -Transform {
    param($c)
    $c -replace 'MINJA_EXAMPLE_ENABLE\b', 'MINJA_EXAMPLE_ENABLED'
})

# v0.15.0 UPSTREAM CMAKE STALENESS #1 (run 15, 2026-08-11): the cmake proto
# list (cmake/packages/litert_lm/CMakeLists.txt:55-61) still enumerates only
# the v0.13-era protos, but 0.15.0 sources include the generated headers of
# FOUR newer runtime/proto files (model_resources.h -> embedding_metadata.pb.h
# was the first to die; the bazel BUILD has all of them). Their cmake lane
# clearly is not CI-covered at this tag. Append the missing protos after the
# token.proto line.
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

# v0.15.0 UPSTREAM CMAKE STALENESS #2: their absl pin (cmake/packages/absl/
# absl.cmake GIT_TAG 20260107.1) predates absl/status/status_macros.h, which
# 0.15.0's OWN generated sources include (litertlm_read.cc,
# model_type_utils.cc -> fatal error: file not found; the header exists from
# 20260526.0 on - verified against abseil-cpp tags). Bump their pin to the
# repo-wide ABSEIL_VERSION so litert_lm's inner code compiles against the
# absl its bazel build actually expects. Scope: absl_external only (tflite/
# litert externals fetch their own absl and are untouched).
$abslPkgCmake = Join-Path $SourceDir 'cmake\packages\absl\absl.cmake'
$abseilPin = Get-SourceBuildVersion -EnvironmentVariables @('ABSEIL_VERSION') -DefaultValue '20260817.0'
$abseilPinMarker = [regex]::Escape($abseilPin)
[void](Edit-SourceFile -Path $abslPkgCmake -Marker $abseilPinMarker -Description "absl.cmake: bump stale upstream absl pin 20260107.1 -> $abseilPin (status_macros.h)" -WarnMessage 'absl.cmake GIT_TAG anchor not found; status_macros.h includes will fail' -Transform {
    param($c)
    $c -replace '(GIT_TAG\s*\r?\n\s*)20260107\.1', ('${1}' + $abseilPin)
})

# v0.15.0 UPSTREAM CMAKE STALENESS #3 (run 16, 2026-08-11): their litert
# pin (cmake/packages/litert/litert.cmake GIT_TAG fb16353a..., '#Updated on
# 2026-03-24') predates the LiteRT APIs that 0.15.0's own executor code
# calls - llm_executor_settings_utils.cc:264 wants
# litert::CpuOptions::SetEnableYNNPack, llm_litert_compiled_model_executor
# wants the newer CompiledModel::Run/RunAsync signatures. The bazel
# WORKSPACE pins LITERT_REF=3cb830ad9c94f9922f0a88dd431b005413628919 for
# this tag - bump their cmake pin to the bazel truth.
$litertPkgCmake = Join-Path $SourceDir 'cmake\packages\litert\litert.cmake'
[void](Edit-SourceFile -Path $litertPkgCmake -Marker '3cb830ad9c94f9922f0a88dd431b005413628919' -Description 'litert.cmake: bump stale upstream litert pin fb16353a -> 3cb830ad (bazel WORKSPACE truth; SetEnableYNNPack/RunAsync APIs)' -WarnMessage 'litert.cmake GIT_TAG anchor fb16353a not found; executor API-skew compile errors will follow' -Transform {
    param($c)
    $c -replace 'fb16353a648922cb6c67a8e9a7a9ebc946360ad2', '3cb830ad9c94f9922f0a88dd431b005413628919'
})

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
[void](Edit-SourceFile -Path $superCmake -Marker 'force-release-buildtype' -Description 'CMakeLists.txt: force inner litert_lm CMAKE_BUILD_TYPE=Release' -Transform {
    param($c)
    $btAnchor = '"-DLITERTLM_HOST_FLATC_BIN_DIR=${LITERTLM_HOST_FLATC_BIN_DIR}"'
    $btRepl = $btAnchor + "`n        `"-DCMAKE_BUILD_TYPE=Release`"  # force-release-buildtype"
    $c.Replace($btAnchor, $btRepl)
})

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
$upbPatch = Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\protobuf-upb-generators-skip.cmake')
[void](Add-FileBlockOnce -Path $protobufPatcher -Marker 'LiteRTLM-winfix upb_generators' -Content $upbPatch `
        -Description 'protobuf_patcher.cmake: skip protoc-gen-upb/-upbdefs tools (unused, abseil link failure)')

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
[void](Edit-SourceFile -Path $protobufPkg -Marker 'WITH_PROTOC' -Description 'protobuf.cmake: -DWITH_PROTOC=host protoc (skip building protoc.exe; abseil link failure)' -WarnMessage 'protobuf.cmake anchor for WITH_PROTOC not found; protoc.exe may still build' -Transform {
    param($c)
    $anchor = '-Dprotobuf_BUILD_PROTOBUF_BINARIES=ON'
    $repl = $anchor + "`n        " + '-DWITH_PROTOC=${LITERTLM_HOST_PROTOC}'
    $c.Replace($anchor, $repl)
})

# Inline patch: strip -fPIC from sentencepiece's src/CMakeLists.txt. clang++ targets
# x86_64-pc-windows-msvc but reports compiler id Clang (not MSVC), so sentencepiece's
# `if(NOT MSVC)` branch adds `-O3 -Wall -fPIC` to CMAKE_CXX_FLAGS -- and -fPIC is a hard
# error on the windows-msvc target ("unsupported option '-fPIC'"). PIC is meaningless on
# Windows, so drop just the flag (keep -O3/-Wall). Grafted onto sentencepiece_patcher.cmake
# (its PATCH_COMMAND hook), re-reading src/CMakeLists.txt after the patcher writes it.
$spPatcher = Join-Path $SourceDir 'cmake\packages\sentencepiece\sentencepiece_patcher.cmake'
$spPatch = Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\sentencepiece-winfix.cmake')
[void](Add-FileBlockOnce -Path $spPatcher -Marker 'LiteRTLM-winfix sentencepiece-fpic' -Content $spPatch `
        -Description 'sentencepiece_patcher.cmake: strip -fPIC + skip spm CLI tools (windows-msvc/abseil link)')

# Inline patch: fix tokenizers-cpp's build for Windows. tokenizers.cmake uses a CUSTOM
# CONFIGURE_COMMAND (`cmake -S <SOURCE_DIR> -B <BINARY_DIR>`) with no -G and relies on
# ExternalProject's DEFAULT build/install commands. Two problems on Windows:
#  (1) no -G -> the default Visual Studio generator, which ignores -DCMAKE_CXX_COMPILER=
#      clang++ (uses CL.exe) and then rejects the clang-only flags this build puts in
#      CMAKE_CXX_FLAGS (`-fdelayed-template-parsing` ...) -> "cl : command line error D8021".
#  (2) the default BUILD_COMMAND is `make`, which does not exist on Windows ("'make' is not
#      recognized").
# Fix both: add -GNinja (so clang++ is used and the clang flags are valid) and set explicit
# BUILD_COMMAND/INSTALL_COMMAND via `cmake --build` (generator-agnostic -> runs Ninja).
# Third problem (3): the Rust static lib name. tokenizers-cpp's CMakeLists picks
# `libtokenizers_c.a` in its `else()` (non-MSVC) branch -- taken because our C++ compiler
# id is Clang -- but rustc builds the crate for the x86_64-pc-windows-msvc target and emits
# MSVC-named `tokenizers_c.lib`, so the custom command's copy of libtokenizers_c.a fails
# ("No such file"). Fix by (a) a PATCH_COMMAND that rewrites the fetched tokenizers-cpp
# CMakeLists to use tokenizers_c.lib, and (b) rewriting litert-lm's own import refs the same
# way. (The C++ libtokenizers_cpp.a is genuinely lib*.a -- CMake+clang++ GNU driver -- so it
# is left alone.)
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
        Copy-Item (Join-Path $PSScriptRoot 'patches\litert-lm\tokenizers_libname_patch.cmake') $tkPatchScript -Force
        $tkPatchCmd = 'PATCH_COMMAND ${CMAKE_COMMAND} -DTK_SRC=<SOURCE_DIR> -P ${CMAKE_CURRENT_LIST_DIR}/tokenizers_libname_patch.cmake' + "`n    " + $tkCfgAnchor
        $tk = $tk.Replace($tkCfgAnchor, $tkPatchCmd)
        # (3b) litert-lm's own imports of the rust lib (leaves libtokenizers_cpp.a untouched)
        $tk = $tk.Replace('libtokenizers_c.a', 'tokenizers_c.lib')
        [System.IO.File]::WriteAllText($tokenizersCmake, $tk)
        Write-Host 'Patched tokenizers.cmake: -GNinja + cmake --build + rust lib -> tokenizers_c.lib'
    }
    else {
        Write-Host 'WARNING: tokenizers.cmake anchors not found; may still use CL.exe/make/libtokenizers_c.a'
    }
}

# TFLite's own tensorflow/lite/profiling/proto/CMakeLists.txt already generates
# profiling_info.pb.cc / model_runtime_info.pb.cc and links them into
# {profiling,model_runtime}_info_proto (which the tflite aggregate pulls in). But litert-lm's
# tflite_shims *also* runs generate_protobuf(tflite_profiling) on the same two protos, so two
# ninja custom commands emit the identical tensorflow/lite/profiling/proto/profiling_info.pb.cc
# -> "multiple rules generate ..." at generate time, and (once that clears) duplicate proto
# symbols when both tflite_profiling and profiling_info_proto reach the final link. Drop the
# redundant generation; the profiling *.cc sources still need the generated headers, so order
# them after TFLite's protoc via OBJECT_DEPENDS (target-order-independent, since
# profiling_info_proto is configured after tflite_profiling).
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
    # tflite_profiling globs profiling/*.cc and only drops *_test.cc, but atrace_profiler.cc
    # is Android-only (includes <dlfcn.h> to dlopen libandroid) and has no Windows path, so
    # it fails "'dlfcn.h' file not found". Exclude it too (platform_profiler.cc already
    # compiles to the no-op backend on non-Android/Apple).
    $c.Replace('EXCLUDE REGEX "_test\\.cc$"', 'EXCLUDE REGEX "(_test|atrace_profiler)\\.cc$"')
})

# tensorflow/lite/core/model_building.h friends its same-namespace helper classes with
# unqualified `friend class Helper;` / `friend class Tensor;`. clang++ (GNU driver, windows-msvc
# target) applies the MSVC unqualified-friend extension and binds those names to a type in an
# OUTER namespace, so the intended tflite::model_builder::{Helper,Tensor} are NOT friends and
# Tensor's ctor can't read the private Buffer::builder_ ("'builder_' is a private member").
# Forward-declare both classes in the local namespace immediately before Buffer so ordinary
# lookup binds the friend names locally (which is what MSVC effectively did). This runs from
# tflite_patcher.cmake because the tflite ExternalProject PATCH_COMMAND does
# `git checkout -- . && git clean -df` first, which would revert any earlier edit.
$tflitePatcher = Join-Path $SourceDir 'cmake\packages\tflite\tflite_patcher.cmake'
$mbPatch = Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\tflite-model-building-friend.cmake')
[void](Add-FileBlockOnce -Path $tflitePatcher -Marker 'LiteRTLM-winfix model_building-friend' -Content $mbPatch -Encoding ASCII `
        -Description 'tflite_patcher.cmake: model_building.h friend forward-declarations')

# LiteRT's core/dynamic_loading.cc is written for POSIX: std::filesystem::path::c_str() and the
# path->string implicit conversion are WIDE (wchar_t / std::wstring) on Windows but narrow on
# Linux, so access(path.c_str()), results.push_back(path) into a vector<string>, and
# FindLiteRtSharedLibsHelper(path) all fail to compile. Narrow every such use with .string()
# (UTF-8/native std::string on all platforms). setenv() is provided by our <unistd.h> shim.
# Done from litert_patcher.cmake because the litert ExternalProject PATCH_COMMAND runs
# `git checkout -- . && git clean -df` first, reverting any earlier edit. patch_file_content
# (litert-lm's own helper, cmake/modules/utils.cmake) does a literal string(REPLACE) of ALL
# occurrences when its IS_REGEX arg is FALSE.
# LiteRT's Qualcomm compiler plugin (vendors/qualcomm/compiler/qnn_compose_graph.cc, via
# litert/cc/internal/litert_op_options.h) includes "flatbuffers/flexbuffers.h", but litert's
# global CXX flags (litert.cmake) add -isystem for tflite/absl/protobuf and NOT flatbuffers,
# so it fails "'flatbuffers/flexbuffers.h' file not found". Add the flatbuffers install include.
$litertCmake = Join-Path $SourceDir 'cmake\packages\litert\litert.cmake'
[void](Edit-SourceFile -Path $litertCmake -Marker '-isystem \$\{FLATBUFFERS_INCLUDE_DIR\}' -Description 'litert.cmake: add flatbuffers install include to litert CXX flags' -WarnMessage 'litert.cmake CXX flags anchor not found; flexbuffers.h may be missing' -Transform {
    param($c)
    $lcAnchor = '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -w"'
    $c.Replace($lcAnchor, '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -isystem ${FLATBUFFERS_INCLUDE_DIR} -w"')
})

$litertPatcher = Join-Path $SourceDir 'cmake\packages\litert\litert_patcher.cmake'
$dlPatch = Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\litert-patcher-winfix.cmake')
# Run-18 forensics (2026-08-11): the appended patcher executed WITHOUT the
# examples-drop block even though the repo file carried it - print what THIS
# container actually read so stale-bind vs. non-execution is decidable from
# the stage log alone.
Write-Host ("litert-patcher-winfix.cmake read: {0} chars; examples REMOVE_RECURSE block present: {1}" -f $dlPatch.Length, $dlPatch.Contains('REMOVE_RECURSE'))
[void](Add-FileBlockOnce -Path $litertPatcher -Marker 'LiteRTLM-winfix dynamic-loading' -Content $dlPatch -Encoding ASCII `
        -Description 'litert_patcher.cmake: dynamic_loading.cc std::filesystem::path narrowing')

# litert-lm's own runtime/executor/litert_compiled_model_executor_utils.cc calls
# gpu_options.SetWeightCacheFd(fd) in the fd-based weight-cache branch, but litert::GpuOptions
# exposes SetWeightCacheFd only on POSIX (it takes a raw file descriptor); on Windows the method
# doesn't exist -> "no member named 'SetWeightCacheFd'". GPU is disabled on this lane anyway, so
# guard just that call (the surrounding Duplicate()/Release() keep their side effects). This is
# the top-level litert-lm repo (no ExternalProject git-checkout), so patch the source directly.
$execUtils = Join-Path $SourceDir 'runtime\executor\litert_compiled_model_executor_utils.cc'
[void](Edit-SourceFile -Path $execUtils -Marker 'LiteRTLM-winfix.*SetWeightCacheFd' -Description 'litert_compiled_model_executor_utils.cc: guard SetWeightCacheFd on Windows' -WarnMessage 'SetWeightCacheFd anchor not found in executor utils' -Transform {
    param($c)
    $euAnchor = 'gpu_options.SetWeightCacheFd(fd);'
    $euRepl = "#if !defined(_WIN32)`n      gpu_options.SetWeightCacheFd(fd);`n#else`n      (void)fd;  // [LiteRTLM-winfix] litert::GpuOptions has no fd-based weight cache on Windows`n#endif"
    $c.Replace($euAnchor, $euRepl)
})

# Same story in runtime/executor/llm_executor_settings_utils.cc: it calls litert::GpuOptions /
# litert::RuntimeOptions setters (SetKernelBatchSize, SetDisableDelegateClustering) that the
# Windows litert build doesn't expose (GPU/delegate tuning). Wrap each full call statement in a
# _WIN32 guard. The regex `\([^;]*\);` spans the multi-line call up to its terminating semicolon
# ([^;] matches newlines in .NET regex), so exact indentation doesn't matter.
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

# runtime/executor/llm_litert_npu_compiled_model_executor.cc reads per-tensor quantization via
# litert::SimpleTensor::HasQuantization()/PerTensorQuantization(), which the Windows litert build
# doesn't expose. This is the NPU executor (dead on Windows -- no NPU hardware, NPU disabled), so
# guard the two quantization blocks with _WIN32; the surrounding params keep their defaults (which
# is exactly what the non-quantized/else path already does). Regex spans each block via [\s\S]*?
# (non-greedy) to its distinctive terminating line, so exact indentation doesn't matter.
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

# runtime/executor/{vision,audio,...}_litert_compiled_model_executor.cc set the GoogleTensor NPU
# performance mode: GetGoogleTensorOptions() then SetPerformanceMode(GoogleTensorOptions::
# PerformanceMode::kBurst). Both the setter and the PerformanceMode enum are absent from the Windows
# litert build (GoogleTensor is a mobile NPU, dead here); Qualcomm's equivalent IS present so only
# GoogleTensor needs guarding. Wrap the whole GetGoogleTensorOptions+SetPerformanceMode block in
# _WIN32 (the code falls through to SetHardwareAccelerators(kCpu) regardless). Guarding the block
# (not just the setter) keeps the bound google_tensor_options reference from going unused.
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

# google-ai-edge/LiteRT-LM v0.13.1's CMake path references several runtime/core sources that the
# OSS export stripped (all 404 upstream): session_basic.cc, session_factory.cc, engine_impl.cc.
# It ships the "advanced" equivalents instead (session_advanced.cc, engine_advanced_impl.cc) plus a
# header-only EngineFactory registry (engine_factory.h) -- engine_factory.cc is likewise absent but
# unneeded. None of the stripped files have a header (session_basic.h/session_factory.h/
# engine_impl.h are all 404), so no translation unit includes them or references their symbols;
# they are dangling link-only targets. Earlier builds never reached this (the cxx-bridge failure
# short-circuited the inner build). The real engine lives in engine_advanced_impl.cc, which
# self-registers via LITERT_LM_REGISTER_ENGINE(kAdvancedLiteRTCompiledModel, ...) but is wired into
# NO target. So: (a) point the first engine target at engine_advanced_impl.cc so the real engine
# compiles exactly once (compiling it in both engine targets would double-define the class +
# registrar in the local aggregate), and (b) drop empty translation units for the remaining
# stripped names so their (unused) targets/links resolve. The generator globs runtime/*.cc into
# GENERATED_SRC_DIR, so every file must exist before configure; runtime/core/CMakeLists.txt is
# litert-lm's own file (no ExternalProject git-reset), so patch it directly.
$coreCmake = Join-Path $SourceDir 'runtime\core\CMakeLists.txt'
[void](Edit-SourceFile -Path $coreCmake -Marker 'LiteRTLM-winfix' -Description 'runtime/core/CMakeLists.txt: point runtime_core_engine_impl at engine_advanced_impl.cc' -Transform {
    param($c)
    # Redirect only the first engine target (runtime_core_engine_impl, NOT ..._cpu_only) to the
    # shipped engine implementation. Regex is tolerant of CRLF/LF + indentation; the space before
    # STATIC disambiguates from the cpu_only target whose name shares the runtime_core_engine_impl
    # prefix, and \s+ spans the newline between the target and its source argument.
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

# runtime/engine/cpu_affinity_utils.cc defines IsPixelTensorDevice / GetPixelPerformanceCores /
# SetCpuAffinity, which the header-only engine_factory.h calls (so litert_lm_lib.cc, engine_advanced
# _impl.cc and litert_lm_main.cc all reference them). It's a Bazel target (runtime/engine/BUILD) but
# the CMake build never lists cpu_affinity_utils.cc as a source of any add_litertlm_library -- a
# Bazel-vs-CMake gap in the OSS export -> the symbols are never compiled and litert_lm_main fails to
# link. Add the source to runtime_engine_litert_lm_lib (a local lib that IS in the aggregate).
$engineCmake = Join-Path $SourceDir 'runtime\engine\CMakeLists.txt'
[void](Edit-SourceFile -Path $engineCmake -Marker 'LiteRTLM-winfix cpu_affinity' -Description 'runtime/engine/CMakeLists.txt: compile cpu_affinity_utils.cc + 6 orphan sources into runtime_engine_litert_lm_lib' -Transform {
    param($c)
    # Same Bazel-vs-CMake gap for a batch of other sources that exist in the tree but are listed in NO
    # CMakeLists (channel_util, image_preprocessor_utils, the VLM/Gemma4 data processors, litert_util,
    # llg_tool_call_utils) -> their symbols (ExtractChannelContent, GetEnvironment, AppendToolRules,
    # FastVlmDataProcessor::Create, ...) are undefined at the litert_lm_main link. Compile them into
    # the same engine lib (relative to runtime/engine/); it carries the broad LITERTLM_DEPS + include
    # paths, and it is in the aggregate that litert_lm_main links.
    [regex]::Replace($c,
        '(add_litertlm_library\(runtime_engine_litert_lm_lib STATIC\s+litert_lm_lib\.cc)',
        "`$1`n  cpu_affinity_utils.cc  # [LiteRTLM-winfix cpu_affinity] compiled by Bazel but omitted from the CMake target`n  ../conversation/channel_util.cc  # [LiteRTLM-winfix orphans]`n  ../components/preprocessor/image_preprocessor_utils.cc`n  ../conversation/model_data_processor/fastvlm_data_processor.cc`n  ../conversation/model_data_processor/gemma4_data_processor.cc`n  ../util/litert_util.cc`n  ../components/constrained_decoding/llg_tool_call_utils.cc`n  ../components/model_resources_streaming.cc`n  ../core/session_advanced.cc`n  ../executor/litert/kv_cache.cc`n  ../executor/llm_litert_npu_compiled_model_executor_utils.cc`n  ../framework/execution_queue.cc`n  ../framework/resource_management/context_handler/context_handler.cc`n  ../framework/resource_management/resource_manager.cc`n  ../framework/resource_management/serial_execution_manager.cc`n  ../framework/resource_management/threaded_execution_manager.cc`n  ../framework/resource_management/utils/resource_manager_utils.cc`n  ../util/data_stream.cc`n  ../util/file_data_stream.cc`n  ../util/litert_lm_streaming_loader.cc`n  ../util/log_tensor_buffer.cc")
})
# v0.14 orphan retargeting + subsystem sources + deps block: lives in the
# export bridge (see litert-lm-export-bridge.ps1, dot-sourced in Phase 1);
# the caller owns the read/compare/write cycle around the pure text transform.
$engineTxt = [System.IO.File]::ReadAllText($engineCmake)
$engineBridged = Add-LiteRtLmV014OrphanSources -EngineCmakeText $engineTxt -SourceDir $SourceDir
if ($engineBridged -ne $engineTxt) {
    [System.IO.File]::WriteAllText($engineCmake, $engineBridged)
    Write-Host '[LiteRTLM-winfix orphans] engine lib source list updated'
}

# litert_util.cc AND resource_manager.cc both set EnvironmentOptions::Tag::kMinLoggerSeverity, which
# the litert core pinned by litert-lm v0.13.1 does not expose (the litert-lm source tree is ahead of
# its own litert dependency). It only pushes an optional min-log-severity env option -> compile that
# block out in each. Both blocks end with `)});` but litert_util wraps the value in static_cast (one
# extra ')'), so anchor on kMinLoggerSeverity and match to the first `)});` + closing brace. Patched
# on $SourceDir before the ExternalProject copies sources into generated/src (same phase as the
# executor #if !defined(_WIN32) guards, which propagate fine).
foreach ($rel in @('runtime\util\litert_util.cc', 'runtime\framework\resource_management\resource_manager.cc')) {
    $p = Join-Path $SourceDir $rel
    if ((Test-Path $p) -and ((Get-Content -Raw $p) -notmatch 'LiteRTLM-winfix kMinLoggerSeverity')) {
        $t = [System.IO.File]::ReadAllText($p)
        $t = [regex]::Replace($t,
            '(if \(auto severity = GetMinLogSeverity\(\)\) \{[\s\S]*?kMinLoggerSeverity[\s\S]*?\)\}\);\s*\})',
            "#if 0  // [LiteRTLM-winfix kMinLoggerSeverity] litert core pinned here has no such Tag`n      `$1`n#endif")
        [System.IO.File]::WriteAllText($p, $t)
        Write-Host "Patched $(Split-Path $rel -Leaf): compiled out kMinLoggerSeverity env option (absent in pinned litert core)"
    }
}

# The Rust staticlib (litert_lm_deps) pulls in rust std, whose windows-msvc target needs system libs
# (ws2_32 for sockets, ntdll for Nt*, userenv/bcrypt/advapi32 for env+rng). cargo emits these via
# #[link] directives, but they are lost when the staticlib is linked through the C++ driver -> a wall
# of undefined __declspec(dllimport) WSA*/Nt*/socket symbols at the litert_lm_main link. NEITHER
# target_link_libraries(PUBLIC ws2_32) NOR target_link_options("LINKER:/DEFAULTLIB:...") reach the
# actual link (litert_lm_main's command is assembled from a custom UNIFIED_LINK_SPEC + a .rsp, and
# CMake silently drops the /DEFAULTLIB entries). What DOES work is the same mechanism clang uses for
# msvcrt (--dependent-lib -> a /DEFAULTLIB directive baked into the .obj's .drectve): emit those
# directives via #pragma comment(lib) in a source that is definitely linked into litert_lm_main.
# cpu_affinity_utils.cc qualifies (its IsPixelTensorDevice/etc. resolve into the exe), so lld-link
# reads its .drectve and pulls each system lib from the SDK LIB path (kernel32.lib already resolves).
$cpuAffCc = Join-Path $SourceDir 'runtime\engine\cpu_affinity_utils.cc'
$pragmaBlock = Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\cpu-affinity-rust-syslibs.cc')
[void](Add-FileBlockOnce -Path $cpuAffCc -Marker 'LiteRTLM-winfix rust-syslibs' -Content $pragmaBlock -Prepend `
        -Description 'cpu_affinity_utils.cc: #pragma comment(lib) rust-std windows system libs into litert_lm_main')

# re2's ExternalProject passes NO CMAKE_BUILD_TYPE, so it builds without NDEBUG -> its objects get
# _ITERATOR_DEBUG_LEVEL=2 while every other lib (Release/NDEBUG) is 0 -> lld-link /failifmismatch
# rejects re2.lib vs sentencepiece_train.lib. Inject Release + dynamic CRT (same as the other EPs).
$re2Cmake = Join-Path $SourceDir 'cmake\packages\re2\re2.cmake'
[void](Edit-SourceFile -Path $re2Cmake -Marker 'LiteRTLM-winfix re2-idl' -Description 're2.cmake: force Release/NDEBUG + dynamic CRT (fix _ITERATOR_DEBUG_LEVEL mismatch)' -Transform {
    param($c)
    $inject = "CMAKE_ARGS`n        -DCMAKE_BUILD_TYPE=" + '${CMAKE_BUILD_TYPE}' + "  # [LiteRTLM-winfix re2-idl] NDEBUG -> _ITERATOR_DEBUG_LEVEL=0 to match the rest`n        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    $c.Replace('CMAKE_ARGS', $inject)
})

# cmake/modules/fetch_content.cmake builds ANTLR's antlr4_static with WITH_STATIC_CRT defaulting ON,
# which forces that target's MSVC_RUNTIME_LIBRARY to the STATIC CRT (/MT -> MT_StaticRelease) while
# everything else uses CMake's default dynamic CRT (MultiThreadedDLL -> MD_DynamicRelease, emitted
# by the clang windows-msvc driver as -D_DLL -Xclang --dependent-lib=msvcrt). At the final
# litert_lm_main link, lld-link's /failifmismatch rejects the mixed RuntimeLibrary. Force
# WITH_STATIC_CRT OFF so antlr inherits the same dynamic CRT as the rest.
$fetchContent = Join-Path $SourceDir 'cmake\modules\fetch_content.cmake'
[void](Edit-SourceFile -Path $fetchContent -Marker 'LiteRTLM-winfix WITH_STATIC_CRT' -Description 'fetch_content.cmake: force antlr WITH_STATIC_CRT OFF (dynamic CRT to match)' -Transform {
    param($c)
    $c.Replace(
        'set(ANTLR_BUILD_STATIC ON)',
        'set(ANTLR_BUILD_STATIC ON)
  set(WITH_STATIC_CRT OFF CACHE BOOL "" FORCE)  # [LiteRTLM-winfix WITH_STATIC_CRT] match the dynamic CRT (/MD) of the rest; avoids lld-link /failifmismatch')
})

# cmake/packages/litert_lm/CMakeLists.txt assembles litert_lm_main's link spec
# (LITERTLM_UNIFIED_LINK_SPEC) with a branch on CMAKE_CXX_COMPILER_ID: the "Clang|GNU" branch emits
# GNU-ld flags (-Wl,--whole-archive / --start-group / --allow-multiple-definition) and a separate
# elseif(MSVC) branch emits the lld-link equivalents (/WHOLEARCHIVE, /FORCE:MULTIPLE). We drive
# clang++ + lld-link on Windows, so the compiler-id is "Clang" -> the GNU branch is taken, but
# lld-link SILENTLY IGNORES --whole-archive/--start-group (it warns "ignoring unknown argument"),
# so abseil's circular deps + the force-included aggregate libs never resolve and litert_lm_main
# fails with undefined abseil (StrCat/log/flags/status) + minja + cpu_affinity_utils symbols. Route
# Windows to the MSVC branch regardless of compiler-id: drop WIN32 from the Clang|GNU branch and add
# it to the MSVC branch (anchored to the link-spec block so other MSVC logic is untouched).
$litertLmPkg = Join-Path $SourceDir 'cmake\packages\litert_lm\CMakeLists.txt'
[void](Edit-SourceFile -Path $litertLmPkg -Marker 'LiteRTLM-winfix link-spec' -Description 'litert_lm/CMakeLists.txt: route Windows clang++/lld-link to the MSVC /WHOLEARCHIVE link spec (-Wl, prefixed)' -Transform {
    param($c)
    $c = [regex]::Replace($c,
        'if\(CMAKE_CXX_COMPILER_ID MATCHES "Clang\|GNU"\)(\s*if\(APPLE\))',
        'if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU" AND NOT WIN32)  # [LiteRTLM-winfix link-spec] lld-link ignores GNU --whole-archive/--start-group; route Windows to the MSVC branch$1')
    $c = [regex]::Replace($c,
        'elseif\(MSVC\)(\s*#\s*Windows Linker)',
        'elseif(MSVC OR WIN32)$1')
    # The MSVC branch's flags are raw link.exe syntax (/FORCE:MULTIPLE, /WHOLEARCHIVE) added via
    # target_link_libraries. That works for the cl.exe driver, but we drive lld-link through clang++:
    # CMake/Ninja treat a leading-'/' link item as an INPUT FILE ("ninja: error: '/FORCE:MULTIPLE' ...
    # missing and no known rule to make it"). Prefix them with -Wl, so clang++ forwards them to
    # lld-link as linker flags instead (the GNU-branch items pass through precisely because they lead
    # with '-'). /WHOLEARCHIVE (no arg) force-includes every following archive, which is what resolves
    # the abseil circular deps + static registrars on Windows.
    $c = $c.Replace('set(_LITERTLM_LINK_MULTIDEF "/FORCE:MULTIPLE")', 'set(_LITERTLM_LINK_MULTIDEF "-Wl,/FORCE:MULTIPLE")')
    $c.Replace('set(_LITERTLM_LINK_WHOLE_START "/WHOLEARCHIVE")', 'set(_LITERTLM_LINK_WHOLE_START "-Wl,/WHOLEARCHIVE")')
})

# [LiteRTLM-winfix clean-link] Make ninja link litert_lm_main.exe cleanly IN ONE PASS (no post-ninja
# manual relink). Three independent defects converge at this one link, all fixed in the CMake target:
#   1. deprecated CRT globals (_timezone/_daylight/_tzname/_environ/_sys_errlist/_sys_nerr + POSIX and
#      __imp_ dllimport spellings) that the split UCRT does not export as data under this -nostdlib link
#      -> compile a CRT-compat shim that provides them (init from UCRT accessors) + /alternatename the
#      POSIX/__imp_ variants onto it.
#   2. flatbuffers::ClassicLocale::instance_ is compiled into no library (guarded by
#      FLATBUFFERS_LOCALE_INDEPENDENT, ON for consumers but OFF in flatbuffers' own util.cpp build)
#      -> compile flatbuffers util.cpp into litert_lm_main (auto-detects ON -> defines instance_).
#   3. protoc.lib + protobuf-lite.lib carry __imp_ (dllimport) abseil hash_internal::MixingHashState
#      (a protobuf-internal quirk; NOT an ABSL_CONSUME_DLL define). Neither is needed by the runtime exe
#      (it links full protobuf.lib) and they are transitively pulled by-path (sentencepiece), so they
#      cannot be dropped in CMake -> a PRE_LINK step empties both archives right before the link.
$cleanCml = Join-Path $SourceDir 'cmake\packages\litert_lm\CMakeLists.txt'
if ((Test-Path $cleanCml) -and ((Get-Content -Raw $cleanCml) -notmatch 'LiteRTLM-winfix clean-link')) {
    # (a) CRT-compat shim as a real compiled source alongside litert_lm_main.cc
    $crtCc = Join-Path $SourceDir 'runtime\engine\crtcompat.cc'
    Copy-Item (Join-Path $PSScriptRoot 'shims\crtcompat.cc') $crtCc -Force
    # (b) an empty object used to truncate the protobuf carriers to empty archives
    $emptyCc = Join-Path $SourceDir 'winfix_empty.cc'
    $emptyObj = Join-Path $SourceDir 'winfix_empty.obj'
    Set-Content -Path $emptyCc -Value '// [LiteRTLM-winfix] intentionally empty' -Encoding ASCII
    # Gate the compile: this obj feeds the CMake PRE_LINK llvm-ar neutralize below;
    # a missing obj would only surface there as an opaque archive error.
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
    # Single-quoted: ${CMAKE_BINARY_DIR} must reach the CMakeLists verbatim (CMake expands it, not PS).
    # No backtick here -- these are inserted via $-interpolation into the here-string below, and PS does
    # not re-expand a variable's contents, so a literal backtick would leak into the generated path.
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

# The abseil ExternalProject builds MSVC-named static libs on Windows (absl_<name>.lib), but
# cmake/packages/absl/absl_import_static_lib.cmake + absl_target_map.cmake hardcode GNU names
# (${ABSL_LIB_DIR}/libabsl_<name>.a) with no MSVC branch -- the clang++ compiler-id=Clang trap
# again. Those .a paths don't exist, so the outer build.ninja .a-stub sweep fills them with EMPTY
# archives; abseil then contributes ZERO objects and litert_lm_main fails with a flood of undefined
# absl:: symbols (lld-link caps the printed list at ~10, so it looks like only a handful). Rewrite
# libabsl_<name>.a -> absl_<name>.lib so the aggregate points at the real libs. (Verified via the
# LITERTLM_KEEP_BUILD_TREE link diag: rsp referenced libabsl_*.a, install/lib held absl_*.lib.)
foreach ($abslCmakeRel in @('cmake\packages\absl\absl_import_static_lib.cmake', 'cmake\packages\absl\absl_target_map.cmake')) {
    [void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir $abslCmakeRel) `
            -Pattern 'libabsl_([A-Za-z0-9_]+)\.a' -Replacement 'absl_$1.lib' -Guard 'libabsl_[A-Za-z0-9_]+\.a' `
            -Description "$abslCmakeRel : libabsl_*.a -> absl_*.lib (point at the real MSVC abseil libs)")
}

# Same MSVC-naming mismatch for protobuf: protobuf_external installs protobuf.lib / protobuf-lite.lib
# / etc. into ${PROTO_LIB_DIR}, but protobuf_target_map.cmake references ${PROTO_LIB_DIR}/lib<name>.a
# (GNU) -> those are empty .a stubs -> a flood of undefined google::protobuf:: symbols (Message,
# WireFormat, EpsCopyOutputStream, InternalMetadata::DoMergeFrom<UnknownFieldSet>). Verified via the
# nm diag: libprotobuf.a = 0KB, protobuf.lib = 11MB (has the symbols). Rewrite /lib<name>.a ->
# /<name>.lib. (protoc/upb/utf8_validity may not all exist as .lib; harmless -- unused ones stay
# empty stubs from the sweep and nothing references them.)
# Same rename via the shared Invoke-InlineRegexPatch (was a hand-rolled ReadAllText/Replace block;
# identical regex + guard, just routed through the helper the abseil/litert renames already use).
[void](Invoke-InlineRegexPatch -Path (Join-Path $SourceDir 'cmake\packages\protobuf\protobuf_target_map.cmake') `
        -Pattern '/lib([a-z0-9_-]+)\.a' -Replacement '/$1.lib' -Guard '/lib[a-z0-9_-]+\.a' `
        -Description 'protobuf_target_map.cmake : /lib*.a -> /*.lib (point at the real MSVC protobuf libs)')

# The Rust cxx-bridge libs are the same story: _cxxbridge_paths (generate_cxxbridge.cmake) references
# ${CMAKE_BINARY_DIR}/liblitert_lm_deps.a + liblitertlm_cxx_bridge.a, but rustc/clang-cl emit MSVC
# litert_lm_deps.lib + litertlm_cxx_bridge.lib -> the .a are empty stubs -> undefined
# rust::cxxbridge1::Box<MinijinjaTemplate>::drop (nm diag: defined in litert_lm_deps.lib/
# litertlm_cxx_bridge.lib). find_and_copy_cxxbridge.cmake runs POST_BUILD of litertlm_cxx_bridge (so
# both .lib exist) but only stages libcxxbridge1.a. Append staging of the other two under the GNU
# names the aggregate expects (byte-for-byte, so lld-link reads them despite the .a extension).
$findCopy = Get-ChildItem $SourceDir -Recurse -Filter 'find_and_copy_cxxbridge.cmake' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $findCopy) {
    Write-Warning 'find_and_copy_cxxbridge.cmake not found under the source tree -- rust cxx-bridge libs will NOT be staged as lib*.a (expect undefined rust::cxxbridge1 symbols at the litert_lm_main link)'
} elseif ((Get-Content -Raw $findCopy.FullName) -notmatch 'LiteRTLM-winfix rust-lib-stage') {
    Add-Content -LiteralPath $findCopy.FullName -Value (Get-Content -Raw (Join-Path $PSScriptRoot 'patches\litert-lm\rust-lib-stage.cmake'))
    Write-Host 'Patched find_and_copy_cxxbridge.cmake: stage rust litert_lm_deps.lib + litertlm_cxx_bridge.lib as lib*.a'
}

# protobuf's ExternalProject defaults to protobuf_MSVC_STATIC_RUNTIME=ON, so it builds protobuf*.lib
# with the STATIC CRT (/MT -> MT_StaticRelease). Now that those libs are actually linked (post
# rename), lld-link's /failifmismatch rejects them against the /MD (MD_DynamicRelease) rest at the
# litert_lm_main link. Force the dynamic CRT for protobuf to match everything else. protobuf.cmake is
# litert-lm's own ExternalProject definition (not the protobuf source), so patch it directly.
$protoCmake = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf.cmake'
[void](Edit-SourceFile -Path $protoCmake -Marker 'protobuf_MSVC_STATIC_RUNTIME' -Description 'protobuf.cmake: force protobuf dynamic CRT (protobuf_MSVC_STATIC_RUNTIME=OFF)' -Transform {
    param($pc)
    $pc.Replace(
        '-Dprotobuf_BUILD_TESTS=OFF',
        "-Dprotobuf_BUILD_TESTS=OFF`n        -Dprotobuf_MSVC_STATIC_RUNTIME=OFF`n        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL  # [LiteRTLM-winfix] dynamic CRT to match the rest (lld-link /failifmismatch)")
})

# runtime_util_logging is declared INTERFACE (header-only) but logging.cc defines non-inline
# SetMinLogSeverity(LogSeverity) -> undefined at the litert_lm_main link. Compile it as STATIC (its
# usage-requirements must reach logging.cc's own compile, so INTERFACE -> PUBLIC on the two follow-up
# calls, scoped to this target only).
$utilCmake = Join-Path $SourceDir 'runtime\util\CMakeLists.txt'
if ((Test-Path $utilCmake) -and ((Get-Content -Raw $utilCmake) -match 'add_litertlm_library\(runtime_util_logging INTERFACE\)')) {
    $uc = [System.IO.File]::ReadAllText($utilCmake)
    $uc = [regex]::Replace($uc, 'add_litertlm_library\(runtime_util_logging INTERFACE\)', "add_litertlm_library(runtime_util_logging STATIC`n  logging.cc`n)")
    $uc = [regex]::Replace($uc, '(target_include_directories\(runtime_util_logging\s+)INTERFACE', '${1}PUBLIC')
    $uc = [regex]::Replace($uc, '(target_link_libraries\(runtime_util_logging\s+)INTERFACE', '${1}PUBLIC')
    [System.IO.File]::WriteAllText($utilCmake, $uc)
    Write-Host 'Patched runtime/util/CMakeLists.txt: runtime_util_logging INTERFACE -> STATIC (compile logging.cc for SetMinLogSeverity)'
}

# The CMake llguidance_schema_utils STATIC target only lists llguidance_schema_utils.cc, but the
# Bazel target groups llg_fc_tool_calls.cc + llg_python_tool_calls.cc into it (they define
# CreateLarkGrammarFor{Fc,Python}ToolCalls). Add them so those symbols resolve.
$cdCmake = Join-Path $SourceDir 'runtime\components\constrained_decoding\CMakeLists.txt'
[void](Edit-SourceFile -Path $cdCmake -Marker 'llg_fc_tool_calls\.cc' -Description 'constrained_decoding/CMakeLists.txt: add llg_fc_tool_calls.cc + llg_python_tool_calls.cc to llguidance_schema_utils' -Transform {
    param($cd)
    [regex]::Replace($cd,
        '(add_litertlm_library\(runtime_components_constrained_decoding_llguidance_schema_utils STATIC\s+llguidance_schema_utils\.cc)',
        "`$1`n  llg_fc_tool_calls.cc`n  llg_python_tool_calls.cc")
})

# The litert core (32 libs), sentencepiece, and tflite ExternalProjects all build MSVC-named *.lib but
# their target maps hardcode GNU lib*.a -> all empty stubs -> undefined LiteRt*/litert::CompiledModel/
# tflite::DefaultErrorReporter/sentencepiece::util::Status (nm diag: real libs are litert_c_api.lib,
# litert_cc_api.lib, tensorflow-lite.lib 15.7MB, sentencepiece.lib). Same rename as abseil/protobuf:
# lib<name>.a -> <name>.lib. Applied to the whole file, but the regex only ever matches lib*.a paths.
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
if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) { $cmakeExtra += '-DUSE_CUDA=ON' }
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
# (The vcpkg include\* copy into the protobuf-external install tree was DELETED
# 2026-08-03: with vcpkg reduced to zlib-only it copied zlib headers into a
# protobuf include dir — vestigial since the protobuf-header days. The
# $protoInstallInclude dir pre-create that fed it was removed 2026-08-04.)

#endregion

#region Phase 7 | Ninja build + ExternalProject lib stubs
$litertBuildDir = Join-Path $buildDir 'litert_lm\build'
$llvmAr = (Get-Command llvm-ar.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source

Write-Host 'Running ExternalProject steps 1-4 (mkdir/download/update/patch)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-mkdir litert_lm/stamps/litert_lm-download litert_lm/stamps/litert_lm-update litert_lm/stamps/litert_lm-patch 2>&1
# Warning (not throw) is safe ONLY because the configure gate right below is a
# hard throw: ninja re-drives any failed earlier stamp when asked for
# litert_lm-configure, so a real mkdir/download/patch failure fails THERE.
if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: mkdir/download/update/patch step exited $LASTEXITCODE (the configure gate below will fail if this was real)" }

Write-Host 'Running ExternalProject step 5 (configure)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-configure 2>&1
if ($LASTEXITCODE -ne 0) {
    # Hard gate: a failed inner configure means NOTHING below can build; the old
    # inverted check here printed "configure OK" on failure and swallowed it.
    throw "inner litert_lm configure failed (exit $LASTEXITCODE)"
}

$buildNinjaFile = Join-Path $litertBuildDir 'build.ninja'
$stubCount = 0
$stubFailCount = 0
# The PATHS, not just the tally. A count alone is unactionable: when lld-link
# later dies with "could not open <path>", nothing connects that path back to
# this step (measured 2026-08-07: "5 lib stub(s) could not be created" with the
# five names only in Write-Verbose, i.e. invisible in a normal build log).
$stubFailedPaths = [System.Collections.Generic.List[string]]::new()
if (Test-Path $buildNinjaFile) {
    Get-Content $buildNinjaFile | ForEach-Object {
        [regex]::Matches($_, "[\x27""]?([^\x27""\s]+\.(?:a|lib))[\x27""]?") | ForEach-Object {
            $aRel = $_.Groups[1].Value
            # Stub ExternalProject INPUTS: any lib referenced WITH a directory component -- absolute
            # aggregate paths (abseil/protobuf/litert(32)/sentencepiece/tflite+ruy+xnnpack(40+)) AND
            # build-tree-relative ones like external/litert/.../vendors/qualcomm/qnn_saver_utils.lib
            # (vendor libs that have no ninja rule on Windows). A BARE filename with no separator is a
            # system/toolchain lib (kernel32.lib, z.lib) resolved via the LIB path -> skip it, unless
            # it is one of the known bare special-cases. Own ninja-built libs stubbed here are
            # harmless: their objects compile fresh in step 6 so ninja relinks over the stub.
            $hasDir = $aRel -match '[\\/]'
            $isAllowedBare = ($aRel -match '\.a$') -or ($aRel -match '(?:tokenizers_c|absl_[A-Za-z0-9_]+|protobuf(?:-lite)?|protoc|upb|utf8_validity|litert_[A-Za-z0-9_]+|sentencepiece(?:_train)?|tensorflow-lite|tflite_profiling)\.lib$')
            if (-not $hasDir -and -not $isAllowedBare) { return }
            $aPath = if ($aRel -match '^[a-zA-Z]:') { $aRel -replace '/', '\' } else { Join-Path $litertBuildDir $aRel }
            if (-not (Test-Path $aPath)) {
                $parent = Split-Path $aPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
                    try { $null = New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "stub parent dir best-effort skip: $_" }
                }
                # Native non-zero exit never raises a PS exception, so gate on the
                # exit code + produced file (the old try/catch could never fire).
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
        # Name them. Capped so a systemic failure cannot flood the log, but the
        # cap is stated so nobody mistakes the list for the whole story.
        $shown = @($stubFailedPaths | Select-Object -First 10)
        $suffix = if ($stubFailCount -gt $shown.Count) { " (+$($stubFailCount - $shown.Count) more)" } else { '' }
        Write-Warning ("$stubFailCount lib stub(s) could not be created -- lld-link may fail with 'could not open' on " +
            "these paths${suffix}:`n  " + ($shown -join "`n  "))
    }
}

Write-Host 'Running ExternalProject step 6 (build)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-build 2>&1
# Transient-failure retries, incremental: 32 parallel clang processes opening the
# same clang-bundled header can storm into Windows ACCESS_DENIED ('cannot open
# file ...mwaitxintrin.h: permission denied' -- 2026-08-03, file + ACLs verified
# healthy afterwards). ninja redoes ONLY failed TUs, so a calm -j8 retry costs
# minutes and self-heals lock storms; real compile errors fail all 3 passes and
# hit the litert_lm_main.exe hard gate below.
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
# --- litert_lm_main.exe: ninja links it cleanly in one pass -------------------------------------
# The [LiteRTLM-winfix clean-link] CMake patch (crtcompat shim + flatbuffers util.cpp sources, CRT
# /alternatename aliases, PRE_LINK protoc/protobuf-lite neutralize) makes the ExternalProject build
# above produce a fully-linked litert_lm_main.exe directly -- no manual relink. Stage the exe + its
# runtime DLLs so it runs standalone (the source tree is wiped below unless KEEP_BUILD_TREE is set).
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
    # v0.14.0+: the Gemma model constraint provider is upstream's prebuilt-only
    # component; when its import lib was linked (clean-link block), the exe imports
    # the DLL -- ship it (and any sibling prebuilt runtime DLLs) next to the exe.
    $prebuiltWin = Join-Path $SourceDir 'prebuilt\windows_x86_64'
    if (Test-Path $prebuiltWin) {
        foreach ($dll in @(Get-ChildItem $prebuiltWin -Filter '*.dll' -ErrorAction SilentlyContinue)) {
            Copy-Item $dll.FullName $binOut -Force
            Write-Host "staged prebuilt runtime DLL: $($dll.Name)"
        }
    }
    # v0.14.0+ runtime DLLs discovered via llvm-objdump -p on the linked exe
    # (smoke-run died 0xC0000135 without them): z.dll (vcpkg zlib is the dynamic
    # triplet; z.lib in winstublibs is its import lib) and kissfft-float.dll
    # (upstream fetches kissfft with KISS_FFT_SHARED). Both must sit next to the
    # exe; the kissfft copy MUST happen before Remove-SourceBuildTree.
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
    $redist = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT' -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($redist) { Copy-Item (Join-Path $redist.FullName '*.dll') $binOut -Force -ErrorAction SilentlyContinue }
    # vcruntime140_1.dll / msvcp140.dll are not in a bare Server Core System32; search the resolved MSVC
    # toolset (via Get-MsvcToolsRoot -- vswhere-based, ships them under bin\Hostx64\x64) rather than
    # recursing all of Program Files.
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
    # Co-locate any REAL imported DLL built inside the tree (kissfft-float.dll, z.dll, ...). api-ms-win-*
    # are UCRT API-set forwarders (virtual, loader-resolved to ucrtbase.dll -- never physical files) -> skip.
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
    # Smoke-RUN the exe, not just check it exists: a linked-but-non-functional binary is the
    # exact failure class the file-existence smoke test misses. Two runtime breakages to catch:
    #   (1) missing DLL -> 0xC0000135 / -1073741515
    #   (2) abseil flag ODR abort at static init (two copies of abseil linked -> 'minloglevel'
    #       registered twice) -> the exe launches but aborts on EVERY invocation.
    # Capture output (do NOT discard it) and classify; exit 1 is NOT automatically "benign usage".
    # Initialize BEFORE the classification: it is only assigned in the BROKEN branches, and the
    # healthy path must still leave it defined or the hard gate's read throws under Set-StrictMode.
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
    # Hard gate: a linked-but-non-functional exe must FAIL the build -- that is the whole point
    # of smoke-RUNNING it (file existence never caught the abseil ODR abort). Skip only under
    # LITERTLM_KEEP_BUILD_TREE so the link diagnostics below still run when debugging a break.
    if ($script:litertLmRuntimeBroken -and -not $env:LITERTLM_KEEP_BUILD_TREE) {
        throw "litert_lm_main.exe is non-functional at runtime (smoke-run flagged it BROKEN above). Set LITERTLM_KEEP_BUILD_TREE=1 to keep the build tree + dump link diagnostics."
    }
}
elseif ($env:LITERTLM_KEEP_BUILD_TREE) {
    # Debug escape hatch only: keep going so the link-diagnostics dump below can run.
    Write-Host "WARNING: ninja did not produce litert_lm_main.exe -- continuing under LITERTLM_KEEP_BUILD_TREE for diagnostics"
}
else {
    # Hard gate, same rationale as the smoke-run gate above: a media-litert image without
    # litert_lm_main.exe is silently degraded, and the merge/final stages would ship it.
    # (Bit us 2026-08-03: LiteRT-LM v0.14.0's broken CMake export failed configure, this
    # branch only WARNED, and the stage 'completed' without the binary.)
    throw "ninja did not produce litert_lm_main.exe (configure or link failed above). Set LITERTLM_KEEP_BUILD_TREE=1 to keep the tree + dump link diagnostics."
}
# ----------------------------------------------------------------------------------------------

Write-Host 'Installing...'
& cmake --install $buildDir --config Release 2>&1
if ($LASTEXITCODE -ne 0) {
    # Hard gate: a failed install means headers/libs are missing from
    # $litertLmInstallDir while the stage would otherwise report green. Under the
    # KEEP_BUILD_TREE debug escape hatch only warn, so the link diagnostics below
    # still run against the kept tree.
    if ($env:LITERTLM_KEEP_BUILD_TREE) {
        Write-Warning "cmake --install failed (exit $LASTEXITCODE) -- continuing under LITERTLM_KEEP_BUILD_TREE for diagnostics"
    } else {
        throw "cmake --install failed (exit $LASTEXITCODE) -- headers/libs missing from $litertLmInstallDir"
    }
}

if ($env:LITERTLM_KEEP_BUILD_TREE) {
    Write-Host 'LITERTLM_KEEP_BUILD_TREE set: dumping litert_lm_main link diagnostics (and KEEPING the tree)'
    & (Join-Path $PSScriptRoot 'debug-litertlm-link.ps1') -SourceDir $SourceDir
}
else { Remove-SourceBuildTree -Path $SourceDir }

#endregion

} finally {
    # Restore the process env snapshot taken in Phase 2 (stages run in-process;
    # a $null snapshot value removes the variable again).
    foreach ($envName in @($litertLmEnvSnapshot.Keys)) {
        [Environment]::SetEnvironmentVariable($envName, $litertLmEnvSnapshot[$envName])
    }
}

Write-Host '=== LiteRT-LM source build completed ==='
# Explicit success: without this, pwsh -File propagates the LAST native exit code.
# Bit us 2026-08-03: Remove-SourceBuildTree's rmdir left residue and exited 145
# (ERROR_DIR_NOT_EMPTY) AFTER a fully successful build + smoke-run, so the stage
# wrapper declared "build failed (exit 145)" on a green build. Every real failure
# above throws (EAP=Stop + explicit gates), so reaching this line IS success.
exit 0

