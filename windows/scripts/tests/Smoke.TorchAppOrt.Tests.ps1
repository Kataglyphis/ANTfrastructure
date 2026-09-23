#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Smoke section 21: the app venv's onnxruntime carries DirectML and IS the chain wheel, on every amd64 lane.
# NOT covered: the probe's python on a real CPython (measured by hand, see the fixtures), any GPU.

# Rooted = as given, so a mutation run can point this at a broken copy of the smoke script.
$script:SmokeScript = 'windows\scripts\build\Test-Container.ps1'

function Resolve-SmokeOrtSuitePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-RepoRoot) $Path)
}

$script:VenvSite = 'C:\opt\OrchestrANT\.venv\Lib\site-packages'
$script:ChainWheel = [pscustomobject]@{
    Path = 'C:\runtime\wheels\onnxruntime-1.30.0-cp314-cp314-win_amd64.whl'; Name = 'onnxruntime'; Version = '1.30.0'; Problem = ''
}

# The probe's JSON for a healthy venv, round-tripped like Invoke-TorchAppOrtProbe does. -Set/-Remove edit it first.
function New-VenvOrtReport {
    param([hashtable]$Set = @{}, [string[]]$Remove = @())
    $bin = { param($name, $wheel, $installed) [ordered]@{ name = "onnxruntime/capi/$name"; wheel = $wheel; installed = $installed } }
    $r = [ordered]@{
        dist      = '1.30.0'
        binaries  = @(
            (& $bin 'DirectML.dll' ('a' * 64) ('a' * 64))
            (& $bin 'onnxruntime.dll' ('b' * 64) ('b' * 64))
            (& $bin 'onnxruntime_providers_shared.dll' ('c' * 64) ('c' * 64))
            (& $bin 'onnxruntime_pybind11_state.pyd' ('d' * 64) ('d' * 64)))
        owners    = @('onnxruntime')
        providers = @('DmlExecutionProvider', 'CPUExecutionProvider')
        package   = "$script:VenvSite\onnxruntime"
        genaiDml  = $true
    }
    foreach ($k in $Set.Keys) { $r[$k] = $Set[$k] }
    foreach ($k in $Remove) { $r.Remove($k) }
    return ($r | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable)
}

Describe 'Smoke §21: the chain wheel the venv is compared against' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-SmokeOrtSuitePath $script:SmokeScript) -FunctionName 'Resolve-ChainOrtWheel')

    It 'resolves the one onnxruntime-*.whl and ignores the genai/tvm wheels beside it' {
        Invoke-InTestDir { param($dir)
            foreach ($n in 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl', 'tvm-0.25.0-cp314-cp314-win_amd64.whl') {
                Set-Content -LiteralPath (Join-Path $dir $n) 'x' -Encoding ASCII
            }
            $w = Resolve-ChainOrtWheel -WheelDir $dir
            Assert-Equal '' $w.Problem 'no problem'
            Assert-Equal 'onnxruntime' $w.Name 'PEP 503 name'
            Assert-Equal '1.30.0' $w.Version 'version from the file name'
            Assert-Equal (Join-Path $dir 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl') $w.Path 'full path'
        }
    }

    It 'reports none, two, or a missing store instead of picking one' {
        Invoke-InTestDir { param($dir)
            Assert-Match "^0 onnxruntime-\*\.whl in '.*', expected exactly 1$" (Resolve-ChainOrtWheel -WheelDir $dir).Problem 'empty store'
            foreach ($n in 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime-1.27.0-cp314-cp314-win_amd64.whl') {
                Set-Content -LiteralPath (Join-Path $dir $n) 'x' -Encoding ASCII
            }
            $two = Resolve-ChainOrtWheel -WheelDir $dir
            Assert-Match '^2 onnxruntime-' $two.Problem 'two wheels are ambiguous'
            Assert-Equal '' $two.Path 'no path handed on when ambiguous'
            Assert-Match '^0 onnxruntime-' (Resolve-ChainOrtWheel -WheelDir (Join-Path $dir 'missing')).Problem 'missing store'
            Assert-Match '^0 onnxruntime-' (Resolve-ChainOrtWheel -WheelDir '').Problem 'unset store'
        }
    }
}

Describe 'Smoke §21: venv DirectML findings' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-SmokeOrtSuitePath $script:SmokeScript) -FunctionName 'Get-TorchAppOrtFinding')

    It 'passes a healthy venv' {
        Assert-Equal 0 @(Get-TorchAppOrtFinding -Report (New-VenvOrtReport) -Aspect Dml).Count 'healthy'
    }

    It 'fails a PyPI onnxruntime (measured: plain 1.30.0 lists Azure+CPU, webgpu 1.27.0 WebGpu+CPU)' {
        foreach ($p in @(@('AzureExecutionProvider', 'CPUExecutionProvider'), @('WebGpuExecutionProvider', 'CPUExecutionProvider'))) {
            $f = @(Get-TorchAppOrtFinding -Report (New-VenvOrtReport -Set @{ providers = $p }) -Aspect Dml)
            Assert-Equal 1 $f.Count "providers $($p -join ',')"
            Assert-Match 'lacks DmlExecutionProvider \(providers: .*CPUExecutionProvider\)' $f[0]
        }
    }

    It 'fails a no-DML GenAI (measured: PyPI onnxruntime-genai 0.14.0 reports False) and a GenAI that will not import' {
        Assert-Match 'is_dml_available\(\) is not True' (Get-TorchAppOrtFinding -Report (New-VenvOrtReport -Set @{ genaiDml = $false }) -Aspect Dml)
        Assert-Match 'is_dml_available\(\) is not True' (Get-TorchAppOrtFinding -Report (New-VenvOrtReport -Remove 'genaiDml') -Aspect Dml)
        $f = @(Get-TorchAppOrtFinding -Report (New-VenvOrtReport -Set @{ genaiError = 'ImportError: DLL load failed' } -Remove 'genaiDml') -Aspect Dml)
        Assert-Equal 1 $f.Count 'one finding for a GenAI import error'
        Assert-Match 'import onnxruntime_genai failed in the venv: ImportError' $f[0]
    }

    It 'fails closed on an import error, a missing report or a failed probe' {
        Assert-Equal "import onnxruntime failed in the venv: ModuleNotFoundError: x" `
            ((Get-TorchAppOrtFinding -Report (New-VenvOrtReport -Set @{ error = 'ModuleNotFoundError: x' }) -Aspect Dml) -join '|')
        Assert-Equal 'the venv probe printed no report' ((Get-TorchAppOrtFinding -Report $null -Aspect Dml) -join '|')
        Assert-Equal 'the venv probe failed: exit 1' ((Get-TorchAppOrtFinding -Report $null -Aspect Dml -ProbeError 'exit 1') -join '|')
    }

    It 'has no lane input: the cpu, nvidia and rocm environments get the same verdict' {
        $cmd = Get-Command Get-TorchAppOrtFinding
        $laneish = @($cmd.Parameters.Keys | Where-Object { $_ -match 'Gpu|Lane|Rocm|Cuda|Nvidia|Variant' })
        Assert-Equal 0 $laneish.Count "lane parameters: $($laneish -join ',')"
        $lanes = @(
            @{ GPU_TYPE = $null; CUDA_ROOT = $null }, @{ GPU_TYPE = 'nvidia'; CUDA_ROOT = 'C:\cuda' },
            @{ GPU_TYPE = 'rocm'; CUDA_ROOT = $null; HIP_PATH = 'C:\TheRock\build' })
        foreach ($lane in $lanes) {
            Invoke-WithEnv $lane {
                Assert-Equal 0 @(Get-TorchAppOrtFinding -Report (New-VenvOrtReport) -Aspect Dml).Count "healthy on GPU_TYPE='$($lane.GPU_TYPE)'"
                $noDml = New-VenvOrtReport -Set @{ providers = @('CPUExecutionProvider') }
                Assert-Equal 1 @(Get-TorchAppOrtFinding -Report $noDml -Aspect Dml).Count "no DML on GPU_TYPE='$($lane.GPU_TYPE)'"
            }
        }
    }
}

Describe 'Smoke §21: venv chain-wheel provenance findings' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-SmokeOrtSuitePath $script:SmokeScript) -FunctionName 'Get-TorchAppOrtFinding')
    $prov = { param($Report, $Wheel = $script:ChainWheel, $Site = $script:VenvSite)
        @(Get-TorchAppOrtFinding -Report $Report -Aspect Provenance -Wheel $Wheel -VenvSitePackages $Site) }

    It 'passes the chain wheel imported from the venv, whatever spelling the site path has' {
        foreach ($site in $script:VenvSite, "$script:VenvSite\", $script:VenvSite.Replace('\', '/')) {
            Assert-Equal 0 @(& $prov (New-VenvOrtReport) $script:ChainWheel $site).Count "site '$site'"
        }
    }

    It 'catches a same-version PyPI wheel by its bytes alone (measured: PyPI ships onnxruntime 1.30.0 too)' {
        $bins = @(
            [ordered]@{ name = 'onnxruntime/capi/DirectML.dll'; wheel = 'a' * 64; installed = '' }
            [ordered]@{ name = 'onnxruntime/capi/onnxruntime_pybind11_state.pyd'; wheel = 'd' * 64; installed = 'e' * 64 })
        $f = @(& $prov (New-VenvOrtReport -Set @{ binaries = $bins }))
        Assert-Equal 2 $f.Count ($f -join ' / ')
        Assert-Equal 'onnxruntime/capi/DirectML.dll is missing from the venv' $f[0]
        Assert-Equal "onnxruntime/capi/onnxruntime_pybind11_state.pyd in the venv differs from the chain wheel's copy" $f[1]
    }

    It 'names a PyPI variant co-installed into the onnxruntime package (measured: onnxruntime-webgpu)' {
        $f = @(& $prov (New-VenvOrtReport -Set @{ owners = @('onnxruntime', 'onnxruntime-webgpu') }))
        Assert-Equal 1 $f.Count ($f -join ' / ')
        Assert-Match 'belongs to \[onnxruntime, onnxruntime-webgpu\], expected only onnxruntime' $f[0]
        Assert-Match 'belongs to \[\]' @(& $prov (New-VenvOrtReport -Set @{ owners = @() }))[0] 'no owner at all'
        Assert-Match 'belongs to \[unreadable' @(& $prov (New-VenvOrtReport -Set @{ owners = @('unreadable (TypeError: x)') }))[0]
    }

    It 'fails a version other than the chain wheel''s (the app lock''s PyPI 1.27.0)' {
        Assert-Equal "dist onnxruntime is '1.27.0', the chain wheel is 1.30.0" ((& $prov (New-VenvOrtReport -Set @{ dist = '1.27.0' })) -join '|')
    }

    It 'fails an onnxruntime imported from outside the venv' {
        $f = @(& $prov (New-VenvOrtReport -Set @{ package = 'C:\temp\cpython\Lib\site-packages\onnxruntime' }))
        Assert-Equal 1 $f.Count ($f -join ' / ')
        Assert-Match "imports from 'C:\\temp\\cpython\\Lib\\site-packages\\onnxruntime', not from the venv's" $f[0]
        Assert-Equal 1 @(& $prov (New-VenvOrtReport) $script:ChainWheel '').Count 'an empty site path never passes'
    }

    It 'fails when nothing was compared, the wheel is unusable, or the probe failed' {
        Assert-Match 'no onnxruntime/\*\.pyd was compared' ((& $prov (New-VenvOrtReport -Set @{ binaries = @() })) -join '|')
        $dllOnly = @([ordered]@{ name = 'onnxruntime/capi/onnxruntime.dll'; wheel = 'b' * 64; installed = 'b' * 64 })
        Assert-Match 'no onnxruntime/\*\.pyd was compared' ((& $prov (New-VenvOrtReport -Set @{ binaries = $dllOnly })) -join '|')
        $bad = [pscustomobject]@{ Path = ''; Name = ''; Version = ''; Problem = "2 onnxruntime-*.whl in 'C:\runtime\wheels', expected exactly 1" }
        Assert-Equal "no chain wheel to compare against: 2 onnxruntime-*.whl in 'C:\runtime\wheels', expected exactly 1" ((& $prov (New-VenvOrtReport) $bad) -join '|')
        Assert-Match 'none resolved' ((& $prov (New-VenvOrtReport) $null) -join '|')
        Assert-Match '^cannot read the chain wheel .*BadZipFile' ((& $prov (New-VenvOrtReport -Set @{ wheelError = 'BadZipFile: x' })) -join '|')
        Assert-Equal 'the venv probe failed: boom' ((Get-TorchAppOrtFinding -Report $null -Aspect Provenance -Wheel $script:ChainWheel -ProbeError 'boom') -join '|')
    }
}

Describe 'Smoke §21: the probe runner' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-SmokeOrtSuitePath $script:SmokeScript) -FunctionName 'Get-TorchAppOrtProbeSource', 'Invoke-TorchAppOrtProbe')
    # The fake records its argv, keeps a copy of the probe, prints out.txt and exits with rc.txt.
    $newFakePython = { param([string]$Dir, [string]$Out, [int]$Rc)
        Set-Content -LiteralPath (Join-Path $Dir 'python.cmd') -Encoding ASCII -Value @(
            '@echo off', '>"%~dp0args.txt" echo %*', 'copy /y "%~2" "%~dp0probe.py" >nul', 'type "%~dp0out.txt"',
            'set /p RC=<"%~dp0rc.txt"', 'exit /b %RC%')
        [System.IO.File]::WriteAllText((Join-Path $Dir 'out.txt'), $Out)
        [System.IO.File]::WriteAllText((Join-Path $Dir 'rc.txt'), "$Rc")
        return (Join-Path $Dir 'python.cmd')
    }

    It 'runs the venv python with -I, the probe and the wheel, and returns the last JSON line' {
        Invoke-InTestDir { param($dir)
            $py = & $newFakePython $dir "noise`r`n{`"dist`": `"0`"}`r`n{`"dist`": `"1.30.0`", `"owners`": [`"onnxruntime`"]}`r`n" 0
            $r = Invoke-TorchAppOrtProbe -Python $py -WheelPath 'C:\runtime\wheels\onnxruntime-1.30.0-cp314-cp314-win_amd64.whl'
            Assert-True ($r -is [hashtable]) 'a hashtable, as Get-TorchAppOrtFinding takes'
            Assert-Equal '1.30.0' $r['dist'] 'the last JSON line wins'
            Assert-Equal 'onnxruntime' ($r['owners'] -join ',') 'arrays survive'
            $argv = (Get-Content -LiteralPath (Join-Path $dir 'args.txt') -Raw).Trim() -split ' '
            Assert-Equal 3 $argv.Count ($argv -join ' ')
            Assert-Equal '-I' $argv[0] 'isolated mode: no PYTHONPATH, no script dir'
            Assert-Match 'smoke-venv-ort-[0-9a-f]{32}\.py$' $argv[1] 'the probe file'
            Assert-Equal 'C:\runtime\wheels\onnxruntime-1.30.0-cp314-cp314-win_amd64.whl' $argv[2] 'the wheel'
            Assert-False (Test-Path -LiteralPath $argv[1]) 'the probe file is removed afterwards'
            Assert-Equal (Get-TorchAppOrtProbeSource) ([System.IO.File]::ReadAllText((Join-Path $dir 'probe.py'))) 'the probe source, verbatim'
        }
    }

    It 'omits the wheel argument when there is no wheel' {
        Invoke-InTestDir { param($dir)
            $py = & $newFakePython $dir '{"dist": ""}' 0
            [void](Invoke-TorchAppOrtProbe -Python $py -WheelPath '')
            Assert-Equal 2 ((Get-Content -LiteralPath (Join-Path $dir 'args.txt') -Raw).Trim() -split ' ').Count 'just -I and the probe'
        }
    }

    It 'throws on a failing interpreter, a report-less run, or a missing interpreter' {
        Invoke-InTestDir { param($dir)
            $py = & $newFakePython $dir "Traceback`r`nImportError: DLL load failed`r`n{`"dist`": `"`"}`r`n" 1
            Assert-Throws { Invoke-TorchAppOrtProbe -Python $py } -MessagePattern '^exit 1 without a report: .*DLL load failed'
            $py = & $newFakePython $dir 'no json here' 0
            Assert-Throws { Invoke-TorchAppOrtProbe -Python $py } -MessagePattern '^exit 0 without a report: no json here'
            Assert-Throws { Invoke-TorchAppOrtProbe -Python (Join-Path $dir 'nope\python.exe') } -MessagePattern '^venv python missing at '
        }
    }

    It 'keeps the probe python free of anything that would raise before the JSON line' {
        $src = Get-TorchAppOrtProbeSource
        Assert-Match '(?s)try:\s+import onnxruntime\s' $src 'the ORT import is guarded'
        Assert-Match '(?s)try:\s+import onnxruntime_genai\s' $src 'the GenAI import is guarded'
        Assert-Match '(?s)try:\s+owners = md\.packages_distributions\(\)' $src 'the owner scan is guarded'
        Assert-Match '(?s)try:\s+with zipfile\.ZipFile\(sys\.argv\[1\]\)' $src 'the wheel read is guarded'
        Assert-Match 'is_dml_available\(\)' $src 'GenAI''s compile-time DML flag, no device'
        Assert-Match 'get_available_providers\(\)' $src 'compiled-in EPs, no device'
    }
}

Describe 'Smoke §21: wiring in Test-Container.ps1' {
    $path = Resolve-SmokeOrtSuitePath $script:SmokeScript
    $text = [System.IO.File]::ReadAllText($path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    # The branch that runs once the venv and its verifier exist; every statement in it is unconditional.
    $venvBranch = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                "$($n.Clauses[0].Item1.Extent.Text)" -match '^\$torchAppDir -and \(Test-Path \$torchAppDir\) -and \$torchAppScript$' }, $true))

    It 'asserts DML and provenance with the venv interpreter against the venv site-packages' {
        Assert-Equal 1 $venvBranch.Count 'exactly one torch-app venv branch'
        $body = $venvBranch[0].Clauses[0].Item2.Extent.Text
        Assert-Match "Invoke-TorchAppOrtProbe -Python \(Join-Path \`$torchAppDir '\.venv\\Scripts\\python\.exe'\)" $body 'the venv python, not the base one'
        Assert-Match "-VenvSitePackages \(Join-Path \`$torchAppDir '\.venv\\Lib\\site-packages'\)" $body 'the venv site'
        Assert-Match '-Aspect Dml' $body 'DML aspect'
        Assert-Match '-Aspect Provenance' $body 'provenance aspect'
    }

    It 'binds each assertion''s condition and message to the findings of its own aspect' {
        $branch = $venvBranch[0].Clauses[0].Item2
        $aspectOf = @{}
        foreach ($as in @($branch.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
            $m = [regex]::Match($as.Right.Extent.Text, '-Aspect\s+(\w+)')
            if ($m.Success) { $aspectOf[$as.Left.VariablePath.UserPath] = "$($aspectOf[$as.Left.VariablePath.UserPath])$($m.Groups[1].Value)" }
        }
        Assert-Equal 'Dml' $aspectOf['ortDmlFindings'] 'the DML findings come from -Aspect Dml, once'
        Assert-Equal 'Provenance' $aspectOf['ortWheelFindings'] 'the provenance findings come from -Aspect Provenance, once'
        Assert-Equal 2 $aspectOf.Count 'no third findings variable'
        foreach ($case in @(@{ Name = 'built with DirectML'; Aspect = 'Dml' }, @{ Name = 'is the chain wheel'; Aspect = 'Provenance' })) {
            $a = @($branch.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Assert-Test' -and $n.Extent.Text -match [regex]::Escape($case.Name) }, $true))
            Assert-Equal 1 $a.Count "one Assert-Test '$($case.Name)'"
            $els = $a[0].CommandElements
            foreach ($param in 'Condition', 'FailMessage') {
                $arg = $null
                for ($i = 0; $i -lt $els.Count; $i++) {
                    if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $param) {
                        $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] }
                    }
                }
                Assert-NotNull $arg "'$($case.Name)' has a -$param"
                $read = @($arg.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                        ForEach-Object { $_.VariablePath.UserPath } | Where-Object { $aspectOf.ContainsKey($_) } | Sort-Object -Unique)
                Assert-Equal $case.Aspect (($read | ForEach-Object { $aspectOf[$_] }) -join ',') "-$param of '$($case.Name)' reads: $($read -join ',')"
                if ($param -eq 'Condition') {
                    Assert-Match '^\{\s*\$\w+\.Count -eq 0\s*\}(\.GetNewClosure\(\))?$' $arg.Extent.Text "'$($case.Name)' passes on zero findings only"
                }
            }
        }
    }

    It 'gates the two assertions on nothing but the cross lane and the venv (every amd64 lane)' {
        $asserts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Assert-Test' -and $n.Extent.Text -match "-Name 'torch-app venv: onnxruntime" }, $true))
        Assert-Equal 2 $asserts.Count 'DML + provenance'
        foreach ($a in $asserts) {
            $conditions = @()
            for ($p = $a.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) { $conditions += @($p.Clauses | ForEach-Object { $_.Item1.Extent.Text }) }
            }
            $all = $conditions -join ' ; '
            Assert-Match 'smokeCross' $all 'inside the cross-lane skip only'
            Assert-Match '\$torchAppScript' $all 'inside the venv branch'
            Assert-False ($all -match 'gpuNvidia|GPU_TYPE|HasRocm|ExpectGpu|tensorRt|CUDA_ROOT') "lane-gated: $all"
        }
    }

    It 'floors section 21 at every unconditional assertion of the venv branch on amd64, and 0 on arm64' {
        $n = @($venvBranch[0].Clauses[0].Item2.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.PipelineAst] -and
                "$($_.PipelineElements[0].GetCommandName())" -match '^Assert-' }).Count
        Assert-Equal 4 $n 'venv dir, app verify, DML, provenance'
        $block = [regex]::Match($text, '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        $m = [regex]::Match($block, "'21'\s*=\s*@\{\s*Gpu\s*=\s*(\d+);\s*Cpu\s*=\s*(\d+);\s*Arm64\s*=\s*(\d+)\s*\}")
        Assert-True $m.Success "no '21' floor entry"
        Assert-Equal $n ([int]$m.Groups[1].Value) 'Gpu floor'
        Assert-Equal $n ([int]$m.Groups[2].Value) 'Cpu floor'
        Assert-Equal 0 ([int]$m.Groups[3].Value) 'Arm64: section 21 is payload work, skipped on cross'
    }

    It 'the app verify must print the ORT census PASS line, and its FAIL lines are the message (mutation)' {
        $text = $venvBranch[0].Clauses[0].Item2.Extent.Text
        $rhsOf = { param($name) [regex]::Match($text, '(?m)^\s*\$' + $name + ' = (.+?)\r?$').Groups[1].Value }
        Assert-Match '-File \$torchAppScript -AppDir \$torchAppDir -Mode verify 2>&1 \| Out-String$' (& $rhsOf 'torchAppVerify') 'the verify output is kept'
        $verdict = [scriptblock]::Create("param(`$torchAppVerify) $(& $rhsOf 'torchAppVerifyOk')")
        $fails = [scriptblock]::Create("param(`$torchAppVerify) $(& $rhsOf 'torchAppCensusFails')")
        $ok = "torch-app-env OK`r`nORT-CENSUS PASS: 2 chain distribution(s) from C:\runtime\wheels`r`n"
        $global:LASTEXITCODE = 0
        Assert-True (& $verdict $ok) 'imports and census both pass'
        Assert-False (& $verdict "torch-app-env OK`r`n") 'a verify without the census line fails'
        Assert-False (& $verdict "torch-app-env OK`r`nnoise ORT-CENSUS PASS`r`n") 'PASS must start its line'
        Assert-False (& $verdict "ORT-CENSUS PASS: 1`r`n") 'the census alone is not the verify'
        $global:LASTEXITCODE = 1
        Assert-False (& $verdict $ok) 'a non-zero exit fails'
        $global:LASTEXITCODE = 0
        $out = "ORT-CENSUS FAIL onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel`r`nORT-CENSUS FAIL two owners`r`nORT-CENSUS FAILED: 2`r`n"
        Assert-Equal 'onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel|two owners' (@(& $fails $out) -join '|') 'each finding, without its CR'
        $verifyAssert = @([regex]::Matches($text, '(?s)Assert-Test -Name "torch-app venv verifies.+?-FailMessage "[^\r\n]*'))
        Assert-Equal 1 $verifyAssert.Count 'one app-verify assertion'
        Assert-Match '-Condition \{ \$torchAppVerifyOk \}' $verifyAssert[0].Value 'its condition is the verdict above'
        Assert-Match '-FailMessage "[^"]*\$torchAppCensusFails' $verifyAssert[0].Value 'its message carries the census findings'
    }

    It 'compares against the store Build-TorchApp.ps1 installed the venv from' {
        $body = $venvBranch[0].Clauses[0].Item2.Extent.Text
        Assert-Match "Resolve-ChainOrtWheel -WheelDir \`$\(if \(\`$env:PYTHON_WHEELS\) \{ \`$env:PYTHON_WHEELS \} else \{ 'C:\\runtime\\wheels' \}\)" $body 'PYTHON_WHEELS, else the default'
        $torchApp = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchApp.ps1'))
        Assert-Match "\[string\]\`$WheelDir = 'C:\\runtime\\wheels'" $torchApp 'Build-TorchApp.ps1 installs from the same store'
        $merge = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-merge-builder'))
        Assert-Match 'PYTHON_WHEELS="C:\\runtime\\wheels"' $merge 'and the image names it PYTHON_WHEELS'
    }
}
