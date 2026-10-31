#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Verifies exact finished-package bytes against an already-proven source file.

# PACKAGE_ORT_PROVIDER_SET_API=1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsMsiLicense.Common.psm1') -DisableNameChecking -ErrorAction Stop

function Assert-PackageBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Member,
        [Parameter(Mandatory)][string[]]$SourcePath,
        [string]$PythonPath = 'python',
        [string]$VerifierPath = (Join-Path $PSScriptRoot '../../../linux/scripts/verify_package_binary.py')
    )
    $request = @{ Path = $Path; Member = $Member; Source = $SourcePath; PythonPath = $PythonPath; VerifierPath = $VerifierPath }
    Invoke-PackageVerifier -Request $request -Binary
}

function Get-ArchiveOrtProviderName {
    param([IO.Compression.ZipArchiveEntry]$Entry, [AllowEmptyString()][string]$Directory)
    $raw = $Entry.FullName
    $parts = @($raw.Replace('\', '/') -split '/' | Where-Object { $_ -and $_ -ne '.' })
    if ($parts.Count -eq 0 -or $parts[-1] -in @('.', '..') -or $parts[-1] -inotmatch '^onnxruntime_providers_') { return }
    if ($parts -contains '..') { throw "unsafe provider archive path: $raw" }
    $parent = if ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] -join '/' } else { '' }
    $expected = (@($Directory, $parts[-1]) | Where-Object { $_ }) -join '/'
    if ($raw -ceq $expected -and (($Entry.ExternalAttributes -shr 16) -band 0xF000) -ne 0xA000) { return $parts[-1] }
    if ([StringComparer]::OrdinalIgnoreCase.Equals($parent, $Directory)) {
        throw "aliased or non-file provider archive member: $raw"
    }
}

function Get-ArchiveOrtProviderNames {
    param([string]$Path, [AllowEmptyString()][string]$Directory)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try { foreach ($entry in $archive.Entries) { Get-ArchiveOrtProviderName -Entry $entry -Directory $Directory } }
    finally { $archive.Dispose() }
}

function Get-ValidatedOrtProviderNames {
    param([string[]]$Names)
    $seen = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if ($name -inotmatch '^onnxruntime_providers_') { continue }
        if ($name -cnotmatch '^onnxruntime_providers_[a-z0-9_]+\.dll$') { throw "invalid ORT provider name: $name" }
        if ($seen.ContainsKey($name)) { throw "duplicate ORT provider name: $name (first: $($seen[$name]))" }
        $seen.Add($name, $name)
    }
    return @($seen.Keys | Sort-Object)
}

function Get-PackageOrtProviderNames {
    <#
    .SYNOPSIS
        Enumerates the exact ORT provider DLL basenames in one installed package directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Directory = '',
        [string]$RootDirectoryId = '', [string]$RootDirectoryName = '')
    if ($Directory -match '(^/|//|(^|/)\.{1,2}(/|$)|[:*?\[\]<>"|\x00-\x1f\\]|[ .](/|$))' -or $Directory.EndsWith('/')) {
        throw "unsafe package directory: $Directory"
    }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $extension = [IO.Path]::GetExtension($resolved)
    $names = if ($extension -ieq '.msi') {
        if (-not $RootDirectoryId) { throw 'MSI provider enumeration requires a root directory identifier' }
        @(Get-MsiDirectoryFileNames -Path $resolved -Directory $Directory -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName)
    } elseif ($extension -in @('.zip', '.msix')) {
        @(Get-ArchiveOrtProviderNames -Path $resolved -Directory $Directory)
    } else { throw 'provider enumeration requires ZIP, MSIX or MSI' }
    return @(Get-ValidatedOrtProviderNames -Names $names)
}

Export-ModuleMember -Function Assert-PackageBinary, Get-PackageOrtProviderNames
