#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# The only sanctioned host disk reclaim: allowlist only, report-only without -Apply; see docs/windows-builds.md § `Clear-DiskSpace.ps1`.

[CmdletBinding()]
param(
    # Actually delete. Without it this script only reports.
    [switch]$Apply,

    # Minimum-free target for the buildkit store lever, in GB.
    [int]$KeepGB = 100,

    # Younger temp entries are left alone: a build in flight owns its temp.
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

# The allowlist, root plus leaf pattern per rule, is the whole security boundary: adding a rule is a reviewed change.
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

    # A rule without a root is dropped, never resolved against the current directory.
    return @($rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Root) })
}

# The hard no
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
    # True when $Path is or contains a protected root; below one is fine, which keeps the TEMP rules legal.
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
    # A junction or symlink lets a recursive delete tunnel out of the allowlist; cannot tell = unsafe.
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
    # Resolves the given rule table into candidates, so tests can pass their own.
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

# Main
function Invoke-FreeDiskSpace {
    Say '== resolving the allowlist ==' 'Cyan'
    $plan = Get-ReclaimPlan -Rules (Get-ReclaimRules -TempAgeDays $TempOlderThanDays)

    # Fail closed: one target on a protected root means the resolution is wrong, so nothing runs.
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
