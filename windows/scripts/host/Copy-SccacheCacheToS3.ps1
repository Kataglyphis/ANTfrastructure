#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Seeds the shared S3 bucket, sccache's level 1, with this host's WebDAV cache, so other hosts hit from their first build.

.DESCRIPTION
    WebDAV and S3 store an object under the same key, a/b/c/<hash>, so the dufs directory copies 1:1 with no key prefix.
    preseed\ (the driver's installers) and .sccache_check stay out. Runs s5cmd (scoop install s5cmd) with the key from
    Set-SccacheS3Level.ps1, which reaches only the s5cmd process. docs/windows-build-resources.md § Two cache levels
.EXAMPLE
    pwsh -File windows/scripts/host/Copy-SccacheCacheToS3.ps1 -DryRun
    Lists what it would upload.

.EXAMPLE
    pwsh -File windows/scripts/host/Copy-SccacheCacheToS3.ps1
    Uploads every object the bucket does not have yet; a rerun after an interruption continues.
#>
[CmdletBinding()]
param(
    # Install-DufsService.ps1's default serve directory.
    [string]$SourceDir = (Join-Path $env:USERPROFILE 'sccache-cache'),
    [int]$Workers = 64,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1') -Force

$endpoint = Get-HostSettingValue 'KATAGLYPHIS_SCCACHE_S3_ENDPOINT'
$bucket = Get-HostSettingValue 'KATAGLYPHIS_SCCACHE_S3_BUCKET'
$region = Get-HostSettingValue 'KATAGLYPHIS_SCCACHE_S3_REGION'
$keyId = Get-HostSettingValue 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID'
$secret = Get-HostSettingValue 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY'
if (-not ($endpoint -and $bucket -and $keyId -and $secret)) {
    throw 'The S3 level is not configured: run windows\scripts\host\Set-SccacheS3Level.ps1 first.'
}
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { throw "No cache directory at $SourceDir (-SourceDir)" }
$s5cmd = (Get-Command s5cmd -ErrorAction SilentlyContinue).Source
if (-not $s5cmd) { throw 's5cmd is not on PATH: scoop install s5cmd' }

$files = [IO.Directory]::EnumerateFiles($SourceDir, '*', [IO.SearchOption]::AllDirectories)
$count = 0; $bytes = 0L
foreach ($f in $files) { if ($f -notmatch '\\preseed\\' -and -not $f.EndsWith('.sccache_check')) { $count++; $bytes += ([IO.FileInfo]$f).Length } }
Write-Host ("Seeding {0:N0} objects ({1:N1} GB) from {2} into s3://{3} at {4}" -f $count, ($bytes / 1GB), $SourceDir, $bucket, $endpoint)

# s5cmd reads the key from its environment, so this process holds it only while s5cmd runs.
$awsEnv = @{ AWS_ACCESS_KEY_ID = $keyId; AWS_SECRET_ACCESS_KEY = $secret; AWS_REGION = $(if ($region) { $region } else { 'us-east-1' }) }
$priorEnv = @(Get-ChildItem Env: | Where-Object Name -In $awsEnv.Keys)
$awsEnv.GetEnumerator() | ForEach-Object { Set-Item -LiteralPath "Env:$($_.Key)" -Value $_.Value }
try {
    # --size-only skips what the bucket holds, so a rerun resumes; a real run logs errors only (750k objects).
    $s5Args = @('--endpoint-url', $endpoint, '--numworkers', $Workers, '--log', $(if ($DryRun) { 'info' } else { 'error' }))
    if ($DryRun) { $s5Args += '--dry-run' }
    $s5Args += @('sync', '--size-only', '--exclude', 'preseed/*', '--exclude', '.sccache_check', (Join-Path $SourceDir '*'), "s3://$bucket/")
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if ($DryRun) {
        $planned = @(& $s5cmd @s5Args)
        $planned | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        Write-Host "($($planned.Count) operation(s) planned)"
    } else {
        & $s5cmd @s5Args | ForEach-Object { Write-Host "  $_" }
    }
    if ($LASTEXITCODE -ne 0) { throw "s5cmd exited $LASTEXITCODE" }
    Write-Host ("Done in {0:N0} s." -f $clock.Elapsed.TotalSeconds)
    if (-not $DryRun) {
        $listed = @(& $s5cmd --endpoint-url $endpoint ls "s3://$bucket/0/0/0/*" 2>$null | Select-Object -First 3)
        Write-Host "Sample of the bucket (0/0/0/*):"
        $listed | ForEach-Object { Write-Host "  $_" }
    }
} finally {
    $awsEnv.Keys | ForEach-Object { Remove-Item -LiteralPath "Env:$_" -ErrorAction SilentlyContinue }
    $priorEnv | ForEach-Object { Set-Item -LiteralPath "Env:$($_.Name)" -Value $_.Value }
}
