#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsConfig.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsConfig.Common.psm1'
    Import-Module $modulePath -Force

    function Invoke-WorkspaceConfigFixture {
      param([scriptblock]$Body, [string]$OverrideConfig = '', [hashtable]$Environment = @{})
      $files = @{ 'default.psd1' = "@{ Build = @{ WorkspaceRootEnv = 'ANT_CFG_ROOT_A' }; Marker = 'default' }" }
      if ($OverrideConfig) { $files['override.psd1'] = $OverrideConfig }
      Invoke-InTestDir -Files $files -Body { param($dir)
        $vars = @{ BUILD_WINDOWS_CONFIG = $null; WORKSPACE_ROOT_ENV = $null; ANT_CFG_ROOT_A = 'C:\from-config' }
        if ($OverrideConfig) { $vars.BUILD_WINDOWS_CONFIG = Join-Path $dir 'override.psd1' }
        foreach ($name in $Environment.Keys) { $vars[$name] = $Environment[$name] }
        Invoke-WithEnv $vars { & $Body $dir }
      }
    }

    function Assert-WorkspaceConfig {
      param([string]$DefaultConfigPath, [string]$ExpectedConfigPath, [string]$Marker, [string]$WorkspaceRoot)
      $result = Get-BuildWorkspaceConfig -DefaultConfigPath $DefaultConfigPath -RepoRoot 'C:\fallback'
      $result.ConfigPath | Should -Be $ExpectedConfigPath
      $result.Config.Marker | Should -Be $Marker
      $result.WorkspaceRoot | Should -Be $WorkspaceRoot
    }
  }

  Context 'Get-ConfigValue' {
    It 'returns the nested value when the path exists' {
      $cfg = @{ Build = @{ WorkspaceRootEnv = 'WORKSPACE' } }
      Get-ConfigValue -Config $cfg -Path 'Build.WorkspaceRootEnv' | Should -Be 'WORKSPACE'
    }

    It 'returns $null for a missing path' {
      $cfg = @{ A = @{ B = 1 } }
      Get-ConfigValue -Config $cfg -Path 'A.C' | Should -BeNullOrEmpty
    }
  }

  # This fixture does not execute either consumer's full build.
  Context 'Get-BuildWorkspaceConfig' {
    It 'reads the default config and its configured workspace environment variable' {
      Invoke-WorkspaceConfigFixture -Body { param($dir)
        $path = Join-Path $dir 'default.psd1'
        Assert-WorkspaceConfig -DefaultConfigPath $path -ExpectedConfigPath $path -Marker 'default' -WorkspaceRoot 'C:\from-config'
      }
    }

    It 'lets the config path and workspace variable name override the defaults' {
      Invoke-WorkspaceConfigFixture -OverrideConfig "@{ Build = @{ WorkspaceRootEnv = 'ANT_CFG_ROOT_B' }; Marker = 'override' }" `
        -Environment @{ WORKSPACE_ROOT_ENV = 'ANT_CFG_ROOT_C'; ANT_CFG_ROOT_B = 'C:\from-file'; ANT_CFG_ROOT_C = 'D:\from-override' } `
        -Body { param($dir)
        $path = Join-Path $dir 'override.psd1'
        Assert-WorkspaceConfig -DefaultConfigPath (Join-Path $dir 'default.psd1') -ExpectedConfigPath $path `
          -Marker 'override' -WorkspaceRoot 'D:\from-override'
      }
    }

    It 'uses the repo root when the selected variable is empty' {
      Invoke-InTestDir -Files @{ 'default.psd1' = "@{ Build = @{ WorkspaceRootEnv = 'ANT_CFG_ROOT_A' } }" } -Body { param($dir)
        Invoke-WithEnv @{ BUILD_WINDOWS_CONFIG = $null; WORKSPACE_ROOT_ENV = '  '; ANT_CFG_ROOT_A = '  ' } {
          $result = Get-BuildWorkspaceConfig -DefaultConfigPath (Join-Path $dir 'default.psd1') -RepoRoot 'C:\fallback'
          $result.WorkspaceRoot | Should -Be 'C:\fallback'
        }
      }
    }

    It 'fails loudly for a missing or malformed config file' {
      Invoke-InTestDir -Files @{ 'malformed.psd1' = '@{ Build = ' } -Body { param($dir)
        Invoke-WithEnv @{ BUILD_WINDOWS_CONFIG = $null } {
          Assert-Throws -MessagePattern 'Build config not found:' -Body {
            Get-BuildWorkspaceConfig -DefaultConfigPath (Join-Path $dir 'missing.psd1') -RepoRoot $dir
          }
          Assert-Throws -Body {
            Get-BuildWorkspaceConfig -DefaultConfigPath (Join-Path $dir 'malformed.psd1') -RepoRoot $dir
          }
        }
      }
    }

    It 'detects removal of the workspace variable override' {
      Invoke-InTestDir -Files @{ 'default.psd1' = "@{ Build = @{ WorkspaceRootEnv = 'ANT_CFG_ROOT_A' } }" } -Body { param($dir)
        $path = Join-Path $dir 'default.psd1'
        Invoke-WithEnv @{ BUILD_WINDOWS_CONFIG = $null; WORKSPACE_ROOT_ENV = 'ANT_CFG_ROOT_C'; ANT_CFG_ROOT_A = 'C:\from-file'; ANT_CFG_ROOT_C = 'D:\from-override' } {
          Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsConfig.Common.psm1' -FunctionName Get-BuildWorkspaceConfig `
            -Find '$env:WORKSPACE_ROOT_ENV' -Replace '$null' -BodyArgumentList @($path) -Body { param($configPath)
              Assert-Throws -Body {
                (Get-MutBuildWorkspaceConfig -DefaultConfigPath $configPath -RepoRoot 'C:\fallback').WorkspaceRoot | Should -Be 'D:\from-override'
              }
            }
        }
      }
    }
  }

  Context 'Get-SelectedConfigurations' {
    It 'expands "all" into every available configuration' {
      $set = Get-SelectedConfigurations -Configurations @('all') -AvailableConfigurations @('a', 'b', 'c')

      $set.Contains('a') | Should -BeTrue
      $set.Contains('b') | Should -BeTrue
      $set.Contains('c') | Should -BeTrue
    }

    It 'parses comma-separated values and normalizes case and whitespace' {
      $set = Get-SelectedConfigurations -Configurations @('MSVC-DEBUG, clangcl-release') `
        -AvailableConfigurations @('msvc-debug', 'clangcl-release')

      $set.Contains('msvc-debug') | Should -BeTrue
      $set.Contains('clangcl-release') | Should -BeTrue
    }

    It 'throws on an unknown configuration' {
      Assert-Throws -MessagePattern "Unknown configuration 'unknown'" -Body {
        Get-SelectedConfigurations -Configurations @('unknown') -AvailableConfigurations @('x')
      }
    }

    It 'returns the set itself for a single selection, and the cleared set selects nothing' {
      $set = Get-SelectedConfigurations -Configurations @('clangcl-debug') -AvailableConfigurations @('clangcl-debug', 'msvc-debug')

      $set.GetType().Name | Should -Be 'HashSet`1'
      $set.Clear()
      Test-ConfigurationSelected -Name 'clangcl-debug' -SelectedConfigurations $set | Should -BeFalse
    }
  }

  Context 'Get-BuildConfigurationRow' {
    BeforeAll {
      $script:cfg = @{ Build = @{ Configurations = @{
            'clangcl-release' = @{ BuildDir = 'build-rel'; BuildDirEnv = 'H4B_TEST_BUILD_DIR'; Preset = 'x64-Rel'; PresetEnv = 'H4B_TEST_PRESET'; Configuration = 'Release' }
            'bare' = @{ BuildDir = 'build-bare'; Preset = 'x64-Bare'; Configuration = 'Debug' } } } }
    }

    It 'returns the row with each *Env variable overriding its field when set' {
      $env:H4B_TEST_BUILD_DIR = $null; $env:H4B_TEST_PRESET = $null
      $row = Get-BuildConfigurationRow -Config $script:cfg -Name 'clangcl-release'
      "$($row.Name)|$($row.BuildDir)|$($row.Preset)|$($row.Configuration)" | Should -Be 'clangcl-release|build-rel|x64-Rel|Release'
      $env:H4B_TEST_BUILD_DIR = 'D:\elsewhere'; $env:H4B_TEST_PRESET = 'x64-Other'
      try {
        $row = Get-BuildConfigurationRow -Config $script:cfg -Name 'clangcl-release'
        "$($row.BuildDir)|$($row.Preset)|$($row.Row['BuildDir'])" | Should -Be 'D:\elsewhere|x64-Other|build-rel'
        (Get-BuildConfigurationRow -Config $script:cfg -Name 'bare').BuildDir | Should -Be 'build-bare'
      } finally {
        $env:H4B_TEST_BUILD_DIR = $null; $env:H4B_TEST_PRESET = $null
      }
    }

    It 'throws for a configuration the file does not define, naming the file' {
      Assert-Throws -MessagePattern ([regex]::Escape("Unknown build configuration 'nope' in C:\x\Build-Windows.config.psd1.")) -Body {
        Get-BuildConfigurationRow -Config $script:cfg -Name 'nope' -ConfigPath 'C:\x\Build-Windows.config.psd1'
      }
    }
  }
}
