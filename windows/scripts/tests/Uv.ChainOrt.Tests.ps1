#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Sync-UvChainOnnxRuntime: inside our images a synced venv ends on the chain ORT wheels or throws; outside only a notice.
# NOT covered: a real interpreter or census run (seams; test-uv-chain-ort.sh runs both on Linux), real uv.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking

# A venv dir with a Scripts\python.exe, and a store holding two chain ORT wheels beside a non-ORT one.
function script:New-ChainOrtFixture {
    param([Parameter(Mandatory)][string]$Dir, [switch]$NoOrtWheel)
    $venv = Join-Path $Dir 'venv'
    New-Item -ItemType Directory -Force -Path (Join-Path $venv 'Scripts') | Out-Null
    Set-Content -LiteralPath (Join-Path $venv 'Scripts\python.exe') 'x' -Encoding ASCII
    $store = Join-Path $Dir 'store'
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $names = @('tvm-0.25.0-cp314-cp314-win_amd64.whl')
    if (-not $NoOrtWheel) {
        $names += 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl', 'onnxruntime_extensions-0.14.0-cp39-abi3-win_amd64.whl'
    }
    foreach ($n in $names) { Set-Content -LiteralPath (Join-Path $store $n) 'x' -Encoding ASCII }
    return [pscustomobject]@{ Venv = $venv; Store = $store }
}

# Runs the reconcile with scripted census answers; returns what uv was asked, what was logged, and UV_NO_SYNC.
# -ViaSync goes through Sync-UvProjectDependencies instead, with the REAL interpreter runner.
function script:Invoke-ChainOrtCase {
    param(
        [Parameter(Mandatory)][pscustomobject]$Fixture,
        [AllowEmptyString()][string]$Store,
        [string[]]$Listed = @('ORT-CENSUS PURGE onnxruntime', 'ORT-CENSUS PURGE onnxruntime-directml', 'ORT-CENSUS PURGE onnxruntime-genai'),
        [int]$CheckExit = 0,
        [int]$ImportExit = 0,
        [string]$Abi = 'cp314',
        [int]$UnownedExit = 0,
        [switch]$FailInstall,
        [switch]$ViaSync
    )
    $state = [pscustomobject]@{ Uv = [System.Collections.Generic.List[string]]::new(); Log = [System.Collections.Generic.List[string]]::new(); Error = ''; NoSync = '' }
    $runner = {
        param($exe, $arguments)
        $state.Uv.Add(($arguments -join ' '))
        if ($FailInstall -and $arguments[1] -eq 'install') { throw 'uv: the wheel is not supported on this platform' }
    }.GetNewClosure()
    $python = {
        param($exe, $arguments)
        if ($arguments -contains '--purge-list') { return [pscustomobject]@{ ExitCode = 0; Output = $Listed } }
        if ($arguments[-1] -match 'find_spec') { return [pscustomobject]@{ ExitCode = $UnownedExit; Output = @($(if ($UnownedExit) { 'onnxruntime' } else { '' })) } }
        if ($arguments[-1] -match 'Py_GIL_DISABLED') { return [pscustomobject]@{ ExitCode = 0; Output = @($Abi) } }
        if ($arguments -contains '-c') { return [pscustomobject]@{ ExitCode = $ImportExit; Output = @('3.13.15', 'ImportError: DLL load failed while importing onnxruntime_pybind11_state') } }
        $verdict = if ($CheckExit -eq 0) { 'ORT-CENSUS PASS: 2 chain distribution(s)' } else { 'ORT-CENSUS FAIL onnxruntime-directml 1.24.4 is not a chain wheel' }
        return [pscustomobject]@{ ExitCode = $CheckExit; Output = @($verdict) }
    }.GetNewClosure()
    $log = { param($m) $state.Log.Add("$m") }.GetNewClosure()
    $syncEnv = @{ ORT_CHAIN_WHEEL_DIR = $(if ($Store) { $Store } else { $null }); PYTHON_WHEELS = $null; UV_PROJECT_ENVIRONMENT = $Fixture.Venv; UV_SYNC_EXTRAS = $null }
    try {
        if ($ViaSync) {
            Invoke-WithEnv $syncEnv { Sync-UvProjectDependencies -PyprojectPath (Join-Path $Fixture.Venv 'pyproject.toml') -CommandRunner $runner -LogWarning $log }
        } else {
            Sync-UvChainOnnxRuntime -VenvPath $Fixture.Venv -WheelStore $Store -CommandRunner $runner -PythonRunner $python -LogInfo $log -LogWarning $log
        }
    } catch { $state.Error = $_.Exception.Message }
    $state.NoSync = "$env:UV_NO_SYNC"
    return $state
}

Describe 'WindowsUv.Common: which store says "inside our images"' {
    It 'ORT_CHAIN_WHEEL_DIR wins over the image''s PYTHON_WHEELS, which wins over the default dir' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ ORT_CHAIN_WHEEL_DIR = 'X:\ort'; PYTHON_WHEELS = 'X:\wheels' } { Assert-Equal 'X:\ort' (Get-ChainOrtWheelStore -DefaultStore $d) 'explicit store' }
            Invoke-WithEnv @{ ORT_CHAIN_WHEEL_DIR = $null; PYTHON_WHEELS = 'X:\wheels' } { Assert-Equal 'X:\wheels' (Get-ChainOrtWheelStore -DefaultStore $d) 'the image ENV' }
            Invoke-WithEnv @{ ORT_CHAIN_WHEEL_DIR = $null; PYTHON_WHEELS = $null } {
                Assert-Equal $d (Get-ChainOrtWheelStore -DefaultStore $d) 'C:\runtime\wheels when it exists'
                Assert-Null (Get-ChainOrtWheelStore -DefaultStore (Join-Path $d 'absent')) 'outside our images'
            }
        }
    }
}

# Where the single windows/Dockerfile COPY naming $Source puts it, re-rooted under $Root (drive dropped).
function script:Get-ImageCopyDest {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Root)
    $copies = @(Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Dockerfile') |
            Where-Object { $_ -match '^COPY\s' -and @($_.Trim() -split '\s+' | Select-Object -Skip 1 | Select-Object -SkipLast 1) -contains $Source })
    Assert-Equal 1 $copies.Count "exactly one windows/Dockerfile COPY carries $Source"
    $dest = Join-Path $Root (($copies[0].Trim() -split '\s+')[-1] -replace '^[A-Za-z]:\\', '')
    if ($dest.EndsWith('\')) { $dest = Join-Path $dest (Split-Path $Source -Leaf) }
    return $dest
}

Describe 'WindowsUv.Common: where the ORT census is, in the hub checkout and in the image' {
    It 'the hub checkout resolves its own linux\scripts copy' {
        $want = [IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) 'linux\scripts\03-media\runtime\ort-venv-census.py'))
        Assert-Equal $want (Get-UvOrtCensusPath) 'the checkout copy'
        Assert-True (Test-Path -LiteralPath $want -PathType Leaf) 'and it exists'
    }

    # The image sets PYTHON_WHEELS image-wide, so its module copy runs the census on every sync: a fresh pwsh imports
    # that copy from the layout windows/Dockerfile builds, and the census it hands the interpreter must be the COPYed one.
    It 'the image copy of the module runs the census windows/Dockerfile COPYs beside its modules dir' {
        Invoke-InTestDir { param($d)
            $modules = Get-ImageCopyDest -Source 'windows\scripts\modules' -Root $d
            $census = Get-ImageCopyDest -Source 'linux\scripts\03-media\runtime\ort-venv-census.py' -Root $d
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $modules), (Split-Path $census)
            Copy-Item -Recurse -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\modules') -Destination $modules
            Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'linux\scripts\03-media\runtime\ort-venv-census.py') -Destination $census
            $f = New-ChainOrtFixture -Dir $d
            $probe = @"
`$ErrorActionPreference = 'Stop'
`$env:ORT_CHAIN_WHEEL_DIR = `$null; `$env:PYTHON_WHEELS = '$($f.Store)'
Import-Module '$(Join-Path $modules 'WindowsUv.Common.psm1')' -DisableNameChecking
`$seen = [System.Collections.Generic.List[string]]::new()
`$py = { param(`$exe, `$arguments) `$seen.Add(`$arguments -join ' '); [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure()
Sync-UvChainOnnxRuntime -VenvPath '$($f.Venv)' -PythonRunner `$py -LogInfo { } -LogWarning { }
`$seen[0]
"@
            $out = @(& pwsh -NoProfile -NonInteractive -Command $probe 2>&1 | ForEach-Object { "$_" })
            Assert-Equal 0 $LASTEXITCODE "the image copy's sync threw: $($out -join ' | ')"
            Assert-Equal "-I $census --purge-list" ($out | Select-Object -Last 1) 'the census beside the modules dir, not the absent checkout path'
        }
    }

    It 'with neither copy the resolver names the checkout path, and a sync inside our images fails on it' {
        Invoke-InTestDir { param($d)
            $f = New-ChainOrtFixture -Dir $d
            $missing = Get-UvOrtCensusPath -ModuleDir (Join-Path $d 'temp\scripts\modules')
            Assert-Equal ([IO.Path]::GetFullPath((Join-Path $d 'linux\scripts\03-media\runtime\ort-venv-census.py'))) $missing 'the checkout path'
            $err = try { Sync-UvChainOnnxRuntime -VenvPath $f.Venv -WheelStore $f.Store -CensusPath $missing -LogInfo { } -LogWarning { }; '' } catch { $_.Exception.Message }
            Assert-Match "^chain ORT: need the store .*\(missing: $([regex]::Escape($missing))\)$" $err 'the missing census is named, the venv untouched'
        }
    }
}

# $Body gets ($fixture, $dir) in a throwaway dir, with UV_NO_SYNC cleared for the case and restored after it.
function script:Use-ChainOrtFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [switch]$NoOrtWheel)
    Invoke-InTestDir { param($d)
        $f = New-ChainOrtFixture -Dir $d -NoOrtWheel:$NoOrtWheel
        Invoke-WithEnv @{ UV_NO_SYNC = $null } { & $Body $f $d }
    }
}

Describe 'WindowsUv.Common: Sync-UvChainOnnxRuntime, and Sync-UvProjectDependencies calling it' {
    It 'inside our images replaces every PyPI ORT dist with the chain wheels and holds uv run off the lock' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store
            Assert-Equal '' $r.Error 'no failure'
            Assert-Equal 2 $r.Uv.Count 'one uninstall, one install'
            Assert-Equal "pip uninstall --python $($f.Venv)\Scripts\python.exe onnxruntime onnxruntime-directml onnxruntime-genai" $r.Uv[0] 'every dist the census lists'
            Assert-Match '^pip install --python [^ ]+ --no-index --no-deps --force-reinstall ' $r.Uv[1] 'offline, without the wheels'' PyPI dependency metadata'
            Assert-Match '[\\/]onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl( |$)' $r.Uv[1] 'the chain core wheel'
            Assert-Match '[\\/]onnxruntime_genai-0\.15\.2-cp314-cp314-win_amd64\.whl( |$)' $r.Uv[1] 'the chain GenAI wheel'
            Assert-False ($r.Uv[1] -match 'tvm-') 'only ORT wheels are taken from the store'
            Assert-Equal '1' $r.NoSync 'UV_NO_SYNC held'
            Assert-True (@($r.Log) -match 'ORT-CENSUS PASS') 'the census verdict is logged'
        }
    }

    # Each check failing alone. After uv (2 calls): the census (bytes), the import (a DLL the venv lacks). Before uv
    # (0 calls): wheels the venv's ABI tag cannot load (abi3 fits any), an ORT import package no distribution owns.
    foreach ($failure in @(
            @{ Name = 'the census still finds a non-chain dist after uv ran'; Case = @{ CheckExit = 1 }; Uv = 2; Want = 'still carries a non-chain ONNX Runtime:\n.*onnxruntime-directml 1\.24\.4' },
            @{ Name = 'the proven chain onnxruntime does not import'; Case = @{ ImportExit = 1 }; Uv = 2; Want = 'does not import in .*\n3\.13\.15\nImportError: DLL load failed' },
            @{ Name = 'the chain wheels do not fit the venv''s ABI tag (a cp313 leg)'; Case = @{ Abi = 'cp313' }; Uv = 0
                Want = 'is a cp313 venv, and the chain wheels are built for the image interpreter: (?!.*onnxruntime_extensions)(?=.*onnxruntime_genai-0\.15\.2-cp314-cp314).*onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl.*list it in EXPERIMENTAL_PYTHON_VERSIONS'
            },
            @{ Name = 'an ORT import package has no distribution to purge'; Case = @{ Listed = @(); UnownedExit = 1; CheckExit = 1 }; Uv = 0
                Want = 'imports ONNX Runtime with no distribution to purge \(onnxruntime\):\n.*ORT-CENSUS FAIL'
            }
        )) {
        It "throws when $($failure.Name), and takes no hold" {
            Use-ChainOrtFixture { param($f)
                $case = $failure.Case
                $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store @case
                Assert-Match $failure.Want $r.Error 'the failing check, with its evidence, is the error'
                Assert-Equal $failure.Uv $r.Uv.Count 'uv calls before the failure (0 = the venv is untouched)'
                Assert-Equal '' $r.NoSync 'no hold on failure'
            }
        }
    }

    It 'outside our images only warns and asks uv for nothing' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -Fixture $f -Store ''
            Assert-Equal '' $r.Error 'today''s behaviour: no failure'
            Assert-Equal 0 $r.Uv.Count 'no uv call'
            Assert-True (@($r.Log) -match 'NOTICE: .* runs ONNX Runtime from outside the chain: onnxruntime onnxruntime-directml onnxruntime-genai') 'the loud notice names them'
            Assert-Equal '' $r.NoSync 'no hold'
        }
    }

    It 'fails before touching the venv when the store has no ORT wheel, or is declared and missing' {
        Use-ChainOrtFixture -NoOrtWheel { param($f, $d)
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store
            Assert-Match 'holds no onnxruntime wheel' $r.Error 'no replacement, no uninstall'
            Assert-Equal 0 $r.Uv.Count 'uv not called'
            $r = Invoke-ChainOrtCase -Fixture $f -Store (Join-Path $d 'no-such-store')
            Assert-Match '^chain ORT: need the store' $r.Error 'a declared store that is gone is an image regression'
            Assert-Equal 0 $r.Uv.Count 'uv not called'
        }
    }

    It 'keeps uv''s reason when uv refuses the chain wheels (a wheel for another platform)' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store -FailInstall
            Assert-Match 'does not take the chain wheels: .*not supported on this platform' $r.Error 'uv''s reason is kept'
        }
    }

    It 'a venv without ORT is untouched, and releases only the hold this module took' {
        Use-ChainOrtFixture { param($f)
            Assert-Equal '1' (Invoke-ChainOrtCase -Fixture $f -Store $f.Store).NoSync 'held by the first venv'
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Listed @()
            Assert-Equal 0 $r.Uv.Count 'nothing to replace'
            Assert-Equal '' $r.NoSync 'released for the next venv'
            Assert-Equal '' (Invoke-ChainOrtCase -Fixture $f -Store '' -Listed @() -UnownedExit 1 -CheckExit 1).Error 'outside our images an unowned ORT fails nothing'
            $env:UV_NO_SYNC = '1'
            Assert-Equal '1' (Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Listed @()).NoSync 'a caller''s own UV_NO_SYNC is never cleared'
        }
    }

    It 'Sync-UvProjectDependencies reconciles after its sync: fails closed inside our images, unchanged outside' {
        Use-ChainOrtFixture { param($f)
            $inside = Invoke-ChainOrtCase -ViaSync -Fixture $f -Store $f.Store
            Assert-Match '^-v sync --dev --all-extras' $inside.Uv[0] 'the sync ran first'
            Assert-Match '^chain ORT: cannot list ' $inside.Error 'the fixture python.exe cannot run, and inside our images that fails closed'
            $outside = Invoke-ChainOrtCase -ViaSync -Fixture $f -Store ''
            Assert-Equal '' $outside.Error 'outside our images nothing fails, even when the venv cannot be inspected'
            Assert-Equal 1 $outside.Uv.Count 'and uv is asked for nothing but the sync'
        }
    }
}
