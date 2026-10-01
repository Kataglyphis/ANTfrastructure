#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real uv resolve and PC\layout --arch arm64 (New-PythonAppBundle.ps1 -TargetArch arm64 runs both inside :winarm64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

# Runs -Body with a global uv that records each call's arguments and exits -Exit; returns the calls.
function script:Invoke-WithFakeUv {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$Exit = 0)
    $global:FakeUvCalls = [Collections.Generic.List[string]]::new()
    $global:FakeUvExit = $Exit
    Set-Item function:global:uv { $global:FakeUvCalls.Add($args -join ' '); $global:LASTEXITCODE = $global:FakeUvExit }
    try {
        & $Body
        return @($global:FakeUvCalls)
    } finally {
        Remove-Item function:global:uv
        Remove-Variable -Name FakeUvCalls, FakeUvExit -Scope Global
    }
}

Describe 'Install-PythonAppCrossPackage' {

    It 'installs the lock, the app and the chain ORT for the target, and drops the host-arch trampolines' {
        Invoke-InTestDir { param($d)
            $site = Join-Path $d 'site'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $site 'bin')
            $calls = Invoke-WithFakeUv {
                Install-PythonAppCrossPackage -HostPython 'C:\host\python.exe' -SitePackages $site -RepoRoot $d -AppWheel 'app.whl' -Extras 'app' `
                    -OrtWheel 'ort.whl' -WorkDir $d -Platform 'aarch64-pc-windows-msvc' -PythonVersion '3.14' -Exclude 'onnxruntime', 'opencv-python'
            }
            Assert-Equal 4 $calls.Count 'the export, then three installs'
            Assert-Match '^export .*--extra app --no-emit-package onnxruntime --no-emit-package opencv-python --output-file ' $calls[0] 'the replaced packages stay out of the export'
            foreach ($install in $calls[1..3]) {
                Assert-Match "--target $([regex]::Escape($site)) --python-platform aarch64-pc-windows-msvc --python-version 3\.14 " $install 'a target install'
            }
            Assert-Match '--requirement .*requirements\.cross\.txt$' $calls[1] 'the lock first'
            Assert-Match '--no-deps app\.whl$' $calls[2] 'the app without its dependencies'
            Assert-Match '--no-index --no-deps ort\.whl$' $calls[3] 'the chain ORT from the file alone'
            Assert-False (Test-Path -LiteralPath (Join-Path $site 'bin')) 'uv''s host-arch script trampolines are gone'
        }
    }

    It 'stops at the first failing uv call' {
        Invoke-InTestDir { param($d)
            Assert-Throws {
                $null = Invoke-WithFakeUv -Exit 2 {
                    Install-PythonAppCrossPackage -HostPython 'py' -SitePackages $d -RepoRoot $d -AppWheel 'a.whl' -Extras 'app' -OrtWheel 'o.whl' `
                        -WorkDir $d -Platform 'aarch64-pc-windows-msvc' -PythonVersion '3.14'
                }
            } -MessagePattern '^uv export failed \(exit 2\)'
        }
    }
}

Describe 'New-PythonAppCrossRuntime' {

    It 'refuses an image without the target CPython before it lays anything out' {
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\PC\layout')
            Assert-Throws {
                New-PythonAppCrossRuntime -TargetPython (Join-Path $d 'none') -SourceDir (Join-Path $d 'src') -HostPython 'py' -Arch 'arm64' `
                    -WorkDir $d -Destination (Join-Path $d 'out')
            } -MessagePattern 'no target CPython for arm64'
            Assert-False (Test-Path -LiteralPath (Join-Path $d 'out')) 'nothing laid out'
        }
    }
}
