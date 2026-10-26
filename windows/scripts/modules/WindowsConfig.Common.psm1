Set-StrictMode -Version Latest
#requires -Version 7.0


function Get-OrDefault([string]$Value, [string]$DefaultValue) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $DefaultValue }
  return $Value
}

function Get-ConfigValue {
  param(
    [Parameter(Mandatory)]
    $Config,
    [Parameter(Mandatory)]
    [string]$Path
  )

  $cursor = $Config
  foreach ($segment in ($Path -split '\.')) {
    if ($null -eq $cursor) { return $null }
    try {
      $cursor = $cursor[$segment]
    } catch {
      return $null
    }
  }

  return $cursor
}

function Get-BuildWorkspaceConfig {
  param(
    [Parameter(Mandatory)][string]$DefaultConfigPath,
    [Parameter(Mandatory)][string]$RepoRoot
  )

  $configPath = Get-OrDefault $env:BUILD_WINDOWS_CONFIG $DefaultConfigPath
  if (-not (Test-Path $configPath)) { throw "Build config not found: $configPath" }
  $config = Import-PowerShellDataFile -Path $configPath
  $workspaceRootEnvVar = Get-OrDefault $env:WORKSPACE_ROOT_ENV (Get-ConfigValue -Config $config -Path 'Build.WorkspaceRootEnv')
  $workspaceEnvItem = Get-Item -Path "Env:$workspaceRootEnvVar" -ErrorAction SilentlyContinue
  $workspaceRootFromEnv = if ($null -ne $workspaceEnvItem) { $workspaceEnvItem.Value } else { $null }

  return [pscustomobject]@{
    ConfigPath = $configPath
    Config = $config
    WorkspaceRoot = Get-OrDefault $workspaceRootFromEnv $RepoRoot
  }
}

function Get-SelectedConfigurations {
  param(
    [string[]]$Configurations,
    [string[]]$AvailableConfigurations
  )

  $selectedConfigurations = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  if ($null -eq $Configurations -or $Configurations.Count -eq 0 -or ($Configurations -contains 'all')) {
    foreach ($configurationName in $AvailableConfigurations) {
      $selectedConfigurations.Add($configurationName) | Out-Null
    }
  } else {
    foreach ($item in $Configurations) {
      if ([string]::IsNullOrWhiteSpace($item)) { continue }
      foreach ($configurationName in $item -split ',') {
        if ([string]::IsNullOrWhiteSpace($configurationName)) { continue }
        $normalized = $configurationName.Trim().ToLowerInvariant()
        if (-not ($AvailableConfigurations -contains $normalized)) {
          throw "Unknown configuration '$configurationName'. Supported values: all, $($AvailableConfigurations -join ', ')"
        }
        $selectedConfigurations.Add($normalized) | Out-Null
      }
    }
  }

  # The comma keeps the set: unrolled, one selection came back a string and -SkipBuild's .Clear() threw.
  return , $selectedConfigurations
}

function Test-ConfigurationSelected {
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SelectedConfigurations)
  return $SelectedConfigurations.Contains($Name)
}

<#
.SYNOPSIS
  Build.Configurations.<Name> of a Build-Windows.config.psd1, with BuildDir and Preset taken from the row's
  BuildDirEnv / PresetEnv variables when those are set; throws for a name the config lacks.
.OUTPUTS
  [pscustomobject] Name, BuildDir, Preset, Configuration and Row (the row as written).
#>
function Get-BuildConfigurationRow {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Name,
    # Named in the error, so a typo says which file to look in.
    [string]$ConfigPath = ''
  )

  $row = Get-ConfigValue -Config $Config -Path "Build.Configurations.$Name"
  if ($null -eq $row) { throw "Unknown build configuration '$Name'$(if ($ConfigPath) { " in $ConfigPath" })." }
  $fromEnv = { param($Variable) if ($Variable) { [Environment]::GetEnvironmentVariable($Variable) } }
  return [pscustomobject]@{
    Name          = $Name
    BuildDir      = Get-OrDefault (& $fromEnv $row['BuildDirEnv']) $row['BuildDir']
    Preset        = Get-OrDefault (& $fromEnv $row['PresetEnv']) $row['Preset']
    Configuration = $row['Configuration']
    Row           = $row
  }
}

Export-ModuleMember -Function @(
  'Get-OrDefault',
  'Get-ConfigValue',
  'Get-BuildWorkspaceConfig',
  'Get-SelectedConfigurations',
  'Test-ConfigurationSelected',
  'Get-BuildConfigurationRow'
)
