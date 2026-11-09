#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Fixtures check the selected repair, argument spelling and atomic refusals; full CUDA compilation, remote hits and inference need chain evidence.
Import-TestRepoModule -Name WindowsSourceBuild.Common
$script:OrtCudaScript = 'windows/scripts/build/Build-OnnxFromSource.ps1'
$script:OrtCudaCmake = 'cmake/onnxruntime_providers_cuda_plugin.cmake'

function Get-OrtCudaStandardFixture {
    param([string]$Newline = "`n")
    return @(
        '"$<$<COMPILE_LANGUAGE:CUDA>:SHELL:--std c++20>"'
        '"$<$<COMPILE_LANGUAGE:CUDA>:--Werror=default-stream-launch>"'
        '"$<$<COMPILE_LANGUAGE:CUDA>:--generate-code=arch=compute_75,code=[sm_75]>"'
        '"$<$<COMPILE_LANGUAGE:CUDA>:SHELL:--std c++20>"'
        '"$<$<COMPILE_LANGUAGE:CXX>:/EHsc>"'
    ) -join $Newline
}

Describe 'ORT CUDA standard option' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtCudaScript -FunctionName ConvertTo-OrtCudaStandardText)
    $script:OrtCudaRepair = [scriptblock]::Create('param($SourceDir); ' + (Get-TestScriptCommandBlock -ScriptPath $script:OrtCudaScript -Name Edit-SourceFile).ToString())

    It 'joins both standard options without altering warning, architecture or C++ policy and stays byte-stable (mutation)' {
        foreach ($newline in "`n", "`r`n") {
            Invoke-InTestDir -Files @{ $script:OrtCudaCmake = (Get-OrtCudaStandardFixture -Newline $newline) } -Body { param($dir)
                $null = & $script:OrtCudaRepair $dir
                $path = Join-Path $dir $script:OrtCudaCmake
                $fixed = [IO.File]::ReadAllText($path)
                Assert-MatchCount 2 ([regex]::Escape('$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-std=c++20>')) $fixed 'both upstream generator branches retain C++20'
                Assert-False $fixed.Contains('SHELL:--std ') 'no separated value can reach the cache parser'
                Assert-TestScriptContains -ScriptPath $path -Literal @('--Werror=default-stream-launch', '--generate-code=arch=compute_75,code=[sm_75]', 'COMPILE_LANGUAGE:CXX>:/EHsc') -ReasonPrefix 'unrelated policy survives'
                Assert-MatchCount 4 ([regex]::Escape($newline)) $fixed 'the input line endings survive'
                $before = (Get-FileHash -LiteralPath $path).Hash
                $null = & $script:OrtCudaRepair $dir
                Assert-Equal $before (Get-FileHash -LiteralPath $path).Hash 'already-fixed bytes remain unchanged'
            }
        }
    }

    It 'refuses missing or changed standard blocks before writing partial repairs (mutation)' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { $null = & $script:OrtCudaRepair $dir } -MessagePattern 'file not found'
            foreach ($bad in @('SHELL:--std c++20', "SHELL:--std c++20`nSHELL:--std c++17", "SHELL:--std c++20`nSHELL:--std c++20`nSHELL:--std c++20", "SHELL:-std=c++20>`nSHELL:-std=c++20>`nSHELL:--std`t c++17>", "SHELL:-std=c++200>`nSHELL:-std=c++200>")) {
                Write-TestFileTree -Root $dir -Files @{ $script:OrtCudaCmake = $bad }
                $path = Join-Path $dir $script:OrtCudaCmake
                $before = (Get-FileHash -LiteralPath $path).Hash
                Assert-Throws { $null = & $script:OrtCudaRepair $dir } -MessagePattern 'standard options are not verified'
                Assert-Equal $before (Get-FileHash -LiteralPath $path).Hash 'a refused source is not partly rewritten'
            }
        }
    }

    It 'binds the repair to the selected ONNX source before configuration (mutation)' {
        $repair = @(Get-TestScriptCommands -ScriptPath $script:OrtCudaScript -Name Edit-SourceFile)
        Assert-TestAstCommand -Command $repair -Text 'Edit-SourceFile -Path (Join-Path $SourceDir ''cmake/onnxruntime_providers_cuda_plugin.cmake'') -Require -Quiet -Description ''ORT CUDA standard option'' -Transform ${function:ConvertTo-OrtCudaStandardText}'
        $configure = @(Get-TestScriptCommands -ScriptPath $script:OrtCudaScript -Name Invoke-CmakeConfigure)[-1]
        Assert-TestAstOrder -Before $repair[0] -After $configure
    }
}
