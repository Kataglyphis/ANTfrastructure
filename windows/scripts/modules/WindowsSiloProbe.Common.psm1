# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Setup only for the LSM/silo probes; the measurement itself differs per probe and stays in each.

<#
.SYNOPSIS
    Full path to the WinDbg package's x64 cdb.exe.
.DESCRIPTION
    The store package's path is versioned, so it is globbed, amd64 only; throws when absent.
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
.PARAMETER OutDir
    Caller's -OutDir; empty resolves the repo default from this module's location, not the working directory.
.PARAMETER DefaultSubPath
    Repo-relative default: out\lsm-attach for the attach probes, out\lsm-dumps for the dump probe.
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
    Its own bait, so the watcher cannot miss the hang window; the NONCE build-arg forces a cache miss, hence a container.
.PARAMETER Tag
    Names the bait context dir and the image (diag-<Tag>-<nonce>), so concurrent probes cannot collide.
.PARAMETER PassThru
    Emit the buildctl process object.
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
    $null on timeout rather than a throw: each probe reacts to a missed window with its own advice.
.PARAMETER BaselinePid
    wininit.exe process ids captured BEFORE the container was started.
.PARAMETER TimeoutSec
    How long to wait; shorter when the probe started its own bait.
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
    Silo processes have empty paths even elevated, so it walks the tree wininit -> services -> svchost while the silo boots.
    Oldest first, as one early svchost hosts DcomLaunch and LSM; throws only when services.exe never appears.
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
