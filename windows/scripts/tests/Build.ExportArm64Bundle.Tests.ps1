#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The device gate unpacks what this packs: a zip without the two markers is a bundle the device cannot run.

Describe 'Export-Arm64Bundle: packs a real bundle or throws' {

    $exportScript = Join-Path $PSScriptRoot '..\build\Export-Arm64Bundle.ps1'
    $work = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'export-arm64bundle-' + [guid]::NewGuid().ToString('N'))
    $real = Join-Path $work 'real'
    $empty = Join-Path $work 'empty'
    $out = Join-Path $work 'out'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $real 'python'), $empty)
    $null = New-Item -ItemType File -Force -Path (Join-Path $real 'BUNDLE-ENV.ps1')
    Set-Content -LiteralPath (Join-Path $real 'python\python.exe') -Value 'fake'

    It 'refuses a root without BUNDLE-ENV.ps1' {
        Assert-Throws { & $exportScript -BundleRoot $empty -OutDir $out } 'empty root' -MessagePattern 'BUNDLE-ENV'
    }

    It 'refuses a root without the bundle python' {
        $noPy = Join-Path $work 'nopy'
        [void](New-Item -ItemType Directory -Force -Path $noPy)
        Set-Content -Path (Join-Path $noPy 'BUNDLE-ENV.ps1') -Value '# fake'
        Assert-Throws { & $exportScript -BundleRoot $noPy -OutDir $out } 'no python' -MessagePattern 'python'
    }

    It 'packs the root and copies the gate script beside the zip' {
        & $exportScript -BundleRoot $real -OutDir $out
        Assert-True (Test-Path (Join-Path $out 'bundle.zip')) 'the zip exists'
        Assert-True (Test-Path (Join-Path $out 'Test-Arm64Bundle.ps1')) 'the gate script travels with it'
    }

    It 'the zip expands to the bundle markers' {
        $dest = Join-Path $work 'extract'
        Expand-Archive -LiteralPath (Join-Path $out 'bundle.zip') -DestinationPath $dest -Force
        Assert-True (Test-Path (Join-Path $dest 'BUNDLE-ENV.ps1')) 'BUNDLE-ENV.ps1 extracts'
        Assert-True (Test-Path (Join-Path $dest 'python\python.exe')) 'python extracts'
    }

    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
