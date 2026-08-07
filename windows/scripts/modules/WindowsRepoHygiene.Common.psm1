# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# WindowsRepoHygiene.Common - repository-state guards that every repo wants and
# none of which know anything about a particular project.
#
# Lifted out of a consumer repo (Kataglyphis-BeschleunigerBallett,
# Scripts/Windows/tests) on 2026-08-07: both checks were written there as
# standalone Pester suites with the repo root hard-coded three levels up from
# $PSScriptRoot, which is the only project-specific thing about them.
#
# What each guard is for:
#
#   Get-SubmodulePinDrift - a submodule checked out somewhere other than the
#     commit the superproject records. `git submodule status` marks those with
#     a leading '+', which is easy to miss in a wall of output and means the
#     build is compiling something other than what is committed. ('-' is
#     "not initialised" - a different and usually harmless state, deliberately
#     not reported here.)
#
#   Get-TrackedIgnoredFile - a file that is BOTH tracked and gitignored, i.e. a
#     generated artifact that got committed before the ignore rule existed.
#     .gitignore only stops NEW files from being added; it does nothing once a
#     path is in the index, so the repo keeps serving a stale build output
#     forever. (Observed in the consumer: 21 files under a gitignored docs/build/
#     plus a stray __pycache__/*.pyc, served two months stale.)
#
#   Test-SubmoduleCommitReachable - whether a submodule's pinned commit can be
#     restored by a fresh clone. A pin that is on no remote branch works only on
#     the machine that made it.
#
# All three shell out to git and return data; failing the build is the caller's
# job (see WindowsRepoHygiene.Common.Tests.ps1 and the consumer suites).

Set-StrictMode -Version Latest

function Invoke-GitIn {
  <#
    .SYNOPSIS
      Runs git in a directory and returns its stdout lines, swallowing stderr.
    .DESCRIPTION
      Push-Location/Pop-Location in a finally so a throwing git cannot leave the
      caller's location stack unbalanced - these functions run inside test
      harnesses where that would corrupt every later assertion.
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
      Returns the `git submodule status` lines for submodules checked out away
      from their recorded commit. Empty array means clean.
    .PARAMETER RepoRoot
      Superproject working tree to inspect.
    .PARAMETER Recurse
      Also inspect nested submodules. Off by default: a consumer that checks out
      with `submodules: true` (top-level only, the cheap CI default) has no
      nested working trees, and recursing would report them all as missing.
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
      Returns every `git submodule status` line, so a caller can assert the
      command produced output at all (a silent empty result usually means the
      checkout omitted submodules, which would make the drift check vacuous).
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
      `git ls-files -i -c --exclude-standard` is the whole check: -i restricts to
      ignored paths, -c to cached (tracked) ones. Anything it prints was committed
      despite an ignore rule, and the fix is `git rm --cached <path>` - never
      relaxing .gitignore.
  #>
  param(
    [Parameter(Mandatory)] [string]$RepoRoot
  )

  return Invoke-GitIn -Path $RepoRoot -Arguments @('ls-files', '-i', '-c', '--exclude-standard')
}

function Get-TrackedGeneratedArtifact {
  <#
    .SYNOPSIS
      Returns tracked paths matching caller-supplied generated-output patterns.
      Empty array means clean.
    .DESCRIPTION
      The blind spot Get-TrackedIgnoredFile leaves behind. That check finds files
      that are tracked AND gitignored - but a generated artifact committed before
      anyone thought to ignore the path is tracked and NOT ignored, so it is
      invisible to both checks.

      Observed in a consumer 2026-08-07: `Testing/TAG`,
      `Testing/20250602-0529/Test.xml` and `Testing/Temporary/CTestCostData.txt`
      (CTest run output) had been committed and the path was never added to
      .gitignore, so the tracked-and-ignored guard reported clean for months.

      This takes the patterns explicitly rather than guessing: what counts as
      "generated" is a property of the project's build, not something a shared
      module can know. Patterns are git pathspecs, e.g. 'Testing/',
      'docs/build/', '**/__pycache__/'.
    .PARAMETER Pattern
      Git pathspecs to treat as generated output.
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
      Tells whether a submodule's checked-out commit is reachable from its remote,
      i.e. whether a fresh clone could restore this pin.
    .DESCRIPTION
      `git branch -r --contains` alone answers this ONLY in a full clone.
      actions/checkout defaults to fetch-depth 1 and hands that depth to
      `git submodule update`, so on a runner the submodule is a shallow,
      single-branch clone whose only remote-tracking ref is origin/<default>.
      A pin that lives on a release branch then looks unreachable and the gate
      fails for weeks over a perfectly restorable commit. (Reproduced in the
      consumer 2026-08-05 with `git clone --depth 1` + `git submodule update
      --init --depth 1`: `git branch -r` lists origin/main only.)

      So ask progressively, cheapest first, and only report unreachable when the
      remote itself cannot account for the commit:
        1. local remote-tracking branches - free, conclusive in a full clone
        2. `git ls-remote --heads` - one network round-trip, no objects;
           conclusive whenever the pin sits at a branch TIP (the normal case
           for a release pin)
        3. fetch every remote head commit-only (--filter=blob:none, plus
           --unshallow when shallow) and re-ask (1) - the mid-branch case
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
