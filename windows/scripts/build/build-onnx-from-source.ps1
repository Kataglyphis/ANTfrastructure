# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast before module import

# #108: repo layout is scripts/<group>/ while container mounts stay FLAT, so shared
# assets sit beside this script (flat) or one level up (repo).
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.29.0' -StripVPrefix

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

# #122: phase brackets via trap (#109 contract, without indenting the body). EAP=Stop
# makes every failure terminating, so the trap stamps the open phase and rethrows.
trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'onnx'; break }
Switch-BuildPhase '1. clone + source patches (DML clang-cl, rc filter)'
Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive | Out-Null

$cmakeSrc = if (Test-Path "$SourceDir\cmake\CMakeLists.txt") { "$SourceDir\cmake" } else { $SourceDir }
$buildDir = "$SourceDir\build"
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"
# Resolved ONCE into a variable (#131): a condition starting with a command name is
# parsed in command mode (the "python wheel 0s" trap).
$onnxCross = Test-WindowsCrossTarget

# Inline patch (kept inline, NOT a .patch file): llvm-rc rejects non-ASCII bytes in the .rc resource.
# This is a binary byte-filter (`-le 127`), not a textual diff -- not expressible as a unified diff.
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

# -- DirectML EP clang-cl fixes (clang-cl + USE_DML=ON) --
# Reviewable .patch first; Invoke-OnnxDmlClangClPatch (WindowsSourceBuild.Patches.psm1, #131)
# is the EOL/context-tolerant drift fallback and documents each fix.
$null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\003-dml-clangcl-compat.patch') -SourceDir $SourceDir `
    -FallbackNote 'falling back to inline regex patcher' `
    -Fallback { Invoke-OnnxDmlClangClPatch -SourceDir $SourceDir; $true }

# DirectML redist dir is CASE-SENSITIVE to ninja and upstream mixes the cases (dml.cmake
# declares bin/arm64-win, providers_dml composes bin/ARM64-win -> 'no known rule to make
# it', which reads like a missing package): docs/windows-cross-builds.md, DirectML row.
$dmlProviders = Join-Path $SourceDir 'cmake\onnxruntime_providers_dml.cmake'
if (Test-Path $dmlProviders) {
    # Two separate edits so a future upstream move of either line fails loudly
    # (-AssertGone) instead of silently missing; -SkipIfMatch keeps a re-run idempotent.
    [void](Invoke-InlineRegexPatch -Path $dmlProviders `
            -SkipIfMatch 'onnxruntime_dml_redist_platform' `
            -Guard 'if \(NOT onnxruntime_USE_CUSTOM_DIRECTML\)' `
            -Pattern '(?m)^(\s*)if \(NOT onnxruntime_USE_CUSTOM_DIRECTML\)' `
            -Replacement "`${1}string(TOLOWER `"`${onnxruntime_target_platform}`" onnxruntime_dml_redist_platform)`n`${1}if (NOT onnxruntime_USE_CUSTOM_DIRECTML)" `
            -Description 'onnxruntime DML: lower-case the redist platform dir (define)')
    [void](Invoke-InlineRegexPatch -Path $dmlProviders `
            -Guard 'bin/\$\{onnxruntime_target_platform\}-win' `
            -Pattern 'bin/\$\{onnxruntime_target_platform\}-win' `
            -Replacement 'bin/${onnxruntime_dml_redist_platform}-win' `
            -AssertGone 'bin/\$\{onnxruntime_target_platform\}-win' `
            -Description 'onnxruntime DML: lower-case the redist platform dir (consumers)')
    if ((Get-Content -LiteralPath $dmlProviders -Raw) -notmatch 'string\(TOLOWER') {
        throw "onnxruntime_providers_dml.cmake: the redist platform lower-casing define is missing after patching (upstream layout changed?). Re-check $dmlProviders."
    }
}

$py = Initialize-ToolchainPythonEnvironment

# Bindings ride this build (ENABLE_PYTHON=ON below): pybind11 needs numpy headers at
# compile time, the wheel step needs setuptools/wheel.
Install-CpythonPip -Python $py
Switch-BuildPhase '2. python deps + cmake args'
Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'numpy', 'setuptools', 'wheel', 'packaging')

# ONNX CPU features atop the shared SIMD base, x86-only (clang-cl rejects them on aarch64):
# mwaitpkg for spin_pause.cc's _tpause, aes/pclmul for CUDA crc64, f16c. AVX-512/AMX never
# global -- per-TU on the MLAS kernels below: docs/windows-cross-builds.md § SIMD.
# /clang:-Wno-unused-value: ORT's own comma-expression macros; ONE diagnostic, not a blanket
# /w. Count check: windows\scripts\diagnostics\Measure-BuildWarnings.ps1.
$onnxTargetArch = Get-WindowsTargetArch
$baseSimdFlags = Get-WindowsTargetSimdFlags -Arch $onnxTargetArch
$x86OnlyFlags = if ($onnxTargetArch -eq 'amd64') { '/clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mf16c' } else { '' }
$cxxFlags = (@('/WX-', $baseSimdFlags, $x86OnlyFlags,
               '/clang:-Wno-invalid-specialization', '/clang:-Wno-unused-value',
               (Get-WarningNoiseSuppressionFlags)) | Where-Object { $_ }) -join ' '

# CUDA stays BARE: the sccache launcher is opt-in at the wiring site (Invoke-CmakeConfigure
# honors only SCCACHE_CUDA_LAUNCHER=1) -- docs/windows-build-resources.md.

# -- GPU detection (single shot via Get-GpuEnvironment; ONNX-specific flag names stay local) --
# ONNX_FORCE_CPU=1 skips the ~1h CUDA/TensorRT kernel compiles so the DirectML clang-cl patch
# can be iterated in ~15 min. Dev knob only; the media-core build never sets it.
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
$gpuArgs = @()
# if/elseif rather than `switch ($gpuEnv.GpuType)`: the switch-on-property syntax can
# trigger parser errors in Windows PowerShell 5.1.
# Cross lane: NEVER take CUDA from a HOST probe. GPU_TYPE is IMAGE state and the toolchain
# image is shared, so an arm64 build would link x64 device libs into an "arm64" artifact
# (arm64 CUDA is backlog, not fiction: docs/windows-cross-builds.md § CUDA / cuDNN / TensorRT).
if ($gpuEnv.HasCuda -and -not $onnxCross) {
    Write-Host 'NVIDIA GPU detected: enabling CUDA + cuDNN'
    $cudaRoot = $gpuEnv.CudaRoot
    $cudnnRoot = $gpuEnv.CudnnRoot
    # Shared cuDNN import-lib finder (prefers cudnn.lib over the 9.x split sub-libs); $null when absent.
    $cudnnLib = Get-CudnnLibrary -CudnnRoot $cudnnRoot

    # CUDA 13.x CCCL breaks clang-cl PCH -- disable via a reviewable .patch (inline regex fallback for context drift).
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\002-disable-cuda-pch.patch') -SourceDir $SourceDir `
        -FallbackNote 'falling back to inline regex' `
        -Fallback {
            $pch = "$SourceDir\cmake\onnxruntime_providers_cuda.cmake"
            Invoke-InlineRegexPatch -Path $pch -Pattern 'target_precompile_headers\([^)]+\)' `
                -WarnMessage "onnxruntime_providers_cuda.cmake: no target_precompile_headers(...) call found to strip; the CUDA PCH may break the clang-cl build. Verify $pch."
        }
    # The CUDA include set defines ERROR/VERBOSE (wingdi.h, reached despite -DNOGDI); either
    # token-pastes through LOGS_DEFAULT into the nonexistent Severity::k0 in tunable.h.
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\004-tunable-severity-macro-collision.patch') -SourceDir $SourceDir `
        -FallbackNote 'falling back to inline #undef insertion' `
        -Fallback {
            $tunable = Join-Path $SourceDir 'onnxruntime\core\framework\tunable.h'
            Invoke-InlineRegexPatch -Path $tunable -Pattern '(#include "core/framework/tuning_context\.h")' `
                -Replacement ('$1' + "`n`n#ifdef ERROR`n#undef ERROR`n#endif`n#ifdef VERBOSE`n#undef VERBOSE`n#endif") `
                -WarnMessage "tunable.h: tuning_context include anchor not found; LOGS_DEFAULT(ERROR) will fail as Severity::k0. Verify $tunable."
        }

    # XQA's host-pass guard keys on HAS_SM80_OR_LATER, which sccache's nvcc decomposition can
    # drop in the host sub-step (C2039 smemSize/kernelType). We always target sm80+, so make
    # the host stub unconditional.
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\005-xqa-host-stub-sccache.patch') -SourceDir $SourceDir `
        -FallbackNote 'falling back to inline guard rewrite' `
        -Fallback {
            $xqaGen = Join-Path $SourceDir 'onnxruntime\contrib_ops\cuda\bert\xqa\xqa_impl_gen.cuh'
            Invoke-InlineRegexPatch -Path $xqaGen -Pattern '#elif defined\(HAS_SM80_OR_LATER\) \|\| !defined\(__CUDACC__\)' `
                -Replacement '#else' `
                -WarnMessage "xqa_impl_gen.cuh: host-stub guard anchor not found; XQA host stubs may fail as C2039 smemSize/kernelType. Verify $xqaGen."
        }

    # Patch 006 (bare nvcc for onnxruntime_providers_cuda_llm) was retired with the #114
    # sccache series (mozilla/sccache#2811): if undefined fused_moe/QkvToContext symbols
    # return, check that series still applies before resurrecting a bare-nvcc exception.

        # clang-cl rejects the `and`/`or`/`not` keyword alternatives; .patch first, the generic
        # Edit-CppKeywordAlternatives helper as the context-drift fallback.
        $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\001-softmax-clangcl-keywords.patch') -SourceDir $SourceDir `
            -FallbackNote 'falling back to keyword-alternatives in softmax sources' `
            -Fallback {
                foreach ($sf in @('softmax.cc', 'softmax.h')) {
                    $sfp = Join-Path $SourceDir 'onnxruntime\core\providers\cuda\math' $sf
                    if (Test-Path $sfp) { Edit-CppKeywordAlternatives -Path $sfp }
                }
                $true
            }

    # ONNX-specific CMake flags (names like `onnxruntime_USE_CUDA` are ORT-only -- kept local, not in the generic helper).
    $gpuArgs += '-Donnxruntime_USE_CUDA=ON'
    $trtRoot = $gpuEnv.TensorRtRoot
    if ($trtRoot) {
        Write-Host "TensorRT detected at $trtRoot - enabling TensorRT EP"
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=ON'
        $gpuArgs += '-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON'
        $gpuArgs += "-DTENSORRT_ROOT=$trtRoot"
    } else {
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=OFF'
    }
    # nvcc host = MSVC cl.exe (nvcc rejects clang-cl); C++17; /wd4067 is ORT-specific. Shared nvcc block.
    $gpuArgs += Get-NvccCudaCmakeArgs -CudaRoot $cudaRoot -CudaStandard '17' -ExtraCudaFlags '-Xcompiler=/wd4067'
    $gpuArgs += "-DCUDNN_ROOT=$cudnnRoot", "-DCUDNN_INCLUDE_DIR=$cudnnRoot\include"
    $gpuArgs += "-DCMAKE_LIBRARY_PATH=$cudnnRoot\lib\x64", "-DCUDNN_LIBRARY=$cudnnLib"
    $gpuArgs += "-Donnxruntime_CUDNN_HOME=$cudnnRoot", "-Donnxruntime_CUDA_HOME=$cudaRoot"
} elseif ($gpuEnv.GpuType -eq 'amd' -and -not $onnxCross) {
    # Same host-vs-target guard as the CUDA branch: a host GPU probe must never decide a
    # TARGET flag. The branch is dead today (GPU_TYPE=amd is never set).
    Write-Host 'AMD GPU detected: enabling ROCm'
    $gpuArgs += '-Donnxruntime_USE_ROCM=ON'
} else {
    Write-Host 'No GPU layer detected: CPU-only build'
}

# DirectML EP ON: the vendored DirectMLHelpers headers only compile under clang-cl with the
# out-of-lining patch above (llvm #57700); USE_DML=ON fetches the redist via NuGet.
# Python bindings ON on both lanes (#120 step 2): the HOST interpreter RUNS the build, the
# TARGET python314.lib is what the .pyd LINKS -- Get-TargetBuildPython encodes that split.
$tpy = Get-TargetBuildPython
$pythonArgs = if ($onnxCross -and -not $tpy.Available) {
    Write-Warning "ONNX: python bindings OFF -- no target CPython import lib at $($tpy.Lib) (build-target-cpython.ps1 did not run?)"
    @('-Donnxruntime_ENABLE_PYTHON=OFF')
} else {
    # `Python_*`, NOT `Python3_*`: ORT's find_package(Python ...) is UNVERSIONED, so Python3_*
    # names are silently ignored. numpy's include dir is probed by RUNNING the host interpreter
    # (its headers are arch-neutral) and handed over explicitly, off FindPython's cross path.
    $numpyInc = (Invoke-ShieldedNative -Label 'numpy include probe' -CommandLine """$($tpy.Exe)"" -c ""import numpy; print(numpy.get_include())""" | Select-Object -Last 1)
    if (-not $numpyInc -or -not (Test-Path (Join-Path $numpyInc 'numpy\arrayobject.h'))) {
        throw "ONNX: numpy include dir not usable ('$numpyInc') -- numpy must be importable by the build interpreter $($tpy.Exe) before configure"
    }
    @('-Donnxruntime_ENABLE_PYTHON=ON') + @(Get-PythonCMakeHintArgs -Python $tpy -Prefix 'Python' -NumPyIncludeDir $numpyInc)
}
if ($onnxCross -and $tpy.Available) { Write-Host "ONNX: python bindings ON for the cross lane (#120 step 2) -- host interpreter $($tpy.Exe), TARGET import lib $($tpy.Lib)" }
# DirectML ON on BOTH lanes (#113; GenAI #118) -- the one cross obstacle was the redist
# path case patched above. Record: docs/windows-cross-builds.md, DirectML row.
$dmlArg = '-Donnxruntime_USE_DML=ON'
if ($onnxCross) { Write-Host 'ONNX: DirectML EP ON for the cross lane too (backlog #113 - the redist DOES ship bin/arm64-win/DirectML.lib; the old failure was an upper-case path, not a missing package)' }
# -- QNN EP (QAIRT SDK), backlog #121: OPT-IN by staging the login-gated zip in
# windows\qnn-sdk\; no zip = EP off. PROVEN on the build-time path 2026-08-31
# (full :winarm64 chain, QAIRT 2.44.0, aarch64-windows-msvc backends); runtime
# execution still needs a Snapdragon host.
$qnnSdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256
$qnnArgs = if ($qnnSdk) { $qnnSdk.CmakeArgs } else { @() }
if ($qnnSdk) { Write-Host "ONNX: QNN EP ON (SDK root $($qnnSdk.Home), backends from $($qnnSdk.LibDir)) -- backlog #121" }
else { Write-Host 'ONNX: QNN EP off -- no SDK zip staged in windows\qnn-sdk (opt-in; see windows\qnn-sdk\README.md, backlog #121)' }
$cmakeArgs = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    $dmlArg, '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
) + $pythonArgs + @(
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $gpuArgs + $qnnArgs
# #123: MLAS's amd64 kernels are MASM and stay on MSVC's ml64 BY MEASUREMENT -- llvm-ml 22
# cannot assemble them (no listing directives, no includer-relative INCLUDE, no SDK macro
# layer). Full record: docs/windows-backlog-archive-2026-08-26.md, #123.
Switch-BuildPhase '3. cmake configure'
# Tee'd, not swallowed: the ASM_MASM identification lines must stay in the log so the
# assembler in use is a fact, not an assumption.
$ortCfgLog = Get-PersistentBuildLogPath -Name 'onnxruntime-configure.log' -FallbackDir $buildDir
Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs 2>&1 |
    Tee-Object -FilePath $ortCfgLog
if (-not $onnxCross) {
    # The found assembler must be ml64 (#123); anything else is toolchain drift worth
    # stopping on now, not 40 ninja-minutes later.
    $masmLines = @(Get-Content $ortCfgLog | Where-Object { $_ -match 'ASM_MASM|Found assembler' })
    if ($masmLines.Count -eq 0 -or -not ($masmLines -join "`n" | Select-String -Pattern 'ml64' -Quiet)) {
        throw "ORT configure did not report ml64 as the ASM_MASM assembler (#123: MLAS needs MSVC's MASM, llvm-ml 22 cannot assemble it). ASM_MASM lines: $(if ($masmLines.Count) { $masmLines -join ' | ' } else { '<none>' }) -- see $ortCfgLog"
    }
    Write-Host "ASM_MASM assembler (#123, MSVC ml64 by design): $($masmLines -join ' | ')"
}
Switch-BuildPhase '4. post-configure _deps patches + ninja-file tags'

# -- Post-configure patches on the fetched _deps trees: inline, NOT .patch files --
# static patches against CMake-fetched deps rot when ORT's dep pointer moves.

# onnx scoped_resource.h: INVALID_HANDLE_VALUE is a reinterpret_cast, not a valid non-type
# template argument under clang; swap the alias for an interface-identical RAII class.
$scopedHandleFix = @'
// [clang-cl compat, ContainerHub] INVALID_HANDLE_VALUE ((HANDLE)(LONG_PTR)-1)
// is not a valid non-type template argument under clang (reinterpret_cast in a
// constant expression; MSVC permits it as an extension). Interface-identical
// RAII type with the sentinel held at runtime instead.
class ScopedHandle {
  HANDLE val_;

 public:
  explicit ScopedHandle(HANDLE v) : val_(v) {}
  ~ScopedHandle() {
    if (val_ != INVALID_HANDLE_VALUE) {
      close_handle(val_);
    }
  }
  HANDLE get() const {
    return val_;
  }
  HANDLE release() {
    HANDLE tmp = val_;
    val_ = INVALID_HANDLE_VALUE;
    return tmp;
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
};
'@
$onnxScoped = "$buildDir\_deps\onnx-src\onnx\common\scoped_resource.h"
if (Test-Path $onnxScoped) {
    Invoke-InlineRegexPatch -Path $onnxScoped `
        -Pattern 'using ScopedHandle = ScopedResource<INVALID_HANDLE_VALUE, close_handle>;' `
        -Replacement $scopedHandleFix `
        -WarnMessage "onnx scoped_resource.h: ScopedHandle alias not found — upstream may have fixed or reshaped it; verify clang-cl still compiles checker.cc." | Out-Null
}

# CUTLASS's fetched SHA follows ORT's ExternalProject pointer, so a static .patch would
# silently rot -- hence the tree-walking helpers below. Cross guard as in the CUDA branch:
# GPU_TYPE is IMAGE state, shared by both lanes.
if ($env:GPU_TYPE -eq 'nvidia' -and -not $onnxCross) {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keyword alternatives.
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object { Edit-CppKeywordAlternatives -Path $_.FullName }
    }
    # CUTLASS enables the MSVC-only `_udiv128` for every _MSC_VER >= 1920, which clang-cl
    # defines. Disable the GUARD, never rewrite the call: #73's `_udiv128 -> udiv128` made
    # udiv128 call itself (225 -Winfinite-recursion warnings, latent stack overflow).
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    # The pattern is a PREFIX of its own replacement, so a resumed build (the _deps tree
    # survives) would re-append it; the explicit skip also keeps the drift warning meaningful.
    if ((Test-Path $cut) -and ((Get-Content -Raw $cut) -match '!defined\(__clang__\)')) {
        Write-Host 'cutlass/uint128.h: __clang__ guard already applied (resumed tree) - skipping'
    } else {
        Invoke-InlineRegexPatch -Path $cut `
            -Pattern '#if _MSC_VER >= 1920 && !defined\(__CUDA_ARCH__\)' `
            -Replacement '#if _MSC_VER >= 1920 && !defined(__CUDA_ARCH__) && !defined(__clang__)' `
            -WarnMessage "cutlass/uint128.h: the _MSC_VER>=1920 intrinsic guard was not found; if CUTLASS reshaped it, clang-cl will fail on _udiv128 (or worse, self-recurse). Verify $cut." | Out-Null
    }
    # CUTLASS cute/array_subbyte: suppressed via -Wno-invalid-specialization above
}

# Strip MSVC-only flags from build.ninja
Update-NinjaFile -NinjaFile "$buildDir\build.ninja" -StripPatterns @(
    # [ \t]* not \s*: \s eats the line's own CR/LF when the flag terminates a
    # line, merging it with the next ninja statement (probed 2026-08-04).
    '--compiler-options /experimental:external[ \t]*',
    '(?<=\s)/experimental:external(?=\s)',
    '(?<=\s)-WX(?=\s)',
    '/arch:\S+',
    '(?<!-Xcompiler\s)/bigobj',
    '--threads \d+'
)

# MLAS's arch kernels get their SIMD features PER-TU in build.ninja: globally they crash
# static init on an AVX2-only host, without them those TUs fail to compile. Arch-parameterized
# -- an x86 literal matches nothing on aarch64, and a patch that matches nothing SUCCEEDS.
# docs/windows-cross-builds.md § SIMD.
$targetArch    = Get-WindowsTargetArch
$mlasArchFlags = Get-WindowsTargetKernelSimdFlags -Arch $targetArch
$mlasTuPattern = Get-MlasKernelTuPattern -Arch $targetArch
# SOURCE-DERIVED, not name-guessed: chasing names missed the *_fp16 family and then
# dwconv.cpp. On cross, union the name pattern with every MLAS source that includes
# fp16_common.h, so a new fp16 consumer is tagged the day it appears.
if ($onnxCross) {
    $mlasLibDir = Join-Path $SourceDir 'onnxruntime\core\mlas\lib'
    $fp16Consumers = @(
        Get-ChildItem $mlasLibDir -Recurse -Filter '*.cpp' -File -ErrorAction SilentlyContinue |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'fp16_common\.h' } |
            ForEach-Object { [regex]::Escape($_.Name) }
    )
    if ($fp16Consumers.Count -gt 0) {
        $mlasTuPattern = '(' + $mlasTuPattern + ')|(' + ($fp16Consumers -join '|') + ')'
        Write-Host "MLAS: $($fp16Consumers.Count) source(s) include fp16_common.h - unioned into the per-TU flag pattern"
    } else {
        Write-Warning "MLAS: no source under $mlasLibDir includes fp16_common.h - the tree layout changed; falling back to the name pattern alone"
    }
}
$mlasTuMinimum = Get-MlasKernelTuMinimum -Arch $targetArch
# Marker proving a FLAGS line is already tagged, so a re-run does not append twice.
# Arch-specific for the same reason as the pattern: 'avx512' is x86-only.
$mlasTaggedMarker = if ($targetArch -eq 'amd64') { 'avx512' } else { 'dotprod' }

# The floor is the guard, the pattern alone is not: too few matches means the dispatched
# kernels silently lose their SIMD features -- HARD FAILURE, build.ninja left untouched.
[void](Add-NinjaPerTuFlags -NinjaFile "$buildDir\build.ninja" -Label "MLAS $targetArch kernel (pattern: $mlasTuPattern)" -Floor $mlasTuMinimum -AlreadyTaggedPattern $mlasTaggedMarker -Select {
    param($line)
    if ($line -match 'onnxruntime_mlas\.dir' -and $line -match $mlasTuPattern) { $mlasArchFlags } else { '' }
})

# Memory-scaled parallelism: jobs = min(cores, memGB/MemGBPerJob), floor 2 (BUILD_JOBS
# overrides); the -j2 retry is incremental, so an OOM costs a slow tail, not the build.
# Ninja log on the PERSISTENT sccache mount (#4): when the vertex fails the container
# filesystem dies with the solve, C:\sccache survives (never-swallow-logs).
$ninjaLog = Get-PersistentBuildLogPath -Name 'onnx-ninja.log' -FallbackDir $buildDir
# MemGBPerJob=2 is measured, not guessed (backlog #28: peak per-process WorkingSet 998 MB).
Switch-BuildPhase '5. ninja build + install'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 2 -MemGBPerJob 2 -Install -LogFile $ninjaLog

# Hit-rate evidence on STDERR -- the stream the 2MiB step-log clip never truncates
# (AGENTS.md priority 1: caching must be MEASURED).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# cmake --install does not stage DirectML.dll, so a DML session would fail 0xC0000135. Must
# run BEFORE Remove-SourceBuildTree. -SidecarFilter pins the pick to the TARGET's redist dir
# (the nuget unpacks one per platform; an unfiltered -First 1 is arch-blind).
$ortDmlArchDir = "$(Get-WindowsTargetArch)" -replace '^amd64$', 'x64'
Copy-SidecarDll -SidecarName 'DirectML.dll' -SearchDir $SourceDir `
    -SidecarFilter { $_.Directory.Name -eq "$ortDmlArchDir-win" } `
    -BesidePrimary 'onnxruntime.dll' -InstallDir $ortInstallDir `
    -Reason 'the DirectML EP may fail to load at runtime (0xC0000135)'

# QNN EP runtime (#121): cmake installs the provider DLL but not the SDK's backend DLLs
# (redist, like DirectML.dll) -- stage them beside onnxruntime.dll for the DLL search path.
if ($qnnSdk) { [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $ortInstallDir) }

# -- Python wheel (onnxruntime) -- setup.py bdist_wheel FROM the build dir, where cmake
# assembled the package tree. No --wheel_name_suffix (our CUDA+TensorRT+DML combo matches no
# upstream split, so it ships as plain `onnxruntime`); must run BEFORE Remove-SourceBuildTree.
Switch-BuildPhase '6. python wheel'
# $onnxCross (a VARIABLE), NOT `Test-WindowsCrossTarget -and ...`: a condition starting with
# a command name is parsed in command mode, so `-and -not ...` became three ARGUMENTS and the
# branch fired with the bindings ON ("python wheel 0s").
if ($onnxCross -and -not $tpy.Available) {
    Write-Host 'Skipping the onnxruntime python wheel: cross build without a target CPython (bindings were OFF above)'
} else {
    # One call for both lanes: -CrossStage stages the target wheel (PE- and name-checked,
    # never imported here); the native lane installs and import-asserts, so the shipped
    # image can `import onnxruntime` out of the box.
    Write-Host 'Building onnxruntime python wheel...'
    Invoke-PythonWheelBuild -Python $py -WorkingDir $buildDir `
        -Arguments """$SourceDir\setup.py"" bdist_wheel" `
        -ModuleName 'onnxruntime' -CrossStage | Out-Null
}

Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnx'
Complete-SourceBuild -Banner '=== ONNX Runtime source build completed ===' -SourceDir $SourceDir  # cleanup + banner + exit 0 (see module help)
