#requires -Version 7.0
# Reusable Windows build-container lifecycle and transfer helpers.
#
# CONSUMED-BY (downstream repos vendoring this repo as ExternalLib — verified
# 2026-08-17; nothing INSIDE this repo imports this module except its tests, so
# an in-repo dead-code sweep WILL flag it and would be wrong, backlog #105):
#   BeschleunigerBallett/scripts/windows/Build-Windows-Container.ps1
#     (Invoke-ContainerBuild, Get-ReusableBuildContainer, Copy-Into/From...,
#      Resolve-DockerExe, Get-ContainerIsolationArgs, ...)
#   OxidANT/scripts/windows/container/Invoke-StevedoreBuild.ps1
#     (Resolve-DockerExe, Get-ContainerIsolationArgs, Remove-BuildContainerSafe;
#      list re-read 2026-09-06 - it had drifted)
# Renames/removals here are BREAKING changes for those repos.
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
        # pwsh 7 everywhere (host policy 2026-08-04) — every image in this
        # chain carries pwsh from the base layer on.
        Get-Content $pruneTmp -Raw | & $DockerExe exec -i $Container pwsh -NoProfile -Command -
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
  Stevedore's docker.exe is the supported classic-lane client (nerdctl needs an
  elevated shell for containerd's admin-only pipe; the BuildKit lane uses
  buildctl instead — see windows/Build-Buildkit.ps1). Checks an explicit
  override, then $env:DOCKER_EXE, then the usual Stevedore install locations,
  then PATH.
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

<#
.SYNOPSIS
  Reads one 'docker inspect' format field and classifies the failure if it fails.
.DESCRIPTION
  Internal helper for Wait-ContainerExit (deliberately not exported). It exists
  to keep three outcomes apart that need OPPOSITE reactions: the field was read;
  the container is GONE (no amount of waiting will ever produce an answer); or
  the client could not reach the daemon, which is a statement about the CLI and
  says nothing at all about the container.

  $ErrorActionPreference is pinned to 'Continue' around the call for the reason
  it is everywhere else in this module: docker's stderr must not turn into a
  terminating NativeCommandError.

  Value comes ONLY from stdout: docker prints client notices (deprecations,
  context warnings) on stderr BEFORE the field value, so a first-line pick over
  a merged stream returns the notice as the "value" - a clean container read as
  a non-numeric exit code. stderr is kept separately for the classification.
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
        # Redirected native stderr arrives as ErrorRecords - split the streams
        # so a stderr notice can never be mistaken for the field value.
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
    # Classification prefers stderr; a docker that reports its failure on
    # stdout instead must still be classifiable, hence the fallback.
    $errorSource = if ($stderrLines.Count -gt 0) { $stderrLines } else { $stdoutLines }
    $text = (@($errorSource) -join "`n").Trim()

    return [pscustomobject]@{
        Ok                = ($code -eq 0)
        Value             = $value
        ExitCode          = $code
        Error             = $text
        # 'Error: No such object: <name>' (inspect) / 'No such container'.
        Missing           = (($code -ne 0) -and ($text -match 'No such (object|container)'))
        # 'error during connect: ... open //./pipe/docker_engine: The system
        # cannot find the file specified.' - the client, not the container.
        DaemonUnreachable = (($code -ne 0) -and
            ($text -match 'error during connect|docker_engine|Cannot connect to the Docker daemon|daemon is not running'))
    }
}

<#
.SYNOPSIS
  Waits for a named container to stop and returns the exit code it really had.
.DESCRIPTION
  The docker CLI intermittently drops its pipe mid-run while the container keeps
  working, and the client then reports a failure that did not happen - the build
  is still compiling and usually goes on to succeed. OxidANT's Stevedore lane hit
  it often enough to change shape for it; its
  scripts/windows/container/Invoke-StevedoreBuild.ps1 header states the rule
  this function upstreams verbatim: "The docker CLI intermittently drops its pipe
  mid-run while the container keeps working, so the container is named (not
  --rm) and this script waits on the actual container state, not the client exit
  code." Same host, same family as the 2026-09-01 finding that a RUN step's
  container exit NOTIFICATION is what goes missing while the work itself
  completes (CHANGELOG, "the container-start wedge is a lost exit notification").

  Only meaningful for a container whose MAIN process IS the workload
  ('docker run --name ...' WITHOUT --rm - with --rm the daemon deletes the
  container the instant it exits and takes the exit code with it). It does NOT
  apply to 'docker exec' inside the reusable build container: that container's
  main process is a 7-day ping, so State.Status reads 'running' no matter what
  the exec'd build did.

  Every failure is named instead of being folded into a bogus exit code. The
  consumer's loop returned an EMPTY string when inspect failed and its caller
  reported that as "exit ", which reads like a build failure and is not one. A
  daemon that cannot be reached DURING the wait is the very fault being
  tolerated, so it is retried until -TimeoutMinutes and then thrown with its own
  count; a vanished container, any other inspect failure, and the timeout each
  throw immediately, saying which case fired.
.PARAMETER PollSeconds
  Seconds between state probes (15 in the consumer this came from: a wasted
  build-minute is cheap, a daemon round trip is not free).
.PARAMETER TimeoutMinutes
  Upper bound on the wait - the consumer's loop had none and could hang a lane
  forever. [double] so sub-minute waits are expressible (the suite uses that);
  the default is four hours, well past any cold build measured here (the slowest
  is 474 s).
.PARAMETER Label
  Prefix for the messages, so a caller running several phases can tell them
  apart ('build' / 'test' in the consumer).
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
            # Fail CLOSED: only states documented to carry a final ExitCode end
            # the wait; an empty or unknown state must not read as "finished".
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
            # An unreachable daemon says nothing about the container - keep
            # asking until the timeout instead of failing a live build.
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
  Plain hashtables are unordered, so their keys are emitted sorted to keep the
  produced command line deterministic (and testable). Pass an [ordered]
  dictionary to control the order yourself.
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
  Persistent compiler cache - in the CONTAINER filesystem, deliberately NOT on
  a named volume.

  The volume was the cause of the "every sccache write fails" mystery.
  Diagnosed 2026-07-20 by running the server by hand with SCCACHE_LOG=trace:
  every DiskCache::put_raw died with os error 3 ("The system cannot find the
  path specified") when SCCACHE_DIR sat on the wcifs volume mount, while
  PowerShell in the same container could write the same paths - including
  \?\-prefixed ones - without error. Pointing SCCACHE_DIR at a
  container-local directory made the very next compile pair go miss -> HIT
  with zero write errors, so the failure is specific to how the sccache
  server writes (tempfile + rename) on a wcifs volume, and no cache written
  through that mount was ever going to persist anything.

  Container-local means the cache dies with the container - which is fine,
  because builds run in the PERSISTENT reusable container; the cache survives
  exactly as long as the thing that uses it. A volume that takes 100% write
  errors persisted nothing anyway.

  NOTE: mounting the build directory as a named volume was TRIED and does not
  work here - CMake's compiler test fails inside a mounted volume with
  "ninja: error: loading 'build.ninja': The system cannot find the file
  specified", both with a fresh volume and a populated one. See
  docs/container-build-caching.md for the full measurement.
.OUTPUTS
  [ordered] dictionary of environment variables; merge caller-specific entries
  into it before handing it to Invoke-ContainerBuild -CacheEnv.
#>
function Get-SccacheContainerEnv {
    [CmdletBinding()]
    param(
        [string]$CacheDir = 'C:\sccache-local',
        [string]$CacheSize = '20G',
        # The error log must NOT live under $CacheDir: sccache's disk cache
        # creates its own directory, but the server OPENS THE ERROR LOG FIRST
        # and dies if its parent does not exist - and then every
        # sccache-wrapped tool fails with "Timed out waiting for server
        # startup". With RUSTC_WRAPPER=sccache that poisons even `cargo tree`,
        # which corrosion reports as "Failed to find a dependency on
        # cxxbridge-cmd" - three indirections from the cause. C:\ always exists.
        [string]$ErrorLogPath = 'C:\sccache-error.log',
        [string]$LogLevel = 'warn'
    )

    # Without SCCACHE_ERROR_LOG/SCCACHE_LOG, a failing cache write is silent:
    # sccache reports the count in its stats and discards the reason. Measured
    # 2026-07-20: 66 write errors out of 66 misses, i.e. every single write
    # failing, with no way to see why.
    return [ordered]@{
        SCCACHE_DIR        = $CacheDir
        SCCACHE_CACHE_SIZE = $CacheSize
        SCCACHE_ERROR_LOG  = $ErrorLogPath
        SCCACHE_LOG        = $LogLevel
    }
}

<#
.SYNOPSIS
  Normalises -BuildCommand into the argv executed inside the container.
.DESCRIPTION
  Accepts a [scriptblock] (invoked with the in-container workspace path, so the
  caller can bake absolute container paths into its arguments) or a ready-made
  string array. Every token must be free of spaces: it travels
  docker CLI -> cmd /S /C -> %*.
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
  The whole container build flow, minus anything project-specific: pick the
  transport, get/reuse the container, stream sources (and existing build trees)
  in, run the caller's command, stream artifacts back out, and prove they
  actually arrived.

  Two transport modes; the tar pipe is the default, -UseBindMount opts in:
    1. Tar pipe (default): sources are streamed into a container-local
       directory in the reusable build container, built there, and the build
       trees + logs are streamed back out. Measured FASTER than the bind
       mount on a Dev Drive host (the build tree stays off the bindFlt
       filter).
    2. Bind mount (-UseBindMount): the repo is mounted read/write into the
       container and build directories land directly in the working tree -
       the same flow CI uses. On a Dev Drive whose filters are not
       allow-listed the mount cannot attach at all (error "Der
       Dateisystem-Minifilter kann nicht an das Entwicklervolume angefügt
       werden"); to make it attachable, run once (elevated):
         fsutil devdrv setfiltersallowed bindFlt, wcifs
       then remount the volume (or reboot).

  -WorkspacePath is used as the mount target AND as the tar-pipe destination,
  and that matters: CMake bakes absolute paths into CMakeCache.txt and refuses
  to reuse a cache generated elsewhere ("The source C:/ws-mnt/CMakeLists.txt
  does not match the source C:/ws/CMakeLists.txt used to generate cache").
  Sharing one path means a tree built under either transport stays usable by
  the other, so switching between them does not force a cold rebuild.

  It must still be a path that is NOT baked into the image: mounting over a
  directory that exists in the image (C:\workspace) fails at
  CreateComputeSystem when the host OS build differs from the image base build.
  C:\ws is absent from the ContainerHub image (verified) and is created by the
  mount.
.PARAMETER BuildCommand
  Scriptblock (receives the in-container workspace path) or string[] returning
  the argv to run inside the container.
.PARAMETER IncrementalDirs
  Host-relative build directories to stream back IN before building, so ninja
  rebuilds only what changed. Ignored when an existing container is reused -
  its tree is already there and newer.
.PARAMETER IncrementalExclude
  Sub-paths, relative to each incremental directory, excluded from the inbound
  transfer.
.PARAMETER OutputDirs
  Workspace-relative directories streamed back to the host when they exist.
.PARAMETER VerifyDirs
  Subset of -OutputDirs that must contain executables and have them delivered.
.PARAMETER CacheEnv
  Environment entries applied to the container (compiler cache, image
  contract flags, ...). See Get-SccacheContainerEnv.
.PARAMETER WaitTimeoutMinutes
  How long the bind-mount transport waits on a container that is still running
  after the docker client returned. See Wait-ContainerExit.
.OUTPUTS
  [pscustomobject] with Transport ('bindmount' | 'tarpipe'), Container (the
  container actually used, or $null for a bind-mount run) and Verified (a
  dictionary of directory -> delivered executable count).
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
        [string[]]$OutboundExclude = @(),
        [string[]]$KeepDirs = @('logs'),
        [System.Collections.IDictionary]$CacheEnv = @{},
        [string[]]$IsolationArgs = @(),
        [string]$EntrypointPath = 'C:\temp\scripts\entrypoint.cmd',
        [string]$ProbeFile = 'CMakePresets.json',
        # Bound for Wait-ContainerExit (~30x the slowest cold build measured);
        # raise it for a slower project rather than removing the bound.
        [ValidateRange(0.01, 10080)][double]$WaitTimeoutMinutes = 240,
        # Opt into the bind-mount transport. Off by default because it is
        # MEASURED SLOWER on a Dev Drive host - see the measurements below.
        [switch]$UseBindMount,
        # Discard the reusable build container and start from a clean one. Use
        # when a build behaves strangely, or after deleting files that the
        # container may still hold (sources are overwritten in place, never
        # pruned).
        [switch]$FreshContainer
    )

    $cacheArgs = Get-ContainerEnvArgs -Environment $CacheEnv
    $buildArgs = Resolve-ContainerBuildCommand -BuildCommand $BuildCommand -WorkspacePath $WorkspacePath

    # Bind mounting looks like the obvious win - no tar transport at all - and
    # it is SLOWER here. Measured 2026-07-19 on a Dev Drive host, same tree,
    # both transports at C:\ws:
    #
    #   no-change build   tar-pipe + reused container   9.6 s ninja / 44 s wall
    #   no-change build   bind mount                   32.7 s ninja / 159 s wall
    #   cold build        tar-pipe                    327.9 s / 364 s
    #   cold build        bind mount                  318.1 s / 474 s
    #
    # Removing the transport does not pay for what it adds: the build tree then
    # lives on the Dev Drive and every ninja stat and object write crosses the
    # bindFlt filter from inside the container. Copying the sources in bulk once
    # is cheaper than paying filtered I/O on ~1000 targets. Repeated to confirm
    # it was not a first-run artifact (32.7 s vs 34.5 s).
    #
    # Kept behind an opt-in switch because the trade may invert elsewhere: on a
    # non-Dev-Drive volume, or with a much smaller build tree, the transport can
    # dominate instead.
    $bindMountUsable = $false
    if ($UseBindMount) {
        Write-Host 'Probing bind mount support...'
        $bindMountUsable = Test-ContainerBindMount -DockerExe $DockerExe -Image $Image -SourcePath $RepoRoot `
            -TargetPath $WorkspacePath -ProbeFile $ProbeFile -RunArgs $IsolationArgs
    }

    if ($bindMountUsable) {
        Write-Host 'Bind mount usable - building directly in the working tree.'
        # NAMED and NOT --rm - both load-bearing for Wait-ContainerExit:
        # see docs/windows-container-build-performance.md § Reusable implementation.
        $runContainer = "$ContainerName-bindmount"
        $leftover = Get-ContainerInspectField -DockerExe $DockerExe -Name $runContainer -Format '{{.State.Status}}'
        if ($leftover.Ok -and $leftover.Value -in @('running', 'paused', 'restarting')) {
            throw ("A bind-mount build container '$runContainer' is already $($leftover.Value) - another " +
                "build of this tree, or a runaway a timed-out wait kept for inspection. Refusing to kill " +
                "it: wait for it, read it with 'docker logs $runContainer', or remove it with " +
                "'docker rm -f $runContainer'.")
        }
        if (-not (Remove-BuildContainerSafe -DockerExe $DockerExe -Name $runContainer)) {
            # A held name makes 'docker run --name' fail 125 and the wait below
            # read the STALE exit code; fall back unique, like -Fresh does.
            $runContainer = "$runContainer-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
            Write-Warning "Falling back to '$runContainer' so this run cannot inherit the old container's exit code."
        }
        $keep = $false
        $created = $false
        try {
            & $DockerExe run --name $runContainer @IsolationArgs @cacheArgs `
                --mount "type=bind,source=$RepoRoot,target=$WorkspacePath" `
                -w $WorkspacePath $Image @buildArgs
            $clientExit = $LASTEXITCODE
            $created = $true
            if ($clientExit -ne 0) {
                # No container, no state to wait on (unresolvable image, mount
                # refused): see the performance doc § Reusable implementation.
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
                # Client and container disagree - never silent: if a green
                # build is ever wrong, this line is the first place to look.
                Write-Warning ("The docker client exited $clientExit but the container's real exit code is " +
                    "$buildExit (dropped client pipe). Trusting the container.")
            }
            if ($buildExit -ne 0) { throw "Container build failed (exit $buildExit)." }
        } catch {
            # Every throw above points the operator at 'docker logs'; removing
            # the container here would destroy the evidence it just promised.
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

    # Returns the container actually used: a blocked -Fresh removal falls back
    # to a uniquely named container, so never assume it matches $ContainerName.
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
            -SourceRoot $RepoRoot -TargetPath $WorkspacePath -Exclude $InboundExclude
        if (-not $sourcesIn) { throw 'Source transfer failed.' }

        # Incremental builds: the host already holds the previous build tree (it
        # is streamed back out after every build), so stream it back IN. ninja
        # then rebuilds only what changed instead of every object from scratch.
        # This avoids mounting the build dir as a volume, which CMake cannot
        # configure inside (see Get-SccacheContainerEnv).
        $streamedIn = @()
        foreach ($buildDirName in $IncrementalDirs) {
            if ($reusedContainer) { break } # tree already lives in the container
            if (-not $buildDirName) { continue }
            $hostBuildDir = Join-Path $RepoRoot $buildDirName
            if (-not (Test-Path $hostBuildDir)) { continue }

            Write-Host "Streaming existing $buildDirName into the container (incremental build)..."
            # -IncrementalExclude exists because deeply nested generated output
            # (cargo's cxxbridge tree) blows past the Windows path limit inside
            # the container ("Can't create ...: Invalid argument"), which fails
            # the WHOLE transfer. Such trees rebuild cheaply, so skipping them
            # costs little.
            $treeIn = Copy-IntoBuildContainer -DockerExe $DockerExe -Container $container `
                -SourceRoot $RepoRoot -TargetPath $WorkspacePath `
                -Items @($buildDirName) `
                -Exclude @($IncrementalExclude | ForEach-Object { "$buildDirName/$_" })
            if (-not $treeIn) {
                Write-Host '  transfer reported errors - ninja will rebuild whatever did not arrive'
            }
            $streamedIn += $buildDirName
        }

        # A build tree streamed from the host carries a CMakeCache.txt with HOST
        # source-directory paths (D:/...). Inside the container the source is at
        # <workspace>/..., so CMake rejects the cache. Delete it so CMake
        # reconfigures from scratch with container-local paths. Object files
        # survive (ninja incremental), so this is fast after the first
        # reconfigure. Only the trees actually streamed in this run need it - a
        # reused container's tree was already generated at these paths, and
        # wiping its CMakeFiles would throw away every object file.
        foreach ($buildDirName in $streamedIn) {
            Write-Host "Deleting stale CMakeCache.txt in $buildDirName (container paths differ from host)..."
            $stale = "$WorkspacePath\$buildDirName"
            & $DockerExe exec $container cmd /c "if exist $stale\CMakeCache.txt del /q $stale\CMakeCache.txt 2>nul"
            # Also remove any stale CMakeFiles directory that could interfere
            & $DockerExe exec $container cmd /c "if exist $stale\CMakeFiles rmdir /s /q $stale\CMakeFiles 2>nul"
        }

        # docker exec bypasses the image entrypoint, so invoke it explicitly to
        # get the VS developer environment and the clang-cl ASAN runtime on PATH.
        & $DockerExe exec -w $WorkspacePath $container cmd /S /C $EntrypointPath @buildArgs
        $buildExit = $LASTEXITCODE

        Write-Host 'Streaming build trees and logs back to the working tree...'
        $existing = @()
        foreach ($dir in $OutputDirs) {
            & $DockerExe exec $container cmd /c "if exist $WorkspacePath\$dir (exit 0) else (exit 1)"
            if ($LASTEXITCODE -eq 0) { $existing += $dir }
        }
        if ($existing.Count -gt 0) {
            # -OutboundExclude drops deep or heavy intermediates on the way out
            # for the same reason they are excluded on the way in: paths that
            # exceed the Windows path limit abort the extraction ("Artifact
            # extraction failed").
            # The build tree now stays in the reusable container, so the host
            # only needs what it actually runs: executables, their debug info,
            # the compile database (clang-tidy) and logs. Copying the whole
            # ~8.5 GB tree back was pure overhead, and its deep cargo/cxxbridge
            # paths are what produced the "Artifact extraction failed" warnings.
            # Dropping the heavy intermediates keeps the transfer small while
            # the host still gets what it needs. The container keeps the full
            # tree, so nothing here has to seed a rebuild.
            $artifactsOut = Copy-FromBuildContainer -DockerExe $DockerExe -Container $container `
                -SourcePath $WorkspacePath -TargetRoot $RepoRoot -Items $existing -Exclude $OutboundExclude
            if (-not $artifactsOut) {
                Write-Warning 'Artifact extraction reported errors - check executable timestamps.'
            }
        }

        if ($buildExit -ne 0) {
            # A dead/missing container is not a compile error - classify it:
            # see docs/windows-builds.md (exec exit codes are unrecoverable).
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

        # A green build is not proof that anything was produced or delivered -
        # both halves of that have already failed here silently (see
        # Test-BuildArtifactsDelivered). Throws on either failure mode.
        foreach ($dir in $existing) {
            if ($VerifyDirs -notcontains $dir) { continue }
            $delivered = Test-BuildArtifactsDelivered -DockerExe $DockerExe -Container $container `
                -WorkspacePath $WorkspacePath -Directory $dir -HostRoot $RepoRoot
            $verified[$dir] = $delivered
            Write-Host "Verified $delivered executable(s) delivered from $dir."
        }
    } finally {
        # The container is intentionally reused across builds - that is what
        # makes builds incremental without moving the tree. Remove it with
        # 'docker rm -f <name>' (Remove-BuildContainerSafe tolerates the wcifs
        # teardown lock) or rerun with -FreshContainer.
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

