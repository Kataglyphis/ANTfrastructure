#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Clear-UnreachableSccacheEndpoint and the two launcher-wiring sites that call it through
# Enable-SccacheCompilerWrapper. Real sockets on 127.0.0.1: a port bound but never
# listening (refused for as long as the test holds it) and a listening one.
# docs/windows-build-resources.md#the-consumer-side-probe

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
# Unforced, like WindowsMediaRuntime.Common.Tests.ps1: a -Force reload breaks Shared's guarded import.
if (-not (Get-Module -Name 'WindowsBuild.Common')) {
    Import-Module (Join-Path $modDir 'WindowsBuild.Common.psm1') -DisableNameChecking
}

# Bound, never listening: every connect is refused while the socket lives.
function New-ClosedLoopbackPort {
    $s = [System.Net.Sockets.Socket]::new('InterNetwork', 'Stream', 'Tcp')
    $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
    $s
}

function New-ListeningLoopbackPort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $l
}

# Every variable the probe and the wiring touch, unset: the host's own values must not leak in.
$script:probeEnv = @{
    SCCACHE_WEBDAV_ENDPOINT = $null; SCCACHE_MULTILEVEL_CHAIN = $null; SCCACHE_DIR = $null
    CMAKE_C_COMPILER_LAUNCHER = $null; CMAKE_CXX_COMPILER_LAUNCHER = $null; RUSTC_WRAPPER = $null
    CC_WRAPPER = $null; CXX_WRAPPER = $null; SCCACHE_MAX_JOBS = $null
    GLOBAL_CACHE_DIR = $null; CARGO_HOME = $null; PUB_CACHE = $null
}

function Invoke-WithProbeEnv {
    param([hashtable]$Vars, [Parameter(Mandatory)][scriptblock]$Body)
    $all = @{} + $script:probeEnv
    foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
    Invoke-WithEnv $all $Body
}

# Splatted into Invoke-WithFunctionModule: a mutant is the probe's two functions, as Clear-MutUnreachableSccacheEndpoint.
$probeMutantSource = @{
    Text         = [IO.File]::ReadAllText((Join-Path $modDir 'WindowsBuild.Common.psm1'))
    FunctionName = 'Test-TcpEndpointReachable', 'Clear-UnreachableSccacheEndpoint'
}

# Runs $Body with SCCACHE_WEBDAV_ENDPOINT on a loopback port that refuses every connect.
function Invoke-WithClosedEndpoint {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $s = New-ClosedLoopbackPort
    try { Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($s.LocalEndPoint.Port)" } $Body }
    finally { $s.Dispose() }
}

# Runs $Body with SCCACHE_WEBDAV_ENDPOINT on http://localhost:<port>, where only 127.0.0.1 listens.
function Invoke-WithLocalhostEndpoint {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $l = New-ListeningLoopbackPort
    try { Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://localhost:$($l.LocalEndpoint.Port)" } $Body }
    finally { $l.Stop() }
}

# Milliseconds $Body takes.
function Measure-ProbeMs {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & $Body
    $clock.ElapsedMilliseconds
}

Describe 'Clear-UnreachableSccacheEndpoint' {

    It 'keeps a reachable endpoint (the build host keeps its cache) and says nothing' {
        $l = New-ListeningLoopbackPort
        try {
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($l.LocalEndpoint.Port)" } {
                $r = Clear-UnreachableSccacheEndpoint -WarningVariable w -WarningAction SilentlyContinue
                Assert-Equal $false $r
                Assert-NotNull $env:SCCACHE_WEBDAV_ENDPOINT 'a reachable endpoint must survive'
                Assert-Equal 0 @($w).Count 'no WARN for a healthy endpoint'
            }
        } finally { $l.Stop() }
    }

    It 'removes an unreachable endpoint with one WARN naming it' {
        $s = New-ClosedLoopbackPort
        try {
            $ep = "http://127.0.0.1:$($s.LocalEndPoint.Port)"
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = $ep; SCCACHE_DIR = 'C:\sccache\v2' } {
                $r = Clear-UnreachableSccacheEndpoint -WarningVariable w -WarningAction SilentlyContinue
                Assert-Equal $true $r
                Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT 'the endpoint must be gone from the process'
                Assert-Equal 1 @($w).Count 'exactly one WARN'
                Assert-Match ([regex]::Escape($ep)) "$($w[0])"
                Assert-Match 'unreachable' "$($w[0])"
                Assert-Match ([regex]::Escape('C:\sccache\v2')) "$($w[0])" 'the WARN says where the cache goes instead'
            }
        } finally { $s.Dispose() }
    }

    It 'does nothing when no endpoint is set' {
        Invoke-WithProbeEnv @{} {
            $r = Clear-UnreachableSccacheEndpoint -WarningVariable w -WarningAction SilentlyContinue
            Assert-Equal $false $r
            Assert-Equal 0 @($w).Count
        }
    }

    It 'removes a value that is not a URL (sccache would try to use it)' {
        Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = 'not a url' } {
            Assert-Equal $true (Clear-UnreachableSccacheEndpoint -WarningAction SilentlyContinue)
            Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT
        }
    }

    It 'takes a chain that names webdav with it, and leaves any other chain alone' {
        $s = New-ClosedLoopbackPort
        try {
            $ep = "http://127.0.0.1:$($s.LocalEndPoint.Port)"
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = $ep; SCCACHE_MULTILEVEL_CHAIN = 'disk,webdav' } {
                $null = Clear-UnreachableSccacheEndpoint -WarningAction SilentlyContinue
                Assert-Null $env:SCCACHE_MULTILEVEL_CHAIN 'a chain naming a removed level would fail the server'
            }
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = $ep; SCCACHE_MULTILEVEL_CHAIN = 'disk' } {
                $null = Clear-UnreachableSccacheEndpoint -WarningAction SilentlyContinue
                Assert-Equal 'disk' $env:SCCACHE_MULTILEVEL_CHAIN
            }
        } finally { $s.Dispose() }
    }

    It 'a mutant that only warns leaves the endpoint in place, and this suite notices (mutation)' {
        Invoke-WithFunctionModule @probeMutantSource -Find 'Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue' -Body {
            Invoke-WithClosedEndpoint -Body {
                $null = Clear-MutUnreachableSccacheEndpoint -WarningAction SilentlyContinue
                Assert-NotNull $env:SCCACHE_WEBDAV_ENDPOINT 'the mutant must keep the endpoint, or the removal assertion above proves nothing'
            }
        }
    }

    # Windows reports a refused loopback connect after ~2 s, the default bound, so only a
    # smaller -TimeoutMs tells a probe that honours it from one that waits for the refusal.
    It 'honours -TimeoutMs: an unreachable endpoint is removed at the bound, not when Windows gives up' {
        Invoke-WithClosedEndpoint -Body {
            $ms = Measure-ProbeMs { Assert-Equal $true (Clear-UnreachableSccacheEndpoint -TimeoutMs 200 -WarningAction SilentlyContinue) }
            Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT
            Assert-True ($ms -lt 1500) "took $ms ms against a 200 ms bound"
        }
    }

    It 'a mutant that ignores -TimeoutMs outlasts the bound here, so the case above bites (mutation)' {
        Invoke-WithFunctionModule @probeMutantSource -Find 'WaitAny($pending.ToArray(), $left)' -Replace 'WaitAny($pending.ToArray(), 10000)' -Body {
            Invoke-WithClosedEndpoint -Body {
                $ms = Measure-ProbeMs { Clear-MutUnreachableSccacheEndpoint -TimeoutMs 200 -WarningAction SilentlyContinue }
                Assert-True ($ms -ge 1500) "the mutant returned in $ms ms: this host refuses fast, so the bound case proves nothing"
            }
        }
    }

    It 'keeps a hostname whose first address refuses when another one answers (localhost: ::1, then 127.0.0.1)' {
        $first = @([System.Net.Dns]::GetHostAddresses('localhost'))[0]
        Assert-Equal 'InterNetworkV6' "$($first.AddressFamily)" 'premise: localhost resolves to ::1 first, as on Windows'
        Invoke-WithLocalhostEndpoint {
            $ms = Measure-ProbeMs { Assert-Equal $false (Clear-UnreachableSccacheEndpoint -WarningAction SilentlyContinue) }
            Assert-NotNull $env:SCCACHE_WEBDAV_ENDPOINT 'the IPv4 listener answered; the endpoint must survive'
            Assert-True ($ms -lt 1500) "took $ms ms: the addresses were tried one after another"
        }
    }

    It 'a mutant that tries only the first resolved address drops that endpoint, so the case above bites (mutation)' {
        Invoke-WithFunctionModule @probeMutantSource -Find 'foreach ($address in $resolve.Result)' -Replace 'foreach ($address in @($resolve.Result)[0])' -Body {
            Invoke-WithLocalhostEndpoint { Assert-Equal $true (Clear-MutUnreachableSccacheEndpoint -WarningAction SilentlyContinue) }
        }
    }

    It 'removes a hostname that does not resolve' {
        Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = 'http://kata-probe.invalid:5000' } {
            Assert-Equal $true (Clear-UnreachableSccacheEndpoint -TimeoutMs 500 -WarningAction SilentlyContinue)
            Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT
        }
    }
}

Describe 'The launcher-wiring sites probe before they wire' {

    It 'Enable-SccacheCompilerWrapper drops an unreachable endpoint and still wires the launchers' {
        $s = New-ClosedLoopbackPort
        try {
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($s.LocalEndPoint.Port)" } {
                Enable-SccacheCompilerWrapper -SccacheExe 'C:\fake\sccache.exe' -WarningAction SilentlyContinue
                Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT
                Assert-Equal 'C:\fake\sccache.exe' $env:CMAKE_C_COMPILER_LAUNCHER
                Assert-Equal 'C:\fake\sccache.exe' $env:RUSTC_WRAPPER
            }
        } finally { $s.Dispose() }
    }

    It 'wiring twice (Initialize-BuildCacheEnvironment, then Invoke-CmakeConfigureAndBuild) WARNs once' {
        $s = New-ClosedLoopbackPort
        try {
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($s.LocalEndPoint.Port)" } {
                Enable-SccacheCompilerWrapper -SccacheExe 'C:\fake\sccache.exe' -WarningVariable w1 -WarningAction SilentlyContinue
                Enable-SccacheCompilerWrapper -SccacheExe 'C:\fake\sccache.exe' -WarningVariable w2 -WarningAction SilentlyContinue
                Assert-Equal 1 (@($w1).Count + @($w2).Count)
            }
        } finally { $s.Dispose() }
    }

    It 'Enable-SccacheCompilerWrapper keeps a reachable endpoint' {
        $l = New-ListeningLoopbackPort
        try {
            $ep = "http://127.0.0.1:$($l.LocalEndpoint.Port)"
            Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = $ep } {
                Enable-SccacheCompilerWrapper -SccacheExe 'C:\fake\sccache.exe'
                Assert-Equal $ep $env:SCCACHE_WEBDAV_ENDPOINT
            }
        } finally { $l.Stop() }
    }

    It 'Initialize-BuildCacheEnvironment, with sccache on PATH, runs the probe' {
        Invoke-InTestDir { param($dir)
            $bin = Join-Path $dir 'bin'
            $null = New-Item -ItemType Directory -Path $bin
            Set-Content -Path (Join-Path $bin 'sccache.cmd') -Value '@exit /b 0' -Encoding ascii
            $ctx = New-BuildContext -Workspace $dir -LogDir $dir
            $s = New-ClosedLoopbackPort
            try {
                Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($s.LocalEndPoint.Port)"; PATH = "$bin;$env:PATH" } {
                    $null = Initialize-BuildCacheEnvironment -Context $ctx -FastBuildDir (Join-Path $dir 'fast') -WarningAction SilentlyContinue 6>$null
                    Assert-Null $env:SCCACHE_WEBDAV_ENDPOINT
                    Assert-Match 'sccache\.cmd$' $env:CMAKE_C_COMPILER_LAUNCHER 'the launchers are still wired'
                }
            } finally { $s.Dispose() }
        }
    }

    It 'Invoke-CmakeConfigureAndBuild wires through Enable-SccacheCompilerWrapper (the probe''s choke point)' {
        $src = Get-Content -Raw (Join-Path $modDir 'WindowsCMake.Common.psm1')
        $fn = [regex]::Match($src, '(?s)function Invoke-CmakeConfigureAndBuild \{.*?\n\}').Value
        Assert-Match 'Enable-SccacheCompilerWrapper -SccacheExe' $fn
        Assert-False ($fn -match '\$env:CMAKE_C_COMPILER_LAUNCHER\s*=\s*\$') 'a direct launcher assignment would bypass the probe'
    }
}
