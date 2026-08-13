# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\tvm-src',
    [string]$InstallDir = '',
    [string]$TvmVersion = '',
    [string]$BuildType = 'Release',
    [switch]$SkipPython
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.25.0'

Write-Host "=== TVM source build ($TvmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive | Out-Null

# TVM requires VsDevCmd for MSVC STL headers. The C++ configure/build does not
# consume CPython, so VsDevCmd alone suffices HERE; the python-wheel block below
# DOES use the source-built CPython (Get-SourceBuildPython + pip) and runs its
# own Initialize-PythonPlatformTag there -- no full
# Initialize-ToolchainPythonEnvironment preamble needed up front.
Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

# Auto-detect CUDA via the canonical GPU environment helper (CUDA_PATH / PATH already set by it).
$gpuEnv = Get-GpuEnvironment
$useCuda = if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) { 'ON' } else { 'OFF' }
if ($useCuda -eq 'ON') { Write-Host "CUDA detected at: $($gpuEnv.CudaRoot) - enabling TVM CUDA support" }

# GPU math libraries (CUDA lane only). cuBLAS ships inside the CUDA toolkit (found via
# CUDAToolkit_ROOT), so it needs no extra hint. cuDNN is a SEPARATE install: enable it only
# when cudnn.h + cudnn.lib actually resolve.
# NOTE: TVM uses its legacy cmake/utils/FindCUDA.cmake, which looks up the variable
# CUDA_CUDNN_LIBRARY (NOT the standard CUDNN_INCLUDE_DIR/CUDNN_LIBRARY -- those are silently
# ignored). Because cuDNN lives OUTSIDE the CUDA toolkit dir here, TVM's find_library returns
# NOTFOUND and configure dies, so we set CUDA_CUDNN_LIBRARY directly and also put cuDNN's
# include/lib on INCLUDE/LIB so clang-cl finds cudnn.h and lld-link finds cudnn.lib at compile.
$useCublas = $useCuda
$useCudnn  = 'OFF'
$cudnnArgs = @()
if ($useCuda -eq 'ON' -and $gpuEnv.CudnnRoot -and (Test-Path (Join-Path $gpuEnv.CudnnRoot 'include\cudnn.h'))) {
    # Shared cuDNN import-lib finder (prefers cudnn.lib over the 9.x split sub-libs); $null when absent.
    $cudnnLibPath = Get-CudnnLibrary -CudnnRoot $gpuEnv.CudnnRoot
    if ($cudnnLibPath) {
        $cudnnLibDir = Split-Path $cudnnLibPath -Parent
        $useCudnn  = 'ON'
        $cudnnArgs = @("-DCUDA_CUDNN_LIBRARY=$($cudnnLibPath -replace '\\','/')")
        $env:INCLUDE = "$(Join-Path $gpuEnv.CudnnRoot 'include');$env:INCLUDE"
        $env:LIB     = "$cudnnLibDir;$env:LIB"
        Write-Host "cuDNN detected at $($gpuEnv.CudnnRoot) - enabling TVM cuDNN (CUDA_CUDNN_LIBRARY=$(Split-Path $cudnnLibPath -Leaf))"
    }
}

# Auto-detect Vulkan SDK ($useVulkan is the single gate; the include/lib args
# below branch on it too instead of re-evaluating the env+Test-Path pair).
$vulkanSdk = Get-SourceBuildVersion -EnvironmentVariables @('VULKAN_SDK') -DefaultValue ''
$useVulkan = 'OFF'
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    Write-Host "Vulkan SDK detected at: $vulkanSdk - enabling TVM Vulkan support"
    $useVulkan = 'ON'
}

# Auto-detect LLVM
$llvmCmd = Get-Command llvm-config.exe -ErrorAction SilentlyContinue
$llvmConfig = if ($llvmCmd) { $llvmCmd.Source } else { $null }
$useLLVM = 'OFF'
if ($llvmConfig) {
    Write-Host "LLVM detected via llvm-config: $llvmConfig - enabling TVM LLVM codegen"
    $useLLVM = 'ON'
}

$pythonModule = if ($SkipPython) { 'OFF' } else { 'ON' }

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    # :STRING= + no embedded quotes (matches onnx/opencv/genai; bare quotes leaked into the flag value)
    # -Wno-documentation-unknown-command: tvm/ffi/reflection/accessor.h uses
    # doxygen tags clang's -Wdocumentation does not know (~900 lines/chain).
    # Upstream's own header comments -- nothing here can fix them, and they say
    # nothing about the correctness of this build.
    # Verify the count actually dropped: windows\scripts\Measure-BuildWarnings.ps1
    '-DCMAKE_CXX_FLAGS:STRING=-Wno-unknown-attributes -Wno-documentation-unknown-command'
    '-DUSE_OPENCL=OFF'
    '-DUSE_MICRO=OFF'
    "-DUSE_CUDA=$useCuda"
    "-DUSE_CUBLAS=$useCublas"
    "-DUSE_CUDNN=$useCudnn"
    "-DUSE_VULKAN=$useVulkan"
    "-DUSE_LLVM=$useLLVM"
    "-DTVM_BUILD_PYTHON_MODULE=$pythonModule"
)

$cmakeExtra += Get-CudaToolkitRootArg -GpuEnv $gpuEnv -ForwardSlash
$cmakeExtra += $cudnnArgs

if ($useVulkan -eq 'ON') {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# CMAKE_AR: find llvm-lib on PATH -- use :FILEPATH (matches OpenCV/LiteRT form) for consistency.
$cmakeExtra += Get-LlvmArchiverCmakeArg

Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra | Out-Null

Write-Host 'Building TVM (this may take 30-60 minutes)...'
$buildLog = Join-Path $buildDir 'tvm-build.log'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 4 -LogFile $buildLog -Install -InstallConfig $BuildType
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# TVM 0.25's FFI split builds libtvm_ffi as a SEPARATE shared lib that tvm_runtime.dll
# imports, but `cmake --install` does not stage tvm_ffi.dll -> tvm_runtime.dll then fails to
# load (0xC0000135 STATUS_DLL_NOT_FOUND) in the final image. Copy it next to the installed
# tvm_runtime.dll. Caught by the smoke-test TVM load probe.
Copy-SidecarDll -SidecarName 'tvm_ffi.dll' -SearchDir $buildDir `
    -BesidePrimary 'tvm_runtime.dll' -InstallDir $tvmInstallDir `
    -Reason 'tvm_runtime.dll may fail to load at runtime (cmake --install missed the FFI shared lib)'

# Python wheel: TVM 0.25 packages via scikit-build-core at the REPO ROOT -- the
# old cmake-generated build\python dir is GONE (TVM_BUILD_PYTHON_MODULE no longer
# emits one; the previous -Optional site install silently did nothing, which is
# why `import tvm` never worked in earlier images). Reuse the just-built ninja
# dir: its CMake cache already carries USE_CUDA/LLVM/etc., so scikit-build-core's
# configure mostly no-ops and the wheel packs existing objects; if the reuse
# trips, fall back to a fresh tree (full ~25 min recompile, still correct).
if ($pythonModule -eq 'ON') {
    $py = Get-SourceBuildPython
    # The tvm wheel is EXPECTED on this lane: a missing interpreter must fail
    # loudly, not silently ship an image without `import tvm` (only an explicit
    # -SkipPython legitimately drops the wheel).
    if (-not (Test-Path $py.Exe)) {
        throw "TVM python module expected but source-built CPython is missing at $($py.Exe) (toolchain layer incomplete? pass -SkipPython for a deliberate no-python build)"
    }
    # Bootstrap pip if missing — this script can no longer rely on the GenAI
    # build having installed it first (parallel media branches).
    Install-CpythonPip -Python $py
    # 64-bit platform tag BEFORE any pip resolution (clang-built CPython
    # self-reports win32 and pulls 32-bit wheels otherwise).
    Initialize-PythonPlatformTag | Out-Null
    # cython: tvm_ffi's cython module (core.pyx -> core.cpp) is transpiled by a
    # CMake custom-build step that shells out to `python -m cython`; without it
    # the tvm_ffi wheel dies with `No module named cython` -> MSB8066. The main
    # tvm wheel does not need it, but installing here covers both.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'scikit-build-core', 'setuptools-scm', 'wheel', 'cython')
    # The DNS-workaround clone may lack git tags -- pin the scm version directly.
    # Save/restore: stages run in-process, and a leaked pretend-version would
    # mis-stamp the NEXT stage's setuptools-scm build (e.g. IREE).
    $prevScmPretendVersion = $env:SETUPTOOLS_SCM_PRETEND_VERSION
    $env:SETUPTOOLS_SCM_PRETEND_VERSION = ($TvmVersion -replace '^v', '')
    $wheelOut = Join-Path $SourceDir 'dist'
    Write-Host 'Building TVM python wheel (scikit-build-core, reusing the ninja build dir)...'
    Push-Location $SourceDir
    try {
        Invoke-CpythonPip -Python $py -Arguments @('wheel', '.', '--no-deps', '--no-build-isolation', '-w', $wheelOut, "--config-settings=build-dir=$buildDir") -Optional
        if (-not (Test-Path (Join-Path $wheelOut '*.whl'))) {
            Write-Warning 'build-dir reuse produced no wheel -- retrying with a fresh scikit-build tree (full recompile)'
            Invoke-CpythonPip -Python $py -Arguments @('wheel', '.', '--no-deps', '--no-build-isolation', '-w', $wheelOut)
        }
    } finally {
        Pop-Location
        if ($null -ne $prevScmPretendVersion) { $env:SETUPTOOLS_SCM_PRETEND_VERSION = $prevScmPretendVersion }
        else { Remove-Item Env:\SETUPTOOLS_SCM_PRETEND_VERSION -ErrorAction SilentlyContinue }
    }
    # ITEM 37 ROOT CAUSE + FIX (2026-08-12, found via libinfo diagnostics):
    # tvm/base.py loads the runtime with
    #   load_lib_ctypes("tvm","tvm_runtime", extra_lib_paths=tvm_ffi.libinfo.package_lib_paths())
    # i.e. the tvm_runtime.dll's FFI dependency is resolved from the SEPARATE
    # `tvm_ffi` PYTHON PACKAGE (apache-tvm-ffi), pulled from PyPI as a wheel
    # dependency. That prebuilt tvm_ffi.dll is a DIFFERENT build than our
    # source-built tvm_runtime.dll, so a TVMFFI procedure it imports is absent
    # -> OSError [WinError 127]. (Ruled out first, all via dumpbin: LLVM (no
    # dynamic dep), the wheel-internal FFI contract (0 missing), dbghelp (all
    # 8 procs present).) FIX: overwrite the tvm_ffi package's dll(s) with our
    # matching build so the loaded FFI is the one tvm_runtime.dll was linked
    # against.
    # Install tvm_ffi (the apache-tvm-ffi package) FROM OUR VENDORED SOURCE,
    # NOT PyPI (item 37 real fix). `import tvm` -> `from tvm_ffi import ...` ->
    # tvm_ffi/registry.py `from . import core` loads the tvm_ffi package's
    # compiled `core` extension + its tvm_ffi.dll. When pip pulls
    # apache-tvm-ffi from PyPI (a RELEASED version) it does not match the
    # tvm-ffi submodule TVM 0.25 vendors, so core.pyd/tvm_ffi.dll and our
    # source-built tvm_runtime.dll disagree on the TVMFFI ABI -> WinError 127.
    # Building tvm_ffi from 3rdparty/tvm-ffi makes core.pyd + tvm_ffi.dll +
    # tvm_runtime.dll one consistent build. Then install tvm with --no-deps so
    # pip never re-pulls the PyPI apache-tvm-ffi over it.
    $tvmFfiSrc = Join-Path $SourceDir '3rdparty\tvm-ffi'
    if (Test-Path (Join-Path $tvmFfiSrc 'pyproject.toml')) {
        # tvm_ffi builds a cython extension via scikit-build-core, which re-runs
        # CMake FindPython from scratch in a subprocess. CMake 4.4's FindPython
        # reads <cpython>\Include\pyconfig.h to get the version; in-tree Windows
        # CPython keeps that header at PC\pyconfig.h only, so FindPython dies with
        # `file STRINGS Include/pyconfig.h cannot be read`. This build skips the
        # full Initialize-ToolchainPythonEnvironment preamble (see top of file),
        # so stage pyconfig.h ourselves -- the same fix opencv/iree/genai use.
        Copy-CpythonPyConfigHeader
        Write-Host "Building + installing tvm_ffi from vendored source ($tvmFfiSrc)..."
        Invoke-CpythonPip -Python $py -Arguments @('install', '--no-build-isolation', '--force-reinstall', '--no-deps', $tvmFfiSrc)
    } else {
        Write-Warning "vendored tvm-ffi source not at $tvmFfiSrc - falling back to the PyPI apache-tvm-ffi (import may fail 127)"
    }
    $staged = @(Save-PythonWheel -SourceDir $wheelOut -WheelDir 'C:\runtime\wheels' -Required)
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--no-deps', '--only-binary', ':all:', $staged[0])
    # Both tvm_ffi and tvm install with --no-deps (so pip never re-pulls the PyPI
    # apache-tvm-ffi BINARY over our source build), so their pure-python runtime
    # deps must be provided explicitly. tvm-ffi declares only typing-extensions;
    # tvm 0.25's FFI split leaves numpy (already present) plus a small optional
    # set (ml_dtypes/cloudpickle/psutil). typing_extensions is a hard import in
    # tvm_ffi/dataclasses/c_class.py, so it is required; the rest are best-effort
    # (--only-binary keeps a cp314-less sdist from dragging in a source build).
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'typing_extensions')
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--only-binary', ':all:', 'ml_dtypes', 'cloudpickle', 'psutil') -Optional
    $sitePkgTvm = & $py.Exe -c "import site,os; print(next((os.path.join(d,'tvm') for d in site.getsitepackages() if os.path.isdir(os.path.join(d,'tvm'))), ''))" 2>&1 | Select-Object -Last 1
    try {
        Test-PythonImport -Python $py -ModuleName 'tvm'
    } catch {
        # SELF-DIAGNOSIS (item 37): ask tvm which lib it loads, then WinDLL
        # THAT exact path to surface the WinError 127 procedure, and dumpbin
        # its unresolved TVM/TVMFFI imports against the co-bundled ffi/runtime.
        Write-Host '=== TVM import-failure diagnostics (item 37) ===' -ForegroundColor Yellow
        $pyExe = $py.Exe
        $findLib = @'
import os, ctypes, traceback
try:
    from tvm._ffi import libinfo
    for p in libinfo.find_lib_path():
        print("FINDLIB", p)
        try:
            ctypes.CDLL(p)
            print("  CDLL-load OK", p)
        except Exception as e:
            print("  CDLL-load FAIL", p, repr(e))
except Exception:
    traceback.print_exc()
'@
        $flFile = Join-Path $env:TEMP 'tvm_findlib.py'
        Set-Content -Path $flFile -Value $findLib -Encoding ascii
        & $pyExe $flFile 2>&1 | ForEach-Object { Write-Host "  findlib: $_" }
        $dumpbin2 = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        if ($dumpbin2 -and $sitePkgTvm -and (Test-Path $sitePkgTvm)) {
            $allExports = New-Object System.Collections.Generic.HashSet[string]
            Get-ChildItem $sitePkgTvm -Filter '*.dll' -Recurse | ForEach-Object {
                & $dumpbin2 /exports $_.FullName 2>&1 | Select-String '\b(TVM\w+)\b' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { [void]$allExports.Add($_.Groups[1].Value) }
            }
            foreach ($big in @("$sitePkgTvm\lib\tvm_compiler.dll", "$sitePkgTvm\tvm_runtime.dll", "$sitePkgTvm\lib\tvm_runtime.dll")) {
                if (Test-Path $big) {
                    $imps = @(& $dumpbin2 /imports $big 2>&1 | Select-String '\b(TVM\w+)\b' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                    $miss = @($imps | Where-Object { -not $allExports.Contains($_) })
                    Write-Host ("  {0}: imports {1} TVM syms, MISSING across all bundled dlls: {2}" -f [IO.Path]::GetFileName($big), $imps.Count, ($miss -join ', '))
                }
            }
        }
        # dumpbin the FFI symbol contract: which tvm_ffi procedures does the
        # runtime IMPORT, and which does the staged tvm_ffi.dll EXPORT? The
        # set difference names the missing procedure (WinError 127) and proves
        # stale-sidecar vs genuine ABI mismatch.
        $dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        $stagedFfi = "$tvmInstallDir\lib\tvm_ffi.dll"
        $stagedRt = "$tvmInstallDir\lib\tvm_runtime.dll"
        $buildFfi = Join-Path $buildDir 'tvm_ffi.dll'
        if ($dumpbin -and (Test-Path $stagedFfi)) {
            $stagedExports = @(& $dumpbin /exports $stagedFfi 2>&1 | Select-String 'TVMFFI\w+' -AllMatches | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique)
            $rtImports = @(& $dumpbin /imports $stagedRt 2>&1 | Select-String 'TVMFFI\w+' -AllMatches | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique)
            $missing = @($rtImports | Where-Object { $_ -notin $stagedExports })
            Write-Host ("  staged tvm_ffi.dll exports {0} TVMFFI syms; runtime imports {1}; MISSING from staged: {2}" -f $stagedExports.Count, $rtImports.Count, ($missing -join ', '))
            if (Test-Path $buildFfi) {
                $buildExports = @(& $dumpbin /exports $buildFfi 2>&1 | Select-String 'TVMFFI\w+' -AllMatches | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique)
                $stillMissing = @($rtImports | Where-Object { $_ -notin $buildExports })
                Write-Host ("  build-dir tvm_ffi.dll exports {0} TVMFFI syms; MISSING from build-dir copy: {1}  (staged==build size: {2})" -f $buildExports.Count, ($stillMissing -join ', '), ((Get-Item $stagedFfi).Length -eq (Get-Item $buildFfi).Length))
            }
        }
        foreach ($dll in @($stagedFfi, $stagedRt)) {
            if (Test-Path $dll) { & $pyExe -c "import ctypes; ctypes.WinDLL(r'$dll')" 2>&1 | ForEach-Object { Write-Host "  load[$([IO.Path]::GetFileName($dll))]: $_" } }
        }
        # THE REAL SCENE (v5): tvm.base loads the WHEEL-BUNDLED libs from
        # site-packages\tvm\, NOT the staged sidecars (which sit co-located and
        # load fine). Enumerate what the wheel actually shipped and load each
        # bundled DLL the way python does (default search dirs), so the 127
        # names itself.
        $sitePkgTvm = & $pyExe -c "import site,os; p=[os.path.join(d,'tvm') for d in site.getsitepackages()+[site.getusersitepackages()] if os.path.isdir(os.path.join(d,'tvm'))]; print(p[0] if p else '')" 2>&1 | Select-Object -Last 1
        Write-Host "  wheel tvm package dir: $sitePkgTvm"
        if ($sitePkgTvm -and (Test-Path $sitePkgTvm)) {
            Get-ChildItem -Path $sitePkgTvm -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host ("  wheel dll: {0} ({1:N0} bytes)" -f $_.FullName.Replace($sitePkgTvm, '...'), $_.Length)
                & $pyExe -c "import ctypes; ctypes.WinDLL(r'$($_.FullName)')" 2>&1 | ForEach-Object { Write-Host "    load: $_" }
            }
        }
        # WinError 127 with a satisfied FFI contract => a SYSTEM-DLL procedure
        # is missing. Dump each DLL's non-TVMFFI imports grouped by source DLL,
        # and cross-check dbghelp.dll (backtrace_win.cc; Server Core ships a
        # minimal dbghelp) - name the exact missing export.
        if ($dumpbin) {
            $sysDbghelp = "$env:SystemRoot\System32\dbghelp.dll"
            $dbghelpExports = if (Test-Path $sysDbghelp) { @(& $dumpbin /exports $sysDbghelp 2>&1 | Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)' | ForEach-Object { $_.Matches.Groups[1].Value }) } else { @() }
            Write-Host ("  system dbghelp.dll ($sysDbghelp) exports {0} procs" -f $dbghelpExports.Count)
            foreach ($dll in @($stagedFfi, $stagedRt)) {
                if (-not (Test-Path $dll)) { continue }
                $imp = @(& $dumpbin /imports $dll 2>&1)
                $curDll = ''
                foreach ($ln in $imp) {
                    if ($ln -match '^\s{4}(\S+\.dll)') { $curDll = $Matches[1] }
                    elseif ($curDll -match 'dbghelp' -and $ln -match '^\s+[0-9A-F]+\s+(\w+)$') {
                        $proc = $Matches[1]
                        $present = $dbghelpExports -contains $proc
                        Write-Host ("  [{0}] imports dbghelp!{1} - present in system dbghelp: {2}" -f [IO.Path]::GetFileName($dll), $proc, $present)
                    }
                }
            }
        }
        # Where is tvm's extension + which DLL/procedure does its import resolve to?
        $tb = @'
import importlib, traceback
try:
    importlib.import_module("tvm")
    print("import ok")
except Exception:
    traceback.print_exc()
'@
        $tbFile = Join-Path $env:TEMP 'tvm_import_diag.py'
        Set-Content -Path $tbFile -Value $tb -Encoding ascii
        & $pyExe $tbFile 2>&1 | Select-Object -First 15 | ForEach-Object { Write-Host "  import tvm: $_" }
        throw
    }
}

Remove-SourceBuildTree -Path $SourceDir


Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0