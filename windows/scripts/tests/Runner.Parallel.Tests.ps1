#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Invoke-Tests.ps1 and Invoke-Lint.ps1 work side by side and report what they report in turn (CON126).

# <dir> <suites>: a copy of the runner beside stub modules and the real fan-out, with the given suites.
function New-RunnerCopy {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][hashtable]$Suites)
    $tests = Join-Path $Dir 'scripts\tests'
    $mods = Join-Path $Dir 'scripts\modules'
    New-Item -ItemType Directory -Force $tests, $mods | Out-Null
    $src = Join-Path (Get-RepoRoot) 'windows\scripts'
    Copy-Item (Join-Path $src 'tests\Invoke-Tests.ps1'), (Join-Path $src 'tests\TestHarness.psm1') $tests
    $runner = [IO.File]::ReadAllText((Join-Path $tests 'Invoke-Tests.ps1'))
    foreach ($m in [regex]::Matches($runner, "Join-Path \`$modDir '([^']+)'")) { Set-Content (Join-Path $mods $m.Groups[1].Value) '' }
    Copy-Item (Join-Path $src 'modules\WindowsFanOut.Common.psm1') $mods -Force
    foreach ($name in $Suites.Keys) { Set-Content (Join-Path $tests $name) $Suites[$name] }
    return $tests
}

# <tests dir> <jobs>: the runner's output, its exit code and its seconds.
function Invoke-RunnerCopy {
    param([Parameter(Mandatory)][string]$Tests, [Parameter(Mandatory)][int]$Jobs)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $Tests 'Invoke-Tests.ps1') -Jobs $Jobs 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Out = $out; Text = ($out -join "`n"); Exit = $LASTEXITCODE; Seconds = $sw.Elapsed.TotalSeconds }
}

Describe 'Invoke-Tests.ps1: each file in its own pwsh, the same tallies as in turn' {
    Invoke-InTestDir { param($d)
        $tests = New-RunnerCopy -Dir (Join-Path $d 'green') -Suites @{
            'A.Tests.ps1' = "Describe 'a' { It 'one' { Start-Sleep 4; Assert-True `$true }; It 'two' { Assert-True `$true } }"
            'B.Tests.ps1' = "Describe 'b' { It 'red' { Start-Sleep 4; throw 'deliberate' } }"
            'C.Tests.ps1' = "Describe 'c' { It 'three' { Start-Sleep 4; Assert-True `$true } }"
        }
        $serial = Invoke-RunnerCopy -Tests $tests -Jobs 1
        $parallel = Invoke-RunnerCopy -Tests $tests -Jobs 3
        $tally = { param($r) @($r.Out | Where-Object { $_ -match '^ \d+ tests \|' }) -join '' }
        $dead = Invoke-RunnerCopy -Jobs 2 -Tests (New-RunnerCopy -Dir (Join-Path $d 'dead') -Suites @{
                'A.Tests.ps1' = "Describe 'a' { It 'one' { Assert-True `$true } }"
                'D.Tests.ps1' = "Describe 'd' { It 'dies' { [Environment]::Exit(9) } }"
            })

        It 'counts and names the same tests either way' {
            Assert-Equal ' 4 tests | 3 passed | 1 failed' (& $tally $serial) 'in turn'
            Assert-Equal (& $tally $serial) (& $tally $parallel) 'side by side'
            Assert-True ($parallel.Text -match 'FAIL \[b\] red') 'the red test is named'
            Assert-Equal $serial.Exit $parallel.Exit 'the same verdict'
        }

        It 'runs the files at once, and says so' {
            Assert-True ($parallel.Seconds -le $serial.Seconds - 4) "in turn $($serial.Seconds) s, side by side $($parallel.Seconds) s"
            Assert-True ($parallel.Text -match 'Invoke-Tests: 3 files, 3 at a time') $parallel.Text
        }

        It 'keeps the floor on the sum' {
            Assert-True ($parallel.Text -match 'FLOOR: only 4 test\(s\) ran') 'four tests are far below it'
        }

        It 'names a suite that kills its pwsh as unfinished and fails the run, never green' {
            Assert-True ($dead.Text -match 'did not finish: D\.Tests\.ps1') ($dead.Out -join ' | ')
            Assert-Equal 1 $dead.Exit 'red'
        }
    }
}

Describe 'Invoke-Lint.ps1: the analyzer side by side finds what it finds in turn' {
    Invoke-InTestDir { param($d)
        Set-Content (Join-Path $d 'a.ps1') 'gci .'
        Set-Content (Join-Path $d 'b.ps1') "ConvertTo-SecureString 'p' -AsPlainText -Force"
        Set-Content (Join-Path $d 'c.ps1') 'Get-Date'
        $lint = Join-Path (Get-RepoRoot) 'windows\scripts\Invoke-Lint.ps1'
        $serial = @(& pwsh -NoProfile -NonInteractive -File $lint -Path $d -Jobs 1 2>&1 | ForEach-Object { "$_" })
        $parallel = @(& pwsh -NoProfile -NonInteractive -File $lint -Path $d -Jobs 3 2>&1 | ForEach-Object { "$_" })
        $pssa = { param($o) @($o | Where-Object { $_ -match '^PSSA: ' }) -join '' }

        It 'reports the same findings' {
            Assert-True ((& $pssa $serial) -match '^PSSA: 1 error\(s\), 1 warning\(s\)') "in turn: $(& $pssa $serial)"
            Assert-Equal (& $pssa $serial) (& $pssa $parallel) 'side by side'
            Assert-True (($parallel -join "`n") -match 'PSAvoidUsingConvertToSecureStringWithPlainText') 'the finding itself crosses back from the child'
        }
    }
}
