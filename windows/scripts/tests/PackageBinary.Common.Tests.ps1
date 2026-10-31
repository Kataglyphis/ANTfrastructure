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
    It 'requires the full ORT family in the declared directory and rejects extra copies' {
        Invoke-InTestDir { param($dir)
            $names = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'DirectML.dll')
            $bundle = Join-Path $dir 'bundle'; $bin = Join-Path $bundle 'bin'
            $null = New-Item -ItemType Directory -Path $bin -Force
            foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $bin $name), $name) }
            Assert-PackageOrtFamily -Path $bundle -Directory 'bin' -Name $names
            $nested = Join-Path $bin 'models'; $null = New-Item -ItemType Directory -Path $nested
            [IO.File]::WriteAllText((Join-Path $nested 'onnxruntime.dll'), 'extra')
            Assert-Throws { Assert-PackageOrtFamily -Path $bundle -Directory 'bin' -Name $names } -MessagePattern 'nested'
            Remove-Item -LiteralPath (Join-Path $nested 'onnxruntime.dll')
            $zip = Join-Path $dir 'candidate.zip'
            $members = @{}; foreach ($name in $names) { $members["root/bin/$name"] = $name }
            New-TestZipFile -Path $zip -Member $members
            Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names
            Remove-Item -LiteralPath $zip
            $members['root/bin/models/onnxruntime.dll'] = 'extra'
            New-TestZipFile -Path $zip -Member $members
            Assert-Throws { Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names } -MessagePattern 'nested'
            Remove-Item -LiteralPath $zip; $members.Remove('root/bin/models/onnxruntime.dll')
            New-TestZipFile -Path $zip -Member $members -DuplicateName @('root/bin/onnxruntime.dll')
            Assert-Throws { Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names } -MessagePattern 'duplicate'
            Remove-Item -LiteralPath $zip; $members.Remove('root/bin/onnxruntime.dll')
            New-TestZipFile -Path $zip -Member $members
            Assert-Throws { Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names } -MessagePattern 'missing'
        }
    }
    It 'rejects extra family members, aliased archive paths and linked entries' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'candidate.zip'
            $names = @('onnxruntime.dll')
            foreach ($extra in @('root/bin/onnxruntime_genai.dll', 'root/bin\onnxruntime.dll', 'root/bin/onnxruntime.dll.')) {
                New-TestZipFile -Path $zip -Member @{ 'root/bin/onnxruntime.dll' = 'core'; $extra = 'unexpected' }
                Assert-Throws { Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names } -MessagePattern 'ORT family archive'
                Remove-Item -LiteralPath $zip
            }
            New-TestZipFile -Path $zip -Member @{ 'root/bin/onnxruntime.dll' = 'link' }
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
            try { $archive.GetEntry('root/bin/onnxruntime.dll').ExternalAttributes = -1610612736 } finally { $archive.Dispose() }
            Assert-Throws { Assert-PackageOrtFamily -Path $zip -Directory 'root/bin' -Name $names } -MessagePattern 'linked'
        }
    }
}
