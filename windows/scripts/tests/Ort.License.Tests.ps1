#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Checks exact wheel-to-DLL mapping and bytes, not licenses of other native libraries.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsOrtLicense.Common.psm1') -DisableNameChecking -ErrorAction Stop

function New-OrtLicenseZipFixture {
    param([string]$Path, [string]$Dll = 'native dll', [string]$License = 'original MIT text',
        [string]$Notice = 'original notices', [switch]$MissingNotice, [switch]$DuplicateLicense, [switch]$Archive,
        [string]$ArchiveDirectory = 'licenses/onnxruntime', [string]$Provider = '', [string]$Extension = '', [string]$DirectMl = '')
    $prefix = if ($Archive) { "app/$ArchiveDirectory" } else { 'onnxruntime' }
    $members = [ordered]@{ "$prefix/LICENSE" = $License }
    if (-not $Archive) { $members['onnxruntime/capi/onnxruntime.dll'] = $Dll }
    if ($Provider) { $members['onnxruntime/capi/onnxruntime_providers_cuda.dll'] = $Provider }
    if ($Extension) { $members['onnxruntime/capi/onnxruntime_pybind11_state.pyd'] = $Extension }
    if ($DirectMl) { $members['onnxruntime/capi/DirectML.dll'] = $DirectMl }
    if (-not $MissingNotice) { $members["$prefix/ThirdPartyNotices.txt"] = $Notice }
    $duplicate = if ($DuplicateLicense) { @("$prefix/LICENSE") } else { @() }
    New-TestZipFile -Path $Path -Member $members -DuplicateName $duplicate
}

function Invoke-OrtLicenseFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [switch]$NoWheel)
    Invoke-InTestDir { param($dir)
        $wheels = Join-Path $dir 'wheels'; $bundle = Join-Path $dir 'bundle'; $dll = Join-Path $dir 'onnxruntime.dll'
        $null = New-Item -ItemType Directory -Path $wheels, $bundle
        [IO.File]::WriteAllText($dll, 'native dll')
        if (-not $NoWheel) { New-OrtLicenseZipFixture -Path (Join-Path $wheels 'onnxruntime-1.2.3-cp315-cp315-win_amd64.whl') }
        & $Body $dir $wheels $bundle $dll
    }.GetNewClosure()
}

function Copy-OrtFixtureTexts([string]$Source, [string]$Destination) {
    Copy-Item -LiteralPath @((Join-Path $Source 'LICENSE'), (Join-Path $Source 'ThirdPartyNotices.txt')) -Destination $Destination -Force
}

Describe 'ONNX Runtime wheel license provenance' {
    It 'copies both original texts only from the wheel with this exact DLL' {
        Invoke-OrtLicenseFixture { param($dir, $wheels, $bundle, $dll)
            New-OrtLicenseZipFixture -Path (Join-Path $wheels 'onnxruntime-1.2.4-cp315-cp315-win_amd64.whl') -Dll 'other dll'
            $out = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle
            Assert-Equal 'original MIT text' ([IO.File]::ReadAllText((Join-Path $out 'LICENSE')))
            Assert-Equal 'original notices' ([IO.File]::ReadAllText((Join-Path $out 'ThirdPartyNotices.txt')))
            [IO.File]::WriteAllText($dll, 'unmatched')
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle } -MessagePattern 'matched 0 wheels'
            [IO.File]::WriteAllText($dll, 'native dll')
            New-OrtLicenseZipFixture -Path (Join-Path $wheels 'onnxruntime-1.2.5-cp315-cp315-win_amd64.whl')
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle } -MessagePattern 'matched 2 wheels'
        }
    }

    It 'rejects missing, empty and duplicate source texts before creating the destination' {
        foreach ($kind in 'missing', 'empty', 'blank', 'duplicate') {
            Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
                $options = @{ Path = (Join-Path $wheels 'onnxruntime-1.2.3-cp315-cp315-win_amd64.whl') }
                if ($kind -eq 'missing') { $options.MissingNotice = $true }
                if ($kind -eq 'empty') { $options.License = '' }
                if ($kind -eq 'blank') { $options.License = " `t`n" }
                if ($kind -eq 'duplicate') { $options.DuplicateLicense = $true }
                New-OrtLicenseZipFixture @options
                Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle }
                Assert-False (Test-Path -LiteralPath (Join-Path $bundle 'licenses'))
            }.GetNewClosure()
        }
    }

    It 'rejects an empty DLL even when an empty wheel member has the same hash' {
        Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
            [IO.File]::WriteAllBytes($dll, [byte[]]@())
            New-OrtLicenseZipFixture -Path (Join-Path $wheels 'onnxruntime-1.2.3-cp315-cp315-win_amd64.whl') -Dll ''
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle } -MessagePattern 'entry is empty'
        }
    }

    It 'requires selected provider bytes in the same wheel as the core before copying texts' {
        Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
            $provider = Join-Path $dir 'onnxruntime_providers_cuda.dll'
            [IO.File]::WriteAllText($provider, 'cuda provider')
            $wheel = Join-Path $wheels 'onnxruntime_gpu-1.2.3-cp315-cp315-win_amd64.whl'
            New-OrtLicenseZipFixture -Path $wheel
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll $provider } -MessagePattern 'matched 0 entries'
            Assert-False (Test-Path -LiteralPath (Join-Path $bundle 'licenses')) 'no texts copied for a missing provider'
            Remove-Item -LiteralPath $wheel
            New-OrtLicenseZipFixture -Path $wheel -Provider 'another provider'
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll $provider } -MessagePattern 'differs from the matching wheel'
            Assert-False (Test-Path -LiteralPath (Join-Path $bundle 'licenses')) 'no texts copied for mismatched provider bytes'
            Remove-Item -LiteralPath $wheel
            New-OrtLicenseZipFixture -Path $wheel -Provider 'cuda provider'
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll @($provider, $provider) } -MessagePattern 'Duplicate ONNX Runtime provider'
            [IO.File]::WriteAllText($provider, '')
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll $provider } -MessagePattern 'empty or not a file'
            [IO.File]::WriteAllText($provider, 'cuda provider')
            $out = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll $provider
            Assert-Equal 'original notices' ([IO.File]::ReadAllText((Join-Path $out 'ThirdPartyNotices.txt')))
        }
    }

    It 'matches a provider larger than the text verifier limit without reading it as a license' {
        Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
            $provider = Join-Path $dir 'onnxruntime_providers_cuda.dll'
            $stream = [IO.File]::Create($provider)
            try { $stream.SetLength(17MB) } finally { $stream.Dispose() }
            $wheel = Join-Path $wheels 'onnxruntime_gpu-1.2.3-cp315-cp315-win_amd64.whl'
            $archive = [IO.Compression.ZipFile]::Open($wheel, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entry in @{
                        'onnxruntime/capi/onnxruntime.dll' = $dll
                        'onnxruntime/capi/onnxruntime_providers_cuda.dll' = $provider
                    }.GetEnumerator()) {
                    $inputStream = [IO.File]::OpenRead($entry.Value)
                    $outputStream = $archive.CreateEntry($entry.Key).Open()
                    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                }
                foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
                    $writer = [IO.StreamWriter]::new($archive.CreateEntry("onnxruntime/$name").Open())
                    try { $writer.Write('original text') } finally { $writer.Dispose() }
                }
            } finally { $archive.Dispose() }
            $out = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -ProviderDll $provider
            Assert-Equal 'original text' ([IO.File]::ReadAllText((Join-Path $out 'LICENSE')))
        }
    }

    It 'optionally requires DirectML bytes from the core wheel before copying texts' {
        Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
            $directMl = Join-Path $dir 'DirectML.dll'
            [IO.File]::WriteAllText($directMl, 'directml runtime')
            $wheel = Join-Path $wheels 'onnxruntime_directml-1.2.3-cp315-cp315-win_amd64.whl'
            New-OrtLicenseZipFixture -Path $wheel
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -DirectMlDll $directMl } -MessagePattern 'matched 0 entries'
            Assert-False (Test-Path -LiteralPath (Join-Path $bundle 'licenses'))
            Remove-Item -LiteralPath $wheel
            New-OrtLicenseZipFixture -Path $wheel -DirectMl 'other runtime'
            Assert-Throws { Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -DirectMlDll $directMl } -MessagePattern 'DirectML runtime differs'
            Assert-False (Test-Path -LiteralPath (Join-Path $bundle 'licenses'))
            Remove-Item -LiteralPath $wheel
            New-OrtLicenseZipFixture -Path $wheel -DirectMl 'directml runtime'
            $out = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle -DirectMlDll $directMl
            Assert-Equal 'original notices' ([IO.File]::ReadAllText((Join-Path $out 'ThirdPartyNotices.txt')))
        }
    }

    It 'verifies both original texts inside the completed archive' {
        Invoke-OrtLicenseFixture { param($dir, $wheels, $bundle, $dll)
            $licenses = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle
            $archive = Join-Path $dir 'app.zip'
            Assert-Throws { Assert-OrtWheelLicensesInPackage -Path $archive -LicenseDirectory $licenses -Format msi } -MessagePattern 'WiX source is required'
            foreach ($path in 'licenses/onnxruntime', 'runtime/Lib/site-packages/onnxruntime') {
                New-OrtLicenseZipFixture -Path $archive -Archive -ArchiveDirectory $path
                Assert-OrtWheelLicensesInPackage -Path $archive -LicenseDirectory $licenses -Format archive -ArchivePrefix app -ArchiveDirectory $path
                Remove-Item -LiteralPath $archive
                New-OrtLicenseZipFixture -Path $archive -Notice 'wrong notice' -Archive -ArchiveDirectory $path
                Assert-Throws { Assert-OrtWheelLicensesInPackage -Path $archive -LicenseDirectory $licenses -Format archive -ArchivePrefix app -ArchiveDirectory $path } -MessagePattern 'verification failed'
                Remove-Item -LiteralPath $archive
            }
        }
    }

    It 'makes Python ORT checks optional but rejects mismatched or missing installed texts' {
        Invoke-OrtLicenseFixture { param($dir, $wheels, $bundle, $dll)
            Assert-Equal '' (Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir (Join-Path $dir 'absent-wheel-store'))
            $ort = Join-Path $bundle 'runtime/Lib/site-packages/onnxruntime'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $ort 'capi')
            Copy-Item -LiteralPath $dll -Destination (Join-Path $ort 'capi/onnxruntime.dll')
            $source = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle
            Copy-OrtFixtureTexts -Source $source -Destination $ort
            Assert-Equal $ort (Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels)
            Invoke-WithProcessEnvironment -Environment @{ ORT_CHAIN_WHEEL_DIR = $wheels } -ScriptBlock {
                Assert-Equal $ort (Resolve-PythonOrtLicenses -Bundle $bundle)
            }
            [IO.File]::WriteAllText((Join-Path $ort 'ThirdPartyNotices.txt'), 'wrong notice')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels } -MessagePattern 'differs from matching wheel'
            Remove-Item -LiteralPath (Join-Path $ort 'LICENSE')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels }
            Copy-OrtFixtureTexts -Source $source -Destination $ort
            [IO.File]::WriteAllText((Join-Path $ort 'capi/onnxruntime.dll'), 'unmatched')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels } -MessagePattern 'matched 0 wheels'
        }
    }

    It 'requires selected Python providers from the same wheel as the core' {
        Invoke-OrtLicenseFixture -NoWheel { param($dir, $wheels, $bundle, $dll)
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda } -MessagePattern 'required'
            $ort = Join-Path $bundle 'runtime/Lib/site-packages/onnxruntime'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $ort 'capi')
            Copy-Item -LiteralPath $dll -Destination (Join-Path $ort 'capi/onnxruntime.dll')
            $wheel = Join-Path $wheels 'onnxruntime_gpu-1.2.3-cp315-cp315-win_amd64.whl'
            New-OrtLicenseZipFixture -Path $wheel -Provider 'cuda provider' -Extension 'python extension' -DirectMl 'directml runtime'
            $source = Copy-OrtWheelLicenses -OrtDll $dll -WheelDir $wheels -Destination $bundle
            Copy-OrtFixtureTexts -Source $source -Destination $ort
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda }
            $provider = Join-Path $ort 'capi/onnxruntime_providers_cuda.dll'
            [IO.File]::WriteAllText($provider, 'wrong provider')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda } -MessagePattern 'differs from the matching wheel'
            [IO.File]::WriteAllText($provider, 'cuda provider')
            Assert-Equal $ort (Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda)
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider '../cuda' } -MessagePattern 'Invalid Python ORT provider'
            $extension = Join-Path $ort 'capi/onnxruntime_pybind11_state.pyd'
            [IO.File]::WriteAllText($extension, 'wrong extension')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda -RequirePythonExtension } -MessagePattern 'extension differs'
            [IO.File]::WriteAllText($extension, 'python extension')
            Assert-Equal $ort (Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda -RequirePythonExtension)
            $directMl = Join-Path $ort 'capi/DirectML.dll'
            [IO.File]::WriteAllText($directMl, 'wrong directml')
            Assert-Throws { Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequireDirectMl } -MessagePattern 'DirectML runtime differs'
            [IO.File]::WriteAllText($directMl, 'directml runtime')
            Assert-Equal $ort (Resolve-PythonOrtLicenses -Bundle $bundle -WheelDir $wheels -RequiredProvider cuda -RequirePythonExtension -RequireDirectMl)
        }
    }

}
