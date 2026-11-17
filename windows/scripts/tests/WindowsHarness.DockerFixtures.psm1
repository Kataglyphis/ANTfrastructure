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

function Get-TestDockerfileStageLines {
    param([Parameter(Mandatory)][string]$Path, [string]$Stage = 'built')
    $docker = Get-TestDockerfileStagesFromPath -Path $Path -JoinContinuations -IgnoreComments -TrimLines -StrictFromHeader
    if (-not $docker.ByName.ContainsKey($Stage)) { throw "Dockerfile stage '$Stage' is missing: $Path" }
    $docker.ByName[$Stage].Lines
}

function Get-TestDockerfileRun {
    param([Parameter(Mandatory)][string]$Path, [string]$Stage = 'built')
    Get-TestDockerfileStageLines @PSBoundParameters | Where-Object { $_ -match '^RUN ' }
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

# Pin defaults belong to the compiling stage; auxiliary module views have independent ARGs.
function Get-TestDockerfileArgDefault {
    param([Parameter(Mandatory)][string]$Path, [string]$Stage = 'built')
    $table = [ordered]@{}
    Get-TestDockerfileStageLines -Path $Path -Stage $Stage |
        Select-String -Pattern '^ARG\s+([A-Z][A-Z0-9_]*)=(\S*)' |
        ForEach-Object { $g = $_.Matches[0].Groups; $table[$g[1].Value] = $g[2].Value.Trim('"') }
    return $table
}


function Assert-TestDockerfileModuleClosure {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string[]]$ScriptPath, [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$MinimumNeeded, [Parameter(Mandatory)][int]$ExpectedMountCount)
    $stages = Get-TestDockerfileStageFacts -Path $Path
    Assert-True ($stages.ContainsKey($Stage)) "the named module-copy stage $Stage must exist"
    $mounted = @($stages[$Stage].MountedModules)
    $needed = @{}
    foreach ($source in $ScriptPath) {
        foreach ($m in [regex]::Matches((Get-Content -Raw (Join-Path $Root $source)), 'modules\\([\w.]+)\.psm1')) { $needed[$m.Groups[1].Value] = $source }
    }
    foreach ($m in $mounted) {
        foreach ($sib in [regex]::Matches((Get-Content -Raw (Join-Path $Root "windows\scripts\modules\$m.psm1")), "PSScriptRoot\s+'([\w.]+)\.psm1'")) { $needed[$sib.Groups[1].Value] = "$m.psm1" }
    }
    Assert-True ($needed.Count -ge $MinimumNeeded) "the scan found $($needed.Count) needed module(s)"
    foreach ($m in $needed.Keys) { Assert-True ($mounted -contains $m) "$m (imported by $($needed[$m])) is not in the $Stage closure" }
    $runs = @(Get-TestDockerfileRun -Path $Path)
    $mount = "from=$Stage,source=/bkmods,target=C:\bkmnt\modules"
    Assert-Equal $ExpectedMountCount @($runs | Where-Object { $_.Contains($mount) }).Count 'every compiling RUN mounts the closure'
}

Export-ModuleMember -Function Get-TestDockerfileArgDefault, Assert-TestDockerfileModuleClosure
