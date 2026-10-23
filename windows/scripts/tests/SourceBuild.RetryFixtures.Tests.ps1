#requires -Version 7.0
# Local fixtures check recording, markers, environment restoration and cleanup; native retry policies remain in their Windows suites.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1') -Force -DisableNameChecking

function Assert-RetryFixtureFailure {
    param([Parameter(Mandatory)][scriptblock]$Body, [Parameter(Mandatory)][string]$MessagePattern,
        [scriptblock]$ToolSetup = { param($dir) })
    $seen = [Collections.Generic.List[string]]::new()
    $setupAction = $ToolSetup
    $operation = $Body
    $setup = { param($dir) $seen.Add($dir); & $setupAction $dir }.GetNewClosure()
    try {
        Assert-Throws { Invoke-RecordedRetryFixture -Tool fixture -ToolSetup $setup -Mode fail -Body $operation } -MessagePattern $MessagePattern
        Assert-Equal 1 $seen.Count
        Assert-False (Test-Path -LiteralPath $seen[0])
    } finally {
        foreach ($path in $seen) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

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
        Invoke-WithEnv @{ WBT_FIXTURE_MODE = 'parent' } {
            Assert-RetryFixtureFailure -Body { param($f) throw 'fixture action failed' } -MessagePattern 'fixture action failed'
            Assert-Equal parent $env:WBT_FIXTURE_MODE
        }
    }

    It 'applies caller environment overrides, suppresses setup output and preserves an empty parent variable' {
        Invoke-WithEnv @{ WBT_FIXTURE_MODE = '' } {
            $fixture = Invoke-RecordedRetryFixture -Tool fixture -Mode default -Environment @{ WBT_FIXTURE_MODE = 'override' } -ToolSetup {
                param($dir)
                Assert-Equal 0 $global:LASTEXITCODE 'setup begins with an isolated native exit'
                'setup output is not a fixture result'
            } -Body {
                param($context)
                Assert-Equal override $env:WBT_FIXTURE_MODE
                [IO.File]::WriteAllText($context.Log, 'one attempt')
                'isolated result'
            }
            Assert-Equal 'isolated result' $fixture.Result
            Assert-Equal '' ([Environment]::GetEnvironmentVariable('WBT_FIXTURE_MODE'))
        }
    }

    It 'preserves a setup failure while removing the directory allocated before setup' {
        Assert-RetryFixtureFailure -ToolSetup { param($dir) throw 'setup sentinel' } `
            -Body { throw 'body must not execute' } -MessagePattern '^setup sentinel$'
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
