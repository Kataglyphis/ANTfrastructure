# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# Container mounts are flat while the repo is scripts/<group>/, so shared assets sit here or one level up.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
# G2's gate: modules\ in the repo, a per-file mount under ortmods\ in the container (never the shared closure).
$ortGateModule = @('modules', 'ortmods') | ForEach-Object { Join-Path $scriptAssetRoot $_ 'WindowsOrtProvenance.Build.psm1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Import-Module ($ortGateModule ?? $(throw 'WindowsOrtProvenance.Build.psm1 (the G2 ORT gate) is not mounted')) -DisableNameChecking

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$FfmpegVersion = Get-SourceBuildVersion -Value $FfmpegVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'n9.0.2'
$prefix = Join-Path $InstallDir 'ffmpeg'
$ffmpegDir = Join-Path $prefix 'bin'

# The host is always amd64; raw inputs are printed because a silent amd64 fallback once showed only as "libonnxruntime not found".
Write-Host ("FFmpeg arch inputs: Process='{0}' Machine='{1}' -> resolved '{2}'" -f `
    [Environment]::GetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'Process'),
    [Environment]::GetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'Machine'),
    (Get-WindowsTargetArch))
$ffTargetArch = Get-WindowsTargetArch
$ffCross      = Test-WindowsCrossTarget -Arch $ffTargetArch
# On --cc, not --extra-cflags, wherever the compiler is named: configure's own probes must target the cross arch too.
$ffCcTargetFlag = if ($ffCross) { " --target=$(Get-ClangTargetTriple -Arch $ffTargetArch)" } else { '' }
if ($ffCross) { Write-Host "FFmpeg: CROSS build for $ffTargetArch on an $(Get-WindowsHostArch) host" }

# Every bash-facing path goes through this: a half-converted one sent make install into <git-root>\cruntimeffmpeg.
function ConvertTo-MsysPath([string]$Path) {
    return '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

# makedef lists each DLL's exports with llvm-nm, which must be the one beside the clang-cl make resolves.
function Get-FfmpegLlvmNm([string]$ClangClPath) {
    $nm = Join-Path (Split-Path -Parent $ClangClPath) 'llvm-nm.exe'
    if (-not (Test-Path -LiteralPath $nm -PathType Leaf)) {
        throw "FFmpeg: no llvm-nm.exe beside $ClangClPath; makedef needs the compiler's own to list exports."
    }
    return $nm
}

function Assert-FfmpegPkgConfig {
    # Catches .pc files that look fine but are not (empty Version, MSYS prefix); kept out of Common.psm1, whose edits re-key every media branch.
    param(
        [Parameter(Mandatory)][string]$PkgConfigDir,
        # Presence and form only; gst-libav's version floors are Assert-PkgConfigModule's.
        [string[]]$RequiredModule = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
    )
    if (-not (Test-Path $PkgConfigDir -PathType Container)) {
        throw ("FFmpeg install produced no pkgconfig directory at $PkgConfigDir. " +
            'Every pkg-config consumer (gst-libav above all) resolves FFmpeg through these files; ' +
            'without them the merge stage silently drops the plugin. Did `make install` run?')
    }
    $versions = [ordered]@{}
    foreach ($required in $RequiredModule) {
        $pcPath = Join-Path $PkgConfigDir "$required.pc"
        if (-not (Test-Path $pcPath)) {
            throw "FFmpeg install produced no $required.pc — consumers resolving it via pkg-config (gst-libav) cannot build."
        }
        $pcText = Get-Content $pcPath -Raw
        $version = ([regex]::Match($pcText, '(?m)^Version:\s*(.+)$')).Groups[1].Value.Trim()
        if ($version -notmatch '^\d+(\.\d+)+$') {
            throw ("$required.pc declares an unusable version '$version'. FFmpeg's configure found neither a VERSION " +
                'file nor git tags, so its version substitutions expanded to nothing. No consumer version constraint ' +
                "can match this — gst-libav would be silently skipped. Check the VERSION file written after extraction.")
        }
        if ($pcText -match '(?m)^prefix=/[a-z]/') {
            throw "$required.pc still carries an MSYS prefix; native Windows consumers cannot use its -I/-L flags."
        }
        $versions[$required] = $version
    }
    $summary = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-Host "FFmpeg .pc gate OK: $summary (real versions, Windows prefixes)"
    return $versions
}

function Remove-MakefileShowIncludes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StripWildcardInclude
    )
    if (-not (Test-Path $Path)) { return }
    $c = [System.IO.File]::ReadAllText($Path)
    $c = $c -replace '-showIncludes', ''
    # -options:strict is cl.exe-only: clang-cl reads it as -o, and once sccache reorders -Fo the object lands in an NTFS stream.
    $c = $c -replace '-options:strict\s*', ''
    # These awk pipelines parse MSVC -showIncludes; clang-cl emits GNU-style deps instead.
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    if ($StripWildcardInclude) { $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', '' }
    [System.IO.File]::WriteAllText($Path, $c)
}

# Every native amd64 lane gets AMF (header-only; amfrt64.dll loads from the driver), cross gets $null. See docs/windows-builds.md § ROCm layer
function Get-FfmpegAmfPlan {
    param(
        [Parameter(Mandatory)][hashtable]$GpuEnvironment,
        [bool]$IsCross = $false,
        [Parameter(Mandatory)][string]$SourceDir
    )
    if ($IsCross) {
        if ($GpuEnvironment.HasRocm) { throw 'GPU_TYPE=rocm on a cross build: the rocm lane is amd64-only, so this environment is mis-plumbed.' }
        return $null
    }
    $compat = Join-Path $SourceDir 'compat\amf'
    return @{ CompatDir = $compat; IncludeDir = (ConvertTo-MsysPath $compat); RocmRoot = $GpuEnvironment.RocmRoot; Rocm = [bool]$GpuEnvironment.HasRocm }
}

# rocm lane only: the base image's Vulkan SDK headers and glslc (vulkan-1.dll is dlopened at run time). docs/windows-rocm.md
function Get-FfmpegVulkanPlan {
    param(
        [AllowNull()][hashtable]$AmfPlan,
        [AllowEmptyString()][string]$VulkanSdk = ''
    )
    if (-not $AmfPlan -or -not $AmfPlan.Rocm) { return $null }
    if ([string]::IsNullOrWhiteSpace($VulkanSdk)) { throw 'rocm lane: VULKAN_SDK is not set (the base image installs the Vulkan SDK and exports it).' }
    $sdk = $VulkanSdk.TrimEnd('\', '/')
    # configure runs `$glslc_probe -v` unquoted, so a spaced path would split into two words.
    if ($sdk -match '\s') { throw "rocm lane: VULKAN_SDK '$sdk' contains whitespace; FFmpeg's glslc probe cannot run it." }
    foreach ($rel in 'Include\vulkan\vulkan.h', 'Include\spirv-headers\spirv.h', 'Bin\glslc.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $sdk $rel) -PathType Leaf)) { throw "rocm lane: no $rel under VULKAN_SDK=$sdk" }
    }
    return @{ SdkRoot = $sdk; IncludeDir = (ConvertTo-MsysPath (Join-Path $sdk 'Include')); Glslc = ((Join-Path $sdk 'Bin\glslc.exe') -replace '\\', '/') }
}

# Emits nothing without a plan, so the cpu/nvidia configure line stays byte-identical.
function Get-FfmpegRocmConfigureArg {
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$AmfPlan,
        [AllowNull()][hashtable]$VulkanPlan = $null
    )
    if (-not $AmfPlan) { return @() }
    if (-not (Test-Path (Join-Path $AmfPlan.CompatDir 'AMF\core\Version.h') -PathType Leaf)) {
        throw "no AMF headers under $($AmfPlan.CompatDir) -- Install-FfmpegAmfHeader must run before configure."
    }
    # Explicit, not autodetect: a missing header then dies in configure ("amf requested but not found").
    $rocmArgs = @('--enable-amf', "--extra-cflags=-I$($AmfPlan.IncludeDir)")
    # Explicit --glslc: configure would otherwise take the first glslc/glslang it meets on PATH.
    if ($VulkanPlan) { $rocmArgs += '--enable-vulkan', "--extra-cflags=-I$($VulkanPlan.IncludeDir)", "--glslc=$($VulkanPlan.Glslc)" }
    return $rocmArgs
}

# The configure symbols --enable-amf must turn on at n9.0.2; rocm-checks/FFmpeg.ps1 lists the same set.
function Get-FfmpegAmfConfigSymbol {
    return @('AMF',
        'H264_AMF_ENCODER', 'HEVC_AMF_ENCODER', 'AV1_AMF_ENCODER',
        'H264_AMF_DECODER', 'HEVC_AMF_DECODER', 'AV1_AMF_DECODER', 'VP9_AMF_DECODER',
        'VPP_AMF_FILTER', 'SR_AMF_FILTER', 'FRC_AMF_FILTER', 'AMF_CAPTURE_FILTER')
}

# Symbols ffbuild/config.mak leaves off (configure writes a disabled one as '!CONFIG_X=yes').
function Get-FfmpegAmfConfigGap {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ConfigMakText)
    foreach ($symbol in Get-FfmpegAmfConfigSymbol) {
        if ($ConfigMakText -notmatch "(?m)^CONFIG_$symbol=yes\r?$") { "CONFIG_$symbol" }
    }
}

# What --enable-vulkan turns on at n9.0.2; glslc-built components stand in for spirv_compiler, which no list names.
function Get-FfmpegVulkanConfigSymbol {
    $hwaccels = 'AV1', 'H264', 'HEVC', 'VP9', 'APV', 'DPX', 'FFV1', 'PRORES', 'PRORES_RAW'
    $encoders = 'H264', 'HEVC', 'AV1', 'FFV1', 'PRORES_KS'
    $filters = 'AVGBLUR', 'BLACKDETECT', 'BLEND', 'BWDIF', 'CHROMABER', 'COLOR', 'FLIP', 'GBLUR', 'HFLIP',
        'INTERLACE', 'NLMEANS', 'OVERLAY', 'SCALE', 'SCDET', 'TRANSPOSE', 'V360', 'VFLIP', 'XFADE'
    return @('CONFIG_VULKAN', 'CONFIG_VULKAN_1_4', 'HAVE_SPIRV_HEADERS_SPIRV_H') +
        @($hwaccels | ForEach-Object { "CONFIG_${_}_VULKAN_HWACCEL" }) +
        @($encoders | ForEach-Object { "CONFIG_${_}_VULKAN_ENCODER" }) +
        @($filters | ForEach-Object { "CONFIG_${_}_VULKAN_FILTER" })
}

# Symbols config.mak leaves off, plus a GLSLC line that is not the plan's compiler.
function Get-FfmpegVulkanConfigGap {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigMakText,
        [Parameter(Mandatory)][string]$Glslc
    )
    foreach ($symbol in Get-FfmpegVulkanConfigSymbol) {
        if ($ConfigMakText -notmatch "(?m)^$symbol=yes\r?$") { $symbol }
    }
    if ($ConfigMakText -notmatch "(?m)^GLSLC=$([regex]::Escape($Glslc))\r?$") { "GLSLC=$Glslc" }
}

# config.mak lines naming the ROCm tree in any spelling (C:\, C:/, /c/): FFmpeg needs nothing from TheRock.
function Get-FfmpegRocmLeak {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigMakText,
        # Empty on the cpu/nvidia lanes, whose AMF plan carries no ROCm root: nothing can leak.
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RocmRoot
    )
    if ([string]::IsNullOrWhiteSpace($RocmRoot)) { return }
    $fwd = $RocmRoot.TrimEnd('\', '/') -replace '\\', '/'
    $forms = @($fwd, ($fwd -replace '/', '\'), ('/' + $fwd.Substring(0, 1) + $fwd.Substring(2)))
    $tree = '(?i)(?:' + (($forms | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?=[\\/\s;''"]|$)'
    foreach ($line in $ConfigMakText -split '\r?\n') { if ($line -match $tree) { $line } }
}

# Replaces <Destination>\AMF with <IncludeRoot>\AMF; refuses a tree without core\Version.h.
function Copy-FfmpegAmfHeaderTree {
    param(
        [Parameter(Mandatory)][string]$IncludeRoot,
        [Parameter(Mandatory)][string]$Destination
    )
    $source = Join-Path $IncludeRoot 'AMF'
    if (-not (Test-Path (Join-Path $source 'core\Version.h') -PathType Leaf)) {
        throw "no AMF\core\Version.h under $IncludeRoot (did the AMF header asset change its layout?)"
    }
    $target = Join-Path $Destination 'AMF'
    Reset-SourceBuildDirectory -Path $target
    $null = [System.IO.Directory]::CreateDirectory($target)
    # The CONTENTS: copying the folder onto an existing one would nest AMF\AMF.
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    return $target
}

# configure finds ffnvcodec and the codecs via pkg-config, absent from the media image; scoop's reads Windows paths.
function Add-FfmpegPkgConfigDir {
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing pkg-config via scoop...'
        & scoop install main/pkg-config 2>&1 | Out-Null
    }
    $env:PKG_CONFIG_PATH = $Dir + $(if ($env:PKG_CONFIG_PATH) { ";$env:PKG_CONFIG_PATH" } else { '' })
}

# Fetches ONLY the release's header asset (SHA256-pinned; never the 1.2 GB repo) into <Destination>\AMF.
function Install-FfmpegAmfHeader {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sha256,
        [Parameter(Mandatory)][string]$Destination,
        [string]$WorkDir = 'C:\temp\amf-headers',
        [string]$BaseUrl = 'https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download',
        [int]$MaxAttempts = 4
    )
    if ([string]::IsNullOrWhiteSpace($Version) -or [string]::IsNullOrWhiteSpace($Sha256)) {
        throw 'AMF_HEADERS_VERSION/AMF_HEADERS_SHA256 are not set (build arg not plumbed?) -- refusing an unverified AMF header download'
    }
    Reset-SourceBuildDirectory -Path $WorkDir
    $archive = Join-Path $WorkDir "AMF-headers-$Version.tar.gz"
    Invoke-DownloadWithRetry -Url "$BaseUrl/$Version/AMF-headers-$Version.tar.gz" -DestinationPath $archive `
        -ExpectedSha256 $Sha256 -Description "AMF headers $Version" -MaxAttempts $MaxAttempts
    $root = Expand-SourceTarball -Archive $archive -Destination (Join-Path $WorkDir 'extract')
    $headerDir = Copy-FfmpegAmfHeaderTree -IncludeRoot $root -Destination $Destination
    Reset-SourceBuildDirectory -Path $WorkDir
    return $headerDir
}

Write-Host "=== FFmpeg source build ($FfmpegVersion, clang-cl+lld-link default; FFMPEG_TOOLCHAIN=msvc to override) ==="

if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    # Verify on re-entry: a -ResumeFrom would otherwise inherit whatever a failed run left, every gate skipped.
    $null = Assert-FfmpegPkgConfig -PkgConfigDir (Join-Path $prefix 'lib\pkgconfig')
    Write-Host "FFmpeg already installed at $prefix - .pc gate passed, skipping"; return
}

$tarballPath = "$SourceDir\ffmpeg.tar.gz"
if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null

# Phase brackets via trap, not a whole-body try/catch, so a failure names its phase.
trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'ffmpeg'; break }

Switch-BuildPhase '1. download + extract'
Write-Host "Downloading FFmpeg $FfmpegVersion..."
if ($FfmpegVersion -in @('main', 'master', 'develop')) {
    try {
        Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/heads/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
    } catch {
        # FFmpeg GitHub mirror uses 'master' as default branch; fall back if branch not found
        Write-Warning "FFmpeg branch '$FfmpegVersion' not found, trying 'master'..."
        Invoke-DownloadWithRetry -Url 'https://github.com/FFmpeg/FFmpeg/archive/refs/heads/master.tar.gz' -DestinationPath $tarballPath -Description 'FFmpeg master tarball'
        $FfmpegVersion = 'master'
    }
} else {
    Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
}
Write-Host "Extracting tarball..."
$srcDir = Expand-SourceTarball -Archive $tarballPath -Destination $SourceDir
Write-Host "Source at: $srcDir"

# Without a repo, Invoke-SourcePatch's probe writes stderr, which PS 5.1 under EAP=Stop makes terminating.
Initialize-ExtractedGitRepo -Path $srcDir

Switch-BuildPhase '2. VERSION synthesis + lib*.version'
# VERSION file: tarballs ship none and there are no tags, so every .pc would say "Version: .." and gst-libav would drop out.
$ffmpegVersionNumber = ([string]$FfmpegVersion) -replace '^n', ''
if ($ffmpegVersionNumber -match '^\d+(\.\d+)*$') {
    Set-Content -Path (Join-Path $srcDir 'VERSION') -Value $ffmpegVersionNumber -Encoding ascii -NoNewline
    Write-Host "Wrote VERSION=$ffmpegVersionNumber (GitHub tarballs ship none; configure would emit 'Version: ..' in every .pc)"
} else {
    # A branch build has no meaningful release number -- leave it to configure, and say so.
    Write-Warning "FFMPEG_VERSION '$FfmpegVersion' is not a release number; .pc Version fields may come out empty."
}

# lib*.version: libversion.sh's awk writes them empty under Git-Bash, so write them here (LF, no BOM; make includes them).
$ffLibs = 'avutil', 'avcodec', 'avformat', 'avdevice', 'avfilter', 'swscale', 'swresample', 'postproc'
foreach ($ffLib in $ffLibs) {
    $ffLibDir = Join-Path $srcDir "lib$ffLib"
    if (-not (Test-Path $ffLibDir)) { continue }
    $ffLibText = ''
    foreach ($h in @((Join-Path $ffLibDir 'version_major.h'), (Join-Path $ffLibDir 'version.h'))) {
        if (Test-Path $h) { $ffLibText += [System.IO.File]::ReadAllText($h) + "`n" }
    }
    $ffLibUc = "LIB$($ffLib.ToUpper())"
    $ffMaj = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MAJOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMin = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MINOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMic = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MICRO\s+(\d+)") { $Matches[1] } else { '' }
    if (-not ($ffMaj -and $ffMin -and $ffMic)) {
        throw "lib$ffLib version macros not found in version(.major).h (upstream layout changed?) - refusing to write a broken .version file"
    }
    $ffVerContent = "lib${ffLib}_VERSION=$ffMaj.$ffMin.$ffMic`nlib${ffLib}_VERSION_MAJOR=$ffMaj`nlib${ffLib}_VERSION_MINOR=$ffMin`n"
    [System.IO.File]::WriteAllText((Join-Path $ffLibDir "lib$ffLib.version"), $ffVerContent)
    Write-Host "Wrote lib$ffLib.version = $ffMaj.$ffMin.$ffMic (bypasses the libversion.sh awk chain)"
}

Enter-VsDevCmdEnvironment
$scoopShims = "$env:USERPROFILE\scoop\shims"
# Bounded: a scoop fetch once sat silent for two hours on a network timeout.
function Invoke-BoundedProvisionStep {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Step,
        [int]$TimeoutMinutes = 10
    )
    $stepStart = Get-Date
    $job = Start-Job -ScriptBlock $Step
    try {
        while ($job.State -eq 'Running' -and (Get-Date) -lt $stepStart.AddMinutes($TimeoutMinutes)) {
            $null = Wait-Job -Job $job -Timeout 60
            if ($job.State -eq 'Running') {
                Write-Host ("  [{0}] still running ({1:N0}s) - heartbeat (#76 guard)" -f $Label, ((Get-Date) - $stepStart).TotalSeconds)
            }
        }
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            throw "$Label exceeded $TimeoutMinutes min - the #76 stall class (2h-mute network timeout); rerun or check egress."
        }
        # A failed job fails the step too, not a later unrelated 'make: not found'.
        $jobOut = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrs
        if ($jobOut) { $jobOut | ForEach-Object { Write-Host "  [$Label] $_" } }
        if ($job.State -ne 'Completed' -or ($jobErrs -and $jobErrs.Count -gt 0)) {
            $reason = if ($jobErrs) { ($jobErrs | Select-Object -First 3) -join '; ' } else { "job state $($job.State)" }
            throw "$Label FAILED: $reason"
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
Switch-BuildPhase '3. toolchain provisioning (make/gawk/nv-codec)'
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    Write-Host "Installing make via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install make' -Step { & scoop install main/make 2>&1; if ($LASTEXITCODE) { throw "scoop exit $LASTEXITCODE" } }
}
# Install gawk and replace MSYS2's broken awk
if (-not (Get-Command gawk -ErrorAction SilentlyContinue)) {
    Write-Host "Installing gawk via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install gawk' -Step { & scoop install main/gawk 2>&1; if ($LASTEXITCODE) { throw "scoop exit $LASTEXITCODE" } }
}
$gitAwk = 'C:\Program Files\Git\usr\bin\awk.exe'
$gawkExe = Join-Path $scoopShims 'gawk.exe'
if ((Test-Path $gitAwk) -and (Test-Path $gawkExe)) {
    Copy-Item $gawkExe $gitAwk -Force
    Write-Host "Replaced MSYS2 awk with gawk"
}
$gitUsrBin = 'C:\Program Files\Git\usr\bin'
$env:PATH = "$scoopShims;$gitUsrBin;$env:PATH"
$bashExe = Join-Path $gitUsrBin 'bash.exe'

# NVIDIA hardware video: header-only, the codec loads from the driver at run time; --enable-cuda-nvcc stays off.
$nvencFlags = @()
$ffGpu = Get-GpuEnvironment
$ffAmfPlan = Get-FfmpegAmfPlan -GpuEnvironment $ffGpu -IsCross $ffCross -SourceDir $srcDir
$ffVulkanPlan = Get-FfmpegVulkanPlan -AmfPlan $ffAmfPlan -VulkanSdk ([string]$env:VULKAN_SDK)
# Every native amd64 lane but rocm, and any CUDA lane: configure has no arch guard here, only the headers.
$ffNvencOnLane = ($ffAmfPlan -and -not $ffAmfPlan.Rocm) -or ($ffGpu.HasCuda -and (Test-Path (Join-Path $ffGpu.CudaRoot 'include\cuda.h')))
if ($ffNvencOnLane) {
    Write-Host 'FFmpeg: enabling NVENC/NVDEC/CUVID via nv-codec-headers (header-only; the driver is loaded at run time)'
    # PREFIX is a forward-slash Windows path, not MSYS, so ffnvcodec.pc emits cflags cl.exe consumes directly.
    $nvHdrRef       = if ($env:NV_CODEC_HEADERS_REF) { $env:NV_CODEC_HEADERS_REF } else { 'n13.1.15.0' }
    $nvHdrSrc       = 'C:\temp\nv-codec-headers'
    $nvHdrPrefix    = 'C:\temp\nv-codec-headers-install'
    $nvHdrPrefixFwd = $nvHdrPrefix -replace '\\', '/'
    if (Test-Path $nvHdrSrc)    { Remove-Item $nvHdrSrc -Recurse -Force }
    if (Test-Path $nvHdrPrefix) { Remove-Item $nvHdrPrefix -Recurse -Force }
    # Shielded: git's "Cloning into..." stderr is terminating under PS 5.1 EAP=Stop, even with 2>&1.
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers clone' -CommandLine "git clone --branch $nvHdrRef --depth 1 https://github.com/FFmpeg/nv-codec-headers.git `"$nvHdrSrc`"")
    $nvHdrSrcCyg = ConvertTo-MsysPath $nvHdrSrc
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers make install' -CommandLine "`"$bashExe`" -c `"cd $nvHdrSrcCyg && make install PREFIX=$nvHdrPrefixFwd`"")
    $nvPc = Join-Path $nvHdrPrefix 'lib\pkgconfig\ffnvcodec.pc'
    if (Test-Path $nvPc) {
        Add-FfmpegPkgConfigDir -Dir (Join-Path $nvHdrPrefix 'lib\pkgconfig')
        $nvencFlags = @('--enable-ffnvcodec', '--enable-nvenc', '--enable-nvdec', '--enable-cuvid')
        Write-Host "ffnvcodec $nvHdrRef installed -> $nvPc"
    } else {
        Write-Warning 'nv-codec-headers install produced no ffnvcodec.pc -- FFmpeg will build without NVIDIA video accel.'
    }
} elseif ($ffAmfPlan) {
    Write-Host "FFmpeg: rocm lane -> no NVENC/NVDEC; AMD AMF and Vulkan (SDK $($ffVulkanPlan.SdkRoot)) are enabled below"
} elseif ($ffCross) {
    Write-Host "FFmpeg: no nvidia CUDA toolkit -> cross build for $ffTargetArch without NVENC/NVDEC (CPU-only FFmpeg; Vulkan is enabled on the rocm lane only)"
} else {
    Write-Host 'FFmpeg: no nvidia CUDA toolkit -> building without NVENC/NVDEC (CPU-only lane)'
}

# Software codecs: take the result object, whatever else a helper emitted on the pipeline.
$ffCodecs = @(& (Join-Path $PSScriptRoot 'Build-FfmpegCodecs.ps1') -Prefix 'C:\temp\ffmpeg-codecs' -TargetArch $ffTargetArch) |
    Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ConfigureFlags'] } | Select-Object -Last 1
if (-not $ffCodecs) { throw 'Build-FfmpegCodecs.ps1 returned no result object' }
if ($ffCodecs.ConfigureFlags.Count -gt 0) { Add-FfmpegPkgConfigDir -Dir $ffCodecs.PkgConfigDir }

$cygPrefix = ConvertTo-MsysPath $prefix
$cygSrc = ConvertTo-MsysPath $srcDir

# Headers go into compat/: --extra-cflags reaches configure's test_cc probes too, which the AMF and Vulkan -I rely on.
$onnxRuntimeDir = Join-Path $InstallDir 'lib\onnxruntime-source'
$onnxHeaderCopied = $false
if (Test-Path $onnxRuntimeDir) {
    $header = Get-ChildItem "$onnxRuntimeDir" -Recurse -Filter 'onnxruntime_c_api.h' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($header) {
        $ffCompatInc = Join-Path $srcDir 'compat\onnx'
        New-Item -Path $ffCompatInc -ItemType Directory -Force | Out-Null
        # The whole include dir: ORT 1.28 split the C API across new sibling headers.
        $ortHeaders = @(Get-ChildItem $header.Directory -File)
        $ortHeaders | Copy-Item -Destination $ffCompatInc -Force
        Write-Host "Copied $($ortHeaders.Count) ONNX header(s) to: $ffCompatInc"
        $onnxHeaderCopied = $true
    } else {
        Write-Warning "ONNX Runtime header onnxruntime_c_api.h not found under $onnxRuntimeDir"
    }
}

# AMD AMF headers into compat/ like the ONNX ones above; every native amd64 lane fetches them.
if ($ffAmfPlan) {
    $amfVersion = Get-SourceBuildVersion -EnvironmentVariables @('AMF_HEADERS_VERSION')
    $amfSha = Get-SourceBuildVersion -EnvironmentVariables @('AMF_HEADERS_SHA256')
    $amfDir = Install-FfmpegAmfHeader -Version $amfVersion -Sha256 $amfSha -Destination $ffAmfPlan.CompatDir
    Write-Host "FFmpeg: AMF headers $amfVersion -> $amfDir"
}
$ffRocmFlags = @(Get-FfmpegRocmConfigureArg -AmfPlan $ffAmfPlan -VulkanPlan $ffVulkanPlan)

$confFlags = @()
$confFlags += "--prefix=$cygPrefix"
$confFlags += '--enable-shared', '--disable-static'
$confFlags += '--disable-debug', '--disable-doc'
# No --enable-nonfree: the published images must stay redistributable.
$confFlags += '--enable-gpl', '--enable-version3'
$confFlags += '--enable-ffmpeg', '--enable-ffprobe'
if ($onnxHeaderCopied) {
    $confFlags += '--enable-libonnxruntime'
    $confFlags += "--extra-cflags=-I$cygSrc/compat/onnx"
    $confFlags += "--extra-ldflags=-libpath:$($onnxRuntimeDir -replace '\\', '/')/lib"
}
# FFmpeg has no clang-cl preset: keep msvc's flag conventions and VsDevCmd env, override only cc/ld.
$ffToolchain = if ($env:FFMPEG_TOOLCHAIN) { $env:FFMPEG_TOOLCHAIN } else { 'clang-cl' }
if ($ffToolchain -eq 'clang-cl') {
    # sccache at make time (make CC= beats config.mak), not in --cc, whose test objects lld-link rejects; remote backend only.
    $ffSccache = Get-Command sccache.exe -ErrorAction SilentlyContinue
    $ffUseLauncher = [bool]($ffSccache -and (Test-SccacheRemoteConfigured) -and $env:FFMPEG_SCCACHE -ne '0')
    Write-Host "FFmpeg toolchain: clang-cl + lld-link (overriding the msvc preset's cc/ld; make-time sccache launcher: $ffUseLauncher)"
    $confFlags += '--toolchain=msvc', "--cc=clang-cl$ffCcTargetFlag", '--ld=lld-link'
    # Unset, makedef runs the first llvm-nm bash finds, and a DLL can end up exporting nothing.
    $ffLlvmNm = Get-FfmpegLlvmNm (Get-Command clang-cl.exe -ErrorAction Stop).Source
    $env:LLVM_NM = ConvertTo-MsysPath $ffLlvmNm
    Write-Host "FFmpeg makedef: llvm-nm = $ffLlvmNm"
} else {
    Write-Host 'FFmpeg toolchain: msvc (cl.exe + link.exe)'
    $confFlags += '--toolchain=msvc'
}
if ($ffCross) {
    # --target-os stays unset on purpose: under MSYS, a guess can pick another code path than amd64's reference TARGET_OS.
    $confFlags += '--enable-cross-compile', "--arch=$(Get-FfmpegTargetArch -Arch $ffTargetArch)"
    # The linker needs /machine besides the compiler's --target, or configure's link probes run as x64.
    $confFlags += "--extra-ldflags=/machine:$(Get-LibMachineArg -Arch $ffTargetArch)"
    # Host tools need GNU-flag clang (configure falls back to absent gcc) and the x64 lib dirs ahead of VsDevCmd's arm64 %LIB%.
    $hostArchDir = Get-MsvcTargetLibDir -Arch (Get-WindowsHostArch)
    $hostLibDirs = @()
    if ($env:VCToolsInstallDir) { $hostLibDirs += (Join-Path $env:VCToolsInstallDir "lib\$hostArchDir") }
    $sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
    $sdkVerDir = Get-ChildItem $sdkLibRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "ucrt\$hostArchDir") } |
        Sort-Object Name | Select-Object -Last 1
    if ($sdkVerDir) {
        $hostLibDirs += (Join-Path $sdkVerDir.FullName "ucrt\$hostArchDir")
        $hostLibDirs += (Join-Path $sdkVerDir.FullName "um\$hostArchDir")
    }
    $hostLibDirs = @($hostLibDirs | Where-Object { Test-Path $_ })
    if ($hostLibDirs.Count -eq 0) {
        throw ("cross build: could not locate any $hostArchDir (host) lib directory for FFmpeg's host tools. " +
               'VCToolsInstallDir=' + $env:VCToolsInstallDir + "; SDK root=$sdkLibRoot")
    }
    # host_ldflags reach an MSYS sh recipe and these dirs hold spaces and parens; 8.3 names can be disabled, so quote as fallback.
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $hostLibArgs = foreach ($d in $hostLibDirs) {
        $short = try { $fso.GetFolder($d).ShortPath } catch { $d }
        if ($short -notmatch '[ ()]') {
            "-Wl,-libpath:$short"
        } else {
            # Double quotes: $confStr wraps a spaced flag in single quotes, which a nested single quote would end.
            '-Wl,-libpath:"' + ($d -replace '\\', '/') + '"'
        }
    }
    # Two quoting levels for two parses: $confStr's single quotes for configure, the double quotes above for make's sh.
    $confFlags += '--host-cc=clang'
    $confFlags += ('--host-ldflags=' + ($hostLibArgs -join ' '))
    Write-Host ("FFmpeg: host tools link against {0} libs -> {1}" -f $hostArchDir, ($hostLibArgs -join ' '))
    # clang's integrated assembler reads GAS syntax; if a .S file breaks, fall back to --disable-asm, not llvm-mingw (wrong ABI).
    $confFlags += "--as=clang$ffCcTargetFlag"
    Write-Host "FFmpeg: aarch64 asm ENABLED via clang's integrated assembler (--as=clang$ffCcTargetFlag); configure assembles test fragments but never runs them"
    # Forced on so a missed probe cannot silently drop FFmpeg 9's aarch64 dotprod/i8mm paths.
    $confFlags += '--enable-neon', '--enable-dotprod', '--enable-i8mm'
    Write-Host "FFmpeg: aarch64 NEON + dotprod + i8mm explicitly requested"
    Write-Host ("FFmpeg: cross flags -> --enable-cross-compile --arch={0} --extra-ldflags=/machine:{1}" -f `
        (Get-FfmpegTargetArch -Arch $ffTargetArch), (Get-LibMachineArg -Arch $ffTargetArch))
}
# The cross lane's --disable-x86asm is a no-op kept so both lanes state their intent side by side.
if ($ffCross) {
    $confFlags += '--disable-x86asm'
} else {
    $nasmCmd = Get-Command nasm.exe -ErrorAction SilentlyContinue
    if (-not $nasmCmd) { throw 'FFmpeg: x86asm is enabled on the amd64 lane (backlog #119) but nasm.exe is not on PATH -- Test-Toolchain.ps1 asserts it; the toolchain layer is incomplete' }
    $confFlags += "--x86asmexe=$($nasmCmd.Source -replace '\\', '/')"
    Write-Host "FFmpeg: x86asm ENABLED (nasm $($nasmCmd.Source); backlog #119 -- --disable-x86asm had no recorded reason)"
}
# vfwcap imports AVICAP32.dll, absent from Server Core, so every avdevice load would fail.
$confFlags += '--disable-indev=vfwcap'
# NVIDIA hardware video accel: empty on the CPU-only lane, populated above when CUDA is present.
$confFlags += $nvencFlags
# AMD AMF on every native amd64 lane, + Vulkan on rocm; an empty array on the cross lane.
$confFlags += $ffRocmFlags
# dav1d/x264/x265 are static: --static makes pkg-config hand configure their Libs.private too.
if ($ffCodecs.ConfigureFlags.Count -gt 0) { $confFlags += @($ffCodecs.ConfigureFlags) + @('--pkg-config-flags=--static') }

# Quote flags carrying spaces: bash parses the wrapper line.
$confStr = ($confFlags | ForEach-Object { if ($_ -match ' ') { "'$_'" } else { $_ } }) -join ' '

# Patch configure to allow MSYS2 builds (official docs say MSYS is discouraged)
Invoke-SourcePatch -PatchFile (Join-Path $scriptAssetRoot 'patches\ffmpeg\001-allow-msys-builds.patch') -SourceDir $srcDir -IgnoreWhitespace

# VsDevCmd INCLUDE/LIB are inherited from PowerShell, so the MSVC SDK paths are available.
$wrapperLines = @()
$wrapperLines += '#!/usr/bin/env bash'
$wrapperLines += "cd $cygSrc"
$wrapperLines += 'export MSYS=winsymlinks:lnk'
$wrapperLines += 'export TMPDIR=tmpdir'
$wrapperLines += 'rm -rf tmpdir; mkdir -p tmpdir'
Switch-BuildPhase '4. configure'
$wrapperLines += "./configure $confStr"

$wrapperPath = Join-Path $srcDir 'ffmpeg-configure-wrapper.sh'
[System.IO.File]::WriteAllLines($wrapperPath, $wrapperLines)

Write-Host "Configuring FFmpeg (toolchain: $ffToolchain)..."
& $bashExe $wrapperPath 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    $logFile = Join-Path $srcDir 'ffbuild\config.log'
    if (Test-Path $logFile) { Write-Host "=== config.log (last 50 lines) ==="; Get-Content $logFile -Tail 50 }
    throw "FFmpeg configure failed (exit $LASTEXITCODE)"
}
# config.mak's CC is the bare compiler by design; echoed so a cache regression shows in the build output.
$configMak = Join-Path $srcDir 'ffbuild\config.mak'
if (Test-Path $configMak) {
    $ccLine = (Select-String -Path $configMak -Pattern '^CC=' | Select-Object -First 1).Line
    Write-Host "config.mak: $ccLine (make-time sccache launcher: $ffUseLauncher)"
    # configure's verdict on arch/OS/cpu/assembler, log-only; @() keeps a no-match an empty loop under StrictMode.
    foreach ($m in @(Select-String -Path $configMak -Pattern '^(TARGET_OS|ARCH|CPU|AS)=' -ErrorAction SilentlyContinue)) {
        Write-Host "config.mak: $($m.Line)"
    }
    # Surface a probe that stops matching at configure time, not hours later in OpenCV's video decode.
    if ($ffCross) {
        $haveDotprod = (Select-String -Path $configMak -Pattern '^HAVE_DOTPROD=yes' -Quiet)
        $haveI8mm = (Select-String -Path $configMak -Pattern '^HAVE_I8MM=yes' -Quiet)
        Write-Host "config.mak: HAVE_DOTPROD=$($haveDotprod ? 'yes' : 'no') HAVE_I8MM=$($haveI8mm ? 'yes' : 'no')"
        if (-not $haveDotprod) { Write-Warning 'FFmpeg cross: HAVE_DOTPROD=no — aarch64 dotprod optimized paths are DISABLED (configure did not detect the feature; this costs decode/encode performance on Snapdragon)' }
        if (-not $haveI8mm) { Write-Warning 'FFmpeg cross: HAVE_I8MM=no — aarch64 i8mm optimized paths are DISABLED (configure did not detect the feature; this costs color conversion and scaling performance on Snapdragon)' }
    }
}
# A missing lib fails configure, but a lane that lost the flags altogether would configure green.
if ($ffCodecs.ConfigSymbols.Count -gt 0) {
    $codecGap = @($ffCodecs.ConfigSymbols | Where-Object { -not (Select-String -LiteralPath $configMak -Pattern "^$_=yes\r?$" -Quiet) })
    if ($codecGap.Count -gt 0) { throw "FFmpeg: configure left software codec(s) disabled: $($codecGap -join ', ')" }
    Write-Host "FFmpeg: config.mak enables $($ffCodecs.ConfigSymbols -join ', ')"
}
# Every AMF lane: fail now, not at the smoke gate hours later, if configure left an AMF component off.
if ($ffAmfPlan) {
    $configMakText = [string](Get-Content -LiteralPath $configMak -Raw)
    $amfGap = @(Get-FfmpegAmfConfigGap -ConfigMakText $configMakText)
    if ($amfGap.Count -gt 0) { throw "FFmpeg: configure left AMF component(s) disabled: $($amfGap -join ', ')" }
    $rocmLeak = @(Get-FfmpegRocmLeak -ConfigMakText $configMakText -RocmRoot $ffAmfPlan.RocmRoot)
    if ($rocmLeak.Count -gt 0) { throw "FFmpeg (rocm lane): configure picked up the ROCm tree: $($rocmLeak -join ' | ')" }
    Write-Host "FFmpeg: config.mak enables all $(@(Get-FfmpegAmfConfigSymbol).Count) AMF symbols"
}
# rocm lane: the same fail-now gate for Vulkan (headers, vulkan_1_4, glslc-built components, SPIR-V headers).
if ($ffVulkanPlan) {
    $vulkanGap = @(Get-FfmpegVulkanConfigGap -ConfigMakText ([string](Get-Content -LiteralPath $configMak -Raw)) -Glslc $ffVulkanPlan.Glslc)
    if ($vulkanGap.Count -gt 0) { throw "FFmpeg (rocm lane): configure left Vulkan component(s) off: $($vulkanGap -join ', ')" }
    Write-Host "FFmpeg (rocm lane): config.mak enables all $(@(Get-FfmpegVulkanConfigSymbol).Count) Vulkan symbols, GLSLC=$($ffVulkanPlan.Glslc)"
    # Log-only: zlib+gzip autodetection (configure:7285) picks the gzip'd or the plain SPIR-V embed rule.
    Write-Host "config.mak: shader compression $(if (Select-String -LiteralPath $configMak -Pattern '^CONFIG_SHADER_COMPRESSION=yes' -Quiet) { 'ON' } else { 'OFF' })"
}

Write-Host 'Building FFmpeg (this may take 30-60 minutes)...'
# Inline, not .patch files: configure generates these per run. See docs/windows-builds.md § Source Patch Policy
$ffbuildDir = Join-Path $srcDir 'ffbuild'
Get-ChildItem -Path $ffbuildDir -Filter '*.mak' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-MakefileShowIncludes -Path $_.FullName
}
foreach ($fn in @('library.mak', 'subdir.mak', 'Makefile')) {
    Remove-MakefileShowIncludes -Path (Join-Path $srcDir $fn) -StripWildcardInclude
}
# Inter-library import-lib deps: the msvc preset may emit no EXTRALIBS at all.
$configMakPath = Join-Path $srcDir 'ffbuild/config.mak'
if (Test-Path $configMakPath) {
    $extraLibs = [ordered]@{
        'libswresample' = 'avutil.lib'
        'libswscale'    = 'avutil.lib'
        'libavcodec'    = 'avutil.lib'
        'libavfilter'   = 'avutil.lib'
        'libavformat'   = 'avutil.lib avcodec.lib'
        'libavdevice'   = 'avformat.lib avcodec.lib avutil.lib'
    }
    $cm = [System.IO.File]::ReadAllText($configMakPath)
    foreach ($lib in $extraLibs.Keys) {
        $line = "EXTRALIBS-$lib=$($extraLibs[$lib])"
        if ($cm -match "(?m)^EXTRALIBS-$lib\s*=") {
            $cm = $cm -replace "(?m)^EXTRALIBS-$lib\s*=.*", $line
        } else {
            $cm += "`n$line"
        }
    }
    [System.IO.File]::WriteAllText($configMakPath, $cm)
}

# A full overwrite, not a .patch: a context diff of a full rewrite kept breaking on upstream drift.
$makedefSrc = Join-Path $scriptAssetRoot 'patches\ffmpeg\makedef'
$makedefDst = Join-Path $srcDir 'compat\windows\makedef'
Copy-Item $makedefSrc $makedefDst -Force
Write-Host "Replaced compat/windows/makedef (glob-expanding, response-file-aware)"

# -jN can race to LNK1120; make is incremental, so the -j1 retry redoes only what failed.
$makeJobs = Get-BuildJobCount -MemGBPerJob 2
# The launcher is safe at make time only because Remove-MakefileShowIncludes strips -options:strict.
Switch-BuildPhase '5. make + install'
$makeCc = if ($ffUseLauncher) { " CC='sccache clang-cl$ffCcTargetFlag'" } else { '' }
# -Optional by design: failures fall through to the -j1 retry and the artifact checks below.
[void](Invoke-ShieldedNative -Optional -Label "ffmpeg make -j$makeJobs" -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j$makeJobs$makeCc`"")
$builtFfmpeg = Join-Path $srcDir 'ffmpeg.exe'
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Retrying with single job (resolves MSVC link races)...'
    [void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make -j1' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j1$makeCc`"")
}
# The source build can fail at the link stage; fall through to the prebuilt gate below.
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Source build of FFmpeg did not produce ffmpeg.exe (link stage incomplete).'
}
Write-Host 'Attempting install from source if built...'
[void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make install (verify below)' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make install`"")

# Per-stage stats: the chain-aggregate dump cannot attribute compile requests to this stage.
if ($ffUseLauncher) { Write-SccacheStatsToStderr -Advanced -RequireRemote }

# A shared build is unusable without its av*.dll beside the exes: treat that as a failed build.
$installedDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
if ((Test-Path "$ffmpegDir\ffmpeg.exe") -and $installedDlls.Count -eq 0) {
    Write-Warning 'Source install produced exes but no av*.dll runtime libraries - discarding as incomplete.'
    Remove-Item "$ffmpegDir\ffmpeg.exe", "$ffmpegDir\ffplay.exe", "$ffmpegDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
}

# The prebuilt fallback is fail-closed: the chain promises our FFmpeg; FFMPEG_ALLOW_PREBUILT=1 opts in on a scrubbed prefix.
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) {
    if ($env:FFMPEG_ALLOW_PREBUILT -ne '1') {
        throw ('FFmpeg source build did not produce ffmpeg.exe and the prebuilt fallback is fail-closed (#68) - ' +
            'fix the source build (see the make output above) or opt in explicitly with FFMPEG_ALLOW_PREBUILT=1.')
    }
    # No prebuilt on cross for provenance, not availability: a winarm64 BtbN asset exists.
    if ($ffCross) {
        throw ("FFmpeg source build did not produce ffmpeg.exe -- and the cross lane has no prebuilt escape hatch: " +
            "a foreign BtbN binary would break the source-chain promise (a winarm64 asset exists; availability is " +
            "not the reason). Fix the cross build (see the make output above).")
    }
    Write-Warning 'FFmpeg source build failed -- falling back to pre-built BtbN MSVC FFmpeg (FFMPEG_ALLOW_PREBUILT=1). DNN/ONNX integration will NOT be available in the fallback binary.'
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '0', 'Process')
    # No MIXED installs: wipe the partial source install before the foreign binaries land.
    Reset-SourceBuildDirectory -Path $prefix
    if (-not (Test-Path $prefix)) { New-Item -Path $prefix -ItemType Directory -Force | Out-Null }
    $dlUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $zipPath = "$env:TEMP\ffmpeg.zip"
    Invoke-DownloadWithRetry -Url $dlUrl -DestinationPath $zipPath -Description 'BtbN prebuilt FFmpeg'
    & 7z x "$zipPath" -o"$env:TEMP\ffmpeg-extract" -y -bd 2>&1 | Out-Null
    $binDir = Get-ChildItem -Path "$env:TEMP\ffmpeg-extract" -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
    if ($binDir) {
        if (-not (Test-Path $ffmpegDir)) { New-Item -Path $ffmpegDir -ItemType Directory -Force | Out-Null }
        Copy-Item "$binDir\*.exe" "$ffmpegDir\" -Force
        Copy-Item "$binDir\*.dll" "$ffmpegDir\" -Force
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '1', 'Process')
}

# configure needs the MSYS --prefix, which it copies into every .pc; native consumers need the Windows form.
$ffPkgConfigDir = Join-Path $prefix 'lib\pkgconfig'
if (Test-Path $ffPkgConfigDir) {
    $winPrefix = ($prefix -replace '\\', '/')   # C:/runtime/ffmpeg
    # The exact string configure got: a second conversion could drift and match nothing.
    $msysPrefix = $cygPrefix -replace '\\', '/' # /c/runtime/ffmpeg
    $rewritten = 0
    foreach ($pc in Get-ChildItem -Path $ffPkgConfigDir -Filter '*.pc' -File) {
        $text = Get-Content $pc.FullName -Raw
        if ($text -notmatch [regex]::Escape($msysPrefix)) { continue }
        Set-Content -Path $pc.FullName -Value ($text -replace [regex]::Escape($msysPrefix), $winPrefix) -Encoding ascii -NoNewline
        $rewritten++
    }
    Write-Host "Rewrote MSYS prefixes to Windows form in $rewritten .pc file(s) under $ffPkgConfigDir"
}
# Every lane installs libavutil/hwcontext_amf.h, which includes <AMF/...>; every native amd64 lane ships those headers.
if ($ffAmfPlan -and $env:FFMPEG_SOURCE_BUILD -eq '1') {
    $amfInstalled = Copy-FfmpegAmfHeaderTree -IncludeRoot $ffAmfPlan.CompatDir -Destination (Join-Path $prefix 'include')
    Write-Host "FFmpeg: AMF headers installed to $amfInstalled"
}

# Outside the Test-Path guard, so a missing lib\pkgconfig fails too; only the prebuilt fallback skips.
Switch-BuildPhase '6. pc gate + PyAV wheel'
if ($env:FFMPEG_SOURCE_BUILD -eq '0') {
    Write-Warning 'Prebuilt fallback active (FFMPEG_ALLOW_PREBUILT=1): no .pc files exist by design; downstream consumers (gst-libav, OpenCV chain-link, PyAV) will not find FFmpeg.'
} else {
    $null = Assert-FfmpegPkgConfig -PkgConfigDir $ffPkgConfigDir
}

# Import libs: harvest every .lib/.def into lib\ and regenerate missing ones, since upstream has moved this layout before.
if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    $ffLibDir = Join-Path $prefix 'lib'
    New-Item -Path $ffLibDir -ItemType Directory -Force | Out-Null
    foreach ($pattern in @('*.lib', '*.def')) {
        $harvest = @(Get-ChildItem $prefix -Recurse -Filter $pattern -ErrorAction SilentlyContinue) +
                   @(Get-ChildItem $srcDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^(av|sw)' })
        foreach ($f in $harvest) {
            if ($f.DirectoryName -ne $ffLibDir) {
                Write-Host "harvesting $($f.Name) from $($f.DirectoryName)"
                Copy-Item $f.FullName $ffLibDir -Force
                # Inside the prefix this is a move: bin\ ships only runtime DLLs and exes.
                if ($f.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item $f.FullName -Force
                }
            }
        }
    }
    foreach ($defFile in @(Get-ChildItem $ffLibDir -Filter '*.def' -ErrorAction SilentlyContinue)) {
        # avformat-63.def -> avformat.lib (unversioned, what PyAV's -lavformat resolves)
        $libName = ($defFile.BaseName -replace '-\d+$', '') + '.lib'
        $libPath = Join-Path $ffLibDir $libName
        if (-not (Test-Path $libPath)) {
            Write-Host "regenerating $libName from $($defFile.Name)"
            # /name pins the DLL (makedef emits EXPORTS only); /machine follows the target.
            [void](Invoke-ShieldedNative -Label "lib.exe /def $($defFile.Name)" -CommandLine "lib.exe /nologo /machine:$(Get-LibMachineArg -Arch $ffTargetArch) /def:`"$($defFile.FullName)`" /name:$($defFile.BaseName).dll /out:`"$libPath`"")
        }
    }
    # Fail here with data, not a bare LNK1181 inside setup.py; the BtbN fallback ships no import libs.
    $ffImportLibs = @(Get-ChildItem $ffLibDir -Filter '*.lib' -ErrorAction SilentlyContinue | ForEach-Object Name)
    Write-Host ("import libs in ${ffLibDir}: " + (($ffImportLibs | Sort-Object) -join ', '))
    if (([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -eq '1') -and
        ($ffImportLibs -notcontains 'avformat.lib')) {
        Write-Host ("lib dir inventory: " + ((Get-ChildItem $ffLibDir -Name -ErrorAction SilentlyContinue) -join ', '))
        throw "ffmpeg install has no avformat.lib in $ffLibDir -- master drift broke import-lib generation"
    }
}

# G2: the tree (compat\onnx is the chain's headers), config.mak and config.log hold the chain ORT only; a pass stamps it for G1.
Assert-ChainOrtOnly -Consumer 'ffmpeg' -OrtRoot $onnxRuntimeDir -TreeRoot $SourceDir -Shim (Join-Path $srcDir 'compat\onnx') `
    -Record (Join-Path $srcDir 'ffbuild\config.mak') -Log (Join-Path $srcDir 'ffbuild\config.log')

Remove-SourceBuildTree -Path $SourceDir

Write-Host "=== FFmpeg build completed ==="
Write-Host "Artifacts at: $prefix"
if (Test-Path "$ffmpegDir\ffmpeg.exe") { Write-Host "ffmpeg.exe installed" }
if (Test-Path "$ffmpegDir\ffprobe.exe") { Write-Host "ffprobe.exe installed" }
$finalDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
Write-Host "runtime DLLs installed: $($finalDlls.Count)"
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) { throw 'FFmpeg install incomplete: no ffmpeg.exe (source build and fallback both failed)' }

# PyAV from sdist against this FFmpeg: PyPI's wheel bundles an avdevice that imports AVICAP32.dll, absent from Server Core.
$ffTargetPy = Get-TargetBuildPython
if ($ffCross -and -not $ffTargetPy.Available) {
    Write-Host "Skipping the PyAV wheel: cross build without a target CPython import lib ($($ffTargetPy.Lib) missing -- did Build-TargetCpython.ps1 run?)"
    Complete-CurrentBuildPhase
    Write-BuildPhaseSummary -Label 'ffmpeg'
    Complete-SourceBuild -Banner '=== FFmpeg cross build completed (PyAV skipped: no target CPython) ===' -SourceDir $SourceDir
}
if ([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -ne '1') {
    Write-Warning 'FFmpeg came from the prebuilt fallback (no headers/import libs) -- skipping the PyAV wheel build.'
    return
}
$pyavVersion = Get-SourceBuildVersion -EnvironmentVariables @('PYAV_VERSION') -DefaultValue '18.1.0'
Write-Host "=== PyAV $pyavVersion wheel build (against $prefix) ==="
$py = Get-SourceBuildPython
Install-CpythonPip -Python $py
Initialize-PythonPlatformTag | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'cython', 'setuptools', 'wheel')
$pyavSrcRoot = 'C:\temp\pyav-src'
New-Item -Path $pyavSrcRoot -ItemType Directory -Force | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('download', "av==$pyavVersion", '--no-binary', ':all:', '--no-deps', '--no-build-isolation', '-d', $pyavSrcRoot)
$pyavSdist = Get-ChildItem $pyavSrcRoot -Filter 'av-*.tar.gz' | Select-Object -First 1
if (-not $pyavSdist) { throw "PyAV sdist not downloaded to $pyavSrcRoot" }
[void](Invoke-ShieldedNative -Label 'PyAV sdist extract' -CommandLine """$($py.Exe)"" -m tarfile -e ""$($pyavSdist.FullName)"" ""$pyavSrcRoot""")
$pyavDir = (Get-ChildItem $pyavSrcRoot -Directory | Select-Object -First 1).FullName
# TARGET import-lib dir on LIB (host == target on amd64; the aarch64 python314.lib on cross).
$env:LIB = "$($ffTargetPy.LibDir);$env:LIB"
$pyavBuildCmd = if ($ffCross) {
    $distutilsPlat = (Get-PythonWheelTag) -replace '_', '-'   # win_arm64 -> win-arm64 (distutils spelling)
    "setup.py --ffmpeg-dir=""$prefix"" build_ext --plat-name $distutilsPlat bdist_wheel --plat-name $(Get-PythonWheelTag)"
} else {
    "setup.py --ffmpeg-dir=""$prefix"" bdist_wheel"
}
# -CrossStage stages and PE-checks on cross, installs and imports natively; --plat-name is already in the command.
Invoke-PythonWheelBuild -Python $py -WorkingDir $pyavDir -Arguments $pyavBuildCmd -ModuleName 'av' -NoDeps -CrossStage | Out-Null
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'ffmpeg'
Complete-SourceBuild -Banner '=== PyAV wheel build completed ===' -SourceDir $pyavSrcRoot  # cleanup + banner + exit 0 (see module help)