#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Machine-checkable version of docs/windows-host-setup.md.
#
# WHY THIS EXISTS: that guide has never been walked cold on a second machine.
# Everything in it was written by someone who already knew the answers, on the
# host where the knowledge was built - and that is exactly how a setup guide
# rots without anyone noticing. On 2026-08-07 its CNI section still handed a
# fresh host the bare `.conf` template, i.e. the instructions silently cost you
# the entire nerdctl lane, and it read as authoritative the whole time.
#
# Prose cannot catch that. A check can. Every assertion below corresponds to a
# claim the guide makes, so a new machine gets a VERDICT instead of trust.
# When you change the guide, change this script - they are two views of one
# contract.
#
# Non-admin by design: everything here is readable unelevated except the
# Defender exclusions, which are reported as UNKNOWN rather than skipped, so
# their absence can never masquerade as success.
#
#   pwsh -File windows\scripts\host\Test-HostSetup.ps1
#   pwsh -File windows\scripts\host\Test-HostSetup.ps1 -SccacheEndpoint http://<ip>:5000
#
# Exit codes: 0 = all required checks passed, 1 = at least one FAIL.

[CmdletBinding()]
param(
    [string]$StevedoreBin = "$env:ProgramFiles\Stevedore\bin",
    [string]$CniConfDir = 'C:\Program Files\containerd\cni\conf',
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
    [int]$MinFreeGb = 40,
    # Patched runhcs shim sizes; extend as hcsshim moves (see AGENTS.md).
    [long[]]$PatchedShimSize = @(25332736, 25329664),
    [long[]]$StockShimSize = @(23279616)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }

$script:Fail = 0
$script:Warn = 0

function Write-Check {
    param(
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [string]$Name,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ('[{0}] {1}' -f $Status.PadRight(4), $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    if ($Fix -and $Status -ne 'PASS') { Write-Host ('       fix: ' + $Fix) -ForegroundColor Cyan }
    if ($Status -eq 'FAIL') { $script:Fail++ }
    if ($Status -eq 'WARN') { $script:Warn++ }
}

function Test-IpInCidr {
    param([string]$Ip, [string]$Cidr)
    if (-not $Ip -or $Cidr -notmatch '^(.+)/(\d+)$') { return $false }
    $net = [Net.IPAddress]::Parse($Matches[1]); $bits = [int]$Matches[2]
    $a = [BitConverter]::ToUInt32(($net.GetAddressBytes()[3..0]), 0)
    $b = [BitConverter]::ToUInt32(([Net.IPAddress]::Parse($Ip).GetAddressBytes()[3..0]), 0)
    $mask = if ($bits -eq 0) { 0 } else { [uint32]((0xFFFFFFFFL -shl (32 - $bits)) -band 0xFFFFFFFFL) }
    return ($a -band $mask) -eq ($b -band $mask)
}

Write-Host ''
Write-Host '=== Windows host setup verification (docs/windows-host-setup.md) ===' -ForegroundColor White
Write-Host ''

# --- Phase A: services + clients ---------------------------------------------

foreach ($svc in 'containerd', 'buildkitd') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq 'Running') { Write-Check PASS "service $svc running" }
    elseif ($s) { Write-Check FAIL "service $svc is $($s.Status)" '' "Start-Service $svc  (admin)" }
    else { Write-Check FAIL "service $svc not installed" '' 'Install Stevedore - see host-setup Phase A' }
}

# stevedore IS dockerd. The BuildKit lane does not build through it, but docker.exe
# stays the publish/inspect tool, so Stopped is survivable and still worth knowing.
$stev = Get-Service stevedore -ErrorAction SilentlyContinue
if ($stev -and $stev.Status -eq 'Running') { Write-Check PASS 'service stevedore (dockerd; publish/inspect) running' }
elseif ($stev) {
    Write-Check WARN "docker.exe publish/inspect unavailable - stevedore is $($stev.Status)" `
        'stevedore IS dockerd; builds do not need it, `docker push`/`image inspect` do' `
        'Start-Service stevedore (admin), THEN re-check the CNI subnet below - a dockerd start recreates the nat network'
} else { Write-Check WARN 'stevedore service not installed - docker.exe publish/inspect unavailable' }

$buildctl = Join-Path $StevedoreBin 'buildctl.exe'
if (Test-Path $buildctl) {
    $null = & $buildctl debug workers 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Check PASS 'buildctl reaches buildkitd UNELEVATED (docker-users ACL)' }
    else { Write-Check FAIL 'buildctl cannot reach buildkitd' '' 'buildkitd must run with --group docker-users, and you must be in that group (re-login after adding)' }
} else { Write-Check FAIL "buildctl missing at $buildctl" }

$nerdctl = Join-Path $StevedoreBin 'nerdctl.exe'
if (Test-Path $nerdctl) { Write-Check PASS 'nerdctl present (admin-only by design - containerd pipe)' }
else { Write-Check WARN "nerdctl missing at $nerdctl - run/inspect lane unavailable" }

# --- Phase A5: CNI ------------------------------------------------------------

# BOTH forms are required — corrected 2026-08-07 after this very check told a
# host that conflist-only was healthy while buildkitd was giving containers NO
# network adapter at all. It previously FAILED on a bare .conf and PASSED on
# conflist-only, i.e. it actively drove hosts into the state that breaks the
# production build lane. buildkitd needs the .conf; nerdctl needs the .conflist;
# neither reads the other. See docs/windows-host-setup.md § A5.
$conflist = Join-Path $CniConfDir '0-containerd-nat.conflist'
$bareConf = Join-Path $CniConfDir '0-containerd-nat.conf'
$haveList = Test-Path $conflist
$haveConf = Test-Path $bareConf
$confText = ''

if ($haveConf) {
    Write-Check PASS 'CNI .conf present (buildkitd reads this one)'
    $confText = Get-Content $bareConf -Raw
} else {
    Write-Check FAIL 'CNI .conf MISSING - buildkitd containers get NO network adapter' `
        'not a DNS fault: empty ipconfig, "unreachable network" on a raw TCP connect, no networking block in the HCS spec (measured 2026-08-07)' `
        "Copy-Item '$conflist' '$bareConf' (then edit to the single-plugin form) ; Restart-Service buildkitd -Force  (admin)"
}

if ($haveList) {
    Write-Check PASS 'CNI .conflist present (nerdctl reads this one)'
    if (-not $confText) { $confText = Get-Content $conflist -Raw }
} else {
    # Not fatal for the build lane: the chain builds on the .conf alone. Only
    # the nerdctl lane (image admin, run/exec) is lost.
    Write-Check WARN 'CNI .conflist missing - nerdctl will PANIC (index out of range [0] with length 0)' `
        'the buildctl chain still builds; only the nerdctl lane is unusable' `
        'add the plugins[] conflist form alongside the .conf - template in host-setup A5'
}

if ($haveConf -and $haveList) {
    # Presence is checked; CONTENT drift between the two is not, and nothing
    # else checks it either. Cheap comparison of the load-bearing field.
    $subnetConf = ([regex]::Match((Get-Content $bareConf -Raw), '"subnet"\s*:\s*"([^"]+)"')).Groups[1].Value
    $subnetList = ([regex]::Match((Get-Content $conflist -Raw), '"subnet"\s*:\s*"([^"]+)"')).Groups[1].Value
    if ($subnetConf -and $subnetList -and $subnetConf -ne $subnetList) {
        Write-Check FAIL "CNI .conf and .conflist disagree on the subnet ($subnetConf vs $subnetList)" `
            'the two clients would attach containers to different networks' `
            'make both files carry the same ipam.subnet/GW, then Restart-Service buildkitd -Force  (admin)'
    } else {
        Write-Check PASS 'CNI .conf and .conflist agree on the subnet'
    }
}

if ($confText) {
    $subnet = ([regex]::Match($confText, '"subnet"\s*:\s*"([^"]+)"')).Groups[1].Value
    $adapter = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -match '^vEthernet \(nat\)$' } | Select-Object -First 1 -ExpandProperty IPAddress)
    if (-not $adapter) { Write-Check WARN 'no vEthernet (nat) adapter - cannot judge subnet drift' }
    elseif (Test-IpInCidr -Ip $adapter -Cidr $subnet) { Write-Check PASS "CNI subnet matches the live nat adapter ($subnet <- $adapter)" }
    else {
        Write-Check FAIL "CNI subnet drift: conf pins $subnet, adapter is $adapter" `
            'containers get unroutable IPs - the first downloading RUN dies with "remote name could not be resolved"' `
            'update ipam.subnet/GW to the adapter, then Restart-Service buildkitd -Force (admin)'
    }
}

# --- Phase C: shim, gcpolicy, service config ---------------------------------

# Shim identity: SHA256 against what Publish-ShimPatch.ps1 recorded at install
# time, exactly like the BK driver's Assert-ShimPatch gate (2026-08-07). The
# state path comes from the SHARED helper so there is one definition of where
# that file lives. Size is only the fallback for a host that has not re-run the
# deploy script since — and saying "still guessing" out loud is the point: this
# script exists to hand a fresh machine a verdict, not a maybe.
$shim = Join-Path $StevedoreBin 'containerd-shim-runhcs-v1.exe'
$shimFix = 'pwsh -File windows\scripts\host\Publish-ShimPatch.ps1 -ShimPath <build>  (admin)'
if (-not (Test-Path $shim)) {
    Write-Check FAIL "runhcs shim missing at $shim"
} else {
    $size = (Get-Item $shim).Length
    $shimState = $null
    try {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
        $shimStatePath = Get-ShimPatchStatePath
        if (Test-Path $shimStatePath) { $shimState = Get-Content $shimStatePath -Raw | ConvertFrom-Json }
    } catch {
        Write-Check WARN 'could not read the recorded shim hash' $_.Exception.Message
    }
    if ($shimState -and $shimState.sha256 -and $shimState.shimPath -eq $shim) {
        $liveHash = (Get-FileHash -Algorithm SHA256 -Path $shim).Hash
        if ($liveHash -eq $shimState.sha256) {
            Write-Check PASS ('runhcs shim matches the deployed patch (SHA256 {0}…, deployed {1})' -f $liveHash.Substring(0, 12), $shimState.deployedAt)
        } elseif ($shimState.stockSha256 -and $liveHash -eq $shimState.stockSha256) {
            Write-Check FAIL 'runhcs shim was REVERTED TO STOCK - the teardown-timeout patch is gone' `
                'heavy media layers WILL fail with hcsshim::ExportLayer 0x3, hours into a build' $shimFix
        } else {
            Write-Check FAIL ('runhcs shim CHANGED since deployment (recorded {0}…, live {1}…)' -f $shimState.sha256.Substring(0, 12), $liveHash.Substring(0, 12)) `
                'most likely a Stevedore/containerd update; the patch cannot be assumed present' $shimFix
        }
    } elseif ($PatchedShimSize -contains $size) {
        Write-Check WARN ('runhcs shim looks PATCHED by SIZE only ({0:N0} bytes) - no recorded hash on this host' -f $size) `
            'the size table rots as hcsshim moves; record the hash instead' `
            'pwsh -File windows\scripts\host\Publish-ShimPatch.ps1 -ShimPath <build>  (admin) - writes the hash state file'
    } elseif ($StockShimSize -contains $size) {
        Write-Check FAIL ('runhcs shim is STOCK ({0:N0} bytes) - the teardown-timeout patch was reverted' -f $size) `
            'heavy media layers WILL fail with hcsshim::ExportLayer 0x3, hours into a build' $shimFix
    } else {
        Write-Check WARN ('runhcs shim size {0:N0} is neither known-patched nor known-stock, and no hash is recorded' -f $size) `
            'probably a newer patched build; re-run Publish-ShimPatch.ps1 to record its hash' $shimFix
    }
}

# Safe property reads: a registry value that does not EXIST (e.g. the
# Environment value on a host that never ran apply-containerd-config) throws
# PropertyNotFound on member access, which under Set-StrictMode surfaces later
# as an unset-variable error and CRASHED this script mid-run (2026-08-09),
# silently skipping the two checks below. .PSObject.Properties.Name -contains
# avoids the throw entirely and turns "absent" into the honest WARN.
$cProps = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd' -ErrorAction SilentlyContinue
$cEnv = if ($cProps -and $cProps.PSObject.Properties.Name -contains 'Environment') { @($cProps.Environment) } else { @() }
if ($cEnv -and ($cEnv -join ';') -match 'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=') {
    Write-Check PASS 'containerd service carries the shim teardown env var'
} else {
    Write-Check WARN 'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT not set on the containerd service' `
        'REQUIRED for a shim built from the upstream patch (its defaults stay 30s); harmless for a fixed-constant build' `
        'pwsh -File windows\scripts\host\Set-ContainerdConfig.ps1  (admin)'
}

$cImage = if ($cProps) { [string]$cProps.ImagePath } else { '' }
if ($cImage -match '--log-level\s+debug') { Write-Check PASS 'containerd debug logging on (owner policy)' }
else { Write-Check WARN 'containerd debug logging OFF' 'the next snapshotter incident will carry no evidence' 'pwsh -File windows\scripts\host\Set-ContainerdConfig.ps1  (admin)' }

if (Test-Path $buildctl) {
    $workers = & $buildctl debug workers -v 2>&1 | Out-String
    if ($workers -match 'snapshotter:\s*windows') { Write-Check PASS 'buildkit worker uses the windows snapshotter' }
    else { Write-Check WARN 'buildkit worker snapshotter is not "windows"' ($workers -split "`n" | Select-String 'snapshotter' | Select-Object -First 1) }
    if ($workers -match 'Minimum free space') { Write-Check PASS 'gcpolicy active on the worker' }
    else { Write-Check FAIL 'no gcpolicy on the worker - the store will grow until the disk dies' '' 'pwsh -File windows\scripts\host\Set-BuildkitdGcpolicy.ps1 -Force  (admin)' }
}

# --- Phase D: runtime preconditions -------------------------------------------

# Every drive the build uses, not just C: — the layer stores live on C:, but the
# repo checkout (the build context) may sit on a VHDX-backed volume with its own
# exhaustion mode, which a C:-only check cannot see. Mirrors Assert-DiskHeadroom.
$repoDrive = (Get-Item (Split-Path $scriptAssetRoot -Parent)).PSDrive.Name
foreach ($driveLetter in (@('C', $repoDrive) | Select-Object -Unique)) {
    $psDrive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
    if (-not $psDrive -or $null -eq $psDrive.Free) { continue }
    $freeGb = [math]::Round($psDrive.Free / 1GB, 1)
    $role = if ($driveLetter -eq 'C') { 'layer stores' } else { 'repo/build context' }
    if ($freeGb -ge $MinFreeGb) {
        Write-Check PASS "disk headroom ${driveLetter}: ${freeGb} GB (min ${MinFreeGb}, ${role})"
    } else {
        Write-Check FAIL "disk headroom ${driveLetter}: ${freeGb} GB is below ${MinFreeGb} GB (${role})" `
            'below ~25 GB hcsshim fails in ways that do not look like a disk problem' `
            'buildctl prune --free-storage <MB ABOVE total disk size - it is a minimum-free TARGET>; for a VHDX-backed volume: windows\scripts\host\Optimize-HostVhdx.ps1'
    }
}

if ($SccacheEndpoint) {
    try {
        $code = (Invoke-WebRequest -Uri $SccacheEndpoint -Method Head -TimeoutSec 5 -UseBasicParsing).StatusCode
        Write-Check PASS "sccache endpoint reachable ($SccacheEndpoint -> HTTP $code)"
    } catch { Write-Check FAIL "sccache endpoint unreachable: $SccacheEndpoint" $_.Exception.Message 'dufs C:\sccache-cache -A -p 5000, and use a LAN IP (not localhost)' }
} else { Write-Check WARN 'no sccache endpoint given' 'media builds require it unless -NoSccache is deliberate' 'pass -SccacheEndpoint or set SCCACHE_WEBDAV_ENDPOINT' }

# Reported, never skipped: absence must not look like success.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $ex = @((Get-MpPreference).ExclusionPath)
    $want = @('C:\ProgramData\containerd', 'C:\ProgramData\buildkitd')
    $missing = @($want | Where-Object { $ex -notcontains $_ })
    if ($missing.Count -eq 0) { Write-Check PASS 'Defender exclusions present' }
    else { Write-Check WARN ('Defender exclusions MISSING: ' + ($missing -join ', ')) 'load-bearing for the hcs-temp finalize flake family' 'pwsh -File windows\scripts\host\Set-ContainerdConfig.ps1  (admin)' }
} else {
    Write-Check INFO 'Defender exclusions UNKNOWN (needs admin to read)' 're-run elevated to verify - they are load-bearing'
}

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host ("VERDICT: {0} FAILED check(s), {1} warning(s) - this host is NOT ready." -f $script:Fail, $script:Warn) -ForegroundColor Red
    exit 1
}
Write-Host ("VERDICT: all required checks passed ({0} warning(s))." -f $script:Warn) -ForegroundColor Green
exit 0
