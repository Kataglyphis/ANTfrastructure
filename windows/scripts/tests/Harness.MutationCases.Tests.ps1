#requires -Version 7.0
# Child probes cover named registration, factories and control failures; operation assertions belong to their consumer suites.

Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

function Invoke-MutationCheckIsolationProbe {
    param([Parameter(Mandatory)][string]$HelperSource)
    $harness = (Join-Path (Get-RepoRoot) 'windows/scripts/tests/TestHarness.psm1').Replace("'", "''")
    $probe = @'
Import-Module '__HARNESS__' -ErrorAction Stop
Invoke-InTestDir {
    param($dir)
    $module = Import-FunctionModule -Text $FixtureSource -Dir $dir -FunctionName Invoke-TestMutationChecks -Prefix Probe
    try {
        Reset-TestState
        $calls = [Collections.Generic.List[string]]::new()
        $factory = {
            param($item)
            $calls.Add($item.Name)
            if ($item.Name -eq 'bad recipe') { return 'invalid recipe' }
            $expected = $item.Value
            return @{
                ModuleArguments = @{ Text = 'function Get-Answer { param($Value) return $Value }'; BodyArgumentList = @($expected) }
                Find = 'return $Value'; Replace = 'return -1'; Expected = 'Assert-Equal'
                Body = { param($value) Assert-Equal $value (Get-MutAnswer $value) }
            }
        }.GetNewClosure()
        Invoke-ProbeTestMutationChecks -Check @(
            @{ Name = 'first'; Value = 11 }, @{ Name = 'bad recipe'; Value = 0 }, @{ Name = 'last'; Value = 29 }
        ) -ArgumentsFactory $factory
        $results = @(Get-TestResult)
        Assert-Equal 'first|bad recipe|last' ($calls -join '|') 'the factory sees each original case in order'
        Assert-Equal 'first|bad recipe|last' (($results | ForEach-Object Name) -join '|') 'each case keeps its own registration name'
        Assert-Equal 'True|False|True' (($results | ForEach-Object Ok) -join '|') 'a bad recipe cannot pass or stop later checks'
        Assert-Match 'arguments must be one dictionary' $results[1].Err
        Assert-Throws { Invoke-ProbeTestMutationChecks -Check @(@{ Name = ' ' }) } -MessagePattern 'nonempty Name'
        Reset-TestState
        $broken = @{
            ModuleArguments = @{ Text = 'function Get-Answer { return 1 }' }
            Find = 'return 1'; Replace = 'return -1'; Expected = 'Assert-Equal'
            Body = { Assert-Equal 2 (Get-MutAnswer) }
        }
        Invoke-ProbeTestMutationChecks -Check @(@{ Name = 'broken control'; Arguments = $broken })
        $control = @(Get-TestResult)
        Assert-Equal 1 $control.Count
        Assert-False $control[0].Ok 'a failed control remains a failure even when the mutant assertion fails as expected'
        Assert-Match 'expected \[2\] but got \[1\]' $control[0].Err
    } finally { Remove-Module $module -Force }
}
'@
    Invoke-TestFunctionSourceProbe -FixtureSource $HelperSource -ProbeSource $probe.Replace('__HARNESS__', $harness)
}

Describe 'Named mutation operation checks' {
    It 'binds each case and factory, records recipe failures, and rejects a failed control' {
        $definition = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/WindowsTest.MutationCases.psm1' -FunctionName Invoke-TestMutationChecks).ToString()
        $result = Invoke-MutationCheckIsolationProbe -HelperSource $definition
        Assert-Equal 0 $result.ExitCode $result.Output
    }

    It 'detects an executor that omits the original control' {
        $definition = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/WindowsTest.MutationCases.psm1' -FunctionName Invoke-TestMutationChecks).ToString()
        $needle = '& $execute @arguments -IncludeControl'
        Assert-TestScriptContains -ScriptPath 'windows/scripts/tests/WindowsTest.MutationCases.psm1' -Literal $needle
        $result = Invoke-MutationCheckIsolationProbe -HelperSource $definition.Replace($needle, '& $execute @arguments')
        Assert-TestPwshFailure -Probe $result -Pattern 'a failed control remains a failure' -Reason 'omitting the control must fail the probe'
    }
}
