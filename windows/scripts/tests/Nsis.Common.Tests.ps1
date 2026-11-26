#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: running makensis or a setup; argv, the file list and the template's source text are checked with fakes.
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsNsis.Common.psm1') -DisableNameChecking -ErrorAction Stop

$script:probe313 = { param($exe) "v3.13`r`n" }

function New-NsisTestPayload {
    param([Parameter(Mandatory)] [string]$Root)
    $payload = Join-Path $Root 'payload'
    foreach ($rel in 'app.exe', (Join-Path 'lib' 'data.bin'), (Join-Path 'lib' 'sub dir' 'price$5.txt')) {
        $null = New-Item -ItemType File -Force -Path (Join-Path $payload $rel)
    }
    return $payload
}

Describe 'Resolve-MakensisExe: only the pinned makensis' {
    It 'refuses a missing pin, a missing override and any other version, and accepts the pin' {
        $dir = New-TestDir -Prefix 'nsis-resolve-'
        try {
            $exe = Join-Path $dir 'makensis.exe'
            $null = New-Item -ItemType File -Path $exe
            Assert-Throws { Resolve-MakensisExe -OverridePath $exe -ExpectedVersion '' -VersionProbe $script:probe313 } -MessagePattern 'the pin decides'
            Assert-Throws { Resolve-MakensisExe -OverridePath (Join-Path $dir 'nope.exe') -ExpectedVersion '3.13' -VersionProbe $script:probe313 } -MessagePattern 'does not exist'
            Assert-Throws { Resolve-MakensisExe -OverridePath $exe -ExpectedVersion '3.13' -VersionProbe { param($e) 'v3.10' } } -MessagePattern "reports 'v3\.10', but the pin is v3\.13"
            Assert-Throws { Resolve-MakensisExe -OverridePath $exe -ExpectedVersion '3.13' -VersionProbe { param($e) 'v3.13.1' } } -MessagePattern 'but the pin is v3\.13'
            Assert-Equal (Resolve-Path -LiteralPath $exe).Path (Resolve-MakensisExe -OverridePath $exe -ExpectedVersion '3.13' -VersionProbe $script:probe313)
        } finally { Remove-TestDir -Path $dir }
    }

    It 'takes NSISDIR''s Bin\makensis.exe before the copy beside it' {
        $dir = New-TestDir -Prefix 'nsis-dir-'
        try {
            $bin = Join-Path $dir 'Bin' 'makensis.exe'
            $null = New-Item -ItemType File -Force -Path $bin
            $null = New-Item -ItemType File -Force -Path (Join-Path $dir 'makensis.exe')
            $seen = Invoke-WithEnv @{ NSISDIR = $dir } { Resolve-MakensisExe -ExpectedVersion '3.13' -VersionProbe $script:probe313 }
            Assert-Equal (Resolve-Path -LiteralPath $bin).Path $seen
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'the payload checks and the file list' {
    It 'fails a payload path over the limit and an empty payload, and returns the longest length' {
        $dir = New-TestDir -Prefix 'nsis-path-'
        try {
            $payload = New-NsisTestPayload -Root $dir
            $longest = (Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object { $_.FullName.Length } | Measure-Object -Maximum).Maximum
            Assert-Equal $longest (Assert-NsisPayloadPath -PayloadDir $payload -Limit $longest)
            Assert-Throws { Assert-NsisPayloadPath -PayloadDir $payload -Limit ($longest - 1) } -MessagePattern 'Build from a shorter root'
            $empty = Join-Path $dir 'empty'
            $null = New-Item -ItemType Directory -Path $empty
            Assert-Throws { Assert-NsisPayloadPath -PayloadDir $empty } -MessagePattern 'payload is empty'
        } finally { Remove-TestDir -Path $dir }
    }

    It 'installs every file, uninstalls exactly those, doubles $ only where NSIS expands it and removes the deepest directory first' {
        $dir = New-TestDir -Prefix 'nsis-list-'
        try {
            $payload = New-NsisTestPayload -Root $dir
            $text = Get-Content -Raw (New-NsisFileList -PayloadDir $payload -Path (Join-Path $dir 'out' 'kg-files.nsh'))
            Assert-Match '(?m)^  SetOutPath "\$INSTDIR\\lib\\sub dir"\r?$' $text
            Assert-Match '(?m)^  File ".*price\$5\.txt"\r?$' $text 'the compile-time source keeps a single $'
            Assert-Match '(?m)^  Delete "\$INSTDIR\\lib\\sub dir\\price\$\$5\.txt"\r?$' $text 'the runtime path doubles it'
            Assert-MatchCount 3 '(?m)^  Delete ' $text
            Assert-MatchCount 3 '(?m)^  File ' $text
            Assert-True ($text.IndexOf('RMDir "$INSTDIR\lib\sub dir"') -lt $text.IndexOf('RMDir "$INSTDIR\lib"')) 'a child directory goes before its parent'
            Assert-False ($text -match 'RMDir /r') 'never a recursive delete'
            $bad = Join-Path $dir 'bad'
            $null = New-Item -ItemType File -Force -Path (Join-Path $bad 'x${y}.txt')
            Assert-Throws { New-NsisFileList -PayloadDir $bad -Path (Join-Path $dir 'bad.nsh') } -MessagePattern "containing '\$\{'"
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'defines and versions' {
    It 'emits one /D token per define and refuses other names, quotes and newlines' {
        $tokens = @(Get-NsisDefineArguments -Defines ([ordered]@{ KG_PRODUCT_NAME = 'Demo App'; KG_ARCH = 'x64' }))
        Assert-Equal 2 $tokens.Count
        Assert-Equal '/DKG_PRODUCT_NAME=Demo App' $tokens[0]
        foreach ($name in 'kg_lower', 'OTHER', 'KG-DASH') {
            Assert-Throws { Get-NsisDefineArguments -Defines @{ $name = 'x' } } -MessagePattern 'Invalid NSIS define name'
        }
        Assert-Throws { Get-NsisDefineArguments -Defines @{ KG_X = 'a"b' } } -MessagePattern 'quote or newline'
        Assert-Throws { Get-NsisDefineArguments -Defines @{ KG_X = "a`nb" } } -MessagePattern 'quote or newline'
    }

    It 'pads to four numeric parts and refuses a version without digits' {
        Assert-Equal '1.2.3.0' (ConvertTo-NsisVersion 'v1.2.3-rc1')
        Assert-Equal '2.0.0.0' (ConvertTo-NsisVersion '2')
        Assert-Equal '1.2.3.4' (ConvertTo-NsisVersion '1.2.3.4.5')
        Assert-Throws { ConvertTo-NsisVersion 'latest' } -MessagePattern 'numeric version'
    }
}

Describe 'Invoke-NsisPackage' {
    It 'checks every input before makensis, passes each define before the script and asserts the output' {
        $dir = New-TestDir -Prefix 'nsis-pkg-'
        try {
            $payload = New-NsisTestPayload -Root $dir
            $exe = Join-Path $dir 'makensis.exe'
            $license = Join-Path $dir 'LICENSE.txt'
            $null = New-Item -ItemType File -Path $exe, $license
            $state = @{ Argv = @(); Calls = 0 }
            $invoker = { param($file, $parameters) $state.Calls++; $state.Argv = $parameters
                $out = ($parameters | Where-Object { $_ -like '/DKG_OUTFILE=*' }) -replace '^/DKG_OUTFILE=', ''
                $null = New-Item -ItemType File -Force -Path $out }.GetNewClosure()
            $setup = @{ ProductName = 'Demo App'; Publisher = 'Owner'; Version = '1.2.3'; Arch = 'x64'
                PayloadDir = $payload; MainExe = 'app.exe'; LicenseFile = $license; UninstallKey = 'Owner.Demo'
                OtherArchSetup = 'demo-arm64-setup.exe'; OutFile = (Join-Path $dir 'demo-setup.exe'); WorkDir = (Join-Path $dir 'work') }
            $tool = @{ Context = [pscustomobject]@{}; MakensisPath = $exe; ExpectedVersion = '3.13'; VersionProbe = $script:probe313; InvokerScriptBlock = $invoker }
            $full = $setup.Clone()
            $full.MsiUpgradeCode = '{12345678-1234-1234-1234-123456789ABC}'
            $full.ShortcutArguments = 'gui'

            $out = Invoke-NsisPackage @tool -Setup $full
            Assert-Equal 1 $state.Calls
            Assert-True (Test-Path -LiteralPath $out) 'the setup exists'
            Assert-Equal '/V3' $state.Argv[0]
            Assert-Match 'setup\.nsi$' $state.Argv[-1] 'the script comes last, after every define'
            foreach ($want in '/DKG_VERSION=1.2.3.0', '/DKG_ARCH=x64', '/DKG_UNINSTALL_KEY=Owner.Demo', '/DKG_SHORTCUT_ARGS=gui',
                '/DKG_MSI_UPGRADE_CODE={12345678-1234-1234-1234-123456789ABC}', '/DKG_OTHER_ARCH_SETUP=demo-arm64-setup.exe') {
                Assert-True ($state.Argv -contains $want) "argv carries $want"
            }

            $state.Calls = 0
            # Message pattern -> the one edit of a valid setup that must produce it.
            $refusals = [ordered]@{
                'NSIS input not found, the main exe'   = { param($s) $s.MainExe = 'absent.exe' }
                'MsiUpgradeCode is malformed'          = { param($s) $s.MsiUpgradeCode = '12345678-1234-1234-1234-123456789ABC' }
                'Arch is malformed'                    = { param($s) $s.Arch = 'X64' }
                'UninstallKey is malformed'            = { param($s) $s.UninstallKey = 'Owner Demo 1.2' }
                'lacks OtherArchSetup'                 = { param($s) $s.Remove('OtherArchSetup') }
                'Unknown NSIS setup key: Compressor'   = { param($s) $s.Compressor = 'lzma' }
            }
            foreach ($pattern in $refusals.Keys) {
                $edited = $setup.Clone()
                & $refusals[$pattern] $edited
                Assert-Throws { Invoke-NsisPackage @tool -Setup $edited } -MessagePattern $pattern
            }
            $wrongPin = $tool.Clone(); $wrongPin.ExpectedVersion = '3.12'
            Assert-Throws { Invoke-NsisPackage @wrongPin -Setup $setup } -MessagePattern 'but the pin is v3\.12'
            Assert-Equal 0 $state.Calls 'nothing reached makensis'
        } finally { Remove-TestDir -Path $dir }
    }
}

Describe 'the setup template' {
    $script:nsisDir = Join-Path (Get-RepoRoot) 'windows' 'scripts' 'nsis'
    $script:setup = Get-Content -Raw (Join-Path $script:nsisDir 'setup.nsi')
    $script:common = Get-Content -Raw (Join-Path $script:nsisDir 'kataglyphis-common.nsh')

    It 'requires exactly the defines Invoke-NsisPackage always passes' {
        $required = @([regex]::Matches($script:setup, '(?m)^!insertmacro KG_REQUIRE (KG_[A-Z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $module = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows' 'scripts' 'modules' 'WindowsNsis.Common.psm1')
        $block = [regex]::Match($module, '(?s)\$defines = \[ordered\]@\{(.*?)\n  \}').Groups[1].Value
        $passed = @([regex]::Matches($block, '(KG_[A-Z_]+) =') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        Assert-Equal ($passed -join ',') ($required -join ',')
    }

    It 'packs with zlib, per machine, and keeps every refusal silent-safe and nonzero' {
        Assert-Match '(?m)^SetCompressor /FINAL zlib$' $script:setup 'LZMA ships CPL-1.0 code without its notice'
        Assert-Match '(?m)^RequestExecutionLevel admin$' $script:setup
        Assert-MatchCount 2 '(?m)^  SetShellVarContext all$' $script:common 'install and uninstall both use the all-users Start menu'
        Assert-Match '(?s)!macro KG_REFUSE MSG.*?/SD IDOK.*?SetErrorLevel 2.*?Quit' $script:common
        Assert-Match 'IsNativeARM64[^\n]*\n\s+!insertmacro KG_REFUSE "[^"]*\$\{KG_OTHER_ARCH_SETUP\}' $script:common 'the x64 setup names the arm64 one'
        Assert-Match 'MsiEnumRelatedProductsW\(w "\$\{KG_MSI_UPGRADE_CODE\}"' $script:common
        Assert-False ($script:setup + $script:common -match 'RMDir /r') 'the uninstaller never deletes a directory recursively'
    }
}
