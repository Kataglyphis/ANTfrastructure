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

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.26.0'

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
# Backlog #47: every OFF path here used to be SILENT — a green build with LLVM
# off has no CPU codegen at all (`tvm.build` for any llvm target dies at
# RUNTIME), and nothing in the log said so. Each detection now states the OFF
# verdict and its consequence; the LLVM one below is fatal on the GPU lane.
if ($useCudnn -eq 'OFF' -and $useCuda -eq 'ON') {
    Write-Warning "TVM: cuDNN NOT found (CudnnRoot='$($gpuEnv.CudnnRoot)') - building WITHOUT cuDNN kernels; conv workloads fall back to slower paths."
}

# Auto-detect Vulkan SDK ($useVulkan is the single gate; the include/lib args
# below branch on it too instead of re-evaluating the env+Test-Path pair).
$vulkanSdk = Get-SourceBuildVersion -EnvironmentVariables @('VULKAN_SDK') -DefaultValue ''
$useVulkan = 'OFF'
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    Write-Host "Vulkan SDK detected at: $vulkanSdk - enabling TVM Vulkan support"
    $useVulkan = 'ON'
} else {
    Write-Warning "TVM: Vulkan SDK NOT found (VULKAN_SDK='$vulkanSdk') - building WITHOUT the Vulkan runtime; base images bake it via scoop, so an OFF here usually means a broken image, not a policy choice (#47)."
}

# Auto-detect LLVM. The #47 gate fired on its first live run (verify5,
# 2026-08-17) and corrected its own premise: the toolchain's scoop LLVM is the
# official Windows INSTALLER build, which ships clang/lld but NEITHER
# llvm-config.exe NOR the LLVM dev libs (probed: 0 hits in the whole install).
# So every prior Windows TVM was silently USE_LLVM=OFF - no CPU codegen at all
# (`tvm.build` for any llvm target dies at RUNTIME).
#
# Self-heal: build a MINIMAL LLVM (X86+NVPTX, no tests/docs/xml2/zlib) from the
# pinned source release and point USE_LLVM at its llvm-config. Building it
# ourselves is not gold-plating - it is the only ABI that works: the official
# clang+llvm-*-windows-msvc dev tarball was tried first (verify6, same day) and
# its static libs are /MT (MT_StaticRelease) + want xml2s.lib, which lld-link
# rightly refuses against this /MD chain (SPIRV-Tools et al.). sccache makes
# the ~2000 extra TUs a one-time cost. Build-time only: TVM links LLVM
# statically, and Clear-BuildScratch scrubs the tree afterwards.
$llvmCmd = Get-Command llvm-config.exe -ErrorAction SilentlyContinue
$llvmConfig = if ($llvmCmd) { $llvmCmd.Source } else { $null }
if (-not $llvmConfig) {
    $llvmDevVersion = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '22.1.8'
    # SHA pins per version - extend when LLVM_WINDOWS_VERSION moves. An unknown
    # version must THROW, never download unpinned (repo download policy).
    $llvmSrcSha = @{
        '22.1.8' = '922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888'
    }
    if (-not $llvmSrcSha.ContainsKey($llvmDevVersion)) {
        throw ("TVM: llvm-config.exe not on PATH and no SHA256 pin for the llvm-project-$llvmDevVersion source " +
            "tarball - add it to `$llvmSrcSha in this script. Refusing an unpinned download (backlog #47).")
    }
    $llvmDevRoot = 'C:\temp\llvm-dev'
    $llvmSrcTar = Join-Path $llvmDevRoot "llvm-project-$llvmDevVersion.src.tar.xz"
    Write-Host "TVM: llvm-config.exe not on PATH (scoop LLVM never ships it) - building a minimal LLVM $llvmDevVersion from source (backlog #47)"
    Invoke-DownloadWithRetry `
        -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmDevVersion/llvm-project-$llvmDevVersion.src.tar.xz" `
        -DestinationPath $llvmSrcTar -ExpectedSha256 $llvmSrcSha[$llvmDevVersion] `
        -Description "llvm-project $llvmDevVersion source tarball (backlog #47)"
    # System32 bsdtar (xz support baked in); git's GNU tar would need xz.exe.
    $tarExe = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
    if (-not $tarExe) { throw 'TVM: no tar.exe found to extract the LLVM source tarball (#47).' }
    & $tarExe -xf $llvmSrcTar -C $llvmDevRoot
    if ($LASTEXITCODE -ne 0) { throw "TVM: extracting the LLVM source tarball failed (tar exit $LASTEXITCODE) (#47)." }
    Remove-Item $llvmSrcTar -Force  # keep the scratch tier lean; the tree is scrubbed post-build anyway
    $llvmInstall = Join-Path $llvmDevRoot 'install'
    Write-Host 'Building minimal LLVM (X86+NVPTX, Release, /MD) - ~20-40 min cold, sccache-cached after'
    # Build the arg list in a VARIABLE: `-ExtraArgs @(...) + (...)` in argument
    # position does not concatenate - the parser fed `+` to -Generator and the
    # archiver arg to -Platform (verify8: "Could not create named generator +").
    $llvmCmakeArgs = @(
            # X86 for host codegen, NVPTX so TVM's llvm path can feed the CUDA lane.
            '-DLLVM_TARGETS_TO_BUILD=X86;NVPTX'
            # No compression/xml deps: nothing here needs them, and each one is
            # another import the /MD-vs-/MT tarball failure taught us to distrust.
            '-DLLVM_ENABLE_LIBXML2=OFF', '-DLLVM_ENABLE_ZLIB=OFF', '-DLLVM_ENABLE_ZSTD=OFF'
            '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_BENCHMARKS=OFF'
            '-DLLVM_INCLUDE_EXAMPLES=OFF', '-DLLVM_INCLUDE_DOCS=OFF'
            '-DLLVM_ENABLE_ASSERTIONS=OFF'
            # No ATL in these Build Tools: DIA-SDK support #includes atlbase.h
            # and dies (verify9) - same trap the IREE port hit. llvm-config
            # consumers here never read PDBs.
            '-DLLVM_ENABLE_DIA_SDK=OFF'
            # RTTI on: TVM compiles its codegen TUs with RTTI (clang-cl default);
            # matching avoids the typeinfo-mismatch class outright.
            '-DLLVM_ENABLE_RTTI=ON'
            # Full :FILEPATH archiver, same as the TVM configure below: the
            # helper's bare -DCMAKE_AR=llvm-lib gets absolutized by LLVM's build
            # to C:\llvm-lib and every static-lib step dies (verify7).
        )
    $llvmCmakeArgs += Get-LlvmArchiverCmakeArg
    Invoke-CmakeConfigure `
        -SourceDir (Join-Path $llvmDevRoot "llvm-project-$llvmDevVersion.src\llvm") `
        -BuildDir (Join-Path $llvmDevRoot 'build') -InstallPrefix $llvmInstall `
        -ExtraArgs $llvmCmakeArgs | Out-Null
    $llvmBuildLog = Get-PersistentBuildLogPath -Name 'llvm-minimal-build.log' -FallbackDir (Join-Path $llvmDevRoot 'build')
    Invoke-NinjaBuildWithRetry -BuildDir (Join-Path $llvmDevRoot 'build') -RetryJobs 1 -MemGBPerJob 2 `
        -LogFile $llvmBuildLog -Install -InstallConfig 'Release'
    $llvmConfig = Join-Path $llvmInstall 'bin\llvm-config.exe'
    if (-not (Test-Path $llvmConfig)) {
        throw ("TVM: llvm-config.exe missing after the minimal LLVM build+install ($llvmInstall). " +
            "USE_LLVM=OFF would ship a TVM with no CPU codegen - refusing (backlog #47).")
    }
    # Reclaim the ~5 GB object tree now; only the install prefix is needed below.
    Remove-Item (Join-Path $llvmDevRoot 'build') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $llvmDevRoot "llvm-project-$llvmDevVersion.src") -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "LLVM detected via llvm-config: $llvmConfig - enabling TVM LLVM codegen"
# A PATH (forward slashes) is TVM's documented USE_LLVM form; plain ON only
# works when llvm-config is already on PATH, which is exactly what is absent.
$useLLVM = $llvmConfig -replace '\\', '/'

$pythonModule = if ($SkipPython) { 'OFF' } else { 'ON' }

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    # :STRING= + no embedded quotes (matches onnx/opencv/genai; bare quotes leaked into the flag value)
    # -Wno-documentation-unknown-command: tvm/ffi/reflection/accessor.h uses
    # doxygen tags clang's -Wdocumentation does not know (~900 lines/chain).
    # Upstream's own header comments -- nothing here can fix them, and they say
    # nothing about the correctness of this build.
    # Verify the count actually dropped: windows\scripts\diagnostics\Measure-BuildWarnings.ps1
    "-DCMAKE_CXX_FLAGS:STRING=-Wno-unknown-attributes $(Get-WarningNoiseSuppressionFlags)"
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
# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'tvm-build.log' -FallbackDir $buildDir
# MemGBPerJob 2, not 4 (backlog #74) — see the note in build-onnx-genai. The
# sibling build-iree, which compiles LLVM in-tree in this same branch, has used
# 2 all along, so the LLVM-class TUs are covered by evidence, not optimism.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install -InstallConfig $BuildType
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
    # tvm_ffi built from the vendored 3rdparty/tvm-ffi source + tvm wheel --no-deps
    # (see above) make `import tvm` load a self-consistent FFI/runtime; a plain
    # smoke import is enough. (The WinError-127 diagnostics that lived here while
    # item 37 was open were removed once the source-built path proved green.)
    Test-PythonImport -Python $py -ModuleName 'tvm'
}

Remove-SourceBuildTree -Path $SourceDir


Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0