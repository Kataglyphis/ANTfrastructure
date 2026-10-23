#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the stage itself, which needs :winarm64's target trees and VS's ARM64 tools (measured there, CON113).

Describe 'New-Arm64PythonTestStage: what windows-11-arm runs (CON113)' {

    $script:stagePath = 'windows\scripts\python\New-Arm64PythonTestStage.ps1'
    Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking
    foreach ($fn in 'Get-StageAbiTag', 'Get-StageTestFile', 'New-StageLegScript') {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:stagePath -FunctionName $fn)
    }

    It 'names each leg''s wheel ABI, GIL and free-threaded' {
        Assert-Equal 'cp315|cp315t|cp316' ((Get-StageAbiTag '3.15'), (Get-StageAbiTag '3.15t'), (Get-StageAbiTag '3.16') -join '|') 'cpXY and cpXYt'
    }

    It 'stages tests\ and the root''s pytest configuration by default, and only the listed paths otherwise' {
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $d 'tests'), (Join-Path $d 'pkg')
            foreach ($f in 'pytest.ini', 'pyproject.toml', 'setup.py') { Set-Content -LiteralPath (Join-Path $d $f) -Value '' }
            Assert-Equal 'tests|pytest.ini|pyproject.toml' ((Get-StageTestFile -RepoRoot $d) -join '|') 'no package sources, which would shadow the wheel'
            Assert-Equal 'tests/unit|pytest.ini' ((Get-StageTestFile -RepoRoot $d -TestFiles 'tests/unit, pytest.ini') -join '|') 'the caller''s list'
        }
    }

    It 'runs pytest on the leg''s own interpreter in run\, with the caller''s environment' {
        $s = New-StageLegScript -Leg '3.15t' -Exe 'python3.15t.exe' -Distribution 'pkg' -TestEnv 'EXPECT_COMPILED=1' -TestPaths 'tests/unit'
        Assert-Equal '@echo off|cd /d "%~dp0run"|set "EXPECT_COMPILED=1"|"%~dp0python-3.15t\python3.15t.exe" -m pytest -p no:cacheprovider tests/unit' ($s.Run -join '|') 'the run script'
        Assert-Throws { New-StageLegScript -Leg '3.15' -Exe 'python.exe' -Distribution 'pkg' -TestEnv 'X=a&b' } -MessagePattern 'without quotes or cmd metacharacters'
    }

    It 'proves the wheel alone: its own directory on PYTHONPATH, no site-packages, with the leg''s check (mutation)' {
        $ft = New-StageLegScript -Leg '3.15t' -Exe 'python3.15t.exe' -Distribution 'pkg' -Check prove
        Assert-Equal '@echo off|set "PYTHONPATH=%~dp0proof-3.15t"|"%~dp0python-3.15t\python3.15t.exe" -S "%~dp0free-threaded-wheel.py" prove pkg' ($ft.Proof -join '|') 'the free-threaded proof'
        Assert-Match ' load pkg$' (New-StageLegScript -Leg '3.15' -Exe 'python.exe' -Distribution 'pkg').Proof[-1] 'the GIL build only loads'
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:stagePath))
        Assert-True $text.Contains('Get-NativeWheelCheck -Name $wheel.Name -Leg $leg -Platform (Get-PythonWheelTag)') 'the check comes from the wheel''s own tags'
    }

    It 'stages pyproject.toml''s free-threaded wheel tests on an X.Yt leg''s own interpreter, which must hold their extra (CON122)' {
        $lines = @(Get-Content -LiteralPath (Join-Path (Get-RepoRoot) $script:stagePath) | ForEach-Object Trim)
        $want = '$suite = Get-FreeThreadedWheelSuite -Python $gil.Exe -PyprojectPath $pyproject', 'if ($ft -and $binary -and $suite) {',
            '$manifest.Add((New-FreeThreadedWheelTestStage -Suite $suite -RepoRoot $repo -StageDir $out -Name "wheel-tests-$leg" `',
            '-Python "python-$leg\$($exe[0].Name)" -Wheel $wheel.Name))'
        Assert-Equal '' (@($want | Where-Object { $_ -notin $lines }) -join ' || ') 'the X.Yt leg reads the table and stages its run on its own python'
        Assert-Match '\$suite\.Extra -notin \$legExtras\) \{\s*throw' ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:stagePath))) 'a leg without the extra fails the stage'
    }

    It 'builds the wheels in a child, where VS''s cross environment ends, with clang-cl told the target through CL' {
        Assert-TestScriptContains -ScriptPath $script:stagePath -ReasonPrefix 'the stage holds' -Literal @(
            '& pwsh -NoProfile -File $PSCommandPath -RepoRoot $repo', '$env:CL = "--target=$((Get-WindowsTargetArchInfo).ClangTriple)"',
            'Invoke-CrossWheelBuild -Python $venv.Exe -Source $repo', 'Install-PythonCrossSite -HostPython $hostPython -SitePackages $site')
    }
}
