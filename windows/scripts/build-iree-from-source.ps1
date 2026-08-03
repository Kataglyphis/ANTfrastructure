# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\iree-src',
    [string]$InstallDir = '',
    [string]$IreeVersion = '',
    [string]$BuildType = 'Release',
    [switch]$SkipPython
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$IreeVersion = Get-SourceBuildVersion -Value $IreeVersion -EnvironmentVariables @('IREE_VERSION') -DefaultValue 'v3.11.0'

Write-Host "=== IREE source build ($IreeVersion, Ninja+clang-cl) ==="

# IREE vendors LLVM (and ~15 other projects) as submodules; the release tarball
# ships WITHOUT them, so this must be a git clone. Shallow clone + shallow
# submodules: GitHub serves the exact pinned SHAs (allowReachableSHA1InWant),
# which turns a ~4 GB llvm-project history into a ~600 MB checkout.
# Invoke-GitClone is not used because its -Recursive maps to `--recursive`
# WITHOUT `--shallow-submodules`.
if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }
$env:GIT_TERMINAL_PROMPT = '0'
# cmd-shielded: git reports clone progress on stderr, which PS 5.1 under
# EAP=Stop turns into a terminating NativeCommandError.
& cmd /c "git clone --depth 1 --branch $IreeVersion --shallow-submodules --recurse-submodules --jobs 4 https://github.com/iree-org/iree.git `"$SourceDir`" 2>&1" | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "IREE clone failed (exit $LASTEXITCODE): $IreeVersion" }
if (-not (Test-Path (Join-Path $SourceDir 'third_party\llvm-project\llvm\CMakeLists.txt'))) {
    throw 'IREE submodules incomplete: third_party/llvm-project missing after clone'
}

# Canonical preamble: VsDevCmd + pyconfig.h into Include\ (in-tree Windows
# CPython keeps it at PC\pyconfig.h, which CMake's FindPython cannot see —
# configure died there on the first spike) + platform-tag shim + python handle.
$py = Initialize-ToolchainPythonEnvironment

$buildDir = Join-Path $SourceDir 'build'
$ireeInstallDir = Join-Path $InstallDir 'iree'

$pythonBindings = 'OFF'
if (-not $SkipPython -and (Test-Path $py.Exe)) {
    $pythonBindings = 'ON'
    Install-CpythonPip -Python $py
    # numpy: required by the runtime bindings at import; nanobind is vendored.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'wheel', 'setuptools', 'numpy')
}

# GPU lane: CUDA HAL driver dlopens nvcuda.dll at runtime and the CUDA compiler
# target emits PTX through IREE's own NVPTX backend -- neither needs nvcc, so
# they are safe to enable whenever the lane is nvidia.
$gpuEnv = Get-GpuEnvironment
$cudaFlag = if ($gpuEnv.GpuType -eq 'nvidia') { 'ON' } else { 'OFF' }
if ($cudaFlag -eq 'ON') { Write-Host 'NVIDIA lane -> enabling IREE CUDA HAL driver + CUDA target backend (PTX via NVPTX, no nvcc)' }

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    # nanobind EH port: see patches\iree\enable-ehsc.cmake (directory-scope
    # /EHsc for every project; the only injection point that survives LLVM's
    # flag stripping without leaking into the ukernel bitcode cross-clang).
    "-DCMAKE_PROJECT_INCLUDE=$((Join-Path $PSScriptRoot 'patches\iree\enable-ehsc.cmake') -replace '\\', '/')"
    '-DLLVM_ENABLE_RTTI=ON'
    '-DIREE_BUILD_COMPILER=ON'
    '-DIREE_BUILD_TESTS=OFF'
    '-DIREE_BUILD_SAMPLES=OFF'
    # The BuildTools image ships the DIA SDK headers but NOT ATL -- LLVM
    # auto-enables DIA and then dies on atlbase.h. DIA-based PDB reading is
    # irrelevant to IREE; force it off.
    '-DLLVM_ENABLE_DIA_SDK=OFF'
    "-DIREE_BUILD_PYTHON_BINDINGS=$pythonBindings"
    '-DIREE_HAL_DRIVER_VULKAN=ON'
    "-DIREE_HAL_DRIVER_CUDA=$cudaFlag"
    "-DIREE_TARGET_BACKEND_CUDA=$cudaFlag"
)
if ($pythonBindings -eq 'ON') {
    $cmakeExtra += "-DPython3_EXECUTABLE=$($py.Exe -replace '\\', '/')"
}
$cmakeExtra += Get-LlvmArchiverCmakeArg

Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $ireeInstallDir -ExtraArgs $cmakeExtra | Out-Null

Write-Host 'Building IREE (LLVM in-tree -- this may take 60-120 minutes)...'
$buildLog = Join-Path $buildDir 'iree-build.log'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install -InstallConfig $BuildType

# Native gate: a REAL compile+run through the installed tools, not an
# existence check (Server Core taught us binaries can exist and still not run).
$ireeCompile = Join-Path $ireeInstallDir 'bin\iree-compile.exe'
$ireeRun     = Join-Path $ireeInstallDir 'bin\iree-run-module.exe'
foreach ($tool in @($ireeCompile, $ireeRun)) {
    if (-not (Test-Path $tool)) { throw "IREE install incomplete: $tool missing" }
}
# ONE test module for both gates (native + python); MLIR is whitespace-
# insensitive, so the python gate embeds the same text collapsed to one line.
$gateMlir = @'
func.func @abs(%input : tensor<f32>) -> (tensor<f32>) {
  %result = math.absf %input : tensor<f32>
  return %result : tensor<f32>
}
'@
$mlirPath = Join-Path $env:TEMP 'iree-gate.mlir'
$vmfbPath = Join-Path $env:TEMP 'iree-gate.vmfb'
$gateMlir | Set-Content -Path $mlirPath -Encoding ascii
& cmd /c """$ireeCompile"" --iree-hal-target-backends=llvm-cpu ""$mlirPath"" -o ""$vmfbPath"" 2>&1" | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "iree-compile gate failed (exit $LASTEXITCODE)" }
$runOut = & cmd /c """$ireeRun"" --module=""$vmfbPath"" --device=local-task --function=abs --input=f32=-5 2>&1" | Out-String
Write-Host $runOut
if ($LASTEXITCODE -ne 0 -or $runOut -notmatch 'f32=5') { throw 'iree-run-module gate failed (abs(-5) != 5)' }
Write-Host 'iree native gate OK (llvm-cpu compile + local-task run, abs(-5)=5)'
Remove-Item $mlirPath, $vmfbPath -Force -ErrorAction SilentlyContinue

# Python wheels: with IREE_BUILD_PYTHON_BINDINGS=ON the build tree synthesizes
# pip-installable packages at <build>/compiler and <build>/runtime that reuse
# the ninja-built artifacts (the documented dev-install path). --no-build-isolation
# keeps pip inside this env so the wheel packs existing objects instead of
# re-running the whole LLVM build in an isolated tree.
if ($pythonBindings -eq 'ON') {
    # IREE's CleanEggInfo cmdclass deletes the egg-info dir that the SAME
    # wheel build just created (its stale-metadata guard misfires on the
    # Windows path layout) and setuptools then dies with 'Cannot update time
    # stamp of directory ... egg-info' (spike round 8). The guard only
    # protects REUSED trees; this tree is pristine every build, so neutralize
    # the rmtree. Generated-file edit by policy (like ffmpeg's config.mak):
    # these setup.py files are synthesized into the build tree at configure.
    foreach ($setupPy in @((Join-Path $buildDir 'compiler\setup.py'), (Join-Path $buildDir 'runtime\setup.py'))) {
        if (Test-Path $setupPy) {
            $content = [System.IO.File]::ReadAllText($setupPy)
            $patched = $content -replace 'shutil\.rmtree\(d, ignore_errors=True\)', 'print(f"kataglyphis: keeping fresh egg-info {d}")'
            if ($patched -ne $content) {
                [System.IO.File]::WriteAllText($setupPy, $patched)
                Write-Host "Neutralized CleanEggInfo rmtree in $setupPy"
            }
        }
    }
    foreach ($pkg in @(
        @{ Dir = 'compiler'; Module = 'iree.compiler' },
        @{ Dir = 'runtime';  Module = 'iree.runtime' }
    )) {
        $pkgDir = Join-Path $buildDir $pkg.Dir
        if (-not (Test-Path (Join-Path $pkgDir 'setup.py'))) {
            throw "IREE python package dir missing setup.py: $pkgDir"
        }
        $wheelOut = Join-Path $SourceDir "dist-$($pkg.Dir)"
        Write-Host "Building IREE $($pkg.Dir) wheel (reusing the ninja build tree)..."
        Invoke-CpythonPip -Python $py -Arguments @('wheel', $pkgDir, '--no-deps', '--no-build-isolation', '-w', $wheelOut)
        Install-StagedPythonWheel -Python $py -SourceDir $wheelOut -ModuleName $pkg.Module | Out-Null
    }
    # End-to-end binding gate: compile MLIR through the python compiler API and
    # execute it on the python runtime -- proves the two wheels interoperate.
    $pyGate = Join-Path $env:TEMP 'iree-py-gate.py'
    @"
import numpy as np
import iree.compiler.tools as tools
import iree.runtime as rt
MLIR = '$($gateMlir -replace '\s+', ' ')'
vmfb = tools.compile_str(MLIR, target_backends=["llvm-cpu"])
module = rt.load_vm_flatbuffer(vmfb, driver="local-task")
# tensor<f32> inputs must be numpy arrays -- a bare python float dies in the
# VM marshaling layer with FAILED_PRECONDITION (list.c), spike round 10.
value = float(module.abs(np.asarray(-5.0, dtype=np.float32)).to_host())
assert value == 5.0, value
print("iree python gate OK: abs(-5) =", value)
"@ | Set-Content -Path $pyGate -Encoding ascii
    cmd.exe /c """$($py.Exe)"" ""$pyGate"" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "IREE python end-to-end gate failed (exit $LASTEXITCODE)" }
    Remove-Item $pyGate -Force -ErrorAction SilentlyContinue
}

Remove-SourceBuildTree -Path $SourceDir


Write-Host '=== IREE source build completed ==='
Write-Host "Artifacts at: $ireeInstallDir"

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0