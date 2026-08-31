#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Start the GenieX server fleet in the measured-optimal topology for a coding agent.

.DESCRIPTION
    One `geniex serve` binds ONE compute unit and serves ONE request at a time --
    it does not batch, and while it generates it does not even answer /v1/models.
    Aggregate throughput therefore comes from running several servers.

    Measured on this host (Snapdragon X, 2026-08-31):

      Single lane        NPU 19.5   CPU 23.7   GPU 12.5   hybrid 9.96  (4B class)
      NPU + GPU          19.25 + 12.11               = 31.4 tok/s
      NPU + CPU          18.85 + 20.81               = 39.7 tok/s   <- best pair
      NPU + GPU + CPU    18.66 + 11.13 + 15.64       = 45.4 tok/s   <- max

    The NPU lane is immune to contention (18.6-19.25 tok/s in every combination):
    isolated silicon, and its CPU footprint is pinned to 3 cores (cpu-mask 0xe0).
    The CPU and GPU lanes fight over the same 8 Oryon cores.

    Default is NPU + GPU: a second lane at low CPU cost, leaving the machine
    usable. -WithCpu adds the fastest GGUF lane (23.7 tok/s) but it pegs 7.5 of
    8 cores, so the box becomes unresponsive for interactive work.

    -WithHybrid exists only for completeness. Do NOT use it: hybrid is slower
    than plain CPU on every model measured (4B 9.96 vs 23.7; 9B 7.5 vs 15.2),
    no --ngl setting rescues it (6-8 tok/s across the sweep), its first token
    takes 14-27 s, and it is the only mode that damages a concurrent NPU lane
    (19.25 -> 12.84) because it shares the same HTP.

    Two defaults matter and are both wrong out of the box for agent use:
      --keepalive 300  unloads the model after 5 idle minutes, so every pause in
                       a coding session costs a 15 s cold reload. We set 24 h.
      --nctx 4096      is smaller than the 8192 the opencode config advertises;
                       overflowing it makes the server crawl instead of erroring.

.EXAMPLE
    pwsh -File windows/scripts/host/start-geniex-servers.ps1
    Starts the NPU (18181) and GPU (18182) lanes.

.EXAMPLE
    pwsh -File windows/scripts/host/start-geniex-servers.ps1 -WithHybrid -Restart
    Stops any running servers, then starts all three lanes.
#>
[CmdletBinding()]
param(
    [int]$NpuPort    = 18181,
    [int]$GpuPort    = 18182,
    [int]$HybridPort = 18183,
    [int]$CpuPort    = 18184,
    [int]$Nctx       = 16384,
    [int]$Keepalive  = 86400,
    [switch]$WithHybrid,
    [switch]$WithCpu,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exe = Join-Path $env:LOCALAPPDATA 'GenieX CLI\geniex.exe'
if (-not (Test-Path $exe)) { throw "GenieX CLI not found at $exe -- install it from https://github.com/qualcomm/GenieX/releases" }

if ($Restart) {
    Write-Host 'Stopping running geniex servers...' -ForegroundColor Yellow
    Get-Process geniex -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

function Start-Lane {
    param([string]$Compute, [int]$Port)

    $busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($busy) { Write-Host ("  {0,-6} :{1}  already listening (pid {2}) -- skipped" -f $Compute, $Port, @($busy)[0].OwningProcess) -ForegroundColor DarkGray; return }

    $argList = @('serve', '--compute', $Compute, '--host', "0.0.0.0:$Port",
              '--nctx', $Nctx, '--keepalive', $Keepalive)
    Start-Process -WindowStyle Hidden -FilePath $exe -ArgumentList $argList | Out-Null

    foreach ($i in 1..20) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 2 | Out-Null
            Write-Host ("  {0,-6} :{1}  up ({2}s)" -f $Compute, $Port, $i) -ForegroundColor Green
            return
        } catch { }
    }
    Write-Warning ("  {0,-6} :{1}  did not answer within 20s" -f $Compute, $Port)
}

Write-Host "GenieX fleet  (nctx=$Nctx, keepalive=${Keepalive}s)" -ForegroundColor Cyan
Start-Lane -Compute 'npu' -Port $NpuPort
Start-Lane -Compute 'gpu' -Port $GpuPort
if ($WithHybrid) { Start-Lane -Compute 'hybrid' -Port $HybridPort }
if ($WithCpu)    { Start-Lane -Compute 'cpu'    -Port $CpuPort }

Write-Host ''
Write-Host 'Point the agent at:' -ForegroundColor Cyan
Write-Host "  http://127.0.0.1:$NpuPort/v1  qualcomm/Qwen3-4B-Instruct-2507:W4A16   <- primary, 19.5 tok/s"
Write-Host "  http://127.0.0.1:$GpuPort/v1  unsloth/Qwen3-4B-GGUF:Q4_0              <- second lane, 12.5 tok/s"
if ($WithHybrid) { Write-Host "  http://127.0.0.1:$HybridPort/v1  empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M  <- third lane, contends with NPU" }
if ($WithCpu)    { Write-Host "  http://127.0.0.1:$CpuPort/v1  unsloth/Qwen3-4B-GGUF:Q4_0              <- fastest GGUF lane (23.2 tok/s) BUT pegs 7.5 of 8 cores" }
