# Tests for Copy-BuildArtifact (stage built files by extension into an install layout) and
# Get-SourceBuildVersion -StripVPrefix. Copy-BuildArtifact drives the manual-install step in
# build-litert / build-onnx-genai (upstreams whose cmake --install is a no-op), so a regression
# would silently ship an incomplete install tree.

Describe 'Copy-BuildArtifact' {

    It 'copies by extension into the mapped dest dirs, creating them, skipping unmatched files' {
        $dir = New-TestDir
        $bd = Join-Path $dir 'build'; New-Item -ItemType Directory -Path $bd | Out-Null
        Set-Content (Join-Path $bd 'a.dll') 'x' -Encoding ASCII
        Set-Content (Join-Path $bd 'b.lib') 'x' -Encoding ASCII
        Set-Content (Join-Path $bd 'c.txt') 'x' -Encoding ASCII
        $inst = Join-Path $dir 'install'
        Copy-BuildArtifact -BuildDir $bd -InstallDir $inst -Map @(
            @{ Filter = '*.dll'; Dest = 'bin' }
            @{ Filter = '*.lib'; Dest = 'lib' }
        )
        Assert-True  (Test-Path (Join-Path $inst 'bin\a.dll')) 'dll routed to bin (dir auto-created)'
        Assert-True  (Test-Path (Join-Path $inst 'lib\b.lib')) 'lib routed to lib'
        Assert-False (Test-Path (Join-Path $inst 'bin\c.txt')) 'unmatched file not copied'
    }

    It 'recurses only when -Recurse is set' {
        $dir = New-TestDir
        $bd = Join-Path $dir 'build'; $sub = Join-Path $bd 'sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content (Join-Path $bd 'top.dll') 'x' -Encoding ASCII
        Set-Content (Join-Path $sub 'deep.dll') 'x' -Encoding ASCII
        $flat = Join-Path $dir 'flat'; $deep = Join-Path $dir 'deep'
        Copy-BuildArtifact -BuildDir $bd -InstallDir $flat -Map @(@{ Filter = '*.dll'; Dest = 'bin' })
        Assert-True  (Test-Path (Join-Path $flat 'bin\top.dll'))  'top-level dll copied without -Recurse'
        Assert-False (Test-Path (Join-Path $flat 'bin\deep.dll')) 'nested dll NOT copied without -Recurse'
        Copy-BuildArtifact -BuildDir $bd -InstallDir $deep -Recurse -Map @(@{ Filter = '*.dll'; Dest = 'bin' })
        Assert-True  (Test-Path (Join-Path $deep 'bin\deep.dll')) 'nested dll copied with -Recurse'
    }

    It 'accepts multiple filters routed to one dest' {
        $dir = New-TestDir
        $bd = Join-Path $dir 'build'; New-Item -ItemType Directory -Path $bd | Out-Null
        Set-Content (Join-Path $bd 'x.lib') 'x' -Encoding ASCII
        Set-Content (Join-Path $bd 'y.dll') 'x' -Encoding ASCII
        $inst = Join-Path $dir 'install'
        Copy-BuildArtifact -BuildDir $bd -InstallDir $inst -Map @(@{ Filter = @('*.lib', '*.dll'); Dest = 'lib' })
        Assert-True (Test-Path (Join-Path $inst 'lib\x.lib')) 'lib copied'
        Assert-True (Test-Path (Join-Path $inst 'lib\y.dll')) 'dll copied to the same dest'
    }
}

Describe 'Remove-MakefileShowIncludes' {

    It 'strips /showIncludes and the awk dep pipeline, keeping unrelated lines' {
        $dir = New-TestDir
        $mk = Join-Path $dir 'library.mak'
        Set-Content $mk "cc -showIncludes foo.c | awk '/including/' > foo.d`nother line" -Encoding ASCII
        Remove-MakefileShowIncludes -Path $mk
        $out = Get-Content $mk -Raw
        Assert-False ($out -match 'showIncludes') '/showIncludes removed'
        Assert-Match 'other line' $out 'unrelated lines preserved'
    }

    It 'drops the wildcard-include line only with -StripWildcardInclude' {
        $dir = New-TestDir
        $a = Join-Path $dir 'a.mak'; $b = Join-Path $dir 'b.mak'
        $line = '-include $(wildcard *.d) # dep tracking'
        Set-Content $a $line -Encoding ASCII
        Set-Content $b $line -Encoding ASCII
        Remove-MakefileShowIncludes -Path $a
        Remove-MakefileShowIncludes -Path $b -StripWildcardInclude
        Assert-Match 'wildcard' (Get-Content $a -Raw) 'wildcard include kept without the switch (ffbuild/*.mak fragments)'
        Assert-False ((Get-Content $b -Raw) -match 'wildcard') 'wildcard include dropped with the switch (top-level makefiles)'
    }

    It 'is a no-op for a missing path' {
        Remove-MakefileShowIncludes -Path (Join-Path (New-TestDir) 'nope.mak')
        Assert-True $true 'no throw on a missing file'
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
