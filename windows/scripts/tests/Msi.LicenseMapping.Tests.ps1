#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Checks MSI File-table mapping and verifier failure propagation, not dependency-license completeness.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMsiLicense.Common.psm1') -Force -DisableNameChecking

function Clear-TestMsiReference {
    param($Object)
    & (Get-Module WindowsMsiLicense.Common) { param($value) Clear-MsiLicenseComReference $value } $Object
}

function New-MsiLicenseTableFixture {
    param([Parameter(Mandatory)][string]$Path)
    & (Get-Module WindowsMsiLicense.Common) { param($path, $body) Invoke-WithMsiLicenseDatabase -Path $path -Mode 3 -Body $body } $Path {
        param($database)
        $view = $null
        try {
            $statements = @(
                'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)',
                'INSERT INTO `File` (`File`, `FileName`, `Sequence`) VALUES (''payloadA'', ''NOTICE~1.Z|NOTICES.Z'', 1)',
                'INSERT INTO `File` (`File`, `FileName`, `Sequence`) VALUES (''payloadB'', ''same.txt'', 2)',
                'INSERT INTO `File` (`File`, `FileName`, `Sequence`) VALUES (''payloadC'', ''same.txt'', 3)',
                'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` SHORT NOT NULL, `Cabinet` CHAR(255) PRIMARY KEY `DiskId`)',
                'INSERT INTO `Media` (`DiskId`, `LastSequence`, `Cabinet`) VALUES (1, 2, ''#cab1.cab'')',
                'INSERT INTO `Media` (`DiskId`, `LastSequence`, `Cabinet`) VALUES (2, 3, ''#cab2.cab'')'
            )
            foreach ($sql in $statements) {
                $view = $database.OpenView($sql)
                $null = $view.Execute(); $null = $view.Close()
                Clear-TestMsiReference $view; $view = $null
            }
            $null = $database.Commit()
        } finally { Clear-TestMsiReference $view }
    }
}

Describe 'MSI license filename mapping' {
    It 'selects an exact short or long file name with case-insensitive Windows semantics' {
        $rows = @([pscustomobject]@{ Id = 'payloadA'; FileName = 'NOTICE~1.Z|NOTICES.Z' })
        Assert-Equal 'payloadA' (Resolve-MsiLicenseFileId -FileName 'notices.z' -Rows $rows)
        Assert-Equal 'payloadA' (Resolve-MsiLicenseFileId -FileName 'notice~1.z' -Rows $rows)
    }

    It 'rejects zero or multiple matches, path names and wildcard identifiers' {
        $rows = @([pscustomobject]@{ Id = 'payloadA'; FileName = 'NOTICES.Z' },
                  [pscustomobject]@{ Id = 'payloadB'; FileName = 'NOTICES.Z' })
        Assert-Throws { Resolve-MsiLicenseFileId -FileName 'missing' -Rows $rows } -MessagePattern 'matched 0 rows'
        Assert-Throws { Resolve-MsiLicenseFileId -FileName 'NOTICES.Z' -Rows $rows } -MessagePattern 'matched 2 rows'
        Assert-Throws { Resolve-MsiLicenseFileId -FileName 'dir/NOTICES.Z' -Rows $rows } -MessagePattern 'must be a basename'
        Assert-Throws { Resolve-MsiLicenseFileId -FileName 'NOTICES.Z' -Rows @([pscustomobject]@{ Id = 'bad*'; FileName = 'NOTICES.Z' }) } -MessagePattern 'invalid MSI file identifier'
    }

    It 'maps one exact WiX source path and refuses ambiguous, invalid and DTD-bearing input' {
        Invoke-InTestDir { param($dir)
            $license = Join-Path $dir 'LICENSE'; $other = Join-Path $dir 'OTHER'; $wix = Join-Path $dir 'source.wxs'
            Set-Content -LiteralPath $license -Value 'license text'
            Set-Content -LiteralPath $other -Value 'other text'
            $escaped = [Security.SecurityElement]::Escape($license)
            $entry = "<File Id='payloadA' Source='$escaped'/>"
            Set-Content -LiteralPath $wix -Value "<Wix xmlns='urn:wix'>$entry</Wix>"
            Assert-Equal 'payloadA' (Get-WixSourceFileId -WixPath $wix -SourcePath $license)
            Assert-Throws { Get-WixSourceFileId -WixPath $wix -SourcePath $other } -MessagePattern 'matched 0 files'
            Set-Content -LiteralPath $wix -Value "<Wix><File Id='payloadA' Source='$($escaped.ToUpperInvariant())'/></Wix>"
            Assert-Equal 'payloadA' (Get-WixSourceFileId -WixPath $wix -SourcePath $license)
            Set-Content -LiteralPath $wix -Value "<Wix><File Id='payloadA' Source='LICENSE'/></Wix>"
            Assert-Throws { Get-WixSourceFileId -WixPath $wix -SourcePath $license } -MessagePattern 'matched 0 files'
            Set-Content -LiteralPath $wix -Value "<Wix>$entry$entry</Wix>"
            Assert-Throws { Get-WixSourceFileId -WixPath $wix -SourcePath $license } -MessagePattern 'matched 2 files'
            Set-Content -LiteralPath $wix -Value "<Wix><File Id='bad*' Source='$escaped'/></Wix>"
            Assert-Throws { Get-WixSourceFileId -WixPath $wix -SourcePath $license } -MessagePattern 'invalid MSI file identifier'
            Set-Content -LiteralPath $wix -Value "<!DOCTYPE Wix [<!ENTITY x 'bad'>]><Wix>$entry</Wix>"
            Assert-Throws { Get-WixSourceFileId -WixPath $wix -SourcePath $license } -MessagePattern '(?i)dtd'
        }
    }

    It 'maps file sequence to exactly one embedded Media cabinet' {
        $files = @([pscustomobject]@{ Id = 'f1'; Sequence = 1 }, [pscustomobject]@{ Id = 'f3'; Sequence = 3 })
        $media = @([pscustomobject]@{ DiskId = 1; LastSequence = 2; Cabinet = '#cab1.cab' },
                   [pscustomobject]@{ DiskId = 2; LastSequence = 3; Cabinet = '#cab2.cab' })
        Assert-Equal 'cab1.cab::f1' (Resolve-MsiCabinetPattern -FileId f1 -Files $files -Media $media)
        Assert-Equal 'cab2.cab::f3' (Resolve-MsiCabinetPattern -FileId f3 -Files $files -Media $media)
        Assert-Throws { Resolve-MsiCabinetPattern -FileId missing -Files $files -Media $media } -MessagePattern 'no unique positive sequence'
        Assert-Throws { Resolve-MsiCabinetPattern -FileId f1 -Files @($files[0], $files[0]) -Media $media } -MessagePattern 'no unique positive sequence'
        Assert-Throws { Resolve-MsiCabinetPattern -FileId f3 -Files $files -Media @($media[0]) } -MessagePattern 'no matching media'
        $media[1].LastSequence = 2
        Assert-Throws { Resolve-MsiCabinetPattern -FileId f1 -Files $files -Media $media } -MessagePattern 'ambiguous or unordered'
        $media[1].LastSequence = 3; $media[1].Cabinet = 'external.cab'
        Assert-Throws { Resolve-MsiCabinetPattern -FileId f3 -Files $files -Media $media } -MessagePattern 'not a safe embedded cabinet'
    }

    It 'forwards the mapped cabinet id and makes a failed verifier fatal on every host' {
        Invoke-InTestDir { param($dir)
            $msi = Join-Path $dir 'mapping.msi'; $verifier = Join-Path $dir 'verifier.py'; $license = Join-Path $dir 'LICENSE'
            $pythonCommand = Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pythonCommand) { throw 'python is required for the verifier fixture' }
            $python = $pythonCommand.Source
            Set-Content -LiteralPath $license -Value 'license text'
            Set-Content -LiteralPath $verifier -Value "import pathlib, sys; sys.exit(0 if len(sys.argv) == 4 and sys.argv[2] == '--require' and sys.argv[3].startswith('cab1.cab::payloadA=') and pathlib.Path(sys.argv[3].split('=', 1)[1]).is_file() else 9)"
            $module = Get-Module WindowsMsiLicense.Common
            & $module {
                $script:originalGetMsiLicenseFileId = (Get-Item Function:Get-MsiLicenseFileId).ScriptBlock
                Set-Item Function:script:Get-MsiLicenseFileId -Value { param($Path, $FileName) 'payloadA' }
                $script:originalGetMsiCabinetPattern = (Get-Item Function:Get-MsiCabinetPattern).ScriptBlock
                Set-Item Function:script:Get-MsiCabinetPattern -Value { param($Path, $FileId) "cab1.cab::$FileId" }
            }
            try {
                Assert-MsiPackageLicense -Path $msi -FileName 'NOTICES.Z' -LicensePath $license -VerifierPath $verifier -PythonPath $python
                Set-Content -LiteralPath $verifier -Value 'import sys; sys.exit(42)'
                Assert-Throws { Assert-MsiPackageLicense -Path $msi -FileName 'NOTICES.Z' -LicensePath $license -VerifierPath $verifier -PythonPath $python } -MessagePattern 'exit 42'
            } finally {
                & $module {
                    Set-Item Function:script:Get-MsiLicenseFileId -Value $script:originalGetMsiLicenseFileId
                    Remove-Variable originalGetMsiLicenseFileId -Scope Script
                    Set-Item Function:script:Get-MsiCabinetPattern -Value $script:originalGetMsiCabinetPattern
                    Remove-Variable originalGetMsiCabinetPattern -Scope Script
                }
            }
        }
    }

    if ($IsWindows) {
        It 'reads an actual MSI table, closes its handles and refuses ambiguous names' {
            Invoke-InTestDir { param($dir)
                $msi = Join-Path $dir 'file table.msi'
                New-MsiLicenseTableFixture -Path $msi
                Assert-Equal 'payloadA' (Get-MsiLicenseFileId -Path $msi -FileName 'NOTICES.Z')
                Assert-Equal 'payloadA' (Get-MsiLicenseFileId -Path $msi -FileName 'NOTICE~1.Z')
                Assert-Equal 'cab1.cab::payloadA' (Get-MsiCabinetPattern -Path $msi -FileId 'payloadA')
                Assert-Equal 'cab2.cab::payloadC' (Get-MsiCabinetPattern -Path $msi -FileId 'payloadC')
                Assert-Throws { Get-MsiLicenseFileId -Path $msi -FileName 'same.txt' } -MessagePattern 'matched 2 rows'
                Assert-Throws { Get-MsiLicenseFileId -Path $msi -FileName 'missing' } -MessagePattern 'matched 0 rows'
                Rename-Item -LiteralPath $msi -NewName 'renamed.msi' -ErrorAction Stop
            }
        }

    }
}
