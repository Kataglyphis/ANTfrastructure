# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Tests whether the host GPU passes through to a process-isolated container, so DirectML runs on hardware, not WARP.
.DESCRIPTION
    Needs process isolation, the exact DirectX device class and a base image whose OS build matches the host's.
    Re-run after an engine, Windows, base-image or driver upgrade; see docs/windows-build-resources.md § GPU acceleration in containers.
.PARAMETER Image
    Image with clang-cl and the Windows SDK; empty = the family Windows CI image composed from versions.env.
.PARAMETER Docker
    Path to docker.exe. Defaults to Stevedore's, then PATH.
#>
param(
    # Empty: a param default runs before the module import that composes the ref.
    [string]$Image = '',
    [string]$Docker = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsContainerImage.Common.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1') -Force -DisableNameChecking
if ([string]::IsNullOrWhiteSpace($Image)) { $Image = Get-CiImageReference -Windows }

# Exactly this DirectX class: docker accepts a wrong GUID variant silently and the container falls back to WARP.
$GpuDeviceClass = 'class/5B45201D-F2F2-4F3B-85BB-30FF1F953599'

if ([string]::IsNullOrWhiteSpace($Docker)) {
    $Docker = Get-PreferredToolPath -CommandName 'docker' -CandidatePaths @($env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe") -Required
}
Write-Host "Using docker: $Docker"
Write-Host "Image:        $Image`n"

# --- 1) host / image / partitionable GPU facts ---
$hostBuild = [System.Environment]::OSVersion.Version
Write-Host "== Host / image / GPU facts =="
Write-Host "  host OS build:  $hostBuild"
$imgOs = & $Docker image inspect $Image --format '{{.OsVersion}}' 2>$null
Write-Host "  image OsVersion: $imgOs"
if ($imgOs -and ($hostBuild.ToString() -split '\.')[2] -ne ($imgOs -split '\.')[2]) {
    Write-Host "  -> BUILD SKEW: host $(($hostBuild.ToString() -split '\.')[2]) vs image $(($imgOs -split '\.')[2]) (GPU injection needs a match)" -ForegroundColor Yellow
}
try {
    $pg = Get-VMHostPartitionableGpu -ErrorAction Stop
    Write-Host "  partitionable GPUs (GPU-PV capable): $(@($pg).Count)"
    foreach ($g in $pg) { Write-Host "     $($g.Name -replace '\s+', '')" }
} catch { Write-Host "  Get-VMHostPartitionableGpu unavailable: $($_.Exception.Message)" }

# --- 2) CONTROL: process isolation with no device ---
Write-Host "`n== CONTROL: --isolation process (no GPU device) =="
$control = & $Docker run --rm --isolation process $Image cmd /c ver 2>&1
$controlOk = ($LASTEXITCODE -eq 0)
Write-Host ("  {0}: {1}" -f ($(if ($controlOk) { 'OK  ' } else { 'FAIL' }), ($control | Select-Object -First 1)))
if (-not $controlOk) {
    Write-Host "  Process isolation itself is broken -- GPU test is moot. Output:" -ForegroundColor Red
    $control | ForEach-Object { Write-Host "    $_" }
    return
}

# --- 3) GPU: process isolation + DirectX GPU device, then DXGI enumeration ---
Write-Host "`n== GPU: --isolation process --device $GpuDeviceClass =="
$probe = @'
$src = @"
#include <dxgi1_6.h>
#include <d3d12.h>
#include <cstdio>
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d12.lib")
int main(){IDXGIFactory6* f=nullptr;if(FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory6),(void**)&f))){printf("DXGI_FAIL\n");return 1;}
IDXGIAdapter1* a=nullptr;int n=0,hw=0;
for(UINT i=0;f->EnumAdapters1(i,&a)!=DXGI_ERROR_NOT_FOUND;++i){DXGI_ADAPTER_DESC1 d;a->GetDesc1(&d);
bool sw=(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)!=0;wprintf(L"  adapter[%u]: %s  VRAM=%lluMB  %s\n",i,d.Description,
(unsigned long long)(d.DedicatedVideoMemory/(1024*1024)),sw?L"(SOFTWARE/WARP)":L"(HARDWARE)");if(!sw)hw++;n++;a->Release();}
f->Release();printf("TOTAL_ADAPTERS=%d HARDWARE_ADAPTERS=%d\n",n,hw);return 0;}
"@
$d='C:\temp\gpuprobe';New-Item -ItemType Directory -Force -Path $d|Out-Null
Set-Content "$d\e.cpp" $src -Encoding ASCII
$vs=Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\Common7\Tools\VsDevCmd.bat' -EA SilentlyContinue|Select -First 1
if(-not $vs){Write-Host 'NO_VSDEVCMD';exit 0}
Set-Content "$d\b.bat" "call `"$($vs.FullName)`" -arch=amd64 -host_arch=amd64 >nul 2>&1 && clang-cl /EHsc `"$d\e.cpp`" /Fe`"$d\e.exe`" /link dxgi.lib d3d12.lib" -Encoding ASCII
& cmd /c "`"$d\b.bat`"" 2>&1 | Out-Null
if(Test-Path "$d\e.exe"){& "$d\e.exe"}else{Write-Host 'PROBE_COMPILE_FAILED'}
'@
$gpuOut = & $Docker run --rm --isolation process --device $GpuDeviceClass $Image `
    pwsh -NoProfile -ExecutionPolicy Bypass -Command $probe 2>&1
$gpuRc = $LASTEXITCODE
$gpuText = ($gpuOut | Out-String)
$gpuOut | ForEach-Object { Write-Host "  $_" }

# --- 4) verdict ---
Write-Host "`n== VERDICT =="
if ($gpuRc -ne 0 -and $gpuText -match 'cannot find the path specified|CreateComputeSystem|does not match the host') {
    Write-Host "  BLOCKED: GPU device assignment failed at CreateComputeSystem." -ForegroundColor Yellow
    Write-Host "  Cause: base-image build ($imgOs) != host build ($hostBuild). GPU driver-store"
    Write-Host "  injection requires a matching base image. Rebuild base on a servercore/nanoserver"
    Write-Host "  tag whose build == the host, OR run the image on a host whose build == $imgOs."
    Write-Host "  DirectML on the host GPU still works OUTSIDE containers (run ORT/GenAI on the bare host)."
} elseif ($gpuText -match 'HARDWARE_ADAPTERS=([1-9])') {
    Write-Host "  PASSTHROUGH WORKS: a HARDWARE DirectX adapter is visible in the container." -ForegroundColor Green
    Write-Host "  DirectML (ONNX DmlExecutionProvider / GenAI DML) will run on the physical GPU."
} elseif ($gpuText -match 'HARDWARE_ADAPTERS=0') {
    Write-Host "  DEVICE-NOT-INJECTED: container started but DXGI sees only WARP (software)." -ForegroundColor Yellow
    Write-Host "  The device class was accepted but no hardware adapter was mapped (check the GUID"
    Write-Host "  is exactly $GpuDeviceClass, and that the GPU driver supports container GPU-PV)."
} else {
    Write-Host "  INCONCLUSIVE -- inspect the probe output above (rc=$gpuRc)." -ForegroundColor Yellow
}

