#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'New-PythonAppBundle launcher and data staging' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/python/New-PythonAppBundle.ps1' -FunctionName @('New-PythonAppBundleLaunchers', 'Copy-PythonAppBundleData'))
    $script:bundleLaunches = [System.Collections.Generic.List[string]]::new()
    function Get-PythonAppEntryPoint { @{ serve = 'package:main'; inspect = 'package:inspect' } }
    function New-PythonAppLauncher {
        param([string]$Name, [string]$EntryPoint)
        $script:bundleLaunches.Add("$Name=$EntryPoint")
        return "$Name.exe"
    }
    function Resolve-PythonAppPath { param([string]$Root, [string]$Path) Join-Path $Root $Path }

    It 'writes only requested launchers and rejects a missing console script' {
        $script:bundleLaunches.Clear()
        $app = @{ distribution = 'fixture'; scripts = @('serve'); data_env = ''; data_dir = '' }
        $wanted = @(New-PythonAppBundleLaunchers -App $app -SitePackages fixture -Bundle fixture -WorkDir fixture -Arch amd64 6>$null)
        Assert-Equal 'serve' ($wanted -join ',')
        Assert-Equal 'serve=package:main' ($script:bundleLaunches -join ',')
        $app.scripts = @('missing')
        Assert-Throws { New-PythonAppBundleLaunchers -App $app -SitePackages fixture -Bundle fixture -WorkDir fixture -Arch amd64 6>$null } -MessagePattern 'declares no console script'
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
