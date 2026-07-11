# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# PS 5.1 turns native stderr under $ErrorActionPreference='Stop' into terminating
# NativeCommandErrors mid-docker-run (a documented trap on this lane) -- require pwsh 7
# up front instead of failing confusingly hours into a build.
#Requires -Version 7.0

<#
.SYNOPSIS
    Builds the Windows container image chain: base -> [nvidia] -> toolchain -> media -> final.

.DESCRIPTION
    Single driver for the staged Windows build (see docs/windows-builds.md).
    Reads canonical versions from linux/scripts/01-core/versions.env and passes
    them as --build-arg so the Dockerfile ARG defaults can never drift from the
    single source of truth.

    Layer caching is ON by default — the Dockerfiles are ordered so that script
    edits only invalidate their own stage. Use -NoCache for a deliberate clean
    rebuild.

    The media stage fans out into three branch images (media-core:
    ONNX->GenAI->OpenCV->FFmpeg; media-litert: LiteRT->LiteRT-LM; media-tvm: TVM),
    built sequentially -- media-core first, so it alone gets the whole RAM budget,
    which maximizes ONNX parallelism -- then fans in via
    Dockerfile.media-merge-builder (merge + GStreamer).

    The former Dockerfile.sdk no-op shim is replaced by a `docker tag`:
      - CPU lane (default): windows-base is tagged as windows-sdk.
      - GPU lane (-Gpu):    Dockerfile.nvidia builds FROM windows-base and is
                            tagged windows-sdk (requires the TensorRT zip in
                            windows/downloads/, see versions.env).

.PARAMETER Gpu
    Build the NVIDIA GPU layer (CUDA + cuDNN + TensorRT) as the sdk stage.

.PARAMETER NoCache
    Pass --no-cache to every docker build (full rebuild).

.PARAMETER Stages
    Subset of stages to build (default: all, in order): base, sdk, toolchain, media, final.

.PARAMETER MediaBranches
    Subset of the media fan-out to (re)build within the 'media' stage (default: all
    three): media-core, media-litert, media-tvm. Use this to rebuild ONE branch after a
    source fix without recompiling the others -- e.g. -MediaBranches media-litert rebuilds
    only the LiteRT/LiteRT-LM branch; the media merge that follows still fans in the other
    branches from their existing images. Unselected branches must already be built (their
    windows-media-<branch> image must exist) for the merge to succeed.

.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, then the Stevedore install
    locations, then docker on PATH.

.PARAMETER FinalTag
    Tag for the final developer image.

.PARAMETER MediaMemoryGb
    --memory limit (GB) for the run+commit stages (media-core, toolchain, and the
    merge/GStreamer stage; the aux branches also get this full budget, since
    media-core has already committed by the time they run).
    Forwarded as MEMORY_LIMIT_GB so the build scripts scale
    parallelism to the cap. Default 0 = AUTO-DETECT from host RAM: usable physical
    GB minus -HostReserveGb. Since
    media-core parallelism is memory-bound (jobs = min(cpu-count, mem/per-job-GB),
    ONNX ~4 GB/job), maximizing this is what actually raises the ONNX job count.
    Pass an explicit value to override the auto-detection.

.PARAMETER HostReserveGb
    RAM (GB) to leave for the Windows host when auto-detecting -MediaMemoryGb
    (default 22). This is NOT just idle Windows: during a GPU build dockerd +
    containerd juggling the ~50 GB CUDA image layers, plus svchost/Defender, hold
    ~16-18 GB steady on this host — measured after a 53 GB container starved the
    host to 0.3 GB free and hung media-core at 0% CPU. 22 GB reserve keeps the
    container (~39 GB here) + host comfortably under physical RAM. Lower it only if
    you have verified the host's real footprint is smaller (riskier: under memory
    pressure the container starves and the compile deadlocks / hcsshim ttrpc wedges).

.PARAMETER MediaCoreCpus
    CPU count for EVERY run+commit stage (docker run --cpu-count N): media-core, the
    sequential aux branches, the toolchain (CPython), and the merge/GStreamer stage.
    (Named for its original media-core-only scope; kept for CLI compatibility.)
    Defaults to the host's logical processor count ([Environment]::ProcessorCount)
    so the heavy compile uses all cores automatically; pass a smaller value to cap
    it. `docker build` is hard-capped at 2 CPUs on this host and process isolation
    cannot commit layers, so media-core builds via docker run + docker commit,
    which DOES honor --cpu-count under Hyper-V. NOTE: actual ninja parallelism is
    min(MediaCoreCpus, MediaMemoryGb / per-job-GB), so it is MEMORY-bound, not
    core-bound — ONNX is ~4 GB/job, so at 48 GB it runs ~j12 even with 32 cores.
    More cores only help the lighter TUs (OpenCV/FFmpeg); true j32 on ONNX needs
    ~128 GB RAM, which this host does not have.

.PARAMETER SccacheEndpoint
    Optional sccache WebDAV endpoint reachable FROM INSIDE build containers
    (e.g. http://<host-lan-ip>:5000). Enables a persistent cross-build compile
    cache; empty disables sccache entirely (a container-local cache would only
    bloat layers). See docs/windows-builds.md § Persistent compile cache.

.EXAMPLE
    .\windows\build.ps1 -Gpu
.EXAMPLE
    .\windows\build.ps1 -Gpu -Stages media,final   # iterate on media only
.EXAMPLE
    .\windows\build.ps1 -Gpu -Stages media,final -MediaBranches media-litert
    # rebuild ONLY the litert branch (full cores via run+commit), re-merge, re-final
.EXAMPLE
    .\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
#>
param(
    [switch]$Gpu,
    [switch]$NoCache,
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'final')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'final'),
    [ValidateSet('media-core', 'media-litert', 'media-tvm')]
    [string[]]$MediaBranches = @('media-core', 'media-litert', 'media-tvm'),
    [string]$Docker = '',
    [string]$FinalTag = '',
    [int]$MediaMemoryGb = 0,
    [int]$HostReserveGb = 22,
    [int]$MediaCoreCpus = [Environment]::ProcessorCount,
    # Skip the media-branch fan-out and run ONLY the fan-in (merge + GStreamer) + final on the
    # EXISTING windows-media-<branch> images. Use to re-merge/re-final after updating a branch image
    # out-of-band (e.g. an incremental component rebuild committed straight onto windows-media-core)
    # without paying to recompile the whole branch. All three branch images must already exist.
    [switch]$SkipMediaBranches,
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
    # Disable the per-run host resource log (CPU/RAM/commit/vmmem sampled every 20s into
    # out\windows-build-logs\resources-<ts>.csv, tagged with the current build phase, plus an
    # end-of-run per-phase exhaustion summary). On by default -- the cost is one idle pwsh.
    [switch]$NoResourceLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot

# Single log directory for every stage (docker build stage logs + run+commit logs) --
# previously split between %TEMP% and out\windows-build-logs, computed at three sites.
$script:LogDir = Join-Path $repoRoot 'out\windows-build-logs'
New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null

# ---- per-run host resource log (which steps exhaust the machine?) ----
# A detached sampler (windows/scripts/build-resource-sampler.ps1) appends CPU/RAM/commit/vmmem
# rows every 20s, tagged with the CURRENT PHASE via a state file that Set-BuildPhase rewrites at
# every docker build / run / commit chokepoint. The finally block stops the sampler and prints a
# per-phase exhaustion summary (also available later: the sampler script's -Summarize mode).
$script:ResourceCsv = $null
$script:SamplerProc = $null
$script:PhaseFile = Join-Path $script:LogDir 'current-phase.txt'
function Set-BuildPhase {
    param([Parameter(Mandatory)][string]$Name)
    # Best-effort: phase tagging must never fail a build.
    try { Set-Content -Path $script:PhaseFile -Value $Name -ErrorAction Stop } catch { Write-Verbose "phase write skipped: $_" }
}
if (-not $NoResourceLog) {
    $script:ResourceCsv = Join-Path $script:LogDir ("resources-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".csv")
    Set-BuildPhase 'init'
    $samplerScript = Join-Path $PSScriptRoot 'scripts\build-resource-sampler.ps1'
    $script:SamplerProc = Start-Process -FilePath ((Get-Process -Id $PID).Path) -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', $samplerScript,
        '-CsvPath', $script:ResourceCsv, '-PhaseFile', $script:PhaseFile, '-IntervalSeconds', '20')
    Write-Host "Resource log: $script:ResourceCsv (20s samples, phase-tagged; disable with -NoResourceLog)"
}

# Transient hcsshim/containerd failures ("failed to create shim task: ttrpc:
# closed") intermittently kill container creation, typically right after a big
# layer commit. Both Invoke-Stage and the media fan-out classify failures against
# this single pattern.
$script:TransientPattern = 'ttrpc: closed|failed to create shim task|failed to create task for container|hcsshim|error during connect'

# CPU note: Hyper-V-isolated build containers get only 2 CPUs, pinning every
# in-container `ninja -j` to 2 (Get-BuildJobCount = min(ProcessorCount, memGB/perJob)).
# `docker build` on this host's classic builder offers NO working lever to raise it
# (--cpu-count rejected, --cpuset-cpus fails), and --isolation process — which would
# expose all host CPUs — cannot commit layers here (hcsshim::ActivateLayer 0x20). So
# `docker build` stages run at 2 CPUs. Raising this requires a docker-run+commit
# path (docker run --cpu-count N does honor the flag under Hyper-V).

# ---- resolve docker CLI (Stevedore's docker.exe preferred; nerdctl build has broken DNS) ----
if ([string]::IsNullOrWhiteSpace($Docker)) {
    $candidates = @(
        $env:DOCKER_EXE,
        'D:\Stevedore\bin\docker.exe',
        (Join-Path $env:ProgramFiles 'Stevedore\bin\docker.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Docker = if ($candidates) { @($candidates)[0] } else { (Get-Command docker -ErrorAction Stop).Source }
}
Write-Host "Using docker: $Docker"

# ---- load canonical versions (single source of truth) ----
$versionsFile = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'
if (-not (Test-Path $versionsFile)) { throw "versions.env not found at $versionsFile" }
$versions = @{}
Get-Content $versionsFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^#') {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $versions[$parts[0].Trim()] = $parts[1].Trim().Trim('"', "'") }
    }
}
function Get-Ver([string]$Name) {
    if (-not $versions.ContainsKey($Name)) { throw "versions.env is missing $Name" }
    return $versions[$Name]
}

# NVIDIA versions are shared with Linux (full semvers in versions.env).
# Windows consumes the dotted major.minor (13.3) derived here; Linux derives
# its apt hyphen form (13-3) inside linux/Dockerfile.nvidia.
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# Default the final image tag from the canonical registry prefix so it can never
# drift from versions.env. Override with -FinalTag.
if ([string]::IsNullOrWhiteSpace($FinalTag)) {
    $FinalTag = (Get-Ver 'IMAGE_REGISTRY_PREFIX') + ':winamd64'
}

function Get-DockerBuildArgList {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @(),
        # Build-context directory. Default repo root; Dockerfile.nvidia passes `windows` so the
        # ~2 GB TensorRT zip (root-.dockerignore'd) rides ONLY in that one build's context.
        [string]$Context = '.'
    )
    # NB: no --progress flag — Stevedore's classic builder (no BuildKit on
    # Windows Containers) rejects it.
    $dockerArgs = @('build')
    if ($NoCache) { $dockerArgs += '--no-cache' }
    # NB: we deliberately do NOT pass --isolation process. On this host process
    # isolation cannot commit ANY file-writing layer: hcsshim::ActivateLayer fails
    # 0x20 ("file used by another process"), reproduced even for a 100 MB dummy
    # layer and NOT caused by Defender/Search/SysMain (all ruled out). Hyper-V
    # isolation (the default) commits reliably but is hard-capped at 2 CPUs for
    # `docker build` (--cpu-count is rejected, --cpuset-cpus fails). Getting >2 CPUs
    # needs a `docker run --cpu-count N` + `docker commit` path, not a build flag.
    # See docs/windows-builds.md § Build isolation and CPU parallelism.
    foreach ($key in ($BuildArgs.Keys | Sort-Object)) {
        $value = $BuildArgs[$key]
        if ($null -ne $value -and "$value" -ne '') { $dockerArgs += '--build-arg', "$key=$value" }
    }
    $dockerArgs += $ExtraFlags
    $dockerArgs += '-t', $Tag, '-f', $Dockerfile, $Context
    return $dockerArgs
}

function Test-TransientDockerFailure {
    # Single source of truth for the "is this a transient container-infrastructure failure?"
    # decision (ttrpc/shim/hcsshim/pipe — see $script:TransientPattern).
    param([string]$Tail)
    return [bool]($Tail -and ($Tail -match $script:TransientPattern))
}

function Assert-ImageExists {
    # Pre-flight guard for stages that consume images built in EARLIER runs (e.g. a -MediaBranches
    # subset: the merge fans in the unselected branches from their existing windows-media-<branch>
    # images). Without this, a missing prerequisite only surfaces at the merge's COPY --from --
    # AFTER hours of branch compile. Fail fast instead.
    param(
        [Parameter(Mandatory)] [string[]]$Tags,
        [Parameter(Mandatory)] [string]$Context
    )
    $missing = @($Tags | Where-Object {
            & $Docker image inspect $_ 2>&1 | Out-Null
            $LASTEXITCODE -ne 0
        })
    if ($missing.Count -gt 0) {
        throw "$Context requires existing image(s) not found locally: $($missing -join ', ') -- build them first (see -Stages / -MediaBranches / -SkipMediaBranches in the help)"
    }
}

function Invoke-TransientCooldown {
    # Shared transient-failure decision for the docker retry loops (Invoke-Stage +
    # Invoke-RunCommitStage). Returns $true when the captured tail looks like a transient
    # container-infrastructure failure AND a retry remains -- after sleeping the cooldown --
    # so the caller can `continue`; $false means treat it as a hard failure (throw). The
    # divergent success/cleanup paths stay in each caller; only the transient-detect +
    # message + cooldown policy is centralized here.
    param(
        [Parameter(Mandatory)] [string]$Tail,
        [Parameter(Mandatory)] [int]$Attempt,
        [int]$MaxAttempts = 3,
        [string]$Label = '',
        [int]$CooldownSeconds = 60
    )
    if ($Attempt -lt $MaxAttempts -and (Test-TransientDockerFailure -Tail $Tail)) {
        Write-Host "[$Label] transient container-infrastructure failure — retry $Attempt/$($MaxAttempts - 1) in ${CooldownSeconds}s" -ForegroundColor Yellow
        Start-Sleep -Seconds $CooldownSeconds
        return $true
    }
    return $false
}

function Invoke-DockerWithRetry {
    # Shared docker retry skeleton behind Invoke-Stage (build) and Invoke-RunCommitStage (run+commit).
    # Runs -Action (returns the exit code to test); on 0 runs -OnSuccess and returns; otherwise reads
    # the -LogFile tail, runs -OnFailedAttempt (per-attempt cleanup, e.g. `container rm`), then either
    # cools down + retries (transient) or throws. Callers build -Action/-OnSuccess with
    # .GetNewClosure() so the scriptblocks capture their function-local vars ($dockerArgs, $runArgs,
    # $ContainerName, ...) when invoked from here -- a plain scriptblock would not see them.
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,   # param($attempt); runs docker, its output streams to the log
        [Parameter(Mandatory)] [string]$Label,
        [string]$LogFile,
        [int]$TailLines = 10,
        [scriptblock]$OnSuccess,
        [scriptblock]$OnFailedAttempt,
        [int]$MaxAttempts = 3
    )
    foreach ($attempt in 1..$MaxAttempts) {
        # Do NOT capture -- let the action's docker output stream through to the console/log (as the
        # inline loops did); read the native exit code from the global $LASTEXITCODE the docker call set.
        & $Action $attempt
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            if ($OnSuccess) { & $OnSuccess }
            return
        }
        $tail = if ($LogFile -and (Test-Path $LogFile)) { Get-Content $LogFile -Tail $TailLines | Out-String } else { '' }
        if ($OnFailedAttempt) { & $OnFailedAttempt }
        if (Invoke-TransientCooldown -Tail $tail -Attempt $attempt -MaxAttempts $MaxAttempts -Label $Label) { continue }
        throw "[$Label] docker step failed (exit $exitCode)"
    }
}

function Invoke-Stage {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @(),
        [string]$Context = '.'
    )
    # Capture output and retry up to twice with a cool-down; cached layers make
    # each retry resume at the failed step. Non-transient errors throw immediately.
    $dockerArgs = Get-DockerBuildArgList -Dockerfile $Dockerfile -Tag $Tag -BuildArgs $BuildArgs -ExtraFlags $ExtraFlags -Context $Context
    # Disambiguate log filename for multi-stage builder: extract --target from extra flags
    # (e.g., `--target media-core` -> `-media-core`) so the shared Dockerfile.media-builder
    # does not overwrite logs between sequential branch builds. Single-target Dockerfiles
    # (base, nvidia, media-merge-builder) produce the plain `stage-<Dockerfile>.log`.
    $targetIdx = [array]::IndexOf($ExtraFlags, '--target')
    $targetSuffix = if ($targetIdx -ge 0 -and $targetIdx -lt $ExtraFlags.Count - 1) { '-' + $ExtraFlags[$targetIdx + 1] } else { '' }
    $stageLog = Join-Path $script:LogDir ("stage-" + [IO.Path]::GetFileName($Dockerfile) + $targetSuffix + ".log")
    Set-BuildPhase ("build:" + [IO.Path]::GetFileName($Dockerfile) + $targetSuffix)
    $dockerExe = $Docker   # local copy: .GetNewClosure() snapshots LOCALS only, not the script-scope $Docker
    $action = {
        param($attempt)
        Write-Host "`n==> docker $($dockerArgs -join ' ')" -ForegroundColor Cyan
        & $dockerExe @dockerArgs 2>&1 | Tee-Object -FilePath $stageLog
    }.GetNewClosure()
    Invoke-DockerWithRetry -Action $action -Label $Dockerfile -LogFile $stageLog
}

# Common per-branch args for the media fan-out
function New-MediaBranchSpec {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BuilderDockerfile,
        [Parameter(Mandatory)][string]$BuilderTag,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$RunScript,
        [Parameter(Mandatory)][string]$Tag,
        [hashtable]$BuildArgs = @{}
    )
    return @{
        Name              = $Name
        BuilderDockerfile = $BuilderDockerfile
        BuilderTag        = $BuilderTag
        ContainerName     = $ContainerName
        RunScript         = $RunScript
        Tag               = $Tag
        BuildArgs         = $BuildArgs
    }
}

function Get-MediaBranchSpecs {
    $sccache = @{ SCCACHE_WEBDAV_ENDPOINT = $SccacheEndpoint }
    $builderDf = 'windows/Dockerfile.media-builder'
    @(
        New-MediaBranchSpec -Name 'media-core' `
            -BuilderDockerfile $builderDf `
            -BuilderTag 'local/kataglyphis:windows-media-core-builder' `
            -ContainerName 'kataglyphis-media-core-build' `
            -RunScript 'build-media-core-all.ps1' `
            -Tag 'local/kataglyphis:windows-media-core' `
            -BuildArgs (@{
                BASE_IMAGE                = 'local/kataglyphis:windows-toolchain'
                ONNXRUNTIME_VERSION       = Get-Ver 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-Ver 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-Ver 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-Ver 'FFMPEG_VERSION'
                NV_CODEC_HEADERS_REF      = Get-Ver 'NV_CODEC_HEADERS_REF'
                CUDA_ARCHITECTURES        = Get-Ver 'CUDA_ARCHITECTURES'
                MEMORY_LIMIT_GB           = $MediaMemoryGb
            } + $sccache)
        New-MediaBranchSpec -Name 'media-litert' `
            -BuilderDockerfile $builderDf `
            -BuilderTag 'local/kataglyphis:windows-media-litert-builder' `
            -ContainerName 'kataglyphis-media-litert-build' `
            -RunScript 'build-litert-all.ps1' `
            -Tag 'local/kataglyphis:windows-media-litert' `
            -BuildArgs (@{
                BASE_IMAGE        = 'local/kataglyphis:windows-toolchain'
                LITERT_VERSION    = Get-Ver 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-Ver 'LITERT_LM_VERSION'
                MEMORY_LIMIT_GB   = $MediaMemoryGb
            } + $sccache)
        New-MediaBranchSpec -Name 'media-tvm' `
            -BuilderDockerfile $builderDf `
            -BuilderTag 'local/kataglyphis:windows-media-tvm-builder' `
            -ContainerName 'kataglyphis-media-tvm-build' `
            -RunScript 'build-tvm-from-source.ps1' `
            -Tag 'local/kataglyphis:windows-media-tvm' `
            -BuildArgs (@{
                BASE_IMAGE      = 'local/kataglyphis:windows-toolchain'
                TVM_REF         = Get-Ver 'TVM_REF'
                MEMORY_LIMIT_GB = $MediaMemoryGb
            } + $sccache)
    )
}

function Invoke-RunCommitStage {
    # Generic run+commit builder: the ONLY way to exceed the 2-CPU `docker build`
    # cap on this host while still producing a committable image. `docker build` is
    # hard-capped at 2 CPUs (Hyper-V) and process isolation cannot commit ANY layer
    # (hcsshim::ActivateLayer 0x20 — the wcifs detach bug, re-verify with
    # windows/diagnostics/test-process-isolation-commit.ps1). So:
    #   1. `docker build` a THIN builder image (cheap COPY/clone layers commit fine
    #      under Hyper-V) carrying the sources + build scripts but NO heavy compile.
    #   2. `docker run --isolation hyperv --cpu-count N` the heavy compile — `docker
    #      run` DOES honor --cpu-count under Hyper-V (unlike `docker build`).
    #   3. `docker commit` the container to $ResultTag.
    # There is no per-stage layer cache inside the run; the sccache remote (when set)
    # covers recompilation. Used by media-core, toolchain (CPython), and the
    # media/GStreamer merge. See docs/windows-builds.md § Build isolation and CPU
    # parallelism.
    param(
        [Parameter(Mandatory)] [string]$BuilderDockerfile,
        [Parameter(Mandatory)] [string]$BuilderTag,
        [Parameter(Mandatory)] [string]$ResultTag,
        [Parameter(Mandatory)] [string]$ContainerName,
        [Parameter(Mandatory)] [string[]]$RunCommand,
        [Parameter(Mandatory)] [int]$Cpus,
        [Parameter(Mandatory)] [int]$MemoryGb,
        [hashtable]$BuildArgs = @{},
        [string[]]$BuilderExtraFlags = @(),   # --target etc. for multi-stage builder images
        [string]$Label = '',
        # Mandatory: the retry loop reads this log's tail to classify transient failures --
        # without it, transient infra errors would never be detected (and never retried).
        [Parameter(Mandatory)] [string]$OutLog
    )
    if (-not $Label) { $Label = $ResultTag }

    # 1. Thin builder image via the shared Invoke-Stage (retry + transient handling).
    #    BuilderExtraFlags may carry --target <stage> for the consolidated multi-stage builder.
    Invoke-Stage -Dockerfile $BuilderDockerfile -Tag $BuilderTag -BuildArgs $BuildArgs -ExtraFlags $BuilderExtraFlags

    # 2. Heavy work via docker run, then commit; retry the run only on transient infra errors.
    #    -Action runs the (pre-clean + run) each attempt; -OnSuccess commits + verifies + cleans up;
    #    -OnFailedAttempt removes the container before the cool-down. Closures capture $runArgs etc.
    $runArgs = @('run', '--isolation', 'hyperv', '--cpu-count', "$Cpus", '--memory', "${MemoryGb}g",
        '--name', $ContainerName, $BuilderTag) + $RunCommand
    $dockerExe = $Docker   # local copy: .GetNewClosure() snapshots LOCALS only, not the script-scope $Docker
    $action = {
        param($attempt)
        & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null
        Set-BuildPhase "run:$Label"
        Write-Host "`n==> [$Label] docker run --isolation hyperv --cpu-count $Cpus --memory ${MemoryGb}g (attempt $attempt)" -ForegroundColor Cyan
        & $dockerExe @runArgs 2>&1 | Tee-Object -FilePath $OutLog
    }.GetNewClosure()
    $onSuccess = {
        # The commit is where this host's transient hcsshim/ttrpc flakiness bites hardest (a
        # multi-GB layer commit right after a long run), so give it its own transient retries --
        # and NEVER remove the container until a commit has SUCCEEDED: it holds hours of finished
        # compile work, and deleting it on a transient failure would make manual recovery
        # impossible. On a final failure, keep the container and print the recovery command.
        # NB: deliberately NOT routed through Invoke-DockerWithRetry -- its OnFailedAttempt
        # contract removes the container, the one thing this path must never do. The loop
        # cannot exhaust silently: Invoke-TransientCooldown returns $false exactly when no
        # retry remains (or the failure is non-transient), which throws here.
        Set-BuildPhase "commit:$Label"
        foreach ($commitAttempt in 1..3) {
            $commitOut = & $dockerExe commit $ContainerName $ResultTag 2>&1
            $commitOut | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { break }
            $commitTail = ($commitOut | Select-Object -Last 15) -join "`n"
            if (-not (Invoke-TransientCooldown -Tail $commitTail -Attempt $commitAttempt -MaxAttempts 3 -Label "$Label commit")) {
                throw ("$Label commit failed -- container '$ContainerName' PRESERVED (it holds the finished build). " +
                    "Recover manually: docker commit $ContainerName $ResultTag ; docker container rm -f $ContainerName")
            }
        }
        & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null
        Write-Host "$Label built via run+commit ($Cpus CPUs) -> $ResultTag" -ForegroundColor Green
    }.GetNewClosure()
    $onFailedAttempt = { & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null }.GetNewClosure()
    Invoke-DockerWithRetry -Action $action -OnSuccess $onSuccess -OnFailedAttempt $onFailedAttempt `
        -Label $Label -LogFile $OutLog -TailLines 15
}

function Get-MediaRunCommand {
    # The `powershell -File C:\temp\scripts\<script> [extra args]` invocation array for a run+commit
    # container (media branches, toolchain, and the GStreamer merge all use this exact prefix).
    param(
        [Parameter(Mandatory)] [string]$Script,
        [string[]]$ExtraArgs = @()
    )
    return @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "C:\temp\scripts\$Script") + $ExtraArgs
}

function Invoke-MediaBranchRunCommit {
    # Build one media branch via the run+commit path at full cores and the full
    # $MediaMemoryGb budget (sequential schedule: every branch gets all the RAM).
    # Passes --target <name> so the consolidated Dockerfile.media-builder
    # multi-stage build selects the correct stage.
    param(
        [Parameter(Mandatory)] $Spec,
        [Parameter(Mandatory)] [string]$OutLog
    )
    Invoke-RunCommitStage `
        -BuilderDockerfile $Spec.BuilderDockerfile -BuilderTag $Spec.BuilderTag `
        -ResultTag $Spec.Tag -ContainerName $Spec.ContainerName `
        -RunCommand (Get-MediaRunCommand $Spec.RunScript) `
        -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb -BuildArgs $Spec.BuildArgs `
        -BuilderExtraFlags @('--target', $Spec.Name) `
        -Label $Spec.Name -OutLog $OutLog
}

function Invoke-MediaSequential {
    # Sequential fan-out: media-core first (whole RAM budget -> most ONNX jobs), then each aux branch,
    # ALL via run+commit at full cores. Invoke-RunCommitStage throws on failure, so a failed branch
    # aborts the chain directly. media-core is already committed before the aux branches run, so aux
    # compiles get the full MediaMemoryGb budget (parallelism is memory-bound).
    param($CoreSpec, $AuxSpecs, $CoreLog, $LogDir)
    if ($CoreSpec) {
        Invoke-MediaBranchRunCommit -Spec $CoreSpec -OutLog $CoreLog
    }
    foreach ($spec in $AuxSpecs) {
        Invoke-MediaBranchRunCommit -Spec $spec -OutLog (Join-Path $LogDir "$($spec.Name).log")
    }
}

function Invoke-MediaBranches {
    # Resolve + subset the branch specs, then build sequentially (media-core first
    # with full RAM, then aux branches also at full RAM since media-core committed).
    # -MediaBranches subsets the fan-out (rebuild one branch after a source fix without
    # recompiling the others); the merge that follows still fans in the unselected branches
    # from their existing windows-media-<branch> images.
    $allSpecs = @(Get-MediaBranchSpecs)
    $specs = @($allSpecs | Where-Object { $MediaBranches -contains $_.Name })
    if ($specs.Count -eq 0) { throw "no media branches selected (-MediaBranches: $($MediaBranches -join ', '))" }
    if ($specs.Count -lt $allSpecs.Count) {
        Write-Host "==> media fan-out limited to: $(@($specs | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow
        $unselected = @($allSpecs | Where-Object { $MediaBranches -notcontains $_.Name })
        Assert-ImageExists -Tags @($unselected | ForEach-Object { $_.Tag }) `
            -Context "media merge (unselected branch(es): $(@($unselected | ForEach-Object { $_.Name }) -join ', '))"
    }
    $coreSpec = $specs | Where-Object { $_.Name -eq 'media-core' } | Select-Object -First 1
    $auxSpecs = @($specs | Where-Object { $_.Name -ne 'media-core' })
    $logDir   = $script:LogDir
    $coreLog  = Join-Path $logDir 'media-core.log'

    Invoke-MediaSequential -CoreSpec $coreSpec -AuxSpecs $auxSpecs -CoreLog $coreLog -LogDir $logDir
    Write-Host 'All media branches built.' -ForegroundColor Green
}

# -MediaMemoryGb 0 = auto-detect from host RAM (usable minus host reserve).
# Sequential is the only schedule (media-core runs first with the full budget,
# then aux branches also get full RAM since media-core already committed).
if ($MediaMemoryGb -le 0) {
    $usableGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $reserve  = $HostReserveGb
    $MediaMemoryGb = [math]::Max(8, $usableGb - $reserve)
    if (($usableGb - $reserve) -lt 8) {
        Write-Warning "host RAM ${usableGb}GB minus reserve ${reserve}GB is below the 8GB floor -- using 8GB anyway; the HOST may be starved during the build (free RAM, or lower -HostReserveGb deliberately)."
    }
    Write-Host ("Auto-detected -MediaMemoryGb=${MediaMemoryGb}g (usable ${usableGb}GB - ${reserve}GB reserve; cores=$MediaCoreCpus)") -ForegroundColor Cyan
} else {
    Write-Host ("-MediaMemoryGb=${MediaMemoryGb}g (explicit); cores=$MediaCoreCpus") -ForegroundColor Cyan
}

$started = Get-Date

try {
    if ($Stages -contains 'base') {
        Invoke-Stage -Dockerfile 'windows/Dockerfile.base' -Tag 'local/kataglyphis:windows-base' -BuildArgs @{
            WINDOWS_LTSC      = Get-Ver 'WINDOWS_LTSC'
            VULKAN_VERSION    = Get-Ver 'VULKAN_VERSION'
            CMAKE_VERSION     = Get-Ver 'CMAKE_VERSION'
            # As a --build-arg (not versions.env-baked env): setup-vs runs BEFORE load-versions
            # by design (protects the VS layer from versions.env bumps), so the SDK pin must
            # reach it via ARG -- and changing it SHOULD bust the VS layer.
            WINDOWS_SDK_BUILD = Get-Ver 'WINDOWS_SDK_BUILD'
        }
    }

    if ($Stages -contains 'sdk') {
        if ($Gpu) {
            # Context `windows` (not the repo root): the TensorRT zip is consumed only here, and
            # the root .dockerignore excludes it so no OTHER build uploads the ~2 GB context.
            Invoke-Stage -Dockerfile 'windows/Dockerfile.nvidia' -Context 'windows' -Tag 'local/kataglyphis:windows-sdk' -BuildArgs @{
                BASE_IMAGE               = 'local/kataglyphis:windows-base'
                CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
                CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
                CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
                TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
            }
        } else {
            Write-Host "`n==> CPU lane: tagging windows-base as windows-sdk (no GPU layer)" -ForegroundColor Cyan
            & $Docker tag local/kataglyphis:windows-base local/kataglyphis:windows-sdk
            if ($LASTEXITCODE -ne 0) { throw 'docker tag failed' }
        }
    }

    if ($Stages -contains 'toolchain') {
        # CPython build.bat is CPU-bound, so it uses the run+commit path for full
        # cores instead of the 2-CPU `docker build`. The thin builder clones CPython
        # + writes Directory.Build.props (cheap, IO-bound); the run does the compile.
        $tcLog = Join-Path $script:LogDir 'toolchain.log'
        Invoke-RunCommitStage `
            -BuilderDockerfile 'windows/Dockerfile.toolchain-builder' `
            -BuilderTag    'local/kataglyphis:windows-toolchain-builder' `
            -ResultTag     'local/kataglyphis:windows-toolchain' `
            -ContainerName 'kataglyphis-toolchain-build' `
            -RunCommand    (Get-MediaRunCommand 'build-toolchain-all.ps1') `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs @{
                BASE_IMAGE     = 'local/kataglyphis:windows-sdk'
                PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
            } `
            -Label 'toolchain' -OutLog $tcLog
    }

    if ($Stages -contains 'media') {
        # Fan-out: three branch images sequentially, then fan-in (merge + GStreamer).
        if ($SkipMediaBranches) {
            Write-Host "`n==> [media] -SkipMediaBranches: skipping branch fan-out; re-merging existing windows-media-<branch> images" -ForegroundColor Yellow
            Assert-ImageExists -Tags @((Get-MediaBranchSpecs) | ForEach-Object { $_.Tag }) -Context '-SkipMediaBranches (merge of existing branch images)'
        } else {
            Invoke-MediaBranches
        }
        # The merge stage splits: the fan-in (COPY --from of the three branch trees)
        # MUST be a `docker build` — `docker run` cannot COPY --from — but it is only
        # IO, so 2 CPUs is fine. The CPU-bound GStreamer compile then runs via the
        # run+commit path (Dockerfile.media-merge-builder carries the merged tree +
        # env + GStreamer scripts but does NOT run the compile; the run does).
        $gstLog = Join-Path $script:LogDir 'gstreamer.log'
        Invoke-RunCommitStage `
            -BuilderDockerfile 'windows/Dockerfile.media-merge-builder' `
            -BuilderTag    'local/kataglyphis:windows-media-merge-builder' `
            -ResultTag     'local/kataglyphis:windows-media' `
            -ContainerName 'kataglyphis-media-merge-build' `
            -RunCommand    (Get-MediaRunCommand 'build-gstreamer-from-source.ps1' -ExtraArgs @('-InstallDir', 'C:\runtime', '-LogDir', 'C:\temp\logs')) `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs @{
                BASE_IMAGE                = 'local/kataglyphis:windows-toolchain'
                CORE_IMAGE                = 'local/kataglyphis:windows-media-core'
                LITERT_IMAGE              = 'local/kataglyphis:windows-media-litert'
                TVM_IMAGE                 = 'local/kataglyphis:windows-media-tvm'
                GSTREAMER_VERSION         = Get-Ver 'GSTREAMER_VERSION'
                ONNXRUNTIME_VERSION       = Get-Ver 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-Ver 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-Ver 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-Ver 'FFMPEG_VERSION'
                LITERT_VERSION            = Get-Ver 'LITERT_VERSION'
                LITERT_LM_VERSION         = Get-Ver 'LITERT_LM_VERSION'
                TVM_REF                   = Get-Ver 'TVM_REF'
                MEMORY_LIMIT_GB           = $MediaMemoryGb
            } `
            -Label 'media-merge+gstreamer' -OutLog $gstLog
    }

    if ($Stages -contains 'final') {
        $vcsRef = ''
        # VCS ref is best-effort provenance metadata: any failure (no git, not a repo) -> empty, never fatal.
        try { $vcsRef = (& git rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -ne 0) { $vcsRef = '' } } catch { $vcsRef = '' }
        Invoke-Stage -Dockerfile 'windows/Dockerfile' -Tag $FinalTag -BuildArgs @{
            BASE_IMAGE = 'local/kataglyphis:windows-media'
            BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            VCS_REF    = $vcsRef
        }
    }

    $elapsed = (Get-Date) - $started
    Write-Host ("`nDone in {0:hh\:mm\:ss}. Stages built: {1}{2}" -f $elapsed, ($Stages -join ', '), $(if ($Gpu) { ' (GPU lane)' } else { ' (CPU lane)' }))
}
finally {
    # Stop the resource sampler and print the per-phase exhaustion summary -- ALSO on failure
    # (that is when you most want to know which step ate the machine). Re-runnable later via:
    #   pwsh -File windows/scripts/build-resource-sampler.ps1 -Summarize -CsvPath <csv>
    Set-BuildPhase 'done'
    if ($script:SamplerProc -and -not $script:SamplerProc.HasExited) {
        Stop-Process -Id $script:SamplerProc.Id -Force -ErrorAction SilentlyContinue
    }
    if ($script:ResourceCsv -and (Test-Path $script:ResourceCsv)) {
        & (Join-Path $PSScriptRoot 'scripts\build-resource-sampler.ps1') -Summarize -CsvPath $script:ResourceCsv
    }
    Pop-Location
}
