#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Every version ARG of a shared -env stage must be mirrored into ENV, or build scripts read the base image's stale value.


BeforeAll {
    $script:dfPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Dockerfile.media-builder'

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
        # The first ENV line starts with ENV; backtick continuations carry more NAME="${NAME}" pairs.
        if ($line -match '^\s*ENV\s') { $inEnvContinuation = $true }
        if ($inEnvContinuation) {
            foreach ($m in [regex]::Matches($line, '([A-Za-z_][A-Za-z0-9_]*)="\$\{\1\}"')) {
                $script:stages[$current].EnvMirrored += $m.Groups[1].Value
            }
            if ($line -notmatch '`\s*$') { $inEnvContinuation = $false }
        }
    }

    # branch -> env stage and its BK descendant; media-core is partitioned per component and has its own Describe.
    $script:branches = @(
        @{ Env = 'media-litert-env'; Bk = 'media-litert-built' }
        @{ Env = 'media-tvm-env';    Bk = 'media-tvm-built' }
    )

    # Each media-core stage declares exactly its component's keys, so one bump never re-runs the ONNX build.
    $script:coreComponentKeys = @{
        'media-core-built-onnx'   = @('ONNXRUNTIME_VERSION', 'CUDA_ARCHITECTURES', 'PYTHON_VERSION')
        'media-core-built-ffmpeg' = @('FFMPEG_VERSION', 'PYAV_VERSION', 'NV_CODEC_HEADERS_REF',
                                      'AMF_HEADERS_VERSION', 'AMF_HEADERS_SHA256',
                                      'DAV1D_VERSION', 'DAV1D_SHA256', 'X264_MESON_BRANCH', 'X264_MESON_COMMIT',
                                      'X265_VERSION', 'X265_SHA256')
        'media-core-built-opencv' = @('OPENCV_SOURCE_VERSION', 'OPENCV_VERSION')
        'media-core-built'        = @('ONNXRUNTIME_GENAI_VERSION')
    }
    # Cross-component on purpose: every stage mounting windows/qnn-sdk extracts the zip and needs the pin.
    $script:sharedCoreKeys = @('QNN_SDK_ZIP_SHA256')
    $script:qnnMountingCoreStages = @('media-core-built-onnx', 'media-core-built')
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
            # The head stage inherits directly; later partitions chain from handoff images built off it.
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
            # A foreign key creeping back into an earlier stage re-couples the cache chain.
            $foreign = @($script:coreComponentKeys.Keys | Where-Object { $_ -ne $name } |
                    ForEach-Object { $script:coreComponentKeys[$_] }) | Where-Object { $_ -in $script:stages[$name].Args }
            @($foreign) | Should -BeNullOrEmpty `
                -Because "$name declaring $($foreign -join ', ') re-couples another component's cache key"
        }
    }

    It 'declares the shared QAIRT pin in EVERY media-core stage that mounts the SDK (#154)' {
        # Without the pin Resolve-QnnSdk only warns and extracts unverified.
        foreach ($name in $script:qnnMountingCoreStages) {
            foreach ($k in $script:sharedCoreKeys) {
                $script:stages[$name].Args | Should -Contain $k `
                    -Because "$name mounts windows/qnn-sdk, so an absent $k means an unverified extract"
                $script:stages[$name].EnvMirrored | Should -Contain $k `
                    -Because "an unmirrored ARG never reaches Resolve-QnnSdk's -ExpectedSha256"
            }
        }
    }

    It 'covers the driver''s whole media-core version-arg set with the per-stage union (no drift)' {
        # A forwarded key no stage declares is silently dropped, so the union is checked against the driver's own map.
        $table = @{}
        foreach ($k in @('ONNXRUNTIME_VERSION', 'ONNXRUNTIME_GENAI_VERSION', 'OPENCV_VERSION',
                         'FFMPEG_VERSION', 'PYAV_VERSION', 'QNN_SDK_ZIP_SHA256',
                         'NV_CODEC_HEADERS_REF', 'AMF_HEADERS_VERSION', 'AMF_HEADERS_SHA256',
                         'DAV1D_VERSION', 'DAV1D_SHA256', 'X264_MESON_BRANCH', 'X264_MESON_COMMIT', 'X265_VERSION', 'X265_SHA256',
                         'CUDA_ARCHITECTURES', 'PYTHON_VERSION')) { $table[$k] = 'fixture' }
        $driverKeys = @((Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $table).Keys) | Sort-Object -Unique
        # Shared keys count toward the union: they live in more than one stage.
        $union      = @(@($script:coreComponentKeys.Values | ForEach-Object { $_ }) + $script:sharedCoreKeys) | Sort-Object -Unique
        ($union -join ',') | Should -Be ($driverKeys -join ',') `
            -Because 'a version the driver forwards but no stage declares falls back to the base image''s baked value, silently'
    }
}
