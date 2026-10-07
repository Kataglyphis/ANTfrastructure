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

if (-not (Test-Path $InstallDir)) { throw "write-bundle-manifest: $InstallDir does not exist -- nothing to describe" }

$arch  = Get-WindowsTargetArch
$info  = Get-WindowsTargetArchInfo -Arch $arch
$cross = Test-WindowsCrossTarget -Arch $arch

# 1. DLL homes: the merge RUN's ENV that exists, named as the GStreamer probe and the final PATH name them
$envNames = @('FFMPEG_BIN', 'OPENCV_BIN', 'ONNX_ROOT', 'ONNX_GENAI_ROOT', 'LITERT_BIN', 'LITERT_LM_ROOT', 'GSTREAMER_BIN',
              'GST_PLUGIN_PATH', 'GST_PLUGIN_SYSTEM_PATH', 'TVM_ROOT', 'IREE_ROOT', 'IREE_BIN', 'PYTHON_WHEELS', 'PYTHON_WHEELS_CP314T',
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
foreach ($extra in @((Join-Path $InstallDir "lib\opencv5\$($info.OpenCvArchDir)\vc18\bin"), (Join-Path $InstallDir 'lib\onnxruntime-source\bin'), (Join-Path $InstallDir 'lib\onnxruntime-genai-source\bin'), (Join-Path $InstallDir 'lavapipe'))) {
    if ((Test-Path $extra) -and ($dllHomes -notcontains $extra)) { $dllHomes += $extra }
}
$dllHomes = @($dllHomes | Select-Object -Unique)

# 2. Python: the target interpreter on a cross lane, the image's host CPython on the native lane
$targetPython = Join-Path $InstallDir 'python'
$pythonRoot = if (Test-Path (Join-Path $targetPython 'python.exe')) { $targetPython } else { '' }
# Build-TargetCpython.ps1's free-threaded twin: last on PATH and without a python.exe, so only a 3.14t request finds it.
$ftPythonRoot = Join-Path $InstallDir 'python-freethreaded'
$ftExeName = Get-CpythonFreeThreadedExeName
$ftPythonExe = if (Test-Path (Join-Path $ftPythonRoot $ftExeName)) { Join-Path $ftPythonRoot $ftExeName } else { '' }
$wheelDir = Join-Path $InstallDir 'wheels'
$wheels = @(if (Test-Path $wheelDir) { Get-ChildItem -Path $wheelDir -Filter '*.whl' -File | ForEach-Object { $_.Name } })
# The cp3XYt twins' own store; see docs/windows-builds.md#the-free-threaded-wheels.
$ftWheelDir = Join-Path $InstallDir 'wheels-cp314t'
$ftWheels = @(if (Test-Path $ftWheelDir) { Get-ChildItem -Path $ftWheelDir -Filter '*.whl' -File | ForEach-Object { $_.Name } })
if ($cross) {
    # Smoke section 20 cannot run a cross bundle, so the store is checked here: every twin-verdict GIL wheel has its twin.
    $ftFindings = @(Get-FreeThreadedStoreFinding -Store $ftWheelDir -GilStore $wheelDir -PlatformTag $info.PythonWheelTag)
    if ($ftFindings.Count -gt 0) { throw "write-bundle-manifest: the cp3XYt store does not mirror the GIL store:`n  $($ftFindings -join "`n  ")" }
}

# 3. What is absent by construction on this lane, in the branches' own words
$absent = @(Get-ChildItem -Path $InstallDir -Recurse -File -Include 'ABSENT-ON-*.txt', 'COMPILER-ABSENT-*.txt' -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName.Substring($InstallDir.Length).TrimStart('\'); First = (Get-Content $_.FullName -TotalCount 1) } })

# 4. The GStreamer plugin contract this lane was gated on
$plugins = @(if (Get-Command Get-RequiredGstPlugin -ErrorAction SilentlyContinue) { Get-RequiredGstPlugin -Arch $arch | ForEach-Object { $_.Name } })

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z'

# BUNDLE-ENV.cmd
$cmd = [System.Collections.Generic.List[string]]::new()
$cmd.Add('@echo off')
$cmd.Add("rem Kataglyphis Windows media bundle -- $arch ($($info.PeMachineName)), written $stamp by Write-BundleManifest.ps1 (#130)")
$cmd.Add('rem Registers every DLL home of this bundle. Run once per shell (or from a script) before using anything below.')
$cmd.Add("set ""KATA_BUNDLE_ROOT=$InstallDir""")
$cmd.Add("set ""KATA_BUNDLE_ARCH=$arch""")
foreach ($r in ($envRows | Where-Object { $_.Exists })) { $cmd.Add("set ""$($r.Name)=$($r.Value)""") }
$cmd.Add("set ""PATH=$($dllHomes -join ';');%PATH%""")
if ($pythonRoot) {
    $cmd.Add("set ""KATA_PYTHON=$pythonRoot\python.exe""")
    $cmd.Add("set ""PATH=$pythonRoot;%PATH%""")
}
if ($ftPythonExe) {
    $cmd.Add("set ""KATA_PYTHON_FREETHREADED=$ftPythonExe""")
    $cmd.Add("set ""PATH=%PATH%;$ftPythonRoot""")
}
$cmd.Add("set ""KATA_WHEELS=$wheelDir""")

# BUNDLE-ENV.ps1
$ps = [System.Collections.Generic.List[string]]::new()
$ps.Add("# Kataglyphis Windows media bundle -- $arch ($($info.PeMachineName)), written $stamp by Write-BundleManifest.ps1 (#130)")
$ps.Add('# Dot-source this file: . C:\runtime\BUNDLE-ENV.ps1')
$ps.Add("`$env:KATA_BUNDLE_ROOT = '$InstallDir'")
$ps.Add("`$env:KATA_BUNDLE_ARCH = '$arch'")
foreach ($r in ($envRows | Where-Object { $_.Exists })) { $ps.Add("`$env:$($r.Name) = '$($r.Value)'") }
$ps.Add("`$env:PATH = '$($dllHomes -join ';');' + `$env:PATH")
if ($pythonRoot) {
    $ps.Add("`$env:KATA_PYTHON = '$pythonRoot\python.exe'")
    $ps.Add("`$env:PATH = '$pythonRoot;' + `$env:PATH")
}
if ($ftPythonExe) {
    $ps.Add("`$env:KATA_PYTHON_FREETHREADED = '$ftPythonExe'")
    $ps.Add("`$env:PATH = `$env:PATH + ';$ftPythonRoot'")
}
$ps.Add("`$env:KATA_WHEELS = '$wheelDir'")

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
$md.Add('## Python')
$md.Add('')
if ($pythonRoot) {
    $md.Add("- Interpreter: ``$pythonRoot\python.exe`` (source-built for this target; CRT DLLs beside it and in ``$bundleBin``).")
    $md.Add("- Site-packages: ``$pythonRoot\Lib\site-packages`` (cv2 installed there, plus its DLL-directory shim).")
    $md.Add('- pip is not installed but its wheel ships with the stdlib: `python -m ensurepip` (offline).')
} else {
    $md.Add('- Interpreter: the image''s CPython (`python` on PATH); the bundle wheels are already installed into it.')
}
if ($ftPythonExe) {
    $ftRequest = $ftExeName -replace '^python' -replace '\.exe$'
    $md.Add("- Free-threaded interpreter: ``$ftPythonExe`` (``--disable-gil``, source-built for this target). It is last on ``PATH`` and has no ``python.exe``, so only a ``$ftRequest`` request finds it (``uv venv --python $ftRequest`` with ``UV_PYTHON_DOWNLOADS=never``). Its site-packages starts empty; its wheels are the store below, never the GIL one.")
}
$md.Add("- Wheel store: ``$wheelDir`` -- $($wheels.Count) wheel(s):")
foreach ($w in $wheels) { $md.Add("  - ``$w``") }
if ($ftWheels.Count -gt 0) {
    $md.Add("- Free-threaded wheel store: ``$ftWheelDir`` -- the ``cp3XYt`` twins of the wheels whose code declares free-threading, $($ftWheels.Count) wheel(s). Install one into a venv of the free-threaded interpreter with ``pip install --no-index --no-deps``; their dependencies have no ``cp3XYt`` wheels in this bundle:")
    foreach ($w in $ftWheels) { $md.Add("  - ``$w``") }
}
$md.Add('')
$md.Add('Install from the store only, never from PyPI on top of it -- the store carries the bundle''s own `onnxruntime` (CPU+DirectML), which a PyPI resolve would shadow:')
$md.Add('')
$md.Add('```')
$md.Add("python -m ensurepip")
$md.Add("python -m pip install --no-index --find-links $wheelDir onnxruntime onnxruntime-genai-directml av")
$md.Add('```')
$md.Add('')
$md.Add('## GStreamer')
$md.Add('')
$md.Add("Mandatory plugin contract on this lane: $(if ($plugins.Count) { ($plugins | ForEach-Object { '`' + $_ + '`' }) -join ', ' } else { '(module not present at manifest time)' }).")
if ($cross) {
    $md.Add('')
    $md.Add('**One-time step on the device:** the GIO module cache (`giomodule.cache`) is not shipped -- `gio-querymodules` cannot run during a cross build. Run once after copying the bundle, from a shell where BUNDLE-ENV has been called:')
    $md.Add('')
    $md.Add('```')
    $md.Add("$bundleBin\gio-querymodules.exe $InstallDir\lib\gio\modules")
    $md.Add('```')
    $md.Add('')
    $md.Add('Without it GIO loads no TLS/proxy modules (gioopenssl); plain pipelines are unaffected.')
}
$md.Add('')
$md.Add('## Vulkan on lavapipe')
$md.Add('')
$md.Add("The CPU Vulkan device (Mesa's lavapipe) sits in ``$InstallDir\lavapipe`` with its own loader and ``vulkaninfo.exe``; ``LP_NATIVE_VECTOR_WIDTH=256`` is set because Mesa 26.2's BVH sort needs 8-lane subgroups.")
$md.Add('')
$md.Add('```')
$md.Add("$InstallDir\lavapipe\vulkaninfo.exe --summary")
$md.Add('```')
if ($cross) {
    $md.Add('')
    $md.Add('**One-time step on the device:** copying the tree does not register the ICD, and the loader ignores `VK_DRIVER_FILES` in an elevated process. From an elevated shell, where BUNDLE-ENV has been called:')
    $md.Add('')
    $md.Add('```')
    $md.Add("New-Item -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -Force | Out-Null")
    $md.Add("New-ItemProperty -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -Name `"$InstallDir\lavapipe\lvp_icd.aarch64.json`" -Value 0 -PropertyType DWord -Force")
    $md.Add('```')
}
$validationJson = Join-Path $InstallDir 'vulkan-layers\VkLayer_khronos_validation.json'
if (Test-Path -LiteralPath $validationJson) {
    $md.Add('')
    $md.Add('## The Vulkan validation layer')
    $md.Add('')
    $md.Add("``VkLayer_khronos_validation`` for this arch sits in ``$InstallDir\vulkan-layers``, at the image's Vulkan SDK version. The loader ignores ``VK_ADD_LAYER_PATH`` in an elevated process, so register it there instead:")
    $md.Add('')
    $md.Add('```')
    $md.Add("New-Item -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\ExplicitLayers' -Force | Out-Null")
    $md.Add("New-ItemProperty -Path 'HKLM:\SOFTWARE\Khronos\Vulkan\ExplicitLayers' -Name `"$validationJson`" -Value 0 -PropertyType DWord -Force")
    $md.Add('```')
}
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
