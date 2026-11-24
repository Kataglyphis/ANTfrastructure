#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ReaderSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    [string]$ExpectedBundleSha256 = '',
    [string]$StoreRoot = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'buildkitd')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scriptRoot = Split-Path $PSScriptRoot -Parent
foreach ($moduleFile in @('WindowsStevedoreDelegation.Security.psm1', 'WindowsStevedoreDelegation.Task.psm1')) {
    Import-Module (Join-Path $scriptRoot "modules\$moduleFile") -ErrorAction Stop
}
$layout = Get-DelegatedMaintenanceLayout
$null = Get-DelegatedMaintenanceSddl $ReaderSid
$sourceFiles = @(Get-DelegatedMaintenancePayload | ForEach-Object { if ($_ -like 'modules\*') { $_ } else { Join-Path 'host' $_ } })
$files = @(foreach ($relative in $sourceFiles) {
    $source = Join-Path $scriptRoot $relative
    Assert-DelegatedMaintenancePath $source
    $installed = if ($relative.StartsWith('host\')) { Split-Path $relative -Leaf } else { $relative }
    [pscustomobject]@{ path = $installed; source = $source; sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$bundle = (@($files | ForEach-Object { "$($_.path) $($_.sha256)" }) -join "`n")
$bundleSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($bundle))).ToLowerInvariant()
if ($ExpectedBundleSha256 -and $bundleSha -cne $ExpectedBundleSha256) { throw 'The reviewed source bundle changed.' }
$StoreRoot = [IO.Path]::GetFullPath($StoreRoot)
Assert-DelegatedMaintenancePath $StoreRoot
$tools = @(foreach ($name in @('buildctl.exe', 'nerdctl.exe')) {
    $path = Join-Path $layout.Tools $name
    Assert-DelegatedMaintenancePath $path -Trusted
    [pscustomobject]@{ name = $name; path = $path; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
})
if (-not $Apply) {
    [ordered]@{ state = 'preview-not-installed'; bundle_sha256 = $bundleSha; reader_sid = $ReaderSid;
        root = $layout.Root; keep_gib = 100; image_policy = 'seven media branch tag families with an existing merged image';
        container_policy = 'stopped and explicitly disposable only'; timers = $false; images_removed = 0; containers_removed = 0 } | ConvertTo-Json
    exit 0
}
Assert-DelegatedMaintenanceAdministrator 'One-time installation requires an actual Administrator PowerShell 7.'
if (Test-Path -LiteralPath $layout.Root) { throw 'Installation already exists; verify it, or revoke and archive it before replacing protected code.' }
$service = Connect-DelegatedMaintenanceScheduler
if ($null -ne (Get-DelegatedMaintenanceFolder $service $layout.Folder)) { throw 'Task folder already exists; do not replace another installation.' }
$runtimeFiles = @(Get-DelegatedMaintenanceRuntimeFiles)
New-DelegatedMaintenanceDirectory $layout.Root $ReaderSid
$installedFiles = [Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    Copy-DelegatedMaintenanceFile $file.source (Join-Path $layout.Root $file.path) $ReaderSid $file.sha256
    $installedFiles.Add([pscustomobject]@{ path = $file.path; sha256 = $file.sha256 })
}
foreach ($file in $runtimeFiles) {
    Assert-DelegatedMaintenancePath $file.FullName -Trusted
    $relative = Join-Path 'runtime' ([IO.Path]::GetRelativePath($PSHOME, $file.FullName))
    $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Copy-DelegatedMaintenanceFile $file.FullName (Join-Path $layout.Root $relative) $ReaderSid $digest
    $installedFiles.Add([pscustomobject]@{ path = $relative; sha256 = $digest })
}
New-DelegatedMaintenanceDirectory (Join-Path $layout.Root 'logs') $ReaderSid
$manifest = [ordered]@{ schema = 1; installed_utc = [datetime]::UtcNow.ToString('o'); reader_sid = $ReaderSid;
    keep_gib = 100; namespace = 'buildkit'; buildkit = 'npipe:////./pipe/buildkitd'; containerd = '\\.\pipe\containerd-containerd';
    store_root = $StoreRoot; source_bundle_sha256 = $bundleSha; files = $installedFiles.ToArray(); tools = $tools }
Write-DelegatedMaintenanceManifest $layout.Root $ReaderSid $manifest
$null = Read-DelegatedMaintenanceManifest $layout.Root
Assert-DelegatedMaintenanceRuntimeReady $layout.Root
$sddl = Get-DelegatedMaintenanceSddl $ReaderSid -Task
$folder = $service.GetFolder('\').CreateFolder($layout.Folder.TrimStart('\'), $sddl)
$registered = @(
    foreach ($name in @('InspectBuildStorage', $layout.Task)) {
        $definition = New-DelegatedMaintenanceTask $service $layout.Root -ReportOnly:($name -ceq 'InspectBuildStorage')
        $task = $folder.RegisterTaskDefinition($name, $definition, 18, 'SYSTEM', $null, 5, $sddl)
        $task.SetSecurityDescriptor($sddl, 16)
        Assert-DelegatedMaintenanceTask $task $definition $ReaderSid
        $task
    }
)
Set-DelegatedMaintenanceTasksEnabled $registered $true
[ordered]@{ state = 'installed-not-run'; bundle_sha256 = $bundleSha; reader_sid = $ReaderSid; root = $layout.Root;
    tasks = @($registered | ForEach-Object Name); no_cleanup_started = $true; normal_user_acceptance_still_required = $true } | ConvertTo-Json
exit 0
