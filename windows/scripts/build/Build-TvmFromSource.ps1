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

# scikit-build-core cannot cross-package, so the cross lane assembles both python wheels itself.
$tvmLeafModule = Join-Path $scriptAssetRoot 'modules\WindowsTvm.Common.psm1'
if (-not (Test-Path $tvmLeafModule)) { throw "Required module not found: $tvmLeafModule -- the media-tvm RUN must mount the tvmmods stage (Dockerfile.media-builder)" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($tvmLeafModule)))) { Import-Module $tvmLeafModule }

# rocm lane: the OpenCL runtime always; ROCm codegen + runtime only with the TVM_ROCM=1 spike switch.
function Get-TvmRocmPlan {
    param([Parameter(Mandatory)][hashtable]$GpuEnv, [bool]$Cross, [string]$SpikeFlag)
    $onLane = [bool]($GpuEnv.HasRocm -and -not $Cross)
    $rocm = $onLane -and $SpikeFlag -eq '1'
    return [pscustomobject]@{
        OnLane       = $onLane
        Rocm         = $rocm
        RocmRoot     = if ($onLane) { $GpuEnv.RocmRoot } else { $null }
        # find_rocm reads $env:ROCM_PATH even with USE_ROCM=OFF: TheRock's include dir + HIP defines on every TU.
        HideRocmPath = $onLane -and -not $rocm
    }
}

# Off the spike this is byte-for-byte the cpu/nvidia list.
function Get-TvmLlvmTargetList {
    param([bool]$Rocm)
    if ($Rocm) { return 'X86;AArch64;NVPTX;AMDGPU' }
    return 'X86;AArch64;NVPTX'
}

# Appended after the shared list (cmake keeps the last -D), so @() leaves cpu/nvidia untouched.
function Get-TvmRocmCmakeArgs {
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.OnLane) { return @() }
    $rocmArgs = @('-DUSE_OPENCL=ON')
    if ($Plan.Rocm) {
        $root = $Plan.RocmRoot -replace '\\', '/'
        # Pre-seeded, so FindROCM does not depend on the rocm-lane package-prefix isolation.
        $rocmArgs += "-DUSE_ROCM=$root", "-DROCM_HIPHCC_LIBRARY=$root/lib/amdhip64.lib"
    }
    return $rocmArgs
}

# The patches the ROCm spike carries: no HSA on Windows, and rocm.py's Linux-only lookups.
function Get-TvmRocmPatchSpec {
    return @(
        @{ File = 'src\backend\rocm\runtime\rocm_device_api.cc'; Description = 'TVM ROCm: drop <hsa/hsa.h> (Windows ROCm ships no HSA)'
            Pattern = '#include <hsa/hsa\.h>\r?\n'; Replacement = ''; Done = '\A(?![\s\S]*hsa/hsa\.h)'; Gone = '<hsa/hsa\.h>' }
        @{ File = 'src\backend\rocm\runtime\rocm_device_api.cc'; Description = 'TVM ROCm: kExist asks HIP, not hsa_init'
            Pattern = 'if \(hsa_init\(\) == HSA_STATUS_SUCCESS\) \{\s*int dev;\s*ROCM_CALL\(hipGetDeviceCount\(&dev\)\);\s*value = dev > device\.device_id \? 1 : 0;\s*hsa_shut_down\(\);\s*\} else \{\s*value = 0;\s*\}'
            Replacement = 'int dev = 0;  /* kataglyphis: HIP kExist */ value = (hipGetDeviceCount(&dev) == hipSuccess && dev > device.device_id) ? 1 : 0;'
            Done = 'kataglyphis: HIP kExist'; Gone = 'hsa_init|hsa_shut_down|HSA_STATUS' }
        @{ File = 'python\tvm\support\rocm.py'; Description = 'TVM rocm.py: import shutil'
            Pattern = '(?m)^import subprocess(\r?\n)'; Replacement = 'import shutil$1import subprocess$1'; Done = '(?m)^import shutil\r?$'; Gone = '' }
        @{ File = 'python\tvm\support\rocm.py'; Description = 'TVM rocm.py: ld.lld via PATHEXT, then TheRock lib\llvm\bin'
            Pattern = '(?m)^([ \t]*)valid_list = \[utils\.which\(x\) for x in lld_list\](\r?\n)'
            Replacement = '$1lld_list += [os.path.join(os.environ["ROCM_PATH"], "lib", "llvm", "bin", "ld.lld")] if os.environ.get("ROCM_PATH") else []$2$1valid_list = [utils.which(x) or shutil.which(x) for x in lld_list]$2'
            Done = 'utils\.which\(x\) or shutil\.which\(x\)'; Gone = 'valid_list = \[utils\.which\(x\) for x in lld_list\]' }
        @{ File = 'python\tvm\support\rocm.py'; Description = 'TVM rocm.py: device bitcode from HIP_DEVICE_LIB_PATH'
            Pattern = '(?m)^([ \t]*)if rocdl_dir is None:(\r?\n)([ \t]*)rocm_path = find_rocm_path\(\)'
            Replacement = '$1if rocdl_dir is None and os.path.isdir(os.environ.get("HIP_DEVICE_LIB_PATH", "")):$2$3rocdl_dir = os.environ["HIP_DEVICE_LIB_PATH"]$2$1if rocdl_dir is None:$2$3rocm_path = find_rocm_path()'
            Done = 'rocdl_dir = os\.environ\["HIP_DEVICE_LIB_PATH"\]'; Gone = '' }
        @{ File = 'python\tvm\support\rocm.py'; Description = 'TVM rocm.py: pre-2023 oclc control bitcode optional'
            Pattern = 'n not in \{"irif"\}'
            Replacement = 'n not in {"irif", "oclc_daz_opt_on", "oclc_daz_opt_off", "oclc_correctly_rounded_sqrt_on", "oclc_correctly_rounded_sqrt_off"}'
            Done = '"oclc_correctly_rounded_sqrt_off"\}'; Gone = 'n not in \{"irif"\}' }
        @{ File = 'python\tvm\support\rocm.py'; Description = 'TVM rocm.py: no rocminfo on Windows falls back to the default arch'
            Pattern = 'except subprocess\.CalledProcessError:'; Replacement = 'except (subprocess.CalledProcessError, OSError):'
            Done = 'except \(subprocess\.CalledProcessError, OSError\):'; Gone = 'except subprocess\.CalledProcessError:' }
    )
}

function Invoke-TvmRocmSourcePatch {
    param([Parameter(Mandatory)][string]$SourceDir)
    foreach ($spec in Get-TvmRocmPatchSpec) {
        $path = Join-Path $SourceDir $spec.File
        [void](Invoke-InlineRegexPatch -Path $path -Require -Pattern $spec.Pattern -Replacement $spec.Replacement `
                -SkipIfMatch $spec.Done -AssertGone $spec.Gone -Description $spec.Description)
        if ([System.IO.File]::ReadAllText($path) -notmatch $spec.Done) { throw "$($spec.Description): did not land in $path -- upstream layout changed" }
    }
}

function Assert-TvmLlvmConfigNotRocm {
    param([string]$LlvmConfig, [string]$RocmRoot)
    if (-not $LlvmConfig -or -not $RocmRoot) { return }
    if ($LlvmConfig.StartsWith($RocmRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "TVM: llvm-config resolves into the ROCm tree ($LlvmConfig) -- AMD's LLVM fork must never reach PATH; TVM would bind to it instead of the pinned LLVM"
    }
}

function Test-TvmLlvmHasAmdgpu {
    param([AllowEmptyString()][string]$TargetsBuilt)
    return @("$TargetsBuilt".Trim() -split '[\s;]+') -ccontains 'AMDGPU'
}

function Assert-TvmLlvmHasAmdgpu {
    param([string]$TargetsBuilt, [string]$LlvmConfig)
    if (-not (Test-TvmLlvmHasAmdgpu -TargetsBuilt $TargetsBuilt)) {
        throw "TVM ROCm spike: $LlvmConfig has no AMDGPU target (targets-built: '$("$TargetsBuilt".Trim())') -- the rocm codegen cannot emit hsaco"
    }
}

# `llvm-config --targets-built` ("AArch64 X86"), trimmed.
function Get-TvmLlvmTargetsBuilt {
    param([Parameter(Mandatory)][string]$LlvmConfig)
    return ((Invoke-ShieldedNative -Label 'llvm-config --targets-built' -CommandLine """$LlvmConfig"" --targets-built" -Quiet) | Out-String).Trim()
}

# The marker's form of a --targets-built line: 'AArch64 X86' -> 'AArch64;X86'.
function ConvertTo-TvmLlvmTargetString {
    param([AllowEmptyString()][string]$TargetsBuilt)
    return (@("$TargetsBuilt".Trim() -split '[\s;]+' | Where-Object { $_ }) -join ';')
}

# PATH's llvm-config, else a minimal LLVM; on the spike the toolchain's (no AMDGPU) counts as absent.
function Get-TvmLlvmChoice {
    param([string]$PathLlvmConfig, [bool]$Rocm, [bool]$Cross, [Parameter(Mandatory)][scriptblock]$GetTargetsBuilt)
    if ($Cross) { return [pscustomobject]@{ BuildMinimal = $false; LlvmConfig = $null; Targets = ''; Why = 'cross lane: runtime-only, no LLVM' } }
    $minimal = [pscustomobject]@{ BuildMinimal = $true; LlvmConfig = $null; Targets = (Get-TvmLlvmTargetList -Rocm $Rocm); Why = 'llvm-config.exe not on PATH (scoop LLVM never ships it)' }
    if (-not $PathLlvmConfig) { return $minimal }
    if ($Rocm) {
        $built = "$(& $GetTargetsBuilt $PathLlvmConfig)".Trim()
        if (-not (Test-TvmLlvmHasAmdgpu -TargetsBuilt $built)) {
            $minimal.Why = "TVM ROCm spike: $PathLlvmConfig has no AMDGPU target (targets-built: '$built')"
            return $minimal
        }
    }
    return [pscustomobject]@{ BuildMinimal = $false; LlvmConfig = $PathLlvmConfig; Targets = ''; Why = 'llvm-config.exe on PATH' }
}

# Read by windows\scripts\build\rocm-checks\TVM.ps1: what the rocm-lane TVM build enabled.
function Get-TvmRocmFeatureMarker {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$LlvmTargets)
    return @(
        '# Written by Build-TvmFromSource.ps1 on the rocm lane; read by rocm-checks\TVM.ps1.'
        "TVM_ROCM=$(if ($Plan.Rocm) { '1' } else { '0' })"
        'USE_OPENCL=ON'
        "USE_ROCM=$(if ($Plan.Rocm) { $Plan.RocmRoot -replace '\\', '/' } else { 'OFF' })"
        "LLVM_TARGETS=$LlvmTargets"
    )
}

# TVM_COMMIT wins over TVM_REF: no TVM release compiles against LLVM 23.1; see versions.env § TVM_COMMIT.
$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_COMMIT', 'TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.26.0'

Write-Host "=== TVM source build ($TvmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive | Out-Null

# VsDevCmd for the MSVC STL headers; the python blocks below set up their own env.
Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

$gpuEnv = Get-GpuEnvironment
# CUDA on the cross lane only when the image carries the arm64 payload, the signal ORT, GenAI and OpenCV use.
$tvmCross = Test-WindowsCrossTarget
$tvmCudaUsable = $gpuEnv.HasCuda -and ((-not $tvmCross) -or (Test-CudaWindowsArm64Payload -CudaRoot $gpuEnv.CudaRoot))
$useCuda = if ($tvmCudaUsable) { 'ON' } else { 'OFF' }
if ($useCuda -eq 'ON') { Write-Host "CUDA detected at: $($gpuEnv.CudaRoot) - enabling TVM CUDA support" }

$tvmRocmPlan = Get-TvmRocmPlan -GpuEnv $gpuEnv -Cross $tvmCross -SpikeFlag $env:TVM_ROCM
if ($tvmRocmPlan.OnLane) {
    Write-Host "ROCm lane -> TVM OpenCL runtime ON; ROCm codegen + runtime $(if ($tvmRocmPlan.Rocm) { "ON (TVM_ROCM=1, $($tvmRocmPlan.RocmRoot))" } else { 'OFF (TVM_ROCM is not 1)' })"
    if ($tvmRocmPlan.Rocm) {
        if (-not (Test-Path (Join-Path $tvmRocmPlan.RocmRoot 'lib\amdhip64.lib'))) { throw "TVM ROCm spike: $($tvmRocmPlan.RocmRoot)\lib\amdhip64.lib missing -- the rocm layer is incomplete" }
        Invoke-TvmRocmSourcePatch -SourceDir $SourceDir
    }
} elseif ($env:TVM_ROCM -eq '1') {
    Write-Warning "TVM_ROCM=1 ignored: GPU_TYPE is '$($gpuEnv.GpuType)'$(if ($tvmCross) { ' on the cross lane' }) -- the TVM ROCm spike runs on the rocm lane only"
}
$savedRocmPath = $env:ROCM_PATH
if ($tvmRocmPlan.HideRocmPath -and $env:ROCM_PATH) {
    Write-Host 'TVM: ROCM_PATH hidden for this build (TVM_ROCM is not 1) -- find_rocm would inject TheRock headers and HIP defines'
    Remove-Item Env:\ROCM_PATH
}

# cuDNN is a separate install, and TVM's legacy FindCUDA reads only CUDA_CUDNN_LIBRARY, not CUDNN_*.
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

# amd64: PATH's llvm-config, else a minimal LLVM from pinned source (also for AMDGPU on the spike); cross: no compiler.
$tvmCross = Test-WindowsCrossTarget
$llvmCmd = if ($tvmCross) { $null } else { Get-Command llvm-config.exe -ErrorAction SilentlyContinue }
$pathLlvmConfig = if ($llvmCmd) { $llvmCmd.Source } else { $null }
if ($tvmRocmPlan.OnLane) { Assert-TvmLlvmConfigNotRocm -LlvmConfig $pathLlvmConfig -RocmRoot $tvmRocmPlan.RocmRoot }
$tvmLlvm = Get-TvmLlvmChoice -PathLlvmConfig $pathLlvmConfig -Rocm $tvmRocmPlan.Rocm -Cross $tvmCross -GetTargetsBuilt ${function:Get-TvmLlvmTargetsBuilt}
$llvmConfig = $tvmLlvm.LlvmConfig
if ($tvmCross) {
    Write-Host 'TVM cross: RUNTIME-ONLY build (USE_LLVM=OFF, no tvm_compiler; runtime python wheels decided below, #133) -- backlog #116; see docs/windows-cross-builds.md'
} elseif ($tvmLlvm.BuildMinimal) {
    $llvmDevVersion = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.3'
    $llvmDevRoot = 'C:\temp\llvm-dev'
    # Before the fetch: this banner is the context an unpinned-version throw from Get-LlvmSourceTarball would lack.
    Write-Host "TVM: $($tvmLlvm.Why) - building a minimal LLVM $llvmDevVersion from source (backlog #47)"
    $llvmSrc = Get-LlvmSourceTarball -Version $llvmDevVersion -DestinationRoot $llvmDevRoot
    # Guarded, not -ErrorAction'd: an already-extracted tree comes back without a tarball.
    if (Test-Path $llvmSrc.Tarball) { Remove-Item $llvmSrc.Tarball -Force }
    $llvmInstall = Join-Path $llvmDevRoot 'install'
    Write-Host "Building minimal LLVM ($($tvmLlvm.Targets), Release, /MD) - ~20-40 min cold, sccache-cached after"
    # A variable: `-ExtraArgs @(...) + (...)` in argument position hands `+` to the next parameter.
    $llvmCmakeArgs = @(
            # X86 for host codegen, NVPTX for the CUDA lane, AArch64 for #116; AMDGPU on the ROCm spike only.
            "-DLLVM_TARGETS_TO_BUILD=$($tvmLlvm.Targets)"
            # No xml2/zlib/zstd: nothing here needs them, and each is another /MD-vs-/MT import risk.
            '-DLLVM_ENABLE_LIBXML2=OFF', '-DLLVM_ENABLE_ZLIB=OFF', '-DLLVM_ENABLE_ZSTD=OFF'
            '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_BENCHMARKS=OFF'
            '-DLLVM_INCLUDE_EXAMPLES=OFF', '-DLLVM_INCLUDE_DOCS=OFF'
            '-DLLVM_ENABLE_ASSERTIONS=OFF'
            # No ATL in these Build Tools: DIA-SDK support #includes atlbase.h and dies.
            '-DLLVM_ENABLE_DIA_SDK=OFF'
            # RTTI on: TVM compiles its codegen TUs with RTTI; matching avoids typeinfo mismatches.
            '-DLLVM_ENABLE_RTTI=ON'
            # Archiver appended below as a full :FILEPATH: LLVM absolutizes a bare llvm-lib to C:\llvm-lib.
        )
    $llvmCmakeArgs += Get-LlvmArchiverCmakeArg
    Invoke-CmakeConfigure `
        -SourceDir (Join-Path $llvmSrc.SourceDir 'llvm') `
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
    Remove-Item $llvmSrc.SourceDir -Recurse -Force -ErrorAction SilentlyContinue
}
$useLLVM = if ($tvmCross) { 'OFF' } else {
    Write-Host "LLVM detected via llvm-config: $llvmConfig - enabling TVM LLVM codegen"
    # A PATH (forward slashes) is TVM's USE_LLVM form; plain ON needs llvm-config already on PATH.
    $llvmConfig -replace '\\', '/'
}
if ($tvmRocmPlan.OnLane) {
    # Read back, never assumed: the AMDGPU gate and the marker describe the LLVM TVM really links.
    $tvmLlvmTargetsBuilt = ConvertTo-TvmLlvmTargetString -TargetsBuilt (Get-TvmLlvmTargetsBuilt -LlvmConfig $llvmConfig)
    Write-Host "TVM rocm lane: $llvmConfig targets-built $tvmLlvmTargetsBuilt"
    if ($tvmRocmPlan.Rocm) { Assert-TvmLlvmHasAmdgpu -TargetsBuilt $tvmLlvmTargetsBuilt -LlvmConfig $llvmConfig }
}

# Python OFF on the cross lane too: the tvm package drives tvm_compiler.dll, absent there.
$pythonModule = if ($SkipPython -or $tvmCross) { 'OFF' } else { 'ON' }
# Cross: tvm-ffi's own Cython `core` builds against the target import lib instead.
$tvmTargetPy = if ($tvmCross) { Get-TargetBuildPython } else { $null }
$tvmCrossPython = [bool]($tvmCross -and -not $SkipPython -and $tvmTargetPy -and $tvmTargetPy.Available)
if ($tvmCross -and -not $tvmCrossPython -and -not $SkipPython) {
    Write-Host "TVM cross: runtime python wheels OFF -- no target CPython import lib at $($tvmTargetPy.Lib) (Build-TargetCpython.ps1 did not run?)"
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
    # :STRING= without embedded quotes, which would leak into the flag; Measure-BuildWarnings.ps1 counts the suppressions.
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

if ($useCuda -eq 'ON' -and $tvmCross) {
    # TVM's FindCUDA searches lib/x64 on WIN32, so each arm64 lib is named; a wrong path fails the link loudly.
    $arm64Lib = Join-Path $gpuEnv.CudaRoot 'lib\arm64'
    $cmakeExtra += @(
        "-DCUDA_HOST_COMPILER=$((Get-NvccHostCompilerPath -Arch 'arm64') -replace '\\', '/')"
        '-DCUDA_NVCC_FLAGS=--use-local-env'
        "-DCUDA_ARCH_BIN=$((Get-CudaArchitectureList) -replace ';', ' ')"
        "-DCUDA_CUDART_LIBRARY=$((Join-Path $arm64Lib 'cudart.lib') -replace '\\', '/')"
        "-DCUDA_CUBLAS_LIBRARY=$((Join-Path $arm64Lib 'cublas.lib') -replace '\\', '/')"
        "-DCUDA_CUDA_LIBRARY=$((Join-Path $arm64Lib 'cuda.lib') -replace '\\', '/')"
    )
}

if ($useVulkan -eq 'ON') {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    # Lib-ARM64 on the cross lane is an optional SDK component that Test-Toolchain.ps1 asserts.
    $vulkanLib = Join-Path $vulkanSdk (Get-VulkanLibDirName)
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# CMAKE_AR: find llvm-lib on PATH -- use :FILEPATH (matches OpenCV/LiteRT form) for consistency.
$cmakeExtra += Get-LlvmArchiverCmakeArg
# No QNN flags: TVM's `qnn` is a quantization dialect, and the QAIRT runtime staged below serves ORT's QNN EP.
$qnnSdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256
# No python knobs: tvm-ffi's CMakeLists returns early as a subproject, so its Cython module is configured separately.

$cmakeExtra += @(Get-TvmRocmCmakeArgs -Plan $tvmRocmPlan)
Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra | Out-Null

Write-Host 'Building TVM (this may take 30-60 minutes)...'
# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'tvm-build.log' -FallbackDir $buildDir
# MemGBPerJob 2, not 4 (backlog #74) -- LLVM-class TUs, same as the sibling build-iree.
if ($tvmCross) {
    # Staged by hand in the amd64 layout: `cmake --install` would install the unbuilt tvm_compiler.
    Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Targets @('tvm_runtime')
    $tvmLibOut = Join-Path $tvmInstallDir 'lib'
    $tvmIncOut = Join-Path $tvmInstallDir 'include'
    New-Item -Path $tvmLibOut, $tvmIncOut -ItemType Directory -Force | Out-Null
    $runtimeBins = @(Get-ChildItem -Path $buildDir -Recurse -Include 'tvm_runtime*.dll', 'tvm_runtime*.lib', 'tvm_ffi*.dll', 'tvm_ffi*.lib' -File)
    if (-not ($runtimeBins | Where-Object { $_.Name -eq 'tvm_runtime.dll' })) { throw "TVM cross: tvm_runtime.dll was not produced under $buildDir" }
    foreach ($b in $runtimeBins) { Copy-Item $b.FullName -Destination $tvmLibOut -Force }
    # TVM's and tvm-ffi's include\tvm merge: copy contents, or PowerShell nests a second tvm\.
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
    # The import gate is off here, so a host-arch DLL would otherwise fail only at load time on the target.
    $tvmDlls = Assert-DirectoryTargetArch -Path $tvmLibOut -Include @('*.dll') -MinCount 2 -Context 'TVM cross'
    Write-Host ('TVM cross: staged {0} runtime binaries ({1} DLLs, all PE machine 0x{2:X4}) into {3}; compiler ABSENT by design (#116)' -f $runtimeBins.Count, $tvmDlls, (Get-PeMachineType), $tvmLibOut)
    # The merge fans in C:\runtime\wheels from this branch unconditionally.
    $wheelStore = Join-Path (Split-Path $InstallDir -Parent) 'runtime\wheels'
    New-Item -Path $wheelStore -ItemType Directory -Force | Out-Null
    if ($tvmCrossPython) {
        # Assembled in the layout each package's libinfo expects: core.pyd beside tvm_ffi\, DLLs under <pkg>\lib.
        Switch-BuildPhase '5b. runtime python wheels (cross, assembled)'
        $tvmFfiSrc = Join-Path $SourceDir '3rdparty\tvm-ffi'
        # The Cython module exists only with tvm-ffi as root; the wheel ships the tvm_ffi.dll core.pyd linked against.
        $ffiPyBuild = Join-Path $buildDir 'tvm-ffi-py'
        $ffiPyArgs = @(
            "-DCMAKE_BUILD_TYPE=$BuildType"
            # An explicit CMAKE_CXX_FLAGS replaces CMake's MSVC init flags, /EHsc included.
            "-DCMAKE_CXX_FLAGS:STRING=/EHsc -Wno-unknown-attributes $(Get-WarningNoiseSuppressionFlags)"
            '-DTVM_FFI_BUILD_PYTHON_MODULE=ON'
            '-DTVM_FFI_BUILD_TESTS=OFF'
        ) + @(Get-PythonCMakeHintArgs -Python $tvmTargetPy -Prefix 'Python' -ForwardSlash) + @(Get-LlvmArchiverCmakeArg)
        Invoke-CmakeConfigure -SourceDir $tvmFfiSrc -BuildDir $ffiPyBuild -InstallPrefix (Join-Path $ffiPyBuild 'install') -ExtraArgs $ffiPyArgs | Out-Null
        Invoke-NinjaBuildWithRetry -BuildDir $ffiPyBuild -RetryJobs 1 -MemGBPerJob 2 -LogFile (Get-PersistentBuildLogPath -Name 'tvm-ffi-python-build.log' -FallbackDir $ffiPyBuild) -Targets @('tvm_ffi_cython')
        $corePyd = @(Get-ChildItem -Path $ffiPyBuild -Recurse -Filter 'core*.pyd' -File)
        if ($corePyd.Count -ne 1) { throw "TVM cross: expected exactly one tvm_ffi core*.pyd under $ffiPyBuild, found $($corePyd.Count): $(($corePyd | ForEach-Object Name) -join ', ')" }
        $wantExt = Get-PythonWheelTag
        # FindPython has no SOABI on Windows, so a bare core.pyd is valid; only a host-tagged name is wrong.
        if ($corePyd[0].Name -match '\.cp\d+-win_(amd64|arm64)\.pyd$' -and $corePyd[0].Name -notmatch [regex]::Escape($wantExt)) { throw "TVM cross: tvm_ffi core module is named $($corePyd[0].Name) -- a HOST EXT_SUFFIX tag, the target interpreter would never import it (expected '$wantExt' or a bare core.pyd)" }
        # tvm_ffi_testing.dll too: core.pyd imports it, and upstream's wheel ships it.
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

# `cmake --install` misses the FFI split's tvm_ffi.dll, and tvm_runtime.dll then fails with 0xC0000135.
Copy-SidecarDll -SidecarName 'tvm_ffi.dll' -SearchDir $buildDir `
    -BesidePrimary 'tvm_runtime.dll' -InstallDir $tvmInstallDir `
    -Reason 'tvm_runtime.dll may fail to load at runtime (cmake --install missed the FFI shared lib)'

# scikit-build-core at the repo root reuses the ninja dir; a fresh tree is the slow fallback.
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
    # The clone may lack tags, so pin the scm version; restored after, since stages run in-process.
    $prevScmPretendVersion = $env:SETUPTOOLS_SCM_PRETEND_VERSION
    # A commit hash is not PEP 440, so the pretend version falls back to TVM_REF's tag.
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
    # tvm_ffi from the vendored submodule: PyPI's is ABI-skewed against our tvm_runtime.dll (WinError 127).
    $tvmFfiSrc = Join-Path $SourceDir '3rdparty\tvm-ffi'
    if (Test-Path (Join-Path $tvmFfiSrc 'pyproject.toml')) {
        # FindPython reads Include\pyconfig.h, which in-tree Windows CPython keeps only at PC\.
        Copy-CpythonPyConfigHeader
        Write-Host "Building + installing tvm_ffi from vendored source ($tvmFfiSrc)..."
        Invoke-CpythonPip -Python $py -Arguments @('install', '--no-build-isolation', '--force-reinstall', '--no-deps', $tvmFfiSrc)
    } else {
        Write-Warning "vendored tvm-ffi source not at $tvmFfiSrc - falling back to the PyPI apache-tvm-ffi (import may fail 127)"
    }
    $staged = @(Save-PythonWheel -SourceDir $wheelOut -WheelDir 'C:\runtime\wheels' -Required)
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--no-deps', '--only-binary', ':all:', $staged[0])
    # --no-deps starves the runtime deps: typing_extensions is a hard import, the rest best-effort.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'typing_extensions')
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', '--only-binary', ':all:', 'ml_dtypes', 'cloudpickle', 'psutil') -Optional
    Test-PythonImport -Python $py -ModuleName 'tvm'
}

if ($tvmRocmPlan.OnLane) {
    # The sidecars install beside tvm_runtime.dll (TVM's RUNTIME_MODULE rule); a miss here is a packaging break.
    $tvmSidecars = @('tvm_runtime_opencl.dll') + @(if ($tvmRocmPlan.Rocm) { 'tvm_runtime_rocm.dll' })
    foreach ($sidecar in $tvmSidecars) {
        if (-not (Test-Path (Join-Path $tvmInstallDir "lib\$sidecar"))) { throw "TVM rocm lane: $sidecar missing from $tvmInstallDir\lib" }
    }
    if ($pythonModule -eq 'ON') {
        # The wheel must load the sidecars too. TheRock's bin stands in for the driver's System32 amdhip64_7.dll.
        $rocmGate = Join-Path $env:TEMP 'tvm-rocm-gate.py'
        @'
import os, sys
os.add_dll_directory(sys.argv[1])
import tvm
for kind in sys.argv[2].split(","):
    assert tvm.runtime.enabled(kind), kind + " runtime sidecar did not load from the tvm wheel"
print("tvm rocm-lane runtime gate OK:", sys.argv[2])
'@ | Set-Content -Path $rocmGate -Encoding ascii
        $gateKinds = if ($tvmRocmPlan.Rocm) { 'opencl,rocm' } else { 'opencl' }
        [void](Invoke-ShieldedNative -Label 'TVM rocm-lane runtime gate' -CommandLine """$($py.Exe)"" ""$rocmGate"" ""$(Join-Path $tvmRocmPlan.RocmRoot 'bin')"" ""$gateKinds""")
        Remove-Item $rocmGate -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path (Join-Path $tvmInstallDir 'ROCM-FEATURES.txt') -Encoding ascii -Value (Get-TvmRocmFeatureMarker -Plan $tvmRocmPlan -LlvmTargets $tvmLlvmTargetsBuilt)
}
if ($tvmRocmPlan.HideRocmPath -and $null -ne $savedRocmPath) { $env:ROCM_PATH = $savedRocmPath }

Remove-SourceBuildTree -Path $SourceDir

# QNN runtime staging (#121): stage the backend DLLs beside the TVM install.
if ($qnnSdk) { [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $tvmInstallDir) }

Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0