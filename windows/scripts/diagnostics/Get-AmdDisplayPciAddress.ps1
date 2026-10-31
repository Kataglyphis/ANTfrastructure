#requires -Version 7.0
<#
.SYNOPSIS
  Resolve an explicit healthy AMD display device to its Windows PCI address.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstanceId)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DisplayPciAddress {
    param([object]$Display, [scriptblock]$ReadProperty)
    $busProperty = @(& $ReadProperty $Display.InstanceId 'DEVPKEY_Device_BusNumber')
    $deviceProperty = @(& $ReadProperty $Display.InstanceId 'DEVPKEY_Device_Address')
    if ($busProperty.Count -ne 1 -or $deviceProperty.Count -ne 1 -or
        $null -eq $busProperty[0].Data -or $null -eq $deviceProperty[0].Data) { throw 'A PCI display lacks a unique bus or address.' }
    $bus = [long]$busProperty[0].Data
    $encoded = [long]$deviceProperty[0].Data
    $device = $encoded -shr 16
    $function = $encoded -band 0xffff
    if ($bus -lt 0 -or $bus -gt 255 -or $device -lt 0 -or $device -gt 31 -or $function -gt 7) {
        throw 'A PCI display has an invalid bus or address.'
    }
    [pscustomobject]@{ InstanceId = $Display.InstanceId; Address = ('{0:x2}:{1:x2}.{2:x1}' -f $bus, $device, $function) }
}

function Resolve-AmdDisplayPciAddress {
    param([string]$TargetId, [object[]]$Displays, [scriptblock]$ReadProperty)
    if ($TargetId -notmatch '^PCI\\VEN_1002&') { throw 'An explicit AMD PCI display InstanceId is required.' }
    $displays = @($Displays | Where-Object { $_.InstanceId -match '^PCI\\' })
    $target = @($displays | Where-Object { $_.InstanceId -ieq $TargetId })
    if ($target.Count -ne 1 -or $target[0].Status -ne 'OK') { throw 'The selected display must be unique and healthy.' }
    $addresses = @(foreach ($display in $displays) { Get-DisplayPciAddress -Display $display -ReadProperty $ReadProperty })
    $selected = @($addresses | Where-Object { $_.InstanceId -ieq $TargetId })
    if ($selected.Count -ne 1 -or @($addresses | Where-Object { $_.Address -ceq $selected[0].Address }).Count -ne 1) {
        throw 'The selected PCI address is ambiguous among Windows displays.'
    }
    $selected[0].Address
}
$allDisplays = @(Get-PnpDevice -Class Display -ErrorAction Stop)
Resolve-AmdDisplayPciAddress -TargetId $InstanceId -Displays $allDisplays -ReadProperty {
    param($Id, $Key)
    Get-PnpDeviceProperty -InstanceId $Id -KeyName $Key -ErrorAction Stop
}
