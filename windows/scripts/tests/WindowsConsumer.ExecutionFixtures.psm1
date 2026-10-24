#requires -Version 7.0
# Consumer execution fixtures share environment case setup and the CMake stand-in used by policy suites.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Invoke-TestEnvironmentCases {
    param([Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][ValidateCount(1, 2147483647)][object[]]$Value,
        [hashtable]$With = @{}, [switch]$AssertRestored, [Parameter(Mandatory)][scriptblock]$Body)
    if ($null -eq $Value) { throw 'Value must contain at least one environment state' }
    $exercise = $Body
    foreach ($sample in $Value) {
        $variables = $With.Clone()
        $variables[$Name] = $sample
        $current = $sample
        Invoke-WithEnv -Vars $variables -Body {
            & $exercise $current
            if ($AssertRestored) {
                Assert-Equal $current ([Environment]::GetEnvironmentVariable($Name)) 'operation restores the environment value'
                Assert-Equal ($null -ne $current) (Test-Path -LiteralPath "Env:$Name") 'operation restores environment presence'
            }
        }.GetNewClosure()
    }
}

function New-TestCmakeExecutionModuleArguments {
    $state = New-TestCallState @{ Runtime = $null; Paths = [Collections.Generic.List[object]]::new(); Logs = [Collections.Generic.List[string]]::new(); Code = 0; Throw = $false }
    $text = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName Write-BuildCommandOutput).ToString() + "`n" +
        (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsCMake.Common.psm1' -FunctionName Invoke-CmakeBuildCommand).ToString()
    return @{ Text = $text; FixtureState = $state; Prelude = @'
function Write-BuildLog { param($Context, $Message) $State.Logs.Add("$Message|PATH=$env:PATH") }
function cmake {
    $State.Calls.Add(@($args))
    $State.Paths.Add([Environment]::GetEnvironmentVariable('PATH'))
    'build output'
    ' '
    $env:PATH = 'dirty build path'
    if ($State.Throw) { throw 'fixture build failed' }
    $global:LASTEXITCODE = $State.Code
}
'@ }
}

Export-ModuleMember -Function Invoke-TestEnvironmentCases, New-TestCmakeExecutionModuleArguments
