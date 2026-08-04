# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Link diagnostics for a litert_lm_main build tree kept via LITERTLM_KEEP_BUILD_TREE=1
# (build-litert-lm-from-source.ps1 invokes this; also runnable standalone against a kept
# tree). Dumps the link rsp, WHOLEARCHIVE/FORCE:MULTIPLE presence, built abseil libs,
# missing/empty archives, and nm scans for the recurring undefined/duplicate symbols.

#requires -Version 7.0

param(
    [Parameter(Mandatory)]
    [string]$SourceDir
)

# Diagnostics are best-effort and must never fail the build that invoked them.
$ErrorActionPreference = 'Continue'
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
    (Get-Content -Raw $rsp.FullName) -split '\s+' | Where-Object { $_ -match '\.(a|lib)$' } | ForEach-Object {
        $p = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $innerBuild $_ }
        if (-not (Test-Path $p)) { Write-Host "  MISSING: $_" }
        elseif ((Get-Item $p).Length -lt 16) { Write-Host "  EMPTY($((Get-Item $p).Length)B): $_" }
    }
}
Write-Host '===DIAG=== which built lib DEFINES the leftover undefined symbols (nm scan; T/D/W = defined):'
$nmExe = (Get-Command 'llvm-nm.exe' -ErrorAction SilentlyContinue).Source
if ($nmExe) {
    $fragments = @('ClassicLocale', 'MixingHashState', 'combine_raw', 'HashStateBase')
    # @(...) is load-bearing: an empty pipeline yields AutomationNull, whose .Count throws under the caller's inherited StrictMode.
    $libs = @(Get-ChildItem $innerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'flatbuffers|absl_hash|absl_city|absl_low_level_hash|tensorflow|tflite' })
    Write-Host "  candidate libs found: $($libs.Count)"
    $libs | ForEach-Object { Write-Host "    lib: $($_.Name)  ($([math]::Round($_.Length/1KB))KB)" }
    foreach ($lib in $libs) {
        $syms = & $nmExe --defined-only $lib.FullName 2>$null
        foreach ($frag in $fragments) {
            $def = $syms | Select-String -Pattern $frag -SimpleMatch | Select-Object -First 1
            if ($def) { Write-Host "  DEFINED [$frag] in $($lib.Name)" }
        }
    }
    # find the dllimport CONSUMER: which lib has an UNDEFINED __imp reference to MixingHashState
    Write-Host '  --- dllimport consumers (libs with UNDEFINED __imp MixingHashState) ---'
    $consumerLibs = Get-ChildItem $innerBuild -Recurse -File -Include '*.a', '*.lib' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'litert|runtime_|tflite|tensorflow|flatbuffers' }
    foreach ($lib in $consumerLibs) {
        $u = & $nmExe --undefined-only $lib.FullName 2>$null | Select-String -Pattern 'MixingHashState' -SimpleMatch | Where-Object { $_ -match '__imp|imp_' } | Select-Object -First 1
        if ($u) { Write-Host "  CONSUMER __imp MixingHashState <- $($lib.Name)" }
    }
} else { Write-Host '  llvm-nm not found' }
Write-Host '===DIAG=== abseil DUPLICATE-flag scan: which rsp archives DEFINE minloglevel (>1 = the ODR culprit):'
if ($nmExe -and $rsp) {
    # @(...) is load-bearing: an empty pipeline yields AutomationNull, whose .Count throws under the caller's inherited StrictMode.
    $rspLibs2 = @((Get-Content -Raw $rsp.FullName) -split '\s+' | Where-Object { $_ -match '\.(a|lib)$' } |
        ForEach-Object { if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $innerBuild $_ } } |
        Where-Object { Test-Path $_ } | Sort-Object -Unique)
    Write-Host "  rsp archives to scan: $($rspLibs2.Count)"
    $mllHits = @()
    foreach ($lp in $rspLibs2) {
        $d = & $nmExe --defined-only $lp 2>$null | Select-String -Pattern 'minloglevel' -SimpleMatch | Select-Object -First 1
        if ($d) { $mllHits += $lp; Write-Host "  DEFINES minloglevel: $lp" }
    }
    Write-Host "  >>> $($mllHits.Count) archive(s) define minloglevel (expect 1; >1 = duplicate abseil = ODR bug)"
    # Also flag any second copy of the whole abseil log-flags TU by archive name.
    $logFlagArch = $rspLibs2 | Where-Object { $_ -match 'log_flags|absl_log_flags|log.*flags' }
    if ($logFlagArch) { Write-Host "  absl_log_flags-named archives in rsp:"; $logFlagArch | ForEach-Object { Write-Host "    $_" } }
} else { Write-Host '  (need llvm-nm + rsp)' }
Write-Host '===DIAG END==='

# Diagnostics-only script: llvm-nm legitimately exits non-zero on the malformed/
# empty archives this hunts for, and that exit code must never outlive us (the
# caller reads the ambient $LASTEXITCODE; standalone pwsh -File propagates it).
exit 0

