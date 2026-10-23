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
