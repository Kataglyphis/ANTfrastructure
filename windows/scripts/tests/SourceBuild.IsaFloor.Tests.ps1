#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# ISA-floor and IREE patch fixtures; not actual compiler selection, dispatched execution or complete IREE builds.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1') -DisableNameChecking

Describe 'Get-SourceCmakeIsaArgs' {

    It 'amd64 clang-cl gets x86-64-v3 for C and C++' {
        $a = @(Get-SourceCmakeIsaArgs -TargetArch 'amd64')
        Assert-Equal 2 $a.Count
        Assert-True ($a -ccontains '-DCMAKE_C_FLAGS_INIT=/clang:-march=x86-64-v3') 'C floor'
        Assert-True ($a -ccontains '-DCMAKE_CXX_FLAGS_INIT=/clang:-march=x86-64-v3') 'C++ floor'
    }

    It 'a full clang-cl.exe path counts as clang-cl' {
        $a = @(Get-SourceCmakeIsaArgs -TargetArch 'amd64' -CCompiler 'C:\llvm\bin\clang-cl.exe' -CxxCompiler 'C:\llvm\bin\clang-cl.exe')
        Assert-Equal 2 $a.Count
    }

    It 'cl.exe or a GNU-style clang gets nothing, as /clang: is clang-cl spelling' {
        Assert-Equal 0 @(Get-SourceCmakeIsaArgs -TargetArch 'amd64' -CCompiler 'cl' -CxxCompiler 'cl').Count
        Assert-Equal 0 @(Get-SourceCmakeIsaArgs -TargetArch 'amd64' -CCompiler 'clang-cl' -CxxCompiler 'clang++').Count
    }

    It 'arm64 gets nothing: a global optional AArch64 feature is SIGILL on hardware without it' {
        Assert-Equal 0 @(Get-SourceCmakeIsaArgs -TargetArch 'arm64').Count
    }

    It 'Invoke-CmakeConfigure passes it before the caller args, so a caller CMAKE_<LANG>_FLAGS still wins' {
        $body = (Get-Command Invoke-CmakeConfigure).Definition
        $isa = $body.IndexOf('Get-SourceCmakeIsaArgs')
        Assert-True ($isa -gt 0) 'Invoke-CmakeConfigure calls Get-SourceCmakeIsaArgs'
        Assert-True ($isa -lt $body.IndexOf('$cmakeArgs += $ExtraArgs')) 'the floor precedes the caller args'
    }
}


Describe 'IREE dispatched x86 ISA options' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' -FunctionName Set-IreeX86KernelCmakeFlags)
    $ireeOptions = @'
# unrelated prefix
iree_select_compiler_opts(IREE_UK_COPTS_X86_64_AVX2_FMA
  MSVC_OR_CLANG_CL
    "/arch:AVX2"
)
iree_select_compiler_opts(IREE_UK_COPTS_X86_64_AVX512_BASE
  CLANG_OR_GCC
    "-mavx512f"
    "-mavx512vl"
    "-mavx512cd"
    "-mavx512bw"
    "-mavx512dq"
  MSVC_OR_CLANG_CL
    "/arch:AVX512"
)
# unrelated suffix
'@
    $relative = 'runtime/src/iree/builtins/ukernel/arch/x86_64/CMakeLists.txt'

    It 'adds exactly the base feature set while preserving GNU, MSVC and unrelated options' {
        Invoke-InTestDir -Files @{ $relative = $ireeOptions } -Body {
            param($dir)
            Set-IreeX86KernelCmakeFlags -SourceDir $dir
            $text = [IO.File]::ReadAllText((Join-Path $dir $relative))
            foreach ($flag in @('/clang:-mavx512f', '/clang:-mavx512vl', '/clang:-mavx512cd', '/clang:-mavx512bw', '/clang:-mavx512dq')) {
                Assert-True ($text.Contains('    "' + $flag + '"')) "explicit dispatched flag $flag"
            }
            Assert-Match 'AVX512_BASE\r?\n  CLANG_CL\r?\n' $text 'the clang-cl-only branch'
            Assert-True ($text.Contains(($ireeOptions -split 'iree_select_compiler_opts\(IREE_UK_COPTS_X86_64_AVX512_BASE')[0])) 'other targets unchanged'
            Assert-True ($text.EndsWith(($ireeOptions -split 'IREE_UK_COPTS_X86_64_AVX512_BASE\r?\n')[1])) 'GNU/MSVC and following bytes unchanged'
        }
    }

    It 'leaves an already patched LF or CRLF source byte-identical' {
        foreach ($newline in @("`n", "`r`n")) {
            $source = $ireeOptions -replace '\r?\n', $newline
            Invoke-InTestDir -Files @{ $relative = $source } -Body {
                param($dir)
                $path = Join-Path $dir $relative
                Set-IreeX86KernelCmakeFlags -SourceDir $dir
                Assert-FileUnchanged -Path $path -Action { Set-IreeX86KernelCmakeFlags -SourceDir $dir } -Reason 'no second rewrite'
            }
        }
    }

    It 'refuses absent, changed and partially patched inputs without changing their bytes' {
        Invoke-InTestDir -Files @{} -Body {
            param($dir)
            Assert-Throws { Set-IreeX86KernelCmakeFlags -SourceDir $dir } -MessagePattern 'file not found'
        }
        foreach ($bad in @(
            ($ireeOptions -replace 'CLANG_OR_GCC', 'UNKNOWN_COMPILER'),
            ($ireeOptions -replace 'AVX512_BASE', 'RENAMED_BASE'),
            ($ireeOptions -replace '"-mavx512dq"', '"-mavx512other"'),
            ($ireeOptions -replace '"/arch:AVX512"', '"/arch:AVX2"'),
            ($ireeOptions -replace '(AVX512_BASE\r?\n)', ('$1  CLANG_CL' + "`n" + '    "/clang:-mavx512f"' + "`n"))
        )) {
            Invoke-InTestDir -Files @{ $relative = $bad } -Body {
                param($dir)
                $path = Join-Path $dir $relative
                Assert-FileUnchanged -Path $path -Action {
                    Assert-Throws { Set-IreeX86KernelCmakeFlags -SourceDir $dir } -MessagePattern 'options layout changed'
                }
            }
        }
    }

    It 'patches the source unconditionally before native or cross host configuration' {
        $commands = Get-TestScriptCommandMap -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' `
            -Name Set-IreeX86KernelCmakeFlags, Install-IreeHostTools -Order Set-IreeX86KernelCmakeFlags, Install-IreeHostTools `
            -UnconditionalText @{ 'Set-IreeX86KernelCmakeFlags' = 'Set-IreeX86KernelCmakeFlags -SourceDir $SourceDir' }
        Assert-TestAstCommand -Command @($commands['Set-IreeX86KernelCmakeFlags']) -Text 'Set-IreeX86KernelCmakeFlags -SourceDir $SourceDir' -Unconditional
    }
}
