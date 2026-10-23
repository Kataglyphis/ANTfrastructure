#requires -Version 7.0
# Fake drives cover rounding and caller verdicts; real storage capacity, network availability and stage floor selection stay outside this suite.

function New-DriveSpaceFixture {
    $state = New-TestCallState @{ Space = @{ C = 0; D = (50.06 * 1GB); N = $null }; Records = [Collections.Generic.List[string]]::new() }
    $source = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Get-DriveFreeSpaceGb).ToString()
    $source += "`n" + (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsBuildDriver.Common.psm1' -FunctionName Assert-DiskHeadroom, Assert-StageDiskHeadroom).ToString()
    return @{ Text = $source; FixtureState = $state; Prelude = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-PSDrive {
    param($Name, $ErrorAction)
    $State.Calls.Add(@($Name, $ErrorAction))
    if ($Name -eq 'throwing') { throw 'fixture drive probe failed' }
    if ($State.Space.ContainsKey($Name)) { [pscustomobject]@{ Free = $State.Space[$Name] } }
}
function Write-DriverRecord { param($Message) $State.Records.Add($Message) }
function Get-StageDiskFloorGb { 40 }
'@ }
}

function Assert-DriveSpaceValues {
    param($State)
    Assert-Equal 0 (Get-MutDriveFreeSpaceGb -Drive C) 'a full disk is a measured zero'
    Assert-Equal 50.1 (Get-MutDriveFreeSpaceGb -Drive D) 'space is rounded to one decimal'
    Assert-Null (Get-MutDriveFreeSpaceGb -Drive missing) 'an absent drive is unknown'
    Assert-Null (Get-MutDriveFreeSpaceGb -Drive N) 'a provider without Free is unknown'
    Assert-Equal 'C|SilentlyContinue' ($State.Calls[0] -join '|') 'probe options retain the caller drive'
    Assert-Throws { Get-MutDriveFreeSpaceGb -Drive throwing } -MessagePattern '^fixture drive probe failed$'
}

Describe 'Shared disk free-space probing' {
    It 'distinguishes zero from unknown and rounds readings, with faults for both decisions' {
        $recipe = @{ ModuleArguments = (New-DriveSpaceFixture); IncludeControl = $true; Body = { param($state) Assert-DriveSpaceValues $state } }
        Invoke-TestFunctionMutations @recipe -Find '$null -eq $disk.Free' -Replace '-not $disk.Free' -Expected 'a full disk is a measured zero'
        Invoke-TestFunctionMutations @recipe -Find '[math]::Round($disk.Free / 1GB, 1)' -Replace '($disk.Free / 1GB)' -Expected 'space is rounded to one decimal'
    }

    It 'retains drive normalization, distinct missing-drive policies, force warnings and stage records' {
        $recipe = New-DriveSpaceFixture
        Invoke-WithFunctionModule @recipe -Body { param($state)
            Assert-Throws { Assert-MutDiskHeadroom -Drive @('d:', 'D:\context', 'missing', 'N') -MinFreeGb 40 6>$null } -MessagePattern 'C: has 0 GB free'
            Assert-Equal 'C|D|M|N' (($state.Calls | ForEach-Object { $_[0] }) -join '|') 'initial checks normalize and deduplicate drive paths'
            $warning = @(Assert-MutDiskHeadroom -Drive missing -MinFreeGb 40 -Force 3>&1 6>$null)
            Assert-Equal 1 $warning.Count
            Assert-Match 'C: has 0 GB free.*continuing because -Force' $warning[0].Message
            $state.Space.C = (80 * 1GB)
            Assert-Equal 0 @(Assert-MutDiskHeadroom -Drive missing, N -MinFreeGb 40 6>$null).Count 'initial unknown drives stay optional'
            $warning = @(Assert-MutStageDiskHeadroom -Label sample -Drive missing -FloorGb 40 3>&1 6>$null)
            Assert-Equal 1 $warning.Count 'stage unknown drives must remain visible'
            Assert-Match 'NOT checked' $warning[0].Message
            Assert-Match 'NOT checked' $state.Records[-1]
            $state.Space.C = 0
            Assert-Throws { Assert-MutStageDiskHeadroom -Label sample -Drive C -FloorGb 1 } -MessagePattern 'REFUSING to start.*0 GB free'
            Assert-Match 'REFUSED: 0 GB free' $state.Records[-1]
            $warning = @(Assert-MutStageDiskHeadroom -Label sample -Drive C -FloorGb 1 -Force 3>&1)
            Assert-Equal 1 $warning.Count
            Assert-Match 'continued under the host-check override' $state.Records[-1]
            Assert-MutStageDiskHeadroom -Label sample -Drive D -FloorGb 50 6>$null
            Assert-Match 'disk OK: 50.1 GB free on D:' $state.Records[-1]
        }
    }

    It 'binds initial, stage and host diagnostics to the exported probe' {
        Assert-Equal 2 @(Get-TestScriptCommands -ScriptPath 'windows/scripts/modules/WindowsBuildDriver.Common.psm1' -Name Get-DriveFreeSpaceGb).Count
        Assert-Equal 1 @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Test-HostSetup.ps1' -Name Get-DriveFreeSpaceGb).Count
        $root = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1'
        $result = Test-ColdModuleCommands -ModulePath $root -CommandName Get-DriveFreeSpaceGb
        Assert-Equal 0 $result.ExitCode $result.Output
    }
}
