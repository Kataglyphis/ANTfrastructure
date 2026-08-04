# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Fail-fast static gate for every Windows build script. Two passes:
#   1. PARSE (mandatory, zero dependencies) — a syntax error in any build script is
#      otherwise discovered only when Docker reaches that RUN, hours into a build.
#   2. PSScriptAnalyzer (optional) — runs only if the module is installed; skipped with
#      a note otherwise, so the gate is always usable on an offline/bare host.
# Exit code is non-zero if any parse error (or, with -FailOnAnalyzer, any analyzer
# diagnostic at the configured severity) is found. Run it before build.ps1 and in CI.
#requires -Version 7.0

[CmdletBinding()]
param(
    # Also fail the run on PSScriptAnalyzer findings (default: analyzer is advisory).
    [switch]$FailOnAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # windows/scripts
$windowsDir = Split-Path -Parent $scriptsDir                        # windows
$settings = Join-Path $windowsDir 'PSScriptAnalyzerSettings.psd1'

# Collect every script/module except the archived (dead) tree.
$targets = @(
    Get-ChildItem -Path $windowsDir -Filter '*.ps1' -File                                  # build.ps1 + siblings
    Get-ChildItem -Path $scriptsDir -Recurse -Include '*.ps1', '*.psm1' -File
) | Where-Object { $_.FullName -notmatch '\\archive\\' } | Sort-Object FullName -Unique

Write-Host "== Lint gate: $($targets.Count) files ==" -ForegroundColor Cyan

# ---- Pass 1: parse ----
$parseErrors = New-Object System.Collections.ArrayList
foreach ($file in $targets) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            [void]$parseErrors.Add([pscustomobject]@{
                    File = $file.FullName; Line = $e.Extent.StartLineNumber; Message = $e.Message
                })
        }
    }
}

if ($parseErrors.Count -gt 0) {
    Write-Host "PARSE: $($parseErrors.Count) error(s)" -ForegroundColor Red
    foreach ($e in $parseErrors) {
        Write-Host ("  {0}:{1}  {2}" -f $e.File, $e.Line, $e.Message) -ForegroundColor Red
    }
} else {
    Write-Host "PARSE: all $($targets.Count) files parse clean" -ForegroundColor Green
}

# ---- Pass 2: PSScriptAnalyzer (optional) ----
$analyzerFindings = @()
$analyzerModule = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if ($analyzerModule) {
    Import-Module PSScriptAnalyzer -Force
    # Invoke-ScriptAnalyzer -Path takes a SINGLE path (an array throws "cannot convert Object[] to
    # String"), so analyze each target file and aggregate.
    foreach ($t in $targets) {
        $params = @{ Path = $t.FullName }
        if (Test-Path $settings) { $params['Settings'] = $settings }
        $analyzerFindings += @(Invoke-ScriptAnalyzer @params)
    }
    $errs = @($analyzerFindings | Where-Object { $_.Severity -eq 'Error' })
    $warns = @($analyzerFindings | Where-Object { $_.Severity -eq 'Warning' })
    $color = if ($errs.Count -gt 0) { 'Red' } elseif ($warns.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "PSSA: $($errs.Count) error(s), $($warns.Count) warning(s) [PSScriptAnalyzer $($analyzerModule.Version)]" -ForegroundColor $color
    foreach ($f in ($analyzerFindings | Sort-Object Severity -Descending | Select-Object -First 40)) {
        $c = if ($f.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1}:{2}  {3} ({4})" -f $f.Severity, $f.ScriptName, $f.Line, $f.Message, $f.RuleName) -ForegroundColor $c
    }
} else {
    Write-Host "PSSA: PSScriptAnalyzer not installed - skipping (install-time only; parse gate still enforced)" -ForegroundColor DarkYellow
}

# ---- Verdict ----
$fail = $parseErrors.Count -gt 0
if ($FailOnAnalyzer -and (@($analyzerFindings | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0)) { $fail = $true }
if ($fail) { Write-Host "`nLINT FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nLINT OK" -ForegroundColor Green
exit 0

