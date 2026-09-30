#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Pins Build-Buildkit.ps1's wiring of the per-run resource CSV, which the BK driver once lacked.

Describe 'BK driver resource sampler wiring (#134)' {

    BeforeAll {
        $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:drv = Get-Content -Raw (Join-Path $repoWin 'Build-Buildkit.ps1')
    }

    It 'exposes a -NoResourceLog switch' {
        Assert-Match '\[switch\]\$NoResourceLog' $script:drv
    }

    It 'declares the phase file and Set-BuildPhase' {
        Assert-Match 'script:PhaseFile' $script:drv
        Assert-Match 'function Set-BuildPhase' $script:drv
    }

    It 'starts the sampler after preflight gates pass' {
        Assert-Match 'Build-ResourceSampler\.ps1' $script:drv
        Assert-Match '\$script:SamplerProc = Start-Process' $script:drv
    }

    It 'writes phase transitions in Invoke-BkStage' {
        Assert-Match '(?s)function Invoke-BkStage.*Set-BuildPhase \$Label' $script:drv
    }

    It 'stops the sampler and summarizes in the finally block' {
        Assert-Match '(?s)finally.*Stop-Process.*SamplerProc' $script:drv
        Assert-Match '(?s)finally.*-Summarize.*ResourceCsv' $script:drv
    }

    It 'forwards -NoResourceLog to concurrent child drivers (parent covers the machine)' {
        Assert-Match "(?s)ConcurrentAux.*auxArgs \+= '-NoResourceLog'" $script:drv
    }
}
