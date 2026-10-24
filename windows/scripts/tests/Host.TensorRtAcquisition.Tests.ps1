#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Install-Tensorrt archive acquisition' {
    foreach ($name in 'Find-TensorRtZipIn', 'Find-TensorRtStagedZip', 'Invoke-TensorRtZipDownload') {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-Tensorrt.ps1' -FunctionName $name)
    }
    $script:trtAttempts = [System.Collections.Generic.List[string]]::new()
    $script:trtSuccessSuffix = ''
    function Resolve-ContainerImageValue { '13.4' }
    function Invoke-DownloadWithRetry {
        param([string]$Url)
        $script:trtAttempts.Add($Url)
        if ($Url -notlike "*$script:trtSuccessSuffix") { throw 'download rejected' }
    }

    It 'prefers the newest repo archive before a public download' {
        Invoke-InTestDir {
            param($dir)
            $repo = Join-Path $dir 'repo'
            $public = Join-Path $dir 'public'
            New-Item -ItemType Directory -Path $repo, $public | Out-Null
            foreach ($name in 'TensorRT-10.2.zip', 'TensorRT-10.4.zip') {
                Set-Content -LiteralPath (Join-Path $repo $name) -Value fixture
            }
            Set-Content -LiteralPath (Join-Path $public 'TensorRT-11.0.zip') -Value fixture
            Assert-Equal (Join-Path $repo 'TensorRT-10.4.zip') (Find-TensorRtStagedZip -RepoDir $repo -PublicDir $public)
        }
    }

    It 'tries the CUDA pin then two fallbacks and reports success only on a fetched archive' {
        $script:trtAttempts.Clear()
        $script:trtSuccessSuffix = 'cuda-12.8.zip'
        Assert-True (Invoke-TensorRtZipDownload -Version '10.4.0.26' -Destination 'fixture.zip' 6>$null)
        Assert-Equal 3 $script:trtAttempts.Count
        Assert-Match 'cuda-13.4.zip$' $script:trtAttempts[0]
        Assert-Match 'cuda-12.8.zip$' $script:trtAttempts[2]
        $script:trtAttempts.Clear()
        $script:trtSuccessSuffix = 'never.zip'
        Assert-False (Invoke-TensorRtZipDownload -Version '10.4.0.26' -Destination 'fixture.zip' 6>$null)
        Assert-Equal 3 $script:trtAttempts.Count
    }
}
