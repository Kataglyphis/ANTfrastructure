#requires -Version 7.0
# A build under the CodeQL tracer must not reach sccache: its server outlived cargo's pipe and hung database create (2026-10-05).
Describe 'sccache is off for a CodeQL-traced build' {
    BeforeAll {
        $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
        Import-Module (Join-Path $modDir 'WindowsCodeQL.Common.psm1') -Force
        if (-not (Get-Module -Name 'WindowsBuild.Common')) {
            Import-Module (Join-Path $modDir 'WindowsBuild.Common.psm1') -DisableNameChecking
        }
        if (-not (Get-Command Get-SccacheStatsText -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -DisableNameChecking
        }
        $script:wrappers = @('RUSTC_WRAPPER', 'CC_WRAPPER', 'CXX_WRAPPER', 'CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER')
        $script:names = $script:wrappers + @('KATAGLYPHIS_NO_SCCACHE', 'SCCACHE_WEBDAV_ENDPOINT', 'SCCACHE_DIR',
            'SCCACHE_MAX_JOBS', 'GLOBAL_CACHE_DIR', 'CARGO_HOME', 'PUB_CACHE', 'PATH')

        # A fake sccache first on PATH; its body is the cmd line it runs when called.
        function Use-FakeSccache([string] $Name, [string] $Body = '@exit /b 0') {
            $bin = Join-Path $TestDrive $Name
            $null = New-Item -ItemType Directory -Force -Path $bin
            Set-Content -Path (Join-Path $bin 'sccache.cmd') -Value $Body -Encoding ascii
            $env:PATH = "$bin;$env:PATH"
            $env:SCCACHE_WEBDAV_ENDPOINT = $null
        }

        function Invoke-CacheInit([string] $Name) {
            $ctx = New-BuildContext -Workspace $TestDrive -LogDir $TestDrive
            $null = Initialize-BuildCacheEnvironment -Context $ctx -FastBuildDir (Join-Path $TestDrive $Name) 6>$null
        }
    }

    BeforeEach {
        $script:saved = @{}
        foreach ($n in $script:names) { $script:saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        foreach ($n in $script:wrappers + 'KATAGLYPHIS_NO_SCCACHE') { [Environment]::SetEnvironmentVariable($n, $null) }
    }

    AfterEach {
        foreach ($n in $script:names) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }

    It 'Disable-SccacheForTrace clears every wrapper and launcher and sets the marker' {
        foreach ($n in $script:wrappers) { [Environment]::SetEnvironmentVariable($n, 'C:\fake\sccache.exe') }
        Disable-SccacheForTrace
        foreach ($n in $script:wrappers) {
            [Environment]::GetEnvironmentVariable($n) | Should -BeNullOrEmpty -Because "$n would wrap a traced compiler"
        }
        $env:KATAGLYPHIS_NO_SCCACHE | Should -Be '1'
    }

    It 'Initialize-BuildCacheEnvironment leaves the launchers unset under the marker, with sccache on PATH' {
        Use-FakeSccache 'marked'
        $env:KATAGLYPHIS_NO_SCCACHE = '1'
        Invoke-CacheInit 'fast-marked'
        $env:CMAKE_CXX_COMPILER_LAUNCHER | Should -BeNullOrEmpty
        $env:RUSTC_WRAPPER | Should -BeNullOrEmpty
    }

    It 'Initialize-BuildCacheEnvironment still wires sccache without the marker' {
        Use-FakeSccache 'unmarked'
        Invoke-CacheInit 'fast-unmarked'
        $env:CMAKE_CXX_COMPILER_LAUNCHER | Should -Match 'sccache\.cmd$'
        $env:RUSTC_WRAPPER | Should -Match 'sccache\.cmd$'
    }

    It 'Get-SccacheStatsText asks nothing under the marker, since asking starts a server' {
        $asked = Join-Path $TestDrive 'asked.txt'
        Use-FakeSccache 'stats' "@echo asked> `"$asked`""
        $env:KATAGLYPHIS_NO_SCCACHE = '1'
        Get-SccacheStatsText | Should -BeNullOrEmpty
        Test-Path -LiteralPath $asked | Should -BeFalse -Because 'sccache must not have been invoked'
    }
}
