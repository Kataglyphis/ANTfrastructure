# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#
# Windows mirror of linux/scripts/03-media/runtime/assemble-torch-app.sh:
# clone OrchestrANT at $AppRef, `uv sync` its environment on the
# source-built CPython, then RECONCILE so the wheels built by this lane
# (onnxruntime / onnxruntime-genai / tvm, staged at C:\runtime\wheels) always win
# over anything PyPI resolved -- remaining dependencies come from PyPI/pytorch
# index. The source-built cv2 (no wheel by design) plus the sitecustomize shim
# (platform tag + native DLL dirs) are staged into the venv, mirroring the
# linux staged-OpenCV5 handling. GUI extra (wxPython) excluded, like linux.
param(

    [string]$AppRef = '',
    [string]$AppDir = 'C:\opt\OrchestrANT',
    [string]$WheelDir = 'C:\runtime\wheels',
    [ValidateSet('install', 'verify', 'all')][string]$Mode = 'all',
    # Torch BACKEND extra (torch is declared ONLY inside these extras in the
    # app's pyproject -- see the linux script's 2026-07-12 lesson): pytorch-cpu
    # (default), pytorch-cu130, ... 'none' disables.
    [string]$PytorchExtra = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Canonical stderr-shielded native runner (this script's local Invoke-TorchAppNative
# was the prototype; it is now promoted to WindowsNative.Common.psm1 and consumed
# from there). This script runs in the torch stage, where the whole modules dir
# is COPY'd.
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$nativeModulePath = Join-Path $scriptAssetRoot 'modules\WindowsNative.Common.psm1'
if (-not (Test-Path $nativeModulePath)) { throw "Required module not found: $nativeModulePath" }
Import-Module $nativeModulePath -Force

# The else-literal must equal versions.env APP_REF; SourceBuild.PinParity gates
# exactly that, and it had drifted a patch behind (v0.0.27 vs v0.0.28), which
# means an unattended run with no APP_REF in the environment built the wrong tag.
if ([string]::IsNullOrWhiteSpace($AppRef)) { $AppRef = if ($env:APP_REF) { $env:APP_REF } else { 'v0.0.28' } }
if ([string]::IsNullOrWhiteSpace($PytorchExtra)) { $PytorchExtra = if ($env:PYTORCH_EXTRA) { $env:PYTORCH_EXTRA } else { 'pytorch-cpu' } }

$cpythonExe = 'C:\temp\cpython\PCbuild\amd64\python.exe'
$baseSite = 'C:\temp\cpython\Lib\site-packages'
$venvDir = Join-Path $AppDir '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$venvSite = Join-Path $venvDir 'Lib\site-packages'

# Verbatim copy of linux/scripts/03-media/runtime/ort-venv-census.py, which the Linux lane runs;
# TorchApp.OrtCensus.Tests.ps1 pins the two together.
function Get-TorchAppOrtCensusSource {
    return @'
#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""ONNX Runtime census of one Python environment: every ORT distribution is a chain wheel.

Run by the interpreter under test: `python -I ort-venv-census.py --check|--purge-list --store DIR`.
assemble-torch-app.sh runs this file; Build-TorchApp.ps1 embeds it verbatim.
Verdicts and fixes: docs/failure-modes.md#the-torch-stage-fails-with-ort-census-fail

NOT covered: whether the store wheel was compiled by the chain (the image census, G1); files
installed outside site-packages; ORT bytes vendored under another name and import package (G1).
"""
import argparse
import hashlib
import importlib.metadata as md
import importlib.util
import os
import re
import sys
import zipfile
from email.parser import HeaderParser

ORT_DIST = re.compile(r"^onnxruntime(-|$)")
ORT_RUNTIME = re.compile(r"^onnxruntime(-(?!genai$|extensions$)[a-z0-9]+)?$")
ORT_PACKAGES = ("onnxruntime", "onnxruntime_genai", "onnxruntime_extensions")
DATA_LIB = re.compile(r"^[^/]+\.data/(?:purelib|platlib)/(.+)$")
WHEEL_METADATA = re.compile(r"^[^/]+\.dist-info/METADATA$")


def norm(name):
    return re.sub(r"[-_.]+", "-", name or "").lower()


def sha256(stream):
    return hashlib.file_digest(stream, "sha256").hexdigest()


def real(path):
    return os.path.normcase(os.path.realpath(path))


def header(dist, key):
    meta = dist.metadata
    return (meta.get(key) if meta is not None else None) or ""


def payload(member):
    """Where a wheel member lands under site-packages; None for metadata and non-lib .data."""
    top = member.split("/", 1)[0]
    if member.endswith("/") or top.endswith(".dist-info"):
        return None
    lib = DATA_LIB.match(member)
    if lib:
        return lib.group(1)
    return None if top.endswith(".data") else member


def listed(dist):
    """The RECORD's site-packages payload: no metadata, no ../ launchers, no bytecode."""
    out = set()
    for path in dist.files or ():
        parts = path.parts
        if parts and parts[0] != ".." and not parts[0].endswith(".dist-info") and "__pycache__" not in parts:
            out.add("/".join(parts))
    return out


def packages(dist):
    tops = {rel.split("/", 1)[0].split(".", 1)[0] for rel in listed(dist)}
    tops.update((dist.read_text("top_level.txt") or "").split())
    return sorted(t for t in tops if t in ORT_PACKAGES)


def candidates():
    """{(name, site): (dist, owned packages)} for every ORT distribution on sys.path."""
    found = {}
    for dist in md.distributions():
        name = norm(header(dist, "Name"))
        key = (name, real(str(dist.locate_file(""))))
        owns = packages(dist)
        if (ORT_DIST.match(name) or owns) and key not in found:
            found[key] = (dist, owns)
    return found


def label(key, dist):
    return "%s %s at %s" % (key[0] or "<unnamed>", header(dist, "Version") or "?", os.path.realpath(str(dist.locate_file(""))))


def summary(paths, what):
    return "%d file(s) %s, e.g. %s" % (len(paths), what, ", ".join(sorted(paths)[:3]))


def store_index(store):
    """{(name, version): wheel path} from each store wheel's own METADATA."""
    index = {}
    for entry in sorted(os.listdir(store)):
        if not entry.endswith(".whl"):
            continue
        path = os.path.join(store, entry)
        with zipfile.ZipFile(path) as whl:
            meta = [n for n in whl.namelist() if WHEEL_METADATA.match(n)]
            head = HeaderParser().parsestr(whl.read(meta[0]).decode("utf-8", "replace")) if len(meta) == 1 else {}
        index[(norm(head.get("Name")), head.get("Version") or "")] = path
    return index


def compare(dist, wheel):
    """What differs between an installed distribution and its store wheel; empty = same bytes."""
    if dist.files is None:
        return ["has no RECORD, so its files cannot be proven"]
    missing, differ, members = [], [], set()
    with zipfile.ZipFile(wheel) as whl:
        for member in whl.namelist():
            rel = payload(member)
            if rel is None:
                continue
            members.add(rel)
            path = str(dist.locate_file(rel))
            if not os.path.isfile(path):
                missing.append(rel)
                continue
            with whl.open(member) as want, open(path, "rb") as have:
                if sha256(want) != sha256(have):
                    differ.append(rel)
    extra = listed(dist) - members
    return [summary(paths, what) for paths, what in (
        (differ, "differ from the chain wheel's bytes"),
        (missing, "of the chain wheel are missing"),
        (extra, "are installed but not in the chain wheel")) if paths]


def import_findings(pkg, owners):
    """The import must resolve to an owner's file, and the package dir may hold only owned files."""
    try:
        spec = importlib.util.find_spec(pkg)
    except (ImportError, ValueError) as exc:
        return ["%s cannot be located: %s" % (pkg, exc)]
    if spec is None:
        return ["import onnxruntime finds nothing"] if pkg == "onnxruntime" else []
    owned = {real(str(d.locate_file(rel))) for d in owners for rel in listed(d)}
    out = []
    if spec.origin and real(spec.origin) not in owned:
        out.append("import %s resolves to %s, which no owning distribution installed" % (pkg, spec.origin))
    stray = []
    for where in spec.submodule_search_locations or ():
        for base, dirs, names in os.walk(where):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            stray.extend(os.path.join(base, n) for n in names if real(os.path.join(base, n)) not in owned)
    if stray:
        out.append(summary(stray, "in the %s package are in no owner's RECORD" % pkg))
    return out


def owner_findings(found):
    findings = []
    for pkg in ORT_PACKAGES:
        owners = [key for key in sorted(found) if pkg in found[key][1]]
        if len(owners) > 1 or (pkg == "onnxruntime" and not owners):
            want = "exactly one" if pkg == "onnxruntime" else "at most one"
            names = "; ".join(label(k, found[k][0]) for k in owners) or "none"
            findings.append("the %s import package has %d owners (%s), expected %s" % (pkg, len(owners), names, want))
        findings.extend(import_findings(pkg, [found[k][0] for k in owners]))
    return findings


def check(store):
    """(findings, chain labels) for the environment against the chain wheel store."""
    index = store_index(store)
    findings, chain = [], []
    if not any(ORT_RUNTIME.match(name) for name, _ in index):
        findings.append("the chain wheel store %s holds no onnxruntime wheel" % store)
    found = candidates()
    for key in sorted(found):
        dist = found[key][0]
        wheel = index.get((key[0], header(dist, "Version")))
        if wheel is None:
            findings.append("%s is not a chain wheel: the store %s has no wheel of that name and version" % (label(key, dist), store))
            continue
        problems = compare(dist, wheel)
        findings.extend("%s: %s" % (label(key, dist), p) for p in problems)
        if not problems:
            chain.append("%s = %s" % (label(key, dist), os.path.basename(wheel)))
    findings.extend(owner_findings(found))
    return findings, chain


def main(argv=None):
    parser = argparse.ArgumentParser(description="ONNX Runtime census of this interpreter's environment")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="fail unless every ORT distribution is a chain wheel")
    mode.add_argument("--purge-list", action="store_true", help="print the ORT distributions to uninstall")
    parser.add_argument("--store", default="", help="the chain wheel store")
    args = parser.parse_args(argv)
    if args.purge_list:
        for name in sorted({key[0] for key in candidates() if key[0]}):
            print("ORT-CENSUS PURGE %s" % name)
        return 0
    try:
        findings, chain = check(args.store)
    except Exception as exc:  # an unreadable environment is a failure, never a pass
        findings, chain = ["the census could not complete: %s: %s" % (type(exc).__name__, exc)], []
    for line in chain:
        print("ORT-CENSUS chain %s" % line)
    for finding in findings:
        print("ORT-CENSUS FAIL %s" % finding)
    if findings:
        print("ORT-CENSUS FAILED: %d finding(s)" % len(findings))
        return 1
    print("ORT-CENSUS PASS: %d chain distribution(s) from %s" % (len(chain), args.store))
    return 0


if __name__ == "__main__":
    sys.exit(main())
'@
}

# Runs the census in -Python with -I, the program on stdin; returns its exit code and output.
# A missing interpreter throws, so a stale $LASTEXITCODE can never read as a verdict.
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
    $text = [System.IO.File]::ReadAllText($LockPath)
    $tables = [regex]::Matches($text, '(?m)^\[\[package\]\]\r?$').Count
    $names = @([regex]::Matches($text, '(?m)^name = "([^"\r\n]*)"\r?$') | ForEach-Object { ($_.Groups[1].Value -replace '[-_.]+', '-').ToLowerInvariant() })
    if (-not $tables -or $names.Count -ne $tables) { throw "cannot read the packages of ${LockPath}: $($names.Count) name(s) for $tables [[package]] table(s)" }
    $ort = @($names | Where-Object { $_ -cmatch '^onnxruntime(-|$)' } | Sort-Object -Unique)
    $bad = @($ort | Where-Object { $_ -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' })
    if ($bad.Count) { throw "${LockPath} pins an ORT name uv sync cannot be handed: $($bad -join ', ')" }
    return $ort
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

function Install-TorchAppEnvironment {
    Write-Host "=== torch app: clone $AppRef + uv sync (extras: ml-ai docs $PytorchExtra test) ==="
    if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $AppDir -Parent) | Out-Null
    [void](Invoke-ShieldedNative -Label 'git clone (app)' -CommandLine "git clone --branch $AppRef --depth 1 https://github.com/Kataglyphis/OrchestrANT.git ""$AppDir""")

    # Venv on the SOURCE-built CPython (matches our cp314 wheels; see the
    # media-merge UV_PYTHON seeding fix). copy link mode: hardlinks don't
    # survive docker layer boundaries.
    $env:UV_PYTHON = $cpythonExe
    $env:UV_LINK_MODE = 'copy'
    # No uv wheel cache: everything resolved here is installed exactly once into
    # the venv, and uv's cache (multiple GB of torch/onnxruntime wheels) would
    # otherwise be committed into the torch layer.
    $env:UV_NO_CACHE = '1'

    Push-Location $AppDir
    try {
        $extraArgs = '--extra ml-ai --extra docs'
        if ($PytorchExtra -and $PytorchExtra -ne 'none') { $extraArgs += " --extra $PytorchExtra" }
        if ($env:SKIP_TORCH_TEST_EXTRAS -ne 'true') { $extraArgs += ' --extra test' }
        # ai-edge-litert: ml-ai pins 2.1.3, which ships NO cp314 wheel (cp311-313
        # only) and is the one family this lane cannot build (LiteRT python is
        # bazel-only on Windows; linux serves it from a locally-built wheel via
        # the same --no-install-package mechanism). The app's LiteRT code path is
        # therefore unavailable in this venv -- documented limitation.
        $baseSyncArgs = "--find-links ""$WheelDir"" $extraArgs --no-install-package ai-edge-litert"
        $lockPath = Join-Path $AppDir 'uv.lock'

        # Frozen first when the repo ships a lock; regenerate on failure
        # (this Python/platform may not be covered by the upstream lock).
        $haveLock = Test-Path $lockPath
        $frozenOk = $false
        if ($haveLock) {
            # Outside the try: a missing chain wheel stops the stage instead of regenerating the lock.
            $syncArgs = "$baseSyncArgs $(Get-TorchAppOrtSyncArg -LockPath $lockPath -Store $WheelDir)"
            try { [void](Invoke-ShieldedNative -Label 'uv sync --frozen' -CommandLine "uv sync $syncArgs --frozen"); $frozenOk = $true }
            catch { Write-Warning "frozen upstream uv.lock failed for this Python/platform -- regenerating a local lock ($($_.Exception.Message))" }
        }
        if (-not $frozenOk) {
            [void](Invoke-ShieldedNative -Label 'uv lock' -CommandLine "uv lock --find-links ""$WheelDir""")
            $syncArgs = "$baseSyncArgs $(Get-TorchAppOrtSyncArg -LockPath $lockPath -Store $WheelDir)"
            [void](Invoke-ShieldedNative -Label 'uv sync' -CommandLine "uv sync $syncArgs")
        }

        # -- Reconcile (linux reconcile_local_wheels): our source builds WIN. --
        # Uninstall any PyPI build of a family we ship locally BEFORE
        # force-reinstalling, so a transitively-pulled upstream (onnxruntime-gpu,
        # opencv-python 4.x) cannot shadow the custom build.
        # ORT names come from the census, never a fixed list: a variant missing from a list stays beside the chain wheel.
        $ortPurge = @(Get-TorchAppOrtPurgeName -Python $venvPython -Store $WheelDir)
        Write-Host "ORT distributions the chain wheels replace: $(if ($ortPurge.Count) { $ortPurge -join ', ' } else { 'none' })"
        [void](Invoke-ShieldedNative -Optional -Label 'uninstall pypi onnx/genai/opencv families' `
                -CommandLine "uv pip uninstall --python ""$venvPython"" $($ortPurge -join ' ') opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless")
        $localWheels = @(Get-ChildItem -Path $WheelDir -Filter '*.whl' -ErrorAction SilentlyContinue | ForEach-Object { '"{0}"' -f $_.FullName })
        if ($localWheels.Count -eq 0) { throw "no local wheels found in $WheelDir -- the media build should have staged onnxruntime/genai/tvm" }
        # --no-deps is REQUIRED: onnxruntime_genai_cuda declares its dependency as
        # `onnxruntime-gpu`, but this lane ships the combined `onnxruntime` wheel
        # (CUDA+TRT+DML in one) -- letting uv resolve that metadata is unsatisfiable
        # on cp314 and would shadow our build even if it resolved. (linux dodges
        # this by PRUNING genai wheels on plain-onnxruntime lanes; we want genai.)
        [void](Invoke-ShieldedNative -Label 'force-reinstall local wheels (no-deps)' `
                -CommandLine "uv pip install --python ""$venvPython"" --force-reinstall --no-deps $($localWheels -join ' ')")
        # Stage from the base interpreter's site-packages (venvs do not see it):
        # - cv2: no wheel exists by design (opencv-python is a separate project)
        # - tvm_ffi: tvm 0.25's FFI split makes it a hard top-level import, and
        #   the version our tvm build installed (0.1.12 final) has NO usable
        #   PyPI wheel (only 0.1.12rc0 sdist/rc) -- copy the working one
        # - sitecustomize.py: win-amd64 tag + add_dll_directory for the image's
        #   native DLL homes (everything else is lazy/optional or rides the app
        #   lock; force-adding e.g. ml_dtypes drags a cp314-less sdist build in)
        # ml_dtypes: iree.runtime hard-imports it; our wheels install --no-deps
        # here and the app lock does not carry it, so stage the base copy (pip
        # resolution risks a cp314-less sdist -- same reason as tvm_ffi).
        foreach ($staged in @('cv2', 'tvm_ffi', 'ml_dtypes', 'sitecustomize.py')) {
            $src = Join-Path $baseSite $staged
            if (Test-Path $src) {
                Copy-Item $src -Destination $venvSite -Recurse -Force
                Write-Host "Staged $staged into venv site-packages"
            } elseif ($staged -eq 'sitecustomize.py') {
                # HARD fail (2026-08-21): unlike cv2/tvm_ffi/ml_dtypes, nothing
                # downstream ever imports sitecustomize explicitly — a missing
                # copy silently drops the win-amd64 platform tag AND the
                # add_dll_directory calls for the image's native DLL homes,
                # and Test-TorchAppEnvironment cannot catch it.
                throw "$src not found -- the venv would silently lose the platform tag + DLL-dir wiring"
            } else {
                Write-Warning "$src not found -- venv will miss $staged"
            }
        }
        # abi3 wheels (IREE's cp312-abi3 pyds) link python3.dll, which uv venvs
        # do NOT stage next to their python.exe -- the import then dies with
        # STATUS_DLL_NOT_FOUND (same trap PyAV hit in the pip-route spikes).
        # Copy it from the source CPython beside the venv interpreter.
        $venvScripts = Split-Path $venvPython -Parent
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
    # try/finally: the staged verify script must not survive this function on the
    # FAILURE path either (it would otherwise ride into the layer/debug image).
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
    # The app's OWN wheel-smoke suite ("exercise the installed ML wheels with
    # real work"; exits non-zero on any required failure -- upstream designed it
    # to gate container builds). Expected report on this lane: 10/11 ok on app
    # v0.0.24/v0.0.25 (pyav check on top of v0.0.23's genai + tvm), 11/12 ok
    # once a tag ships the iree check -- always with ONE WARN (ai-edge-litert,
    # skipped by design: no cp314 wheel exists).
    [void](Invoke-ShieldedNative -Label 'app smoke suite (python -m orchestrant.smoke)' `
            -CommandLine """$venvPython"" -m orchestrant.smoke")
    [void](Invoke-ShieldedNative -Optional -Label 'uv pip list' -CommandLine "uv pip list --python ""$venvPython""")
    Write-Host '=== torch app: verify complete ==='
}

if ($Mode -in @('install', 'all')) { Install-TorchAppEnvironment }
if ($Mode -in @('verify', 'all')) { Test-TorchAppEnvironment }

# Explicit success: pwsh -File (and docker RUN) propagate the LAST native exit
# code otherwise. Real failures throw above; reaching EOF IS success.
exit 0