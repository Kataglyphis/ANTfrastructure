#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Elevated store reset that renames state dirs aside; Continue so no single failure aborts, every step prints a verdict.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1')

Assert-Elevated -Interactive
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
& (Join-Path $PSScriptRoot 'Set-BuildkitdGcpolicy.ps1')
Start-Sleep -Seconds 3

Say '== CNI confs survive? ==' 'Cyan'
foreach ($f in @('C:\Program Files\containerd\cni\conf\0-containerd-nat.conf', 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist')) {
    Say ("  " + $f + "  " + (Test-Path $f))
}

Say '== buildctl worker ==' 'Cyan'
$bt = Get-PreferredToolPath -CommandName 'buildctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
if ($bt) { & $bt --addr npipe:////./pipe/buildkitd debug workers 2>&1 | Select-String -Pattern 'windows/amd64|worker' | ForEach-Object { $_.Line } | Write-Host } else { Say '  buildctl missing' 'Red' }

Say '== docker info ==' 'Cyan'
$dockerExe = Get-PreferredToolPath -CommandName 'docker.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\docker.exe", 'D:\Stevedore\bin\docker.exe')
if ($dockerExe) {
    & $dockerExe info 2>&1 | Select-String -Pattern 'Server Version|Storage Driver|Isolation' | ForEach-Object { $_.Line } | Write-Host
}

Say 'RESET COMPLETE - tell the agent to re-run the 3-layer probe.' 'Green'
Read-Host 'Press ENTER to close'
