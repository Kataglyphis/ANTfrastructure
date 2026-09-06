#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    #73: does clang-cl turn `return _udiv128(...)` into SELF-recursion? All
    225 -Winfinite-recursion warnings in the chain are cutlass's udiv128
    wrapper (uint128.h:96); neither cutlass v4.4.2 nor ORT's patch explains
    a self-call, so measure the compiler: compile the minimal shape, read
    the warning, disassemble the object.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-rec',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== udiv128 recursion probe nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
@'
#include <cstdint>
#include <intrin.h>
uint64_t udiv128(uint64_t h, uint64_t l, uint64_t d, uint64_t* r) {
  return _udiv128(h, l, d, r);
}
uint64_t caller(uint64_t h, uint64_t l, uint64_t d, uint64_t* r) {
  return udiv128(h, l, d, r);
}
'@ | Set-Content -Path 't.cpp' -Encoding ascii

Write-Host '--- compile (warnings on) ---'
# '-Fot.obj' MUST be quoted: PS splits a bare -X token at the first dot
# when passing to natives (yesterday's memory note, stepped in anyway).
& clang-cl -nologo -W3 -c '-Fot.obj' t.cpp 2>&1 | ForEach-Object { "cc| $_" }
Write-Host ('compile exit: ' + $LASTEXITCODE)

Write-Host '--- clang version ---'
& clang-cl --version 2>&1 | Select-Object -First 1 | ForEach-Object { "ver| $_" }

Write-Host '--- disassembly (does udiv128 CALL itself?) ---'
$dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1).FullName
& $dumpbin /disasm t.obj 2>&1 | Select-Object -First 60 | ForEach-Object { "dis| $_" }
Write-Host 'probe complete'
