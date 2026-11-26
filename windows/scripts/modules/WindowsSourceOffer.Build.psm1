#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A copyleft build's licence texts and exact sources beside its binaries; see docs/consumer-image-contract.md § The FFmpeg source offer

Set-StrictMode -Version Latest
# A leaf module: the RUN that mounts it mounts its sibling next to it, never the shared closure.
Import-Module (Join-Path $PSScriptRoot 'WindowsNativeProvenance.Common.psm1') -DisableNameChecking -ErrorAction Stop

$script:SourceOfferKeys = 'Name', 'Version', 'Url', 'Archive', 'ArchiveName', 'NoticeDir'

function Assert-SourceOfferComponent {
    param([Parameter(Mandatory)][hashtable]$Component)
    $absent = @($script:SourceOfferKeys | Where-Object { [string]::IsNullOrWhiteSpace([string]$Component[$_]) })
    if ($absent) { throw "source offer component '$($Component['Name'])' lacks $($absent -join ', ')" }
    if ($Component.ArchiveName -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "source offer archive name is unsafe: $($Component.ArchiveName)" }
    if (-not (Test-Path -LiteralPath $Component.Archive -PathType Leaf)) { throw "source offer archive of $($Component.Name) is missing: $($Component.Archive)" }
    $notices = @(Get-NativeNoticeFile -Directory $Component.NoticeDir)
    if ($notices.Count -eq 0) { throw "$($Component.Name) has no licence text at the top of $($Component.NoticeDir)" }
    return $notices
}

function Format-SourceOfferText {
    param([string]$Owner, [object[]]$Record)
    $lines = @("The $Owner binaries in this package were built from these exact sources.",
        'Each file is attached to the release this package came from, under the same name; its SHA-256 identifies it.',
        "The build/ files are the scripts and patches that built them.", '')
    foreach ($row in $Record) {
        $id = if ($row.revision) { "$($row.version) ($($row.revision))" } else { $row.version }
        $lines += "$($row.name) $id", "  file:   $($row.file)", "  sha256: $($row.sha256)", "  from:   $($row.url)", ''
    }
    return $lines -join "`n"
}

function Copy-SourceOfferFile {
    param([string]$From, [string]$Directory, [string]$Name)
    $target = Join-Path $Directory $Name
    Copy-Item -LiteralPath $From -Destination $target -Force
    return (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
}

<#
.SYNOPSIS
    Copies each component's licence texts and source archive under Root, writes the offer and proves a manifest over File.
.PARAMETER Component
    Hashtables with Name, Version, Url, Archive (the exact archive built from), ArchiveName and NoticeDir; optionally Sha256 and Revision.
    The first one is the binaries' own source.
.PARAMETER BuildFile
    The scripts and patches that built them, shipped under share\sources\<Owner>\build.
.OUTPUTS
    The written manifest's path, Root\provenance\<Owner>.json.
#>
function Publish-NativeSourceOffer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Root,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Owner,
        [Parameter(Mandatory)][string[]]$File,
        [Parameter(Mandatory)][hashtable[]]$Component,
        [Parameter(Mandatory)][string[]]$BuildFile
    )
    # ValidatePattern ignores case, and the owner names files a case-sensitive reader looks up.
    if ($Owner -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw "source offer owner must be lower-case kebab: $Owner" }
    $offerDir = Join-Path $Root "share\sources\$Owner"
    if (Test-Path -LiteralPath $offerDir) { Remove-Item -LiteralPath $offerDir -Recurse -Force }
    $buildDir = Join-Path $offerDir 'build'
    $null = New-Item -ItemType Directory -Force -Path $buildDir
    $notices = [Collections.Generic.List[string]]::new()
    $records = @(foreach ($part in $Component) {
            $texts = @(Assert-SourceOfferComponent -Component $part)
            $notices.AddRange([string[]]@(Copy-NativeNotice -Root $Root -NoticeDir 'licenses' -Name $part.Name -File $texts.FullName))
            [ordered]@{ name = $part.Name; version = $part.Version; revision = [string]$part['Revision']; url = $part.Url
                file = "share/sources/$Owner/$($part.ArchiveName)"; sha256 = (Copy-SourceOfferFile -From $part.Archive -Directory $offerDir -Name $part.ArchiveName) }
        })
    $build = @(foreach ($path in $BuildFile) {
            $leaf = Split-Path -Leaf $path
            [ordered]@{ file = "share/sources/$Owner/build/$leaf"; sha256 = (Copy-SourceOfferFile -From $path -Directory $buildDir -Name $leaf) }
        })
    $offer = @{ 'sources.json' = (ConvertTo-Json -Depth 5 -InputObject ([ordered]@{ owner = $Owner; schema = 1; sources = $records; build = $build }))
        'SOURCE-OFFER.txt' = (Format-SourceOfferText -Owner $Owner -Record $records) }
    $offer.GetEnumerator() | ForEach-Object { Set-Content -LiteralPath (Join-Path $offerDir $_.Key) -Value $_.Value -Encoding utf8NoBOM }
    $notices.AddRange([string[]]@("share\sources\$Owner\sources.json", "share\sources\$Owner\SOURCE-OFFER.txt"))
    $first = $Component[0]
    $identity = @{ Name = $first.Name; Version = $first.Version; Url = $first.Url; Sha256 = $records[0].sha256; Revision = [string]$first['Revision'] }
    $entries = @(foreach ($binary in $File) { New-NativeProvenanceEntry -Root $Root -File $binary -Source $identity -Notice $notices.ToArray() })
    $manifest = Join-Path $Root "provenance\$Owner.json"
    Write-NativeProvenanceManifest -Path $manifest -Owner $Owner -Entry $entries -Root $Root -RequiredFile $File
    return $manifest
}

<#
.SYNOPSIS
    What no longer holds: the manifest over the binaries and texts, and every offered source and build file against its recorded hash.
#>
function Get-NativeSourceOfferFinding {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Owner, [string[]]$RequiredFile = @())
    $findings = @(Get-NativeProvenanceFinding -Path (Join-Path $Root "provenance\$Owner.json") -Root $Root -RequiredFile $RequiredFile)
    $offer = Join-Path $Root "share\sources\$Owner\sources.json"
    if (-not (Test-Path -LiteralPath $offer -PathType Leaf)) { return [string[]]($findings + "no source offer at $offer") }
    $record = Get-Content -LiteralPath $offer -Raw | ConvertFrom-Json
    if (@($record.sources).Count -eq 0) { $findings += "$offer offers no source" }
    $offered = @($record.sources) + @($record.build)
    $findings += @(foreach ($item in $offered) {
            # Inside switch, $_ is the switch value, so the row needs its own name.
            $state = switch ($true) {
                ([string]::IsNullOrWhiteSpace($item.file) -or [IO.Path]::IsPathRooted($item.file) -or '..' -in ($item.file -split '[\\/]')) { 'outside the root'; break }
                (-not (Test-Path -LiteralPath (Join-Path $Root $item.file) -PathType Leaf)) { 'absent'; break }
                ((Get-FileHash -LiteralPath (Join-Path $Root $item.file) -Algorithm SHA256).Hash -ine $item.sha256) { 'not the archived bytes'; break }
            }
            if ($state) { "offered $($item.file): $state" }
        })
    return [string[]]$findings
}

Export-ModuleMember -Function Publish-NativeSourceOffer, Get-NativeSourceOfferFinding
