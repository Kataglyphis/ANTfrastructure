#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A fake Gallery proves retry and pin verdicts; this suite does not contact the real service.

$bootstrapPrelude = @'
function Get-Module {
    param([switch]$ListAvailable, [string]$Name)
    if (-not $ListAvailable -or $Name -ne $State.Name) { throw 'Unexpected module query' }
    $State.Available
}
function Install-Module {
    param([string]$Name, [string]$RequiredVersion, [string]$MinimumVersion, [string]$Scope,
        [switch]$Force, [switch]$SkipPublisherCheck, [string]$ErrorAction)
    $State.Attempts++
    $State.LastCall = @{ Name = $Name; RequiredVersion = $RequiredVersion; MinimumVersion = $MinimumVersion;
        Scope = $Scope; Force = $Force.IsPresent; SkipPublisherCheck = $SkipPublisherCheck.IsPresent; ErrorAction = $ErrorAction }
    if ($State.Attempts -le $State.Failures) { throw 'Gallery lookup unavailable' }
    if ($State.Materialize) {
        $version = if ($RequiredVersion) { [version]$RequiredVersion } else { [version]$MinimumVersion }
        $State.Available = @([pscustomobject]@{ Name = $Name; Version = $version })
    }
}
function Start-Sleep { param([int]$Seconds) $State.Sleeps.Add($Seconds) | Out-Null }
'@

function New-BootstrapState {
    param([string]$Name = 'Pester', [string[]]$AvailableVersions = @(), [int]$Failures = 0, [bool]$Materialize = $true)
    $available = @($AvailableVersions | ForEach-Object { [pscustomobject]@{ Name = $Name; Version = [version]$_ } })
    [pscustomobject]@{
        Name = $Name; Available = $available; Failures = $Failures; Materialize = $Materialize
        Attempts = 0; LastCall = @{}; Sleeps = [Collections.Generic.List[int]]::new()
    }
}

function Invoke-BootstrapFixture {
    param([object]$State, [scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1' `
        -FunctionName @('Get-CiInstalledModule', 'Install-PinnedPowerShellModule') -Prelude $bootstrapPrelude `
        -FixtureState $State -Body $Body -Find $Find -Replace $Replace
}

function Assert-InstalledBootstrapSelection {
    param([object]$State, [string]$Version, [string]$Expected, [switch]$Minimum)
    Invoke-BootstrapFixture -State $State -Body {
        param($s)
        $selected = Install-MutPinnedPowerShellModule -Name $s.Name -Version $Version -Minimum:$Minimum
        Assert-Equal $Expected $selected.Version.ToString()
        Assert-Equal 0 $s.Attempts
    }.GetNewClosure()
}

Describe 'Shared CI PowerShell module bootstrap' {
    It 'wires Pester and analyzer jobs to the same installer' {
        $root = Get-RepoRoot
        $action = [IO.File]::ReadAllText((Join-Path $root '.github/actions/run-pester-suite/action.yml'))
        $windows = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/windows-x64.yml'))
        $reusable = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/powershell-quality.yml'))
        $pesterExact = 'Install-PinnedPowerShellModule -Name Pester -Version ''${{ inputs.version }}'''
        Assert-True $action.Contains($pesterExact) 'shared Pester action uses the installer'
        Assert-True $action.Contains('GITHUB_ACTION_PATH') 'action imports its own versioned module'
        Assert-True $action.Contains('../../../windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1') 'action resolves the module from its own checkout'
        Assert-True $windows.Contains("Install-PinnedPowerShellModule -Name Pester -Version '6.2' -Minimum") 'hub tests use the installer'
        foreach ($workflow in @($windows, $reusable)) {
            Assert-True $workflow.Contains('Install-PinnedPowerShellModule -Name PSScriptAnalyzer -Version $pin') `
                'analyzer workflows use the installer with their resolved pin'
            Assert-True $workflow.Contains('WindowsCi.ModuleBootstrap.psm1') 'analyzer workflows import the shared module'
            Assert-True $workflow.Contains('Resolve-Path -LiteralPath') 'workflow imports a rooted module path'
        }
        $actionDir = Join-Path $root '.github/actions/run-pester-suite'
        $actionModule = (Resolve-Path -LiteralPath (Join-Path $actionDir '../../../windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1')).Path
        Assert-Equal (Join-Path $root 'windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1') $actionModule
        $mutant = $action.Replace($pesterExact, 'Install-Module Pester -RequiredVersion ''${{ inputs.version }}''')
        Assert-Throws { Assert-True $mutant.Contains($pesterExact) 'shared Pester action uses the installer' } `
            -MessagePattern 'shared Pester action uses the installer'
    }

    It 'uses installed exact and minimum versions without a Gallery request' {
        foreach ($case in @(
                @{ Available = @('3.4.0', '6.2.0'); Version = '3.4.0'; Expected = '3.4.0'; Minimum = $false }
                @{ Available = @('6.1.0', '6.2.1'); Version = '6.2'; Expected = '6.2.1'; Minimum = $true }
            )) {
            $state = New-BootstrapState -AvailableVersions $case.Available
            Assert-InstalledBootstrapSelection -State $state -Version $case.Version -Expected $case.Expected -Minimum:$case.Minimum
        }
    }

    It 'retries a transient lookup and verifies the exact installed version' {
        $state = New-BootstrapState -Name PSScriptAnalyzer -Failures 1
        Invoke-BootstrapFixture -State $state -Body {
            param($s)
            $selected = Install-MutPinnedPowerShellModule -Name PSScriptAnalyzer -Version '1.25.0'
            Assert-Equal '1.25.0' $selected.Version.ToString()
            Assert-Equal 2 $s.Attempts
            Assert-Equal 1 $s.Sleeps.Count
            Assert-Equal '1.25.0' $s.LastCall.RequiredVersion
            Assert-Equal 'Stop' $s.LastCall.ErrorAction
            Assert-Equal 'CurrentUser' $s.LastCall.Scope
            Assert-True $s.LastCall.Force
        }
    }

    It 'fails after bounded Gallery errors and when installation materializes no matching module' {
        $down = New-BootstrapState -Failures 5
        Invoke-BootstrapFixture -State $down -Body {
            param($s)
            Assert-Throws { Install-MutPinnedPowerShellModule -Name Pester -Version '3.4.0' } `
                -MessagePattern 'after 5 attempt.*Gallery lookup unavailable'
            Assert-Equal 5 $s.Attempts
        }
        $missing = New-BootstrapState -Materialize $false
        Invoke-BootstrapFixture -State $missing -Body {
            param($s)
            Assert-Throws { Install-MutPinnedPowerShellModule -Name Pester -Version '3.4.0' } `
                -MessagePattern 'without Pester RequiredVersion 3.4.0'
            Assert-Equal 5 $s.Attempts
        }
    }

    It 'rejects a mutant that treats a successful installer return as proof' {
        $state = New-BootstrapState -Materialize $false
        $find = 'if ($installed.Count -eq 0) { throw "Installer returned without $Name $versionKind $target" }'
        Invoke-BootstrapFixture -State $state -Find $find -Replace 'if ($false) { throw "unreachable" }' -Body {
            Assert-Throws {
                Assert-Throws { Install-MutPinnedPowerShellModule -Name Pester -Version '3.4.0' } `
                    -MessagePattern 'without Pester'
            } -MessagePattern 'expected an exception'
        }
    }
}
