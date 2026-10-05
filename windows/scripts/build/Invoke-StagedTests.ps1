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
    "kind": "gtest" | "cargo" | "pytest" | "exitcode", "skip_pattern": "<regex>" }. gtest, cargo and pytest are
    counted from their own summaries (a pytest exe is the product's python.exe with "-m pytest" in args); an
    exitcode entry is one test. skip_pattern (optional) names the line a test prints when it skips
    itself, which its framework counts as passed (a wgpu test without an adapter): each match moves one test from
    passed to skipped. A failing test is counted, not thrown, so the verdict line always prints; a missing binary
    or a summary that cannot be read is an error.
#>
[CmdletBinding()]
param(
    [string]$Manifest = (Join-Path $PSScriptRoot 'tests.json'),
    # Test seam: WER event 1000 records since a time; the real reader needs a Windows event log.
    [scriptblock]$CrashEventReader = {
        param([datetime]$Since)
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $Since } -ErrorAction Stop
    }
)

$ErrorActionPreference = 'Stop'
# A failing test exits non-zero by design; it is counted below rather than raised here.
$PSNativeCommandUseErrorActionPreference = $false

# NTSTATUS names for what a crashed test binary exits with; a bare negative decimal names nothing.
$script:CrashNames = @{
    0xC0000005 = 'STATUS_ACCESS_VIOLATION'; 0xC0000409 = 'STATUS_STACK_BUFFER_OVERRUN (a fail-fast abort)'
    0xC00000FD = 'STATUS_STACK_OVERFLOW'; 0xC0000374 = 'STATUS_HEAP_CORRUPTION'
    0xC000001D = 'STATUS_ILLEGAL_INSTRUCTION'; 0xC0000135 = 'STATUS_DLL_NOT_FOUND'
    0xC0000139 = 'STATUS_ENTRYPOINT_NOT_FOUND'; 0xC0000142 = 'STATUS_DLL_INIT_FAILED'
    0xC0000094 = 'STATUS_INTEGER_DIVIDE_BY_ZERO'; 0xC000013A = 'STATUS_CONTROL_C_EXIT'
    0x80000003 = 'STATUS_BREAKPOINT'
}

# "<decimal> (0x<hex> <NTSTATUS name>)": the form a crash is looked up by.
function Format-StagedExitCode([int]$Code) {
    $hex = '0x{0:X8}' -f $Code
    if ($script:CrashNames.ContainsKey($Code)) { return "$Code ($hex $($script:CrashNames[$Code]))" }
    return "$Code ($hex)"
}

# Windows Error Reporting's event 1000 for a binary that crashed since -Since, which names the faulting module; best effort.
function Get-StagedCrashReport([string]$ExeName, [datetime]$Since) {
    try {
        $events = @(& $CrashEventReader $Since)
    } catch {
        return $null
    }
    foreach ($werEvent in $events) {
        # Properties, not Message, which is localized: [0] application, [3] module, [6] exception code, [7] offset.
        $data = @($werEvent.Properties | ForEach-Object { "$($_.Value)" })
        if ($data.Count -lt 8 -or $data[0] -ne $ExeName) { continue }
        return "WER: faulting module $($data[3]) at offset 0x$($data[7]), exception 0x$($data[6])"
    }
    return $null
}

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
        'pytest' {
            # The final "928 passed, 31 skipped in 9.1s" line, framed in = unless -q; errors are failures, xfails skips.
            $hit = @($Lines | Select-String -Pattern '^(=+ )?(\d+ \w+(, )?)+.* in [\d.]+s\b|^(=+ )?no tests ran in ') | Select-Object -Last 1
            if (-not $hit) { throw "no pytest summary ('== N passed ... in Ns ==') in its output" }
            $n = @{}
            foreach ($m in [regex]::Matches($hit.Line, '(\d+) (\w+)')) { $n[$m.Groups[2].Value] = [int]$m.Groups[1].Value }
            Add-StagedCount $tally -Passed ($n['passed'] + $n['xpassed']) -Failed ($n['failed'] + $n['error'] + $n['errors']) -Skipped ($n['skipped'] + $n['xfailed'])
        }
        'exitcode' { Add-StagedCount $tally -Passed ([int]($ExitCode -eq 0)) -Failed ([int]($ExitCode -ne 0)) }
        default { throw "unknown test kind '$Kind' (gtest, cargo, pytest, exitcode)" }
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
    $started = Get-Date
    # Each binary runs from its own directory, where its DLLs were staged.
    Push-Location (Split-Path -Parent $exe)
    try {
        $lines = @(& $exe @testArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $lines | ForEach-Object { Write-Host $_ }
    try {
        $counts = Get-StagedTestCount -Kind $entry.kind -Lines $lines -ExitCode $code
    } catch {
        # A binary that died before its summary: the exit code and WER are all that name the crash.
        $crash = if ($code -lt 0) { Get-StagedCrashReport -ExeName (Split-Path -Leaf $exe) -Since $started }
        throw "$($entry.exe): $($_.Exception.Message); exit $(Format-StagedExitCode $code)$(if ($crash) { "; $crash" })"
    }
    if ($entry.PSObject.Properties['skip_pattern']) {
        $selfSkipped = [Math]::Min(@($lines | Select-String -Pattern $entry.skip_pattern).Count, $counts.Passed)
        $counts.Passed -= $selfSkipped; $counts.Skipped += $selfSkipped
    }
    Write-Host "   -> passed $($counts.Passed), failed $($counts.Failed), skipped $($counts.Skipped) (exit $(Format-StagedExitCode $code))"
    Add-StagedCount $total -Passed $counts.Passed -Failed $counts.Failed -Skipped $counts.Skipped
}
Write-Output "TESTS: passed=$($total.Passed) failed=$($total.Failed) skipped=$($total.Skipped)"
# The last test's exit code would otherwise leak into $LASTEXITCODE; the line above is the verdict.
exit 0
