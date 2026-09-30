#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Host-side BuildKit helpers, kept out of WindowsScripts.Shared, whose edits rebuild the whole chain from the base image.

Set-StrictMode -Version Latest

function Test-IpInSubnet {
    <#
    .SYNOPSIS
        IPv4 CIDR containment: is $Ip inside $Cidr (e.g. '172.31.32.0/20')?
    #>
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Cidr
    )
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { throw "Test-IpInSubnet: '$Cidr' is not CIDR notation" }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "Test-IpInSubnet: prefix /$prefix out of range" }
    # Reverse byte order: GetAddressBytes is big-endian, ToUInt32 wants little.
    $ipBits  = [BitConverter]::ToUInt32(([System.Net.IPAddress]::Parse($Ip).GetAddressBytes()[3..0]), 0)
    $netBits = [BitConverter]::ToUInt32(([System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()[3..0]), 0)
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32](([long]4294967295 -shl (32 - $prefix)) -band [long]4294967295) }
    return (($ipBits -band $mask) -eq ($netBits -band $mask))
}

function Get-CniNatSubnetDrift {
    <#
    .SYNOPSIS
        CNI-vs-HNS nat subnet drift: $null when healthy, else a ready-to-throw diagnosis.
    .DESCRIPTION
        A dockerd restart recreates the nat network on a new subnet, orphaning the CNI conf and killing container egress.
    #>
    param(
        # Both names, or "absent = nothing to judge" silently skips whichever one is missing.
        [string[]]$ConfPath = @(
            'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist',
            'C:\Program Files\containerd\cni\conf\0-containerd-nat.conf'
        ),
        # Test seam: injected adapter IP / conf text override the live lookups.
        [string]$AdapterIp = '',
        [string]$ConfText = ''
    )
    $confFile = ''
    if (-not $ConfText) {
        $confFile = @($ConfPath | Where-Object { Test-Path $_ }) | Select-Object -First 1
        if (-not $confFile) { return $null }  # no conf = no drift to judge (network setup docs cover absence)
        $ConfText = Get-Content -Raw $confFile
    }
    # An explicitly bound empty -AdapterIp means "adapter absent" and must not fall through to the live adapter.
    if (-not $AdapterIp -and -not $PSBoundParameters.ContainsKey('AdapterIp')) {
        $AdapterIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -match '^vEthernet \(nat\)$' } |
            Select-Object -First 1 -ExpandProperty IPAddress)
    }
    $confSubnet = ([regex]::Match($ConfText, '"subnet"\s*:\s*"([^"]+)"')).Groups[1].Value
    if (-not $AdapterIp -or -not $confSubnet) { return $null }
    if (Test-IpInSubnet -Ip $AdapterIp -Cidr $confSubnet) { return $null }
    $where = if ($confFile) { $confFile } else { 'the CNI nat conf' }
    return ("CNI nat subnet drift: conf pins $confSubnet but the live 'vEthernet (nat)' adapter is $AdapterIp. " +
            "BK containers would get unroutable IPs (no DNS/egress). Fix (admin): update the ipam.subnet/GW in " +
            "$where to the adapter's subnet (e.g. gateway $AdapterIp), then Restart-Service buildkitd -Force.")
}

function ConvertFrom-CniConfList {
    <#
    .SYNOPSIS
        Derives the single-plugin .conf text from a .conflist; rejects multi-plugin lists instead of truncating.
    .DESCRIPTION
        See docs/windows-build-invariants.md § The CNI .conf is DERIVED from the .conflist, not hand-edited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfListText)

    $list = $ConfListText | ConvertFrom-Json
    # Existence, not truthiness: under StrictMode a missing property throws before -not sees it.
    if (-not ($list.PSObject.Properties.Name -contains 'plugins')) {
        throw 'not a conflist: no plugins[] array present'
    }
    $plugins = @($list.plugins)
    if ($plugins.Count -ne 1) {
        throw ("conflist carries $($plugins.Count) plugins; the .conf form holds exactly one. " +
            'Collapsing it would silently drop configuration — split the deployment by hand instead.')
    }
    # Identity first, then the plugin body: the conventional CNI order, so a rewrite does not reshuffle the file.
    $conf = [ordered]@{}
    foreach ($key in 'cniVersion', 'name') {
        if ($list.PSObject.Properties.Name -contains $key) { $conf[$key] = $list.$key }
    }
    # The plugin must not be able to override the identity fields above.
    foreach ($p in $plugins[0].PSObject.Properties) {
        if ($conf.Contains($p.Name)) { continue }
        $conf[$p.Name] = $p.Value
    }
    return ($conf | ConvertTo-Json -Depth 10)
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        Key-sorted, whitespace-free JSON for comparing documents; a ConvertTo-Json round-trip keeps parse order.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject)

    $canon = {
        param($node)
        if ($null -eq $node) { return $null }
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $ordered = [ordered]@{}
            foreach ($name in ($node.PSObject.Properties.Name | Sort-Object)) {
                $ordered[$name] = & $canon $node.$name
            }
            return $ordered
        }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            return @($node | ForEach-Object { & $canon $_ })
        }
        return $node
    }
    return ((& $canon $InputObject) | ConvertTo-Json -Depth 20 -Compress)
}

function Get-CniConfFormIssue {
    <#
    .SYNOPSIS
        A CNI conf missing under the name the buildctl lane reads: $null when healthy, else a ready-to-throw diagnosis.
    .DESCRIPTION
        See docs/windows-build-invariants.md § The CNI nat config must exist as BOTH .conf AND .conflist.
    #>
    param(
        [string]$ConfDir = 'C:\Program Files\containerd\cni\conf',
        [string]$BuildkitConfName = '0-containerd-nat.conf',
        [string]$NerdctlConfName = '0-containerd-nat.conflist',
        # Test seam: when set, these override the on-disk probes.
        [Nullable[bool]]$BuildkitConfExists = $null,
        [Nullable[bool]]$NerdctlConfExists = $null
    )
    $bkPath = Join-Path $ConfDir $BuildkitConfName
    $ndPath = Join-Path $ConfDir $NerdctlConfName
    $haveBk = if ($null -ne $BuildkitConfExists) { [bool]$BuildkitConfExists } else { Test-Path $bkPath }
    $haveNd = if ($null -ne $NerdctlConfExists) { [bool]$NerdctlConfExists } else { Test-Path $ndPath }

    if (-not $haveBk -and -not $haveNd) {
        return ("No CNI nat conf found in $ConfDir. BuildKit RUN steps will have NO network adapter and the first " +
            'downloading step dies with "Could not resolve host". Fix (admin): install both forms — see ' +
            'docs/windows-builds.md § BuildKit/containerd lane, step 2.')
    }
    if (-not $haveBk) {
        return ("CNI conf present as .conflist ONLY ($ndPath) — buildkitd does not pick that up and will give " +
            "containers NO NETWORK ADAPTER (measured 2026-08-07: empty ipconfig, 'unreachable network' on a raw " +
            "TCP connect, no networking block in the HCS spec). nerdctl needs the .conflist, so keep it and ADD " +
            "the .conf. Fix (admin): Copy-Item '$ndPath' '$bkPath'  # or restore the .conf.disabled backup, then " +
            'edit it back to the single-plugin form; then Restart-Service buildkitd -Force.')
    }
    if (-not $haveNd) {
        # Not fatal here: the buildctl chain works on the .conf alone.
        return $null
    }
    return $null
}

Export-ModuleMember -Function Test-IpInSubnet, Get-CniNatSubnetDrift, Get-CniConfFormIssue,
    ConvertFrom-CniConfList, ConvertTo-CanonicalJson
