#requires -Version 7.0
# Observer fixtures exercise callback recording and verdicts; they do not run uv, Python or a chain image.

Import-Module (Join-Path $PSScriptRoot 'WindowsUv.ChainFixtures.psm1') -Force -DisableNameChecking

function script:Invoke-UvObserverInstall {
    param([Parameter(Mandatory)]$Observer, [switch]$Hold)
    & $Observer.CommandRunner -exe uv -arguments @('pip', 'install', 'wheel')
    if ($Hold) { $Observer.State.NoSync = '1' }
}

Describe 'UV chain test observers' {
    It 'records command and log callbacks independently for each invocation' {
        $first = New-UvChainTestObserver
        $second = New-UvChainTestObserver
        Invoke-UvObserverInstall -Observer $first -Hold
        & $first.Log 'a diagnostic'
        Assert-UvChainTestReplacement -State $first.State -CommandCount 1
        Assert-UvChainTestCommand -State $first.State -Index 0 -Equal 'pip install wheel' -Match '^pip install' -NotMatch 'uninstall'
        Assert-Equal 'a diagnostic' ($first.State.Log -join ',')
        Assert-Equal '0|0||' "$($second.State.Uv.Count)|$($second.State.Log.Count)|$($second.State.Error)|$($second.State.NoSync)"
    }

    It 'records a rejected command before propagating the caller-owned error' {
        $observer = New-UvChainTestObserver -CommandCheck { param($exe, $arguments)
            if ($exe -eq 'uv' -and $arguments[1] -eq 'install') { throw 'fixture install refused' }
        }
        Assert-Throws { Invoke-UvObserverInstall -Observer $observer } -MessagePattern 'fixture install refused'
        Assert-Equal 'pip install wheel' ($observer.State.Uv -join ',')
        Assert-Equal '' $observer.State.Error 'the caller owns error capture'
    }

    It 'refuses missing holds, wrong counts and unexpected command content' {
        $observer = New-UvChainTestObserver
        Invoke-UvObserverInstall -Observer $observer
        Assert-Throws { Assert-UvChainTestReplacement -State $observer.State -CommandCount 1 } -MessagePattern 'Assert-Equal'
        $observer.State.NoSync = '1'
        Assert-Throws { Assert-UvChainTestReplacement -State $observer.State -CommandCount 2 } -MessagePattern 'Assert-Equal'
        Assert-Throws { Assert-UvChainTestCommand -State $observer.State -Index 0 -Match '^uninstall' } -MessagePattern 'Assert-Match'
        Assert-Throws { Assert-UvChainTestCommand -State $observer.State -Index 0 -NotMatch install } -MessagePattern 'Assert-False'
        Assert-Throws { Assert-UvChainTestCommand -State $observer.State -Index 0 -Equal other } -MessagePattern 'Assert-Equal'
    }

    It 'detects a recorder mutant that drops attempted commands' {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'WindowsUv.ChainFixtures.psm1'))
        Invoke-WithFunctionModule -Text $source -FunctionName New-UvChainTestObserver -Find '$state.Uv.Add(($arguments -join '' ''))' -Replace '' -Body {
            $observer = New-MutUvChainTestObserver
            Invoke-UvObserverInstall -Observer $observer -Hold
            Assert-Throws { Assert-UvChainTestReplacement -State $observer.State -CommandCount 1 } -MessagePattern 'Assert-Equal'
        }
    }
}
