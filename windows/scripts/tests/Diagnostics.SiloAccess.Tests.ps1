#requires -Version 7.0
# Stubbed ACL transport covers arguments and output, not live permissions or debugger attachment.

function Invoke-SiloAccessFixture {
    param([scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = New-TestCallState @{ Code = 7; Action = $Body }
    Invoke-WithTestNativeCommand -Name icacls.exe -FixtureState $state -Implementation { 'native ACL output' } -Body { param($record)
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSiloProbe.Common.psm1' -FunctionName Grant-SiloProbeReadAccess `
            -FixtureState $record -Find $Find -Replace $Replace -Body { param($record) & $record.Action $record }
    }
}

function Assert-SiloAccessArguments {
    param($State)
    $result = @(Grant-MutSiloProbeReadAccess -OutDir 'C:\logs [probe]\space' -Identity 'DOMAIN\user name')
    Assert-Equal 'C:\logs [probe]\space|/grant|DOMAIN\user name:(OI)(CI)R|/T' ($State.Calls[0] -join '|') 'read grant must retain exact native arguments'
    Assert-Equal 1 $result.Count 'native ACL output must stay suppressed'
    Assert-Equal 'DOMAIN\user name' $result[0]
}

Describe 'Shared silo log read access' {
    It 'preserves recursive read-only ACL arguments and returns only the caller identity even on a nonzero native status' {
        Invoke-SiloAccessFixture { param($state) Assert-SiloAccessArguments $state }
    }

    It 'detects widened permissions and leaked native output' {
        $assertAccess = Get-Command Assert-SiloAccessArguments
        foreach ($mutation in @(@{ Find = '(OI)(CI)R'; Replace = '(OI)(CI)F'; Pattern = 'read grant must retain' },
            @{ Find = ' | Out-Null'; Replace = ''; Pattern = 'native ACL output must stay suppressed' })) {
            Invoke-SiloAccessFixture -Find $mutation.Find -Replace $mutation.Replace -Body {
                param($state) Assert-Throws { & $assertAccess $state } -MessagePattern $mutation.Pattern
            }.GetNewClosure()
        }
    }

    It 'does not swallow a missing ACL tool' {
        Invoke-SiloAccessFixture -Find '& icacls.exe' -Replace '& Invoke-MissingSiloAclFixture' -Body {
            Assert-Throws { Grant-MutSiloProbeReadAccess -OutDir 'fixture' -Identity 'fixture' } -MessagePattern 'Invoke-MissingSiloAclFixture'
        }
    }

    It 'binds all four diagnostics to the shared operation' {
        foreach ($name in 'Find-LsmEventHolder', 'Get-HostLsm', 'Get-LsmWaitObject', 'Get-SiloProcesses') {
            $ast = Get-TestScriptAst -ScriptPath "windows/scripts/diagnostics/$name.ps1"
            $calls = @(Get-TestAstCommands -Ast $ast -Name Grant-SiloProbeReadAccess)
            Assert-Equal 1 $calls.Count "$name must grant shared read access"
            Assert-Equal '$OutDir' (Get-TestCommandArguments $calls[0]).OutDir
            Assert-Equal 0 @(Get-TestAstCommands -Ast $ast -Name icacls.exe).Count
        }
    }
}
