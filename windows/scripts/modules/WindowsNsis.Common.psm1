#requires -Version 7.0
Set-StrictMode -Version Latest

# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
foreach ($sibling in 'WindowsScripts.Shared', 'WindowsMsix.Common', 'WindowsMsix.Signing') {
  $siblingPath = Join-Path $PSScriptRoot "$sibling.psm1"
  if (-not (Test-Path -LiteralPath $siblingPath -PathType Leaf)) { throw "WindowsNsis.Common needs $sibling.psm1 beside it: $siblingPath" }
  if (-not (Get-Module -Name $sibling)) { Import-Module $siblingPath -ErrorAction Stop }
}

# makensis 3.13 is not long-path aware: a payload path at MAX_PATH fails the build.
$script:NsisMaxPath = 259
$script:NsisDefaultScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'nsis' 'setup.nsi'

function Resolve-MakensisExe {
  <#
    .SYNOPSIS
      makensis.exe from -OverridePath, then $env:NSISDIR, then PATH; anything but the pinned version fails.
  #>
  param(
    [AllowNull()] [string]$OverridePath,
    [string]$ExpectedVersion = $env:NSIS_VERSION,
    # Test seam: returns makensis /VERSION's output for a path.
    [scriptblock]$VersionProbe = { param($exe) (& $exe /VERSION | Out-String) }
  )
  if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    throw 'Resolve-MakensisExe needs -ExpectedVersion or NSIS_VERSION: GitHub runners carry their own NSIS, so the pin decides.'
  }
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
    if (-not (Test-Path -LiteralPath $OverridePath -PathType Leaf)) { throw "Configured makensis does not exist: $OverridePath" }
    $candidates = @($OverridePath)
  } else {
    if (-not [string]::IsNullOrWhiteSpace($env:NSISDIR)) {
      $candidates += @((Join-Path $env:NSISDIR 'Bin' 'makensis.exe'), (Join-Path $env:NSISDIR 'makensis.exe'))
    }
    $onPath = Get-Command 'makensis.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
  }
  $exe = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $exe) { throw "makensis.exe not found under NSISDIR ('$env:NSISDIR') or on PATH; Install-Nsis.ps1 installs NSIS $ExpectedVersion." }
  $reported = ([string](& $VersionProbe $exe)).Trim()
  if ($reported -ne "v$ExpectedVersion") {
    throw "makensis at $exe reports '$reported', but the pin is v$ExpectedVersion (NSIS_VERSION); install the pinned NSIS rather than build with another."
  }
  return (Resolve-Path -LiteralPath $exe).Path
}

function Assert-NsisPayloadPath {
  <#
    .SYNOPSIS
      Fail when a payload path reaches MAX_PATH, which makensis cannot open; returns the longest path length.
  #>
  param([Parameter(Mandatory)] [string]$PayloadDir, [int]$Limit = $script:NsisMaxPath)
  $root = (Resolve-Path -LiteralPath $PayloadDir).Path
  $longest = Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1
  if (-not $longest) { throw "NSIS payload is empty: $root" }
  if ($longest.FullName.Length -gt $Limit) {
    throw "NSIS payload path is $($longest.FullName.Length) characters, over makensis's $Limit-character limit: $($longest.FullName). Build from a shorter root."
  }
  return $longest.FullName.Length
}

# $ starts an NSIS variable, so a literal one in a path is doubled.
function ConvertTo-NsisString { param([string]$Text) return $Text.Replace('$', '$$') }

function Split-NsisParent { param([string]$Path) if ($Path.Contains('\')) { return $Path.Substring(0, $Path.LastIndexOf('\')) } return '' }

function New-NsisFileList {
  <#
    .SYNOPSIS
      Write the KG_INSTALL_FILES and KG_UNINSTALL_FILES macros for every payload file, so the uninstaller removes only them.
  #>
  param([Parameter(Mandatory)] [string]$PayloadDir, [Parameter(Mandatory)] [string]$Path)
  $root = (Resolve-Path -LiteralPath $PayloadDir).Path
  # The installed layout is a Windows path whatever host writes the list.
  $entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
      # File's source is read at compile time, where only ${define} expands; $ stays literal there.
      if ($_.FullName.Contains('${')) { throw "NSIS cannot pack a payload path containing '`${': $($_.FullName)" }
      $rel = [System.IO.Path]::GetRelativePath($root, $_.FullName).Replace('/', '\')
      [pscustomobject]@{ Source = $_.FullName; Rel = $rel; Dir = (Split-NsisParent $rel) }
    })
  if ($entries.Count -eq 0) { throw "NSIS payload is empty: $root" }
  $current = $null
  $install = foreach ($entry in $entries) {
    if ($entry.Dir -ne $current) {
      "  SetOutPath `"`$INSTDIR$(if ($entry.Dir) { '\' + (ConvertTo-NsisString $entry.Dir) })`""
      $current = $entry.Dir
    }
    "  File `"$($entry.Source)`""
  }
  $dirs = $entries | ForEach-Object { for ($d = $_.Dir; $d; $d = Split-NsisParent $d) { $d } } | Sort-Object -Unique
  $depthFirst = $dirs | Sort-Object { ($_ -split '\\').Count }, { $_ } -Descending
  $uninstall = @($entries | ForEach-Object { "  Delete `"`$INSTDIR\$(ConvertTo-NsisString $_.Rel)`"" }) +
    @($depthFirst | ForEach-Object { "  RMDir `"`$INSTDIR\$(ConvertTo-NsisString $_)`"" })
  New-PackagerParentDirectory -Path $Path
  @('!macro KG_INSTALL_FILES') + $install + @('!macroend', '!macro KG_UNINSTALL_FILES') + $uninstall + @('!macroend') |
    Set-Content -LiteralPath $Path -Encoding utf8
  return $Path
}

# One native argv token per define, so a value with spaces cannot split.
function Get-NsisDefineArguments {
  param([System.Collections.IDictionary]$Defines)
  foreach ($name in $Defines.Keys) {
    if ($name -cnotmatch '^KG_[A-Z0-9_]+$') { throw "Invalid NSIS define name: $name (KG_ and upper case only)" }
    $value = [string]$Defines[$name]
    if ($value -match '["\r\n]') { throw "NSIS define $name carries a quote or newline, which makensis cannot pass through" }
    "/D$name=$value"
  }
}

function ConvertTo-NsisVersion {
  param([Parameter(Mandatory)] [string]$Version)
  $digits = [regex]::Match($Version, '^[vV]?([0-9]+(\.[0-9]+){0,3})')
  if (-not $digits.Success) { throw "NSIS needs a numeric version, got '$Version'" }
  $parts = @($digits.Groups[1].Value.Split('.'))
  while ($parts.Count -lt 4) { $parts += '0' }
  return ($parts -join '.')
}

# Setup keys: required ones, and the pattern each value must match.
$script:NsisSetupKeys = [ordered]@{
  ProductName = '\S'; Publisher = '\S'; Version = '\d'; Arch = '^(x64|arm64)$'; PayloadDir = '\S'; MainExe = '\S'
  LicenseFile = '\S'; UninstallKey = '^[A-Za-z0-9][A-Za-z0-9._-]*$'; OtherArchSetup = '\S'; OutFile = '\S'; WorkDir = '\S'
}
$script:NsisSetupOptional = @{
  MsiUpgradeCode = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'; IconFile = '\S'; ShortcutArguments = '\S'; SignPfx = '\S'
}

function Assert-NsisSetup {
  <#
    .SYNOPSIS
      Fail on a missing, malformed or unknown setup key, or a missing input file, before makensis runs.
  #>
  param([Parameter(Mandatory)] [System.Collections.IDictionary]$Setup, [Parameter(Mandatory)] [string]$ScriptPath)
  foreach ($key in $Setup.Keys) {
    if (-not ($script:NsisSetupKeys.Contains($key) -or $script:NsisSetupOptional.ContainsKey($key))) { throw "Unknown NSIS setup key: $key" }
    $pattern = if ($script:NsisSetupKeys.Contains($key)) { $script:NsisSetupKeys[$key] } else { $script:NsisSetupOptional[$key] }
    if ([string]$Setup[$key] -cnotmatch $pattern) { throw "NSIS setup key $key is malformed: '$($Setup[$key])'" }
  }
  $missing = @($script:NsisSetupKeys.Keys | Where-Object { -not $Setup.Contains($_) })
  if ($missing) { throw "NSIS setup lacks $($missing -join ', ')" }
  if (-not (Test-Path -LiteralPath $Setup.PayloadDir -PathType Container)) { throw "NSIS payload directory not found: $($Setup.PayloadDir)" }
  $inputs = [ordered]@{ 'the setup script' = $ScriptPath; 'the license' = $Setup.LicenseFile; 'the main exe' = (Join-Path $Setup.PayloadDir $Setup.MainExe) }
  if ($Setup.Contains('IconFile')) { $inputs['the icon'] = $Setup.IconFile }
  if ($Setup.Contains('SignPfx')) { $inputs['the signing .pfx'] = $Setup.SignPfx }
  Assert-PackagerInput -Kind 'NSIS' -Inputs $inputs
}

function Invoke-NsisPackage {
  <#
    .SYNOPSIS
      Build one per-machine NSIS setup from the hub's setup.nsi; the output's existence is asserted.
    .PARAMETER Setup
      ProductName, Publisher, Version, Arch (x64|arm64), PayloadDir, MainExe, LicenseFile, UninstallKey (stable,
      no version), OtherArchSetup (named when this setup refuses), OutFile and WorkDir; optional MsiUpgradeCode
      (the setup stops when that MSI is installed), IconFile, ShortcutArguments and SignPfx (signs the setup and
      its uninstaller; the password comes from MSIX_PFX_PASSWORD or MSIX_CERT_PASSWORD).
  #>
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [System.Collections.IDictionary]$Setup,
    [string]$ScriptPath = $script:NsisDefaultScript,
    [string]$MakensisPath = '',
    [string]$ExpectedVersion = $env:NSIS_VERSION,
    [scriptblock]$VersionProbe,
    [scriptblock]$SignatureReader,
    # Test seam, as in Invoke-MsiPackage: real builds need makensis.
    [scriptblock]$InvokerScriptBlock
  )

  Assert-NsisSetup -Setup $Setup -ScriptPath $ScriptPath
  $resolveArgs = @{ OverridePath = $MakensisPath; ExpectedVersion = $ExpectedVersion }
  if ($VersionProbe) { $resolveArgs.VersionProbe = $VersionProbe }
  $makensis = Resolve-MakensisExe @resolveArgs
  [void](Assert-NsisPayloadPath -PayloadDir $Setup.PayloadDir)

  $defines = [ordered]@{
    KG_PRODUCT_NAME = $Setup.ProductName; KG_VERSION = (ConvertTo-NsisVersion $Setup.Version); KG_PUBLISHER = $Setup.Publisher
    KG_ARCH = $Setup.Arch; KG_MAIN_EXE = $Setup.MainExe; KG_UNINSTALL_KEY = $Setup.UninstallKey
    KG_LICENSE_FILE = (Resolve-Path -LiteralPath $Setup.LicenseFile).Path; KG_OTHER_ARCH_SETUP = $Setup.OtherArchSetup
    KG_FILE_LIST = (New-NsisFileList -PayloadDir $Setup.PayloadDir -Path (Join-Path $Setup.WorkDir 'kg-files.nsh'))
    KG_OUTFILE = [System.IO.Path]::GetFullPath($Setup.OutFile)
  }
  if ($Setup.Contains('MsiUpgradeCode')) { $defines.KG_MSI_UPGRADE_CODE = $Setup.MsiUpgradeCode }
  if ($Setup.Contains('IconFile')) { $defines.KG_ICON = (Resolve-Path -LiteralPath $Setup.IconFile).Path }
  if ($Setup.Contains('ShortcutArguments')) { $defines.KG_SHORTCUT_ARGS = $Setup.ShortcutArguments }
  if ($Setup.Contains('SignPfx')) {
    $defines.KG_SIGN_PFX = (Resolve-Path -LiteralPath $Setup.SignPfx).Path
    $defines.KG_SIGN_PWSH = (Get-Process -Id $PID).Path
    $defines.KG_SIGN_LOGDIR = [System.IO.Path]::GetFullPath((Join-Path $Setup.WorkDir 'sign-logs'))
  }

  $nsisArgs = @('/V3', '/INPUTCHARSET', 'UTF8') + @(Get-NsisDefineArguments -Defines $defines) + @((Resolve-Path -LiteralPath $ScriptPath).Path)
  Invoke-PackagerTool -Context $Context -File $makensis -Parameters $nsisArgs -OutputPath $defines.KG_OUTFILE -InvokerScriptBlock $InvokerScriptBlock
  # makensis already stopped on a failed !finalize; this proves the file that left it carries the signature.
  if ($Setup.Contains('SignPfx')) {
    $signerArgs = @{ Path = $defines.KG_OUTFILE; PfxPath = $defines.KG_SIGN_PFX }
    if ($SignatureReader) { $signerArgs.SignatureReader = $SignatureReader }
    Assert-AuthenticodeSigner @signerArgs
  }
  return $defines.KG_OUTFILE
}

Export-ModuleMember -Function Resolve-MakensisExe, Assert-NsisPayloadPath, New-NsisFileList, Get-NsisDefineArguments, ConvertTo-NsisVersion, Assert-NsisSetup, Invoke-NsisPackage
