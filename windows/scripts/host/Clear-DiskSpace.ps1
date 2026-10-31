#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
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
    [switch]$NoDaemonPrune,

    # Only renamed container stores; daemon GC is always disabled.
    [switch]$StoreHusksOnly,

    # Restrict this run to explicitly selected Stevedore image tags and/or regular BuildKit cache.
    [switch]$StevedoreOnly,
    [string[]]$ImageTag = @(),
    [string[]]$ExpectedImageId = @(),
    [switch]$RegularCache,
    [string]$StevedoreNamespace = 'buildkit',
    [string]$BuildkitAddress = 'npipe:////./pipe/buildkitd',
    [string]$ContainerdAddress = '\\.\pipe\containerd-containerd'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:cleanupBoundParameters = @($PSBoundParameters.Keys)

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1')


# The allowlist, root plus leaf pattern per rule, is the whole security boundary: adding a rule is a reviewed change.
function Get-ReclaimRules {
    param([int]$TempAgeDays = 7, [switch]$StoreHusksOnly)

    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

    $rules = @(
        # --- dead container-store husks (renamed aside, never read again) ---
        @{ Root = 'C:\ProgramData'; Leaf = 'containerd.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'containerd store husk' }
        @{ Root = 'C:\ProgramData'; Leaf = 'buildkitd.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'buildkitd store husk' }
        @{ Root = 'C:\ProgramData'; Leaf = 'Docker.bak-*'; Kind = 'Directory'; MinAgeDays = 0; What = 'docker store husk' }
    )
    if (-not $StoreHusksOnly) {
        $rules += @(
        @{ Root = 'C:\ProgramData\kataglyphis'; Leaf = 'logs-*'; Kind = 'Any'; MinAgeDays = 7; What = 'rotated host-tool logs' }

        # --- temp: regenerable by definition, but AGE-GATED ---
        @{ Root = $env:TEMP; Leaf = '*'; Kind = 'Any'; MinAgeDays = $TempAgeDays; What = 'user temp' }
        @{ Root = 'C:\Windows\Temp'; Leaf = '*'; Kind = 'Any'; MinAgeDays = $TempAgeDays; What = 'Windows temp' }

        # --- build scratch inside the checkout ---
        @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'build-logs-*'; Kind = 'Any'; MinAgeDays = 3; What = 'archived build logs' }
        @{ Root = (Join-Path $repoRoot 'out'); Leaf = 'probe-*'; Kind = 'Directory'; MinAgeDays = 3; What = 'diagnostic probe scratch' }
        )
    }

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
        $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
        return ($links.Count -gt 0)
    } catch { return $true }
}

function Get-EntrySizeGB {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [math]::Round($item.Length / 1GB, 3) }
        $bytes = (Get-HostMaintenanceTreeStats -Root $Path).Bytes
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

function Write-ReclaimPlanSummary {
    param([AllowEmptyCollection()][object[]]$Plan)
    if ($plan.Count -eq 0) {
        Write-HostMaintenanceMessage 'no allow-listed candidates on this host - nothing for the file half to do.' 'Green'
    } else {
        $plan | Sort-Object SizeGB -Descending | Select-Object -First 40 | Format-Table -AutoSize @(
            @{ n = 'GB'; e = { $_.SizeGB } }
            @{ n = 'age(d)'; e = { $_.AgeDays } }
            @{ n = 'link?'; e = { if ($_.Linked) { 'SKIP' } else { '' } } }
            @{ n = 'path'; e = { $_.Path } }
            @{ n = 'what'; e = { $_.What } }
        ) | Out-String | Write-Host
        if ($plan.Count -gt 40) { Write-HostMaintenanceMessage ('... and {0} more (not truncated at delete time)' -f ($plan.Count - 40)) 'DarkGray' }

        foreach ($l in ($plan | Where-Object { $_.Linked })) {
            Write-HostMaintenanceMessage ('SKIP - junction/symlink or unreadable tree: ' + $l.Path) 'Yellow'
        }
        $deletable = @($plan | Where-Object { -not $_.Linked })
        Write-HostMaintenanceMessage ('total allow-listed: {0} GB across {1} entries ({2} skipped as unsafe)' -f
            [math]::Round((($deletable | ForEach-Object { $_.SizeGB } | Measure-Object -Sum).Sum), 2), $deletable.Count,
            ($plan.Count - $deletable.Count)) 'Yellow'
    }

}

function Write-DaemonPruneAdvice {
    param([bool]$DaemonPrune, [int]$KeepGB)
    if ($daemonPrune) {
        Write-HostMaintenanceMessage '== unused container layers (the big lever) ==' 'Cyan'
        try {
            $df = & docker system df 2>&1
            if ($LASTEXITCODE -eq 0) { $df | ForEach-Object { Write-Host ('  ' + $_) } }
            else { Write-HostMaintenanceMessage '  docker reachable but `system df` failed - run it in an elevated shell for the layer report.' 'DarkGray' }
        } catch { Write-HostMaintenanceMessage '  docker not on PATH in this shell - no layer report (the prune levers below still apply).' 'DarkGray' }
        Write-HostMaintenanceMessage ('levers: buildctl prune --free-storage {0}  |  docker image prune -f' -f ($KeepGB * 1024))
        Write-HostMaintenanceMessage 'Cache hits do not refresh lastUsedAt, so a size or age prune can evict a warm chain''s base. See docs\failure-modes.md.'
        Write-HostMaintenanceMessage 'The file allowlist excludes compile caches; daemon GC is separate. Use -StoreHusksOnly to disable it.' 'DarkGray'
    }

}

function Invoke-ReclaimDaemonPrune {
    param([bool]$DaemonPrune, [int]$KeepGB)
    if ($daemonPrune) {
        Write-HostMaintenanceMessage '== pruning unused container layers ==' 'Cyan'
        $freeTargetMB = $KeepGB * 1024
        try {
            & buildctl prune --free-storage $freeTargetMB
            Write-HostMaintenanceMessage ('  buildctl exit: ' + $LASTEXITCODE)
        } catch { Write-HostMaintenanceMessage ('  buildctl unavailable: ' + $_.Exception.Message) 'Yellow' }
        try {
            & docker image prune -f
            Write-HostMaintenanceMessage ('  docker image prune exit: ' + $LASTEXITCODE)
        } catch { Write-HostMaintenanceMessage ('  docker unavailable: ' + $_.Exception.Message) 'Yellow' }
    }

}

# Main
function Get-StevedoreTargets {
    param([string[]]$Tags, [string[]]$Ids)
    if ($Tags.Count -ne $Ids.Count) { throw 'Each image tag needs one expected image ID.' }
    $seen = @{}
    for ($i = 0; $i -lt $Tags.Count; $i++) {
        # Explicit tagged references only: no globs, digest selectors, options or untagged names.
        if ($Tags[$i] -cnotmatch '^[a-z0-9][a-z0-9._:/-]*:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$') {
            throw "Invalid explicit image tag: $($Tags[$i])"
        }
        if ($Ids[$i] -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Expected image ID must be a full lowercase sha256 ID.' }
        if ($seen.ContainsKey($Tags[$i])) { throw "Duplicate image tag: $($Tags[$i])" }
        $seen[$Tags[$i]] = $true
        [pscustomobject]@{ Tag = $Tags[$i]; Id = $Ids[$i] }
    }
}

function Invoke-StevedoreRead {
    param($Store, [string[]]$Arguments, [string]$FailureMessage)
    $output = @(& $Store.Tool --address $Store.Address --namespace $Store.Namespace @Arguments)
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
    return $output
}

function ConvertFrom-StevedoreJson {
    param([string[]]$Raw, [string]$Context)
    try { $Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid $Context response." }
}

function Assert-BuildkitIdle {
    param([string]$Buildctl, [string]$Address)
    $raw = @(& $Buildctl --addr $Address du --format '{{json .}}')
    if ($LASTEXITCODE -ne 0 -or -not $raw.Count) { throw 'Cannot inspect BuildKit usage.' }
    $records = @(ConvertFrom-StevedoreJson -Raw $raw -Context 'BuildKit usage')
    foreach ($record in $records) {
        if ($null -eq $record.PSObject.Properties['inUse'] -or $record.inUse -isnot [bool]) {
            throw 'BuildKit usage response has no valid inUse value.'
        }
        if ($record.inUse) { throw 'BuildKit has in-use records; refusing cleanup.' }
    }
}

function Assert-StevedoreIdle {
    param([string]$Buildctl, [string]$Address, $Store)
    if (@(Get-Process -Name docker,nerdctl,buildctl -ErrorAction SilentlyContinue).Count) {
        throw 'A container client is running; refusing Stevedore cleanup.'
    }
    $running = @(Invoke-StevedoreRead -Store $Store -Arguments @('ps', '--quiet', '--no-trunc') `
        -FailureMessage 'Cannot inspect Stevedore containers.')
    if (@($running | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'Stevedore containers are running; refusing cleanup.'
    }
    Assert-BuildkitIdle -Buildctl $Buildctl -Address $Address
}

function Get-StevedoreImageId {
    param($Store, [string]$Tag)
    $raw = @(Invoke-StevedoreRead -Store $Store -Arguments @('image', 'inspect', $Tag) -FailureMessage "Cannot inspect image: $Tag")
    if (-not $raw.Count) { throw "Cannot inspect image: $Tag" }
    $items = @(ConvertFrom-StevedoreJson -Raw $raw -Context "image inspection: $Tag")
    if ($items.Count -ne 1 -or $null -eq $items[0].PSObject.Properties['Id']) { throw "Unexpected image inspection: $Tag" }
    return $items[0].Id
}

function Assert-StevedoreTarget {
    param($Store, $Target)
    if ((Get-StevedoreImageId -Store $Store -Tag $Target.Tag) -cne $Target.Id) {
        throw "Image changed since review: $($Target.Tag)"
    }
}

function Invoke-StevedoreRemoval {
    param($Store, [string]$Tag)
    & $Store.Tool --address $Store.Address --namespace $Store.Namespace rmi $Tag | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Image removal failed: $Tag" }
}

function Invoke-StevedoreRegularPrune {
    param([string]$Buildctl, [string]$Address, [int]$TargetGB)
    & $Buildctl --addr $Address prune --filter 'type==regular' --free-storage ($TargetGB * 1024) | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Regular BuildKit cache prune failed.' }
}

function Assert-StevedoreAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator rights are required.' }
}

function Invoke-StevedoreReclaim {
    param([object[]]$Targets, [bool]$PruneRegular, [int]$TargetGB, [bool]$DoApply,
        [string]$Nerdctl, [string]$Buildctl, [string]$Namespace, [string]$Address, [string]$ContainerdAddress)
    if (-not $Targets.Count -and -not $PruneRegular) { throw 'Select image tags or -RegularCache.' }
    if ($TargetGB -lt 1 -or $TargetGB -gt 2097151) { throw 'KeepGB is outside the supported range.' }
    if ($Namespace -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'Invalid Stevedore namespace.' }
    if ($Address -notmatch '^(npipe|unix|tcp)://\S+$') { throw 'Invalid BuildKit address.' }
    if ($ContainerdAddress -notmatch '^(?:(npipe|unix|tcp)://\S+|\\\\\.\\pipe\\[^\s]+)$') { throw 'Invalid containerd address.' }
    $store = [pscustomobject]@{ Tool = $Nerdctl; Namespace = $Namespace; Address = $ContainerdAddress }
    foreach ($target in $Targets) {
        Assert-StevedoreTarget -Store $store -Target $target
        Write-HostMaintenanceMessage ("Stevedore tag: {0} ({1})" -f $target.Tag, $target.Id)
    }
    if ($PruneRegular) { Write-HostMaintenanceMessage ("Unused regular BuildKit cache: free-space target {0} GB; cache mounts excluded." -f $TargetGB) }
    if (-not $DoApply) { Write-HostMaintenanceMessage 'REPORT ONLY. Re-run with -Apply after review.'; return }
    Assert-StevedoreAdmin
    Assert-StevedoreIdle -Buildctl $Buildctl -Address $Address -Store $store
    foreach ($target in $Targets) {
        Assert-StevedoreTarget -Store $store -Target $target
        Invoke-StevedoreRemoval -Store $store -Tag $target.Tag
    }
    if ($PruneRegular) {
        Assert-StevedoreIdle -Buildctl $Buildctl -Address $Address -Store $store
        Invoke-StevedoreRegularPrune -Buildctl $Buildctl -Address $Address -TargetGB $TargetGB
    }
}

function Assert-StevedoreSelectors {
    param([bool]$Selected, [string[]]$BoundParameters)
    if (-not $Selected) {
        foreach ($name in @('ImageTag', 'ExpectedImageId', 'RegularCache', 'StevedoreNamespace', 'BuildkitAddress', 'ContainerdAddress')) {
            if ($name -in $BoundParameters) { throw "$name requires -StevedoreOnly." }
        }
    }
}

function Invoke-StevedoreOnlyMode {
    if ($AllowDuringBuild -or $NoDaemonPrune -or $StoreHusksOnly) { throw 'StevedoreOnly cannot be combined with other cleanup selectors.' }
    $targets = @(Get-StevedoreTargets -Tags $ImageTag -Ids $ExpectedImageId)
    $bin = Join-Path $env:ProgramFiles 'Stevedore\bin'
    Invoke-StevedoreReclaim -Targets $targets -PruneRegular ([bool]$RegularCache) -TargetGB $KeepGB -DoApply ([bool]$Apply) `
        -Nerdctl (Join-Path $bin 'nerdctl.exe') -Buildctl (Join-Path $bin 'buildctl.exe') `
        -Namespace $StevedoreNamespace -Address $BuildkitAddress -ContainerdAddress $ContainerdAddress
    return 0
}

function Invoke-FreeDiskSpace {
    Assert-StevedoreSelectors -Selected ([bool]$StevedoreOnly) -BoundParameters $script:cleanupBoundParameters
    if ($StevedoreOnly) { return (Invoke-StevedoreOnlyMode) }
    Write-HostMaintenanceMessage '== resolving the allowlist ==' 'Cyan'
    $daemonPrune = -not ($NoDaemonPrune -or $StoreHusksOnly)
    $plan = @(Get-ReclaimPlan -Rules (Get-ReclaimRules -TempAgeDays $TempOlderThanDays -StoreHusksOnly:$StoreHusksOnly))

    # Fail closed: one target on a protected root means the resolution is wrong, so nothing runs.
    foreach ($t in $plan) {
        if (Test-Protected $t.Path) {
            Write-HostMaintenanceMessage ('REFUSING THE WHOLE RUN: a resolved target lands on a protected root -> ' + $t.Path) 'Red'
            Write-HostMaintenanceMessage 'The allowlist resolution is wrong. Fix the rule; do not bypass this.' 'Red'
            return 2
        }
    }

    Write-ReclaimPlanSummary -Plan $plan

    # ----------------------------------------------------- daemon levers ----
    Write-DaemonPruneAdvice -DaemonPrune $daemonPrune -KeepGB $KeepGB

    # ------------------------------------------------------- the delete -----
    if (-not $Apply) {
        Write-Host ''
        Write-HostMaintenanceMessage 'REPORT ONLY. Re-run with -Apply to delete the entries listed above.' 'Green'
        Write-HostMaintenanceMessage 'Nothing outside that list will EVER be touched by this script.' 'Green'
        return 0
    }

    $buildLive = $false
    try { $buildLive = [bool](Get-Process -Name 'buildctl', 'docker' -ErrorAction SilentlyContinue) } catch { $buildLive = $false }
    if ($buildLive -and -not $AllowDuringBuild) {
        Write-HostMaintenanceMessage 'a build looks live (buildctl/docker running) - refusing the destructive half.' 'Red'
        Write-HostMaintenanceMessage 'Re-run with -AllowDuringBuild once the chain is idle.' 'Red'
        return 1
    }

    Invoke-ReclaimDaemonPrune -DaemonPrune $daemonPrune -KeepGB $KeepGB

    Write-HostMaintenanceMessage '== deleting allow-listed entries ==' 'Cyan'
    $freed = 0.0
    foreach ($t in $plan) {
        if (Test-Protected $t.Path) { Write-HostMaintenanceMessage ('SKIP (protected): ' + $t.Path) 'Red'; continue }
        if ($t.Linked -or (Test-HasReparsePoint $t.Path)) { Write-HostMaintenanceMessage ('SKIP (junction/symlink or unreadable tree): ' + $t.Path) 'Yellow'; continue }
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            $freed += $t.SizeGB
        } catch {
            Write-HostMaintenanceMessage ('locked or in use, left in place: {0}' -f $t.Path) 'DarkGray'
        }
    }

    Write-Host ''
    Write-HostMaintenanceMessage ('done - {0} GB returned from allow-listed entries.' -f [math]::Round($freed, 2)) 'Green'
    Get-PSDrive C, D -ErrorAction SilentlyContinue |
        ForEach-Object { Write-HostMaintenanceMessage ('{0}: {1} GB free' -f $_.Name, [int]($_.Free / 1GB)) }
    return 0
}

# Dot-sourced (by the test suite) = definitions only, nothing runs.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-FreeDiskSpace)
}
