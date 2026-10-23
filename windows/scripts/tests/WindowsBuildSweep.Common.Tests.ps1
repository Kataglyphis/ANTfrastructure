#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# `cmd /c exit N`, not a mock: the bug is about a native command's $LASTEXITCODE, which a PowerShell fake never sets.

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
    It '<Name>' -ForEach @(
      @{ Name = 'returns 0 when every step passed'; Expected = 0; Result = @(
        [pscustomobject]@{ Name = 'a'; Ok = $true; Skipped = $false; ExitCode = 0; Message = '' }
        [pscustomobject]@{ Name = 'b'; Ok = $true; Skipped = $true; ExitCode = 0; Message = 'skipped' }
      ) }
      @{ Name = 'returns the first non-zero exit code rather than a synthesised 1'; Expected = 7; Result = @(
        [pscustomobject]@{ Name = 'a'; Ok = $true; Skipped = $false; ExitCode = 0; Message = '' }
        [pscustomobject]@{ Name = 'b'; Ok = $false; Skipped = $false; ExitCode = 7; Message = 'exit code 7' }
        [pscustomobject]@{ Name = 'c'; Ok = $false; Skipped = $false; ExitCode = 5; Message = 'exit code 5' }
      ) }
      @{ Name = 'returns 1 when a step failed by throwing with no exit code'; Expected = 1; Result = @(
        [pscustomobject]@{ Name = 'a'; Ok = $false; Skipped = $false; ExitCode = 0; Message = 'boom' }
      ) }
    ) {
      Write-SweepSummary -Result $Result | Should -Be $Expected
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

  Context 'Invoke-InLinuxContainerBuild' {
    # A fake engine that records its arguments, resolved by the tested code in a child scope; only the global scope survives it.
    function script:Invoke-WithFakeEngine {
        param([Parameter(Mandatory)][scriptblock]$Body, [switch]$AllCalls)
        $calls = [Collections.Generic.List[object]]::new()
        $definition = { $calls.Add(@($args)) }.GetNewClosure()
        $null = Invoke-WithTestFunction -Name FakeEngineRun -Definition $definition -Body $Body
        if ($AllCalls) { foreach ($call in $calls) { $call -join ' ' } }
        elseif ($calls.Count) { return $calls[-1] }
    }

    It 'hands bash LF-only lines when the command came from a CRLF file' {
      # A here-string in a CRLF-checked-out script keeps its CRs; bash then rejects `set -e<CR>`.
      $args_seen = Invoke-WithFakeEngine {
        Invoke-InLinuxContainerBuild -RepoRoot 'C:\repo' -Image 'img' -Command "echo a`r`necho b`r`n" -DockerExe 'FakeEngineRun'
      }
      $args_seen[-3..-1] -join '|' | Should -BeExactly "bash|-c|set -e`necho a`necho b`n"
    }

    function script:Get-FakeEngineCall {
        param([Parameter(Mandatory)][scriptblock]$Body)
        Invoke-WithFakeEngine -Body $Body -AllCalls
    }

    It 'chowns each named volume with the image it runs, on its platform, never a stock image' {
      $calls = @(Get-FakeEngineCall {
        Invoke-InLinuxContainerBuild -RepoRoot 'C:\repo' -Image 'img' -Command 'true' -DockerExe 'FakeEngineRun' -NamedVolumes 'cache:/cache' -Platform 'linux/arm64'
      })
      $calls.Count | Should -Be 3
      $calls[0] | Should -BeExactly 'volume create cache'
      $calls[1] | Should -BeExactly 'run --rm --user root --mount type=volume,source=cache,target=/v --platform linux/arm64 --entrypoint chown img -R 1001:1001 /v'
      $calls[2] | Should -BeLike 'run --rm --platform linux/arm64 -v C:\repo:/workspace -w /workspace --mount type=volume,source=cache,target=/cache img bash -c *'
      ($calls -join ' ') | Should -Not -Match 'alpine'
    }

    It 'passes -Privileged, -Device, -Env and -ExtraMount to the run' {
      $calls = @(Get-FakeEngineCall {
        Invoke-InLinuxContainerBuild -RepoRoot 'C:\repo' -Image 'img' -Command 'true' -DockerExe 'FakeEngineRun' -Privileged -Device '/dev/kvm' `
          -Env 'CI=true', 'A=b c' -ExtraMount 'type=bind,source=C:\k,target=/run/secrets/k,readonly'
      })
      $calls[-1] | Should -BeLike 'run --rm --privileged --device /dev/kvm --platform linux/amd64 -e CI=true -e A=b c -v C:\repo:/workspace -w /workspace --mount type=bind,source=C:\k,target=/run/secrets/k,readonly img bash -c *'
    }

    It 'finds nerdctl through Resolve-NerdctlExe when -Engine nerdctl names no -DockerExe' {
      Mock -ModuleName WindowsBuildSweep.Common -CommandName Resolve-NerdctlExe { 'FakeEngineRun' }
      $calls = @(Get-FakeEngineCall { Invoke-InLinuxContainerBuild -RepoRoot 'C:\repo' -Image 'img' -Command 'true' -Engine nerdctl })
      $calls.Count | Should -Be 1
      Should -Invoke Resolve-NerdctlExe -ModuleName WindowsBuildSweep.Common -Times 1 -Exactly
    }
  }
}
