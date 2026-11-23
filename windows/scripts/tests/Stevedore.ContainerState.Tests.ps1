#requires -Version 7.0
# NOT covered: live task races, daemon access, SYSTEM ACLs or reclaimed bytes.

Describe 'Task-absent nerdctl containers' {
    Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
    . (Get-DelegationFixtureFunctions Containers)

    It 'recognizes the complete empty process state without changing its raw fields' {
        $item = New-DelegationFixtureContainer -TaskAbsent
        $record = ConvertTo-HostContainerRecord $item
        Assert-Equal created $record.Status 'a known task-absent state must be accepted'
        Assert-False $record.Running
        Assert-True $record.Disposable
        Assert-Equal '' $item.State.Status 'the original raw state must remain unchanged'
        $target = [pscustomobject]@{ Id = $item.Id; Image = $item.Image }
        function Get-StevedoreInspection { param($Store, $Kind, $Value) $item }
        Assert-StevedoreContainerTarget @{} $target
    }

    It 'refuses incomplete contradictory and nonempty unknown process states' {
        $item = New-DelegationFixtureContainer -TaskAbsent
        $state = $item.State
        $faults = @(@{Status=$null}, @{Status='unknown'}, @{Status=' '}, @{Running=$true}, @{Running='false'}, @{Paused=$true}, @{Paused=$null}, @{Restarting=$true}, @{Restarting='false'}, @{Pid=1}, @{Pid=$null}, @{Pid='0'}, @{ExitCode=1}, @{ExitCode=$null}, @{ExitCode='0'}, @{Error='failure'}, @{Error=$null}, @{StartedAt='2026-11-21T12:00:00Z'}, @{StartedAt=$null}, @{FinishedAt='2026-11-21T12:00:00Z'}, @{FinishedAt=$null})
        Assert-DelegationPropertyRefusals -Prototype $state -Fault $faults -MessagePattern 'Container' -Body {
            param($changed)
            $item.State = $changed
            ConvertTo-HostContainerRecord $item
        }
        $item.State = $state.PSObject.Copy()
        $item.State.PSObject.Properties.Remove('Pid')
        Assert-Throws { ConvertTo-HostContainerRecord $item }
    }
}

Describe 'Canonical native read diagnostics' {
    It 'retains raw failures and refuses diagnostics even when the query exits zero' {
        $state = [pscustomobject]@{ Command = '[Console]::Out.WriteLine(''payload''); exit 0' }
        $prelude = 'function Invoke-StoreReadProbe { & (Join-Path $PSHOME $(if ($IsWindows) { ''pwsh.exe'' } else { ''pwsh'' })) -NoLogo -NoProfile -Command $State.Command }'
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -FunctionName Invoke-StevedoreRead -Prelude $prelude -FixtureState $state -Body {
            param($State)
            $store = [pscustomobject]@{ Tool = 'Invoke-StoreReadProbe'; Address = 'fixture'; Namespace = 'buildkit' }
            Assert-Equal payload (Invoke-MutStevedoreRead $store @('container', 'inspect', 'fixture') 'inspection failed')
            $State.Command = '[Console]::Error.WriteLine(''incomplete task query''); exit 0'
            Assert-Throws { Invoke-MutStevedoreRead $store @() 'inspection failed' } -MessagePattern 'exit 0.*incomplete task query'
            $State.Command = 'exit 7'
            Assert-Throws { Invoke-MutStevedoreRead $store @() 'inspection failed' } -MessagePattern 'exit 7'
        }
    }
}
