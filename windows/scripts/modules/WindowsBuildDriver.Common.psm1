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
        } catch { }
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

Export-ModuleMember -Function Initialize-BuildDriverContext, Set-BuildDriverIsolation,
    Test-TransientDockerFailure, Invoke-TransientCooldown, Invoke-DockerWithRetry,
    Get-DockerBuildArgList, Assert-ImageExists, Resolve-BuildIsolation
