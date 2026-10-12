#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# ai-edge-litert for the pinned Python: upstream's own bazel wheel target, built with Bazel 7's clang-cl toolchain (CON91).
[CmdletBinding()]
param(
    [string]$ScriptDir = 'C:\temp\scripts',
    [string]$WheelDir = 'C:\runtime\wheels',
    # Everything bazel writes, the clone and the hermetic Python live here and leave the layer at the end.
    [string]$WorkRoot = 'C:\lw',
    # A mounted cache for bazel.exe and the accelerator wheel only; bazel's own caches rename files, which the mount breaks.
    [string]$ToolCache = '',
    # Keeps $WorkRoot for an incremental retry in a reused container.
    [switch]$KeepTree,
    # Development runs: bazel --keep_going, so one build lists every failing action.
    [switch]$KeepGoing
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

foreach ($m in 'WindowsSourceBuild.Common', 'WindowsSourceBuild.Patches', 'WindowsTargetArch.Common') {
    Import-Module (Join-Path $ScriptDir "modules\$m.psm1") -Force -DisableNameChecking
}
# The stage mounts WindowsBazel.Common beside the shared closure, a checkout keeps it in modules\.
$bazelModule = @('bazelmods', 'modules', '..\modules') | ForEach-Object { Join-Path $ScriptDir "$_\WindowsBazel.Common.psm1" } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $bazelModule) { throw "WindowsBazel.Common.psm1 is neither in $ScriptDir\bazelmods nor in $ScriptDir\modules" }
Import-Module $bazelModule -Force -DisableNameChecking


function Get-LitertWheelPin {
    # Every pin the build reads.
    return Get-BazelPin -Context 'the LiteRT wheel build reads it from versions.env' -Name 'LITERT_VERSION', 'LITERT_WINDOWS_SOURCE_COMMIT',
        'LITERT_BAZEL_WINDOWS_VERSION', 'LITERT_BAZEL_WINDOWS_AMD64_SHA256', 'LITERT_WINDOWS_ACCELERATOR_WHEEL_URL',
        'LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256', 'LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256'
}

function Get-LitertWheelBazelArg {
    <#
    .SYNOPSIS
        The one option list fetch, build and aquery share, so no repo rule re-runs between them and wipes the rewrites.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string[]]$ToolchainFlag,
        [Parameter(Mandatory)][string]$PythonTarballSha256,
        [Parameter(Mandatory)][string]$PythonMajorMinor
    )
    $root = $WorkRoot -replace '\\', '/'
    $py = "$root/py/python/python.exe"
    return @('-c', 'opt', '--config=windows') + $ToolchainFlag + @(
        # upstream's own Windows flags (ci/build_pip_package_with_bazel_windows.ps1), protobuf_allow_msvc inert under clang-cl
        '--copt=-DLITERT_DISABLE_OPENCL_SUPPORT=1', '--copt=-mavx2', '--copt=-mfma', '--copt=-mf16c',
        '--define=protobuf_allow_msvc=true', '--copt=/Iexternal\com_google_protobuf\src', '--host_copt=/Iexternal\com_google_protobuf\src',
        # snappy takes _bzhi_u32 whenever _MSC_VER is set, and clang-cl wants the feature; the AVX2 floor above implies BMI2 (P12).
        '--per_file_copt=external/snappy/.*@-mbmi2', '--host_per_file_copt=external/snappy/.*@-mbmi2',
        # LiteRT's .bazelrc asks for PDBs; lld-link honours the last /DEBUG, and disk is the binding constraint.
        '--linkopt=/DEBUG:NONE', '--host_linkopt=/DEBUG:NONE',
        "--python_path=$py", "--action_env=PYTHON_BIN_PATH=$py",
        "--repo_env=HERMETIC_PYTHON_VERSION=$PythonMajorMinor",
        "--repo_env=HERMETIC_PYTHON_URL=file:///$root/py/python.tar.gz",
        "--repo_env=HERMETIC_PYTHON_SHA256=$PythonTarballSha256",
        '--repo_env=HERMETIC_PYTHON_PREFIX=python',
        "--repo_env=HERMETIC_REQUIREMENTS_LOCK=$root/req/requirements_lock.txt",
        '--repo_env=USE_PYWRAP_RULES=True',
        # An empty dir in place of the unhashed OpenVINO nightly configurable_repo fetches at load time (probe P5b).
        "--repo_env=OPENVINO_NATIVE_DIR=$root/openvino-absent",
        "--override_repository=litert_prebuilts=$root/prebuilts",
        "--override_repository=pypi__pip=$root/pip",
        "--repository_cache=$root/repo-cache")
}

function New-HermeticPythonTarball {
    <#
    .SYNOPSIS
        PC\layout of the image's CPython as rules_python's Windows runtime, tarred under python/; returns its path and SHA256.
    #>
    param([Parameter(Mandatory)][string]$CpythonDir, [Parameter(Mandatory)][string]$Destination)
    $build = Join-Path $CpythonDir 'PCbuild\amd64'
    $tree = Join-Path $Destination 'python'
    & (Join-Path $build 'python.exe') (Join-Path $CpythonDir 'PC\layout') --source $CpythonDir --build $build --copy $tree `
        --include-dev --include-stable --include-venv | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "PC\layout exited $LASTEXITCODE" }
    $version = Get-PinnedPythonVersion
    foreach ($rel in 'python.exe', "python$($version.AbiTag.Substring(2)).dll", 'python3.dll', "libs\python$($version.AbiTag.Substring(2)).lib",
        'libs\python3.lib', 'include\Python.h', 'include\pyconfig.h', 'DLLs\_ssl.pyd') {
        if (-not (Test-Path -LiteralPath (Join-Path $tree $rel))) { throw "hermetic Python: PC\layout left no $rel" }
    }
    $tarball = Join-Path $Destination 'python.tar.gz'
    # System32's bsdtar: Git's MSYS tar is first on PATH and reads C: as a remote host.
    & "$env:SystemRoot\System32\tar.exe" -czf $tarball -C $Destination python
    if ($LASTEXITCODE -ne 0) { throw "tar exited $LASTEXITCODE" }
    return [pscustomobject]@{ Path = $tarball; Sha256 = (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function New-PipOverrideRepo {
    <#
    .SYNOPSIS
        CPython's own ensurepip wheel as the @pypi__pip repo, with rules_python's BUILD; the pip rules_python pins dies on 3.15's typing (probe P5).
    #>
    param([Parameter(Mandatory)][string]$CpythonDir, [Parameter(Mandatory)][string]$Destination)
    $wheels = @(Get-ChildItem -LiteralPath (Join-Path $CpythonDir 'Lib\ensurepip\_bundled') -Filter 'pip-*-py3-none-any.whl' -File)
    if ($wheels.Count -ne 1) { throw "ensurepip bundles $($wheels.Count) pip wheels, not one" }
    Expand-Archive -LiteralPath $wheels[0].FullName -DestinationPath $Destination -Force
    Set-Content -LiteralPath (Join-Path $Destination 'WORKSPACE') -Value ''
    Set-Content -LiteralPath (Join-Path $Destination 'BUILD.bazel') -Value @(
        'package(default_visibility = ["//visibility:public"])', ''
        'load("@rules_python//python:py_library.bzl", "py_library")', ''
        'py_library('
        '    name = "lib",'
        '    srcs = glob(["**/*.py"]),'
        '    data = glob(["**/*"], exclude = ["**/*.py", "**/*.pyc", "**/*.pyc.*", "**/*.dist-info/RECORD", "BUILD", "WORKSPACE"]),'
        '    imports = ["."],'
        ')')
    return $wheels[0].Name
}

function New-LitertPrebuiltsRepo {
    <#
    .SYNOPSIS
        @litert_prebuilts as a local repo holding only the pinned WebGPU accelerator, in place of upstream's floating 'latest' zip.
    #>
    param([Parameter(Mandatory)][string]$AcceleratorWheel, [Parameter(Mandatory)][string]$BuildFile, [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256)
    $dll = Join-Path $Destination 'windows_x86_64\libLiteRtWebGpuAccelerator.dll'
    New-Item -ItemType Directory -Force -Path (Split-Path $dll) | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($AcceleratorWheel)
    try {
        $entry = $zip.Entries | Where-Object FullName -eq 'ai_edge_litert/libLiteRtWebGpuAccelerator.dll'
        if (-not $entry) { throw "$AcceleratorWheel holds no ai_edge_litert/libLiteRtWebGpuAccelerator.dll" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
    } finally { $zip.Dispose() }
    $got = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    if ($got -ne $ExpectedSha256) { throw "libLiteRtWebGpuAccelerator.dll has SHA256 $got, LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256 pins $ExpectedSha256" }
    Set-Content -LiteralPath (Join-Path $Destination 'WORKSPACE') -Value ''
    Copy-Item -LiteralPath $BuildFile -Destination (Join-Path $Destination 'BUILD.bazel')
}

function Edit-ExternalText {
    # One upstream rewrite: exactly one hit, or already applied; anything else throws, so a moved anchor stops the build.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Old, [Parameter(Mandatory)][AllowEmptyString()][string]$New,
        [string]$Applied = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "rewrite target missing: $Path" }
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $hits = ([regex]::Matches($text, [regex]::Escape($Old))).Count
    if ($hits -eq 0 -and $Applied -and $text.Contains($Applied)) { return }
    if ($hits -ne 1) { throw "rewrite anchor found $hits times in ${Path}: $($Old.Substring(0, [Math]::Min(80, $Old.Length)))" }
    [IO.File]::WriteAllText($Path, $text.Replace($Old, $New))
}

function Invoke-LitertExternalRewrite {
    <#
    .SYNOPSIS
        upstream's post-fetch source fixes (ci/build_pip_package_with_bazel_windows.ps1), each throw-on-miss; returns the HH_ALIGNAS move count.
    .DESCRIPTION
        MSVC's STL is clang-cl's too, so the incomplete-type and alignment fixes still apply; the -Wno-sign-compare strip does not.
    #>
    param([Parameter(Mandatory)][string]$External, [Parameter(Mandatory)][string]$InsertFieldFile)
    Edit-ExternalText "$External\com_google_absl\absl\base\options.h" '#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 2' '#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 0' `
        -Applied '#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 0'
    $pb = "$External\com_google_protobuf\src\google\protobuf"
    $helpers = '#include "google/protobuf/compiler/java/helpers.h"'
    Edit-ExternalText "$pb\compiler\java\context.h" $helpers "$helpers`n#include `"google/protobuf/compiler/java/field_common.h`"" -Applied 'java/field_common.h"'
    Edit-ExternalText "$pb\compiler\java\BUILD.bazel" '"helpers.h",' "`"helpers.h`",`n        `"field_common.h`"," -Applied "`"helpers.h`",`n        `"field_common.h`","
    $um = "$pb\json\internal\untyped_message"
    Edit-ExternalText "$um.h" ', UntypedMessage,' ', std::unique_ptr<UntypedMessage>,'
    Edit-ExternalText "$um.h" 'std::vector<UntypedMessage>>;' 'std::vector<std::unique_ptr<UntypedMessage>>>;'
    $desc = '  const ResolverPool::Message& desc() const { return *desc_; }'
    Edit-ExternalText "$um.h" $desc ((Get-LitertGetMessageSource) + $desc) -Applied 'GetMessage(int32_t field_number'
    Edit-ExternalText "$um.cc" 'InsertField(*field, std::move(group))' 'InsertField(*field, std::make_unique<UntypedMessage>(std::move(group)))'
    Edit-ExternalText "$um.cc" 'InsertField(field, std::move(*inner))' 'InsertField(field, std::make_unique<UntypedMessage>(std::move(*inner)))'
    $cc = [IO.File]::ReadAllText("$um.cc").Replace("`r`n", "`n")
    # \x7B and \x7D: a bare brace in a string would unbalance the file for every brace-counting reader.
    $re = [regex]'(?s)template <typename T>\s+absl::Status UntypedMessage::InsertField\([^\x7B]*\)\s*\x7B.*?\n\x7D'
    if (-not $re.IsMatch($cc)) { throw "rewrite anchor missing in $um.cc: the InsertField template" }
    [IO.File]::WriteAllText("$um.cc", $re.Replace($cc, ([IO.File]::ReadAllText($InsertFieldFile).Replace("`r`n", "`n").TrimEnd()), 1))
    Edit-ExternalText "$pb\json\internal\unparser_traits.h" 'return &msg.Get<Msg>(f->proto().number())[idx];' 'return msg.GetMessage(f->proto().number(), idx);'
    foreach ($gen in 'objectivec', 'rust') {
        Edit-ExternalText "$pb\compiler\BUILD.bazel" "        `"//src/google/protobuf/compiler/$gen`",`n" ''
    }
    foreach ($line in '#include "google/protobuf/compiler/objectivec/generator.h"', '#include "google/protobuf/compiler/rust/generator.h"',
        '  objectivec::ObjectiveCGenerator objc_generator;', '  cli.RegisterGenerator("--objc_out", "--objc_opt", &objc_generator,',
        '                        "Generate Objective-C header and source.");', '  rust::RustGenerator rust_generator;',
        '  cli.RegisterGenerator("--rust_out", "--rust_opt", &rust_generator,', '                        "Generate Rust sources.");') {
        Edit-ExternalText "$pb\compiler\main.cc" $line ''
    }
    $gcc = "#if HH_GCC_VERSION && HH_GCC_VERSION < 408`n#define HH_ALIGNAS(multiple) __attribute__((aligned(multiple)))`n#else`n#define HH_ALIGNAS(multiple) alignas(multiple)  // C++11`n#endif"
    Edit-ExternalText "$External\highwayhash\highwayhash\compiler_specific.h" $gcc "#if HH_MSC_VERSION`n#define HH_ALIGNAS(multiple) __declspec(align(multiple))`n#elif$($gcc.Substring(3))" `
        -Applied '__declspec(align(multiple))'
    # clang-cl defines _MSC_VER, so __declspec(align) must lead the declaration, never trail it.
    return (Move-HighwayHashAlignas -Directory "$External\highwayhash\highwayhash")
}

function Get-LitertGetMessageSource {
    # The accessor unparser_traits.h calls once a message field holds unique_ptr<UntypedMessage>.
    return (@(
            '  const UntypedMessage* GetMessage(int32_t field_number, size_t idx = 0) const {'
            '    auto it = fields_.find(field_number);'
            '    ABSL_CHECK(it != fields_.end()) << "missing UntypedMessage field " << field_number;'
            '    if (auto* val = std::get_if<std::unique_ptr<UntypedMessage>>(&it->second)) {'
            '      return val->get();'
            '    }'
            '    if (auto* vec = std::get_if<std::vector<std::unique_ptr<UntypedMessage>>>(&it->second)) {'
            '      ABSL_CHECK(idx < vec->size()) << "UntypedMessage index out of range for field " << field_number;'
            '      return (*vec)[idx].get();'
            '    }'
            '    ABSL_CHECK(false) << "wrong type for UntypedMessage::GetMessage(" << field_number << ")";'
            '    return nullptr;'
            '  }'
            '') -join "`n") + "`n"
}

function Move-HighwayHashAlignas {
    # `T x HH_ALIGNAS(n);` becomes `HH_ALIGNAS(n) T x;` on plain declaration lines; returns how many lines moved.
    param([Parameter(Mandatory)][string]$Directory)
    $moved = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Include *.h, *.cc)) {
        $lines = [IO.File]::ReadAllLines($file.FullName)
        $changed = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -notmatch 'HH_ALIGNAS\(' -or $line -match '^\s*(HH_ALIGNAS\(|//|#|private:|public:|protected:)') { continue }
            $brace = $line.IndexOf([char]0x7B)
            if ($brace -ge 0 -and $brace -lt $line.IndexOf('HH_ALIGNAS(')) { continue }
            $new = $line -replace '^(\s*)([^;]*?)\s+HH_ALIGNAS\((\d+)\)\s*([^;]*;\s*)$', '$1HH_ALIGNAS($3) $2$4'
            if ($new -ne $line) { $lines[$i] = $new; $changed = $true; $moved++ }
        }
        if ($changed) { [IO.File]::WriteAllLines($file.FullName, $lines) }
    }
    return $moved
}

function Assert-LitertWheelContract {
    <#
    .SYNOPSIS
        The wheel the stage ships: its name, the four extension modules, python3XY.dll imports, the pinned accelerator, no Rich header.
    #>
    param([Parameter(Mandatory)][string]$Wheel, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$AbiTag,
        [Parameter(Mandatory)][string]$AcceleratorSha256, [Parameter(Mandatory)][string]$ExtractDir)
    $want = "ai_edge_litert-$Version-$AbiTag-$AbiTag-win_amd64.whl"
    if ((Split-Path -Leaf $Wheel) -ne $want) { throw "the wheel is $(Split-Path -Leaf $Wheel), not $want" }
    Expand-Archive -LiteralPath $Wheel -DestinationPath $ExtractDir -Force
    $pkg = Join-Path $ExtractDir 'ai_edge_litert'
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($ext in 'interpreter', 'compiled_model', 'environment', 'tensor_buffer') {
        if (-not @(Get-ChildItem -LiteralPath $pkg -Filter "_pywrap_litert_${ext}_wrapper*.pyd" -File).Count) { $problems.Add("no _pywrap_litert_${ext}_wrapper pyd") }
    }
    $common = Join-Path $pkg 'pywrap_litert_common.dll'
    $pyDll = "python$($AbiTag.Substring(2)).dll"
    if (-not (Test-Path -LiteralPath $common)) { $problems.Add('no pywrap_litert_common.dll') }
    elseif ($pyDll -notin @(Get-PeImportNames -Path $common)) { $problems.Add("pywrap_litert_common.dll does not import $pyDll") }
    $acc = Join-Path $pkg 'libLiteRtWebGpuAccelerator.dll'
    if (-not (Test-Path -LiteralPath $acc)) { $problems.Add('no libLiteRtWebGpuAccelerator.dll') }
    elseif ((Get-FileHash -LiteralPath $acc -Algorithm SHA256).Hash -ne $AcceleratorSha256) { $problems.Add('libLiteRtWebGpuAccelerator.dll is not the pinned accelerator') }
    if (Test-Path -LiteralPath (Join-Path $pkg 'vendors\intel_openvino')) { $problems.Add('vendors\intel_openvino shipped, though nothing pins its SDK') }
    foreach ($pe in @(Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -Include *.pyd, *.dll, *.exe)) {
        if ($pe.FullName -eq $acc) { continue }
        if (Test-PeRichHeader -Path $pe.FullName) { $problems.Add("$($pe.Name) carries MSVC's Rich header") }
        if (@(Get-PeImportNames -Path $pe.FullName) -match '^onnxruntime') { $problems.Add("$($pe.Name) imports an ONNX Runtime") }
    }
    if ($problems.Count) { throw "ai_edge_litert wheel contract: $($problems -join '; ')" }
}

function Invoke-LitertWheelSmoke {
    <#
    .SYNOPSIS
        Installs the wheel, numpy and ml_dtypes (tensor_buffer imports it) at their pins into -Target, then runs a floor model through both Python APIs on the CPU.
    #>
    param([Parameter(Mandatory)][string]$Wheel, [Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$PipDir,
        [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][string]$SmokeScript)
    $saved = $env:PYTHONPATH
    try {
        # The hermetic layout ships no pip; the @pypi__pip repo's copy runs from PYTHONPATH.
        $env:PYTHONPATH = $PipDir
        & $Python -m pip install --quiet --disable-pip-version-check --no-deps --only-binary=:all: --target $Target $Wheel @(Get-PipPin -Name 'numpy', 'ml_dtypes') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "pip install of the smoke set exited $LASTEXITCODE" }
        $env:PYTHONPATH = $Target
        $out = @(& $Python $SmokeScript $Model 2>&1 | ForEach-Object { "$_" })
        $out | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not ($out -match '^LITERT-WHEEL-SMOKE PASS')) { throw 'the ai_edge_litert CPU smoke failed (output above)' }
    } finally { $env:PYTHONPATH = $saved }
}

Import-CanonicalVersions -ScriptRoot $ScriptDir

if (Test-WindowsCrossTarget) {
    # The merge COPYs the store unconditionally; nothing builds LiteRT's bazel wheel for windows-arm64 (upstream has no config).
    [void](Write-AbsentOnCrossMarker -Root 'C:\runtime\lib\litert\python' -Component 'ai-edge-litert (Python wheel)' -Reason @(
            'Upstream''s bazel wheel target has no windows-arm64 configuration.'))
    New-Item -ItemType Directory -Force -Path $WheelDir | Out-Null
    exit 0
}

$pin = Get-LitertWheelPin
$python = Get-PinnedPythonVersion
$clock = [Diagnostics.Stopwatch]::StartNew()
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
foreach ($d in 'bin', 'py', 'req', 'prebuilts', 'openvino-absent', 'pip', 'dl') { New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot $d) | Out-Null }
if (-not $ToolCache) { $ToolCache = Join-Path $WorkRoot 'dl' }
New-Item -ItemType Directory -Force -Path $ToolCache | Out-Null

Write-Host "=== [1/7] tools and source: bazel $($pin.LITERT_BAZEL_WINDOWS_VERSION), LiteRT $($pin.LITERT_VERSION) ==="
$bazelCached = Join-Path $ToolCache "bazel-$($pin.LITERT_BAZEL_WINDOWS_VERSION)-windows-x86_64.exe"
Get-PinnedTool -Uri "https://github.com/bazelbuild/bazel/releases/download/$($pin.LITERT_BAZEL_WINDOWS_VERSION)/bazel-$($pin.LITERT_BAZEL_WINDOWS_VERSION)-windows-x86_64.exe" `
    -Path $bazelCached -PinKey 'LITERT_BAZEL_WINDOWS_AMD64_SHA256'
$bazel = Join-Path $WorkRoot 'bin\bazel.exe'
Copy-Item -LiteralPath $bazelCached -Destination $bazel -Force
$src = Join-Path $WorkRoot 's'
# LF checkout: the patches are LF, and the image's git converts on checkout.
& git -c core.autocrlf=false clone --quiet --depth 1 --branch $pin.LITERT_VERSION https://github.com/google-ai-edge/LiteRT.git $src
if ($LASTEXITCODE -ne 0) { throw "git clone of LiteRT $($pin.LITERT_VERSION) failed ($LASTEXITCODE)" }
$head = (& git -C $src rev-parse HEAD).Trim()
if ($head -ne $pin.LITERT_WINDOWS_SOURCE_COMMIT) { throw "LiteRT $($pin.LITERT_VERSION) is $head, LITERT_WINDOWS_SOURCE_COMMIT pins $($pin.LITERT_WINDOWS_SOURCE_COMMIT): the tag moved" }
$wanted = (Get-Content -LiteralPath (Join-Path $src '.bazelversion') -Raw).Trim()
if ($wanted -ne $pin.LITERT_BAZEL_WINDOWS_VERSION) { throw "LiteRT pins bazel $wanted, LITERT_BAZEL_WINDOWS_VERSION is $($pin.LITERT_BAZEL_WINDOWS_VERSION)" }
$patchDir = Join-Path $ScriptDir 'patches\litert'
foreach ($patch in @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch' -File | Sort-Object Name)) {
    Invoke-SourcePatch -PatchFile $patch.FullName -SourceDir $src
}

Write-Host "=== [2/7] hermetic Python $($python.Version), pip, prebuilts, lock ==="
$tarball = New-HermeticPythonTarball -CpythonDir 'C:\temp\cpython' -Destination (Join-Path $WorkRoot 'py')
Write-Host "  hermetic Python tarball: $($tarball.Sha256)"
Write-Host "  @pypi__pip from $(New-PipOverrideRepo -CpythonDir 'C:\temp\cpython' -Destination (Join-Path $WorkRoot 'pip'))"
$accWheel = Join-Path $ToolCache (Split-Path -Leaf ([uri]$pin.LITERT_WINDOWS_ACCELERATOR_WHEEL_URL).AbsolutePath)
Get-PinnedTool -Uri $pin.LITERT_WINDOWS_ACCELERATOR_WHEEL_URL -Path $accWheel -PinKey 'LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256'
New-LitertPrebuiltsRepo -AcceleratorWheel $accWheel -BuildFile (Join-Path $src 'third_party\litert_prebuilts\litert_prebuilts.BUILD') `
    -Destination (Join-Path $WorkRoot 'prebuilts') -ExpectedSha256 $pin.LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256
$lock = Join-Path $patchDir "requirements_lock_$($python.MajorMinor -replace '\.', '_').txt"
if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { throw "no hash-pinned requirements lock for Python $($python.MajorMinor) at $lock" }
Copy-Item -LiteralPath $lock -Destination (Join-Path $WorkRoot 'req\requirements_lock.txt')

Write-Host '=== [3/7] bazel env and options ==='
$toolchain = Get-BazelClangClArg -Platform '@org_tensorflow//tensorflow/tools/toolchains/win:x64_windows-clang-cl' `
    -VcRoot 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC' -BashPath 'C:\Program Files\Git\usr\bin\bash.exe'
$restoreEnv = Set-BazelProcessEnv -Values ([ordered]@{
        BAZEL_LLVM = $toolchain.Env.BAZEL_LLVM; BAZEL_VC = $toolchain.Env.BAZEL_VC; BAZEL_VC_FULL_VERSION = $toolchain.Env.BAZEL_VC_FULL_VERSION
        BAZEL_SH = $toolchain.Env.BAZEL_SH; LITERT_MODELS = ''; JAVA_HOME = $null
        ANDROID_NDK_HOME = $null; ANDROID_NDK_VERSION = $null; ANDROID_HOME = $null; ANDROID_SDK_ROOT = $null
    })
$startup = @("--output_user_root=$WorkRoot\u", "--output_base=$WorkRoot\o", '--max_idle_secs=900')
$opts = Get-LitertWheelBazelArg -WorkRoot $WorkRoot -ToolchainFlag $toolchain.Flags -PythonTarballSha256 $tarball.Sha256 -PythonMajorMinor $python.MajorMinor
$target = '//ci/tools/python/wheel:litert_wheel'
$log = Join-Path $WorkRoot 'bazel-build.log'

Push-Location $src
try {
    Write-Host '=== [4/7] fetch through analysis, then upstream''s source rewrites ==='
    & $bazel @startup build @opts --nobuild $target 2>&1 | Tee-Object -FilePath $log | Select-Object -Last 5 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "bazel analysis failed ($LASTEXITCODE); see $log" }
    $external = Join-Path $WorkRoot 'o\external'
    $pinnedPip = [regex]::Match([IO.File]::ReadAllText((Join-Path $external 'rules_python\python\private\pypi\deps.bzl')), 'pip-([\d.]+)-py3-none-any\.whl').Groups[1].Value
    Write-Host "  @pypi__pip: CPython's ensurepip pip in place of rules_python's pip $pinnedPip"
    $moved = Invoke-LitertExternalRewrite -External $external -InsertFieldFile (Join-Path $patchDir 'untyped_message_insert_field.cc')
    Write-Host "  rewrites applied; highwayhash HH_ALIGNAS moved on $moved line(s)"

    Write-Host "=== [5/7] bazel build $target ==="
    $buildOnly = @(if ($KeepGoing) { '--keep_going' })
    $exit = Invoke-BazelLogged -Bazel $bazel -Argument (@($startup) + @('build') + @($opts) + @($buildOnly) + @($target)) -LogPath $log -Append
    if ($exit -ne 0) { throw "bazel build failed ($exit); see the lines above" }

    Write-Host '=== [6/7] gates: every action ran LLVM, the wheel contract, a CPU smoke ==='
    $aquery = & $bazel @startup aquery @opts "mnemonic('CppCompile|CppLink|CppArchive', deps($target))" --output=jsonproto 2>$null | Out-String
    Write-Host "  $(Assert-BazelActionCompiler -AqueryJson $aquery) compile/link/archive actions, all clang-cl, lld-link or llvm-lib"
    $dist = @(Get-ChildItem -LiteralPath (Join-Path $src 'bazel-bin\ci\tools\python\wheel\dist') -Filter '*.whl' -File)
    if ($dist.Count -ne 1) { throw "the wheel target left $($dist.Count) wheels, not one" }
    $version = $pin.LITERT_VERSION.TrimStart('v')
    Assert-LitertWheelContract -Wheel $dist[0].FullName -Version $version -AbiTag $python.AbiTag `
        -AcceleratorSha256 $pin.LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256 -ExtractDir (Join-Path $WorkRoot 'contract')
    Invoke-LitertWheelSmoke -Wheel $dist[0].FullName -Python (Join-Path $WorkRoot 'py\python\python.exe') -PipDir (Join-Path $WorkRoot 'pip') `
        -Target (Join-Path $WorkRoot 'smoke') -Model (Join-Path $src 'litert\test\testdata\simple_floor_op.tflite') -SmokeScript (Join-Path $ScriptDir 'litert-wheel-smoke.py')

    Write-Host '=== [7/7] store the wheel ==='
    [void](Save-PythonWheel -SourceDir (Split-Path $dist[0].FullName) -Filter $dist[0].Name -WheelDir $WheelDir -Required)
} finally {
    Pop-Location
    $null = Set-BazelProcessEnv -Values $restoreEnv
}
$peak = Get-TreeGb -Path $WorkRoot
if (-not $KeepTree) { Remove-BazelBuildTree -Path @($WorkRoot) -ServerRoot @("$WorkRoot\u") }
Write-Host ('ai-edge-litert {0} for {1}: {2:N0} s, work tree peak {3:N1} GB' -f $pin.LITERT_VERSION, $python.AbiTag, $clock.Elapsed.TotalSeconds, $peak)
exit 0
