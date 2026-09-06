#requires -Version 7.0
# ARCHIVED 2026-08-21 (#127 extraction; question SETTLED — scoop's LLVM never
# ships llvm-config.exe, 0 hits, which is why Build-TvmFromSource.ps1 builds
# a minimal pinned LLVM from source, #47). Original: does the toolchain image
# ship llvm-config.exe? (verify5 tvm-stage failure 2026-08-17.) Formerly
# Dockerfile.llvm-config-probe with the body inline (WCOW re-quoting split a
# double-quoted $(...) string mid-way on the first attempt). Run:
#   Invoke-DiagnosticProbe.ps1 -ProbeScript archive/Test-LlvmConfig.ps1 -BaseImage local/kataglyphis:bk-windows-toolchain
[CmdletBinding()]
param([string]$Nonce = '0')
$ErrorActionPreference = 'Stop'
Write-Host "nonce=$Nonce"
$cmd = Get-Command llvm-config.exe -ErrorAction SilentlyContinue
if ($cmd) { Write-Host ('[ OK ] llvm-config on PATH: ' + $cmd.Source) }
else { Write-Host '[FAIL] llvm-config.exe NOT on PATH' }
$bin = 'C:\Users\ContainerAdministrator\scoop\apps\llvm\current\bin'
Write-Host 'bin dir inventory (llvm-*.exe):'
Get-ChildItem $bin -Filter 'llvm-*.exe' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  ' + $_.Name) }
$hits = @(Get-ChildItem 'C:\Users\ContainerAdministrator\scoop\apps\llvm' -Recurse -Filter 'llvm-config.exe' -ErrorAction SilentlyContinue)
Write-Host ('llvm-config.exe anywhere under scoop\apps\llvm: ' + $hits.Count + ' hit(s)')
$hits | ForEach-Object { Write-Host ('  ' + $_.FullName) }
Write-Host 'probe complete'
