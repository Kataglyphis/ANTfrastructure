#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Collect the host-side state that makes or breaks Windows-container layer
# filesystems, for comparing two machines ("works there, fails here").
# Write once at the end (best-effort, guarded); every section individually
# guarded so one failure cannot abort the rest. ELEVATED for the feature
# (dism) and filter (fltmc) reads; degrades gracefully when not.
#
#   pwsh -File windows\scripts\host\Get-HostDockerState.ps1
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\ContainerHub\windows\scripts\host\Get-HostDockerState.ps1'

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$out = Join-Path (Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent) 'out\host-docker-forensics.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
$sb = New-Object System.Text.StringBuilder
function W([string]$s) { [void]$sb.AppendLine($s) }

W ('==== host-docker forensics ==== ' + (Get-Date -Format o) + '  machine=' + $env:COMPUTERNAME)
try {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    W ('OS: ' + $k.DisplayVersion + ' build ' + $k.CurrentBuild + '.' + $k.UBR)
} catch { W ('  os error: ' + $_.Exception.Message) }

W ''
W '== Optional features (Container/Hyper/ProjFS/VM) =='
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Continue |
        Where-Object { $_.FeatureName -match 'Container|Hyper|VirtualMachine|ProjFS|Projected|Hosted' } |
        Sort-Object FeatureName |
        ForEach-Object { W ('  {0}  =  {1}' -f $_.FeatureName, $_.State) }
    W '  (DISM API OK)'
} catch { W ('  features error - DISM API broken: ' + $_.Exception.Message) }

W ''
W '== Filter drivers (fltmc filters) =='
try { fltmc.exe filters 2>&1 | ForEach-Object { W ('  ' + $_) } }
catch { W ('  fltmc error: ' + $_.Exception.Message) }

W ''
W '== Services =='
try {
    Get-Service vmcompute,hns,icssvc,cexecsvc,containerd,buildkitd,stevedore,wslservice,containers*,docker* -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { W ('  {0}  {1}  {2}' -f $_.Name, $_.Status, $_.StartType) }
} catch { W ('  services error: ' + $_.Exception.Message) }

W ''
W '== Engine binaries =='
try {
    Get-Item 'C:\Program Files\Stevedore\bin\*.exe', 'C:\Program Files\Stevedore\*.exe', 'D:\Stevedore\bin\*.exe', 'D:\Stevedore\*.exe' -ErrorAction SilentlyContinue |
        Select-Object Name, @{n='Ver'; e={$_.VersionInfo.FileVersion}}, @{n='MB'; e={[math]::Round($_.Length/1MB,1)}} |
        ForEach-Object { W ('  {0} v{1} {2}MB' -f $_.Name, $_.Ver, $_.MB) }
} catch { W ('  engines error: ' + $_.Exception.Message) }

W ''
W '== docker version / info (condensed) =='
try {
    docker version 2>&1 | Where-Object { $_ -match 'Version|OS/Arch|Engine|Server|Client' } | ForEach-Object { W ('  ' + $_.Trim()) }
    docker info 2>&1 | Where-Object { $_ -match 'Storage Driver|Isolation|Kernel Version|Operating System|Name:' } | ForEach-Object { W ('  ' + $_.Trim()) }
} catch { W ('  docker error: ' + $_.Exception.Message) }

W ''
W '== HNS networks =='
try { Get-NetNat | ForEach-Object { W ('  ' + $_.Name + ' ' + $_.InternalIPInterfaceAddressPrefix) } }
catch { W ('  netnat error: ' + $_.Exception.Message) }

W '==== end ===='
try {
    [System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Get-Content $out
    Write-Host ''
    Write-Host ("Wrote: $out  - run the SAME script on the working machine and compare.") -ForegroundColor Green
} catch { Write-Warning ('could not write ' + $out + ': ' + $_.Exception.Message) }
Read-Host 'Press ENTER to close'
