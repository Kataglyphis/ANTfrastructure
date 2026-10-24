#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The smoke and dependency contracts run without building ORT or a GPU.

. (Join-Path $PSScriptRoot 'Import-OrtWebGpuTestModules.ps1')

$script:OrtWebGpuCheck = 'windows\scripts\build\rocm-checks\OrtWebGpu.ps1'
$script:OrtWebGpuDepsJson = 'docs\deps\deps.json'

function Get-OrtWebGpuLicenseRowsByPin {
    param([string]$Path)
    $doc = [IO.File]::ReadAllText((Resolve-PathFromRoot -Path $Path -Root (Get-RepoRoot))) | ConvertFrom-Json -AsHashtable
    $rows = @{}
    foreach ($subsection in @($doc['sections'] | Where-Object { $_['title'] -eq 'Windows Image' } | ForEach-Object { $_['subsections'] })) {
        foreach ($entry in @($subsection['entries'] | Where-Object { $_['spdx'] -and $_['var'] })) {
            if (-not $rows.ContainsKey($entry['var'])) { $rows[$entry['var']] = [System.Collections.Generic.List[object]]::new() }
            $rows[$entry['var']].Add($entry)
        }
    }
    return $rows
}

Describe 'rocm-checks\OrtWebGpu.ps1: the spike mode, the DXC DLLs and each interpreter' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtWebGpuCheck -FunctionName 'Read-OrtWebGpuMarker', 'Get-OrtWebGpuDxcKey',
        'Get-OrtWebGpuRetiredDxcDll', 'Get-OrtWebGpuMarkerFinding', 'Test-OrtWebGpuOutcome', 'Get-OrtWebGpuProbeSource',
        'Get-OrtWebGpuDxcFinding', 'Get-OrtWebGpuGenaiFinding', 'Get-OrtWebGpuInterpreterFinding')
    function Set-OrtWebGpuFixtureFile([string]$Dir, [string]$RelativePath, [string]$Content) {
        [IO.File]::WriteAllText((Join-Path $Dir $RelativePath), $Content)
    }
    # A spike-on ORT root: bin\ with dxcompiler.dll and the licence, and the marker naming its hash.
    function New-OrtWebGpuTestRoot([string]$Dir, [string]$Mode = '1') {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'bin'), (Join-Path $Dir 'licenses\directx-shader-compiler'))
        $lines = @('# test', "ORT_WEBGPU=$Mode")
        if ($Mode -eq '1') {
            Set-OrtWebGpuFixtureFile -Dir $Dir -RelativePath 'bin\dxcompiler.dll' -Content 'dxcompiler.dll'
            Set-OrtWebGpuFixtureFile -Dir $Dir -RelativePath 'licenses\directx-shader-compiler\LICENSE-MS.txt' -Content 'ms'
            $lines += "DXCOMPILER_SHA256=$((Get-FileHash (Join-Path $Dir 'bin\dxcompiler.dll')).Hash.ToLowerInvariant())"
        }
        [System.IO.File]::WriteAllLines((Join-Path $Dir 'ROCM-FEATURES.txt'), [string[]]$lines)
        return Read-OrtWebGpuMarker -Path (Join-Path $Dir 'ROCM-FEATURES.txt')
    }
    function New-OrtWebGpuReport([hashtable]$Marker, [hashtable]$Override = @{}) {
        $r = @{ providers = @('WebGpuExecutionProvider', 'DmlExecutionProvider', 'CPUExecutionProvider'); capi = 'C:\v\Lib\site-packages\onnxruntime\capi'
            session = 'fell back to [''CPUExecutionProvider'']: webgpu_context.cc:69 Failed to get a WebGPU adapter: No supported adapters'
            dlls = @{ 'dxcompiler.dll' = @{ sha256 = $Marker['DXCOMPILER_SHA256']; entry = $true } }
            genai_ort = 'c:\V\lib\site-packages\onnxruntime\capi\onnxruntime.dll'; genai_session = 'RuntimeError: Failed to get a WebGPU adapter: No supported adapters' }
        foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
        return $r
    }

    It 'a spike image passes, and each marker defect is its own finding' {
        Invoke-InTestDir { param($dir)
            $m = New-OrtWebGpuTestRoot -Dir $dir
            $grade = { param($Marker, $Expect) @(Get-OrtWebGpuMarkerFinding -Marker $Marker -MarkerPath 'm' -Expect $Expect -OrtRoot $dir) }
            Assert-Equal 0 @(& $grade $m '1').Count "healthy: $((& $grade $m '1') -join ' | ')"
            Assert-Match 'missing: the rocm-lane ORT build writes it' ((& $grade $null '1') -join '') 'no marker'
            Assert-Match 'cannot be graded' ((& $grade $m '') -join '') 'no EXPECT_ROCM_SPIKES'
            Assert-Match 'ORT_WEBGPU=1, EXPECT_ROCM_SPIKES=0: an onnx stage from the other spike mode' ((& $grade $m '0') -join '') 'stale parent'
            Set-OrtWebGpuFixtureFile -Dir $dir -RelativePath 'bin\dxil.dll' -Content 'leftover'
            Assert-Match 'bin\\dxil\.dll ships, but nothing loads it since ORT v1\.31\.0' ((& $grade $m '1') -join '') 'a leftover dxil.dll'
            Remove-Item (Join-Path $dir 'bin\dxil.dll')
            Set-OrtWebGpuFixtureFile -Dir $dir -RelativePath 'bin\dxcompiler.dll' -Content 'swapped'
            Assert-Match 'bin\\dxcompiler\.dll is [0-9a-f]{64}, the build staged' ((& $grade $m '1') -join '') 'other bytes'
            Remove-Item (Join-Path $dir 'bin\dxcompiler.dll'), (Join-Path $dir 'licenses\directx-shader-compiler\LICENSE-MS.txt')
            $f = (& $grade $m '1') -join "`n"
            Assert-Match 'dxcompiler\.dll missing beside onnxruntime\.dll' $f 'missing DLL'
            Assert-Match 'licence texts are missing' $f 'missing licence'
            $m['DXCOMPILER_SHA256'] = ''
            Assert-Match 'DXCOMPILER_SHA256 is '''', not a SHA256' ((& $grade $m '1') -join '') 'empty hash in the marker'
        }
    }

    It 'a -NoRocmSpikes image passes with no DXC beside ORT, and is flagged when a WebGPU leftover ships' {
        Invoke-InTestDir { param($dir)
            $m = New-OrtWebGpuTestRoot -Dir $dir -Mode '0'
            Assert-Equal 0 @(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '0' -OrtRoot $dir).Count 'healthy'
            Assert-Match 'EXPECT_ROCM_SPIKES=1' (@(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '1' -OrtRoot $dir) -join '') 'spike asked, none built'
            Set-OrtWebGpuFixtureFile -Dir $dir -RelativePath 'bin\dxcompiler.dll' -Content 'x'
            Set-OrtWebGpuFixtureFile -Dir $dir -RelativePath 'bin\dxil.dll' -Content 'x'
            $f = @(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '0' -OrtRoot $dir) -join "`n"
            Assert-Match 'dxcompiler\.dll ships although ORT_WEBGPU=0' $f 'leftover'
            Assert-Match 'dxil\.dll ships, but nothing loads it' $f 'leftover dxil.dll'
        }
    }

    It 'a session may use WebGPU or fail for want of an adapter; nothing else passes' {
        foreach ($ok in 'webgpu', 'created', 'RuntimeError: ... Failed to get a WebGPU adapter: No supported adapters', 'fell back to [x]: Failed to get a WebGPU adapter.') {
            Assert-True (Test-OrtWebGpuOutcome $ok) "accepted: $ok"
        }
        foreach ($bad in '', 'fell back to [''CPUExecutionProvider'']: LoadLibrary failed with error 126 "dxcompiler.dll"', 'RuntimeError: WebGPU execution provider is not supported in this build',
            'Failed to get a WebGPU device.', 'failed to get a webgpu adapter') {
            Assert-False (Test-OrtWebGpuOutcome $bad) "refused: $bad"
        }
    }

    It 'an interpreter on the spike image passes; each defect is its own finding' {
        $m = @{ ORT_WEBGPU = '1'; DXCOMPILER_SHA256 = 'c' * 64 }
        Assert-Equal 0 @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report (New-OrtWebGpuReport $m) -WebGpu $true -Marker $m).Count 'healthy (paths compared case-insensitively)'
        $dll = { param($Name, $Sha, $Entry) $d = (New-OrtWebGpuReport $m).dlls; $d[$Name] = @{ sha256 = $Sha; entry = $Entry }; $d }
        Assert-TestSingleFindingCases -Cases @(
                @{ O = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider') }; P = 'no WebGpuExecutionProvider' }
                @{ O = @{ session = 'RuntimeError: D3D12CreateDevice failed' }; P = 'session failed, and not for want of an adapter: RuntimeError: D3D12' }
                @{ O = @{ dlls = (& $dll 'dxcompiler.dll' ('e' * 64) $true) }; P = 'capi\\dxcompiler\.dll is e{64}, the build staged c{64}' }
                @{ O = @{ dlls = (& $dll 'dxcompiler.dll' ('c' * 64) $false) }; P = 'capi\\dxcompiler\.dll does not load' }
                @{ O = @{ dlls = @{} }; P = 'capi has no dxcompiler\.dll' }
                @{ O = @{ dlls = (& $dll 'dxil.dll' ('d' * 64) $true) }; P = 'capi carries dxil\.dll, which nothing loads since ORT v1\.31\.0' }
                @{ O = @{ genai_error = 'ImportError: onnxruntime-genai.dll' }; P = 'import onnxruntime_genai failed' }
                @{ O = @{ genai_ort = 'C:\Windows\System32\onnxruntime.dll' }; P = 'GenAI runs on ''C:\\Windows\\System32\\onnxruntime\.dll''' }
                @{ O = @{ genai_session = 'RuntimeError: WebGPU execution provider is not supported in this build' }; P = 'GenAI''s WebGPU model failed' }) -Exercise {
            param($case)
            Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report (New-OrtWebGpuReport $m $case.O) -WebGpu $true -Marker $m
        } -Message 'interpreter'
        Assert-Match 'import onnxruntime failed' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report @{ error = 'x' } -WebGpu $true -Marker $m) 'no ORT'
        Assert-Match 'the probe exited 1' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report 'the probe exited 1 without a report' -WebGpu $true -Marker $m) 'probe failure'
        Assert-Match 'no report' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report $null -WebGpu $true -Marker $m) 'null report'
    }

    It 'without the spike, a listed WebGPU EP or a DXC dll in capi is a finding' {
        $m = @{ ORT_WEBGPU = '0' }
        $plain = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider'); capi = 'C:\v'; dlls = @{} }
        Assert-Equal 0 @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report $plain -WebGpu $false -Marker $m).Count 'healthy'
        $plain.providers = @('WebGpuExecutionProvider', 'CPUExecutionProvider'); $plain.dlls = @{ 'dxil.dll' = @{ sha256 = 'x'; entry = $true } }
        $f = @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report $plain -WebGpu $false -Marker $m) -join "`n"
        Assert-Match 'lists WebGpuExecutionProvider although the marker says ORT_WEBGPU=0' $f 'listed'
        Assert-Match 'capi carries dxil\.dll without the WebGPU EP' $f 'leftover'
    }

    It 'the probe: the identity model is the smoke suite''s, stdout is captured around the fallback, dxcompiler loads first, GenAI asks for webgpu' {
        $src = Get-OrtWebGpuProbeSource
        Assert-Match "bytes\.fromhex\(`"$(Get-IdentityOnnxHex)`"\)" $src 'the same 63-byte Identity model'
        Assert-Match 'contextlib\.redirect_stdout\(printed\)' $src 'the fallback''s printed EP error is captured'
        Assert-True ($src.IndexOf('"dxcompiler.dll", "dxil.dll"') -gt $src.IndexOf('og.Model(og.Config(model_dir))')) 'DXC loads last, dxcompiler first (the one Dawn loads; dxil.dll only to catch a leftover)'
        Assert-Match '"provider_options": \[\{"webgpu": \{\}\}\]' $src 'GenAI asks for its webgpu provider'
        Assert-False ($src -match 'ALLOW_SOFTWARE|forceFallback|dawnBackendType|register_execution_provider_library') 'no adapter forcing, no plugin EP'
        $ast = (Get-TestScriptAst -ScriptPath $script:OrtWebGpuCheck)
        Assert-Null $ast.ParamBlock 'rocm-checks scripts take no parameters (Test-RocmImage.ps1 runs them bare)'
    }

    It 'the whole script: no marker is one finding, a stale spike mode stops before any probe, a gradable one probes base AND venv' {
        Invoke-InTestScriptDir -ScriptPath $script:OrtWebGpuCheck -Body { param($dir, $check)
            $shim = Join-Path $dir 'shim'
            $run = { @(Invoke-WithEnv @{ ONNX_ROOT = $dir; EXPECT_ROCM_SPIKES = '1'; TORCH_APP_DIR = $dir; PATH = "$shim;$env:SystemRoot\System32" } { & $check 6>$null }) }
            $out = @(& $run)
            Assert-Equal 1 $out.Count "no marker: $($out -join ' / ')"
            Assert-Match 'ROCM-FEATURES\.txt missing' $out[0] 'no marker'
            [void](New-OrtWebGpuTestRoot -Dir $dir -Mode '0')
            [void](New-Item -ItemType Directory -Path $shim)
            [System.IO.File]::WriteAllText((Join-Path $shim 'python.cmd'), "@echo {`"error`": `"base shim`"}`r`n")
            $out = @(& $run)
            Assert-Equal 1 $out.Count "stale: $($out -join ' / ')"
            Assert-Match 'ORT_WEBGPU=0, EXPECT_ROCM_SPIKES=1' $out[0] 'stale mode, no python probed'
            [void](New-OrtWebGpuTestRoot -Dir $dir -Mode '1')
            & (Get-OrtWebGpuTestPython) -m venv --without-pip (Join-Path $dir '.venv') | Out-Null
            Assert-Equal 0 $LASTEXITCODE 'a real venv for the app interpreter'
            $out = @(& $run)
            Assert-Equal 2 $out.Count "gradable: $($out -join ' / ')"
            Assert-Match '^OrtWebGpu \[base\]: import onnxruntime failed: base shim$' $out[0] 'the base python on PATH is probed'
            Assert-Match '^OrtWebGpu \[venv\]: import onnxruntime failed: ModuleNotFoundError' $out[1] 'the app venv is probed with the real probe source'
        }
    }
}

Describe 'rocm-checks\OrtWebGpu.ps1: shared Python JSON transport' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtWebGpuCheck -FunctionName 'Get-OrtWebGpuProbeSource', 'Invoke-OrtWebGpuProbe', 'Get-OrtWebGpuInterpreterFinding')

    function Invoke-OrtWebGpuProbeFixture {
        param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][scriptblock]$Body)
        Invoke-WithTestNativeCommand -Name Invoke-OrtWebGpuFixturePython -FixtureState $State -Implementation {
            param($state, $argumentList)
            $state.Args = @($argumentList)
            $state.Source = [IO.File]::ReadAllText($state.Args[0])
            $state.Lines
        } -Body $Body
    }

    function Assert-OrtWebGpuProbeFailure {
        param($State, [hashtable]$Case)
        $State.Code = $Case.Code
        $State.Lines = $Case.Line
        $report = Invoke-OrtWebGpuProbe -Python 'Invoke-OrtWebGpuFixturePython' -WebGpu $Case.WebGpu
        Assert-Match $Case.ProbePattern $report $Case.ProbeMessage
        Assert-Match $Case.FindingPattern (Get-OrtWebGpuInterpreterFinding -Label $Case.Label -Report $report -WebGpu $Case.WebGpu) $Case.FindingMessage
    }

    It 'uses the shared transport for both modes and preserves failed probes as findings' {
        $state = [pscustomobject]@{ Code = 0; Lines = @('diagnostic', '{"python":"fixture"}'); Calls = [Collections.Generic.List[object]]::new(); Args = @(); Source = '' }
        Invoke-OrtWebGpuProbeFixture -State $state -Body {
            param($state)
            $report = Invoke-OrtWebGpuProbe -Python 'Invoke-OrtWebGpuFixturePython' -WebGpu $true
            Assert-Equal 'fixture' $report.python 'the shared transport parses the report'
            Assert-Equal 2 $state.Args.Count 'the helper receives the script path and mode'
            Assert-Match '^rocm-ort-webgpu-.+\.py$' (Split-Path $state.Args[0] -Leaf) 'the helper owns its temporary source file'
            Assert-Equal 'webgpu' $state.Args[1] 'WebGPU mode reaches Python'
            Assert-Equal (Get-OrtWebGpuProbeSource) $state.Source 'the existing feature probe is preserved'

            $state.Args = @()
            $null = Invoke-OrtWebGpuProbe -Python 'Invoke-OrtWebGpuFixturePython' -WebGpu $false
            Assert-Equal 'plain' $state.Args[1] 'plain mode reaches Python'

            Assert-OrtWebGpuProbeFailure -State $state -Case @{
                Code = 7; Line = @('diagnostic', '{"python":"failed"}'); WebGpu = $true; Label = 'base'
                ProbePattern = 'probe failed: probe exit 7 without a report:.*failed'; FindingPattern = '^OrtWebGpu \[base\]: probe failed:'
                ProbeMessage = 'a nonzero interpreter cannot supply a passing JSON report'; FindingMessage = 'the failure remains a caller finding'
            }
            Assert-OrtWebGpuProbeFailure -State $state -Case @{
                Code = 0; Line = @('{malformed'); WebGpu = $false; Label = 'venv'
                ProbePattern = '^probe failed:'; FindingPattern = '^OrtWebGpu \[venv\]: probe failed:'
                ProbeMessage = 'malformed JSON remains a failed probe'; FindingMessage = 'the check runner can aggregate it'
            }
        }
    }
}

Describe 'deps.json: what the WebGPU spike ships beside and inside the chain ORT' {
    It 'names the DXC compiler and Dawn/Tint in Windows rows with an spdx id, versioned by the ORT_WEBGPU_WINDOWS_* pins' {
        $byVar = Get-OrtWebGpuLicenseRowsByPin -Path $script:OrtWebGpuDepsJson
        $pins = Get-OrtWebGpuTestPin
        foreach ($c in @(
                @{ Var = 'ORT_WEBGPU_WINDOWS_DXC_VERSION'; Name = @('dxcompiler.dll', 'onnxruntime'); Spdx = '^NCSA AND LicenseRef-Proprietary-EULA$' }
                @{ Var = 'ORT_WEBGPU_WINDOWS_DAWN_VERSION'; Name = @('Dawn', 'Tint', 'onnxruntime.dll'); Spdx = '^BSD-3-Clause\b' })) {
            Assert-True $pins.Contains($c.Var) "$($c.Var) is a versions.env key"
            $hit = @(if ($byVar.ContainsKey($c.Var)) { $byVar[$c.Var] })
            Assert-Equal 1 $hit.Count "Windows rows with an spdx id versioned by $($c.Var)"
            foreach ($n in $c.Name) { Assert-True ("$($hit[0]['name'])".Contains($n)) "the $($c.Var) row names $n" }
            Assert-Match $c.Spdx "$($hit[0]['spdx'])" "$($c.Var) spdx"
        }
    }
}
