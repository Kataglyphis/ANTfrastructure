#requires -Version 7.0
# TestHarness Invoke-WithEnv: $null REMOVES a variable, and one that was unset is unset again after.
# NOT covered: Machine/User scope (the harness only touches the process block).

Describe 'TestHarness: Invoke-WithEnv removes and restores for real' {
    $script:Probe = 'KATAGLYPHIS_WITHENV_PROBE'
    # .NET's own view: $null means absent. An EMPTY var reads as '' and still reaches child processes.
    function Get-Probe { [Environment]::GetEnvironmentVariable($script:Probe) }

    It '$null removes a set variable for the body and restores it after' {
        [Environment]::SetEnvironmentVariable($script:Probe, 'outer')
        try {
            Invoke-WithEnv @{ $script:Probe = $null } { Assert-Null (Get-Probe) 'absent inside the body, not empty' }
            Assert-Equal 'outer' (Get-Probe) 'restored'
        } finally { [Environment]::SetEnvironmentVariable($script:Probe, [NullString]::Value) }
    }

    It 'a variable that was unset is unset again after, not left empty' {
        [Environment]::SetEnvironmentVariable($script:Probe, [NullString]::Value)
        Invoke-WithEnv @{ $script:Probe = 'inner' } { Assert-Equal 'inner' (Get-Probe) 'set inside the body' }
        Assert-Null (Get-Probe) 'absent after, not empty'
    }
}
