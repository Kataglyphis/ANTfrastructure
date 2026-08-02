# Tests for the shared helpers that replaced three duplicated implementations each:
#   Get-SccacheStatsText  <- the sccache --show-stats copies in WindowsCMake.Common
#                            (inline), WindowsBuild.Common (Show-SccacheStats) and
#                            WindowsSourceBuild.Common (Write-SccacheStats)
#   Get-VisualStudioInstallPath / Get-MsvcToolsRoots
#                         <- Get-VsInstallPath/Get-MsvcToolsRoot (throwing) and the
#                            inline non-throwing vswhere probe in
#                            WindowsCMake.Common::Get-SanitizerRuntimeDlls
# Only the host-independent parts are asserted: the remote gate, and the
# throwing-vs-silent contract when vswhere.exe cannot be found. Both are driven
# purely from the environment, so they behave the same with or without a real
# Visual Studio installation on the machine.

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
        # PowerShell unrolls an empty return, so callers wrap in @(...) before
        # taking the first entry -- this is exactly what Get-SanitizerRuntimeDlls
        # does, and it must yield $null rather than blowing up.
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = 'X:\no-such-program-files' } {
            Assert-Null (@(Get-MsvcToolsRoots -AllowMissing) | Select-Object -First 1)
        }
    }
}
