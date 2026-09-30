# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Build-sweep harness only; which builds to run stays in the consuming script.

Set-StrictMode -Version Latest

function Invoke-SweepStep {
  <#
    .SYNOPSIS
      Runs one sweep step and returns a result instead of throwing, so one failure never aborts the rest.
    .PARAMETER Name
      Human-readable step name, used in the progress and summary output.
    .PARAMETER Action
      The build; a thrown exception or a non-zero $LASTEXITCODE both count as failure.
    .PARAMETER Skip
      Report the step as skipped without running it; not a failure.
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

  # Cleared so an earlier native command's code cannot be misread as this step's.
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
    # Never rethrown: one broken configuration must not cost the results after it.
    Write-Host "$Name threw: $_" -ForegroundColor Red
    return [pscustomobject]@{ Name = $Name; Ok = $false; Skipped = $false; ExitCode = 1; Message = "$_" }
  }
}

function Test-LinuxContainerSupport {
  <#
    .SYNOPSIS
      Returns $true when this host can actually run a Linux container.
    .DESCRIPTION
      Runs a trivial Linux image: every static check misjudges some Rancher/Docker Desktop mode.
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
      Bash command run with `set -e` prepended, so a failing line fails the step.
    .PARAMETER Engine
      docker (default) or nerdctl; an explicit -DockerExe still wins.
    .PARAMETER Platform
      Overrides linux/amd64; arm64 needs binfmt per VM boot (docs/rancher-desktop-linux-containers.md).
    .PARAMETER Name / -KeepContainer
      Name the container and keep it after exit, so a failed run can be inspected.
    .PARAMETER NamedVolumes
      'volume-name:/mount/path' entries, chowned to uid 1001; long --mount form, as Windows nerdctl binds `-v name:/path`.
    .PARAMETER EnvFile
      Passed through as --env-file.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [Parameter(Mandatory)] [string]$Image,
    [Parameter(Mandatory)] [string]$Command,
    [string]$WorkDir = '/workspace',
    [string]$DockerExe = 'docker',
    [ValidateSet('docker', 'nerdctl')] [string]$Engine = 'docker',
    [string]$Platform = 'linux/amd64',
    [string]$Name = '',
    [switch]$KeepContainer,
    [string[]]$NamedVolumes = @(),
    [string]$EnvFile = ''
  )

  $exe = if ($PSBoundParameters.ContainsKey('DockerExe')) { $DockerExe } else { $Engine }

  foreach ($spec in $NamedVolumes) {
    $volume = $spec.Split(':')[0]
    # Both steps are safe to repeat, so no exists-check to get wrong.
    & $exe volume create $volume | Out-Null
    & $exe run --rm --user root --mount "type=volume,source=$volume,target=/v" `
      alpine:3.20 chown -R 1001:1001 /v | Out-Null
  }

  $runArgs = @('run')
  if (-not $KeepContainer) { $runArgs += '--rm' }
  if ($Name) { $runArgs += @('--name', $Name) }
  if ($Platform) { $runArgs += @('--platform', $Platform) }
  if ($EnvFile) { $runArgs += @('--env-file', $EnvFile) }
  $runArgs += @('-v', "${RepoRoot}:${WorkDir}", '-w', $WorkDir)
  foreach ($spec in $NamedVolumes) {
    $parts = $spec.Split(':')
    $runArgs += @('--mount', "type=volume,source=$($parts[0]),target=$($parts[1])")
  }
  $runArgs += @($Image, 'bash', '-c', "set -e`n$Command")

  & $exe @runArgs
}

function Write-SweepSummary {
  <#
    .SYNOPSIS
      Prints the per-step summary and returns the aggregate exit code.
    .DESCRIPTION
      The first non-zero exit code, so the caller exits with a real build's code; 0 when every run step passed.
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

  # Bound first: under StrictMode .ExitCode on an empty Select-Object throws, the all-thrown case.
  $firstCoded = @($failed | Where-Object { $_.ExitCode -ne 0 }) | Select-Object -First 1
  $aggregate = if ($firstCoded) { $firstCoded.ExitCode } else { 1 }
  Write-Host "=== $($failed.Count) BUILD(S) FAILED (aggregate exit code $aggregate) ===" -ForegroundColor Red
  return $aggregate
}

Export-ModuleMember -Function Invoke-SweepStep, Test-LinuxContainerSupport,
  Invoke-InLinuxContainerBuild, Write-SweepSummary
