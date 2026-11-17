#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# CON265: every clang-cl CMake configure gets the amd64 floor as _FLAGS_INIT; other compilers and arm64 get nothing.

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
