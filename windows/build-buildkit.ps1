# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

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
.NOTES
    INVOCATION TRAP (hit 2026-08-07): `pwsh -File .\windows\build-buildkit.ps1
    -Stages sdk,toolchain,media` passes the list as ONE string and dies on the
    ValidateSet ("sdk,toolchain,media does not belong to the set"). `-File`
    argument parsing does not build arrays. Call the script directly, or use the
    call operator with a real array when scripting it:

        & .\windows\build-buildkit.ps1 -Gpu -Stages @('sdk','toolchain','media')
        pwsh -Command "& .\windows\build-buildkit.ps1 -Stages @('sdk','media')"

    The ValidateSet is kept deliberately — it gives tab-completion and a precise
    error — so the fix is the call form, not a looser parameter.
#>
[CmdletBinding()]
param(
    [switch]$Gpu,
    # Compile TARGET. The build host is always windows/amd64 (Microsoft ships no
    # arm64 Windows container base image), so 'arm64' is a CROSS build out of the
    # same x64 container whose product is an artifact bundle, not a runnable
    # image. base/sdk/toolchain are host tooling and are SHARED by both targets;
    # only media onward forks, which is why WINDOWS_TARGET_ARCH is forwarded to
    # the media/merge/final stages and never to base.
    [ValidateSet('amd64', 'arm64')]
    [string]$TargetArch = 'amd64',
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
    # Extra build-args forwarded to EVERY solve, as 'KEY=VALUE'. Escape hatch for
    # one-off investigations (e.g. SCCACHE_REPRO_CUDA_LLM=1 for the upstream
    # sccache deadlock capture) without threading a bespoke parameter through the
    # whole driver. An unknown key is inert — the Dockerfile must declare a
    # matching ARG for it to have any effect, and BuildKit warns when it does not.
    [string[]]$BuildArg = @(),
    # SMOKE GATE (backlog #44). After `final`, the produced image is run through
    # smoke-test-container.ps1 and the chain FAILS if it does not pass. Neither
    # driver did this before 2026-08-14, so every chain shipped unverified.
    # -SkipSmokeGate is for iterating on the chain itself — it does not make an
    # unverified image safe to ship.
    [switch]$SkipSmokeGate,
    # Coverage floors, not just "0 failures": a fully-skipped run used to print
    # "All smoke tests passed!" and exit 0. Derived from the MEASURED baseline
    # (2026-08-14: 184 passed / 1 skipped) with a modest margin — the first
    # defaults (40 / 24) were inert: the script has only 23 Skip-Test sites, so
    # a ceiling of 24 could not trip even if EVERY section skipped, and a floor
    # of 40 tolerated losing 78 % of the assertion surface. Raise these together
    # with the recorded baseline when the suite grows; lower them EXPLICITLY for
    # a lane with genuinely fewer sections rather than by accident.
    [int]$SmokeMinPassed = 160,
    [int]$SmokeMaxSkipped = 3,
    # Per-stage cache bypass (backlog #64) — the lever the determinism gate
    # already tells you to pull when a snapshot is poisoned, e.g.
    #   -NoCacheStage opencv          (one media-core sub-stage)
    #   -NoCacheStage media-merge,torch
    # Matched as a substring against the stage LABEL shown in the build output
    # and in the log filename. Chain-wide -NoCache still overrides everything.
    [string[]]$NoCacheStage = @(),
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
    [string]$PushRef = '',
    # Override the host preflight gates (disk headroom + patched runhcs shim).
    # Both refuse for good reason — see Assert-DiskHeadroom / Assert-ShimPatch —
    # so this is for deliberate exceptions, not routine use.
    [switch]$SkipHostChecks,
    # Backlog #18: bypass ONLY the RDNA4 gate (e.g. after a driver update,
    # verified green via probe-build-copy.ps1 -Heavy) without also disarming
    # the disk/shim gates the way the all-or-nothing -SkipHostChecks does.
    [switch]$SkipRdna4Gate,
    # Bypass ONLY the buildkitd step-log-env gate (0a) for one launch when
    # the elevated restore has to wait for a between-runs window with an
    # admin present. The 2MiB clip stays active - causal errors still reach
    # the host via stderr and the buildctl error summary, but chatty step
    # middles are lost. Restore properly ASAP (setup-new-host.ps1).
    [switch]$SkipStepLogGate,
    # Free-space floor for the preflight gate; below ~25 GB hcsshim misbehaves
    # in ways that do not look like a disk problem.
    [int]$MinFreeGb = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {

Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force
# Canonical target-arch facts, so the driver derives the per-arch build-args it
# forwards from the SAME table the in-container scripts read, instead of
# re-spelling 'x64'/'arm64' here and letting the two drift.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsTargetArch.Common.psm1') -Force
# Shared transient-failure engine (unit-tested in BuildDriver.Retry.Tests) —
# the BK lane classifies against its own pattern: ActivateLayer 0x20 snapshot
# contention explicitly, NOT blanket 'hcsshim' (a genuine ExportLayer 0x3
# platform-defect hit must fail loudly, not burn a pointless retry).
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1') -Force

$script:LogDir = Join-Path $repoRoot 'out\windows-build-logs'
New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
# Per-RUN id (backlog #61): stage logs used to be named by label alone, so run
# N TRUNCATED run N-1's evidence — and Limit-DiagnosticLogs -Keep 80 never
# fired because there were only ~10 distinct names. With the id in the name,
# history accumulates and the existing Keep-80 rotation below actually rotates.
$script:RunId = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Stage -> seconds, written to a manifest at the end; on a green run this is
# the only place per-stage cost is recorded at all.
$script:StageTimings = [ordered]@{}
# Retention (backlog #30): stage logs are per-run keepsakes, not an archive -
# trim the tail so incident-day forensics stay navigable. 80 files ≈ several
# full chains; never-swallow-logs means the CURRENT incident always survives.
Limit-DiagnosticLogs -Directory $script:LogDir -Keep 80

# --- buildctl resolution (shared helper, #101; Shared.psm1 is imported above) -
if (-not $BuildCtl) {
    $BuildCtl = Get-PreferredToolPath -CommandName 'buildctl' -CandidatePaths @(
        "$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
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
# Separate failure, separate check (added 2026-08-07 after it cost a launched
# chain): the drift guard compares subnets of whatever conf it finds and passed
# green while buildkitd was handing containers NO network adapter, because the
# .conf had been renamed to .conflist for nerdctl's benefit. Both files must
# exist; this catches the wrong-filename case in milliseconds instead of at the
# first downloading RUN.
$cniForm = Get-CniConfFormIssue
if ($cniForm) { throw $cniForm }

# Transient-retry engine context (see the import note above for the pattern).
# 'failed to reimport snapshot' + 'failed to write compressed diff': hcs-temp
# sharing-violation/debris flakes at finalize/export time (2026-08-05 night —
# likely a realtime scanner racing the hcs scratch dirs; the completed RUN
# vertices stay cached, so the retry only re-pays the finalize/export step).
# NB 'failed to reimport snapshot(?!.*ExportLayer)': the reimport wrapper text
# also surrounds a genuine ExportLayer-0x3 defect hit, which MUST fail loudly
# (2026-08-05: two pointless retries of a deterministic 0x3 before the
# negative lookahead was added).
# 'failed to mount {windows-layer' / 'failed to calculate checksum of ref' ADDED
# 2026-08-07: the media MERGE stage was given -MaxAttempts 5 back on 2026-08-06
# precisely because this failure was measured going green only on the third
# attempt — but the pattern never matched it, so the classifier returned
# NON-transient and the retries never fired at all. The raised attempt count was
# dead code for the exact failure it was raised for. Watched it hard-fail on the
# first attempt today, which is what exposed the gap.
Initialize-BuildDriverContext -Docker 'docker.exe' -LogDir $script:LogDir -TransientPattern 'hcsshim::(Activate|Prepare)Layer.*0x20|ttrpc: closed|failed to create shim task|failed to create task for container|error during connect|rpc error: code = Unavailable|failed to reimport snapshot(?!.*ExportLayer)|failed to write compressed diff|failed to extract layer|failed to mount \{windows-layer|failed to calculate checksum of ref'

# --- versions (single source of truth) ---
$versions = ConvertFrom-VersionsEnv -Path (Join-Path $repoRoot 'linux\scripts\01-core\versions.env')
# Thin lane-local alias over the canonical lookup in WindowsBuildDriver.Common
# (see the same alias in build.ps1 — the two hand-copied bodies had already
# drifted to different error messages).
function Get-Ver([string]$Key) {
    return Get-VersionTableValue -VersionTable $versions -Key $Key
}
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# --- resource budget + sccache gate (canonical, shared with build.ps1 via
# WindowsBuildDriver.Common — the hand-copied twins had started drifting) ---
$MediaMemoryGb = Get-MediaMemoryBudget -RequestedGb $MediaMemoryGb -HostReserveGb $HostReserveGb
Write-Host "BuildKit lane: process isolation, all CPUs; memory budget $MediaMemoryGb GB (published via webdav, #51)" -ForegroundColor Cyan
Assert-SccacheEndpoint -Stages $Stages -SccacheEndpoint $SccacheEndpoint -NoSccache:$NoSccache

# --- cross-target gates: refuse the combinations that cannot work -------------
# Fail HERE, in milliseconds, rather than hours into a stage that was never
# going to produce anything usable.
if ($TargetArch -ne 'amd64') {
    if ($Gpu) {
        # CORRECTED 2026-08-24: this throw used to say CUDA, cuDNN and TensorRT
        # "have no Windows-on-ARM builds at all" and the lane was "CPU + Vulkan
        # only". Both halves were wrong, and already false at this repo's
        # current pins when checked: the cuDNN windows-arm64 9.25.0.15 archive
        # exists at the exact pin this file reads (fetched it: HTTP 200, 421 MB,
        # lib/arm64 inside), CUDA 13.4 (preview) advertises Windows ARM64
        # including x86_64-hosted cross-compile, and TensorRT-RTX publishes
        # Windows-on-Arm packages for CUDA 13.4. Only classic TensorRT is
        # genuinely x64-only (no ARM64 row in NVIDIA's support matrix). And the
        # arm64 lane has shipped DirectML since #113/#118. The refusal stays
        # because none of the CUDA stack is WIRED into this lane yet -- backlog
        # work, not fiction.
        throw ("-Gpu is not available for -TargetArch $TargetArch yet: the CUDA/cuDNN stack is not wired " +
               'for the cross lane (cuDNN and TensorRT-RTX do ship Windows-on-ARM packages; classic ' +
               'TensorRT does not). The arm64 lane is CPU + DirectML + Vulkan today.')
    }
    # Asking for torch EXPLICITLY is an error; inheriting it from the parameter
    # default just drops it with a notice -- the same distinction $MediaBranches
    # makes below. Throwing on the default made the documented invocation
    # `build-buildkit.ps1 -TargetArch arm64` fail 100 % of the time, because
    # $Stages defaults to @('base','sdk','toolchain','media','torch','final'):
    # every caller had to know to pass -Stages explicitly, and the error told
    # them so only after they had already hit it.
    if ($Stages -contains 'torch') {
        $torchWhy = ('the torch stage runs ``uv sync``, which must EXECUTE the target interpreter - impossible in a ' +
                     'cross build. Independently, the pinned PyTorch publishes no win_arm64 wheel for the pinned Python.')
        if ($PSBoundParameters.ContainsKey('Stages')) {
            throw "-Stages torch is not available for -TargetArch $TargetArch : $torchWhy Re-run without torch, e.g. -Stages base,sdk,toolchain,media,final"
        }
        $Stages = @($Stages | Where-Object { $_ -ne 'torch' })
        Write-Host "[bk] stage 'torch' dropped for $TargetArch : $torchWhy" -ForegroundColor Yellow
    }
    # Every media branch builds on the cross lane since 2026-08-24 (#115 plain
    # LiteRT, #116 TVM/IREE runtime-only). What a branch cannot build for the
    # target is decided INSIDE the branch and shipped as an empty, marker-carrying
    # tree (LiteRT-LM, the TVM/IREE compilers) -- see build-litert-all.ps1 and the
    # exclusion table in docs/windows-cross-builds.md. A driver-level "blocked
    # branches" refusal list lived here until 2026-08-25 and was removed once it
    # had been empty for a day: two mechanisms for one fact.
    Write-Host ("[bk] TARGET ARCH: $TargetArch (CROSS build - host stays windows/amd64). " +
                'Output is an artifact bundle, not a runnable image.') -ForegroundColor Yellow
}
# Which branches the merge fan-in requires before it may run: all three on
# BOTH lanes since 2026-08-24 (#115 made media-litert real on arm64, #116
# made media-tvm real -- runtime-only -- the same day). The former
# 'media-branch-absent' stand-in stage is retired; a cross branch that can
# not build ships its OWN empty, marker-carrying tree (litert-lm is the
# surviving example, see build-litert-all.ps1).
$script:MergeRequiredBranches = @('media-core', 'media-litert', 'media-tvm')
# Forwarded to the stages AFTER the arch fork only. base/sdk/toolchain are host
# tooling shared by both lanes; declaring this ARG there would re-pay the VS
# Build Tools layer on every lane switch.
#
# OPENCV_ARCH_DIR rides along because Dockerfile.media-merge-builder bakes
# OPENCV_LIB/OPENCV_BIN as ENV, and an ENV WINS over the arch-aware fallback in
# build-gstreamer-from-source.ps1 ($env:OPENCV_LIB is set, so the fallback never
# runs). Without it the arm64 lane resolves OpenCV's import libs under
# ...\opencv5\x64\vc18\lib, finds nothing, and dies with "no import libraries
# found" deep in the GStreamer pkg-config step. A Dockerfile cannot branch on an
# ARG, so the mapping is done here, from the same table the scripts read.
$archArgs = @{
    WINDOWS_TARGET_ARCH = $TargetArch
    OPENCV_ARCH_DIR     = Get-OpenCvArchDir -Arch $TargetArch
}
# ARCH_GATE_MIN_INSPECTED is a FLOOR, and the Dockerfile default of 10 is far
# below what a complete arm64 bundle actually contains (ONNX Runtime, GenAI,
# FFmpeg, OpenCV and GStreamer together stage well over a hundred DLLs). A floor
# that low cannot detect losing an entire component -- the gate would inspect the
# handful of files that survived and report green, which is precisely the
# "verified nothing, said PASS" failure Dockerfile.smoke-gate exists to document.
# Raised for the cross lane only, so the amd64 solve's build-args are unchanged.
if ($TargetArch -ne 'amd64') {
    $archArgs['ARCH_GATE_MIN_INSPECTED'] = '100'
    # #117: the merge fans the HOST CPython's site-packages into the image, and
    # the gate now scans that tree too. On the cross lane every .pyd in it is
    # the x64 build interpreter's -- legitimately host-arch, but it must show up
    # as a REPORTED allowlist skip, never as silent out-of-scope. Appended to
    # the Dockerfile default rather than replacing it.
    $archArgs['ARCH_GATE_HOST_TOOLS'] = 'protoc\.exe|flatc\.exe|\\_deps\\|\\cpython\\Lib\\site-packages\\'
}

# --- host preflight: the two failures that cost HOURS when discovered late ---
# Both were manual checklist items in docs/windows-host-setup.md § D3 until
# 2026-08-07, and both bit on 2026-08-06: a chain ran 2.5 h before dying of a
# disk shortage disguised as a missing ninja, and a Stevedore update can revert
# the shim patch so the first heavy finalize fails with ExportLayer 0x3 after
# the compile is already paid for. Two seconds here, hours saved there.
# -Drive: repo checkout's drive on top of C: (see the same call in build.ps1) —
# buildctl streams the local context from here on every solve.
Assert-DiskHeadroom -Drive @($repoRoot) -MinFreeGb $MinFreeGb -Force:$SkipHostChecks
Assert-ShimPatch -Force:$SkipHostChecks
# Host-drift preflight (backlog 0a): seconds at launch instead of a
# minute-80 surprise - the 2MiB step-log clip hid verdicts for a day.
Assert-BuildkitdStepLogEnv -Force:($SkipHostChecks -or $SkipStepLogGate)
Assert-NoActiveRdna4Gpu -Force:($SkipHostChecks -or $SkipRdna4Gate)

# --- tags: fully-qualified for containerd-store handoff; bk- namespaced so the
# classic docker lane's local/kataglyphis:windows-* tags can never collide ---
# amd64 keeps EXACTLY the historical names (no suffix) so the existing lane's
# cache and any external reference to bk-windows-* stay valid; a cross target
# appends its arch so the two lanes cannot collide in the local tag namespace.
# The stages BEFORE the arch fork (base/sdk/toolchain) are shared host tooling
# and deliberately keep the unsuffixed name for both targets - suffixing them
# would fork the most expensive layers in the chain for no benefit.
# Names exempt from the suffix: the pre-fork shared stages, and the final tags
# which already spell their arch (winamd64 / winarm64) - suffixing those would
# produce bk-winarm64-arm64.
$script:NoSuffixTags = @('windows-base', 'windows-sdk', 'windows-toolchain', 'winamd64', 'winarm64')
function Get-BkTag([string]$Name) {
    $suffix = if ($TargetArch -eq 'amd64' -or $script:NoSuffixTags -contains $Name) { '' } else { "-$TargetArch" }
    return "docker.io/local/kataglyphis:bk-$Name$suffix"
}

# The final image/bundle tag: winamd64 for the native lane, winarm64 for the
# cross lane. NB winarm64 labels a windows/amd64 image carrying an aarch64
# payload - never publish it with --platform windows/arm64, that yields a
# manifest nothing can run.
$script:FinalTagName = if ($TargetArch -eq 'arm64') { 'winarm64' } else { 'winamd64' }

# Get-TorchAppRef / Get-BuildVcsRef now live in WindowsBuildDriver.Common
# (Resolve-TorchAppRef / Get-BuildVcsRef) — shared with build.ps1.

# Which -NoCacheStage entries actually matched a stage label. Checked once at
# the end of the run so a typo fails LOUDLY instead of silently building
# everything from cache (backlog #64 follow-up).
$script:NoCacheStageMatched = @{}

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
        [switch]$NoOutput,
        # Raw --output spec override (e.g. docker-tar or push exporters); the
        # FinalTar/PushRef re-solves use this instead of the default image
        # output so they ride the same retry + log plumbing as every stage.
        [string]$OutputSpec = '',
        # Transient-failure budget. 3 suits every stage that touches ONE
        # snapshot tree; the media MERGE stage is the exception — it fans in
        # three branch images, so it does far more mount work than any other
        # stage and flakes proportionally (2026-08-06: two `failed to mount
        # {windows-layer}` failures in one run, green only on the third and
        # last attempt). Retries are cheap here: completed RUN vertices stay
        # cached, only the failed finalize/export re-runs.
        [int]$MaxAttempts = 3
    )
    if (-not $NoOutput -and -not $Tag -and -not $OutputSpec) { throw 'Invoke-BkStage: need -Tag, -OutputSpec or -NoOutput' }
    if (-not $Label) { $Label = [IO.Path]::GetFileName($Dockerfile) + $(if ($Target) { ":$Target" } else { '' }) }

    # PER-STAGE DISK GATE (2026-08-07). The start-of-run Assert-DiskHeadroom
    # passed at 164 GB free and the chain still walked down to 23 GB inside a
    # heavy stage — into the band where hcsshim stops failing honestly. Escaping
    # it meant killing the solve, and that kill poisoned a snapshot (3 failed
    # attempts + a -NoCache rebuild). Checking BEFORE each stage refuses to enter
    # a stage that cannot fit, while stopping is still free.
    #
    # Floors + message live in WindowsBuildDriver.Common so the CLASSIC lane —
    # the documented "always-working fallback", which had no per-stage gate at
    # all — enforces exactly the same numbers instead of a second copy that
    # drifts.
    # -Drive from the REPO root, not the 'C' default (backlog #48). The launch
    # gate learned this the hard way — the build context is the repo checkout,
    # on the reference host a dynamically-expanding VHDX at D:, which "fell to
    # 11.7 GB free while a C:-only gate reported everything fine". The per-stage
    # gate exists precisely because the launch gate is not enough, and it was
    # still looking at the wrong drive.
    Assert-StageDiskHeadroom -Label $Label -Drive (Split-Path -Qualifier $repoRoot).TrimEnd(':') -Force:$SkipHostChecks
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
    if ($OutputSpec) { $bkArgs += @('--output', $OutputSpec) }
    elseif (-not $NoOutput) { $bkArgs += @('--output', "type=image,name=$Tag,unpack=true") }
    # -NoCache is chain-wide; -NoCacheStage is per-stage (backlog #64). The
    # determinism gate tells the owner "the fix is -NoCache on this stage alone,
    # NOT a retry" (WindowsBuildDriver.Common) — advice the driver could not
    # express: for a poisoned media-core-built-opencv snapshot the only lever
    # was `-Stages media -NoCache`, which re-does all four media-core
    # sub-stages plus litert plus tvm plus merge. Matched against the same
    # $Label the stage logs and the disk gate already use, substring so
    # 'opencv' catches 'Dockerfile.media-builder:media-core-built-opencv'.
    $matched = @($NoCacheStage | Where-Object { $Label -like "*$_*" })
    # Record what matched so a typo can be caught at the END of the run
    # (Assert-NoCacheStageMatched). Printing only on a match is NOT visibility:
    # a misspelled entry would print nothing and the stage would build fully
    # cached while the owner believed it had been busted — the fail-open shape
    # this repo's conventions forbid.
    foreach ($m in $matched) { $script:NoCacheStageMatched[$m] = $true }
    $stageNoCache = $matched.Count -gt 0
    if ($NoCache -or $stageNoCache) { $bkArgs += @('--no-cache') }
    if ($stageNoCache -and -not $NoCache) { Write-Host "[bk:$Label] -NoCacheStage match -> --no-cache for THIS stage only" -ForegroundColor Yellow }
    if ($Target) { $bkArgs += @('--opt', "target=$Target") }
    # Optional cross-host cache (mode=max also caches non-exported intermediate
    # stages; per-stage refs suffixed with the label keep entries separable).
    if ($ImportCacheRef) { $bkArgs += @('--import-cache', "type=registry,ref=$ImportCacheRef") }
    if ($ExportCacheRef) { $bkArgs += @('--export-cache', "type=registry,ref=$ExportCacheRef,mode=max") }
    foreach ($k in ($BuildArgs.Keys | Sort-Object)) {
        $v = $BuildArgs[$k]
        if ($null -ne $v -and "$v" -ne '') { $bkArgs += @('--opt', "build-arg:$k=$v") }
    }
    # Arch is the one build-arg whose absence is INVISIBLE downstream: the stage
    # just falls back to its amd64 ARG default and the failure surfaces much
    # later as something unrelated (2026-08-23: "libonnxruntime not found", which
    # was really an x64 link probe against an arm64 library). Name it per solve.
    if ($BuildArgs.ContainsKey('WINDOWS_TARGET_ARCH')) {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH=$($BuildArgs['WINDOWS_TARGET_ARCH'])" -ForegroundColor DarkGray
    } elseif ($TargetArch -ne 'amd64') {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH NOT PASSED to this stage (target is $TargetArch) - it will default to amd64" -ForegroundColor Yellow
    }
    # -BuildArg passthrough, applied LAST so an explicit one-off overrides the
    # stage's computed value rather than being silently dropped by it.
    foreach ($extra in $BuildArg) {
        # Strict KEY validation, not just "has an =": buildctl silently
        # discards build-args for ARG names no Dockerfile declares, so a
        # mangled key is invisible downstream. Seen live 2026-08-18: a caller
        # used `& pwsh -File`, which flattens a comma array into ONE literal
        # string with the quotes kept — the "key" began with an apostrophe,
        # buildctl dropped it, and an 88-minute repro measured nothing.
        if ($extra -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            throw ("-BuildArg '$extra' is not in KEY=VALUE form with a clean identifier key. " +
                'If several args arrived as ONE quoted string, the caller crossed a process boundary ' +
                '(`pwsh -File` flattens comma arrays, quotes included) - invoke build-buildkit.ps1 ' +
                'directly or pass one -BuildArg element per KEY=VALUE.')
        }
        $bkArgs += @('--opt', "build-arg:$extra")
    }
    $stageLog = Join-Path $script:LogDir ("bk-" + $script:RunId + "-" + ($Label -replace '[:\\/]', '-') + ".log")
    $stageClock = [System.Diagnostics.Stopwatch]::StartNew()
    $dest = if ($NoOutput) { '(warm solve, no output)' } else { $Tag }
    # ONE automatic retry on transient container-infrastructure failures via
    # the shared, unit-tested engine (WindowsBuildDriver.Common; pattern set
    # in Initialize-BuildDriverContext above — ActivateLayer 0x20 snapshot
    # contention + ttrpc/shim races; a manual 0x20 re-run cost us 2026-08-04).
    # 3 attempts (was 2): the hcs-temp finalize flake family occasionally
    # burns both under load (2026-08-05: mkdir access-denied THEN 0x20 on the
    # retry, during a parallel canary export). Third attempt is cheap — the
    # completed RUN vertices stay cached; only finalize/export re-runs.
    # Fresh log per RUN, APPENDED per ATTEMPT (backlog #41). Until 2026-08-14
    # the Tee below had no -Append, so attempt 2 TRUNCATED attempt 1: a stage
    # that burned its budget kept only the last attempt, and when attempt 1
    # held the real compile error while 2-3 died on infra flakes the evidence
    # was destroyed. That is a "never swallow logs" violation inside the very
    # path that exists to survive failures. Clear once here, append per attempt.
    Remove-Item -Path $stageLog -Force -ErrorAction SilentlyContinue
    $previousTail = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "`n==> [bk:$Label] buildctl -> $dest$(if ($attempt -gt 1) { ' (retry)' })" -ForegroundColor Cyan
        "`n===== [bk:$Label] attempt $attempt/$MaxAttempts =====" | Add-Content -Path $stageLog -Encoding utf8
        & $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $stageLog -Append
        if ($LASTEXITCODE -eq 0) { break }
        $tail = if (Test-Path $stageLog) { (Get-Content $stageLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        # -PreviousTail arms the determinism gate: an identical failure means a
        # poisoned snapshot, not a flake, and retrying it just burns the budget
        # (measured 2026-08-07: 3x ImportLayer 0xb7 on the same snapshot IDs).
        if (Invoke-TransientCooldown -Tail $tail -PreviousTail $previousTail -Attempt $attempt -MaxAttempts $MaxAttempts -Label "bk:$Label" -CooldownSeconds 15) {
            $previousTail = $tail
            continue
        }
        # Surface the CAUSE, not just a path (backlog #42). This tail was
        # already computed for the determinism gate above and then discarded,
        # leaving the owner to open a deliberately-unbounded log by hand — the
        # "hunting through 2.5MB logs" loop, two lines from fixed.
        if ($tail) {
            Write-Host "`n--- [bk:$Label] tail of the failing attempt ---" -ForegroundColor Yellow
            Write-Host $tail
            Write-Host "--- end of tail (full log: $stageLog) ---`n" -ForegroundColor Yellow
        }
        throw "[bk:$Label] buildctl failed (exit $LASTEXITCODE) — full log: $stageLog"
    }
    $stageClock.Stop()
    $script:StageTimings[$Label] = [math]::Round($stageClock.Elapsed.TotalSeconds, 1)
    Write-Host ("[bk:{0}] OK -> {1}  ({2:hh\:mm\:ss})" -f $Label, $dest, $stageClock.Elapsed) -ForegroundColor Green
}

$sccache = @{ SCCACHE_WEBDAV_ENDPOINT = $SccacheEndpoint }

# Preseed the vulkan SDK exe onto the LAN webdav so containers never pull it
# from the vendor: sdk.lunarg.com stalls out reproducibly INSIDE containers
# (2026-08-19: three ~20-min 275 MB transfers, all died mid-stream) while the
# host pulls the same file fine. Fail-open at every step - a failure here
# just leaves the container on its own (retried) direct-download path.
if ($SccacheEndpoint) {
    try {
        $vkVer = Get-Ver 'VULKAN_VERSION'
        $vkName = "vulkansdk-windows-X64-$vkVer.exe"
        $vkOnDav = "$SccacheEndpoint/preseed/$vkName"
        $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
        & $curlExe -sfI $vkOnDav *> $null
        if ($LASTEXITCODE -ne 0) {
            $vkLocal = Join-Path $PSScriptRoot 'downloads' $vkName
            if (-not (Test-Path $vkLocal)) {
                Write-Host "preseed: downloading $vkName host-side..."
                & $curlExe -sfL --retry 3 --retry-delay 5 --retry-all-errors "https://sdk.lunarg.com/sdk/download/$vkVer/windows/$vkName" -o $vkLocal
                if ($LASTEXITCODE -ne 0) { throw "host download failed (exit $LASTEXITCODE)" }
            }
            & $curlExe -sf --retry 3 --retry-delay 5 --retry-all-errors -T $vkLocal $vkOnDav
            if ($LASTEXITCODE -ne 0) { throw "webdav PUT failed (exit $LASTEXITCODE)" }
            Write-Host "preseed: $vkName staged at $vkOnDav"
        } else {
            Write-Host "preseed: $vkName already on the webdav"
        }
    } catch {
        Write-Warning "vulkan preseed skipped (container falls back to direct download): $($_.Exception.Message)"
    }
    $global:LASTEXITCODE = 0

    # #51: MEMORY_LIMIT_GB is a SCHEDULING knob and must not be an image
    # ARG/ENV (cache key - toggling -ConcurrentAux used to invalidate every
    # litert/tvm compile; a different-RAM host invalidated everything).
    # Published here instead; Get-BuildJobCount reads it via the endpoint.
    # PHASED under -ConcurrentAux (audit 2026-08-21 #16): the schedule is
    # sequential-then-parallel — media-core runs ALONE and gets the FULL
    # budget (the old single halved publish ran the memory-bound long pole,
    # ONNX, at half RAM with nothing else on the host); the halved budget is
    # re-published just before the two children spawn, and the full one again
    # before the merge stage (GStreamer reads it too).
    function Publish-MemoryBudget {
        param([Parameter(Mandatory)][int]$Gb, [string]$Phase = '')
        try {
            $memBody = Join-Path $env:TEMP 'memory-limit-gb.txt'
            Set-Content -Path $memBody -Value "$Gb" -Encoding ascii -NoNewline
            & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf -T $memBody "$SccacheEndpoint/preseed/memory-limit-gb.txt"
            $phaseNote = if ($Phase) { " ($Phase)" } else { '' }
            if ($LASTEXITCODE -eq 0) { Write-Host "preseed: memory-limit-gb=$Gb published$phaseNote" }
            else { Write-Warning "memory-limit publish failed (exit $LASTEXITCODE) - containers fall back to CIM host RAM" }
        } catch {
            Write-Warning "memory-limit publish skipped: $($_.Exception.Message)"
        }
        $global:LASTEXITCODE = 0
    }
    Publish-MemoryBudget -Gb ([int]$MediaMemoryGb) -Phase 'sequential phase'
}

$started = Get-Date

if ($Stages -contains 'base') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.base' -Tag (Get-BkTag 'windows-base') -BuildArgs @{
        WINDOWS_LTSC          = Get-Ver 'WINDOWS_LTSC'
        WINDOWS_BASE_DIGEST   = Get-Ver 'WINDOWS_BASE_DIGEST'
        VULKAN_VERSION        = Get-Ver 'VULKAN_VERSION'
        # LAN source for the 275 MB SDK exe (see the preseed block above).
        VULKAN_PRESEED_ENDPOINT = $SccacheEndpoint
        CMAKE_VERSION         = Get-Ver 'CMAKE_VERSION'
        # Compiled-output pins — see the same block in build.ps1.
        LLVM_WINDOWS_VERSION  = Get-Ver 'LLVM_WINDOWS_VERSION'
        NINJA_WINDOWS_VERSION = Get-Ver 'NINJA_WINDOWS_VERSION'
        NASM_WINDOWS_VERSION  = Get-Ver 'NASM_WINDOWS_VERSION'
        PWSH_VERSION          = Get-Ver 'PWSH_VERSION'
        PWSH_ZIP_SHA256       = Get-Ver 'PWSH_ZIP_SHA256'
        WINDOWS_SDK_BUILD     = Get-Ver 'WINDOWS_SDK_BUILD'
        VISUAL_STUDIO_VERSION = Get-Ver 'VISUAL_STUDIO_VERSION'
        # #50 (2026-08-18): consumed below versions.env's relocated COPY, so
        # they ride as ARGs - a Linux-key edit no longer re-pays scoop/vcpkg/
        # rust. Keep in sync with the ARG block in Dockerfile.base.
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
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.nvidia' -Context 'windows' -Tag (Get-BkTag 'windows-sdk') -BuildArgs @{
            BASE_IMAGE               = Get-BkTag 'windows-base'
            CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
            CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
            CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
            TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
            CUDA_INSTALLER_SHA256    = Get-Ver 'CUDA_INSTALLER_SHA256'
            CUDNN_ZIP_SHA256         = Get-Ver 'CUDNN_ZIP_SHA256'
            TENSORRT_ZIP_SHA256      = Get-Ver 'TENSORRT_ZIP_SHA256'
        }
    } else {
        # CPU lane: containerd has no unprivileged `tag`; re-export base under
        # the sdk name via a trivial FROM (cache-hit, seconds).
        $alias = Join-Path $script:LogDir 'Dockerfile.bk-sdk-alias'
        "FROM $(Get-BkTag 'windows-base')`r`n" | Set-Content $alias -Encoding ASCII
        Invoke-BkStage -Dockerfile ('out/windows-build-logs/' + [IO.Path]::GetFileName($alias)) -Tag (Get-BkTag 'windows-sdk') -Label 'bk-cpu-alias'
    }
}

if ($Stages -contains 'toolchain') {
    # No $sccache here: Dockerfile.toolchain-builder declares no such ARG and
    # build-toolchain-all.ps1 has no sccache wiring (MSBuild/ClangCL toolset) —
    # forwarding it only produced an "unused build-arg" frontend warning.
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Target 'built' -Tag (Get-BkTag 'windows-toolchain') -BuildArgs @{
        BASE_IMAGE     = Get-BkTag 'windows-sdk'
        PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
    }
}

if ($Stages -contains 'media') {
    # Canonical per-branch version args (WindowsBuildDriver.Common — shared
    # with build.ps1; the hand-copied maps had already started drifting).
    $branchArgs = @{}
    foreach ($b in 'media-core', 'media-litert', 'media-tvm') {
        $branchArgs[$b] = Get-MediaBranchVersionArg -Branch $b -VersionTable $versions
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
        } + $branchArgs[$branch] + $sccache + $archArgs
        if ($branch -eq 'media-core') {
            # DIRECT SOLVES (de-warmed 2026-08-06, round 2): every library
            # layer builds and exports in one solve. The former
            # warm/materialize pairs existed for the ExportLayer-0x3 defect —
            # ROOT CAUSE was the runhcs shim's hardcoded 30s tearDownTimeout
            # terminating the ~2-min heavy-churn silo teardown mid-flush;
            # FIXED by the patched shim (45min) in Stevedore\bin — see
            # docs/windows-builds.md § roadmap "DEFECT SOLVED" incl. the
            # maintenance rule (Stevedore updates overwrite the patch!) and
            # the 3x OPENCV canary recipe after any shim/OS change.
            # Per-library split retained: per-layer caching + an FFmpeg fix
            # still never re-pays ONNX.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-onnx' -Tag (Get-BkTag 'windows-media-core-onnx') -BuildArgs $branchBuildArgs
            $onnxArg   = @{ MEDIA_CORE_ONNX_IMAGE = Get-BkTag 'windows-media-core-onnx' }
            $opencvArg = @{ MEDIA_CORE_OPENCV_IMAGE = Get-BkTag 'windows-media-core-opencv' }
            $ffmpegArg = @{ MEDIA_CORE_FFMPEG_IMAGE = Get-BkTag 'windows-media-core-ffmpeg' }
            # ORDER: onnx -> FFMPEG -> OPENCV -> genai (swapped 2026-08-16,
            # backlog #94). OpenCV must configure AFTER FFmpeg exists or it
            # silently links its own downloaded prebuilt FFmpeg instead of this
            # chain's. Keep this in step with the FROM graph in
            # Dockerfile.media-builder — the two encode the same order twice.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-ffmpeg' -Tag (Get-BkTag 'windows-media-core-ffmpeg') -BuildArgs ($branchBuildArgs + $onnxArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-opencv' -Tag (Get-BkTag 'windows-media-core-opencv') -BuildArgs ($branchBuildArgs + $ffmpegArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built' -Tag (Get-BkTag 'windows-media-core') -BuildArgs ($branchBuildArgs + $opencvArg)
        } else {
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target "$branch-built" -Tag (Get-BkTag "windows-$branch") -BuildArgs $branchBuildArgs
        }
    }
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        Write-Host "`n==> [bk:aux] concurrent litert + tvm child drivers ($auxMem GB memory budget each)" -ForegroundColor Cyan
        # Parallel phase begins: halve the published budget for the two
        # concurrent children (see Publish-MemoryBudget's phased contract).
        if (Get-Command Publish-MemoryBudget -ErrorAction SilentlyContinue) {
            Publish-MemoryBudget -Gb ([Math]::Max(8, [int]($MediaMemoryGb / 2))) -Phase 'parallel aux phase'
        }
        foreach ($aux in 'media-litert', 'media-tvm') {
            $auxArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Stages', 'media', '-MediaBranches', $aux, '-MediaMemoryGb', $auxMem)
            if ($Gpu) { $auxArgs += '-Gpu' }
            if ($SccacheEndpoint) { $auxArgs += @('-SccacheEndpoint', $SccacheEndpoint) }
            # Children inherit the cache/tooling knobs — without these a
            # -NoCache parent quietly built its aux branches FROM cache.
            if ($NoCache) { $auxArgs += '-NoCache' }
            # -NoCacheStage MUST ride along too: under -ConcurrentAux the litert
            # and tvm branches are built by these CHILD processes, so a parent-only
            # flag is a silent no-op for exactly the branches it targets — and a
            # poisoned snapshot in litert/tvm is the scenario the flag exists for.
            # Forward ONLY the entries this child's branch can match: the child
            # builds one aux branch, and its end-of-run matched-nothing gate
            # would otherwise throw on a parent-scoped label like 'opencv'
            # (audit 2026-08-21 #5) — killing the chain AFTER the branches
            # were paid for. NB -File cannot deliver arrays (documented in
            # .NOTES), so entries go one-per-argument, not comma-joined.
            $auxNoCache = @($NoCacheStage | Where-Object { $aux -match [regex]::Escape(($_ -replace '^media-', '')) -or $_ -match ($aux -replace '^media-', '') })
            foreach ($ncs in $auxNoCache) { $auxArgs += @('-NoCacheStage', $ncs) }
            if ($ImportCacheRef) { $auxArgs += @('-ImportCacheRef', $ImportCacheRef) }
            if ($ExportCacheRef) { $auxArgs += @('-ExportCacheRef', $ExportCacheRef) }
            if ($BuildCtl) { $auxArgs += @('-BuildCtl', $BuildCtl) }
            # PREFLIGHT OVERRIDES — each child re-runs the FULL host preflight,
            # so an override the parent was launched with MUST reach it or the
            # child throws 1-2h in, after media-core is already paid for
            # (backlog #62). Three combinations were guaranteed failures:
            #   -Gpu -ConcurrentAux -SkipRdna4Gate   -> both children threw on
            #        the RDNA4 gate (the documented post-driver-update path)
            #   -ConcurrentAux -SkipHostChecks       -> children threw on disk
            #   -ConcurrentAux -NoSccache            -> children threw on the
            #        sccache-required gate; this one could NEVER succeed.
            if ($SkipHostChecks) { $auxArgs += '-SkipHostChecks' }
            if ($SkipRdna4Gate) { $auxArgs += '-SkipRdna4Gate' }
            if ($SkipStepLogGate) { $auxArgs += '-SkipStepLogGate' }
            if ($NoSccache) { $auxArgs += '-NoSccache' }
            if ($PSBoundParameters.ContainsKey('MinFreeGb')) { $auxArgs += @('-MinFreeGb', $MinFreeGb) }
            if ($PSBoundParameters.ContainsKey('HostReserveGb')) { $auxArgs += @('-HostReserveGb', $HostReserveGb) }
            # Forward -BuildArg too: under -ConcurrentAux the litert/tvm solves
            # are the CHILDREN's, so a parent-only compile knob was a silent
            # no-op for two of three branches (audit 2026-08-21 #17).
            foreach ($ba in $BuildArg) { $auxArgs += @('-BuildArg', $ba) }
            # QUOTE spaced elements: Start-Process -ArgumentList joins with
            # spaces and does NOT quote, so a buildctl under
            # 'C:\Program Files\Stevedore' (this host since 2026-08-21!) or a
            # spaced checkout path split mid-token and killed both children
            # right after media-core (audit 2026-08-21 #4 — the same
            # argv-boundary class this file hard-throws on for -BuildArg).
            $auxArgsQuoted = @($auxArgs | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } })
            $auxProcs += Start-Process -FilePath 'pwsh' -ArgumentList $auxArgsQuoted -PassThru -NoNewWindow
        }
        # FAIL FAST + never orphan (backlog #62). Wait-Process on the whole set
        # meant a child dying at minute 5 went unnoticed until the other
        # finished ~40 min later; and because the children are spawned outside
        # any try/finally, killing the parent used to leave two pwsh+buildctl
        # trees solving against the same store, which then raced a relaunch.
        try {
            while ($true) {
                $exited = @($auxProcs | Where-Object { $_.HasExited })
                $failed = @($exited | Where-Object { $_.ExitCode -ne 0 })
                if ($failed) {
                    throw "[bk:aux] concurrent branch driver (pid $($failed[0].Id)) failed (exit $($failed[0].ExitCode)) — aborting the remaining aux branch(es)"
                }
                if ($exited.Count -eq $auxProcs.Count) { break }
                Start-Sleep -Seconds 5
            }
        } finally {
            foreach ($p in $auxProcs) {
                if (-not $p.HasExited) {
                    Write-Host "[bk:aux] stopping child driver pid $($p.Id)" -ForegroundColor Yellow
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
        # (No second exit-code sweep: the wait loop above already throws on the
        # FIRST non-zero child rather than after every child has finished.)
        Write-Host '[bk:aux] litert + tvm OK' -ForegroundColor Green
        # Parallel phase over: the merge stage (GStreamer reads the budget
        # too) runs alone again — restore the full budget.
        if (Get-Command Publish-MemoryBudget -ErrorAction SilentlyContinue) {
            Publish-MemoryBudget -Gb ([int]$MediaMemoryGb) -Phase 'merge phase'
        }
    }
    # Merge fan-in needs ALL THREE branch images — and must run exactly ONCE.
    # -ConcurrentAux children are spawned with a single -MediaBranches entry,
    # so this gate keeps them out of the merge (previously every child ALSO
    # ran it: 3 merge runs, 2 concurrent, racing the same gstreamer.tar
    # handoff and referencing branch tags that might not exist yet).
    $allBranches = $script:MergeRequiredBranches
    $runMerge = @($allBranches | Where-Object { $_ -notin $MediaBranches }).Count -eq 0
    if ($runMerge) {
        # Both lanes fan in REAL branch images since 2026-08-24 (#115 litert,
        # #116 tvm/iree runtime-only). The 'media-branch-absent' stand-in that
        # used to substitute for unbuildable cross branches is retired; the
        # merge Dockerfile's unconditional COPY --from=... lines are satisfied
        # by each branch shipping its own (possibly empty, marker-carrying) tree.
        $litertImage = Get-BkTag 'windows-media-litert'
        $tvmImage    = Get-BkTag 'windows-media-tvm'
        # Canonical merge version env (WindowsBuildDriver.Common) + BK tag wiring.
        $mergeArgs = (Get-MediaMergeVersionArg -VersionTable $versions) + @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
            CORE_IMAGE      = Get-BkTag 'windows-media-core'
            LITERT_IMAGE    = $litertImage
            TVM_IMAGE       = $tvmImage
        } + $archArgs
        # Direct solve (de-warmed 2026-08-05 — see the media-core comment above).
        # -MaxAttempts 5: the fan-in stage mounts three branch trees and is the
        # only stage measured burning its whole 3-attempt budget (2026-08-06).
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -Target 'built' -Tag (Get-BkTag 'windows-media') -BuildArgs ($mergeArgs + $sccache) -MaxAttempts 5
    } else {
        # FAIL CLOSED (backlog #39). Skipping the merge is fine on its own — the
        # owner asked for a branch subset. It is NOT fine when torch/final are
        # also selected: those stages resolve BASE_IMAGE from the
        # 'windows-media' tag, which still points at the PREVIOUS run's merge.
        # So `-Stages media,torch,final -MediaBranches media-litert` (the
        # natural "I fixed LiteRT, re-ship" invocation) used to rebuild litert,
        # print one yellow line, and then ship a winamd64 WITHOUT the fix —
        # silently, with a zero exit code. The classic lane never had this hole
        # (build.ps1 merges unconditionally + Assert-ImageExists).
        $downstream = @('torch', 'final') | Where-Object { $Stages -contains $_ }
        if ($downstream) {
            throw ("[bk:merge] REFUSING to build $($downstream -join '+') from a STALE '$(Get-BkTag 'windows-media')': " +
                   "the merge was skipped because -MediaBranches is a subset (got: $($MediaBranches -join ', '); " +
                   "needs all of: $($allBranches -join ', ')). Those stages would silently ship the PREVIOUS run's media image. " +
                   'Either run all three branches, or drop torch/final from -Stages and re-run them after a full media pass.')
        }
        Write-Host "[bk:merge] skipped (needs all three media branches; got: $($MediaBranches -join ', '))" -ForegroundColor Yellow
    }
}

# Provenance stamps: computed ONCE so the final solve and its FinalTar/PushRef
# re-solves share identical build-args (previously the re-solves dropped
# BUILD_DATE/VCS_REF and regenerated the LABEL layer with empty values — the
# pushed artifact was not the locally exported image).
$stampArgs = @{
    BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    VCS_REF    = Get-BuildVcsRef
}

if ($Stages -contains 'torch') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.torch' -Tag (Get-BkTag 'windows-torch') -BuildArgs ($stampArgs + @{
        BASE_IMAGE = Get-BkTag 'windows-media'
        APP_REF    = Resolve-TorchAppRef -VersionTable $versions -LatestApp:$LatestApp
        # Backend extra from the app's pyproject — without this a -Gpu chain
        # shipped CPU torch in a CUDA image (Dockerfile default: pytorch-cpu).
        PYTORCH_EXTRA = $(if ($Gpu) { 'pytorch-cu130' } else { 'pytorch-cpu' })
    })
}

if ($Stages -contains 'final') {
    # The arm64 lane skips the torch stage (guarded at launch), so its final
    # image is based on the merged media stage directly.
    $finalBase = if ($TargetArch -eq 'amd64') { Get-BkTag 'windows-torch' } else { Get-BkTag 'windows-media' }
    $finalArgs = $stampArgs + @{ BASE_IMAGE = $finalBase } + $archArgs
    # -Label 'final' (audit 2026-08-21 #14): the default label is the
    # Dockerfile filename ('Dockerfile'), so -NoCacheStage final matched
    # only final-tar/final-push — busting the re-EXPORT while the owner
    # believed the final stage was rebuilt.
    Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final' -Tag (Get-BkTag $script:FinalTagName) -BuildArgs $finalArgs
    # SMOKE GATE (backlog #44). Until 2026-08-14 neither driver ran the smoke
    # test at all, so a multi-hour chain ended with "Done" and zero evidence the
    # image worked — in a repo whose defect history is dominated by "builds
    # fine, fails to LOAD". Runs as a buildctl solve, not `nerdctl run`,
    # because containerd's pipe is admin-only and this driver is deliberately
    # non-admin. -SkipSmokeGate exists for iterating on the chain itself; it is
    # NOT a way to ship an unverified image.
    if ($TargetArch -ne 'amd64' -and -not $SkipSmokeGate) {
        # CROSS LANE (re-scoped 2026-08-24; until then this branch skipped the
        # gate entirely as "NOT APPLICABLE"). That blanket verdict was over-broad:
        # ~49 of the suite's assertions never touch the payload -- sections 1-6
        # and 14-16 exercise the amd64 HOST toolchain inside this amd64 container
        # (rustc/clang-cl compile+link+RUN, ASAN, CMake+Ninja, MSBuild) and §19's
        # pointer checks are pure filesystem reads. smoke-test-container.ps1 now
        # skips the payload sections itself (it resolves the lane from the baked
        # WINDOWS_TARGET_ARCH) and applies the arm64 column of $sectionFloors.
        #
        # The floors here are the ARM64 lane's own numbers, not lowered amd64
        # ones: 66 sits just under the arm64 per-section floor sum (73), the same
        # relationship the CPU 160/161 pair has. An explicit -SmokeMinPassed
        # still wins. What this gate can NEVER prove on this host is that the
        # aarch64 payload RUNS -- that stays with verify-target-arch.ps1 (static
        # PE gate in the merge stage) and is impossible until a windows-11-arm
        # runner exists.
        # Distinctly named so Smoke.FloorCalibration.Tests.ps1 can pin the arm64
        # floor against the arm64 section-floor sum without colliding with the
        # GPU lane's $effectiveMinPassed below.
        $armMinPassed = 66
        $armMaxSkipped = 25
        if ($PSBoundParameters.ContainsKey('SmokeMinPassed')) { $armMinPassed = $SmokeMinPassed }
        if ($PSBoundParameters.ContainsKey('SmokeMaxSkipped')) { $armMaxSkipped = $SmokeMaxSkipped }
        Write-Host ("[bk:smoke-gate] cross lane: HOST-toolchain sections run (floors: MIN_PASSED=$armMinPassed, " +
                    "MAX_SKIPPED=$armMaxSkipped); payload sections are skipped in-suite — the aarch64 payload " +
                    'itself remains statically verified only (verify-target-arch.ps1, merge stage).') -ForegroundColor Yellow
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs @{
            BASE_IMAGE  = Get-BkTag $script:FinalTagName
            MIN_PASSED  = "$armMinPassed"
            MAX_SKIPPED = "$armMaxSkipped"
            EXPECT_GPU  = '0'
        } -MaxAttempts 1
    } elseif ($TargetArch -ne 'amd64') {
        Write-Host '[bk:smoke-gate] skipped (-SkipSmokeGate). NB the arm64 payload is statically verified only.' -ForegroundColor Yellow
    } elseif (-not $SkipSmokeGate) {
        # LANE-AWARE FLOOR (2026-08-22). 160 is the CPU-lane number: it sits just
        # under the sum of the per-section CPU floors (161). On the GPU lane the
        # same 160 tolerated losing 60 of the 220 assertions a green run actually
        # executes — a quarter of the surface — because CUDA/cuDNN, the CUDA EPs
        # and the GPU-only halves of several sections all ride on -Gpu. Derived,
        # not guessed: 190 is the sum of the GPU column of $sectionFloors in
        # smoke-test-container.ps1 (measured green run: 220). An explicit
        # -SmokeMinPassed always wins, so a lane with genuinely fewer sections
        # still lowers it deliberately rather than by accident.
        $effectiveMinPassed = $SmokeMinPassed
        if ($Gpu -and -not $PSBoundParameters.ContainsKey('SmokeMinPassed')) {
            $effectiveMinPassed = 190
            Write-Host "smoke gate: GPU lane floor $effectiveMinPassed (CPU default is $SmokeMinPassed)"
        }
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs @{
            BASE_IMAGE  = Get-BkTag $script:FinalTagName
            MIN_PASSED  = "$effectiveMinPassed"
            MAX_SKIPPED = "$SmokeMaxSkipped"
            EXPECT_GPU  = $(if ($Gpu) { '1' } else { '0' })
        } -MaxAttempts 1
        Write-Host '[bk:smoke-gate] image verified' -ForegroundColor Green
    } else {
        Write-Host '[bk:smoke-gate] SKIPPED (-SkipSmokeGate) — this image is UNVERIFIED' -ForegroundColor Yellow
    }
# FAIL LOUDLY (moved pre-export, audit #15) on a -NoCacheStage entry that matched nothing. Printing only on a
    # match is not visibility: a typo would print nothing, every stage would build
    # fully cached, and the owner would believe a poisoned snapshot had been busted.
    $unmatchedNoCacheStage = @($NoCacheStage | Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })
    if ($unmatchedNoCacheStage.Count -gt 0) {
        throw ("[bk] -NoCacheStage matched NO stage in this run: $($unmatchedNoCacheStage -join ', '). " +
               'Every stage built from cache, so nothing was busted. Check the spelling against the ' +
               'stage labels in the output above (they are the same labels used for the log filenames).')
    }
    # FinalTar / PushRef: the same final solve from cache, different exporter —
    # via Invoke-BkStage so both get the transient retry + stage log for free.
    # Same $finalArgs so the re-solve is a pure cache hit of the export above.
    # Push auth: buildctl forwards THIS shell's docker credential store — run
    # `docker login <registry>` here first.
    if ($FinalTar) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-tar' -OutputSpec "type=docker,name=local/kataglyphis:$($script:FinalTagName),dest=$FinalTar" -BuildArgs $finalArgs
    }
    if ($PushRef) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-push' -OutputSpec "type=image,name=$PushRef,push=true" -BuildArgs $finalArgs
        Write-Host "[bk] pushed $PushRef" -ForegroundColor Green
    }
}

# The -NoCacheStage matched-nothing gate fires PRE-EXPORT inside the final
# block (audit 2026-08-21 #15: it used to fire only after -PushRef had already
# published a fully-cached image). This tail copy covers runs WITHOUT 'final'
# in -Stages, where the pre-export site never executes.
if ($Stages -notcontains 'final') {
    $unmatchedNoCacheStage = @($NoCacheStage | Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })
    if ($unmatchedNoCacheStage.Count -gt 0) {
        throw ("[bk] -NoCacheStage matched NO stage in this run: $($unmatchedNoCacheStage -join ', '). " +
               'Every stage built from cache, so nothing was busted. Check the spelling against the ' +
               'stage labels in the output above (they are the same labels used for the log filenames).')
    }
}

$elapsed = (Get-Date) - $started
# Run manifest (backlog #61): per-stage seconds, machine-parseable, one file
# per run — before this, a green run recorded NO per-stage cost anywhere and
# regressions like "export got slow" were only findable by log archaeology.
if ($script:StageTimings.Count -gt 0) {
    $manifest = Join-Path $script:LogDir ("bk-" + $script:RunId + "-manifest.txt")
    $lines = @("run=$($script:RunId) stages=$($Stages -join ',') gpu=$([bool]$Gpu) total_s=$([math]::Round($elapsed.TotalSeconds,1))")
    foreach ($k in $script:StageTimings.Keys) { $lines += ("{0}={1}" -f $k, $script:StageTimings[$k]) }
    Set-Content -Path $manifest -Value $lines -Encoding utf8
    Write-Host "`n[bk] per-stage timings:" -ForegroundColor Cyan
    foreach ($k in $script:StageTimings.Keys) { Write-Host ("  {0,8:N1}s  {1}" -f $script:StageTimings[$k], $k) }
    Write-Host "[bk] manifest: $manifest"
}
Write-Host ("`n[bk] Done in {0:hh\:mm\:ss}. Stages: {1}{2}" -f $elapsed, ($Stages -join ', '), $(if ($Gpu) { ' (GPU)' } else { ' (CPU)' })) -ForegroundColor Green

} finally { Pop-Location }
