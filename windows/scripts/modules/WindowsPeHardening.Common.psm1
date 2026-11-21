# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# The PE twin of 06-packaging/verify-elf-hardening.sh (CON294): ASLR, DEP and CFG in a repo's own binaries.
Import-Module (Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1') -DisableNameChecking

function Get-PeHardening {
    # The DllCharacteristics bits ASLR, DEP and CFG set, and whether the image is PE32+; throws on a non-PE.
    param([Parameter(Mandatory)][string]$Path)
    $layout = Read-PeLayout -Path $Path -Caller 'Get-PeHardening'
    # The optional header follows e_lfanew's 'PE\0\0' and the 20-byte COFF header; DllCharacteristics sits 70 bytes in.
    $optional = [BitConverter]::ToInt32($layout.Bytes, 60) + 24
    $flags = [BitConverter]::ToUInt16($layout.Bytes, $optional + 70)
    return [pscustomobject]@{
        Pe32Plus      = [BitConverter]::ToUInt16($layout.Bytes, $optional) -eq 0x20B
        DynamicBase   = [bool]($flags -band 0x0040)
        HighEntropyVa = [bool]($flags -band 0x0020)
        NxCompat      = [bool]($flags -band 0x0100)
        GuardCf       = [bool]($flags -band 0x4000)
    }
}

function Assert-PeHardening {
    # Throws naming each PE that lacks DYNAMIC_BASE, NX_COMPAT, HIGH_ENTROPY_VA (PE32+) or GUARD_CF; -NoCfg waives CFG by leaf.
    param([Parameter(Mandatory)][string[]]$Path, [string[]]$NoCfg = @())
    $misses = @(foreach ($file in $Path) {
            $pe = Get-PeHardening -Path $file
            $lacks = @(
                if (-not $pe.DynamicBase) { 'DYNAMIC_BASE' }
                if (-not $pe.NxCompat) { 'NX_COMPAT' }
                if ($pe.Pe32Plus -and -not $pe.HighEntropyVa) { 'HIGH_ENTROPY_VA' }
                if (-not $pe.GuardCf -and (Split-Path -Leaf $file) -notin $NoCfg) { 'GUARD_CF' }
            )
            if ($lacks.Count -gt 0) { "$file lacks $($lacks -join ', ')" }
        })
    if ($misses.Count -gt 0) { throw "PE hardening: $($misses.Count) file(s) fall short:`n  $($misses -join "`n  ")" }
}

Export-ModuleMember -Function Get-PeHardening, Assert-PeHardening
