#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Install-Cuda cuDNN verification' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-Cuda.ps1' -FunctionName 'Assert-CudnnInstallation')

    It 'accepts one header, one import library and one runtime DLL' {
        Invoke-InTestDir {
            param($dir)
            foreach ($name in 'cudnn.h', 'cudnn.lib', 'cudnn64_9.dll') {
                Set-Content -LiteralPath (Join-Path $dir $name) -Value 'fixture'
            }
            $output = Assert-CudnnInstallation -Root $dir 6>&1 | Out-String
            Assert-Match '1 headers, 1 libs, 1 DLLs' $output
        }
    }

    It 'fails separately when headers, import libraries or DLLs are missing' {
        Invoke-InTestDir {
            param($dir)
            foreach ($name in 'cudnn.h', 'cudnn.lib', 'cudnn64_9.dll') {
                Set-Content -LiteralPath (Join-Path $dir $name) -Value 'fixture'
            }
            foreach ($case in @(
                @{ Name = 'cudnn.h'; Pattern = 'headers.*not found' },
                @{ Name = 'cudnn.lib'; Pattern = 'import libs.*not found' },
                @{ Name = 'cudnn64_9.dll'; Pattern = 'DLLs.*not found' }
            )) {
                $path = Join-Path $dir $case.Name
                Remove-Item -LiteralPath $path
                Assert-Throws { Assert-CudnnInstallation -Root $dir 6>$null } -MessagePattern $case.Pattern
                Set-Content -LiteralPath $path -Value 'fixture'
            }
        }
    }
}
