#requires -Version 7.0
# Host-portable, so the mutation shards on Linux pwsh can prove it; Smoke.Operations holds the Windows-only cases.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSmokeTest.Common.psm1') -Force -DisableNameChecking

Describe 'Smoke finding verdict' {
    It 'passes an empty if/else finding list and still fails a real finding (mutation)' {
        Initialize-SmokeTestRun
        $none = if ($true) { @() } else { @('unreached') }
        Assert-Test -Name 'empty if result' -Finding $none -FailMessage 'an empty if result is no finding'
        Assert-Test -Name missing -Finding @('missing artifact') -FailMessage 'missing artifact'
        Assert-Equal 1 (Get-SmokeTestSummary).Passed 'the empty if result passes'
        Assert-Equal 1 (Get-SmokeTestSummary).Failed 'a real finding still fails'
    }
}
