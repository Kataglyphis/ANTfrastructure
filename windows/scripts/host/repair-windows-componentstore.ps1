#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Repair the Windows component store on this host: the container layer-fs
# failures in BOTH engines + a broken DISM COM API ("Klasse nicht registriert"
# from Get-WindowsOptionalFeature) point at a damaged Windows install. The
# canonical repair: DISM /RestoreHealth (repairs the component store, needs
# internet/WU), then sfc /scannow. Then re-test whether DISM works again.
# ELEVATED. Long-running (10-40 min). Safe with nothing building.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\host\repair-windows-componentstore.ps1'

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'MUST run elevated' -ForegroundColor Red; Read-Host 'Enter'; exit 1
}

function Say([string]$m, [string]$c = 'Gray') { Write-Host ('[{0}] {1}' -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor $c }

Say '== 1. DISM /Online /Cleanup-Image /RestoreHealth (repairs the component store) ==' 'Cyan'
Say '    This needs internet and can take 10-40 minutes. Do not close the window.' 'Yellow'
dism.exe /Online /Cleanup-Image /RestoreHealth
Say ("    dism exit: " + $LASTEXITCODE)

Say '== 2. sfc /scannow ==' 'Cyan'
sfc.exe /scannow
Say ("    sfc exit: " + $LASTEXITCODE)

Say '== 3. re-test DISM API (was: Klasse nicht registriert) ==' 'Cyan'
try {
    $f = Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.FeatureName -match 'Container|Hyper|VirtualMachine|ProjFS' }
    $f | Sort-Object FeatureName | ForEach-Object { Write-Host ('  ' + $_.FeatureName + ' = ' + $_.State) }
    Say 'DISM API now WORKS.' 'Green'
} catch {
    Say ('DISM API STILL broken: ' + $_.Exception.Message) 'Red'
    Say 'If RestoreHealth could not reach Windows Update, retry with /Source <path-to>install.wim: /RestoreHealth /Source D:\sources\install.wim /LimitAccess'
}

Say '== 4. committed build probe (image export, -Heavy) ==' 'Cyan'
# Delegates to the canonical probe: it exports type=image (a type=local export
# of a Windows rootfs dies in the receiver even on a HEALTHY host and reads
# like a defect - the false signal this script used to produce), exits
# non-zero per failing lane, and Tee's full lane logs to out\build-logs.
# Absolute path: this script is documented to launch elevated via
# Start-Process, where cwd is System32 and relative paths break.
$probeScript = Join-Path $scriptAssetRoot 'diagnostics\probe-build-copy.ps1'
& pwsh -NoProfile -File $probeScript -Heavy 2>&1 | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
Say ('probe exit: ' + $LASTEXITCODE)

Write-Host ''
Write-Host 'Done - report the probe result to the agent.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
