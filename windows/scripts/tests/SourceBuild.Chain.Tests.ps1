#requires -Version 7.0
# Tests for Invoke-SourceBuildChain — the shared *-all.ps1 orchestrator loop driving all
# three media branches (media-core, media-litert, media-tvm) and the BK lane's split
# layers (-StartAt/-Until). A regression here breaks the run+commit chains: wrong stage
# order, a swallowed non-zero stage exit, or a stage running after an earlier failure.
# Invoke-InTestDir zeroes $LASTEXITCODE, isolating each case from prior native exits.

Describe 'Invoke-SourceBuildChain' {

    It 'runs every stage in order, forwarding its SourceDir and the shared InstallDir' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'order.log'
            # Fake stage script: record "<SourceDir>|<InstallDir>". $SourceDir/$InstallDir stay
            # literal (the fake script's own params); $log is interpolated into the path.
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value (`$SourceDir + '|' + `$InstallDir)"
            Set-Content -LiteralPath (Join-Path $dir 'a.ps1') -Value $body -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'b.ps1') -Value $body -Encoding ASCII

            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'C:\src\a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'C:\src\b' }
            )
            Invoke-SourceBuildChain -Label 'test' -Stages $stages -InstallDir 'C:\inst' -ScriptDir $dir

            $lines = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $lines.Count 'both stages ran exactly once'
            Assert-Equal 'C:\src\a|C:\inst' $lines[0] 'stage A: its own SourceDir + shared InstallDir'
            Assert-Equal 'C:\src\b|C:\inst' $lines[1] 'stage B ran after A with its own SourceDir'
        }
    }

    It 'throws on a stage that exits non-zero (native-exit safety net) and stops the chain' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'ran.log'
            Set-Content -LiteralPath (Join-Path $dir 'ok.ps1')    -Value "param(`$SourceDir,`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value 'ok'"                 -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'fail.ps1')  -Value "param(`$SourceDir,`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value 'fail'`nexit 3"       -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'never.ps1') -Value "param(`$SourceDir,`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value 'never'"              -Encoding ASCII

            $stages = @(
                @{ Name = 'OK';    Script = 'ok.ps1';    SourceDir = 'x' }
                @{ Name = 'FAIL';  Script = 'fail.ps1';  SourceDir = 'x' }
                @{ Name = 'NEVER'; Script = 'never.ps1'; SourceDir = 'x' }
            )
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir } 'a non-zero stage exit must throw'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-True  ($ran -contains 'ok')    'the first (passing) stage ran'
            Assert-True  ($ran -contains 'fail')  'the failing stage ran'
            Assert-False ($ran -contains 'never') 'the stage after the failure did NOT run'
        }
    }

    It '-StartAt skips the stages before the named one (resume path)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'resume.log'
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value `$SourceDir"
            foreach ($s in 'a', 'b', 'c') { Set-Content -LiteralPath (Join-Path $dir "$s.ps1") -Value $body -Encoding ASCII }
            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'src-a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'src-b' }
                @{ Name = 'C'; Script = 'c.ps1'; SourceDir = 'src-c' }
            )
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt 'B'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $ran.Count 'exactly the resumed suffix ran'
            Assert-Equal 'src-b' $ran[0] 'resume starts AT the named stage'
            Assert-Equal 'src-c' $ran[1] 'later stages still run'
        }
    }

    It '-StartAt with an unknown stage name throws before running anything' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'none.log'
            Set-Content -LiteralPath (Join-Path $dir 'a.ps1') -Value "param(`$SourceDir,`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value 'ran'" -Encoding ASCII
            $stages = @(@{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'x' })
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt 'TYPO' } 'unknown -StartAt must throw (a typo must not rebuild from scratch)'
            Assert-False (Test-Path $log) 'no stage ran'
        }
    }

    It '-Until stops AFTER the named stage (inclusive) — the BK split-layer path' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'until.log'
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value `$SourceDir"
            foreach ($s in 'a', 'b', 'c') { Set-Content -LiteralPath (Join-Path $dir "$s.ps1") -Value $body -Encoding ASCII }
            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'src-a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'src-b' }
                @{ Name = 'C'; Script = 'c.ps1'; SourceDir = 'src-c' }
            )
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -Until 'B'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $ran.Count 'exactly the prefix through -Until ran'
            Assert-Equal 'src-b' $ran[1] 'the -Until stage itself DID run (inclusive)'
        }
    }

    It '-Until layer 1 + -StartAt layer 2 partition the chain without overlap or gap' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'split.log'
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value `$SourceDir"
            foreach ($s in 'a', 'b', 'c', 'd') { Set-Content -LiteralPath (Join-Path $dir "$s.ps1") -Value $body -Encoding ASCII }
            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'src-a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'src-b' }
                @{ Name = 'C'; Script = 'c.ps1'; SourceDir = 'src-c' }
                @{ Name = 'D'; Script = 'd.ps1'; SourceDir = 'src-d' }
            )
            # exactly how Dockerfile.media-builder's two RUN layers call the wrapper
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -Until 'B'
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt 'C'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-Equal 'src-a src-b src-c src-d' ($ran -join ' ') 'every stage exactly once, in order'
        }
    }

    It '-Until with an unknown stage name throws before running anything' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'noneu.log'
            Set-Content -LiteralPath (Join-Path $dir 'a.ps1') -Value "param(`$SourceDir,`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value 'ran'" -Encoding ASCII
            $stages = @(@{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'x' })
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -Until 'TYPO' } 'unknown -Until must throw (a typo must not silently run the whole chain)'
            Assert-False (Test-Path $log) 'no stage ran'
        }
    }

    It 'empty -StartAt runs the full chain (default behavior unchanged)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'full.log'
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value `$SourceDir"
            foreach ($s in 'a', 'b') { Set-Content -LiteralPath (Join-Path $dir "$s.ps1") -Value $body -Encoding ASCII }
            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'src-a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'src-b' }
            )
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt ''
            Assert-Equal 2 @(Get-Content -LiteralPath $log).Count 'all stages ran'
        }
    }
}
