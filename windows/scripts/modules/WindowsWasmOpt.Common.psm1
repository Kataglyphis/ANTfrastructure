# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

# WindowsWasmOpt.Common - binaryen/wasm-opt bootstrap and optimisation helper.
# The Windows twin of linux/scripts/lib/wasm-opt.sh.
#
# Two things every "check/shrink the wasm bundle" script needs and nothing
# project-specific:
#   1. a wasm-opt binary - not installed on most machines and not worth a
#      package-manager dependency, so a pinned, SHA-verified binaryen release is
#      fetched on demand and put on PATH
#   2. the wasm feature flags that release has to be told about, because
#      wgpu/naga-style toolchains emit instructions wasm-opt's validator
#      rejects by default
#
# The version and the per-platform checksums come from the canonical
# linux/scripts/01-core/versions.env (BINARYEN_VERSION,
# BINARYEN_<PLATFORM>_<ARCH>_SHA256), the same file the bash twin reads, so the
# pin exists in exactly one place across the two languages.
#
# This module is project-agnostic: the size budget, crate name and output paths
# stay in the consuming script.

Set-StrictMode -Version Latest

# Import shared helpers (ConvertFrom-VersionsEnv, Invoke-DownloadWithRetry).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

# The wasm features wgpu/naga-style codegen emits: bulk-memory,
# nontrapping-float-to-int, sign-extension and simd instructions among them.
# The names are exactly what wasm-opt's validator asks for in its error
# messages. --all-features is the fallback (see Invoke-WasmOpt) if a future
# codegen change needs a feature not listed here.
$script:WasmOptFeatureFlags = @(
    '--enable-bulk-memory-opt'
    '--enable-nontrapping-float-to-int'
    '--enable-simd'
    '--enable-sign-ext'
    '--enable-reference-types'
    '--enable-mutable-globals'
    '--enable-multivalue'
)

function Get-WasmOptFeatureFlag {
    return @($script:WasmOptFeatureFlags)
}

# Canonical versions.env, shared with the whole Linux pipeline and with
# linux/scripts/lib/wasm-opt.sh.
function Get-WasmOptVersionsEnvPath {
    return (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env')
}

# Resolves the pinned binaryen release for a platform/architecture: version,
# release asset name, expected SHA256 and download URL.
#
# Environment overrides win over versions.env (same precedence as the bash
# side's load_versions_env), so a caller can pin a different release without
# editing the canonical file.
function Get-BinaryenPin {
    param(
        [string]$VersionsEnvPath,
        [ValidateSet('windows', 'linux', 'macos')]
        [string]$Platform = 'windows',
        [ValidateSet('x86_64', 'aarch64')]
        [string]$Architecture = 'x86_64'
    )

    if ([string]::IsNullOrWhiteSpace($VersionsEnvPath)) {
        $VersionsEnvPath = Get-WasmOptVersionsEnvPath
    }

    $versions = @{}
    if (Test-Path $VersionsEnvPath) {
        $parsed = ConvertFrom-VersionsEnv -Path (Resolve-Path $VersionsEnvPath).Path
        foreach ($key in $parsed.Keys) { $versions[$key] = $parsed[$key] }
    }

    $shaKey = "BINARYEN_$($Platform.ToUpperInvariant())_$($Architecture.ToUpperInvariant())_SHA256"

    $version = if ($env:BINARYEN_VERSION) { $env:BINARYEN_VERSION }
               elseif ($versions.ContainsKey('BINARYEN_VERSION')) { $versions['BINARYEN_VERSION'] }
               else { $null }
    if (-not $version) {
        throw "BINARYEN_VERSION is pinned neither in the environment nor in '$VersionsEnvPath'."
    }

    $sha256 = if (Test-Path "Env:\$shaKey") { (Get-Item "Env:\$shaKey").Value }
              elseif ($versions.ContainsKey($shaKey)) { $versions[$shaKey] }
              else { $null }
    if (-not $sha256) {
        throw "No pinned binaryen SHA256 ($shaKey) for $Platform/$Architecture; add one to '$VersionsEnvPath'."
    }

    $asset = "binaryen-$version-$Architecture-$Platform.tar.gz"
    return [pscustomobject]@{
        Version = $version
        Asset   = $asset
        Sha256  = $sha256.ToLowerInvariant()
        Url     = "https://github.com/WebAssembly/binaryen/releases/download/$version/$asset"
    }
}

# Makes wasm-opt available on PATH, fetching the pinned binaryen release if it
# is not already there. Returns the full path to the wasm-opt executable.
#
# The extraction directory is a stable, version-keyed cache (-CacheRoot,
# default %TEMP%) rather than a throwaway directory, so repeated runs reuse the
# download instead of re-fetching ~10 MB every time. A cache hit is decided by
# the presence of bin\wasm-opt.exe inside the version-keyed directory, so
# bumping BINARYEN_VERSION never reuses a stale binary.
function Install-WasmOpt {
    param(
        [string]$VersionsEnvPath,
        [string]$CacheRoot = [System.IO.Path]::GetTempPath(),
        [ValidateSet('windows', 'linux', 'macos')]
        [string]$Platform = 'windows',
        [ValidateSet('x86_64', 'aarch64')]
        [string]$Architecture = 'x86_64',
        # Bootstrap even when a wasm-opt is already on PATH (e.g. to guarantee
        # the pinned version rather than whatever the machine happens to have).
        [switch]$Force
    )

    if (-not $Force) {
        $existing = Get-Command wasm-opt -ErrorAction SilentlyContinue
        if ($existing) { return $existing.Source }
    }

    $pin = Get-BinaryenPin -VersionsEnvPath $VersionsEnvPath -Platform $Platform -Architecture $Architecture
    $installDir = Join-Path $CacheRoot "binaryen-$($pin.Version)"
    $exeName = if ($Platform -eq 'windows') { 'wasm-opt.exe' } else { 'wasm-opt' }
    $exePath = Join-Path $installDir (Join-Path 'bin' $exeName)

    if (-not (Test-Path $exePath)) {
        Write-Host "wasm-opt not on PATH; fetching pinned binaryen $($pin.Version)" -ForegroundColor Yellow
        if (-not (Test-Path $CacheRoot)) { New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null }

        $archivePath = Join-Path $CacheRoot $pin.Asset
        Invoke-DownloadWithRetry -Url $pin.Url -DestinationPath $archivePath
        $actualSha = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
        if ($actualSha -ne $pin.Sha256) {
            Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
            throw "binaryen download checksum mismatch: expected $($pin.Sha256), got $actualSha"
        }
        # The tarball's top-level directory is already binaryen-<version>, i.e.
        # exactly $installDir - extract into the cache root, not into it.
        tar -xzf $archivePath -C $CacheRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Extracting $($pin.Asset) failed (tar exit code $LASTEXITCODE)."
        }
        Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Reusing cached binaryen $($pin.Version) from $installDir" -ForegroundColor Yellow
    }

    if (-not (Test-Path $exePath)) {
        throw "$exeName missing in $installDir\bin after bootstrap."
    }

    $binDir = Split-Path $exePath -Parent
    $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
    return $exePath
}

# Argument vector for one wasm-opt invocation. Pure - no process is started -
# so the flag set stays unit-testable.
function Get-WasmOptArgument {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,
        [Parameter(Mandatory)]
        [string]$OutputPath,
        [string]$OptimizationLevel = '-Oz',
        # Use --all-features instead of the explicit feature list (the retry
        # path, for codegen emitting a feature the list predates).
        [switch]$AllFeatures
    )

    $features = if ($AllFeatures) { @('--all-features') } else { Get-WasmOptFeatureFlag }
    return @($OptimizationLevel) + $features + @($InputPath, '-o', $OutputPath)
}

# Runs wasm-opt with the feature flags above, retrying once with --all-features
# if the explicit set is not enough. Throws when both attempts fail.
function Invoke-WasmOpt {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,
        [Parameter(Mandatory)]
        [string]$OutputPath,
        [string]$OptimizationLevel = '-Oz'
    )

    $arguments = Get-WasmOptArgument -InputPath $InputPath -OutputPath $OutputPath -OptimizationLevel $OptimizationLevel
    & wasm-opt @arguments
    if ($LASTEXITCODE -eq 0) { return }

    Write-Host 'wasm-opt with explicit feature flags failed. Retrying with --all-features...' -ForegroundColor Yellow
    $arguments = Get-WasmOptArgument -InputPath $InputPath -OutputPath $OutputPath -OptimizationLevel $OptimizationLevel -AllFeatures
    & wasm-opt @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wasm-opt failed (exit code $LASTEXITCODE)."
    }
}

Export-ModuleMember -Function Get-WasmOptFeatureFlag, Get-WasmOptVersionsEnvPath, Get-BinaryenPin,
    Install-WasmOpt, Get-WasmOptArgument, Invoke-WasmOpt
