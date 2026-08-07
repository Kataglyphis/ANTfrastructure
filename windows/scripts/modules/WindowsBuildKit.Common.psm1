# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
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
        # BOTH CNI forms, most-preferred first. nerdctl cannot parse a bare
        # .conf: it indexes plugins[0] without a length check and PANICS (index
        # out of range) on the single-plugin form — in `network create`
        # (netutil_windows.go:40) and again in `run`
        # (container_network_manager.go:857).
        # CORRECTION (measured 2026-08-07): the earlier claim here that "BuildKit
        # reads either form" is FALSE. With only the .conflist present, buildkitd
        # gave its containers NO network adapter at all. BOTH files must exist —
        # see Get-CniConfFormIssue, which is the check for that; THIS function
        # only judges subnet drift and passed happily while the lane had no
        # network, because drift and absence are different failures.
        # Checking both names still matters here: this function's "file absent =
        # nothing to judge" contract would otherwise make it a silent no-op on
        # whichever name happens to be missing.
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
    $where = if ($confFile) { $confFile } else { 'the CNI nat conf' }
    return ("CNI nat subnet drift: conf pins $confSubnet but the live 'vEthernet (nat)' adapter is $AdapterIp. " +
            "BK containers would get unroutable IPs (no DNS/egress). Fix (admin): update the ipam.subnet/GW in " +
            "$where to the adapter's subnet (e.g. gateway $AdapterIp), then Restart-Service buildkitd -Force.")
}

function Get-CniConfFormIssue {
    <#
    .SYNOPSIS
        Detects a CNI conf present under the WRONG FILENAME for the buildctl
        lane. Returns $null when healthy, else a ready-to-throw diagnosis.
    .DESCRIPTION
        MEASURED 2026-08-07, and it cost a launched chain: with ONLY
        0-containerd-nat.conflist present, buildkitd gives its containers NO
        NETWORK ADAPTER AT ALL. Not a DNS problem — a probe container showed an
        empty `ipconfig`, and a raw TCP connect to a literal GitHub IP failed
        with "unreachable network". The containerd debug log confirmed it: the
        HcsCreateComputeSystem spec for buildkitsandbox carried Storage,
        MappedDirectories and MappedPipes but no networking block. Restoring
        0-containerd-nat.conf (keeping the .conflist) and restarting buildkitd
        fixed it immediately: IPv4 172.31.44.107, gateway 172.31.32.1, DNS
        192.168.188.1, github.com resolved.

        So the two clients genuinely disagree, and the repo's earlier claim that
        "containerd and BuildKit read either form" is FALSE:
          * buildkitd needs the .conf  — it does not pick up a .conflist-only dir
          * nerdctl needs the .conflist — it indexes plugins[0] with no length
            check and PANICS on the single-plugin .conf form
        Therefore BOTH files must exist. Keeping them in sync is the price of
        having both lanes.

        The subnet-drift guard cannot catch this: it checks whichever form it
        finds and passed happily while the lane had no network at all. Different
        failure, different check.
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
        # Not fatal for THIS lane — the buildctl chain works on the .conf alone.
        # Reported so the nerdctl lane's absence is a known state, not a surprise
        # the next time someone needs `nerdctl images`.
        return $null
    }
    return $null
}

Export-ModuleMember -Function Test-IpInSubnet, Get-CniNatSubnetDrift, Get-CniConfFormIssue
