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
    pwsh -File Test-Container.ps1
#>

param(
    [switch]$SkipCudaTests,
    # Makes a missing CUDA_ROOT a loud FAILURE instead of the CPU-lane skip.
    [switch]$ExpectGpu,
    [switch]$ExitOnFirstFailure,
    # Coverage floors, so "nothing ran" cannot pass as "all passed"; -MaxSkipped -1 means no cap.
    [int]$MinPassed = 0,
    [int]$MaxSkipped = -1
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSmokeTest.Common.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsNative.Common.psm1')
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -ErrorAction Stop

# Imported directly, as this script loads no WindowsSourceBuild.Common; unset WINDOWS_TARGET_ARCH means amd64.
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1') -Force
# Cross: payload sections (8-13, 17, 18, 20-22) skip whole, host-toolchain ones run; see $sectionFloors' Arm64 column.
$smokeCross = Test-WindowsCrossTarget

# Before the first assertion; the module cannot read -ExitOnFirstFailure from this scope.
Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure

# NVIDIA probes would fail a legitimate CPU image, so they key on CUDA_ROOT; DirectML is DX12-based and always checked.
$script:gpuNvidia = (-not $SkipCudaTests) -and (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CUDA_ROOT')))

# TensorRT follows the staged tree, not the lane: a zip-less GPU lane is normal, a staged tree without the EP fails.
$script:tensorRtStaged = Test-TensorRtTreeStaged

function Get-CommandVersion {
    param([string]$Name)
    try {
        $ver = & $Name --version 2>&1 | Select-Object -First 1
        return $ver
    } catch { return $null }
}

# A hand-encoded 63-byte Identity model shared by §8 and §20: real inference without model files.
$script:identityOnnxBytes = [byte[]]@(
    0x08,0x08,0x3A,0x37,0x0A,0x10,0x0A,0x01,0x78,0x12,0x01,0x79,0x22,0x08,0x49,0x64,
    0x65,0x6E,0x74,0x69,0x74,0x79,0x12,0x01,0x67,0x5A,0x0F,0x0A,0x01,0x78,0x12,0x0A,
    0x0A,0x08,0x08,0x01,0x12,0x04,0x0A,0x02,0x08,0x01,0x62,0x0F,0x0A,0x01,0x79,0x12,
    0x0A,0x0A,0x08,0x08,0x01,0x12,0x04,0x0A,0x02,0x08,0x01,0x42,0x02,0x10,0x0D)

# Shared by §20 and §22; no double quotes, which PS 5.1 strips from -c strings.
$script:ireeGateMlir = 'func.func @abs(%input : tensor<f32>) -> (tensor<f32>) { %result = math.absf %input : tensor<f32> return %result : tensor<f32> }'

# Expected versions: the baked Machine env in-container, the repo's versions.env on a host.
$script:versionsFromFile = @{}
$repoVersions = Join-Path $scriptAssetRoot '..\..\linux\scripts\01-core\versions.env'
$sharedModule = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
# Host-side only; the module guard keeps the suite runnable in an image with no modules dir.
if ((Test-Path $repoVersions) -and (Test-Path $sharedModule)) {
    Import-Module $sharedModule -Force
    $script:versionsFromFile = ConvertFrom-VersionsEnv -Path $repoVersions
}

# The final image and live smoke mount both carry the canonical module closure.
$containerImageModule = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
Import-Module $containerImageModule -Force -ErrorAction Stop

function Get-ExpectedVersion {
    # The setup and verify gates' own normalization; precedence env > versions.env > literal.
    param([string]$Key, [string]$Fallback)
    $fileValue = ''
    if ($script:versionsFromFile.ContainsKey($Key)) { $fileValue = [string]$script:versionsFromFile[$Key] }
    $default = if (-not [string]::IsNullOrWhiteSpace($fileValue)) { $fileValue } else { $Fallback }
    return Resolve-ContainerImageValue -EnvironmentVariable $Key -DefaultValue $default -TrimVPrefix
}

# §21 probe for the venv's python: ORT/GenAI facts and each chain-wheel binary hashed in wheel and venv; never raises.
function Get-TorchAppOrtProbeSource {
    return @'
import hashlib, importlib.metadata as md, json, os, re, sys, zipfile
def sha256(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1 << 20), b""):
        digest.update(chunk)
    return digest.hexdigest()
try:
    dist = md.version("onnxruntime")
except md.PackageNotFoundError:
    dist = ""
report = {"dist": dist, "binaries": []}
try:
    owners = md.packages_distributions().get("onnxruntime", [])
    report["owners"] = sorted({re.sub(r"[-_.]+", "-", o).lower() for o in owners if o})
except Exception as exc:
    report["owners"] = ["unreadable (%s: %s)" % (type(exc).__name__, exc)]
try:
    import onnxruntime
    report["providers"] = list(onnxruntime.get_available_providers())
    report["package"] = os.path.dirname(os.path.abspath(onnxruntime.__file__))
except Exception as exc:
    report["error"] = "%s: %s" % (type(exc).__name__, exc)
try:
    import onnxruntime_genai
    report["genaiDml"] = bool(onnxruntime_genai.is_dml_available())
except Exception as exc:
    report["genaiError"] = "%s: %s" % (type(exc).__name__, exc)
if len(sys.argv) > 1 and "package" in report:
    root = os.path.dirname(report["package"])
    try:
        with zipfile.ZipFile(sys.argv[1]) as wheel:
            for name in wheel.namelist():
                if name.startswith("onnxruntime/") and name.lower().endswith((".pyd", ".dll")):
                    path = os.path.join(root, *name.split("/"))
                    installed = ""
                    if os.path.isfile(path):
                        with open(path, "rb") as f:
                            installed = sha256(f)
                    with wheel.open(name) as f:
                        report["binaries"].append({"name": name, "wheel": sha256(f), "installed": installed})
    except Exception as exc:
        report["wheelError"] = "%s: %s" % (type(exc).__name__, exc)
print(json.dumps(report))
'@
}

# The chain ORT wheel Build-TorchApp.ps1 force-installs: its PEP 503 name and version, or a Problem.
function Resolve-ChainOrtWheel {
    param([AllowEmptyString()][string]$WheelDir)
    $found = @()
    if ($WheelDir -and (Test-Path -LiteralPath $WheelDir -PathType Container)) {
        $found = @(Get-ChildItem -LiteralPath $WheelDir -Filter 'onnxruntime-*.whl' -File -ErrorAction SilentlyContinue)
    }
    $wheel = [pscustomobject]@{ Path = ''; Name = ''; Version = ''; Problem = '' }
    if ($found.Count -ne 1) {
        $wheel.Problem = "$($found.Count) onnxruntime-*.whl in '$WheelDir', expected exactly 1"
    } elseif ($found[0].Name -notmatch '^(?<name>[^-]+)-(?<version>[^-]+)-') {
        $wheel.Problem = "cannot read name and version from $($found[0].Name)"
    } else {
        $wheel.Path = $found[0].FullName
        $wheel.Name = ($Matches['name'] -replace '[-_.]+', '-').ToLowerInvariant()
        $wheel.Version = $Matches['version']
    }
    return $wheel
}

function Get-TorchAppOrtDmlFinding {
    param([hashtable]$Report)
    $providers = @($Report['providers'])
    if ($providers -notcontains 'DmlExecutionProvider') {
        "the venv's onnxruntime lacks DmlExecutionProvider (providers: $($providers -join ', ')) - not the chain wheel"
    }
    if ($Report['genaiError']) { "import onnxruntime_genai failed in the venv: $($Report['genaiError'])" }
    elseif ($Report['genaiDml'] -ne $true) { "the venv's onnxruntime_genai.is_dml_available() is not True - a no-DML GenAI shadows the chain wheel" }
}

function Get-TorchAppOrtProvenanceFinding {
    param([hashtable]$Report, [AllowNull()][pscustomobject]$Wheel, [string]$VenvSitePackages)
    if ($null -eq $Wheel -or $Wheel.Problem) { return "no chain wheel to compare against: $(if ($Wheel) { $Wheel.Problem } else { 'none resolved' })" }
    if ($Report['wheelError']) { return "cannot read the chain wheel $($Wheel.Path): $($Report['wheelError'])" }
    $owners = @($Report['owners'])
    if (($owners -join ', ') -ne $Wheel.Name) {
        "the onnxruntime import package belongs to [$($owners -join ', ')], expected only $($Wheel.Name) - a PyPI variant is installed over the chain wheel"
    }
    if ("$($Report['dist'])" -ne $Wheel.Version) { "dist onnxruntime is '$($Report['dist'])', the chain wheel is $($Wheel.Version)" }
    $site = "$VenvSitePackages".Replace('/', '\').TrimEnd('\')
    $parent = (Split-Path "$($Report['package'])".Replace('/', '\') -Parent)
    if (-not $site -or $parent -ne $site) { "onnxruntime imports from '$($Report['package'])', not from the venv's '$VenvSitePackages'" }
    $binaries = @($Report['binaries'])
    if (-not @($binaries | Where-Object { "$($_['name'])".EndsWith('.pyd') })) { 'no onnxruntime/*.pyd was compared - the chain wheel has no extension module?' }
    foreach ($b in $binaries) {
        if (-not $b['installed']) { "$($b['name']) is missing from the venv" }
        elseif ($b['installed'] -ne $b['wheel']) { "$($b['name']) in the venv differs from the chain wheel's copy" }
    }
}

# No lane input: USE_DML=ON is unconditional in ORT and GenAI, so every amd64 lane must pass both aspects.
function Get-TorchAppOrtFinding {
    param(
        [AllowNull()][hashtable]$Report,
        [Parameter(Mandatory)][ValidateSet('Dml', 'Provenance')][string]$Aspect,
        [AllowNull()][pscustomobject]$Wheel,
        [AllowEmptyString()][string]$VenvSitePackages = '',
        [AllowEmptyString()][string]$ProbeError = ''
    )
    if ($ProbeError) { return "the venv probe failed: $ProbeError" }
    if ($null -eq $Report) { return 'the venv probe printed no report' }
    if ($Report['error']) { return "import onnxruntime failed in the venv: $($Report['error'])" }
    if ($Aspect -eq 'Dml') { return Get-TorchAppOrtDmlFinding -Report $Report }
    return Get-TorchAppOrtProvenanceFinding -Report $Report -Wheel $Wheel -VenvSitePackages $VenvSitePackages
}

# -I keeps PYTHONPATH and the script dir off sys.path; throws without a report.
function Invoke-TorchAppOrtProbe {
    param([Parameter(Mandatory)][string]$Python, [AllowEmptyString()][string]$WheelPath = '')
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "venv python missing at $Python" }
    $arguments = @(@($WheelPath) | Where-Object { $_ })
    Invoke-PythonJsonProbe -Python $Python -Source (Get-TorchAppOrtProbeSource) -Prefix smoke-venv-ort -InterpreterArgument @('-I') -ArgumentList $arguments -DiagnosticTail
}

# §19: the ort-sys crate env windows/Dockerfile bakes must name the chain ORT under ONNX_ROOT.
function Get-OrtCrateEnvFinding {
    param([AllowEmptyString()][string]$OnnxRoot, [AllowNull()][hashtable]$Environment = $null)
    if ([string]::IsNullOrWhiteSpace($OnnxRoot)) { return 'ONNX_ROOT is unset, so nothing names the chain ORT' }
    $v = @{}
    $set = @{}
    # Untrimmed and set-vs-null kept apart: ort-sys compares exactly and reads a set-but-empty variable.
    foreach ($n in 'ORT_LIB_LOCATION', 'ORT_LIB_PATH', 'ORT_DYLIB_PATH', 'ORT_PREFER_DYNAMIC_LINK', 'ORT_SKIP_DOWNLOAD', 'CARGO_NET_OFFLINE') {
        $raw = if ($null -ne $Environment) { $Environment[$n] } else { [Environment]::GetEnvironmentVariable($n) }
        $set[$n] = $null -ne $raw
        $v[$n] = "$raw"
    }
    $lib = Join-Path $OnnxRoot.TrimEnd('\') 'lib'
    $dll = Join-Path $OnnxRoot.TrimEnd('\') 'bin\onnxruntime.dll'
    if ($v['ORT_LIB_LOCATION'].TrimEnd('\') -ne $lib) {
        "ORT_LIB_LOCATION is '$($v['ORT_LIB_LOCATION'])', not the chain's $lib - without it ort-sys downloads pyke's ORT"
    } elseif (-not (Test-Path -LiteralPath (Join-Path $lib 'onnxruntime.lib') -PathType Leaf)) {
        "$lib has no onnxruntime.lib for ort-sys to link"
    }
    if ($v['ORT_DYLIB_PATH'] -ne $dll) {
        "ORT_DYLIB_PATH is '$($v['ORT_DYLIB_PATH'])', not $dll - load-dynamic then loads a bare onnxruntime.dll, and System32's wins"
    } elseif (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        "$dll does not exist"
    }
    if ($v['ORT_PREFER_DYNAMIC_LINK'] -notin '1', 'true') { "ORT_PREFER_DYNAMIC_LINK is '$($v['ORT_PREFER_DYNAMIC_LINK'])' - ort-sys would try a static ORT the chain does not ship" }
    if ($v['ORT_SKIP_DOWNLOAD'] -notin '1', 'true') { "ORT_SKIP_DOWNLOAD is '$($v['ORT_SKIP_DOWNLOAD'])' - an unset location would fetch from pyke's CDN instead of failing" }
    if ($set['ORT_LIB_PATH']) { "ORT_LIB_PATH is set ('$($v['ORT_LIB_PATH'])') and ort-sys reads it BEFORE ORT_LIB_LOCATION" }
    if ($set['CARGO_NET_OFFLINE'] -and $v['CARGO_NET_OFFLINE'] -notin '1', 'true') {
        "CARGO_NET_OFFLINE is '$($v['CARGO_NET_OFFLINE'])' - ort-sys reads it before ORT_SKIP_DOWNLOAD, so it re-enables the download"
    }
}

function Assert-SmokeBannerMatch {
    param([string]$Name, [scriptblock]$ReadBanner, [string]$Pattern, [string]$FailMessage)
    Assert-Test -Name $Name -Condition {
        $banner = & $ReadBanner
        return "$banner" -match $Pattern
    }.GetNewClosure() -FailMessage $FailMessage
}

function Assert-SmokeOptionalPinnedVersion {
    param([string]$Expected, [string]$Name, [scriptblock]$ReadBanner, [string]$Failure, [string]$Missing = '')
    if (-not $Expected) {
        if ($Missing) { Skip-Test $Missing }
        return
    }
    Assert-SmokeBannerMatch -Name $Name -ReadBanner $ReadBanner -Pattern ([regex]::Escape($Expected)) -FailMessage $Failure
}

function Invoke-SmokeSection01 {
Write-TestHeader '1. Build Tools'
# msbuild comes from VS Build Tools; the rest from scoop/LLVM.
foreach ($tool in 'git', 'cmake', 'ninja', 'clang-cl', 'lld-link', 'llvm-lib', 'msbuild', 'nuget') {
    Assert-CommandExists $tool
}

# Well-formedness only: published images' clang may predate the pin, which Test-Toolchain.ps1 asserts at build time.
$clangVer = Get-CommandVersion 'clang-cl'
Assert-Test -Name "clang-cl version" -Condition { $null -ne $clangVer } -FailMessage "Could not get clang-cl version"
Assert-Test -Name "clang-cl version string" -Condition { $clangVer -match '\d+\.\d+' } -FailMessage "clang-cl did not report a well-formed version"
if ($env:LLVM_WINDOWS_VERSION -and $clangVer -and ("$clangVer" -notmatch [regex]::Escape($env:LLVM_WINDOWS_VERSION))) {
    Write-Warning ("clang-cl reports '$clangVer' but this image's LLVM_WINDOWS_VERSION pin is " +
        "'$env:LLVM_WINDOWS_VERSION' - expected for an image built before the pin moved; " +
        'unexpected for a fresh base build (Test-Toolchain.ps1 would have failed it).')
}

# Every LLVM tool PATH reaches is clang-cl's release; IREE's bin and VsDevCmd's MSVC dir carry their own (BACKLOG CON71).
$clangRelease = [regex]::Match("$clangVer", '\d+\.\d+\.\d+').Value
foreach ($tool in 'clang', 'clang++', 'clang-cpp', 'clang-tidy', 'clang-format', 'clangd', 'clang-scan-deps', 'ld.lld',
    'llvm-ar', 'llvm-nm', 'llvm-objdump', 'llvm-objcopy', 'llvm-profdata', 'llvm-cov', 'llvm-symbolizer', 'llvm-link',
    'llvm-config', 'opt', 'llc', 'lldb', 'FileCheck') {
    $toolCmd = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $toolRelease = if ($toolCmd) { [regex]::Match(((& $toolCmd.Source --version 2>&1) | Out-String), '\d+\.\d+\.\d+(git)?').Value } else { 'MISSING' }
    Assert-Test -Name "$tool is clang-cl's LLVM $clangRelease" -Condition { $clangRelease -and $toolRelease -eq $clangRelease } `
        -FailMessage "$tool resolves to $(if ($toolCmd) { $toolCmd.Source } else { 'nothing' }), LLVM '$toolRelease'"
}

# Skipped, not failed, when absent: the manifest is additive and published images may predate it.
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
Assert-Test -Name "cmake version" -Condition { $null -ne $cmakeVer } -FailMessage "Could not get cmake version"

# Pin assert: catches a stale base layer riding into the final image.
$cmakeExpected = Get-ExpectedVersion 'CMAKE_VERSION' ''
Assert-SmokeOptionalPinnedVersion -Expected $cmakeExpected -Name "cmake matches versions.env pin ($cmakeExpected)" `
    -ReadBanner ({ $cmakeVer }.GetNewClosure()) -Failure "cmake banner '$cmakeVer' does not contain pinned $cmakeExpected -- stale base layer shipped?" `
    -Missing 'cmake pin assert (CMAKE_VERSION not resolvable from env or versions.env)'
}

Invoke-SmokeSection01

function Get-SmokePinnedToolVersion {
    param(
        [string]$Tool, [string]$VersionKey, [string]$Fallback,
        [string]$CheckName, [string]$Failure, [scriptblock]$ReadBanner,
        [switch]$RequirePin
    )
    Assert-CommandExists $Tool
    $pin = Get-ExpectedVersion $VersionKey $Fallback
    if ($RequirePin) {
        Assert-Test -Name "$VersionKey is pinned (image ENV or versions.env)" -Condition { $pin -match '^\d+\.\d+' }.GetNewClosure() `
            -FailMessage "$VersionKey is '$pin' -- neither the image ENV nor versions.env names the pin"
    }
    # Select-Object avoids padding a one-part version with a null component.
    $majorMinor = ($pin -split '\.' | Select-Object -First 2) -join '.'
    Assert-SmokeBannerMatch -Name ($CheckName -f $majorMinor) -ReadBanner $ReadBanner `
        -Pattern ([regex]::Escape($majorMinor) + $(if ($Tool -eq 'python') { '\.' } else { '' })) `
        -FailMessage ($Failure -f $majorMinor)
    return @{ Pin = $pin; MajorMinor = $majorMinor }
}

function Get-PythonSmokeContext {
# No fallback version: grading against an old literal would pass an image that never got the pin.
$version = Get-SmokePinnedToolVersion -Tool python -VersionKey PYTHON_VERSION -Fallback '' -RequirePin `
    -CheckName 'Python is {0}.x' -Failure 'Python version is not {0}.x' -ReadBanner { & python --version 2>&1 }
$pyExpected = $version.Pin
$pyMajorMinor = $version.MajorMinor

# TEMP_DIR is unset on a build host, where a bare Join-Path would throw.
$cpythonDir = Join-Path ($env:TEMP_DIR ?? 'C:\temp') 'cpython'
# PCbuild\amd64 on both lanes: `python` is the host interpreter; only the wheel tag follows the target.
Assert-Test -Name "Python source-built from $cpythonDir" -Condition {
    (Test-Path "$cpythonDir\PCbuild\amd64\python.exe") -or
    (Test-Path "$cpythonDir\PCbuild\amd64\python3.dll")
} -FailMessage "Python source build artifacts not found at $cpythonDir"

# setuptools links an extension against sys.base_exec_prefix\libs, which a venv of the in-tree build reaches (CON93).
$pyLibName = "python$($pyMajorMinor -replace '\.', '').lib"
Assert-Test -Name "$cpythonDir\libs holds $pyLibName and python3.lib" -Condition {
    (Test-Path -LiteralPath "$cpythonDir\libs\$pyLibName" -PathType Leaf) -and (Test-Path -LiteralPath "$cpythonDir\libs\python3.lib" -PathType Leaf)
} -FailMessage "no $pyLibName or python3.lib in $cpythonDir\libs, so an sdist's C extension fails to link in a venv (LNK1104)"

Assert-Test -Name "Python pip available" -Condition {
    # Exit-code based: with stderr merged, a failing pip still emits a first object.
    & python -m pip --version 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "pip not available"

# Exact pin: a stale toolchain layer would still pass the x.y check above.
if ($pyExpected) {
    Assert-SmokeBannerMatch -Name "python matches versions.env pin ($pyExpected)" -ReadBanner { & python --version 2>&1 } `
        -Pattern ([regex]::Escape($pyExpected)) -FailMessage "python --version is not the pinned $pyExpected -- stale toolchain layer shipped?"
}
    return @{ Pin = $pyExpected; MajorMinor = $pyMajorMinor; CpythonDir = $cpythonDir }
}

function Assert-PythonSmokeStdlib {
# Source-built CPython silently omits extension modules whose deps were missing at build time.
Assert-PythonSnippet -Name "Python stdlib extension modules import (ssl/sqlite3/zlib/ctypes/bz2/lzma)" `
    -Code "import ssl, sqlite3, zlib, ctypes, bz2, lzma, hashlib, socket; print('stdlib-ok')" `
    -ExpectMatch @('stdlib-ok') `
    -FailMessage "one or more stdlib extension modules failed to import (dep missing at CPython build time?)"
}

function Assert-FreeThreadedPythonSmoke {
    param([string]$pyExpected, [string]$pyMajorMinor, [string]$cpythonDir)
# The X.Yt legs' interpreter, built beside the GIL one; see docs/windows-builds.md § The free-threaded CPython.
$ftBin = [Environment]::GetEnvironmentVariable('PYTHON_FREETHREADED_BIN')
$script:ftExe = Join-Path ($ftBin ?? 'C:\python-freethreaded') "python${pyMajorMinor}t.exe"
$ftVersion = if ($pyExpected) { $pyExpected } else { $pyMajorMinor }
Assert-PythonSnippet -Python $ftExe -Name "free-threaded Python $ftVersion runs with the GIL off ($ftExe)" `
    -Code "import sys, sysconfig, ssl, sqlite3, ctypes; print('ft', sys.version.split()[0], sys._is_gil_enabled(), sysconfig.get_config_var('Py_GIL_DISABLED'))" `
    -ExpectMatch @("ft $([regex]::Escape($ftVersion))\S* False 1") `
    -FailMessage "$ftExe is missing, is not $ftVersion, or has the GIL on -- an ${pyMajorMinor}t leg would download or test a GIL build"
Assert-Test -Name "uv finds ${pyMajorMinor}t there and ${pyMajorMinor}+gil in $cpythonDir, downloads off" -Condition {
    $resolved = foreach ($request in "${pyMajorMinor}t", "${pyMajorMinor}+gil") { "$(& uv python find --no-python-downloads $request 2>&1)|$LASTEXITCODE" }
    ($resolved -join ';') -ieq "$ftExe|0;$cpythonDir\PCbuild\amd64\python.exe|0"
} -FailMessage "uv python find resolved a free-threaded or GIL request elsewhere (PYTHON_FREETHREADED_BIN off PATH, or a python.exe in it?)"
}

function Assert-PythonBuildToolSmoke {
    param([string]$cpythonDir)
# Both media branches install it; their fan-in once shipped Cython\shadow.py, which hides Cython.Shadow (CON80).
$cythonPin = Get-ExpectedVersion 'PY_CYTHON_VERSION' ''
$cythonWant = if ($cythonPin) { "cython $([regex]::Escape($cythonPin))\s" } else { 'cython \S+\s' }
Assert-PythonSnippet -Python "$cpythonDir\PCbuild\amd64\python.exe" -Name "Cython $cythonPin imports in $cpythonDir (Cython.Shadow, Cython.Compiler.Main)" `
    -Code "import Cython, Cython.Shadow, Cython.Compiler.Main; print('cython', Cython.__version__)" `
    -ExpectMatch @($cythonWant) `
    -FailMessage "Cython is missing, unimportable or not PY_CYTHON_VERSION '$cythonPin' -- see docs/failure-modes.md § A Python module imports nowhere though its distribution is installed"
# meson's wrap.py verifies through truststore whenever it imports; without it Server Core's 18 roots fail xiph.org (CON88).
$trustPin = Get-ExpectedVersion 'PY_TRUSTSTORE_VERSION' ''
Assert-PythonSnippet -Python "$cpythonDir\PCbuild\amd64\python.exe" -Name "truststore $trustPin imports in $cpythonDir beside meson" `
    -Code "import truststore, mesonbuild; print('truststore', truststore.__version__)" `
    -ExpectMatch @($(if ($trustPin) { "truststore $([regex]::Escape($trustPin))" } else { 'truststore \S+' })) `
    -FailMessage "truststore is missing beside meson in $cpythonDir, so meson's wraps verify against Server Core's store alone (CON88)"
# NTFS opens any spelling, CPython's import only the one RECORD names: a lowercased file is a module that imports nowhere.
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSitePackages.Common.psm1') -Force -DisableNameChecking
$baseSitePackages = Join-Path $cpythonDir 'Lib\site-packages'
$baseSiteDists = @(if (Test-Path $baseSitePackages) { Get-DistInfoVersion -SitePackages $baseSitePackages })
$baseSiteCase = @(if ($baseSiteDists.Count -gt 0) { Find-RecordCaseMismatch -SitePackages $baseSitePackages | Format-RecordCaseMismatch })
Assert-Test -Name "every RECORD in $baseSitePackages spells its files as on disk ($($baseSiteDists.Count) distributions)" -Condition {
    $baseSiteDists.Count -gt 0 -and $baseSiteCase.Count -eq 0
} -FailMessage ("no distribution found, or files spelled otherwise than their RECORD (a COPY or reinstall over a lower layer lowercases them): " +
    $(if ($baseSiteCase.Count) { $baseSiteCase -join '; ' } else { 'no dist-info at all' }))
}

function Invoke-SmokeSection02 {
    Write-TestHeader '2. Python (source-built)'
    $py = Get-PythonSmokeContext
    Assert-PythonSmokeStdlib
    Assert-FreeThreadedPythonSmoke -pyExpected $py.Pin -pyMajorMinor $py.MajorMinor -cpythonDir $py.CpythonDir
    Assert-PythonBuildToolSmoke -cpythonDir $py.CpythonDir
}

Invoke-SmokeSection02

function Invoke-SmokeSection03 {
Write-TestHeader '3. Rust Toolchain'
Assert-CommandExists 'cargo'
Assert-CommandExists 'rustc'
Assert-CommandExists 'rustup'

# Cargokit's own probe; see docs/windows-builds.md § Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup).
Assert-Test -Name 'rustup resolves an active toolchain' -Condition {
    & rustup show active-toolchain 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage 'rustup show active-toolchain failed (toolchain-less rustup shipped?)'
Assert-Test -Name 'rustup which cargo resolves' -Condition {
    & rustup which cargo 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage 'rustup which cargo failed (proxy shims resolve no real toolchain?)'

# Baked so Flutter+Rust consumers skip a cold `cargo install` per container; pinned, as the bindings must match the runtime.
Assert-Test -Name 'flutter_rust_bridge_codegen at FLUTTER_RUST_BRIDGE_VERSION' -Condition {
    $pin = [string]$env:FLUTTER_RUST_BRIDGE_VERSION
    $ver = & flutter_rust_bridge_codegen --version 2>&1
    return ($LASTEXITCODE -eq 0) -and $pin -and ("$ver" -match "\b$([regex]::Escape($pin))\b")
} -FailMessage "flutter_rust_bridge_codegen missing, or not at FLUTTER_RUST_BRIDGE_VERSION '$env:FLUTTER_RUST_BRIDGE_VERSION'"

# Baked so cxx consumers never cargo-install it at configure time (CON145); a mismatch with their cxx breaks the bridge ABI.
Assert-Test -Name 'cxxbridge at CXXBRIDGE_CMD_VERSION' -Condition {
    $pin = [string]$env:CXXBRIDGE_CMD_VERSION
    $ver = & cxxbridge --version 2>&1
    return ($LASTEXITCODE -eq 0) -and $pin -and ("$ver" -match "\b$([regex]::Escape($pin))\b")
} -FailMessage "cxxbridge missing, or not at CXXBRIDGE_CMD_VERSION '$env:CXXBRIDGE_CMD_VERSION'"

# Pinned like Linux since 2026-10-05 (CON60); an unset pin fails rather than passing vacuously.
Assert-Test -Name 'Rust at RUST_VERSION' -Condition {
    $pin = [string]$env:RUST_VERSION
    $ver = & rustc --version 2>&1
    return $pin -and ("$ver" -match "^rustc $([regex]::Escape($pin)) ")
} -FailMessage "rustc is not at RUST_VERSION '$env:RUST_VERSION'"

# Proves the toolchain compiles, links through the MSVC linker and runs, not just that rustc exists.
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
}

Invoke-SmokeSection03

function Invoke-SmokeSection04 {
Write-TestHeader '4. LLVM / Clang + Flutter + WiX'
Assert-CommandExists 'flutter'
Assert-Test -Name "Flutter works" -Condition {
    $output = & flutter --version 2>&1 | Out-String
    return $output -match 'Flutter'
} -FailMessage "Flutter --version failed"

Assert-FileExists -Path 'C:\WiX\wix.exe' -Description 'WiX toolset'
Assert-Test -Name 'WiX firewall extension' -Condition {
    (& 'C:\WiX\wix.exe' extension list --global 2>&1 | Out-String) -match 'WixToolset\.Firewall\.wixext'
} -FailMessage 'WixToolset.Firewall.wixext is not installed globally (windows/Dockerfile installs it)'
foreach ($tool in 'sccache', 'cppcheck', '7z', 'uv', 'nano') {
    Assert-CommandExists $tool
}
}

Invoke-SmokeSection04

function Invoke-SmokeSection05 {
Write-TestHeader '5. Visual Studio Build Tools'
$vsVer = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }
$msvcPlatformToolset = "v$($vsVer)0"
# Install-Vs.ps1 accepts both Program Files roots, so this probe must too.
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
}

Invoke-SmokeSection05

function Invoke-SmokeSection06 {
Write-TestHeader '6. Vulkan SDK'
Assert-CommandExists 'glslc'
Assert-CommandExists 'vulkaninfoSDK'
Assert-EnvVarSet -Name 'VULKAN_SDK'

# Needs no GPU or ICD, unlike vulkaninfo, which is deliberately not run headless.
Assert-Test -Name 'glslc compiles a shader to SPIR-V' -Condition {
    Invoke-SmokeCompilation -WorkName glslc -SourceName smoke.vert -OutputName smoke.spv -Compiler glslc `
        -Source "#version 450`nvoid main() { gl_Position = vec4(0.0); }"
} -FailMessage 'glslc failed to compile a trivial shader to SPIR-V'

# The lavapipe ICD makes vulkaninfo runnable headless; the amd64 image registers it in HKLM at install time.
$lavapipeDir = 'C:\runtime\lavapipe'
Assert-Test -Name 'lavapipe ICD + driver + loader staged (C:\runtime\lavapipe)' -Condition {
    $icd = if ((Get-WindowsTargetArch) -eq 'amd64') { 'lvp_icd.x86_64.json' } else { 'lvp_icd.aarch64.json' }
    (Test-Path (Join-Path $lavapipeDir $icd)) -and
    (Test-Path (Join-Path $lavapipeDir 'vulkan_lvp.dll')) -and
    (Test-Path (Join-Path $lavapipeDir 'vulkan-1.dll'))
} -FailMessage "the lavapipe ICD, driver and loader must all be staged in $lavapipeDir (Install-Lavapipe.ps1)"
Assert-EnvVarSet -Name 'LP_NATIVE_VECTOR_WIDTH'

if ($smokeCross) {
    # The aarch64 payload cannot execute on the x64 host; its PE machine is the provable half here.
    Assert-Test -Name 'lavapipe payload is aarch64 (PE machine 0xAA64)' -Condition {
        (Get-PeFileMachine -Path (Join-Path $lavapipeDir 'vulkan_lvp.dll')) -eq 0xAA64 -and
        (Get-PeFileMachine -Path (Join-Path $lavapipeDir 'vulkan-1.dll')) -eq 0xAA64
    } -FailMessage "the staged lavapipe driver and loader must be aarch64 PEs for the bundle's target"
} else {
    Assert-Test -Name 'vulkaninfo lists the lavapipe device (llvmpipe)' -Condition {
        $summary = @(& (Join-Path $lavapipeDir 'vulkaninfo.exe') --summary 2>&1 | ForEach-Object { "$_" })
        return ($summary -match 'llvmpipe')
    } -FailMessage 'vulkaninfo --summary lists no llvmpipe device; the HKLM ICD registration or the loader is missing'
}
}

Invoke-SmokeSection06

function Invoke-CudnnSmoke {
    # cuDNN
    Assert-EnvVarSet -Name 'CUDNN_ROOT'
    $cudnnRoot = [Environment]::GetEnvironmentVariable('CUDNN_ROOT')
    Assert-DirectoryExists -Path $cudnnRoot -Description "CUDNN_ROOT directory"

    # Recursive, as cuDNN may use subdirs; @() keeps .Count on a single result.
    $cudnnHeaders = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.h' -Recurse -ErrorAction SilentlyContinue)
    $cudnnLibs = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue)
    $cudnnDlls = @(Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue)

    Assert-Test -Name "cuDNN headers (cudnn*.h)" -Condition { $cudnnHeaders.Count -gt 0 } -FailMessage "No cuDNN headers found"
    Assert-Test -Name "cuDNN libs (cudnn*.lib)" -Condition { $cudnnLibs.Count -gt 0 } -FailMessage "No cuDNN libs found"
    Assert-Test -Name "cuDNN DLLs (cudnn*.dll)" -Condition { $cudnnDlls.Count -gt 0 } -FailMessage "No cuDNN DLLs found"

    # PTX only, as there is no GPU here; -ccbin names the MSVC host compiler, which is not on PATH.
    $nvccCcbin = if ($env:VCToolsInstallDir) { Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64' } else { $null }
    Assert-Test -Name 'nvcc compiles a CUDA kernel to PTX' -Condition {
        $after = @(if ($nvccCcbin) { '-ccbin'; $nvccCcbin })
        Invoke-SmokeCompilation -WorkName cuda -SourceName k.cu -OutputName k.ptx -Compiler nvcc -ArgumentList @('-std=c++17', '-ptx') -AfterArgument $after `
            -Source "__global__ void k(float* a) { a[threadIdx.x] *= 2.0f; }`nint main() { return 0; }"
    }.GetNewClosure() -FailMessage 'nvcc could not compile a trivial kernel to PTX (host_config/nv-target/cl.exe integration?)'

    # A host-only cuDNN call needs no GPU; on cross the run half becomes a PE-machine assert, as in §14.
    $cudnnHdr = $cudnnHeaders | Where-Object { $_.Name -eq 'cudnn.h' } | Select-Object -First 1
    $cudnnMainLib = $cudnnLibs | Where-Object { $_.Name -eq 'cudnn.lib' } | Select-Object -First 1
    $cudnnMainDll = $cudnnDlls | Where-Object { $_.Name -like 'cudnn64_*.dll' } | Select-Object -First 1
    if ($cudnnHdr -and $cudnnMainLib -and $cudnnMainDll -and $env:CUDA_ROOT) {
        $cudnnProbe = @{
            WorkName    = 'cudnn'
            Source      = @'
#include <cudnn.h>
#include <cstdio>
int main() { std::printf("cudnn %zu\n", (size_t)cudnnGetVersion()); return 0; }
'@
            IncludeDirs = @($cudnnHdr.DirectoryName, (Join-Path $env:CUDA_ROOT 'include'))
            LibDir      = $cudnnMainLib.DirectoryName
            LibName     = $cudnnMainLib.Name
            DllDir      = $cudnnMainDll.DirectoryName
        }
        if ($smokeCross) {
            Assert-NativeLinkRun @cudnnProbe -CrossLinkOnly -Name "cuDNN links against the target-arch import lib ($($cudnnMainLib.DirectoryName))" -ExpectMatch 'cudnn' -FailMessage "cuDNN did not compile/link for the target arch -- header/lib mismatch in the arm64 payload (the run half is impossible on this x64 host; the linked exe's PE machine is asserted instead)"
        } else {
            Assert-NativeLinkRun @cudnnProbe -Name 'cuDNN links + host API works (cudnnGetVersion)' -ExpectMatch 'cudnn' -FailMessage 'cuDNN did not compile/link/run (cudnnGetVersion) -- header/lib/DLL mismatch or missing dependent DLL'
        }
    } else {
        Skip-Test 'cuDNN link+run (cudnn.h/.lib/cudnn64_*.dll not all found)'
    }
}

function Assert-CudaSmokePrerequisites {
    $null = Get-SmokePinnedToolVersion -Tool nvcc -VersionKey CUDA_VERSION -Fallback '13.4.2' `
        -CheckName 'nvcc version is {0}.x' -Failure 'nvcc version is not {0}.x' -ReadBanner { & nvcc --version 2>&1 | Out-String }

    Assert-EnvVarSet -Name 'CUDA_ROOT'
    Assert-EnvVarSet -Name 'CUDA_PATH'

    Assert-DirectoryExists -Path $env:CUDA_ROOT -Description "CUDA_ROOT directory"
    Assert-FileExists -Path (Join-Path $env:CUDA_ROOT 'bin\nvcc.exe') -Description 'nvcc.exe in CUDA_ROOT\bin'
}

function Invoke-SmokeSection07 {
Write-TestHeader '7. CUDA Toolkit + cuDNN'
# Gate on CUDA_ROOT, not just -SkipCudaTests: a CPU-only image legitimately has no nvcc/cuDNN.
if ($script:gpuNvidia) {
    Assert-CudaSmokePrerequisites

    Invoke-CudnnSmoke
} elseif ($ExpectGpu) {
    # -ExpectGpu says this is an nvidia image, so a missing CUDA_ROOT is a defect, not a CPU lane.
    Assert-Test -Name 'CUDA section runs (-ExpectGpu)' -Condition { $false } -FailMessage 'caller passed -ExpectGpu but CUDA_ROOT is not set (or -SkipCudaTests was passed) -- nvidia image lost its baked CUDA env?'
} else {
    Skip-Test 'CUDA/cuDNN tests skipped (-SkipCudaTests, or CPU-only image without CUDA_ROOT; pass -ExpectGpu to fail loudly instead when the image should be on the nvidia lane)'
}
# Every image, owner 2026-10-21: the SLA lets only runtime DLLs ship; Dockerfile.nvidia's trt-extract keeps the SDK.
$trtNotRuntime = @(Get-TensorRtShipViolation)
Assert-Test -Name 'TensorRT ships only its runtime DLLs (no headers, import libs, trtexec, samples or wheels)' -Finding $trtNotRuntime -FailMessage "TENSORRT_ROOT carries $($trtNotRuntime.Count) SDK files: $(($trtNotRuntime | Select-Object -First 8) -join ', ')"
}

Invoke-SmokeSection07

function Invoke-OrtCpuInferenceSmoke {
    param([string]$OnnxRoot, [hashtable]$OnnxLink, $OnnxCApiHdr)
        # Graph load, session init and Run() on the CPU EP with the in-memory Identity model.
        $ortModelDir = Join-Path $env:TEMP 'kataglyphis-smoke-ort-model'
        Initialize-SmokeScratch -Path $ortModelDir
        [IO.File]::WriteAllBytes((Join-Path $ortModelDir 'identity.onnx'), $script:identityOnnxBytes)
        $onnxCxxHdr = Find-SmokeArtifact -Root $onnxRoot -Filter 'onnxruntime_cxx_api.h'
        if ($onnxCxxHdr) {
            $onnxInferLink = $onnxLink.Clone()
            $onnxInferLink.IncludeDirs = @(@($onnxCApiHdr.DirectoryName, $onnxCxxHdr.DirectoryName) | Select-Object -Unique)
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
}

function Get-RequiredSmokeDll {
    param([string]$Root, [string]$Filter, [string]$Description)
    Assert-ArtifactPresent -Root $Root -Filter $Filter -Description $Description
    return Find-SmokeArtifact -Root $Root -Filter $Filter
}

function Assert-OrtTensorRtProviderSmoke {
    param([string]$OnnxRoot, [hashtable]$OnnxLink, [string]$OnnxEpProbeSource)
            if ($script:tensorRtStaged) {
                # The runtime subset must hold what the EP imports and LoadLibrary()s, or the EP fails only at session creation.
                $trtEp = Get-RequiredSmokeDll -Root $onnxRoot -Filter 'onnxruntime_providers_tensorrt.dll' -Description 'ONNX TensorRT provider DLL (onnxruntime_providers_tensorrt.dll)'
                $trtGap = if ($trtEp) { @(Get-TensorRtEpGap -EpImports @(Get-PeImportNames -Path $trtEp.FullName -IncludeDelayLoad) -BinDir (Join-Path $env:TENSORRT_ROOT 'current\bin')) } else { @('onnxruntime_providers_tensorrt.dll') }
                Assert-Test -Name 'ORT TensorRT EP finds every TensorRT DLL it loads in TENSORRT_ROOT\current\bin' -Finding $trtGap -FailMessage "missing from the shipped TensorRT runtime: $($trtGap -join ', ')"
                # The real gate: enumerate compiled-in EPs and require CUDA + TensorRT to be present.
                Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime CUDA + TensorRT EPs available (GetAvailableProviders)' -WorkName 'onnx-eps' -Source $onnxEpProbeSource -ExpectMatch 'cuda=1 trt=1' -FailMessage 'ONNX Runtime does not expose CUDAExecutionProvider + TensorrtExecutionProvider (GPU EPs missing -- build fell back to CPU?)'
            } else {
                # Zip-less, the normal state: the EP must be absent, while CUDA stays required.
                $trtDllCount = @(Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime_providers_tensorrt.dll' -Recurse -ErrorAction SilentlyContinue).Count
                Assert-Test -Name 'ONNX TensorRT provider DLL absent (zip-less GPU lane -- no EULA zip staged)' -Condition { $trtDllCount -eq 0 }.GetNewClosure() -FailMessage "onnxruntime_providers_tensorrt.dll found under $onnxRoot although no TensorRT tree is staged -- the ORT build and the staged state disagree"
                Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime CUDA EP available, TensorRT EP absent (GetAvailableProviders, zip-less lane)' -WorkName 'onnx-eps' -Source $onnxEpProbeSource -ExpectMatch 'cuda=1 trt=0' -FailMessage 'ONNX Runtime does not expose CUDAExecutionProvider on a zip-less GPU lane (an absent TensorRT EP is expected here) -- build fell back to CPU?'
            }
}

function Assert-OrtDmlProviderSmoke {
    param([string]$OnnxRoot, [hashtable]$OnnxLink, [string]$OnnxEpProbeSource)
        # USE_DML=ON builds via the "[clang-cl DML fix]" header patch (llvm #57700); a shipped redist must register the EP.
        $dmlRedist = Find-SmokeArtifact -Root $onnxRoot -Filter 'DirectML.dll'
        if ($dmlRedist) {
            Assert-NativeLinkRun @onnxLink -Name 'ONNX Runtime DirectML EP available (GetAvailableProviders)' -WorkName 'onnx-dml' -Source $onnxEpProbeSource -ExpectMatch 'dml=1' -FailMessage 'ONNX Runtime shipped DirectML.dll but does not expose DmlExecutionProvider'
        } else {
            # Fail, not skip: USE_DML=ON is unconditional, and on the AMD reference host DirectML is the only GPU path.
            Assert-Test -Name 'ONNX Runtime DirectML redist present (USE_DML=ON is unconditional)' `
                -Condition { $false } `
                -FailMessage "DirectML.dll not found under $onnxRoot. ONNX Runtime is built with USE_DML=ON unconditionally, so the redist must ship; Copy-SidecarDll only WARNS when it cannot stage it. On the AMD reference host this is the only working GPU path."
        }
}

function Invoke-OrtProviderSmoke {
    param([string]$OnnxRoot, [hashtable]$OnnxLink)
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

        # GetAvailableProviders catches a silent CPU fallback without requiring a GPU device.
        if ($script:gpuNvidia) {
            $null = Get-RequiredSmokeDll -Root $onnxRoot -Filter 'onnxruntime_providers_cuda.dll' -Description 'ONNX CUDA provider DLL (onnxruntime_providers_cuda.dll)'
            Assert-OrtTensorRtProviderSmoke -OnnxRoot $onnxRoot -OnnxLink $onnxLink -OnnxEpProbeSource $onnxEpProbeSource
        }
        Assert-OrtDmlProviderSmoke -OnnxRoot $OnnxRoot -OnnxLink $OnnxLink -OnnxEpProbeSource $onnxEpProbeSource
}

$script:SmokeNativeSectionNames = @{
    8 = @('8. ONNX Runtime (source-built)', '8 (ONNX Runtime (source-built))')
    9 = @('9. ONNX Runtime GenAI (source-built)', '9 (ONNX Runtime GenAI (source-built))')
    10 = @('10. OpenCV 5 (source-built)', '10 (OpenCV 5 (source-built))')
    11 = @('11. GStreamer (source-built)', '11 (GStreamer (source-built))')
    12 = @('12. LiteRT (AI Edge runtime, source-built)', '12 (LiteRT (AI Edge runtime, source-built))')
    13 = @('13. LiteRT-LM (on-device LLM inference, source-built)', '13 (LiteRT-LM (on-device LLM inference, source-built))')
    17 = @('17. TVM (source-built)', '17 (TVM (source-built))')
    18 = @('18. FFmpeg (source-built with DNN/ONNX)', '18 (FFmpeg (source-built with DNN/ONNX))')
    20 = @('20. Python bindings (wheels + imports + inference)', '20 (Python bindings (wheels + imports + inference))')
    22 = @('22. IREE (source-built ML compiler + runtime)', '22 (IREE (source-built ML compiler + runtime))')
}

function Invoke-SmokeNativeSectionBody {
    param([int]$Section, [scriptblock]$Body, [scriptblock]$ResolveRoot,
        [hashtable[]]$Artifact = @(), [scriptblock]$BeforeArtifacts)
    $labels = $script:SmokeNativeSectionNames[$Section]
    Write-TestHeader $labels[0]
    if (-not (Test-SmokeNativeSection -Name $labels[1] -CrossTarget:$smokeCross -TargetArch (Get-WindowsTargetArch))) { return }
    if (-not $ResolveRoot) { & $Body; return }
    $root = & $ResolveRoot
    if (-not $root) { return }
    if ($BeforeArtifacts) { & $BeforeArtifacts $root }
    Assert-SmokeArtifacts -Root $root -Artifact $Artifact
    & $Body $root
}

function Assert-SmokeArtifacts {
    param([string]$Root, [hashtable[]]$Artifact)
    foreach ($entry in $Artifact) {
        Assert-ArtifactPresent -Root $Root -Filter $entry.Filter -Description $entry.Description -Informational:([bool]$entry['Informational'])
    }
}

function Test-SmokeNativeLinkInputs {
    param([object[]]$LinkInputs, [ValidateSet('Ort', 'OpenCv')][string]$Component)
    if (@($LinkInputs | Where-Object { -not $_ }).Count -eq 0) { return $true }
    $message = $script:SmokeNativePrerequisiteMessage[$Component]
    Assert-Test -Name $message.Name -Condition { $false } -FailMessage $message.Failure
    return $false
}

$script:SmokeNativePrerequisiteMessage = @{
    Ort = @{ Name = 'ONNX Runtime link+run prerequisites present'; Failure = 'ONNX_ROOT exists but onnxruntime.lib/.dll/c_api.h are not all found — the install shrank' }
    OpenCv = @{ Name = 'OpenCV link+run prerequisites present'; Failure = 'OPENCV_ROOT exists but opencv_core lib/dll or core.hpp are not all found — the install shrank' }
}

$script:SmokeNativeArtifacts = @{
    8 = @(
        @{ Filter = 'onnxruntime_cxx_api.h'; Description = 'ONNX C++ API header' }
        @{ Filter = 'onnxruntime_c_api.h'; Description = 'ONNX C API header' }
        @{ Filter = 'onnxruntime*.lib'; Description = 'ONNX lib files' }
        @{ Filter = 'onnxruntime*.dll'; Description = 'ONNX DLL files' }
    )
    17 = @(
        @{ Filter = 'tvm*.lib'; Description = 'TVM lib files' }
        @{ Filter = 'tvm*.dll'; Description = 'TVM DLL files' }
    )
    9 = @(
        @{ Filter = 'onnxruntime-genai*.lib'; Description = 'ONNX GenAI lib files' }
        @{ Filter = 'onnxruntime-genai*.dll'; Description = 'ONNX GenAI DLL files' }
    )
}

function Invoke-SmokeSection08 {
# Recursive search: ORT installs headers below include\onnxruntime.
Invoke-SmokeNativeSectionBody -Section 8 -ResolveRoot { Get-SmokeInstallRoot -Name ONNX_ROOT } -Artifact $script:SmokeNativeArtifacts[8] -Body {
    param($onnxRoot)
    # Existence is not loadability: compile, link and run against the ORT C API.
    $onnxCApiHdr = Find-SmokeArtifact -Root $onnxRoot -Filter 'onnxruntime_c_api.h'
    $onnxMainLib = Find-SmokeArtifact -Root $onnxRoot -Filter 'onnxruntime.lib'
    $onnxDll = Find-SmokeArtifact -Root $onnxRoot -Filter 'onnxruntime.dll'
    $onnxInputs = @($onnxCApiHdr, $onnxMainLib, $onnxDll)
    if (Test-SmokeNativeLinkInputs -LinkInputs $onnxInputs -Component Ort) {
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

        Invoke-OrtCpuInferenceSmoke -OnnxRoot $onnxRoot -OnnxLink $onnxLink -OnnxCApiHdr $onnxCApiHdr

        Invoke-OrtProviderSmoke -OnnxRoot $onnxRoot -OnnxLink $onnxLink
    }
}
}
Invoke-SmokeSection08

function Assert-SmokeLoadableDll {
    param(
        [string]$Root, [string[]]$Filter, [string]$Name, [string]$FailMessage,
        [string]$MissingName, [string]$MissingMessage,
        [string[]]$DependencyDirs = @(), [string]$Export = ''
    )
    $dll = $null
    foreach ($candidate in $Filter) {
        $dll = Find-SmokeArtifact -Root $Root -Filter $candidate
        if ($dll) { break }
    }
    if (-not $dll) {
        Assert-Test -Name $MissingName -Condition { $false } -FailMessage $MissingMessage
        return $null
    }
    Assert-DllLoads -Name $Name -DllPath $dll.FullName -DependencyDirs $DependencyDirs -Export $Export -FailMessage $FailMessage
    return $dll
}

function Assert-GenaiCudaSmoke {
    param([string]$GenaiRoot, [string]$OnnxDepDir)
        # The nvidia lane also emits onnxruntime-genai-cuda.dll, whose CUDA and ORT dependencies must resolve.
        if ($script:gpuNvidia) {
            $genaiCudaDll = Get-RequiredSmokeDll -Root $genaiRoot -Filter 'onnxruntime-genai-cuda.dll' -Description 'ONNX GenAI CUDA DLL (onnxruntime-genai-cuda.dll)'
            if ($genaiCudaDll) {
                $cudaBin  = if ($env:CUDA_ROOT) { Join-Path $env:CUDA_ROOT 'bin' } else { $null }
                $cudnnBin = Get-SmokeArtifactDirectory -EnvironmentName CUDNN_ROOT -Filter 'cudnn*.dll'
                $genaiCudaDeps = @($onnxDepDir, $cudaBin, $cudnnBin) | Where-Object { $_ }
                Assert-DllLoads -Name 'ONNX GenAI CUDA DLL loads (CUDA runtime + onnxruntime chain resolves)' -DllPath $genaiCudaDll.FullName -DependencyDirs $genaiCudaDeps -FailMessage 'onnxruntime-genai-cuda.dll failed to load -- a dependent DLL (cudart/cublas/cudnn/onnxruntime) did not resolve'
            }
        }
}

function Invoke-GenaiLoadProbe {
    param([string]$GenaiRoot)
    # Loading it and resolving an export catches a mismatched dependency no file check can see.
    $onnxDepDir = Get-SmokeArtifactDirectory -EnvironmentName ONNX_ROOT -Filter 'onnxruntime.dll'
    $genaiDepDirs = if ($onnxDepDir) { @($onnxDepDir) } else { @() }
    $genaiDll = Assert-SmokeLoadableDll -Root $genaiRoot -Filter 'onnxruntime-genai.dll' -DependencyDirs $genaiDepDirs -Export 'OgaConfigClearProviders' `
        -Name 'ONNX GenAI DLL loads + C API resolves (OgaConfigClearProviders)' `
        -FailMessage 'onnxruntime-genai.dll failed to load or its C API symbol is missing (dependent onnxruntime.dll not resolved?)' `
        -MissingName 'GenAI load-probe prerequisite present' `
        -MissingMessage 'ONNX_GENAI_ROOT exists but onnxruntime-genai.dll is missing (a -cuda.dll alone satisfies the glob above — this is the CPU-EP DLL vanishing)'
    if ($genaiDll) {

        Assert-GenaiCudaSmoke -GenaiRoot $genaiRoot -OnnxDepDir $onnxDepDir

        # DML lives in the main genai DLL; the evidence is D3D12Core.dll beside it, where the DML device loads it from.
        $genaiDir = $genaiDll.DirectoryName
        $d3d12Core = Find-SmokeArtifact -Root $genaiRoot -Filter 'D3D12Core.dll'
        if ($d3d12Core) {
            Assert-Test -Name 'ONNX GenAI DirectML: D3D12Core.dll staged beside onnxruntime-genai.dll' `
                -Condition { $d3d12Core.DirectoryName -eq $genaiDir } `
                -FailMessage "D3D12Core.dll is at $($d3d12Core.FullName) but not beside the genai DLL ($genaiDir); the DML device loads it from the genai module dir at runtime"
            # The Agility nuget ships x64, arm64 and win32, and a naive recursive copy can grab arm64 first.
            Assert-Test -Name 'ONNX GenAI DirectML: D3D12Core.dll is x64 (PE machine 0x8664)' `
                -Condition {
                    try { (Get-PeFileMachine -Path $d3d12Core.FullName) -eq 0x8664 } catch { $false }
                } `
                -FailMessage "D3D12Core.dll at $($d3d12Core.FullName) is not an x64 PE -- wrong-arch stage would fail DML device init on the x64 image"
        } else {
            Skip-Test 'GenAI DirectML evidence (D3D12Core.dll absent -- USE_DML=OFF variant)'
        }
    }
}

function Invoke-SmokeSection09 {
Invoke-SmokeNativeSectionBody -Section 9 -ResolveRoot { Get-SmokeInstallRoot -Name ONNX_GENAI_ROOT } `
    -BeforeArtifacts { param($genaiRoot)
    # @(...) so a single-FileInfo result still exposes .Count (scalar trap).
    $genaiHdr = @(Get-ChildItem -Path $genaiRoot -Filter 'ort_genai*.h' -Recurse -ErrorAction SilentlyContinue)
    if ($genaiHdr.Count -eq 0) { $genaiHdr = @(Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai.h' -Recurse -ErrorAction SilentlyContinue) }
    Assert-Test -Name 'ONNX GenAI header' -Condition { $genaiHdr.Count -gt 0 } -FailMessage "No GenAI header (ort_genai*.h / onnxruntime-genai.h) found under $genaiRoot"
} -Artifact $script:SmokeNativeArtifacts[9] -Body { param($genaiRoot)
    Invoke-GenaiLoadProbe -GenaiRoot $genaiRoot
}
}
Invoke-SmokeSection09

function Assert-OpenCvCudaSmoke {
    param([string]$OpencvSearchRoot, [string]$CvIncDir, $CvCoreLib, $CvCoreDll)
    # getBuildInformation() embeds the build config, so "NVIDIA CUDA: YES" proves the backend without a GPU.
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

function Invoke-OpenCvLinkSmoke {
    param([string]$OpencvInclude, [string]$OpencvSearchRoot)
# Existence is not loadability: compile, link and run against opencv_core.
$cvHpp = if ($opencvInclude -and (Test-Path $opencvInclude)) { Get-ChildItem -Path $opencvInclude -Filter 'core.hpp' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\opencv2\\' } | Select-Object -First 1 } else { $null }
$cvCoreLib = if ($opencvSearchRoot) { Find-SmokeArtifact -Root $opencvSearchRoot -Filter 'opencv_core*.lib' } else { $null }
$cvCoreDll = if ($opencvSearchRoot) { Find-SmokeArtifact -Root $opencvSearchRoot -Filter 'opencv_core*.dll' } else { $null }
$cvInputs = @($cvHpp, $cvCoreLib, $cvCoreDll)
if (Test-SmokeNativeLinkInputs -LinkInputs $cvInputs -Component OpenCv) {
    # <opencv2/core.hpp> resolves from the dir containing opencv2\, core.hpp's grandparent.
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

    Assert-OpenCvCudaSmoke -OpencvSearchRoot $opencvSearchRoot -CvIncDir $cvIncDir -CvCoreLib $cvCoreLib -CvCoreDll $cvCoreDll
}
}
}

function Invoke-SmokeSection10 {
Invoke-SmokeNativeSectionBody -Section 10 -Body {
$opencvInclude = [Environment]::GetEnvironmentVariable('OPENCV_INCLUDE')
$opencvRoot = [Environment]::GetEnvironmentVariable('OPENCV_ROOT')
# Per-module libs sit under <root>\<arch>\vc18, not where OPENCV_BIN/OPENCV_LIB point, so search the whole root.
$opencvSearchRoot = if ($opencvRoot -and (Test-Path $opencvRoot)) { $opencvRoot } elseif ($opencvInclude -and (Test-Path $opencvInclude)) { Split-Path $opencvInclude -Parent } else { $null }

if ($opencvInclude -and (Test-Path $opencvInclude)) {
    Assert-ArtifactPresent -Root $opencvInclude -Filter 'opencv.hpp' -Description 'OpenCV headers (opencv.hpp)'
} else {
    Skip-Test 'OPENCV_INCLUDE not set or not found'
}

if ($opencvSearchRoot) {
    # opencv_core is always built (world only if BUILD_opencv_world=ON).
    Assert-ArtifactPresent -Root $opencvSearchRoot -Filter 'opencv_core*.dll' -Description 'OpenCV core DLL'
    # Every DLL, not one: a DLL can link fine and still fail 0xC0000135 at load; CUDA/cuDNN bins are dependency dirs.
    $cvDepDirs = @(
        $env:CUDA_ROOT, "$env:CUDA_ROOT\bin", "$env:CUDNN_ROOT\bin",
        'C:\runtime\cuda-runtime\bin'
    ) | Where-Object { $_ -and (Test-Path $_) }
    Assert-AllDllsLoad -Name 'every OpenCV DLL loads (full dependent chain, not just opencv_core)' `
        -Root $opencvSearchRoot -DependencyDirs $cvDepDirs -MinimumChecked 5
} else {
    Skip-Test 'OpenCV DLLs (OPENCV_ROOT/INCLUDE not found)'
}

Invoke-OpenCvLinkSmoke -OpencvInclude $opencvInclude -OpencvSearchRoot $opencvSearchRoot

}
}
Invoke-SmokeSection10

function Invoke-SmokeSection11 {
Invoke-SmokeNativeSectionBody -Section 11 -Body {
Assert-CommandExists 'gst-launch-1.0'
Assert-CommandExists 'gst-inspect-1.0'
Assert-SmokeBannerMatch -Name 'GStreamer core plugin available' -ReadBanner { & gst-inspect-1.0 2>&1 | Out-String } `
    -Pattern 'coreelements' -FailMessage 'GStreamer coreelements plugin not found'

$gstBin = [Environment]::GetEnvironmentVariable('GSTREAMER_BIN')
Assert-DirectoryExists -Path $gstBin -Description "GSTREAMER_BIN"

# num-buffers=1 matters: a bare fakesrc produces buffers forever and hangs the smoke test.
Assert-Test -Name "GStreamer pipeline creation (fake)" -Condition {
    & gst-launch-1.0 --gst-plugin-path="$gstBin\..\lib\gstreamer-1.0" fakesrc num-buffers=1 ! fakesink 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "GStreamer fakesrc pipeline failed (coreelements broken or gst-launch cannot run)"

# Pin assert: catches a stale media layer riding into the final image.
$gstExpected = Get-ExpectedVersion 'GSTREAMER_VERSION' ''
Assert-SmokeOptionalPinnedVersion -Expected $gstExpected -Name "gst-launch matches versions.env pin ($gstExpected)" `
    -ReadBanner { & gst-launch-1.0 --version 2>&1 | Select-Object -First 1 } `
    -Failure "gst-launch-1.0 --version is not the pinned $gstExpected -- stale media layer shipped?"

# pkg_check_modules needs the pkg-config binary on top of PKG_CONFIG_PATH; modversion checks both.
Assert-CommandExists 'pkg-config'
Assert-Test -Name "pkg-config resolves gstreamer-1.0$(if ($gstExpected) { " ($gstExpected)" })" -Condition {
    $pcVer = (& pkg-config --modversion gstreamer-1.0 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($gstExpected) { return ($pcVer -eq $gstExpected) }
    return ($pcVer -match '^\d+\.\d+')
} -FailMessage "pkg-config --modversion gstreamer-1.0 failed or mismatched versions.env (missing pkg-config binary or broken PKG_CONFIG_PATH)"

# Real buffers prove the video plugin DLLs load and negotiate caps, which fakesrc cannot.
Assert-Test -Name "GStreamer real pipeline runs (videotestsrc ! videoconvert ! fakesink)" -Condition {
    & gst-launch-1.0 --gst-plugin-path="$gstBin\..\lib\gstreamer-1.0" videotestsrc num-buffers=5 ! videoconvert ! fakesink 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
} -FailMessage "videotestsrc pipeline failed (video plugin DLLs broken or missing)"

# Mandatory plugins, fatal: a plugin can compile and still fail to register without a sidecar DLL.
$requiredGstModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if (Test-Path $requiredGstModule) {
    Import-Module $requiredGstModule -Force -DisableNameChecking
    # Explicit -Arch: a bare call probes the amd64 contract on a host without WINDOWS_TARGET_ARCH.
    foreach ($plugin in @(Get-RequiredGstPlugin -Arch (Get-WindowsTargetArch))) {
        Assert-Test -Name "gst-plugin '$($plugin.Name)' is present and loadable" -Condition {
            $global:LASTEXITCODE = 0
            & gst-inspect-1.0 $plugin.Name 2>&1 | Out-Null
            $LASTEXITCODE -eq 0
        } -FailMessage ("mandatory GStreamer plugin '$($plugin.Name)' is MISSING or fails to load. " +
            "It provides $($plugin.Provides). $($plugin.Why). " +
            "Needs pkg-config: $($plugin.NeedsPc -join ', ') at GStreamer build time.")
    }
    # Signals, DTLS, SRTP and H.264 in one pipeline pair: a zeroed libffi and OpenSSL 4's BIO EOF each passed every check above.
    Assert-Test -Name 'WebRTC loopback: webrtcsink -> webrtcsrc decodes 60 frames over DTLS-SRTP' -Condition {
        $note = Assert-GstWebRtcLoopback -Frames 60 -TimeoutSeconds 90 -LogDir (Join-Path $env:TEMP 'smoke-webrtc')
        if ($note) { Write-Host "  [WARN] $note" -ForegroundColor Yellow }
        $true
    } -FailMessage 'the WebRTC loopback did not pass'
} else {
    Skip-Test "mandatory gst-plugin assertions (WindowsGstPlugins.Common.psm1 not found at $requiredGstModule -- image predates the contract)"
}

}
}
Invoke-SmokeSection11

function Assert-SmokeComponentDirectory {
    param([string]$Path, [string]$Description, [hashtable[]]$Artifact = @())
    Assert-DirectoryExists -Path $Path -Description $Description
    if (-not (Test-Path $Path)) { return }
    Assert-SmokeArtifacts -Root $Path -Artifact $Artifact
}

function Assert-LitertGpuHeaders {
    param([string]$Include)
    if (-not (Test-Path $Include)) { return }
    # GPU headers matched by path because -Filter matches file names only.
    $headers = Get-ChildItem -Path $Include -Filter '*.h' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\gpu\\' }
    Assert-Test -Name 'LiteRT GPU delegate headers' -Condition { @($headers).Count -gt 0 } -FailMessage "No GPU delegate headers found under $Include"
}

function Assert-LitertCApiExports {
    param([string]$LibDir)
    if (-not (Test-Path $LibDir)) { return }
    # An import lib can exist while the DLL exports no C-API symbol.
    $dll = Find-SmokeArtifact -Root (Split-Path $LibDir -Parent) -Filter 'tensorflowlite_c.dll'
    if ($dll) {
        foreach ($sym in @('TfLiteInterpreterCreate', 'TfLiteXNNPackDelegateCreate', 'TfLiteXNNPackDelegateOptionsDefault')) {
            Assert-DllLoads -Name "tensorflowlite_c.dll exports $sym" -DllPath $dll.FullName -Export $sym `
                -FailMessage "tensorflowlite_c.dll does not export $sym - the /EXPORT: + WINDOWS_EXPORT_ALL_SYMBOLS injection in Build-LitertFromSource.ps1 regressed. A link-clean lib with no exports breaks gst-tflite one branch later."
        }
    } else {
        Assert-Test -Name 'tensorflowlite_c.dll present (C API consumers need it)' -Condition { $false } `
            -FailMessage "tensorflowlite_c.dll not found near $LibDir - the build gates on the .lib only, so an import lib without its DLL passes that check and fails downstream."
    }
}

function Assert-LitertLmRunner {
    param([string]$BinDir)
    $exe = Join-Path $BinDir 'litert_lm_main.exe'
    Assert-FileExists -Path $exe -Description 'litert_lm_main.exe (on-device LLM runner)'
    if (-not (Test-Path $exe)) { return }
    Assert-Test -Name 'litert_lm_main.exe launches + parses flags (no abseil ODR / missing DLL)' -Condition {
        $prevPath = $env:PATH
        $env:PATH = "$BinDir;$env:PATH"
        try {
            $out = & cmd /c "`"$exe`" --help 2>&1"
            $code = $LASTEXITCODE
            $text = ($out | Out-String)
        } finally { $env:PATH = $prevPath }
        if ($text -match 'Inconsistency between flag|ODR violation|duplicate flags') { return $false }
        # 0xC0000135 means a dependent DLL did not resolve.
        if ($code -eq -1073741515 -or $code -eq 3221225781) { return $false }
        return ($text -match 'model_path|input_prompt|Flags from')
    } -FailMessage 'litert_lm_main.exe did not run cleanly (abseil flag ODR abort, missing DLL, or no flag output)'
}

function Invoke-SmokeLitertSections {
    Invoke-SmokeNativeSectionBody -Section 12 -Body {
        $root = if ($env:LITERT_ROOT) { $env:LITERT_ROOT } else { 'C:\runtime\lib\litert' }
        $include = Join-Path $root 'include'
        $lib = Join-Path $root 'lib'
        $bin = Join-Path $root 'bin'
        Assert-SmokeComponentDirectory -Path $root -Description 'LiteRT root dir'
        Assert-SmokeComponentDirectory -Path $include -Description 'LiteRT include dir' -Artifact @(
            @{ Filter = 'c_api.h'; Description = 'LiteRT C API header' }
            @{ Filter = 'interpreter.h'; Description = 'LiteRT C++ API header' }
        )
        Assert-LitertGpuHeaders -Include $include
        Assert-SmokeComponentDirectory -Path $lib -Description 'LiteRT lib dir' -Artifact @(
            @{ Filter = '*.lib'; Description = 'LiteRT lib files' }
        )
        Assert-LitertCApiExports -LibDir $lib
        # LiteRT builds statically by default, so DLL presence is informational.
        Assert-SmokeComponentDirectory -Path $bin -Description 'LiteRT bin dir' -Artifact @(
            @{ Filter = '*.dll'; Description = 'LiteRT DLL files'; Informational = $true }
        )
    }

    Invoke-SmokeNativeSectionBody -Section 13 -Body {
        $root = if ($env:LITERT_LM_ROOT) { $env:LITERT_LM_ROOT } else { 'C:\runtime\lib\litert-lm' }
        $include = Join-Path $root 'include'
        $bin = Join-Path $root 'bin'
        Assert-SmokeComponentDirectory -Path $root -Description 'LiteRT-LM root dir'
        Assert-SmokeComponentDirectory -Path $include -Description 'LiteRT-LM include dir' -Artifact @(
            @{ Filter = '*.h'; Description = 'LiteRT-LM headers' }
        )
        # LiteRT-LM ships an executable and DLLs, not a library set.
        Assert-SmokeComponentDirectory -Path $bin -Description 'LiteRT-LM bin dir' -Artifact @(
            @{ Filter = '*.exe'; Description = 'LiteRT-LM executable' }
            @{ Filter = '*.dll'; Description = 'LiteRT-LM runtime DLLs' }
        )
        Assert-LitertLmRunner -BinDir $bin
    }
}
Invoke-SmokeLitertSections

function Invoke-SmokeCompilerWorkspace {
    param([string]$Header, [string]$DirectoryName, [scriptblock]$Body)
    Write-TestHeader $Header
    $directory = Join-Path $env:TEMP $DirectoryName
    Initialize-SmokeScratch -Path $directory
    try { & $Body $directory }
    finally { Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-ClangSmokeBody {
    param($tmpDir)

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

# Cross: VSDEVCMD_ARCH=arm64 puts the ARM64 CRT on LIB, so compile for the target and assert the PE machine.
$smokeCompileTargetFlag = if ($smokeCross) { "/clang:--target=$(Get-ClangTargetTriple)" } else { $null }
Assert-Test -Name "clang-cl compiles C++ program" -Condition {
    if ($smokeCompileTargetFlag) { & clang-cl $srcFile $smokeCompileTargetFlag /Fe$exeFile /std:c++17 2>&1 | Out-Null }
    else { & clang-cl $srcFile /Fe$exeFile /std:c++17 2>&1 | Out-Null }
    return $LASTEXITCODE -eq 0
} -FailMessage "clang-cl failed to compile simple C++ program"

if ($smokeCross) {
    Assert-Test -Name "Compiled program is target-arch (PE machine)" -Condition {
        if (-not (Test-Path $exeFile)) { return $false }
        # Get-PeFileMachine throws by name on a non-PE file, which Assert-Test turns into a FAIL.
        return ((Get-PeFileMachine -Path $exeFile) -eq (Get-PeMachineType))
    } -FailMessage "cross-compiled smoke.exe has the wrong PE machine type"
    Skip-Test 'Compiled program runs: skipped on the cross lane (aarch64 exe cannot execute on this x64 host; PE machine asserted instead)'
} else {
    Assert-Test -Name "Compiled program runs" -Condition {
        $output = & $exeFile 2>&1 | Out-String
        return $output.Trim() -eq 'smoke test ok'
    } -FailMessage "Compiled program produced wrong output"
}


# ASAN must report the intentional overflow; the cross lane cannot execute the probe, and its bundle ships VS's aarch64 runtime for the device instead.
if ($smokeCross) {
    Skip-Test 'ASAN probe skipped on the cross lane (the probe must execute the instrumented exe; the bundle ships VS''s aarch64 ASan runtime for the device - Test-Arm64Bundle.ps1 asserts it)'
} else {
Assert-Test -Name "AddressSanitizer compile + runtime works (clang-cl /fsanitize=address)" -Condition {
    Invoke-WithSmokeScratch -Name asan -Body { param($d)
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
    }
} -FailMessage "ASAN probe failed: /fsanitize=address did not compile, or the runtime did not detect the intentional overflow (ASAN runtime DLLs missing?)"
}
}

Invoke-SmokeCompilerWorkspace -Header '14. Compiler smoke test (clang-cl builds C++)' -DirectoryName 'kataglyphis-smoke-test' -Body ${function:Invoke-ClangSmokeBody}

function Assert-CmakeSmokeBuild {
    param([string]$tmpDir2)
$buildDir2 = Join-Path $tmpDir2 'build'
# Cross: the configure carries the target triple, as in §14; amd64 stays byte-identical.
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
}

function Invoke-CmakeSmokeBody {
    param($tmpDir2)

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

Set-SmokeSourceFiles -Directory $tmpDir2 -Files @{ 'CMakeLists.txt' = $cmakeLists; 'smoke_cmake.cpp' = $cppSource2 }

Assert-CmakeSmokeBuild -Directory $tmpDir2
}

Invoke-SmokeCompilerWorkspace -Header '15. CMake + Ninja + clang-cl integration' -DirectoryName 'kataglyphis-smoke-cmake' -Body ${function:Invoke-CmakeSmokeBody}

function Invoke-MsbuildSmokeBody {
    param($tmpDir3)

# Single-quoted, or PowerShell evaluates $(VCTargetsPath); MSB8013 needs ProjectConfigurations and ConfigurationType.
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

Set-SmokeSourceFiles -Directory $tmpDir3 -Files @{ 'smoke_msbuild.vcxproj' = $vcxproj; 'smoke_msbuild.cpp' = $cppSource3 }

Assert-Test -Name "MSBuild+ClangCL builds" -Condition {
    & msbuild (Join-Path $tmpDir3 'smoke_msbuild.vcxproj') /p:Configuration=Release /p:Platform=x64 /nologo 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "MSBuild with ClangCL toolset failed"

}

Invoke-SmokeCompilerWorkspace -Header '16. VS MSBuild + ClangCL toolset integration' -DirectoryName 'kataglyphis-smoke-msbuild' -Body ${function:Invoke-MsbuildSmokeBody}

function Invoke-SmokeSection17 {
Invoke-SmokeNativeSectionBody -Section 17 -ResolveRoot {
    $root = if ($env:TVM_ROOT) { $env:TVM_ROOT } else { Join-Path 'C:\runtime\lib' 'tvm' }
    if (-not (Test-Path $root)) { Skip-Test 'TVM not installed (C:\runtime\lib\tvm not found)'; return $null }
    Assert-DirectoryExists -Path $root -Description "TVM install root ($root)"
    return $root
} -BeforeArtifacts { param($tvmRoot)
    $tvmInclude = Join-Path $tvmRoot 'include'
    if (Test-Path $tvmInclude) {
        # TVM's runtime header names churn across releases, so assert the directory.
        Assert-ArtifactPresent -Root $tvmInclude -Subdir 'tvm\runtime' -Filter '*.h' -Description 'TVM runtime headers (tvm/runtime/*.h)'
    } else {
        Skip-Test 'TVM include dir not found'
    }
} -Artifact $script:SmokeNativeArtifacts[17] -Body { param($tvmRoot)
    # Loading the runtime DLL proves its dependent chain resolves; TVM's C API names churn, so no link probe.
    $null = Assert-SmokeLoadableDll -Root $tvmRoot -Filter @('tvm_runtime.dll', 'tvm*runtime*.dll') `
        -Name 'TVM runtime DLL loads (dependent chain resolves)' `
        -FailMessage 'tvm_runtime.dll failed to load -- a dependent DLL (LLVM/CUDA/Vulkan runtime) did not resolve' `
        -MissingName 'TVM load-probe prerequisite present' `
        -MissingMessage 'TVM_ROOT exists but tvm_runtime.dll is missing — the runtime DLL vanished from the install'
}
}
Invoke-SmokeSection17

function Assert-FfmpegRuntimeSmoke {
    param([string]$BinDir)
    $ffmpegExe = Join-Path $BinDir 'ffmpeg.exe'
    $ffprobeExe = Join-Path $BinDir 'ffprobe.exe'
    Assert-FileExists -Path $ffmpegExe -Description 'ffmpeg.exe'
    Assert-FileExists -Path $ffprobeExe -Description 'ffprobe.exe'

    Assert-Test -Name "ffmpeg --version responds" -Condition {
        $v = & $ffmpegExe -version 2>&1 | Select-Object -First 1
        return ($null -ne $v) -and ($v -match 'ffmpeg')
    } -FailMessage "ffmpeg -version failed"

    # The configuration line is part of the -version banner; DNN filters come from enabling a backend.
    $ffCfg = & $ffmpegExe -version 2>&1 | Out-String
    Assert-Test -Name "ffmpeg built with --enable-libonnxruntime" -Condition {
        $ffCfg -match 'enable-libonnxruntime'
    } -FailMessage "ffmpeg was not configured with --enable-libonnxruntime"

    Assert-SmokeBannerMatch -Name 'ffmpeg dnn_processing filter available' `
        -ReadBanner ({ & $ffmpegExe -hide_banner -filters 2>&1 | Out-String }.GetNewClosure()) `
        -Pattern 'dnn_' -FailMessage 'no dnn_* filters reported by ffmpeg -filters'

    # -version and -filters only parse tables; a real lavfi graph proves the runtime DLL chain executes.
    Assert-Test -Name "ffmpeg runs a real filter graph (lavfi testsrc2 -> null)" -Condition {
        & $ffmpegExe -hide_banner -loglevel error -f lavfi -i testsrc2=duration=0.2:size=64x64:rate=10 -f null - 2>&1 | Out-Null
        $LASTEXITCODE -eq 0
    } -FailMessage "ffmpeg failed a trivial lavfi->null graph (runtime codec/filter chain broken)"

    # Listing codecs needs no GPU; the shared plan retains the lane's required codec tables.
    foreach ($feature in @(Get-FfmpegSmokeListingCheck -Nvidia:$script:gpuNvidia -CrossTarget:$smokeCross -Rocm:($env:EXPECT_ROCM -eq '1'))) {
        Assert-SmokeCommandOutput -Name $feature.Name -Command $ffmpegExe -ArgumentList @('-hide_banner', $feature.Listing) -ExpectMatch $feature.Expect -FailMessage $feature.Failure
    }
}

function Invoke-SmokeSection18 {
Invoke-SmokeNativeSectionBody -Section 18 -Body {
$ffmpegBin = if ($env:FFMPEG_BIN) { $env:FFMPEG_BIN } else { 'C:\runtime\ffmpeg\bin' }
if (Test-Path $ffmpegBin) {
    Assert-FfmpegRuntimeSmoke -BinDir $ffmpegBin
} else {
    Skip-Test 'FFmpeg not installed (C:\runtime\ffmpeg\bin not found)'
}

}
}
Invoke-SmokeSection18

function Invoke-SmokeSection19 {
Write-TestHeader '19. Environment pointer integrity'
# Baked pointers must name real dirs; CARGO_HOME/CARGO_BIN exist only after first use, SCOOP_GLOBAL_SHIMS is soft-asserted below.
$envPointerNames = @(
    'CMAKE_BIN', 'FLUTTER_BIN', 'VULKAN_SDK', 'WIX', 'LLVM_USER_BIN',
    'SCOOP_HOME', 'SCOOP_GLOBAL', 'SCOOP_USER_SHIMS',
    'GIT_CMD', 'GIT_BIN', 'GIT_USRBIN',
    'ONNX_ROOT', 'ONNX_GENAI_ROOT', 'OPENCV_ROOT', 'OPENCV_BIN', 'OPENCV_LIB', 'OPENCV_INCLUDE',
    # The merge image declares these for consumers; this check is their only reader.
    'FFMPEG_ROOT', 'FFMPEG_BIN', 'FFMPEG_LIB', 'GSTREAMER_BIN', 'PYTHON_BUILD_BIN', 'PYTHON_FREETHREADED_BIN', 'TEMP_DIR',
    'TVM_ROOT', 'TVM_LIBRARY_PATH', 'LITERT_ROOT', 'LITERT_INCLUDE', 'LITERT_LIB', 'LITERT_BIN',
    'LITERT_LM_ROOT', 'LITERT_LM_INCLUDE', 'LITERT_LM_BIN', 'PYTHON_WHEELS', 'PYTHON_WHEELS_FREE_THREADED',
    'IREE_ROOT', 'IREE_BIN',
    # Section 24 asserts these too; this check makes them an image-wide contract.
    'HAILO_ROOT', 'HAILO_BIN',
    # Section 21 skips when TORCH_APP_DIR is unset, so only this check catches a lost env var.
    'TORCH_APP_DIR'
)
if ($script:gpuNvidia) {
    $envPointerNames += @('CUDA_ROOT', 'CUDA_PATH', 'CUDNN_ROOT', 'TENSORRT_ROOT')
}
if ($smokeCross) {
    # No torch stage on cross (uv sync must run the target interpreter); unbuilt branches ship marker dirs, so the rest resolve.
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

# A pointer that exists proves the target is there, not that it is on PATH.
$pathMembers = @('ONNX_ROOT', 'OPENCV_BIN', 'FFMPEG_BIN', 'GSTREAMER_BIN', 'LITERT_BIN', 'LITERT_LIB', 'TVM_LIBRARY_PATH', 'IREE_BIN', 'PYTHON_BUILD_BIN', 'PYTHON_FREETHREADED_BIN')
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
# On PATH on both lanes: the ORT CUDA EP dlopens cudnn64_9.dll from here at session time.
Assert-Test -Name 'C:\runtime\cuda-runtime\bin is on PATH' -Condition {
    $pathEntries -contains 'C:\runtime\cuda-runtime\bin'
} -FailMessage 'the flattened CUDA-runtime staging dir fell off PATH (Copy-CudaRuntime.ps1 contract)'
if ($script:gpuNvidia) {
    Assert-FileExists -Path 'C:\runtime\cuda-runtime\bin\cudnn64_9.dll' -Description 'staged cuDNN runtime (ORT CUDA EP dlopens it)'
}
# Every lane (static; the arm64 bundle's chain ORT is what an aarch64 Rust target must link).
$ortCrateFindings = @(Get-OrtCrateEnvFinding -OnnxRoot $env:ONNX_ROOT)
Assert-Test -Name 'ort crate env names the chain ORT (ORT_LIB_LOCATION, ORT_DYLIB_PATH, dynamic link, no download)' `
    -Finding $ortCrateFindings -FailMessage ($ortCrateFindings -join '; ')

# Images built before 2026-08-08 lack SCOOP_GLOBAL_SHIMS, so skip rather than fail.
$globalShims = $env:SCOOP_GLOBAL_SHIMS
if ([string]::IsNullOrWhiteSpace($globalShims)) {
    Skip-Test 'SCOOP_GLOBAL_SHIMS checks skipped (env var absent -- base image predates 2026-08-08)'
} else {
    # The goal, not the mechanism: scoop never creates a global shims dir here, so a --global package must resolve by name.
    Assert-Test -Name 'globally scoop-installed package resolves by name (flutter)' -Condition {
        [bool](Get-Command flutter -ErrorAction SilentlyContinue)
    } -FailMessage 'flutter (scoop --global) does not resolve by name — neither a global shims dir nor a baked *_BIN entry is on PATH'
    Assert-Test -Name 'global scoop root holds the --global install' -Condition {
        $root = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL')
        if (-not $root) { $root = Split-Path $globalShims -Parent }
        Test-Path (Join-Path $root 'apps') -PathType Container
    }.GetNewClosure() -FailMessage 'no apps\ directory under the global scoop root — the --global install did not happen at all'
}

# LiteRT-LM's protobuf_external still consumes vcpkg zlib; VCPKG_ROOT is what vcpkg tooling honors.
$vcpkgRoot = $env:VCPKG_ROOT ?? 'C:\vcpkg'
# vcpkg's zlib port renamed its output to z.lib, so accept either name.
Assert-Test -Name "vcpkg zlib present (media-build dependency)" -Condition {
    $libDir = Join-Path $vcpkgRoot "installed\$(Get-VcpkgTriplet)\lib"
    @(Get-ChildItem -Path $libDir -Filter 'z*.lib' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('z.lib', 'zlib.lib', 'zlibstatic.lib') }).Count -gt 0
} -FailMessage "no vcpkg zlib import lib (z.lib/zlib.lib) under $vcpkgRoot\installed\$(Get-VcpkgTriplet)\lib — vcpkg install genuinely broken"
}

Invoke-SmokeSection19

function Assert-PythonWheelStore {
    param([string]$WheelStore)
    foreach ($wheelPattern in @('onnxruntime-*.whl', '*genai*.whl', '*tvm*.whl', 'av-*.whl', '*iree*compiler*.whl', '*iree*runtime*.whl', 'ai_edge_litert-*.whl')) {
        $wp = $wheelPattern
        Assert-Test -Name "wheel staged: $wheelPattern" -Condition {
            @(Get-ChildItem -Path $wheelStore -Filter $wp -ErrorAction SilentlyContinue).Count -gt 0
        }.GetNewClosure() -FailMessage "no $wheelPattern found in $wheelStore"
    }

    # A win32 tag means the shim was missing at build time; win_amd64 on arm64 means a host-built wheel leaked in.
    $pyWheelTag = Get-PythonWheelTag
    $pyPlatformName = Get-PythonPlatformName
    Assert-Test -Name "all staged wheels are $pyWheelTag-tagged" -Condition {
        @(Get-ChildItem -Path $wheelStore -Filter '*.whl' | Where-Object { $_.Name -notmatch ($pyWheelTag + '|any\.whl$') }).Count -eq 0
    } -FailMessage "wheel(s) with a non-$pyWheelTag platform tag in $wheelStore (platform-tag shim missing at build time?)"

    Assert-Test -Name "python platform tag is $pyPlatformName (sitecustomize shim)" -Condition {
        (& python -c "import sysconfig; print(sysconfig.get_platform())" 2>&1 | Out-String) -match $pyPlatformName
    } -FailMessage "sysconfig.get_platform() is not $pyPlatformName (shim missing -- pip resolves 32-bit wheels)"
}

function Invoke-SmokePythonSnippetSet {
    param([ValidateSet('Dml', 'Base', 'Extended')][string]$Group)
    switch ($Group) {
        'Dml' {
    Assert-PythonSnippet -Name "python onnxruntime exposes DML EP (not shadowed by a PyPI variant)" `
        -Code "import onnxruntime; print(onnxruntime.get_available_providers())" `
        -ExpectMatch @('DmlExecutionProvider') `
        -FailMessage "base-interpreter onnxruntime lacks DmlExecutionProvider -- a PyPI onnxruntime variant shadowed the source-built wheel"
        }
        'Base' {
    Assert-PythonSnippet -Name "python onnxruntime-genai imports" `
        -Code "import onnxruntime_genai as og; print('py-genai', getattr(og, '__version__', 'n/a'))" `
        -ExpectMatch @('py-genai') `
        -FailMessage "import onnxruntime_genai failed (pyd or embedded DLL chain broken)"

    # cv2: PNG encode/decode round-trip exercises core + imgcodecs via python.
    Assert-PythonSnippet -Name "python cv2 imports + PNG round-trip" `
        -Code "import cv2, numpy; img = numpy.zeros((8, 8, 3), numpy.uint8); ok, buf = cv2.imencode('.png', img); d = cv2.imdecode(buf, cv2.IMREAD_COLOR); print('py-cv2', cv2.__version__, bool(ok) and d.shape == (8, 8, 3))" `
        -ExpectMatch @('py-cv2 .* True') `
        -FailMessage "cv2 import or PNG round-trip failed (cv2 pyd, loader config, or OpenCV DLL chain broken)"
        }
        'Extended' {
    Assert-PythonSnippet -Name "python tvm imports (runtime device reachable)" `
        -Code "import tvm; print('py-tvm', tvm.__version__, tvm.cpu(0))" `
        -ExpectMatch @('py-tvm') `
        -FailMessage "import tvm failed (wheel, tvm_runtime/tvm_ffi DLLs, or deps broken)"

    # PyPI's PyAV imports AVICAP32, absent on Server Core; mpeg4 by name, as `h264` resolves to h264_d3d12va.
    Assert-PythonSnippet -Name "python av (PyAV vs our ffmpeg): in-memory mpeg4 encode" `
        -Code "import io, av; buf = io.BytesIO(); c = av.open(buf, mode='w', format='mp4'); s = c.add_stream('mpeg4', rate=24); s.width = 64; s.height = 64; s.pix_fmt = 'yuv420p'; f = av.VideoFrame(64, 64, 'yuv420p'); [c.mux(p) for p in s.encode(f)]; [c.mux(p) for p in s.encode()]; c.close(); print('py-av', av.__version__, len(buf.getvalue()) > 0)" `
        -ExpectMatch @('py-av .* True') `
        -FailMessage "PyAV import or mpeg4 encode failed (av pyd, our ffmpeg DLL chain, or codec table broken)"

    # Proves the two IREE wheels interoperate; tensor<f32> args must be numpy arrays, not bare floats.
    Assert-PythonSnippet -Name "python iree compile+run end-to-end (abs(-5)=5, local-task)" `
        -Code "import numpy as np, iree.compiler.tools as t, iree.runtime as rt; vm = t.compile_str('$script:ireeGateMlir', target_backends=['llvm-cpu']); m = rt.load_vm_flatbuffer(vm, driver='local-task'); print('py-iree', float(m.abs(np.asarray(-5.0, dtype=np.float32)).to_host()))" `
        -ExpectMatch @('py-iree 5\.0') `
        -FailMessage "iree.compiler/iree.runtime end-to-end failed (wheels, bundled iree-compile, or runtime driver broken)"
        }
    }
}

function Invoke-PythonRuntimeSmoke {
    # onnxruntime: real python-side inference over the shared 63-byte Identity model.
    Assert-Test -Name "python onnxruntime inference end-to-end (CPU EP)" -Condition {
        Invoke-WithSmokeScratch -Name pyort -Body { param($mdir)
            [IO.File]::WriteAllBytes((Join-Path $mdir 'identity.onnx'), $script:identityOnnxBytes)
            $out = & python -c "import sys, numpy, onnxruntime as ort; s = ort.InferenceSession(sys.argv[1], providers=['CPUExecutionProvider']); y = s.run(['y'], {'x': numpy.array([42.0], numpy.float32)})[0]; print('py-ort', ort.__version__, float(y[0]))" (Join-Path $mdir 'identity.onnx') 2>&1 | Out-String
            ($LASTEXITCODE -eq 0) -and ($out -match 'py-ort .*42\.0')
        }
    } -FailMessage "onnxruntime python inference failed (pyd, dependent DLLs, or numpy broken)"

    # PyPI's onnxruntime-gpu has no DML EP, so DML exposes a same-version PyPI variant shadowing ours.
    Invoke-SmokePythonSnippetSet -Group Dml

    if ($script:gpuNvidia) {
        # Follows the staged state: a zip-less lane passes with the CUDA EP alone.
        $pyEpExpect = if ($script:tensorRtStaged) { @('CUDAExecutionProvider', 'TensorrtExecutionProvider') } else { @('CUDAExecutionProvider') }
        $pyEpName = if ($script:tensorRtStaged) { 'python onnxruntime exposes CUDA + TensorRT EPs (GPU lane)' } else { 'python onnxruntime exposes CUDA EP (GPU lane, zip-less: TensorRT EP absent by design)' }
        Assert-PythonSnippet -Name $pyEpName `
            -Code "import onnxruntime; print(onnxruntime.get_available_providers())" `
            -ExpectMatch $pyEpExpect `
            -FailMessage "base-interpreter onnxruntime lacks the expected GPU EP(s) (TensorRT staged: $($script:tensorRtStaged))"
    }

    Invoke-SmokePythonSnippetSet -Group Base
}

function Invoke-OpenCvPythonBackendSmoke {
    # Video backends: getBackends() lists GSTREAMER whether or not it was compiled in, so it proves nothing.
    $cvBuildInfo = & python -c "import cv2; print(cv2.getBuildInformation())" 2>&1 | Out-String

    # The standalone plugin leaves getBuildInformation() at `GStreamer: NO`; hasBackend attempts the plugin load.
    Assert-PythonSnippet -Name "cv::VideoCapture has a working GStreamer backend (plugin, #93)" -Code "import cv2; print('gst-backend', cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER))" -ExpectMatch 'gst-backend True' -FailMessage ("cv2.videoio_registry.hasBackend(CAP_GSTREAMER) is False -- the opencv_videoio_gstreamer plugin " +
        "DLL is missing next to opencv_videoio*.dll, or it failed to load (GStreamer DLLs not resolvable). " +
        "Built by Build-OpencvGstreamerPlugin.ps1 in the merge stage -- backlog #93.")

    # Capability, not just loadability: open a real (synthetic) pipeline and read one frame.
    Assert-PythonSnippet -Name "cv::VideoCapture opens a GStreamer pipeline and reads a frame (#93)" -Code "import cv2; cap = cv2.VideoCapture('videotestsrc num-buffers=1 ! videoconvert ! appsink', cv2.CAP_GSTREAMER); ok, frame = cap.read(); print('gst-read', bool(ok) and frame is not None and frame.size > 0)" -ExpectMatch 'gst-read True' -FailMessage ("VideoCapture(CAP_GSTREAMER) could not read a frame from a videotestsrc pipeline -- the plugin " +
        "loads but the GStreamer runtime underneath it is broken (core plugins missing from the plugin dir, or " +
        "GST_PLUGIN_PATH/PATH not set by the entrypoint). Backlog #93.")

    # Not provenance: `(prebuilt binaries)` prints for any wrapper build; the avcodec comparison below is.
    Assert-Test -Name 'OpenCV has an FFmpeg backend at all' -Condition {
        $cvBuildInfo -match '(?m)^\s*FFMPEG:\s+YES'
    } -FailMessage 'cv2.getBuildInformation() does not report FFMPEG: YES -- cv::VideoCapture has no FFmpeg path.'

    # avdevice was NO with OpenCV's downloaded FFmpeg; #94 turned it on -- guard the regression.
    Assert-Test -Name 'OpenCV FFmpeg backend includes avdevice (#94)' -Condition {
        $cvBuildInfo -match '(?m)^\s*avdevice:\s+YES'
    } -FailMessage ('cv2.getBuildInformation() reports avdevice as NO -- the FFmpeg backend lost libavdevice, ' +
        'which is one of the symptoms #94 fixed.')

    # Majors must agree, which survives a version bump; both are read first so "unreadable" stays apart from "mismatch".
    $ffDir = if ($env:FFMPEG_BIN) { $env:FFMPEG_BIN } else { 'C:\runtime\ffmpeg\bin' }
    $ffExe = Join-Path $ffDir 'ffmpeg.exe'
    $chainAvcodec = ''
    if (Test-Path $ffExe) {
        # Without its bin dir on PATH ffmpeg.exe cannot resolve avcodec-*.dll and prints no version.
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
}

function Invoke-FreeThreadedWheelSmoke {
    param([string]$WheelStore)
    # The cp3XYt twins (store PYTHON_WHEELS_CP314T before CON91), each proved again here; docs/windows-builds.md#the-free-threaded-wheels
    $ftStore = @($env:PYTHON_WHEELS_FREE_THREADED, $env:PYTHON_WHEELS_CP314T) | Where-Object { $_ } | Select-Object -First 1
    if ($ftStore) {
        Assert-Test -Name "the free-threaded store $ftStore exists" -Condition { Test-Path -LiteralPath $ftStore -PathType Container }.GetNewClosure() `
            -FailMessage "the image names $ftStore as its free-threaded store, and it is not there"
    }
    if ($ftStore -and (Test-Path $ftStore)) {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking
        $ftWheels = @(Get-ChildItem -Path $ftStore -Filter '*.whl' -File)
        # The image's own copy of the twin table, as for the helper below: the gate mounts windows/scripts alone.
        $ftTable = Resolve-SmokeCompanion -ScriptRoot $scriptAssetRoot -Name 'free-threaded-twins.txt'
        Assert-Test -Name 'the twin table is baked beside the helper (free-threaded-twins.txt)' -Condition { [bool]$ftTable }.GetNewClosure() `
            -FailMessage 'free-threaded-twins.txt is in neither the script mount nor C:\temp\scripts'
        $ftTwins = @(if ($ftTable) { Get-FreeThreadedTwinTable -Path $ftTable | Where-Object Verdict -ceq 'twin' | ForEach-Object Distribution | Sort-Object })
        $ftHeld = @($ftWheels | ForEach-Object { ConvertTo-PythonDistributionName -Name ($_.Name -split '-')[0] } | Sort-Object)
        Assert-Test -Name "free-threaded store holds one wheel per twin: $($ftTwins -join ', ')" -Condition { ($ftHeld -join ',') -ceq ($ftTwins -join ',') }.GetNewClosure() `
            -FailMessage "$ftStore holds [$($ftHeld -join ', ')], the twin table names [$($ftTwins -join ', ')]"
        $ftTagFindings = @($ftWheels | ForEach-Object { Get-FreeThreadedWheelFinding -Path $_.FullName -PlatformTag (Get-PythonWheelTag) })
        Assert-Test -Name "every free-threaded-store wheel is cp3XY-cp3XYt $(Get-PythonWheelTag), no GIL or abi3 module inside" -Finding $ftTagFindings `
            -FailMessage ($ftTagFindings -join '; ')
        $ftLeaked = @(Get-ChildItem -Path $wheelStore -Filter '*.whl' -File | Where-Object { $_.Name -match '-cp\d+-cp\d+t-' } | ForEach-Object Name)
        Assert-Test -Name 'no free-threaded wheel in the GIL store (PYTHON_WHEELS)' -Finding $ftLeaked `
            -FailMessage "$($ftLeaked -join ', ') in $wheelStore, where every GIL install would see it"
        $ftSite = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $ftExe -Parent) 'Lib\site-packages') -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'README.txt' | ForEach-Object Name)
        Assert-Test -Name 'the free-threaded interpreter''s site-packages stays empty (twins install into venvs)' -Finding $ftSite `
            -FailMessage "it holds $($ftSite -join ', ')"
        # The image's own copy of the helper; this script may run from a mount that lacks it.
        $ftHelper = Resolve-SmokeCompanion -ScriptRoot $scriptAssetRoot -Name 'free-threaded-wheel.py'
        $ftDllHomes = @($env:PATH -split ';' | Where-Object { $_ -like 'C:\runtime\*' })
        foreach ($ftWheel in $ftWheels) {
            $ftDist = ConvertTo-PythonDistributionName -Name ($ftWheel.Name -split '-')[0]
            $ftProof = ''
            try {
                if (-not $ftHelper) { throw 'free-threaded-wheel.py is in neither the script mount nor C:\temp\scripts' }
                $ftProof = Invoke-FreeThreadedWheelVenvProof -Interpreter $ftExe -Wheel $ftWheel.FullName -Distribution $ftDist -DllDirectory $ftDllHomes -Helper $ftHelper
            } catch { $ftProof = "FAILED: $($_.Exception.Message)" }
            Assert-Test -Name "free-threaded twin $ftDist keeps the GIL off under $ftExe" -Condition { $ftProof -notlike 'FAILED:*' }.GetNewClosure() -FailMessage $ftProof
        }
    } elseif (-not $ftStore) {
        Skip-Test 'free-threaded twins (PYTHON_WHEELS_FREE_THREADED unset -- image predates the free-threaded wheels)'
    }
}

function Invoke-SmokeSection20 {
Invoke-SmokeNativeSectionBody -Section 20 -Body {
# cv2 ships installed in place only; ai-edge-litert is a bazel wheel for the pinned Python (CON91).
$wheelStore = Get-SmokeExistingInstallRoot -Name PYTHON_WHEELS
if ($wheelStore) {

    Assert-PythonWheelStore -WheelStore $wheelStore
    Invoke-PythonRuntimeSmoke
    Invoke-OpenCvPythonBackendSmoke
    Invoke-SmokePythonSnippetSet -Group Extended
    Invoke-FreeThreadedWheelSmoke -WheelStore $wheelStore

} else {
    Skip-Test 'Python bindings (PYTHON_WHEELS unset or missing -- image predates the wheel feature)'
}

}
}
Invoke-SmokeSection20

function Invoke-SmokeSection21 {
Write-TestHeader '21. OrchestrANT app environment (torch step)'
if (Test-SmokeNativeSection -Name '21 (OrchestrANT app environment (torch step))' -CrossTarget:$smokeCross -TargetArch (Get-WindowsTargetArch)) {
# Re-runs Build-TorchApp.ps1's verify mode offline against the baked venv.
$torchAppDir = [Environment]::GetEnvironmentVariable('TORCH_APP_DIR')
# A set TORCH_APP_DIR without a resolvable verifier is a gate wiring bug, not an optional feature.
$torchAppScript = Resolve-SmokeCompanion -ScriptRoot $PSScriptRoot -Name 'Build-TorchApp.ps1'
if ($torchAppDir -and (Test-Path $torchAppDir) -and -not $torchAppScript) {
    Assert-Test -Name 'torch-app verifier reachable (gate wiring)' -Condition { $false } `
        -FailMessage 'TORCH_APP_DIR is baked but Build-TorchApp.ps1 is neither beside the smoke script nor at C:\temp\scripts — the gate mount lost the verifier'
}
if ($torchAppDir -and (Test-Path $torchAppDir) -and $torchAppScript) {
    Assert-DirectoryExists -Path (Join-Path $torchAppDir '.venv') -Description 'torch-app venv'
    # The verify re-runs Build-TorchApp's ORT census (every ORT dist a chain wheel); its FAIL lines are the message.
    $torchAppVerify = & pwsh -NoProfile -ExecutionPolicy Bypass -File $torchAppScript -AppDir $torchAppDir -Mode verify 2>&1 | Out-String
    $torchAppVerifyOk = ($LASTEXITCODE -eq 0) -and ($torchAppVerify -match 'torch-app-env OK') -and ($torchAppVerify -match '(?m)^ORT-CENSUS PASS')
    $torchAppCensusFails = @([regex]::Matches($torchAppVerify, '(?m)^ORT-CENSUS FAIL (.+?)\r?$') | ForEach-Object { $_.Groups[1].Value })
    Assert-Test -Name "torch-app venv verifies (numpy/cv2/torch/ort+CUDA-EP/genai/tvm/av/iree, chain-only ORT)" `
        -Condition { $torchAppVerifyOk }.GetNewClosure() `
        -FailMessage "Build-TorchApp.ps1 -Mode verify failed (baked venv broken, local wheels lost, or an ORT that is not the chain's)$(if ($torchAppCensusFails) { ': ' + ($torchAppCensusFails -join '; ') })"
    # PyPI's onnxruntime lacks the DML EP but shares the version, so only the bytes prove the chain wheel.
    $ortWheel = Resolve-ChainOrtWheel -WheelDir $(if ($env:PYTHON_WHEELS) { $env:PYTHON_WHEELS } else { 'C:\runtime\wheels' })
    $ortReport = $null
    $ortProbeError = ''
    try {
        $ortReport = Invoke-TorchAppOrtProbe -Python (Join-Path $torchAppDir '.venv\Scripts\python.exe') -WheelPath $ortWheel.Path
    } catch { $ortProbeError = $_.Exception.Message }
    $ortDmlFindings = @(Get-TorchAppOrtFinding -Report $ortReport -Aspect Dml -ProbeError $ortProbeError)
    Assert-Test -Name 'torch-app venv: onnxruntime + GenAI built with DirectML (every amd64 lane, no device)' `
        -Finding $ortDmlFindings -FailMessage ($ortDmlFindings -join '; ')
    $ortWheelFindings = @(Get-TorchAppOrtFinding -Report $ortReport -Aspect Provenance -Wheel $ortWheel -ProbeError $ortProbeError `
            -VenvSitePackages (Join-Path $torchAppDir '.venv\Lib\site-packages'))
    Assert-Test -Name 'torch-app venv: onnxruntime is the chain wheel (sole owner, same version, same binaries)' `
        -Finding $ortWheelFindings -FailMessage ($ortWheelFindings -join '; ')
} else {
    Skip-Test 'OrchestrANT app env (TORCH_APP_DIR unset or missing -- image predates the torch step)'
}

}
}

Invoke-SmokeSection21

function Invoke-SmokeSection22 {
Invoke-SmokeNativeSectionBody -Section 22 -Body {
# Real work, not existence checks: compile MLIR to a vmfb and execute it.
$ireeBin = Get-SmokeExistingInstallRoot -Name IREE_BIN
if ($ireeBin) {
    Assert-CommandExists 'iree-compile'
    Assert-CommandExists 'iree-run-module'

    # The source-built iree-compile reports "version (unknown)", so pin on the wheel name git-describe stamps.
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
        Test-SmokeCompiledArtifact -Compiler iree-compile -ArgumentList @('--iree-hal-target-backends=llvm-cpu', $ireeMlir, '-o', $ireeVmfb) -OutputPath $ireeVmfb
    } -FailMessage "iree-compile failed to lower MLIR for llvm-cpu"

    Assert-SmokeCommandOutput -Name "iree-run-module: local-task executes abs(-5)=5" -Command iree-run-module -ArgumentList @("--module=$ireeVmfb", '--device=local-task', '--function=abs', '--input=f32=-5') -ExpectMatch 'f32=5'  -FailMessage "iree-run-module failed or returned wrong result (runtime/HAL broken)"

    if ($script:gpuNvidia) {
        # Compile-only: execution needs a CUDA device, which containers on this host cannot see.
        Assert-Test -Name "iree-compile: MLIR -> vmfb (cuda target, compile-only)" -Condition {
            $cudaVmfb = Join-Path $ireeDir 'abs-cuda.vmfb'
            Test-SmokeCompiledArtifact -Compiler iree-compile -ArgumentList @('--iree-hal-target-backends=cuda', $ireeMlir, '-o', $cudaVmfb) -OutputPath $cudaVmfb
        } -FailMessage "iree-compile cuda target failed (NVPTX backend broken)"
    }

    Remove-Item $ireeDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Skip-Test 'IREE (IREE_BIN unset or missing -- image predates the IREE step)'
}

}
}
Invoke-SmokeSection22

function Invoke-SmokeSection23 {
Write-TestHeader '23. Baked C:\temp\scripts surface (host-arch)'
# The gate bind-mounts windows/scripts, so only this section exercises the copies baked into the image.
$bakedScriptsRoot = 'C:\temp\scripts'
if (-not (Test-Path (Join-Path $bakedScriptsRoot 'Test-Container.ps1'))) {
    Skip-Test "baked C:\temp\scripts surface ($bakedScriptsRoot predates the final-stage COPY)"
} else {
    # Four baked files; the torch-assembled one is default-dropped on the cross lane.
    $bakedFiles = @('Test-Health.ps1', 'Test-Container.ps1', 'entrypoint.cmd')
    if ($smokeCross) {
        Skip-Test 'baked Build-TorchApp.ps1 (torch stage is dropped on the cross lane; see docs/windows-cross-builds.md)'
    } else {
        $bakedFiles += 'Build-TorchApp.ps1'
    }
    foreach ($bakedFile in $bakedFiles) {
        Assert-FileExists -Path (Join-Path $bakedScriptsRoot $bakedFile) -Description "baked $bakedFile"
    }

    # The shipped module set must import from where the image puts it, not the mount.
    $bakedModule = Join-Path $bakedScriptsRoot 'modules\WindowsTargetArch.Common.psm1'
    Assert-Test -Name 'baked modules dir imports (WindowsTargetArch.Common.psm1)' -Condition {
        Import-Module $bakedModule -Force -ErrorAction Stop
        (Get-Module 'WindowsTargetArch.Common').Path -eq $bakedModule -and
        [bool](Get-Command Get-WindowsTargetArch -ErrorAction SilentlyContinue)
    } -FailMessage "Import-Module $bakedModule failed or resolved to a different file"

    # Exit code only: echoed [PASS]/[SKIP] lines would read as this suite's assertions.
    Assert-Test -Name 'baked healthcheck exits 0 (Test-Health.ps1)' -Condition {
        $null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bakedScriptsRoot 'Test-Health.ps1') 2>&1
        $LASTEXITCODE -eq 0
    } -FailMessage 'the baked Test-Health.ps1 exited non-zero (the shipped image healthcheck is genuinely broken)'
}
}

Invoke-SmokeSection23

function Invoke-SmokeSection24 {
Write-TestHeader '24. Hailo (source-built, Phase 3)'
# HailoRT (docs/hailo-support.md); on cross the CLI run-probe becomes a PE-machine assert, as in sections 7 and 14.
if ([string]::IsNullOrWhiteSpace($env:HAILO_ROOT)) {
    Skip-Test 'Hailo section (HAILO_ROOT not set -- pre-Phase-3 image)'
} else {
    Assert-EnvVarSet -Name 'HAILO_ROOT'
    Assert-DirectoryExists -Path $env:HAILO_ROOT -Description 'HAILO_ROOT directory'
    $hailortCli = Get-ChildItem -Path $env:HAILO_ROOT -Filter 'hailortcli.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    # The Windows install names the library libhailort.dll (the Linux lane's libhailort.so).
    $hailortDll = Get-ChildItem -Path $env:HAILO_ROOT -Filter 'libhailort.dll' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert-Test -Name 'hailortcli.exe present' -Condition { $null -ne $hailortCli }.GetNewClosure() -FailMessage "hailortcli.exe not found under $env:HAILO_ROOT"
    Assert-Test -Name 'libhailort.dll present' -Condition { $null -ne $hailortDll }.GetNewClosure() -FailMessage "libhailort.dll not found under $env:HAILO_ROOT"
    if ($hailortCli -and $hailortDll) {
        if ($smokeCross) {
            Assert-Test -Name 'libhailort.dll is the target arch (PE machine)' -Condition {
                try { (Get-PeFileMachine -Path $hailortDll.FullName) -eq (Get-PeMachineType) } catch { $false }
            }.GetNewClosure() -FailMessage 'cross-built libhailort.dll has the wrong PE machine type'
        } else {
            Assert-DllLoads -Name 'libhailort.dll loads (WinUSB/PCIe stack resolves)' -DllPath $hailortDll.FullName
            Assert-Test -Name 'hailortcli --version runs' -Condition {
                $out = & $hailortCli.FullName --version 2>&1 | Out-String
                ($LASTEXITCODE -eq 0) -and ($out -match 'HailoRT')
            }.GetNewClosure() -FailMessage 'hailortcli --version failed (the CLI or its dependent DLLs are broken)'
        }
    }
}
}

Invoke-SmokeSection24

function Invoke-SmokeSection25 {
Write-TestHeader '25. ONNX Runtime single source'
# G1: every ORT byte in the image is the chain build, checked statically, so arm64 runs it too; see docs/onnxruntime-single-source.md.
$ortCensusExemption = @()   # '<arch>:<path>:<reason>'; an entry that stops matching fails, one naming an in-box ORT too
$ortStampArmed = $false
$ortCensus = $null
$ortCensusError = ''
try {
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsOrtProvenance.Common.psm1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsOrtProvenance.Build.psm1') -Force -DisableNameChecking -ErrorAction Stop
    # STAMP arms itself with G2: stamps exist only once Assert-ChainOrtOnly writes them.
    $ortStampArmed = [bool](Get-Command -Name 'Assert-ChainOrtOnly' -ErrorAction SilentlyContinue)
    $ortCensus = Invoke-OrtImageCensus -Arch (Get-WindowsTargetArch) -CrossTarget:$smokeCross `
        -OrtVersion (Get-ExpectedVersion 'ONNXRUNTIME_VERSION' '') -RequireStamp:$ortStampArmed -Exemption $ortCensusExemption
    Write-OrtCensusReport -Census $ortCensus -Title 'ORT census'
} catch { $ortCensusError = $_.Exception.Message }
$ortGroups = [ordered]@{
    run = @('NONE', 'EXEMPT-STALE'); bytes = @('FOREIGN', 'STALE', 'UNPROVEN'); placement = @('ELSEWHERE', 'UNRESOLVED')
    consumers = @('UNREGISTERED', 'DIST'); stamp = @('STAMP'); inbox = @('INBOX')
}
$ortFail = @{}
foreach ($g in $ortGroups.Keys) { $ortFail[$g] = @($(if (-not $ortCensus) { "the census did not run: $ortCensusError" })) }
foreach ($f in @(if ($ortCensus) { $ortCensus.Findings | Where-Object Fatal })) {
    # An unknown fatal verdict lands in 'run', so it can never pass unasserted.
    $g = @($ortGroups.Keys | Where-Object { $ortGroups[$_] -contains $f.Verdict }) + @('run') | Select-Object -First 1
    $ortFail[$g] += "$($f.Verdict) $($f.Path): $($f.Detail)"
}
foreach ($a in @(
        @{ G = 'run'; Name = 'ORT census ran: chain reference from this image, ORT binaries found, exemptions current' }
        @{ G = 'bytes'; Name = 'ORT bytes: no foreign, stale or unproven ONNX Runtime anywhere in the image' }
        @{ G = 'placement'; Name = 'ORT placement: chain copies only in their homes, every importer resolves to the chain' }
        @{ G = 'consumers'; Name = 'ORT consumers: every one registered, one onnxruntime distribution per interpreter' })) {
    $ortLines = @($ortFail[$a.G])
    Assert-Test -Name $a.Name -Finding $ortLines -FailMessage (@($ortLines | Select-Object -First 25) -join ' | ')
}
# An in-box ORT would beat PATH for every importer; see docs/onnxruntime-single-source.md#the-in-box-onnx-runtime-windows-ml
$ortLines = @($ortFail['inbox'])
if (-not $smokeCross) {
    Assert-Test -Name 'ORT in-box: the Windows dir holds no ONNX Runtime or Windows ML (servercore ships none)' -Finding $ortLines `
        -FailMessage (@($ortLines | Select-Object -First 25) -join ' | ')
} else {
    Skip-Test 'ORT in-box (cross lane: the base image''s Windows dir is not the device''s; Test-OrtProvenanceTree assumes a client System32 ORT)'
}
if ($ortStampArmed) {
    $ortLines = @($ortFail['stamp'])
    Assert-Test -Name 'ORT stamps: every present consumer was gated against this chain ORT (G2)' -Finding $ortLines `
        -FailMessage (@($ortLines | Select-Object -First 25) -join ' | ')
} else {
    Skip-Test 'ORT stamps (unarmed: no Assert-ChainOrtOnly in this hub, so no consumer writes one yet)'
}
}

Invoke-SmokeSection25

function Get-SmokeCoverageProblems {
    param($Summary)
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
# Per-section floors, measured per lane and changed deliberately; a payload section skipped on cross stays 0.
$sectionFloors = @{
    '1' = @{ Gpu = 13; Cpu = 13; Arm64 = 13 }; '2' = @{ Gpu = 8; Cpu = 8; Arm64 = 8 }; '3' = @{ Gpu = 8; Cpu = 8; Arm64 = 8 }
    '4' = @{ Gpu = 8; Cpu = 8; Arm64 = 8 };    '5' = @{ Gpu = 4; Cpu = 4; Arm64 = 4 }; '6' = @{ Gpu = 4; Cpu = 4; Arm64 = 4 }
    # '7' counts a real -ExpectGpu run; Arm64 stays 0, as the cross CPU lane skips the section.
    '7' = @{ Gpu = 13; Cpu = 0; Arm64 = 0 };  '8' = @{ Gpu = 11; Cpu = 8; Arm64 = 0 };  '9' = @{ Gpu = 9; Cpu = 6; Arm64 = 0 }
    '10' = @{ Gpu = 7; Cpu = 4; Arm64 = 0 };  '11' = @{ Gpu = 20; Cpu = 20; Arm64 = 0 }; '12' = @{ Gpu = 9; Cpu = 9; Arm64 = 0 }
    '13' = @{ Gpu = 6; Cpu = 6; Arm64 = 0 }
    # '14' arm64 is 2: the run-assert becomes a PE-machine assert 1:1, but ASAN is a SKIP there.
    '14' = @{ Gpu = 3; Cpu = 3; Arm64 = 2 };  '15' = @{ Gpu = 2; Cpu = 2; Arm64 = 2 };  '16' = @{ Gpu = 1; Cpu = 1; Arm64 = 1 }
    '17' = @{ Gpu = 5; Cpu = 5; Arm64 = 0 };  '18' = @{ Gpu = 8; Cpu = 6; Arm64 = 0 };  '19' = @{ Gpu = 31; Cpu = 27; Arm64 = 25 }
    # '21' is 4 on every amd64 lane: venv dir, app verify, venv DML, chain-wheel provenance.
    '20' = @{ Gpu = 22; Cpu = 21; Arm64 = 0 }; '21' = @{ Gpu = 4; Cpu = 4; Arm64 = 0 }; '22' = @{ Gpu = 7; Cpu = 6; Arm64 = 0 }
    # '23' arm64 is 5: the torch-baked Build-TorchApp.ps1, the amd64 sixth, is skipped on cross.
    '23' = @{ Gpu = 6; Cpu = 6; Arm64 = 5 }
    # '24' Hailo: six host-runnable assertions on amd64; arm64 runs a static subset, so its floor stays 0.
    '24' = @{ Gpu = 6; Cpu = 6; Arm64 = 0 }
    # '25' ORT census: four static assertions on every lane, the in-box one on amd64 (+1 STAMP once G2 arms it).
    '25' = @{ Gpu = 5; Cpu = 5; Arm64 = 4 }
}
# Cross first: even with -ExpectGpu the arm64 lane skips the payload, so the Gpu column would be unreachable.
$floorLane = if ($smokeCross) { 'Arm64' } elseif ($ExpectGpu) { 'Gpu' } else { 'Cpu' }
foreach ($sec in $sectionFloors.Keys) {
    $floor = $sectionFloors[$sec][$floorLane]
    if ($floor -le 0) { continue }
    $got = if ($summary.SectionPassed.Contains($sec)) { [int]$summary.SectionPassed[$sec] } else { 0 }
    if ($got -lt $floor) {
        $coverageProblems += "section $sec passed only $got assertion(s), floor is $floor — a subsystem's verification quietly shrank"
    }
}
    return $coverageProblems
}

function Invoke-SmokeSectionSummary {
Write-TestHeader '== SUMMARY =='
# Through the module: the counters live in its scope, and a bare $script:passed here would report 0/0.
$summary = Get-SmokeTestSummary
Write-Host "  Passed:  $($summary.Passed)" -ForegroundColor Green
Write-Host "  Failed:  $($summary.Failed)" -ForegroundColor Red
Write-Host "  Skipped: $($summary.Skipped)" -ForegroundColor Yellow
Write-Host "  Total:   $($summary.Total)" -ForegroundColor Cyan
if ($summary.Aborted) {
    Write-Host '  NOTE: -ExitOnFirstFailure aborted the run at the first failure; remaining tests were not executed.' -ForegroundColor Yellow
}

if ($summary.Failed -gt 0) {
    Write-RedFindingList -Header "`n--- FAILURE DETAILS ---" -Item $summary.FailureDetails
    exit 1
}

# Zero failures is not "verified"; checked after the failure branch so a failure still reports as one.
$coverageProblems = @(Get-SmokeCoverageProblems -Summary $summary)
if ($coverageProblems.Count -gt 0) {
    Write-Host "`n--- INSUFFICIENT COVERAGE ---" -ForegroundColor Red
    foreach ($p in $coverageProblems) { Write-Host "  $p" -ForegroundColor Red }
    Write-Host 'Refusing to report success: 0 failures with too little executed is indistinguishable from a broken harness.' -ForegroundColor Red
    exit 3
}

Write-Host "`nAll smoke tests passed! ($($summary.Passed) assertions, $($summary.Skipped) skipped)" -ForegroundColor Green
exit 0
}

Invoke-SmokeSectionSummary

