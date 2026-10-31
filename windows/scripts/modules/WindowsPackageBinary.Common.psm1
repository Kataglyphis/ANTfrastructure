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
    if (-not (Test-Path -LiteralPath $VerifierPath -PathType Leaf)) { throw "package binary verifier is missing: $VerifierPath" }
    if ($Member.Count -eq 0 -or $Member.Count -ne $SourcePath.Count) { throw 'package binary members and sources must have equal, nonzero counts' }
    $rules = @()
    for ($i = 0; $i -lt $Member.Count; $i++) {
        $mapped = if ([IO.Path]::GetExtension($Path) -ieq '.msi') { Get-MsiCabinetPattern -Path $Path -FileId $Member[$i] } else { $Member[$i] }
        $rules += '--require', "$mapped=$($SourcePath[$i])"
    }
    & $PythonPath -I $VerifierPath $Path @rules
    if ($LASTEXITCODE -ne 0) { throw "package binary verification failed for '$($Member -join ', ')' (exit $LASTEXITCODE)" }
}

function Get-ArchiveOrtProviderNames {
    param([string]$Path, [AllowEmptyString()][string]$Directory)
    $names = @()
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            $raw = $entry.FullName
            $parts = @($raw.Replace('\', '/') -split '/' | Where-Object { $_ -and $_ -ne '.' })
            if ($parts.Count -eq 0 -or $parts[-1] -in @('.', '..') -or $parts[-1] -inotmatch '^onnxruntime_providers_') { continue }
            if ($parts -contains '..') { throw "unsafe provider archive path: $raw" }
            $parent = if ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] -join '/' } else { '' }
            if (-not [string]::Equals($parent, $Directory, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $expected = (@($Directory, $parts[-1]) | Where-Object { $_ }) -join '/'
            if ($raw -cne $expected -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw "aliased or non-file provider archive member: $raw"
            }
            $names += $parts[-1]
        }
    } finally { $archive.Dispose() }
    return $names
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
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if ($name -inotmatch '^onnxruntime_providers_') { continue }
        if ($name -cnotmatch '^onnxruntime_providers_[a-z0-9_]+\.dll$') { throw "invalid ORT provider name: $name" }
        if (-not $seen.Add($name)) { throw "duplicate ORT provider name: $name" }
    }
    return @($seen | Sort-Object)
}

Export-ModuleMember -Function Assert-PackageBinary, Get-PackageOrtProviderNames
