# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = ''
)

# Inline initialization (avoids module-load dependency for the first media build script).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.27.0' -StripVPrefix

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive | Out-Null

$cmakeSrc = if (Test-Path "$SourceDir\cmake\CMakeLists.txt") { "$SourceDir\cmake" } else { $SourceDir }
$buildDir = "$SourceDir\build"
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"

# Inline patch (kept inline, NOT a .patch file): llvm-rc rejects non-ASCII bytes in the .rc resource.
# This is a binary byte-filter (`-le 127`), not a textual diff -- not expressible as a unified diff.
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

# -- DirectML EP clang-cl fix (needed because we build ONNX with clang-cl and enable USE_DML) --
# AbstractOperatorDesc and OperatorField are mutually recursive: AbstractOperatorDesc holds
# std::vector<OperatorField>, while OperatorField's variant (OperatorFieldTypes, GeneratedSchemaTypes.h)
# holds AbstractOperatorDesc by value. AbstractOperatorDesc's non-template tensor accessors are defined
# INLINE and call GetTensors<>(), which iterates/derefs OperatorField -- but there OperatorField is only
# forward-declared. MSVC compiles those bodies lazily (end-of-TU, OperatorField complete); clang-cl
# instantiates them eagerly while OperatorField is incomplete -> "member access into incomplete type /
# cannot increment const_iterator" (llvm #57700). Fix (textbook mutual-recursion resolution): turn the
# 4 accessors into DECLARATIONS in AbstractOperatorDesc.h and emit their DEFINITIONS out-of-line at the
# end of GeneratedSchemaTypes.h, after OperatorField is fully defined. GetTensors<>() (which dereferences
# OperatorField members) is likewise reduced to a template DECLARATION and defined out-of-line there --
# leaving NO OperatorField-touching body in AbstractOperatorDesc.h while the type is still incomplete.
$dmlHelpers  = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\External\DirectMLHelpers"
$dmlAbstract = Join-Path $dmlHelpers 'AbstractOperatorDesc.h'
$dmlTypes    = Join-Path $dmlHelpers 'GeneratedSchemaTypes.h'
if ((Test-Path $dmlAbstract) -and (Test-Path $dmlTypes)) {
    $abs = [System.IO.File]::ReadAllText($dmlAbstract)
    if ($abs -notmatch '\[clang-cl DML fix\]') {
        # Two things must move out-of-line so clang-cl never touches std::vector<OperatorField> or
        # OperatorField members while the type is incomplete:
        #  (1) the 4 tensor accessors (they call GetTensors<>() which iterates `fields`), and
        #  (2) AbstractOperatorDesc's special members -- the vector<OperatorField> member makes the
        #      implicit dtor/move instantiate the vector's element-dtor loop, and those get pulled in
        #      via std::optional<AbstractOperatorDesc> in OperatorFieldTypes (defined BEFORE OperatorField).
        $ctorRx = 'AbstractOperatorDesc\(\) = default;\r?\n\s*AbstractOperatorDesc\(const DML_OPERATOR_SCHEMA\* schema, std::vector<OperatorField>&& fields\)\r?\n\s*: schema\(schema\)\r?\n\s*, fields\(std::move\(fields\)\)\r?\n\s*\{\}'
        $accessorRx = '(?s)(std::vector<[^\r\n]+?> Get(?:Input|Output)Tensors\(\)(?: const)?)\r?\n\s*\{\r?\n\s*return GetTensors<[^\r\n]+?>\(\);\r?\n\s*\}'
        # The private GetTensors<>() template body dereferences OperatorField (field.GetSchema() etc.) --
        # collapse it to a declaration; its definition is emitted out-of-line below (after OperatorField).
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
            # Insert the fix marker right after the forward declaration so the guard above is stable.
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
            Write-Host "WARNING: [clang-cl DML fix] anchors not found (ctor=$ctorHit accessors=$accHit gettensors=$gtHit) -- DirectML may fail under clang-cl. Verify $dmlAbstract."
        }
    }
} else {
    Write-Host 'NOTE: DirectMLHelpers headers not found -- skipping the clang-cl DML fix (USE_DML build may fail).'
}

# [clang-cl DML fix #2] MLOperatorAuthorImpl.cpp's CASE_PROTO macro writes `initializer.##Z()`, pasting
# the `.` punctuator onto the field name (e.g. `.float_data_size`). That is not a valid preprocessing
# token: MSVC silently tolerates it, clang-cl errors (-Winvalid-token-paste). The `##` is spurious --
# `initializer.Z()` expands Z normally to the intended `initializer.float_data_size()`. Drop the paste.
$dmlAuthorImpl = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\MLOperatorAuthorImpl.cpp"
if (Test-Path $dmlAuthorImpl) {
    $impl = [System.IO.File]::ReadAllText($dmlAuthorImpl)
    if ($impl -match '\.##Z\(\)') {
        $impl = $impl -replace '(initializer)\.##Z\(\)', '$1.Z()'
        [System.IO.File]::WriteAllText($dmlAuthorImpl, $impl)
        Write-Host 'Applied [clang-cl DML fix #2]: dropped spurious `.##Z` token-paste in MLOperatorAuthorImpl.cpp CASE_PROTO'
    } else {
        Write-Host 'NOTE: [clang-cl DML fix #2] `.##Z` token-paste not found in MLOperatorAuthorImpl.cpp (already fixed upstream?) -- skipping.'
    }
}

# [clang-cl DML fix #3] DmlDFT.h and DmlGridSample.h declare `template <typename TConstants, uint32_t TSize>`
# and deduce TSize from `std::array<ID3D12Resource*, TSize>&`. std::array's size parameter is size_t
# (unsigned long long on Win64), so clang refuses to deduce a uint32_t TSize from a size_t value
# ("deduced non-type template argument does not have the same type"); MSVC allows the narrowing. Widen
# the parameter to size_t so deduction matches (TSize only sizes small local arrays / loop counts).
$dmlOps = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\Operators"
foreach ($opHeader in @('DmlDFT.h', 'DmlGridSample.h')) {
    $opPath = Join-Path $dmlOps $opHeader
    if (Test-Path $opPath) {
        $op = [System.IO.File]::ReadAllText($opPath)
        if ($op -match 'template <typename TConstants, uint32_t TSize>') {
            $op = $op -replace 'template <typename TConstants, uint32_t TSize>', 'template <typename TConstants, size_t TSize>'
            [System.IO.File]::WriteAllText($opPath, $op)
            Write-Host "Applied [clang-cl DML fix #3]: widened Dispatch<TSize> to size_t in $opHeader"
        } else {
            Write-Host "NOTE: [clang-cl DML fix #3] uint32_t TSize decl not found in $opHeader (already fixed upstream?) -- skipping."
        }
    }
}

$py = Initialize-ToolchainPythonEnvironment

# ONNX-specific CPU feature flags added on top of the shared SIMD base.
# mwaitpkg is required by spin_pause.cc (_tpause intrinsic); aes/pclmul are
# used by CUDA provider crc64; f16c accelerates float16 on Haswell+.
$cxxFlags = "/WX- $(Get-WindowsX86SimdFlags) /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mf16c $(Get-WindowsX86Avx512Flags) /clang:-Wno-invalid-specialization"

# -- GPU detection (single shot via Get-GpuEnvironment; ONNX-specific flag names stay local) --
$gpuEnv = Get-GpuEnvironment
# ONNX_FORCE_CPU=1 forces a CPU-only ONNX (skips the ~1h CUDA/TensorRT kernel compiles) so the DirectML
# clang-cl patch can be iterated fast -- DirectML (USE_DML=ON) still builds and surfaces any clang-cl
# errors in ~15 min. Dev/iteration knob only; the media-core build never sets it.
if ($env:ONNX_FORCE_CPU -eq '1') {
    Write-Host 'ONNX_FORCE_CPU=1 -> CPU-only ONNX build (fast DirectML-patch iteration; CUDA/TensorRT disabled)'
    $gpuEnv = @{ GpuType = 'none'; CudaRoot = $null; CudnnRoot = $null; TensorRtRoot = $null }
}
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
        # clang-cl can't handle `and`/`or`/`not` keyword alternatives -- replace via a reviewable .patch.
        # If the .patch context has drifted upstream (common when ONNX rearranges comments), fall back
        # to the generic Replace-CppKeywordAlternatives helper against the two softmax source files.
        try {
            Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\001-softmax-clangcl-keywords.patch') -SourceDir $SourceDir -IgnoreWhitespace
        } catch {
            Write-Host "001-softmax-clangcl-keywords.patch did not apply cleanly -- falling back to keyword-alternatives in softmax sources"
            foreach ($sf in @('softmax.cc', 'softmax.h')) {
                $sfp = Join-Path $SourceDir 'onnxruntime\core\providers\cuda\math' $sf
                if (Test-Path $sfp) { Replace-CppKeywordAlternatives -Path $sfp }
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
    $gpuArgs += "-DCMAKE_CUDA_COMPILER:FILEPATH=$cudaRoot\bin\nvcc.exe"
    $gpuArgs += "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$((Get-Command cl.exe -ErrorAction Stop).Source)"
    $gpuArgs += '-DCMAKE_CUDA_STANDARD:STRING=17'
    $gpuArgs += "-DCMAKE_CUDA_ARCHITECTURES=$(Get-CudaArchitectureList -Decoration '-real')"
    $gpuArgs += "-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/wd4067 -Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING"
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
    '-Donnxruntime_USE_DML=ON', '-Donnxruntime_ENABLE_PYTHON=OFF', '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
    "-DPython3_EXECUTABLE=$($py.Exe)", "-DPython3_INCLUDE_DIR=$($py.Include)", "-DPython3_LIBRARY=$($py.Lib)"
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $gpuArgs
Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs | Out-Null

# -- Post-configure patches (NVIDIA CUDA + CUTLASS) --
# Inline patches (kept inline, NOT .patch files):
#   * CUTLASS is a CMake-fetched third-party dep; the fetched version's SHA varies
#     with onnxruntime's `cutlass-src` ExternalProject pointer. A static .patch
#     against a pinned tag would silently rot when the pinned SHA changes, so
#     the `Replace-CppKeywordAlternatives` helper walks the fetched tree and
#     the `_udiv128->udiv128` substitution targets `cutlass/uint128.h` directly.
if ($env:GPU_TYPE -eq 'nvidia') {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keyword alternatives.
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object { Replace-CppKeywordAlternatives -Path $_.FullName }
    }
    # CUTLASS uint128: clang-cl lacks the MSVC-only `_udiv128` intrinsic.
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    Invoke-InlineRegexPatch -Path $cut -Pattern '_udiv128' -Replacement 'udiv128' `
        -WarnMessage "cutlass/uint128.h: _udiv128 not found; if CUTLASS still references the MSVC-only intrinsic, clang-cl will fail. Verify $cut." | Out-Null
    # CUTLASS cute/array_subbyte: suppressed via -Wno-invalid-specialization above
}

# Strip MSVC-only flags from build.ninja
Update-NinjaFile -NinjaFile "$buildDir\build.ninja" -StripPatterns @(
    '--compiler-options /experimental:external\s*',
    '(?<=\s)/experimental:external(?=\s)',
    '(?<=\s)-WX(?=\s)',
    '/arch:\S+',
    '(?<!-Xcompiler\s)/bigobj',
    '--threads \d+'
)

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
$installedOrtDll = Get-ChildItem -Path $ortInstallDir -Filter 'onnxruntime.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($installedOrtDll) {
    $dmlDll = Get-ChildItem -Path $SourceDir -Filter 'DirectML.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dmlDll) {
        Copy-Item $dmlDll.FullName -Destination $installedOrtDll.DirectoryName -Force
        Write-Host "Staged DirectML.dll ($($dmlDll.FullName)) -> $($installedOrtDll.DirectoryName)"
    } else {
        Write-Host 'WARNING: DirectML.dll not found under build tree -- DML EP may fail to load at runtime'
    }
}

Remove-SourceBuildTree -Path $SourceDir
Write-Host '=== ONNX Runtime source build completed ==='


