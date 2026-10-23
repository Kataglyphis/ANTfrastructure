#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real arm64 run (container-ci-windows.yml's run-arm64 job does that on windows-11-arm).

$script:StagedTests = Join-Path (Get-RepoRoot) 'windows\scripts\build\Invoke-StagedTests.ps1'

# One fake test binary: a .cmd named -Name that echoes -Lines and exits -Exit, counted as -Kind.
function script:New-FakeTest([string]$Name, [string]$Kind, [int]$Exit, [string[]]$Lines) {
    return [pscustomobject]@{ Name = $Name; Kind = $Kind; Exit = $Exit; Lines = $Lines }
}

# Writes the fake binaries plus tests.json, and returns the verdict line Invoke-StagedTests.ps1 prints.
function script:Invoke-FakeSuite {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][object[]]$Tests, [scriptblock]$CrashEventReader)
    $entries = foreach ($t in $Tests) {
        $null = New-TestBatchTool -Directory $Dir -Name "$($t.Name).cmd" -Line @($t.Lines | ForEach-Object { "echo $_" }) -ExitCode $t.Exit
        @{ exe = "$($t.Name).cmd"; kind = $t.Kind }
    }
    ConvertTo-Json -InputObject @($entries) | Set-Content -LiteralPath (Join-Path $Dir 'tests.json') -Encoding utf8
    $seam = @{}
    if ($CrashEventReader) { $seam.CrashEventReader = $CrashEventReader }
    return @(& $script:StagedTests -Manifest (Join-Path $Dir 'tests.json') @seam 6>$null) | Select-Object -Last 1
}

Describe 'Invoke-StagedTests.ps1' {

    It 'sums each framework''s summary (pytest errors as failures, xfails as skips), and counts failures, crashes included' {
        $libtest = 'test result: ok. {0} passed; 0 failed; {1} ignored; 0 measured; 0 filtered out'
        $green = @(
            (New-FakeTest 'core_test' 'gtest' 0 '[==========] 4 tests ran.', '[  PASSED  ] 3 tests.', '[  SKIPPED ] 1 test, listed below:'),
            (New-FakeTest 'crate' 'cargo' 0 ($libtest -f 5, 2), ($libtest -f 1, 0)),
            (New-FakeTest 'py' 'pytest' 0 'tests/unit/test_a.py ....', '======= 928 passed, 31 skipped, 2 xfailed, 1 xpassed in 9.10s ======='),
            (New-FakeTest 'py_quiet' 'pytest' 0 '....', '7 passed, 1 skipped in 0.42s'),
            (New-FakeTest 'smoke' 'exitcode' 0 'ok')
        )
        $red = @(
            (New-FakeTest 'red_test' 'gtest' 1 '[  PASSED  ] 2 tests.', '[  FAILED  ] 1 test, listed below:'),
            (New-FakeTest 'crash_test' 'gtest' 3 '[  PASSED  ] 4 tests.'),
            (New-FakeTest 'red_py' 'pytest' 1 '===== 1 failed, 5 passed, 2 errors in 1.20s ====='),
            (New-FakeTest 'bad' 'exitcode' 2 'boom')
        )
        foreach ($case in @(@($green, 'TESTS: passed=946 failed=0 skipped=37'), @($red, 'TESTS: passed=11 failed=6 skipped=0'))) {
            Invoke-InTestDir { param($d) Assert-Equal $case[1] (Invoke-FakeSuite -Dir $d -Tests $case[0]) $case[1] }
        }
    }

    It 'refuses a binary whose summary it cannot read, and a staged test that is missing' {
        Invoke-InTestDir { param($d)
            Assert-Throws { Invoke-FakeSuite -Dir $d -Tests @(New-FakeTest 'mute' 'gtest' 0 'nothing here') } -MessagePattern 'no googletest summary'
            Set-Content -LiteralPath (Join-Path $d 'tests.json') -Value '[{"exe":"gone.exe","kind":"exitcode"}]' -Encoding utf8
            Assert-Throws { & $script:StagedTests -Manifest (Join-Path $d 'tests.json') 6>$null } -MessagePattern 'staged test missing'
        }
    }

    # The arm64 WARP run (36889467167) died after "running 39 tests" and its log named nothing.
    It 'names a binary that dies before its summary: its NTSTATUS, and the faulting module WER logged' {
        Invoke-InTestDir { param($d)
            $crash = { param($Reader, $Code) Invoke-FakeSuite -Dir $d -CrashEventReader $Reader -Tests @(New-FakeTest 'headless' 'cargo' $Code 'running 39 tests') }
            Assert-Throws { & $crash { param($Since) throw 'no event log here' } -1073741819 } `
                -MessagePattern "headless\.cmd: no libtest 'test result:' line in its output; exit -1073741819 \(0xC0000005 STATUS_ACCESS_VIOLATION\)$"
            # Event 1000's data in its own order; its Message is localized, so the script never reads it.
            $record = { param($App, $Module) [pscustomobject]@{ Properties = @($App, '1.0', 'aad2c1f4', $Module, '10.0', 'aad2c1f4', 'c0000409', '00000000000012ab' |
                        ForEach-Object { [pscustomobject]@{ Value = $_ } }) } }
            $wer = { param($Since) & $record 'other.exe' 'wrong.dll'; & $record 'HEADLESS.cmd' 'd3d12warp.dll' }.GetNewClosure()
            Assert-Throws { & $crash $wer -1073740791 } `
                -MessagePattern '0xC0000409 STATUS_STACK_BUFFER_OVERRUN \(a fail-fast abort\)\); WER: faulting module d3d12warp\.dll at offset 0x00000000000012ab, exception 0xc0000409$'
        }
    }

    It 'moves self-skipped tests from passed to skipped by skip_pattern, never below zero' {
        Invoke-InTestDir { param($d)
            $lines = 'SKIP: no GPU adapter available in this environment', 'SKIP: no GPU adapter available in this environment', 'test result: ok. 5 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out'
            $null = Invoke-FakeSuite -Dir $d -Tests @(New-FakeTest 'renderer' 'cargo' 0 @($lines))
            $entries = @(Get-Content -LiteralPath (Join-Path $d 'tests.json') -Raw | ConvertFrom-Json)
            $entries[0] | Add-Member -NotePropertyName skip_pattern -NotePropertyValue '^SKIP: no GPU adapter'
            ConvertTo-Json -InputObject $entries | Set-Content -LiteralPath (Join-Path $d 'tests.json') -Encoding utf8
            Assert-Equal 'TESTS: passed=3 failed=0 skipped=3' (@(& $script:StagedTests -Manifest (Join-Path $d 'tests.json') 6>$null) | Select-Object -Last 1) 'two self-skips plus the ignored one'
        }
    }

    It 'leaves no failing exit code behind, so the lane reads its verdict from the line' {
        Invoke-InTestDir { param($d)
            $null = Invoke-FakeSuite -Dir $d -Tests @(New-FakeTest 'red_test' 'gtest' 1 '[  PASSED  ] 1 test.', '[  FAILED  ] 1 test, listed below:')
            Assert-Equal 0 $LASTEXITCODE 'exit 0 after printing the verdict'
        }
    }

    It 'with -AssertVerdict throws after the counts line on a failure or on nothing passed, and passes a green run' {
        Invoke-InTestDir { param($d)
            $run = { param($Tests) $null = Invoke-FakeSuite -Dir $d -Tests $Tests; @(& $script:StagedTests -Manifest (Join-Path $d 'tests.json') -AssertVerdict 6>$null) }
            Assert-Equal 'TESTS: passed=1 failed=0 skipped=0' (@(& $run @(New-FakeTest 'ok' 'exitcode' 0 'ok')) | Select-Object -Last 1)
            Assert-Throws { & $run @(New-FakeTest 'red' 'exitcode' 3 'boom') } -MessagePattern '^1 staged test\(s\) failed \(0 passed, 0 skipped\)\.$'
            Assert-Throws { & $run @(New-FakeTest 'idle' 'cargo' 0 'test result: ok. 0 passed; 0 failed; 2 ignored; 0 measured; 0 filtered out') } `
                -MessagePattern '^No staged test passed'
        }
    }
}

Describe 'Assert-StagedTestVerdict' {

    It 'returns the counts of the one verdict line, and refuses none, two, a failure or nothing passed' {
        $ok = Assert-StagedTestVerdict -Lines @('== a.exe', 'TESTS: passed=7 failed=0 skipped=2', 'tail') -Label 'host tests'
        Assert-Equal '7|0|2' "$($ok.Passed)|$($ok.Failed)|$($ok.Skipped)"
        Assert-Throws { Assert-StagedTestVerdict -Lines @('no verdict') -Label 'host tests' } -MessagePattern "^host tests printed 0 'TESTS: "
        Assert-Throws { Assert-StagedTestVerdict -Lines @('TESTS: passed=1 failed=0 skipped=0', 'TESTS: passed=1 failed=0 skipped=0') } -MessagePattern 'printed 2 '
        Assert-Throws { Assert-StagedTestVerdict -Lines @('TESTS: passed=4 failed=1 skipped=0') -Label 'arm64' } -MessagePattern '^arm64: 1 failed \(4 passed, 0 skipped\)\.$'
        Assert-Throws { Assert-StagedTestVerdict -Lines @('TESTS: passed=0 failed=0 skipped=3') } -MessagePattern 'no test passed'
        Assert-Throws { Assert-StagedTestVerdict -Lines @() } -MessagePattern 'printed 0 '
    }
}
