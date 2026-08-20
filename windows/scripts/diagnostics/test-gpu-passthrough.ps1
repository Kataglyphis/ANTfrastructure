# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Test whether the host GPU can be passed through to a process-isolated Windows
    container so DirectX / DirectML runs on real hardware (not the WARP software
    renderer). Run after any Docker Engine / containerd / hcsshim / Windows /
    base-image / GPU-driver upgrade to check if GPU-in-container has become usable.

.DESCRIPTION
    Background (see docs/windows-builds.md § GPU acceleration in containers and the
    directml-clangcl-port / windows-container-host-quirks memories):

    On Windows, GPU acceleration in containers is DirectX-only (Direct3D 12 and the
    frameworks on top of it -- including DirectML). It requires:
      * process isolation           (Hyper-V-isolated containers get NO GPU)
      * --device class/5B45201D-F2F2-4F3B-85BB-30FF1F953599   (the DirectX GPU
        device interface class; NOTE the exact GUID -- a wrong variant is silently
        accepted by `docker run` but assigns nothing, leaving only WARP)
      * a base-image OS build that MATCHES the host build. Basic process isolation
        tolerates skew (a 26100 image runs on a 26200 host), but GPU driver-store
        INJECTION does not -- CreateComputeSystem fails with "The system cannot
        find the path specified" when the builds differ. This is the SAME
        client-host (26200) vs Server base image (ltsc2025 / 26100) skew that
        breaks `docker build --isolation process` layer commits.

    This host's GPUs (AMD Radeon RX 9070 XT + iGPU) ARE GPU-PV partitionable
    (Get-VMHostPartitionableGpu lists them), and DirectML is vendor-agnostic, so
    the RX 9070 XT is the REAL GPU path here (there is no NVIDIA GPU -- CUDA/TensorRT
    are dead weight on this box). The blocker is purely the base-image/host build
    skew, not the GPU or the DirectML build.

    The script:
      1. Prints host build, image OsVersion, and host partitionable GPUs.
      2. CONTROL   -- `docker run --isolation process` with NO device (must work).
      3. GPU       -- `docker run --isolation process --device class/<GPU-GUID>`,
                      then compiles + runs a DXGI adapter enumerator inside the
                      container and reports HARDWARE vs SOFTWARE(WARP) adapters.
      4. Verdict   -- PASSTHROUGH WORKS / BLOCKED (build skew) / DEVICE-NOT-INJECTED.

.PARAMETER Image
    Container image to test. Must contain clang-cl + the Windows SDK (the built
    winamd64 image does). Default: ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64

.PARAMETER Docker
    Path to docker.exe. Defaults to Stevedore's, then PATH.

.EXAMPLE
    pwsh -File windows/scripts/diagnostics/test-gpu-passthrough.ps1
#>
param(
    [string]$Image = 'ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64',
    [string]$Docker = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The DirectX GPU device interface class GUID (Microsoft-documented). A wrong
# variant (e.g. ...-4AA3-9020-C4B8B62E36F7) is accepted by docker but matches no
# device, so the container silently falls back to WARP -- use exactly this one.
$GpuDeviceClass = 'class/5B45201D-F2F2-4F3B-85BB-30FF1F953599'

if ([string]::IsNullOrWhiteSpace($Docker)) {
    $candidates = @(@('C:\Program Files\Stevedore\bin\docker.exe') | Where-Object { Test-Path $_ })
    $Docker = if ($candidates.Count) { $candidates[0] } else { (Get-Command docker -ErrorAction Stop).Source }
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

