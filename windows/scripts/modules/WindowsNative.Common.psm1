#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Not in WindowsScripts.Shared, which is copied before the VS layer, so every edit there re-pays the VS install.

Set-StrictMode -Version Latest

function Invoke-ShieldedNative {
    <#
    .SYNOPSIS
        Stderr-shielded native call through `cmd.exe /c "<line> 2>&1"`; throws on non-zero exit unless -Optional.
    .DESCRIPTION
        cmd merges stderr before PS 5.1 can make it a terminating error; $LASTEXITCODE is always normalized afterwards.
    .PARAMETER CommandLine
        The literal cmd.exe command line; the caller quotes paths by cmd's rules, not PowerShell's.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$Label = '',
        [switch]$Optional,
        [switch]$Quiet
    )
    if (-not $Label) { $Label = ($CommandLine -split '\s+')[0] }
    # /s plus a leading space: deterministic quote stripping even when the line starts with a quoted exe path.
    $out = & cmd.exe /s /c " $CommandLine 2>&1"
    $code = $LASTEXITCODE
    if (-not $Quiet) { $out | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0) {
        if ($Optional) {
            Write-Warning "[$Label] exited $code (optional step; continuing)"
        } else {
            $global:LASTEXITCODE = $code
            throw "[$Label] failed (exit $code)"
        }
    }
    $global:LASTEXITCODE = 0
    return $out
}

Export-ModuleMember -Function Invoke-ShieldedNative
