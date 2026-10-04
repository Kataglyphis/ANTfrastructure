#requires -Version 7.0
# CONSUMED-BY BeschleunigerBallett and OxidANT container scripts, renames break them; see docs/windows-container-build-performance.md

Set-StrictMode -Version Latest

<#
.SYNOPSIS
  Returns a reusable build container, creating or recreating it as needed.
.DESCRIPTION
  Recreates it when the image ID changed, or a rebuilt toolchain image would be silently ignored.
.OUTPUTS
  [pscustomobject] Reused (tree intact) and Name, which differs from -Name when the wcifs lock blocked a -Fresh removal.
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

        # The wcifs teardown lock can fail the removal silently; a survivor gets a unique name so fresh means fresh.
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
  For hosts without bind mounts; -Exclude deep output dirs, as one over-long path silently aborts the whole transfer.
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
  Copy back only what the host runs; tar does not expand globs, so -Items are literal paths and -Exclude filters.
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
    # tar -C avoids a nested cmd /c, which would need quote-in-quote escaping for the excludes.
    $command = "`"$DockerExe`" exec $Container tar -cf - $excludeArgs -C $SourcePath $itemArgs | tar -xf - -C `"$TargetRoot`""
    cmd /c $command
    return ($LASTEXITCODE -eq 0)
}


<#
.SYNOPSIS
  Ensures PowerShell Core (pwsh) is available inside a running container.
.DESCRIPTION
  Images that ship only Windows PowerShell 5.1 get pwsh through the image's scoop.
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
  tar never deletes, so a host-deleted source keeps building; keeps build, build-*, build_* and -KeepDirs, removes the rest.
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

    # Piped via stdin: -Command would need nested quoting for the script's own double quotes.
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
        Get-Content $pruneTmp -Raw | & $DockerExe exec -i $Container pwsh -NoProfile -Command - | Out-Host
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
  A green build proves neither production nor delivery; compares by existence, since a no-change build does not relink.
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
  Order: explicit override, $env:DOCKER_EXE, Stevedore install locations, PATH.
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
  Fails on a Dev Drive until 'fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"'; callers fall back to tar.
.NOTES
  Mount onto a fresh path: over an image-baked dir it fails when host and image builds differ.
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
  The immediate remove can fail where a later one succeeds, so it only warns and never fails a green build.
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

<#
.SYNOPSIS
  Reads one 'docker inspect' format field and classifies the failure if it fails.
.DESCRIPTION
  Keeps read, container gone and daemon unreachable apart; the value comes only from stdout, as notices precede it on stderr.
.OUTPUTS
  [pscustomobject] with Ok, Value, ExitCode, Error, Missing, DaemonUnreachable.
#>
function Get-ContainerInspectField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Format
    )

    $stdoutLines = [System.Collections.Generic.List[string]]::new()
    $stderrLines = [System.Collections.Generic.List[string]]::new()
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Redirected stderr arrives as ErrorRecords, so the streams split cleanly.
        & $DockerExe inspect -f $Format $Name 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderrLines.Add("$_") }
            else { $stdoutLines.Add("$_") }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $value = ''
    if ($code -eq 0) {
        $first = @($stdoutLines | Where-Object { $_.Trim() }) | Select-Object -First 1
        if ($first) { $value = $first.Trim() }
    }
    # stdout is the fallback for a docker that reports its failure there.
    $errorSource = if ($stderrLines.Count -gt 0) { $stderrLines } else { $stdoutLines }
    $text = (@($errorSource) -join "`n").Trim()

    return [pscustomobject]@{
        Ok                = ($code -eq 0)
        Value             = $value
        ExitCode          = $code
        Error             = $text
        # 'Error: No such object: <name>' (inspect) / 'No such container'.
        Missing           = (($code -ne 0) -and ($text -match 'No such (object|container)'))
        # 'error during connect: ... //./pipe/docker_engine': the client, not the container.
        DaemonUnreachable = (($code -ne 0) -and
            ($text -match 'error during connect|docker_engine|Cannot connect to the Docker daemon|daemon is not running'))
    }
}

<#
.SYNOPSIS
  Waits for a named container to stop and returns the exit code it really had.
.DESCRIPTION
  The docker CLI drops its pipe mid-run while the container keeps working; only for 'docker run --name' without --rm.
.PARAMETER PollSeconds
  Seconds between state probes.
.PARAMETER TimeoutMinutes
  Upper bound on the wait; [double] so sub-minute waits are expressible.
.PARAMETER Label
  Message prefix, so a caller running several phases can tell them apart.
.OUTPUTS
  [int] - the container's real exit code.
#>
function Wait-ContainerExit {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 3600)][int]$PollSeconds = 15,
        [ValidateRange(0.01, 10080)][double]$TimeoutMinutes = 240,
        [string]$Label = 'container'
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $unreachable = 0
    $announced = $false
    $status = ''
    $stall = "container '$Name' was still running"

    while ($true) {
        $probe = Get-ContainerInspectField -DockerExe $DockerExe -Name $Name -Format '{{.State.Status}}'

        if ($probe.Ok) {
            $unreachable = 0
            $status = $probe.Value
            # Fail closed: only states documented to carry a final ExitCode end the wait.
            if ($status -in @('exited', 'dead', 'removing', 'created')) { break }
            if ($status -notin @('running', 'paused', 'restarting')) {
                throw ("[$Label] docker reported state '$status' for '$Name' - neither a running state " +
                    "nor a terminal one this function knows (exited, dead, removing, created). Refusing " +
                    'to read an exit code against a state it does not understand.')
            }
            $stall = "container '$Name' was still '$status'"
            if (-not $announced) {
                Write-Host ("[$Label] the docker client returned but container '$Name' is still $status - " +
                    "waiting on the container, not the client (poll ${PollSeconds}s).") -ForegroundColor Yellow
                $announced = $true
            }
        } elseif ($probe.Missing) {
            throw ("[$Label] container '$Name' no longer exists, so its exit code can never be read. " +
                "Something removed it while it was being waited on - a concurrent 'docker rm', or --rm on the " +
                'run that created it (a container that is waited on must be created WITHOUT --rm). ' +
                "docker said: $($probe.Error)")
        } elseif ($probe.DaemonUnreachable) {
            # An unreachable daemon says nothing about the container, so keep asking until the timeout.
            $unreachable++
            $stall = "the docker daemon was unreachable for $unreachable consecutive probe(s) ($($probe.Error))"
            if ($unreachable -eq 1) {
                Write-Warning ("[$Label] docker inspect cannot reach the daemon - retrying until the timeout; " +
                    "the container is unaffected. docker said: $($probe.Error)")
            }
        } else {
            throw ("[$Label] docker inspect of '$Name' failed (exit $($probe.ExitCode)) for a reason that is " +
                "neither a missing container nor an unreachable daemon, so the container's state is unknown " +
                "and waiting longer cannot help: $($probe.Error)")
        }

        if ((Get-Date) -ge $deadline) {
            throw ("[$Label] gave up after $TimeoutMinutes minute(s): $stall. Raise -TimeoutMinutes if the " +
                "build legitimately takes that long, or look at it with: docker logs $Name")
        }
        Start-Sleep -Seconds $PollSeconds
    }

    if ($status -eq 'created') {
        throw ("[$Label] container '$Name' never started (state 'created'), so its ExitCode is 0 without a " +
            'single instruction having run. Refusing to report that as a successful build.')
    }

    $exit = Get-ContainerInspectField -DockerExe $DockerExe -Name $Name -Format '{{.State.ExitCode}}'
    if (-not $exit.Ok) {
        throw ("[$Label] container '$Name' reached state '$status' but its exit code could not be read " +
            "(inspect exit $($exit.ExitCode)): $($exit.Error). Refusing to guess - an unreadable exit code is " +
            'not a zero one.')
    }
    $parsed = 0
    if (-not [int]::TryParse($exit.Value, [ref]$parsed)) {
        throw "[$Label] docker reported a non-numeric exit code for '$Name': '$($exit.Value)'."
    }
    return $parsed
}

<#
.SYNOPSIS
  Turns an environment hashtable into docker '-e NAME=VALUE' arguments.
.DESCRIPTION
  Hashtable keys are emitted sorted for a deterministic command line; an [ordered] dictionary keeps its order.
.OUTPUTS
  [string[]] - flat '-e', 'NAME=VALUE', ... suitable for splatting.
#>
function Get-ContainerEnvArgs {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Environment = @{})

    if (-not $Environment -or $Environment.Count -eq 0) { return @() }

    $keys = @($Environment.Keys)
    if ($Environment -is [hashtable]) { $keys = @($keys | Sort-Object) }

    $envArgs = @()
    foreach ($key in $keys) { $envArgs += @('-e', "$key=$($Environment[$key])") }
    return $envArgs
}

<#
.SYNOPSIS
  Standard sccache environment for builds inside a Windows build container.
.DESCRIPTION
  In the container filesystem, not a volume: docs/windows-container-build-performance.md § sccache's cache directory on a Windows container volume.
.OUTPUTS
  [ordered] environment; merge caller entries into it before Invoke-ContainerBuild -CacheEnv.
#>
function Get-SccacheContainerEnv {
    [CmdletBinding()]
    param(
        [string]$CacheDir = 'C:\sccache-local',
        [string]$CacheSize = '20G',
        # Not under $CacheDir: the server opens the log before creating the cache dir and dies without a parent.
        [string]$ErrorLogPath = 'C:\sccache-error.log',
        [string]$LogLevel = 'warn'
    )

    # Without the logs a failing cache write is silent: sccache counts it and discards the reason.
    return [ordered]@{
        SCCACHE_DIR        = $CacheDir
        SCCACHE_CACHE_SIZE = $CacheSize
        SCCACHE_ERROR_LOG  = $ErrorLogPath
        SCCACHE_LOG        = $LogLevel
    }
}

<#
.SYNOPSIS
  -CacheEnv plus this host's sccache remote tier, for the keys the caller did not set.
.DESCRIPTION
  A caller's key wins, '' included (the opt-out): docs/windows-build-resources.md#the-build-hosts-remote-tier-at-run-time
.OUTPUTS
  A new dictionary of the same kind as -CacheEnv; the caller's is never modified.
#>
function Add-HostSccacheRemoteEnv {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$CacheEnv = @{})

    $merged = if ($CacheEnv -is [hashtable]) { @{} } else { [ordered]@{} }
    if ($CacheEnv) { foreach ($k in $CacheEnv.Keys) { $merged[$k] = $CacheEnv[$k] } }
    $added = @()
    foreach ($name in 'SCCACHE_WEBDAV_ENDPOINT', 'SCCACHE_MULTILEVEL_CHAIN') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($value) -or $merged.Contains($name)) { continue }
        $merged[$name] = $value
        $added += $name
    }
    if ($added) { Write-Host "Forwarding this host's sccache remote tier into the container: $($added -join ', ')" }
    return $merged
}

<#
.SYNOPSIS
  Normalises -BuildCommand into the argv executed inside the container.
.DESCRIPTION
  A scriptblock gets the in-container workspace path; tokens must be space-free, as they travel via cmd /S /C and %*.
.OUTPUTS
  [string[]] - the argument vector.
#>
function Resolve-ContainerBuildCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BuildCommand,
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $resolved = if ($BuildCommand -is [scriptblock]) { & $BuildCommand $WorkspacePath } else { $BuildCommand }
    $resolved = @($resolved | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
    if ($resolved.Count -eq 0) { throw '-BuildCommand produced an empty argument list.' }
    return $resolved
}

<#
.SYNOPSIS
  Builds a project inside a Windows build container, choosing the transport.
.DESCRIPTION
  Tar-pipe by default, bind mount (the CI flow) via -UseBindMount. Setup,
  measurements and path rules: docs/windows-container-build-performance.md.
.PARAMETER WorkspacePath
  Shared by both transports so a CMake cache survives a switch; never a path baked into the image.
.PARAMETER BuildCommand
  Scriptblock (receives the in-container workspace path) or string[] with the argv to run.
.PARAMETER IncrementalDirs
  Host build dirs streamed in first so ninja rebuilds only changes; ignored for a reused container.
.PARAMETER IncrementalExclude
  Sub-paths of each incremental directory excluded from the inbound transfer.
.PARAMETER OutputDirs
  Workspace-relative directories streamed back to the host when they exist.
.PARAMETER VerifyDirs
  Subset of -OutputDirs that must contain executables and have them delivered.
.PARAMETER CacheEnv
  Container environment (see Get-SccacheContainerEnv); Add-HostSccacheRemoteEnv fills the host's remote tier.
.PARAMETER WaitTimeoutMinutes
  How long the bind-mount run waits on a container still running after the client returned.
.OUTPUTS
  [pscustomobject] Transport ('bindmount' | 'tarpipe'), Container ($null for bind mount), Verified (dir -> exe count).
#>
function Invoke-ContainerBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$BuildCommand,
        [string]$WorkspacePath = 'C:\ws',
        [string[]]$IncrementalDirs = @(),
        [string[]]$IncrementalExclude = @(),
        [string[]]$OutputDirs = @(),
        [string[]]$VerifyDirs = @(),
        [string[]]$InboundExclude = @(),
        # bsdtar excludes match at every depth; omit a root dir here instead of excluding its name.
        [string[]]$InboundItems = @('.'),
        [string[]]$OutboundExclude = @(),
        [string[]]$KeepDirs = @('logs'),
        [System.Collections.IDictionary]$CacheEnv = @{},
        [string[]]$IsolationArgs = @(),
        [string]$EntrypointPath = 'C:\temp\scripts\entrypoint.cmd',
        [string]$ProbeFile = 'CMakePresets.json',
        # Raise it for a slower project rather than removing the bound.
        [ValidateRange(0.01, 10080)][double]$WaitTimeoutMinutes = 240,
        # Off by default: measured slower on a Dev Drive host.
        [switch]$UseBindMount,
        # Start from a clean container, e.g. after deleting files the reused one may still hold.
        [switch]$FreshContainer
    )

    $cacheArgs = Get-ContainerEnvArgs -Environment (Add-HostSccacheRemoteEnv -CacheEnv $CacheEnv)
    $buildArgs = Resolve-ContainerBuildCommand -BuildCommand $BuildCommand -WorkspacePath $WorkspacePath

    # Bind mount is opt-in: see docs/windows-container-build-performance.md § Why the bind mount lost here
    $bindMountUsable = $false
    if ($UseBindMount) {
        Write-Host 'Probing bind mount support...'
        $bindMountUsable = Test-ContainerBindMount -DockerExe $DockerExe -Image $Image -SourcePath $RepoRoot `
            -TargetPath $WorkspacePath -ProbeFile $ProbeFile -RunArgs $IsolationArgs
    }

    if ($bindMountUsable) {
        Write-Host 'Bind mount usable - building directly in the working tree.'
        # Named and not --rm, both load-bearing: docs/windows-container-build-performance.md § Reusable implementation
        $runContainer = "$ContainerName-bindmount"
        $leftover = Get-ContainerInspectField -DockerExe $DockerExe -Name $runContainer -Format '{{.State.Status}}'
        if ($leftover.Ok -and $leftover.Value -in @('running', 'paused', 'restarting')) {
            throw ("A bind-mount build container '$runContainer' is already $($leftover.Value) - another " +
                "build of this tree, or a runaway a timed-out wait kept for inspection. Refusing to kill " +
                "it: wait for it, read it with 'docker logs $runContainer', or remove it with " +
                "'docker rm -f $runContainer'.")
        }
        if (-not (Remove-BuildContainerSafe -DockerExe $DockerExe -Name $runContainer)) {
            # A held name fails 'docker run' and the wait would read the stale exit code.
            $runContainer = "$runContainer-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
            Write-Warning "Falling back to '$runContainer' so this run cannot inherit the old container's exit code."
        }
        $keep = $false
        $created = $false
        try {
            # Out-Host: build output must not join this function's result; $LASTEXITCODE survives the pipe.
            & $DockerExe run --name $runContainer @IsolationArgs @cacheArgs `
                --mount "type=bind,source=$RepoRoot,target=$WorkspacePath" `
                -w $WorkspacePath $Image @buildArgs | Out-Host
            $clientExit = $LASTEXITCODE
            $created = $true
            if ($clientExit -ne 0) {
                # No container means no state to wait on (unresolvable image, refused mount).
                $started = Get-ContainerInspectField -DockerExe $DockerExe -Name $runContainer `
                    -Format '{{.State.Status}}'
                if ($started.Missing) {
                    $created = $false
                    throw ("Container build failed (exit $clientExit) - docker run never created a container " +
                        "to wait on. docker said: $($started.Error)")
                }
            }
            $buildExit = Wait-ContainerExit -DockerExe $DockerExe -Name $runContainer -Label 'bindmount' `
                -TimeoutMinutes $WaitTimeoutMinutes
            if ($clientExit -ne $buildExit) {
                # Never silent: if a green build is ever wrong, this line is the first place to look.
                Write-Warning ("The docker client exited $clientExit but the container's real exit code is " +
                    "$buildExit (dropped client pipe). Trusting the container.")
            }
            if ($buildExit -ne 0) { throw "Container build failed (exit $buildExit)." }
        } catch {
            # The throws above point at 'docker logs', so a failed container is kept as evidence.
            if ($created) {
                $keep = $true
                Write-Warning ("Keeping container '$runContainer' so it can be inspected: " +
                    "docker logs $runContainer - remove it with: docker rm -f $runContainer")
            }
            throw
        } finally {
            if (-not $keep) { [void](Remove-BuildContainerSafe -DockerExe $DockerExe -Name $runContainer) }
        }
        return [pscustomobject]@{ Transport = 'bindmount'; Container = $null; Verified = @{} }
    }

    if ($UseBindMount) {
        Write-Host 'Bind mount requested but unusable - falling back to tar-pipe transport.'
    } else {
        Write-Host 'Using tar-pipe transport with a reusable container (faster here; -UseBindMount to override).'
    }

    # A blocked -Fresh removal falls back to a unique name, so it may not match $ContainerName.
    $containerInfo = Get-ReusableBuildContainer -DockerExe $DockerExe -Name $ContainerName -Image $Image `
        -RunArgs ($IsolationArgs + $cacheArgs) -Fresh:$FreshContainer
    $reusedContainer = $containerInfo.Reused
    $container = $containerInfo.Name
    $verified = [ordered]@{}

    try {
        & $DockerExe exec $container cmd /c "mkdir $WorkspacePath" | Out-Null

        $null = Initialize-ContainerPwsh -DockerExe $DockerExe -Container $container

        Write-Host 'Streaming sources into the container...'
        if ($reusedContainer) {
            Write-Host 'Pruning stale sources from the reusable container...'
            $null = Remove-StaleContainerSources -DockerExe $DockerExe -Container $container `
                -WorkspacePath $WorkspacePath -KeepDirs $KeepDirs
        }

        $sourcesIn = Copy-IntoBuildContainer -DockerExe $DockerExe -Container $container `
            -SourceRoot $RepoRoot -TargetPath $WorkspacePath -Items $InboundItems -Exclude $InboundExclude
        if (-not $sourcesIn) { throw 'Source transfer failed.' }

        # Streamed in rather than mounted as a volume, which CMake cannot configure inside.
        $streamedIn = @()
        foreach ($buildDirName in $IncrementalDirs) {
            if ($reusedContainer) { break } # tree already lives in the container
            if (-not $buildDirName) { continue }
            $hostBuildDir = Join-Path $RepoRoot $buildDirName
            if (-not (Test-Path $hostBuildDir)) { continue }

            Write-Host "Streaming existing $buildDirName into the container (incremental build)..."
            # Deep generated trees (cxxbridge) exceed the path limit and fail the whole transfer; they rebuild cheaply.
            $treeIn = Copy-IntoBuildContainer -DockerExe $DockerExe -Container $container `
                -SourceRoot $RepoRoot -TargetPath $WorkspacePath `
                -Items @($buildDirName) `
                -Exclude @($IncrementalExclude | ForEach-Object { "$buildDirName/$_" })
            if (-not $treeIn) {
                Write-Host '  transfer reported errors - ninja will rebuild whatever did not arrive'
            }
            $streamedIn += $buildDirName
        }

        # A streamed-in cache holds host source paths CMake rejects; only those trees, as a reused one's objects must survive.
        foreach ($buildDirName in $streamedIn) {
            Write-Host "Deleting stale CMakeCache.txt in $buildDirName (container paths differ from host)..."
            $stale = "$WorkspacePath\$buildDirName"
            & $DockerExe exec $container cmd /c "if exist $stale\CMakeCache.txt del /q $stale\CMakeCache.txt 2>nul" | Out-Host
            & $DockerExe exec $container cmd /c "if exist $stale\CMakeFiles rmdir /s /q $stale\CMakeFiles 2>nul" | Out-Host
        }

        # docker exec bypasses the entrypoint, which provides the VS environment and the ASan runtime on PATH.
        & $DockerExe exec -w $WorkspacePath $container cmd /S /C $EntrypointPath @buildArgs | Out-Host
        $buildExit = $LASTEXITCODE

        Write-Host 'Streaming build trees and logs back to the working tree...'
        $existing = @()
        foreach ($dir in $OutputDirs) {
            & $DockerExe exec $container cmd /c "if exist $WorkspacePath\$dir (exit 0) else (exit 1)" | Out-Host
            if ($LASTEXITCODE -eq 0) { $existing += $dir }
        }
        if ($existing.Count -gt 0) {
            # Only what the host runs: the container keeps the full tree, and deep paths abort extraction.
            $artifactsOut = Copy-FromBuildContainer -DockerExe $DockerExe -Container $container `
                -SourcePath $WorkspacePath -TargetRoot $RepoRoot -Items $existing -Exclude $OutboundExclude
            if (-not $artifactsOut) {
                Write-Warning 'Artifact extraction reported errors - check executable timestamps.'
            }
        }

        if ($buildExit -ne 0) {
            # A dead or missing container is not a compile error, so classify it.
            $state = Get-ContainerInspectField -DockerExe $DockerExe -Name $container -Format '{{.State.Status}}'
            if ($state.Missing) {
                throw ("The build container '$container' disappeared while the build was running (docker exec " +
                    "exit $buildExit). Nothing compiled past that point, so this is not a build failure to " +
                    "look for in the log. docker said: $($state.Error)")
            }
            if ($state.Ok -and $state.Value -ne 'running') {
                throw ("The build container '$container' stopped (state '$($state.Value)') while the build was " +
                    "running (docker exec exit $buildExit) - the build died with the container, not on an " +
                    'error in the code.')
            }
            throw "Container build failed (exit $buildExit)."
        }

        foreach ($dir in $existing) {
            if ($VerifyDirs -notcontains $dir) { continue }
            $delivered = Test-BuildArtifactsDelivered -DockerExe $DockerExe -Container $container `
                -WorkspacePath $WorkspacePath -Directory $dir -HostRoot $RepoRoot
            $verified[$dir] = $delivered
            Write-Host "Verified $delivered executable(s) delivered from $dir."
        }
    } finally {
        Write-Host "Keeping build container '$container' for the next build (reset: -FreshContainer)."
    }

    return [pscustomobject]@{ Transport = 'tarpipe'; Container = $container; Verified = $verified }
}

Export-ModuleMember -Function @(
    'Get-ReusableBuildContainer',
    'Get-ContainerEnvArgs',
    'Get-SccacheContainerEnv',
    'Resolve-ContainerBuildCommand',
    'Invoke-ContainerBuild',
    'Copy-IntoBuildContainer',
    'Copy-FromBuildContainer',
    'Initialize-ContainerPwsh',
    'Remove-StaleContainerSources',
    'Test-BuildArtifactsDelivered',
    'Resolve-DockerExe',
    'Get-ContainerIsolationArgs',
    'Test-ContainerBindMount',
    'Remove-BuildContainerSafe',
    'Wait-ContainerExit'
)

