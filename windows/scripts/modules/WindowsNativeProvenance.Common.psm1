#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# One manifest format for native DLLs an image redistributes: see docs/consumer-image-contract.md § Native DLL provenance

Set-StrictMode -Version Latest

$script:NoticeNamePattern = '^(licen[cs]e|copying|copyright|notice|patents)([._-].*)?$'

function Get-NativeProvenanceRelativePathError {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'is empty' }
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') { return 'is rooted' }
    if (@($Path -split '[\\/]') -contains '..') { return 'climbs out of the root' }
    return ''
}

<#
.SYNOPSIS
    Parses a meson .wrap file into its directory and source identity.
#>
function Read-MesonWrapSource {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $values = @{}
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; continue }
        if ($section -in @('wrap-file', 'wrap-git') -and $line -match '^\s*([A-Za-z_-]+)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    if (-not $section -or -not $values.ContainsKey('directory') -and -not $values.ContainsKey('url') -and -not $values.ContainsKey('source_url')) {
        throw "$Path is not a readable wrap-file or wrap-git"
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $read = { param($key) if ($values.ContainsKey($key)) { $values[$key] } else { '' } }
    $url = & $read 'source_url'
    if (-not $url) { $url = & $read 'url' }
    return [pscustomobject]@{
        Name      = $name
        Directory = $(if ($values.ContainsKey('directory')) { $values['directory'] } else { $name })
        Url       = $url
        Sha256    = & $read 'source_hash'
        Revision  = & $read 'revision'
        PatchUrl  = & $read 'patch_url'
        PatchHash = & $read 'patch_hash'
    }
}

<#
.SYNOPSIS
    Every top-level wrap of a subprojects directory by name; take it before wrap provisioning deletes any.
#>
function Get-MesonWrapInventory {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$SubprojectDir)
    $inventory = @{}
    foreach ($wrap in @(Get-ChildItem -LiteralPath $SubprojectDir -Filter '*.wrap' -File)) {
        $source = Read-MesonWrapSource -Path $wrap.FullName
        $inventory[$source.Name] = $source
    }
    return $inventory
}

<#
.SYNOPSIS
    The license, copying, notice and patent files at the top of a source tree.
#>
function Get-NativeNoticeFile {
    [OutputType([IO.FileInfo[]])]
    param([Parameter(Mandatory)][string]$Directory)
    return @(Get-ChildItem -LiteralPath $Directory -File -Force | Where-Object { $_.Name -imatch $script:NoticeNamePattern } | Sort-Object Name)
}

<#
.SYNOPSIS
    Copies original notice files under Root\NoticeDir\Name and returns their root-relative paths.
#>
function Copy-NativeNotice {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$NoticeDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$File
    )
    $relativeDir = Join-Path $NoticeDir $Name
    $target = Join-Path $Root $relativeDir
    $null = New-Item -ItemType Directory -Force -Path $target
    return [string[]]@(foreach ($path in $File) {
            $leaf = Split-Path -Leaf $path
            Copy-Item -LiteralPath $path -Destination (Join-Path $target $leaf) -Force
            Join-Path $relativeDir $leaf
        })
}

<#
.SYNOPSIS
    One manifest entry: a shipped file's bytes, its source identity and its notice texts.
.PARAMETER Source
    Hashtable with Name, Version and Url, and optionally Sha256, Revision, PatchUrl and PatchHash.
#>
function New-NativeProvenanceEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][hashtable]$Source,
        [Parameter(Mandatory)][string[]]$Notice
    )
    $sha = { param($relative) (Get-FileHash -LiteralPath (Join-Path $Root $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $identity = [ordered]@{}
    foreach ($key in @($Source.Keys | Sort-Object)) { if ($Source[$key]) { $identity[$key.ToLowerInvariant()] = "$($Source[$key])" } }
    return [ordered]@{
        file    = $File
        sha256  = & $sha $File
        source  = $identity
        notices = @(foreach ($relative in $Notice) { [ordered]@{ path = $relative; sha256 = & $sha $relative } })
    }
}

<#
.SYNOPSIS
    Writes a manifest as UTF-8 JSON, refusing an empty entry list.
#>
function Write-NativeProvenanceManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry
    )
    if ($Entry.Count -eq 0) { throw "refusing to write an empty $Owner provenance manifest at $Path" }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    $json = [ordered]@{ schema = 1; owner = $Owner; entries = @($Entry) } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-NativeProvenanceEntryFinding {
    param([object]$Entry, [string]$Root)
    $name = $Entry.file
    $pathError = Get-NativeProvenanceRelativePathError -Path $name
    if ($pathError) { return @("file '$name' $pathError") }
    $found = @()
    $full = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $found += "$name is missing" }
    elseif ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $Entry.sha256) { $found += "$name differs from its recorded bytes" }
    if (-not $Entry.source -or -not $Entry.source.name -or -not $Entry.source.version -or -not $Entry.source.url) { $found += "$name has no source name, version and url" }
    if (@($Entry.notices).Count -eq 0) { $found += "$name has no notice text" }
    foreach ($notice in @($Entry.notices)) {
        $noticeError = Get-NativeProvenanceRelativePathError -Path $notice.path
        if ($noticeError) { $found += "$name notice '$($notice.path)' $noticeError"; continue }
        $text = Join-Path $Root $notice.path
        if (-not (Test-Path -LiteralPath $text -PathType Leaf)) { $found += "$name notice $($notice.path) is missing" }
        elseif ((Get-FileHash -LiteralPath $text -Algorithm SHA256).Hash -ine $notice.sha256) { $found += "$name notice $($notice.path) differs from its recorded bytes" }
    }
    return $found
}

<#
.SYNOPSIS
    Every defect of a manifest against the tree under Root; empty means it holds.
.PARAMETER RequiredFile
    Root-relative files the manifest must list.
#>
function Get-NativeProvenanceFinding {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$RequiredFile = @()
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @("manifest $Path is missing") }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1) { return @("manifest $Path has schema '$($manifest.schema)', expected 1") }
    $entries = @($manifest.entries)
    if ($entries.Count -eq 0) { return @("manifest $Path lists nothing") }
    $found = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if (-not $seen.Add("$($entry.file)")) { $found.Add("$($entry.file) is listed twice") }
        foreach ($item in @(Get-NativeProvenanceEntryFinding -Entry $entry -Root $Root)) { $found.Add($item) }
    }
    foreach ($required in $RequiredFile) {
        if (-not $seen.Contains($required)) { $found.Add("$required is not in the manifest") }
    }
    return [string[]]$found
}

<#
.SYNOPSIS
    Throws on any defect of a manifest, naming each one.
#>
function Assert-NativeProvenanceManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$RequiredFile = @()
    )
    $found = @(Get-NativeProvenanceFinding -Path $Path -Root $Root -RequiredFile $RequiredFile)
    if ($found.Count -gt 0) { throw "native provenance manifest $Path fails: $($found -join '; ')" }
}

<#
.SYNOPSIS
    Staged DLLs in Directory, recursively from Importer's PE imports, that the manifest does not list.
.PARAMETER GetImport
    Returns one PE file's imported names; callers pass Get-PeImportNames.
#>
function Get-NativeClosureGap {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Importer,
        [Parameter(Mandatory)][scriptblock]$GetImport
    )
    $listed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @((Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json).entries)) { $null = $listed.Add((Split-Path -Leaf $entry.file)) }
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gap = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($path in $Importer) { $queue.Enqueue($path) }
    while ($queue.Count -gt 0) {
        foreach ($name in @(& $GetImport $queue.Dequeue())) {
            $staged = Join-Path $Directory $name
            if (-not $visited.Add($name) -or -not (Test-Path -LiteralPath $staged -PathType Leaf)) { continue }
            if (-not $listed.Contains($name)) { $null = $gap.Add($name) }
            $queue.Enqueue($staged)
        }
    }
    return [string[]]@($gap)
}

function Get-MesonInstalledDll {
    param([Parameter(Mandatory)][string]$BuildDir)
    $targets = Get-Content -LiteralPath (Join-Path $BuildDir 'meson-info\intro-targets.json') -Raw | ConvertFrom-Json
    foreach ($target in @($targets)) {
        if (-not $target.installed) { continue }
        foreach ($installed in @($target.install_filename)) {
            if ("$installed" -imatch '\.dll$') { [pscustomobject]@{ Path = "$installed"; Subproject = $target.subproject } }
        }
    }
}

function Get-MesonSubprojectVersion {
    param([Parameter(Mandatory)][string]$BuildDir)
    $projects = Get-Content -LiteralPath (Join-Path $BuildDir 'meson-info\intro-projectinfo.json') -Raw | ConvertFrom-Json
    $versions = @{ '' = "$($projects.version)" }
    foreach ($sub in @($projects.subprojects)) { $versions["$($sub.name)"] = "$($sub.version)" }
    return $versions
}

function Resolve-MesonDllSource {
    param([object]$Dll, [hashtable]$Wrap, [hashtable]$Version, [string]$SourceDir, [hashtable]$RootSource)
    $sub = "$($Dll.Subproject)"
    if (-not $sub) {
        return @{ Key = 'gstreamer'; Directory = $SourceDir; Source = $RootSource }
    }
    if ($Wrap.ContainsKey($sub)) {
        $w = $Wrap[$sub]
        return @{
            Key       = $sub
            Directory = Join-Path $SourceDir "subprojects\$($w.Directory)"
            Source    = @{ Name = $sub; Version = $Version[$sub]; Url = $w.Url; Sha256 = $w.Sha256; Revision = $w.Revision; PatchUrl = $w.PatchUrl; PatchHash = $w.PatchHash }
        }
    }
    $inTree = Join-Path $SourceDir "subprojects\$sub"
    if (-not (Test-Path -LiteralPath $inTree -PathType Container)) {
        throw "$($Dll.Path) comes from subproject '$sub', which has neither a wrap nor a directory in $SourceDir"
    }
    $source = $RootSource.Clone()
    $source['Name'] = $sub
    $source['Version'] = $Version[$sub]
    return @{ Key = $sub; Directory = $inTree; Source = $source }
}

<#
.SYNOPSIS
    Manifest entries for every DLL a meson build installed under Root, copying each source's notices.
.PARAMETER Wrap
    Get-MesonWrapInventory's result, taken before provisioning.
.PARAMETER RootSource
    Source identity of the main project and of in-tree subprojects without a wrap.
#>
function Get-MesonProvenanceEntry {
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$NoticeDir,
        [Parameter(Mandatory)][hashtable]$Wrap,
        [Parameter(Mandatory)][hashtable]$RootSource
    )
    $version = Get-MesonSubprojectVersion -BuildDir $BuildDir
    $notices = @{}
    $prefix = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return @(foreach ($dll in @(Get-MesonInstalledDll -BuildDir $BuildDir)) {
            $full = [IO.Path]::GetFullPath($dll.Path)
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$full is not installed under $Root" }
            $origin = Resolve-MesonDllSource -Dll $dll -Wrap $Wrap -Version $version -SourceDir $SourceDir -RootSource $RootSource
            if (-not $notices.ContainsKey($origin.Key)) {
                $files = @(Get-NativeNoticeFile -Directory $origin.Directory)
                if ($files.Count -eq 0) { throw "$($origin.Key) ($($origin.Directory)) has no license or notice file; $($full) cannot ship without one" }
                $notices[$origin.Key] = Copy-NativeNotice -Root $Root -NoticeDir $NoticeDir -Name $origin.Key -File @($files.FullName)
            }
            New-NativeProvenanceEntry -Root $Root -File $full.Substring($prefix.Length) -Source $origin.Source -Notice $notices[$origin.Key]
        })
}

Export-ModuleMember -Function Read-MesonWrapSource, Get-MesonWrapInventory, Get-NativeNoticeFile, Copy-NativeNotice,
    New-NativeProvenanceEntry, Write-NativeProvenanceManifest, Get-NativeProvenanceFinding, Assert-NativeProvenanceManifest,
    Get-NativeClosureGap, Get-MesonProvenanceEntry
