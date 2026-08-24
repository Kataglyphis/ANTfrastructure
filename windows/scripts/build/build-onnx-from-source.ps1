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

# Inline patch (kept inline, NOT a .patch file): llvm-rc rejects non-ASCII bytes in the .rc resource.
# This is a binary byte-filter (`-le 127`), not a textual diff -- not expressible as a unified diff.
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

function Invoke-OnnxDmlClangClPatch {
    param([Parameter(Mandatory)][string]$SourceDir)

    $dmlHelpers  = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\External\DirectMLHelpers"
    $dmlAbstract = Join-Path $dmlHelpers 'AbstractOperatorDesc.h'
    $dmlTypes    = Join-Path $dmlHelpers 'GeneratedSchemaTypes.h'
    if ((Test-Path $dmlAbstract) -and (Test-Path $dmlTypes)) {
        $abs = [System.IO.File]::ReadAllText($dmlAbstract)
        if ($abs -notmatch '\[clang-cl DML fix\]') {
            $ctorRx = 'AbstractOperatorDesc\(\) = default;\r?\n\s*AbstractOperatorDesc\(const DML_OPERATOR_SCHEMA\* schema, std::vector<OperatorField>&& fields\)\r?\n\s*: schema\(schema\)\r?\n\s*, fields\(std::move\(fields\)\)\r?\n\s*\{\}'
            $accessorRx = '(?s)(std::vector<[^\r\n]+?> Get(?:Input|Output)Tensors\(\)(?: const)?)\r?\n\s*\{\r?\n\s*return GetTensors<[^\r\n]+?>\(\);\r?\n\s*\}'
            $getTensorsRx = '(?s)template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>\r?\n\s*std::vector<TensorType\*> GetTensors\(\) const\r?\n\s*\{.*?return tensors;\r?\n\s*\}'
            $ctorHit = [regex]::IsMatch($abs, $ctorRx)
            $accHit  = ([regex]::Matches($abs, $accessorRx)).Count
            $gtHit   = ([regex]::Matches($abs, $getTensorsRx)).Count
            if ($ctorHit -and $accHit -eq 4 -and $gtHit -eq 1) {
                $ctorDecls = @'
AbstractOperatorDesc();
    AbstractOperatorDesc(const DML_OPERATOR_SCHEMA* schema, std::vector<OperatorField>&& fields);
    AbstractOperatorDesc(const AbstractOperatorDesc&);
    AbstractOperatorDesc(AbstractOperatorDesc&&) noexcept;
    AbstractOperatorDesc& operator=(const AbstractOperatorDesc&);
    AbstractOperatorDesc& operator=(AbstractOperatorDesc&&) noexcept;
    ~AbstractOperatorDesc();
'@
                $gtDecl = @'
template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>
    std::vector<TensorType*> GetTensors() const;
'@
                $abs = [regex]::Replace($abs, $ctorRx, $ctorDecls)
                $abs = [regex]::Replace($abs, $accessorRx, '$1;')
                $abs = [regex]::Replace($abs, $getTensorsRx, $gtDecl)
                $abs = $abs -replace '(class OperatorField;)', "`$1`r`n// [clang-cl DML fix] special members + GetTensors + accessors moved out-of-line to GeneratedSchemaTypes.h"
                [System.IO.File]::WriteAllText($dmlAbstract, $abs)
                $outOfLine = @'

// [clang-cl DML fix] Out-of-line AbstractOperatorDesc members. Defined here, AFTER OperatorField is
// complete, so the std::vector<OperatorField> special members (dtor/move), GetTensors<>() and the 4
// tensor accessors instantiate against a complete type. Left inline they instantiate via
// optional<AbstractOperatorDesc> while OperatorField is still forward-declared, which clang-cl rejects
// (MSVC defers method/special-member instantiation to end-of-TU, where the type is complete).
inline AbstractOperatorDesc::AbstractOperatorDesc() = default;
inline AbstractOperatorDesc::AbstractOperatorDesc(const DML_OPERATOR_SCHEMA* schema, std::vector<OperatorField>&& fields)
    : schema(schema), fields(std::move(fields)) {}
inline AbstractOperatorDesc::AbstractOperatorDesc(const AbstractOperatorDesc&) = default;
inline AbstractOperatorDesc::AbstractOperatorDesc(AbstractOperatorDesc&&) noexcept = default;
inline AbstractOperatorDesc& AbstractOperatorDesc::operator=(const AbstractOperatorDesc&) = default;
inline AbstractOperatorDesc& AbstractOperatorDesc::operator=(AbstractOperatorDesc&&) noexcept = default;
inline AbstractOperatorDesc::~AbstractOperatorDesc() = default;
template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>
std::vector<TensorType*> AbstractOperatorDesc::GetTensors() const
{
    std::vector<TensorType*> tensors;
    for (auto& field : fields)
    {
        const DML_SCHEMA_FIELD* fieldSchema = field.GetSchema();
        if (fieldSchema->Kind != Kind)
        {
            continue;
        }

        if (fieldSchema->Type == DML_SCHEMA_FIELD_TYPE_TENSOR_DESC)
        {
            auto& tensor = field.AsTensorDesc();
            tensors.push_back(tensor ? const_cast<TensorType*>(&*tensor) : nullptr);
        }
        else if (fieldSchema->Type == DML_SCHEMA_FIELD_TYPE_TENSOR_DESC_ARRAY)
        {
            auto& tensorArray = field.AsTensorDescArray();
            if (tensorArray)
            {
                for (auto& tensor : *tensorArray)
                {
                    tensors.push_back(const_cast<TensorType*>(&tensor));
                }
            }
        }
    }
    return tensors;
}
inline std::vector<DmlBufferTensorDesc*> AbstractOperatorDesc::GetInputTensors()
{
    return GetTensors<DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_INPUT_TENSOR>();
}
inline std::vector<const DmlBufferTensorDesc*> AbstractOperatorDesc::GetInputTensors() const
{
    return GetTensors<const DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_INPUT_TENSOR>();
}
inline std::vector<DmlBufferTensorDesc*> AbstractOperatorDesc::GetOutputTensors()
{
    return GetTensors<DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_OUTPUT_TENSOR>();
}
inline std::vector<const DmlBufferTensorDesc*> AbstractOperatorDesc::GetOutputTensors() const
{
    return GetTensors<const DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_OUTPUT_TENSOR>();
}
'@
                [System.IO.File]::AppendAllText($dmlTypes, $outOfLine)
                Write-Host 'Applied [clang-cl DML fix]: out-of-lined AbstractOperatorDesc special members + GetTensors + 4 tensor accessors'
            } else {
                Write-Warning "[clang-cl DML fix] anchors not found (ctor=$ctorHit accessors=$accHit gettensors=$gtHit) -- DirectML may fail under clang-cl. Verify $dmlAbstract."
            }
        }
    } else {
        Write-Warning 'DirectMLHelpers headers not found -- skipping the clang-cl DML fix (USE_DML build may fail).'
    }

    $dmlAuthorImpl = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\MLOperatorAuthorImpl.cpp"
    [void](Invoke-InlineRegexPatch -Path $dmlAuthorImpl `
            -Pattern '(initializer)\.##Z\(\)' -Replacement '$1.Z()' `
            -Description 'clang-cl DML fix #2 (dropped spurious `.##Z` token-paste in MLOperatorAuthorImpl.cpp CASE_PROTO)' `
            -WarnMessage '[clang-cl DML fix #2] `.##Z` token-paste not found in MLOperatorAuthorImpl.cpp (already fixed upstream?) -- skipping.')

    $dmlOps = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\Operators"
    foreach ($opHeader in @('DmlDFT.h', 'DmlGridSample.h')) {
        [void](Invoke-InlineRegexPatch -Path (Join-Path $dmlOps $opHeader) `
                -Pattern 'template <typename TConstants, uint32_t TSize>' `
                -Replacement 'template <typename TConstants, size_t TSize>' `
                -Description "clang-cl DML fix #3 (widened Dispatch<TSize> to size_t in $opHeader)" `
                -WarnMessage "[clang-cl DML fix #3] uint32_t TSize decl not found in $opHeader (already fixed upstream?) -- skipping.")
    }
}

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
    $dmlText = Get-Content -LiteralPath $dmlProviders -Raw
    if ($dmlText -notmatch 'onnxruntime_dml_redist_platform') {
        # Define the lower-cased variable just above the first consumer, then
        # point both consumers at it. Two separate edits so a future upstream
        # move of either line degrades to a loud warning, not a silent miss.
        [void](Invoke-InlineRegexPatch -Path $dmlProviders `
                -Guard 'if \(NOT onnxruntime_USE_CUSTOM_DIRECTML\)' `
                -Pattern '(?m)^(\s*)if \(NOT onnxruntime_USE_CUSTOM_DIRECTML\)' `
                -Replacement "`${1}string(TOLOWER `"`${onnxruntime_target_platform}`" onnxruntime_dml_redist_platform)`n`${1}if (NOT onnxruntime_USE_CUSTOM_DIRECTML)" `
                -Description 'onnxruntime DML: lower-case the redist platform dir (define)')
        [void](Invoke-InlineRegexPatch -Path $dmlProviders `
                -Guard 'bin/\$\{onnxruntime_target_platform\}-win' `
                -Pattern 'bin/\$\{onnxruntime_target_platform\}-win' `
                -Replacement 'bin/${onnxruntime_dml_redist_platform}-win' `
                -Description 'onnxruntime DML: lower-case the redist platform dir (consumers)')
        $dmlText = Get-Content -LiteralPath $dmlProviders -Raw
        if ($dmlText -match 'bin/\$\{onnxruntime_target_platform\}-win' -or $dmlText -notmatch 'string\(TOLOWER') {
            throw ("onnxruntime_providers_dml.cmake: the DirectML redist path-case fix did not apply cleanly " +
                   "(upstream layout changed?). On ARM64 the build will fail with 'bin/ARM64-win/DirectML.lib " +
                   "missing and no known rule to make it', which looks like a missing package but is not. Re-check $dmlProviders.")
        }
        Write-Host 'Patched onnxruntime DML: redist platform dir lower-cased (fixes bin/ARM64-win vs bin/arm64-win)'
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
if ($gpuEnv.HasCuda -and -not (Test-WindowsCrossTarget)) {
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
} elseif ($gpuEnv.GpuType -eq 'amd' -and -not (Test-WindowsCrossTarget)) {
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
# Python bindings are OFF on a cross lane, and the Python3_* hints are dropped
# with them (measured 2026-08-23, first arm64 configure): $py resolves the HOST
# x64 interpreter -- Get-SourceBuildPython is host-pinned by design, since an
# aarch64 python.exe cannot run here -- so ENABLE_PYTHON=ON hands
# onnxruntime_python.cmake an x64 python314.lib to link an aarch64 module
# against. It fails at target_link_libraries with Python3_INCLUDE_DIR /
# Python3_LIBRARY reported as unresolved, which reads like a missing-Python
# problem and is really a wrong-architecture one.
#
# Producing a target binding needs a TARGET CPython, which this lane does not
# build. Same call as build-opencv-from-source.ps1's BUILD_opencv_python3.
$onnxCross = Test-WindowsCrossTarget
# #120 step 2 (2026-08-24): the paragraph above is HISTORY. A target CPython
# now exists (build-target-cpython.ps1 runs first in this chain), so the
# bindings are ON for the cross lane too -- composed the only correct way:
#   Python3_EXECUTABLE -> the HOST interpreter (pybind11/numpy probes RUN it)
#   Python3_INCLUDE_DIR -> arch-neutral headers
#   Python3_LIBRARY     -> the TARGET python314.lib (the .pyd LINKS it)
# Get-TargetBuildPython encodes exactly that split. Its .Available guard keeps
# the OFF path for a -ResumeFrom entry that skipped the cpython stage.
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
    @('-Donnxruntime_ENABLE_PYTHON=ON',
      "-DPython_EXECUTABLE=$($tpy.Exe)", "-DPython_INCLUDE_DIR=$($tpy.Include)", "-DPython_LIBRARY=$($tpy.Lib)",
      "-DPython_NumPy_INCLUDE_DIR=$numpyInc")
}
if ($onnxCross -and $tpy.Available) { Write-Host "ONNX: python bindings ON for the cross lane (#120 step 2) -- host interpreter $($tpy.Exe), TARGET import lib $($tpy.Lib)" }
# HISTORY, CORRECTED -- nothing in this block is current policy. The mistaken
# measurement, the mistaken scope note, and their retractions are kept together
# so the wrong reading cannot come back; the CURRENT paragraph at the end is
# the only part to act on.
#
# MEASURED 2026-08-23, first arm64 ninja run: the build died with
#   'packages/Microsoft.AI.DirectML.1.15.4/bin/ARM64-win/DirectML.lib' ...
#   missing and no known rule to make it
# and that was read as "the redist carries no ARM64 import library", which became
# the stated evidence for scoping the whole lane to "CPU + Vulkan".
#
# THAT READING WAS WRONG (2026-08-23, same day). The nuget does ship it -- 1.15.4
# contains bin/arm64-win/DirectML.lib, machine 0xAA64 -- in a LOWER-case directory,
# while onnxruntime composed an UPPER-case one. A missing ninja node and a missing
# package produce the same message; only one of them was true. The fix is the
# path-case patch above, and DML is now ON for both lanes.
#
# What remains true from the old note, and is worth keeping: Microsoft's guidance
# for Snapdragon devices points at the QNN execution provider rather than DML, so
# DML working here does not make it the best accelerator on that hardware -- it
# makes it an available one. QNN would need the Qualcomm AI Engine SDK, which this
# stack does not integrate.
#
# RETRACTED SCOPE NOTE (wrong from the day it was written, 2026-08-23): "turning
# it on for arm64 again is a deliberate spike, not a flag flip: it needs a
# redist that actually ships bin\ARM64-win\DirectML.lib ... until then the
# arm64 lane is CPU + Vulkan". The redist ALWAYS shipped that library (in the
# lower-case dir, see above), so no spike was needed and the lane was never
# DML-incapable -- and the lane scope is CPU + DirectML + Vulkan, not
# CPU + Vulkan.
#
# CURRENT: ENABLED ON BOTH LANES since 2026-08-23 (backlog #113); GenAI's build
# followed with USE_DML=ON on both lanes in #118 (2026-08-24). The redist-path
# case fix applied above is what unblocked it; see that comment for why the old
# failure looked like a missing package. The scope note ABOVE is kept as the
# record of what was believed, and corrected -- not as current fact.
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
$qnnArgs = @()
$qnnRuntimeHome = $null
$qnnDrop = 'C:\temp\qnn-sdk'
$qnnZips = @(Get-ChildItem -Path $qnnDrop -Filter '*.zip' -File -ErrorAction SilentlyContinue)
if ($qnnZips.Count -gt 1) { throw "ONNX/QNN: exactly one SDK zip may sit in windows\qnn-sdk (found $($qnnZips.Count)): $($qnnZips.Name -join ', ')" }
if ($qnnZips.Count -eq 1) {
    $qnnZip = $qnnZips[0].FullName
    $qnnSha = "$env:QNN_SDK_ZIP_SHA256".Trim()
    if ($qnnSha) {
        $qnnActual = (Get-FileHash -Algorithm SHA256 -Path $qnnZip).Hash
        if (-not [string]::Equals($qnnActual, $qnnSha, [StringComparison]::OrdinalIgnoreCase)) { throw "ONNX/QNN: SDK zip SHA256 mismatch for ${qnnZip}: expected $qnnSha, got $qnnActual" }
        Write-Host 'ONNX/QNN: SDK zip SHA256 verified (QNN_SDK_ZIP_SHA256).'
    } else {
        Write-Warning 'ONNX/QNN: QNN_SDK_ZIP_SHA256 is empty -- extracting the staged SDK zip UNVERIFIED (pin it in versions.env, same contract as TENSORRT_ZIP_SHA256)'
    }
    $qnnExtract = Join-Path $env:TEMP_DIR 'qnn-sdk-extract'
    if (Test-Path $qnnExtract) { Remove-Item $qnnExtract -Recurse -Force }
    Expand-Archive -Path $qnnZip -DestinationPath $qnnExtract -Force
    # The SDK root is wherever include\QNN\QnnInterface.h lives (qairt\<version>\ in every SDK layout seen).
    $qnnAnchor = Get-ChildItem -Path $qnnExtract -Recurse -Filter 'QnnInterface.h' -File | Where-Object { $_.Directory.Name -eq 'QNN' } | Select-Object -First 1
    if (-not $qnnAnchor) { throw "ONNX/QNN: include\QNN\QnnInterface.h not found under the extracted SDK ($qnnExtract) -- not a QAIRT SDK zip?" }
    $qnnRuntimeHome = $qnnAnchor.Directory.Parent.Parent.FullName
    $qnnLibDir = Join-Path $qnnRuntimeHome "lib\$(Get-QnnSdkLibDirName)"
    if (-not (Test-Path (Join-Path $qnnLibDir 'QnnCpu.dll'))) { throw "ONNX/QNN: $qnnLibDir\QnnCpu.dll missing -- the SDK carries no $(Get-QnnSdkLibDirName) backend set for this target" }
    $qnnArgs = @('-Donnxruntime_USE_QNN=ON', "-Donnxruntime_QNN_HOME=$($qnnRuntimeHome -replace '\\', '/')")
    Write-Host "ONNX: QNN EP ON (SDK root $qnnRuntimeHome, backends from lib\$(Get-QnnSdkLibDirName)) -- backlog #121"
} else {
    Write-Host 'ONNX: QNN EP off -- no SDK zip staged in windows\qnn-sdk (opt-in; see windows\qnn-sdk\README.md, backlog #121)'
}
$cmakeArgs = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    $dmlArg, '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
) + $pythonArgs + @(
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $gpuArgs + $qnnArgs
Switch-BuildPhase '3. cmake configure'
Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs | Out-Null
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
if ($env:GPU_TYPE -eq 'nvidia' -and -not (Test-WindowsCrossTarget)) {
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
if (Test-WindowsCrossTarget -Arch $targetArch) {
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

$ninjaFile = "$buildDir\build.ninja"
$ninjaLines = Get-Content $ninjaFile
$inMlasArch = $false
$mlasTagged = 0
for ($i = 0; $i -lt $ninjaLines.Count; $i++) {
    $line = $ninjaLines[$i]
    if ($line -match '^build ') {
        $inMlasArch = ($line -match 'onnxruntime_mlas\.dir' -and $line -match $mlasTuPattern)
    } elseif ($inMlasArch -and $line -match '^\s+FLAGS = ') {
        if ($line -notmatch $mlasTaggedMarker) {
            $ninjaLines[$i] = $line + ' ' + $mlasArchFlags
            $mlasTagged++
        }
    }
}
if ($mlasTagged -ge $mlasTuMinimum) {
    Set-Content -Path $ninjaFile -Value $ninjaLines
    Write-Host "build.ninja: added $targetArch kernel SIMD flags to $mlasTagged MLAS arch TU FLAGS line(s) (runtime-dispatched kernels)"
} else {
    # HARD FAILURE, not a warning (2026-08-22). A zero/low match count means the
    # ninja layout no longer matches this pass -- upstream renamed the kernels,
    # or the pattern is wrong for this target. Either way the dispatched kernels
    # silently lose their features, which nothing downstream can detect: on a
    # cross build the artifacts cannot even be executed. The floor is the guard;
    # the pattern alone is not.
    throw ("build.ninja: tagged only $mlasTagged MLAS kernel TU FLAGS line(s) for $targetArch, expected at least " +
           "$mlasTuMinimum (pattern: $mlasTuPattern). The MLAS ninja layout no longer matches this pass, so the " +
           'runtime-dispatched kernels would be built WITHOUT their SIMD features. Update ' +
           'Get-MlasKernelTuPattern in WindowsTargetArch.Common.psm1 to match the current upstream tree.')
}

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
if ($qnnRuntimeHome) {
    $qnnBinOut = Split-Path (Get-ChildItem -Path $ortInstallDir -Recurse -Filter 'onnxruntime.dll' -File | Select-Object -First 1).FullName -Parent
    $qnnProvider = Get-ChildItem -Path $ortInstallDir -Recurse -Filter 'onnxruntime_providers_qnn.dll' -File | Select-Object -First 1
    if (-not $qnnProvider) { throw "ONNX/QNN: onnxruntime_providers_qnn.dll was not installed under $ortInstallDir although USE_QNN=ON -- the EP did not build" }
    $qnnSdkLib = Join-Path $qnnRuntimeHome "lib\$(Get-QnnSdkLibDirName)"
    $qnnStaged = @(Get-ChildItem -Path $qnnSdkLib -Filter '*.dll' -File)
    foreach ($d in $qnnStaged) { Copy-Item $d.FullName -Destination $qnnBinOut -Force }
    foreach ($skel in @(Get-ChildItem -Path (Join-Path $qnnRuntimeHome 'lib') -Directory -Filter 'hexagon-v*')) {
        Copy-Item $skel.FullName -Destination (Join-Path $qnnBinOut $skel.Name) -Recurse -Force
    }
    Write-Host "ONNX/QNN: staged $($qnnStaged.Count) backend DLL(s) from $qnnSdkLib + hexagon skel dirs beside $($qnnProvider.Name) in $qnnBinOut"
}

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
} elseif ($onnxCross) {
    # #120 step 2: BUILD + STAGE the wheel; never install/import it here (the
    # .pyd is aarch64, the interpreter that would import it is x64). bdist_wheel
    # is the HOST python zipping files -- no target code executes -- but it
    # stamps the platform tag from the HOST's sysconfig (host-pinned shim, see
    # Initialize-PythonPlatformTag), so the target tag must be passed
    # explicitly. -StageOnly then opens the wheel and PE-checks every native
    # member, which is the only place a host-arch .pyd inside the zip would be
    # caught (the merge arch gate does not look into archives).
    Write-Host "Building onnxruntime python wheel for the target (--plat-name $(Get-PythonWheelTag); staged, not installed)..."
    Invoke-PythonWheelBuild -Python $py -WorkingDir $buildDir `
        -Arguments """$SourceDir\setup.py"" bdist_wheel --plat-name $(Get-PythonWheelTag)" `
        -ModuleName 'onnxruntime' -StageOnly | Out-Null
} else {
Write-Host 'Building onnxruntime python wheel...'
# Shared wheel-build shape (was duplicated verbatim with the GenAI script):
# stage + install (WITH pypi deps) + import-assert, so the shipped image can
# `import onnxruntime` out of the box (the media merge fans CPython's
# site-packages into the image). The helper also encapsulates the
# single-element array-unwrap footgun (the c-0.0.1 incident) and the
# EAP=Stop-safe import check.
Invoke-PythonWheelBuild -Python $py -WorkingDir $buildDir `
    -Arguments """$SourceDir\setup.py"" bdist_wheel" `
    -ModuleName 'onnxruntime' | Out-Null
}

Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnx'
Complete-SourceBuild -Banner '=== ONNX Runtime source build completed ===' -SourceDir $SourceDir  # cleanup + banner + exit 0 (see module help)