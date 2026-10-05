Set-StrictMode -Version Latest
#requires -Version 7.0


# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
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
    # Ordinal .Replace, not -replace, which reads the token as a regex and '$1' in the value as a template.
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

function Get-PackageVersion {
  <#
    .SYNOPSIS
      The version to stamp a package with, read from the workspace.
    .DESCRIPTION
      VERSION.txt, or version.txt for the Rust consumers; missing or unparseable falls back to -Default, visibly.
    .PARAMETER Components
      Component count, 4 for an AppxManifest, which rejects fewer; extras dropped, missing ones zero-filled.
  #>
  param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [string]$Default = '0.0.1.0',
    [int]$Components = 4
  )

  $text = ''
  foreach ($name in @('VERSION.txt', 'version.txt')) {
    $candidate = Join-Path $WorkspacePath $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $text = (Get-Content -LiteralPath $candidate -Raw).Trim()
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($text)) { $text = $Default }

  # A leading v, a -rc1 suffix or a newline is common in a version file and illegal in an AppxManifest.
  $digits = [regex]::Match($text, '[0-9]+(\.[0-9]+)*')
  if (-not $digits.Success) { $digits = [regex]::Match($Default, '[0-9]+(\.[0-9]+)*') }
  $parts = @($digits.Value.Split('.'))
  while ($parts.Count -lt $Components) { $parts += '0' }
  return ($parts[0..($Components - 1)] -join '.')
}

# Runs one packager into a cleared -OutputPath; makeappx and wix can both exit 0 and write nothing.
function Invoke-PackagerTool {
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$File,
    [Parameter(Mandatory)] [string[]]$Parameters,
    [Parameter(Mandatory)] [string]$OutputPath,
    [scriptblock]$InvokerScriptBlock
  )

  $outDir = Split-Path -Parent $OutputPath
  if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
  if ($InvokerScriptBlock) {
    & $InvokerScriptBlock $File $Parameters | Out-Null
  } else {
    Invoke-BuildExternal -Context $Context -File $File -Parameters $Parameters | Out-Null
  }
  if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "$([System.IO.Path]::GetFileNameWithoutExtension($File)) reported success but produced no package at $OutputPath"
  }
}

function Invoke-MsixPackage {
  <#
    .SYNOPSIS
      Stage, manifest, pack and (optionally) sign one MSIX.
    .DESCRIPTION
      Staging stays with the caller; the output's existence is asserted, since makeappx can report success with no file.
    .PARAMETER TokenMap
      __TOKEN__ -> value for the AppxManifest template; values are XML-escaped.
    .PARAMETER GenerateTransparentLogos
      Write placeholder PNGs instead of copying -LogoPath; a missing logo fails the install without naming it.
    .PARAMETER SigningRoot
      Where -Sign looks for the *.pfx (non-recursive), normally the repository root; required with -Sign.
  #>
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$StagingDir,
    [Parameter(Mandatory)] [string]$ManifestTemplatePath,
    [Parameter(Mandatory)] [hashtable]$TokenMap,
    [Parameter(Mandatory)] [string]$OutputPath,
    [string]$ExePath = '',
    [string[]]$ExtraFiles = @(),
    [string]$ResourcesDir = '',
    [string]$LogoPath = '',
    [switch]$GenerateTransparentLogos,
    [string]$MakeAppxPath = '',
    [switch]$Sign,
    [string]$SigningRoot = '',
    # Test seam: this module does not import Invoke-BuildExternal, and real packing needs a Windows SDK.
    [scriptblock]$InvokerScriptBlock
  )

  # Before any work, so a missing parameter cannot leave a packed package silently unsigned.
  if ($Sign) {
    if ([string]::IsNullOrWhiteSpace($SigningRoot)) {
      throw '-Sign needs -SigningRoot: the directory holding the signing .pfx, normally the repository root.'
    }
    if (-not (Get-Command -Name 'Invoke-MsixSign' -ErrorAction SilentlyContinue)) {
      throw '-Sign needs WindowsMsix.Signing; import it before calling this.'
    }
  }

  $makeappx = Resolve-WindowsSdkToolPath -ToolName 'makeappx.exe' -OverridePath $MakeAppxPath
  if ([string]::IsNullOrWhiteSpace($makeappx)) {
    throw 'makeappx.exe not found. Install the Windows SDK, or pass -MakeAppxPath.'
  }
  if (-not (Test-Path -LiteralPath $ManifestTemplatePath -PathType Leaf)) {
    throw "Manifest template not found: $ManifestTemplatePath"
  }

  New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
  if ($ExePath) { Copy-Item -LiteralPath $ExePath -Destination $StagingDir -Force }
  foreach ($file in $ExtraFiles) {
    if ($file -and (Test-Path -LiteralPath $file)) {
      Copy-Item -LiteralPath $file -Destination $StagingDir -Force -Recurse
    }
  }
  if ($ResourcesDir -and (Test-Path -LiteralPath $ResourcesDir)) {
    Copy-Item -Path (Join-Path $ResourcesDir '*') -Destination $StagingDir -Force -Recurse
  }

  # All four conventional logo names, always: a missing one fails the install without naming it.
  $assetsDir = Join-Path $StagingDir 'Assets'
  New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
  $logos = @{ 'StoreLogo.png' = @(50, 50); 'Square44x44Logo.png' = @(44, 44)
              'Square150x150Logo.png' = @(150, 150); 'Wide310x150Logo.png' = @(310, 150) }
  foreach ($name in $logos.Keys) {
    $target = Join-Path $assetsDir $name
    if ($LogoPath -and -not $GenerateTransparentLogos -and (Test-Path -LiteralPath $LogoPath)) {
      Copy-Item -LiteralPath $LogoPath -Destination $target -Force
    } else {
      New-TransparentPng -Path $target -Width $logos[$name][0] -Height $logos[$name][1]
    }
  }

  $manifest = Expand-XmlTemplateTokens -Template (Get-Content -LiteralPath $ManifestTemplatePath -Raw) -TokenMap $TokenMap
  Set-Content -Path (Join-Path $StagingDir 'AppxManifest.xml') -Value $manifest -Encoding utf8

  $packArgs = @('pack', '/d', $StagingDir, '/p', $OutputPath, '/o')
  Invoke-PackagerTool -Context $Context -File $makeappx -Parameters $packArgs -OutputPath $OutputPath -InvokerScriptBlock $InvokerScriptBlock

  if ($Sign) {
    Invoke-MsixSign -Context $Context -WorkspacePath $SigningRoot -MsixOutPath $OutputPath
  }

  return $OutputPath
}

function Resolve-WixExe {
  <#
    .SYNOPSIS
      wix.exe (WiX v4 or later): -OverridePath, then $env:WIX, then PATH; $null when none has it.
  #>
  param(
    [AllowNull()]
    [string]$OverridePath
  )

  # $env:WIX is where the WiX installer and the image put it; only an explicit path outranks it.
  if ([string]::IsNullOrWhiteSpace($OverridePath) -and -not [string]::IsNullOrWhiteSpace($env:WIX)) {
    $candidate = Join-Path $env:WIX 'wix.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return Resolve-WindowsSdkToolPath -ToolName 'wix.exe' -OverridePath $OverridePath
}

function New-WixPayloadFragment {
  <#
    .SYNOPSIS
      Write a WiX fragment with one component per file, in ComponentGroup PayloadFiles under APPLICATIONFOLDER.
    .PARAMETER PayloadFiles
      Objects with Source and Subdirectory; an empty Subdirectory installs beside the exe.
  #>
  param(
    [Parameter(Mandatory)] [object[]]$PayloadFiles,
    [Parameter(Mandatory)] [string]$Path,
    [ValidateSet('x64', 'arm64', 'x86')] [string]$Arch = 'x64'
  )

  $bitness = if ($Arch -eq 'x86') { 'always32' } else { 'always64' }
  $components = for ($i = 0; $i -lt $PayloadFiles.Count; $i++) {
    $src = [System.Security.SecurityElement]::Escape([string]$PayloadFiles[$i].Source)
    $dir = [string]$PayloadFiles[$i].Subdirectory
    $sub = if ($dir) { " Subdirectory='$([System.Security.SecurityElement]::Escape($dir))'" } else { '' }
    "      <Component Id='payload$i' Bitness='$bitness'$sub><File Id='payloadFile$i' Source='$src' KeyPath='yes'/></Component>"
  }
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  @(
    "<Wix xmlns='http://wixtoolset.org/schemas/v4/wxs'><Fragment>"
    "    <ComponentGroup Id='PayloadFiles' Directory='APPLICATIONFOLDER'>"
    $components
    '    </ComponentGroup>'
    '</Fragment></Wix>'
  ) | Set-Content -LiteralPath $Path -Encoding utf8
  return $Path
}

function Invoke-MsiPackage {
  <#
    .SYNOPSIS
      Build one MSI from the project's own .wxs with wix build; the output's existence is asserted.
    .DESCRIPTION
      The .wxs takes every moving value as a preprocessor variable: Version, ExeSource, LicenseRtf,
      ProductName and Manufacturer, plus PayloadFiles=1 when -PayloadFiles is given.
    .PARAMETER PayloadFiles
      Objects with Source and Subdirectory, written to -FragmentPath by New-WixPayloadFragment.
  #>
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$WxsFile,
    [Parameter(Mandatory)] [string]$LicenseFile,
    [Parameter(Mandatory)] [string]$ProductName,
    [Parameter(Mandatory)] [string]$Manufacturer,
    [Parameter(Mandatory)] [string]$ExeSource,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$OutFile,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64', 'x86')] [string]$Arch,
    [object[]]$PayloadFiles = @(),
    [string]$FragmentPath = '',
    [string[]]$Extensions = @('WixToolset.UI.wixext'),
    [string]$WixPath = '',
    # Test seam, as in Invoke-MsixPackage: real builds need WiX.
    [scriptblock]$InvokerScriptBlock
  )

  $inputs = [ordered]@{ 'the .wxs' = $WxsFile; 'the license' = $LicenseFile; 'the exe' = $ExeSource }
  foreach ($name in $inputs.Keys) {
    if (-not (Test-Path -LiteralPath $inputs[$name] -PathType Leaf)) { throw "MSI input not found, ${name}: $($inputs[$name])" }
  }
  if ($PayloadFiles.Count -gt 0 -and [string]::IsNullOrWhiteSpace($FragmentPath)) {
    throw '-PayloadFiles needs -FragmentPath: where to write the generated component fragment.'
  }
  $wix = Resolve-WixExe -OverridePath $WixPath
  if (-not $wix) {
    throw "wix.exe (WiX v4 or later) not found under `$env:WIX ('$env:WIX') or on PATH; the Windows image installs it (Install-ScoopTools.ps1)."
  }

  $wixArgs = @('build', '-arch', $Arch)
  foreach ($ext in $Extensions) { $wixArgs += @('-ext', $ext) }
  $wixArgs += @(
    '-d', "Version=$Version", '-d', "ExeSource=$ExeSource", '-d', "LicenseRtf=$LicenseFile",
    '-d', "ProductName=$ProductName", '-d', "Manufacturer=$Manufacturer", '-out', $OutFile, $WxsFile)
  if ($PayloadFiles.Count -gt 0) {
    $wixArgs += @('-d', 'PayloadFiles=1', (New-WixPayloadFragment -PayloadFiles $PayloadFiles -Path $FragmentPath -Arch $Arch))
  }

  Invoke-PackagerTool -Context $Context -File $wix -Parameters $wixArgs -OutputPath $OutFile -InvokerScriptBlock $InvokerScriptBlock
  return $OutFile
}

# Approved-verb wrappers to improve discoverability while preserving existing function names.
function Get-WindowsSdkToolPath { param($ToolName,$OverridePath) return Resolve-WindowsSdkToolPath -ToolName $ToolName -OverridePath $OverridePath }

function ConvertTo-XmlSafeText { param($Text) return ConvertTo-XmlEscapedText -Value $Text }

function New-TransparentImage { param($Path,$Width,$Height) return New-TransparentPng -Path $Path -Width $Width -Height $Height }

Export-ModuleMember -Function Resolve-WindowsSdkToolPath, Expand-XmlTemplateTokens, New-TransparentPng, Get-WindowsSdkToolPath, ConvertTo-XmlSafeText, New-TransparentImage, Get-PackageVersion, Invoke-MsixPackage, Resolve-WixExe, New-WixPayloadFragment, Invoke-MsiPackage
