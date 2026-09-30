#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real uv or import cv2 (the image's cv2 exists only there; OrchestrANT's Windows CI imports it).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

# An image runtime whose OpenCV needs FFmpeg from its own PATH dir (the 2026-10-01 bundle gap), a venv, and the chain cv2.
function script:New-ChainOpenCvFixture {
    param([Parameter(Mandatory)][string]$Dir, [string[]]$DistInfo = @(), [switch]$NoSource)
    $root = Join-Path $Dir 'runtime'
    $ocvBin = Join-Path $root 'lib\opencv5\x64\vc18\bin'
    $ffBin = Join-Path $root 'ffmpeg\bin'
    New-OrtTestPe -Path (Join-Path $ocvBin 'opencv_world500.dll') -Import 'avcodec-63.dll', 'KERNEL32.dll'
    New-OrtTestPe -Path (Join-Path $ffBin 'avcodec-63.dll') -Import 'avutil-61.dll'
    New-OrtTestPe -Path (Join-Path $ffBin 'avutil-61.dll')
    New-OrtTestPe -Path (Join-Path $root 'bin\unrelated.dll')
    $site = Join-Path $Dir 'venv\Lib\site-packages'
    New-Item -ItemType Directory -Force -Path $site | Out-Null
    foreach ($info in $DistInfo) { New-Item -ItemType Directory -Force -Path (Join-Path $site $info) | Out-Null }
    $source = Join-Path $Dir 'image\cv2'
    if (-not $NoSource) {
        New-OrtTestPe -Path (Join-Path $source 'python-3.14\cv2.cp314-win_amd64.pyd') -Import 'opencv_world500.dll', 'python314.dll'
        Set-Content -LiteralPath (Join-Path $source '__init__.py') 'chain' -Encoding ASCII
        $configRoot = (Join-Path $root 'lib\opencv5').Replace('\', '/')
        Set-Content -LiteralPath (Join-Path $source 'config.py') "import os`n`nBINARIES_PATHS = [`n    os.path.join('$configRoot', 'x64/vc18/bin')`n] + BINARIES_PATHS" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $source 'config-3.14.py') "PYTHON_EXTENSIONS_PATHS = [`n    os.path.join('C:/temp/cpython/Lib/site-packages/cv2', 'python-3.14')`n] + PYTHON_EXTENSIONS_PATHS" -Encoding ASCII
    }
    return [pscustomobject]@{ Root = $root; OcvBin = $ocvBin; FfBin = $ffBin; Venv = (Join-Path $Dir 'venv'); Site = $site; Source = $source }
}

function script:Invoke-ChainOpenCvCase {
    param([Parameter(Mandatory)][pscustomobject]$Fixture)
    $state = [pscustomobject]@{ Uv = [System.Collections.Generic.List[string]]::new(); Log = [System.Collections.Generic.List[string]]::new(); NoSync = '' }
    $runner = { param($exe, $arguments) $state.Uv.Add(($arguments -join ' ')) }.GetNewClosure()
    $log = { param($m) $state.Log.Add("$m") }.GetNewClosure()
    Invoke-WithEnv @{ PATH = "$($Fixture.FfBin);$env:SystemRoot\System32"; ONNX_ROOT = $null; UV_NO_SYNC = $null } {
        Sync-UvChainOpenCv -VenvPath $Fixture.Venv -Source $Fixture.Source -RuntimeRoot $Fixture.Root -CommandRunner $runner -LogInfo $log
        $state.NoSync = "$env:UV_NO_SYNC"
    }
    return $state
}

Describe 'Sync-UvChainOpenCv' {

    It 'replaces every PyPI OpenCV flavour with the image''s cv2, loading from the dirs its closure lives in' {
        Invoke-InTestDir { param($d)
            $f = New-ChainOpenCvFixture -Dir $d -DistInfo 'opencv_python-5.0.0.dist-info', 'opencv_contrib_python_headless-5.0.0.dist-info', 'numpy-2.3.0.dist-info'
            $state = Invoke-ChainOpenCvCase -Fixture $f
            Assert-Equal 1 $state.Uv.Count 'one uninstall'
            Assert-Match '^pip uninstall --python .+\\Scripts\\python\.exe' $state.Uv[0] 'the venv interpreter'
            Assert-Match 'opencv_python\b' $state.Uv[0] 'opencv-python'
            Assert-Match 'opencv_contrib_python_headless' $state.Uv[0] 'the contrib flavour'
            Assert-False ($state.Uv[0] -match 'numpy') 'not numpy'
            Assert-Equal 'chain' ((Get-Content -LiteralPath (Join-Path $f.Site 'cv2\__init__.py')).Trim()) 'the chain loader'
            $config = Get-Content -LiteralPath (Join-Path $f.Site 'cv2\config.py') -Raw
            Assert-True $config.Contains("r'$($f.OcvBin)'") "OpenCV's own bin: $config"
            Assert-True $config.Contains("r'$($f.FfBin)'") "FFmpeg's bin, found only on PATH: $config"
            Assert-False $config.Contains('unrelated') 'not a dir the closure does not use'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Site 'cv2\bin')) 'nothing copied'
            Assert-Match "LOADER_DIR, 'python-3.14'" (Get-Content -LiteralPath (Join-Path $f.Site 'cv2\config-3.14.py') -Raw) 'the copied .pyd, not the image''s'
            Assert-Match 'Media Foundation' ($state.Log -join "`n") 'says why'
            Assert-Match ([regex]::Escape($f.FfBin)) ($state.Log -join "`n") 'says where from'
            Assert-Equal '1' $state.NoSync 'holds uv run off the lock, which would restore PyPI opencv'
        }
    }

    It 'replaces a cv2 folder the uninstall left behind instead of nesting cv2\cv2' {
        Invoke-InTestDir { param($d)
            $f = New-ChainOpenCvFixture -Dir $d -DistInfo 'opencv_python-4.13.0.dist-info'
            New-Item -ItemType Directory -Force -Path (Join-Path $f.Site 'cv2\__pycache__') | Out-Null
            $null = Invoke-ChainOpenCvCase -Fixture $f
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Site 'cv2\__init__.py')) 'cv2\__init__.py'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Site 'cv2\cv2')) 'no cv2\cv2'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Site 'cv2\__pycache__')) 'no stale bytecode'
        }
    }

    It 'does nothing in a venv without OpenCV, or outside the image' {
        foreach ($case in @(@{ Name = 'no OpenCV'; Info = 'numpy-2.3.0.dist-info'; NoSource = $false }, @{ Name = 'outside'; Info = 'opencv_python-5.0.0.dist-info'; NoSource = $true })) {
            Invoke-InTestDir { param($d)
                $f = New-ChainOpenCvFixture -Dir $d -DistInfo $case.Info -NoSource:$case.NoSource
                $state = Invoke-ChainOpenCvCase -Fixture $f
                Assert-Equal '0|0|' "$($state.Uv.Count)|$($state.Log.Count)|$($state.NoSync)" "$($case.Name): no uv call, silent, no hold"
                Assert-False (Test-Path -LiteralPath (Join-Path $f.Site 'cv2')) "$($case.Name): no cv2 added"
            }
        }
    }
}

Describe 'Copy-ChainOpenCvPackage for a bundle' {

    It 'copies the whole closure, FFmpeg included, into cv2\bin and loads from there' {
        Invoke-InTestDir { param($d)
            $f = New-ChainOpenCvFixture -Dir $d
            $copied = Invoke-WithEnv @{ PATH = "$($f.FfBin);$env:SystemRoot\System32"; ONNX_ROOT = $null } {
                @(Copy-ChainOpenCvPackage -SitePackages $f.Site -Source $f.Source -RuntimeRoot $f.Root)
            }
            Assert-Equal 'avcodec-63.dll,avutil-61.dll,opencv_world500.dll' ((@($copied | ForEach-Object { Split-Path $_ -Leaf }) | Sort-Object) -join ',') 'the closure, no unrelated DLL'
            Assert-Match "os\.path\.join\(LOADER_DIR, 'bin'\)" (Get-Content -LiteralPath (Join-Path $f.Site 'cv2\config.py') -Raw) 'relative, so the bundle relocates'
            Assert-False ((Get-Content -LiteralPath (Join-Path $f.Site 'cv2\config.py') -Raw).Contains($f.Root)) 'no image path'
        }
    }
}
