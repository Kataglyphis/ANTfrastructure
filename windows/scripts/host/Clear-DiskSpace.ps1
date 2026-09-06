#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# THE ONLY SANCTIONED WAY TO RECLAIM HOST DISK IN THIS REPO.
#
# 2026-08-21: an ad-hoc elevated "free some space" one-liner took the host's
# installed programs and user profile with it. Anything outside this allowlist
# is a human's decision, not a better one-liner.
#
# WHAT IT CLEANS (unnecessary, regenerable data only):
#   * unused container layers      - via the daemon's own GC, which knows what
#                                    is still referenced (the big lever, 100s of GB)
#   * dead container-store husks   - the *.bak-<stamp> trees Reset-ContainerStores.ps1
#                                    renames aside and nothing ever reads again
#   * temp files                   - user + Windows TEMP, AGE-GATED so nothing
#                                    in flight is touched
#   * build scratch                - repo out/ probe + log directories
#
# WHAT IT WILL NEVER TOUCH, AT ANY FLAG:
#   * installed programs, C:\Program Files, driver stores, package caches
#   * the user profile, AppData outside TEMP, .ssh/.vscode/scoop/.claude
#   * C:\Windows, C:\ProgramData outside the container stores, drive roots
#   * THE COMPILE CACHES - sccache/ccache/cargo/uv. They look like "cache" and
#     are the most expensive thing on the disk: AGENTS.md CACHE1 records a
#     prune that traded ~1.5-2h of cold LLVM rebuilds for a few GB. Never.
#
# Design rules, in priority order:
#   1. ALLOWLIST, NOT DENYLIST. A path is deletable only because a rule in
#      $script:ReclaimRules produced it. Unknown path = not touched.
#   2. DEFAULT DRY. Nothing is deleted without -Apply.
#   3. FAIL CLOSED. If any resolved target fails the protected-root check the
#      WHOLE run aborts - a target that lands there means the resolution logic
#      is wrong, so the rest of the plan cannot be trusted either.
#   4. NAMES ARE NOT TARGETS. A candidate containing a junction/symlink is
#      skipped: that is where a name stops predicting what a recursive delete
#      reaches.
#   5. DAEMON LEVERS FIRST. buildctl/docker GC hand back far more than file
#      deletion and understand what is still referenced.
#
# Usage:
#   pwsh -File windows\scripts\host\Clear-DiskSpace.ps1                 # report
#   pwsh -File windows\scripts\host\Clear-DiskSpace.ps1 -Apply          # do it
#   pwsh -File windows\scripts\host\Clear-DiskSpace.ps1 -Apply -TempOlderThanDays 14

[CmdletBinding()]
param(
    # Actually delete. Without it this script only reports.
    [switch]$Apply,

    # Minimum-free target for the buildkit store lever, in GB.
    [int]$KeepGB = 100,

    # Temp entries younger than this are left alone - a build in flight owns
    # its temp. 0 would mean "delete temp files this session is using".
    [ValidateRange(1, 3650)]
    [int]$TempOlderThanDays = 7,

    # Skip the "is a build running" refusal.
    [switch]$AllowDuringBuild,

    # Skip the daemon GC levers (container layers) and only handle files.
    [switch]$NoDaemonPrune
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say([string]$m, [string]$c = 'Gray') {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor $c
}

# =========================================================== the allowlist ===
# Each rule is a ROOT plus a LEAF pattern; nothing else under the root is ever
# a candidate. MinAgeDays gates live directories so work in flight survives.
# Adding a rule here is a reviewed change - it is the whole security boundary.
function Get-ReclaimRules {
    param([int]$TempAgeDays = 7)

    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

    $rules = @(
        # --- dead container-store husks (renamed aside, never read again) ---
        @{ Root = 'C:\ProgramData'; Leaf = 'containerd.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'containerd store husk' }
        @{ Root = 'C:\ProgramData'; Leaf = 'buildkitd.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'buildkitd store husk' }
        @{ Root = 'C:\ProgramData'; Leaf = 'Docker.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'docker store husk' }
        @{ Root = 'C:\ProgramData\kataglyphis'; Leaf = 'logs-*'; Kind = 'Any'; MinAgeDays = 7; What = 'rotated host-tool logs' }

        # --- temp: regenerable by definition, but AGE-GATED ---
        @{ Root = $env:TEMP; Leaf = '*'; Kind = 'Any'; MinAgeDays = $TempAgeDays; What = 'user temp' }
        @{ Root = 'C:\Windows\Temp'; Leaf = '*'; Kind = 'Any'; MinAgeDays = $TempAgeDays; What = 'Windows temp' }

        # --- build scratch inside the checkout ---
        @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'build-logs-*'; Kind = 'Any'; MinAgeDays = 3; What = 'archived build logs' }
        @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'probe-*'; Kind = 'Directory'; MinAgeDays = 3; What = 'diagnostic probe scratch' }
    )

    # A rule with no root (e.g. $env:TEMP unset under some service accounts)
    # is dropped rather than resolved against the current directory.
    return @($rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Root) })
}

# ============================================================= the hard NO ===
function Get-ProtectedRoots {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    return @(
        'C:\Program Files'
        'C:\Program Files (x86)'
        'C:\Windows'
        'C:\Users'
        'C:\ProgramData'
        'C:\ProgramData\Package Cache'
        $env:USERPROFILE
        $env:APPDATA
        $env:LOCALAPPDATA
        $repoRoot
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Test-Protected {
    # $true when deleting $Path would take a protected root with it - either
    # because it IS one, or because it CONTAINS one. A path BELOW a protected
    # root is fine when an allowlist rule produced it: that is how
    # C:\ProgramData\containerd.bak-* and the TEMP rules stay legal.
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 3) { return $true }          # any drive root, always

    foreach ($p in (Get-ProtectedRoots)) {
        $prot = [IO.Path]::GetFullPath($p).TrimEnd('\')
        if ($full -ieq $prot) { return $true }
        if ($prot.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-HasReparsePoint {
    # A junction or symlink inside a delete candidate is a tunnel OUT of the
    # allowlist: the name-based checks clear the candidate, and the recursive
    # delete then walks through the link into whatever it points at - which can
    # be a protected root. Cannot tell = treat as unsafe.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $self = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($self.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        if (-not $self.PSIsContainer) { return $false }
        $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
        return ($links.Count -gt 0)
    } catch { return $true }
}

function Get-EntrySizeGB {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [math]::Round($item.Length / 1GB, 3) }
        # No -FollowSymlink: sizing must not walk out of the subtree either.
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0.0 }
        return [math]::Round($bytes / 1GB, 3)
    } catch { return 0.0 }
}

function Get-ReclaimPlan {
    # Resolves the rules into concrete candidates. Pure enough to unit-test:
    # pass your own rule table and it resolves that instead.
    param([Parameter(Mandatory)][object[]]$Rules)

    $now = Get-Date
    $plan = @()
    foreach ($rule in $Rules) {
        if (-not (Test-Path -LiteralPath $rule.Root)) { continue }

        $params = @{ LiteralPath = $rule.Root; Filter = $rule.Leaf; Force = $true; ErrorAction = 'SilentlyContinue' }
        if ($rule.Kind -eq 'Directory') { $params['Directory'] = $true }
        $hits = @(Get-ChildItem @params)

        foreach ($h in $hits) {
            $ageDays = ($now - $h.LastWriteTime).TotalDays
            if ($ageDays -lt $rule.MinAgeDays) { continue }
            $plan += [pscustomobject]@{
                Path    = $h.FullName
                What    = $rule.What
                AgeDays = [math]::Round($ageDays, 1)
                SizeGB  = Get-EntrySizeGB $h.FullName
                Linked  = Test-HasReparsePoint $h.FullName
            }
        }
    }
    return @($plan)
}

# ==================================================================== main ===
function Invoke-FreeDiskSpace {
    Say '== resolving the allowlist ==' 'Cyan'
    $plan = Get-ReclaimPlan -Rules (Get-ReclaimRules -TempAgeDays $TempOlderThanDays)

    # Rule 3: fail closed. One bad target and nothing runs.
    foreach ($t in $plan) {
        if (Test-Protected $t.Path) {
            Say ('REFUSING THE WHOLE RUN: a resolved target lands on a protected root -> ' + $t.Path) 'Red'
            Say 'The allowlist resolution is wrong. Fix the rule; do not bypass this.' 'Red'
            return 2
        }
    }

    if ($plan.Count -eq 0) {
        Say 'no allow-listed candidates on this host - nothing for the file half to do.' 'Green'
    } else {
        $plan | Sort-Object SizeGB -Descending | Select-Object -First 40 | Format-Table -AutoSize @(
            @{ n = 'GB'; e = { $_.SizeGB } }
            @{ n = 'age(d)'; e = { $_.AgeDays } }
            @{ n = 'link?'; e = { if ($_.Linked) { 'SKIP' } else { '' } } }
            @{ n = 'path'; e = { $_.Path } }
            @{ n = 'what'; e = { $_.What } }
        ) | Out-String | Write-Host
        if ($plan.Count -gt 40) { Say ('... and {0} more (not truncated at delete time)' -f ($plan.Count - 40)) 'DarkGray' }

        foreach ($l in ($plan | Where-Object { $_.Linked })) {
            Say ('SKIP - contains a junction/symlink, a recursive delete could tunnel out of it: ' + $l.Path) 'Yellow'
        }
        $deletable = @($plan | Where-Object { -not $_.Linked })
        Say ('total allow-listed: {0} GB across {1} entries ({2} skipped as linked)' -f
            [math]::Round((($deletable | Measure-Object SizeGB -Sum).Sum), 2), $deletable.Count,
            ($plan.Count - $deletable.Count)) 'Yellow'
    }

    # ----------------------------------------------------- daemon levers ----
    if (-not $NoDaemonPrune) {
        Say '== unused container layers (the big lever) ==' 'Cyan'
        try {
            $df = & docker system df 2>&1
            if ($LASTEXITCODE -eq 0) { $df | ForEach-Object { Write-Host ('  ' + $_) } }
            else { Say '  docker reachable but `system df` failed - run it in an elevated shell for the layer report.' 'DarkGray' }
        } catch { Say '  docker not on PATH in this shell - no layer report (the prune levers below still apply).' 'DarkGray' }
        Say ('levers: buildctl prune --free-storage {0}  |  docker image prune -f' -f ($KeepGB * 1024))
        Say 'Both leave in-use and freshly-referenced records alone. See docs\windows-builds.md § Store GC.'
        Say 'NOT pruned: sccache/ccache/cargo/uv compile caches - hours of build time, a few GB of disk.' 'DarkGray'
    }

    # ------------------------------------------------------- the delete -----
    if (-not $Apply) {
        Write-Host ''
        Say 'REPORT ONLY. Re-run with -Apply to delete the entries listed above.' 'Green'
        Say 'Nothing outside that list will EVER be touched by this script.' 'Green'
        return 0
    }

    $buildLive = $false
    try { $buildLive = [bool](Get-Process -Name 'buildctl', 'docker' -ErrorAction SilentlyContinue) } catch { $buildLive = $false }
    if ($buildLive -and -not $AllowDuringBuild) {
        Say 'a build looks live (buildctl/docker running) - refusing the destructive half.' 'Red'
        Say 'Re-run with -AllowDuringBuild once the chain is idle.' 'Red'
        return 1
    }

    if (-not $NoDaemonPrune) {
        Say '== pruning unused container layers ==' 'Cyan'
        $freeTargetMB = $KeepGB * 1024
        try {
            & buildctl prune --free-storage $freeTargetMB
            Say ('  buildctl exit: ' + $LASTEXITCODE)
        } catch { Say ('  buildctl unavailable: ' + $_.Exception.Message) 'Yellow' }
        try {
            & docker image prune -f
            Say ('  docker image prune exit: ' + $LASTEXITCODE)
        } catch { Say ('  docker unavailable: ' + $_.Exception.Message) 'Yellow' }
    }

    Say '== deleting allow-listed entries ==' 'Cyan'
    $freed = 0.0
    foreach ($t in $plan) {
        if (Test-Protected $t.Path) { Say ('SKIP (protected): ' + $t.Path) 'Red'; continue }
        if ($t.Linked) { Say ('SKIP (junction/symlink inside): ' + $t.Path) 'Yellow'; continue }
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            $freed += $t.SizeGB
        } catch {
            Say ('locked or in use, left in place: {0}' -f $t.Path) 'DarkGray'
        }
    }

    Write-Host ''
    Say ('done - {0} GB returned from allow-listed entries.' -f [math]::Round($freed, 2)) 'Green'
    Get-PSDrive C, D -ErrorAction SilentlyContinue |
        ForEach-Object { Say ('{0}: {1} GB free' -f $_.Name, [int]($_.Free / 1GB)) }
    return 0
}

# Dot-sourced (by the test suite) = definitions only, nothing runs.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-FreeDiskSpace)
}
