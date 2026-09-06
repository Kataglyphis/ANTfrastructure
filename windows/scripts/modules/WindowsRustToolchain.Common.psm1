#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Rust toolchain repair for images whose rustup was fed from a local mirror that
# no longer exists.
#
# WHY THIS IS ITS OWN MODULE — CACHE BOUNDARY, NOT TASTE.
# This lived inside Build-GstreamerFromSource.ps1 (backlog #133) because the
# only module homes then available were the six in `buildmods` — the import
# closure of WindowsSourceBuild.Common, mounted into all 11 media/merge RUNs, so
# an edit there re-keyed every media branch on both lanes. #134 gave the merge
# lane its own leaf modules; this file is mounted by
# Dockerfile.media-merge-builder ONLY, so a change costs the GStreamer layer and
# nothing else.
#
# Keep that property: do NOT add this module to Dockerfile.media-builder's
# `buildmods` stage. Same rule, same reason, as WindowsMeson.Common.psm1 and
# WindowsGstPlugins.Common.psm1.
#
# It is one function today. That is deliberate: a rust-toolchain concern does
# not belong in a meson module, and the next rust-for-the-target helper (the
# corrosion crates LiteRT-LM needs, #133(d)) has an obvious home here.

Set-StrictMode -Version Latest

# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap). Needed for
# Invoke-DownloadWithRetry; the fixture test injects -Downloader instead and so
# never reaches it.
$rustSharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (Test-Path $rustSharedPath) {
    if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $rustSharedPath }
} else {
    throw ("WindowsRustToolchain.Common: required sibling module not found at $rustSharedPath. " +
           'Install-RustTargetStdFromPinnedManifest downloads through Invoke-DownloadWithRetry ' +
           'and cannot work without it. Add WindowsScripts.Shared.psm1 to the COPY/mount list ' +
           'that carries this module.')
}

# Makes `rustup target add <triple>` possible in an image whose rustup was fed
# from a local mirror that is gone (#128 / #133). Install-RustToolchain.ps1
# rewrote the channel manifest's URLs to file:///<mirror>/dist/<date>/<file>
# and deleted the mirror after the install; the cached manifest under
# <rustup home>\toolchains\<tc>\lib\rustlib\multirust-channel-manifest.toml
# still names every component with that URL AND upstream's sha256. Fetching
# exactly that tarball from static.rust-lang.org into the path the manifest
# expects gives rustup a file it can hash-verify against the pinned manifest
# -- the pin stays the authority, the network only supplies the bytes.
# Returns a one-line verdict (never throws): the caller's staticlib probe is
# the gate. -Downloader is injectable for the fixture test.
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
