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

    # branch -> the shared env stage and the BK stage that must descend from it.
    # media-core is NOT in this list since #49 (2026-08-19): its BK lane is
    # partitioned per component and carries per-stage version blocks - the
    # dedicated Describe below asserts that contract instead.
    #
    # The `Classic = 'media-litert' / 'media-tvm'` column was dropped on
    # 2026-08-26 (#134) with the docker-classic lane and its COPY-only stages.
    # The env stages themselves stay: they are still the shared ancestors, now
    # of one descendant each, and they are still where a version bump must land
    # so it re-keys the branch exactly once.
    $script:branches = @(
        @{ Env = 'media-litert-env'; Bk = 'media-litert-built' }
        @{ Env = 'media-tvm-env';    Bk = 'media-tvm-built' }
    )

    # #49 contract: each BK media-core stage declares EXACTLY its component's
    # version keys, so a single-component bump re-runs that stage + downstream
    # instead of the full ~75-min ONNX build.
    $script:coreComponentKeys = @{
        # QNN_SDK_ZIP_SHA256 (#121): the hand-staged QAIRT zip's integrity pin, read
        # by build-onnx-from-source.ps1 only -- so it keys the onnx stage alone.
        'media-core-built-onnx'   = @('ONNXRUNTIME_VERSION', 'CUDA_ARCHITECTURES', 'PYTHON_VERSION', 'QNN_SDK_ZIP_SHA256')
        'media-core-built-ffmpeg' = @('FFMPEG_VERSION', 'PYAV_VERSION', 'NV_CODEC_HEADERS_REF')
        'media-core-built-opencv' = @('OPENCV_SOURCE_VERSION', 'OPENCV_VERSION')
        'media-core-built'        = @('ONNXRUNTIME_GENAI_VERSION')
    }
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

    It 'descends the branch build from the shared env stage' {
        foreach ($b in $script:branches) {
            $script:stages.Keys | Should -Contain $b.Bk
            # The BK head stage inherits directly; later partitions chain from
            # handoff images (${MEDIA_CORE_*_IMAGE}) built off that same head.
            $script:stages[$b.Bk].Parent | Should -Be $b.Env `
                -Because 'the branch build must inherit the shared version env, not restate it'
        }
    }

    It 'never re-declares a shared version ARG in a descendant stage' {
        foreach ($b in $script:branches) {
            $shared = @($script:stages[$b.Env].Args | Sort-Object -Unique)
            $redeclared = @($script:stages[$b.Bk].Args | Where-Object { $_ -in $shared })
            $redeclared | Should -BeNullOrEmpty `
                -Because "$($b.Bk) re-declaring $($redeclared -join ', ') shadows the shared env stage and re-keys the branch twice"
        }
    }
}

Describe 'Dockerfile.media-builder media-core per-component contract (#49)' {
    # ('keeps the classic lane on the shared media-core-env ancestor' was removed
    # on 2026-08-26 with the docker-classic lane: media-core and media-core-env
    # are both gone from Dockerfile.media-builder — #134.)

    It 'starts the BK partition from common, not the shared env stage' {
        $script:stages['media-core-built-onnx'].Parent | Should -Be 'common' `
            -Because 'descending from media-core-env would make every component bump re-pay the ONNX stage (#49)'
    }

    It 'declares and ENV-mirrors exactly its component keys per BK stage' {
        foreach ($name in $script:coreComponentKeys.Keys) {
            $script:stages.Keys | Should -Contain $name
            $keys = $script:coreComponentKeys[$name]
            foreach ($k in $keys) {
                $script:stages[$name].Args | Should -Contain $k -Because "$name consumes $k"
                $script:stages[$name].EnvMirrored | Should -Contain $k `
                    -Because "an unmirrored ARG silently falls back to the base image's baked env"
            }
            # No foreign component keys: a key creeping back into an earlier
            # stage re-couples the cache chain the split exists to cut.
            $foreign = @($script:coreComponentKeys.Keys | Where-Object { $_ -ne $name } |
                    ForEach-Object { $script:coreComponentKeys[$_] }) | Where-Object { $_ -in $script:stages[$name].Args }
            @($foreign) | Should -BeNullOrEmpty `
                -Because "$name declaring $($foreign -join ', ') re-couples another component's cache key"
        }
    }

    It 'covers the driver''s whole media-core version-arg set with the per-stage union (no drift)' {
        # WHAT THIS REPLACED, AND WHY IT IS NOT THE SAME TEST (#134, 2026-08-26).
        # This used to compare the per-stage union against media-core-env's ARG
        # block. That stage was the classic lane's single-stage ancestor and was
        # deleted with the lane — but the property it proved is load-bearing and
        # had no other gate: a key the DRIVER forwards that NO stage declares is
        # silently dropped, and the branch's build scripts fall back to the value
        # baked into the base image, possibly months old
        # (WindowsBuildDriver.Common.psm1, Get-MediaBranchVersionArg: "COMPLETENESS IS LOAD-BEARING").
        # The union is therefore now checked against the driver's own map. That
        # is a cross-FILE check between the two things that must agree, where the
        # old one compared two blocks of the same Dockerfile.
        #
        # The table below is the versions.env-side key set the media-core map
        # reads (note the deliberate OPENCV_VERSION -> OPENCV_SOURCE_VERSION
        # rename on the way out). If the driver grows a key that is not here,
        # Get-VersionTableValue throws "versions.env has no key X" and this test
        # fails — which is the correct outcome: a new key needs a home in
        # $script:coreComponentKeys and in a stage.
        $table = @{}
        foreach ($k in @('ONNXRUNTIME_VERSION', 'ONNXRUNTIME_GENAI_VERSION', 'OPENCV_VERSION',
                         'FFMPEG_VERSION', 'PYAV_VERSION', 'QNN_SDK_ZIP_SHA256',
                         'NV_CODEC_HEADERS_REF', 'CUDA_ARCHITECTURES', 'PYTHON_VERSION')) { $table[$k] = 'fixture' }
        $driverKeys = @((Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $table).Keys) | Sort-Object -Unique
        $union      = @($script:coreComponentKeys.Values | ForEach-Object { $_ }) | Sort-Object -Unique
        ($union -join ',') | Should -Be ($driverKeys -join ',') `
            -Because 'a version the driver forwards but no stage declares falls back to the base image''s baked value, silently'
    }
}
