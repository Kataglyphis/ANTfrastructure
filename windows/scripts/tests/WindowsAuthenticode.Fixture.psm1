#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Shared by the harness and Pester signing suites; a fake stands in for Get-AuthenticodeSignature.
Set-StrictMode -Version Latest

function New-FakeAuthenticode {
    <#
      .SYNOPSIS
        A signature reader that reports -Thumbprint as the signer with -Status; an empty thumbprint means unsigned.
    #>
    param([AllowNull()] [AllowEmptyString()] [string]$Thumbprint, [string]$Status = 'UnknownError')
    $signer = if ($Thumbprint) { [pscustomobject]@{ Thumbprint = $Thumbprint } } else { $null }
    $value = [pscustomobject]@{ Status = $Status; StatusMessage = "status $Status"; SignerCertificate = $signer }
    return { param($p) $value }.GetNewClosure()
}

Export-ModuleMember -Function New-FakeAuthenticode
