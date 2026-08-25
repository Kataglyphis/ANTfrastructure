# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
<#
.SYNOPSIS
    Stages the PyPI runtime dependencies of the bundle's own wheels for the
    TARGET platform tag, and gates that every Requires-Dist resolves inside the
    wheel store (backlog #126, 2026-08-25).
.DESCRIPTION
    On the amd64 lane every dependency is pip-installed into the shipped
    interpreter itself. On a cross lane nothing can be installed into the target
    interpreter (it cannot run here), so the consumer-side audit found the
    device would have our onnxruntime / onnxruntime_genai / av wheels and cv2 --
    and no numpy, no packaging, no protobuf, nothing they import. This stage:
      1. reads Requires-Dist from every wheel in the store (its dist-info
         METADATA), drops `extra ==` markers, adds numpy for cv2 (which ships
         no metadata of its own);
      2. runs the HOST pip in DOWNLOAD mode for the TARGET: --platform
         <win_arm64> --python-version <X.Y> --implementation cp --only-binary=:all:
         -- pip resolves transitively and picks pure (`none-any`) or
         target-tagged wheels, never a host one;
      3. gates: every Requires-Dist name of every wheel in the store must map
         to a wheel in the store, and every downloaded wheel must be pure or
         carry the target tag (native members PE-checked through
         Assert-WheelTargetArch). A missing upstream wheel FAILS the lane --
         that is the honest answer; add it to -KnownUnavailable WITH a reason
         only after measuring.
    Runs in the merge stage (both lanes present there): a notice and exit 0
    on the native lane, the full staging + gate on a cross lane.
#>
param(
    [string]$WheelDir = 'C:\runtime\wheels',
    # Regex of distribution names allowed to be missing, each with a recorded
    # reason in docs/windows-builds.md (#126). Empty = nothing may be missing.
    [string]$KnownUnavailable = '',
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

if (-not (Test-WindowsCrossTarget)) {
    Write-Host 'Target python deps: native lane -- every dependency is installed into the shipped interpreter itself (smoke section 20 proves the imports); nothing to stage'
    exit 0
}

$targetTag = Get-PythonWheelTag
$py = Get-SourceBuildPython
if (-not (Test-Path $py.Exe)) { throw "Target python deps: host build interpreter missing at $($py.Exe)" }
$pyVer = (& $py.Exe -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>&1 | Select-Object -Last 1).Trim()
if ($pyVer -notmatch '^\d+\.\d+$') { throw "Target python deps: could not read the interpreter version ('$pyVer')" }
$abiTag = 'cp' + ($pyVer -replace '\.', '')
New-Item -Path $WheelDir -ItemType Directory -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-WheelDistName([string]$WheelFileName) {
    # PEP 427: {distribution}-{version}(-{build})?-{python}-{abi}-{platform}.whl
    return (($WheelFileName -split '-')[0] -replace '[-_.]+', '-').ToLowerInvariant()
}
function Get-RequirementName([string]$Requirement) {
    # "numpy>=1.21.6", "coloredlogs", "protobuf (>=3.20)", "foo[bar] ; extra == 'x'"
    $m = [regex]::Match($Requirement.Trim(), '^([A-Za-z0-9][A-Za-z0-9._-]*)')
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace '[-_.]+', '-').ToLowerInvariant()
}
function Get-WheelRequirements([string]$WheelPath) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        $meta = $zip.Entries | Where-Object { $_.FullName -match '^[^/]+\.dist-info/METADATA$' } | Select-Object -First 1
        if (-not $meta) { throw "wheel $WheelPath has no dist-info/METADATA" }
        $reader = New-Object System.IO.StreamReader($meta.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $reqs = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -eq '') { break }   # headers end at the first blank line (the description follows)
        if ($line -match '^Requires-Dist:\s*(.+)$') {
            $r = $Matches[1].Trim()
            if ($r -match ';\s*extra\s*==') { continue }   # optional extras are not first-touch deps
            $reqs += $r
        }
    }
    return $reqs
}

# 1. What our wheels need.
$ourWheels = @(Get-ChildItem -Path $WheelDir -Filter '*.whl' -File)
if ($ourWheels.Count -eq 0) { throw "Target python deps: no wheels in $WheelDir -- the media branches did not stage their wheels (ORT/GenAI/PyAV)" }
$requirements = [System.Collections.Generic.List[string]]::new()
foreach ($w in $ourWheels) {
    foreach ($r in (Get-WheelRequirements $w.FullName)) { if (-not $requirements.Contains($r)) { $requirements.Add($r) } }
}
if (-not ($requirements | Where-Object { (Get-RequirementName $_) -eq 'numpy' })) { $requirements.Add('numpy') }   # cv2 imports numpy; the installed module carries no metadata
Write-Host "Target python deps: $($ourWheels.Count) bundle wheel(s) declare $($requirements.Count) first-touch requirement(s): $($requirements -join ' | ')"

# 2. Download for the TARGET with the HOST pip -- but only what the bundle does not
#    provide itself. onnxruntime-genai's METADATA says `onnxruntime-directml>=1.29`,
#    and that wheel IS the bundle's own ORT wheel sitting next to it; asking PyPI for
#    it fails on arm64 ("from versions: none" -- Microsoft publishes no win_arm64
#    onnxruntime-directml wheel; measured arm64 run 12, 2026-08-25). Gate (b) below
#    still checks that edge against the store, so nothing is skipped, only not
#    re-downloaded.
$bundled = @{}
foreach ($w in $ourWheels) { $bundled[(Get-WheelDistName $w.Name)] = $w.Name }
$external = @($requirements | Where-Object { $n = Get-RequirementName $_; -not ($n -and $bundled.ContainsKey($n)) })
$inBundle = @($requirements | Where-Object { $n = Get-RequirementName $_; $n -and $bundled.ContainsKey($n) })
if ($inBundle.Count -gt 0) { Write-Host "Target python deps: $($inBundle.Count) requirement(s) satisfied by the bundle's own wheels, not downloaded: $($inBundle -join ' | ')" }
if ($external.Count -gt 0) {
    $pipArgs = @('-m', 'pip', 'download', '--only-binary=:all:', '--platform', $targetTag, '--python-version', $pyVer,
                 '--implementation', 'cp', '--abi', $abiTag, '--abi', 'none', '--abi', 'abi3', '-d', $WheelDir, '--disable-pip-version-check') + $external
    Write-Host "Target python deps: pip download for $targetTag / cp$($pyVer -replace '\.','') into $WheelDir : $($external -join ' | ')"
    [void](Invoke-ShieldedNative -Label 'pip download (target platform)' -CommandLine ("""$($py.Exe)"" " + (($pipArgs | ForEach-Object { if ($_ -match '[\s<>=!~;]') { '"' + $_ + '"' } else { $_ } }) -join ' ')))
} else {
    Write-Host "Target python deps: nothing external to download -- every first-touch requirement is a bundle wheel"
}

# 3. Gate. (a) every wheel in the store is pure or target-tagged (natives PE-checked);
#          (b) every Requires-Dist of every wheel in the store resolves to a wheel in the store.
$store = @(Get-ChildItem -Path $WheelDir -Filter '*.whl' -File)
$available = @{}
foreach ($w in $store) {
    $available[(Get-WheelDistName $w.Name)] = $w.Name
    if ($w.Name -match "-$targetTag\.whl$") { Assert-WheelTargetArch -WheelPath $w.FullName }
    elseif ($w.Name -notmatch '-none-any\.whl$') { throw "Target python deps: $($w.Name) is neither a pure wheel (none-any) nor tagged $targetTag -- a wrong-platform wheel landed in the store" }
}
$missing = @()
foreach ($w in $store) {
    foreach ($r in (Get-WheelRequirements $w.FullName)) {
        $n = Get-RequirementName $r
        if ($n -and -not $available.ContainsKey($n)) { $missing += "$($w.Name) -> $r" }
    }
}
if (-not $available.ContainsKey('numpy')) { $missing += "cv2 -> numpy" }
$unexplained = @($missing | Where-Object { -not ($KnownUnavailable -and ($_ -match $KnownUnavailable)) })
Write-Host ("Target python deps: store holds {0} wheel(s); {1} requirement edge(s) unresolved ({2} known-unavailable)" -f $store.Count, $missing.Count, ($missing.Count - $unexplained.Count))
if ($unexplained.Count -gt 0) {
    $unexplained | ForEach-Object { Write-Host "  MISSING: $_" -ForegroundColor Red }
    throw "Target python deps: $($unexplained.Count) requirement(s) have no wheel in $WheelDir for $targetTag -- the device could not import the bundle's Python surface (#126). Stage them, or record a measured reason in -KnownUnavailable."
}
Write-Host "Target python deps OK: every Requires-Dist of the $($store.Count) staged wheels resolves inside $WheelDir for $targetTag"
exit 0
