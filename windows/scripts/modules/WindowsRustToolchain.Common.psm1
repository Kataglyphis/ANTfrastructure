#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Merge-lane leaf, never in the media-builder buildmods: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
$rustSharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (Test-Path $rustSharedPath) {
    if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $rustSharedPath }
} else {
    throw ("WindowsRustToolchain.Common: required sibling module not found at $rustSharedPath. " +
           'Install-RustTargetStdFromPinnedManifest downloads through Invoke-DownloadWithRetry ' +
           'and cannot work without it. Add WindowsScripts.Shared.psm1 to the COPY/mount list ' +
           'that carries this module.')
}

# The manifest still names the deleted mirror's file:// URL and upstream's sha256, so upstream bytes land where it expects.
function Install-RustTargetStdFromPinnedManifest {
    param(
        [Parameter(Mandatory)]
        [string]$Triple,
        [string]$RustupHome = '',
        [string]$UpstreamRoot = 'https://static.rust-lang.org',
        [scriptblock]$Downloader = $null
    )
    if ([string]::IsNullOrWhiteSpace($RustupHome)) {
        $RustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $env:USERPROFILE '.rustup' }
    }
    $manifests = @(Get-ChildItem -Path (Join-Path $RustupHome 'toolchains') -Recurse -Filter 'multirust-channel-manifest.toml' -File -ErrorAction SilentlyContinue)
    if ($manifests.Count -eq 0) { return "rust-std ${Triple}: no cached channel manifest under $RustupHome -- leaving `rustup target add` to its own devices" }
    $manifest = [System.IO.File]::ReadAllText($manifests[0].FullName)
    # The rust-std package block names its per-target tarball; take the xz one.
    $rx = '(?s)\[pkg\.rust-std\.target\.' + [regex]::Escape($Triple) + '\](.*?)(?=\r?\n\[pkg\.)'
    $m = [regex]::Match($manifest, $rx)
    if (-not $m.Success) { return "rust-std ${Triple}: the pinned manifest has no [pkg.rust-std.target.$Triple] block -- upstream ships no std for it" }
    $block = $m.Groups[1].Value
    $urlM = [regex]::Match($block, 'xz_url\s*=\s*"([^"]+)"')
    if (-not $urlM.Success) { return "rust-std ${Triple}: no xz_url in the manifest block" }
    $url = $urlM.Groups[1].Value
    if ($url -notmatch '^file:///') { return "rust-std ${Triple}: manifest URL is not a file:// mirror path ($url) -- nothing to pre-seed" }
    # file:///C:/.../rustup-dist/dist/<date>/<file> -> local path + dist-relative part
    $local = [uri]::UnescapeDataString(($url -replace '^file:///', '')) -replace '/', '\'
    $relM = [regex]::Match($url, '/(dist/[^/]+/[^/]+\.tar\.xz)$')
    if (-not $relM.Success) { return "rust-std ${Triple}: cannot derive the dist-relative path from $url" }
    $upstream = "$($UpstreamRoot.TrimEnd('/'))/$($relM.Groups[1].Value)"
    if (Test-Path $local -PathType Leaf) { return "rust-std ${Triple}: $local already present" }
    New-Item -Path (Split-Path $local -Parent) -ItemType Directory -Force | Out-Null
    try {
        if ($Downloader) { & $Downloader $upstream $local }
        else { Invoke-DownloadWithRetry -Url $upstream -DestinationPath $local -Description "rust-std $Triple (pinned manifest, upstream bytes)" }
    } catch {
        return "rust-std ${Triple}: download of $upstream failed ($($_.Exception.Message)) -- rustup will report the missing mirror file"
    }
    if (-not (Test-Path $local -PathType Leaf)) { return "rust-std ${Triple}: downloader produced no file at $local" }
    return "rust-std ${Triple}: fetched $upstream -> $local ($([math]::Round((Get-Item $local).Length / 1MB, 1)) MB); rustup verifies it against the pinned manifest hash"
}

Export-ModuleMember -Function Install-RustTargetStdFromPinnedManifest
