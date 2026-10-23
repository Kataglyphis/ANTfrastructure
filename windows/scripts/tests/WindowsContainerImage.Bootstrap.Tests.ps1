#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsContainerImage.Bootstrap' {
    $script:modulePath = Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsContainerImage.Bootstrap.psm1'
    $script:moduleArguments = @{ ScriptPath = 'windows/scripts/modules/WindowsContainerImage.Bootstrap.psm1'; FunctionName = @('Resolve-ContainerImageModulePath') }

    function script:Assert-ContainerImageModulePath {
        Invoke-InTestDir -Files @{ 'modules/WindowsContainerImage.Common.psm1' = '' } -Body { param($root)
            $expected = Join-Path $root 'modules\WindowsContainerImage.Common.psm1'
            Assert-Equal $expected (Resolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsContainerImage.Common.psm1')
            Assert-Throws -MessagePattern 'Required module not found' -Body {
                Resolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsMissing.Common.psm1'
            }
            Assert-Null (Resolve-ContainerImageModulePath -ModuleRoot $root -Name 'WindowsMissing.Common.psm1' -Optional)
        }
    }

    It 'resolves required modules and keeps optional misses silent (mutation)' {
        Invoke-TestFunctionMutations -ModuleArguments $script:moduleArguments -IncludeControl `
            -Find 'if (-not (Test-Path -LiteralPath $modulePath)) {' -Replace 'if ($false) {' `
            -Expected 'expected an exception but none was thrown' -Body { Assert-ContainerImageModulePath }
    }

    It 'exports the resolver and both lavapipe installers use it' {
        $module = Import-Module $script:modulePath -PassThru
        try { Assert-True $module.ExportedCommands.ContainsKey('Resolve-ContainerImageModulePath') 'the bootstrap resolver is public' }
        finally { Remove-Module $module }

        foreach ($entry in @(
                @{ Path = 'windows/scripts/host/Install-Lavapipe.ps1'; Count = 2 },
                @{ Path = 'windows/scripts/host/Install-LavapipeHost.ps1'; Count = 1 })) {
            $calls = @(Get-TestScriptCommands -ScriptPath $entry.Path -Name Resolve-ContainerImageModulePath)
            Assert-Equal $entry.Count $calls.Count "$($entry.Path) resolves each module through the shared owner"
        }
    }
}
