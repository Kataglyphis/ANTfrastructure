#requires -Version 7.0
# The fixture executes copy loops, but cannot prove cross builds or staged binaries.

Describe 'Shared source-copy loop fixture' {
    It 'selects exactly one parsed copy loop by variable and condition marker' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'driver.ps1'
            Write-TestFileTree -Root $dir -Files @{ 'driver.ps1' = @'
foreach ($other in 'unrelated') { Copy-Item -LiteralPath $other -Destination unused }
foreach ($rel in 'fixture.txt') {
    Copy-Item -LiteralPath (Join-Path $repoRoot $rel) -Destination (Join-Path $Destination $rel)
}
'@ }
            $loop = Get-TestSourceCopyLoopText -ScriptPath $path -LoopVariable rel -ConditionContains 'fixture.txt'
            Assert-Match 'foreach \(\$rel in' $loop
            Assert-False ($loop.Contains('unrelated'))
            Assert-Throws { Get-TestSourceCopyLoopText -ScriptPath $path -LoopVariable other -ConditionContains 'fixture.txt' } -MessagePattern 'found 0'
            $text = [IO.File]::ReadAllText($path)
            [IO.File]::WriteAllText($path, $text.Replace('Copy-Item -LiteralPath (Join-Path $repoRoot $rel)', 'Write-Host -Object (Join-Path $repoRoot $rel)'))
            Assert-Throws { Get-TestSourceCopyLoopText -ScriptPath $path -LoopVariable rel } -MessagePattern 'found 0'
            [IO.File]::WriteAllText($path, "$text`n$text")
            Assert-Throws { Get-TestSourceCopyLoopText -ScriptPath $path -LoopVariable rel -ConditionContains 'fixture.txt' } -MessagePattern 'found 2'
            [IO.File]::WriteAllText($path, 'foreach ($rel in')
            Assert-Throws { Get-TestSourceCopyLoopText -ScriptPath $path -LoopVariable rel } -MessagePattern 'parse errors'
        }
    }

    It 'runs caller-named variables and detects a removed copy' {
        Invoke-InTestDir { param($dir)
            $loop = 'foreach ($rel in ''fixture.txt'') { Copy-Item -LiteralPath (Join-Path $workspacePath $rel) -Destination (Join-Path $tests $rel) }'
            $stage = Invoke-TestSourceCopyLoop -Loop $loop -Root (Join-Path $dir 'control') -Files @{ 'fixture.txt' = 'owned' } -SourceVariableName workspacePath -DestinationVariableName tests
            Assert-Equal 'owned' ([IO.File]::ReadAllText((Join-Path $stage 'fixture.txt')))
            $mutant = $loop.Replace('Copy-Item -LiteralPath (Join-Path $workspacePath $rel) -Destination (Join-Path $tests $rel)', '$null = Join-Path $workspacePath $rel')
            Assert-False ($mutant -eq $loop)
            $stage = Invoke-TestSourceCopyLoop -Loop $mutant -Root (Join-Path $dir 'mutant') -Files @{ 'fixture.txt' = 'owned' } -SourceVariableName workspacePath -DestinationVariableName tests
            Assert-False (Test-Path -LiteralPath (Join-Path $stage 'fixture.txt'))
        }
    }

    It 'rejects malformed loops before allocating a file tree' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'invalid'
            Assert-Throws { Invoke-TestSourceCopyLoop -Loop 'foreach ($rel in' -Root $root -Files @{ 'fixture.txt' = 'owned' } -SourceVariableName repoRoot -DestinationVariableName Destination } -MessagePattern 'failed to parse'
            Assert-False (Test-Path -LiteralPath $root)
            Assert-Throws { Invoke-TestSourceCopyLoop -Loop '$x = 1' -Root $root -Files @{} -SourceVariableName repoRoot -DestinationVariableName repoRoot } -MessagePattern 'must differ'
            Assert-False (Test-Path -LiteralPath $root)
        }
    }
}
