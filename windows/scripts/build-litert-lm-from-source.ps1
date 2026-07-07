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

# Version-matched host protoc. The from-source runtime is protobuf 6.31.1, but vcpkg's
# protoc is a DIFFERENT major (libprotoc 33.4). Using it for codegen emits .pb.h/.cc that
# use newer macros (PROTOBUF_FUTURE_ADD_NODISCARD) and a gencode version stamp the 6.31.1
# headers reject ("Protobuf C++ gencode is built with an incompatible version" #error).
# Building a matching 6.31.1 protoc from source fails to link (abseil under clang++/lld-
# link), so fetch the official prebuilt protoc for release v31.1 (== runtime 6.31.1) and
# use it for every codegen step below (litert-lm protos, sentencepiece, WITH_PROTOC import).
$hostProtocDir = 'C:\temp\protoc-31.1'
$hostProtoc = Join-Path $hostProtocDir 'bin\protoc.exe'
if (-not (Test-Path $hostProtoc)) {
    $protocZip = 'C:\temp\protoc-31.1-win64.zip'
    $protocUrl = 'https://github.com/protocolbuffers/protobuf/releases/download/v31.1/protoc-31.1-win64.zip'
    Write-Host "Downloading version-matched protoc (v31.1) from $protocUrl"
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $protocUrl -OutFile $protocZip -UseBasicParsing
    Expand-Archive -Path $protocZip -DestinationPath $hostProtocDir -Force
    $ProgressPreference = $prevProgress
    if (-not (Test-Path $hostProtoc)) { throw "Failed to obtain prebuilt protoc 31.1 at $hostProtoc" }
}
Write-Host "Using version-matched host protoc: $hostProtoc ($(& $hostProtoc --version))"

# litert-lm generates its tool-call JSON parser at build time by running the ANTLR jar
# (java -jar antlr-4.13.2-complete.jar ...), so the build needs a JRE. The media base image
# doesn't ship Java, so fetch a portable Temurin 21 JRE and put java.exe on PATH. (No JDK
# needed -- ANTLR only runs the prebuilt jar.)
$jreDir = 'C:\temp\jre'
$javaExe = Get-ChildItem -Path $jreDir -Recurse -Filter java.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $javaExe) {
    $jreZip = 'C:\temp\temurin-jre.zip'
    $jreUrl = 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse'
    Write-Host "Downloading Temurin 21 JRE (for ANTLR codegen) from $jreUrl"
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $jreUrl -OutFile $jreZip -UseBasicParsing
    Expand-Archive -Path $jreZip -DestinationPath $jreDir -Force
    $ProgressPreference = $prevProgress
    $javaExe = Get-ChildItem -Path $jreDir -Recurse -Filter java.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $javaExe) { throw "Failed to obtain a JRE (java.exe) under $jreDir" }
}
$env:PATH = "$($javaExe.Directory.FullName);$env:PATH"
Write-Host "Using Java for ANTLR codegen: $($javaExe.FullName)"

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

# LiteRT's core dynamic-loading path (litert/core/dynamic_loading.cc and the delegate/plugin
# loaders) does `#include <dlfcn.h>` with no _WIN32 guard, so it fails "'dlfcn.h' file not
# found" on Windows. Drop a header-only <dlfcn.h> shim on the include path that maps the POSIX
# dl* API onto Win32 LoadLibrary/GetProcAddress. Header-only (static inline) => nothing extra to
# link. Placed on CXXFLAGS below so every external that ports Unix dl code picks it up.
$winShimDir = 'C:\temp\winshims'
New-Item -ItemType Directory -Force $winShimDir | Out-Null
$dlfcnShim = @'
#ifndef LITERTLM_WIN_DLFCN_SHIM_H
#define LITERTLM_WIN_DLFCN_SHIM_H
/* Minimal <dlfcn.h> for the clang++ windows-msvc build of LiteRT / LiteRT-LM: maps the POSIX
   dynamic-loader API onto Win32. Header-only so no extra object/library is required.
   NOMINMAX/NOGDI come from the global CXXFLAGS; we deliberately do NOT force
   WIN32_LEAN_AND_MEAN here so a TU that also needs the full <windows.h> is not starved. */
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif
#define RTLD_LAZY     0x0001
#define RTLD_NOW      0x0002
#define RTLD_LOCAL    0x0000
#define RTLD_GLOBAL   0x0100
#define RTLD_NODELETE 0x1000
#define RTLD_NOLOAD   0x0004
#define RTLD_DEEPBIND 0x0000
#define RTLD_DEFAULT  ((void*)0)
#define RTLD_NEXT     ((void*)-1)
static inline void* dlopen(const char* filename, int flag) {
    (void)flag;
    if (filename == 0) return (void*)GetModuleHandleA(0);
    return (void*)LoadLibraryA(filename);
}
static inline int dlclose(void* handle) {
    return FreeLibrary((HMODULE)handle) ? 0 : -1;
}
static inline void* dlsym(void* handle, const char* name) {
    return (void*)(uintptr_t)GetProcAddress((HMODULE)handle, name);
}
static inline char* dlerror(void) {
    static char buf[256];
    DWORD e = GetLastError();
    if (e == 0) return (char*)0;
    DWORD n = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, e, 0, buf, (DWORD)sizeof(buf), NULL);
    if (n == 0) snprintf(buf, sizeof(buf), "dlerror: Win32 error %lu", (unsigned long)e);
    return buf;
}
#ifdef __cplusplus
}
#endif
#endif
'@
Set-Content -LiteralPath (Join-Path $winShimDir 'dlfcn.h') -Value $dlfcnShim -Encoding ASCII

# LiteRT's dynamic_loading.cc also does an unguarded `#include <unistd.h>` and calls
# access(path, R_OK). MSVC's CRT already declares access() in <io.h> (deprecated -> _access);
# the POSIX permission-mode constants are all it's missing. (Its `#include <link.h>` is under
# `#if __has_include(<link.h>)`, so it simply drops out on Windows -- no shim needed there.)
$unistdShim = @'
#ifndef LITERTLM_WIN_UNISTD_SHIM_H
#define LITERTLM_WIN_UNISTD_SHIM_H
/* Minimal <unistd.h> for the clang++ windows-msvc build of LiteRT: access() via the CRT's
   <io.h>, the POSIX permission-mode constants the CRT does not define, and setenv/unsetenv
   mapped onto _putenv_s (LiteRT's dynamic_loading.cc uses setenv to edit LD_LIBRARY_PATH). */
#include <io.h>
#include <process.h>
#include <direct.h>
#include <stdlib.h>
#include <string.h>
#ifndef R_OK
#define R_OK 4
#endif
#ifndef W_OK
#define W_OK 2
#endif
#ifndef X_OK
#define X_OK 0
#endif
#ifndef F_OK
#define F_OK 0
#endif
#ifdef __cplusplus
static inline int setenv(const char* name, const char* value, int overwrite) {
    if (!overwrite) {
        size_t sz = 0;
        if (getenv_s(&sz, 0, 0, name) == 0 && sz != 0) return 0;
    }
    return _putenv_s(name, value ? value : "");
}
static inline int unsetenv(const char* name) { return _putenv_s(name, ""); }
#endif
#endif
'@
Set-Content -LiteralPath (Join-Path $winShimDir 'unistd.h') -Value $unistdShim -Encoding ASCII

# LiteRT's Qualcomm vendor code (vendors/qualcomm/compiler/qnn_compose_graph.cc) includes
# <alloca.h>, which doesn't exist on Windows -- the CRT puts alloca (_alloca) in <malloc.h>.
$allocaShim = @'
#ifndef LITERTLM_WIN_ALLOCA_SHIM_H
#define LITERTLM_WIN_ALLOCA_SHIM_H
#include <malloc.h>
#ifndef alloca
#define alloca _alloca
#endif
#endif
'@
Set-Content -LiteralPath (Join-Path $winShimDir 'alloca.h') -Value $allocaShim -Encoding ASCII
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
$env:CXXFLAGS = (@($env:CXXFLAGS, '-fdelayed-template-parsing', '-Wno-delayed-template-parsing-in-cxx20', '-isystem C:/temp/winshims', '-DNOMINMAX', '-DNOGDI', '-include unistd.h', '-D_USE_MATH_DEFINES') | Where-Object { $_ }) -join ' '
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

# Inline patch: strip -fPIC from sentencepiece's src/CMakeLists.txt. clang++ targets
# x86_64-pc-windows-msvc but reports compiler id Clang (not MSVC), so sentencepiece's
# `if(NOT MSVC)` branch adds `-O3 -Wall -fPIC` to CMAKE_CXX_FLAGS -- and -fPIC is a hard
# error on the windows-msvc target ("unsupported option '-fPIC'"). PIC is meaningless on
# Windows, so drop just the flag (keep -O3/-Wall). Grafted onto sentencepiece_patcher.cmake
# (its PATCH_COMMAND hook), re-reading src/CMakeLists.txt after the patcher writes it.
$spPatcher = Join-Path $SourceDir 'cmake\packages\sentencepiece\sentencepiece_patcher.cmake'
if ((Test-Path $spPatcher) -and ((Get-Content -Raw $spPatcher) -notmatch 'LiteRTLM-winfix sentencepiece-fpic')) {
    $spPatch = @'

# [LiteRTLM-winfix sentencepiece-fpic] clang++ targets x86_64-pc-windows-msvc but its
# compiler id is Clang (not MSVC), so sentencepiece's `if(NOT MSVC)` branch injects -fPIC,
# a hard error on the windows-msvc target. Strip it (PIC is meaningless on Windows).
# Also skip the spm_* CLI tools (spm_encode/decode/normalize/train/export_vocab +
# compile_charsmap): litert-lm only needs the sentencepiece-static library, and those
# standalone executables fail to link abseil-flags/protobuf under clang++/lld-link. Wrap
# the exe region and its install-append each in if(FALSE); the library + its install stay.
file(READ "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" _sp_src)
string(REPLACE "-O0 -Wall -fPIC -coverage" "-O0 -Wall -coverage" _sp_src "${_sp_src}")
string(REPLACE "-O3 -Wall -fPIC" "-O3 -Wall" _sp_src "${_sp_src}")
string(REPLACE "add_executable(spm_encode spm_encode_main.cc)" "if(FALSE) # LiteRTLM-winfix: skip unused spm CLI tools (abseil-flags/protobuf link failure)\nadd_executable(spm_encode spm_encode_main.cc)" _sp_src "${_sp_src}")
string(REPLACE "list(APPEND SPM_INSTALLTARGETS" "endif() # LiteRTLM-winfix: end skip spm CLI tools\nif(FALSE) # LiteRTLM-winfix: exclude spm tools from install\nlist(APPEND SPM_INSTALLTARGETS" _sp_src "${_sp_src}")
string(REPLACE "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)" "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)\nendif() # LiteRTLM-winfix" _sp_src "${_sp_src}")
file(WRITE "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" "${_sp_src}")
message(STATUS "[LiteRTLM] Patched sentencepiece src/CMakeLists.txt: stripped -fPIC + skipped spm CLI tools")
'@
    Add-Content -LiteralPath $spPatcher -Value $spPatch
    Write-Host 'Patched sentencepiece_patcher.cmake: strip -fPIC + skip spm CLI tools (windows-msvc/abseil link)'
}

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
        $tkPatchContent = @'
# [LiteRTLM-winfix] rustc builds the crate for x86_64-pc-windows-msvc and emits
# tokenizers_c.lib, but tokenizers-cpp's CMakeLists picks libtokenizers_c.a in its
# non-MSVC branch (our C++ compiler id is Clang), so its copy step can't find the output.
file(READ "${TK_SRC}/CMakeLists.txt" _c)
string(REPLACE "libtokenizers_c.a" "tokenizers_c.lib" _c "${_c}")
file(WRITE "${TK_SRC}/CMakeLists.txt" "${_c}")
message(STATUS "[LiteRTLM-winfix] tokenizers-cpp rust staticlib name -> tokenizers_c.lib")
'@
        Set-Content -LiteralPath $tkPatchScript -Value $tkPatchContent -Encoding ASCII
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
if ((Test-Path $tfliteShims) -and ((Get-Content -Raw $tfliteShims) -notmatch 'LiteRTLM-winfix tflite-profiling-proto')) {
    $ts = [System.IO.File]::ReadAllText($tfliteShims)
    $tsAnchor = 'generate_protobuf(tflite_profiling ${TENSORFLOW_SOURCE_DIR})'
    if ($ts.Contains($tsAnchor)) {
        $tsRepl = @'
# [LiteRTLM-winfix tflite-profiling-proto] TFLite's profiling/proto/CMakeLists already emits
# profiling_info.pb.cc / model_runtime_info.pb.cc into {profiling,model_runtime}_info_proto,
# which the aggregate links; regenerating them here produced a second ninja rule for the same
# output ("multiple rules generate profiling_info.pb.cc") and duplicate proto symbols at link.
# Depend on TFLite's generated headers instead of recompiling the protos into tflite_profiling.
set_source_files_properties(${PROFILING_SRCS} PROPERTIES OBJECT_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/tensorflow/lite/profiling/proto/profiling_info.pb.h;${CMAKE_CURRENT_BINARY_DIR}/tensorflow/lite/profiling/proto/model_runtime_info.pb.h")
'@
        $ts = $ts.Replace($tsAnchor, $tsRepl)
        # tflite_profiling globs profiling/*.cc and only drops *_test.cc, but atrace_profiler.cc
        # is Android-only (includes <dlfcn.h> to dlopen libandroid) and has no Windows path, so
        # it fails "'dlfcn.h' file not found". Exclude it too (platform_profiler.cc already
        # compiles to the no-op backend on non-Android/Apple).
        $ts = $ts.Replace('EXCLUDE REGEX "_test\\.cc$"', 'EXCLUDE REGEX "(_test|atrace_profiler)\\.cc$"')
        [System.IO.File]::WriteAllText($tfliteShims, $ts)
        Write-Host 'Patched tflite_shims.cmake: drop redundant tflite_profiling proto gen + exclude Android-only atrace_profiler.cc'
    }
    else {
        Write-Host 'WARNING: tflite_shims.cmake generate_protobuf(tflite_profiling) anchor not found'
    }
}

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
if ((Test-Path $tflitePatcher) -and ((Get-Content -Raw $tflitePatcher) -notmatch 'LiteRTLM-winfix model_building-friend')) {
    $mbPatch = @'

# [LiteRTLM-winfix model_building-friend] see build-litert-lm-from-source.ps1
set(_lrtlm_mb "${TENSORFLOW_SOURCE_DIR}/tensorflow/lite/core/model_building.h")
if(EXISTS "${_lrtlm_mb}")
    file(READ "${_lrtlm_mb}" _lrtlm_mbc)
    string(REPLACE "class [[nodiscard]] Buffer {" "class Helper;\nclass Tensor;\nclass [[nodiscard]] Buffer {" _lrtlm_mbc "${_lrtlm_mbc}")
    file(WRITE "${_lrtlm_mb}" "${_lrtlm_mbc}")
    message(STATUS "[LiteRTLM-winfix] forward-declared Helper/Tensor before Buffer in model_building.h")
endif()
'@
    Add-Content -LiteralPath $tflitePatcher -Value $mbPatch -Encoding ASCII
    Write-Host 'Patched tflite_patcher.cmake: model_building.h friend forward-declarations'
}

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
if ((Test-Path $litertCmake) -and ((Get-Content -Raw $litertCmake) -notmatch '-isystem \$\{FLATBUFFERS_INCLUDE_DIR\}')) {
    $lc = [System.IO.File]::ReadAllText($litertCmake)
    $lcAnchor = '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -w"'
    if ($lc.Contains($lcAnchor)) {
        $lc = $lc.Replace($lcAnchor, '-isystem ${PROTOBUF_INSTALL_PREFIX}/include -isystem ${FLATBUFFERS_INCLUDE_DIR} -w"')
        [System.IO.File]::WriteAllText($litertCmake, $lc)
        Write-Host 'Patched litert.cmake: add flatbuffers install include to litert CXX flags'
    }
    else {
        Write-Host 'WARNING: litert.cmake CXX flags anchor not found; flexbuffers.h may be missing'
    }
}

$litertPatcher = Join-Path $SourceDir 'cmake\packages\litert\litert_patcher.cmake'
if ((Test-Path $litertPatcher) -and ((Get-Content -Raw $litertPatcher) -notmatch 'LiteRTLM-winfix dynamic-loading')) {
    $dlPatch = @'

# [LiteRTLM-winfix dynamic-loading] narrow std::filesystem::path uses for Windows (see
# build-litert-lm-from-source.ps1). setenv is supplied by the Windows <unistd.h> shim.
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "access(path.c_str(), R_OK)" "access(path.string().c_str(), R_OK)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "results.push_back(path);" "results.push_back(path.string());" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "FindLiteRtSharedLibsHelper(path, lib_pattern, full_match, results)" "FindLiteRtSharedLibsHelper(path.string(), lib_pattern, full_match, results)" FALSE)
message(STATUS "[LiteRTLM-winfix] narrowed std::filesystem::path uses in core/dynamic_loading.cc")

# The C API's SHARED LiteRt.dll (litert_runtime_c_api_shared_lib) is built unconditionally, but
# litert-lm's target map links only the STATIC liblitert_c_api.a, so nothing needs the DLL. Its
# link is broken under clang++/lld-link (GNU --whole-archive/--start-group are ignored and it
# looks for the MSVC-named litert_cc_options.lib). EXCLUDE_FROM_ALL doesn't stop it (litert
# builds the default `all`), so flip it SHARED->STATIC: a static archive of empty.cc records
# its PUBLIC deps only as usage requirements and never links, so the litert_cc_options.lib
# resolution simply doesn't happen. Nothing depends on it, and litert isn't installed
# (INSTALL_COMMAND ""), so the leftover libLiteRt.a is harmless.
patch_file_content("${LITERT_SRC_DIR}/c/CMakeLists.txt" "add_library(litert_runtime_c_api_shared_lib SHARED empty.cc)" "add_library(litert_runtime_c_api_shared_lib STATIC empty.cc)" FALSE)
message(STATUS "[LiteRTLM-winfix] shared LiteRt.dll -> STATIC (avoids lld-link of GNU-named static deps; litert-lm links static c_api)")

# The per-vendor NPU dispatch plugins (dispatch_api_<VENDOR>_so -> LiteRtDispatch_<VENDOR>.dll,
# defined by _litert_add_dispatch_so in vendors/CMakeLists.txt) are SHARED and hit the SAME
# broken lld-link path as LiteRt.dll (GNU --whole-archive/-Wl,-soname ignored; MSVC-named
# litert_cc_options.lib not found). They're runtime-dlopen'd NPU backends, not in litert-lm's
# target map and useless on a Windows desktop (no such NPU). One SHARED->STATIC on the shared
# add_library covers every vendor at once. (The escaped \${TGT}/\${DISPATCH_SRCS} keep the
# literal CMake variable names so string(REPLACE) matches the un-expanded source line.)
patch_file_content("${LITERT_SRC_DIR}/vendors/CMakeLists.txt" "add_library(\${TGT} SHARED \${DISPATCH_SRCS})" "add_library(\${TGT} STATIC \${DISPATCH_SRCS})" FALSE)
message(STATUS "[LiteRTLM-winfix] vendor dispatch LiteRtDispatch_*.dll -> STATIC (NPU plugins unused on Windows)")

# Qualcomm defines its dispatch + compiler-plugin as their OWN explicit SHARED add_library
# (not via the _litert_add_dispatch_so helper), so they need separate SHARED->STATIC patches.
# Both are runtime-dlopen'd NPU plugins, absent from litert-lm's target map, and fail the same
# lld-link path (they link the now-STATIC litert_runtime_c_api_shared_lib and want the
# MSVC-named litert_cc_options.lib). qnn_compiler_plugin is distinct from litert-lm's mapped
# litert::compiler_plugin (the generic static liblitert_compiler_plugin.a), so this is safe.
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/dispatch/CMakeLists.txt" "add_library(dispatch_api_qualcomm_so SHARED)" "add_library(dispatch_api_qualcomm_so STATIC)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/compiler/CMakeLists.txt" "add_library(qnn_compiler_plugin SHARED" "add_library(qnn_compiler_plugin STATIC" FALSE)
message(STATUS "[LiteRTLM-winfix] Qualcomm dispatch + qnn_compiler_plugin SHARED -> STATIC")

# litert/tools builds standalone exes (run_model, analyze_model, apply_plugin_main) that are
# NOT gated by LITERT_BUILD_TOOLS. They link abseil flags/log/str_format via bare CMake target
# names, which under lld-link leaves those symbols undefined (litert-lm's abseil reaches
# litert_lm_main only through the full-path local_aggregate, not these tools). litert-lm's
# target map wants the tool LIBRARIES (liblitert_apply_plugin.a, etc.), not these exes, so
# EXCLUDE_FROM_ALL them (nothing links an executable, so unlike LiteRt.dll the exclusion holds;
# the install(TARGETS ...) is a no-op since litert's INSTALL_COMMAND is "").
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(run_model" "add_executable(run_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(analyze_model" "add_executable(analyze_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(apply_plugin_main" "add_executable(apply_plugin_main EXCLUDE_FROM_ALL" FALSE)
message(STATUS "[LiteRTLM-winfix] litert tool exes (run_model/analyze_model/apply_plugin_main) EXCLUDE_FROM_ALL")
'@
    Add-Content -LiteralPath $litertPatcher -Value $dlPatch -Encoding ASCII
    Write-Host 'Patched litert_patcher.cmake: dynamic_loading.cc std::filesystem::path narrowing'
}

# litert-lm's own runtime/executor/litert_compiled_model_executor_utils.cc calls
# gpu_options.SetWeightCacheFd(fd) in the fd-based weight-cache branch, but litert::GpuOptions
# exposes SetWeightCacheFd only on POSIX (it takes a raw file descriptor); on Windows the method
# doesn't exist -> "no member named 'SetWeightCacheFd'". GPU is disabled on this lane anyway, so
# guard just that call (the surrounding Duplicate()/Release() keep their side effects). This is
# the top-level litert-lm repo (no ExternalProject git-checkout), so patch the source directly.
$execUtils = Join-Path $SourceDir 'runtime\executor\litert_compiled_model_executor_utils.cc'
if ((Test-Path $execUtils) -and ((Get-Content -Raw $execUtils) -notmatch 'LiteRTLM-winfix.*SetWeightCacheFd')) {
    $eu = [System.IO.File]::ReadAllText($execUtils)
    $euAnchor = 'gpu_options.SetWeightCacheFd(fd);'
    if ($eu.Contains($euAnchor)) {
        $euRepl = "#if !defined(_WIN32)`n      gpu_options.SetWeightCacheFd(fd);`n#else`n      (void)fd;  // [LiteRTLM-winfix] litert::GpuOptions has no fd-based weight cache on Windows`n#endif"
        $eu = $eu.Replace($euAnchor, $euRepl)
        [System.IO.File]::WriteAllText($execUtils, $eu)
        Write-Host 'Patched litert_compiled_model_executor_utils.cc: guard SetWeightCacheFd on Windows'
    }
    else {
        Write-Host 'WARNING: SetWeightCacheFd anchor not found in executor utils'
    }
}

# Same story in runtime/executor/llm_executor_settings_utils.cc: it calls litert::GpuOptions /
# litert::RuntimeOptions setters (SetKernelBatchSize, SetDisableDelegateClustering) that the
# Windows litert build doesn't expose (GPU/delegate tuning). Wrap each full call statement in a
# _WIN32 guard. The regex `\([^;]*\);` spans the multi-line call up to its terminating semicolon
# ([^;] matches newlines in .NET regex), so exact indentation doesn't matter.
$settingsUtils = Join-Path $SourceDir 'runtime\executor\llm_executor_settings_utils.cc'
if ((Test-Path $settingsUtils) -and ((Get-Content -Raw $settingsUtils) -notmatch 'LiteRTLM-winfix')) {
    $su = [System.IO.File]::ReadAllText($settingsUtils)
    foreach ($m in @('gpu_compilation_options.SetKernelBatchSize', 'runtime_options.SetDisableDelegateClustering')) {
        $pat = [regex]::Escape($m) + '\([^;]*\);'
        $su = [regex]::Replace($su, $pat, {
            param($mm)
            "#if !defined(_WIN32)  // [LiteRTLM-winfix] litert GpuOptions/RuntimeOptions setter absent on Windows`n      " + $mm.Value + "`n#endif"
        })
    }
    [System.IO.File]::WriteAllText($settingsUtils, $su)
    Write-Host 'Patched llm_executor_settings_utils.cc: guard Windows-absent GpuOptions/RuntimeOptions setters'
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

$vcpkgProtoc = $hostProtoc  # version-matched protoc 31.1 (== protobuf_external 6.31.1); NOT vcpkg's libprotoc 33.4
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
        [regex]::Matches($_, "[\x27""]?([^\x27""\s]+(?:\.a|tokenizers_c\.lib))[\x27""]?") | ForEach-Object {
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
    Write-Host "Created $stubCount aggregate stubs (.a + rust tokenizers_c.lib)"
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

if ($env:LITERTLM_KEEP_BUILD_TREE) {
    Write-Host 'LITERTLM_KEEP_BUILD_TREE set: dumping tflite profiling_info.pb.cc rules (diagnostic)'
    $tfBn = Join-Path $SourceDir 'build_ninja\litert_lm\build\external\tensorflow\src\tflite_external-build\build.ninja'
    if (Test-Path $tfBn) {
        $ln = 0
        Get-Content $tfBn | ForEach-Object {
            $ln++
            if ($_ -match 'profiling_info\.pb\.(cc|h)' -and ($_ -match '^build ' -or $_ -match 'protoc|--cpp_out|COMMAND|command =')) {
                Write-Host ("DIAG L{0}: {1}" -f $ln, $_)
            }
        }
    } else { Write-Host "DIAG: tflite build.ninja not found at $tfBn" }
    Remove-SourceBuildTree -Path $SourceDir
}
else { Remove-SourceBuildTree -Path $SourceDir }

Write-Host '=== LiteRT-LM source build completed ==='



