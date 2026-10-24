#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'GenieX active CDSP driver selection' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Test-GeniexNpuDriver.ps1' -FunctionName 'Get-ActiveCdspDriver')
    $script:cdspFiles = @()

    It 'selects the Hexagon PnP version rather than a newer stale store copy' {
        $script:cdspFiles = @(
            [pscustomobject]@{ FullName = 'stale.dll'; VersionInfo = [pscustomobject]@{ FileVersion = '31.0.1.0' } },
            [pscustomobject]@{ FullName = 'active.dll'; VersionInfo = [pscustomobject]@{ FileVersion = '30.0.0220.3000' } }
        )
        Invoke-WithTestFunction -Name Get-CimInstance -Definition {
            [pscustomobject]@{ DeviceName = 'Qualcomm Hexagon NPU'; DriverVersion = '30.0.220.3000' }
        } -Body {
            Invoke-WithTestFunction -Name Get-ChildItem -Definition { $script:cdspFiles } -Body {
                Assert-Equal 'active.dll' (Get-ActiveCdspDriver).FullName
            }
        }
    }

    It 'returns no active copy when PnP discovery fails' {
        Invoke-WithTestFunction -Name Get-CimInstance -Definition { throw 'driver query failed' } -Body {
            Assert-Equal $null (Get-ActiveCdspDriver)
        }
    }
}
