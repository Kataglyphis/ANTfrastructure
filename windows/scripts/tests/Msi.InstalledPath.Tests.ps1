#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Duplicate filenames need the installed directory, not the first File-table row.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMsiLicense.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsPackageBinary.Common.psm1') -Force -DisableNameChecking

Describe 'MSI installed-path mapping' {
    $files = @(
        [pscustomobject]@{ Id = 'ort'; Name = 'LICENSE'; Component = 'a' },
        [pscustomobject]@{ Id = 'other'; Name = 'LICENSE'; Component = 'b' },
        [pscustomobject]@{ Id = 'gpu'; Name = 'ONNXR~1.DLL|onnxruntime.dll'; Component = 'c' }
    )
    $components = @(
        [pscustomobject]@{ Id = 'a'; Directory = 'ortdir' },
        [pscustomobject]@{ Id = 'b'; Directory = 'otherdir' },
        [pscustomobject]@{ Id = 'c'; Directory = 'bindir' }
    )
    $directories = @(
        [pscustomobject]@{ Id = 'root'; Parent = ''; Name = 'SourceDir' },
        [pscustomobject]@{ Id = 'app'; Parent = 'root'; Name = 'APP~1|AccelerANTgine:SourceApp' },
        [pscustomobject]@{ Id = 'lic'; Parent = 'app'; Name = 'LICENSES|licenses' },
        [pscustomobject]@{ Id = 'ortdir'; Parent = 'lic'; Name = 'ONNXRU~1|onnxruntime' },
        [pscustomobject]@{ Id = 'otherdir'; Parent = 'lic'; Name = 'other' },
        [pscustomobject]@{ Id = 'bindir'; Parent = 'app'; Name = 'bin' }
    )
    It 'finds the unique long installed path despite another file with the same name' {
        Assert-Equal 'ort' (Resolve-MsiInstalledFileId -RelativePath 'AccelerANTgine/licenses/onnxruntime/LICENSE' -Files $files -Components $components -Directories $directories)
        Assert-Equal 'gpu' (Resolve-MsiInstalledFileId -RelativePath 'AccelerANTgine\bin\onnxruntime.dll' -Files $files -Components $components -Directories $directories)
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'OtherProduct/bin/onnxruntime.dll' -Files $files -Components $components -Directories $directories } -MessagePattern 'matched 0 rows'
        Assert-Equal 'ort' (Resolve-MsiInstalledFileId -RelativePath 'licenses/onnxruntime/LICENSE' -RootDirectoryId app -RootDirectoryName AccelerANTgine -Files $files -Components $components -Directories $directories)
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'bin/onnxruntime.dll' -RootDirectoryId otherdir -Files $files -Components $components -Directories $directories } -MessagePattern 'matched 0 rows'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'bin/onnxruntime.dll' -RootDirectoryId app -RootDirectoryName OtherProduct -Files $files -Components $components -Directories $directories } -MessagePattern 'expected'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'bin/onnxruntime.dll' -RootDirectoryId missing -Files $files -Components $components -Directories $directories } -MessagePattern 'missing MSI root directory'
        $decoys = @(
            [pscustomobject]@{ Id = 'INSTALL_ROOT'; Parent = 'root'; Name = 'AccelerANTgine' },
            [pscustomobject]@{ Id = 'decoy'; Parent = 'root'; Name = 'OtherProduct' },
            [pscustomobject]@{ Id = 'wrongbin'; Parent = 'decoy'; Name = 'bin' },
            [pscustomobject]@{ Id = 'root'; Parent = ''; Name = 'SourceDir' }
        )
        $outside = @([pscustomobject]@{ Id = 'gpu'; Name = 'onnxruntime.dll'; Component = 'wrong' })
        $outsideComponent = @([pscustomobject]@{ Id = 'wrong'; Directory = 'wrongbin' })
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'bin/onnxruntime.dll' -RootDirectoryId INSTALL_ROOT -RootDirectoryName AccelerANTgine -Files $outside -Components $outsideComponent -Directories $decoys } -MessagePattern 'matched 0 rows'
    }
    It 'rejects missing or ambiguous installed paths and unsafe requests' {
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'licenses/missing/LICENSE' -Files $files -Components $components -Directories $directories } -MessagePattern 'matched 0 rows'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'LICENSE' -Files $files -Components $components -Directories $directories } -MessagePattern 'matched 2 rows'
        foreach ($path in '../LICENSE', '/LICENSE', 'x/./LICENSE', 'x/*', 'x/f.dll.', 'x/f.dll ', "x/f`ndll") {
            Assert-Throws { Resolve-MsiInstalledFileId -RelativePath $path -Files $files -Components $components -Directories $directories } -MessagePattern 'unsafe MSI relative path'
        }
    }
    It 'rejects malformed and cyclic directory and component tables' {
        $cycle = @($directories | ForEach-Object { $_.PSObject.Copy() })
        ($cycle | Where-Object Id -eq 'ortdir').Parent = 'ortdir'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'licenses/onnxruntime/LICENSE' -Files $files -Components $components -Directories $cycle } -MessagePattern 'cyclic or missing MSI directory'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'licenses/onnxruntime/LICENSE' -Files $files -Components @() -Directories $directories } -MessagePattern 'missing MSI component'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'LICENSE' -Files $files -Components @($components + $components[0]) -Directories $directories } -MessagePattern 'duplicate or empty MSI component'
        $badFiles = @([pscustomobject]@{ Id = 'bad'; Name = 'onnxruntime.dll '; Component = 'c' })
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'AccelerANTgine/bin/onnxruntime.dll' -Files $badFiles -Components $components -Directories $directories } -MessagePattern 'unsafe MSI target name'
        $badFiles[0].Name = 'onnxruntime.dll:evil'
        Assert-Throws { Resolve-MsiInstalledFileId -RelativePath 'AccelerANTgine/bin/onnxruntime.dll' -Files $badFiles -Components $components -Directories $directories } -MessagePattern 'unsafe MSI file name'
    }
    It 'enumerates only long filenames under an exact anchored MSI directory' {
        $provider = [pscustomobject]@{ Id = 'provider'; Name = 'ONNXP~1.DLL|onnxruntime_providers_shared.dll'; Component = 'c' }
        $names = @(Resolve-MsiDirectoryFileNames -Directory 'bin' -RootDirectoryId app -RootDirectoryName AccelerANTgine -Files @($files + $provider) -Components $components -Directories $directories)
        Assert-Equal 'onnxruntime.dll,onnxruntime_providers_shared.dll' ($names -join ',')
        Assert-Throws { Resolve-MsiDirectoryFileNames -Directory 'Bin' -RootDirectoryId app -Files $files -Components $components -Directories $directories } -MessagePattern 'directory case differs'
        Assert-Throws { Resolve-MsiDirectoryFileNames -Directory 'bin/../bin' -RootDirectoryId app -Files $files -Components $components -Directories $directories } -MessagePattern 'unsafe MSI relative directory'
        Assert-Throws { Resolve-MsiDirectoryFileNames -Directory 'bin' -RootDirectoryId app -RootDirectoryName Wrong -Files $files -Components $components -Directories $directories } -MessagePattern 'expected'
    }
    if ($IsWindows) {
        It 'reads the installed path from actual MSI database tables' {
            Invoke-InTestDir { param($dir)
                $msi = Join-Path $dir 'paths.msi'
                & (Get-Module WindowsMsiLicense.Common) { param($path)
                    Invoke-WithMsiLicenseDatabase -Path $path -Mode 3 -Body {
                        param($database)
                        foreach ($sql in @(
                            'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL PRIMARY KEY `Directory`)',
                            'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL PRIMARY KEY `Component`)',
                            'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Component_` CHAR(72) NOT NULL PRIMARY KEY `File`)',
                            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''root'', NULL, ''SourceDir'')',
                            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''licenses'', ''root'', ''licenses'')',
                            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''ort'', ''licenses'', ''onnxruntime'')',
                            'INSERT INTO `Component` (`Component`, `Directory_`) VALUES (''ortc'', ''ort'')',
                            'INSERT INTO `Component` (`Component`, `Directory_`) VALUES (''otherc'', ''licenses'')',
                            'INSERT INTO `File` (`File`, `FileName`, `Component_`) VALUES (''ortlicense'', ''LICENSE'', ''ortc'')',
                            'INSERT INTO `File` (`File`, `FileName`, `Component_`) VALUES (''ortprovider'', ''ONNXP~1.DLL|onnxruntime_providers_shared.dll'', ''ortc'')',
                            'INSERT INTO `File` (`File`, `FileName`, `Component_`) VALUES (''otherlicense'', ''LICENSE'', ''otherc'')'
                        )) {
                            $view = $database.OpenView($sql)
                            try { $null = $view.Execute(); $null = $view.Close() }
                            finally { Clear-MsiLicenseComReference $view }
                        }
                        $null = $database.Commit()
                    }
                } $msi
                Assert-Equal 'ortlicense' (Get-MsiInstalledFileId -Path $msi -RelativePath 'licenses/onnxruntime/LICENSE')
                Assert-Equal 'ortlicense' (Get-MsiInstalledFileId -Path $msi -RelativePath 'onnxruntime/LICENSE' -RootDirectoryId licenses -RootDirectoryName licenses)
                Assert-Equal 'LICENSE,onnxruntime_providers_shared.dll' (@(Get-MsiDirectoryFileNames -Path $msi -Directory 'onnxruntime' -RootDirectoryId licenses -RootDirectoryName licenses) -join ',')
                Assert-Equal 'onnxruntime_providers_shared.dll' (@(Get-PackageOrtProviderNames -Path $msi -Directory 'onnxruntime' -RootDirectoryId licenses -RootDirectoryName licenses) -join ',')
                Assert-Throws { Get-MsiInstalledFileId -Path $msi -RelativePath 'LICENSE' } -MessagePattern 'matched 2 rows'
                & (Get-Module WindowsMsiLicense.Common) { param($path)
                    Invoke-WithMsiLicenseDatabase -Path $path -Mode 1 -Body {
                        param($database)
                        $view = $database.OpenView('INSERT INTO `File` (`File`, `FileName`, `Component_`) VALUES (''duplicate'', ''onnxruntime_providers_shared.dll'', ''ortc'')')
                        try { $null = $view.Execute(); $null = $view.Close(); $null = $database.Commit() }
                        finally { Clear-MsiLicenseComReference $view }
                    }
                } $msi
                Assert-Throws { Get-PackageOrtProviderNames -Path $msi -Directory 'onnxruntime' -RootDirectoryId licenses -RootDirectoryName licenses } -MessagePattern 'duplicate ORT provider'
                Rename-Item -LiteralPath $msi -NewName 'closed.msi' -ErrorAction Stop
            }
        }
    }
}
