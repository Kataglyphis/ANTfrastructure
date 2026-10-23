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
