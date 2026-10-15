#requires -Version 7.0
# Only the environment-driven parts of the shared sccache and vswhere helpers, so results never depend on the host's VS.

Describe 'Get-SccacheStatsText' {

    It 'returns $null with -RequireRemote and no remote backend (never spawns a server)' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = '' } {
            Assert-Null (Get-SccacheStatsText -RequireRemote) 'no remote backend must short-circuit'
        }
    }

    It 'returns $null with -RequireRemote -Advanced and no remote backend' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = '' } {
            Assert-Null (Get-SccacheStatsText -RequireRemote -Advanced) 'the advanced query gates identically'
        }
    }

    It 'never throws when sccache is unavailable (empty PATH)' {
        Invoke-WithEnv @{ PATH = '' } {
            $result = Get-SccacheStatsText
            Assert-True ($null -eq $result -or $result -is [array]) 'returns $null or lines, never throws'
        }
    }
}

Describe 'Get-VisualStudioInstallPath' {

    It 'throws by default when vswhere.exe is missing (source-build contract)' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Throws { Get-VisualStudioInstallPath } 'a missing VS installer must be fatal by default'
        }
    }

    It 'names the missing vswhere path in the error' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            $message = ''
            try { Get-VisualStudioInstallPath } catch { $message = $_.Exception.Message }
            Assert-Match 'vswhere\.exe not found' $message
        }
    }

    It 'returns $null with -AllowMissing (sanitizer-probe contract)' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Null (Get-VisualStudioInstallPath -AllowMissing) 'the non-throwing face must stay silent'
        }
    }

    It 'returns an empty array with -AllowMissing -All' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Equal 0 (@(Get-VisualStudioInstallPath -AllowMissing -All).Count)
        }
    }
}

Describe 'Get-MsvcToolsRoots' {

    It 'throws by default when no Visual Studio can be discovered' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Throws { Get-MsvcToolsRoots } 'the throwing face is what Get-MsvcToolsRoot relies on'
        }
    }

    It 'returns an empty array with -AllowMissing' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Equal 0 (@(Get-MsvcToolsRoots -AllowMissing).Count)
        }
    }

    It 'supports the -AllowMissing caller pattern without throwing (empty -> $null)' {
        # An empty return unrolls, so callers wrap in @(...) and must get $null, not an error.
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Null (@(Get-MsvcToolsRoots -AllowMissing) | Select-Object -First 1)
        }
    }
}

Describe 'Test-UrlPortOpen' {

    It 'answers $false for a malformed or host-less URL instead of throwing' {
        Assert-False (Test-UrlPortOpen 'not a url') 'no scheme'
        Assert-False (Test-UrlPortOpen '') 'empty'
    }

    It 'answers $true for a listening port and $false once it closes' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        try { Assert-True (Test-UrlPortOpen $url) 'listening' } finally { $listener.Stop() }
        Assert-False (Test-UrlPortOpen $url -TimeoutSeconds 1) 'closed'
    }
}
