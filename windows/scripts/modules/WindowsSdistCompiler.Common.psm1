#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# setuptools compiles an sdist with VS's cl.exe unless cl, link and lib on PATH are LLVM's (CON93); see docs/windows-builds.md § The app stage.

Set-StrictMode -Version Latest

# Unforced: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
foreach ($sibling in 'WindowsTargetArch.Common', 'WindowsScripts.Shared') { Import-Module (Join-Path $PSScriptRoot "$sibling.psm1") -DisableNameChecking -ErrorAction Stop }

$script:ImageLlvmBin = 'C:\llvm-patched\bin'

<#
.SYNOPSIS
    The LIB path a lane's build links with: the caller's, else what VsDevCmd.bat sets.
.DESCRIPTION
    lld-link finds VS and the SDK for default libraries only, so an sdist naming kernel32.lib on its link line needs LIB.
#>
function Get-ClangClSdistVsLib {
    [OutputType([string])]
    param([string]$VsDevCmdPattern = 'C:\Program Files*\Microsoft Visual Studio\*\*\Common7\Tools\VsDevCmd.bat')
    if ($env:LIB) { return $env:LIB }
    $vsDevCmd = @(Get-ChildItem -Path $VsDevCmdPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($vsDevCmd.Count -eq 0) { throw "the sdist compiler shim needs LIB or a VsDevCmd.bat at $VsDevCmdPattern" }
    $lines = @(& "$env:SystemRoot\System32\cmd.exe" /d /c "`"$($vsDevCmd[0].FullName)`" -arch=amd64 -host_arch=amd64 >nul && set LIB" 2>&1)
    $lib = @($lines | Where-Object { "$_" -match '^LIB=.' })
    if ($lib.Count -ne 1) { throw "$($vsDevCmd[0].FullName) set no LIB (exit $LASTEXITCODE): $($lines -join ' | ')" }
    return "$($lib[0])".Substring(4)
}

<#
.SYNOPSIS
    Puts copies of clang-cl, lld-link and llvm-lib first on PATH as cl, link and lib; returns the values to restore.
#>
function Enable-ClangClSdistShim {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ShimDir, [string]$LlvmBin = $script:ImageLlvmBin, [string]$VsLib = '')
    $shim = [ordered]@{ 'cl.exe' = 'clang-cl.exe'; 'link.exe' = 'lld-link.exe'; 'lib.exe' = 'llvm-lib.exe' }
    $missing = @($shim.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LlvmBin $_) -PathType Leaf) })
    if ($missing.Count) { throw "the sdist compiler shim needs $($missing -join ', ') in $LlvmBin" }
    # A copied clang-cl looks for its builtin headers beside the copy, so the real resource directory is named.
    $clangLib = Join-Path (Split-Path $LlvmBin -Parent) 'lib\clang'
    $resource = @(Get-ChildItem -LiteralPath $clangLib -Directory -ErrorAction SilentlyContinue)
    if ($resource.Count -ne 1) { throw "the sdist compiler shim needs one resource directory under $clangLib, found $($resource.Count)" }
    if (-not $VsLib) { $VsLib = Get-ClangClSdistVsLib }
    $null = New-Item -ItemType Directory -Force -Path $ShimDir
    $shim.GetEnumerator() | ForEach-Object { Copy-Item -LiteralPath (Join-Path $LlvmBin $_.Value) -Destination (Join-Path $ShimDir $_.Key) -Force }
    # cl.exe's common tentative definitions, which psutil's headers rely on.
    $cl = ("/clang:-fcommon `"/clang:-resource-dir=$($resource[0].FullName)`" $env:CL").TrimEnd()
    return Set-ProcessEnvironmentValue -Values ([ordered]@{ DISTUTILS_USE_SDK = '1'; MSSdk = '1'; PATH = "$ShimDir;$env:PATH"; LIB = $VsLib; CL = $cl })
}

<#
.SYNOPSIS
    Restores what Enable-ClangClSdistShim returned and removes the shim.
#>
function Disable-ClangClSdistShim {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Previous, [Parameter(Mandatory)][string]$ShimDir)
    $null = Set-ProcessEnvironmentValue -Values $Previous
    Remove-Item -LiteralPath $ShimDir -Recurse -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Fails when a distribution uv reports as built from source carries MSVC's Rich header under -SitePackages.
.DESCRIPTION
    Sees only what this sync built: a wheel served from uv's cache prints no Built line.
#>
function Assert-ClangClSdistBuild {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SyncOutput, [Parameter(Mandatory)][string]$SitePackages)
    $built = @($SyncOutput | ForEach-Object { if ("$_" -match '^\s*Built (\S+?)(==| @ )') { $Matches[1] } } | Sort-Object -Unique)
    Write-Host "uv built from source: $(if ($built.Count) { $built -join ', ' } else { 'nothing' })"
    $msvc = @(foreach ($name in $built) {
            $norm = $name -replace '[-_.]+', '_'
            $infos = @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Name -replace '-[^-]+\.dist-info$', '' -replace '[-_.]+', '_') -ieq $norm })
            if ($infos.Count -eq 0) { throw "uv built $name, but $SitePackages has no dist-info for it" }
            foreach ($line in [IO.File]::ReadAllLines((Join-Path $infos[0].FullName 'RECORD'))) {
                $rel = ($line -split ',')[0]
                # Scripts\*.exe are uv's own launchers, outside site-packages.
                if ($rel -notmatch '\.(pyd|dll|exe)$' -or $rel.StartsWith('..')) { continue }
                $pe = Join-Path $SitePackages $rel
                if ((Test-Path -LiteralPath $pe -PathType Leaf) -and (Test-PeRichHeader -Path $pe)) { "${name}: $rel" }
            }
        })
    if ($msvc.Count) { throw "uv built these with MSVC's linker, not the clang-cl shim: $($msvc -join '; ')" }
}

<#
.SYNOPSIS
    Runs a consumer lane's native build step under the shim; outside the image, where -LlvmBin is absent, it runs as it stands.
.PARAMETER BuiltOutput
    The uv output -SitePackages is graded against once the step ends.
#>
function Invoke-WithClangClSdist {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$LlvmBin = $script:ImageLlvmBin,
        [AllowEmptyCollection()][Collections.Generic.List[string]]$BuiltOutput,
        [string]$SitePackages = '',
        [scriptblock]$LogInfo
    )
    if (-not (Test-Path -LiteralPath $LlvmBin -PathType Container)) {
        if ($LogInfo) { & $LogInfo "sdist compiler: no $LlvmBin, so setuptools keeps its own compiler" }
        & $Script
        return
    }
    $shimDir = Join-Path ([IO.Path]::GetTempPath()) "clangcl-sdist-shim-$PID"
    $previous = Enable-ClangClSdistShim -ShimDir $shimDir -LlvmBin $LlvmBin
    try { & $Script } finally { Disable-ClangClSdistShim -Previous $previous -ShimDir $shimDir }
    if ($SitePackages) { Assert-ClangClSdistBuild -SyncOutput @($BuiltOutput) -SitePackages $SitePackages }
}

Export-ModuleMember -Function Get-ClangClSdistVsLib, Enable-ClangClSdistShim, Disable-ClangClSdistShim, Assert-ClangClSdistBuild, Invoke-WithClangClSdist
