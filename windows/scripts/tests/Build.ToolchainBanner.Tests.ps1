#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The hub's sccache build reports its id as semver build metadata; an exact match failed the base's toolchain check.

Describe 'Test-Toolchain.ps1: a pinned tool''s banner' {

    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Toolchain.ps1' -FunctionName 'Test-PinnedBanner')

    It 'accepts the pin and a hub build id''s build-metadata spelling, nothing else (mutation)' {
        Assert-True (Test-PinnedBanner -Banner 'sccache 0.18.0+1bd7432.pr2809' -Expected '0.18.0-1bd7432-pr2809') 'the hub build as sccache reports it'
        Assert-True (Test-PinnedBanner -Banner 'sccache 0.18.0-1bd7432-pr2809' -Expected '0.18.0-1bd7432-pr2809') 'the id as pinned'
        Assert-True (Test-PinnedBanner -Banner '1.13.2' -Expected '1.13.2') 'a plain version'
        Assert-False (Test-PinnedBanner -Banner 'sccache 0.18.0' -Expected '0.18.0-1bd7432-pr2809') 'a release is not the hub build'
        Assert-False (Test-PinnedBanner -Banner 'sccache 0.18.0+9999999.pr2809' -Expected '0.18.0-1bd7432-pr2809') 'another commit'
    }
}
