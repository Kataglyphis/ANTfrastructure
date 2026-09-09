#requires -Version 7.0
# Tests for Invoke-SourceBuildChain — the shared *-all.ps1 orchestrator loop driving all
# three media branches (media-core, media-litert, media-tvm) and the BK lane's split
# layers (-StartAt/-Until). A regression here breaks the run+commit chains: wrong stage
# order, a swallowed non-zero stage exit, or a stage running after an earlier failure.
# Invoke-InTestDir zeroes $LASTEXITCODE, isolating each case from prior native exits.

Describe 'Invoke-SourceBuildChain' {

    # One owner for the plain stage tree seven cases built by hand, differing only in how many
    # stages the array had (3, 3, 4, 2 for -StartAt / -Until / split-layer / full-chain, and
    # 1 for the two unknown-name cases — those assert the log never appears, so what the fake
    # stage would have written is irrelevant). Writes $Count fake stage scripts a.ps1, b.ps1,
    # ... into $Dir — each appending only its own -SourceDir to $Log — and returns the
    # matching stage array (@{ Name='A'; Script='a.ps1'; SourceDir='src-a' } ...). The leading
    # comma is required: without it PowerShell unrolls a one-stage tree to a bare hashtable.
    # A case that needs one stage to misbehave appends to that stage's script rather than
    # taking a mode flag here (see the non-zero-exit case). The only hand-built tree left is
    # the order case: its scripts log "<SourceDir>|<InstallDir>" and its SourceDirs are
    # absolute, because InstallDir forwarding is what that case is about.
    $newStageTree = {
        param([string]$Dir, [string]$Log, [int]$Count)
        # $SourceDir/$InstallDir stay literal (the fake script's own params); $Log is
        # interpolated into the Add-Content path.
        $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$Log' -Value `$SourceDir"
        $letters = @(0..($Count - 1) | ForEach-Object { [string][char](97 + $_) })
        foreach ($s in $letters) { Set-Content -LiteralPath (Join-Path $Dir "$s.ps1") -Value $body -Encoding ASCII }
        return , @($letters | ForEach-Object { @{ Name = $_.ToUpperInvariant(); Script = "$_.ps1"; SourceDir = "src-$_" } })
    }

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
            $stages = & $newStageTree $dir $log 3
            # The one line that is this case's subject: stage B still logs itself, then exits
            # non-zero. Appended (not a separate fake) so A and C stay ordinary stages.
            Add-Content -LiteralPath (Join-Path $dir 'b.ps1') -Value 'exit 3' -Encoding ASCII
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir } 'a non-zero stage exit must throw'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-True  ($ran -contains 'src-a') 'the first (passing) stage ran'
            Assert-True  ($ran -contains 'src-b') 'the failing stage ran'
            Assert-False ($ran -contains 'src-c') 'the stage after the failure did NOT run'
        }
    }

    It '-StartAt skips the stages before the named one (resume path)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'resume.log'
            $stages = & $newStageTree $dir $log 3
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
            $stages = & $newStageTree $dir $log 1
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt 'TYPO' } 'unknown -StartAt must throw (a typo must not rebuild from scratch)'
            Assert-False (Test-Path $log) 'no stage ran'
        }
    }

    It '-Until stops AFTER the named stage (inclusive) — the BK split-layer path' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'until.log'
            $stages = & $newStageTree $dir $log 3
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -Until 'B'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $ran.Count 'exactly the prefix through -Until ran'
            Assert-Equal 'src-b' $ran[1] 'the -Until stage itself DID run (inclusive)'
        }
    }

    It '-Until layer 1 + -StartAt layer 2 partition the chain without overlap or gap' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'split.log'
            $stages = & $newStageTree $dir $log 4
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
            $stages = & $newStageTree $dir $log 1
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -Until 'TYPO' } 'unknown -Until must throw (a typo must not silently run the whole chain)'
            Assert-False (Test-Path $log) 'no stage ran'
        }
    }

    It 'empty -StartAt runs the full chain (default behavior unchanged)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'full.log'
            $stages = & $newStageTree $dir $log 2
            Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir -StartAt ''
            Assert-Equal 2 @(Get-Content -LiteralPath $log).Count 'all stages ran'
        }
    }
}
