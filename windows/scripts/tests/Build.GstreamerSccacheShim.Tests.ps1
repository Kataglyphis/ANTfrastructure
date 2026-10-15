#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Hub #182: meson dropped 'sccache' in front of clang-cl, so GStreamer compiled cold on every merge rebuild.

Describe 'Build-GstreamerFromSource: meson compiles through the sccache shim (hub #182)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -FunctionName 'New-SccacheCompilerShim')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -FunctionName 'Format-MesonExeList')
    $script:GstText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-GstreamerFromSource.ps1'))

    It 'writes a shim that runs the named sccache on the named compiler, builds it for the x64 host with LIB cleared, and restores LIB (mutation)' {
        Invoke-InTestDir { param($d)
            # A stand-in compiler: records the LIB it saw and its arguments, and leaves an exe where /Fe points.
            $fakeCompiler = @'
$out = "$args" -replace '.*/Fe(\S+).*', '$1'
[IO.File]::WriteAllText($out, 'exe')
[IO.File]::WriteAllLines("$PSScriptRoot\seen.txt", [string[]](@("LIB=[$env:LIB]") + $args))
exit 0
'@
            Set-Content -LiteralPath "$d\fake-cc.ps1" -Value $fakeCompiler
            $callerLib = $env:LIB
            $env:LIB = 'C:\target\arm64\lib'
            try {
                $exe = New-SccacheCompilerShim -Sccache 'C:\Users\X\.cargo\bin\sccache.exe' -Compiler "$d\fake-cc.ps1" -OutDir "$d\shim" 6>$null
                Assert-Equal 'C:\target\arm64\lib' $env:LIB 'the caller''s LIB is back'
            } finally { $env:LIB = $callerLib }
            Assert-Equal "$d\shim\clang-cl.exe" $exe 'meson must see a compiler named clang-cl'
            $seen = [IO.File]::ReadAllLines("$d\seen.txt")
            Assert-Equal 'LIB=[]' $seen[0] 'built without the target''s libraries'
            Assert-True ($seen -contains '--target=x86_64-pc-windows-msvc') 'an x64 host exe on every lane'
            Assert-True ($seen -contains '-fuse-ld=lld') 'lld-link finds the host libraries itself'
            $c = [IO.File]::ReadAllText("$d\shim\sccache-shim.c")
            Assert-True $c.Contains('sccache[] = L"C:\\Users\\X\\.cargo\\bin\\sccache.exe"') 'the sccache path, escaped for C'
            Assert-True $c.Contains('L"\"%ls\" \"%ls\" %ls", sccache, compiler, p') 'sccache, then the compiler, then the caller''s arguments'
            Assert-True $c.Contains('return (int)code;') 'the compile''s exit code is meson''s'
        }
    }

    It 'hands meson the shim, never ''sccache clang-cl'', and fails a build sccache barely saw' {
        Assert-False ($script:GstText -match "\`$env:CC\s*=\s*'sccache clang-cl'") 'the prefix meson drops'
        Assert-Match "\`$env:CC  = \`$shim\s*\r?\n\s*\`$env:CXX = \`$shim\s*\r?\n\s*\`$script:GstSccacheShim = \`$shim" $script:GstText 'C and C++ through the shim'
        Assert-Match "New-SccacheCompilerShim -Sccache \(Get-Command sccache\.exe\)\.Source -Compiler \`$clangCheck\.Source" $script:GstText 'the clang-cl PATH resolves, the patched one'
        Assert-Match "\[int\]\`$requests\.Groups\[1\]\.Value -lt 100\) \{\s*\r?\n\s*throw `"sccache counted" $script:GstText 'a bypass fails the stage'
    }

    It 'keeps the one-word shim a list in the meson files, so --target stays its own entry (mutation)' {
        # 2026-10-15: the arm64 cross file read c = ['C:/temp/gst-sccache-shim/clang-cl.exe--target=aarch64-pc-windows-msvc'].
        Assert-Equal "'C:/temp/gst-sccache-shim/clang-cl.exe', '--target=aarch64-pc-windows-msvc'" `
            (Format-MesonExeList -Command 'C:\temp\gst-sccache-shim\clang-cl.exe' -Extra '--target=aarch64-pc-windows-msvc') 'the shim and the target, two entries'
        Assert-Equal "'sccache', 'clang-cl', '--target=aarch64-pc-windows-msvc'" `
            (Format-MesonExeList -Command ' sccache  clang-cl ' -Extra '--target=aarch64-pc-windows-msvc') 'every word its own entry'
        Assert-Equal "'clang-cl'" (Format-MesonExeList -Command 'clang-cl') 'the native file, no target'
        foreach ($list in 'ccList', 'cxxList', 'nccList', 'ncxxList') {
            Assert-Match "\`$$list = Format-MesonExeList -Command " $script:GstText "$list goes through the helper"
        }
    }
}
