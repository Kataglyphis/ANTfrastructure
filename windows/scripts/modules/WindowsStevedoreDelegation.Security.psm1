#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
foreach ($moduleFile in @('WindowsScripts.Shared.psm1', 'WindowsHostMaintenance.Common.psm1')) {
    Import-Module (Join-Path $PSScriptRoot $moduleFile) -ErrorAction Stop
}

function Assert-DelegatedMaintenanceAdministrator {
    param([string]$Reason)
    if (-not (Test-Elevated)) { throw $Reason }
}

function Get-DelegatedMaintenanceFolder {
    param($Service, [string]$Path)
    try { return $Service.GetFolder($Path) }
    catch { if ($_.Exception.HResult -ne -2147024894) { throw }; return $null }
}

function Set-DelegatedMaintenanceTasksEnabled {
    param([object[]]$Tasks, [bool]$Enabled)
    foreach ($task in $Tasks) { $task.Enabled = $Enabled }
}

function Test-DelegatedMaintenanceTaskActive {
    param($Task)
    return $Task.State -notin @(1, 3) -or $Task.GetInstances(0).Count -gt 0
}

function Connect-DelegatedMaintenanceScheduler {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    return $service
}

function Get-DelegatedMaintenanceLayout {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    [pscustomobject]@{
        Root = Join-Path $programFiles 'ANTfrastructure Maintenance v2'
        Tools = Join-Path $programFiles 'Stevedore\bin'
        Folder = '\ANTfrastructureMaintenanceV2'
        Task = 'ReclaimBuildStorage'
    }
}

function Get-DelegatedMaintenanceSddl {
    param([Parameter(Mandatory)][string]$ReaderSid, [switch]$Directory, [switch]$Task)
    if ($ReaderSid -cnotmatch '^S-1-(?:5-21-\d+-\d+-\d+-\d+|12-1-\d+-\d+-\d+-\d+)$') {
        throw 'A specific local, domain or Entra user SID is required.'
    }
    $inherit = if ($Directory) { 'OICI' } else { '' }
    $rights = if ($Task) { 'GRGX' } else { '0x1200a9' }
    $full = if ($Task) { 'GA' } else { 'FA' }
    return "O:BAG:BAD:P(A;$inherit;$full;;;SY)(A;$inherit;$full;;;BA)(A;$inherit;$rights;;;$ReaderSid)"
}

function Assert-DelegatedMaintenancePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Trusted)
    $trustedOwners = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $write = [Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $null = Get-HostNonReparseItem -Path $current
        $parent = Split-Path -Path $current -Parent
        if ($Trusted -and $parent) {
            $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedOwners) { throw "Untrusted owner: $current" }
            foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($ace.AccessControlType -ne 'Allow' -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
                if (($ace.FileSystemRights -band $write) -and $ace.IdentityReference.Value -notin $trustedOwners) { throw "Untrusted writer: $current" }
            }
        }
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function New-DelegatedMaintenanceDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ReaderSid)
    if (Test-Path -LiteralPath $Path) { Assert-DelegatedMaintenancePath $Path -Trusted; return }
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-DelegatedMaintenanceDirectory $parent $ReaderSid }
    Assert-DelegatedMaintenancePath $parent -Trusted
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm((Get-DelegatedMaintenanceSddl $ReaderSid -Directory))
    $null = [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $acl)
    Assert-DelegatedMaintenancePath $Path -Trusted
}

function New-DelegatedMaintenanceFileStream {
    param([string]$Destination, [string]$ReaderSid)
    New-DelegatedMaintenanceDirectory (Split-Path $Destination -Parent) $ReaderSid
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetSecurityDescriptorSddlForm((Get-DelegatedMaintenanceSddl $ReaderSid))
    return [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Destination), [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 65536, [IO.FileOptions]::None, $acl)
}

function Copy-DelegatedMaintenanceFile {
    param([string]$Source, [string]$Destination, [string]$ReaderSid, [string]$ExpectedHash)
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::OpenRead($Source)
        $outputStream = New-DelegatedMaintenanceFileStream $Destination $ReaderSid
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }
    Assert-DelegatedMaintenancePath $Destination -Trusted
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'Installed file hash differs.' }
}

function Write-DelegatedMaintenanceManifest {
    param([string]$Root, [string]$ReaderSid, $Manifest)
    $stream = New-DelegatedMaintenanceFileStream (Join-Path $Root 'installed.json') $ReaderSid
    try { $stream.Write([Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 8))) }
    finally { $stream.Dispose() }
}

function Get-DelegatedMaintenanceRuntimeFiles {
    Assert-DelegatedMaintenancePath $PSHOME -Trusted
    $runtimeFiles = @(Get-ChildItem -LiteralPath $PSHOME -Recurse -File -Force -ErrorAction Stop)
    if (-not $runtimeFiles.Count) { throw 'PowerShell runtime is empty.' }
    foreach ($item in Get-ChildItem -LiteralPath $PSHOME -Recurse -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PowerShell runtime contains a reparse point.' }
    }
    return $runtimeFiles
}

function Assert-DelegatedMaintenanceRuntimeReady {
    param([string]$Root)
    $runtime = @(& (Join-Path $Root 'runtime\pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')
    if ($LASTEXITCODE -ne 0 -or $runtime.Count -ne 1 -or $runtime[0] -notmatch '^7\.') { throw 'Protected PowerShell runtime cannot start.' }
}

function Get-DelegatedMaintenancePayload {
    return @(
        'Clear-DiskSpace.ps1', 'Invoke-StevedoreMaintenanceWorker.ps1',
        'modules\WindowsStevedoreDelegation.Security.psm1', 'modules\WindowsStevedoreDelegation.Policy.psm1',
        'modules\WindowsStevedoreDelegation.Inventory.psm1', 'modules\WindowsStevedoreDelegation.Task.psm1',
        'modules\WindowsHostMaintenance.Common.psm1', 'modules\WindowsScripts.Shared.psm1'
    )
}

function Assert-DelegatedMaintenancePolicy {
    param($Manifest)
    if ($manifest.schema -ne 1 -or $manifest.keep_gib -ne 100 -or $manifest.namespace -cne 'buildkit') { throw 'Installed maintenance policy differs.' }
    if ($manifest.buildkit -cne 'npipe:////./pipe/buildkitd' -or $manifest.containerd -cne '\\.\pipe\containerd-containerd') { throw 'Installed daemon endpoints differ.' }
    if ($manifest.files.Count -lt 9 -or $manifest.tools.Count -ne 2) { throw 'Installed closure is incomplete.' }
    if ((@($manifest.tools | ForEach-Object name | Sort-Object) -join '|') -cne 'buildctl.exe|nerdctl.exe') { throw 'Installed tool names differ.' }
}

function Read-DelegatedMaintenanceManifest {
    param([Parameter(Mandatory)][string]$Root)
    $layout = Get-DelegatedMaintenanceLayout
    if ($Root -cne $layout.Root) { throw 'Maintenance root differs from the fixed installation.' }
    $path = Join-Path $Root 'installed.json'
    Assert-DelegatedMaintenancePath $path -Trusted
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-DelegatedMaintenancePolicy $manifest
    $paths = @($manifest.files | ForEach-Object path)
    if (@($paths | Sort-Object -Unique).Count -ne $paths.Count) { throw 'Installed closure contains duplicates.' }
    foreach ($required in Get-DelegatedMaintenancePayload) {
        if ($required -cnotin $paths) { throw 'A required maintenance payload is missing.' }
    }
    $null = Get-DelegatedMaintenanceSddl $manifest.reader_sid
    foreach ($file in $manifest.files) {
        $target = [IO.Path]::GetFullPath((Join-Path $Root $file.path))
        if (-not $target.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed file escapes the maintenance root.' }
        Assert-DelegatedMaintenancePath $target -Trusted
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw "Installed maintenance file changed: $($file.path)" }
    }
    foreach ($tool in $manifest.tools) {
        if ($tool.path -cne (Join-Path $layout.Tools $tool.name)) { throw 'Installed tool location differs.' }
        Assert-DelegatedMaintenancePath $tool.path -Trusted
        if ((Get-FileHash -LiteralPath $tool.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tool.sha256) { throw 'Installed Stevedore tool changed; reinstall after review.' }
    }
    return $manifest
}

Export-ModuleMember -Function *-DelegatedMaintenance*
