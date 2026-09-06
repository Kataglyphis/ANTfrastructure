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

    Three defaults matter and are all wrong out of the box for agent use:
      --keepalive 300   unloads the model after 5 idle minutes, so every pause in
                        a coding session costs a 15 s cold reload. We set 24 h.
      --nctx 4096       is smaller than the 8192 the opencode config advertises;
                        overflowing it makes the server crawl instead of erroring.
      --max-tokens 2048 caps ONE response. Benchmark § 1j/§ 1k lost 26 of 27
                        coding tasks to truncation under a 2048 cap that was
                        never recorded anywhere, so it read as a model result.
                        We set 4096 and pass it EXPLICITLY, so the value that
                        produced a number is visible in this file.

    The model ids come from linux/llm-stack/backends.json, so the benchmark
    suite and this launcher cannot drift apart; -Models overrides per lane.

.PARAMETER Models
    Hashtable of compute -> model id, e.g. @{ npu = 'qualcomm/Qwen3-4B-Instruct-2507:W4A16' }.
    Overrides backends.json for the named lanes only.

.PARAMETER Pull
    Run `geniex pull <model>` for any model the local store does not list.

.EXAMPLE
    pwsh -File windows/scripts/host/Start-GeniexServers.ps1
    Starts the NPU (18181) and GPU (18182) lanes with the backends.json models.

.EXAMPLE
    pwsh -File windows/scripts/host/Start-GeniexServers.ps1 -WithCpu -MaxTokens 8192 -Pull
    Adds the CPU lane, raises the per-response cap, and fetches missing models.
#>
[CmdletBinding()]
param(
    [int]$NpuPort    = 18181,
    [int]$GpuPort    = 18182,
    [int]$HybridPort = 18183,
    [int]$CpuPort    = 18184,
    [int]$Nctx       = 16384,
    [int]$MaxTokens  = 4096,
    [int]$Keepalive  = 86400,
    [hashtable]$Models = @{},
    [switch]$Pull,
    [switch]$WithHybrid,
    [switch]$WithCpu,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exe = Join-Path $env:LOCALAPPDATA 'GenieX CLI\geniex.exe'
if (-not (Test-Path $exe)) { throw "GenieX CLI not found at $exe -- install it from https://github.com/qualcomm/GenieX/releases" }

# backends.json is the one place a model id is written down. Under StrictMode
# every property access on parsed JSON has to be guarded: a missing key throws
# rather than returning $null.
function Get-BackendModels {
    param([Parameter(Mandatory)][string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "backends.json not found at $Path -- no model ids known."
        return $map
    }
    $doc = $null
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "could not parse $Path ($($_.Exception.Message)) -- no model ids known."
        return $map
    }
    if ($null -eq $doc -or -not ($doc.PSObject.Properties.Name -contains 'backends')) { return $map }
    $backends = $doc.backends
    if ($null -eq $backends) { return $map }

    foreach ($compute in @('npu', 'gpu', 'hybrid', 'cpu')) {
        $name = "geniex-$compute"
        if (-not ($backends.PSObject.Properties.Name -contains $name)) { continue }
        $entry = $backends.$name
        if ($null -eq $entry) { continue }
        if (-not ($entry.PSObject.Properties.Name -contains 'model')) { continue }
        $model = $entry.model
        if (-not [string]::IsNullOrWhiteSpace($model)) { $map[$compute] = [string]$model }
    }
    return $map
}

# QAIRT bundle or GGUF? Loading a GGUF into a lane that already holds a QAIRT
# bundle crashes the NPU server, and the crash looks like a bad model.
function Get-BundleKind {
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return 'unknown' }
    if ($Model -match '(?i)gguf') { return 'gguf' }
    if ($Model -match '(?i)w4a16|w8a16|qairt|qualcomm/') { return 'qairt' }
    return 'unknown'
}

function Get-ServedModels {
    param([int]$Port)
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5
    } catch {
        return @()
    }
    if ($null -eq $r -or -not ($r.PSObject.Properties.Name -contains 'data')) { return @() }
    $ids = @()
    foreach ($item in @($r.data)) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties.Name -contains 'id' -and $item.id) { $ids += [string]$item.id }
    }
    return $ids
}

$scriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path
$backendsFile = Join-Path $repoRoot 'linux\llm-stack\backends.json'
$laneModels = Get-BackendModels -Path $backendsFile
if ($null -ne $Models) {
    foreach ($key in @($Models.Keys)) {
        $value = $Models[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) { $laneModels[[string]$key] = [string]$value }
    }
}

function Get-LaneModel {
    param([string]$Compute)
    if ($laneModels.ContainsKey($Compute)) { return $laneModels[$Compute] }
    return ''
}

# `geniex list` once, not per lane: it is the only way to tell a missing model
# from one already in the store, and an unreadable list must not silently skip
# every pull.
$storeListing = $null
if ($Pull) {
    try {
        $storeListing = (& $exe list 2>&1 | Out-String)
    } catch {
        $storeListing = $null
    }
    if ([string]::IsNullOrWhiteSpace($storeListing)) {
        Write-Warning 'could not read the local model store (geniex list) -- pulling every configured model; an already-present model is a no-op.'
    }
}

function Invoke-PullIfMissing {
    param([string]$Model)
    if (-not $Pull -or [string]::IsNullOrWhiteSpace($Model)) { return }
    if ($null -ne $storeListing -and $storeListing -match [regex]::Escape($Model)) {
        Write-Host ("  pull   {0}  already in the store" -f $Model) -ForegroundColor DarkGray
        return
    }
    Write-Host ("  pull   {0}" -f $Model) -ForegroundColor Yellow
    # A failed pull must not abort the fleet: PS 7.4 turns a non-zero native
    # exit into a terminating error under $ErrorActionPreference = 'Stop'.
    try {
        & $exe pull $Model
        if ($LASTEXITCODE -ne 0) { Write-Warning ("geniex pull {0} exited {1}" -f $Model, $LASTEXITCODE) }
    } catch {
        Write-Warning ("geniex pull {0} failed: {1}" -f $Model, $_.Exception.Message)
    }
}

if ($Restart) {
    Write-Host 'Stopping running geniex servers...' -ForegroundColor Yellow
    Get-Process geniex -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

# One tiny request per lane. /v1/models answers before any weights are loaded,
# so "up" without a warmup still means the first real request pays a 15 s cold
# load -- which lands in the first measured task.
function Invoke-Warmup {
    param([string]$Compute, [int]$Port, [string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { return }
    $body = @{
        model      = $Model
        messages   = @(@{ role = 'user'; content = 'hi' })
        max_tokens = 1
        stream     = $false
    } | ConvertTo-Json -Depth 5
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
            -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300 | Out-Null
        Write-Host ("  {0,-6} :{1}  warm ({2})" -f $Compute, $Port, $Model) -ForegroundColor DarkGreen
    } catch {
        Write-Warning ("  {0,-6} :{1}  warmup failed for {2}: {3}" -f $Compute, $Port, $Model, $_.Exception.Message)
    }
}

function Start-Lane {
    param([string]$Compute, [int]$Port)

    $model = Get-LaneModel -Compute $Compute
    if ([string]::IsNullOrWhiteSpace($model)) {
        Write-Warning ("  {0,-6} :{1}  no model id in backends.json or -Models; the lane starts but cannot be warmed or pulled" -f $Compute, $Port)
    }

    $busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host ("  {0,-6} :{1}  already listening (pid {2}) -- skipped" -f $Compute, $Port, @($busy)[0].OwningProcess) -ForegroundColor DarkGray
        # A lane already holding a different KIND of bundle will not take this
        # model; on the NPU that is a server crash, not an error message.
        # @(): a function returning an empty array unrolls to $null, and
        # $null.Count is an error under StrictMode.
        $served = @(Get-ServedModels -Port $Port)
        if ($served.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($model)) {
            $wantKind = Get-BundleKind -Model $model
            $haveKind = Get-BundleKind -Model $served[0]
            if ($wantKind -ne 'unknown' -and $haveKind -ne 'unknown' -and $wantKind -ne $haveKind) {
                Write-Warning ("  {0,-6} :{1}  serves a {2} bundle ({3}) but {4} is {5}. Re-run with -Restart; loading a GGUF into a lane holding a QAIRT bundle crashes the server." -f $Compute, $Port, $haveKind, $served[0], $model, $wantKind)
            }
        }
        return
    }

    Invoke-PullIfMissing -Model $model

    # --nctx and --max-tokens passed EXPLICITLY: the CLI's own defaults (4096 /
    # 2048) are invisible in a benchmark report, and the 2048 one silently
    # truncated 26 of 27 coding tasks.
    $argList = @('serve', '--compute', $Compute, '--host', "0.0.0.0:$Port",
                 '--nctx', $Nctx, '--max-tokens', $MaxTokens, '--keepalive', $Keepalive)
    Start-Process -WindowStyle Hidden -FilePath $exe -ArgumentList $argList | Out-Null

    foreach ($i in 1..20) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 2 | Out-Null
            Write-Host ("  {0,-6} :{1}  up ({2}s)" -f $Compute, $Port, $i) -ForegroundColor Green
            Invoke-Warmup -Compute $Compute -Port $Port -Model $model
            return
        } catch { }
    }
    Write-Warning ("  {0,-6} :{1}  did not answer within 20s" -f $Compute, $Port)
}

Write-Host "GenieX fleet  (nctx=$Nctx, max-tokens=$MaxTokens, keepalive=${Keepalive}s)" -ForegroundColor Cyan
Write-Host "  models from $backendsFile" -ForegroundColor DarkGray
Start-Lane -Compute 'npu' -Port $NpuPort
Start-Lane -Compute 'gpu' -Port $GpuPort
if ($WithHybrid) { Start-Lane -Compute 'hybrid' -Port $HybridPort }
if ($WithCpu)    { Start-Lane -Compute 'cpu'    -Port $CpuPort }

# What each lane REPORTS serving, not what we asked for: the two differ after a
# lane was started by hand or by an earlier run with other flags.
Write-Host ''
Write-Host 'Point the agent at:' -ForegroundColor Cyan
$lanes = @(
    @{ Compute = 'npu'; Port = $NpuPort; Note = 'primary, 19.5 tok/s' },
    @{ Compute = 'gpu'; Port = $GpuPort; Note = 'second lane, 12.5 tok/s' }
)
if ($WithHybrid) { $lanes += @{ Compute = 'hybrid'; Port = $HybridPort; Note = 'third lane, contends with NPU -- avoid' } }
if ($WithCpu)    { $lanes += @{ Compute = 'cpu';    Port = $CpuPort;    Note = 'fastest GGUF lane (23.2 tok/s) BUT pegs 7.5 of 8 cores' } }

foreach ($lane in $lanes) {
    $served = @(Get-ServedModels -Port $lane.Port)
    $shown = if ($served.Count -gt 0) { $served -join ', ' } else { '(not answering /v1/models)' }
    Write-Host ("  http://127.0.0.1:{0}/v1  {1}   <- {2}" -f $lane.Port, $shown, $lane.Note)
    $want = Get-LaneModel -Compute $lane.Compute
    if ($served.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($want) -and $served -notcontains $want) {
        Write-Warning ("  {0,-6} serves {1}, not the configured {2} -- re-run with -Restart to load it." -f $lane.Compute, $served[0], $want)
    }
}
