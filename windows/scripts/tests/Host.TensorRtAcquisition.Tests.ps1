#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Install-Tensorrt archive acquisition' {
    foreach ($name in 'Find-TensorRtZipIn', 'Find-TensorRtStagedZip', 'Get-TensorRtZipUrl', 'Invoke-TensorRtZipDownload', 'Resolve-TensorRtZip') {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-Tensorrt.ps1' -FunctionName $name)
    }
    $script:trtAttempts = [System.Collections.Generic.List[string]]::new()
    $script:trtDownloadWorks = $true
    function Resolve-ContainerImageValue { '13.4' }
    function Invoke-DownloadWithRetry {
        param([string]$Url, [string]$ExpectSignature)
        $script:trtAttempts.Add($Url)
        if ($ExpectSignature -ne 'PK') { throw 'the download must refuse a non-zip answer' }
        if (-not $script:trtDownloadWorks) { throw 'download rejected' }
    }

    It 'prefers the newest repo archive before a public download' {
        Invoke-InTestDir {
            param($dir)
            $repo = Join-Path $dir 'repo'
            $public = Join-Path $dir 'public'
            New-Item -ItemType Directory -Path $repo, $public | Out-Null
            foreach ($name in 'TensorRT-10.2.zip', 'TensorRT-Enterprise-10.4.0.1-Windows-amd64-cuda-13.4-Release-external.zip') {
                Set-Content -LiteralPath (Join-Path $repo $name) -Value fixture
            }
            Set-Content -LiteralPath (Join-Path $public 'TensorRT-11.0.zip') -Value fixture
            Assert-Equal (Join-Path $repo 'TensorRT-Enterprise-10.4.0.1-Windows-amd64-cuda-13.4-Release-external.zip') (Find-TensorRtStagedZip -RepoDir $repo -PublicDir $public 6>$null)
        }
    }

    It 'names the TensorRT 11 zip NVIDIA serves for the pin and the image CUDA line' {
        Assert-Equal 'https://developer.nvidia.com/downloads/compute/machine-learning/tensorrt/11.4.0/zip/TensorRT-Enterprise-11.4.0.106-Windows-amd64-cuda-13.4-Release-external.zip' (Get-TensorRtZipUrl -Version '11.4.0.106' -Cuda '13.4')
    }

    It 'downloads only the CUDA pin and reports success only on a fetched archive' {
        $script:trtAttempts.Clear()
        $script:trtDownloadWorks = $true
        Assert-True (Invoke-TensorRtZipDownload -Version '11.4.0.106' -Destination 'fixture.zip' 6>$null)
        Assert-Equal 1 $script:trtAttempts.Count
        Assert-Match 'cuda-13\.4-Release-external\.zip$' $script:trtAttempts[0]
        $script:trtAttempts.Clear()
        $script:trtDownloadWorks = $false
        Assert-False (Invoke-TensorRtZipDownload -Version '11.4.0.106' -Destination 'fixture.zip' 6>$null)
        Assert-Equal 1 $script:trtAttempts.Count
    }

    It 'throws instead of continuing without TensorRT when nothing is staged and the download fails' {
        Invoke-InTestDir {
            param($dir)
            $script:trtDownloadWorks = $false
            Assert-Throws { Resolve-TensorRtZip -RepoDir $dir -Version '11.4.0.106' -Destination (Join-Path $dir 't.zip') 6>$null } -MessagePattern 'nvidia lane needs TensorRT'
            Assert-Throws { Resolve-TensorRtZip -RepoDir $dir -Version '' -Destination (Join-Path $dir 't.zip') 6>$null } -MessagePattern 'TENSORRT_VERSION is empty'
        }
    }

    It 'takes a staged zip before downloading and the download when nothing is staged' {
        Invoke-InTestDir {
            param($dir)
            $script:trtAttempts.Clear()
            $script:trtDownloadWorks = $true
            $dest = Join-Path $dir 't.zip'
            Assert-Equal $dest (Resolve-TensorRtZip -RepoDir $dir -Version '11.4.0.106' -Destination $dest 6>$null)
            Assert-Equal 1 $script:trtAttempts.Count
            $staged = Join-Path $dir 'TensorRT-Enterprise-11.4.0.106-Windows-amd64-cuda-13.4-Release-external.zip'
            Set-Content -LiteralPath $staged -Value fixture
            $script:trtAttempts.Clear()
            Assert-Equal $staged (Resolve-TensorRtZip -RepoDir $dir -Version '11.4.0.106' -Destination $dest 6>$null)
            Assert-Equal 0 $script:trtAttempts.Count
        }
    }

    It 'leaves no graceful skip in the installer or the extract stage' {
        $installer = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/host/Install-Tensorrt.ps1')
        Assert-False ($installer -match 'WITHOUT TensorRT') 'the installer still carries the graceful skip'
        $tree = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/build/Set-TensorrtTree.ps1')
        Assert-Match "absent after Install-Tensorrt\.ps1" $tree
    }

    It 'requires the TensorRT tree in the smoke gate of an nvidia image' {
        $smoke = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/build/Test-Container.ps1')
        Assert-Match ([regex]::Escape("if (`$ExpectGpu) { Assert-Test -Name 'TensorRT runtime staged (-ExpectGpu)' -Condition { `$script:tensorRtStaged }")) $smoke
    }
}
