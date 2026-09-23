#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    rocm-image check for MIGraphX and AMD's ORT plugin EP (migraphx-ep.dll); writes one finding per gap.
.DESCRIPTION
    GPU-less: the install trees exist with the licence texts of what they link, every static import of
    the binaries built here resolves beside them, in HIP_PATH\bin or in System32, TheRock's HIP runtime
    set sits beside the EP, HIP is only delay-imported, and migraphx-ep.dll loads and exports
    CreateEpFactories without starting HIP.
    NOT covered: ORT's RegisterExecutionProviderLibrary (its GetSupportedDevices calls
    hipGetDeviceCount, so it needs a GPU), a session, any kernel. Silent when MIGRAPHX_ROOT is unset:
    that image was built with -NoRocmSpikes. docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MigraphxCheckInstallFinding {
    param(
        [Parameter(Mandatory)][string]$MigraphxRoot,
        [Parameter(Mandatory)][string]$EpRoot
    )
    $expected = @(
        'bin\migraphx.dll', 'bin\migraphx_c.dll', 'bin\migraphx_gpu.dll', 'bin\migraphx_device.dll', 'bin\migraphx_onnx.dll',
        'bin\migraphx-hiprtc-driver.exe', 'bin\migraphx-driver.exe', 'lib\cmake\migraphx\migraphx-config.cmake'
    ) | ForEach-Object { Join-Path $MigraphxRoot $_ }
    $expected += @('migraphx-ep.dll', 'migraphx.dll', 'migraphx_c.dll', 'migraphx_gpu.dll', 'migraphx_device.dll',
        'migraphx_onnx.dll', 'migraphx-hiprtc-driver.exe') | ForEach-Object { Join-Path $EpRoot $_ }
    foreach ($path in $expected) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "MIGraphX: $path is missing" }
    }
}

# Both trees ship the licence texts of what they link statically; WindowsMigraphx.Common owns the list.
function Get-MigraphxCheckLicenseFinding {
    param(
        [Parameter(Mandatory)][string]$MigraphxRoot,
        [Parameter(Mandatory)][string]$EpRoot
    )
    foreach ($tree in @(@{ Set = 'MigraphxDeps'; Root = $MigraphxRoot }, @{ Set = 'OrtAmdgpuEp'; Root = $EpRoot })) {
        foreach ($rel in @(Get-MigraphxLicenseGap -InstallDir $tree.Root -Set $tree.Set)) {
            "MIGraphX: licence text $(Join-Path $tree.Root $rel) is missing"
        }
    }
}

# The HIP runtime the EP loads must be TheRock's, byte-for-byte: MIGraphX was built against it.
function Get-MigraphxCheckHipSidecarFinding {
    param(
        [Parameter(Mandatory)][string]$RocmBin,
        [Parameter(Mandatory)][string]$EpRoot
    )
    $set = @(Get-MigraphxHipRuntimeFile -RocmBin $RocmBin)
    if ($set.Count -eq 0) { return "MIGraphX: no amdhip64/amd_comgr/hiprtc DLLs under $RocmBin to compare against" }
    foreach ($dll in $set) {
        $staged = Join-Path $EpRoot $dll.Name
        if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) { "MIGraphX: $($dll.Name) is not beside migraphx-ep.dll"; continue }
        if ((Get-Item -LiteralPath $staged).Length -ne $dll.Length) { "MIGraphX: $staged differs from $($dll.FullName)" }
    }
}

# $ReadImports is Get-PeImportNames' shape (-Path, -IncludeDelayLoad) so a test can fake a PE.
function Get-MigraphxCheckImportFinding {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$SearchDir,
        [Parameter(Mandatory)][scriptblock]$ReadImports,
        [switch]$HipDelayOnly
    )
    $own = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    foreach ($import in @(& $ReadImports -Path $Path)) {
        if ($import -match '^(api|ext)-ms-') { continue }
        if ($HipDelayOnly -and $import -match '^amdhip64') {
            "MIGraphX: $name imports $import statically; it must be /DELAYLOAD so loading the EP does not start HIP"
            continue
        }
        $hit = @(@($own) + $SearchDir | Where-Object { Test-Path -LiteralPath (Join-Path $_ $import) -PathType Leaf })
        if ($hit.Count -eq 0) { "MIGraphX: $name imports $import, found neither beside it nor in $($SearchDir -join ', ')" }
    }
}

# Exit codes of the load probe below: 0 loaded, 3 LoadLibraryEx failed, 4 no export, 5 HIP got loaded.
function ConvertTo-MigraphxLoadFinding {
    param(
        [AllowNull()]$ExitCode,
        [AllowEmptyString()][string]$Output = ''
    )
    $detail = $Output.Trim()
    switch ($ExitCode) {
        $null { return 'MIGraphX: the migraphx-ep.dll load probe hung past its timeout' }
        0 { return }
        3 { return "MIGraphX: migraphx-ep.dll did not load ($detail; Win32 126 = a dependency is missing)" }
        4 { return 'MIGraphX: migraphx-ep.dll loaded but exports no CreateEpFactories' }
        5 { return "MIGraphX: loading migraphx-ep.dll started the HIP runtime ($detail); ORT's provider probe would too" }
        default { return "MIGraphX: the load probe exited $ExitCode ($detail)" }
    }
}

# LoadLibraryEx in a child pwsh: a crash or a stuck loader must not take the check runner with it.
function Invoke-MigraphxLoadProbe {
    param(
        [Parameter(Mandatory)][string]$Dll,
        [int]$TimeoutSeconds = 120
    )
    $probe = @'
Add-Type -Namespace MgxProbe -Name K -MemberDefinition @"
[DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr LoadLibraryExW(string p, IntPtr f, uint flags);
[DllImport("kernel32", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
"@
$h = [MgxProbe.K]::LoadLibraryExW($env:MGX_PROBE_DLL, [IntPtr]::Zero, 8)
if ($h -eq [IntPtr]::Zero) { "Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 3 }
if ([MgxProbe.K]::GetProcAddress($h, 'CreateEpFactories') -eq [IntPtr]::Zero) { exit 4 }
$hip = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -like 'amdhip64*' })
if ($hip.Count -gt 0) { $hip[0].FileName; exit 5 }
exit 0
'@
    $log = Join-Path ([System.IO.Path]::GetTempPath()) "migraphx-load-probe-$PID.txt"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
    $env:MGX_PROBE_DLL = $Dll
    try {
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -PassThru -RedirectStandardOutput $log `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        $null = $child.Handle   # without a held handle Start-Process's ExitCode reads $null
        $done = $child.WaitForExit($TimeoutSeconds * 1000)
        if (-not $done) { $child.Kill($true) }
        $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
        return [pscustomobject]@{ ExitCode = $(if ($done) { $child.ExitCode } else { $null }); Output = "$text" }
    } finally {
        Remove-Item Env:MGX_PROBE_DLL -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}

if (-not $env:MIGRAPHX_ROOT) {
    Write-Host '  [SKIP] MIGRAPHX_ROOT unset: this image carries no MIGraphX (-NoRocmSpikes)'
    return
}
$epRoot = if ($env:ORT_AMDGPU_EP_ROOT) { $env:ORT_AMDGPU_EP_ROOT } else { 'C:\runtime\lib\onnxruntime-ep-amdgpu' }
# The repo/gate layout keeps modules two levels up, the flat image copy one.
$moduleDir = @((Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'), (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules')) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'WindowsMigraphx.Common.psm1') } | Select-Object -First 1
if (-not $moduleDir) { return "MIGraphX: no modules directory with WindowsMigraphx.Common.psm1 near $PSScriptRoot" }
# Unguarded on purpose: without -Force an already-loaded module is left as it is.
Import-Module (Join-Path $moduleDir 'WindowsTargetArch.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $moduleDir 'WindowsMigraphx.Common.psm1') -DisableNameChecking
if (-not $env:HIP_PATH) { return 'MIGraphX: HIP_PATH is not set, so the HIP runtime set cannot be located' }
$rocmBin = Join-Path $env:HIP_PATH 'bin'

$gaps = @(Get-MigraphxCheckInstallFinding -MigraphxRoot $env:MIGRAPHX_ROOT -EpRoot $epRoot)
$gaps
if ($gaps.Count -gt 0) { return }
Get-MigraphxCheckLicenseFinding -MigraphxRoot $env:MIGRAPHX_ROOT -EpRoot $epRoot
Get-MigraphxCheckHipSidecarFinding -RocmBin $rocmBin -EpRoot $epRoot

# ORT's bin too: the EP only ever loads into a process that already holds onnxruntime.dll.
$searchDir = @($rocmBin, "$env:SystemRoot\System32") + @(if ($env:ONNX_ROOT) { Join-Path $env:ONNX_ROOT 'bin' })
$staticImports = { param([string]$Path) Get-PeImportNames -Path $Path }
foreach ($pe in @(Get-ChildItem -LiteralPath $epRoot -File | Where-Object { $_.Name -match '^migraphx.*\.(dll|exe)$' })) {
    Get-MigraphxCheckImportFinding -Path $pe.FullName -SearchDir $searchDir -ReadImports $staticImports `
        -HipDelayOnly:($pe.Name -eq 'migraphx-ep.dll')
}
foreach ($pe in @(Get-ChildItem -LiteralPath (Join-Path $env:MIGRAPHX_ROOT 'bin') -File | Where-Object { $_.Name -match '^migraphx.*\.(dll|exe)$' })) {
    Get-MigraphxCheckImportFinding -Path $pe.FullName -SearchDir $searchDir -ReadImports $staticImports
}

$probe = Invoke-MigraphxLoadProbe -Dll (Join-Path $epRoot 'migraphx-ep.dll')
$loadFinding = ConvertTo-MigraphxLoadFinding -ExitCode $probe.ExitCode -Output $probe.Output
if ($loadFinding) { $loadFinding } else { Write-Host '  [PASS] migraphx-ep.dll loads GPU-less and exports CreateEpFactories; HIP stays unloaded' }
