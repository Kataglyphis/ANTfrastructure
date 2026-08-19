#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    THE canonical repro for the #100 crash (candidate upstream sccache
    issue/PR 3): `sccache clang-cl -options:strict -c -Fo<out> <src>` dies
    with "failed to zip up compiler outputs" - isolated from ffmpeg by the
    cc-shape probe rounds 3-5. Dumps sccache's own debug parse lines to
    prove HOW the argument is (mis)read.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-optstrict',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache -options:strict repro nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
Set-Content -Path 'tiny.c' -Value 'int tiny_fn(int x) { return x + 1; }' -Encoding ascii

$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'scc.log'
$env:SCCACHE_LOG = 'trace'
$env:SCCACHE_SERVER_PORT = '4770'
& $sccache --stop-server 2>&1 | Out-Null
& $sccache --start-server 2>&1 | Out-Null

# Control (must pass), then the trigger (crashes at output collection).
foreach ($case in @(
        @{ Name = 'control'; Args = @('clang-cl', '-nologo', '-c', '-Fotiny1.o', 'tiny.c') },
        @{ Name = 'TRIGGER'; Args = @('clang-cl', '-nologo', '-options:strict', '-c', '-Fotiny2.o', 'tiny.c') }
    )) {
    $out = & $sccache @($case.Args) 2>&1
    Write-Host ("case {0,-8} exit={1} object={2}" -f $case.Name, $LASTEXITCODE, (Test-Path ($case.Args[-2] -replace '^-Fo', '')))
    if ($LASTEXITCODE -ne 0) { ($out | Where-Object { $_ } | Select-Object -Last 3) | ForEach-Object { Write-Host "  err| $_" } }
}

# The proof: sccache's own trace of how it parsed the trigger - outputs map,
# unhandled args, and the compile command it actually spawned.
Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue |
    Select-String 'parse_arguments|outputs|options:strict|ptions|zip up|failed to open|compile_cmd|arguments' |
    Select-Object -Last 20 | ForEach-Object {
        $t = $_.Line.Trim(); Write-Host ("  trace| {0}" -f $t.Substring(0, [Math]::Min(220, $t.Length)))
    }
& $sccache --stop-server 2>&1 | Out-Null
Write-Host 'probe complete'
