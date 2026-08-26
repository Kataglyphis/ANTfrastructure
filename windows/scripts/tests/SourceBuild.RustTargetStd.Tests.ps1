#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Install-RustTargetStdFromPinnedManifest (build-gstreamer-from-source.ps1):
# pre-seeds the tarball `rustup target add` wants at the file:// path the
# image's PINNED channel manifest names, fetching the bytes from upstream
# (runs 23-28: "could not download file from 'file:///...rustup-dist/...'").
# Lifted out of the script's AST; fixture rustup home + stub downloader, no
# rustup needed. Pins: the manifest block for the triple is found, the
# dist-relative path is derived from the file:// URL, the download lands where
# the manifest points, a present file is not re-fetched, and every failure
# mode returns a verdict instead of throwing (the staticlib probe is the gate).

Describe 'Install-RustTargetStdFromPinnedManifest' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\build-gstreamer-from-source.ps1' `
                                       -FunctionName 'Install-RustTargetStdFromPinnedManifest')

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-ruststd-' + [guid]::NewGuid().ToString('N'))
        $script:rustupHome = Join-Path $script:tmp 'rustup'
        $script:mirror = Join-Path $script:tmp 'rustup-dist'
        $tcDir = Join-Path $script:rustupHome 'toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib'
        New-Item -ItemType Directory -Force -Path $tcDir | Out-Null
        $mirrorUrl = 'file:///' + ($script:mirror -replace '\\', '/')
        # The shape setup-rust-toolchain.ps1 leaves behind: upstream manifest, URLs rewritten to the mirror.
        @(
            'manifest-version = "2"',
            'date = "2026-08-20"',
            '[pkg.rust-std]',
            'version = "1.98.0 (abcdef 2026-08-20)"',
            '[pkg.rust-std.target.x86_64-pc-windows-msvc]',
            'available = true',
            "xz_url = `"$mirrorUrl/dist/2026-08-20/rust-std-1.98.0-x86_64-pc-windows-msvc.tar.xz`"",
            'xz_hash = "1111111111111111111111111111111111111111111111111111111111111111"',
            '[pkg.rust-std.target.aarch64-pc-windows-msvc]',
            'available = true',
            "xz_url = `"$mirrorUrl/dist/2026-08-20/rust-std-1.98.0-aarch64-pc-windows-msvc.tar.xz`"",
            'xz_hash = "2222222222222222222222222222222222222222222222222222222222222222"',
            '[pkg.rustc]',
            'version = "1.98.0"'
        ) -join "`n" | Set-Content -Path (Join-Path $tcDir 'multirust-channel-manifest.toml') -Encoding ASCII
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'derives the upstream URL from the pinned file:// URL and lands the bytes where the manifest points' {
        $script:seenUrl = $null; $script:seenDest = $null
        $dl = { param($u, $d) $script:seenUrl = $u; $script:seenDest = $d; Set-Content -Path $d -Value 'tarball-bytes' }
        $v = Install-RustTargetStdFromPinnedManifest -Triple 'aarch64-pc-windows-msvc' -RustupHome $script:rustupHome -Downloader $dl
        Assert-Equal 'https://static.rust-lang.org/dist/2026-08-20/rust-std-1.98.0-aarch64-pc-windows-msvc.tar.xz' $script:seenUrl 'upstream URL'
        $expected = Join-Path $script:mirror 'dist\2026-08-20\rust-std-1.98.0-aarch64-pc-windows-msvc.tar.xz'
        Assert-Equal $expected $script:seenDest 'destination is the manifest path'
        Assert-True (Test-Path $expected) 'file exists afterwards'
        Assert-True ($v -like 'rust-std aarch64-pc-windows-msvc: fetched *') "verdict says fetched ($v)"
    }

    It 'does not re-download a tarball that is already present' {
        $script:called = $false
        $dl = { param($u, $d) $script:called = $true }
        $v = Install-RustTargetStdFromPinnedManifest -Triple 'aarch64-pc-windows-msvc' -RustupHome $script:rustupHome -Downloader $dl
        Assert-False $script:called 'downloader not invoked'
        Assert-True ($v -like '*already present*') "verdict ($v)"
    }

    It 'reports a triple the pinned manifest does not carry, without throwing' {
        $v = Install-RustTargetStdFromPinnedManifest -Triple 'riscv64gc-unknown-linux-gnu' -RustupHome $script:rustupHome -Downloader { throw 'must not be called' }
        # .Contains, not -like: the [brackets] would be a wildcard character class.
        Assert-True ($v.Contains('no [pkg.rust-std.target.riscv64gc-unknown-linux-gnu] block')) "verdict ($v)"
    }

    It 'reports a missing rustup home without throwing' {
        $v = Install-RustTargetStdFromPinnedManifest -Triple 'aarch64-pc-windows-msvc' -RustupHome (Join-Path $script:tmp 'absent') -Downloader { throw 'must not be called' }
        Assert-True ($v -like '*no cached channel manifest*') "verdict ($v)"
    }

    It 'turns a failing download into a verdict, not an exception' {
        Remove-Item (Join-Path $script:mirror 'dist\2026-08-20\rust-std-1.98.0-aarch64-pc-windows-msvc.tar.xz') -Force
        $v = Install-RustTargetStdFromPinnedManifest -Triple 'aarch64-pc-windows-msvc' -RustupHome $script:rustupHome -Downloader { throw 'HTTP 503' }
        Assert-True ($v -like '*download of * failed (HTTP 503)*') "verdict ($v)"
    }
}
