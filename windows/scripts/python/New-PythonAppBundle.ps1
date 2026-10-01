#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Builds a consumer's Python app into a relocatable folder and proves it runs; see docs/python-app-bundles.md § What the builders do

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Config = 'packaging/app.json',
    [string]$WheelDir = 'dist',
    # Empty: dist/windows-<x64|arm64>/bundle.
    [string]$OutDir = '',
    [string]$WorkDir = '',
    [string]$PythonSource = 'C:\temp\cpython',
    # The host build: the runtime itself on amd64, and on a cross lane the interpreter that lays out and compiles the target's.
    [string]$PythonBuild = 'C:\temp\cpython\PCbuild\amd64',
    # The target CPython a cross lane's image installs (Build-TargetCpython.ps1).
    [string]$TargetPython = 'C:\runtime\python',
    [string]$OrtWheelDir = '',
    [string]$VcRuntimeDir = '',
    # amd64 or arm64; empty takes the image's WINDOWS_TARGET_ARCH. arm64 lays the bundle out here and leaves the self-test to the device.
    [string]$TargetArch = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# WindowsOrtPayload.Common first and top-level: the app module reuses it, and this script calls Assert-ChainOrtTree itself.
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsOrtPayload.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsTargetArch.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

$arch = Get-WindowsTargetArch -Arch $TargetArch
$cross = Test-WindowsCrossTarget -Arch $arch
$packageArch = Get-WindowsPackageArch -Arch $arch
$app = Get-PythonAppConfig -Path (Resolve-PythonAppPath $RepoRoot $Config)
if (-not $OutDir) { $OutDir = "dist/windows-$packageArch/bundle" }
$bundle = Resolve-PythonAppPath $RepoRoot $OutDir
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) "python-app-$($app['id'])-$arch" }
$null = New-Item -ItemType Directory -Force -Path $WorkDir
if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $bundle
$hostPython = Join-Path $PythonBuild 'python.exe'
# Host and target come from one CPython tree, so the host reports the target's version and ABI tag.
$pythonVersion = "$(& $hostPython -c 'import sys; print(sys.version.split()[0])')".Trim()
Write-Host "$($app['name']) for $arch$(if ($cross) { ' (cross)' }), CPython $pythonVersion"

# The compiled wheel for the runtime's ABI and platform when there is one: the bundle ships binaries, not source.
$wheels = @(Get-ChildItem -LiteralPath (Resolve-PythonAppPath $RepoRoot $WheelDir) -Filter '*.whl' -File |
    Where-Object { (($_.Name -split '-')[0] -replace '[-_.]+', '_').ToLowerInvariant() -eq ($app['distribution'] -replace '[-_.]+', '_').ToLowerInvariant() })
if ($wheels.Count -eq 0) { throw "No $($app['distribution']) wheel in $WheelDir; build it first (Invoke-CiPackaging.ps1)" }
$abiTag = Get-PythonAbiTag -Python $hostPython
$appWheel = Select-PythonAppWheel -Wheels $wheels -AbiTag $abiTag -PlatformTag (Get-PythonWheelTag -Arch $arch)
Write-Host "App wheel: $($appWheel.Name) (runtime ABI $abiTag)"

if (-not $OrtWheelDir) { $OrtWheelDir = @($env:ORT_CHAIN_WHEEL_DIR, $env:PYTHON_WHEELS, 'C:\runtime\wheels') | Where-Object { $_ } | Select-Object -First 1 }
$ortWheel = @(Get-ChildItem -LiteralPath $OrtWheelDir -Filter 'onnxruntime-*.whl' -File)
if ($ortWheel.Count -ne 1) { throw "Expected one chain onnxruntime-*.whl in $OrtWheelDir, found $($ortWheel.Count)" }
Write-Host "Chain ORT wheel: $($ortWheel[0].Name)"

$chainOpenCv = $app.ContainsKey('chain_opencv') -and $app['chain_opencv']
$runtime = Join-Path $bundle 'runtime'
$sitePackages = Join-Path $runtime 'Lib\site-packages'
Write-Host '== runtime'
if ($cross) {
    $python = New-PythonAppCrossRuntime -TargetPython $TargetPython -SourceDir $PythonSource -HostPython $hostPython -Arch $arch -WorkDir $WorkDir -Destination $runtime
} else {
    $python = New-PythonAppRuntime -SourceDir $PythonSource -BuildDir $PythonBuild -Destination $runtime
}

Write-Host '== packages'
if ($cross) {
    $exclude = @('onnxruntime') + @(if ($chainOpenCv) { 'opencv-python' })
    Install-PythonAppCrossPackage -HostPython $hostPython -SitePackages $sitePackages -RepoRoot $RepoRoot -AppWheel $appWheel.FullName -Extras $app['extras'] `
        -OrtWheel $ortWheel[0].FullName -WorkDir $WorkDir -Platform (Get-ClangTargetTriple -Arch $arch) -PythonVersion (($pythonVersion -split '\.')[0..1] -join '.') -Exclude $exclude
} else {
    Install-PythonAppPackage -Python $python -RepoRoot $RepoRoot -AppWheel $appWheel.FullName -Extras $app['extras'] -OrtWheel $ortWheel[0].FullName -WorkDir $WorkDir
}

if ($chainOpenCv) {
    Write-Host '== chain OpenCV (no Media Foundation, unlike PyPI cv2)'
    $cv2Args = @{ Python = $python; SitePackages = $sitePackages; Arch = $arch }
    if ($cross) { $cv2Args['HostPython'] = $hostPython; $cv2Args['Source'] = Join-Path $TargetPython 'Lib\site-packages\cv2' }
    $cv2Copied = @(Install-PythonAppChainOpenCv @cv2Args)
    Write-Host "  cv2\bin: $($cv2Copied.Count) DLL(s)"
}

Write-Host '== launchers'
$entryPoints = Get-PythonAppEntryPoint -SitePackages $sitePackages -Distribution $app['distribution']
$wanted = if ($app.ContainsKey('scripts')) { @($app['scripts']) } else { @($entryPoints.Keys) }
foreach ($name in $wanted) {
    if (-not $entryPoints.Contains($name)) { throw "$($app['distribution']) declares no console script '$name'" }
    $exe = New-PythonAppLauncher -Name $name -EntryPoint $entryPoints[$name] -Destination $bundle -DataEnv $app['data_env'] -DataDir $app['data_dir'] -WorkDir $WorkDir -Arch $arch
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
        Where-Object { $_.FullName -match "\\Redist\\MSVC\\[^\\]+\\$packageArch\\" } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VcRuntimeDir) { throw "No $packageArch VC++ redist CRT directory; pass -VcRuntimeDir" }
$copied = @(Copy-PythonAppRuntimeClosure -Runtime $runtime -SearchDirectory $VcRuntimeDir -Arch $arch)
Write-Host "  copied: $(@($copied | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"

Write-Host '== import walk: every DLL a binary imports ships in the bundle or with Windows'
& (Join-Path $PSScriptRoot '..\build\Test-TargetArch.ps1') -Path $bundle -Arch $arch -ImportWalk -Standalone -MinInspected 20

Write-Host '== G6: ONNX Runtime is the chain build'
$null = Assert-ChainOrtTree -Root $bundle -OrtDirectory (Join-Path $sitePackages 'onnxruntime\capi') -WaiveUnresolved

if ($cross) {
    # No emulation runs an arm64 binary on this host: the device runs the checker, so it travels beside the bundle.
    Write-Host '== self-test: deferred to the device'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-PythonAppSelfTest.ps1') -Destination (Split-Path $bundle -Parent)
    $report = "deferred to the $arch device: Test-PythonAppSelfTest.ps1 -Bundle <bundle> -Command $(@($app['self_test']) -join ',')"
} else {
    Write-Host '== self-test'
    $report = Invoke-PythonAppSelfTest -Bundle $bundle -Command $app['self_test'] -Root $bundle
}

$manifest = [ordered]@{
    name = $app['name']
    arch = $arch
    wheel = $appWheel.Name
    ort_wheel = $ortWheel[0].Name
    python = $pythonVersion
    scripts = $wanted
    self_test = $report
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Encoding utf8
Write-Host "Bundle ready: $bundle"
