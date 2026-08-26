#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The pure helpers behind the cross lane's hand-assembled TVM wheels (#133,
# build-tvm-from-source.ps1): Write-AssembledWheelDistInfo (METADATA / WHEEL /
# top_level.txt for `python -m wheel pack`), Get-VendoredTvmFfiVersion (the
# submodule's v* tag, PEP 440-normalised, else TVM's own >= bound) and
# Get-PyprojectDependencies (the [project] dependencies block, never
# hardcoded). Lifted out of the script's AST; no python, no TVM.

Describe 'TVM assembled-wheel helpers' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $tvmScript = Join-Path $root 'scripts\build\build-tvm-from-source.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($tvmScript, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) { throw "parse errors in $tvmScript : $($parseErrors[0].Message)" }
        foreach ($fn in 'Write-AssembledWheelDistInfo', 'Get-VendoredTvmFfiVersion', 'Get-PyprojectDependencies') {
            $fnAst = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)) | Select-Object -First 1
            if (-not $fnAst) { throw "$fn not defined in $tvmScript" }
            . ([scriptblock]::Create($fnAst.Extent.Text))
        }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-tvmwheel-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:tmp 'root\tvm_ffi\lib') | Out-Null
        Set-Content (Join-Path $script:tmp 'root\tvm_ffi\__init__.py') '# pkg'
        Set-Content (Join-Path $script:tmp 'root\tvm_ffi\core.cp314-win_arm64.pyd') 'not a real pyd'
        Set-Content (Join-Path $script:tmp 'root\tvm_ffi\lib\tvm_ffi.dll') 'not a real dll'
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes a binary-wheel dist-info with the target tag, the requirements and the top-level package' {
        $di = Write-AssembledWheelDistInfo -Name 'apache-tvm-ffi' -Version '0.1.13.post3' -PackageRoot (Join-Path $script:tmp 'root') -RequiresDist @('typing-extensions>=4.5') -RequiresPython '>=3.9' -Summary 'fixture'
        Assert-True ($di -like '*apache_tvm_ffi-0.1.13.post3.dist-info') "dist-info dir name ($di)"
        $meta = Get-Content (Join-Path $di 'METADATA')
        Assert-True ($meta -contains 'Name: apache-tvm-ffi') 'Name'
        Assert-True ($meta -contains 'Version: 0.1.13.post3') 'Version'
        Assert-True ($meta -contains 'Requires-Dist: typing-extensions>=4.5') 'Requires-Dist'
        Assert-True ($meta -contains 'Requires-Python: >=3.9') 'Requires-Python'
        $wheel = Get-Content (Join-Path $di 'WHEEL')
        Assert-True ($wheel -contains 'Tag: cp314-cp314-win_arm64') 'Tag line drives the archive name'
        Assert-True ($wheel -contains 'Root-Is-Purelib: false') 'binary wheel'
        Assert-Equal 'tvm_ffi' ((Get-Content (Join-Path $di 'top_level.txt')) -join ',') 'top_level excludes the dist-info itself'
    }

    It 'normalises the submodule tag and falls back to the pyproject bound' {
        Assert-Equal '0.1.13.post3' (Get-VendoredTvmFfiVersion -DescribeOutput 'v0.1.13-post3') 'dash-post tag'
        Assert-Equal '0.1.13' (Get-VendoredTvmFfiVersion -DescribeOutput "v0.1.13`n") 'plain tag, trailing newline'
        Assert-Equal '0.1.13.post2' (Get-VendoredTvmFfiVersion -DescribeOutput 'fatal: No names found' -TvmPyprojectText 'dependencies = [`n  "apache-tvm-ffi>=0.1.13.post2",`n  "numpy",`n]') 'falls back to the >= bound'
        $threw = $false
        try { Get-VendoredTvmFfiVersion -DescribeOutput '' -TvmPyprojectText 'nothing here' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'no tag and no bound must throw'
    }

    It 'reads the [project] dependencies block and nothing else' {
        # Lists BEFORE dependencies (classifiers, authors, keywords) are the
        # shape both real pyprojects have -- run 34: a regex that forbade any `[`
        # between [project] and the list matched nothing and both wheels
        # shipped with NO requirements (a defect the deps gate cannot see).
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
        Assert-Equal 0 (@(Get-PyprojectDependencies -PyprojectText '[project]`nname = "x"')).Count 'no block -> empty'
    }

    It 'stops at the one-line list and never runs into [project.urls] / optional-dependencies (tvm-ffi shape, run 33)' {
        # arm64 run 33: the assembled tvm-ffi wheel declared its Homepage URL,
        # ninja, torch and setuptools as requirements because the capture ran past
        # the one-line `dependencies = [...]` to the next `]` at a line start.
        $py = @(
            '[project]', 'name = "apache-tvm-ffi"', 'requires-python = ">=3.9"',
            'dependencies = ["typing-extensions>=4.5"]',
            '', '[project.urls]', 'Homepage = "https://github.com/apache/tvm-ffi"',
            '', '[project.optional-dependencies]', 'torch = [', '  "ninja",', '  "torch; python_version < ''3.14''",', '  "setuptools",', ']'
        ) -join "`n"
        $deps = @(Get-PyprojectDependencies -PyprojectText $py)
        Assert-Equal 'typing-extensions>=4.5' ($deps -join ',') 'only the real dependency'
        # An extras marker keeps its own brackets inside the list.
        $py2 = "[project]`nname = ""x""`ndependencies = [`n  ""torch[cuda]>=2"",`n  ""numpy"",`n]`n[project.urls]`nHome = ""https://x""`n"
        Assert-Equal 'torch[cuda]>=2,numpy' ((Get-PyprojectDependencies -PyprojectText $py2) -join ',') 'extras brackets survive'
    }
}
