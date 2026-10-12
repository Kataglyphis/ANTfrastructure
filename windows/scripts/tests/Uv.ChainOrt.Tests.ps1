#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
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

# -ViaSync goes through Sync-UvProjectDependencies instead, with the real interpreter runner unless -StubPython; -Lock is its uv.lock.
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
        [switch]$ViaSync,
        [string[]]$Skipped = @(),
        [string[]]$Lock,
        [ValidateSet('ORT_CHAIN_WHEEL_DIR', 'PYTHON_WHEELS')][string]$StoreVar = 'ORT_CHAIN_WHEEL_DIR',
        [switch]$StubPython,
        [switch]$UseLocked,
        [switch]$RetryWithoutLocked,
        [switch]$StaleLock
    )
    $state = [pscustomobject]@{ Uv = [System.Collections.Generic.List[string]]::new(); Log = [System.Collections.Generic.List[string]]::new(); Error = ''; NoSync = '' }
    $runner = {
        param($exe, $arguments)
        $state.Uv.Add(($arguments -join ' '))
        if ($FailInstall -and $arguments[1] -eq 'install') { throw 'uv: the wheel is not supported on this platform' }
        if ($StaleLock -and $arguments -contains '--locked') { throw 'The lockfile at `uv.lock` needs to be updated, but `--locked` was provided.' }
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
    $syncEnv = @{ ORT_CHAIN_WHEEL_DIR = $null; PYTHON_WHEELS = $null; UV_PROJECT_ENVIRONMENT = $Fixture.Venv; UV_SYNC_EXTRAS = $null }
    if ($Store) { $syncEnv[$StoreVar] = $Store }
    if ($Lock) { Set-Content -LiteralPath (Join-Path $Fixture.Venv 'uv.lock') -Value $Lock -Encoding utf8NoBOM }
    $sync = @{ UseLocked = $UseLocked; RetryWithoutLocked = $RetryWithoutLocked; PythonRunner = $(if ($StubPython) { $python } else { $null }) }
    try {
        if ($ViaSync) {
            Invoke-WithEnv $syncEnv { Sync-UvProjectDependencies -PyprojectPath (Join-Path $Fixture.Venv 'pyproject.toml') -CommandRunner $runner -LogInfo $log -LogWarning $log @sync }
        } else {
            Sync-UvChainOnnxRuntime -VenvPath $Fixture.Venv -WheelStore $Store -Skipped $Skipped -CommandRunner $runner -PythonRunner $python -LogInfo $log -LogWarning $log
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

    # PYTHON_WHEELS is image-wide, so the image's module copy runs the census on every sync and must find the COPYed one.
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

    It 'a free-threaded venv takes the image''s cp3XYt twin store, and without one fails on the ABI as before (mutation)' {
        Use-ChainOrtFixture { param($f, $d)
            $twins = New-Item -ItemType Directory -Force -Path (Join-Path $d 'wheels-cp314t')
            Set-Content -LiteralPath (Join-Path $twins 'onnxruntime-1.30.0-cp314-cp314t-win_amd64.whl') 'x' -Encoding ASCII
            $r = Invoke-WithEnv @{ PYTHON_WHEELS_CP314T = $twins.FullName } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Abi 'cp314t' -Listed @('ORT-CENSUS PURGE onnxruntime') }
            Assert-Equal '' $r.Error 'the twin fits'
            Assert-Match '[\\/]wheels-cp314t[\\/]onnxruntime-1\.30\.0-cp314-cp314t-win_amd64\.whl$' $r.Uv[1] 'the twin, nothing from the GIL store'
            $gil = Invoke-WithEnv @{ PYTHON_WHEELS_CP314T = $twins.FullName } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store }
            Assert-Match '[\\/]store[\\/]onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl' $gil.Uv[1] 'a GIL venv keeps the GIL store'
            $none = Invoke-WithEnv @{ PYTHON_WHEELS_CP314T = $null } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Abi 'cp314t' }
            Assert-Match 'is a cp314t venv, and the chain wheels are built for the image interpreter' $none.Error 'no twins: the old verdict'
        }
    }

    # Each check failing alone: census and import run after uv's 2 calls, the ABI and ownership checks before any.
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

# A uv.lock with -Name's [[package]] tables, each with an indented dependency reference that is no table.
function script:New-ChainOrtLock([string[]]$Name) {
    $lines = @('version = 1', '')
    foreach ($n in $Name) { $lines += '[[package]]', "name = ""$n""", 'version = "1.0"', 'dependencies = [', '    { name = "numpy" },', ']', '' }
    return $lines
}

# A sync inside our images over an ORT lock, with no ORT left in the venv for the census to list.
function script:Invoke-OrtSkipSync([pscustomobject]$Fixture, [hashtable]$Case = @{}) {
    return Invoke-ChainOrtCase -ViaSync -StubPython -Fixture $Fixture -Store $Fixture.Store -Lock (New-ChainOrtLock 'numpy', 'onnxruntime', 'onnxruntime-directml', 'onnxruntime_genai', 'orchestrant') -Listed @() @Case
}

Describe 'WindowsUv.Common: inside our images the sync leaves the lock''s ORT to the chain wheels (CON91)' {
    $skip = '--no-install-package onnxruntime --no-install-package onnxruntime-directml --no-install-package onnxruntime-genai'

    It 'the image''s PYTHON_WHEELS alone skips every ORT of the lock, and the reconcile installs the chain wheels with nothing to uninstall' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-OrtSkipSync $f @{ StoreVar = 'PYTHON_WHEELS' }
            Assert-Equal '' $r.Error 'no failure'
            Assert-Equal "-v sync --dev --all-extras $skip" $r.Uv[0] 'the sync names every lock ORT, normalised'
            Assert-Equal 2 $r.Uv.Count 'the sync and one install, no uninstall'
            Assert-Match '^pip install --python .*onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl' $r.Uv[1] 'the chain wheels go in'
            Assert-Equal '1' $r.NoSync 'UV_NO_SYNC held'
            Assert-True (@($r.Log) -match '^chain ORT: the sync leaves onnxruntime onnxruntime-directml onnxruntime-genai to the chain wheels$') 'the skip is logged'
        }
    }

    It 'the unlocked retry keeps the skip' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-OrtSkipSync $f @{ UseLocked = $true; RetryWithoutLocked = $true; StaleLock = $true }
            Assert-Equal '' $r.Error 'the retry passed'
            Assert-Equal "-v sync --dev --all-extras --locked $skip" $r.Uv[0] 'the locked attempt'
            Assert-Equal "-v sync --dev --all-extras $skip" $r.Uv[1] 'the retry'
        }
    }

    It 'outside our images the lock is not read: no skip, and a malformed lock fails nothing' {
        if (Test-Path -LiteralPath 'C:\runtime\wheels') { return }
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -ViaSync -Fixture $f -Store '' -Lock @('[[package]]', 'version = "1"')
            Assert-Equal '' $r.Error 'not read'
            Assert-Equal '-v sync --dev --all-extras' $r.Uv[0] 'no skip'
        }
    }

    It 'inside our images a lock it cannot read fails before the sync (mutation)' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -ViaSync -StubPython -Fixture $f -Store $f.Store -Lock @('[[package]]', 'version = "1"')
            Assert-Match '^chain ORT: cannot read the packages of .*uv\.lock: 0 name\(s\) for 1 \[\[package\]\] table\(s\)' $r.Error 'the count guard'
            Assert-Equal 0 $r.Uv.Count 'no sync'
        }
    }

    It 'a skipped name joins the census list once, and only the installed ones are uninstalled; no ORT wheel then fails (mutation)' {
        Use-ChainOrtFixture { param($f)
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Listed @('ORT-CENSUS PURGE onnxruntime') -Skipped 'onnxruntime', 'onnxruntime-genai'
            Assert-Equal '' $r.Error 'no failure'
            Assert-Equal "pip uninstall --python $($f.Venv)\Scripts\python.exe onnxruntime" $r.Uv[0] 'the installed one alone'
            Assert-True (@($r.Log) -match '^chain ORT: replacing onnxruntime onnxruntime-genai in ') 'both are replaced'
        }
        Use-ChainOrtFixture -NoOrtWheel { param($f)
            $r = Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Listed @() -Skipped 'onnxruntime'
            Assert-Match 'holds no onnxruntime wheel for onnxruntime' $r.Error 'a skipped ORT with no chain wheel would leave the venv without one'
        }
    }
}

Describe 'Get-UvLockOrtName (CON91)' {
    It 'returns the lock''s ORT names normalised and once, ignores dependency references, and reads a CRLF lock' {
        Invoke-InTestDir { param($d)
            $lock = Join-Path $d 'uv.lock'
            Set-Content -LiteralPath $lock -Value (New-ChainOrtLock 'onnxruntime_GenAI', 'onnxruntime', 'onnxruntime.genai', 'numpy', 'onnxruntimex')
            Assert-Equal 'onnxruntime|onnxruntime-genai' ((Get-UvLockOrtName -LockPath $lock) -join '|') 'normalised, deduplicated, onnxruntimex is no ORT'
            [IO.File]::WriteAllText($lock, ((New-ChainOrtLock 'onnxruntime-directml') -join "`r`n"))
            Assert-Equal 'onnxruntime-directml' ((Get-UvLockOrtName -LockPath $lock) -join '|') 'CRLF'
            Assert-Equal 0 @(Get-UvLockOrtName -LockPath (Join-Path $d 'absent.lock')).Count 'no lock, no names'
            Set-Content -LiteralPath $lock -Value @('[[package]]', 'name = "onnxruntime"', '[[package]]')
            Assert-Throws { Get-UvLockOrtName -LockPath $lock } -MessagePattern '1 name\(s\) for 2 \[\[package\]\] table\(s\)'
            Set-Content -LiteralPath $lock -Value @('[[package]]', 'name = "onnxruntime-x y"')
            Assert-Throws { Get-UvLockOrtName -LockPath $lock } -MessagePattern 'pins an ORT name uv sync cannot be handed: onnxruntime-x y'
        }
    }
}
