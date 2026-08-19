#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Minimal repro for the #100 sccache failure: "failed to zip up compiler
    outputs / failed to open file `...\libavdevice/dshow_pin.o`" when ffmpeg's
    make drives clang-cl through sccache with RELATIVE forward-slash -Fo
    output paths.

.DESCRIPTION
    Matrix over -Fo shapes, each against BARE clang-cl (control: does the
    compiler itself put the file where sccache later looks?) and through
    sccache (fresh local disk cache, server started from C:\ like the
    chain's prologue does). One extra case runs the sccache compile from
    inside git-bash, mimicking make's spawn environment. Verdict per case:
    exit code, object file present at the expected path, and the sccache
    error line if any.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-fo',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache relative -Fo probe nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'src\libavdevice')
Set-Location (Join-Path $WorkDir 'src')
@'
int probe_fn(int x) { return x * 2; }
'@ | Set-Content -Path 'libavdevice\probe.c' -Encoding ascii

$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'scc.log'
$env:SCCACHE_LOG = 'debug'
$env:SCCACHE_SERVER_PORT = '4750'
& $sccache --stop-server 2>&1 | Out-Null
# Server from C:\ exactly like the chain prologue - a cwd-dependent output
# resolution bug needs the server cwd != client cwd.
Push-Location 'C:\'
try { & $sccache --start-server 2>&1 | Out-Null } finally { Pop-Location }

# ffmpeg's shape: relative fwd-slash output into a subdir, cwd = source root.
$cases = [ordered]@{
    'bare-fwdslash'    = @{ Exe = 'clang-cl'; Args = @('-nologo', '-c', '-Folibavdevice/probe1.o', 'libavdevice/probe.c'); Out = 'libavdevice\probe1.o' }
    'scc-fwdslash'     = @{ Exe = 'sccache';  Args = @('clang-cl', '-nologo', '-c', '-Folibavdevice/probe2.o', 'libavdevice/probe.c'); Out = 'libavdevice\probe2.o' }
    'scc-backslash'    = @{ Exe = 'sccache';  Args = @('clang-cl', '-nologo', '-c', '-Folibavdevice\probe3.o', 'libavdevice\probe.c'); Out = 'libavdevice\probe3.o' }
    'scc-absolute'     = @{ Exe = 'sccache';  Args = @('clang-cl', '-nologo', '-c', "-Fo$WorkDir\src\libavdevice\probe4.o", 'libavdevice\probe.c'); Out = 'libavdevice\probe4.o' }
    'scc-flat-relative' = @{ Exe = 'sccache'; Args = @('clang-cl', '-nologo', '-c', '-Foprobe5.o', 'libavdevice/probe.c'); Out = 'probe5.o' }
}
foreach ($name in $cases.Keys) {
    $c = $cases[$name]
    Remove-Item $c.Out -Force -ErrorAction SilentlyContinue
    $exe = if ($c.Exe -eq 'sccache') { $sccache } else { $c.Exe }
    $out = & $exe @($c.Args) 2>&1
    $rc = $LASTEXITCODE
    $exists = Test-Path $c.Out
    Write-Host ("case {0,-18} exit={1} object-at-expected-path={2}" -f $name, $rc, $exists)
    if ($rc -ne 0 -or -not $exists) {
        ($out | Where-Object { $_ } | Select-Object -Last 4) | ForEach-Object { Write-Host "  err| $_" }
    }
}

# make-spawn mimicry: the failing compiles came from MSYS make. Run the exact
# failing shape from inside git-bash (env conversion, argv handling).
$bashExe = "$env:ProgramFiles\Git\bin\bash.exe"
if (-not (Test-Path $bashExe)) { $bashExe = (Get-Command bash.exe -ErrorAction SilentlyContinue).Source }
if ($bashExe) {
    Remove-Item 'libavdevice\probe6.o' -Force -ErrorAction SilentlyContinue
    $out = & $bashExe -c "cd /c/probe-fo/src && sccache clang-cl -nologo -c -Folibavdevice/probe6.o libavdevice/probe.c" 2>&1
    $rc = $LASTEXITCODE
    $exists = Test-Path 'libavdevice\probe6.o'
    Write-Host ("case {0,-18} exit={1} object-at-expected-path={2}" -f 'scc-via-bash', $rc, $exists)
    if ($rc -ne 0 -or -not $exists) { ($out | Where-Object { $_ } | Select-Object -Last 4) | ForEach-Object { Write-Host "  err| $_" } }
} else {
    Write-Host 'case scc-via-bash SKIPPED (no bash.exe)'
}

# Server log: the zip-up failure lands here with the resolved path.
Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue |
    Select-String 'zip up|failed to open|ERROR' | Select-Object -Last 6 |
    ForEach-Object { Write-Host "  srv| $($_.Line.Trim().Substring(0, [Math]::Min(200, $_.Line.Trim().Length)))" }
& $sccache --stop-server 2>&1 | Out-Null
Write-Host 'probe complete'
