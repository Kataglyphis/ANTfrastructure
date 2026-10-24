#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The pure helpers behind the cross lane's hand-assembled TVM wheels, lifted from the script; no python, no TVM.

Describe 'TVM assembled-wheel helpers' {

    BeforeAll {
        $script:tmp = New-TestDir -Prefix 'wbt-tvmwheel-' -Files @{
            'root/tvm_ffi/__init__.py' = '# pkg'; 'root/tvm_ffi/core.cp314-win_arm64.pyd' = 'not a real pyd'
            'root/tvm_ffi/lib/tvm_ffi.dll' = 'not a real dll'
        }
    }
    AfterAll { Remove-TestDir -Path $script:tmp }

    It 'writes a binary-wheel dist-info with the target tag, the requirements and the top-level package' {
        $di = Write-AssembledWheelDistInfo -Name 'apache-tvm-ffi' -Version '0.1.13.post3' -PackageRoot (Join-Path $script:tmp 'root') -PythonTag 'cp987' -AbiTag 'cp987' -RequiresDist @('typing-extensions>=4.5') -RequiresPython '>=3.9' -Summary 'fixture'
        Assert-True ($di -like '*apache_tvm_ffi-0.1.13.post3.dist-info') "dist-info dir name ($di)"
        $meta = Get-Content (Join-Path $di 'METADATA')
        Assert-True ($meta -contains 'Name: apache-tvm-ffi') 'Name'
        Assert-True ($meta -contains 'Version: 0.1.13.post3') 'Version'
        Assert-True ($meta -contains 'Requires-Dist: typing-extensions>=4.5') 'Requires-Dist'
        Assert-True ($meta -contains 'Requires-Python: >=3.9') 'Requires-Python'
        $wheel = Get-Content (Join-Path $di 'WHEEL')
        Assert-True ($wheel -contains 'Tag: cp987-cp987-win_arm64') 'Tag line drives the archive name'
        Assert-True ($wheel -contains 'Root-Is-Purelib: false') 'binary wheel'
        Assert-Equal 'tvm_ffi' ((Get-Content (Join-Path $di 'top_level.txt')) -join ',') 'top_level excludes the dist-info itself'
    }

    It 'Build-TvmFromSource tags the GIL wheel with the pin and the twin cpXY-cpXYt (CON91)' {
        $tvm = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TvmFromSource.ps1'))
        Assert-Match '-CrossPython \$tvmCrossPython -TargetPython \$tvmTargetPy -HostPython \$py -TvmVersion \$TvmVersion' $tvm 'the cross path passes the selected target interpreter into runtime staging'
        Assert-Match '-TargetPython \$TargetPython -HostPython \$HostPython -BuildType \$BuildType' $tvm 'runtime staging forwards the interpreter to the wheel stage'
        Assert-Match '(?s)function Invoke-TvmCrossPythonWheels.*?New-TvmFfiCrossWheel -Python \$TargetPython .*?-AbiTag \(Get-PinnedPythonVersion\)\.AbiTag' $tvm 'the GIL wheel carries the pin''s cpXY, not a default'
        Assert-Match "PythonTag = \(\`$AbiTag -replace 't\$', ''\); AbiTag = \`$AbiTag" $tvm 'the python tag drops the free-threaded t'
        Assert-False ($tvm -match "AbiTag = 'cp3") 'no literal tag default'
    }

    It 'shares the target extension-tag verdict across TVM staging and wheel validation' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' -FunctionName 'Test-PythonExtensionHostTag')
        Assert-False (Test-PythonExtensionHostTag -Name 'core.pyd' -TargetTag 'win_arm64') 'a bare extension is valid'
        Assert-False (Test-PythonExtensionHostTag -Name 'core.cp315t-win_arm64.pyd' -TargetTag 'win_arm64') 'a target-tagged twin is valid'
        Assert-True (Test-PythonExtensionHostTag -Name 'core.cp315-win_amd64.pyd' -TargetTag 'win_arm64') 'a host-tagged extension fails'
        Assert-True (Test-PythonExtensionHostTag -Name 'core.cp315t-win_amd64.pyd' -TargetTag 'win_arm64') 'a host-tagged twin fails'
        $tvm = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/build/Build-TvmFromSource.ps1'))
        $common = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1'))
        Assert-Match 'Test-PythonExtensionHostTag -Name \$corePyd\.Name -TargetTag \$wantExt' $tvm 'TVM checks its built core'
        Assert-Match 'Test-PythonExtensionHostTag -Name \$f\.Name -TargetTag \$wantTag' $common 'the wheel gate checks every member'
        Assert-Match 'Copy-SelectedBuildArtifacts -Artifact \$runtimeBins -Destination \$tvmLibOut' $tvm 'TVM stages selected runtime binaries'
        Assert-Match 'Copy-SelectedBuildArtifacts -Artifact \$wheels -Destination \$WheelDir -LogPrefix ''Staged wheel:''' $common 'wheel staging keeps its diagnostics'
    }

    It 'normalises the submodule tag and falls back to the pyproject bound' {
        Assert-Equal '0.1.13.post3' (Get-VendoredTvmFfiVersion -DescribeOutput 'v0.1.13-post3') 'dash-post tag'
        Assert-Equal '0.1.13' (Get-VendoredTvmFfiVersion -DescribeOutput "v0.1.13`n") 'plain tag, trailing newline'
        Assert-Equal '0.1.13.post2' (Get-VendoredTvmFfiVersion -DescribeOutput 'fatal: No names found' -TvmPyprojectText "dependencies = [`n  ""apache-tvm-ffi>=0.1.13.post2"",`n  ""numpy"",`n]") 'falls back to the >= bound'
        Assert-Throws { Get-VendoredTvmFfiVersion -DescribeOutput '' -TvmPyprojectText 'nothing here' | Out-Null } 'no tag and no bound must throw'
    }

    It 'reads the [project] dependencies block and nothing else' {
        # Real pyprojects have lists before dependencies; a regex that forbids `[` there silently yields no requirements.
        $py = @(
            '[build-system]', 'requires = ["scikit-build-core>=0.11"]', '[project]', 'name = "apache-tvm"',
            'authors = [{ name = "Apache TVM Community", email = "dev@tvm.apache.org" }]',
            'keywords = ["machine learning", "compiler"]',
            'classifiers = [', '  "Development Status :: 4 - Beta",', '  "Programming Language :: Python :: 3",', ']',
            'dependencies = [', '  "apache-tvm-ffi>=0.1.13.post2",', '  "ml_dtypes",', '  "numpy",', '  "typing_extensions",', ']',
            '[project.optional-dependencies]', 'torch = ["torch"]'
        ) -join "`n"
        $deps = @(Get-PyprojectDependencies -PyprojectText $py)
        Assert-Equal 'apache-tvm-ffi>=0.1.13.post2,ml_dtypes,numpy,typing_extensions' ($deps -join ',') 'exact list, torch extra excluded'
        Assert-Equal 0 (@(Get-PyprojectDependencies -PyprojectText "[project]`nname = ""x""")).Count 'no block -> empty'
        # The container checkout is CRLF, and .NET's multiline `$` matches only right before `\n`.
        Assert-Equal 'apache-tvm-ffi>=0.1.13.post2,ml_dtypes,numpy,typing_extensions' `
            ((Get-PyprojectDependencies -PyprojectText ($py -replace "`n", "`r`n")) -join ',') 'CRLF file parses identically'
    }

    It 'stops at the one-line list and never runs into [project.urls] / optional-dependencies (tvm-ffi shape, run 33)' {
        # A capture that runs past a one-line list to the next line-start `]` swallows URLs and extras.
        $py = @(
            '[project]', 'name = "apache-tvm-ffi"', 'requires-python = ">=3.9"',
            'dependencies = ["typing-extensions>=4.5"]',
            '', '[project.urls]', 'Homepage = "https://github.com/apache/tvm-ffi"',
            '', '[project.optional-dependencies]', 'torch = [', '  "ninja",', '  "torch; python_version < ''3.14''",', '  "setuptools",', ']'
        ) -join "`n"
        $deps = @(Get-PyprojectDependencies -PyprojectText $py)
        Assert-Equal 'typing-extensions>=4.5' ($deps -join ',') 'only the real dependency'
        Assert-Equal 'typing-extensions>=4.5' ((Get-PyprojectDependencies -PyprojectText ($py -replace "`n", "`r`n")) -join ',') 'one-line list, CRLF'
        # An extras marker keeps its own brackets inside the list.
        $py2 = "[project]`nname = ""x""`ndependencies = [`n  ""torch[cuda]>=2"",`n  ""numpy"",`n]`n[project.urls]`nHome = ""https://x""`n"
        Assert-Equal 'torch[cuda]>=2,numpy' ((Get-PyprojectDependencies -PyprojectText $py2) -join ',') 'extras brackets survive'
    }
}
