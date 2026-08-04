# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Classic-lane build-driver core, extracted from windows/build.ps1 (2026-08-03
# audit): the docker retry engine (transient classification + cooldown +
# retry skeleton), build-arg list shaping, image preflight, and the isolation
# probe. Lives in a module so the failure-path logic is UNIT-TESTABLE with a
# fake docker (BuildDriver.Retry.Tests.ps1) — these paths only ever executed
# during real multi-hour builds before.
#
# Layer economics: this module is only picked up by the final stage's whole-dir
# modules COPY (cheap). build.ps1 itself is never COPY'd into any image.
#
# Context pattern: build.ps1 calls Initialize-BuildDriverContext once after
# resolving docker; the functions read module scope so the many existing call
# sites keep their signatures. Explicit parameters always win over context.

Set-StrictMode -Version Latest

# Resolve-LatestVersionTag (used by Resolve-TorchAppRef) lives in Shared.
# Import WITHOUT -Force and only if absent: a forced nested re-import rebinds
# Shared into this module's private scope and unloads the caller's top-level
# import (the PS module-scoping trap documented in build-gstreamer's header;
# it broke the BuildDriver test suite on 2026-08-04).
if (-not (Get-Command Resolve-LatestVersionTag -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -DisableNameChecking
}

# Transient hcsshim/containerd failures ("failed to create shim task: ttrpc:
# closed") intermittently kill container creation, typically right after a big
# layer commit. Every retry loop classifies failures against this ONE pattern.
$script:BuildDriverContext = @{
    Docker           = ''
    LogDir           = ''
    NoCache          = $false
    Isolation        = 'hyperv'
    TransientPattern = 'ttrpc: closed|failed to create shim task|failed to create task for container|hcsshim|error during connect'
}

function Initialize-BuildDriverContext {
    param(
        [Parameter(Mandatory)][string]$Docker,
        [Parameter(Mandatory)][string]$LogDir,
        [switch]$NoCache,
        [string]$TransientPattern = ''
    )
    $script:BuildDriverContext.Docker  = $Docker
    $script:BuildDriverContext.LogDir  = $LogDir
    $script:BuildDriverContext.NoCache = [bool]$NoCache
    if ($TransientPattern) { $script:BuildDriverContext.TransientPattern = $TransientPattern }
}

function Set-BuildDriverIsolation {
    param([Parameter(Mandatory)][ValidateSet('process', 'hyperv')][string]$Isolation)
    $script:BuildDriverContext.Isolation = $Isolation
}

function Test-TransientDockerFailure {
    # Single source of truth for the "is this a transient container-infrastructure
    # failure?" decision (ttrpc/shim/hcsshim/pipe).
    param([string]$Tail)
    return [bool]($Tail -and ($Tail -match $script:BuildDriverContext.TransientPattern))
}

function Invoke-TransientCooldown {
    # Shared transient-failure decision for the docker retry loops. Returns $true
    # when the captured tail looks transient AND a retry remains -- after sleeping
    # the cooldown -- so the caller can `continue`; $false means hard failure.
    param(
        [Parameter(Mandatory)] [string]$Tail,
        [Parameter(Mandatory)] [int]$Attempt,
        [int]$MaxAttempts = 3,
        [string]$Label = '',
        [int]$CooldownSeconds = 60,
        # Caller already classified the failure as transient (e.g.
        # Invoke-DockerWithRetry, which gates its retry branch on
        # Test-TransientDockerFailure itself) — skip the re-test so the
        # condition is expressed exactly ONCE per call path.
        [switch]$AssumeTransient
    )
    if ($Attempt -lt $MaxAttempts -and ($AssumeTransient -or (Test-TransientDockerFailure -Tail $Tail))) {
        Write-Host "[$Label] transient container-infrastructure failure — retry $Attempt/$($MaxAttempts - 1) in ${CooldownSeconds}s" -ForegroundColor Yellow
        Start-Sleep -Seconds $CooldownSeconds
        return $true
    }
    return $false
}

function Invoke-DockerWithRetry {
    # Shared docker retry skeleton behind Invoke-Stage (build) and
    # Invoke-RunCommitStage (run+commit). Runs -Action; on exit 0 runs -OnSuccess
    # and returns; otherwise reads the -LogFile tail, runs -OnFailedAttempt
    # (per-attempt cleanup) then either cools down + retries (transient) or runs
    # -OnFinalFailure and throws. Callers build the scriptblocks with
    # .GetNewClosure() so they capture their function-local vars when invoked
    # from here.
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,   # param($attempt); runs docker, output streams to the log
        [Parameter(Mandatory)] [string]$Label,
        [string]$LogFile,
        [int]$TailLines = 10,
        [scriptblock]$OnSuccess,
        # Per-attempt cleanup, run ONLY when a transient retry will actually re-run
        # the action (e.g. `container rm` before the next `docker run`). It does NOT
        # fire on the FINAL failure — a run+commit container holding hours of
        # finished stages must survive a non-transient compile failure for resume.
        [scriptblock]$OnFailedAttempt,
        # Runs once before the terminal throw (no retry left / non-transient error),
        # e.g. to print a recovery recipe for the preserved container.
        [scriptblock]$OnFinalFailure,
        [int]$MaxAttempts = 3,
        [int]$CooldownSeconds = 60
    )
    foreach ($attempt in 1..$MaxAttempts) {
        # Do NOT capture -- let the action's docker output stream through to the
        # console/log; read the native exit code the docker call set.
        & $Action $attempt
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            if ($OnSuccess) { & $OnSuccess }
            return
        }
        $tail = if ($LogFile -and (Test-Path $LogFile)) { Get-Content $LogFile -Tail $TailLines | Out-String } else { '' }
        if ($attempt -lt $MaxAttempts -and (Test-TransientDockerFailure -Tail $tail)) {
            if ($OnFailedAttempt) { & $OnFailedAttempt }
            # -AssumeTransient: this branch IS the classification; the cooldown
            # helper only owns the message + delay here.
            Invoke-TransientCooldown -Tail $tail -Attempt $attempt -MaxAttempts $MaxAttempts -Label $Label -CooldownSeconds $CooldownSeconds -AssumeTransient | Out-Null
            continue
        }
        if ($OnFinalFailure) { & $OnFinalFailure }
        throw "[$Label] docker step failed (exit $exitCode)"
    }
}

function Get-DockerBuildArgList {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @(),
        # Build-context directory. Default repo root; Dockerfile.nvidia passes
        # `windows` so the ~2 GB TensorRT zip (root-.dockerignore'd) rides ONLY
        # in that one build's context.
        [string]$Context = '.'
    )
    # NB: no --progress flag — Stevedore's classic builder (no BuildKit on
    # Windows Containers) rejects it. Build-args are emitted SORTED: the arg
    # list shape is a docker cache key, keep it deterministic.
    $dockerArgs = @('build')
    if ($script:BuildDriverContext.NoCache) { $dockerArgs += '--no-cache' }
    $dockerArgs += '--isolation', $script:BuildDriverContext.Isolation
    foreach ($key in ($BuildArgs.Keys | Sort-Object)) {
        $value = $BuildArgs[$key]
        if ($null -ne $value -and "$value" -ne '') { $dockerArgs += '--build-arg', "$key=$value" }
    }
    $dockerArgs += $ExtraFlags
    $dockerArgs += '-t', $Tag, '-f', $Dockerfile, $Context
    return $dockerArgs
}

function Assert-ImageExists {
    # Pre-flight guard for stages that consume images built in EARLIER runs.
    # Without this, a missing prerequisite only surfaces at the merge's
    # COPY --from — AFTER hours of branch compile. Fail fast instead.
    param(
        [Parameter(Mandatory)] [string[]]$Tags,
        [Parameter(Mandatory)] [string]$Context
    )
    $docker = $script:BuildDriverContext.Docker
    $missing = @($Tags | Where-Object {
            & $docker image inspect $_ 2>&1 | Out-Null
            $LASTEXITCODE -ne 0
        })
    if ($missing.Count -gt 0) {
        throw "$Context requires existing image(s) not found locally: $($missing -join ', ') -- build them first (see -Stages / -MediaBranches / -SkipMediaBranches in the help)"
    }
}

function Resolve-BuildIsolation {
    # PROCESS isolation is always preferred (full host CPUs for docker build AND
    # docker run), but only usable when the host can COMMIT process-isolated
    # layers: on wcifs-skew hosts every stage dies at its first commit. 'auto'
    # runs the ~10s commit probe and caches the verdict per (host build, docker
    # version); a Windows update or Docker upgrade re-probes automatically.
    param(
        [Parameter(Mandatory)][ValidateSet('auto', 'process', 'hyperv')][string]$Isolation,
        [Parameter(Mandatory)][string]$Docker,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$ProbeScript
    )
    if ($Isolation -ne 'auto') {
        Write-Host "Isolation: $Isolation (forced via -Isolation)" -ForegroundColor Cyan
        return $Isolation
    }
    $hostInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $dockerVer = (& $Docker version --format '{{.Server.Version}}' 2>$null | Select-Object -First 1)
    $cacheKey = '{0}.{1}|{2}' -f $hostInfo.CurrentBuildNumber, $hostInfo.UBR, $dockerVer
    $cacheFile = Join-Path $LogDir 'isolation-probe-cache.json'
    if (Test-Path $cacheFile) {
        try {
            $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
            if ($cached.key -eq $cacheKey) {
                Write-Host ("Isolation: {0} (cached commit-probe verdict for {1})" -f $cached.isolation, $cacheKey) -ForegroundColor Cyan
                return $cached.isolation
            }
        } catch {
            # Best-effort: an unreadable/corrupt verdict cache just re-probes.
            Write-Verbose "isolation verdict cache unreadable, re-probing: $($_.Exception.Message)"
        }
    }
    Write-Host 'Isolation: auto — running the process-isolation commit probe (~10s, verdict cached)...' -ForegroundColor Cyan
    $probeLog = Join-Path $LogDir 'isolation-probe.log'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ProbeScript -Docker $Docker *> $probeLog
    $verdict = $LASTEXITCODE
    $resolved = if ($verdict -eq 0) { 'process' } else { 'hyperv' }
    if ($resolved -eq 'process') {
        Write-Host 'Isolation: PROCESS — commit probe passed; full host CPUs for docker build and docker run.' -ForegroundColor Green
    } else {
        Write-Warning ("process isolation cannot commit layers on this host (probe exit ${verdict}, log: $probeLog) — using hyperv. " +
            'Real fix: build on a Windows Server host whose build matches the base image (see docs/windows-builds.md § Build isolation).')
    }
    @{ key = $cacheKey; isolation = $resolved } | ConvertTo-Json -Compress | Set-Content $cacheFile
    return $resolved
}

# ── Lane-shared version/driver helpers (2026-08-04 dedup) ────────────────────
# Both drivers (build.ps1 classic, build-buildkit.ps1 BK) used to carry hand-
# copied twins of these; the per-branch version→build-arg maps had already
# started drifting. ONE canonical definition lives here — a version pin added
# for one lane can no longer silently miss the other.

function Get-VersionTableValue {
    param(
        [Parameter(Mandatory)][hashtable]$VersionTable,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $VersionTable.Contains($Key)) { throw "versions.env has no key $Key" }
    return $VersionTable[$Key]
}

function Get-MediaBranchVersionArg {
    # The version build-args of one media branch — VERSIONS ONLY (callers add
    # BASE_IMAGE / MEMORY_LIMIT_GB / sccache themselves; those are lane-shaped).
    param(
        [Parameter(Mandatory)][ValidateSet('media-core', 'media-litert', 'media-tvm')][string]$Branch,
        [Parameter(Mandatory)][hashtable]$VersionTable
    )
    switch ($Branch) {
        'media-core' {
            return @{
                ONNXRUNTIME_VERSION       = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-VersionTableValue $VersionTable 'FFMPEG_VERSION'
                PYAV_VERSION              = Get-VersionTableValue $VersionTable 'PYAV_VERSION'
                NV_CODEC_HEADERS_REF      = Get-VersionTableValue $VersionTable 'NV_CODEC_HEADERS_REF'
                CUDA_ARCHITECTURES        = Get-VersionTableValue $VersionTable 'CUDA_ARCHITECTURES'
            }
        }
        'media-litert' {
            return @{
                LITERT_VERSION    = Get-VersionTableValue $VersionTable 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-VersionTableValue $VersionTable 'LITERT_LM_VERSION'
            }
        }
        'media-tvm' {
            return @{
                TVM_REF      = Get-VersionTableValue $VersionTable 'TVM_REF'
                IREE_VERSION = Get-VersionTableValue $VersionTable 'IREE_VERSION'
            }
        }
    }
}

function Get-MediaMergeVersionArg {
    # The merge builder's canonical version env = union of all branch version
    # args MINUS core-branch compile inputs its Dockerfile declares no ARG for,
    # PLUS its own GStreamer pin.
    param([Parameter(Mandatory)][hashtable]$VersionTable)
    $merge = @{}
    foreach ($branch in 'media-core', 'media-litert', 'media-tvm') {
        $args_ = Get-MediaBranchVersionArg -Branch $branch -VersionTable $VersionTable
        foreach ($k in $args_.Keys) {
            if ($k -notin @('NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES')) { $merge[$k] = $args_[$k] }
        }
    }
    $merge['GSTREAMER_VERSION'] = Get-VersionTableValue $VersionTable 'GSTREAMER_VERSION'
    return $merge
}

function Get-BuildVcsRef {
    try { $r = (& git rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -ne 0) { return '' } else { return $r } }
    catch { return '' }
}

function Resolve-TorchAppRef {
    # Orchestr-ANT-ion ref: DETERMINISTIC by default (versions.env APP_REF pin);
    # -LatestApp opts into resolving the app repo's newest release tag at build
    # time, falling back to the pin when offline / no tags match.
    param(
        [Parameter(Mandatory)][hashtable]$VersionTable,
        [switch]$LatestApp
    )
    $ref = Get-VersionTableValue $VersionTable 'APP_REF'
    if ($LatestApp) {
        try {
            $tagRaw = & git ls-remote --tags https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion.git 2>$null
            if ($LASTEXITCODE -eq 0 -and $tagRaw) {
                $latest = Resolve-LatestVersionTag -LsRemoteOutput @($tagRaw)
                if (-not [string]::IsNullOrWhiteSpace($latest)) { $ref = $latest }
            }
        } catch {
            Write-Verbose "ls-remote tag resolution failed, using pinned APP_REF: $($_.Exception.Message)"
        }
        Write-Host "-LatestApp: resolved Orchestr-ANT-ion ref: $ref (versions.env pin: $(Get-VersionTableValue $VersionTable 'APP_REF'))"
    }
    return $ref
}

function Assert-SccacheEndpoint {
    # Fail-fast sccache gate shared by both lanes: compile stages REQUIRE the
    # remote cache unless -NoSccache is a deliberate choice.
    param(
        [Parameter(Mandatory)][string[]]$Stages,
        [string]$SccacheEndpoint = '',
        [switch]$NoSccache
    )
    # 'media' only: the toolchain stage (MSBuild/ClangCL CPython) has no
    # sccache wiring — gating it on the endpoint blocked toolchain-only builds
    # for a cache they never used.
    $compileStages = @('media')
    if ($NoSccache -or @($Stages | Where-Object { $compileStages -contains $_ }).Count -eq 0) { return }
    if ([string]::IsNullOrWhiteSpace($SccacheEndpoint)) {
        throw ('sccache is required for the media stage (the only cross-attempt compile cache). ' +
            'One-time host setup: scoop install dufs; mkdir C:\sccache-cache; dufs C:\sccache-cache -A -p 5000 — then pass ' +
            '-SccacheEndpoint http://<host-lan-ip>:5000 or set SCCACHE_WEBDAV_ENDPOINT machine-wide. ' +
            'Pass -NoSccache only for a deliberate cache-less build.')
    }
    try {
        Invoke-WebRequest -Uri $SccacheEndpoint -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
        Write-Host "sccache endpoint reachable: $SccacheEndpoint" -ForegroundColor Cyan
    } catch {
        throw ("sccache endpoint '$SccacheEndpoint' is not reachable from the host ($($_.Exception.Message)). " +
            'Start the WebDAV server and use a LAN IP reachable from inside containers (not localhost). ' +
            'Pass -NoSccache only for a deliberate cache-less build.')
    }
}

function Get-MediaMemoryBudget {
    # MEMORY_LIMIT_GB auto-detect shared by both lanes: host RAM minus reserve,
    # floor 8 GB; an explicit request always wins.
    param(
        [int]$RequestedGb = 0,
        [int]$HostReserveGb = 22
    )
    if ($RequestedGb -gt 0) { return $RequestedGb }
    $usableGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    return [math]::Max(8, $usableGb - $HostReserveGb)
}

Export-ModuleMember -Function Initialize-BuildDriverContext, Set-BuildDriverIsolation,
    Test-TransientDockerFailure, Invoke-TransientCooldown, Invoke-DockerWithRetry,
    Get-DockerBuildArgList, Assert-ImageExists, Resolve-BuildIsolation,
    Get-VersionTableValue, Get-MediaBranchVersionArg, Get-MediaMergeVersionArg,
    Get-BuildVcsRef, Resolve-TorchAppRef, Assert-SccacheEndpoint, Get-MediaMemoryBudget
