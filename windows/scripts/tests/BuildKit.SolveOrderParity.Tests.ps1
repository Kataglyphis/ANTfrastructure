#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

# The media-core solve order lives in the Dockerfile and the driver; drift silently builds on a stale ancestor.

function Get-MediaCoreDriverArgumentMap {
    param([Management.Automation.Language.Ast]$DriverAst)
    $driverArguments = @{}
    foreach ($assignment in $driverAst.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst] -or
            $assignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
            $assignment.Right.Expression -isnot [Management.Automation.Language.HashtableAst]) { continue }
        foreach ($entry in $assignment.Right.Expression.KeyValuePairs) {
            if ($entry.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $entry.Item1.Value -match '^MEDIA_CORE_[A-Z]+_IMAGE$') {
                $driverArguments[$assignment.Left.VariablePath.UserPath] = $entry.Item1.Value
            }
        }
    }
    return $driverArguments
}

function Get-MediaCoreDriverSolveGraph {
    param([Management.Automation.Language.Ast]$DriverAst, [hashtable]$DriverArguments)
    $driverParents = @{}
    $driverOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($call in (Get-TestAstCommands -Ast $driverAst -Name 'Invoke-BkStage' | Sort-Object { $_.Extent.StartOffset })) {
        $arguments = Get-TestCommandArguments -Command $call -AsAst
        if (-not $arguments.ContainsKey('Target') -or
            $arguments.Target -isnot [Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $target = $arguments.Target.Value
        if ($target -notmatch '^media-core-built') { continue }
        $driverOrder.Add($target)
        $parents = @()
        if ($arguments.ContainsKey('BuildArgs')) {
            $parents = @($arguments.BuildArgs.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
                    Where-Object { $_.Parent -is [Management.Automation.Language.BinaryExpressionAst] -and
                        $_.Parent.Operator -eq [Management.Automation.Language.TokenKind]::Plus } |
                    ForEach-Object { $_.VariablePath.UserPath } | Where-Object { $driverArguments.ContainsKey($_) } | Select-Object -Unique)
        }
        if ($parents.Count -gt 1) { throw "$target passes multiple media-core parent arguments: $($parents -join ', ')" }
        if ($parents.Count -eq 1) { $driverParents[$target] = $driverArguments[$parents[0]] }
    }
    return [pscustomobject]@{ Parents = $driverParents; Order = $driverOrder }
}

function Get-MediaCoreSolveGraph {
    param([string]$DockerfilePath, [string]$DriverPath)
    $dockerfileText = [IO.File]::ReadAllText($DockerfilePath)
    $driverAst = Get-TestScriptAst -ScriptPath $DriverPath
    $dockerfileParents = @{}
    foreach ($stage in (Get-TestDockerfileStages -Text $dockerfileText -StrictFromHeader).Stages) {
        if ($stage.From -match '^\$\{(MEDIA_CORE_[A-Z]+_IMAGE)\}$') { $dockerfileParents[$stage.Name] = $Matches[1] }
    }
    $driverArguments = Get-MediaCoreDriverArgumentMap -DriverAst $driverAst
    $driverSolves = Get-MediaCoreDriverSolveGraph -DriverAst $driverAst -DriverArguments $driverArguments
    return [pscustomobject]@{
        DockerfileText = $dockerfileText
        DockerfileParents = $dockerfileParents
        DriverArguments = $driverArguments
        DriverParents = $driverSolves.Parents
        DriverOrder = $driverSolves.Order
    }
}

Describe 'BK media-core solve-order parity (Dockerfile FROM graph vs driver)' {

    $repoWin = Join-Path (Get-RepoRoot) 'windows'
    $graph = Get-MediaCoreSolveGraph -DockerfilePath (Join-Path $repoWin 'Dockerfile.media-builder') -DriverPath 'windows/Build-Buildkit.ps1'
    $dfText = $graph.DockerfileText
    $dfMap = $graph.DockerfileParents
    $argVarMap = $graph.DriverArguments
    $drvMap = $graph.DriverParents
    $drvOrder = $graph.DriverOrder

    It 'discovers the chain in both files (scanner-rot guard)' {
        Assert-True ($dfMap.Count -ge 3) "Dockerfile FROM graph: expected >=3 MEDIA_CORE_*_IMAGE stages, found $($dfMap.Count)"
        Assert-True ($drvOrder.Count -ge 4) "driver: expected >=4 media-core-built* Invoke-BkStage calls, found $($drvOrder.Count)"
        Assert-True ($argVarMap.Count -ge 3) "driver: expected >=3 `$xArg = @{ MEDIA_CORE_*_IMAGE } definitions, found $($argVarMap.Count)"
    }

    It 'reads multiline stage calls and ignores a commented decoy, then sees a wrong parent (mutation)' {
        Invoke-InTestDir { param($dir)
            $dockerfile = @'
FROM scratch AS media-core-built-onnx
FROM ${MEDIA_CORE_ONNX_IMAGE} AS media-core-built-ffmpeg
FROM ${MEDIA_CORE_FFMPEG_IMAGE} AS media-core-built-opencv
'@
            $driver = @'
$onnxArg = @{
    MEDIA_CORE_ONNX_IMAGE = 'onnx'
}
$ffmpegArg = @{ MEDIA_CORE_FFMPEG_IMAGE = 'ffmpeg' }
# Invoke-BkStage -Target 'media-core-built-decoy' -BuildArgs ($branchBuildArgs + $onnxArg)
Invoke-BkStage -Target 'media-core-built-onnx' -BuildArgs $branchBuildArgs
Invoke-BkStage `
    -Target 'media-core-built-ffmpeg' `
    -BuildArgs ($branchBuildArgs + $onnxArg + @{ HINT = $ffmpegArg })
Invoke-BkStage -Target 'media-core-built-opencv' -BuildArgs ($branchBuildArgs + $ffmpegArg)
'@
            Write-TestFileTree -Root $dir -Files @{ 'Dockerfile' = $dockerfile; 'driver.ps1' = $driver }
            $graph = Get-MediaCoreSolveGraph -DockerfilePath (Join-Path $dir 'Dockerfile') -DriverPath (Join-Path $dir 'driver.ps1')
            Assert-Equal 'media-core-built-onnx|media-core-built-ffmpeg|media-core-built-opencv' ($graph.DriverOrder -join '|') 'source order without the decoy'
            Assert-Equal 2 $graph.DriverArguments.Count 'only live media-core parent assignments'
            Assert-Equal $graph.DockerfileParents['media-core-built-ffmpeg'] $graph.DriverParents['media-core-built-ffmpeg'] 'the multiline solve keeps its parent'
            Assert-Equal $graph.DockerfileParents['media-core-built-opencv'] $graph.DriverParents['media-core-built-opencv'] 'the final solve keeps its parent'
            $mutantPath = Join-Path $dir 'driver-mutant.ps1'
            [IO.File]::WriteAllText($mutantPath, $driver.Replace('$branchBuildArgs + $ffmpegArg', '$branchBuildArgs + $onnxArg'))
            $mutant = Get-MediaCoreSolveGraph -DockerfilePath (Join-Path $dir 'Dockerfile') -DriverPath $mutantPath
            Assert-False ($mutant.DockerfileParents['media-core-built-opencv'] -eq $mutant.DriverParents['media-core-built-opencv']) 'a stale ancestor is visible to the parity gate'
        }
    }

    It 'driver hands every chained stage the SAME parent the Dockerfile declares' {
        $bad = @()
        foreach ($stage in $dfMap.Keys) {
            if (-not $drvMap.ContainsKey($stage)) { $bad += "driver never passes a MEDIA_CORE_*_IMAGE arg to '$stage'"; continue }
            if ($drvMap[$stage] -ne $dfMap[$stage]) {
                $bad += "'$stage': Dockerfile parent $($dfMap[$stage]) vs driver arg $($drvMap[$stage])"
            }
        }
        Assert-True ($bad.Count -eq 0) ("solve-order drift (silent stale-ancestor builds):`n  " + ($bad -join "`n  "))
    }

    It 'the two production sccache ENV blocks declare identical key sets and ARG defaults' {
        # media-builder `common` and media-merge-builder `built` share no FROM, so they are hand-mirrored twins.
        $mergeText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.media-merge-builder')
        $getKeys = { param($text)
            [regex]::Matches($text, '(?m)^\s*(SCCACHE_[A-Z_]+)=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        }
        $a = & $getKeys $dfText
        $b = & $getKeys $mergeText
        Assert-Equal ($a -join ',') ($b -join ',') 'sccache ENV key sets drifted between the two files'
        # The intersection only: media-builder declares onnx-stage-only knobs with no merge-side counterpart.
        $getArgs = { param($text)
            $t = @{}
            [regex]::Matches($text, '(?m)^ARG (SCCACHE_[A-Z_]+)=("[^"]*")') | ForEach-Object { $t[$_.Groups[1].Value] = $_.Groups[2].Value }
            $t
        }
        $argsA = & $getArgs $dfText
        $argsB = & $getArgs $mergeText
        $drift = @()
        foreach ($k in ($argsA.Keys | Where-Object { $argsB.ContainsKey($_) })) {
            if ($argsA[$k] -ne $argsB[$k]) { $drift += "$k : $($argsA[$k]) vs $($argsB[$k])" }
        }
        Assert-True ($drift.Count -eq 0) ('sccache ARG defaults drifted on shared names: ' + ($drift -join '; '))
    }

    It 'merge-builder buildmods is a superset of media-builder buildmods (B4)' {
        # No cross-Dockerfile stage sharing exists, so the 5-module core stays in step by hand.
        $mergeText2 = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.media-merge-builder')
        $getMods = { param($text)
            $inStage = $false; $mods = @()
            foreach ($line in (ConvertTo-TestDockerLogicalLine -Text $text)) {
                if ($line -match '^FROM \S+ AS buildmods') { $inStage = $true; continue }
                if ($inStage -and $line -match '^FROM ') { break }
                if ($inStage) {
                    $mods += ([regex]::Matches($line, 'modules.(Windows[\w.]+\.psm1)') | ForEach-Object { $_.Groups[1].Value })
                }
            }
            $mods | Sort-Object -Unique
        }
        $a = & $getMods $dfText
        $b = & $getMods $mergeText2
        Assert-True ($a.Count -ge 5) "media-builder buildmods parse found only $($a.Count) modules — stage layout changed?"
        $missing = @($a | Where-Object { $b -notcontains $_ })
        Assert-True ($missing.Count -eq 0) ('modules in media-builder buildmods but MISSING from merge-builder: ' + ($missing -join ', '))
    }

    It 'driver builds every parent BEFORE the stage that consumes it' {
        $bad = @()
        # MEDIA_CORE_X_IMAGE is produced by the driver call targeting media-core-built-x
        foreach ($stage in $dfMap.Keys) {
            $parentStage = 'media-core-built-' + ($dfMap[$stage] -replace '^MEDIA_CORE_|_IMAGE$', '').ToLowerInvariant()
            $pi = $drvOrder.IndexOf($parentStage)
            $si = $drvOrder.IndexOf($stage)
            if ($pi -lt 0 -or $si -lt 0) { continue } # covered by the map assertion above
            if ($pi -gt $si) { $bad += "'$parentStage' (idx $pi) is built after its consumer '$stage' (idx $si)" }
        }
        Assert-True ($bad.Count -eq 0) ("driver order violates the FROM graph:`n  " + ($bad -join "`n  "))
    }
}
