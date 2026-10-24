#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1') -DisableNameChecking
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsNative.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsOrtWebGpu.TestFixture.psm1') -DisableNameChecking
