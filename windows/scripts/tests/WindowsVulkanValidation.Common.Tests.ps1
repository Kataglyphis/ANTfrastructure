#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Running the executable needs a GPU and a Vulkan SDK, so the consuming project's wrapper covers it.

Describe 'WindowsVulkanValidation.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsVulkanValidation.Common.psm1'
    Import-Module $modulePath -Force

    function Invoke-VulkanSettingsFixture {
      param([Collections.IDictionary]$Files = @{}, [scriptblock]$WhileStaged, [scriptblock]$AfterRestore)
      $inspectStaged = $WhileStaged; $inspectRestored = $AfterRestore
      $copy = Get-Command Copy-VulkanLayerSettings
      $restore = Get-Command Restore-VulkanLayerSettings
      $source = Get-VulkanLayerSettingsDefaultPath
      Invoke-InTestDir -Files $Files -Body { param($dir)
        $path = Join-Path $dir 'vk_layer_settings.txt'
        $staging = & $copy -SettingsPath $source -TargetDirectory $dir
        try { & $inspectStaged $path $staging }
        finally { & $restore -Staging $staging }
        & $inspectRestored $path $staging
      }.GetNewClosure()
    }

    $script:root = New-TestDir -Prefix 'vkvalidation-'

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
    Remove-TestDir -Path $script:root
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

    It 'prints the hazard header and the matching line' {
      $report = @(Test-VulkanValidationLog -LogPath $script:hazardLog 6>&1 | ForEach-Object { $_.ToString() }) -join "`n"
      $report | Should -Match 'SYNCHRONIZATION HAZARDS DETECTED \(1\)'
      $report | Should -Match 'VALIDATION - SYNC-HAZARD-WRITE_AFTER_WRITE'
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
      Invoke-VulkanSettingsFixture -WhileStaged { param($staged, $staging)
        Test-Path $staged | Should -Be $true
        $staging.StagedPath | Should -Be $staged
        ($null -eq $staging.BackupPath) | Should -Be $true
      } -AfterRestore { param($staged)
        Test-Path $staged | Should -Be $false
      }
    }

    It 'backs up and restores a pre-existing vk_layer_settings.txt' {
      Invoke-VulkanSettingsFixture -Files @{ 'vk_layer_settings.txt' = 'khronos_validation.validate_core = true' } -WhileStaged { param($staged, $staging)
        ($null -ne $staging.BackupPath) | Should -Be $true
        (Get-Content $staged -Raw) | Should -Match 'validate_sync'
      } -AfterRestore { param($staged, $staging)
        Test-Path $staged | Should -Be $true
        (Get-Content $staged -Raw) | Should -Be 'khronos_validation.validate_core = true'
        Test-Path $staging.BackupPath | Should -Be $false
      }
    }

    It 'unwinds the staged settings when an inspecting assertion fails, with a fault control' {
      $prelude = @'
function Get-VulkanLayerSettingsDefaultPath { 'fixture settings' }
function Copy-VulkanLayerSettings { param($SettingsPath, $TargetDirectory); $State.Calls.Add('copy'); [pscustomobject]@{ StagedPath = (Join-Path $TargetDirectory 'vk_layer_settings.txt') } }
function Restore-VulkanLayerSettings { param($Staging); $State.Calls.Add('restore') }
'@
      $module = @{ ScriptPath = 'windows/scripts/tests/WindowsVulkanValidation.Common.Tests.ps1'; FunctionName = 'Invoke-VulkanSettingsFixture'
        Prelude = $prelude; FixtureState = (New-TestCallState @{ After = $false }) }
      Invoke-TestFunctionMutations -ModuleArguments $module -Find 'finally { & $restore -Staging $staging }' -Replace 'finally { }' `
        -Expected 'a failed inspection must restore settings' -IncludeControl -Body { param($state)
          $state.Calls.Clear(); $state.After = $false
          Assert-Throws {
            Invoke-MutVulkanSettingsFixture -WhileStaged { throw 'settings inspection sentinel' } -AfterRestore { $state.After = $true }
          } -MessagePattern 'settings inspection sentinel'
          Assert-Equal 'copy|restore' ($state.Calls -join '|') 'a failed inspection must restore settings'
          Assert-False $state.After 'a failed inspection must not run the after-restore verdict'
        }
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
