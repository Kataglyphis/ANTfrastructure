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

# Toolchain provenance manifest, best-effort per probe; see docs/windows-builds.md § Complete-Container.ps1.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1') -Force

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

# The MSVC toolset floats inside the pinned VS major; its dir name is the version.
$msvcToolset = $null
try {
    $vsRoot = Resolve-VsBuildToolsRoot
    if ($vsRoot) {
        $toolsetDir = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
        if ($toolsetDir) { $msvcToolset = $toolsetDir.Name }
    }
} catch { Write-Host "toolchain-manifest: MSVC toolset probe skipped ($($_.Exception.Message))" }

# Read from directories: `flutter --version` would trigger a first-run download.
function Get-DirectoryVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        # The leaf of $Path is the version; otherwise the highest child dir name is.
        [switch]$LeafIsVersion
    )
    try {
        if (-not (Test-Path $Path)) { return $null }
        if ($LeafIsVersion) { return (Split-Path $Path -Leaf) }
        # Numeric where the name parses as a version: a lexical sort ranks 14.9.x above 14.10.x.
        $child = Get-ChildItem $Path -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'current' } |
            Sort-Object -Property @{ Expression = { $v = $null; if ([version]::TryParse($_.Name, [ref]$v)) { $v } else { $null } } }, Name |
            Select-Object -Last 1
        if ($child) { return $child.Name }
        return $null
    } catch {
        Write-Host "toolchain-manifest: directory probe of '$Path' skipped ($($_.Exception.Message))"
        return $null
    }
}

# Skipping scoop's `current` junction records the version, not the string "current".
$vulkanResolved = Get-DirectoryVersion -Path 'C:\Users\ContainerAdministrator\scoop\apps\vulkan'
$flutterResolved = Get-DirectoryVersion -Path 'C:\ProgramData\scoop\apps\flutter'
$sdkResolved = Get-DirectoryVersion -Path 'C:\Program Files (x86)\Windows Kits\10\Include'

$manifest = [ordered]@{
    schema      = 'kataglyphis/windows-toolchain-manifest@1'
    generated   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # The OS layer everything else sits on (versions.env WINDOWS_BASE_DIGEST).
    osBaseDigest = [string]$env:WINDOWS_BASE_DIGEST
    windowsLtsc  = [string]$env:WINDOWS_LTSC
    # A resolved value that differs from its pin means the layer predates the pin.
    pinned = [ordered]@{
        llvm            = [ordered]@{ pin = [string]$env:LLVM_WINDOWS_VERSION;  resolved = (Get-ToolBanner -Exe 'clang-cl') }
        ninja           = [ordered]@{ pin = [string]$env:NINJA_WINDOWS_VERSION; resolved = (Get-ToolBanner -Exe 'ninja') }
        nasm            = [ordered]@{ pin = [string]$env:NASM_WINDOWS_VERSION;  resolved = (Get-ToolBanner -Exe 'nasm' -Arguments @('-v')) }
        # Pinned because an sccache older than v0.16.0 silently ignores the multi-tier config.
        sccache         = [ordered]@{ pin = [string]$env:SCCACHE_WINDOWS_VERSION; resolved = (Get-ToolBanner -Exe 'sccache') }
        cmake           = [ordered]@{ pin = [string]$env:CMAKE_VERSION;         resolved = (Get-ToolBanner -Exe 'cmake') }
        vulkanSdk       = [ordered]@{ pin = [string]$env:VULKAN_VERSION;        resolved = $vulkanResolved }
        git             = [ordered]@{ pin = [string]$env:GIT_VERSION;           resolved = (Get-ToolBanner -Exe 'git') }
        flutter         = [ordered]@{ pin = [string]$env:FLUTTER_VERSION;       resolved = $flutterResolved }
        # The VS pin is only the major; resolved is the toolset Build-OnnxGenaiFromSource.ps1's yvals_core.h patch targets.
        visualStudio    = [ordered]@{ pin = [string]$env:VISUAL_STUDIO_VERSION; resolved = $msvcToolset }
        windowsSdkBuild = [ordered]@{ pin = [string]$env:WINDOWS_SDK_BUILD;     resolved = $sdkResolved }
    }
    # Floating inputs: the resolved value is the only record.
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

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0