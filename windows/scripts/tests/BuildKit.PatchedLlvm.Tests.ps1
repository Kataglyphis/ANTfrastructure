#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The patched-llvm toolchain (BUILD_PATCHED_LLVM=1) is now the DEFAULT (#135:
# the EH_LABEL fix llvm#219275 + #219276 is proven, and the OpenCV workarounds
# have been removed). This suite pins that the driver reaches the patched stage
# by default, and that -StockLlvm is the opt-out.

Describe 'BK driver defaults to the patched-llvm toolchain (#135)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $drvText = Get-Content -Raw (Join-Path $repoWin 'Build-Buildkit.ps1')
    $dfText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.toolchain-builder')

    It 'exposes a -StockLlvm opt-out switch' {
        Assert-Match '\[switch\]\$StockLlvm' $drvText
    }

    It 'targets the patched-llvm stage by default' {
        Assert-Match '(?m)^FROM built AS patched-llvm' $dfText
        Assert-Match 'toolchainTarget = if \(\$StockLlvm\) \{ ''built'' \} else \{ ''patched-llvm'' \}' $drvText
    }

    It 'passes the build-arg when targeting patched-llvm' {
        Assert-Match '(?m)^ARG BUILD_PATCHED_LLVM=1' $dfText
        Assert-Match "BUILD_PATCHED_LLVM'\] = '1'" $drvText
    }

    It 'defaults to patched-llvm (not built)' {
        Assert-Match 'toolchainTarget = if \(\$StockLlvm\) \{ ''built'' \} else \{ ''patched-llvm'' \}' $drvText
    }
}
