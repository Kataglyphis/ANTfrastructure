# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Project-agnostic git-state guards; they return data, and failing the build is the caller's job.

Set-StrictMode -Version Latest

function Invoke-GitIn {
  <#
    .SYNOPSIS
      Runs git in a directory and returns its stdout lines, swallowing stderr.
    .DESCRIPTION
      Pop-Location in a finally, as an unbalanced location stack would corrupt every later test assertion.
  #>
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string[]]$Arguments
  )

  Push-Location -LiteralPath $Path
  try {
    return @(& git @Arguments 2>$null)
  } finally {
    Pop-Location
  }
}

function Get-SubmodulePinDrift {
  <#
    .SYNOPSIS
      `git submodule status` lines marked '+' (checked out away from the recorded commit); empty means clean.
    .PARAMETER RepoRoot
      Superproject working tree to inspect.
    .PARAMETER Recurse
      Also inspect nested submodules; off because a top-level-only CI checkout has none.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [switch]$Recurse
  )

  $gitArgs = @('submodule', 'status')
  if ($Recurse) { $gitArgs += '--recursive' }

  $status = Invoke-GitIn -Path $RepoRoot -Arguments $gitArgs
  return @($status | Where-Object { $_ -match '^\+' })
}

function Get-SubmoduleStatusLine {
  <#
    .SYNOPSIS
      Every `git submodule status` line, so a caller can catch an empty result that makes the drift check vacuous.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot
  )

  return Invoke-GitIn -Path $RepoRoot -Arguments @('submodule', 'status')
}

function Get-TrackedIgnoredFile {
  <#
    .SYNOPSIS
      Returns tracked paths that .gitignore also excludes. Empty array means clean.
    .DESCRIPTION
      .gitignore does nothing once a path is indexed; fix a hit with `git rm --cached`, never by relaxing .gitignore.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot
  )

  return Invoke-GitIn -Path $RepoRoot -Arguments @('ls-files', '-i', '-c', '--exclude-standard')
}

function Get-TrackedGeneratedArtifact {
  <#
    .SYNOPSIS
      Tracked paths matching caller-supplied generated-output patterns; empty means clean.
    .DESCRIPTION
      Catches generated output that was committed and never ignored, which Get-TrackedIgnoredFile cannot see.
    .PARAMETER Pattern
      Git pathspecs to treat as generated output, e.g. 'Testing/', '**/__pycache__/'.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [Parameter(Mandatory)] [string[]]$Pattern
  )

  $gitArgs = @('ls-files', '--') + $Pattern
  return Invoke-GitIn -Path $RepoRoot -Arguments $gitArgs
}

function Test-SubmoduleCommitReachable {
  <#
    .SYNOPSIS
      Whether a fresh clone could restore a submodule's checked-out commit from its remote.
    .DESCRIPTION
      A shallow CI clone knows only origin/<default>, so it asks cheapest first: tracking refs, ls-remote heads, then a blobless fetch.
    .OUTPUTS
      A PSCustomObject: Head, Reachable, ContainingRef, Method.
  #>
  param(
    [Parameter(Mandatory)] [string]$SubmodulePath
  )

  $head = (Invoke-GitIn -Path $SubmodulePath -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($head)) {
    return [pscustomobject]@{ Head = $null; Reachable = $false; ContainingRef = @(); Method = 'no-head' }
  }
  $head = $head.Trim()

  $containing = @(Invoke-GitIn -Path $SubmodulePath -Arguments @('branch', '-r', '--contains', $head))
  if ($containing.Count -gt 0) {
    return [pscustomobject]@{ Head = $head; Reachable = $true; ContainingRef = $containing; Method = 'local-tracking' }
  }

  $tips = @(Invoke-GitIn -Path $SubmodulePath -Arguments @('ls-remote', '--heads', 'origin') |
      Where-Object { $_ -match ('^{0}\s' -f [regex]::Escape($head)) })
  if ($tips.Count -gt 0) {
    return [pscustomobject]@{ Head = $head; Reachable = $true; ContainingRef = $tips; Method = 'remote-tip' }
  }

  $isShallow = (Invoke-GitIn -Path $SubmodulePath -Arguments @('rev-parse', '--is-shallow-repository') |
      Select-Object -First 1)
  $fetchArgs = @('fetch', '--no-tags', '--filter=blob:none')
  if ("$isShallow".Trim() -eq 'true') { $fetchArgs += '--unshallow' }
  $fetchArgs += @('origin', '+refs/heads/*:refs/remotes/origin/*')
  Invoke-GitIn -Path $SubmodulePath -Arguments $fetchArgs | Out-Null

  $containing = @(Invoke-GitIn -Path $SubmodulePath -Arguments @('branch', '-r', '--contains', $head))
  return [pscustomobject]@{
    Head          = $head
    Reachable     = ($containing.Count -gt 0)
    ContainingRef = $containing
    Method        = 'fetched-heads'
  }
}

Export-ModuleMember -Function Get-SubmodulePinDrift, Get-SubmoduleStatusLine,
  Get-TrackedIgnoredFile, Get-TrackedGeneratedArtifact, Test-SubmoduleCommitReachable
