#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# repro-llvm-aarch64-layout.ps1 decides whether a candidate clang-cl lets this
# repo DELETE the two #135 workarounds from build-opencv-from-source.ps1. That
# makes its command-line surgery load-bearing in an unusual direction: if
# Get-CodegenFlags leaves either workaround spelling in the flag list, the
# "workaround OFF" arm is not off, the control compiles clean, and the harness
# reports a compiler fix that does not exist. A false green here retires a
# workaround that is still needed and breaks the arm64 lane.
#
# So the stripping is pinned against the REAL failing command line, captured
# verbatim from the 2026-08-26 cross build (out/windows-build-logs/
# bk-20260826-192841-Dockerfile.media-builder-media-core-built-opencv.log,
# the median_blur.dispatch.cpp.obj FAILED line). out/ is gitignored, so the
# fixture is embedded rather than read -- CI has no build logs.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -Force

$script:Target = 'aarch64-pc-windows-msvc'
. (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\diagnostics\repro-llvm-aarch64-layout.ps1' `
        -FunctionName 'Split-CommandLine', 'Get-CodegenFlags')

# Get-CodegenFlags reads $Target from its enclosing scope, as it does in the script.
$Target = $script:Target

# One line, verbatim. Note it carries the jump-table workaround in its -mllvm
# form -- that run predates the switch to +force-32bit-jump-tables -- which is
# precisely why both spellings have to be stripped.
$script:RealCommand = 'C:\Users\ContainerAdministrator\.cargo\bin\sccache.exe C:\Users\ContainerAdministrator\scoop\apps\llvm\current\bin\clang-cl.exe --target=aarch64-pc-windows-msvc  /nologo -TP -DCVAPI_EXPORTS -DHAVE_STDARG_H=1 -DVK_NO_PROTOTYPES -D_USE_MATH_DEFINES -D_VARIADIC_MAX=10 -D_WIN32_WINNT=0x0601 -D__OPENCV_BUILD=1 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -IC:\temp\opencv-src\opencv\3rdparty\dlpack\include -IC:\temp\opencv-src\opencv\3rdparty\include -IC:\temp\opencv-src\opencv\modules\imgproc\include -IC:\temp\opencv-src\build\modules\imgproc -IC:\temp\opencv-src\opencv\modules\core\include -IC:\temp\opencv-src\opencv\modules\flann\include -IC:\temp\opencv-src\opencv\modules\geometry\include -IC:\temp\opencv-src\opencv\3rdparty\zlib -IC:\temp\opencv-src\build\3rdparty\zlib -imsvcC:\temp\opencv-src\build /FIcstring -Wno-unused-parameter -Wno-documentation-unknown-command -Wno-deprecated-copy -Wno-undef -Wno-missing-field-initializers --target=aarch64-pc-windows-msvc /D_USE_MATH_DEFINES -mllvm -aarch64-enable-compress-jump-tables=false  /D _CRT_SECURE_NO_DEPRECATE /D _CRT_NONSTDC_NO_DEPRECATE /D _SCL_SECURE_NO_WARNINGS /Gy /bigobj /D _ARM64_DISTINCT_NEON_TYPES /Oi  /fp:precise -W -Wreturn-type -Wnon-virtual-dtor -Waddress -Wsequence-point -Wformat -Wformat-security -Wmissing-declarations -Wmissing-prototypes -Wstrict-prototypes -Wundef -Winit-self -Wpointer-arith -Wshadow -Wsign-promo -Wuninitialized -Winconsistent-missing-override -Wno-delete-non-virtual-dtor -Wno-unnamed-type-template-args -Wno-comment -Wno-deprecated-enum-enum-conversion -Wno-deprecated-anon-enum-enum-conversion -Qunused-arguments /FS  /EHa /wd4127 /wd4251 /wd4324 /wd4275 /wd4512 /wd4589 /wd4819  /O2 /Ob2 /DNDEBUG  -DNDEBUG -std:c++17 -MD -clang:-MD -clang:-MTmodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj -clang:-MFmodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj.d /Fomodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj /Fdlib\opencv_imgproc500.pdb -c -- C:\temp\opencv-src\opencv\modules\imgproc\src\median_blur.dispatch.cpp'

$script:Flags = @(Get-CodegenFlags -Tokens (Split-CommandLine -Line $script:RealCommand))

Describe 'llvm135 repro harness: tokenizing the real ninja command' {

    It 'splits the captured line into the expected token count' {
        Assert-True ($script:RealCommand.Length -gt 2000) 'fixture truncated'
        $tokens = @(Split-CommandLine -Line $script:RealCommand)
        Assert-True ($tokens.Count -gt 80) "expected >80 tokens, got $($tokens.Count)"
        Assert-Equal 'clang-cl.exe' ([IO.Path]::GetFileName($tokens[1]))
    }

    It 'keeps a quoted token with spaces intact' {
        $tokens = @(Split-CommandLine -Line 'clang-cl.exe "-IC:\Program Files\x" /O2')
        Assert-Equal 3 $tokens.Count
        Assert-Equal '-IC:\Program Files\x' $tokens[1]
    }
}

Describe 'llvm135 repro harness: what Get-CodegenFlags must STRIP' {

    It 'drops the compiler and the sccache wrapper' {
        Assert-True (-not ($script:Flags -match '\.exe$')) 'an executable survived into the flag list'
    }

    It 'drops everything the preprocessor already consumed' {
        foreach ($pattern in @('^[-/]I', '^[-/]D', '^-imsvc', '^[-/]FI')) {
            Assert-True (-not ($script:Flags -cmatch $pattern)) "flag matching $pattern survived"
        }
    }

    It 'drops the VALUE of a separated /D, not just the /D' {
        # OpenCV passes `/D _CRT_SECURE_NO_DEPRECATE` as two tokens. Dropping only
        # the switch leaves the name behind as a positional argument, and clang-cl
        # reads positional arguments as INPUT FILES. Measured: this is how the
        # function first went wrong.
        Assert-True (-not ($script:Flags -contains '_CRT_SECURE_NO_DEPRECATE')) 'bare define leaked'
        Assert-True (-not ($script:Flags -contains '_ARM64_DISTINCT_NEON_TYPES')) 'bare define leaked'
    }

    It 'leaves no positional argument of any kind' {
        $positional = @($script:Flags | Where-Object { $_ -notmatch '^[-/]' })
        Assert-True ($positional.Count -eq 0) "positional token(s) survived: $($positional -join ', ')"
    }

    It 'drops dependency generation, output naming, the compile verb and the source' {
        Assert-True (-not ($script:Flags -match '^-clang:-M')) 'dep-gen survived'
        Assert-True (-not ($script:Flags -cmatch '^[-/]F[od]')) 'output naming survived'
        Assert-True (-not ($script:Flags -ccontains '-c')) 'compile verb survived'
        Assert-True (-not ($script:Flags -match '\.(cpp|cc)$')) 'source path survived'
    }

    It 'drops the optimisation and inlining levels, which the arms set' {
        Assert-True (-not ($script:Flags -cmatch '^[-/]O[0-9]')) '/O level survived'
        Assert-True (-not ($script:Flags -cmatch '^[-/]Ob[0-3]$')) '/Ob level survived'
    }
}

Describe 'llvm135 repro harness: the workaround must not survive into the OFF arm' {

    It 'strips the -mllvm spelling of the jump-table workaround' {
        Assert-True (-not ($script:Flags -match 'compress-jump-tables')) '-mllvm workaround survived'
    }

    It 'leaves no orphaned -mllvm whose value was consumed' {
        Assert-True (-not ($script:Flags -ccontains '-mllvm')) 'dangling -mllvm survived'
    }

    It 'strips the target-feature spelling of the jump-table workaround' {
        $withFeature = $script:RealCommand + ' -Xclang -target-feature -Xclang +force-32bit-jump-tables'
        $flags = @(Get-CodegenFlags -Tokens (Split-CommandLine -Line $withFeature))
        Assert-True (-not ($flags -match 'force-32bit-jump-tables')) 'target-feature workaround survived'
        Assert-True (-not ($flags -ccontains '-target-feature')) 'orphaned -target-feature survived'
        Assert-True (-not ($flags -ccontains '-Xclang')) 'orphaned -Xclang survived'
    }
}

Describe 'llvm135 repro harness: what must be KEPT, because it shapes the layout' {

    It 'sets the aarch64 target exactly once' {
        Assert-Equal 1 (@($script:Flags -match '^--target=').Count)
        Assert-True ($script:Flags -contains '--target=aarch64-pc-windows-msvc') 'target not aarch64'
    }

    It 'keeps /EHa -- exception handling changes function layout, the subject of #135' {
        Assert-True ($script:Flags -ccontains '/EHa') '/EHa dropped'
    }

    It 'keeps /fp:precise, which the case-insensitive /F[odip] rule used to eat' {
        # -match is case-INSENSITIVE, so '^[-/]F[odip]' also matches /fp:precise.
        # Only -cmatch separates /Fo from /fp. This assertion is the regression pin.
        Assert-True ($script:Flags -ccontains '/fp:precise') '/fp:precise was stripped as an output flag'
    }

    It 'keeps the remaining codegen-relevant flags' {
        foreach ($flag in @('/Gy', '/bigobj', '/Oi', '-std:c++17', '-MD', '-TP')) {
            Assert-True ($script:Flags -ccontains $flag) "$flag dropped"
        }
    }
}
