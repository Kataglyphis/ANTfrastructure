Set-StrictMode -Version Latest
#requires -Version 7.0


# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
# No -Force when already loaded: a nested force-reimport moves the module's
# exports out of the global session state on Windows PowerShell 5.1.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

function Resolve-WindowsSdkToolPath {
  param(
    [Parameter(Mandatory)]
    [string]$ToolName,
    [AllowNull()]
    [string]$OverridePath
  )

  if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
    if (Test-Path $OverridePath) {
      return (Resolve-Path $OverridePath).Path
    }

    throw "Configured SDK tool path does not exist for '$ToolName': $OverridePath"
  }

  $onPath = Get-Command $ToolName -ErrorAction SilentlyContinue
  if ($onPath) {
    return $onPath.Source
  }

  $candidateDirs = @()

  foreach ($envVar in @('WindowsSdkVerBinPath', 'WindowsSdkBinPath')) {
    $entry = Get-Item -Path "Env:$envVar" -ErrorAction SilentlyContinue
    if ($entry -and -not [string]::IsNullOrWhiteSpace($entry.Value)) {
      $candidateDirs += $entry.Value
      $candidateDirs += (Join-Path $entry.Value 'x64')
    }
  }

  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  if (Test-Path $kitsRoot) {
    $sdkVersion = $null
    $versionEntry = Get-Item -Path 'Env:WindowsSDKVersion' -ErrorAction SilentlyContinue
    if ($versionEntry -and -not [string]::IsNullOrWhiteSpace($versionEntry.Value)) {
      $sdkVersion = $versionEntry.Value.TrimEnd('\\')
    }

    if (-not [string]::IsNullOrWhiteSpace($sdkVersion)) {
      $candidateDirs += (Join-Path $kitsRoot $sdkVersion)
      $candidateDirs += (Join-Path (Join-Path $kitsRoot $sdkVersion) 'x64')
    }

    $versionDirs = Get-ChildItem -Path $kitsRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending
    foreach ($versionDir in $versionDirs) {
      $candidateDirs += $versionDir.FullName
      $candidateDirs += (Join-Path $versionDir.FullName 'x64')
    }
  }

  foreach ($dir in ($candidateDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    $candidate = Join-Path $dir $ToolName
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

function ConvertTo-XmlEscapedText {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) { return '' }
  return [System.Security.SecurityElement]::Escape($Value)
}

function Expand-XmlTemplateTokens {
  param(
    [Parameter(Mandatory)]
    [string]$Template,
    [Parameter(Mandatory)]
    [hashtable]$TokenMap
  )

  $expanded = $Template
  foreach ($token in $TokenMap.Keys) {
    # Ordinal [string].Replace, NOT -replace: -replace treats the token as a
    # regex and the value as a substitution template, so a value containing
    # '$&' or '$1' (or a token containing regex metacharacters) would corrupt
    # the output. Behavior is identical for the plain __TOKEN__ inputs used today.
    $expanded = $expanded.Replace([string]$token, (ConvertTo-XmlEscapedText ([string]$TokenMap[$token])))
  }

  return $expanded
}

function New-TransparentPng {
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [int]$Width,
    [Parameter(Mandatory)]
    [int]$Height
  )

  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $gfx.Clear([System.Drawing.Color]::Transparent)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $gfx.Dispose()
    $bmp.Dispose()
  }
}

# Approved-verb wrappers to improve discoverability while preserving existing function names.
function Get-WindowsSdkToolPath { param($ToolName,$OverridePath) return Resolve-WindowsSdkToolPath -ToolName $ToolName -OverridePath $OverridePath }

function ConvertTo-XmlSafeText { param($Text) return ConvertTo-XmlEscapedText -Value $Text }

function New-TransparentImage { param($Path,$Width,$Height) return New-TransparentPng -Path $Path -Width $Width -Height $Height }

Export-ModuleMember -Function Resolve-WindowsSdkToolPath, Expand-XmlTemplateTokens, New-TransparentPng, Get-WindowsSdkToolPath, ConvertTo-XmlSafeText, New-TransparentImage
