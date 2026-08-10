# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deterministic container-store reset v2: stop -> RENAME state dirs aside ->
# re-create -> start each service (verifying each) -> CNI + buildctl + docker
# checks. ErrorActionPreference=Continue so no single failure aborts the run;
# every step prints a verdict line.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\reset-container-stores.ps1'

#requires -Version 7.0
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'MUST run elevated' -ForegroundColor Red; Read-Host 'Enter'; exit 1
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say([string]$m, [string]$c = 'Gray') { Write-Host ('[{0}] {1}' -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor $c }

Say '== stop services ==' 'Cyan'
Stop-Service buildkitd -Force -ErrorAction SilentlyContinue
Stop-Service containerd -Force -ErrorAction SilentlyContinue
Stop-Service stevedore -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Get-Service containerd, buildkitd, stevedore | Select-Object Name, Status | Format-Table -AutoSize

Say '== rename state dirs aside (.bak-<stamp>) ==' 'Cyan'
foreach ($d in @('C:\ProgramData\containerd', 'C:\ProgramData\buildkitd', 'C:\ProgramData\Docker')) {
    if (Test-Path $d) {
        $bak = "$d.bak-$stamp"
        try {
            Rename-Item -Path $d -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
            Say "  $d -> $bak" 'Green'
        } catch { Say "  FAILED to rename $d : $($_.Exception.Message)" 'Red' }
    } else { Say "  $d (absent)" }
}

Say '== start services, verifying each ==' 'Cyan'
Start-Service containerd
Start-Sleep -Seconds 5
Say ("  containerd = " + (Get-Service containerd).Status) $(if ((Get-Service containerd).Status -eq 'Running') { 'Green' } else { 'Red' })
Start-Service buildkitd
Start-Sleep -Seconds 5
Say ("  buildkitd  = " + (Get-Service buildkitd).Status) $(if ((Get-Service buildkitd).Status -eq 'Running') { 'Green' } else { 'Red' })
Start-Service stevedore
Start-Sleep -Seconds 5
Say ("  stevedore  = " + (Get-Service stevedore).Status) $(if ((Get-Service stevedore).Status -eq 'Running') { 'Green' } else { 'Red' })

Say '== re-deploy GC policy toml ==' 'Cyan'
& 'D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\apply-buildkitd-gcpolicy.ps1'
Start-Sleep -Seconds 3

Say '== CNI confs survive? ==' 'Cyan'
foreach ($f in @('C:\Program Files\containerd\cni\conf\0-containerd-nat.conf', 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist')) {
    Say ("  " + $f + "  " + (Test-Path $f))
}

Say '== buildctl worker ==' 'Cyan'
$bt = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
if (Test-Path $bt) { & $bt --addr npipe:////./pipe/buildkitd debug workers 2>&1 | Select-String -Pattern 'windows/amd64|worker' | ForEach-Object { $_.Line } | Write-Host } else { Say '  buildctl missing' 'Red' }

Say '== docker info ==' 'Cyan'
& "$env:ProgramFiles\Stevedore\bin\docker.exe" info 2>&1 | Select-String -Pattern 'Server Version|Storage Driver|Isolation' | ForEach-Object { $_.Line } | Write-Host

Say 'RESET COMPLETE - tell the agent to re-run the 3-layer probe.' 'Green'
Read-Host 'Press ENTER to close'
