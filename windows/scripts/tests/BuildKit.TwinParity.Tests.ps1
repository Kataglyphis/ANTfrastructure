#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Guards the version-env contract in Dockerfile.media-builder.
#
# HISTORY: until 2026-08-07 each classic media-<branch> stage had a
# media-<branch>-bk ENV twin, and this suite existed to catch the two copies
# drifting apart (sync_versions.py policed the VALUES, this suite the SETS).
# The twins are gone: both lanes now descend from a single media-<branch>-env
# ancestor, so drift is structurally impossible rather than policed.
#
# What is still worth asserting is what that refactor must never lose:
#   1. the shared -env stage exists and declares the version ARGs,
#   2. every ARG it declares is mirrored into ENV — the BK lane's build scripts
#      read versions from the ENVIRONMENT, and an unmirrored ARG silently falls
#      back to the base image's baked Machine env (i.e. a stale version),
#   3. BOTH lanes descend from it — the classic builder stage and the BK
#      compile stage — because that shared ancestry IS the anti-drift mechanism,
#   4. nobody re-declares those ARGs in a descendant, which would reintroduce a
#      twin by the back door.


BeforeAll {
    $script:dfPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Dockerfile.media-builder'

    # Minimal stage-aware Dockerfile scan:
    # stage name -> @{ Parent; Args = [set]; EnvMirrored = [set] }
    $script:stages = @{}
    $current = $null
    $inEnvContinuation = $false
    foreach ($line in (Get-Content $script:dfPath)) {
        if ($line -match '^\s*FROM\s+(\S+)\s+AS\s+(\S+)') {
            $current = $Matches[2]
            $script:stages[$current] = @{ Parent = $Matches[1]; Args = @(); EnvMirrored = @() }
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
            if ($line -notmatch '`\s*$') { $inEnvContinuation = $false }
        }
    }

    # branch -> the shared env stage, plus the two lanes that must descend from it.
    $script:branches = @(
        @{ Env = 'media-core-env';   Classic = 'media-core';   Bk = 'media-core-built-onnx' }
        @{ Env = 'media-litert-env'; Classic = 'media-litert'; Bk = 'media-litert-built' }
        @{ Env = 'media-tvm-env';    Classic = 'media-tvm';    Bk = 'media-tvm-built' }
    )
}

Describe 'Dockerfile.media-builder version-env contract' {
    It 'defines a shared version-env stage per media branch' {
        foreach ($b in $script:branches) {
            $script:stages.Keys | Should -Contain $b.Env
            @($script:stages[$b.Env].Args).Count | Should -BeGreaterThan 0 `
                -Because "$($b.Env) is the single place the branch's version ARGs are declared"
        }
    }

    It 'mirrors every version ARG into ENV (NAME="${NAME}")' {
        foreach ($b in $script:branches) {
            $s = $script:stages[$b.Env]
            $unmirrored = @($s.Args | Sort-Object -Unique | Where-Object { $_ -notin $s.EnvMirrored })
            $unmirrored | Should -BeNullOrEmpty `
                -Because "$($b.Env) ARG(s) without ENV mirror silently fall back to the base image's baked env: $($unmirrored -join ', ')"
        }
    }

    It 'descends BOTH lanes from the shared env stage' {
        foreach ($b in $script:branches) {
            $script:stages.Keys | Should -Contain $b.Classic
            $script:stages[$b.Classic].Parent | Should -Be $b.Env `
                -Because 'the classic builder must inherit the shared version env, not restate it'

            $script:stages.Keys | Should -Contain $b.Bk
            # The BK head stage inherits directly; later partitions chain from
            # handoff images (${MEDIA_CORE_*_IMAGE}) built off that same head.
            $script:stages[$b.Bk].Parent | Should -Be $b.Env `
                -Because 'the BK lane must inherit the shared version env, not restate it'
        }
    }

    It 'never re-declares a shared version ARG in a descendant stage' {
        foreach ($b in $script:branches) {
            $shared = @($script:stages[$b.Env].Args | Sort-Object -Unique)
            foreach ($name in @($b.Classic, $b.Bk)) {
                $redeclared = @($script:stages[$name].Args | Where-Object { $_ -in $shared })
                $redeclared | Should -BeNullOrEmpty `
                    -Because "$name re-declaring $($redeclared -join ', ') reintroduces the twin this refactor removed"
            }
        }
    }
}
