#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The media-core solve order lives in the Dockerfile and the driver; drift silently builds on a stale ancestor.

Describe 'BK media-core solve-order parity (Dockerfile FROM graph vs driver)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $dfText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.media-builder')
    $drvText = Get-Content -Raw (Join-Path $repoWin 'Build-Buildkit.ps1')

    # Dockerfile side: stage -> parent ARG key, from `FROM ${MEDIA_CORE_X_IMAGE} AS stage`
    $dfMap = @{}
    foreach ($m in [regex]::Matches($dfText, '(?m)^FROM \$\{(MEDIA_CORE_[A-Z]+_IMAGE)\} AS ([\w-]+)')) {
        $dfMap[$m.Groups[2].Value] = $m.Groups[1].Value
    }

    # Driver side: $xArg = @{ MEDIA_CORE_Y_IMAGE = ... } definitions ...
    $argVarMap = @{}
    foreach ($m in [regex]::Matches($drvText, '\$(\w+Arg)\s*=\s*@\{\s*(MEDIA_CORE_[A-Z]+_IMAGE)\s*=')) {
        $argVarMap[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    # ... and which Invoke-BkStage -Target gets which $xArg appended.
    $drvMap = @{}
    $drvOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($drvText, "Invoke-BkStage[^\r\n]*-Target '([\w-]+)'[^\r\n]*")) {
        $target = $m.Groups[1].Value
        if ($target -notmatch '^media-core-built') { continue }
        $drvOrder.Add($target)
        $argRef = [regex]::Match($m.Value, '\+\s*\$(\w+Arg)')
        if ($argRef.Success) { $drvMap[$target] = $argVarMap[$argRef.Groups[1].Value] }
    }

    It 'discovers the chain in both files (scanner-rot guard)' {
        Assert-True ($dfMap.Count -ge 3) "Dockerfile FROM graph: expected >=3 MEDIA_CORE_*_IMAGE stages, found $($dfMap.Count)"
        Assert-True ($drvOrder.Count -ge 4) "driver: expected >=4 media-core-built* Invoke-BkStage calls, found $($drvOrder.Count)"
        Assert-True ($argVarMap.Count -ge 3) "driver: expected >=3 `$xArg = @{ MEDIA_CORE_*_IMAGE } definitions, found $($argVarMap.Count)"
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
            $j = $text -replace ('`' + "`r?`n"), ' '
            $inStage = $false; $mods = @()
            foreach ($line in ($j -split "`n")) {
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
