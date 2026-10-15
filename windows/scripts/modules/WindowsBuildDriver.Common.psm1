#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Build-Buildkit.ps1's core, a module so its failure paths are unit-testable; explicit parameters beat the driver context.

Set-StrictMode -Version Latest

# Only if absent, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
if (-not (Get-Command Resolve-LatestVersionTag -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -DisableNameChecking
}

# The one transient-failure pattern every retry loop classifies against.
$script:BuildDriverContext = @{
    TransientPattern = 'ttrpc: closed|failed to create shim task|failed to create task for container|hcsshim|error during connect'
    DriverLog        = ''
}

function Initialize-BuildDriverContext {
    param([string]$TransientPattern = '', [AllowEmptyString()][string]$DriverLog = '')
    if ($TransientPattern) { $script:BuildDriverContext.TransientPattern = $TransientPattern }
    # Bound and empty clears it, so a caller can end its records.
    if ($PSBoundParameters.ContainsKey('DriverLog')) { $script:BuildDriverContext.DriverLog = $DriverLog }
}

function Write-DriverRecord {
    # The console is no record: a retry or disk-gate verdict also lands in the run's driver log, when one is set (hub #184).
    param([Parameter(Mandatory)][string]$Message)
    $log = $script:BuildDriverContext.DriverLog
    if (-not $log) { return }
    try { Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-ddTHH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding utf8 -ErrorAction Stop }
    catch { Write-Warning "driver log write failed ($log): $($_.Exception.Message)" }
}

function Test-TransientDockerFailure {
    param([string]$Tail)
    return [bool]($Tail -and ($Tail -match $script:BuildDriverContext.TransientPattern))
}

function Invoke-TransientCooldown {
    # $true after the cooldown when the failure is transient and a retry remains; $false is a hard failure.
    param(
        [Parameter(Mandatory)] [string]$Tail,
        [Parameter(Mandatory)] [int]$Attempt,
        [int]$MaxAttempts = 3,
        [string]$Label = '',
        [int]$CooldownSeconds = 60,
        # The caller already classified it as transient; skip the re-test.
        [switch]$AssumeTransient,
        # The PREVIOUS attempt's tail: byte-identical means DETERMINISTIC, not transient.
        [string]$PreviousTail = '',
        # Retried even when identical: snapshot-mount contention clears, unlike a poisoned snapshot at finalize.
        [string]$RetryDespiteIdenticalPattern = 'failed to mount \{windows-layer|failed to calculate checksum of ref'
    )
    # A flake changes between attempts, a poisoned snapshot does not: docs/failure-modes.md § `ImportLayer ... (0xb7)` on the SAME chain-IDs across retries
    if ($PreviousTail -and ($RetryDespiteIdenticalPattern -and $Tail -match $RetryDespiteIdenticalPattern)) {
        Write-Host "[$Label] identical failure, but it is snapshot-mount contention — retrying anyway (measured to go green on a later attempt)." -ForegroundColor Yellow
    } elseif ($PreviousTail) {
        $normalise = { param($t) (($t -replace '(?m)^#\d+\s+[\d.]+\s+', '') -replace '\s+', ' ').Trim() }
        if ((& $normalise $Tail) -eq (& $normalise $PreviousTail)) {
            Write-Host ("[$Label] IDENTICAL failure to the previous attempt — deterministic, not transient. " +
                'Not retrying. If this is a poisoned snapshot (hcsshim ImportLayer/ExportLayer during finalize), ' +
                "the fix is -NoCache on this stage alone, NOT a retry — see AGENTS.md Common Failure Modes.") -ForegroundColor Red
            Write-DriverRecord "[$Label] attempt $Attempt/$MaxAttempts failed identically to the previous one: deterministic, not retried"
            return $false
        }
    }
    if ($Attempt -lt $MaxAttempts -and ($AssumeTransient -or (Test-TransientDockerFailure -Tail $Tail))) {
        Write-Host "[$Label] transient container-infrastructure failure — retry $Attempt/$($MaxAttempts - 1) in ${CooldownSeconds}s" -ForegroundColor Yellow
        $cause = @(($Tail -split "`r?`n") | Where-Object { $_ -match $script:BuildDriverContext.TransientPattern } | Select-Object -Last 1)
        Write-DriverRecord "[$Label] attempt $Attempt/$MaxAttempts failed transiently: retry $Attempt/$($MaxAttempts - 1) in ${CooldownSeconds}s ($(if ($cause) { $cause[0].Trim() } else { 'classified by the caller' }))"
        Start-Sleep -Seconds $CooldownSeconds
        return $true
    }
    Write-DriverRecord "[$Label] attempt $Attempt/$MaxAttempts failed: $(if ($Attempt -ge $MaxAttempts) { 'no attempt left' } else { 'not transient' }), no retry"
    return $false
}

# ── Lane-shared version/driver helpers ───────────────────────────────────────

function Get-VersionTableValue {
    param(
        [Parameter(Mandatory)][hashtable]$VersionTable,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $VersionTable.Contains($Key)) { throw "versions.env has no key $Key" }
    return $VersionTable[$Key]
}

function Get-MediaBranchVersionArg {
    # Versions only; callers add the lane-shaped BASE_IMAGE, MEMORY_LIMIT_GB and sccache args.
    param(
        [Parameter(Mandatory)][ValidateSet('media-core', 'media-litert', 'media-tvm', 'rocm-migraphx')][string]$Branch,
        [Parameter(Mandatory)][hashtable]$VersionTable
    )
    switch ($Branch) {
        # Must list every pin a branch's scripts read: a missing key silently falls back to the base image's baked value.
        'media-core' {
            return @{
                ONNXRUNTIME_VERSION       = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-VersionTableValue $VersionTable 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                # build-opencv reads OPENCV_VERSION as well as the SOURCE alias.
                OPENCV_VERSION            = Get-VersionTableValue $VersionTable 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-VersionTableValue $VersionTable 'FFMPEG_VERSION'
                PYAV_VERSION              = Get-VersionTableValue $VersionTable 'PYAV_VERSION'
                # PyAV's Cython; media-tvm installs the same one, as the fan-in refuses two versions.
                PY_CYTHON_VERSION         = Get-VersionTableValue $VersionTable 'PY_CYTHON_VERSION'
                # Hand-staged QAIRT SDK zip pin; empty by default (no zip = QNN EP off).
                QNN_SDK_ZIP_SHA256        = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
                NV_CODEC_HEADERS_REF      = Get-VersionTableValue $VersionTable 'NV_CODEC_HEADERS_REF'
                # AMF headers for FFmpeg; only the rocm lane fetches them, every lane carries the pin.
                AMF_HEADERS_VERSION       = Get-VersionTableValue $VersionTable 'AMF_HEADERS_VERSION'
                AMF_HEADERS_SHA256        = Get-VersionTableValue $VersionTable 'AMF_HEADERS_SHA256'
                # FFmpeg's static software codecs (Build-FfmpegCodecs.ps1, amd64).
                DAV1D_VERSION             = Get-VersionTableValue $VersionTable 'DAV1D_VERSION'
                DAV1D_SHA256              = Get-VersionTableValue $VersionTable 'DAV1D_SHA256'
                X264_MESON_BRANCH         = Get-VersionTableValue $VersionTable 'X264_MESON_BRANCH'
                X264_MESON_COMMIT         = Get-VersionTableValue $VersionTable 'X264_MESON_COMMIT'
                X265_VERSION              = Get-VersionTableValue $VersionTable 'X265_VERSION'
                X265_SHA256               = Get-VersionTableValue $VersionTable 'X265_SHA256'
                CUDA_ARCHITECTURES        = Get-VersionTableValue $VersionTable 'CUDA_ARCHITECTURES'
                # build-opencv resolves the CPython it builds bindings against.
                PYTHON_VERSION            = Get-VersionTableValue $VersionTable 'PYTHON_VERSION'
            }
        }
        'media-litert' {
            return @{
                LITERT_VERSION    = Get-VersionTableValue $VersionTable 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-VersionTableValue $VersionTable 'LITERT_LM_VERSION'
                # Host protoc must match litert-lm's protobuf runtime, or its headers #error on the gencode.
                PROTOC_VERSION    = Get-VersionTableValue $VersionTable 'PROTOC_VERSION'
                # Bazel needs a JRE; litert-lm resolves it from this pin.
                JRE_VERSION       = Get-VersionTableValue $VersionTable 'JRE_VERSION'
                # This branch mounts windows/qnn-sdk too; without the pin the SDK is extracted unverified.
                QNN_SDK_ZIP_SHA256 = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
                # rocm lane's LiteRT-LM GPU payload pins (Build-LitertLmBazel.ps1); unused on cpu/nvidia.
                LITERT_LM_WEBGPU_ACCELERATOR_SHA256 = Get-VersionTableValue $VersionTable 'LITERT_LM_WEBGPU_ACCELERATOR_SHA256'
                LITERT_LM_WEBGPU_SAMPLER_SHA256     = Get-VersionTableValue $VersionTable 'LITERT_LM_WEBGPU_SAMPLER_SHA256'
                LITERT_LM_WEBGPU_DAWN_SHA256        = Get-VersionTableValue $VersionTable 'LITERT_LM_WEBGPU_DAWN_SHA256'
                LITERT_LM_DXC_ZIP_SHA256            = Get-VersionTableValue $VersionTable 'LITERT_LM_DXC_ZIP_SHA256'
                # Build-LitertLmBazel.ps1's tools, refused unless their SHA256 matches (hub #185).
                LITERT_LM_BAZEL_WINDOWS_VERSION       = Get-VersionTableValue $VersionTable 'LITERT_LM_BAZEL_WINDOWS_VERSION'
                LITERT_LM_BAZEL_WINDOWS_AMD64_SHA256  = Get-VersionTableValue $VersionTable 'LITERT_LM_BAZEL_WINDOWS_AMD64_SHA256'
                TEMURIN_JDK_WINDOWS_VERSION         = Get-VersionTableValue $VersionTable 'TEMURIN_JDK_WINDOWS_VERSION'
                TEMURIN_JDK_WINDOWS_X64_SHA256      = Get-VersionTableValue $VersionTable 'TEMURIN_JDK_WINDOWS_X64_SHA256'
                GIT_LFS_WINDOWS_VERSION             = Get-VersionTableValue $VersionTable 'GIT_LFS_WINDOWS_VERSION'
                GIT_LFS_WINDOWS_AMD64_SHA256        = Get-VersionTableValue $VersionTable 'GIT_LFS_WINDOWS_AMD64_SHA256'
                # Build-LitertWheelBazel.ps1: the ai-edge-litert wheel for the pinned Python (CON91).
                LITERT_WINDOWS_SOURCE_COMMIT             = Get-VersionTableValue $VersionTable 'LITERT_WINDOWS_SOURCE_COMMIT'
                LITERT_BAZEL_WINDOWS_VERSION             = Get-VersionTableValue $VersionTable 'LITERT_BAZEL_WINDOWS_VERSION'
                LITERT_BAZEL_WINDOWS_AMD64_SHA256        = Get-VersionTableValue $VersionTable 'LITERT_BAZEL_WINDOWS_AMD64_SHA256'
                LITERT_WINDOWS_ACCELERATOR_WHEEL_URL     = Get-VersionTableValue $VersionTable 'LITERT_WINDOWS_ACCELERATOR_WHEEL_URL'
                LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256  = Get-VersionTableValue $VersionTable 'LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256'
                LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256 = Get-VersionTableValue $VersionTable 'LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256'
            }
        }
        'media-tvm' {
            return @{
                TVM_REF      = Get-VersionTableValue $VersionTable 'TVM_REF'
                IREE_VERSION = Get-VersionTableValue $VersionTable 'IREE_VERSION'
                # tvm-ffi's Cython; media-core installs the same one, as the fan-in refuses two versions.
                PY_CYTHON_VERSION = Get-VersionTableValue $VersionTable 'PY_CYTHON_VERSION'
                # This branch mounts windows/qnn-sdk too; without the pin the SDK is extracted unverified.
                QNN_SDK_ZIP_SHA256 = Get-VersionTableValue $VersionTable 'QNN_SDK_ZIP_SHA256'
                # rocm lane: IREE's device-bitcode download pin (Build-IreeFromSource.ps1); unused on cpu/nvidia.
                IREE_ROCM_DEVICE_BC_SHA256 = Get-VersionTableValue $VersionTable 'IREE_ROCM_DEVICE_BC_SHA256'
            }
        }
        'rocm-migraphx' {
            # Not a media branch (Dockerfile.rocm-migraphx); Rocm.Migraphx.Tests.ps1 holds ARG parity.
            $keys = @('MIGRAPHX_VERSION', 'ROCM_WINDOWS_GFX_FAMILY') +
                @($VersionTable.Keys | Where-Object { $_ -match '^(MIGRAPHX_WINDOWS|ORT_AMDGPU_EP)_' } | Sort-Object)
            $out = @{}
            foreach ($k in $keys) { $out[$k] = Get-VersionTableValue $VersionTable $k }
            return $out
        }
    }
}

function Get-MediaMergeVersionArg {
    param([Parameter(Mandatory)][hashtable]$VersionTable)
    # No merge ARG exists for these; forwarding them only warns and pollutes the merge stage's cache key.
    $branchOnly = @(
        'NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES',
        'AMF_HEADERS_VERSION', 'AMF_HEADERS_SHA256',   # media-core: FFmpeg AMF headers
        'DAV1D_VERSION', 'DAV1D_SHA256', 'X264_MESON_BRANCH', 'X264_MESON_COMMIT',
        'X265_VERSION', 'X265_SHA256',        # media-core: FFmpeg's static software codecs
        'PYTHON_VERSION', 'OPENCV_VERSION',   # media-core: OpenCV bindings target
        'PY_CYTHON_VERSION',                  # media-core + media-tvm: the Cython both branches install
        'QNN_SDK_ZIP_SHA256',                 # QAIRT zip pin (#121/#154): every stage that mounts windows/qnn-sdk
        'PROTOC_VERSION', 'JRE_VERSION',      # media-litert: litert-lm toolchain pins
        # media-litert: the rocm lane's LiteRT-LM GPU payload pins, checked in-branch only.
        'LITERT_LM_WEBGPU_ACCELERATOR_SHA256', 'LITERT_LM_WEBGPU_SAMPLER_SHA256',
        'LITERT_LM_WEBGPU_DAWN_SHA256', 'LITERT_LM_DXC_ZIP_SHA256',
        # media-litert: the bazel tool pins (hub #185).
        'LITERT_LM_BAZEL_WINDOWS_VERSION', 'LITERT_LM_BAZEL_WINDOWS_AMD64_SHA256', 'TEMURIN_JDK_WINDOWS_VERSION',
        'TEMURIN_JDK_WINDOWS_X64_SHA256', 'GIT_LFS_WINDOWS_VERSION', 'GIT_LFS_WINDOWS_AMD64_SHA256',
        # media-litert: the ai-edge-litert wheel's source, bazel and accelerator pins (CON91).
        'LITERT_WINDOWS_SOURCE_COMMIT', 'LITERT_BAZEL_WINDOWS_VERSION', 'LITERT_BAZEL_WINDOWS_AMD64_SHA256',
        'LITERT_WINDOWS_ACCELERATOR_WHEEL_URL', 'LITERT_WINDOWS_ACCELERATOR_WHEEL_SHA256', 'LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256',
        'IREE_ROCM_DEVICE_BC_SHA256'          # media-tvm: IREE rocm target's device-bitcode pin
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

function Get-WindowsVersionsEnvLine {
    <#
    .SYNOPSIS
        The KEY=VALUE lines of -VersionsEnv the Windows chain bakes: every key but the Linux-only ones nothing under windows\ names.
    .DESCRIPTION
        A key goes only when it matches -LinuxOnlyPattern, has no WINDOWS in its name, and no file of -Corpus names it; any
        doubt keeps it, so a missed Linux key costs a rebuild, never a Windows build. Comments go too, in source order (CON87).
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$VersionsEnv,
        [Parameter(Mandatory)][string[]]$Corpus,
        [string]$LinuxOnlyPattern = $script:LinuxOnlyVersionKeyPattern
    )
    $text = ($Corpus | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
    $named = { param([string]$Key) $text -match ('(?<![A-Z0-9_])' + [regex]::Escape($Key) + '(?![A-Z0-9_])') }
    $kept = foreach ($line in [IO.File]::ReadAllLines($VersionsEnv)) {
        $key = [regex]::Match($line, '^[A-Z][A-Z0-9_]*(?==)').Value
        if ($key -and ($key -notmatch $LinuxOnlyPattern -or $key -match 'WINDOWS' -or (& $named $key))) { $line }
    }
    return [string[]]@($kept)
}

# Keys only the Linux lanes read; the guard in Get-WindowsVersionsEnvLine keeps any of them windows\ names.
$script:LinuxOnlyVersionKeyPattern = '^(UBUNTU_|ANDROID_|DEEPSTREAM_|CHROME|APPIMAGETOOL_|FLATPAK_|TAPPAS_|HAILO_(LIBZMQ|CPPZMQ)_|OLLAMA_|' +
    'WASM_PACK_|FLUTTER_SDK_|GSTREAMER_ANDROID_|CUDA_KEYRING_|ROCM_GPG_|PANDOC_|NODE_|SQLITE3_WASM_|LIBCAMERA_|ARMNN_|ACL_|' +
    'OPENVINO_|TENSORFLOW_C_|MEDIAPIPE_|LITERTJS_|SCCACHE_LINUX_|CARGO_(AUDIT|DENY|TARPAULIN)_|FAST_UBUNTU_MIRROR|' +
    'CROSS_DEFAULT_ARCHES$|GCC_VERSION$|JDK_PACKAGE$|RUST_NIGHTLY_TOOLCHAIN$|PYTHON_TGZ_SHA256$|RUSTUP_INIT_SHA256$|UV_INSTALL_SH_SHA256$)|' +
    'RISCV64|_LINUX_|_AARCH64_'

function Get-WindowsVersionsEnvCorpus {
    # windows\ and every linux\ file a Windows Dockerfile mounts or copies; the tests never run in the chain, and naming a Linux key there would keep it.
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $windowsRoot = Join-Path $RepoRoot 'windows'
    $skip = '^' + [regex]::Escape($windowsRoot) + '\\(generated|scripts\\tests)\\'
    $corpus = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem -LiteralPath $windowsRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.py', '*.cmd', '*.txt', '*.json', '*.wxs', 'Dockerfile*' |
        Where-Object { $_.FullName -notmatch $skip } | ForEach-Object { [void]$corpus.Add($_.FullName) }
    $dockerfileText = (Get-ChildItem -LiteralPath $windowsRoot -File -Filter 'Dockerfile*' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    [regex]::Matches($dockerfileText, '(?<![\w.])linux[\\/][\w./\\-]+\.(?:py|txt|sh|ps1)') |
        ForEach-Object { Join-Path $RepoRoot ($_.Value -replace '/', '\') } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object { [void]$corpus.Add($_) }
    return [string[]]@($corpus)
}

function Write-WindowsVersionsEnv {
    <#
    .SYNOPSIS
        Writes windows\generated\versions.env, the filtered versions.env every Windows Dockerfile bakes or mounts; returns its path.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $source = Join-Path $RepoRoot 'linux\scripts\01-core\versions.env'
    $generated = Join-Path $RepoRoot 'windows\generated'
    $lines = @(Get-WindowsVersionsEnvLine -VersionsEnv $source -Corpus (Get-WindowsVersionsEnvCorpus -RepoRoot $RepoRoot))
    $null = New-Item -ItemType Directory -Force -Path $generated
    $out = Join-Path $generated 'versions.env'
    $header = '# Generated by windows\Build-Buildkit.ps1 from linux\scripts\01-core\versions.env, without its Linux-only keys (CON87).'
    [IO.File]::WriteAllText($out, (@($header) + $lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $total = @([IO.File]::ReadAllLines($source) | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*=' }).Count
    Write-Host ("versions.env for the Windows chain: {0} of {1} key(s), {2} Linux-only left out -> {3}" -f $lines.Count, $total, ($total - $lines.Count), $out)
    return $out
}

function Get-BuildVcsRef {
    try { $r = (& git rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -ne 0) { return '' } else { return $r } }
    catch { return '' }
}

function Resolve-GitRefCommit {
    <#
    .SYNOPSIS
        The commit ls-remote output names for $Ref: a branch beats a same-named tag, tags peel; '' when none.
    #>
    param([string[]]$LsRemoteOutput, [string]$Ref)
    if (-not $LsRemoteOutput -or -not $Ref) { return '' }
    $byRef = @{}
    foreach ($line in @($LsRemoteOutput | Where-Object { $_ -match "^[0-9a-f]{40}`t" })) {
        $sha, $name = $line -split "`t", 2
        $byRef[$name.Trim()] = $sha
    }
    foreach ($name in "refs/heads/$Ref", "refs/tags/$Ref^{}", "refs/tags/$Ref") {
        if ($byRef.ContainsKey($name)) { return $byRef[$name] }
    }
    return ''
}

function Resolve-TorchAppRef {
    # APP_REF resolved to its current commit, so the layer moves exactly when the app does: docs/windows-builds.md § The torch step
    param(
        [Parameter(Mandatory)][hashtable]$VersionTable,
        [switch]$LatestApp
    )
    $url = 'https://github.com/Kataglyphis/OrchestrANT.git'
    $ref = Get-VersionTableValue $VersionTable 'APP_REF'
    if ($LatestApp) {
        try {
            $tagRaw = & git ls-remote --tags $url 2>$null
            if ($LASTEXITCODE -eq 0 -and $tagRaw) {
                $latest = Resolve-LatestVersionTag -LsRemoteOutput @($tagRaw)
                if (-not [string]::IsNullOrWhiteSpace($latest)) { $ref = $latest }
            }
        } catch {
            Write-Verbose "ls-remote tag resolution failed, using pinned APP_REF: $($_.Exception.Message)"
        }
        Write-Host "-LatestApp: resolved OrchestrANT ref: $ref (versions.env pin: $(Get-VersionTableValue $VersionTable 'APP_REF'))"
    }
    if ($ref -match '^[0-9a-f]{40}$') { return $ref }
    $raw = @(& git ls-remote $url "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}" 2>$null)
    $sha = if ($LASTEXITCODE -eq 0) { Resolve-GitRefCommit -LsRemoteOutput $raw -Ref $ref } else { '' }
    if (-not $sha) { throw "APP_REF '$ref' resolves to no commit of $url (no such branch or tag, or the remote is unreachable)" }
    Write-Host "OrchestrANT ref: $ref -> $sha"
    return $sha
}

function Assert-SccacheEndpoint {
    # Compile stages require the remote cache unless -NoSccache is a deliberate choice.
    param(
        [Parameter(Mandatory)][string[]]$Stages,
        [string]$SccacheEndpoint = '',
        [switch]$NoSccache
    )
    # Only media: the toolchain stage has no sccache wiring to gate on.
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

function Get-BkSccacheConfig {
    <#
    .SYNOPSIS
        sccache's build args and buildctl secrets: level 0 the host's WebDAV, level 1 an optional S3 bucket shared by every host.
    .DESCRIPTION
        The S3 level joins only with its endpoint, bucket and both key halves in the process environment. The key reaches
        buildctl as env-sourced secrets, never as an argument or a build arg, so no layer or image history carries it.
        docs/windows-build-resources.md § Two cache levels
    .OUTPUTS
        @{ BuildArgs; Secrets; Levels; Note } - Note says why a configured S3 level was left out.
    #>
    param(
        [string]$WebdavEndpoint = '',
        [string]$S3Endpoint = '',
        [string]$S3Bucket = '',
        [string]$S3Region = '',
        [string]$KeyIdVariable = 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID',
        [string]$SecretVariable = 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY'
    )
    $config = @{ BuildArgs = @{ SCCACHE_WEBDAV_ENDPOINT = $WebdavEndpoint }; Secrets = @(); Levels = @(); Note = '' }
    if ($WebdavEndpoint) { $config.Levels += "webdav $WebdavEndpoint" }
    $s3 = Get-SccacheS3Level -WebdavEndpoint $WebdavEndpoint -S3Endpoint $S3Endpoint -S3Bucket $S3Bucket -S3Region $S3Region `
        -KeyIdVariable $KeyIdVariable -SecretVariable $SecretVariable
    $config.Note = $s3.Note
    if ($s3.Settings.Count -eq 0) { return $config }
    foreach ($name in $s3.Settings.Keys) { $config.BuildArgs[$name] = $s3.Settings[$name] }
    $config.Secrets = @('--secret', "id=sccache_s3_key_id,env=$KeyIdVariable", '--secret', "id=sccache_s3_secret,env=$SecretVariable")
    $config.Levels += "s3 $S3Endpoint bucket $S3Bucket"
    return $config
}

function Assert-DiskHeadroom {
    # Every drive the build touches, context included: docs/failure-modes.md § `ExportLayer 0x3`, spawn flakes, `ExportLayer 0x70` — disk exhaustion in costume
    param(
        # Extra drive letters; C (the layer stores) is always checked.
        [string[]]$Drive = @('C'),
        # Clear of the ~25 GB band where hcsshim misbehaves, with room for one heavy layer's scratch.
        [int]$MinFreeGb = 40,
        [switch]$Force
    )
    $reclaim = 'Reclaim first (docs/windows-builds.md § Store GC): ' +
        'buildctl prune --free-storage <MB ABOVE total disk size, it is a minimum-free TARGET>; ' +
        'then admin `nerdctl --namespace buildkit rmi` for superseded bk-* stage tags. ' +
        'For a VHDX-backed checkout the lever is a different one entirely: ' +
        'windows\scripts\host\Optimize-HostVhdx.ps1 / Update-HostVhdx.ps1.'
    # Accepts 'C', 'C:', 'C:\' and full paths alike.
    $letters = [System.Collections.Generic.List[string]]::new()
    foreach ($d in (@('C') + $Drive)) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $letter = ($d.Trim() -replace '^([A-Za-z]).*$', '$1').ToUpperInvariant()
        if ($letter -and -not $letters.Contains($letter)) { $letters.Add($letter) }
    }
    $short = @()
    foreach ($letter in $letters) {
        $psDrive = Get-PSDrive $letter -ErrorAction SilentlyContinue
        # A missing drive is not a failure: another machine may keep the repo on C:.
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
    # Host state, not repo state: it describes this machine's Stevedore install.
    param([string]$StatePath = '')
    if ($StatePath) { return $StatePath }
    if ($env:KATAGLYPHIS_SHIM_STATE) { return $env:KATAGLYPHIS_SHIM_STATE }
    $root = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return (Join-Path $root 'kataglyphis\shim-patch.json')
}

function Write-ShimPatchState {
    # The hash Assert-ShimPatch checks the live binary against on every BK build.
    param(
        [Parameter(Mandatory)][string]$ShimPath,
        [string]$StatePath = '',
        # Free-text: which patch variant went in ('local-45min', 'upstream-env', …).
        [string]$Variant = '',
        # The preserved stock binary, so the gate can say "reverted to stock".
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
    # Works around microsoft/hcsshim#2855, whose patch every Stevedore update reverts: hash first, size heuristic as fallback.
    param(
        [string]$ShimPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
        # Sizes measured on the reference host; extend as hcsshim moves.
        [long[]]$PatchedSize = @(25332736, 25329664),
        [long[]]$StockSize = @(23279616),
        [string]$StatePath = '',
        # Injectable so the not-found path is testable on a host with a real shim.
        [string[]]$AlternateRoot = @(
            "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",
            'D:\Stevedore\bin\containerd-shim-runhcs-v1.exe'
        ),
        [switch]$Force
    )
    # Defined BEFORE the not-found branch below, which quotes it in its throw.
    $advice = 'Re-install it before building: pwsh -File windows\scripts\host\Publish-ShimPatch.ps1 ' +
        '-ShimPath <your build> (and -ServiceEnvironment for an upstream-patch build, which needs ' +
        'CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT set or it silently keeps the 30s default). ' +
        'Recipe + patch: windows/upstream/hcsshim-teardown-timeout/.'
    # Fail closed: "could not check" must not read as "fine".
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
    # A state file for a different install path describes another binary.
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
        'windows\scripts\host\Publish-ShimPatch.ps1 (it writes ' + $statePath + ' on a successful swap).'
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
    # Measured floors: see docs/windows-build-lanes.md § Driver preflight gates and isolation policy
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    # Most specific first, so a sub-stage is not caught by the generic media rule.
    switch -Regex ($Label) {
        'nvidia|sdk'                { return 60 }   # CUDA ~36 GB + export headroom
        'Dockerfile\.rocm$'         { return 45 }   # rocm sdk: 2.3 GB tarball + 9.56 GB tree at peak, + export
        'media-core-built-onnx'     { return 55 }   # the 25 GB image, the one that really needs room
        'media-core-built-opencv'   { return 45 }
        'media-core-built-ffmpeg'   { return 40 }
        'media-core-built$'         { return 40 }   # BK: the GenAI tail solve only
        'media-litert'              { return 45 }
        'media-tvm'                 { return 40 }
        'media-merge|merge'         { return 45 }   # mounts three branch trees at once
        # Classic lane: one run+commit does the whole chain, so it takes the heaviest floor.
        'media-core|media-builder'  { return 55 }
        'toolchain'                 { return 40 }
        default                     { return 40 }
    }
}

function Assert-StageDiskHeadroom {
    # A chain can drain the disk mid-stage, where killing the solve poisons a snapshot; refusing entry costs nothing.
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
        # Silence would read as "plenty of space" in the build log.
        Write-Warning "[$Label] disk headroom NOT checked: drive '$Drive' has no readable free space (network drive, or wrong letter?)."
        Write-DriverRecord "[$Label] disk headroom NOT checked: drive '$Drive' has no readable free space"
        return
    }
    $freeGb = [math]::Round($psDrive.Free / 1GB, 1)
    if ($freeGb -ge $FloorGb) {
        Write-Host "[$Label] disk OK: ${freeGb} GB free (stage floor ${FloorGb} GB)" -ForegroundColor DarkGray
        Write-DriverRecord "[$Label] disk OK: ${freeGb} GB free on ${Drive}: (stage floor ${FloorGb} GB)"
        return
    }
    $msg = ("[$Label] C: has ${freeGb} GB free, below the ${FloorGb} GB this stage needs. Entering it anyway walks " +
        'into the band where hcsshim fails dishonestly, and the only escape (killing the solve) poisons a snapshot. ' +
        'Reclaim first — docs/windows-builds.md § Store GC: admin `nerdctl --namespace buildkit rmi` on superseded ' +
        'bk-* stage tags, then `buildctl prune --free-storage <MB above disk size>`.')
    if ($Force) {
        Write-Warning "$msg Continuing because the host-check override was passed."
        Write-DriverRecord "[$Label] disk below floor: ${freeGb} GB free, floor ${FloorGb} GB; continued under the host-check override"
        return
    }
    Write-DriverRecord "[$Label] REFUSED: ${freeGb} GB free on ${Drive}:, below the ${FloorGb} GB floor"
    throw "REFUSING to start: $msg"
}

function Assert-BuildkitdStepLogEnv {
    # Without BUILDKIT_STEP_LOG_MAX_SIZE=-1 step logs clip at 2MiB and bury the causal error; a Stevedore repair can wipe it.
    param(
        [string]$ServiceName = 'buildkitd',
        # Injectable for tests: pass the service's Environment multi-string.
        [object[]]$EnvironmentOverride = $null,
        [switch]$Force
    )
    $envStrings = $EnvironmentOverride
    if ($null -eq $envStrings) {
        $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        # No service means not this host's lane; the driver's buildctl resolution reports that.
        if (-not (Test-Path $svcKey)) { return }
        # Guarded: under StrictMode .Environment throws on exactly the wiped-env case this gate exists for.
        $props = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
        $envStrings = if ($props -and $props.PSObject.Properties.Name -contains 'Environment') { $props.Environment } else { @() }
    }
    if ((@($envStrings) -join "`n") -match 'BUILDKIT_STEP_LOG_MAX_SIZE\s*=\s*-1') { return }
    $msg = ("buildkitd service env is missing BUILDKIT_STEP_LOG_MAX_SIZE=-1 - step logs will clip at 2MiB. " +
        "Fix (elevated, between chain runs): windows\scripts\host\Install-NewHost.ps1, or " +
        "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment " +
        "-Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1') ; Restart-Service buildkitd.")
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg Pass -SkipHostChecks to override."
}

# The one RDNA4 hazard pattern (RX 9xxx, AI PRO R9700) for gate, toggle and A/B; extend as SKUs appear.
$script:Rdna4HazardPattern = 'Radeon\s*(\(TM\)\s*)?(AI\s+PRO\s+)?(RX\s+|R)?9\d{3}'

function Get-Rdna4HazardDevice {
    # $Devices and -Pattern are test seams; -ActiveOnly keeps the enabled ones.
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
    # Elevated callers only; the post-state is verified because a swallowed failure strands the host on the iGPU.
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
    # Works around docker/for-win#14977: see docs/failure-modes.md § `hcsshim::ActivateLayer 0x20` on an AMD Radeon host
    param(
        # Injectable for tests. Default: live display-class PnP devices.
        [object[]]$Devices = $null,
        # Test-only override of the hazard pattern.
        [string]$HazardPattern = '',
        [switch]$Force
    )
    $hazards = @(Get-Rdna4HazardDevice -Devices $Devices -Pattern $HazardPattern)
    if ($hazards.Count -eq 0) { return }

    $active = @($hazards | Where-Object { $_.Status -eq 'OK' })
    if ($active.Count -eq 0) {
        # -f binds tighter than +, so the concat stays parenthesized.
        Write-Host (("RDNA4 gate: {0} present but DISABLED - RUN-layer finalize is safe; re-enable after the " +
            "build with windows\scripts\host\Set-Rdna4Gpu.ps1 (elevated).") -f $hazards[0].FriendlyName) -ForegroundColor Cyan
        return
    }
    $msg = (("'{0}' is ENABLED. On this host family an active RDNA4 dGPU makes EVERY process-isolated RUN-layer " +
        "finalize fail with hcsshim::ActivateLayer 0x20 (docker/for-win#14977; A/B-proven here 2026-08-10) - the " +
        "chain would die on its first RUN commit. Disable it for the build window (display falls back to the " +
        "iGPU): elevated pwsh -File windows\scripts\host\Set-Rdna4Gpu.ps1 -Disable, build, then re-enable with " +
        "the same script (default action). Verify first with Test-BuildCopy.ps1 -Heavy.") -f $active[0].FriendlyName)
    if ($Force) { Write-Warning "$msg Continuing because the host-check override was passed."; return }
    throw "REFUSING to start: $msg Pass -SkipHostChecks to override."
}

function Get-MediaMemoryBudget {
    # Host RAM minus the reserve, at least 8 GB; an explicit request wins.
    param(
        [int]$RequestedGb = 0,
        [int]$HostReserveGb = 22
    )
    if ($RequestedGb -gt 0) { return $RequestedGb }
    $usableGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    return [math]::Max(8, $usableGb - $HostReserveGb)
}

function Get-ByteRangeSplit {
    # Inclusive byte ranges covering 0..Length-1 exactly, in at most Parts pieces.
    param(
        [Parameter(Mandatory)][long]$Length,
        [Parameter(Mandatory)][ValidateRange(1, 256)][int]$Parts
    )
    if ($Length -le 0) { throw "Get-ByteRangeSplit: length must be positive, got $Length" }
    $size = [long][math]::Ceiling($Length / [double]$Parts)
    for ($from = [long]0; $from -lt $Length; $from += $size) {
        [pscustomobject]@{ From = $from; To = [long][math]::Min($Length, $from + $size) - 1 }
    }
}

function Save-ParallelRangeDownload {
    # slproweb throttles each connection to ~20 KB/s, so a 251 MB installer needs many ranges at once.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [ValidateRange(1, 64)][int]$Parts = 32
    )
    if ((Test-Path -LiteralPath $Destination) -and ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ieq $ExpectedSha256)) { return }
    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    $head = @(& $curlExe -sfIL --max-time 60 $Url)
    if ($LASTEXITCODE -ne 0) { throw "HEAD $Url failed (curl exit $LASTEXITCODE)" }
    # The last Content-Length: -L prints the headers of every redirect hop.
    $lengths = @($head | Select-String -Pattern '^Content-Length:\s*(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($lengths.Count -eq 0) { throw "HEAD $Url returned no Content-Length" }
    $ranges = @(Get-ByteRangeSplit -Length ([long]$lengths[-1]) -Parts $Parts)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)
    $jobs = for ($i = 0; $i -lt $ranges.Count; $i++) {
        $part = "$Destination.part$i"
        # --speed-time turns a stalled range into a retry rather than an hours-long wait.
        $proc = Start-Process -FilePath $curlExe -NoNewWindow -PassThru -ArgumentList @(
            '-sfL', '--retry', '8', '--retry-delay', '5', '--retry-all-errors', '--speed-limit', '1024', '--speed-time', '120',
            '-r', "$($ranges[$i].From)-$($ranges[$i].To)", '-o', $part, $Url)
        $null = $proc.Handle   # without a cached handle, ExitCode reads empty once the process is gone
        [pscustomobject]@{ Process = $proc; Part = $part; Size = $ranges[$i].To - $ranges[$i].From + 1 }
    }
    $jobs.Process | Wait-Process
    $bad = @($jobs | Where-Object {
            $_.Process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $_.Part) -or (Get-Item -LiteralPath $_.Part).Length -ne $_.Size })
    if ($bad.Count -gt 0) { throw "$($bad.Count) of $($jobs.Count) range(s) of $Url failed or came back short" }
    $out = [System.IO.File]::Create($Destination)
    try {
        foreach ($job in $jobs) {
            $in = [System.IO.File]::OpenRead($job.Part)
            try { $in.CopyTo($out) } finally { $in.Dispose() }
        }
    } finally { $out.Dispose() }
    $jobs.Part | Remove-Item -Force
    $got = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($got -ine $ExpectedSha256) { throw "sha256 mismatch for ${Url}: got $got, expected $ExpectedSha256" }
}

function Publish-PreseedFile {
    # Puts one host-side download on the webdav under preseed/, unless it is there already; the caller decides fail-open.
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LocalDir,
        # Gets the local path and must leave the verified file there.
        [Parameter(Mandatory)][scriptblock]$Fetch
    )
    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    $onDav = "$Endpoint/preseed/$Name"
    & $curlExe -sfI $onDav *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "preseed: $Name already on the webdav"; return }
    Write-Host "preseed: downloading $Name host-side..."
    $null = New-Item -ItemType Directory -Force -Path $LocalDir
    $local = Join-Path $LocalDir $Name
    & $Fetch $local
    & $curlExe -sf --retry 3 --retry-delay 5 --retry-all-errors -T $local $onDav
    if ($LASTEXITCODE -ne 0) { throw "webdav PUT of $Name failed (exit $LASTEXITCODE)" }
    Write-Host "preseed: $Name staged at $onDav"
}

Export-ModuleMember -Function Initialize-BuildDriverContext, Write-DriverRecord, Get-BkSccacheConfig,
    Test-TransientDockerFailure, Invoke-TransientCooldown,
    Get-VersionTableValue, Get-MediaBranchVersionArg, Get-MediaMergeVersionArg,
    Get-WindowsVersionsEnvLine, Get-WindowsVersionsEnvCorpus, Write-WindowsVersionsEnv,
    Get-BuildVcsRef, Resolve-GitRefCommit, Resolve-TorchAppRef, Assert-SccacheEndpoint, Get-MediaMemoryBudget,
    Assert-DiskHeadroom, Assert-ShimPatch,
    Get-ShimPatchStatePath, Write-ShimPatchState,
    Get-StageDiskFloorGb, Assert-StageDiskHeadroom, Assert-NoActiveRdna4Gpu,
    Get-Rdna4HazardDevice, Set-Rdna4DeviceState, Assert-BuildkitdStepLogEnv,
    Get-ByteRangeSplit, Save-ParallelRangeDownload, Publish-PreseedFile
