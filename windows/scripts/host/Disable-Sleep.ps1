#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Hold the machine awake while a long benchmark runs, then release it.

.DESCRIPTION
    Windows treats a busy NPU as idle and enters Modern Standby, which this host may not survive with a GenieX model loaded.
    Needs -ExecutionPolicy Bypass over a \\wsl.localhost path; launched hidden, a refusal is silent, so check Get-Process pwsh.
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

# The u suffix matters: a bare 0x80000000 parses as a negative Int32 and fails the [uint32] cast.
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
    # Released on Ctrl-C or failure too, or the machine would stay awake indefinitely.
    [void][Kataglyphis.Power]::SetThreadExecutionState($ES_CONTINUOUS)
    Write-Host 'Sleep suppression released.' -ForegroundColor Green
}

exit $code
