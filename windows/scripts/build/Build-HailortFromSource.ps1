# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds HailoRT for Windows (library + hailortcli) and installs it to a prefix.
.DESCRIPTION
    The Windows twin of build-hailort.sh (docs/hailo-support.md), without TAPPAS or the GStreamer
    binding; FetchContent's externals are staged at the Linux lane's commits for an offline configure.
.PARAMETER TargetArch
    '' resolves WINDOWS_TARGET_ARCH; 'arm64' cross-builds with clang-cl's target flag.
#>
param(
    [string]$SourceDir = 'C:\temp\hailort-src',
    [string]$InstallDir = '',
    [string]$BuildDir = 'C:\temp\hailort-build',
    [string]$HailortVersion = '',
    [string]$BuildType = 'Release',
    [string]$TargetArch = '',
    [switch]$SkipExternals
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in the flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot
$HailortVersion = Get-SourceBuildVersion -Value $HailortVersion -EnvironmentVariables @('HAILORT_VERSION') -DefaultValue '5.4.0'

# Fail on missing pins: an empty -ExpectedSha256 means "no check", so a stale versions.env would download unverified.
$hailortSourceSha = Get-SourceBuildVersion -EnvironmentVariables @('HAILORT_SOURCE_SHA256')
$protobufVersion = Get-SourceBuildVersion -EnvironmentVariables @('HAILO_PROTOBUF_VERSION')
$protobufSha = Get-SourceBuildVersion -EnvironmentVariables @('HAILO_PROTOBUF_SHA256')
if (-not $hailortSourceSha) { throw 'HAILORT_SOURCE_SHA256 is not set (stale versions.env in the parent image?) -- refusing to download unverified sources' }
if (-not $protobufVersion -or -not $protobufSha) { throw 'HAILO_PROTOBUF_VERSION/HAILO_PROTOBUF_SHA256 are not set (stale versions.env in the parent image?) -- refusing to download unverified sources' }

$targetArch = if ($TargetArch) { $TargetArch } else { Get-WindowsTargetArch }
Write-Host "=== HailoRT source build ($HailortVersion, $targetArch, Ninja+clang-cl) ==="

# The Linux lane's HAILO_EXTERNALS commits; re-derive from hailort/cmake/external/*.cmake at a bump.
$hailoExternals = @(
    @{ Name = 'cli11'; Url = 'https://github.com/hailo-ai/CLI11.git'; Commit = '242adfdb23957d30e3e56831e474020d0ac6c86c' },
    @{ Name = 'cpp-httplib'; Url = 'https://github.com/yhirose/cpp-httplib.git'; Commit = '51dee793fec2fa70239f5cf190e165b54803880f' },
    @{ Name = 'dotwriter'; Url = 'https://github.com/hailo-ai/DotWriter'; Commit = 'e5fa8f281adca10dd342b1d32e981499b8681daf' },
    @{ Name = 'eigen'; Url = 'https://gitlab.com/libeigen/eigen'; Commit = '3147391d946bb4b6c68edd901f2add6ac1f31f8c' },
    @{ Name = 'json'; Url = 'https://github.com/nlohmann/json.git'; Commit = '9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03' },
    @{ Name = 'minja'; Url = 'https://github.com/google/minja'; Commit = '58568621432715b0ed38efd16238b0e7ff36c3ba' },
    @{ Name = 'readerwriterqueue'; Url = 'https://github.com/cameron314/readerwriterqueue'; Commit = '435e36540e306cac40fcfeab8cc0a22d48464509' },
    @{ Name = 'spdlog'; Url = 'https://github.com/gabime/spdlog'; Commit = '27cb4c76708608465c413f6d0e6b8d99a4d84302' },
    @{ Name = 'tl-expected'; Url = 'https://github.com/TartanLlama/expected.git'; Commit = '1770e3559f2f6ea4a5fb4f577ad22aeb30fbd8e4' },
    @{ Name = 'xxhash'; Url = 'https://github.com/Cyan4973/xxHash'; Commit = 'bbb27a5efb85b92a0486cf361a8635715a53f6ba' }
)

function Resolve-HailortSourceRoot {
    # Test-Path first: under EAP=Stop, Get-ChildItem on a missing path errors despite SilentlyContinue.
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $hit = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'hailort\CMakeLists.txt') } |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

$sourceRoot = Resolve-HailortSourceRoot -Root $SourceDir
if (-not $sourceRoot) {
    Write-Host "Fetching hailo-ai/hailort v$HailortVersion (SHA-verified tarball)"
    $tarball = Join-Path $env:TEMP "hailort-$HailortVersion.tar.gz"
    Invoke-DownloadWithRetry -Url "https://github.com/hailo-ai/hailort/archive/refs/tags/v$HailortVersion.tar.gz" `
        -DestinationPath $tarball -Description "HailoRT $HailortVersion source" -ExpectSignature '' `
        -ExpectedSha256 $hailortSourceSha
    $extracted = Expand-SourceTarball -Archive $tarball -Destination $SourceDir
    Remove-Item $tarball -Force -ErrorAction SilentlyContinue
    Write-Host "HailoRT source at $extracted"
    $sourceRoot = Resolve-HailortSourceRoot -Root $SourceDir
}
if (-not $sourceRoot) { throw "HailoRT source tree (hailort\CMakeLists.txt) not found under $SourceDir" }

# One owner for the four patch-with-fallback call sites, which the code-dupes gate would count as copies.
function Invoke-HailortSourcePatch {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FallbackNote,
        [Parameter(Mandatory)][scriptblock]$Fallback
    )
    $null = Invoke-SourcePatchWithFallback -PatchFile (Join-Path $scriptAssetRoot "patches\hailo\$Name") -SourceDir $sourceRoot `
        -FallbackNote $FallbackNote -Fallback $Fallback
}

# bankers_round keys its x86 intrinsics on _MSC_VER, which clang-cl defines on every arch.
Invoke-HailortSourcePatch -Name '001-quantization-msvc-guard.patch' -FallbackNote 'falling back to an inline guard rewrite' -Fallback {
    Invoke-InlineRegexPatch -Path (Join-Path $sourceRoot 'hailort\libhailort\include\hailo\quantization.hpp') `
        -SkipIfMatch '!defined\(__clang__\)' `
        -Pattern '#if defined\(_MSC_VER\)' `
        -Replacement '#if defined(_MSC_VER) && !defined(__clang__) && (defined(_M_X64) || defined(_M_IX86))' `
        -Description 'hailort quantization: x86-only MSVC guard' `
        -WarnMessage 'quantization.hpp: the _MSC_VER guard was not found; the x86 intrinsics will fail on ARM64 or a bare x64 clang-cl. Verify the file.' | Out-Null
}

# clang-cl, unlike MSVC, requires `template<>` on an explicit specialization's member definitions.
Invoke-HailortSourcePatch -Name '002-ioctl-nullptr-template-specialization.patch' -FallbackNote 'falling back to inline template<> insertion' -Fallback {
    $ioctl = Join-Path $sourceRoot 'hailort\libhailort\src\vdma\driver\os\windows\driver_os_specific.cpp'
    foreach ($member in @('to_compatible', 'from_compatible')) {
        Invoke-InlineRegexPatch -Path $ioctl `
            -SkipIfMatch "(?m)^template<>`r?`n\S+ WindowsIoctlParamCast<nullptr_t>::$member" `
            -Pattern "(?m)^((?:\S+ )?WindowsIoctlParamCast<nullptr_t>::$member)" `
            -Replacement "template<>`n`$1" `
            -Description "hailort ioctl cast ${member}: explicit-specialization prefix" `
            -WarnMessage "driver_os_specific.cpp: $member definition not found; clang-cl will reject the file. Verify it." | Out-Null
    }
}

# The Windows filesystem.cpp omits the LockedFile destructor its header declares, so hailortcli does not link.
Invoke-HailortSourcePatch -Name '003-windows-lockedfile-dtor.patch' -FallbackNote 'falling back to inline destructor insertion' -Fallback {
    $fs = Join-Path $sourceRoot 'hailort\common\os\windows\filesystem.cpp'
    Invoke-InlineRegexPatch -Path $fs `
        -SkipIfMatch 'LockedFile::~LockedFile' `
        -Pattern '(?m)^(TempFile::~TempFile\(\)\r?\n\{\r?\n\})' `
        -Replacement "`$1`n`nLockedFile::~LockedFile()`n{`n}" `
        -Description 'hailort windows filesystem: LockedFile destructor' `
        -WarnMessage 'filesystem.cpp: TempFile::~TempFile not found; the LockedFile destructor cannot be inserted and hailortcli will not link. Verify it.' | Out-Null
}

# Upstream defines _AMD64_=1 for any 64-bit build, sending an aarch64 winnt.h down the x86 intrinsic path.
Invoke-HailortSourcePatch -Name '004-cmake-target-arch-macro.patch' -FallbackNote 'falling back to an inline arch-macro rewrite' -Fallback {
    $top = Join-Path $sourceRoot 'hailort\CMakeLists.txt'
    Invoke-InlineRegexPatch -Path $top `
        -SkipIfMatch 'CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64"' `
        -Pattern '(?m)^(    if \(CMAKE_SIZEOF_VOID_P EQUAL 8\)\r?\n        add_compile_definitions\(_AMD64_=1\))' `
        -Replacement "    if (CMAKE_SYSTEM_PROCESSOR STREQUAL `"ARM64`" OR CMAKE_SYSTEM_PROCESSOR STREQUAL `"arm64`")`n        add_compile_definitions(_ARM64_=1)`n    elseif (CMAKE_SIZEOF_VOID_P EQUAL 8)`n        add_compile_definitions(_AMD64_=1)" `
        -Description 'hailort CMakeLists: arch-aware Windows SDK macro' `
        -WarnMessage 'hailort/CMakeLists.txt: the pointer-size guard was not found; the ARM64 build will define _AMD64_ and winnt.h will fail. Verify it.' | Out-Null
}

if (-not $SkipExternals) {
    # HailoRT builds protobuf from the literal external/protobuf-src path; FETCHCONTENT_SOURCE_DIR_* does not reach it.
    $protobufSrc = Join-Path $sourceRoot 'hailort\external\protobuf-src'
    if (-not (Test-Path (Join-Path $protobufSrc 'CMakeLists.txt'))) {
        Write-Host "Staging protobuf v$protobufVersion (SHA-verified)"
        $protobufTar = Join-Path $env:TEMP "protobuf-$protobufVersion.tar.gz"
        Invoke-DownloadWithRetry -Url "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v$protobufVersion.tar.gz" `
            -DestinationPath $protobufTar -Description "protobuf $protobufVersion source" -ExpectSignature '' `
            -ExpectedSha256 $protobufSha
        # A --strip-components=1 via 7z, since git's MSYS tar mangles Windows paths.
        $extractRoot = Join-Path $env:TEMP "protobuf-$protobufVersion-extract"
        Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        $inner = Expand-SourceTarball -Archive $protobufTar -Destination $extractRoot
        New-Item -Path $protobufSrc -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $inner '*') -Destination $protobufSrc -Recurse -Force
        Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $protobufTar -Force -ErrorAction SilentlyContinue
    }
    foreach ($ext in $hailoExternals) {
        $dir = Join-Path $sourceRoot "hailort\external\$($ext.Name)-src"
        if ((Test-Path $dir) -and (Get-ChildItem $dir -ErrorAction SilentlyContinue | Select-Object -First 1)) { continue }
        Write-Host "Staging external $($ext.Name) @ $($ext.Commit.Substring(0, 10))"
        # Invoke-GitClone fetches a 40-hex -Tag as a commit; git clone --branch <hash> would fail.
        Invoke-GitClone -RepoUrl $ext.Url -Tag $ext.Commit -SourceDir $dir | Out-Null
        $head = (& git -C $dir rev-parse HEAD).Trim()
        if ($head -ne $ext.Commit) { throw "external $($ext.Name) is $head, expected $($ext.Commit)" }
        & git -C $dir submodule update --init --recursive --quiet
        if ($LASTEXITCODE -ne 0) { throw "external $($ext.Name): submodule update failed" }
    }
}

# Configure and build
$cmakeExtra = @(
    '-DHAILO_BUILD_TOOLS=OFF'
    '-DHAILO_BUILD_GSTREAMER=OFF'
    '-DHAILO_BUILD_EXAMPLES=OFF'
    '-DHAILO_BUILD_UT=OFF'
    '-DHAILO_OFFLINE_COMPILATION=ON'
    "-DFETCHCONTENT_SOURCE_DIR_PROTOBUF=$((Join-Path $sourceRoot 'hailort\external\protobuf-src') -replace '\\', '/')"
)
# A full :FILEPATH, or a bare llvm-lib becomes C:\llvm-lib and every static-lib step dies silently.
$cmakeExtra += Get-LlvmArchiverCmakeArg
# Nested FetchContent builds survive a top-level clean, and a stale compiler cache poisons configure.
Get-ChildItem (Join-Path $sourceRoot 'hailort\external') -Directory -Filter '*-build' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $sourceRoot 'hailort\external') -Directory -Filter '*-install' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue

Invoke-CmakeConfigure -SourceDir $sourceRoot -BuildDir $BuildDir -InstallPrefix $InstallDir `
    -BuildType $BuildType -ExtraArgs $cmakeExtra -TargetArch $targetArch

$jobs = Get-BuildJobCount
Write-Host "Building HailoRT (jobs=$jobs)"
# Not piped to Out-Null: ninja's output, compiler errors included, is on the success stream.
Invoke-NinjaBuildWithRetry -BuildDir $BuildDir -Install -InstallConfig $BuildType

# Verify
$hailortDll = Get-ChildItem -Path $InstallDir -Filter 'libhailort.dll' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
$hailortCli = Get-ChildItem -Path $InstallDir -Filter 'hailortcli.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $hailortDll) { throw "libhailort.dll not found under $InstallDir after install" }
if (-not $hailortCli) { throw "hailortcli.exe not found under $InstallDir after install" }
# The image-wide arch gate checks this too, but a mismatch here names the component.
$expectedMachine = Get-PeMachineType -Arch $targetArch
$actualMachine = Get-PeFileMachine -Path $hailortDll.FullName
if ($actualMachine -ne $expectedMachine) {
    throw ("hailort.dll PE machine 0x{0:X4} != expected 0x{1:X4} for $targetArch" -f $actualMachine, $expectedMachine)
}
Write-Host ("HailoRT verified: {0} (PE 0x{1:X4}), {2}" -f $hailortDll.Name, $actualMachine, $hailortCli.Name)

Complete-SourceBuild -Banner "=== HailoRT build complete ($targetArch) ===" -SourceDir $SourceDir
