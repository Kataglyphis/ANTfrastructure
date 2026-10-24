#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Host-maintenance plumbing; what a script restores and whether it then throws stays in the script on purpose.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -ErrorAction Stop

function New-HostMaintenanceLog {
    <#
    .SYNOPSIS
        Transcript context: an in-memory line list and the log path (default <repo>\logs\host\<name>.log).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot = (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent),
        [string]$LogPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path $RepoRoot ('logs\host\' + $Name + '.log')
    }
    return [pscustomobject]@{
        Lines   = [System.Collections.Generic.List[string]]::new()
        LogPath = $LogPath
    }
}

function Write-HostStep {
    param(
        [Parameter(Mandatory)]$Log,
        [string]$Message = '',
        [string]$Color = 'Gray'
    )
    Write-HostMaintenanceMessage -Message $Message -Color $Color -Log $Log
}

function Write-HostMaintenanceMessage {
    param([string]$Message = '', [string]$Color = 'Gray', $Log = $null)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($null -ne $Log) { $Log.Lines.Add($line) }
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

function Write-HostMaintenanceError {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][string]$Template, [string]$Color = 'Red')
    Write-HostStep -Log $Log ($Template -f $ErrorRecord.Exception.Message) $Color
}

function Invoke-HostMaintenanceTask {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$FailureTemplate, [string]$FailureColor = 'Yellow')
    try { & $Operation }
    catch { Write-HostMaintenanceError -Log $Log -ErrorRecord $_ -Template $FailureTemplate -Color $FailureColor }
}

function Write-HostMaintenanceProbe {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Command, [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Pattern, [string]$UnavailableMessage = '', [string]$UnavailableColor = 'Yellow')
    if ($Command) {
        & $Command @ArgumentList 2>&1 | Select-String -Pattern $Pattern | ForEach-Object { $_.Line } | Write-Host
    } elseif ($UnavailableMessage) {
        Write-Host $UnavailableMessage -ForegroundColor $UnavailableColor
    }
}

function Write-HostMaintenanceFailure {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message, [string[]]$Advice = @())
    Write-HostStep -Log $Log ("${Phase} FAILED: $Message") 'Red'
    foreach ($line in $Advice) { Write-HostStep -Log $Log $line 'Yellow' }
}

function Get-HostMaintenanceProcess {
    param([Parameter(Mandatory)][string[]]$Name, [switch]$Force, $Log,
        [Parameter(Mandatory)][string]$FailureTemplate)
    $live = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0 -and -not $Force) {
        if ($null -ne $Log) { Save-HostMaintenanceLog -Log $Log }
        throw ($FailureTemplate -f $live.Count,
            (($live | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '),
            (($live | ForEach-Object Id) -join ', '))
    }
    return $live
}

function Get-HostMaintenanceTreeStats {
    param([Parameter(Mandatory)][string]$Root, [string[]]$ExcludeDir = @())
    $bytes = [long]0; $files = 0; $errors = 0
    $ev = $null
    # Omit -FollowSymlink so size probes remain inside the selected tree.
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable ev
    if ($ExcludeDir.Count -gt 0) {
        $items = @($items | Where-Object {
                $parts = $_.FullName.Split([char]'\')
                -not ($ExcludeDir | Where-Object { $parts -contains $_ })
            })
    }
    foreach ($file in $items) { $bytes += $file.Length; $files++ }
    if ($ev) { $errors = @($ev).Count }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Errors = $errors }
}

function Get-HostMaintenanceVhdxSnapshot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Drive)
    return [pscustomobject]@{
        PhysicalBytes = (Get-Item $Path).Length
        HostFreeBytes = (Get-PSDrive $Drive).Free
    }
}

function Test-HostMaintenanceVerifyPath {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)][string]$Path)
    $exists = Test-Path $Path
    Write-HostStep -Log $Log ("verify path {0}: {1}" -f $Path, $exists) $(if ($exists) { 'Green' } else { 'Red' })
    return $exists
}

function Get-HostMaintenanceBuildCtlPath {
    param([switch]$SearchPath, [switch]$IncludeCProgramFilesFallback)
    $candidates = @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
    if ($IncludeCProgramFilesFallback) { $candidates = @($candidates[0], 'C:\Program Files\Stevedore\bin\buildctl.exe', $candidates[1]) }
    if ($SearchPath) { return Get-PreferredToolPath -CommandName 'buildctl.exe' -CandidatePaths $candidates }
    foreach ($candidate in $candidates) { if (Test-Path $candidate) { return $candidate } }
    return $null
}

Export-ModuleMember -Function @(
    'New-HostMaintenanceLog',
    'Write-HostStep',
    'Write-HostMaintenanceMessage',
    'Save-HostMaintenanceLog',
    'Stop-HostServices',
    'Start-HostServices',
    'Get-HostMaintenanceProcess',
    'Get-HostMaintenanceTreeStats',
    'Get-HostMaintenanceVhdxSnapshot',
    'Test-HostMaintenanceVerifyPath',
    'Get-HostMaintenanceBuildCtlPath',
    'Write-HostMaintenanceFailure',
    'Write-HostMaintenanceError',
    'Invoke-HostMaintenanceTask',
    'Write-HostMaintenanceProbe',
    'Test-Elevated',
    'Assert-Elevated',
    'Get-PreferredToolPath'
)
