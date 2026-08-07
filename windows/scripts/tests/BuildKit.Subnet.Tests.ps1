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
