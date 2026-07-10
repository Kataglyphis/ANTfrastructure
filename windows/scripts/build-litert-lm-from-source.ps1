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
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.13.1'
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT-LM' }

Write-Host 'Setting up git-lfs...'
# Shield native git under the Dockerfile's PS 5.1 SHELL: `git lfs` writes progress to stderr, which
# under $ErrorActionPreference='Stop' becomes a terminating NativeCommandError even with `2>&1` (5.1
# merges the stream too late to prevent it). Route through cmd.exe so the stderr is consumed there and
# never reaches PowerShell's pipeline -- same shield as Invoke-GitClone and build-ffmpeg's git clone.
& cmd /c 'git lfs install --skip-repo 2>&1' | Out-Null
& cmd /c "cd /d `"$SourceDir`" && git lfs pull 2>&1" | Out-Null

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
    Invoke-DownloadWithRetry -Url $protocUrl -DestinationPath $protocZip -Description 'version-matched protoc v31.1'
    Expand-Archive -Path $protocZip -DestinationPath $hostProtocDir -Force
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
    Invoke-DownloadWithRetry -Url $jreUrl -DestinationPath $jreZip -Description 'Temurin 21 JRE'
    Expand-Archive -Path $jreZip -DestinationPath $jreDir -Force
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
[void](Edit-SourceFile -Path $runtimeProtoCmake -Description 'runtime/proto/CMakeLists.txt before configure' -Transform {
    param($c)
    $c = $c -replace 'protobuf_generate\([^)]*\)', '# protobuf_generate disabled (vcpkg)'
    $c -replace 'find_package\(Protobuf', 'find_package(Protobuf QUIET'
})

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

# [LiteRTLM-winfix] sentencepiece's src/error.cc defines ABSL_FLAG(int32, minloglevel, ...)
# under _USE_EXTERNAL_ABSL as a "naive workaround" assuming external abseil does not provide
# it. But litert-lm links abseil's FULL absl_log_flags.lib, which DOES define minloglevel, so
# the two collide: duplicate FLAGS_minloglevel / FLAGS_nominloglevel are both registered at
# static init and abseil aborts EVERY invocation ("Inconsistency between flag object and
# registration for flag 'minloglevel'"). /FORCE:MULTIPLE hides it at link time, so it only
# surfaces at runtime. Drop sentencepiece's duplicate ([^;]* spans the two-line statement,
# eol-agnostic) so abseil's definition stands alone; litert_lm_main still links absl_log_flags
# so the symbol resolves. This is THE fix for the litert_lm_main.exe startup ODR abort.
file(READ "${SENTENCE_SRC_DIR}/src/error.cc" _sp_err)
string(REGEX REPLACE "ABSL_FLAG\\(int32, minloglevel, 0,[^;]*;" "/* [LiteRTLM-winfix] dropped duplicate ABSL_FLAG(minloglevel); abseil absl_log_flags provides it (ODR fix) */" _sp_err "${_sp_err}")
file(WRITE "${SENTENCE_SRC_DIR}/src/error.cc" "${_sp_err}")
message(STATUS "[LiteRTLM] Patched sentencepiece error.cc: dropped duplicate ABSL_FLAG(minloglevel) -> fixes abseil flag ODR abort")
'@
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

# runtime/executor/llm_litert_npu_compiled_model_executor.cc reads per-tensor quantization via
# litert::SimpleTensor::HasQuantization()/PerTensorQuantization(), which the Windows litert build
# doesn't expose. This is the NPU executor (dead on Windows -- no NPU hardware, NPU disabled), so
# guard the two quantization blocks with _WIN32; the surrounding params keep their defaults (which
# is exactly what the non-quantized/else path already does). Regex spans each block via [\s\S]*?
# (non-greedy) to its distinctive terminating line, so exact indentation doesn't matter.
$npuExec = Join-Path $SourceDir 'runtime\executor\llm_litert_npu_compiled_model_executor.cc'
if ((Test-Path $npuExec) -and ((Get-Content -Raw $npuExec) -notmatch 'LiteRTLM-winfix')) {
    $ne = [System.IO.File]::ReadAllText($npuExec)
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
    [System.IO.File]::WriteAllText($npuExec, $ne)
    Write-Host 'Patched llm_litert_npu_compiled_model_executor.cc: guard Windows-absent SimpleTensor quantization API'
}

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
$pragmaBlock = @'
// [LiteRTLM-winfix rust-syslibs] force-link rust-std's windows-msvc system libs via /DEFAULTLIB
// directives baked into this .obj (the CMake link-flag routes silently dropped them). Same mechanism
// clang uses for msvcrt via --dependent-lib.
#if defined(_WIN32)
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "dbghelp.lib")
// CRT compat: oldnames maps POSIX names (cprintf/timezone/tzname/sys_errlist -> _cprintf/_timezone
// /...); legacy_stdio_definitions supplies the deprecated global data (_timezone/_tzname/_sys_errlist)
// that the split UCRT no longer auto-provides under --dependent-lib=msvcrt alone.
#pragma comment(lib, "oldnames.lib")
#pragma comment(lib, "legacy_stdio_definitions.lib")
// Complete the dynamic-CRT set: --dependent-lib=msvcrt pulls only the VCRuntime forwarder; the
// deprecated UCRT global data (_timezone/_daylight/_tzname/_environ/_sys_errlist/_sys_nerr, pulled in
// by rust-std/C deps) lives in ucrt.lib + vcruntime.lib, which /MD would normally auto-link.
#pragma comment(lib, "ucrt.lib")
#pragma comment(lib, "vcruntime.lib")
#endif

'@
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
    $crtSrc = @'
// [LiteRTLM-winfix] CRT compat shim: litert-lm objects reference deprecated CRT globals
// (_timezone/_daylight/_tzname/_environ/_sys_errlist/_sys_nerr + POSIX and __imp_ dllimport forms)
// that the split UCRT does not export as data under litert_lm_main's -nostdlib link. Provide real
// storage initialised from the UCRT accessors + the __imp_ pointer forms the dllimport references
// dereference. Accessors are declared by hand (NOT via <time.h>/<stdlib.h>) because those headers
// declare the very globals we define here as dllimport, which conflicts ("illegal initializer").
typedef unsigned long long crtcompat_size_t;
extern "C" {
int  _get_timezone(long*);
int  _get_daylight(int*);
int  _get_tzname(crtcompat_size_t*, char*, crtcompat_size_t, int);
void _tzset(void);
char*** __p__environ(void);
long   _timezone = 0;
int    _daylight = 0;
char   _crtcompat_tzn0[128] = "";
char   _crtcompat_tzn1[128] = "";
char*  _tzname[2] = { _crtcompat_tzn0, _crtcompat_tzn1 };
int    _sys_nerr = 0;
char*  _sys_errlist[1] = { (char*)"" };
char** _environ = 0;
void* __imp__timezone    = &_timezone;
void* __imp__daylight    = &_daylight;
void* __imp__tzname      = &_tzname;
void* __imp__sys_nerr    = &_sys_nerr;
void* __imp__sys_errlist = &_sys_errlist;
void* __imp__environ     = &_environ;
}
namespace {
struct CrtCompatInit {
    CrtCompatInit() {
        _tzset();
        long tz = 0;  if (_get_timezone(&tz) == 0) _timezone = tz;
        int  dl = 0;  if (_get_daylight(&dl) == 0) _daylight = dl;
        crtcompat_size_t n = 0;
        _get_tzname(&n, _crtcompat_tzn0, sizeof(_crtcompat_tzn0), 0);
        _get_tzname(&n, _crtcompat_tzn1, sizeof(_crtcompat_tzn1), 1);
        _environ = __p__environ() ? *__p__environ() : 0;
    }
};
CrtCompatInit _crt_compat_init;
}
'@
    Set-Content -Path $crtCc -Value $crtSrc -Encoding ASCII
    # (b) an empty object used to truncate the protobuf carriers to empty archives
    $emptyCc = Join-Path $SourceDir 'winfix_empty.cc'
    $emptyObj = Join-Path $SourceDir 'winfix_empty.obj'
    Set-Content -Path $emptyCc -Value '// [LiteRTLM-winfix] intentionally empty' -Encoding ASCII
    & (Get-Command clang++.exe).Source -c $emptyCc -o $emptyObj 2>&1 | Out-Null
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
if ($findCopy -and ((Get-Content -Raw $findCopy.FullName) -notmatch 'LiteRTLM-winfix rust-lib-stage')) {
    Add-Content -LiteralPath $findCopy.FullName -Value @'

# [LiteRTLM-winfix rust-lib-stage] stage the MSVC-named rust staticlib + cxxbridge C++ glue under the
# GNU lib*.a names that _cxxbridge_paths references (rustc/clang-cl emit <name>.lib on windows-msvc).
foreach(_winfix_pair "litert_lm_deps.lib|liblitert_lm_deps.a" "litertlm_cxx_bridge.lib|liblitertlm_cxx_bridge.a")
    string(REPLACE "|" ";" _winfix_kv "${_winfix_pair}")
    list(GET _winfix_kv 0 _winfix_src_name)
    list(GET _winfix_kv 1 _winfix_dst_name)
    file(GLOB_RECURSE _winfix_found "${CMAKE_BINARY_DIR}/${_winfix_src_name}")
    if(_winfix_found)
        list(GET _winfix_found 0 _winfix_src)
        file(COPY_FILE "${_winfix_src}" "${CMAKE_BINARY_DIR}/${_winfix_dst_name}")
        message(STATUS "[LiteRTLM-winfix] staged ${_winfix_src} -> ${_winfix_dst_name}")
    else()
        message(WARNING "[LiteRTLM-winfix] rust lib ${_winfix_src_name} not found under ${CMAKE_BINARY_DIR}")
    endif()
endforeach()
'@
    Write-Host 'Patched find_and_copy_cxxbridge.cmake: stage rust litert_lm_deps.lib + litertlm_cxx_bridge.lib as lib*.a'
}

# protobuf's ExternalProject defaults to protobuf_MSVC_STATIC_RUNTIME=ON, so it builds protobuf*.lib
# with the STATIC CRT (/MT -> MT_StaticRelease). Now that those libs are actually linked (post
# rename), lld-link's /failifmismatch rejects them against the /MD (MD_DynamicRelease) rest at the
# litert_lm_main link. Force the dynamic CRT for protobuf to match everything else. protobuf.cmake is
# litert-lm's own ExternalProject definition (not the protobuf source), so patch it directly.
$protoCmake = Join-Path $SourceDir 'cmake\packages\protobuf\protobuf.cmake'
if ((Test-Path $protoCmake) -and ((Get-Content -Raw $protoCmake) -notmatch 'protobuf_MSVC_STATIC_RUNTIME')) {
    $pc = [System.IO.File]::ReadAllText($protoCmake)
    $pc = $pc.Replace(
        '-Dprotobuf_BUILD_TESTS=OFF',
        "-Dprotobuf_BUILD_TESTS=OFF`n        -Dprotobuf_MSVC_STATIC_RUNTIME=OFF`n        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL  # [LiteRTLM-winfix] dynamic CRT to match the rest (lld-link /failifmismatch)")
    [System.IO.File]::WriteAllText($protoCmake, $pc)
    Write-Host 'Patched protobuf.cmake: force protobuf dynamic CRT (protobuf_MSVC_STATIC_RUNTIME=OFF)'
}

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
if ((Test-Path $cdCmake) -and ((Get-Content -Raw $cdCmake) -notmatch 'llg_fc_tool_calls\.cc')) {
    $cd = [System.IO.File]::ReadAllText($cdCmake)
    $cd = [regex]::Replace($cd,
        '(add_litertlm_library\(runtime_components_constrained_decoding_llguidance_schema_utils STATIC\s+llguidance_schema_utils\.cc)',
        "`$1`n  llg_fc_tool_calls.cc`n  llg_python_tool_calls.cc")
    [System.IO.File]::WriteAllText($cdCmake, $cd)
    Write-Host 'Patched constrained_decoding/CMakeLists.txt: added llg_fc_tool_calls.cc + llg_python_tool_calls.cc to llguidance_schema_utils'
}

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

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT-LM CMake configure failed' }

# $hostProtoc below is the version-matched protoc 31.1 (== protobuf_external 6.31.1); NOT vcpkg's libprotoc 33.4
$protoDir = Join-Path $SourceDir 'runtime\proto'
foreach ($outSubDir in @('proto', 'protobuf')) {
    $protoOutDir = Join-Path $SourceDir "build_ninja\litert_lm\build\runtime\$outSubDir"
    New-Item -Path $protoOutDir -ItemType Directory -Force | Out-Null
    if ((Test-Path $hostProtoc) -and (Test-Path $protoDir)) {
        Get-ChildItem -Path $protoDir -Filter '*.proto' | ForEach-Object {
            & $hostProtoc --proto_path="$SourceDir" --cpp_out="$protoOutDir" $_.FullName 2>&1
        }
        Write-Host "Generated proto files to $protoOutDir"
    }
}
$protoInstallBin = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\bin'
New-Item -Path $protoInstallBin -ItemType Directory -Force | Out-Null
Copy-Item $hostProtoc (Join-Path $protoInstallBin 'protoc.exe') -Force
Copy-Item $hostProtoc (Join-Path $protoInstallBin 'protoc') -Force
$vcpkgInclude = Join-Path $vcpkgDir 'installed\x64-windows\include'
$protoInstallInclude = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\include'
New-Item -Path $protoInstallInclude -ItemType Directory -Force | Out-Null
Copy-Item "$vcpkgInclude\*" $protoInstallInclude -Recurse -Force -ErrorAction SilentlyContinue

$litertBuildDir = Join-Path $buildDir 'litert_lm\build'
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
                try {
                    $null = & $llvmAr rcs $aPath -- 2>&1
                    $stubCount++
                } catch { Write-Verbose "stub archive best-effort skip: $_" }
            }
        }
    }
    Write-Host "Created $stubCount ExternalProject lib stubs (.a/.lib referenced by the aggregate but not yet built)"
}

Write-Host 'Running ExternalProject step 6 (build)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-build 2>&1
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 101) { Write-Host "WARNING: ninja build step exited with code $LASTEXITCODE" }
Write-Host "Build step completed with exit code: $LASTEXITCODE"

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
    $vcpkgBin = Join-Path $vcpkgDir 'installed\x64-windows\bin'
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
else { Write-Host "WARNING: ninja did not produce litert_lm_main.exe -- the clean-link CMake patch may need attention" }
# ----------------------------------------------------------------------------------------------

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
    Write-Host 'LITERTLM_KEEP_BUILD_TREE set: dumping litert_lm_main link diagnostics (and KEEPING the tree)'
    $innerBuild = Join-Path $SourceDir 'build_ninja\litert_lm\build'
    Write-Host '===DIAG=== litert_lm_main.rsp (link inputs/flags, order preserved):'
    $rsp = Get-ChildItem $innerBuild -Recurse -Filter 'litert_lm_main.rsp' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rsp) { Write-Host "RSP: $($rsp.FullName)"; (Get-Content -Raw $rsp.FullName) -split '\s+' | ForEach-Object { Write-Host "  $_" } }
    else { Write-Host 'RSP not found'; Get-ChildItem $innerBuild -Recurse -Filter '*.rsp' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  found rsp: $($_.FullName)" } }
    Write-Host '===DIAG=== WHOLEARCHIVE / FORCE:MULTIPLE presence in the link rule (build.ninja):'
    $bn = Join-Path $innerBuild 'build.ninja'
    if (Test-Path $bn) { Get-Content $bn | Select-String -Pattern 'litert_lm_main.*(WHOLEARCHIVE|FORCE:MULTIPLE)|WHOLEARCHIVE' | Select-Object -First 4 | ForEach-Object { Write-Host "  $($_.Line.Substring(0,[Math]::Min(240,$_.Line.Length)))" } }
    Write-Host '===DIAG=== abseil libs actually built (strings/log/flags/status present?):'
    $abslLib = Join-Path $innerBuild 'external\abseil-cpp\install\lib'
    if (Test-Path $abslLib) { Get-ChildItem $abslLib -Filter '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'strings|log|flags|status|str_format|str_cat' } | ForEach-Object { Write-Host "  $($_.Name)" } }
    else { Write-Host "  abseil lib dir not found at $abslLib"; Get-ChildItem (Join-Path $innerBuild 'external\abseil-cpp') -Recurse -Filter 'libabsl_strings*' -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { Write-Host "  $($_.FullName)" } }
    Write-Host '===DIAG=== referenced libs in rsp that are MISSING or 0-byte (empty stubs -> undefined symbols):'
    if ($rsp) {
        (Get-Content -Raw $rsp.FullName) -split '\s+' | Where-Object { $_ -match '\.(a|lib)$' } | ForEach-Object {
            $p = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $innerBuild $_ }
            if (-not (Test-Path $p)) { Write-Host "  MISSING: $_" }
            elseif ((Get-Item $p).Length -lt 16) { Write-Host "  EMPTY($((Get-Item $p).Length)B): $_" }
        }
    }
    Write-Host '===DIAG=== which built lib DEFINES the leftover undefined symbols (nm scan; T/D/W = defined):'
    $nmExe = (Get-Command 'llvm-nm.exe' -ErrorAction SilentlyContinue).Source
    if ($nmExe) {
        $fragments = @('ClassicLocale', 'MixingHashState', 'combine_raw', 'HashStateBase')
        $libs = Get-ChildItem $innerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'flatbuffers|absl_hash|absl_city|absl_low_level_hash|tensorflow|tflite' }
        Write-Host "  candidate libs found: $($libs.Count)"
        $libs | ForEach-Object { Write-Host "    lib: $($_.Name)  ($([math]::Round($_.Length/1KB))KB)" }
        foreach ($lib in $libs) {
            $syms = & $nmExe --defined-only $lib.FullName 2>$null
            foreach ($frag in $fragments) {
                $def = $syms | Select-String -Pattern $frag -SimpleMatch | Select-Object -First 1
                if ($def) { Write-Host "  DEFINED [$frag] in $($lib.Name)" }
            }
        }
        # find the dllimport CONSUMER: which lib has an UNDEFINED __imp reference to MixingHashState
        Write-Host '  --- dllimport consumers (libs with UNDEFINED __imp MixingHashState) ---'
        $consumerLibs = Get-ChildItem $innerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'litert|runtime_|tflite|tensorflow|flatbuffers' }
        foreach ($lib in $consumerLibs) {
            $u = & $nmExe --undefined-only $lib.FullName 2>$null | Select-String -Pattern 'MixingHashState' -SimpleMatch | Where-Object { $_ -match '__imp|imp_' } | Select-Object -First 1
            if ($u) { Write-Host "  CONSUMER __imp MixingHashState <- $($lib.Name)" }
        }
    } else { Write-Host '  llvm-nm not found' }
    Write-Host '===DIAG=== abseil DUPLICATE-flag scan: which rsp archives DEFINE minloglevel (>1 = the ODR culprit):'
    if ($nmExe -and $rsp) {
        $rspLibs2 = (Get-Content -Raw $rsp.FullName) -split '\s+' | Where-Object { $_ -match '\.(a|lib)$' } |
            ForEach-Object { if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $innerBuild $_ } } |
            Where-Object { Test-Path $_ } | Sort-Object -Unique
        Write-Host "  rsp archives to scan: $($rspLibs2.Count)"
        $mllHits = @()
        foreach ($lp in $rspLibs2) {
            $d = & $nmExe --defined-only $lp 2>$null | Select-String -Pattern 'minloglevel' -SimpleMatch | Select-Object -First 1
            if ($d) { $mllHits += $lp; Write-Host "  DEFINES minloglevel: $lp" }
        }
        Write-Host "  >>> $($mllHits.Count) archive(s) define minloglevel (expect 1; >1 = duplicate abseil = ODR bug)"
        # Also flag any second copy of the whole abseil log-flags TU by archive name.
        $logFlagArch = $rspLibs2 | Where-Object { $_ -match 'log_flags|absl_log_flags|log.*flags' }
        if ($logFlagArch) { Write-Host "  absl_log_flags-named archives in rsp:"; $logFlagArch | ForEach-Object { Write-Host "    $_" } }
    } else { Write-Host '  (need llvm-nm + rsp)' }
    Write-Host '===DIAG END==='
}
else { Remove-SourceBuildTree -Path $SourceDir }

Write-Host '=== LiteRT-LM source build completed ==='



