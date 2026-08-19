#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# PS 5.1 turns native stderr under $ErrorActionPreference='Stop' into terminating
# NativeCommandErrors mid-docker-run (a documented trap on this lane) -- require pwsh 7
# up front instead of failing confusingly hours into a build.

<#
.SYNOPSIS
    Builds the Windows container image chain: base -> [nvidia] -> toolchain -> media -> torch -> final.

.DESCRIPTION
    Single driver for the staged Windows build (see docs/windows-builds.md).
    Reads canonical versions from linux/scripts/01-core/versions.env and passes
    them as --build-arg so the Dockerfile ARG defaults can never drift from the
    single source of truth.

    Layer caching is ON by default — the Dockerfiles are ordered so that script
    edits only invalidate their own stage. Use -NoCache for a deliberate clean
    rebuild.

    The media stage fans out into three branch images (media-core:
    ONNX->GenAI->OpenCV->FFmpeg; media-litert: LiteRT->LiteRT-LM; media-tvm: TVM->IREE),
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
    Subset of stages to build (default: all, in order): base, sdk, toolchain,
    media, torch, final. 'torch' (windows/Dockerfile.torch) assembles the
    Orchestr-ANT-ion app env on the media image; 'final' builds FROM the torch
    image. App-only iteration: `-Stages torch,final` — an APP_REF bump costs
    minutes, never a compile-chain rebuild.

.PARAMETER TorchBaseImage
    Base image for the torch app stage. Default: the local windows-media image.
    Point it at the published :winamd64 ref to iterate the app on a host without
    local chain images (docker pulls it automatically).

.PARAMETER TorchTag
    Tag for the torch app image. Default: the local windows-torch tag, which the
    'final' stage then builds FROM.

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
.EXAMPLE
    .\windows\build.ps1 -Stages torch,final -LatestApp
    # app-only iteration: reassemble Orchestr-ANT-ion at the newest tag + re-final
#>
param(
    [switch]$Gpu,
    [switch]$NoCache,
    # Chain order (stage blocks run in script order regardless of the order given
    # here): base -> sdk -> toolchain -> media -> torch -> final. 'torch'
    # (windows/Dockerfile.torch) assembles the Orchestr-ANT-ion app env on the
    # media image; 'final' builds FROM the torch image and adds the dev trimmings.
    # App-only iteration: -Stages torch,final (the compile chain stays untouched).
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'torch', 'final')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'torch', 'final'),
    # ValidateSet must be literal; keep in lockstep with Get-MediaBranchSpecs -Name values
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
    # ── Scripted resume of a preserved run+commit container ──────────────────
    # After a non-transient mid-chain failure, Invoke-RunCommitStage PRESERVES
    # the container and prints a manual recipe. These parameters EXECUTE that
    # recipe instead of hand-typing it (it was hand-typed 5x on 2026-08-03):
    #   .\windows\build.ps1 -ResumeStage media-litert -ResumeFrom 'LiteRT-LM' `
    #        -CopyFix windows\scripts\build-litert-lm-from-source.ps1
    # Flow: [docker cp each -CopyFix into C:\temp\scripts\] -> commit
    # <tag>-partial -> rm container -> run from the partial with -ResumeFrom ->
    # commit <tag> -> cleanup. Runs INSTEAD of the normal stage chain.
    [ValidateSet('media-core', 'media-litert', 'media-tvm')]
    [string]$ResumeStage = '',
    # Stage name inside the branch chain to resume AT (see the '=== <label>
    # stage: X ===' banners in the stage log). Required with -ResumeStage.
    [string]$ResumeFrom = '',
    # Host-side script files to docker cp into the container's C:\temp\scripts\
    # BEFORE the partial commit (the fix that makes the resume worth running).
    [string[]]$CopyFix = @(),
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
    # Container isolation policy. 'auto' (default) PREFERS process isolation —
    # full host CPUs for docker build AND docker run, no 2-CPU Hyper-V cap — and
    # decides by running the ~10s commit probe
    # (windows/diagnostics/test-process-isolation-commit.ps1, verdict cached per
    # host build + docker version): process when the wcifs layer-commit bug is
    # absent, else hyperv with a loud warning. 'process'/'hyperv' force it.
    [ValidateSet('auto', 'process', 'hyperv')]
    [string]$Isolation = 'auto',
    # sccache is REQUIRED by default for the media stage (the only stage with
    # sccache wiring — toolchain's MSBuild/ClangCL CPython build has none):
    # it is the only cross-attempt cache the run+commit path has. The build
    # fails fast when no reachable -SccacheEndpoint is configured; pass
    # -NoSccache for a deliberate cache-less build.
    [switch]$NoSccache,
    # Resolve the torch-app ref for the final stage from the app repo's LATEST
    # release tag (live `git ls-remote` at build time). Default OFF: the same
    # commit then always builds the same final image from the versions.env
    # APP_REF pin — bump the pin (or pass this switch) to move the app.
    [switch]$LatestApp,
    # Base image for the torch app stage. Default '' = local windows-media (the
    # in-chain parent). Point it at the published image to iterate the app on a
    # host without local chain images (docker pulls it automatically), e.g.
    # -TorchBaseImage ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64.
    [string]$TorchBaseImage = '',
    # Tag for the torch app image. Default '' = local windows-torch (the tag the
    # 'final' stage builds FROM).
    [string]$TorchTag = '',
    # Disable the per-run host resource log (CPU/RAM/commit/vmmem sampled every 20s into
    # out\windows-build-logs\resources-<ts>.csv, tagged with the current build phase, plus an
    # end-of-run per-phase exhaustion summary). On by default -- the cost is one idle pwsh.
    [switch]$NoResourceLog,
    # Override the host disk preflight gate — see Assert-DiskHeadroom for why
    # it refuses rather than warns.
    [switch]$SkipHostChecks,
    # Backlog #18: bypass ONLY the RDNA4 gate (verified green via
    # probe-build-copy.ps1 -Heavy) without disarming the other host gates.
    [switch]$SkipRdna4Gate,
    [int]$MinFreeGb = 40
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
# NOTE: the resource sampler is NOT started here — see the block just above the
# main try/finally below (backlog #63). It used to start at this point, ~500
# lines before the try that owns its lifecycle, so every preflight-gate throw
# (sccache endpoint down, RDNA4 enabled, disk short, dockerd stopped — all
# common) orphaned a hidden pwsh running `while ($true)` forever, one per failed
# attempt, invisible because it is -WindowStyle Hidden.

# Transient-failure classification, retry engine, build-arg shaping, image
# preflight and the isolation probe live in WindowsBuildDriver.Common.psm1
# (extracted 2026-08-03; unit-tested with a fake docker in
# BuildDriver.Retry.Tests.ps1). Initialized right after docker resolution below.

# CPU note: Hyper-V-isolated build containers get only 2 CPUs, pinning every
# in-container `ninja -j` to 2 (Get-BuildJobCount = min(ProcessorCount, memGB/perJob)).
# `docker build` on this host's classic builder offers NO working lever to raise it
# (--cpu-count rejected, --cpuset-cpus fails), and --isolation process — which would
# expose all host CPUs — cannot commit layers here (hcsshim::ActivateLayer 0x20). So
# `docker build` stages run at 2 CPUs. Raising this requires a docker-run+commit
# path (docker run --cpu-count N does honor the flag under Hyper-V).

# ---- resolve docker CLI (Stevedore's docker.exe; nerdctl needs an elevated shell for
# containerd's pipe, and buildctl/buildkitd — see build-buildkit.ps1 — covers the
# CNI-networked BuildKit path that nerdctl's missing-DNS symptom actually pointed at) ----
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
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1') -Force
Initialize-BuildDriverContext -Docker $Docker -LogDir $script:LogDir -NoCache:$NoCache
$versionsFile = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'
if (-not (Test-Path $versionsFile)) { throw "versions.env not found at $versionsFile" }
$versions = ConvertFrom-VersionsEnv -Path $versionsFile
# Thin lane-local alias over the canonical lookup in WindowsBuildDriver.Common.
# The body used to be a hand-copied twin of build-buildkit.ps1's — same check,
# two different error messages, i.e. already drifting. Keep the short name
# (many call sites below) but only one implementation.
function Get-Ver([string]$Name) {
    return Get-VersionTableValue -VersionTable $versions -Key $Name
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

# Single source of truth for the LOCAL intermediate tags (the published tag is
# $FinalTag above). Every stage invocation and BASE_IMAGE hand-off below reads
# from here — the same tag string must never be typed twice. Dockerfile ARG
# BASE_IMAGE defaults deliberately stay as-is (they are overridden on every
# invocation; rewriting them would bust layers for cosmetics).
$script:ImageTag = @{
    base              = 'local/kataglyphis:windows-base'
    sdk               = 'local/kataglyphis:windows-sdk'
    toolchainBuilder  = 'local/kataglyphis:windows-toolchain-builder'
    toolchain         = 'local/kataglyphis:windows-toolchain'
    mediaMergeBuilder = 'local/kataglyphis:windows-media-merge-builder'
    media             = 'local/kataglyphis:windows-media'
    torch             = 'local/kataglyphis:windows-torch'
}

function Get-MediaBranchTag {
    # local/kataglyphis:windows-<branch>[-builder] — the media fan-out naming rule.
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Builder
    )
    if ($Builder) { return "local/kataglyphis:windows-$Name-builder" }
    return "local/kataglyphis:windows-$Name"
}

# ── Isolation policy ──────────────────────────────────────────────────────────
# PROCESS isolation is always preferred (full host CPUs for docker build AND
# docker run — no 2-CPU Hyper-V build cap, no --cpu-count juggling), but it can
# only be used when the host can COMMIT process-isolated layers: on hosts with
# the wcifs skew bug (client build vs Server base image) every stage would die
# at its first commit. 'auto' therefore runs the ~10s commit probe and caches
# the verdict per (host build, docker version); a Windows update or Docker
# upgrade re-probes automatically.
$script:BuildIsolation = Resolve-BuildIsolation -Isolation $Isolation -Docker $Docker -LogDir $script:LogDir -ProbeScript (Join-Path $PSScriptRoot 'diagnostics\test-process-isolation-commit.ps1')
Set-BuildDriverIsolation -Isolation $script:BuildIsolation

# ── sccache policy (required by default for the media stage) ─────────────────
# Without BuildKit cache mounts, sccache's WebDAV remote is the ONLY compile
# cache that survives a container; building media without it means a mid-chain
# failure re-pays every object file. Fail fast, not hours in. (toolchain is
# NOT gated: its MSBuild/ClangCL CPython build has no sccache wiring.)
# Canonical fail-fast sccache gate (WindowsBuildDriver.Common, shared with the
# BK lane).
Assert-SccacheEndpoint -Stages $Stages -SccacheEndpoint $SccacheEndpoint -NoSccache:$NoSccache

# Disk preflight (see Assert-DiskHeadroom): below the floor, hcsshim fails in
# ways that do not look like a disk problem, hours into the run. The shim-patch
# gate is BuildKit-lane only — this lane's run+commit path uses Hyper-V
# isolation, where the teardown-timeout defect does not apply.
# -Drive: the repo checkout's drive on top of C: (the layer stores) — the build
# context is uploaded from here on every `docker build`, and on this host it is a
# VHDX with its own exhaustion mode.
Assert-DiskHeadroom -Drive @($repoRoot) -MinFreeGb $MinFreeGb -Force:$SkipHostChecks
# This lane needs a live dockerd. On a Stevedore host that is the `stevedore`
# service, which was found Stopped on 2026-08-07 — the "always-working
# fallback" silently was not one.
Assert-DockerDaemon -Docker $Docker -Force:$SkipHostChecks
# RDNA4 layer-lock gate (2026-08-10): an enabled RDNA4 dGPU kills EVERY
# process-isolated RUN-layer finalize, and this lane can run process-isolated
# (Resolve-BuildIsolation 'auto' probe — whose cached verdict does NOT key on
# the dGPU state). Same gate as the BK lane; -SkipHostChecks or the
# gate-specific -SkipRdna4Gate override.
Assert-NoActiveRdna4Gpu -Force:($SkipHostChecks -or $SkipRdna4Gate)

# (Get-DockerBuildArgList / Test-TransientDockerFailure / Assert-ImageExists /
# Invoke-TransientCooldown / Invoke-DockerWithRetry: WindowsBuildDriver.Common.psm1)

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
    # Per-stage disk gate — same calibrated floors as the BuildKit lane (they
    # live in WindowsBuildDriver.Common). This lane is the documented
    # "always-working fallback" and had NO per-stage check at all: the
    # start-of-run one can pass with 160 GB free while a single heavy stage walks
    # the disk into the band where hcsshim stops failing honestly.
    # -Drive from the REPO root, not the 'C' default — same reason as the BK
    # lane (backlog #48): the context lives on the D: VHDX on the reference host.
    Assert-StageDiskHeadroom -Label ([IO.Path]::GetFileName($Dockerfile) + $targetSuffix) -Drive (Split-Path -Qualifier $repoRoot).TrimEnd(':') -Force:$SkipHostChecks
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
            -BuilderTag (Get-MediaBranchTag 'media-core' -Builder) `
            -ContainerName 'kataglyphis-media-core-build' `
            -RunScript 'build-media-core-all.ps1' `
            -Tag (Get-MediaBranchTag 'media-core') `
            -BuildArgs ((Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $versions) + @{
                BASE_IMAGE      = $script:ImageTag.toolchain
                MEMORY_LIMIT_GB = $MediaMemoryGb
            } + $sccache)
        New-MediaBranchSpec -Name 'media-litert' `
            -BuilderDockerfile $builderDf `
            -BuilderTag (Get-MediaBranchTag 'media-litert' -Builder) `
            -ContainerName 'kataglyphis-media-litert-build' `
            -RunScript 'build-litert-all.ps1' `
            -Tag (Get-MediaBranchTag 'media-litert') `
            -BuildArgs ((Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $versions) + @{
                BASE_IMAGE      = $script:ImageTag.toolchain
                MEMORY_LIMIT_GB = $MediaMemoryGb
            } + $sccache)
        New-MediaBranchSpec -Name 'media-tvm' `
            -BuilderDockerfile $builderDf `
            -BuilderTag (Get-MediaBranchTag 'media-tvm' -Builder) `
            -ContainerName 'kataglyphis-media-tvm-build' `
            -RunScript 'build-media-tvm-all.ps1' `
            -Tag (Get-MediaBranchTag 'media-tvm') `
            -BuildArgs ((Get-MediaBranchVersionArg -Branch 'media-tvm' -VersionTable $versions) + @{
                BASE_IMAGE      = $script:ImageTag.toolchain
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
    #    -OnFailedAttempt removes the container ONLY before a transient re-run; on the final
    #    failure -OnFinalFailure preserves it and prints the -ResumeFrom recovery recipe.
    # Isolation from the probe-gated policy: process (preferred; full CPUs
    # natively, commit verified by the probe) or hyperv (where --cpu-count is
    # what grants the cores). --cpu-count/--memory apply under both. Captured
    # as a LOCAL because the .GetNewClosure() blocks below cannot resolve
    # $script: scope (the empty "--isolation " in the first resume recipe).
    $isolation = $script:BuildIsolation
    $runArgs = @('run', '--isolation', $isolation, '--cpu-count', "$Cpus", '--memory', "${MemoryGb}g",
        '--name', $ContainerName, $BuilderTag) + $RunCommand
    $dockerExe = $Docker   # local copy: .GetNewClosure() snapshots LOCALS only, not the script-scope $Docker
    # Script FUNCTIONS need the same treatment as $Docker: a .GetNewClosure() block
    # resolves function names against its dynamic module -> global scope, NOT this
    # script's scope. That resolution only happens to work when build.ps1 is the
    # pwsh -File entry point; invoked via the call operator from another session,
    # "Set-BuildPhase is not recognized" killed the run (2026-07-15). Capture
    # ${function:...} refs as locals and invoke via & instead.
    $setBuildPhase = ${function:Set-BuildPhase}
    $transientCooldown = ${function:Invoke-TransientCooldown}
    $action = {
        param($attempt)
        & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null
        & $setBuildPhase "run:$Label"
        Write-Host "`n==> [$Label] docker run --isolation $isolation --cpu-count $Cpus --memory ${MemoryGb}g (attempt $attempt)" -ForegroundColor Cyan
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
        & $setBuildPhase "commit:$Label"
        # --change 'CMD ["pwsh"]': `docker commit` captures the CONTAINER's config,
        # and this container's Cmd is the build script argv from $runArgs above. Without
        # the override, local/kataglyphis:windows-media (and windows-torch, which
        # inherits it) ship a CMD that RE-RUNS the GStreamer build — so a debugging
        # `docker run -it local/kataglyphis:windows-media` starts recompiling over
        # C:\runtime instead of giving you a shell. The final image is unaffected
        # either way (windows/Dockerfile's ENTRYPOINT resets an inherited CMD), which
        # is exactly why this stayed invisible.
        foreach ($commitAttempt in 1..3) {
            $commitOut = & $dockerExe commit --change 'CMD ["pwsh"]' $ContainerName $ResultTag 2>&1
            $commitOut | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { break }
            $commitTail = ($commitOut | Select-Object -Last 15) -join "`n"
            if (-not (& $transientCooldown -Tail $commitTail -Attempt $commitAttempt -MaxAttempts 3 -Label "$Label commit")) {
                throw ("$Label commit failed -- container '$ContainerName' PRESERVED (it holds the finished build). " +
                    "Recover manually: docker commit --change 'CMD [`"pwsh`"]' $ContainerName $ResultTag ; docker container rm -f $ContainerName")
            }
        }
        & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null
        Write-Host "$Label built via run+commit ($Cpus CPUs) -> $ResultTag" -ForegroundColor Green
    }.GetNewClosure()
    $onFailedAttempt = { & $dockerExe container rm -f $ContainerName 2>&1 | Out-Null }.GetNewClosure()
    # Final (non-transient) run failure: PRESERVE the container — it holds every
    # completed stage's output in C:\runtime — and print the resume recipe.
    # NB: `docker start` would re-run the original chain command from scratch;
    # the correct resume is commit-partial → run a NEW container with -ResumeFrom.
    $runCommand = $RunCommand
    $onFinalFailure = {
        Write-Host ("`n[$Label] run FAILED (non-transient) — container '$ContainerName' PRESERVED with all completed stages." ) -ForegroundColor Yellow
        Write-Host ("[$Label] Resume (check $OutLog for the last '=== ... stage:' banner to pick <stage>):") -ForegroundColor Yellow
        Write-Host ("    docker commit $ContainerName ${ResultTag}-partial")
        Write-Host ("    docker container rm -f $ContainerName")
        Write-Host ("    docker run --isolation $isolation --cpu-count $Cpus --memory ${MemoryGb}g --name $ContainerName ${ResultTag}-partial " + ($runCommand -join ' ') + " -ResumeFrom '<stage>'")
        Write-Host ("    docker commit --change 'CMD [`"pwsh`"]' $ContainerName $ResultTag ; docker container rm -f $ContainerName")
        Write-Host ("[$Label] Or discard: docker container rm -f $ContainerName") -ForegroundColor Yellow
    }.GetNewClosure()
    Invoke-DockerWithRetry -Action $action -OnSuccess $onSuccess -OnFailedAttempt $onFailedAttempt `
        -OnFinalFailure $onFinalFailure -Label $Label -LogFile $OutLog -TailLines 15
}

function Get-MediaRunCommand {
    # The `pwsh -File C:\temp\scripts\<script> [extra args]` invocation array for a run+commit
    # container (media branches, toolchain, and the GStreamer merge all use this exact prefix).
    param(
        [Parameter(Mandatory)] [string]$Script,
        [string[]]$ExtraArgs = @()
    )
    return @('pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "C:\temp\scripts\$Script") + $ExtraArgs
}

# Provenance/app-ref helpers shared by the 'final' and 'torch' stages. (Moved out
# of the try-block stage chain where they sat mid-flow between two stage blocks.)
# VCS ref is best-effort metadata: any failure (no git, not a repo) -> empty, never fatal.
# Get-BuildVcsRef + the Orchestr-ANT-ion ref resolution (Resolve-TorchAppRef)
# now live in WindowsBuildDriver.Common — shared with build-buildkit.ps1.

function Invoke-MediaBranchRunCommit {
    # Build one media branch via the run+commit path at full cores and the full
    # $MediaMemoryGb budget (sequential schedule: every branch gets all the RAM).
    # Passes --target <name> so the consolidated Dockerfile.media-builder
    # multi-stage build selects the correct stage.
    param(
        [Parameter(Mandatory)] $Spec,
        [Parameter(Mandatory)] [string]$OutLog
    )
    # -ScrubAfter: lane parity with the BK lane, which passes it on every compile
    # RUN. Clear-BuildScratch drops the pip cache, ~\.nuget, %TEMP% and INetCache
    # INSIDE the container before the commit — the classic lane cannot shrink an
    # already-committed layer afterwards, so a scrub in any later stage is too
    # late. (Source trees are already handled: each leaf build script calls
    # Remove-SourceBuildTree itself. This is only the package-manager debris.)
    Invoke-RunCommitStage `
        -BuilderDockerfile $Spec.BuilderDockerfile -BuilderTag $Spec.BuilderTag `
        -ResultTag $Spec.Tag -ContainerName $Spec.ContainerName `
        -RunCommand (Get-MediaRunCommand $Spec.RunScript -ExtraArgs @('-ScrubAfter')) `
        -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb -BuildArgs $Spec.BuildArgs `
        -BuilderExtraFlags @('--target', $Spec.Name) `
        -Label $Spec.Name -OutLog $OutLog
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
    # Sequential fan-out: media-core first (whole RAM budget -> most ONNX jobs),
    # then each aux branch, ALL via run+commit at full cores.
    # Invoke-RunCommitStage throws on failure, so a failed branch aborts the
    # chain directly; media-core is committed before the aux branches run, so
    # aux compiles get the full MediaMemoryGb budget (parallelism is memory-bound).
    $coreSpec = $specs | Where-Object { $_.Name -eq 'media-core' } | Select-Object -First 1
    $auxSpecs = @($specs | Where-Object { $_.Name -ne 'media-core' })
    if ($coreSpec) {
        Invoke-MediaBranchRunCommit -Spec $coreSpec -OutLog (Join-Path $script:LogDir 'media-core.log')
    }
    foreach ($spec in $auxSpecs) {
        Invoke-MediaBranchRunCommit -Spec $spec -OutLog (Join-Path $script:LogDir "$($spec.Name).log")
    }
    Write-Host 'All media branches built.' -ForegroundColor Green
}

function Invoke-ResumeRunCommit {
    # Scripted version of the manual recovery recipe Invoke-RunCommitStage
    # prints on a final failure. The container invariant is identical: it is
    # NEVER removed before a successful commit (it holds hours of compile).
    $spec = @(Get-MediaBranchSpecs) | Where-Object { $_.Name -eq $ResumeStage } | Select-Object -First 1
    if (-not $spec) { throw "-ResumeStage '$ResumeStage' has no branch spec" }
    if (-not $ResumeFrom) { throw "-ResumeStage requires -ResumeFrom '<stage name>' (see the '=== $($spec.Name) stage: X ===' banners in the stage log)" }
    $container = $spec.ContainerName
    $state = & $Docker inspect $container --format '{{.State.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "container '$container' not found — nothing to resume (was it discarded?)" }
    if ($state -ne 'exited') { throw "container '$container' is '$state' — resume needs it exited (docker cp cannot touch a running Hyper-V container)" }

    foreach ($fix in $CopyFix) {
        if (-not (Test-Path $fix)) { throw "-CopyFix file not found: $fix" }
        $leaf = Split-Path $fix -Leaf
        & $Docker cp $fix "${container}:C:\temp\scripts\$leaf"
        if ($LASTEXITCODE -ne 0) { throw "docker cp '$fix' into $container failed" }
        Write-Host "[resume:$ResumeStage] injected fix: $leaf" -ForegroundColor Cyan
    }

    $partial = "$($spec.Tag)-partial"
    Write-Host "[resume:$ResumeStage] committing preserved container -> $partial" -ForegroundColor Cyan
    & $Docker commit $container $partial | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "partial commit failed — container '$container' left untouched" }
    & $Docker container rm -f $container | Out-Null

    $isolation = $script:BuildIsolation
    $outLog = Join-Path $script:LogDir "$($spec.Name).log"
    # -ScrubAfter mirrors Invoke-MediaBranchRunCommit: a resumed branch must
    # produce the same image shape as a first-pass one.
    $runCmd = (Get-MediaRunCommand $spec.RunScript -ExtraArgs @('-ScrubAfter')) + @('-ResumeFrom', $ResumeFrom)
    Write-Host "[resume:$ResumeStage] docker run --isolation $isolation --cpu-count $MediaCoreCpus --memory ${MediaMemoryGb}g -ResumeFrom '$ResumeFrom'" -ForegroundColor Cyan
    # Same transient-retry engine as the first attempt (ttrpc/shim flakes love
    # long runs; the recovery run used to single-shot). Invariants mirror
    # Invoke-RunCommitStage: transient retry removes the dead container and
    # re-runs from $partial (the preserved state IS the partial image); a
    # non-transient failure preserves the container for another resume round.
    # LOCAL COPIES — load-bearing (backlog #40). .GetNewClosure() snapshots the
    # LOCAL scope only, never $script:. $Docker/$MediaCoreCpus/$MediaMemoryGb/
    # $ResumeStage are script-level param() variables, so inside the blocks
    # below they resolved to EMPTY: the run degraded to
    #   [] run --isolation hyperv --cpu-count  --memory "g" --name c1 p1
    # which dies with a PowerShell parser error ("The expression after '&' ...")
    # rather than a docker error — so the resume aborted pointing nowhere. The
    # identical fix has been on the sibling Invoke-RunCommitStage since 2026-07
    # (see $dockerExe above); this path never got it, and no test covered it.
    # The compile state itself was never at risk: it lives in $partial, which is
    # committed and exit-code-checked before the container is removed.
    $dockerExe = $Docker
    $cpus = $MediaCoreCpus
    $memGb = $MediaMemoryGb
    $stageName = $ResumeStage
    Invoke-DockerWithRetry -Label "resume:$ResumeStage" -LogFile $outLog -MaxAttempts 2 `
        -Action {
            & $dockerExe run --isolation $isolation --cpu-count $cpus --memory "${memGb}g" --name $container $partial @runCmd 2>&1 | Tee-Object -FilePath $outLog
        }.GetNewClosure() `
        -OnFailedAttempt {
            & $dockerExe container rm -f $container 2>&1 | Out-Null
        }.GetNewClosure() `
        -OnFinalFailure {
            Write-Host ("[resume:$stageName] run FAILED — container '$container' PRESERVED again; " +
                "fix forward and re-run: .\windows\build.ps1 -ResumeStage $stageName -ResumeFrom '<stage>' [-CopyFix <file>]") -ForegroundColor Red
        }.GetNewClosure()
    Write-Host "[resume:$ResumeStage] committing -> $($spec.Tag)" -ForegroundColor Cyan
    # --change: same reason as Invoke-RunCommitStage's commit — without it the
    # resumed branch image inherits the build-script argv as its CMD.
    & $Docker commit --change 'CMD ["pwsh"]' $container $spec.Tag | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "[resume:$ResumeStage] FINAL commit failed — container '$container' PRESERVED (recover: docker commit --change 'CMD [`"pwsh`"]' $container $($spec.Tag))"
    }
    & $Docker container rm -f $container 2>&1 | Out-Null
    & $Docker image rm -f $partial 2>&1 | Out-Null
    Write-Host "[resume:$ResumeStage] COMMITTED $($spec.Tag) — continue the chain with e.g. -Stages media,torch,final -SkipMediaBranches (or -MediaBranches for remaining branches)" -ForegroundColor Green
}

# -MediaMemoryGb 0 = auto-detect from host RAM (usable minus host reserve).
# Sequential is the only schedule (media-core runs first with the full budget,
# then aux branches also get full RAM since media-core already committed).
# Canonical math lives in WindowsBuildDriver.Common (shared with the BK lane —
# this block used to hand-roll the identical reserve/floor-8 computation and
# the pair had already drifted once before).
if ($MediaMemoryGb -le 0) {
    $MediaMemoryGb = Get-MediaMemoryBudget -RequestedGb $MediaMemoryGb -HostReserveGb $HostReserveGb
    if ($MediaMemoryGb -le 8) {
        Write-Warning "media memory budget hit the 8GB floor (host RAM minus -HostReserveGb $HostReserveGb) -- the HOST may be starved during the build (free RAM, or lower -HostReserveGb deliberately)."
    }
    Write-Host ("Auto-detected -MediaMemoryGb=${MediaMemoryGb}g (host RAM - ${HostReserveGb}GB reserve; cores=$MediaCoreCpus)") -ForegroundColor Cyan
} else {
    Write-Host ("-MediaMemoryGb=${MediaMemoryGb}g (explicit); cores=$MediaCoreCpus") -ForegroundColor Cyan
}

$started = Get-Date

# Resource sampler starts HERE, immediately before the try/finally that stops
# it (backlog #63) — every preflight gate above is now past, so a rejected
# launch can no longer orphan it. The preflight costs seconds, so nothing
# meaningful is lost from the sample series.
if (-not $NoResourceLog) {
    $script:ResourceCsv = Join-Path $script:LogDir ("resources-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".csv")
    Set-BuildPhase 'init'
    $samplerScript = Join-Path $PSScriptRoot 'scripts\build-resource-sampler.ps1'
    $script:SamplerProc = Start-Process -FilePath ((Get-Process -Id $PID).Path) -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', $samplerScript,
        '-CsvPath', $script:ResourceCsv, '-PhaseFile', $script:PhaseFile, '-IntervalSeconds', '20')
    Write-Host "Resource log: $script:ResourceCsv (20s samples, phase-tagged; disable with -NoResourceLog)"
}

try {
    if ($ResumeStage) {
        # Scripted recovery mode: runs INSTEAD of the stage chain (continue the
        # chain afterwards with -Stages media,torch,final -SkipMediaBranches /
        # -MediaBranches as the success message suggests).
        Invoke-ResumeRunCommit
        Write-Host ("`nDone in {0:hh\:mm\:ss}. Resume of {1} completed." -f ((Get-Date) - $started), $ResumeStage) -ForegroundColor Green
        return
    }
    if ($Stages -contains 'base') {
        Invoke-Stage -Dockerfile 'windows/Dockerfile.base' -Tag $script:ImageTag.base -BuildArgs @{
            WINDOWS_LTSC      = Get-Ver 'WINDOWS_LTSC'
            WINDOWS_BASE_DIGEST = Get-Ver 'WINDOWS_BASE_DIGEST'
            VULKAN_VERSION    = Get-Ver 'VULKAN_VERSION'
            CMAKE_VERSION     = Get-Ver 'CMAKE_VERSION'
            # Compiled-output pins (2026-08-07): clang-cl compiles the whole media
            # chain, ninja drives it, nasm assembles FFmpeg's SIMD. Unpinned they
            # made the base image unreproducible; verify-toolchain.ps1 asserts them.
            LLVM_WINDOWS_VERSION  = Get-Ver 'LLVM_WINDOWS_VERSION'
            NINJA_WINDOWS_VERSION = Get-Ver 'NINJA_WINDOWS_VERSION'
            NASM_WINDOWS_VERSION  = Get-Ver 'NASM_WINDOWS_VERSION'
            PWSH_VERSION      = Get-Ver 'PWSH_VERSION'
            # SHA256 pin for the pwsh zip: the bootstrap RUN predates load-versions
            # baking, so the hash must travel as an ARG like the version itself.
            PWSH_ZIP_SHA256   = Get-Ver 'PWSH_ZIP_SHA256'
            # As a --build-arg (not versions.env-baked env): setup-vs runs BEFORE load-versions
            # by design (protects the VS layer from versions.env bumps), so the SDK pin must
            # reach it via ARG -- and changing it SHOULD bust the VS layer.
            WINDOWS_SDK_BUILD = Get-Ver 'WINDOWS_SDK_BUILD'
            VISUAL_STUDIO_VERSION = Get-Ver 'VISUAL_STUDIO_VERSION'
            # #50 (2026-08-18): consumed below versions.env's relocated COPY -
            # keep in sync with Dockerfile.base's ARG block and build-buildkit.
            GIT_VERSION                  = Get-Ver 'GIT_VERSION'
            GIT_WINDOWS_INSTALLER_SHA256 = Get-Ver 'GIT_WINDOWS_INSTALLER_SHA256'
            SCOOP_INSTALLER_SHA256       = Get-Ver 'SCOOP_INSTALLER_SHA256'
            WIX_VERSION                  = Get-Ver 'WIX_VERSION'
            WIX_UI_EXT_VERSION           = Get-Ver 'WIX_UI_EXT_VERSION'
            FLUTTER_VERSION              = Get-Ver 'FLUTTER_VERSION'
            VCPKG_REF                    = Get-Ver 'VCPKG_REF'
            SCCACHE_GIT_REV              = Get-Ver 'SCCACHE_GIT_REV'
        }
    }

    if ($Stages -contains 'sdk') {
        if ($Gpu) {
            # Context `windows` (not the repo root): the TensorRT zip is consumed only here, and
            # the root .dockerignore excludes it so no OTHER build uploads the ~2 GB context.
            Invoke-Stage -Dockerfile 'windows/Dockerfile.nvidia' -Context 'windows' -Tag $script:ImageTag.sdk -BuildArgs @{
                BASE_IMAGE               = $script:ImageTag.base
                CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
                CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
                CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
                TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
                # Hashes as ARGs: the base image's baked versions.env is stale
                # right after a bump — these must move WITH the version pins.
                CUDA_INSTALLER_SHA256    = Get-Ver 'CUDA_INSTALLER_SHA256'
                CUDNN_ZIP_SHA256         = Get-Ver 'CUDNN_ZIP_SHA256'
                TENSORRT_ZIP_SHA256      = Get-Ver 'TENSORRT_ZIP_SHA256'
            }
        } else {
            Write-Host "`n==> CPU lane: tagging windows-base as windows-sdk (no GPU layer)" -ForegroundColor Cyan
            & $Docker tag $script:ImageTag.base $script:ImageTag.sdk
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
            -BuilderTag    $script:ImageTag.toolchainBuilder `
            -ResultTag     $script:ImageTag.toolchain `
            -ContainerName 'kataglyphis-toolchain-build' `
            -RunCommand    (Get-MediaRunCommand 'build-toolchain-all.ps1') `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs @{
                BASE_IMAGE     = $script:ImageTag.sdk
                PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
            } `
            -BuilderExtraFlags @('--target', 'builder-classic') `
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
        # Branch result tags come from the specs (single source of truth): a
        # renamed -Tag cannot leave the merge COPY --from pointing at the old
        # name. The component-version union comes from the CANONICAL
        # Get-MediaMergeVersionArg (WindowsBuildDriver.Common, shared with the
        # BK lane) — this block used to re-derive it from spec BuildArgs with
        # its own exclusion list, re-forming exactly the two-copies drift the
        # module was created to end (the exclusion pair NV_CODEC_HEADERS_REF/
        # CUDA_ARCHITECTURES lived in both).
        $branchTag = @{}
        foreach ($spec in Get-MediaBranchSpecs) {
            $branchTag[$spec.Name] = $spec.Tag
        }
        $mergeArgs = (Get-MediaMergeVersionArg -VersionTable $versions) + @{
            BASE_IMAGE        = $script:ImageTag.toolchain
            CORE_IMAGE        = $branchTag['media-core']
            LITERT_IMAGE      = $branchTag['media-litert']
            TVM_IMAGE         = $branchTag['media-tvm']
            MEMORY_LIMIT_GB   = $MediaMemoryGb
        }
        Invoke-RunCommitStage `
            -BuilderDockerfile 'windows/Dockerfile.media-merge-builder' `
            -BuilderTag    $script:ImageTag.mediaMergeBuilder `
            -ResultTag     $script:ImageTag.media `
            -ContainerName 'kataglyphis-media-merge-build' `
            -RunCommand    (Get-MediaRunCommand 'build-gstreamer-from-source.ps1' -ExtraArgs @('-InstallDir', 'C:\runtime', '-LogDir', 'C:\temp\logs', '-ScrubAfter')) `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs $mergeArgs `
            -BuilderExtraFlags @('--target', 'merge') `
            -Label 'media-merge+gstreamer' -OutLog $gstLog
    }

    # Orchestr-ANT-ion app stage (windows/Dockerfile.torch) — AFTER toolchain and
    # media, BEFORE final: 'final' builds FROM this image, so the app-assembly
    # logic lives here alone and an APP_REF bump rebuilds torch + the cheap
    # final tail only. -TorchBaseImage swaps the parent (e.g. the published
    # :winamd64 image on a host without local chain images).
    if ($Stages -contains 'torch') {
        $torchBase = if ($TorchBaseImage) { $TorchBaseImage } else { $script:ImageTag.media }
        $torchTagResolved = if ($TorchTag) { $TorchTag } else { $script:ImageTag.torch }
        $appRef = Resolve-TorchAppRef -VersionTable $versions -LatestApp:$LatestApp
        Write-Host "Orchestr-ANT-ion app stage: $torchBase + $appRef -> $torchTagResolved"
        Invoke-Stage -Dockerfile 'windows/Dockerfile.torch' -Tag $torchTagResolved -BuildArgs @{
            BASE_IMAGE = $torchBase
            BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            VCS_REF    = Get-BuildVcsRef
            APP_REF    = $appRef
            # Backend extra from the app's pyproject — without this a -Gpu chain
            # shipped CPU torch in a CUDA image (Dockerfile default: pytorch-cpu).
            PYTORCH_EXTRA = $(if ($Gpu) { 'pytorch-cu130' } else { 'pytorch-cpu' })
        }
    }

    if ($Stages -contains 'final') {
        # FROM the torch image: the windows-torch tag must exist (built above, or
        # in an earlier run when iterating with -Stages final alone).
        Invoke-Stage -Dockerfile 'windows/Dockerfile' -Tag $FinalTag -BuildArgs @{
            BASE_IMAGE = if ($TorchTag) { $TorchTag } else { $script:ImageTag.torch }
            BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            VCS_REF    = Get-BuildVcsRef
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
