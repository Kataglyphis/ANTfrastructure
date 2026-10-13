#requires -Version 7.0
# cleanup-disk-space's wait mode must end on the done marker, on a dead process and on its timeout, and never fail the job.

$script:waitScript = Join-Path (Get-RepoRoot) '.github\actions\cleanup-disk-space\Wait-DiskCleanup.ps1'

function Invoke-Wait([string]$StateDir, [double]$TimeoutMinutes = 1) {
    $envFile = Join-Path $StateDir 'github_env.txt'
    Set-Content -LiteralPath $envFile -Value ''
    $out = Invoke-WithEnv @{ GITHUB_ENV = $envFile } {
        & pwsh -NoProfile -File $script:waitScript -StateDir $StateDir -TimeoutMinutes $TimeoutMinutes -PollSeconds 0.2 2>&1 | Out-String
    }
    [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE; Env = (Get-Content -LiteralPath $envFile -Raw) }
}

function Start-Sleeper([int]$Seconds) {
    Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "Start-Sleep -Seconds $Seconds" -PassThru -WindowStyle Hidden
}

function Set-PidFile([string]$StateDir, [System.Diagnostics.Process]$Proc) {
    Set-Content -LiteralPath (Join-Path $StateDir 'disk-cleanup.pid') -Value "$($Proc.Id) $($Proc.StartTime.ToUniversalTime().Ticks)"
}

Describe 'cleanup-disk-space: wait mode' {
    It 'does nothing when no background run was started' {
        Invoke-InTestDir {
            param($d)
            $r = Invoke-Wait $d
            Assert-Equal 0 $r.Exit 'wait never fails the job'
            Assert-Match 'No background disk cleanup to wait for' $r.Out
            Assert-False ($r.Env -match 'ANTF_DISK_CLEANUP') 'nothing ran, so nothing is marked done'
        }
    }

    It 'returns on the done marker, prints the log and marks the cleanup done' {
        Invoke-InTestDir {
            param($d)
            Set-PidFile $d (Get-Process -Id $PID)
            Set-Content -LiteralPath (Join-Path $d 'disk-cleanup.done') -Value 'seconds=42 c_before_gb=29 c_after_gb=68'
            Set-Content -LiteralPath (Join-Path $d 'disk-cleanup.log') -Value 'Removing C:\hostedtoolcache ...'
            $r = Invoke-Wait $d
            Assert-Equal 0 $r.Exit
            Assert-Match 'seconds=42' $r.Out 'the timing reaches the job log'
            Assert-Match 'Removing C:\\hostedtoolcache' $r.Out 'the detached log reaches the job log'
            Assert-Match 'ANTF_DISK_CLEANUP=done' $r.Env 'a second wait is skipped'
            Assert-False (Test-Path (Join-Path $d 'disk-cleanup.pid')) 'the pid file is consumed'
            Assert-True (Test-Path (Join-Path $d 'disk-cleanup.waited')) 'the waited seconds are recorded'
        }
    }

    It 'waits for a live run and warns when it exits without its marker' {
        Invoke-InTestDir {
            param($d)
            $p = Start-Sleeper 2
            Set-PidFile $d $p
            $r = Invoke-Wait $d
            Assert-Equal 0 $r.Exit
            Assert-True $p.HasExited 'it waited for the process'
            Assert-Match 'exited without its done marker' $r.Out
        }
    }

    It 'treats a recycled pid as a finished run' {
        Invoke-InTestDir {
            param($d)
            Set-Content -LiteralPath (Join-Path $d 'disk-cleanup.pid') -Value "$PID 1"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Wait $d
            Assert-True ($sw.Elapsed.TotalSeconds -lt 20) 'a live process with another start time is not the cleanup'
            Assert-Match 'exited without its done marker' $r.Out
        }
    }

    It 'gives up after its timeout and lets the job go on' {
        Invoke-InTestDir {
            param($d)
            $p = Start-Sleeper 60
            try {
                Set-PidFile $d $p
                $r = Invoke-Wait $d -TimeoutMinutes 0.02
                Assert-Equal 0 $r.Exit 'a timeout is a warning, not a failure'
                Assert-Match 'still running after' $r.Out
                Assert-False $p.HasExited 'it did not wait for the full minute'
            } finally {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
