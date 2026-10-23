#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest

function ConvertTo-TestDockerLogicalText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text -replace '`\r?\n', ' '
}

function Get-TestDockerLogicalText {
    param([Parameter(Mandatory)][string]$LiteralPath)
    ConvertTo-TestDockerLogicalText -Text ([IO.File]::ReadAllText($LiteralPath))
}

function ConvertTo-TestDockerLogicalLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (ConvertTo-TestDockerLogicalText -Text $Text) -split "`n"
}

function Get-TestDockerLogicalLine {
    param([Parameter(Mandatory)][string]$LiteralPath)
    ConvertTo-TestDockerLogicalLine -Text ([IO.File]::ReadAllText($LiteralPath))
}

Export-ModuleMember -Function ConvertTo-TestDockerLogicalText, Get-TestDockerLogicalText, ConvertTo-TestDockerLogicalLine, Get-TestDockerLogicalLine
