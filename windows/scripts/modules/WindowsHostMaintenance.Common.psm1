#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared plumbing for the HOST maintenance family (compact-host-vhdx,
# rebuild-host-vhdx, deploy-shim-patch): all three are "stop services ->
# mutate a host artifact -> restore services -> write a transcript", and until
# 2026-08-21 each carried its own byte-identical transcript preamble and
# service stop-loop (~90 duplicated lines, already diverging in formatting).
# The RESTORE halves stay in the scripts on purpose — each script's restore
# semantics differ (best-effort mid-flow vs must-succeed final) and that
# difference is load-bearing, not drift.

Set-StrictMode -Version Latest

function New-HostMaintenanceLog {
    <#
    .SYNOPSIS
        Creates the transcript context: an in-memory line list plus the
        resolved log path (default: out\<name>.log under the repo root).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$LogPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path $RepoRoot ('out\' + $Name + '.log')
    }
    return [pscustomobject]@{
        Lines   = [System.Collections.Generic.List[string]]::new()
        LogPath = $LogPath
    }
}

function Write-HostStep {
    # Timestamped console line that is ALSO captured in the transcript. The
    # maintenance scripts wrap this in a local 2-line Write-Step so their ~50
    # call sites keep the old signature.
    param(
        [Parameter(Mandatory)]$Log,
        [string]$Message = '',
        [string]$Color = 'Gray'
    )
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $Log.Lines.Add($line)
    Write-Host $line -ForegroundColor $Color
}

function Save-HostMaintenanceLog {
    param([Parameter(Mandatory)]$Log)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $Log.LogPath -Parent) | Out-Null
        Set-Content -Path $Log.LogPath -Value ($Log.Lines -join [Environment]::NewLine) -Encoding UTF8
        Write-Host "log: $($Log.LogPath)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "could not write log to $($Log.LogPath): $($_.Exception.Message)"
    }
}

function Stop-HostServices {
    <#
    .SYNOPSIS
        Best-effort stop of the given services (a service that fails to stop
        is logged, not fatal — the caller decides whether the missing member
        of the returned list matters). Returns the names actually stopped, so
        the caller's restore half starts only what this stopped.
    #>
    param(
        [Parameter(Mandatory)]$Log,
        [Parameter(Mandatory)][string[]]$Service
    )
    Write-HostStep $Log '--- stopping services ---'
    $stopped = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Service) {
        try {
            Stop-Service $s -Force -ErrorAction Stop
            $stopped.Add($s)
            Write-HostStep $Log "$s stopped"
        } catch {
            Write-HostStep $Log ('{0} STOP ERROR: {1}' -f $s, $_.Exception.Message) 'Yellow'
        }
    }
    Start-Sleep -Seconds 3
    return , $stopped
}

Export-ModuleMember -Function @(
    'New-HostMaintenanceLog',
    'Write-HostStep',
    'Save-HostMaintenanceLog',
    'Stop-HostServices'
)
