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

# #108: shared assets sit beside this script in the FLAT container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# Cross-lane python wheels (#133): scikit-build-core cannot cross-package, so this lane assembles
# both wheels itself -- see docs/windows-refactor-backlog.md #133(c).
$tvmLeafModule = Join-Path $scriptAssetRoot 'modules\WindowsTvm.Common.psm1'
if (-not (Test-Path $tvmLeafModule)) { throw "Required module not found: $tvmLeafModule -- the media-tvm RUN must mount the tvmmods stage (Dockerfile.media-builder)" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($tvmLeafModule)))) { Import-Module $tvmLeafModule }

# TVM_COMMIT wins over TVM_REF: v0.26.0 does not compile against LLVM 23.1.0
# (Intrinsic::matchIntrinsicSignature + MatchIntrinsicTypes_* removed, ORC JIT
# lambda signature changed, SubtargetSubTypeKV::Key -> key()). Upstream main
# carries TVM_LLVM_VERSION >= 230 guards for all of it; no release does.
# See versions.env § TVM_COMMIT for the full rationale.
$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_COMMIT', 'TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.26.0'

Write-Host "=== TVM source build ($TvmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive | Out-Null

# TVM needs VsDevCmd for MSVC STL headers; the C++ build consumes no CPython, so the python blocks
# below set up their own env instead of a full Initialize-ToolchainPythonEnvironment preamble here.
Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

$gpuEnv = Get-GpuEnvironment
$useCuda = if ($gpuEnv.HasCuda) { 'ON' } else { 'OFF' }
if ($useCuda -eq 'ON') { Write-Host "CUDA detected at: $($gpuEnv.CudaRoot) - enabling TVM CUDA support" }

# cuBLAS ships inside the toolkit (no hint needed). cuDNN is a SEPARATE install, and TVM's legacy
# cmake/utils/FindCUDA.cmake reads CUDA_CUDNN_LIBRARY -- the standard CUDNN_* vars are ignored.
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
# #47: every OFF verdict must state its consequence in the log, never pass silently.
if ($useCudnn -eq 'OFF' -and $useCuda -eq 'ON') {
    Write-Warning "TVM: cuDNN NOT found (CudnnRoot='$($gpuEnv.CudnnRoot)') - building WITHOUT cuDNN kernels; conv workloads fall back to slower paths."
}

$vulkanSdk = Get-SourceBuildVersion -EnvironmentVariables @('VULKAN_SDK') -DefaultValue ''
$useVulkan = 'OFF'
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    Write-Host "Vulkan SDK detected at: $vulkanSdk - enabling TVM Vulkan support"
    $useVulkan = 'ON'
} else {
    Write-Warning "TVM: Vulkan SDK NOT found (VULKAN_SDK='$vulkanSdk') - building WITHOUT the Vulkan runtime; base images bake it via scoop, so an OFF here usually means a broken image, not a policy choice (#47)."
}

# amd64: scoop LLVM ships no llvm-config and no dev libs, so build a minimal LLVM from pinned
# source (#47, docs/windows-build-invariants.md). Cross: runtime-only, no compiler at all (#116).
$tvmCross = Test-WindowsCrossTarget
$llvmCmd = if ($tvmCross) { $null } else { Get-Command llvm-config.exe -ErrorAction SilentlyContinue }
$llvmConfig = if ($llvmCmd) { $llvmCmd.Source } else { $null }
if ($tvmCross) {
    Write-Host 'TVM cross: RUNTIME-ONLY build (USE_LLVM=OFF, no tvm_compiler; runtime python wheels decided below, #133) -- backlog #116; see docs/windows-cross-builds.md'
} elseif (-not $llvmConfig) {
    $llvmDevVersion = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.0'
    # An unknown version must THROW, never download unpinned (repo download policy). versions.env
    # can pre-seed the current version via LLVM_WINDOWS_SRC_SHA256 (#129); the table is the record.
    $llvmSrcSha = @{
        '22.1.8' = '922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888'
        '23.1.0' = 'ab1f0e3ec52448c33e8782eaf0422504b87c7b016b22514653ee0d8fcee479ff'
    }
    if ($env:LLVM_WINDOWS_SRC_SHA256) { $llvmSrcSha[$llvmDevVersion] = $env:LLVM_WINDOWS_SRC_SHA256 }
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
    Write-Host 'Building minimal LLVM (X86+AArch64+NVPTX, Release, /MD) - ~20-40 min cold, sccache-cached after'
    # Build the arg list in a VARIABLE: `-ExtraArgs @(...) + (...)` in argument position does not
    # concatenate -- the parser fed `+` to -Generator ("Could not create named generator +").
    $llvmCmakeArgs = @(
            # X86 for host codegen, NVPTX for the CUDA lane, AArch64 for #116.
            '-DLLVM_TARGETS_TO_BUILD=X86;AArch64;NVPTX'
            # No xml2/zlib/zstd: nothing here needs them, and each is another /MD-vs-/MT import risk.
            '-DLLVM_ENABLE_LIBXML2=OFF', '-DLLVM_ENABLE_ZLIB=OFF', '-DLLVM_ENABLE_ZSTD=OFF'
            '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_BENCHMARKS=OFF'
            '-DLLVM_INCLUDE_EXAMPLES=OFF', '-DLLVM_INCLUDE_DOCS=OFF'
            '-DLLVM_ENABLE_ASSERTIONS=OFF'
            # No ATL in these Build Tools: DIA-SDK support #includes atlbase.h and dies.
            '-DLLVM_ENABLE_DIA_SDK=OFF'
            # RTTI on: TVM compiles its codegen TUs with RTTI; matching avoids typeinfo mismatches.
            '-DLLVM_ENABLE_RTTI=ON'
            # Archiver appended below as a full :FILEPATH -- a bare -DCMAKE_AR=llvm-lib gets
            # absolutized by LLVM's build to C:\llvm-lib and every static-lib step dies.
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
$useLLVM = if ($tvmCross) { 'OFF' } else {
    Write-Host "LLVM detected via llvm-config: $llvmConfig - enabling TVM LLVM codegen"
    # A PATH (forward slashes) is TVM's USE_LLVM form; plain ON needs llvm-config already on PATH.
    $llvmConfig -replace '\\', '/'
}

# Python OFF on the cross lane too: the tvm package drives tvm_compiler.dll, absent there.
$pythonModule = if ($SkipPython -or $tvmCross) { 'OFF' } else { 'ON' }
# Cross (#133): TVM_BUILD_PYTHON_MODULE stays OFF; tvm-ffi's own TVM_FFI_BUILD_PYTHON_MODULE builds
# the Cython `core` extension against the TARGET import lib (#120 pattern, EXT_SUFFIX via the shim).
$tvmTargetPy = if ($tvmCross) { Get-TargetBuildPython } else { $null }
$tvmCrossPython = [bool]($tvmCross -and -not $SkipPython -and $tvmTargetPy -and $tvmTargetPy.Available)
if ($tvmCross -and -not $tvmCrossPython -and -not $SkipPython) {
    Write-Host "TVM cross: runtime python wheels OFF -- no target CPython import lib at $($tvmTargetPy.Lib) (build-target-cpython.ps1 did not run?)"
}
$py = Get-SourceBuildPython
if ($tvmCrossPython) {
    Install-CpythonPip -Python $py
    Initialize-PythonPlatformTag | Out-Null
    # cython transpiles core.pyx (a CMake custom command); wheel supplies `python -m wheel pack`.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'cython', 'wheel')
    # FindPython reads Include\pyconfig.h; the in-tree CPython keeps it at PC\.
    Copy-CpythonPyConfigHeader
    Write-Host "TVM cross: runtime python wheels ON (#133) -- host interpreter $($py.Exe), TARGET import lib $($tvmTargetPy.Lib); the compiler and its codegen stay ABSENT"
}

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    # :STRING= and no embedded quotes -- bare quotes leak into the flag value. The suppressions cover
    # upstream's own doxygen tags; count them with windows\scripts\diagnostics\Measure-BuildWarnings.ps1.
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
    # Arch-aware: Lib on amd64, Lib-ARM64 on the cross lane (the x64 SDK's
    # optional arm64 component; verify-toolchain.ps1 asserts it is installed).
    $vulkanLib = Join-Path $vulkanSdk (Get-VulkanLibDirName)
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# CMAKE_AR: find llvm-lib on PATH -- use :FILEPATH (matches OpenCV/LiteRT form) for consistency.
$cmakeExtra += Get-LlvmArchiverCmakeArg
# (#133) NO python knobs here: tvm-ffi's CMakeLists `return()`s as a subproject, so
# TVM_FFI_BUILD_PYTHON_MODULE is never read. The Cython module gets its own configure below.

Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra | Out-Null

Write-Host 'Building TVM (this may take 30-60 minutes)...'
# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'tvm-build.log' -FallbackDir $buildDir
# MemGBPerJob 2, not 4 (backlog #74) -- LLVM-class TUs, same as the sibling build-iree.
if ($tvmCross) {
    # Runtime-only (#116): build the tvm_runtime target graph and stage by hand -- `cmake --install`
    # would install tvm_compiler, never built here. Layout mirrors amd64 so TVM_LIBRARY_PATH holds.
    Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Targets @('tvm_runtime')
    $tvmLibOut = Join-Path $tvmInstallDir 'lib'
    $tvmIncOut = Join-Path $tvmInstallDir 'include'
    New-Item -Path $tvmLibOut, $tvmIncOut -ItemType Directory -Force | Out-Null
    $runtimeBins = @(Get-ChildItem -Path $buildDir -Recurse -Include 'tvm_runtime*.dll', 'tvm_runtime*.lib', 'tvm_ffi*.dll', 'tvm_ffi*.lib' -File)
    if (-not ($runtimeBins | Where-Object { $_.Name -eq 'tvm_runtime.dll' })) { throw "TVM cross: tvm_runtime.dll was not produced under $buildDir" }
    foreach ($b in $runtimeBins) { Copy-Item $b.FullName -Destination $tvmLibOut -Force }
    # 0.26 layout (docs/windows-cross-builds.md): TVM's include\tvm and the FFI split's are MERGED --
    # copy CONTENTS, or PowerShell nests a second tvm\; dlpack lives in the tvm-ffi submodule.
    $dlpackHeader = Get-ChildItem -Path (Join-Path $SourceDir '3rdparty\tvm-ffi') -Recurse -Filter 'dlpack.h' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $headerTrees = @(
        @{ Src = (Join-Path $SourceDir 'include\tvm');                 Dest = 'tvm' }
        @{ Src = (Join-Path $SourceDir '3rdparty\tvm-ffi\include\tvm'); Dest = 'tvm' }
    )
    if ($dlpackHeader) { $headerTrees += @{ Src = $dlpackHeader.DirectoryName; Dest = 'dlpack' } }
    else { Write-Warning 'TVM cross: dlpack.h not found under 3rdparty\tvm-ffi (upstream layout drift?) -- the runtime headers will not compile standalone' }
    foreach ($tree in $headerTrees) {
        if (-not (Test-Path $tree.Src)) { throw "TVM cross: header tree $($tree.Src) not found (upstream layout drift?)" }
        $dest = Join-Path $tvmIncOut $tree.Dest
        New-Item -Path $dest -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $tree.Src '*') -Destination $dest -Recurse -Force
    }
    # c_runtime_api.h is GONE with the FFI split (its C surface is tvm\ffi\c_api.h now).
    foreach ($mustExist in @('tvm\runtime\c_backend_api.h', 'tvm\runtime\device_api.h', 'tvm\ffi\c_api.h', 'dlpack\dlpack.h')) {
        if (-not (Test-Path (Join-Path $tvmIncOut $mustExist))) { throw "TVM cross: staged include tree is missing $mustExist -- the header copy above did not produce a usable runtime SDK" }
    }
    # Static gate (the import gate is OFF on this lane): a host-arch DLL from the wrong build dir
    # would otherwise ship and fail only at load time on the target.
    $tvmDlls = Assert-DirectoryTargetArch -Path $tvmLibOut -Include @('*.dll') -MinCount 2 -Context 'TVM cross'
    Write-Host ('TVM cross: staged {0} runtime binaries ({1} DLLs, all PE machine 0x{2:X4}) into {3}; compiler ABSENT by design (#116)' -f $runtimeBins.Count, $tvmDlls, (Get-PeMachineType), $tvmLibOut)
    # The merge fans in C:\runtime\wheels from this branch unconditionally.
    $wheelStore = Join-Path (Split-Path $InstallDir -Parent) 'runtime\wheels'
    New-Item -Path $wheelStore -ItemType Directory -Force | Out-Null
    if ($tvmCrossPython) {
        # (#133) Two wheels assembled from the package sources + this pass's binaries; each layout is
        # what the package looks for: core.pyd beside tvm_ffi\, DLLs under <pkg>\lib (libinfo), _version.py.
        Switch-BuildPhase '5b. runtime python wheels (cross, assembled)'
        $tvmFfiSrc = Join-Path $SourceDir '3rdparty\tvm-ffi'
        # tvm-ffi's Cython module exists only when tvm-ffi is the ROOT project, hence its own
        # configure. The wheel ships THIS build's tvm_ffi.dll -- the one core.pyd linked against.
        $ffiPyBuild = Join-Path $buildDir 'tvm-ffi-py'
        $ffiPyArgs = @(
            "-DCMAKE_BUILD_TYPE=$BuildType"
            # /EHsc explicitly: an explicit CMAKE_CXX_FLAGS replaces CMake's MSVC init flags, and
            # tvm-ffi as a root project does not add it back ("throw with exceptions disabled").
            "-DCMAKE_CXX_FLAGS:STRING=/EHsc -Wno-unknown-attributes $(Get-WarningNoiseSuppressionFlags)"
            '-DTVM_FFI_BUILD_PYTHON_MODULE=ON'
            '-DTVM_FFI_BUILD_TESTS=OFF'
        ) + @(Get-PythonCMakeHintArgs -Python $tvmTargetPy -Prefix 'Python' -ForwardSlash) + @(Get-LlvmArchiverCmakeArg)
        Invoke-CmakeConfigure -SourceDir $tvmFfiSrc -BuildDir $ffiPyBuild -InstallPrefix (Join-Path $ffiPyBuild 'install') -ExtraArgs $ffiPyArgs | Out-Null
        Invoke-NinjaBuildWithRetry -BuildDir $ffiPyBuild -RetryJobs 1 -MemGBPerJob 2 -LogFile (Get-PersistentBuildLogPath -Name 'tvm-ffi-python-build.log' -FallbackDir $ffiPyBuild) -Targets @('tvm_ffi_cython')
        $corePyd = @(Get-ChildItem -Path $ffiPyBuild -Recurse -Filter 'core*.pyd' -File)
        if ($corePyd.Count -ne 1) { throw "TVM cross: expected exactly one tvm_ffi core*.pyd under $ffiPyBuild, found $($corePyd.Count): $(($corePyd | ForEach-Object Name) -join ', ')" }
        $wantExt = Get-PythonWheelTag
        # FindPython reports no SOABI for CPython on Windows, so WITH_SOABI yields a bare `core.pyd`
        # -- a valid import name. Only a HOST-tagged name is wrong; the PE check below is the gate.
        if ($corePyd[0].Name -match '\.cp\d+-win_(amd64|arm64)\.pyd$' -and $corePyd[0].Name -notmatch [regex]::Escape($wantExt)) { throw "TVM cross: tvm_ffi core module is named $($corePyd[0].Name) -- a HOST EXT_SUFFIX tag, the target interpreter would never import it (expected '$wantExt' or a bare core.pyd)" }
        # tvm_ffi_testing.dll too: core.pyd imports it (the merge's arch gate walks those imports),
        # and upstream's wheel ships it beside tvm_ffi.dll for the same reason.
        $tvmFfiLibs = @(Get-ChildItem -Path $ffiPyBuild -Recurse -File | Where-Object { $_.Name -in 'tvm_ffi.dll', 'tvm_ffi.lib', 'tvm_ffi_testing.dll' } | Group-Object Name | ForEach-Object { $_.Group | Select-Object -First 1 })
        foreach ($must in 'tvm_ffi.dll', 'tvm_ffi_testing.dll') {
            if (-not ($tvmFfiLibs | Where-Object { $_.Name -eq $must })) { throw "TVM cross: $must not produced by the standalone tvm-ffi build under $ffiPyBuild" }
        }
        [void](Assert-DirectoryTargetArch -Path $corePyd[0].DirectoryName -Include @('core*.pyd') -MinCount 1 -Context 'tvm_ffi core module')
        $describe = & git -C $tvmFfiSrc describe --tags --abbrev=0 --match 'v*' 2>&1 | Out-String
        $global:LASTEXITCODE = 0
        $tvmPyproject = [System.IO.File]::ReadAllText((Join-Path $SourceDir 'pyproject.toml'))
        $ffiPyproject = [System.IO.File]::ReadAllText((Join-Path $tvmFfiSrc 'pyproject.toml'))
        $ffiVersion = Get-VendoredTvmFfiVersion -DescribeOutput $describe -TvmPyprojectText $tvmPyproject
        $tvmPyVersion = ($TvmVersion -replace '^v', '')
        $stage = Join-Path $buildDir 'py-stage'
        if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force }
        # apache-tvm-ffi
        $ffiRoot = Join-Path $stage 'ffi'
        New-Item -Path (Join-Path $ffiRoot 'tvm_ffi\lib') -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $tvmFfiSrc 'python\tvm_ffi\*') -Destination (Join-Path $ffiRoot 'tvm_ffi') -Recurse -Force
        Copy-Item -Path $corePyd[0].FullName -Destination (Join-Path $ffiRoot 'tvm_ffi') -Force
        foreach ($l in $tvmFfiLibs) { Copy-Item -Path $l.FullName -Destination (Join-Path $ffiRoot 'tvm_ffi\lib') -Force }
        foreach ($inc in @(@{ Src = 'include'; Dest = 'include' }, @{ Src = '3rdparty\dlpack\include'; Dest = '3rdparty\dlpack\include' })) {
            $srcDir = Join-Path $tvmFfiSrc $inc.Src
            if (Test-Path $srcDir) {
                $dst = Join-Path $ffiRoot "tvm_ffi\$($inc.Dest)"
                New-Item -Path $dst -ItemType Directory -Force | Out-Null
                Copy-Item -Path (Join-Path $srcDir '*') -Destination $dst -Recurse -Force
            }
        }
        [void](Write-AssembledWheelDistInfo -Name 'apache-tvm-ffi' -Version $ffiVersion -PackageRoot $ffiRoot -PlatformTag $wantExt `
            -RequiresDist (Get-PyprojectDependencies -PyprojectText $ffiPyproject) -RequiresPython '>=3.9' `
            -Summary "tvm-ffi runtime for $wantExt, assembled from the tvm-ffi submodule TVM $TvmVersion vendors (Kataglyphis cross build)")
        # apache-tvm (runtime-only)
        $tvmRoot = Join-Path $stage 'tvm'
        New-Item -Path (Join-Path $tvmRoot 'tvm\lib') -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $SourceDir 'python\tvm\*') -Destination (Join-Path $tvmRoot 'tvm') -Recurse -Force
        [System.IO.File]::WriteAllText((Join-Path $tvmRoot 'tvm\_version.py'), "__version__ = `"$tvmPyVersion`"`n__version_tuple__ = ($($tvmPyVersion -replace '\.', ', '))`n")
        Copy-Item -Path (Join-Path $tvmLibOut 'tvm_runtime.dll') -Destination (Join-Path $tvmRoot 'tvm\lib') -Force
        [void](Write-AssembledWheelDistInfo -Name 'apache-tvm' -Version $tvmPyVersion -PackageRoot $tvmRoot -PlatformTag $wantExt `
            -RequiresDist (Get-PyprojectDependencies -PyprojectText $tvmPyproject) -RequiresPython '>=3.10' `
            -Summary "Apache TVM $TvmVersion RUNTIME-ONLY python package for $wantExt (no tvm_compiler; Kataglyphis cross build)")
        $wheelOut = Join-Path $stage 'dist'
        New-Item -Path $wheelOut -ItemType Directory -Force | Out-Null
        foreach ($root in @($ffiRoot, $tvmRoot)) {
            [void](Invoke-ShieldedNative -Label "wheel pack $(Split-Path $root -Leaf)" -CommandLine """$($py.Exe)"" -m wheel pack ""$root"" --dest-dir ""$wheelOut""")
        }
        $stagedWheels = @(Save-PythonWheel -SourceDir $wheelOut -WheelDir $wheelStore -Required)
        if ($stagedWheels.Count -ne 2) { throw "TVM cross: expected 2 assembled wheels staged into $wheelStore, got $($stagedWheels.Count)" }
        foreach ($w in $stagedWheels) { Assert-WheelTargetArch -WheelPath $w }
        Write-Host "TVM cross: staged $($stagedWheels.Count) runtime python wheel(s) for $wantExt into ${wheelStore}: $(($stagedWheels | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
        # Close the phase opened above, or the next script's first phase inherits it.
        Complete-CurrentBuildPhase
    }
    $absentComponent = if ($tvmCrossPython) { 'tvm_compiler.dll (and with it every tvm codegen / relax build path)' } else { 'tvm_compiler.dll and the tvm python package' }
    [void](Write-AbsentOnCrossMarker -Root $tvmInstallDir -Component $absentComponent -FileName 'COMPILER-ABSENT-ON-ARM64.txt' -Reason @(
        'The compiler needs TARGET-arch LLVM libraries plus a HOST llvm-config at configure time (backlog #116/#133) -- not attempted.',
        $(if ($tvmCrossPython) { 'The tvm + tvm_ffi python packages ARE shipped as win_arm64 wheels in C:\runtime\wheels (#133), runtime-only: `import tvm` takes tvm/base.py''s _RUNTIME_ONLY path.' } else { 'The python packages were not built on this pass (no target CPython import lib or -SkipPython).' }),
        'tvm_runtime.dll + tvm_ffi.dll (+ import libs) in lib\ and the headers in include\ are the shipped runtime.'
    ))
} else {
    Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install -InstallConfig $BuildType
}
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# The FFI split builds tvm_ffi as a SEPARATE shared lib that `cmake --install` does not stage, so
# tvm_runtime.dll fails to load (0xC0000135) in the final image.
Copy-SidecarDll -SidecarName 'tvm_ffi.dll' -SearchDir $buildDir `
    -BesidePrimary 'tvm_runtime.dll' -InstallDir $tvmInstallDir `
    -Reason 'tvm_runtime.dll may fail to load at runtime (cmake --install missed the FFI shared lib)'

# TVM packages via scikit-build-core at the REPO ROOT (no cmake-generated build\python dir any
# more). Reuse the ninja dir so the wheel packs existing objects; a fresh tree is the ~25 min fallback.
if ($pythonModule -eq 'ON') {
    $py = Get-SourceBuildPython
    # The wheel is EXPECTED here: only an explicit -SkipPython may drop it, never a missing interpreter.
    if (-not (Test-Path $py.Exe)) {
        throw "TVM python module expected but source-built CPython is missing at $($py.Exe) (toolchain layer incomplete? pass -SkipPython for a deliberate no-python build)"
    }
    # Parallel media branches: cannot rely on the GenAI build having installed pip first.
    Install-CpythonPip -Python $py
    # 64-bit platform tag BEFORE any pip resolution (clang-built CPython self-reports win32).
    Initialize-PythonPlatformTag | Out-Null
    # cython: tvm_ffi's core.pyx is transpiled by a CMake step shelling out to `python -m cython`.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'scikit-build-core', 'setuptools-scm', 'wheel', 'cython')
    # The DNS-workaround clone may lack git tags -- pin the scm version. Save/restore: stages run
    # in-process and a leaked pretend-version would mis-stamp the next stage's build.
    $prevScmPretendVersion = $env:SETUPTOOLS_SCM_PRETEND_VERSION
    # When TVM_COMMIT (a commit hash) wins over TVM_REF (a tag), the pretend
    # version must still be the TAG's version (e.g. 0.26.0), not the hash —
    # setuptools_scm would otherwise generate an InvalidVersion crash in
    # packaging.version (a 40-char hex string is not PEP 440).
    $scmVersion = $TvmVersion
    if ($scmVersion -match '^[0-9a-f]{7,40}$') {
        $tagFallback = Get-SourceBuildVersion -EnvironmentVariables @('TVM_REF') -DefaultValue 'v0.26.0'
        $scmVersion = $tagFallback
    }
    $env:SETUPTOOLS_SCM_PRETEND_VERSION = ($scmVersion -replace '^v', '')
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
    # Build tvm_ffi from the VENDORED submodule, never PyPI: TVM vendors an unreleased tvm-ffi, so
    # the PyPI wheel is ABI-skewed against our tvm_runtime.dll (WinError 127; item 37 in
    # docs/windows-backlog-archive-2026-08-11.md). The tvm wheel then installs --no-deps.
    $tvmFfiSrc = Join-Path $SourceDir '3rdparty\tvm-ffi'
    if (Test-Path (Join-Path $tvmFfiSrc 'pyproject.toml')) {
        # scikit-build-core re-runs CMake FindPython in a subprocess; it reads Include\pyconfig.h,
        # which in-tree Windows CPython keeps only at PC\ -- stage it (same fix opencv/iree/genai use).
        Copy-CpythonPyConfigHeader
        Write-Host "Building + installing tvm_ffi from vendored source ($tvmFfiSrc)..."
        Invoke-CpythonPip -Python $py -Arguments @('install', '--no-build-isolation', '--force-reinstall', '--no-deps', $tvmFfiSrc)
    } else {
        Write-Warning "vendored tvm-ffi source not at $tvmFfiSrc - falling back to the PyPI apache-tvm-ffi (import may fail 127)"
    }
    $staged = @(Save-PythonWheel -SourceDir $wheelOut -WheelDir 'C:\runtime\wheels' -Required)
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--no-deps', '--only-binary', ':all:', $staged[0])
    # --no-deps above starves the pure-python runtime deps, so install them here: typing_extensions
    # is a hard import in tvm_ffi, the rest are best-effort (--only-binary blocks sdist builds).
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'typing_extensions')
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--only-binary', ':all:', 'ml_dtypes', 'cloudpickle', 'psutil') -Optional
    Test-PythonImport -Python $py -ModuleName 'tvm'
}

Remove-SourceBuildTree -Path $SourceDir


Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0