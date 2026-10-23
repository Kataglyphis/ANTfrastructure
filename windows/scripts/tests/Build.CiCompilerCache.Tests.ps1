#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Real robocopy moves between temp directories, and an sccache stand-in first on PATH that records each call.

# A -Force reload would break WindowsScripts.Shared's guarded import, so an already loaded copy stays.
if (-not (Get-Module -Name 'WindowsBuild.Common')) { Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsBuild.Common.psm1') -DisableNameChecking }

# New-Item -Force creates a file's missing directories too.
function script:Set-CacheFile([string]$Dir, [string[]]$Relative) { $Relative | ForEach-Object { $null = New-Item -ItemType File -Force -Path (Join-Path $Dir $_) -Value $_ } }

# A CI cache with an sccache object and a cargo archive, and the stand-in sccache; returns the env the cases run under.
function script:New-CiCacheFixture([string]$Dir) {
    Set-CacheFile $Dir 'ci\sccache\a\obj', 'ci\cargo\registry\cache\x.crate'
    $null = New-TestBatchTool -Directory (Join-Path $Dir 'bin') -Name 'sccache.cmd' -Line @(
        '>>"%FAKE_SCCACHE_LOG%" echo %*', 'if "%1"=="--version" echo sccache 0.19.0')
    return @{ PATH = "$(Join-Path $Dir 'bin');$env:PATH"; FAKE_SCCACHE_LOG = (Join-Path $Dir 'sccache.log'); SCCACHE_DIR = $null; CARGO_HOME = $null
        CI_COMPILER_CACHE = (Join-Path $Dir 'ci'); GLOBAL_CACHE_DIR = (Join-Path $Dir 'local'); KATAGLYPHIS_FAST_BUILD_DIR = $null }
}

Describe 'Test-SccacheModuleSafe' {
    It 'keeps a CI cache only on an sccache that keys clang-cl module importers right' {
        foreach ($stale in 'sccache 0.18.0', 'sccache 0.17.3', '') { Assert-False (Test-SccacheModuleSafe $stale) "'$stale'" }
        foreach ($keyed in 'sccache 0.18.0+1bd7432.pr2809', 'sccache 0.19.0') { Assert-True (Test-SccacheModuleSafe $keyed) "'$keyed'" }
    }
}

Describe 'Restore-CiCompilerCache and Save-CiCompilerCache' {
    It 'moves sccache and cargo in, points SCCACHE_DIR and CARGO_HOME there, and back without cargo''s unpacked sources' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv (New-CiCacheFixture $d) {
                $restored = Restore-CiCompilerCache -Cache sccache, cargo 6>$null
                Assert-Equal (Join-Path $d 'local\sccache') $env:SCCACHE_DIR
                Assert-Equal (Join-Path $d 'local\cargo') $env:CARGO_HOME
                Assert-True (Test-Path -LiteralPath (Join-Path $d 'local\sccache\a\obj')) 'the object moved in'
                Assert-False (Test-Path -LiteralPath (Join-Path $d 'ci\sccache\a\obj')) 'moved, not copied'
                Set-CacheFile $d 'local\sccache\b\new', 'local\cargo\registry\src\x\lib.rs', 'local\cargo\git\checkouts\y\f'
                Assert-True (Save-CiCompilerCache $restored 6>$null)
                foreach ($f in 'ci\sccache\a\obj', 'ci\sccache\b\new', 'ci\cargo\registry\cache\x.crate') {
                    Assert-True (Test-Path -LiteralPath (Join-Path $d $f)) "$f is saved"
                }
                Assert-False (Test-Path -LiteralPath (Join-Path $d 'ci\cargo\registry\src')) 'cargo unpacks registry\src again'
                Assert-False (Test-Path -LiteralPath (Join-Path $d 'ci\cargo\git\checkouts')) 'and git\checkouts'
                Assert-Equal '--version|--stop-server|--show-stats|--stop-server' ((Get-Content -LiteralPath $env:FAKE_SCCACHE_LOG) -join '|') 'a server never outlives a move'
            }
        }
    }

    It 'does nothing without CI_COMPILER_CACHE, nor on an sccache that serves stale module importers' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv (New-CiCacheFixture $d) {
                Assert-Null (Restore-CiCompilerCache -CacheRoot '')
                $restored = Restore-CiCompilerCache -RequireModuleSafeSccache -VersionText 'sccache 0.18.0' 3>$null
                Assert-Null $restored 'refused'
                Assert-True (Test-Path -LiteralPath (Join-Path $d 'ci\sccache\a\obj')) 'the cache stays where it was'
                Assert-Null $env:SCCACHE_DIR 'and SCCACHE_DIR unset'
                Assert-True (Save-CiCompilerCache $null) 'nothing to save is a success'
                Assert-NotNull (Restore-CiCompilerCache -RequireModuleSafeSccache 6>$null) 'the stand-in reports 0.19.0, which is safe'
            }
        }
    }

    It 'warns and returns $false when a cache cannot move back' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv (New-CiCacheFixture $d) {
                $restored = Restore-CiCompilerCache 6>$null
                Set-Content -LiteralPath (Join-Path $d 'blocker') -Value 'a file where the cache root should be'
                $restored.CacheRoot = Join-Path $d 'blocker'
                $warnings = $null
                $ok = Save-CiCompilerCache $restored -WarningVariable warnings -WarningAction SilentlyContinue 6>$null
                Assert-False $ok
                Assert-Match 'sccache could not move back: robocopy .* failed with exit code' (@($warnings) -join ' ')
            }
        }
    }
}
