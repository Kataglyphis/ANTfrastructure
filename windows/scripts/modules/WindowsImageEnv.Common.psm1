#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The Windows publish gate: a published image's environment carries no build-host
# setting. Twin of linux/scripts/verify_image_env.py, graded by the same fixture
# (linux/scripts/tests/image-env-cases.json). Dependency-free, because
# windows/Dockerfile.publish-gate mounts this one file.
# docs/windows-build-resources.md#what-the-published-image-carries

Set-StrictMode -Version Latest

# The build host's cache layout and every sccache REMOTE backend. Local defaults
# (SCCACHE_DIR, _CACHE_SIZE, _ERROR_LOG, _LOG, _IDLE_TIMEOUT) are allowed.
$script:BuildHostName = '^SCCACHE_(?:WEBDAV_\w+|REDIS\w*|MEMCACHED\w*|GCS_\w+|AZURE_\w+|S3_\w+|OSS_\w+|' +
    'COS_\w+|GHA_\w+|BUCKET|ENDPOINT|REGION|MULTILEVEL_CHAIN|FORCE_LOCAL)$'
$script:Ipv4 = [regex]'(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])'
$script:Ipv6LinkLocal = [regex]::new('(?:^|[\s,;=\[@"''(])(fe[89ab][0-9a-f]:[0-9a-f:.%]*)', 'IgnoreCase')
$script:Lead = " `t,;=`"'(["
$script:Trail = " `t,;`"')]"

# RFC1918 or 169.254/16; a leading-zero octet is not an address (as in Python's ipaddress).
function Test-PrivateIPv4 {
    param([Parameter(Mandatory)][string]$Text)
    $octets = @($Text.Split('.') | ForEach-Object { if ($_ -match '^(0|[1-9]\d{0,2})$') { [int]$_ } else { -1 } })
    if ($octets.Count -ne 4 -or @($octets | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count -gt 0) { return $false }
    return ($octets[0] -eq 10) -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168) -or ($octets[0] -eq 169 -and $octets[1] -eq 254)
}

# Is Value[Start..End) an address, or a version/path fragment that only looks like one?
function Test-HostPosition {
    param([string]$Value, [int]$Start, [int]$End, [string]$Name)
    $before = $Value.Substring(0, $Start)
    $after = if ($End -lt $Value.Length) { [string]$Value[$End] } else { '' }
    if ($before -match '//(?:[^/@\s]*@)?$' -or $before.EndsWith('\\') -or $before.EndsWith('@')) { return $true }
    if ($before.Length -gt 0 -and -not $script:Lead.Contains($before[-1])) { return $false }
    if ($after -in @(':', '/')) { return $true }
    if ($after -ne '' -and -not $script:Trail.Contains($after)) { return $false }
    return ($Name.ToUpperInvariant() -notlike '*VERSION*')
}

<#
.SYNOPSIS
    Why NAME=VALUE must not ship in a published image; an empty array when it may.
#>
function Get-ImageEnvLeak {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [AllowEmptyString()][string]$Value = '')

    # Emitted one per line, so `@(Get-ImageEnvLeak ...).Count` is the number of reasons.
    if ($Name -match $script:BuildHostName) {
        'build-host sccache setting (the image may carry local defaults only)'
    }
    foreach ($m in $script:Ipv4.Matches($Value)) {
        $g = $m.Groups[1]
        if ((Test-PrivateIPv4 -Text $g.Value) -and (Test-HostPosition -Value $Value -Start $g.Index -End ($g.Index + $g.Length) -Name $Name)) {
            "RFC1918/link-local address $($g.Value)"
        }
    }
    foreach ($m in $script:Ipv6LinkLocal.Matches($Value)) { "link-local address $($m.Groups[1].Value)" }
}

<#
.SYNOPSIS
    Every leaking variable in an environment dictionary, as Scope/Name/Value/Reason records.
#>
function Find-ImageEnvLeak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Environment,
        [string]$Scope = 'Process'
    )

    foreach ($name in @($Environment.Keys | Sort-Object)) {
        $value = [string]$Environment[$name]
        foreach ($reason in (Get-ImageEnvLeak -Name ([string]$name) -Value $value)) {
            [pscustomobject]@{ Scope = $Scope; Name = [string]$name; Value = $value; Reason = $reason }
        }
    }
}

<#
.SYNOPSIS
    Throws when the running image's environment carries a build-host setting.
.DESCRIPTION
    Grades the Process scope (the image config's ENV) and the Machine and User registry
    scopes (a RUN that set a variable there publishes it too). -Scopes replaces all three,
    for tests. Fewer than -MinInspected variables is a read failure, never a pass.
#>
function Assert-ImageEnvPublishable {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Scopes,
        [int]$MinInspected = 10
    )

    if (-not $Scopes) {
        $Scopes = [ordered]@{}
        foreach ($s in 'Process', 'Machine', 'User') { $Scopes[$s] = [Environment]::GetEnvironmentVariables($s) }
    }
    $inspected = 0
    $findings = @()
    foreach ($scope in $Scopes.Keys) {
        $inspected += $Scopes[$scope].Count
        $findings += @(Find-ImageEnvLeak -Environment $Scopes[$scope] -Scope $scope)
    }
    if ($inspected -lt $MinInspected) {
        throw "publish gate: read $inspected variable(s), need >= $MinInspected - refusing a pass over an environment that was never read"
    }
    foreach ($f in $findings) { Write-Host "  LEAK [$($f.Scope)] $($f.Name)=$($f.Value) -- $($f.Reason)" }
    if ($findings.Count -gt 0) {
        throw ("publish gate FAILED: $($findings.Count) build-host setting(s) in the image environment " +
            "($(@($findings | ForEach-Object Name | Sort-Object -Unique) -join ', ')). " +
            'docs/windows-build-resources.md#what-the-published-image-carries')
    }
    Write-Host "publish gate: $inspected variable(s) across $(@($Scopes.Keys) -join '/'), no build-host setting"
}

Export-ModuleMember -Function Get-ImageEnvLeak, Find-ImageEnvLeak, Assert-ImageEnvPublishable
