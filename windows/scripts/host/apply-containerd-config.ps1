#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Source of truth for the containerd side: it runs with NO config.toml here, so the
# debug flags, the shim teardown env var and the Defender exclusions below ARE the
# configuration and live only in the service's registry values.
# Admin, and NEVER while a build solves: applying restarts containerd (refuses unless -Force).
# What each setting is for: docs/windows-host-setup.md § C1.

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ServiceName = 'containerd',
    [string]$LogLevel = 'debug',
    [string]$LogFile = 'C:\ProgramData\containerd\containerd-debug.log',
    # CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT; empty string REMOVES it. The
    # companion TASK_CLOSE_TIMEOUT stays unset on purpose - upstream derives it
    # as 2x teardown + 30s, so the two values cannot fall out of step by hand.
    # 45m -> 5m (2026-09-01): under the lost-notification regression the 45 min
    # became a flat tax on EVERY RUN (2841.2 s vs 441.3 s measured); 5m still
    # covers the legitimate 117 s worst case 2.5x. A drift-repair run with the
    # old default silently restored 45m - that is exactly how the regression
    # would come back with every gate green (audit finding 2026-09-01).
    [string]$TeardownTimeout = '5m',
    [string[]]$ExclusionPath = @(
        'C:\ProgramData\containerd',
        'C:\ProgramData\buildkitd',
        'C:\ProgramData\nerdctl'
    ),
    [switch]$SkipDefenderExclusions,
    # CNI conf directory: the .conflist here is AUTHORED, the .conf DERIVED from it.
    [string]$CniConfDir = 'C:\Program Files\containerd\cni\conf',
    [switch]$SkipCniSync,
    [string[]]$BlockingProcess = @('buildctl', 'containerd-shim-runhcs-v1'),
    [switch]$ReportOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #108: shared assets sit beside this script in the FLAT container mount and one
# level up in the repo's scripts/<group>/ layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }

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
# The host needs BOTH forms - buildkitd reads the .conf, nerdctl the .conflist -
# and each breaks silently without its own; deriving keeps their CONTENT from
# drifting (docs/windows-build-invariants.md § CNI .conf is DERIVED).
if (-not $SkipCniSync) {
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
        # Canonical compare (sorted keys, no whitespace): a round-trip through
        # ConvertTo-Json preserves parse order and cries wolf on field-order diffs.
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

# -Force: a plain Restart-Service is refused when dependents exist.
Restart-Service $ServiceName -Force
Start-Sleep -Seconds 3
Write-Step ('{0}: {1}' -f $ServiceName, (Get-Service $ServiceName).Status) 'Green'
Write-Step 'NOTE: the runhcs shim picks up the new environment per CONTAINER, so no further restart is needed.' 'Cyan'
