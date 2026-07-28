# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, ConvertTo-ParameterList, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function New-StructuredLogContext {
    param(
        [Parameter(Mandatory)]
        [string]$LogDir,
        [string]$Prefix = 'installer'
    )

    $resolvedLogDir = Resolve-DirectoryPath -Path $LogDir
    $timestamp = New-Timestamp -Format 'yyyy-MM-dd_HH-mm-ss'

    [pscustomobject]@{
        LogDir = $resolvedLogDir
        Prefix = $Prefix
        TranscriptFile = Join-Path $resolvedLogDir "$Prefix-$timestamp.transcript.log"
        StructuredLogFile = Join-Path $resolvedLogDir "$Prefix-$timestamp.log"
        TranscriptStarted = $false
    }
}

function Start-StructuredLogging {
    param([Parameter(Mandatory)][pscustomobject]$Context)

    try {
        Start-Transcript -Path $Context.TranscriptFile -Force | Out-Null
        $Context.TranscriptStarted = $true
    } catch {
        Write-Warning "Start-Transcript failed: $($_.Exception.Message). Continuing without transcript."
    }
}

function Stop-StructuredLogging {
    param([Parameter(Mandatory)][pscustomobject]$Context)

    if ($Context.TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }
}

function Write-StructuredLogEntry {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Text
    )

    $entry = "$(Get-Date -Format u)`t$Text"
    Write-Host $entry

    try {
        Add-Content -Path $Context.StructuredLogFile -Value $entry -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to structured log ($($Context.StructuredLogFile)): $($_.Exception.Message)"
    }
}

function Enable-Tls12ForDownloads {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

Export-ModuleMember -Function @(
    'New-StructuredLogContext',
    'Start-StructuredLogging',
    'Stop-StructuredLogging',
    'Write-StructuredLogEntry',
    'Enable-Tls12ForDownloads',
    # Re-exported from WindowsScripts.Shared (imported above) so a caller gets these via a
    # single Import-Module -- no "import Shared last" ordering dance / nested -Force clobber.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'Expand-ArchiveSubdirectory'
)

