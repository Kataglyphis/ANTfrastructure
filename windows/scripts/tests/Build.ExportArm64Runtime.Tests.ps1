#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Real staging over synthetic PE files covers archive inputs, not Windows DLL loading or inference.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsOrtPayload.Common.psm1') -Force -DisableNameChecking
. (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Export-Arm64Bundle.ps1' -FunctionName Get-Arm64BundleOrtOverlay)

Describe 'ARM64 bundle ORT overlay' {
    It 'stages exact chain bytes for both targets without changing the image tree' {
        foreach ($arch in 'amd64', 'arm64') {
            Invoke-InTestDir { param($dir)
                $machine = if ($arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
                $chain = Join-Path $dir 'runtime/lib/onnxruntime-source/bin'
                $names = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'DirectML.dll')
                foreach ($name in $names) { New-OrtTestPe -Path (Join-Path $chain $name) -Machine $machine -Text @($name) }
                Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = $arch } {
                    $entries = @(Get-Arm64BundleOrtOverlay -BundleRoot (Join-Path $dir runtime) -StageRoot (Join-Path $dir overlay))
                    Assert-Equal 3 $entries.Count
                    foreach ($name in $names) {
                        Assert-True ($entries -contains "bin/$name")
                        Assert-Equal (Get-FileHash (Join-Path $chain $name)).Hash (Get-FileHash (Join-Path $dir "overlay/bin/$name")).Hash
                        Assert-False (Test-Path -LiteralPath (Join-Path $dir "runtime/bin/$name"))
                    }
                    New-OrtTestPe -Path (Join-Path $dir 'runtime/bin/onnxruntime.dll') -Machine $machine -Text @('stale')
                    Assert-Throws { Get-Arm64BundleOrtOverlay -BundleRoot (Join-Path $dir runtime) -StageRoot (Join-Path $dir overlay) } -MessagePattern 'refusing a duplicate archive member'
                }
            }
        }
    }

    It 'rejects a missing chain core and a core for the wrong target' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'arm64' } {
                Assert-Throws { Get-Arm64BundleOrtOverlay -BundleRoot $dir -StageRoot (Join-Path $dir overlay) } -MessagePattern 'not the chain install'
                New-OrtTestPe -Path (Join-Path $dir 'lib/onnxruntime-source/bin/onnxruntime.dll') -Machine 0x8664
                Assert-Throws { Get-Arm64BundleOrtOverlay -BundleRoot $dir -StageRoot (Join-Path $dir overlay) } -MessagePattern 'PE machine'
            }
        }
    }
}
