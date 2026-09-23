#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm image: the chain ORT carries its in-tree WebGPU EP exactly when the spike ran, in the base python and the app venv.
.DESCRIPTION
    GPU-less: providers, a WebGPU session and a GenAI model that may fail only for want of an adapter, DXC bytes and loads.
    NOT covered: a WebGPU kernel running. Built by Build-OnnxFromSource.ps1; docs/windows-rocm.md § ONNX Runtime WebGPU EP.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The marker's KEY=value lines; $null when the build never wrote it.
function Read-OrtWebGpuMarker {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-StringData)
}

# DXC DLL -> the marker key holding the SHA256 the build staged.
function Get-OrtWebGpuDxcKey {
    return [ordered]@{ 'dxcompiler.dll' = 'DXCOMPILER_SHA256'; 'dxil.dll' = 'DXIL_SHA256' }
}

# The spike mode the run asked for vs the marker, and the DXC pair beside onnxruntime.dll.
function Get-OrtWebGpuMarkerFinding {
    param(
        [AllowNull()][hashtable]$Marker, [Parameter(Mandatory)][string]$MarkerPath,
        [AllowEmptyString()][string]$Expect, [Parameter(Mandatory)][string]$OrtRoot
    )
    if ($null -eq $Marker) { return "OrtWebGpu: $MarkerPath missing: the rocm-lane ORT build writes it, so this ORT never took the rocm path" }
    if ($Expect -notin @('0', '1')) { return "OrtWebGpu: EXPECT_ROCM_SPIKES is '$Expect', not 0 or 1: the WebGPU spike mode cannot be graded" }
    $mode = "$($Marker['ORT_WEBGPU'])"
    if ($mode -ne $Expect) { return "OrtWebGpu: the marker says ORT_WEBGPU=$mode, EXPECT_ROCM_SPIKES=${Expect}: an onnx stage from the other spike mode under the shared tags" }
    $keys = Get-OrtWebGpuDxcKey
    foreach ($dll in $keys.Keys) {
        $path = Join-Path $OrtRoot "bin\$dll"
        if ($mode -eq '0') {
            if (Test-Path -LiteralPath $path) { "OrtWebGpu: $path ships although ORT_WEBGPU=0" }
            continue
        }
        $want = "$($Marker[$keys[$dll]])"
        if ($want -notmatch '^[0-9a-f]{64}$') { "OrtWebGpu: the marker's $($keys[$dll]) is '$want', not a SHA256"; continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "OrtWebGpu: $path missing beside onnxruntime.dll"; continue }
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($got -ne $want) { "OrtWebGpu: $path is $got, the build staged $want" }
    }
    if ($mode -eq '1' -and -not (Test-Path -LiteralPath (Join-Path $OrtRoot 'licenses\directx-shader-compiler\LICENSE-MS.txt'))) {
        "OrtWebGpu: DXC's licence texts are missing under $OrtRoot\licenses\directx-shader-compiler"
    }
}

# A session outcome a GPU-less container may show: WebGPU in use, or ORT's no-adapter error (webgpu_context.cc).
function Test-OrtWebGpuOutcome {
    param([AllowEmptyString()][string]$Outcome)
    return ($Outcome -in @('webgpu', 'created')) -or $Outcome.Contains('Failed to get a WebGPU adapter')
}

# One JSON line. argv[1] == "webgpu" adds the session, GenAI and DXC-load probes. Python's
# InferenceSession falls back to CPU and PRINTS the EP error, so stdout is captured around it.
function Get-OrtWebGpuProbeSource {
    return @'
import contextlib, ctypes, hashlib, io, json, os, re, sys, tempfile
IDENTITY = bytes.fromhex("08083a370a100a017812017922084964656e746974791201675a0f0a0178120a0a08080112040a020801620f0a0179120a0a08080112040a0208014202100d")
sink = io.StringIO()
r = {"python": sys.executable}
try:
    with contextlib.redirect_stderr(sink):
        import onnxruntime as ort
    r["providers"] = ort.get_available_providers()
    r["capi"] = os.path.join(os.path.dirname(os.path.abspath(ort.__file__)), "capi")
except Exception as exc:
    r["error"] = "%s: %s" % (type(exc).__name__, exc)
r["dlls"] = {}
if "providers" in r and sys.argv[1:] == ["webgpu"] and "WebGpuExecutionProvider" in r["providers"]:
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(sink):
            used = ort.InferenceSession(IDENTITY, providers=["WebGpuExecutionProvider"]).get_providers()
        m = re.search(r"(?m)^EP Error (.+?) when using", printed.getvalue(), re.S)
        r["session"] = "webgpu" if "WebGpuExecutionProvider" in used else "fell back to %s: %s" % (used, m.group(1).strip() if m else printed.getvalue()[-400:])
    except Exception as exc:
        r["session"] = "%s: %s" % (type(exc).__name__, exc)
    try:
        with contextlib.redirect_stderr(sink):
            import onnxruntime_genai as og
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.GetModuleHandleW.restype = ctypes.c_void_p
        k32.GetModuleHandleW.argtypes = [ctypes.c_wchar_p]
        k32.GetModuleFileNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
        buf, handle = ctypes.create_unicode_buffer(32768), k32.GetModuleHandleW("onnxruntime.dll")
        r["genai_ort"] = buf.value if handle and k32.GetModuleFileNameW(handle, buf, 32768) else ""
        model_dir = tempfile.mkdtemp()
        with open(os.path.join(model_dir, "model.onnx"), "wb") as f:
            f.write(IDENTITY)
        with open(os.path.join(model_dir, "genai_config.json"), "w") as f:
            json.dump({"model": {"type": "llama", "context_length": 8, "decoder": {"filename": "model.onnx",
                       "session_options": {"provider_options": [{"webgpu": {}}]}}}}, f)
        try:
            with contextlib.redirect_stderr(sink):
                og.Model(og.Config(model_dir))
            r["genai_session"] = "created"
        except Exception as exc:
            r["genai_session"] = "%s: %s" % (type(exc).__name__, exc)
    except Exception as exc:
        r["genai_error"] = "%s: %s" % (type(exc).__name__, exc)
if "capi" in r:
    for name in ("dxil.dll", "dxcompiler.dll"):
        path = os.path.join(r["capi"], name)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            try:
                entry = hasattr(ctypes.WinDLL(path), "DxcCreateInstance")
            except OSError:
                entry = False
            r["dlls"][name] = {"sha256": digest, "entry": entry}
r["stderr"] = sink.getvalue()[-1500:]
print(json.dumps(r))
'@
}

# Runs the probe on one interpreter (source on stdin): the report as a hashtable, or the failure as a string.
function Invoke-OrtWebGpuProbe {
    param([Parameter(Mandatory)][string]$Python, [bool]$WebGpu)
    $mode = if ($WebGpu) { 'webgpu' } else { 'plain' }
    $out = @(Get-OrtWebGpuProbeSource | & $Python - $mode 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
    $reports = @($out -match '^\{')
    if ($exit -ne 0 -or $reports.Count -eq 0) { return "probe exit $exit, no JSON line: $(($out | Select-Object -Last 3) -join ' | ')" }
    return ConvertFrom-Json -InputObject $reports[-1] -AsHashtable
}

# One interpreter's report ($Report: hashtable, or the probe's failure string) against the marker.
function Get-OrtWebGpuInterpreterFinding {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][AllowNull()]$Report, [bool]$WebGpu, [hashtable]$Marker = @{})
    $tag = "OrtWebGpu [$Label]"
    if ($Report -isnot [System.Collections.IDictionary]) { return "${tag}: $(if ($Report) { $Report } else { 'no report' })" }
    if ($Report['error']) { return "${tag}: import onnxruntime failed: $($Report['error'])" }
    $listed = @($Report['providers']) -contains 'WebGpuExecutionProvider'
    $dlls = if ($Report['dlls'] -is [System.Collections.IDictionary]) { $Report['dlls'] } else { @{} }
    if (-not $WebGpu) {
        if ($listed) { "${tag}: onnxruntime lists WebGpuExecutionProvider although the marker says ORT_WEBGPU=0" }
        foreach ($dll in @($dlls.Keys | Sort-Object)) { "${tag}: onnxruntime\capi carries $dll without the WebGPU EP" }
        return
    }
    if (-not $listed) { return "${tag}: onnxruntime lists [$(@($Report['providers']) -join ', ')], no WebGpuExecutionProvider" }
    if (-not (Test-OrtWebGpuOutcome "$($Report['session'])")) { "${tag}: a WebGpuExecutionProvider session failed, and not for want of an adapter: $($Report['session'])" }
    $keys = Get-OrtWebGpuDxcKey
    foreach ($dll in $keys.Keys) {
        $d = $dlls[$dll]
        if ($d -isnot [System.Collections.IDictionary]) { "${tag}: onnxruntime\capi has no $dll"; continue }
        if ("$($d['sha256'])" -ne "$($Marker[$keys[$dll]])") { "${tag}: onnxruntime\capi\$dll is $($d['sha256']), the build staged $($Marker[$keys[$dll]])" }
        if ($d['entry'] -ne $true) { "${tag}: onnxruntime\capi\$dll does not load or lacks DxcCreateInstance" }
    }
    if ($Report['genai_error']) { return "${tag}: import onnxruntime_genai failed: $($Report['genai_error'])" }
    $capiOrt = [System.IO.Path]::GetFullPath((Join-Path "$($Report['capi'])" 'onnxruntime.dll'))
    $genaiOrt = if ($Report['genai_ort']) { [System.IO.Path]::GetFullPath("$($Report['genai_ort'])") } else { '' }
    if (-not [string]::Equals($genaiOrt, $capiOrt, [StringComparison]::OrdinalIgnoreCase)) { "${tag}: GenAI runs on '$genaiOrt', not this interpreter's WebGPU ORT '$capiOrt'" }
    if (-not (Test-OrtWebGpuOutcome "$($Report['genai_session'])")) { "${tag}: GenAI's WebGPU model failed, and not for want of an adapter: $($Report['genai_session'])" }
}

# Dot-sourced = definitions only; Test-RocmImage.ps1 runs it with &.
if ($MyInvocation.InvocationName -eq '.') { return }

$ortRoot = if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { 'C:\runtime\lib\onnxruntime-source' }
$markerPath = Join-Path $ortRoot 'ROCM-FEATURES.txt'
$marker = Read-OrtWebGpuMarker -Path $markerPath
$markerFindings = @(Get-OrtWebGpuMarkerFinding -Marker $marker -MarkerPath $markerPath -Expect "$env:EXPECT_ROCM_SPIKES" -OrtRoot $ortRoot)
$markerFindings
# Probe the interpreters only for a gradable mode the image actually carries.
if ($null -eq $marker -or "$env:EXPECT_ROCM_SPIKES" -notin @('0', '1') -or "$($marker['ORT_WEBGPU'])" -ne "$env:EXPECT_ROCM_SPIKES") { return }
$webgpu = "$($marker['ORT_WEBGPU'])" -eq '1'
Write-Host "  ORT WebGPU: ORT_WEBGPU=$($marker['ORT_WEBGPU']) DAWN=$($marker['DAWN_VERSION']) DXC=$($marker['DXC_VERSION'])"
$appDir = if ($env:TORCH_APP_DIR) { $env:TORCH_APP_DIR } else { 'C:\opt\OrchestrANT' }
$base = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$interpreters = [ordered]@{ base = $(if ($base) { $base.Source } else { '' }); venv = (Join-Path $appDir '.venv\Scripts\python.exe') }
foreach ($label in $interpreters.Keys) {
    $python = $interpreters[$label]
    if (-not $python -or -not (Test-Path -LiteralPath $python -PathType Leaf)) { "OrtWebGpu [$label]: no python at '$python'"; continue }
    Get-OrtWebGpuInterpreterFinding -Label $label -Report (Invoke-OrtWebGpuProbe -Python $python -WebGpu $webgpu) -WebGpu $webgpu -Marker $marker
}
