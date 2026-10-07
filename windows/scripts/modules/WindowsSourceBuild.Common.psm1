# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

$patchesPath = Join-Path $PSScriptRoot 'WindowsSourceBuild.Patches.psm1'
$cudaPath    = Join-Path $PSScriptRoot 'WindowsSourceBuild.Cuda.psm1'
$nativePath  = Join-Path $PSScriptRoot 'WindowsNative.Common.psm1'
$targetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
# Optional like the two above: only the cp3XYt twin functions need it, and they throw by name without it.
$pythonWheelPath = Join-Path $PSScriptRoot 'WindowsPythonWheel.Common.psm1'
if ((Test-Path $patchesPath) -and -not (Get-Module -Name 'WindowsSourceBuild.Patches')) { Import-Module $patchesPath }
if ((Test-Path $cudaPath) -and -not (Get-Module -Name 'WindowsSourceBuild.Cuda')) { Import-Module $cudaPath }
if ((Test-Path $pythonWheelPath) -and -not (Get-Module -Name 'WindowsPythonWheel.Common')) { Import-Module $pythonWheelPath }
# Re-exported: every COPY list that carries this module must carry WindowsNative.Common.psm1 too.
if (Test-Path $nativePath) {
    if (-not (Get-Module -Name 'WindowsNative.Common')) { Import-Module $nativePath }
} else {
    function Invoke-ShieldedNative {
        throw 'Invoke-ShieldedNative unavailable: WindowsNative.Common.psm1 is not next to WindowsSourceBuild.Common.psm1 (incomplete modules COPY list)'
    }
}
# Re-exported on the same terms: every COPY list with this module needs WindowsTargetArch.Common.psm1.
if (Test-Path $targetArchPath) {
    if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchPath }
} else {
    # Throw, not a stub: Export-ModuleMember skips unmatched names, so the gap would surface much later.
    throw ("WindowsTargetArch.Common.psm1 is not next to WindowsSourceBuild.Common.psm1 " +
           "(looked at: $targetArchPath). This is an incomplete modules COPY list -- every " +
           'Dockerfile that COPYs WindowsSourceBuild.Common.psm1 must COPY the arch module too.')
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

function Reset-SourceBuildDirectory {
    # A BuildKit cache-mount target cannot be removed, only emptied.
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Reset-SourceBuildDirectory: cannot remove $Path (mount point?) - clearing contents instead"
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -ne 0) {
            throw "Reset-SourceBuildDirectory: $Path could be neither removed nor emptied"
        }
    }
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
        [int]$Depth = 1,
        # The driver does not retry script failures, so the clone retries itself.
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 10
    )

    $ref = if ($Tag) { $Tag } else { $Branch }
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'Either -Branch or -Tag is required' }

    # `git clone --branch` rejects a commit hash, so a hash is fetched and checked out after the clone.
    $isCommitHash = $ref -match '^[0-9a-f]{7,40}$'

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # Wipe on every attempt: git refuses a non-empty directory.
        Reset-SourceBuildDirectory -Path $SourceDir

        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $env:GIT_TERMINAL_PROMPT = '0'

        if ($isCommitHash) {
            # Full clone: the commit may not be reachable from a shallow default-branch tip.
            $cloneArgs = @('clone')
            if ($Recursive) { $cloneArgs += '--recursive' }
            $cloneArgs += $RepoUrl, $SourceDir
            $cloneOut = @(& git @cloneArgs 2>&1)
            $cloneExit = $LASTEXITCODE
            if ($cloneExit -eq 0 -and (Test-Path $SourceDir)) {
                $fetchOut = @(& git -C $SourceDir fetch --depth 1 origin $ref 2>&1)
                $fetchExit = $LASTEXITCODE
                if ($fetchExit -eq 0) {
                    $checkoutOut = @(& git -C $SourceDir checkout $ref 2>&1)
                    $cloneExit = $LASTEXITCODE
                    $cloneOut += $fetchOut + $checkoutOut
                } else {
                    # fetch by hash can fail on some servers; try a full fetch
                    $fullFetch = @(& git -C $SourceDir fetch origin 2>&1)
                    $cloneOut += $fullFetch
                    $checkoutOut = @(& git -C $SourceDir checkout $ref 2>&1)
                    $cloneExit = $LASTEXITCODE
                    $cloneOut += $checkoutOut
                }
                if ($Recursive -and $cloneExit -eq 0) {
                    $subOut = @(& git -C $SourceDir submodule update --init --recursive --depth 1 2>&1)
                    $cloneOut += $subOut
                    # A failed submodule init must fail the clone, or an incomplete tree passes as green.
                    $cloneExit = $LASTEXITCODE
                }
            }
        } else {
            $gitArgs = @('clone')
            if ($Recursive) { $gitArgs += '--recursive' }
            $gitArgs += '--branch', $ref
            $gitArgs += '--depth', $Depth
            $gitArgs += $RepoUrl, $SourceDir
            $cloneOut = @(& git @gitArgs 2>&1)
            $cloneExit = $LASTEXITCODE
        }

        $ErrorActionPreference = $oldEAP

        if ($cloneExit -eq 0) { return $true }

        $tail = ($cloneOut | Select-Object -Last 10) -join [Environment]::NewLine
        if ($attempt -lt $MaxAttempts) {
            Write-Warning "git clone failed (exit $cloneExit, attempt $attempt/$MaxAttempts): $RepoUrl $ref - retrying in ${delay}s`n$tail"
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
            $delay = [Math]::Min($delay * 2, 30)
            continue
        }
        if ($SkipOnFailure) {
            Write-Warning "git clone failed (exit $cloneExit) after $MaxAttempts attempts - skipped: $tail"
            return $false
        }
        throw "git clone failed (exit $cloneExit) after $MaxAttempts attempts: $RepoUrl $ref`n$tail"
    }
}

function Get-CMakeRocmIsolationArgs {
    # TheRock's bin is on PATH on the rocm lane, so CMake would take its flatbuffers/zlib for non-HIP builds.
    if ($env:GPU_TYPE -ne 'rocm') { return @() }
    $root = @($env:ROCM_PATH, $env:HIP_PATH) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $root) { return @() }
    return @("-DCMAKE_IGNORE_PREFIX_PATH=$($root -replace '\\', '/')")
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
        # The alias keeps `-T` unambiguous if another T-prefixed parameter is added.
        [Alias('T')]
        [string]$Toolset = '',
        [string]$BuildType = 'Release',
        [string]$CCompiler = 'clang-cl',
        [string]$CxxCompiler = 'clang-cl',
        [string]$Linker = 'lld-link',
        [string]$Archiver = 'llvm-lib',
        [string[]]$ExtraArgs = @(),
        # A host-tool configure also needs Invoke-WithHostArchLibraryEnvironment; this alone is not enough.
        [string]$TargetArch = '',
        # A HIP consumer (find_package(hip) from TheRock) opts out of the rocm-lane prefix isolation.
        [switch]$AllowRocmPrefix,
        [switch]$SkipOnFailure,
        # Configures twice: CMake 4.4's Ninja generator writes `\` paths on a tree's first configure and `/` on every later one.
        [switch]$Settle
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
            # The CUDA launcher stays opt-in (mozilla/sccache#2811); C/CXX are unconditional.
            if ($env:SCCACHE_CUDA_LAUNCHER -eq '1') {
                $cmakeArgs += "-DCMAKE_CUDA_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
                Write-Host "sccache enabled at: $($sccacheCmd.Source) (remote backend, max $env:SCCACHE_MAX_JOBS jobs; C/CXX launchers + CUDA OPT-IN ACTIVE - three-canary bar applies)"
            } else {
                Write-Host "sccache enabled at: $($sccacheCmd.Source) (remote backend, max $env:SCCACHE_MAX_JOBS jobs; C/CXX launchers; CUDA stays bare - miscompile verdict 2026-08-10)"
            }
        }
    } else {
        Write-Host 'sccache disabled (no remote backend configured; a container-local cache would only bloat layers)'
    }

    # Cross args go before $ExtraArgs so a caller's -D wins: cmake honours the last occurrence.
    $crossArgs = @(Get-CMakeCrossArgs -Arch $TargetArch)
    if ($crossArgs.Count -gt 0) {
        $cmakeArgs += $crossArgs
        Write-Host "CMake cross-compiling for $(Get-WindowsTargetArch -Arch $TargetArch): $($crossArgs -join ' ')"
    }
    if (-not $AllowRocmPrefix) {
        $rocmIsolation = @(Get-CMakeRocmIsolationArgs)
        if ($rocmIsolation.Count -gt 0) {
            $cmakeArgs += $rocmIsolation
            Write-Host "CMake: ROCm tree isolated from package search ($($rocmIsolation -join ' '))"
        }
    }

    if ($ExtraArgs.Count -gt 0) { $cmakeArgs += $ExtraArgs }

    Write-Host "CMake configure: $($cmakeArgs -join ' ')"
    & cmake @cmakeArgs
    # A tree re-configured later (a cp3XYt twin) would otherwise recompile everything for the changed spelling (measured 2026-10-07).
    if ($LASTEXITCODE -eq 0 -and $Settle) {
        Write-Host 'CMake configure again (-Settle): a re-configure keeps these command lines'
        & cmake @cmakeArgs
    }
    if ($LASTEXITCODE -ne 0) {
        if ($SkipOnFailure) {
            Write-Warning "CMake configuration failed - skipped"
            return $false
        }
        throw "CMake configuration failed"
    }
    Assert-CmakeArgsConsumed -BuildDir $BuildDir -PassedArgs $ExtraArgs
    return $true
}

function Assert-CmakeArgsConsumed {
    # CMake caches an undeclared -DNAME= as UNINITIALIZED but a typed -DNAME:BOOL= as declared: pass feature flags untyped.
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [string[]]$PassedArgs = @()
    )
    $cache = Join-Path $BuildDir 'CMakeCache.txt'
    if (-not (Test-Path $cache)) { return }
    $names = @($PassedArgs |
        ForEach-Object { if ($_ -match '^-D([A-Za-z0-9_]+)(:[A-Za-z]+)?=') { $matches[1] } } |
        Sort-Object -Unique)
    if ($names.Count -eq 0) { return }
    $text = Get-Content $cache -Raw
    $ignored = @($names | Where-Object { $text -match "(?m)^$([regex]::Escape($_)):UNINITIALIZED=" })
    if ($ignored.Count -gt 0) {
        Write-Warning ("CMake IGNORED $($ignored.Count) caller-supplied variable(s) - the project never " +
            "declares them, so whatever they were meant to enable is OFF: $($ignored -join ', '). " +
            'Either the option name is wrong for this upstream pin, or the feature does not exist there.')
    }
}

# Test-SccacheRemoteConfigured lives in WindowsScripts.Shared.psm1 and is re-exported here.

function Write-SccacheStats {
    # -RequireRemote: without a remote backend a stats query would spawn a local server.
    param([string]$Label = 'build')
    $lines = Get-SccacheStatsText -RequireRemote
    if ($null -eq $lines) { return }
    Write-Host "`n=== sccache stats ($Label) ==="
    $lines | ForEach-Object { Write-Host $_ }
}

function Enter-VsDevCmdEnvironment {
    # -HostArch stays amd64: no arm64 Windows base image exists.
    param(
        [string]$Arch = '',
        [string]$HostArch = 'amd64',
        [string]$VsDevCmdPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($Arch)) { $Arch = Get-VsDevCmdArch }

    if ([string]::IsNullOrWhiteSpace($VsDevCmdPath)) {
        $vsPath = Get-VisualStudioInstallPath
        $VsDevCmdPath = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    }
    if (-not (Test-Path $VsDevCmdPath)) { throw "VsDevCmd.bat not found at: $VsDevCmdPath" }

    # VsDevCmd can print an error banner and still exit 0, so a sentinel variable is checked too.
    $vsDevOut = @(cmd /c """$VsDevCmdPath"" -arch=$Arch -host_arch=$HostArch && set" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $tail = ($vsDevOut | Select-Object -Last 10) -join [Environment]::NewLine
        throw "VsDevCmd.bat failed (exit $LASTEXITCODE): $tail"
    }
    $applied = 0
    foreach ($line in $vsDevOut) {
        if ($line -match '^(.*?)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
            $applied++
        }
    }
    if ($applied -eq 0 -or [string]::IsNullOrWhiteSpace($env:VCToolsInstallDir)) {
        $tail = ($vsDevOut | Select-Object -Last 10) -join [Environment]::NewLine
        throw "VsDevCmd.bat produced no usable environment (parsed $applied vars, VCToolsInstallDir unset): $tail"
    }
}

function Invoke-WithHostArchLibraryEnvironment {
    # lld-link reads only LIB and a second VsDevCmd appends to it, so a host-tool pass swaps the lib dirs.
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $hostDir   = (Get-WindowsTargetArchInfo -Arch (Get-WindowsHostArch)).MsvcTargetLibDir
    $targetDir = (Get-WindowsTargetArchInfo).MsvcTargetLibDir
    if ($hostDir -eq $targetDir) { return (& $ScriptBlock) }
    $saved = @{}
    foreach ($name in 'LIB', 'LIBPATH') { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in 'LIB', 'LIBPATH') {
            if ([string]::IsNullOrWhiteSpace($saved[$name])) { continue }
            $swapped = @($saved[$name] -split ';' | ForEach-Object { $_ -replace "\\$targetDir(\\|$)", "\$hostDir`$1" }) -join ';'
            [Environment]::SetEnvironmentVariable($name, $swapped, 'Process')
        }
        Write-Host "Host-arch library environment: LIB/LIBPATH \$targetDir -> \$hostDir for the duration of the host-tool pass"
        & $ScriptBlock
    } finally {
        # Unset, not empty: an empty LIB makes lld-link skip its MSVC/SDK auto-detection.
        foreach ($name in 'LIB', 'LIBPATH') {
            if ($null -eq $saved[$name]) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }
}

function Get-MsvcToolsRoot {
    # @() is load-bearing: with one toolset the flattened return is a string and [0] its first letter.
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

function Select-CpythonImportLib {
    # The GIL and free-threaded builds each link only their own pythonXY[t].lib; python3[t].lib is the stable-ABI stub.
    param(
        [Parameter(Mandatory)][string]$LibDir,
        [switch]$FreeThreaded
    )
    $pattern = if ($FreeThreaded) { '^python3\d+t\.lib$' } else { '^python3\d+\.lib$' }
    return Get-ChildItem -LiteralPath $LibDir -Filter 'python3*.lib' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } | Sort-Object Name | Select-Object -First 1
}

function Get-CpythonFreeThreadedRoot {
    # The image's free-threaded install; PYTHON_FREETHREADED_BIN is the Dockerfile.toolchain-builder ENV that puts it on PATH.
    if ($env:PYTHON_FREETHREADED_BIN) { return $env:PYTHON_FREETHREADED_BIN }
    return 'C:\python-freethreaded'
}

function Get-CpythonFreeThreadedExeName {
    # PC\layout names the free-threaded entry point python<X.Y>t.exe and ships no python.exe beside it.
    param([string]$Version = $env:PYTHON_VERSION)
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = '3.14' }
    return 'python{0}t.exe' -f ((@($Version -split '\.') | Select-Object -First 2) -join '.')
}

function Get-CpythonFreeThreadedBuildDir {
    # Py_OutDir of the free-threaded build without -Arch; with it, the directory PCbuild writes that arch's binaries to.
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [string]$Arch = ''
    )
    $root = Join-Path $SourceDir 'PCbuild\freethreaded'
    if ([string]::IsNullOrWhiteSpace($Arch)) { return $root }
    return Join-Path $root (Get-CpythonOutputDir -Arch $Arch)
}

function Get-CpythonPcbuildArguments {
    <#
    .SYNOPSIS
        PCbuild\build.bat's arguments, MSBuild properties last; -FreeThreaded adds --disable-gil and its own output and object trees.
    .DESCRIPTION
        The free-threaded binaries land outside PCbuild\<arch>, so the GIL tree on PATH never carries a python3.14t.exe whose
        site-packages it would share.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [string]$Platform = 'x64',
        [switch]$FreeThreaded,
        [string[]]$ExtraArguments = @()
    )
    $argv = @('-e', '-p', $Platform, '-c', 'Release')
    if ($FreeThreaded) {
        # Quoted, or cmd splits /p:Name=Value at the '='; no trailing backslash, which would escape the closing quote.
        $argv += @('--disable-gil',
            ('"/p:Py_OutDir={0}"' -f (Get-CpythonFreeThreadedBuildDir -SourceDir $SourceDir)),
            ('"/p:Py_IntDir={0}"' -f (Join-Path $SourceDir 'PCbuild\obj\freethreaded')))
    }
    return @($argv + $ExtraArguments)
}

function Invoke-CpythonPcbuild {
    # Through cmd, which keeps the quoted /p: arguments whole; logs the build's wall time.
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [string]$Platform = 'x64',
        [switch]$FreeThreaded,
        [string[]]$ExtraArguments = @()
    )
    $buildArgs = Get-CpythonPcbuildArguments -SourceDir $SourceDir -Platform $Platform -FreeThreaded:$FreeThreaded -ExtraArguments $ExtraArguments
    $kind = if ($FreeThreaded) { 'free-threaded' } else { 'GIL' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & cmd /c "cd /d $SourceDir && PCbuild\build.bat $($buildArgs -join ' ')" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "CPython build.bat ($kind, -p $Platform) failed (exit $LASTEXITCODE)" }
    Write-Host ('{0} CPython build (-p {1}): {2:N0}s' -f $kind, $Platform, $clock.Elapsed.TotalSeconds)
}

function Install-CpythonFreeThreadedLayout {
    <#
    .SYNOPSIS
        Lays the free-threaded build of -SourceDir out as an install at -Destination with CPython's own PC\layout.
    .DESCRIPTION
        Its own prefix, so the GIL tree's later site-packages (pip, cp314 wheels, the platform shim) never reaches the
        free-threaded interpreter. -LayoutPython runs PC\layout, which refuses a source tree of another version than its own.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$LayoutPython,
        [string]$Arch = 'amd64'
    )
    $buildDir = Get-CpythonFreeThreadedBuildDir -SourceDir $SourceDir -Arch $Arch
    $layout = Join-Path $SourceDir 'PC\layout'
    foreach ($required in @($LayoutPython, (Join-Path $layout 'main.py'), $buildDir)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Free-threaded CPython layout: $required is missing" }
    }
    # PC\layout copies Lib as it finds it, so a package here would be a GIL-built one inside the free-threaded install.
    $installed = @(Get-ChildItem -LiteralPath (Join-Path $SourceDir 'Lib\site-packages') -Force -ErrorAction SilentlyContinue |
            Where-Object Name -ne 'README.txt' | ForEach-Object Name)
    if ($installed.Count -gt 0) {
        throw "Free-threaded CPython layout: $SourceDir\Lib\site-packages already holds $($installed -join ', '); lay out before the GIL tree gets packages"
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    & $LayoutPython $layout --source $SourceDir --build $buildDir --temp (Join-Path $SourceDir 'PCbuild\obj\layout-freethreaded') `
        --copy $Destination --include-freethreaded --include-dev --include-venv --include-stable | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Free-threaded CPython layout: PC\layout exited $LASTEXITCODE" }
    if (Test-Path -LiteralPath (Join-Path $Destination 'python.exe')) {
        throw "Free-threaded CPython layout: $Destination\python.exe exists, so a GIL request could resolve to the free-threaded build"
    }
    if (-not (Select-CpythonImportLib -LibDir (Join-Path $Destination 'libs') -FreeThreaded)) {
        throw "Free-threaded CPython layout: no python3XYt.lib in $Destination\libs, so no extension could link against it"
    }
    return $Destination
}

function Assert-CpythonInterpreter {
    <#
    .SYNOPSIS
        Throws unless -Exe starts, imports its stdlib extensions, keeps the -ArchMarker and has the GIL state -FreeThreaded names.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [switch]$FreeThreaded,
        [string]$ExpectedVersion = '',
        [string]$ArchMarker = 'AMD64'
    )
    if (-not (Test-Path -LiteralPath $Exe)) { throw "CPython interpreter missing: $Exe" }
    $kind = if ($FreeThreaded) { 'free-threaded' } else { 'GIL' }
    # -I keeps PYTHON_GIL and user site-packages out of the answer; single quotes only inside the code.
    $code = 'import sys, sysconfig, ssl, sqlite3, zlib, ctypes, bz2, lzma, hashlib, socket; ' +
        "print(sys.version.split()[0], sys._is_gil_enabled(), sysconfig.get_config_var('Py_GIL_DISABLED'), '$ArchMarker' in sys.version)"
    $out = @(& $Exe -I -c $code 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed to start or to import its stdlib extensions (exit $LASTEXITCODE): $($out -join ' | ')" }
    $fields = @("$($out | Select-Object -Last 1)" -split '\s+')
    if ($fields.Count -ne 4) { throw "$Exe printed '$($out -join ' | ')', not its version, GIL state, Py_GIL_DISABLED and arch marker" }
    if ($ExpectedVersion -and $fields[0] -ne $ExpectedVersion) { throw "$Exe is CPython $($fields[0]), not the pinned $ExpectedVersion" }
    # sys._is_gil_enabled() and Py_GIL_DISABLED, as printed.
    $gilState = $fields[1..2] -join ' '
    if ($gilState -ne $(if ($FreeThreaded) { 'False 1' } else { 'True 0' })) {
        throw "$Exe is not a $kind build: sys._is_gil_enabled() and Py_GIL_DISABLED print '$gilState'"
    }
    # sysconfig.get_platform() reads the architecture out of sys.version; without it uv and pip resolve win32 wheels.
    if ($fields[3] -ne 'True') { throw "$Exe's sys.version lost '$ArchMarker': $($out -join ' | ')" }
    Write-Host "CPython $($fields[0]) ($kind) verified: $Exe"
}

function Install-CpythonTargetTree {
    <#
    .SYNOPSIS
        Stages one cross-target PCbuild output as a python.org-style tree in -Destination; returns its Root, Exe, Lib and Files.
    .DESCRIPTION
        The target interpreter never runs here, so its PE checks are the only proof; see docs/windows-cross-builds.md
        § The target CPython is built from source (#120 step 1). -FreeThreaded stages the python3.XYt build, without a python.exe.
    #>
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Arch,
        [switch]$FreeThreaded,
        # VS's <arch>\Microsoft.VC*.CRT, the replacement for host-arch CRT DLLs; empty when the image has none.
        [string]$RedistDir = '',
        # Also receives the CRT, so every bundle DLL finds it; empty stages it beside the exe only.
        [string]$BundleBin = '',
        # Writes the DLL-directory sitecustomize.py credited to this text; empty keeps site-packages empty.
        [string]$ShimWrittenBy = ''
    )
    # A module function does not inherit the calling script's preference.
    $ErrorActionPreference = 'Stop'
    $label = if ($FreeThreaded) { 'Target CPython (free-threaded)' } else { 'Target CPython' }
    $exeName = if ($FreeThreaded) { Get-CpythonFreeThreadedExeName } else { 'python.exe' }
    $tgtExe = Join-Path $BuildDir $exeName
    $tgtLib = Select-CpythonImportLib -LibDir $BuildDir -FreeThreaded:$FreeThreaded
    if (-not (Test-Path $tgtExe)) { throw "${label}: $tgtExe was not produced" }
    if (-not $tgtLib) { throw "${label}: no python3XY$(if ($FreeThreaded) { 't' }).lib import library in $BuildDir" }
    # Checked here, not only at the merge gate, so a wrong-arch interpreter fails naming the defect.
    $machine = Get-PeFileMachine -Path $tgtExe
    $wantMachine = Get-PeMachineType -Arch $Arch
    if ($machine -ne $wantMachine) {
        throw ('{0}: {1} machine is 0x{2:X4}, expected 0x{3:X4} -- the {4} platform build produced a host-arch binary (PreferredToolArchitecture / toolset resolution went wrong)' -f $label, $exeName, $machine, $wantMachine, $Arch)
    }
    Write-Host ('{0}: {1} PE machine 0x{2:X4} verified' -f $label, $exeName, $machine)

    # Laid out like a python.org install, under the arch gate's scan root.
    $pyRoot = $Destination
    foreach ($d in @($pyRoot, "$pyRoot\DLLs", "$pyRoot\libs", "$pyRoot\include")) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    Copy-Item "$BuildDir\python*.exe" $pyRoot -Force
    Copy-Item "$BuildDir\python*.dll" $pyRoot -Force
    Copy-Item "$BuildDir\*.pyd" "$pyRoot\DLLs" -Force -ErrorAction SilentlyContinue
    # Sidecar DLLs the pyds need (libffi, ssl/crypto, sqlite, tk if built).
    Get-ChildItem $BuildDir -Filter '*.dll' -File | Where-Object { $_.Name -notmatch '^python' } |
        ForEach-Object { Copy-Item $_.FullName "$pyRoot\DLLs" -Force }
    if ($FreeThreaded -and (Test-Path (Join-Path $pyRoot 'python.exe'))) {
        throw "${label}: $pyRoot\python.exe exists, so a GIL request could resolve to the free-threaded build"
    }

    # MSBuild's redist copy drops host-arch CRT DLLs into the target output; replace them or fail here, not at the merge gate.
    foreach ($staged in (Get-ChildItem -Path $pyRoot -Recurse -Include '*.dll', '*.exe', '*.pyd' -File)) {
        $m = Get-PeFileMachine -Path $staged.FullName
        if ($m -eq $wantMachine) { continue }
        $replacement = if ($RedistDir) { Join-Path $RedistDir $staged.Name } else { $null }
        if ($replacement -and (Test-Path $replacement) -and ((Get-PeFileMachine -Path $replacement) -eq $wantMachine)) {
            Copy-Item $replacement $staged.FullName -Force
            Write-Host ('{0}: replaced host-arch {1} (0x{2:X4}) with the VS {3} redist copy' -f $label, $staged.Name, $m, $Arch)
        } elseif ($staged.Name -ieq 'vcruntime140_1.dll' -and (Test-Path (Join-Path $staged.DirectoryName 'vcruntime140.dll')) -and ((Get-PeFileMachine -Path (Join-Path $staged.DirectoryName 'vcruntime140.dll')) -eq $wantMachine)) {
            # vcruntime140_1.dll has no ARM64 edition by design; see docs/windows-cross-builds.md § The target CPython is built from source (#120 step 1).
            Remove-Item $staged.FullName -Force
            Write-Host ('{0}: dropped {1} (0x{2:X4}) -- no {3} edition of this DLL exists; vcruntime140.dll (target-arch) carries its role' -f $label, $staged.Name, $m, $Arch)
        } else {
            throw ('{0}: staged {1} is machine 0x{2:X4}, expected 0x{3:X4}, and no {4} redist replacement was found -- refusing to ship a host-arch binary in the bundle' -f $label, $staged.FullName, $m, $wantMachine, $Arch)
        }
    }
    Copy-Item $tgtLib.FullName "$pyRoot\libs" -Force
    # The cross twins link this tree, and IREE's FindPython requires Development.SABIModule, the stub beside the version lib.
    if ($FreeThreaded) {
        $stableLib = Join-Path $BuildDir 'python3t.lib'
        if (-not (Test-Path -LiteralPath $stableLib)) { throw "${label}: no python3t.lib stable-ABI import library in $BuildDir" }
        Copy-Item -LiteralPath $stableLib "$pyRoot\libs" -Force
    }
    # Headers are arch-neutral: PC\pyconfig.h selects by compiler macros at include time.
    Copy-Item "$SourceDir\Include\*" "$pyRoot\include" -Recurse -Force
    Copy-Item "$SourceDir\PC\pyconfig.h" "$pyRoot\include" -Force
    # The tree's site-packages belongs to the host interpreter, so the target's starts empty.
    Copy-Item "$SourceDir\Lib" "$pyRoot\Lib" -Recurse -Force
    $tgtSitePackages = Join-Path $pyRoot 'Lib\site-packages'
    if (Test-Path $tgtSitePackages) { Get-ChildItem -LiteralPath $tgtSitePackages -Force | Remove-Item -Recurse -Force }
    New-Item -Path $tgtSitePackages -ItemType Directory -Force | Out-Null
    if ($FreeThreaded) {
        # Where PC\layout --include-venv puts them: with no python.exe to copy, uv venv has no other way to make a 3.14t venv (measured 2026-10-07).
        $venvScripts = New-Item -Path (Join-Path $pyRoot 'Lib\venv\scripts\nt') -ItemType Directory -Force
        foreach ($launcher in 'venvlaunchert.exe', 'venvwlaunchert.exe') {
            $src = Join-Path $BuildDir $launcher
            if (-not (Test-Path $src)) { throw "${label}: $src was not produced, so neither uv nor venv could make an environment from this tree" }
            if ((Get-PeFileMachine -Path $src) -ne $wantMachine) { throw "${label}: $src is not target-arch -- refusing to stage it" }
            Copy-Item $src $venvScripts.FullName -Force
        }
    }

    # The CRT must sit beside the exe: DLLs\ is a Python search path the loader never sees (0xC0000135).
    $crtNames = @('vcruntime140.dll', 'vcruntime140_threads.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'concrt140.dll', 'vccorlib140.dll')
    if ($BundleBin) { New-Item -Path $BundleBin -ItemType Directory -Force | Out-Null }
    $crtStaged = 0
    foreach ($crt in $crtNames) {
        $src = if (Test-Path (Join-Path "$pyRoot\DLLs" $crt)) { Join-Path "$pyRoot\DLLs" $crt } elseif ($RedistDir -and (Test-Path (Join-Path $RedistDir $crt))) { Join-Path $RedistDir $crt } else { $null }
        if (-not $src) { continue }
        if ((Get-PeFileMachine -Path $src) -ne $wantMachine) { throw "${label}: CRT candidate $src is not target-arch -- refusing to stage it" }
        Copy-Item $src (Join-Path $pyRoot $crt) -Force
        if ($BundleBin) { Copy-Item $src (Join-Path $BundleBin $crt) -Force }
        $crtStaged++
    }
    if (-not (Test-Path (Join-Path $pyRoot 'vcruntime140.dll'))) {
        throw "${label}: vcruntime140.dll (target-arch) could not be staged beside $exeName -- neither the build output nor the VS $Arch redist tree ($RedistDir) had it; the interpreter would not start on a clean device"
    }
    Write-Host "${label}: staged $crtStaged CRT DLL(s) beside $exeName$(if ($BundleBin) { " and in $BundleBin" }) (loader-visible; #124)"

    if ($ShimWrittenBy) {
        # The host's shim writer, without the host-only platform/EXT_SUFFIX patches.
        $tgtShim = Write-PythonDllDirectoryShim -SitePackages $tgtSitePackages -OpenCvArchDir (Get-OpenCvArchDir -Arch $Arch) -WrittenBy $ShimWrittenBy
        Write-Host "${label}: wrote the DLL-directory sitecustomize shim for the target interpreter: $tgtShim"
    }

    # The device gets pip offline from ensurepip's bundled wheel.
    $ensurepipWheel = Get-ChildItem -Path (Join-Path $pyRoot 'Lib\ensurepip\_bundled') -Filter 'pip-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ensurepipWheel) { throw "${label}: Lib\ensurepip\_bundled\pip-*.whl missing -- the device would have no way to install the staged wheels" }
    Write-Host "${label}: ensurepip bundle present ($($ensurepipWheel.Name)) -- $exeName -m ensurepip works offline on the device"

    $fileCount = @(Get-ChildItem $pyRoot -Recurse -File).Count
    Write-Host "${label}: staged $fileCount files -> $pyRoot (interpreter + CRT + import lib + headers + stdlib$(if ($FreeThreaded) { ' + venv launchers' })$(if ($ShimWrittenBy) { ' + shim' }))"
    return [pscustomobject]@{ Root = $pyRoot; Exe = (Join-Path $pyRoot $exeName); Lib = (Join-Path $pyRoot "libs\$($tgtLib.Name)"); Files = $fileCount }
}

function Get-SourceBuildPython {
    # Host-pinned because callers execute .Exe; target link inputs come from Get-TargetBuildPython.
    param(
        [string]$CpythonDir = '',
        # The free-threaded install instead of the in-tree GIL build.
        [switch]$FreeThreaded,
        [string]$FreeThreadedRoot = ''
    )
    if ($FreeThreaded) {
        if ([string]::IsNullOrWhiteSpace($FreeThreadedRoot)) { $FreeThreadedRoot = Get-CpythonFreeThreadedRoot }
        $ftLibDir = Join-Path $FreeThreadedRoot 'libs'
        $ftLib = Select-CpythonImportLib -LibDir $ftLibDir -FreeThreaded
        return @{
            Exe     = Join-Path $FreeThreadedRoot (Get-CpythonFreeThreadedExeName)
            Include = Join-Path $FreeThreadedRoot 'include'
            LibDir  = $ftLibDir
            Lib     = if ($ftLib) { $ftLib.FullName } else { Join-Path $ftLibDir 'python3t.lib' }
        }
    }
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $hostOutDir = Get-CpythonOutputDir -Arch (Get-WindowsHostArch)
    $exe = Join-Path $CpythonDir "PCbuild\$hostOutDir\python.exe"
    $include = Join-Path $CpythonDir 'Include'
    $libDir = Join-Path $CpythonDir "PCbuild\$hostOutDir"
    $gilLib = Select-CpythonImportLib -LibDir $libDir
    $lib = if ($gilLib) { $gilLib.FullName } else { Join-Path $libDir 'python3.lib' }
    return @{ Exe = $exe; Include = $include; LibDir = $libDir; Lib = $lib }
}

function Get-TargetBuildPython {
    # Callers must honour .Available: -ResumeFrom can skip Build-TargetCpython.ps1.
    param(
        [string]$CpythonDir = '',
        # The host's free-threaded install runs, the target's python3XYt.lib links (docs/windows-builds.md#the-free-threaded-wheels).
        [switch]$FreeThreaded,
        [string]$TargetFreeThreadedRoot = 'C:\runtime\python-freethreaded'
    )
    if ($FreeThreaded) {
        $ftPy = Get-SourceBuildPython -FreeThreaded
        if (-not (Test-WindowsCrossTarget)) {
            return @{ Exe = $ftPy.Exe; Include = $ftPy.Include; LibDir = $ftPy.LibDir; Lib = $ftPy.Lib; Available = (Test-Path $ftPy.Lib) }
        }
        $tgtLibDir = Join-Path $TargetFreeThreadedRoot 'libs'
        $tgtFtLib = Select-CpythonImportLib -LibDir $tgtLibDir -FreeThreaded
        return @{
            Exe = $ftPy.Exe; Include = $ftPy.Include; LibDir = $tgtLibDir
            Lib = if ($tgtFtLib) { $tgtFtLib.FullName } else { Join-Path $tgtLibDir 'python3t.lib' }
            Available = [bool]$tgtFtLib
        }
    }
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $hostPy = Get-SourceBuildPython -CpythonDir $CpythonDir
    if (-not (Test-WindowsCrossTarget)) {
        return @{ Exe = $hostPy.Exe; Include = $hostPy.Include; LibDir = $hostPy.LibDir; Lib = $hostPy.Lib
                  Available = (Test-Path $hostPy.Lib) }
    }
    $tgtOutDir = Join-Path $CpythonDir "PCbuild\$(Get-CpythonOutputDir)"
    $tgtLib = Select-CpythonImportLib -LibDir $tgtOutDir
    return @{
        Exe       = $hostPy.Exe
        Include   = $hostPy.Include
        LibDir    = $tgtOutDir
        Lib       = if ($tgtLib) { $tgtLib.FullName } else { Join-Path $tgtOutDir 'python314.lib' }
        Available = [bool]$tgtLib
    }
}

function Initialize-SourceBuildEnvironment {
    param(
        [string]$InstallDir = ''
    )
    # No Set-StrictMode/$ErrorActionPreference: inside a module function they only affect this scope.
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }
    # sccache does not create its error log's parent dir, and its server spawns on the first compile.
    if ($env:SCCACHE_ERROR_LOG) {
        $errLogDir = Split-Path $env:SCCACHE_ERROR_LOG -Parent
        if ($errLogDir -and -not (Test-Path $errLogDir)) {
            $null = New-Item -ItemType Directory -Force -Path $errLogDir -ErrorAction SilentlyContinue
        }
    }
    # Keeps Windows Update from dropping an .msu into the image layer.
    Disable-ContainerWindowsUpdate
    return $InstallDir
}

function Initialize-SourceBuildScript {
    # Scripts with work between these two steps call them directly.
    param(
        [string]$InstallDir = '',
        [string]$ScriptRoot = ''
    )
    $resolved = Initialize-SourceBuildEnvironment -InstallDir $InstallDir
    Import-CanonicalVersions -ScriptRoot $ScriptRoot
    return $resolved
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

<#
.SYNOPSIS
    Appends per-TU flags to the build.ninja FLAGS lines a selector picks; returns the tagged count.
.DESCRIPTION
    -Select returns the flags for each `build` line, or nothing. Below -Floor the file stays untouched and the
    call throws, because a selector that matches nothing would otherwise succeed silently.
#>
function Add-NinjaPerTuFlags {
    param(
        [Parameter(Mandatory)][string]$NinjaFile,
        [Parameter(Mandatory)][scriptblock]$Select,
        [Parameter(Mandatory)][int]$Floor,
        [Parameter(Mandatory)][string]$Label,
        [string]$AlreadyTaggedPattern = ''
    )
    if (-not (Test-Path -LiteralPath $NinjaFile)) { throw "Add-NinjaPerTuFlags ($Label): $NinjaFile not found -- configure did not run?" }
    $lines = @(Get-Content -LiteralPath $NinjaFile)
    $tagged = 0
    $pending = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^build ') {
            $pending = & $Select $line
            if ([string]::IsNullOrWhiteSpace("$pending")) { $pending = $null }
        } elseif ($null -ne $pending -and $line -match '^\s+FLAGS = ') {
            if ($AlreadyTaggedPattern -and $line -match $AlreadyTaggedPattern) { $tagged++ }
            else { $lines[$i] = $line + ' ' + "$pending".Trim(); $tagged++ }
            $pending = $null
        }
    }
    if ($tagged -lt $Floor) {
        throw ("build.ninja: tagged only $tagged $Label TU(s), expected >= $Floor. The ninja layout or filename convention " +
               "changed and the per-TU flags would silently go missing; the file was left untouched ($NinjaFile).")
    }
    Set-Content -LiteralPath $NinjaFile -Value $lines
    Write-Host "build.ninja: per-TU flags on $tagged $Label TU FLAGS line(s) (floor $Floor)"
    return $tagged
}

<#
.SYNOPSIS
    Writes the ABSENT-ON-<ARCH>.txt marker for a component a cross branch cannot build; returns its path.
.DESCRIPTION
    Also creates the empty directories the merge's unconditional COPY expects; the marker ships in the bundle.
#>
function Write-AbsentOnCrossMarker {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string[]]$Reason,
        [string[]]$EnsureDirs = @(),
        [string]$FileName = ''
    )
    if (-not $FileName) { $FileName = "ABSENT-ON-$((Get-WindowsTargetArch).ToUpperInvariant()).txt" }
    foreach ($d in @($Root) + @($EnsureDirs | ForEach-Object { Join-Path $Root $_ })) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    $marker = Join-Path $Root $FileName
    $body = @("$Component is intentionally ABSENT from the Windows $(Get-WindowsTargetArch) bundle.") + @($Reason) + @('See docs/windows-cross-builds.md.')
    Set-Content -Path $marker -Encoding ASCII -Value $body
    Write-Host "$Component`: named ABSENT for $(Get-WindowsTargetArch) at $marker"
    return $marker
}

<#
.SYNOPSIS
    Composes the CMake FindPython hints per prefix: the host interpreter to run, the target import lib to link.
.DESCRIPTION
    Prefixes are not interchangeable: ORT uses Python, GenAI Python and PYTHON, OpenCV PYTHON3 with forward slashes.
#>
function Get-PythonCMakeHintArgs {
    param(
        [Parameter(Mandatory)]$Python,
        [Parameter(Mandatory)][string[]]$Prefix,
        [switch]$ForwardSlash,
        [string]$NumPyIncludeDir = ''
    )
    $fmt = { param($p) if ($ForwardSlash) { "$p" -replace '\\', '/' } else { "$p" } }
    $args_ = @()
    foreach ($p in $Prefix) {
        $args_ += "-D${p}_EXECUTABLE=$(& $fmt $Python.Exe)"
        $args_ += "-D${p}_INCLUDE_DIR=$(& $fmt $Python.Include)"
        $args_ += "-D${p}_LIBRARY=$(& $fmt $Python.Lib)"
    }
    if ($NumPyIncludeDir) { $args_ += "-D$($Prefix[0])_NumPy_INCLUDE_DIR=$(& $fmt $NumPyIncludeDir)" }
    return $args_
}

<#
.SYNOPSIS
    Builds a host-tool tree with the host target and host LIB/LIBPATH; returns the bin dir (-Install) or build dir.
#>
function Invoke-HostToolCmakeBuild {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$InstallPrefix,
        [string[]]$ExtraArgs = @(),
        [string[]]$Targets = @(),
        [switch]$Install,
        [string]$InstallConfig = 'Release',
        [string]$LogName = 'host-tools-build.log',
        [int]$MemGBPerJob = 2,
        [string]$Label = 'host tools'
    )
    Write-Host "$Label`: native $(Get-WindowsHostArch) configure + build into $BuildDir"
    # `| Out-Host` is load-bearing: the block's output would otherwise leak into the return value.
    Invoke-WithHostArchLibraryEnvironment {
        Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $BuildDir -InstallPrefix $InstallPrefix -ExtraArgs $ExtraArgs -TargetArch (Get-WindowsHostArch) | Out-Null
        $log = Get-PersistentBuildLogPath -Name $LogName -FallbackDir $BuildDir
        Invoke-NinjaBuildWithRetry -BuildDir $BuildDir -RetryJobs 1 -MemGBPerJob $MemGBPerJob -LogFile $log -Targets $Targets -Install:$Install -InstallConfig $InstallConfig
    } | Out-Host
    if ($Install) { return (Join-Path $InstallPrefix 'bin') }
    return $BuildDir
}

<#
.SYNOPSIS
    Extracts and verifies a hand-staged QAIRT ("QNN") SDK zip; returns @{ Home; LibDir; CmakeArgs } or $null.
.DESCRIPTION
    No zip ($null) is the supported default. Throws on two zips, a hash mismatch, a non-SDK zip or a missing
    backend set.
#>
function Resolve-QnnSdk {
    param(
        [Parameter(Mandatory)][string]$DropDir,
        [string]$ExpectedSha256 = '',
        [string]$ExtractDir = '',
        [string]$Arch = ''
    )
    $zips = @(Get-ChildItem -Path $DropDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if ($zips.Count -gt 1) { throw "QNN: exactly one SDK zip may sit in $DropDir (found $($zips.Count)): $($zips.Name -join ', ')" }
    if ($zips.Count -eq 0) { return $null }
    $zip = $zips[0].FullName
    # A mismatch is fatal, an empty pin only warns: Assert-FileSha256 owns that policy.
    Assert-FileSha256 -Path $zip -Expected $ExpectedSha256 -Label 'QNN SDK zip' -PinName 'QNN_SDK_ZIP_SHA256'
    if (-not $ExtractDir) { $ExtractDir = Join-Path $env:TEMP_DIR 'qnn-sdk-extract' }
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $ExtractDir -Force
    $anchor = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'QnnInterface.h' -File | Where-Object { $_.Directory.Name -eq 'QNN' } | Select-Object -First 1
    if (-not $anchor) { throw "QNN: include\QNN\QnnInterface.h not found under the extracted SDK ($ExtractDir) -- not a QAIRT SDK zip?" }
    $home_ = $anchor.Directory.Parent.Parent.FullName
    $libDir = Join-Path $home_ "lib\$(Get-QnnSdkLibDirName -Arch $Arch)"
    if (-not (Test-Path (Join-Path $libDir 'QnnCpu.dll'))) { throw "QNN: $libDir\QnnCpu.dll missing -- the SDK carries no $(Get-QnnSdkLibDirName -Arch $Arch) backend set for this target" }
    # QNN_OP_STFT (API 2.25+) is the canary for an SDK too old for this ORT: QNN goes off instead of failing.
    $opDef = Join-Path $home_ 'include\QNN\QnnOpDef.h'
    if (Test-Path $opDef) {
        $opDefs = Get-Content $opDef -Raw
        if ($opDefs -notmatch 'QNN_OP_STFT') {
            $apiVer = "$([regex]::Match($opDefs, 'QNN_API_VERSION_MAJOR\s+(\d+)').Groups[1].Value).$([regex]::Match($opDefs, 'QNN_API_VERSION_MINOR\s+(\d+)').Groups[1].Value)"
            Write-Warning "QNN: SDK API version $apiVer is too old for this ORT build (QNN_OP_STFT missing) -- QNN EP OFF. Stage a newer QAIRT SDK (2.25+ API) to enable it."
            return $null
        }
    }
    return @{
        Home      = $home_
        LibDir    = $libDir
        CmakeArgs = @('-Donnxruntime_USE_QNN=ON', "-Donnxruntime_QNN_HOME=$($home_ -replace '\\', '/')")
    }
}

<#
.SYNOPSIS
    Stages the QNN backend DLLs and hexagon-v* skel dirs beside the install's DLLs; returns the DLL count.
#>
function Copy-QnnRuntime {
    param(
        [Parameter(Mandatory)]$Sdk,            # Resolve-QnnSdk result
        [Parameter(Mandatory)][string]$OrtInstallDir
    )
    # GenAI, LiteRT, TVM and IREE have no onnxruntime.dll, so fall back to any DLL's directory.
    $ortDll = Get-ChildItem -Path $OrtInstallDir -Recurse -Filter 'onnxruntime.dll' -File | Select-Object -First 1
    if (-not $ortDll) {
        $anyDll = @(Get-ChildItem -Path $OrtInstallDir -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $anyDll) {
            $binOut = Join-Path $OrtInstallDir 'bin'
            if (-not (Test-Path $binOut)) { New-Item -Path $binOut -ItemType Directory -Force | Out-Null }
        } else {
            $binOut = $anyDll.DirectoryName
        }
    } else {
        $binOut = $ortDll.DirectoryName
    }
    $staged = @(Get-ChildItem -Path $Sdk.LibDir -Filter '*.dll' -File)
    foreach ($d in $staged) { Copy-Item $d.FullName -Destination $binOut -Force }
    foreach ($skel in @(Get-ChildItem -Path (Join-Path $Sdk.Home 'lib') -Directory -Filter 'hexagon-v*' -ErrorAction SilentlyContinue)) {
        Copy-Item $skel.FullName -Destination (Join-Path $binOut $skel.Name) -Recurse -Force
    }
    Write-Host "QNN: staged $($staged.Count) backend DLL(s) from $($Sdk.LibDir) + hexagon skel dirs to $binOut"
    return $staged.Count
}

function Invoke-PythonWheelBuild {
    # Through cmd.exe: setup.py logs to stderr, which EAP=Stop would turn into an error.
    param(
        [Parameter(Mandatory)] $Python,           # Get-SourceBuildPython object
        [Parameter(Mandatory)] [string]$WorkingDir,
        [Parameter(Mandatory)] [string]$Arguments, # e.g. 'setup.py bdist_wheel'
        [Parameter(Mandatory)] [string]$ModuleName,
        [string]$DistDir = '',
        [switch]$NoDeps,
        # A cross wheel cannot be imported here, so its PE members are machine-checked instead.
        [switch]$StageOnly,
        # Cross lane: implies -StageOnly and adds `--plat-name`; a no-op on the native lane.
        [switch]$CrossStage,
        # -Python is New-FreeThreadedBuildPython's: the one cp3XYt wheel is gated, proved and stored apart, never installed; `--plat-name` on cross.
        [switch]$FreeThreaded,
        [string]$Distribution = ''
    )
    if ($FreeThreaded) {
        if (-not ($Python -is [hashtable] -and $Python['FreeThreaded'])) { throw "python wheel ($ModuleName) -FreeThreaded needs New-FreeThreadedBuildPython's interpreter, not $($Python.Exe)" }
        if (-not $Distribution) { throw "python wheel ($ModuleName) -FreeThreaded needs -Distribution, the name the proof looks up" }
        if (-not $DistDir) { $DistDir = Join-Path $WorkingDir 'dist' }
        # One wheel or none: a GIL wheel left in the dist dir would be ambiguous.
        if (Test-Path -LiteralPath $DistDir) { Get-ChildItem -LiteralPath $DistDir -Filter '*.whl' -File | Remove-Item -Force }
    }
    if (($CrossStage -or $FreeThreaded) -and (Test-WindowsCrossTarget)) {
        if ($Arguments -match '\bbdist_wheel\b' -and $Arguments -notmatch '--plat-name') { $Arguments = "$Arguments --plat-name $(Get-PythonWheelTag)" }
        if ($CrossStage) {
            $StageOnly = $true
            Write-Host "python wheel ($ModuleName): cross lane -- building for $(Get-PythonWheelTag), staging only (never installed or imported here)"
        }
    }
    if (-not $DistDir) { $DistDir = Join-Path $WorkingDir 'dist' }
    Push-Location $WorkingDir
    try {
        # The twin's build log goes to the host, so the stored wheel's path is all a -FreeThreaded call returns.
        cmd.exe /c """$($Python.Exe)"" $Arguments 2>&1" | ForEach-Object { if ($FreeThreaded) { Write-Host $_ } else { $_ } }
        if ($LASTEXITCODE -ne 0) { throw "python wheel build failed (exit $LASTEXITCODE): $Arguments" }
    } finally { Pop-Location }
    if ($FreeThreaded) {
        $twin = Select-FreeThreadedWheel -Wheels @(Get-ChildItem -LiteralPath $DistDir -Filter '*.whl' -File -ErrorAction SilentlyContinue) -AbiTag (Get-FreeThreadedAbiTag)
        if (-not $twin) { throw "free-threaded: the $Distribution build left a pure wheel, so there is no cp3XYt twin to store" }
        return Save-FreeThreadedWheel -Wheel $twin.FullName -Distribution $Distribution
    }
    if ($StageOnly) {
        $staged = @(Save-PythonWheel -SourceDir $DistDir -Required)
        foreach ($w in $staged) { Assert-WheelTargetArch -WheelPath $w }
        return $staged[0]
    }
    return Install-StagedPythonWheel -Python $Python -SourceDir $DistDir -ModuleName $ModuleName -NoDeps:$NoDeps
}

function Assert-WheelTargetArch {
    # A wheel tagged for the wrong platform installs fine and then fails at import.
    param([Parameter(Mandatory)][string]$WheelPath)
    $wantTag = Get-PythonWheelTag
    $wantMachine = Get-PeMachineType
    $name = Split-Path $WheelPath -Leaf
    if ($name -notmatch [regex]::Escape($wantTag)) {
        throw "wheel $name does not carry the target platform tag '$wantTag' -- pass --plat-name $wantTag to bdist_wheel"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wheelcheck-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $tmp -ItemType Directory -Force | Out-Null
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($WheelPath, $tmp)
        $pe = @(Get-ChildItem -Path $tmp -Recurse -File -Include '*.pyd', '*.dll', '*.exe')
        if ($pe.Count -eq 0) { throw "wheel $name contains no native modules at all -- the binding was not built" }
        foreach ($f in $pe) {
            # The target interpreter only loads its own EXT_SUFFIX tag, whatever the PE machine field says.
            if ($f.Name -match '\.cp\d+t?-win_(amd64|arm64)\.pyd$' -and $f.Name -notmatch [regex]::Escape($wantTag)) {
                throw "wheel ${name}: member $($f.Name) carries a host EXT_SUFFIX tag, expected '$wantTag' -- the target interpreter would never import it (the sitecustomize shim pins EXT_SUFFIX to the target; is it active?)"
            }
            $m = Get-PeFileMachine -Path $f.FullName
            if ($m -ne $wantMachine) {
                throw ('wheel {0}: member {1} is machine 0x{2:X4}, expected 0x{3:X4} -- a host-arch binary inside a {4} wheel' -f $name, $f.Name, $m, $wantMachine, $wantTag)
            }
        }
        # Names, not just a count: consumers need to know what the wheel embeds.
        $names = @($pe | ForEach-Object { $_.FullName.Substring($tmp.Length).TrimStart('\', '/') } | Sort-Object)
        Write-Host ('Wheel arch check OK: {0} -- {1} native member(s), all 0x{2:X4}: {3}' -f $name, $pe.Count, $wantMachine, (($names | Select-Object -First 60) -join ', ') + $(if ($names.Count -gt 60) { ", ... (+$($names.Count - 60))" } else { '' }))
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-FreeThreadedWheelStore {
    # The cp3XYt twins' own store (image ENV PYTHON_WHEELS_CP314T), apart from PYTHON_WHEELS so no GIL install resolves one.
    [OutputType([string])]
    param()
    if ($env:PYTHON_WHEELS_CP314T) { return $env:PYTHON_WHEELS_CP314T }
    return 'C:\runtime\wheels-cp314t'
}

function Get-FreeThreadedAbiTag {
    # PYTHON_VERSION's free-threaded wheel ABI tag, 3.14 when unset, as Get-CpythonFreeThreadedExeName assumes.
    [OutputType([string])]
    param([string]$Version = $env:PYTHON_VERSION)
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = '3.14' }
    return (Get-FreeThreadedTarget -PythonVersion $Version).AbiTag
}

function Get-FreeThreadedTwinPlan {
    <#
    .SYNOPSIS
        Whether this build makes -Distribution's cp3XYt twin and the one log line why; throws for an unlisted distribution or a missing interpreter.
    #>
    param(
        [Parameter(Mandatory)][string]$Distribution,
        # Get-TargetBuildPython -FreeThreaded's default: Build-TargetCpython.ps1's staged tree.
        [string]$TargetFreeThreadedRoot = 'C:\runtime\python-freethreaded'
    )
    $row = Get-FreeThreadedTwinRow -Distribution $Distribution
    if (-not $row) { throw "free-threaded: $Distribution is not in Get-FreeThreadedTwinTable (linux/scripts/03-media/free-threaded-twins.txt)" }
    $abi = Get-FreeThreadedAbiTag
    $skip = { param([string]$Why) [pscustomobject]@{ Build = $false; Reason = "free-threaded: no $abi twin of ${Distribution}: $Why" } }
    if ($row.Verdict -cne 'twin') { return & $skip "$($row.Verdict), $($row.Evidence)" }
    $cross = Test-WindowsCrossTarget
    # The GIL cross wheels skip a missing target CPython with a log line; its twin follows them.
    if ($cross -and -not (Get-TargetBuildPython).Available) { return & $skip "the $(Get-WindowsTargetArch) cross build has no target CPython, so it builds no GIL wheel either" }
    # The host's free-threaded install runs the build; the target's python3XYt.lib is what the twin links.
    foreach ($need in @((Get-SourceBuildPython -FreeThreaded).Exe, (Get-TargetBuildPython -FreeThreaded -TargetFreeThreadedRoot $TargetFreeThreadedRoot).Lib)) {
        if (-not (Test-Path -LiteralPath $need)) { throw "free-threaded: $Distribution needs a $abi twin, and this image has no $need to build it with" }
    }
    $for = if ($cross) { " for $(Get-PythonWheelTag)" } else { '' }
    return [pscustomobject]@{ Build = $true; Reason = "free-threaded: building the $abi twin of $Distribution$for ($($row.Evidence))" }
}

function Assert-NinjaFreeThreadedDefine {
    # 3.14's PC\pyconfig.h leaves Py_GIL_DISABLED undefined: compile lines without it build a GIL module. Returns the line count.
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][string]$Label)
    $ninja = Join-Path $BuildDir 'build.ninja'
    $hits = @(Select-String -LiteralPath $ninja -Pattern '(^|\s)[-/]DPy_GIL_DISABLED=1(\s|$)')
    if ($hits.Count -eq 0) { throw "free-threaded ${Label}: no line of $ninja defines Py_GIL_DISABLED=1, so its modules would build against the GIL ABI" }
    Write-Host "free-threaded ${Label}: Py_GIL_DISABLED=1 on $($hits.Count) build.ninja line(s)"
    return $hits.Count
}

function New-FreeThreadedBuildPython {
    <#
    .SYNOPSIS
        A uv venv of the free-threaded install holding -Package at -GilPython's versions; Get-SourceBuildPython's shape plus FreeThreaded and Venv.
    .DESCRIPTION
        'name==version' passes as given. Exe is the venv's; Include, LibDir and Lib are Get-TargetBuildPython -FreeThreaded's, so CMake and
        setuptools link the target's python3XYt.lib. On a cross lane the venv's sitecustomize pins EXT_SUFFIX to the target's
        .cp3XYt-<tag>.pyd, as Initialize-PythonPlatformTag does for the GIL build interpreter.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$GilPython,
        [Parameter(Mandatory)][string]$VenvDir,
        [string[]]$Package = @()
    )
    $ft = Get-SourceBuildPython -FreeThreaded
    $link = Get-TargetBuildPython -FreeThreaded
    $requirements = @(foreach ($p in $Package) {
            if ($p -match '[=<>!~]') { $p; continue }
            $ver = "$(& $GilPython.Exe -I -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' $p 2>$null)".Trim()
            if ($LASTEXITCODE -ne 0 -or -not $ver) { throw "free-threaded: the GIL build interpreter $($GilPython.Exe) has no $p, so its twin has no version to match" }
            "$p==$ver"
        })
    [void](Invoke-ShieldedNative -Label 'uv venv (free-threaded build)' -CommandLine "uv venv --clear --no-cache --quiet --python ""$($ft.Exe)"" ""$VenvDir""")
    $exe = Join-Path $VenvDir 'Scripts\python.exe'
    if ($requirements.Count -gt 0) {
        [void](Invoke-ShieldedNative -Label 'uv pip install (free-threaded build)' -CommandLine "uv pip install --no-cache --quiet --python ""$exe"" $($requirements -join ' ')")
    }
    # After the installs, which resolve host wheels: the pin changes EXT_SUFFIX only, get_platform() stays the host's.
    if (Test-WindowsCrossTarget) {
        $shim = Write-PythonDllDirectoryShim -SitePackages (Join-Path $VenvDir 'Lib\site-packages') -OpenCvArchDir (Get-OpenCvArchDir) `
            -CrossExtTag (Get-PythonWheelTag) -WrittenBy 'New-FreeThreadedBuildPython (cross build venv)'
        Write-Host "free-threaded: $shim names this venv's modules for $(Get-PythonWheelTag); they link $($link.Lib)"
    }
    Write-Host "free-threaded: build venv $VenvDir on $($ft.Exe) with $(if ($requirements.Count) { $requirements -join ' ' } else { 'no packages' })"
    return @{ Exe = $exe; Include = $link.Include; LibDir = $link.LibDir; Lib = $link.Lib; FreeThreaded = $true; Venv = $VenvDir }
}

function Invoke-FreeThreadedTwinWheel {
    <#
    .SYNOPSIS
        A setup.py or pip-wheel twin: when the plan says so, -Arguments run by a build venv of -Package in -WorkingDir; the stored path, else $null.
    .PARAMETER CleanPath
        Build leftovers of the GIL pass to remove first, such as setup.py's build\.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$GilPython,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$ModuleName,
        [Parameter(Mandatory)][string]$WorkingDir,
        [Parameter(Mandatory)][string]$Arguments,
        [string[]]$Package = @(),
        [string]$DistDir = '',
        [string[]]$CleanPath = @()
    )
    $plan = Get-FreeThreadedTwinPlan -Distribution $Distribution
    Write-Host $plan.Reason
    if (-not $plan.Build) { return $null }
    $venv = Join-Path ([IO.Path]::GetTempPath()) "ft-venv-$Distribution"
    try {
        $ftPy = New-FreeThreadedBuildPython -GilPython $GilPython -VenvDir $venv -Package $Package
        foreach ($stale in $CleanPath) { Remove-Item -LiteralPath $stale -Recurse -Force -ErrorAction SilentlyContinue }
        return Invoke-PythonWheelBuild -Python $ftPy -WorkingDir $WorkingDir -DistDir $DistDir -Arguments $Arguments `
            -ModuleName $ModuleName -FreeThreaded -Distribution $Distribution
    } finally {
        Remove-Item -LiteralPath $venv -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeThreadedWheelImportFinding {
    <#
    .SYNOPSIS
        Why -Path's modules are no cp3XYt build: a .pyd importing another Python runtime than python3XYt.dll, or none importing it; none = it passes.
    .DESCRIPTION
        The static half of the proof, for a cross wheel this host cannot load: a module built against the GIL ABI imports pythonXY.dll or python3.dll.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [string]$AbiTag = (Get-FreeThreadedAbiTag))
    $name = [IO.Path]::GetFileName($Path)
    $want = "python$($AbiTag -replace '^cp', '').dll"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ft-imports-' + [guid]::NewGuid().ToString('N'))
    $hits = 0
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in @($zip.Entries | Where-Object { $_.Name -like '*.pyd' })) {
            $file = Join-Path $tmp ([guid]::NewGuid().ToString('N') + '.pyd')
            $null = New-Item -ItemType Directory -Force -Path $tmp
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $file)
            $runtimes = @(Get-PeImportNames -Path $file -IncludeDelayLoad | Where-Object { $_ -match '^python\d+t?(_d)?\.dll$' })
            if ($runtimes -contains $want) { $hits++ }
            foreach ($other in @($runtimes | Where-Object { $_ -ne $want })) { "$($entry.FullName) imports $other, not $want" }
        }
    } finally {
        $zip.Dispose()
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($hits -eq 0) { "no module of $name imports $want" }
}

function Save-FreeThreadedWheel {
    <#
    .SYNOPSIS
        Gates -Wheel's cp3XYt tags and imports, proves it alone in a fresh free-threaded venv, then copies it to -Store; returns the stored path.
    .DESCRIPTION
        Nothing unproved is stored; Invoke-FreeThreadedWheelVenvProof registers the image's DLL homes for the proof. A cross
        twin cannot load here, so its PE members are machine-checked instead and Test-Arm64Bundle.ps1 proves it on the device.
    #>
    param(
        [Parameter(Mandatory)][string]$Wheel,
        [Parameter(Mandatory)][string]$Distribution,
        [string]$Store = (Get-FreeThreadedWheelStore),
        [string]$Helper = ''
    )
    $name = Split-Path $Wheel -Leaf
    $findings = @(Get-FreeThreadedWheelFinding -Path $Wheel -PlatformTag (Get-PythonWheelTag))
    if ($findings.Count -gt 0) { throw "free-threaded: $name fails the cp3XYt tag gate:`n  $($findings -join "`n  ")" }
    $findings = @(Get-FreeThreadedWheelImportFinding -Path $Wheel)
    if ($findings.Count -gt 0) { throw "free-threaded: $name fails the cp3XYt import gate:`n  $($findings -join "`n  ")" }
    if (Test-WindowsCrossTarget) {
        Assert-WheelTargetArch -WheelPath $Wheel
        Write-Host "free-threaded: ${name}: tags, imports and PE machine checked; the $(Get-PythonWheelTag) device proves it (Test-Arm64Bundle.ps1)"
    } else {
        $verdict = Invoke-FreeThreadedWheelVenvProof -Interpreter (Get-SourceBuildPython -FreeThreaded).Exe -Wheel $Wheel -Distribution $Distribution `
            -DllDirectory (Get-PythonDllHome -OpenCvArchDir (Get-OpenCvArchDir)) -Helper $Helper
        Write-Host "free-threaded: ${name}: $verdict"
    }
    New-Item -Path $Store -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $Wheel -Destination $Store -Force
    Write-Host "free-threaded: stored $name in $Store"
    return (Join-Path $Store $name)
}

function Get-FreeThreadedStoreFinding {
    <#
    .SYNOPSIS
        Why the twins' store does not mirror -GilStore; none = every twin-verdict GIL wheel has one tag-clean cp3XYt twin of its version.
    .DESCRIPTION
        For a cross lane's merge, where smoke section 20 cannot run; there every twin pairs a GIL wheel. A native image ships
        apache-tvm-ffi's twin alone, so section 20 checks the table's exact set there instead.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][string]$GilStore, [Parameter(Mandatory)][string]$PlatformTag)
    $describe = { param([IO.FileInfo]$Wheel)
        $f = $Wheel.BaseName.Split('-')
        [pscustomobject]@{ Name = $Wheel.Name; Dist = (ConvertTo-PythonDistributionName -Name $f[0]); Version = $f[1]; Abi = $f[-2]; Row = (Get-FreeThreadedTwinRow -Distribution $f[0]) }
    }
    $twins = @(Get-ChildItem -LiteralPath $Store -Filter '*.whl' -File -ErrorAction SilentlyContinue | ForEach-Object { & $describe $_ })
    $gil = @(Get-ChildItem -LiteralPath $GilStore -Filter '*.whl' -File -ErrorAction SilentlyContinue | ForEach-Object { & $describe $_ })
    foreach ($g in @($gil | Where-Object Abi -Match '^cp\d+t$')) { "$($g.Name) is free-threaded and sits in the GIL store $GilStore" }
    foreach ($t in $twins) {
        if (-not $t.Row -or $t.Row.Verdict -cne 'twin') { "$($t.Name) is in $Store, but Get-FreeThreadedTwinTable gives $($t.Dist) no twin" }
        elseif (-not @($gil | Where-Object Dist -CEQ $t.Dist).Count) { "$($t.Name) has no GIL wheel in $GilStore to pair with" }
        Get-FreeThreadedWheelFinding -Path (Join-Path $Store $t.Name) -PlatformTag $PlatformTag
    }
    foreach ($g in @($gil | Where-Object { $_.Abi -notmatch '^cp\d+t$' -and $_.Row -and $_.Row.Verdict -ceq 'twin' })) {
        $mine = @($twins | Where-Object Dist -CEQ $g.Dist)
        if ($mine.Count -eq 0) { "$($g.Name) has no cp3XYt twin in $Store" }
        elseif ($mine.Count -gt 1) { "$($g.Dist) has $($mine.Count) twins in ${Store}: $($mine.Name -join ', ')" }
        elseif ($mine[0].Version -cne $g.Version) { "$($mine[0].Name) is version $($mine[0].Version), its GIL wheel $($g.Name) $($g.Version)" }
    }
}

function Complete-SourceBuild {
    <#
    .SYNOPSIS
        Build-script epilogue: optional cleanup, the banner verbatim (log-watchers grep it), then `exit 0`.
    .DESCRIPTION
        Never returns. The explicit exit matters: pwsh -File otherwise propagates the last native exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$Banner,
        [string]$SourceDir = ''
    )
    if ($SourceDir) { Remove-SourceBuildTree -Path $SourceDir }
    Write-Host $Banner
    exit 0
}

function Remove-SourceBuildTree {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )
    if ($env:KEEP_BUILD_ARTIFACTS -eq '1') {
        Write-Host "KEEP_BUILD_ARTIFACTS=1 - keeping: $($Path -join ', ')"
        # This call must not leak an exit code on any path.
        $global:LASTEXITCODE = 0
        return
    }
    # Daemons holding handles leave pending-delete files that break the BuildKit snapshot finalize.
    Stop-LingeringBuildProcess
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path $p)) { continue }
        if ((Get-Location).Path -like "$p*") { Set-Location (Split-Path $p -Parent) }
        Write-Host "Removing build tree: $p"
        & cmd.exe /c "rd /s /q ""$p""" 2>$null
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Best-effort cleanup: a failing `rd` must not fail a green stage.
    $global:LASTEXITCODE = 0
}

# Build phases: markers, not scriptblocks, because a function-invoked body would drop every assignment.
function Start-BuildPhase {
    param(
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path 'Variable:script:BuildPhaseTable')) { $script:BuildPhaseTable = [System.Collections.Generic.List[object]]::new() }
    $phase = [pscustomobject]@{ Name = $Name; Started = Get-Date; Seconds = $null; Failed = $false }
    $script:BuildPhaseTable.Add($phase)
    Write-Host ""
    Write-Host ("=== PHASE: {0} ({1:HH:mm:ss}) ===" -f $Name, $phase.Started) -ForegroundColor Cyan
    return $phase
}

function Switch-BuildPhase {
    <#
    .SYNOPSIS
        Completes the open phase (if any) and starts a new one; pair with Complete-CurrentBuildPhase in catch/finally.
    #>
    param([Parameter(Mandatory)][string]$Name)
    Complete-CurrentBuildPhase
    $script:CurrentBuildPhase = Start-BuildPhase $Name
}

function Complete-CurrentBuildPhase {
    # A no-op when no phase is open, so catch/finally can call it unconditionally.
    param($ErrorRecord = $null)
    if (-not (Test-Path 'Variable:script:CurrentBuildPhase')) { return }
    if ($null -eq $script:CurrentBuildPhase) { return }
    Complete-BuildPhase $script:CurrentBuildPhase -ErrorRecord $ErrorRecord
    $script:CurrentBuildPhase = $null
}

function Complete-BuildPhase {
    param(
        [Parameter(Mandatory)]$Phase,
        # Marks the phase failed so the chain log names the phase, not just the line.
        $ErrorRecord = $null
    )
    $Phase.Seconds = [math]::Round(((Get-Date) - $Phase.Started).TotalSeconds, 1)
    if ($null -ne $ErrorRecord) {
        $Phase.Failed = $true
        Write-Host ("=== PHASE FAILED: {0} after {1}s - {2} ===" -f $Phase.Name, $Phase.Seconds, $ErrorRecord.Exception.Message) -ForegroundColor Red
    } else {
        Write-Host ("=== PHASE OK: {0} ({1}s) ===" -f $Phase.Name, $Phase.Seconds) -ForegroundColor Cyan
    }
}

function Write-BuildPhaseSummary {
    param([string]$Label = '')
    if (-not (Test-Path 'Variable:script:BuildPhaseTable')) { return }
    Write-Host ""
    Write-Host ("=== phase summary{0} ===" -f $(if ($Label) { " ($Label)" } else { '' }))
    foreach ($p in $script:BuildPhaseTable) {
        $mark = if ($p.Failed) { 'FAIL' } elseif ($null -eq $p.Seconds) { '....' } else { ' ok ' }
        Write-Host ("  [{0}] {1,-38} {2,8}s" -f $mark, $p.Name, $(if ($null -ne $p.Seconds) { $p.Seconds } else { '-' }))
    }
    $script:BuildPhaseTable = [System.Collections.Generic.List[object]]::new()
}

function Get-WarningNoiseSuppressionFlags {
    # One list for every clang-cl CMake build: these five classes bury the genuine warnings.
    return '-Wno-unused-parameter -Wno-documentation-unknown-command -Wno-deprecated-copy -Wno-undef -Wno-missing-field-initializers'
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
    } elseif ($env:SCCACHE_WEBDAV_ENDPOINT) {
        # A scheduling knob must not be image ENV/ARG (both are cache keys), so the driver publishes it to webdav.
        if (-not (Test-Path 'Variable:script:WebdavMemoryLimitGb')) {
            $script:WebdavMemoryLimitGb = ''
            try {
                $resp = & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --max-time 5 "$($env:SCCACHE_WEBDAV_ENDPOINT)/preseed/memory-limit-gb.txt" 2>$null
                if ("$resp".Trim() -match '^\d+$') { $script:WebdavMemoryLimitGb = "$resp".Trim() }
            } catch {
                # Fails open: the webdav budget is an optimisation and the CIM branch below takes over.
                Write-Debug ("webdav memory-limit probe failed ({0}) -- falling back to CIM" -f $_.Exception.Message)
            }
            $global:LASTEXITCODE = 0
        }
        if ($script:WebdavMemoryLimitGb -match '^\d+$') { $memGB = [int]$script:WebdavMemoryLimitGb }
    }
    if ($memGB -le 0) {
        try {
            $memGB = [int][Math]::Floor((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB)
        } catch { $memGB = 0 }
    }
    if ($memGB -le 0) { return $cores }
    return [Math]::Max(2, [Math]::Min($cores, [int][Math]::Floor($memGB / $MemGBPerJob)))
}

function Start-SccacheStallGuard {
    # A quiet fleet only pre-filters; a timed --show-stats probe confirms the deadlock, and $MarkerPath tells the retry ladder.
    param([int]$SampleSeconds = 60, [string]$MarkerPath = '', [int]$ProbeTimeoutMs = 15000)
    if (-not (Get-Command sccache.exe -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-SccacheRemoteConfigured)) { return $null }
    return Start-Job -ScriptBlock {
        $sampleSeconds = $using:SampleSeconds
        $markerPath = $using:MarkerPath
        $probeTimeoutMs = $using:ProbeTimeoutMs
        $sccacheExe = (Get-Command sccache.exe -ErrorAction SilentlyContinue).Source
        $fleet = @('ninja', 'cl', 'clang-cl', 'nvcc', 'cicc', 'ptxas', 'cudafe++', 'link', 'lld-link', 'sccache')
        $prev = -1.0
        while ($true) {
            Start-Sleep -Seconds $sampleSeconds
            $procs = @(Get-Process -Name $fleet -ErrorAction SilentlyContinue)
            $scc = @($procs | Where-Object { $_.ProcessName -eq 'sccache' })
            if ($procs.Count -eq 0 -or $scc.Count -eq 0) { $prev = -1.0; continue }
            $cpu = 0.0
            foreach ($p in $procs) {
                # A process can exit between enumeration and this read.
                try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { continue }
            }
            $delta = if ($prev -ge 0) { $cpu - $prev } else { -1.0 }
            $prev = $cpu
            if ($delta -lt 0 -or $delta -ge 2.0) { continue }  # pre-filter: fleet is visibly working
            # Touch .Handle before WaitForExit, or a -PassThru process reports a wrong ExitCode.
            $probe = Start-Process -FilePath $sccacheExe -ArgumentList '--show-stats' `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
            $null = $probe.Handle
            if ($probe.WaitForExit($probeTimeoutMs)) { continue }  # server answered: healthy idle
            Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
            $msg = ("sccache server failed to answer --show-stats within {0}s while the fleet sat at {1:N1} CPU-s/{2}s - DEADLOCK confirmed, killing sccache (ninja retry resumes incrementally)" -f ($probeTimeoutMs / 1000), $delta, $sampleSeconds)
            $recorded = $false
            if ($markerPath) {
                try {
                    Add-Content -Path $markerPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ErrorAction Stop
                    $recorded = $true
                } catch { $recorded = $false }
            }
            if (-not $recorded) {
                # A kill must never be invisible, so fall back to the job stream.
                Write-Output ("MARKER WRITE FAILED - " + $msg)
            }
            $scc | Stop-Process -Force -ErrorAction SilentlyContinue
            $prev = -1.0
        }
    }
}

function Stop-SccacheStallGuard {
    param($Guard)
    if (-not $Guard) { return }
    $msgs = @(Receive-Job -Job $Guard -ErrorAction SilentlyContinue)
    Stop-Job -Job $Guard -ErrorAction SilentlyContinue
    Remove-Job -Job $Guard -Force -ErrorAction SilentlyContinue
    foreach ($m in $msgs) { Write-Host "[sccache-stall-guard] $m" -ForegroundColor Yellow }
}

function Get-PersistentBuildLogPath {
    # See docs/windows-build-invariants.md § A build log written inside the build dir dies with the solve
    param(
        [Parameter(Mandatory)][string]$Name,
        # Used when no persistent cache mount is available.
        [Parameter(Mandatory)][string]$FallbackDir
    )
    # Never $env:SCCACHE_DIR: rotating logs through sccache's LRU index made its cache writes fail.
    $logRoot = if ($env:SCCACHE_ERROR_LOG) { Split-Path $env:SCCACHE_ERROR_LOG -Parent } else { '' }
    $logDir = if ($logRoot -and (Test-Path $logRoot)) { $logRoot } else { $FallbackDir }
    $null = New-Item -ItemType Directory -Force -Path $logDir
    $logPath = Join-Path $logDir $Name
    # Copy+Remove, not Move-Item: the cache mount is rename-hostile.
    if (Test-Path $logPath) {
        Copy-Item -Path $logPath -Destination "$logPath.prev" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    }
    return $logPath
}

function Invoke-NinjaBuildWithRetry {
    # A guard-kill is not OOM-shaped, so it retries at full -j; only a compile failure drops to -j$RetryJobs once.
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [int]$RetryJobs = 1,
        [int]$MemGBPerJob = 4,
        [string]$LogFile = '',
        [switch]$Install,
        [string]$InstallConfig = 'Release',
        [int]$StallRetries = 3,
        # Injectable for tests; default lives beside the build dir.
        [string]$StallMarkerPath = '',
        # Explicit ninja targets (default: the whole graph), passed on every retry.
        [string[]]$Targets = @()
    )
    $env:NINJA_STATUS = "[%f/%t] "
    $jobs = Get-BuildJobCount -MemGBPerJob $MemGBPerJob
    $ninjaKeep = if ($env:NINJA_KEEP_GOING -eq '1') { @('-k', '0') } else { @() }
    if (-not $StallMarkerPath) { $StallMarkerPath = Join-Path $BuildDir '.sccache-stall-guard.marker' }
    Remove-Item -Path $StallMarkerPath -Force -ErrorAction SilentlyContinue
    # Reset once here; every invocation below appends.
    if ($LogFile) { Remove-Item -Path $LogFile -Force -ErrorAction SilentlyContinue }

    $invokeNinja = {
        param($jobCount)
        # Truncate before each attempt so kills are attributed to this attempt only.
        Remove-Item -Path $StallMarkerPath -Force -ErrorAction SilentlyContinue
        if ($LogFile) { ninja -j $jobCount @ninjaKeep -C $BuildDir @Targets 2>&1 | Tee-Object -FilePath $LogFile -Append }
        else { ninja -j $jobCount @ninjaKeep -C $BuildDir @Targets 2>&1 }
    }

    Write-Host "Building with ninja -j$jobs..."
    $guard = Start-SccacheStallGuard -MarkerPath $StallMarkerPath
    try {
        & $invokeNinja $jobs
        # Guard-kill retries: full parallelism, bounded, only while this attempt's marker shows a kill.
        for ($attempt = 1; $attempt -le $StallRetries -and $LASTEXITCODE -ne 0; $attempt++) {
            $kills = @(Get-Content $StallMarkerPath -ErrorAction SilentlyContinue)
            if ($kills.Count -eq 0) { break }
            foreach ($k in $kills) { Write-Host "[sccache-stall-guard] $k" -ForegroundColor Yellow }
            Write-Host "ninja -j$jobs failed after $($kills.Count) stall-guard kill(s) this attempt - full-speed retry $attempt/$StallRetries (compiled objects are cache hits)..." -ForegroundColor Yellow
            & $invokeNinja $jobs
        }
        if ($LASTEXITCODE -ne 0 -and $jobs -gt $RetryJobs) {
            # Loud and bounded to one attempt: a repeating downgrade is a crash signature.
            Write-Warning ("#75 JOB-DOWNGRADE: ninja -j$jobs failed (exit $LASTEXITCODE) - ONE bounded incremental retry at -j$RetryJobs. " +
                'If this pattern repeats across runs at ~the same runtime, it is a crash signature (sccache server, OOM killer) - investigate, do not re-run the stage.')
            $incrementalStart = Get-Date
            & $invokeNinja $RetryJobs
            if ($LASTEXITCODE -eq 0) {
                $incMin = [math]::Round(((Get-Date) - $incrementalStart).TotalMinutes, 1)
                Write-Warning "#75 JOB-DOWNGRADE: build completed ONLY via the -j$RetryJobs fallback (+$incMin min serial) - green, but the -j$jobs failure above still needs a root cause."
            }
        }
    } finally {
        Stop-SccacheStallGuard $guard
        if (Test-Path $StallMarkerPath) {
            Get-Content $StallMarkerPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "[sccache-stall-guard] $_" -ForegroundColor Yellow }
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
    # Gate both 7z passes, or a corrupt tarball surfaces as a missing source directory.
    $pass1 = @(& 7z x "$Archive" -o"$Destination" -y -bd 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "7z extraction of '$Archive' failed (exit $LASTEXITCODE): $((($pass1 | Select-Object -Last 5) -join '; '))"
    }
    $tarFile = Get-ChildItem -Path $Destination -Filter '*.tar' | Select-Object -First 1 -ExpandProperty FullName
    if ($tarFile) {
        $pass2 = @(& 7z x "$tarFile" -o"$Destination" -y -bd 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "7z tar extraction of '$tarFile' failed (exit $LASTEXITCODE): $((($pass2 | Select-Object -Last 5) -join '; '))"
        }
    }
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
    $versionsScript = Join-Path $ScriptRoot 'Import-Versions.ps1'
    if (Test-Path $versionsScript) { & $versionsScript }
}

function Get-LlvmArchiverCmakeArg {
    $llvmLib = Resolve-LlvmArchiver
    if ($llvmLib) { return @("-DCMAKE_AR:FILEPATH=$llvmLib") }
    return @()
}

# llvm-ml replaces ml64.exe, the last MSVC tool; unlike the archiver, a missing one throws (see Get-LlvmMasmCmakeArg).
function Resolve-LlvmMasm {
    $llvmMl = (Get-Command 'llvm-ml' -ErrorAction SilentlyContinue).Source
    if (-not $llvmMl) { $llvmMl = (Get-Command 'llvm-ml.exe' -ErrorAction SilentlyContinue).Source }
    return $llvmMl
}
function Get-LlvmMasmCmakeArg {
    # Forward slashes: the value is also expanded inside CMake strings (IREE's custom command).
    $llvmMl = Resolve-LlvmMasm
    if (-not $llvmMl) { throw 'llvm-ml not found on PATH -- the pinned LLVM ships it (bin\llvm-ml.exe); without it the MASM sources would silently fall back to ml64 (#123)' }
    return @("-DCMAKE_ASM_MASM_COMPILER:FILEPATH=$($llvmMl -replace '\\', '/')")
}

<#
.SYNOPSIS
    The one SHA256 pin table for the llvm-project source tarball; returns the pin for -Version.
.DESCRIPTION
    Throws for an unpinned version rather than return empty: an empty -ExpectedSha256 is an unverified download.
    LLVM_WINDOWS_SRC_SHA256 overrides the entry for the version being built.
#>
function Get-LlvmSourceSha256 {
    param(
        [Parameter(Mandatory)][string]$Version
    )
    $pins = @{
        '22.1.8' = '922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888'
        '23.1.0' = 'ab1f0e3ec52448c33e8782eaf0422504b87c7b016b22514653ee0d8fcee479ff'
        '23.1.3' = 'c44186a7762ed28954be72e5ff6df9808e0779d4f1bf014ecc4e7e211d31ee34'
    }
    if ($env:LLVM_WINDOWS_SRC_SHA256) { $pins[$Version] = $env:LLVM_WINDOWS_SRC_SHA256 }
    if (-not $pins.ContainsKey($Version)) {
        throw ("No SHA256 pin for the llvm-project-$Version source tarball - add it to the table in " +
            "Get-LlvmSourceSha256 (windows\scripts\modules\WindowsSourceBuild.Common.psm1), which is the " +
            "ONE place it lives for every consumer. Refusing an unpinned download (backlog #47).")
    }
    return $pins[$Version]
}

<#
.SYNOPSIS
    Fetches and extracts the pin-verified llvm-project source tarball; returns @{ Tarball; SourceDir }.
.DESCRIPTION
    Uses System32 bsdtar: git's GNU tar lacks xz and parses C:\ as a remote host. An existing tree is left
    alone, so Tarball may not exist.
#>
function Get-LlvmSourceTarball {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $sha = Get-LlvmSourceSha256 -Version $Version
    $null = New-Item -ItemType Directory -Force -Path $DestinationRoot
    $tarball = Join-Path $DestinationRoot "llvm-project-$Version.src.tar.xz"
    $srcDir = Join-Path $DestinationRoot "llvm-project-$Version.src"
    if (-not (Test-Path $srcDir)) {
        Invoke-DownloadWithRetry `
            -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$Version/llvm-project-$Version.src.tar.xz" `
            -DestinationPath $tarball -ExpectedSha256 $sha `
            -Description "llvm-project $Version source tarball (backlog #47)"
        $tarExe = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
        if (-not $tarExe) { throw 'No tar.exe found to extract the LLVM source tarball (#47).' }
        & $tarExe -xf $tarball -C $DestinationRoot
        if ($LASTEXITCODE -ne 0) { throw "Extracting $tarball failed (tar exit $LASTEXITCODE) (#47)." }
        if (-not (Test-Path $srcDir)) { throw "LLVM source did not extract to $srcDir - upstream archive layout changed." }
    }
    return @{ Tarball = $tarball; SourceDir = $srcDir }
}

<#
.SYNOPSIS
    Mines clang_rt.builtins-aarch64.lib from the LLVM release archive beside the x86_64 builtins; returns its path.
.DESCRIPTION
    Throws on any failure: the caller owns the fail-open/fail-closed policy.
.PARAMETER Url
    The clang+llvm-<ver>-aarch64-pc-windows-msvc.tar.xz release URL.
.PARAMETER DestinationDir
    The x86_64 builtins directory, which clang and every consumer already search.
.PARAMETER LibName
    Archive member to mine.
.PARAMETER ExpectedSha256
    The versions.env pin; empty warns, never fails.
.PARAMETER PinName
    The versions.env key named in the verify messages.
.PARAMETER WorkDir
    Scratch dir for the archive and extraction (default TEMP_DIR, else TEMP).
#>
function Install-AArch64CompilerRt {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationDir,
        [string]$LibName = 'clang_rt.builtins-aarch64.lib',
        [string]$ExpectedSha256 = '',
        [string]$PinName = 'LLVM_WINDOWS_AARCH64_RT_SHA256',
        [string]$WorkDir = ''
    )

    if (-not (Test-Path $DestinationDir)) {
        throw "aarch64 compiler-rt destination '$DestinationDir' does not exist - refusing a misplaced lib."
    }
    if (-not $WorkDir) { $WorkDir = if ($env:TEMP_DIR) { $env:TEMP_DIR } else { $env:TEMP } }
    # Decode %2B to '+', the archive name the pin was measured on.
    $archiveName = [IO.Path]::GetFileName($Url) -replace '%2B', '+'
    $archive = Join-Path $WorkDir $archiveName
    $extract = Join-Path $WorkDir 'llvm-aarch64-rt'
    try {
        Invoke-DownloadWithRetry -Url $Url -DestinationPath $archive -Description 'aarch64 compiler-rt archive'
        Assert-FileSha256 -Path $archive -Expected $ExpectedSha256 -Label 'aarch64 compiler-rt archive' -PinName $PinName
        # System32 bsdtar, never GNU tar: GNU parses `C:\...` as a remote-host spec.
        $tarExe = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
        if (-not $tarExe) { throw 'No tar.exe found to extract the aarch64 compiler-rt archive.' }
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        & $tarExe -xf $archive -C $extract "*$LibName"
        $found = @(Get-ChildItem -Path $extract -Recurse -Filter $LibName -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($found.Count -eq 0) { throw "$LibName not found inside $archive - upstream archive layout changed." }
        $dest = Join-Path $DestinationDir $LibName
        Copy-Item -Path $found[0].FullName -Destination $dest -Force
        return $dest
    } finally {
        Remove-Item -Path $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-PythonPlatformTag {
    # Clang-built CPython misreports win32; the tag follows the host (pip resolves with it), EXT_SUFFIX the target.
    param(
        [string]$CpythonDir = '',
        [string]$Arch = '',
        # The staged OpenCV tree is the target's on a cross lane; -Arch only steers the platform tag.
        [string]$StagedOpenCvArch = ''
    )
    if ([string]::IsNullOrWhiteSpace($Arch)) { $Arch = Get-WindowsHostArch }
    if ([string]::IsNullOrWhiteSpace($StagedOpenCvArch)) { $StagedOpenCvArch = Get-WindowsTargetArch }
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $platformName = Get-PythonPlatformName -Arch $Arch
    $openCvArchDir = Get-OpenCvArchDir -Arch $StagedOpenCvArch
    $crossExtTag = if (Test-WindowsCrossTarget) { Get-PythonWheelTag } else { '' }
    $sitePackages = Join-Path $CpythonDir 'Lib\site-packages'
    $shim = Write-PythonDllDirectoryShim -SitePackages $sitePackages -OpenCvArchDir $openCvArchDir `
        -PlatformName $platformName -CrossExtTag $crossExtTag -WrittenBy 'Initialize-PythonPlatformTag (HOST build interpreter)'
    Write-Host "Wrote python platform-tag ($platformName) + dll-directory shim: $shim"
    return $shim
}

<#
.SYNOPSIS
    Writes the sitecustomize.py shim that registers the bundle's DLL directories; returns its path.
.DESCRIPTION
    Python >= 3.8 ignores PATH for extension-module dependencies. The here-string expands, so the Python body
    must contain no '$' and no backtick.
.PARAMETER SitePackages
    Directory that receives sitecustomize.py (created if missing).
.PARAMETER OpenCvArchDir
    The opencv5\<arch>\vc18\bin directory the bundle staged.
.PARAMETER PlatformName
    When set, patches sysconfig.get_platform() from 'win32' to this value (host interpreter only).
.PARAMETER CrossExtTag
    When set, pins sysconfig EXT_SUFFIX to this wheel tag (host interpreter on a cross lane only).
#>
function Get-PythonDllHome {
    # The bundle's native DLL homes, which Python >= 3.8 never finds on PATH; the shim and the cp3XYt proof register them.
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$OpenCvArchDir)
    return @(
        "C:\runtime\lib\opencv5\$OpenCvArchDir\vc18\bin",
        'C:\runtime\lib\onnxruntime-source\bin',
        'C:\runtime\lib\onnxruntime-source\lib',
        'C:\runtime\lib\onnxruntime-genai-source\lib',
        'C:\runtime\lib\tvm\lib',
        'C:\runtime\ffmpeg\bin',
        'C:\runtime\bin'
    )
}

function Write-PythonDllDirectoryShim {
    param(
        [Parameter(Mandatory)][string]$SitePackages,
        [Parameter(Mandatory)][string]$OpenCvArchDir,
        [string]$PlatformName = '',
        [string]$CrossExtTag = '',
        [string]$WrittenBy = 'WindowsSourceBuild.Common.psm1'
    )
    New-Item -Path $SitePackages -ItemType Directory -Force | Out-Null
    $shim = Join-Path $SitePackages 'sitecustomize.py'
    $homes = @(Get-PythonDllHome -OpenCvArchDir $OpenCvArchDir | ForEach-Object { "        r'$_'," }) -join [Environment]::NewLine
    Set-Content -Path $shim -Encoding ASCII -Value @"
# Written by $WrittenBy.
# 1) HOST build interpreter only (empty name = nothing happens): clang-built
#    CPython lacks the "64 bit (AMD64)" marker in sys.version, so
#    sysconfig.get_platform() misreports win32 -> pip resolves 32-bit wheels and
#    locally-built wheels get mis-tagged.
# 2) Python 3.8+ ignores PATH when resolving extension-module dependencies;
#    register this bundle's native DLL homes (CUDA 13 keeps its runtime libs in
#    bin\x64, cuDNN 9 likewise) so cv2/onnxruntime/av/tvm pyds import cleanly.
import os
import sys
import sysconfig
_platform_name = '$PlatformName'
if _platform_name and sysconfig.get_platform() == 'win32' and sys.maxsize > 2**32:
    sysconfig.get_platform = lambda: _platform_name
# 3) HOST cross build only (empty tag = nothing happens): extension modules
#    BUILT by this interpreter are for the TARGET interpreter, and setuptools /
#    OpenCV / pybind11 take the .pyd filename tag from this interpreter's
#    EXT_SUFFIX. Pin it to the target so the module is named for the machine
#    that will import it. get_platform() above stays HOST on purpose: pip
#    resolves downloads with it. Importing this interpreter's OWN extensions is
#    unaffected (the import system reads the C-level suffix list, not
#    sysconfig). sysconfig.get_config_vars() returns the live cache, so
#    get_config_var('EXT_SUFFIX') sees the pin too. A free-threaded build
#    interpreter keeps its 't': .cp314t-<tag>.pyd.
_target_tag = '$CrossExtTag'
if _target_tag:
    _abi = 't' if sysconfig.get_config_var('Py_GIL_DISABLED') else ''
    _ext = '.cp%d%d%s-%s.pyd' % (sys.version_info[0], sys.version_info[1], _abi, _target_tag)
    _cv = sysconfig.get_config_vars()
    _cv['EXT_SUFFIX'] = _ext
    _cv['SO'] = _ext
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
$homes
    ]
    for _d in _dirs:
        if os.path.isdir(_d):
            try:
                os.add_dll_directory(_d)
            except OSError:
                pass
"@
    return $shim
}

function Test-PythonImport {
    # Through cmd.exe, judged by exit code only: a stderr-noisy success must not read as a failure.
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$VersionExpression = ''
    )
    # -I keeps a same-named source dir in CWD from shadowing the wheel; single quotes only, PS 5.1 strips double ones.
    if (-not $VersionExpression) { $VersionExpression = "getattr($ModuleName, '__version__', 'imported')" }
    $out = cmd.exe /c """$($Python.Exe)"" -I -c ""import $ModuleName; print($VersionExpression)"" 2>&1"
    $code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $tail = if ($out) { (@($out) | Select-Object -Last 1).ToString().Trim() } else { '' }
    if ($code -ne 0) { throw "import $ModuleName failed right after install (exit $code): $tail" }
    Write-Host "$ModuleName python binding OK ($tail)"
}

function Install-StagedPythonWheel {
    # -NoDeps is for wheels whose metadata is unsatisfiable by design.
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
    # The final image exposes C:\runtime\wheels as PYTHON_WHEELS.
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
    # A cp3XYt wheel here would reach every GIL install of the store; Save-FreeThreadedWheel stores the twins apart.
    $twins = @($wheels | Where-Object { $_.Name -match '-cp\d+-cp\d+t-[^-]+\.whl$' })
    if ($twins.Count -gt 0) { throw "Save-PythonWheel: $($twins.Name -join ', ') is free-threaded and never goes into $WheelDir; Save-FreeThreadedWheel stores it in $(Get-FreeThreadedWheelStore)" }
    foreach ($w in $wheels) {
        Copy-Item $w.FullName -Destination $WheelDir -Force
        Write-Host "Staged wheel: $($w.Name) -> $WheelDir"
    }
    return @($wheels | ForEach-Object { Join-Path $WheelDir $_.Name })
}

function Initialize-ToolchainPythonEnvironment {
    # -Arch defaults to empty: Enter-VsDevCmdEnvironment resolves the target arch only from an empty string.
    param(
        [string]$Arch = '',
        [string]$HostArch = 'amd64'
    )
    Enter-VsDevCmdEnvironment -Arch $Arch -HostArch $HostArch
    Copy-CpythonPyConfigHeader
    # -Arch is not forwarded: the platform-tag shim configures the host interpreter.
    Initialize-PythonPlatformTag | Out-Null
    return Get-SourceBuildPython
}

# sccache server session: best-effort, a missing or dead server must never fail a green build.

function Start-SccacheServerSession {
    # sccache reads SCCACHE_ERROR_LOG only at server start, so start a fresh server before the first compile.
    [CmdletBinding()]
    param(
        [string]$SccachePath = ''
    )
    if (-not $SccachePath) {
        # StrictMode-safe: .Source on a $null Get-Command result throws.
        $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
        if ($sccacheCmd) { $SccachePath = $sccacheCmd.Source }
    }
    if (-not $SccachePath) { return }
    Write-Host "Starting the sccache server from a STABLE working directory (backlog #99)..."
    try {
        # Stop first so this start wins; "no connection could be made" is expected in a fresh container.
        & $SccachePath --stop-server 2>&1 | ForEach-Object { Write-Host "  sccache-prologue| $_" }

        # The sccache-logs mount is append-only, so without truncation the epilogue replays old failures.
        if ($env:SCCACHE_ERROR_LOG) {
            try {
                $errDir = Split-Path $env:SCCACHE_ERROR_LOG -Parent
                if ($errDir -and -not (Test-Path $errDir)) {
                    $null = New-Item -ItemType Directory -Force -Path $errDir -ErrorAction Stop
                }
                Set-Content -Path $env:SCCACHE_ERROR_LOG -Value $null -Force -ErrorAction Stop
                Write-Host "  sccache-prologue| truncated $($env:SCCACHE_ERROR_LOG) (per-stage attribution)"
            } catch {
                Write-Host "  sccache-prologue| WARNING: could not truncate the error log: $($_.Exception.Message)"
                Write-Host "  sccache-prologue| WARNING: the epilogue dump may contain entries from EARLIER runs."
            }
        }

        Push-Location 'C:\'
        try {
            & $SccachePath --start-server 2>&1 | ForEach-Object { Write-Host "  sccache-prologue| $_" }
        } finally { Pop-Location }
    } catch {
        Write-Verbose "sccache prologue skipped: $($_.Exception.Message)"
    }
    $global:LASTEXITCODE = 0
}

function Complete-SccacheServerSession {
    # With SCCACHE_IDLE_TIMEOUT=0 the server never exits, so stop it to flush its error log and webdav tail.
    [CmdletBinding()]
    param(
        [string]$SccachePath = ''
    )
    if (-not $SccachePath) {
        # StrictMode-safe: .Source on a $null Get-Command result throws.
        $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
        if ($sccacheCmd) { $SccachePath = $sccacheCmd.Source }
    }
    if ($SccachePath) {
        Write-Host 'Stopping the sccache server so its error log + webdav tail flush before the layer closes...'
        try {
            & $SccachePath --stop-server 2>&1 | ForEach-Object { Write-Host "  sccache| $_" }
        } catch {
            Write-Warning "sccache --stop-server failed (non-fatal): $($_.Exception.Message)"
        }
    }

    # Dump the server log into this run's log: a later build's --no-cache empties the mount first.
    $errLog = $env:SCCACHE_ERROR_LOG
    if ($errLog -and (Test-Path $errLog)) {
        $lines = @(Get-Content $errLog -ErrorAction SilentlyContinue)
        Write-Host "`n=== sccache server log ($($lines.Count) lines, $errLog) ==="
        # Failures in full; otherwise only a tail, not a debug-level flood.
        $failures = @($lines | Select-String -Pattern 'ERROR|WARN|failed|denied|refused' -SimpleMatch:$false)
        if ($failures.Count -gt 0) {
            Write-Host "--- $($failures.Count) error/warn line(s) ---"
            $failures | Select-Object -Last 60 | ForEach-Object { Write-Host "  sccache-log| $_" }
        } else {
            Write-Host '--- no error/warn lines; tail follows ---'
            $lines | Select-Object -Last 20 | ForEach-Object { Write-Host "  sccache-log| $_" }
        }
        Write-Host '=== end sccache server log ==='
    } elseif ($errLog) {
        Write-Host "sccache server log NOT written ($errLog) - the server never opened it."
    }
    $global:LASTEXITCODE = 0
}

function Invoke-SourceBuildChain {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Stages,
        [string]$InstallDir = 'C:\runtime',
        [string]$ScriptDir  = 'C:\temp\scripts',
        # Skip the stages before this one; an unknown name throws so a typo cannot rebuild from the start.
        [string]$StartAt = '',
        # Stop after this stage (inclusive) so the BuildKit lane can split a chain across RUN layers.
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
    Start-SccacheServerSession

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
        # An Invoke scriptblock wraps a script whose signature differs from the chain contract.
        if ($stage.ContainsKey('Invoke')) {
            & $stage.Invoke $ScriptDir $InstallDir
        } else {
            & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
        }
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($exitCode) { throw "$($stage.Name) build failed (exit $exitCode)" }
        if ($Until -and ($stage.Name -eq $Until)) {
            Write-Host "`n=== $Label chain: stopped after '$Until' (-Until) — remaining stages run in a later layer ==="
            break
        }
    }
    # The counters die with the container, so this is the last chance to log them.
    Write-SccacheStats -Label $Label
    Stop-LingeringBuildProcess
}

# BuildKit warm/materialize handoff: heavy-churn containers cannot finalize, and cache mounts reject renames.

function Export-BuildHandoff {
    # WebDAV, not a cache mount: BuildKit clones a locked cache mount, so two solves may see different copies.
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
    # System32 paths: scoop's git puts MSYS tar on PATH, which parses a drive path as a remote host.
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -cf $tarFile -C C:\ -T $listFile
    if ($LASTEXITCODE -ne 0) { throw "Export-BuildHandoff: tar failed (exit $LASTEXITCODE)" }
    # --retry-all-errors: this PUT is the only copy of an hours-long warm build.
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -T $tarFile "$Endpoint/bkhandoff/$Name.tar"
    if ($LASTEXITCODE -ne 0) { throw "Export-BuildHandoff: upload to $Endpoint/bkhandoff/$Name.tar failed (exit $LASTEXITCODE)" }
    $sizeMb = [math]::Round((Get-Item $tarFile).Length / 1MB, 1)
    Remove-Item $tarFile, $listFile -Force -ErrorAction SilentlyContinue
    Write-Host "Export-BuildHandoff: $($entries.Count) files ($sizeMb MB) -> $Endpoint/bkhandoff/$Name.tar"
    $global:LASTEXITCODE = 0
}

function Import-BuildHandoff {
    # Runs as the only work of a calm RUN layer.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Endpoint = $env:SCCACHE_WEBDAV_ENDPOINT
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        throw 'Import-BuildHandoff: no -Endpoint and SCCACHE_WEBDAV_ENDPOINT is unset'
    }
    $tarFile = Join-Path $env:TEMP "handoff-$Name.tar"
    # Same retries as the upload: one HTTP round-trip gates the whole layer.
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -o $tarFile "$Endpoint/bkhandoff/$Name.tar"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tarFile)) {
        throw "Import-BuildHandoff: download $Endpoint/bkhandoff/$Name.tar failed - did the warm solve run?"
    }
    # The tar holds files only, and bsdtar's long-path mode does not create missing parents.
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
    # Best-effort: build scratch in the container profile is dead weight in an exported image.
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

function Disable-ContainerWindowsUpdate {
    # An .msu spooled during a RUN kills the layer finalize; host-guarded so it never touches a developer's updates.
    [CmdletBinding()]
    param([switch]$Force)
    if (-not $Force -and -not (Get-Service -Name 'cexecsvc' -ErrorAction SilentlyContinue)) {
        Write-Host 'Disable-ContainerWindowsUpdate: not inside a Windows container (no cexecsvc) -- skipped'
        return
    }
    $touched = @()
    foreach ($svc in @('wuauserv', 'UsoSvc')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        try {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction Stop }
            Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
            $touched += $svc
        } catch { Write-Warning "Disable-ContainerWindowsUpdate: could not disable $svc -- $($_.Exception.Message)" }
    }
    try {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
        New-ItemProperty -Path $au -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force | Out-Null
    } catch { Write-Warning "Disable-ContainerWindowsUpdate: could not set the NoAutoUpdate policy -- $($_.Exception.Message)" }
    # Informational: only a file written during this RUN lands in the layer diff.
    $spool = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $spoolItems = if (Test-Path $spool) { @(Get-ChildItem -LiteralPath $spool -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Host ("Disable-ContainerWindowsUpdate: services disabled [{0}], NoAutoUpdate=1; spool holds {1} item(s) at RUN start (inherited -- only files written during this RUN can poison the layer)" -f ($touched -join ', '), $spoolItems)
    $global:LASTEXITCODE = 0
}

function Stop-LingeringBuildProcess {
    # MSVC daemons still holding sandbox handles fail the snapshot finalize; sccache lingers harmlessly, so it is not listed.
    [CmdletBinding()]
    param(
        # Kill even outside a container (tests use this with fake process names).
        [switch]$Force
    )
    # Host guard (cexecsvc exists only in Windows containers): never kill a developer's live VS session.
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
        if (-not $primary) {
            # Loud: a missing primary means the upstream install step failed.
            Write-Warning "Copy-SidecarDll: primary '$BesidePrimary' not found under $InstallDir -- skipping $SidecarName staging ($Reason)"
            return
        }
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

# The test suites consume the export list too (Save-PythonWheel, Get-CudaRoot, Resolve-TensorRtRoot, sccache).
function Complete-SourceBuildChain {
    # Scrub here, not downstream: layers are additive, so a later delete only adds a whiteout.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$ScrubAfter
    )
    Write-Host "`n=== $Label chain completed ==="

    Complete-SccacheServerSession

    if ($ScrubAfter) { Clear-BuildScratch }
    # Callers still end with `exit 0`: pwsh -File otherwise propagates the last native exit code.
    $global:LASTEXITCODE = 0
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Get-PersistentBuildLogPath',
    'Invoke-SourceBuildChain',
    'Complete-SourceBuildChain',
    'Start-SccacheServerSession',
    'Complete-SccacheServerSession',
    # Stop-LingeringBuildProcess stays internal.
    'Export-BuildHandoff',
    'Import-BuildHandoff',
    'Clear-BuildScratch',
    'Disable-ContainerWindowsUpdate',
    'Invoke-ShieldedNative',
    'Invoke-GitClone',
    'Reset-SourceBuildDirectory',
    'Invoke-CmakeConfigure',
    'Get-CMakeRocmIsolationArgs',
    'Assert-CmakeArgsConsumed',
    'Test-SccacheRemoteConfigured',
    # Re-exported from WindowsScripts.Shared: scripts cannot see nested-module exports.
    'Get-SccacheStatsText',
    'Write-SccacheStatsToStderr',
    'Write-SccacheStats',
    'Save-PythonWheel',
    'Get-CudaRoot',
    'Resolve-TensorRtRoot',
    'Enter-VsDevCmdEnvironment',
    'Get-MsvcToolsRoot',
    'Copy-CpythonPyConfigHeader',
    'Select-CpythonImportLib',
    'Get-CpythonFreeThreadedRoot',
    'Get-CpythonFreeThreadedExeName',
    'Get-CpythonFreeThreadedBuildDir',
    'Get-CpythonPcbuildArguments',
    'Invoke-CpythonPcbuild',
    'Install-CpythonFreeThreadedLayout',
    'Assert-CpythonInterpreter',
    'Install-CpythonTargetTree',
    'Get-SourceBuildPython',
    'Get-TargetBuildPython',
    'Get-PythonDllHome',
    'Write-PythonDllDirectoryShim',
    'Invoke-WithHostArchLibraryEnvironment',
    'Add-NinjaPerTuFlags',
    'Resolve-QnnSdk',
    'Copy-QnnRuntime',
    'Write-AbsentOnCrossMarker',
    'Get-PythonCMakeHintArgs',
    'Invoke-HostToolCmakeBuild',
    'Assert-PeTargetMachine',
    'Assert-DirectoryTargetArch',
    'Assert-PythonExtensionTag',
    'Get-PeImportNames',
    'Assert-WheelTargetArch',
    'Get-PeFileMachine',
    'Edit-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Invoke-OnnxDmlClangClPatch',
    'Invoke-SourcePatchWithFallback',
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
    'Get-CudnnLibraryDir',
    'Get-CudnnLibrary',
    'Test-CudaWindowsArm64Payload',
    'Get-NvccHostCompilerPath',
    'Get-LlvmArchiverCmakeArg',
    # Called directly by Build-LlvmFromSource.ps1 and Build-TvmFromSource.ps1.
    'Get-LlvmSourceSha256',
    'Get-LlvmSourceTarball',
    # Called directly by Build-LlvmFromSource.ps1 and Build-GstreamerFromSource.ps1.
    'Install-AArch64CompilerRt',
    'Resolve-LlvmMasm',
    'Get-LlvmMasmCmakeArg',
    'Initialize-SourceBuildEnvironment',
    'Initialize-SourceBuildScript',
    'Initialize-ToolchainPythonEnvironment',
    'Initialize-PythonPlatformTag',
    'Install-StagedPythonWheel',
    'Invoke-PythonWheelBuild',
    'Get-FreeThreadedWheelStore',
    'Get-FreeThreadedAbiTag',
    'Get-FreeThreadedTwinPlan',
    'Assert-NinjaFreeThreadedDefine',
    'New-FreeThreadedBuildPython',
    'Invoke-FreeThreadedTwinWheel',
    'Get-FreeThreadedWheelImportFinding',
    'Save-FreeThreadedWheel',
    'Get-FreeThreadedStoreFinding',
    # Re-exported from WindowsPythonWheel.Common for the build scripts' same-build check.
    'Get-WheelMemberDifference',
    'Test-PythonImport',
    'Remove-SourceBuildTree',
    'Complete-SourceBuild',
    'Get-BuildJobCount',
    'Get-WarningNoiseSuppressionFlags',
    'Start-BuildPhase',
    'Switch-BuildPhase',
    'Complete-CurrentBuildPhase',
    'Complete-BuildPhase',
    'Write-BuildPhaseSummary',
    'Install-CpythonPip',
    'Invoke-CpythonPip',
    'Copy-BuildArtifact',
    'Copy-SidecarDll',
    'Get-NvccCudaCmakeArgs',
    'Get-WindowsTargetArch',
    'Get-WindowsTargetArchInfo',
    'Get-WindowsHostArch',
    'Test-WindowsCrossTarget',
    'Get-ClangTargetTriple',
    'Get-VsDevCmdArch',
    'Get-PeMachineType',
    'Get-VcpkgTriplet',
    'Get-MsvcTargetBinDir',
    'Get-MsvcTargetLibDir',
    'Get-VulkanLibDirName',
    'Get-VulkanBinDirName',
    'Get-PythonWheelTag',
    'Get-QnnSdkLibDirName',
    'Get-PythonPlatformName',
    'Get-CpythonBuildPlatform',
    'Get-CpythonOutputDir',
    'Get-RustTargetTriple',
    'Get-OpenCvArchDir',
    'Get-WindowsRuntimeIdentifier',
    'Get-WindowsTargetTagSuffix',
    'Get-FfmpegTargetArch',
    'Get-LibMachineArg',
    'Get-WindowsTargetSimdFlags',
    'Get-WindowsTargetKernelSimdFlags',
    'Get-MlasKernelTuPattern',
    'Get-MlasKernelTuMinimum',
    'Get-CMakeCrossArgs',
    # Called directly by Build-GstreamerFromSource.ps1; Modules.ScriptCallClosure.Tests.ps1 gates it.
    'Resolve-BuildMachineMsvcTool',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    # Re-exported so Build-LlvmFromSource.ps1 needs no second module import.
    'Assert-FileSha256',
    # Called directly by Build-LlvmFromSource.ps1 and Build-GstreamerFromSource.ps1.
    'Get-PreferredToolPath',
    # Called directly by Build-GstreamerFromSource.ps1.
    'Start-SccacheStallGuard',
    'Stop-SccacheStallGuard'
)

