# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#
# TARGET CPython (backlog #120): builds the aarch64 interpreter + import library
# from the SAME source tree the toolchain layer already built the amd64 HOST
# interpreter from (C:\temp\cpython -- "IS the deliverable", see AGENTS.md), via
# PCbuild\build.bat -p ARM64 with the repo's ClangCL PlatformToolset props.
#
# Why FROM SOURCE and not the pythonarm64 nuget: owner decision, 2026-08-24.
# The nuget would be a foreign prebuilt inside a chain whose whole promise is
# "everything shipped is built here" -- the same reason the BtbN FFmpeg fallback
# refuses on every lane.
#
# What this unblocks (Tier 2 of the parity plan): the ORT python wheel, GenAI's
# bindings, cv2 and PyAV all skip on the cross lane for exactly one reason --
# "no target CPython to link". Producing python314.lib + headers ends that
# reason; each consumer is then flipped SEPARATELY (strict ordering, same
# discipline as #113/#118).
#
# What this can NEVER do on this host: run the result. python.exe here is
# aarch64; the arch gate (PE machine 0xAA64 over C:\runtime) is the proof this
# stage gets, and the windows-11-arm CI job is the only place it can ever start.
#
# HOST-vs-TARGET discipline (the recurring bug class of this lane): the BUILD
# interpreter stays Get-SourceBuildPython (host-pinned, PCbuild\amd64) --
# build.bat itself is driven with the HOST python via $env:PYTHON. Only the
# LINK INPUTS (python314.lib) and the SHIPPED tree are target-arch.

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
    # amd64: host == target. The toolchain layer's PCbuild\amd64 build IS the
    # target interpreter and is already consumed image-wide; a second build here
    # would only duplicate it. This stage is a deliberate no-op, present in the
    # chain on both lanes so -ResumeFrom/-Until names stay lane-independent.
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
    # The toolchain layer drops cpython-Directory.Build.props here (ClangCL
    # toolset). Restore it from the script assets if a scrub removed it: the
    # ARM64 build must go through ClangCL for the same invariant reason the
    # host build does.
    $shipped = Join-Path $scriptAssetRoot 'cpython-Directory.Build.props'
    if (Test-Path $shipped) { Copy-Item $shipped $propsFile } else { throw "Target CPython: $propsFile missing and no shipped props to restore" }
}
$cpyBuildPlatform = Get-CpythonBuildPlatform -Arch $tgtArch   # 'ARM64'
$cpyOutDir = Join-Path $SourceDir "PCbuild\$(Get-CpythonOutputDir -Arch $tgtArch)"  # ...\PCbuild\arm64
Write-Host "Target CPython: building -p $cpyBuildPlatform (ClangCL toolset) from $SourceDir; output -> $cpyOutDir"

Switch-BuildPhase '2. externals'
# The toolchain layer DELETES $SourceDir\externals after the host build (layer
# slimming), so the cross build must re-fetch them. get_externals is driven by
# the HOST interpreter; the archives it pulls from cpython-bin-deps carry
# per-arch payloads (openssl/tcltk ship amd64 AND arm64 subtrees), so the same
# fetch serves this platform. -e below re-runs it idempotently; this phase only
# exists so a network failure is attributed to 'externals', not to 'build'.
$env:PYTHON = $hostPy.Exe
$externals = Join-Path $SourceDir 'externals'
if (Test-Path $externals) {
    Write-Host "externals already present at $externals (unexpected on this image, but fine)"
} else {
    Write-Host 'externals absent (deleted by the toolchain layer after the host build) — build.bat -e will fetch them'
}

Switch-BuildPhase '3. PCbuild -p ARM64 (ClangCL)'
# /p:PreferredToolArchitecture=x64: the COMPILERS must be the x64-hosted
# cross-binaries (Hostx64\arm64) — without it MSBuild may pick an arm64-hosted
# toolchain that cannot execute here. Everything after -c Release passes
# through to msbuild.
# NB if this fails with an "unknown PlatformToolset ClangCL for ARM64" class of
# error, that answers #114 Phase-0 question 1 NEGATIVELY for this VS build —
# record the exact message in the backlog before touching the props file.
& cmd /c "cd /d $SourceDir && PCbuild\build.bat -e -p $cpyBuildPlatform -c Release `"/p:PreferredToolArchitecture=x64`""
if ($LASTEXITCODE -ne 0) { throw "Target CPython build.bat -p $cpyBuildPlatform failed (exit $LASTEXITCODE)" }

Switch-BuildPhase '4. verify + stage into the bundle'
$tgtExe = Join-Path $cpyOutDir 'python.exe'
$tgtLib = Get-ChildItem -Path $cpyOutDir -Filter 'python3*.lib' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^python3\d+\.lib$' } | Select-Object -First 1
if (-not (Test-Path $tgtExe)) { throw "Target CPython: $tgtExe was not produced" }
if (-not $tgtLib) { throw "Target CPython: no python3XY.lib import library in $cpyOutDir" }
# PE machine check RIGHT HERE, not only at the merge gate: a wrong-arch
# interpreter must fail THIS stage with a message that names the defect, not
# surface 40 minutes later as an anonymous gate violation. IMAGE_FILE_MACHINE
# sits at (0x3C pointer)+4.
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

# Stage the TARGET interpreter into the bundle, under the arch gate's scan root.
# Layout mirrors a python.org install so on-device consumers need no map:
#   C:\runtime\python\{python.exe, python3xy.dll, DLLs\, Lib\, include\, libs\}
$pyRoot = Join-Path $InstallDir 'python'
foreach ($d in @($pyRoot, "$pyRoot\DLLs", "$pyRoot\libs", "$pyRoot\include")) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
Copy-Item "$cpyOutDir\python*.exe" $pyRoot -Force
Copy-Item "$cpyOutDir\python*.dll" $pyRoot -Force
Copy-Item "$cpyOutDir\*.pyd" "$pyRoot\DLLs" -Force -ErrorAction SilentlyContinue
# Sidecar DLLs the pyds need (libffi, ssl/crypto, sqlite, tk if built).
Get-ChildItem $cpyOutDir -Filter '*.dll' -File | Where-Object { $_.Name -notmatch '^python' } |
    ForEach-Object { Copy-Item $_.FullName "$pyRoot\DLLs" -Force }

# SELF-POLICING PASS (2026-08-24; the merge arch gate caught exactly this on
# its first extended run): MSBuild's redist copy step put an x64
# vcruntime140_1.dll into PCbuild\arm64, and the sidecar glob swept it into the
# bundle -- 1 violation out of 932 inspected. The stage now PE-checks every
# staged binary itself: a wrong-arch CRT redist DLL is replaced from the VS
# installation's ARM64 redist tree; anything else wrong-arch throws HERE, with
# a name, instead of 40 minutes later in the merge.
$redistArm64 = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\arm64\Microsoft.VC*.CRT' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
foreach ($staged in (Get-ChildItem -Path $pyRoot -Recurse -Include '*.dll', '*.exe', '*.pyd' -File)) {
    $m = Get-PeFileMachine -Path$staged.FullName
    if ($m -eq $wantMachine) { continue }
    $replacement = if ($redistArm64) { Join-Path $redistArm64.FullName $staged.Name } else { $null }
    if ($replacement -and (Test-Path $replacement) -and ((Get-PeFileMachine -Path$replacement) -eq $wantMachine)) {
        Copy-Item $replacement $staged.FullName -Force
        Write-Host ('Target CPython: replaced host-arch {0} (0x{1:X4}) with the VS ARM64 redist copy' -f $staged.Name, $m)
    } elseif ($staged.Name -ieq 'vcruntime140_1.dll' -and (Test-Path (Join-Path $staged.DirectoryName 'vcruntime140.dll')) -and ((Get-PeFileMachine -Path(Join-Path $staged.DirectoryName 'vcruntime140.dll')) -eq $wantMachine)) {
        # vcruntime140_1.dll has NO ARM64 edition BY DESIGN: it exists only to
        # carry the x64 FH4 exception helpers (__CxxFrameHandler4); on ARM64
        # everything lives in vcruntime140.dll, which is staged here and IS
        # target-arch. MSBuild's redist copy step is host-blind and drops the
        # x64 file into the ARM64 output (measured 2026-08-24, run 13's merge
        # gate: the single violation in 932). Deleting is the CORRECT target
        # image, not a workaround -- guarded tightly to exactly this file and
        # only while its target-arch sibling is present.
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
# Stdlib: pure-python, arch-neutral. site-packages is NOT: the source tree's
# is the HOST interpreter's (pip/setuptools with x64 launcher stubs, and later
# every host-installed package), so the target starts with an EMPTY one -- cv2
# is installed into it by the OpenCV stage, the wheels + their deps live in
# C:\runtime\wheels, and pip comes from ensurepip's bundled wheel (below).
Copy-Item "$SourceDir\Lib" "$pyRoot\Lib" -Recurse -Force
$tgtSitePackages = Join-Path $pyRoot 'Lib\site-packages'
if (Test-Path $tgtSitePackages) { Get-ChildItem -LiteralPath $tgtSitePackages -Force | Remove-Item -Recurse -Force }
New-Item -Path $tgtSitePackages -ItemType Directory -Force | Out-Null

# #124 (2026-08-25, consumer-side audit): the CRT must sit BESIDE python.exe.
# python3xy.dll imports vcruntime140.dll through the LOADER's search order (exe
# directory, System32, PATH) -- DLLs\ is a *Python* search path, invisible to
# the loader -- so on a clean device without the ARM64 VC redist the
# interpreter died with 0xC0000135 before any Python ran. python.org's own
# layout keeps the CRT next to the exe. The same target-arch CRT set also goes
# to C:\runtime\bin, the bundle-wide DLL home every consumer registers, so
# opencv/onnxruntime/ffmpeg resolve it without a redist install.
# vcruntime140_threads.dll (C11 <threads.h> support, VS 17.10+ redist) joined the
# list after arm64 run 13's import walk (#127, 2026-08-25): LiteRT's
# tensorflowlite_c.dll imports it, and it was the one CRT member not staged.
$crtNames = @('vcruntime140.dll', 'vcruntime140_threads.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'concrt140.dll', 'vccorlib140.dll')
$bundleBin = Join-Path $InstallDir 'bin'
New-Item -Path $bundleBin -ItemType Directory -Force | Out-Null
$crtStaged = 0
foreach ($crt in $crtNames) {
    $src = if (Test-Path (Join-Path "$pyRoot\DLLs" $crt)) { Join-Path "$pyRoot\DLLs" $crt } elseif ($redistArm64 -and (Test-Path (Join-Path $redistArm64.FullName $crt))) { Join-Path $redistArm64.FullName $crt } else { $null }
    if (-not $src) { continue }
    if ((Get-PeFileMachine -Path$src) -ne $wantMachine) { throw "Target CPython: CRT candidate $src is not target-arch -- refusing to stage it" }
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
# Mirror the toolchain layer's slimming: externals and ARM64 obj are build
# residue. PCbuild\arm64 itself STAYS in C:\temp\cpython — Get-TargetBuildPython
# resolves link inputs there for the consumer builds later in this chain.
foreach ($d in @("$SourceDir\externals", "$SourceDir\PCbuild\obj")) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'target-cpython'
Write-Host '=== Target CPython build completed ==='
exit 0
