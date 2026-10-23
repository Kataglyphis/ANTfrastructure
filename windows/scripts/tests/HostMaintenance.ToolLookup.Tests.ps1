# NOT covered: process launches or a host install; this pins host candidate and missing-tool policies.

Describe 'Host maintenance buildctl lookup' {
    It 'preserves candidate order, optional fallback and PATH policy under mutation' {
        $state = [pscustomobject]@{
            CheckedPaths = [System.Collections.Generic.List[string]]::new()
            ExistsPath = 'D:\Stevedore\bin\buildctl.exe'
            CommandName = ''
            PreferredCalls = 0
            PreferredPaths = @()
            Required = $false
            Resolved = 'buildctl from PATH'
        }
        $prelude = 'function Test-Path { param($Path) $State.CheckedPaths.Add($Path); $Path -eq $State.ExistsPath }; function Get-PreferredToolPath { param($CommandName, $CandidatePaths, [switch]$Required) $State.PreferredCalls++; $State.CommandName = $CommandName; $State.PreferredPaths = $CandidatePaths; $State.Required = $Required; $State.Resolved }'
        Invoke-WithEnv @{ ProgramFiles = 'Z:\FixtureProgramFiles' } {
            Invoke-TestFunctionMutations -ModuleArguments @{ ScriptPath = 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1';
                    FunctionName = 'Get-HostMaintenanceBuildCtlPath'; Prelude = $prelude; FixtureState = $state } -IncludeControl `
                -Find "if (`$IncludeCProgramFilesFallback) { `$candidates = @(`$candidates[0], 'C:\Program Files\Stevedore\bin\buildctl.exe', `$candidates[1]) }" `
                -Replace '' -Expected 'C fallback must precede D' -Body {
                param($state)
                $state.CheckedPaths.Clear()
                $state.ExistsPath = 'D:\Stevedore\bin\buildctl.exe'
                $state.CommandName = ''
                $state.PreferredCalls = 0
                $state.PreferredPaths = @()
                $state.Required = $false
                $state.Resolved = 'buildctl from PATH'
                $programFiles = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
                $resolved = Get-MutHostMaintenanceBuildCtlPath
                Assert-Equal 'D:\Stevedore\bin\buildctl.exe' $resolved 'the default candidate order ends at D'
                Assert-Equal "$programFiles|D:\Stevedore\bin\buildctl.exe" ($state.CheckedPaths -join '|') 'no PATH probe is added by default'
                Assert-Equal 0 $state.PreferredCalls 'default callers retain candidate-only lookup'

                $state.CheckedPaths.Clear()
                $state.ExistsPath = 'C:\Program Files\Stevedore\bin\buildctl.exe'
                $resolved = Get-MutHostMaintenanceBuildCtlPath -IncludeCProgramFilesFallback
                Assert-Equal $state.ExistsPath $resolved 'the lock reset retains its explicit C fallback'
                Assert-Equal "$programFiles|C:\Program Files\Stevedore\bin\buildctl.exe" ($state.CheckedPaths -join '|') 'C stays ahead of D only for the lock reset'

                $state.CheckedPaths.Clear()
                $state.Resolved = 'buildctl from PATH'
                $resolved = Get-MutHostMaintenanceBuildCtlPath -SearchPath
                Assert-Equal $state.Resolved $resolved 'store reset retains PATH fallback'
                Assert-Equal 1 $state.PreferredCalls 'PATH lookup delegates to the shared resolver'
                Assert-Equal 'buildctl.exe' $state.CommandName 'the shared resolver gets the executable name'
                Assert-Equal "$programFiles|D:\Stevedore\bin\buildctl.exe" ($state.PreferredPaths -join '|') 'PATH lookup keeps its original candidates'
                Assert-Equal 0 $state.CheckedPaths.Count 'the shared resolver owns candidate checks'
                Assert-False $state.Required 'missing tools remain optional'

                $state.Resolved = $null
                Assert-Null (Get-MutHostMaintenanceBuildCtlPath -SearchPath) 'unavailable probes return null for caller diagnostics'
            }
        }
    }

    It 'routes each worker probe through the shared resolver with its prior lookup policy' {
        $assertLookup = {
            param($Ast, $Script)
            $calls = @(Get-TestAstCommands -Ast $Ast -Name Get-HostMaintenanceBuildCtlPath)
            Assert-Equal 1 $calls.Count 'each host worker probe must use the shared lookup'
            $arguments = Get-TestCommandArguments -Command $calls[0]
            if ($Script -eq 'Reset-ContainerLocks') {
                Assert-True $arguments.ContainsKey('IncludeCProgramFilesFallback') 'only the lock reset adds C'
                Assert-False $arguments.ContainsKey('SearchPath') 'the lock reset must not search PATH'
            } elseif ($Script -eq 'Reset-ContainerStores') {
                Assert-True $arguments.ContainsKey('SearchPath') 'store reset retains PATH fallback'
            } else {
                Assert-Equal 0 $arguments.Count 'GC verification stays candidate-only'
            }
            $directBuildctlLookups = @(Get-TestAstCommands -Ast $Ast -Name Get-PreferredToolPath | Where-Object {
                (Get-TestCommandArguments -Command $_).CommandName -eq "'buildctl.exe'"
            })
            Assert-Equal 0 $directBuildctlLookups.Count 'host scripts must route buildctl selection through the shared lookup'
        }.GetNewClosure()

        foreach ($script in @('Reset-ContainerLocks', 'Reset-ContainerStores', 'Set-BuildkitdGcpolicy')) {
            & $assertLookup (Get-TestScriptAst -ScriptPath "windows/scripts/host/$script.ps1") $script
        }

        $path = Join-Path (Get-RepoRoot) 'windows/scripts/host/Set-BuildkitdGcpolicy.ps1'
        $mutated = [IO.File]::ReadAllText($path).Replace('Get-HostMaintenanceBuildCtlPath', 'Get-PreferredToolPath')
        $ast = ConvertTo-TestScriptAst -Text $mutated
        Assert-Throws { & $assertLookup $ast 'Set-BuildkitdGcpolicy' } -MessagePattern 'each host worker probe must use the shared lookup'

        $broken = $mutated.Replace('Get-PreferredToolPath', 'Get-PreferredToolPath -CandidatePaths (')
        Assert-Throws { $ast = ConvertTo-TestScriptAst -Text $broken; & $assertLookup $ast 'Set-BuildkitdGcpolicy' } -MessagePattern 'snippet failed to parse'
    }
}
