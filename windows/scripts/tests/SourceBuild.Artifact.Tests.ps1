#requires -Version 7.0
# Copy-BuildArtifact is the install for upstreams whose cmake --install is a no-op, so a regression ships an incomplete tree.

Describe 'Copy-BuildArtifact' {
    function Invoke-ArtifactCopyFixture {
        param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$File,
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][hashtable[]]$Case, [string]$CopyCommand = 'Copy-BuildArtifact')
        Invoke-InTestDir { param($dir)
            $build = Join-Path $dir 'build'
            foreach ($relative in $File) {
                $path = Join-Path $build $relative
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
                Set-Content -LiteralPath $path -Value x -Encoding ASCII
            }
            foreach ($copyCase in $Case) {
                if (-not $copyCase.Present -and -not $copyCase.Absent) { throw 'an artifact-copy fixture needs an expected outcome' }
                $install = Join-Path $dir $copyCase.Name
                & $CopyCommand -BuildDir $build -InstallDir $install -Recurse:$copyCase.Recurse -Map $copyCase.Map
                foreach ($relative in $copyCase.Present) {
                    Assert-True (Test-Path (Join-Path $install $relative)) "copied artifact missing: $relative"
                }
                foreach ($relative in $copyCase.Absent) {
                    Assert-False (Test-Path (Join-Path $install $relative)) "unrequested artifact copied: $relative"
                }
            }
        }
    }

    $copyCases = @(
        @{ Name = 'copies by extension into the mapped dest dirs, creating them, skipping unmatched files'
            File = @('a.dll', 'b.lib', 'c.txt')
            Plans = @(@{ Name = 'install'; Recurse = $false
                    Map = @(@{ Filter = '*.dll'; Dest = 'bin' }, @{ Filter = '*.lib'; Dest = 'lib' })
                    Present = @('bin/a.dll', 'lib/b.lib'); Absent = @('bin/c.txt') }) }
        @{ Name = 'recurses only when -Recurse is set'; File = @('top.dll', 'sub/deep.dll')
            Plans = @(
                @{ Name = 'flat'; Recurse = $false; Map = @(@{ Filter = '*.dll'; Dest = 'bin' })
                    Present = @('bin/top.dll'); Absent = @('bin/deep.dll') }
                @{ Name = 'deep'; Recurse = $true; Map = @(@{ Filter = '*.dll'; Dest = 'bin' })
                    Present = @('bin/top.dll', 'bin/deep.dll'); Absent = @() }
            ) }
        @{ Name = 'accepts multiple filters routed to one dest'; File = @('x.lib', 'y.dll')
            Plans = @(@{ Name = 'install'; Recurse = $false; Map = @(@{ Filter = @('*.lib', '*.dll'); Dest = 'lib' })
                    Present = @('lib/x.lib', 'lib/y.dll'); Absent = @() }) }
    )
    foreach ($copyCase in $copyCases) {
        It $copyCase.Name { Invoke-ArtifactCopyFixture -File $copyCase.File -Case $copyCase.Plans }
    }

    It 'detects a copy mutant that recurses despite an omitted switch' {
        $definition = (Get-Command Copy-BuildArtifact).Definition
        $source = "function Copy-BuildArtifact {`n$definition`n}"
        $fixture = (Get-Command Invoke-ArtifactCopyFixture).ScriptBlock
        $flatCase = $copyCases[1].Plans[0]
        Invoke-WithFunctionModule -Text $source -FunctionName Copy-BuildArtifact -Find '-Recurse:$Recurse' -Replace '-Recurse' -Body ({
            Assert-Throws {
                & $fixture -File top.dll, sub/deep.dll -Case $flatCase -CopyCommand Copy-MutBuildArtifact
            } -MessagePattern 'unrequested artifact copied'
        }.GetNewClosure())
    }

}

Describe 'Remove-MakefileShowIncludes' {
    # AST-extracted from its only consumer: dot-sourcing Build-FfmpegFromSource.ps1 would start a build.
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-FfmpegFromSource.ps1' -FunctionName 'Remove-MakefileShowIncludes')

    It 'strips /showIncludes and the awk dep pipeline, keeping unrelated lines' {
        Invoke-InTestDir { param($dir)
            $mk = Join-Path $dir 'library.mak'
            Set-Content $mk "cc -showIncludes foo.c | awk '/including/' > foo.d`nother line" -Encoding ASCII
            Remove-MakefileShowIncludes -Path $mk
            $out = Get-Content $mk -Raw
            Assert-False ($out -match 'showIncludes') '/showIncludes removed'
            Assert-Match 'other line' $out 'unrelated lines preserved'
        }
    }

    It 'drops the wildcard-include line only with -StripWildcardInclude' {
        Invoke-InTestDir { param($dir)
            $a = Join-Path $dir 'a.mak'; $b = Join-Path $dir 'b.mak'
            $line = '-include $(wildcard *.d) # dep tracking'
            Set-Content $a $line -Encoding ASCII
            Set-Content $b $line -Encoding ASCII
            Remove-MakefileShowIncludes -Path $a
            Remove-MakefileShowIncludes -Path $b -StripWildcardInclude
            Assert-Match 'wildcard' (Get-Content $a -Raw) 'wildcard include kept without the switch (ffbuild/*.mak fragments)'
            Assert-False ((Get-Content $b -Raw) -match 'wildcard') 'wildcard include dropped with the switch (top-level makefiles)'
        }
    }

    It 'is a no-op for a missing path' {
        Invoke-InTestDir { param($dir)
            Remove-MakefileShowIncludes -Path (Join-Path $dir 'nope.mak')
            Assert-True $true 'no throw on a missing file'
        }
    }
}

Describe 'Assert-FfmpegPkgConfig' {
    # The gate lives in the FFmpeg script, outside the three media branches' compile closure.
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-FfmpegFromSource.ps1' -FunctionName 'Assert-FfmpegPkgConfig')

    # A healthy file, as FFmpeg's configure emits it after the MSYS prefix rewrite.
    function New-TestPc {
        param($Dir, $Name, $Version = '62.11.100', $Prefix = 'C:/runtime/ffmpeg')
        Set-Content (Join-Path $Dir "$Name.pc") @"
prefix=$Prefix
exec_prefix=`${prefix}
libdir=`${prefix}/lib
includedir=`${prefix}/include

Name: $Name
Description: FFmpeg $Name library
Version: $Version
Libs: -L`${libdir} -l$Name
Cflags: -I`${includedir}
"@ -Encoding ASCII
    }
    $allFour = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')

    function Assert-InvalidFfmpegPc {
        param([hashtable]$Replacement, [string]$MessagePattern)
        Invoke-InTestDir { param($dir)
            $allFour | ForEach-Object { New-TestPc -Dir $dir -Name $_ }
            New-TestPc -Dir $dir @Replacement
            Assert-Throws { Assert-FfmpegPkgConfig -PkgConfigDir $dir } -MessagePattern $MessagePattern
        }
    }


    It 'passes and reports versions when all four modules are well-formed' {
        Invoke-InTestDir { param($dir)
            $allFour | ForEach-Object { New-TestPc -Dir $dir -Name $_ }
            $result = Assert-FfmpegPkgConfig -PkgConfigDir $dir
            Assert-True ($result.Contains('libavcodec')) 'returns the parsed versions'
            Assert-Match '62\.11\.100' $result['libavfilter'] 'version parsed off the Version: line'
        }
    }

    It 'throws when the pkgconfig directory does not exist at all' {
        # A missing directory is the total failure and must not pass silently.
        Invoke-InTestDir { param($dir)
            Assert-Throws -Body { Assert-FfmpegPkgConfig -PkgConfigDir (Join-Path $dir 'nope') } `
                -MessagePattern 'no pkgconfig directory' `
                -Message 'a missing pkgconfig dir is a hard failure, not a skip'
        }
    }

    It 'throws on the empty "Version: .." configure emits without a VERSION file' {
        Assert-InvalidFfmpegPc -Replacement @{ Name = 'libavcodec'; Version = '..' } -MessagePattern 'unusable version'
    }

    It 'throws when an MSYS prefix survived the rewrite' {
        Assert-InvalidFfmpegPc -Replacement @{ Name = 'libavutil'; Prefix = '/c/runtime/ffmpeg' } -MessagePattern 'MSYS prefix'
    }

    It 'throws when one of the four modules is missing entirely' {
        Invoke-InTestDir { param($dir)
            @('libavcodec', 'libavformat', 'libavutil') | ForEach-Object { New-TestPc -Dir $dir -Name $_ }
            Assert-Throws -Body { Assert-FfmpegPkgConfig -PkgConfigDir $dir } `
                -MessagePattern 'no libavfilter\.pc' -Message 'missing module rejected'
        }
    }
}

Describe 'Assert-FfmpegTarballStream / Get-FfmpegSourceTree (the FFMPEG_SHA256 pin)' {

    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-FfmpegFromSource.ps1' -FunctionName 'Assert-FfmpegTarballStream', 'Get-FfmpegSourceTree')

    $script:ffPayload = [Text.Encoding]::ASCII.GetBytes('ffmpeg-n9.0.2/configure' * 512)
    $script:ffStreamSha = (Get-FileHash -InputStream ([IO.MemoryStream]::new($script:ffPayload)) -Algorithm SHA256).Hash.ToLowerInvariant()

    function New-FfTestGzip([string]$Path, [string]$Level = 'Optimal') {
        $gz = [IO.Compression.GZipStream]::new([IO.File]::Create($Path), [IO.Compression.CompressionLevel]$Level)
        try { [IO.MemoryStream]::new($script:ffPayload).CopyTo($gz) } finally { $gz.Dispose() }
    }

    # Stubs record the order, so a refused archive is seen never to reach the extract.
    function Invoke-FfSourceTreeFixture([string]$Version, [string]$Sha256) {
        Invoke-InTestDir { param($dir)
            $script:ffCalls = [Collections.Generic.List[string]]::new()
            function Switch-BuildPhase { }
            function Invoke-DownloadWithRetry([string]$Url, [string]$DestinationPath) { $script:ffCalls.Add("download $Url"); New-FfTestGzip $DestinationPath }
            function Expand-SourceTarball([string]$Archive, [string]$Destination) { $script:ffCalls.Add('extract'); $Destination }
            function Initialize-ExtractedGitRepo { }
            $failure = $null
            try { $null = Get-FfmpegSourceTree -FfmpegVersion $Version -SourceDir $dir -tarballPath (Join-Path $dir 'ffmpeg.tar.gz') -Sha256 $Sha256 }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{ Calls = @($script:ffCalls); Failure = $failure }
        }
    }

    It 'reaches the FFmpeg RUN: its stage declares FFMPEG_SHA256 and mirrors it into ENV (mutation)' {
        $facts = Get-TestDockerfileStageFacts -Path (Join-Path (Get-RepoRoot) 'windows/Dockerfile.media-builder')
        Assert-True ($facts['media-core-built-ffmpeg'].Args -ccontains 'FFMPEG_SHA256') 'media-core-built-ffmpeg declares FFMPEG_SHA256'
        Assert-True ($facts['media-core-built-ffmpeg'].EnvMirrored -ccontains 'FFMPEG_SHA256') 'an ARG the RUN cannot read as ENV leaves the script on its baked default'
    }

    It 'hashes the decompressed stream, so a re-gzipped archive of the same tar still matches' {
        Invoke-InTestDir { param($dir)
            foreach ($level in 'Optimal', 'Fastest', 'NoCompression') {
                $path = Join-Path $dir "$level.tar.gz"
                New-FfTestGzip $path $level
                Assert-FfmpegTarballStream -Path $path -Expected $script:ffStreamSha -Tag 'n9.0.2' | Out-Null
            }
            $fileSha = (Get-FileHash -Algorithm SHA256 (Join-Path $dir 'Optimal.tar.gz')).Hash.ToLowerInvariant()
            Assert-Throws { Assert-FfmpegTarballStream -Path (Join-Path $dir 'Optimal.tar.gz') -Expected $fileSha -Tag 'n9.0.2' } `
                -MessagePattern 'is not the pinned one' -Message 'the file hash is not the pin'
        }
    }

    It 'refuses a pin that is empty, short or not lowercase hex' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'a.tar.gz'
            New-FfTestGzip $path
            foreach ($bad in '', 'abc', $script:ffStreamSha.ToUpperInvariant()) {
                Assert-Throws { Assert-FfmpegTarballStream -Path $path -Expected $bad -Tag 'n9.0.2' } -MessagePattern 'must name its archive''s stream hash'
            }
        }
    }

    It 'checks a tag''s archive before extracting it, and stops on a mismatch' {
        $ok = Invoke-FfSourceTreeFixture -Version 'n9.0.2' -Sha256 $script:ffStreamSha
        Assert-Null $ok.Failure 'the pinned archive is accepted'
        Assert-Equal 'download https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n9.0.2.tar.gz|extract' ($ok.Calls -join '|') 'download, then extract'
        $bad = Invoke-FfSourceTreeFixture -Version 'n9.0.2' -Sha256 ('0' * 64)
        Assert-Match 'is not the pinned one' $bad.Failure
        Assert-False ($bad.Calls -contains 'extract') 'a refused archive is never extracted'
    }

    It 'builds a branch unpinned, as Linux does' {
        $branch = Invoke-FfSourceTreeFixture -Version 'master' -Sha256 ''
        Assert-Null $branch.Failure 'a branch needs no hash'
        Assert-True ($branch.Calls -contains 'extract') 'the branch tree is extracted'
    }
}

Describe 'Get-SourceBuildVersion -StripVPrefix' {

    It 'strips a leading v only when the switch is set' {
        Assert-Equal '1.2.3'  (Get-SourceBuildVersion -Value 'v1.2.3' -StripVPrefix) 'v-prefix stripped'
        Assert-Equal 'v1.2.3' (Get-SourceBuildVersion -Value 'v1.2.3')               'v-prefix kept without the switch'
        Assert-Equal '1.2.3'  (Get-SourceBuildVersion -Value '1.2.3' -StripVPrefix)  'no-op when there is no leading v'
    }

    It 'applies the strip to a resolved default value too' {
        Assert-Equal '0.14.0' (Get-SourceBuildVersion -DefaultValue 'v0.14.0' -StripVPrefix) 'default value also stripped'
    }
}
