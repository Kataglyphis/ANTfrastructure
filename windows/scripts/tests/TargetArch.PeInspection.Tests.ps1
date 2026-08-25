#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Get-PeFileMachine / Get-PeImportNames (WindowsTargetArch.Common.psm1): the
# dependency-free PE readers behind the merge arch gate and its #127 import
# walk. Real PE files from this host stand in for fixtures (kernel32.dll and
# the running pwsh.exe exist on every Windows test runner); the machine
# assertion follows the runner's own architecture so an arm64 runner passes
# too. A synthetic non-PE file proves the throw path.

Describe 'PE inspection primitives' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsTargetArch.Common.psm1') -Force -DisableNameChecking
        $script:kernel32 = Join-Path $env:SystemRoot 'System32\kernel32.dll'
        $script:pwshExe = (Get-Process -Id $PID).Path
        $script:hostMachine = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
            'X64'   { 0x8664 }
            'Arm64' { 0xAA64 }
            default { 0x8664 }
        }
        $script:notPe = Join-Path ([IO.Path]::GetTempPath()) ('not-a-pe-' + [guid]::NewGuid().ToString('N') + '.dll')
        Set-Content -Path $script:notPe -Value 'this is not a portable executable, it is a haiku' -Encoding ASCII
    }

    AfterAll { Remove-Item $script:notPe -Force -ErrorAction SilentlyContinue }

    It 'Get-PeFileMachine reads the machine of a real system DLL' {
        Assert-Equal $script:hostMachine (Get-PeFileMachine -Path $script:kernel32) 'kernel32.dll must report the runner''s own machine type'
    }

    It 'Get-PeFileMachine throws on a non-PE file rather than returning 0' {
        $threw = $false
        try { Get-PeFileMachine -Path $script:notPe | Out-Null } catch { $threw = $true }
        Assert-True $threw 'a text file must be rejected, never mistaken for "matches nothing"'
    }

    It 'Get-PeImportNames lists the imported DLL names of a real PE (kernel32 -> ntdll)' {
        $imports = @(Get-PeImportNames -Path $script:kernel32)
        Assert-True ($imports.Count -gt 0) 'kernel32.dll has an import table'
        Assert-True (($imports | ForEach-Object { $_.ToLowerInvariant() }) -contains 'ntdll.dll') "kernel32.dll imports ntdll.dll (got: $($imports -join ', '))"
        Assert-True (@($imports | Where-Object { $_ -match '^api-ms-win-' }).Count -gt 0) 'kernel32.dll imports at least one api-ms-win-* API set'
    }

    It 'Get-PeImportNames also reads the running pwsh.exe (PE32+ with a delay-load table or none)' {
        $imports = @(Get-PeImportNames -Path $script:pwshExe -IncludeDelayLoad)
        Assert-True ($imports.Count -gt 0) 'pwsh.exe imports something (kernel32 at least)'
        Assert-True (($imports | ForEach-Object { $_.ToLowerInvariant() }) -contains 'kernel32.dll') 'pwsh.exe imports kernel32.dll'
    }

    It 'Get-PeImportNames returns unique names and throws on a non-PE file' {
        $imports = @(Get-PeImportNames -Path $script:kernel32)
        Assert-Equal $imports.Count @($imports | Select-Object -Unique).Count 'names are unique'
        $threw = $false
        try { Get-PeImportNames -Path $script:notPe | Out-Null } catch { $threw = $true }
        Assert-True $threw 'non-PE input must throw'
    }
}
