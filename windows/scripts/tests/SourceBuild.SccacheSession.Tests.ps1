#requires -Version 7.0
# Per-stage truncation matters: an append-only log on the shared mount replays old failures as live ones.

# A fake whose --start-server fails as a stalled level makes it fail: while a bucket is set, or -Always.
$newRefusingSccache = {
    param($dir, [switch]$Always)
    $refuse = if ($Always) { 'goto refuse' } else { 'if defined SCCACHE_BUCKET goto refuse' }
    New-TestBatchTool -Directory $dir -Name 'sccache.cmd' -Line @(
        'echo SCCACHE %1 [%SCCACHE_BUCKET%] >> "%WBT_SCC_LOG%"',
        'if not "%1"=="--start-server" exit /b 0',
        $refuse,
        'exit /b 0',
        ':refuse',
        'echo sccache: error: Timed out waiting for server startup 1>&2',
        'exit /b 2'
    )
}

# File scope: both Describes below use the same fake (WBT_SCC_LOG appender).
$newFakeSccache = {
    param($dir)
    New-TestBatchTool -Directory $dir -Name 'sccache.cmd' -Line @(
        'echo SCCACHE %* >> "%WBT_SCC_LOG%"'
    )
}

function Invoke-SccacheLoggedSession {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$ErrorLog,
        [Parameter(Mandatory)][ValidateSet('Start', 'Complete')][string]$Session, [string[]]$InitialLogLines)
    $fake = & $newFakeSccache $Directory
    $callLog = Join-Path $Directory 'calls.log'
    if ($null -ne $InitialLogLines) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $ErrorLog)
        Set-Content -LiteralPath $ErrorLog -Value $InitialLogLines -Encoding ASCII
    }
    $output = Invoke-WithEnv @{ WBT_SCC_LOG = $callLog; SCCACHE_ERROR_LOG = $ErrorLog } {
        if ($Session -eq 'Start') { Start-SccacheServerSession -SccachePath $fake 6>$null }
        else { Complete-SccacheServerSession -SccachePath $fake 6>&1 | Out-String }
    }.GetNewClosure()
    [pscustomobject]@{ Calls = @(Get-Content -LiteralPath $callLog); Output = $output }
}

Describe 'Start-SccacheServerSession' {

    It 'stops then starts the server, truncating the error log in between' {
        Invoke-InTestDir { param($dir)
            $errLog = Join-Path $dir 'logs\sccache-err.log'
            $result = Invoke-SccacheLoggedSession -Directory $dir -ErrorLog $errLog -Session Start -InitialLogLines 'STALE failure line from a previous run'
            $calls = $result.Calls
            Assert-Equal 2 $calls.Count 'exactly stop + start'
            Assert-Match '^SCCACHE --stop-server' $calls[0] 'stop comes first (fresh server wins)'
            Assert-Match '^SCCACHE --start-server' $calls[1] 'explicit start after the truncate'
            $left = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
            Assert-True ([string]::IsNullOrWhiteSpace($left)) 'stale error-log content was truncated (per-stage attribution)'
        }
    }

    It 'creates a missing error-log parent directory' {
        Invoke-InTestDir { param($dir)
            $errLog = Join-Path $dir 'not-yet\deeper\err.log'
            $null = Invoke-SccacheLoggedSession -Directory $dir -ErrorLog $errLog -Session Start
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
            $result = Invoke-SccacheLoggedSession -Directory $dir -ErrorLog (Join-Path $dir 'err.log') -Session Complete -InitialLogLines @(
                'DEBUG chatter 1', 'ERROR L0 write failed', 'DEBUG chatter 2', 'WARN cache eviction'
            )
            $calls = $result.Calls
            $out = $result.Output
            Assert-Equal 1 $calls.Count 'exactly one sccache invocation'
            Assert-Match '^SCCACHE --stop-server' $calls[0] 'the epilogue flushes via --stop-server'
            Assert-Match '2 error/warn line' $out 'failures are counted and surfaced first'
            Assert-Match 'ERROR L0 write failed' $out 'the failure line itself lands in the build log'
        }
    }

    It 'falls back to the tail when the log has no error/warn lines' {
        Invoke-InTestDir { param($dir)
            $out = (Invoke-SccacheLoggedSession -Directory $dir -ErrorLog (Join-Path $dir 'err.log') -Session Complete -InitialLogLines @('DEBUG a', 'DEBUG b')).Output
            Assert-Match 'no error/warn lines; tail follows' $out 'quiet logs still show a context tail'
        }
    }

    It 'names an error log the server never opened' {
        Invoke-InTestDir { param($dir)
            $out = (Invoke-SccacheLoggedSession -Directory $dir -ErrorLog (Join-Path $dir 'never-written.log') -Session Complete).Output
            Assert-Match 'never opened it' $out 'a missing log is reported, not silently skipped'
        }
    }
}
