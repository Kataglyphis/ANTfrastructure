#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm-lane smoke: LiteRT-LM's GPU backend (WebGPU over Dawn -> D3D12) ships next to litert_lm_main.exe.
.DESCRIPTION
    Writes one finding per defect (none = pass). GPU-free: file presence, a load of each DLL
    in a child pwsh whose search path is only the bin dir + System32 (so TheRock's bin cannot
    stand in), its entry export, and --help naming --backend. NOT covered: a real GPU run.
    Built by Build-LitertLmBazel.ps1; docs/windows-builds.md § ROCm layer.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    DLL -> the export litert_lm_main looks up in it (gpu_registry.cc, sampler_factory.cc, Dawn's DXC loader).
#>
function Get-LiteRtLmGpuExport {
    return [ordered]@{
        'libLiteRtWebGpuAccelerator.dll' = 'LiteRtAcceleratorImpl'
        'libLiteRtTopKWebGpuSampler.dll' = 'LiteRtTopKWebGpuSampler_Create'
        'libwebgpu_dawn.dll'             = 'wgpuCreateInstance'
        'dxcompiler.dll'                 = 'DxcCreateInstance'
        'dxil.dll'                       = 'DxcCreateInstance'
    }
}

<#
.SYNOPSIS
    One finding per required file missing under the LiteRT-LM root.
#>
function Get-LiteRtLmFileFinding {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Dll)
    $required = @('bin\litert_lm_main.exe') + @($Dll | ForEach-Object { "bin\$_" }) +
        @('licenses\directx-shader-compiler\LICENSE-MS.txt')
    foreach ($rel in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) { "missing $rel under $Root" }
    }
}

<#
.SYNOPSIS
    Loads each present DLL in a child pwsh (a crash stays there) and resolves its export; one finding per failure.
#>
function Get-LiteRtLmLoadFinding {
    param([Parameter(Mandatory)][string]$BinDir, [Parameter(Mandatory)][System.Collections.IDictionary]$Export)
    $pwsh = (Get-Process -Id $PID).Path
    foreach ($dll in @($Export.Keys)) {
        if (-not (Test-Path -LiteralPath (Join-Path $BinDir $dll) -PathType Leaf)) { continue }
        $out = & $pwsh -NoProfile -NonInteractive -Command {
            param($Dir, $Name, $Symbol)
            $env:PATH = "$Dir;$env:SystemRoot\System32"
            try {
                $h = [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $Dir $Name))
                $null = [System.Runtime.InteropServices.NativeLibrary]::GetExport($h, $Symbol)
            } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
            exit 0
        } -args $BinDir, $dll, $Export[$dll] 2>&1
        if ($LASTEXITCODE -ne 0) {
            "$dll does not load from $BinDir alone or lacks $($Export[$dll]): $((@($out) -join ' ').Trim())"
        }
    }
}

<#
.SYNOPSIS
    litert_lm_main --help must name --backend (abseil exits 1 on --help; the text is the signal).
#>
function Get-LiteRtLmHelpFinding {
    param([Parameter(Mandatory)][string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return }
    $help = (& $Exe --help 2>&1 | Out-String)
    if ($help -notmatch '--backend\b') { "litert_lm_main --help does not list --backend: $($help.Substring(0, [Math]::Min(200, $help.Length)))" }
}

$root = if ($env:LITERT_LM_ROOT) { $env:LITERT_LM_ROOT } else { 'C:\runtime\lib\litert-lm' }
$bin = Join-Path $root 'bin'
$export = Get-LiteRtLmGpuExport
Get-LiteRtLmFileFinding -Root $root -Dll @($export.Keys)
Get-LiteRtLmLoadFinding -BinDir $bin -Export $export
Get-LiteRtLmHelpFinding -Exe (Join-Path $bin 'litert_lm_main.exe')
$global:LASTEXITCODE = 0
