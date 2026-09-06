#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Fail-fast static gate for every Windows build script. Two passes:
#   1. PARSE (mandatory, zero dependencies) — a syntax error in any build script is
#      otherwise discovered only when Docker reaches that RUN, hours into a build.
#   2. PSScriptAnalyzer (optional) — runs only if the module is installed; skipped with
#      a note otherwise, so the gate is always usable on an offline/bare host.
# Exit code is non-zero if any parse error (or, with -FailOnAnalyzer, any analyzer
# finding of Warning or Error severity) is found. Run it before Build-Buildkit.ps1 and in CI.

[CmdletBinding()]
param(
    # Also fail the run on PSScriptAnalyzer findings of Warning or Error severity
    # (default: analyzer is advisory).
    [switch]$FailOnAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # windows/scripts
$windowsDir = Split-Path -Parent $scriptsDir                        # windows
$settings = Join-Path $windowsDir 'PSScriptAnalyzerSettings.psd1'

# Collect every script/module except the archived (dead) tree. One recursive
# walk over windows\ (2026-08-10, backlog #21): the former three-list form
# missed trees like windows\upstream, and windows\diagnostics had silently
# never been linted before joining the scope the same day.
$targets = @(
    Get-ChildItem -Path $windowsDir -Recurse -Include '*.ps1', '*.psm1' -File
    # shared/windows: templates consumed by 4 external repos — an edit there
    # was gated by NOTHING until 2026-08-21 (no lint, no tests, no workflow
    # trigger); exactly the class of miss #108 cleaned up in-repo.
    Get-ChildItem -Path (Join-Path (Split-Path -Parent $windowsDir) 'shared\windows') -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue
) | Where-Object { $_.FullName -notmatch '\\archive\\' } | Sort-Object FullName -Unique

Write-Host "== Lint gate: $($targets.Count) files ==" -ForegroundColor Cyan

# AST trap detectors ride the parse loop (backlog #21: the ArgQuoting test
# suite used to re-parse the whole tree a second time per gate cycle, and
# its standalone sweep forgot the \archive\ exclusion).
Import-Module (Join-Path $scriptsDir 'modules\WindowsLint.Common.psm1')

# ---- Pass 1: parse + AST traps ----
$parseErrors = New-Object System.Collections.ArrayList
$astViolations = New-Object System.Collections.ArrayList
foreach ($file in $targets) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            [void]$parseErrors.Add([pscustomobject]@{
                    File = $file.FullName; Line = $e.Extent.StartLineNumber; Message = $e.Message
                })
        }
        continue
    }
    $rel = $file.FullName.Substring($windowsDir.Length).TrimStart('\', '/')
    foreach ($v in @(Get-BarewordCommaAttrViolation -Ast $ast -Label $rel)) {
        [void]$astViolations.Add("bareword comma-attribute native arg (quote the whole string): $v")
    }
    foreach ($v in @(Get-SwitchShadowViolation -Ast $ast -Label $rel)) {
        [void]$astViolations.Add("[switch] parameter shadowed by non-boolean assignment (rename the local): $v")
    }
    foreach ($v in @(Get-GluedParameterViolation -Ast $ast -Label $rel)) {
        [void]$astViolations.Add("parameter token glued to its argument (-Path`$x / -Path(...) parse but bind wrong): $v")
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

if ($astViolations.Count -gt 0) {
    Write-Host "AST TRAPS: $($astViolations.Count) violation(s)" -ForegroundColor Red
    foreach ($v in $astViolations) { Write-Host "  $v" -ForegroundColor Red }
} else {
    Write-Host 'AST TRAPS: none (comma-attr quoting + switch shadowing + glued parameter tokens)' -ForegroundColor Green
}

# ---- Pass 2: PSScriptAnalyzer (optional) ----
$analyzerFindings = @()
# Initialized HERE, not inside the PSSA branch: the verdict block reads it
# unconditionally, and an undefined variable there would fail under StrictMode
# on the "PSScriptAnalyzer not installed" path (backlog #82).
$analyzerCrashes = @()
$errs = @()
$warns = @()
$analyzerModule = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if ($analyzerModule) {
    # Import the DISCOVERED module object, not the bare name: a name import
    # resolves independently and can load a different (newest) installation,
    # shadowing CI's pinned install - the version reported below must be the
    # version that actually ran.
    Import-Module $analyzerModule -Force
    # Invoke-ScriptAnalyzer -Path takes a SINGLE path (an array throws "cannot convert Object[] to
    # String"), so analyze each target file and aggregate.
    # PSSA 1.25.0 intermittently throws "Object reference not set to an instance
    # of an object." from inside Invoke-ScriptAnalyzer — observed ~2 in 9 runs
    # on 2026-08-14, never on the same file twice, and always clean on an
    # immediate re-run (backlog #82). An exception is NOT a lint finding: left
    # unhandled it aborts the whole gate, which reads as a spurious red in CI
    # and trains you to re-run instead of read. Retry the file once, then
    # record it as an INFRASTRUCTURE failure — never silently skip it, because
    # a skipped file is a fail-open hole in the gate.
    foreach ($t in $targets) {
        $params = @{ Path = $t.FullName }
        if (Test-Path $settings) { $params['Settings'] = $settings }
        try {
            $analyzerFindings += @(Invoke-ScriptAnalyzer @params)
        } catch {
            Write-Host "  [retry] PSSA threw on $($t.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow
            try {
                $analyzerFindings += @(Invoke-ScriptAnalyzer @params)
            } catch {
                $analyzerCrashes += [pscustomobject]@{ File = $t.Name; Message = $_.Exception.Message }
            }
        }
    }
    $errs = @($analyzerFindings | Where-Object { $_.Severity -eq 'Error' })
    $warns = @($analyzerFindings | Where-Object { $_.Severity -eq 'Warning' })
    $color = if ($errs.Count -gt 0) { 'Red' } elseif ($warns.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "PSSA: $($errs.Count) error(s), $($warns.Count) warning(s) [PSScriptAnalyzer $($analyzerModule.Version)]" -ForegroundColor $color
    foreach ($f in ($analyzerFindings | Sort-Object Severity -Descending | Select-Object -First 40)) {
        $c = if ($f.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1}:{2}  {3} ({4})" -f $f.Severity, $f.ScriptName, $f.Line, $f.Message, $f.RuleName) -ForegroundColor $c
    }
    if ($analyzerCrashes.Count -gt 0) {
        # Reported separately from findings on purpose: these files were NOT
        # analysed, so the gate's coverage is incomplete and saying otherwise
        # would be a lie. Distinct exit code so CI can tell a tooling fault from
        # a code-quality failure.
        Write-Host "PSSA INFRASTRUCTURE FAILURE: $($analyzerCrashes.Count) file(s) could not be analysed after a retry:" -ForegroundColor Red
        foreach ($c in $analyzerCrashes) { Write-Host "  $($c.File): $($c.Message)" -ForegroundColor Red }
        Write-Host 'These files were NOT linted - coverage is incomplete.' -ForegroundColor Red
    }
} else {
    Write-Host "PSSA: PSScriptAnalyzer not installed - skipping (install-time only; parse gate still enforced)" -ForegroundColor DarkYellow
}

# ---- Verdict ----
$fail = ($parseErrors.Count -gt 0) -or ($astViolations.Count -gt 0)
# -FailOnAnalyzer treats Warning as well as Error findings as fatal, matching the
# "findings" wording in the help text.
if ($FailOnAnalyzer -and ($errs.Count -gt 0 -or $warns.Count -gt 0)) { $fail = $true }
# Exit 2 = the GATE broke, not the code (backlog #82). Distinct from 1 so CI can
# retry a tooling fault without treating it as a lint failure, and so a green
# "LINT OK" is never printed over files that were never analysed. Reported even
# without -FailOnAnalyzer: incomplete coverage is not a style opinion.
# ORDER MATTERS. $fail comes from parse errors and AST-trap violations — hard,
# deterministic code defects. Exit 2 means "the TOOL broke, retry me", so
# reporting it FIRST would let a CI retry loop re-run a build that has a genuine
# parse error while the operator never sees LINT FAILED. Announce the
# infrastructure problem either way, but let a real defect win the exit code.
# (Test-Container.ps1 already gets this ordering right: failures branch
# before the coverage branch.)
if ($analyzerCrashes.Count -gt 0) {
    Write-Host "`nLINT INCONCLUSIVE - PSScriptAnalyzer failed on $($analyzerCrashes.Count) file(s)" -ForegroundColor Red
}
if ($fail) { Write-Host "`nLINT FAILED" -ForegroundColor Red; exit 1 }
if ($analyzerCrashes.Count -gt 0) { exit 2 }
Write-Host "`nLINT OK" -ForegroundColor Green
exit 0

