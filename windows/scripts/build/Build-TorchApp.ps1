# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
# Windows mirror of assemble-torch-app.sh; see docs/windows-builds.md § The torch step (OrchestrANT app environment).
param(

    [string]$AppRef = '',
    [string]$AppDir = 'C:\opt\OrchestrANT',
    [string]$WheelDir = 'C:\runtime\wheels',
    [ValidateSet('install', 'verify', 'all')][string]$Mode = 'all',
    # Torch backend extra, the only place the app declares torch: pytorch-cpu (default), pytorch-cu130, ...; 'none' disables.
    [string]$PytorchExtra = '',
    [string]$OrtCensusPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$nativeModulePath = Join-Path $scriptAssetRoot 'modules\WindowsNative.Common.psm1'
if (-not (Test-Path $nativeModulePath)) { throw "Required module not found: $nativeModulePath" }
Import-Module $nativeModulePath -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsUvLock.Common.psm1')
# Test-PeRichHeader for the install's sdist compiler gate; verify mode runs from mounts that may lack it.
$targetArchModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if (Test-Path $targetArchModulePath) { Import-Module $targetArchModulePath -Force }

# The else-literal must equal versions.env APP_REF; SourceBuild.PinParity gates it.
if ([string]::IsNullOrWhiteSpace($AppRef)) { $AppRef = if ($env:APP_REF) { $env:APP_REF } else { 'develop' } }
if ([string]::IsNullOrWhiteSpace($PytorchExtra)) { $PytorchExtra = if ($env:PYTORCH_EXTRA) { $env:PYTORCH_EXTRA } else { 'pytorch-cpu' } }
$script:OrtCensusPath = if ($OrtCensusPath) { $OrtCensusPath } else { Join-Path $PSScriptRoot 'ort-venv-census.py' }
if (-not (Test-Path -LiteralPath $script:OrtCensusPath -PathType Leaf)) { throw "ORT census source missing at $script:OrtCensusPath" }

$cpythonExe = 'C:\temp\cpython\PCbuild\amd64\python.exe'
$baseSite = 'C:\temp\cpython\Lib\site-packages'
$venvDir = Join-Path $AppDir '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$venvSite = Join-Path $venvDir 'Lib\site-packages'

# The image stages the shared Linux census beside this script, keeping one source of truth.
function Get-TorchAppOrtCensusSource {
    return [IO.File]::ReadAllText($script:OrtCensusPath)
}

# Runs the census from stdin under -I; a missing interpreter throws, so a stale $LASTEXITCODE is never a verdict.
function Invoke-TorchAppOrtCensus {
    param(
        [Parameter(Mandatory)][ValidateSet('check', 'purge-list')][string]$Mode,
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$Store
    )
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "ORT census: no interpreter at $Python" }
    $ErrorActionPreference = 'Continue'
    $lines = @(Get-TorchAppOrtCensusSource | & $Python -I - "--$Mode" --store $Store 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

# Findings from one census run; empty = pass. Exit 0 without the PASS line is not a pass.
function Get-TorchAppOrtCensusFinding {
    param([int]$ExitCode, [AllowNull()][AllowEmptyCollection()][string[]]$Output)
    $all = @($Output | Where-Object { $null -ne $_ })
    $fails = @($all -clike 'ORT-CENSUS FAIL *' | ForEach-Object { $_.Substring(16) })
    if ($fails.Count) { return $fails }
    $tail = ($all | Select-Object -Last 3) -join ' | '
    if ($ExitCode -ne 0) { return "the census exited $ExitCode without a finding: $tail" }
    if (-not @($all -clike 'ORT-CENSUS PASS*').Count) { return "the census printed no PASS line: $tail" }
}

# The venv's ORT distributions (onnxruntime* names and every owner of an ORT package), to uninstall.
function Get-TorchAppOrtPurgeName {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Store)
    $run = Invoke-TorchAppOrtCensus -Mode purge-list -Python $Python -Store $Store
    if ($run.ExitCode -ne 0) {
        throw "the ORT census could not list the venv's ONNX Runtime distributions (exit $($run.ExitCode)): $(($run.Lines | Select-Object -Last 3) -join ' | ')"
    }
    return @($run.Lines | Where-Object { $_ -cmatch '^ORT-CENSUS PURGE [a-z0-9][a-z0-9-]*$' } | ForEach-Object { $_.Substring(17) })
}

# Fail-closed: every ORT distribution in the venv must be byte-identical to a chain wheel in -Store.
function Assert-TorchAppOrtChainOnly {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Store)
    $run = Invoke-TorchAppOrtCensus -Mode check -Python $Python -Store $Store
    $run.Lines | ForEach-Object { Write-Host $_ }
    $findings = @(Get-TorchAppOrtCensusFinding -ExitCode $run.ExitCode -Output $run.Lines)
    if ($findings.Count) { throw "the venv carries ONNX Runtime that is not the chain's ($($findings.Count) finding(s)): $($findings -join '; ')" }
}

# Every ORT distribution uv.lock pins, by the census's name pattern (never a list), normalized.
function Get-TorchAppLockOrtName {
    param([Parameter(Mandatory)][string]$LockPath)
    return Get-OrtLockPackageName -LockPath $LockPath
}

# The chain wheel that replaces an ORT distribution: every runtime flavour is onnxruntime, every GenAI one onnxruntime-genai.
function Get-TorchAppOrtFamily {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cmatch '^onnxruntime-(genai|extensions)(-|$)') { return "onnxruntime-$($Matches[1])" }
    if ($Name -cmatch '^onnxruntime(-[a-z0-9]+)?$') { return 'onnxruntime' }
    return $Name
}

# `uv sync` args keeping every ORT distribution of -LockPath out of the venv; each needs a chain wheel of its family.
function Get-TorchAppOrtSyncArg {
    param([Parameter(Mandatory)][string]$LockPath, [Parameter(Mandatory)][string]$Store)
    $locked = @(Get-TorchAppLockOrtName -LockPath $LockPath)
    $chain = @(Get-ChildItem -LiteralPath $Store -Filter '*.whl' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-TorchAppOrtFamily -Name (($_.Name.Split('-')[0] -replace '[_.]+', '-').ToLowerInvariant()) })
    $missing = @($locked | Where-Object { (Get-TorchAppOrtFamily -Name $_) -cnotin $chain })
    if ($missing.Count) { throw "uv.lock pins $($missing -join ', ') and $Store has no chain wheel of that family: uv sync would install the lock's PyPI build" }
    Write-Host "uv sync skips the lock's ORT distributions (the chain wheels replace them): $(if ($locked.Count) { $locked -join ', ' } else { 'none' })"
    return (@($locked | ForEach-Object { "--no-install-package $_" }) -join ' ')
}

# `uv sync` args keeping the lock's ai-edge-litert out when the chain built one, or when the lock has no wheel for -AbiTag.
function Get-TorchAppLitertSyncArg {
    param([Parameter(Mandatory)][string]$LockPath, [Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][string]$AbiTag)
    $text = [System.IO.File]::ReadAllText($LockPath)
    if ($text -notmatch '(?m)^name = "ai-edge-litert"\r?$') { return '' }
    if (@(Get-ChildItem -LiteralPath $Store -Filter 'ai_edge_litert-*.whl' -File -ErrorAction SilentlyContinue).Count) {
        Write-Host "uv sync skips the lock's ai-edge-litert (the chain wheel replaces it)"
        return '--no-install-package ai-edge-litert'
    }
    if ($text -match "ai_edge_litert-[^/`"]+-$AbiTag-$AbiTag-win_amd64\.whl") { return '' }
    Write-Warning "ai-edge-litert: uv.lock has no $AbiTag win_amd64 wheel and $Store no chain wheel; the venv goes without it until the chain builds one (CON91)"
    return '--no-install-package ai-edge-litert'
}

# setuptools compiles an sdist with VS's cl.exe unless cl, link and lib on PATH are LLVM's, under DISTUTILS_USE_SDK (CON93).
function Enable-TorchAppClangClSdist {
    param([Parameter(Mandatory)][string]$ShimDir, [string]$LlvmBin = 'C:\llvm-patched\bin')
    $shim = [ordered]@{ 'cl.exe' = 'clang-cl.exe'; 'link.exe' = 'lld-link.exe'; 'lib.exe' = 'llvm-lib.exe' }
    $missing = @($shim.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LlvmBin $_) -PathType Leaf) })
    if ($missing.Count) { throw "the sdist compiler shim needs $($missing -join ', ') in $LlvmBin" }
    New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
    $shim.GetEnumerator() | ForEach-Object { Copy-Item -LiteralPath (Join-Path $LlvmBin $_.Value) -Destination (Join-Path $ShimDir $_.Key) -Force }
    # What the finally puts back.
    $previous = @{ DISTUTILS_USE_SDK = $env:DISTUTILS_USE_SDK; MSSdk = $env:MSSdk; PATH = $env:PATH }
    $env:DISTUTILS_USE_SDK = '1'
    $env:MSSdk = '1'
    $env:PATH = "$ShimDir;$env:PATH"
    return $previous
}

# Each distribution uv reports as built from source must have linked every PE under -SitePackages with lld-link (CON93).
function Assert-TorchAppSdistCompiler {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SyncOutput, [Parameter(Mandatory)][string]$SitePackages)
    $built = @($SyncOutput | ForEach-Object { if ("$_" -match '^\s*Built (\S+?)(==| @ )') { $Matches[1] } } | Sort-Object -Unique)
    Write-Host "uv built from source: $(if ($built.Count) { $built -join ', ' } else { 'nothing' })"
    $msvc = @(foreach ($name in $built) {
            $norm = $name -replace '[-_.]+', '_'
            $infos = @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Name -replace '-[^-]+\.dist-info$', '' -replace '[-_.]+', '_') -ieq $norm })
            if ($infos.Count -eq 0) { throw "uv built $name, but $SitePackages has no dist-info for it" }
            foreach ($line in [IO.File]::ReadAllLines((Join-Path $infos[0].FullName 'RECORD'))) {
                $rel = ($line -split ',')[0]
                # Scripts\*.exe are uv's own launchers, outside site-packages.
                if ($rel -notmatch '\.(pyd|dll|exe)$' -or $rel.StartsWith('..')) { continue }
                $pe = Join-Path $SitePackages $rel
                if ((Test-Path -LiteralPath $pe -PathType Leaf) -and (Test-PeRichHeader -Path $pe)) { "${name}: $rel" }
            }
        })
    if ($msvc.Count) { throw "uv built these with MSVC's linker, not the clang-cl shim: $($msvc -join '; ')" }
}

function New-TorchAppCheckout {
    param([string]$AppDir, [string]$AppRef)

    if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $AppDir -Parent) | Out-Null
    $appRepo = 'https://github.com/Kataglyphis/OrchestrANT.git'
    if ($AppRef -match '^[0-9a-f]{40}$') {
        # A commit is fetched as itself: clone --branch takes names only.
        [void](Invoke-ShieldedNative -Label 'git init (app)' -CommandLine "git init -q ""$AppDir""")
        [void](Invoke-ShieldedNative -Label 'git fetch (app)' -CommandLine "git -C ""$AppDir"" fetch -q --depth 1 $appRepo $AppRef")
        [void](Invoke-ShieldedNative -Label 'git checkout (app)' -CommandLine "git -C ""$AppDir"" checkout -q --detach FETCH_HEAD")
    } else {
        Write-Warning "APP_REF '$AppRef' is a name, not a commit: a cached build of this stage does not see it move"
        [void](Invoke-ShieldedNative -Label 'git clone (app)' -CommandLine "git clone --branch $AppRef --depth 1 $appRepo ""$AppDir""")
    }
}

function Install-TorchAppPython3Dll {
    param([string]$VenvPython)

    # abi3 pyds link python3.dll, which uv venvs do not stage beside python.exe.
    $venvScripts = Split-Path $VenvPython -Parent
    $py3Dll = Join-Path $venvScripts 'python3.dll'
    if (-not (Test-Path $py3Dll)) {
        $srcPy3 = 'C:\temp\cpython\PCbuild\amd64\python3.dll'
        if (Test-Path $srcPy3) {
            Copy-Item $srcPy3 $py3Dll -Force
            Write-Host 'Staged python3.dll into venv Scripts (abi3 wheel support)'
        } else {
            Write-Warning "python3.dll not found at $srcPy3 -- abi3 wheels (iree) may fail to import"
        }
    }
}

function Install-TorchAppEnvironment {
    Write-Host "=== torch app: clone $AppRef + uv sync (extras: ml-ai docs frontend $PytorchExtra test) ==="
    New-TorchAppCheckout -AppDir $AppDir -AppRef $AppRef

    # The source-built CPython matches the chain's cpXY wheels; copy mode, as hardlinks do not survive layer boundaries.
    $env:UV_PYTHON = $cpythonExe
    $env:UV_LINK_MODE = 'copy'
    # No uv cache: gigabytes of torch/onnxruntime wheels would otherwise be committed into the torch layer.
    $env:UV_NO_CACHE = '1'

    Push-Location $AppDir
    try {
        $extraArgs = '--extra ml-ai --extra docs --extra frontend'
        if ($PytorchExtra -and $PytorchExtra -ne 'none') { $extraArgs += " --extra $PytorchExtra" }
        if ($env:SKIP_TORCH_TEST_EXTRAS -ne 'true') { $extraArgs += ' --extra test' }
        $baseSyncArgs = "--find-links ""$WheelDir"" $extraArgs"
        $lockPath = Join-Path $AppDir 'uv.lock'
        $venvTag = "$(& $cpythonExe -I -c "import sys; print('cp%d%d' % sys.version_info[:2])")".Trim()
        if ($venvTag -notmatch '^cp\d+$') { throw "$cpythonExe did not report its wheel tag (got '$venvTag')" }

        # Frozen first; regenerate on failure, since the upstream lock may not cover this Python/platform.
        $haveLock = Test-Path $lockPath
        $frozenOk = $false
        $syncOut = @()
        $shimDir = 'C:\temp\clangcl-sdist-shim'
        $sdistEnv = Enable-TorchAppClangClSdist -ShimDir $shimDir
        try {
            if ($haveLock) {
                # Outside the try: a missing chain wheel stops the stage instead of regenerating the lock.
                $syncArgs = "$baseSyncArgs $(Get-TorchAppOrtSyncArg -LockPath $lockPath -Store $WheelDir) $(Get-TorchAppLitertSyncArg -LockPath $lockPath -Store $WheelDir -AbiTag $venvTag)"
                try { $syncOut = @(Invoke-ShieldedNative -Label 'uv sync --frozen' -CommandLine "uv sync $syncArgs --frozen"); $frozenOk = $true }
                catch { Write-Warning "frozen upstream uv.lock failed for this Python/platform -- regenerating a local lock ($($_.Exception.Message))" }
            }
            if (-not $frozenOk) {
                [void](Invoke-ShieldedNative -Label 'uv lock' -CommandLine "uv lock --find-links ""$WheelDir""")
                $syncArgs = "$baseSyncArgs $(Get-TorchAppOrtSyncArg -LockPath $lockPath -Store $WheelDir) $(Get-TorchAppLitertSyncArg -LockPath $lockPath -Store $WheelDir -AbiTag $venvTag)"
                $syncOut = @(Invoke-ShieldedNative -Label 'uv sync' -CommandLine "uv sync $syncArgs")
            }
        } finally {
            foreach ($name in $sdistEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $sdistEnv[$name]) }
            Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Assert-TorchAppSdistCompiler -SyncOutput $syncOut -SitePackages $venvSite

        # Reconcile: uninstall PyPI builds of our families (ORT names from the census, never a list) before reinstalling ours.
        $ortPurge = @(Get-TorchAppOrtPurgeName -Python $venvPython -Store $WheelDir)
        Write-Host "ORT distributions the chain wheels replace: $(if ($ortPurge.Count) { $ortPurge -join ', ' } else { 'none' })"
        [void](Invoke-ShieldedNative -Optional -Label 'uninstall pypi onnx/genai/opencv families' `
                -CommandLine "uv pip uninstall --python ""$venvPython"" $($ortPurge -join ' ') opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless")
        $localWheels = @(Get-ChildItem -Path $WheelDir -Filter '*.whl' -ErrorAction SilentlyContinue | ForEach-Object { '"{0}"' -f $_.FullName })
        if ($localWheels.Count -eq 0) { throw "no local wheels found in $WheelDir -- the media build should have staged onnxruntime/genai/tvm" }
        # --no-deps is required: genai-cuda names onnxruntime-gpu, which our combined onnxruntime wheel replaces.
        [void](Invoke-ShieldedNative -Label 'force-reinstall local wheels (no-deps)' `
                -CommandLine "uv pip install --python ""$venvPython"" --force-reinstall --no-deps $($localWheels -join ' ')")
        # From base site-packages, which venvs do not see: cv2 has no wheel, tvm_ffi and ml_dtypes no usable wheel for the image's tag.
        foreach ($staged in @('cv2', 'tvm_ffi', 'ml_dtypes', 'sitecustomize.py')) {
            $src = Join-Path $baseSite $staged
            if (Test-Path $src) {
                Copy-Item $src -Destination $venvSite -Recurse -Force
                Write-Host "Staged $staged into venv site-packages"
            } elseif ($staged -eq 'sitecustomize.py') {
                # Hard fail: nothing imports sitecustomize explicitly, so its loss would pass every later check.
                throw "$src not found -- the venv would silently lose the platform tag + DLL-dir wiring"
            } else {
                Write-Warning "$src not found -- venv will miss $staged"
            }
        }
        Install-TorchAppPython3Dll -VenvPython $venvPython
        Assert-TorchAppOrtChainOnly -Python $venvPython -Store $WheelDir
    } finally { Pop-Location }
    Write-Host '=== torch app: install complete ==='
}

function Test-TorchAppEnvironment {
    Write-Host '=== torch app: verify ==='
    if (-not (Test-Path $venvPython)) { throw "venv python missing at $venvPython (run -Mode install first)" }
    # Re-run on every verify: the rocm stage and the smoke gate verify a venv assembled earlier.
    Assert-TorchAppOrtChainOnly -Python $venvPython -Store $WheelDir
    $verifyPy = Join-Path $env:TEMP 'verify-torch-app.py'
    $gpuLane = ($env:GPU_TYPE -eq 'nvidia')
    # The staged verify script must not ride into the layer on the failure path either.
    try {
        Set-Content -Path $verifyPy -Encoding ASCII -Value @'
import os
import sys
os.environ.setdefault('OPENCV_LOG_LEVEL', 'ERROR')
import numpy
print('numpy', numpy.__version__)
import cv2
print('cv2', cv2.__version__)
import torch
print('torch', torch.__version__)
import onnxruntime
providers = onnxruntime.get_available_providers()
print('onnxruntime', onnxruntime.__version__, providers)
import onnxruntime_genai
print('onnxruntime-genai', getattr(onnxruntime_genai, '__version__', 'n/a'))
import tvm
print('tvm', tvm.__version__)
import av
print('pyav', av.__version__)
import iree.compiler
import iree.runtime
print('iree-compiler', getattr(iree.compiler, '__version__', 'n/a'))
if '--require-cuda-ep' in sys.argv:
    assert 'CUDAExecutionProvider' in providers, 'ERROR: local onnxruntime wheel lost its CUDAExecutionProvider!'
    print('CUDAExecutionProvider present (build check, no device required)')
print('torch-app-env OK')
'@
        $cudaFlag = if ($gpuLane) { ' --require-cuda-ep' } else { '' }
        [void](Invoke-ShieldedNative -Label 'venv import verification' -CommandLine """$venvPython"" ""$verifyPy""$cudaFlag")
    } finally {
        Remove-Item $verifyPy -Force -ErrorAction SilentlyContinue
    }
    # The app's own wheel-smoke suite, which upstream designed to gate container builds.
    [void](Invoke-ShieldedNative -Label 'app smoke suite (python -m orchestrant.smoke)' `
            -CommandLine """$venvPython"" -m orchestrant.smoke")
    [void](Invoke-ShieldedNative -Optional -Label 'uv pip list' -CommandLine "uv pip list --python ""$venvPython""")
    Write-Host '=== torch app: verify complete ==='
}

if ($Mode -in @('install', 'all')) { Install-TorchAppEnvironment }
if ($Mode -in @('verify', 'all')) { Test-TorchAppEnvironment }

# pwsh -File propagates the last native exit code otherwise; real failures throw above.
exit 0
