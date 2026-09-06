#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Write-BundleManifest.ps1 (#130) writes the bundle's self-description into
# C:\runtime: BUNDLE-ENV.cmd, BUNDLE-ENV.ps1 and BUNDLE-README.md. It is the
# consumer-side entry point: a consumer who copies C:\runtime to a device had
# to reverse-engineer the DLL homes from the tree before this existed.
#
# The script has no functions to lift — it is procedural — so this suite runs
# it against a synthetic bundle tree in a temp directory and checks the output
# files. WINDOWS_TARGET_ARCH controls the arch the script reports.

Describe 'write-bundle-manifest: bundle self-description' {

    BeforeAll {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('bundlemanifest-' + [guid]::NewGuid().ToString('N'))
        $script:runtime = Join-Path $script:tmp 'runtime'
        New-Item -ItemType Directory -Force -Path $script:runtime | Out-Null
        $script:scriptPath = Join-Path (Get-RepoRoot) 'windows\scripts\build\Write-BundleManifest.ps1'

        # Save env vars we mutate so AfterAll can restore them.
        $script:savedArch = [Environment]::GetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'Process')
        $script:savedEnv = @{}
        foreach ($n in 'FFMPEG_BIN', 'OPENCV_BIN', 'ONNX_ROOT', 'GSTREAMER_BIN', 'VULKAN_SDK') {
            $script:savedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
        }
    }

    AfterAll {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
        # Restore env vars.
        if ($null -ne $script:savedArch) { [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', $script:savedArch, 'Process') } else { [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', $null, 'Process') }
        foreach ($kv in $script:savedEnv.GetEnumerator()) {
            if ($null -ne $kv.Value) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process') } else { [Environment]::SetEnvironmentVariable($kv.Key, $null, 'Process') }
        }
    }

    It 'writes all three output files for an amd64 bundle' {
        [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'amd64', 'Process')
        # Synthetic DLL homes: bin + a wheel store.
        $binDir = Join-Path $script:runtime 'bin'; New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $wheelDir = Join-Path $script:runtime 'wheels'; New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null
        Set-Content (Join-Path $wheelDir 'onnxruntime-1.22.0-cp314-cp314-win_amd64.whl') 'fake'
        Set-Content (Join-Path $wheelDir 'av-18.1.0-cp314-cp314-win_amd64.whl') 'fake'

        & $script:scriptPath -InstallDir $script:runtime 2>&1 | Out-Null

        Assert-True (Test-Path (Join-Path $script:runtime 'BUNDLE-ENV.cmd')) 'BUNDLE-ENV.cmd written'
        Assert-True (Test-Path (Join-Path $script:runtime 'BUNDLE-ENV.ps1')) 'BUNDLE-ENV.ps1 written'
        Assert-True (Test-Path (Join-Path $script:runtime 'BUNDLE-README.md')) 'BUNDLE-README.md written'
    }

    It 'BUNDLE-ENV.cmd registers the bundle root and arch' {
        $cmd = Get-Content (Join-Path $script:runtime 'BUNDLE-ENV.cmd') -Raw
        Assert-True ($cmd -match "KATA_BUNDLE_ROOT=$([regex]::Escape($script:runtime))") 'bundle root set'
        Assert-True ($cmd -match 'KATA_BUNDLE_ARCH=amd64') 'arch is amd64'
        Assert-True ($cmd -match 'set "PATH=') 'PATH prepend line present'
    }

    It 'BUNDLE-ENV.ps1 registers the same facts in PowerShell syntax' {
        $ps = Get-Content (Join-Path $script:runtime 'BUNDLE-ENV.ps1') -Raw
        Assert-True ($ps -match "KATA_BUNDLE_ROOT = '") 'bundle root set'
        Assert-True ($ps -match "KATA_BUNDLE_ARCH = 'amd64'") 'arch is amd64'
        Assert-True ($ps -match 'env:PATH =') 'PATH prepend line present'
    }

    It 'BUNDLE-README.md names the target arch and lists the wheel store' {
        $md = Get-Content (Join-Path $script:runtime 'BUNDLE-README.md') -Raw
        Assert-True ($md -match 'amd64') 'README names amd64'
        Assert-True ($md -match 'onnxruntime-1.22.0') 'README lists the ORT wheel'
        Assert-True ($md -match 'av-18.1.0') 'README lists the PyAV wheel'
    }

    It 'BUNDLE-README.md notes the cross-build caveat on arm64 but not on amd64' {
        # amd64 (native lane): the README says the tree IS the image ENV.
        $md = Get-Content (Join-Path $script:runtime 'BUNDLE-README.md') -Raw
        Assert-True ($md -match 'native') 'amd64 README mentions native lane'
        Assert-False ($md -match 'cross-compiled artifact bundle') 'amd64 README does not carry the cross caveat'
    }

    It 'writes the cross-build caveat for an arm64 bundle' {
        [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'arm64', 'Process')
        # Clear the old output so we don't read stale content.
        Remove-Item (Join-Path $script:runtime 'BUNDLE-README.md') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:runtime 'BUNDLE-ENV.cmd') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:runtime 'BUNDLE-ENV.ps1') -Force -ErrorAction SilentlyContinue

        & $script:scriptPath -InstallDir $script:runtime 2>&1 | Out-Null

        $md = Get-Content (Join-Path $script:runtime 'BUNDLE-README.md') -Raw
        Assert-True ($md -match 'cross-compiled artifact bundle') 'arm64 README carries the cross caveat'
        Assert-True ($md -match 'arm64') 'README names arm64'

        $cmd = Get-Content (Join-Path $script:runtime 'BUNDLE-ENV.cmd') -Raw
        Assert-True ($cmd -match 'KATA_BUNDLE_ARCH=arm64') 'arm64 BUNDLE-ENV.cmd arch'
    }

    It 'registers existing *_BIN env vars as DLL homes' {
        [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'amd64', 'Process')
        [Environment]::SetEnvironmentVariable('FFMPEG_BIN', (Join-Path $script:runtime 'ffmpeg-bin'), 'Process')
        New-Item -ItemType Directory -Force -Path (Join-Path $script:runtime 'ffmpeg-bin') | Out-Null

        & $script:scriptPath -InstallDir $script:runtime 2>&1 | Out-Null

        $cmd = Get-Content (Join-Path $script:runtime 'BUNDLE-ENV.cmd') -Raw
        Assert-True ($cmd -match 'FFMPEG_BIN') 'FFMPEG_BIN registered'
        Assert-True ($cmd -match 'ffmpeg-bin') 'FFMPEG_BIN path in BUNDLE-ENV.cmd'

        [Environment]::SetEnvironmentVariable('FFMPEG_BIN', $null, 'Process')
    }

    It 'throws when the install directory does not exist' {
        [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'amd64', 'Process')
        $missing = Join-Path $script:tmp 'does-not-exist'
        $threw = $false
        try { & $script:scriptPath -InstallDir $missing 2>&1 | Out-Null } catch { $threw = $true }
        Assert-True $threw 'missing install dir throws, never silently writes nothing'
    }

    It 'records an ABSENT marker when one is present in the tree' {
        [Environment]::SetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'arm64', 'Process')
        $markerDir = Join-Path $script:runtime 'lib\tvm'
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
        Set-Content (Join-Path $markerDir 'ABSENT-ON-ARM64.txt') "TVM compiler needs target LLVM"

        & $script:scriptPath -InstallDir $script:runtime 2>&1 | Out-Null

        $md = Get-Content (Join-Path $script:runtime 'BUNDLE-README.md') -Raw
        Assert-True ($md -match 'ABSENT-ON-ARM64') 'README lists the absent marker'
        Assert-True ($md -match 'TVM compiler') 'README carries the marker reason'
    }
}
