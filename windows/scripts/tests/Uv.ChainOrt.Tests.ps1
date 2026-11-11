#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real interpreter or census run (seams; test-uv-chain-ort.sh runs both on Linux), real uv.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking

Import-Module (Join-Path $PSScriptRoot 'WindowsUv.ChainFixtures.psm1') -Force -DisableNameChecking

function script:Get-ChainOrtPythonReply {
    param([object[]]$Arguments, [string[]]$Listed, [int]$UnownedExit, [string]$Abi, [int]$ImportExit, [int]$CheckExit)
    if ($Arguments -contains '--purge-list') { return [pscustomobject]@{ ExitCode = 0; Output = $Listed } }
    if ($Arguments[-1] -match 'find_spec') { return [pscustomobject]@{ ExitCode = $UnownedExit; Output = @($(if ($UnownedExit) { 'onnxruntime' } else { '' })) } }
    if ($Arguments[-1] -match 'Py_GIL_DISABLED') { return [pscustomobject]@{ ExitCode = 0; Output = @($Abi) } }
    if ($Arguments -contains '-c') { return [pscustomobject]@{ ExitCode = $ImportExit; Output = @('3.13.15', 'ImportError: DLL load failed while importing onnxruntime_pybind11_state') } }
    $verdict = if ($CheckExit -eq 0) { 'ORT-CENSUS PASS: 2 chain distribution(s)' } else { 'ORT-CENSUS FAIL onnxruntime-directml 1.24.4 is not a chain wheel' }
    return [pscustomobject]@{ ExitCode = $CheckExit; Output = @($verdict) }
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
    $check = {
        param($exe, $arguments)
        if ($FailInstall -and $arguments[1] -eq 'install') { throw 'uv: the wheel is not supported on this platform' }
        if ($StaleLock -and $arguments -contains '--locked') { throw 'The lockfile at `uv.lock` needs to be updated, but `--locked` was provided.' }
    }.GetNewClosure()
    $observer = New-UvChainTestObserver -CommandCheck $check
    $state = $observer.State
    $python = {
        param($exe, $arguments)
        Get-ChainOrtPythonReply -Arguments $arguments -Listed $Listed -UnownedExit $UnownedExit -Abi $Abi -ImportExit $ImportExit -CheckExit $CheckExit
    }.GetNewClosure()
    $syncEnv = @{ ORT_CHAIN_WHEEL_DIR = $null; PYTHON_WHEELS = $null; UV_PROJECT_ENVIRONMENT = $Fixture.Venv; UV_SYNC_EXTRAS = $null }
    if ($Store) { $syncEnv[$StoreVar] = $Store }
    if ($Lock) { Set-Content -LiteralPath (Join-Path $Fixture.Venv 'uv.lock') -Value $Lock -Encoding utf8NoBOM }
    $sync = @{ UseLocked = $UseLocked; RetryWithoutLocked = $RetryWithoutLocked; PythonRunner = $(if ($StubPython) { $python } else { $null }) }
    try {
        if ($ViaSync) {
            Invoke-WithEnv $syncEnv { Sync-UvProjectDependencies -PyprojectPath (Join-Path $Fixture.Venv 'pyproject.toml') -CommandRunner $observer.CommandRunner -LogInfo $observer.Log -LogWarning $observer.Log @sync }
        } else {
            Sync-UvChainOnnxRuntime -VenvPath $Fixture.Venv -WheelStore $Store -Skipped $Skipped -CommandRunner $observer.CommandRunner -PythonRunner $python -LogInfo $observer.Log -LogWarning $observer.Log
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

function script:Assert-ChainOrtLogged {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Because)
    Assert-True (@($State.Log) -match $Pattern) $Because
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
            Assert-UvChainTestReplacement -State $r -CommandCount 2
            Assert-UvChainTestCommand -State $r -Index 0 -Equal "pip uninstall --python $($f.Venv)\Scripts\python.exe onnxruntime onnxruntime-directml onnxruntime-genai"
            Assert-UvChainTestCommand -State $r -Index 1 -Match @(
                '^pip install --python [^ ]+ --no-index --no-deps --force-reinstall ',
                '[\\/]onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl( |$)',
                '[\\/]onnxruntime_genai-0\.15\.2-cp314-cp314-win_amd64\.whl( |$)'
            ) -NotMatch 'tvm-'
            Assert-ChainOrtLogged $r 'ORT-CENSUS PASS' 'the census verdict is logged'
        }
    }

    It 'a free-threaded venv takes the image''s cp3XYt twin store, and without one fails on the ABI as before (mutation)' {
        Use-ChainOrtFixture { param($f, $d)
            $twins = New-Item -ItemType Directory -Force -Path (Join-Path $d 'wheels-free-threaded')
            Set-Content -LiteralPath (Join-Path $twins 'onnxruntime-1.30.0-cp314-cp314t-win_amd64.whl') 'x' -Encoding ASCII
            foreach ($var in 'PYTHON_WHEELS_FREE_THREADED', 'PYTHON_WHEELS_CP314T') {
                $other = if ($var -eq 'PYTHON_WHEELS_CP314T') { 'PYTHON_WHEELS_FREE_THREADED' } else { 'PYTHON_WHEELS_CP314T' }
                $r = Invoke-WithEnv @{ $var = $twins.FullName; $other = $null } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Abi 'cp314t' -Listed @('ORT-CENSUS PURGE onnxruntime') }
                Assert-Equal '' $r.Error "the twin fits ($var)"
                Assert-Match '[\\/]wheels-free-threaded[\\/]onnxruntime-1\.30\.0-cp314-cp314t-win_amd64\.whl$' $r.Uv[1] "the twin, nothing from the GIL store ($var)"
            }
            $gil = Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $twins.FullName } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store }
            Assert-Match '[\\/]store[\\/]onnxruntime-1\.30\.0-cp314-cp314-win_amd64\.whl' $gil.Uv[1] 'a GIL venv keeps the GIL store'
            $none = Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $null; PYTHON_WHEELS_CP314T = $null } { Invoke-ChainOrtCase -Fixture $f -Store $f.Store -Abi 'cp314t' }
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
            Assert-ChainOrtLogged $r 'NOTICE: .* runs ONNX Runtime from outside the chain: onnxruntime onnxruntime-directml onnxruntime-genai' 'the loud notice names them'
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
            Assert-ChainOrtLogged $r '^chain ORT: the sync leaves onnxruntime onnxruntime-directml onnxruntime-genai to the chain wheels$' 'the skip is logged'
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
            Assert-ChainOrtLogged $r '^chain ORT: replacing onnxruntime onnxruntime-genai in ' 'both are replaced'
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
