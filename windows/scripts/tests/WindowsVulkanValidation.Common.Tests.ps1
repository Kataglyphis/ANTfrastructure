# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Covers the pure parts of WindowsVulkanValidation.Common: the log scan, the
# hazard report, and the vk_layer_settings.txt staging/cleanup contract. The
# executable-running part needs a GPU and a Vulkan SDK, so it is exercised by
# the consuming project's wrapper instead.

Describe 'WindowsVulkanValidation.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsVulkanValidation.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('vkvalidation-' + (Get-Random))) -Force).FullName

    $script:hazardLog = Join-Path $script:root 'hazard.log'
    Set-Content -Path $script:hazardLog -Value @(
      '[ RUN      ] GoldenRender.ShadowsDarkenSomePixels'
      'VALIDATION - SYNC-HAZARD-WRITE_AFTER_WRITE(ERROR): image barrier missing'
      '[       OK ] GoldenRender.ShadowsDarkenSomePixels'
    )

    $script:cleanLog = Join-Path $script:root 'clean.log'
    Set-Content -Path $script:cleanLog -Value @(
      '[ RUN      ] GoldenRender.ShadowsDarkenSomePixels'
      '[       OK ] GoldenRender.ShadowsDarkenSomePixels'
    )
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Get-VulkanValidationHazard' {
    It 'returns the SYNC-HAZARD lines of a hazardous log' {
      $hazards = @(Get-VulkanValidationHazard -LogPath $script:hazardLog)
      $hazards.Count | Should -Be 1
      $hazards[0].Line | Should -Match 'SYNC-HAZARD-WRITE_AFTER_WRITE'
    }

    It 'returns nothing for a clean log' {
      @(Get-VulkanValidationHazard -LogPath $script:cleanLog).Count | Should -Be 0
    }

    It 'honours a custom pattern list' {
      @(Get-VulkanValidationHazard -LogPath $script:cleanLog -Pattern @('GoldenRender')).Count | Should -Be 2
    }

    It 'throws when the log does not exist' {
      $threw = $false
      try { Get-VulkanValidationHazard -LogPath (Join-Path $script:root 'nope.log') } catch { $threw = $true }
      $threw | Should -Be $true
    }
  }

  Context 'Test-VulkanValidationLog' {
    It 'is false for a hazardous log' {
      (Test-VulkanValidationLog -LogPath $script:hazardLog) | Should -Be $false
    }

    It 'is true for a clean log' {
      (Test-VulkanValidationLog -LogPath $script:cleanLog -Quiet) | Should -Be $true
    }
  }

  Context 'vk_layer_settings staging' {
    It 'ships a default settings file that enables sync validation' {
      $default = Get-VulkanLayerSettingsDefaultPath
      Test-Path $default | Should -Be $true
      (Get-Content $default -Raw) | Should -Match 'khronos_validation\.validate_sync\s*=\s*true'
    }

    It 'stages the settings file next to the executable and removes it again' {
      $exeDir = (New-Item -ItemType Directory -Path (Join-Path $script:root ('stage-' + (Get-Random))) -Force).FullName
      $staging = Copy-VulkanLayerSettings -SettingsPath (Get-VulkanLayerSettingsDefaultPath) -TargetDirectory $exeDir
      $staged = Join-Path $exeDir 'vk_layer_settings.txt'

      Test-Path $staged | Should -Be $true
      $staging.StagedPath | Should -Be $staged
      ($null -eq $staging.BackupPath) | Should -Be $true

      Restore-VulkanLayerSettings -Staging $staging
      Test-Path $staged | Should -Be $false
    }

    It 'backs up and restores a pre-existing vk_layer_settings.txt' {
      $exeDir = (New-Item -ItemType Directory -Path (Join-Path $script:root ('stage-' + (Get-Random))) -Force).FullName
      $staged = Join-Path $exeDir 'vk_layer_settings.txt'
      Set-Content -Path $staged -Value 'khronos_validation.validate_core = true' -NoNewline

      $staging = Copy-VulkanLayerSettings -SettingsPath (Get-VulkanLayerSettingsDefaultPath) -TargetDirectory $exeDir
      ($null -ne $staging.BackupPath) | Should -Be $true
      (Get-Content $staged -Raw) | Should -Match 'validate_sync'

      Restore-VulkanLayerSettings -Staging $staging
      Test-Path $staged | Should -Be $true
      (Get-Content $staged -Raw) | Should -Be 'khronos_validation.validate_core = true'
      Test-Path $staging.BackupPath | Should -Be $false
    }

    It 'ignores a null staging handle so finally blocks are safe' {
      { Restore-VulkanLayerSettings -Staging $null } | Should -Not -Throw
    }

    It 'throws when the settings source does not exist' {
      $threw = $false
      try {
        Copy-VulkanLayerSettings -SettingsPath (Join-Path $script:root 'missing.txt') -TargetDirectory $script:root
      } catch { $threw = $true }
      $threw | Should -Be $true
    }
  }
}
