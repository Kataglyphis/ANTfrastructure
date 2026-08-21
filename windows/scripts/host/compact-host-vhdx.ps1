#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Reclaims host disk space when the repo checkout (or the container store)
# lives on a dynamically-expanding VHDX: stops the build services so nothing
# holds a handle, detaches the disk, compacts it, re-attaches it read-write
# and restarts the services. Also frees whatever scratch the running build
# services were pinning — on the reference host that second effect was worth
# 19 GB while the compaction itself returned 0.2 GB (see the ReFS warning
# below and docs/windows-host-setup.md § D3).
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running — stopping
# buildkitd kills every in-flight solve. The script refuses if it sees a live
# buildctl process unless -Force is passed.
#
# ReFS CAVEAT (measured, not theoretical): Optimize-VHD can only release
# blocks the guest filesystem reports as free via UNMAP/TRIM. NTFS guests do
# that reliably; ReFS guests largely do not, so a ReFS VHDX can sit at 270 GB
# physical for 16 GB of data and still report "Optimize-VHD OK" after
# reclaiming nothing. The script detects the guest filesystem up front and
# says so BEFORE you spend the downtime. On ReFS the only reliable reclaim is
# rebuilding the VHDX around its live data.
#
# Everything machine-specific is a parameter — the defaults describe the
# reference host, not a requirement. Examples:
#
#   # reference host
#   pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx
#
#   # look first, change nothing (no downtime, no service stop)
#   pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath D:\vm\build.vhdx -ReportOnly
#
#   # another machine: different disk, different services, verify the checkout came back
#   pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath E:\disks\ci.vhdx `
#        -Service buildkitd, containerd, stevedore -VerifyPath E:\src\Kataglyphis-ContainerHub

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The dynamically-expanding VHDX to compact. Machine-specific, no default.
    [Parameter(Mandatory)]
    [string]$VhdxPath,

    # Services stopped for the duration (order matters: dependents first).
    # They are restarted in reverse order afterwards.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes whose presence means a build is live; the run is refused
    # unless -Force. Stale ones are killed once the guard passes.
    [string[]]$BlockingProcess = @('buildctl'),

    # Optimize-VHD mode. Full = deepest (needs the read-only attach);
    # Quick/Retrim are cheaper and rarely worth it here.
    [ValidateSet('Full', 'Quick', 'Retrim')]
    [string]$Mode = 'Full',

    # Path that must exist again after the remount (typically the repo
    # checkout on the VHDX). Empty = skip the check.
    [string]$VerifyPath = '',

    # Where the transcript lands. Default: <repo>\out\compact-host-vhdx.log
    [string]$LogPath = '',

    # Report sizes, guest filesystem and reclaim potential, then exit.
    # Touches nothing: no service stop, no detach, no downtime.
    [switch]$ReportOnly,

    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$repoRoot = Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1') -Force
$hostLog = New-HostMaintenanceLog -Name 'compact-host-vhdx' -RepoRoot $repoRoot -LogPath $LogPath
$LogPath = $hostLog.LogPath
# Thin local wrappers so the ~50 existing call sites keep their signature.
function Write-Step { param([string]$Message, [string]$Color = 'Gray') Write-HostStep $hostLog $Message $Color }
function Save-Transcript { Save-HostMaintenanceLog $hostLog }

# --- guards ------------------------------------------------------------------

Assert-Elevated -Reason 'attach/detach and service control need it'
if (-not (Test-Path $VhdxPath)) { throw "VHDX not found: $VhdxPath" }

# --- inspect: sizes + guest filesystem ---------------------------------------

# Reclaim potential = physical file size minus what the guest actually uses.
# Reported before anything is touched so -ReportOnly is a complete answer.
function Get-GuestVolumeInfo {
    param([string]$Path)
    try {
        $image = Get-DiskImage -ImagePath $Path -ErrorAction Stop
        if (-not $image.Attached) { return $null }
        $disk = $image | Get-Disk -ErrorAction Stop
        return Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
            Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystem } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

$physicalBefore = (Get-Item $VhdxPath).Length
$freeBefore = (Get-PSDrive (Split-Path $VhdxPath -Qualifier).TrimEnd(':')).Free

Write-Step ('VHDX      : {0}' -f $VhdxPath)
Write-Step ('physical  : {0:N1} GB' -f ($physicalBefore / 1GB))
Write-Step ('host free : {0:N1} GB' -f ($freeBefore / 1GB))

$volume = Get-GuestVolumeInfo -Path $VhdxPath
if ($volume) {
    $used = $volume.Size - $volume.SizeRemaining
    Write-Step ('guest fs  : {0} ({1}), {2:N1} GB used of {3:N1} GB' -f
        $volume.FileSystem, $volume.FileSystemLabel, ($used / 1GB), ($volume.Size / 1GB))
    Write-Step ('potential : ~{0:N1} GB of dead blocks' -f (($physicalBefore - $used) / 1GB))

    if ($volume.FileSystem -eq 'ReFS') {
        Write-Step 'WARNING: ReFS guest — Optimize-VHD usually reclaims ~nothing here.' 'Yellow'
        Write-Step '         ReFS does not report free blocks via UNMAP the way NTFS does;' 'Yellow'
        Write-Step '         expect "Optimize-VHD OK" with a near-zero delta. The reliable' 'Yellow'
        Write-Step '         reclaim on ReFS is rebuilding the VHDX around its live data.' 'Yellow'
    }
} else {
    Write-Step 'guest fs  : not attached (or unreadable) — skipping the potential estimate.'
}

if ($ReportOnly) {
    Write-Step 'ReportOnly: nothing changed.' 'Cyan'
    Save-Transcript
    return
}

$live = @(Get-Process -Name $BlockingProcess -ErrorAction SilentlyContinue)
if ($live.Count -gt 0 -and -not $Force) {
    Save-Transcript
    throw ("{0} live process(es) found ({1}; pids: {2}) — stopping the build services kills their solves. " -f
        $live.Count, (($live | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '),
        (($live | ForEach-Object Id) -join ', ')) +
        'Wait for the build to finish, or pass -Force if they are stale.'
}

if (-not $PSCmdlet.ShouldProcess($VhdxPath, "stop [$($Service -join ', ')], detach, compact ($Mode), reattach")) {
    return
}

# --- 1) stale build clients ---------------------------------------------------

Write-Step '--- stale build clients ---'
if ($live.Count -gt 0) {
    foreach ($p in $live) {
        Write-Step ('killing {0} PID {1} (CPU {2}s)' -f $p.ProcessName, $p.Id, [math]::Round($p.CPU, 1))
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Step 'none running'
}

# --- 2) services down ---------------------------------------------------------

$stopped = Stop-HostServices -Log $hostLog -Service $Service

# --- 3) compact ---------------------------------------------------------------
#
# Optimize-VHD needs the disk detached or attached READ-ONLY. The finally
# block always restores the read-write attach, so a failure mid-compact can
# never strand the volume offline (that failure mode cost a session once).

try {
    Write-Step '--- detach ---'
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
    Write-Step 'detached'

    Write-Step '--- attach read-only ---'
    Mount-DiskImage -ImagePath $VhdxPath -Access ReadOnly -NoDriveLetter -ErrorAction Stop | Out-Null
    Write-Step 'read-only attached'

    Write-Step "--- compact (mode $Mode; can take a while, the console looks idle) ---"
    if (-not (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)) {
        throw 'Optimize-VHD not available — install the Hyper-V PowerShell module: ' +
              'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell'
    }
    Optimize-VHD -Path $VhdxPath -Mode $Mode -ErrorAction Stop
    Write-Step 'Optimize-VHD reported success'
} catch {
    Write-Step ('COMPACT ERROR: {0}' -f $_.Exception.Message) 'Red'
} finally {
    Write-Step '--- reattach read-write ---'
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null
    try {
        Mount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
        Write-Step 'reattached'
    } catch {
        Write-Step ('REATTACH ERROR: {0}' -f $_.Exception.Message) 'Red'
        Write-Step ('Recover manually: Mount-DiskImage -ImagePath {0}' -f $VhdxPath) 'Red'
    }
    Start-Sleep -Seconds 3
}

# --- 4) result ----------------------------------------------------------------

$physicalAfter = (Get-Item $VhdxPath).Length
$freeAfter = (Get-PSDrive (Split-Path $VhdxPath -Qualifier).TrimEnd(':')).Free
$reclaimed = ($physicalBefore - $physicalAfter) / 1GB

Write-Step ('--- after: VHDX {0:N1} GB physical | host free {1:N1} GB' -f ($physicalAfter / 1GB), ($freeAfter / 1GB))
Write-Step ('reclaimed from the VHDX : {0:N1} GB' -f $reclaimed)
Write-Step ('host free delta (all causes): {0:N1} GB' -f (($freeAfter - $freeBefore) / 1GB))

if ($reclaimed -lt 1 -and $volume -and $volume.FileSystem -eq 'ReFS') {
    Write-Step 'As predicted for ReFS: compaction returned ~nothing. Rebuild the VHDX to reclaim.' 'Yellow'
}

if ($VerifyPath) {
    $ok = Test-Path $VerifyPath
    Write-Step ("verify path {0}: {1}" -f $VerifyPath, $ok) $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) { Write-Step 'the volume did not come back with its drive letter — check Disk Management.' 'Red' }
}

# --- 5) services up -----------------------------------------------------------

Write-Step '--- starting services ---'
[array]::Reverse($stopped)
foreach ($s in $stopped) {
    try {
        Start-Service $s -ErrorAction Stop
        Write-Step ('{0} : {1}' -f $s, (Get-Service $s).Status)
    } catch {
        Write-Step ('{0} START ERROR: {1}' -f $s, $_.Exception.Message) 'Red'
    }
}

Write-Step 'done' 'Green'
Save-Transcript
