#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# containerd runs without config.toml, so its service registry values are the config: see docs/windows-host-setup.md § C1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ServiceName = 'containerd',
    [string]$LogLevel = 'debug',
    [string]$LogFile = 'C:\ProgramData\containerd\containerd-debug.log',
    # The shim teardown timeout (a Go duration; empty removes it); TASK_CLOSE_TIMEOUT stays unset so upstream derives it.
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

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1')
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1')

function Write-ContainerdCurrentReport {
    param([string]$Name, $Current, [string[]]$CurrentEnvironment, [string]$LogPath)
    Write-HostMaintenanceMessage ('service    : {0} ({1})' -f $Name, (Get-Service $Name -ErrorAction SilentlyContinue).Status)
    Write-HostMaintenanceMessage ('ImagePath  : {0}' -f $Current.ImagePath)
    Write-HostMaintenanceMessage ('Environment: {0}' -f $(if ($CurrentEnvironment.Count) { $CurrentEnvironment -join '; ' } else { '(none)' }))
    if (Test-Path $LogPath) {
        Write-HostMaintenanceMessage ('debug log  : {0:N1} MB  {1}' -f ((Get-Item $LogPath).Length / 1MB), $LogPath)
    } else {
        Write-HostMaintenanceMessage ('debug log  : not present yet ({0})' -f $LogPath)
    }
}

function Sync-ContainerdCni {
    param([string]$ModuleRoot, [string]$ConfDir, [bool]$Report, [bool]$IsAdmin, [scriptblock]$Approve)
    $cniModule = Join-Path $ModuleRoot 'modules\WindowsBuildKit.Common.psm1'
    if (-not (Test-Path $cniModule)) { throw "required module not found: $cniModule" }
    Import-Module $cniModule -Force

    $confListPath = Join-Path $ConfDir '0-containerd-nat.conflist'
    $confPath = Join-Path $ConfDir '0-containerd-nat.conf'
    if (-not (Test-Path $confListPath)) {
        Write-HostMaintenanceMessage "cni        : no $confListPath - nothing to derive from (see docs/windows-host-setup.md A5)" 'Yellow'
        return
    }
    $derived = ConvertFrom-CniConfList -ConfListText (Get-Content $confListPath -Raw)
    $existing = if (Test-Path $confPath) { (Get-Content $confPath -Raw) } else { '' }
    # Canonical compare: a ConvertTo-Json round-trip keeps field order and would flag order-only diffs.
    $same = $false
    if ($existing) {
        try {
            $same = ((ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json $existing)) -eq
                     (ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json $derived)))
        } catch { $same = $false }
    }
    if ($same) {
        Write-HostMaintenanceMessage 'cni        : .conf matches the .conflist (derived, in sync)'
    } elseif ($Report) {
        Write-HostMaintenanceMessage "cni        : .conf is OUT OF SYNC with the .conflist - run without -ReportOnly to rewrite it" 'Yellow'
    } elseif (-not $IsAdmin) {
        Write-HostMaintenanceMessage "cni        : .conf out of sync but writing $ConfDir needs admin" 'Yellow'
    } elseif (& $Approve $confPath 'rewrite from the .conflist') {
        Set-Content -Path $confPath -Value $derived -Encoding ascii
        Write-HostMaintenanceMessage "cni        : rewrote $confPath from the .conflist - restart buildkitd to pick it up" 'Green'
    }
}

function Write-ContainerdExclusionReport {
    param([bool]$IsAdmin, [string[]]$Path)
    if ($IsAdmin) {
        $have = @((Get-MpPreference).ExclusionPath)
        foreach ($p in $Path) {
            $ok = $have -contains $p
            Write-HostMaintenanceMessage ("exclusion  : {0,-32} {1}" -f $p, $(if ($ok) { 'present' } else { 'MISSING' })) $(if ($ok) { 'Gray' } else { 'Yellow' })
        }
    } else {
        Write-HostMaintenanceMessage 'exclusions : need admin to read (Get-MpPreference)' 'Yellow'
    }
}

function Get-ContainerdDesiredConfiguration {
    param($Current, [string[]]$CurrentEnvironment, [string]$Name, [string]$Level, [string]$LogPath, [string]$Timeout)
    $exe = if ($Current.ImagePath -match '^\s*"([^"]+)"') { $Matches[1] } else { ($Current.ImagePath -split '\s+')[0] }
    $desiredImagePath = '"{0}" --run-service --service-name {1} --log-level {2} --log-file {3}' -f $exe, $Name, $Level, $LogPath
    $desiredEnv = @($CurrentEnvironment | Where-Object { $_ -notmatch '^CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=' })
    if ($Timeout) { $desiredEnv += "CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=$Timeout" }
    return [pscustomobject]@{
        ImagePath = $desiredImagePath
        Environment = $desiredEnv
        ImagePathDrift = ($Current.ImagePath.Trim() -ne $desiredImagePath)
        EnvironmentDrift = ((($CurrentEnvironment | Sort-Object) -join '|') -ne (($desiredEnv | Sort-Object) -join '|'))
    }
}

function Write-ContainerdDriftReport {
    param($Desired)
    Write-HostMaintenanceMessage ('ImagePath drift : {0}' -f $Desired.ImagePathDrift) $(if ($Desired.ImagePathDrift) { 'Yellow' } else { 'Green' })
    Write-HostMaintenanceMessage ('Environment drift: {0}' -f $Desired.EnvironmentDrift) $(if ($Desired.EnvironmentDrift) { 'Yellow' } else { 'Green' })
}

function Add-ContainerdDefenderExclusions {
    param([string[]]$Path, [scriptblock]$Approve)
    foreach ($p in $Path) {
        if (@((Get-MpPreference).ExclusionPath) -notcontains $p) {
            if (& $Approve $p 'Add-MpPreference -ExclusionPath') {
                Add-MpPreference -ExclusionPath $p
                Write-HostMaintenanceMessage ("exclusion added: $p") 'Green'
            }
        }
    }
}

function Set-ContainerdServiceValues {
    param([string]$ServiceKey, $Current, $Desired)
    if ($Desired.ImagePathDrift) {
        Set-ItemProperty -Path $ServiceKey -Name ImagePath -Value $Desired.ImagePath
        Write-HostMaintenanceMessage ('ImagePath set: {0}' -f $Desired.ImagePath) 'Green'
    }
    if ($Desired.EnvironmentDrift) {
        if ($Desired.Environment.Count) {
            Set-ItemProperty -Path $ServiceKey -Name Environment -Value ([string[]]$Desired.Environment) -Type MultiString
            Write-HostMaintenanceMessage ('Environment set: {0}' -f ($Desired.Environment -join '; ')) 'Green'
        } elseif ($Current.PSObject.Properties.Name -contains 'Environment') {
            Remove-ItemProperty -Path $ServiceKey -Name Environment
            Write-HostMaintenanceMessage 'Environment removed' 'Green'
        }
    }
}

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

# --- report -------------------------------------------------------------------

if (-not (Test-Path $svcKey)) { throw "service '$ServiceName' not found (looked at $svcKey)" }
$current = Get-ItemProperty $svcKey

$currentEnv = @(if ($current.PSObject.Properties.Name -contains 'Environment') { $current.Environment } else { @() })
Write-ContainerdCurrentReport -Name $ServiceName -Current $current -CurrentEnvironment $currentEnv -LogPath $LogFile

$isAdmin = Test-Elevated
$approve = { param($target, $action) $PSCmdlet.ShouldProcess($target, $action) }.GetNewClosure()

# CNI: see docs/windows-build-invariants.md § The CNI .conf is DERIVED from the .conflist
if (-not $SkipCniSync) {
    Sync-ContainerdCni -ModuleRoot $scriptAssetRoot -ConfDir $CniConfDir -Report:$ReportOnly -IsAdmin:$isAdmin -Approve $approve
}

if (-not $SkipDefenderExclusions) {
    Write-ContainerdExclusionReport -IsAdmin:$isAdmin -Path $ExclusionPath
}

# Desired ImagePath: the binary + its flags, with log settings normalised.
$desired = Get-ContainerdDesiredConfiguration -Current $current -CurrentEnvironment $currentEnv -Name $ServiceName -Level $LogLevel -LogPath $LogFile -Timeout $TeardownTimeout
$imagePathDrift = $desired.ImagePathDrift
$envDrift = $desired.EnvironmentDrift
Write-ContainerdDriftReport -Desired $desired

if ($ReportOnly) {
    if ($imagePathDrift) { Write-HostMaintenanceMessage ('would set  : {0}' -f $desired.ImagePath) 'Cyan' }
    if ($envDrift) { Write-HostMaintenanceMessage ('would set  : {0}' -f ($desired.Environment -join '; ')) 'Cyan' }
    Write-HostMaintenanceMessage 'ReportOnly: nothing changed.' 'Cyan'
    return
}

# --- apply --------------------------------------------------------------------

if (-not $isAdmin) { throw 'Run from an elevated (admin) shell: service configuration and Defender exclusions need it.' }

$null = Get-HostMaintenanceProcess -Name $BlockingProcess -Force:$Force `
    -FailureTemplate '{0} live build process(es) ({1}) - applying restarts containerd and kills every in-flight solve. Wait for the build to finish, or pass -Force.'

if (-not $SkipDefenderExclusions) {
    Add-ContainerdDefenderExclusions -Path $ExclusionPath -Approve $approve
}

if (-not $imagePathDrift -and -not $envDrift) {
    Write-HostMaintenanceMessage 'service configuration already correct - no restart needed.' 'Green'
    return
}

if (-not $PSCmdlet.ShouldProcess($ServiceName, 'update service configuration and restart')) { return }

Set-ContainerdServiceValues -ServiceKey $svcKey -Current $current -Desired $desired

# -Force: a plain Restart-Service is refused when dependents exist.
Restart-Service $ServiceName -Force
Start-Sleep -Seconds 3
Write-HostMaintenanceMessage ('{0}: {1}' -f $ServiceName, (Get-Service $ServiceName).Status) 'Green'
Write-HostMaintenanceMessage 'NOTE: the runhcs shim picks up the new environment per CONTAINER, so no further restart is needed.' 'Cyan'
