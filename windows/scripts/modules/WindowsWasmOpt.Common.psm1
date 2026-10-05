# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# The Windows twin of linux/scripts/lib/wasm-opt.sh; the binaryen pin lives only in tool-pins.env.

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# wgpu/naga codegen emits these, which wasm-opt's validator rejects by default; Invoke-WasmOpt falls back to --all-features.
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

# Shared with linux/scripts/lib/wasm-opt.sh, so the pin exists once.
function Get-WasmOptVersionsEnvPath {
    return (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\tool-pins.env')
}

# Environment overrides win over tool-pins.env, the same precedence as the bash side's load_versions_env.
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

# A version-keyed cache under -CacheRoot: reruns skip the download, and a version bump never reuses a stale binary.
function Install-WasmOpt {
    param(
        [string]$VersionsEnvPath,
        [string]$CacheRoot = [System.IO.Path]::GetTempPath(),
        [ValidateSet('windows', 'linux', 'macos')]
        [string]$Platform = 'windows',
        [ValidateSet('x86_64', 'aarch64')]
        [string]$Architecture = 'x86_64',
        # Bootstrap even when wasm-opt is on PATH, to guarantee the pinned version.
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
        # The tarball's top-level directory is already binaryen-<version>, so extract into the cache root.
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

# Pure, so the flag set stays unit-testable.
function Get-WasmOptArgument {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,
        [Parameter(Mandatory)]
        [string]$OutputPath,
        [string]$OptimizationLevel = '-Oz',
        # The retry path, for codegen emitting a feature the explicit list predates.
        [switch]$AllFeatures
    )

    $features = if ($AllFeatures) { @('--all-features') } else { Get-WasmOptFeatureFlag }
    return @($OptimizationLevel) + $features + @($InputPath, '-o', $OutputPath)
}

# Retries once with --all-features; throws when both attempts fail.
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
