#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# sccache drops the slower levels' background uploads when its server stops, so each RUN waits for them first.

BeforeAll {
    $script:repo = Get-RepoRoot
    Import-Module (Join-Path $script:repo 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
    # A stand-in sccache: each call adds -Step writes to level 1 until it reaches -L0, and prints the multi-level JSON.
    function script:New-StatsStub {
        param([Parameter(Mandatory)][string]$Dir, [int]$L0 = 5, [int]$L1Start = 1, [int]$Step = 2, [int]$Failures = 0, [switch]$NoLevels)
        Set-Content -LiteralPath "$Dir\l1.txt" -Value $L1Start
        $levels = if ($NoLevels) { 'null' } else {
            '[{"name":"L0 (webdav)","writes":' + $L0 + ',"write_failures":0},{"name":"L1 (s3)","writes":__L1__,"write_failures":' + $Failures + '}]'
        }
        $body = @"
`$n = [int](Get-Content -LiteralPath '$Dir\l1.txt')
Set-Content -LiteralPath '$Dir\l1.txt' -Value ([Math]::Min($L0, `$n + $Step))
Add-Content -LiteralPath '$Dir\calls.txt' -Value "`$args"
'{"stats":{"compile_requests":9,"multi_level":$levels}}'.Replace('__L1__', "`$n")
"@
        Set-Content -LiteralPath "$Dir\sccache.ps1" -Value $body
        return "$Dir\sccache.ps1"
    }
}

Describe 'Wait-SccacheUploadDrain' {

    It 'returns at once without a multi-level chain, and never asks the server' {
        Invoke-InTestDir { param($d)
            $stub = New-StatsStub -Dir $d
            Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = $null } {
                Assert-Equal 0 (Wait-SccacheUploadDrain -SccachePath $stub -PollSec 0 6>$null)
            }
            Assert-False (Test-Path "$d\calls.txt") 'no --show-stats call'
        }
    }

    It 'returns 0 once level 1 has drained: <Why>' -ForEach @(
        @{ Why = 'its writes reach level 0''s, polled until they do'; Stub = @{ L0 = 5; L1Start = 1; Step = 2 }; Calls = 3 }
        @{ Why = 'a failed upload counts as done, since the stop cannot save it either'; Stub = @{ L0 = 5; L1Start = 3; Step = 0; Failures = 2 }; Calls = 1 }
    ) {
        $case = $_
        Invoke-InTestDir { param($d)
            $stubArgs = $case.Stub
            $stub = New-StatsStub -Dir $d @stubArgs
            Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = 'webdav,s3' } {
                Assert-Equal 0 (Wait-SccacheUploadDrain -SccachePath $stub -PollSec 0 6>$null)
            }
            $calls = @(Get-Content "$d\calls.txt")
            Assert-Equal $case.Calls $calls.Count 'one --show-stats per poll'
            Assert-Equal '--show-stats --stats-format json' "$($calls[0])" 'the JSON counters'
        }
    }

    It 'gives up at -TimeoutSec with the pending count and a warning' {
        Invoke-InTestDir { param($d)
            $stub = New-StatsStub -Dir $d -L0 5 -L1Start 1 -Step 0
            Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = 'webdav,s3' } {
                $pending = Wait-SccacheUploadDrain -SccachePath $stub -TimeoutSec 1 -PollSec 1 -WarningVariable w -WarningAction SilentlyContinue 6>$null
                Assert-Equal 4 $pending
                Assert-Match '4 upload\(s\) still pending after 1 s' "$($w[0])"
            }
        }
    }

    It 'does not wait on a server that reports no per-level counters' {
        Invoke-InTestDir { param($d)
            $stub = New-StatsStub -Dir $d -NoLevels
            Invoke-WithEnv @{ SCCACHE_MULTILEVEL_CHAIN = 'webdav,s3' } {
                Assert-Equal 0 (Wait-SccacheUploadDrain -SccachePath $stub -TimeoutSec 60 -PollSec 0 6>$null)
            }
            Assert-Equal 1 @(Get-Content "$d\calls.txt").Count 'one look, then on'
        }
    }

    It 'runs before the server stop in Complete-SccacheServerSession' {
        $text = [IO.File]::ReadAllText((Join-Path $script:repo 'windows\scripts\modules\WindowsSourceBuild.Common.psm1'))
        Assert-Match '(?s)function Complete-SccacheServerSession.*?Wait-SccacheUploadDrain -SccachePath \$SccachePath.*?--stop-server' $text
    }
}
