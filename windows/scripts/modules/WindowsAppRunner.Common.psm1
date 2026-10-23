# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Windows twin of linux/scripts/lib/app-runner.sh; the exit code stays in $LASTEXITCODE because the app owns stdout.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1')

# Tries the flat build root, bin\ and per-configuration dirs before a recursive search.
function Resolve-AppExecutablePath {
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    [string[]]$Configurations = @('Debug')
  )

  $relativeDirs = @('', 'bin')
  foreach ($configuration in $Configurations) {
    $relativeDirs += @((Join-Path 'bin' $configuration), $configuration)
  }
  return Resolve-BuildExecutable -BuildRoot $BuildRoot -ExecutableName $ExecutableName `
    -RelativeDirectory $relativeDirs -ResolveCandidatePath
}

# Throws when no executable is found; otherwise $LASTEXITCODE holds the exit code, 1 if the process never started.
function Invoke-AppRun {
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    [string[]]$Configurations = @('Debug'),
    # The app usually resolves its assets relative to the current location.
    [string]$WorkingDirectory = (Get-Location).Path,
    [string[]]$ExeArgs = @(),
    # Per-profile env setup before the directory switch; its $env: writes are process-wide.
    [scriptblock]$EnvHook,
    # Free-form label for the "Starting" line, e.g. "release" / "profile".
    [string]$Label,
    [string]$NotFoundHint
  )

  $exePath = Resolve-AppExecutablePath -BuildRoot $BuildRoot -ExecutableName $ExecutableName -Configurations $Configurations
  if (-not $exePath) {
    $notFoundMessage = "Executable '$ExecutableName' not found inside $BuildRoot."
    if (-not [string]::IsNullOrWhiteSpace($NotFoundHint)) {
      $notFoundMessage = "$notFoundMessage $NotFoundHint"
    }
    throw $notFoundMessage
  }

  $startSuffix = if ([string]::IsNullOrWhiteSpace($Label)) { '' } else { " ($Label)" }
  Write-Host "Starting$startSuffix $exePath..."
  Write-Host "Working Directory: $WorkingDirectory"

  try {
    if ($EnvHook) {
      & $EnvHook
    }

    # Push/Pop: this runs in the caller's session, where a bare Set-Location would stick.
    Push-Location -Path $WorkingDirectory
    try {
      if ($null -ne $ExeArgs -and $ExeArgs.Count -gt 0) {
        & $exePath @ExeArgs
      } else {
        & $exePath
      }
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    if ($exitCode -ne 0) {
      Write-Warning "Process failed with exit code $exitCode"
    }
    $global:LASTEXITCODE = $exitCode
  } catch {
    Write-Warning "Failed to start $exePath : $_"
    $global:LASTEXITCODE = 1
  }
}

Export-ModuleMember -Function Resolve-AppExecutablePath, Invoke-AppRun
