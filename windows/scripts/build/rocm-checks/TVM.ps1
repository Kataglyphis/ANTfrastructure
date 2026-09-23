#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm image: TVM's OpenCL runtime sidecar, and on a TVM_ROCM=1 build the ROCm sidecar on HIP plus a
    gfx1201 code object from TVM's own AMDGPU codegen.
.DESCRIPTION
    Writes one finding per gap; nothing means pass. Reads the ROCM-FEATURES.txt marker the rocm-lane
    TVM build writes. Loads sidecars and compiles only, so no GPU is needed. NOT covered: running a
    kernel, and device-library math (the probe kernel calls no ocml function).
    Built by Build-TvmFromSource.ps1; docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The marker's KEY=value lines as a hashtable; $null when the file is absent.
#>
function Read-TvmRocmFeatureMarker {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $features = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([A-Z_]+)=(.*)$') { $features[$Matches[1]] = $Matches[2].Trim() }
    }
    return $features
}

<#
.SYNOPSIS
    Sidecar files and their static imports. $GetImports maps a DLL path to its imported DLL names.
#>
function Get-TvmRocmSidecarFinding {
    param(
        [Parameter(Mandatory)][string]$LibDir,
        [Parameter(Mandatory)][hashtable]$Features,
        [Parameter(Mandatory)][scriptblock]$GetImports
    )
    $opencl = Join-Path $LibDir 'tvm_runtime_opencl.dll'
    if (-not (Test-Path -LiteralPath $opencl -PathType Leaf)) { "TVM: $opencl missing (the rocm lane builds USE_OPENCL=ON)" }
    elseif (@(& $GetImports $opencl) -contains 'OpenCL.dll') {
        'TVM: tvm_runtime_opencl.dll links OpenCL.dll at load time -- USE_OPENCL must be ON (lazy loader), not an SDK path'
    }
    $rocm = Join-Path $LibDir 'tvm_runtime_rocm.dll'
    if ($Features['TVM_ROCM'] -ne '1') {
        if (Test-Path -LiteralPath $rocm) { "TVM: $rocm exists although the marker says TVM_ROCM=$($Features['TVM_ROCM'])" }
        return
    }
    if (-not (Test-Path -LiteralPath $rocm -PathType Leaf)) { return "TVM: $rocm missing although the marker says TVM_ROCM=1" }
    $imports = @(& $GetImports $rocm)
    if ($imports -notcontains 'amdhip64_7.dll') { "TVM: tvm_runtime_rocm.dll does not import amdhip64_7.dll (imports: $($imports -join ', '))" }
    if (@($imports | Where-Object { $_ -match '^hsa' }).Count -gt 0) { 'TVM: tvm_runtime_rocm.dll imports an HSA runtime, which Windows ROCm does not ship' }
}

<#
.SYNOPSIS
    Probe 1: which runtime sidecars `import tvm` loaded, and the LLVM targets tvm_compiler links (null
    without LLVM). argv[1] = a DLL dir standing in for System32.
#>
function Get-TvmRocmRuntimeProbe {
    return @'
import json, os, sys
if os.path.isdir(sys.argv[1]):
    os.add_dll_directory(sys.argv[1])
import tvm
targets = tvm.get_global_func("target.llvm_get_targets", allow_missing=True)
print(json.dumps({"opencl": bool(tvm.runtime.enabled("opencl")), "rocm": bool(tvm.runtime.enabled("rocm")),
                  "llvm_targets": None if targets is None else sorted(str(t) for t in targets())}))
'@
}

<#
.SYNOPSIS
    The marker's own promise: a TVM_ROCM=1 build recorded an LLVM with AMDGPU.
#>
function Get-TvmRocmMarkerFinding {
    param([Parameter(Mandatory)][hashtable]$Features)
    $targets = @("$($Features['LLVM_TARGETS'])" -split ';' | Where-Object { $_ })
    if ($targets.Count -eq 0) { return 'TVM: the marker records no LLVM_TARGETS -- the build did not read back llvm-config --targets-built' }
    if ($Features['TVM_ROCM'] -eq '1' -and $targets -cnotcontains 'AMDGPU') {
        "TVM: the marker says TVM_ROCM=1 but LLVM_TARGETS=$($Features['LLVM_TARGETS']) has no AMDGPU -- the rocm codegen cannot emit hsaco"
    }
}

<#
.SYNOPSIS
    The marker's LLVM_TARGETS against the arches tvm_compiler links (llvm_get_targets, probe 1).
#>
function Get-TvmRocmLlvmTargetFinding {
    param([Parameter(Mandatory)][hashtable]$Report, [Parameter(Mandatory)][hashtable]$Features)
    if (-not $Report.ContainsKey('llvm_targets')) { return 'TVM: the runtime probe did not report llvm_targets' }
    if ($null -eq $Report['llvm_targets']) { return 'TVM: tvm_compiler registers no target.llvm_get_targets -- it was built without LLVM' }
    $linked = @($Report['llvm_targets'])
    $marker = @("$($Features['LLVM_TARGETS'])" -split ';' | Where-Object { $_ })
    # LLVM target -> the Triple::getArchTypeName TVM lists for it; LLVM 23 renamed amdgcn to amdgpu.
    $archOf = [ordered]@{ X86 = 'x86_64'; AArch64 = 'aarch64'; NVPTX = 'nvptx64'; AMDGPU = 'amdgpu|amdgcn' }
    foreach ($target in $archOf.Keys) {
        $inMarker = $marker -ccontains $target
        if ($inMarker -ne (@($linked -cmatch "^($($archOf[$target]))$").Count -gt 0)) {
            "TVM: the marker's LLVM_TARGETS $(if ($inMarker) { 'lists' } else { 'omits' }) $target, but tvm_compiler $(if ($inMarker) { 'has no' } else { 'links the' }) $($archOf[$target]) target (llvm_get_targets: $($linked -join ', '))"
        }
    }
}

function Get-TvmRocmRuntimeFinding {
    param([Parameter(Mandatory)][hashtable]$Report, [Parameter(Mandatory)][hashtable]$Features)
    if (-not $Report['opencl']) { 'TVM: tvm.runtime.enabled("opencl") is False -- the OpenCL sidecar did not load' }
    $wantRocm = $Features['TVM_ROCM'] -eq '1'
    if ([bool]$Report['rocm'] -ne $wantRocm) {
        "TVM: tvm.runtime.enabled(`"rocm`") is $($Report['rocm']) but the marker says TVM_ROCM=$($Features['TVM_ROCM']) (HIP runtime from HIP_PATH\bin)"
    }
}

<#
.SYNOPSIS
    Probe 2: compile a vector add for rocm/argv[1] and report the linked hsaco's ELF header. Runs
    without a HIP DLL dir, so codegen takes TVM's fallback module and never calls the HIP runtime.
#>
function Get-TvmRocmCodegenProbe {
    return @'
import json, sys
import tvm
import tvm_ffi
from tvm.script import ir as I
from tvm.script import tirx as T

report = {}
link = tvm_ffi.get_global_func("tvm_callback_rocm_link")
code = []


def capture(obj):
    out = link(obj)
    code.append(bytes(out))
    return out


tvm_ffi.register_global_func("tvm_callback_rocm_link", capture, override=True)


@I.ir_module(s_tir=True)
class Module:
    @T.prim_func(s_tir=True)
    def main(A: T.Buffer((64,), "float32"), B: T.Buffer((64,), "float32")):
        T.func_attr({"tirx.noalias": True})
        for i_0 in T.thread_binding(2, thread="blockIdx.x"):
            for i_1 in T.thread_binding(32, thread="threadIdx.x"):
                with T.sblock("B"):
                    v_i = T.axis.spatial(64, i_0 * 32 + i_1)
                    T.reads(A[v_i])
                    T.writes(B[v_i])
                    B[v_i] = A[v_i] + 1.0


try:
    tvm.compile(Module, target=tvm.target.Target({"kind": "rocm", "mcpu": sys.argv[1]}))
except Exception as err:
    report["error"] = type(err).__name__ + ": " + str(err)[:400]
h = code[0] if code else b""
report["size"] = len(h)
report["magic"] = h[:4] == b"\x7fELF"
report["elf_class"] = h[4] if len(h) > 4 else -1
report["type"] = int.from_bytes(h[16:18], "little") if len(h) >= 18 else -1
report["machine"] = int.from_bytes(h[18:20], "little") if len(h) >= 20 else -1
report["mach"] = h[48] if len(h) > 48 else -1
print(json.dumps(report))
'@
}

<#
.SYNOPSIS
    A linked ELF64 AMDGPU object (ET_DYN, e_machine 224) for $Mach; gfx1201 is 0x4E.
#>
function Get-TvmRocmCodegenFinding {
    param([Parameter(Mandatory)][hashtable]$Report, [int]$Mach = 0x4E)
    if ($Report.ContainsKey('error')) { return "TVM: rocm compile failed: $($Report['error'])" }
    if ([int]$Report['size'] -le 0) { return 'TVM: rocm compile produced no hsaco (tvm_callback_rocm_link never ran)' }
    $ok = $Report['magic'] -and [int]$Report['elf_class'] -eq 2 -and [int]$Report['type'] -eq 3 -and
        [int]$Report['machine'] -eq 224 -and [int]$Report['mach'] -eq $Mach
    if (-not $ok) {
        'TVM: the hsaco is not a linked ELF64 AMDGPU object for mach 0x{0:X2} (class {1}, type {2}, machine {3}, mach 0x{4:X2})' -f $Mach,
            $Report['elf_class'], $Report['type'], $Report['machine'], [int]$Report['mach']
    }
}

<#
.SYNOPSIS
    The probe's report (its last JSON line) as a hashtable, or a finding naming the probe.
#>
function ConvertFrom-TvmRocmProbeOutput {
    param([Parameter(Mandatory)][string]$Probe, [int]$ExitCode, [AllowEmptyCollection()][string[]]$Lines = @())
    $report = @($Lines | Where-Object { $_.StartsWith('{') })
    if ($ExitCode -eq 0 -and $report.Count -gt 0) { return ($report[-1] | ConvertFrom-Json -AsHashtable) }
    return "TVM: the $Probe probe exited $ExitCode without a report: $(@($Lines | Select-Object -Last 3) -join ' | ')"
}

$tvmRoot = if ($env:TVM_ROOT) { $env:TVM_ROOT } else { 'C:\runtime\lib\tvm' }
$libDir = if ($env:TVM_LIBRARY_PATH) { $env:TVM_LIBRARY_PATH } else { Join-Path $tvmRoot 'lib' }
$marker = Join-Path $tvmRoot 'ROCM-FEATURES.txt'
$features = Read-TvmRocmFeatureMarker -Path $marker
if ($null -eq $features) {
    "TVM: $marker missing -- the rocm-lane TVM build writes it, so this TVM never took the rocm path"
    return
}
Write-Host "  TVM rocm features: TVM_ROCM=$($features['TVM_ROCM']) LLVM_TARGETS=$($features['LLVM_TARGETS'])"
Get-TvmRocmMarkerFinding -Features $features

$modules = @((Join-Path $PSScriptRoot '..\..\modules'), (Join-Path $PSScriptRoot '..\modules')) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'WindowsTargetArch.Common.psm1') } | Select-Object -First 1
if (-not $modules) { 'TVM: WindowsTargetArch.Common.psm1 not found next to the checks'; return }
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module (Join-Path $modules 'WindowsTargetArch.Common.psm1') }
Get-TvmRocmSidecarFinding -LibDir $libDir -Features $features -GetImports { param($p) Get-PeImportNames -Path $p }

$python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { 'TVM: python is not on PATH -- the tvm package cannot be checked'; return }
$probes = [System.IO.Directory]::CreateTempSubdirectory('rocm-check-tvm-').FullName
try {
    # Probe 1 gets TheRock's bin as its DLL dir: no AMD driver puts amdhip64_7.dll in System32 here.
    $hipBin = if ($env:HIP_PATH) { Join-Path $env:HIP_PATH 'bin' } else { '' }
    $runtimePy = Join-Path $probes 'tvm_rocm_runtime.py'
    [System.IO.File]::WriteAllText($runtimePy, (Get-TvmRocmRuntimeProbe))
    $out = @(& $python.Source $runtimePy $hipBin 2>&1 | ForEach-Object { "$_" })
    $runtime = ConvertFrom-TvmRocmProbeOutput -Probe 'runtime' -ExitCode $LASTEXITCODE -Lines $out
    if ($runtime -is [string]) { $runtime } else {
        Get-TvmRocmRuntimeFinding -Report $runtime -Features $features
        Get-TvmRocmLlvmTargetFinding -Report $runtime -Features $features
    }

    if ($features['TVM_ROCM'] -eq '1') {
        $codegenPy = Join-Path $probes 'tvm_rocm_codegen.py'
        [System.IO.File]::WriteAllText($codegenPy, (Get-TvmRocmCodegenProbe))
        $out = @(& $python.Source $codegenPy 'gfx1201' 2>&1 | ForEach-Object { "$_" })
        $codegen = ConvertFrom-TvmRocmProbeOutput -Probe 'codegen' -ExitCode $LASTEXITCODE -Lines $out
        if ($codegen -is [string]) { $codegen } else { Get-TvmRocmCodegenFinding -Report $codegen }
    }
} finally {
    Remove-Item -LiteralPath $probes -Recurse -Force -ErrorAction SilentlyContinue
}
