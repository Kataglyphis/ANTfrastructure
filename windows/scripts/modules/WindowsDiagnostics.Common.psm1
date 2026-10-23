#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -ErrorAction Stop

function Resolve-DiagnosticDocker {
    param([string]$Docker = '')
    if (-not $Docker) {
        $Docker = Get-PreferredToolPath -CommandName docker -CandidatePaths @(
            $env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe")
    }
    if (-not $Docker) { throw 'docker.exe not found. Pass -Docker <path>.' }
    return $Docker
}

function Write-DiagnosticResult {
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [switch]$SeparateDetail)
    $tag = if ($Ok) { '[ OK ]' } else { '[FAIL]' }
    $suffix = if ($Detail -and -not $SeparateDetail) { " - $Detail" } else { '' }
    Write-Host ("{0} {1}{2}" -f $tag, $Name, $suffix)
    if ($Detail -and $SeparateDetail) { Write-Host ("       {0}" -f $Detail) }
}

Export-ModuleMember -Function Write-DiagnosticResult

function Write-DiagnosticHeading {
    param([string]$Title)
    Write-Host "`n==== $Title ====" -ForegroundColor Cyan
}

function Write-DiagnosticHostEnvironment {
    param([Parameter(Mandatory)][string]$Docker, [Parameter(Mandatory)][string]$Base,
        [string]$ImageLabel = 'Probe image    ')
    Write-DiagnosticHeading 'Environment (record these against the verdict)'
    $hostBuild = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Host ("Host           : {0} (build {1}.{2})" -f $hostBuild.ProductName, $hostBuild.CurrentBuildNumber, $hostBuild.UBR)
    Write-Host ("{0}: {1}" -f $ImageLabel, $Base)
    & $Docker version --format 'Docker Engine  : {{.Server.Version}} (API {{.Server.APIVersion}})' 2>&1 | Write-Host
    & $Docker info --format 'containerd     : {{.ContainerdCommit.ID}}   default-isolation: {{.Isolation}}' 2>&1 | Write-Host
}

function Invoke-DiagnosticDocker {
    param([Parameter(Mandatory)][string]$Docker, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& $Docker @Arguments 2>&1)
    $code = $LASTEXITCODE
    $output | Write-Host
    return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-DiagnosticControl {
    param([Parameter(Mandatory)][string]$Docker, [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string[]]$Command, [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$SuccessDetail, [Parameter(Mandatory)][string]$FailureDetail)
    $result = Invoke-DiagnosticDocker -Docker $Docker -Arguments (@('run', '--rm', '--isolation', 'process', $Base) + $Command)
    $passed = $result.Code -eq 0 -and $result.Text -match $Marker
    Write-Host ("CONTROL: {0}" -f $(if ($passed) { "PASS ($SuccessDetail)" } else { "FAIL ($FailureDetail)" })) `
        -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    return $passed
}

function Write-DiagnosticVerdict {
    param([bool]$Passed, [bool]$KnownBug, [Parameter(Mandatory)][string[]]$Success,
        [Parameter(Mandatory)][string[]]$Present, [Parameter(Mandatory)][string]$Failure)
    Write-DiagnosticHeading 'RESULT'
    if ($Passed) { $lines = $Success; $color = 'Green'; $code = 0 }
    elseif ($KnownBug) { $lines = $Present; $color = 'Yellow'; $code = 1 }
    else { $lines = @($Failure); $color = 'Red'; $code = 2 }
    foreach ($line in $lines) { Write-Host $line -ForegroundColor $color }
    return $code
}

Export-ModuleMember -Function Find-ChildDirectoryFile, Resolve-DiagnosticDocker, Write-DiagnosticHeading, Write-DiagnosticHostEnvironment, Invoke-DiagnosticDocker, Invoke-DiagnosticControl, Write-DiagnosticVerdict
