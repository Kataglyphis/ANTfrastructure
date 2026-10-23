#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The device gate unpacks what this packs: a zip without the two markers is a bundle the device cannot run.

Describe 'Export-Arm64Bundle: packs a real bundle or throws' {
    BeforeAll {
    $script:exportScript = Join-Path $PSScriptRoot '..\build\Export-Arm64Bundle.ps1'
    $script:work = New-TestDir -Prefix 'export-arm64bundle-'
    $real = Join-Path $script:work 'real'
    $empty = Join-Path $script:work 'empty'
    $script:out = Join-Path $script:work 'out'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $real 'python'), $empty)
    $null = New-Item -ItemType File -Force -Path (Join-Path $real 'BUNDLE-ENV.ps1')
    Set-Content -LiteralPath (Join-Path $real 'python\python.exe') -Value 'fake'
    }

    It 'refuses a root without BUNDLE-ENV.ps1' {
        Assert-Throws { & $script:exportScript -BundleRoot $empty -OutDir $script:out } 'empty root' -MessagePattern 'BUNDLE-ENV'
    }

    It 'refuses a root without the bundle python' {
        $noPy = Join-Path $script:work 'nopy'
        [void](New-Item -ItemType Directory -Force -Path $noPy)
        Set-Content -Path (Join-Path $noPy 'BUNDLE-ENV.ps1') -Value '# fake'
        Assert-Throws { & $script:exportScript -BundleRoot $noPy -OutDir $script:out } 'no python' -MessagePattern 'python'
    }

    It 'packs the root and copies the gate script beside the zip' {
        & $script:exportScript -BundleRoot $real -OutDir $script:out
        Assert-True (Test-Path (Join-Path $script:out 'bundle.zip')) 'the zip exists'
        Assert-True (Test-Path (Join-Path $script:out 'Test-Arm64Bundle.ps1')) 'the gate script travels with it'
        $helper = Join-Path (Get-RepoRoot) 'linux\scripts\02-toolchain\python\free-threaded-wheel.py'
        Assert-Equal (Get-FileHash $helper).Hash (Get-FileHash (Join-Path $script:out 'free-threaded-wheel.py')).Hash 'and the helper the gate proves the cp3XYt twins with'
        foreach ($module in 'WindowsGstPlugins.Common.psm1', 'WindowsTargetArch.Common.psm1', 'WindowsPythonWheel.Common.psm1') {
            $src = Join-Path (Get-RepoRoot) "windows\scripts\modules\$module"
            Assert-Equal (Get-FileHash $src).Hash (Get-FileHash (Join-Path $script:out $module)).Hash "and $module, which a gate step imports"
        }
    }

    It 'the zip expands to the bundle markers' {
        $dest = Join-Path $script:work 'extract'
        Expand-Archive -LiteralPath (Join-Path $script:out 'bundle.zip') -DestinationPath $dest -Force
        Assert-True (Test-Path (Join-Path $dest 'BUNDLE-ENV.ps1')) 'BUNDLE-ENV.ps1 extracts'
        Assert-True (Test-Path (Join-Path $dest 'python\python.exe')) 'python extracts'
    }

    AfterAll { Remove-TestDir -Path $script:work }
}
