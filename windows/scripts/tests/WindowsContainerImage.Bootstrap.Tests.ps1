#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: running BuildKit or downloading CUDA/TensorRT; this suite grades resolver wiring and Dockerfile mounts.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

Describe 'WindowsContainerImage.Bootstrap' {
    $script:modulePath = Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsContainerImage.Bootstrap.psm1'
    $script:moduleArguments = @{ ScriptPath = 'windows/scripts/modules/WindowsContainerImage.Bootstrap.psm1'; FunctionName = @('Resolve-ContainerImageModulePath') }

    It 'resolves required modules and keeps optional misses silent (mutation)' {
        Invoke-TestFunctionMutations -ModuleArguments $script:moduleArguments -IncludeControl `
            -Find 'if (-not (Test-Path -LiteralPath $modulePath)) {' -Replace 'if ($false) {' `
            -Expected 'expected an exception but none was thrown' -Body {
                Invoke-InTestDir -Files @{ 'modules/WindowsContainerImage.Common.psm1' = '' } -Body { param($root)
                    $expected = Join-Path $root 'modules\WindowsContainerImage.Common.psm1'
                    Assert-Equal $expected (MutResolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsContainerImage.Common.psm1')
                    Assert-Throws -MessagePattern 'Required module not found' -Body {
                        MutResolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsMissing.Common.psm1'
                    }
                    Assert-Null (MutResolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsMissing.Common.psm1' -Optional)
                }
            }
    }

    It 'exports the resolver and container installers use it' {
        $module = Import-Module $script:modulePath -PassThru
        try { Assert-True $module.ExportedCommands.ContainsKey('Resolve-ContainerImageModulePath') 'the bootstrap resolver is public' }
        finally { Remove-Module $module }

        foreach ($entry in @(
                @{ Path = 'windows/scripts/host/Install-Lavapipe.ps1'; Count = 2; ImageInstaller = $false; Shared = $false },
                @{ Path = 'windows/scripts/host/Install-LavapipeHost.ps1'; Count = 1; ImageInstaller = $false; Shared = $false },
                @{ Path = 'windows/scripts/host/Install-Cuda.ps1'; Count = 1; ImageInstaller = $true; Shared = $false },
                @{ Path = 'windows/scripts/host/Install-Tensorrt.ps1'; Count = 2; ImageInstaller = $true; Shared = $true })) {
            $calls = @(Get-TestScriptCommands -ScriptPath $entry.Path -Name Resolve-ContainerImageModulePath)
            Assert-Equal $entry.Count $calls.Count "$($entry.Path) resolves each module through the shared owner"
            if (-not $entry.ImageInstaller) { continue }

            $ast = Get-TestScriptAst -ScriptPath $entry.Path
            $imports = @(Get-TestScriptCommands -ScriptPath $entry.Path -Name Import-Module)
            Assert-Equal (2 + [int]$entry.Shared) $imports.Count "$($entry.Path) imports bootstrap, common, and shared helper"
            Assert-Match 'WindowsContainerImage.Bootstrap.psm1' $imports[0].Extent.Text "$($entry.Path) imports the bootstrap first"
            $helperImports = @($imports | Where-Object { $_.Extent.Text -match '\$sharedHelpersPath' })
            Assert-Equal ([int]$entry.Shared) $helperImports.Count "$($entry.Path) imports the TensorRT helper only when it is not loaded"
            if ($entry.Shared) {
                Assert-False ($helperImports[0].Extent.Text -match '\s-Force\b') 'shared helper import remains unforced'
            }

            $resolverText = $calls.Extent.Text -join "`n"
            Assert-Match "-Name 'WindowsContainerImage.Common.psm1'" $resolverText "$($entry.Path) requires WindowsContainerImage.Common"
            Assert-Match '-ModuleRoot \$ModuleRoot' $resolverText "$($entry.Path) resolves from its caller root"
            if ($entry.Shared) {
                Assert-Match 'Resolve-ContainerImageModulePath -ModuleRoot \$ModuleRoot -Name ''WindowsScripts.Shared.psm1''' $resolverText 'TensorRT requires WindowsScripts.Shared'
                Assert-Match 'if \(-not \(Get-Module -Name ''WindowsScripts.Shared''\)\) \{ Import-Module \$sharedHelpersPath \}' $ast.Extent.Text 'TensorRT keeps its loaded-module guard'
            }
        }
    }

    It 'nvidia installers mount the resolver per file and pass the container module root' {
        $dockerfile = Join-Path (Get-RepoRoot) 'windows\Dockerfile.nvidia'
        $runs = @(Get-TestDockerLogicalLine -LiteralPath $dockerfile | Where-Object { $_ -match '^RUN\s' -and $_ -match 'Install-(Cuda|Tensorrt)\.ps1' })
        Assert-Equal 2 $runs.Count 'both nvidia installer RUNs are covered'
        foreach ($entry in @(
                @{ Script = 'Install-Tensorrt.ps1'; Run = $runs | Where-Object { $_ -match 'Install-Tensorrt\.ps1' } },
                @{ Script = 'Install-Cuda.ps1'; Run = $runs | Where-Object { $_ -match 'Install-Cuda\.ps1' } })) {
            Assert-Match '--mount=type=bind,source=scripts/modules/WindowsContainerImage\.Bootstrap\.psm1,target=C:\\temp\\scripts\\modules\\WindowsContainerImage\.Bootstrap\.psm1' $entry.Run "$($entry.Script) mounts the bootstrap module narrowly"
            Assert-Match ("{0}.*-ModuleRoot 'C:\\temp\\scripts'" -f [regex]::Escape($entry.Script)) $entry.Run "$($entry.Script) passes its module root"
        }
    }
}
