#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# CACHE-BUST 2026-08-06 (round 2): content change sidesteps persistent
# snapshotter debris finalizing THIS RUN layer's snapshot. Round 1 dodged
# `ImportLayer 0xb7 "already exists"` (IDs nbcn…→ubvb…); the rebuilt
# snapshot then died `ActivateLayer 0x20 sharing violation` (IDs
# 16d9…→7d0i…) deterministically, SURVIVING a containerd+buildkitd
# restart — same poisoned-snapshot family, different symptom. The error is
# REPORTED at the COPY step below; busting that one is insufficient.
# New content => new chain-IDs for this layer and everything after.


param(
    [string]$TempDir = 'C:\temp',
    # Default derived below from versions.env's GIT_VERSION (baked by load-versions.ps1);
    # pass an explicit URL only for a git-for-windows respin (…windows.2 tag).
    [string]$GitInstallerUrl = '',
    [string]$CMakeVersion = '',
    [string]$VulkanVersion = '',
    # Compiled-output pins (versions.env; forwarded as Dockerfile ARGs). Empty
    # falls through to scoop's current manifest so a standalone run of this
    # script still works — the Dockerfile always passes them.
    [string]$LlvmVersion = '',
    [string]$NinjaVersion = '',
    [string]$NasmVersion = '',
    # Pinned 2026-08-08 for a FEATURE, not for output determinism: multi-tier
    # caching needs sccache >= v0.16.0 and degrades silently below it.
    [string]$SccacheVersion = '',
    # '1' turns the Vulkan ARM64 component check into a HARD gate. Default is
    # warn-only -- see the Vulkan ARM64 region below for why, and note this must
    # arrive as a PARAMETER: a bare $env: read is unreachable from `docker build`
    # unless the name is also declared as an ARG.
    [string]$WindowsArm64Strict = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Local wrappers, ON PURPOSE not module exports: setup-* scripts may only rely on
# the three modules COPY'd before them in Dockerfile.base (Shared, ContainerImage,
# Installer), and these helpers are specific to this provisioning script anyway.

# CACHE-BUST 2026-08-05: content change forces a new COPY layer -> new snapshot
# chain-IDs downstream, sidestepping a persistently corrupt half-committed
# snapshot in the containerd windows-snapshotter (ImportLayer 0xb7 "already
# exists" on the OLD chain's finalize, twice; the debris is not a reclaimable
# BK cache record and its removal would need admin). Comment is load-bearing
# history, not noise.
#
# Runs one provisioning step and throws on a non-zero native exit code. Scoop and
# dotnet failures previously just scrolled past ($ErrorActionPreference does not
# see native exit codes), letting the layer commit with tools silently missing.
function Invoke-ScoopStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    Write-Host "==> $Description"
    $global:LASTEXITCODE = 0    # clear stale exit codes from earlier native calls
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit code $LASTEXITCODE)" }
}

# Collapses the repeated `if ($version) { pkg@ver } else { pkg }` idiom and routes
# every install through the exit-code gate above. RETRIES (2026-08-19, the
# #116 lesson one level down): scoop itself has NO download retry, and a
# 20-minute 275 MB vulkan transfer died mid-download and killed the whole
# base ride. A dropped transfer can leave a partial file in scoop's cache,
# so the app's cache is purged between attempts.
function Install-ScoopPackage {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$Version = '',
        [switch]$Global,
        [int]$MaxAttempts = 3
    )
    $spec = if ([string]::IsNullOrWhiteSpace($Version)) { $Package } else { "$Package@$Version" }
    $flags = @(if ($Global) { '--global' })
    $desc = "scoop install $($flags -join ' ') $spec".Replace('  ', ' ')
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-ScoopStep -Description $desc -Command {
                scoop install @flags $spec
            }.GetNewClosure()
            return
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "$desc failed (attempt $attempt/$MaxAttempts) - purging the app's scoop cache and retrying in 15s"
            $app = ($Package -split '/')[-1]
            scoop cache rm $app 2>$null | Out-Null
            $global:LASTEXITCODE = 0
            Start-Sleep -Seconds 15
        }
    }
}

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$installerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# Shared helpers (Invoke-DownloadWithRetry, etc.) come through the Common modules' re-export.

# CMake stable pin comes from versions.env's CMAKE_VERSION (baked in by
# load-versions.ps1 / passed as -CMakeVersion from the Dockerfile ARG); empty
# falls through to scoop's current stable manifest.
$CMakeVersion = Resolve-ContainerImageValue -Value $CMakeVersion -EnvironmentVariable 'CMAKE_VERSION'
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'
# Same resolution route for the compiled-output pins (param wins, then baked env).
$LlvmVersion  = Resolve-ContainerImageValue -Value $LlvmVersion  -EnvironmentVariable 'LLVM_WINDOWS_VERSION'
$NinjaVersion = Resolve-ContainerImageValue -Value $NinjaVersion -EnvironmentVariable 'NINJA_WINDOWS_VERSION'
$NasmVersion  = Resolve-ContainerImageValue -Value $NasmVersion  -EnvironmentVariable 'NASM_WINDOWS_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

#region 1. Git (pinned installer)
# Derive the Git installer URL from GIT_VERSION (versions.env) so the pin cannot drift
# invisibly in a param default -- same pattern as the CMake/Vulkan pins above. The
# ".windows.1" tag suffix covers normal releases; a respun release needs -GitInstallerUrl.
$gitVer = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_VERSION' -DefaultValue '2.55.0'
$GitInstallerUrl = Resolve-ContainerImageValue -Value $GitInstallerUrl -EnvironmentVariable 'GIT_INSTALLER_URL' `
    -DefaultValue "https://github.com/git-for-windows/git/releases/download/v$gitVer.windows.1/Git-$gitVer-64-bit.exe"

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
# SHA256 pin from versions.env (GIT_WINDOWS_INSTALLER_SHA256, baked env). Empty
# (e.g. a -GitInstallerUrl override for a respun release) skips the hash check.
$gitSha = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_WINDOWS_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url $GitInstallerUrl -DestinationPath $gitInstaller -Description 'Git for Windows installer' -ExpectSignature MZ -ExpectedSha256 $gitSha
# Exit-code gate (was missing — a failed Git install surfaced only much later
# as "git not recognized" deep inside a media build).
$gitProc = Start-Process -FilePath $gitInstaller -ArgumentList '/SILENT', '/NORESTART' -Wait -NoNewWindow -PassThru
if ($gitProc.ExitCode -ne 0) { throw "Git for Windows installer failed (exit $($gitProc.ExitCode))" }
Remove-Item $gitInstaller -Force
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\Git\usr\bin'
) | Out-Null

#endregion
#region 2. WiX toolset (dotnet tool, pinned)
# WiX versions come from versions.env (single source of truth shared with the
# verify-toolchain.ps1 assert); defaults keep the script runnable standalone.
$WixVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_VERSION' -DefaultValue '4.0.6'
$WixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.6'
Invoke-ScoopStep -Description "dotnet tool install wix $WixVersion" -Command {
    dotnet tool install --tool-path C:\WiX wix --version $WixVersion
}
Invoke-ScoopStep -Description "wix extension add WixToolset.UI.wixext/$WixUiExtVersion" -Command {
    & 'C:\WiX\wix.exe' extension add --global "WixToolset.UI.wixext/$WixUiExtVersion"
}

Enable-Tls12ForDownloads
$scoopInstallScript = Join-Path $TempDir 'install-scoop.ps1'
#endregion
#region 3. scoop bootstrap + shims
# Hardened fetch (retry + TLS) instead of a bare one-shot irm -- a transient blip here
# killed the whole base build. Hash-pinned (SCOOP_INSTALLER_SHA256): this script is
# EXECUTED, so we only run the exact bytes that were reviewed when the pin was set.
# Scoop revving the installer surfaces as a mismatch -- re-review and bump the pin.
$scoopSha = Resolve-ContainerImageValue -EnvironmentVariable 'SCOOP_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url 'https://get.scoop.sh' -DestinationPath $scoopInstallScript -Description 'scoop installer script' -ExpectedSha256 $scoopSha
& $scoopInstallScript -RunAsAdmin
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Users\ContainerAdministrator\scoop\shims',
    'C:\ProgramData\scoop\shims'
) | Out-Null
Assert-ContainerCommandAvailable -Name 'git' | Out-Null
Assert-ContainerCommandAvailable -Name 'scoop' | Out-Null
# Buckets: `scoop bucket add` exits 2 when the bucket already exists — and
# scoop's own installer pre-adds `main`, so that is the NORMAL state. The
# strict gate turned it fatal (2026-08-05), and output-sniffing for the WARN
# text proved unreliable (the child shim's warning bypasses 2>&1 capture).
# Deterministic check instead: a bucket IS a directory under <scoop>\buckets —
# skip the add when it exists, gate strictly when we genuinely add.
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
foreach ($bucket in @('main', 'extras', 'versions')) {
    if (Test-Path (Join-Path $scoopRoot "buckets\$bucket")) {
        Write-Host "==> scoop bucket add $bucket -- already present, skipped"
        continue
    }
    Invoke-ScoopStep -Description "scoop bucket add $bucket" -Command { scoop bucket add $bucket }.GetNewClosure()
}
Install-ScoopPackage -Package 'main/7zip'
Invoke-ScoopStep -Description 'scoop config use_external_7zip true' -Command { scoop config use_external_7zip true }

# Rust is provisioned by setup-rust-toolchain.ps1 via rustup WITH a default
# toolchain (single provider; Flutter's Cargokit hard-requires rustup). We
# deliberately install NO rust here: scoop rust would compete with the rustup
# proxies in CARGO_BIN, and a toolchain-LESS rustup would drop proxy shims that
# resolve no toolchain (the failure the old "never rustup" rule guarded against).

#endregion
#region 4. Vulkan LAN preseed + pinned installs (cmake/vulkan/flutter)
# Preseed the 275 MB SDK from the LAN webdav into scoop's cache under scoop's
# own cache name (app#version#first-7-of-sha256(url)): sdk.lunarg.com stalls
# out reproducibly from inside containers (2026-08-19, three ~20-min transfer
# deaths). scoop still verifies its manifest hash on install, so a stale or
# corrupt preseed fails open into the normal (retried) vendor download.
if ($env:VULKAN_PRESEED_ENDPOINT -and $VulkanVersion) {
    try {
        $vkVendorUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/vulkansdk-windows-X64-$VulkanVersion.exe"
        $vkUrlSha = [System.Security.Cryptography.SHA256]::Create()
        $vkTok = ([BitConverter]::ToString($vkUrlSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($vkVendorUrl))) -replace '-', '').ToLower().Substring(0, 7)
        $vkCacheDir = Join-Path $env:USERPROFILE 'scoop\cache'
        $null = New-Item -ItemType Directory -Force -Path $vkCacheDir
        $vkDest = Join-Path $vkCacheDir "vulkan#$VulkanVersion#$vkTok.exe"
        $vkSrc = "$($env:VULKAN_PRESEED_ENDPOINT)/preseed/vulkansdk-windows-X64-$VulkanVersion.exe"
        & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -o $vkDest $vkSrc
        if ($LASTEXITCODE -eq 0) {
            Write-Host "vulkan preseed: $vkDest ($([math]::Round((Get-Item $vkDest).Length / 1MB)) MB) from $vkSrc"
        } else {
            Remove-Item $vkDest -Force -ErrorAction SilentlyContinue
            Write-Warning "vulkan preseed fetch failed (exit $LASTEXITCODE) - falling back to the direct download"
        }
        $global:LASTEXITCODE = 0
    } catch {
        Write-Warning "vulkan preseed skipped: $($_.Exception.Message)"
    }
}
Install-ScoopPackage -Package 'main/vulkan' -Version $VulkanVersion

# ARM64 cross-compile libraries for the Vulkan SDK (2026-08-22).
#
# LunarG ships the aarch64 import libraries INSIDE the x64 Windows SDK, but as
# an OPTIONAL component that the default install does not select:
#     com.lunarg.vulkan.arm64  "ARM64 binaries for cross compiling on Windows x86_64"
#     Lib-ARM64 / Bin-ARM64    "for cross compiling from Intel based development environments"
# scoop runs the installer with the manifest's default component set, so without
# this step $VULKAN_SDK\Lib-ARM64 does not exist and an arm64 link against
# vulkan-1.lib silently falls back to the x64 import library (or fails).
#
# The SDK is a Qt Installer Framework package, so components are added after the
# fact through its maintenancetool. NB $env:VULKAN_SDK is not set yet -- that ENV
# lands further down Dockerfile.base -- so the path is derived from the scoop root.
#
# WARN-ONLY BY DEFAULT, opt-in hard gate via WINDOWS_ARM64_STRICT=1 -- the same
# shape as the CUDA stack check (verify-cuda-stack.sh / CUDA_STACK_STRICT=1).
#
# This started life as a hard `throw` with a WINDOWS_ARM64_STRICT=1 escape
# hatch, which was wrong twice over (2026-08-22):
#   1. The block is NOT arch-gated -- it runs on every base build, including a
#      plain amd64 one. A throw here kills the chain's most expensive layer for
#      BOTH lanes.
#   2. The hatch was unreachable. $env:WINDOWS_ARM64_STRICT is never set during
#      `docker build` unless the name is declared as an ARG, and buildctl
#      silently discards --build-arg for undeclared ARG names. There was no way
#      out except editing the Dockerfile.
# Combined with the fact that the maintenancetool invocation below has never
# been executed against a real base image, that made an unverified installer
# call able to brick the whole chain. Warning is the correct default until the
# step is observed working; flip a build to WINDOWS_ARM64_STRICT=1 once it is.
$armStrict = if (-not [string]::IsNullOrWhiteSpace($WindowsArm64Strict)) { $WindowsArm64Strict } else { $env:WINDOWS_ARM64_STRICT }
$vkRoot = Join-Path $env:USERPROFILE 'scoop\apps\vulkan\current'
$vkArm64Lib = Join-Path $vkRoot 'Lib-ARM64'
if (Test-Path $vkArm64Lib) {
    Write-Host "Vulkan ARM64 cross libraries already present ($vkArm64Lib)."
} else {
    $maintenanceTool = Join-Path $vkRoot 'maintenancetool.exe'
    if (Test-Path $maintenanceTool) {
        # Two documented argument shapes: current Qt IFW long options first, the
        # older short forms as a fallback (LunarG has shipped both).
        $argSets = @(
            @('--accept-licenses', '--default-answer', '--confirm-command', 'install', 'com.lunarg.vulkan.arm64'),
            @('--al', '--am', '-c', 'install', 'com.lunarg.vulkan.arm64')
        )
        foreach ($argSet in $argSets) {
            Write-Host "Adding Vulkan ARM64 component: maintenancetool $($argSet -join ' ')"
            & $maintenanceTool @argSet 2>&1 | ForEach-Object { Write-Host "  $_" }
            $global:LASTEXITCODE = 0
            if (Test-Path $vkArm64Lib) { break }
        }
    } else {
        Write-Warning "Vulkan maintenancetool.exe not found at $maintenanceTool - cannot add the ARM64 component."
    }

    if (Test-Path $vkArm64Lib) {
        Write-Host "Vulkan ARM64 cross libraries installed ($vkArm64Lib)."
    } elseif ($armStrict -eq '1') {
        throw ("Vulkan ARM64 component (com.lunarg.vulkan.arm64) is not installed: $vkArm64Lib is missing. " +
               'It is an optional component of the x64 SDK and is required to link an aarch64 target. ' +
               'WINDOWS_ARM64_STRICT=1 made this a hard gate.')
    } else {
        Write-Warning ("Vulkan ARM64 component (com.lunarg.vulkan.arm64) not installed: $vkArm64Lib is missing. " +
                       'The amd64 lane is unaffected; an arm64 target cannot link Vulkan until this is resolved. ' +
                       'Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}

# Flutter pinned to versions.env FLUTTER_VERSION (baked env) — previously the
# ONLY versions.env-managed tool installed floating here, so the Windows image
# could silently diverge from the Linux lane's Flutter. Empty env falls back to
# scoop's current manifest (standalone runs), same pattern as vulkan/cmake.
Install-ScoopPackage -Package 'extras/flutter' -Version ([string]$env:FLUTTER_VERSION) -Global
#endregion
#region 5. PINNED compiled-output packages + floating toolset + cache scrub
# ── PINNED: the three scoop packages that produce or shape compiled output ────
# llvm was DELIBERATELY UNPINNED until 2026-08-07, which left the base image --
# the most expensive layer in the chain -- unreproducible in its single most
# load-bearing component: clang-cl compiles the entire media chain, and five of
# the patches in windows/scripts/patches/ are written against a specific
# clang-cl's diagnostics. A rebuild months later would swap the compiler
# silently and fail ~2 h into media-core. Pins live in versions.env
# (LLVM_WINDOWS_VERSION / NINJA_WINDOWS_VERSION / NASM_WINDOWS_VERSION) and
# reach here as Dockerfile ARGs; verify-toolchain.ps1 asserts the resolved
# clang-cl against the pin so a silent scoop fallback fails the base build
# instead of the media build. versions.env's LLVM_RELEASE is a SEPARATE pin for
# the Linux lane -- the two lanes move independently on purpose.
Install-ScoopPackage -Package 'main/llvm'  -Version $LlvmVersion
Install-ScoopPackage -Package 'main/ninja' -Version $NinjaVersion
Install-ScoopPackage -Package 'main/nasm'  -Version $NasmVersion

# ── compiler-rt builtins for aarch64 (2026-08-23) ────────────────────────────
# scoop's main/llvm is the x64 Windows RELEASE, and LLVM ships compiler-rt for
# the HOST architecture only: the install contains clang_rt.builtins-x86_64.lib
# and nothing else (measured via probe-arm64-prereqs.ps1 Q5, which has checked
# for exactly this since the arm64 lane was designed and reported [FAIL]).
#
# That is not cosmetic. clang lowers 128-bit integer arithmetic to compiler-rt
# libcalls on aarch64, so the first component that does 64x64->128 math fails at
# LINK, not compile:
#     lld-link: error: undefined symbol: __udivti3
#     >>> referenced by gstutils.c:670 (gst_util_uint64_scale)
# ONNX Runtime, FFmpeg and OpenCV happen not to need it; GStreamer does.
#
# Installed UNCONDITIONALLY, like the MSVC ARM64 toolset and the Vulkan ARM64
# component: this is a shared layer, and gating it on an arch ARG would re-pay
# the chain's most expensive layers on every lane switch. Only the one static
# library is kept -- the archive is fetched, mined and deleted.
$llvmAppRoot = Join-Path $env:USERPROFILE 'scoop\apps\llvm\current'
$rtHost = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-x86_64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
$rtTarget = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($rtTarget.Count -gt 0) {
    Write-Host "compiler-rt builtins for aarch64 already present ($($rtTarget[0].FullName))."
} elseif ($rtHost.Count -eq 0) {
    Write-Warning ("clang_rt.builtins-x86_64.lib not found under $llvmAppRoot\lib\clang - cannot determine where to " +
                   'place the aarch64 counterpart. The LLVM layout changed; arm64 links needing __udivti3 will fail.')
} else {
    # Destination is derived from the HOST library's own directory, never
    # hardcoded: that is by construction the directory clang and every consumer
    # already search, so no discovery logic anywhere needs to learn a new path.
    $rtDestDir = $rtHost[0].Directory.FullName
    $rtArchive = Join-Path $env:TEMP "clang+llvm-$LlvmVersion-aarch64-pc-windows-msvc.tar.xz"
    # %2B, not a literal '+': that is the canonical browser_download_url GitHub's
    # own release API returns for this asset, and the unencoded form 404s.
    # Verified 2026-08-23 with a ranged GET (a HEAD is refused outright here, so
    # "HEAD failed" is NOT evidence the asset is missing -- it cost one wrong
    # conclusion already).
    $rtUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/clang%2Bllvm-$LlvmVersion-aarch64-pc-windows-msvc.tar.xz"
    $rtExtractDir = Join-Path $env:TEMP 'llvm-aarch64-rt'
    try {
        Write-Host "Fetching aarch64 compiler-rt from $rtUrl (large, one-time; only clang_rt.builtins-aarch64.lib is kept)"
        Invoke-DownloadWithRetry -Url $rtUrl -DestinationPath $rtArchive
        New-Item -Path $rtExtractDir -ItemType Directory -Force | Out-Null
        # bsdtar (Windows built-in tar.exe) matches member PATTERNS, so the whole
        # 700+ MB archive is streamed but only the one member lands on disk.
        & tar.exe -xf $rtArchive -C $rtExtractDir '*clang_rt.builtins-aarch64.lib'
        $global:LASTEXITCODE = 0
        $rtFound = @(Get-ChildItem -Path $rtExtractDir -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($rtFound.Count -gt 0) {
            Copy-Item -Path $rtFound[0].FullName -Destination $rtDestDir -Force
            Write-Host "compiler-rt builtins for aarch64 installed -> $(Join-Path $rtDestDir 'clang_rt.builtins-aarch64.lib')"
        } else {
            Write-Warning "clang_rt.builtins-aarch64.lib was not found inside $rtArchive - the upstream archive layout changed."
        }
    } catch {
        Write-Warning "aarch64 compiler-rt fetch failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -Path $rtArchive -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $rtExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $rtTarget = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($rtTarget.Count -eq 0) {
        # Same warn-by-default / opt-in-hard-gate shape as the Vulkan ARM64
        # component above, and for the same reason: this is a shared layer, so an
        # arm64-only prerequisite must not be able to break the amd64 build.
        $msg = ('compiler-rt builtins for aarch64 are NOT installed under ' + $llvmAppRoot + '\lib\clang. ' +
                'An arm64 target cannot link 128-bit integer arithmetic (__udivti3 / __umodti3 & co); ' +
                'GStreamer is known to need it. The amd64 lane is unaffected.')
        if ($armStrict -eq '1') { throw ($msg + ' WINDOWS_ARM64_STRICT=1 made this a hard gate.') }
        Write-Warning ($msg + ' Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}
# sccache is pinned for a DIFFERENT reason than the three above: it shapes no
# compiled output whatsoever. It is here because multi-tier caching
# (SCCACHE_MULTILEVEL_CHAIN, an ARG in Dockerfile.media-builder) requires
# >= v0.16.0, and an older sccache ignores that variable SILENTLY -- the local
# L0 tier would not exist, every compile would go back to a WebDAV round-trip,
# and no gate anywhere would notice. A speed feature that can vanish without a
# signal is exactly what this repo refuses to ship, so the version it needs is
# asserted rather than assumed.
#
# NOTE 2026-08-16: the chain is currently DEFAULTED OFF (WebDAV is the only
# cache) because BuildKit's Windows cache mounts lose writes into a directory an
# earlier RUN populated -- docs/windows-builds.md #99. The pin stays exactly
# because the two-tier layout is wanted back: dropping below 0.16 would make
# re-enabling it fail silently instead of loudly.
Install-ScoopPackage -Package 'main/sccache' -Version $SccacheVersion

# ── OpenSSL for aarch64 (2026-08-23) ─────────────────────────────────────────
# scoop installs ONE architecture per app, and that is the host's: the image gets
# lib\VC\x64\MD\libcrypto.lib and nothing else. Four GStreamer targets link
# OpenSSL and therefore fail at link on the cross lane (measured 2026-08-23, all
# four with the same error):
#   gst-plugins-bad ext/hls, ext/dtls, ext/aes, and glib-networking's openssl TLS backend
#   lld-link: error: libcrypto.lib(libcrypto-4-x64.dll): machine type x64 conflicts with arm64
# Losing them would cost HTTP Live Streaming, DTLS/WebRTC and AES on arm64.
#
# The scoop manifest already knows an arm64 source, so this uses the SAME upstream
# artifact scoop would, with the manifest's own SHA256:
#   "arm64": { "url": "https://slproweb.com/download/Win64ARMOpenSSL-4_0_1.exe" }
# It is installed ALONGSIDE the x64 one (never replacing it -- this layer is shared
# with the amd64 lane) into a fixed directory that the GStreamer build points
# pkg-config at on the cross lane.
#
# Warn-only, like the Vulkan ARM64 component above and for the same reason: an
# arm64-only prerequisite must not be able to break the amd64 build.
$sslArm64Root = 'C:\opt\openssl-arm64'
$sslArm64Lib = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($sslArm64Lib.Count -gt 0) {
    Write-Host "OpenSSL (aarch64) already present ($($sslArm64Lib[0].FullName))."
} else {
    $sslUrl  = 'https://slproweb.com/download/Win64ARMOpenSSL-4_0_1.exe'
    $sslSha  = '397146c4317e84dbad20f8a3222b0af6414db8db11a8a3bfe7de11990b39cbaa'
    $sslExe  = Join-Path $env:TEMP 'Win64ARMOpenSSL.exe'
    try {
        Write-Host "Fetching aarch64 OpenSSL from $sslUrl (installed beside the x64 build, never replacing it)"
        Invoke-DownloadWithRetry -Url $sslUrl -DestinationPath $sslExe
        $got = (Get-FileHash -LiteralPath $sslExe -Algorithm SHA256).Hash
        if ($got -ine $sslSha) { throw "sha256 mismatch: got $got, expected $sslSha (this is the hash scoop's own openssl manifest pins for the arm64 asset)" }
        # EXTRACT, do not run. The scoop manifest marks this asset
        # `"innosetup": true`, which is exactly how scoop installs it: with
        # innounp, never by executing the installer. Running it silently was
        # tried first (2026-08-23) and is what NOT to do -- the whole step took
        # 11.8 s including the 218 MB download, exited 0, and produced no files
        # at all, so a silent no-op looked like success.
        #
        # Extraction is also the right shape here for a second reason: this must
        # land BESIDE the x64 install without touching the registry or the
        # Windows system directory, and an extractor cannot do either.
        $innounp = (Get-Command innounp -ErrorAction SilentlyContinue).Source
        if (-not $innounp) {
            $cand = Join-Path $env:USERPROFILE 'scoop\apps\innounp\current\innounp.exe'
            if (Test-Path $cand) { $innounp = $cand }
        }
        if (-not $innounp) { throw 'innounp not found (scoop installs it for innosetup manifests such as openssl) - cannot extract the aarch64 OpenSSL package.' }
        New-Item -Path $sslArm64Root -ItemType Directory -Force | Out-Null
        # -x extract, -y overwrite, -d<dir> destination. Output is logged rather
        # than swallowed: the previous attempt failed silently precisely because
        # nothing looked at it.
        $unpOut = & $innounp -x -y "-d$sslArm64Root" $sslExe 2>&1
        $unpCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Write-Host "innounp exit=$unpCode; last lines:"
        @($unpOut) | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Warning "aarch64 OpenSSL fetch/install failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -Path $sslExe -Force -ErrorAction SilentlyContinue
    }

    # Resolve by SEARCH, never by assuming slproweb's layout -- the same discipline
    # the compiler-rt step uses. Whatever directory holds libcrypto.lib IS the lib
    # dir, and the consumer is told about it rather than guessing.
    $sslArm64Lib = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($sslArm64Lib.Count -gt 0) {
        Write-Host "OpenSSL (aarch64) installed -> $($sslArm64Lib[0].FullName)"
        # Log the shape once so the consumer side can be written against FACT.
        @('include', 'lib') | ForEach-Object {
            $d = Join-Path $sslArm64Root $_
            if (Test-Path $d) { Write-Host "  openssl-arm64/${_}: $((Get-ChildItem $d -Force | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', ')" }
        }
        $pcFound = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter '*.pc' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        Write-Host "  openssl-arm64 pkgconfig files: $(if ($pcFound) { $pcFound -join ', ' } else { 'NONE (the consumer authors its own .pc)' })"
    } elseif ($armStrict -eq '1') {
        throw "OpenSSL for aarch64 is not installed under $sslArm64Root. gst-plugins-bad's hls/dtls/aes and glib-networking's openssl backend cannot link on the cross lane. WINDOWS_ARM64_STRICT=1 made this a hard gate."
    } else {
        Write-Warning ("OpenSSL for aarch64 is not installed under $sslArm64Root. The amd64 lane is unaffected; on arm64, " +
                       "gst-plugins-bad's hls/dtls/aes and glib-networking's openssl TLS backend will fail to link. " +
                       'Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}

# ── FLOATING (deliberate): tools the build only INVOKES ───────────────────────
# None of these enter the compiled artifacts, so tracking scoop's current
# manifest costs nothing and saves a pin-bump treadmill. Move a package UP to
# the pinned block the moment it starts linking into shipped binaries.
# pkg-config: consumers' CMake `find_package(PkgConfig)` + `pkg_check_modules(...)` need
# the BINARY -- the image bakes PKG_CONFIG_PATH and the .pc files, but the source-built
# GStreamer (unlike the old MSI) ships no pkg-config tool. NOTE: scoop main has no
# `pkgconf` manifest; the package name is `pkg-config`.
# sccache LEFT this list on 2026-08-08 -- see the pinned block above. It is the
# one package here whose VERSION gates behaviour rather than output.
# Per-package via Install-ScoopPackage (2026-08-21): the former single
# 8-package Invoke-ScoopStep bypassed the 3-attempt retry + cache purge, so
# one transient SourceForge/GitHub blip on ANY of the 8 killed the whole base
# build — the precise failure the retry helper was added for on 2026-08-19.
foreach ($floatingPkg in @('nano', 'cppcheck', 'extras/nsis', 'main/uv', 'main/nuget', 'extras/zlib', 'main/openssl', 'main/pkg-config')) {
    Install-ScoopPackage -Package $floatingPkg
}

# CMake stable release via scoop (replaces the old cmake.org MSI download); the
# shim lands on the scoop user-shims PATH like every other tool installed here.
Install-ScoopPackage -Package 'main/cmake' -Version $CMakeVersion

# make + gawk BAKED INTO BASE (2026-08-05): build-ffmpeg-from-source.ps1 used
# to install both at RUN time ("if absent -> scoop install") — but their
# ezwinports manifests download from SourceForge, whose mirror-picker flakes
# killed a proof-run ffmpeg-warm solve ("URL is not valid" -> make missing ->
# nv-codec `make install` exit 127) after the SAME stage had passed twice
# that day. Baking them here makes the ffmpeg stage's runtime install a
# never-taken fallback: one SourceForge roulette per BASE build (cached),
# zero per chain run.
Install-ScoopPackage -Package 'main/make'
Install-ScoopPackage -Package 'main/gawk'

# Drop scoop's download cache — the installers (LLVM, Flutter, Vulkan SDK, ...) are
# already unpacked into the apps dir and only bloat this (large) layer otherwise.
Write-Host 'Clearing scoop download cache...'
scoop cache rm * 2>&1 | Out-Null

# Same-layer cleanup for the other caches this script fills: the WiX dotnet-tool
# install leaves its nupkgs in the NuGet cache (the tool is fully materialized at
# C:\WiX) and installers drop temp files. Must happen HERE, not in a later stage:
# the classic builder cannot shrink an already-committed layer from a later one.
foreach ($d in @("$env:USERPROFILE\.nuget\packages", "$env:LOCALAPPDATA\Temp")) {
    if (Test-Path $d) {
        Write-Host "Clearing $d ..."
        Remove-Item "$d\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion
