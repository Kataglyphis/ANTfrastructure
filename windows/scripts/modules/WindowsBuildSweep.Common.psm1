# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# WindowsBuildSweep.Common - run several builds in one session and report one
# aggregate result.
#
# Lifted out of a consumer repo (BeschleunigerBallett,
# scripts/Test-AllConfigs.ps1) on 2026-08-07. Everything here is the harness;
# WHICH builds to run - configuration names, CMake presets, image tags, build
# directories - stays in the consuming script, which is the only part that knows
# about a particular project.
#
# The two things every such sweep re-implements and gets subtly wrong:
#
#   1. Failure aggregation. A step can fail by THROWING or by leaving a non-zero
#      $LASTEXITCODE, and a sweep that only checks one of them reports green over
#      a broken build. Invoke-SweepStep treats both as failure and never lets one
#      failing step abort the remaining ones - the point of a sweep is to learn
#      about every configuration in one pass, not just the first broken one.
#
#   2. "Can this host run Linux containers?" Answering it by inspecting the
#      Docker context, the OS, or whether `docker` is on PATH all give wrong
#      answers on at least one of Rancher Desktop / Docker Desktop in Linux mode
#      / Docker Desktop in Windows mode. Actually running a trivial Linux
#      container is the only check that cannot lie.

Set-StrictMode -Version Latest

function Invoke-SweepStep {
  <#
    .SYNOPSIS
      Runs one step of a build sweep and returns a structured result instead of
      throwing.
    .PARAMETER Name
      Human-readable step name, used in the progress and summary output.
    .PARAMETER Action
      Scriptblock performing the build. Failure is either a thrown exception or
      a non-zero $LASTEXITCODE left by a native command.
    .PARAMETER Skip
      Report the step as skipped without running it. A skipped step is NOT a
      failure and does not contribute to the aggregate exit code.
    .PARAMETER SkipReason
      Shown next to a skipped step so the log says why coverage is missing.
    .OUTPUTS
      PSCustomObject: Name, Ok, Skipped, ExitCode, Message.
  #>
  param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [scriptblock]$Action,
    [switch]$Skip,
    [string]$SkipReason = ''
  )

  Write-Host ''
  Write-Host "=== $Name ===" -ForegroundColor Cyan

  if ($Skip) {
    Write-Host "Skipped. $SkipReason" -ForegroundColor Yellow
    return [pscustomobject]@{ Name = $Name; Ok = $true; Skipped = $true; ExitCode = 0; Message = $SkipReason }
  }

  # Cleared so a stale code from an earlier native command in this session
  # cannot be misread as this step's result.
  $global:LASTEXITCODE = 0
  try {
    & $Action
    $code = if ($null -eq $global:LASTEXITCODE) { 0 } else { $global:LASTEXITCODE }

    if ($code -ne 0) {
      Write-Host "$Name FAILED (exit code $code)." -ForegroundColor Red
      return [pscustomobject]@{ Name = $Name; Ok = $false; Skipped = $false; ExitCode = $code; Message = "exit code $code" }
    }

    Write-Host "$Name PASSED." -ForegroundColor Green
    return [pscustomobject]@{ Name = $Name; Ok = $true; Skipped = $false; ExitCode = 0; Message = '' }
  } catch {
    # Caught, never rethrown: one broken configuration must not cost the sweep
    # the results of every configuration after it.
    Write-Host "$Name threw: $_" -ForegroundColor Red
    return [pscustomobject]@{ Name = $Name; Ok = $false; Skipped = $false; ExitCode = 1; Message = "$_" }
  }
}

function Test-LinuxContainerSupport {
  <#
    .SYNOPSIS
      Returns $true when this host can actually run a Linux container.
    .DESCRIPTION
      Runs a trivial Linux image and checks it printed what it was told to.
      Works with Rancher Desktop, Docker Desktop in Linux mode, or any docker
      that can run linux/amd64 - and correctly says $false for Docker Desktop
      switched to Windows containers, which every static check gets wrong.
    .PARAMETER Image
      Probe image. Must be tiny and must exist for linux/amd64.
  #>
  param(
    [string]$Image = 'alpine',
    [string]$DockerExe = 'docker'
  )

  try {
    $token = 'linux-ok'
    $output = & $DockerExe run --rm --platform linux/amd64 $Image echo $token 2>$null
    return (@($output) -contains $token)
  } catch {
    return $false
  }
}

function Invoke-InLinuxContainerBuild {
  <#
    .SYNOPSIS
      Runs a bash command inside a Linux container with the repo bind-mounted.
    .PARAMETER RepoRoot
      Host path bind-mounted at -WorkDir.
    .PARAMETER Image
      Fully qualified image reference to run.
    .PARAMETER Command
      Bash command executed inside the container. Run with `set -e` prepended so
      a failing line fails the step instead of being swallowed by the last
      command's status.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [Parameter(Mandatory)] [string]$Image,
    [Parameter(Mandatory)] [string]$Command,
    [string]$WorkDir = '/workspace',
    [string]$DockerExe = 'docker'
  )

  & $DockerExe run --rm `
    --platform linux/amd64 `
    -v "${RepoRoot}:${WorkDir}" `
    -w $WorkDir `
    $Image `
    bash -c "set -e`n$Command"
}

function Write-SweepSummary {
  <#
    .SYNOPSIS
      Prints the per-step summary and returns the aggregate exit code.
    .DESCRIPTION
      Returns the FIRST non-zero exit code seen, so the caller's `exit` carries a
      real build's code rather than a synthesised 1. Zero means every non-skipped
      step passed.
  #>
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Result
  )

  $failed = @($Result | Where-Object { -not $_.Ok })
  $skipped = @($Result | Where-Object { $_.Skipped })

  Write-Host ''
  Write-Host ('=' * 60)
  foreach ($r in $Result) {
    $label = if ($r.Skipped) { 'SKIP' } elseif ($r.Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($r.Skipped) { 'Yellow' } elseif ($r.Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}{2}" -f $label, $r.Name, $(if ($r.Message) { " - $($r.Message)" } else { '' })) -ForegroundColor $color
  }
  Write-Host ('=' * 60)

  if ($failed.Count -eq 0) {
    $note = if ($skipped.Count -gt 0) { " ($($skipped.Count) skipped)" } else { '' }
    Write-Host "=== ALL BUILDS PASSED$note ===" -ForegroundColor Green
    return 0
  }

  # Bound to a variable first: under Set-StrictMode -Version Latest, reading
  # .ExitCode straight off a Select-Object that matched nothing throws
  # "property cannot be found on this object" - which is exactly the case where
  # every failure was a thrown exception rather than a native exit code.
  $firstCoded = @($failed | Where-Object { $_.ExitCode -ne 0 }) | Select-Object -First 1
  $aggregate = if ($firstCoded) { $firstCoded.ExitCode } else { 1 }
  Write-Host "=== $($failed.Count) BUILD(S) FAILED (aggregate exit code $aggregate) ===" -ForegroundColor Red
  return $aggregate
}

Export-ModuleMember -Function Invoke-SweepStep, Test-LinuxContainerSupport,
  Invoke-InLinuxContainerBuild, Write-SweepSummary
