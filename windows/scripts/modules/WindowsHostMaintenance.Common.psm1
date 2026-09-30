#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Host-maintenance plumbing; what a script restores and whether it then throws stays in the script on purpose.

Set-StrictMode -Version Latest

function New-HostMaintenanceLog {
    <#
    .SYNOPSIS
        Transcript context: an in-memory line list and the log path (default <repo>\out\<name>.log).
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
    # Takes $Log explicitly; the scripts wrap it in a script-scope Write-Step.
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
        Best-effort stop; returns the names actually stopped, so the restore starts only those.
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
    # A real array: [array]::Reverse() on a List reverses a converted copy, a silent no-op.
    return , $stopped.ToArray()
}

function Start-HostServices {
    <#
    .SYNOPSIS
        Starts what Stop-HostServices stopped, in reverse order; a failure is a red line, never silence.
    #>
    param(
        [Parameter(Mandatory)]$Log,
        [Parameter(Mandatory)][string[]]$Service
    )
    Write-HostStep $Log '--- starting services ---'
    $ordered = @($Service)
    [array]::Reverse($ordered)
    foreach ($s in $ordered) {
        try {
            Start-Service $s -ErrorAction Stop
            Write-HostStep $Log ('{0} : {1}' -f $s, (Get-Service $s).Status)
        } catch {
            Write-HostStep $Log ('{0} START ERROR: {1}' -f $s, $_.Exception.Message) 'Red'
        }
    }
}

Export-ModuleMember -Function @(
    'New-HostMaintenanceLog',
    'Write-HostStep',
    'Save-HostMaintenanceLog',
    'Stop-HostServices',
    'Start-HostServices'
)
