#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Offline source and cache fixtures exercise the install input contract.

. (Join-Path $PSScriptRoot 'Import-TorchRocmTestSetup.ps1')

Describe 'Install-TorchRocm: offline install inputs' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Get-TorchRocmCachedPath', 'Get-TorchRocmRequirement', 'Get-TorchRocmInstallCommand'))

    It 'writes one hash-pinned reference per file: the pinned ones from the hash-keyed cache, the built ones where they are mounted' {
        $set = Get-TorchRocmTestSet
        $pins = $set.Pins
        $built = @(Get-TorchRocmBuiltWheelFact)
        $lines = @(Get-TorchRocmRequirement -Wheels ($built + @($set.Wheels)) -CacheDir 'C:\uvcache\torch-rocm')
        Assert-Equal 7 $lines.Count 'requirement lines (2 built, 5 AMD runtime)'
        foreach ($l in @($lines | Select-Object -Skip 2)) { Assert-Match '^[a-z0-9-]+ @ file:///C:/uvcache/torch-rocm/[0-9a-f]{64}/\S+ --hash=sha256:[0-9a-f]{64}$' $l 'pinned requirement shape' }
        Assert-Equal "torch @ file:///C:/bkmnt/torch-rocm-wheels/$($script:TorchRocmBuiltName[0]) --hash=sha256:$('a' * 64)" $lines[0] 'the built torch, from its mount'
        Assert-Equal "torchvision @ file:///C:/bkmnt/torch-rocm-wheels/$($script:TorchRocmBuiltName[1]) --hash=sha256:$('a' * 64)" $lines[1] 'the built torchvision'
        $core = @($lines | Where-Object { $_ -like 'rocm-sdk-core @ *' })[0]
        Assert-True $core.EndsWith("--hash=sha256:$($pins['TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'])") 'rocm-sdk-core hash'
        foreach ($dist in 'rocm', 'rocm-sdk-libraries', 'rocm-sdk-device-gfx1200', 'rocm-sdk-device-gfx1201') {
            Assert-Equal 1 @($lines | Where-Object { $_ -like "$dist @ *" }).Count "one line for $dist"
        }
    }

    It 'installs offline and exactly: no index, no deps, no build isolation, hashes required' {
        $cmd = Get-TorchRocmInstallCommand -VenvPython 'C:\opt\OrchestrANT\.venv\Scripts\python.exe' -RequirementsFile 'C:\t\req.txt' -GfxTarget (Get-TorchRocmTestSet).GfxTarget
        foreach ($flag in '--no-index', '--no-deps', '--no-build-isolation', '--require-hashes', '--force-reinstall') {
            Assert-True $cmd.Contains($flag) "missing $flag in: $cmd"
        }
        Assert-True $cmd.Contains('--python "C:\opt\OrchestrANT\.venv\Scripts\python.exe"') 'venv interpreter, quoted'
        Assert-True $cmd.EndsWith('-r "C:\t\req.txt"') 'requirements file, quoted'
        $uv = $cmd.IndexOf('uv pip install')
        foreach ($set in 'set "UV_NO_CACHE=1" && ', 'set "UV_LINK_MODE=copy" && ', 'set "ROCM_SDK_TARGET_FAMILY=gfx1201" && ', 'set "ROCM_BOOTSTRAP_DISABLE_DETECTION=1" && ') {
            $at = $cmd.IndexOf($set)
            Assert-True ($at -ge 0 -and $at -lt $uv) "missing, or after uv: $set in: $cmd"
        }
        Assert-Throws { Get-TorchRocmInstallCommand -VenvPython 'p' -RequirementsFile 'r' -GfxTarget 'gfx1201 & calc' } 'a GPU target cmd would run' -MessagePattern 'GfxTarget'
    }

    It 'the env reaches the command through cmd and never the calling process' {
        $cmd = Get-TorchRocmInstallCommand -VenvPython 'p' -RequirementsFile 'r' -GfxTarget 'gfx1201'
        $probe = $cmd.Substring(0, $cmd.IndexOf('uv pip install')) + 'set ROCM_'
        $out = Invoke-WithEnv @{ ROCM_SDK_TARGET_FAMILY = $null; ROCM_BOOTSTRAP_DISABLE_DETECTION = $null } {
            @(& cmd.exe /s /c " $probe 2>&1")
            Assert-Null $env:ROCM_SDK_TARGET_FAMILY 'the calling process env stays untouched'
        }
        Assert-True (@($out) -contains 'ROCM_SDK_TARGET_FAMILY=gfx1201') "cmd saw: $($out -join ' | ')"
        Assert-True (@($out) -contains 'ROCM_BOOTSTRAP_DISABLE_DETECTION=1') "cmd saw: $($out -join ' | ')"
    }
}

Describe 'Install-TorchRocm: hash-keyed wheel cache' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName 'Get-TorchRocmCachedPath', 'Save-TorchRocmWheel')
    function New-TorchRocmFakeWheel { param([string]$Dir)
        $src = Join-Path $Dir 'src\fake_pkg-1.0-py3-none-any.whl'
        New-Item -ItemType Directory -Force -Path (Split-Path $src -Parent) | Out-Null
        [System.IO.File]::WriteAllBytes($src, [byte[]](@(0x50, 0x4B) + [System.Text.Encoding]::ASCII.GetBytes('fake wheel body')))
        return [pscustomobject]@{
            FileName = 'fake_pkg-1.0-py3-none-any.whl'; Url = ([uri]$src).AbsoluteUri; IsSdist = $false
            Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant(); Cache = (Join-Path $Dir 'cache')
        }
    }
    # The fake wheel, already fetched once into its cache (.Path).
    function Save-TorchRocmFakeWheel { param([string]$Dir)
        $w = New-TorchRocmFakeWheel -Dir $Dir
        return ($w | Add-Member -NotePropertyName Path -NotePropertyValue (Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0) -PassThru)
    }

    It 'fetches into <cache>\<sha256>\<file>, then serves that copy with the source gone' {
        Invoke-InTestDir { param($dir)
            $w = Save-TorchRocmFakeWheel -Dir $dir
            Assert-Equal (Join-Path $w.Cache "$($w.Sha256)\$($w.FileName)") $w.Path 'cache layout'
            $w.Url = ([uri](Join-Path $dir 'nowhere\fake_pkg-1.0-py3-none-any.whl')).AbsoluteUri
            Assert-Equal $w.Path (Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0) 'cached copy reused offline'
        }
    }

    It 'a cached copy that fails its SHA256 is fetched again, never used' {
        Invoke-InTestDir { param($dir)
            $w = Save-TorchRocmFakeWheel -Dir $dir
            [System.IO.File]::WriteAllText($w.Path, 'PK tampered')
            [void](Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0 3>$null)
            Assert-Equal $w.Sha256 (Get-FileHash -Algorithm SHA256 -LiteralPath $w.Path).Hash.ToLowerInvariant() 'refetched bytes'
        }
    }

    It 'a download that does not match its pin throws and leaves nothing in the cache' {
        Invoke-InTestDir { param($dir)
            $w = New-TorchRocmFakeWheel -Dir $dir
            $w.Sha256 = '0' * 64
            Assert-Throws { Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0 } 'SHA256 mismatch' -MessagePattern 'SHA256 mismatch'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $w.Cache -Recurse -File -ErrorAction SilentlyContinue).Count 'no file left behind'
        }
    }

    It 'renames nothing on the cache mount, where a rename failed ERROR_PATH_NOT_FOUND (2026-09-25)' {
        $body = (Get-Command Save-TorchRocmWheel).Definition
        Assert-Match 'Invoke-DownloadWithRetry -Url \$Wheel\.Url -DestinationPath \$dest ' $body 'downloads to the cache path itself'
        # \b: -match ignores case, and Remove-Item ends in 'move-Item'.
        Assert-False ($body -match '\b(Move|Rename)-Item\b|\[System\.IO\.File\]::Move') 'no rename'
    }
}

