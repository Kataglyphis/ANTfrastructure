#requires -Version 7.0
# Tests for WindowsBuildKit.Common.psm1 — the CNI nat subnet-drift guard's math.
# A wrong mask here makes build-buildkit.ps1's preflight PASS a drifted config,
# which is exactly the silent no-network failure the guard exists to prevent
# (cost a chain launch on 2026-08-03).

Describe 'Test-IpInSubnet' {

    It 'accepts addresses inside the subnet across prefix widths' {
        $cases = @(
            @{ Ip = '172.31.32.1';   Cidr = '172.31.32.0/20' }   # gateway itself
            @{ Ip = '172.31.47.254'; Cidr = '172.31.32.0/20' }   # last host of /20
            @{ Ip = '172.20.0.1';    Cidr = '172.20.0.0/16' }
            @{ Ip = '10.1.2.3';      Cidr = '10.0.0.0/8' }
            @{ Ip = '192.168.188.125'; Cidr = '192.168.188.0/24' }
            @{ Ip = '1.2.3.4';       Cidr = '0.0.0.0/0' }        # /0 matches everything
            @{ Ip = '172.31.32.1';   Cidr = '172.31.32.1/32' }   # /32 exact match
        )
        foreach ($c in $cases) {
            Assert-True (Test-IpInSubnet -Ip $c.Ip -Cidr $c.Cidr) "$($c.Ip) must be inside $($c.Cidr)"
        }
    }

    It 'rejects addresses outside the subnet (the 2026-08-03 drift shape included)' {
        $cases = @(
            @{ Ip = '172.31.32.1';  Cidr = '172.20.0.0/16' }   # the real incident: adapter vs stale conf
            @{ Ip = '172.31.48.1';  Cidr = '172.31.32.0/20' }  # one past the /20 boundary
            @{ Ip = '172.30.32.1';  Cidr = '172.31.32.0/20' }
            @{ Ip = '11.0.0.1';     Cidr = '10.0.0.0/8' }
            @{ Ip = '172.31.32.2';  Cidr = '172.31.32.1/32' }
        )
        foreach ($c in $cases) {
            Assert-False (Test-IpInSubnet -Ip $c.Ip -Cidr $c.Cidr) "$($c.Ip) must be OUTSIDE $($c.Cidr)"
        }
    }

    It 'throws on malformed CIDR input instead of guessing' {
        Assert-Throws { Test-IpInSubnet -Ip '10.0.0.1' -Cidr '10.0.0.0' } 'missing prefix must throw'
        Assert-Throws { Test-IpInSubnet -Ip '10.0.0.1' -Cidr '10.0.0.0/33' } 'prefix over 32 must throw'
    }
}

Describe 'Get-CniNatSubnetDrift' {

    It 'returns $null when the adapter sits inside the conf subnet' {
        $conf = '{ "ipam": { "subnet": "172.31.32.0/20" } }'
        $r = Get-CniNatSubnetDrift -ConfText $conf -AdapterIp '172.31.32.1'
        Assert-True ($null -eq $r) 'healthy config must not report drift'
    }

    It 'returns a diagnosis naming both sides when drifted (the real incident shape)' {
        $conf = '{ "ipam": { "subnet": "172.20.0.0/16" } }'
        $r = Get-CniNatSubnetDrift -ConfText $conf -AdapterIp '172.31.32.1'
        Assert-True ($null -ne $r) 'drifted config must report'
        Assert-True ($r -like '*172.20.0.0/16*') 'diagnosis names the conf subnet'
        Assert-True ($r -like '*172.31.32.1*') 'diagnosis names the live adapter IP'
        Assert-True ($r -like '*Restart-Service buildkitd -Force*') 'diagnosis carries the fix'
    }

    It 'judges the .conflist form too (the host standardises on it for nerdctl)' {
        # nerdctl panics on a bare single-plugin .conf, so 0-containerd-nat.conf
        # was converted to conflist form on 2026-08-07. The drift guard must read
        # the nested plugins[].ipam shape, or it silently stops guarding.
        $conflist = '{ "cniVersion": "0.3.0", "name": "nat", "plugins": [ { "type": "nat", "ipam": { "subnet": "172.20.0.0/16" } } ] }'
        $r = Get-CniNatSubnetDrift -ConfText $conflist -AdapterIp '172.31.32.1'
        Assert-True ($null -ne $r) 'a drifted conflist must still report drift'
        Assert-True ($r -like '*172.20.0.0/16*') 'diagnosis names the conflist subnet'

        $healthy = '{ "cniVersion": "0.3.0", "name": "nat", "plugins": [ { "type": "nat", "ipam": { "subnet": "172.31.32.0/20" } } ] }'
        Assert-True ($null -eq (Get-CniNatSubnetDrift -ConfText $healthy -AdapterIp '172.31.32.1')) 'healthy conflist must not report drift'
    }

    It 'returns $null (not a throw) when the conf has no subnet or the adapter is absent' {
        Assert-True ($null -eq (Get-CniNatSubnetDrift -ConfText '{}' -AdapterIp '172.31.32.1')) 'no subnet key = no judgement'
        Assert-True ($null -eq (Get-CniNatSubnetDrift -ConfText '{ "ipam": { "subnet": "172.20.0.0/16" } }' -AdapterIp $null)) 'no adapter = no judgement'
    }
}

Describe 'Get-CniConfFormIssue (wrong-filename guard)' {

    # 2026-08-07: the .conf was renamed to .conflist to stop nerdctl panicking,
    # and buildkitd silently lost container networking — empty ipconfig,
    # "unreachable network" on a raw TCP connect, no networking block in the HCS
    # spec. The drift guard passed green throughout, because drift and absence
    # are different failures. These cases pin the distinction.

    It 'passes when BOTH forms are present (the only healthy state)' {
        Assert-Null (Get-CniConfFormIssue -BuildkitConfExists $true -NerdctlConfExists $true) `
            'both files present = both lanes work'
    }

    It 'FAILS on conflist-only — the exact 2026-08-07 shape' {
        $issue = Get-CniConfFormIssue -BuildkitConfExists $false -NerdctlConfExists $true
        Assert-NotNull $issue 'conflist-only must be reported'
        Assert-Match 'NO NETWORK ADAPTER' $issue 'the message must name the actual symptom'
        Assert-Match 'Restart-Service buildkitd' $issue 'the message must carry the fix'
    }

    It 'FAILS when no conf exists at all' {
        $issue = Get-CniConfFormIssue -BuildkitConfExists $false -NerdctlConfExists $false
        Assert-NotNull $issue 'a missing conf is fatal for this lane'
        Assert-Match 'No CNI nat conf found' $issue
    }

    It 'does NOT fail the buildctl lane on conf-only (nerdctl absence is not this lane s problem)' {
        # The chain builds fine on the .conf alone; only nerdctl breaks. Failing
        # here would block builds for a tool the build does not use.
        Assert-Null (Get-CniConfFormIssue -BuildkitConfExists $true -NerdctlConfExists $false) `
            'conf-only must not block the buildctl lane'
    }
}

Describe 'ConvertFrom-CniConfList (derive the .conf from the .conflist)' {

    # The host needs both forms; keeping them as hand-edited copies is the
    # two-copies drift this repo eliminates elsewhere. Authored = conflist,
    # derived = conf.

    It 'unwraps the single plugin and keeps the network identity' {
        $list = @'
{
  "cniVersion": "0.3.0",
  "name": "nat",
  "plugins": [
    { "type": "nat", "master": "Ethernet",
      "ipam": { "subnet": "172.31.32.0/20", "routes": [ { "GW": "172.31.32.1" } ] },
      "capabilities": { "portMappings": true, "dns": true } }
  ]
}
'@
        $conf = ConvertFrom-CniConfList -ConfListText $list | ConvertFrom-Json
        Assert-Equal 'nat' $conf.name 'network name must survive'
        Assert-Equal '0.3.0' $conf.cniVersion 'cniVersion must survive'
        Assert-Equal 'nat' $conf.type 'the plugin type moves to the top level'
        Assert-Equal 'Ethernet' $conf.master
        Assert-Equal '172.31.32.0/20' $conf.ipam.subnet 'the load-bearing field must survive'
        # Property-existence, not truthiness: StrictMode throws on a missing one.
        Assert-False ($conf.PSObject.Properties.Name -contains 'plugins') 'the .conf form has no plugins[] array'
    }

    It 'REFUSES a multi-plugin conflist instead of silently taking plugins[0]' {
        # Truncating to plugins[0] is exactly the unchecked indexing that makes
        # nerdctl panic; doing it ourselves would drop configuration silently.
        $list = '{ "cniVersion": "0.3.0", "name": "nat", "plugins": [ {"type":"nat"}, {"type":"portmap"} ] }'
        Assert-Throws -MessagePattern '2 plugins' -Body { ConvertFrom-CniConfList -ConfListText $list }
    }

    It 'rejects input that is not a conflist at all' {
        Assert-Throws -MessagePattern 'no plugins' -Body {
            ConvertFrom-CniConfList -ConfListText '{ "cniVersion": "0.3.0", "name": "nat", "type": "nat" }'
        }
    }

    It 'round-trips the live host conf when both files are present' {
        # Guards the real invariant: whatever is deployed must be derivable.
        $listPath = 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist'
        $confPath = 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conf'
        if ((Test-Path $listPath) -and (Test-Path $confPath)) {
            $derived = ConvertFrom-CniConfList -ConfListText (Get-Content $listPath -Raw) | ConvertFrom-Json
            $live = Get-Content $confPath -Raw | ConvertFrom-Json
            Assert-Equal $live.ipam.subnet $derived.ipam.subnet 'live .conf subnet must match what the .conflist derives'
            Assert-Equal $live.name $derived.name
        } else {
            Write-Host '    (skipped: CNI confs not present on this machine)'
        }
    }
}

Describe 'ConvertTo-CanonicalJson (order-independent comparison)' {

    # The first CNI sync check compared ConvertFrom-Json | ConvertTo-Json, which
    # preserves parse order, and reported the reference host as "out of sync"
    # while the two files were identical apart from field order. A guard that
    # cries wolf gets ignored, so comparison is canonical.

    It 'treats documents differing only in key order as equal' {
        $a = '{ "cniVersion": "0.3.0", "name": "nat", "type": "nat" }' | ConvertFrom-Json
        $b = '{ "type": "nat", "name": "nat", "cniVersion": "0.3.0" }' | ConvertFrom-Json
        Assert-Equal (ConvertTo-CanonicalJson -InputObject $a) (ConvertTo-CanonicalJson -InputObject $b) `
            'field order is not a semantic difference'
    }

    It 'sorts nested objects too' {
        $a = '{ "ipam": { "subnet": "1.2.3.0/24", "routes": [ { "GW": "1.2.3.1" } ] } }' | ConvertFrom-Json
        $b = '{ "ipam": { "routes": [ { "GW": "1.2.3.1" } ], "subnet": "1.2.3.0/24" } }' | ConvertFrom-Json
        Assert-Equal (ConvertTo-CanonicalJson -InputObject $a) (ConvertTo-CanonicalJson -InputObject $b)
    }

    It 'still reports a REAL difference (the subnet actually changed)' {
        $a = '{ "ipam": { "subnet": "172.31.32.0/20" } }' | ConvertFrom-Json
        $b = '{ "ipam": { "subnet": "172.20.0.0/16" } }' | ConvertFrom-Json
        Assert-True ((ConvertTo-CanonicalJson -InputObject $a) -ne (ConvertTo-CanonicalJson -InputObject $b)) `
            'a changed value must NOT be normalised away'
    }

    It 'preserves array ORDER (it is meaningful in CNI routes)' {
        $a = '{ "routes": [ { "GW": "1.1.1.1" }, { "GW": "2.2.2.2" } ] }' | ConvertFrom-Json
        $b = '{ "routes": [ { "GW": "2.2.2.2" }, { "GW": "1.1.1.1" } ] }' | ConvertFrom-Json
        Assert-True ((ConvertTo-CanonicalJson -InputObject $a) -ne (ConvertTo-CanonicalJson -InputObject $b)) `
            'sorting arrays would hide a real ordering change'
    }

    It 'derives a .conf that matches the live one on this host' {
        $listPath = 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist'
        $confPath = 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conf'
        if ((Test-Path $listPath) -and (Test-Path $confPath)) {
            $derived = ConvertFrom-CniConfList -ConfListText (Get-Content $listPath -Raw)
            Assert-Equal (ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json (Get-Content $confPath -Raw))) `
                         (ConvertTo-CanonicalJson -InputObject (ConvertFrom-Json $derived)) `
                         'the deployed .conf must be derivable from the .conflist'
        } else {
            Write-Host '    (skipped: CNI confs not present on this machine)'
        }
    }
}
