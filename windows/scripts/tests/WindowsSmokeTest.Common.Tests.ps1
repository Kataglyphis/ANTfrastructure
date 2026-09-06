#requires -Version 7.0
# Tests for the smoke-test assertion harness, extracted from
# Test-Container.ps1 on 2026-08-08.
#
# The extraction's one real hazard is scope: Assert-Test used to read
# $ExitOnFirstFailure and $script:passed out of the CALLING SCRIPT's scope
# through PowerShell's dynamic scoping, and a module cannot see either. Both
# failure modes are silent -- the switch would simply stop working, and the
# summary would report 0/0 and exit 0 on a run that failed. Hence the pointed
# tests below.

$modulePath = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'modules\WindowsSmokeTest.Common.psm1'
Import-Module $modulePath -Force

Describe 'Smoke harness counters' {

    It 'Initialize-SmokeTestRun zeroes every counter' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'seed' -Condition { $true }
        Initialize-SmokeTestRun
        $s = Get-SmokeTestSummary
        Assert-Equal 0 $s.Passed  'passed reset'
        Assert-Equal 0 $s.Failed  'failed reset'
        Assert-Equal 0 $s.Skipped 'skipped reset'
        Assert-Equal 0 $s.Total   'total reset'
        Assert-False $s.Aborted   'abort flag reset'
    }

    It 'counts a passing, a failing and a skipped assertion into the summary' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'true'  -Condition { $true }
        Assert-Test -Name 'false' -Condition { $false } -FailMessage 'deliberate'
        Skip-Test 'deliberate skip'
        $s = Get-SmokeTestSummary
        Assert-Equal 1 $s.Passed  'one pass'
        Assert-Equal 1 $s.Failed  'one fail'
        Assert-Equal 1 $s.Skipped 'one skip'
        Assert-Equal 3 $s.Total   'total is the sum'
    }

    It 'records the failure message in FailureDetails' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'named' -Condition { $false } -FailMessage 'because reasons'
        $s = Get-SmokeTestSummary
        Assert-Equal 1 @($s.FailureDetails).Count 'one detail recorded'
        Assert-Match 'named.*because reasons' $s.FailureDetails[0] 'name and message both kept'
    }

    It 'treats a throwing condition as a failure, not a crash' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'throws' -Condition { throw 'boom' }
        $s = Get-SmokeTestSummary
        Assert-Equal 1 $s.Failed 'exception counted as failure'
        Assert-Match 'boom' $s.FailureDetails[0] 'exception message surfaced'
    }
}

Describe '-ExitOnFirstFailure across the module boundary' {
    # THE regression this extraction could have introduced. Before the move the
    # switch was a parameter of the calling script that Assert-Test happened to
    # see via dynamic scoping; inside a module that lookup finds nothing, and a
    # $null test is falsy -- so the abort would simply never fire and nothing
    # would report that it had stopped working.

    It 'aborts at the first failure and short-circuits later assertions' {
        Initialize-SmokeTestRun -ExitOnFirstFailure
        Assert-Test -Name 'ok'    -Condition { $true }
        Assert-Test -Name 'boom'  -Condition { $false } -FailMessage 'first failure'
        Assert-Test -Name 'later' -Condition { $true }
        Skip-Test 'later skip'
        $s = Get-SmokeTestSummary
        Assert-True  $s.Aborted 'abort flag set'
        Assert-Equal 1 $s.Passed  'the assertion AFTER the failure did not run'
        Assert-Equal 1 $s.Failed  'exactly the one failure'
        Assert-Equal 0 $s.Skipped 'the skip after the failure did not count either'
    }

    It 'keeps running after a failure when the switch is absent (default)' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'boom'  -Condition { $false } -FailMessage 'first failure'
        Assert-Test -Name 'later' -Condition { $true }
        $s = Get-SmokeTestSummary
        Assert-False $s.Aborted  'no abort'
        Assert-Equal 1 $s.Passed 'later assertion still ran'
    }

    It 'does not leak the switch into the next run' {
        Initialize-SmokeTestRun -ExitOnFirstFailure
        Assert-Test -Name 'boom' -Condition { $false }
        Initialize-SmokeTestRun          # no switch this time
        Assert-Test -Name 'boom2' -Condition { $false }
        Assert-Test -Name 'after' -Condition { $true }
        $s = Get-SmokeTestSummary
        Assert-False $s.Aborted  'module state reset with the run'
        Assert-Equal 1 $s.Passed 'run continued'
    }
}

Describe 'Path and command assertions' {

    It 'Assert-FileExists / Assert-DirectoryExists distinguish files from directories' {
        Invoke-InTestDir { param($dir)
            $file = Join-Path $dir 'a.txt'
            Set-Content $file 'x' -Encoding ASCII
            Initialize-SmokeTestRun
            Assert-FileExists      -Path $file -Description 'file as file'
            Assert-DirectoryExists -Path $dir  -Description 'dir as dir'
            Assert-FileExists      -Path $dir  -Description 'dir as file (must fail)'
            $s = Get-SmokeTestSummary
            Assert-Equal 2 $s.Passed 'file and dir both found'
            Assert-Equal 1 $s.Failed 'a directory does not satisfy -PathType Leaf'
        }
    }

    It 'Assert-CommandExists queries the NAME, not the test title' {
        # Regression from the original harness: Assert-Test's own $Name parameter
        # shadowed this one under dynamic scoping, so it used to look up a command
        # literally called "Command 'git' on PATH" and always failed. The fix is
        # the .GetNewClosure() capture, which must survive the move into a module.
        Initialize-SmokeTestRun
        Assert-CommandExists -Name 'Get-ChildItem'
        Assert-CommandExists -Name 'definitely-not-a-real-command-xyzzy'
        $s = Get-SmokeTestSummary
        Assert-Equal 1 $s.Passed 'the real command resolved'
        Assert-Equal 1 $s.Failed 'the bogus one did not'
    }

    It 'Assert-ArtifactPresent counts recursively, and -Informational downgrades a miss to a skip' {
        Invoke-InTestDir { param($dir)
            $sub = Join-Path $dir 'nested'
            New-Item -ItemType Directory -Path $sub | Out-Null
            Set-Content (Join-Path $sub 'x.dll') 'x' -Encoding ASCII
            Initialize-SmokeTestRun
            Assert-ArtifactPresent -Root $dir -Filter '*.dll' -Description 'nested dll found'
            Assert-ArtifactPresent -Root $dir -Filter '*.nope' -Description 'absent, informational' -Informational
            Assert-ArtifactPresent -Root $dir -Filter '*.nope' -Description 'absent, mandatory'
            $s = Get-SmokeTestSummary
            Assert-Equal 1 $s.Passed  'recursive match counted'
            Assert-Equal 1 $s.Skipped 'informational miss is a skip'
            Assert-Equal 1 $s.Failed  'mandatory miss is a failure'
        }
    }

    It 'Assert-EnvVarSet checks the variable, and honours an expected prefix' {
        Invoke-WithEnv @{ SMOKE_HARNESS_PROBE = 'C:\some\path' } {
            Initialize-SmokeTestRun
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE' -ExpectedPrefix 'C:\some'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE' -ExpectedPrefix 'D:\other'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_ABSENT'
            $s = Get-SmokeTestSummary
            Assert-Equal 2 $s.Passed 'set, and matching prefix'
            Assert-Equal 2 $s.Failed 'wrong prefix, and unset'
        }
    }
}
