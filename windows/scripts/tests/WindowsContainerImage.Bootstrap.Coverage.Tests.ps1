#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: installer imports and Dockerfile mounts; the bootstrap harness suite checks those.

Describe 'WindowsContainerImage.Bootstrap command coverage' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsContainerImage.Bootstrap.psm1'
    Import-Module $modulePath -Force -DisableNameChecking
    $script:root = New-TestDir -Prefix 'containerimage-bootstrap-'
    $moduleDir = New-Item -ItemType Directory -Path (Join-Path $script:root 'modules') -Force
    $script:requiredPath = Join-Path $moduleDir 'WindowsContainerImage.Common.psm1'
    [IO.File]::WriteAllText($script:requiredPath, '')
  }

  AfterAll {
    Remove-TestDir -Path $script:root
  }

  Context 'Resolve-ContainerImageModulePath' {
    It 'returns the existing required module path' {
      Resolve-ContainerImageModulePath -ModuleRoot $script:root | Should -Be $script:requiredPath
    }

    It 'returns null for an absent optional module' {
      $missing = Resolve-ContainerImageModulePath -ModuleRoot $script:root -Name 'Missing.Common.psm1' -Optional
      ($null -eq $missing) | Should -BeTrue
    }

    It 'throws for an absent required module' {
      { Resolve-ContainerImageModulePath -ModuleRoot $script:root -Name 'Missing.Common.psm1' } |
        Should -Throw '*Required module not found*'
    }
  }
}
