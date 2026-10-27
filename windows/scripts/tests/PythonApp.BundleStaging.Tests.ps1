#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsPythonApp.Common.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMsix.Common.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.NativeArgs.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'New-PythonAppBundle launcher and data staging' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/python/New-PythonAppBundle.ps1' -FunctionName @('Initialize-PythonAppBundleWorkspace', 'Initialize-PythonAppBundleIcon', 'New-PythonAppBundleLaunchers', 'Copy-PythonAppBundleData'))
    $script:bundleLaunches = [System.Collections.Generic.List[string]]::new()
    $script:bundleIcons = [System.Collections.Generic.List[string]]::new()
    $script:bundleResourceBuilds = 0
    function Get-PythonAppEntryPoint { @{ serve = 'package:main'; inspect = 'package:inspect' } }
    function New-PythonAppLauncher {
        param([string]$Name, [string]$EntryPoint, [string]$IconResource)
        $script:bundleLaunches.Add("$Name=$EntryPoint")
        $script:bundleIcons.Add($IconResource)
        return "$Name.exe"
    }
    function Resolve-PythonAppPath { param([string]$Root, [string]$Path) Join-Path $Root $Path }
    function New-WindowsIconResource {
        param([string]$PngPath, [string]$WorkDir)
        if (-not (Test-Path -LiteralPath $PngPath -PathType Leaf)) { throw "missing icon: $PngPath" }
        $script:bundleResourceBuilds++
        return (Join-Path $WorkDir 'compiled.res')
    }

    It 'writes only requested launchers and rejects a missing console script' {
        $script:bundleLaunches.Clear()
        $app = @{ distribution = 'fixture'; scripts = @('serve'); data_env = ''; data_dir = '' }
        $wanted = @(New-PythonAppBundleLaunchers -App $app -SitePackages fixture -Bundle fixture -WorkDir fixture -Arch amd64 6>$null)
        Assert-Equal 'serve' ($wanted -join ',')
        Assert-Equal 'serve=package:main' ($script:bundleLaunches -join ',')
        $app.scripts = @('missing')
        Assert-Throws { New-PythonAppBundleLaunchers -App $app -SitePackages fixture -Bundle fixture -WorkDir fixture -Arch amd64 6>$null } -MessagePattern 'declares no console script'
    }

    It 'compiles a configured icon once and passes it to every launcher, while absent icons stay optional' {
        Invoke-InTestDir { param($dir)
            $app = @{ distribution = 'fixture'; scripts = @('serve', 'inspect'); data_env = ''; data_dir = '' }
            Assert-Equal '' (Initialize-PythonAppBundleIcon -App $app -RepoRoot $dir -WorkDir $dir)
            $app['icon'] = ''
            Assert-Throws { Initialize-PythonAppBundleIcon -App $app -RepoRoot $dir -WorkDir $dir } -MessagePattern 'icon must name a file'
            $app['icon'] = 'logo.png'
            Assert-Throws { Initialize-PythonAppBundleIcon -App $app -RepoRoot $dir -WorkDir $dir } -MessagePattern 'missing icon'
            Set-Content -LiteralPath (Join-Path $dir 'logo.png') -Value 'fixture'
            $script:bundleResourceBuilds = 0
            $icon = Initialize-PythonAppBundleIcon -App $app -RepoRoot $dir -WorkDir $dir
            Assert-Equal 1 $script:bundleResourceBuilds
            Assert-Equal (Join-Path $dir 'compiled.res') $icon
            $script:bundleIcons.Clear()
            $null = @(New-PythonAppBundleLaunchers -App $app -SitePackages fixture -Bundle $dir -WorkDir $dir -Arch arm64 -IconResource $icon 6>$null)
            Assert-Equal "$icon,$icon" ($script:bundleIcons -join ',')
        }
    }

    It 'links a provided resource after linker flags and keeps the ARM64 target without changing the no-icon path' {
        Invoke-InTestDir { param($dir)
            $state = New-TestCallState @{ Root = $dir; Argv = @() }
            $prelude = @'
$script:LauncherSource = 'launcher.c'
function Get-ClangTargetTriple { param($Arch) return 'aarch64-pc-windows-msvc' }
function clang-cl { $State.Argv = @($args); $global:LASTEXITCODE = 0 }
'@
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsPythonApp.Common.psm1' `
                -FunctionName New-PythonAppLauncher -FixtureState $state -Prelude $prelude -Body { param($fixture)
                    $resource = Join-Path $fixture.Root 'icon file.res'
                    [IO.File]::WriteAllText($resource, 'resource')
                    $base = @{ Name = 'serve'; EntryPoint = 'package:main'; Destination = $fixture.Root;
                        DataEnv = 'DATA'; DataDir = 'share/data'; WorkDir = $fixture.Root; Arch = 'arm64' }
                    $null = New-MutPythonAppLauncher @base -IconResource $resource
                    Assert-TestNativeArgOrder -Arguments $fixture.Argv -First '/SUBSYSTEM:CONSOLE' -Second $resource -Adjacent
                    Assert-True ($fixture.Argv -contains '/clang:--target=aarch64-pc-windows-msvc') 'the cross target remains explicit'
                    $fixture.Argv = @()
                    $null = New-MutPythonAppLauncher @base
                    Assert-False ($fixture.Argv -contains $resource)
                    $fixture.Argv = @()
                    Assert-Throws -MessagePattern 'icon resource not found' -Body { New-MutPythonAppLauncher @base -IconResource (Join-Path $fixture.Root 'missing.res') }
                    Assert-Equal 0 $fixture.Argv.Count
                }
        }
    }

    It 'checks the project licence before resetting the bundle and then installs the original bytes' {
        Invoke-InTestDir { param($dir)
            $bundle = Join-Path $dir 'bundle'
            New-Item -ItemType Directory -Path $bundle -Force | Out-Null
            $sentinel = Join-Path $bundle 'keep.txt'
            [IO.File]::WriteAllText($sentinel, 'old')
            $app = @{}
            Assert-Throws -MessagePattern 'license_file' -Body { Initialize-PythonAppBundleWorkspace -App $app -RepoRoot $dir -Bundle $bundle }
            $app['license_file'] = 'LICENSE'
            Assert-Throws -MessagePattern 'license not found' -Body { Initialize-PythonAppBundleWorkspace -App $app -RepoRoot $dir -Bundle $bundle }
            [IO.File]::WriteAllText((Join-Path $dir 'LICENSE'), '   ')
            Assert-Throws -MessagePattern 'license is empty' -Body { Initialize-PythonAppBundleWorkspace -App $app -RepoRoot $dir -Bundle $bundle }
            Assert-True (Test-Path -LiteralPath $sentinel) 'invalid inputs must not clear an existing bundle'
            [IO.File]::WriteAllText((Join-Path $dir 'LICENSE'), 'actual terms')
            Initialize-PythonAppBundleWorkspace -App $app -RepoRoot $dir -Bundle $bundle
            Assert-False (Test-Path -LiteralPath $sentinel)
            Assert-Equal 'actual terms' ([IO.File]::ReadAllText((Join-Path $bundle 'LICENSE')))
        }
    }

    It 'wires the validated workspace and generated icon into the actual bundle driver' {
        $ast = Get-TestScriptAst -ScriptPath 'windows/scripts/python/New-PythonAppBundle.ps1'
        $workspaces = @(Get-TestAstCommands -Ast $ast -Name 'Initialize-PythonAppBundleWorkspace')
        $icons = @(Get-TestAstCommands -Ast $ast -Name 'Initialize-PythonAppBundleIcon')
        $launchers = @(Get-TestAstCommands -Ast $ast -Name 'New-PythonAppBundleLaunchers')
        Assert-Equal 1 $workspaces.Count
        Assert-Equal 1 $icons.Count
        Assert-Equal 1 $launchers.Count
        Assert-True ($workspaces[0].Extent.StartOffset -lt $icons[0].Extent.StartOffset) 'the workspace is prepared before the icon'
        $arguments = Get-TestCommandArguments -Command $launchers[0]
        Assert-True ($arguments.ContainsKey('IconResource')) 'the generated resource must reach the launchers'
        Assert-Equal '$launcherIcon' $arguments['IconResource']
    }

    It 'copies configured data to its bundle path' {
        Invoke-InTestDir {
            param($dir)
            $source = Join-Path $dir 'input.txt'
            Set-Content -LiteralPath $source -Value 'payload'
            $bundle = Join-Path $dir 'bundle'
            Copy-PythonAppBundleData -App @{ data = @(@{ from = 'input.txt'; to = 'share/data.txt' }) } -RepoRoot $dir -Bundle $bundle 6>$null
            Assert-True (Test-Path (Join-Path $bundle 'share/data.txt'))
            Assert-Equal 'payload' (Get-Content -LiteralPath (Join-Path $bundle 'share/data.txt') -Raw).Trim()
        }
    }
}
