# Reusable Windows build-container lifecycle and transfer helpers.
#
# Building a large project inside a Windows container is dominated by two
# costs: recompiling everything because the container is fresh, and moving the
# build tree in and out. Reusing ONE container removes both - the build tree,
# ninja graph and C++ module BMIs simply stay where they are.
#
# Measured on a ~690-object C++23 modules project: 48 s incremental vs
# 352-484 s with a fresh container per build. Background, including three
# approaches that do NOT work, is in
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
  [bool] $true when an existing container was reused (its build tree is intact),
  $false when a new one was created (callers may want to seed it).
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
            return $true
        } else {
            Write-Host "Starting existing build container '$Name'..."
            & $DockerExe start $Name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
            & $DockerExe rm -f $Name 2>&1 | Out-Null
        }
    }

    Write-Host "Creating build container '$Name'..."
    & $DockerExe run -d --name $Name @RunArgs --entrypoint cmd $Image `
        /c 'ping -n 604800 127.0.0.1 > nul' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to start build container '$Name'." }
    return $false
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
  compile database, logs) instead of the whole build tree.
#>
function Copy-FromBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerExe,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    $patternArgs = ($Patterns -join ' ')
    $command = "`"$DockerExe`" exec $Container cmd /c `"cd /d $SourcePath && tar -cf - $patternArgs`" | tar -xf - -C `"$TargetRoot`""
    cmd /c $command
    return ($LASTEXITCODE -eq 0)
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
    'Resolve-DockerExe',
    'Get-ContainerIsolationArgs',
    'Test-ContainerBindMount',
    'Remove-BuildContainerSafe'
)
