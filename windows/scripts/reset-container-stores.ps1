#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deterministic container-store reset v2: stop -> RENAME state dirs aside ->
# re-create -> start each service (verifying each) -> CNI + buildctl + docker
# checks. ErrorActionPreference=Continue so no single failure aborts the run;
# every step prints a verdict line.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\reset-container-stores.ps1'

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'MUST run elevated' -ForegroundColor Red; Read-Host 'Enter'; exit 1
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Tool resolution via the shared candidate-list owner (backlog #2).
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsScripts.Shared.psm1')

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
# $PSScriptRoot, not a hardcoded checkout path: this script must work from
# any clone location (a D:\GitHub literal broke C:-checkout hosts).
& (Join-Path $PSScriptRoot 'apply-buildkitd-gcpolicy.ps1')
Start-Sleep -Seconds 3

Say '== CNI confs survive? ==' 'Cyan'
foreach ($f in @('C:\Program Files\containerd\cni\conf\0-containerd-nat.conf', 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist')) {
    Say ("  " + $f + "  " + (Test-Path $f))
}

Say '== buildctl worker ==' 'Cyan'
# Get-PreferredToolPath: candidates first, then PATH; returns $null when
# absent (the old `Test-Path $bt` threw on a $null path with buildctl missing).
$bt = Get-PreferredToolPath -CommandName 'buildctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
if ($bt) { & $bt --addr npipe:////./pipe/buildkitd debug workers 2>&1 | Select-String -Pattern 'windows/amd64|worker' | ForEach-Object { $_.Line } | Write-Host } else { Say '  buildctl missing' 'Red' }

Say '== docker info ==' 'Cyan'
$dockerExe = Get-PreferredToolPath -CommandName 'docker.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\docker.exe", 'D:\Stevedore\bin\docker.exe')
if ($dockerExe) {
    & $dockerExe info 2>&1 | Select-String -Pattern 'Server Version|Storage Driver|Isolation' | ForEach-Object { $_.Line } | Write-Host
}

Say 'RESET COMPLETE - tell the agent to re-run the 3-layer probe.' 'Green'
Read-Host 'Press ENTER to close'
