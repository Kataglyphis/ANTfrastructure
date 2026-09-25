#requires -Version 7.0
# Get-CiImageReference, the PowerShell twin of linux/scripts/ci-image-ref.sh: the same refs
# composed from versions.env, the arm64 cross bundle's own key, and no empty ref on a gap.

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
