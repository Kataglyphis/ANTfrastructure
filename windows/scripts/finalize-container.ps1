# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Enable long paths for deep CMake/npm/cargo dependency trees
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
# Trust all directories as git-safe (suppresses ownership mismatch in container)
git config --global --add safe.directory '*'
if ($LASTEXITCODE -ne 0) { throw "git config --global --add safe.directory '*' failed (exit code $LASTEXITCODE)" }
# Enable git to handle paths >260 characters
git config --global core.longpaths true
if ($LASTEXITCODE -ne 0) { throw "git config --global core.longpaths true failed (exit code $LASTEXITCODE)" }

# ── Toolchain provenance manifest ────────────────────────────────────────────
# "Which compiler built this?" must be answerable from the ARTIFACT, not from a
# build log that ages out of out\windows-build-logs\. The base build already
# resolved every one of these (verify-toolchain.ps1 logs clang-cl,
# setup-vs.ps1 logs the bootstrapper hash) — this writes them where they
# survive into the 49 GB final image, which inherits this layer unchanged.
#
# It also makes lane parity mechanical: `diff` the manifest out of a classic
# windows-* image and a bk-* image instead of eyeballing two build logs. And it
# records the RESOLVED value of everything that is still deliberately floating
# (the VS toolset inside major 18, the non-compiled scoop tools), which is the
# only provenance those have.
#
# Every probe is best-effort: this is the last step of a multi-hour layer, so a
# missing optional tool records null rather than throwing the build away.
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1') -Force

function Get-ToolBanner {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @('--version'),
        # Some tools print the interesting line second (rustup, nasm variants).
        [int]$Line = 0
    )
    try {
        if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }
        $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        if ($out.Count -le $Line) { return $null }
        return $out[$Line].Trim()
    } catch {
        Write-Host "toolchain-manifest: '$Exe' probe skipped ($($_.Exception.Message))"
        return $null
    }
}

# MSVC toolset: the directory name under VC\Tools\MSVC IS the version, and it is
# the value that actually floats (setup-vs.ps1 pins only the MAJOR, via the
# aka.ms/vs/<major>/release channel). Highest wins if a rebuild ever stacks two.
$msvcToolset = $null
try {
    $vsRoot = Resolve-VsBuildToolsRoot
    if ($vsRoot) {
        $toolsetDir = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
        if ($toolsetDir) { $msvcToolset = $toolsetDir.Name }
    }
} catch { Write-Host "toolchain-manifest: MSVC toolset probe skipped ($($_.Exception.Message))" }

# Directory-probed versions: cheaper and safer than running the tool. `flutter
# --version` in particular triggers Flutter's first-run bootstrap (a download)
# inside what is supposed to be a metadata step, so read the scoop app dir
# instead. Same for the Vulkan SDK, and for the SDK build the Windows Kits
# Include\<build> dir IS the installed version.
function Get-DirectoryVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        # $true: the leaf of $Path is itself the version. $false: pick the
        # highest-sorting child directory name.
        [switch]$LeafIsVersion
    )
    try {
        if (-not (Test-Path $Path)) { return $null }
        if ($LeafIsVersion) { return (Split-Path $Path -Leaf) }
        $child = Get-ChildItem $Path -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'current' } | Sort-Object Name | Select-Object -Last 1
        if ($child) { return $child.Name }
        return $null
    } catch {
        Write-Host "toolchain-manifest: directory probe of '$Path' skipped ($($_.Exception.Message))"
        return $null
    }
}

# scoop's `current` is a junction to the versioned dir — resolve THROUGH it so
# the recorded value is the version, not the string "current".
$vulkanResolved = Get-DirectoryVersion -Path 'C:\Users\ContainerAdministrator\scoop\apps\vulkan'
$flutterResolved = Get-DirectoryVersion -Path 'C:\ProgramData\scoop\apps\flutter'
$sdkResolved = Get-DirectoryVersion -Path 'C:\Program Files (x86)\Windows Kits\10\Include'

$manifest = [ordered]@{
    schema      = 'kataglyphis/windows-toolchain-manifest@1'
    generated   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # The OS layer everything else sits on (versions.env WINDOWS_BASE_DIGEST).
    osBaseDigest = [string]$env:WINDOWS_BASE_DIGEST
    windowsLtsc  = [string]$env:WINDOWS_LTSC
    # PINNED inputs — value here should always equal the versions.env pin; a
    # difference means the layer predates the pin (or the pin was bumped
    # without a rebuild), which is exactly what this file exists to expose.
    pinned = [ordered]@{
        llvm            = [ordered]@{ pin = [string]$env:LLVM_WINDOWS_VERSION;  resolved = (Get-ToolBanner -Exe 'clang-cl') }
        ninja           = [ordered]@{ pin = [string]$env:NINJA_WINDOWS_VERSION; resolved = (Get-ToolBanner -Exe 'ninja') }
        nasm            = [ordered]@{ pin = [string]$env:NASM_WINDOWS_VERSION;  resolved = (Get-ToolBanner -Exe 'nasm' -Arguments @('-v')) }
        # Moved up from `floating` on 2026-08-08. It shapes nothing that ships;
        # it is pinned because multi-tier caching needs >= v0.16.0 and an older
        # sccache ignores the config silently. Recording pin-vs-resolved here
        # makes "did this image actually get the two-tier cache?" answerable
        # from the ARTIFACT, which a log cannot do once it ages out.
        sccache         = [ordered]@{ pin = [string]$env:SCCACHE_WINDOWS_VERSION; resolved = (Get-ToolBanner -Exe 'sccache') }
        cmake           = [ordered]@{ pin = [string]$env:CMAKE_VERSION;         resolved = (Get-ToolBanner -Exe 'cmake') }
        vulkanSdk       = [ordered]@{ pin = [string]$env:VULKAN_VERSION;        resolved = $vulkanResolved }
        git             = [ordered]@{ pin = [string]$env:GIT_VERSION;           resolved = (Get-ToolBanner -Exe 'git') }
        flutter         = [ordered]@{ pin = [string]$env:FLUTTER_VERSION;       resolved = $flutterResolved }
        # NB: the VS pin is only the MAJOR — `resolved` is the MSVC toolset that
        # actually floats inside it, which is what the yvals_core.h patch in
        # build-onnx-genai-from-source.ps1 is written against.
        visualStudio    = [ordered]@{ pin = [string]$env:VISUAL_STUDIO_VERSION; resolved = $msvcToolset }
        windowsSdkBuild = [ordered]@{ pin = [string]$env:WINDOWS_SDK_BUILD;     resolved = $sdkResolved }
    }
    # FLOATING inputs — no pin to compare against, so the resolved value IS the
    # record. This is the half that a bare version pin can never give you.
    floating = [ordered]@{
        lldLink   = (Get-ToolBanner -Exe 'lld-link')
        rustc     = (Get-ToolBanner -Exe 'rustc')
        cargo     = (Get-ToolBanner -Exe 'cargo')
        uv        = (Get-ToolBanner -Exe 'uv')
        pwsh      = "$($PSVersionTable.PSVersion)"
        openssl   = (Get-ToolBanner -Exe 'openssl' -Arguments @('version'))
        pkgConfig = (Get-ToolBanner -Exe 'pkg-config')
    }
}

$manifestPath = 'C:\toolchain-manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
Write-Host "Wrote toolchain provenance manifest: $manifestPath"
Write-Host (Get-Content $manifestPath -Raw)

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0