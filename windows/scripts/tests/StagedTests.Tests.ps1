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
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][object[]]$Tests)
    $entries = foreach ($t in $Tests) {
        $body = @('@echo off') + @($t.Lines | ForEach-Object { "echo $_" }) + "exit /b $($t.Exit)"
        Set-Content -LiteralPath (Join-Path $Dir "$($t.Name).cmd") -Value $body -Encoding ascii
        @{ exe = "$($t.Name).cmd"; kind = $t.Kind }
    }
    ConvertTo-Json -InputObject @($entries) | Set-Content -LiteralPath (Join-Path $Dir 'tests.json') -Encoding utf8
    return @(& $script:StagedTests -Manifest (Join-Path $Dir 'tests.json') 6>$null) | Select-Object -Last 1
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
}
