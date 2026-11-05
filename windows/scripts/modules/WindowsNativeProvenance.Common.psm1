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
    $blocks = ((Get-Content -LiteralPath $Path -Raw) -replace '\r', '') -split '(?m)^(?=\[)'
    $section = @($blocks | Where-Object { $_ -match '^\[wrap-(file|git)\]' })
    if ($section.Count -ne 1) { throw "$Path is not a readable wrap-file or wrap-git" }
    # A wrap's values hold no backslashes, so StringData's escaping cannot change them.
    $values = ($section[0] -replace '^.*\n', '') | ConvertFrom-StringData
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
    Writes a manifest as UTF-8 JSON and proves it against the tree under Root; refuses an empty entry list.
#>
function Write-NativeProvenanceManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [Parameter(Mandatory)][string]$Root,
        [string[]]$RequiredFile = @()
    )
    if ($Entry.Count -eq 0) { throw "refusing to write an empty $Owner provenance manifest at $Path" }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    $json = [ordered]@{ schema = 1; owner = $Owner; entries = @($Entry) } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
    Assert-NativeProvenanceManifest -Path $Path -Root $Root -RequiredFile $RequiredFile
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
    $files = @($entries | ForEach-Object { "$($_.file)" })
    return [string[]]@(
        $files | Group-Object | Where-Object Count -GT 1 | ForEach-Object { "$($_.Name) is listed twice" }
        $entries | ForEach-Object { Get-NativeProvenanceEntryFinding -Entry $_ -Root $Root }
        $RequiredFile | Where-Object { $_ -notin $files } | ForEach-Object { "$_ is not in the manifest" }
    )
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
    $entries = @((Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json).entries)
    $listed = @($entries | ForEach-Object { Split-Path -Leaf $_.file })
    $seen = @{}
    $pending = [System.Collections.Generic.List[string]]::new([string[]]$Importer)
    for ($next = 0; $next -lt $pending.Count; $next++) {
        foreach ($name in @(& $GetImport $pending[$next])) {
            $staged = Join-Path $Directory $name
            if ($seen.ContainsKey($name) -or -not (Test-Path -LiteralPath $staged -PathType Leaf)) { continue }
            $seen[$name] = $true
            $pending.Add($staged)
        }
    }
    return [string[]]@($seen.Keys | Where-Object { $_ -notin $listed } | Sort-Object)
}

function Read-MesonInfo {
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][string]$Name)
    return Get-Content -LiteralPath (Join-Path $BuildDir "meson-info\$Name") -Raw | ConvertFrom-Json
}

function Get-MesonInstalledDll {
    param([Parameter(Mandatory)][string]$BuildDir)
    foreach ($target in @(Read-MesonInfo -BuildDir $BuildDir -Name 'intro-targets.json')) {
        if (-not $target.installed) { continue }
        foreach ($installed in @($target.install_filename)) {
            if ("$installed" -imatch '\.dll$') { [pscustomobject]@{ Path = "$installed"; Subproject = $target.subproject; DefinedIn = "$($target.defined_in)" } }
        }
    }
}

function Get-MesonSubprojectVersion {
    param([Parameter(Mandatory)][string]$BuildDir)
    $projects = Read-MesonInfo -BuildDir $BuildDir -Name 'intro-projectinfo.json'
    $versions = @{ '' = "$($projects.version)" }
    foreach ($sub in @($projects.subprojects)) { $versions["$($sub.name)"] = "$($sub.version)" }
    return $versions
}

# A provisioned wrap need not extract where its directory key says, so meson's own record of the target locates the tree.
function Get-MesonSubprojectDirectory {
    param([object]$Dll, [string]$SourceDir)
    $prefix = [IO.Path]::GetFullPath((Join-Path $SourceDir 'subprojects')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $Dll.DefinedIn) { throw "$($Dll.Path) has no defined_in in meson's records" }
    $definedIn = [IO.Path]::GetFullPath($Dll.DefinedIn)
    if (-not $definedIn.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$($Dll.Path) comes from subproject '$($Dll.Subproject)', defined outside $prefix at $definedIn"
    }
    return $prefix + ($definedIn.Substring($prefix.Length) -split '[\\/]')[0]
}

function Resolve-MesonDllSource {
    param([object]$Dll, [hashtable]$Wrap, [hashtable]$Version, [string]$SourceDir, [hashtable]$RootSource)
    $sub = "$($Dll.Subproject)"
    if (-not $sub) {
        return @{ Key = 'gstreamer'; Directory = $SourceDir; Source = $RootSource }
    }
    $directory = Get-MesonSubprojectDirectory -Dll $Dll -SourceDir $SourceDir
    if ($Wrap.ContainsKey($sub)) {
        $w = $Wrap[$sub]
        return @{
            Key       = $sub
            Directory = $directory
            Source    = @{ Name = $sub; Version = $Version[$sub]; Url = $w.Url; Sha256 = $w.Sha256; Revision = $w.Revision; PatchUrl = $w.PatchUrl; PatchHash = $w.PatchHash }
        }
    }
    $source = $RootSource.Clone()
    $source['Name'] = $sub
    $source['Version'] = $Version[$sub]
    return @{ Key = $sub; Directory = $directory; Source = $source }
}

<#
.SYNOPSIS
    Extracts archive members to their destinations; a missing member throws.
.PARAMETER Member
    Member name -> destination file.
#>
function Expand-NativeZipMember {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][System.Collections.IDictionary]$Member)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($name in @($Member.Keys)) {
            $entry = $zip.GetEntry($name)
            if (-not $entry) { throw "$Archive has no $name" }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Member[$name])
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Member[$name], $true)
        }
    } finally { $zip.Dispose() }
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
    # Every defect at once: this runs after a half-hour build, so reporting one per run costs a build each.
    $defects = [System.Collections.Generic.List[string]]::new()
    $entries = @(foreach ($dll in @(Get-MesonInstalledDll -BuildDir $BuildDir)) {
            $full = [IO.Path]::GetFullPath($dll.Path)
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $defects.Add("$full is not installed under $Root"); continue }
            try { $origin = Resolve-MesonDllSource -Dll $dll -Wrap $Wrap -Version $version -SourceDir $SourceDir -RootSource $RootSource }
            catch { $defects.Add($_.Exception.Message); continue }
            if (-not $notices.ContainsKey($origin.Key)) {
                $files = @(if (Test-Path -LiteralPath $origin.Directory -PathType Container) { Get-NativeNoticeFile -Directory $origin.Directory })
                if ($files.Count -eq 0) { $defects.Add("$($origin.Key) ($($origin.Directory)) has no license or notice file; $($full) cannot ship without one"); continue }
                $notices[$origin.Key] = Copy-NativeNotice -Root $Root -NoticeDir $NoticeDir -Name $origin.Key -File @($files.FullName)
            }
            New-NativeProvenanceEntry -Root $Root -File $full.Substring($prefix.Length) -Source $origin.Source -Notice $notices[$origin.Key]
        })
    if ($defects.Count -gt 0) { throw "native provenance: $($defects.Count) defect(s): $($defects -join ' | ')" }
    return $entries
}

Export-ModuleMember -Function Expand-NativeZipMember, Read-MesonWrapSource, Get-MesonWrapInventory, Get-NativeNoticeFile, Copy-NativeNotice,
    New-NativeProvenanceEntry, Write-NativeProvenanceManifest, Get-NativeProvenanceFinding, Assert-NativeProvenanceManifest,
    Get-NativeClosureGap, Get-MesonProvenanceEntry
