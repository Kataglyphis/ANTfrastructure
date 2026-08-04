# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Guards the classic/BK twin-stage contract in Dockerfile.media-builder:
# each media-<branch> stage has a media-<branch>-bk ENV twin that must declare
# the SAME version-ARG set, and every ARG in a -bk twin must be mirrored into
# ENV (the BK lane's build scripts read versions from the environment — an ARG
# added to only one twin leaves the other lane silently building on the base
# image's baked Machine env). sync_versions.py polices the VALUES line-by-line
# but not the SETS — that's this suite's job.

#requires -Version 7.0

BeforeAll {
    $script:dfPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Dockerfile.media-builder'

    # Minimal stage-aware Dockerfile scan: stage name -> @{ Args = [set]; EnvMirrored = [set] }
    $script:stages = @{}
    $current = $null
    $inEnvContinuation = $false
    foreach ($line in (Get-Content $script:dfPath)) {
        if ($line -match '^\s*FROM\s+\S+\s+AS\s+(\S+)') {
            $current = $Matches[1]
            $script:stages[$current] = @{ Args = @(); EnvMirrored = @() }
            $inEnvContinuation = $false
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)') {
            $script:stages[$current].Args += $Matches[1]
            $inEnvContinuation = $false
        }
        # ENV mirror lines: NAME="${NAME}" — first line starts with ENV, backtick
        # continuations carry further NAME="${NAME}" pairs.
        if ($line -match '^\s*ENV\s') { $inEnvContinuation = $true }
        if ($inEnvContinuation) {
            foreach ($m in [regex]::Matches($line, '([A-Za-z_][A-Za-z0-9_]*)="\$\{\1\}"')) {
                $script:stages[$current].EnvMirrored += $m.Groups[1].Value
            }
            if ($line -notmatch '`\s*$' -and $line -notmatch '^\s*ENV\s.*`\s*$') {
                if ($line -notmatch '^\s*ENV\s') { $inEnvContinuation = $false }
                elseif ($line -notmatch '`\s*$') { $inEnvContinuation = $false }
            }
        }
    }

    $script:twinPairs = @(
        @{ Classic = 'media-core';   Bk = 'media-core-bk' }
        @{ Classic = 'media-litert'; Bk = 'media-litert-bk' }
        @{ Classic = 'media-tvm';    Bk = 'media-tvm-bk' }
    )
}

Describe 'Dockerfile.media-builder twin-stage parity' {
    It 'parses all six twin stages' {
        foreach ($p in $script:twinPairs) {
            $script:stages.Keys | Should -Contain $p.Classic
            $script:stages.Keys | Should -Contain $p.Bk
        }
    }

    It 'declares identical ARG sets in each classic/-bk twin pair' {
        foreach ($p in $script:twinPairs) {
            $classicArgs = @($script:stages[$p.Classic].Args) | Sort-Object -Unique
            $bkArgs      = @($script:stages[$p.Bk].Args) | Sort-Object -Unique
            $onlyClassic = @($classicArgs | Where-Object { $_ -notin $bkArgs })
            $onlyBk      = @($bkArgs | Where-Object { $_ -notin $classicArgs })
            $onlyClassic | Should -BeNullOrEmpty -Because "$($p.Bk) is missing ARG(s) that $($p.Classic) declares: $($onlyClassic -join ', ')"
            $onlyBk | Should -BeNullOrEmpty -Because "$($p.Classic) is missing ARG(s) that $($p.Bk) declares: $($onlyBk -join ', ')"
        }
    }

    It 'mirrors every -bk ARG into ENV (NAME="${NAME}")' {
        foreach ($p in $script:twinPairs) {
            $bk = $script:stages[$p.Bk]
            $unmirrored = @($bk.Args | Sort-Object -Unique | Where-Object { $_ -notin $bk.EnvMirrored })
            $unmirrored | Should -BeNullOrEmpty -Because "$($p.Bk) ARG(s) without ENV mirror: $($unmirrored -join ', ')"
        }
    }

    It 'declares a non-empty ARG set per twin (parser self-check)' {
        foreach ($p in $script:twinPairs) {
            @($script:stages[$p.Classic].Args).Count | Should -BeGreaterThan 0
            @($script:stages[$p.Bk].Args).Count | Should -BeGreaterThan 0
        }
    }
}
