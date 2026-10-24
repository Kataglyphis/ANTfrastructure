#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Dependency-free: Dockerfile.publish-gate mounts only this file. docs/windows-build-resources.md#what-the-published-image-carries

Set-StrictMode -Version Latest

# The sccache names whose value is a host, a bucket or a region.
$script:BuildHostAddressName = '^SCCACHE_(?:WEBDAV_\w+|REDIS\w*|MEMCACHED\w*|GCS_\w+|AZURE_\w+|S3_\w+|OSS_\w+|' +
    'COS_\w+|GHA_\w+|BUCKET|ENDPOINT|REGION)$'
# Every sccache remote backend and host cache layout; local defaults such as SCCACHE_DIR are allowed.
$script:BuildHostName = $script:BuildHostAddressName.Replace('|REGION)$', '|REGION|MULTILEVEL_CHAIN|FORCE_LOCAL)$')
# The S3 level's key reaches a RUN only as a BuildKit secret; as a variable it would publish with the image.
$script:CredentialName = '^AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)$'
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
    if ($Name -match $script:CredentialName) {
        'object-store credential (a key must never ship in an image)'
    }
    Get-ImageEnvAddressLeak -Name $Name -Value $Value
}

# One reason per RFC1918/link-local address that Value carries in a host position.
function Get-ImageEnvAddressLeak {
    param([AllowEmptyString()][string]$Name = '', [AllowEmptyString()][string]$Value = '')
    foreach ($m in $script:Ipv4.Matches($Value)) {
        $g = $m.Groups[1]
        if ((Test-PrivateIPv4 -Text $g.Value) -and (Test-HostPosition -Value $Value -Start $g.Index -End ($g.Index + $g.Length) -Name $Name)) {
            "RFC1918/link-local address $($g.Value)"
        }
    }
    foreach ($m in $script:Ipv6LinkLocal.Matches($Value)) { "link-local address $($m.Groups[1].Value)" }
}

# The texts of an image config that BuildKit or the Dockerfile fill, as (where, text) pairs.
function Get-ImageConfigText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $i = 0
    foreach ($h in @($Config['history'])) {
        if ($h -is [System.Collections.IDictionary]) { , @("history[$i]", "$($h['created_by']) $($h['comment'])") }
        $i++
    }
    $cfg = $Config['config']
    if ($cfg -isnot [System.Collections.IDictionary]) { return }
    foreach ($e in @($cfg['Env'])) { if ($e) { , @('config.Env', "$e") } }
    $labels = $cfg['Labels']
    if ($labels -is [System.Collections.IDictionary]) { foreach ($k in $labels.Keys) { , @('config.Labels', "$k=$($labels[$k])") } }
    foreach ($field in 'Entrypoint', 'Cmd', 'Shell', 'OnBuild', 'WorkingDir', 'User') {
        if ($cfg[$field]) { , @("config.$field", (@($cfg[$field]) -join ' ')) }
    }
}

function Get-ImageConfigTokenReason {
    param([AllowEmptyString()][string]$Token, [string]$Bucket = '', [string]$Region = '')
    if (-not $Token) { return }
    $name, $value = '', $Token
    if ($Token -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $name = $Matches[1]; $value = $Matches[2].Trim([char[]]('"', "'")) }
    if ($value -and ($name -match $script:BuildHostAddressName -or $name -match $script:CredentialName)) { "the build-host setting $name" }
    foreach ($why in @(Get-ImageEnvAddressLeak -Name $name -Value $value)) { ($why -replace ' \S+$', '') + $(if ($name) { " in $name" }) }
    if ($Bucket -and $name -match 'BUCKET' -and $value -eq $Bucket) { "the S3 bucket as $name" }
    if ($Region -and $name -match 'REGION' -and $value -eq $Region) { "the S3 region as $name" }
}

<#
.SYNOPSIS
    Where an image config names a build host, as Entry/Reason records; a reason never carries the value.
.DESCRIPTION
    BuildKit writes an ARG's value into its history entry and every build arg of a RUN into the RUN's, so the config
    keeps what no ENV shows. docs/windows-build-resources.md#what-the-published-image-carries
#>
function Find-ImageConfigLeak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        # The cache endpoints' hosts, refused anywhere in the config.
        [string[]]$EndpointHost = @(),
        # Refused as the value of a *BUCKET* or *REGION* name only: both are common words (sccache, garage).
        [string]$Bucket = '',
        [string]$Region = ''
    )

    $hosts = @($EndpointHost | Where-Object { $_ -and $_ -notmatch '^(localhost|127\.|::1$|\[::1\]$)' } | Sort-Object -Unique)
    $seen = @{}
    foreach ($source in @(Get-ImageConfigText -Config $Config)) {
        $entry, $text = $source
        $reasons = @(
            foreach ($token in ($text -split '\s+')) {
                Get-ImageConfigTokenReason -Token $token -Bucket $Bucket -Region $Region
            }
            foreach ($h in $hosts) {
                if ($text -match ('(?i)(?<![\w.-])' + [regex]::Escape($h) + '(?![\w-]|\.\w)')) { "a cache endpoint's host" }
            }
        )
        foreach ($reason in $reasons) {
            if ($seen.ContainsKey("$entry|$reason")) { continue }
            $seen["$entry|$reason"] = $true
            [pscustomobject]@{ Entry = $entry; Reason = $reason }
        }
    }
}

<#
.SYNOPSIS
    Throws when an image config names a build host; prints where and why, never the value.
#>
function Assert-ImageConfigPublishable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$EndpointHost = @(),
        [string]$Bucket = '',
        [string]$Region = ''
    )

    $entries = @(@($Config['history']) | Where-Object { $null -ne $_ }).Count
    if ($entries -lt 1) { throw "history gate: $Label has no history entry - refusing a pass over a config that was never read" }
    $found = @(Find-ImageConfigLeak -Config $Config -EndpointHost $EndpointHost -Bucket $Bucket -Region $Region)
    Stop-ImageLeak -Line @($found | ForEach-Object { "$($_.Entry): $($_.Reason)" }) -Where @($found | ForEach-Object { $_.Entry }) `
        -Failure "history gate FAILED: $($found.Count) finding(s) in the history and config of $Label"
    Write-Host "history gate: $Label - $entries history entries, no build-host address"
}

# Both gates end here: one LEAK line per finding, then a throw that names where.
function Stop-ImageLeak {
    param([string[]]$Line = @(), [string[]]$Where = @(), [Parameter(Mandatory)][string]$Failure)
    if ($Line.Count -eq 0) { return }
    foreach ($l in $Line) { Write-Host "  LEAK $l" }
    throw "$Failure ($(@($Where | Sort-Object -Unique) -join ', ')). docs/windows-build-resources.md#what-the-published-image-carries"
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
    Grades Process, Machine and User scopes, since a RUN's registry writes publish too; too few variables is a read failure.
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
    Stop-ImageLeak -Line @($findings | ForEach-Object { "[$($_.Scope)] $($_.Name)=$($_.Value) -- $($_.Reason)" }) `
        -Where @($findings | ForEach-Object Name) -Failure "publish gate FAILED: $($findings.Count) build-host setting(s) in the image environment"
    Write-Host "publish gate: $inspected variable(s) across $(@($Scopes.Keys) -join '/'), no build-host setting"
}

Export-ModuleMember -Function Get-ImageEnvLeak, Find-ImageEnvLeak, Assert-ImageEnvPublishable, Find-ImageConfigLeak, Assert-ImageConfigPublishable
