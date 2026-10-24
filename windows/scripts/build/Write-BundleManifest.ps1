# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
<#
.SYNOPSIS
    Writes the bundle's self-description into C:\runtime: BUNDLE-ENV.cmd, BUNDLE-ENV.ps1 and BUNDLE-README.md.
.DESCRIPTION
    A copied C:\runtime otherwise names none of its DLL homes. Runs in the merge stage on both lanes and writes
    only what it can check there: the arch table, the merge RUN's ENV, existing dirs and the branches' ABSENT markers.
#>
param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -ScriptDir is accepted only for parity with the other merge-stage scripts; the resolver needs no hint.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
$gstModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if ((Test-Path $gstModule) -and -not (Get-Module -Name 'WindowsGstPlugins.Common')) { Import-Module $gstModule }

function Get-BundleEnvironmentAction {
    param([string]$InstallDir, [string]$Arch, [object[]]$Environment, [string[]]$DllHome,
        [string]$PythonRoot, [string]$FreeThreadedExe, [string]$FreeThreadedRoot, [string]$WheelDir)
    $set = { param($Name, $Value, $Mode = 'Set') [pscustomobject]@{ Name = $Name; Value = $Value; Mode = $Mode } }
    & $set KATA_BUNDLE_ROOT $InstallDir
    & $set KATA_BUNDLE_ARCH $Arch
    foreach ($row in @($Environment | Where-Object { $_.Exists })) { & $set $row.Name $row.Value }
    & $set PATH ($DllHome -join ';') Prepend
    if ($PythonRoot) {
        & $set KATA_PYTHON "$PythonRoot\python.exe"
        & $set PATH $PythonRoot Prepend
    }
    if ($FreeThreadedExe) {
        & $set KATA_PYTHON_FREETHREADED $FreeThreadedExe
        & $set PATH $FreeThreadedRoot Append
    }
    & $set KATA_WHEELS $WheelDir
}

function ConvertTo-BundleEnvironmentScript {
    param([ValidateSet('Cmd', 'PowerShell')][string]$Syntax, [object[]]$Action, [string]$Header)
    if ($Syntax -eq 'Cmd') {
        '@echo off'
        "rem $Header"
        'rem Registers every DLL home of this bundle. Run once per shell (or from a script) before using anything below.'
    } else {
        "# $Header"
        '# Dot-source this file: . C:\runtime\BUNDLE-ENV.ps1'
    }
    foreach ($item in $Action) {
        $value = [string]$item.Value
        if ($Syntax -eq 'Cmd') {
            if ($item.Mode -eq 'Append') { $value = "%PATH%;$value" }
            elseif ($item.Mode -eq 'Prepend') { $value += ';%PATH%' }
            'set "{0}={1}"' -f $item.Name, $value
        } else {
            $expression = "'" + $value.Replace("'", "''") + "'"
            if ($item.Mode -eq 'Append') { $expression = '$env:PATH + ' + "';" + $value.Replace("'", "''") + "'" }
            elseif ($item.Mode -eq 'Prepend') { $expression = "'" + $value.Replace("'", "''") + ";' + " + '$env:PATH' }
            '$env:{0} = {1}' -f $item.Name, $expression
        }
    }
}

function Get-BundleManifestFacts {
    param([string]$InstallDir, [string]$Arch, [object]$Info, [bool]$Cross)

    $envNames = @('FFMPEG_BIN', 'OPENCV_BIN', 'ONNX_ROOT', 'ONNX_GENAI_ROOT', 'LITERT_BIN', 'LITERT_LM_ROOT', 'GSTREAMER_BIN',
                  'GST_PLUGIN_PATH', 'GST_PLUGIN_SYSTEM_PATH', 'TVM_ROOT', 'IREE_ROOT', 'IREE_BIN', 'PYTHON_WHEELS', 'PYTHON_WHEELS_FREE_THREADED',
                  'VULKAN_SDK', 'LP_NATIVE_VECTOR_WIDTH')
    $envRows = @()
    foreach ($n in $envNames) {
        $v = [Environment]::GetEnvironmentVariable($n, 'Process')
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $exists = Test-Path $v
        $envRows += [pscustomobject]@{ Name = $n; Value = $v; Exists = $exists }
    }
    $bundleBin = Join-Path $InstallDir 'bin'
    $dllHomes = @($bundleBin) + @($envRows | Where-Object { $_.Exists -and $_.Name -match '_BIN$' } | ForEach-Object { $_.Value })
    foreach ($extra in @((Join-Path $InstallDir "lib\opencv5\$($Info.OpenCvArchDir)\vc18\bin"), (Join-Path $InstallDir 'lib\onnxruntime-source\bin'), (Join-Path $InstallDir 'lib\onnxruntime-genai-source\bin'), (Join-Path $InstallDir 'lavapipe'))) {
        if ((Test-Path $extra) -and ($dllHomes -notcontains $extra)) { $dllHomes += $extra }
    }
    $dllHomes = @($dllHomes | Select-Object -Unique)

    $targetPython = Join-Path $InstallDir 'python'
    $pythonRoot = if (Test-Path (Join-Path $targetPython 'python.exe')) { $targetPython } else { '' }
    $ftPythonRoot = Join-Path $InstallDir 'python-freethreaded'
    $ftExeName = Get-CpythonFreeThreadedExeName
    $ftPythonExe = if (Test-Path (Join-Path $ftPythonRoot $ftExeName)) { Join-Path $ftPythonRoot $ftExeName } else { '' }
    $wheelDir = Join-Path $InstallDir 'wheels'
    $wheels = @(if (Test-Path $wheelDir) { Get-ChildItem -Path $wheelDir -Filter '*.whl' -File | ForEach-Object { $_.Name } })
    $ftWheelDir = Join-Path $InstallDir (Split-Path -Leaf (Get-FreeThreadedWheelStore))
    $ftWheels = @(if (Test-Path $ftWheelDir) { Get-ChildItem -Path $ftWheelDir -Filter '*.whl' -File | ForEach-Object { $_.Name } })
    if ($Cross) {
        # The cross bundle cannot run smoke section 20, so its twin store must be checked here.
        $ftFindings = @(Get-FreeThreadedStoreFinding -Store $ftWheelDir -GilStore $wheelDir -PlatformTag $Info.PythonWheelTag)
        if ($ftFindings.Count -gt 0) { throw "write-bundle-manifest: the cp3XYt store does not mirror the GIL store:`n  $($ftFindings -join "`n  ")" }
    }
    $absent = @(Get-ChildItem -Path $InstallDir -Recurse -File -Include 'ABSENT-ON-*.txt', 'COMPILER-ABSENT-*.txt' -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Path = $_.FullName.Substring($InstallDir.Length).TrimStart('\'); First = (Get-Content $_.FullName -TotalCount 1) } })
    $plugins = @(if (Get-Command Get-RequiredGstPlugin -ErrorAction SilentlyContinue) { Get-RequiredGstPlugin -Arch $Arch | ForEach-Object { $_.Name } })
    return [pscustomobject]@{ EnvRows = $envRows; DllHomes = $dllHomes; BundleBin = $bundleBin; PythonRoot = $pythonRoot
        FtPythonRoot = $ftPythonRoot; FtExeName = $ftExeName; FtPythonExe = $ftPythonExe; WheelDir = $wheelDir
        Wheels = $wheels; FtWheelDir = $ftWheelDir; FtWheels = $ftWheels; Absent = $absent; Plugins = $plugins }
}

function Get-BundleReadmePythonLines {
    param([string]$PythonRoot, [string]$BundleBin,
        [string]$FtPythonExe, [string]$FtExeName, [string]$WheelDir, [string[]]$Wheels,
        [string]$FtWheelDir, [string[]]$FtWheels)

    '## Python'
    ''
    if ($PythonRoot) {
        "- Interpreter: ``$PythonRoot\python.exe`` (source-built for this target; CRT DLLs beside it and in ``$BundleBin``)."
        "- Site-packages: ``$PythonRoot\Lib\site-packages`` (cv2 installed there, plus its DLL-directory shim)."
        '- pip is not installed but its wheel ships with the stdlib: `python -m ensurepip` (offline).'
    } else {
        '- Interpreter: the image''s CPython (`python` on PATH); the bundle wheels are already installed into it.'
    }
    if ($FtPythonExe) {
        $ftRequest = $FtExeName -replace '^python' -replace '\.exe$'
        "- Free-threaded interpreter: ``$FtPythonExe`` (``--disable-gil``, source-built for this target). It is last on ``PATH`` and has no ``python.exe``, so only a ``$ftRequest`` request finds it (``uv venv --python $ftRequest`` with ``UV_PYTHON_DOWNLOADS=never``). Its site-packages starts empty; its wheels are the store below, never the GIL one."
    }
    "- Wheel store: ``$WheelDir`` -- $($Wheels.Count) wheel(s):"
    foreach ($w in $Wheels) { "  - ``$w``" }
    if ($FtWheels.Count -gt 0) {
        "- Free-threaded wheel store: ``$FtWheelDir`` -- the ``cp3XYt`` twins of the wheels whose code declares free-threading, $($FtWheels.Count) wheel(s). Install one into a venv of the free-threaded interpreter with ``pip install --no-index --no-deps``; their dependencies have no ``cp3XYt`` wheels in this bundle:"
        foreach ($w in $FtWheels) { "  - ``$w``" }
    }
    ''
    'Install from the store only, never from PyPI on top of it -- the store carries the bundle''s own `onnxruntime` (CPU+DirectML), which a PyPI resolve would shadow:'
    ''
    '```'
    "python -m ensurepip"
    "python -m pip install --no-index --find-links $WheelDir onnxruntime onnxruntime-genai-directml av"
    '```'
    ''
}

function Get-BundleReadmeIntegrationLines {
    param([string[]]$Plugins, [bool]$Cross,
        [string]$BundleBin, [string]$InstallDir)

    '## GStreamer'
    ''
    "Mandatory plugin contract on this lane: $(if ($Plugins.Count) { ($Plugins | ForEach-Object { '`' + $_ + '`' }) -join ', ' } else { '(module not present at manifest time)' })."
    if ($Cross) {
        ''
        '**One-time step on the device:** the GIO module cache (`giomodule.cache`) is not shipped -- `gio-querymodules` cannot run during a cross build. Run once after copying the bundle, from a shell where BUNDLE-ENV has been called:'
        ''
        '```'
        "$BundleBin\gio-querymodules.exe $InstallDir\lib\gio\modules"
        '```'
        ''
        'Without it GIO loads no TLS/proxy modules (gioopenssl); plain pipelines are unaffected.'
    }
    ''
    '## Vulkan on lavapipe'
    ''
    "The CPU Vulkan device (Mesa's lavapipe) sits in ``$InstallDir\lavapipe`` with its own loader and ``vulkaninfo.exe``; ``LP_NATIVE_VECTOR_WIDTH=256`` is set because Mesa 26.2's BVH sort needs 8-lane subgroups."
    ''
    '```'
    "$InstallDir\lavapipe\vulkaninfo.exe --summary"
    '```'
    if ($Cross) {
        ''
        '**One-time step on the device:** copying the tree does not register the ICD, and the loader ignores `VK_DRIVER_FILES` in an elevated process. From an elevated shell, where BUNDLE-ENV has been called:'
        ''
        '```'
        "New-Item -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -Force | Out-Null"
        "New-ItemProperty -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -Name `"$InstallDir\lavapipe\lvp_icd.aarch64.json`" -Value 0 -PropertyType DWord -Force"
        '```'
    }
    $validationJson = Join-Path $InstallDir 'vulkan-layers\VkLayer_khronos_validation.json'
    if (Test-Path -LiteralPath $validationJson) {
        ''
        '## The Vulkan validation layer'
        ''
        "``VkLayer_khronos_validation`` for this arch sits in ``$InstallDir\vulkan-layers``, at the image's Vulkan SDK version. The loader ignores ``VK_ADD_LAYER_PATH`` in an elevated process, so register it there instead:"
        ''
        '```'
        "New-Item -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\ExplicitLayers' -Force | Out-Null"
        "New-ItemProperty -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\ExplicitLayers' -Name `"$validationJson`" -Value 0 -PropertyType DWord -Force"
        '```'
    }
}

if (-not (Test-Path $InstallDir)) { throw "write-bundle-manifest: $InstallDir does not exist -- nothing to describe" }

$arch  = Get-WindowsTargetArch
$info  = Get-WindowsTargetArchInfo -Arch $arch
$cross = Test-WindowsCrossTarget -Arch $arch

$facts = Get-BundleManifestFacts -InstallDir $InstallDir -Arch $arch -Info $info -Cross $cross
$envRows = $facts.EnvRows
$dllHomes = $facts.DllHomes
$bundleBin = $facts.BundleBin
$pythonRoot = $facts.PythonRoot
$ftPythonRoot = $facts.FtPythonRoot
$ftExeName = $facts.FtExeName
$ftPythonExe = $facts.FtPythonExe
$wheelDir = $facts.WheelDir
$wheels = $facts.Wheels
$ftWheelDir = $facts.FtWheelDir
$ftWheels = $facts.FtWheels
$absent = $facts.Absent
$plugins = $facts.Plugins

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z'

$environmentAction = @(Get-BundleEnvironmentAction -InstallDir $InstallDir -Arch $arch -Environment $envRows -DllHome $dllHomes `
    -PythonRoot $pythonRoot -FreeThreadedExe $ftPythonExe -FreeThreadedRoot $ftPythonRoot -WheelDir $wheelDir)
$environmentHeader = "Kataglyphis Windows media bundle -- $arch ($($info.PeMachineName)), written $stamp by Write-BundleManifest.ps1 (#130)"
$cmd = @(ConvertTo-BundleEnvironmentScript -Syntax Cmd -Action $environmentAction -Header $environmentHeader)
$ps = @(ConvertTo-BundleEnvironmentScript -Syntax PowerShell -Action $environmentAction -Header $environmentHeader)

# BUNDLE-README.md
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Kataglyphis Windows media bundle -- $arch")
$md.Add('')
$md.Add("Target: **$arch** (PE machine $($info.PeMachineName), clang target ``$($info.ClangTriple)``, wheel tag ``$($info.PythonWheelTag)``). Written $stamp by ``Write-BundleManifest.ps1`` in the merge stage; every path below was checked to exist at that moment.")
$md.Add('')
if ($cross) {
    $md.Add('This is a **cross-compiled artifact bundle**: it was produced inside a `windows/amd64` container and nothing in it has been executed there (Windows x64 cannot run ARM64 code). Its static gates -- PE machine of every binary, a whole-tree import walk, the wheel store -- are the proof it carries; running it on a device is the proof it does not.')
} else {
    $md.Add('This bundle is the `C:\runtime` tree of the native `windows/amd64` image; the same facts are the image ENV, restated here so a copied tree describes itself.')
}
$md.Add('')
$md.Add('## Register the DLL homes')
$md.Add('')
$md.Add('`call C:\runtime\BUNDLE-ENV.cmd` (cmd) or `. C:\runtime\BUNDLE-ENV.ps1` (pwsh). They prepend these directories to `PATH`:')
$md.Add('')
foreach ($d in $dllHomes) { $md.Add("- ``$d``") }
$md.Add('')
$md.Add('Python extension modules do not consult `PATH` (Python >= 3.8): the shipped `sitecustomize.py` in the site-packages below registers the same directories with `os.add_dll_directory` at interpreter start.')
$md.Add('')
$md.AddRange([string[]]@(Get-BundleReadmePythonLines -PythonRoot $pythonRoot -BundleBin $bundleBin -FtPythonExe $ftPythonExe `
    -FtExeName $ftExeName -WheelDir $wheelDir -Wheels $wheels -FtWheelDir $ftWheelDir -FtWheels $ftWheels))
$md.AddRange([string[]]@(Get-BundleReadmeIntegrationLines -Plugins $plugins -Cross $cross -BundleBin $bundleBin -InstallDir $InstallDir))
$md.Add('')
$md.Add('## Absent on this lane, by construction')
$md.Add('')
if ($absent.Count -eq 0) {
    $md.Add('Nothing -- every component of the amd64 image is present.')
} else {
    foreach ($a in $absent) { $md.Add("- ``$($a.Path)`` -- $($a.First)") }
}
$md.Add('')
$md.Add('## ENV facts carried over from the build')
$md.Add('')
$md.Add('| Name | Value | Exists |')
$md.Add('|---|---|---|')
foreach ($r in $envRows) { $md.Add("| ``$($r.Name)`` | ``$($r.Value)`` | $(if ($r.Exists) { 'yes' } else { 'no' }) |") }
$md.Add('')
$md.Add('Docs: `docs/windows-cross-builds.md` (lane status, gates, what is absent and why), `docs/windows-builds.md` (the build).')

$cmdPath = Join-Path $InstallDir 'BUNDLE-ENV.cmd'
$psPath  = Join-Path $InstallDir 'BUNDLE-ENV.ps1'
$mdPath  = Join-Path $InstallDir 'BUNDLE-README.md'
[IO.File]::WriteAllText($cmdPath, (($cmd -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
[IO.File]::WriteAllText($psPath,  (($ps  -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($mdPath,  (($md  -join "`n")   + "`n"),   (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("Bundle manifest ({0}): {1} DLL home(s), python={2}, free-threaded={9}, {3} wheel(s) + {10} cp3XYt twin(s), {4} absent marker(s), plugins [{5}] -> {6}, {7}, {8}" -f $arch, $dllHomes.Count, $(if ($pythonRoot) { $pythonRoot } else { 'image CPython' }), $wheels.Count, $absent.Count, ($plugins -join ' '), $cmdPath, $psPath, $mdPath, $(if ($ftPythonExe) { $ftPythonExe } else { 'none' }), $ftWheels.Count)
exit 0
