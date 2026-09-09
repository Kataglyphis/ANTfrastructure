# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Shared SETUP for the LSM / silo boot-hang probes in windows\scripts\diagnostics
# (Find-LsmEventHolder, Get-HostLsm, Get-LsmWaitObject, Get-LsmWaitstack,
# Get-SiloProcesses). Those five scripts each had to find cdb.exe, pick an output
# directory, start a bait container and wait for the silo it creates before they
# could measure anything, and every one of them carried its own copy -- the
# densest clone cluster in the diagnostics scope (2026-09-09).
#
# DELIBERATELY SETUP ONLY. Nothing here runs a debugger command, reads a
# register, captures a dump or enumerates a handle: that is the MEASUREMENT, it
# differs per probe, and it is the part that cannot be re-verified without an
# elevated host, the WinDbg package, a live buildkitd and a container inside its
# ~141 s hang window. Keeping the measurement inline in each probe is what makes
# this module safe to introduce from a static verification alone.
#
# DEPENDENCY-FREE by design, like WindowsTargetArch.Common.psm1: the probes are
# run as `pwsh -File ...` from a bare checkout on a host being diagnosed, so a
# single repo-relative Import-Module must be the whole of their setup cost.
#
# Every function returns a value and takes no mode switches. Where the probes
# genuinely differ -- the silo wait is 180 s here and 900 s there, the bait image
# tag, the output subdirectory -- that difference is an ARGUMENT, and the error
# text a caller emits when a wait times out stays at the caller, because each
# probe tells the operator something different about how to retry.

<#
.SYNOPSIS
    Full path to the WinDbg package's x64 cdb.exe.
.DESCRIPTION
    The WinDbg store package installs under C:\Program Files\WindowsApps in a
    versioned directory, so the path cannot be spelled literally; the amd64
    filter excludes the arm64 payload that ships in the same package.
    Throws when absent -- a probe with no debugger has nothing to report.
.OUTPUTS
    [string] Path to cdb.exe.
#>
function Get-CdbPath {
    $cdb = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter cdb.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -like '*Microsoft.WinDbg*amd64*' } | Select-Object -First 1
    if (-not $cdb) { throw 'cdb.exe not found - winget install Microsoft.WinDbg' }
    return $cdb.FullName
}

<#
.SYNOPSIS
    Resolves and creates a probe's output directory.
.DESCRIPTION
    An empty -OutDir means "the repo's own out\ tree", resolved from this
    module's location so the probes stay runnable from a bare checkout with no
    working-directory assumption.
.PARAMETER OutDir
    Caller's -OutDir. Empty selects the repo-relative default.
.PARAMETER DefaultSubPath
    Repo-relative default. The attach probes share out\lsm-attach; the dump
    probe writes .dmp files and keeps its own out\lsm-dumps.
.OUTPUTS
    [string] The directory, which exists on return.
#>
function Initialize-LsmProbeOutDir {
    param(
        [string]$OutDir = '',
        [string]$DefaultSubPath = 'out\lsm-attach'
    )
    if (-not $OutDir) {
        # <repo>\windows\scripts\modules -> <repo>
        $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
        $OutDir = Join-Path $repoRoot $DefaultSubPath
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    return $OutDir
}

<#
.SYNOPSIS
    Process ids of every wininit.exe currently running (host + existing silos).
.DESCRIPTION
    The silo baseline. Win32_Process.ExecutablePath and .CommandLine are EMPTY
    for silo processes even when elevated (measured 2026-09-01/02), so the
    process TREE is the only thing that identifies a silo: each one adds its own
    wininit.exe, whose services.exe child spawns the silo's svchosts.
.OUTPUTS
    [int[]] Possibly empty.
#>
function Get-WininitProcessId {
    return @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
}

<#
.SYNOPSIS
    Starts a throwaway buildctl solve whose container is the one to inspect.
.DESCRIPTION
    Coordinating an elevated watcher with a build somebody else starts is what
    made the first attempts at this diagnosis miss the hang window entirely, so
    each probe starts its own bait.

    The NONCE build-arg is load-bearing: it keeps every launch a cache MISS. A
    cached solve starts no container, and there would be nothing to attach to.

    Returns the buildctl process. Callers that only need the side effect pipe it
    to Out-Null; Find-LsmEventHolder reports its pid.
.PARAMETER Tag
    Names both the bait context directory under $env:TEMP and the local image
    the solve produces (docker.io/local/kataglyphis:diag-<Tag>-<nonce>), so
    concurrent probes cannot collide and a stray image says which probe left it.
.OUTPUTS
    [System.Diagnostics.Process]
#>
function Start-SiloBaitContainer {
    param(
        [Parameter(Mandatory)][string]$Tag
    )
    $buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
    if (-not (Test-Path $buildctl)) { throw "buildctl not found at $buildctl" }
    $nonce = Get-Date -Format 'yyyyMMddHHmmss'
    $baitDir = Join-Path $env:TEMP "$Tag-bait-$nonce"
    New-Item -ItemType Directory -Force -Path $baitDir | Out-Null
    @'
ARG BASE
FROM ${BASE}
ARG NONCE
RUN echo bait-$NONCE > C:bait.txt
'@ | Set-Content (Join-Path $baitDir 'Dockerfile') -Encoding ascii
    return Start-Process -FilePath $buildctl -PassThru -WindowStyle Hidden -ArgumentList @(
        '--addr', 'npipe:////./pipe/buildkitd', 'build', '--frontend', 'dockerfile.v0'
        '--local', "context=$baitDir", '--local', "dockerfile=$baitDir"
        '--opt', 'build-arg:BASE=mcr.microsoft.com/windows/servercore:ltsc2025'
        '--opt', "build-arg:NONCE=$nonce", '--opt', 'image-resolve-mode=local'
        '--output', "type=image,name=docker.io/local/kataglyphis:diag-$Tag-$nonce"
    )
}

<#
.SYNOPSIS
    Waits for a wininit.exe that was not in the baseline -- i.e. a new silo.
.DESCRIPTION
    Returns the new process, or $null on timeout. Deliberately does NOT throw:
    each probe reacts differently to a missed window (Get-HostLsm warns and
    takes a second idle sample; the rest throw with their own retry advice), and
    that message is the useful half of the failure.
.PARAMETER BaselineProcessId
    Ids from Get-WininitProcessId, captured BEFORE the container was started.
.PARAMETER TimeoutSec
    How long to wait. 900 s when watching for somebody else's build; shorter
    when the probe started its own bait and knows roughly when it lands.
.PARAMETER PollSec
    Interval between samples.
.OUTPUTS
    The wininit CIM instance, or $null.
#>
function Wait-ForNewSilo {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$BaselineProcessId,
        [int]$TimeoutSec = 900,
        [int]$PollSec = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $newWininit = Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" |
            Where-Object { $_.ProcessId -notin $BaselineProcessId } | Select-Object -First 1
        if ($newWininit) { return $newWininit }
        Start-Sleep -Seconds $PollSec
    }
    return $null
}

<#
.SYNOPSIS
    The silo's services.exe, polled for while the silo boots.
.DESCRIPTION
    The wininit appears before its services.exe child does, so the descent has
    to be retried rather than read once. Returns $null after ~20 s; the caller
    throws, because "the silo never got that far" is itself a finding and each
    probe words it differently.
.PARAMETER WininitProcessId
    Pid of the silo's wininit.exe (from Wait-ForNewSilo).
.OUTPUTS
    The services.exe CIM instance, or $null.
#>
function Get-SiloServicesProcess {
    param(
        [Parameter(Mandatory)][int]$WininitProcessId
    )
    $siloServices = $null
    foreach ($i in 1..20) {
        $siloServices = Get-CimInstance Win32_Process -Filter "Name='services.exe' AND ParentProcessId=$WininitProcessId" |
            Select-Object -First 1
        if ($siloServices) { break }
        Start-Sleep -Seconds 1
    }
    return $siloServices
}

<#
.SYNOPSIS
    The silo's svchost processes, oldest first, polled for while it boots.
.DESCRIPTION
    Sorted by CreationDate because the EARLIEST svchosts are the interesting
    ones: one of them hosts DcomLaunch and with it LSM. Callers take as many as
    they want (Get-LsmWaitstack dumps the first three); the count is a call-site
    decision, not a parameter here.

    Returns an empty array after ~40 s rather than throwing, for the same reason
    as Get-SiloServicesProcess.
.PARAMETER ServicesProcessId
    Pid of the silo's services.exe.
.OUTPUTS
    [object[]] svchost CIM instances, oldest first; possibly empty.
#>
function Get-SiloSvchost {
    param(
        [Parameter(Mandatory)][int]$ServicesProcessId
    )
    $svchosts = @()
    foreach ($i in 1..20) {
        $svchosts = @(Get-CimInstance Win32_Process -Filter "Name='svchost.exe' AND ParentProcessId=$ServicesProcessId" |
                Sort-Object CreationDate)
        if ($svchosts.Count -ge 1) { break }
        Start-Sleep -Seconds 2
    }
    return $svchosts
}

Export-ModuleMember -Function @(
    'Get-CdbPath',
    'Initialize-LsmProbeOutDir',
    'Get-WininitProcessId',
    'Start-SiloBaitContainer',
    'Wait-ForNewSilo',
    'Get-SiloServicesProcess',
    'Get-SiloSvchost'
)
