#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Compacts a host VHDX (admin, never while a build solves); ReFS guests reclaim ~nothing: see docs/windows-builds.md § Optimize-HostVhdx.ps1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The dynamically-expanding VHDX to compact. Machine-specific, no default.
    [Parameter(Mandatory)]
    [string]$VhdxPath,

    # Services to stop, dependents first; restarted in reverse order.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes that mean a build is live: the run is refused unless -Force, which kills them.
    [string[]]$BlockingProcess = @('buildctl'),

    # Optimize-VHD mode; Full is the deepest and needs the read-only attach.
    [ValidateSet('Full', 'Quick', 'Retrim')]
    [string]$Mode = 'Full',

    # Path that must exist again after the remount; empty skips the check.
    [string]$VerifyPath = '',

    # Where the transcript lands. Default: <repo>\logs\host\compact-host-vhdx.log
    [string]$LogPath = '',

    # Report sizes, guest filesystem and reclaim potential, then exit without touching anything.
    [switch]$ReportOnly,

    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1') -Force
$hostLog = New-HostMaintenanceLog -Name 'compact-host-vhdx' -LogPath $LogPath

# --- guards ------------------------------------------------------------------

Assert-Elevated -Reason 'attach/detach and service control need it'
if (-not (Test-Path $VhdxPath)) { throw "VHDX not found: $VhdxPath" }

# --- inspect: sizes + guest filesystem ---------------------------------------

# Reclaim potential is physical size minus guest usage, reported before anything is touched.
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

function Write-GuestVolumeReport {
    param($Volume, [long]$PhysicalBytes, $Log)
    if ($Volume) {
        $used = $Volume.Size - $Volume.SizeRemaining
        Write-HostStep -Log $Log ('guest fs  : {0} ({1}), {2:N1} GB used of {3:N1} GB' -f
            $Volume.FileSystem, $Volume.FileSystemLabel, ($used / 1GB), ($Volume.Size / 1GB))
        Write-HostStep -Log $Log ('potential : ~{0:N1} GB of dead blocks' -f (($PhysicalBytes - $used) / 1GB))
        if ($Volume.FileSystem -eq 'ReFS') {
            Write-HostStep -Log $Log 'WARNING: ReFS guest — Optimize-VHD usually reclaims ~nothing here.' 'Yellow'
            Write-HostStep -Log $Log '         ReFS does not report free blocks via UNMAP the way NTFS does;' 'Yellow'
            Write-HostStep -Log $Log '         expect "Optimize-VHD OK" with a near-zero delta. The reliable' 'Yellow'
            Write-HostStep -Log $Log '         reclaim on ReFS is rebuilding the VHDX around its live data.' 'Yellow'
        }
    } else {
        Write-HostStep -Log $Log 'guest fs  : not attached (or unreadable) — skipping the potential estimate.'
    }
}

$snapshotArgs = @{ Path = $VhdxPath; Drive = (Split-Path $VhdxPath -Qualifier).TrimEnd(':') }
$before = Get-HostMaintenanceVhdxSnapshot @snapshotArgs
$physicalBefore = $before.PhysicalBytes
$freeBefore = $before.HostFreeBytes

Write-HostStep -Log $hostLog ('VHDX      : {0}' -f $VhdxPath)
Write-HostStep -Log $hostLog ('physical  : {0:N1} GB' -f ($physicalBefore / 1GB))
Write-HostStep -Log $hostLog ('host free : {0:N1} GB' -f ($freeBefore / 1GB))

$volume = Get-GuestVolumeInfo -Path $VhdxPath
Write-GuestVolumeReport -Volume $volume -PhysicalBytes $physicalBefore -Log $hostLog

if ($ReportOnly) {
    Write-HostStep -Log $hostLog 'ReportOnly: nothing changed.' 'Cyan'
    Save-HostMaintenanceLog -Log $hostLog
    return
}

$live = @(Get-HostMaintenanceProcess -Name $BlockingProcess -Force:$Force -Log $hostLog `
    -FailureTemplate '{0} live process(es) found ({1}; pids: {2}) — stopping the build services kills their solves. Wait for the build to finish, or pass -Force if they are stale.')

if (-not $PSCmdlet.ShouldProcess($VhdxPath, "stop [$($Service -join ', ')], detach, compact ($Mode), reattach")) {
    return
}

# --- 1) stale build clients ---------------------------------------------------

Write-HostStep -Log $hostLog '--- stale build clients ---'
if ($live.Count -gt 0) {
    foreach ($p in $live) {
        Write-HostStep -Log $hostLog ('killing {0} PID {1} (CPU {2}s)' -f $p.ProcessName, $p.Id, [math]::Round($p.CPU, 1))
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-HostStep -Log $hostLog 'none running'
}

# --- 2) services down ---------------------------------------------------------

$stopped = Stop-HostServices -Log $hostLog -Service $Service

# --- 3) compact (read-only attach; the finally always restores read-write so the volume is never stranded) ---

try {
    Write-HostStep -Log $hostLog '--- detach ---'
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
    Write-HostStep -Log $hostLog 'detached'

    Write-HostStep -Log $hostLog '--- attach read-only ---'
    Mount-DiskImage -ImagePath $VhdxPath -Access ReadOnly -NoDriveLetter -ErrorAction Stop | Out-Null
    Write-HostStep -Log $hostLog 'read-only attached'

    Write-HostStep -Log $hostLog "--- compact (mode $Mode; can take a while, the console looks idle) ---"
    if (-not (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)) {
        throw 'Optimize-VHD not available — install the Hyper-V PowerShell module: ' +
              'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell'
    }
    Optimize-VHD -Path $VhdxPath -Mode $Mode -ErrorAction Stop
    Write-HostStep -Log $hostLog 'Optimize-VHD reported success'
} catch {
    Write-HostMaintenanceError -Log $hostLog -ErrorRecord $_ -Template 'COMPACT ERROR: {0}' -Color 'Red'
} finally {
    Write-HostStep -Log $hostLog '--- reattach read-write ---'
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null
    try {
        Mount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
        Write-HostStep -Log $hostLog 'reattached'
    } catch {
        Write-HostMaintenanceError -Log $hostLog -ErrorRecord $_ -Template 'REATTACH ERROR: {0}' -Color 'Red'
        Write-HostStep -Log $hostLog ('Recover manually: Mount-DiskImage -ImagePath {0}' -f $VhdxPath) 'Red'
    }
    Start-Sleep -Seconds 3
}

# --- 4) result ----------------------------------------------------------------

$after = Get-HostMaintenanceVhdxSnapshot @snapshotArgs
$physicalAfter = $after.PhysicalBytes
$freeAfter = $after.HostFreeBytes
$reclaimed = ($physicalBefore - $physicalAfter) / 1GB

Write-HostStep -Log $hostLog ('--- after: VHDX {0:N1} GB physical | host free {1:N1} GB' -f ($physicalAfter / 1GB), ($freeAfter / 1GB))
Write-HostStep -Log $hostLog ('reclaimed from the VHDX : {0:N1} GB' -f $reclaimed)
Write-HostStep -Log $hostLog ('host free delta (all causes): {0:N1} GB' -f (($freeAfter - $freeBefore) / 1GB))

if ($reclaimed -lt 1 -and $volume -and $volume.FileSystem -eq 'ReFS') {
    Write-HostStep -Log $hostLog 'As predicted for ReFS: compaction returned ~nothing. Rebuild the VHDX to reclaim.' 'Yellow'
}

if ($VerifyPath) {
    $ok = Test-HostMaintenanceVerifyPath -Log $hostLog -Path $VerifyPath
    if (-not $ok) { Write-HostStep -Log $hostLog 'the volume did not come back with its drive letter — check Disk Management.' 'Red' }
}

# --- 5) services up -----------------------------------------------------------

Start-HostServices -Log $hostLog -Service $stopped

Write-HostStep -Log $hostLog 'done' 'Green'
Save-HostMaintenanceLog -Log $hostLog
