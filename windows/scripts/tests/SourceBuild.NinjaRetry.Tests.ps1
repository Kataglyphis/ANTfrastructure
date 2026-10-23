#requires -Version 7.0
# A failed ninja -j<N> must retry once at -j<RetryJobs>; a fake ninja.bat logs each attempt, BUILD_JOBS pins the first.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1') -Force -DisableNameChecking

$script:NewFakeNinja = {
    param($dir)
    New-TestBatchTool -Directory $dir -Name 'ninja.bat' -Line @(
        'echo NINJA %* >> "%WBT_NINJA_LOG%"',
        'if "%WBT_NINJA_MODE%"=="fail" ( (if not "%WBT_NINJA_STALLMARK%"=="" echo kill >> "%WBT_NINJA_STALLMARK%") & exit /b 1 )',
        'if exist "%WBT_NINJA_FAILONCE%" ( del "%WBT_NINJA_FAILONCE%" & ( if not "%WBT_NINJA_STALLMARK%"=="" echo kill >> "%WBT_NINJA_STALLMARK%" ) & exit /b 1 )',
        'if exist "%WBT_NINJA_FAILONCE2%" ( del "%WBT_NINJA_FAILONCE2%" & ( if not "%WBT_NINJA_STALLMARK%"=="" echo kill >> "%WBT_NINJA_STALLMARK%" ) & exit /b 1 )'
    )
}

function script:Invoke-NinjaRetryFixture {
    param([int]$RetryJobs = 1, [int]$Jobs = 4, [int]$Failures = 0, [string]$Mode = '',
        [switch]$Stall, [int]$StallRetries = 3, [switch]$ExpectFailure)
    $action = {
        param($fixture)
        $options = @{ BuildDir = $fixture.Dir; RetryJobs = $RetryJobs }
        if ($Stall) { $options.StallMarkerPath = $fixture.StallMarker; $options.StallRetries = $StallRetries }
        if ($ExpectFailure) {
            Assert-Throws { Invoke-NinjaBuildWithRetry @options } -MessagePattern 'Build failed \(exit 1\)'
        } else { Invoke-NinjaBuildWithRetry @options }
    }.GetNewClosure()
    Invoke-RecordedRetryFixture -Tool ninja -ToolSetup $script:NewFakeNinja -Body $action -Failures $Failures -Mode $Mode -Stall:$Stall `
        -Environment @{ BUILD_JOBS = "$Jobs"; NINJA_KEEP_GOING = ''; NINJA_STATUS = '' }
}

function script:Assert-NinjaRetryJobs {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][int[]]$Jobs)
    Assert-RecordedRetryCalls -Fixture $Fixture -Pattern @($Jobs | ForEach-Object { "^NINJA -j $_ " })
}

Describe 'Invoke-NinjaBuildWithRetry' {
    It 'succeeds first try at the full job count and never retries' {
        $fixture = Invoke-NinjaRetryFixture
        Assert-NinjaRetryJobs -Fixture $fixture -Jobs 4
    }

    It 'retries a failed build once with -j<RetryJobs> and succeeds' {
        $fixture = Invoke-NinjaRetryFixture -RetryJobs 2 -Failures 1
        Assert-NinjaRetryJobs -Fixture $fixture -Jobs 4, 2
    }

    It 'throws after the reduced-job retry also fails (exit code in the message)' {
        $fixture = Invoke-NinjaRetryFixture -Mode fail -ExpectFailure
        Assert-NinjaRetryJobs -Fixture $fixture -Jobs 4, 1
    }

    foreach ($stallCase in @(
            @{ Name = 'retries a guard-kill failure at FULL -j, not -j<RetryJobs> (run-6 lesson)'; Failures = 1; Jobs = @(4, 4) },
            @{ Name = 'attributes kills per attempt: two consecutive guard-kill failures get two full-speed retries'; Failures = 2; Jobs = @(4, 4, 4) }
        )) {
        It $stallCase.Name {
            $fixture = Invoke-NinjaRetryFixture -RetryJobs 2 -Failures $stallCase.Failures -Stall
            Assert-NinjaRetryJobs -Fixture $fixture -Jobs $stallCase.Jobs
        }
    }

    It 'bounds stall retries, then falls through to the incremental attempt, then throws' {
        $fixture = Invoke-NinjaRetryFixture -Mode fail -Stall -StallRetries 3 -ExpectFailure
        Assert-NinjaRetryJobs -Fixture $fixture -Jobs 4, 4, 4, 4, 1
    }

    It 'does NOT retry when the job count is already <= RetryJobs' {
        $fixture = Invoke-NinjaRetryFixture -RetryJobs 2 -Jobs 2 -Mode fail -ExpectFailure
        Assert-NinjaRetryJobs -Fixture $fixture -Jobs 2
    }

}
