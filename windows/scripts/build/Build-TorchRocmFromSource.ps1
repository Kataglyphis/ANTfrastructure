# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds the torch wheel for Windows ROCm from upstream source against TheRock (rocm lane only).
.DESCRIPTION
    Follows TheRock's build_prod_wheels.py; Build-TorchvisionRocmFromSource.ps1 dot-sources this file for its helpers.
    See docs/windows-rocm.md § PyTorch on the rocm lane (torch stage).
.PARAMETER OutputDir
    Receives exactly torch-<v>+rocm<r>-cp314-cp314-win_amd64.whl.
.PARAMETER WorkDir
    Sources, build venv and tree, short for Windows path limits; the venv stays for the torchvision RUN.
#>
param(
    [string]$OutputDir = 'C:\torch-rocm-wheels',
    [string]$WorkDir = 'C:\b'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
foreach ($module in 'WindowsScripts.Shared.psm1', 'WindowsNative.Common.psm1', 'WindowsSourceBuild.Common.psm1', 'WindowsMigraphx.Common.psm1') {
    $modulePath = Join-Path $scriptAssetRoot "modules\$module"
    if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
}

function Get-TorchRocmBuildVersion {
    # PYTORCH_VERSION-style tag (v2.14.0) + ROCM_WINDOWS_RELEASE -> the wheel's local version, AMD's shape.
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Release)
    $m = [regex]::Match($Version, '^v?(?<v>\d+\.\d+\.\d+)$')
    if (-not $m.Success) { throw "version pin '$Version' is not [v]x.y.z" }
    if ($Release -notmatch '^\d+\.\d+\.\d+$') { throw "ROCM_WINDOWS_RELEASE '$Release' is not x.y.z" }
    return "$($m.Groups['v'].Value)+rocm$Release"
}

function Assert-TorchRocmTreeVersion {
    # Upstream release tags keep an alpha version.txt (2.14.0a0); its x.y.z must still be the pinned one.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$VersionText, [Parameter(Mandatory)][string]$Version)
    $tree = [regex]::Match($VersionText.Trim(), '^\d+\.\d+\.\d+')
    $want = $Version -replace '^v', ''
    if (-not $tree.Success) { throw "$Name version.txt holds '$($VersionText.Trim())', not x.y.z[...]" }
    if ($tree.Value -ne $want) { throw "$Name commit is $($tree.Value) (version.txt), the version pin is $want" }
}

function Get-TorchRocmInitSource {
    # torch/_rocm_init.py as AMD's wheels carry it: torch imports it first and preloads ROCm from rocm_sdk.
    param([Parameter(Mandatory)][string]$Release)
    $names = "'amd_comgr', 'amdhip64', 'hiprtc', 'hipblas', 'hipfft', 'hiprand', 'hipsparse', 'hipsparselt', " +
        "'hipsolver', 'hipblaslt', 'miopen', 'hipdnn', 'rocm-openblas'"
    return @(
        'def initialize():'
        '    import rocm_sdk'
        '    rocm_sdk.initialize_process('
        "        preload_shortnames=[$names],"
        "        check_version='$Release')"
    ) -join "`n"
}

function Get-TorchRocmCommonEnv {
    # _setup_common_build_env on Windows, with the SDK root TheRock's rocm_sdk paths resolve to.
    param([Parameter(Mandatory)][string]$RocmRoot, [Parameter(Mandatory)][string]$GpuTargets)
    $llvmBin = Join-Path $RocmRoot 'lib\llvm\bin'
    $vars = [ordered]@{
        PYTHONUTF8        = '1'
        CMAKE_PREFIX_PATH = Join-Path $RocmRoot 'lib\cmake'
        ROCM_HOME         = $RocmRoot
        ROCM_PATH         = $RocmRoot
        PYTORCH_ROCM_ARCH = $GpuTargets
        USE_KINETO        = 'OFF'
        HIP_CLANG_PATH    = $llvmBin -replace '\\', '/'
        CC                = Join-Path $llvmBin 'clang-cl.exe'
        CXX               = Join-Path $llvmBin 'clang-cl.exe'
        DISTUTILS_USE_SDK = '1'
    }
    $bitcode = Join-Path $RocmRoot 'lib\llvm\amdgcn\bitcode'
    if (Test-Path -LiteralPath $bitcode) { $vars['HIP_DEVICE_LIB_PATH'] = $bitcode }
    $hostMath = Join-Path $RocmRoot 'lib\host-math'
    if (Test-Path -LiteralPath $hostMath) {
        $vars['BLAS'] = 'OpenBLAS'; $vars['OpenBLAS_HOME'] = $hostMath; $vars['OpenBLAS_LIB_NAME'] = 'rocm-openblas'
    }
    return $vars
}

function Get-TorchRocmTorchEnv {
    # The torch-only half of do_build_pytorch; AOTriton and torch.distributed off (docs say why).
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Common,
        [Parameter(Mandatory)][string]$BuildVersion,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][int]$Jobs,
        [switch]$Sccache
    )
    $vars = Copy-TorchRocmEnv -Common $Common -Jobs $Jobs
    $vars['USE_ROCM'] = 'ON'; $vars['USE_CUDA'] = 'OFF'; $vars['USE_MPI'] = 'OFF'; $vars['USE_NUMA'] = 'OFF'
    $vars['USE_FLASH_ATTENTION'] = 'OFF'; $vars['USE_MEM_EFF_ATTENTION'] = 'OFF'
    $vars['USE_DISTRIBUTED'] = '0'; $vars['USE_GLOO'] = 'OFF'
    $vars['BUILD_TEST'] = '0'
    $vars['PYTORCH_BUILD_VERSION'] = $BuildVersion; $vars['PYTORCH_BUILD_NUMBER'] = '1'
    $vars['PYTORCH_EXTRA_INSTALL_REQUIREMENTS'] = "rocm[libraries]==$Release"
    if ($Sccache) { $vars['CMAKE_C_COMPILER_LAUNCHER'] = 'sccache'; $vars['CMAKE_CXX_COMPILER_LAUNCHER'] = 'sccache' }
    return $vars
}

function Get-TorchRocmVisionEnv {
    # do_build_pytorch_vision: a fresh copy of the common env, HIP forced on a GPU-less host.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Common, [Parameter(Mandatory)][string]$BuildVersion, [Parameter(Mandatory)][int]$Jobs)
    $vars = Copy-TorchRocmEnv -Common $Common -Jobs $Jobs
    $vars['BUILD_VERSION'] = $BuildVersion; $vars['FORCE_CUDA'] = '1'
    $vars['TORCHVISION_USE_NVJPEG'] = '0'; $vars['TORCHVISION_USE_VIDEO_CODEC'] = '0'
    return $vars
}

function Copy-TorchRocmEnv {
    # Each build's env starts as its own copy of the common env, with the job count.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Common, [Parameter(Mandatory)][int]$Jobs)
    $vars = [ordered]@{}
    foreach ($k in $Common.Keys) { $vars[$k] = $Common[$k] }
    $vars['MAX_JOBS'] = "$Jobs"
    return $vars
}

function Get-TorchRocmWheelName {
    # The one wheel a build must leave, by its exact PEP 427 name.
    param([Parameter(Mandatory)][string]$Distribution, [Parameter(Mandatory)][string]$BuildVersion, [Parameter(Mandatory)][string]$PythonTag)
    return "$Distribution-$BuildVersion-$PythonTag-$PythonTag-win_amd64.whl"
}

function Assert-TorchRocmSystemLibomp {
    # VS 18 ships libomp140 only under debug_nonredist, so the wheel relies on System32's; see docs/windows-rocm.md § PyTorch on the rocm lane (torch stage).
    param([Parameter(Mandatory)][string]$System32)
    $dll = Join-Path $System32 'libomp140.x86_64.dll'
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "$dll is missing: torch_cpu.dll imports it (USE_OPENMP), so import torch would fail" }
    return $dll
}

function Assert-TorchRocmStagedWheel {
    # The output holds exactly the named wheels: the torch RUN leaves torch, the torchvision RUN adds its own.
    param([Parameter(Mandatory)][string]$OutputDir, [Parameter(Mandatory)][string[]]$Name)
    $staged = @(Get-ChildItem -LiteralPath $OutputDir -Filter '*.whl' -File | ForEach-Object Name | Sort-Object)
    $want = @($Name | Sort-Object)
    if (($staged -join '|') -ne ($want -join '|')) { throw "$OutputDir holds [$($staged -join ', ')], expected exactly [$($want -join ', ')]" }
}

function Set-TorchRocmProcessEnv {
    # One build's env into THIS process (the RUN ends with it); values print for the log.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Env)
    foreach ($k in $Env.Keys) {
        [Environment]::SetEnvironmentVariable($k, "$($Env[$k])", 'Process')
        Write-Host "  $k=$($Env[$k])"
    }
}

function Copy-TorchRocmVenvShim {
    # Without the base sitecustomize.py the clang-built CPython reports win32 and uv resolves 32-bit wheels.
    param([Parameter(Mandatory)][string]$BaseSitePackages, [Parameter(Mandatory)][string]$BasePythonDir, [Parameter(Mandatory)][string]$Venv)
    $shim = Join-Path $BaseSitePackages 'sitecustomize.py'
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) { throw "$shim not found: the build venv would report win32 and resolve 32-bit wheels" }
    Copy-Item -LiteralPath $shim -Destination (Join-Path $Venv 'Lib\site-packages') -Force
    $py3 = Join-Path $BasePythonDir 'python3.dll'
    if (Test-Path -LiteralPath $py3 -PathType Leaf) { Copy-Item -LiteralPath $py3 -Destination (Join-Path $Venv 'Scripts') -Force }
}

function Invoke-TorchRocmLogged {
    # Streams a long native build and keeps the whole of it on the persistent log mount.
    param([Parameter(Mandatory)][string]$CommandLine, [Parameter(Mandatory)][string]$WorkingDir, [Parameter(Mandatory)][string]$LogName)
    $log = Get-PersistentBuildLogPath -Name $LogName -FallbackDir $WorkDir
    Write-Host "  log: $log"
    Push-Location $WorkingDir
    try {
        & cmd.exe /s /c " $CommandLine 2>&1" | Tee-Object -FilePath $log
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) { throw "$LogName failed (exit $code); full log: $log" }
    $global:LASTEXITCODE = 0
}

function Save-TorchRocmTree {
    # One upstream tree at its pinned commit, held to its version pin; both RUNs start with it.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$CommitKey,
        [Parameter(Mandatory)][string]$VersionKey, [Parameter(Mandatory)][string]$WorkDir)
    & git config --global core.longpaths true
    $src = Save-GitCommitSource -Name $Name -Repository $Repository -Commit "$([Environment]::GetEnvironmentVariable($CommitKey))".Trim() -WorkDir $WorkDir
    Assert-TorchRocmTreeVersion -Name $CommitKey -Version "$([Environment]::GetEnvironmentVariable($VersionKey))".Trim() `
        -VersionText ([System.IO.File]::ReadAllText((Join-Path $src 'version.txt')))
    return $src
}

function Get-TorchRocmPythonTag {
    # The build venv's cpXY tag, which names the wheel a build must leave.
    param([Parameter(Mandatory)][string]$Python)
    $tag = "$(& $Python -c "import sys; print('cp' + str(sys.version_info[0]) + str(sys.version_info[1]))")".Trim()
    if ($tag -notmatch '^cp3\d+$') { throw "build venv python reports tag '$tag'" }
    return $tag
}

function Install-TorchRocmBuiltWheel {
    # The wheel a build left, by its exact name, installed into the build venv and imported there.
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$SourceDir, [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$BuildVersion, [Parameter(Mandatory)][string]$PythonTag, [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$LogPrefix, [Parameter(Mandatory)][string]$ImportCode)
    $wheel = Join-Path $SourceDir "dist\$(Get-TorchRocmWheelName -Distribution $Distribution -BuildVersion $BuildVersion -PythonTag $PythonTag)"
    if (-not (Test-Path -LiteralPath $wheel -PathType Leaf)) { throw "$Distribution build left no $wheel" }
    # Out-Null: the streamed build output belongs to the console; this function returns the wheel path alone.
    Invoke-TorchRocmLogged -CommandLine "uv pip install --python ""$Python"" --no-deps ""$wheel""" -WorkingDir $WorkDir -LogName "$LogPrefix-install.log" | Out-Null
    Invoke-TorchRocmLogged -CommandLine """$Python"" -c ""$ImportCode""" -WorkingDir $WorkDir -LogName "$LogPrefix-import.log" | Out-Null
    return $wheel
}

function Get-TorchRocmRuntimePin {
    # The pinned rocm sdist + core + libraries (TORCH_ROCM_WINDOWS_*), as rocm-1 installs them at run time.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Pins)
    $dists = [ordered]@{ ROCM = 'rocm'; SDK_CORE = 'rocm-sdk-core'; SDK_LIBRARIES = 'rocm-sdk-libraries' }
    foreach ($name in $dists.Keys) {
        $url = "$($Pins["TORCH_ROCM_WINDOWS_${name}_URL"])".Trim()
        $sha = "$($Pins["TORCH_ROCM_WINDOWS_${name}_SHA256"])".Trim().ToLowerInvariant()
        if (-not $url.StartsWith('https://stable.repo.amd.com/rocm/')) { throw "TORCH_ROCM_WINDOWS_${name}_URL must be an AMD stable-repo URL, got '$url'" }
        if ($sha -notmatch '^[0-9a-f]{64}$') { throw "TORCH_ROCM_WINDOWS_${name}_SHA256 must be a 64-hex SHA256, got '$sha'" }
        [pscustomobject]@{ Distribution = $dists[$name]; Url = $url; Sha256 = $sha; FileName = [uri]::UnescapeDataString(([uri]$url).Segments[-1]) }
    }
}

function Save-TorchRocmRuntimeWheel {
    # The build venv needs rocm_sdk: torch/_rocm_init.py runs on the `import torch` torchvision's setup does.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][object[]]$Pin)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    foreach ($p in $Pin) {
        $file = Join-Path $Dir $p.FileName
        Invoke-DownloadWithRetry -Url $p.Url -DestinationPath $file -ExpectedSha256 $p.Sha256 -Description $p.FileName
        "$($p.Distribution) @ $(([uri]$file).AbsoluteUri) --hash=sha256:$($p.Sha256)"
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

# Refuses off the rocm lane (Get-GpuEnvironment.HasRocm) and off amd64, before anything is fetched.
$build = Initialize-MigraphxBuild -InstallDir $OutputDir -ScriptRoot $PSScriptRoot -Component 'PyTorch'
$OutputDir = $build.InstallDir
$rocmRoot = $build.RocmRoot
$release = "$env:ROCM_WINDOWS_RELEASE".Trim()
$torchVersion = Get-TorchRocmBuildVersion -Version "$env:PYTORCH_VERSION".Trim() -Release $release
Write-Host "=== torch $torchVersion from source (TheRock $rocmRoot, $($build.GpuTargets)) ==="

$python = Start-MigraphxBuildSession -WorkDir $WorkDir
$jobs = Get-BuildJobCount -MemGBPerJob 5
try {
    Switch-BuildPhase '1. sources'
    $torchSrc = Save-TorchRocmTree -Name 'pytorch' -Repository 'https://github.com/pytorch/pytorch.git' `
        -CommitKey 'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT' -VersionKey 'PYTORCH_VERSION' -WorkDir $WorkDir
    # Submodule commits are the superproject's gitlinks: git verifies every object against them.
    Invoke-TorchRocmLogged -CommandLine 'git submodule update --init --recursive --depth 1 --jobs 8' -WorkingDir $torchSrc -LogName 'torch-rocm-submodules.log'

    Switch-BuildPhase '2. build venv'
    $venv = Join-Path $WorkDir 'venv'
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    $env:UV_NO_CACHE = '1'; $env:UV_LINK_MODE = 'copy'
    Invoke-TorchRocmLogged -CommandLine "uv venv --python ""$python"" ""$venv""" -WorkingDir $WorkDir -LogName 'torch-rocm-venv.log'
    $baseSite = "$(& $python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")".Trim()
    Copy-TorchRocmVenvShim -BaseSitePackages $baseSite -BasePythonDir (Split-Path $python -Parent) -Venv $venv
    $venvPlatform = "$(& $venvPy -c "import sysconfig; print(sysconfig.get_platform())")".Trim()
    if ($venvPlatform -ne 'win-amd64') { throw "build venv reports platform '$venvPlatform', not win-amd64" }
    Invoke-TorchRocmLogged -CommandLine ("uv pip install --python ""$venvPy"" -r requirements.txt -r requirements-build.txt build") `
        -WorkingDir $torchSrc -LogName 'torch-rocm-deps.log'
    # The system ninja (>= 1.13.1): PyPI's hangs (1.11.1) or breaks link.exe response files (1.13.0).
    [void](Invoke-ShieldedNative -Label 'uv pip uninstall ninja' -Optional -CommandLine "uv pip uninstall --python ""$venvPy"" ninja")
    $pins = @{}
    foreach ($k in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { "$_" -like 'TORCH_ROCM_WINDOWS_*' })) { $pins["$k"] = [Environment]::GetEnvironmentVariable("$k") }
    $req = Join-Path $WorkDir 'rocm-runtime.txt'
    Set-Content -LiteralPath $req -Encoding utf8 -Value @(Save-TorchRocmRuntimeWheel -Dir (Join-Path $WorkDir 'rocm-runtime') -Pin @(Get-TorchRocmRuntimePin -Pins $pins))
    $env:ROCM_SDK_TARGET_FAMILY = ($build.GpuTargets -split ';')[-1]; $env:ROCM_BOOTSTRAP_DISABLE_DETECTION = '1'
    Invoke-TorchRocmLogged -CommandLine ("uv pip install --python ""$venvPy"" --no-deps --no-index --no-build-isolation --require-hashes -r ""$req""") `
        -WorkingDir $WorkDir -LogName 'torch-rocm-runtime.log'
    $pyTag = Get-TorchRocmPythonTag -Python $venvPy

    Switch-BuildPhase '3. torch (HIPIFY + wheel)'
    Invoke-TorchRocmLogged -CommandLine """$venvPy"" tools/amd_build/build_amd.py" -WorkingDir $torchSrc -LogName 'torch-rocm-hipify.log'
    Set-Content -LiteralPath (Join-Path $torchSrc 'torch\_rocm_init.py') -Encoding ascii -Value (Get-TorchRocmInitSource -Release $release)
    Write-Host "  OpenMP runtime: $(Assert-TorchRocmSystemLibomp -System32 ([Environment]::SystemDirectory))"
    $common = Get-TorchRocmCommonEnv -RocmRoot $rocmRoot -GpuTargets $build.GpuTargets
    Set-TorchRocmProcessEnv -Env (Get-TorchRocmTorchEnv -Common $common -BuildVersion $torchVersion -Release $release -Jobs $jobs `
            -Sccache:(Test-SccacheRemoteConfigured))
    $env:PATH = "$(Join-Path $rocmRoot 'bin');$env:PATH"
    Invoke-TorchRocmLogged -WorkingDir $torchSrc -LogName 'torch-rocm-wheel.log' -CommandLine ("""$venvPy"" -m build --wheel --no-isolation --skip-dependency-check " +
        '-Cwheel.force-include.torch/_rocm_init.py=torch/_rocm_init.py')
    $torchWheel = Install-TorchRocmBuiltWheel -Python $venvPy -SourceDir $torchSrc -Distribution 'torch' -BuildVersion $torchVersion `
        -PythonTag $pyTag -WorkDir $WorkDir -LogPrefix 'torch-rocm' `
        -ImportCode 'import torch; print(torch.__version__, torch.version.hip, torch.version.rocm, torch._C._cuda_getArchFlags())'

    Switch-BuildPhase '4. stage the torch wheel'
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Copy-Item -LiteralPath $torchWheel -Destination $OutputDir -Force
    Assert-TorchRocmStagedWheel -OutputDir $OutputDir -Name (Split-Path $torchWheel -Leaf)
    Remove-Item -LiteralPath (Join-Path $WorkDir 'rocm-runtime') -Recurse -Force
    Complete-CurrentBuildPhase
} catch {
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'PyTorch ROCm'
    throw
}

# Only the torch tree goes: the torchvision RUN (Build-TorchvisionRocmFromSource.ps1) builds in this venv.
Complete-MigraphxBuildSession -Label 'PyTorch ROCm' -WorkDir $torchSrc -Banner "=== torch $torchVersion built ($OutputDir); build venv kept in $WorkDir ==="
