# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#Requires -Version 7.0

<#
.SYNOPSIS
    EXPERIMENTAL BuildKit/containerd driver for the Windows image chain:
    base -> [nvidia] -> toolchain -> media -> torch -> final — every stage a
    plain build under PROCESS isolation with ALL host CPUs.

.DESCRIPTION
    Unlike docker's classic builder on this host, buildkitd+containerd commits
    process-isolated layers and gives RUN steps all CPUs, so this driver builds
    the SAME Dockerfiles via buildctl, selecting the `*-built` targets. The
    classic lane (windows/build.ps1) remains the fallback.

    Prerequisites (one-time, admin): buildkitd + containerd services running,
    and C:\Program Files\containerd\cni\conf\0-containerd-nat.conf present —
    without the conf, RUN steps get NO network adapter and every download fails.

    Results land in the CONTAINERD image store as
    docker.io/local/kataglyphis:bk-<stage>, fully qualified because buildkit
    normalizes FROM refs and stage handoff matches the stored name via
    `--opt image-resolve-mode=local`. These images are INVISIBLE to docker;
    use -FinalTar for a docker-loadable tarball.

.PARAMETER FinalTar
    Optional path: additionally export the final image as a docker-load tar.

.EXAMPLE
    .\windows\build-buildkit.ps1 -Gpu
.EXAMPLE
    .\windows\build-buildkit.ps1 -Stages toolchain -Verbose   # one stage
.NOTES
    INVOCATION TRAP: `pwsh -File ... -Stages sdk,toolchain,media` passes the
    list as ONE string and dies on the ValidateSet — `-File` cannot build
    arrays. Fix the CALL, not the ValidateSet — call the script directly, or use
    the call operator with a real array:

        & .\windows\build-buildkit.ps1 -Gpu -Stages @('sdk','toolchain','media')
#>
[CmdletBinding()]
param(
    [switch]$Gpu,
    # #135: build clang from source with the two AArch64 getInstSizeInBytes
    # patches and put it first on PATH. Opt-in — it adds a RUN and an ENV to the
    # toolchain image, which re-keys every media stage below it.
    [switch]$PatchedLlvm,
    # The build host is always windows/amd64, so 'arm64' is a CROSS build whose
    # product is an artifact bundle, not a runnable image. base/sdk/toolchain are
    # shared host tooling; only media onward forks on the target arch.
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
    # Extra 'KEY=VALUE' build-args forwarded to EVERY solve — escape hatch for
    # one-off investigations. Inert unless a Dockerfile declares a matching ARG.
    [string[]]$BuildArg = @(),
    # SMOKE GATE (backlog #44): after `final` the image must pass
    # smoke-test-container.ps1. -SkipSmokeGate is for iterating on the chain
    # itself; it does not make an unverified image safe to ship.
    [switch]$SkipSmokeGate,
    # Coverage floors, not just "0 failures" — a fully-skipped run used to exit 0.
    # Measured 2026-08-14 baseline: 184 passed / 1 skipped; raise with it, lower
    # only EXPLICITLY. A ceiling >= the suite's Skip-Test site count (33) is
    # inert — it cannot trip even if every section skips.
    [int]$SmokeMinPassed = 160,
    [int]$SmokeMaxSkipped = 3,
    # Per-stage cache bypass (backlog #64), e.g. -NoCacheStage opencv. Matched as
    # a substring of the stage LABEL; chain-wide -NoCache overrides everything.
    [string[]]$NoCacheStage = @(),
    # Optional cross-host/CI cache ref (import and/or export). Registry auth must
    # already be wired — docker login credentials are NOT shared with buildkitd.
    [string]$ExportCacheRef = '',
    [string]$ImportCacheRef = '',
    # OPT-IN: build the memory-bound aux branches (litert + tvm) CONCURRENTLY in
    # child drivers after media-core, each on half the memory budget. The
    # sequential default is the safe long-pole schedule.
    [switch]$ConcurrentAux,
    # Push the final image after the local export. buildctl forwards the CLIENT's
    # docker credential store, so a prior `docker login <registry>` suffices.
    [string]$PushRef = '',
    # Override the host preflight gates (disk headroom + patched runhcs shim) —
    # deliberate exceptions only; see Assert-DiskHeadroom / Assert-ShimPatch.
    [switch]$SkipHostChecks,
    # Backlog #18: bypass ONLY the RDNA4 gate without also disarming the
    # disk/shim gates the way the all-or-nothing -SkipHostChecks does.
    [switch]$SkipRdna4Gate,
    # Bypass ONLY the buildkitd step-log-env gate (0a) for one launch. The 2MiB
    # clip stays active, so chatty step middles are lost (causal errors still
    # reach stderr); restore properly via setup-new-host.ps1.
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
# Per-arch build-args come from the SAME table the in-container scripts read,
# so the two cannot drift.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsTargetArch.Common.psm1') -Force
# Shared transient-failure engine; the BK lane passes its own pattern below.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1') -Force

$script:LogDir = Join-Path $repoRoot 'out\windows-build-logs'
New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
# Per-RUN id in every stage-log name (backlog #61): label-only names made run N
# truncate run N-1's evidence, and left too few names for the rotation to rotate.
$script:RunId = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Stage -> seconds; the run manifest below is the only record of per-stage cost.
$script:StageTimings = [ordered]@{}
# Retention (backlog #30): ~80 files is several full chains of forensics.
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
# dockerd restarts recreate the 'nat' HNS network on a new subnet while the CNI
# conf pins a static one; drifted, containers get IPs with no gateway.
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildKit.Common.psm1') -Force
$cniDrift = Get-CniNatSubnetDrift
if ($cniDrift) { throw $cniDrift }
# Separate check: the drift guard passes green when the .conf has been renamed
# to .conflist for nerdctl and containers get NO adapter. Both must exist.
$cniForm = Get-CniConfFormIssue
if ($cniForm) { throw $cniForm }

# Transient patterns: hcs-temp finalize/export flakes, where completed RUN
# vertices stay cached so a retry only re-pays finalize. The negative lookahead
# on 'reimport snapshot' keeps a genuine ExportLayer 0x3 defect failing loudly.
Initialize-BuildDriverContext -Docker 'docker.exe' -LogDir $script:LogDir -TransientPattern 'hcsshim::(Activate|Prepare)Layer.*0x20|ttrpc: closed|failed to create shim task|failed to create task for container|error during connect|rpc error: code = Unavailable|failed to reimport snapshot(?!.*ExportLayer)|failed to write compressed diff|failed to extract layer|failed to mount \{windows-layer|failed to calculate checksum of ref'

# --- versions (single source of truth) ---
$versions = ConvertFrom-VersionsEnv -Path (Join-Path $repoRoot 'linux\scripts\01-core\versions.env')
# Thin lane-local alias over the canonical lookup (same alias in build.ps1).
function Get-Ver([string]$Key) {
    return Get-VersionTableValue -VersionTable $versions -Key $Key
}
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# --- resource budget + sccache gate (shared with build.ps1) ---
$MediaMemoryGb = Get-MediaMemoryBudget -RequestedGb $MediaMemoryGb -HostReserveGb $HostReserveGb
Write-Host "BuildKit lane: process isolation, all CPUs; memory budget $MediaMemoryGb GB (published via webdav, #51)" -ForegroundColor Cyan
Assert-SccacheEndpoint -Stages $Stages -SccacheEndpoint $SccacheEndpoint -NoSccache:$NoSccache

# --- cross-target gates: refuse the combinations that cannot work, in
# milliseconds rather than hours into a stage that cannot produce anything ----
if ($TargetArch -ne 'amd64') {
    if ($Gpu) {
        throw ("-Gpu is not available for -TargetArch $TargetArch yet: the CUDA/cuDNN stack is not wired " +
               'for the cross lane (cuDNN and TensorRT-RTX do ship Windows-on-ARM packages; classic ' +
               'TensorRT does not). The arm64 lane is CPU + DirectML + Vulkan today.')
    }
    # Asking for torch EXPLICITLY is an error; inheriting it from the $Stages
    # default just drops it — throwing there made plain -TargetArch arm64 fail.
    if ($Stages -contains 'torch') {
        $torchWhy = ('the torch stage runs ``uv sync``, which must EXECUTE the target interpreter - impossible in a ' +
                     'cross build. Independently, the pinned PyTorch publishes no win_arm64 wheel for the pinned Python.')
        if ($PSBoundParameters.ContainsKey('Stages')) {
            throw "-Stages torch is not available for -TargetArch $TargetArch : $torchWhy Re-run without torch, e.g. -Stages base,sdk,toolchain,media,final"
        }
        $Stages = @($Stages | Where-Object { $_ -ne 'torch' })
        Write-Host "[bk] stage 'torch' dropped for $TargetArch : $torchWhy" -ForegroundColor Yellow
    }
    # Every media branch builds on the cross lane (#115, #116); what a branch
    # cannot build for the target ships as an empty, marker-carrying tree --
    # exclusion table in docs/windows-cross-builds.md.
    Write-Host ("[bk] TARGET ARCH: $TargetArch (CROSS build - host stays windows/amd64). " +
                'Output is an artifact bundle, not a runnable image.') -ForegroundColor Yellow
}
# Branches the merge fan-in requires: all three on BOTH lanes (#115, #116).
$script:MergeRequiredBranches = @('media-core', 'media-litert', 'media-tvm')
# Forwarded to the stages AFTER the arch fork only: declaring this ARG on the
# shared base/sdk/toolchain would re-pay the VS Build Tools layer on every switch.
# OPENCV_ARCH_DIR rides along because the merge Dockerfile bakes OPENCV_LIB/BIN
# as ENV, which WINS over the arch-aware fallback in build-gstreamer-from-source.ps1.
$archArgs = @{
    WINDOWS_TARGET_ARCH = $TargetArch
    OPENCV_ARCH_DIR     = Get-OpenCvArchDir -Arch $TargetArch
}
# A FLOOR on files inspected: the Dockerfile default of 10 cannot detect losing
# a whole component. Measured counts minus headroom; raise with the bundle,
# never lower one to make a red run green -- a drop IS the finding.
# amd64 arch gate ~1134, import walk ~1100+; arm64 arch gate ~992, import walk ~606
# (arm64 has 3 ABSENT components, so its walk covers fewer files — 606 is the
# known-good, NOT 840 which was set against the arch-gate binary count).
$archArgs['ARCH_GATE_MIN_INSPECTED'] = if ($TargetArch -eq 'amd64') { '950' } else { '580' }
if ($TargetArch -ne 'amd64') {
    # #117: every .pyd in the merged HOST site-packages is the x64 build
    # interpreter's -- a REPORTED allowlist skip, never silent out-of-scope.
    $archArgs['ARCH_GATE_HOST_TOOLS'] = 'protoc\.exe|flatc\.exe|\\_deps\\|\\cpython\\Lib\\site-packages\\'
}

# --- host preflight (docs/windows-host-setup.md § Phase D item 3): a disk shortage surfaces
# as something unrelated (a missing ninja) and a Stevedore update reverts the
# shim patch. -Drive covers the repo drive, which buildctl streams the context from.
Assert-DiskHeadroom -Drive @($repoRoot) -MinFreeGb $MinFreeGb -Force:$SkipHostChecks
Assert-ShimPatch -Force:$SkipHostChecks
# Host-drift preflight (backlog 0a): the 2MiB step-log clip hid verdicts for a day.
Assert-BuildkitdStepLogEnv -Force:($SkipHostChecks -or $SkipStepLogGate)
Assert-NoActiveRdna4Gpu -Force:($SkipHostChecks -or $SkipRdna4Gate)

# --- tags: fully-qualified for containerd-store handoff; bk- namespaced so the
# classic docker lane's local/kataglyphis:windows-* tags can never collide ---
# amd64 keeps the historical unsuffixed names, a cross target appends its arch —
# except the shared pre-fork stages (suffixing would fork the chain's most
# expensive layers) and the final tags, which already spell their arch.
$script:NoSuffixTags = @('windows-base', 'windows-sdk', 'windows-toolchain', 'winamd64', 'winarm64')
function Get-BkTag([string]$Name) {
    $suffix = if ($TargetArch -eq 'amd64' -or $script:NoSuffixTags -contains $Name) { '' } else { "-$TargetArch" }
    return "docker.io/local/kataglyphis:bk-$Name$suffix"
}

# NB winarm64 labels a windows/amd64 image carrying an aarch64 payload - never
# publish it with --platform windows/arm64, that yields a manifest nothing runs.
$script:FinalTagName = if ($TargetArch -eq 'arm64') { 'winarm64' } else { 'winamd64' }

# Which -NoCacheStage entries matched a stage label; checked at the end of the
# run so a typo fails LOUDLY instead of building everything from cache (#64).
$script:NoCacheStageMatched = @{}

function Invoke-BkStage {
    param(
        [Parameter(Mandatory)][string]$Dockerfile,   # repo-relative
        [string]$Tag = '',
        [hashtable]$BuildArgs = @{},
        [string]$Target = '',
        [string]$Context = '.',
        [string]$Label = '',
        # WARM solve: no exporter, so nothing finalizes and the ExportLayer 0x3
        # defect never fires (docs/windows-builds.md § BuildKit/containerd lane).
        # Artifacts leave via the C:\bkhandoff cache mount (Export-BuildHandoff).
        [switch]$NoOutput,
        # Raw --output override (docker-tar / push), so the FinalTar and PushRef
        # re-solves ride the same retry + log plumbing as every stage.
        [string]$OutputSpec = '',
        # Transient-failure budget: 3 suits any stage touching ONE snapshot tree.
        # The media MERGE stage fans in three branch images and was measured
        # green only on its third attempt, so it asks for more.
        [int]$MaxAttempts = 3
    )
    if (-not $NoOutput -and -not $Tag -and -not $OutputSpec) { throw 'Invoke-BkStage: need -Tag, -OutputSpec or -NoOutput' }
    if (-not $Label) { $Label = [IO.Path]::GetFileName($Dockerfile) + $(if ($Target) { ":$Target" } else { '' }) }

    # PER-STAGE DISK GATE: the launch gate passed at 164 GB free and a heavy
    # stage still walked to 23 GB, where hcsshim stops failing honestly — and
    # killing the solve to escape poisons a snapshot. -Drive from the REPO root,
    # not 'C' (backlog #48); shared floors live in WindowsBuildDriver.Common.
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
    # Per-stage cache bust (backlog #64), the lever the determinism gate asks for.
    # Substring of the same $Label the logs and the disk gate use, so 'opencv'
    # catches 'Dockerfile.media-builder:media-core-built-opencv'.
    $matched = @($NoCacheStage | Where-Object { $Label -like "*$_*" })
    # Recorded so a typo fails at the END of the run: printing only on a match
    # would leave a misspelled entry silent and every stage cached (fail-open).
    foreach ($m in $matched) { $script:NoCacheStageMatched[$m] = $true }
    $stageNoCache = $matched.Count -gt 0
    if ($NoCache -or $stageNoCache) { $bkArgs += @('--no-cache') }
    if ($stageNoCache -and -not $NoCache) { Write-Host "[bk:$Label] -NoCacheStage match -> --no-cache for THIS stage only" -ForegroundColor Yellow }
    if ($Target) { $bkArgs += @('--opt', "target=$Target") }
    # mode=max also caches non-exported intermediate stages.
    if ($ImportCacheRef) { $bkArgs += @('--import-cache', "type=registry,ref=$ImportCacheRef") }
    if ($ExportCacheRef) { $bkArgs += @('--export-cache', "type=registry,ref=$ExportCacheRef,mode=max") }
    foreach ($k in ($BuildArgs.Keys | Sort-Object)) {
        $v = $BuildArgs[$k]
        if ($null -ne $v -and "$v" -ne '') { $bkArgs += @('--opt', "build-arg:$k=$v") }
    }
    # Arch is the one build-arg whose absence is INVISIBLE downstream: the stage
    # falls back to its amd64 default and fails much later as something unrelated.
    if ($BuildArgs.ContainsKey('WINDOWS_TARGET_ARCH')) {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH=$($BuildArgs['WINDOWS_TARGET_ARCH'])" -ForegroundColor DarkGray
    } elseif ($TargetArch -ne 'amd64') {
        Write-Host "    [build-arg] WINDOWS_TARGET_ARCH NOT PASSED to this stage (target is $TargetArch) - it will default to amd64" -ForegroundColor Yellow
    }
    # -BuildArg passthrough, applied LAST so an explicit one-off overrides the
    # stage's computed value rather than being silently dropped by it.
    foreach ($extra in $BuildArg) {
        # Strict KEY validation: buildctl silently discards build-args for ARG
        # names no Dockerfile declares, so a mangled key is invisible downstream
        # (`pwsh -File` flattens a comma array into one quoted string).
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
    # Retries on transient infra failures; a third attempt is cheap because
    # completed RUN vertices stay cached. Fresh log per RUN but APPENDED per
    # attempt (#41) — truncating destroyed attempt 1's real compile error.
    Remove-Item -Path $stageLog -Force -ErrorAction SilentlyContinue
    $previousTail = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "`n==> [bk:$Label] buildctl -> $dest$(if ($attempt -gt 1) { ' (retry)' })" -ForegroundColor Cyan
        "`n===== [bk:$Label] attempt $attempt/$MaxAttempts =====" | Add-Content -Path $stageLog -Encoding utf8
        & $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $stageLog -Append
        if ($LASTEXITCODE -eq 0) { break }
        $tail = if (Test-Path $stageLog) { (Get-Content $stageLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        # -PreviousTail arms the determinism gate: an identical failure is a
        # poisoned snapshot, not a flake, and retrying only burns the budget.
        if (Invoke-TransientCooldown -Tail $tail -PreviousTail $previousTail -Attempt $attempt -MaxAttempts $MaxAttempts -Label "bk:$Label" -CooldownSeconds 15) {
            $previousTail = $tail
            continue
        }
        # Surface the CAUSE, not just a log path (backlog #42).
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

# Preseed the vulkan SDK exe onto the LAN webdav: sdk.lunarg.com stalls
# reproducibly INSIDE containers while the host pulls the same file fine.
# Fail-open - the container keeps its own retried direct-download path.
if ($SccacheEndpoint) {
    $vkVer = Get-Ver 'VULKAN_VERSION'
    $vkName = "vulkansdk-windows-X64-$vkVer.exe"
    $vkOnDav = "$SccacheEndpoint/preseed/$vkName"
    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    $vkUrl = "https://sdk.lunarg.com/sdk/download/$vkVer/windows/$vkName"

    # ONLY a 404 is fatal: VULKAN_VERSION then names a file LunarG does not
    # publish FOR WINDOWS (its Windows SDK lags linux); 403/5xx stay fail-open.
    # Two traps: `-I` buries the status in headers (hence the one-byte RANGE),
    # and `-o $null` renders as an empty string, so curl writes the body out.
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

    try {
        & $curlExe -sfI $vkOnDav *> $null
        if ($LASTEXITCODE -ne 0) {
            $vkLocal = Join-Path $PSScriptRoot 'downloads' $vkName
            if (-not (Test-Path $vkLocal)) {
                Write-Host "preseed: downloading $vkName host-side..."
                & $curlExe -sfL --retry 3 --retry-delay 5 --retry-all-errors $vkUrl -o $vkLocal
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

    # #51: MEMORY_LIMIT_GB is a SCHEDULING knob, so it must not be an image
    # ARG/ENV (a cache key - a different-RAM host would invalidate everything).
    # Published to the endpoint instead, and PHASED: full budget for media-core
    # alone, halved for the two concurrent children, full again for the merge.
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
        # #50: consumed below versions.env's relocated COPY, so they ride as
        # ARGs - a Linux-key edit no longer re-pays scoop/vcpkg/rust. Keep in
        # sync with the ARG block in Dockerfile.base.
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
    # No $sccache here: neither Dockerfile.toolchain-builder nor
    # build-toolchain-all.ps1 has sccache wiring, so it is an unused build-arg.
    $toolchainArgs = @{
        BASE_IMAGE     = Get-BkTag 'windows-sdk'
        PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
    }
    $toolchainTarget = 'built'
    if ($PatchedLlvm) {
        $toolchainTarget = 'patched-llvm'
        $toolchainArgs['BUILD_PATCHED_LLVM'] = '1'
    }
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Target $toolchainTarget -Tag (Get-BkTag 'windows-toolchain') -BuildArgs $toolchainArgs
}

if ($Stages -contains 'media') {
    # Canonical per-branch version args, shared with build.ps1.
    $branchArgs = @{}
    foreach ($b in 'media-core', 'media-litert', 'media-tvm') {
        $branchArgs[$b] = Get-MediaBranchVersionArg -Branch $b -VersionTable $versions
    }
    $loopBranches = $MediaBranches
    $auxProcs = @()
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        # media-core (the long pole) stays sequential below; the child drivers
        # each build one aux branch on half the memory budget.
        $loopBranches = @($MediaBranches | Where-Object { $_ -notin @('media-litert', 'media-tvm') })
        $auxMem = [Math]::Max(8, [int]($MediaMemoryGb / 2))
    }
    foreach ($branch in $loopBranches) {
        $branchBuildArgs = @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
        } + $branchArgs[$branch] + $sccache + $archArgs
        if ($branch -eq 'media-core') {
            # DIRECT SOLVES: the warm/materialize pairs existed for the
            # ExportLayer-0x3 defect, fixed by the patched runhcs shim — see
            # docs/windows-build-lanes.md § Traps (Stevedore updates overwrite the
            # patch). The per-library split stays for per-layer caching.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-onnx' -Tag (Get-BkTag 'windows-media-core-onnx') -BuildArgs $branchBuildArgs
            $onnxArg   = @{ MEDIA_CORE_ONNX_IMAGE = Get-BkTag 'windows-media-core-onnx' }
            $opencvArg = @{ MEDIA_CORE_OPENCV_IMAGE = Get-BkTag 'windows-media-core-opencv' }
            $ffmpegArg = @{ MEDIA_CORE_FFMPEG_IMAGE = Get-BkTag 'windows-media-core-ffmpeg' }
            # ORDER onnx -> ffmpeg -> opencv -> genai (backlog #94): OpenCV must
            # configure AFTER FFmpeg exists or it silently links its own
            # downloaded prebuilt. Keep in step with Dockerfile.media-builder.
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-ffmpeg' -Tag (Get-BkTag 'windows-media-core-ffmpeg') -BuildArgs ($branchBuildArgs + $onnxArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built-opencv' -Tag (Get-BkTag 'windows-media-core-opencv') -BuildArgs ($branchBuildArgs + $ffmpegArg)
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target 'media-core-built' -Tag (Get-BkTag 'windows-media-core') -BuildArgs ($branchBuildArgs + $opencvArg)
        } else {
            Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Target "$branch-built" -Tag (Get-BkTag "windows-$branch") -BuildArgs $branchBuildArgs
        }
    }
    if ($ConcurrentAux -and ($MediaBranches -contains 'media-litert') -and ($MediaBranches -contains 'media-tvm')) {
        Write-Host "`n==> [bk:aux] concurrent litert + tvm child drivers ($auxMem GB memory budget each)" -ForegroundColor Cyan
        # Parallel phase begins: halve the published budget for the children.
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
            # -NoCacheStage must ride along (the children build litert/tvm), but
            # ONLY entries this child's branch can match: a parent-scoped label
            # would trip the child's own matched-nothing gate. -File cannot
            # deliver arrays (see .NOTES), so entries go one per argument.
            $auxNoCache = @($NoCacheStage | Where-Object { $aux -match [regex]::Escape(($_ -replace '^media-', '')) -or $_ -match ($aux -replace '^media-', '') })
            foreach ($ncs in $auxNoCache) { $auxArgs += @('-NoCacheStage', $ncs) }
            if ($ImportCacheRef) { $auxArgs += @('-ImportCacheRef', $ImportCacheRef) }
            if ($ExportCacheRef) { $auxArgs += @('-ExportCacheRef', $ExportCacheRef) }
            if ($BuildCtl) { $auxArgs += @('-BuildCtl', $BuildCtl) }
            # PREFLIGHT OVERRIDES: each child re-runs the FULL host preflight,
            # so an override the parent was launched with must reach it or the
            # child throws 1-2h in, after media-core is paid for (backlog #62).
            if ($SkipHostChecks) { $auxArgs += '-SkipHostChecks' }
            if ($SkipRdna4Gate) { $auxArgs += '-SkipRdna4Gate' }
            if ($SkipStepLogGate) { $auxArgs += '-SkipStepLogGate' }
            if ($NoSccache) { $auxArgs += '-NoSccache' }
            if ($PSBoundParameters.ContainsKey('MinFreeGb')) { $auxArgs += @('-MinFreeGb', $MinFreeGb) }
            if ($PSBoundParameters.ContainsKey('HostReserveGb')) { $auxArgs += @('-HostReserveGb', $HostReserveGb) }
            # Forward -BuildArg: the litert/tvm solves are the CHILDREN's, so a
            # parent-only compile knob is a no-op for two of three branches.
            foreach ($ba in $BuildArg) { $auxArgs += @('-BuildArg', $ba) }
            # QUOTE spaced elements: Start-Process -ArgumentList joins with
            # spaces and does NOT quote, so a path under 'C:\Program Files'
            # splits mid-token and kills both children right after media-core.
            $auxArgsQuoted = @($auxArgs | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } })
            $auxProcs += Start-Process -FilePath 'pwsh' -ArgumentList $auxArgsQuoted -PassThru -NoNewWindow
        }
        # FAIL FAST + never orphan (backlog #62): Wait-Process on the whole set
        # hid a child dying at minute 5, and an unguarded parent left two
        # buildctl trees solving against the same store.
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
    # The merge needs ALL THREE branch images and must run exactly ONCE: this
    # gate also keeps the single-branch -ConcurrentAux children out of it.
    $allBranches = $script:MergeRequiredBranches
    $runMerge = @($allBranches | Where-Object { $_ -notin $MediaBranches }).Count -eq 0
    if ($runMerge) {
        # The merge Dockerfile's unconditional COPY --from lines are satisfied
        # by each branch shipping its own (possibly empty, marker-carrying) tree.
        $litertImage = Get-BkTag 'windows-media-litert'
        $tvmImage    = Get-BkTag 'windows-media-tvm'
        # Canonical merge version env + BK tag wiring.
        $mergeArgs = (Get-MediaMergeVersionArg -VersionTable $versions) + @{
            BASE_IMAGE      = Get-BkTag 'windows-toolchain'
            CORE_IMAGE      = Get-BkTag 'windows-media-core'
            LITERT_IMAGE    = $litertImage
            TVM_IMAGE       = $tvmImage
        } + $archArgs
        # -MaxAttempts 5: mounting three branch trees is the only stage measured
        # burning its whole 3-attempt budget.
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -Target 'built' -Tag (Get-BkTag 'windows-media') -BuildArgs ($mergeArgs + $sccache) -MaxAttempts 5
    } else {
        # FAIL CLOSED (backlog #39): skipping the merge is fine alone, but
        # torch/final resolve BASE_IMAGE from the 'windows-media' tag, so they
        # would silently ship the PREVIOUS run's media image with a zero exit.
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

# Provenance stamps computed ONCE, so the FinalTar/PushRef re-solves stay cache
# hits of the final solve instead of regenerating LABEL with empty values.
$stampArgs = @{
    BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    VCS_REF    = Get-BuildVcsRef
}

if ($Stages -contains 'torch') {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.torch' -Tag (Get-BkTag 'windows-torch') -BuildArgs ($stampArgs + @{
        BASE_IMAGE = Get-BkTag 'windows-media'
        APP_REF    = Resolve-TorchAppRef -VersionTable $versions -LatestApp:$LatestApp
        # Without this a -Gpu chain ships CPU torch (Dockerfile default).
        PYTORCH_EXTRA = $(if ($Gpu) { 'pytorch-cu130' } else { 'pytorch-cpu' })
    })
}

if ($Stages -contains 'final') {
    # The arm64 lane skips the torch stage (guarded at launch), so its final
    # image is based on the merged media stage directly.
    $finalBase = if ($TargetArch -eq 'amd64') { Get-BkTag 'windows-torch' } else { Get-BkTag 'windows-media' }
    $finalArgs = $stampArgs + @{ BASE_IMAGE = $finalBase } + $archArgs
    # -Label 'final': the default label is the filename ('Dockerfile'), so
    # -NoCacheStage final matched only the re-exports, not this stage.
    Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final' -Tag (Get-BkTag $script:FinalTagName) -BuildArgs $finalArgs
    # SMOKE GATE (backlog #44). Runs as a buildctl solve, not `nerdctl run`,
    # because containerd's pipe is admin-only and this driver is non-admin.
    if ($TargetArch -ne 'amd64' -and -not $SkipSmokeGate) {
        # CROSS LANE: the suite runs its host-toolchain sections and skips the
        # payload ones itself. These are arm64's OWN floors -- 66 sits just under
        # its section-floor sum of 73 (name kept distinct for
        # Smoke.FloorCalibration.Tests.ps1); no gate here proves the payload RUNS.
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
        # LANE-AWARE FLOOR: 160 is the CPU number (just under its section-floor
        # sum of 161); on the GPU lane it would tolerate losing 60 of the 220
        # assertions a green run executes. 190 is the GPU column's sum in
        # smoke-test-container.ps1. An explicit -SmokeMinPassed always wins.
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
    # FAIL LOUDLY, pre-export (audit #15), on a -NoCacheStage entry that matched
    # nothing: a typo would otherwise leave every stage cached and look green.
    $unmatchedNoCacheStage = @($NoCacheStage | Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })
    if ($unmatchedNoCacheStage.Count -gt 0) {
        throw ("[bk] -NoCacheStage matched NO stage in this run: $($unmatchedNoCacheStage -join ', '). " +
               'Every stage built from cache, so nothing was busted. Check the spelling against the ' +
               'stage labels in the output above (they are the same labels used for the log filenames).')
    }
    # FinalTar / PushRef: the same final solve from cache, different exporter.
    # Push auth uses THIS shell's docker credential store (`docker login` first).
    if ($FinalTar) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-tar' -OutputSpec "type=docker,name=local/kataglyphis:$($script:FinalTagName),dest=$FinalTar" -BuildArgs $finalArgs
    }
    if ($PushRef) {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-push' -OutputSpec "type=image,name=$PushRef,push=true" -BuildArgs $finalArgs
        Write-Host "[bk] pushed $PushRef" -ForegroundColor Green
    }
}

# The matched-nothing gate fires PRE-EXPORT inside the final block; this copy
# covers runs WITHOUT 'final', where that site never executes.
if ($Stages -notcontains 'final') {
    $unmatchedNoCacheStage = @($NoCacheStage | Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })
    if ($unmatchedNoCacheStage.Count -gt 0) {
        throw ("[bk] -NoCacheStage matched NO stage in this run: $($unmatchedNoCacheStage -join ', '). " +
               'Every stage built from cache, so nothing was busted. Check the spelling against the ' +
               'stage labels in the output above (they are the same labels used for the log filenames).')
    }
}

$elapsed = (Get-Date) - $started
# Run manifest (backlog #61): machine-parseable per-stage seconds, one file per
# run — otherwise a green run records no per-stage cost anywhere.
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
