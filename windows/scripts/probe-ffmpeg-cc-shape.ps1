#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    #100 round 2: the serial -Fo matrix does NOT reproduce the "failed to
    zip up compiler outputs" crash, so capture ffmpeg's EXACT compile
    command (make -n) and replay it through sccache - serially, then with
    parallel jobs - to name the missing ingredient (flags vs concurrency).

.DESCRIPTION
    Minimal ffmpeg configure (msvc preset, cc=clang-cl overridden, no
    external deps), then:
      1. make -n on two .o targets -> print the exact recipe lines
      2. replay ONE captured command through sccache serially (fresh cache)
      3. make -j8 CC='sccache clang-cl' over libavutil only -> the crash
         reproduced ~20 files in on the real build, so a bounded parallel
         slice should reproduce it too if concurrency is the trigger
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-ffcc',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== ffmpeg cc-shape probe nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$ver = Get-SourceBuildVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'n9.0'
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
if (-not (Test-Path 'src\.git')) {
    Invoke-GitClone -RepoUrl 'https://github.com/FFmpeg/FFmpeg.git' -SourceDir (Join-Path $WorkDir 'src') -Tag $ver -InitialDelaySeconds 5 | Out-Null
}
Set-Location 'src'
& git apply 'C:\bkmnt\patches\ffmpeg\001-allow-msys-builds.patch' 2>$null
if (-not (Get-Command make -ErrorAction SilentlyContinue)) { & scoop install main/make 2>&1 | Out-Null }
if (-not (Get-Command gawk -ErrorAction SilentlyContinue)) { & scoop install main/gawk 2>&1 | Out-Null }

$bashExe = "$env:ProgramFiles\Git\bin\bash.exe"
$cygSrc = '/c/probe-ffcc/src'
& $bashExe -c "cd $cygSrc && export MSYS=winsymlinks:lnk && ./configure --toolchain=msvc --cc=clang-cl --ld=lld-link --disable-everything --disable-doc --disable-x86asm --disable-network --disable-autodetect" 2>&1 |
    Select-Object -Last 3 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }

# PRODUCTION FIXUP (round 3): the real build strips -showIncludes and the
# awk dep pipelines from every generated *.mak (Remove-MakefileShowIncludes
# in build-ffmpeg-from-source.ps1) - round 2 measured the UNPATCHED recipe
# (its awk program is genuinely broken through make; production never runs
# it). Replicate the same regexes so the replayed shapes match production.
foreach ($mak in (Get-ChildItem -Path . -Recurse -Include '*.mak', 'Makefile' -File)) {
    $c = [System.IO.File]::ReadAllText($mak.FullName)
    $c = $c -replace '-showIncludes', ''
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    [System.IO.File]::WriteAllText($mak.FullName, $c)
}
Write-Host 'applied: production -showIncludes/awk strip to *.mak'

# 1. The exact PRODUCTION recipe for two representative objects.
Write-Host '--- make -n (exact production recipes) ---'
$recipes = & $bashExe -c "cd $cygSrc && make -n libavutil/avstring.o libavutil/mem.o 2>&1" |
    Where-Object { $_ -match 'clang-cl|printf' } | Select-Object -First 6
$recipes | ForEach-Object { Write-Host "recipe| $_" }

# 2. Serial replay of ONE real recipe through sccache, fresh local cache.
$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'scc.log'
$env:SCCACHE_SERVER_PORT = '4760'
& $sccache --stop-server 2>&1 | Out-Null
Push-Location 'C:\'
try { & $sccache --start-server 2>&1 | Out-Null } finally { Pop-Location }
# Serial replay of EACH captured production shape (dep-scan line first, then
# the -c/-Fo compile) - write them to a script file so no PS/bash re-quoting
# can mangle them (round 2's awk breakage was exactly that).
$recipeLines = @($recipes | Where-Object { $_ -match 'clang-cl' })
$i = 0
foreach ($r in $recipeLines) {
    $i++
    $sh = @("cd $cygSrc", ($r -replace '(^|; )(clang-cl )', '$1sccache clang-cl ' -replace '^printf', 'printf'))
    $shPath = Join-Path $WorkDir "replay$i.sh"
    [System.IO.File]::WriteAllLines($shPath, $sh)
    & $bashExe "/c/probe-ffcc/replay$i.sh" 2>&1 | Select-Object -Last 2 | ForEach-Object { "  serial$i| $_" }
    Write-Host ("serial replay #{0} exit={1} ({2}...)" -f $i, $LASTEXITCODE, $r.Substring(0, [Math]::Min(60, $r.Length)))
}

# 3. Parallel slice: everything under libavutil with the launcher, -j8.
#    (The real crash hit ~20 files in at -j19.)
& $bashExe -c "cd $cygSrc && make -j8 CC='sccache clang-cl' libavutil/avstring.o libavutil/mem.o libavutil/buffer.o libavutil/dict.o libavutil/error.o libavutil/eval.o libavutil/fifo.o libavutil/frame.o libavutil/log.o libavutil/opt.o libavutil/parseutils.o libavutil/rational.o libavutil/samplefmt.o libavutil/time.o libavutil/utils.o libavutil/mathematics.o" 2>&1 |
    Select-String 'zip up|failed|error|Error' | Select-Object -First 6 | ForEach-Object { "  par| $_" }
Write-Host ("parallel -j8 exit={0}" -f $LASTEXITCODE)

$stats = & $sccache --show-stats 2>&1
($stats | Select-String 'Compile requests|Cache hits$|Cache misses$|errors') | Select-Object -First 6 | ForEach-Object { "  stats| $_" }
Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue |
    Select-String 'zip up|failed to open|ERROR' | Select-Object -Last 4 |
    ForEach-Object { Write-Host "  srv| $($_.Line.Trim().Substring(0, [Math]::Min(200, $_.Line.Trim().Length)))" }
& $sccache --stop-server 2>&1 | Out-Null
Write-Host 'probe complete'
