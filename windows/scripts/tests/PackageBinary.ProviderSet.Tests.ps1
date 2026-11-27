#requires -Version 7.0
# Checks the provider-set verdict on ZIP fixtures; enumeration has PackageBinary.Common, a real MSI has Msi.InstalledPath.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsPackageBinary.Common.psm1') -DisableNameChecking -ErrorAction Stop

function New-ProviderSetZip {
    param([string]$Dir, [string[]]$Provider)
    $zip = Join-Path $Dir 'package.zip'
    $members = @{ 'app/bin/onnxruntime.dll' = 'core' }
    foreach ($name in $Provider) { $members["app/bin/onnxruntime_providers_$name.dll"] = $name }
    New-TestZipFile -Path $zip -Member $members
    return $zip
}

function Get-ProviderSetName {
    param([string[]]$Provider)
    return @($Provider | ForEach-Object { "onnxruntime_providers_$_.dll" })
}

Describe 'Finished-package ORT provider set' {
    It 'accepts the proven providers in any order and ignores the rest of the family' {
        Invoke-InTestDir { param($dir)
            $zip = New-ProviderSetZip -Dir $dir -Provider cuda, shared
            $proven = @('onnxruntime.dll', 'DirectML.dll', 'onnxruntime_pybind11_state.pyd') + (Get-ProviderSetName shared, cuda)
            Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected $proven -Label 'ZIP'
        }
    }
    It 'rejects a missing provider and names both sets' {
        Invoke-InTestDir { param($dir)
            $zip = New-ProviderSetZip -Dir $dir -Provider shared
            $pattern = '^ZIP ORT providers differ from the proven set in .*package\.zip: expected onnxruntime_providers_cuda\.dll, onnxruntime_providers_shared\.dll; found onnxruntime_providers_shared\.dll$'
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected (Get-ProviderSetName cuda, shared) -Label 'ZIP' } -MessagePattern $pattern
        }
    }
    It 'rejects an extra provider and an empty package directory' {
        Invoke-InTestDir { param($dir)
            $zip = New-ProviderSetZip -Dir $dir -Provider cuda, shared
            $extra = 'expected onnxruntime_providers_shared\.dll; found onnxruntime_providers_cuda\.dll, onnxruntime_providers_shared\.dll$'
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected (Get-ProviderSetName shared) -Label 'MSIX' } -MessagePattern "^MSIX ORT providers differ.*$extra"
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app' -Expected (Get-ProviderSetName shared) -Label 'ZIP' } -MessagePattern 'found \(none\)$'
        }
    }
    It 'refuses a proven list without providers, a duplicate and a miscased provider' {
        Invoke-InTestDir { param($dir)
            $zip = New-ProviderSetZip -Dir $dir -Provider @()
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected 'onnxruntime.dll' -Label 'ZIP' } -MessagePattern '^ZIP proven names carry no ORT provider$'
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected (Get-ProviderSetName shared, shared) -Label 'ZIP' } -MessagePattern 'duplicate ORT provider name'
            Assert-Throws { Assert-PackageOrtProviderSet -Path $zip -Directory 'app/bin' -Expected 'ONNXRUNTIME_PROVIDERS_SHARED.DLL' -Label 'ZIP' } -MessagePattern 'invalid ORT provider name'
        }
    }
    It 'hands the MSI root to the enumeration' {
        Invoke-InTestDir { param($dir)
            $msi = Join-Path $dir 'package.msi'
            [IO.File]::WriteAllText($msi, 'not an installer database')
            $proven = Get-ProviderSetName shared
            Assert-Throws { Assert-PackageOrtProviderSet -Path $msi -Expected $proven -Label 'MSI' } -MessagePattern 'requires a root directory identifier'
            $caught = try { Assert-PackageOrtProviderSet -Path $msi -Expected $proven -Label 'MSI' -RootDirectoryId INSTALLFOLDER; '' } catch { $_.Exception.Message }
            Assert-True ($caught -and $caught -notmatch 'requires a root directory identifier') "the MSI root must reach the reader: $caught"
        }
    }
}
