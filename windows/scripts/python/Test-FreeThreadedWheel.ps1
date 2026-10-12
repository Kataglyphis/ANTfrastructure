# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    The device half of a cross lane's cp3XYt wheel: proves every wheel beside it with the free-threaded interpreter packed beside it.
.DESCRIPTION
    New-CrossFreeThreadedWheel.ps1 packs this script, the wheel, the target's free-threaded tree as python\, free-threaded-wheel.py and
    WindowsPythonWheel.Common.psm1 into one directory; container-ci-windows.yml's arm64 run job starts it there.
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking
$python = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'python') -Filter 'python3.*t.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw "no free-threaded interpreter (python3.*t.exe) in $(Join-Path $PSScriptRoot 'python')" }
Invoke-TwinDeviceProof -Interpreter $python.FullName -Store $PSScriptRoot -Helper (Join-Path $PSScriptRoot 'free-threaded-wheel.py')
Write-Host "free-threaded wheel(s) in $PSScriptRoot proved on $env:PROCESSOR_ARCHITECTURE with $($python.Name)"
