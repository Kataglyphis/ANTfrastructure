#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real uv, pytest and the two child drivers in the image (python-ci-windows.yml's build job does that).

Import-Module (Join-Path $PSScriptRoot 'WindowsPythonCi.DriverFixture.psm1') -Force -DisableNameChecking

$script:CiBuild = Join-Path (Get-RepoRoot) 'windows\scripts\python\Invoke-PythonCiBuild.ps1'

# A demo repo, a uv and a python that log each call ("python find" prints the fake python), and stubs of the three child drivers.
function script:New-CiBuildFixture([string]$Dir, [string]$Settings = '') {
    $fake = New-PythonCiFixtureTools -Dir $Dir -UvBody @(
        'if ("$args" -eq "python find $($args[2])") { Write-Output (Join-Path $PSScriptRoot "python.cmd") }'
        'if ($env:FAKE_FAIL -and "uv $args" -match $env:FAKE_FAIL) { exit 1 }'
    )
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'repo\scripts\windows')
    $files = @{ 'repo/pyproject.toml' = "[project]`r`nname = `"demo-dist`"`r`n"; 'repo/uv.lock' = "version = 1`r`n" }
    if ($Settings) { $files['repo/scripts/windows/python-ci.psd1'] = $Settings + "`r`n" }
    Write-TestFileTree -Root $Dir -Files $files
    foreach ($stub in @(@{ n = 'static'; p = 'PythonVersion, PackageName, RepoRoot, ExtraPaths, BanditExcludes' },
            @{ n = 'packaging'; p = 'PythonVersion, RepoRoot, TargetArch, FreeThreadedWheel' },
            @{ n = 'wheeltests'; p = 'PythonVersion, RepoRoot, TargetArch, FreeThreadedWheel' })) {
        $params = ($stub.p -split ', ' | ForEach-Object { "[string[]]`$$_" }) -join ', '
        Set-Content -LiteralPath (Join-Path $fake "$($stub.n).ps1") -Encoding utf8 -Value @(
            "param($params)"
            "Add-Content -LiteralPath `$env:FAKE_LOG -Value ('$($stub.n) ' + ((`$PSBoundParameters.GetEnumerator() | Sort-Object Key | ForEach-Object { `"`$(`$_.Key)=`$(`$_.Value -join '+')`" }) -join ' '))"
            "if (`$env:FAKE_FAIL -and '$($stub.n)' -match `$env:FAKE_FAIL) { exit 1 }"
        )
    }
}

# Runs the driver in a child pwsh from the demo repo; returns its exit code, its calls (the dir as <d>) and the summary.
function script:Invoke-CiBuildFixture {
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Arguments = @(), [string]$Fail = '', [switch]$Declares)
    $fake = Join-Path $Dir 'fake'
    $vars = @{ FAKE_FAIL = $Fail; FAKE_DECLARES = $(if ($Declares) { '1' } else { $null }); PATH = "$fake;$env:PATH"
        PYTHON_VERSION = '9.87.6'; EXPERIMENTAL_PYTHON_VERSIONS = $null; ORT_CHAIN_WHEEL_DIR = $null; PYTHON_WHEELS = $null; UV_PROJECT_ENVIRONMENT = $null
    }
    $seams = @('-StaticAnalysisScript', (Join-Path $fake 'static.ps1'), '-PackagingScript', (Join-Path $fake 'packaging.ps1'),
        '-WheelTestsScript', (Join-Path $fake 'wheeltests.ps1'))
    $result = Invoke-PythonCiFixtureDriver -Dir $Dir -Script $script:CiBuild -Environment $vars -Arguments ($seams + $Arguments) -WorkingDirectory (Join-Path $Dir 'repo')
    $summary = Get-ChildItem -LiteralPath (Join-Path $Dir 'repo\logs') -Filter 'build-summary-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
    Remove-Item -LiteralPath (Join-Path $Dir 'repo\logs') -Recurse -Force -ErrorAction SilentlyContinue
    $result.Calls = @($result.Calls | ForEach-Object { $_.Replace("$Dir\repo", '<d>') })
    $result | Add-Member -NotePropertyName Summary -NotePropertyValue $summary
    return $result
}

Describe 'Invoke-PythonCiBuild.ps1' {

    It 'takes every value from python-ci.psd1: legs, a free-threaded leg''s extras, the static paths and the data locks' {
        Invoke-InTestDir { param($d)
            New-CiBuildFixture $d -Settings "@{ PackageName = 'demo_pkg'; PythonVersions = @('3.13', 'pinnedt'); FreeThreadedExtras = 'tests'; TestPaths = 'tests/unit, tests/integration'
                ExtraPaths = @('bench', 'examples'); BanditExcludes = 'tests,vendor'; DataLocks = @('models/models.lock') }"
            $r = Invoke-CiBuildFixture -Dir $d
            Assert-Equal 0 $r.Code $r.Text
            $calls = $r.Calls -join '|'
            $sync = '-v sync --dev {0} --locked'
            foreach ($want in @("uv venv --python 3.13+gil --clear <d>\.venv-3.13|uv $($sync -f '--all-extras')",
                    "uv venv --python 9.87t --clear <d>\.venv-9.87t|uv $($sync -f '--extra tests')",
                    'uv run pytest tests/unit tests/integration -v --cov=demo_pkg --cov-report=term-missing --cov-report=html:logs/test-results/coverage-html-9.87t',
                    'static BanditExcludes=tests,vendor ExtraPaths=bench+examples PackageName=demo_pkg RepoRoot=<d>',
                    'packaging RepoRoot=<d>')) {
                Assert-True $calls.Contains($want) "missing: $want"
            }
            $fetcher = [regex]::Escape((Join-Path (Get-RepoRoot) 'linux\scripts\lib\fetch-data-lock.py'))
            Assert-Match "\|python -I $fetcher --lock <d>\\models\\models\.lock\|packaging " $calls 'the hub''s fetcher takes the lock before packaging'
            Assert-Match '\|packaging RepoRoot=<d>\|wheeltests RepoRoot=<d>$' $calls 'the installed-wheel tests last, on what packaging left'
            Assert-Equal 2 @($r.Calls | Where-Object { $_ -match '^uv run pytest (?:.* )?-v --cov=' }).Count 'one pytest run per leg'
            Assert-Equal '' (@($r.Summary.failedSteps) -join ',') 'nothing failed'
        }
    }

    It 'lets a parameter beat the settings file, and refuses a key that is no setting' {
        Invoke-InTestDir { param($d)
            New-CiBuildFixture $d -Settings "@{ PackageName = 'demo_pkg'; PythonVersions = '3.13' }"
            $r = Invoke-CiBuildFixture -Dir $d -Arguments @('-PackageName', 'other')
            Assert-Equal 0 $r.Code $r.Text
            Assert-Match 'uv run pytest -v --cov=other ' ($r.Calls -join '|')
            Assert-Match '\|static PackageName=other RepoRoot=<d>\|' ($r.Calls -join '|')
            foreach ($bad in "@{ PackageNmae = 'x' }", "@{ RepoRoot = 'C:\elsewhere' }") {
                Set-Content -LiteralPath (Join-Path $d 'repo\scripts\windows\python-ci.psd1') -Value $bad
                $r = Invoke-CiBuildFixture -Dir $d
                Assert-True ($r.Code -ne 0) "accepted $bad"
                Assert-Match "sets '(PackageNmae|RepoRoot)', which is not a setting" $r.Text
            }
        }
    }

    It 'gates on a failed leg and on static analysis, but not on a demo or an experimental free-threaded leg' {
        Invoke-InTestDir { param($d)
            New-CiBuildFixture $d -Settings "@{ PythonVersions = 'pinned pinnedt' }"
            $r = Invoke-CiBuildFixture -Dir $d -Fail 'report-9\.87t\.xml|bench/demo_cprofile'
            Assert-Equal 0 $r.Code $r.Text
            Assert-Match 'demo_cprofile\.py skipped \(exit 1\)' $r.Text
            Assert-Match 'Python 9\.87t - Tests' $r.Text 'the experimental leg is reported'
            Assert-Equal 'demo-dist' ([regex]::Match(($r.Calls -join '|'), '--cov=([^ ]+)').Groups[1].Value) 'the package name from pyproject.toml'
            foreach ($case in @(@{ fail = 'report-9\.87\.xml'; step = 'Python 9.87 - Tests' }, @{ fail = '^static$'; step = 'Static Analysis' },
                    @{ fail = '^packaging$'; step = 'Packaging (source + Windows binaries)' }, @{ fail = '^wheeltests$'; step = 'Free-threaded wheel tests' })) {
                $r = Invoke-CiBuildFixture -Dir $d -Fail $case.fail
                Assert-Equal 1 $r.Code "a failed $($case.step) must fail the run"
                Assert-Equal $case.step (@($r.Summary.failedSteps) -join ',')
            }
        }
    }

    It 'runs the pinned X.Y, and its X.Yt twin only for a project that declares free-threading' {
        Invoke-InTestDir { param($d)
            New-CiBuildFixture $d
            $legs = { param($r) @($r.Calls | Where-Object { $_ -like 'uv venv --python *' } | ForEach-Object { ($_ -split ' ')[3] }) -join ',' }
            Assert-Equal '9.87+gil,9.87t' (& $legs (Invoke-CiBuildFixture -Dir $d -Declares))
            Assert-Equal '9.87+gil' (& $legs (Invoke-CiBuildFixture -Dir $d))
        }
    }

    It 'passes the child drivers only parameters they declare' {
        $calls = @(Get-TestScriptCommands -ScriptPath $script:CiBuild -Name 'Invoke-ChildDriver')
        Assert-Equal 3 $calls.Count 'the static-analysis, packaging and wheel-tests calls'
        $drivers = @{ '$StaticAnalysisScript' = 'Invoke-CiStaticAnalysis.ps1'; '$PackagingScript' = 'Invoke-CiPackaging.ps1'; '$WheelTestsScript' = 'Invoke-FreeThreadedWheelTests.ps1' }
        foreach ($call in $calls) {
            $driver = Join-Path (Split-Path $script:CiBuild) $drivers[$call.CommandElements[1].Extent.Text]
            $declared = @((Get-TestScriptAst -ScriptPath $driver).ParamBlock.Parameters.Name.VariablePath.UserPath)
            $passed = @($call.CommandElements[2].Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs.Item1.Value)
            foreach ($name in $passed) { Assert-True ($name -in $declared) "$(Split-Path $driver -Leaf) has no -$name" }
        }
    }
}
