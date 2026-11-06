#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Stages and checks the MSVC runtime's notice in Windows packages; see docs/third-party-licenses.md § The MSVC runtime notice

Set-StrictMode -Version Latest
foreach ($sibling in 'WindowsScripts.Shared', 'WindowsMsiLicense.Common') {
    Import-Module (Join-Path $PSScriptRoot "$sibling.psm1") -DisableNameChecking -ErrorAction Stop
}

$script:MsvcRuntimeDllPattern = '^(msvcp140.*|vcruntime140.*|concrt140|vccorlib140)\.dll$'
$script:MsvcNoticeDir = 'licenses/msvc-runtime'
$script:MsvcNoticeText = Join-Path $PSScriptRoot '../../../cmake/msvc-runtime-notice.txt'

function Test-MsvcRuntimeDllName {
    param([AllowEmptyString()][string]$Name)
    return $Name -match $script:MsvcRuntimeDllPattern
}

function Find-MsvcRedistText {
    <#
    .SYNOPSIS
        Returns the Visual Studio install's Licenses\<lcid>\Redist.txt, English first; throws when none exists.
    #>
    param([string]$VsInstallDir = '')
    if (-not $VsInstallDir) { $VsInstallDir = Get-VisualStudioInstallPath }
    $texts = @(Get-ChildItem -Path (Join-Path $VsInstallDir 'Licenses/*/Redist.txt') -File -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = { $_.Directory.Name -ne '1033' } }, FullName)
    if ($texts.Count -eq 0) { throw "no Licenses\<lcid>\Redist.txt under '$VsInstallDir', so the MSVC runtime cannot ship with its notice" }
    return $texts[0].FullName
}

function Copy-MsvcRuntimeNotice {
    <#
    .SYNOPSIS
        Stages Redist.txt and the end-user notice under <Root>\licenses\msvc-runtime when Root carries the MSVC runtime.
    .OUTPUTS
        The staged Redist.txt, or $null when no MSVC runtime DLL is under Root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [string]$VsInstallDir = '', [string]$RedistText = '')
    $dlls = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.dll' | Where-Object { Test-MsvcRuntimeDllName $_.Name })
    if ($dlls.Count -eq 0) { return $null }
    if (-not $RedistText) { $RedistText = Find-MsvcRedistText -VsInstallDir $VsInstallDir }
    if (-not (Test-Path -LiteralPath $script:MsvcNoticeText -PathType Leaf)) { throw "the MSVC runtime notice is missing: $script:MsvcNoticeText" }
    $dir = Join-Path $Root $script:MsvcNoticeDir
    $null = New-Item -ItemType Directory -Force -Path $dir
    Copy-Item -LiteralPath $RedistText -Destination (Join-Path $dir 'Redist.txt') -Force
    Copy-Item -LiteralPath $script:MsvcNoticeText -Destination (Join-Path $dir 'README.txt') -Force
    Write-Host "MSVC runtime notice: $($dlls.Count) runtime DLL(s) -> $dir"
    return (Join-Path $dir 'Redist.txt')
}

function Get-PackageMemberName {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::GetExtension($Path) -ieq '.msi') {
        # The File table stores short|long names.
        return @(Get-MsiInstalledFileNames -Path $Path | ForEach-Object { ($_ -split '\|')[-1] })
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try { return @($zip.Entries | Where-Object { $_.Name } | ForEach-Object { [Uri]::UnescapeDataString($_.FullName) }) }
    finally { $zip.Dispose() }
}

function Assert-PackageMsvcRuntimeNotice {
    <#
    .SYNOPSIS
        Fails a finished ZIP, MSIX or MSI that carries an MSVC runtime DLL without licenses/msvc-runtime/Redist.txt equal to -RedistText.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$RedistText = '', [string]$PythonPath = 'python')
    $members = @(Get-PackageMemberName -Path $Path)
    $runtime = @($members | Where-Object { Test-MsvcRuntimeDllName (Split-Path $_ -Leaf) })
    if ($runtime.Count -eq 0) { return }
    $notices = @($members | Where-Object { ($_ -replace '\\', '/') -match '(^|/)licenses/msvc-runtime/Redist\.txt$' -or $_ -ieq 'Redist.txt' })
    if ($notices.Count -ne 1) { throw "$Path carries $($runtime -join ', ') but $($notices.Count) licenses/msvc-runtime/Redist.txt; the MSVC runtime ships only with its notice" }
    if (-not $RedistText) { throw "$Path carries the MSVC runtime, and no -RedistText names the notice it must ship" }
    if ([IO.Path]::GetExtension($Path) -ieq '.msi') {
        Assert-MsiPackageLicense -Path $Path -FileName 'Redist.txt' -LicensePath $RedistText -PythonPath $PythonPath
    } else {
        Assert-PackageLicense -Path $Path -Pattern $notices[0] -LicensePath $RedistText -PythonPath $PythonPath
    }
}

Export-ModuleMember -Function Test-MsvcRuntimeDllName, Find-MsvcRedistText, Copy-MsvcRuntimeNotice, Assert-PackageMsvcRuntimeNotice
