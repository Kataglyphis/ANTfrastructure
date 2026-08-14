# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Renames the extracted TensorRT-<version>\ tree to a STABLE 'current\' so that
# nothing downstream has to spell the version (backlog #38).
#
# WHY
# ---
# Dockerfile.nvidia built the runtime PATH out of the pin:
#     ENV PATH=...;$TENSORRT_ROOT\TensorRT-$TENSORRT_VERSION\lib;$PATH
# while setup-tensorrt.ps1 extracts whatever the staged archive contains and
# resolves it with a GLOB. The two disagreed the moment the pin was bumped
# without re-staging the zip (2026-08-14: pin 11.2.1.2 vs a staged
# TensorRT-11.1.0.106 zip), putting a NONEXISTENT directory on PATH. Nothing
# failed: ONNX compiled the EP against the real 11.1 headers (the glob resolved
# correctly) and logged `onnxruntime_USE_TENSORRT=ON`, so the build was green
# and the DLLs were merely unreachable at RUNTIME — ORT then dropped the
# TensorRT EP with no error. versions.env already documents this exact incident
# and the rule it broke ("Bump this WITH the staged zip, never alone"); it
# recurred anyway, because nothing ENFORCED it.
#
# A Machine-PATH write cannot fix this: Dockerfile.base sets `ENV PATH=...`
# explicitly, so the image config wins and a registry PATH written inside a RUN
# is invisible to later stages. A stable DIRECTORY NAME is the fix that works
# with the ENV, not against it.
#
# Runs in the `trt-extract` stage, so the rename costs nothing at image size:
# only C:\tensorrt is carried forward by `COPY --from=trt-extract`.
[CmdletBinding()]
param(
    [string]$TensorRtRoot = 'C:\tensorrt',
    # Reported only — never used to build a path.
    [string]$ExpectedVersion = $env:TENSORRT_VERSION
)
$ErrorActionPreference = 'Stop'

$stable = Join-Path $TensorRtRoot 'current'

if (-not (Test-Path $TensorRtRoot)) {
    Write-Host "TensorRT: '$TensorRtRoot' absent -> nothing to normalize (EP skipped downstream)."
    return
}
if (Test-Path $stable) {
    Write-Host "TensorRT: '$stable' already present -> nothing to normalize."
    return
}

$versionDir = Get-ChildItem -LiteralPath $TensorRtRoot -Directory -Filter 'TensorRT-*' -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -First 1

if (-not $versionDir) {
    # Flat layout (setup-tensorrt.ps1 tolerates it) or the supported zip-less
    # build. Both are legitimate; only a half-extracted tree is not.
    if (Test-Path (Join-Path $TensorRtRoot 'lib')) {
        Write-Host "TensorRT: flat layout at '$TensorRtRoot' -> consumers use the root directly."
    } else {
        Write-Host "TensorRT: '$TensorRtRoot' holds no versioned tree -> EP skipped (supported: no zip staged)."
    }
    return
}

$actual = $versionDir.Name -replace '^TensorRT-', ''
if ($ExpectedVersion -and $actual -ne $ExpectedVersion) {
    # Loud, but NOT fatal: the staged zip is the truth for this image, and the
    # pin is also consumed by the Linux lane (apt), where it may legitimately
    # differ. The point is that drift can no longer be SILENT.
    Write-Warning ("TensorRT PIN DRIFT: versions.env says TENSORRT_VERSION=$ExpectedVersion but the staged zip " +
                   "extracted TensorRT-$actual. This image ships $actual and is internally consistent — but the " +
                   'pin no longer describes what ships. Re-stage the zip or correct the pin.')
}

Rename-Item -LiteralPath $versionDir.FullName -NewName 'current'

# Fail CLOSED: a tree that exists without loadable DLLs is the failure this
# whole script exists to prevent, and it must not reach a downstream stage.
$libDir = Join-Path $stable 'lib'
if (-not (Test-Path $libDir)) {
    throw "TensorRT tree '$($versionDir.Name)' has no lib\ directory after normalization — refusing to ship a partial extract."
}
$dlls = @(Get-ChildItem -LiteralPath $libDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)
if ($dlls.Count -eq 0) {
    throw "TensorRT lib directory '$libDir' contains no DLLs — the EP would be dropped silently at runtime."
}
Write-Host "TensorRT $actual normalized to '$stable' ($($dlls.Count) DLLs in lib\)."
