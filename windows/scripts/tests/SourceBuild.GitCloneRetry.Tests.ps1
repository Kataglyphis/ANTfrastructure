#requires -Version 7.0
# The driver does not retry script failures, so Invoke-GitClone must; a fake git.bat on PATH logs every attempt.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1') -Force -DisableNameChecking

$script:NewFakeGit = New-TestBatchToolSetup -Name 'git.bat' -Line @(
    'echo GIT %* >> "%WBT_GIT_LOG%"',
    'if "%WBT_GIT_MODE%"=="fail" exit /b 128',
    'if exist "%WBT_GIT_FAILONCE%" ( del "%WBT_GIT_FAILONCE%" & mkdir "%WBT_GIT_TARGET%" 2>nul & echo partial > "%WBT_GIT_TARGET%\partial.txt" & exit /b 128 )',
    'mkdir "%WBT_GIT_TARGET%" 2>nul',
    'echo ok > "%WBT_GIT_TARGET%\cloned.txt"'
)

function script:Invoke-GitCloneRetryFixture {
    param([int]$Failures = 0, [string]$Mode = '', [int]$MaxAttempts = 3, [switch]$SkipOnFailure)
    $action = {
        param($fixture)
        $options = @{ RepoUrl = 'https://example.invalid/repo.git'; SourceDir = $fixture.Target; Branch = 'main'
            MaxAttempts = $MaxAttempts; InitialDelaySeconds = 0; SkipOnFailure = $SkipOnFailure }
        if ($Mode -eq 'fail' -and -not $SkipOnFailure) {
            Assert-Throws { Invoke-GitClone @options 3>$null } -MessagePattern "after $MaxAttempts attempts"
        } else {
            $result = Invoke-GitClone @options 3>$null
            if ($Failures -gt 0) {
                Assert-Equal $false (Test-Path (Join-Path $fixture.Target 'partial.txt')) 'partial tree was wiped before retry'
                Assert-Equal $true (Test-Path (Join-Path $fixture.Target 'cloned.txt')) 'retry produced the clone'
            }
            return $result
        }
    }.GetNewClosure()
    Invoke-RecordedRetryFixture -Tool git -ToolSetup $script:NewFakeGit -Body $action -Failures $Failures -Mode $Mode
}

Describe 'Invoke-GitClone retry' {
    It 'succeeds first try with exactly one git invocation' {
        $fixture = Invoke-GitCloneRetryFixture
        Assert-Equal $true $fixture.Result 'green clone returns $true'
        Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^GIT clone --branch main '
    }

    It 'retries a transient failure once and wipes the partial tree between attempts' {
        $fixture = Invoke-GitCloneRetryFixture -Failures 1
        Assert-Equal $true $fixture.Result 'recovers on the second attempt'
        Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^GIT clone ', '^GIT clone '
    }

    It 'throws after MaxAttempts with the attempt count in the message' {
        $fixture = Invoke-GitCloneRetryFixture -Mode fail -MaxAttempts 3
        Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^GIT clone ', '^GIT clone ', '^GIT clone '
    }

    It 'returns $false (no throw) after MaxAttempts with -SkipOnFailure' {
        $fixture = Invoke-GitCloneRetryFixture -Mode fail -MaxAttempts 2 -SkipOnFailure
        Assert-Equal $false $fixture.Result 'SkipOnFailure degrades persistent failure to $false'
        Assert-RecordedRetryCalls -Fixture $fixture -Pattern '^GIT clone ', '^GIT clone '
    }

}
