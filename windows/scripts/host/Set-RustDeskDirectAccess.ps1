#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Turns RustDesk's direct IP access on or off, so a LAN client connects by address with no server in the path; see docs/windows-host-setup.md § F2.

[CmdletBinding()]
param(
    [switch]$Disable,
    # Sets direct-access-port; without it the configured port, default 21118, stays.
    [ValidateRange(1, 65535)]
    [int]$Port = 21118
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsRustDesk.Common.psm1')

Assert-Elevated -Reason 'rustdesk.exe --option writes the service config'
$exe = Get-RustDeskExe

if ($Disable) {
    Set-RustDeskOption -Exe $exe -Name 'direct-server' -Value 'N'
    Write-Host 'Direct IP access is off.' -ForegroundColor Green
    exit 0
}

Set-RustDeskOption -Exe $exe -Name 'direct-server' -Value 'Y'
if ($PSBoundParameters.ContainsKey('Port')) { Set-RustDeskOption -Exe $exe -Name 'direct-access-port' -Value "$Port" }
$configured = Get-RustDeskOption -Exe $exe -Name 'direct-access-port'
$listenPort = if ($configured) { [int]$configured } else { 21118 }

if (-not (Wait-RustDeskListener -Port $listenPort)) {
    Write-Host "No RustDesk listener on TCP $listenPort yet - restarting the RustDesk service" -ForegroundColor Yellow
    Restart-Service -Name RustDesk
    if (-not (Wait-RustDeskListener -Port $listenPort)) {
        throw "RustDesk does not listen on TCP $listenPort after a service restart"
    }
}

$suffix = if ($listenPort -eq 21118) { '' } else { ":$listenPort" }
Write-Host "RustDesk listens on TCP $listenPort. Type one of these into the client's ID field:" -ForegroundColor Green
foreach ($address in @(Get-RustDeskLanAddress)) { Write-Host "  $address$suffix" }
