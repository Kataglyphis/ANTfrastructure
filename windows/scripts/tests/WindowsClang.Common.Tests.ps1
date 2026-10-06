#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsClang.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsClang.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('clang-common-' + (Get-Random))) -Force).FullName
    $script:ws = Join-Path $script:root 'ws'
    $script:buildRoot = Join-Path $script:root 'build'
    $null = New-Item -ItemType Directory -Path (Join-Path $script:ws 'Src\Playground') -Force
    $null = New-Item -ItemType Directory -Path $script:buildRoot -Force

    $script:built = Join-Path $script:ws 'Src\built.cpp'
    $script:unbuilt = Join-Path $script:ws 'Src\Playground\unbuilt.cpp'
    Set-Content -LiteralPath $script:built -Value 'int main() { return 0; }'
    Set-Content -LiteralPath $script:unbuilt -Value '#include "kompute/Algorithm.hpp"'

    $db = @(@{ file = $script:built; command = 'clang-cl /c built.cpp'; directory = $script:buildRoot })
    ConvertTo-Json -InputObject $db -AsArray | Set-Content -LiteralPath (Join-Path $script:buildRoot 'compile_commands.json')

    # The step's collaborators, stubbed: which clang-tidy it finds and which files the project lists vary per test.
    function Set-TidyStub([string]$Tidy, [string[]]$Files) {
      $script:stubTidy = $Tidy
      $script:stubFiles = $Files
      Mock -ModuleName WindowsClang.Common -CommandName Get-Command { return [pscustomobject]@{ Source = $script:stubTidy } }
      Mock -ModuleName WindowsClang.Common -CommandName Get-ProjectCppFiles { return $script:stubFiles }
      Mock -ModuleName WindowsClang.Common -CommandName Write-BuildLog { }
    }
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Invoke-ClangTidyFixStep' {
    It 'tidies only the files the build compiled, and names what it skipped' {
      Set-TidyStub -Tidy 'clang-tidy.exe' -Files @($script:built, $script:unbuilt)
      Mock -ModuleName WindowsClang.Common -CommandName Invoke-BuildExternal { }

      Invoke-ClangTidyFixStep -Context ([pscustomobject]@{ }) -WorkspacePath $script:ws -BuildRoot $script:buildRoot

      $expected = $script:built
      Should -Invoke Invoke-BuildExternal -ModuleName WindowsClang.Common -Times 1 -Exactly -ParameterFilter {
        $File -eq 'clang-tidy.exe' -and @($Parameters) -contains $expected
      }
      Should -Invoke Write-BuildLog -ModuleName WindowsClang.Common -ParameterFilter {
        $Message -like '*1 file(s)*no compile command*'
      }
    }
  }

  Context 'Invoke-ClangTidyFixStep in parallel' {
    BeforeAll {
      $script:pws = Join-Path $script:root 'pws'
      $script:pbuild = Join-Path $script:root 'pbuild'
      $null = New-Item -ItemType Directory -Path (Join-Path $script:pws 'Src'), $script:pbuild -Force
      $script:good = Join-Path $script:pws 'Src\good.cpp'
      $script:bad = Join-Path $script:pws 'Src\bad.cpp'
      foreach ($file in $script:good, $script:bad) { Set-Content -LiteralPath $file -Value 'int f() { return 0; }' }
      $pdb = @($script:good, $script:bad | ForEach-Object { @{ file = $_; command = 'clang-cl /c x.cpp'; directory = $script:pbuild } })
      $pdb | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $script:pbuild 'compile_commands.json')
      # A clang-tidy that reports on every file and fails bad.cpp.
      $script:fakeTidy = Join-Path $script:root 'fake-tidy.cmd'
      Set-Content -LiteralPath $script:fakeTidy -Value @(
        '@echo off'
        'echo tidied %*'
        'echo %* | findstr /c:"bad.cpp" >nul && exit /b 3'
        'exit /b 0'
      )
    }

    BeforeEach {
      Set-TidyStub -Tidy $script:fakeTidy -Files @($script:good, $script:bad)
    }

    It 'tidies every file, logs each one''s output and names exactly the file that failed' {
      $thrown = $null
      try {
        Invoke-ClangTidyFixStep -Context ([pscustomobject]@{ }) -WorkspacePath $script:pws -BuildRoot $script:pbuild -ThrottleLimit 2
      } catch { $thrown = $_.Exception.Message }

      $thrown | Should -BeLike '*1 file(s)*bad.cpp (exit 3)*'
      $thrown | Should -Not -BeLike '*good.cpp (exit*'
      $goodFile = $script:good
      Should -Invoke Write-BuildLog -ModuleName WindowsClang.Common -ParameterFilter {
        $Message -like 'tidied *' -and $Message -like "*$goodFile*"
      }
    }

    It 'keeps -Fix serial, since two files'' fixes can rewrite one header' {
      Mock -ModuleName WindowsClang.Common -CommandName Invoke-BuildExternal { }

      Invoke-ClangTidyFixStep -Context ([pscustomobject]@{ }) -WorkspacePath $script:pws -BuildRoot $script:pbuild -ThrottleLimit 8 -Fix

      Should -Invoke Invoke-BuildExternal -ModuleName WindowsClang.Common -Times 2 -Exactly -ParameterFilter {
        @($Parameters) -contains '--fix'
      }
    }
  }
}
