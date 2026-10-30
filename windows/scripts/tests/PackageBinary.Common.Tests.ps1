#requires -Version 7.0
# Checks wrapper-to-verifier behavior on ZIP fixtures; MSI table mapping has its own suite.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsPackageBinary.Common.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'Finished-package binary verification' {
    It 'accepts exact binary bytes and rejects a source mutation' {
        Invoke-InTestDir { param($dir)
            $source = Join-Path $dir 'provider.dll'
            [IO.File]::WriteAllBytes($source, [byte[]](77, 90, 13, 10, 0, 255))
            $shared = Join-Path $dir 'shared.dll'
            [IO.File]::WriteAllText($shared, 'shared provider')
            $zip = Join-Path $dir 'package.zip'
            New-TestZipFile -Path $zip -Member @{ 'app/provider.dll' = $source; 'app/shared.dll' = $shared } -FileValues
            Assert-PackageBinary -Path $zip -Member 'app/provider.dll' -SourcePath $source
            Assert-PackageBinary -Path $zip -Member @('app/provider.dll', 'app/shared.dll') -SourcePath @($source, $shared)
            Assert-Throws { Assert-PackageBinary -Path $zip -Member @('app/provider.dll', 'app/shared.dll') -SourcePath $source } -MessagePattern 'equal, nonzero counts'
            [IO.File]::WriteAllBytes($source, [byte[]](77, 90, 10, 0, 255))
            Assert-Throws { Assert-PackageBinary -Path $zip -Member 'app/provider.dll' -SourcePath $source } -MessagePattern 'package binary verification failed'
            Assert-Throws { Assert-PackageBinary -Path $zip -Member @('app/provider.dll', 'app/shared.dll') -SourcePath @($source, $shared) } -MessagePattern 'package binary verification failed'
        }
    }
    It 'rejects an absent or duplicate package member' {
        Invoke-InTestDir { param($dir)
            $source = Join-Path $dir 'provider.dll'
            [IO.File]::WriteAllText($source, 'provider')
            $zip = Join-Path $dir 'package.zip'
            New-TestZipFile -Path $zip -Member @{ 'app/provider.dll' = $source } -FileValues -DuplicateName @('app/provider.dll')
            Assert-Throws { Assert-PackageBinary -Path $zip -Member 'app/provider.dll' -SourcePath $source } -MessagePattern 'package binary verification failed'
            Assert-Throws { Assert-PackageBinary -Path $zip -Member 'app/missing.dll' -SourcePath $source } -MessagePattern 'package binary verification failed'
        }
    }
    It 'enumerates only providers in the exact archive directory and rejects aliases' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'providers.zip'
            $prefix = 'app/runtime/capi'
            $shared = 'onnxruntime_providers_shared.dll'
            $cuda = 'onnxruntime_providers_cuda.dll'
            New-TestZipFile -Path $zip -Member @{ "$prefix/$shared" = 'bridge'; "$prefix/$cuda" = 'cuda'; 'other/onnxruntime_providers_other.dll' = 'other' }
            Assert-Equal "$cuda,$shared" (@(Get-PackageOrtProviderNames -Path $zip -Directory $prefix) -join ',')
            Remove-Item -LiteralPath $zip
            New-TestZipFile -Path $zip -Member @{ "$prefix/$shared" = 'bridge' } -DuplicateName @("$prefix/$shared")
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory $prefix } -MessagePattern 'duplicate'
            Remove-Item -LiteralPath $zip
            New-TestZipFile -Path $zip -Member @{ "$prefix/$shared" = 'bridge'; "app/runtime/capi/ONNXRUNTIME_PROVIDERS_CUDA.dll" = 'alias' }
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory $prefix } -MessagePattern 'invalid ORT provider name'
            Remove-Item -LiteralPath $zip
            New-TestZipFile -Path $zip -Member @{ "app/runtime/./capi/$shared" = 'alias' }
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory $prefix } -MessagePattern 'aliased'
            Remove-Item -LiteralPath $zip
            New-TestZipFile -Path $zip -Member @{ "app/runtime/else/../capi/$shared" = 'alias' }
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory $prefix } -MessagePattern 'unsafe provider archive path'
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory '../capi' } -MessagePattern 'unsafe package directory'
            Remove-Item -LiteralPath $zip
            New-TestZipFile -Path $zip -Member @{ "$prefix/$shared" = 'link' }
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
            try { $archive.GetEntry("$prefix/$shared").ExternalAttributes = -1610612736 } finally { $archive.Dispose() }
            Assert-Throws { Get-PackageOrtProviderNames -Path $zip -Directory $prefix } -MessagePattern 'non-file provider'
        }
    }
}
