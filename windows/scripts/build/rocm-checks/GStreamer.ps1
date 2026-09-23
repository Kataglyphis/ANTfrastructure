#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm-image check for GStreamer's AMD paths (hip, amfcodec, d3d11, d3d12); writes one finding per breach.
.DESCRIPTION
    GPU-less and static where it must be: each plugin and its library exist, their import closure resolves
    on PATH/System32, the HIP runtime gsthip opens at HIP_PATH exports what the loader resolves, and every
    plugin whose closure this Server Core image can satisfy loads in gst-inspect-1.0.
    NOT covered: element registration (hipupload, amfh264enc, ... need an AMD GPU and driver), symbols a
    newer GStreamer adds to its HIP loader, and loading hip/amfcodec when their GL/Vulkan closure needs a
    host DLL Server Core lacks. docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Export names of a PE file; throws on a non-PE (PEHeaders maps RVAs, the name table is read raw).
function Get-GstPeExportName {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $headers = [System.Reflection.PortableExecutable.PEHeaders]::new([System.IO.MemoryStream]::new($bytes))
    $toFile = {
        param([int]$Rva)
        $i = $headers.GetContainingSectionIndex($Rva)
        if ($i -lt 0) { throw "Get-GstPeExportName: RVA 0x$($Rva.ToString('X')) of $Path lies in no section" }
        $s = $headers.SectionHeaders[$i]
        return $s.PointerToRawData + $Rva - $s.VirtualAddress
    }
    $dir = $headers.PEHeader.ExportTableDirectory
    if ($dir.Size -eq 0) { return @() }
    $table = & $toFile $dir.RelativeVirtualAddress
    $nameTable = & $toFile ([BitConverter]::ToInt32($bytes, $table + 32))
    return @(for ($i = 0; $i -lt [BitConverter]::ToInt32($bytes, $table + 24); $i++) {
            $at = & $toFile ([BitConverter]::ToInt32($bytes, $nameTable + 4 * $i))
            [System.Text.Encoding]::ASCII.GetString($bytes, $at, [Array]::IndexOf($bytes, [byte]0, $at) - $at)
        })
}

# Import edges the way LoadLibraryW resolves them: search dirs only, never the DLL's own folder.
# System32 DLLs are not walked (their OneCore deps are loader-tolerated noise on Server Core).
function Get-GstDllClosure {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$SearchDir
    )
    $known = @{}
    $work = [System.Collections.Generic.List[string]]::new()
    $work.Add($Path)
    for ($i = 0; $i -lt $work.Count; $i++) {
        foreach ($name in @(Get-PeImportNames -Path $work[$i] -IncludeDelayLoad)) {
            if ($name -like 'api-ms-*' -or $name -like 'ext-ms-*' -or $known.ContainsKey($name)) { continue }
            $known[$name] = $true
            $hit = $null
            foreach ($d in $SearchDir) {
                if ([System.IO.File]::Exists([System.IO.Path]::Combine($d, $name))) { $hit = [System.IO.Path]::Combine($d, $name); break }
            }
            [pscustomobject]@{ From = [System.IO.Path]::GetFileName($work[$i]); Name = $name; Path = $hit }
            if ($hit -and $hit -notmatch '\\(System32|SysWOW64|WinSxS)\\') { $work.Add($hit) }
        }
    }
}

# gsthiprtc.cpp opens hiprtc%02d%02d.dll from the runtime's major/minor; .hipVersion carries the same pair.
function Get-GstHiprtcDllName {
    param([Parameter(Mandatory)][string]$HipVersionFile)
    $ver = @{}
    Select-String -LiteralPath $HipVersionFile -Pattern '^HIP_VERSION_(MAJOR|MINOR)=(\d+)\s*$' |
        ForEach-Object { $ver[$_.Matches[0].Groups[1].Value] = [int]$_.Matches[0].Groups[2].Value }
    if ($ver.Count -lt 2) { return $null }
    return 'hiprtc{0:D2}{1:D2}.dll' -f $ver['MAJOR'], $ver['MINOR']
}

# The HIP runtime gsthip dlopens: gsthiploader.cpp takes the first HIP_PATH\bin\amdhip64_*.dll.
# Symbol lists = its LOAD_SYMBOL calls (and gsthiprtc.cpp's) at the pinned GStreamer, GL pair included.
function Get-GstHipRuntimeFinding {
    param(
        [Parameter(Mandatory)][string]$HipRoot,
        [Parameter(Mandatory)][string[]]$SearchDir,
        [string[]]$HipSymbol = @('hipInit', 'hipDriverGetVersion', 'hipRuntimeGetVersion', 'hipGetErrorName',
            'hipGetErrorString', 'hipGetDeviceCount', 'hipGetDeviceProperties', 'hipDeviceGetAttribute', 'hipSetDevice',
            'hipMalloc', 'hipFree', 'hipHostMalloc', 'hipHostFree', 'hipStreamCreate', 'hipStreamDestroy',
            'hipStreamSynchronize', 'hipEventCreateWithFlags', 'hipEventRecord', 'hipEventDestroy', 'hipEventSynchronize',
            'hipEventQuery', 'hipModuleLoadData', 'hipModuleUnload', 'hipModuleGetFunction', 'hipModuleLaunchKernel',
            'hipMemcpyParam2DAsync', 'hipMemsetD8Async', 'hipMemsetD16Async', 'hipMemsetD32Async', 'hipTexObjectCreate',
            'hipTexObjectDestroy', 'hipGraphicsMapResources', 'hipGraphicsResourceGetMappedPointer',
            'hipGraphicsUnmapResources', 'hipGraphicsUnregisterResource', 'hipGLGetDevices', 'hipGraphicsGLRegisterBuffer'),
        [string[]]$RtcSymbol = @('hiprtcCreateProgram', 'hiprtcCompileProgram', 'hiprtcGetProgramLog',
            'hiprtcGetProgramLogSize', 'hiprtcGetCodeSize', 'hiprtcGetCode', 'hiprtcDestroyProgram')
    )
    $bin = Join-Path $HipRoot 'bin'
    $hip = @(Get-ChildItem -LiteralPath $bin -Filter 'amdhip64_*.dll' -File -ErrorAction SilentlyContinue | Sort-Object Name) |
        Select-Object -First 1
    if (-not $hip) { return "no amdhip64_*.dll in ${bin}: gsthip's loader finds no HIP runtime" }
    $rtcName = if (Test-Path -LiteralPath (Join-Path $bin '.hipVersion')) { Get-GstHiprtcDllName -HipVersionFile (Join-Path $bin '.hipVersion') }
    if (-not $rtcName) { return "$bin\.hipVersion is missing or has no HIP_VERSION_MAJOR/MINOR: the hiprtc name gsthip derives is unknown" }
    $libs = @(@{ Path = $hip.FullName; Want = $HipSymbol }, @{ Path = (Join-Path $bin $rtcName); Want = $RtcSymbol })
    foreach ($lib in $libs) {
        if (-not (Test-Path -LiteralPath $lib.Path -PathType Leaf)) { "$($lib.Path) is missing: gsthip cannot open it"; continue }
        $exported = @(Get-GstPeExportName -Path $lib.Path)
        $missing = @($lib.Want | Where-Object { $exported -notcontains $_ })
        if ($missing) { "$(Split-Path $lib.Path -Leaf) does not export $($missing -join ', '): gsthip's loader gives up on it" }
        foreach ($edge in @(Get-GstDllClosure -Path $lib.Path -SearchDir $SearchDir | Where-Object { -not $_.Path })) {
            "$($edge.From) -> $($edge.Name) resolves nowhere on PATH/System32, so $(Split-Path $lib.Path -Leaf) cannot load"
        }
    }
    $builtins = $rtcName -replace '^hiprtc', 'hiprtc-builtins'
    if (-not @($SearchDir | Where-Object { Test-Path -LiteralPath (Join-Path $_ $builtins) -PathType Leaf })) {
        "$builtins is not on PATH/System32: hiprtc cannot compile the converter kernels"
    }
}

# Exit code and stdout of gst-inspect-1.0 <plugin>; ExitCode is $null on a hang (the tree is killed).
# stderr stays on the console: it is the diagnostic when a plugin fails to load.
function Invoke-GstInspectProbe {
    param(
        [Parameter(Mandatory)][string]$GstInspect,
        [Parameter(Mandatory)][string]$Plugin,
        [int]$TimeoutSec = 300
    )
    $info = [System.Diagnostics.ProcessStartInfo]@{ FileName = $GstInspect; UseShellExecute = $false; RedirectStandardOutput = $true }
    $info.ArgumentList.Add($Plugin)
    $child = [System.Diagnostics.Process]@{ StartInfo = $info }
    [void]$child.Start()
    $text = $child.StandardOutput.ReadToEndAsync()
    try {
        $exited = $child.WaitForExit([TimeSpan]::FromSeconds($TimeoutSec))
        if ($exited) { $child.WaitForExit() } else { $child.Kill($true); [void]$child.WaitForExit(10000) }
        return [pscustomobject]@{ ExitCode = $(if ($exited) { $child.ExitCode }); Output = $(if ($exited) { $text.Result } else { '' }) }
    } finally { $child.Dispose() }
}

# One plugin: file present, closure resolves (host-provided GL/Vulkan aside), no static vendor-runtime link,
# and a load probe unless the closure needs a host DLL this image does not carry.
function Get-GstPluginFinding {
    param(
        [Parameter(Mandatory)][string]$Plugin,
        [Parameter(Mandatory)][string]$Dll,
        [Parameter(Mandatory)][string[]]$SearchDir,
        [string]$Forbid = '',
        [string]$GstInspect = '',
        [string]$HostProvided = '^(opengl32|vulkan-1)\.dll$'
    )
    if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) { return "$Plugin plugin was not built: $Dll is missing" }
    $edges = @(Get-GstDllClosure -Path $Dll -SearchDir $SearchDir)
    $absent = @($edges | Where-Object { -not $_.Path })
    foreach ($edge in @($absent | Where-Object { $_.Name -notmatch $HostProvided })) {
        "$Plugin plugin: $($edge.From) -> $($edge.Name) resolves nowhere on PATH/System32"
    }
    if ($Forbid) {
        foreach ($edge in @($edges | Where-Object { $_.Name -match $Forbid })) {
            "$Plugin plugin: $($edge.From) links $($edge.Name) statically; it must stay a runtime dlopen"
        }
    }
    $hostOnly = @($absent | Where-Object { $_.Name -match $HostProvided } | ForEach-Object Name | Select-Object -Unique)
    if ($hostOnly) {
        Write-Host "  [SKIP] $Plugin load probe: needs $($hostOnly -join ', '), which Server Core does not ship (bare-host only)"
        return
    }
    if (-not $GstInspect) { return }
    $probe = Invoke-GstInspectProbe -GstInspect $GstInspect -Plugin $Plugin
    if ($null -eq $probe.ExitCode) { return "$Plugin plugin: gst-inspect-1.0 $Plugin hung past its timeout" }
    if ($probe.ExitCode -ne 0) { return "$Plugin plugin: gst-inspect-1.0 $Plugin exited $($probe.ExitCode), the plugin did not load" }
    $features = [regex]::Match($probe.Output, '(\d+) features?').Groups[1].Value
    Write-Host "  [PASS] $Plugin loads ($(if ($features) { "$features feature(s)" } else { 'feature count not printed' }); elements need a GPU)"
}

$archModule = @((Join-Path $PSScriptRoot '..\..\modules\WindowsTargetArch.Common.psm1'),
    (Join-Path $PSScriptRoot '..\modules\WindowsTargetArch.Common.psm1')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $archModule) { return "WindowsTargetArch.Common.psm1 not found beside $PSScriptRoot, so no import closure could be walked" }
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $archModule }

$searchDir = @(@("$env:SystemRoot\System32") + @($env:PATH -split ';') | ForEach-Object { "$_".Trim().Trim('"') } |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
$gstBin = if ($env:GSTREAMER_BIN) { $env:GSTREAMER_BIN } else { 'C:\runtime\bin' }
$pluginDir = Join-Path (Split-Path $gstBin -Parent) 'lib\gstreamer-1.0'
$gstInspect = Join-Path $gstBin 'gst-inspect-1.0.exe'
if (-not (Test-Path -LiteralPath $gstInspect -PathType Leaf)) { "gst-inspect-1.0.exe missing at ${gstInspect}: no load probe can run"; $gstInspect = '' }

if ($env:HIP_PATH) { Get-GstHipRuntimeFinding -HipRoot $env:HIP_PATH -SearchDir $searchDir }
else { 'HIP_PATH is not set: gsthip only finds a HIP runtime that happens to sit on PATH' }

$prevRegistry = $env:GST_REGISTRY
$env:GST_REGISTRY = Join-Path ([System.IO.Path]::GetTempPath()) "gst-registry-rocm-check-$PID.bin"
try {
    $plugins = @(
        @{ Plugin = 'd3d11'; Dll = 'gstd3d11.dll'; Forbid = '' }
        @{ Plugin = 'd3d12'; Dll = 'gstd3d12.dll'; Forbid = '' }
        @{ Plugin = 'amfcodec'; Dll = 'gstamfcodec.dll'; Forbid = '^amfrt' }
        @{ Plugin = 'hip'; Dll = 'gsthip.dll'; Forbid = '^(amdhip64|hiprtc)' }
    )
    foreach ($p in $plugins) {
        Get-GstPluginFinding -Plugin $p.Plugin -Dll (Join-Path $pluginDir $p.Dll) -SearchDir $searchDir -Forbid $p.Forbid -GstInspect $gstInspect
    }
} finally {
    Remove-Item -LiteralPath $env:GST_REGISTRY -Force -ErrorAction SilentlyContinue
    $env:GST_REGISTRY = $prevRegistry
}
