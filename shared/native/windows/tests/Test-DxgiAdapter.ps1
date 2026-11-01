#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
Import-Module (Join-Path $root 'windows/scripts/modules/WindowsSourceBuild.Common.psm1') -ErrorAction Stop
Enter-VsDevCmdEnvironment -Arch amd64
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$source = Join-Path $PSScriptRoot '..\dxgi_adapter.c'
$test = Join-Path $PSScriptRoot 'dxgi_adapter_test.c'
Push-Location $output
try {
    foreach ($language in @('C', 'CXX')) {
        $mode = if ($language -eq 'C') { '/TC' } else { '/TP' }
        $standard = if ($language -eq 'C') { '/std:c11' } else { '/std:c++17' }
        $exe = Join-Path $output "dxgi-adapter-$language.exe"
        & clang-cl /nologo /W4 /WX $mode $standard $source $test "/Fe$exe" /link dxgi.lib
        if ($LASTEXITCODE -ne 0) { throw "clang-cl $language compilation failed: $LASTEXITCODE" }
        & $exe
        if ($LASTEXITCODE -ne 0) { throw "$language selector tests failed: $LASTEXITCODE" }
        Write-Host "PASS: clang-cl $language DXGI adapter selection"
    }
} finally {
    Pop-Location
}
