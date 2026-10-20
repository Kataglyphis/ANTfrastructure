#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a passing run, which needs a free-threaded interpreter (proved in :winamd64 and on windows-11-arm, CON122).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Suite.psm1') -Force -DisableNameChecking

$script:WheelTests = Join-Path (Get-RepoRoot) 'windows\scripts\python\Invoke-FreeThreadedWheelTests.ps1'
$script:Table = @('[tool.antfrastructure.free-threaded-wheel-tests]', 'extra = "test"', 'copy = ["tests/unit/test_threads.py", "pytest.ini"]',
    'env = { FIXTURE_COMPILED = "1" }', 'isolated = true', 'pytest-args = ["-W", "error", "-k", "not slow", "tests/unit/test_threads.py"]')

# The host's interpreter reads the table for real: the JSON between the helper and this module is the contract under test.
function script:Get-SuiteTestPython {
    $found = @(Get-Command -Name python -CommandType Application -ErrorAction Ignore)
    if ($found.Count -eq 0) { throw 'no python on PATH, and the shared helper must read the table for real here' }
    return $found[0].Source
}

# A repo with the table (or -Toml instead), its two test files and a wheel per -Wheels in dist\.
function script:New-SuiteRepo([string]$Dir, [string[]]$Toml = $script:Table, [string[]]$Wheels = @(), [switch]$Undeclared) {
    $repo = Join-Path $Dir 'repo'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tests\unit'), (Join-Path $repo 'dist'), (Join-Path $repo 'demo')
    $classifier = if ($Undeclared) { '' } else { '"Programming Language :: Python :: Free Threading :: 2 - Beta"' }
    Set-Content -LiteralPath (Join-Path $repo 'pyproject.toml') -Value (@('[project]', 'name = "demo"', "classifiers = [$classifier]") + $Toml)
    foreach ($f in 'tests\unit\test_threads.py', 'pytest.ini', 'demo\__init__.py', 'uv.lock') { Set-Content -LiteralPath (Join-Path $repo $f) -Value '' }
    foreach ($w in $Wheels) { Set-Content -LiteralPath (Join-Path $repo "dist\$w") -Value '' }
    return $repo
}

Describe 'WindowsPythonWheel.Suite: the table, read through the shared helper (CON122)' {

    It 'returns the table with its defaults, $null without one, and throws the helper''s reason for an invalid one' {
        Invoke-InTestDir { param($d)
            $py = Get-SuiteTestPython
            $repo = New-SuiteRepo $d
            $s = Get-FreeThreadedWheelSuite -Python $py -PyprojectPath (Join-Path $repo 'pyproject.toml')
            Assert-Equal 'test|tests/unit/test_threads.py,pytest.ini|FIXTURE_COMPILED=1|True|-W,error,-k,not slow,tests/unit/test_threads.py' (
                "$($s.Extra)|$($s.Copy -join ',')|$(@($s.Env.Keys | ForEach-Object { "$_=$($s.Env[$_])" }) -join ',')|$($s.Isolated)|$($s.PytestArgs -join ',')")
            $repo = New-SuiteRepo $d -Toml @('[tool.antfrastructure.free-threaded-wheel-tests]', 'copy = ["tests"]')
            $s = Get-FreeThreadedWheelSuite -Python $py -PyprojectPath (Join-Path $repo 'pyproject.toml')
            Assert-Equal '|tests|0|False|0' "$($s.Extra)|$($s.Copy -join ',')|$($s.Env.Count)|$($s.Isolated)|$($s.PytestArgs.Count)" 'the defaults'
            $repo = New-SuiteRepo $d -Toml @()
            Assert-Null (Get-FreeThreadedWheelSuite -Python $py -PyprojectPath (Join-Path $repo 'pyproject.toml')) 'no table'
            $repo = New-SuiteRepo $d -Toml @('[tool.antfrastructure.free-threaded-wheel-tests]', 'copy = ["tests"]', 'isolate = true')
            Assert-Throws { Get-FreeThreadedWheelSuite -Python $py -PyprojectPath (Join-Path $repo 'pyproject.toml') } -MessagePattern "unknown key 'isolate'"
        }
    }

    It 'copies each path to the same relative path, and refuses a missing one' {
        Invoke-InTestDir { param($d)
            $repo = New-SuiteRepo $d
            $suite = [pscustomobject]@{ Copy = [string[]]@('tests', 'pytest.ini') }
            Copy-FreeThreadedWheelTestFile -Suite $suite -RepoRoot $repo -Destination (Join-Path $d 'run')
            $staged = @(Get-ChildItem -LiteralPath (Join-Path $d 'run') -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath((Join-Path $d 'run'), $_.FullName) })
            Assert-Equal 'pytest.ini|tests\unit\test_threads.py' (($staged | Sort-Object) -join '|') 'no package source beside the tests'
            $suite = [pscustomobject]@{ Copy = [string[]]@('tests/absent.py') }
            Assert-Throws { Copy-FreeThreadedWheelTestFile -Suite $suite -RepoRoot $repo -Destination (Join-Path $d 'run2') } -MessagePattern "copy 'tests/absent.py': no such file"
        }
    }

    It 'stages a device cmd: the run directory, the env, -I, the sites, each argument quoted, then the verdict line' {
        Invoke-InTestDir { param($d)
            $repo = New-SuiteRepo $d
            $suite = Get-FreeThreadedWheelSuite -Python (Get-SuiteTestPython) -PyprojectPath (Join-Path $repo 'pyproject.toml')
            $stage = Join-Path $d 'stage'
            $entry = New-FreeThreadedWheelTestStage -Suite $suite -RepoRoot $repo -StageDir $stage -Name 'wheel-tests-3.15t' `
                -Python 'python-3.15t\python3.15t.exe' -Site 'site-ft' -Wheel 'demo-1.0-cp315-cp315t-win_arm64.whl'
            Assert-Equal 'wheel-tests-3.15t.cmd|pytest' "$($entry.exe)|$($entry.kind)" 'counted from pytest''s summary'
            $want = @('@echo off', 'cd /d "%~dp0wheel-tests-3.15t"', 'set "PYTHONPATH=%~dp0site-ft"', 'set "FIXTURE_COMPILED=1"',
                ('"%~dp0python-3.15t\python3.15t.exe" -I "%~dp0free-threaded-wheel-tests.py" run --site "%~dp0site-ft" -- ' +
                    '"-W" "error" "-k" "not slow" "tests/unit/test_threads.py"'),
                'if errorlevel 1 exit /b %errorlevel%', 'echo free-threaded wheel tests passed: demo-1.0-cp315-cp315t-win_arm64.whl')
            Assert-Equal ($want -join '|') ((Get-Content -LiteralPath (Join-Path $stage 'wheel-tests-3.15t.cmd')) -join '|')
            Assert-True (Test-Path -LiteralPath (Join-Path $stage 'wheel-tests-3.15t\tests\unit\test_threads.py')) 'the tests, in the run directory'
            Assert-Equal (Get-FileHash (Get-FreeThreadedWheelSuiteHelper)).Hash (Get-FileHash (Join-Path $stage 'free-threaded-wheel-tests.py')).Hash 'the shared runner beside it'
            $suite.PytestArgs = [string[]]@('-k', '100%')
            Assert-Throws { New-FreeThreadedWheelTestStage -Suite $suite -RepoRoot $repo -StageDir $stage -Name 'w' -Python 'p.exe' -Wheel 'w.whl' } -MessagePattern 'cannot carry'
        }
    }
}

# A uv that logs each call (`python find` prints the fake python, `venv` makes a real venv of the host's GIL python, `export` writes its -o).
function script:New-WheelTestsFake([string]$Dir) {
    $fake = Join-Path $Dir 'fake'
    $null = New-Item -ItemType Directory -Force -Path $fake
    New-FakeToolShim -Dir $fake -Tool uv, python
    Set-Content -LiteralPath (Join-Path $fake 'fake-uv.ps1') -Encoding utf8 -Value @(
        'if ("$($args[0]) $($args[1])" -eq "python find") { Write-Output (Join-Path $PSScriptRoot "python.cmd"); exit 0 }'
        'if ($args[0] -eq "venv") { & $env:REAL_PYTHON -m venv --without-pip $args[-1]; exit $LASTEXITCODE }'
        'if ($args[0] -eq "export") { Set-Content -LiteralPath $args[[array]::IndexOf($args, "-o") + 1] -Value "" }'
    )
    # declares answers from FAKE_DECLARES; the table is the real helper's, on the host's python.
    Set-Content -LiteralPath (Join-Path $fake 'fake-python.ps1') -Encoding utf8 -Value @(
        'if ($args[2] -eq "declares") { if ($env:FAKE_DECLARES) { "Free Threading"; exit 0 }; "no classifier"; exit 1 }'
        'if ($args[2] -eq "table") { & $env:REAL_PYTHON @args; exit $LASTEXITCODE }'
    )
    return $fake
}

# The driver in a child pwsh; returns its exit code, its plain output and the calls it made.
function script:Invoke-WheelTestsFixture {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Repo, [string[]]$Arguments = @(), [switch]$Declares, [string]$Mode = '')
    $fake = New-WheelTestsFake $Dir
    $log = Join-Path $Dir 'calls.log'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $vars = @{ FAKE_LOG = $log; FAKE_DECLARES = $(if ($Declares) { '1' } else { $null }); REAL_PYTHON = (Get-SuiteTestPython); PATH = "$fake;$env:PATH"
        PYTHON_VERSION = '9.87.6'; PYTHON_FREE_THREADED_WHEEL = $(if ($Mode) { $Mode } else { $null }); WINDOWS_TARGET_ARCH = $null; FIXTURE_COMPILED = $null
    }
    $output = Invoke-WithEnv $vars { & pwsh -NoProfile -File $script:WheelTests -RepoRoot $Repo @Arguments 2>&1 | ForEach-Object { "$_" } }
    $code = $LASTEXITCODE
    $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
    $text = ($output -join "`n") -replace '\x1b\[[0-9;]*m', '' -replace '\s*\n\s*(\|\s*)*', ' '
    return [pscustomobject]@{ Code = $code; Calls = $calls; Text = $text }
}

Describe 'Invoke-FreeThreadedWheelTests.ps1: the Windows twin of test-free-threaded-wheel.sh (CON122)' {

    It 'skips, saying why, exactly where Invoke-CiPackaging.ps1 builds no native cp3XYt wheel, and without a table' {
        Invoke-InTestDir { param($d)
            $repo = New-SuiteRepo $d
            foreach ($case in @(@{ a = @('-TargetArch', 'arm64'); want = 'free-threaded wheel tests skipped: the arm64 cross build''s wheel is tested on the device' },
                    @{ m = 'off'; want = 'free-threaded wheel tests skipped: PYTHON_FREE_THREADED_WHEEL=off' },
                    @{ want = 'free-threaded wheel tests skipped: the project does not declare support' })) {
                $r = Invoke-WheelTestsFixture -Dir $d -Repo $repo -Arguments @($case['a'] | Where-Object { $_ }) -Mode "$($case['m'])"
                Assert-Equal 0 $r.Code $r.Text
                Assert-Match ([regex]::Escape($case.want)) $r.Text
            }
            $r = Invoke-WheelTestsFixture -Dir $d -Repo (New-SuiteRepo $d -Toml @()) -Declares
            Assert-Equal 0 $r.Code $r.Text
            Assert-Match 'free-threaded wheel tests skipped: pyproject\.toml has no \[tool\.antfrastructure\.free-threaded-wheel-tests\]' $r.Text
            Assert-Equal 0 @($r.Calls | Where-Object { $_ -like 'uv venv*' }).Count 'a skip makes no venv'
        }
    }

    It 'fails a declared project without its one cp3XYt win_amd64 wheel, listing dist\' {
        Invoke-InTestDir { param($d)
            $r = Invoke-WheelTestsFixture -Dir $d -Repo (New-SuiteRepo $d -Wheels 'demo-1.0-cp987-cp987-win_amd64.whl') -Declares
            Assert-Equal 1 $r.Code $r.Text
            Assert-Match 'expected one cp987t win_amd64 wheel in dist\\, found 0 among: demo-1\.0-cp987-cp987-win_amd64\.whl' $r.Text
        }
    }

    It 'installs the lock''s set and the wheel into a fresh venv, runs the table''s tests outside the checkout, and fails with the runner' {
        Invoke-InTestDir { param($d)
            $wheel = 'demo-1.0-cp987-cp987t-win_amd64.whl'
            $repo = New-SuiteRepo $d -Wheels $wheel, 'demo-1.0-cp987-cp987-win_amd64.whl'
            $start = Get-Date
            $r = Invoke-WheelTestsFixture -Dir $d -Repo $repo -Declares
            $calls = $r.Calls -join '|'
            Assert-Match 'uv python find 9\.87t' $calls 'the image''s interpreter, never downloaded'
            Assert-Match 'uv export --locked --no-emit-project --extra test --format requirements\.txt -o \S+\\ft-wheel-tests-[^\\]+\\requirements\.txt' $calls 'the table''s extra'
            Assert-Match "uv pip install --python \S+\\venv\\Scripts\\python\.exe --no-deps $([regex]::Escape("$repo\dist\$wheel"))" $calls 'the shipped wheel alone'
            Assert-Match ('CMD: \S+\\venv\\Scripts\\python\.exe -I \S+free-threaded-wheel-tests\.py run -- -W error -k not slow tests/unit/test_threads\.py') $r.Text 'isolated, through the runner'
            # The host's python is a GIL build, so the runner refuses it: the failure path, end to end.
            Assert-Equal 1 $r.Code $r.Text
            Assert-Match 'is not a free-threaded interpreter' $r.Text
            Assert-Match ([regex]::Escape("the tests failed against $wheel, or left the GIL enabled (exit 2)")) $r.Text
            Assert-Equal 0 @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'ft-wheel-tests-*' |
                    Where-Object { $_.CreationTime -ge $start }).Count 'the work directory is removed'
        }
    }
}
