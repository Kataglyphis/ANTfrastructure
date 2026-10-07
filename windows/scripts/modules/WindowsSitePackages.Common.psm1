#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Dependency-free leaf, mounted alone by the media fan-in's merge: see docs/windows-build-invariants.md#a-layer-that-replaces-a-lower-layers-file-stores-its-name-lowercased

Set-StrictMode -Version Latest

function Get-DistInfoVersion {
    <#
    .SYNOPSIS
        Each *.dist-info directly under -SitePackages as Name (PEP 503 normal form), Version and Directory.
    #>
    param([Parameter(Mandatory)][string]$SitePackages)
    foreach ($dir in @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^(?<name>.+)-(?<version>[^-]+)\.dist-info$') { continue }
        [pscustomobject]@{ Name = ($Matches.name -replace '[-_.]+', '-').ToLowerInvariant(); Version = $Matches.version; Directory = $dir.Name }
    }
}

function Find-SitePackagesVersionConflict {
    <#
    .SYNOPSIS
        Each distribution that two of -Tree carry at different versions; none = a merge leaves one install per distribution.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Tree)
    $rows = @(foreach ($root in $Tree) { Get-DistInfoVersion -SitePackages $root | Select-Object Name, Version, @{ n = 'Tree'; e = { $root } } })
    foreach ($group in @($rows | Group-Object Name)) {
        $first = $group.Group[0]
        $group.Group | Where-Object Version -cne $first.Version | ForEach-Object { "$($group.Name) is $($first.Version) in $($first.Tree) but $($_.Version) in $($_.Tree)" }
    }
}

function Find-RecordCaseMismatch {
    <#
    .SYNOPSIS
        RECORD entries under -SitePackages whose file exists only under another spelling, as Distribution, Record and OnDisk.
    .DESCRIPTION
        NTFS opens either spelling, but CPython's import matches the directory listing exactly: Cython\shadow.py hides Cython.Shadow.
        Missing files and entries outside -SitePackages (..\..\Scripts) are not this check's business.
    .PARAMETER Distribution
        Only these distributions, in any spelling; empty checks every one.
    #>
    param([Parameter(Mandatory)][string]$SitePackages, [string[]]$Distribution = @())
    $root = (Resolve-Path -LiteralPath $SitePackages).ProviderPath.TrimEnd('\')
    $exact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $folded = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
        $rel = $file.Substring($root.Length + 1).Replace('\', '/')
        [void]$exact.Add($rel)
        $folded[$rel] = $rel
    }
    $wanted = @($Distribution | ForEach-Object { ($_ -replace '[-_.]+', '-').ToLowerInvariant() })
    foreach ($dist in @(Get-DistInfoVersion -SitePackages $root)) {
        if ($wanted.Count -gt 0 -and $dist.Name -notin $wanted) { continue }
        $record = Join-Path (Join-Path $root $dist.Directory) 'RECORD'
        if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { continue }
        foreach ($row in @(Import-Csv -LiteralPath $record -Header Path, Hash, Size)) {
            $path = "$($row.Path)".Replace('\', '/')
            if (-not $path -or $path.StartsWith('../') -or $exact.Contains($path) -or -not $folded.ContainsKey($path)) { continue }
            [pscustomobject]@{ Distribution = $dist.Name; Record = $path; OnDisk = $folded[$path] }
        }
    }
}

function Format-RecordCaseMismatch {
    <#
    .SYNOPSIS
        One line per distribution for Find-RecordCaseMismatch's output: the count and the first entry as RECORD names it and as the disk spells it.
    #>
    [OutputType([string])]
    param([Parameter(ValueFromPipeline)][object[]]$Mismatch = @())
    begin { $all = [Collections.Generic.List[object]]::new() }
    process { foreach ($m in @($Mismatch)) { if ($null -ne $m) { $all.Add($m) } } }
    end {
        foreach ($group in @($all | Group-Object Distribution | Sort-Object Name)) {
            $first = $group.Group[0]
            "$($group.Name): $($group.Count) RECORD entr$(if ($group.Count -eq 1) { 'y' } else { 'ies' }) spelled otherwise on disk, e.g. $($first.Record) is $($first.OnDisk)"
        }
    }
}

function Merge-SitePackageTree {
    <#
    .SYNOPSIS
        Merges each -Source site-packages into -Destination in order, a later source winning a file both carry, keeping every spelling.
    .DESCRIPTION
        A Windows layer that replaces a file a lower layer holds stores it lowercased, which BuildKit's COPY does to every file it
        overwrites; robocopy rewrites an existing file in place, so its name survives. Throws when -Destination and the sources
        carry one distribution at two versions, or when a RECORD no longer matches the merged files' spelling.
    #>
    param([Parameter(Mandatory)][string[]]$Source, [Parameter(Mandatory)][string]$Destination)
    foreach ($tree in $Source) {
        if (-not (Test-Path -LiteralPath $tree -PathType Container)) { throw "site-packages merge: source $tree does not exist" }
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $conflicts = @(Find-SitePackagesVersionConflict -Tree (@($Destination) + $Source))
    if ($conflicts.Count -gt 0) {
        throw "site-packages merge: a merge would leave a mixed install; pin one version across the branches:`n  $($conflicts -join "`n  ")"
    }
    # robocopy's success codes are 1-3; a caller's native-error preference would turn them into throws.
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($tree in $Source) {
        # /XJ: a junction in a branch tree would be followed into whatever it points at.
        $log = @(& robocopy.exe $tree $Destination /E /COPY:DAT /DCOPY:DAT /XJ /MT:16 /R:2 /W:1 /NP /NFL /NDL /NJH 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        # Bit 4 is a file meeting a directory of the same name, which no merge of two installs may paper over.
        if ($code -ge 4) { throw "site-packages merge: robocopy $tree -> $Destination exited $code`n$($log -join "`n")" }
        Write-Host "site-packages merge: $tree -> $Destination (robocopy exit $code)"
        $log | Where-Object { $_ -match '^\s*(Dirs|Files|Bytes)\s*:' } | ForEach-Object { Write-Host "  $($_.Trim())" }
    }
    $global:LASTEXITCODE = 0
    $mismatch = @(Find-RecordCaseMismatch -SitePackages $Destination)
    if ($mismatch.Count -gt 0) { throw "site-packages merge: RECORD spelling lost:`n  $(@($mismatch | Format-RecordCaseMismatch) -join "`n  ")" }
    $dists = @(Get-DistInfoVersion -SitePackages $Destination)
    Write-Host "site-packages merge: $($dists.Count) distributions in $Destination, every RECORD entry spelled as on disk"
}

Export-ModuleMember -Function Get-DistInfoVersion, Find-SitePackagesVersionConflict, Find-RecordCaseMismatch,
    Format-RecordCaseMismatch, Merge-SitePackageTree
