# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#requires -Version 7.0

Set-StrictMode -Version Latest

function Resolve-ContainerImageModulePath {
    param(
        [Parameter(Mandatory)][string]$ModuleRoot,
        [string]$Name = 'WindowsContainerImage.Common.psm1',
        [switch]$Optional
    )
    $modulePath = Join-Path $ModuleRoot (Join-Path 'modules' $Name)
    if (-not (Test-Path -LiteralPath $modulePath)) {
        if ($Optional) { return $null }
        throw "Required module not found: $modulePath"
    }
    return $modulePath
}

Export-ModuleMember -Function 'Resolve-ContainerImageModulePath'
