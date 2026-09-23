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
        Invoke-InTestDir { param($dir)
            $text = [IO.File]::ReadAllText((Join-Path $modDir 'WindowsBuild.Common.psm1'))
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Test-TcpEndpointReachable', 'Clear-UnreachableSccacheEndpoint') }, $true) |
                    ForEach-Object { $_.Extent.Text })
            Assert-Equal 2 $defs.Count 'both functions must be found'
            $find = 'Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue'
            $body = ($defs -join "`n")
            Assert-True $body.Contains($find) 'mutation target is gone'
            $path = Join-Path $dir 'WbtProbeMutant.psm1'
            [IO.File]::WriteAllText($path, $body.Replace($find, '') + "`nExport-ModuleMember -Function Clear-UnreachableSccacheEndpoint`n")
            $m = Import-Module $path -Prefix Mut -Force -PassThru -DisableNameChecking
            $s = New-ClosedLoopbackPort
            try {
                Invoke-WithProbeEnv @{ SCCACHE_WEBDAV_ENDPOINT = "http://127.0.0.1:$($s.LocalEndPoint.Port)" } {
                    $null = Clear-MutUnreachableSccacheEndpoint -WarningAction SilentlyContinue
                    Assert-NotNull $env:SCCACHE_WEBDAV_ENDPOINT 'the mutant must keep the endpoint, or the removal assertion above proves nothing'
                }
            } finally { $s.Dispose(); Remove-Module $m -Force }
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
