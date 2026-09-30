#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Diagnose why GenieX's Hexagon NPU path fails on a Snapdragon X Windows host.

.DESCRIPTION
    ggml-hexagon needs the dspqueue API from libcdsprpc.dll, which older drivers lack; see docs/geniex-local-ai-setup.md.
    Report-only: run it after a Hexagon NPU driver update, and every symbol must be present.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GeniexNpuDll {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr h, string name);
}
'@

# Symbols the bundled ggml-hexagon backend dlsyms from the CDSP driver.
$Required = @(
    'dspqueue_create',
    'dspqueue_read',
    'dspqueue_write',
    'dspqueue_export',
    'dspqueue_close',
    'dspqueue_read_noblock',
    'fastrpc_mmap',
    'fastrpc_munmap'
)

Write-Host '=== GenieX NPU driver probe ==='
Write-Host ''

# 1. GenieX install
$geniex = Get-ChildItem "$env:LOCALAPPDATA\GenieX CLI" -Filter 'geniex.exe' -ErrorAction SilentlyContinue
if ($geniex) {
    Write-Host ("GenieX CLI     : {0}" -f $geniex.FullName)
    $ver = & $geniex.FullName --version 2>&1 | Select-Object -First 1
    Write-Host ("  version      : {0}" -f $ver)
} else {
    Write-Host 'GenieX CLI     : NOT FOUND (install from qualcomm/GenieX releases)'
}

# 2. NPU / FastRPC PnP devices
Write-Host ''
Write-Host '=== NPU devices ==='
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Hexagon|FastRPC|NPU|CDSP' } |
    Select-Object FriendlyName, Status, Class |
    Format-Table -AutoSize

# 3. The verdict follows the Hexagon device's active copy, not stale DriverStore copies or the FastRPC driver.
$active = $null
try {
    $pnp = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName -match 'Hexagon' } | Select-Object -First 1
    if ($pnp -and $pnp.DriverVersion) {
        # PnP says 30.0.220.3000 where FileVersion says 30.0.0220.3000, so compare as versions.
        $want = [version]$pnp.DriverVersion
        $active = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'libcdsprpc.dll' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $v = [version]$_.VersionInfo.FileVersion
                    $v.Major -eq $want.Major -and $v.Minor -eq $want.Minor -and
                    $v.Build -eq $want.Build -and $v.Revision -eq $want.Revision
                } catch { $false }
            } | Select-Object -First 1
    }
} catch {
    # Swallowed: this only narrows the report, and the probe must never throw on a negative result.
    Write-Debug ("active-driver lookup failed ({0}) -- reporting every driver-store copy instead" -f $_.Exception.Message)
}

Write-Host '=== libcdsprpc.dll copies and dspqueue coverage ==='
$copies = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'libcdsprpc.dll' -ErrorAction SilentlyContinue
if (-not $copies) {
    Write-Host 'No libcdsprpc.dll found in the driver store -- the CDSP driver is not installed.'
    exit 0
}

$allPresent = $true
foreach ($lib in $copies) {
    $h = [GeniexNpuDll]::LoadLibrary($lib.FullName)
    if ($h -eq [IntPtr]::Zero) {
        Write-Host ("{0} : LOAD FAILED" -f $lib.FullName)
        continue
    }
    $present = foreach ($s in $Required) {
        $addr = [GeniexNpuDll]::GetProcAddress($h, $s)
        [pscustomobject]@{ Symbol = $s; Present = ($addr -ne [IntPtr]::Zero) }
    }
    $missing = @($present | Where-Object { -not $_.Present })
    $isActive = ($active -and $lib.FullName -eq $active.FullName)
    if ($isActive) {
        # The verdict depends on the ACTIVE driver, not on stale store copies.
        $allPresent = $allPresent -and ($missing.Count -eq 0)
    }
    Write-Host ("{0}{1}" -f $lib.FullName, $(if ($isActive) { '  [ACTIVE]' } else { '' }))
    Write-Host ("  DriverVer    : {0}" -f $lib.VersionInfo.FileVersion)
    $present | ForEach-Object {
        Write-Host ("  {0,-24} {1}" -f $_.Symbol, $(if ($_.Present) { 'OK' } else { 'MISSING' }))
    }
}

Write-Host ''
if ($allPresent) {
    Write-Host 'VERDICT: active CDSP driver exports the dspqueue API. NPU inference'
    Write-Host '         should work for models that fit HTP memory (~3 GB vmem on'
    Write-Host '         Snapdragon X). Larger models fail at graph compute with'
    Write-Host '         `dspqueue_read failed: 0x00000072` -- that is a memory limit,'
    Write-Host '         not a driver problem.'
} else {
    Write-Host 'VERDICT: active CDSP driver does NOT export the dspqueue API. Update'
    Write-Host '         the Qualcomm Hexagon NPU driver (Lenovo support / Windows'
    Write-Host '         Update optional updates), reboot, and re-run this probe.'
    Write-Host '         Until then --compute gpu is the working path.'
}
exit 0
