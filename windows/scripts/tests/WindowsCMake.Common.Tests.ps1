#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsCMake.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsCMake.Common.psm1'
    Import-Module $modulePath -Force

    $script:buildRoot = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('cmake-common-' + (Get-Random))) -Force).FullName
  }

  AfterAll {
    Remove-Item -LiteralPath $script:buildRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Get-CompileCommandsDatabase' {
    It 'throws when neither compile_commands.json nor build.ninja exists' {
      # An unscoped mock never reaches Test-Path inside the module, so the test would hit the real filesystem.
      Mock -ModuleName WindowsCMake.Common -CommandName Test-Path { return $false }

      { Get-CompileCommandsDatabase -Context ([pscustomobject]@{ }) -BuildRoot $script:buildRoot } |
        Should -Throw -ExpectedMessage '*compile_commands.json not found*'
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

  Context 'Get-SanitizerRuntimeDlls' {
    It 'stages the runtime Get-AsanRuntimeDirs selects, not clang-cl-on-PATH' {
      # Sanitizers.cmake links Microsoft's ASan runtime; staging LLVM's DLL fails every tool with STATUS_ENTRYPOINT_NOT_FOUND.
      $fakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kataglyphis-asan-fake-" + $PID)
      $null = New-Item -ItemType Directory -Path $fakeDir -Force
      $fakeDll = Join-Path $fakeDir 'clang_rt.asan_dynamic-x86_64.dll'
      Set-Content -Path $fakeDll -Value 'x'

      try {
        InModuleScope WindowsCMake.Common {
          $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("kataglyphis-asan-fake-" + $PID)
          Mock Get-AsanRuntimeDirs { @($dir) }

          $result = @(Get-SanitizerRuntimeDlls)
          $result.Count | Should -Be 1
          $result[0].FullName | Should -Be (Join-Path $dir 'clang_rt.asan_dynamic-x86_64.dll')
        }
      } finally {
        Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
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
