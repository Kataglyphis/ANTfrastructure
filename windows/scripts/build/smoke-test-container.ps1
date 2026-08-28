# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Comprehensive smoke test for the Windows Kataglyphis container image.

.DESCRIPTION
    Runs inside the container (or on the build host) and validates every build
    tool, compiler, library and AI runtime the image ships, section by section.

.EXAMPLE
    pwsh -File smoke-test-container.ps1
#>

param(
    [switch]$SkipCudaTests,
    # Makes a missing CUDA_ROOT a loud FAILURE instead of the CPU-lane skip.
    [switch]$ExpectGpu,
    [switch]$ExitOnFirstFailure,
    # COVERAGE FLOORS (#44): a gate that cannot tell "everything passed" from "nothing ran" is
    # worse than no gate. -MinPassed floors passes, -MaxSkipped caps skips (-1 = no ceiling);
    # the 0 / -1 defaults keep hand invocations behaving exactly as before.
    [int]$MinPassed = 0,
    [int]$MaxSkipped = -1
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# The assertion harness lives in a module so it can be unit-tested without a built image.
# #108: container mounts are FLAT (C:\bkmnt, C:\temp\scripts) while the repo is
# scripts/<group>/ -- shared assets sit beside this script, or one level up.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSmokeTest.Common.psm1') -Force

# TARGET-arch facts (vcpkg triplet, PE machine, wheel tag). Imported directly because this
# script pulls in no WindowsSourceBuild.Common; the module is deliberately dependency-free.
# Unset WINDOWS_TARGET_ARCH => every accessor returns the amd64 value.
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1') -Force
# CROSS LANE: sections 1-6 and 14-16 exercise the amd64 HOST toolchain and pass identically on a
# cross image; only the PAYLOAD (8-13, 17, 18, 20-22) is aarch64 and unrunnable here, so those
# skip as SECTIONS while §19's pointer list is arch-filtered. Floors: $sectionFloors' Arm64 column.
$smokeCross = Test-WindowsCrossTarget

# Must precede the first assertion: zeroes the counters and hands the module
# -ExitOnFirstFailure, which it cannot read out of this script's scope.
Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure

# GPU-lane discriminator: the NVIDIA EP/codec probes below would FAIL on a legitimate CPU-only
# image. Keyed on CUDA_ROOT, baked Machine-wide only on the nvidia lane. DirectML is NOT gated --
# it is DX12-based and built unconditionally, so it is checked always.
$script:gpuNvidia = (-not $SkipCudaTests) -and (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CUDA_ROOT')))

function Get-CommandVersion {
    param([string]$Name)
    try {
        $ver = & $Name --version 2>&1 | Select-Object -First 1
        return $ver
    } catch { return $null }
}

# Hand-encoded 63-byte ONNX ModelProto (opset 13, one Identity node x:float[1] -> y), shared by
# the native (§8) and python (§20) probes -- real inference with zero external model files.
$script:identityOnnxBytes = [byte[]]@(
    0x08,0x08,0x3A,0x37,0x0A,0x10,0x0A,0x01,0x78,0x12,0x01,0x79,0x22,0x08,0x49,0x64,
    0x65,0x6E,0x74,0x69,0x74,0x79,0x12,0x01,0x67,0x5A,0x0F,0x0A,0x01,0x78,0x12,0x0A,
    0x0A,0x08,0x08,0x01,0x12,0x04,0x0A,0x02,0x08,0x01,0x62,0x0F,0x0A,0x01,0x79,0x12,
    0x0A,0x0A,0x08,0x08,0x01,0x12,0x04,0x0A,0x02,0x08,0x01,0x42,0x02,0x10,0x0D)

# One-op MLIR module (abs(-5)=5) shared by §20 and §22; MLIR is whitespace-insensitive so the
# one-liner works both inline and as a file. No double quotes: PS 5.1 strips them from -c strings.
$script:ireeGateMlir = 'func.func @abs(%input : tensor<f32>) -> (tensor<f32>) { %result = math.absf %input : tensor<f32> return %result : tensor<f32> }'

# Expected versions come from versions.env, not literals that silently drift on a bump: the
# baked Machine env is authoritative in-container, the repo file is the host-side fallback.
$script:versionsFromFile = @{}
$repoVersions = Join-Path $scriptAssetRoot '..\..\linux\scripts\01-core\versions.env'
$sharedModule = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
# Host-side only; the module guard keeps the suite runnable in an image with no modules dir.
if ((Test-Path $repoVersions) -and (Test-Path $sharedModule)) {
    Import-Module $sharedModule -Force
    $script:versionsFromFile = ConvertFrom-VersionsEnv -Path $repoVersions
}

# Imported conditionally with local fallbacks so the suite stays runnable in an image whose
# modules dir is broken. The fallbacks mirror the module functions exactly -- keep them in sync.
$containerImageModule = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (Test-Path $containerImageModule) {
    Import-Module $containerImageModule -Force
}
if (-not (Get-Command Resolve-ContainerImageValue -ErrorAction SilentlyContinue)) {
    function Resolve-ContainerImageValue {
        param(
            [AllowEmptyString()][string]$Value = '',
            [string]$EnvironmentVariable = '',
            [AllowEmptyString()][string]$DefaultValue = '',
            [switch]$TrimVPrefix
        )
        $resolved = $DefaultValue
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $resolved = $Value
        } elseif (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
            $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
            if (-not [string]::IsNullOrWhiteSpace($environmentValue)) { $resolved = $environmentValue }
        }
        if ($TrimVPrefix -and $null -ne $resolved) { $resolved = ([string]$resolved).TrimStart('v') }
        return $resolved
    }
}
if (-not (Get-Command Resolve-VsBuildToolsRoot -ErrorAction SilentlyContinue)) {
    function Resolve-VsBuildToolsRoot {
        param([string]$VsMajor = '')
        if ([string]::IsNullOrWhiteSpace($VsMajor)) {
            $VsMajor = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }
        }
        foreach ($programFiles in @('C:\Program Files', 'C:\Program Files (x86)')) {
            $candidate = Join-Path $programFiles ("Microsoft Visual Studio\{0}\BuildTools" -f $VsMajor)
            if (Test-Path (Join-Path $candidate 'Common7\Tools\VsDevCmd.bat')) { return $candidate }
        }
        return $null
    }
}

function Get-ExpectedVersion {
    # Wraps Resolve-ContainerImageValue so this gate and the setup-/verify-time gates normalize a
    # tag-style leading 'v' through the SAME code path. Precedence: env > versions.env > literal.
    param([string]$Key, [string]$Fallback)
    $fileValue = ''
    if ($script:versionsFromFile.ContainsKey($Key)) { $fileValue = [string]$script:versionsFromFile[$Key] }
    $default = if (-not [string]::IsNullOrWhiteSpace($fileValue)) { $fileValue } else { $Fallback }
    return Resolve-ContainerImageValue -EnvironmentVariable $Key -DefaultValue $default -TrimVPrefix
}

# ============================================================================
Write-TestHeader '1. Build Tools'
# ============================================================================
# msbuild comes from VS Build Tools; the rest from scoop/LLVM.
foreach ($tool in 'git', 'cmake', 'ninja', 'clang-cl', 'lld-link', 'llvm-lib', 'msbuild', 'nuget') {
    Assert-CommandExists $tool
}

# Well-formedness only, deliberately: verify-toolchain.ps1 asserts LLVM_WINDOWS_VERSION at base
# build time, and this suite also runs against PUBLISHED images whose clang legitimately predates
# the current pin. A disagreeing baked pin warns; failing it would kill the regression gate.
$clangVer = Get-CommandVersion 'clang-cl'
Assert-Test -Name "clang-cl version" -Condition { $clangVer -ne $null } -FailMessage "Could not get clang-cl version"
Assert-Test -Name "clang-cl version string" -Condition { $clangVer -match '\d+\.\d+' } -FailMessage "clang-cl did not report a well-formed version"
if ($env:LLVM_WINDOWS_VERSION -and $clangVer -and ("$clangVer" -notmatch [regex]::Escape($env:LLVM_WINDOWS_VERSION))) {
    Write-Warning ("clang-cl reports '$clangVer' but this image's LLVM_WINDOWS_VERSION pin is " +
        "'$env:LLVM_WINDOWS_VERSION' - expected for an image built before the pin moved; " +
        'unexpected for a fresh base build (verify-toolchain.ps1 would have failed it).')
}

# The artifact's own record of which compiler built it (finalize-container.ps1). SKIP, not fail:
# the file is additive and this suite must stay usable against published images.
$manifestPath = 'C:\toolchain-manifest.json'
if (-not (Test-Path $manifestPath)) {
    Skip-Test "toolchain provenance manifest ($manifestPath absent — image predates it)"
} else {
    Assert-Test -Name 'toolchain manifest is valid JSON with a resolved compiler' -Condition {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $m.schema -and $m.pinned -and $m.pinned.llvm -and $m.pinned.llvm.resolved
    } -FailMessage "$manifestPath is unreadable or records no resolved clang-cl"
}

$cmakeVer = Get-CommandVersion 'cmake'
Assert-Test -Name "cmake version" -Condition { $cmakeVer -ne $null } -FailMessage "Could not get cmake version"

# Pin assert: catches a stale base layer riding into the final image.
$cmakeExpected = Get-ExpectedVersion 'CMAKE_VERSION' ''
if ($cmakeExpected) {
    Assert-Test -Name "cmake matches versions.env pin ($cmakeExpected)" -Condition {
        $cmakeVer -match [regex]::Escape($cmakeExpected)
    } -FailMessage "cmake banner '$cmakeVer' does not contain pinned $cmakeExpected -- stale base layer shipped?"
} else {
    Skip-Test 'cmake pin assert (CMAKE_VERSION not resolvable from env or versions.env)'
}

# ============================================================================
Write-TestHeader '2. Python (source-built)'
# ============================================================================
Assert-CommandExists 'python'
# Select-Object -First 2, not [0..1]: a single-part version would pad with $null and yield '3.'.
$pyMajorMinor = ((Get-ExpectedVersion 'PYTHON_VERSION' '3.14') -split '\.' | Select-Object -First 2) -join '.'
Assert-Test -Name "Python is $pyMajorMinor.x" -Condition {
    $ver = & python --version 2>&1
    return $ver -match ([regex]::Escape($pyMajorMinor) + '\.')
} -FailMessage "Python version is not $pyMajorMinor.x"

# TEMP_DIR is baked in-container but typically unset on a build host -- a bare
# Join-Path $env:TEMP_DIR would throw there before any test ran.
$cpythonDir = Join-Path ($env:TEMP_DIR ?? 'C:\temp') 'cpython'
# PCbuild\amd64 on BOTH lanes and NOT arch-parameterized: this is the HOST interpreter every
# image's `python` resolves to. Only the wheel TAG follows WINDOWS_TARGET_ARCH.
Assert-Test -Name "Python source-built from $cpythonDir" -Condition {
    (Test-Path "$cpythonDir\PCbuild\amd64\python.exe") -or
    (Test-Path "$cpythonDir\PCbuild\amd64\python3.dll")
} -FailMessage "Python source build artifacts not found at $cpythonDir"

Assert-Test -Name "Python pip available" -Condition {
    # Exit-code based: stderr is merged, so a FAILING pip still emitted a non-null first
    # object and false-passed the old object-based check.
    & python -m pip --version 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "pip not available"

# Exact pin, not just major.minor: a stale toolchain layer surviving a
# PYTHON_VERSION bump would still pass the x.y check above.
$pyExpected = Get-ExpectedVersion 'PYTHON_VERSION' ''
if ($pyExpected) {
    Assert-Test -Name "python matches versions.env pin ($pyExpected)" -Condition {
        (& python --version 2>&1) -match [regex]::Escape($pyExpected)
    } -FailMessage "python --version is not the pinned $pyExpected -- stale toolchain layer shipped?"
}

# Source-built CPython silently OMITS optional extension modules whose deps were missing at build
# time; each import here loads a real .pyd plus its dependent DLLs.
Assert-PythonSnippet -Name "Python stdlib extension modules import (ssl/sqlite3/zlib/ctypes/bz2/lzma)" `
    -Code "import ssl, sqlite3, zlib, ctypes, bz2, lzma, hashlib, socket; print('stdlib-ok')" `
    -ExpectMatch @('stdlib-ok') `
    -FailMessage "one or more stdlib extension modules failed to import (dep missing at CPython build time?)"

# ============================================================================
Write-TestHeader '3. Rust Toolchain'
# ============================================================================
Assert-CommandExists 'cargo'
Assert-CommandExists 'rustc'
Assert-CommandExists 'rustup'

# Mirrors Cargokit's own rustup probe shape, and catches the toolchain-LESS rustup failure mode
# -- see docs/windows-builds.md, "Rust toolchain".
Assert-Test -Name 'rustup resolves an active toolchain' -Condition {
    & rustup show active-toolchain 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage 'rustup show active-toolchain failed (toolchain-less rustup shipped?)'
Assert-Test -Name 'rustup which cargo resolves' -Condition {
    & rustup which cargo 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage 'rustup which cargo failed (proxy shims resolve no real toolchain?)'

# Baked so Flutter+Rust consumers skip a minutes-long cold `cargo install` per
# fresh container (setup-rust-toolchain.ps1).
Assert-Test -Name 'flutter_rust_bridge_codegen available' -Condition {
    & flutter_rust_bridge_codegen --version 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage 'flutter_rust_bridge_codegen missing or broken (bake step in setup-rust-toolchain.ps1 failed?)'

# Well-formed semver only: Rust is DELIBERATELY unpinned on the Windows lane (RUST_VERSION pins
# Linux), so a pin comparison would fail this image's own smoke test on every Rust release.
Assert-Test -Name 'Rust version (well-formed)' -Condition {
    $ver = & rustc --version 2>&1
    return $ver -match '\d+\.\d+\.\d+'
} -FailMessage "rustc --version did not report a well-formed version"

# rustc --version only proves the binary exists; this proves the toolchain can actually
# COMPILE + LINK (via the MSVC linker) + RUN -- catches a broken linker / missing target / std.
Assert-Test -Name 'rustc compiles + links + runs a program' -Condition {
    $d = Join-Path $env:TEMP 'kataglyphis-smoke-rust'
    Initialize-SmokeScratch -Path $d
    $src = Join-Path $d 'main.rs'
    'fn main() { println!("rust ok"); }' | Set-Content -Path $src -Encoding ASCII
    $exe = Join-Path $d 'main.exe'
    & rustc $src -o $exe 2>&1 | Out-Null
    $ok = $false
    if (($LASTEXITCODE -eq 0) -and (Test-Path $exe)) {
        $out = (& $exe 2>&1 | Out-String)
        $ok = ($LASTEXITCODE -eq 0) -and ($out -match 'rust ok')
    }
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    return $ok
} -FailMessage 'rustc could not compile/link/run a hello-world (broken MSVC linker or std?)'

# ============================================================================
Write-TestHeader '4. LLVM / Clang + Flutter + WiX'
# ============================================================================
Assert-CommandExists 'flutter'
Assert-Test -Name "Flutter works" -Condition {
    $output = & flutter --version 2>&1 | Out-String
    return $output -match 'Flutter'
} -FailMessage "Flutter --version failed"

Assert-FileExists -Path 'C:\WiX\wix.exe' -Description 'WiX toolset'
foreach ($tool in 'sccache', 'cppcheck', '7z', 'uv', 'nano') {
    Assert-CommandExists $tool
}

# ============================================================================
Write-TestHeader '5. Visual Studio Build Tools'
# ============================================================================
$vsVer = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }
$msvcPlatformToolset = "v$($vsVer)0"
# Shared probe: setup-vs.ps1 accepts BOTH Program Files roots, and hardcoding (x86) failed a
# perfectly good 64-bit-rooted install.
$vsBuildToolsRoot = Resolve-VsBuildToolsRoot -VsMajor $vsVer
if ($vsBuildToolsRoot) {
    Assert-FileExists -Path (Join-Path $vsBuildToolsRoot 'Common7\Tools\VsDevCmd.bat') -Description 'VsDevCmd.bat'
} else {
    Assert-Test -Name 'VsDevCmd.bat' -Condition { $false } -FailMessage "VS Build Tools $vsVer not found under either Program Files root"
}

Assert-Test -Name "MSBuild works (ClangCL toolset available)" -Condition {
    $msbuildOutput = & msbuild /version 2>&1 | Out-String
    return $msbuildOutput -match "$vsVer\."
} -FailMessage "MSBuild /version doesn't show VS $vsVer"

Assert-EnvVarSet -Name 'VCToolsInstallDir'

if ($vsBuildToolsRoot) {
    $clangClToolsetPath = Join-Path $vsBuildToolsRoot "MSBuild\Microsoft\VC\$msvcPlatformToolset\Platforms\x64\PlatformToolsets\ClangCL"
    Assert-DirectoryExists -Path $clangClToolsetPath -Description 'ClangCL MSBuild toolset'
} else {
    Assert-Test -Name 'ClangCL MSBuild toolset' -Condition { $false } -FailMessage "VS Build Tools $vsVer not found, so the ClangCL toolset cannot exist"
}

# ============================================================================
Write-TestHeader '6. Vulkan SDK'
# ============================================================================
Assert-CommandExists 'glslc'
Assert-CommandExists 'vulkaninfoSDK'
Assert-EnvVarSet -Name 'VULKAN_SDK'

# glslc on PATH != working; compile a trivial shader to SPIR-V. Needs no GPU/ICD (unlike
# vulkaninfo, which we deliberately do NOT run headless), so it exercises the real toolchain.
Assert-Test -Name 'glslc compiles a shader to SPIR-V' -Condition {
    $d = Join-Path $env:TEMP 'kataglyphis-smoke-glslc'
    Initialize-SmokeScratch -Path $d
    $src = Join-Path $d 'smoke.vert'
    "#version 450`nvoid main() { gl_Position = vec4(0.0); }" | Set-Content -Path $src -Encoding ASCII
    $spv = Join-Path $d 'smoke.spv'
    & glslc $src -o $spv 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $spv) -and ((Get-Item $spv).Length -gt 0)
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    return $ok
} -FailMessage 'glslc failed to compile a trivial shader to SPIR-V'

# ============================================================================
Write-TestHeader '7. CUDA Toolkit + cuDNN'
# ============================================================================
# Gate on CUDA_ROOT, not just -SkipCudaTests: a CPU-only image legitimately has no nvcc/cuDNN.
if ($script:gpuNvidia) {
    Assert-CommandExists 'nvcc'
    $cudaMajorMinor = ((Get-ExpectedVersion 'CUDA_VERSION' '13.3') -split '\.' | Select-Object -First 2) -join '.'
    Assert-Test -Name "nvcc version is $cudaMajorMinor.x" -Condition {
        $ver = & nvcc --version 2>&1 | Out-String
        return $ver -match [regex]::Escape($cudaMajorMinor)
    } -FailMessage "nvcc version is not $cudaMajorMinor.x"

    Assert-EnvVarSet -Name 'CUDA_ROOT'
    Assert-EnvVarSet -Name 'CUDA_PATH'

    Assert-DirectoryExists -Path $env:CUDA_ROOT -Description "CUDA_ROOT directory"
    Assert-FileExists -Path (Join-Path $env:CUDA_ROOT 'bin\nvcc.exe') -Description 'nvcc.exe in CUDA_ROOT\bin'

    # cuDNN
    Assert-EnvVarSet -Name 'CUDNN_ROOT'
    $cudnnRoot = [Environment]::GetEnvironmentVariable('CUDNN_ROOT')
    Assert-DirectoryExists -Path $cudnnRoot -Description "CUDNN_ROOT directory"

    # Check cuDNN headers/libs/DLLs recursively as they may be in subdirs.
    # @(...) so a single-FileInfo result still exposes .Count (scalar trap).
    $cudnnHeaders = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.h' -Recurse -ErrorAction SilentlyContinue)
    $cudnnLibs = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue)
    $cudnnDlls = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue)

    Assert-Test -Name "cuDNN headers (cudnn*.h)" -Condition { $cudnnHeaders.Count -gt 0 } -FailMessage "No cuDNN headers found"
    Assert-Test -Name "cuDNN libs (cudnn*.lib)" -Condition { $cudnnLibs.Count -gt 0 } -FailMessage "No cuDNN libs found"
    Assert-Test -Name "cuDNN DLLs (cudnn*.dll)" -Condition { $cudnnDlls.Count -gt 0 } -FailMessage "No cuDNN DLLs found"

    # Proves nvcc can COMPILE device code (host_config/nv-target stubs + cl.exe integration).
    # PTX only -- no GPU device here; -ccbin points nvcc at the MSVC host compiler, which is not
    # on the bare PATH.
    $nvccCcbin = if ($env:VCToolsInstallDir) { Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64' } else { $null }
    Assert-Test -Name 'nvcc compiles a CUDA kernel to PTX' -Condition {
        $d = Join-Path $env:TEMP 'kataglyphis-smoke-cuda'
        Initialize-SmokeScratch -Path $d
        $src = Join-Path $d 'k.cu'
        "__global__ void k(float* a) { a[threadIdx.x] *= 2.0f; }`nint main() { return 0; }" | Set-Content -Path $src -Encoding ASCII
        $ptx = Join-Path $d 'k.ptx'
        $nvccArgs = @('-std=c++17', '-ptx', $src, '-o', $ptx)
        if ($nvccCcbin) { $nvccArgs += @('-ccbin', $nvccCcbin) }
        & nvcc @nvccArgs 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $ptx) -and ((Get-Item $ptx).Length -gt 0)
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        return $ok
    }.GetNewClosure() -FailMessage 'nvcc could not compile a trivial kernel to PTX (host_config/nv-target/cl.exe integration?)'

    # Existence != loadable: link + call a HOST-only cuDNN API (cudnnGetVersion needs no GPU)
    # to prove the cuDNN header/lib/DLL actually link + load together.
    $cudnnHdr = $cudnnHeaders | Where-Object { $_.Name -eq 'cudnn.h' } | Select-Object -First 1
    $cudnnMainLib = $cudnnLibs | Where-Object { $_.Name -eq 'cudnn.lib' } | Select-Object -First 1
    $cudnnMainDll = $cudnnDlls | Where-Object { $_.Name -like 'cudnn64_*.dll' } | Select-Object -First 1
    if ($cudnnHdr -and $cudnnMainLib -and $cudnnMainDll -and $env:CUDA_ROOT) {
        Assert-NativeLinkRun -Name 'cuDNN links + host API works (cudnnGetVersion)' -WorkName 'cudnn' -Source @'
#include <cudnn.h>
#include <cstdio>
int main() { std::printf("cudnn %zu\n", (size_t)cudnnGetVersion()); return 0; }
'@ -IncludeDirs @($cudnnHdr.DirectoryName, (Join-Path $env:CUDA_ROOT 'include')) -LibDir $cudnnMainLib.DirectoryName -LibName $cudnnMainLib.Name -DllDir $cudnnMainDll.DirectoryName -ExpectMatch 'cudnn' -FailMessage 'cuDNN did not compile/link/run (cudnnGetVersion) -- header/lib/DLL mismatch or missing dependent DLL'
    } else {
        Skip-Test 'cuDNN link+run (cudnn.h/.lib/cudnn64_*.dll not all found)'
    }
} elseif ($ExpectGpu) {
    # -ExpectGpu: the caller asserts this is an nvidia-lane image, so a missing
    # CUDA_ROOT (or -SkipCudaTests) is a real defect here, not a CPU-only lane.
    Assert-Test -Name 'CUDA section runs (-ExpectGpu)' -Condition { $false } -FailMessage 'caller passed -ExpectGpu but CUDA_ROOT is not set (or -SkipCudaTests was passed) -- nvidia image lost its baked CUDA env?'
} else {
    Skip-Test 'CUDA/cuDNN tests skipped (-SkipCudaTests, or CPU-only image without CUDA_ROOT; pass -ExpectGpu to fail loudly instead when the image should be on the nvidia lane)'
}

# ============================================================================
Write-TestHeader '8. ONNX Runtime (source-built)'
if ($smokeCross) {
    Skip-Test "section 8 (ONNX Runtime (source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$onnxRoot = [Environment]::GetEnvironmentVariable('ONNX_ROOT')
if ($onnxRoot) {
    Assert-DirectoryExists -Path $onnxRoot -Description "ONNX_ROOT"
    # Recursive search: ORT installs headers nested (include\onnxruntime\...), not flat
    Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime_cxx_api.h' -Description 'ONNX C++ API header'
    Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime_c_api.h' -Description 'ONNX C API header'
    Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime*.lib' -Description 'ONNX lib files'
    Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime*.dll' -Description 'ONNX DLL files'

    # Existence != loadable: compile+link+run against the ORT C API to prove the header,
    # import lib, and onnxruntime.dll actually work together at runtime.
    $onnxCApiHdr = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime_c_api.h' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $onnxMainLib = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime.lib' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $onnxDll     = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onnxCApiHdr -and $onnxMainLib -and $onnxDll) {
        # Shared link inputs for every ORT probe below (same header/lib/DLL triple).
        $onnxLink = @{
            IncludeDirs = @($onnxCApiHdr.DirectoryName)
            LibDir      = $onnxMainLib.DirectoryName
            LibName     = $onnxMainLib.Name
            DllDir      = $onnxDll.DirectoryName
        }
        Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime loads + C API ABI works (OrtGetApiBase)' -WorkName 'onnx' -Source @'
#include <onnxruntime_c_api.h>
#include <cstdio>
int main() {
    const OrtApiBase* base = OrtGetApiBase();
    if (!base) return 2;
    if (!base->GetApi(ORT_API_VERSION)) return 3;
    std::printf("onnxruntime %s\n", base->GetVersionString());
    return 0;
}
'@ -ExpectMatch 'onnxruntime' -FailMessage 'ONNX Runtime C API did not compile/link/run (header+lib+DLL mismatch or missing dependent DLL)'

        # Proves the RUNTIME works end-to-end -- graph load, session init, Run() -- on the CPU EP
        # with the shared in-memory Identity model. No external files, no GPU device.
        $ortModelDir = Join-Path $env:TEMP 'kataglyphis-smoke-ort-model'
        Initialize-SmokeScratch -Path $ortModelDir
        [IO.File]::WriteAllBytes((Join-Path $ortModelDir 'identity.onnx'), $script:identityOnnxBytes)
        $onnxCxxHdr = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime_cxx_api.h' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onnxCxxHdr) {
            $onnxInferLink = @{
                IncludeDirs = @(@($onnxCApiHdr.DirectoryName, $onnxCxxHdr.DirectoryName) | Select-Object -Unique)
                LibDir      = $onnxMainLib.DirectoryName
                LibName     = $onnxMainLib.Name
                DllDir      = $onnxDll.DirectoryName
            }
            Assert-NativeLinkRun @onnxInferLink -Name 'ONNX Runtime CPU inference end-to-end (session create + Run)' -WorkName 'onnx-infer' -Source @'
#include <onnxruntime_cxx_api.h>
#include <cstdio>
#include <cstdlib>
#include <string>
int main() {
    const char* temp = std::getenv("TEMP");
    if (!temp) return 4;
    std::string p = std::string(temp) + "\\kataglyphis-smoke-ort-model\\identity.onnx";
    std::wstring wp(p.begin(), p.end());
    Ort::Env env(ORT_LOGGING_LEVEL_ERROR, "smoke");
    Ort::SessionOptions so;
    Ort::Session session(env, wp.c_str(), so);
    float v = 42.0f; int64_t shape[1] = {1};
    Ort::MemoryInfo mi = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    Ort::Value in = Ort::Value::CreateTensor<float>(mi, &v, 1, shape, 1);
    const char* inNames[] = {"x"}; const char* outNames[] = {"y"};
    auto outs = session.Run(Ort::RunOptions{nullptr}, inNames, &in, 1, outNames, 1);
    float o = outs[0].GetTensorMutableData<float>()[0];
    std::printf("ort_cpu_infer=%s\n", (o == 42.0f) ? "ok" : "bad");
    return (o == 42.0f) ? 0 : 1;
}
'@ -ExpectMatch 'ort_cpu_infer=ok' -FailMessage 'ORT session create/Run failed on the CPU EP (runtime graph init broken despite the C API loading)'
        } else {
            Skip-Test 'ORT CPU inference (onnxruntime_cxx_api.h not found)'
        }
        Remove-Item $ortModelDir -Recurse -Force -ErrorAction SilentlyContinue

        # One EP-enumeration TU serves both gates below; each assertion matches only its flags.
        $onnxEpProbeSource = @'
#include <onnxruntime_c_api.h>
#include <cstdio>
#include <cstring>
int main() {
    const OrtApi* api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) return 2;
    char** providers = nullptr; int n = 0;
    if (api->GetAvailableProviders(&providers, &n) != nullptr) return 3;
    int cuda = 0, trt = 0, dml = 0;
    for (int i = 0; i < n; ++i) {
        if (std::strcmp(providers[i], "CUDAExecutionProvider") == 0) cuda = 1;
        if (std::strcmp(providers[i], "TensorrtExecutionProvider") == 0) trt = 1;
        if (std::strcmp(providers[i], "DmlExecutionProvider") == 0) dml = 1;
    }
    api->ReleaseAvailableProviders(providers, n);
    std::printf("providers cuda=%d trt=%d dml=%d\n", cuda, trt, dml);
    return 0;
}
'@

        # GetAvailableProviders() enumerates the providers COMPILED IN (no GPU device needed), the
        # real signal that USE_CUDA/USE_TENSORRT took effect -- a CPU fallback still passes above.
        if ($script:gpuNvidia) {
            # Cheap backstop first: the provider shared libs must exist by exact name.
            Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime_providers_cuda.dll' -Description 'ONNX CUDA provider DLL (onnxruntime_providers_cuda.dll)'
            Assert-ArtifactPresent -Root $onnxRoot -Filter 'onnxruntime_providers_tensorrt.dll' -Description 'ONNX TensorRT provider DLL (onnxruntime_providers_tensorrt.dll)'
            # The real gate: enumerate compiled-in EPs and require CUDA + TensorRT to be present.
            Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime CUDA + TensorRT EPs available (GetAvailableProviders)' -WorkName 'onnx-eps' -Source $onnxEpProbeSource -ExpectMatch 'cuda=1 trt=1' -FailMessage 'ONNX Runtime does not expose CUDAExecutionProvider + TensorrtExecutionProvider (GPU EPs missing -- build fell back to CPU?)'
        }

        # USE_DML=ON on the clang-cl lane via the "[clang-cl DML fix]" header patch (llvm #57700).
        # If the redist shipped, require the EP to register; a future no-DML build SKIPs.
        $dmlRedist = Get-ChildItem -Path $onnxRoot -Filter 'DirectML.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dmlRedist) {
            Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime DirectML EP available (GetAvailableProviders)' -WorkName 'onnx-dml' -Source $onnxEpProbeSource -ExpectMatch 'dml=1' -FailMessage 'ONNX Runtime shipped DirectML.dll but does not expose DmlExecutionProvider'
        } else {
            # FAIL, don't skip (#46): this branch used to be keyed on the very artifact it
            # verifies, so the EP could vanish with zero red at either end. USE_DML=ON is
            # unconditional, and on the AMD reference host DirectML is the ONLY GPU path.
            Assert-Test -Name 'ONNX Runtime DirectML redist present (USE_DML=ON is unconditional)' `
                -Condition { $false } `
                -FailMessage "DirectML.dll not found under $onnxRoot. ONNX Runtime is built with USE_DML=ON unconditionally, so the redist must ship; Copy-SidecarDll only WARNS when it cannot stage it. On the AMD reference host this is the only working GPU path."
        }
    } else {
        # Root resolved but the probe artifact is gone: that is the defect this section exists for
        # (#46 -- deleting onnxruntime.lib silently dropped 7 assertions and stayed green).
        Assert-Test -Name 'ONNX Runtime link+run prerequisites present' -Condition { $false } `
            -FailMessage 'ONNX_ROOT exists but onnxruntime.lib/.dll/c_api.h are not all found — the install shrank'
    }
} else {
    Skip-Test 'ONNX_ROOT not set'
}

}
# ============================================================================
Write-TestHeader '9. ONNX Runtime GenAI (source-built)'
if ($smokeCross) {
    Skip-Test "section 9 (ONNX Runtime GenAI (source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$genaiRoot = [Environment]::GetEnvironmentVariable('ONNX_GENAI_ROOT')
if ($genaiRoot) {
    Assert-DirectoryExists -Path $genaiRoot -Description "ONNX_GENAI_ROOT"
    # @(...) so a single-FileInfo result still exposes .Count (scalar trap).
    $genaiHdr = @(Get-ChildItem -Path $genaiRoot -Filter 'ort_genai*.h' -Recurse -ErrorAction SilentlyContinue)
    if ($genaiHdr.Count -eq 0) { $genaiHdr = @(Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai.h' -Recurse -ErrorAction SilentlyContinue) }
    Assert-Test -Name 'ONNX GenAI header' -Condition { $genaiHdr.Count -gt 0 } -FailMessage "No GenAI header (ort_genai*.h / onnxruntime-genai.h) found under $genaiRoot"
    Assert-ArtifactPresent -Root $genaiRoot -Filter 'onnxruntime-genai*.lib' -Description 'ONNX GenAI lib files'
    Assert-ArtifactPresent -Root $genaiRoot -Filter 'onnxruntime-genai*.dll' -Description 'ONNX GenAI DLL files'

    # Existence != loadable: LoadLibrary the GenAI DLL with onnxruntime.dll's dir on PATH and
    # resolve a C export -- catches a mismatched dependency no file check can see.
    $genaiDll = Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $onnxRootForGenai = [Environment]::GetEnvironmentVariable('ONNX_ROOT')
    # Capture-then-guard: .DirectoryName on an empty Get-ChildItem result is a null
    # deref (throws under StrictMode, silently $null otherwise).
    $onnxDepDir = $null
    if ($onnxRootForGenai) {
        $onnxDllForGenai = Get-ChildItem -Path $onnxRootForGenai -Filter 'onnxruntime.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onnxDllForGenai) { $onnxDepDir = $onnxDllForGenai.DirectoryName }
    }
    if ($genaiDll) {
        $genaiDepDirs = if ($onnxDepDir) { @($onnxDepDir) } else { @() }
        Assert-DllLoads -Name 'ONNX GenAI DLL loads + C API resolves (OgaConfigClearProviders)' -DllPath $genaiDll.FullName -DependencyDirs $genaiDepDirs -Export 'OgaConfigClearProviders' -FailMessage 'onnxruntime-genai.dll failed to load or its C API symbol is missing (dependent onnxruntime.dll not resolved?)'

        # The nvidia lane also emits onnxruntime-genai-cuda.dll; confirm its dependent chain
        # (CUDA runtime + onnxruntime.dll) resolves.
        if ($script:gpuNvidia) {
            Assert-ArtifactPresent -Root $genaiRoot -Filter 'onnxruntime-genai-cuda.dll' -Description 'ONNX GenAI CUDA DLL (onnxruntime-genai-cuda.dll)'
            $genaiCudaDll = Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai-cuda.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($genaiCudaDll) {
                $cudaBin  = if ($env:CUDA_ROOT) { Join-Path $env:CUDA_ROOT 'bin' } else { $null }
                # Capture-then-guard (same null-deref trap as $onnxDepDir above).
                $cudnnBin = $null
                if ($env:CUDNN_ROOT) {
                    $cudnnDepDll = Get-ChildItem -Path $env:CUDNN_ROOT -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($cudnnDepDll) { $cudnnBin = $cudnnDepDll.DirectoryName }
                }
                $genaiCudaDeps = @($onnxDepDir, $cudaBin, $cudnnBin) | Where-Object { $_ }
                Assert-DllLoads -Name 'ONNX GenAI CUDA DLL loads (CUDA runtime + onnxruntime chain resolves)' -DllPath $genaiCudaDll.FullName -DependencyDirs $genaiCudaDeps -FailMessage 'onnxruntime-genai-cuda.dll failed to load -- a dependent DLL (cudart/cublas/cudnn/onnxruntime) did not resolve'
            }
        }

        # USE_DML=ON compiles the DML provider into the main genai DLL (no separate -dml.dll). The
        # evidence is D3D12Core.dll staged BESIDE it: the DML device loads it from its own module
        # dir at runtime and BUILD_WHEEL=OFF does not auto-copy it. Absent => a no-DML variant.
        $genaiDir = $genaiDll.DirectoryName
        $d3d12Core = Get-ChildItem -Path $genaiRoot -Filter 'D3D12Core.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($d3d12Core) {
            Assert-Test -Name 'ONNX GenAI DirectML: D3D12Core.dll staged beside onnxruntime-genai.dll' `
                -Condition { $d3d12Core.DirectoryName -eq $genaiDir } `
                -FailMessage "D3D12Core.dll is at $($d3d12Core.FullName) but not beside the genai DLL ($genaiDir); the DML device loads it from the genai module dir at runtime"
            # Arch guard: the Agility SDK nuget ships x64/arm64/win32 and a naive recursive copy can
            # grab arm64 first -- read the PE machine so it fails HERE, not at DML device init.
            Assert-Test -Name 'ONNX GenAI DirectML: D3D12Core.dll is x64 (PE machine 0x8664)' `
                -Condition {
                    try { (Get-PeFileMachine -Path $d3d12Core.FullName) -eq 0x8664 } catch { $false }
                } `
                -FailMessage "D3D12Core.dll at $($d3d12Core.FullName) is not an x64 PE -- wrong-arch stage would fail DML device init on the x64 image"
        } else {
            Skip-Test 'GenAI DirectML evidence (D3D12Core.dll absent -- USE_DML=OFF variant)'
        }
    } else {
        Assert-Test -Name 'GenAI load-probe prerequisite present' -Condition { $false } `
            -FailMessage 'ONNX_GENAI_ROOT exists but onnxruntime-genai.dll is missing (a -cuda.dll alone satisfies the glob above — this is the CPU-EP DLL vanishing)'
    }
} else {
    Skip-Test 'ONNX_GENAI_ROOT not set'
}

}
# ============================================================================
Write-TestHeader '10. OpenCV 5 (source-built)'
if ($smokeCross) {
    Skip-Test "section 10 (OpenCV 5 (source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$opencvInclude = [Environment]::GetEnvironmentVariable('OPENCV_INCLUDE')
$opencvRoot = [Environment]::GetEnvironmentVariable('OPENCV_ROOT')
# OpenCV installs per-module libs under <root>\<arch>\vc18\{bin,lib} -- not a single
# opencv_world, and not where OPENCV_BIN/OPENCV_LIB point. Search the whole root so the arch
# dir, the module-vs-world layout and the misdirected env vars all stop mattering.
$opencvSearchRoot = if ($opencvRoot -and (Test-Path $opencvRoot)) { $opencvRoot } elseif ($opencvInclude -and (Test-Path $opencvInclude)) { Split-Path $opencvInclude -Parent } else { $null }

if ($opencvInclude -and (Test-Path $opencvInclude)) {
    Assert-ArtifactPresent -Root $opencvInclude -Filter 'opencv.hpp' -Description 'OpenCV headers (opencv.hpp)'
} else {
    Skip-Test 'OPENCV_INCLUDE not set or not found'
}

if ($opencvSearchRoot) {
    # opencv_core is always built (world only if BUILD_opencv_world=ON).
    Assert-ArtifactPresent -Root $opencvSearchRoot -Filter 'opencv_core*.dll' -Description 'OpenCV core DLL'
    # BULK LOAD TEST (#57): one DLL used to be load-tested and the other ~25 were existence
    # checks. That is the OPENGL32 defect verbatim -- linked fine, failed 0xC0000135 at LOAD on
    # Server Core. CUDA/cuDNN live outside this root, so pass their bins as dependency dirs.
    $cvDepDirs = @(
        $env:CUDA_ROOT, "$env:CUDA_ROOT\bin", "$env:CUDNN_ROOT\bin",
        'C:\runtime\cuda-runtime\bin'
    ) | Where-Object { $_ -and (Test-Path $_) }
    Assert-AllDllsLoad -Name 'every OpenCV DLL loads (full dependent chain, not just opencv_core)' `
        -Root $opencvSearchRoot -DependencyDirs $cvDepDirs -MinimumChecked 5
} else {
    Skip-Test 'OpenCV DLLs (OPENCV_ROOT/INCLUDE not found)'
}

# Existence != loadable: compile+link+run against opencv_core to prove the header,
# core import lib, and core DLL actually work together at runtime.
$cvHpp = if ($opencvInclude -and (Test-Path $opencvInclude)) { Get-ChildItem -Path $opencvInclude -Filter 'core.hpp' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\opencv2\\' } | Select-Object -First 1 } else { $null }
$cvCoreLib = if ($opencvSearchRoot) { Get-ChildItem -Path $opencvSearchRoot -Filter 'opencv_core*.lib' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
$cvCoreDll = if ($opencvSearchRoot) { Get-ChildItem -Path $opencvSearchRoot -Filter 'opencv_core*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
if ($cvHpp -and $cvCoreLib -and $cvCoreDll) {
    # <opencv2/core.hpp> resolves relative to the dir CONTAINING opencv2\ -- core.hpp
    # lives at <inc>\opencv2\core.hpp, so its grandparent is the include root.
    $cvIncDir = Split-Path $cvHpp.DirectoryName -Parent
    Assert-NativeLinkRun -Name 'OpenCV loads + core API works (cv::Mat / CV_VERSION)' -WorkName 'opencv' -Source @'
#include <opencv2/core.hpp>
#include <cstdio>
int main() {
    cv::Mat m(3, 3, CV_8UC1);
    m.setTo(cv::Scalar(7));
    if (m.total() != 9) return 2;
    std::printf("opencv %s\n", CV_VERSION);
    return 0;
}
'@ -IncludeDirs @($cvIncDir) -LibDir $cvCoreLib.DirectoryName -LibName $cvCoreLib.Name -DllDir $cvCoreDll.DirectoryName -ExpectMatch 'opencv' -FailMessage 'OpenCV core API did not compile/link/run (header+core lib+DLL mismatch or missing dependent DLL)'

    # getBuildInformation() embeds the resolved build config, so asserting "NVIDIA CUDA: YES"
    # proves the CUDA backend was compiled in -- no GPU device required. nvidia lane only.
    if ($script:gpuNvidia) {
        Assert-NativeLinkRun -Name 'OpenCV built WITH_CUDA + cuDNN (getBuildInformation)' -WorkName 'opencv-cuda' -Source @'
#include <opencv2/core.hpp>
#include <cstdio>
int main() { std::printf("%s\n", cv::getBuildInformation().c_str()); return 0; }
'@ -IncludeDirs @($cvIncDir) -LibDir $cvCoreLib.DirectoryName -LibName $cvCoreLib.Name -DllDir $cvCoreDll.DirectoryName -ExpectMatch 'NVIDIA CUDA:\s+YES' -FailMessage 'OpenCV getBuildInformation() does not report "NVIDIA CUDA: YES" (CUDA backend not compiled in -- build fell back to CPU?)'
        # The cv::dnn CUDA backend + cudaarithm contrib module ship as their own DLLs.
        Assert-ArtifactPresent -Root $opencvSearchRoot -Filter 'opencv_cudaarithm*.dll' -Description 'OpenCV CUDA arithm module DLL (opencv_cudaarithm*.dll)'
        Assert-ArtifactPresent -Root $opencvSearchRoot -Filter 'opencv_dnn*.dll' -Description 'OpenCV DNN module DLL (opencv_dnn*.dll)'
    }
} else {
    Assert-Test -Name 'OpenCV link+run prerequisites present' -Condition { $false } `
        -FailMessage 'OPENCV_ROOT exists but opencv_core lib/dll or core.hpp are not all found — the install shrank'
}

}
# ============================================================================
Write-TestHeader '11. GStreamer (source-built)'
if ($smokeCross) {
    Skip-Test "section 11 (GStreamer (source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
Assert-CommandExists 'gst-launch-1.0'
Assert-CommandExists 'gst-inspect-1.0'
Assert-Test -Name "GStreamer core plugin available" -Condition {
    $plugins = & gst-inspect-1.0 2>&1 | Out-String
    return $plugins -match 'coreelements'
} -FailMessage "GStreamer coreelements plugin not found"

$gstBin = [Environment]::GetEnvironmentVariable('GSTREAMER_BIN')
Assert-DirectoryExists -Path $gstBin -Description "GSTREAMER_BIN"

# Verify GStreamer can create and run a trivial pipeline. num-buffers=1 is
# essential: a bare fakesrc produces buffers FOREVER and hangs the smoke test.
Assert-Test -Name "GStreamer pipeline creation (fake)" -Condition {
    & gst-launch-1.0 --gst-plugin-path="$gstBin\..\lib\gstreamer-1.0" fakesrc num-buffers=1 ! fakesink 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "GStreamer fakesrc pipeline failed (coreelements broken or gst-launch cannot run)"

# Pin assert: the version actually shipped must match versions.env, catching a
# stale media layer riding into the final image.
$gstExpected = Get-ExpectedVersion 'GSTREAMER_VERSION' ''
if ($gstExpected) {
    Assert-Test -Name "gst-launch matches versions.env pin ($gstExpected)" -Condition {
        (& gst-launch-1.0 --version 2>&1 | Select-Object -First 1) -match [regex]::Escape($gstExpected)
    } -FailMessage "gst-launch-1.0 --version is not the pinned $gstExpected -- stale media layer shipped?"
}

# Consumers resolve GStreamer via pkg_check_modules, which needs the pkg-config BINARY on top of
# the baked PKG_CONFIG_PATH; the modversion assert validates both in one shot.
Assert-CommandExists 'pkg-config'
Assert-Test -Name "pkg-config resolves gstreamer-1.0$(if ($gstExpected) { " ($gstExpected)" })" -Condition {
    $pcVer = (& pkg-config --modversion gstreamer-1.0 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($gstExpected) { return ($pcVer -eq $gstExpected) }
    return ($pcVer -match '^\d+\.\d+')
} -FailMessage "pkg-config --modversion gstreamer-1.0 failed or mismatched versions.env (missing pkg-config binary or broken PKG_CONFIG_PATH)"

# fakesrc/fakesink only exercise coreelements; real buffers prove the video plugin DLLs load
# and negotiate caps at runtime.
Assert-Test -Name "GStreamer real pipeline runs (videotestsrc ! videoconvert ! fakesink)" -Condition {
    & gst-launch-1.0 --gst-plugin-path="$gstBin\..\lib\gstreamer-1.0" videotestsrc num-buffers=5 ! videoconvert ! fakesink 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "videotestsrc pipeline failed (video plugin DLLs broken or missing)"

# ── Mandatory plugin integrations: FATAL, not informational ──────────────────
# The build-time contract lives in Get-RequiredGstPlugin; this is the independent confirmation
# that what was built actually LOADS -- a plugin can compile and still fail to register when a
# sidecar DLL is missing, which only gst-inspect catches.
$requiredGstModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if (Test-Path $requiredGstModule) {
    Import-Module $requiredGstModule -Force -DisableNameChecking
    # Explicit -Arch: the bare call was arch-correct in-container only by coincidence, and
    # silently probes the amd64 contract on a build host without WINDOWS_TARGET_ARCH.
    foreach ($plugin in @(Get-RequiredGstPlugin -Arch (Get-WindowsTargetArch))) {
        Assert-Test -Name "gst-plugin '$($plugin.Name)' is present and loadable" -Condition {
            $global:LASTEXITCODE = 0
            & gst-inspect-1.0 $plugin.Name 2>&1 | Out-Null
            $LASTEXITCODE -eq 0
        } -FailMessage ("mandatory GStreamer plugin '$($plugin.Name)' is MISSING or fails to load. " +
            "It provides $($plugin.Provides). $($plugin.Why). " +
            "Needs pkg-config: $($plugin.NeedsPc -join ', ') at GStreamer build time.")
    }
} else {
    Skip-Test "mandatory gst-plugin assertions (WindowsGstPlugins.Common.psm1 not found at $requiredGstModule -- image predates the contract)"
}

}
# ============================================================================
Write-TestHeader '12. LiteRT (AI Edge runtime, source-built)'
if ($smokeCross) {
    Skip-Test "section 12 (LiteRT (AI Edge runtime, source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$litertRoot = if ($env:LITERT_ROOT) { $env:LITERT_ROOT } else { 'C:\runtime\lib\litert' }
$litertInclude = Join-Path $litertRoot 'include'
$litertLibDir = Join-Path $litertRoot 'lib'
$litertBinDir = Join-Path $litertRoot 'bin'

Assert-DirectoryExists -Path $litertRoot -Description 'LiteRT root dir'
Assert-DirectoryExists -Path $litertInclude -Description 'LiteRT include dir'

if (Test-Path $litertInclude) {
    # NB: -Filter matches file NAMES only -- a path-style filter never matches.
    Assert-ArtifactPresent -Root $litertInclude -Filter 'c_api.h' -Description 'LiteRT C API header'
    Assert-ArtifactPresent -Root $litertInclude -Filter 'interpreter.h' -Description 'LiteRT C++ API header'
    # GPU headers matched by PATH (any *.h under a gpu\ dir), not by a name filter.
    $litertGpuHeaders = Get-ChildItem -Path $litertInclude -Filter '*.h' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\gpu\\' }
    Assert-Test -Name "LiteRT GPU delegate headers" -Condition { @($litertGpuHeaders).Count -gt 0 } -FailMessage "No GPU delegate headers found under $litertInclude"
}

Assert-DirectoryExists -Path $litertLibDir -Description 'LiteRT lib dir'
if (Test-Path $litertLibDir) {
    Assert-ArtifactPresent -Root $litertLibDir -Filter '*.lib' -Description 'LiteRT lib files'
    # EXPORTS, not just the import lib (#67): the documented failure was an import lib that
    # existed while the DLL exported ZERO C-API symbols -- invisible to a presence check, and it
    # only surfaced one branch later in gst's meson link.
    $tfliteDll = Get-ChildItem -Path (Split-Path $litertLibDir -Parent) -Filter 'tensorflowlite_c.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tfliteDll) {
        foreach ($sym in @('TfLiteInterpreterCreate', 'TfLiteXNNPackDelegateCreate', 'TfLiteXNNPackDelegateOptionsDefault')) {
            Assert-DllLoads -Name "tensorflowlite_c.dll exports $sym" -DllPath $tfliteDll.FullName -Export $sym `
                -FailMessage "tensorflowlite_c.dll does not export $sym - the /EXPORT: + WINDOWS_EXPORT_ALL_SYMBOLS injection in build-litert-from-source.ps1 regressed. A link-clean lib with no exports breaks gst-tflite one branch later."
        }
    } else {
        Assert-Test -Name 'tensorflowlite_c.dll present (C API consumers need it)' -Condition { $false } `
            -FailMessage "tensorflowlite_c.dll not found near $litertLibDir - the build gates on the .lib only, so an import lib without its DLL passes that check and fails downstream."
    }
}

Assert-DirectoryExists -Path $litertBinDir -Description 'LiteRT bin dir'
if (Test-Path $litertBinDir) {
    # LiteRT builds statically by default -- the .lib files are the real artifact, so DLL
    # presence is informational.
    Assert-ArtifactPresent -Root $litertBinDir -Filter '*.dll' -Description 'LiteRT DLL files' -Informational
}

}
# ============================================================================
Write-TestHeader '13. LiteRT-LM (on-device LLM inference, source-built)'
if ($smokeCross) {
    Skip-Test "section 13 (LiteRT-LM (on-device LLM inference, source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$litertLmRoot = if ($env:LITERT_LM_ROOT) { $env:LITERT_LM_ROOT } else { 'C:\runtime\lib\litert-lm' }
$litertLmInclude = Join-Path $litertLmRoot 'include'

Assert-DirectoryExists -Path $litertLmRoot -Description 'LiteRT-LM root dir'

Assert-DirectoryExists -Path $litertLmInclude -Description 'LiteRT-LM include dir'
if (Test-Path $litertLmInclude) {
    Assert-ArtifactPresent -Root $litertLmInclude -Filter '*.h' -Description 'LiteRT-LM headers'
}

# NO lib\ assertion: LiteRT-LM is an EXECUTABLE deliverable (bazel builds bin\litert_lm_main.exe
# + co-located DLLs and installs no library set) -- see Dockerfile.media-merge-builder's ENV note.
$litertLmBinDir = Join-Path $litertLmRoot 'bin'
Assert-DirectoryExists -Path $litertLmBinDir -Description 'LiteRT-LM bin dir'
if (Test-Path $litertLmBinDir) {
    Assert-ArtifactPresent -Root $litertLmBinDir -Filter '*.exe' -Description 'LiteRT-LM executable'
    Assert-ArtifactPresent -Root $litertLmBinDir -Filter '*.dll' -Description 'LiteRT-LM runtime DLLs'
}

# Smoke-RUN, not just exist: the shipped binary once linked cleanly yet aborted at startup on
# EVERY run (an abseil flag ODR from a duplicate ABSL_FLAG(minloglevel)). This validates the
# FINAL merged image's exe -- defense-in-depth over the build-time smoke gate.
$litertLmBinDir = Join-Path $litertLmRoot 'bin'
$litertLmExe    = Join-Path $litertLmBinDir 'litert_lm_main.exe'
Assert-FileExists -Path $litertLmExe -Description 'litert_lm_main.exe (on-device LLM runner)'
if (Test-Path $litertLmExe) {
    Assert-Test -Name 'litert_lm_main.exe launches + parses flags (no abseil ODR / missing DLL)' -Condition {
        $prevPath = $env:PATH
        $env:PATH = "$litertLmBinDir;$env:PATH"
        try {
            $out  = & cmd /c "`"$litertLmExe`" --help 2>&1"
            $code = $LASTEXITCODE
            $text = ($out | Out-String)
        } finally { $env:PATH = $prevPath }
        # abseil flag ODR abort at static init (the exact bug that shipped).
        if ($text -match 'Inconsistency between flag|ODR violation|duplicate flags') { return $false }
        # 0xC0000135 STATUS_DLL_NOT_FOUND -> a dependent DLL did not resolve.
        if ($code -eq -1073741515 -or $code -eq 3221225781) { return $false }
        # Positive signal: it reached abseil's flag parser and printed its OWN flags.
        return ($text -match 'model_path|input_prompt|Flags from')
    } -FailMessage 'litert_lm_main.exe did not run cleanly (abseil flag ODR abort, missing DLL, or no flag output)'
}

}
# ============================================================================
Write-TestHeader '14. Compiler smoke test (clang-cl builds C++)'
# ============================================================================
$tmpDir = Join-Path $env:TEMP 'kataglyphis-smoke-test'
Initialize-SmokeScratch -Path $tmpDir

$cppSource = @"
#include <iostream>
#include <vector>
#include <string>
int main() {
    std::vector<std::string> items = {"smoke", "test", "ok"};
    std::cout << items[0] << " " << items[1] << " " << items[2] << std::endl;
    return 0;
}
"@

$srcFile = Join-Path $tmpDir 'smoke.cpp'
$exeFile = Join-Path $tmpDir 'smoke.exe'
Set-Content -Path $srcFile -Value $cppSource -Encoding ASCII

# CROSS LANE: the image bakes VSDEVCMD_ARCH=arm64, so LIB/INCLUDE here are the ARM64 CRT and a
# bare clang-cl (default x64) fails with machine-type conflicts. Compile FOR the target and
# assert the produced PE's machine instead; only the RUN half is impossible here.
$smokeCompileTargetFlag = if ($smokeCross) { "/clang:--target=$(Get-ClangTargetTriple)" } else { $null }
Assert-Test -Name "clang-cl compiles C++ program" -Condition {
    if ($smokeCompileTargetFlag) { & clang-cl $srcFile $smokeCompileTargetFlag /Fe$exeFile /std:c++17 2>&1 | Out-Null }
    else { & clang-cl $srcFile /Fe$exeFile /std:c++17 2>&1 | Out-Null }
    return $LASTEXITCODE -eq 0
} -FailMessage "clang-cl failed to compile simple C++ program"

if ($smokeCross) {
    Assert-Test -Name "Compiled program is target-arch (PE machine)" -Condition {
        if (-not (Test-Path $exeFile)) { return $false }
        $fs = [System.IO.File]::OpenRead($exeFile)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Seek(0x3C, 'Begin') | Out-Null
            $peOff = $br.ReadUInt32()
            $fs.Seek($peOff + 4, 'Begin') | Out-Null
            return ($br.ReadUInt16() -eq (Get-PeMachineType))
        } finally { $fs.Dispose() }
    } -FailMessage "cross-compiled smoke.exe has the wrong PE machine type"
    Skip-Test 'Compiled program runs: skipped on the cross lane (aarch64 exe cannot execute on this x64 host; PE machine asserted instead)'
} else {
    Assert-Test -Name "Compiled program runs" -Condition {
        $output = & $exeFile 2>&1 | Out-String
        return $output.Trim() -eq 'smoke test ok'
    } -FailMessage "Compiled program produced wrong output"
}

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# "Installed" is not "functional" (the OpenGL32 lesson): compile + RUN under /fsanitize=address
# and require ASAN to actually REPORT the intentional overflow. Cross lane skips outright --
# LLVM's Windows x64 package ships no aarch64-windows ASAN runtime.
if ($smokeCross) {
    Skip-Test 'ASAN probe skipped on the cross lane (no aarch64-windows ASAN runtime in the LLVM package; the probe must execute the instrumented exe)'
} else {
Assert-Test -Name "AddressSanitizer compile + runtime works (clang-cl /fsanitize=address)" -Condition {
    $d = Join-Path $env:TEMP 'kataglyphis-smoke-asan'
    Initialize-SmokeScratch -Path $d
    try {
        $src = Join-Path $d 'main.cpp'
        Set-Content -Path $src -Encoding ASCII -Value @'
#include <cstdio>
int main() {
    int* p = new int[4];
    int v = p[4];  // intentional heap-buffer-overflow for ASAN to catch
    std::printf("should not survive: %d\n", v);
    delete[] p;
    return 0;
}
'@
        $exe = Join-Path $d 'main.exe'
        & clang-cl $src '/fsanitize=address' '/Zi' '/EHsc' '/nologo' "/Fe$exe" 2>&1 | Out-Null
        if (($LASTEXITCODE -ne 0) -or -not (Test-Path $exe)) { return $false }
        $out = & $exe 2>&1 | Out-String
        # ASAN aborts the process (non-zero exit) and prints its report.
        return ($LASTEXITCODE -ne 0) -and ($out -match 'AddressSanitizer: heap-buffer-overflow')
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
} -FailMessage "ASAN probe failed: /fsanitize=address did not compile, or the runtime did not detect the intentional overflow (ASAN runtime DLLs missing?)"
}

# ============================================================================
Write-TestHeader '15. CMake + Ninja + clang-cl integration'
# ============================================================================
$tmpDir2 = Join-Path $env:TEMP 'kataglyphis-smoke-cmake'
Initialize-SmokeScratch -Path $tmpDir2

$cmakeLists = @"
cmake_minimum_required(VERSION 3.20)
project(SmokeTest CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(smoke_cmake smoke_cmake.cpp)
"@
$cppSource2 = @"
#include <iostream>
int main() { std::cout << "cmake+clangcl ok" << std::endl; return 0; }
"@

Set-Content -Path (Join-Path $tmpDir2 'CMakeLists.txt') -Value $cmakeLists -Encoding ASCII
Set-Content -Path (Join-Path $tmpDir2 'smoke_cmake.cpp') -Value $cppSource2 -Encoding ASCII

$buildDir2 = Join-Path $tmpDir2 'build'
# Cross lane: same VSDEVCMD_ARCH=arm64 reality as section 14 -- the configure must carry the
# target triple. amd64 gets the empty array and stays byte-identical.
$smokeCmakeCrossArgs = if ($smokeCross) {
    @("-DCMAKE_C_COMPILER_TARGET=$(Get-ClangTargetTriple)", "-DCMAKE_CXX_COMPILER_TARGET=$(Get-ClangTargetTriple)",
      "-DCMAKE_C_FLAGS_INIT=--target=$(Get-ClangTargetTriple)", "-DCMAKE_CXX_FLAGS_INIT=--target=$(Get-ClangTargetTriple)")
} else { @() }
Assert-Test -Name "CMake+Ninja+clang-cl configure" -Condition {
    & cmake -S $tmpDir2 -B $buildDir2 -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl @smokeCmakeCrossArgs 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "CMake configure with Ninja+clang-cl failed"

Assert-Test -Name "CMake+Ninja+clang-cl build" -Condition {
    & cmake --build $buildDir2 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "CMake build with Ninja+clang-cl failed"

if ($smokeCross) {
    Assert-Test -Name "CMake-built exe is target-arch (PE machine)" -Condition {
        $exe2 = Join-Path $buildDir2 'smoke_cmake.exe'
        if (-not (Test-Path $exe2)) { return $false }
        try { (Get-PeFileMachine -Path $exe2) -eq (Get-PeMachineType) } catch { $false }
    } -FailMessage "CMake-built smoke_cmake.exe has the wrong PE machine type"
}

Remove-Item $tmpDir2 -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Write-TestHeader '16. VS MSBuild + ClangCL toolset integration'
# ============================================================================
$tmpDir3 = Join-Path $env:TEMP 'kataglyphis-smoke-msbuild'
Initialize-SmokeScratch -Path $tmpDir3

# NB: single-quoted here-string -- a double-quoted one makes PowerShell evaluate MSBuild's
# $(VCTargetsPath). The ProjectConfigurations group + ConfigurationType are required (MSB8013).
$vcxproj = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup Label="ProjectConfigurations">
    <ProjectConfiguration Include="Release|x64">
      <Configuration>Release</Configuration>
      <Platform>x64</Platform>
    </ProjectConfiguration>
  </ItemGroup>
  <PropertyGroup Label="Globals">
    <ProjectGuid>{D497C90E-6D4C-4E96-9B21-000000000001}</ProjectGuid>
    <Keyword>Win32Proj</Keyword>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <PropertyGroup>
    <ConfigurationType>Application</ConfigurationType>
    <PlatformToolset>ClangCL</PlatformToolset>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />
  <ItemGroup>
    <ClCompile Include="smoke_msbuild.cpp" />
  </ItemGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
'@
$cppSource3 = @"
int main() { return 0; }
"@

Set-Content -Path (Join-Path $tmpDir3 'smoke_msbuild.vcxproj') -Value $vcxproj -Encoding ASCII
Set-Content -Path (Join-Path $tmpDir3 'smoke_msbuild.cpp') -Value $cppSource3 -Encoding ASCII

Assert-Test -Name "MSBuild+ClangCL builds" -Condition {
    & msbuild (Join-Path $tmpDir3 'smoke_msbuild.vcxproj') /p:Configuration=Release /p:Platform=x64 /nologo 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "MSBuild with ClangCL toolset failed"

Remove-Item $tmpDir3 -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Write-TestHeader '17. TVM (source-built)'
if ($smokeCross) {
    Skip-Test "section 17 (TVM (source-built)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$tvmRoot = if ($env:TVM_ROOT) { $env:TVM_ROOT } else { Join-Path 'C:\runtime\lib' 'tvm' }
if (Test-Path $tvmRoot) {
    Assert-DirectoryExists -Path $tvmRoot -Description "TVM install root ($tvmRoot)"
    $tvmInclude = Join-Path $tvmRoot 'include'
    if (Test-Path $tvmInclude) {
        # Layout-agnostic: TVM's runtime header names churn across releases (c_runtime_api.h was
        # dropped by the new FFI in 0.25) -- assert the directory instead.
        Assert-ArtifactPresent -Root $tvmInclude -Subdir 'tvm\runtime' -Filter '*.h' -Description 'TVM runtime headers (tvm/runtime/*.h)'
    } else {
        Skip-Test 'TVM include dir not found'
    }
    Assert-ArtifactPresent -Root $tvmRoot -Filter 'tvm*.lib' -Description 'TVM lib files'
    Assert-ArtifactPresent -Root $tvmRoot -Filter 'tvm*.dll' -Description 'TVM DLL files'

    # Existence != loadable: LoadLibrary the TVM runtime DLL to prove its full dependent-DLL
    # chain resolves (header-agnostic -- TVM's C API names churn across releases). No GPU needed.
    $tvmRuntimeDll = Get-ChildItem -Path $tvmRoot -Filter 'tvm_runtime.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tvmRuntimeDll) { $tvmRuntimeDll = Get-ChildItem -Path $tvmRoot -Filter 'tvm*runtime*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($tvmRuntimeDll) {
        Assert-DllLoads -Name 'TVM runtime DLL loads (dependent chain resolves)' -DllPath $tvmRuntimeDll.FullName -FailMessage 'tvm_runtime.dll failed to load -- a dependent DLL (LLVM/CUDA/Vulkan runtime) did not resolve'
    } else {
        Assert-Test -Name 'TVM load-probe prerequisite present' -Condition { $false } `
            -FailMessage 'TVM_ROOT exists but tvm_runtime.dll is missing — the runtime DLL vanished from the install'
    }
} else {
    Skip-Test 'TVM not installed (C:\runtime\lib\tvm not found)'
}

}
# ============================================================================
Write-TestHeader '18. FFmpeg (source-built with DNN/ONNX)'
if ($smokeCross) {
    Skip-Test "section 18 (FFmpeg (source-built with DNN/ONNX)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
$ffmpegBin = if ($env:FFMPEG_BIN) { $env:FFMPEG_BIN } else { 'C:\runtime\ffmpeg\bin' }
if (Test-Path $ffmpegBin) {
    $ffmpegExe = Join-Path $ffmpegBin 'ffmpeg.exe'
    $ffprobeExe = Join-Path $ffmpegBin 'ffprobe.exe'
    Assert-FileExists -Path $ffmpegExe -Description 'ffmpeg.exe'
    Assert-FileExists -Path $ffprobeExe -Description 'ffprobe.exe'

    Assert-Test -Name "ffmpeg --version responds" -Condition {
        $v = & $ffmpegExe -version 2>&1 | Select-Object -First 1
        return ($v -ne $null) -and ($v -match 'ffmpeg')
    } -FailMessage "ffmpeg -version failed"

    # `-configure` is not an ffmpeg option (the configuration line is part of the -version
    # banner), and `--enable-dnn` is not a real flag -- DNN filters come from enabling a backend.
    $ffCfg = & $ffmpegExe -version 2>&1 | Out-String
    Assert-Test -Name "ffmpeg built with --enable-libonnxruntime" -Condition {
        $ffCfg -match 'enable-libonnxruntime'
    } -FailMessage "ffmpeg was not configured with --enable-libonnxruntime"

    Assert-Test -Name "ffmpeg dnn_processing filter available" -Condition {
        $filters = & $ffmpegExe -hide_banner -filters 2>&1 | Out-String
        return ($filters -match 'dnn_')
    } -FailMessage "no dnn_* filters reported by ffmpeg -filters"

    # -version/-filters only parse the binary's tables; a REAL graph (lavfi in, null out) proves
    # the runtime filter/codec DLL chain executes.
    Assert-Test -Name "ffmpeg runs a real filter graph (lavfi testsrc2 -> null)" -Condition {
        & $ffmpegExe -hide_banner -loglevel error -f lavfi -i testsrc2=duration=0.2:size=64x64:rate=10 -f null - 2>&1 | Out-Null
        $LASTEXITCODE -eq 0
    } -FailMessage "ffmpeg failed a trivial lavfi->null graph (runtime codec/filter chain broken)"

    # The banner says nothing about hardware codecs and the nv-codec-headers step is skippable,
    # so a build that silently dropped NVENC would still pass. Listing codecs needs no GPU device.
    if ($script:gpuNvidia) {
        Assert-Test -Name "ffmpeg NVENC encoders present (h264_nvenc + hevc_nvenc)" -Condition {
            $enc = & $ffmpegExe -hide_banner -encoders 2>&1 | Out-String
            return ($enc -match 'h264_nvenc') -and ($enc -match 'hevc_nvenc')
        } -FailMessage "ffmpeg -encoders did not list h264_nvenc/hevc_nvenc (NVENC not built -- nv-codec-headers step skipped?)"

        Assert-Test -Name "ffmpeg CUVID/NVDEC decoders present (h264_cuvid)" -Condition {
            $dec = & $ffmpegExe -hide_banner -decoders 2>&1 | Out-String
            return ($dec -match 'h264_cuvid')
        } -FailMessage "ffmpeg -decoders did not list h264_cuvid (NVDEC/CUVID not built)"
    }
} else {
    Skip-Test 'FFmpeg not installed (C:\runtime\ffmpeg\bin not found)'
}

}
# ============================================================================
Write-TestHeader '19. Environment pointer integrity'
# ============================================================================
# Every *_BIN/*_ROOT the Dockerfiles bake must point at a real directory -- a stale pointer is
# how the CMake MSI->scoop switch left CMAKE_BIN aimed at a deleted dir.
# Deliberately NOT asserted: CARGO_HOME/CARGO_BIN (nonexistent until first use) and the removed
# LLVM_GLOBAL_BIN. SCOOP_GLOBAL_SHIMS is soft-asserted -- see the block after this loop.
$envPointerNames = @(
    'CMAKE_BIN', 'FLUTTER_BIN', 'VULKAN_SDK', 'WIX', 'LLVM_USER_BIN',
    'SCOOP_HOME', 'SCOOP_GLOBAL', 'SCOOP_USER_SHIMS',
    'GIT_CMD', 'GIT_BIN', 'GIT_USRBIN',
    'ONNX_ROOT', 'ONNX_GENAI_ROOT', 'OPENCV_ROOT', 'OPENCV_BIN', 'OPENCV_LIB', 'OPENCV_INCLUDE',
    # #127: these were declared in the merge image with zero readers repo-wide -- asserting them
    # here turns layout documentation into a checked contract.
    'FFMPEG_ROOT', 'FFMPEG_BIN', 'FFMPEG_LIB', 'GSTREAMER_BIN', 'PYTHON_BUILD_BIN', 'TEMP_DIR',
    'TVM_ROOT', 'TVM_LIBRARY_PATH', 'LITERT_ROOT', 'LITERT_INCLUDE', 'LITERT_LIB', 'LITERT_BIN',
    'LITERT_LM_ROOT', 'LITERT_LM_INCLUDE', 'LITERT_LM_BIN', 'PYTHON_WHEELS',
    'IREE_ROOT', 'IREE_BIN',
    # Hard-assert TORCH_APP_DIR: section 21 SKIPs when it is unset, so without this pointer
    # check a lost env var would silently drop the whole app-env verification.
    'TORCH_APP_DIR'
)
if ($script:gpuNvidia) {
    $envPointerNames += @('CUDA_ROOT', 'CUDA_PATH', 'CUDNN_ROOT', 'TENSORRT_ROOT')
}
if ($smokeCross) {
    # The torch stage is default-dropped on the cross lane (uv sync must RUN the target
    # interpreter), so TORCH_APP_DIR names a stage that never built. Every other pointer stays
    # asserted (#115 litert, #116 tvm/iree runtime-only): what a branch cannot build ships an
    # EMPTY marker-carrying dir, so every pointer must still resolve on either lane.
    $envPointerNames = @($envPointerNames | Where-Object { $_ -ne 'TORCH_APP_DIR' })
    Skip-Test 'TORCH_APP_DIR pointer check skipped on the cross lane (torch stage is default-dropped; see docs/windows-cross-builds.md)'
}
foreach ($envPointer in $envPointerNames) {
    $pointerName = $envPointer
    Assert-Test -Name "$envPointer points at an existing directory" -Condition {
        $v = [Environment]::GetEnvironmentVariable($pointerName)
        (-not [string]::IsNullOrWhiteSpace($v)) -and (Test-Path $v -PathType Container)
    }.GetNewClosure() -FailMessage "$envPointer is unset or points at a nonexistent path (stale Dockerfile ENV?)"
}

# PATH COMPOSITION: pointer-exists proves the TARGET is there, not that it is ON PATH --
# deleting the Dockerfile PATH line that adds ONNX_ROOT\bin kept every assertion green.
$pathMembers = @('ONNX_ROOT', 'OPENCV_BIN', 'FFMPEG_BIN', 'GSTREAMER_BIN', 'LITERT_BIN', 'LITERT_LIB', 'TVM_LIBRARY_PATH', 'IREE_BIN', 'PYTHON_BUILD_BIN')
$pathEntries = @($env:PATH -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
foreach ($pm in $pathMembers) {
    $pmVal = [Environment]::GetEnvironmentVariable($pm)
    if (-not $pmVal) { continue }  # unset pointers are the pointer loop's problem
    # ONNX_ROOT itself is not on PATH — its bin\ is (windows/Dockerfile).
    $expected = $(if ($pm -eq 'ONNX_ROOT') { Join-Path $pmVal 'bin' } else { $pmVal }).TrimEnd('\')
    Assert-Test -Name "$pm target is on PATH ($expected)" -Condition {
        $pathEntries -contains $expected
    }.GetNewClosure() -FailMessage "$expected is not on PATH — the ENV PATH line that adds it was lost; dependents die with STATUS_DLL_NOT_FOUND"
}
# cuda-runtime staging dir: PATH entry #1 on BOTH lanes -- cudnn64_9.dll is what the ORT CUDA
# EP dlopens at session time.
Assert-Test -Name 'C:\runtime\cuda-runtime\bin is on PATH' -Condition {
    $pathEntries -contains 'C:\runtime\cuda-runtime\bin'
} -FailMessage 'the flattened CUDA-runtime staging dir fell off PATH (stage-cuda-runtime.ps1 contract)'
if ($script:gpuNvidia) {
    Assert-FileExists -Path 'C:\runtime\cuda-runtime\bin\cudnn64_9.dll' -Description 'staged cuDNN runtime (ORT CUDA EP dlopens it)'
}

# flutter is installed --global, so scoop creates C:\ProgramData\scoop\shims -- which was on NO
# PATH entry between 2026-07-14 and 2026-08-08. Skip, don't fail, on images from that window.
$globalShims = $env:SCOOP_GLOBAL_SHIMS
if ([string]::IsNullOrWhiteSpace($globalShims)) {
    Skip-Test 'SCOOP_GLOBAL_SHIMS checks skipped (env var absent -- base image predates 2026-08-08)'
} else {
    # ASSERT THE GOAL, NOT THE MECHANISM (#86): requiring a global shims dir failed on every
    # image, including a fresh base -- scoop simply never creates one in this configuration.
    # What matters is that a --global package resolves BY NAME, so assert exactly that.
    Assert-Test -Name 'globally scoop-installed package resolves by name (flutter)' -Condition {
        [bool](Get-Command flutter -ErrorAction SilentlyContinue)
    } -FailMessage 'flutter (scoop --global) does not resolve by name — neither a global shims dir nor a baked *_BIN entry is on PATH'
    Assert-Test -Name 'global scoop root holds the --global install' -Condition {
        $root = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL')
        if (-not $root) { $root = Split-Path $globalShims -Parent }
        Test-Path (Join-Path $root 'apps') -PathType Container
    }.GetNewClosure() -FailMessage 'no apps\ directory under the global scoop root — the --global install did not happen at all'
}

# vcpkg zlib is the one vcpkg artifact media builds still consume (LiteRT-LM's
# protobuf_external HAVE_ZLIB). Root from VCPKG_ROOT, the env var vcpkg tooling and CMake
# toolchains honor; 'C:\vcpkg' is only setup-vcpkg.ps1's default install dir.
$vcpkgRoot = $env:VCPKG_ROOT ?? 'C:\vcpkg'
# NAME DRIFT, not a missing library (#87): upstream vcpkg's zlib port switched to the Unix-style
# output name (z.lib). Accept either name so the next rename does not re-open this.
Assert-Test -Name "vcpkg zlib present (media-build dependency)" -Condition {
    $libDir = Join-Path $vcpkgRoot "installed\$(Get-VcpkgTriplet)\lib"
    @(Get-ChildItem -Path $libDir -Filter 'z*.lib' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('z.lib', 'zlib.lib', 'zlibstatic.lib') }).Count -gt 0
} -FailMessage "no vcpkg zlib import lib (z.lib/zlib.lib) under $vcpkgRoot\installed\$(Get-VcpkgTriplet)\lib — vcpkg install genuinely broken"

# ============================================================================
Write-TestHeader '20. Python bindings (wheels + imports + inference)'
if ($smokeCross) {
    Skip-Test "section 20 (Python bindings (wheels + imports + inference)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
# The media branches build python bindings, stage the wheels at PYTHON_WHEELS and install them
# into site-packages. cv2 ships installed-in-place only; LiteRT has no python bindings here.
$wheelStore = [Environment]::GetEnvironmentVariable('PYTHON_WHEELS')
if ($wheelStore -and (Test-Path $wheelStore)) {

    foreach ($wheelPattern in @('onnxruntime-*.whl', '*genai*.whl', '*tvm*.whl', 'av-*.whl', '*iree*compiler*.whl', '*iree*runtime*.whl')) {
        $wp = $wheelPattern
        Assert-Test -Name "wheel staged: $wheelPattern" -Condition {
            @(Get-ChildItem -Path $wheelStore -Filter $wp -ErrorAction SilentlyContinue).Count -gt 0
        }.GetNewClosure() -FailMessage "no $wheelPattern found in $wheelStore"
    }

    # All wheels must carry THIS LANE'S platform tag: a win32 tag means the sitecustomize shim
    # was missing at build time, a win_amd64 tag on arm64 means a host-built wheel leaked in.
    # This assert resolves the TARGET arch while the shim deliberately stamps the HOST build
    # interpreter, so the two may diverge on the cross lane -- they answer different questions.
    # That divergence is unexercised today: the arm64 wheel store stays empty until #120 lands.
    $pyWheelTag = Get-PythonWheelTag
    $pyPlatformName = Get-PythonPlatformName
    Assert-Test -Name "all staged wheels are $pyWheelTag-tagged" -Condition {
        @(Get-ChildItem -Path $wheelStore -Filter '*.whl' | Where-Object { $_.Name -notmatch ($pyWheelTag + '|any\.whl$') }).Count -eq 0
    } -FailMessage "wheel(s) with a non-$pyWheelTag platform tag in $wheelStore (platform-tag shim missing at build time?)"

    Assert-Test -Name "python platform tag is $pyPlatformName (sitecustomize shim)" -Condition {
        (& python -c "import sysconfig; print(sysconfig.get_platform())" 2>&1 | Out-String) -match $pyPlatformName
    } -FailMessage "sysconfig.get_platform() is not $pyPlatformName (shim missing -- pip resolves 32-bit wheels)"

    # onnxruntime: real python-side inference over the shared 63-byte Identity model.
    Assert-Test -Name "python onnxruntime inference end-to-end (CPU EP)" -Condition {
        $mdir = Join-Path $env:TEMP 'kataglyphis-smoke-pyort'
        Initialize-SmokeScratch -Path $mdir
        try {
            [IO.File]::WriteAllBytes((Join-Path $mdir 'identity.onnx'), $script:identityOnnxBytes)
            $out = & python -c "import os, numpy, onnxruntime as ort; s = ort.InferenceSession(os.path.join(os.environ['TEMP'], 'kataglyphis-smoke-pyort', 'identity.onnx'), providers=['CPUExecutionProvider']); y = s.run(['y'], {'x': numpy.array([42.0], numpy.float32)})[0]; print('py-ort', ort.__version__, float(y[0]))" 2>&1 | Out-String
            ($LASTEXITCODE -eq 0) -and ($out -match 'py-ort .*42\.0')
        } finally { Remove-Item $mdir -Recurse -Force -ErrorAction SilentlyContinue }
    } -FailMessage "onnxruntime python inference failed (pyd, dependent DLLs, or numpy broken)"

    # PyPI onnxruntime-gpu ships NO DmlExecutionProvider, so asserting DML here detects any
    # same-version PyPI variant shadowing our combined wheel.
    Assert-PythonSnippet -Name "python onnxruntime exposes DML EP (not shadowed by a PyPI variant)" `
        -Code "import onnxruntime; print(onnxruntime.get_available_providers())" `
        -ExpectMatch @('DmlExecutionProvider') `
        -FailMessage "base-interpreter onnxruntime lacks DmlExecutionProvider -- a PyPI onnxruntime variant shadowed the source-built wheel"

    if ($script:gpuNvidia) {
        Assert-PythonSnippet -Name "python onnxruntime exposes CUDA + TensorRT EPs (GPU lane)" `
            -Code "import onnxruntime; print(onnxruntime.get_available_providers())" `
            -ExpectMatch @('CUDAExecutionProvider', 'TensorrtExecutionProvider') `
            -FailMessage "base-interpreter onnxruntime lacks CUDA/TensorRT EPs"
    }

    Assert-PythonSnippet -Name "python onnxruntime-genai imports" `
        -Code "import onnxruntime_genai as og; print('py-genai', getattr(og, '__version__', 'n/a'))" `
        -ExpectMatch @('py-genai') `
        -FailMessage "import onnxruntime_genai failed (pyd or embedded DLL chain broken)"

    # cv2: PNG encode/decode round-trip exercises core + imgcodecs via python.
    Assert-PythonSnippet -Name "python cv2 imports + PNG round-trip" `
        -Code "import cv2, numpy; img = numpy.zeros((8, 8, 3), numpy.uint8); ok, buf = cv2.imencode('.png', img); d = cv2.imdecode(buf, cv2.IMREAD_COLOR); print('py-cv2', cv2.__version__, bool(ok) and d.shape == (8, 8, 3))" `
        -ExpectMatch @('py-cv2 .* True') `
        -FailMessage "cv2 import or PNG round-trip failed (cv2 pyd, loader config, or OpenCV DLL chain broken)"

    # ---- COMPILED-IN VIDEO BACKENDS (#95) ----------------------------------
    # Guards #93 (GStreamer silently OFF) and #94 (OpenCV using its OWN prebuilt FFmpeg). The
    # obvious check LIES: cv2.videoio_registry.getBackends() lists GSTREAMER whether or not it
    # was compiled in, so only getBuildInformation() is authoritative.
    $cvBuildInfo = & python -c "import cv2; print(cv2.getBuildInformation())" 2>&1 | Out-String

    # #93 is solved by the STANDALONE plugin route (opencv_videoio_gstreamer*.dll built in the
    # MERGE stage). getBuildInformation() legitimately keeps saying `GStreamer: NO` -- that is
    # videoio's COMPILE-TIME config, so asserting it would stay red on a CORRECT image.
    # hasBackend(CAP_GSTREAMER) is authoritative: it attempts the plugin load.
    Assert-Test -Name "cv::VideoCapture has a working GStreamer backend (plugin, #93)" -Condition {
        $out = & python -c "import cv2; print('gst-backend', cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER))" 2>&1 | Out-String
        ($LASTEXITCODE -eq 0) -and ($out -match 'gst-backend True')
    } -FailMessage ("cv2.videoio_registry.hasBackend(CAP_GSTREAMER) is False -- the opencv_videoio_gstreamer plugin " +
        "DLL is missing next to opencv_videoio*.dll, or it failed to load (GStreamer DLLs not resolvable). " +
        "Built by build-opencv-gstreamer-plugin.ps1 in the merge stage -- backlog #93.")

    # Capability, not just loadability: open a real (synthetic) pipeline and read one frame.
    Assert-Test -Name "cv::VideoCapture opens a GStreamer pipeline and reads a frame (#93)" -Condition {
        $out = & python -c "import cv2; cap = cv2.VideoCapture('videotestsrc num-buffers=1 ! videoconvert ! appsink', cv2.CAP_GSTREAMER); ok, frame = cap.read(); print('gst-read', bool(ok) and frame is not None and frame.size > 0)" 2>&1 | Out-String
        ($LASTEXITCODE -eq 0) -and ($out -match 'gst-read True')
    } -FailMessage ("VideoCapture(CAP_GSTREAMER) could not read a frame from a videotestsrc pipeline -- the plugin " +
        "loads but the GStreamer runtime underneath it is broken (core plugins missing from the plugin dir, or " +
        "GST_PLUGIN_PATH/PATH not set by the entrypoint). Backlog #93.")

    # NOT a provenance check: `(prebuilt binaries)` is printed whenever videoio uses the wrapper
    # mechanism, regardless of where the libs came from, so it stays there on a CORRECT build.
    # The avcodec version comparison below is the real provenance test.
    Assert-Test -Name 'OpenCV has an FFmpeg backend at all' -Condition {
        $cvBuildInfo -match '(?m)^\s*FFMPEG:\s+YES'
    } -FailMessage 'cv2.getBuildInformation() does not report FFMPEG: YES -- cv::VideoCapture has no FFmpeg path.'

    # avdevice was NO with OpenCV's downloaded FFmpeg; #94 turned it on -- guard the regression.
    Assert-Test -Name 'OpenCV FFmpeg backend includes avdevice (#94)' -Condition {
        $cvBuildInfo -match '(?m)^\s*avdevice:\s+YES'
    } -FailMessage ('cv2.getBuildInformation() reports avdevice as NO -- the FFmpeg backend lost libavdevice, ' +
        'which is one of the symptoms #94 fixed.')

    # Cross-check versions instead of pinning: ask ffmpeg.exe and OpenCV what avcodec each
    # carries and require the majors to agree -- survives an FFMPEG_VERSION bump and catches a
    # silent fallback to a bundled build. Read both UP FRONT so "they disagree" and "one was
    # unreadable" stay separable defects with separate messages.
    $ffDir = if ($env:FFMPEG_BIN) { $env:FFMPEG_BIN } else { 'C:\runtime\ffmpeg\bin' }
    $ffExe = Join-Path $ffDir 'ffmpeg.exe'
    $chainAvcodec = ''
    if (Test-Path $ffExe) {
        # ffmpeg.exe needs its own bin dir on PATH to resolve avcodec-*.dll; without it the
        # version comes back empty and reads as a mismatch that is really "could not read".
        $savedPath = $env:PATH
        try {
            if ($env:PATH -notlike "*$ffDir*") { $env:PATH = "$ffDir;$env:PATH" }
            $chainVer = (& $ffExe -version 2>&1 | Out-String)
            if ($chainVer -match '(?m)^\s*libavcodec\s+(\d+)\.') { $chainAvcodec = $Matches[1] }
        } finally { $env:PATH = $savedPath }
    }
    # OpenCV prints either `avcodec: 61.19.100` or `avcodec: YES (61.19.100)` -- accept both.
    $cvAvcodec = ''
    if ($cvBuildInfo -match '(?m)^\s*avcodec:\s+(?:YES\s*\()?(\d+)\.') { $cvAvcodec = $Matches[1] }

    Assert-Test -Name "both avcodec majors are readable (precondition for the #94 check)" -Condition {
        $chainAvcodec -and $cvAvcodec
    } -FailMessage ("could not read one of the avcodec versions -- chain='$chainAvcodec' (from '$ffExe' -version), " +
        "opencv='$cvAvcodec' (from cv2.getBuildInformation()). This is NOT a version-mismatch verdict: an empty " +
        "chain value usually means ffmpeg.exe could not launch (its bin dir missing from PATH), an empty opencv " +
        "value means the Video I/O block had no avcodec line at all.")

    if ($chainAvcodec -and $cvAvcodec) {
        Assert-Test -Name "OpenCV's avcodec major matches the chain's FFmpeg (#94)" -Condition {
            $chainAvcodec -eq $cvAvcodec
        } -FailMessage ("OpenCV was built against avcodec $cvAvcodec while this chain ships avcodec $chainAvcodec -- " +
            "the image carries TWO FFmpeg generations and cv::VideoCapture's FFmpeg path uses the wrong one. " +
            "Backlog #94.")
    } else {
        Skip-Test 'OpenCV avcodec major vs chain (one of the versions unreadable)'
    }

    Assert-PythonSnippet -Name "python tvm imports (runtime device reachable)" `
        -Code "import tvm; print('py-tvm', tvm.__version__, tvm.cpu(0))" `
        -ExpectMatch @('py-tvm') `
        -FailMessage "import tvm failed (wheel, tvm_runtime/tvm_ffi DLLs, or deps broken)"

    # PyAV built against OUR ffmpeg (PyPI's wheel is unloadable on Server Core: its bundled
    # avdevice imports AVICAP32). Software codec BY NAME -- generic 'h264' resolves to
    # h264_d3d12va, which cannot open without a D3D12 device.
    Assert-PythonSnippet -Name "python av (PyAV vs our ffmpeg): in-memory mpeg4 encode" `
        -Code "import io, av; buf = io.BytesIO(); c = av.open(buf, mode='w', format='mp4'); s = c.add_stream('mpeg4', rate=24); s.width = 64; s.height = 64; s.pix_fmt = 'yuv420p'; f = av.VideoFrame(64, 64, 'yuv420p'); [c.mux(p) for p in s.encode(f)]; [c.mux(p) for p in s.encode()]; c.close(); print('py-av', av.__version__, len(buf.getvalue()) > 0)" `
        -ExpectMatch @('py-av .* True') `
        -FailMessage "PyAV import or mpeg4 encode failed (av pyd, our ffmpeg DLL chain, or codec table broken)"

    # Compile through iree.compiler and execute on iree.runtime's local-task driver: proves the
    # two wheels interoperate. tensor<f32> args must be numpy arrays (a bare float dies in VM
    # marshaling).
    Assert-PythonSnippet -Name "python iree compile+run end-to-end (abs(-5)=5, local-task)" `
        -Code "import numpy as np, iree.compiler.tools as t, iree.runtime as rt; vm = t.compile_str('$script:ireeGateMlir', target_backends=['llvm-cpu']); m = rt.load_vm_flatbuffer(vm, driver='local-task'); print('py-iree', float(m.abs(np.asarray(-5.0, dtype=np.float32)).to_host()))" `
        -ExpectMatch @('py-iree 5\.0') `
        -FailMessage "iree.compiler/iree.runtime end-to-end failed (wheels, bundled iree-compile, or runtime driver broken)"

} else {
    Skip-Test 'Python bindings (PYTHON_WHEELS unset or missing -- image predates the wheel feature)'
}

}
# ============================================================================
Write-TestHeader '21. Orchestr-ANT-ion app environment (torch step)'
if ($smokeCross) {
    Skip-Test "section 21 (Orchestr-ANT-ion app environment (torch step)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
# The final image bakes the runtime orchestrator (assemble-torch-app.ps1); verification re-runs
# that script's own verify mode OFFLINE against the baked venv.
$torchAppDir = [Environment]::GetEnvironmentVariable('TORCH_APP_DIR')
# Resolve the verifier beside this script OR from the image's baked copy -- the BK gate used to
# file-mount only the smoke script, silently skipping section 21 forever. A set TORCH_APP_DIR
# with no resolvable verifier is a GATE bug, not an optional feature: fail loudly.
$torchAppScript = @(
    (Join-Path $PSScriptRoot 'assemble-torch-app.ps1'),
    'C:\temp\scripts\assemble-torch-app.ps1'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($torchAppDir -and (Test-Path $torchAppDir) -and -not $torchAppScript) {
    Assert-Test -Name 'torch-app verifier reachable (gate wiring)' -Condition { $false } `
        -FailMessage 'TORCH_APP_DIR is baked but assemble-torch-app.ps1 is neither beside the smoke script nor at C:\temp\scripts — the gate mount lost the verifier'
}
if ($torchAppDir -and (Test-Path $torchAppDir) -and $torchAppScript) {
    Assert-DirectoryExists -Path (Join-Path $torchAppDir '.venv') -Description 'torch-app venv'
    Assert-Test -Name "torch-app venv verifies (numpy/cv2/torch/ort+CUDA-EP/genai/tvm/av/iree)" -Condition {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $torchAppScript -AppDir $torchAppDir -Mode verify 2>&1 | Out-String
        ($LASTEXITCODE -eq 0) -and ($out -match 'torch-app-env OK')
    } -FailMessage "assemble-torch-app.ps1 -Mode verify failed (baked venv broken or local wheels lost)"
} else {
    Skip-Test 'Orchestr-ANT-ion app env (TORCH_APP_DIR unset or missing -- image predates the torch step)'
}

}
# ============================================================================
Write-TestHeader '22. IREE (source-built ML compiler + runtime)'
if ($smokeCross) {
    Skip-Test "section 22 (IREE (source-built ML compiler + runtime)) skipped on the $(Get-WindowsTargetArch) cross lane: it executes the aarch64 payload, impossible on an x64 host"
} else {
# ============================================================================
# Native tools live at IREE_BIN; the python bindings ship as wheels (section 20). Real work,
# not existence checks: compile MLIR to a vmfb and execute it.
$ireeBin = [Environment]::GetEnvironmentVariable('IREE_BIN')
if ($ireeBin -and (Test-Path $ireeBin)) {
    Assert-CommandExists 'iree-compile'
    Assert-CommandExists 'iree-run-module'

    # Pin assert: the source-built iree-compile reports "version (unknown)", so pin on the
    # staged compiler WHEEL filename, which git-describe stamps with the tag.
    $ireeExpected = (Get-ExpectedVersion 'IREE_VERSION' '') -replace '^v', ''
    if ($ireeExpected) {
        Assert-Test -Name "iree compiler wheel matches versions.env pin ($ireeExpected)" -Condition {
            $ws = [Environment]::GetEnvironmentVariable('PYTHON_WHEELS')
            @(Get-ChildItem -Path $ws -Filter '*iree*compiler*.whl' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match [regex]::Escape($ireeExpected) }).Count -gt 0
        } -FailMessage "no staged iree compiler wheel carries the pinned $ireeExpected -- stale media layer shipped?"
    }

    Assert-Test -Name "iree-compile runs (--version exits 0)" -Condition {
        & iree-compile --version 2>&1 | Out-Null
        $LASTEXITCODE -eq 0
    } -FailMessage "iree-compile --version failed (tool or DLL chain broken)"

    $ireeDir = Join-Path $env:TEMP 'kataglyphis-smoke-iree'
    Initialize-SmokeScratch -Path $ireeDir
    $ireeMlir = Join-Path $ireeDir 'abs.mlir'
    $ireeVmfb = Join-Path $ireeDir 'abs-cpu.vmfb'
    Set-Content -Path $ireeMlir -Encoding ascii -Value $script:ireeGateMlir

    Assert-Test -Name "iree-compile: MLIR -> vmfb (llvm-cpu)" -Condition {
        & iree-compile --iree-hal-target-backends=llvm-cpu $ireeMlir -o $ireeVmfb 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0) -and (Test-Path $ireeVmfb) -and ((Get-Item $ireeVmfb).Length -gt 0)
    } -FailMessage "iree-compile failed to lower MLIR for llvm-cpu"

    Assert-Test -Name "iree-run-module: local-task executes abs(-5)=5" -Condition {
        $out = & iree-run-module --module=$ireeVmfb --device=local-task --function=abs --input=f32=-5 2>&1 | Out-String
        ($LASTEXITCODE -eq 0) -and ($out -match 'f32=5')
    } -FailMessage "iree-run-module failed or returned wrong result (runtime/HAL broken)"

    if ($script:gpuNvidia) {
        # Compile-only: execution needs a CUDA device, which containers on this host cannot see.
        Assert-Test -Name "iree-compile: MLIR -> vmfb (cuda target, compile-only)" -Condition {
            $cudaVmfb = Join-Path $ireeDir 'abs-cuda.vmfb'
            & iree-compile --iree-hal-target-backends=cuda $ireeMlir -o $cudaVmfb 2>&1 | Out-Null
            ($LASTEXITCODE -eq 0) -and (Test-Path $cudaVmfb) -and ((Get-Item $cudaVmfb).Length -gt 0)
        } -FailMessage "iree-compile cuda target failed (NVPTX backend broken)"
    }

    Remove-Item $ireeDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Skip-Test 'IREE (IREE_BIN unset or missing -- image predates the IREE step)'
}

}
# ============================================================================
Write-TestHeader '== SUMMARY =='
# ============================================================================
# Read through the module, NOT $script:passed: the counters live in the harness module's scope,
# and a bare $script:passed here resolves to unset -- reporting 0/0 and exiting 0 regardless.
$summary = Get-SmokeTestSummary
Write-Host "  Passed:  $($summary.Passed)" -ForegroundColor Green
Write-Host "  Failed:  $($summary.Failed)" -ForegroundColor Red
Write-Host "  Skipped: $($summary.Skipped)" -ForegroundColor Yellow
Write-Host "  Total:   $($summary.Total)" -ForegroundColor Cyan
if ($summary.Aborted) {
    Write-Host '  NOTE: -ExitOnFirstFailure aborted the run at the first failure; remaining tests were not executed.' -ForegroundColor Yellow
}

if ($summary.Failed -gt 0) {
    Write-Host "`n--- FAILURE DETAILS ---" -ForegroundColor Red
    foreach ($detail in $summary.FailureDetails) {
        Write-Host "  $detail" -ForegroundColor Red
    }
    exit 1
}

# Coverage floors (#44): zero failures is NOT "verified". Checked after the failure branch so a
# real failure still reports as a failure, not as a coverage problem.
$coverageProblems = @()
if ($MinPassed -gt 0 -and $summary.Passed -lt $MinPassed) {
    $coverageProblems += "only $($summary.Passed) assertion(s) passed, expected at least $MinPassed — the run proved far less than it appears to"
}
if ($MaxSkipped -ge 0 -and $summary.Skipped -gt $MaxSkipped) {
    $coverageProblems += "$($summary.Skipped) test(s) skipped, ceiling is $MaxSkipped — sections are being gated out (usually a missing env var or an absent artifact keyed as 'optional')"
}
if ($summary.Aborted) {
    $coverageProblems += '-ExitOnFirstFailure aborted the run, so the remaining tests never executed and this result is not a full verdict'
}
# PER-SECTION floors: the global floor left 34 points of anonymous slack -- deleting
# onnxruntime.lib alone silently dropped 7 of the strongest assertions and stayed green.
# Every floor is MEASURED per lane and updated DELIBERATELY; a payload section skipped on cross
# MUST stay 0 rather than be "fixed" by a skip. Columns are NAMED (#131): the old positional
# triple's index order differed from the selector's.
$sectionFloors = @{
    '1' = @{ Gpu = 13; Cpu = 13; Arm64 = 13 }; '2' = @{ Gpu = 6; Cpu = 6; Arm64 = 6 }; '3' = @{ Gpu = 8; Cpu = 8; Arm64 = 8 }
    '4' = @{ Gpu = 8; Cpu = 8; Arm64 = 8 };    '5' = @{ Gpu = 4; Cpu = 4; Arm64 = 4 }; '6' = @{ Gpu = 4; Cpu = 4; Arm64 = 4 }
    # '7' is 13, counted against a real -ExpectGpu run: the section's only branch picks the
    # cuDNN link+run OR a Skip, so there is no conditional fourteenth.
    '7' = @{ Gpu = 13; Cpu = 0; Arm64 = 0 };  '8' = @{ Gpu = 11; Cpu = 8; Arm64 = 0 };  '9' = @{ Gpu = 9; Cpu = 6; Arm64 = 0 }
    '10' = @{ Gpu = 7; Cpu = 5; Arm64 = 0 };  '11' = @{ Gpu = 12; Cpu = 12; Arm64 = 0 }; '12' = @{ Gpu = 9; Cpu = 9; Arm64 = 0 }
    '13' = @{ Gpu = 6; Cpu = 6; Arm64 = 0 }
    # '14' arm64 is 2: the run-assert becomes a PE-machine assert 1:1, but ASAN is a SKIP there.
    '14' = @{ Gpu = 3; Cpu = 3; Arm64 = 2 };  '15' = @{ Gpu = 2; Cpu = 2; Arm64 = 2 };  '16' = @{ Gpu = 1; Cpu = 1; Arm64 = 1 }
    '17' = @{ Gpu = 5; Cpu = 5; Arm64 = 0 };  '18' = @{ Gpu = 8; Cpu = 6; Arm64 = 0 };  '19' = @{ Gpu = 30; Cpu = 26; Arm64 = 24 }
    '20' = @{ Gpu = 22; Cpu = 21; Arm64 = 0 }; '21' = @{ Gpu = 2; Cpu = 2; Arm64 = 0 }; '22' = @{ Gpu = 7; Cpu = 6; Arm64 = 0 }
}
$floorLane = if ($ExpectGpu) { 'Gpu' } elseif ($smokeCross) { 'Arm64' } else { 'Cpu' }
foreach ($sec in $sectionFloors.Keys) {
    $floor = $sectionFloors[$sec][$floorLane]
    if ($floor -le 0) { continue }
    $got = if ($summary.SectionPassed.Contains($sec)) { [int]$summary.SectionPassed[$sec] } else { 0 }
    if ($got -lt $floor) {
        $coverageProblems += "section $sec passed only $got assertion(s), floor is $floor — a subsystem's verification quietly shrank"
    }
}
if ($coverageProblems.Count -gt 0) {
    Write-Host "`n--- INSUFFICIENT COVERAGE ---" -ForegroundColor Red
    foreach ($p in $coverageProblems) { Write-Host "  $p" -ForegroundColor Red }
    Write-Host 'Refusing to report success: 0 failures with too little executed is indistinguishable from a broken harness.' -ForegroundColor Red
    exit 3
}

Write-Host "`nAll smoke tests passed! ($($summary.Passed) assertions, $($summary.Skipped) skipped)" -ForegroundColor Green
exit 0

