# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#
# TARGET CPython (#120; docs/windows-cross-builds.md § "The target CPython is built from source").
# Not the pythonarm64 nuget: a foreign prebuilt in a chain that builds what it ships.
# Host-vs-target discipline: build.bat runs under the HOST interpreter; only the link
# inputs and the shipped tree are target-arch, and the result can never RUN here -- the
# in-stage PE machine check is the only proof this stage can get.

param(
    [string]$SourceDir = 'C:\temp\cpython',
    [string]$InstallDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$tgtArch = Get-WindowsTargetArch
if (-not (Test-WindowsCrossTarget -Arch $tgtArch)) {
    # amd64: host == target, so the toolchain layer's build already serves. Kept
    # in the chain on both lanes so -ResumeFrom/-Until names stay lane-independent.
    Write-Host 'Target CPython: host == target on amd64 — the toolchain PCbuild\amd64 build already serves as the target interpreter. Nothing to do.'
    exit 0
}

trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'target-cpython'; break }

Switch-BuildPhase '1. preconditions'
$buildBat = Join-Path $SourceDir 'PCbuild\build.bat'
if (-not (Test-Path $buildBat)) {
    throw ("Target CPython: $buildBat not found. The toolchain layer ships the CPython SOURCE tree " +
           '(it is the deliverable); if it is absent this image predates that contract or the tree was scrubbed.')
}
$hostPy = Get-SourceBuildPython
if (-not (Test-Path $hostPy.Exe)) { throw "Target CPython: host build interpreter missing at $($hostPy.Exe) — build.bat needs it via `$env:PYTHON" }
$propsFile = Join-Path $SourceDir 'PCbuild\Directory.Build.props'
if (-not (Test-Path $propsFile)) {
    # The ARM64 build must go through the ClangCL toolset like the host build, so
    # restore the props the toolchain layer drops here if a scrub removed them.
    $shipped = Join-Path $scriptAssetRoot 'cpython-Directory.Build.props'
    if (Test-Path $shipped) { Copy-Item $shipped $propsFile } else { throw "Target CPython: $propsFile missing and no shipped props to restore" }
}
$cpyBuildPlatform = Get-CpythonBuildPlatform -Arch $tgtArch   # 'ARM64'
$cpyOutDir = Join-Path $SourceDir "PCbuild\$(Get-CpythonOutputDir -Arch $tgtArch)"  # ...\PCbuild\arm64
Write-Host "Target CPython: building -p $cpyBuildPlatform (ClangCL toolset) from $SourceDir; output -> $cpyOutDir"

Switch-BuildPhase '2. externals'
# The toolchain layer deletes externals after the host build, so -e below re-fetches
# them (the archives carry both arch payloads). Own phase so a network failure is
# attributed here rather than to 'build'.
$env:PYTHON = $hostPy.Exe
$externals = Join-Path $SourceDir 'externals'
if (Test-Path $externals) {
    Write-Host "externals already present at $externals (unexpected on this image, but fine)"
} else {
    Write-Host 'externals absent (deleted by the toolchain layer after the host build) — build.bat -e will fetch them'
}

Switch-BuildPhase '3. PCbuild -p ARM64 (ClangCL)'
# /p:PreferredToolArchitecture=x64 forces the x64-hosted cross compilers (Hostx64\arm64);
# without it MSBuild may pick an arm64-hosted toolchain that cannot execute here.
# An "unknown PlatformToolset ClangCL for ARM64" failure answers #114 Phase-0 Q1 negatively.
& cmd /c "cd /d $SourceDir && PCbuild\build.bat -e -p $cpyBuildPlatform -c Release `"/p:PreferredToolArchitecture=x64`""
if ($LASTEXITCODE -ne 0) { throw "Target CPython build.bat -p $cpyBuildPlatform failed (exit $LASTEXITCODE)" }

Switch-BuildPhase '4. verify + stage into the bundle'
$tgtExe = Join-Path $cpyOutDir 'python.exe'
$tgtLib = Get-ChildItem -Path $cpyOutDir -Filter 'python3*.lib' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^python3\d+\.lib$' } | Select-Object -First 1
if (-not (Test-Path $tgtExe)) { throw "Target CPython: $tgtExe was not produced" }
if (-not $tgtLib) { throw "Target CPython: no python3XY.lib import library in $cpyOutDir" }
# PE machine checked here, not only at the merge gate, so a wrong-arch interpreter
# fails with a message that names the defect. IMAGE_FILE_MACHINE sits at (0x3C pointer)+4.
$fs = [System.IO.File]::OpenRead($tgtExe)
try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Seek(0x3C, 'Begin') | Out-Null
    $peOff = $br.ReadUInt32()
    $fs.Seek($peOff + 4, 'Begin') | Out-Null
    $machine = $br.ReadUInt16()
} finally { $fs.Dispose() }
$wantMachine = Get-PeMachineType -Arch $tgtArch
if ($machine -ne $wantMachine) {
    throw ('Target CPython: python.exe machine is 0x{0:X4}, expected 0x{1:X4} — the ARM64 platform build produced a host-arch binary (PreferredToolArchitecture / toolset resolution went wrong)' -f $machine, $wantMachine)
}
Write-Host ('Target CPython: python.exe PE machine 0x{0:X4} verified' -f $machine)

# Staged under the arch gate's scan root, laid out like a python.org install so
# on-device consumers need no map.
$pyRoot = Join-Path $InstallDir 'python'
foreach ($d in @($pyRoot, "$pyRoot\DLLs", "$pyRoot\libs", "$pyRoot\include")) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
Copy-Item "$cpyOutDir\python*.exe" $pyRoot -Force
Copy-Item "$cpyOutDir\python*.dll" $pyRoot -Force
Copy-Item "$cpyOutDir\*.pyd" "$pyRoot\DLLs" -Force -ErrorAction SilentlyContinue
# Sidecar DLLs the pyds need (libffi, ssl/crypto, sqlite, tk if built).
Get-ChildItem $cpyOutDir -Filter '*.dll' -File | Where-Object { $_.Name -notmatch '^python' } |
    ForEach-Object { Copy-Item $_.FullName "$pyRoot\DLLs" -Force }

# Self-policing PE check: MSBuild's redist copy step drops host-arch CRT DLLs into
# the ARM64 output. Replace from the VS ARM64 redist tree, else throw HERE with a
# name rather than 40 minutes later in the merge gate (#120; 1 violation in 932 scanned).
$redistArm64 = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\arm64\Microsoft.VC*.CRT' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
foreach ($staged in (Get-ChildItem -Path $pyRoot -Recurse -Include '*.dll', '*.exe', '*.pyd' -File)) {
    $m = Get-PeFileMachine -Path $staged.FullName
    if ($m -eq $wantMachine) { continue }
    $replacement = if ($redistArm64) { Join-Path $redistArm64.FullName $staged.Name } else { $null }
    if ($replacement -and (Test-Path $replacement) -and ((Get-PeFileMachine -Path $replacement) -eq $wantMachine)) {
        Copy-Item $replacement $staged.FullName -Force
        Write-Host ('Target CPython: replaced host-arch {0} (0x{1:X4}) with the VS ARM64 redist copy' -f $staged.Name, $m)
    } elseif ($staged.Name -ieq 'vcruntime140_1.dll' -and (Test-Path (Join-Path $staged.DirectoryName 'vcruntime140.dll')) -and ((Get-PeFileMachine -Path (Join-Path $staged.DirectoryName 'vcruntime140.dll')) -eq $wantMachine)) {
        # vcruntime140_1.dll has NO ARM64 edition by design (x64 FH4 helpers only);
        # ARM64 keeps everything in vcruntime140.dll, so dropping it is the CORRECT
        # target image. See docs/windows-cross-builds.md § "The target CPython...".
        Remove-Item $staged.FullName -Force
        Write-Host ('Target CPython: dropped {0} (0x{1:X4}) -- no ARM64 edition of this DLL exists; vcruntime140.dll (target-arch) carries its role' -f $staged.Name, $m)
    } else {
        throw ('Target CPython: staged {0} is machine 0x{1:X4}, expected 0x{2:X4}, and no ARM64 redist replacement was found -- refusing to ship a host-arch binary in the bundle' -f $staged.FullName, $m, $wantMachine)
    }
}
Copy-Item $tgtLib.FullName "$pyRoot\libs" -Force
# Headers: Include\ is arch-neutral source; PC\pyconfig.h selects by compiler
# macros at INCLUDE time, so one copy serves the target.
Copy-Item "$SourceDir\Include\*" "$pyRoot\include" -Recurse -Force
Copy-Item "$SourceDir\PC\pyconfig.h" "$pyRoot\include" -Force
# Stdlib is arch-neutral; site-packages is NOT (the tree's belongs to the HOST
# interpreter), so the target starts EMPTY -- cv2 lands there from the OpenCV
# stage, the other wheels in C:\runtime\wheels.
Copy-Item "$SourceDir\Lib" "$pyRoot\Lib" -Recurse -Force
$tgtSitePackages = Join-Path $pyRoot 'Lib\site-packages'
if (Test-Path $tgtSitePackages) { Get-ChildItem -LiteralPath $tgtSitePackages -Force | Remove-Item -Recurse -Force }
New-Item -Path $tgtSitePackages -ItemType Directory -Force | Out-Null

# #124/#127: the CRT must sit BESIDE python.exe -- DLLs\ is a *Python* search path,
# invisible to the loader, so a clean device died 0xC0000135 before any Python ran.
# The same set goes to C:\runtime\bin, the DLL home every other consumer registers.
$crtNames = @('vcruntime140.dll', 'vcruntime140_threads.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'concrt140.dll', 'vccorlib140.dll')
$bundleBin = Join-Path $InstallDir 'bin'
New-Item -Path $bundleBin -ItemType Directory -Force | Out-Null
$crtStaged = 0
foreach ($crt in $crtNames) {
    $src = if (Test-Path (Join-Path "$pyRoot\DLLs" $crt)) { Join-Path "$pyRoot\DLLs" $crt } elseif ($redistArm64 -and (Test-Path (Join-Path $redistArm64.FullName $crt))) { Join-Path $redistArm64.FullName $crt } else { $null }
    if (-not $src) { continue }
    if ((Get-PeFileMachine -Path $src) -ne $wantMachine) { throw "Target CPython: CRT candidate $src is not target-arch -- refusing to stage it" }
    Copy-Item $src (Join-Path $pyRoot $crt) -Force
    Copy-Item $src (Join-Path $bundleBin $crt) -Force
    $crtStaged++
}
if (-not (Test-Path (Join-Path $pyRoot 'vcruntime140.dll'))) {
    throw "Target CPython: vcruntime140.dll (target-arch) could not be staged beside python.exe -- neither the build output nor the VS ARM64 redist tree ($($redistArm64.FullName)) had it; the interpreter would not start on a clean device"
}
Write-Host "Target CPython: staged $crtStaged CRT DLL(s) beside python.exe and in $bundleBin (loader-visible; #124)"

# #125: the DLL-directory shim for the TARGET interpreter -- the same writer as
# the host's, without the host-only platform/EXT_SUFFIX patches.
$tgtShim = Write-PythonDllDirectoryShim -SitePackages $tgtSitePackages -OpenCvArchDir (Get-OpenCvArchDir -Arch $tgtArch) `
    -WrittenBy 'build-target-cpython.ps1 (TARGET interpreter, #125)'
Write-Host "Target CPython: wrote the DLL-directory sitecustomize shim for the target interpreter: $tgtShim"

# pip on the device: `python -m ensurepip` installs from the stdlib's bundled
# wheel, offline. Assert the wheel travelled with the Lib copy.
$ensurepipWheel = Get-ChildItem -Path (Join-Path $pyRoot 'Lib\ensurepip\_bundled') -Filter 'pip-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ensurepipWheel) { throw "Target CPython: Lib\ensurepip\_bundled\pip-*.whl missing -- the device would have no way to install the staged wheels" }
Write-Host "Target CPython: ensurepip bundle present ($($ensurepipWheel.Name)) -- `python -m ensurepip` works offline on the device"

$staged = @(Get-ChildItem $pyRoot -Recurse -File).Count
Write-Host "Target CPython: staged $staged files -> $pyRoot (interpreter + CRT + import lib + headers + stdlib + shim)"

Switch-BuildPhase '5. scrub'
# externals and obj are build residue; PCbuild\arm64 itself STAYS —
# Get-TargetBuildPython resolves link inputs there for the later consumer builds.
foreach ($d in @("$SourceDir\externals", "$SourceDir\PCbuild\obj")) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'target-cpython'
Write-Host '=== Target CPython build completed ==='
exit 0
