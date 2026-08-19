#requires -Version 7.0
# Tests for Start-/Complete-SccacheServerSession (WindowsSourceBuild.Common.psm1,
# #107) — the sccache prologue/epilogue extracted from the chain functions. The
# two behaviors that each cost a false alarm are pinned here: the PER-STAGE
# error-log truncation (an append-only log on the shared mount replayed a
# previous run's failures as a live regression) and the failures-first dump.
# -SccachePath is the test seam: a fake .cmd logs every invocation.

Describe 'Start-SccacheServerSession' {

    $newFakeSccache = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo SCCACHE %* >> "%WBT_SCC_LOG%"',
            'exit /b 0'
        )
        $path = Join-Path $dir 'sccache.cmd'
        Set-Content -LiteralPath $path -Value ($lines -join "`r`n") -Encoding ASCII
        return $path
    }

    It 'stops then starts the server, truncating the error log in between' {
        Invoke-InTestDir { param($dir)
            $fake = & $newFakeSccache $dir
            $callLog = Join-Path $dir 'calls.log'
            $errLog = Join-Path $dir 'logs\sccache-err.log'
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $errLog)
            Set-Content -LiteralPath $errLog -Value 'STALE failure line from a previous run' -Encoding ASCII
            Invoke-WithEnv @{ WBT_SCC_LOG = $callLog; SCCACHE_ERROR_LOG = $errLog } {
                Start-SccacheServerSession -SccachePath $fake 6>$null
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $callLog)
            Assert-Equal 2 $calls.Count 'exactly stop + start'
            Assert-Match '^SCCACHE --stop-server' $calls[0] 'stop comes first (fresh server wins)'
            Assert-Match '^SCCACHE --start-server' $calls[1] 'explicit start after the truncate'
            $left = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
            Assert-True ([string]::IsNullOrWhiteSpace($left)) 'stale error-log content was truncated (per-stage attribution)'
        }
    }

    It 'creates a missing error-log parent directory' {
        Invoke-InTestDir { param($dir)
            $fake = & $newFakeSccache $dir
            $errLog = Join-Path $dir 'not-yet\deeper\err.log'
            Invoke-WithEnv @{ WBT_SCC_LOG = (Join-Path $dir 'calls.log'); SCCACHE_ERROR_LOG = $errLog } {
                Start-SccacheServerSession -SccachePath $fake 6>$null
            }.GetNewClosure()
            Assert-True (Test-Path (Split-Path $errLog)) 'parent chain was created so the server can open the log'
        }
    }

    It 'is a silent no-op when sccache is absent' {
        Invoke-InTestDir { param($dir)
            # PATH reduced to the (sccache-less) test dir so the default
            # Get-Command resolution finds nothing.
            Invoke-WithEnv @{ PATH = $dir; SCCACHE_ERROR_LOG = '' } {
                Start-SccacheServerSession 6>$null
            }
            Assert-True $true 'no throw without sccache (best-effort contract)'
        }
    }
}

Describe 'Complete-SccacheServerSession' {

    $newFakeSccache = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo SCCACHE %* >> "%WBT_SCC_LOG%"',
            'exit /b 0'
        )
        $path = Join-Path $dir 'sccache.cmd'
        Set-Content -LiteralPath $path -Value ($lines -join "`r`n") -Encoding ASCII
        return $path
    }

    It 'stops the server and dumps error/warn lines failures-first' {
        Invoke-InTestDir { param($dir)
            $fake = & $newFakeSccache $dir
            $callLog = Join-Path $dir 'calls.log'
            $errLog = Join-Path $dir 'err.log'
            Set-Content -LiteralPath $errLog -Value @(
                'DEBUG chatter 1', 'ERROR L0 write failed', 'DEBUG chatter 2', 'WARN cache eviction'
            ) -Encoding ASCII
            $out = Invoke-WithEnv @{ WBT_SCC_LOG = $callLog; SCCACHE_ERROR_LOG = $errLog } {
                Complete-SccacheServerSession -SccachePath $fake 6>&1 | Out-String
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $callLog)
            Assert-Equal 1 $calls.Count 'exactly one sccache invocation'
            Assert-Match '^SCCACHE --stop-server' $calls[0] 'the epilogue flushes via --stop-server'
            Assert-Match '2 error/warn line' $out 'failures are counted and surfaced first'
            Assert-Match 'ERROR L0 write failed' $out 'the failure line itself lands in the build log'
        }
    }

    It 'falls back to the tail when the log has no error/warn lines' {
        Invoke-InTestDir { param($dir)
            $fake = & $newFakeSccache $dir
            $errLog = Join-Path $dir 'err.log'
            Set-Content -LiteralPath $errLog -Value @('DEBUG a', 'DEBUG b') -Encoding ASCII
            $out = Invoke-WithEnv @{ WBT_SCC_LOG = (Join-Path $dir 'calls.log'); SCCACHE_ERROR_LOG = $errLog } {
                Complete-SccacheServerSession -SccachePath $fake 6>&1 | Out-String
            }.GetNewClosure()
            Assert-Match 'no error/warn lines; tail follows' $out 'quiet logs still show a context tail'
        }
    }

    It 'names an error log the server never opened' {
        Invoke-InTestDir { param($dir)
            $fake = & $newFakeSccache $dir
            $out = Invoke-WithEnv @{ WBT_SCC_LOG = (Join-Path $dir 'calls.log'); SCCACHE_ERROR_LOG = (Join-Path $dir 'never-written.log') } {
                Complete-SccacheServerSession -SccachePath $fake 6>&1 | Out-String
            }.GetNewClosure()
            Assert-Match 'never opened it' $out 'a missing log is reported, not silently skipped'
        }
    }
}
