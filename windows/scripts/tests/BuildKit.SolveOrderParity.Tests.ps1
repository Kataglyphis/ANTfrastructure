#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The BK media-core solve ORDER is encoded twice — as the FROM graph in
# Dockerfile.media-builder (media-core-built-ffmpeg FROM ${MEDIA_CORE_ONNX_IMAGE}
# etc.) and as the Invoke-BkStage sequence + MEDIA_CORE_*_IMAGE build-args in
# build-buildkit.ps1. The driver's own comment admits "the two encode the same
# order twice". A mismatch does not error: buildctl resolves whatever image the
# build-arg names, so a drifted driver silently builds the chain on a stale
# ancestor (old common-stage ENV included). Order is load-bearing (#94: OpenCV
# must configure AFTER FFmpeg exists or it links its own downloaded prebuilt).
# This suite derives the parent map from BOTH files and asserts they agree.

Describe 'BK media-core solve-order parity (Dockerfile FROM graph vs driver)' {

    $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $dfText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.media-builder')
    $drvText = Get-Content -Raw (Join-Path $repoWin 'build-buildkit.ps1')

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
        # media-builder `common` vs media-merge-builder `built`: not FROM-related
        # (ENV crosses no FROM boundary), so they are hand-mirrored twins — the
        # 2026-08-21 audit caught SCCACHE_DIR hardcoded and SCCACHE_FORCE_LOCAL
        # missing on the merge side. This pins the sets AND the ARG defaults.
        $mergeText = Get-Content -Raw (Join-Path $repoWin 'Dockerfile.media-merge-builder')
        $getKeys = { param($text)
            [regex]::Matches($text, '(?m)^\s*(SCCACHE_[A-Z_]+)=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        }
        $a = & $getKeys $dfText
        $b = & $getKeys $mergeText
        Assert-Equal ($a -join ',') ($b -join ',') 'sccache ENV key sets drifted between the two files'
        # ARG defaults: compare on the INTERSECTION of names — media-builder
        # legitimately declares onnx-stage-only knobs (SCCACHE_CUDA_LAUNCHER,
        # SCCACHE_REPRO_CUDA_LLM) with no merge-side counterpart.
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
