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

Export-ModuleMember -Function @(
    'Get-ReusableBuildContainer',
    'Copy-IntoBuildContainer',
    'Copy-FromBuildContainer'
)
