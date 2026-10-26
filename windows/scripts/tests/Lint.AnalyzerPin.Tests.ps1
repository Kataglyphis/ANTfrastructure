#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Runner image updates must not float lint results; this fixture does not test PowerShell Gallery installation.

function Assert-WorkflowMutation {
    param([string]$Workflow, [string]$Original, [string]$Replacement, [scriptblock]$Check, [string]$Path = '', [string]$RequiredText = '')
    $Text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $Workflow))
    if ($RequiredText) { Assert-True ($Text.Contains($RequiredText)) "$Workflow resolves the hub pin path" }
    Assert-True ($Text.Contains($Original)) 'the workflow mutation has a real subject'
    & $Check $Text $Path
    $mutant = $Text.Replace($Original, $Replacement)
    Assert-Throws { & $Check $mutant $Path } -MessagePattern 'Assert-True'
}

Describe 'Invoke-Lint analyzer pin' {
    It 'uses the hub pin when a newer module is also installed' {
        Invoke-InTestDir { param($d)
            $modules = @(
                [pscustomobject]@{ Name = 'newer'; Version = [version]'1.26.0' }
                [pscustomobject]@{ Name = 'pinned'; Version = [version]'1.25.0' }
            )
            $state = [pscustomobject]@{
                WindowsDir = (Join-Path $d 'windows')
                PinFile = (Join-Path $d 'linux/scripts/01-core/versions.env')
                Modules = $modules
                SharedPath = (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1')
            }
            New-Item -ItemType Directory -Force (Split-Path -Parent $state.PinFile) | Out-Null
            Set-Content -LiteralPath $state.PinFile 'PSSCRIPTANALYZER_VERSION=1.25.0'
            $prelude = @'
$windowsDir = $State.WindowsDir
Import-Module $State.SharedPath -ErrorAction Stop
function Get-Module {
    param([switch]$ListAvailable, [string]$Name)
    if (-not $ListAvailable -or $Name -ne 'PSScriptAnalyzer') { throw 'Unexpected module query' }
    $State.Modules
}
'@
            $fixture = @{
                ScriptPath = 'windows/scripts/Invoke-Lint.ps1'
                FunctionName = @('Get-AnalyzerPin', 'Get-AnalyzerModule')
                Prelude = $prelude
                FixtureState = $state
            }
            Invoke-WithFunctionModule @fixture -Body {
                param($s)
                Assert-Equal '1.25.0' ((Get-MutAnalyzerPin -File $s.PinFile).ToString())
                Assert-Equal 'pinned' (Get-MutAnalyzerModule).Name 'the default reads the hub pin'
                $s.Modules = @($s.Modules[0])
                Assert-Throws { Get-MutAnalyzerModule } -MessagePattern 'PSScriptAnalyzer 1\.25\.0 is not installed'
            }
            $state.Modules = $modules
            Invoke-WithFunctionModule @fixture -Find '$_.Version -eq $pin' -Replace '$_.Version -ge $pin' -Body {
                Assert-Throws { Assert-Equal 'pinned' (Get-MutAnalyzerModule).Name } -MessagePattern 'Assert-Equal'
            }
        }
    }

    It 'fails when the hub pin is missing, duplicated or invalid' {
        Invoke-InTestDir { param($d)
            $state = [pscustomobject]@{
                File = (Join-Path $d 'versions.env')
                SharedPath = (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1')
            }
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/Invoke-Lint.ps1' -FunctionName Get-AnalyzerPin `
                -FixtureState $state -Prelude 'Import-Module $State.SharedPath -ErrorAction Stop' -Body {
                param($s)
                Assert-Throws { Get-MutAnalyzerPin -File $s.File } -MessagePattern 'pin file is missing'
                Set-Content -LiteralPath $s.File 'OTHER_VERSION=1.25.0'
                Assert-Throws { Get-MutAnalyzerPin -File $s.File } -MessagePattern 'must occur exactly once'
                Set-Content -LiteralPath $s.File @('PSSCRIPTANALYZER_VERSION=1.25.0', ' PSSCRIPTANALYZER_VERSION =1.26.0')
                Assert-Throws { Get-MutAnalyzerPin -File $s.File } -MessagePattern 'must occur exactly once'
                Set-Content -LiteralPath $s.File 'PSSCRIPTANALYZER_VERSION=unexpected'
                Assert-Throws { Get-MutAnalyzerPin -File $s.File } -MessagePattern 'Invalid PSSCRIPTANALYZER_VERSION'
                Set-Content -LiteralPath $s.File 'PSSCRIPTANALYZER_VERSION="1.25.0"'
                Assert-Equal '1.25.0' ((Get-MutAnalyzerPin -File $s.File).ToString())
            }
        }
    }

    It 'keeps both analyzer paths on the pin lookup' {
        $source = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/Invoke-Lint.ps1'))
        $child = $source.Substring($source.IndexOf('if ($PssaBatch) {'), $source.IndexOf('# Default scope:') - $source.IndexOf('if ($PssaBatch) {'))
        $parent = $source.Substring($source.IndexOf('# Pass 2: PSScriptAnalyzer'))
        Assert-True ($child -match '(?m)^    \$analyzerModule = Get-AnalyzerModule$') 'batch child selects the pin'
        Assert-True ($parent -match '(?m)^\$analyzerModule = Get-AnalyzerModule$') 'parent selects the pin'
    }

    It 'runs for action edits on push and pull requests' {
        $check = {
            param([string]$text)
            foreach ($triggerName in @('push', 'pull_request')) {
                $section = [regex]::Match($text, "(?ms)^  ${triggerName}:\r?\n(?<body>.*?)(?=^  (?:push|pull_request):|^permissions:)").Groups['body'].Value
                Assert-True ($section -match '(?m)^      - ''\.github/actions/\*\*''\r?$') "$triggerName watches .github/actions"
            }
        }
        Assert-WorkflowMutation -Workflow '.github/workflows/windows-x64.yml' -Original "      - '.github/actions/**'" -Replacement '' -Check $check
    }

    It 'installs the hub pin in Windows lanes and the reusable quality workflow' {
        $check = {
            param([string]$text, [string]$path)
            $install = [regex]::Match($text, '(?ms)^      - name: Install PSScriptAnalyzer\r?\n(?<step>.*?)(?=^      - name:|^      #)').Groups['step'].Value
            Assert-True ($install.Contains("Get-Content -LiteralPath $path")) "install reads $path"
            Assert-True ($install.Contains('Install-PinnedPowerShellModule -Name PSScriptAnalyzer -Version $pin')) 'shared installer uses the parsed pin'
        }
        foreach ($case in @(
                @{ Workflow = '.github/workflows/windows-x64.yml'; Path = "'linux/scripts/01-core/versions.env'" }
                @{ Workflow = '.github/workflows/powershell-quality.yml'; Path = '$versions'; Root = "Join-Path `$hub 'linux/scripts/01-core/versions.env'" }
            )) {
            $root = if ($case.ContainsKey('Root')) { $case.Root } else { '' }
            Assert-WorkflowMutation -Workflow $case.Workflow -Original 'Install-PinnedPowerShellModule -Name PSScriptAnalyzer -Version $pin' `
                -Replacement 'Install-PinnedPowerShellModule -Name PSScriptAnalyzer -Version 1.25.0' -Check $check -Path $case.Path -RequiredText $root
        }
        $checkCaller = {
            param([string]$text)
            $job = [regex]::Match($text, '(?ms)^  lint-powershell:\r?\n(?<body>.*?)(?=^  [a-z][\w-]*:|\z)').Groups['body'].Value
            Assert-True ($job.Contains('uses: ./.github/workflows/powershell-quality.yml')) 'consumer lint job calls the pinned quality workflow'
        }
        Assert-WorkflowMutation -Workflow '.github/workflows/python-ci-windows.yml' -Original 'uses: ./.github/workflows/powershell-quality.yml' `
            -Replacement 'uses: ./.github/workflows/missing-quality.yml' -Check $checkCaller
    }
}
