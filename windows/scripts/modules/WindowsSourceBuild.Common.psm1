# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

# Load sub-modules for patch and GPU utilities (split out to reduce this module's size).
$patchesPath = Join-Path $PSScriptRoot 'WindowsSourceBuild.Patches.psm1'
$cudaPath    = Join-Path $PSScriptRoot 'WindowsSourceBuild.Cuda.psm1'
if (Test-Path $patchesPath) { Import-Module $patchesPath -Force }
if (Test-Path $cudaPath)    { Import-Module $cudaPath -Force }

function Get-SourceBuildVersion {
    param(
        [string]$Value = '',
        [string[]]$EnvironmentVariables = @(),
        [string]$DefaultValue = '',
        [switch]$StripVPrefix
    )

    $resolved = $DefaultValue
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $resolved = $Value
    } else {
        foreach ($envVar in $EnvironmentVariables) {
            if (-not [string]::IsNullOrWhiteSpace($envVar)) {
                $envValue = [Environment]::GetEnvironmentVariable($envVar)
                if (-not [string]::IsNullOrWhiteSpace($envValue)) { $resolved = $envValue; break }
            }
        }
    }

    if ($StripVPrefix) { $resolved = $resolved -replace '^v', '' }
    return $resolved
}

function Invoke-GitClone {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [string]$Branch = '',
        [string]$Tag = '',
        [switch]$Recursive,
        [switch]$SkipOnFailure,
        [int]$Depth = 1
    )

    if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }

    $ref = if ($Tag) { $Tag } else { $Branch }
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'Either -Branch or -Tag is required' }

    $gitArgs = @('clone')
    if ($Recursive) { $gitArgs += '--recursive' }
    $gitArgs += '--branch', $ref
    $gitArgs += '--depth', $Depth
    $gitArgs += $RepoUrl, $SourceDir

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'

    $null = & git @gitArgs 2>&1
    $cloneExit = $LASTEXITCODE

    $ErrorActionPreference = $oldEAP

    if ($cloneExit -ne 0) {
        if ($SkipOnFailure) {
            Write-Warning "git clone failed (exit $cloneExit) - skipped"
            return $false
        }
        throw "git clone failed (exit $cloneExit): $RepoUrl $ref"
    }
    return $true
}

function Invoke-CmakeConfigure {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [Parameter(Mandatory)]
        [string]$InstallPrefix,
        [string]$Generator = 'Ninja',
        [string]$Platform = '',
        [string]$Toolset = '',
        [string]$BuildType = 'Release',
        [string]$CCompiler = 'clang-cl',
        [string]$CxxCompiler = 'clang-cl',
        [string]$Linker = 'lld-link',
        [string]$Archiver = 'llvm-lib',
        [string[]]$ExtraArgs = @(),
        [switch]$SkipOnFailure
    )

    New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
    New-Item -Path $InstallPrefix -ItemType Directory -Force | Out-Null

    $cmakeArgs = @('-S', $SourceDir, '-B', $BuildDir, "-DCMAKE_INSTALL_PREFIX=$InstallPrefix")

    if ($Generator) {
        $cmakeArgs += '-G', $Generator
        if ($Platform) { $cmakeArgs += '-A', $Platform }
        if ($Toolset) { $cmakeArgs += '-T', $Toolset }
    }

    if ($BuildType) { $cmakeArgs += "-DCMAKE_BUILD_TYPE=$BuildType" }
    if ($CCompiler) { $cmakeArgs += "-DCMAKE_C_COMPILER=$CCompiler" }
    if ($CxxCompiler) { $cmakeArgs += "-DCMAKE_CXX_COMPILER=$CxxCompiler" }
    if ($Linker) { $cmakeArgs += "-DCMAKE_LINKER=$Linker" }
    if ($Archiver) { $cmakeArgs += "-DCMAKE_AR=$Archiver" }

    if (Test-SccacheRemoteConfigured) {
        $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
        if ($sccacheCmd) {
            if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
            $cmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
            $cmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
            Write-Host "sccache enabled at: $($sccacheCmd.Source) (remote backend, max $env:SCCACHE_MAX_JOBS jobs)"
        }
    } else {
        Write-Host 'sccache disabled (no remote backend configured; a container-local cache would only bloat layers)'
    }

    if ($ExtraArgs.Count -gt 0) { $cmakeArgs += $ExtraArgs }

    Write-Host "CMake configure: $($cmakeArgs -join ' ')"
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) {
        if ($SkipOnFailure) {
            Write-Warning "CMake configuration failed - skipped"
            return $false
        }
        throw "CMake configuration failed"
    }
    return $true
}

function Test-SccacheRemoteConfigured {
    # True when any sccache remote backend is configured. Shared by the cmake
    # launcher wiring (Invoke-CmakeConfigure) and the end-of-build stats dump --
    # without a remote there is no cache, so neither should activate.
    return (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_WEBDAV_ENDPOINT)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_BUCKET)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_REDIS_ENDPOINT))
}

function Write-SccacheStats {
    # Dump sccache's hit/miss counters into the build log. The counters live in the
    # sccache server, which dies with the container at the end of a run+commit step,
    # so this is the only moment the numbers exist -- the host cannot query them
    # after the run. Tee'd run output lands them in the host-side branch log, where
    # they answer "is the remote cache actually hitting or are we compiling cold?".
    # Never fails the build: stats are diagnostics, not a gate.
    param([string]$Label = 'build')
    if (-not (Test-SccacheRemoteConfigured)) { return }
    $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
    if (-not $sccacheCmd) { return }
    Write-Host "`n=== sccache stats ($Label) ==="
    # cmd.exe routing: sccache may write diagnostics to stderr, which PS 5.1 under
    # EAP=Stop escalates into a terminating NativeCommandError even through 2>&1.
    cmd.exe /c """$($sccacheCmd.Source)"" --show-stats 2>&1" | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Write-Host "(sccache --show-stats exited $LASTEXITCODE -- stats unavailable)" }
}

function Enter-VsDevCmdEnvironment {
    param(
        [string]$Arch = 'amd64',
        [string]$HostArch = 'amd64',
        [string]$VsDevCmdPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($VsDevCmdPath)) {
        $vsPath = Get-VsInstallPath
        $VsDevCmdPath = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    }
    if (-not (Test-Path $VsDevCmdPath)) { throw "VsDevCmd.bat not found at: $VsDevCmdPath" }

    cmd /c """$VsDevCmdPath"" -arch=$Arch -host_arch=$HostArch && set" | ForEach-Object {
        if ($_ -match '^(.*?)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
}

function Get-VsInstallPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere - Visual Studio Installer missing" }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) { throw 'No Visual Studio installation with VC Tools x86/x64 found via vswhere' }
    return $vsPath
}

function Get-MsvcToolsRoot {
    $vsPath = Get-VsInstallPath
    $msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
    $dirs = Get-ChildItem -Path $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $dirs) { throw "No MSVC toolchain found under $msvcRoot" }
    return $dirs[0].FullName
}

function Resolve-LlvmArchiver {
    $llvmLib = (Get-Command 'llvm-lib' -ErrorAction SilentlyContinue).Source
    if (-not $llvmLib) { $llvmLib = (Get-Command 'llvm-lib.exe' -ErrorAction SilentlyContinue).Source }
    return $llvmLib
}

function Copy-CpythonPyConfigHeader {
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $src = Join-Path $CpythonDir 'PC\pyconfig.h'
    $dst = Join-Path $CpythonDir 'Include\pyconfig.h'
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        Copy-Item $src $dst -Force
        Write-Host "Copied pyconfig.h to Include/ (from $src)"
    }
}

function Get-SourceBuildPython {
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $exe = Join-Path $CpythonDir 'PCbuild\amd64\python.exe'
    $include = Join-Path $CpythonDir 'Include'
    $libDir = Join-Path $CpythonDir 'PCbuild\amd64'
    $lib = if (Test-Path (Join-Path $libDir 'python314.lib')) { Join-Path $libDir 'python314.lib' } else { Join-Path $libDir 'python3.lib' }
    return @{ Exe = $exe; Include = $include; LibDir = $libDir; Lib = $lib }
}

function Initialize-SourceBuildEnvironment {
    param(
        [string]$InstallDir = ''
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }
    return $InstallDir
}

function Initialize-SourceBuildScript {
    # Standard preamble for the build-*-from-source.ps1 scripts: resolve the install
    # prefix (default C:\runtime) and load canonical versions.env values into the
    # process environment (so Get-SourceBuildVersion sees them). Returns the resolved
    # InstallDir. Scripts with work between the two steps (build-gstreamer's logging
    # setup) call the underlying functions directly instead.
    param(
        [string]$InstallDir = '',
        [string]$ScriptRoot = ''
    )
    $resolved = Initialize-SourceBuildEnvironment -InstallDir $InstallDir
    Import-CanonicalVersions -ScriptRoot $ScriptRoot
    return $resolved
}

function Get-WindowsX86SimdFlags {
    return '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'
}

function Get-WindowsX86Avx512Flags {
    return '/clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'
}

function Install-CpythonPip {
    param(
        [hashtable]$Python = $null
    )
    if (-not $Python) { $Python = Get-SourceBuildPython }
    if (-not (Test-Path $Python.Exe)) { throw "Source-built Python not found at $($Python.Exe)" }
    cmd.exe /c """$($Python.Exe)"" -m pip --version >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Host 'pip already installed'; return }
    Write-Host 'Bootstrapping pip via get-pip.py...'
    $pipScript = Join-Path $env:TEMP 'get-pip.py'
    Invoke-DownloadWithRetry -Url 'https://bootstrap.pypa.io/get-pip.py' -DestinationPath $pipScript
    cmd.exe /c """$($Python.Exe)"" ""$pipScript"" --quiet 2>&1"
    if ($LASTEXITCODE -ne 0) { throw 'get-pip.py failed' }
    Remove-Item $pipScript -Force -ErrorAction SilentlyContinue
}

function Invoke-CpythonPip {
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Optional
    )
    if (-not (Test-Path $Python.Exe)) { throw "Source-built Python not found at $($Python.Exe)" }
    $argLine = $Arguments -join ' '
    cmd.exe /c """$($Python.Exe)"" -m pip $argLine 2>&1"
    $exit = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exit -ne 0) {
        $msg = "pip $argLine failed (exit $exit)"
        if ($Optional) { Write-Warning "$msg -- continuing"; return }
        throw $msg
    }
}

function Copy-BuildArtifact {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][object[]]$Map,
        [switch]$Recurse
    )
    foreach ($entry in $Map) {
        $destDir = Join-Path $InstallDir $entry.Dest
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        $count = 0
        foreach ($filter in @($entry.Filter)) {
            Get-ChildItem -Path $BuildDir -Filter $filter -Recurse:$Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item $_.FullName -Destination $destDir -Force -ErrorAction SilentlyContinue
                $count++
            }
        }
        Write-Host ("Staged {0} {1} -> {2}" -f $count, (@($entry.Filter) -join '/'), $destDir)
    }
}

function Remove-MakefileShowIncludes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StripWildcardInclude
    )
    if (-not (Test-Path $Path)) { return }
    $c = [System.IO.File]::ReadAllText($Path)
    $c = $c -replace '-showIncludes', ''
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    if ($StripWildcardInclude) { $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', '' }
    [System.IO.File]::WriteAllText($Path, $c)
}

function Remove-SourceBuildTree {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )
    if ($env:KEEP_BUILD_ARTIFACTS -eq '1') {
        Write-Host "KEEP_BUILD_ARTIFACTS=1 - keeping: $($Path -join ', ')"
        return
    }
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path $p)) { continue }
        if ((Get-Location).Path -like "$p*") { Set-Location (Split-Path $p -Parent) }
        Write-Host "Removing build tree: $p"
        & cmd.exe /c "rd /s /q ""$p""" 2>$null
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BuildJobCount {
    param(
        [int]$MemGBPerJob = 4
    )
    if ($env:BUILD_JOBS -match '^\d+$') { return [int]$env:BUILD_JOBS }
    $cores = [Environment]::ProcessorCount
    $memGB = 0
    if ($env:MEMORY_LIMIT_GB -match '^\d+$') {
        $memGB = [int]$env:MEMORY_LIMIT_GB
    } else {
        try {
            $memGB = [int][Math]::Floor((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB)
        } catch { $memGB = 0 }
    }
    if ($memGB -le 0) { return $cores }
    return [Math]::Max(2, [Math]::Min($cores, [int][Math]::Floor($memGB / $MemGBPerJob)))
}

function Invoke-NinjaBuildWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [int]$RetryJobs = 1,
        [int]$MemGBPerJob = 4,
        [string]$LogFile = '',
        [switch]$Install,
        [string]$InstallConfig = 'Release'
    )
    $env:NINJA_STATUS = "[%f/%t] "
    $jobs = Get-BuildJobCount -MemGBPerJob $MemGBPerJob
    $ninjaKeep = if ($env:NINJA_KEEP_GOING -eq '1') { @('-k', '0') } else { @() }
    Write-Host "Building with ninja -j$jobs..."
    if ($LogFile) {
        ninja -j $jobs @ninjaKeep -C $BuildDir 2>&1 | Tee-Object -FilePath $LogFile
    } else {
        ninja -j $jobs @ninjaKeep -C $BuildDir 2>&1
    }
    if ($LASTEXITCODE -ne 0 -and $jobs -gt $RetryJobs) {
        Write-Host "ninja -j$jobs failed (exit $LASTEXITCODE) - retrying incrementally with -j$RetryJobs..."
        if ($LogFile) {
            ninja -j $RetryJobs @ninjaKeep -C $BuildDir 2>&1 | Tee-Object -FilePath $LogFile -Append
        } else {
            ninja -j $RetryJobs @ninjaKeep -C $BuildDir 2>&1
        }
    }
    if ($LASTEXITCODE -ne 0) {
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "`n=== BUILD FAILED - last 50 lines ==="
            Get-Content $LogFile -Tail 50 | ForEach-Object { Write-Host $_ }
        }
        throw "Build failed (exit $LASTEXITCODE)"
    }
    if ($Install) {
        Write-Host "Installing..."
        & cmake --install $BuildDir --config $InstallConfig
        if ($LASTEXITCODE -ne 0) { throw "Install failed" }
    }
}

function Expand-SourceTarball {
    param(
        [Parameter(Mandatory)]
        [string]$Archive,
        [Parameter(Mandatory)]
        [string]$Destination
    )
    & 7z x "$Archive" -o"$Destination" -y -bd 2>&1 | Out-Null
    $tarFile = Get-ChildItem -Path $Destination -Filter '*.tar' | Select-Object -First 1 -ExpandProperty FullName
    if ($tarFile) { & 7z x "$tarFile" -o"$Destination" -y -bd 2>&1 | Out-Null }
    $srcDir = Get-ChildItem -Path $Destination -Directory | Select-Object -First 1 -ExpandProperty FullName
    if (-not $srcDir) { throw "Failed to locate extracted source directory under $Destination" }
    return $srcDir
}

function Initialize-ExtractedGitRepo {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    cmd.exe /c "git -C ""$Path"" init >nul 2>&1"
}

function Import-CanonicalVersions {
    param(
        [string]$ScriptRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = Split-Path $PSScriptRoot -Parent }
    $versionsScript = Join-Path $ScriptRoot 'load-versions.ps1'
    if (Test-Path $versionsScript) { & $versionsScript }
}

function Get-LlvmArchiverCmakeArg {
    $llvmLib = Resolve-LlvmArchiver
    if ($llvmLib) { return @("-DCMAKE_AR:FILEPATH=$llvmLib") }
    return @()
}

function Initialize-PythonPlatformTag {
    # Clang-built CPython's sys.version lacks the "64 bit (AMD64)" marker that
    # sysconfig.get_platform() keys on, so the 64-bit interpreter reports win32:
    # pip then resolves 32-bit wheels (numpy import dies on a cp314-win32 pyd)
    # and locally-built wheels get mis-tagged. _PYTHON_HOST_PLATFORM is POSIX-only,
    # so drop a sitecustomize.py shim forcing win-amd64 (verified 2026-07-12).
    param([string]$CpythonDir = '')
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $sitePackages = Join-Path $CpythonDir 'Lib\site-packages'
    New-Item -Path $sitePackages -ItemType Directory -Force | Out-Null
    $shim = Join-Path $sitePackages 'sitecustomize.py'
    Set-Content -Path $shim -Encoding ASCII -Value @'
# Written by Initialize-PythonPlatformTag (WindowsSourceBuild.Common.psm1).
# 1) Clang-built CPython lacks the "64 bit (AMD64)" marker in sys.version, so
#    sysconfig.get_platform() misreports win32 -> pip resolves 32-bit wheels and
#    locally-built wheels get mis-tagged.
# 2) Python 3.8+ ignores PATH when resolving extension-module dependencies;
#    register this image's native DLL homes (CUDA 13 keeps its runtime libs in
#    bin\x64, cuDNN 9 likewise) so cv2/onnxruntime/tvm pyds import cleanly.
import os
import sys
import sysconfig
if sysconfig.get_platform() == 'win32' and sys.maxsize > 2**32:
    sysconfig.get_platform = lambda: 'win-amd64'
if os.name == 'nt' and hasattr(os, 'add_dll_directory'):
    _dirs = []
    for _env in ('CUDA_PATH', 'CUDNN_ROOT'):
        _root = os.environ.get(_env) or ''
        if _root:
            _dirs += [os.path.join(_root, 'bin'), os.path.join(_root, 'bin', 'x64')]
    _trt = os.environ.get('TENSORRT_ROOT') or ''
    if _trt and os.path.isdir(_trt):
        for _n in os.listdir(_trt):
            if _n.startswith('TensorRT-'):
                _dirs.append(os.path.join(_trt, _n, 'lib'))
    _dirs += [
        r'C:\runtime\lib\opencv5\x64\vc18\bin',
        r'C:\runtime\lib\onnxruntime-source\bin',
        r'C:\runtime\lib\onnxruntime-source\lib',
        r'C:\runtime\lib\onnxruntime-genai-source\lib',
        r'C:\runtime\lib\tvm\lib',
        r'C:\runtime\ffmpeg\bin',
        r'C:\runtime\bin',
    ]
    for _d in _dirs:
        if os.path.isdir(_d):
            try:
                os.add_dll_directory(_d)
            except OSError:
                pass
'@
    Write-Host "Wrote python platform-tag + dll-directory shim: $shim"
    return $shim
}

function Test-PythonImport {
    # EAP=Stop-safe binding assert: a stderr-noisy SUCCESS (tvm prints [HH:MM:SS]
    # warnings to stderr on import) must not read as failure, so route through
    # cmd.exe (the house pattern for native stderr under EAP=Stop) and judge by
    # exit code only. Throws with the last output line on a real failure.
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$VersionExpression = ''
    )
    if (-not $VersionExpression) { $VersionExpression = "$ModuleName.__version__" }
    $out = cmd.exe /c """$($Python.Exe)"" -c ""import $ModuleName; print($VersionExpression)"" 2>&1"
    $code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $tail = if ($out) { (@($out) | Select-Object -Last 1).ToString().Trim() } else { '' }
    if ($code -ne 0) { throw "import $ModuleName failed right after install (exit $code): $tail" }
    Write-Host "$ModuleName python binding OK ($tail)"
}

function Save-PythonWheel {
    # Stage built wheel(s) into the central wheel store shipped in the image
    # (C:\runtime\wheels; the final image exposes it as PYTHON_WHEELS).
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [string]$Filter = '*.whl',
        [string]$WheelDir = 'C:\runtime\wheels',
        [switch]$Required
    )
    New-Item -Path $WheelDir -ItemType Directory -Force | Out-Null
    $wheels = @(Get-ChildItem -Path $SourceDir -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue)
    if ($wheels.Count -eq 0) {
        if ($Required) { throw "no wheel matching '$Filter' under $SourceDir" }
        Write-Warning "no wheel matching '$Filter' under $SourceDir -- skipping"
        return @()
    }
    foreach ($w in $wheels) {
        Copy-Item $w.FullName -Destination $WheelDir -Force
        Write-Host "Staged wheel: $($w.Name) -> $WheelDir"
    }
    return @($wheels | ForEach-Object { Join-Path $WheelDir $_.Name })
}

function Initialize-ToolchainPythonEnvironment {
    param(
        [string]$Arch = 'amd64',
        [string]$HostArch = 'amd64'
    )
    Enter-VsDevCmdEnvironment -Arch $Arch -HostArch $HostArch
    Copy-CpythonPyConfigHeader
    Initialize-PythonPlatformTag | Out-Null
    return Get-SourceBuildPython
}

function Invoke-SourceBuildChain {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Stages,
        [string]$InstallDir = 'C:\runtime',
        [string]$ScriptDir  = 'C:\temp\scripts'
    )
    $ErrorActionPreference = 'Stop'
    foreach ($stage in $Stages) {
        Write-Host "`n=== $Label stage: $($stage.Name) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
        & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($exitCode) { throw "$($stage.Name) build failed (exit $exitCode)" }
    }
}

function Copy-SidecarDll {
    param(
        [Parameter(Mandatory)][string]$SidecarName,
        [Parameter(Mandatory)][string]$SearchDir,
        [scriptblock]$SidecarFilter,
        [string]$BesidePrimary,
        [string]$InstallDir,
        [string]$Destination,
        [string]$Reason = 'the dependent DLL may fail to load at runtime'
    )
    if ($BesidePrimary) {
        $primary = Get-ChildItem -Path $InstallDir -Filter $BesidePrimary -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $primary) { return }
        $Destination = $primary.DirectoryName
    }
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'Copy-SidecarDll: need -Destination or -BesidePrimary/-InstallDir' }

    $sidecar = Get-ChildItem -Path $SearchDir -Filter $SidecarName -Recurse -File -ErrorAction SilentlyContinue
    if ($SidecarFilter) { $sidecar = $sidecar | Where-Object $SidecarFilter }
    $sidecar = $sidecar | Select-Object -First 1
    if ($sidecar) {
        Copy-Item -LiteralPath $sidecar.FullName -Destination $Destination -Force
        Write-Host "Staged $SidecarName ($($sidecar.FullName)) -> $Destination"
    } else {
        Write-Warning "$SidecarName not found under $SearchDir -- $Reason"
    }
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-SourceBuildChain',
    'Invoke-GitClone',
    'Invoke-CmakeConfigure',
    'Test-SccacheRemoteConfigured',
    'Write-SccacheStats',
    'Enter-VsDevCmdEnvironment',
    'Get-VsInstallPath',
    'Get-MsvcToolsRoot',
    'Copy-CpythonPyConfigHeader',
    'Get-SourceBuildPython',
    'Edit-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Invoke-InlineRegexPatch',
    'Add-FileBlockOnce',
    'Edit-SourceFile',
    'Invoke-NinjaBuildWithRetry',
    'Expand-SourceTarball',
    'Initialize-ExtractedGitRepo',
    'Import-CanonicalVersions',
    'Get-CudaRoot',
    'Resolve-TensorRtRoot',
    'Get-GpuEnvironment',
    'Get-CudaArchitectureList',
    'Get-CudaToolkitRootArg',
    'Get-CudnnLibrary',
    'Get-LlvmArchiverCmakeArg',
    'Initialize-SourceBuildEnvironment',
    'Initialize-SourceBuildScript',
    'Initialize-ToolchainPythonEnvironment',
    'Initialize-PythonPlatformTag',
    'Save-PythonWheel',
    'Test-PythonImport',
    'Remove-SourceBuildTree',
    'Get-BuildJobCount',
    'Install-CpythonPip',
    'Invoke-CpythonPip',
    'Copy-BuildArtifact',
    'Copy-SidecarDll',
    'Remove-MakefileShowIncludes',
    'Get-NvccCudaCmakeArgs',
    'Get-WindowsX86SimdFlags',
    'Get-WindowsX86Avx512Flags',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)
