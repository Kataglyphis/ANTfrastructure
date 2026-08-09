# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One elevated run to bring a FRESH Windows host (Stevedore installed + rebooted,
# repo checked out) to a green `verify-host-setup.ps1` plus a running dufs
# sccache L2 endpoint. This is the "scriptable half" of docs/windows-host-setup.md
# Phase A5 + Phase C; the interactive half (Stevedore install, reboot, docker-users
# group, docker.exe conditional fixes) still needs the guide by hand.
#
# It ORCHESTRATES the canonical per-concern scripts instead of duplicating them:
#   * CNI .conflist is AUTHORED here from the LIVE vEthernet (nat) subnet - no
#     magic constants - and apply-containerd-config.ps1 derives the .conf from it.
#   * apply-containerd-config.ps1  - debug flags, teardown env var, Defender
#     exclusions, CNI .conf derive, containerd restart.
#   * apply-buildkitd-gcpolicy.ps1 + the step-log env var - GC policy, history
#     cap, --config, buildkitd restart.
#   * deploy-shim-patch.ps1        - installs the patched runhcs shim. If no
#     -ShimPath is given and the live binary is unpatched, this script BUILDS the
#     45min/100min fixed-constant shim from hcsshim source (per
#     windows/upstream/hcsshim-teardown-timeout/README.md § Rebuilding the local
#     45 min shim), installing Go via scoop when missing.
#   * dufs + persistence           - scoops dufs if missing, starts it serving
#     the sccache cache dir, registers the logon task, sets the machine-level
#     SCCACHE_WEBDAV_ENDPOINT to the host's LAN IP (never localhost).
#
# RUN FROM AN ADMIN SHELL and NEVER while a build is solving: the config scripts
# restart containerd and buildkitd, which kills every in-flight solve.
#
#   pwsh -File windows\scripts\setup-new-host.ps1 -ReportOnly          # plan, nothing changed
#   pwsh -File windows\scripts\setup-new-host.ps1                      # bring this host to green
#   pwsh -File windows\scripts\setup-new-host.ps1 -SkipShim            # shim is already patched
#   pwsh -File windows\scripts\setup-new-host.ps1 -ShimPath C:\src\hcsshim\containerd-shim-runhcs-v1.exe
#   pwsh -File windows\scripts\setup-new-host.ps1 -SccacheCacheDir C:\Users\jonas\sccache-cache
#
# Verify afterwards:
#   pwsh -File windows\scripts\verify-host-setup.ps1 -SccacheEndpoint http://<lan-ip>:5000

#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # A prebuilt patched shim to deploy instead of building one.
    [string]$ShimPath = '',

    # Port the dufs sccache L2 server listens on (docs standard: 5000).
    [string]$SccachePort = '5000',

    # WebDAV store directory served by dufs. Default matches the guide (C5).
    [string]$SccacheCacheDir = 'C:\sccache-cache',

    # Extra dufs serve arguments: -A allows all read/write. Kept as a parameter
    # so a host can restrict it once the L2 store is trusted.
    [string]$DufsExtraArgs = '-A',

    # Skip rebuilding/deploying the shim (you are SURE it is patched already).
    [switch]$SkipShim,
    # Skip the CNI conflist authorship + apply-containerd-config (incl. .conf).
    [switch]$SkipCni,
    # Skip the GC policy + buildkitd step-log env + buildkitd restart.
    [switch]$SkipGcPolicy,
    # Skip installing/configuring dufs + the SCCACHE_WEBDAV_ENDPOINT env.
    [switch]$SkipDufs,
    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force,
    # Only print what would change; sub-scripts run with their -ReportOnly.
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $ReportOnly) {
    throw 'Run from an elevated (admin) shell: service config, Defender exclusions, scoop installs and file installs need it.'
}

$scriptRoot = $PSScriptRoot

function Write-Step {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Get-LanIpv4Address {
    # The address containers should reach the host on: a physical adapter with a
    # real default gateway, skipping the HNS/reserved adapters and link-local.
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and
            $_.NetAdapter.InterfaceAlias -notmatch '^vEthernet|Loopback|Bluetooth|WLAN' }
    $addr = ($cfg | Select-Object -First 1).IPv4Address.IPAddress
    if (-not $addr) {
        $addr = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
                $_.InterfaceAlias -notmatch '^vEthernet|Loopback' } |
            Select-Object -ExpandProperty IPAddress -First 1)
    }
    if (-not $addr) { throw 'Could not determine a LAN IPv4 address for the sccache endpoint (ipconfig?)' }
    return $addr
}

function Get-NatAdapterCidr {
    # Live vEthernet (nat) -> "network/prefix" for the CNI conflist. Derived at
    # runtime so the docs never hand out a magic subnet that drifts out of
    # existence when dockerd recreates the HNS nat network on a new subnet.
    # Byte-based mask to avoid the int64 sign traps of the .NET Address net-order
    # conversion for 172.x/192.x octets.
    $n = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -eq 'vEthernet (nat)' } | Select-Object -First 1
    if (-not $n) { throw "No 'vEthernet (nat)' adapter found - is Windows Containers enabled (Stevedore + reboot)?" }
    $bytes = [System.Net.IPAddress]::Parse($n.IPAddress).GetAddressBytes()
    $prefix = [int]$n.PrefixLength
    $netBytes = [byte[]]::new(4)
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, $prefix - (8 * $i)))
        if ($bits -eq 8)                { $netBytes[$i] = $bytes[$i] }
        elseif ($bits -eq 0)            { $netBytes[$i] = [byte]0 }
        else {
            $shift = 8 - $bits
            $netBytes[$i] = ([byte]($bytes[$i] -shr $shift)) -shl $shift
        }
    }
    $netStr = '{0}.{1}.{2}.{3}' -f $netBytes[0], $netBytes[1], $netBytes[2], $netBytes[3]
    return ('{0}/{1}' -f $netStr, $prefix), $n.IPAddress
}

# ── Step 1: CNI conflist (authored) + apply-containerd-config (derives .conf) ─
function Invoke-StepCni {
    if ($SkipCni) { Write-Step 'cni        : skipped (-SkipCni)'; return }

    $cniDir = 'C:\Program Files\containerd\cni\conf'
    $conflistPath = Join-Path $cniDir '0-containerd-nat.conflist'
    $natCidr, $natGw = Get-NatAdapterCidr
    $desired = @{
        cniVersion = '0.3.0'
        name       = 'nat'
        plugins    = @(@{
            type         = 'nat'
            master       = 'Ethernet'
            ipam         = @{
                subnet = $natCidr
                routes = @(@{ GW = $natGw })
            }
            capabilities = @{ portMappings = $true; dns = $true }
        })
    } | ConvertTo-Json -Depth 8

    $changeNeed = if (Test-Path $conflistPath) {
        ((Get-Content -Raw $conflistPath).Trim() -ne $desired.Trim())
    } else {
        $true
    }

    $verb = if ($ReportOnly) { 'would write' } else { 'writing' }
    if ($changeNeed) {
        Write-Step ("cni        : {0} the .conflist (subnet {1} from the live nat adapter)" -f $verb, $natCidr) 'Yellow'
        if (-not $ReportOnly) {
            New-Item -ItemType Directory -Force -Path $cniDir | Out-Null
            Set-Content -Path $conflistPath -Value ($desired + "`n") -Encoding utf8
            Write-Step "cni        : wrote $conflistPath" 'Green'
        }
    } else {
        Write-Step "cni        : .conflist already at the live subnet ($natCidr) - no change"
    }

    # apply-containerd-config derives the .conf from the .conflist and owns the
    # debug flags, teardown env var and Defender exclusions (restarts containerd).
    # HASHTABLE splat, never an array: array splatting binds by position and
    # would deliver '-ReportOnly' as $ServiceName (AGENTS § array-splat trap).
    $acArgs = @{ ReportOnly = $ReportOnly }
    Write-Step 'containerd : applying apply-containerd-config.ps1 (debug flags, teardown env, Defender, .conf derive)'
    & (Join-Path $scriptRoot 'apply-containerd-config.ps1') @acArgs
}

# ── Step 2: GC policy + step-log env + buildkitd restart ───────────────────────
function Invoke-StepGcPolicy {
    if ($SkipGcPolicy) { Write-Step 'buildkitd  : skipped (-SkipGcPolicy)'; return }

    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd'
    $desiredEnv = @('BUILDKIT_STEP_LOG_MAX_SIZE=-1', 'BUILDKIT_STEP_LOG_MAX_SPEED=-1')

    $props = Get-ItemProperty $svcKey -ErrorAction SilentlyContinue
    $have = if ($props -and $props.PSObject.Properties.Name -contains 'Environment') { @($props.Environment) } else { @() }
    $missing = @($desiredEnv | Where-Object { $have -notcontains $_ })

    if ($missing.Count -eq 0) {
        Write-Step 'buildkitd  : step-log env present'
    } elseif ($ReportOnly) {
        Write-Step "buildkitd  : step-log env MISSING ($($missing -join ', ')) - would set on the real run" 'Yellow'
    } elseif (-not $Force) {
        $live = @(Get-Process -Name 'buildctl' -ErrorAction SilentlyContinue)
        if ($live.Count -gt 0) {
            throw ("{0} live buildctl process(es) - this step restarts buildkitd and kills them. " -f $live.Count) +
                'Wait, or pass -Force if they are stale.'
        }
    }

    if (-not $ReportOnly -and $missing.Count -gt 0) {
        $merged = @($have | Where-Object { $_ -notmatch '^BUILDKIT_STEP_LOG_' }) + $desiredEnv
        Set-ItemProperty -Path $svcKey -Name Environment -Value ([string[]]$merged) -Type MultiString
        Write-Step "buildkitd  : Environment set to $($merged -join '; ')" 'Green'
    }

    if ($ReportOnly) {
        # apply-buildkitd-gcpolicy.ps1 has NO dry-run mode (it deploys the toml
        # and restarts buildkitd unconditionally) - so REPORT the intent here and
        # never invoke it from a report run.
        Write-Step 'buildkitd  : would apply apply-buildkitd-gcpolicy.ps1 (GC policy + history cap + --config + restart)'
        return
    }

    # Hashtable splat (NOT an array) so -Force binds as the switch, not as $ConfigDest.
    $gcArgs = @{ Force = $Force }
    Write-Step 'buildkitd  : applying apply-buildkitd-gcpolicy.ps1 (GC policy + --config + restart)'
    & (Join-Path $scriptRoot 'apply-buildkitd-gcpolicy.ps1') @gcArgs
}

# ── Step 3: patched runhcs shim (build if needed, then deploy) ─────────────────
function Invoke-StepShim {
    if ($SkipShim) { Write-Step 'shim       : skipped (-SkipShim)'; return }

    $shimExe = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe"
    $installedSize = if (Test-Path $shimExe) { (Get-Item $shimExe).Length } else { 0 }
    $json = 'C:\ProgramData\kataglyphis\shim-patch.json'
    $recorded = Test-Path $json
    if ($recorded) {
        try { $null = Get-Content -Raw $json | ConvertFrom-Json } catch { $recorded = $false }
    }

    if ($installedSize -gt 0 -and $recorded) {
        Write-Step 'shim       : recorded patched shim already installed (hash gate active) - skipping'
        return
    }
    if ($installedSize -gt 0 -and $installedSize -ne 23279616 -and -not $recorded) {
        Write-Step ('shim       : installed binary ({0:N0} B) is NOT stock but no recorded hash - deploy once to record it' -f $installedSize) 'Yellow'
    }

    $build = $ShimPath
    if (-not $build) {
        $build = Invoke-BuildPatchedShim
    } elseif (-not (Test-Path $build)) {
        throw "-ShimPath not found: $build"
    }

    if ($ReportOnly) {
        Write-Step "shim       : would deploy $build"
        return
    }
    # Hashtable splat (NOT an array) so -ShimPath/-Force bind by name.
    $dsp = @{ ShimPath = $build; Force = $Force }
    Write-Step 'shim       : deploying the patched runhcs shim (45min/100min teardown)'
    & (Join-Path $scriptRoot 'deploy-shim-patch.ps1') @dsp
}

function Invoke-BuildPatchedShim {
    $work = Join-Path $env:TEMP 'kataglyphis-hcsshim'
    $src = Join-Path $work 'cmd\containerd-shim-runhcs-v1\task_hcs.go'
    $exeOut = Join-Path $work 'containerd-shim-runhcs-v1.exe'

    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Step 'shim       : Go not found - installing via scoop'
        if ($ReportOnly) { return $exeOut }
        $scoop = Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'
        if (-not (Test-Path $scoop)) { throw "scoop not found ($scoop) - install a patched shim via -ShimPath instead" }
        & $scoop install go
        if ($LASTEXITCODE -ne 0) { throw 'scoop install go failed' }
    }

    if (-not (Test-Path (Join-Path $work '.git'))) {
        if ($ReportOnly) {
            Write-Step 'shim       : would clone Microsoft/hcsshim (shallow) and raise teardown timeouts to 45min/100min'
            return $exeOut
        }
        Write-Step 'shim       : cloning Microsoft/hcsshim (shallow, 1 commit)'
        $git = (Get-Command git -ErrorAction SilentlyContinue).Source
        if (-not $git) { throw 'git not found - install Git for Windows, or pass -ShimPath' }
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        & $git clone --depth 1 https://github.com/Microsoft/hcsshim $work
        if ($LASTEXITCODE -ne 0) { throw 'hcsshim clone failed' }
    }
    if (-not (Test-Path $src)) { throw "task_hcs.go not found at $src - unexpected hcsshim layout?" }

    $raw = Get-Content -Raw $src
    $rawNew = $raw.Replace('const tearDownTimeout = 30 * time.Second', 'const tearDownTimeout = 45 * time.Minute')
    $rawNew = $rawNew.Replace('const timeout = 30 * time.Second', 'const timeout = 100 * time.Minute')
    if ($rawNew -ne $raw) {
        Set-Content -Path $src -Value $rawNew -Encoding utf8
        Write-Step 'shim       : raised teardown timeouts in task_hcs.go to 45min/100min' 'Green'
    } else {
        Write-Step 'shim       : task_hcs.go already carries the long timeouts (idempotent)'
    }

    Push-Location $work
    try {
        & go build .\cmd\containerd-shim-runhcs-v1
        if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Step ("shim       : built $exeOut ({0:N0} B)" -f (Get-Item $exeOut).Length) 'Green'
    return $exeOut
}

# ── Step 4: dufs sccache L2 server + logon task + machine endpoint env ─────────
function Invoke-StepDufs {
    if ($SkipDufs) { Write-Step 'dufs       : skipped (-SkipDufs)'; return }

    $lanIp = Get-LanIpv4Address
    $endpoint = 'http://{0}:{1}' -f $lanIp, $SccachePort

    $dufsCmd = Get-Command dufs -ErrorAction SilentlyContinue
    if (-not $dufsCmd) {
        Write-Step 'dufs       : not installed - installing via scoop'
        if (-not $ReportOnly) {
            $scoop = Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'
            if (-not (Test-Path $scoop)) { throw "scoop not found ($scoop) - install dufs by hand (docs C5)" }
            & $scoop install dufs
            if ($LASTEXITCODE -ne 0) { throw 'scoop install dufs failed' }
        }
    } else {
        Write-Step ('dufs       : present at {0}' -f $dufsCmd.Source)
    }

    if (-not $ReportOnly) {
        New-Item -ItemType Directory -Force -Path $SccacheCacheDir | Out-Null
    }

    $dufsExe = $null
    if (Test-Path "$env:USERPROFILE\scoop\shims\dufs.exe") {
        $dufsExe = "$env:USERPROFILE\scoop\shims\dufs.exe"
    } elseif ($dufsCmd) { $dufsExe = $dufsCmd.Source }

    $open = Test-NetConnection -ComputerName '127.0.0.1' -Port ([int]$SccachePort) -WarningAction SilentlyContinue
    if ($open.TcpTestSucceeded) {
        Write-Step "dufs       : already serving on :$SccachePort (adopting)"
    } else {
        Write-Step "dufs       : nothing on :$SccachePort - would start '$dufsExe' serving '$SccacheCacheDir'"
        if (-not $ReportOnly -and $dufsExe) {
            Start-Process -FilePath $dufsExe -ArgumentList @($SccacheCacheDir, $DufsExtraArgs, '-p', $SccachePort) -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }
    }

    # Logon persistence so a reboot does not kill the endpoint mid-session.
    $taskName = 'dufs-sccache'
    & schtasks.exe /Query /TN $taskName *> $null
    $taskExists = ($LASTEXITCODE -eq 0)
    if (-not $taskExists) {
        $verb = if ($ReportOnly) { 'would register' } else { 'registering' }
        Write-Step ("dufs       : {0} the '{1}' ONLOGON scheduled task" -f $verb, $taskName) 'Yellow'
        if (-not $ReportOnly -and $dufsExe) {
            $cmd = '"{0}" "{1}" {2} -p {3}' -f $dufsExe, $SccacheCacheDir, $DufsExtraArgs, $SccachePort
            & schtasks.exe /Create /F /TN $taskName /TR $cmd /SC ONLOGON /RL LIMITED *> $null
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create $taskName failed (exit $LASTEXITCODE)" }
        }
    } else {
        Write-Step "dufs       : task '$taskName' already registered"
    }

    # Machine-level endpoint (new shells + the build inherit it). NEVER localhost.
    $machineEp = [Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT', 'Machine')
    if ($machineEp -ne $endpoint) {
        $verb = if ($ReportOnly) { 'would set' } else { 'setting' }
        Write-Step ("dufs       : {0} SCCACHE_WEBDAV_ENDPOINT={1} (Machine)" -f $verb, $endpoint) 'Yellow'
        if (-not $ReportOnly) { [Environment]::SetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT', $endpoint, 'Machine') }
    } else {
        Write-Step "dufs       : SCCACHE_WEBDAV_ENDPOINT already $endpoint"
    }

    if (-not $ReportOnly) {
        try {
            $code = (Invoke-WebRequest -Uri $endpoint -Method Head -TimeoutSec 5 -UseBasicParsing).StatusCode
            Write-Step "dufs       : endpoint $endpoint -> HTTP $code" 'Green'
        } catch { throw "sccache endpoint $endpoint is not reachable: $($_.Exception.Message)" }
    }
}

# ── run ─────────────────────────────────────────────────────────────────────────
Write-Step ('setup-new-host {0}' -f $(if ($ReportOnly) { 'REPORT ONLY' } else { 'APPLY' }))

if (-not $SkipCni)      { Invoke-StepCni }
if (-not $SkipGcPolicy) { Invoke-StepGcPolicy }
if (-not $SkipShim)     { Invoke-StepShim }
if (-not $SkipDufs)     { Invoke-StepDufs }

# The .conf derive + config restarts may have left buildkitd stopped or a fresh
# .conf on disk; one restart finalises the CNI + step-log env.
if (-not $ReportOnly) {
    Write-Step 'buildkitd  : restarting to ensure the CNI .conf and step-log env are live'
    Restart-Service buildkitd -Force
    Write-Step ('buildkitd  : {0}' -f (Get-Service buildkitd).Status)
}

$lan = Get-LanIpv4Address
Write-Step ('DONE ({0}). Verify with:  pwsh -File windows\scripts\verify-host-setup.ps1 -SccacheEndpoint http://{1}:{2}' -f
    $(if ($ReportOnly) { 'nothing changed' } else { 'applied' }), $lan, $SccachePort) 'Cyan'
