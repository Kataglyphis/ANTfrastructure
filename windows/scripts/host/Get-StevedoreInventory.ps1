#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$StevedoreNamespace = 'buildkit',
    [ValidateNotNullOrEmpty()]
    [string]$BuildkitAddress = 'npipe:////./pipe/buildkitd',
    [ValidateNotNullOrEmpty()]
    [string]$ContainerdAddress = '\\.\pipe\containerd-containerd',
    [string]$NerdctlPath = (Join-Path $env:ProgramFiles 'Stevedore\bin\nerdctl.exe'),
    [string]$BuildctlPath = (Join-Path $env:ProgramFiles 'Stevedore\bin\buildctl.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StevedoreInventoryPlan {
    param(
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string]$StevedoreNamespace,
        [ValidateNotNullOrEmpty()][string]$BuildkitAddress,
        [ValidateNotNullOrEmpty()][string]$ContainerdAddress,
        [string]$NerdctlPath,
        [string]$BuildctlPath
    )
    @(
        [pscustomobject]@{ Title = 'BuildKit disk usage'; Executable = $BuildctlPath; Arguments = @('--addr', $BuildkitAddress, 'du', '-v') }
        [pscustomobject]@{ Title = "Images in $StevedoreNamespace"; Executable = $NerdctlPath; Arguments = @('--address', $ContainerdAddress, '--namespace', $StevedoreNamespace, 'images', '--no-trunc') }
        [pscustomobject]@{ Title = "Containers in $StevedoreNamespace"; Executable = $NerdctlPath; Arguments = @('--address', $ContainerdAddress, '--namespace', $StevedoreNamespace, 'ps', '-a', '--no-trunc') }
    )
}

function Invoke-StevedoreInventoryProbe {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Probe failed with exit code $LASTEXITCODE`: $Executable $($Arguments -join ' ')" }
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host '== Filesystem free space (GiB) =='
    Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free } |
        Select-Object Name, @{ Name = 'FreeGiB'; Expression = { [math]::Round($_.Free / 1GB, 2) } } |
        Format-Table -AutoSize | Out-Host
    $failed = $false
    foreach ($probe in (Get-StevedoreInventoryPlan -StevedoreNamespace $StevedoreNamespace -BuildkitAddress $BuildkitAddress -ContainerdAddress $ContainerdAddress -NerdctlPath $NerdctlPath -BuildctlPath $BuildctlPath)) {
        Write-Host "== $($probe.Title) =="
        try { Invoke-StevedoreInventoryProbe -Executable $probe.Executable -Arguments $probe.Arguments }
        catch { Write-Warning $_.Exception.Message; $failed = $true }
    }
    if ($failed) { [Console]::Error.WriteLine('Inventory incomplete; check daemon access, executable paths and elevation.'); exit 1 }
    exit 0
}
