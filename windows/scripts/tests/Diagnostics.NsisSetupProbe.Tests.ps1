#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: makensis itself, 7-Zip, the installer run or any measured number.

Describe 'NSIS setup probe script generation' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Measure-NsisSetup.ps1' -FunctionName 'New-NsisProbeScript')

    It 'selects the requested compressor and packs the payload tree' {
        $nsi = New-NsisProbeScript -OutFile 'C:\o\s.exe' -Compressor '/SOLID lzma' -PayloadDir 'C:\p'
        Assert-Match '(?m)^SetCompressor /SOLID lzma\r$' $nsi
        Assert-Match '(?m)^OutFile "C:\\o\\s\.exe"\r$' $nsi
        Assert-Match '(?m)^  File /r "C:\\p\\\*"\r$' $nsi
        Assert-False ($nsi -match 'CreateShortcut|Icon ')
    }

    It 'adds an icon only when one is given' {
        Assert-Match '(?m)^Icon "C:\\i\.ico"\r$' (New-NsisProbeScript -OutFile 'o.exe' -Compressor 'zlib' -Icon 'C:\i.ico')
    }

    It 'pairs the Start-menu shortcut with an uninstaller that removes it' {
        $nsi = New-NsisProbeScript -OutFile 'o.exe' -Compressor 'zlib' -Shortcut
        Assert-Match 'CreateShortcut "\$SMPROGRAMS\\NsisProbe\\NsisProbe\.lnk"' $nsi
        Assert-Match 'WriteUninstaller "\$INSTDIR\\uninstall\.exe"' $nsi
        Assert-Match '(?s)Section "Uninstall".*Delete "\$SMPROGRAMS\\NsisProbe\\NsisProbe\.lnk"' $nsi
        Assert-False ($nsi -match 'File /r')
    }
}

Describe 'NSIS setup probe 7-Zip listing parser' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Measure-NsisSetup.ps1' -FunctionName 'ConvertFrom-SevenZipListing')

    It 'keeps the archive-level facts and ignores later per-file rows' {
        $facts = ConvertFrom-SevenZipListing -Line @('Path = s.exe', 'Type = Nsis', 'Physical Size = 1234',
            'Method = Deflate', 'Solid = -', 'SubType = NSIS-3 Unicode', '----------', 'Path = a.dll', 'Method = LZMA:23')
        Assert-Equal 'Nsis' $facts['Type']
        Assert-Equal 'Deflate' $facts['Method']
        Assert-Equal 'NSIS-3 Unicode' $facts['SubType']
        Assert-Equal '1234' $facts['Physical Size']
        Assert-Equal 5 $facts.Count
    }

    It 'returns no facts for a listing that names none' {
        Assert-Equal 0 (ConvertFrom-SevenZipListing -Line @('ERROR: s.exe : Can not open the file as archive')).Count
    }
}

Describe 'NSIS setup probe Scoop shim resolution' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Measure-NsisSetup.ps1' -FunctionName 'Resolve-ScoopShimTarget')

    It 'follows a shim to the real compiler and keeps a plain executable' {
        $dir = New-TestDir -Prefix 'nsis-shim-'
        try {
            $exe = Join-Path $dir 'makensis.exe'
            Set-Content -LiteralPath $exe -Value ''
            Assert-Equal $exe (Resolve-ScoopShimTarget -Path $exe)
            Set-Content -LiteralPath (Join-Path $dir 'makensis.shim') -Value 'path = "C:\scoop\apps\nsis\current\makensis.exe"'
            Assert-Equal 'C:\scoop\apps\nsis\current\makensis.exe' (Resolve-ScoopShimTarget -Path $exe)
        } finally { Remove-TestDir -Path $dir }
    }

    It 'fails on a shim without a target' {
        $dir = New-TestDir -Prefix 'nsis-shim-'
        try {
            Set-Content -LiteralPath (Join-Path $dir 'bad.shim') -Value 'args = /V2'
            Assert-Throws { Resolve-ScoopShimTarget -Path (Join-Path $dir 'bad.exe') } -MessagePattern 'names no target path'
        } finally { Remove-TestDir -Path $dir }
    }
}
