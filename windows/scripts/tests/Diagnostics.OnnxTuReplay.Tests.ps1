#requires -Version 7.0

Describe 'ONNX TU replay diagnostic reporting' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Test-OnnxTuReplay.ps1' `
            -FunctionName 'Write-Chunked', 'Write-ReplayDifference', 'Write-ReplayTokenDifference')

    It 'keeps the first 4600 characters in 230-character chunks' {
        $lines = @(Write-Chunked -Prefix 'xformPP|' -Line ('x' * 4610) -Limit 4600 6>&1 | ForEach-Object { "$($_.MessageData)" })
        Assert-Equal 20 $lines.Count 'twenty output chunks'
        Assert-Equal 239 $lines[0].Length 'prefix and 230 characters'
        Assert-Equal 4600 (($lines | ForEach-Object { $_.Substring(9) }) -join '').Length 'no more than the trace limit'
    }

    It 'keeps both finding labels and the plan and execution counts' {
        $lines = @(Write-ReplayTokenDifference -HeaderFormat 'delta: plan={0} exec={1}' `
                -Plan @('A', 'B') -Executed @('B', 'C') -OnlyPlanLabel 'LOST' -OnlyExecutedLabel 'ADDED' `
                6>&1 | ForEach-Object { "$($_.MessageData)" })
        Assert-Equal 'delta: plan=2 exec=2' $lines[0] 'counts'
        Assert-True (($lines -join '|') -match 'LOST: A') 'lost plan item'
        Assert-True (($lines -join '|') -match 'ADDED: C') 'added execution item'
    }
}
