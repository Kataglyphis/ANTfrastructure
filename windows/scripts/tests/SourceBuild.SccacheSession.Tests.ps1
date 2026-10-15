#requires -Version 7.0
# Per-stage truncation matters: an append-only log on the shared mount replays old failures as live ones.

# A fake whose --start-server fails as a stalled level makes it fail: while a bucket is set, or -Always.
$newRefusingSccache = {
    param($dir, [switch]$Always)
    $refuse = if ($Always) { 'goto refuse' } else { 'if defined SCCACHE_BUCKET goto refuse' }
    $lines = @(
        '@echo off',
        'echo SCCACHE %1 [%SCCACHE_BUCKET%] >> "%WBT_SCC_LOG%"',
        'if not "%1"=="--start-server" exit /b 0',
        $refuse,
        'exit /b 0',
        ':refuse',
        'echo sccache: error: Timed out waiting for server startup 1>&2',
        'exit /b 2'
    )
    $path = Join-Path $dir 'sccache.cmd'
    Set-Content -LiteralPath $path -Value ($lines -join "`r`n") -Encoding ASCII
    return $path
}

# File scope: both Describes below use the same fake (WBT_SCC_LOG appender).
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

Describe 'Start-SccacheServerSession' {

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

    It 'drops a bucket the server will not start with, and starts it again on the other levels' {
        Invoke-InTestDir { param($dir)
            $fake = & $newRefusingSccache $dir
            $callLog = Join-Path $dir 'calls.log'
            Invoke-WithEnv @{ WBT_SCC_LOG = $callLog; SCCACHE_ERROR_LOG = ''; SCCACHE_BUCKET = 'sccache'; SCCACHE_ENDPOINT = 'http://192.0.2.1:3900'
                SCCACHE_REGION = 'garage'; SCCACHE_S3_USE_SSL = 'false'; SCCACHE_MULTILEVEL_CHAIN = 'webdav,s3' } {
                Start-SccacheServerSession -SccachePath $fake -WarningVariable w -WarningAction SilentlyContinue 6>$null
                Assert-Null $env:SCCACHE_BUCKET 'the bucket is gone for this RUN'
                Assert-Null $env:SCCACHE_MULTILEVEL_CHAIN 'WebDAV alone needs no chain'
                Assert-Match 'did not start with it' "$($w[0])"
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $callLog)
            Assert-Equal 'SCCACHE --stop-server [sccache],SCCACHE --start-server [sccache],SCCACHE --stop-server [],SCCACHE --start-server []' (($calls | ForEach-Object { $_.Trim() }) -join ',')
        }
    }

    It 'does not retry a failed start that had no S3 level to drop' {
        Invoke-InTestDir { param($dir)
            $fake = & $newRefusingSccache $dir -Always
            $callLog = Join-Path $dir 'calls.log'
            Invoke-WithEnv @{ WBT_SCC_LOG = $callLog; SCCACHE_ERROR_LOG = ''; SCCACHE_BUCKET = $null } {
                Start-SccacheServerSession -SccachePath $fake 6>$null
            }.GetNewClosure()
            Assert-Equal 2 @(Get-Content -LiteralPath $callLog).Count 'stop and one start'
        }
    }

    It 'is a silent no-op when sccache is absent' {
        Invoke-InTestDir { param($dir)
            # PATH is only the test dir, so Get-Command finds no sccache.
            Invoke-WithEnv @{ PATH = $dir; SCCACHE_ERROR_LOG = '' } {
                Start-SccacheServerSession 6>$null
            }
            Assert-True $true 'no throw without sccache (best-effort contract)'
        }
    }
}

Describe 'Complete-SccacheServerSession' {

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
