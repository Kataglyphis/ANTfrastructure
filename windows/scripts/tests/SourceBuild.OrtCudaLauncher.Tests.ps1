#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# With Blackwell archs ORT's PTX-only nvcc compiles abort under sccache (mozilla/sccache#2862), so only those targets drop the launcher.

# Splatted into Invoke-WithFunctionModule: a mutant is this one function, as Get-MutOrtPtxLauncherExemptArg.
$launcherMutantSource = @{
    Text         = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1'))
    FunctionName = 'Get-OrtPtxLauncherExemptArg'
}
$ortPatchDir = Join-Path (Get-RepoRoot) 'windows\scripts\patches\onnxruntime'

Describe 'Build-OnnxFromSource: the CUDA launcher and a Blackwell arch list' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-OnnxFromSource.ps1' -FunctionName 'Get-OrtPtxLauncherExemptArg')

    It 'adds the exempting include for 120 or 121, keeps the launcher on, and leaves any other arch list alone' {
        foreach ($c in @(
                @{ Archs = '86;87;89;120'; Exempt = $true }, @{ Archs = '121'; Exempt = $true },
                @{ Archs = '80;86;87;89;90'; Exempt = $false }, @{ Archs = '86;89'; Exempt = $false })) {
            Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = '1' } {
                $r = @(Get-OrtPtxLauncherExemptArg -Architectures $c.Archs -PatchDir $ortPatchDir 6>$null)
                Assert-Equal $(if ($c.Exempt) { 1 } else { 0 }) $r.Count "args for $($c.Archs)"
                if ($c.Exempt) { Assert-Match '^-DCMAKE_PROJECT_onnxruntime_INCLUDE=.+/sccache-ptx-exempt\.cmake$' $r[0] }
                Assert-Equal '1' "$env:SCCACHE_CUDA_LAUNCHER" "the launcher stays on for $($c.Archs)"
            }
        }
    }

    It 'a mutant that matches 120 alone gives 121 no exemption, so the case above bites (mutation)' {
        Invoke-WithFunctionModule @launcherMutantSource -Find "'^12[01]'" -Replace "'^120'" -Body {
            Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = '1' } {
                Assert-Equal 0 @(Get-MutOrtPtxLauncherExemptArg -Architectures '121' -PatchDir $ortPatchDir 6>$null).Count 'the mutant must miss 121'
            }
        }
    }

    It 'does nothing when the launcher was not on' {
        Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = $null } {
            Assert-Equal 0 @(Get-OrtPtxLauncherExemptArg -Architectures '86;120' -PatchDir $ortPatchDir 6>$null).Count 'nothing to exempt'
        }
    }

    It 'refuses a Blackwell build whose include is missing, instead of letting nvcc abort an hour in' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = '1' } {
                Assert-Throws { Get-OrtPtxLauncherExemptArg -Architectures '120' -PatchDir $d 6>$null } 'no sccache-ptx-exempt.cmake'
            }
        }
    }

    It 'is called on the CUDA path of the script, into the args the configure gets' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1')
        $call = $src.IndexOf('$gpuArgs += Get-OrtPtxLauncherExemptArg')
        Assert-True ($call -gt $src.IndexOf('if ($cudaUsable) {')) 'inside the CUDA branch'
        Assert-True ($call -lt $src.IndexOf("Switch-BuildPhase '3. cmake configure'")) 'before cmake reads the launcher'
    }
}

Describe 'sccache-ptx-exempt.cmake' {

    It 'takes the CUDA launcher off every target with a -virtual arch, in subdirectories too, and off no other' {
        $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
        Assert-True ([bool]$cmake) 'cmake (3.19 or newer, for cmake_language(DEFER)) must be on PATH for this suite'
        Invoke-InTestDir { param($d)
            New-Item -ItemType Directory -Path "$d\src\sub" | Out-Null
            Set-Content -LiteralPath "$d\src\CMakeLists.txt" -Value @'
cmake_minimum_required(VERSION 3.19)
project(onnxruntime NONE)
set(CMAKE_CUDA_COMPILER_LAUNCHER sccache)
add_custom_target(llm)
set_target_properties(llm PROPERTIES CUDA_ARCHITECTURES "86-real;120-virtual" CUDA_COMPILER_LAUNCHER sccache)
add_custom_target(kernels)
set_target_properties(kernels PROPERTIES CUDA_ARCHITECTURES "86-real;120a-real" CUDA_COMPILER_LAUNCHER sccache)
add_custom_target(host)
add_subdirectory(sub)
function(report)
  foreach(t llm kernels host plugin_llm)
    get_target_property(l ${t} CUDA_COMPILER_LAUNCHER)
    message(STATUS "LAUNCHER ${t}=[${l}]")
  endforeach()
endfunction()
cmake_language(DEFER CALL report)
'@
            Set-Content -LiteralPath "$d\src\sub\CMakeLists.txt" -Value @'
add_custom_target(plugin_llm)
set_target_properties(plugin_llm PROPERTIES CUDA_ARCHITECTURES "75-real;121-virtual" CUDA_COMPILER_LAUNCHER sccache)
'@
            $include = (Join-Path $ortPatchDir 'sccache-ptx-exempt.cmake') -replace '\\', '/'
            $out = (& $cmake -S "$d\src" -B "$d\build" "-DCMAKE_PROJECT_onnxruntime_INCLUDE=$include" 2>&1) -join "`n"
            Assert-Equal 0 $LASTEXITCODE "configure failed: $out"
            Assert-Match 'LAUNCHER llm=\[\]' $out 'the PTX-only target goes bare'
            Assert-Match 'LAUNCHER plugin_llm=\[\]' $out 'a -virtual target in a subdirectory goes bare too'
            Assert-Match 'LAUNCHER kernels=\[sccache\]' $out 'a real-only CUDA target keeps the launcher'
            Assert-Match 'LAUNCHER host=\[l-NOTFOUND\]' $out 'a target without CUDA archs is left alone'
            Assert-Match 'sccache-ptx-exempt: nvcc stays bare for llm;plugin_llm' $out 'and configure names them'
        }
    }
}
