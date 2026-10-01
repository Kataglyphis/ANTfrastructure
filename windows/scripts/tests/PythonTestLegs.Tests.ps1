#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real uv and Python on windows-11-arm (python-ci-windows.yml's arm64 job does that).

$script:Legs = Join-Path (Get-RepoRoot) 'windows\scripts\python\Invoke-PythonTestLegs.ps1'

# A uv that logs each call and exits 1 when "<args> [<UV_PROJECT_ENVIRONMENT>]" matches the regex FAKE_UV_FAIL.
function script:New-FakeUv([string]$Dir) {
    $null = New-Item -ItemType Directory -Force -Path $Dir
    Set-Content -LiteralPath (Join-Path $Dir 'uv.cmd') -Encoding ascii -Value '@pwsh -NoProfile -File "%~dp0fake-uv.ps1" %*'
    Set-Content -LiteralPath (Join-Path $Dir 'fake-uv.ps1') -Encoding utf8 -Value @(
        'Add-Content -LiteralPath $env:FAKE_UV_LOG -Value "$args"'
        'if ($env:FAKE_UV_FAIL -and "$args [$env:UV_PROJECT_ENVIRONMENT]" -match $env:FAKE_UV_FAIL) { exit 1 }'
        'exit 0'
    )
}

# The uv calls so far, with the test directory written as <d>.
function script:Get-FakeUvCall([string]$Dir) {
    return @(Get-Content -LiteralPath (Join-Path $Dir 'uv-calls.log') | ForEach-Object { $_.Replace($Dir, '<d>') }) -join '|'
}

# Runs the legs script in -Dir; -FakeOnPath writes a uv into -Dir\fake and puts it first on PATH.
function script:Invoke-FakeLegs {
    param([Parameter(Mandatory)][string]$Dir, [hashtable]$Arguments = @{}, [string]$Fail = '', [switch]$FakeOnPath)
    $path = $env:PATH
    if ($FakeOnPath) { New-FakeUv (Join-Path $Dir 'fake'); $path = "$(Join-Path $Dir 'fake');$path" }
    $vars = @{ FAKE_UV_LOG = (Join-Path $Dir 'uv-calls.log'); FAKE_UV_FAIL = $Fail; PATH = $path; RUNNER_TEMP = (Join-Path $Dir 'tmp'); UV_PROJECT_ENVIRONMENT = $null }
    Invoke-WithEnv $vars {
        Push-Location $Dir
        try { & $script:Legs @Arguments 6>$null } finally { Pop-Location }
    }
}

Describe 'Invoke-PythonTestLegs.ps1' {

    It 'gives each leg its own GIL-pinned or free-threaded venv, a free-threaded leg only its extras, and pytest the paths given' {
        Invoke-InTestDir { param($d)
            Set-Content -LiteralPath (Join-Path $d 'uv.lock') -Value 'version = 1'
            Invoke-FakeLegs -Dir $d -FakeOnPath -Arguments @{ PythonVersions = '3.14 3.14t'; FreeThreadedExtras = 'test'; TestPaths = 'tests/unit,tests/web' }
            Assert-Equal (@(
                    'python find 3.14+gil', 'venv --python 3.14+gil --clear <d>\.venv-ci-3.14', 'sync --dev --all-extras --locked', 'run --no-sync python -m pytest tests/unit tests/web',
                    'venv --python 3.14t --clear <d>\.venv-ci-3.14t', 'sync --dev --extra test --locked', 'run --no-sync python -m pytest tests/unit tests/web'
                ) -join '|') (Get-FakeUvCall $d) 'the uv calls, leg by leg'
            Assert-False (Test-Path Env:UV_PROJECT_ENVIRONMENT) 'no leg environment leaks out'
        }
    }

    It 'runs every leg before failing, names each failed one and its step, and syncs unlocked without uv.lock' {
        Invoke-InTestDir { param($d)
            $legs = @{ PythonVersions = '3.13,3.14t'; Extras = 'a, b' }
            Assert-Throws { Invoke-FakeLegs -Dir $d -FakeOnPath -Arguments $legs -Fail '^sync .*ci-3\.13\]$' } -MessagePattern 'Python legs failed: 3\.13 \(sync exited 1\)$'
            $calls = Get-FakeUvCall $d
            Assert-Match 'ci-3\.13\|sync [^|]+\|venv --python 3\.14t ' $calls 'no pytest after the failed sync; the next leg starts'
            Assert-Match 'run --no-sync python -m pytest$' $calls 'the next leg still tests'
            Assert-False ($calls.Contains('--locked')) 'no uv.lock, no --locked'
            Assert-Throws { Invoke-FakeLegs -Dir $d -FakeOnPath -Arguments $legs -Fail '^run ' } -MessagePattern '3\.13 \(pytest exited 1\), 3\.14t \(pytest exited 1\)$'
            Assert-Throws { Invoke-FakeLegs -Dir $d -FakeOnPath -Arguments $legs -Fail '^python ' } -MessagePattern 'Python legs failed: 3\.13 \(venv: [^,]*\)$'
        }
    }

    It 'installs the pinned uv only when its zip matches the versions.env SHA256' {
        Invoke-InTestDir { param($d)
            New-FakeUv (Join-Path $d 'payload')
            $rel = Join-Path $d 'rel\9.9.9'
            $null = New-Item -ItemType Directory -Force -Path $rel, (Join-Path $d 'tmp')
            $zip = Join-Path $rel 'uv-aarch64-pc-windows-msvc.zip'
            Compress-Archive -Path (Join-Path $d 'payload\*') -DestinationPath $zip
            $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
            $envFile = Join-Path $d 'versions.env'
            $install = @{ InstallUv = $true; UvArch = 'arm64'; VersionsEnvPath = $envFile; UvReleaseBase = ([uri](Join-Path $d 'rel')).AbsoluteUri; PythonVersions = '3.14t' }
            Set-Content -LiteralPath $envFile -Value @('UV_VERSION=9.9.9', "UV_WINDOWS_ARM64_SHA256=$sha")
            Invoke-FakeLegs -Dir $d -Arguments $install
            Assert-Match '\|run --no-sync python -m pytest$' (Get-FakeUvCall $d) 'the downloaded uv ran the leg'
            Set-Content -LiteralPath $envFile -Value @('UV_VERSION=9.9.9', "UV_WINDOWS_ARM64_SHA256=$('0' * 64)")
            Assert-Throws { Invoke-FakeLegs -Dir $d -Arguments $install } -MessagePattern 'SHA256 mismatch'
            Set-Content -LiteralPath $envFile -Value 'UV_VERSION=9.9.9'
            Assert-Throws { Invoke-FakeLegs -Dir $d -Arguments $install } -MessagePattern 'UV_WINDOWS_ARM64_SHA256 is not set'
        }
    }
}
