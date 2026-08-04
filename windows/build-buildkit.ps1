# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.0

<#
.SYNOPSIS
    EXPERIMENTAL BuildKit/containerd driver for the Windows image chain:
    base -> [nvidia] -> toolchain -> media -> torch -> final — every stage a
    plain build under PROCESS isolation with ALL host CPUs.

.DESCRIPTION
    The classic lane (windows/build.ps1) exists because on this host docker's
    classic builder cannot commit process-isolated layers (wcifs skew) and
    Hyper-V `docker build` is capped at 2 CPUs — hence the run+commit machinery.
    Probes on 2026-08-03 proved buildkitd+containerd does NOT share those
    limits here: process-isolated RUN steps see all CPUs, layers commit, and
    (with the CNI nat conf installed) containers have networking. This driver
    builds the SAME Dockerfiles via buildctl, selecting the `*-built` targets
    that run the heavy compile scripts as plain layers.

    Prerequisites (one-time, admin):
      * buildkitd + containerd services running (Stevedore installs them;
        buildkitd grants pipe access to the docker-users group)
      * C:\Program Files\containerd\cni\conf\0-containerd-nat.conf present
        (nat plugin ships in ...\cni\bin; without the conf, RUN steps have NO
        network adapter and every download fails)

    Results land in the CONTAINERD image store as
    docker.io/local/kataglyphis:bk-<stage> — deliberately fully-qualified:
    buildkit normalizes FROM references to docker.io/..., and stage handoff
    relies on `--opt image-resolve-mode=local` matching the stored name.
    NOTE: these images are INVISIBLE to docker (its windowsfilter store is
    separate); use -FinalTar to export a docker-loadable tarball of the final
    image, or push from buildctl directly once registry auth is wired.

.PARAMETER FinalTar
    Optional path: additionally export the final image as a docker-load tar
    (instant re-solve from cache, then tar streaming).

.EXAMPLE
    .\windows\build-buildkit.ps1 -Gpu
.EXAMPLE
    .\windows\build-buildkit.ps1 -Stages toolchain -Verbose   # one stage
#>
[CmdletBinding()]
param(
    [switch]$Gpu,
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'torch', 'final')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'torch', 'final'),
    [ValidateSet('media-core', 'media-litert', 'media-tvm')]
    [string[]]$MediaBranches = @('media-core', 'media-litert', 'media-tvm'),
    [string]$BuildCtl = '',
    [int]$MediaMemoryGb = 0,
    [int]$HostReserveGb = 22,
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
    [switch]$NoSccache,
    [switch]$LatestApp,
    [string]$FinalTar = '',
    [switch]$NoCache,
    # Optional cross-host/CI cache: exports each stage's buildkit cache to a
    # registry ref (and/or imports it first). E.g.
    #   -ExportCacheRef ghcr.io/kataglyphis/kataglyphis_beschleuniger:bk-cache
    # Registry auth must already be wired (docker login credentials are NOT
    # shared with buildkitd; use registry-hosted cache only once push works).
    [string]$ExportCacheRef = '',
    [string]$ImportCacheRef = '',
    # OPT-IN: build the two aux media branches (litert + tvm) CONCURRENTLY via
    # child driver processes after media-core. Both branches are memory-bound;
    # each child gets half the media memory budget. Measure before enabling on
    # smaller hosts — the sequential default is the safe long-pole schedule.
    [switch]$ConcurrentAux,
    # Push the final image to a registry ref after the local export, e.g.
    #   -PushRef ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
    # buildctl forwards the CLIENT's docker credential store, so a prior
    # `docker login <registry>` in this shell is sufficient.
    [string]$PushRef = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {

Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force

$script:LogDir = Join-Path $repoRoot 'out\windows-build-logs'
New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null

# --- buildctl resolution ---
if (-not $BuildCtl) {
    foreach ($c in @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')) {
        if (Test-Path $c) { $BuildCtl = $c; break }
    }
    if (-not $BuildCtl) { $BuildCtl = (Get-Command buildctl -ErrorAction SilentlyContinue).Source }
}
if (-not $BuildCtl) { throw 'buildctl.exe not found (Stevedore bin or PATH).' }
& $BuildCtl debug info *> $null
if ($LASTEXITCODE -ne 0) { throw 'buildkitd not reachable (service running? user in docker-users?)' }

# --- CNI nat subnet drift guard --------------------------------------------
# dockerd restarts recreate the Windows 'nat' HNS network on a new subnet while
# the containerd CNI conf pins a static one — drifted, BK containers get IPs
# whose gateway does not exist (cost a chain launch on 2026-08-03). The check
# lives in WindowsBuildKit.Common.psm1 (table-tested subnet math); fail fast
# here with the exact fix.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildKit.Common.psm1') -Force
$cniDrift = Get-CniNatSubnetDrift
if ($cniDrift) { throw $cniDrift }

# --- versions (single source of truth) ---
$versions = ConvertFrom-VersionsEnv -Path (Join-Path $repoRoot 'linux\scripts\01-core\versions.env')
function Get-Ver([string]$Key) {
    if (-not $versions.Contains($Key)) { throw "versions.env has no key $Key" }
    return $versions[$Key]
}
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# --- resource budget (same model as build.ps1) ---
if ($MediaMemoryGb -le 0) {
    $usableGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $MediaMemoryGb = [math]::Max(8, $usableGb - $HostReserveGb)
}
Write-Host "BuildKit lane: process isolation, all CPUs; MEMORY_LIMIT_GB=$MediaMemoryGb (job-count cap)" -ForegroundColor Cyan

# --- sccache policy (same as build.ps1) ---
$compileStages = @('toolchain', 'media')
if (-not $NoSccache -and @($Stages | Where-Object { $compileStages -contains $_ }).Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($SccacheEndpoint)) {
        throw 'sccache required for toolchain/media (see windows/build.ps1 for setup); -NoSccache overrides.'
    }
    Invoke-WebRequest -Uri $SccacheEndpoint -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
    Write-Host "sccache endpoint reachable: $SccacheEndpoint" -ForegroundColor Cyan
}

# --- tags: fully-qualified for containerd-store handoff; bk- namespaced so the
# classic docker lane's local/kataglyphis:windows-* tags can never collide ---
function Get-BkTag([string]$Name) { return "docker.io/local/kataglyphis:bk-$Name" }

function Get-TorchAppRef {
    $ref = Get-Ver 'APP_REF'
    if ($LatestApp) {
        try {
            $tagRaw = & git ls-remote --tags https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion.git 2>$null
            if ($LASTEXITCODE -eq 0 -and $tagRaw) {
                $latest = Resolve-LatestVersionTag -LsRemoteOutput @($tagRaw)
                if ($latest) { $ref = $latest }
            }
        } catch { }
    }
    return $ref
}
function Get-BuildVcsRef {
    try { $r = (& git rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -ne 0) { return '' } else { return $r } }
    catch { return '' }
}

function Invoke-BkStage {
    param(
        [Parameter(Mandatory)][string]$Dockerfile,   # repo-relative
        [string]$Tag = '',
        [hashtable]$BuildArgs = @{},
        [string]$Target = '',
        [string]$Context = '.',
        [string]$Label = '',
        # WARM solve: run the build WITHOUT any exporter. Nothing ever
        # finalizes the solve's snapshots, so the host's lost-HCS-shutdown-
        # notification defect (ExportLayer 0x3 at finalize — see
        # docs/windows-builds.md § BuildKit/containerd lane) never fires.
        # Artifacts leave the warm container via the C:\bkhandoff cache mount
        # (Export-BuildHandoff); the paired materialize target imports them
        # in a calm container and IS exported normally.
        [switch]$NoOutput
    )
    if (-not $NoOutput -and -not $Tag) { throw 'Invoke-BkStage: -Tag is required unless -NoOutput' }
    if (-not $Label) { $Label = [IO.Path]::GetFileName($Dockerfile) + $(if ($Target) { ":$Target" } else { '' }) }
    $dfDir = Split-Path (Join-Path $repoRoot $Dockerfile) -Parent
    $dfName = [IO.Path]::GetFileName($Dockerfile)
    $bkArgs = @(
        'build',
        '--frontend', 'dockerfile.v0',
        '--local', "context=$Context",
        '--local', "dockerfile=$dfDir",
        '--opt', "filename=$dfName",
        # Stage handoff: resolve FROM refs against the local containerd store
        # (stored fully-qualified; without this buildkit goes to docker.io).
        '--opt', 'image-resolve-mode=local',
        '--progress', 'plain'
    )
    if (-not $NoOutput) { $bkArgs += @('--output', "type=image,name=$Tag,unpack=true") }
    if ($NoCache) { $bkArgs += @('--no-cache') }
    if ($Target) { $bkArgs += @('--opt', "target=$Target") }
    # Optional cross-host cache (mode=max also caches non-exported intermediate
    # stages; per-stage refs suffixed with the label keep entries separable).
    if ($ImportCacheRef) { $bkArgs += @('--import-cache', "type=registry,ref=$ImportCacheRef") }
    if ($ExportCacheRef) { $bkArgs += @('--export-cache', "type=registry,ref=$ExportCacheRef,mode=max") }
    foreach ($k in ($BuildArgs.Keys | Sort-Object)) {
        $v = $BuildArgs[$k]
        if ($null -ne $v -and "$v" -ne '') { $bkArgs += @('--opt', "build-arg:$k=$v") }
    }
    $stageLog = Join-Path $script:LogDir ("bk-" + ($Label -replace '[:\\/]', '-') + ".log")
    $dest = if ($NoOutput) { '(warm solve, no output)' } else { $Tag }
    # ONE automatic retry on transient container-infrastructure failures —
    # the same class the classic driver retries (WindowsBuildDriver.Common):
    # ActivateLayer 0x20 is snapshot contention that clears in seconds (cost
    # a manual re-run on 2026-08-04), ttrpc/shim errors are startup races.
    $transient = 'hcsshim::ActivateLayer.*0x20|ttrpc: closed|failed to create shim task'
    foreach ($attempt in 1, 2) {
        Write-Host "`n==> [bk:$Label] buildctl -> $dest$(if ($attempt -gt 1) { ' (retry)' })" -ForegroundColor Cyan
        & $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $stageLog
        if ($LASTEXITCODE -eq 0) { break }
        $tail = if (Test-Path $stageLog) { (Get-Content $stageLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        if ($attempt -eq 1 -and $tail -match $transient) {
            Write-Warning "[bk:$Label] transient infrastructure failure — retrying in 15s"
            Start-Sleep -Seconds 15
            continue
        }
        throw "[bk:$Label] buildctl failed (exit $LASTEXITCODE) — log: $stageLog"
    }
    Write-Host "[bk:$Label] OK -> $dest" -ForegroundColor Green
}

$sccache = @{ SCCACHE_WEBDAV_ENDPOINT = $SccacheEndpoint }
$started = Get-Date

if ($Stages -contains 'base') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.base' -Tag (Get-BkTag 'windows-base') -BuildArgs @{
        WINDOWS_LTSC          = Get-Ver 'WINDOWS_LTSC'
        WINDOWS_BASE_DIGEST   = Get-Ver 'WINDOWS_BASE_DIGEST'
        VULKAN_VERSION        = Get-Ver 'VULKAN_VERSION'
        CMAKE_VERSION         = Get-Ver 'CMAKE_VERSION'
        PWSH_VERSION          = Get-Ver 'PWSH_VERSION'
        PWSH_ZIP_SHA256       = Get-Ver 'PWSH_ZIP_SHA256'
        WINDOWS_SDK_BUILD     = Get-Ver 'WINDOWS_SDK_BUILD'
        VISUAL_STUDIO_VERSION = Get-Ver 'VISUAL_STUDIO_VERSION'
    }
}

if ($Stages -contains 'sdk') {
    if ($Gpu) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.nvidia' -Context 'windows' -Tag (Get-BkTag 'windows-sdk') -BuildArgs @{
            BASE_IMAGE               = Get-BkTag 'windows-base'
            CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
            CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
            CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
            TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
            CUDA_INSTALLER_SHA256    = Get-Ver 'CUDA_INSTALLER_SHA256'
            CUDNN_ZIP_SHA256         = Get-Ver 'CUDNN_ZIP_SHA256'
        }
    } else {
        # CPU lane: containerd has no unprivileged `tag`; re-export base under
        # the sdk name via a trivial FROM (cache-hit, seconds).
        $alias = Join-Path $script:LogDir 'Dockerfile.bk-sdk-alias'
        "FROM $(Get-BkTag 'windows-base')`r`n" | Set-Content $alias -Encoding ASCII
        Invoke-BkStage -Dockerfile ('out/windows-build-logs/' + [IO.Path]::GetFileName($alias)) -Tag (Get-BkTag 'windows-sdk') -Label 'sdk-alias'
    }
}

if ($Stages -contains 'toolchain') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Target 'built' -Tag (Get-BkTag 'windows-toolchain') -BuildArgs (@{
        BASE_IMAGE     = Get-BkTag 'windows-sdk'
        PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
    } + $sccache)
}

if ($Stages -contains 'media') {
    $branchArgs = @{
        'media-core'   = @{
            ONNXRUNTIME_VERSION       = Get-Ver 'ONNXRUNTIME_VERSION'
            ONNXRUNTIME_GENAI_VERSION = Get-Ver 'ONNXRUNTIME_GENAI_VERSION'
            OPENCV_SOURCE_VERSION     = Get-Ver 'OPENCV_VERSION'
            FFMPEG_VERSION            = Get-Ver 'FFMPEG_VERSION'
            PYAV_VERSION              = Get-Ver 'PYAV_VERSION'
            NV_CODEC_HEADERS_REF      = Get-Ver 'NV_CODEC_HEADERS_REF'
            CUDA_ARCHITECTURES        = Get-Ver 'CUDA_ARCHITECTURES'
        }
        'media-litert' = @{
            LITERT_VERSION    = Get-Ver 'LITERT_VERSION'
            LITERT_LM_VERSION = Get-Ver 'LITERT_LM_VERSION'
        }
        'media-tvm'    = @{
            TVM_REF      = Get-Ver 'TVM_REF'
            IREE_VERSION = Get-Ver 'IREE_VERSION'
        }
    }
    $loopBranches = $MediaBranches
    $auxProcs = @()
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        # media-core (the long pole) runs sequentially below; litert + tvm run
        # side by side afterwards via child drivers (each re-checks
        # base/sdk/toolchain as cache hits and builds exactly one branch on
        # half the memory budget — both branches are memory-bound).
        $loopBranches = @($MediaBranches | Where-Object { $_ -notin @('media-litert', 'media-tvm') })
        $auxMem = [Math]::Max(8, [int]($MediaMemoryGb / 2))
    }
    foreach ($branch in $loopBranches) {
        $branchBuildArgs = @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
            MEMORY_LIMIT_GB = $MediaMemoryGb
        } + $branchArgs[$branch] + $sccache
        if ($branch -eq 'media-core') {
            # WARM/MATERIALIZE solve pairs (host platform defect: heavy-churn
            # containers lose the HCS shutdown notification and their snapshot
            # can never be finalized — full evidence in Dockerfile.media-builder
            # and docs/windows-builds.md). Warm solves run with -NoOutput so
            # nothing ever finalizes them; the paired materialize solves import
            # the handoff from the C:\bkhandoff cache mount and export the tag.
            # ONNX never trips the defect and keeps its direct solve.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-onnx' -Tag (Get-BkTag 'windows-media-core-onnx') -BuildArgs $branchBuildArgs
            $onnxArg   = @{ MEDIA_CORE_ONNX_IMAGE = Get-BkTag 'windows-media-core-onnx' }
            $opencvArg = @{ MEDIA_CORE_OPENCV_IMAGE = Get-BkTag 'windows-media-core-opencv' }
            $ffmpegArg = @{ MEDIA_CORE_FFMPEG_IMAGE = Get-BkTag 'windows-media-core-ffmpeg' }
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-warm-opencv' -NoOutput -BuildArgs ($branchBuildArgs + $onnxArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-opencv' -Tag (Get-BkTag 'windows-media-core-opencv') -BuildArgs ($branchBuildArgs + $onnxArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-warm-ffmpeg' -NoOutput -BuildArgs ($branchBuildArgs + $opencvArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-ffmpeg' -Tag (Get-BkTag 'windows-media-core-ffmpeg') -BuildArgs ($branchBuildArgs + $opencvArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-warm-genai' -NoOutput -BuildArgs ($branchBuildArgs + $ffmpegArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built' -Tag (Get-BkTag 'windows-media-core') -BuildArgs ($branchBuildArgs + $ffmpegArg)
        } elseif ($branch -eq 'media-tvm') {
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-tvm-warm' -NoOutput -BuildArgs $branchBuildArgs
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-tvm-built' -Tag (Get-BkTag 'windows-media-tvm') -BuildArgs $branchBuildArgs
        } else {
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target "$branch-built" -Tag (Get-BkTag "windows-$branch") -BuildArgs $branchBuildArgs
        }
    }
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        Write-Host "`n==> [bk:aux] concurrent litert + tvm child drivers ($auxMem GB memory budget each)" -ForegroundColor Cyan
        foreach ($aux in 'media-litert', 'media-tvm') {
            $auxArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Stages', 'media', '-MediaBranches', $aux, '-MediaMemoryGb', $auxMem)
            if ($Gpu) { $auxArgs += '-Gpu' }
            if ($SccacheEndpoint) { $auxArgs += @('-SccacheEndpoint', $SccacheEndpoint) }
            $auxProcs += Start-Process -FilePath 'pwsh' -ArgumentList $auxArgs -PassThru -NoNewWindow
        }
        $auxProcs | Wait-Process
        foreach ($p in $auxProcs) {
            if ($p.ExitCode -ne 0) { throw "[bk:aux] concurrent branch driver (pid $($p.Id)) failed (exit $($p.ExitCode))" }
        }
        Write-Host '[bk:aux] litert + tvm OK' -ForegroundColor Green
    }
    $mergeArgs = @{
        BASE_IMAGE        = Get-BkTag 'windows-toolchain'
        CORE_IMAGE        = Get-BkTag 'windows-media-core'
        LITERT_IMAGE      = Get-BkTag 'windows-media-litert'
        TVM_IMAGE         = Get-BkTag 'windows-media-tvm'
        GSTREAMER_VERSION = Get-Ver 'GSTREAMER_VERSION'
        MEMORY_LIMIT_GB   = $MediaMemoryGb
    }
    foreach ($t in $branchArgs.Values) { foreach ($k in $t.Keys) {
        if ($k -notin @('NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES')) { $mergeArgs[$k] = $t[$k] }
    } }
    # Warm/materialize pair (GStreamer is heavy-churn — same platform-defect
    # workaround as the media-core libraries, see Dockerfile.media-builder).
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -Target 'warm' -NoOutput -BuildArgs ($mergeArgs + $sccache)
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -Target 'built' -Tag (Get-BkTag 'windows-media') -BuildArgs ($mergeArgs + $sccache)
}

if ($Stages -contains 'torch') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.torch' -Tag (Get-BkTag 'windows-torch') -BuildArgs @{
        BASE_IMAGE = Get-BkTag 'windows-media'
        APP_REF    = Get-TorchAppRef
        BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        VCS_REF    = Get-BuildVcsRef
    }
}

if ($Stages -contains 'final') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Tag (Get-BkTag 'winamd64') -BuildArgs @{
        BASE_IMAGE = Get-BkTag 'windows-torch'
        BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        VCS_REF    = Get-BuildVcsRef
    }
    if ($FinalTar) {
        Write-Host "`n==> exporting final image to $FinalTar (docker-loadable)" -ForegroundColor Cyan
        # Same solve from cache; only the export differs.
        $dfDir = Join-Path $repoRoot 'windows'
        & $BuildCtl build --frontend dockerfile.v0 --local "context=." --local "dockerfile=$dfDir" `
            --opt filename=Dockerfile --opt image-resolve-mode=local `
            --opt "build-arg:BASE_IMAGE=$(Get-BkTag 'windows-torch')" `
            --output "type=docker,name=local/kataglyphis:winamd64,dest=$FinalTar" 2>&1 | Select-Object -Last 5
        if ($LASTEXITCODE -ne 0) { throw "final tar export failed" }
    }
    if ($PushRef) {
        Write-Host "`n==> pushing final image to $PushRef" -ForegroundColor Cyan
        # Same solve from cache; the push=true exporter uploads the blobs.
        # Auth: buildctl forwards THIS shell's docker credential store —
        # run `docker login <registry>` here first.
        $dfDir = Join-Path $repoRoot 'windows'
        & $BuildCtl build --frontend dockerfile.v0 --local "context=." --local "dockerfile=$dfDir" `
            --opt filename=Dockerfile --opt image-resolve-mode=local `
            --opt "build-arg:BASE_IMAGE=$(Get-BkTag 'windows-torch')" `
            --output "type=image,name=$PushRef,push=true" 2>&1 | Select-Object -Last 5
        if ($LASTEXITCODE -ne 0) { throw "registry push to $PushRef failed" }
        Write-Host "[bk] pushed $PushRef" -ForegroundColor Green
    }
}

$elapsed = (Get-Date) - $started
Write-Host ("`n[bk] Done in {0:hh\:mm\:ss}. Stages: {1}{2}" -f $elapsed, ($Stages -join ', '), $(if ($Gpu) { ' (GPU)' } else { ' (CPU)' })) -ForegroundColor Green

} finally { Pop-Location }
