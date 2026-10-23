#requires -Version 7.0
# Text fixtures cover replay accounting, not CUDA compilation, sccache execution or ONNX source behavior.

Describe 'ONNX replay shared accounting' {
    It 'preserves literal versus regex counts, both artifact sides, classifier priority and distinct diff labels' {
        $functions = @('Get-ReplayFileMatchCount', 'Write-ReplayDifference', 'Get-ReplayStepFacts', 'Measure-ReplayIntermediate', 'Get-ReplaySymbols')
        $prelude = 'function llvm-nm { "000 T zeta"; "001 T alpha"; "003 T zeta" }'
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/diagnostics/Test-OnnxTuReplay.ps1' -FunctionName $functions -Prelude $prelude -Body {
            Invoke-InTestDir { param($dir)
                $bare = Join-Path $dir bare; $wrap = Join-Path $dir wrap
                Write-TestFileTree -Root $dir -Files @{ 'bare/b.ii' = 'ab a.b A.B ab'; 'bare/a.ii' = ''; 'wrap/c.ii' = 'a.b' }
                $path = Join-Path $bare 'b.ii'
                Assert-Equal 2 (Get-MutReplayFileMatchCount -Path $path -Pattern 'a.b' -SimpleMatch)
                Assert-Equal 2 (Get-MutReplayFileMatchCount -Path $path -Pattern 'a.b')
                Assert-Equal 4 (Get-MutReplayFileMatchCount -Path $path -Pattern 'a.*?b')
                Assert-Equal 0 (Get-MutReplayFileMatchCount -Path (Join-Path $bare 'a.ii') -Pattern x)
                Assert-Throws { Get-MutReplayFileMatchCount -Path (Join-Path $dir missing) -Pattern x -ReadErrorAction Stop } -MessagePattern 'missing'
                $facts = @(Measure-MutReplayIntermediate -BareDirectory $bare -WrappedDirectory $wrap -Patterns @('a.b', 'absent') -SimpleMatch -Sort)
                Assert-Equal 'bare:a.ii,bare:b.ii,wrap:c.ii' (($facts | ForEach-Object { $_.Side + ':' + $_.File.Name }) -join ',')
                Assert-Equal 0 $facts[0].Counts[0]
                Assert-Equal 2 $facts[1].Counts[0]
                Assert-Equal 0 $facts[2].Counts[1]
                $step = Get-MutReplayStepFacts -Line 'cudafe++ cicc -DA -DB' -Rules ([ordered]@{ 'cudafe\+\+' = 'frontend'; cicc = 'device' }) -DefaultKind other -DefinePattern '-D'
                Assert-Equal frontend $step.Kind
                Assert-Equal 2 $step.Defines
                Assert-Equal unknown (Get-MutReplayStepFacts -Line 'plain' -Rules @{} -DefaultKind unknown -DefinePattern '-D').Kind
                $diff = Write-MutReplayDifference -Reference @('shared', 'left') -Difference @('shared', 'right') -OnlyReferenceLabel LOST -OnlyDifferenceLabel ADDED 6>&1 | Out-String
                Assert-Match 'LOST: left' $diff
                Assert-Match 'ADDED: right' $diff
                Assert-False ($diff.Contains('shared'))
                Assert-Equal 'alpha,zeta' ((Get-MutReplaySymbols -Path any) -join ',')
            }
        }
    }
}

$script:ReplayProjectionModule = @{ ScriptPath = 'windows/scripts/diagnostics/Test-OnnxTuReplay.ps1'; FunctionName = @('Get-ReplayStepFacts', 'Get-ReplayStepRecord', 'Format-ReplayTrace') }

function Assert-ReplayProjectionFixture {
    $records = @(Get-MutReplayStepRecord -Lines @('irrelevant', 'cicc -DA', 'cudafe++ -DA -DB') -Pattern 'cicc|cudafe' `
        -Rules ([ordered]@{ 'cudafe\+\+' = 'frontend'; cicc = 'device' }) -DefaultKind host -DefinePattern '-D')
    Assert-Equal 2 $records.Count 'step filtering'
    Assert-Equal 'cicc -DA:device:1|cudafe++ -DA -DB:frontend:2' (($records | ForEach-Object { '{0}:{1}:{2}' -f $_.Line, $_.Kind, $_.Defines }) -join '|')
    $lines = @(Format-MutReplayTrace -Lines @('irrelevant', ('  cicc' + ('x' * 350) + '  '), 'ptxas keep', 'fatbinary excluded') -Prefix sample -Limit 2)
    Assert-Equal 2 $lines.Count 'trace limit'
    Assert-Equal ('sample| cicc' + ('x' * 296) + '|sample| ptxas keep') ($lines -join '|') 'trace bytes, trimming and cap'
    Assert-Equal 0 @(Format-MutReplayTrace -Lines @() -Prefix plan -Limit 40).Count
}

Describe 'ONNX replay step and trace projections' {
    It 'shares filtering and classification while retaining trace ordering and limits' {
        Invoke-WithFunctionModule @script:ReplayProjectionModule -Body { Assert-ReplayProjectionFixture }
    }

    It 'rejects lost step filtering' {
        Invoke-TestFunctionMutations -Find '$Lines | Select-String -Pattern $Pattern' -Replace '$Lines | ForEach-Object { [pscustomobject]@{ Line = $_ } }' -Expected 'step filtering' -Body { Assert-ReplayProjectionFixture } -ModuleArguments $script:ReplayProjectionModule
    }

    It 'rejects lost trace count limits' {
        Invoke-TestFunctionMutations -Find 'Select-Object -First $Limit' -Replace 'ForEach-Object { $_ }' -Expected 'trace limit' -Body { Assert-ReplayProjectionFixture } -ModuleArguments $script:ReplayProjectionModule
    }
}
