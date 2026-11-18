#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

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
      $build = Join-Path $script:buildRoot 'cpack-logs'
      $nsis = Join-Path $build '_CPack_Packages\win64\NSIS'
      New-Item -ItemType Directory -Path $nsis -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $nsis 'NSISOutput.log') -Value @('line 1', 'Error: path too long', 'line 3')
      $lines = @(Get-CPackLogLines $build)
      ($lines -join "`n") | Should -Match 'NSISOutput\.log'
      $lines | Should -Contain 'Error: path too long'
      $lines | Should -Contain 'line 3'
      $lines | Should -Not -Contain 'line 1'
    }

    It 'says so when the build has no _CPack_Packages directory' {
      $build = Join-Path $script:buildRoot 'cpack-none'
      New-Item -ItemType Directory -Path $build -Force | Out-Null
      (@(Get-CPackLogLines $build) -join "`n") | Should -Match 'does not exist'
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
