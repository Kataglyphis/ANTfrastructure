# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

Assert-ContainerCommandAvailable -Name 'flutter' | Out-Null
Assert-ContainerCommandAvailable -Name 'wix' | Out-Null
Assert-ContainerCommandAvailable -Name 'clang-cl' | Out-Null
Assert-ContainerCommandAvailable -Name 'lld-link' | Out-Null
Assert-ContainerCommandAvailable -Name 'cmake' | Out-Null

# A silent scoop fallback to another clang-cl would otherwise surface hours later as a patch that no longer applies.
$clangOut = & clang-cl --version
if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed (exit code $LASTEXITCODE)" }
$clangBanner = $clangOut | Select-Object -First 1
Write-Host ("clang-cl (provenance): {0}" -f $clangBanner)
$expectedLlvm = Resolve-ContainerImageValue -EnvironmentVariable 'LLVM_WINDOWS_VERSION' -DefaultValue ''
if ($expectedLlvm -and $clangBanner -notmatch [regex]::Escape($expectedLlvm)) {
    throw ("clang-cl version mismatch: expected $expectedLlvm (versions.env LLVM_WINDOWS_VERSION), got '$clangBanner'. " +
        'Either scoop could not serve the pinned manifest, or the pin was bumped without rebuilding this layer. ' +
        'A version change here invalidates the clang-cl-shaped patches under windows/scripts/patches/ — ' +
        're-run windows/scripts/tests/Test-PatchesApplyClean.ps1 after a deliberate bump.')
}

# ninja and nasm shape what ships; an sccache older than v0.16.0 silently ignores SCCACHE_MULTILEVEL_CHAIN.
foreach ($pinned in @(
        @{ Tool = 'ninja';   Args = @('--version'); EnvVar = 'NINJA_WINDOWS_VERSION' },
        @{ Tool = 'nasm';    Args = @('-v');        EnvVar = 'NASM_WINDOWS_VERSION' },
        @{ Tool = 'sccache'; Args = @('--version'); EnvVar = 'SCCACHE_WINDOWS_VERSION' })) {
    $expected = Resolve-ContainerImageValue -EnvironmentVariable $pinned.EnvVar -DefaultValue ''
    if (-not $expected) { continue }
    # Real splatting: an array subexpression works for native commands only by accident of argument flattening.
    $toolArgs = $pinned.Args
    $banner = (& $pinned.Tool @toolArgs 2>&1 | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "$($pinned.Tool) $($toolArgs -join ' ') failed (exit code $LASTEXITCODE)" }
    if ($banner -notmatch [regex]::Escape($expected)) {
        throw "$($pinned.Tool) version mismatch: expected $expected (versions.env $($pinned.EnvVar)), got '$banner'"
    }
    Write-Host "$($pinned.Tool) OK: $banner"
}

# Fail the base build on a CMake pin mismatch, not hours later in a media build.
$expectedCmake = Resolve-ContainerImageValue -EnvironmentVariable 'CMAKE_VERSION' -DefaultValue ''
if ($expectedCmake) {
    $cmakeOut = & cmake --version
    if ($LASTEXITCODE -ne 0) { throw "cmake --version failed (exit code $LASTEXITCODE)" }
    $cmakeBanner = $cmakeOut | Select-Object -First 1
    if ($cmakeBanner -notmatch [regex]::Escape($expectedCmake)) {
        throw "cmake version mismatch: expected $expectedCmake (versions.env), got '$cmakeBanner'"
    }
    Write-Host "cmake OK: $cmakeBanner"
}

# Captured first: .Source on a miss would throw under StrictMode.
$wixCommandInfo = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wixCommandInfo) { throw 'wix.exe not found on PATH (Assert-ContainerCommandAvailable failed)' }
$wixCmd = $wixCommandInfo.Source

& $wixCmd --version | Out-Host
if ($LASTEXITCODE -ne 0) { throw "wix --version failed (exit code $LASTEXITCODE)" }
$wixExtensions = & $wixCmd extension list --global 2>&1
$wixExtensions | Out-Host
# Before the extension assert, or a broken wix masquerades as a missing extension.
if ($LASTEXITCODE -ne 0) { throw "wix extension list --global failed (exit code $LASTEXITCODE): $wixExtensions" }
# Assert against the same versions.env value the install used (no hand-synced literal).
$wixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.6'
if (-not ($wixExtensions | Select-String -SimpleMatch "WixToolset.UI.wixext $wixUiExtVersion")) {
    throw "Required WiX extension not installed: WixToolset.UI.wixext $wixUiExtVersion"
}


# ARM64 cross readiness: compile-only, since VsDevCmd has not run in this layer and a link would fail for unrelated reasons
$archModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if (-not (Test-Path $archModulePath)) { throw "Required module not found: $archModulePath" }
Import-Module $archModulePath -Force

$armTriple  = Get-ClangTargetTriple -Arch 'arm64'
$armMachine = Get-PeMachineType -Arch 'arm64'

# File-local helpers: moving them into a module would widen the base stage's build closure.

function Invoke-Arm64StrictPolicy {
    param([Parameter(Mandatory)][string]$Shortfall)
    if ($env:WINDOWS_ARM64_STRICT -eq '1') { throw $Shortfall }
    Write-Warning "$Shortfall (amd64 lane unaffected; WINDOWS_ARM64_STRICT=1 makes this fatal)"
}

# MSVC and the SDK both install ARM64 libraries under <root>\<version>\<rel>.
function Assert-Arm64ComponentLib {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Remedy
    )
    $found = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $RelativePath } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ($found) {
        Write-Host "$Label OK: $found"
        return
    }
    Invoke-Arm64StrictPolicy -Shortfall "$Label missing under $Root (expected <ver>\$RelativePath). $Remedy"
}

$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('archprobe-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $probeDir
try {
    $probeSrc = Join-Path $probeDir 'probe.c'
    Set-Content -LiteralPath $probeSrc -Value 'int probe(int x) { return x + 1; }' -Encoding ASCII
    $probeObj = Join-Path $probeDir 'probe.obj'

    & clang-cl "--target=$armTriple" /c $probeSrc "/Fo$probeObj" 2>&1 | ForEach-Object { Write-Host "  $_" }
    $probeFailure = ''
    if ($LASTEXITCODE -ne 0) {
        $probeFailure = "clang-cl failed to compile for $armTriple (exit $LASTEXITCODE)"
    } elseif (-not (Test-Path $probeObj)) {
        $probeFailure = "clang-cl produced no object file for $armTriple"
    } else {
        # An unlinked COFF object starts with IMAGE_FILE_HEADER, whose first two bytes are the Machine field.
        $objBytes = [System.IO.File]::ReadAllBytes($probeObj)
        if ($objBytes.Length -lt 2) {
            $probeFailure = "clang-cl produced a truncated object file for $armTriple"
        } else {
            # The [int] casts matter: -shl keeps the left operand's type, so [byte]0xAA -shl 8 is 0.
            $objMachine = [int]$objBytes[0] -bor ([int]$objBytes[1] -shl 8)
            if ($objMachine -ne $armMachine) {
                $probeFailure = ('clang-cl targeted the wrong architecture: object machine 0x{0:X4}, expected 0x{1:X4} ({2}).' -f $objMachine, $armMachine, $armTriple)
            } else {
                Write-Host ('clang-cl cross-compiles to {0} (object machine 0x{1:X4}) OK' -f $armTriple, $objMachine)
            }
        }
    }
    if ($probeFailure) { Invoke-Arm64StrictPolicy -Shortfall $probeFailure }
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# MSVC ARM64 CRT + import libraries (installed by VC.Tools.ARM64).
$msvcRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\$(Resolve-ContainerImageValue -EnvironmentVariable 'VISUAL_STUDIO_VERSION' -DefaultValue '18')\BuildTools\VC\Tools\MSVC"
if (-not (Test-Path $msvcRoot)) {
    $msvcRoot = Join-Path $env:ProgramFiles "Microsoft Visual Studio\$(Resolve-ContainerImageValue -EnvironmentVariable 'VISUAL_STUDIO_VERSION' -DefaultValue '18')\BuildTools\VC\Tools\MSVC"
}
Assert-Arm64ComponentLib -Label 'MSVC ARM64 libraries' -Root $msvcRoot -RelativePath 'lib\arm64\libcmt.lib' -Remedy (
    'The VC.Tools.ARM64 component is not installed; clang-cl cannot link an aarch64 target without it.')

# The SDK component is architecture-complete, so this asserts an expectation, not an install step.
$sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
Assert-Arm64ComponentLib -Label 'Windows SDK ARM64 import libraries' -Root $sdkLibRoot -RelativePath 'um\arm64\kernel32.lib' -Remedy (
    'Reinstall the Windows 11 SDK component with ARM64 support.')

# Warn-only unless WINDOWS_ARM64_STRICT=1: the shared base must not block amd64 over an arm64-only prerequisite.
if ($env:VULKAN_SDK) {
    $vkArmLib = Join-Path $env:VULKAN_SDK (Get-VulkanLibDirName -Arch 'arm64')
    if (Test-Path (Join-Path $vkArmLib 'vulkan-1.lib')) {
        Write-Host "Vulkan ARM64 import library OK: $vkArmLib"
    } elseif ($env:WINDOWS_ARM64_STRICT -eq '1') {
        throw ("Vulkan ARM64 import library missing at $vkArmLib. The com.lunarg.vulkan.arm64 component " +
            'is optional in the x64 SDK and Install-ScoopTools.ps1 must add it. ' +
            'WINDOWS_ARM64_STRICT=1 made this a hard gate.')
    } else {
        Write-Warning ("Vulkan ARM64 import library missing at $vkArmLib - an arm64 target cannot link Vulkan. " +
            'The amd64 lane is unaffected. Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
} else {
    Write-Warning 'VULKAN_SDK is not set - skipping the Vulkan ARM64 import-library check.'
}
