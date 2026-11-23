#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Installs or updates RustDesk from Chocolatey's MSI package and schedules the weekly update; see docs/windows-host-setup.md § F1.

[CmdletBinding()]
param(
    # Holds the ID key and password material, so it stays under the user profile.
    [string]$BackupRoot = (Join-Path $env:USERPROFILE 'RustDesk-Backup'),
    [DayOfWeek]$UpdateDay = [DayOfWeek]::Sunday,
    # Only the time of day counts; the trigger repeats it weekly.
    [datetime]$UpdateTime = '04:00',
    [switch]$NoUpdateTask,
    # The upgrade reinstalls the service, which drops an open session.
    [switch]$Force
)

$script:UpdateTaskName = 'RustDesk Update (choco)'

function Assert-ChocolateyInstallerSignature {
    param([Parameter(Mandatory)][object]$Signature)
    if ("$($Signature.Status)" -ne 'Valid') { throw "Chocolatey's install.ps1 signature is $($Signature.Status); refusing to run it" }
    $subject = "$($Signature.SignerCertificate.Subject)"
    if ($subject -notmatch '(^|, )O="?Chocolatey Software, Inc"?(,|$)') {
        throw "Chocolatey's install.ps1 is signed by '$subject', not by Chocolatey Software, Inc"
    }
}

function Install-Chocolatey {
    param([string]$ChocoExe = (Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'))
    if (Test-Path -LiteralPath $ChocoExe) { return $ChocoExe }
    # Authenticode verification needs the .ps1 extension.
    $installer = Join-Path ([IO.Path]::GetTempPath()) ("chocolatey-install-{0}.ps1" -f [guid]::NewGuid())
    try {
        Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $installer -UseBasicParsing
        Assert-ChocolateyInstallerSignature -Signature (Get-AuthenticodeSignature -LiteralPath $installer)
        # Chocolatey supports its installer under Windows PowerShell, which every Windows 11 host has.
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $installer
        if ($LASTEXITCODE -ne 0) { throw "Chocolatey's installer exited $LASTEXITCODE" }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $ChocoExe)) { throw "Chocolatey's installer finished without $ChocoExe" }
    return $ChocoExe
}

function Register-RustDeskUpdateTask {
    param([Parameter(Mandatory)][string]$ChocoExe, [Parameter(Mandatory)][DayOfWeek]$Day, [Parameter(Mandatory)][datetime]$Time)
    $action = New-ScheduledTaskAction -Execute $ChocoExe -Argument 'upgrade rustdesk.install -y --no-progress'
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # A host that was off at the trigger catches up at its next start.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $script:UpdateTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    return Get-ScheduledTask -TaskName $script:UpdateTaskName
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsRustDesk.Common.psm1')

Assert-Elevated -Reason 'the MSI install and a SYSTEM task need admin'
if ((Test-RustDeskSessionOpen) -and -not $Force) {
    throw 'A RustDesk session is open and the upgrade would drop it; close it or pass -Force'
}

Write-Host '== 1/4 back up the RustDesk config ==' -ForegroundColor Cyan
$backup = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$copied = @(Backup-RustDeskConfig -Destination $backup)
if ($copied.Count) { Write-Host "  $backup ($($copied -join ', '))" } else { Write-Host '  no config yet (fresh host)' }

Write-Host '== 2/4 Chocolatey ==' -ForegroundColor Cyan
$choco = Install-Chocolatey
Write-Host "  $choco $(& $choco --version)"

Write-Host '== 3/4 choco upgrade rustdesk.install ==' -ForegroundColor Cyan
& $choco upgrade rustdesk.install -y --no-progress
$chocoExit = $LASTEXITCODE
# 3010 is the MSI's success that still needs a reboot.
if ($chocoExit -notin 0, 3010) { throw "choco upgrade rustdesk.install exited $chocoExit" }

Write-Host '== 4/4 weekly update task ==' -ForegroundColor Cyan
if ($NoUpdateTask) {
    Write-Host '  skipped (-NoUpdateTask)'
} else {
    $task = Register-RustDeskUpdateTask -ChocoExe $choco -Day $UpdateDay -Time $UpdateTime
    Write-Host "  '$($task.TaskName)' $($task.State): $UpdateDay $($UpdateTime.ToString('HH:mm')) as SYSTEM"
}

$version = (Get-Item -LiteralPath (Get-RustDeskExe)).VersionInfo.ProductVersion
$service = Get-Service -Name RustDesk
Write-Host ''
Write-Host "RustDesk $version, service $($service.Status) ($($service.StartType))" -ForegroundColor Green
if ($chocoExit -eq 3010) { Write-Host 'Reboot to finish the MSI install.' -ForegroundColor Yellow }
if ($service.Status -ne 'Running') { exit 1 }
