#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Does HIP compile in a rocm image against its MSVC <cmath>, and does it still need the overlay?
#   Invoke-DiagnosticProbe.ps1 -ProbeScript Test-HipMsvcCmath.ps1 -BaseImage <rocm tag> -VerdictPattern '\[ OK \]|\[FAIL\]|\[INFO\]'
# The image's path is the default config beside TheRock's clang (windows/scripts/hip). --no-default-config
# drops it: a raw compile that passes means a toolset or TheRock bump made the overlay unnecessary.
# Every compile runs through entrypoint.cmd, as the smoke gate's, so the VS environment is the image's.
param([string]$Nonce = '')

$ErrorActionPreference = 'Continue'
$bin = 'C:\TheRock\build\lib\llvm\bin'
$work = [System.IO.Directory]::CreateTempSubdirectory('hip-cmath-').FullName
$kernel = Join-Path $work 'scale.hip'
[System.IO.File]::WriteAllLines($kernel, [string[]]@('#include <hip/hip_runtime.h>', '__global__ void scale(float* x, float f) { x[threadIdx.x] *= f; }'))
$toolset = @(& cmd /S /C 'C:\temp\scripts\entrypoint.cmd cmd /c echo %VCToolsVersion%' 2>&1)[-1]
Write-Host "nonce $Nonce, MSVC toolset $toolset, TheRock $(Get-Content -Raw -LiteralPath 'C:\TheRock\build\.info\version' -ErrorAction SilentlyContinue)"
foreach ($cfg in Get-ChildItem -LiteralPath $bin -Filter '*.cfg' -File) {
    Write-Host "  $($cfg.Name): $((Get-Content -LiteralPath $cfg.FullName | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' ')"
}

# The error lines of one compile (@() on success), or $null when it failed without naming any.
function Invoke-HipCompile([string]$Command) {
    $object = Join-Path $work ([guid]::NewGuid().ToString('N') + '.o')
    $out = @(& cmd /S /C ('C:\temp\scripts\entrypoint.cmd ' + ($Command -f $object)) 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $object)) { return , @() }
    $errors = @($out -match 'error:')
    if ($errors.Count) { return , $errors } else { return $null }
}

$source = "-c `"$kernel`" -o `"{0}`""
foreach ($case in @(
        @{ Label = 'hipcc'; Command = "hipcc --offload-arch=gfx1201 $source" },
        @{ Label = 'clang -x hip'; Command = "`"$bin\clang.exe`" -x hip --offload-arch=gfx1201 $source" },
        @{ Label = 'amdclang++ -x hip'; Command = "`"$bin\amdclang++.exe`" -x hip --offload-arch=gfx1201 $source" })) {
    $errors = Invoke-HipCompile $case.Command
    if ($null -ne $errors -and $errors.Count -eq 0) { Write-Host "[ OK ] $($case.Label), as the image ships it" }
    else { Write-Host "[FAIL] $($case.Label), as the image ships it: $(@($errors)[0])" }
}
$raw = Invoke-HipCompile "`"$bin\clang.exe`" --no-default-config -x hip --offload-arch=gfx1201 $source"
if ($null -ne $raw -and $raw.Count -eq 0) { Write-Host '[INFO] without the overlay it compiles too: this toolset no longer needs windows/scripts/hip' }
else { Write-Host "[INFO] without the overlay: $(@($raw).Count) error line(s), the overlay is still needed: $(@($raw)[0])" }
exit 0
