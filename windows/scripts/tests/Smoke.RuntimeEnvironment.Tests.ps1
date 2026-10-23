#requires -Version 7.0
# Fake native loaders and hostname cover PATH isolation and closure visibility; real DLL imports and compiler correctness remain image smoke coverage.

Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

function Add-SmokeEnvironmentProbeType {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class KataNativeProbe {
    public static List<string> Paths = new List<string>();
    public static int Freed;
    public static IntPtr LoadLibraryW(string path) { Paths.Add(Environment.GetEnvironmentVariable("PATH")); Environment.SetEnvironmentVariable("PATH", "loader changed path"); return new IntPtr(1); }
    public static bool FreeLibrary(IntPtr handle) { Freed++; return true; }
    public static IntPtr GetProcAddress(IntPtr handle, string name) { return name == "absent" ? IntPtr.Zero : new IntPtr(2); }
}
'@
}

function Assert-SmokeEnvironmentProbe {
    param([string]$ModuleSource)
    $hostname = (Get-Command hostname -CommandType Application).Source
    Invoke-InTestDir -Files @{ 'a.dll' = ''; 'nested/b.dll' = ''; 'skip.dll' = '' } -Body { param($dir)
        $state = New-TestCallState @{ Root = $dir; Hostname = $hostname; Scope = (Get-Command Invoke-WithProcessEnvironment) }
        $prelude = @'
function Invoke-WithProcessEnvironment {
    param($Environment, $ScriptBlock)
    $State.Calls.Add($Environment.PATH)
    $scope = $State.Scope; $operation = $ScriptBlock
    & $scope -Environment $Environment -ScriptBlock { & $operation; $env:PATH = 'probe changed path' }.GetNewClosure()
}
'@
        Invoke-WithTestFunction -Name clang-cl -FixtureState $state -Definition {
            $output = @($args | Where-Object { $_ -like '/Fe*' })[0].Substring(3)
            Copy-Item -LiteralPath $State.Hostname -Destination $output
            $global:LASTEXITCODE = 0
        } -Body { param($state)
            Invoke-WithFunctionModule -Text $ModuleSource -Prelude $prelude -FixtureState $state -Body { param($state)
                Invoke-TestEnvironmentCases -Name PATH -Value @($null, '', 'parent runtime path') -With @{ TEMP = $state.Root } -AssertRestored -Body {
                    param($parent)
                        Initialize-SmokeTestRun
                        Assert-MutNativeLinkRun -Name native -WorkName 'environment' -Source 'fixture' -IncludeDirs @() -LibDir $state.Root -LibName fake.lib -DllDir (Join-Path $state.Root deps) -ExpectMatch '.' -FailMessage 'native fixture failed'
                        Assert-Equal 1 (Get-SmokeTestSummary).Passed 'native link callback captures the environment operation'
                        Assert-Equal ((Join-Path $state.Root deps) + ';' + $parent) $state.Calls[-1]
                        Assert-MutDllLoads -Name export -DllPath (Join-Path $state.Root a.dll) -DependencyDirs @('one', 'two') -Export present -FailMessage 'DLL fixture failed'
                        Assert-Equal 2 (Get-SmokeTestSummary).Passed 'DLL callback captures the environment operation'
                        Assert-Equal ($state.Root + ';one;two;' + $parent) ([KataNativeProbe]::Paths[-1]) 'DLL path precedence is stable'
                        $before = [KataNativeProbe]::Paths.Count
                        Assert-MutAllDllsLoad -Name sweep -Root $state.Root -DependencyDirs @('dep') -Allow skip.dll -MinimumChecked 2
                        Assert-Equal 3 (Get-SmokeTestSummary).Passed
                        Assert-Equal 2 ([KataNativeProbe]::Paths.Count - $before) 'the sweep retains its allow-list and recursion'
                        foreach ($entry in [KataNativeProbe]::Paths.GetRange($before, 2)) { Assert-True ($entry.EndsWith(";$($state.Root);dep;$parent")) 'each DLL scope uses the same parent PATH' }
                        Assert-MutDllLoads -Name absent -DllPath (Join-Path $state.Root a.dll) -Export absent -FailMessage 'missing export'
                        Assert-Equal 1 (Get-SmokeTestSummary).Failed 'an absent export remains a failure'
                }
                Assert-Equal 12 ([KataNativeProbe]::Freed) 'every loaded handle is freed, including a missing export'
            }
        }
    }.GetNewClosure()
}

function Invoke-SmokeEnvironmentProbe {
    param([string]$Find = '', [string]$Replace = '')
    $moduleSource = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsSmokeTest.Common.psm1' -FunctionName Assert-NativeLinkRun, Initialize-KataNativeProbe, Invoke-SmokeDllProbe, Assert-DllLoads, Assert-AllDllsLoad).ToString()
    if ($Find) {
        Assert-TestScriptContains -ScriptPath 'windows/scripts/modules/WindowsSmokeTest.Common.psm1' -Literal $Find
        $moduleSource = $moduleSource.Replace($Find, $Replace)
    }
    $root = (Get-RepoRoot).Replace("'", "''")
    $functions = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Smoke.RuntimeEnvironment.Tests.ps1' -FunctionName Add-SmokeEnvironmentProbeType, Assert-SmokeEnvironmentProbe).ToString()
    Invoke-TestFunctionSourceProbe -FixtureSource $moduleSource -ProbeSource @"
Import-Module '$root/windows/scripts/tests/TestHarness.psm1' -ErrorAction Stop
Import-Module '$root/windows/scripts/modules/WindowsScripts.Shared.psm1' -ErrorAction Stop
Import-Module '$root/windows/scripts/modules/WindowsSmokeTest.Common.psm1' -ErrorAction Stop
Import-Module '$root/windows/scripts/tests/WindowsConsumer.ExecutionFixtures.psm1' -ErrorAction Stop
$functions
Add-SmokeEnvironmentProbeType
Assert-SmokeEnvironmentProbe -ModuleSource `$FixtureSource
"@
}

Describe 'Smoke runtime environment scopes' {
    It 'isolates each native probe while retaining callback commands, DLL order and handle cleanup' {
        $probe = Invoke-SmokeEnvironmentProbe
        Assert-Equal 0 $probe.ExitCode $probe.Output
    }

    It 'detects losing the captured environment operation inside smoke callbacks' {
        $needle = '$withEnvironment = Get-Command Invoke-WithProcessEnvironment'
        $probe = Invoke-SmokeEnvironmentProbe -Find $needle -Replace '$withEnvironment = $null'
        Assert-TestPwshFailure -Probe $probe -Pattern 'native link callback captures the\s+environment operation' -Reason 'missing callback visibility must fail'
    }
}
