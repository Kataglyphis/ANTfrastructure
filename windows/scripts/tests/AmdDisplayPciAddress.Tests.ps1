#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
. (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Get-AmdDisplayPciAddress.ps1' -FunctionName Get-DisplayPciAddress, Resolve-AmdDisplayPciAddress)
Describe 'AMD display PCI address' {
    It 'returns the address for the explicitly selected adapter' {
        $displays = @(
            [pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_1111\INTEGRATED'; Status = 'OK' },
            [pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_2222\DISCRETE'; Status = 'OK' }
        )
        $read = { param($Id, $Key) [pscustomobject]@{ Data = if ($Key -eq 'DEVPKEY_Device_Address') { 0 } elseif ($Id -like '*INTEGRATED') { 24 } else { 3 } } }
        Assert-Equal '03:00.0' (Resolve-AmdDisplayPciAddress -TargetId $displays[1].InstanceId -Displays $displays -ReadProperty $read)
    }
    It 'rejects disabled and absent targets' {
        $displays = @([pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_2222\DISCRETE'; Status = 'Error' })
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId $displays[0].InstanceId -Displays $displays -ReadProperty {} } -MessagePattern 'unique and healthy'
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId 'PCI\VEN_1002&DEV_3333\MISSING' -Displays $displays -ReadProperty {} } -MessagePattern 'unique and healthy'
    }
    It 'rejects another PCI display with the same bus and address' {
        $displays = @(
            [pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_1111\INTEGRATED'; Status = 'OK' },
            [pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_2222\DISCRETE'; Status = 'OK' }
        )
        $read = { param($Id, $Key) $null = $Id; [pscustomobject]@{ Data = if ($Key -eq 'DEVPKEY_Device_Address') { 0 } else { 3 } } }
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId $displays[1].InstanceId -Displays $displays -ReadProperty $read } -MessagePattern 'ambiguous'
    }
    It 'rejects a malformed address and a non-AMD target' {
        $displays = @([pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_2222\DISCRETE'; Status = 'OK' })
        $read = { param($Id, $Key) $null = $Id; [pscustomobject]@{ Data = if ($Key -eq 'DEVPKEY_Device_Address') { 0x200000 } else { 3 } } }
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId $displays[0].InstanceId -Displays $displays -ReadProperty $read } -MessagePattern 'invalid'
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId 'PCI\VEN_10DE&DEV_2222\DISCRETE' -Displays $displays -ReadProperty $read } -MessagePattern 'AMD'
    }
    It 'rejects missing and ambiguous PCI properties' {
        $displays = @([pscustomobject]@{ InstanceId = 'PCI\VEN_1002&DEV_2222\DISCRETE'; Status = 'OK' })
        $missing = { param($Id, $Key) $null = $Id; if ($Key -eq 'DEVPKEY_Device_Address') { [pscustomobject]@{ Data = 0 } } }
        $duplicate = { param($Id, $Key) $null = $Id, $Key; [pscustomobject]@{ Data = 0 }; [pscustomobject]@{ Data = 0 } }
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId $displays[0].InstanceId -Displays $displays -ReadProperty $missing } -MessagePattern 'unique bus or address'
        Assert-Throws { Resolve-AmdDisplayPciAddress -TargetId $displays[0].InstanceId -Displays $displays -ReadProperty $duplicate } -MessagePattern 'unique bus or address'
    }
}
