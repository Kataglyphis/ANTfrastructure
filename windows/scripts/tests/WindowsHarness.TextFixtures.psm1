#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -DisableNameChecking -ErrorAction Stop

function ConvertTo-TestFileText {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Line = @())
    if ($null -eq $Line -or $Line.Count -eq 0) { return '' }
    return ($Line -join [Environment]::NewLine) + [Environment]::NewLine
}

function ConvertTo-TestFileMap {
    param([Parameter(Mandatory)][Collections.IDictionary]$LineFiles)
    $files = [ordered]@{}
    foreach ($entry in $LineFiles.GetEnumerator()) { $files[$entry.Key] = ConvertTo-TestFileText -Line $entry.Value }
    return $files
}

function Invoke-InTestLineDir {
    param([Parameter(Mandatory)][Collections.IDictionary]$LineFiles, [Parameter(Mandatory)][scriptblock]$Body)
    Invoke-InTestDir -Files (ConvertTo-TestFileMap -LineFiles $LineFiles) -Body $Body
}

Export-ModuleMember -Function ConvertTo-TestFileText, ConvertTo-TestFileMap, Invoke-InTestLineDir
