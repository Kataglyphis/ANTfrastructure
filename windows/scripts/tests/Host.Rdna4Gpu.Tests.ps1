#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Set-Rdna4Gpu device changes' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Set-Rdna4Gpu.ps1' -FunctionName 'Invoke-Rdna4DeviceChanges')
    $script:rdnaChanges = [System.Collections.Generic.List[string]]::new()
    function Set-Rdna4DeviceState {
        param($Device, [string]$State)
        $script:rdnaChanges.Add("$($Device.FriendlyName)|$State")
        return [pscustomobject]@{ Ok = ($Device.FriendlyName -ne 'bad'); Status = 'Error' }
    }
    function New-RdnaDevice {
        param([string]$Name, [string]$Status, [string]$Id)
        return [pscustomobject]@{ FriendlyName = $Name; Status = $Status; InstanceId = $Id }
    }

    It 'skips devices already in the requested state' {
        $script:rdnaChanges.Clear()
        $ready = New-RdnaDevice -Name ready -Status OK -Id one
        $disabled = New-RdnaDevice -Name disabled -Status Error -Id two
        Assert-False (Invoke-Rdna4DeviceChanges -Device @($ready) -Disable $false 6>$null)
        Assert-False (Invoke-Rdna4DeviceChanges -Device @($disabled) -Disable $true 6>$null)
        Assert-Equal 0 $script:rdnaChanges.Count
    }

    It 'continues after one device fails and returns a failing verdict' {
        $script:rdnaChanges.Clear()
        $bad = New-RdnaDevice -Name bad -Status OK -Id one
        $good = New-RdnaDevice -Name good -Status OK -Id two
        Assert-True (Invoke-Rdna4DeviceChanges -Device @($bad, $good) -Disable $true 6>$null)
        Assert-Equal 'bad|Disabled,good|Disabled' ($script:rdnaChanges -join ',')
    }
}
