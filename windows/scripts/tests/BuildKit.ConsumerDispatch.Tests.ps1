#requires -Version 7.0
# A Windows publish must start every consumer's lanes on the new tag, and a failed dispatch must never fail the publish.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:repoRoot 'windows/scripts/modules/WindowsBuildKit.Common.psm1') -Force
    $script:fakeBash = Join-Path $TestDrive 'fake-bash.ps1'
    $script:callLog = Join-Path $TestDrive 'calls.txt'
    # Stands in for Git Bash: records its arguments and exits with the code the case asks for.
    Set-Content -LiteralPath $script:fakeBash -Value @(
        '($args -join " ") | Add-Content -LiteralPath $env:FAKE_BASH_LOG'
        'exit [int]$env:FAKE_BASH_EXIT'
    )
}

Describe 'Get-BkPushTag' {
    It 'takes the tag from the last path segment' -TestCases @(
        @{ Ref = 'registry.example/owner/image:winamd64'; Tag = 'winamd64' }
        @{ Ref = 'registry.example/owner/image:winamd64-nvidia'; Tag = 'winamd64-nvidia' }
        @{ Ref = 'localhost:5000/kataglyphis:winarm64'; Tag = 'winarm64' }
        @{ Ref = 'localhost:5000/kataglyphis'; Tag = '' }
    ) {
        Get-BkPushTag -PushRef $Ref | Should -Be $Tag
    }
}

Describe 'Invoke-BkConsumerDispatch' {
    BeforeEach {
        Remove-Item -LiteralPath $script:callLog -ErrorAction SilentlyContinue
        $env:FAKE_BASH_LOG = $script:callLog
        $env:FAKE_BASH_EXIT = '0'
    }
    AfterAll { Remove-Item Env:FAKE_BASH_LOG, Env:FAKE_BASH_EXIT -ErrorAction SilentlyContinue }

    It 'runs the hub dispatch script in a login shell with the pushed tag' {
        $ok = Invoke-BkConsumerDispatch -PushRef 'registry.example/owner/image:winamd64' -RepoRoot $script:repoRoot -BashPath $script:fakeBash
        $ok | Should -BeTrue
        $call = Get-Content -LiteralPath $script:callLog
        $call | Should -HaveCount 1
        $expected = (Join-Path $script:repoRoot 'linux/scripts/dispatch-consumer-lanes.sh').Replace('\', '/')
        $call | Should -BeExactly "-l $expected --tag winamd64"
    }

    It 'warns, dispatches nothing more and does not throw when <Why>' -TestCases @(
        @{ Why = 'the dispatch fails'; Ref = 'reg/kataglyphis:winarm64'; Code = '1'; Bash = 'fake'; Said = 'exited 1.*--tag winarm64'; Ran = $true }
        @{ Why = 'Git Bash is missing'; Ref = 'reg/kataglyphis:winamd64'; Code = '0'; Bash = 'missing'; Said = 'by hand: bash linux/scripts/dispatch-consumer-lanes.sh --tag winamd64'; Ran = $false }
        @{ Why = 'the ref names no tag'; Ref = 'reg/kataglyphis'; Code = '0'; Bash = 'fake'; Said = 'names no tag'; Ran = $false }
    ) {
        $env:FAKE_BASH_EXIT = $Code
        $path = if ($Bash -eq 'fake') { $script:fakeBash } else { Join-Path $TestDrive 'no-such-bash.exe' }
        $ok = Invoke-BkConsumerDispatch -PushRef $Ref -RepoRoot $script:repoRoot -BashPath $path -WarningVariable warned -WarningAction SilentlyContinue
        $ok | Should -BeFalse
        "$warned" | Should -Match $Said
        Test-Path -LiteralPath $script:callLog | Should -Be $Ran
    }
}

Describe 'Build-Buildkit.ps1 publish' {
    It 'dispatches the consumer lanes right after the final push' {
        $driver = Get-Content -Raw -LiteralPath (Join-Path $script:repoRoot 'windows/Build-Buildkit.ps1')
        $driver | Should -Match '(?s)\[bk\] pushed \$PushRef.{0,200}Invoke-BkConsumerDispatch -PushRef \$PushRef -RepoRoot \$repoRoot'
    }
}
