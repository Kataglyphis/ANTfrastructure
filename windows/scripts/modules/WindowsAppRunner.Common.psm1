# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

# WindowsAppRunner.Common - generic launcher core for per-profile "run the built
# app" scripts. The Windows twin of linux/scripts/lib/app-runner.sh.
#
# This module is project-agnostic: nothing project-specific is hard-coded here.
# A thin wrapper script imports it, passes its per-profile defaults (build root,
# executable name, configurations, working directory) and optionally an -EnvHook
# script block for per-profile environment tweaks (forcing a Vulkan ICD,
# clearing validation layers, ...), then exits with $LASTEXITCODE.
#
# Contract mirrored from app-runner.sh:
#   app_runner_find_executable -> Resolve-AppExecutablePath
#   app_runner_env_hook        -> -EnvHook script block
#   app_runner_main            -> Invoke-AppRun
#
# Invoke-AppRun deliberately does NOT return the exit code on the pipeline: the
# launched application writes to stdout, so a captured return value would
# collect its output. The exit code is left in $LASTEXITCODE (also on failure to
# start), which is what the wrapper scripts pass to `exit`.

Set-StrictMode -Version Latest

# Locates the built application executable inside a build tree. Shared by the
# run_{debug,profile,release} launcher scripts. Tries the flat
# build root, bin\, and per-configuration subdirectories (bin\<Config>\ and
# <Config>\ for single- vs multi-config generators) before falling back to a
# recursive search.
function Resolve-AppExecutablePath {
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    [string[]]$Configurations = @('Debug')
  )

  $candidateRelativePaths = @(
    $ExecutableName,
    (Join-Path 'bin' $ExecutableName)
  )
  foreach ($configuration in $Configurations) {
    $candidateRelativePaths += @(
      (Join-Path 'bin' (Join-Path $configuration $ExecutableName)),
      (Join-Path $configuration $ExecutableName)
    )
  }

  foreach ($relativePath in $candidateRelativePaths) {
    $candidate = Join-Path $BuildRoot $relativePath
    if (Test-Path $candidate) {
      return (Resolve-Path $candidate).Path
    }
  }

  $foundExecutable = Get-ChildItem -Path $BuildRoot -Filter $ExecutableName -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($foundExecutable) {
    return $foundExecutable.FullName
  }

  return $null
}

# Full pipeline: discover the executable, run the caller's environment hook,
# switch to the working directory and launch the application.
#
# Throws when the executable cannot be found (append build instructions via
# -NotFoundHint). Otherwise the process exit code is left in $LASTEXITCODE - 1
# when the process could not be started at all - and a warning is written for
# any non-zero code, matching app-runner.sh's behaviour.
function Invoke-AppRun {
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    [string[]]$Configurations = @('Debug'),
    # Defaults to the current location, the way app-runner.sh defaults to the
    # project root: the app usually resolves its assets relative to it.
    [string]$WorkingDirectory = (Get-Location).Path,
    [string[]]$ExeArgs = @(),
    # Per-profile environment setup, run after the executable was located and
    # before the working directory switch (e.g. VK_ICD_FILENAMES overrides,
    # clearing validation layers). $env: writes from here are process-wide.
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

    Set-Location -Path $WorkingDirectory
    if ($null -ne $ExeArgs -and $ExeArgs.Count -gt 0) {
      & $exePath @ExeArgs
    } else {
      & $exePath
    }

    $exitCode = $LASTEXITCODE
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
