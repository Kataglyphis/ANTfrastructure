#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
foreach ($moduleFile in @('WindowsHostMaintenance.Common.psm1', 'WindowsStevedoreDelegation.Security.psm1', 'WindowsStevedoreDelegation.Inventory.psm1', 'WindowsStevedoreDelegation.Policy.psm1')) {
    Import-Module (Join-Path $PSScriptRoot $moduleFile) -ErrorAction Stop
}

function New-DelegatedMaintenanceTask {
    param($Service, [string]$Root, [switch]$ReportOnly)
    $definition = $Service.NewTask(0)
    $definition.Principal.UserId = 'SYSTEM'
    $definition.Principal.LogonType = 5
    $definition.Principal.RunLevel = 1
    $definition.Settings.Enabled = $false
    $definition.Settings.Hidden = $true
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.AllowHardTerminate = $false
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $action = $definition.Actions.Create(0)
    $action.Path = Join-Path $Root 'runtime\pwsh.exe'
    $action.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $Root 'Invoke-StevedoreMaintenanceWorker.ps1') + '"'
    if ($ReportOnly) { $action.Arguments += ' -ReportOnly' }
    $action.WorkingDirectory = $Root
    return $definition
}

function Assert-DelegatedMaintenanceTaskDefinition {
    param($Actual, $Expected)
    if ($actual.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or $actual.Principal.LogonType -ne 5 -or $actual.Principal.RunLevel -ne 1) { throw 'Task principal differs.' }
    if ($actual.Actions.Count -ne 1 -or $actual.Triggers.Count -ne 0 -or $actual.Settings.MultipleInstances -ne 2) { throw 'Task action or trigger scope differs.' }
    if ($actual.Settings.AllowHardTerminate -or $actual.Settings.ExecutionTimeLimit -cne 'PT0S' -or $actual.Settings.StopIfGoingOnBatteries -or $actual.Settings.DisallowStartIfOnBatteries) { throw 'Task lifetime policy differs.' }
    $action = $actual.Actions.Item(1)
    $expectedAction = $Expected.Actions.Item(1)
    if ($action.Path -cne $expectedAction.Path -or $action.Arguments -cne $expectedAction.Arguments -or $action.WorkingDirectory -cne $expectedAction.WorkingDirectory) { throw 'Task command differs.' }
}

function Assert-DelegatedMaintenanceTask {
    param($Task, $Expected, [string]$ReaderSid)
    $actual = $Task.Definition
    Assert-DelegatedMaintenanceTaskDefinition $actual $Expected
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Task.GetSecurityDescriptor(7))
    if ($descriptor.Owner.Value -cne 'S-1-5-32-544') { throw 'Task owner differs.' }
    $reader = @($descriptor.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -ceq $ReaderSid })
    if ($reader.Count -ne 1 -or $reader[0].AceType -ne 'AccessAllowed' -or $reader[0].AccessMask -notin @(0x1200a9, [int]0xa0000000)) { throw 'Task delegation differs.' }
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($ace.SecurityIdentifier.Value -notin @('S-1-5-18', 'S-1-5-32-544', $ReaderSid)) { throw 'Unexpected task principal.' }
    }
}

function Assert-DelegatedMaintenanceOverlap {
    $service = Connect-DelegatedMaintenanceScheduler
    foreach ($path in @('\ANTfrastructureMaintenance\RegularCache', '\ANTfrastructureMaintenance\IdleRecovery', '\ANTfrastructureMaintenanceV2\InspectBuildStorage', '\ANTfrastructureMaintenanceV2\ReclaimBuildStorage')) {
        try { $task = $service.GetFolder((Split-Path $path -Parent)).GetTask((Split-Path $path -Leaf)) }
        catch { if ($_.Exception.HResult -eq -2147024894) { continue }; throw }
        if ((Test-DelegatedMaintenanceTaskActive $task) -and $path -cne $script:DelegatedCurrentTask) { throw 'Another maintenance task is active.' }
    }
}

function Invoke-DelegatedCanonicalReclaim {
    param([string]$Root, $Plan, [switch]$Apply)
    $options = @{
        StevedoreOnly = $true
        ImageTag = @($Plan.Images | ForEach-Object Tag)
        ExpectedImageId = @($Plan.Images | ForEach-Object Config)
        ContainerId = @($Plan.Containers | ForEach-Object Id)
        ExpectedContainerImageId = @($Plan.Containers | ForEach-Object Image)
        RegularCache = $true
        KeepGB = 100
    }
    & (Join-Path $Root 'Clear-DiskSpace.ps1') @options -Apply:$Apply
    if ($LASTEXITCODE -ne 0) { throw 'Canonical reclaim refused or failed; retain the complete transcript.' }
}

function Get-DelegatedMaintenanceCurrentInstance {
    param($Service, [string]$TaskPath)
    $instances = @($Service.GetRunningTasks(1) | Where-Object Path -CEQ $TaskPath)
    $identity = [guid]::Empty
    if ($instances.Count -ne 1) { throw 'The original scheduled-task instance is unknown.' }
    if (-not [guid]::TryParse([string]$instances[0].InstanceGuid, [ref]$identity) -or $identity -eq [guid]::Empty) { throw 'The scheduled-task instance identity is unknown.' }
    return $identity.ToString('B')
}

function Invoke-DelegatedMaintenanceWorker {
    param([Parameter(Mandatory)][string]$Root, [switch]$ReportOnly)
    $manifest = Read-DelegatedMaintenanceManifest $Root
    $layout = Get-DelegatedMaintenanceLayout
    $script:DelegatedCurrentTask = $layout.Folder + '\' + $(if ($ReportOnly) { 'InspectBuildStorage' } else { $layout.Task })
    $run = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N')
    $logRoot = Join-Path $Root ('logs\' + $run)
    $null = New-Item -ItemType Directory -Path $logRoot -ErrorAction Stop
    $result = [ordered]@{ state = 'failed'; raw_exit = 1; run_id = $run; started_utc = [datetime]::UtcNow.ToString('o'); completed_utc = $null;
        report_only = $ReportOnly.IsPresent; worker_pid = $PID; task_instance = $null; case = $logRoot; before = $null; after = $null;
        plan = $null; preservation_verified = $false; target_met = $false; error = $null }
    $transcript = $false
    $lock = $null
    try {
        $lock = Open-ExclusiveFile -LiteralPath (Join-Path $Root 'maintenance.lock') -Mode OpenOrCreate
        $null = Start-Transcript -LiteralPath (Join-Path $logRoot 'console.log') -ErrorAction Stop
        $transcript = $true
        $service = Connect-DelegatedMaintenanceScheduler
        $result.task_instance = Get-DelegatedMaintenanceCurrentInstance $service $script:DelegatedCurrentTask
        Assert-DelegatedMaintenanceOverlap
        $result.before = Get-DelegatedStoreSnapshot $manifest $logRoot 'before'
        $result.plan = Get-DelegatedRetirementPlan $result.before
        if ($ReportOnly) { $result.state = 'preview'; $result.raw_exit = 0 }
        else { Complete-DelegatedMaintenanceRun -Root $Root -Manifest $manifest -Result $result -LogRoot $logRoot }
    } catch { $result.error = $_.Exception.Message; Write-Host ($_ | Out-String) }
    finally {
        if ($transcript) { try { $null = Stop-Transcript -ErrorAction Stop } catch { $result.state = 'failed'; $result.raw_exit = 1; $result.error = 'Transcript finalization failed.' } }
        if ($null -ne $lock) { $lock.Dispose() }
        $result.completed_utc = [datetime]::UtcNow.ToString('o')
        $json = $result | ConvertTo-Json -Depth 12
        $json | Set-Content -LiteralPath (Join-Path $logRoot 'result.json') -Encoding utf8 -ErrorAction Stop
        $latest = if ($ReportOnly) { 'latest-preview.json' } else { 'latest.json' }
        $temporary = Join-Path $Root ('logs\' + $run + '.tmp')
        $json | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination (Join-Path $Root "logs\$latest") -Force -ErrorAction Stop
    }
    return [pscustomobject]$result
}

function Complete-DelegatedMaintenanceRun {
    param([string]$Root, $Manifest, $Result, [string]$LogRoot)
    $hasWork = $Result.plan.Images.Count -gt 0 -or $Result.plan.Containers.Count -gt 0 -or $Result.before.UnusedPrivateRegularBytes -gt 0
    if ($Result.before.FreeBytes -lt 100GB -and $hasWork) {
        Invoke-DelegatedCanonicalReclaim -Root $Root -Plan $Result.plan
        Assert-DelegatedMaintenanceOverlap
        $fresh = Get-DelegatedStoreSnapshot $Manifest $LogRoot 'pre-apply'
        $unchanged = [pscustomobject]@{ PreservedImages = $Result.before.Images; PreservedContainers = $Result.before.Containers; CacheMounts = $Result.before.CacheMounts }
        Assert-DelegatedPreservation -Plan $unchanged -Snapshot $fresh
        Invoke-DelegatedCanonicalReclaim -Root $Root -Plan $Result.plan -Apply
        $Result.after = Get-DelegatedStoreSnapshot $Manifest $LogRoot 'after'
        Assert-DelegatedPreservation -Plan $Result.plan -Snapshot $Result.after
    } else {
        $Result.after = Get-DelegatedStoreSnapshot $Manifest $LogRoot 'after-noop'
        $unchanged = [pscustomobject]@{ PreservedImages = $Result.before.Images; PreservedContainers = $Result.before.Containers; CacheMounts = $Result.before.CacheMounts }
        Assert-DelegatedPreservation -Plan $unchanged -Snapshot $Result.after
        $reason = if ($hasWork) { 'Capacity target already met.' } else { 'No eligible unreferenced storage; no exhausted prune repeated.' }
        $Result.plan = [pscustomobject]@{ Images = @(); Containers = @(); reason = $reason }
    }
    $Result.preservation_verified = $true
    $Result.target_met = $Result.after.FreeBytes -ge 100GB
    $Result.state = 'completed'
    $Result.raw_exit = 0
}

function Get-DelegatedMaintenanceConnection {
    $layout = Get-DelegatedMaintenanceLayout
    $manifest = Read-DelegatedMaintenanceManifest $layout.Root
    [pscustomobject]@{ Layout = $layout; Manifest = $manifest; Service = Connect-DelegatedMaintenanceScheduler }
}

function Read-DelegatedMaintenanceCompletion {
    param($Task, [string]$Latest, [datetime]$Started, [string]$InstanceGuid)
    if ($task.State -eq 3 -and $task.GetInstances(0).Count -eq 0 -and (Test-Path -LiteralPath $latest)) {
        $result = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json -ErrorAction Stop
        if (([datetimeoffset]$result.started_utc).UtcDateTime -ge $started -and $result.task_instance -ieq $InstanceGuid) {
            if ($task.LastTaskResult -ne 267009) {
                if ($task.LastTaskResult -ne $result.raw_exit) { throw 'Scheduler and worker raw results differ.' }
                return $result
            }
        }
    }
    return $null
}

function Start-DelegatedMaintenance {
    param([switch]$Apply, [ValidateRange(0, 3600)][int]$WaitSeconds = 300)
    $connection = Get-DelegatedMaintenanceConnection
    $layout = $connection.Layout
    $manifest = $connection.Manifest
    $service = $connection.Service
    $name = if ($Apply) { $layout.Task } else { 'InspectBuildStorage' }
    $task = $service.GetFolder($layout.Folder).GetTask($name)
    Assert-DelegatedMaintenanceTask $task (New-DelegatedMaintenanceTask $service $layout.Root -ReportOnly:(-not $Apply)) $manifest.reader_sid
    if (-not $task.Enabled -or $task.State -ne 3 -or $task.GetInstances(0).Count) { throw 'Maintenance task is disabled or already active.' }
    $started = [datetime]::UtcNow
    $instance = $task.Run($null)
    $deadline = $started.AddSeconds($WaitSeconds)
    $latest = Join-Path $layout.Root ('logs\' + $(if ($Apply) { 'latest.json' } else { 'latest-preview.json' }))
    do {
        $result = Read-DelegatedMaintenanceCompletion -Task $task -Latest $latest -Started $started -InstanceGuid $instance.InstanceGuid
        if ($null -ne $result) { return $result }
        if ([datetime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 2
    } while ($true)
    if ($task.GetInstances(0).Count -eq 0 -and $task.State -notin @(2, 4)) {
        return [pscustomobject]@{ state = 'failed-without-fresh-receipt'; raw_exit = 1; task_instance = $instance.InstanceGuid; scheduler_raw_result = $task.LastTaskResult; logs = Join-Path $layout.Root 'logs' }
    }
    return [pscustomobject]@{ state = 'submitted-not-completed'; task_instance = $instance.InstanceGuid; task = $layout.Folder + '\' + $name; logs = Join-Path $layout.Root 'logs' }
}

function Get-DelegatedMaintenanceStatus {
    $connection = Get-DelegatedMaintenanceConnection
    foreach ($name in @('InspectBuildStorage', $connection.Layout.Task)) {
        $task = $connection.Service.GetFolder($connection.Layout.Folder).GetTask($name)
        $latest = Join-Path $connection.Layout.Root ('logs\' + $(if ($name -ceq $connection.Layout.Task) { 'latest.json' } else { 'latest-preview.json' }))
        $result = if (Test-Path -LiteralPath $latest) { Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json -ErrorAction Stop } else { $null }
        [pscustomobject]@{ task = $name; state = $task.State; active_instances = $task.GetInstances(0).Count; scheduler_raw_result = $task.LastTaskResult; result = $result }
    }
}

Export-ModuleMember -Function New-DelegatedMaintenanceTask, Assert-DelegatedMaintenanceTask, Start-DelegatedMaintenance, Invoke-DelegatedMaintenanceWorker, Get-DelegatedMaintenanceStatus
