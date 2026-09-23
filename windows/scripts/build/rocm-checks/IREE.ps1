#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm image: IREE's hip HAL driver is compiled in and looks for TheRock's amdhip64_7.dll, and the
    rocm target (iree-compile and iree.compiler) links a gfx1201 AMDGPU code object.
.DESCRIPTION
    Writes one finding per gap; nothing means pass. Lists, loads from an empty dir and compiles, so no GPU is needed.
    NOT covered: creating a hip device or running a kernel (needs an RDNA3/4 GPU and AMD's driver).
    Built by Build-IreeFromSource.ps1; docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Every ELF header inside a blob (a vmfb embeds its code objects): offset, class, type, machine, mach.
#>
function Get-ElfHeaderRecord {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $text = [System.Text.Encoding]::Latin1.GetString($Bytes)
    $at = $text.IndexOf("`u{7F}ELF", [System.StringComparison]::Ordinal)
    while ($at -ge 0 -and $at + 52 -le $Bytes.Length) {
        [pscustomobject]@{
            Offset  = $at
            Class   = [int]$Bytes[$at + 4]
            Type    = [int][BitConverter]::ToUInt16($Bytes, $at + 16)
            Machine = [int][BitConverter]::ToUInt16($Bytes, $at + 18)
            # ELF64 e_flags low byte = EF_AMDGPU_MACH.
            Mach    = [int]$Bytes[$at + 48]
        }
        $at = $text.IndexOf("`u{7F}ELF", $at + 4, [System.StringComparison]::Ordinal)
    }
}

<#
.SYNOPSIS
    A finding unless the blob holds a linked (ET_DYN) ELF64 AMDGPU (e_machine 224) object for $Mach.
    gfx1201 is 0x4E, read off IREE 3.11's own gfx1201 output.
#>
function Get-AmdgpuCodeObjectFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$What,
        [int]$Mach = 0x4E
    )
    $amdgpu = @(Get-ElfHeaderRecord -Bytes $Bytes | Where-Object { $_.Machine -eq 224 })
    if ($amdgpu.Count -eq 0) { return "IREE: $What holds no AMDGPU (e_machine 224) code object" }
    $linked = @($amdgpu | Where-Object { $_.Class -eq 2 -and $_.Type -eq 3 -and $_.Mach -eq $Mach })
    if ($linked.Count -eq 0) {
        $seen = ($amdgpu | ForEach-Object { 'class {0} type {1} mach 0x{2:X2}' -f $_.Class, $_.Type, $_.Mach }) -join '; '
        return "IREE: $What has no linked ELF64 code object for mach 0x$('{0:X2}' -f $Mach) (found: $seen)"
    }
}

<#
.SYNOPSIS
    A finding unless --hip_dylib_path=<empty dir> tried exactly <dir>\<name> for each Windows name, in
    order. Without the carried reset patch, names 2 and 3 come out as concatenated paths.
#>
function Get-IreeHipSearchPathFinding {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output, [Parameter(Mandatory)][string]$Dir)
    $tried = [regex]::Matches($Output, '(?m)^\s*Tried: (.*?)\s*$') | ForEach-Object { $_.Groups[1].Value }
    # IREE canonicalizes the joined path: '/' becomes '\' and a run of '\' collapses to one.
    $expected = 'amdhip64_7.dll', 'amdhip64_6.dll', 'amdhip64.dll' | ForEach-Object { "$Dir/$_" -replace '[\\/]+', '\' }
    if ((@($tried) -join '|') -cne ($expected -join '|')) {
        "IREE: iree-run-module --hip_dylib_path=$Dir tried [$(@($tried) -join ', ')], expected [$($expected -join ', ')] -- the explicit-path HIP lookup is broken"
    }
}

function Get-IreeRocmGateMlir {
    return 'func.func @abs(%input : tensor<f32>) -> (tensor<f32>) { %result = math.absf %input : tensor<f32> return %result : tensor<f32> }'
}

<#
.SYNOPSIS
    The python half: the wheels list hip, their runtime extension carries the patched name, and
    iree.compiler writes a rocm vmfb to argv[2]. Prints one JSON report line.
#>
function Get-IreeRocmPythonProbe {
    return @"
import glob, json, os, sys
import iree.runtime as rt
import iree.compiler.tools as tools
report = {"drivers": sorted(rt.query_available_drivers())}
pkg = os.path.dirname(os.path.dirname(os.path.abspath(rt.__file__)))
pyds = glob.glob(os.path.join(pkg, "**", "_runtime*.pyd"), recursive=True)
report["pyds"] = len(pyds)
report["pyd_patched"] = bool(pyds) and all(b"amdhip64_7.dll" in open(p, "rb").read() for p in pyds)
try:
    vmfb = tools.compile_str("$(Get-IreeRocmGateMlir)", target_backends=["rocm"], extra_args=["--iree-rocm-target=" + sys.argv[1]])
    with open(sys.argv[2], "wb") as out:
        out.write(vmfb)
except Exception as err:
    report["compile_error"] = type(err).__name__ + ": " + str(err)[:400]
print(json.dumps(report))
"@
}

<#
.SYNOPSIS
    All IREE rocm findings. $Invoke runs (exe, argv) and returns @{ Exit; Output }; tests inject it.
#>
function Get-IreeRocmFinding {
    param(
        [Parameter(Mandatory)][string]$IreeBin,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][scriptblock]$Invoke,
        [string]$Python = 'python',
        [string]$Arch = 'gfx1201',
        [int]$Mach = 0x4E
    )
    $compile = Join-Path $IreeBin 'iree-compile.exe'
    $run = Join-Path $IreeBin 'iree-run-module.exe'
    $missing = @($compile, $run | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) { return "IREE: $($missing -join ', ') missing (IREE_BIN '$IreeBin')" }

    $list = & $Invoke $run @('--list_drivers')
    if ("$($list.Output)" -notmatch '(?m)^\s*hip:') { 'IREE: iree-run-module --list_drivers does not list the hip HAL driver' }
    if (-not [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($run)).Contains('amdhip64_7.dll')) {
        'IREE: iree-run-module.exe does not look for amdhip64_7.dll -- the hip driver would find no HIP runtime on Windows'
    }
    # Every load fails in an empty dir, so the error lists each candidate path. The path flag goes first:
    # --list_devices runs while the flags are still being parsed.
    $noHip = Join-Path $ScratchDir 'no-hip-runtime'
    [void](New-Item -ItemType Directory -Force -Path $noHip)
    $search = & $Invoke $run @("--hip_dylib_path=$noHip", '--list_devices=hip')
    Get-IreeHipSearchPathFinding -Output "$($search.Output)" -Dir $noHip

    $mlir = Join-Path $ScratchDir 'abs.mlir'
    [System.IO.File]::WriteAllText($mlir, (Get-IreeRocmGateMlir))
    $vmfb = Join-Path $ScratchDir 'abs-hip.vmfb'
    $built = & $Invoke $compile @('--iree-hal-target-device=hip', "--iree-rocm-target=$Arch", $mlir, '-o', $vmfb)
    if ($built.Exit -ne 0 -or -not (Test-Path -LiteralPath $vmfb -PathType Leaf)) {
        "IREE: iree-compile --iree-hal-target-device=hip --iree-rocm-target=$Arch failed (exit $($built.Exit))"
    } else {
        Get-AmdgpuCodeObjectFinding -Bytes ([System.IO.File]::ReadAllBytes($vmfb)) -What "the iree-compile $Arch vmfb" -Mach $Mach
    }

    $root = Split-Path $IreeBin -Parent
    foreach ($bc in 'ocml.bc', 'ockl.bc') {
        $hit = @(Get-ChildItem -LiteralPath $root -Recurse -Filter $bc -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'iree_platform_libs[\\/]rocm[\\/]' })
        if ($hit.Count -eq 0) { "IREE: no iree_platform_libs\rocm\$bc under $root -- the rocm target ships no device library" }
    }

    $probe = Join-Path $ScratchDir 'iree_rocm_probe.py'
    [System.IO.File]::WriteAllText($probe, (Get-IreeRocmPythonProbe))
    $pyVmfb = Join-Path $ScratchDir 'abs-hip-py.vmfb'
    $ran = & $Invoke $Python @($probe, $Arch, $pyVmfb)
    $json = @("$($ran.Output)" -split '\r?\n' | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
    if ($ran.Exit -ne 0 -or -not $json) { return "IREE: the python probe exited $($ran.Exit) without a report" }
    $report = $json | ConvertFrom-Json -AsHashtable
    if ('hip' -notin @($report['drivers'])) { "IREE: iree.runtime lists no hip driver ($(@($report['drivers']) -join ', '))" }
    if (-not $report['pyd_patched']) { "IREE: the iree.runtime extension ($($report['pyds']) pyd) does not look for amdhip64_7.dll" }
    if ($report.ContainsKey('compile_error')) { "IREE: iree.compiler rocm compile failed: $($report['compile_error'])" }
    elseif (-not (Test-Path -LiteralPath $pyVmfb -PathType Leaf)) { 'IREE: iree.compiler wrote no rocm vmfb' }
    else { Get-AmdgpuCodeObjectFinding -Bytes ([System.IO.File]::ReadAllBytes($pyVmfb)) -What "the iree.compiler $Arch vmfb" -Mach $Mach }
}

$ireeBin = if ($env:IREE_BIN) { $env:IREE_BIN } else { 'C:\runtime\iree\bin' }
$scratch = [System.IO.Directory]::CreateTempSubdirectory('rocm-check-iree-').FullName
try {
    $invoke = {
        param([string]$Exe, [string[]]$ArgList)
        $out = & $Exe @ArgList 2>&1 | Out-String
        @{ Exit = $LASTEXITCODE; Output = $out }
    }
    Get-IreeRocmFinding -IreeBin $ireeBin -ScratchDir $scratch -Invoke $invoke
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
