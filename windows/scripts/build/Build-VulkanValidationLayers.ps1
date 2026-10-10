# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Stages VkLayer_khronos_validation for the target arch in C:\runtime\vulkan-layers.
.DESCRIPTION
    arm64 builds Khronos Vulkan-ValidationLayers at vulkan-sdk-<VULKAN_VERSION>, with the dependency
    commits that tag's scripts\known_good.json names; amd64 copies the same-version layer from the SDK.
    See docs/windows-cross-builds.md § The Vulkan validation layer.
#>
param(
    [string]$InstallDir = 'C:\runtime\vulkan-layers',
    [string]$WorkDir = 'C:\temp\vvl',
    [string]$VulkanVersion = '',
    [string]$TargetArch = '',
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LayerName = 'VkLayer_khronos_validation'

function Get-VvlDependencyPlan {
    <#
    .SYNOPSIS
        The known_good.json repos a Windows layer build needs, in file order, with {repo_dir} expanded.
    #>
    param(
        [Parameter(Mandatory)][string]$KnownGoodJson,
        [Parameter(Mandatory)][string]$WorkDir
    )
    $repos = @((ConvertFrom-Json -InputObject $KnownGoodJson).repos)
    $plan = foreach ($repo in $repos) {
        $optional = @(if ($repo.PSObject.Properties['optional']) { $repo.optional })
        if ($optional.Count -gt 0) { continue }
        $platforms = @(if ($repo.PSObject.Properties['build_platforms']) { $repo.build_platforms })
        if ($platforms.Count -gt 0 -and 'windows' -notin $platforms) { continue }
        if (-not $repo.commit) { throw "known_good.json: $($repo.name) has no commit" }
        $source = Join-Path $WorkDir $repo.sub_dir
        $options = @(if ($repo.PSObject.Properties['cmake_options']) { $repo.cmake_options }) |
            ForEach-Object { $_.Replace('{repo_dir}', $source.Replace('\', '/')) }
        # The layer links SPIRV-Tools-opt only; its executables would be arm64 binaries nothing runs.
        if ($repo.name -eq 'SPIRV-Tools') { $options = @($options) + '-DSPIRV_SKIP_EXECUTABLES=ON' }
        [pscustomobject]@{ Name = $repo.name; Url = $repo.url; Commit = $repo.commit; SourceDir = $source; CmakeOptions = @($options) }
    }
    $names = @($plan | ForEach-Object Name)
    foreach ($required in 'Vulkan-Headers', 'Vulkan-Utility-Libraries', 'SPIRV-Headers', 'SPIRV-Tools') {
        if ($required -notin $names) { throw "known_good.json names no $required; the layer cannot configure without it" }
    }
    return @($plan)
}

function Assert-ValidationLayerManifest {
    <#
    .SYNOPSIS
        Throws unless the manifest names the validation layer and a library beside it.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.layer.name -ne 'VK_LAYER_KHRONOS_validation') { throw "$Path names layer '$($manifest.layer.name)'" }
    if ($manifest.layer.library_path -notmatch '^\.[\\/]+VkLayer_khronos_validation\.dll$') {
        throw "$Path has library_path '$($manifest.layer.library_path)'; the DLL must sit beside it"
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
if ($ScriptDir) { & (Join-Path $ScriptDir 'Import-Versions.ps1') }

$arch = if ($TargetArch) { $TargetArch } else { Get-WindowsTargetArch }
if ($arch -notin 'amd64', 'arm64') { throw "Build-VulkanValidationLayers: -TargetArch must be amd64 or arm64; got '$arch'" }
$VulkanVersion = Get-SourceBuildVersion -Value $VulkanVersion -EnvironmentVariables @('VULKAN_VERSION')
if ($VulkanVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "VULKAN_VERSION '$VulkanVersion' is not four-part (stale versions.env?)" }
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$dll = Join-Path $InstallDir "$LayerName.dll"
$json = Join-Path $InstallDir "$LayerName.json"

if ($arch -eq 'amd64') {
    # The x64 SDK ships this very layer; arm64 has none in any SDK the amd64 container can install.
    $sdkBin = Join-Path $env:VULKAN_SDK 'Bin'
    Copy-Item -LiteralPath (Join-Path $sdkBin "$LayerName.dll"), (Join-Path $sdkBin "$LayerName.json") -Destination $InstallDir -Force
} else {
    $null = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot
    $py = Initialize-ToolchainPythonEnvironment
    $vvlSource = Join-Path $WorkDir 'Vulkan-ValidationLayers'
    $depsPrefix = Join-Path $WorkDir 'deps'
    Invoke-GitClone -RepoUrl 'https://github.com/KhronosGroup/Vulkan-ValidationLayers.git' -SourceDir $vvlSource -Tag "vulkan-sdk-$VulkanVersion"

    $plan = Get-VvlDependencyPlan -KnownGoodJson (Get-Content -LiteralPath (Join-Path $vvlSource 'scripts\known_good.json') -Raw) -WorkDir $WorkDir
    $common = @("-DCMAKE_PREFIX_PATH=$($depsPrefix.Replace('\', '/'))", "-DPython3_EXECUTABLE=$($py.Exe)") + (Get-LlvmArchiverCmakeArg)
    foreach ($dep in $plan) {
        Write-Host "=== $($dep.Name) @ $($dep.Commit) ($arch) ==="
        Invoke-GitClone -RepoUrl $dep.Url -SourceDir $dep.SourceDir -Tag $dep.Commit
        $buildDir = Join-Path $WorkDir "build\$($dep.Name)"
        Invoke-CmakeConfigure -SourceDir $dep.SourceDir -BuildDir $buildDir -InstallPrefix $depsPrefix `
            -ExtraArgs ($common + $dep.CmakeOptions) -TargetArch $arch
        Invoke-NinjaBuildWithRetry -BuildDir $buildDir -Install -InstallConfig 'Release'
    }

    Write-Host "=== Vulkan-ValidationLayers vulkan-sdk-$VulkanVersion ($arch) ==="
    $vvlBuild = Join-Path $WorkDir 'build\Vulkan-ValidationLayers'
    $vvlPrefix = Join-Path $WorkDir 'install'
    # No sccache here: on 1.4.363 the arm64 compile of vk_validation_error_messages.cpp hung in the server twice (2026-10-10).
    Invoke-CmakeConfigure -SourceDir $vvlSource -BuildDir $vvlBuild -InstallPrefix $vvlPrefix -TargetArch $arch `
        -ExtraArgs ($common + @('-DUPDATE_DEPS=OFF', '-DBUILD_WERROR=OFF', '-DBUILD_TESTS=OFF',
            '-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=', '-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH='))
    Invoke-NinjaBuildWithRetry -BuildDir $vvlBuild -Install -InstallConfig 'Release'
    foreach ($name in "$LayerName.dll", "$LayerName.json") {
        $built = @(Get-ChildItem -LiteralPath $vvlPrefix -Recurse -File -Filter $name)
        if ($built.Count -ne 1) { throw "expected one $name under $vvlPrefix, found $($built.Count)" }
        Copy-Item -LiteralPath $built[0].FullName -Destination $InstallDir -Force
    }
}

$absent = @(@($dll, $json) | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($absent.Count -gt 0) { throw "the layer was not staged: $($absent -join ', ')" }
Assert-ValidationLayerManifest -Path $json
# The image's arch gate checks this too, but only this names the layer.
$layerMachine = Get-PeFileMachine -Path $dll
if ($layerMachine -ne (Get-PeMachineType -Arch $arch)) { throw ('{0} is PE machine 0x{1:X4}, not {2}' -f $dll, $layerMachine, $arch) }
Write-Host ('Vulkan validation layer {0} ({1}, PE 0x{2:X4}) staged in {3}' -f $VulkanVersion, $arch, $layerMachine, $InstallDir)
if ($arch -eq 'arm64') {
    Complete-SourceBuild -Banner "=== Vulkan validation layer build complete ($arch) ===" -SourceDir $WorkDir
}
