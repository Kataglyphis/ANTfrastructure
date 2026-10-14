#requires -Version 7.0
# #179: every RUN that started an sccache server idled ~120 s before DONE until the host's TcpTimedWaitDelay was 30 s.

Describe 'Install-NewHost: TcpTimedWaitDelay changes only when it differs' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-NewHost.ps1' -FunctionName 'Get-TcpTimeWaitChange')

    It 'leaves a host already at the target alone' {
        Assert-True ($null -eq (Get-TcpTimeWaitChange -Current 30 -Desired 30)) 'no change at 30'
    }

    It 'names the default when the value is unset' {
        Assert-True ((Get-TcpTimeWaitChange -Current $null -Desired 30) -eq 'unset (the 120 s default) -> 30 s') 'unset reads as the default'
    }

    It 'reports a different value with its old and new seconds' {
        Assert-True ((Get-TcpTimeWaitChange -Current 120 -Desired 30) -eq '120 s -> 30 s') 'explicit 120'
    }
}
