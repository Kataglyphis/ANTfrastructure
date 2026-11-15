#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: installer or batch execution; native installer cases remain in Torch.Rocm.Check.Tests.ps1.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Assert-TorchRocmInstallRefused { param([object]$Result, [string]$Pattern, [string]$Why)
    Assert-True ($Result.Rc -ne 0) "exit code $($Result.Rc); output: $($Result.Out)"
    Assert-Match $Pattern (ConvertTo-TestDiagnosticText -Output @($Result.Out)) $Why
    Assert-False $Result.CacheMade 'refused before any download'
}

Export-ModuleMember -Function Assert-TorchRocmInstallRefused
