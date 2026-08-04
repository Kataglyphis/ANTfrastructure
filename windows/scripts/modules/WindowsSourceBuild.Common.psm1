# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

# Load sub-modules for patch and GPU utilities (split out to reduce this module's size).
$patchesPath = Join-Path $PSScriptRoot 'WindowsSourceBuild.Patches.psm1'
$cudaPath    = Join-Path $PSScriptRoot 'WindowsSourceBuild.Cuda.psm1'
$nativePath  = Join-Path $PSScriptRoot 'WindowsNative.Common.psm1'
if (Test-Path $patchesPath) { Import-Module $patchesPath -Force }
if (Test-Path $cudaPath)    { Import-Module $cudaPath -Force }
# Canonical stderr-shield for native calls (Invoke-ShieldedNative) — imported
# and re-exported here so every source-build script gets it with its usual
# SourceBuild.Common import. Ship WindowsNative.Common.psm1 in every COPY
# list that carries this module; the stub keeps the re-export valid and the
# failure loud if a COPY list ever misses it.
if (Test-Path $nativePath) {
    Import-Module $nativePath -Force
} else {
    function Invoke-ShieldedNative {
        throw 'Invoke-ShieldedNative unavailable: WindowsNative.Common.psm1 is not next to WindowsSourceBuild.Common.psm1 (incomplete modules COPY list)'
    }
}

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

    # MOUNT-FRIENDLY reset: when $SourceDir is a BuildKit cache-mount target
    # (RUN --mount=type=cache,target=<SourceDir> — the BK lane puts the heavy
    # source/build churn there so the container scratch stays calm, see
    # docs/windows-builds.md § BuildKit/containerd lane), the directory ITSELF
    # cannot be removed ("used by another process"). Clear its CONTENTS then;
    # git can clone into an existing empty directory. A non-empty leftover
    # tree (previous run, KEEP_BUILD_ARTIFACTS) is wiped either way — callers
    # that want incremental reuse skip the clone before calling this.
    if (Test-Path $SourceDir) {
        try {
            Remove-Item $SourceDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "Invoke-GitClone: cannot remove $SourceDir (mount point?) - clearing contents instead"
            Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            if (@(Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction SilentlyContinue).Count -ne 0) {
                throw "Invoke-GitClone: $SourceDir could be neither removed nor emptied"
            }
        }
    }

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

# Test-SccacheRemoteConfigured now lives in WindowsScripts.Shared.psm1 (imported
# above) so WindowsCMake.Common/WindowsBuild.Common can gate on the same check;
# it is still re-exported from this module for existing consumers.

function Write-SccacheStats {
    # Dump sccache's hit/miss counters into the build log. The counters live in the
    # sccache server, which dies with the container at the end of a run+commit step,
    # so this is the only moment the numbers exist -- the host cannot query them
    # after the run. Tee'd run output lands them in the host-side branch log, where
    # they answer "is the remote cache actually hitting or are we compiling cold?".
    # Never fails the build: stats are diagnostics, not a gate.
    #
    # Only the Write-Host sink is local; reading the counters is
    # Get-SccacheStatsText (WindowsScripts.Shared). -RequireRemote keeps the
    # "silent no-op without a remote backend" contract -- querying would spawn a
    # local sccache server as a side effect.
    param([string]$Label = 'build')
    $lines = Get-SccacheStatsText -RequireRemote
    if ($null -eq $lines) { return }
    Write-Host "`n=== sccache stats ($Label) ==="
    $lines | ForEach-Object { Write-Host $_ }
}

function Enter-VsDevCmdEnvironment {
    param(
        [string]$Arch = 'amd64',
        [string]$HostArch = 'amd64',
        [string]$VsDevCmdPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($VsDevCmdPath)) {
        # Direct call to Shared's finder (the old Get-VsInstallPath passthrough
        # was deleted 2026-08-03 — NB it had this ONE module-internal caller,
        # which the "zero callers" audit sweep missed and no test covers
        # because Enter-VsDevCmdEnvironment needs a real VS install).
        $vsPath = Get-VisualStudioInstallPath
        $VsDevCmdPath = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    }
    if (-not (Test-Path $VsDevCmdPath)) { throw "VsDevCmd.bat not found at: $VsDevCmdPath" }

    cmd /c """$VsDevCmdPath"" -arch=$Arch -host_arch=$HostArch && set" | ForEach-Object {
        if ($_ -match '^(.*?)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
}

# Both of these are the throwing face of the shared vswhere discovery in
# WindowsScripts.Shared.psm1 (Get-VisualStudioInstallPath / Get-MsvcToolsRoots).
# Source builds want the hard failure: no Visual Studio means no build, and the
# callers (build-onnx-genai-from-source.ps1, build-litert-lm-from-source.ps1)
# either propagate it or wrap it in their own try/catch.
function Get-MsvcToolsRoot {
    # @() re-wrap is LOAD-BEARING: PowerShell flattens a single-element array on
    # return, so with exactly ONE installed toolset `(...)[0]` indexed a STRING
    # and returned 'C' — which sent the GenAI yvals_core.h clang patch at
    # 'C\include\yvals_core.h' (a silent no-op) and let STL1009 kill the build.
    # Old VS images had several toolsets, masking this since the consolidation.
    return @(Get-MsvcToolsRoots)[0]
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
    # NEVER put these in global CXX flags. Field-proven on 2026-08-03 (ORT
    # v1.28, AVX2-only 5950X): globally, clang may emit AVX-512 anywhere — the
    # in-tree protoc AND onnxruntime.dll's static initializers both crashed at
    # RUN/LOAD time with STATUS_ILLEGAL_INSTRUCTION. But entirely without them
    # MLAS's arch TUs (qgemm_kernel_amx, intrinsics/avx512/*) fail to COMPILE:
    # clang-cl gates intrinsics behind target features and ORT's mlas.cmake
    # adds no per-file -m flags on its MSVC branch. The settled design:
    # build-onnx-from-source.ps1 appends this string per-TU to exactly those
    # MLAS FLAGS lines in build.ninja post-configure — the only place the
    # features may be assumed, because those kernels are runtime-dispatched.
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

# (Remove-MakefileShowIncludes moved into build-ffmpeg-from-source.ps1 on
# 2026-08-03: FFmpeg was its only consumer, ever, and keeping it here forced
# all three media branches to rebuild whenever the FFmpeg-specific fixup moved.)

function Invoke-PythonWheelBuild {
    # Shared wheel-build shape used by the ONNX + GenAI scripts (was duplicated
    # verbatim): cd into the source dir, run python through the cmd.exe stderr
    # shield (setup.py/pip log to stderr under EAP=Stop), gate on the exit code,
    # then install the freshest wheel from the dist dir via the staged-wheel path.
    param(
        [Parameter(Mandatory)] $Python,           # Get-SourceBuildPython object
        [Parameter(Mandatory)] [string]$WorkingDir,
        [Parameter(Mandatory)] [string]$Arguments, # e.g. 'setup.py bdist_wheel'
        [Parameter(Mandatory)] [string]$ModuleName,
        [string]$DistDir = '',
        [switch]$NoDeps
    )
    if (-not $DistDir) { $DistDir = Join-Path $WorkingDir 'dist' }
    Push-Location $WorkingDir
    try {
        cmd.exe /c """$($Python.Exe)"" $Arguments 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "python wheel build failed (exit $LASTEXITCODE): $Arguments" }
    } finally { Pop-Location }
    return Install-StagedPythonWheel -Python $Python -SourceDir $DistDir -ModuleName $ModuleName -NoDeps:$NoDeps
}

function Remove-SourceBuildTree {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )
    if ($env:KEEP_BUILD_ARTIFACTS -eq '1') {
        Write-Host "KEEP_BUILD_ARTIFACTS=1 - keeping: $($Path -join ', ')"
        # Same contract as the normal exit below: this call never carries an
        # exit code, on ANY path (the early return must not leak a stale one).
        $global:LASTEXITCODE = 0
        return
    }
    # Kill lingering compiler daemons BEFORE deleting the tree, not after: a
    # daemon holding a handle into the tree (mspdbsrv on a PDB, an MSBuild
    # node, vctip) turns every deleted-while-open file into a PENDING-DELETE
    # zombie. Those zombies live until the container is torn down and then
    # break the BuildKit snapshot finalize (hcsshim::ExportLayer 0x3 "path
    # not found", 2026-08-04: killed the GenAI/OpenCV layers ~9x; ninja-only
    # ONNX — whose toolchain exits before this call — never failed, and the
    # never-deleted cpython tree in the toolchain image never failed either).
    # The chain-tail call in Invoke-SourceBuildChain runs AFTER the leaf
    # scripts' tree deletion, i.e. too late — this is the load-bearing one.
    Stop-LingeringBuildProcess
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path $p)) { continue }
        if ((Get-Location).Path -like "$p*") { Set-Location (Split-Path $p -Parent) }
        Write-Host "Removing build tree: $p"
        & cmd.exe /c "rd /s /q ""$p""" 2>$null
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Cleanup is best-effort by design; its exit code must NEVER outlive this
    # function. `rd` exiting 145 (ERROR_DIR_NOT_EMPTY, lingering AV/compiler
    # handle) once made Invoke-SourceBuildChain declare a fully green LiteRT-LM
    # stage "failed (exit 145)" — the chain reads the AMBIENT $LASTEXITCODE
    # after each in-process stage, and stage scripts routinely end on this call.
    $global:LASTEXITCODE = 0
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
    # getattr fallback: not every binding exposes __version__ (iree.compiler
    # does not) and the assert is about IMPORTABILITY, not version metadata.
    # Single quotes only -- PS 5.1 strips embedded double quotes in -c strings.
    # -I (isolated mode): drop CWD from sys.path. The callers sit inside the
    # SOURCE tree when this runs, and a source dir named like the module (e.g.
    # C:\temp\onnx-src\onnxruntime\) SHADOWS the installed wheel — the assert
    # then fails against the source stub while the install is perfectly fine
    # (bit ORT v1.28 first). Isolated mode asserts the INSTALLED module only.
    if (-not $VersionExpression) { $VersionExpression = "getattr($ModuleName, '__version__', 'imported')" }
    $out = cmd.exe /c """$($Python.Exe)"" -I -c ""import $ModuleName; print($VersionExpression)"" 2>&1"
    $code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $tail = if ($out) { (@($out) | Select-Object -Last 1).ToString().Trim() } else { '' }
    if ($code -ne 0) { throw "import $ModuleName failed right after install (exit $code): $tail" }
    Write-Host "$ModuleName python binding OK ($tail)"
}

function Install-StagedPythonWheel {
    # One-stop wheel publish: stage the built wheel into the central store,
    # install it into the source CPython (--no-deps optional for wheels whose
    # dependency metadata is unsatisfiable-by-design, e.g. genai-cuda's
    # onnxruntime-gpu), and import-assert the binding. Encapsulates the
    # single-element array-unwrap footgun (the c-0.0.1 incident) so call sites
    # can never reintroduce it.
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$WheelDir = 'C:\runtime\wheels',
        [switch]$NoDeps
    )
    $staged = @(Save-PythonWheel -SourceDir $SourceDir -WheelDir $WheelDir -Required)
    if (-not (Test-Path $staged[0])) { throw "staged wheel path invalid: '$($staged[0])'" }
    $pipArgs = @('install', '--quiet', '--only-binary', ':all:')
    if ($NoDeps) { $pipArgs += '--no-deps' }
    Invoke-CpythonPip -Python $Python -Arguments ($pipArgs + @($staged[0]))
    Test-PythonImport -Python $Python -ModuleName $ModuleName
    return $staged[0]
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
        [string]$ScriptDir  = 'C:\temp\scripts',
        # Resume support: skip every stage BEFORE the named one. Used to re-enter a
        # preserved run+commit container after a mid-chain failure (the completed
        # stages' output is already in $InstallDir) instead of re-paying hours of
        # compile. Unknown names throw immediately — a typo must not silently
        # rebuild from the start.
        [string]$StartAt = '',
        # Stop AFTER the named stage (inclusive). Lets the BuildKit lane split one
        # chain across multiple RUN layers (-Until 'X' in layer 1, -StartAt '<next>'
        # in layer 2): smaller layers finalize more reliably and cache per-half.
        # Unknown names throw, same rationale as -StartAt.
        [string]$Until = ''
    )
    $ErrorActionPreference = 'Stop'
    $names = @($Stages | ForEach-Object { $_.Name })
    if ($StartAt -and ($names -notcontains $StartAt)) {
        throw "Invoke-SourceBuildChain: -StartAt '$StartAt' is not a stage of '$Label' (stages: $($names -join ', '))"
    }
    if ($Until -and ($names -notcontains $Until)) {
        throw "Invoke-SourceBuildChain: -Until '$Until' is not a stage of '$Label' (stages: $($names -join ', '))"
    }
    $skipping = [bool]$StartAt
    foreach ($stage in $Stages) {
        if ($skipping) {
            if ($stage.Name -eq $StartAt) {
                $skipping = $false
            } else {
                Write-Host "`n=== $Label stage: $($stage.Name) — SKIPPED (resuming at $StartAt) ==="
                continue
            }
        }
        Write-Host "`n=== $Label stage: $($stage.Name) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
        & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($exitCode) { throw "$($stage.Name) build failed (exit $exitCode)" }
        if ($Until -and ($stage.Name -eq $Until)) {
            Write-Host "`n=== $Label chain: stopped after '$Until' (-Until) — remaining stages run in a later layer ==="
            break
        }
    }
    # ONE stats dump per chain run, here — leaf scripts and wrappers used to
    # each call Write-SccacheStats themselves (tvm branch reported twice, litert
    # once, media-tvm-all not at all). Counters die with the container, so this
    # is the last chance to get them into the run log.
    Write-SccacheStats -Label $Label
    Stop-LingeringBuildProcess
}

# ── BuildKit warm/materialize handoff ────────────────────────────────────────
# On this host, heavy-churn containers lose their HCS shutdown notification and
# their snapshot can NEVER be finalized (hcsshim::ExportLayer 0x3 — see
# docs/windows-builds.md § BuildKit/containerd lane). The workaround: run the
# heavy build in a WARM solve with no exporter (nothing ever finalizes its
# snapshot), hand the artifacts off through a cache mount, and materialize
# them in a calm, short-lived container whose layer commits fine. Cache-mount
# constraint (probed): directory RENAMES fail on the mount — these helpers
# only ever CREATE files there.

function Export-BuildHandoff {
    # Tar everything the build wrote (CreationTime/LastWriteTime > -Since)
    # under -Roots and PUT it to the WebDAV server (the same dufs instance
    # that serves sccache — reachable from every RUN container). Transport is
    # WebDAV, not a cache mount: BuildKit clones cache mounts whenever the
    # record is locked, so warm and materialize solves are NOT guaranteed to
    # see the same instance (bit us on 2026-08-04). Runs at the tail of a
    # warm-solve RUN.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)][string]$Name,
        [string]$Endpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
        [string[]]$Roots = @('C:\runtime', 'C:\temp\cpython\Lib\site-packages')
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        throw 'Export-BuildHandoff: no -Endpoint and SCCACHE_WEBDAV_ENDPOINT is unset'
    }
    $listFile = Join-Path $env:TEMP "handoff-$Name.list"
    $tarFile  = Join-Path $env:TEMP "handoff-$Name.tar"
    $entries = foreach ($root in $Roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTime -gt $Since -or $_.LastWriteTime -gt $Since } |
            ForEach-Object { ($_.FullName.Substring(3) -replace '\\', '/') }  # relative to C:\
    }
    $entries = @($entries)
    if ($entries.Count -eq 0) { throw "Export-BuildHandoff: nothing to hand off for '$Name' (Since=$Since)" }
    Set-Content -Path $listFile -Value $entries -Encoding UTF8
    # System32 paths, NOT bare names: inside the builder containers scoop's
    # git puts MSYS GNU tar/curl on PATH, and GNU tar parses "C:\" as a
    # remote host ("Cannot connect to C: resolve failed").
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -cf $tarFile -C C:\ -T $listFile
    if ($LASTEXITCODE -ne 0) { throw "Export-BuildHandoff: tar failed (exit $LASTEXITCODE)" }
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf -T $tarFile "$Endpoint/bkhandoff/$Name.tar"
    if ($LASTEXITCODE -ne 0) { throw "Export-BuildHandoff: upload to $Endpoint/bkhandoff/$Name.tar failed (exit $LASTEXITCODE)" }
    $sizeMb = [math]::Round((Get-Item $tarFile).Length / 1MB, 1)
    Remove-Item $tarFile, $listFile -Force -ErrorAction SilentlyContinue
    Write-Host "Export-BuildHandoff: $($entries.Count) files ($sizeMb MB) -> $Endpoint/bkhandoff/$Name.tar"
    $global:LASTEXITCODE = 0
}

function Import-BuildHandoff {
    # Materialize a warm solve's handoff: GET the tar from the WebDAV server
    # and extract it over C:\. Runs as the ONLY work of a calm RUN layer.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Endpoint = $env:SCCACHE_WEBDAV_ENDPOINT
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        throw 'Import-BuildHandoff: no -Endpoint and SCCACHE_WEBDAV_ENDPOINT is unset'
    }
    $tarFile = Join-Path $env:TEMP "handoff-$Name.tar"
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf -o $tarFile "$Endpoint/bkhandoff/$Name.tar"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tarFile)) {
        throw "Import-BuildHandoff: download $Endpoint/bkhandoff/$Name.tar failed - did the warm solve run?"
    }
    # The tar holds FILE entries only (delta list) and bsdtar's Windows
    # long-path mode does not create missing parent chains — pre-create every
    # directory (C:\runtime does not even exist in a fresh materialize
    # container).
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    & $tarExe -tf $tarFile |
        ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique |
        ForEach-Object { if ($_) {
            $abs = Join-Path 'C:\' $_
            if (-not (Test-Path $abs)) { New-Item -ItemType Directory -Path $abs -Force | Out-Null }
        } }
    & $tarExe -xf $tarFile -C C:\
    if ($LASTEXITCODE -ne 0) { throw "Import-BuildHandoff: tar extract failed (exit $LASTEXITCODE)" }
    $sizeMb = [math]::Round((Get-Item $tarFile).Length / 1MB, 1)
    Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
    Write-Host "Import-BuildHandoff: $Name.tar ($sizeMb MB) extracted to C:\"
    $global:LASTEXITCODE = 0
}

function Clear-BuildScratch {
    # Remove package-manager and temp scratch that heavy builds leave in the
    # container profile — dead weight in an exported image. Best-effort by
    # contract (locked files are skipped silently); called by the LAST
    # materialize step of a chain (bk-materialize.ps1 -Scrub).
    [CmdletBinding()]
    param()
    $targets = @(
        ($env:TEMP + '\*'),
        'C:\Windows\Temp\*',
        'C:\ProgramData\Microsoft\VisualStudio\Telemetry',
        ($env:LOCALAPPDATA + '\Microsoft\VSApplicationInsights'),
        ($env:LOCALAPPDATA + '\pip\cache'),
        ($env:LOCALAPPDATA + '\Microsoft\MSBuild'),
        ($env:USERPROFILE + '\.nuget'),
        ($env:LOCALAPPDATA + '\NuGet'),
        ($env:LOCALAPPDATA + '\Microsoft\Windows\INetCache')
    )
    foreach ($p in $targets) {
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host 'Clear-BuildScratch: scrubbed package/temp scratch'
    $global:LASTEXITCODE = 0
}

function Stop-LingeringBuildProcess {
    # MSVC keeps helper daemons alive after the compiler exits (mspdbsrv serves
    # PDB writes, vctip phones telemetry home, VBCSCompiler is the managed
    # equivalent). Inside a BuildKit RUN they MUST be dead before the step's
    # entrypoint returns: HCS tears the container down around them while they
    # still hold file handles in the sandbox, and the half-released files make
    # the snapshot finalize fail (hcsshim::ExportLayer 0x3 "path not found" —
    # killed the GenAI layer 3x on 2026-08-04; the ninja-only ONNX layer, which
    # leaves no such daemons behind, finalized fine every time). sccache is
    # deliberately NOT on the list: it lingered on the healthy ONNX layer too.
    [CmdletBinding()]
    param(
        # Kill even outside a container (tests use this with fake process names).
        [switch]$Force
    )
    # HOST GUARD: outside a Windows container this would kill a developer's
    # live VS/MSBuild session (Remove-SourceBuildTree runs on the host in the
    # test suite and in ad-hoc script runs). cexecsvc only exists inside
    # Windows containers.
    if (-not $Force -and -not (Get-Service -Name 'cexecsvc' -ErrorAction SilentlyContinue)) {
        $global:LASTEXITCODE = 0
        return
    }
    foreach ($name in 'mspdbsrv', 'vctip', 'VBCSCompiler', 'MSBuild', 'Tracker') {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                Write-Host "Stopping lingering build process: $name (pid $($proc.Id))"
                $proc.Kill()
                $null = $proc.WaitForExit(5000)
            } catch {
                Write-Warning "could not stop $name (pid $($proc.Id)): $_"
            }
        }
    }
    # best-effort contract: a failed kill or a race must not fail the build step
    $global:LASTEXITCODE = 0
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

# Export surface trimmed 2026-08-03 (audit): Get-VsInstallPath deleted (dead
# 4-line passthrough to Shared's Get-VisualStudioInstallPath, zero callers);
# Remove-MakefileShowIncludes moved into build-ffmpeg-from-source.ps1 (its only
# consumer, ever — hosting it here rebuilt all three media branches on change).
# NB the test suites ARE consumers of this export list (first trim pass broke
# Resolve/Artifact suites) — Save-PythonWheel/Get-CudaRoot/Resolve-TensorRtRoot/
# sccache helpers stay exported for them.
Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-SourceBuildChain',
    'Stop-LingeringBuildProcess',
    'Export-BuildHandoff',
    'Import-BuildHandoff',
    'Clear-BuildScratch',
    'Invoke-ShieldedNative',
    'Invoke-GitClone',
    'Invoke-CmakeConfigure',
    'Test-SccacheRemoteConfigured',
    'Write-SccacheStats',
    'Save-PythonWheel',
    'Get-CudaRoot',
    'Resolve-TensorRtRoot',
    'Enter-VsDevCmdEnvironment',
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
    'Get-GpuEnvironment',
    'Get-CudaArchitectureList',
    'Get-CudaToolkitRootArg',
    'Get-CudnnLibrary',
    'Get-LlvmArchiverCmakeArg',
    'Initialize-SourceBuildEnvironment',
    'Initialize-SourceBuildScript',
    'Initialize-ToolchainPythonEnvironment',
    'Initialize-PythonPlatformTag',
    'Install-StagedPythonWheel',
    'Invoke-PythonWheelBuild',
    'Test-PythonImport',
    'Remove-SourceBuildTree',
    'Get-BuildJobCount',
    'Install-CpythonPip',
    'Invoke-CpythonPip',
    'Copy-BuildArtifact',
    'Copy-SidecarDll',
    'Get-NvccCudaCmakeArgs',
    'Get-WindowsX86SimdFlags',
    'Get-WindowsX86Avx512Flags',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

