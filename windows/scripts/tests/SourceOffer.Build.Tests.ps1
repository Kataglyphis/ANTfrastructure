#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real FFmpeg build; fake source trees, archives and a DLL stand in for its outputs.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceOffer.Build.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceOffer.Fixture.psm1') -Force -DisableNameChecking

Describe 'Publish-NativeSourceOffer: texts, sources and a manifest beside the binaries' {
    It 'ships every component''s licence and archive, names them in the offer, and the finding catches each change' {
        Invoke-InTestDir { param($dir)
            $offer = New-SourceOfferFixture -Dir $dir
            $manifest = Publish-NativeSourceOffer @offer
            $root = $offer.Root
            Assert-Equal (Join-Path $root 'provenance\ffmpeg.json') $manifest
            foreach ($rel in 'licenses\ffmpeg\COPYING.GPLv3', 'licenses\x264\COPYING.GPLv3', 'share\sources\ffmpeg\ffmpeg-1.0.tar.gz',
                'share\sources\ffmpeg\x264-1.0.tar.gz', 'share\sources\ffmpeg\build\Build-Demo.ps1', 'share\sources\ffmpeg\SOURCE-OFFER.txt') {
                Assert-True (Test-Path -LiteralPath (Join-Path $root $rel) -PathType Leaf) "$rel is shipped"
            }
            Assert-False (Test-Path -LiteralPath (Join-Path $root 'licenses\ffmpeg\README')) 'only licence texts are copied'
            $entry = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).entries[0]
            Assert-Equal 'ffmpeg' $entry.source.name 'the first component is the binary''s own source'
            Assert-True (@($entry.notices.path) -contains 'share\sources\ffmpeg\SOURCE-OFFER.txt') 'the offer travels with the notices'
            Assert-Match 'x264 1\.0\s+file:\s+share/sources/ffmpeg/x264-1\.0\.tar\.gz' (Get-Content -LiteralPath (Join-Path $root 'share\sources\ffmpeg\SOURCE-OFFER.txt') -Raw)
            Assert-Equal 0 @(Get-NativeSourceOfferFinding -Root $root -Owner 'ffmpeg' -RequiredFile 'bin\avcodec-63.dll').Count 'an intact offer has no finding'

            # Each change after the build, with the finding it must raise.
            $changes = @(
                @{ Expect = 'offered share/sources/ffmpeg/x264-1.0.tar.gz: not the archived bytes'; Do = { Set-Content -LiteralPath (Join-Path $root 'share\sources\ffmpeg\x264-1.0.tar.gz') -Value 'other' } },
                @{ Expect = 'offered share/sources/ffmpeg/build/Build-Demo.ps1: absent'; Do = { Remove-Item -LiteralPath (Join-Path $root 'share\sources\ffmpeg\build\Build-Demo.ps1') } },
                @{ Expect = 'COPYING.GPLv3'; Do = { Set-Content -LiteralPath (Join-Path $root 'licenses\x264\COPYING.GPLv3') -Value 'edited' } },
                @{ Expect = 'no source offer at'; Do = { Remove-Item -LiteralPath (Join-Path $root 'share\sources\ffmpeg\sources.json') } })
            foreach ($change in $changes) {
                $null = Publish-NativeSourceOffer @offer
                & $change.Do
                Assert-Match ([regex]::Escape($change.Expect)) (@(Get-NativeSourceOfferFinding -Root $root -Owner 'ffmpeg') -join '; ')
            }
        }
    }

    It 'refuses a component without a licence text, without its archive or with an unsafe archive name' {
        Invoke-InTestDir { param($dir)
            $offer = New-SourceOfferFixture -Dir $dir
            $broken = @(
                @{ Expect = 'has no licence text'; Edit = { param($c) Remove-Item -LiteralPath (Join-Path $c.NoticeDir 'COPYING.GPLv3') } },
                @{ Expect = 'archive of x264 is missing'; Edit = { param($c) $c.Archive = Join-Path $dir 'absent.tar.gz' } },
                @{ Expect = 'archive name is unsafe'; Edit = { param($c) $c.ArchiveName = '..\escape.tar.gz' } },
                @{ Expect = 'lacks Url'; Edit = { param($c) $c.Remove('Url') } })
            foreach ($case in $broken) {
                $fresh = New-SourceOfferFixture -Dir (Join-Path $dir ([guid]::NewGuid().ToString('N')))
                & $case.Edit $fresh.Component[1]
                Assert-Throws { Publish-NativeSourceOffer @fresh } -MessagePattern $case.Expect
            }
            $none = $offer.Clone(); $none.Owner = 'FFmpeg'
            Assert-Throws { Publish-NativeSourceOffer @none } -MessagePattern 'owner must be lower-case kebab'
        }
    }
}
