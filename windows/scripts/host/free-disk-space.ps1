#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# THE ONLY SANCTIONED WAY TO RECLAIM HOST DISK IN THIS REPO.
#
# 2026-08-21: an ad-hoc "free some space" command, written on the spot and
# pasted into an elevated shell, went past the container stores and took the
# host's installed programs and user profile with it - editor, VCS, GPU driver
# stack and the container runtime all had to be reinstalled by hand. The
# lesson is not "write a more careful one-liner next time"; it is that disk
# reclaim on this host must be a REVIEWED, ALLOW-LISTED, DEFAULT-DRY script,
# and that anything outside its allowlist is a human's decision, not an
# agent's.
#
# Design rules, in priority order:
#   1. ALLOWLIST, NOT DENYLIST. A path is deletable only because it appears in
#      $script:Reclaimable below. Unknown path = not touched, no exceptions.
#   2. DEFAULT DRY. Nothing is deleted without -Apply. The default run is a
#      report you can read before anything happens.
#   3. FAIL CLOSED. If any resolved target fails the protected-root check, the
#      WHOLE run aborts - it does not "skip the bad one and continue", because
#      a target that lands on a protected root means the resolution logic is
#      wrong, and the rest of the plan cannot be trusted either.
#   4. DAEMON LEVERS FIRST. buildctl/docker GC hand back far more than file
#      deletion does, and they understand what is still referenced. Filesystem
#      deletes here are limited to the DEAD husks that reset-container-stores.ps1
#      renames aside (*.bak-<stamp>) plus build logs.
#   5. NEVER: installed programs, the user profile, AppData, C:\Windows,
#      C:\ProgramData outside the container stores, registry, services,
#      driver packages, package caches. Not with a flag, not with -Force.
#      Freeing that space is a reinstall, not a cleanup.
#
# Usage:
#   pwsh -File windows\scripts\host\free-disk-space.ps1              # report only
#   pwsh -File windows\scripts\host\free-disk-space.ps1 -Apply       # do it
#   pwsh -File windows\scripts\host\free-disk-space.ps1 -Apply -KeepGB 150
#
# Mid-build safety: refuses to run the destructive half while a build is live
# unless -AllowDuringBuild is passed (buildctl prune --free-storage is the
# documented mid-run lever and stays available in report mode).

[CmdletBinding()]
param(
    # Actually delete. Without it this script only reports.
    [switch]$Apply,

    # Minimum-free target for the buildkit store lever, in GB.
    [int]$KeepGB = 100,

    # Skip the "is a build running" refusal.
    [switch]$AllowDuringBuild,

    # Skip the daemon GC levers and only report/remove dead husks.
    [switch]$NoDaemonPrune
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say([string]$m, [string]$c = 'Gray') {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor $c
}

# --------------------------------------------------------------- allowlist ---
# Every deletable path must be produced by one of these rules. Each rule is a
# ROOT plus a LEAF PATTERN; nothing else under the root is ever a candidate.
# Adding a rule here is a reviewed change - it is the whole security boundary.
$script:Reclaimable = @(
    @{ Root = 'C:\ProgramData'; Leaf = 'containerd.bak-*'; What = 'containerd store husk (renamed aside by reset-container-stores.ps1)' }
    @{ Root = 'C:\ProgramData'; Leaf = 'buildkitd.bak-*'; What = 'buildkitd store husk' }
    @{ Root = 'C:\ProgramData'; Leaf = 'Docker.bak-*'; What = 'docker store husk' }
    @{ Root = 'C:\ProgramData\kataglyphis'; Leaf = 'logs-*'; What = 'rotated host-tool logs' }
    @{ Root = 'C:\temp\scripts'; Leaf = 'stale-*'; What = 'stale mounted script closures' }
)

# Repo-relative rules, resolved against the checkout this script lives in.
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$script:ReclaimableRepo = @(
    @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'build-logs-*'; What = 'archived build logs' }
    @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'probe-*'; What = 'diagnostic probe scratch' }
)

# ------------------------------------------------------------ the hard NO ---
# A resolved target matching any of these aborts the run. This is the belt to
# the allowlist's braces: the allowlist decides what CAN be deleted, this
# decides what can never be, even if a rule above is later mis-edited.
$script:Protected = @(
    'C:\Program Files'
    'C:\Program Files (x86)'
    'C:\Windows'
    'C:\Users'
    'C:\ProgramData\Package Cache'
    'C:\ProgramData\Microsoft'
    'C:\ProgramData\chocolatey'
    $env:USERPROFILE
    $env:APPDATA
    $env:LOCALAPPDATA
    $repoRoot                       # the checkout itself, only its out/ subtrees
)

function Test-Protected {
    # $true when deleting $Path would take a protected root with it - either
    # because it IS one, or because it CONTAINS one. The second half is the
    # one that matters: C:\ and C:\Users are not in the allowlist, but a
    # mis-resolved rule that produced them would swallow every protected root
    # underneath. A path BELOW a protected root is fine when an allowlist rule
    # produced it (that is how C:\ProgramData\containerd.bak-* stays legal).
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')

    # Any drive root, always.
    if ($full.Length -le 3) { return $true }

    foreach ($p in $script:Protected) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $prot = [IO.Path]::GetFullPath($p).TrimEnd('\')
        if ($full -ieq $prot) { return $true }
        if ($prot.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-HasReparsePoint {
    # A junction or symlink inside a delete candidate is a tunnel OUT of the
    # allowlist: the path check clears the candidate, and the recursive delete
    # then walks through the link into whatever it points at - which can be a
    # protected root. Every path check in this script reasons about NAMES, and
    # a reparse point is precisely where a name stops predicting the target.
    # So: a candidate containing one is not deleted, loudly.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
        return ($links.Count -gt 0)
    } catch { return $true }   # cannot tell = treat as unsafe
}

function Get-DirSizeGB {
    param([Parameter(Mandatory)][string]$Path)
    try {
        # No -FollowSymlink: sizing must not walk out of the subtree either.
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0.0 }
        return [math]::Round($bytes / 1GB, 2)
    } catch { return 0.0 }
}

# ------------------------------------------------------------------ plan ----
Say '== resolving the allowlist ==' 'Cyan'
$plan = @()
foreach ($rule in ($script:Reclaimable + $script:ReclaimableRepo)) {
    if (-not (Test-Path -LiteralPath $rule.Root)) { continue }
    $hits = @(Get-ChildItem -LiteralPath $rule.Root -Filter $rule.Leaf -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($h in $hits) {
        $plan += [pscustomobject]@{
            Path   = $h.FullName
            What   = $rule.What
            SizeGB = Get-DirSizeGB $h.FullName
            Linked = Test-HasReparsePoint $h.FullName
        }
    }
}

# Rule 3: fail closed. One bad target and nothing runs.
foreach ($t in $plan) {
    if (Test-Protected $t.Path) {
        Say ("REFUSING THE WHOLE RUN: a resolved target lands on a protected root -> " + $t.Path) 'Red'
        Say 'This means the allowlist resolution is wrong. Fix the rule, do not bypass this.' 'Red'
        exit 2
    }
}

if ($plan.Count -eq 0) {
    Say 'no allow-listed husks on this host - nothing for the filesystem half to do.' 'Green'
} else {
    $plan | Sort-Object SizeGB -Descending | Format-Table -AutoSize @(
        @{ n = 'GB'; e = { $_.SizeGB } }
        @{ n = 'link?'; e = { if ($_.Linked) { 'SKIP' } else { '' } } }
        @{ n = 'path'; e = { $_.Path } }
        @{ n = 'what'; e = { $_.What } }
    ) | Out-String | Write-Host

    foreach ($l in ($plan | Where-Object { $_.Linked })) {
        Say ('SKIP - contains a junction/symlink, a recursive delete could tunnel out of it: ' + $l.Path) 'Yellow'
    }
    Say ('total allow-listed: {0} GB in {1} directories' -f (($plan | Measure-Object SizeGB -Sum).Sum, $plan.Count)) 'Yellow'
}

# --------------------------------------------------------- daemon levers ----
$buildLive = $false
try {
    $buildLive = [bool](Get-Process -Name 'buildctl', 'docker' -ErrorAction SilentlyContinue)
} catch { $buildLive = $false }

if (-not $NoDaemonPrune) {
    Say '== daemon-level reclaim (the big, safe lever) ==' 'Cyan'
    Say ("buildkit store: prune down to a {0} GB free-space target" -f $KeepGB)
    Say '  buildctl prune --free-storage <MB>   (minimum-FREE target, not an amount)'
    Say '  docker image prune -f                (classic lane, dangling only)'
    Say 'Both leave in-use and freshly-referenced records alone. See docs\windows-builds.md § Store GC.'
    if ($Apply) {
        $freeTargetMB = $KeepGB * 1024
        Say ("running: buildctl prune --free-storage {0}" -f $freeTargetMB) 'Yellow'
        & buildctl prune --free-storage $freeTargetMB
        Say ('  buildctl exit: ' + $LASTEXITCODE)
    }
}

# ------------------------------------------------------------- the delete ---
if (-not $Apply) {
    Write-Host ''
    Say 'REPORT ONLY. Re-run with -Apply to delete the listed husks.' 'Green'
    Say 'Nothing outside the list above will EVER be touched by this script.' 'Green'
    exit 0
}

if ($buildLive -and -not $AllowDuringBuild) {
    Say 'a build looks live (buildctl/docker running) - refusing the destructive half.' 'Red'
    Say 'Re-run with -AllowDuringBuild once the chain is idle, or use the daemon lever alone.' 'Red'
    exit 1
}

Say '== deleting allow-listed husks ==' 'Cyan'
$freed = 0.0
foreach ($t in $plan) {
    if (Test-Protected $t.Path) { Say ('SKIP (protected): ' + $t.Path) 'Red'; continue }
    if ($t.Linked) { Say ('SKIP (contains a junction/symlink): ' + $t.Path) 'Yellow'; continue }
    try {
        Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
        $freed += $t.SizeGB
        Say ('freed {0} GB - {1}' -f $t.SizeGB, $t.Path) 'Green'
    } catch {
        Say ('locked or in use, left in place: {0} ({1})' -f $t.Path, $_.Exception.Message) 'Yellow'
    }
}

Write-Host ''
Say ('done - {0} GB returned from allow-listed husks.' -f [math]::Round($freed, 2)) 'Green'
Get-PSDrive C, D -ErrorAction SilentlyContinue |
    ForEach-Object { Say ('{0}: {1} GB free' -f $_.Name, [int]($_.Free / 1GB)) }
