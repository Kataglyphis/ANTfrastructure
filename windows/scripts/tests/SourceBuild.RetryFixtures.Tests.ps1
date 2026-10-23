#requires -Version 7.0
# Local fixtures check recording, markers, environment restoration and cleanup; native retry policies remain in their Windows suites.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1') -Force -DisableNameChecking

Describe 'Recorded retry fixtures' {
    It 'provides isolated markers and records calls before cleaning up' {
        Invoke-WithEnv @{ WBT_FIXTURE_MODE = 'parent'; WBT_FIXTURE_FAILONCE = $null } {
            $fixture = Invoke-RecordedRetryFixture -Tool fixture -ToolSetup { param($dir) } -Mode fail -Failures 2 -Stall -Body {
                param($f)
                Assert-Equal fail $env:WBT_FIXTURE_MODE
                Assert-True (Test-Path -LiteralPath $env:WBT_FIXTURE_FAILONCE)
                Assert-True (Test-Path -LiteralPath $env:WBT_FIXTURE_FAILONCE2)
                Assert-Equal $f.StallMarker $env:WBT_FIXTURE_STALLMARK
                Assert-Equal $f.Target $env:WBT_FIXTURE_TARGET
                Set-Content -LiteralPath $f.Log -Value 'FAKE first', 'FAKE second'
                return 'body-result'
            }
            Assert-Equal body-result $fixture.Result
            Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^FAKE first$', '^FAKE second$'
            Assert-False (Test-Path -LiteralPath $fixture.Dir)
            Assert-Equal parent $env:WBT_FIXTURE_MODE
            Assert-Null ([Environment]::GetEnvironmentVariable('WBT_FIXTURE_FAILONCE'))
        }
    }

    It 'preserves the action error while restoring its environment and directory' {
        $seen = [System.Collections.Generic.List[string]]::new()
        $setup = { param($dir) $seen.Add($dir) }.GetNewClosure()
        Invoke-WithEnv @{ WBT_FIXTURE_MODE = 'parent' } {
            Assert-Throws {
                Invoke-RecordedRetryFixture -Tool fixture -ToolSetup $setup -Mode fail -Body { param($f) throw 'fixture action failed' }
            } -MessagePattern 'fixture action failed'
            Assert-Equal parent $env:WBT_FIXTURE_MODE
        }
        Assert-Equal 1 $seen.Count
        Assert-False (Test-Path -LiteralPath $seen[0])
    }

    It 'rejects missing attempts and wrong argument trajectories' {
        $fixture = [pscustomobject]@{ Calls = @('FAKE first', 'FAKE second') }
        Assert-Throws { Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^FAKE first$' } -MessagePattern 'recorded retry attempt count'
        Assert-Throws { Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^FAKE first$', '^FAKE missing$' } -MessagePattern 'Assert-Match'
    }

    It 'detects an attempt-count verdict mutant' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Assert-RecordedRetryCalls -Find "Assert-Equal `$Pattern.Count `$Fixture.Calls.Count 'recorded retry attempt count'" -Replace '' -Body {
            $fixture = [pscustomobject]@{ Calls = @('FAKE first', 'FAKE second', 'FAKE third') }
            $check = {
                param($verdict)
                $rejected = $false
                try { & $verdict -Fixture $fixture -Pattern '^FAKE', '^FAKE' } catch { $rejected = $true }
                Assert-True $rejected 'an extra attempted command must fail'
            }.GetNewClosure()
            & $check (Get-Command Assert-RecordedRetryCalls)
            Assert-Throws { & $check (Get-Command Assert-MutRecordedRetryCalls) } -MessagePattern 'an extra attempted command must fail'
        }
    }
}
