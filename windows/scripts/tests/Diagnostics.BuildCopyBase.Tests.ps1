#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Test-BuildCopy base reference' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Test-BuildCopy.ps1' -FunctionName 'Get-ProbeBaseReference', 'Get-ProbeBaseArguments')

    It 'uses both pinned base fields from versions.env' {
        Invoke-InTestDir {
            param($dir)
            $path = Join-Path $dir 'versions.env'
            Set-Content -LiteralPath $path -Value @('WINDOWS_LTSC=2025', 'WINDOWS_BASE_DIGEST=sha256:abc')
            Assert-Equal 'mcr.microsoft.com/windows/servercore:ltsc2025@sha256:abc' (Get-ProbeBaseReference -VersionsEnv $path)
        }
    }

    It 'does not claim a pinned base when a field or the file is missing' {
        Invoke-InTestDir {
            param($dir)
            $path = Join-Path $dir 'versions.env'
            Assert-Equal '' (Get-ProbeBaseReference -VersionsEnv $path)
            Set-Content -LiteralPath $path -Value 'WINDOWS_LTSC=2025'
            Assert-Equal '' (Get-ProbeBaseReference -VersionsEnv $path)
        }
    }

    It 'passes the same pinned base to BuildKit and classic docker in their own argument syntax' {
        $base = 'mcr.microsoft.com/windows/servercore:ltsc2025@sha256:abc'
        Assert-Equal "--opt,build-arg:BASE=$base" (@(Get-ProbeBaseArguments -Base $base) -join ',') 'BuildKit options'
        Assert-Equal "--build-arg,BASE=$base" (@(Get-ProbeBaseArguments -Base $base -Docker) -join ',') 'docker options'
        Assert-Equal 0 @(Get-ProbeBaseArguments -Base '' -Docker).Count 'no unpinned argument'
    }
}
