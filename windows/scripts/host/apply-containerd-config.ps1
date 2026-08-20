#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Makes the CONTAINERD side of the Windows container lane reproducible.
#
# WHY THIS EXISTS: buildkitd's configuration is version-controlled
# (windows/buildkitd.toml) and deployed by apply-buildkitd-gcpolicy.ps1.
# containerd's was not — an audit on 2026-08-07 found the reference host
# running containerd with NO config.toml at all, every setting living only in
# the service's ImagePath registry value. That means a fresh machine gets
# whatever the Stevedore installer chose, and the debug logging this project's
# whole diagnostic workflow depends on has to be re-applied from memory. The
# settings below ARE the configuration; this script is their source of truth.
#
# What it configures:
#   * --log-level debug + --log-file  — permanent owner policy. The containerd
#     debug log is what root-caused the ExportLayer 0x3 defect (the missing
#     "timed out waiting for container shutdown" line is what proved the
#     patched shim was active). TRUNCATE it when it grows; never disable.
#   * CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT — the runhcs shim inherits
#     the service environment. Required by any shim built from the upstream
#     patch (microsoft/hcsshim#2855), whose defaults are unchanged at 30s: set
#     the wrong name, or none, and the shim silently keeps 30s and the 0x3
#     defect returns. Not needed by a fixed-constant build, harmless there.
#   * Defender exclusions — load-bearing for the hcs-temp finalize/export flake
#     family (see docs/windows-builds.md). Reported here because they are
#     otherwise invisible: Get-MpPreference needs admin, so nothing tells you
#     if they were lost.
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running: applying any
# change restarts containerd, which kills every in-flight solve. The script
# refuses unless -Force.
#
#   pwsh -File windows\scripts\host\apply-containerd-config.ps1 -ReportOnly   # inspect
#   pwsh -File windows\scripts\host\apply-containerd-config.ps1               # apply
#   pwsh -File windows\scripts\host\apply-containerd-config.ps1 -TeardownTimeout ''  # drop the env var

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ServiceName = 'containerd',
    [string]$LogLevel = 'debug',
    [string]$LogFile = 'C:\ProgramData\containerd\containerd-debug.log',
    # Value for CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT. Empty string
    # REMOVES it (use when running a fixed-constant shim build and you want the
    # environment clean). The companion TASK_CLOSE_TIMEOUT is deliberately not
    # set: the upstream patch derives it as 2x teardown + 30s precisely so no
    # one has to keep two coupled values in step by hand.
    [string]$TeardownTimeout = '45m',
    [string[]]$ExclusionPath = @(
        'C:\ProgramData\containerd',
        'C:\ProgramData\buildkitd',
        'C:\ProgramData\nerdctl'
    ),
    [switch]$SkipDefenderExclusions,
    # CNI conf directory. The .conflist here is the AUTHORED file; the .conf is
    # derived from it (see the CNI section below) so the two forms buildkitd and
    # nerdctl each require cannot drift apart in content.
    [string]$CniConfDir = 'C:\Program Files\containerd\cni\conf',
    [switch]$SkipCniSync,
    [string[]]$BlockingProcess = @('buildctl', 'containerd-shim-runhcs-v1'),
    [switch]$ReportOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

function Write-Step {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

# --- report -------------------------------------------------------------------

if (-not (Test-Path $svcKey)) { throw "service '$ServiceName' not found (looked at $svcKey)" }
$current = Get-ItemProperty $svcKey

Write-Step ('service    : {0} ({1})' -f $ServiceName, (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status)
Write-Step ('ImagePath  : {0}' -f $current.ImagePath)
$currentEnv = @(if ($current.PSObject.Properties.Name -contains 'Environment') { $current.Environment } else { @() })
Write-Step ('Environment: {0}' -f $(if ($currentEnv.Count) { $currentEnv -join '; ' } else { '(none)' }))
if (Test-Path $LogFile) {
    Write-Step ('debug log  : {0:N1} MB  {1}' -f ((Get-Item $LogFile).Length / 1MB), $LogFile)
} else {
    Write-Step ('debug log  : not present yet ({0})' -f $LogFile)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# --- CNI: the .conflist is AUTHORED, the .conf is DERIVED ---------------------
# The host must carry both forms — buildkitd reads the .conf, nerdctl reads the
# .conflist, and each breaks silently without its own (2026-08-07: a "conversion"
# to conflist-only left BuildKit containers with no network adapter and cost a
# launched chain). Keeping them as two hand-edited copies is the two-copies-drift
# this repo eliminates everywhere else: Get-CniConfFormIssue guards PRESENCE, but
# nothing stopped the CONTENT diverging, so a subnet edit applied to one file
# would hand the two clients different networks.
#
# Deriving removes the failure mode instead of policing it. The conflist stays
# the single authored file; this rewrites the .conf from it whenever they differ.
if (-not $SkipCniSync) {
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
    $cniModule = Join-Path $scriptAssetRoot 'modules\WindowsBuildKit.Common.psm1'
    if (-not (Test-Path $cniModule)) { throw "required module not found: $cniModule" }
    Import-Module $cniModule -Force

    $confListPath = Join-Path $CniConfDir '0-containerd-nat.conflist'
    $confPath = Join-Path $CniConfDir '0-containerd-nat.conf'
    if (-not (Test-Path $confListPath)) {
        Write-Step "cni        : no $confListPath - nothing to derive from (see docs/windows-host-setup.md A5)" 'Yellow'
    } else {
        $derived = ConvertFrom-CniConfList -ConfListText (Get-Content $confListPath -Raw)
        $existing = if (Test-Path $confPath) { (Get-Content $confPath -Raw) } else { '' }
        # Compare CANONICALLY — sorted keys, no whitespace. The first version of
        # this check compared `ConvertFrom-Json | ConvertTo-Json`, which
        # preserves parse order, and duly reported the reference host as out of
        # sync when the two files were identical apart from field order. A guard
        # that cries wolf gets ignored.
        $same = $false
        if ($existing) {
            try {
                $same = ((ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json $existing)) -eq
                         (ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json $derived)))
            } catch { $same = $false }
        }
        if ($same) {
            Write-Step 'cni        : .conf matches the .conflist (derived, in sync)'
        } elseif ($ReportOnly) {
            Write-Step "cni        : .conf is OUT OF SYNC with the .conflist - run without -ReportOnly to rewrite it" 'Yellow'
        } elseif (-not $isAdmin) {
            Write-Step "cni        : .conf out of sync but writing $CniConfDir needs admin" 'Yellow'
        } elseif ($PSCmdlet.ShouldProcess($confPath, 'rewrite from the .conflist')) {
            Set-Content -Path $confPath -Value $derived -Encoding ascii
            Write-Step "cni        : rewrote $confPath from the .conflist - restart buildkitd to pick it up" 'Green'
        }
    }
}

if (-not $SkipDefenderExclusions) {
    if ($isAdmin) {
        $have = @((Get-MpPreference).ExclusionPath)
        foreach ($p in $ExclusionPath) {
            $ok = $have -contains $p
            Write-Step ("exclusion  : {0,-32} {1}" -f $p, $(if ($ok) { 'present' } else { 'MISSING' })) $(if ($ok) { 'Gray' } else { 'Yellow' })
        }
    } else {
        Write-Step 'exclusions : need admin to read (Get-MpPreference)' 'Yellow'
    }
}

# Desired ImagePath: the binary + its flags, with log settings normalised.
$exe = if ($current.ImagePath -match '^\s*"([^"]+)"') { $Matches[1] } else { ($current.ImagePath -split '\s+')[0] }
$desiredImagePath = '"{0}" --run-service --service-name {1} --log-level {2} --log-file {3}' -f
    $exe, $ServiceName, $LogLevel, $LogFile

$desiredEnv = @($currentEnv | Where-Object { $_ -notmatch '^CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=' })
if ($TeardownTimeout) { $desiredEnv += "CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=$TeardownTimeout" }

$imagePathDrift = ($current.ImagePath.Trim() -ne $desiredImagePath)
$envDrift = ((($currentEnv | Sort-Object) -join '|') -ne (($desiredEnv | Sort-Object) -join '|'))

Write-Step ('ImagePath drift : {0}' -f $imagePathDrift) $(if ($imagePathDrift) { 'Yellow' } else { 'Green' })
Write-Step ('Environment drift: {0}' -f $envDrift) $(if ($envDrift) { 'Yellow' } else { 'Green' })

if ($ReportOnly) {
    if ($imagePathDrift) { Write-Step ('would set  : {0}' -f $desiredImagePath) 'Cyan' }
    if ($envDrift) { Write-Step ('would set  : {0}' -f ($desiredEnv -join '; ')) 'Cyan' }
    Write-Step 'ReportOnly: nothing changed.' 'Cyan'
    return
}

# --- apply --------------------------------------------------------------------

if (-not $isAdmin) { throw 'Run from an elevated (admin) shell: service configuration and Defender exclusions need it.' }

$live = @(Get-Process -Name $BlockingProcess -ErrorAction SilentlyContinue)
if ($live.Count -gt 0 -and -not $Force) {
    throw ('{0} live build process(es) ({1}) - applying restarts containerd and kills every in-flight solve. ' -f
        $live.Count, (($live | ForEach-Object ProcessName | Sort-Object -Unique) -join ', ')) +
        'Wait for the build to finish, or pass -Force.'
}

if (-not $SkipDefenderExclusions) {
    foreach ($p in $ExclusionPath) {
        if (@((Get-MpPreference).ExclusionPath) -notcontains $p) {
            if ($PSCmdlet.ShouldProcess($p, 'Add-MpPreference -ExclusionPath')) {
                Add-MpPreference -ExclusionPath $p
                Write-Step ("exclusion added: $p") 'Green'
            }
        }
    }
}

if (-not $imagePathDrift -and -not $envDrift) {
    Write-Step 'service configuration already correct - no restart needed.' 'Green'
    return
}

if (-not $PSCmdlet.ShouldProcess($ServiceName, 'update service configuration and restart')) { return }

if ($imagePathDrift) {
    Set-ItemProperty -Path $svcKey -Name ImagePath -Value $desiredImagePath
    Write-Step ('ImagePath set: {0}' -f $desiredImagePath) 'Green'
}
if ($envDrift) {
    if ($desiredEnv.Count) {
        Set-ItemProperty -Path $svcKey -Name Environment -Value ([string[]]$desiredEnv) -Type MultiString
        Write-Step ('Environment set: {0}' -f ($desiredEnv -join '; ')) 'Green'
    } elseif ($current.PSObject.Properties.Name -contains 'Environment') {
        Remove-ItemProperty -Path $svcKey -Name Environment
        Write-Step 'Environment removed' 'Green'
    }
}

# -Force on Restart-Service: a plain restart is refused when dependents exist
# (the same fix apply-buildkitd-gcpolicy.ps1 needed).
Restart-Service $ServiceName -Force
Start-Sleep -Seconds 3
Write-Step ('{0}: {1}' -f $ServiceName, (Get-Service $ServiceName).Status) 'Green'
Write-Step 'NOTE: the runhcs shim picks up the new environment per CONTAINER, so no further restart is needed.' 'Cyan'
