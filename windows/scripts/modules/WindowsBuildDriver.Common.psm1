#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
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
        [switch]$AssumeTransient,
        # The PREVIOUS attempt's tail. When the new failure is byte-identical,
        # the failure is DETERMINISTIC, not transient, and retrying is pure
        # waste — see the determinism gate below.
        [string]$PreviousTail = '',
        # Failure classes that are genuinely worth retrying EVEN WHEN the tail
        # repeats verbatim, i.e. the determinism gate must not judge them.
        # Snapshot MOUNT contention is the measured case: the media merge mounts
        # three branch trees at once and was recorded going green only on the
        # third attempt (2026-08-06), with the same layer path named each time.
        # Finalize/commit failures are the opposite — an identical
        # ImportLayer/ExportLayer there means a poisoned snapshot that no number
        # of retries will fix.
        [string]$RetryDespiteIdenticalPattern = 'failed to mount \{windows-layer|failed to calculate checksum of ref'
    )
    # DETERMINISM GATE (2026-08-07). A flake changes between attempts; a poisoned
    # snapshot does not. `ImportLayer 0xb7` failed three times that day with
    # byte-identical snapshot IDs — the pattern matched `failed to reimport
    # snapshot`, so this function happily paid two retries and two cool-downs
    # before the caller gave up. Comparing against the previous tail turns ~10
    # wasted minutes into an immediate, correctly-named failure.
    #
    # Compared AFTER stripping timing noise: buildkit prefixes every line with
    # elapsed seconds (`#9 627.3 …`), which differ between attempts even when the
    # failure is identical.
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
        # Surface the CAUSE, not just an exit code (backlog #42). $tail is
        # already computed above for the transient classification and was then
        # discarded, so the classic lane threw a bare exit code and left the
        # owner to find and open the log by hand. Same fix as the BK lane.
        if ($tail) {
            Write-Host "`n--- [$Label] tail of the failing attempt ---" -ForegroundColor Yellow
            Write-Host $tail
            Write-Host "--- end of tail$(if ($LogFile) { " (full log: $LogFile)" }) ---`n" -ForegroundColor Yellow
        }
        throw "[$Label] docker step failed (exit $exitCode)$(if ($LogFile) { " — full log: $LogFile" })"
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
        # COMPLETENESS IS LOAD-BEARING (2026-08-07). Since the media stages no
        # longer COPY versions.env (that COPY made every pin edit invalidate the
        # whole media chain), these maps are the ONLY channel by which current
        # version values reach a branch's build scripts. A key that a script
        # reads but that is missing here falls back to the value baked into the
        # base image — silently, and possibly months old.
        #
        # The lists below were derived by auditing what the scripts actually
        # read, both directly (`$env:X`) and indirectly (`Get-SourceBuildVersion
        # -EnvironmentVariables`). Re-run that audit when adding a build script:
        #   grep -ohE '\$env:[A-Z_]+' windows/scripts/build-*.ps1
        #   grep -ohE "EnvironmentVariables?\s+@?\('[A-Z_, ']+" windows/scripts/build-*.ps1
        'media-core' {
            return @{
                ONNXRUNTIME_VERSION       = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                # build-opencv reads OPENCV_VERSION as well as the SOURCE alias.
                OPENCV_VERSION            = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-VersionTableValue $VersionTable 'FFMPEG_VERSION'
                PYAV_VERSION              = Get-VersionTableValue $VersionTable 'PYAV_VERSION'
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
                # litert-lm pins host protoc to its internal protobuf runtime —
                # a mismatch emits gencode the pinned headers #error on (bit us
                # 2026-08-03: 35.1 vs 6.31.1). Losing this to a stale baked value
                # would reintroduce exactly that.
                PROTOC_VERSION    = Get-VersionTableValue $VersionTable 'PROTOC_VERSION'
                # Bazel needs a JRE; litert-lm resolves it from this pin.
                JRE_VERSION       = Get-VersionTableValue $VersionTable 'JRE_VERSION'
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
    # BRANCH-ONLY keys: compile inputs the merge Dockerfile declares no ARG for.
    # Forwarding them would only produce "unused build-arg" frontend warnings and
    # put unrelated values into the merge stage's cache key. The list grew on
    # 2026-08-07 when the branch maps gained the keys that used to arrive via the
    # (now removed) versions.env COPY — a pre-existing test caught the leak
    # immediately, which is why it is enumerated here rather than filtered by
    # guesswork.
    $branchOnly = @(
        'NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES',
        'PYTHON_VERSION', 'OPENCV_VERSION',   # media-core: OpenCV bindings target
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

function Assert-DiskHeadroom {
    # Fail-fast disk gate shared by both lanes. Below roughly 25 GB free,
    # hcsshim stops failing honestly and starts failing WEIRDLY: vanished
    # tools ("ninja is not recognized" mid-build), "failed to write compressed
    # diff", ImportLayer 0xb7 / ActivateLayer 0x20 on snapshots that were fine
    # an hour ago — and the poisoned snapshots outlive the build that made
    # them. 2026-08-06: a full chain ran 2.5 h and died with the ninja symptom
    # at 4.8 GB free, and the two debris families it left cost another two
    # runs to sidestep. Two seconds of checking replaces all of that.
    #
    # CHECKS EVERY DRIVE THE BUILD TOUCHES, not just C:. The layer stores live on
    # C:, but the build CONTEXT is the repo checkout — on the reference host a
    # dynamically-expanding VHDX mounted at D:, which has its own reclaim trap
    # (docs/windows-builds.md § VHDX-backed checkouts: 270 GB physical for 16 GB
    # of live data, measured 2026-08-06) and fell to 11.7 GB free while a
    # C:-only gate reported everything fine. A full context drive fails the same
    # dishonest way a full store drive does.
    param(
        # Extra drive letters to gate on. C (the layer stores) is always checked;
        # the drivers add their repo-root drive. Duplicates are harmless.
        [string[]]$Drive = @('C'),
        # 40 GB is the Phase-D checklist figure: comfortably above the ~25 GB
        # misbehaviour band, with room for one heavy layer's scratch.
        [int]$MinFreeGb = 40,
        [switch]$Force
    )
    $reclaim = 'Reclaim first (docs/windows-builds.md § Store GC): ' +
        'buildctl prune --free-storage <MB ABOVE total disk size, it is a minimum-free TARGET>; ' +
        'then admin `nerdctl --namespace buildkit rmi` for superseded bk-* stage tags. ' +
        'For a VHDX-backed checkout the lever is a different one entirely: ' +
        'windows\scripts\compact-host-vhdx.ps1 / rebuild-host-vhdx.ps1.'
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
        # A drive that does not exist is not a failure: the repo may well sit on
        # C: on another machine, in which case the list collapses to one entry.
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

function Assert-DockerDaemon {
    # Classic-lane gate. The docs call this lane the "always-working fallback",
    # but on a Stevedore host the daemon is the `stevedore` SERVICE (it is
    # dockerd: "...\Stevedore\dockerd.exe --run-service --service-name stevedore
    # --host npipe:...dockerDesktopWindowsEngine --containerd=npipe:...").
    # Found Stopped on the reference host 2026-08-07 while the BuildKit lane ran
    # happily — i.e. the fallback was unavailable and nothing said so until you
    # needed it. `docker.exe` on PATH proves nothing; only a reachable daemon does.
    param(
        [string]$Docker = 'docker.exe',
        [string]$ServiceName = 'stevedore',
        [switch]$Force
    )
    $null = & $Docker version --format '{{.Server.Version}}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'docker daemon reachable' -ForegroundColor Cyan
        return
    }
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    $state = if ($svc) { "the '$ServiceName' service is $($svc.Status)" } else { "no '$ServiceName' service found" }
    # Starting dockerd is NOT a safe reflex: it recreates the nat HNS network,
    # which can move the subnet out from under
    # C:\Program Files\containerd\cni\conf\0-containerd-nat.conf and leave
    # BuildKit containers with unroutable IPs. Hence: instruct, do not auto-start.
    $advice = "Start it deliberately (admin): Start-Service $ServiceName - then RE-CHECK the CNI subnet, " +
        'because a dockerd start recreates the nat HNS network and can orphan ' +
        '0-containerd-nat.conf (build-buildkit.ps1 fail-fasts on that drift with the exact fix).'
    if ($Force) {
        Write-Warning "docker daemon unreachable ($state) - continuing because -Force was passed. $advice"
        return
    }
    throw ("docker daemon is not reachable ($state). This lane needs it; docker.exe being on PATH does not " +
        "mean a daemon is running. $advice Pass -Force to override.")
}

function Get-ShimPatchStatePath {
    # Where deploy-shim-patch.ps1 records what it installed, and where
    # Assert-ShimPatch reads it back. Host state, not repo state: it describes
    # THIS machine's Stevedore install, so it must not travel with a checkout.
    param([string]$StatePath = '')
    if ($StatePath) { return $StatePath }
    if ($env:KATAGLYPHIS_SHIM_STATE) { return $env:KATAGLYPHIS_SHIM_STATE }
    $root = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return (Join-Path $root 'kataglyphis\shim-patch.json')
}

function Write-ShimPatchState {
    # Record the SHA256 of the shim that was just deployed. Called by
    # deploy-shim-patch.ps1 after a successful swap; this hash is what
    # Assert-ShimPatch checks the live binary against on every BK build.
    param(
        [Parameter(Mandatory)][string]$ShimPath,
        [string]$StatePath = '',
        # Free-text: which patch variant went in ('local-45min', 'upstream-env', …).
        [string]$Variant = '',
        # The stock binary deploy-shim-patch preserved, if any — lets the gate
        # say "reverted to stock" instead of the vaguer "hash changed".
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
    # BuildKit-lane gate: the patched containerd-shim-runhcs-v1 is a LOCAL
    # patch (upstream: microsoft/hcsshim#2855) and EVERY Stevedore/containerd
    # update silently restores the stock binary. Stock means the hardcoded 30s
    # tearDownTimeout is back, which means the first heavy media finalize dies
    # with ExportLayer 0x3 — hours in, after the compile is already paid for.
    #
    # PRIMARY CHECK: SHA256 against what deploy-shim-patch.ps1 recorded when it
    # installed the binary (2026-08-07). This repo pins every other downloaded
    # input by hash — pwsh zip, git installer, scoop installer, CUDA, cuDNN,
    # nuget — and the shim is the one binary whose reversion costs hours, so it
    # gets the same treatment. The recorded hash refreshes when YOU deploy, so
    # unlike a size table it cannot rot as hcsshim moves.
    #
    # FALLBACK (no state file yet): the original size heuristic. It exists only
    # so an un-recorded host is not blocked; sizes are a weak signal, which is
    # exactly why an unrecognised one warns rather than fails — and why the
    # warning now tells you how to upgrade the host to the hash check.
    #
    # Behavioural verification is still the only PROOF the patch took effect
    # (the shim logs its timeout at Debug level, which never reaches
    # containerd's log): run the OpenCV canary after any shim or OS change.
    param(
        [string]$ShimPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
        # Sizes measured on the reference host; extend as hcsshim moves.
        [long[]]$PatchedSize = @(25332736, 25329664),
        [long[]]$StockSize = @(23279616),
        [string]$StatePath = '',
        [switch]$Force
    )
    # Defined BEFORE the not-found branch below, which quotes it in its throw.
    $advice = 'Re-install it before building: pwsh -File windows\scripts\deploy-shim-patch.ps1 ' +
        '-ShimPath <your build> (and -ServiceEnvironment for an upstream-patch build, which needs ' +
        'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT set or it silently keeps the 30s default). ' +
        'Recipe + patch: windows/upstream/hcsshim-teardown-timeout/.'
    # FAIL CLOSED on a shim we cannot find (backlog #48). This used to warn and
    # return green — including on a D:\Stevedore host, a layout the SAME driver
    # explicitly supports when resolving buildctl. The gate exists because a
    # STOCK shim means ExportLayer 0x3 *after* the compile is already paid for,
    # so "could not check" is the one answer that must not read as "fine".
    # Probe the same candidate roots buildctl resolution uses before giving up.
    if (-not (Test-Path $ShimPath)) {
        $alt = @(
            "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
            'D:\Stevedore\bin\containerd-shim-runhcs-v1.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
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
    # A state file written for a DIFFERENT install path describes another
    # binary; treat it as absent rather than comparing unrelated hashes.
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
        'windows\scripts\deploy-shim-patch.ps1 (it writes ' + $statePath + ' on a successful swap).'
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
    # Free-space floor for ONE stage, keyed on its label. Stage-aware because the
    # stages differ by an order of magnitude, and CALIBRATED against a measured
    # run (2026-08-07) rather than guessed — an earlier 80 GB media floor refused
    # a legitimate rebuild at 72 GB free, and a gate that blocks correct work is
    # as useless as one that waves danger through. Observed consumption:
    #
    #   media-core (ONNX -> OpenCV -> FFmpeg -> GenAI):  118 -> 104 GB  (~15 GB)
    #   media-litert:                                    104 ->  83 GB  (~20 GB)
    #   media-tvm incl. export:                           83 ->  73 GB  (~10 GB)
    #   merge fan-in:                                     73 ->  65 GB  (~ 8 GB)
    #   sdk / CUDA:                                                     (~36 GB)
    #
    # Each floor is observed consumption plus runway to stay clear of the ~25 GB
    # band where hcsshim stops failing honestly. Revisit with numbers, not
    # intuition. Labels come from both lanes, so the patterns match BK stage
    # labels ('Dockerfile.media-builder:media-core-built-onnx') and classic ones
    # ('windows/Dockerfile.media-builder', 'media-core') alike.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    # PER SUB-STAGE, not per branch (refined 2026-08-07 after the coarse version
    # refused the FFmpeg sub-stage by 1.5 GB). Lumping every media-* label at one
    # floor applies ONNX's appetite to sub-stages an order of magnitude lighter,
    # which blocks correct work — the same failure mode as a floor that is too
    # low, just in the other direction. Measured this run:
    #
    #   ONNX  (25 GB image, the heaviest):  63 -> 56 GB   (~8 GB net after GC)
    #   OpenCV:                             56 -> 53.5 GB (~2.5 GB net)
    #   FFmpeg / GenAI:                     lighter still
    #
    # Ordered most-specific first: 'media-core-built-onnx' must not be caught by
    # the generic media rule below it.
    switch -Regex ($Label) {
        'nvidia|sdk'                { return 60 }   # CUDA ~36 GB + export headroom
        'media-core-built-onnx'     { return 55 }   # the 25 GB image, the one that really needs room
        'media-core-built-opencv'   { return 45 }
        'media-core-built-ffmpeg'   { return 40 }
        'media-core-built$'         { return 40 }   # BK: the GenAI tail solve only
        'media-litert'              { return 45 }
        'media-tvm'                 { return 40 }
        'media-merge|merge'         { return 45 }   # mounts three branch trees at once
        # CLASSIC lane: its media-core is ONE run+commit doing the WHOLE chain
        # (ONNX -> OpenCV -> FFmpeg -> GenAI), so it needs the heaviest floor,
        # not the lightest. Caught by the cross-lane parity test — the first
        # refinement gave it 40 and would have under-protected the lane that has
        # no per-solve checkpoints to fall back on.
        'media-core|media-builder'  { return 55 }
        'toolchain'                 { return 40 }
        default                     { return 40 }
    }
}

function Assert-StageDiskHeadroom {
    # Per-stage gate, shared by both lanes. The start-of-run Assert-DiskHeadroom
    # passed at 164 GB free on 2026-08-07 and the chain still walked down to
    # 23 GB INSIDE a heavy stage — into the band where hcsshim fails
    # dishonestly. Escaping it meant killing the solve, and that kill poisoned a
    # snapshot (three failed attempts plus a -NoCache rebuild). Refusing to
    # ENTER a stage that cannot fit costs nothing while stopping is still free.
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
        # Say so instead of returning silently (backlog #48): a mid-chain gate
        # that cannot read its target reports nothing, and "no output" is
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
    # Host-drift preflight (backlog 0a): the buildkitd service must carry
    # BUILDKIT_STEP_LOG_MAX_SIZE=-1 or every RUN step's log clips at 2MiB and
    # buries the causal error of a multi-hour build. This exact drift ate a
    # day on 2026-08-10 (a Stevedore repair silently wiped the service env;
    # owner directive: never swallow logs). Non-admin registry READ; the fix
    # needs elevation and a service restart - between chain runs only.
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
        # Property-guarded read: `.Environment` on a key WITHOUT that value
        # throws PropertyNotFound under StrictMode - which is EXACTLY the
        # wiped-env case this gate exists for (it killed run 13's launch,
        # 2026-08-10, because the tests only ever injected the override).
        $props = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
        $envStrings = if ($props -and $props.PSObject.Properties.Name -contains 'Environment') { $props.Environment } else { @() }
    }
    if ((@($envStrings) -join "`n") -match 'BUILDKIT_STEP_LOG_MAX_SIZE\s*=\s*-1') { return }
    $msg = ("buildkitd service env is missing BUILDKIT_STEP_LOG_MAX_SIZE=-1 - step logs will clip at 2MiB. " +
        "Fix (elevated, between chain runs): windows\scripts\setup-new-host.ps1, or " +
        "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment " +
        "-Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1') ; Restart-Service buildkitd.")
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg Pass -SkipHostChecks to override."
}

# SINGLE SOURCE for the RDNA4 hazard set (backlog #1): the gate below, the
# toggle script and the layer-lock A/B all resolve through this pattern -
# it forked into three divergent copies once ((TM)-rename hole, 2026-08-10)
# and must never fork again. RDNA4 discrete cards: RX 9xxx / AI PRO R9700;
# extend as SKUs appear.
$script:Rdna4HazardPattern = 'Radeon\s*(\(TM\)\s*)?(AI\s+PRO\s+)?(RX\s+|R)?9\d{3}'

function Get-Rdna4HazardDevice {
    # Returns the display-class PnP devices matching the RDNA4 hazard set
    # (all of them, or only the ENABLED ones with -ActiveOnly). $Devices is
    # injectable for tests; -Pattern exists for tests only - production
    # callers must use the single-source default.
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
    # The toggle primitive shared by toggle-rdna4-gpu.ps1 and the layer-lock
    # A/B (backlog #6: the safety-critical re-enable path was duplicated).
    # ELEVATED callers only. Always verifies the post-state - a swallowed
    # Enable-PnpDevice failure strands the host on the iGPU while the
    # console claims otherwise (review sweep finding, 2026-08-10).
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
    # Host gate (2026-08-10, A/B-proven on the RX 9070 XT host): an ENABLED AMD
    # RDNA4 dGPU + Adrenalin driver locks freshly-written container layer files,
    # so EVERY process-isolated RUN-layer finalize dies with
    # `hcsshim::ActivateLayer 0x20 "file is being used by another process"` at
    # `failed to reimport snapshot` (upstream: docker/for-win#14977 — RDNA3.5/4,
    # open; severity shifts with the Windows patch level: pre-KB5101684 only
    # heavyweight layers tripped, post-KB5101684 even 10-byte RUN layers do).
    # COPY-only layers are unaffected — which is why light probes can look green
    # while the chain dies on its first RUN finalize. Same-boot A/B: disable the
    # dGPU -> tiny AND heavy finalize green; enable -> red. Defender exclusions,
    # daemon bounces, vmcompute restarts, store state, cache state and settle
    # delays were all falsified first.
    #
    # The build window is: disable the dGPU (display falls back to the iGPU),
    # build, re-enable. `windows\scripts\toggle-rdna4-gpu.ps1` (elevated) does
    # the toggle. This gate refuses to START a chain that would die on its
    # first RUN finalize hours before anyone looks.
    param(
        # Injectable for tests. Default: live display-class PnP devices.
        [object[]]$Devices = $null,
        # Test-only override; production resolves via Get-Rdna4HazardDevice
        # (the single source, backlog #1).
        [string]$HazardPattern = '',
        [switch]$Force
    )
    $hazards = @(Get-Rdna4HazardDevice -Devices $Devices -Pattern $HazardPattern)
    if ($hazards.Count -eq 0) { return }

    $active = @($hazards | Where-Object { $_.Status -eq 'OK' })
    if ($active.Count -eq 0) {
        # NOTE: -f binds TIGHTER than + (probed live 2026-08-10: an unwrapped
        # concat printed a literal {0}); keep the concat parenthesized.
        Write-Host (("RDNA4 gate: {0} present but DISABLED - RUN-layer finalize is safe; re-enable after the " +
            "build with windows\scripts\toggle-rdna4-gpu.ps1 (elevated).") -f $hazards[0].FriendlyName) -ForegroundColor Cyan
        return
    }
    $msg = (("'{0}' is ENABLED. On this host family an active RDNA4 dGPU makes EVERY process-isolated RUN-layer " +
        "finalize fail with hcsshim::ActivateLayer 0x20 (docker/for-win#14977; A/B-proven here 2026-08-10) - the " +
        "chain would die on its first RUN commit. Disable it for the build window (display falls back to the " +
        "iGPU): elevated pwsh -File windows\scripts\toggle-rdna4-gpu.ps1 -Disable, build, then re-enable with " +
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

Export-ModuleMember -Function Initialize-BuildDriverContext, Set-BuildDriverIsolation,
    Test-TransientDockerFailure, Invoke-TransientCooldown, Invoke-DockerWithRetry,
    Get-DockerBuildArgList, Assert-ImageExists, Resolve-BuildIsolation,
    Get-VersionTableValue, Get-MediaBranchVersionArg, Get-MediaMergeVersionArg,
    Get-BuildVcsRef, Resolve-TorchAppRef, Assert-SccacheEndpoint, Get-MediaMemoryBudget,
    Assert-DiskHeadroom, Assert-ShimPatch, Assert-DockerDaemon,
    Get-ShimPatchStatePath, Write-ShimPatchState,
    Get-StageDiskFloorGb, Assert-StageDiskHeadroom, Assert-NoActiveRdna4Gpu,
    Get-Rdna4HazardDevice, Set-Rdna4DeviceState, Assert-BuildkitdStepLogEnv
