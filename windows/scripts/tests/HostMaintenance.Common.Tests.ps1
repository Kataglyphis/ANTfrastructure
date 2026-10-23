#requires -Version 7.0
# Transcript and tree-stat fixtures do not touch live services, disks, registry values, ACLs or host probes.

Describe 'Host maintenance contexts and live-process guard' {
    It 'isolates transcript contexts and preserves idle, force, diagnostics and save-before-throw policies' {
        $probeCommands = @(foreach ($script in @('Reset-ContainerLocks', 'Reset-ContainerStores', 'Set-BuildkitdGcpolicy')) {
            Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script.ps1" -Name Write-HostMaintenanceProbe | ForEach-Object { $_.Extent.Text }
        })
        $state = [pscustomobject]@{ Results = @(); Calls = 0; Names = @(); ProbeArguments = @(); ProbeCommands = $probeCommands }
        $prelude = 'function Get-Process { param($Name) $State.Calls++; $State.Names = $Name; $State.Results }; function Invoke-TestHostProbe { $State.ProbeArguments = $args; $global:LASTEXITCODE = 7; "wanted: worker"; "irrelevant" }'
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName New-HostMaintenanceLog, Write-HostStep, Save-HostMaintenanceLog, Write-HostMaintenanceMessage, Write-HostMaintenanceProbe, Get-HostMaintenanceProcess, Write-HostMaintenanceFailure, Write-HostMaintenanceError, Invoke-HostMaintenanceTask -Prelude $prelude -FixtureState $state -Body { param($state)
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
                    & ([scriptblock]::Create($command.Replace('Write-HostMaintenanceProbe', 'Write-MutHostMaintenanceProbe'))) 6>$null
                    Assert-True ($state.ProbeArguments.Count -gt 0)
                }
                Assert-Match '^\[\d\d:\d\d:\d\d\] first context$' $first.Lines[0]
                Assert-False ($second.Lines[0].Contains('first context'))
                Assert-Equal (Join-Path $dir 'out\first.log') $first.LogPath
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

    It 'walks nested files rather than silently measuring only the root (mutation)' {
        Assert-HostTreeRecursionMutation
    }
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

function Assert-HostTreeStatsPolicyMutations {
    $cases = [System.Collections.Generic.List[object]]::new()
    $cases.Add(@{ Find = '-not ($ExcludeDir | Where-Object { $parts -contains $_ })'; Replace = '$true'; Expected = 'excluded files must not contribute bytes' })
    $cases.Add(@{ Find = '-ErrorVariable ev'; Replace = ''; Expected = 'unreadable paths must remain observable' })
    Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName Get-HostMaintenanceTreeStats -Prelude (New-HostTreeStatsPrelude) -IncludeControl -Case $cases.ToArray() -Body {
        $stats = Get-MutHostMaintenanceTreeStats -Root 'C:\fixture' -ExcludeDir '$RECYCLE.BIN'
        Assert-Equal 5 $stats.Bytes 'excluded files must not contribute bytes'
        Assert-Equal 1 $stats.Files 'excluded files must not contribute to the count'
        Assert-Equal 1 $stats.Errors 'unreadable paths must remain observable'
    }
}

function Assert-HostTreeRecursionMutation {
    Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName Get-HostMaintenanceTreeStats -IncludeControl -Find '-Recurse' -Replace '' -Expected 'expected nested file count' -Body {
        Invoke-InTestDir -Files @{ 'top.bin' = 'abc'; 'nested\deep.bin' = '123456' } -Body {
            param($dir)
            $stats = Get-MutHostMaintenanceTreeStats -Root $dir
            Assert-Equal 2 $stats.Files 'expected nested file count'
            Assert-Equal 9 $stats.Bytes
        }
    }
}
