#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Get-MesonSetupFailureClass (build-gstreamer-from-source.ps1): the retry
# classifier for a failed `meson setup`. Lifted out of the script's AST. Pins
# the arm64 run-25 misfire -- the SDK constant BINDINFO_OPTIONS_IGNORE_SSLERRORS_ONCE
# inlined from a probe source must NOT read as a transient network failure --
# while the two measured real network shapes (2026-08-23 HTTP 503, a DNS
# URLError) still do, and the network scan stays inside meson stdout + the
# log's tail where a fatal download error actually lands.

Describe 'Get-MesonSetupFailureClass' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\build-gstreamer-from-source.ps1' `
                                       -FunctionName 'Get-MesonSetupFailureClass')

        $script:hardLine = 'temp\gst-source\gstreamer-1.29.2\subprojects\gst-plugins-bad\gst-libs\gst\webrtc\nice\meson.build:16:14: ERROR: Subproject "subprojects/libnice" required but not found.'
        $script:sdkLine  = '    BINDINFO_OPTIONS_IGNORE_SSLERRORS_ONCE = 0x2000000,'
    }

    It 'run 25: a hard meson.build error plus an inlined SDK SSLERRORS constant is deterministic, not network' {
        $r = Get-MesonSetupFailureClass -Output @('Running meson setup', $script:hardLine) -LogLines @('Code:', $script:sdkLine, '-----', $script:hardLine)
        Assert-Equal 2 $r.HardError.Count 'hard error seen in stdout and log'
        Assert-Equal 0 $r.NetworkError.Count 'SSLERRORS_ONCE must not match \bSSLError\b'
    }

    It '2026-08-23: a download failure in meson.build clothing carries the HTTP 503 signature' {
        $out = @(
            'subprojects\win-pkgconfig\meson.build:13:6: ERROR: Command `download-binary.py 0.29.2` failed with status 1',
            'HTTP Error 503: Backend unavailable, connection timeout'
        )
        $r = Get-MesonSetupFailureClass -Output $out -LogLines @()
        Assert-Equal 1 $r.HardError.Count 'the ERROR line is still a hard error'
        Assert-True ($r.NetworkError.Count -ge 1) 'HTTP 503 is a network signature'
        Assert-True ($r.NetworkError[-1] -like '*HTTP Error 503*') 'last network line is the 503'
    }

    It 'a DNS URLError in the log tail is network; the same line outside the tail window is not' {
        $dns = 'urllib.error.URLError: <urlopen error [Errno 11001] getaddrinfo failed>'
        $inTail = @('a', 'b', $dns, 'c')
        $r1 = Get-MesonSetupFailureClass -Output @() -LogLines $inTail -NetworkTail 3
        Assert-Equal 1 $r1.NetworkError.Count 'URLError inside the last 3 lines'
        $outside = @($dns) + @(1..10 | ForEach-Object { "filler $_" })
        $r2 = Get-MesonSetupFailureClass -Output @() -LogLines $outside -NetworkTail 3
        Assert-Equal 0 $r2.NetworkError.Count 'URLError 10 lines before the tail is out of scope'
    }

    It 'stdout is always scanned for network signatures, regardless of the tail' {
        $r = Get-MesonSetupFailureClass -Output @('Failed to download https://example.invalid/x.tar.xz') -LogLines @(1..50 | ForEach-Object { "line $_" }) -NetworkTail 1
        Assert-Equal 1 $r.NetworkError.Count 'stdout hit'
    }

    It 'empty input classifies as neither' {
        $r = Get-MesonSetupFailureClass -Output @() -LogLines @()
        Assert-Equal 0 $r.HardError.Count 'no hard'
        Assert-Equal 0 $r.NetworkError.Count 'no network'
        Assert-False ([bool]$r.HardError) 'empty HardError is falsy for the call-site if'
    }
}
