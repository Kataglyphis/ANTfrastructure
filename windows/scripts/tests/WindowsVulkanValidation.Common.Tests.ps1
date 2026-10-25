#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: GPU-backed Vulkan execution and SDK validation; the consuming wrapper runs those.

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

    function Assert-VulkanChildResult {
      param([string]$LogPath, [int]$ExitCode, [string]$Marker)
      $global:LASTEXITCODE | Should -Be $ExitCode
      (Get-Content -LiteralPath $LogPath -Raw) | Should -Match ([regex]::Escape($Marker))
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

  Context 'validation command lifecycle' {
    It 'stages settings for the child and restores them after a nonzero exit' {
      $settings = Join-Path $script:root 'vk_layer_settings.txt'
      $tool = New-TestBatchTool -Directory $script:root -Name 'vulkan-sync-probe.cmd' -Line @(
        "if exist `"$settings`" echo SETTINGS_PRESENT",
        'echo ARG=%1'
      ) -ExitCode 7
      $log = Join-Path $script:root 'run.log'

      Invoke-VulkanValidationRun -ExecutablePath $tool -Arguments @('hello') -WorkingDirectory $script:root -LogPath $log

      Assert-VulkanChildResult -LogPath $log -ExitCode 7 -Marker 'SETTINGS_PRESENT'
      (Get-Content -LiteralPath $log -Raw) | Should -Match 'ARG=hello'
      Test-Path -LiteralPath $settings | Should -BeFalse
    }

    It 'rejects a missing executable before it can stage settings' {
      $missing = Join-Path $script:root 'missing.exe'
      $log = Join-Path $script:root 'missing.log'

      { Invoke-VulkanValidationRun -ExecutablePath $missing -WorkingDirectory $script:root -LogPath $log } |
        Should -Throw '*Executable not found*'
      Test-Path -LiteralPath (Join-Path $script:root 'vk_layer_settings.txt') | Should -BeFalse
    }

    It 'restores a caller Vulkan layer path after the child exits' {
      $tool = New-TestBatchTool -Directory $script:root -Name 'vulkan-layer-probe.cmd' -Line 'echo LAYER=%VK_LAYER_PATH%'
      $log = Join-Path $script:root 'layer.log'

      Invoke-WithEnv @{ VK_LAYER_PATH = 'caller-layer' } {
        Invoke-VulkanValidationRun -ExecutablePath $tool -WorkingDirectory $script:root -LogPath $log -LayerPath $script:root
        $env:VK_LAYER_PATH | Should -Be 'caller-layer'
      }
      (Get-Content -LiteralPath $log -Raw) | Should -Match ([regex]::Escape("LAYER=$script:root"))
    }

    It 'captures a bounded child exit and cleans its redirected files' {
      $tool = New-TestBatchTool -Directory $script:root -Name 'vulkan-timed-probe.cmd' -Line 'echo TIMED_RUN' -ExitCode 9
      $log = Join-Path $script:root 'timed.log'

      Invoke-VulkanValidationRun -ExecutablePath $tool -WorkingDirectory $script:root -LogPath $log -TimeoutSeconds 5

      Assert-VulkanChildResult -LogPath $log -ExitCode 9 -Marker 'TIMED_RUN'
      Test-Path -LiteralPath "$log.stdout.tmp" | Should -BeFalse
      Test-Path -LiteralPath "$log.stderr.tmp" | Should -BeFalse
    }
  }
}
