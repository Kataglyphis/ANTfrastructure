#requires -Version 7.0
# Local paths cover scope restoration and forwarding; no child process or build is started.

Describe 'Harness working-directory scope' {
    It 'uses literal paths, forwards stdout and native results, and removes the bracket-named fixture' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName Invoke-InTestDir `
            -Find 'Remove-Item -LiteralPath $d' -Replace 'Remove-Item -Path $d' -Expected 'literal fixture root must be removed' -IncludeControl -Body {
            Invoke-DirectoryCleanupProbe { param($record)
                Invoke-MutInTestDir -Prefix 'location [literal]-' -Body { param($dir)
                    $record.Path = $dir
                    $original = (Get-Location).Path
                    $output = @(Invoke-InTestLocation -Path $dir -Body {
                        (Get-Location).Path
                        'scope output'
                        $global:LASTEXITCODE = 23
                    })
                    Assert-Equal 2 $output.Count
                    Assert-Equal $dir $output[0] 'the bracket path must be entered literally'
                    Assert-Equal 'scope output' $output[1]
                    Assert-Equal 23 $global:LASTEXITCODE
                    Assert-Equal $original (Get-Location).Path 'successful scope restores location'
                }
                Assert-False (Test-Path -LiteralPath $record.Path) 'literal fixture root must be removed'
            }
        }
    }

    It 'restores the caller location when the body throws' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName Invoke-InTestLocation `
            -Find 'finally { Pop-Location }' -Replace 'finally { }' -Expected 'failed scope restores location' -IncludeControl -Body {
            Invoke-InTestDir { param($dir)
                $original = (Get-Location).Path
                $depth = @(Get-Location -Stack).Count
                try {
                    Assert-Throws { Invoke-MutInTestLocation -Path $dir -Body { throw 'location body sentinel' } } -MessagePattern 'location body sentinel'
                    Assert-Equal $original (Get-Location).Path 'failed scope restores location'
                } finally {
                    while (@(Get-Location -Stack).Count -gt $depth) { Pop-Location }
                    Set-Location -LiteralPath $original
                }
            }
        }
    }

    It 'refuses an absent location before executing the body under a permissive error preference' {
        Invoke-InTestDir { param($dir)
            $record = [pscustomobject]@{ Called = $false }
            $ErrorActionPreference = 'Continue'
            Assert-Throws {
                Invoke-InTestLocation -Path (Join-Path $dir absent) -Body { $record.Called = $true } 2>$null
            } -MessagePattern 'absent'
            Assert-False $record.Called 'an invalid location must not execute the body'
        }
    }
}
