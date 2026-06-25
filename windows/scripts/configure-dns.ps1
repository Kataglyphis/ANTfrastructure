# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string[]]$DnsServers = @('8.8.8.8', '1.1.1.1')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# DEPRECATED: nerdctl build has known DNS issues on Windows.
# Use Stevedore's docker.exe instead (see AGENTS.md § Windows Container Build).
# This script remains as a fallback for hosts that cannot use docker.exe.
Write-Host 'Configuring DNS for BuildKit container...'

$adapters = Get-NetAdapter -ErrorAction SilentlyContinue
if ($adapters) {
    $adapters | Set-DnsClientServerAddress -ServerAddresses $DnsServers
    Write-Host "DNS configured with servers: $($DnsServers -join ', ')"

    # Verify DNS works
    try {
        $result = Resolve-DnsName -Name 'aka.ms' -Type A -ErrorAction Stop
        Write-Host "DNS verified: aka.ms -> $($result.IPAddress)"
    } catch {
        Write-Host "DNS resolution still failing: $($_.Exception.Message)"
    }
} else {
    Write-Host 'No network adapters found, falling back to hosts file entries'
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

    $seenHosts = @{}
    $entries = @(
        '185.199.108.133 aka.ms'
        '185.199.109.133 aka.ms'
        '185.199.110.133 aka.ms'
        '185.199.111.133 aka.ms'
        '140.82.121.5 github.com'
        '140.82.121.6 github.com'
        '140.82.112.4 api.github.com'
        '185.199.108.133 raw.githubusercontent.com'
        '185.199.109.133 raw.githubusercontent.com'
        '185.199.110.133 raw.githubusercontent.com'
        '185.199.111.133 raw.githubusercontent.com'
        '151.101.130.137 dl.google.com'
        '142.250.185.195 storage.googleapis.com'
        '185.199.108.133 cmake.org'
        '185.199.109.133 cmake.org'
        '185.199.110.133 cmake.org'
        '185.199.111.133 cmake.org'
        '151.101.130.133 sdk.lunarg.com'
        '104.16.26.34 get.scoop.sh'
        '91.189.91.38 hudson.mirrorer.canonical.com'
        '20.205.243.166 nvidia.com'
        '23.218.150.211 developer.download.nvidia.com'
        '23.218.150.211 developer.nvidia.com'
        '23.216.191.84 dist.nuget.org'
        '151.101.130.133 nuget.org'
        '151.101.194.133 api.nuget.org'
        '52.168.117.195 bootstrap.pypa.io'
        '23.56.121.94 files.pythonhosted.org'
        '151.101.130.137 static.rust-lang.org'
    )

    $existing = Get-Content $hostsPath -ErrorAction SilentlyContinue
    $added = 0
    foreach ($entry in $entries) {
        $hostname = ($entry -split '\s+')[1]
        if ($seenHosts.ContainsKey($hostname)) { continue }
        $seenHosts[$hostname] = $true
        if ($existing -notcontains $entry -and $existing -notcontains "# $entry") {
            Add-Content -Path $hostsPath -Value $entry -Encoding ASCII
            $added++
        }
    }
    Write-Host "Added $added static host entries to $hostsPath"
}

Write-Host 'DNS configuration complete.'
