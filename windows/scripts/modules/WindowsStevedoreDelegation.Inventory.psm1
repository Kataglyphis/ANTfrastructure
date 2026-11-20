#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsHostMaintenance.Common.psm1') -ErrorAction Stop

function Invoke-DelegatedStoreCommand {
    param([string]$Tool, [string[]]$Arguments, [string]$LogRoot, [string]$Name)
    $output = @(& $Tool @Arguments 2> (Join-Path $LogRoot "$Name.stderr.log"))
    $raw = $LASTEXITCODE
    $output | Set-Content -LiteralPath (Join-Path $LogRoot "$Name.stdout.log") -Encoding utf8
    if ($raw -ne 0) { throw "Stevedore probe failed: $Name ($raw)" }
    return $output
}

function Assert-DelegatedStoreIdle {
    param([object[]]$Usage, [string[]]$History)
    foreach ($row in $Usage) {
        if ($row.inUse -isnot [bool] -or $row.inUse -or -not $row.id -or -not $row.recordType) { throw 'BuildKit is active or unknown.' }
        if ($row.shared -isnot [bool] -or ($row.size -isnot [long] -and $row.size -isnot [int]) -or $row.size -lt 0) { throw 'BuildKit storage accounting is unknown.' }
    }
    foreach ($line in $History) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $historyEvent = $line | ConvertFrom-Json -ErrorAction Stop
        if (-not $historyEvent.record.CompletedAt -or $historyEvent.record.CompletedAt.seconds -lt $historyEvent.record.CreatedAt.seconds) { throw 'An unfinished BuildKit history remains.' }
    }
}

function Invoke-DelegatedContainerdCommand {
    param($Manifest, [string[]]$Arguments, [string]$LogRoot, [string]$Name)
    $tool = ($Manifest.tools | Where-Object name -CEQ 'nerdctl.exe').path
    Invoke-DelegatedStoreCommand $tool (@('--address', $Manifest.containerd, '--namespace', 'buildkit') + $Arguments) $LogRoot $Name
}

function Read-DelegatedContainerdJson {
    param($Manifest, [string[]]$Arguments, [string]$LogRoot, [string]$Name)
    $raw = @(Invoke-DelegatedContainerdCommand $Manifest $Arguments $LogRoot $Name)
    return @($raw -join "`n" | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-DelegatedImageTags {
    param([string[]]$Listing)
    $tags = @(foreach ($line in $Listing) {
        if (-not $line.Trim() -or $line -match '^REPOSITORY\s+TAG\s+') { continue }
        if ($line -cnotmatch '^(\S+)\s+(\S+)\s+(sha256:[0-9a-f]{64})\s+') { throw 'Image inventory format is unknown.' }
        if ($Matches[1] -ceq '<none>' -or $Matches[2] -ceq '<none>') { throw 'Untagged images require separate review.' }
        [pscustomobject]@{ Tag = $Matches[1] + ':' + $Matches[2]; Manifest = $Matches[3] }
    })
    if (@($tags | ForEach-Object Tag | Sort-Object -Unique).Count -ne $tags.Count) { throw 'Image inventory contains duplicate tags.' }
    return $tags
}

function Get-DelegatedContainerdInventory {
    param($Manifest, [string]$LogRoot, [string]$Name, [ValidateSet('image', 'container')][string]$Kind)
    $arguments = if ($Kind -ceq 'image') { @('images', '--no-trunc') } else { @('ps', '--all', '--quiet', '--no-trunc') }
    $listing = @(Invoke-DelegatedContainerdCommand $Manifest $arguments $LogRoot "$Name-$Kind-list")
    $tags = @(if ($Kind -ceq 'image') { ConvertTo-DelegatedImageTags $listing })
    $ids = @(if ($Kind -ceq 'image') { $tags | ForEach-Object Tag } else { $listing | Where-Object { $_.Trim() } })
    if (-not $ids.Count) { return @() }
    if ($Kind -ceq 'container') { foreach ($id in $ids) { if ($id -cnotmatch '^[0-9a-f]{64}$') { throw 'Container identity is unknown.' } } }
    $details = @(Read-DelegatedContainerdJson $Manifest (@($Kind, 'inspect') + $ids) $LogRoot "$Name-$Kind-details")
    if ($Kind -ceq 'image') { return @(ConvertTo-DelegatedImageInventory $tags $details) }
    if ($details.Count -ne $ids.Count) { throw 'Container inspection is incomplete.' }
    if ((@($details | ForEach-Object Id | Sort-Object -Unique) -join '|') -cne (@($ids | Sort-Object -Unique) -join '|')) { throw 'Container inspection identities differ.' }
    foreach ($item in $details) {
        $record = ConvertTo-HostContainerRecord -Container $item
        if ($record.Id -cnotin $ids -or $record.Running -or $record.Status -cnotin @('created', 'exited', 'stopped', 'dead')) { throw 'Container state is active or unknown.' }
        $record
    }
}

function ConvertTo-DelegatedImageInventory {
    param([object[]]$Tags, [object[]]$Details)
    foreach ($tag in $Tags) {
        $normalized = $tag.Tag -creplace '^docker.io/', ''
        $found = @($Details | Where-Object { $normalized -cin @($_.RepoTags | ForEach-Object { $_ -creplace '^docker.io/', '' }) })
        $ids = @($found | ForEach-Object {
            if ($null -eq $_.PSObject.Properties['Id']) { throw 'Image configuration identity is unknown.' }
            $_.Id
        } | Select-Object -Unique)
        if ($ids.Count -ne 1 -or $ids[0] -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Image configuration identity is unknown.' }
        [pscustomobject]@{ Tag = $tag.Tag; Manifest = $tag.Manifest; Config = $ids[0] }
    }
}

function Get-DelegatedStoreSnapshot {
    param($Manifest, [string]$LogRoot, [string]$Name)
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while (@(Get-Process -Name buildctl, docker, nerdctl -ErrorAction SilentlyContinue).Count) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Container clients remain active.' }
        Start-Sleep -Milliseconds 250
    }
    $tool = ($Manifest.tools | Where-Object name -CEQ 'buildctl.exe').path
    $storeArgs = @('--addr', $Manifest.buildkit)
    $history = @(Invoke-DelegatedStoreCommand $tool ($storeArgs + @('debug', 'histories', '--format', '{{json .}}')) $LogRoot "$Name-history")
    $raw = @(Invoke-DelegatedStoreCommand $tool ($storeArgs + @('du', '--format', '{{json .}}')) $LogRoot "$Name-usage")
    if (-not $raw.Count) { throw 'BuildKit usage is missing.' }
    $usage = @($raw -join "`n" | ConvertFrom-Json -ErrorAction Stop)
    Assert-DelegatedStoreIdle -Usage $usage -History $history
    $containers = @(Get-DelegatedContainerdInventory $Manifest $LogRoot $Name -Kind container)
    $images = @(Get-DelegatedContainerdInventory $Manifest $LogRoot $Name -Kind image)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Manifest.store_root))
    $free = $drive.AvailableFreeSpace
    if (-not $drive.IsReady -or $free -lt 0) { throw 'Free disk measurement is unknown.' }
    $regularBytes = 0L
    foreach ($row in $usage) { if ($row.recordType -ceq 'regular' -and -not $row.shared) { $regularBytes += $row.size } }
    [pscustomobject]@{ Images = $images; Containers = $containers; CacheMounts = @($usage | Where-Object recordType -CEQ 'exec.cachemount' | ForEach-Object id); FreeBytes = $free; UnusedPrivateRegularBytes = $regularBytes }
}

Export-ModuleMember -Function Invoke-DelegatedStoreCommand, Assert-DelegatedStoreIdle, Get-DelegatedStoreSnapshot
