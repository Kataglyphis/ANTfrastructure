#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Points this host's Windows container builds at the shared S3 bucket, sccache's level 1, or reports what is set.

.DESCRIPTION
    Writes the five KATAGLYPHIS_SCCACHE_S3_* variables to the user's environment, which Build-Buildkit.ps1 reads even from a
    shell that started earlier. The secret is asked for without echo and never passes a command line. With s5cmd on PATH
    the key is tried against the bucket first, and a key the server refuses is not written.
    Level 0 stays the host's own WebDAV (Install-NewHost.ps1). docs/windows-build-resources.md § Two cache levels
.EXAMPLE
    pwsh -File windows/scripts/host/Set-SccacheS3Level.ps1 -Endpoint http://192.168.188.216:3900 -AccessKeyId GK0123456789abcdef01234567
    Asks for the secret, then sets bucket sccache and region garage, the defaults.

.EXAMPLE
    pwsh -File windows/scripts/host/Set-SccacheS3Level.ps1 -ReportOnly
    Shows which of the five variables are set; the secret only as set or missing.

.EXAMPLE
    pwsh -File windows/scripts/host/Set-SccacheS3Level.ps1 -Clear
    Removes all five, so the next build runs on the WebDAV level alone.
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory)][string]$Endpoint,
    [Parameter(ParameterSetName = 'Set', Mandatory)][string]$AccessKeyId,
    [Parameter(ParameterSetName = 'Set')][string]$Bucket = 'sccache',
    [Parameter(ParameterSetName = 'Set')][string]$Region = 'garage',
    [Parameter(ParameterSetName = 'Report', Mandatory)][switch]$ReportOnly,
    [Parameter(ParameterSetName = 'Clear', Mandatory)][switch]$Clear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1') -Force

$names = [ordered]@{
    Endpoint    = 'KATAGLYPHIS_SCCACHE_S3_ENDPOINT'
    Bucket      = 'KATAGLYPHIS_SCCACHE_S3_BUCKET'
    Region      = 'KATAGLYPHIS_SCCACHE_S3_REGION'
    AccessKeyId = 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID'
    Secret      = 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY'
}

function Show-Setting {
    foreach ($key in $names.Keys) {
        $value = [Environment]::GetEnvironmentVariable($names[$key], 'User')
        $shown = if (-not $value) { '(not set)' } elseif ($key -eq 'Secret') { '(set)' } else { $value }
        Write-Host ('{0,-42} {1}' -f $names[$key], $shown)
    }
}

if ($ReportOnly) { Show-Setting; return }

if ($Clear) {
    foreach ($name in $names.Values) { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
    Write-Host 'Removed the S3 level; the next build runs on the WebDAV level alone.'
    return
}

if ($Endpoint -notmatch '^https?://[^/:]+(:\d+)?/?$') {
    throw "-Endpoint '$Endpoint' is not an http(s) URL such as http://192.168.188.216:3900"
}
if (-not (Test-UrlPortOpen $Endpoint)) {
    Write-Warning "$Endpoint does not answer from here; is the VPN up? The settings are written anyway."
}
$secure = Read-Host -Prompt "Secret key for $AccessKeyId" -AsSecureString
$secret = [Net.NetworkCredential]::new('', $secure).Password
if (-not $secret) { throw 'No secret entered; nothing was changed.' }
# A pasted command line instead of the key was stored once (2026-10-15) and surfaced only as 403s in every build.
if ($secret -match '\s') { throw 'The secret contains whitespace, so the paste was probably something else (the command line?); nothing was changed.' }
$s5cmd = (Get-Command s5cmd -ErrorAction SilentlyContinue).Source
if (-not $s5cmd) {
    Write-Host 'Not checked against the server: s5cmd is not on PATH (scoop install s5cmd).'
} else {
    $answer = (@(Invoke-S5cmdWithKey -S5cmdPath $s5cmd -AccessKeyId $AccessKeyId -SecretAccessKey $secret -Region $Region -Arguments @('--endpoint-url', $Endpoint, 'ls', "s3://$Bucket") 2>&1) -join ' ')
    if ($answer -match 'AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch|Invalid signature') {
        throw "The server refuses this key ($($answer.Trim())); nothing was changed."
    } elseif ($LASTEXITCODE -ne 0 -and $answer -notmatch 'no object found') {
        Write-Warning "The key could not be checked against $Endpoint ($($answer.Trim())); it is written anyway."
    } else {
        Write-Host "The server accepts the key for bucket $Bucket."
    }
}

$values = @{ Endpoint = $Endpoint; Bucket = $Bucket; Region = $Region; AccessKeyId = $AccessKeyId; Secret = $secret }
foreach ($key in $names.Keys) { [Environment]::SetEnvironmentVariable($names[$key], $values[$key], 'User') }
Write-Host 'Set. Build-Buildkit.ps1 now prints "sccache levels: webdav ... -> s3 ..." at the start of a run.'
Show-Setting
