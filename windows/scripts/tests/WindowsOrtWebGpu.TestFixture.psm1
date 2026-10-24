#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Import-Module (Join-Path $PSScriptRoot '../modules/WindowsScripts.Shared.psm1') -ErrorAction Stop

function Get-OrtWebGpuTestPin {
    ConvertFrom-VersionsEnv -Path (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'linux/scripts/01-core/versions.env')
}

function Get-OrtWebGpuTestPython {
    $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { throw 'python is not on PATH: the DEPS probe is Python and must run for real here' }
    return $python.Source
}

Export-ModuleMember -Function Get-OrtWebGpuTestPin, Get-OrtWebGpuTestPython
