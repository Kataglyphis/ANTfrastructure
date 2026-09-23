#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm-image check for the sdk layer's GPU API loaders (Vulkan, OpenCL); writes one finding per gap.
.DESCRIPTION
    GPU-less. vulkan-1.dll resolves to System32's copy (FFmpeg and Python search no PATH), equal to the
    pinned one beside its licence in VULKAN_LOADER_DIR, exports vkGetInstanceProcAddr and
    vkEnumerateInstanceVersion, and is not older than the SDK headers. HKLM\SOFTWARE\Khronos\OpenCL\Vendors
    names TheRock's amdocl64.dll as REG_DWORD 0, that DLL loads and exports the ICD entry points, and
    clGetPlatformIDs through OpenCL.dll lists AMD's platform, which AMD's ICD reports even with no GPU.
    Both loaders run in a child with a timeout.
    NOT covered: devices. No GPU and no Vulkan ICD here, so zero devices is the expected answer.
    docs/windows-rocm.md § The ROCm layer.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OpenClIcdRegistryEntry {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64'),
        [string]$SubKey = 'SOFTWARE\Khronos\OpenCL\Vendors'
    )
    $key = $BaseKey.OpenSubKey($SubKey)
    if ($null -eq $key) { return }
    try {
        foreach ($name in $key.GetValueNames()) {
            [pscustomobject]@{ Name = $name; Kind = "$($key.GetValueKind($name))"; Value = $key.GetValue($name) }
        }
    } finally { $key.Dispose() }
}

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

# Lines of the child probe below: 'vulkan|path|gipa|eiv|rc|major|minor|patch', 'opencl|path|rc|count',
# 'platform|name|devrc|devices', 'icd|path|icdGetPlatformIDs|getExtFnAddr', '<kind>-load|win32error'.
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
    $one = { param($k) if ($rec.ContainsKey($k)) { return , $rec[$k][0] } }

    $vk = & $one 'vulkan'
    if ($rec.ContainsKey('vulkan-load')) {
        "Vulkan: vulkan-1.dll does not load through the standard DLL search (Win32 $((& $one 'vulkan-load')[1]); 126 = found nowhere)"
    } elseif (-not $vk) { 'Vulkan: the probe reported nothing about vulkan-1.dll' }
    else {
        if (-not [string]::Equals($vk[1], $LoaderPath, [StringComparison]::OrdinalIgnoreCase)) {
            "Vulkan: vulkan-1.dll resolves to $($vk[1]), not $LoaderPath (a copy shadows it, or System32 has none)"
        }
        if ($vk[2] -ne 'True' -or $vk[3] -ne 'True') { "Vulkan: $($vk[1]) does not export vkGetInstanceProcAddr and vkEnumerateInstanceVersion" }
        elseif ($vk[4] -ne '0') { "Vulkan: vkEnumerateInstanceVersion returned $($vk[4])" }
        elseif ($SdkHeaderVersion -gt 0 -and [int]$vk[7] -lt $SdkHeaderVersion) {
            "Vulkan: the loader is $($vk[5]).$($vk[6]).$($vk[7]), older than the SDK headers ($SdkHeaderVersion) the image links against"
        }
    }

    $cl = & $one 'opencl'
    if ($rec.ContainsKey('opencl-load')) {
        "OpenCL: no OpenCL.dll loads through the standard DLL search (Win32 $((& $one 'opencl-load')[1])): TheRock's bin is not on PATH"
    } elseif (-not $cl) { 'OpenCL: the probe reported nothing about OpenCL.dll' }
    elseif ($cl[2] -eq 'nosym') { "OpenCL: $($cl[1]) exports no clGetPlatformIDs" }
    elseif ($cl[2] -notin @('0', '-1001')) { "OpenCL: clGetPlatformIDs through $($cl[1]) returned $($cl[2])" }
    else {
        $names = @(if ($rec.ContainsKey('platform')) { $rec['platform'] | ForEach-Object { $_[1] } })
        if (-not @($names | Where-Object { $_ -match $PlatformPattern })) {
            "OpenCL: clGetPlatformIDs through $($cl[1]) lists no AMD platform ($(if ($names) { $names -join ', ' } else { 'none' })), so the loader did not load $IcdPath"
        }
    }

    $icd = & $one 'icd'
    if ($rec.ContainsKey('icd-load')) { "OpenCL: $IcdPath does not load (Win32 $((& $one 'icd-load')[1]))" }
    elseif (-not $icd) { "OpenCL: the probe reported nothing about $IcdPath" }
    elseif ($icd[2] -ne 'True' -or $icd[3] -ne 'True') {
        "OpenCL: $IcdPath does not export clIcdGetPlatformIDsKHR and clGetExtensionFunctionAddress, which the Khronos loader requires"
    }
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
    $info = [System.Diagnostics.ProcessStartInfo]@{ FileName = (Get-Process -Id $PID).Path; UseShellExecute = $false; RedirectStandardOutput = $true }
    foreach ($a in '-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:GpuLoaderProbeSource))) {
        $info.ArgumentList.Add($a)
    }
    $info.Environment['GPU_LOADER_PROBE_ICD'] = $IcdPath
    $child = [System.Diagnostics.Process]::Start($info)
    try {
        $text = $child.StandardOutput.ReadToEndAsync()
        if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
            $child.Kill($true)
            return [pscustomobject]@{ ExitCode = $null; Line = @() }
        }
        $child.WaitForExit()
        return [pscustomobject]@{ ExitCode = $child.ExitCode; Line = @($text.Result -split '\r?\n' | Where-Object { $_ }) }
    } finally { $child.Dispose() }
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
