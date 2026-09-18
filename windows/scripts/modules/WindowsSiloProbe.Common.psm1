# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Shared SETUP for the LSM / silo boot-hang probes in windows\scripts\diagnostics
# (Find-LsmEventHolder, Get-HostLsm, Get-LsmWaitObject, Get-LsmWaitstack,
# Get-SiloProcesses). Debugger commands, dump capture, register reads and handle
# scans stay in each probe: they are the measurement and differ per probe.

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
    Starts a throwaway buildctl solve whose container is the one to inspect.
.DESCRIPTION
    Coordinating an elevated watcher with a build somebody else starts is what
    made the first attempts at this diagnosis miss the hang window entirely, so
    each probe starts its own bait.

    The NONCE build-arg is load-bearing: it keeps every launch a cache MISS. A
    cached solve starts no container, and there would be nothing to attach to.
.PARAMETER Tag
    Names both the bait context directory under $env:TEMP and the local image
    the solve produces (docker.io/local/kataglyphis:diag-<Tag>-<nonce>), so
    concurrent probes cannot collide and a stray image says which probe left it.
.PARAMETER PassThru
    Emit the buildctl process object. Callers that only need the side effect
    omit it; Find-LsmEventHolder reports its pid.
.OUTPUTS
    [System.Diagnostics.Process] with -PassThru; nothing otherwise.
#>
function Start-SiloBaitContainer {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [switch]$PassThru
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
    $process = Start-Process -FilePath $buildctl -PassThru -WindowStyle Hidden -ArgumentList @(
        '--addr', 'npipe:////./pipe/buildkitd', 'build', '--frontend', 'dockerfile.v0'
        '--local', "context=$baitDir", '--local', "dockerfile=$baitDir"
        '--opt', 'build-arg:BASE=mcr.microsoft.com/windows/servercore:ltsc2025'
        '--opt', "build-arg:NONCE=$nonce", '--opt', 'image-resolve-mode=local'
        '--output', "type=image,name=docker.io/local/kataglyphis:diag-$Tag-$nonce"
    )
    if ($PassThru) { return $process }
}

<#
.SYNOPSIS
    Waits for a wininit.exe that was not in the baseline -- i.e. a new silo.
.DESCRIPTION
    Returns the new process, or $null on timeout. Deliberately does NOT throw:
    each probe reacts differently to a missed window (Get-HostLsm warns and
    takes a second idle sample; the rest throw with their own retry advice), and
    that message is the useful half of the failure.
.PARAMETER BaselinePid
    Ids captured BEFORE the container was started:
    @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
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
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$BaselinePid,
        [int]$TimeoutSec = 900,
        [int]$PollSec = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $newWininit = Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" |
            Where-Object { $_.ProcessId -notin $BaselinePid } | Select-Object -First 1
        if ($newWininit) { return $newWininit }
        Start-Sleep -Seconds $PollSec
    }
    return $null
}

<#
.SYNOPSIS
    The silo's svchost processes, oldest first.
.DESCRIPTION
    Win32_Process.ExecutablePath and .CommandLine are EMPTY for silo processes
    even when elevated (measured 2026-09-01/02), so the process TREE is the only
    thing that identifies a silo. This descends wininit.exe -> its services.exe
    -> their svchost.exe, polling while the silo boots because each level
    appears some seconds after the one above it.

    Sorted by CreationDate because the EARLIEST svchosts are the interesting
    ones: one of them hosts DcomLaunch and with it LSM. Callers take as many as
    they want; the count is a call-site decision, not a parameter here.

    Throws when the services.exe descent itself never lands; an empty array
    otherwise means the silo got no svchost, which is the caller's finding.
.PARAMETER ServicesParentPid
    Pid of the silo's wininit.exe -- the parent of its services.exe.
.PARAMETER TimeoutSec
    Budget for each descent level, in seconds.
.OUTPUTS
    [object[]] svchost CIM instances, oldest first; possibly empty.
#>
function Get-SiloSvchost {
    param(
        [Parameter(Mandatory)][int]$ServicesParentPid,
        [int]$TimeoutSec = 40
    )
    $siloServices = $null
    foreach ($i in 1..$TimeoutSec) {
        $siloServices = Get-CimInstance Win32_Process -Filter "Name='services.exe' AND ParentProcessId=$ServicesParentPid" |
            Select-Object -First 1
        if ($siloServices) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $siloServices) { throw "silo wininit $ServicesParentPid has no services.exe child yet" }

    $svchosts = @()
    foreach ($i in 1..([int]($TimeoutSec / 2))) {
        $svchosts = @(Get-CimInstance Win32_Process -Filter "Name='svchost.exe' AND ParentProcessId=$($siloServices.ProcessId)" |
                Sort-Object CreationDate)
        if ($svchosts.Count -ge 1) { break }
        Start-Sleep -Seconds 2
    }
    return $svchosts
}

Export-ModuleMember -Function @(
    'Get-CdbPath',
    'Initialize-LsmProbeOutDir',
    'Start-SiloBaitContainer',
    'Wait-ForNewSilo',
    'Get-SiloSvchost'
)
