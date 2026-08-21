#requires -Version 7.0
# ARCHIVED 2026-08-21 (#127 extraction; incident SETTLED — round 3's fixed
# gate verified). #112: why did the opencv stage's FFmpeg provenance probe
# read back empty? Root cause chain: exit 0xC0000135 STATUS_DLL_NOT_FOUND
# with all av* DLLs present — the recursive dumpbin walk (round 2) names the
# missing transitive import (onnxruntime.dll not on PATH); round 3 replays
# the FIXED gate (bin dir + discovered onnxruntime dir on PATH).
# Formerly Dockerfile.ffmpeg-provenance-probe with 54 lines of inline pwsh —
# the only probe that inlined, carrying WCOW re-quoting scar tissue. Run:
#   run-diagnostic-probe.ps1 -ProbeScript archive/probe-ffmpeg-provenance.ps1 -BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg
[CmdletBinding()]
param([string]$Nonce = '0')
$ErrorActionPreference = 'Stop'
Write-Host "nonce=$Nonce"

# ---- Round 1: inventory + direct run ---------------------------------------
$probe = 'C:\runtime\ffmpeg\bin\ffmpeg.exe'
Write-Host ('exists: ' + (Test-Path $probe))
Write-Host ('runtime dirs: ' + ((Get-ChildItem C:\runtime -Directory -ErrorAction SilentlyContinue).Name -join ', '))
Write-Host ('ffmpeg subdirs: ' + ((Get-ChildItem C:\runtime\ffmpeg -Directory -ErrorAction SilentlyContinue).Name -join ', '))
Write-Host ('bin entries: ' + ((Get-ChildItem C:\runtime\ffmpeg\bin -ErrorAction SilentlyContinue | Select-Object -First 20).Name -join ', '))
if (Test-Path $probe) {
    $env:PATH = 'C:\runtime\ffmpeg\bin;' + $env:PATH
    $out = & $probe -version 2>&1 | Out-String
    Write-Host ('ffmpeg exit: ' + $LASTEXITCODE)
    ($out -split "`r?`n" | Select-Object -First 8) | ForEach-Object { Write-Host ('ver| ' + $_) }
    if ($out -match '(?m)^\s*libavcodec\s+(\d+)\.') { Write-Host ('PARSED avcodec major: ' + $Matches[1]) }
    else { Write-Host 'NO libavcodec line parsed' }
} else {
    Write-Host 'ffmpeg.exe ABSENT at the gate path - that IS the #112 cause'
}

# ---- Round 2: recursive dumpbin dependency walk ----------------------------
# Same approach as the GStreamer plugin-LOAD gate: BFS over static imports,
# naming every DLL no search dir can satisfy.
$dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
Write-Host ('dumpbin: ' + $dumpbin)
$searchDirs = @('C:\runtime\ffmpeg\bin', "$env:SystemRoot\System32") + ($env:PATH -split ';' | Where-Object { $_ })
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$queue = [System.Collections.Queue]::new()
$queue.Enqueue('C:\runtime\ffmpeg\bin\ffmpeg.exe')
$missing = @{}
while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    if (-not $seen.Add([IO.Path]::GetFileName($item).ToLower())) { continue }
    $deps = @(& $dumpbin /dependents $item 2>&1 | Select-String '^\s{4,}(\S+\.dll)' | ForEach-Object { $_.Matches.Groups[1].Value })
    foreach ($dep in $deps) {
        if ($seen.Contains($dep.ToLower())) { continue }
        if ($dep -match '^(api-ms-|ext-ms-)') { continue }
        $hit = $searchDirs | Where-Object { Test-Path (Join-Path $_ $dep) } | Select-Object -First 1
        if ($hit) { $queue.Enqueue((Join-Path $hit $dep)) }
        else { $missing[$dep] = [IO.Path]::GetFileName($item) }
    }
}
if ($missing.Count -eq 0) { Write-Host 'walker: NO missing static imports (delay-load or manifest issue?)' }
else { $missing.GetEnumerator() | ForEach-Object { Write-Host ('MISSING: ' + $_.Key + '  (imported by ' + $_.Value + ')') } }
Write-Host 'walk complete'

# ---- Round 3: replay the FIXED gate logic ----------------------------------
$probeDirs = @('C:\runtime\ffmpeg\bin')
$ortDll = Get-ChildItem 'C:\runtime\lib\onnxruntime-source' -Recurse -Filter 'onnxruntime.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ('ort dll: ' + $(if ($ortDll) { $ortDll.FullName } else { 'NOT FOUND' }))
if ($ortDll) { $probeDirs += $ortDll.DirectoryName }
$env:PATH = ($probeDirs -join ';') + ';' + $env:PATH
$out = & C:\runtime\ffmpeg\bin\ffmpeg.exe -version 2>&1 | Out-String
Write-Host ('fixed-gate exit: ' + $LASTEXITCODE)
if ($out -match '(?m)^\s*libavcodec\s+(\d+)\.') { Write-Host ('FIXED-GATE PARSED avcodec major: ' + $Matches[1]) }
else { throw 'fixed gate STILL cannot parse libavcodec' }
Write-Host 'fix verified'
Write-Host 'probe complete'
