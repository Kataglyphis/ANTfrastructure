#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Elevated store reset that renames state dirs aside; Continue so no single failure aborts, every step prints a verdict.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1')

Assert-Elevated -Interactive
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'


Write-HostMaintenanceMessage '== stop services ==' 'Cyan'
Stop-Service buildkitd -Force -ErrorAction SilentlyContinue
Stop-Service containerd -Force -ErrorAction SilentlyContinue
Stop-Service stevedore -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Get-Service containerd, buildkitd, stevedore | Select-Object Name, Status | Format-Table -AutoSize

Write-HostMaintenanceMessage '== rename state dirs aside (.bak-<stamp>) ==' 'Cyan'
foreach ($d in @('C:\ProgramData\containerd', 'C:\ProgramData\buildkitd', 'C:\ProgramData\Docker')) {
    if (Test-Path $d) {
        $bak = "$d.bak-$stamp"
        try {
            Rename-Item -Path $d -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
            Write-HostMaintenanceMessage "  $d -> $bak" 'Green'
        } catch { Write-HostMaintenanceMessage "  FAILED to rename $d : $($_.Exception.Message)" 'Red' }
    } else { Write-HostMaintenanceMessage "  $d (absent)" }
}

Write-HostMaintenanceMessage '== start services, verifying each ==' 'Cyan'
Start-Service containerd
Start-Sleep -Seconds 5
Write-HostMaintenanceMessage ("  containerd = " + (Get-Service containerd).Status) $(if ((Get-Service containerd).Status -eq 'Running') { 'Green' } else { 'Red' })
Start-Service buildkitd
Start-Sleep -Seconds 5
Write-HostMaintenanceMessage ("  buildkitd  = " + (Get-Service buildkitd).Status) $(if ((Get-Service buildkitd).Status -eq 'Running') { 'Green' } else { 'Red' })
Start-Service stevedore
Start-Sleep -Seconds 5
Write-HostMaintenanceMessage ("  stevedore  = " + (Get-Service stevedore).Status) $(if ((Get-Service stevedore).Status -eq 'Running') { 'Green' } else { 'Red' })

Write-HostMaintenanceMessage '== re-deploy GC policy toml ==' 'Cyan'
& (Join-Path $PSScriptRoot 'Set-BuildkitdGcpolicy.ps1')
Start-Sleep -Seconds 3

Write-HostMaintenanceMessage '== CNI confs survive? ==' 'Cyan'
foreach ($f in @('C:\Program Files\containerd\cni\conf\0-containerd-nat.conf', 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist')) {
    Write-HostMaintenanceMessage ("  " + $f + "  " + (Test-Path $f))
}

Write-HostMaintenanceMessage '== buildctl worker ==' 'Cyan'
$bt = Get-PreferredToolPath -CommandName 'buildctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
Write-HostMaintenanceProbe -Command $bt -ArgumentList @('--addr', 'npipe:////./pipe/buildkitd', 'debug', 'workers') `
    -Pattern 'windows/amd64|worker' -UnavailableMessage '  buildctl missing' -UnavailableColor Red

Write-HostMaintenanceMessage '== docker info ==' 'Cyan'
$dockerExe = Get-PreferredToolPath -CommandName 'docker.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\docker.exe", 'D:\Stevedore\bin\docker.exe')
Write-HostMaintenanceProbe -Command $dockerExe -ArgumentList info -Pattern 'Server Version|Storage Driver|Isolation'

Write-HostMaintenanceMessage 'RESET COMPLETE - tell the agent to re-run the 3-layer probe.' 'Green'
Read-Host 'Press ENTER to close'
