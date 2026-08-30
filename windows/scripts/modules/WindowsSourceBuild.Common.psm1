# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded and WITHOUT -Force: a forced nested re-import rebinds the dependency into
# this module's scope and unloads the caller's top-level import. See
# docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

$patchesPath = Join-Path $PSScriptRoot 'WindowsSourceBuild.Patches.psm1'
$cudaPath    = Join-Path $PSScriptRoot 'WindowsSourceBuild.Cuda.psm1'
$nativePath  = Join-Path $PSScriptRoot 'WindowsNative.Common.psm1'
$targetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if ((Test-Path $patchesPath) -and -not (Get-Module -Name 'WindowsSourceBuild.Patches')) { Import-Module $patchesPath }
if ((Test-Path $cudaPath) -and -not (Get-Module -Name 'WindowsSourceBuild.Cuda')) { Import-Module $cudaPath }
# Canonical stderr-shield for native calls, re-exported here. Every COPY list
# that carries this module must carry WindowsNative.Common.psm1 too.
if (Test-Path $nativePath) {
    if (-not (Get-Module -Name 'WindowsNative.Common')) { Import-Module $nativePath }
} else {
    function Invoke-ShieldedNative {
        throw 'Invoke-ShieldedNative unavailable: WindowsNative.Common.psm1 is not next to WindowsSourceBuild.Common.psm1 (incomplete modules COPY list)'
    }
}
# Canonical TARGET-architecture facts, re-exported on the same terms as
# WindowsNative.Common above; ship the module in every COPY list that has this one.
if (Test-Path $targetArchPath) {
    if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchPath }
} else {
    # THROW AT IMPORT, not a stub: ~29 names are re-exported and Export-ModuleMember
    # ignores unmatched ones, so a broken COPY list would otherwise surface as a bare
    # CommandNotFoundException deep inside the VsDevCmd bootstrap.
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
    # MOUNT-FRIENDLY reset: a BuildKit cache-mount target dir cannot be removed
    # ("used by another process"), so clear its CONTENTS -- git clones into an empty
    # dir (docs/windows-builds.md § BuildKit/containerd lane). Any leftover tree is
    # wiped either way: callers that want incremental reuse must skip the reset.
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
        # #116: one TCP drop killed a 4-hour ride, and the driver does not
        # infra-retry script failures, so the clone must retry ITSELF.
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 10
    )

    $ref = if ($Tag) { $Tag } else { $Branch }
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'Either -Branch or -Tag is required' }

    # A 40-char hex string is a commit hash, not a branch/tag name: `git clone
    # --branch <hash>` fails ("Remote branch <hash> not found"). Clone the
    # default branch, then fetch + checkout the commit. Mirrors the Linux lane
    # (tvm.sh lines 183-198). A shorter hex prefix also works with `git fetch`.
    $isCommitHash = $ref -match '^[0-9a-f]{7,40}$'

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # Mount-safe wipe EVERY attempt: a half-transferred clone is unusable and
        # git refuses a non-empty directory.
        Reset-SourceBuildDirectory -Path $SourceDir

        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $env:GIT_TERMINAL_PROMPT = '0'

        if ($isCommitHash) {
            # Full clone (no --branch, no --depth): the commit may not be on the
            # default branch's tip. Then fetch the commit shallowly and checkout.
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
        # [Alias('T')] is defensive: PowerShell binds parameters by unambiguous
        # PREFIX, so a second T-parameter would make a bare `-T v143` ambiguous.
        [Alias('T')]
        [string]$Toolset = '',
        [string]$BuildType = 'Release',
        [string]$CCompiler = 'clang-cl',
        [string]$CxxCompiler = 'clang-cl',
        [string]$Linker = 'lld-link',
        [string]$Archiver = 'llvm-lib',
        [string[]]$ExtraArgs = @(),
        # Per-call cross override; empty resolves WINDOWS_TARGET_ARCH, so the amd64
        # lane is unchanged. It exists for the HOST-TOOL configure, which also needs
        # Invoke-WithHostArchLibraryEnvironment -- this parameter alone is not enough.
        [string]$TargetArch = '',
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
            # CUDA launcher gated at THIS wiring site only (one switch, one place);
            # rehabilitated 2026-08-18 by the #114 sccache patch series
            # (mozilla/sccache#2811), three-canary bar applies. C/CXX are unconditional.
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

    # THE cross choke point: nearly every library in the chain configures through
    # here. Get-CMakeCrossArgs is empty on the host arch (the @() wrap is
    # load-bearing under StrictMode), and it goes BEFORE $ExtraArgs so a caller's
    # explicit -D still wins -- cmake honours the LAST occurrence.
    $crossArgs = @(Get-CMakeCrossArgs -Arch $TargetArch)
    if ($crossArgs.Count -gt 0) {
        $cmakeArgs += $crossArgs
        Write-Host "CMake cross-compiling for $(Get-WindowsTargetArch -Arch $TargetArch): $($crossArgs -join ' ')"
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

# Test-SccacheRemoteConfigured lives in WindowsScripts.Shared.psm1; still
# re-exported from here for existing consumers.

function Write-SccacheStats {
    # The counters live in the sccache server and die with the container, so this
    # is the only moment they exist. Never fails the build. -RequireRemote keeps
    # the silent no-op without a remote backend (a query would spawn a local server).
    param([string]$Label = 'build')
    $lines = Get-SccacheStatsText -RequireRemote
    if ($null -eq $lines) { return }
    Write-Host "`n=== sccache stats ($Label) ==="
    $lines | ForEach-Object { Write-Host $_ }
}

function Enter-VsDevCmdEnvironment {
    # -Arch defaults to the resolved TARGET arch, so every caller is cross-correct
    # unchanged; -HostArch stays literal amd64 (no arm64 Windows base image exists).
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

    # TWO gates: a non-zero VsDevCmd exit means the `&& set` never ran (no env vars,
    # surfacing hours later as cryptic INCLUDE/LIB errors), and it can also print an
    # error banner and exit 0 -- so require a sentinel var to have landed as well.
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
    # Runs $ScriptBlock with LIB/LIBPATH rewritten from the TARGET arch's library
    # dirs to the HOST's -- the missing half of a host-tool pass on a cross lane
    # (lld-link reads only LIB; a second VsDevCmd appends rather than resets).
    # No-op on the native lane.
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
        # A variable that was UNSET must end up unset again -- not defined-empty.
        # A variable that was UNSET must end up unset, not defined-empty:
        # SetEnvironmentVariable($name, $null) leaves LIB= in the process block,
        # and lld-link then skips its MSVC/SDK auto-detection.
        foreach ($name in 'LIB', 'LIBPATH') {
            if ($null -eq $saved[$name]) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }
}

# The throwing face of Shared's vswhere discovery (Get-VisualStudioInstallPath /
# Get-MsvcToolsRoots): no Visual Studio means no source build.
function Get-MsvcToolsRoot {
    # @() re-wrap is LOAD-BEARING: PowerShell flattens a single-element array on
    # return, so with exactly ONE installed toolset the [0] index would read a
    # STRING and yield a single letter -- a silently misdirected patch path.
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
    # HOST-PINNED: every call site EXECUTES .Exe, and an aarch64 python.exe cannot
    # run on the x64 build host. .LibDir/.Lib are the HOST import libs -- LINK
    # inputs for the target come from Get-TargetBuildPython.
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $hostOutDir = Get-CpythonOutputDir -Arch (Get-WindowsHostArch)
    $exe = Join-Path $CpythonDir "PCbuild\$hostOutDir\python.exe"
    $include = Join-Path $CpythonDir 'Include'
    $libDir = Join-Path $CpythonDir "PCbuild\$hostOutDir"
    $lib = if (Test-Path (Join-Path $libDir 'python314.lib')) { Join-Path $libDir 'python314.lib' } else { Join-Path $libDir 'python3.lib' }
    return @{ Exe = $exe; Include = $include; LibDir = $libDir; Lib = $lib }
}

function Get-TargetBuildPython {
    # TARGET-arch complement to Get-SourceBuildPython (#120): .Exe stays the HOST
    # interpreter, .Include is arch-neutral, .LibDir/.Lib are the TARGET import
    # lib. Consumers MUST honour .Available -- -ResumeFrom can enter this chain
    # after build-target-cpython.ps1 would have run.
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $hostPy = Get-SourceBuildPython -CpythonDir $CpythonDir
    if (-not (Test-WindowsCrossTarget)) {
        return @{ Exe = $hostPy.Exe; Include = $hostPy.Include; LibDir = $hostPy.LibDir; Lib = $hostPy.Lib
                  Available = (Test-Path $hostPy.Lib) }
    }
    $tgtOutDir = Join-Path $CpythonDir "PCbuild\$(Get-CpythonOutputDir)"
    $tgtLib = Get-ChildItem -Path $tgtOutDir -Filter 'python3*.lib' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^python3\d+\.lib$' } | Select-Object -First 1
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
    # Deliberately NO Set-StrictMode/$ErrorActionPreference here: set inside a
    # module function they affect only this scope. Every build script sets its own.
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }
    # sccache does not create the parent dir of its error log, and the server
    # spawns on the first wrapped compile, so create it before any cmake (#23).
    if ($env:SCCACHE_ERROR_LOG) {
        $errLogDir = Split-Path $env:SCCACHE_ERROR_LOG -Parent
        if ($errLogDir -and -not (Test-Path $errLogDir)) {
            $null = New-Item -ItemType Directory -Force -Path $errLogDir -ErrorAction SilentlyContinue
        }
    }
    # Keeps Windows Update from dropping an .msu into the layer -- see the
    # function for the measured finalize failure. No-op outside a container.
    Disable-ContainerWindowsUpdate
    return $InstallDir
}

function Initialize-SourceBuildScript {
    # Standard build-script preamble: resolve the install prefix, then load
    # versions.env. Scripts with work between the two call the parts directly.
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
    Appends per-TU flags to build.ninja FLAGS lines chosen by a selector, with a
    coverage floor. ONE implementation for MLAS (ORT), XNNPACK (LiteRT) and the
    IREE arm_64 ukernels (#131).
.DESCRIPTION
    Walks build.ninja once; -Select receives each `build ...` line and returns the
    flags to append to that target's FLAGS line, or nothing to leave it alone. The
    floor is load-bearing: a selector that matches nothing SUCCEEDS silently, so
    below -Floor the file is left untouched and the call throws with the count.
    -AlreadyTaggedPattern makes a re-run idempotent.
.OUTPUTS
    [int] tagged FLAGS lines.
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
    Writes the standard ABSENT-ON-<ARCH>.txt marker for a component a cross branch
    cannot build, creating the (empty) directories the merge's unconditional COPY
    expects. Returns the marker path.
.DESCRIPTION
    The one convention for "not built for the target" (#131). The marker travels
    INTO the shipped bundle, so an empty directory carries its reason on the spot.
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
    Composes the CMake FindPython hint trio (EXECUTABLE / INCLUDE_DIR / LIBRARY)
    for one or more variable prefixes from a Get-TargetBuildPython object -- host
    interpreter to RUN, target import lib to LINK.
.DESCRIPTION
    The spellings are not interchangeable: ORT -> Python; GenAI -> Python AND the
    pybind11-classic PYTHON; OpenCV -> PYTHON3 with forward slashes.
    -NumPyIncludeDir adds <first prefix>_NumPy_INCLUDE_DIR.
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
    Configures and builds a HOST-tool tree on a cross lane: host target on the
    choke point AND the host's LIB/LIBPATH for the duration -- the pair LiteRT's
    flatc pass and IREE's host pass both need. Native lane: a plain configure+build.
.DESCRIPTION
    Returns the install prefix's bin dir when -Install, else the build dir.
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
    # `| Out-Host` is LOAD-BEARING: the block's pipeline output would otherwise
    # become part of this function's return value, handing a caller build-log
    # lines with the path last.
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
    Locates, verifies and extracts a hand-staged Qualcomm AI Engine Direct
    (QAIRT/"QNN") SDK zip; returns the facts the ONNX build needs, or $null when
    no zip is staged (the default, supported state).
.DESCRIPTION
    Backlog #121. Contract (same as the TensorRT zip): exactly one *.zip in
    -DropDir; optional -ExpectedSha256 (empty = unverified, with a warning); the
    SDK root is wherever include\QNN\QnnInterface.h lives; the target's
    lib\<arch>\QnnCpu.dll must exist. Throws on two zips, a hash mismatch, a
    non-SDK zip or a missing backend set -- never silently.
.OUTPUTS
    $null, or @{ Home; LibDir; CmakeArgs } (CmakeArgs = the two -D switches).
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
    $sha = "$ExpectedSha256".Trim()
    if ($sha) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash
        if (-not [string]::Equals($actual, $sha, [StringComparison]::OrdinalIgnoreCase)) { throw "QNN: SDK zip SHA256 mismatch for ${zip}: expected $sha, got $actual" }
        Write-Host 'QNN: SDK zip SHA256 verified (QNN_SDK_ZIP_SHA256).'
    } else {
        Write-Warning 'QNN: QNN_SDK_ZIP_SHA256 is empty -- extracting the staged SDK zip UNVERIFIED (pin it in versions.env, same contract as TENSORRT_ZIP_SHA256)'
    }
    if (-not $ExtractDir) { $ExtractDir = Join-Path $env:TEMP_DIR 'qnn-sdk-extract' }
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $ExtractDir -Force
    $anchor = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'QnnInterface.h' -File | Where-Object { $_.Directory.Name -eq 'QNN' } | Select-Object -First 1
    if (-not $anchor) { throw "QNN: include\QNN\QnnInterface.h not found under the extracted SDK ($ExtractDir) -- not a QAIRT SDK zip?" }
    $home_ = $anchor.Directory.Parent.Parent.FullName
    $libDir = Join-Path $home_ "lib\$(Get-QnnSdkLibDirName -Arch $Arch)"
    if (-not (Test-Path (Join-Path $libDir 'QnnCpu.dll'))) { throw "QNN: $libDir\QnnCpu.dll missing -- the SDK carries no $(Get-QnnSdkLibDirName -Arch $Arch) backend set for this target" }
    # Version compatibility check: the ORT version we build may reference QNN
    # ops that are absent from an older SDK. QNN_OP_STFT is the canary — it
    # was added in QNN API 2.25+ and ORT 1.29 uses it. When the SDK is too
    # old, warn and return $null (QNN off) rather than failing the build.
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
    Stages the QNN runtime beside onnxruntime.dll (the per-arch backend DLLs and
    the hexagon-v* skel dirs), after asserting the provider DLL was installed.
    Returns the number of DLLs staged.
#>
function Copy-QnnRuntime {
    param(
        [Parameter(Mandatory)]$Sdk,            # Resolve-QnnSdk result
        [Parameter(Mandatory)][string]$OrtInstallDir
    )
    # Find the bin dir: prefer onnxruntime.dll (ORT), but fall back to any DLL
    # (GenAI, LiteRT, TVM, IREE don't have onnxruntime.dll but do have their own DLLs).
    $ortDll = Get-ChildItem -Path $OrtInstallDir -Recurse -Filter 'onnxruntime.dll' -File | Select-Object -First 1
    if (-not $ortDll) {
        $anyDll = @(Get-ChildItem -Path $OrtInstallDir -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $anyDll) {
            # No DLLs at all yet — use a bin dir under the install root
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
    # Shared wheel-build shape for the ONNX + GenAI scripts: run python through the
    # cmd.exe stderr shield (setup.py logs to stderr under EAP=Stop), gate on the
    # exit code, then install the freshest wheel from the dist dir.
    param(
        [Parameter(Mandatory)] $Python,           # Get-SourceBuildPython object
        [Parameter(Mandatory)] [string]$WorkingDir,
        [Parameter(Mandatory)] [string]$Arguments, # e.g. 'setup.py bdist_wheel'
        [Parameter(Mandatory)] [string]$ModuleName,
        [string]$DistDir = '',
        [switch]$NoDeps,
        # CROSS LANE (#120): BUILD + STAGE only -- the .pyd is aarch64, so it cannot
        # be installed or import-asserted here. Every PE member of the staged wheel
        # is machine-checked instead; the merge arch gate cannot see inside a zip.
        [switch]$StageOnly,
        # ONE call for both lanes (#131): on a cross lane this implies -StageOnly and
        # appends `--plat-name <target tag>`; on the native lane it is a no-op.
        [switch]$CrossStage
    )
    if ($CrossStage -and (Test-WindowsCrossTarget)) {
        $StageOnly = $true
        if ($Arguments -match '\bbdist_wheel\b' -and $Arguments -notmatch '--plat-name') { $Arguments = "$Arguments --plat-name $(Get-PythonWheelTag)" }
        Write-Host "python wheel ($ModuleName): cross lane -- building for $(Get-PythonWheelTag), staging only (never installed or imported here)"
    }
    if (-not $DistDir) { $DistDir = Join-Path $WorkingDir 'dist' }
    Push-Location $WorkingDir
    try {
        cmd.exe /c """$($Python.Exe)"" $Arguments 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "python wheel build failed (exit $LASTEXITCODE): $Arguments" }
    } finally { Pop-Location }
    if ($StageOnly) {
        $staged = @(Save-PythonWheel -SourceDir $DistDir -Required)
        foreach ($w in $staged) { Assert-WheelTargetArch -WheelPath $w }
        return $staged[0]
    }
    return Install-StagedPythonWheel -Python $Python -SourceDir $DistDir -ModuleName $ModuleName -NoDeps:$NoDeps
}

# Writes the dist-info a binary wheel needs (METADATA, WHEEL, top_level.txt) into
# an already-laid-out package tree; `python -m wheel pack` then produces RECORD +
# the archive. Generic in every parameter (#134) -- assembling a wheel by hand is
# what every cross consumer scikit-build-core cannot build has to do.
# Fixture test: SourceBuild.TvmAssembledWheel.Tests.ps1.
function Write-AssembledWheelDistInfo {
    param(
        [Parameter(Mandatory)][string]$Name,        # distribution name, e.g. apache-tvm-ffi
        [Parameter(Mandatory)][string]$Version,     # PEP 440
        [Parameter(Mandatory)][string]$PackageRoot, # dir whose child dirs are the top-level packages
        [string]$PythonTag = 'cp314',
        [string]$AbiTag = 'cp314',
        [string]$PlatformTag = 'win_arm64',
        [string[]]$RequiresDist = @(),
        [string]$RequiresPython = '',
        [string]$Summary = '',
        [string]$Generator = 'kataglyphis-assembled-wheel'
    )
    if (-not (Test-Path $PackageRoot -PathType Container)) { throw "Write-AssembledWheelDistInfo: package root $PackageRoot does not exist" }
    $distName = ($Name -replace '[-_.]+', '_')
    $distInfo = Join-Path $PackageRoot "$distName-$Version.dist-info"
    New-Item -Path $distInfo -ItemType Directory -Force | Out-Null
    $meta = @('Metadata-Version: 2.1', "Name: $Name", "Version: $Version")
    if ($Summary) { $meta += "Summary: $Summary" }
    if ($RequiresPython) { $meta += "Requires-Python: $RequiresPython" }
    foreach ($r in $RequiresDist) { if ($r) { $meta += "Requires-Dist: $r" } }
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'METADATA'), (($meta -join "`n") + "`n"))
    $wheelMeta = @('Wheel-Version: 1.0', "Generator: $Generator", 'Root-Is-Purelib: false', "Tag: $PythonTag-$AbiTag-$PlatformTag")
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'WHEEL'), (($wheelMeta -join "`n") + "`n"))
    $top = @(Get-ChildItem -Path $PackageRoot -Directory | Where-Object { $_.Name -notlike '*.dist-info' } | ForEach-Object { $_.Name })
    if ($top.Count -eq 0) { throw "Write-AssembledWheelDistInfo: no top-level package directory under $PackageRoot" }
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'top_level.txt'), (($top -join "`n") + "`n"))
    return $distInfo
}

# A pyproject's [project] dependencies = [...] block, read from the source
# tree at build time (never hardcoded here).
function Get-PyprojectDependencies {
    param([Parameter(Mandatory)][string]$PyprojectText)
    # Two steps -- the [project] table body, then the list inside it: one regex
    # forbidding any `[` between them matched nothing once `classifiers = [`
    # preceded the list, and the assembled wheels shipped with NO requirements.
    # `\r?` before every `$`: .NET multiline `$` matches only immediately before
    # `\n`, so a CRLF checkout silently yields an empty list.
    $tbl = [regex]::Match($PyprojectText, '(?ms)^\[project\][ \t]*(?:#[^\r\n]*)?\r?$(.*?)(?=^\[|\z)')
    if (-not $tbl.Success) { return @() }
    $m = [regex]::Match($tbl.Groups[1].Value, '(?ms)^dependencies\s*=\s*\[(.*?)\][ \t]*(?:#[^\r\n]*)?\r?$')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}

function Assert-WheelTargetArch {
    # PE-checks every .pyd/.dll/.exe member of a staged wheel against the TARGET
    # machine, and asserts the filename carries the target's platform tag (a wheel
    # tagged for the wrong platform would install and then fail at import).
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
            # The EXT_SUFFIX tag is part of the import contract: a target
            # interpreter only loads <mod>.cp314-<its own platform>.pyd (or a bare
            # <mod>.pyd), however correct the machine field is.
            if ($f.Name -match '\.cp\d+-win_(amd64|arm64)\.pyd$' -and $f.Name -notmatch [regex]::Escape($wantTag)) {
                throw "wheel ${name}: member $($f.Name) carries a host EXT_SUFFIX tag, expected '$wantTag' -- the target interpreter would never import it (the sitecustomize shim pins EXT_SUFFIX to the target; is it active?)"
            }
            $m = Get-PeFileMachine -Path $f.FullName
            if ($m -ne $wantMachine) {
                throw ('wheel {0}: member {1} is machine 0x{2:X4}, expected 0x{3:X4} -- a host-arch binary inside a {4} wheel' -f $name, $f.Name, $m, $wantMachine, $wantTag)
            }
        }
        # Names, not only a count (#130c): what a wheel actually embeds is a fact
        # a consumer needs and a count cannot give.
        $names = @($pe | ForEach-Object { $_.FullName.Substring($tmp.Length).TrimStart('\', '/') } | Sort-Object)
        Write-Host ('Wheel arch check OK: {0} -- {1} native member(s), all 0x{2:X4}: {3}' -f $name, $pe.Count, $wantMachine, (($names | Select-Object -First 60) -join ', ') + $(if ($names.Count -gt 60) { ", ... (+$($names.Count - 60))" } else { '' }))
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Complete-SourceBuild {
    <#
    .SYNOPSIS
        The shared build-script epilogue: optional source-tree cleanup, the
        completion banner (passed verbatim so log-watchers keep their grep anchors),
        then `exit 0` -- and the exit is the point, because pwsh -File otherwise
        propagates the LAST native exit code and a best-effort cleanup once failed
        a fully green stage with exit 145. NOTE: never returns.
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
        # Same contract as the normal exit below: this call never carries an
        # exit code, on ANY path (the early return must not leak a stale one).
        $global:LASTEXITCODE = 0
        return
    }
    # Kill lingering compiler daemons BEFORE deleting the tree: one holding a handle
    # into it turns every deleted-while-open file into a PENDING-DELETE zombie, and
    # those break the BuildKit snapshot finalize (hcsshim::ExportLayer 0x3).
    Stop-LingeringBuildProcess
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path $p)) { continue }
        if ((Get-Location).Path -like "$p*") { Set-Location (Split-Path $p -Parent) }
        Write-Host "Removing build tree: $p"
        & cmd.exe /c "rd /s /q ""$p""" 2>$null
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Cleanup is best-effort by design; its exit code must NEVER outlive this
    # function -- `rd` exiting 145 once made the chain declare a green stage failed.
    $global:LASTEXITCODE = 0
}

# ── build phases (#109) ──────────────────────────────────────────────────────
# Named phases with timing, failure attribution and an end-of-run summary for the
# monolith build scripts. Marker-based, NOT scriptblock-taking: try/catch opens no
# variable scope in PowerShell, so cross-phase state keeps flowing exactly as
# before -- a function-invoked body would silently drop every assignment.
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
        Completes the tracked open phase (if any) and starts a new one; the module
        owns the current-phase state, so callers lose the two-line couplet that
        existed 21 times (#109). Pair with Complete-CurrentBuildPhase in the
        script's final/catch brackets.
    #>
    param([Parameter(Mandatory)][string]$Name)
    Complete-CurrentBuildPhase
    $script:CurrentBuildPhase = Start-BuildPhase $Name
}

function Complete-CurrentBuildPhase {
    # Safe no-op when no phase is open -- callable unconditionally from catch/final
    # brackets. -ErrorRecord stamps the failing phase (see Complete-BuildPhase).
    param($ErrorRecord = $null)
    if (-not (Test-Path 'Variable:script:CurrentBuildPhase')) { return }
    if ($null -eq $script:CurrentBuildPhase) { return }
    Complete-BuildPhase $script:CurrentBuildPhase -ErrorRecord $ErrorRecord
    $script:CurrentBuildPhase = $null
}

function Complete-BuildPhase {
    param(
        [Parameter(Mandatory)]$Phase,
        # The caught ErrorRecord on the failure path: the phase stamps itself
        # onto the error so a chain log names the phase, not just the line.
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
    # #80: five diagnostic classes were 96% of an 87,515-line chain warning stream
    # and BURIED the ~1,055 genuine signals. ONE list for every clang-cl CMake
    # build -- per-script copies would drift.
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
        # #51: the budget is a SCHEDULING knob, so it must not ride as image
        # ENV/ARG (both are cache keys). The driver publishes it to the LAN webdav
        # instead; memoized per process, and fails open to CIM below.
        if (-not (Test-Path 'Variable:script:WebdavMemoryLimitGb')) {
            $script:WebdavMemoryLimitGb = ''
            try {
                $resp = & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --max-time 5 "$($env:SCCACHE_WEBDAV_ENDPOINT)/preseed/memory-limit-gb.txt" 2>$null
                if ("$resp".Trim() -match '^\d+$') { $script:WebdavMemoryLimitGb = "$resp".Trim() }
            } catch { }
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
    # Background watchdog for the sccache DEADLOCK (history:
    # docs/windows-backlog-archive-2026-08-21.md). A quiet compiler fleet is only a
    # PRE-FILTER; the verdict is a TIMED `sccache --show-stats` probe (#16). On
    # confirmation kill EVERY sccache process -- clients block forever on a dead
    # pipe -- and append the kill to $MarkerPath, which the parent's retry ladder
    # reads (attempt-scoped) to tell a guard-kill from an OOM-shaped failure.
    # Returns $null without sccache on PATH or without a remote backend (#20).
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
                # A process can exit between enumeration and the property read;
                # its CPU contribution is then simply skipped for this sample.
                try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { continue }
            }
            $delta = if ($prev -ge 0) { $cpu - $prev } else { -1.0 }
            $prev = $cpu
            if ($delta -lt 0 -or $delta -ge 2.0) { continue }  # pre-filter: fleet is visibly working
            # Quiet fleet + live sccache: ask the server itself. PassThru quirk
            # (repo memory): touch .Handle before WaitForExit or ExitCode lies.
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
                # Marker write failed (locked file/bad path): shout via the job
                # stream so the kill is never invisible (#17).
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
    # A build log written inside $buildDir DIES WITH THE SOLVE; the sccache-logs
    # cache mount is persistent and survives into the next run, so the full stream
    # stays readable from a debug container. #43: one implementation, five callers.
    param(
        [Parameter(Mandatory)][string]$Name,
        # Where the log goes when no persistent cache mount is available (the
        # host lane, or a container built without the sccache mount).
        [Parameter(Mandatory)][string]$FallbackDir
    )
    # NEVER $env:SCCACHE_DIR -- that is sccache's own cache ROOT, and churning
    # rotated logs through its LRU index made 100% of L0 cache writes fail
    # (os error 3). Derived from SCCACHE_ERROR_LOG so both stay on the dedicated
    # logs mount instead of hard-coding that path twice (#90).
    $logRoot = if ($env:SCCACHE_ERROR_LOG) { Split-Path $env:SCCACHE_ERROR_LOG -Parent } else { '' }
    $logDir = if ($logRoot -and (Test-Path $logRoot)) { $logRoot } else { $FallbackDir }
    $null = New-Item -ItemType Directory -Force -Path $logDir
    $logPath = Join-Path $logDir $Name
    # Copy+Remove, NOT Move-Item: the cache mount is rename-hostile. One .prev
    # generation bounds growth.
    if (Test-Path $logPath) {
        Copy-Item -Path $logPath -Destination "$logPath.prev" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    }
    return $logPath
}

function Invoke-NinjaBuildWithRetry {
    # Retry ladder: a guard-kill failure is NOT OOM-shaped (everything already
    # compiled is an L0 hit) and the deadlock recurs, so it retries at FULL -j up to
    # $StallRetries; only a plain compile failure falls through to the single
    # incremental -j$RetryJobs attempt that handles the OOM shape.
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
        # Explicit ninja targets (default: the whole graph) -- the runtime-only TVM
        # cross build (#116). Every retry rung passes the same list.
        [string[]]$Targets = @()
    )
    $env:NINJA_STATUS = "[%f/%t] "
    $jobs = Get-BuildJobCount -MemGBPerJob $MemGBPerJob
    $ninjaKeep = if ($env:NINJA_KEEP_GOING -eq '1') { @('-k', '0') } else { @() }
    if (-not $StallMarkerPath) { $StallMarkerPath = Join-Path $BuildDir '.sccache-stall-guard.marker' }
    Remove-Item -Path $StallMarkerPath -Force -ErrorAction SilentlyContinue
    # The log is reset ONCE here; every invocation below appends (backlog #10 -
    # the per-call append flag made each caller track whether it was first).
    if ($LogFile) { Remove-Item -Path $LogFile -Force -ErrorAction SilentlyContinue }

    $invokeNinja = {
        param($jobCount)
        # Attempt-scoped marker (#17): truncate BEFORE each invocation so the
        # post-attempt read attributes kills to THIS attempt only. Lines are printed
        # when consumed below, so truncation never swallows a kill report.
        Remove-Item -Path $StallMarkerPath -Force -ErrorAction SilentlyContinue
        if ($LogFile) { ninja -j $jobCount @ninjaKeep -C $BuildDir @Targets 2>&1 | Tee-Object -FilePath $LogFile -Append }
        else { ninja -j $jobCount @ninjaKeep -C $BuildDir @Targets 2>&1 }
    }

    Write-Host "Building with ninja -j$jobs..."
    $guard = Start-SccacheStallGuard -MarkerPath $StallMarkerPath
    try {
        & $invokeNinja $jobs
        # Guard-kill retries: full parallelism, bounded, and only while THIS
        # attempt's marker shows a kill.
        for ($attempt = 1; $attempt -le $StallRetries -and $LASTEXITCODE -ne 0; $attempt++) {
            $kills = @(Get-Content $StallMarkerPath -ErrorAction SilentlyContinue)
            if ($kills.Count -eq 0) { break }
            foreach ($k in $kills) { Write-Host "[sccache-stall-guard] $k" -ForegroundColor Yellow }
            Write-Host "ninja -j$jobs failed after $($kills.Count) stall-guard kill(s) this attempt - full-speed retry $attempt/$StallRetries (compiled objects are cache hits)..." -ForegroundColor Yellow
            & $invokeNinja $jobs
        }
        if ($LASTEXITCODE -ne 0 -and $jobs -gt $RetryJobs) {
            # LOUD, not chatty (#75): one silent-looking line here once hid an
            # 11 h 17 m self-heal that re-ground the same build 11 times. The ladder
            # stays BOUNDED to exactly one incremental attempt.
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
    # Gate BOTH 7z passes: a corrupt or truncated tarball previously surfaced as
    # "Failed to locate extracted source directory" instead of the real failure.
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
    $versionsScript = Join-Path $ScriptRoot 'load-versions.ps1'
    if (Test-Path $versionsScript) { & $versionsScript }
}

function Get-LlvmArchiverCmakeArg {
    $llvmLib = Resolve-LlvmArchiver
    if ($llvmLib) { return @("-DCMAKE_AR:FILEPATH=$llvmLib") }
    return @()
}

# #123: llvm-ml is LLVM's MASM-compatible assembler and replaces ml64.exe, the
# last MSVC tool in the native lane. Unlike the archiver this THROWS when absent:
# a silent fallback to ml64 would be the untracked exception #123 exists to remove.
function Resolve-LlvmMasm {
    $llvmMl = (Get-Command 'llvm-ml' -ErrorAction SilentlyContinue).Source
    if (-not $llvmMl) { $llvmMl = (Get-Command 'llvm-ml.exe' -ErrorAction SilentlyContinue).Source }
    return $llvmMl
}
function Get-LlvmMasmCmakeArg {
    # CMake's own ASM_MASM rule is one llvm-ml accepts. Forward slashes: the value
    # is also consumed inside CMake string expansions (IREE's custom command).
    $llvmMl = Resolve-LlvmMasm
    if (-not $llvmMl) { throw 'llvm-ml not found on PATH -- the pinned LLVM ships it (bin\llvm-ml.exe); without it the MASM sources would silently fall back to ml64 (#123)' }
    return @("-DCMAKE_ASM_MASM_COMPILER:FILEPATH=$($llvmMl -replace '\\', '/')")
}

function Initialize-PythonPlatformTag {
    # Clang-built CPython's sys.version lacks the "64 bit (AMD64)" marker that
    # sysconfig.get_platform() keys on, so the 64-bit interpreter reports win32 and
    # pip resolves 32-bit wheels. _PYTHON_HOST_PLATFORM is POSIX-only, so the fix is
    # a sitecustomize.py shim forcing win-amd64.
    #
    # -Arch follows the HOST: this shim configures the interpreter that RUNS the
    # builds, and pip resolves DOWNLOADS against the same tag. EXT_SUFFIX is the
    # separate fact, pinned to the TARGET on a cross lane, because it is what NAMES
    # the .pyd and a target interpreter imports only its own tag.
    param(
        [string]$CpythonDir = '',
        [string]$Arch = '',
        # The platform tag belongs to the HOST interpreter this shim configures; the
        # OpenCV DLL directory registered below is a fact about what this image
        # STAGED, which on a cross lane is the TARGET tree. Defaults to the target
        # arch; -Arch keeps steering only the tag.
        [string]$StagedOpenCvArch = ''
    )
    if ([string]::IsNullOrWhiteSpace($Arch)) { $Arch = Get-WindowsHostArch }
    if ([string]::IsNullOrWhiteSpace($StagedOpenCvArch)) { $StagedOpenCvArch = Get-WindowsTargetArch }
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $platformName = Get-PythonPlatformName -Arch $Arch
    $openCvArchDir = Get-OpenCvArchDir -Arch $StagedOpenCvArch
    # Cross lane only: the EXT_SUFFIX pin (see the header). Empty on amd64, so
    # the native lane's shim is byte-identical to before #120 step 2.
    $crossExtTag = if (Test-WindowsCrossTarget) { Get-PythonWheelTag } else { '' }
    $sitePackages = Join-Path $CpythonDir 'Lib\site-packages'
    $shim = Write-PythonDllDirectoryShim -SitePackages $sitePackages -OpenCvArchDir $openCvArchDir `
        -PlatformName $platformName -CrossExtTag $crossExtTag -WrittenBy 'Initialize-PythonPlatformTag (HOST build interpreter)'
    Write-Host "Wrote python platform-tag ($platformName) + dll-directory shim: $shim"
    return $shim
}

<#
.SYNOPSIS
    Writes the sitecustomize.py shim that registers this bundle's native DLL
    directories (and, for the HOST build interpreter, the platform-tag fixes).
.DESCRIPTION
    ONE writer for two interpreters (#125): the TARGET interpreter shipped at
    C:\runtime\python needs it too, because Python >= 3.8 ignores PATH for
    extension-module dependencies. build-target-cpython.ps1 passes -PlatformName
    and -CrossExtTag EMPTY -- the target reports its own platform, and the
    EXT_SUFFIX pin is a build-time concern of the host interpreter only.
    EXPANDING here-string: the python body must contain NO '$' and NO backtick.
.PARAMETER SitePackages
    Directory that receives sitecustomize.py (created if missing).
.PARAMETER OpenCvArchDir
    The opencv5\<this>\vc18\bin directory the bundle STAGED (target arch).
.PARAMETER PlatformName
    When non-empty, patch sysconfig.get_platform() from 'win32' to this value
    (the clang-built HOST CPython marker bug). Empty = leave it alone.
.PARAMETER CrossExtTag
    When non-empty, pin sysconfig EXT_SUFFIX to this wheel tag (host-side cross
    build of target modules). Empty = leave it alone.
.OUTPUTS
    [string] the shim path.
#>
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
#    get_config_var('EXT_SUFFIX') sees the pin too.
_target_tag = '$CrossExtTag'
if _target_tag:
    _ext = '.cp%d%d-%s.pyd' % (sys.version_info[0], sys.version_info[1], _target_tag)
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
        r'C:\runtime\lib\opencv5\$OpenCvArchDir\vc18\bin',
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
"@
    return $shim
}

function Test-PythonImport {
    # EAP=Stop-safe binding assert: a stderr-noisy SUCCESS must not read as a
    # failure, so route through cmd.exe and judge by exit code only.
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$VersionExpression = ''
    )
    # getattr fallback: the assert is about IMPORTABILITY, not version metadata.
    # -I (isolated) drops CWD from sys.path -- a source dir named like the module
    # SHADOWS the installed wheel. Single quotes only: PS 5.1 strips embedded ones.
    if (-not $VersionExpression) { $VersionExpression = "getattr($ModuleName, '__version__', 'imported')" }
    $out = cmd.exe /c """$($Python.Exe)"" -I -c ""import $ModuleName; print($VersionExpression)"" 2>&1"
    $code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $tail = if ($out) { (@($out) | Select-Object -Last 1).ToString().Trim() } else { '' }
    if ($code -ne 0) { throw "import $ModuleName failed right after install (exit $code): $tail" }
    Write-Host "$ModuleName python binding OK ($tail)"
}

function Install-StagedPythonWheel {
    # One-stop wheel publish: stage into the central store, install into the source
    # CPython (--no-deps for metadata that is unsatisfiable by design), then
    # import-assert. Encapsulates the single-element array-unwrap footgun.
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
    # -Arch defaults to EMPTY, not a literal arch: Enter-VsDevCmdEnvironment resolves
    # the target arch only when handed an empty string, so a literal default silently
    # defeated it for all five callers routed through here. -HostArch stays literal.
    param(
        [string]$Arch = '',
        [string]$HostArch = 'amd64'
    )
    Enter-VsDevCmdEnvironment -Arch $Arch -HostArch $HostArch
    Copy-CpythonPyConfigHeader
    # NOT forwarded on purpose: the platform-tag shim configures the HOST interpreter
    # that runs the builds, so it stays host-pinned even inside a target-arch VsDevCmd.
    Initialize-PythonPlatformTag | Out-Null
    return Get-SourceBuildPython
}

# ── sccache server session (#107) ────────────────────────────────────────────
# Extracted from the chain functions so the prologue/epilogue choreography is
# unit-testable; -SccachePath is the test seam. BEST-EFFORT throughout: a missing
# sccache or a dead server must never fail a build that would otherwise be green.

function Start-SccacheServerSession {
    # PROLOGUE: force a FRESH sccache server before the first compile (#97) --
    # sccache reads SCCACHE_ERROR_LOG when the SERVER starts, and a server started
    # implicitly by the first wrapped compile evidently misses it, which also makes
    # the epilogue's flush meaningless.
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
        # Stop first so the start below is the one that wins (usually a no-op
        # in a fresh container - "no connection could be made" is expected).
        & $SccachePath --stop-server 2>&1 | ForEach-Object { Write-Host "  sccache-prologue| $_" }

        # START IT EXPLICITLY, FROM C:\ -- hygiene, NOT a fix: the CWD theory did
        # not explain the cache-write failures (measured 2026-08-15, #99; do not
        # re-litigate it). It does guarantee the server read THIS stage's env.
        #
        # TRUNCATE THE ERROR LOG FIRST: it lives on the shared, APPEND-only
        # sccache-logs mount, so the epilogue otherwise replays a previous run's
        # failures verbatim. Best-effort: never fail a green stage over a log file.
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
    # EPILOGUE: flush the sccache SERVER before the run ends. With
    # SCCACHE_IDLE_TIMEOUT=0 it never exits on its own, so the process tree is torn
    # down with the error log still buffered and the file never lands on the mount;
    # --stop-server also flushes the async webdav write-through tail.
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

    # DUMP THE SERVER LOG INTO THIS RUN's build log (#98): reading it from a LATER
    # build does not work, because --no-cache empties the cache mount first (#96).
    # It is the only account of WHY a write is rejected, and the failures are all
    # at L0 -- read the per-layer block, not the summary counter.
    $errLog = $env:SCCACHE_ERROR_LOG
    if ($errLog -and (Test-Path $errLog)) {
        $lines = @(Get-Content $errLog -ErrorAction SilentlyContinue)
        Write-Host "`n=== sccache server log ($($lines.Count) lines, $errLog) ==="
        # Failures first and in full; they are what this exists for. The tail
        # gives surrounding context without dumping a debug-level flood.
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
        # Resume support: skip every stage BEFORE the named one, to re-enter a
        # preserved container instead of re-paying hours of compile. Unknown names
        # throw immediately -- a typo must not silently rebuild from the start.
        [string]$StartAt = '',
        # Stop AFTER the named stage (inclusive): lets the BuildKit lane split one
        # chain across RUN layers. Unknown names throw, same rationale as -StartAt.
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
    # Fresh sccache server + per-stage error-log attribution (#97/#99) — the
    # full war story lives on the function.
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
        # A stage is either the standard shape (Script + SourceDir, invoked with the
        # chain's contract) or carries its own Invoke scriptblock for a script with
        # a DIFFERENT signature (#128).
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
    # ONE stats dump per chain run: the counters die with the container, so this is
    # the last chance to get them into the run log.
    Write-SccacheStats -Label $Label
    Stop-LingeringBuildProcess
}

# ── BuildKit warm/materialize handoff ────────────────────────────────────────
# Heavy-churn containers on this host can NEVER finalize their snapshot, so the
# heavy build runs in a WARM solve with no exporter and hands its artifacts off to
# a calm, short-lived container (docs/windows-builds.md § BuildKit/containerd
# lane). Cache mounts reject directory RENAMES -- these helpers only CREATE files.

function Export-BuildHandoff {
    # Tar what the build wrote under -Roots since -Since and PUT it to WebDAV, not
    # a cache mount: BuildKit clones cache mounts whenever the record is locked, so
    # warm and materialize solves are not guaranteed to see the same instance.
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
    # System32 paths, NOT bare names: scoop's git puts MSYS tar/curl on PATH, and
    # GNU tar parses a drive-qualified path as a remote host.
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -cf $tarFile -C C:\ -T $listFile
    if ($LASTEXITCODE -ne 0) { throw "Export-BuildHandoff: tar failed (exit $LASTEXITCODE)" }
    # --retry: this PUT is the ONLY copy of an hours-long warm build.
    # --retry-all-errors extends the retries to transient HTTP 5xx.
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -T $tarFile "$Endpoint/bkhandoff/$Name.tar"
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
    # Same retry rationale as the Export upload: the download gates an entire
    # materialize layer on one HTTP round-trip.
    & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -o $tarFile "$Endpoint/bkhandoff/$Name.tar"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tarFile)) {
        throw "Import-BuildHandoff: download $Endpoint/bkhandoff/$Name.tar failed - did the warm solve run?"
    }
    # The tar holds FILE entries only, and bsdtar's Windows long-path mode does not
    # create missing parent chains -- pre-create every directory.
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
    # container profile -- dead weight in an exported image. Best-effort by contract.
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
    # Windows Update runs INSIDE a process-isolated build container, and an .msu
    # written to its spool during a RUN kills the layer finalize deterministically
    # ("unknown stream ID 9", measured 2026-08-25). PREVENTION ONLY: nothing under
    # C:\Windows is ever deleted here. Host-guarded like Stop-LingeringBuildProcess,
    # because outside a container this would switch off the developer's own updates.
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
    # The spool count is informational: an entry inherited from the parent image
    # sits in a layer that already finalized. Only a file WRITTEN during this RUN
    # lands in the diff.
    $spool = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $spoolItems = if (Test-Path $spool) { @(Get-ChildItem -LiteralPath $spool -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Host ("Disable-ContainerWindowsUpdate: services disabled [{0}], NoAutoUpdate=1; spool holds {1} item(s) at RUN start (inherited -- only files written during this RUN can poison the layer)" -f ($touched -join ', '), $spoolItems)
    $global:LASTEXITCODE = 0
}

function Stop-LingeringBuildProcess {
    # MSVC helper daemons (mspdbsrv, vctip, VBCSCompiler) must be dead before a
    # BuildKit step returns: HCS tears the container down while they still hold
    # sandbox handles, and the snapshot finalize then fails (ExportLayer 0x3).
    # sccache is deliberately NOT on the list -- it lingered on healthy layers too.
    [CmdletBinding()]
    param(
        # Kill even outside a container (tests use this with fake process names).
        [switch]$Force
    )
    # HOST GUARD: outside a Windows container this would kill a developer's live
    # VS/MSBuild session. cexecsvc exists only inside Windows containers.
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
            # Loud, like the missing-sidecar branch below: a missing PRIMARY means
            # the install step upstream failed.
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

# NB the test suites ARE consumers of the export list below -- Save-PythonWheel,
# Get-CudaRoot, Resolve-TensorRtRoot and the sccache helpers stay exported for them.
function Complete-SourceBuildChain {
    # Shared epilogue for the build-*-all.ps1 chain wrappers: banner plus the
    # in-layer scratch scrub. The scrub MUST happen HERE, not downstream: image
    # layers are additive, so deleting this chain's scratch from a later layer only
    # adds a whiteout entry and the bytes still ship. Safe against C:\temp --
    # Clear-BuildScratch targets $env:TEMP, the container profile temp.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$ScrubAfter
    )
    Write-Host "`n=== $Label chain completed ==="

    # Server flush + error-log dump (#96/#98) — the full war story lives on
    # the function.
    Complete-SccacheServerSession

    if ($ScrubAfter) { Clear-BuildScratch }
    # Callers still end with their own explicit `exit 0`: pwsh -File otherwise
    # propagates the LAST native exit code.
    $global:LASTEXITCODE = 0
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Get-PersistentBuildLogPath',
    'Invoke-SourceBuildChain',
    'Complete-SourceBuildChain',
    'Start-SccacheServerSession',
    'Complete-SccacheServerSession',
    # Stop-LingeringBuildProcess: internal (chain + ninja retry) — unexported
    # 2026-08-21, zero external callers.
    'Export-BuildHandoff',
    'Import-BuildHandoff',
    'Clear-BuildScratch',
    'Disable-ContainerWindowsUpdate',
    'Invoke-ShieldedNative',
    'Invoke-GitClone',
    'Reset-SourceBuildDirectory',
    'Invoke-CmakeConfigure',
    'Test-SccacheRemoteConfigured',
    # Re-exported from nested WindowsScripts.Shared for SCRIPT-scope callers:
    # nested-module exports are invisible to scripts (repo scoping rule), and the
    # omission would have thrown CommandNotFound after the multi-hour ONNX build.
    'Get-SccacheStatsText',
    'Write-SccacheStatsToStderr',
    'Write-SccacheStats',
    'Save-PythonWheel',
    'Get-CudaRoot',
    'Resolve-TensorRtRoot',
    'Enter-VsDevCmdEnvironment',
    'Get-MsvcToolsRoot',
    'Copy-CpythonPyConfigHeader',
    'Get-SourceBuildPython',
    'Get-TargetBuildPython',
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
    'Write-AssembledWheelDistInfo',
    'Get-PyprojectDependencies',
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
    'Get-CudnnLibrary',
    'Get-LlvmArchiverCmakeArg',
    'Resolve-LlvmMasm',
    'Get-LlvmMasmCmakeArg',
    'Initialize-SourceBuildEnvironment',
    'Initialize-SourceBuildScript',
    'Initialize-ToolchainPythonEnvironment',
    'Initialize-PythonPlatformTag',
    'Install-StagedPythonWheel',
    'Invoke-PythonWheelBuild',
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
    # Called DIRECTLY by build-gstreamer-from-source.ps1's meson native file (#134);
    # invisible to Modules.ReExport.Tests.ps1, so Modules.ScriptCallClosure.Tests.ps1
    # gates it.
    'Resolve-BuildMachineMsvcTool',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    # Called directly by build-tvm-from-source.ps1's LLVM-source fallback (#47).
    # Latent on both lanes, so no build ever caught it -- Modules.ScriptCallClosure.Tests.ps1 did.
    'Get-PreferredToolPath',
    # #113: used directly by build-gstreamer-from-source.ps1 -- module-internal use
    # never needs the export list, direct script calls do.
    'Start-SccacheStallGuard',
    'Stop-SccacheStallGuard'
)

