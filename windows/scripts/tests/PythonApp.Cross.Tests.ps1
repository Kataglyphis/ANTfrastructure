#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real uv resolve and PC\layout --arch arm64 (New-PythonAppBundle.ps1 -TargetArch arm64 runs both inside :winarm64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

# Runs -Body with a global uv that records each call's arguments and exits -Exit; returns the calls.
function script:Invoke-WithFakeUv {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'the fake uv runs in a child scope the tested code resolves; only the global scope survives it')]
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$Exit = 0)
    $global:FakeUvCalls = [Collections.Generic.List[string]]::new()
    $global:FakeUvExit = $Exit
    Set-Item function:global:uv { $global:FakeUvCalls.Add($args -join ' '); $global:LASTEXITCODE = $global:FakeUvExit }
    try {
        & $Body
        return @($global:FakeUvCalls)
    } finally {
        # Not function:global:uv: Remove-Item ignores that scope prefix, and the fake outlived the suite to answer later suites' uv.
        Remove-Item -Path Function:\uv
        Remove-Variable -Name FakeUvCalls, FakeUvExit -Scope Global
    }
}

Describe 'Install-PythonAppPackage' {

    It 'leaves the PyPI ORT out of the lock export, then installs the lock, the app and the chain ORT' {
        Invoke-InTestDir { param($d)
            $calls = Invoke-WithFakeUv {
                Install-PythonAppPackage -Python 'C:\rt\python.exe' -RepoRoot $d -AppWheel 'app.whl' -Extras 'app' -OrtWheel 'ort.whl' -WorkDir $d
            }
            Assert-Match '^export .*--extra app --no-emit-package onnxruntime --output-file ' $calls[0] 'a runtime newer than PyPI ORT''s wheels (cp315) cannot install it'
            Assert-Match '--requirement .*requirements\.lock\.txt$' $calls[1] 'the lock first'
            Assert-Match '--no-index --no-deps ort\.whl$' $calls[-1] 'the chain ORT last'
        }
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

Describe 'Get-LockSdist and Add-RequirementHash' {

    It 'reads one package''s sdist URL and sha256 from uv.lock, and names a package it lacks' {
        Invoke-InTestDir { param($d)
            $lock = Join-Path $d 'uv.lock'
            Set-Content -LiteralPath $lock -Value @(
                '[[package]]', 'name = "pyyaml"', 'version = "6.0.3"', 'source = { registry = "https://pypi.org/simple" }',
                "sdist = { url = ""https://files.example/pyyaml-6.0.3.tar.gz"", hash = ""sha256:$('a' * 64)"", size = 1 }",
                '', '[[package]]', 'name = "wheel-only"', 'version = "1.0"', 'wheels = []')
            $sdist = & (Get-Module WindowsPythonApp.Common) { Get-LockSdist -Lock $args[0] -Name 'pyyaml' -Version '6.0.3' } $lock
            Assert-Equal 'https://files.example/pyyaml-6.0.3.tar.gz' $sdist.Url 'the URL'
            Assert-Equal ('a' * 64) $sdist.Sha256 'the hash'
            Assert-Throws { & (Get-Module WindowsPythonApp.Common) { Get-LockSdist -Lock $args[0] -Name 'wheel-only' -Version '1.0' } $lock } -MessagePattern 'no sdist for wheel-only'
            Assert-Throws { & (Get-Module WindowsPythonApp.Common) { Get-LockSdist -Lock $args[0] -Name 'absent' -Version '1' } $lock } -MessagePattern 'no package absent 1'
        }
    }

    It 'adds the built wheel''s hash to its own requirement only, keeping the line continuations' {
        $lines = @('pyyaml==6.0.3 \', '    --hash=sha256:111 \', '    --hash=sha256:222', '    # via app', 'rich==14.0 \', '    --hash=sha256:333')
        $out = & (Get-Module WindowsPythonApp.Common) { Add-RequirementHash -Lines $args[0] -Name 'pyyaml' -Sha256 'fff' } $lines
        Assert-Equal "pyyaml==6.0.3 \|    --hash=sha256:111 \|    --hash=sha256:222 \|    --hash=sha256:fff|    # via app|rich==14.0 \|    --hash=sha256:333" ($out -join '|') 'one more hash, continued'
        Assert-Throws { & (Get-Module WindowsPythonApp.Common) { Add-RequirementHash -Lines @('pyyaml==6.0.3') -Name 'pyyaml' -Sha256 'f' } } -MessagePattern 'no hashed requirement for pyyaml'
    }
}

Describe 'Add-PurePythonWheel' {

    # Builds pyyaml from a file:// sdist the lock pins, with a fake uv build writing a wheel of -Entries; returns the build's env and count.
    function script:Invoke-PureBuild {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'the fake uv runs in the module''s scope; only the global scope reaches it')]
        param([Parameter(Mandatory)][string]$Dir, [string[]]$Entries = @('yaml/__init__.py'), [switch]$Whole)
        $sdist = Join-Path $Dir 'pyyaml-6.0.3.tar.gz'
        Set-Content -LiteralPath $sdist -Value 'the sdist'
        $sha = (Get-FileHash -LiteralPath $sdist -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $Dir 'uv.lock') -Value @('[[package]]', 'name = "pyyaml"', 'version = "6.0.3"',
            "sdist = { url = ""$([uri]::new($sdist).AbsoluteUri)"", hash = ""sha256:$sha"", size = 9 }")
        Set-Content -LiteralPath (Join-Path $Dir 'req.txt') -Value @('pyyaml==6.0.3 \', '    --hash=sha256:111', 'rich==14.0')
        $global:FakeEntries = $Entries
        $global:FakeBuildEnv = $null
        $global:FakeCalls = [Collections.Generic.List[string]]::new()
        Set-Item function:global:uv {
            $global:FakeCalls.Add($args -join ' ')
            $global:LASTEXITCODE = 0
            $outFile = [array]::IndexOf($args, '--output-file')
            if ($outFile -ge 0) { Copy-Item -LiteralPath (Join-Path (Split-Path $args[$outFile + 1]) 'req.txt') -Destination $args[$outFile + 1]; return }
            if ($args[0] -ne 'build') { return }
            $global:FakeBuildEnv = $env:PYYAML_FORCE_LIBYAML
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::Open((Join-Path $args[[array]::IndexOf($args, '--out-dir') + 1] 'pyyaml-6.0.3-py3-none-any.whl'), 'Create')
            try { foreach ($e in $global:FakeEntries) { $null = $zip.CreateEntry($e) } } finally { $zip.Dispose() }
            $global:LASTEXITCODE = 0
        }
        try {
            if ($Whole) {
                Install-PythonAppCrossPackage -HostPython 'py' -SitePackages (Join-Path $Dir 'site') -RepoRoot $Dir -AppWheel 'a.whl' -Extras 'app' `
                    -OrtWheel 'o.whl' -WorkDir $Dir -Platform 'aarch64-pc-windows-msvc' -PythonVersion '3.15'
                return [pscustomobject]@{ Calls = @($global:FakeCalls) }
            }
            $built = & (Get-Module WindowsPythonApp.Common) {
                Add-PurePythonWheel -Requirements $args[0] -Lock $args[1] -HostPython 'py' -OutDir $args[2] -PureBuild @{ pyyaml = @{ PYYAML_FORCE_LIBYAML = '0' } }
            } (Join-Path $Dir 'req.txt') (Join-Path $Dir 'uv.lock') (Join-Path $Dir 'pure')
            return [pscustomobject]@{ Built = $built; Env = $global:FakeBuildEnv }
        } finally {
            Remove-Item -Path Function:\uv
            Remove-Variable -Name FakeEntries, FakeBuildEnv, FakeCalls -Scope Global
        }
    }

    It 'builds pyyaml from the lock''s hash-checked sdist with its env, and pins the wheel by its own hash' {
        Invoke-InTestDir { param($d)
            $env:PYYAML_FORCE_LIBYAML = $null
            $run = Invoke-PureBuild -Dir $d
            Assert-Equal 'pyyaml' ($run.Built -join ',') 'one pure wheel, by name'
            Assert-Equal '0' $run.Env 'the build saw PYYAML_FORCE_LIBYAML=0'
            Assert-True ($null -eq $env:PYYAML_FORCE_LIBYAML) 'and the variable is gone again'
            $wheelHash = (Get-FileHash -LiteralPath (Join-Path $d 'pure\pyyaml-6.0.3-py3-none-any.whl') -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-Match "--hash=sha256:$wheelHash" ((Get-Content -LiteralPath (Join-Path $d 'req.txt')) -join "`n") 'the requirement accepts the wheel'
        }
    }

    It 'makes the dependency install take the pure wheel: --find-links, and --only-binary so uv does not build the sdist instead' {
        Invoke-InTestDir { param($d)
            $run = Invoke-PureBuild -Dir $d -Whole
            $deps = @($run.Calls | Where-Object { $_ -like 'pip install *--requirement *' })
            Assert-Equal 1 $deps.Count 'one install of the locked dependencies'
            Assert-Match "--find-links $([regex]::Escape((Join-Path $d 'pure-wheels'))) --only-binary pyyaml --requirement " $deps[0] 'the built wheel, and no fallback to building the sdist'
        }
    }

    It 'refuses a wheel that carries a binary, which would be the build host''s arch' {
        Invoke-InTestDir { param($d)
            Assert-Throws { $null = Invoke-PureBuild -Dir $d -Entries 'yaml/__init__.py', 'yaml/_yaml.cp315-win_amd64.pyd' } -MessagePattern 'carries yaml/_yaml\.cp315-win_amd64\.pyd'
        }
    }
}
