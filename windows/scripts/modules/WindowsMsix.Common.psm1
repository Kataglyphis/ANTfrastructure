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

function Get-PackageVersion {
  <#
    .SYNOPSIS
      The version to stamp a package with, read from the workspace.
    .DESCRIPTION
      Three consumers each parsed a version file inline and each got a different
      answer out of the same input: one produced "0.0.1.0" unconditionally, one
      read version.txt and did not pad it to the four components an AppxManifest
      requires (makeappx rejects three), and one read it twice in the same script
      with two different fallbacks. This is that parse, once.

      VERSION.txt is the family's name for it (adopting-in-a-new-project.md, S 8);
      version.txt is accepted because that is what two Rust consumers actually
      have on disk. Missing, empty or unparseable falls back to -Default rather
      than throwing: a packaging step is not the right place to discover that a
      repo has no version file, and the fallback is visible in the package name.
    .PARAMETER Components
      How many dot-separated components the result must have; 4 for an
      AppxManifest, which rejects fewer. Extra components are dropped, missing
      ones are zero-filled.
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

  # A leading v, a -rc1 suffix, a trailing newline: all common in a version
  # file, none of them legal in an AppxManifest version attribute.
  $digits = [regex]::Match($text, '[0-9]+(\.[0-9]+)*')
  if (-not $digits.Success) { $digits = [regex]::Match($Default, '[0-9]+(\.[0-9]+)*') }
  $parts = @($digits.Value.Split('.'))
  while ($parts.Count -lt $Components) { $parts += '0' }
  return ($parts[0..($Components - 1)] -join '.')
}

function Invoke-MsixPackage {
  <#
    .SYNOPSIS
      Stage, manifest, pack and (optionally) sign one MSIX.
    .DESCRIPTION
      The orchestration three consumers had each written out: resolve makeappx,
      lay out the assets, expand the manifest template, pack, check, sign. What
      differs between them is STAGING -- one runs `cmake --install`, one copies
      an exe and its dlls, one lets cargo build into place -- so staging stays
      with the caller and everything after it lives here.

      The caller passes a -StagingDir that already holds what goes in the
      package; this adds the assets and the manifest, packs, and asserts the
      output EXISTS. That last check is not defensive noise: makeappx has been
      seen to report success and produce no file, and without the assertion the
      lane goes green and the artifact upload finds nothing.
    .PARAMETER TokenMap
      __TOKEN__ -> value for the AppxManifest template. Values are XML-escaped
      by Expand-XmlTemplateTokens; a hand-rolled .Replace chain was not.
    .PARAMETER GenerateTransparentLogos
      Write placeholder PNGs instead of copying -LogoPath. A package without the
      four logo assets fails to install with an error that names none of them.
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
    # Optional invoker for testability, exactly as Invoke-MsixSign takes one:
    # Invoke-BuildExternal lives in WindowsBuild.Common, which this module does
    # not import, so a test cannot mock it here -- and packing for real needs a
    # Windows SDK no runner has.
    [scriptblock]$InvokerScriptBlock
  )

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

  # The four names an AppxManifest references by convention. All four, always:
  # a package missing one installs with an error that names none of them.
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

  $outDir = Split-Path -Parent $OutputPath
  if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

  $packArgs = @('pack', '/d', $StagingDir, '/p', $OutputPath, '/o')
  if ($InvokerScriptBlock) {
    & $InvokerScriptBlock $makeappx $packArgs | Out-Null
  } else {
    Invoke-BuildExternal -Context $Context -File $makeappx -Parameters $packArgs | Out-Null
  }

  # makeappx reported success but produced no file: seen, and a lane that does
  # not check here goes green while the artifact upload finds nothing.
  if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "makeappx reported success but produced no package at $OutputPath"
  }

  if ($Sign) {
    if (-not (Get-Command -Name 'Invoke-MsixSign' -ErrorAction SilentlyContinue)) {
      throw '-Sign needs WindowsMsix.Signing; import it before calling this.'
    }
    Invoke-MsixSign -Context $Context -WorkspacePath (Split-Path -Parent $StagingDir) -MsixOutPath $OutputPath
  }

  return $OutputPath
}

# Approved-verb wrappers to improve discoverability while preserving existing function names.
function Get-WindowsSdkToolPath { param($ToolName,$OverridePath) return Resolve-WindowsSdkToolPath -ToolName $ToolName -OverridePath $OverridePath }

function ConvertTo-XmlSafeText { param($Text) return ConvertTo-XmlEscapedText -Value $Text }

function New-TransparentImage { param($Path,$Width,$Height) return New-TransparentPng -Path $Path -Width $Width -Height $Height }

Export-ModuleMember -Function Resolve-WindowsSdkToolPath, Expand-XmlTemplateTokens, New-TransparentPng, Get-WindowsSdkToolPath, ConvertTo-XmlSafeText, New-TransparentImage, Get-PackageVersion, Invoke-MsixPackage
