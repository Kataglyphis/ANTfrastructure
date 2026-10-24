#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'LiteRT ARM assembler feature directives' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-LitertFromSource.ps1' -FunctionName 'Add-LitertArmAsmFeatures')

    It 'prepends the feature union to ten kernels and refuses a smaller set' {
        Invoke-InTestDir { param($dir)
            $build = Join-Path $dir 'build'
            $source = Join-Path $dir 'source'
            $null = New-Item -ItemType Directory -Path $build, $source -Force
            foreach ($index in 1..10) {
                [IO.File]::WriteAllText((Join-Path $source "xnnpack-asm-aarch64-$index.S"), "nop`n")
            }
            Add-LitertArmAsmFeatures -BuildDir $build -SourceDir $source
            $first = Get-Content -LiteralPath (Join-Path $source 'xnnpack-asm-aarch64-1.S') -First 1
            Assert-Equal '.arch armv8.2-a+fp16+dotprod+i8mm+bf16' $first 'cross assembler feature union'
            Assert-Throws { Add-LitertArmAsmFeatures -BuildDir $build -SourceDir $source } `
                'already patched kernels must not inflate the new-patch floor' -MessagePattern 'expected >= 10'
        }
    }
}
