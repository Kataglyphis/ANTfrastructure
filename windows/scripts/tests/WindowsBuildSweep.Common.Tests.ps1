# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The failure-aggregation cases use `cmd /c exit N` rather than a mock, because
# the bug this module exists to prevent is specifically about $LASTEXITCODE from
# a NATIVE command - a PowerShell-only fake would never reproduce it.

Describe 'WindowsBuildSweep.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsBuildSweep.Common.psm1'
    Import-Module $modulePath -Force
  }

  Context 'Invoke-SweepStep' {
    It 'reports success for a step that completes cleanly' {
      $r = Invoke-SweepStep -Name 'ok' -Action { 'work' | Out-Null }

      $r.Ok | Should -BeTrue
      $r.Skipped | Should -BeFalse
      $r.ExitCode | Should -Be 0
    }

    It 'reports failure on a non-zero exit code from a native command' {
      $r = Invoke-SweepStep -Name 'native-fail' -Action { & cmd /c exit 3 }

      $r.Ok | Should -BeFalse
      $r.ExitCode | Should -Be 3
    }

    It 'reports failure on a thrown exception without rethrowing it' {
      # The whole point: the sweep must survive so later steps still run.
      $r = Invoke-SweepStep -Name 'throwing' -Action { throw 'boom' }

      $r.Ok | Should -BeFalse
      $r.Message | Should -Match 'boom'
    }

    It 'does not inherit a stale exit code from an earlier native command' {
      & cmd /c exit 9
      $r = Invoke-SweepStep -Name 'clean-after-stale' -Action { 'work' | Out-Null }

      $r.Ok | Should -BeTrue
      $r.ExitCode | Should -Be 0
    }

    It 'does not run the action when skipped' {
      $script:ran = $false
      $r = Invoke-SweepStep -Name 'skipped' -Skip -SkipReason 'no runtime' -Action { $script:ran = $true }

      $script:ran | Should -BeFalse
      $r.Skipped | Should -BeTrue
      $r.Ok | Should -BeTrue
    }
  }

  Context 'Write-SweepSummary' {
    It 'returns 0 when every step passed' {
      $results = @(
        [pscustomobject]@{ Name = 'a'; Ok = $true; Skipped = $false; ExitCode = 0; Message = '' }
        [pscustomobject]@{ Name = 'b'; Ok = $true; Skipped = $true; ExitCode = 0; Message = 'skipped' }
      )

      Write-SweepSummary -Result $results | Should -Be 0
    }

    It 'returns the first non-zero exit code rather than a synthesised 1' {
      $results = @(
        [pscustomobject]@{ Name = 'a'; Ok = $true; Skipped = $false; ExitCode = 0; Message = '' }
        [pscustomobject]@{ Name = 'b'; Ok = $false; Skipped = $false; ExitCode = 7; Message = 'exit code 7' }
        [pscustomobject]@{ Name = 'c'; Ok = $false; Skipped = $false; ExitCode = 5; Message = 'exit code 5' }
      )

      Write-SweepSummary -Result $results | Should -Be 7
    }

    It 'returns 1 when a step failed by throwing with no exit code' {
      $results = @(
        [pscustomobject]@{ Name = 'a'; Ok = $false; Skipped = $false; ExitCode = 0; Message = 'boom' }
      )

      Write-SweepSummary -Result $results | Should -Be 1
    }

    It 'accepts an empty result set' {
      Write-SweepSummary -Result @() | Should -Be 0
    }
  }

  Context 'Test-LinuxContainerSupport' {
    It 'returns $false when the docker executable is missing' {
      Test-LinuxContainerSupport -DockerExe 'docker-that-does-not-exist' | Should -BeFalse
    }
  }
}
