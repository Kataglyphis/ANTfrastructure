#requires -Version 7.0
# NOT covered: live services, disks, registry, ACLs, host probes or actual token elevation.

function Assert-HostElevationPolicy {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][ValidateSet('Repair', 'Reset')][string]$Policy)
    $ast = ConvertTo-TestScriptAst -Text $Text -ErrorLabel "${Policy} elevation policy"
    $calls = @(Get-TestAstCommands -Ast $ast -Name Test-Elevated)
    Assert-Equal 1 $calls.Count "$Policy must use the shared elevation predicate"
    Assert-Equal 0 ([regex]::Matches($Text, '\[Security\.Principal\.WindowsPrincipal\]').Count) "$Policy must not keep a private token probe"
    $guards = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('Test-Elevated')
    }, $true))
    Assert-Equal 1 $guards.Count "$Policy must keep one elevation guard"
    $branch = $guards[0].Clauses[0].Item2
    if ($Policy -eq 'Repair') {
        $writeCalls = @(Get-TestAstCommands -Ast $branch -Name Write-Host)
        $promptCalls = @(Get-TestAstCommands -Ast $branch -Name Read-Host)
        $exits = @($branch.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true))
        Assert-Equal 1 $writeCalls.Count 'repair keeps its visible denial'
        Assert-Equal 1 $promptCalls.Count 'repair keeps its interactive pause'
        Assert-Equal 1 $exits.Count 'repair must keep exit 1 on denial'
        Assert-Match 'exit 1' $exits[0].Extent.Text 'repair must exit unsuccessfully after the prompt'
    } else {
        $throws = @($branch.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true))
        Assert-Equal 1 $throws.Count 'lock reset must throw on denial'
        Assert-Match 'This must run ELEVATED' $throws[0].Extent.Text 'lock reset preserves its fatal message'
        $promptCalls = @(Get-TestAstCommands -Ast $branch -Name Read-Host)
        Assert-Equal 0 $promptCalls.Count 'lock reset remains non-interactive'
    }
}

function Assert-HostElevationPolicyMutations {
    $repairPath = Join-Path (Get-RepoRoot) 'windows/scripts/host/Repair-WindowsComponentstore.ps1'
    $resetPath = Join-Path (Get-RepoRoot) 'windows/scripts/host/Reset-ContainerLocks.ps1'
    $repair = [IO.File]::ReadAllText($repairPath)
    $reset = [IO.File]::ReadAllText($resetPath)
    Assert-HostElevationPolicy -Text $repair -Policy Repair
    Assert-HostElevationPolicy -Text $reset -Policy Reset
    Assert-Throws { Assert-HostElevationPolicy -Text $repair.Replace('Test-Elevated', '$true') -Policy Repair } -MessagePattern 'shared elevation predicate'
    Assert-Throws { Assert-HostElevationPolicy -Text $repair.Replace('exit 1', 'return') -Policy Repair } -MessagePattern 'exit 1'
    Assert-Throws { Assert-HostElevationPolicy -Text $reset.Replace("throw 'This must run ELEVATED (service restart + process kill need admin).'", "Write-Host 'denied'") -Policy Reset } -MessagePattern 'must throw on denial'
}

function New-HostTreeStatsPrelude {
    return @'
function Get-ChildItem {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Recurse, [switch]$File, [switch]$Force)
    [pscustomobject]@{ FullName = 'C:\fixture\keep\file.bin'; Length = 5 }
    [pscustomobject]@{ FullName = 'C:\fixture\$RECYCLE.BIN\old.bin'; Length = 7 }
    Write-Error 'fixture access denied'
}
'@
}

function Invoke-HostMaintenanceFunctionMutations {
    param(
        [Parameter(Mandatory)][string[]]$FunctionName,
        [Parameter(Mandatory)][object[]]$Case,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Prelude,
        [object]$FixtureState
    )
    $moduleArguments = @{ ScriptPath = 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1'; FunctionName = $FunctionName }
    if ($PSBoundParameters.ContainsKey('Prelude')) { $moduleArguments.Prelude = $Prelude }
    if ($PSBoundParameters.ContainsKey('FixtureState')) { $moduleArguments.FixtureState = $FixtureState }
    Invoke-TestFunctionMutations -ModuleArguments $moduleArguments -IncludeControl -Case $Case -Body $Body
}

function Assert-HostTreeStatsPolicyMutations {
    $cases = [System.Collections.Generic.List[object]]::new()
    $cases.Add(@{ Find = '-not ($ExcludeDir | Where-Object { $parts -contains $_ })'; Replace = '$true'; Expected = 'excluded files must not contribute bytes' })
    $cases.Add(@{ Find = '-ErrorVariable ev'; Replace = ''; Expected = 'unreadable paths must remain observable' })
    Invoke-HostMaintenanceFunctionMutations -FunctionName 'Get-HostMaintenanceTreeStats' -Prelude (New-HostTreeStatsPrelude) -Case $cases.ToArray() -Body {
        $stats = Get-MutHostMaintenanceTreeStats -Root 'C:\fixture' -ExcludeDir '$RECYCLE.BIN'
        Assert-Equal 5 $stats.Bytes 'excluded files must not contribute bytes'
        Assert-Equal 1 $stats.Files 'excluded files must not contribute to the count'
        Assert-Equal 1 $stats.Errors 'unreadable paths must remain observable'
    }
}

function Assert-HostTreeRecursionMutation {
    Invoke-HostMaintenanceFunctionMutations -FunctionName 'Get-HostMaintenanceTreeStats' -Case @(@{ Find = '-Recurse'; Replace = ''; Expected = 'expected nested file count' }) -Body {
        Invoke-InTestDir -Files @{ 'top.bin' = 'abc'; 'nested\deep.bin' = '123456' } -Body {
            param($dir)
            $stats = Get-MutHostMaintenanceTreeStats -Root $dir
            Assert-Equal 2 $stats.Files 'expected nested file count'
            Assert-Equal 9 $stats.Bytes
        }
    }
}

function Assert-HostVhdxHelpers {
    $state = [pscustomobject]@{ Path = ''; Drive = ''; Exists = $true; Lines = [Collections.Generic.List[string]]::new() }
    $prelude = 'function Get-Item { param($Path) $State.Path = $Path; [pscustomobject]@{ Length = 17 } }; function Get-PSDrive { param($Name) $State.Drive = $Name; [pscustomobject]@{ Free = 23 } }; function Test-Path { param($Path) $State.Path = $Path; $State.Exists }; function Write-HostStep { param($Log, $Message, $Color) $Log.Add("$Message|$Color") }'
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName @('Get-HostMaintenanceVhdxSnapshot', 'Test-HostMaintenanceVerifyPath') -Prelude $prelude -FixtureState $state -Body {
        $snapshot = Get-MutHostMaintenanceVhdxSnapshot -Path 'C:\fixture.vhdx' -Drive C
        Assert-Equal 'C:\fixture.vhdx' $state.Path 'snapshot reads the requested VHDX'
        Assert-Equal C $state.Drive 'snapshot reads free space from the requested host volume'
        Assert-Equal 17 $snapshot.PhysicalBytes 'physical bytes come from the VHDX file'
        Assert-Equal 23 $snapshot.HostFreeBytes 'free bytes come from the host volume'
        $state.Exists = $true
        Assert-True (Test-MutHostMaintenanceVerifyPath -Log $state.Lines -Path 'C:\fixture\sentinel') 'existing verify path must pass'
        Assert-Equal 'C:\fixture\sentinel' $state.Path
        Assert-Equal 'verify path C:\fixture\sentinel: True|Green' $state.Lines[-1]
        $state.Exists = $false
        Assert-False (Test-MutHostMaintenanceVerifyPath -Log $state.Lines -Path 'C:\fixture\missing') 'missing path remains a caller-visible false verdict'
        Assert-Equal 'verify path C:\fixture\missing: False|Red' $state.Lines[-1]
    }
}

Describe 'Host maintenance contexts and live-process guard' {
    It 'checks host VHDX snapshots and verification paths' { Assert-HostVhdxHelpers }

    It 'isolates transcript contexts and preserves idle, force, diagnostics and save-before-throw policies' {
        $probeCommands = @(foreach ($script in @('Reset-ContainerLocks', 'Reset-ContainerStores', 'Set-BuildkitdGcpolicy')) {
            Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script.ps1" -Name Write-HostMaintenanceProbe | ForEach-Object { $_.Extent.Text }
        })
        $state = [pscustomobject]@{ Results = @(); Calls = 0; Names = @(); ProbeArguments = @(); ProbeCommands = $probeCommands }
        $prelude = 'function Get-Process { param($Name) $State.Calls++; $State.Names = $Name; $State.Results }; function Get-PreferredToolPath { param($CommandName, $CandidatePaths, [switch]$Required) "fixture $CommandName" }; function Invoke-TestHostProbe { $State.ProbeArguments = $args; $global:LASTEXITCODE = 7; "wanted: worker"; "irrelevant" }'
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName New-HostMaintenanceLog, Write-HostStep, Save-HostMaintenanceLog, Write-HostMaintenanceMessage, Write-HostMaintenanceProbe, Get-HostMaintenanceProcess, Get-HostMaintenanceBuildCtlPath, Write-HostMaintenanceFailure, Write-HostMaintenanceError, Invoke-HostMaintenanceTask -Prelude $prelude -FixtureState $state -Body { param($state)
            Invoke-InTestDir { param($dir)
                $first = New-MutHostMaintenanceLog -Name first -RepoRoot $dir
                $second = New-MutHostMaintenanceLog -Name second -RepoRoot $dir
                Write-MutHostStep -Log $first 'first context' 'Yellow' 6>$null
                Write-MutHostStep -Log $second 'second context' 6>$null
                Assert-Equal 1 $first.Lines.Count
                $standalone = Write-MutHostMaintenanceMessage 'standalone diagnostic' Cyan 6>&1 | Out-String
                Assert-Match '\[\d\d:\d\d:\d\d\] standalone diagnostic' $standalone
                $probe = Write-MutHostMaintenanceProbe -Command Invoke-TestHostProbe -ArgumentList @('literal value', ';') -Pattern wanted 6>&1 | Out-String
                Assert-Match 'wanted: worker' $probe
                Assert-False ($probe.Contains('irrelevant'))
                Assert-Equal 'literal value|;' ($state.ProbeArguments -join '|')
                Assert-Equal 7 $global:LASTEXITCODE
                Assert-Match 'not installed' (Write-MutHostMaintenanceProbe -Command '' -Pattern wanted -UnavailableMessage 'not installed' 6>&1 | Out-String)
                Assert-Equal 0 @(Write-MutHostMaintenanceProbe -Command '' -Pattern wanted 6>&1).Count
                foreach ($name in @('buildctl', 'bt', 'dockerExe')) { Set-Variable -Name $name -Value 'Invoke-TestHostProbe' }
                Assert-Equal 4 $state.ProbeCommands.Count
                foreach ($command in $state.ProbeCommands) {
                    $mutatedCommand = $command.Replace('Write-HostMaintenanceProbe', 'Write-MutHostMaintenanceProbe').Replace('Get-HostMaintenanceBuildCtlPath', 'Get-MutHostMaintenanceBuildCtlPath')
                    & ([scriptblock]::Create($mutatedCommand)) 6>$null
                    Assert-True ($state.ProbeArguments.Count -gt 0)
                }
                Assert-Match '^\[\d\d:\d\d:\d\d\] first context$' $first.Lines[0]
                Assert-False ($second.Lines[0].Contains('first context'))
                Assert-Equal (Join-Path $dir 'logs\host\first.log') $first.LogPath
                $template = 'count={0}; names={1}; ids={2}'
                Assert-Equal 0 @(Get-MutHostMaintenanceProcess -Name buildctl -FailureTemplate $template).Count
                $state.Results = @([pscustomobject]@{ Id = 12; ProcessName = 'z' }, [pscustomobject]@{ Id = 4; ProcessName = 'a' }, [pscustomobject]@{ Id = 9; ProcessName = 'z' })
                Assert-Throws { Get-MutHostMaintenanceProcess -Name @('buildctl', 'shim') -Log $first -FailureTemplate $template 6>$null } -MessagePattern 'count=3; names=a, z; ids=12, 4, 9'
                Assert-Equal 'buildctl,shim' ($state.Names -join ',')
                Assert-Equal $first.Lines[0] ([IO.File]::ReadAllText($first.LogPath).TrimEnd())
                Assert-False (Test-Path $second.LogPath)
                $forced = @(Get-MutHostMaintenanceProcess -Name buildctl -Force -Log $second -FailureTemplate $template)
                Assert-Equal 3 $forced.Count
                Assert-Equal 3 $state.Calls
                Assert-False (Test-Path $second.LogPath)
                Assert-Throws { Get-MutHostMaintenanceProcess -Name buildctl -FailureTemplate $template } -MessagePattern 'count=3; names=a, z; ids=12, 4, 9'
                Write-MutHostMaintenanceFailure -Log $second -Phase SWAP -Message problem -Advice @('first advice', 'second advice') 6>$null
                Assert-Equal 4 $second.Lines.Count
                Assert-Match 'SWAP FAILED: problem$' $second.Lines[1]
                Assert-Match 'first advice$' $second.Lines[2]
                Assert-Match 'second advice$' $second.Lines[3]
                Assert-Equal completed (Invoke-MutHostMaintenanceTask -Log $second -Operation { 'completed' } -FailureTemplate 'task failed: {0}')
                $captured = 'caller context'
                Assert-Equal $captured (Invoke-MutHostMaintenanceTask -Log $second -Operation { $captured }.GetNewClosure() -FailureTemplate 'task failed: {0}')
                Invoke-MutHostMaintenanceTask -Log $second -Operation { throw 'fixture task failure' } -FailureTemplate 'task failed: {0}' -FailureColor Yellow 6>$null
                Assert-Match 'task failed: fixture task failure$' $second.Lines[-1]
            }
        }
    }

    It 'fails mutations that drop recursion, exclusions or access-error accounting' {
        Assert-HostTreeStatsPolicyMutations
    }

    It 'shares token elevation detection and mutation-checks both caller denial policies' {
        Assert-HostElevationPolicyMutations
    }

    It 'walks nested files rather than silently measuring only the root (mutation)' {
        Assert-HostTreeRecursionMutation
    }
}
