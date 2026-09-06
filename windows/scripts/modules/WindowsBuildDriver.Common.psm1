#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Build-driver core for windows/build-buildkit.ps1: transient-failure classification,
# version/build-arg shaping, host gates. In a module so the failure paths are UNIT-TESTABLE
# (BuildDriver.Retry.Tests.ps1).
# Edit cost: the final stage's whole-dir modules COPY (windows/Dockerfile) — cheap, it is
# the last stage. The docker-classic half died with build.ps1 (deleted 2026-08-31).
# build-buildkit.ps1 calls Initialize-BuildDriverContext once; functions read that module
# scope so call sites keep their signatures, and explicit parameters always win.

Set-StrictMode -Version Latest

# Import WITHOUT -Force and only if absent: a forced nested re-import rebinds Shared into
# this module's private scope and unloads the caller's top-level import.
if (-not (Get-Command Resolve-LatestVersionTag -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -DisableNameChecking
}

# Transient hcsshim/containerd failures kill container creation, typically right after a
# big layer commit; every retry loop classifies against this ONE pattern.
$script:BuildDriverContext = @{
    TransientPattern = 'ttrpc: closed|failed to create shim task|failed to create task for container|hcsshim|error during connect'
}

function Initialize-BuildDriverContext {
    # Docker/LogDir/NoCache went with build.ps1 (2026-08-31): nothing read them any more.
    param([string]$TransientPattern = '')
    if ($TransientPattern) { $script:BuildDriverContext.TransientPattern = $TransientPattern }
}

function Test-TransientDockerFailure {
    # Single source of truth for "is this a transient container-infrastructure failure?".
    param([string]$Tail)
    return [bool]($Tail -and ($Tail -match $script:BuildDriverContext.TransientPattern))
}

function Invoke-TransientCooldown {
    # $true (after sleeping the cooldown) when the tail looks transient AND a retry remains,
    # so the caller can `continue`; $false means hard failure.
    param(
        [Parameter(Mandatory)] [string]$Tail,
        [Parameter(Mandatory)] [int]$Attempt,
        [int]$MaxAttempts = 3,
        [string]$Label = '',
        [int]$CooldownSeconds = 60,
        # Caller already classified the failure as transient -- skip the re-test so the
        # condition is expressed exactly ONCE per call path.
        [switch]$AssumeTransient,
        # The PREVIOUS attempt's tail: byte-identical means DETERMINISTIC, not transient.
        [string]$PreviousTail = '',
        # Failure classes worth retrying EVEN WHEN the tail repeats verbatim. Snapshot MOUNT
        # contention is the measured case (the media merge went green on the third attempt);
        # an identical ImportLayer/ExportLayer at finalize is the opposite - a poisoned snapshot.
        [string]$RetryDespiteIdenticalPattern = 'failed to mount \{windows-layer|failed to calculate checksum of ref'
    )
    # DETERMINISM GATE: a flake changes between attempts, a poisoned snapshot does not.
    # Compared AFTER stripping buildkit's per-line elapsed-seconds prefix (docs/failure-modes.md
    # § `ImportLayer ... (0xb7)` on the SAME chain-IDs across retries).
    if ($PreviousTail -and ($RetryDespiteIdenticalPattern -and $Tail -match $RetryDespiteIdenticalPattern)) {
        Write-Host "[$Label] identical failure, but it is snapshot-mount contention — retrying anyway (measured to go green on a later attempt)." -ForegroundColor Yellow
    } elseif ($PreviousTail) {
        $normalise = { param($t) (($t -replace '(?m)^#\d+\s+[\d.]+\s+', '') -replace '\s+', ' ').Trim() }
        if ((& $normalise $Tail) -eq (& $normalise $PreviousTail)) {
            Write-Host ("[$Label] IDENTICAL failure to the previous attempt — deterministic, not transient. " +
                'Not retrying. If this is a poisoned snapshot (hcsshim ImportLayer/ExportLayer during finalize), ' +
                "the fix is -NoCache on this stage alone, NOT a retry — see AGENTS.md Common Failure Modes.") -ForegroundColor Red
            return $false
        }
    }
    if ($Attempt -lt $MaxAttempts -and ($AssumeTransient -or (Test-TransientDockerFailure -Tail $Tail))) {
        Write-Host "[$Label] transient container-infrastructure failure — retry $Attempt/$($MaxAttempts - 1) in ${CooldownSeconds}s" -ForegroundColor Yellow
        Start-Sleep -Seconds $CooldownSeconds
        return $true
    }
    return $false
}

# ── Lane-shared version/driver helpers ───────────────────────────────────────
# ONE canonical definition: both drivers carried hand-copied twins that had started to
# drift, so a version pin added for one lane silently missed the other.

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
        # COMPLETENESS IS LOAD-BEARING: the media stages no longer COPY versions.env, so these
        # maps are the ONLY channel by which current pins reach a branch's build scripts -- a
        # key missing here silently falls back to the base image's baked value. Re-audit when
        # adding a build script:
        #   grep -ohE '\$env:[A-Z_]+' windows/scripts/build/build-*.ps1
        #   grep -ohE "EnvironmentVariables?\s+@?\('[A-Z_, ']+" windows/scripts/build/build-*.ps1
        'media-core' {
            return @{
                ONNXRUNTIME_VERSION       = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                # build-opencv reads OPENCV_VERSION as well as the SOURCE alias.
                OPENCV_VERSION            = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-VersionTableValue $VersionTable 'FFMPEG_VERSION'
                PYAV_VERSION              = Get-VersionTableValue $VersionTable 'PYAV_VERSION'
                # Integrity pin for the hand-staged QAIRT SDK zip (ORT QNN EP, #121); empty
                # by default (no zip = EP off), same contract as TENSORRT_ZIP_SHA256.
                QNN_SDK_ZIP_SHA256        = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
                NV_CODEC_HEADERS_REF      = Get-VersionTableValue $VersionTable 'NV_CODEC_HEADERS_REF'
                CUDA_ARCHITECTURES        = Get-VersionTableValue $VersionTable 'CUDA_ARCHITECTURES'
                # build-opencv resolves the CPython it builds bindings against.
                PYTHON_VERSION            = Get-VersionTableValue $VersionTable 'PYTHON_VERSION'
            }
        }
        'media-litert' {
            return @{
                LITERT_VERSION    = Get-VersionTableValue $VersionTable 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-VersionTableValue $VersionTable 'LITERT_LM_VERSION'
                # litert-lm pins host protoc to its internal protobuf runtime; a mismatch
                # emits gencode the pinned headers #error on (35.1 vs 6.31.1).
                PROTOC_VERSION    = Get-VersionTableValue $VersionTable 'PROTOC_VERSION'
                # Bazel needs a JRE; litert-lm resolves it from this pin.
                JRE_VERSION       = Get-VersionTableValue $VersionTable 'JRE_VERSION'
                # Same QAIRT zip pin as media-core (#154): this branch MOUNTS
                # windows/qnn-sdk too, so without it Resolve-QnnSdk extracts unverified.
                QNN_SDK_ZIP_SHA256 = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
            }
        }
        'media-tvm' {
            return @{
                TVM_REF      = Get-VersionTableValue $VersionTable 'TVM_REF'
                IREE_VERSION = Get-VersionTableValue $VersionTable 'IREE_VERSION'
                # Same QAIRT zip pin as media-core (#154): this branch MOUNTS
                # windows/qnn-sdk too, so without it Resolve-QnnSdk extracts unverified.
                QNN_SDK_ZIP_SHA256 = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
            }
        }
    }
}

function Get-MediaMergeVersionArg {
    # The merge builder's canonical version env = union of all branch version
    # args MINUS core-branch compile inputs its Dockerfile declares no ARG for,
    # PLUS its own GStreamer pin.
    param([Parameter(Mandatory)][hashtable]$VersionTable)
    # BRANCH-ONLY keys: compile inputs the merge Dockerfile declares no ARG for. Forwarding
    # them only produces "unused build-arg" warnings and pollutes the merge stage's cache key.
    $branchOnly = @(
        'NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES',
        'PYTHON_VERSION', 'OPENCV_VERSION',   # media-core: OpenCV bindings target
        'QNN_SDK_ZIP_SHA256',                 # QAIRT zip pin (#121/#154): every stage that mounts windows/qnn-sdk
        'PROTOC_VERSION', 'JRE_VERSION'       # media-litert: litert-lm toolchain pins
    )
    $merge = @{}
    foreach ($branch in 'media-core', 'media-litert', 'media-tvm') {
        $args_ = Get-MediaBranchVersionArg -Branch $branch -VersionTable $VersionTable
        foreach ($k in $args_.Keys) {
            if ($k -notin $branchOnly) { $merge[$k] = $args_[$k] }
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
    # OrchestrANT ref: DETERMINISTIC by default (versions.env APP_REF pin). -LatestApp
    # resolves the app repo's newest release tag, falling back to the pin when offline.
    param(
        [Parameter(Mandatory)][hashtable]$VersionTable,
        [switch]$LatestApp
    )
    $ref = Get-VersionTableValue $VersionTable 'APP_REF'
    if ($LatestApp) {
        try {
            $tagRaw = & git ls-remote --tags https://github.com/Kataglyphis/OrchestrANT.git 2>$null
            if ($LASTEXITCODE -eq 0 -and $tagRaw) {
                $latest = Resolve-LatestVersionTag -LsRemoteOutput @($tagRaw)
                if (-not [string]::IsNullOrWhiteSpace($latest)) { $ref = $latest }
            }
        } catch {
            Write-Verbose "ls-remote tag resolution failed, using pinned APP_REF: $($_.Exception.Message)"
        }
        Write-Host "-LatestApp: resolved OrchestrANT ref: $ref (versions.env pin: $(Get-VersionTableValue $VersionTable 'APP_REF'))"
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
    # 'media' only: the toolchain stage has no sccache wiring, and gating it on the endpoint
    # blocked toolchain-only builds for a cache they never used.
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

function Assert-DiskHeadroom {
    # Fail-fast disk gate: below ~25 GB free hcsshim stops failing honestly (vanished tools,
    # "failed to write compressed diff", ImportLayer 0xb7) and its poisoned snapshots outlive
    # the run -- docs/failure-modes.md § disk exhaustion in costume. Checks EVERY drive the
    # build touches: the CONTEXT drive can be a VHDX-backed D: (docs/windows-build-lanes.md
    # § VHDX-backed checkouts), and it fails the same dishonest way a full store drive does.
    param(
        # Extra drive letters to gate on. C (the layer stores) is always checked;
        # the drivers add their repo-root drive. Duplicates are harmless.
        [string[]]$Drive = @('C'),
        # 40 GB: comfortably above the ~25 GB misbehaviour band, with room for one heavy
        # layer's scratch.
        [int]$MinFreeGb = 40,
        [switch]$Force
    )
    $reclaim = 'Reclaim first (docs/windows-builds.md § Store GC): ' +
        'buildctl prune --free-storage <MB ABOVE total disk size, it is a minimum-free TARGET>; ' +
        'then admin `nerdctl --namespace buildkit rmi` for superseded bk-* stage tags. ' +
        'For a VHDX-backed checkout the lever is a different one entirely: ' +
        'windows\scripts\host\compact-host-vhdx.ps1 / rebuild-host-vhdx.ps1.'
    # Normalize: accept 'C', 'C:', 'C:\' and full paths alike, dedupe, keep order.
    $letters = [System.Collections.Generic.List[string]]::new()
    foreach ($d in (@('C') + $Drive)) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $letter = ($d.Trim() -replace '^([A-Za-z]).*$', '$1').ToUpperInvariant()
        if ($letter -and -not $letters.Contains($letter)) { $letters.Add($letter) }
    }
    $short = @()
    foreach ($letter in $letters) {
        $psDrive = Get-PSDrive $letter -ErrorAction SilentlyContinue
        # A drive that does not exist is not a failure: on another machine the repo may sit
        # on C:, collapsing the list to one entry.
        if (-not $psDrive -or $null -eq $psDrive.Free) { continue }
        $freeGb = [math]::Round($psDrive.Free / 1GB, 1)
        if ($freeGb -ge $MinFreeGb) {
            Write-Host "disk headroom OK: ${letter}: ${freeGb} GB free (min ${MinFreeGb} GB)" -ForegroundColor Cyan
            continue
        }
        $short += "${letter}: has ${freeGb} GB free"
    }
    if ($short.Count -eq 0) { return }
    $detail = $short -join '; '
    if ($Force) {
        Write-Warning "$detail (min ${MinFreeGb} GB) - continuing because -Force was passed. $reclaim"
        return
    }
    throw ("$detail, below the ${MinFreeGb} GB floor this build needs. " +
        'Starting here does not fail fast - it fails in hours, with symptoms that look like anything but disk ' +
        "(vanished tools, ExportLayer/ImportLayer errors), and leaves debris that outlives the run. $reclaim " +
        'Pass -Force to override deliberately.')
}

function Get-ShimPatchStatePath {
    # Where deploy-shim-patch.ps1 records what it installed. HOST state, not repo state: it
    # describes THIS machine's Stevedore install, so it must not travel with a checkout.
    param([string]$StatePath = '')
    if ($StatePath) { return $StatePath }
    if ($env:KATAGLYPHIS_SHIM_STATE) { return $env:KATAGLYPHIS_SHIM_STATE }
    $root = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return (Join-Path $root 'kataglyphis\shim-patch.json')
}

function Write-ShimPatchState {
    # Record the SHA256 of the shim just deployed; this hash is what Assert-ShimPatch checks
    # the live binary against on every BK build.
    param(
        [Parameter(Mandatory)][string]$ShimPath,
        [string]$StatePath = '',
        # Free-text: which patch variant went in ('local-45min', 'upstream-env', …).
        [string]$Variant = '',
        # The stock binary deploy-shim-patch preserved, if any -- lets the gate say
        # "reverted to stock" instead of the vaguer "hash changed".
        [string]$StockBackupPath = ''
    )
    $resolved = Get-ShimPatchStatePath -StatePath $StatePath
    $stockSha = ''
    if ($StockBackupPath -and (Test-Path $StockBackupPath)) {
        $stockSha = (Get-FileHash -Algorithm SHA256 -Path $StockBackupPath).Hash
    }
    $state = [ordered]@{
        schema     = 'kataglyphis/shim-patch-state@1'
        shimPath   = $ShimPath
        sha256     = (Get-FileHash -Algorithm SHA256 -Path $ShimPath).Hash
        sizeBytes  = (Get-Item $ShimPath).Length
        variant    = $Variant
        stockSha256 = $stockSha
        deployedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $resolved -Parent) | Out-Null
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $resolved -Encoding utf8
    return $resolved
}

function Assert-ShimPatch {
    # BuildKit-lane gate: the patched containerd-shim-runhcs-v1 (upstream microsoft/hcsshim#2855)
    # is silently restored to stock by every Stevedore/containerd update, and stock means the
    # 30s tearDownTimeout -- the first heavy media finalize then dies ExportLayer 0x3, hours in.
    # PRIMARY: SHA256 recorded by deploy-shim-patch.ps1 (refreshes when YOU deploy, so unlike a
    # size table it cannot rot). FALLBACK (no state file): the weak size heuristic, which warns
    # instead of failing. Only the OpenCV canary PROVES the patch took effect.
    param(
        [string]$ShimPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
        # Sizes measured on the reference host; extend as hcsshim moves.
        [long[]]$PatchedSize = @(25332736, 25329664),
        [long[]]$StockSize = @(23279616),
        [string]$StatePath = '',
        # Roots buildctl resolution uses; injectable so the not-found path is testable
        # on a host that HAS a real shim installed.
        [string[]]$AlternateRoot = @(
            "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
            'D:\Stevedore\bin\containerd-shim-runhcs-v1.exe'
        ),
        [switch]$Force
    )
    # Defined BEFORE the not-found branch below, which quotes it in its throw.
    $advice = 'Re-install it before building: pwsh -File windows\scripts\host\deploy-shim-patch.ps1 ' +
        '-ShimPath <your build> (and -ServiceEnvironment for an upstream-patch build, which needs ' +
        'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT set or it silently keeps the 30s default). ' +
        'Recipe + patch: windows/upstream/hcsshim-teardown-timeout/.'
    # FAIL CLOSED on a shim we cannot find (backlog #48): "could not check" is the one answer
    # that must not read as "fine". Probe the roots buildctl resolution uses before giving up.
    if (-not (Test-Path $ShimPath)) {
        $alt = @($AlternateRoot) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        if ($alt) {
            Write-Host "shim not at $ShimPath; using $alt" -ForegroundColor DarkGray
            $ShimPath = $alt
        } elseif ($Force) {
            Write-Warning "shim not found at $ShimPath and no alternate root has one - continuing because -Force/-SkipHostChecks was passed."
            return
        } else {
            throw ("containerd shim not found at '$ShimPath' (nor under D:\Stevedore\bin). " +
                   'Refusing to build: an UNPATCHED shim kills heavy RUN layers with ExportLayer 0x3 only ' +
                   "AFTER the compile is paid for, so an unverifiable shim is not a safe default. $advice " +
                   'Pass -SkipHostChecks to override deliberately.')
        }
    }
    $size = (Get-Item $ShimPath).Length

    $statePath = Get-ShimPatchStatePath -StatePath $StatePath
    $state = $null
    if (Test-Path $statePath) {
        try { $state = Get-Content $statePath -Raw | ConvertFrom-Json }
        catch { Write-Warning "shim state file $statePath is unreadable ($($_.Exception.Message)) - falling back to the size check." }
    }
    # A state file written for a DIFFERENT install path describes another binary; treat it
    # as absent rather than comparing unrelated hashes.
    if ($state -and $state.shimPath -and $state.shimPath -ne $ShimPath) {
        Write-Warning "shim state file $statePath records '$($state.shimPath)', not '$ShimPath' - falling back to the size check."
        $state = $null
    }

    if ($state -and $state.sha256) {
        $live = (Get-FileHash -Algorithm SHA256 -Path $ShimPath).Hash
        if ($live -eq $state.sha256) {
            $variant = if ($state.variant) { ", variant $($state.variant)" } else { '' }
            Write-Host "runhcs shim: hash matches the deployed patch (deployed $($state.deployedAt)$variant)" -ForegroundColor Cyan
            return
        }
        $what = if ($state.stockSha256 -and $live -eq $state.stockSha256) {
            'has been REVERTED TO THE STOCK BINARY'
        } else {
            'has CHANGED since the patch was deployed'
        }
        $detail = ("runhcs shim at $ShimPath $what (recorded $($state.sha256.Substring(0,12))… on " +
            "$($state.deployedAt), live $($live.Substring(0,12))…, $('{0:N0}' -f $size) bytes) - " +
            'most likely a Stevedore/containerd update. Heavy media layers WILL fail with ' +
            "hcsshim::ExportLayer 0x3 after the compile is already paid for. $advice")
        if ($Force) {
            Write-Warning "$detail Continuing because -Force was passed."
            return
        }
        throw "$detail Pass -Force to override."
    }

    # ── fallback: size heuristic (no recorded hash on this host yet) ──────────
    $record = "Record the deployed binary's hash so this gate stops guessing: re-run " +
        'windows\scripts\host\deploy-shim-patch.ps1 (it writes ' + $statePath + ' on a successful swap).'
    if ($PatchedSize -contains $size) {
        Write-Host "runhcs shim: patched build by SIZE ($('{0:N0}' -f $size) bytes; no recorded hash)" -ForegroundColor Cyan
        Write-Warning $record
        return
    }
    if ($StockSize -contains $size) {
        if ($Force) {
            Write-Warning "runhcs shim is STOCK ($('{0:N0}' -f $size) bytes) - continuing because -Force was passed. Expect ExportLayer 0x3 on the first heavy media finalize. $advice"
            return
        }
        throw ("runhcs shim at $ShimPath is the STOCK binary ($('{0:N0}' -f $size) bytes) - the teardown-timeout " +
            'patch has been reverted, most likely by a Stevedore/containerd update. Heavy media layers WILL fail ' +
            "with hcsshim::ExportLayer 0x3 after the compile is already paid for. $advice Pass -Force to override.")
    }
    Write-Warning ("runhcs shim size $('{0:N0}' -f $size) bytes is neither a known patched nor a known stock build, " +
        "and no deployed hash is recorded on this host. $record $advice")
}

function Get-StageDiskFloorGb {
    # Free-space floor for ONE stage, keyed on its label: observed consumption plus runway
    # clear of the ~25 GB band where hcsshim stops failing honestly. The floors are MEASURED
    # and both directions of error hurt -- docs/windows-build-lanes.md § Driver preflight
    # gates ("Per-stage disk floors are CALIBRATED, not guessed").
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    # PER SUB-STAGE, not per branch, and ordered most-specific first: 'media-core-built-onnx'
    # must not be caught by the generic media rule below it.
    switch -Regex ($Label) {
        'nvidia|sdk'                { return 60 }   # CUDA ~36 GB + export headroom
        'media-core-built-onnx'     { return 55 }   # the 25 GB image, the one that really needs room
        'media-core-built-opencv'   { return 45 }
        'media-core-built-ffmpeg'   { return 40 }
        'media-core-built$'         { return 40 }   # BK: the GenAI tail solve only
        'media-litert'              { return 45 }
        'media-tvm'                 { return 40 }
        'media-merge|merge'         { return 45 }   # mounts three branch trees at once
        # CLASSIC lane: its media-core is ONE run+commit doing the WHOLE chain, so it needs
        # the heaviest floor, not the lightest (a cross-lane parity test enforces that).
        'media-core|media-builder'  { return 55 }
        'toolchain'                 { return 40 }
        default                     { return 40 }
    }
}

function Assert-StageDiskHeadroom {
    # Per-stage gate: the start-of-run check passed at 164 GB free and the chain still walked
    # down to 23 GB INSIDE a heavy stage, where the only escape (killing the solve) poisons a
    # snapshot. Refusing to ENTER a stage that cannot fit costs nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Drive = 'C',
        [int]$FloorGb = 0,
        [switch]$Force
    )
    if ($FloorGb -le 0) { $FloorGb = Get-StageDiskFloorGb -Label $Label }
    $psDrive = Get-PSDrive $Drive -ErrorAction SilentlyContinue
    if (-not $psDrive -or $null -eq $psDrive.Free) {
        # Say so instead of returning silently (backlog #48): "no output" is
        # indistinguishable from "plenty of space" in a 2 MB build log.
        Write-Warning "[$Label] disk headroom NOT checked: drive '$Drive' has no readable free space (network drive, or wrong letter?)."
        return
    }
    $freeGb = [math]::Round($psDrive.Free / 1GB, 1)
    if ($freeGb -ge $FloorGb) {
        Write-Host "[$Label] disk OK: ${freeGb} GB free (stage floor ${FloorGb} GB)" -ForegroundColor DarkGray
        return
    }
    $msg = ("[$Label] C: has ${freeGb} GB free, below the ${FloorGb} GB this stage needs. Entering it anyway walks " +
        'into the band where hcsshim fails dishonestly, and the only escape (killing the solve) poisons a snapshot. ' +
        'Reclaim first — docs/windows-builds.md § Store GC: admin `nerdctl --namespace buildkit rmi` on superseded ' +
        'bk-* stage tags, then `buildctl prune --free-storage <MB above disk size>`.')
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg"
}

function Assert-BuildkitdStepLogEnv {
    # Host-drift preflight (backlog 0a): buildkitd must carry BUILDKIT_STEP_LOG_MAX_SIZE=-1 or
    # every RUN step's log clips at 2MiB and buries the causal error (a Stevedore repair once
    # wiped it; never swallow logs). Registry READ is non-admin; the fix needs elevation + a restart.
    param(
        [string]$ServiceName = 'buildkitd',
        # Injectable for tests: pass the service's Environment multi-string.
        [object[]]$EnvironmentOverride = $null,
        [switch]$Force
    )
    $envStrings = $EnvironmentOverride
    if ($null -eq $envStrings) {
        $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        # No service registered = not this host's lane; the buildctl
        # resolution in the driver is the authority on that failure.
        if (-not (Test-Path $svcKey)) { return }
        # Property-guarded read: `.Environment` on a key WITHOUT that value throws
        # PropertyNotFound under StrictMode - EXACTLY the wiped-env case this gate exists for.
        $props = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
        $envStrings = if ($props -and $props.PSObject.Properties.Name -contains 'Environment') { $props.Environment } else { @() }
    }
    if ((@($envStrings) -join "`n") -match 'BUILDKIT_STEP_LOG_MAX_SIZE\s*=\s*-1') { return }
    $msg = ("buildkitd service env is missing BUILDKIT_STEP_LOG_MAX_SIZE=-1 - step logs will clip at 2MiB. " +
        "Fix (elevated, between chain runs): windows\scripts\host\setup-new-host.ps1, or " +
        "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment " +
        "-Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1') ; Restart-Service buildkitd.")
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg Pass -SkipHostChecks to override."
}

# SINGLE SOURCE for the RDNA4 hazard set (backlog #1): gate, toggle script and layer-lock
# A/B all resolve through this pattern; it forked into three divergent copies once. RDNA4
# discrete cards: RX 9xxx / AI PRO R9700 - extend as SKUs appear.
$script:Rdna4HazardPattern = 'Radeon\s*(\(TM\)\s*)?(AI\s+PRO\s+)?(RX\s+|R)?9\d{3}'

function Get-Rdna4HazardDevice {
    # Display-class PnP devices matching the RDNA4 hazard set (-ActiveOnly: the ENABLED ones).
    # $Devices and -Pattern are test injection points; production uses the single-source default.
    param(
        [object[]]$Devices = $null,
        [string]$Pattern = '',
        [switch]$ActiveOnly
    )
    if ([string]::IsNullOrWhiteSpace($Pattern)) { $Pattern = $script:Rdna4HazardPattern }
    if ($null -eq $Devices) {
        $Devices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
    }
    $hazards = @($Devices | Where-Object { $_.FriendlyName -match $Pattern })
    if ($ActiveOnly) { $hazards = @($hazards | Where-Object { $_.Status -eq 'OK' }) }
    return $hazards
}

function Set-Rdna4DeviceState {
    # Toggle primitive shared by toggle-rdna4-gpu.ps1 and the layer-lock A/B (backlog #6).
    # ELEVATED callers only, and always verify the post-state: a swallowed Enable-PnpDevice
    # failure strands the host on the iGPU while the console claims otherwise.
    param(
        [Parameter(Mandatory)][object]$Device,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    if ($State -eq 'Disabled') {
        Disable-PnpDevice -InstanceId $Device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        Enable-PnpDevice -InstanceId $Device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    $post = Get-PnpDevice -InstanceId $Device.InstanceId -ErrorAction SilentlyContinue
    $status = if ($post) { [string]$post.Status } else { 'unknown' }
    $ok = if ($State -eq 'Enabled') { $status -eq 'OK' } else { ($post -and $status -ne 'OK') }
    return [pscustomobject]@{ Ok = [bool]$ok; Status = $status }
}

function Assert-NoActiveRdna4Gpu {
    # Host gate: an ENABLED AMD RDNA4 dGPU + Adrenalin locks freshly-written container layer
    # files, so EVERY process-isolated RUN-layer finalize dies `hcsshim::ActivateLayer 0x20`
    # (docker/for-win#14977; A/B-proven here; COPY-only layers are unaffected, which is why
    # light probes look green). Build window: disable the dGPU, build, re-enable via
    # windows\scripts\host\toggle-rdna4-gpu.ps1 (elevated).
    # docs/failure-modes.md § `hcsshim::ActivateLayer 0x20` on an AMD Radeon host.
    param(
        # Injectable for tests. Default: live display-class PnP devices.
        [object[]]$Devices = $null,
        # Test-only override; production resolves via Get-Rdna4HazardDevice (backlog #1).
        [string]$HazardPattern = '',
        [switch]$Force
    )
    $hazards = @(Get-Rdna4HazardDevice -Devices $Devices -Pattern $HazardPattern)
    if ($hazards.Count -eq 0) { return }

    $active = @($hazards | Where-Object { $_.Status -eq 'OK' })
    if ($active.Count -eq 0) {
        # -f binds TIGHTER than + (an unwrapped concat printed a literal {0}): keep the
        # concat parenthesized.
        Write-Host (("RDNA4 gate: {0} present but DISABLED - RUN-layer finalize is safe; re-enable after the " +
            "build with windows\scripts\host\toggle-rdna4-gpu.ps1 (elevated).") -f $hazards[0].FriendlyName) -ForegroundColor Cyan
        return
    }
    $msg = (("'{0}' is ENABLED. On this host family an active RDNA4 dGPU makes EVERY process-isolated RUN-layer " +
        "finalize fail with hcsshim::ActivateLayer 0x20 (docker/for-win#14977; A/B-proven here 2026-08-10) - the " +
        "chain would die on its first RUN commit. Disable it for the build window (display falls back to the " +
        "iGPU): elevated pwsh -File windows\scripts\host\toggle-rdna4-gpu.ps1 -Disable, build, then re-enable with " +
        "the same script (default action). Verify first with probe-build-copy.ps1 -Heavy.") -f $active[0].FriendlyName)
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg Pass -SkipHostChecks to override."
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

Export-ModuleMember -Function Initialize-BuildDriverContext,
    Test-TransientDockerFailure, Invoke-TransientCooldown,
    Get-VersionTableValue, Get-MediaBranchVersionArg, Get-MediaMergeVersionArg,
    Get-BuildVcsRef, Resolve-TorchAppRef, Assert-SccacheEndpoint, Get-MediaMemoryBudget,
    Assert-DiskHeadroom, Assert-ShimPatch,
    Get-ShimPatchStatePath, Write-ShimPatchState,
    Get-StageDiskFloorGb, Assert-StageDiskHeadroom, Assert-NoActiveRdna4Gpu,
    Get-Rdna4HazardDevice, Set-Rdna4DeviceState, Assert-BuildkitdStepLogEnv
