#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Wraps a New-PythonAppBundle.ps1 folder as zip, MSI and MSIX, and starts each as a user would; see docs/python-app-bundles.md § Packages

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Config = 'packaging/app.json',
    [Parameter(Mandatory)][string]$Bundle,
    [string]$OutDir = '',
    [string]$Formats = 'zip,msi,msix',
    [switch]$SkipTest,
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsScripts.Shared.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsMsix.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

$app = Get-PythonAppConfig -Path (Resolve-PythonAppPath $RepoRoot $Config)
$Bundle = (Resolve-Path -LiteralPath (Resolve-PythonAppPath $RepoRoot $Bundle)).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $Bundle 'bundle.json') -Raw | ConvertFrom-Json -AsHashtable
# The wheel name's second field is its version: orchestrant-0.0.28-py3-none-any.whl.
$version = ($manifest['wheel'] -split '-')[1]
$stem = "$($app['id'])-$version-windows-x64"
$OutDir = if ($OutDir) { Resolve-PythonAppPath $RepoRoot $OutDir } else { Split-Path $Bundle -Parent }
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) "python-app-package-$($app['id'])" }
$null = New-Item -ItemType Directory -Force -Path $OutDir, $WorkDir
$test = -not $SkipTest
# A real install or a trusted root changes the machine, so only a container's throwaway system gets either.
$throwaway = (Test-Elevated) -and [bool](Get-Service -Name cexecsvc -ErrorAction SilentlyContinue)
Write-Host "$($app['name']) $version from $Bundle"

# The app's icon PNG; the MSI's shortcut and the MSIX's logos both need one.
function Get-AppIconPng([string]$For) {
    if (-not $app.ContainsKey('icon') -or -not $app['icon']) { throw "app.json names no icon; $For needs one" }
    return Resolve-PythonAppPath $RepoRoot $app['icon']
}

function Write-Created([string]$Path, [string]$Note = '') {
    Write-Host "Created: $Path ($([math]::Round((Get-Item -LiteralPath $Path).Length / 1MB)) MB)$Note"
}

# An empty directory under the work dir, whatever an earlier run left there.
function New-EmptyWorkDir([string]$Name) {
    $path = Join-Path $WorkDir $Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $path
    return $path
}

function Test-StartedFrom([string]$Root, [string]$What) {
    $null = Invoke-PythonAppSelfTest -Bundle $Root -Command $app['self_test'] -Root $Root
    Write-Host "  started from $($What): ok"
}

function Invoke-ZipPackage {
    $zip = Join-Path $OutDir "$stem.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    # Windows' bsdtar has no -s to rename the top folder, so the bundle carries the release name while it is zipped.
    $parent = Split-Path $Bundle -Parent
    $staged = Join-Path $parent $stem
    if ($staged -ne $Bundle) { Rename-Item -LiteralPath $Bundle -NewName $stem }
    try {
        & "$env:SystemRoot\System32\tar.exe" -a -c -f $zip -C $parent $stem
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to write $zip (exit $LASTEXITCODE)" }
    } finally {
        if ($staged -ne $Bundle) { Rename-Item -LiteralPath $staged -NewName (Split-Path $Bundle -Leaf) }
    }
    Write-Created $zip
    if (-not $test) { return }
    $unpacked = New-EmptyWorkDir 'zip-test'
    & "$env:SystemRoot\System32\tar.exe" -x -f $zip -C $unpacked
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to unpack $zip (exit $LASTEXITCODE)" }
    Test-StartedFrom (Join-Path $unpacked $stem) 'the unpacked zip'
}

function Invoke-Msiexec([string[]]$Arguments, [string]$Log) {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList (@($Arguments) + @('/qn', '/norestart', '/l*v', "`"$Log`"")) -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec $($Arguments -join ' ') exited $($p.ExitCode); see $Log" }
}

function Invoke-MsiPackage {
    $icon = ConvertTo-PythonAppIcon -PngPath (Get-AppIconPng "the MSI's shortcut") -Destination (Join-Path $WorkDir 'app.ico')
    $wxs = New-PythonAppWxs -Bundle $Bundle -App $app -Version $version -IconPath $icon -Destination (Join-Path $WorkDir "$($app['id']).wxs")
    $msi = Join-Path $OutDir "$stem.msi"
    & wix build -arch x64 -pdbtype none -o $msi $wxs
    if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE)" }
    Write-Created $msi
    if (-not $test) { return }
    if (-not $throwaway) {
        # An administrative install unpacks the payload without changing the machine; it proves the files, not the install.
        Write-Warning 'Not an elevated container: proving the MSI payload with msiexec /a instead of an install'
        $target = New-EmptyWorkDir 'msi-admin'
        Invoke-Msiexec -Arguments @('/a', "`"$msi`"", "TARGETDIR=`"$target`"") -Log (Join-Path $WorkDir 'msi-admin.log')
        $launcher = Get-ChildItem -LiteralPath $target -Recurse -File -Filter "$(@($app['self_test'])[0]).exe" | Select-Object -First 1
        if (-not $launcher) { throw "msiexec /a unpacked no $(@($app['self_test'])[0]).exe under $target" }
        Test-StartedFrom $launcher.DirectoryName 'the administrative MSI unpack'
        return
    }
    Invoke-Msiexec -Arguments @('/i', "`"$msi`"") -Log (Join-Path $WorkDir 'msi-install.log')
    $installed = Join-Path $env:ProgramFiles $app['name']
    $null = Invoke-PythonAppSelfTest -Bundle $installed -Command $app['self_test'] -Root $installed
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
    if ($machinePath -notcontains $installed -and $machinePath -notcontains "$installed\") { throw "The MSI did not put $installed on the system PATH" }
    Write-Host "  installed, started from $installed, and on PATH: ok"
    Invoke-Msiexec -Arguments @('/x', "`"$msi`"") -Log (Join-Path $WorkDir 'msi-uninstall.log')
    if (Test-Path -LiteralPath $installed) { throw "The uninstall left $installed behind" }
    Write-Host '  uninstalled cleanly: ok'
}

function Invoke-SdkTool([string]$Tool, [string[]]$Arguments) {
    $exe = Resolve-WindowsSdkToolPath -ToolName $Tool -OverridePath ''
    if (-not $exe) { throw "$Tool not found; it comes with the Windows SDK" }
    & $exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool $($Arguments[0]) failed (exit $LASTEXITCODE)" }
}

function Invoke-MsixAppPackage {
    $png = Get-AppIconPng "the MSIX's logos"
    $msix = Join-Path $OutDir "$stem.msix"
    $cer = Join-Path $OutDir "$stem-test-signing.cer"
    $work = New-EmptyWorkDir 'msix'
    $assets = Join-Path $work 'Assets'
    $null = New-Item -ItemType Directory -Force -Path $assets
    foreach ($logo in 'StoreLogo', 'Square150x150Logo', 'Square44x44Logo') {
        Copy-Item -LiteralPath $png -Destination (Join-Path $assets "$logo.png")
    }
    $publisher = "CN=$($app['publisher'])"
    $manifest = New-PythonAppAppxManifest -App $app -Version $version -Publisher $publisher -Destination (Join-Path $work 'AppxManifest.xml')
    # A mapping file packs the bundle where it lies, instead of staging a second 0.5 GB copy.
    $root = $Bundle.TrimEnd('\').Length + 1
    $map = @('[Files]', "`"$manifest`" `"AppxManifest.xml`"") +
        @(Get-ChildItem -LiteralPath $assets -File | ForEach-Object { "`"$($_.FullName)`" `"Assets\$($_.Name)`"" }) +
        @(Get-ChildItem -LiteralPath $Bundle -Recurse -File | ForEach-Object { "`"$($_.FullName)`" `"$($_.FullName.Substring($root))`"" })
    Set-Content -LiteralPath (Join-Path $work 'mapping.txt') -Value $map -Encoding utf8NoBOM
    Invoke-SdkTool 'makeappx.exe' @('pack', '/o', '/h', 'SHA256', '/f', (Join-Path $work 'mapping.txt'), '/p', $msix)
    $pfx = Join-Path $work 'test-signing.pfx'
    $thumbprint = New-PythonAppSigningCertificate -Subject $publisher -PfxPath $pfx -CerPath $cer
    try {
        Invoke-SdkTool 'signtool.exe' @('sign', '/fd', 'SHA256', '/f', $pfx, $msix)
    } finally {
        Remove-Item -LiteralPath $pfx -Force
    }
    Write-Created $msix ", signed by a test certificate for $publisher ($(Split-Path $cer -Leaf))"
    if (-not $test) { return }
    $unpacked = New-EmptyWorkDir 'msix-test'
    Invoke-SdkTool 'makeappx.exe' @('unpack', '/o', '/p', $msix, '/d', $unpacked)
    Test-StartedFrom $unpacked 'the unpacked MSIX'
    # Server Core cannot install an MSIX at all; the signature is what a client host checks first.
    if (-not $throwaway) {
        Write-Warning 'Not an elevated container: the MSIX signature chain is not verified, since that needs the test root trusted'
        return
    }
    $trusted = Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root'
    try {
        Invoke-SdkTool 'signtool.exe' @('verify', '/pa', $msix)
        if ($trusted.Thumbprint -ne $thumbprint) { throw "The .cer beside the MSIX is not the certificate that signed it" }
    } finally {
        Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($trusted.Thumbprint)" -Force
    }
    Write-Host '  signature verified against the shipped test certificate: ok'
}

foreach ($format in @($Formats -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    Write-Host "== $format"
    switch ($format) {
        'zip' { Invoke-ZipPackage }
        'msi' { Invoke-MsiPackage }
        'msix' { Invoke-MsixAppPackage }
        default { throw "Unknown format '$format' (zip, msi, msix)" }
    }
}
Write-Host "Packages ready in $OutDir"
