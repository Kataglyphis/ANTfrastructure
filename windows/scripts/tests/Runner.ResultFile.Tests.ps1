#requires -Version 7.0
# Tests a real child result file, not test coverage or report-upload behavior.

. (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Runner.Parallel.Tests.ps1' -FunctionName New-RunnerCopy)

Describe 'Invoke-Tests.ps1 child result paths' {
    It 'creates a missing result directory and writes the actual tally' {
        Invoke-InTestDir { param($dir)
            $tests = New-RunnerCopy -Dir $dir -Suites @{
                'A.Tests.ps1' = "Describe 'a' { It 'passes' { Assert-True `$true } }"
            }
            $result = Join-Path $dir 'new/nested/tally.json'
            $output = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $tests 'Invoke-Tests.ps1') `
                -Only 'A.Tests.ps1' -ResultFile $result 2>&1)
            Assert-Equal 0 $LASTEXITCODE ($output -join ' | ')
            Assert-True (Test-Path -LiteralPath $result -PathType Leaf) 'the child writes the requested result'
            $tally = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
            Assert-Equal 1 $tally.Passed 'the saved tally reports the real pass'

            $runner = Join-Path $tests 'Invoke-Tests.ps1'
            $source = [IO.File]::ReadAllText($runner)
            $anchor = '    if ($resultParent) { $null = New-Item -ItemType Directory -Force -Path $resultParent -ErrorAction Stop }'
            $mutant = Update-TestLiteralText -Text $source -Find $anchor -Replace '    $null = $resultParent' `
                -ErrorLabel 'result-directory mutant'
            [IO.File]::WriteAllText($runner, $mutant)
            $broken = Join-Path $dir 'missing/again/tally.json'
            $null = @(& pwsh -NoProfile -NonInteractive -File $runner -Only 'A.Tests.ps1' -ResultFile $broken 2>&1)
            Assert-Equal 1 $LASTEXITCODE 'removing directory creation must fail the child'
        }
    }
}
