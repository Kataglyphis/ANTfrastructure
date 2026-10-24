#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'ARM64 VS runtime discovery' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Copy-Arm64VsRuntime.ps1' -FunctionName 'Find-Arm64AsanDirectory', 'Find-Arm64Vcomp')

    It 'selects the ARM64 runtime and reports a missing ASan file' {
        Invoke-InTestDir { param($dir)
            $tools = Join-Path $dir 'VS\VC\Tools\MSVC\14.0'
            $asanDir = Join-Path $tools 'bin\HostArm64\arm64'
            $vcompDir = Join-Path $tools 'bin\Hostx64\arm64'
            $null = New-Item -ItemType Directory -Path $asanDir, $vcompDir -Force
            $asan = 'clang_rt.asan_dynamic-aarch64.dll'
            $null = New-Item -ItemType File -Path (Join-Path $asanDir $asan), (Join-Path $vcompDir 'vcomp140.dll')
            Assert-Equal $asanDir (Find-Arm64AsanDirectory -ToolsRoots @($tools) -AsanFile $asan) 'HostArm64 takes precedence'
            $result = Find-Arm64Vcomp -ToolsRoots @($tools)
            Assert-Equal (Join-Path $vcompDir 'vcomp140.dll') $result.File.FullName 'Hostx64 fallback remains available'
            Assert-True ($result.Searched -contains $vcompDir) 'the diagnostic lists the searched path'
            Remove-Item -LiteralPath (Join-Path $asanDir $asan)
            Assert-Null (Find-Arm64AsanDirectory -ToolsRoots @($tools) -AsanFile $asan) 'missing runtime fails discovery'
        }
    }
}
