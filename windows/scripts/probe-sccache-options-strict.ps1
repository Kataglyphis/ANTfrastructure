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

# Round 4: sccache never logs the spawned compile line (even at trace), so
# intercept it - a shim that records every argv and forwards to the real
# clang-cl. sccache detects the shim as clang-cl because it forwards
# everything (incl. the -E detection probe).
$realClang = (Get-Command clang-cl.exe).Source
$shim = Join-Path $WorkDir 'clang-shim.bat'
@(
    '@echo off',
    "echo ARGS: %* >> $WorkDir\shim.log",
    "`"$realClang`" %*",
    "echo EXIT: %ERRORLEVEL% >> $WorkDir\shim.log",
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path $shim -Encoding ascii

# Control (must pass), then the trigger (crashes at output collection).
foreach ($case in @(
        @{ Name = 'control'; Args = @($shim, '-nologo', '-c', '-Fotiny1.o', 'tiny.c') },
        @{ Name = 'TRIGGER'; Args = @($shim, '-nologo', '-options:strict', '-c', '-Fotiny2.o', 'tiny.c') }
    )) {
    $out = & $sccache @($case.Args) 2>&1
    Write-Host ("case {0,-8} exit={1} object={2}" -f $case.Name, $LASTEXITCODE, (Test-Path ($case.Args[-2] -replace '^-Fo', '')))
    if ($LASTEXITCODE -ne 0) { ($out | Where-Object { $_ } | Select-Object -Last 3) | ForEach-Object { Write-Host "  err| $_" } }
}

# The shim's argv log IS the missing evidence: every line sccache actually
# spawned, with exit codes, in order.
Get-Content (Join-Path $WorkDir 'shim.log') -ErrorAction SilentlyContinue | ForEach-Object {
    $t = "$_".Trim(); if ($t) { Write-Host ("  shim| {0}" -f $t.Substring(0, [Math]::Min(400, $t.Length))) }
}
# Where DID the object land? Sweep the workdir for stray .o/.obj files.
Get-ChildItem $WorkDir -Recurse -Include '*.o', '*.obj' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  obj| {0} ({1} bytes)" -f $_.FullName, $_.Length) }
& $sccache --stop-server 2>&1 | Out-Null
Write-Host 'probe complete'
