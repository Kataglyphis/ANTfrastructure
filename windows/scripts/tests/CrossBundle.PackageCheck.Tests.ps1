#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Host-portable callback proofs; native CMake/batch execution, DLL traversal and archive contents have separate suites.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsCrossBundle.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.GraphFixture.psm1') -ErrorAction Stop

Describe 'New-PortableBundle package-check callbacks' {
    It 'returns one bundle for chatty checks and propagates rejection before copying packages' {
        Invoke-InTestDir { param($dir)
            $dist = Join-Path $dir 'dist'
            New-OrtTestPe -Path (Join-Path $dir 'app/app.exe') -Import KERNEL32.dll -Machine 0xAA64
            $fixture = New-CrossBundlePackageFixture -Dir $dir -SearchDirectory @($dir) -Chatty
            $options = $fixture.Options
            $result = @(New-PortableBundle @options)
            Assert-Equal 1 $result.Count 'package-check success lines do not join the returned bundle object'
            Assert-Equal (Join-Path $dist 'bundle') $result[0].Bundle
            Assert-Equal (Join-Path $dist 'packages') $result[0].Packages
            Assert-Equal 0 @($result[0].Added).Count 'the synthetic app imports only an OS DLL'
            Assert-Equal 'app.msi,app.zip' (($result[0].Installers | Sort-Object) -join ',')
            Assert-Equal 'app.msi,app.zip' (($fixture.Checked | Sort-Object) -join ',') 'both installer checks ran'
            Assert-Equal 2 @(Get-ChildItem -LiteralPath $result[0].Packages -File).Count 'checked packages were copied'
            $options.PackageCheck = { param($Path, $RedistText) throw "package-check rejected: $Path" }
            Assert-Throws { New-PortableBundle @options } -MessagePattern 'package-check rejected: .*app\.(msi|zip)'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $dist 'packages') -File).Count 'a failed check cannot publish an installer'
        }
    }
}
