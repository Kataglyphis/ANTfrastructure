#requires -Version 7.0
# Invoke-SourceBuildChain drives every media branch: a wrong order or a swallowed stage exit breaks the chain.

# $Count fake stages logging their -SourceDir; the leading comma keeps a one-stage tree an array.
$newStageTree = {
    param([string]$Dir, [string]$Log, [int]$Count)
    # $SourceDir/$InstallDir stay literal; $Log is interpolated into the path.
    $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$Log' -Value `$SourceDir"
    $letters = @(0..($Count - 1) | ForEach-Object { [string][char](97 + $_) })
    foreach ($s in $letters) { Set-Content -LiteralPath (Join-Path $Dir "$s.ps1") -Value $body -Encoding ASCII }
    return , @($letters | ForEach-Object { @{ Name = $_.ToUpperInvariant(); Script = "$_.ps1"; SourceDir = "src-$_" } })
}

function Assert-SourceBuildStageLog {
    param([Parameter(Mandatory)][string]$Log, [Parameter(Mandatory)][string[]]$Expected)
    $actual = @(Get-Content -LiteralPath $Log)
    Assert-Equal $Expected.Count $actual.Count 'every expected stage ran exactly once'
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Expected[$index] $actual[$index] "stage log entry $index"
    }
}

Describe 'Invoke-SourceBuildChain' {

    It 'runs every stage in order, forwarding its SourceDir and the shared InstallDir' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'order.log'
            # Logs "<SourceDir>|<InstallDir>", since InstallDir forwarding is this case's subject.
            $body = "param([string]`$SourceDir,[string]`$InstallDir)`nAdd-Content -LiteralPath '$log' -Value (`$SourceDir + '|' + `$InstallDir)"
            Set-Content -LiteralPath (Join-Path $dir 'a.ps1') -Value $body -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'b.ps1') -Value $body -Encoding ASCII

            $stages = @(
                @{ Name = 'A'; Script = 'a.ps1'; SourceDir = 'C:\src\a' }
                @{ Name = 'B'; Script = 'b.ps1'; SourceDir = 'C:\src\b' }
            )
            Invoke-SourceBuildChain -Label 'test' -Stages $stages -InstallDir 'C:\inst' -ScriptDir $dir

            Assert-SourceBuildStageLog -Log $log -Expected 'C:\src\a|C:\inst', 'C:\src\b|C:\inst'
        }
    }

    It 'throws on a stage that exits non-zero (native-exit safety net) and stops the chain' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'ran.log'
            $stages = & $newStageTree $dir $log 3
            # Appended, so A and C stay ordinary stages.
            Add-Content -LiteralPath (Join-Path $dir 'b.ps1') -Value 'exit 3' -Encoding ASCII
            Assert-Throws { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir } 'a non-zero stage exit must throw'

            $ran = @(Get-Content -LiteralPath $log)
            Assert-True  ($ran -contains 'src-a') 'the first (passing) stage ran'
            Assert-True  ($ran -contains 'src-b') 'the failing stage ran'
            Assert-False ($ran -contains 'src-c') 'the stage after the failure did NOT run'
        }
    }

    foreach ($case in @(
            @{ Name = '-StartAt skips the stages before the named one (resume path)'; Log = 'resume.log'; Count = 3; Runs = @(@{ StartAt = 'B' }); Expected = 'src-b', 'src-c' }
            @{ Name = '-StartAt with an unknown stage name throws before running anything'; Log = 'none.log'; Count = 1; Runs = @(@{ StartAt = 'TYPO' }); Why = 'unknown -StartAt must throw (a typo must not rebuild from scratch)' }
            @{ Name = '-Until stops AFTER the named stage (inclusive) — the BK split-layer path'; Log = 'until.log'; Count = 3; Runs = @(@{ Until = 'B' }); Expected = 'src-a', 'src-b' }
            # exactly how Dockerfile.media-builder's two RUN layers call the wrapper
            @{ Name = '-Until layer 1 + -StartAt layer 2 partition the chain without overlap or gap'; Log = 'split.log'; Count = 4; Runs = @(@{ Until = 'B' }, @{ StartAt = 'C' }); Expected = 'src-a', 'src-b', 'src-c', 'src-d' }
            @{ Name = '-Until with an unknown stage name throws before running anything'; Log = 'noneu.log'; Count = 1; Runs = @(@{ Until = 'TYPO' }); Why = 'unknown -Until must throw (a typo must not silently run the whole chain)' }
        )) {
        It $case.Name {
            Invoke-InTestDir { param($dir)
                $log = Join-Path $dir $case.Log
                $stages = & $newStageTree $dir $log $case.Count
                $runAll = { foreach ($run in $case.Runs) { Invoke-SourceBuildChain -Label 't' -Stages $stages -ScriptDir $dir @run } }
                if ($case.Contains('Why')) {
                    Assert-Throws $runAll $case.Why
                    Assert-False (Test-Path $log) 'no stage ran'
                } else {
                    & $runAll
                    Assert-SourceBuildStageLog -Log $log -Expected $case.Expected
                }
            }
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

Describe 'Source build stage-log verifier' {
    It 'rejects missing, extra and reordered stages without invoking a build chain' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'stage-verdict.log'
            $expected = @('a', 'b')
            Set-Content -LiteralPath $log -Value $expected
            Assert-SourceBuildStageLog -Log $log -Expected $expected
            foreach ($mutation in 'missing', 'extra', 'reordered') {
                $mutant = switch ($mutation) {
                    missing { $expected[0] }
                    extra { $expected + 'unexpected' }
                    reordered { $expected[1..0] }
                }
                Set-Content -LiteralPath $log -Value $mutant
                Assert-Throws { Assert-SourceBuildStageLog -Log $log -Expected $expected } -MessagePattern 'every expected stage|stage log entry'
            }
        }
    }
}
