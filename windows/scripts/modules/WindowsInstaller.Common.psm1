# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, ConvertTo-ParameterList, etc.)
# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

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
            # Best-effort: transcript may already be closed by a nested stop.
            Write-Verbose "Stop-Transcript: $($_.Exception.Message)"
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
        # pwsh 7 defaults already include TLS 1.2+; failure here is cosmetic.
        Write-Verbose "TLS12 opt-in failed (already default on pwsh 7): $($_.Exception.Message)"
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

