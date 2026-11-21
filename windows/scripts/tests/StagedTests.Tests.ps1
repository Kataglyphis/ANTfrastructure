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
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][object[]]$Tests, [scriptblock]$CrashEventReader, [int]$CrashEventWaitSeconds = 0)
    $entries = foreach ($t in $Tests) {
        $null = New-TestBatchTool -Directory $Dir -Name "$($t.Name).cmd" -Line @($t.Lines | ForEach-Object { "echo $_" }) -ExitCode $t.Exit
        @{ exe = "$($t.Name).cmd"; kind = $t.Kind }
    }
    ConvertTo-Json -InputObject @($entries) | Set-Content -LiteralPath (Join-Path $Dir 'tests.json') -Encoding utf8
    $seam = @{ CrashEventWaitSeconds = $CrashEventWaitSeconds }
    if ($CrashEventReader) { $seam.CrashEventReader = $CrashEventReader }
    return @(& $script:StagedTests -Manifest (Join-Path $Dir 'tests.json') @seam 6>$null) | Select-Object -Last 1
}

# Sets -Name to -Value on the first entry of the tests.json Invoke-FakeSuite wrote, and returns that manifest's path.
function script:Set-FakeSuiteField([string]$Dir, [string]$Name, $Value) {
    $manifest = Join-Path $Dir 'tests.json'
    $entries = @(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)
    $entries[0] | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    ConvertTo-Json -InputObject $entries -Depth 4 | Set-Content -LiteralPath $manifest -Encoding utf8
    return $manifest
}

# One fake -Test with -Name set to -Value on its tests.json entry: every line the runner printed, its verdict last.
function script:Invoke-FakeSuiteField {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][object]$Test, [Parameter(Mandatory)][string]$Name, $Value)
    $null = Invoke-FakeSuite -Dir $Dir -Tests @($Test)
    $manifest = Set-FakeSuiteField -Dir $Dir -Name $Name -Value $Value
    return @(& $script:StagedTests -Manifest $manifest 6>&1 | ForEach-Object { "$_" })
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
            $crash = { param($Reader, $Code, $Wait = 0) Invoke-FakeSuite -Dir $d -CrashEventReader $Reader -CrashEventWaitSeconds $Wait -Tests @(New-FakeTest 'headless' 'cargo' $Code 'running 39 tests') }
            Assert-Throws { & $crash { param($Since) throw 'no event log here' } -1073741819 } `
                -MessagePattern "headless\.cmd: no libtest 'test result:' line in its output; exit -1073741819 \(0xC0000005 STATUS_ACCESS_VIOLATION\)$"
            # Event 1000's data in its own order; its Message is localized, so the script never reads it.
            $record = { param($App, $Module) [pscustomobject]@{ Properties = @($App, '1.0', 'aad2c1f4', $Module, '10.0', 'aad2c1f4', 'c0000409', '00000000000012ab' |
                        ForEach-Object { [pscustomobject]@{ Value = $_ } }) } }
            $wer = { param($Since) & $record 'other.exe' 'wrong.dll'; & $record 'HEADLESS.cmd' 'd3d12warp.dll' }.GetNewClosure()
            Assert-Throws { & $crash $wer -1073740791 } `
                -MessagePattern '0xC0000409 STATUS_STACK_BUFFER_OVERRUN \(a fail-fast abort\)\); WER: faulting module d3d12warp\.dll at offset 0x00000000000012ab, exception 0xc0000409$'
            # A record WER writes late is still read: the runner looks again each second until the wait runs out.
            $looks = @{ n = 0 }
            $late = { param($Since) $looks.n++; if ($looks.n -gt 1) { & $record 'headless.cmd' 'd3d10warp.dll' } }.GetNewClosure()
            Assert-Throws { & $crash $late -1073740791 3 } -MessagePattern 'WER: faulting module d3d10warp\.dll at offset 0x00000000000012ab, exception 0xc0000409$'
            Assert-Equal 2 $looks.n 'the second look found it and the search stopped'
            $looks.n = 0
            $never = { param($Since) $looks.n++; throw 'No events were found that match the specified selection criteria.' }.GetNewClosure()
            Assert-Throws { & $crash $never -1073740791 1 } -MessagePattern '\(0xC0000409 STATUS_STACK_BUFFER_OVERRUN \(a fail-fast abort\)\)$'
            Assert-Equal 2 $looks.n 'a wait of one second looks twice, then names the exit code alone'
        }
    }

    It 'moves self-skipped tests from passed to skipped by skip_pattern, never below zero' {
        Invoke-InTestDir { param($d)
            $lines = 'SKIP: no GPU adapter available in this environment', 'SKIP: no GPU adapter available in this environment', 'test result: ok. 5 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out'
            $out = Invoke-FakeSuiteField -Dir $d -Test (New-FakeTest 'renderer' 'cargo' 0 @($lines)) -Name skip_pattern -Value '^SKIP: no GPU adapter'
            Assert-Equal 'TESTS: passed=3 failed=0 skipped=3' $out[-1] 'two self-skips plus the ignored one'
        }
    }

    # AccelerANTgine's WebRTC test added on 2026-11-13 has never run on Windows; an unlisted skip names such a test.
    It 'holds a gtest entry''s skips to its exact allowed_skips: an unlisted skip, or a listed test that ran or is gone, fails' {
        Invoke-InTestDir { param($d)
            $engine = New-FakeTest 'engine_test' 'gtest' 0 @(
                '[ RUN      ] A.One', '[       OK ] A.One (0 ms)', '[ RUN      ] A.Two', '[  SKIPPED ] A.Two (0 ms)',
                '[ RUN      ] A.Three', '[  SKIPPED ] A.Three (1 ms)', '[ RUN      ] A.Four', '[       OK ] A.Four (2 ms)',
                '[  PASSED  ] 2 tests.', '[  SKIPPED ] 2 tests, listed below:', '[  SKIPPED ] A.Two', '[  SKIPPED ] A.Three')
            $run = { param([string[]]$Allowed) Invoke-FakeSuiteField -Name allowed_skips -Value @($Allowed) -Dir $d -Test $engine }
            Assert-Equal 'TESTS: passed=2 failed=0 skipped=2' (& $run @('A.Two', 'A.Three'))[-1] 'the exact list passes'
            $off = & $run @('A.Two', 'A.Four', 'A.Gone')
            Assert-Equal 'TESTS: passed=1 failed=3 skipped=1' $off[-1] 'an unlisted skip, a listed pass and a listed name that never ran'
            foreach ($named in 'skipped, not on allowed_skips: A.Three', 'on allowed_skips, but it passed: A.Four', 'on allowed_skips, but it did not run: A.Gone') {
                Assert-Equal 1 @($off | Where-Object { $_.EndsWith($named) }).Count "names: $named"
            }
            Assert-Equal 'TESTS: passed=2 failed=2 skipped=0' (& $run @())[-1] 'an empty list refuses every skip'
        }
    }

    It 'refuses allowed_skips on a cargo, pytest or exitcode entry, before it runs the binary' {
        Invoke-InTestDir { param($d)
            $crate = New-FakeTest 'crate' 'cargo' 0 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'
            Assert-Throws { Invoke-FakeSuiteField -Dir $d -Test $crate -Name allowed_skips -Value @() } -MessagePattern '^crate\.cmd: allowed_skips lists gtest skips; a cargo entry cannot carry it$'
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
