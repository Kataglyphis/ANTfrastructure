#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: Invoke-CiPackaging.ps1's build, venv and install around these, which need a real free-threaded interpreter (proved in :winamd64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking

# A python that logs its arguments to FAKE_PY_LOG, prints FAKE_PY_TEXT and exits FAKE_PY_RC.
function script:New-FakePython([string]$Dir) {
    $cmd = Join-Path $Dir 'python.cmd'
    Set-Content -LiteralPath $cmd -Encoding ascii -Value @('@echo %*>> "%FAKE_PY_LOG%"', '@echo %FAKE_PY_TEXT%', '@exit /b %FAKE_PY_RC%')
    return $cmd
}

# Runs -Body with the fake python answering -Code and -Text; returns what -Body returned.
function script:Invoke-WithFakePython {
    param([Parameter(Mandatory)][string]$Dir, [int]$Code = 0, [string]$Text = 'ok', [Parameter(Mandatory, Position = 0)][scriptblock]$Body)
    Invoke-WithEnv @{ FAKE_PY_LOG = (Join-Path $Dir 'py.log'); FAKE_PY_TEXT = $Text; FAKE_PY_RC = "$Code" } { & $Body (New-FakePython $Dir) }
}

Describe 'Resolve-FreeThreadedWheelMode and Get-FreeThreadedTarget' {

    It 'takes -Value, then PYTHON_FREE_THREADED_WHEEL, then auto, and refuses anything but auto, on or off' {
        Invoke-WithEnv @{ PYTHON_FREE_THREADED_WHEEL = $null } {
            Assert-Equal 'auto' (Resolve-FreeThreadedWheelMode) 'unset'
            Assert-Equal 'on' (Resolve-FreeThreadedWheelMode -Value 'on')
        }
        Invoke-WithEnv @{ PYTHON_FREE_THREADED_WHEEL = 'off' } {
            Assert-Equal 'off' (Resolve-FreeThreadedWheelMode) 'from the environment'
            Assert-Equal 'auto' (Resolve-FreeThreadedWheelMode -Value 'auto') '-Value wins'
        }
        Assert-Throws { Resolve-FreeThreadedWheelMode -Value 'yes' } -MessagePattern "must be auto, on or off, not 'yes'"
        Assert-Throws { Resolve-FreeThreadedWheelMode -Value 'OFF' } -MessagePattern "not 'OFF'"
    }

    It 'pairs a GIL version with its free-threaded request and ABI tag' {
        foreach ($v in '3.14', '3.14.4', '3.14t') {
            $t = Get-FreeThreadedTarget -PythonVersion $v
            Assert-Equal '3.14t|cp314t' "$($t.Version)|$($t.AbiTag)" $v
        }
        Assert-Throws { Get-FreeThreadedTarget -PythonVersion '3' } -MessagePattern 'not an X\.Y'
    }
}

Describe 'Get-PinnedPythonVersion (CON91)' {

    It 'takes the image ENV first, and versions.env without it, a quoted value and a comment line included' {
        Invoke-InTestDir { param($d)
            $envFile = Join-Path $d 'versions.env'
            Set-Content -LiteralPath $envFile -Value @('# PYTHON_VERSION=1.2.3 in a comment', 'PYTHON_VERSION="9.87.6"  # the pin')
            Invoke-WithEnv @{ PYTHON_VERSION = '8.76.5' } {
                $p = Get-PinnedPythonVersion -VersionsEnvPath $envFile
                Assert-Equal '8.76.5|8.76|cp876|cp876t' "$($p.Version)|$($p.MajorMinor)|$($p.AbiTag)|$($p.FreeThreadedAbiTag)" 'the ENV wins'
            }
            Invoke-WithEnv @{ PYTHON_VERSION = $null } {
                $p = Get-PinnedPythonVersion -VersionsEnvPath $envFile
                Assert-Equal '9.87.6|9.87|cp987|cp987t' "$($p.Version)|$($p.MajorMinor)|$($p.AbiTag)|$($p.FreeThreadedAbiTag)" 'versions.env'
            }
        }
    }

    It 'reads the hub''s own versions.env by default' {
        $pin = (ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'))['PYTHON_VERSION']
        Invoke-WithEnv @{ PYTHON_VERSION = $null } { Assert-Equal $pin (Get-PinnedPythonVersion).Version 'the checkout pin' }
    }

    It 'throws without a pin, and on a value that is no X.Y[.Z] (mutation)' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_VERSION = $null } {
                Assert-Throws { Get-PinnedPythonVersion -VersionsEnvPath (Join-Path $d 'absent.env') } -MessagePattern 'no pinned Python'
            }
            foreach ($bad in '3', 'latest', '3.15.0rc1') {
                Invoke-WithEnv @{ PYTHON_VERSION = $bad } {
                    Assert-Throws { Get-PinnedPythonVersion -VersionsEnvPath (Join-Path $d 'absent.env') } -MessagePattern "no pinned Python: PYTHON_VERSION is '$bad'"
                }
            }
        }
    }
}

Describe 'Get-FreeThreadedWheelPlan' {

    It 'builds when the helper finds the classifier, and hands it the pyproject; a cross arch with a target tree too (CON75)' {
        Invoke-InTestDir { param($d)
            $lib = New-Item -ItemType File -Path (Join-Path $d 'python314t.lib')
            foreach ($cross in @(@{}, @{ CrossArch = 'arm64'; TargetLib = $lib.FullName })) {
                $plan = Invoke-WithFakePython -Dir $d -Text 'Programming Language :: Python :: Free Threading :: 2 - Beta' { param($py)
                    Get-FreeThreadedWheelPlan -Mode 'auto' -PyprojectPath 'C:\p\pyproject.toml' -Python $py @cross }
                Assert-True $plan.Build
                Assert-Equal "free-threaded wheel: the project declares 'Programming Language :: Python :: Free Threading :: 2 - Beta'" $plan.Reason
            }
            Assert-Match 'free-threaded-wheel\.py declares C:\\p\\pyproject\.toml' (Get-Content -Raw (Join-Path $d 'py.log')) 'the shared helper, with -I'
        }
    }

    It 'skips an undeclared project on auto and builds it on on; an unreadable verdict throws' {
        Invoke-InTestDir { param($d)
            $why = "no 'Programming Language :: Python :: Free Threading' classifier in pyproject.toml"
            $auto = Invoke-WithFakePython -Dir $d -Code 1 -Text $why { param($py) Get-FreeThreadedWheelPlan -Mode 'auto' -PyprojectPath 'p' -Python $py }
            Assert-False $auto.Build
            Assert-Equal "free-threaded wheel skipped: the project does not declare support ($why)" $auto.Reason
            $on = Invoke-WithFakePython -Dir $d -Code 1 -Text $why { param($py) Get-FreeThreadedWheelPlan -Mode 'on' -PyprojectPath 'p' -Python $py }
            Assert-True $on.Build
            Assert-Match 'PYTHON_FREE_THREADED_WHEEL=on, although no ' $on.Reason
            Assert-Throws { Invoke-WithFakePython -Dir $d -Code 2 -Text 'bad toml' { param($py) Get-FreeThreadedWheelPlan -Mode 'auto' -PyprojectPath 'p' -Python $py } } `
                -MessagePattern 'cannot tell whether the project declares free-threading support: bad toml'
        }
    }

    It 'skips a cross arch without a target tree, and off, without asking the helper' {
        Invoke-InTestDir { param($d)
            $cross = Invoke-WithFakePython -Dir $d { param($py) Get-FreeThreadedWheelPlan -Mode 'on' -PyprojectPath 'p' -Python $py -CrossArch 'arm64' -TargetLib "$d\no.lib" }
            Assert-Equal "free-threaded wheel skipped: the arm64 image carries no free-threaded target tree: no $d\no.lib" $cross.Reason
            $off = Get-FreeThreadedWheelPlan -Mode 'off' -PyprojectPath 'p'
            Assert-Equal 'free-threaded wheel skipped: PYTHON_FREE_THREADED_WHEEL=off' $off.Reason
            Assert-False ($cross.Build -or $off.Build)
            Assert-False (Test-Path (Join-Path $d 'py.log')) 'the helper never ran'
            Assert-Throws { Get-FreeThreadedWheelPlan -Mode 'auto' -PyprojectPath 'p' } -MessagePattern 'needs -Python'
        }
    }
}

Describe 'Select-FreeThreadedWheel and Get-PythonWheelAbiTag' {

    It 'reads the ABI field of a wheel name' {
        Assert-Equal 'cp314t' (Get-PythonWheelAbiTag -Name 'app-1.0-cp314-cp314t-win_amd64.whl')
        Assert-Equal 'none' (Get-PythonWheelAbiTag -Name 'app-1.0-py3-none-any.whl')
        Assert-Equal 'abi3' (Get-PythonWheelAbiTag -Name 'app-1.0-1-cp312-abi3-win_amd64.whl') 'a build tag shifts nothing'
        Assert-Throws { Get-PythonWheelAbiTag -Name 'app-1.0.tar.gz' } -MessagePattern 'not a wheel file name'
    }

    It 'returns the free-threaded binary, $null for a pure build, and throws on any other result' {
        Invoke-InTestDir { param($d)
            $pick = { param([string[]]$Names)
                Get-ChildItem -LiteralPath $d -Filter '*.whl' | Remove-Item
                foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $d $n) -Value 'w' }
                Select-FreeThreadedWheel -Wheels @(Get-ChildItem -LiteralPath $d -Filter '*.whl') -AbiTag 'cp314t'
            }
            Assert-Equal 'app-1.0-cp314-cp314t-win_amd64.whl' (& $pick @('app-1.0-cp314-cp314t-win_amd64.whl')).Name
            Assert-Null (& $pick @('app-1.0-py3-none-any.whl')) 'pure'
            Assert-Throws { & $pick @('app-1.0-cp314-cp314-win_amd64.whl') } -MessagePattern 'produced app-1\.0-cp314-cp314-win_amd64\.whl, not a cp314t wheel'
            Assert-Throws { & $pick @() } -MessagePattern 'left 0 wheels, not one'
            Assert-Throws { & $pick @('a-1-cp314-cp314t-win_amd64.whl', 'b-1-cp314-cp314t-win_amd64.whl') } -MessagePattern 'left 2 wheels'
        }
    }
}

Describe 'Invoke-FreeThreadedWheelProof and Add-PythonLibPath' {

    It 'returns the verdict of a passing proof and throws with the verdict of a failing one, the GIL build''s load check too' {
        Invoke-InTestDir { param($d)
            $ok = Invoke-WithFakePython -Dir $d -Text '3 compiled modules loaded' { param($py) Invoke-FreeThreadedWheelProof -Python $py -Distribution 'app' }
            Assert-Equal '3 compiled modules loaded' $ok
            Assert-Match 'free-threaded-wheel\.py prove app' (Get-Content -Raw (Join-Path $d 'py.log'))
            Assert-Throws { Invoke-WithFakePython -Dir $d -Code 1 -Text 'the GIL was re-enabled by app.core' { param($py) Invoke-FreeThreadedWheelProof -Python $py -Distribution 'app' } } `
                -MessagePattern 'free-threaded proof failed for app: the GIL was re-enabled by app\.core'
            $null = Invoke-WithFakePython -Dir $d { param($py) Invoke-FreeThreadedWheelProof -Python $py -Distribution 'app' -Check load }
            Assert-Match 'free-threaded-wheel\.py load app' (Get-Content -Raw (Join-Path $d 'py.log')) '-Check load'
            Assert-Throws { Invoke-WithFakePython -Dir $d -Code 1 -Text 'cannot load app.core' { param($py) Invoke-FreeThreadedWheelProof -Python $py -Distribution 'app' -Check load } } `
                -MessagePattern '^load proof failed for app: cannot load app\.core'
            Assert-Throws { Invoke-FreeThreadedWheelProof -Python 'python' -Distribution 'app' -Check 'import' } -MessagePattern 'import'
        }
    }

    It 'puts an in-tree interpreter directory on LIB, and only that kind' {
        Invoke-InTestDir { param($d)
            $tree = New-Item -ItemType Directory -Path (Join-Path $d 'tree')
            Set-Content -LiteralPath (Join-Path $tree 'python314t.lib') -Value 'lib'
            Invoke-WithEnv @{ LIB = 'C:\sdk' } {
                Add-PythonLibPath -PythonDir $d
                Assert-Equal 'C:\sdk' $env:LIB 'no python3*.lib, no change'
                Add-PythonLibPath -PythonDir $tree.FullName
                Assert-Equal "$($tree.FullName);C:\sdk" $env:LIB
            }
        }
    }
}

Describe 'Resolve-PythonLegList and Get-NativeWheelCheck (Invoke-NativeWheelBuild.ps1)' {

    It 'reads empty as the pinned X.Y, pinned and pinnedt as it and its twin, and either separator' {
        Invoke-InTestDir { param($d)
            $envFile = Join-Path $d 'versions.env'
            Set-Content -LiteralPath $envFile -Value 'PYTHON_VERSION=3.14.2'
            Invoke-WithEnv @{ PYTHON_VERSION = $null } {
                Assert-Equal '3.14' ((Resolve-PythonLegList -VersionsEnvPath $envFile) -join '|') 'empty'
                Assert-Equal '3.14|3.14t' ((Resolve-PythonLegList -PythonVersions 'pinned pinnedt' -VersionsEnvPath $envFile) -join '|')
                Assert-Equal '3.13|3.14t' ((Resolve-PythonLegList -PythonVersions '3.13, 3.14t' -VersionsEnvPath $envFile) -join '|')
                Assert-Throws { Resolve-PythonLegList -PythonVersions ' , ' -VersionsEnvPath $envFile } -MessagePattern 'names no leg'
            }
        }
    }

    It 'loads an X.Y leg''s wheel, proves an X.Yt leg''s, and refuses any other ABI or platform' {
        Assert-Equal 'load' (Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314-win_arm64.whl' -Leg '3.14' -Platform 'win_arm64')
        Assert-Equal 'load' (Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314-win_arm64.whl' -Leg '3.14.2' -Platform 'win_arm64') 'X.Y.Z'
        Assert-Equal 'prove' (Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314t-win_arm64.whl' -Leg '3.14t' -Platform 'win_arm64')
        Assert-Throws { Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314-win_amd64.whl' -Leg '3.14' -Platform 'win_arm64' } `
            -MessagePattern 'built app-1\.0-cp314-cp314-win_amd64\.whl, not a cp314 win_arm64 wheel'
        Assert-Throws { Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314t-win_arm64.whl' -Leg '3.14' -Platform 'win_arm64' } -MessagePattern 'not a cp314 win_arm64'
        Assert-Throws { Get-NativeWheelCheck -Name 'app-1.0-py3-none-any.whl' -Leg '3.14t' -Platform 'win_arm64' } -MessagePattern 'not a cp314t win_arm64'
        Assert-Throws { Get-NativeWheelCheck -Name 'app-1.0-cp314-cp314-win_arm64.whl' -Leg 'latest' -Platform 'win_arm64' } -MessagePattern 'no X\.Y or X\.Yt'
    }
}
