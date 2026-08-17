#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Reclaims the dead blocks of a dynamically-expanding VHDX by REBUILDING it
# around its live data, instead of compacting it. Use this when
# compact-host-vhdx.ps1 reports a near-zero reclaim — which is the expected
# outcome on ReFS guests, where Optimize-VHD cannot see the guest's free
# blocks (measured on the reference host: 269.9 GB physical for 16.2 GB of
# data, compaction returned 0.2 GB; see docs/windows-host-setup.md § D3).
#
# The rebuild is a copy, not an in-place operation: a fresh VHDX is created,
# the live data is mirrored into it, both copies are compared, and only then
# is the drive letter moved over. The old file is KEPT (renamed .old) unless
# -RetireOld is passed, so a bad outcome is always one rename away from being
# undone.
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running.
#
# TWO PHASES, because they have very different requirements:
#
#   copy  — creates the new VHDX and mirrors the data. The source volume stays
#           mounted and in use the whole time. Safe to run with editors, shells
#           and agents still sitting on the drive.
#   swap  — detaches the source and hands its drive letter to the new disk.
#           This REQUIRES that no process holds a handle on the volume: no
#           shell whose current directory is on it, no editor with the
#           checkout open. A detach that strands the volume is what killed a
#           working session once, so the swap refuses rather than forces, and
#           the copy it already made survives for a later -SwapOnly run.
#
# Everything machine-specific is a parameter. Examples:
#
#   # look first: sizes, guest filesystem, what the rebuild would reclaim
#   pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -ReportOnly
#
#   # phase 1 only — safe to run right now, with everything still open
#   pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -CopyOnly
#
#   # phase 2, after closing everything that lives on the volume
#   pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx `
#        -SwapOnly -VerifyPath D:\GitHub\Kataglyphis-ContainerHub
#
#   # both phases, and delete the old file once the rebuild verifies
#   pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx `
#        -VerifyPath D:\GitHub\Kataglyphis-ContainerHub -RetireOld

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The dynamically-expanding VHDX to rebuild. Machine-specific, no default.
    [Parameter(Mandatory)]
    [string]$VhdxPath,

    # Maximum size of the replacement disk. 0 = same as the source. The disk
    # is dynamic, so this is a ceiling, not an allocation — but sizing it to
    # what the volume will realistically hold keeps future runaway growth
    # bounded instead of letting it eat the host again.
    [int]$NewSizeGB = 0,

    # Where the replacement is built. Defaults to <source>.new.vhdx, i.e. the
    # same volume as the source — which is what you want: the host needs room
    # for the live data (~16 GB on the reference host), not for a second copy
    # of the dead blocks.
    [string]$NewVhdxPath = '',

    # Services stopped for the swap (order matters: dependents first).
    # Restarted in reverse afterwards. The copy phase leaves them alone.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes whose presence means a build is live; the run is refused
    # unless -Force.
    [string[]]$BlockingProcess = @('buildctl'),

    # Path that must exist on the rebuilt volume before the old disk is
    # considered retired (typically the repo checkout). Empty = skip.
    [string]$VerifyPath = '',

    # Directories excluded from the mirror. The defaults are volume metadata
    # that cannot and must not be copied.
    [string[]]$ExcludeDir = @('System Volume Information', '$RECYCLE.BIN'),

    # Where the transcript lands. Default: <repo>\out\rebuild-host-vhdx.log
    [string]$LogPath = '',

    # Report sizes, guest filesystem and reclaim potential, then exit.
    [switch]$ReportOnly,

    # Phase 1 only: build and verify the replacement, change nothing else.
    [switch]$CopyOnly,

    # Phase 2 only: swap in a replacement built by an earlier -CopyOnly run.
    [switch]$SwapOnly,

    # Delete the old VHDX after the swap verifies. Without this the old file
    # is kept as <source>.old and the space is not reclaimed until you remove
    # it yourself — deliberately, so the first run of this script on a new
    # machine cannot lose data.
    [switch]$RetireOld,

    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $LogPath) { $LogPath = Join-Path $repoRoot 'out\rebuild-host-vhdx.log' }
if (-not $NewVhdxPath) { $NewVhdxPath = [IO.Path]::ChangeExtension($VhdxPath, $null) + 'new.vhdx' }
$oldVhdxPath = "$VhdxPath.old"

$transcript = [System.Collections.Generic.List[string]]::new()
function Write-Step {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $transcript.Add($line)
    Write-Host $line -ForegroundColor $Color
}

function Save-Transcript {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent) | Out-Null
        Set-Content -Path $LogPath -Value ($transcript -join [Environment]::NewLine) -Encoding UTF8
        Write-Host "log: $LogPath" -ForegroundColor DarkGray
    } catch {
        Write-Warning "could not write log to ${LogPath}: $($_.Exception.Message)"
    }
}

# Total bytes and file count under a root, used to compare source and copy.
# Access errors are counted separately rather than swallowed: a mismatch that
# comes from an unreadable file is a different problem than a short copy.
function Measure-Tree {
    param([string]$Root)
    $bytes = [long]0; $files = 0; $errors = 0
    $ev = $null
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable ev
    foreach ($f in $items) { $bytes += $f.Length; $files++ }
    if ($ev) { $errors = @($ev).Count }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Errors = $errors }
}

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($c in [char[]](90..68)) { if ($used -notcontains "$c") { return "$c" } }
    throw 'no free drive letter available for the staging mount.'
}

# --- guards ------------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated (admin) shell: attach/detach, format and service control need it.'
}
if ($CopyOnly -and $SwapOnly) { throw '-CopyOnly and -SwapOnly are mutually exclusive.' }
if (-not (Test-Path $VhdxPath)) { throw "VHDX not found: $VhdxPath" }
if (-not (Get-Command New-VHD -ErrorAction SilentlyContinue)) {
    throw 'New-VHD not available — install the Hyper-V PowerShell module: ' +
          'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell'
}

$hostDrive = (Split-Path $VhdxPath -Qualifier).TrimEnd(':')

# --- inspect ------------------------------------------------------------------

$image = Get-DiskImage -ImagePath $VhdxPath
if (-not $image.Attached) { throw "source VHDX is not attached — mount it first: Mount-DiskImage -ImagePath $VhdxPath" }

$sourceDisk = $image | Get-Disk
$sourcePart = Get-Partition -DiskNumber $sourceDisk.Number | Where-Object DriveLetter | Select-Object -First 1
if (-not $sourcePart) { throw 'the source disk has no partition with a drive letter — nothing to mirror.' }
$sourceVolume = $sourcePart | Get-Volume
$sourceLetter = $sourcePart.DriveLetter
$sourceRoot = "${sourceLetter}:\"

$physicalBefore = (Get-Item $VhdxPath).Length
$usedBytes = $sourceVolume.Size - $sourceVolume.SizeRemaining
$freeBefore = (Get-PSDrive $hostDrive).Free

Write-Step ('source VHDX : {0}' -f $VhdxPath)
Write-Step ('physical    : {0:N1} GB' -f ($physicalBefore / 1GB))
Write-Step ('guest       : {0}: {1} ({2}), {3:N1} GB used of {4:N1} GB' -f
    $sourceLetter, $sourceVolume.FileSystem, $sourceVolume.FileSystemLabel,
    ($usedBytes / 1GB), ($sourceVolume.Size / 1GB))
Write-Step ('host {0}: free : {1:N1} GB' -f $hostDrive, ($freeBefore / 1GB))
Write-Step ('reclaimable : ~{0:N1} GB by rebuilding' -f (($physicalBefore - $usedBytes) / 1GB))

# The copy needs room for the live data plus headroom; the dead blocks are
# not copied, so this is far less than the source's physical size.
$needed = $usedBytes * 1.15
if (-not $SwapOnly -and $freeBefore -lt $needed) {
    throw ('not enough room on {0}: need ~{1:N1} GB for the copy, {2:N1} GB free.' -f
        $hostDrive, ($needed / 1GB), ($freeBefore / 1GB))
}

if ($ReportOnly) {
    Write-Step 'ReportOnly: nothing changed.' 'Cyan'
    Save-Transcript
    return
}

$live = @(Get-Process -Name $BlockingProcess -ErrorAction SilentlyContinue)
if ($live.Count -gt 0 -and -not $Force) {
    Save-Transcript
    throw ('{0} live build process(es) ({1}) — finish the build first, or pass -Force if they are stale.' -f
        $live.Count, (($live | ForEach-Object Id) -join ', '))
}

if (-not $PSCmdlet.ShouldProcess($VhdxPath, 'rebuild around live data')) { return }

# --- phase 1: build the replacement and mirror into it ------------------------

if (-not $SwapOnly) {
    if (Test-Path $NewVhdxPath) {
        throw "replacement already exists: $NewVhdxPath — delete it, or pass -SwapOnly to use it."
    }

    $sizeBytes = if ($NewSizeGB -gt 0) { [long]$NewSizeGB * 1GB } else { $image.Size }
    Write-Step ('--- creating replacement: {0} ({1:N0} GB max, dynamic) ---' -f $NewVhdxPath, ($sizeBytes / 1GB))
    New-VHD -Path $NewVhdxPath -SizeBytes $sizeBytes -Dynamic | Out-Null

    $stageLetter = Get-FreeDriveLetter
    try {
        Mount-DiskImage -ImagePath $NewVhdxPath -ErrorAction Stop | Out-Null
        $newDisk = Get-DiskImage -ImagePath $NewVhdxPath | Get-Disk
        Initialize-Disk -Number $newDisk.Number -PartitionStyle $sourceDisk.PartitionStyle -ErrorAction Stop | Out-Null

        $newPart = New-Partition -DiskNumber $newDisk.Number -UseMaximumSize -DriveLetter $stageLetter -ErrorAction Stop
        Write-Step ('staged as {0}: — formatting {1} ({2})' -f
            $stageLetter, $sourceVolume.FileSystem, $sourceVolume.FileSystemLabel)

        # Reproduce the source's filesystem, label and cluster size. A Dev
        # Drive is an ReFS volume with a trust flag; -DevDrive exists only on
        # builds that support it, hence the capability probe.
        $fmt = @{
            FileSystem         = $sourceVolume.FileSystem
            NewFileSystemLabel = $sourceVolume.FileSystemLabel
            AllocationUnitSize = $sourceVolume.AllocationUnitSize
            Confirm            = $false
            ErrorAction        = 'Stop'
        }
        $isDevDrive = $false
        if ($sourceVolume.FileSystem -eq 'ReFS') {
            $probe = & fsutil devdrv query "${sourceLetter}:" 2>&1 | Out-String
            $isDevDrive = $probe -match 'ist ein Dev Drive|is a Dev Drive'
            if ($isDevDrive -and (Get-Command Format-Volume).Parameters.ContainsKey('DevDrive')) {
                $fmt['DevDrive'] = $true
                Write-Step 'source is a Dev Drive — formatting the replacement as one too'
            } elseif ($isDevDrive) {
                Write-Step 'source is a Dev Drive but Format-Volume has no -DevDrive here;' 'Yellow'
                Write-Step 'the copy will be plain ReFS — re-flag it with: fsutil devdrv trust' 'Yellow'
            }
        }
        $newPart | Format-Volume @fmt | Out-Null

        Write-Step ('--- mirroring {0} -> {1}:\ (this is the long part) ---' -f $sourceRoot, $stageLetter)
        $xd = @(); foreach ($d in $ExcludeDir) { $xd += Join-Path $sourceRoot $d }
        $rc = @(
            $sourceRoot, "${stageLetter}:\", '/MIR', '/COPYALL', '/DCOPY:DAT',
            '/XJ', '/R:1', '/W:1', '/MT:8', '/NFL', '/NDL', '/NP', '/NJH'
        )
        if ($xd.Count -gt 0) { $rc += '/XD'; $rc += $xd }
        & robocopy @rc | ForEach-Object { if ($_.Trim()) { Write-Step "  $_" } }

        # robocopy: 0-7 are success (8+ means files were skipped or failed).
        $rcExit = $LASTEXITCODE
        Write-Step ('robocopy exit {0} ({1})' -f $rcExit, $(if ($rcExit -lt 8) { 'ok' } else { 'FAILURES' }))
        if ($rcExit -ge 8) { throw "robocopy reported failures (exit $rcExit) — the copy is not trustworthy." }

        Write-Step '--- verifying the copy ---'
        $srcStats = Measure-Tree -Root $sourceRoot
        $dstStats = Measure-Tree -Root "${stageLetter}:\"
        Write-Step ('source : {0:N0} files, {1:N2} GB ({2} unreadable)' -f $srcStats.Files, ($srcStats.Bytes / 1GB), $srcStats.Errors)
        Write-Step ('copy   : {0:N0} files, {1:N2} GB ({2} unreadable)' -f $dstStats.Files, ($dstStats.Bytes / 1GB), $dstStats.Errors)
        if ($dstStats.Files -ne $srcStats.Files -or $dstStats.Bytes -ne $srcStats.Bytes) {
            throw 'copy does not match the source — refusing to go any further. The source is untouched.'
        }
        Write-Step 'copy matches the source exactly' 'Green'
    } catch {
        Write-Step ('COPY FAILED: {0}' -f $_.Exception.Message) 'Red'
        Write-Step 'discarding the incomplete replacement; the source is untouched.' 'Yellow'
        Dismount-DiskImage -ImagePath $NewVhdxPath -ErrorAction SilentlyContinue | Out-Null
        Remove-Item $NewVhdxPath -Force -ErrorAction SilentlyContinue
        Save-Transcript
        throw
    }

    Dismount-DiskImage -ImagePath $NewVhdxPath -ErrorAction SilentlyContinue | Out-Null
    Write-Step 'replacement built and detached' 'Green'

    if ($CopyOnly) {
        Write-Step 'CopyOnly: stopping here. Nothing on the live volume was touched.' 'Cyan'
        Write-Step ('Run the swap once nothing holds {0}: -SwapOnly' -f $sourceRoot) 'Cyan'
        Save-Transcript
        return
    }
}

# --- phase 2: swap ------------------------------------------------------------

if (-not (Test-Path $NewVhdxPath)) { throw "no replacement to swap in: $NewVhdxPath" }

Write-Step '--- stopping services ---'
$stopped = [System.Collections.Generic.List[string]]::new()
foreach ($s in $Service) {
    try { Stop-Service $s -Force -ErrorAction Stop; $stopped.Add($s); Write-Step "$s stopped" }
    catch { Write-Step ('{0} STOP ERROR: {1}' -f $s, $_.Exception.Message) 'Yellow' }
}
Start-Sleep -Seconds 3

Write-Step ('--- detaching the source ({0}:) ---' -f $sourceLetter)
try {
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
    Write-Step 'source detached'
} catch {
    Write-Step ('DETACH FAILED: {0}' -f $_.Exception.Message) 'Red'
    Write-Step 'Something still holds the volume — a shell whose current directory is on it,' 'Yellow'
    Write-Step 'an editor with the checkout open, or a background agent. Close them and re-run' 'Yellow'
    Write-Step 'with -SwapOnly; the verified replacement is kept and costs nothing to reuse.' 'Yellow'
    foreach ($s in $stopped) { Start-Service $s -ErrorAction SilentlyContinue }
    Save-Transcript
    throw
}

try {
    Write-Step '--- renaming: source -> .old, replacement -> source ---'
    if (Test-Path $oldVhdxPath) { throw "a previous backup is in the way: $oldVhdxPath" }
    Rename-Item -LiteralPath $VhdxPath -NewName (Split-Path $oldVhdxPath -Leaf) -ErrorAction Stop
    Rename-Item -LiteralPath $NewVhdxPath -NewName (Split-Path $VhdxPath -Leaf) -ErrorAction Stop

    Write-Step '--- attaching the replacement ---'
    Mount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
    $disk = Get-DiskImage -ImagePath $VhdxPath | Get-Disk
    $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
    if ($part.DriveLetter -ne $sourceLetter) {
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $sourceLetter -ErrorAction Stop
    }
    Start-Sleep -Seconds 3
    Write-Step ('attached as {0}:' -f $sourceLetter) 'Green'
} catch {
    Write-Step ('SWAP FAILED: {0}' -f $_.Exception.Message) 'Red'
    Write-Step '--- rolling back to the original disk ---' 'Yellow'
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null
    if ((Test-Path $oldVhdxPath) -and -not (Test-Path $NewVhdxPath)) {
        Rename-Item -LiteralPath $VhdxPath -NewName (Split-Path $NewVhdxPath -Leaf) -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $oldVhdxPath -NewName (Split-Path $VhdxPath -Leaf) -ErrorAction SilentlyContinue
    }
    Mount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null
    foreach ($s in $stopped) { Start-Service $s -ErrorAction SilentlyContinue }
    Save-Transcript
    throw
}

# --- result -------------------------------------------------------------------

$verified = $true
if ($VerifyPath) {
    $verified = Test-Path $VerifyPath
    Write-Step ('verify path {0}: {1}' -f $VerifyPath, $verified) $(if ($verified) { 'Green' } else { 'Red' })
}

$physicalAfter = (Get-Item $VhdxPath).Length
$freeAfter = (Get-PSDrive $hostDrive).Free
Write-Step ('replacement : {0:N1} GB physical (was {1:N1} GB)' -f ($physicalAfter / 1GB), ($physicalBefore / 1GB))
Write-Step ('host {0}: free : {1:N1} GB (was {2:N1} GB)' -f $hostDrive, ($freeAfter / 1GB), ($freeBefore / 1GB))

if ($RetireOld -and $verified) {
    Write-Step ('--- deleting the old disk: {0} ---' -f $oldVhdxPath)
    Remove-Item -LiteralPath $oldVhdxPath -Force -ErrorAction Stop
    Write-Step ('host {0}: free : {1:N1} GB after retiring the old disk' -f $hostDrive, ((Get-PSDrive $hostDrive).Free / 1GB)) 'Green'
} else {
    Write-Step ('old disk kept: {0} ({1:N1} GB)' -f $oldVhdxPath, ($physicalBefore / 1GB)) 'Cyan'
    Write-Step 'The space is NOT reclaimed until it is deleted. Check the volume, then:' 'Cyan'
    Write-Step ('  Remove-Item -LiteralPath "{0}" -Force' -f $oldVhdxPath) 'Cyan'
    if (-not $verified) { Write-Step 'verification FAILED — do not delete it, roll back instead.' 'Red' }
}

Write-Step '--- starting services ---'
[array]::Reverse($stopped)
foreach ($s in $stopped) {
    try { Start-Service $s -ErrorAction Stop; Write-Step ('{0} : {1}' -f $s, (Get-Service $s).Status) }
    catch { Write-Step ('{0} START ERROR: {1}' -f $s, $_.Exception.Message) 'Red' }
}

Write-Step 'done' 'Green'
Save-Transcript
