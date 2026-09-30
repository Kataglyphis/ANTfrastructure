#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Wraps a New-PythonAppBundle.ps1 folder as zip and MSI, and starts each as a user would; see docs/python-app-bundles.md § Packages

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Config = 'packaging/app.json',
    [Parameter(Mandatory)][string]$Bundle,
    [string]$OutDir = '',
    [string]$Formats = 'zip,msi',
    [switch]$SkipTest,
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsScripts.Shared.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

$app = Get-PythonAppConfig -Path (Resolve-PythonAppPath $RepoRoot $Config)
$Bundle = (Resolve-Path -LiteralPath (Resolve-PythonAppPath $RepoRoot $Bundle)).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $Bundle 'bundle.json') -Raw | ConvertFrom-Json -AsHashtable
# The wheel name's second field is its version: orchestrant-0.0.28-py3-none-any.whl.
$version = ($manifest['wheel'] -split '-')[1]
$OutDir = if ($OutDir) { Resolve-PythonAppPath $RepoRoot $OutDir } else { Split-Path $Bundle -Parent }
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) "python-app-package-$($app['id'])" }
$null = New-Item -ItemType Directory -Force -Path $OutDir, $WorkDir
$test = -not $SkipTest
Write-Host "$($app['name']) $version from $Bundle"

function Invoke-ZipPackage {
    $stem = "$($app['id'])-$version-windows-x64"
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
    Write-Host "Created: $zip ($([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB)) MB)"
    if (-not $test) { return }
    $unpacked = Join-Path $WorkDir 'zip-test'
    if (Test-Path -LiteralPath $unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $unpacked
    & "$env:SystemRoot\System32\tar.exe" -x -f $zip -C $unpacked
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to unpack $zip (exit $LASTEXITCODE)" }
    $root = Join-Path $unpacked $stem
    $null = Invoke-PythonAppSelfTest -Bundle $root -Command $app['self_test'] -Root $root
    Write-Host "  started from the unpacked zip: ok"
}

function Invoke-Msiexec([string[]]$Arguments, [string]$Log) {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList (@($Arguments) + @('/qn', '/norestart', '/l*v', "`"$Log`"")) -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec $($Arguments -join ' ') exited $($p.ExitCode); see $Log" }
}

function Invoke-MsiPackage {
    if (-not $app.ContainsKey('icon') -or -not $app['icon']) { throw "app.json names no icon; the MSI's shortcut needs one" }
    $icon = ConvertTo-PythonAppIcon -PngPath (Resolve-PythonAppPath $RepoRoot $app['icon']) -Destination (Join-Path $WorkDir 'app.ico')
    $wxs = New-PythonAppWxs -Bundle $Bundle -App $app -Version $version -IconPath $icon -Destination (Join-Path $WorkDir "$($app['id']).wxs")
    $msi = Join-Path $OutDir "$($app['id'])-$version-windows-x64.msi"
    & wix build -arch x64 -pdbtype none -o $msi $wxs
    if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE)" }
    Write-Host "Created: $msi ($([math]::Round((Get-Item -LiteralPath $msi).Length / 1MB)) MB)"
    if (-not $test) { return }
    $admin = Test-Elevated
    # A real install changes Program Files and the system PATH, so only a container's throwaway system gets one.
    $inContainer = [bool](Get-Service -Name cexecsvc -ErrorAction SilentlyContinue)
    if (-not ($admin -and $inContainer)) {
        # An administrative install unpacks the payload without changing the machine; it proves the files, not the install.
        Write-Warning 'Not an elevated container: proving the MSI payload with msiexec /a instead of an install'
        $target = Join-Path $WorkDir 'msi-admin'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Invoke-Msiexec -Arguments @('/a', "`"$msi`"", "TARGETDIR=`"$target`"") -Log (Join-Path $WorkDir 'msi-admin.log')
        $launcher = Get-ChildItem -LiteralPath $target -Recurse -File -Filter "$(@($app['self_test'])[0]).exe" | Select-Object -First 1
        if (-not $launcher) { throw "msiexec /a unpacked no $(@($app['self_test'])[0]).exe under $target" }
        $root = $launcher.DirectoryName
        $null = Invoke-PythonAppSelfTest -Bundle $root -Command $app['self_test'] -Root $root
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

foreach ($format in @($Formats -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    Write-Host "== $format"
    switch ($format) {
        'zip' { Invoke-ZipPackage }
        'msi' { Invoke-MsiPackage }
        default { throw "Unknown format '$format' (zip, msi)" }
    }
}
Write-Host "Packages ready in $OutDir"
