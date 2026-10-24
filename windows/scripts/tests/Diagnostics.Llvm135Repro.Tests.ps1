#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Fixtures pin command selection and diagnostic output; they do not establish compiler layout behavior.

# Never -Force: it resets the harness result count; probe a harness-only command, since Pester also exports Describe.
if (-not (Get-Command Get-ScriptFunctionDefinition -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1')
}

$script:Target = 'aarch64-pc-windows-msvc'
. (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\diagnostics\Invoke-LlvmAarch64Layout.ps1' `
        -FunctionName 'Split-CommandLine', 'Get-LlvmWorkaroundSkipSpan', 'Get-LlvmPreprocessedSkipSpan',
        'Get-LlvmCompilePlan', 'Get-CodegenFlags', 'Get-LlvmCorpusManifest', 'Get-LlvmVerifiedInput',
        'Get-LlvmCaseResult', 'Write-LlvmOverallVerdict')

# Get-CodegenFlags reads $Target from its enclosing scope, as it does in the script.
$Target = $script:Target

# Verbatim; it carries the older -mllvm jump-table spelling, which is why both spellings must be stripped.
$script:RealCommand = 'C:\Users\ContainerAdministrator\.cargo\bin\sccache.exe C:\Users\ContainerAdministrator\scoop\apps\llvm\current\bin\clang-cl.exe --target=aarch64-pc-windows-msvc  /nologo -TP -DCVAPI_EXPORTS -DHAVE_STDARG_H=1 -DVK_NO_PROTOTYPES -D_USE_MATH_DEFINES -D_VARIADIC_MAX=10 -D_WIN32_WINNT=0x0601 -D__OPENCV_BUILD=1 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -IC:\temp\opencv-src\opencv\3rdparty\dlpack\include -IC:\temp\opencv-src\opencv\3rdparty\include -IC:\temp\opencv-src\opencv\modules\imgproc\include -IC:\temp\opencv-src\build\modules\imgproc -IC:\temp\opencv-src\opencv\modules\core\include -IC:\temp\opencv-src\opencv\modules\flann\include -IC:\temp\opencv-src\opencv\modules\geometry\include -IC:\temp\opencv-src\opencv\3rdparty\zlib -IC:\temp\opencv-src\build\3rdparty\zlib -imsvcC:\temp\opencv-src\build /FIcstring -Wno-unused-parameter -Wno-documentation-unknown-command -Wno-deprecated-copy -Wno-undef -Wno-missing-field-initializers --target=aarch64-pc-windows-msvc /D_USE_MATH_DEFINES -mllvm -aarch64-enable-compress-jump-tables=false  /D _CRT_SECURE_NO_DEPRECATE /D _CRT_NONSTDC_NO_DEPRECATE /D _SCL_SECURE_NO_WARNINGS /Gy /bigobj /D _ARM64_DISTINCT_NEON_TYPES /Oi  /fp:precise -W -Wreturn-type -Wnon-virtual-dtor -Waddress -Wsequence-point -Wformat -Wformat-security -Wmissing-declarations -Wmissing-prototypes -Wstrict-prototypes -Wundef -Winit-self -Wpointer-arith -Wshadow -Wsign-promo -Wuninitialized -Winconsistent-missing-override -Wno-delete-non-virtual-dtor -Wno-unnamed-type-template-args -Wno-comment -Wno-deprecated-enum-enum-conversion -Wno-deprecated-anon-enum-enum-conversion -Qunused-arguments /FS  /EHa /wd4127 /wd4251 /wd4324 /wd4275 /wd4512 /wd4589 /wd4819  /O2 /Ob2 /DNDEBUG  -DNDEBUG -std:c++17 -MD -clang:-MD -clang:-MTmodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj -clang:-MFmodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj.d /Fomodules\imgproc\CMakeFiles\opencv_imgproc.dir\src\median_blur.dispatch.cpp.obj /Fdlib\opencv_imgproc500.pdb -c -- C:\temp\opencv-src\opencv\modules\imgproc\src\median_blur.dispatch.cpp'

$script:Flags = @(Get-CodegenFlags -Tokens (Split-CommandLine -Line $script:RealCommand))

Describe 'LLVM compiler identity evidence' {
    It 'keeps the first version line, argv, exit status and exact identity spacing' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'argv.log'
            $compiler = New-TestBatchTool -Directory $dir -Name 'compiler identity.cmd' -ExitCode 17 -Line @(
                ('>> "' + $log + '" echo %*'), 'echo version one', 'echo version two', 'echo hidden stderr 1>&2')
            $state = [pscustomobject]@{ Compiler = $compiler; Log = $log }
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/diagnostics/Invoke-LlvmAarch64Layout.ps1' `
                -FunctionName Get-LlvmCompilerVersion, Write-LlvmCompilerIdentity -FixtureState $state -Body { param($state)
                    $original = & $state.Compiler --version 2>$null | Select-Object -First 1
                    $originalCode = $LASTEXITCODE
                    Assert-Equal $original (Get-MutLlvmCompilerVersion -Compiler $state.Compiler)
                    $owner = (Get-Command Get-MutLlvmCompilerVersion).Module
                    Assert-Equal $originalCode (& $owner { $LASTEXITCODE })
                    $lines = @(Write-MutLlvmCompilerIdentity -Label 'baseline ' -Compiler $state.Compiler 6>&1 | ForEach-Object { "$_" })
                    Assert-Equal ("baseline : $($state.Compiler)|           version one") ($lines -join '|')
                    Assert-Equal '--version|--version|--version' ((Get-Content -LiteralPath $state.Log) -join '|')
                }
        }
    }

    It 'rejects additional version lines leaking into captured evidence' {
        Invoke-WithTestNativeCommand -Name Invoke-LlvmVersionFixture -FixtureState (New-TestCallState) -Implementation { 'first'; 'second' } -Body {
            Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/diagnostics/Invoke-LlvmAarch64Layout.ps1' -FunctionName Get-LlvmCompilerVersion `
                -Find '| Select-Object -First 1' -Replace '' -Expected 'one compiler identity line' -Body {
                    Assert-Equal 1 @(Get-MutLlvmCompilerVersion -Compiler Invoke-LlvmVersionFixture).Count 'one compiler identity line'
                }
        }
    }
}

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
        # `/D NAME` is two tokens; dropping only /D leaves NAME, which clang-cl reads as an input file.
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
        # -match is case-insensitive, so only -cmatch separates /Fo from /fp:precise.
        Assert-True ($script:Flags -ccontains '/fp:precise') '/fp:precise was stripped as an output flag'
    }

    It 'keeps the remaining codegen-relevant flags' {
        foreach ($flag in @('/Gy', '/bigobj', '/Oi', '-std:c++17', '-MD', '-TP')) {
            Assert-True ($script:Flags -ccontains $flag) "$flag dropped"
        }
    }
}

Describe 'llvm135 shared capture and codegen argument selection' {
    It 'shares artifact filtering while retaining mode-specific preprocessing, codegen and operand policies' {
        $tokens = @('sccache.exe', 'clang-cl.exe', '/O2', '/Ob2', '/D', 'NAME.cpp', '/I', 'include path',
            '-imsvc', 'sdk path', '/FI', 'forced header', '/Fiold.i', '/Fpold.pch', '/Foout.obj', '/Fdout.pdb',
            '-clang:-MFold.d', '/fp:precise', '-mllvm', '-other-pass', '-mllvm', '-inline-threshold=1',
            '-Xclang', '-target-feature', '-Xclang', '+force-32bit-jump-tables', '/c', '--', 'source.cpp')
        $codegen = Get-LlvmCompilePlan -Tokens $tokens
        Assert-Equal '/fp:precise,-mllvm,-other-pass' ($codegen.Flags -join ',')
        Assert-Equal 'source.cpp' $codegen.Source
        Assert-False ($codegen.Flags -contains '+force-32bit-jump-tables')
        $capture = Get-LlvmCompilePlan -Tokens $tokens -Preprocess
        Assert-Equal 'source.cpp' $capture.Source
        Assert-True ($capture.Flags -contains '/O2')
        Assert-True ($capture.Flags -contains '/Ob2')
        Assert-True ($capture.Flags -contains '/D')
        Assert-True ($capture.Flags -contains 'include path')
        Assert-True ($capture.Flags -contains '/Fiold.i')
        Assert-True ($capture.Flags -contains '/Fpold.pch')
        Assert-True ($capture.Flags -contains '-inline-threshold=1')
        Assert-True ($capture.Flags -contains '+force-32bit-jump-tables')
        Assert-False ([bool]($capture.Flags -cmatch '^[-/]F[od]'))
        Assert-False ([bool]($capture.Flags -match '^-clang:-M'))
        Assert-False ($capture.Flags -contains '/c')
        Assert-False ($capture.Flags -contains '--')
    }
}

Describe 'llvm135 compile-plan boundaries' {
    It 'makes the target-feature skip fail when its four-token guard is removed' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/diagnostics/Invoke-LlvmAarch64Layout.ps1' `
            -FunctionName Get-LlvmWorkaroundSkipSpan -Find 'return 4' -Replace 'return 0' `
            -Expected 'expected four workaround tokens' -IncludeControl -Body {
                $tokens = @('-Xclang', '-target-feature', '-Xclang', '+force-32bit-jump-tables')
                Assert-Equal 4 (Get-MutLlvmWorkaroundSkipSpan -Tokens $tokens -Index 0) 'expected four workaround tokens'
            }
    }
}

function New-LlvmCorpusFixture {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Content)
    $inputPath = Join-Path $Directory 'case.i'
    [IO.File]::WriteAllText($inputPath, $Content)
    $case = [pscustomobject]@{ Id = 'layout'; Ref = '#135'; Preprocessed = 'case.i';
        Sha256 = (Get-FileHash $inputPath -Algorithm SHA256).Hash; CodegenFlags = @('/EHa');
        OffFlags = @('/O2'); OnFlags = @('/Ob1'); Expect = 'fixup' }
    return [pscustomobject]@{ Path = $inputPath; Case = $case }
}

Describe 'llvm135 verified corpus and verdicts' {
    It 'rejects a tampered or missing preprocessed input before compiling' {
        Invoke-InTestDir { param($dir)
            $fixture = New-LlvmCorpusFixture -Directory $dir -Content 'original'
            Assert-Equal $fixture.Path (Get-LlvmVerifiedInput -Case $fixture.Case -CorpusDir $dir)
            [IO.File]::WriteAllText($fixture.Path, 'tampered')
            Assert-Throws -Body { Get-LlvmVerifiedInput -Case $fixture.Case -CorpusDir $dir } -MessagePattern 'corpus tampered'
            Remove-Item -LiteralPath $fixture.Path
            Assert-Throws -Body { Get-LlvmVerifiedInput -Case $fixture.Case -CorpusDir $dir } -MessagePattern 'corpus incomplete'
        }
    }

    It 'requires both control arms before trying a candidate and keeps all candidate outcomes' {
        Invoke-InTestDir { param($dir)
            $case = (New-LlvmCorpusFixture -Directory $dir -Content 'fixture').Case
            $state = [pscustomobject]@{ Calls = [Collections.Generic.List[string]]::new(); Arms = @{} }
            Invoke-WithTestFunction -Name Invoke-Arm -FixtureState $state -Definition {
                param($ClangCl, $Flags, $InputPath, $ObjPath)
                $arm = [IO.Path]::GetFileNameWithoutExtension($ObjPath).Replace('layout.', '')
                [void]$State.Calls.Add("$ClangCl|$arm|$($Flags -join ',')|$InputPath")
                return $State.Arms[$arm]
            } -Body { param($state)
                $rows = @(
                    @{ Off = @{ ExitCode = 0; Output = '' }; On = @{ ExitCode = 0; Output = '' }; CandidateArm = @{ ExitCode = 0; Output = '' }; Verdict = 'INVALID-NO-REPRO'; Calls = 2 }
                    @{ Off = @{ ExitCode = 1; Output = 'fixup error' }; On = @{ ExitCode = 1; Output = 'error' }; CandidateArm = @{ ExitCode = 0; Output = '' }; Verdict = 'INVALID-WORKAROUND-DEAD'; Calls = 2 }
                    @{ Off = @{ ExitCode = 1; Output = 'fixup error' }; On = @{ ExitCode = 0; Output = '' }; CandidateArm = @{ ExitCode = 0; Output = '' }; Verdict = 'FIXED'; Calls = 3 }
                    @{ Off = @{ ExitCode = 1; Output = 'fixup error' }; On = @{ ExitCode = 0; Output = '' }; CandidateArm = @{ ExitCode = 1; Output = 'fixup error' }; Verdict = 'NOT-FIXED'; Calls = 3 }
                    @{ Off = @{ ExitCode = 1; Output = 'fixup error' }; On = @{ ExitCode = 0; Output = '' }; CandidateArm = @{ ExitCode = 1; Output = 'other error' }; Verdict = 'INCONCLUSIVE'; Calls = 3 }
                )
                foreach ($row in $rows) {
                    $state.Calls.Clear()
                    $state.Arms = @{ 'baseline-off' = $row.Off; 'baseline-on' = $row.On; 'candidate-off' = $row.CandidateArm }
                    $result = Get-LlvmCaseResult -Case $case -Baseline stock -ObjDir $dir -CorpusDir $dir -Candidate candidate
                    Assert-Equal $row.Verdict $result.Verdict
                    Assert-Equal $row.Calls $state.Calls.Count
                    Assert-Match 'stock\|baseline-off\|/EHa,/O2' $state.Calls[0]
                    Assert-Match 'stock\|baseline-on\|/EHa,/Ob1' $state.Calls[1]
                }
            }
        }
    }

    It 'gives invalid controls priority over a green candidate result' {
        $results = @(
            [pscustomobject]@{ Id = 'bad'; Verdict = 'INVALID-NO-REPRO'; BaselineTail = 'bad control' },
            [pscustomobject]@{ Id = 'good'; Verdict = 'FIXED'; CandidateTail = '' }
        )
        $output = @(Write-LlvmOverallVerdict -Results $results -Candidate candidate 6>&1 | ForEach-Object { "$_" })
        Assert-Equal 'INVALID' $output[-1]
        Assert-True (($output -join "`n") -match 'HARNESS INVALID')
    }
}
