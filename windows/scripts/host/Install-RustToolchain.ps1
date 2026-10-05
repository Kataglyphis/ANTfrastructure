# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

# rustup with the pinned RUST_VERSION as its default, never toolchain-less; see docs/windows-builds.md § Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup).

# Short native steps under EAP=Continue, since rustup and cargo write progress to stderr; long ones use the heartbeat wrapper.
function Invoke-NativeRustStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Nulled first, so a missing binary cannot ride a stale 0 into a green step.
        $global:LASTEXITCODE = $null
        & $Command 2>&1 | ForEach-Object { "$_" } | Out-Host
        if ($null -eq $LASTEXITCODE) { throw "$Description failed: command missing or produced no exit code" }
        if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit $LASTEXITCODE)" }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

#region 1. rustup via local dist mirror (HOST QUIRK workaround)
# rustup's own downloader deadlocks in small containers (bypassed by the mirror below); this adds file logs, a heartbeat and a hard timeout.
function Invoke-RustProcessWithHeartbeat {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSec = 1800
    )
    $logBase = Join-Path $env:TEMP ("rust-{0}" -f ($Description -replace '[^A-Za-z0-9]', '-'))
    $outLog = "$logBase.out.log"; $errLog = "$logBase.err.log"
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
        -RedirectStandardOutput "$outLog" -RedirectStandardError "$errLog"
    # Touch .Handle now, or ExitCode stays $null after exit; the argless WaitForExit() below flushes it too.
    $null = $p.Handle
    $elapsed = 0
    while (-not $p.WaitForExit(30000)) {
        $elapsed += 30
        Write-Host ("[{0}] running... {1}s elapsed" -f $Description, $elapsed)
        if ($elapsed -ge $TimeoutSec) {
            # Kill before throwing, or its handles keep the RUN wedged; guarded, since a stuck process may refuse.
            try {
                $p.Kill($true)
                $p.Dispose()
            } catch {
                Write-Host ("[{0}] could not kill/dispose timed-out process: {1}" -f $Description, $_.Exception.Message)
            }
            throw ("{0} timed out after {1}s (see {2} / {3})" -f $Description, $TimeoutSec, $outLog, $errLog)
        }
    }
    $p.WaitForExit()
    foreach ($f in @($outLog, $errLog)) {
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 0)) {
            Write-Host ("--- {0} (last 40 lines) ---" -f (Split-Path $f -Leaf))
            Get-Content $f -Tail 40 | Out-Host
        }
    }
    if ($p.ExitCode -ne 0) { throw ("{0} failed (exit {1})" -f $Description, $p.ExitCode) }
    # On success the logs would only ride into the layer; on failure they stay for the throw message.
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
}

# Linux pins the same value (install-rust.sh), so both platforms build oxidant with one rustc.
$rustVersion = [string]$env:RUST_VERSION
if ([string]::IsNullOrWhiteSpace($rustVersion)) {
    throw 'RUST_VERSION is not set (versions.env not loaded?) — refusing an unpinned Rust.'
}
Write-Host "Installing Rust $rustVersion via rustup (pinned default toolchain; single provider)..."
$rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
Invoke-DownloadWithRetry -Url 'https://win.rustup.rs/x86_64' -DestinationPath $rustupInit `
    -Description 'rustup-init' -ExpectSignature MZ

# A local file:// dist mirror fetched with Invoke-DownloadWithRetry, so rustup-init installs by file copy, never its own downloader.
$targetTriple = 'x86_64-pc-windows-msvc'
$mirrorRoot = Join-Path $env:TEMP 'rustup-dist'
$distDir = Join-Path $mirrorRoot 'dist'
New-Item -Path $distDir -ItemType Directory -Force | Out-Null
$manifestName = "channel-rust-$rustVersion.toml"
$manifestPath = Join-Path $distDir $manifestName
Invoke-DownloadWithRetry -Url "https://static.rust-lang.org/dist/$manifestName" `
    -DestinationPath $manifestPath -Description "rust $rustVersion channel manifest"

$manifest = Get-Content -Path $manifestPath -Raw
$componentUrls = @([regex]::Matches($manifest, 'xz_url\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -match "/(rustc|rust-std|cargo|rustfmt|clippy)-\d[^/]*-$([regex]::Escape($targetTriple))\.tar\.xz$" } |
    Sort-Object -Unique)
if ($componentUrls.Count -lt 3) {
    throw "expected at least the rustc/rust-std/cargo $targetTriple tarball URLs in the channel manifest, found $($componentUrls.Count)"
}
foreach ($url in $componentUrls) {
    $relative = ($url -replace '^https://static\.rust-lang\.org/dist/', '') -replace '/', '\'
    $destination = Join-Path $distDir $relative
    Invoke-DownloadWithRetry -Url $url -DestinationPath $destination -Description (Split-Path $relative -Leaf)
}

# The rewrite changes the manifest bytes, so its .sha256 is regenerated; the component hashes inside stay intact.
$mirrorUrl = 'file:///' + ($mirrorRoot -replace '\\', '/')
$manifest = $manifest -replace 'https://static\.rust-lang\.org', $mirrorUrl
Set-Content -Path $manifestPath -Value $manifest -Encoding ASCII -NoNewline
$manifestHash = (Get-FileHash -Path $manifestPath -Algorithm SHA256).Hash.ToLower()
Set-Content -Path "$manifestPath.sha256" -Value "$manifestHash  $manifestName" -Encoding ASCII

$env:RUSTUP_DIST_SERVER = $mirrorUrl
# Single-threaded unpack: thread-pool contention in a small container is the deadlock class guarded against.
$env:RUSTUP_IO_THREADS = '1'

# The mirror, installer and env override go away on the failure path too.
try {
    # rustfmt and clippy now: once the mirror is gone the cached manifest's file:// URLs make a later component add fail.
    Invoke-RustProcessWithHeartbeat -Description 'rustup-init' -FilePath $rustupInit `
        -ArgumentList @('-y', '--no-modify-path', '--default-toolchain', $rustVersion, '--profile', 'minimal',
                        '-c', 'rustfmt', '-c', 'clippy') `
        -TimeoutSec 900
} finally {
    Remove-Item $rustupInit -Force -ErrorAction SilentlyContinue
    Remove-Item $mirrorRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\RUSTUP_DIST_SERVER -ErrorAction SilentlyContinue
}

#endregion
#region 2. assertion battery + codegen tools
# The baked PATH carries CARGO_BIN for later stages; this process needs it now for the asserts.
$cargoBin = if ($env:CARGO_BIN) { $env:CARGO_BIN } else { Join-Path $env:USERPROFILE '.cargo\bin' }
if (Test-Path (Join-Path $cargoBin 'cargo.exe')) {
    $env:PATH = "$cargoBin;$env:PATH"
    Write-Host "Using rustup-managed Rust binaries at $cargoBin"
}

Assert-ContainerCommandAvailable -Name 'rustup' | Out-Null
Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null

# Idempotent re-assert, in case rustup-init's tail stalls before setting the default.
Invoke-NativeRustStep -Description "rustup default $rustVersion" -Command { rustup default $rustVersion }
Invoke-NativeRustStep -Description 'cargo --version' -Command { cargo --version }
Invoke-NativeRustStep -Description 'rustc --version' -Command { rustc --version }

# Asserted now: they cannot be added later, and a consumer missing them silently skips its lint gates.
Invoke-NativeRustStep -Description 'cargo fmt --version' -Command { cargo fmt --version }
Invoke-NativeRustStep -Description 'cargo clippy --version' -Command { cargo clippy --version }

# Exactly what flutter_rust_bridge's build_tool runs; failing here is cheaper than in every consumer.
Invoke-NativeRustStep -Description 'rustup show active-toolchain' -Command { rustup show active-toolchain }
Invoke-NativeRustStep -Description 'rustup which cargo' -Command { rustup which cargo }

# Baked, or every fresh consumer container pays minutes to cargo-install it; pinned, since bindings must match the runtime's frb.
$frbVersion = [string]$env:FLUTTER_RUST_BRIDGE_VERSION
if ([string]::IsNullOrWhiteSpace($frbVersion)) {
    throw 'FLUTTER_RUST_BRIDGE_VERSION is not set (versions.env not loaded?) — refusing a floating codegen.'
}
Write-Host "Baking flutter_rust_bridge_codegen $frbVersion (cargo install)..."
Invoke-RustProcessWithHeartbeat -Description 'cargo-install-frb-codegen' `
    -FilePath (Join-Path $cargoBin 'cargo.exe') `
    -ArgumentList @('install', 'flutter_rust_bridge_codegen', '--locked', '--version', $frbVersion) `
    -TimeoutSec 2400
Invoke-NativeRustStep -Description 'flutter_rust_bridge_codegen --version' -Command {
    flutter_rust_bridge_codegen --version
}

#endregion
#region 3. sccache from the released zip (source build retired 2026-09-18)
# Into CARGO_BIN, ahead of the scoop shims; see docs/windows-build-resources.md § Persistent compile cache (sccache).
$sccacheVersion = [string]$env:SCCACHE_WINDOWS_VERSION
if ([string]::IsNullOrWhiteSpace($sccacheVersion)) {
    throw 'SCCACHE_WINDOWS_VERSION is not set (versions.env not loaded?) — refusing an unpinned sccache.'
}
$sccacheSha = [string]$env:SCCACHE_WINDOWS_ZIP_SHA256
if ([string]::IsNullOrWhiteSpace($sccacheSha)) {
    throw 'SCCACHE_WINDOWS_ZIP_SHA256 is not set (versions.env not loaded?) — refusing an unverified sccache download.'
}
$sccacheZip = Join-Path $env:TEMP "sccache-v$sccacheVersion-x86_64-pc-windows-msvc.zip"
$sccacheUrl = "https://github.com/mozilla/sccache/releases/download/v$sccacheVersion/sccache-v$sccacheVersion-x86_64-pc-windows-msvc.zip"
Write-Host "Installing released sccache v$sccacheVersion into $cargoBin (SHA256-verified)..."
Invoke-DownloadWithRetry -Url $sccacheUrl -DestinationPath $sccacheZip `
    -Description "sccache v$sccacheVersion zip" -ExpectSignature PK -ExpectedSha256 $sccacheSha
$sccacheExtract = Join-Path $env:TEMP "sccache-v$sccacheVersion-extract"
try {
    Expand-Archive -Path $sccacheZip -DestinationPath $sccacheExtract -Force
    # Search for the exe, never assume the archive's top-level directory name.
    $sccacheExe = @(Get-ChildItem -Path $sccacheExtract -Recurse -Filter 'sccache.exe' -File | Select-Object -First 1)
    if ($sccacheExe.Count -eq 0) { throw "sccache.exe not found inside $sccacheZip — the release asset layout changed." }
    Copy-Item -Path $sccacheExe[0].FullName -Destination (Join-Path $cargoBin 'sccache.exe') -Force
} finally {
    Remove-Item $sccacheZip -Force -ErrorAction SilentlyContinue
    Remove-Item $sccacheExtract -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-NativeRustStep -Description 'sccache --version (released zip)' -Command {
    & (Join-Path $cargoBin 'sccache.exe') --version
}

# Drop the registry/build intermediates -- only CARGO_BIN needs to ship in the layer.
foreach ($cacheDir in @('registry', 'git')) {
    $p = Join-Path $env:USERPROFILE ".cargo\$cacheDir"
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}
#endregion
