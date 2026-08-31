#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The patched-llvm toolchain (#135, default) builds compiler-rt builtins for the
# HOST arch only, so the arm64 GStreamer link died on __udivti3 (found on the
# 2026-08-30 arm64 cross run, merge stage). This pins the self-heal in
# build-gstreamer-from-source.ps1: on the cross lane it mines
# clang_rt.builtins-aarch64.lib from the LLVM release archive next to the x86_64
# one; the warn-and-continue policy is preserved on amd64 and as a fallback.

Describe 'GStreamer cross-lane compiler-rt self-heal (#135 follow-up)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $gstPath = Join-Path $repoWin 'scripts\build\build-gstreamer-from-source.ps1'
    $gstText = Get-Content -Raw $gstPath

    It 'mines the aarch64 builtins from the LLVM release archive' {
        Assert-Match 'clang_rt\.builtins-aarch64\.lib' $gstText
        Assert-Match 'clang%2Bllvm-\$rtVer-aarch64-pc-windows-msvc\.tar\.xz' $gstText
    }

    It 'places the mined lib beside the x86_64 builtins (the dir every consumer searches)' {
        Assert-Match 'rtHostLib\[0\]\.Directory\.FullName' $gstText
    }

    It 're-runs the candidate search after placement so the link actually uses it' {
        Assert-Match 'rtCandidates = @\(Get-ChildItem -Path "\$llvmRoot\\lib\\clang"' $gstText
    }

    It 'keeps the self-heal inside the cross-lane gate (amd64 never downloads)' {
        # The fetch must sit between the `$script:GstCross` guard and the
        # warn-and-continue block that follows it. Index-based so whitespace
        # reformatting cannot break the assertion.
        $gateIdx = $gstText.IndexOf('if ($script:GstCross) {')
        $healIdx = $gstText.IndexOf('# SELF-HEAL')
        $warnIdx = $gstText.IndexOf('WARN, do not throw')
        Assert-True ($gateIdx -ge 0 -and $healIdx -gt $gateIdx -and $warnIdx -gt $healIdx) 'self-heal must sit between the cross-lane gate and the warn block'
    }
}

Describe 'GStreamer cross-lane opus intrinsics (reverted to the proven disabled state)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $gstPath = Join-Path $repoWin 'scripts\build\build-gstreamer-from-source.ps1'
    $gstText = Get-Content -Raw $gstPath

    It 'keeps opus intrinsics DISABLED on both lanes (the 08-26 proven shape)' {
        Assert-True ($gstText.Contains('-Dopus:intrinsics=disabled')) 'intrinsics must stay disabled'
        Assert-True (-not $gstText.Contains('-Dopus:intrinsics=enabled')) 'the speculative cross-lane enablement must not be reintroduced silently'
    }

    It 'records the working enablement recipe so the follow-up is not lost' {
        Assert-True ($gstText.Contains('intrinsics=enabled + rtcd=disabled')) 'the recipe comment must stay'
        Assert-True ($gstText.Contains('__emit')) 'the reason (clang-cl lacks MSVC __emit) must stay'
        Assert-True ($gstText.Contains('arm64')) 'the reason must be present'
    }
}
