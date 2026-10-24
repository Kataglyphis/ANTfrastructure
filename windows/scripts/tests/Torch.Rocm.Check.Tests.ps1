#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Torch ROCm fixture setup is shared by installer, smoke and Dockerfile contracts.

. (Join-Path $PSScriptRoot 'Import-TorchRocmTestSetup.ps1')

function Merge-TorchRocmReportFields {
    param([hashtable]$Base, [hashtable]$Change)
    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
    foreach ($key in $Change.Keys) { $merged[$key] = $Change[$key] }
    return $merged
}

Describe 'rocm-checks\Torch.ps1: findings' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmProbeSource', 'Get-TorchRocmReportSection',
        'Get-TorchRocmExtraFinding', 'Get-TorchRocmKernelFinding', 'Get-TorchRocmFinding', 'Get-TorchRocmRocblasGpu', 'Get-TorchRocmImageFinding')
    $script:TorchRocmGpu = @('gfx1200', 'gfx1201')
    function New-TorchRocmReport { param([hashtable]$Override = @{})
        $r = @{
            torch = '2.14.0+rocm10.0.0'; hip = '7.15.26333'; rocm = '10.0.0'; arch = 'gfx1200 gfx1201'
            torchvision = '0.29.0+rocm10.0.0'; rocm_sdk = '10.0.0'; stderr = ''
            dists = @{
                'rocm' = '10.0.0'; 'rocm-sdk-core' = '10.0.0'; 'rocm-sdk-libraries' = '10.0.0'
                'rocm-sdk-device-gfx1201' = '10.0.0'; 'rocm-sdk-device-gfx1200' = '10.0.0'
            }
            ort = @{ dml = $true }
            litert = @{ version = '2.2.0'; unmet = @(); interpreter = $true; compiled_model = $true; environment = $true
                accelerator = 'C:\x\libLiteRtWebGpuAccelerator.dll'; accelerator_entry = $true }
        }
        foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
        return $r
    }

    It 'a ROCm venv for the release, with both GPUs, the chain ORT and ai-edge-litert, passes' {
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 0 $f.Count "findings: $($f -join ' | ')"
    }

    It 'the CPU torch the app lock installs is caught' {
        $cpu = New-TorchRocmReport -Override @{ torch = '2.14.0+cpu'; hip = $null; rocm = $null; torchvision = '0.29.0+cpu'; rocm_sdk = $null; arch = ''; dists = @{} }
        $f = @(Get-TorchRocmFinding -Report $cpu -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        foreach ($p in "torch is '2\.14\.0\+cpu'", 'torchvision is', 'torch\.version\.hip is empty', 'no rocm-sdk-device-', 'no compiled GPU arch') {
            Assert-Match $p $f 'CPU torch finding'
        }
    }

    It 'each single defect yields a finding' {
        $cases = @(
            @{ Release = '10.1.0'; O = @{}; P = 'rocm10\.1\.0' }
            @{ Release = '10.0.0'; O = @{ error = 'OSError: [WinError 126] amdhip64_7.dll' }; P = 'import.*failed.*WinError 126' }
            @{ Release = '10.0.0'; O = @{ hip = '' }; P = 'hip is empty' }
            @{ Release = '10.0.0'; O = @{ rocm = '10.0.1' }; P = 'torch\.version\.rocm' }
            @{ Release = '10.0.0'; O = @{ rocm_sdk = '9.9.9' }; P = 'rocm_sdk is' }
            @{ Release = '10.0.0'; O = @{ arch = 'gfx1201' }; P = 'torch was built for gfx1201, not gfx1200' }
            @{ Release = '10.0.0'; O = @{ arch = '' }; P = 'no compiled GPU arch' }
            @{ Release = ''; O = @{}; P = 'ROCM_WINDOWS_RELEASE is not set' }
        )
        foreach ($c in $cases) {
            $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport -Override $c.O) -Release $c.Release -RocmGpu $script:TorchRocmGpu) -join "`n"
            Assert-Match $c.P $f "case $($c.O | ConvertTo-Json -Compress) release '$($c.Release)'"
        }
        Assert-Match 'no report' (@(Get-TorchRocmFinding -Report $null -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join ' ') 'null report'
    }

    It 'dist defects: a missing runtime, a device wheel at the wrong version' {
        foreach ($c in @(
                @{ Drop = 'rocm-sdk-libraries'; Set = $null; P = 'rocm-sdk-libraries is' }
                @{ Drop = 'rocm-sdk-core'; Set = $null; P = 'rocm-sdk-core is' }
                @{ Drop = $null; Set = @('rocm-sdk-device-gfx1200', '10.0.1'); P = 'rocm-sdk-device-gfx1200 is' })) {
            $r = New-TorchRocmReport
            $dists = @{}
            foreach ($k in $r.dists.Keys) { if ($k -ne $c.Drop) { $dists[$k] = $r.dists[$k] } }
            if ($c.Set) { $dists[$c.Set[0]] = $c.Set[1] }
            $r.dists = $dists
            Assert-Match $c.P (@(Get-TorchRocmFinding -Report $r -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n") "dist case $($c.P)"
        }
    }

    It 'every GPU ROCm''s rocBLAS serves needs torch kernels compiled for it and its rocm-sdk device dist' {
        $r = New-TorchRocmReport
        $r.dists.Remove('rocm-sdk-device-gfx1200')
        $f = @(Get-TorchRocmFinding -Report $r -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 1 $f.Count "dropping rocm-sdk-device-gfx1200; findings: $($f -join ' | ')"
        Assert-Match "no rocm-sdk-device-gfx1200 dist: ROCm's rocBLAS serves gfx1200" $f[0] 'library kernels'
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport -Override @{ arch = 'gfx1201;gfx1100' }) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 1 $f.Count "torch without gfx1200 kernels; findings: $($f -join ' | ')"
        Assert-Match 'torch was built for gfx1201, gfx1100, not gfx1200' $f[0] 'torch kernels, any separator'
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu @('gfx1036', 'gfx1201')) -join "`n"
        Assert-Match 'no rocm-sdk-device-gfx1036 dist' $f 'a GPU rocBLAS serves: library kernels'
        Assert-Match 'not gfx1036' $f 'a GPU rocBLAS serves: torch kernels'
        Assert-Match "names no GPU" (@(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0') -join "`n") 'no rocBLAS set given'
    }

    It 'no ROCm root, a missing rocBLAS dir or one without GPUs is a finding, never a StrictMode throw that loses the others' {
        Invoke-InTestDir { param($dir)
            $r = New-TorchRocmReport -Override @{ ort = @{ error = 'import onnxruntime: ModuleNotFoundError: x' } }
            [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'empty\bin\rocblas\library'))
            foreach ($root in '', (Join-Path $dir 'none'), (Join-Path $dir 'empty')) {
                $f = @(Get-TorchRocmImageFinding -Report $r -Release '10.0.0' -RocmRoot $root 6>$null) -join "`n"
                Assert-Match 'names no GPU' $f "ROCm root '$root'"
                Assert-Match "the venv's onnxruntime: import onnxruntime" $f "ROCm root '$root': the other findings survive"
            }
            Assert-Match 'names no GPU' (@(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu $null) -join "`n") 'a $null set'
        }
    }

    It 'the script body reads the GPU set from <ROCm root>\bin\rocblas\library, one GPU or several' {
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'bin/rocblas/library/TensileLibrary_lazy_gfx1201.dat' = 'x' }
            $f = @(Get-TorchRocmImageFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmRoot $dir 6>$null)
            Assert-Equal 0 $f.Count "gfx1201 alone (a one-GPU set unwraps to a string); findings: $($f -join ' | ')"
            Write-TestFileTree -Root $dir -Files @{ 'bin/rocblas/library/TensileLibrary_lazy_gfx1036.dat' = 'x' }
            $f = @(Get-TorchRocmImageFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmRoot $dir 6>$null) -join "`n"
            Assert-Match 'no rocm-sdk-device-gfx1036 dist' $f 'a GPU rocBLAS serves that the venv lacks'
        }
    }

    It 'venv extras: each defect yields its own finding' {
        $lite = (New-TorchRocmReport).litert
        Assert-TestSingleFindingCases -Cases @(
                @{ O = @{ ort = @{ error = 'import onnxruntime: ImportError: DLL load failed' } }; P = "the venv's onnxruntime: import onnxruntime: ImportError" }
                @{ O = @{ ort = @{ dml = $false } }; P = 'no DmlExecutionProvider' }
                @{ O = @{ litert = @{ error = 'import ai_edge_litert.interpreter: ModuleNotFoundError: No module named ''ai_edge_litert''' } }; P = 'ai-edge-litert: import ai_edge_litert' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ interpreter = $false }) }; P = 'has no Interpreter' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ compiled_model = $false }) }; P = 'has no CompiledModel or no Environment' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ environment = $false }) }; P = 'has no CompiledModel or no Environment' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ accelerator = '' }) }; P = 'ships no libLiteRtWebGpuAccelerator\.dll' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ accelerator_entry = $false }) }; P = 'without its LiteRtAcceleratorImpl export' }
                @{ O = @{ litert = (Merge-TorchRocmReportFields $lite @{ unmet = @('ml_dtypes') }) }; P = 'ai-edge-litert is installed --no-deps and the venv lacks its requirement ml_dtypes' }) -Exercise {
            param($case)
            Get-TorchRocmFinding -Report (New-TorchRocmReport -Override $case.O) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu
        } -Message 'venv extras'
    }

    It 'a report without the ORT or LiteRT section, or a failed torch import, still reports the extras' {
        $old = New-TorchRocmReport
        $old.Remove('ort'); $old.Remove('litert')
        $f = @(Get-TorchRocmFinding -Report $old -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        Assert-Match "the venv's onnxruntime lists no DmlExecutionProvider" $f 'no ORT section'
        Assert-Match 'ai-edge-litert: ai_edge_litert\.interpreter has no Interpreter' $f 'no LiteRT section'
        $broken = New-TorchRocmReport -Override @{ error = 'ImportError: torch'; ort = @{ error = 'import onnxruntime: ModuleNotFoundError: x' } }
        $f = @(Get-TorchRocmFinding -Report $broken -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        Assert-Match 'importing torch/torchvision/rocm_sdk failed' $f 'torch finding'
        Assert-Match "the venv's onnxruntime: import onnxruntime" $f 'ORT finding survives the torch return'
    }

    It 'the whole script reports a missing app venv as one finding instead of passing' {
        Invoke-InTestDir { param($dir)
            $check = (Get-TestScriptAst -ScriptPath $script:TorchRocmCheck).Extent.File
            $out = @(Invoke-WithEnv @{ TORCH_APP_DIR = $dir; ROCM_WINDOWS_RELEASE = '10.0.0' } { & $check 6>$null })
            Assert-Equal 1 $out.Count "findings: $($out -join ' / ')"
            Assert-Match '^Torch: app venv python not found at ' $out[0] 'missing venv finding'
        }
    }

    It 'needs no GPU: no torch.cuda, no plugin EP; the LiteRT accelerator load is the only native step' {
        $src = Get-TorchRocmProbeSource
        Assert-False ($src -match 'torch\.cuda') 'probe source calls torch.cuda (it needs a GPU)'
        Assert-Match 'torch\._C\._cuda_getArchFlags\(\)' $src 'the compiled arch list: build-time data, no GPU needed'
        Assert-False ($src -match 'onnxruntime_ep_webgpu|register_execution_provider_library') 'no prebuilt plugin EP (the chain ORT carries WebGPU; rocm-checks\OrtWebGpu.ps1 checks it)'
        Assert-Match '"dml"\] = "DmlExecutionProvider" in ort\.get_available_providers\(\)' $src 'the chain wheel''s DML EP is read'
        Assert-Match 'ctypes\.WinDLL\(path\), "LiteRtAcceleratorImpl"' $src 'accelerator loaded and its entry export resolved'
        $ast = (Get-TestScriptAst -ScriptPath $script:TorchRocmCheck)
        Assert-Null $ast.ParamBlock 'rocm-checks scripts take no parameters (Test-RocmImage.ps1 runs them bare)'
    }
}

Describe 'rocm-checks\Torch.ps1: the GPUs ROCm''s rocBLAS serves' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmRocblasGpu')

    It 'reads them from TensileLibrary_lazy_<gfx>.dat only, sorted and unique' {
        Invoke-InTestDir { param($dir)
            foreach ($n in 'TensileLibrary_lazy_gfx1201.dat', 'TensileLibrary_lazy_gfx1200.dat', 'TensileLibrary_lazy_gfx1201.dat.zlib',
                'TensileLibrary_lazy_gfx1036.dat.zlib', 'TensileLibrary_lazy_gfx1030.datx', 'TensileLibrary_gfx1100.dat', 'Kernels.so-000-gfx1102.hsaco') {
                [System.IO.File]::WriteAllText((Join-Path $dir $n), 'x')
            }
            Assert-Equal 'gfx1200,gfx1201' ((Get-TorchRocmRocblasGpu -RocblasLibraryDir $dir) -join ',') 'GPU set'
        }
    }

    It 'a missing or empty directory is an empty set (the finding then says so)' {
        Invoke-InTestDir { param($dir)
            Assert-Equal 0 @(Get-TorchRocmRocblasGpu -RocblasLibraryDir $dir).Count 'empty dir'
            Assert-Equal 0 @(Get-TorchRocmRocblasGpu -RocblasLibraryDir (Join-Path $dir 'nope')).Count 'missing dir'
        }
    }
}

Describe 'rocm-checks\Torch.ps1: the one venv probe, shared with Install-TorchRocm' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmProbeSource', 'Get-TorchRocmVenvReport')
    # A stand-in interpreter: keeps a copy of the probe it was handed, prints $Lines, exits $Rc.
    function New-TorchRocmFakePython { param([string]$Dir, [string[]]$Lines, [int]$Rc = 0)
        $cmd = Join-Path $Dir "python-$([guid]::NewGuid().ToString('N')).cmd"
        $body = @('@echo off', "echo %1> ""$Dir\probe-path.txt""", "copy /y %1 ""$Dir\probe-copy.py"" >nul") +
            @($Lines | ForEach-Object { "echo $_" }) + @("exit /b $Rc")
        Set-Content -LiteralPath $cmd -Value $body -Encoding ascii
        return $cmd
    }
    # An installer run up to its first refusal: fake venv python, pins from versions.env, a check that reports $Venv.
    function Invoke-TorchRocmInstallerTo { param([string]$Dir, [string]$Venv, [hashtable]$Env = @{}, [string]$WheelDir = '')
        if (-not $WheelDir) { $WheelDir = New-TorchRocmBuiltWheelDir -Dir $Dir }
        $app = Join-Path $Dir 'app'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $app '.venv\Scripts'))
        [System.IO.File]::WriteAllBytes((Join-Path $app '.venv\Scripts\python.exe'), [byte[]]@())
        $fake = Join-Path $Dir 'FakeCheck.ps1'
        $real = (Get-TestScriptAst -ScriptPath $script:TorchRocmCheck).Extent.File
        [System.IO.File]::WriteAllLines($fake, [string[]]@(". '$real'", "function Get-TorchRocmVenvReport { param(`$Python) @{ venv = $Venv } }",
                "if (`$MyInvocation.InvocationName -eq '.') { return }", "'Torch: the fake check ran as a check'"))
        $pins = Get-TorchRocmTestPin
        # A dead proxy: a regression that reaches the downloads fails fast instead of pulling ~2 GB from AMD.
        $vars = @{ GPU_TYPE = 'rocm'; TORCH_ROCM = $null; HIP_PATH = $null; ROCM_PATH = $null
            HTTPS_PROXY = 'http://127.0.0.1:9'; HTTP_PROXY = 'http://127.0.0.1:9'; NO_PROXY = $null }
        foreach ($k in @($pins.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' -or $_ -eq 'ROCM_WINDOWS_RELEASE' })) { $vars[$k] = $pins[$k] }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $installer = (Get-TestScriptAst -ScriptPath $script:TorchRocmScript).Extent.File
        $out = Invoke-WithEnv $vars {
            & pwsh -NoProfile -NonInteractive -File $installer -TorchRocm 1 -AppDir $app -WheelDir $WheelDir -WheelCache (Join-Path $Dir 'cache') -CheckScript $fake 2>&1 | Out-String
        }
        return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = $out; CacheMade = (Test-Path (Join-Path $Dir 'cache')) }
    }
    # A refusal: a non-zero exit, the named reason in the output, and no wheel cache created.
    function Assert-TorchRocmInstallRefused { param([object]$Result, [string]$Pattern, [string]$Why)
        Assert-True ($Result.Rc -ne 0) "exit code $($Result.Rc); output: $($Result.Out)"
        Assert-Match $Pattern $Result.Out $Why
        Assert-False $Result.CacheMade 'refused before any download'
    }

    It 'returns the last JSON line as a hashtable, ran the probe source and removed its file' {
        Invoke-InTestDir { param($dir)
            $py = New-TorchRocmFakePython -Dir $dir -Lines @('noise', '{"n": 1}', '{"venv": {"tag": "cp314"}, "n": 2}', 'tail noise')
            $report = Get-TorchRocmVenvReport -Python $py
            Assert-Equal 2 $report['n'] 'the last JSON line wins'
            Assert-Equal 'cp314' $report['venv']['tag'] 'nested venv facts'
            Assert-Equal (Get-TorchRocmProbeSource).Trim() ([System.IO.File]::ReadAllText((Join-Path $dir 'probe-copy.py'))).Trim() 'the probe source ran'
            $probe = ([System.IO.File]::ReadAllText((Join-Path $dir 'probe-path.txt'))).Trim()
            Assert-False (Test-Path -LiteralPath $probe) "probe file left behind: $probe"
        }
    }

    It 'a probe that exits non-zero or prints no report throws' {
        Invoke-InTestDir { param($dir)
            foreach ($case in @(@{ Lines = @('{"venv": {}}'); Rc = 3; P = 'exited 3' }, @{ Lines = @('no json here'); Rc = 0; P = 'without a report' })) {
                $py = New-TorchRocmFakePython -Dir $dir -Lines $case.Lines -Rc $case.Rc
                Assert-Throws { Get-TorchRocmVenvReport -Python $py } "rc $($case.Rc)" -MessagePattern $case.P
            }
        }
    }

    It 'the probe reads the venv facts, the chain onnxruntime''s RECORD digest included, before any import' {
        $src = Get-TorchRocmProbeSource
        $facts = $src.IndexOf('report = {"venv"')
        Assert-True ($facts -ge 0 -and $facts -lt $src.IndexOf('import torch') -and $facts -lt $src.IndexOf('import onnxruntime')) 'venv facts come first'
        foreach ($p in 'Py_GIL_DISABLED', '"torch": version\("torch"\)', '"torchvision": version\("torchvision"\)', '"setuptools": version\("setuptools"\)',
            '"onnxruntime_record": record_digest\("onnxruntime"\)') {
            Assert-Match $p $src 'venv fact'
        }
    }

    It 'dot-sourcing the check defines the runner and runs no check' {
        Invoke-InTestDir { param($dir)
            $check = (Get-TestScriptAst -ScriptPath $script:TorchRocmCheck).Extent.File
            $cmd = ". '$check'; if (Get-Command Get-TorchRocmVenvReport -ErrorAction SilentlyContinue) { 'RUNNER' }"
            $out = @(Invoke-WithEnv @{ TORCH_APP_DIR = $dir } { & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 })
            Assert-Equal 'RUNNER' ($out -join ' | ') 'dot-source output (a finding here means the check ran)'
        }
    }

    It 'Install-TorchRocm checks the wheels against the check''s venv report, before any download' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv "@{ tag = 'cp313'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }"
            Assert-TorchRocmInstallRefused $r 'the app venv runs cp313' 'the report''s venv facts reached the wheel check'
        }
    }

    It 'Install-TorchRocm refuses, before any download, a missing source-built wheel directory' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv "@{ tag = '$($script:TorchRocmVenvTag)'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }" -WheelDir (Join-Path $dir 'nowhere')
            Assert-TorchRocmInstallRefused $r 'no source-built wheels at' 'the torch-rocm-wheels mount is required'
        }
    }

    It 'Install-TorchRocm refuses, before any download, a rocBLAS GPU the device pins miss, and a missing ROCm root' {
        Invoke-InTestDir { param($dir)
            $venv = "@{ tag = '$($script:TorchRocmVenvTag)'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0'; onnxruntime_record = 'x' }"
            $lib = Join-Path $dir 'rocm\bin\rocblas\library'
            New-Item -ItemType Directory -Force -Path $lib | Out-Null
            foreach ($gfx in 'gfx1036', 'gfx1200', 'gfx1201') { [System.IO.File]::WriteAllText((Join-Path $lib "TensileLibrary_lazy_$gfx.dat"), 'x') }
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv $venv -Env @{ HIP_PATH = (Join-Path $dir 'rocm') }
            Assert-TorchRocmInstallRefused $r "rocBLAS serves gfx1036, the device pins cover only gfx1201, gfx1200" 'coverage refusal'
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv $venv
            Assert-TorchRocmInstallRefused $r 'neither HIP_PATH nor ROCM_PATH is set' 'no ROCm root'
        }
    }
}

