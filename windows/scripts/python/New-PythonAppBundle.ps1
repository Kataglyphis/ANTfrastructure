#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Builds a consumer's Python app into a relocatable folder and proves it runs; see docs/python-app-bundles.md § What the builders do

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Config = 'packaging/app.json',
    [string]$WheelDir = 'dist',
    [string]$OutDir = 'dist/windows-x64/bundle',
    [string]$WorkDir = '',
    [string]$PythonSource = 'C:\temp\cpython',
    [string]$PythonBuild = 'C:\temp\cpython\PCbuild\amd64',
    [string]$OrtWheelDir = '',
    [string]$VcRuntimeDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# WindowsOrtPayload.Common first and top-level: the app module reuses it, and this script calls Assert-ChainOrtTree itself.
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsOrtPayload.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

$app = Get-PythonAppConfig -Path (Resolve-PythonAppPath $RepoRoot $Config)
$bundle = Resolve-PythonAppPath $RepoRoot $OutDir
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) "python-app-$($app['id'])" }
$null = New-Item -ItemType Directory -Force -Path $WorkDir
if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $bundle

# The compiled wheel for the runtime's ABI when there is one: the bundle ships binaries, not source.
$wheels = @(Get-ChildItem -LiteralPath (Resolve-PythonAppPath $RepoRoot $WheelDir) -Filter '*.whl' -File |
    Where-Object { (($_.Name -split '-')[0] -replace '[-_.]+', '_').ToLowerInvariant() -eq ($app['distribution'] -replace '[-_.]+', '_').ToLowerInvariant() })
if ($wheels.Count -eq 0) { throw "No $($app['distribution']) wheel in $WheelDir; build it first (Invoke-CiPackaging.ps1)" }
$abiTag = Get-PythonAbiTag -Python (Join-Path $PythonBuild 'python.exe')
$appWheel = Select-PythonAppWheel -Wheels $wheels -AbiTag $abiTag
Write-Host "App wheel: $($appWheel.Name) (runtime ABI $abiTag)"

if (-not $OrtWheelDir) { $OrtWheelDir = @($env:ORT_CHAIN_WHEEL_DIR, $env:PYTHON_WHEELS, 'C:\runtime\wheels') | Where-Object { $_ } | Select-Object -First 1 }
$ortWheel = @(Get-ChildItem -LiteralPath $OrtWheelDir -Filter 'onnxruntime-*.whl' -File)
if ($ortWheel.Count -ne 1) { throw "Expected one chain onnxruntime-*.whl in $OrtWheelDir, found $($ortWheel.Count)" }
Write-Host "Chain ORT wheel: $($ortWheel[0].Name)"

Write-Host '== runtime'
$python = New-PythonAppRuntime -SourceDir $PythonSource -BuildDir $PythonBuild -Destination (Join-Path $bundle 'runtime')

Write-Host '== packages'
Install-PythonAppPackage -Python $python -RepoRoot $RepoRoot -AppWheel $appWheel.FullName -Extras $app['extras'] -OrtWheel $ortWheel[0].FullName -WorkDir $WorkDir

if ($app.ContainsKey('chain_opencv') -and $app['chain_opencv']) {
    Write-Host '== chain OpenCV (no Media Foundation, unlike PyPI cv2)'
    $cv2Copied = @(Install-PythonAppChainOpenCv -Python $python -SitePackages (Join-Path $bundle 'runtime\Lib\site-packages'))
    Write-Host "  cv2\bin: $($cv2Copied.Count) DLL(s)"
}

Write-Host '== launchers'
$sitePackages = Join-Path $bundle 'runtime\Lib\site-packages'
$entryPoints = Get-PythonAppEntryPoint -SitePackages $sitePackages -Distribution $app['distribution']
$wanted = if ($app.ContainsKey('scripts')) { @($app['scripts']) } else { @($entryPoints.Keys) }
foreach ($name in $wanted) {
    if (-not $entryPoints.Contains($name)) { throw "$($app['distribution']) declares no console script '$name'" }
    $exe = New-PythonAppLauncher -Name $name -EntryPoint $entryPoints[$name] -Destination $bundle -DataEnv $app['data_env'] -DataDir $app['data_dir'] -WorkDir $WorkDir
    Write-Host "  $name -> $($entryPoints[$name]) ($exe)"
}

Write-Host '== data'
foreach ($item in @($app['data'])) {
    if (-not $item) { continue }
    $to = Join-Path $bundle $item['to']
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent)
    Copy-Item -LiteralPath (Resolve-PythonAppPath $RepoRoot $item['from']) -Destination $to -Force
    Write-Host "  $($item['from']) -> $($item['to'])"
}

Write-Host '== VC++ runtime closure'
if (-not $VcRuntimeDir) {
    $VcRuntimeDir = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio', 'C:\Program Files\Microsoft Visual Studio' -Recurse -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\Redist\\MSVC\\[^\\]+\\x64\\' } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VcRuntimeDir) { throw 'No x64 VC++ redist CRT directory; pass -VcRuntimeDir' }
$copied = @(Copy-PythonAppRuntimeClosure -Runtime (Join-Path $bundle 'runtime') -SearchDirectory $VcRuntimeDir)
Write-Host "  copied: $(@($copied | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"

Write-Host '== import walk: every DLL a binary imports ships in the bundle or with Windows'
& (Join-Path $PSScriptRoot '..\build\Test-TargetArch.ps1') -Path $bundle -Arch amd64 -ImportWalk -Standalone -MinInspected 20

Write-Host '== G6: ONNX Runtime is the chain build'
$ortDir = Join-Path $sitePackages 'onnxruntime\capi'
$null = Assert-ChainOrtTree -Root $bundle -OrtDirectory $ortDir -WaiveUnresolved

Write-Host '== self-test'
$report = Invoke-PythonAppSelfTest -Bundle $bundle -Command $app['self_test'] -Root $bundle

$manifest = [ordered]@{
    name = $app['name']
    wheel = $appWheel.Name
    ort_wheel = $ortWheel[0].Name
    python = & $python -c 'import sys; print(sys.version.split()[0])'
    scripts = $wanted
    self_test = $report
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Encoding utf8
Write-Host "Bundle ready: $bundle"
