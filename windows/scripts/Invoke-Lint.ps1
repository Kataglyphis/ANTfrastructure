#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Parse, AST-trap and PSScriptAnalyzer gate for every Windows build script; a missing PSScriptAnalyzer throws.

[CmdletBinding()]
param(
    # Also fail on PSScriptAnalyzer Warning or Error findings (default: advisory).
    [switch]$FailOnAnalyzer,
    # Dirs or files to lint; omitted = the hub's own trees. The ruleset stays the hub's, used by reference.
    [string[]]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# $PSScriptRoot anchors the ruleset to this script, not to a consumer's -Path.
$scriptsDir = $PSScriptRoot                                         # windows/scripts
$windowsDir = Split-Path -Parent $scriptsDir                        # windows
$settings = Join-Path $windowsDir 'PSScriptAnalyzerSettings.psd1'

# Default scope: all of windows\ plus the shared\windows templates consumer repos use.
$roots = if ($Path) {
    $Path
} else {
    @(
        $windowsDir
        Join-Path (Split-Path -Parent $windowsDir) 'shared\windows'
    )
}

# A missing root throws, or a typo would pass as zero clean files.
$found = foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { throw "Lint path does not exist: $root" }
    if (Test-Path -LiteralPath $root -PathType Container) {
        Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1', '*.psm1' -File
    } else {
        Get-Item -LiteralPath $root
    }
}
# @() around the whole pipeline: one result unwraps to a scalar and .Count dies under StrictMode.
$targets = @($found |
        Where-Object { $_.FullName -notmatch '\\archive\\' } |
        Sort-Object FullName -Unique)

# Same reason: a scope that resolves to nothing must not report success.
if ($targets.Count -eq 0) {
    throw "No .ps1/.psm1 files found under: $($roots -join ', ')"
}

Write-Host "== Lint gate: $($targets.Count) files ==" -ForegroundColor Cyan

# The AST trap detectors ride the parse loop, so the tree is parsed once.
Import-Module (Join-Path $scriptsDir 'modules\WindowsLint.Common.psm1')

# Pass 1: parse and AST traps
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
    # GetRelativePath, not Substring: Substring throws for any file outside windows\.
    $rel = [IO.Path]::GetRelativePath($windowsDir, $file.FullName)
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

# Pass 2: PSScriptAnalyzer (mandatory)
$analyzerFindings = @()
# Initialized here because the verdict reads them unconditionally under StrictMode.
$analyzerCrashes = @()
$errs = @()
$warns = @()
$analyzerModule = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if ($analyzerModule) {
    # The discovered object, not the name, which could load another install than the version reported.
    Import-Module $analyzerModule -Force
    # One path per call; PSSA crashes intermittently, so retry once, then record an infrastructure failure, never skip.
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
        # Reported apart from findings: these files were not analysed at all.
        Write-Host "PSSA INFRASTRUCTURE FAILURE: $($analyzerCrashes.Count) file(s) could not be analysed after a retry:" -ForegroundColor Red
        foreach ($c in $analyzerCrashes) { Write-Host "  $($c.File): $($c.Message)" -ForegroundColor Red }
        Write-Host 'These files were NOT linted - coverage is incomplete.' -ForegroundColor Red
    }
} else {
    # Throw, never skip: a gate that analysed nothing must not print LINT OK.
    throw ("PSScriptAnalyzer is not installed: the analyzer pass would cover 0 of " +
        "$($targets.Count) file(s), so this gate refuses to report a verdict. Install it with " +
        "'Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -Scope CurrentUser'.")
}

# Verdict
$fail = ($parseErrors.Count -gt 0) -or ($astViolations.Count -gt 0)
if ($FailOnAnalyzer -and ($errs.Count -gt 0 -or $warns.Count -gt 0)) { $fail = $true }
# Exit 2 = the tool broke (retryable), 1 = a code defect, which wins so a retry loop cannot hide it.
if ($analyzerCrashes.Count -gt 0) {
    Write-Host "`nLINT INCONCLUSIVE - PSScriptAnalyzer failed on $($analyzerCrashes.Count) file(s)" -ForegroundColor Red
}
if ($fail) { Write-Host "`nLINT FAILED" -ForegroundColor Red; exit 1 }
if ($analyzerCrashes.Count -gt 0) { exit 2 }
Write-Host "`nLINT OK" -ForegroundColor Green
exit 0

