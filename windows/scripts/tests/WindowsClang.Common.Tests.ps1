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
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Invoke-ClangTidyFixStep' {
    It 'tidies only the files the build compiled, and names what it skipped' {
      Mock -ModuleName WindowsClang.Common -CommandName Get-Command { return [pscustomobject]@{ Source = 'clang-tidy.exe' } }
      Mock -ModuleName WindowsClang.Common -CommandName Get-ProjectCppFiles { return @($script:built, $script:unbuilt) }
      Mock -ModuleName WindowsClang.Common -CommandName Write-BuildLog { }
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
}
