#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Optimize-HostVhdx guest report' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Optimize-HostVhdx.ps1' -FunctionName 'Write-GuestVolumeReport')
    $script:guestReport = [System.Collections.Generic.List[string]]::new()
    function Write-HostStep {
        param($Log, [string]$Message, [string]$Color)
        $script:guestReport.Add($Message)
    }

    It 'warns that a ReFS guest will not reclaim dead blocks' {
        $script:guestReport.Clear()
        $volume = [pscustomobject]@{ Size = 100GB; SizeRemaining = 60GB; FileSystem = 'ReFS'; FileSystemLabel = 'store' }
        Write-GuestVolumeReport -Volume $volume -PhysicalBytes 80GB -Log @{}
        Assert-Match '40.0 GB used of 100.0 GB' ($script:guestReport -join "`n")
        Assert-Match '40.0 GB of dead blocks' ($script:guestReport -join "`n")
        Assert-Match 'WARNING: ReFS guest' ($script:guestReport -join "`n")
    }

    It 'reports an unattached guest without claiming reclaim potential' {
        $script:guestReport.Clear()
        Write-GuestVolumeReport -Volume $null -PhysicalBytes 80GB -Log @{}
        Assert-Equal 1 $script:guestReport.Count
        Assert-Match 'not attached' $script:guestReport[0]
    }
}
