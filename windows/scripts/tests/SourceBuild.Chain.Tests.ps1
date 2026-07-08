# Tests for Invoke-SourceBuildChain — the shared *-all.ps1 orchestrator loop (media-core,
# media-litert). A regression here breaks the run+commit chains: wrong stage order, a
# swallowed non-zero stage exit, or a stage running after an earlier failure.

Describe 'Invoke-SourceBuildChain' {

    It 'runs every stage in order, forwarding its SourceDir and the shared InstallDir' {
        $global:LASTEXITCODE = 0   # isolate from any prior test's native exit code
        $dir = New-TestDir
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

    It 'throws on a stage that exits non-zero (native-exit safety net) and stops the chain' {
        $global:LASTEXITCODE = 0   # so the first (passing) stage does not inherit a stale code
        $dir = New-TestDir
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
