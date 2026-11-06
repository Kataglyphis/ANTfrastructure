#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The IREE twin's genrule, stable-ABI and GIL fixes; host-portable, so its recipes prove on Linux pwsh as well.

Describe 'IREE v3.13.0 twin on clang-cl' {

    It 'defines Py_GIL_DISABLED on the cross twin''s Python bindings only, and fails when they are gone (mutation)' {
        foreach ($name in 'Add-IreeNinjaTuFlag', 'Add-IreeTwinFreeThreadedDefine') { . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' -FunctionName $name) }
        Assert-Match 'if \(\$Cross\) \{\s+Update-IreeCrossNinjaFile -BuildDir \$BuildDir\s+Add-IreeTwinFreeThreadedDefine -BuildDir \$BuildDir' (Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/build/Build-IreeFromSource.ps1')) 'the cross twin calls it before the gate'
        $edges = foreach ($n in 1..10) { "build runtime/bindings/python/CMakeFiles/nanobind-static.dir/n$n.cpp.obj: CXX_COMPILER`n  FLAGS = /O2" }
        Invoke-InTestDir -Files @{} -Body {
            param($d)
            $ninja = Join-Path $d 'build.ninja'
            Set-Content -LiteralPath $ninja -Value (@($edges) + "build runtime/src/iree/base/a.c.obj: C_COMPILER`n  FLAGS = /O1")
            Add-IreeTwinFreeThreadedDefine -BuildDir $d
            $text = Get-Content -LiteralPath $ninja
            Assert-Equal 10 @($text -match '/O2 -DPy_GIL_DISABLED=1$').Count 'every binding object gets it'
            Assert-Equal 1 @($text -match 'FLAGS = /O1$').Count 'no other object recompiles'
            Set-Content -LiteralPath $ninja -Value "build other.cpp.obj: CXX_COMPILER`n  FLAGS = /O2"
            Assert-Throws { Add-IreeTwinFreeThreadedDefine -BuildDir $d } 'bindings moved' -MessagePattern 'tagged only 0'
        }
    }

    It 'names the staged stable-ABI library for both FindPython prefixes, and only when it exists (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' -FunctionName 'Get-IreeFreeThreadedCmakeArgs')
        Invoke-InTestDir -Files @{ 'libs/python315t.lib' = 'x'; 'libs/python3t.lib' = 'x'; 'bare/python315t.lib' = 'x' } -Body {
            param($d)
            $python = @{ Exe = 'C:\v\python.exe'; Include = 'C:\i'; Lib = (Join-Path $d 'libs/python315t.lib') }
            $stable = (Join-Path $d 'libs/python3t.lib') -replace '\\', '/'
            $named = @(Get-IreeFreeThreadedCmakeArgs -CmakeExtra @('-DX=1') -Python $python -NumPyIncludeDir 'C:/n')
            foreach ($prefix in 'Python3', 'Python') { Assert-True ("-D${prefix}_SABI_LIBRARY=$stable" -in $named) "$prefix gets python3t.lib" }
            $python.Lib = Join-Path $d 'bare/python315t.lib'
            $bare = @(Get-IreeFreeThreadedCmakeArgs -CmakeExtra @('-DX=1') -Python $python -NumPyIncludeDir 'C:/n')
            Assert-Equal 0 @($bare | Where-Object { $_ -match 'SABI_LIBRARY' }).Count 'an absent library is left to FindPython, whose failure names it'
            Assert-Equal 0 @($bare | Where-Object { [string]::IsNullOrEmpty($_) }).Count 'and leaves no empty configure argument'
        }
    }

    It 'points every IREE genrule at the configured Python and refuses another bare shape (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' -FunctionName 'Set-IreeGenrulePython')
        $rule = '    "python3 $(rootpath //build_tools/scripts:gen.py) --out $(execpath x.h)"'
        Invoke-InTestDir -Files @{
            'compiler/src/PluginAPI/CMakeLists.txt' = $rule
            'runtime/src/isa/CMakeLists.txt' = $rule
            'tests/e2e/CMakeLists.txt' = $rule
            'third_party/llvm/CMakeLists.txt' = $rule
        } -Body {
            param($d)
            Set-IreeGenrulePython -SourceDir $d
            foreach ($own in 'compiler/src/PluginAPI', 'runtime/src/isa', 'tests/e2e') {
                Assert-Equal '    "${Python3_EXECUTABLE} $(rootpath //build_tools/scripts:gen.py) --out $(execpath x.h)"' (Get-Content -Raw (Join-Path $d "$own/CMakeLists.txt")).TrimEnd() "$own runs the configured Python"
            }
            Assert-Equal $rule (Get-Content -Raw (Join-Path $d 'third_party/llvm/CMakeLists.txt')).TrimEnd() 'vendored trees stay untouched'
            Set-IreeGenrulePython -SourceDir $d
            [System.IO.File]::WriteAllText((Join-Path $d 'compiler/src/PluginAPI/CMakeLists.txt'), '    "python3 $(location gen.py)"')
            Assert-Throws { Set-IreeGenrulePython -SourceDir $d } 'another shape'
        }
    }

    It 'keeps the interpreter swap and links the compiler builtins' {
        $iree = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/build/Build-IreeFromSource.ps1')
        Assert-Match ([regex]::Escape("-Pattern '`"python3 \`$\(rootpath'")) $iree 'the bare python3 genrule command'
        Assert-Match ([regex]::Escape("-Replacement '`"`$`${Python3_EXECUTABLE} `$`$(rootpath'")) $iree 'becomes the configured interpreter'
        Assert-Match 'Get-IreeCompilerRtCmakeArgs -Arch \(Get-WindowsHostArch\)' $iree 'host tools link the host builtins'
        Assert-Match 'Get-IreeCompilerRtCmakeArgs -Arch \(Get-WindowsTargetArch\)' $iree 'the target build links the target''s'
    }
}
