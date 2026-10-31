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

# The requirements pin wheel hashes in lowercase hex.
function script:Get-TestSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Every cross install here is the app's arm64 leg from a checkout at $Dir; $Leg carries what each case varies.
function script:Install-TestArm64App([string]$Dir, [hashtable]$Leg) {
    Install-PythonAppCrossPackage -RepoRoot $Dir -WorkDir $Dir -Extras 'app' -Platform 'aarch64-pc-windows-msvc' @Leg
}

# The value after a flag in a fake's argv, or nothing when the flag is absent.
function script:Get-FakeOption([object[]]$Argv, [string]$Flag) {
    $at = [array]::IndexOf($Argv, $Flag)
    if ($at -ge 0) { return $Argv[$at + 1] }
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
                Install-TestArm64App $d @{ HostPython = 'C:\host\python.exe'; SitePackages = $site; AppWheel = 'app.whl'; OrtWheel = 'ort.whl'
                    PythonVersion = '3.14'; Exclude = 'onnxruntime', 'opencv-python' }
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

    foreach ($hashCase in @(
        @{
            Name = 'adds the built wheel''s hash to its own requirement only, keeping the line continuations'
            Package = 'pyyaml'; Sha = 'fff'
            Lines = @('pyyaml==6.0.3 \', '    --hash=sha256:111 \', '    --hash=sha256:222', '    # via app', 'rich==14.0 \', '    --hash=sha256:333')
            Expected = 'pyyaml==6.0.3 \|    --hash=sha256:111 \|    --hash=sha256:222 \|    --hash=sha256:fff|    # via app|rich==14.0 \|    --hash=sha256:333'.Split('|')
            Unhashed = ,@('pyyaml==6.0.3')
        },
        @{
            Name = 'retains CRLF bytes, repeated groups and a final continued hash'
            Package = 'pkg.name'; Sha = 'built'
            Lines = @('other==1 \', '    --hash=sha256:other', 'pkg.name==2 \', '    --hash=sha256:first \\',
                '    # via app', 'pkg.name==2 \', '    --hash=sha256:last \')
            Expected = @('other==1 \', '    --hash=sha256:other', 'pkg.name==2 \', '    --hash=sha256:first \',
                '    --hash=sha256:built', '    # via app', 'pkg.name==2 \', '    --hash=sha256:last \', '    --hash=sha256:built')
            Unhashed = @(@('pkg.name==2', '    # via app'), @('pkgXname==2 \', '    --hash=sha256:other'))
        },
        @{
            Name = 'keeps the blank lines a requirements export carries'
            Package = 'pkg'; Sha = 'built'
            Lines = @('# header', '', 'pkg==1 \', '    --hash=sha256:a', '')
            Expected = @('# header', '', 'pkg==1 \', '    --hash=sha256:a \', '    --hash=sha256:built', '')
            Unhashed = ,@('', 'pkg==1')
        }
    )) {
        It $hashCase.Name {
            $out = & (Get-Module WindowsPythonApp.Common) {
                Add-RequirementHash -Lines $args[0] -Name $args[1] -Sha256 $args[2]
            } $hashCase.Lines $hashCase.Package $hashCase.Sha
            Assert-Equal ($hashCase.Expected -join '|') ($out -join '|') 'one more hash, continued'
            Assert-Equal ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($hashCase.Expected -join "`r`n"))) `
                ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($out -join "`r`n"))) 'requirement bytes and continuation placement'
            foreach ($unhashed in $hashCase.Unhashed) {
                Assert-Throws {
                    & (Get-Module WindowsPythonApp.Common) { Add-RequirementHash -Lines $args[0] -Name $args[1] -Sha256 $args[2] } `
                        $unhashed $hashCase.Package $hashCase.Sha
                } -MessagePattern "no hashed requirement for $([regex]::Escape($hashCase.Package))"
            }
        }
    }

    It 'detects a lost final requirement group' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsPythonApp.Common.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Get-RequirementLineGroup, Add-RequirementHash `
            -Find 'if ($group.Count -gt 0) { Write-Output -NoEnumerate -InputObject $group.ToArray() }' -Replace '' -Body {
                $lines = @('pkg==1 \', '    --hash=sha256:last')
                $original = & (Get-Module WindowsPythonApp.Common) { Add-RequirementHash -Lines $args[0] -Name pkg -Sha256 built } $lines
                Assert-Equal 'pkg==1 \|    --hash=sha256:last \|    --hash=sha256:built' ($original -join '|')
                Assert-Throws { Add-MutRequirementHash -Lines $lines -Name pkg -Sha256 built } -MessagePattern 'no hashed requirement for pkg'
            }
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
            $outFile = Get-FakeOption $args '--output-file'
            if ($outFile) { Copy-Item -LiteralPath (Join-Path (Split-Path $outFile) 'req.txt') -Destination $outFile; return }
            if ($args[0] -ne 'build') { return }
            $global:FakeBuildEnv = $env:PYYAML_FORCE_LIBYAML
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::Open((Join-Path (Get-FakeOption $args '--out-dir') 'pyyaml-6.0.3-py3-none-any.whl'), 'Create')
            try { foreach ($e in $global:FakeEntries) { $null = $zip.CreateEntry($e) } } finally { $zip.Dispose() }
            $global:LASTEXITCODE = 0
        }
        try {
            if ($Whole) {
                Install-TestArm64App $Dir @{ HostPython = 'py'; SitePackages = (Join-Path $Dir 'site'); AppWheel = 'a.whl'; OrtWheel = 'o.whl'; PythonVersion = '3.15' }
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
            $wheelHash = Get-TestSha256 (Join-Path $d 'pure\pyyaml-6.0.3-py3-none-any.whl')
            Assert-Match "--hash=sha256:$wheelHash" ((Get-Content -LiteralPath (Join-Path $d 'req.txt')) -join "`n") 'the requirement accepts the wheel'
        }
    }

    It 'makes the dependency install take the pure wheel: --find-links, and --only-binary so uv does not build the sdist instead' {
        Invoke-InTestDir { param($d)
            $run = Invoke-PureBuild -Dir $d -Whole
            $deps = @($run.Calls | Where-Object { $_ -like 'pip install *--requirement *' })
            Assert-Equal 1 $deps.Count 'one install of the locked dependencies'
            Assert-Match "--find-links $([regex]::Escape((Join-Path $d 'pure-wheels'))) --only-binary pyyaml --no-deps --requirement " $deps[0] 'the built wheel, and no fallback to building the sdist'
        }
    }

    It 'refuses a wheel that carries a binary, which would be the build host''s arch' {
        Invoke-InTestDir { param($d)
            Assert-Throws { $null = Invoke-PureBuild -Dir $d -Entries 'yaml/__init__.py', 'yaml/_yaml.cp315-win_amd64.pyd' } -MessagePattern 'carries yaml/_yaml\.cp315-win_amd64\.pyd'
        }
    }
}

Describe 'Install-PythonCrossSite (CON113)' {

    It 'exports every extra on request, then installs the wheel and each extra wheel from its file alone' {
        Invoke-InTestDir { param($d)
            $calls = Invoke-WithFakeUv {
                Install-PythonCrossSite -HostPython 'C:\host\python3.15t.exe' -SitePackages (Join-Path $d 'site') -RepoRoot $d -Wheel 'p.whl' -AllExtras `
                    -WorkDir $d -Platform 'aarch64-pc-windows-msvc' -PythonVersion '3.15' -ExtraWheel 'x.whl'
            }
            Assert-Match '^export --locked --no-dev --no-emit-project --format requirements\.txt --all-extras --output-file ' $calls[0] 'every extra'
            Assert-Match ' --no-deps --requirement .*requirements\.cross\.txt$' $calls[1] 'the lock''s closure as exported, no fresh resolve that drops [tool.uv] overrides (mutation)'
            Assert-Match '--no-deps p\.whl$' $calls[2] 'the project without its dependencies'
            Assert-Match '--no-index --no-deps x\.whl$' $calls[3] 'an extra wheel from its file alone'
        }
    }

    It 'takes store wheels through --find-links on the stores, and --only-binary so uv does not build the sdist instead' {
        $links = & (Get-Module WindowsPythonApp.Common) { Get-CrossFindLinkArgument -Pure 'P' -Built 'pyyaml' -Store 'S1', 'S2' -Stored 'psutil' }
        Assert-Equal '--find-links P --find-links S1 --find-links S2 --only-binary pyyaml --only-binary psutil' ($links -join ' ') 'both sources, both pinned to their wheel'
        $none = & (Get-Module WindowsPythonApp.Common) { Get-CrossFindLinkArgument -Pure 'P' -Store 'S1' }
        Assert-Equal '' ($none -join ' ') 'no store wheel taken, no store in view'
    }

    It 'adds a store wheel''s own hash only for the version and tag the lock pins (mutation)' {
        Invoke-InTestDir { param($d)
            $store = Join-Path $d 'deps'
            $null = New-Item -ItemType Directory -Path $store
            foreach ($n in 'psutil-7.2.2-cp315-cp315t-win_arm64', 'psutil-7.2.1-cp315-cp315t-win_arm64', 'rich-14.0-cp315-cp315-win_arm64') {
                Set-Content -LiteralPath (Join-Path $store "$n.whl") -Value $n
            }
            Set-Content -LiteralPath (Join-Path $d 'req.txt') -Value @("psutil==7.2.2 ; sys_platform == 'win32' \", '    --hash=sha256:111', 'rich==14.0 \', '    --hash=sha256:222')
            $added = & (Get-Module WindowsPythonApp.Common) { Add-StoreWheelHash -Requirements $args[0] -Store $args[1] -Tag 'cp315t-win_arm64' } (Join-Path $d 'req.txt') @($store)
            Assert-Equal 'psutil' ($added -join ',') 'the pinned version, of the leg''s tag, alone'
            $want = Get-TestSha256 (Join-Path $store 'psutil-7.2.2-cp315-cp315t-win_arm64.whl')
            $req = (Get-Content -LiteralPath (Join-Path $d 'req.txt')) -join "`n"
            Assert-Match "--hash=sha256:111 \\\n    --hash=sha256:$want\nrich" $req 'its hash joins psutil''s'
            Assert-False ($req -match 'sha256:222 \\') 'rich untouched'
        }
    }
}
