#requires -Version 7.0
# The fake verifies forwarded arguments and failure ordering; it never tests real HTTP or archive contents.

function Invoke-DownloadPreludeFixture {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][scriptblock]$Body, [string]$Prelude = (Get-TestDownloadPrelude))
    Invoke-WithFunctionModule -Text $Prelude -FunctionName Invoke-DownloadWithRetry -Prefix Fake -FixtureState $State -Body $Body
}

Describe 'Harness download transport fixture' {
    It 'records the full download request before applying caller policy and writes exact archive text silently' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName Get-TestDownloadPrelude `
            -Find 'Sha = $ExpectedSha256' -Replace "Sha = ''" -Expected 'the SHA pin must be recorded' -IncludeControl -Body {
        $state = New-TestCallState @{ DownloadContent = "archive`nMiXeD"; Download = {
            param($record, $state)
            Assert-Equal 1 $state.Calls.Count 'the attempt is visible to caller policy'
            $record.Kind = 'caller kind'
        } }
        Invoke-DownloadPreludeFixture -Prelude (Get-MutTestDownloadPrelude) -State $state -Body { param($state)
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir 'archive [pin].zip'
                $output = @(Invoke-FakeDownloadWithRetry -Url 'https://fixture.invalid/tool.zip' -DestinationPath $path -Description 'caller label' -ExpectedSha256 'aBcD' -ExpectSignature PK)
                Assert-Equal 0 $output.Count 'download setup must not add stdout'
                Assert-Equal "archive`nMiXeD" ([IO.File]::ReadAllText($path)) 'archive text must be exact'
                $request = $state.Calls[0]
                Assert-Equal 'https://fixture.invalid/tool.zip' $request.Url
                Assert-Equal $path $request.Destination
                Assert-Equal 'caller label' $request.Description
                Assert-Equal 'aBcD' $request.Sha 'the SHA pin must be recorded'
                Assert-Equal PK $request.Signature
                Assert-Equal 'caller kind' $request.Kind 'caller changes remain on the recorded request'
            }
        }
        }
    }

    It 'retains a failed request without creating an archive or swallowing its exception' {
        $state = New-TestCallState @{ Download = { param($record) $record.Kind = 'failed fetch'; throw 'download callback sentinel' } }
        Invoke-DownloadPreludeFixture -State $state -Body { param($state)
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir absent.zip
                Assert-Throws { Invoke-FakeDownloadWithRetry -Url rejected -DestinationPath $path } -MessagePattern 'download callback sentinel'
                Assert-Equal 1 $state.Calls.Count 'failure keeps the attempted request'
                Assert-Equal 'failed fetch' $state.Calls[0].Kind
                Assert-False (Test-Path -LiteralPath $path) 'a failed callback cannot create an archive'
            }
        }
    }

    It 'supports a recorder without a caller callback or custom archive content' {
        Invoke-DownloadPreludeFixture -State (New-TestCallState) -Body { param($state)
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir default.zip
                Invoke-FakeDownloadWithRetry -DestinationPath $path
                Assert-Equal 'archive' ([IO.File]::ReadAllText($path))
                Assert-Equal 1 $state.Calls.Count
                Assert-Null $state.Calls[0].Signature
                Assert-Null $state.Calls[0].Sha
            }
        }
    }
}
