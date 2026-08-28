#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The patched-llvm stage shipped unreachable: Dockerfile.toolchain-builder had it
# and no driver ever targeted it, so "flip BUILD_PATCHED_LLVM when the PRs merge"
# would have been a no-op discovered mid-build. See backlog #135.

Describe 'BK driver reaches the patched-llvm stage (#135)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $drvText = Get-Content -Raw (Join-Path $repoWin 'build-buildkit.ps1')
    $dfText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.toolchain-builder')

    It 'exposes a -PatchedLlvm switch' {
        Assert-Match '\[switch\]\$PatchedLlvm' $drvText
    }

    It 'targets the stage the Dockerfile actually defines' {
        Assert-Match '(?m)^FROM built AS patched-llvm' $dfText
        Assert-Match "toolchainTarget = 'patched-llvm'" $drvText
    }

    It 'passes the build-arg the stage declares' {
        Assert-Match '(?m)^ARG BUILD_PATCHED_LLVM' $dfText
        Assert-Match "BUILD_PATCHED_LLVM'\] = '1'" $drvText
    }

    It 'defaults to the plain built stage' {
        Assert-Match "toolchainTarget = 'built'" $drvText
    }
}
