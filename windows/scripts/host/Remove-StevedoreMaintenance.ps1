#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
[CmdletBinding()]
param([switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsStevedoreDelegation.Security.psm1') -ErrorAction Stop
$layout = Get-DelegatedMaintenanceLayout
Assert-DelegatedMaintenanceAdministrator 'Revoking a SYSTEM task requires an actual Administrator PowerShell 7.'
Assert-DelegatedMaintenancePath $layout.Root -Trusted
$service = Connect-DelegatedMaintenanceScheduler
$folder = Get-DelegatedMaintenanceFolder $service $layout.Folder
$tasks = if ($null -ne $folder) { @($folder.GetTasks(1)) } else { @() }
if (@($tasks | Where-Object { $_.Name -cnotin @('InspectBuildStorage', $layout.Task) }).Count) { throw 'Unexpected tasks exist; no revocation performed.' }
foreach ($task in $tasks) { if ($task.GetInstances(0).Count) { throw 'Maintenance is active; nothing stopped or removed.' } }
$archive = $layout.Root + '.revoked-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
if ((Split-Path $archive -Parent) -cne (Split-Path $layout.Root -Parent) -or (Test-Path -LiteralPath $archive)) { throw 'Revocation archive target differs.' }
if (-not $Apply) { [ordered]@{ state = 'preview'; archive = $archive; logs_preserved = $true; no_deletion = $true } | ConvertTo-Json; exit 0 }
Set-DelegatedMaintenanceTasksEnabled $tasks $false
foreach ($task in $tasks) { if ($task.GetInstances(0).Count) { throw 'Maintenance started before disabling; task retained.' }; $folder.DeleteTask($task.Name, 0) }
if ($null -ne $folder) { $service.GetFolder('\').DeleteFolder($layout.Folder.TrimStart('\'), 0) }
Move-Item -LiteralPath $layout.Root -Destination $archive -ErrorAction Stop
[ordered]@{ state = 'revoked-and-archived'; archive = $archive; logs_preserved = $true; files_deleted = 0 } | ConvertTo-Json
exit 0
