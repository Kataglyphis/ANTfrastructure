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

function Test-PackageOrtFamilyName {
    param([string]$Name)
    return $Name.TrimEnd(' ', '.') -imatch '^(onnxruntime.*\.dll|directml\.dll)$'
}

function New-PackageOrtFamilySet {
    param([string[]]$Name)
    $allowed = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Name) {
        if (-not (Test-PackageOrtFamilyName $item) -or $item -match '[\\/:*?\[\]<>"|\x00-\x1f]' -or
            $item -match '[ .]$' -or $allowed.ContainsKey($item)) { throw "invalid or duplicate ORT family name: $item" }
        $allowed.Add($item, $item)
    }
    if ($allowed.Count -eq 0) { throw 'ORT family name list is empty' }
    return ,$allowed
}

function Add-PackageOrtFamilyName {
    param([string]$Name, $Allowed, $Seen, [string]$Context)
    if (-not $Allowed.ContainsKey($Name) -or $Allowed[$Name] -cne $Name -or -not $Seen.Add($Name)) {
        throw "unexpected or duplicate $Context file: $Name"
    }
}

function Assert-DirectoryOrtFamily {
    param([string]$Path, [string]$Directory, $Allowed, $Seen)
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) {
        if (-not (Test-PackageOrtFamilyName $file.Name)) { continue }
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName).Replace('\', '/')
        $expected = (@($Directory, $file.Name) | Where-Object { $_ }) -join '/'
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $relative -cne $expected) {
            throw "unexpected or nested ORT family file: $relative"
        }
        Add-PackageOrtFamilyName -Name $file.Name -Allowed $Allowed -Seen $Seen -Context 'ORT family bundle'
    }
}

function Assert-MsiOrtFamily {
    param([string]$Path, [string]$Directory, $Allowed, $Seen, [string]$RootDirectoryId, [string]$RootDirectoryName)
    if (-not $RootDirectoryId) { throw 'MSI family verification requires a root directory identifier' }
    foreach ($raw in @(Get-MsiInstalledFileNames -Path $Path)) {
        $parts = @($raw -split '\|', 2)
        $leaf = $parts[-1]
        if ($parts.Count -eq 2 -and (Test-PackageOrtFamilyName $parts[0]) -and $parts[0] -ine $leaf) {
            throw "aliased MSI ORT family file: $raw"
        }
        if (-not (Test-PackageOrtFamilyName $leaf)) { continue }
        Add-PackageOrtFamilyName -Name $leaf -Allowed $Allowed -Seen $Seen -Context 'MSI ORT family'
    }
    foreach ($item in $Allowed.Keys) {
        $relative = (@($Directory, $item) | Where-Object { $_ }) -join '/'
        $null = Get-MsiInstalledFileId -Path $Path -RelativePath $relative -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName
    }
}

function Assert-ArchiveOrtFamily {
    param([string]$Path, [string]$Directory, $Allowed, $Seen)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            $leaf = @($entry.FullName -split '[/\\]')[-1]
            if (-not $leaf -or -not (Test-PackageOrtFamilyName $leaf)) { continue }
            $expected = (@($Directory, $leaf) | Where-Object { $_ }) -join '/'
            if ($entry.FullName -cne $expected -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw "unexpected, nested or linked ORT family archive file: $($entry.FullName)"
            }
            Add-PackageOrtFamilyName -Name $leaf -Allowed $Allowed -Seen $Seen -Context 'ORT family archive'
        }
    } finally { $archive.Dispose() }
}

function Assert-PackageOrtFamily {
    <#
    .SYNOPSIS
        Requires exactly the declared ORT-family DLLs throughout a bundle or package.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Directory = '',
        [Parameter(Mandatory)][string[]]$Name, [string]$RootDirectoryId = '', [string]$RootDirectoryName = '')
    if ($Directory -match '(^/|//|(^|/)\.{1,2}(/|$)|[:*?\[\]<>"|\x00-\x1f\\]|[ .](/|$))' -or $Directory.EndsWith('/')) {
        throw "unsafe package directory: $Directory"
    }
    $allowed = New-PackageOrtFamilySet -Name $Name
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        Assert-DirectoryOrtFamily -Path $resolved -Directory $Directory -Allowed $allowed -Seen $seen
    } elseif ([IO.Path]::GetExtension($resolved) -ieq '.msi') {
        Assert-MsiOrtFamily -Path $resolved -Directory $Directory -Allowed $allowed -Seen $seen -RootDirectoryId $RootDirectoryId -RootDirectoryName $RootDirectoryName
    } elseif ([IO.Path]::GetExtension($resolved) -in @('.zip', '.msix')) {
        Assert-ArchiveOrtFamily -Path $resolved -Directory $Directory -Allowed $allowed -Seen $seen
    } else { throw 'ORT family verification requires a bundle, ZIP, MSIX or MSI' }
    if ($seen.Count -ne $allowed.Count) { throw 'package is missing a required ORT family file' }
}

Export-ModuleMember -Function Assert-PackageBinary, Get-PackageOrtProviderNames, Assert-PackageOrtFamily
