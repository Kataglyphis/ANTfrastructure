#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The fake image prefix the source offer suites share: one binary, two components, one build script.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Writes a prefix under -Dir and returns Publish-NativeSourceOffer's arguments for it.
#>
function New-SourceOfferFixture {
    param([Parameter(Mandatory)][string]$Dir)
    # Relative path -> content; every file the offer reads, under -Dir.
    $layout = [ordered]@{ 'prefix/bin/avcodec-63.dll' = 'MZ avcodec'; 'Build-Demo.ps1' = '# build' }
    foreach ($name in 'ffmpeg', 'x264') {
        $layout["$name-src/COPYING.GPLv3"] = "$name GPLv3 text"
        $layout["$name-src/README"] = 'not a licence'
        $layout["$name-download.tar.gz"] = "$name source bytes"
    }
    foreach ($rel in $layout.Keys) {
        $file = [IO.Path]::Combine($Dir, $rel)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
        [IO.File]::WriteAllText($file, $layout[$rel])
    }
    $parts = @('ffmpeg', 'x264' | ForEach-Object {
            @{ Name = $_; Version = '1.0'; Url = "https://example.invalid/$_.tar.gz"; Archive = [IO.Path]::Combine($Dir, "$_-download.tar.gz")
                ArchiveName = "$_-1.0.tar.gz"; NoticeDir = [IO.Path]::Combine($Dir, "$_-src") }
        })
    return @{ Root = [IO.Path]::Combine($Dir, 'prefix'); Owner = 'ffmpeg'; File = @('bin\avcodec-63.dll'); Component = $parts
        BuildFile = @([IO.Path]::Combine($Dir, 'Build-Demo.ps1')) }
}

Export-ModuleMember -Function New-SourceOfferFixture
