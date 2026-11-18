#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Local compiler arguments and diagnostic files are fixtures; no package generator or native compiler runs here.

Describe 'WindowsCMake.Common' {
  BeforeAll {
    function Assert-CmakeBuildArgs {
      param([hashtable]$Options, [string]$Expected)
      InModuleScope WindowsCMake.Common -Parameters @{ Options = $Options; Expected = $Expected } {
        param($Options, $Expected)
        Mock Write-BuildLog {}
        $buildArgs = @(Get-CmakeBuildArgs @Options)
        ($buildArgs -join ' ') | Should -Be $Expected
      }
    }

    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsCMake.Common.psm1'
    Import-Module $modulePath -Force

    $script:buildRoot = New-TestDir -Prefix 'cmake-common-'
  }

  AfterAll {
    Remove-TestDir -Path $script:buildRoot
  }

  Context 'Write-CPackGeneratorLog' {
    BeforeAll {
      function New-CPackLogFixture {
        param([string]$Name, [hashtable]$Files)
        $build = Join-Path $script:buildRoot $Name
        Write-TestFileTree -Root $build -Files $Files
        return $build
      }

      # The lines the function logs for a build directory, both log writers captured.
      function script:Get-CPackLogLines([string]$Build) {
        InModuleScope WindowsCMake.Common -Parameters @{ Build = $Build } {
          param($Build)
          $script:cpackLines = [System.Collections.Generic.List[string]]::new()
          Mock Write-BuildLog { $script:cpackLines.Add($Message) }
          Mock Write-BuildLogMessages { foreach ($m in $Messages) { $script:cpackLines.Add($m) } }
          Write-CPackGeneratorLog -Context @{} -BuildPath $Build -TailLines 2
          $script:cpackLines
        }
      }
    }

    It 'prints the tail of every generator log under _CPack_Packages' {
      $build = New-CPackLogFixture -Name 'cpack-logs' -Files @{ '_CPack_Packages/win64/NSIS/NSISOutput.log' = "line 1`nError: path too long`nline 3`n" }
      $lines = @(Get-CPackLogLines $build)
      ($lines -join "`n") | Should -Match 'NSISOutput\.log'
      $lines | Should -Contain 'Error: path too long'
      $lines | Should -Contain 'line 3'
      $lines | Should -Not -Contain 'line 1'
    }

    It 'distinguishes missing and empty generator directories: <Name>' -TestCases @(
      @{ Name = 'cpack-none'; Files = @{ 'unrelated.txt' = 'outside the generator directory' }; Pattern = 'does not exist' },
      @{ Name = 'cpack-empty'; Files = @{ '_CPack_Packages/unrelated.txt' = 'not a generator log' }; Pattern = 'No CPack generator logs under ' }
    ) {
      param($Name, $Files, $Pattern)
      $build = New-CPackLogFixture -Name $Name -Files $Files
      (@(Get-CPackLogLines $build) -join "`n") | Should -Match $Pattern
    }

    It 'keeps deterministic generator log order and each separate tail' {
      $build = New-CPackLogFixture -Name 'cpack-ordered' -Files @{
        '_CPack_Packages/b.log' = "old-b`ntail-b1`ntail-b2`n"
        '_CPack_Packages/a.log' = "old-a`ntail-a1`ntail-a2`n"
        '_CPack_Packages/unrelated.txt' = 'not a generator log'
      }
      $lines = @(Get-CPackLogLines $build)
      $lines.Count | Should -Be 6
      $lines[0] | Should -Match 'a\.log'
      $lines[1] | Should -Be 'tail-a1'
      $lines[2] | Should -Be 'tail-a2'
      $lines[3] | Should -Match 'b\.log'
      $lines[4] | Should -Be 'tail-b1'
      $lines[5] | Should -Be 'tail-b2'
    }
  }

  Context 'Get-CompileCommandsDatabase' {
    It 'throws when neither compile_commands.json nor build.ninja exists' {
      # An unscoped mock never reaches Test-Path inside the module, so the test would hit the real filesystem.
      Mock -ModuleName WindowsCMake.Common -CommandName Test-Path { return $false }

      Assert-Throws -MessagePattern 'compile_commands\.json not found' -Body {
        Get-CompileCommandsDatabase -Context ([pscustomobject]@{ }) -BuildRoot $script:buildRoot
      }
    }

    It 'returns the existing compile_commands.json when present' {
      $compilePath = Join-Path $script:buildRoot 'compile_commands.json'
      Set-Content -Path $compilePath -Value '[{"file":"a.cpp"}]' -Encoding utf8

      Get-CompileCommandsDatabase -Context ([pscustomobject]@{ }) -BuildRoot $script:buildRoot |
        Should -Be $compilePath
    }
  }

  Context 'Get-CmakeConfigureArgs' {
    It 'passes the build path, the preset and the extra arguments in order' {
      $a = Get-CmakeConfigureArgs -BuildPath 'C:\b' -Preset 'clangcl-release' -ConfigureExtraArgs @('-DX=1')
      ($a -join ' ') | Should -Be '-B C:\b --preset clangcl-release -DX=1'
    }

    # A COMPILER_CACHE=sccache preset makes Cache.cmake set the launcher again, overriding the cleared env vars.
    It '-DisableSccache also clears the preset''s compiler cache and a cached launcher, after the extra args' {
      $a = Get-CmakeConfigureArgs -BuildPath 'C:\b' -Preset 'p' -ConfigureExtraArgs @('-DCOMPILER_CACHE=sccache') -DisableSccache
      ($a -join ' ') | Should -Be '-B C:\b --preset p -DCOMPILER_CACHE=sccache -DCOMPILER_CACHE= -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER='
    }

    It 'returns an array even without extra arguments' {
      $a = Get-CmakeConfigureArgs -BuildPath 'C:\b' -Preset 'p'
      $a.Count | Should -Be 4
    }
  }

  Context 'Get-CmakeBuildArgs' {
    It 'keeps build and package argument order, parallelism and verbosity (mutation)' {
      (Get-Command Get-CmakeBuildArgs -ErrorAction Stop).ModuleName | Should -Be 'WindowsCMake.Common'
      $cases = @(
        @{ Config = 'Debug'; Target = ''; Jobs = 3; Verbose = $true; Want = '--build C:\b --config Debug --parallel 3 --verbose' }
        @{ Config = 'Release'; Target = ''; Jobs = 0; Verbose = $false; Want = '--build C:\b --config Release --parallel' }
        @{ Config = 'Release'; Target = 'package'; Jobs = 3; Verbose = $false; Want = '--build C:\b --target package --config Release --parallel 3' }
        @{ Config = 'Release'; Target = 'package'; Jobs = 0; Verbose = $false; Want = '--build C:\b --target package --config Release --parallel' }
      )
      foreach ($case in $cases) {
        $options = @{ Context = [pscustomobject]@{}; BuildPath = 'C:\b'; Configuration = $case.Config
          Target = $case.Target; ParallelJobs = $case.Jobs; CpuCount = 8; VerboseOutput = $case.Verbose }
        Assert-CmakeBuildArgs -Options $options -Expected $case.Want
      }
    }
  }

  Context 'Get-SanitizerRuntimeDlls' {
    It 'stages the runtime Get-AsanRuntimeDirs selects, not clang-cl-on-PATH' {
      # Sanitizers.cmake links Microsoft's ASan runtime; staging LLVM's DLL fails every tool with STATUS_ENTRYPOINT_NOT_FOUND.
      $fakeDir = New-TestDir -Prefix 'kataglyphis-asan-fake-'
      $fakeDll = Join-Path $fakeDir 'clang_rt.asan_dynamic-x86_64.dll'
      Set-Content -Path $fakeDll -Value 'x'

      try {
        InModuleScope WindowsCMake.Common -Parameters @{ FixtureDir = $fakeDir } -ScriptBlock {
          param($FixtureDir)
          $script:asanFixtureDir = $FixtureDir
          try {
            Mock Get-AsanRuntimeDirs { @($script:asanFixtureDir) }

            $result = @(Get-SanitizerRuntimeDlls)
            $result.Count | Should -Be 1
            $result[0].FullName | Should -Be (Join-Path $FixtureDir 'clang_rt.asan_dynamic-x86_64.dll')
          } finally {
            Remove-Variable -Name asanFixtureDir -Scope Script -ErrorAction SilentlyContinue
          }
        }
      } finally {
        Remove-TestDir -Path $fakeDir
      }
    }

    It 'returns an empty array when no runtime directory is selected' {
      InModuleScope WindowsCMake.Common {
        Mock Get-AsanRuntimeDirs { @() }

        $result = @(Get-SanitizerRuntimeDlls)
        $result.Count | Should -Be 0
      }
    }
  }
}
