#requires -Version 7.0
# Child-process and loop probes share module setup and log capture while retaining their own command fakes.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function New-TestAgenticModuleArguments {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][Collections.IDictionary]$Definition)
    $fields = @{ Root = $Root }
    foreach ($key in $Definition.Properties.Keys) { $fields[$key] = $Definition.Properties[$key] }
    return @{
        ScriptPath = 'windows/scripts/modules/WindowsAgenticLoop.Common.psm1'
        FunctionName = $Definition.FunctionName
        FixtureState = New-TestCallState -Properties $fields
        Prelude = @'
$script:AgenticDryRun = $false
function Write-AgenticSection {}
function Write-AgenticLog { param($Message, $Level = 'INFO') $State.Calls.Add("log|$Level|$Message") }
'@ + "`n" + $Definition.Prelude
    }
}

function New-TestAgenticModuleFactory {
    param([Parameter(Mandatory)][string[]]$FunctionName, [Collections.IDictionary]$Properties = @{}, [string]$Prelude = '')
    $construct = Get-Command New-TestAgenticModuleArguments -CommandType Function
    $definition = @{ FunctionName = $FunctionName; Properties = $Properties; Prelude = $Prelude }
    return { param($root) & $construct -Root $root -Definition $definition }.GetNewClosure()
}

Export-ModuleMember -Function New-TestAgenticModuleFactory
