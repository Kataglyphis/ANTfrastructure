# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = '',
    # rocm-lane WebGPU spike only: the Dawn tree and the DXC release, removed after the wheel.
    [string]$WebGpuWorkDir = 'C:\temp\ort-webgpu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast before module import

# #108: repo layout is scripts/<group>/ while container mounts stay FLAT, so shared
# assets sit beside this script (flat) or one level up (repo).
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

# ── rocm-lane WebGPU EP spike (ORT_WEBGPU=1): the in-tree EP over Dawn/D3D12 with a pinned DXC.
#    Inputs, fetches and the clang-cl notes: docs/windows-rocm.md § ONNX Runtime WebGPU EP.
function Get-OrtWebGpuPlan {
    param([Parameter(Mandatory)][hashtable]$GpuEnv, [bool]$Cross, [AllowEmptyString()][string]$SpikeFlag)
    if ($SpikeFlag -notin @('', '0', '1')) { throw "ORT_WEBGPU must be '0' or '1', got '$SpikeFlag'" }
    $onLane = [bool]($GpuEnv.HasRocm -and -not $Cross)
    if ($SpikeFlag -eq '1' -and -not $onLane) {
        throw "ORT_WEBGPU=1 but GPU_TYPE is '$($GpuEnv.GpuType)'$(if ($Cross) { ' on the cross lane' }): the WebGPU EP spike is rocm-lane only"
    }
    return [pscustomobject]@{ OnLane = $onLane; WebGpu = ($onLane -and $SpikeFlag -eq '1') }
}

# The ORT_WEBGPU_WINDOWS_* pins, each shape-checked: the Dockerfile ARGs are valueless, so a
# stage solved without the driver sees them empty and must refuse, not fetch unpinned.
function Get-OrtWebGpuPin {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source)
    $shape = [ordered]@{
        DAWN_VERSION = '^v\d{8}\.\d{6}$'; DAWN_SHA256 = '^[0-9a-fA-F]{64}$'
        DXC_VERSION = '^v\d+\.\d+\.\d+(\.\d+)?$'; DXC_ASSET = '^dxc_\d{4}_\d{2}_\d{2}\.zip$'; DXC_SHA256 = '^[0-9a-fA-F]{64}$'
    }
    $pin = [ordered]@{}
    foreach ($name in $shape.Keys) {
        $value = "$($Source["ORT_WEBGPU_WINDOWS_$name"])".Trim()
        if ($value -notmatch $shape[$name]) {
            throw "ORT_WEBGPU_WINDOWS_$name is '$value' (want $($shape[$name])): the driver forwards the pins on -Variant rocm (Get-BkRocmStageArg)"
        }
        $pin[$name] = $value
    }
    return [pscustomobject]$pin
}

# ORT's cmake/deps.txt dawn row: it must fetch exactly the pinned tag, and its SHA1 is ORT's own pin.
function Get-OrtDawnDepsEntry {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$DepsLine, [Parameter(Mandatory)][string]$DawnVersion)
    $rows = @($DepsLine | Where-Object { $_ -match '^dawn;' })
    if ($rows.Count -ne 1) { throw "ORT's cmake/deps.txt has $($rows.Count) 'dawn;' rows, expected exactly one" }
    $null, $url, $sha1 = $rows[0].Trim() -split ';'
    $want = "https://github.com/google/dawn/archive/refs/tags/$DawnVersion.zip"
    if ($url -ne $want) { throw "ORT's cmake/deps.txt fetches Dawn from '$url', not '$want': re-derive ORT_WEBGPU_WINDOWS_DAWN_* for this ORT" }
    if ($sha1 -notmatch '^[0-9a-f]{40}$') { throw "ORT's cmake/deps.txt pins Dawn by '$sha1', not a SHA1" }
    return [pscustomobject]@{ Url = $url; Sha1 = $sha1 }
}

# ORT's own Dawn patches in its PATCH_COMMAND order, read from the pinned ORT rather than restated.
function Get-OrtDawnPatchName {
    param([Parameter(Mandatory)][string]$ExternalDepsText)
    $names = @([regex]::Matches($ExternalDepsText, '\$\{PROJECT_SOURCE_DIR\}/patches/dawn/([A-Za-z0-9_.-]+\.patch)') | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -eq 0) { throw 'onnxruntime_external_deps.cmake names no patches/dawn/*.patch: ORT''s Dawn PATCH_COMMAND moved' }
    return $names
}

# The Dawn DEPS entries a D3D12-only, prebuilt-DXC configure reads; Dawn's own fetcher would take 19.
function Get-OrtDawnRequiredDep {
    return @('third_party/jinja2', 'third_party/markupsafe', 'third_party/spirv-headers/src', 'third_party/spirv-tools/src')
}

# DEPS is Python: evaluated exactly as Dawn's tools/fetch_dawn_dependencies.py does, prints {path: url@commit}.
function Get-OrtDawnDepsProbeSource {
    return @'
import json, sys
class Var:
    def __init__(self, name): self.name = name
    def __add__(self, text): return self.name + text
    def __radd__(self, text): return text + self.name
scope = {}
with open(sys.argv[1], encoding="utf-8") as f:
    exec(f.read(), {"Var": Var, "Str": str}, scope)
deps, variables = scope.get("deps") or {}, scope.get("vars") or {}
out = {}
for path in sys.argv[2:]:
    entry = deps.get(path)
    url = entry.get("url") if isinstance(entry, dict) else entry
    out[path] = url.format(**variables) if isinstance(url, str) else ""
print(json.dumps(out))
'@
}

# Dawn DEPS -> {path: url@commit} for $Path: the probe above, fed to the build's Python on stdin.
function Invoke-OrtDawnDepsProbe {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$DepsFile, [Parameter(Mandatory)][string[]]$Path)
    $json = @(Get-OrtDawnDepsProbeSource | & $Python - $DepsFile @Path) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not "$json".StartsWith('{')) { throw "the Dawn DEPS probe exited $LASTEXITCODE without a report: $json" }
    return ConvertFrom-Json -InputObject $json -AsHashtable
}

# $Resolved is the probe's {path: url@commit}; each named path must resolve to an https URL and a full commit.
function ConvertTo-OrtDawnDepPin {
    param([Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Resolved, [Parameter(Mandatory)][string[]]$Path)
    $pins = [ordered]@{}
    foreach ($p in $Path) {
        $spec = if ($null -ne $Resolved) { "$($Resolved[$p])" } else { '' }
        if ($spec -notmatch '^(?<url>https://[^@\s]+)@(?<commit>[0-9a-f]{40})$') { throw "Dawn DEPS pins $p as '$spec', not https-url@40-hex-commit" }
        $pins[$p] = [pscustomobject]@{ Url = $Matches.url; Commit = $Matches.commit }
    }
    return $pins
}

# One DEPS entry, shallow-fetched by commit; the checkout must BE that commit, or the build stops.
function Save-OrtDawnDep {
    param(
        [Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Commit,
        [int]$MaxAttempts = 3, [int]$DelaySeconds = 10
    )
    $git = "git -C ""$Dir"""
    $head = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Reset-SourceBuildDirectory -Path $Dir
        [void](New-Item -ItemType Directory -Force -Path $Dir)
        [void](Invoke-ShieldedNative -Optional -Quiet -Label "fetch $Url" -CommandLine "$git init -q 2>&1 && $git fetch -q --depth 1 ""$Url"" $Commit 2>&1 && $git checkout -q --detach FETCH_HEAD")
        $head = "$(Invoke-ShieldedNative -Optional -Quiet -Label 'rev-parse' -CommandLine "$git rev-parse HEAD" | Select-Object -Last 1)".Trim()
        if ($head -eq $Commit) { Write-Host "  [dawn dep] $Url @ $Commit"; return }
        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Dawn dependency $Url@$Commit is at '$head' after $MaxAttempts attempt(s)"
}

# Zip members to files; $Map turns an entry name ('/'-separated) into a relative path, or $null to skip.
# No member may land outside $Destination.
function Expand-OrtZipMember {
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][scriptblock]$Map)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $written = [System.Collections.Generic.List[string]]::new()
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName -replace '\\', '/'
            if ($name.EndsWith('/')) { continue }
            $rel = & $Map $name
            if (-not $rel) { continue }
            $out = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
            if (-not $out.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "zip member '$name' of $Zip would land outside $Destination" }
            [void](New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($out)))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
            $written.Add($name)
        }
    } finally { $archive.Dispose() }
    return @($written)
}

# The DXC release's x64 pair, the import lib Dawn's target links and the licence texts; all six must exist.
function Expand-OrtWebGpuDxc {
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination)
    $members = [ordered]@{
        'bin/x64/dxcompiler.dll' = 'dxcompiler.dll'; 'bin/x64/dxil.dll' = 'dxil.dll'; 'lib/x64/dxcompiler.lib' = 'dxcompiler.lib'
        'LICENSE-LLVM.txt' = 'licenses\LICENSE-LLVM.txt'; 'LICENSE-MS.txt' = 'licenses\LICENSE-MS.txt'; 'LICENCE-MIT.txt' = 'licenses\LICENCE-MIT.txt'
    }
    $got = @(Expand-OrtZipMember -Zip $Zip -Destination $Destination -Map { param($n) $members[$n] }.GetNewClosure())
    $missing = @($members.Keys | Where-Object { $got -notcontains $_ })
    if ($missing.Count -gt 0) { throw "the DXC zip $Zip lacks $($missing -join ', ')" }
}

# The Dawn archive minus its top directory and test/ (70k files ORT also deletes).
function Expand-OrtDawnArchive {
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination)
    $got = @(Expand-OrtZipMember -Zip $Zip -Destination $Destination -Map {
            param($n)
            $rel = ($n -split '/', 2)[1]
            if ($rel -and $rel -notmatch '^test/') { $rel }
        })
    if (@($got | Where-Object { $_ -match '^[^/]+/CMakeLists\.txt$' }).Count -eq 0) { throw "the Dawn archive $Zip has no top-level CMakeLists.txt" }
}

# Dawn's DXC targets become the pinned release: DXC's WinIncludes.h includes atlbase.h and the image has
# no ATL. DAWN_USE_BUILT_DXC stays ON, so Dawn keeps its DXC path (ShaderF16, subgroups).
function Invoke-DawnPrebuiltDxcPatch {
    param([Parameter(Mandatory)][string]$DawnSrc)
    $cmake = @'
if (DAWN_USE_BUILT_DXC AND DAWN_PREBUILT_DXC_DIR)
    # [ANTfrastructure prebuilt DXC] the pinned release's DLLs stand in for a DXC build.
    message(STATUS "Dawn: prebuilt DXC from ${DAWN_PREBUILT_DXC_DIR}")
    add_library(dxcompiler SHARED IMPORTED GLOBAL)
    set_target_properties(dxcompiler PROPERTIES
        IMPORTED_LOCATION "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.dll"
        IMPORTED_IMPLIB "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.lib")
    add_custom_target(copy_dxil_dll COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${DAWN_PREBUILT_DXC_DIR}/dxil.dll" "${CMAKE_BINARY_DIR}/dxil.dll")
elseif (DAWN_USE_BUILT_DXC)
    AddSubdirectoryDXC()
endif()
'@
    $path = Join-Path $DawnSrc 'third_party\CMakeLists.txt'
    $applied = Invoke-InlineRegexPatch -Path $path -Require -Description 'Dawn: prebuilt DXC targets' `
        -SkipIfMatch 'ANTfrastructure prebuilt DXC' `
        -Pattern '(?m)^if \(DAWN_USE_BUILT_DXC\)\r?\n[ \t]+AddSubdirectoryDXC\(\)\r?\nendif\(\)' `
        -Replacement $cmake.TrimEnd() `
        -AssertGone '(?m)^if \(DAWN_USE_BUILT_DXC\)\r?\n[ \t]+AddSubdirectoryDXC\(\)'
    if (-not $applied) { throw "$path : the 'if (DAWN_USE_BUILT_DXC) AddSubdirectoryDXC() endif()' block moved; re-derive Invoke-DawnPrebuiltDxcPatch" }
}

# ORT applies its Dawn patches with GNU patch, fuzz included (git apply rejects three at v1.30.0).
function Resolve-GnuPatchExe {
    $onPath = Get-Command patch.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $core = "$(& git --exec-path 2>$null)".Trim()
    if ($core) {
        $candidate = Join-Path (Split-Path (Split-Path (Split-Path $core -Parent) -Parent) -Parent) 'usr\bin\patch.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'GNU patch.exe is neither on PATH nor in <git>\usr\bin: ORT''s Dawn patches need it'
}

# Every WebGPU input, each pinned: the Dawn archive (SHA256 + ORT's SHA1), ORT's Dawn patches, four
# DEPS commits and the DXC zip (SHA256). Nothing else is fetched. Returns @{ Pin; DawnSrc; DxcDir }.
function Initialize-OrtWebGpuInput {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SHA1 only matches ORT''s deps.txt; the SHA256 pin verifies')]
    param([Parameter(Mandatory)][string]$OrtSourceDir, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$Python)
    $pin = Get-OrtWebGpuPin -Source ([Environment]::GetEnvironmentVariables())
    $entry = Get-OrtDawnDepsEntry -DepsLine @(Get-Content -LiteralPath (Join-Path $OrtSourceDir 'cmake\deps.txt')) -DawnVersion $pin.DAWN_VERSION
    Reset-SourceBuildDirectory -Path $WorkDir
    [void](New-Item -ItemType Directory -Force -Path $WorkDir)
    $zip = Join-Path $WorkDir 'dawn.zip'
    Invoke-DownloadWithRetry -Url $entry.Url -DestinationPath $zip -ExpectedSha256 $pin.DAWN_SHA256 -ExpectSignature 'PK' -Description "Dawn $($pin.DAWN_VERSION)"
    $sha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($sha1 -ne $entry.Sha1) { throw "Dawn archive SHA1 $sha1 is not ORT's deps.txt $($entry.Sha1), yet its SHA256 matched: re-measure ORT_WEBGPU_WINDOWS_DAWN_SHA256" }
    $dawnSrc = Join-Path $WorkDir 'dawn'
    Expand-OrtDawnArchive -Zip $zip -Destination $dawnSrc
    $patchExe = Resolve-GnuPatchExe
    $depsCmake = [System.IO.File]::ReadAllText((Join-Path $OrtSourceDir 'cmake\external\onnxruntime_external_deps.cmake'))
    foreach ($name in (Get-OrtDawnPatchName -ExternalDepsText $depsCmake)) {
        $patch = Join-Path $OrtSourceDir "cmake\patches\dawn\$name"
        [void](Invoke-ShieldedNative -Label "ORT Dawn patch $name" -CommandLine "cd /d ""$dawnSrc"" && ""$patchExe"" --batch --binary --ignore-whitespace -p1 -i ""$patch""")
    }
    Invoke-DawnPrebuiltDxcPatch -DawnSrc $dawnSrc
    $required = Get-OrtDawnRequiredDep
    $deps = ConvertTo-OrtDawnDepPin -Resolved (Invoke-OrtDawnDepsProbe -Python $Python -DepsFile (Join-Path $dawnSrc 'DEPS') -Path $required) -Path $required
    foreach ($p in $deps.Keys) { Save-OrtDawnDep -Dir (Join-Path $dawnSrc ($p -replace '/', '\')) -Url $deps[$p].Url -Commit $deps[$p].Commit }
    $dxcZip = Join-Path $WorkDir $pin.DXC_ASSET
    Invoke-DownloadWithRetry -Url "https://github.com/microsoft/DirectXShaderCompiler/releases/download/$($pin.DXC_VERSION)/$($pin.DXC_ASSET)" `
        -DestinationPath $dxcZip -ExpectedSha256 $pin.DXC_SHA256 -ExpectSignature 'PK' -Description "DXC $($pin.DXC_VERSION)"
    $dxcDir = Join-Path $WorkDir 'dxc'
    Expand-OrtWebGpuDxc -Zip $dxcZip -Destination $dxcDir
    Remove-Item -LiteralPath $zip, $dxcZip -Force
    return [pscustomobject]@{ Pin = $pin; DawnSrc = $dawnSrc; DxcDir = $dxcDir }
}

# Appended only on the spike: @() leaves every other lane's configure line untouched.
function Get-OrtWebGpuCmakeArgs {
    param([Parameter(Mandatory)]$Plan, [string]$DawnSrc = '', [string]$DxcDir = '')
    if (-not $Plan.WebGpu) { return @() }
    return @('-Donnxruntime_USE_WEBGPU=ON', '-Donnxruntime_ENABLE_DAWN_BACKEND_D3D12=ON', '-Donnxruntime_ENABLE_DAWN_BACKEND_VULKAN=OFF',
        "-Donnxruntime_CUSTOM_DAWN_SRC_PATH=$($DawnSrc -replace '\\', '/')", "-DDAWN_PREBUILT_DXC_DIR:PATH=$($DxcDir -replace '\\', '/')")
}

# After configure: the spike's switches took, the prebuilt-DXC branch ran, and Dawn fetched nothing itself.
function Get-OrtWebGpuConfigureFinding {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CacheText, [Parameter(Mandatory)][AllowEmptyString()][string]$LogText)
    $want = [ordered]@{ onnxruntime_USE_WEBGPU = 'ON'; DAWN_FETCH_DEPENDENCIES = 'OFF'; DAWN_USE_BUILT_DXC = 'ON'; DAWN_ENABLE_D3D12 = 'ON'; DAWN_ENABLE_VULKAN = 'OFF' }
    foreach ($k in $want.Keys) {
        $m = [regex]::Match($CacheText, "(?m)^$k(?::[A-Z]+)?=(.*?)\r?$")
        $got = if ($m.Success) { $m.Groups[1].Value.Trim() } else { '<unset>' }
        if ($got -ne $want[$k]) { "WebGPU EP: CMakeCache has $k=$got, want $($want[$k])" }
    }
    if ($LogText -notmatch 'Dawn: prebuilt DXC from ') { 'WebGPU EP: the configure never took the prebuilt-DXC branch (Dawn would build DXC, which needs ATL)' }
    if ($LogText -match 'Running fetch_dawn_dependencies') { 'WebGPU EP: Dawn ran fetch_dawn_dependencies, a fetch this build does not pin' }
}

# cmake --install skips Dawn's DXC pair: stage it beside onnxruntime.dll with DXC's licences.
# Returns @{ dll = sha256 }. onnxruntime.dll must load DXC at run time, as upstream does.
function Install-OrtWebGpuRuntime {
    param([Parameter(Mandatory)][string]$DxcDir, [Parameter(Mandatory)][string]$OrtInstallDir)
    $bin = Join-Path $OrtInstallDir 'bin'
    $ortDll = Join-Path $bin 'onnxruntime.dll'
    if (-not (Test-Path -LiteralPath $ortDll -PathType Leaf)) { throw "WebGPU EP: $ortDll missing after the install" }
    $linked = @(Get-PeImportNames -Path $ortDll -IncludeDelayLoad | Where-Object { $_ -in @('dxcompiler.dll', 'dxil.dll') })
    if ($linked.Count -gt 0) { throw "onnxruntime.dll imports $($linked -join ', '): Dawn must open DXC at run time, not at load time" }
    $sha = @{}
    foreach ($dll in 'dxcompiler.dll', 'dxil.dll') {
        Copy-Item -LiteralPath (Join-Path $DxcDir $dll) -Destination $bin -Force
        $sha[$dll] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $bin $dll)).Hash.ToLowerInvariant()
    }
    $licences = Join-Path $OrtInstallDir 'licenses\directx-shader-compiler'
    [void](New-Item -ItemType Directory -Force -Path $licences)
    Copy-Item -Path (Join-Path $DxcDir 'licenses\*') -Destination $licences -Force
    return $sha
}

# The installed wheel (native lane): does it list the EP, do its capi DXC bytes equal the staged pair, does it carry DXC's notice?
function Get-OrtWebGpuWheelFinding {
    param([AllowNull()][hashtable]$Report, [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$DllSha256)
    if ($null -eq $Report) { return 'WebGPU EP: the wheel probe printed no report' }
    if ($Report['error']) { return "WebGPU EP: the installed wheel does not import: $($Report['error'])" }
    if (@($Report['providers']) -notcontains 'WebGpuExecutionProvider') { "WebGPU EP: the wheel lists [$(@($Report['providers']) -join ', ')], no WebGpuExecutionProvider" }
    $capi = if ($Report['dlls'] -is [System.Collections.IDictionary]) { $Report['dlls'] } else { @{} }
    foreach ($dll in 'dxcompiler.dll', 'dxil.dll') {
        $want = "$($DllSha256[$dll])"
        if ($want -cnotmatch '^[0-9a-f]{64}$') { "WebGPU EP: the staged $dll hash is '$want', not a SHA256: nothing to hold capi's copy to"; continue }
        if ("$($capi[$dll])" -cne $want) { "WebGPU EP: onnxruntime\capi\$dll is '$($capi[$dll])', the staged $dll is $want" }
    }
    if ($Report['dxc_notice'] -ne $true) { "WebGPU EP: the wheel's ThirdPartyNotices.txt lacks '$(Get-OrtDxcNoticeTitle)'" }
}

# The ThirdPartyNotices.txt entry title for the DXC pair: ORT's own notices cover Dawn/Tint, not DXC.
function Get-OrtDxcNoticeTitle { return 'DirectXShaderCompiler (onnxruntime/capi/dxcompiler.dll, dxil.dll)' }

# Appends DXC's licence texts to the notices file the wheel packs, so a wheel copied out keeps them. Idempotent.
function Add-OrtWebGpuWheelNotice {
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][string]$DxcDir, [Parameter(Mandatory)][string]$DxcVersion)
    $notices = Join-Path $BuildDir 'onnxruntime\ThirdPartyNotices.txt'
    if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) { throw "WebGPU EP: $notices missing: ORT's POST_BUILD copy moved, the wheel would ship DXC without its licence" }
    $title = Get-OrtDxcNoticeTitle
    if ([System.IO.File]::ReadAllText($notices).Contains($title)) { return }
    $texts = @(Get-ChildItem -LiteralPath (Join-Path $DxcDir 'licenses') -File | Sort-Object Name)
    if ($texts.Count -eq 0) { throw "WebGPU EP: no DXC licence texts under $DxcDir\licenses" }
    $body = ($texts | ForEach-Object { "--- $($_.Name) ---`n`n$([System.IO.File]::ReadAllText($_.FullName).TrimEnd())" }) -join "`n`n"
    [System.IO.File]::AppendAllText($notices, "`n_____`n`n$title $DxcVersion`n`nhttps://github.com/microsoft/DirectXShaderCompiler`n`n$body`n")
}

# The installed wheel's own view, one JSON line on stdout: providers, the SHA256 of capi's DXC pair, DXC's notice.
function Get-OrtWebGpuWheelReport {
    param([Parameter(Mandatory)][string]$Python)
    $probe = @'
import hashlib, json, os, sys
try:
    import onnxruntime
    capi = os.path.join(os.path.dirname(onnxruntime.__file__), "capi")
    report = {"providers": onnxruntime.get_available_providers(), "dlls": {}, "dxc_notice": False}
    for name in ("dxcompiler.dll", "dxil.dll"):
        if os.path.isfile(os.path.join(capi, name)):
            with open(os.path.join(capi, name), "rb") as f:
                report["dlls"][name] = hashlib.sha256(f.read()).hexdigest()
    notices = os.path.join(os.path.dirname(capi), "ThirdPartyNotices.txt")
    if os.path.isfile(notices):
        with open(notices, encoding="utf-8", errors="replace") as f:
            report["dxc_notice"] = sys.argv[1] in f.read()
except Exception as exc:
    report = {"error": "%s: %s" % (type(exc).__name__, exc)}
print(json.dumps(report))
'@
    $line = @($probe | & $Python - (Get-OrtDxcNoticeTitle) 2>$null) | Select-Object -Last 1
    if ("$line".StartsWith('{')) { return ConvertFrom-Json -InputObject $line -AsHashtable }
}

# Read by windows\scripts\build\rocm-checks\OrtWebGpu.ps1: what this rocm-lane ORT build shipped.
function Get-OrtWebGpuFeatureMarker {
    param([Parameter(Mandatory)]$Plan, $Pin = $null, [hashtable]$DllSha256 = @{})
    $lines = @('# Written by Build-OnnxFromSource.ps1 on the rocm lane; read by rocm-checks\OrtWebGpu.ps1.'
        "ORT_WEBGPU=$(if ($Plan.WebGpu) { '1' } else { '0' })")
    if ($Plan.WebGpu) {
        $lines += "DAWN_VERSION=$($Pin.DAWN_VERSION)", "DXC_VERSION=$($Pin.DXC_VERSION)",
            "DXCOMPILER_SHA256=$($DllSha256['dxcompiler.dll'])", "DXIL_SHA256=$($DllSha256['dxil.dll'])"
    }
    return $lines
}

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.30.0' -StripVPrefix

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
# image is shared, so an arm64 build would link x64 device libs into an "arm64" artifact.
# #176 (2026-09-20): the POSITIVE cross signal is the image's arm64 payload -- lib\arm64
# staged by Install-Cuda.ps1 -TargetArch arm64 -- so a cross image WITHOUT it stays
# CPU + DirectML and one WITH it builds the CUDA EP for arm64.
$cudaUsable = $gpuEnv.HasCuda -and ((-not $onnxCross) -or (Test-CudaWindowsArm64Payload -CudaRoot $gpuEnv.CudaRoot))
if ($cudaUsable) {
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
    # Classic TensorRT is x64-only (docs/windows-cross-builds.md § CUDA / cuDNN /
    # TensorRT): a zip staged for the amd64 lane must never enable the EP on a cross
    # build -- it would link x64 import libs into the arm64 provider. TensorRT-RTX
    # (which does ship arm64) is not wired.
    $trtRoot = if ($onnxCross) { $null } else { $gpuEnv.TensorRtRoot }
    if ($trtRoot) {
        Write-Host "TensorRT detected at $trtRoot - enabling TensorRT EP"
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=ON'
        $gpuArgs += '-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON'
        $gpuArgs += "-DTENSORRT_ROOT=$trtRoot"
    } else {
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=OFF'
    }
    # nvcc host = MSVC cl.exe (nvcc rejects clang-cl); C++17; /wd4067 is ORT-specific. Shared nvcc block
    # (arch-aware since #176: the cross lane drives the Hostx64\arm64 cl + --use-local-env).
    $gpuArgs += Get-NvccCudaCmakeArgs -CudaRoot $cudaRoot -CudaStandard '17' -ExtraCudaFlags '-Xcompiler=/wd4067'
    $cudnnLibDir = Get-CudnnLibraryDir -CudnnRoot $cudnnRoot
    if (-not $cudnnLibDir) {
        throw "ONNX: cuDNN import lib dir not found under $cudnnRoot (lib\x64 natively, lib\arm64 on the cross lane) -- refusing to configure a CUDA build with no cuDNN."
    }
    $gpuArgs += "-DCUDNN_ROOT=$cudnnRoot", "-DCUDNN_INCLUDE_DIR=$cudnnRoot\include"
    $gpuArgs += "-DCMAKE_LIBRARY_PATH=$cudnnLibDir", "-DCUDNN_LIBRARY=$cudnnLib"
    $gpuArgs += "-Donnxruntime_CUDNN_HOME=$cudnnRoot", "-Donnxruntime_CUDA_HOME=$cudaRoot"
} elseif ($gpuEnv.HasRocm) {
    # ORT >= 1.23 has no ROCm EP (onnxruntime_USE_ROCM is gone): cpu flags, plus the WebGPU spike below.
    Write-Host 'ROCm layer present: CPU+DML ORT'
} else {
    Write-Host 'No GPU layer detected: CPU-only build'
}

# DirectML EP ON: the vendored DirectMLHelpers headers only compile under clang-cl with the
# out-of-lining patch above (llvm #57700); USE_DML=ON fetches the redist via NuGet.
# Python bindings ON on both lanes (#120 step 2): the HOST interpreter RUNS the build, the
# TARGET python314.lib is what the .pyd LINKS -- Get-TargetBuildPython encodes that split.
$tpy = Get-TargetBuildPython
$pythonArgs = if ($onnxCross -and -not $tpy.Available) {
    Write-Warning "ONNX: python bindings OFF -- no target CPython import lib at $($tpy.Lib) (Build-TargetCpython.ps1 did not run?)"
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
# rocm lane: ORT_WEBGPU=1 adds the WebGPU EP (the driver sends it; cpu/nvidia never see it).
$webgpuPlan = Get-OrtWebGpuPlan -GpuEnv $gpuEnv -Cross $onnxCross -SpikeFlag "$env:ORT_WEBGPU"
$webgpu = $null
if ($webgpuPlan.WebGpu) {
    Switch-BuildPhase '2b. WebGPU EP inputs: Dawn + DXC (rocm spike)'
    $webgpu = Initialize-OrtWebGpuInput -OrtSourceDir $SourceDir -WorkDir $WebGpuWorkDir -Python $py.Exe
    $cmakeArgs += Get-OrtWebGpuCmakeArgs -Plan $webgpuPlan -DawnSrc $webgpu.DawnSrc -DxcDir $webgpu.DxcDir
} elseif ($webgpuPlan.OnLane) {
    Write-Host 'ROCm lane: WebGPU EP spike off (ORT_WEBGPU is not 1)'
}
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
if ($webgpuPlan.WebGpu) {
    $webgpuCfg = @(Get-OrtWebGpuConfigureFinding -CacheText ([System.IO.File]::ReadAllText((Join-Path $buildDir 'CMakeCache.txt'))) -LogText ([System.IO.File]::ReadAllText($ortCfgLog)))
    if ($webgpuCfg.Count -gt 0) { throw "WebGPU EP configure check:`n  $($webgpuCfg -join "`n  ")" }
}
Switch-BuildPhase '4. post-configure _deps patches + ninja-file tags'

# -- Post-configure patches on the fetched _deps trees: inline, NOT .patch files --
# static patches against CMake-fetched deps rot when ORT's dep pointer moves.

# onnx scoped_resource.h: INVALID_HANDLE_VALUE is a reinterpret_cast, not a valid non-type
# template argument under clang; swap the alias for an interface-identical RAII class.
$scopedHandleFix = @'
// [clang-cl compat, ANTfrastructure] INVALID_HANDLE_VALUE ((HANDLE)(LONG_PTR)-1)
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
# silently rot -- hence the tree-walking helpers below. Guarded on the SAME decision as
# the CUDA branch above (native GPU lane, or the cross lane with the arm64 payload).
if ($cudaUsable) {
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
$webgpuDllSha = if ($webgpuPlan.WebGpu) { Install-OrtWebGpuRuntime -DxcDir $webgpu.DxcDir -OrtInstallDir $ortInstallDir } else { @{} }
if ($webgpuPlan.WebGpu) { Add-OrtWebGpuWheelNotice -BuildDir $buildDir -DxcDir $webgpu.DxcDir -DxcVersion $webgpu.Pin.DXC_VERSION }

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
if ($webgpuPlan.WebGpu) {
    $wheelFindings = @(Get-OrtWebGpuWheelFinding -Report (Get-OrtWebGpuWheelReport -Python $py.Exe) -DllSha256 $webgpuDllSha)
    if ($wheelFindings.Count -gt 0) { throw "WebGPU EP wheel check:`n  $($wheelFindings -join "`n  ")" }
}
if ($webgpuPlan.OnLane) {
    $marker = Get-OrtWebGpuFeatureMarker -Plan $webgpuPlan -Pin $(if ($webgpu) { $webgpu.Pin }) -DllSha256 $webgpuDllSha
    [System.IO.File]::WriteAllLines((Join-Path $ortInstallDir 'ROCM-FEATURES.txt'), [string[]]$marker)
}
if ($webgpu) { Remove-SourceBuildTree -Path $WebGpuWorkDir }

Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnx'
Complete-SourceBuild -Banner '=== ONNX Runtime source build completed ===' -SourceDir $SourceDir  # cleanup + banner + exit 0 (see module help)
