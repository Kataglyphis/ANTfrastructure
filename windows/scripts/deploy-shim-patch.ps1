# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Installs a locally built containerd-shim binary over the one Stevedore ships,
# keeping a timestamped backup, and optionally sets environment variables on the
# containerd service (the shim inherits containerd's environment).
#
# WHY THIS EXISTS: this host class needs a patched runhcs shim - the stock one
# hardcodes a 30s container teardown timeout, which on filesystem-heavy WCOW
# builds terminates the container mid-hive-flush and leaves the scratch
# permanently unexportable (hcsshim::ExportLayer 0x3). Full story:
# docs/windows-builds.md, upstream submission: windows/upstream/.
# EVERY Stevedore/containerd update silently overwrites the patched binary and
# brings the defect back, so this script is run repeatedly, not once.
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running - the service
# stop kills every in-flight solve, and the binary cannot be replaced while a
# shim process holds it. The script refuses on both unless -Force is passed.
#
# Examples:
#
#   # what is installed right now, which backups exist - changes nothing
#   pwsh -File windows\scripts\deploy-shim-patch.ps1 -ReportOnly
#
#   # deploy a build that hardcodes the longer timeouts
#   pwsh -File windows\scripts\deploy-shim-patch.ps1 -ShimPath C:\src\hcsshim\containerd-shim-runhcs-v1.exe
#
#   # deploy the upstream-shaped build, which needs the env var to do anything
#   pwsh -File windows\scripts\deploy-shim-patch.ps1 -ShimPath C:\src\shim.exe `
#        -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=45m
#
#   # put the stock binary back
#   pwsh -File windows\scripts\deploy-shim-patch.ps1 -Restore .orig
#
# VERIFYING THE RESULT: the shim logs its effective timeout at Debug level only,
# which does NOT reach containerd's log on a default setup - so a quiet log is
# NOT proof the deployment worked. The reliable check is behavioural: run a
# filesystem-heavy container (the OpenCV canary in docs/windows-builds.md) and
# confirm it finalizes and exports without 0x3. A disposable canary snapshot is
# the right thing to risk; a chain run is not.

#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The newly built shim binary to install. Required unless -ReportOnly or
    # -Restore is used.
    [string]$ShimPath = '',

    # Where the live binary sits. Stevedore's default install location.
    [string]$InstallPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",

    # Environment entries ('NAME=value') to set on -EnvironmentService. Existing
    # entries are preserved; entries with the same name are replaced.
    [string[]]$ServiceEnvironment = @(),

    # The service whose environment the shim inherits.
    [string]$EnvironmentService = 'containerd',

    # Services stopped for the swap, in order. Restarted in reverse.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes whose presence means a build is live.
    [string[]]$BlockingProcess = @('buildctl'),

    # Restore a previously kept binary instead of installing a new one. Give the
    # backup's suffix, e.g. '.orig' (stock) or '.45min'. Use -ReportOnly to list.
    [string]$Restore = '',

    # Report installed binary, backups and service environment, then exit.
    [switch]$ReportOnly,

    # Skip the live-build and live-shim guards.
    [switch]$Force,

    # Transcript destination. Default: <repo>\out\deploy-shim-patch.log
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $LogPath) { $LogPath = Join-Path $repoRoot 'out\deploy-shim-patch.log' }

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

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$EnvironmentService"

# --- report ------------------------------------------------------------------

function Show-State {
    if (Test-Path $InstallPath) {
        $item = Get-Item $InstallPath
        Write-Step ('installed : {0:N0} bytes, {1}' -f $item.Length, $item.LastWriteTime)
    } else {
        Write-Step "installed : MISSING at $InstallPath" 'Red'
    }

    $backups = @(Get-ChildItem "$InstallPath.*" -ErrorAction SilentlyContinue)
    if ($backups.Count -gt 0) {
        foreach ($b in $backups) {
            Write-Step ('backup    : {0,-12} {1,14:N0} bytes, {2}' -f $b.Extension, $b.Length, $b.LastWriteTime)
        }
    } else {
        Write-Step 'backup    : none'
    }

    try {
        $current = (Get-ItemProperty $svcKey -ErrorAction Stop).Environment
        if ($current) {
            foreach ($e in $current) { Write-Step "env       : $e" }
        } else {
            Write-Step "env       : $EnvironmentService has no Environment value"
        }
    } catch {
        Write-Step ("env       : cannot read {0} ({1})" -f $svcKey, $_.Exception.Message) 'Yellow'
    }
}

# --- guards ------------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($ReportOnly) {
    Write-Step 'ReportOnly - nothing will be changed'
    if (-not $isAdmin) { Write-Step 'not elevated: the service environment may read as unavailable' 'Yellow' }
    Show-State
    Save-Transcript
    return
}

if (-not $isAdmin) { throw 'Run from an elevated (admin) shell: replacing the binary and controlling services needs it.' }

if ($Restore -and $ShimPath) { throw 'Pass either -ShimPath or -Restore, not both.' }

$source = $ShimPath
if ($Restore) {
    $source = "$InstallPath$Restore"
    if (-not (Test-Path $source)) { throw "no such backup: $source (use -ReportOnly to list)" }
} elseif (-not $source) {
    throw 'Nothing to do: pass -ShimPath, -Restore or -ReportOnly.'
} elseif (-not (Test-Path $source)) {
    throw "shim binary not found: $source"
}

Write-Step '--- before ---'
Show-State
Write-Step ('source    : {0:N0} bytes  {1}' -f (Get-Item $source).Length, $source)

if (-not $Force) {
    $live = @(Get-Process -Name $BlockingProcess -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0) {
        Save-Transcript
        throw ("{0} live process(es) ({1}) - stopping the build services kills their solves. Wait, or pass -Force." -f
            $live.Count, (($live | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '))
    }
    $shims = @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($InstallPath)) -ErrorAction SilentlyContinue)
    if ($shims.Count -gt 0) {
        Save-Transcript
        throw ("{0} shim process(es) alive (pids: {1}) - containers are still running and the binary is locked." -f
            $shims.Count, (($shims | ForEach-Object Id) -join ', '))
    }
}

if (-not $PSCmdlet.ShouldProcess($InstallPath, "stop [$($Service -join ', ')], replace binary, restart")) { return }

# --- stop --------------------------------------------------------------------

Write-Step '--- stopping services ---'
$stopped = [System.Collections.Generic.List[string]]::new()
foreach ($s in $Service) {
    try { Stop-Service $s -Force -ErrorAction Stop; $stopped.Add($s); Write-Step "$s stopped" }
    catch { Write-Step ('{0} STOP ERROR: {1}' -f $s, $_.Exception.Message) 'Yellow' }
}
Start-Sleep -Seconds 3

# --- swap --------------------------------------------------------------------
#
# The backup is timestamped so repeated deployments never silently discard the
# binary that was working. .orig is left alone once it exists - it is the only
# copy of the untouched stock shim.

$swapped = $false
try {
    if (-not $Restore) {
        $stockBackup = "$InstallPath.orig"
        if (-not (Test-Path $stockBackup)) {
            Copy-Item $InstallPath $stockBackup -Force -ErrorAction Stop
            Write-Step "stock binary preserved as $stockBackup"
        }
        $stamp = "$InstallPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $InstallPath $stamp -Force -ErrorAction Stop
        Write-Step "previous binary preserved as $stamp"
    }
    Copy-Item $source $InstallPath -Force -ErrorAction Stop
    $swapped = $true
    Write-Step ('installed {0:N0} bytes' -f (Get-Item $InstallPath).Length) 'Green'
} catch {
    Write-Step ('SWAP ERROR: {0}' -f $_.Exception.Message) 'Red'
}

# --- service environment -----------------------------------------------------

if ($swapped -and $ServiceEnvironment.Count -gt 0) {
    Write-Step "--- setting environment on $EnvironmentService ---"
    try {
        $existing = @((Get-ItemProperty $svcKey -ErrorAction Stop).Environment)
        $names = $ServiceEnvironment | ForEach-Object { ($_ -split '=', 2)[0] }
        $kept = @($existing | Where-Object { $_ -and (($_ -split '=', 2)[0]) -notin $names })
        if ($kept.Count -gt 0) { Write-Step ('preserved: ' + ($kept -join ' | ')) }
        $merged = $kept + $ServiceEnvironment
        Set-ItemProperty -Path $svcKey -Name Environment -Type MultiString -Value $merged -ErrorAction Stop
        Write-Step ('environment now: ' + ((Get-ItemProperty $svcKey).Environment -join ' | ')) 'Green'
    } catch {
        Write-Step ('ENV ERROR: {0}' -f $_.Exception.Message) 'Red'
    }
}

# --- start -------------------------------------------------------------------

Write-Step '--- starting services ---'
[array]::Reverse($stopped)
foreach ($s in $stopped) {
    try { Start-Service $s -ErrorAction Stop; Write-Step ('{0} : {1}' -f $s, (Get-Service $s).Status) }
    catch { Write-Step ('{0} START ERROR: {1}' -f $s, $_.Exception.Message) 'Red' }
}

Write-Step '--- after ---'
Show-State
Write-Step 'NOT YET PROVEN: a quiet log does not confirm the deployment took effect.' 'Yellow'
Write-Step 'Verify behaviourally with the OpenCV canary (docs/windows-builds.md).' 'Yellow'
Save-Transcript
