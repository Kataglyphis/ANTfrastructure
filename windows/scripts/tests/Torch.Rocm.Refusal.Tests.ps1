#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: installer or batch execution; native installer cases remain in Torch.Rocm.Check.Tests.ps1.

Import-Module (Join-Path $PSScriptRoot 'WindowsTorchRocm.RefusalFixture.psm1') -ErrorAction Stop

Describe 'Torch ROCm refusal assertions' {
    It 'matches a wrapped refusal while retaining the exit, reason and pre-download checks' {
        $reason = 'rocBLAS serves gfx1036, the device pins cover only gfx1201, gfx1200'
        $sample = @{ Rc = 1; CacheMade = $false; Out = "`e[31mrocBLAS serves gfx1036, the device pins cover only gfx1201,`r`n     | gfx1200`e[0m" }
        Assert-TorchRocmInstallRefused $sample $reason 'wrapped refusal'
        $sample.Rc = 0
        Assert-Throws { Assert-TorchRocmInstallRefused $sample $reason '' } -MessagePattern 'Assert-True'
        $sample.Rc = 1
        Assert-Throws { Assert-TorchRocmInstallRefused $sample 'missing reason' '' } -MessagePattern 'Assert-Match'
        $sample.CacheMade = $true
        Assert-Throws { Assert-TorchRocmInstallRefused $sample $reason '' } -MessagePattern 'Assert-False'
    }
}
