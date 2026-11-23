#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
# Disposable Git and metadata tests cover pins, recursive transport and CMake argument wiring; they do not compile GenAI or prove inference.

Import-TestRepoModule -Name WindowsScripts.Shared, WindowsSourceBuild.Common
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsOrt.SourceFixture.psm1') -ErrorAction Stop
$script:ExtensionsScript = 'windows/scripts/build/Build-OnnxGenaiFromSource.ps1'
. (Get-ScriptFunctionDefinition -ScriptPath $script:ExtensionsScript -FunctionName Get-GenaiExtensionsCommit, Get-GenaiExtensionsCmakeArgs)
$script:ExtensionsUrl = 'https://github.com/microsoft/onnxruntime-extensions.git'
$script:ExtensionsPin = 'e2e119c08b4379d038bcb5c75d9111328a9b86c1'

Describe 'GenAI extensions source identity' {
    It 'reads the exact upstream commit independently of unrelated dependency rows' {
        $lines = @('#Name;Url;SHA1', 'other;https://example.invalid;abc', "onnxruntime_extensions;$script:ExtensionsUrl;$script:ExtensionsPin")
        Assert-Equal $script:ExtensionsPin (Get-GenaiExtensionsCommit -DepsLine $lines)
    }
    It 'rejects missing and ambiguous declarations' {
        $row = "onnxruntime_extensions;$script:ExtensionsUrl;$script:ExtensionsPin"
        Assert-Throws { Get-GenaiExtensionsCommit -DepsLine @('other;url;hash') } -MessagePattern 'exactly one dependency row'
        Assert-Throws { Get-GenaiExtensionsCommit -DepsLine @($row, $row) } -MessagePattern 'exactly one dependency row'
    }
    It 'rejects changed repositories, abbreviated or uppercase commits and extra fields' {
        $rows = @(
            "onnxruntime_extensions;https://example.invalid/extensions.git;$script:ExtensionsPin",
            "onnxruntime_extensions;$script:ExtensionsUrl;e2e119c",
            "onnxruntime_extensions;$script:ExtensionsUrl;$($script:ExtensionsPin.ToUpperInvariant())",
            "onnxruntime_extensions;$script:ExtensionsUrl;$script:ExtensionsPin;extra"
        )
        foreach ($row in $rows) {
            Assert-Throws { Get-GenaiExtensionsCommit -DepsLine @($row) } -MessagePattern 'upstream repository and a full lowercase commit'
        }
    }
    It 'returns one source argument after an actual exact-commit checkout under a path with spaces' {
        Invoke-OrtSourceFixture {
            param($fixture)
            Write-TestFileTree -Root $fixture.Options.SourceDir -Files @{
                'cmake/deps.txt' = "onnxruntime_extensions;$script:ExtensionsUrl;$($fixture.Commit)"
            }
            $url = [uri]::new($fixture.Repo).AbsoluteUri
            Invoke-WithEnv @{
                GIT_CONFIG_COUNT = '1'
                GIT_CONFIG_KEY_0 = "url.$url.insteadOf"
                GIT_CONFIG_VALUE_0 = $script:ExtensionsUrl
            } {
                $arguments = @(Get-GenaiExtensionsCmakeArgs -SourceDir $fixture.Options.SourceDir)
                $source = Join-Path $fixture.Options.SourceDir 'extensions-source'
                Assert-Equal 1 $arguments.Count 'one argument retains spaces'
                Assert-Equal "-DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME_EXTENSIONS:PATH=$($source.Replace('\', '/'))" $arguments[0]
                Assert-OrtSourceFixtureCheckout -Fixture $fixture -Path $source
            }.GetNewClosure()
        }
    }
    It 'passes the checked source into the existing CMake argument list before configure' {
        $commands = Get-TestScriptCommandMap -ScriptPath $script:ExtensionsScript -Name Get-GenaiExtensionsCmakeArgs, Invoke-CmakeConfigure `
            -Order Get-GenaiExtensionsCmakeArgs, Invoke-CmakeConfigure `
            -UnconditionalText @{ 'Get-GenaiExtensionsCmakeArgs' = 'Get-GenaiExtensionsCmakeArgs -SourceDir $SourceDir' }
        Assert-TestAstCommand -Command @($commands['Get-GenaiExtensionsCmakeArgs']) `
            -Text 'Get-GenaiExtensionsCmakeArgs -SourceDir $SourceDir' -Assignment '$cmakeExtraGenAi'
        $assignment = Get-TestAstAncestor -Node $commands['Get-GenaiExtensionsCmakeArgs'] -Type ([Management.Automation.Language.AssignmentStatementAst]) -First
        Assert-Equal 'PlusEquals' $assignment.Operator.ToString() 'keep the ORT and other CMake arguments'
        Assert-TestAstCommand -Command @($commands['Invoke-CmakeConfigure']) `
            -Text 'Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $genaiBuildDir -ExtraArgs $cmakeExtraGenAi -InstallPrefix $genaiInstallDir 2>&1' -Unconditional
    }
}
