#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Hold the machine awake while a long benchmark runs, then release it.

.DESCRIPTION
    A multi-hour benchmark makes no power request. Windows sees background HTTP
    traffic and a busy NPU as an idle system, so it enters Modern Standby on
    schedule -- and this host does not reliably come back from it while a GenieX
    lane holds a model.

    That is not hypothetical. On 2026-09-03 a 27-task run was left unattended;
    the WLAN log shows `sleep, SLPM Exit, display off` cycling once a minute
    until 03:53, when the machine had to be powered off by hand (Kernel-Power
    event 41, BugcheckCode 0, no crash dump -- a hang, not a bluescreen). Idle
    timeouts on this host are 5 h on AC and 10 MINUTES on battery.

    SetThreadExecutionState is the right mechanism: it is scoped to this
    process, so a crash or Ctrl-C releases the request automatically. Changing
    the power scheme instead would survive the run and silently leave the
    machine unable to sleep.

    -ExecutionPolicy Bypass is required when this file is reached over a UNC
    path -- which is what \\wsl.localhost\... is, and this repository lives in
    WSL. Without it Windows refuses the unsigned script, and launched hidden
    (Start-Process -WindowStyle Hidden) the SecurityError is never seen: the
    launcher reports success and no guard is running. Confirm with
    `Get-Process pwsh` rather than trusting the launch.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File windows/scripts/host/Disable-Sleep.ps1 -Command "bash run-sweep.sh"

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File windows/scripts/host/Disable-Sleep.ps1 -Minutes 180
    Holds the machine awake for three hours, for a run started elsewhere.
#>
[CmdletBinding(DefaultParameterSetName = 'Duration')]
param(
    [Parameter(ParameterSetName = 'Command', Mandatory)][string]$Command,
    [Parameter(ParameterSetName = 'Duration')][int]$Minutes = 120,
    [switch]$KeepDisplayOn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace Kataglyphis -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

# The `u` suffix matters: PowerShell parses a bare 0x80000000 as Int32, which
# overflows to -2147483648 and fails the [uint32] cast.
$ES_CONTINUOUS       = 0x80000000u
$ES_SYSTEM_REQUIRED  = 0x00000001u
$ES_DISPLAY_REQUIRED = 0x00000002u

$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
if ($KeepDisplayOn) { $flags = $flags -bor $ES_DISPLAY_REQUIRED }

if ([Kataglyphis.Power]::SetThreadExecutionState($flags) -eq 0) {
    throw 'SetThreadExecutionState failed; the machine may still sleep mid-run'
}
Write-Host 'Sleep suppressed for this process.' -ForegroundColor Green
Write-Host 'Verify from another shell with:  powercfg /requests' -ForegroundColor DarkGray

try {
    if ($PSCmdlet.ParameterSetName -eq 'Command') {
        Write-Host "Running: $Command" -ForegroundColor Cyan
        & bash -lc $Command
        $code = $LASTEXITCODE
    } else {
        Write-Host "Holding awake for $Minutes minute(s). Ctrl-C releases it." -ForegroundColor Cyan
        Start-Sleep -Seconds ($Minutes * 60)
        $code = 0
    }
} finally {
    # Release even on Ctrl-C or a failure: leaving the request set would keep
    # the machine awake indefinitely, which is its own kind of bug.
    [void][Kataglyphis.Power]::SetThreadExecutionState($ES_CONTINUOUS)
    Write-Host 'Sleep suppression released.' -ForegroundColor Green
}

exit $code
