#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

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

function Get-TestDockerfileRun {
    param([Parameter(Mandatory)][string]$Path, [string]$Stage = 'built')
    $docker = Get-TestDockerfileStagesFromPath -Path $Path -JoinContinuations -IgnoreComments -TrimLines -StrictFromHeader
    if (-not $docker.ByName.ContainsKey($Stage)) { throw "Dockerfile stage '$Stage' is missing: $Path" }
    $docker.ByName[$Stage].Lines | Where-Object { $_ -match '^RUN ' }
}

function Get-TestDockerfileBuildRun {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ScriptLeaf, [string]$Stage = 'built')
    $runs = @(Get-TestDockerfileRun -Path ([IO.Path]::GetFullPath($Path, (Get-RepoRoot))) -Stage $Stage)
    $selected = @($runs | Where-Object { $_.Contains($ScriptLeaf) })
    Assert-Equal 1 $selected.Count "one build RUN containing $ScriptLeaf"
    [pscustomobject]@{ All = $runs; Command = $selected[0] }
}

function Assert-TestDockerfileBuildMounts {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ScriptLeaf,
        [Parameter(Mandatory)][object[]]$Mount, [Parameter(Mandatory)][string[]]$ArgumentText)
    $build = Get-TestDockerfileBuildRun -Path $Path -ScriptLeaf $ScriptLeaf
    foreach ($item in $Mount) {
        Assert-True $build.Command.Contains($item.Text) "required build mount $($item.Text)"
        Assert-Equal 1 @($build.All | Where-Object { $_.Contains($item.Exclusive) }).Count "exclusive build mount $($item.Exclusive)"
    }
    foreach ($item in $ArgumentText) { Assert-True $build.Command.Contains($item) "required build argument $item" }
}

Export-ModuleMember -Function ConvertTo-TestDockerLogicalText, Get-TestDockerLogicalText, ConvertTo-TestDockerLogicalLine, Get-TestDockerLogicalLine, Get-TestDockerfileRun, Get-TestDockerfileBuildRun, Assert-TestDockerfileBuildMounts
