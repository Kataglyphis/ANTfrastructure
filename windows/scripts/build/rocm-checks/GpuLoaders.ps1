#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm-image check for the sdk layer's GPU API loaders (Vulkan, OpenCL); writes one finding per gap.
.DESCRIPTION
    GPU-less: System32 holds the pinned Vulkan loader, and TheRock's registered ICD makes OpenCL list AMD's platform.
    Zero devices is the expected answer. See docs/windows-rocm.md § The ROCm layer.
#>

Set-StrictMode -Version Latest

$nativeRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
Import-Module (Join-Path $nativeRoot 'modules\WindowsNative.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $nativeRoot 'modules\WindowsContainerImage.Common.psm1') -ErrorAction Stop

$ErrorActionPreference = 'Stop'

# The Khronos loader LoadLibrary's each value NAME whose data is REG_DWORD 0 (icd_windows.c).
function Get-OpenClIcdRegistryFinding {
    param(
        [AllowEmptyCollection()][object[]]$Entry = @(),
        [Parameter(Mandatory)][string]$IcdPath
    )
    $mine = @($Entry | Where-Object { [string]::Equals($_.Name, $IcdPath, [StringComparison]::OrdinalIgnoreCase) })
    if ($mine.Count -eq 0) {
        return "OpenCL: HKLM\SOFTWARE\Khronos\OpenCL\Vendors has no value named $IcdPath, so the Khronos loader never loads TheRock's ICD"
    }
    if ($mine[0].Kind -ne 'DWord' -or "$($mine[0].Value)" -ne '0') {
        "OpenCL: the Vendors value $IcdPath is $($mine[0].Kind) '$($mine[0].Value)'; the loader skips anything but REG_DWORD 0"
    }
    if (-not [System.IO.File]::Exists($IcdPath)) { "OpenCL: the registered ICD $IcdPath does not exist" }
}

# VK_HEADER_VERSION of the SDK the image links against; 0 when the header is not there.
function Get-VulkanSdkHeaderVersion {
    param([AllowEmptyString()][string]$SdkRoot = '')
    $header = if ($SdkRoot) { [System.IO.Path]::Combine($SdkRoot, 'Include', 'vulkan', 'vulkan_core.h') } else { '' }
    if (-not $header -or -not [System.IO.File]::Exists($header)) { return 0 }
    $hit = Select-String -LiteralPath $header -Pattern '^#define\s+VK_HEADER_VERSION\s+(\d+)\s*$' | Select-Object -First 1
    return $(if ($hit) { [int]$hit.Matches[0].Groups[1].Value } else { 0 })
}

# System32's vulkan-1.dll must be the pinned loader Install-VulkanLoader.ps1 verified, byte for byte.
function Get-VulkanLoaderCopyFinding {
    param(
        [Parameter(Mandatory)][string]$SystemCopy,
        [Parameter(Mandatory)][string]$PinnedCopy
    )
    if (-not [System.IO.File]::Exists($PinnedCopy)) { return "Vulkan: the verified loader $PinnedCopy is missing, so System32's copy cannot be traced to the pin" }
    if (-not [System.IO.File]::Exists($SystemCopy)) { return "Vulkan: $SystemCopy is missing; FFmpeg's dlopen and Python's DLL search find no loader on PATH" }
    if ((Get-FileHash -LiteralPath $SystemCopy).Hash -ne (Get-FileHash -LiteralPath $PinnedCopy).Hash) {
        "Vulkan: $SystemCopy differs from the pinned $PinnedCopy; something replaced the image's loader"
    }
}

function Get-GpuLoaderFirstRecord {
    param([hashtable]$Records, [string]$Kind)
    if ($Records.ContainsKey($Kind)) { return , $Records[$Kind][0] }
}

function Get-GpuLoaderRecordStatus {
    param([hashtable]$Records, [string]$Kind)
    if ($Records.ContainsKey("$Kind-load")) {
        return [pscustomobject]@{ State = 'LoadFailure'; Record = (Get-GpuLoaderFirstRecord -Records $Records -Kind "$Kind-load") }
    }
    $record = Get-GpuLoaderFirstRecord -Records $Records -Kind $Kind
    if (-not $record) { return [pscustomobject]@{ State = 'Missing'; Record = $null } }
    return [pscustomobject]@{ State = 'Loaded'; Record = $record }
}

function Get-GpuLoaderFailureFinding {
    param([object]$Status, [string]$Kind, [string]$IcdPath)
    if ($Status.State -eq 'Loaded') { return }
    if ($Kind -eq 'vulkan') {
        if ($Status.State -eq 'Missing') { return 'Vulkan: the probe reported nothing about vulkan-1.dll' }
        return "Vulkan: vulkan-1.dll does not load through the standard DLL search (Win32 $($Status.Record[1]); 126 = found nowhere)"
    }
    if ($Kind -eq 'opencl') {
        if ($Status.State -eq 'Missing') { return 'OpenCL: the probe reported nothing about OpenCL.dll' }
        return "OpenCL: no OpenCL.dll loads through the standard DLL search (Win32 $($Status.Record[1])): TheRock's bin is not on PATH"
    }
    if ($Status.State -eq 'Missing') { return "OpenCL: the probe reported nothing about $IcdPath" }
    return "OpenCL: $IcdPath does not load (Win32 $($Status.Record[1]))"
}

function Get-OpenClPlatformFinding {
    param([hashtable]$Records, [object[]]$LoaderRecord, [string]$IcdPath, [string]$PlatformPattern)
    $names = @(if ($Records.ContainsKey('platform')) { $Records['platform'] | ForEach-Object { $_[1] } })
    if (-not @($names | Where-Object { $_ -match $PlatformPattern })) {
        "OpenCL: clGetPlatformIDs through $($LoaderRecord[1]) lists no AMD platform ($(if ($names) { $names -join ', ' } else { 'none' })), so the loader did not load $IcdPath"
    }
}

function Get-GpuLoaderRecordFinding {
    param([hashtable]$Records, [string]$Kind, [string]$LoaderPath, [string]$IcdPath,
        [int]$SdkHeaderVersion, [string]$PlatformPattern)
    $status = Get-GpuLoaderRecordStatus -Records $Records -Kind $Kind
    if ($status.State -ne 'Loaded') { return Get-GpuLoaderFailureFinding -Status $status -Kind $Kind -IcdPath $IcdPath }
    $record = $status.Record
    switch ($Kind) {
        'vulkan' {
            if (-not [string]::Equals($record[1], $LoaderPath, [StringComparison]::OrdinalIgnoreCase)) {
                "Vulkan: vulkan-1.dll resolves to $($record[1]), not $LoaderPath (a copy shadows it, or System32 has none)"
            }
            if ($record[2] -ne 'True' -or $record[3] -ne 'True') { "Vulkan: $($record[1]) does not export vkGetInstanceProcAddr and vkEnumerateInstanceVersion" }
            elseif ($record[4] -ne '0') { "Vulkan: vkEnumerateInstanceVersion returned $($record[4])" }
            elseif ($SdkHeaderVersion -gt 0 -and [int]$record[7] -lt $SdkHeaderVersion) {
                "Vulkan: the loader is $($record[5]).$($record[6]).$($record[7]), older than the SDK headers ($SdkHeaderVersion) the image links against"
            }
        }
        'opencl' {
            if ($record[2] -eq 'nosym') { "OpenCL: $($record[1]) exports no clGetPlatformIDs" }
            elseif ($record[2] -notin @('0', '-1001')) { "OpenCL: clGetPlatformIDs through $($record[1]) returned $($record[2])" }
            else { Get-OpenClPlatformFinding -Records $Records -LoaderRecord $record -IcdPath $IcdPath -PlatformPattern $PlatformPattern }
        }
        'icd' {
            if ($record[2] -ne 'True' -or $record[3] -ne 'True') {
                "OpenCL: $IcdPath does not export clIcdGetPlatformIDsKHR and clGetExtensionFunctionAddress, which the Khronos loader requires"
            }
        }
    }
}

# $Line holds the child probe's 'kind|field|...' records; GpuLoaderProbe.Run below defines each kind's fields.
function Get-GpuLoaderProbeFinding {
    param(
        [AllowNull()]$ExitCode,
        [AllowEmptyCollection()][string[]]$Line = @(),
        [Parameter(Mandatory)][string]$LoaderPath,
        [Parameter(Mandatory)][string]$IcdPath,
        [int]$SdkHeaderVersion = 0,
        [string]$PlatformPattern = '^AMD\b'
    )
    if ($null -eq $ExitCode) { return 'GPU loaders: the probe hung past its timeout (vulkan-1.dll or amdocl64.dll blocks on load)' }
    if ($ExitCode -ne 0) { return "GPU loaders: the probe exited $ExitCode, so a loader or the ICD crashed on load: $(@($Line | Select-Object -Last 2) -join ' | ')" }
    $rec = @{}
    foreach ($l in $Line) {
        $f = $l.Split('|')
        if (-not $rec.ContainsKey($f[0])) { $rec[$f[0]] = [System.Collections.Generic.List[object]]::new() }
        $rec[$f[0]].Add($f)
    }
    Get-GpuLoaderRecordFinding -Records $rec -Kind 'vulkan' -LoaderPath $LoaderPath -IcdPath $IcdPath -SdkHeaderVersion $SdkHeaderVersion
    Get-GpuLoaderRecordFinding -Records $rec -Kind 'opencl' -IcdPath $IcdPath -PlatformPattern $PlatformPattern
    Get-GpuLoaderRecordFinding -Records $rec -Kind 'icd' -IcdPath $IcdPath
}

$script:GpuLoaderProbeSource = @'
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class GpuLoaderProbe {
  [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryExW(string p, IntPtr f, uint flags);
  [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string n);
  [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern uint GetModuleFileNameW(IntPtr h, StringBuilder b, uint n);
  delegate int EnumVersion(out uint v);
  delegate int PlatformIds(uint n, IntPtr[] p, out uint count);
  delegate int PlatformInfo(IntPtr p, uint name, UIntPtr size, byte[] value, out UIntPtr ret);
  delegate int DeviceIds(IntPtr p, ulong type, uint n, IntPtr[] d, out uint count);
  static string Where(IntPtr h) { var b = new StringBuilder(32768); GetModuleFileNameW(h, b, 32768); return b.ToString(); }
  static T Fn<T>(IntPtr h, string n) where T : class { IntPtr f = GetProcAddress(h, n); return f == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer<T>(f); }
  static IntPtr Load(List<string> o, string kind, string dll, uint flags) {
    IntPtr h = LoadLibraryExW(dll, IntPtr.Zero, flags);
    if (h == IntPtr.Zero) o.Add(kind + "-load|" + Marshal.GetLastWin32Error());
    return h;
  }
  public static List<string> Run(string icd) {
    var o = new List<string>();
    IntPtr vk = Load(o, "vulkan", "vulkan-1.dll", 0);
    if (vk != IntPtr.Zero) {
      var ev = Fn<EnumVersion>(vk, "vkEnumerateInstanceVersion"); uint v = 0; int rc = ev == null ? -1 : ev(out v);
      o.Add(string.Join("|", "vulkan", Where(vk), GetProcAddress(vk, "vkGetInstanceProcAddr") != IntPtr.Zero, ev != null, rc, (v >> 22) & 0x7F, (v >> 12) & 0x3FF, v & 0xFFF));
    }
    IntPtr cl = Load(o, "opencl", "OpenCL.dll", 0);
    if (cl != IntPtr.Zero) {
      var ids = Fn<PlatformIds>(cl, "clGetPlatformIDs"); var info = Fn<PlatformInfo>(cl, "clGetPlatformInfo"); var devs = Fn<DeviceIds>(cl, "clGetDeviceIDs");
      uint n = 0; int rc = ids == null ? 0 : ids(0, null, out n);
      o.Add(string.Join("|", "opencl", Where(cl), ids == null ? "nosym" : rc.ToString(), n));
      if (ids != null && info != null && devs != null && rc == 0 && n > 0) {
        var p = new IntPtr[n]; uint got; ids(n, p, out got);
        foreach (var pl in p) {
          var buf = new byte[1024]; UIntPtr len; uint dc; int drc = devs(pl, 0xFFFFFFFF, 0, null, out dc);
          string name = info(pl, 0x0902, (UIntPtr)1024, buf, out len) == 0 ? Encoding.ASCII.GetString(buf, 0, (int)len.ToUInt32()).TrimEnd('\0') : "?";
          o.Add(string.Join("|", "platform", name.Replace('|', '/'), drc, dc));
        }
      }
    }
    IntPtr h = Load(o, "icd", icd, 8);
    if (h != IntPtr.Zero) o.Add(string.Join("|", "icd", Where(h), GetProcAddress(h, "clIcdGetPlatformIDsKHR") != IntPtr.Zero, GetProcAddress(h, "clGetExtensionFunctionAddress") != IntPtr.Zero));
    return o;
  }
}
"@
[GpuLoaderProbe]::Run($env:GPU_LOADER_PROBE_ICD) | ForEach-Object { $_ }
'@

# The loaders run in a child pwsh: a crash or a stuck driver init must not take the check runner with it.
function Invoke-GpuLoaderProbe {
    param(
        [Parameter(Mandatory)][string]$IcdPath,
        [int]$TimeoutSeconds = 120
    )
    $run = Invoke-PwshProbeProcess -Source $script:GpuLoaderProbeSource `
        -ProcessOptions @{ Environment = @{ GPU_LOADER_PROBE_ICD = $IcdPath }; TimeoutSeconds = $TimeoutSeconds; InheritStandardError = $true; PreserveOutput = $true }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Line = @($run.Text -split '\r?\n' | Where-Object { $_ }) }
}

if (-not $env:HIP_PATH) { return 'GPU loaders: HIP_PATH is not set, so TheRock''s OpenCL ICD cannot be located' }
$icdPath = [System.IO.Path]::Combine($env:HIP_PATH, 'bin', 'amdocl64.dll')
$loaderDir = $env:VULKAN_LOADER_DIR
if (-not $loaderDir) { 'Vulkan: VULKAN_LOADER_DIR is not set (an sdk layer from before the loader?)'; $loaderDir = 'C:\vulkan-loader' }
$loaderPath = [System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'vulkan-1.dll')
if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($loaderDir, 'VulkanRT-License.txt'))) {
    "Vulkan: $loaderDir\VulkanRT-License.txt is missing; the loader ships without its licence"
}
Get-VulkanLoaderCopyFinding -SystemCopy $loaderPath -PinnedCopy ([System.IO.Path]::Combine($loaderDir, 'vulkan-1.dll'))

Get-OpenClIcdRegistryFinding -Entry @(Get-OpenClIcdRegistryEntry) -IcdPath $icdPath
$probe = Invoke-GpuLoaderProbe -IcdPath $icdPath
foreach ($l in $probe.Line) { Write-Host "  [info] gpu-loader probe: $l" }
Get-GpuLoaderProbeFinding -ExitCode $probe.ExitCode -Line $probe.Line -LoaderPath $loaderPath -IcdPath $icdPath `
    -SdkHeaderVersion (Get-VulkanSdkHeaderVersion -SdkRoot "$env:VULKAN_SDK")
