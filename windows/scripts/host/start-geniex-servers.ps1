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

      NPU alone            19.5 tok/s      GPU alone            12.5 tok/s
      NPU + GPU together   19.2 + 12.1     = 31.4 tok/s aggregate, ~0% interference
      NPU + GPU + hybrid   12.8+11.2+10.1  = 34.1 tok/s, but the NPU lane drops 34%

    NPU and GPU are separate silicon and compose almost perfectly. `hybrid` is
    NPU+CPU, so it contends for the same HTP -- it is opt-in via -WithHybrid and
    is only worth it when you truly want a third concurrent lane.

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
    [int]$Nctx       = 16384,
    [int]$Keepalive  = 86400,
    [switch]$WithHybrid,
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

Write-Host ''
Write-Host 'Point the agent at:' -ForegroundColor Cyan
Write-Host "  http://127.0.0.1:$NpuPort/v1  qualcomm/Qwen3-4B-Instruct-2507:W4A16   <- primary, 19.5 tok/s"
Write-Host "  http://127.0.0.1:$GpuPort/v1  unsloth/Qwen3-4B-GGUF:Q4_0              <- second lane, 12.5 tok/s"
if ($WithHybrid) { Write-Host "  http://127.0.0.1:$HybridPort/v1  empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M  <- third lane, contends with NPU" }
