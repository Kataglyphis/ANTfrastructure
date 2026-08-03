# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# BuildKit-lane helpers (host-side; consumed by windows/build-buildkit.ps1 and
# the test suites). Deliberately a SEPARATE module from WindowsScripts.Shared:
# the shared module is COPY'd into the base image, so edits there cascade a
# full-chain rebuild — this one is only picked up by the final stage's
# whole-dir modules COPY (cheap) and never by the builder images.

Set-StrictMode -Version Latest

function Test-IpInSubnet {
    <#
    .SYNOPSIS
        Pure CIDR containment check: is $Ip inside $Cidr (e.g. '172.31.32.0/20')?
    .NOTES
        IPv4 only. The bit-math lives here (instead of inline in the CNI drift
        guard) because a silent mistake here makes the guard PASS drifted
        configs — the exact failure it exists to prevent. Table-tested in
        windows/scripts/tests/BuildKit.Subnet.Tests.ps1.
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
        Detects CNI-vs-HNS nat subnet drift. Returns $null when healthy, else a
        ready-to-throw diagnosis string (caller decides whether to throw).
    .DESCRIPTION
        dockerd restarts recreate the Windows 'nat' HNS network on a new subnet,
        silently orphaning the static CNI conf — BK containers then get IPs whose
        gateway does not exist (no DNS, no egress; the first downloading RUN dies
        with "remote name could not be resolved"). Compares the conf's ipam.subnet
        against the live 'vEthernet (nat)' adapter address.
    #>
    param(
        [string]$ConfPath = 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conf',
        # Test seam: injected adapter IP / conf text override the live lookups.
        [string]$AdapterIp = '',
        [string]$ConfText = ''
    )
    if (-not $ConfText) {
        if (-not (Test-Path $ConfPath)) { return $null }  # no conf = no drift to judge (network setup docs cover absence)
        $ConfText = Get-Content -Raw $ConfPath
    }
    # Live lookup only when the caller did not bind -AdapterIp at all: an
    # explicitly passed empty value means "adapter absent" (test seam) and must
    # NOT fall through to the real host adapter.
    if (-not $AdapterIp -and -not $PSBoundParameters.ContainsKey('AdapterIp')) {
        $AdapterIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -match '^vEthernet \(nat\)$' } |
            Select-Object -First 1 -ExpandProperty IPAddress)
    }
    $confSubnet = ([regex]::Match($ConfText, '"subnet"\s*:\s*"([^"]+)"')).Groups[1].Value
    if (-not $AdapterIp -or -not $confSubnet) { return $null }
    if (Test-IpInSubnet -Ip $AdapterIp -Cidr $confSubnet) { return $null }
    return ("CNI nat subnet drift: conf pins $confSubnet but the live 'vEthernet (nat)' adapter is $AdapterIp. " +
            "BK containers would get unroutable IPs (no DNS/egress). Fix (admin): update the ipam.subnet/GW in " +
            "$ConfPath to the adapter's subnet (e.g. gateway $AdapterIp), then Restart-Service buildkitd -Force.")
}

Export-ModuleMember -Function Test-IpInSubnet, Get-CniNatSubnetDrift
