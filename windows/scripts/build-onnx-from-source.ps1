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

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.28.0' -StripVPrefix

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

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
try {
    Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\003-dml-clangcl-compat.patch') -SourceDir $SourceDir -IgnoreWhitespace
} catch {
    Write-Host '003-dml-clangcl-compat.patch did not apply cleanly -- falling back to inline regex patcher'
    Invoke-OnnxDmlClangClPatch -SourceDir $SourceDir
}

$py = Initialize-ToolchainPythonEnvironment

# Python bindings ride this build (onnxruntime_ENABLE_PYTHON=ON below): pybind11
# needs numpy headers at compile time and the wheel step needs setuptools/wheel.
# (Initialize-ToolchainPythonEnvironment wrote the win-amd64 platform-tag shim, so
# pip resolves 64-bit wheels and our wheel tags correctly.)
Install-CpythonPip -Python $py
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
# Verify the count actually dropped: windows\scripts\Measure-BuildWarnings.ps1
$cxxFlags = "/WX- $(Get-WindowsX86SimdFlags) /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mf16c /clang:-Wno-invalid-specialization /clang:-Wno-unused-value"

# -- GPU detection (single shot via Get-GpuEnvironment; ONNX-specific flag names stay local) --
# ONNX_FORCE_CPU=1 forces a CPU-only ONNX (skips the ~1h CUDA/TensorRT kernel compiles) so the DirectML
# clang-cl patch can be iterated fast -- DirectML (USE_DML=ON) still builds and surfaces any clang-cl
# errors in ~15 min. Dev/iteration knob only; the media-core build never sets it.
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
$gpuArgs = @()
# if/elseif/else used in place of `switch ($gpuEnv.GpuType) { ... }` for broad compatibility
# with Windows PowerShell 5.1 (the switch-on-property syntax can trigger parser errors in PS 5.1).
if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) {
    Write-Host 'NVIDIA GPU detected: enabling CUDA + cuDNN'
    $cudaRoot = $gpuEnv.CudaRoot
    $cudnnRoot = $gpuEnv.CudnnRoot
    # Shared cuDNN import-lib finder (prefers cudnn.lib over the 9.x split sub-libs); $null when absent.
    $cudnnLib = Get-CudnnLibrary -CudnnRoot $cudnnRoot

    # CUDA 13.x CCCL breaks clang-cl PCH -- disable via a reviewable .patch (inline regex fallback for context drift).
    try {
        Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\002-disable-cuda-pch.patch') -SourceDir $SourceDir -IgnoreWhitespace
    } catch {
        Write-Host "002-disable-cuda-pch.patch did not apply cleanly -- falling back to inline regex"
        $pch = "$SourceDir\cmake\onnxruntime_providers_cuda.cmake"
        Invoke-InlineRegexPatch -Path $pch -Pattern 'target_precompile_headers\([^)]+\)' `
            -WarnMessage "onnxruntime_providers_cuda.cmake: no target_precompile_headers(...) call found to strip; the CUDA PCH may break the clang-cl build. Verify $pch." | Out-Null
    }
    # ORT 1.28.0 + CUDA 13.3: Windows headers in the CUDA include set define ERROR
    # (wingdi.h's `#define ERROR 0`, reached despite -DNOGDI) and can define VERBOSE;
    # either pre-expands through the LOGS_DEFAULT forwarding macro and token-pastes
    # into the nonexistent Severity::k0 inside tunable.h (nvcc: `enum
    # "onnxruntime::logging::Severity" has no member "k0"` at the LOGS_DEFAULT(ERROR)
    # line; first TU: triton_kernel.cu). Reviewable .patch first; inline #undef
    # insertion after the last tunable.h include as the context-drift fallback.
    try {
        Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\004-tunable-severity-macro-collision.patch') -SourceDir $SourceDir -IgnoreWhitespace
    } catch {
        Write-Host "004-tunable-severity-macro-collision.patch did not apply cleanly -- falling back to inline #undef insertion"
        $tunable = Join-Path $SourceDir 'onnxruntime\core\framework\tunable.h'
        Invoke-InlineRegexPatch -Path $tunable -Pattern '(#include "core/framework/tuning_context\.h")' `
            -Replacement ('$1' + "`n`n#ifdef ERROR`n#undef ERROR`n#endif`n#ifdef VERBOSE`n#undef VERBOSE`n#endif") `
            -WarnMessage "tunable.h: tuning_context include anchor not found; LOGS_DEFAULT(ERROR) will fail as Severity::k0. Verify $tunable." | Out-Null
    }

    # ORT 1.28.0 XQA kernels: the host-pass include guard in xqa_impl_gen.cuh keys on the
    # cmake-provided HAS_SM80_OR_LATER define, and sccache's nvcc decomposition
    # (CMAKE_CUDA_COMPILER_LAUNCHER) can drop target -D defines in the host sub-step -
    # the stub then fails with C2039/C2065 (`smemSize`/`kernelType`/`cacheVTileSeqLen`
    # missing from `H*::grp*_*` in x_?.cudafe1.stub.c). We always target sm80+
    # (CUDA_ARCHITECTURES 80;86;89;90), so the patch makes the host stub unconditional.
    try {
        Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\005-xqa-host-stub-sccache.patch') -SourceDir $SourceDir -IgnoreWhitespace
    } catch {
        Write-Host "005-xqa-host-stub-sccache.patch did not apply cleanly -- falling back to inline guard rewrite"
        $xqaGen = Join-Path $SourceDir 'onnxruntime\contrib_ops\cuda\bert\xqa\xqa_impl_gen.cuh'
        Invoke-InlineRegexPatch -Path $xqaGen -Pattern '#elif defined\(HAS_SM80_OR_LATER\) \|\| !defined\(__CUDACC__\)' `
            -Replacement '#else' `
            -WarnMessage "xqa_impl_gen.cuh: host-stub guard anchor not found; XQA host stubs may fail as C2039 smemSize/kernelType. Verify $xqaGen." | Out-Null
    }

        # clang-cl can't handle `and`/`or`/`not` keyword alternatives -- replace via a reviewable .patch.
        # If the .patch context has drifted upstream (common when ONNX rearranges comments), fall back
        # to the generic Edit-CppKeywordAlternatives helper against the two softmax source files.
        try {
            Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\001-softmax-clangcl-keywords.patch') -SourceDir $SourceDir -IgnoreWhitespace
        } catch {
            Write-Host "001-softmax-clangcl-keywords.patch did not apply cleanly -- falling back to keyword-alternatives in softmax sources"
            foreach ($sf in @('softmax.cc', 'softmax.h')) {
                $sfp = Join-Path $SourceDir 'onnxruntime\core\providers\cuda\math' $sf
                if (Test-Path $sfp) { Edit-CppKeywordAlternatives -Path $sfp }
            }
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
} elseif ($gpuEnv.GpuType -eq 'amd') {
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
$cmakeArgs = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    '-Donnxruntime_USE_DML=ON', '-Donnxruntime_ENABLE_PYTHON=ON', '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
    "-DPython3_EXECUTABLE=$($py.Exe)", "-DPython3_INCLUDE_DIR=$($py.Include)", "-DPython3_LIBRARY=$($py.Lib)"
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $gpuArgs
Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs | Out-Null

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
if ($env:GPU_TYPE -eq 'nvidia') {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keyword alternatives.
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object { Edit-CppKeywordAlternatives -Path $_.FullName }
    }
    # CUTLASS uint128: clang-cl lacks the MSVC-only `_udiv128` intrinsic.
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    Invoke-InlineRegexPatch -Path $cut -Pattern '_udiv128' -Replacement 'udiv128' `
        -WarnMessage "cutlass/uint128.h: _udiv128 not found; if CUTLASS still references the MSVC-only intrinsic, clang-cl will fail. Verify $cut." | Out-Null
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
$mlasArchFlags = Get-WindowsX86Avx512Flags
$ninjaFile = "$buildDir\build.ninja"
$ninjaLines = Get-Content $ninjaFile
$inMlasArch = $false
$mlasTagged = 0
for ($i = 0; $i -lt $ninjaLines.Count; $i++) {
    $line = $ninjaLines[$i]
    if ($line -match '^build ') {
        $inMlasArch = ($line -match 'onnxruntime_mlas\.dir' -and $line -match '(avx512|_amx|amx_|sqnbitgemm|qgemm_kernel_amx)')
    } elseif ($inMlasArch -and $line -match '^\s+FLAGS = ') {
        if ($line -notmatch 'avx512') {
            $ninjaLines[$i] = $line + ' ' + $mlasArchFlags
            $mlasTagged++
        }
    }
}
if ($mlasTagged -gt 0) {
    Set-Content -Path $ninjaFile -Value $ninjaLines
    Write-Host "build.ninja: added AVX-512/AMX flags to $mlasTagged MLAS arch TU FLAGS line(s) (runtime-dispatched kernels)"
} else {
    Write-Warning 'build.ninja: no MLAS avx512/amx FLAGS lines found to tag — if MLAS arch TUs fail to compile, the ninja layout no longer matches this pass.'
}

# Memory-scaled parallelism: AVX-512/CUDA TUs under clang-cl peak at several GB each,
# so full -j<cores> can OOM the container. jobs = min(cores, memGB/4), floor 2
# (override with BUILD_JOBS). 4 GB/job is tuned to use more host cores; typical TUs
# use ~2-3 GB and only a few heavy CUDA kernels approach the cap. Ninja is
# incremental, so the -j2 retry after an OOM-style failure only redoes the jobs
# that died -- worst case is a slow tail, not a failed build.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 2 -MemGBPerJob 4 -Install

# DirectML EP: onnxruntime.dll depends on DirectML.dll (fetched via NuGet during configure). cmake
# --install does not stage that redist, so a DML session would fail (0xC0000135) in the final image.
# Copy it next to the installed onnxruntime.dll (mirrors the tvm_ffi.dll staging). Must run BEFORE
# Remove-SourceBuildTree deletes the build tree. Verified by the smoke-test DmlExecutionProvider probe.
Copy-SidecarDll -SidecarName 'DirectML.dll' -SearchDir $SourceDir `
    -BesidePrimary 'onnxruntime.dll' -InstallDir $ortInstallDir `
    -Reason 'the DirectML EP may fail to load at runtime (0xC0000135)'

# -- Python wheel (onnxruntime) --
# ENABLE_PYTHON=ON made cmake assemble the full python package tree at
# $buildDir\onnxruntime (onnxruntime_python.cmake); the upstream wheel is just the
# source-root setup.py run as bdist_wheel FROM the build dir. No
# --wheel_name_suffix: our CUDA+TensorRT+DML combo matches no upstream package
# split, so it ships as plain `onnxruntime`. Must run BEFORE Remove-SourceBuildTree.
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

Remove-SourceBuildTree -Path $SourceDir
Write-Host '=== ONNX Runtime source build completed ==='

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0