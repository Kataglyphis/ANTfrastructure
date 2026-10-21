#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Parse, AST-trap and PSScriptAnalyzer gate for every Windows build script; a missing PSScriptAnalyzer throws.

[CmdletBinding()]
param(
    # Also fail on PSScriptAnalyzer Warning or Error findings (default: advisory).
    [switch]$FailOnAnalyzer,
    # Dirs or files to lint; omitted = the hub's own trees. The ruleset stays the hub's, used by reference.
    [string[]]$Path,
    # Analyzer processes at once (default 4: each pays PSSA's start-up, and 8 or 16 were no faster); 1 analyses in turn.
    [ValidateRange(1, 256)]
    [int]$Jobs = [Math]::Min(4, [Environment]::ProcessorCount),
    # Internal: run as one analyzer batch over -InputFile's paths.
    [switch]$PssaBatch,
    # Internal: the paths that batch analyses, one per line.
    [string]$InputFile,
    # Internal: where that batch writes its findings for the parent.
    [string]$ResultFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# $PSScriptRoot anchors the ruleset to this script, not to a consumer's -Path.
$scriptsDir = $PSScriptRoot                                         # windows/scripts
$windowsDir = Split-Path -Parent $scriptsDir                        # windows
$settings = Join-Path $windowsDir 'PSScriptAnalyzerSettings.psd1'

# A file the analyzer never finished: counted apart from findings, as an infrastructure failure.
function New-CrashVerdict {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Message, [string]$Note)
    return [pscustomobject]@{ Findings = @(); Note = $Note; Crash = [pscustomobject]@{ File = (Split-Path -Leaf $File); Message = $Message } }
}

# One path per call; PSSA crashes intermittently, so retry once, then record an infrastructure failure, never skip.
function Invoke-AnalyzerOnce {
    param([Parameter(Mandatory)][string]$File)
    $params = @{ Path = $File }
    if (Test-Path $settings) { $params['Settings'] = $settings }
    $note = $null
    try {
        return [pscustomobject]@{ Findings = @(Invoke-ScriptAnalyzer @params); Crash = $null; Note = $null }
    } catch {
        $note = "  [retry] PSSA threw on $(Split-Path -Leaf $File): $($_.Exception.Message)"
    }
    try {
        return [pscustomobject]@{ Findings = @(Invoke-ScriptAnalyzer @params); Crash = $null; Note = $note }
    } catch {
        return New-CrashVerdict -File $File -Message $_.Exception.Message -Note $note
    }
}

# The newest PSScriptAnalyzer installed, or $null; the object, not the name, so the version reported is the one loaded.
function Get-AnalyzerModule {
    Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
}

# <verdict> <severity cast>: findings as plain data, so a verdict crosses a process boundary as JSON.
function ConvertTo-PlainVerdict {
    param([Parameter(Mandatory)]$Verdict, [Parameter(Mandatory)][scriptblock]$Severity)
    $findings = foreach ($x in @($Verdict.Findings)) {
        [pscustomobject]@{ Severity = (& $Severity $x.Severity); ScriptName = $x.ScriptName; Line = $x.Line; Message = $x.Message; RuleName = $x.RuleName }
    }
    return [pscustomobject]@{ Note = $Verdict.Note; Crash = $Verdict.Crash; Findings = @($findings) }
}

# <files>: one verdict per file, from this process or from -Jobs analyzer batches.
function Get-AnalyzerVerdict {
    param([Parameter(Mandatory)][object[]]$Target)
    $batchCount = [Math]::Min($Target.Count, $Jobs)
    if ($batchCount -le 1) {
        foreach ($t in $Target) { Invoke-AnalyzerOnce -File $t.FullName }
    } else {
        Import-Module (Join-Path $scriptsDir 'modules\WindowsFanOut.Common.psm1') -Force
        $lists = @(for ($b = 0; $b -lt $batchCount; $b++) { , @(for ($i = $b; $i -lt $Target.Count; $i += $batchCount) { $Target[$i].FullName }) })
        $sets = @($lists | ForEach-Object { , @('-PssaBatch') })
        foreach ($child in @(Invoke-PwshFanOut -Script $PSCommandPath -ArgumentSets $sets -InputSets $lists -Jobs $Jobs)) {
            if ($null -eq $child.Result) {
                # A batch that wrote nothing analysed nothing: each of its files is an infrastructure failure.
                $why = $child.Output | Select-Object -Last 1
                foreach ($f in $lists[$child.Index]) { New-CrashVerdict -File $f -Message "analyzer batch $($child.Index) wrote no verdict: $why" }
                continue
            }
            foreach ($v in @($child.Result | ConvertFrom-Json)) {
                ConvertTo-PlainVerdict -Verdict $v -Severity { param($s) [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]$s }
            }
        }
    }
}

# A batch child: PSSA keeps process-wide caches that runspaces corrupt, so parallel analysis takes processes.
if ($PssaBatch) {
    Import-Module (Get-AnalyzerModule) -Force
    $out = foreach ($f in @(Get-Content -LiteralPath $InputFile | Where-Object { $_ })) {
        ConvertTo-PlainVerdict -Verdict (Invoke-AnalyzerOnce -File $f) -Severity { param($s) [int]$s }
    }
    ConvertTo-Json -InputObject @($out) -Depth 5 | Set-Content -LiteralPath $ResultFile
    exit 0
}

# Default scope: all of windows\, the shared\windows templates consumer repos use, and the scripts composite actions ship.
$roots = if ($Path) {
    $Path
} else {
    @(
        $windowsDir
        Join-Path (Split-Path -Parent $windowsDir) 'shared\windows'
        Join-Path (Split-Path -Parent $windowsDir) '.github\actions'
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
$analyzerModule = Get-AnalyzerModule
if ($analyzerModule) {
    # The discovered object, not the name, which could load another install than the version reported.
    Import-Module $analyzerModule -Force
    $verdicts = @(Get-AnalyzerVerdict -Target $targets)
    foreach ($v in @($verdicts)) {
        if ($v.Note) { Write-Host $v.Note -ForegroundColor DarkYellow }
        $analyzerFindings += @($v.Findings)
        if ($v.Crash) { $analyzerCrashes += $v.Crash }
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

