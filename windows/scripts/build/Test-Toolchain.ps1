# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

Assert-ContainerCommandAvailable -Name 'flutter' | Out-Null
Assert-ContainerCommandAvailable -Name 'wix' | Out-Null
Assert-ContainerCommandAvailable -Name 'clang-cl' | Out-Null
Assert-ContainerCommandAvailable -Name 'lld-link' | Out-Null
Assert-ContainerCommandAvailable -Name 'cmake' | Out-Null

# LLVM is PINNED on Windows since 2026-08-07 (versions.env LLVM_WINDOWS_VERSION,
# forwarded through Dockerfile.base -> Install-ScoopTools.ps1). Assert it HERE, in
# the base build: a silent scoop fallback to a different clang-cl otherwise
# surfaces ~2 h into media-core as a patch that no longer applies. Same shape as
# the cmake assert below. versions.env's LLVM_RELEASE pins the LINUX lane only.
$clangOut = & clang-cl --version
if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed (exit code $LASTEXITCODE)" }
$clangBanner = $clangOut | Select-Object -First 1
Write-Host ("clang-cl (provenance): {0}" -f $clangBanner)
$expectedLlvm = Resolve-ContainerImageValue -EnvironmentVariable 'LLVM_WINDOWS_VERSION' -DefaultValue ''
if ($expectedLlvm -and $clangBanner -notmatch [regex]::Escape($expectedLlvm)) {
    throw ("clang-cl version mismatch: expected $expectedLlvm (versions.env LLVM_WINDOWS_VERSION), got '$clangBanner'. " +
        'Either scoop could not serve the pinned manifest, or the pin was bumped without rebuilding this layer. ' +
        'A version change here invalidates the clang-cl-shaped patches under windows/scripts/patches/ — ' +
        're-run windows/scripts/tests/Test-PatchesApplyClean.ps1 after a deliberate bump.')
}

# ninja + nasm are pinned for the same reason (build-graph executor and the x86 SIMD
# assembler both shape what ships). Cheap asserts, same failure economics.
# Attribution, twice corrected on 2026-08-24: until that day FFmpeg passed an
# unconditional --disable-x86asm (nasm assembled nothing for it; GStreamer's
# openh264 was its only consumer, Build-GstreamerFromSource.ps1:482). Since
# backlog #119 the amd64 FFmpeg build enables x86asm again (the flag had no
# recorded reason -- see Build-FfmpegFromSource.ps1's #119 block), so nasm
# now shapes FFmpeg's x86 SIMD too and this assert is load-bearing for both.
#
# sccache is here for a DIFFERENT reason and it is the important one to keep:
# it shapes nothing that ships, but multi-tier caching
# (SCCACHE_MULTILEVEL_CHAIN=disk,webdav, wired in Dockerfile.media-builder)
# needs >= v0.16.0, and an older sccache ignores that variable SILENTLY. Without
# this assert the local L0 tier could simply not exist -- every compile back to
# a WebDAV round-trip, no error, nothing slower than "a bit slower than we
# remember". That is unfalsifiable in a log, so it is asserted here instead.
foreach ($pinned in @(
        @{ Tool = 'ninja';   Args = @('--version'); EnvVar = 'NINJA_WINDOWS_VERSION' },
        @{ Tool = 'nasm';    Args = @('-v');        EnvVar = 'NASM_WINDOWS_VERSION' },
        @{ Tool = 'sccache'; Args = @('--version'); EnvVar = 'SCCACHE_WINDOWS_VERSION' })) {
    $expected = Resolve-ContainerImageValue -EnvironmentVariable $pinned.EnvVar -DefaultValue ''
    if (-not $expected) { continue }
    # Real splatting (@<var>), not an array subexpression: the latter only works
    # for native commands by accident of PS argument flattening.
    $toolArgs = $pinned.Args
    $banner = (& $pinned.Tool @toolArgs 2>&1 | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "$($pinned.Tool) $($toolArgs -join ' ') failed (exit code $LASTEXITCODE)" }
    if ($banner -notmatch [regex]::Escape($expected)) {
        throw "$($pinned.Tool) version mismatch: expected $expected (versions.env $($pinned.EnvVar)), got '$banner'"
    }
    Write-Host "$($pinned.Tool) OK: $banner"
}

# sccache must resolve to the CARGO-BUILT binary, not scoop's.
#
# This cannot be a version assert: sccache's main branch still reports package
# version 0.17.0, so `--version` is IDENTICAL for the released build and the
# source build carrying mozilla/sccache#2722. The only observable difference is
# WHERE the binary comes from — CARGO_BIN precedes the scoop shims on PATH, so
# a successful source build wins and a failed/skipped one silently does not.
#
# What is at stake: without #2722, wrapping nvcc on CUDA 13.3 does not merely
# miss the cache, it FAILS the build (`fatbinary fatal: Could not open input
# file '<tu>.compute_80.cubin'`) — an hour into the media stage. Catch it here,
# in the base, in milliseconds.
$sccacheResolved = (Get-Command sccache -ErrorAction SilentlyContinue)
if (-not $sccacheResolved) {
    throw 'sccache not found on PATH after the base build.'
}
$cargoBinDir = [string]$env:CARGO_BIN
if ([string]::IsNullOrWhiteSpace($cargoBinDir)) { $cargoBinDir = Join-Path $env:USERPROFILE '.cargo\bin' }
if ($sccacheResolved.Source -notlike (Join-Path $cargoBinDir '*')) {
    throw ("sccache resolves to '$($sccacheResolved.Source)', not the cargo-built one under '$cargoBinDir'. " +
        'The source build (Install-RustToolchain.ps1, SCCACHE_GIT_REV) did not take, so nvcc caching would ' +
        'fail the media stage with a fatbinary error ~1h in. Released sccache cannot wrap nvcc on CUDA 13.3 ' +
        '(mozilla/sccache#2722, merged after v0.17.0 shipped).')
}
Write-Host "sccache source-build OK: $($sccacheResolved.Source)"

# CMake is pinned (scoop main/cmake@CMAKE_VERSION from versions.env, baked by
# Import-Versions.ps1) -- fail the base build here on a pin mismatch instead of
# surfacing it hours later in a media build or the smoke test.
$expectedCmake = Resolve-ContainerImageValue -EnvironmentVariable 'CMAKE_VERSION' -DefaultValue ''
if ($expectedCmake) {
    $cmakeOut = & cmake --version
    if ($LASTEXITCODE -ne 0) { throw "cmake --version failed (exit code $LASTEXITCODE)" }
    $cmakeBanner = $cmakeOut | Select-Object -First 1
    if ($cmakeBanner -notmatch [regex]::Escape($expectedCmake)) {
        throw "cmake version mismatch: expected $expectedCmake (versions.env), got '$cmakeBanner'"
    }
    Write-Host "cmake OK: $cmakeBanner"
}

# Resolve wix.exe via Get-Command (single source of truth, survives WiX install relocations
# instead of hardcoding C:\WiX\wix.exe). Capture-then-read keeps the .Source deref
# StrictMode-safe on the miss path.
$wixCommandInfo = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wixCommandInfo) { throw 'wix.exe not found on PATH (Assert-ContainerCommandAvailable failed)' }
$wixCmd = $wixCommandInfo.Source

& $wixCmd --version | Out-Host
if ($LASTEXITCODE -ne 0) { throw "wix --version failed (exit code $LASTEXITCODE)" }
$wixExtensions = & $wixCmd extension list --global 2>&1
$wixExtensions | Out-Host
# Gate BEFORE the extension assert: a broken wix would otherwise masquerade as
# "extension not installed" and send the operator chasing the wrong problem.
if ($LASTEXITCODE -ne 0) { throw "wix extension list --global failed (exit code $LASTEXITCODE): $wixExtensions" }
# Assert against the same versions.env value the install used (no hand-synced literal).
$wixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.6'
if (-not ($wixExtensions | Select-String -SimpleMatch "WixToolset.UI.wixext $wixUiExtVersion")) {
    throw "Required WiX extension not installed: WixToolset.UI.wixext $wixUiExtVersion"
}


# ---------------------------------------------------------------------------
# ARM64 cross-target readiness (2026-08-22)
#
# The Windows build HOST is always amd64 (no arm64 Windows container base image
# exists), so an arm64 lane is a CROSS build out of this same x64 image. Three
# things must be true for that to work, and all three are cheap to check here
# in the base -- where a failure costs one clear message instead of surfacing
# hours into a media build as an opaque link error:
#
#   1. clang-cl can actually emit aarch64 code.
#   2. Microsoft's ARM64 CRT/import libraries are present (clang-cl targets the
#      MSVC ABI, so it links against them even though cl.exe is never invoked).
#   3. The Windows SDK and Vulkan ARM64 import libraries are present.
#
# Compile-only on purpose: VsDevCmd has not run in this layer, so INCLUDE/LIB
# are unset and a full link would fail for reasons unrelated to the toolchain.
# The PE machine-type gate over the produced payload runs later, at the end of
# Dockerfile.media-merge-builder's `built` stage (Test-TargetArch.ps1 over
# C:\runtime) -- that is the first point where the whole media tree exists.
# ---------------------------------------------------------------------------
$archModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if (-not (Test-Path $archModulePath)) { throw "Required module not found: $archModulePath" }
Import-Module $archModulePath -Force

$armTriple  = Get-ClangTargetTriple -Arch 'arm64'
$armMachine = Get-PeMachineType -Arch 'arm64'

$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('archprobe-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $probeDir
try {
    $probeSrc = Join-Path $probeDir 'probe.c'
    Set-Content -LiteralPath $probeSrc -Value 'int probe(int x) { return x + 1; }' -Encoding ASCII
    $probeObj = Join-Path $probeDir 'probe.obj'

    & clang-cl "--target=$armTriple" /c $probeSrc "/Fo$probeObj" 2>&1 | ForEach-Object { Write-Host "  $_" }
    $probeFailure = ''
    if ($LASTEXITCODE -ne 0) {
        $probeFailure = "clang-cl failed to compile for $armTriple (exit $LASTEXITCODE)"
    } elseif (-not (Test-Path $probeObj)) {
        $probeFailure = "clang-cl produced no object file for $armTriple"
    } else {
        # An unlinked COFF object begins with IMAGE_FILE_HEADER, so the first two
        # bytes ARE the Machine field (little-endian) - no MZ/PE offset walk needed.
        $objBytes = [System.IO.File]::ReadAllBytes($probeObj)
        if ($objBytes.Length -lt 2) {
            $probeFailure = "clang-cl produced a truncated object file for $armTriple"
        } else {
            # [int] casts are LOAD-BEARING, not style. PowerShell's -shl keeps the
            # LEFT operand's type: [byte]0xAA -shl 8 is 0, not 0xAA00. Without the
            # casts this reads 0x0064 for a perfectly good ARM64 object and reports
            # a false FAIL -- the single most damaging way this check could be
            # wrong, since it would condemn a working cross toolchain.
            $objMachine = [int]$objBytes[0] -bor ([int]$objBytes[1] -shl 8)
            if ($objMachine -ne $armMachine) {
                $probeFailure = ('clang-cl targeted the wrong architecture: object machine 0x{0:X4}, expected 0x{1:X4} ({2}).' -f $objMachine, $armMachine, $armTriple)
            } else {
                Write-Host ('clang-cl cross-compiles to {0} (object machine 0x{1:X4}) OK' -f $armTriple, $objMachine)
            }
        }
    }
    if ($probeFailure) {
        if ($env:WINDOWS_ARM64_STRICT -eq '1') { throw $probeFailure }
        Write-Warning "$probeFailure (amd64 lane unaffected; WINDOWS_ARM64_STRICT=1 makes this fatal)"
    }
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# MSVC ARM64 CRT + import libraries (installed by VC.Tools.ARM64).
$msvcRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\$(Resolve-ContainerImageValue -EnvironmentVariable 'VISUAL_STUDIO_VERSION' -DefaultValue '18')\BuildTools\VC\Tools\MSVC"
if (-not (Test-Path $msvcRoot)) {
    $msvcRoot = Join-Path $env:ProgramFiles "Microsoft Visual Studio\$(Resolve-ContainerImageValue -EnvironmentVariable 'VISUAL_STUDIO_VERSION' -DefaultValue '18')\BuildTools\VC\Tools\MSVC"
}
$msvcArm64Lib = Get-ChildItem -Path $msvcRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'lib\arm64\libcmt.lib' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $msvcArm64Lib) {
    $msg = ("MSVC ARM64 libraries missing under $msvcRoot (expected <ver>\lib\arm64\libcmt.lib). " +
        'The VC.Tools.ARM64 component is not installed; clang-cl cannot link an aarch64 target without it.')
    if ($env:WINDOWS_ARM64_STRICT -eq '1') { throw $msg } else { Write-Warning "$msg (amd64 lane unaffected; WINDOWS_ARM64_STRICT=1 makes this fatal)" }
} else {
    Write-Host "MSVC ARM64 libraries OK: $msvcArm64Lib"
}

# Windows SDK ARM64 import libraries. The SDK component is architecture-complete,
# so this asserts an expectation rather than a separate install step.
$sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$sdkArm64 = Get-ChildItem -Path $sdkLibRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'um\arm64\kernel32.lib' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $sdkArm64) {
    $msg = ("Windows SDK ARM64 import libraries missing under $sdkLibRoot (expected <ver>\um\arm64\kernel32.lib). " +
        'Reinstall the Windows 11 SDK component with ARM64 support.')
    if ($env:WINDOWS_ARM64_STRICT -eq '1') { throw $msg } else { Write-Warning "$msg (amd64 lane unaffected; WINDOWS_ARM64_STRICT=1 makes this fatal)" }
} else {
    Write-Host "Windows SDK ARM64 libraries OK: $sdkArm64"
}

# Vulkan ARM64 cross libraries (optional LunarG component com.lunarg.vulkan.arm64,
# added by Install-ScoopTools.ps1). Same escape hatch as the install step.
# Warn-only by default, opt-in hard gate via WINDOWS_ARM64_STRICT=1 -- mirrors
# Install-ScoopTools.ps1's install-side gate and the CUDA_STACK_STRICT idiom.
# This must NOT throw by default: it runs in the shared base image, so a hard
# failure here would block the amd64 lane over an arm64-only prerequisite.
if ($env:VULKAN_SDK) {
    $vkArmLib = Join-Path $env:VULKAN_SDK (Get-VulkanLibDirName -Arch 'arm64')
    if (Test-Path (Join-Path $vkArmLib 'vulkan-1.lib')) {
        Write-Host "Vulkan ARM64 import library OK: $vkArmLib"
    } elseif ($env:WINDOWS_ARM64_STRICT -eq '1') {
        throw ("Vulkan ARM64 import library missing at $vkArmLib. The com.lunarg.vulkan.arm64 component " +
            'is optional in the x64 SDK and Install-ScoopTools.ps1 must add it. ' +
            'WINDOWS_ARM64_STRICT=1 made this a hard gate.')
    } else {
        Write-Warning ("Vulkan ARM64 import library missing at $vkArmLib - an arm64 target cannot link Vulkan. " +
            'The amd64 lane is unaffected. Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
} else {
    Write-Warning 'VULKAN_SDK is not set - skipping the Vulkan ARM64 import-library check.'
}
