#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: real Python, uv or inference; child and copied-module path checks run on Linux and Windows.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WindowsUv.ChainFixtures.psm1') -Force -DisableNameChecking

function script:Get-ImageCopyDest {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Root)
    $copies = @(Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Dockerfile') |
            Where-Object { $_ -match '^COPY\s' -and @($_.Trim() -split '\s+' | Select-Object -Skip 1 | Select-Object -SkipLast 1) -contains $Source })
    Assert-Equal 1 $copies.Count "exactly one windows/Dockerfile COPY carries $Source"
    $dest = Join-Path $Root (($copies[0].Trim() -split '\s+')[-1] -replace '^[A-Za-z]:\\', '')
    if ($dest -match '[\\/]$') { $dest = Join-Path $dest (Split-Path $Source -Leaf) }
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
`$env:PYTHON_WHEELS_FREE_THREADED = `$null; `$env:PYTHON_WHEELS_CP314T = `$null
Import-Module '$(Join-Path $modules 'WindowsUv.Common.psm1')' -DisableNameChecking
`$seen = [System.Collections.Generic.List[string]]::new()
`$py = { param(`$exe, `$arguments) `$seen.Add(`$arguments -join ' '); [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure()
Sync-UvChainOnnxRuntime -VenvPath '$($f.Venv)' -PythonRunner `$py -LogInfo { } -LogWarning { }
`$seen[0]
"@
            $out = @(Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $f.Store; PYTHON_WHEELS_CP314T = $f.Store } {
                & pwsh -NoProfile -NonInteractive -Command $probe 2>&1 | ForEach-Object { "$_" }
            })
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
