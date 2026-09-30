# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#Requires -Version 7.0

<#
.SYNOPSIS
    BuildKit/containerd driver for the Windows image chain, every stage process-isolated with all host CPUs.
.DESCRIPTION
    Needs the buildkitd/containerd services and the CNI nat conf; images land in containerd as bk-<stage>, invisible to docker.
    Call it directly or with &: pwsh -File passes -Stages as one string and fails the ValidateSet.
.PARAMETER FinalTar
    Also export the final image as a docker-load tar.
.PARAMETER Variant
    '' (CPU + DirectML), nvidia (= -Gpu) or rocm (amd64 only); both variants take the sdk slot under their own tags.
.PARAMETER Stages
    Subset of base,sdk,toolchain,media,migraphx,llama,torch,final; migraphx and llama are rocm-only.
.PARAMETER NoRocmSpikes
    rocm only: skip the migraphx stage and build TVM without ROCm.
.EXAMPLE
    .\windows\Build-Buildkit.ps1 -Variant rocm -Stages torch,final # reuses bk-windows-media-llama-rocm
.EXAMPLE
    & .\windows\Build-Buildkit.ps1 -Gpu -Stages @('sdk','toolchain','media')
#>
[CmdletBinding()]
param(
    # The nvidia variant's original spelling; -Variant nvidia means the same.
    [switch]$Gpu,
    # Empty = the default (CPU + DirectML) image; see docs/windows-rocm.md § The ROCm layer (`Dockerfile.rocm`).
    [ValidateSet('', 'nvidia', 'rocm')]
    [string]$Variant = '',
    # rocm only: drop the migraphx stage and pass TVM_ROCM=0 to media-tvm.
    [switch]$NoRocmSpikes,
    # Inert: the patched clang (llvm#219275/#219276) is the default toolchain.
    [switch]$PatchedLlvm,
    # Stock scoop clang-cl instead of the patched one; only for debugging the patches.
    [switch]$StockLlvm,
    # arm64 is a cross build producing a bundle, not a runnable image; only media onward forks on it.
    [ValidateSet('amd64', 'arm64')]
    [string]$TargetArch = 'amd64',
    # 'rocm' stays in the set only to refuse it with the migration message (Resolve-BkVariant).
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'migraphx', 'llama', 'torch', 'final', 'rocm')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'migraphx', 'llama', 'torch', 'final'),
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
    # 'KEY=VALUE' build-args for every solve; inert unless a Dockerfile declares the ARG.
    [string[]]$BuildArg = @(),
    # For iterating on the chain only: it does not make an unverified image safe to ship.
    [switch]$SkipSmokeGate,
    # Coverage floors: raise with the measured baseline, lower only explicitly.
    [int]$SmokeMinPassed = 170,
    [int]$SmokeMaxSkipped = 3,
    # Substring of a stage label, e.g. opencv; -NoCache overrides it.
    [string[]]$NoCacheStage = @(),
    # Registry auth must already be wired: docker login credentials are not shared with buildkitd.
    [string]$ExportCacheRef = '',
    [string]$ImportCacheRef = '',
    # Opt-in: litert and tvm in concurrent child drivers after media-core, each on half the memory budget.
    [switch]$ConcurrentAux,
    # buildctl forwards the client's docker credential store, so a prior docker login suffices.
    [string]$PushRef = '',
    # Skips the disk and shim preflight gates; deliberate exceptions only.
    [switch]$SkipHostChecks,
    # Bypasses only the RDNA4 gate, leaving the disk and shim gates armed.
    [switch]$SkipRdna4Gate,
    # Bypasses the step-log-env gate once; the 2MiB clip stays, so restore it via Install-NewHost.ps1.
    [switch]$SkipStepLogGate,
    # Disables the detached per-run resource CSV sampler.
    [switch]$NoResourceLog,
    # Below ~25 GB hcsshim fails in ways that do not look like a disk problem.
    [int]$MinFreeGb = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {

Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force
# The same arch table the in-container scripts read, so the two cannot drift.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsTargetArch.Common.psm1') -Force
# Shared transient-failure engine; the BK lane passes its own pattern below.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1') -Force

<#
.SYNOPSIS
    Normalizes -Gpu/-Variant and refuses what a variant cannot build or push; returns @{ Variant; Stages }.
.DESCRIPTION
    A rocm run may not skip a post-media stage between two it builds, or the next one builds on a stale parent.
#>
function Resolve-BkVariant {
    param(
        [AllowEmptyString()][string]$Variant,
        [bool]$Gpu,
        [string]$TargetArch,
        [string[]]$Stages,
        [bool]$StagesBound,
        [bool]$NoRocmSpikes,
        [AllowEmptyString()][string]$PushRef
    )
    if ($Stages -contains 'rocm') {
        throw '-Stages rocm is gone: the ROCm layer is the sdk stage on -Variant rocm (e.g. -Variant rocm -Stages sdk,toolchain,media,migraphx,llama,torch,final)'
    }
    if ($Gpu -and $Variant -eq 'rocm') { throw '-Gpu selects the nvidia variant; it cannot be combined with -Variant rocm' }
    if ($Gpu) { $Variant = 'nvidia' }
    if ($Variant -eq 'rocm' -and $TargetArch -ne 'amd64') {
        throw "-Variant rocm is amd64-only (AMD publishes no Windows arm64 ROCm); got -TargetArch $TargetArch"
    }
    $rocmOnlyStages = @('migraphx', 'llama')
    if ($Variant -ne 'rocm') {
        if ($NoRocmSpikes) { throw "-NoRocmSpikes needs -Variant rocm (this run's variant: '$Variant')" }
        $named = @($Stages | Where-Object { $_ -in $rocmOnlyStages })
        if ($named.Count -gt 0 -and $StagesBound) { throw "-Stages $($named -join ',') needs -Variant rocm (this run's variant: '$Variant')" }
        $Stages = @($Stages | Where-Object { $_ -notin $rocmOnlyStages })
    } else {
        if ($NoRocmSpikes -and $Stages -contains 'migraphx') {
            if ($StagesBound) { throw '-Stages migraphx contradicts -NoRocmSpikes, which skips it' }
            $Stages = @($Stages | Where-Object { $_ -ne 'migraphx' })
        }
        # Each post-media stage builds FROM the previous tag, final too (rocm is amd64-only), so a gap inherits an older image.
        $chain = @(@('media', 'migraphx', 'llama', 'torch', 'final') | Where-Object { -not ($NoRocmSpikes -and $_ -eq 'migraphx') })
        $built = @(for ($i = 0; $i -lt $chain.Count; $i++) { if ($Stages -contains $chain[$i]) { $i } })
        $gap = @(if ($built.Count -gt 1) { $chain[$built[0]..$built[-1]] | Where-Object { $Stages -notcontains $_ } })
        if ($gap.Count -gt 0) {
            throw ("-Variant rocm -Stages $($Stages -join ',') skips $($gap -join ','): the next stage would build FROM " +
                   "an earlier run's $($gap[-1]) image (stale parent, backlog #39). Add $($gap -join ',') to -Stages" +
                   $(if ($gap -contains 'migraphx') { ', or pass -NoRocmSpikes to skip migraphx deliberately.' } else { '.' }))
        }
    }
    if ($PushRef) {
        $lastSegment = ($PushRef -split '/')[-1]
        $pushTag = if ($lastSegment -match ':') { ($lastSegment -split ':')[-1] } else { '' }
        # A variant's bytes never go under another lane's tag (AGENTS.md § Image and tag naming).
        $foreign = @('nvidia', 'rocm') | Where-Object { $_ -ne $Variant -and $pushTag -like "*-$_" }
        if ($foreign) { throw "-PushRef '$PushRef' names the $foreign variant's tag, but this run is not -Variant $foreign" }
        $own = (Get-WindowsTargetTagSuffix -Arch $TargetArch) + $(if ($Variant) { "-$Variant" })
        if ($Variant -and $pushTag -ne $own) { throw "-Variant $Variant pushes only to a ':$own' tag; got -PushRef '$PushRef'" }
    }
    return @{ Variant = $Variant; Stages = $Stages }
}

<#
.SYNOPSIS
    The rocm-only build-args of one stage; @{} on every other lane, so cpu/nvidia solves are unchanged.
#>
function Get-BkRocmStageArg {
    param(
        [AllowEmptyString()][string]$Variant,
        [Parameter(Mandatory)][string]$Stage,
        [bool]$NoRocmSpikes,
        # torch also takes every TORCH_ROCM_WINDOWS_* pin from it (Dockerfile.torch's rocm-1 stage).
        [hashtable]$VersionTable = @{}
    )
    if ($Variant -ne 'rocm') { return @{} }
    switch ($Stage) {
        'media-tvm' { return @{ TVM_ROCM = $(if ($NoRocmSpikes) { '0' } else { '1' }) } }
        # The onnx stage's WebGPU EP spike and its ORT_WEBGPU_WINDOWS_* pins (valueless ARGs there).
        'media-core' {
            $coreArgs = @{ ORT_WEBGPU = $(if ($NoRocmSpikes) { '0' } else { '1' }) }
            foreach ($k in @($VersionTable.Keys | Where-Object { $_ -like 'ORT_WEBGPU_WINDOWS_*' })) { $coreArgs[$k] = $VersionTable[$k] }
            return $coreArgs
        }
        # Both spike modes write the same tags, so the gate must know which one this image claims.
        'smoke-gate' { return @{ EXPECT_ROCM_SPIKES = $(if ($NoRocmSpikes) { '0' } else { '1' }) } }
        'torch' {
            $torchArgs = @{ TORCH_ROCM = '1' }
            foreach ($k in @($VersionTable.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' })) { $torchArgs[$k] = $VersionTable[$k] }
            # The torch-rocm-wheels stage's source build: its versions and GPU family (docs/windows-rocm.md).
            foreach ($k in 'PYTORCH_VERSION', 'TORCHVISION_VERSION', 'ROCM_WINDOWS_GFX_FAMILY') {
                if ($VersionTable.ContainsKey($k)) { $torchArgs[$k] = $VersionTable[$k] }
            }
            return $torchArgs
        }
        default     { return @{} }
    }
}

$variantPlan = Resolve-BkVariant -Variant $Variant -Gpu ([bool]$Gpu) -TargetArch $TargetArch -Stages $Stages `
    -StagesBound $PSBoundParameters.ContainsKey('Stages') -NoRocmSpikes ([bool]$NoRocmSpikes) -PushRef $PushRef
$Variant = $variantPlan.Variant
$Stages = $variantPlan.Stages
# Every nvidia code path below reads this, so -Gpu and -Variant nvidia are one lane.
$isNvidia = $Variant -eq 'nvidia'

$script:LogDir = Join-Path $repoRoot 'out\windows-build-logs'
New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
# Per-run id in every stage-log name, so run N never truncates run N-1's evidence.
$script:RunId = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Stage -> seconds; the run manifest below is the only record of per-stage cost.
$script:StageTimings = [ordered]@{}
# The detached resource sampler tags each CSV row with the phase written here.
$script:PhaseFile = Join-Path $script:LogDir 'current-phase.txt'
$script:ResourceCsv = $null
$script:SamplerProc = $null
function Set-BuildPhase {
    param([Parameter(Mandatory)][string]$Name)
    try { Set-Content -Path $script:PhaseFile -Value $Name -ErrorAction Stop } catch { Write-Verbose "phase write skipped: $_" }
}
function Assert-NoCacheStageMatched {
    param([string[]]$Requested = $NoCacheStage)
    $unmatchedNoCacheStage = @($Requested | Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })
    if ($unmatchedNoCacheStage.Count -gt 0) {
        throw ("[bk] -NoCacheStage matched NO stage in this run: $($unmatchedNoCacheStage -join ', '). " +
               'Every stage built from cache, so nothing was busted. Check the spelling against the ' +
               'stage labels in the output above (they are the same labels used for the log filenames).')
    }
}
# ~80 files is several full chains of forensics.
Limit-DiagnosticLogs -Directory $script:LogDir -Keep 80

# buildctl resolution
$BuildCtl = Resolve-BuildCtlPath -BuildCtl $BuildCtl
& $BuildCtl debug info *> $null
if ($LASTEXITCODE -ne 0) { throw 'buildkitd not reachable (service running? user in docker-users?)' }

# A dockerd restart moves the nat HNS subnet away from the CNI conf's, leaving containers without a gateway.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildKit.Common.psm1') -Force
$cniDrift = Get-CniNatSubnetDrift
if ($cniDrift) { throw $cniDrift }
# The drift guard stays green when the .conf was renamed to .conflist, yet containers get no adapter.
$cniForm = Get-CniConfFormIssue
if ($cniForm) { throw $cniForm }

# Retry only re-pays finalize; the reimport lookahead keeps a real ExportLayer 0x3 defect failing loudly.
Initialize-BuildDriverContext -TransientPattern 'hcsshim::(Activate|Prepare)Layer.*0x20|ttrpc: closed|failed to create shim task|failed to create task for container|error during connect|rpc error: code = Unavailable|failed to reimport snapshot(?!.*ExportLayer)|failed to write compressed diff|failed to extract layer|failed to mount \{windows-layer|failed to calculate checksum of ref'

# --- versions (single source of truth) ---
$versions = ConvertFrom-VersionsEnv -Path (Join-Path $repoRoot 'linux\scripts\01-core\versions.env')
# Thin lane-local alias over the canonical lookup.
function Get-Ver([string]$Key) {
    return Get-VersionTableValue -VersionTable $versions -Key $Key
}
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# --- resource budget + sccache gate ---
$MediaMemoryGb = Get-MediaMemoryBudget -RequestedGb $MediaMemoryGb -HostReserveGb $HostReserveGb
Write-Host "BuildKit lane: process isolation, all CPUs; memory budget $MediaMemoryGb GB (published via webdav, #51)" -ForegroundColor Cyan
Assert-SccacheEndpoint -Stages $Stages -SccacheEndpoint $SccacheEndpoint -NoSccache:$NoSccache
# The children's halved budget travels only via the webdav publish, which -NoSccache disables.
if ($ConcurrentAux -and $NoSccache) {
    throw ('-ConcurrentAux relies on the WebDAV memory publish to halve the aux children''s budget, ' +
           'which -NoSccache disables. Drop -NoSccache, or run the aux branches sequentially.')
}

# Cross-target gates: refuse impossible combinations now, not hours into a stage
if ($TargetArch -ne 'amd64') {
    if ($isNvidia) {
        Write-Host ('[bk] GPU: arm64 cross CUDA/cuDNN (bundle only; the arm64 payload is statically verified)') -ForegroundColor Yellow
    }
    # An explicit torch is an error; the default list just drops it, or plain -TargetArch arm64 would fail.
    if ($Stages -contains 'torch') {
        $torchWhy = ('the torch stage runs ``uv sync``, which must EXECUTE the target interpreter - impossible in a ' +
                     'cross build. Independently, the pinned PyTorch publishes no win_arm64 wheel for the pinned Python.')
        if ($PSBoundParameters.ContainsKey('Stages')) {
            throw "-Stages torch is not available for -TargetArch $TargetArch : $torchWhy Re-run without torch, e.g. -Stages base,sdk,toolchain,media,final"
        }
        $Stages = @($Stages | Where-Object { $_ -ne 'torch' })
        Write-Host "[bk] stage 'torch' dropped for $TargetArch : $torchWhy" -ForegroundColor Yellow
    }
    # What a branch cannot build for the target ships as an empty marker tree; see docs/windows-cross-builds.md.
    Write-Host ("[bk] TARGET ARCH: $TargetArch (CROSS build - host stays windows/amd64). " +
                'Output is an artifact bundle, not a runnable image.') -ForegroundColor Yellow
}
# The merge fan-in needs all three branches on both lanes.
$script:MergeRequiredBranches = @('media-core', 'media-litert', 'media-tvm')
# Only for stages after the arch fork: on base/sdk/toolchain the ARG would re-key the VS layer.
$archArgs = @{
    WINDOWS_TARGET_ARCH = $TargetArch
    OPENCV_ARCH_DIR     = Get-OpenCvArchDir -Arch $TargetArch
}
# Floors from measured counts minus headroom (arm64's import walk covers ~606); never lower one to turn a run green.
$archArgs['ARCH_GATE_MIN_INSPECTED'] = if ($TargetArch -eq 'amd64') { '650' } else { '580' }
if ($TargetArch -ne 'amd64') {
    # The host site-packages .pyds are the x64 build interpreter's: a reported allowlist skip, never silently out of scope.
    $archArgs['ARCH_GATE_HOST_TOOLS'] = 'protoc\.exe|flatc\.exe|\\_deps\\|\\cpython\\Lib\\site-packages\\'
}
# A drop in wheel or requirement count is a finding, not a greener gate.
$archArgs['DEPS_MIN_BUNDLE_WHEELS'] = '6'
$archArgs['DEPS_MIN_FIRST_TOUCH_REQS'] = if ($TargetArch -eq 'amd64') { '10' } else { '8' }

# Host preflight; see docs/windows-host-setup.md § Phase D.
Assert-DiskHeadroom -Drive @($repoRoot) -MinFreeGb $MinFreeGb -Force:$SkipHostChecks
Assert-ShimPatch -Force:$SkipHostChecks
# The 2MiB step-log clip hides verdicts.
Assert-BuildkitdStepLogEnv -Force:($SkipHostChecks -or $SkipStepLogGate)
Assert-NoActiveRdna4Gpu -Force:($SkipHostChecks -or $SkipRdna4Gate)

# Tags: pre-fork stages stay unsuffixed (a suffix would fork the most expensive layers), final tags spell their arch.
$script:NoSuffixTags = @('windows-base', 'windows-sdk', 'windows-toolchain', 'winamd64', 'winarm64',
    'winamd64-nvidia', 'winarm64-nvidia', 'winamd64-rocm')
# A variant owns the sdk slot, so every tag from sdk on gets '-<variant>' and never overwrites the default's.
$script:BkVariantInfix = if ($Variant) { "-$Variant" } else { '' }
function Get-BkTag([string]$Name) {
    $infix = $script:BkVariantInfix
    $variant = if ($infix -and $Name -ne 'windows-base' -and -not $Name.EndsWith($infix)) { $infix } else { '' }
    $suffix = if ($TargetArch -eq 'amd64' -or $script:NoSuffixTags -contains $Name) { '' } else { "-$TargetArch" }
    return "docker.io/local/kataglyphis:bk-$Name$variant$suffix"
}

# winarm64 is a windows/amd64 image with an aarch64 payload: never publish it as --platform windows/arm64.
$script:FinalTagName = (Get-WindowsTargetTagSuffix -Arch $TargetArch) + $script:BkVariantInfix

# Checked at the end of the run, so a -NoCacheStage typo fails loudly instead of building from cache.
$script:NoCacheStageMatched = @{}
# A BASE_IMAGE in neither set is graded first; see docs/windows-build-resources.md § An image this run did not build.
$script:BkBuiltTags = [System.Collections.Generic.HashSet[string]]::new()
$script:BkGatedImages = [System.Collections.Generic.HashSet[string]]::new()

function Invoke-BkStage {
    param(
        [Parameter(Mandatory)][string]$Dockerfile,   # repo-relative
        [string]$Tag = '',
        [hashtable]$BuildArgs = @{},
        [string]$Target = '',
        [string]$Context = '.',
        [string]$Label = '',
        # Warm solve without an exporter, so nothing finalizes.
        [switch]$NoOutput,
        # Raw --output (docker-tar, push), so those re-solves share the retry and log plumbing.
        [string]$OutputSpec = '',
        # 3 suits a stage touching one snapshot tree; the merge fan-in asks for more.
        [int]$MaxAttempts = 3,
        # Set by Invoke-BkPublishGate only: the gate's own BASE_IMAGE is what it grades.
        [switch]$NoParentGate
    )
    if (-not $NoOutput -and -not $Tag -and -not $OutputSpec) { throw 'Invoke-BkStage: need -Tag, -OutputSpec or -NoOutput' }
    if (-not $Label) { $Label = [IO.Path]::GetFileName($Dockerfile) + $(if ($Target) { ":$Target" } else { '' }) }
    # Grade an unbuilt parent's ENV now, in seconds, not at the final gate.
    $parent = "$($BuildArgs['BASE_IMAGE'])"
    if (-not $NoParentGate -and $parent -and -not $script:BkBuiltTags.Contains($parent) -and -not $script:BkGatedImages.Contains($parent)) {
        Invoke-BkPublishGate -Image $parent -Label "publish-gate:$($parent -replace '^.*:', '')" -Hint (
            "$parent was not built by this run and failed the publish gate: a build-host setting in its ENV " +
            "(built before 2026-09-23?) or no such image. Rebuild it: put the stage that produces it in -Stages, " +
            'from a fresh driver process.')
    }

    # Per stage too: one heavy stage can walk the disk into hcsshim's dishonest-failure band.
    Assert-StageDiskHeadroom -Label $Label -Drive (Split-Path -Qualifier $repoRoot).TrimEnd(':') -Force:$SkipHostChecks
    $dfDir = Split-Path (Join-Path $repoRoot $Dockerfile) -Parent
    $dfName = [IO.Path]::GetFileName($Dockerfile)
    $bkArgs = @(
        'build',
        '--frontend', 'dockerfile.v0',
        '--local', "context=$Context",
        '--local', "dockerfile=$dfDir",
        '--opt', "filename=$dfName",
        # Stage handoff: resolve FROM refs locally, else buildkit goes to docker.io.
        '--opt', 'image-resolve-mode=local',
        '--progress', 'plain'
    )
    if ($OutputSpec) { $bkArgs += @('--output', $OutputSpec) }
    elseif (-not $NoOutput) { $bkArgs += @('--output', "type=image,name=$Tag,unpack=true") }
    # final-tar/final-push re-export the smoked final solve, so they stay cache hits.
    $exportOnlyLabel = $Label -in @('final-tar', 'final-push')
    $matched = @()
    if (-not $exportOnlyLabel) { $matched = @($NoCacheStage | Where-Object { $Label -like "*$_*" }) }
    # Recorded so a misspelled entry fails at the end of the run instead of silently caching everything.
    foreach ($m in $matched) { $script:NoCacheStageMatched[$m] = $true }
    $stageNoCache = $matched.Count -gt 0
    if (($NoCache -or $stageNoCache) -and -not $exportOnlyLabel) { $bkArgs += @('--no-cache') }
    if ($stageNoCache -and -not $NoCache) { Write-Host "[bk:$Label] -NoCacheStage match -> --no-cache for THIS stage only" -ForegroundColor Yellow }
    if ($Target) { $bkArgs += @('--opt', "target=$Target") }
    # mode=max also caches non-exported intermediate stages.
    if ($ImportCacheRef) { $bkArgs += @('--import-cache', "type=registry,ref=$ImportCacheRef") }
    if ($ExportCacheRef) { $bkArgs += @('--export-cache', "type=registry,ref=$ExportCacheRef,mode=max") }
    foreach ($k in ($BuildArgs.Keys | Sort-Object)) {
        $v = $BuildArgs[$k]
        if ($null -ne $v -and "$v" -ne '') { $bkArgs += @('--opt', "build-arg:$k=$v") }
    }
    # A missing arch arg is invisible: the stage falls back to amd64 and fails much later as something else.
    if ($BuildArgs.ContainsKey('WINDOWS_TARGET_ARCH')) {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH=$($BuildArgs['WINDOWS_TARGET_ARCH'])" -ForegroundColor DarkGray
    } elseif ($TargetArch -ne 'amd64') {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH NOT PASSED to this stage (target is $TargetArch) - it will default to amd64" -ForegroundColor Yellow
    }
    # Applied last, so an explicit one-off overrides the stage's computed value.
    foreach ($extra in $BuildArg) {
        # buildctl silently discards undeclared ARG names, so a key mangled by pwsh -File would vanish.
        if ($extra -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            throw ("-BuildArg '$extra' is not in KEY=VALUE form with a clean identifier key. " +
                'If several args arrived as ONE quoted string, the caller crossed a process boundary ' +
                '(`pwsh -File` flattens comma arrays, quotes included) - invoke Build-Buildkit.ps1 ' +
                'directly or pass one -BuildArg element per KEY=VALUE.')
        }
        $bkArgs += @('--opt', "build-arg:$extra")
    }
    $stageLog = Join-Path $script:LogDir ("bk-" + $script:RunId + "-" + ($Label -replace '[:\\/]', '-') + ".log")
    Set-BuildPhase $Label
    $stageClock = [System.Diagnostics.Stopwatch]::StartNew()
    $dest = if ($NoOutput) { '(warm solve, no output)' } else { $Tag }
    # Appended per attempt: truncating would destroy attempt 1's real compile error.
    Remove-Item -Path $stageLog -Force -ErrorAction SilentlyContinue
    $previousTail = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "`n==> [bk:$Label] buildctl -> $dest$(if ($attempt -gt 1) { ' (retry)' })" -ForegroundColor Cyan
        "`n===== [bk:$Label] attempt $attempt/$MaxAttempts =====" | Add-Content -Path $stageLog -Encoding utf8
        & $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $stageLog -Append
        if ($LASTEXITCODE -eq 0) { break }
        $tail = if (Test-Path $stageLog) { (Get-Content $stageLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        # An identical failure is a poisoned snapshot, not a flake, so it is not retried.
        if (Invoke-TransientCooldown -Tail $tail -PreviousTail $previousTail -Attempt $attempt -MaxAttempts $MaxAttempts -Label "bk:$Label" -CooldownSeconds 15) {
            $previousTail = $tail
            continue
        }
        # Surface the cause, not just a log path.
        if ($tail) {
            Write-Host "`n--- [bk:$Label] tail of the failing attempt ---" -ForegroundColor Yellow
            Write-Host $tail
            Write-Host "--- end of tail (full log: $stageLog) ---`n" -ForegroundColor Yellow
        }
        throw "[bk:$Label] buildctl failed (exit $LASTEXITCODE) — full log: $stageLog"
    }
    $stageClock.Stop()
    $script:StageTimings[$Label] = [math]::Round($stageClock.Elapsed.TotalSeconds, 1)
    if ($Tag) { $null = $script:BkBuiltTags.Add($Tag) }
    Write-Host ("[bk:{0}] OK -> {1}  ({2:hh\:mm\:ss})" -f $Label, $dest, $stageClock.Elapsed) -ForegroundColor Green
}

# Fails when $Image's ENV carries a build-host setting; see docs/windows-build-resources.md § What the published image carries.
function Invoke-BkPublishGate {
    param([Parameter(Mandatory)][string]$Image, [string]$Label = 'publish-gate', [string]$Hint = '')
    try {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.publish-gate' -Label $Label -NoOutput -NoParentGate -BuildArgs @{
            BASE_IMAGE = $Image
        } -MaxAttempts 1
    } catch {
        if ($Hint) { throw "$($_.Exception.Message)`n[bk:$Label] $Hint" }
        throw
    }
    $null = $script:BkGatedImages.Add($Image)
    Write-Host "[bk:$Label] $Image carries no build-host setting" -ForegroundColor Green
}

$sccache = @{ SCCACHE_WEBDAV_ENDPOINT = $SccacheEndpoint }

# Preseed the Vulkan SDK on the webdav: sdk.lunarg.com stalls inside containers; fail-open to their direct download.
if ($SccacheEndpoint) {
    $vkVer = Get-Ver 'VULKAN_VERSION'
    $vkName = "vulkansdk-windows-X64-$vkVer.exe"
    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    $vkUrl = "https://sdk.lunarg.com/sdk/download/$vkVer/windows/$vkName"

    # Only a 404 is fatal (no Windows SDK for that version); a one-byte range because -I buries the status.
    $vkProbe = (& $curlExe -sS -o NUL -w '%{http_code}' -L --max-time 30 -r 0-0 $vkUrl 2>$null)
    $global:LASTEXITCODE = 0
    if ("$vkProbe".Trim() -eq '404') {
        throw ("VULKAN_VERSION=$vkVer has no Windows installer: $vkUrl returns 404. LunarG versions the " +
               'SDK per platform and Windows can lag behind linux/mac -- check ' +
               'https://vulkan.lunarg.com/sdk/latest.json and pin the version its "windows" field names ' +
               '(VULKAN_VERSION feeds BOTH lanes, so it can only carry a version that exists on both). ' +
               'Failing here rather than 14 minutes into Dockerfile.base, where the same 404 surfaces as ' +
               'a scoop install error.')
    }

    $preseedDir = Join-Path $PSScriptRoot 'downloads'
    try {
        Publish-PreseedFile -Endpoint $SccacheEndpoint -Name $vkName -LocalDir $preseedDir -Fetch {
            param($to)
            if (Test-Path $to) { return }
            & $curlExe -sfL --retry 3 --retry-delay 5 --retry-all-errors $vkUrl -o $to
            if ($LASTEXITCODE -ne 0) { throw "host download failed (exit $LASTEXITCODE)" }
        }
    } catch {
        Write-Warning "vulkan preseed skipped (container falls back to direct download): $($_.Exception.Message)"
    }
    $global:LASTEXITCODE = 0

    # Both OpenSSL installers too: slproweb throttles each connection, and one 251 MB stream ran 3.6 h and failed (2026-09-30).
    try {
        $sslManifest = Invoke-RestMethod -TimeoutSec 60 -Uri 'https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/openssl.json'
        foreach ($sslArch in '64bit', 'arm64') {
            $sslAsset = $sslManifest.architecture.$sslArch
            Publish-PreseedFile -Endpoint $SccacheEndpoint -Name (Split-Path -Leaf $sslAsset.url) -LocalDir $preseedDir -Fetch {
                param($to)
                Save-ParallelRangeDownload -Url $sslAsset.url -Destination $to -ExpectedSha256 $sslAsset.hash
            }
        }
    } catch {
        Write-Warning "openssl preseed skipped (the container falls back to slproweb): $($_.Exception.Message)"
    }
    $global:LASTEXITCODE = 0

    # A scheduling knob published on the webdav, never an ARG/ENV, which would make it a cache key.
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

# Started after every preflight gate, so a rejected launch cannot orphan the detached sampler.
if (-not $NoResourceLog) {
    $script:ResourceCsv = Join-Path $script:LogDir ("resources-" + $script:RunId + ".csv")
    Set-BuildPhase 'init'
    $samplerScript = Join-Path $repoRoot 'windows\scripts\build\Build-ResourceSampler.ps1'
    $script:SamplerProc = Start-Process -FilePath ((Get-Process -Id $PID).Path) -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', $samplerScript,
        '-CsvPath', $script:ResourceCsv, '-PhaseFile', $script:PhaseFile, '-IntervalSeconds', '20')
    Write-Host "Resource log: $script:ResourceCsv (20s samples, phase-tagged; disable with -NoResourceLog)"
}

if ($Stages -contains 'base') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.base' -Tag (Get-BkTag 'windows-base') -BuildArgs @{
        WINDOWS_LTSC          = Get-Ver 'WINDOWS_LTSC'
        WINDOWS_BASE_DIGEST   = Get-Ver 'WINDOWS_BASE_DIGEST'
        VULKAN_VERSION        = Get-Ver 'VULKAN_VERSION'
        # LAN source for the 275 MB SDK exe (see the preseed block above).
        VULKAN_PRESEED_ENDPOINT = $SccacheEndpoint
        CMAKE_VERSION         = Get-Ver 'CMAKE_VERSION'
        # Compiled-output pins.
        LLVM_WINDOWS_VERSION  = Get-Ver 'LLVM_WINDOWS_VERSION'
        NINJA_WINDOWS_VERSION = Get-Ver 'NINJA_WINDOWS_VERSION'
        NASM_WINDOWS_VERSION  = Get-Ver 'NASM_WINDOWS_VERSION'
        PWSH_VERSION          = Get-Ver 'PWSH_VERSION'
        PWSH_ZIP_SHA256       = Get-Ver 'PWSH_ZIP_SHA256'
        WINDOWS_SDK_BUILD     = Get-Ver 'WINDOWS_SDK_BUILD'
        VISUAL_STUDIO_VERSION = Get-Ver 'VISUAL_STUDIO_VERSION'
        # Keep in sync with Dockerfile.base's ARG block.
        GIT_VERSION                  = Get-Ver 'GIT_VERSION'
        GIT_WINDOWS_INSTALLER_SHA256 = Get-Ver 'GIT_WINDOWS_INSTALLER_SHA256'
        SCOOP_INSTALLER_SHA256       = Get-Ver 'SCOOP_INSTALLER_SHA256'
        WIX_VERSION                  = Get-Ver 'WIX_VERSION'
        WIX_UI_EXT_VERSION           = Get-Ver 'WIX_UI_EXT_VERSION'
        FLUTTER_VERSION              = Get-Ver 'FLUTTER_VERSION'
        VCPKG_REF                    = Get-Ver 'VCPKG_REF'
        SCCACHE_WINDOWS_VERSION      = Get-Ver 'SCCACHE_WINDOWS_VERSION'
        SCCACHE_WINDOWS_ZIP_SHA256   = Get-Ver 'SCCACHE_WINDOWS_ZIP_SHA256'
    }
}

if ($Stages -contains 'sdk') {
    if ($isNvidia) {
        # The arch picks Install-Cuda.ps1's arm64 redist payload on the cross lane; the arm64 SHAs are inert on amd64.
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.nvidia' -Context 'windows' -Tag (Get-BkTag 'windows-sdk') -BuildArgs @{
            BASE_IMAGE               = Get-BkTag 'windows-base'
            CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
            CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
            CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
            TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
            CUDA_INSTALLER_SHA256    = Get-Ver 'CUDA_INSTALLER_SHA256'
            CUDNN_ZIP_SHA256         = Get-Ver 'CUDNN_ZIP_SHA256'
            TENSORRT_ZIP_SHA256      = Get-Ver 'TENSORRT_ZIP_SHA256'
            WINDOWS_TARGET_ARCH      = $TargetArch
            CUDA_WINDOWS_ARM64_CUDART_VERSION    = Get-Ver 'CUDA_WINDOWS_ARM64_CUDART_VERSION'
            CUDA_WINDOWS_ARM64_CUDART_SHA256     = Get-Ver 'CUDA_WINDOWS_ARM64_CUDART_SHA256'
            CUDA_WINDOWS_ARM64_CUBLAS_VERSION    = Get-Ver 'CUDA_WINDOWS_ARM64_CUBLAS_VERSION'
            CUDA_WINDOWS_ARM64_CUBLAS_SHA256     = Get-Ver 'CUDA_WINDOWS_ARM64_CUBLAS_SHA256'
            CUDA_WINDOWS_ARM64_CUFFT_VERSION     = Get-Ver 'CUDA_WINDOWS_ARM64_CUFFT_VERSION'
            CUDA_WINDOWS_ARM64_CUFFT_SHA256      = Get-Ver 'CUDA_WINDOWS_ARM64_CUFFT_SHA256'
            CUDA_WINDOWS_ARM64_CURAND_VERSION    = Get-Ver 'CUDA_WINDOWS_ARM64_CURAND_VERSION'
            CUDA_WINDOWS_ARM64_CURAND_SHA256     = Get-Ver 'CUDA_WINDOWS_ARM64_CURAND_SHA256'
            CUDA_WINDOWS_ARM64_NVJITLINK_VERSION = Get-Ver 'CUDA_WINDOWS_ARM64_NVJITLINK_VERSION'
            CUDA_WINDOWS_ARM64_NVJITLINK_SHA256  = Get-Ver 'CUDA_WINDOWS_ARM64_NVJITLINK_SHA256'
            CUDA_WINDOWS_ARM64_NPP_VERSION       = Get-Ver 'CUDA_WINDOWS_ARM64_NPP_VERSION'
            CUDA_WINDOWS_ARM64_NPP_SHA256        = Get-Ver 'CUDA_WINDOWS_ARM64_NPP_SHA256'
            CUDA_WINDOWS_ARM64_CUSOLVER_VERSION  = Get-Ver 'CUDA_WINDOWS_ARM64_CUSOLVER_VERSION'
            CUDA_WINDOWS_ARM64_CUSOLVER_SHA256   = Get-Ver 'CUDA_WINDOWS_ARM64_CUSOLVER_SHA256'
            CUDA_WINDOWS_ARM64_CUSPARSE_VERSION  = Get-Ver 'CUDA_WINDOWS_ARM64_CUSPARSE_VERSION'
            CUDA_WINDOWS_ARM64_CUSPARSE_SHA256   = Get-Ver 'CUDA_WINDOWS_ARM64_CUSPARSE_SHA256'
            CUDNN_WINDOWS_ARM64_ZIP_SHA256       = Get-Ver 'CUDNN_WINDOWS_ARM64_ZIP_SHA256'
        }
    } elseif ($Variant -eq 'rocm') {
        # The AMD layer in the sdk slot, like nvidia: toolchain and media inherit GPU_TYPE=rocm.
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm' -Tag (Get-BkTag 'windows-sdk') -BuildArgs @{
            BASE_IMAGE                  = Get-BkTag 'windows-base'
            ROCM_WINDOWS_RELEASE        = Get-Ver 'ROCM_WINDOWS_RELEASE'
            ROCM_WINDOWS_GFX_FAMILY     = Get-Ver 'ROCM_WINDOWS_GFX_FAMILY'
            ROCM_WINDOWS_TARBALL_SHA256 = Get-Ver 'ROCM_WINDOWS_TARBALL_SHA256'
            VULKAN_VERSION              = Get-Ver 'VULKAN_VERSION'
            VULKAN_RT_WINDOWS_ZIP_SHA256 = Get-Ver 'VULKAN_RT_WINDOWS_ZIP_SHA256'
        }
    } else {
        # containerd has no unprivileged tag, so a trivial FROM re-exports base under the sdk name.
        $alias = Join-Path $script:LogDir 'Dockerfile.bk-sdk-alias'
        "FROM $(Get-BkTag 'windows-base')`r`n" | Set-Content $alias -Encoding ASCII
        Invoke-BkStage -Dockerfile ('out/windows-build-logs/' + [IO.Path]::GetFileName($alias)) -Tag (Get-BkTag 'windows-sdk') -Label 'bk-cpu-alias'
    }
}

if ($Stages -contains 'toolchain') {
    # Without the endpoint the patched-llvm stage compiles LLVM cold.
    $toolchainArgs = @{
        BASE_IMAGE     = Get-BkTag 'windows-sdk'
        PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
    } + $sccache
    $toolchainTarget = if ($StockLlvm) { 'built' } else { 'patched-llvm' }
    if ($toolchainTarget -eq 'patched-llvm') {
        $toolchainArgs['BUILD_PATCHED_LLVM'] = '1'
    }
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Target $toolchainTarget -Tag (Get-BkTag 'windows-toolchain') -BuildArgs $toolchainArgs
    # Every later stage inherits this ENV (and the Machine/User scopes): grade it now, not hours on.
    Invoke-BkPublishGate -Image (Get-BkTag 'windows-toolchain') -Label 'publish-gate:toolchain'
}

if ($Stages -contains 'media') {
    # Canonical per-branch version args (WindowsBuildDriver.Common).
    $branchArgs = @{}
    foreach ($b in 'media-core', 'media-litert', 'media-tvm') {
        $branchArgs[$b] = Get-MediaBranchVersionArg -Branch $b -VersionTable $versions
    }
    $loopBranches = $MediaBranches
    $auxProcs = @()
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        # media-core, the long pole, stays sequential; each child builds one aux branch.
        $loopBranches = @($MediaBranches | Where-Object { $_ -notin @('media-litert', 'media-tvm') })
        # Sole owner of the halved aux budget, published below.
        $auxMem = [Math]::Max(8, [int]($MediaMemoryGb / 2))
    }
    foreach ($branch in $loopBranches) {
        $branchBuildArgs = @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
        } + $branchArgs[$branch] + $sccache + $archArgs + (Get-BkRocmStageArg -Variant $Variant -Stage $branch -NoRocmSpikes ([bool]$NoRocmSpikes) -VersionTable $versions)
        if ($branch -eq 'media-core') {
            # Direct solves rely on the patched runhcs shim (see docs/windows-build-lanes.md § Traps); one solve per library for caching.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-onnx' -Tag (Get-BkTag 'windows-media-core-onnx') -BuildArgs $branchBuildArgs
            $onnxArg   = @{ MEDIA_CORE_ONNX_IMAGE = Get-BkTag 'windows-media-core-onnx' }
            $opencvArg = @{ MEDIA_CORE_OPENCV_IMAGE = Get-BkTag 'windows-media-core-opencv' }
            $ffmpegArg = @{ MEDIA_CORE_FFMPEG_IMAGE = Get-BkTag 'windows-media-core-ffmpeg' }
            $hailoArg  = @{ MEDIA_CORE_HAILO_IMAGE = Get-BkTag 'windows-media-core-hailo' }
            # onnx, ffmpeg, opencv, hailo, genai: OpenCV must configure after FFmpeg exists, as in Dockerfile.media-builder.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-ffmpeg' -Tag (Get-BkTag 'windows-media-core-ffmpeg') -BuildArgs ($branchBuildArgs + $onnxArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-opencv' -Tag (Get-BkTag 'windows-media-core-opencv') -BuildArgs ($branchBuildArgs + $ffmpegArg)
            # HailoRT sits between opencv and the GenAI stage.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-hailo' -Tag (Get-BkTag 'windows-media-core-hailo') -BuildArgs ($branchBuildArgs + $opencvArg + @{
                HAILORT_VERSION        = Get-Ver 'HAILORT_VERSION'
                HAILORT_SOURCE_SHA256  = Get-Ver 'HAILORT_SOURCE_SHA256'
                HAILO_PROTOBUF_VERSION = Get-Ver 'HAILO_PROTOBUF_VERSION'
                HAILO_PROTOBUF_SHA256  = Get-Ver 'HAILO_PROTOBUF_SHA256'
            })
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built' -Tag (Get-BkTag 'windows-media-core') -BuildArgs ($branchBuildArgs + $hailoArg)
        } else {
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target "$branch-built" -Tag (Get-BkTag "windows-$branch") -BuildArgs $branchBuildArgs
        }
    }
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        Write-Host "`n==> [bk:aux] concurrent litert + tvm child drivers ($auxMem GB memory budget each)" -ForegroundColor Cyan
        # Parallel phase begins: halve the published budget for the children.
        if (Get-Command Publish-MemoryBudget -ErrorAction SilentlyContinue) {
            Publish-MemoryBudget -Gb $auxMem -Phase 'parallel aux phase'
        }
        foreach ($aux in 'media-litert', 'media-tvm') {
            $auxArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Stages', 'media', '-MediaBranches', $aux, '-MediaMemoryGb', $auxMem)
            # Without it an arm64 parent's children build under amd64 tags and the merge fans in stale trees.
            if ($TargetArch -ne 'amd64') { $auxArgs += @('-TargetArch', $TargetArch) }
            if ($isNvidia) { $auxArgs += '-Gpu' }
            # Without the variant the children build FROM the default toolchain under default tags.
            if ($Variant -eq 'rocm') { $auxArgs += @('-Variant', 'rocm') + @(if ($NoRocmSpikes) { '-NoRocmSpikes' }) }
            if ($SccacheEndpoint) { $auxArgs += @('-SccacheEndpoint', $SccacheEndpoint) }
            # Without these a -NoCache parent's aux branches would build from cache.
            if ($NoCache) { $auxArgs += '-NoCache' }
            # Only entries this child can match, one per argument (-File cannot pass arrays).
            $auxNoCache = @($NoCacheStage | Where-Object { $aux -match [regex]::Escape(($_ -replace '^media-', '')) -or $_ -match ($aux -replace '^media-', '') })
            foreach ($ncs in $auxNoCache) {
                $auxArgs += @('-NoCacheStage', $ncs)
                # Marked here too, or a correct parent run ends red in the matched-nothing gate.
                $script:NoCacheStageMatched[$ncs] = $true
            }
            if ($ImportCacheRef) { $auxArgs += @('-ImportCacheRef', $ImportCacheRef) }
            if ($ExportCacheRef) { $auxArgs += @('-ExportCacheRef', $ExportCacheRef) }
            if ($BuildCtl) { $auxArgs += @('-BuildCtl', $BuildCtl) }
            # Each child re-runs the full preflight, so the parent's overrides must reach it.
            if ($SkipHostChecks) { $auxArgs += '-SkipHostChecks' }
            if ($SkipRdna4Gate) { $auxArgs += '-SkipRdna4Gate' }
            if ($SkipStepLogGate) { $auxArgs += '-SkipStepLogGate' }
            if ($NoSccache) { $auxArgs += '-NoSccache' }
            # The parent's sampler already covers the whole machine.
            $auxArgs += '-NoResourceLog'
            if ($PSBoundParameters.ContainsKey('MinFreeGb')) { $auxArgs += @('-MinFreeGb', $MinFreeGb) }
            if ($PSBoundParameters.ContainsKey('HostReserveGb')) { $auxArgs += @('-HostReserveGb', $HostReserveGb) }
            # The litert/tvm solves are the children's, so a parent-only knob would miss them.
            foreach ($ba in $BuildArg) { $auxArgs += @('-BuildArg', $ba) }
            # Start-Process -ArgumentList joins with spaces and never quotes, so spaced paths would split.
            $auxArgsQuoted = @($auxArgs | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } })
            $auxProcs += Start-Process -FilePath 'pwsh' -ArgumentList $auxArgsQuoted -PassThru -NoNewWindow
        }
        # Fail fast on the first dead child, and never orphan the other's buildctl tree.
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
        Write-Host '[bk:aux] litert + tvm OK' -ForegroundColor Green
        # Parallel phase over: the merge runs alone, so restore the full budget.
        if (Get-Command Publish-MemoryBudget -ErrorAction SilentlyContinue) {
            Publish-MemoryBudget -Gb ([int]$MediaMemoryGb) -Phase 'merge phase'
        }
    }
    # The merge needs all three branches and runs once, which keeps the single-branch children out of it.
    $allBranches = $script:MergeRequiredBranches
    $runMerge = @($allBranches | Where-Object { $_ -notin $MediaBranches }).Count -eq 0
    if ($runMerge) {
        # Every branch ships a tree, possibly an empty marker one, so the unconditional COPY --from lines hold.
        $litertImage = Get-BkTag 'windows-media-litert'
        $tvmImage    = Get-BkTag 'windows-media-tvm'
        # Canonical merge version env + BK tag wiring.
        $mergeArgs = (Get-MediaMergeVersionArg -VersionTable $versions) + @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
            CORE_IMAGE      = Get-BkTag 'windows-media-core'
            LITERT_IMAGE    = $litertImage
            TVM_IMAGE       = $tvmImage
        } + $archArgs
        # Mounting three branch trees is the only stage measured burning all 3 attempts.
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -Target 'built' -Tag (Get-BkTag 'windows-media') -BuildArgs ($mergeArgs + $sccache) -MaxAttempts 5
    } else {
        # Fail closed: later stages would silently build on the previous run's media image.
        $downstream = @('migraphx', 'llama', 'torch', 'final') | Where-Object { $Stages -contains $_ }
        if ($downstream) {
            throw ("[bk:merge] REFUSING to build $($downstream -join '+') from a STALE '$(Get-BkTag 'windows-media')': " +
                   "the merge was skipped because -MediaBranches is a subset (got: $($MediaBranches -join ', '); " +
                   "needs all of: $($allBranches -join ', ')). Those stages would silently ship the PREVIOUS run's media image. " +
                   "Either run all three branches, or drop $($downstream -join '/') from -Stages and re-run them after a full media pass.")
        }
        Write-Host "[bk:merge] skipped (needs all three media branches; got: $($MediaBranches -join ', '))" -ForegroundColor Yellow
    }
}

# rocm-only handoff tags, each named once and read by the stage that builds FROM it.
$migraphxTag = Get-BkTag 'windows-media-migraphx'
$llamaTag = Get-BkTag 'windows-media-llama'
if ($Stages -contains 'migraphx') {
    # Its pins (MIGRAPHX_*, ORT_AMDGPU_EP_*, the gfx family) come from the shared version map.
    $migraphxArgs = @{
        BASE_IMAGE = Get-BkTag 'windows-media'
    } + (Get-MediaBranchVersionArg -Branch 'rocm-migraphx' -VersionTable $versions) + $sccache
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm-migraphx' -Target 'built' -Tag $migraphxTag -BuildArgs $migraphxArgs
}
if ($Stages -contains 'llama') {
    # -NoRocmSpikes skips migraphx, so llama then builds straight on the merged media.
    $llamaArgs = @{
        BASE_IMAGE           = $(if ($NoRocmSpikes) { Get-BkTag 'windows-media' } else { $migraphxTag })
        LLAMA_CPP_HIP_BUILD  = Get-Ver 'LLAMA_CPP_HIP_BUILD'
        LLAMA_CPP_HIP_ASSET  = Get-Ver 'LLAMA_CPP_HIP_ASSET'
        LLAMA_CPP_HIP_SHA256 = Get-Ver 'LLAMA_CPP_HIP_SHA256'
        LLAMA_CPP_HIP_LICENSE_SHA256 = Get-Ver 'LLAMA_CPP_HIP_LICENSE_SHA256'
        LLAMA_CPP_VULKAN_SHA256 = Get-Ver 'LLAMA_CPP_VULKAN_SHA256'
    }
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm-llama' -Target 'built' -Tag $llamaTag -BuildArgs $llamaArgs
}
# Get-BkTag carries the lane: bk-windows-torch, or bk-windows-torch-rocm on the rocm lane.
$torchTag = Get-BkTag 'windows-torch'

# Computed once, so the FinalTar/PushRef re-solves stay cache hits of the final solve.
$stampArgs = @{
    BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    VCS_REF    = Get-BuildVcsRef
}

if ($Stages -contains 'torch') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.torch' -Tag $torchTag -BuildArgs ($stampArgs + @{
        BASE_IMAGE = $(if ($Variant -eq 'rocm') { $llamaTag } else { Get-BkTag 'windows-media' })
        APP_REF    = Resolve-TorchAppRef -VersionTable $versions -LatestApp:$LatestApp
        # Without it a -Gpu chain ships CPU torch; rocm keeps the cpu extra and TORCH_ROCM swaps torch later.
        PYTORCH_EXTRA = $(if ($isNvidia) { 'pytorch-cu130' } else { 'pytorch-cpu' })
    } + (Get-BkRocmStageArg -Variant $Variant -Stage 'torch' -VersionTable $versions) +
        # rocm compiles torch from source in this Dockerfile (torch-rocm-wheels); cpu/nvidia solve args stay as they were.
        $(if ($Variant -eq 'rocm') { $sccache } else { @{} }))
}

if ($Stages -contains 'final') {
    # arm64 has no torch stage, so its final image builds on the merged media.
    $finalBase = if ($TargetArch -eq 'amd64') { $torchTag } else { Get-BkTag 'windows-media' }
    # The Vulkan loader's pins: the final stage installs it on PATH (BACKLOG CON25).
    $finalArgs = $stampArgs + @{
        BASE_IMAGE                   = $finalBase
        VULKAN_VERSION               = Get-Ver 'VULKAN_VERSION'
        VULKAN_RT_WINDOWS_ZIP_SHA256 = Get-Ver 'VULKAN_RT_WINDOWS_ZIP_SHA256'
    } + $archArgs
    # The default label 'Dockerfile' would let -NoCacheStage final match only the re-exports.
    Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final' -Tag (Get-BkTag $script:FinalTagName) -BuildArgs $finalArgs
    # Smoke gate: a buildctl solve, since containerd's pipe is admin-only and this driver is not.
    if ($TargetArch -ne 'amd64' -and -not $SkipSmokeGate) {
        # Just under the arm64 section-floor sum (Smoke.FloorCalibration.Tests.ps1 pins the bounds).
        $armMinPassed = 76
        $armMaxSkipped = 20
        if ($PSBoundParameters.ContainsKey('SmokeMinPassed')) { $armMinPassed = $SmokeMinPassed }
        if ($PSBoundParameters.ContainsKey('SmokeMaxSkipped')) { $armMaxSkipped = $SmokeMaxSkipped }
        Write-Host ("[bk:smoke-gate] cross lane: HOST-toolchain sections run (floors: MIN_PASSED=$armMinPassed, " +
                    "MAX_SKIPPED=$armMaxSkipped); payload sections are skipped in-suite — the aarch64 payload " +
                    'itself remains statically verified only (Test-TargetArch.ps1, merge stage).') -ForegroundColor Yellow
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs @{
            BASE_IMAGE  = Get-BkTag $script:FinalTagName
            MIN_PASSED  = "$armMinPassed"
            MAX_SKIPPED = "$armMaxSkipped"
            # Makes a lost CUDA env red instead of a silent skip.
            EXPECT_GPU  = $(if ($isNvidia) { '1' } else { '0' })
        } -MaxAttempts 1
    } elseif ($TargetArch -ne 'amd64') {
        Write-Host '[bk:smoke-gate] skipped (-SkipSmokeGate). NB the arm64 payload is statically verified only.' -ForegroundColor Yellow
    } elseif (-not $SkipSmokeGate) {
        # The CPU floor would let the GPU lane lose 60 assertions; 190 is the GPU column's sum, and an explicit value wins.
        $effectiveMinPassed = $SmokeMinPassed
        if ($isNvidia -and -not $PSBoundParameters.ContainsKey('SmokeMinPassed')) {
            $effectiveMinPassed = 190
            Write-Host "smoke gate: GPU lane floor $effectiveMinPassed (CPU default is $SmokeMinPassed)"
        }
        # EXPECT_ROCM_SPIKES on rocm only; @{} elsewhere, so the cpu/nvidia gate args are unchanged.
        $smokeArgs = Get-BkRocmStageArg -Variant $Variant -Stage 'smoke-gate' -NoRocmSpikes ([bool]$NoRocmSpikes)
        $smokeArgs += @{
            BASE_IMAGE  = Get-BkTag $script:FinalTagName
            MIN_PASSED  = "$effectiveMinPassed"
            MAX_SKIPPED = "$SmokeMaxSkipped"
            EXPECT_GPU  = $(if ($isNvidia) { '1' } else { '0' })
            # rocm keeps the CPU floor; Test-RocmImage.ps1 adds the ROCm checks on top.
            EXPECT_ROCM = $(if ($Variant -eq 'rocm') { '1' } else { '0' })
        }
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs $smokeArgs -MaxAttempts 1
        Write-Host '[bk:smoke-gate] image verified' -ForegroundColor Green
    } else {
        Write-Host '[bk:smoke-gate] SKIPPED (-SkipSmokeGate) — this image is UNVERIFIED' -ForegroundColor Yellow
    }
    # The publish gate is never skipped, not even by -SkipSmokeGate.
    Invoke-BkPublishGate -Image (Get-BkTag $script:FinalTagName)
    # Before export, so a -NoCacheStage typo cannot ship a fully cached image as green.
    & Assert-NoCacheStageMatched
    # The same final solve from cache with another exporter; push auth is this shell's docker login.
    if ($FinalTar) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-tar' -OutputSpec "type=docker,name=local/kataglyphis:$($script:FinalTagName),dest=$FinalTar" -BuildArgs $finalArgs
    }
    if ($PushRef) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-push' -OutputSpec "type=image,name=$PushRef,push=true" -BuildArgs $finalArgs
        Write-Host "[bk] pushed $PushRef" -ForegroundColor Green
    }
}

# Covers runs without 'final', where the pre-export check never executes.
if ($Stages -notcontains 'final') {
    & Assert-NoCacheStageMatched
}

$elapsed = (Get-Date) - $started
# The run manifest is the only record of a green run's per-stage cost.
if ($script:StageTimings.Count -gt 0) {
    $manifest = Join-Path $script:LogDir ("bk-" + $script:RunId + "-manifest.txt")
    $lines = @("run=$($script:RunId) arch=$TargetArch variant=$(if ($Variant) { $Variant } else { 'default' }) stages=$($Stages -join ',') gpu=$($isNvidia) total_s=$([math]::Round($elapsed.TotalSeconds,1))")
    foreach ($k in $script:StageTimings.Keys) { $lines += ("{0}={1}" -f $k, $script:StageTimings[$k]) }
    Set-Content -Path $manifest -Value $lines -Encoding utf8
    Write-Host "`n[bk] per-stage timings:" -ForegroundColor Cyan
    foreach ($k in $script:StageTimings.Keys) { Write-Host ("  {0,8:N1}s  {1}" -f $script:StageTimings[$k], $k) }
    Write-Host "[bk] manifest: $manifest"
}
Write-Host ("`n[bk] Done in {0:hh\:mm\:ss}. Stages: {1}{2}" -f $elapsed, ($Stages -join ', '), $(if ($Variant) { " ($Variant)" } else { ' (CPU)' })) -ForegroundColor Green

} finally {
    # Sampler summary on failure too; guarded so it never replaces the real exception or skips Pop-Location.
    try {
        Set-BuildPhase 'done'
        if ($script:SamplerProc -and -not $script:SamplerProc.HasExited) {
            Stop-Process -Id $script:SamplerProc.Id -Force -ErrorAction SilentlyContinue
        }
        if ($script:ResourceCsv -and (Test-Path $script:ResourceCsv)) {
            & (Join-Path $repoRoot 'windows\scripts\build\Build-ResourceSampler.ps1') -Summarize -CsvPath $script:ResourceCsv
        }
    } catch {
        Write-Warning "resource-sampler teardown failed (build verdict above is unaffected): $($_.Exception.Message)"
    }
    Pop-Location
}
