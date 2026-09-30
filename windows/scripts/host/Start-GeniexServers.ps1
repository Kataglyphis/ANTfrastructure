#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Start the GenieX server fleet in the measured-optimal topology for a coding agent.

.DESCRIPTION
    Fleet topology, measured numbers and flag rationale: docs/geniex-local-ai-setup.md.
    Default is NPU + GPU; -WithCpu and -WithHybrid are opt-in and not recommended.

.PARAMETER Models
    Compute -> model id, e.g. @{ npu = 'qualcomm/Qwen3-4B-Instruct-2507:W4A16' }; overrides backends.json for those lanes.

.PARAMETER Pull
    Run `geniex pull <model>` for any model the local store does not list.

.PARAMETER BindAddress
    Listen address; 0.0.0.0 reaches WSL2 in NAT mode, 127.0.0.1 suffices for mirrored mode and the gateway.

.EXAMPLE
    pwsh -File windows/scripts/host/Start-GeniexServers.ps1
    Starts the NPU (18181) and GPU (18182) lanes with the backends.json models.

.EXAMPLE
    pwsh -File windows/scripts/host/Start-GeniexServers.ps1 -WithCpu -MaxTokens 8192 -Pull
    Adds the CPU lane, raises the per-response cap, and fetches missing models.

.EXAMPLE
    pwsh -File windows/scripts/host/Start-GeniexServers.ps1 -BindAddress 127.0.0.1 -WithCpu
    The gateway's lanes: loopback only, with the CPU lane.
#>
[CmdletBinding()]
param(
    [int]$NpuPort    = 18181,
    [int]$GpuPort    = 18182,
    [int]$HybridPort = 18183,
    [int]$CpuPort    = 18184,
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$BindAddress = '0.0.0.0',
    [int]$Nctx       = 16384,
    [int]$MaxTokens  = 4096,
    [int]$Keepalive  = 86400,
    [hashtable]$Models = @{},
    [switch]$Pull,
    [switch]$WithHybrid,
    [switch]$WithCpu,
    [switch]$Restart,
    # Each lane's stdout/stderr; under LOCALAPPDATA so WSL can read it back through /mnt/c.
    [string]$LaneLogDir = (Join-Path $env:LOCALAPPDATA 'GenieX CLI\lane-logs'),
    # geniex --log, when the build has it; the CLI default 'none' leaves an empty log on a silent failure.
    [ValidateSet('none', 'error', 'warn', 'info', 'debug', 'trace')]
    [string]$LogLevel = 'info',
    # Layers to offload, -1 = all (llama.cpp lanes only); passed only when set.
    [Nullable[int]]$Ngl = $null,
    # Env for the server process only: the one way to reach the embedded llama.cpp beyond --ngl.
    [hashtable]$ServerEnv = @{}
)

Set-StrictMode -Version Latest
# Where this script's own probes connect: a wildcard bind is reached on loopback.
$ProbeHost = if ($BindAddress -eq '0.0.0.0') { '127.0.0.1' } else { $BindAddress }
$ErrorActionPreference = 'Stop'

$exe = Join-Path $env:LOCALAPPDATA 'GenieX CLI\geniex.exe'
if (-not (Test-Path $exe)) { throw "GenieX CLI not found at $exe -- install it from https://github.com/qualcomm/GenieX/releases" }

# Every property access is guarded: under StrictMode a missing JSON key throws instead of returning $null.
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

# The serve flags move between geniex releases, and an unknown flag is fatal at startup.
$script:ServeHelp = $null
$script:WarnedNoMaxTokens = $false
function Test-ServeFlag {
    param([Parameter(Mandatory)][string]$Flag)
    if ($null -eq $script:ServeHelp) {
        try { $script:ServeHelp = (& $exe serve --help 2>&1 | Out-String) }
        catch { $script:ServeHelp = '' }
    }
    return ($script:ServeHelp -match [regex]::Escape($Flag))
}

# Loading a GGUF into a lane holding a QAIRT bundle crashes the NPU server, which looks like a bad model.
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
        $r = Invoke-RestMethod -Uri "http://${ProbeHost}:$Port/v1/models" -TimeoutSec 5
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

# An unreadable store listing must not silently skip every pull.
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
    # A failed pull must not abort the fleet; PS 7.4 makes a non-zero native exit terminating under Stop.
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

# /v1/models answers before weights load, so without a warmup the first measured request pays the cold load.
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
        Invoke-RestMethod -Uri "http://${ProbeHost}:$Port/v1/chat/completions" `
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
        # A lane started earlier on 0.0.0.0 stays on the LAN whatever -BindAddress says now.
        $bound = @($busy | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique)
        if ($bound -notcontains $BindAddress) {
            Write-Warning ("  {0,-6} :{1}  listens on {2}, not the requested {3} -- re-run with -Restart to rebind it." -f $Compute, $Port, ($bound -join ', '), $BindAddress)
        }
        # @(): an empty array return unrolls to $null, whose .Count throws under StrictMode.
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

    # --nctx explicit so a report shows it; --max-tokens only where serve still has it, else clients send max_tokens.
    $argList = @('serve', '--compute', $Compute, '--host', "${BindAddress}:$Port",
                 '--nctx', $Nctx, '--keepalive', $Keepalive)
    if (Test-ServeFlag '--max-tokens') {
        $argList += @('--max-tokens', $MaxTokens)
    } elseif (-not $script:WarnedNoMaxTokens) {
        $script:WarnedNoMaxTokens = $true
        Write-Warning ("  this geniex has no `serve --max-tokens`; every caller must send max_tokens itself (-MaxTokens {0} ignored)." -f $MaxTokens)
    }
    if ($LogLevel -and (Test-ServeFlag '--log')) { $argList += @('--log', $LogLevel) }
    if ($null -ne $Ngl -and (Test-ServeFlag '--ngl')) { $argList += @('--ngl', $Ngl) }

    # Restored after Start-Process so one lane's env cannot leak into the next lane or the shell.
    $savedEnv = @{}
    foreach ($k in $ServerEnv.Keys) {
        $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$ServerEnv[$k])
        Write-Host ("  {0,-6} :{1}  env {2}={3}" -f $Compute, $Port, $k, $ServerEnv[$k]) -ForegroundColor DarkGray
    }

    # Unredirected, a hidden lane that dies on startup leaves nothing to read; the two streams need separate files.
    if (-not (Test-Path $LaneLogDir)) {
        New-Item -ItemType Directory -Force -Path $LaneLogDir | Out-Null
    }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog  = Join-Path $LaneLogDir "$Compute-$Port-$stamp.out.log"
    $errLog  = Join-Path $LaneLogDir "$Compute-$Port-$stamp.err.log"
    Start-Process -WindowStyle Hidden -FilePath $exe -ArgumentList $argList `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog | Out-Null
    foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }

    foreach ($i in 1..20) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://${ProbeHost}:$Port/v1/models" -TimeoutSec 2 | Out-Null
            Write-Host ("  {0,-6} :{1}  up ({2}s)  log: {3}" -f $Compute, $Port, $i, $outLog) -ForegroundColor Green
            Invoke-Warmup -Compute $Compute -Port $Port -Model $model
            return
        } catch {
            # Expected until the port binds; running out of attempts warns below.
            Write-Debug ("  {0} :{1} not ready after {2}s: {3}" -f $Compute, $Port, $i, $_.Exception.Message)
        }
    }
    # A lane that exits immediately has already written its reason, so quote it.
    Write-Warning ("  {0,-6} :{1}  did not answer within 20s -- log: {2}" -f $Compute, $Port, $errLog)
    foreach ($log in @($errLog, $outLog)) {
        if (Test-Path $log) {
            $tail = Get-Content -Path $log -Tail 5 -ErrorAction SilentlyContinue
            if ($tail) { $tail | ForEach-Object { Write-Warning ("      {0}" -f $_) } }
        }
    }
}

Write-Host "GenieX fleet  (nctx=$Nctx, max-tokens=$MaxTokens, keepalive=${Keepalive}s)" -ForegroundColor Cyan
Write-Host "  models from $backendsFile" -ForegroundColor DarkGray
Start-Lane -Compute 'npu' -Port $NpuPort
Start-Lane -Compute 'gpu' -Port $GpuPort
if ($WithHybrid) { Start-Lane -Compute 'hybrid' -Port $HybridPort }
if ($WithCpu)    { Start-Lane -Compute 'cpu'    -Port $CpuPort }

# What each lane reports serving, which differs from the request when an earlier run started it.
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
    Write-Host ("  http://{0}:{1}/v1  {2}   <- {3}" -f $ProbeHost, $lane.Port, $shown, $lane.Note)
    $want = Get-LaneModel -Compute $lane.Compute
    if ($served.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($want) -and $served -notcontains $want) {
        Write-Warning ("  {0,-6} serves {1}, not the configured {2} -- re-run with -Restart to load it." -f $lane.Compute, $served[0], $want)
    }
}
