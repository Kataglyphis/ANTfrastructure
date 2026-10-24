#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Link diagnostics for a litert_lm_main tree kept via LITERTLM_KEEP_BUILD_TREE=1; also runnable standalone.


param(
    [Parameter(Mandatory)]
    [string]$SourceDir
)

# Diagnostics are best-effort and must never fail the build that invoked them.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Get-LitertRspArchives {
    param([string]$InnerBuild, [object]$Rsp)
    foreach ($name in ((Get-Content -Raw $Rsp.FullName) -split '\s+' | Where-Object { $_ -match '\.(a|lib)$' })) {
        $path = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $InnerBuild $name }
        [pscustomobject]@{ Name = $name; Path = $path }
    }
}

function Show-LitertLinkDefinedSymbols {
    param([string]$InnerBuild, [string]$NmExe)

    if (-not $NmExe) { Write-Host '  llvm-nm not found'; return }
    $fragments = @('ClassicLocale', 'MixingHashState', 'combine_raw', 'HashStateBase')
    # @(...) preserves an empty collection under the caller's inherited StrictMode.
    $libs = @(Get-ChildItem $InnerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'flatbuffers|absl_hash|absl_city|absl_low_level_hash|tensorflow|tflite' })
    Write-Host "  candidate libs found: $($libs.Count)"
    $libs | ForEach-Object { Write-Host "    lib: $($_.Name)  ($([math]::Round($_.Length/1KB))KB)" }
    foreach ($lib in $libs) {
        $syms = & $NmExe --defined-only $lib.FullName 2>$null
        foreach ($frag in $fragments) {
            $def = $syms | Select-String -Pattern $frag -SimpleMatch | Select-Object -First 1
            if ($def) { Write-Host "  DEFINED [$frag] in $($lib.Name)" }
        }
    }
    Write-Host '  --- dllimport consumers (libs with UNDEFINED __imp MixingHashState) ---'
    $consumerLibs = Get-ChildItem $InnerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'litert|runtime_|tflite|tensorflow|flatbuffers' }
    foreach ($lib in $consumerLibs) {
        $u = & $NmExe --undefined-only $lib.FullName 2>$null | Select-String -Pattern 'MixingHashState' -SimpleMatch | Where-Object { $_ -match '__imp|imp_' } | Select-Object -First 1
        if ($u) { Write-Host "  CONSUMER __imp MixingHashState <- $($lib.Name)" }
    }
}

function Show-LitertLinkDuplicateFlags {
    param([string]$InnerBuild, [string]$NmExe, [AllowNull()]$Rsp)

    if (-not $NmExe -or -not $Rsp) { Write-Host '  (need llvm-nm + rsp)'; return }
    # @(...) preserves an empty collection under the caller's inherited StrictMode.
    $rspLibs2 = @(Get-LitertRspArchives -InnerBuild $InnerBuild -Rsp $Rsp |
        Where-Object { Test-Path $_.Path } | Select-Object -ExpandProperty Path | Sort-Object -Unique)
    Write-Host "  rsp archives to scan: $($rspLibs2.Count)"
    $mllHits = @()
    foreach ($lp in $rspLibs2) {
        $d = & $NmExe --defined-only $lp 2>$null | Select-String -Pattern 'minloglevel' -SimpleMatch | Select-Object -First 1
        if ($d) { $mllHits += $lp; Write-Host "  DEFINES minloglevel: $lp" }
    }
    Write-Host "  >>> $($mllHits.Count) archive(s) define minloglevel (expect 1; >1 = duplicate abseil = ODR bug)"
    $logFlagArch = $rspLibs2 | Where-Object { $_ -match 'log_flags|absl_log_flags|log.*flags' }
    if ($logFlagArch) { Write-Host "  absl_log_flags-named archives in rsp:"; $logFlagArch | ForEach-Object { Write-Host "    $_" } }
}

$innerBuild = Join-Path $SourceDir 'build_ninja\litert_lm\build'
Write-Host '===DIAG=== litert_lm_main.rsp (link inputs/flags, order preserved):'
$rsp = Get-ChildItem $innerBuild -Recurse -Filter 'litert_lm_main.rsp' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($rsp) { Write-Host "RSP: $($rsp.FullName)"; (Get-Content -Raw $rsp.FullName) -split '\s+' | ForEach-Object { Write-Host "  $_" } }
else { Write-Host 'RSP not found'; Get-ChildItem $innerBuild -Recurse -Filter '*.rsp' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  found rsp: $($_.FullName)" } }
Write-Host '===DIAG=== WHOLEARCHIVE / FORCE:MULTIPLE presence in the link rule (build.ninja):'
$bn = Join-Path $innerBuild 'build.ninja'
if (Test-Path $bn) { Get-Content $bn | Select-String -Pattern 'litert_lm_main.*(WHOLEARCHIVE|FORCE:MULTIPLE)|WHOLEARCHIVE' | Select-Object -First 4 | ForEach-Object { Write-Host "  $($_.Line.Substring(0,[Math]::Min(240,$_.Line.Length)))" } }
Write-Host '===DIAG=== abseil libs actually built (strings/log/flags/status present?):'
$abslLib = Join-Path $innerBuild 'external\abseil-cpp\install\lib'
if (Test-Path $abslLib) { Get-ChildItem $abslLib -Filter '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'strings|log|flags|status|str_format|str_cat' } | ForEach-Object { Write-Host "  $($_.Name)" } }
else { Write-Host "  abseil lib dir not found at $abslLib"; Get-ChildItem (Join-Path $innerBuild 'external\abseil-cpp') -Recurse -Filter 'libabsl_strings*' -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { Write-Host "  $($_.FullName)" } }
Write-Host '===DIAG=== referenced libs in rsp that are MISSING or 0-byte (empty stubs -> undefined symbols):'
if ($rsp) {
    foreach ($archive in @(Get-LitertRspArchives -InnerBuild $innerBuild -Rsp $rsp)) {
        if (-not (Test-Path $archive.Path)) { Write-Host "  MISSING: $($archive.Name)" }
        elseif ((Get-Item $archive.Path).Length -lt 16) { Write-Host "  EMPTY($((Get-Item $archive.Path).Length)B): $($archive.Name)" }
    }
}
Write-Host '===DIAG=== which built lib DEFINES the leftover undefined symbols (nm scan; T/D/W = defined):'
# llvm-nm may be absent, and .Source on null throws under the caller's StrictMode.
$nmCmd = Get-Command 'llvm-nm.exe' -ErrorAction SilentlyContinue
$nmExe = if ($nmCmd) { $nmCmd.Source } else { $null }
Show-LitertLinkDefinedSymbols -InnerBuild $innerBuild -NmExe $nmExe
Write-Host '===DIAG=== abseil DUPLICATE-flag scan: which rsp archives DEFINE minloglevel (>1 = the ODR culprit):'
Show-LitertLinkDuplicateFlags -InnerBuild $innerBuild -NmExe $nmExe -Rsp $rsp
Write-Host '===DIAG END==='

# llvm-nm exits non-zero on the broken archives this hunts for; the caller must not read that exit code.
exit 0

