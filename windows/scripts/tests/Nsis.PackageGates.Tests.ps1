#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: real 7-Zip and the Python verifiers, which test_package_nsis_setup.py and a Windows host run; a fake 7z lists the setup here.
$moduleDir = Join-Path (Get-RepoRoot) 'windows/scripts/modules'
'WindowsMsiLicense', 'WindowsMsvcRuntimeNotice', 'WindowsPackageBinary', 'WindowsCrossBundle' |
    ForEach-Object { Import-Module (Join-Path $moduleDir "$_.Common.psm1") -Force -DisableNameChecking }
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.GraphFixture.psm1') -ErrorAction Stop

# Runs -Body with a global 7z that lists -Member as an NSIS setup and exits -ExitCode, then removes it.
function Invoke-WithFakeNsisListing {
    param([Parameter(Position = 0)][string[]]$Member, [Parameter(Mandatory, Position = 1)][scriptblock]$Body, [int]$ExitCode = 0)
    $listing = @('Path = C:\demo-setup.exe', 'Type = Nsis', '', '----------') + @($Member | ForEach-Object { "Path = $_"; 'Size = '; '' })
    $code = $ExitCode
    $fake = { $global:LASTEXITCODE = $code; if (-not $code) { $listing } }.GetNewClosure()
    $null = New-Item -Path function:global:7z -Value $fake -Force
    try { & $Body } finally { Remove-Item -LiteralPath function:global:7z -ErrorAction SilentlyContinue }
}

# 4 KiB of zeros with NSIS's first header at -Offset: flags, then 0xDEADBEEF and "NullsoftInst".
function New-NsisHeaderFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$Offset)
    $content = [byte[]]::new(4096)
    [Convert]::FromHexString('EFBEADDE4E756C6C736F6674496E7374').CopyTo($content, $Offset + 4)
    [IO.File]::WriteAllBytes($Path, $content)
}

Describe 'Test-NsisSetup and Get-NsisSetupFileNames' {
    It 'finds the first header only at a 512-byte boundary and lists installed files without installer internals' {
        Invoke-InTestDir { param($dir)
            New-NsisHeaderFile -Path (Join-Path $dir 'setup.exe') -Offset 1024
            New-NsisHeaderFile -Path (Join-Path $dir 'unaligned.exe') -Offset 1000
            Assert-True (Test-NsisSetup (Join-Path $dir 'setup.exe')) 'an aligned header is a setup'
            Assert-False (Test-NsisSetup (Join-Path $dir 'unaligned.exe')) 'an unaligned signature is not'

            $setup = Join-Path $dir 'setup.exe'
            $names = Invoke-WithFakeNsisListing -Member '$PLUGINSDIR\System.dll', 'app.exe', 'lib\sub dir\price$5.txt', 'Uninstall.exe' {
                Get-NsisSetupFileNames -Path $setup
            }
            Assert-Equal 'app.exe|lib/sub dir/price$5.txt|Uninstall.exe' ($names -join '|')
            foreach ($bad in @(@{ Member = 'app.exe', 'APP.EXE'; Pattern = 'duplicate NSIS setup member' },
                    @{ Member = @('..\evil.dll'); Pattern = 'unsafe NSIS setup member' })) {
                Assert-Throws { Invoke-WithFakeNsisListing -Member $bad.Member { Get-NsisSetupFileNames -Path $setup } } -MessagePattern $bad.Pattern
            }
            Assert-Throws { Invoke-WithFakeNsisListing -Member 'app.exe' -ExitCode 2 { Get-NsisSetupFileNames -Path $setup } } -MessagePattern 'cannot read the NSIS setup'
            Assert-Throws { Get-NsisSetupFileNames -Path $setup -Lister { param($p) 'no list' } } -MessagePattern 'no member list'
        }
    }
}

Describe 'New-PortableBundle: an NSIS setup is an installer' {
    It 'checks and ships a setup of any stem, and leaves a test .exe behind' {
        $root = New-TestDir -Prefix 'nsis-bundle-'
        try {
            $case = New-CrossBundlePackageFixture -Dir $root -WithArm64App -InstallerName 'app.zip'
            foreach ($file in @(@{ Name = 'demo-1.0-win64-setup.exe'; At = 512 }, @{ Name = 'app_tests.exe'; At = 100 })) {
                New-NsisHeaderFile -Path (Join-Path $case.Options.BuildDir $file.Name) -Offset $file.At
            }
            $splat = $case.Options
            $bundle = New-PortableBundle @splat
            $want = 'app.zip,demo-1.0-win64-setup.exe'
            Assert-Equal $want ((@($bundle.Installers) | Sort-Object) -join ',') 'the setup ships once, whatever its stem'
            Assert-Equal $want ((@($case.Checked) | Sort-Object) -join ',') 'the setup is checked like the others'
            Assert-False (Test-Path -LiteralPath (Join-Path $bundle.Packages 'app_tests.exe')) 'a test .exe is no installer'
        } finally { Remove-TestDir -Path $root }
    }
}

Describe 'Package gates read an NSIS setup' {
    It 'requires the MSVC notice and checks the ORT provider and family layout from the listing' {
        Invoke-InTestDir { param($dir)
            $setup = Join-Path $dir 'demo-setup.exe'
            $null = New-Item -ItemType File -Path $setup
            Invoke-WithFakeNsisListing -Member 'bin\vcruntime140.dll', 'bin\app.exe' {
                Assert-Throws { Assert-PackageMsvcRuntimeNotice -Path $setup } -MessagePattern '0 licenses/msvc-runtime/Redist\.txt'
            }
            Invoke-WithFakeNsisListing -Member 'bin\vcruntime140.dll', 'licenses\msvc-runtime\Redist.txt' {
                Assert-Throws { Assert-PackageMsvcRuntimeNotice -Path $setup } -MessagePattern 'no -RedistText'
            }

            $ort = 'bin\onnxruntime.dll', 'bin\DirectML.dll', 'bin\onnxruntime_providers_shared.dll', 'bin\onnxruntime_providers_cuda.dll'
            Invoke-WithFakeNsisListing -Member $ort {
                Assert-Equal 'onnxruntime_providers_cuda.dll,onnxruntime_providers_shared.dll' ((Get-PackageOrtProviderNames -Path $setup -Directory 'bin') -join ',')
                Assert-PackageOrtFamily -Path $setup -Directory 'bin' -Name 'onnxruntime.dll', 'DirectML.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll'
                Assert-Throws { Assert-PackageOrtFamily -Path $setup -Directory 'bin' -Name 'onnxruntime.dll', 'DirectML.dll' } -MessagePattern 'unexpected or duplicate'
            }
            Invoke-WithFakeNsisListing -Member 'BIN\onnxruntime_providers_cuda.dll' {
                Assert-Throws { Get-PackageOrtProviderNames -Path $setup -Directory 'bin' } -MessagePattern 'aliased or non-file provider'
            }
            Invoke-WithFakeNsisListing -Member 'bin\onnxruntime.dll', 'bin\nested\DirectML.dll' {
                Assert-Throws { Assert-PackageOrtFamily -Path $setup -Directory 'bin' -Name 'onnxruntime.dll', 'DirectML.dll' } -MessagePattern 'unexpected, nested or linked'
            }
            Invoke-WithFakeNsisListing -Member @('bin\onnxruntime.dll') {
                Assert-Throws { Assert-PackageOrtFamily -Path $setup -Directory 'bin' -Name 'onnxruntime.dll', 'DirectML.dll' } -MessagePattern 'missing a required ORT family file'
            }
        }
    }
}
