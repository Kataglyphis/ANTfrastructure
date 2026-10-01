#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Runs the test binaries a cross build staged and prints the one counts line container-ci-windows.yml's test-command reads.

<#
.SYNOPSIS
    Runs every test in -Manifest (tests.json beside it) and prints `TESTS: passed=<n> failed=<n> skipped=<n>`.
.DESCRIPTION
    Self-contained on purpose: the arm64 runner has no checkout, so a consumer's build copies this script and its
    tests.json into the test-artifact-dir. Each entry is { "exe": "<path relative to the manifest>", "args": [...],
    "kind": "gtest" | "cargo" | "exitcode", "skip_pattern": "<regex>" }. gtest and cargo are counted from their own
    summaries; an exitcode entry is one test. skip_pattern (optional) names the line a test prints when it skips
    itself, which its framework counts as passed (a wgpu test without an adapter): each match moves one test from
    passed to skipped. A failing test is counted, not thrown, so the verdict line always prints; a missing binary
    or a summary that cannot be read is an error.
#>
[CmdletBinding()]
param(
    [string]$Manifest = (Join-Path $PSScriptRoot 'tests.json')
)

$ErrorActionPreference = 'Stop'
# A failing test exits non-zero by design; it is counted below rather than raised here.
$PSNativeCommandUseErrorActionPreference = $false

# Adds -Passed/-Failed/-Skipped to the running -Into tally.
function Add-StagedCount([hashtable]$Into, [int]$Passed, [int]$Failed, [int]$Skipped) {
    $Into.Passed += $Passed; $Into.Failed += $Failed; $Into.Skipped += $Skipped
}

function Get-StagedTestCount {
    # Passed, failed and skipped from one binary's output, by the summary its framework prints.
    param([Parameter(Mandatory)][string]$Kind, [AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][int]$ExitCode)
    $tally = @{ Passed = 0; Failed = 0; Skipped = 0 }
    switch ($Kind) {
        'gtest' {
            foreach ($label in 'PASSED', 'FAILED', 'SKIPPED') {
                $hit = @($Lines | Select-String -Pattern "^\[\s*$label\s*\]\s+(\d+) tests?") | Select-Object -Last 1
                if ($hit) { $tally[$label.Substring(0, 1) + $label.Substring(1).ToLowerInvariant()] = [int]$hit.Matches[0].Groups[1].Value }
            }
            if ($tally.Passed + $tally.Failed + $tally.Skipped -eq 0) { throw 'no googletest summary ([  PASSED  ] / [  FAILED  ]) in its output' }
        }
        'cargo' {
            $hits = @($Lines | Select-String -Pattern '^test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored')
            if ($hits.Count -eq 0) { throw "no libtest 'test result:' line in its output" }
            foreach ($hit in $hits) {
                $g = $hit.Matches[0].Groups
                Add-StagedCount $tally -Passed $g[1].Value -Failed $g[2].Value -Skipped $g[3].Value
            }
        }
        'exitcode' { Add-StagedCount $tally -Passed ([int]($ExitCode -eq 0)) -Failed ([int]($ExitCode -ne 0)) }
        default { throw "unknown test kind '$Kind' (gtest, cargo, exitcode)" }
    }
    # A crash after a clean summary, or a gtest exit 1 with no FAILED line, still counts as one failure.
    if ($ExitCode -ne 0 -and $tally.Failed -eq 0) { $tally.Failed = 1 }
    return $tally
}

$root = Split-Path -Parent (Resolve-Path -LiteralPath $Manifest).ProviderPath
$entries = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json)
if ($entries.Count -eq 0) { throw "$Manifest lists no tests" }
$total = @{ Passed = 0; Failed = 0; Skipped = 0 }
foreach ($entry in $entries) {
    $exe = Join-Path $root $entry.exe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "staged test missing: $exe" }
    $testArgs = @(if ($entry.PSObject.Properties['args']) { $entry.args })
    Write-Host "== $($entry.exe) $($testArgs -join ' ')"
    # Each binary runs from its own directory, where its DLLs were staged.
    Push-Location (Split-Path -Parent $exe)
    try {
        $lines = @(& $exe @testArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $lines | ForEach-Object { Write-Host $_ }
    $counts = Get-StagedTestCount -Kind $entry.kind -Lines $lines -ExitCode $code
    if ($entry.PSObject.Properties['skip_pattern']) {
        $selfSkipped = [Math]::Min(@($lines | Select-String -Pattern $entry.skip_pattern).Count, $counts.Passed)
        $counts.Passed -= $selfSkipped; $counts.Skipped += $selfSkipped
    }
    Write-Host "   -> passed $($counts.Passed), failed $($counts.Failed), skipped $($counts.Skipped) (exit $code)"
    Add-StagedCount $total -Passed $counts.Passed -Failed $counts.Failed -Skipped $counts.Skipped
}
Write-Output "TESTS: passed=$($total.Passed) failed=$($total.Failed) skipped=$($total.Skipped)"
# The last test's exit code would otherwise leak into $LASTEXITCODE; the line above is the verdict.
exit 0
