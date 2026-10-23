#requires -Version 7.0
# Lifted host steps use process, registry and script stubs; no live services or host configuration are changed.

function Invoke-NewHostGcFixture {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $guard = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName Get-HostMaintenanceProcess).ToString()
    $prelude = @'
$SkipGcPolicy = $State.Skip; $ReportOnly = $State.ReportOnly; $Force = $State.Force; $scriptRoot = 'fixture'
function Get-Process { param($Name) $State.ProcessCalls++; $State.Live }
function Get-ItemProperty { $State.Properties }
function Set-ItemProperty { param($Path, $Name, $Value, $Type) $State.Writes++; $State.Environment = $Value }
function Write-HostMaintenanceMessage { param($Message, $Color) $State.Messages.Add($Message) }
function Join-Path { param($Path, $ChildPath) 'Invoke-TestGcPolicy' }
function Invoke-TestGcPolicy { param([switch]$Force) $State.Invoked++; $State.Forced = $Force.IsPresent }
'@
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/host/Install-NewHost.ps1' -FunctionName Invoke-StepGcPolicy `
        -FixtureState $State -Prelude ($prelude + "`n" + $guard) -Find $Find -Replace $Replace -Body $Body
}

function New-HostGcState {
    param([switch]$Force, [switch]$ReportOnly, [switch]$Skip)
    New-TestCallState @{ Force = $Force.IsPresent; ReportOnly = $ReportOnly.IsPresent; Skip = $Skip.IsPresent
        Properties = [pscustomobject]@{ Environment = @('KEEP=value', 'BUILDKIT_STEP_LOG_MAX_SIZE=2') }
        Live = @([pscustomobject]@{ Id = 31; ProcessName = 'buildctl' }); ProcessCalls = 0
        Writes = 0; Invoked = 0; Forced = $false; Environment = @(); Messages = [Collections.Generic.List[string]]::new() }
}

Describe 'New-host setup shared maintenance policies' {
    It 'blocks before registry or script actions when a build is live' {
        Invoke-NewHostGcFixture -State (New-HostGcState) -Body { param($state)
            Assert-Throws { Invoke-MutStepGcPolicy } -MessagePattern '1 live buildctl process.*this step restarts buildkitd'
            Assert-Equal 1 $state.ProcessCalls
            Assert-Equal 0 $state.Writes
            Assert-Equal 0 $state.Invoked
        }
    }

    It 'retains force, report-only and skip policies without live host probes' {
        Invoke-NewHostGcFixture -State (New-HostGcState -Force) -Body { param($state)
            Invoke-MutStepGcPolicy
            Assert-Equal 0 $state.ProcessCalls
            Assert-Equal 1 $state.Writes
            Assert-Equal 'KEEP=value|BUILDKIT_STEP_LOG_MAX_SIZE=-1|BUILDKIT_STEP_LOG_MAX_SPEED=-1' ($state.Environment -join '|')
            Assert-Equal 1 $state.Invoked
            Assert-True $state.Forced
        }
        foreach ($mode in @(@{ ReportOnly = $true }, @{ Skip = $true })) {
            Invoke-NewHostGcFixture -State (New-HostGcState @mode) -Body { param($state)
                Invoke-MutStepGcPolicy
                Assert-Equal 0 ($state.ProcessCalls + $state.Writes + $state.Invoked)
                Assert-True ($state.Messages.Count -gt 0)
            }
        }
    }

    It 'keeps the final restart under report-only and force guards and passes the buildctl diagnostic' {
        $calls = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Install-NewHost.ps1' -Name Get-HostMaintenanceProcess)
        Assert-Equal 2 $calls.Count 'both destructive steps need the shared guard'
        $final = @($calls | Where-Object { -not (Get-TestAstAncestor -Node $_ -Type ([Management.Automation.Language.FunctionDefinitionAst]) -First) })
        Assert-Equal 1 $final.Count
        Assert-Equal 'buildctl' (Get-TestCommandArguments -Command $final[0]).Name
        $conditions = @(Get-TestAstAncestor -Node $final[0] -Type ([Management.Automation.Language.IfStatementAst]) | ForEach-Object { $_.Clauses[0].Item1.Extent.Text })
        Assert-Equal '-not $Force|-not $ReportOnly' ($conditions -join '|')
    }

    It 'detects removing the shared live-build guard from the GC step' {
        $call = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Install-NewHost.ps1' -Name Get-HostMaintenanceProcess)[0]
        Invoke-NewHostGcFixture -State (New-HostGcState) -Find $call.Extent.Text -Replace '$null' -Body {
            Assert-Throws {
                Assert-Throws { Invoke-MutStepGcPolicy } -MessagePattern 'live buildctl'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }
}
