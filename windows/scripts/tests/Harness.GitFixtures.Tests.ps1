#requires -Version 7.0
# Disposable real repositories cover local identity, bytes and native failures; no remote or user Git settings are changed.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -DisableNameChecking

Describe 'Harness Git fixture operations' {
    It 'creates a literal repository, commits exact file bytes and confines identity to its local config' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'repo [fixture] space'
            $result = @(New-TestGitRepository -Path $path -InitialBranch 'fixture-main' -UserName 'Fixture Author' -UserEmail 'author@example.invalid')
            Assert-Equal 1 $result.Count 'repository allocation returns only its root'
            Assert-Equal $path $result[0]
            Assert-Equal 'fixture-main' (& git -C $path symbolic-ref --short HEAD)
            Assert-Equal 'Fixture Author' (& git -C $path config --local user.name)
            Assert-Equal 'author@example.invalid' (& git -C $path config --local user.email)
            $output = @(Add-TestGitCommit -Path $path -Files @{ 'nested [dir]/file.txt' = "MiXeD`nbytes"; 'empty.txt' = '' } -Message 'first fixture commit')
            Assert-Equal 0 $output.Count 'commit setup is silent'
            Assert-Equal "MiXeD`nbytes" ([IO.File]::ReadAllText((Join-Path $path 'nested [dir]/file.txt'))) 'fixture bytes remain literal'
            Assert-Equal 'first fixture commit' (& git -C $path log -1 --format=%s)
            Assert-Equal 0 @(& git -C $path status --porcelain).Count 'all fixture files are committed'
            Assert-Equal 'empty.txt|nested [dir]/file.txt' ((& git -C $path ls-files) -join '|') 'no setup files are invented'
        }
    }

    It 'reports a real missing repository and an empty commit as setup failures' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Invoke-TestGitCommand -Path $dir -ArgumentList @('rev-parse', 'HEAD') } -MessagePattern 'Fixture git.*failed with exit'
            $repo = New-TestGitRepository -Path (Join-Path $dir empty)
            Assert-Throws { Add-TestGitCommit -Path $repo } -MessagePattern 'Fixture git commit.*failed with exit'
        }
    }

    It 'cannot turn a failed native tool into successful fixture setup, with a fault control' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/WindowsHarness.GitFixtures.psm1' -FunctionName Invoke-TestGitCommand `
            -Find 'if ($code -ne 0)' -Replace 'if ($false)' -Expected 'expected an exception but none was thrown' -IncludeControl -Body {
                Invoke-WithTestFunction -Name git -Definition { $global:LASTEXITCODE = 19; 'fixture git stderr' } -Body {
                    Assert-Throws { Invoke-MutTestGitCommand -Path unused -ArgumentList status } -MessagePattern 'exit 19: fixture git stderr'
                }
            }
    }
}
