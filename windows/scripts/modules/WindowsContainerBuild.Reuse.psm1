# Reusable Windows build-container lifecycle and transfer helpers.
#
# Building a large project inside a Windows container is dominated by two
# costs: recompiling everything because the container is fresh, and moving the
# build tree in and out. Reusing ONE container removes both - the build tree,
# ninja graph and C++ module BMIs simply stay where they are.
#
# Measured on a ~690-object C++23 modules project: 9.6 s ninja / 44 s wall for
# a no-change incremental build, vs 352-484 s with a fresh container per build.
# Background - including the two supported transports and how to set each up,
# plus three approaches that do NOT work - is in
# docs/windows-container-build-performance.md.

Set-StrictMode -Version Latest
#requires -Version 7.0


<#
.SYNOPSIS
  Returns a reusable build container, creating or recreating it as needed.
.DESCRIPTION
  Reuses a running container, starts a stopped one, and recreates it whenever
  the referenced image ID differs from the container's image - without that
  check a rebuilt toolchain image is silently ignored and you keep building
  against the old one.
.OUTPUTS
  [pscustomobject] with Reused ([bool] - true when an existing container was
  reused and its build tree is intact) and Name ([string] - the container that
  was actually used, which may differ from -Name when a -Fresh removal was
  blocked by the wcifs teardown lock).
#>
function Get-ReusableBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Image,
        [string[]]$RunArgs = @(),
        [switch]$Fresh
    )

    if ($Fresh) {
        Write-Host "Fresh container requested - discarding '$Name'."
        & $DockerExe rm -f $Name 2>&1 | Out-Null

        # Removal can FAIL silently on hosts with the wcifs teardown lock. If it
        # did, the old container is still there and would simply be reused -
        # making -Fresh a no-op exactly when someone needs it (stale sources,
        # deleted files, a corrupted tree). Verify, and fall back to a uniquely
        # named container so "fresh" always means fresh.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $DockerExe inspect $Name 2>&1 | Out-Null
            $survived = ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $previous
        }

        if ($survived) {
            $unique = "$Name-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
            Write-Warning ("Could not remove '$Name' (wcifs teardown lock?). Using '$unique' instead so " +
                "-Fresh is honoured; remove the old one later with: docker rm -f $Name")
            $Name = $unique
        }
    }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $imageId = (& $DockerExe inspect -f '{{.Id}}' $Image 2>$null | Select-Object -First 1)
        $state = (& $DockerExe inspect -f '{{.State.Running}}|{{.Image}}' $Name 2>$null | Select-Object -First 1)
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($state) {
        $parts = $state -split '\|'
        $isRunning = ($parts[0] -eq 'true')
        $containerImage = if ($parts.Count -gt 1) { $parts[1] } else { '' }

        if ($imageId -and $containerImage -and ($containerImage -ne $imageId)) {
            Write-Host 'Build image changed - recreating the reusable container.'
            & $DockerExe rm -f $Name 2>&1 | Out-Null
        } elseif ($isRunning) {
            Write-Host "Reusing build container '$Name' (build tree preserved)."
            return [pscustomobject]@{ Reused = $true; Name = $Name }
        } else {
            Write-Host "Starting existing build container '$Name'..."
            & $DockerExe start $Name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Reused = $true; Name = $Name } }
            & $DockerExe rm -f $Name 2>&1 | Out-Null
        }
    }

    Write-Host "Creating build container '$Name'..."
    & $DockerExe run -d --name $Name @RunArgs --entrypoint cmd $Image `
        /c 'ping -n 604800 127.0.0.1 > nul' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to start build container '$Name'." }
    return [pscustomobject]@{ Reused = $false; Name = $Name }
}

<#
.SYNOPSIS
  Streams a host directory into a running container via a tar pipe.
.DESCRIPTION
  Used where bind mounts are unavailable (Dev Drive hosts reject the
  filesystem minifilter). ALWAYS pass -Exclude for deeply nested output
  directories: a single path over the Windows limit fails with
  "Can't create ...: Invalid argument" and aborts the WHOLE transfer, silently
  turning a full copy into a partial one.
#>
function Copy-IntoBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetPath,
        [string[]]$Items = @('.'),
        [string[]]$Exclude = @()
    )

    $excludeArgs = ($Exclude | ForEach-Object { "--exclude `"$_`"" }) -join ' '
    $itemArgs = ($Items | ForEach-Object { "`"$_`"" }) -join ' '
    # cmd /c keeps the pipe a raw byte stream regardless of PowerShell version.
    $command = "tar -cf - $excludeArgs -C `"$SourceRoot`" $itemArgs | `"$DockerExe`" exec -i $Container tar -xf - -C $TargetPath"
    cmd /c $command
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
  Streams selected artifacts out of a container back to the host.
.DESCRIPTION
  With a reusable container the host copy is no longer the incremental seed,
  so copy back only what the host actually runs (executables, debug info,
  compile database, logs) instead of the whole build tree. tar does NOT
  expand globs in item arguments (it reports "Cannot stat" and produces an
  empty archive), so pass literal paths in -Items and select by -Exclude to
  drop heavy intermediates.
#>
function Copy-FromBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string[]]$Items,
        [string[]]$Exclude = @()
    )

    $excludeArgs = ($Exclude | ForEach-Object { "--exclude `"$_`"" }) -join ' '
    $itemArgs = ($Items -join ' ')
    # tar's -C avoids a nested cmd /c inside the container, which would need
    # quote-in-quote escaping for the exclude patterns.
    $command = "`"$DockerExe`" exec $Container tar -cf - $excludeArgs -C $SourcePath $itemArgs | tar -xf - -C `"$TargetRoot`""
    cmd /c $command
    return ($LASTEXITCODE -eq 0)
}


<#
.SYNOPSIS
  Ensures PowerShell Core (pwsh) is available inside a running container.
.DESCRIPTION
  Windows container images often ship only Windows PowerShell 5.1
  (powershell.exe); build scripts requiring PS 7+ need pwsh installed via
  scoop (pre-installed in the image). Measured 2026-07-29: ~10 s on first
  install (scoop update may run); subsequent calls are a no-op ~1 s check.
.OUTPUTS
  [bool] - $true when pwsh is available (already present or installed).
#>
function Initialize-ContainerPwsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container
    )

    & $DockerExe exec $Container cmd /c "where pwsh >nul 2>nul" | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }

    Write-Host 'pwsh not found in container - installing via scoop...'
    & $DockerExe exec $Container powershell -NoProfile -Command "scoop install pwsh" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pwsh installation failed (exit $LASTEXITCODE) - build may fail if modules require PS 7."
        return $false
    }
    Write-Host 'pwsh installed successfully.'
    return $true
}

<#
.SYNOPSIS
  Removes stale source directories from a reused build container.
.DESCRIPTION
  tar extracts over the existing tree but never removes files, so a source
  deleted on the host keeps building inside a reusable container (observed
  and repro'd 2026-07-19). This prunes everything under the workspace except
  the build trees and the extra directories the caller keeps; sources
  re-stream in seconds.

  The keep test is designed so a wrong pattern CANNOT delete the build tree:
  directories named "build", "build-*", "build_*" and the -KeepDirs names are
  kept, everything else is removed. A future build-directory naming
  convention must start with "build" to be kept.
.OUTPUTS
  [bool] - $true when pruning reported no errors.
#>
function Remove-StaleContainerSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container,
        [string]$WorkspacePath = 'C:\ws',
        [string[]]$KeepDirs = @('logs')
    )

    # Pipe the pruning script via stdin to avoid nested-quote hell with
    # -Command when the script itself contains double-quoted strings.
    $keepList = ($KeepDirs | ForEach-Object { '"{0}"' -f $_ }) -join ','
    $pruneLines = @(
        ('$d = Get-ChildItem "{0}" -Directory -ErrorAction SilentlyContinue' -f $WorkspacePath),
        'if ($d) {',
        ('  $k = @({0})' -f $keepList),
        '  $d | Where-Object { $_.Name -notin $k -and $_.Name -ne "build" -and $_.Name -notlike "build-*" -and $_.Name -notlike "build_*" } |',
        '    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue',
        '}'
    ) -join "`n"
    $pruneTmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $pruneTmp -Value $pruneLines -Encoding UTF8 -NoNewline
        Get-Content $pruneTmp -Raw | & $DockerExe exec -i $Container powershell -NoProfile -Command -
        $pruneExit = $LASTEXITCODE
    } finally {
        if (Test-Path $pruneTmp) { Remove-Item $pruneTmp -Force }
    }
    if ($pruneExit -ne 0) {
        Write-Warning "Source pruning reported errors (exit $pruneExit) - continuing anyway."
        return $false
    }
    return $true
}

<#
.SYNOPSIS
  Verifies that every executable built in the container reached the host.
.DESCRIPTION
  A green build is not proof that anything was produced or delivered. Both
  halves of that have failed silently in practice: a build cut off partway
  still looked successful (no test exe at all), and an outbound tar that
  used globs (which tar does not expand) copied NOTHING while stale host
  artifacts masked it. Compares by EXISTENCE, not timestamps: on a no-change
  build ninja does not relink, so executables are legitimately older than
  the current run. Throws on either failure mode.
.OUTPUTS
  [int] - the number of executables verified as delivered.
#>
function Test-BuildArtifactsDelivered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$HostRoot
    )

    $containerExes = @(& $DockerExe exec $Container cmd /c "dir /b $WorkspacePath\$Directory\*.exe 2>nul" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($containerExes.Count -eq 0) {
        throw ("Build reported success but produced no executables in $Directory. " +
            'The build was almost certainly cut off before linking - check the tail of the build log ' +
            'for a step count that never reached its total.')
    }

    $notDelivered = @($containerExes | Where-Object { -not (Test-Path (Join-Path (Join-Path $HostRoot $Directory) $_)) })
    if ($notDelivered.Count -gt 0) {
        throw ("$($notDelivered.Count) executable(s) built in the container never reached the host " +
            "($Directory): $($notDelivered -join ', '). The outbound transfer is broken - anything you run " +
            'on the host is stale.')
    }

    return $containerExes.Count
}

<#
.SYNOPSIS
  Locates docker.exe, preferring Stevedore's copy.
.DESCRIPTION
  nerdctl has DNS issues in BuildKit on Windows, so Stevedore's docker.exe is
  the supported client. Checks an explicit override, then $env:DOCKER_EXE,
  then the usual Stevedore install locations, then PATH.
#>
function Resolve-DockerExe {
    [CmdletBinding()]
    param([string]$Override)

    $candidates = @(
        $Override,
        $env:DOCKER_EXE,
        (Join-Path $env:ProgramFiles 'Stevedore\bin\docker.exe'),
        'D:\Stevedore\bin\docker.exe'
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $onPath = Get-Command docker -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    throw 'docker.exe not found. Install Stevedore (winget install stevedore) or pass an explicit path.'
}

<#
.SYNOPSIS
  Builds docker isolation arguments.
.DESCRIPTION
  Process isolation exposes all host CPUs; Hyper-V isolation defaults to 2, so
  CPU and memory are passed explicitly for that mode only.
#>
function Get-ContainerIsolationArgs {
    [CmdletBinding()]
    param(
        [ValidateSet('process', 'hyperv')][string]$Isolation = 'process',
        [int]$CpuCount = 0,
        [int]$MemoryGb = 16
    )

    $isolationArgs = @('--isolation', $Isolation)
    if ($Isolation -eq 'hyperv') {
        $cpus = if ($CpuCount -gt 0) { $CpuCount } else { [Environment]::ProcessorCount }
        $isolationArgs += @('--cpu-count', "$cpus", '--memory', "${MemoryGb}g")
    }
    return $isolationArgs
}

<#
.SYNOPSIS
  Tests whether a bind mount of $SourcePath actually attaches.
.DESCRIPTION
  EXPECTED to fail on Dev Drive hosts: the filesystem minifilter cannot attach
  unless 'fsutil devdrv setfiltersallowed bindFlt, wcifs' has been run. Callers
  fall back to a tar-pipe transport. Docker's stderr must not become a
  terminating NativeCommandError (Windows PowerShell turns redirected native
  stderr into ErrorRecords under $ErrorActionPreference = 'Stop').
.NOTES
  Mount onto a FRESH target path: mounting over a directory baked into the
  image (e.g. C:\workspace) fails at CreateComputeSystem when the host OS
  build differs from the image base build.
#>
function Test-ContainerBindMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetPath = 'C:\ws-mnt',
        [string]$ProbeFile = 'CMakePresets.json',
        [string[]]$RunArgs = @()
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $DockerExe run --rm @RunArgs `
            --mount "type=bind,source=$SourcePath,target=$TargetPath" `
            --entrypoint cmd $Image /c "dir $TargetPath\$ProbeFile > nul" 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
  Removes a container, tolerating the wcifs layer-teardown lock.
.DESCRIPTION
  On some hosts the immediate remove fails even though a later manual
  'docker rm' succeeds. Surface it as a warning; never let docker's stderr flip
  a green build to a failure.
#>
function Remove-BuildContainerSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Name
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $DockerExe rm -f $Name 2>&1 | Out-Null
        & $DockerExe inspect $Name 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Warning ("Container '$Name' could not be removed yet (wcifs teardown lock?). " +
                "Remove it later with: docker rm -f $Name")
            return $false
        }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return $true
}

Export-ModuleMember -Function @(
    'Get-ReusableBuildContainer',
    'Copy-IntoBuildContainer',
    'Copy-FromBuildContainer',
    'Initialize-ContainerPwsh',
    'Remove-StaleContainerSources',
    'Test-BuildArtifactsDelivered',
    'Resolve-DockerExe',
    'Get-ContainerIsolationArgs',
    'Test-ContainerBindMount',
    'Remove-BuildContainerSafe'
)

