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

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.29.0' -StripVPrefix

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

# #122 (2026-08-21): phase brackets via trap — same failure-names-its-phase
# contract as gstreamer/litert-lm (#109) without indenting the body. EAP=Stop
# makes every failure terminating, so the trap stamps the open phase and
# rethrows.
trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'onnx'; break }
Switch-BuildPhase '1. clone + source patches (DML clang-cl, rc filter)'
Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive | Out-Null

$cmakeSrc = if (Test-Path "$SourceDir\cmake\CMakeLists.txt") { "$SourceDir\cmake" } else { $SourceDir }
$buildDir = "$SourceDir\build"
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"
# Resolved ONCE, as a variable (#131): every cross decision below reads it,
# and a condition that starts with the command name is parsed in command mode
# (the run-2 "python wheel 0s" trap).
$onnxCross = Test-WindowsCrossTarget

# Inline patch (kept inline, NOT a .patch file): llvm-rc rejects non-ASCII bytes in the .rc resource.
# This is a binary byte-filter (`-le 127`), not a textual diff -- not expressible as a unified diff.
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

# The DirectML clang-cl regex fallback (Invoke-OnnxDmlClangClPatch, 80 lines of
# embedded C++) lives in WindowsSourceBuild.Patches.psm1 since #131; it is
# the drift fallback for the checked-in .patch below.

# -- DirectML EP clang-cl fixes (needed because we build ONNX with clang-cl + USE_DML=ON) --
# Applied via a reviewable, upstreamable .patch (003-dml-clangcl-compat.patch). The delicate inline regex
# patcher (Invoke-OnnxDmlClangClPatch) stays as a drift fallback: it is EOL/context-tolerant (\r?\n anchors,
# warn-not-throw), so if a future onnxruntime bump shifts the anchors and the static .patch stops applying,
# the build self-heals instead of failing. See that function for the full rationale of each fix
# (#1 incomplete-type out-lining, #2 `.##Z` token-paste, #3 Dispatch<size_t>).
$null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\003-dml-clangcl-compat.patch') -SourceDir $SourceDir `
    -FallbackNote 'falling back to inline regex patcher' `
    -Fallback { Invoke-OnnxDmlClangClPatch -SourceDir $SourceDir; $true }

# DirectML redist path is CASE-SENSITIVE to ninja, and upstream mixes the cases.
#
# The nuget lays its redist out in LOWER case -- bin/x64-win, bin/arm64-win --
# and cmake/external/dml.cmake declares its add_custom_command OUTPUTs with those
# exact lower-case names. But detect_onnxruntime_target_platform.cmake leaves
# onnxruntime_target_platform VERBATIM ("Do nothing. We'll just use the current
# value"), so on ARM64 it is upper case and the two consumers in
# onnxruntime_providers_dml.cmake compose bin/ARM64-win/... . Under Ninja that is
# a DIFFERENT node name than the one dml.cmake declared, and the build dies with
#   'packages/Microsoft.AI.DirectML.1.15.4/bin/ARM64-win/DirectML.lib' missing
#   and no known rule to make it
# which reads exactly like a missing package -- and was misread that way here on
# 2026-08-23, becoming the stated reason for scoping the lane to "CPU + Vulkan".
# It is not missing: 1.15.4 ships bin/arm64-win/DirectML.lib, a COFF import
# archive whose IMPORT_OBJECT_HEADER carries machine 0xAA64 and which imports
# DMLCreateDevice from DirectML.dll.
#
# amd64 is untouched by construction: 'x64' is already lower case, so both the
# TOLOWER and the substitution are no-ops there. Applied unconditionally anyway --
# a case-correctness fix has no business being arch-conditional.
$dmlProviders = Join-Path $SourceDir 'cmake\onnxruntime_providers_dml.cmake'
if (Test-Path $dmlProviders) {
    # Define the lower-cased variable just above the first consumer, then point
    # both consumers at it. Two separate edits so a future upstream move of
    # either line fails loudly (-AssertGone), never as a silent miss: on ARM64
    # that miss surfaces as 'bin/ARM64-win/DirectML.lib missing and no known
    # rule to make it', which looks like a missing package but is not.
    # -SkipIfMatch makes a re-run idempotent.
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

# Python bindings ride this build (onnxruntime_ENABLE_PYTHON=ON below): pybind11
# needs numpy headers at compile time and the wheel step needs setuptools/wheel.
# (Initialize-ToolchainPythonEnvironment wrote the win-amd64 platform-tag shim, so
# pip resolves 64-bit wheels and our wheel tags correctly.)
Install-CpythonPip -Python $py
Switch-BuildPhase '2. python deps + cmake args'
Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'numpy', 'setuptools', 'wheel', 'packaging')

# ONNX-specific CPU feature flags added on top of the shared SIMD base.
# mwaitpkg is required by spin_pause.cc (_tpause intrinsic); aes/pclmul are
# used by CUDA provider crc64; f16c accelerates float16 on Haswell+.
# AVX-512/AMX deliberately NOT in the global flags: with them, clang may emit
# AVX-512 anywhere — including onnxruntime.dll's static initializers, which
# run unconditionally at LOAD time and crashed with STATUS_ILLEGAL_INSTRUCTION
# on this AVX2-only host (ORT 1.28; ctypes/pybind load both die). The MLAS
# arch-specific TUs that REQUIRE those features get them per-TU via the
# build.ninja add-pass after configure — they are runtime-dispatched and safe.
# /clang:-Wno-unused-value: ORT's own stream_handles.h / execution_provider.h
# use comma-expression macros whose result is discarded, ~2 460 lines of pure
# upstream noise per chain. Targeted at ONE diagnostic, not a blanket /w -- our
# own diagnostics must stay visible. /WX- above already rules out warnings-as-
# errors, so even an unrecognised -Wno- could not break this build.
# Verify the count actually dropped: windows\scripts\diagnostics\Measure-BuildWarnings.ps1
# Arch-aware (2026-08-22): the baseline SIMD set AND the four extra ISA flags
# below are x86-only. On aarch64 clang-cl rejects them outright, so they are
# gated rather than merely swapped -- Get-WindowsTargetSimdFlags returns empty
# for arm64 by design (NEON is baseline; optional AArch64 features belong only
# on the runtime-dispatched MLAS kernels, see the build.ninja pass further down).
$onnxTargetArch = Get-WindowsTargetArch
$baseSimdFlags = Get-WindowsTargetSimdFlags -Arch $onnxTargetArch
$x86OnlyFlags = if ($onnxTargetArch -eq 'amd64') { '/clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mf16c' } else { '' }
$cxxFlags = (@('/WX-', $baseSimdFlags, $x86OnlyFlags,
               '/clang:-Wno-invalid-specialization', '/clang:-Wno-unused-value',
               (Get-WarningNoiseSuppressionFlags)) | Where-Object { $_ }) -join ' '

# CUDA stays BARE here - and everywhere: since 2026-08-10 night the CUDA
# launcher is OPT-IN at the wiring site (Invoke-CmakeConfigure honors only
# SCCACHE_CUDA_LAUNCHER=1; review find #1 killed the per-script opt-out
# env var, which leaked process-wide on the classic lane while the BK lane
# kept wrapping other CUDA stages). HISTORY: the nvcc decomposition was
# disqualified 2026-08-10 (runs 5/12-vs-10/11 discriminator, fused_moe
# server crash) and REHABILITATED 2026-08-18 - root cause was the dryrun
# quote-collapse, fixed by the #114 patch series (mozilla/sccache#2811),
# proven by the three-canary bar incl. a 100% CUDA-hit link. Patch 006 was
# retired the same evening (see below). Guard + retry ladder stay armed.

# -- GPU detection (single shot via Get-GpuEnvironment; ONNX-specific flag names stay local) --
# ONNX_FORCE_CPU=1 forces a CPU-only ONNX (skips the ~1h CUDA/TensorRT kernel compiles) so the DirectML
# clang-cl patch can be iterated fast -- DirectML (USE_DML=ON) still builds and surfaces any clang-cl
# errors in ~15 min. Dev/iteration knob only; the media-core build never sets it.
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
$gpuArgs = @()
# if/elseif/else used in place of `switch ($gpuEnv.GpuType) { ... }` for broad compatibility
# with Windows PowerShell 5.1 (the switch-on-property syntax can trigger parser errors in PS 5.1).
# Cross lane: NEVER take CUDA from a HOST probe. Get-GpuEnvironment answers
# "does this windows/amd64 BUILD IMAGE carry a CUDA toolkit" -- and GPU-ness is
# baked into the image (Dockerfile.nvidia's ENV GPU_TYPE), not passed per run.
# The toolchain image is SHARED and unsuffixed, so an arm64 media build inherits
# GPU_TYPE=nvidia with a valid CUDA_ROOT and would configure an aarch64 ONNX with
# USE_CUDA=ON, linking x64 device libs into an "arm64" artifact. The driver's
# arm64 -Gpu refusal cannot see this: it is image state, not an argument.
# CORRECTED 2026-08-24: this note used to close with "there is no CUDA/cuDNN/
# TensorRT for Windows-on-ARM at all" -- that absolute was WRONG when written.
# cuDNN publishes a windows-arm64 archive at this repo's exact 9.25.0.15 pin
# (verified HTTP 200, lib/arm64 inside), CUDA 13.4 (preview) advertises Windows
# ARM64 incl. x86_64-hosted cross-compile, and TensorRT-RTX ships Windows-on-Arm
# packages for CUDA 13.4 (only classic TensorRT is genuinely x64-only -- no
# ARM64 row in NVIDIA's support matrix). Wiring an arm64 CUDA is backlog work,
# not fiction. The guard STAYS regardless: the toolkit baked into this x64
# image is x64, and a HOST GPU probe must never decide a TARGET flag. Same
# guard as build-opencv-from-source.ps1's CUDA branch.
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
    # ORT 1.28.0 + CUDA 13.3: Windows headers in the CUDA include set define ERROR
    # (wingdi.h's `#define ERROR 0`, reached despite -DNOGDI) and can define VERBOSE;
    # either pre-expands through the LOGS_DEFAULT forwarding macro and token-pastes
    # into the nonexistent Severity::k0 inside tunable.h (nvcc: `enum
    # "onnxruntime::logging::Severity" has no member "k0"` at the LOGS_DEFAULT(ERROR)
    # line; first TU: triton_kernel.cu). Reviewable .patch first; inline #undef
    # insertion after the last tunable.h include as the context-drift fallback.
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\004-tunable-severity-macro-collision.patch') -SourceDir $SourceDir `
        -FallbackNote 'falling back to inline #undef insertion' `
        -Fallback {
            $tunable = Join-Path $SourceDir 'onnxruntime\core\framework\tunable.h'
            Invoke-InlineRegexPatch -Path $tunable -Pattern '(#include "core/framework/tuning_context\.h")' `
                -Replacement ('$1' + "`n`n#ifdef ERROR`n#undef ERROR`n#endif`n#ifdef VERBOSE`n#undef VERBOSE`n#endif") `
                -WarnMessage "tunable.h: tuning_context include anchor not found; LOGS_DEFAULT(ERROR) will fail as Severity::k0. Verify $tunable."
        }

    # ORT 1.28.0 XQA kernels: the host-pass include guard in xqa_impl_gen.cuh keys on the
    # cmake-provided HAS_SM80_OR_LATER define, and sccache's nvcc decomposition
    # (CMAKE_CUDA_COMPILER_LAUNCHER) can drop target -D defines in the host sub-step -
    # the stub then fails with C2039/C2065 (`smemSize`/`kernelType`/`cacheVTileSeqLen`
    # missing from `H*::grp*_*` in x_?.cudafe1.stub.c). We always target sm80+
    # (CUDA_ARCHITECTURES 80;86;89;90), so the patch makes the host stub unconditional.
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot 'patches\onnxruntime\005-xqa-host-stub-sccache.patch') -SourceDir $SourceDir `
        -FallbackNote 'falling back to inline guard rewrite' `
        -Fallback {
            $xqaGen = Join-Path $SourceDir 'onnxruntime\contrib_ops\cuda\bert\xqa\xqa_impl_gen.cuh'
            Invoke-InlineRegexPatch -Path $xqaGen -Pattern '#elif defined\(HAS_SM80_OR_LATER\) \|\| !defined\(__CUDACC__\)' `
                -Replacement '#else' `
                -WarnMessage "xqa_impl_gen.cuh: host-stub guard anchor not found; XQA host stubs may fail as C2039 smemSize/kernelType. Verify $xqaGen."
        }

    # Patch 006 (bare nvcc pinned onto onnxruntime_providers_cuda_llm) was
    # RETIRED 2026-08-18 (owner call): both reasons for it are resolved and
    # measured. The server deadlock on the fused_moe launchers was collateral
    # of the #99 broken L0 cache mount (gone under WebDAV-only - all 1891 CUDA
    # objects compiled through the server without a stall on 2026-08-18), and
    # the dropped-instantiation miscompile was the dryrun quote-collapse fixed
    # by the #114-shipped patch series (mozilla/sccache#2811; hit canary:
    # 100.00% CUDA hit rate, link green). The fused_moe family now goes
    # through the launcher like every other CUDA target. If lld-link ever
    # reports undefined fused_moe/QkvToContext symbols again, FIRST check the
    # sccache patch series still applies (SCCACHE_GIT_REV bump?) before
    # resurrecting any bare-nvcc exception. SCCACHE_REPRO_CUDA_LLM is retired
    # with it (it existed only to skip 006 for the #2808 server-trace repro).

        # clang-cl can't handle `and`/`or`/`not` keyword alternatives -- replace via a reviewable .patch.
        # If the .patch context has drifted upstream (common when ONNX rearranges comments), fall back
        # to the generic Edit-CppKeywordAlternatives helper against the two softmax source files.
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
    # The cross guard mirrors the CUDA branch above (hardened 2026-08-23; this
    # sibling was missed until 2026-08-24): Get-GpuEnvironment probes the x64
    # BUILD HOST, and a host GPU must never decide a TARGET flag. The branch is
    # dead today (GPU_TYPE=amd is never set), which is exactly when a latent
    # host-vs-target confusion survives longest.
    Write-Host 'AMD GPU detected: enabling ROCm'
    $gpuArgs += '-Donnxruntime_USE_ROCM=ON'
} else {
    Write-Host 'No GPU layer detected: CPU-only build'
}

# DirectML EP is ON. Its vendored DirectMLHelpers headers iterate a std::vector<OperatorField> while
# OperatorField is an incomplete type -- MSVC tolerates it, clang-cl (correctly) does not (llvm #57700).
# The "[clang-cl DML fix]" patch applied above (out-of-lining AbstractOperatorDesc's tensor accessors)
# makes it compile under clang-cl, so DirectML now builds on the clang-cl lane alongside CUDA/TensorRT.
# USE_DML=ON makes cmake fetch the Microsoft.AI.DirectML redist via NuGet (nuget.exe is pre-seeded).
# Python bindings are ON on both lanes (#120 step 2). The HOST interpreter RUNS
# the build (pybind11/numpy probes execute it), the TARGET python314.lib is what
# the .pyd LINKS; Get-TargetBuildPython encodes that split (.Exe host, .Include
# arch-neutral, .Lib target) and its .Available guard keeps the OFF path for a
# -ResumeFrom entry that skipped the cpython stage. History of the cross skip:
# docs/windows-cross-builds.md, "#120 step 2".
$tpy = Get-TargetBuildPython
$pythonArgs = if ($onnxCross -and -not $tpy.Available) {
    Write-Warning "ONNX: python bindings OFF -- no target CPython import lib at $($tpy.Lib) (build-target-cpython.ps1 did not run?)"
    @('-Donnxruntime_ENABLE_PYTHON=OFF')
} else {
    # `Python_*`, NOT `Python3_*`: ORT's CMake calls find_package(Python ...)
    # with the UNVERSIONED prefix. The Python3_* names this script passed until
    # 2026-08-24 were silently ignored on every lane ("Manually-specified
    # variables were not used by the project") -- amd64 only worked because
    # FindPython auto-detected the host interpreter and its numpy. The first
    # cross configure exposed it: `Target "onnxruntime_pybind11_state" links to
    # Python::NumPy but the target was not found`. The numpy include dir is
    # probed here by RUNNING the host interpreter (numpy headers are arch-
    # neutral) and handed over explicitly, so FindPython's own probing under
    # CMAKE_CROSSCOMPILING is not on the critical path.
    $numpyInc = (Invoke-ShieldedNative -Label 'numpy include probe' -CommandLine """$($tpy.Exe)"" -c ""import numpy; print(numpy.get_include())""" | Select-Object -Last 1)
    if (-not $numpyInc -or -not (Test-Path (Join-Path $numpyInc 'numpy\arrayobject.h'))) {
        throw "ONNX: numpy include dir not usable ('$numpyInc') -- numpy must be importable by the build interpreter $($tpy.Exe) before configure"
    }
    @('-Donnxruntime_ENABLE_PYTHON=ON') + @(Get-PythonCMakeHintArgs -Python $tpy -Prefix 'Python' -NumPyIncludeDir $numpyInc)
}
if ($onnxCross -and $tpy.Available) { Write-Host "ONNX: python bindings ON for the cross lane (#120 step 2) -- host interpreter $($tpy.Exe), TARGET import lib $($tpy.Lib)" }
# DirectML: ON on BOTH lanes since 2026-08-23 (#113; GenAI followed in #118).
# The one cross obstacle was the redist path-case mismatch patched above -- the
# nuget always shipped bin/arm64-win/DirectML.lib. The full measurement-and-
# retraction record (the "no ARM64 import library" misreading and the retracted
# "CPU + Vulkan" scope note) lives in docs/windows-cross-builds.md, DirectML row.
# On Snapdragon devices Microsoft points at the QNN EP rather than DML: DML is
# an available accelerator there, not the best one (QNN: opt-in below, #121).
$dmlArg = '-Donnxruntime_USE_DML=ON'
if ($onnxCross) { Write-Host 'ONNX: DirectML EP ON for the cross lane too (backlog #113 - the redist DOES ship bin/arm64-win/DirectML.lib; the old failure was an upper-case path, not a missing package)' }
# -- QNN EP (Qualcomm AI Engine Direct / QAIRT SDK) -- backlog #121. OPT-IN by
# staging the login-gated SDK zip in windows\qnn-sdk\ (bind-mounted at
# C:\temp\qnn-sdk by the onnx RUN). No zip = EP off with one notice -- the same
# graceful-skip contract as the TensorRT zip. SCAFFOLD, UNPROVEN: this host has
# never held the SDK, so every step asserts what it expects and the first
# staged zip proves or breaks it loudly, never silently. The EP is enabled on
# BOTH lanes (arm64: HTP/NPU + CPU backends, the point of the EP; amd64: CPU
# backend only, useful for graph-compatibility checks).
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
# #123 (2026-08-25): MLAS's amd64 kernels are MASM sources (mlas/lib/amd64/*.asm,
# "Building ASM_MASM object" in every amd64 log) and CMake's ASM_MASM default is
# MSVC's ml64 -- the last MSVC tool in the native build. llvm-ml is LLVM's
# MASM-compatible assembler; whether MLAS's macro-heavy dialect is inside its
# compatibility is the question this wiring answers by building. The cross
# lane assembles nothing through ASM_MASM (arm64 MLAS is .S / intrinsics), so
# the argument is native-only and its configure command line stays as it was.
if (-not $onnxCross) { $cmakeArgs += Get-LlvmMasmCmakeArg }
Switch-BuildPhase '3. cmake configure'
# Tee'd (not | Out-Null): the ASM_MASM identification lines are the proof #123
# needs, and a swallowed configure log is a "never swallow logs" violation.
$ortCfgLog = Get-PersistentBuildLogPath -Name 'onnxruntime-configure.log' -FallbackDir $buildDir
Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs 2>&1 |
    Tee-Object -FilePath $ortCfgLog
if (-not $onnxCross) {
    # CMake reports the assembler it found ("-- Found assembler: <path>" /
    # "The ASM_MASM compiler identification is ..."). It must be llvm-ml; a
    # silent fallback to ml64 is the exception this item removes.
    $masmLines = @(Get-Content $ortCfgLog | Where-Object { $_ -match 'ASM_MASM|Found assembler' })
    if ($masmLines.Count -eq 0 -or -not ($masmLines -join "`n" | Select-String -Pattern 'llvm-ml' -Quiet)) {
        throw "ORT configure did not report llvm-ml as the ASM_MASM assembler (#123). ASM_MASM lines: $(if ($masmLines.Count) { $masmLines -join ' | ' } else { '<none>' }) -- see $ortCfgLog"
    }
    Write-Host "ASM_MASM assembler (#123): $($masmLines -join ' | ')"
}
Switch-BuildPhase '4. post-configure _deps patches + ninja-file tags'

# -- Post-configure patches (fetched _deps trees; inline, NOT .patch files —
# static patches against CMake-fetched deps rot when ORT's dep pointer moves) --

# onnx (bundled proto library, ORT >= 1.28): scoped_resource.h declares
#   using ScopedHandle = ScopedResource<INVALID_HANDLE_VALUE, close_handle>;
# INVALID_HANDLE_VALUE is ((HANDLE)(LONG_PTR)-1) — a reinterpret_cast, which is
# NOT a valid non-type template argument under clang (MSVC accepts it as an
# extension). Replace the alias with an interface-identical RAII class holding
# the sentinel at runtime. (checker.cc uses ctor/get/release only.)
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

#   * CUTLASS is a CMake-fetched third-party dep; the fetched version's SHA varies
#     with onnxruntime's `cutlass-src` ExternalProject pointer. A static .patch
#     against a pinned tag would silently rot when the pinned SHA changes, so
#     the `Edit-CppKeywordAlternatives` helper walks the fetched tree and
#     the `_udiv128->udiv128` substitution targets `cutlass/uint128.h` directly.
# Same cross guard as the CUDA branch above: GPU_TYPE is IMAGE state and the
# toolchain image is shared by both lanes, so this CUTLASS patch pass would
# otherwise run on an arm64 build that has no CUDA sources to patch.
if ($env:GPU_TYPE -eq 'nvidia' -and -not $onnxCross) {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keyword alternatives.
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object { Edit-CppKeywordAlternatives -Path $_.FullName }
    }
    # CUTLASS uint128: clang-cl lacks the MSVC-only `_udiv128` intrinsic, and
    # CUTLASS enables the intrinsic branch for EVERY _MSC_VER >= 1920 (which
    # clang-cl defines). #73 POST-MORTEM (2026-08-20): the previous fix here
    # substituted `_udiv128 -> udiv128` - i.e. it rewrote the call INSIDE
    # udiv128 into a call to itself, hand-crafting the infinite recursion
    # behind all 225 -Winfinite-recursion warnings and a latent stack
    # overflow in the SHIPPED provider. The correct fix disables the
    # intrinsic GUARD for clang so CUTLASS falls back to its portable
    # 128-bit long-division loop (correct by construction; MSVC-proper
    # builds keep the intrinsic). Upstream candidate for NVIDIA/cutlass:
    # the guard should carry `&& !defined(__clang__)`.
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    # Idempotency (audit 2026-08-21): the pattern is a PREFIX of its own
    # replacement, so a resumed build (the _deps tree survives) re-appended
    # '&& !defined(__clang__)' on every pass — and after the first patch the
    # no-op drift warning could never fire again. Explicit already-applied
    # skip keeps resumes quiet AND keeps the drift warning meaningful.
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

# ADD AVX-512/AMX per-TU to MLAS's arch-specific objects in build.ninja.
# Polarity settled 2026-08-03 after three field failures:
#   * global flags  -> _deps protoc AND onnxruntime.dll static init execute
#                      AVX-512 on this AVX2-only host (load-time crash);
#   * no flags      -> MLAS's avx512/amx TUs fail to COMPILE (clang-cl gates
#                      intrinsics behind target features; ORT's mlas.cmake
#                      takes the MSVC branch under clang-cl and adds none).
# So: nothing gets the features globally; ONLY the MLAS TUs whose object paths
# name avx512/amx receive them — those kernels are runtime-dispatched and are
# never executed on CPUs without the features.
# Arch-parameterized (2026-08-22). The x86 pattern below used to be a literal,
# which matches NOTHING in an aarch64 tree -- and a patch that matches nothing
# SUCCEEDS. The build would have gone green with MLAS's NEON/dotprod/i8mm
# kernels compiled without their features: unoptimised at best, absent at worst,
# and undetectable from an x64 host that cannot execute the result.
$targetArch    = Get-WindowsTargetArch
$mlasArchFlags = Get-WindowsTargetKernelSimdFlags -Arch $targetArch
$mlasTuPattern = Get-MlasKernelTuPattern -Arch $targetArch
# SOURCE-DERIVED, not name-guessed (2026-08-23). Two rounds of extending the
# name pattern each uncovered another TU: first the whole *_fp16 family, then
# dwconv.cpp -- which carries neither 'fp16' nor 'kernel_neon' in its name yet
# includes fp16_common.h and inlines MlasMultiplyAddFloat16. Chasing names is
# whack-a-mole, and every miss is a compile error at best and an unoptimised
# kernel at worst.
#
# So on a cross target the name pattern is UNIONED with the set of MLAS sources
# that actually pull the fp16 intrinsic header. That set maintains itself across
# upstream churn: a new fp16 consumer is tagged the day it appears.
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
# Marker that proves a FLAGS line was already tagged, so a re-run does not
# append the set twice. Arch-specific for the same reason as the pattern:
# 'avx512' never appears in an aarch64 flag set.
$mlasTaggedMarker = if ($targetArch -eq 'amd64') { 'avx512' } else { 'dotprod' }

# The floor (Get-MlasKernelTuMinimum) is the guard, the pattern alone is not:
# a zero/low match means upstream renamed the kernels or the pattern is wrong
# for this target, and the dispatched kernels would silently lose their SIMD
# features -- undetectable downstream, and on a cross build the artifacts
# cannot even be executed. Below the floor the helper throws with the count and
# leaves build.ninja untouched (HARD FAILURE since 2026-08-22).
[void](Add-NinjaPerTuFlags -NinjaFile "$buildDir\build.ninja" -Label "MLAS $targetArch kernel (pattern: $mlasTuPattern)" -Floor $mlasTuMinimum -AlreadyTaggedPattern $mlasTaggedMarker -Select {
    param($line)
    if ($line -match 'onnxruntime_mlas\.dir' -and $line -match $mlasTuPattern) { $mlasArchFlags } else { '' }
})

# Memory-scaled parallelism: AVX-512/CUDA TUs under clang-cl peak at several GB each,
# so full -j<cores> can OOM the container. jobs = min(cores, memGB/4), floor 2
# (override with BUILD_JOBS). 4 GB/job is tuned to use more host cores; typical TUs
# use ~2-3 GB and only a few heavy CUDA kernels approach the cap. Ninja is
# incremental, so the -j2 retry after an OOM-style failure only redoes the jobs
# that died -- worst case is a slow tail, not a failed build.
# Ninja log on the PERSISTENT sccache cache mount (backlog #4): when this
# vertex fails, the container filesystem dies with the solve, but C:\sccache
# survives into the next run - the full ninja stream stays readable from a
# debug container (never-swallow-logs).
# Moved into the shared module 2026-08-14 (backlog #43): this block lived here
# ALONE for months while opencv/iree/tvm/litert silently kept losing their logs.
$ninjaLog = Get-PersistentBuildLogPath -Name 'onnx-ninja.log' -FallbackDir $buildDir
# MemGBPerJob=2 (backlog #28): runs 12+13 measured 9274 samples across the full
# ONNX vertex -- peak per-process WorkingSet 998 MB, peak fleet 5.5 GB at -j9.
# At 2 GB/job the job-count formula yields ~19 jobs (~11-12 GB extrapolated vs
# the 39 GB budget), roughly doubling parallelism on the long-pole ONNX build.
Switch-BuildPhase '5. ninja build + install'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 2 -MemGBPerJob 2 -Install -LogFile $ninjaLog

# Hit-rate evidence on STDERR - the stream the 2MiB step-log clip never
# truncates (AGENTS.md priority 1: caching must be MEASURED): C/CXX hits vs
# misses (CUDA is bare nvcc by design - see the launcher block above), and
# any 'Cache errors' pointing at a broken backend.
Write-SccacheStatsToStderr -Advanced -RequireRemote

# DirectML EP: onnxruntime.dll depends on DirectML.dll (fetched via NuGet during configure). cmake
# --install does not stage that redist, so a DML session would fail (0xC0000135) in the final image.
# Copy it next to the installed onnxruntime.dll (mirrors the tvm_ffi.dll staging). Must run BEFORE
# Remove-SourceBuildTree deletes the build tree. Verified by the smoke-test DmlExecutionProvider probe.
#
# -SidecarFilter (2026-08-24): the nuget unpacks DirectML.dll for EVERY platform
# (bin/x64-win, bin/x86-win, bin/arm-win, bin/arm64-win) and an unfiltered
# recursive pick takes whichever enumerates first -- the same arch-blind -First 1
# GenAI's D3D12Core staging already fixed. Pin it to the TARGET's redist dir;
# the merge arch gate then proves the pick, since the sidecar lands in its scan
# root. NB the dir name is the lower-cased platform (see the TOLOWER patch above).
$ortDmlArchDir = "$(Get-WindowsTargetArch)" -replace '^amd64$', 'x64'
Copy-SidecarDll -SidecarName 'DirectML.dll' -SearchDir $SourceDir `
    -SidecarFilter { $_.Directory.Name -eq "$ortDmlArchDir-win" } `
    -BesidePrimary 'onnxruntime.dll' -InstallDir $ortInstallDir `
    -Reason 'the DirectML EP may fail to load at runtime (0xC0000135)'

# QNN EP runtime (#121): the provider DLL is installed by cmake; the SDK's
# backend DLLs are NOT (they are redist, like DirectML.dll). Stage the whole
# per-arch backend set plus the hexagon skel dirs beside onnxruntime.dll, so a
# target host finds them on the DLL search path with no PATH surgery.
if ($qnnSdk) { [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $ortInstallDir) }

# -- Python wheel (onnxruntime) --
# ENABLE_PYTHON=ON made cmake assemble the full python package tree at
# $buildDir\onnxruntime (onnxruntime_python.cmake); the upstream wheel is just the
# source-root setup.py run as bdist_wheel FROM the build dir. No
# --wheel_name_suffix: our CUDA+TensorRT+DML combo matches no upstream package
# split, so it ships as plain `onnxruntime`. Must run BEFORE Remove-SourceBuildTree.
Switch-BuildPhase '6. python wheel'
# $onnxCross (a variable), NOT `Test-WindowsCrossTarget -and ...`: a condition
# that STARTS with a command name is parsed in command mode, so `-and -not
# $tpy.Available` became three ARGUMENTS to the function and the branch fired
# with the bindings ON (arm64 run 2, 2026-08-24: "python wheel 0s"). Same trap
# family as `-ExtraArgs @(...) + (...)`.
if ($onnxCross -and -not $tpy.Available) {
    Write-Host 'Skipping the onnxruntime python wheel: cross build without a target CPython (bindings were OFF above)'
} else {
    # One call for both lanes: -CrossStage builds + STAGES on a cross lane
    # (target --plat-name, every native member PE- and name-checked, never
    # imported here) and installs + import-asserts on the native lane.
    # Native lane: stage + install (WITH pypi deps) + import-assert, so the
    # shipped image can `import onnxruntime` out of the box (the media merge
    # fans CPython's site-packages into the image). The helper also
    # encapsulates the single-element array-unwrap footgun (the c-0.0.1
    # incident) and the EAP=Stop-safe import check.
    Write-Host 'Building onnxruntime python wheel...'
    Invoke-PythonWheelBuild -Python $py -WorkingDir $buildDir `
        -Arguments """$SourceDir\setup.py"" bdist_wheel" `
        -ModuleName 'onnxruntime' -CrossStage | Out-Null
}

Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnx'
Complete-SourceBuild -Banner '=== ONNX Runtime source build completed ===' -SourceDir $SourceDir  # cleanup + banner + exit 0 (see module help)
