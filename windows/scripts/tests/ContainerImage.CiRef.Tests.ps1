#requires -Version 7.0
# Get-CiImageReference must compose the same refs as ci-image-ref.sh, and never an empty ref on a gap.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsContainerImage.Common.psm1') -Force -DisableNameChecking

Describe 'Get-CiImageReference' {
    It 'composes the Linux, Windows and arm64-bundle refs from versions.env' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $prefix = $v['IMAGE_REGISTRY_PREFIX']
        Assert-Equal "${prefix}:$($v['CI_IMAGE_LINUX_TAG'])" (Get-CiImageReference) 'Linux is the default'
        Assert-Equal "${prefix}:$($v['CI_IMAGE_WINDOWS_TAG'])" (Get-CiImageReference -Windows) 'Windows'
        Assert-Equal "${prefix}:$($v['CI_IMAGE_WINDOWS_ARM64_TAG'])" (Get-CiImageReference -Windows -TargetArch arm64) 'the arm64 bundle, its own key'
        Assert-Equal (Get-CiImageReference -Windows) (Get-CiImageReference -Windows -TargetArch amd64) 'amd64 is the plain Windows image'
    }

    It 'refuses the bundle without -Windows, and throws on a missing key instead of composing half a ref' {
        Assert-Throws { Get-CiImageReference -TargetArch arm64 } -MessagePattern 'needs -Windows'
        Invoke-InTestDir { param($dir)
            $envFile = Join-Path $dir 'versions.env'
            Set-Content -LiteralPath $envFile -Value "IMAGE_REGISTRY_PREFIX=ghcr.io/x/y`nCI_IMAGE_WINDOWS_TAG=win"
            Assert-Equal 'ghcr.io/x/y:win' (Get-CiImageReference -Windows -VersionsEnvPath $envFile) 'amd64 needs only its own key'
            Assert-Throws { Get-CiImageReference -Windows -TargetArch arm64 -VersionsEnvPath $envFile } -MessagePattern 'CI_IMAGE_WINDOWS_ARM64_TAG is not set'
        }
    }
}

Describe 'Container smoke canonical image helpers' {
    $smokeAst = Get-TestScriptAst -ScriptPath 'windows/scripts/build/Test-Container.ps1'
    $imports = @($smokeAst.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Import-Module' -and
                $node.CommandElements.Extent.Text -contains '$containerImageModule' }, $true))
    $importBootstrap = $imports[0]
    while ($importBootstrap.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) {
        $importBootstrap = $importBootstrap.Parent
    }

    It 'imports the canonical helper owner without private fallback definitions' {
        Assert-Equal 1 $imports.Count 'one module import'
        $copies = @($smokeAst.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -in @('Resolve-ContainerImageValue', 'Resolve-VsBuildToolsRoot') }, $true))
        Assert-Equal 0 $copies.Count 'helpers must have one owner'
        $containerImageModule = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsContainerImage.Common.psm1'
        . ([scriptblock]::Create($importBootstrap.Extent.Text))
        Assert-Equal 'canonical' (Resolve-ContainerImageValue -DefaultValue canonical)
        Assert-Equal $containerImageModule (Get-Command Resolve-ContainerImageValue).Module.Path
    }

    It 'refuses an incomplete smoke module closure before reporting passed sections' {
        Assert-Equal 1 $imports.Count 'the import cannot silently disappear'
        Invoke-InTestDir { param($dir)
            $containerImageModule = Join-Path $dir 'missing-module.psm1'
            Assert-False (Test-Path $containerImageModule) 'the fixture has no module'
            Assert-Throws { . ([scriptblock]::Create($importBootstrap.Extent.Text)) }
        }
    }
}
