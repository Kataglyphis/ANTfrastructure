# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
<#
.SYNOPSIS
    Stages the target-tagged PyPI dependencies of the bundle's wheels and gates that every Requires-Dist resolves in the store.
.DESCRIPTION
    Cross lanes only (the target interpreter cannot run here); the native lane installs its deps into the shipped interpreter.
    See docs/windows-build-invariants.md § Python bindings plumbing is load-bearing.
#>
param(
    [string]$WheelDir = 'C:\runtime\wheels',
    # The cp3XYt twins' store; empty = Get-FreeThreadedWheelStore. Their dependencies go to its deps\, so its top holds twins only.
    [string]$FreeThreadedWheelDir = '',
    # Regex of distributions allowed to be missing, each only with a measured reason; empty = none.
    [string]$KnownUnavailable = '',
    # Floors set by the driver, since vanishing requirements make the gate greener; 0 = no floor.
    [int]$MinBundleWheels = 0,
    [int]$MinFirstTouchRequirements = 0,
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
function ConvertTo-CmdSafeRequirement([string]$Requirement) {
    # PEP 508 markers may quote strings with double quotes; cmd.exe strips those, so pass the equivalent single-quoted form.
    return ($Requirement -replace '"', "'")
}
# A marker such as python_version < '3.11' decides for the TARGET, so pip's vendored packaging evaluates it there (PEP 508).
function Select-ActiveRequirement([string]$PythonExe, [string]$PythonVersion, [string]$PlatformMachine, [string[]]$Requirement) {
    $marked = @($Requirement | Where-Object { $_ -match ';' })
    if ($marked.Count -eq 0) { return @($Requirement) }
    $code = @'
import sys
from pip._vendor.packaging.requirements import Requirement
env = dict(python_version=sys.argv[1], python_full_version=sys.argv[1] + '.0', platform_machine=sys.argv[2],
           sys_platform='win32', os_name='nt', platform_system='Windows', implementation_name='cpython',
           platform_python_implementation='CPython', extra='')
for line in sys.stdin.read().splitlines():
    if line.strip():
        print(int(Requirement(line).marker.evaluate(env)))
'@
    $verdicts = @($marked | & $PythonExe -c $code $PythonVersion $PlatformMachine)
    if ($LASTEXITCODE -ne 0 -or $verdicts.Count -ne $marked.Count) {
        throw "Target python deps: could not evaluate the markers of $($marked.Count) requirement(s) (exit $LASTEXITCODE): $($marked -join ' | ')"
    }
    $inactive = @(for ($i = 0; $i -lt $marked.Count; $i++) { if ("$($verdicts[$i])".Trim() -eq '0') { $marked[$i] } })
    return @($Requirement | Where-Object { $_ -notin $inactive })
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
            if ($r -match ';\s*.*\bextra\s*==') { continue }   # optional extras are not first-touch deps, however the marker is compounded
            $reqs += $r
        }
    }
    return $reqs
}
# pip download of -Requirement for the target; a free-threaded target passes no abi3, which its ABI cannot load.
function Save-TargetRequirement([string[]]$Requirement, [string]$Dir, [string[]]$Abi, [string]$Label) {
    if (-not $Requirement) { Write-Host "Target python deps: no requirement to download for the $Label"; return }
    $pipArgs = @('-m', 'pip', 'download', '--only-binary=:all:', '--platform', $targetTag, '--python-version', $pyVer, '--implementation', 'cp') +
        @($Abi | ForEach-Object { '--abi'; $_ }) + @('-d', $Dir, '--disable-pip-version-check') + @($Requirement | ForEach-Object { ConvertTo-CmdSafeRequirement $_ })
    Write-Host "Target python deps: pip download for $targetTag / $($Abi -join ', ') into $Dir : $($Requirement -join ' | ')"
    [void](Invoke-ShieldedNative -Label "pip download ($Label)" -CommandLine ("""$($py.Exe)"" " + (($pipArgs | ForEach-Object { if ($_ -match '[\s<>=!~;]') { '"' + $_ + '"' } else { $_ } }) -join ' ')))
}
# The wheels in -Dir, none when it does not exist.
function Get-StoreWheel([string]$Dir) {
    @(Get-ChildItem -Path $Dir -Filter '*.whl' -File -ErrorAction SilentlyContinue)
}
# Each Requires-Dist of -Wheel that is active on the target, with its wheel and canonical name.
function Get-TargetRequirement([System.IO.FileInfo[]]$Wheel, [string]$PythonExe, [string]$PythonVersion, [string]$Machine) {
    foreach ($w in $Wheel) {
        foreach ($r in (Select-ActiveRequirement -PythonExe $PythonExe -PythonVersion $PythonVersion -PlatformMachine $Machine -Requirement @(Get-WheelRequirements $w.FullName))) {
            [pscustomobject]@{ Wheel = $w.Name; Requirement = $r; Name = (Get-RequirementName $r) }
        }
    }
}
# Throws for a wheel that is neither pure nor -TargetTag; returns each active Requires-Dist edge no wheel of -Wheel resolves.
function Get-UnresolvedTargetRequirement([System.IO.FileInfo[]]$Wheel, [string]$TargetTag, [string]$PythonExe, [string]$PythonVersion, [string]$Machine) {
    $available = @{}
    foreach ($w in $Wheel) {
        $available[(Get-WheelDistName $w.Name)] = $w.Name
        if ($w.Name -match "-$TargetTag\.whl$") { Assert-WheelTargetArch -WheelPath $w.FullName }
        elseif ($w.Name -notmatch '-none-any\.whl$') { throw "Target python deps: $($w.Name) is neither a pure wheel (none-any) nor tagged $TargetTag -- a wrong-platform wheel landed in the store" }
    }
    Get-TargetRequirement -Wheel $Wheel -PythonExe $PythonExe -PythonVersion $PythonVersion -Machine $Machine |
        Where-Object { $_.Name -and -not $available.ContainsKey($_.Name) } | ForEach-Object { "$($_.Wheel) -> $($_.Requirement)" }
}
# Lists each unresolved -Edge and throws with -Why; nothing to say when every edge resolved.
function Assert-TargetEdgeResolved([string[]]$Edge, [string]$Why) {
    if (-not $Edge) { return }
    $Edge | ForEach-Object { Write-Host "  MISSING: $_" -ForegroundColor Red }
    throw "Target python deps: $($Edge.Count) requirement(s) $Why"
}
# The wheels whose ABI tag a free-threaded -Abi interpreter cannot load: anything but -Abi itself and 'none'.
function Get-ForeignAbiWheel([System.IO.FileInfo[]]$Wheel, [string]$Abi) {
    @($Wheel | Where-Object { $_.BaseName.Split('-')[-2] -notin @($Abi, 'none') } | ForEach-Object Name)
}

# 1. What our wheels need.
$ourWheels = Get-StoreWheel $WheelDir
if ($ourWheels.Count -eq 0) { throw "Target python deps: no wheels in $WheelDir -- the media branches did not stage their wheels (ORT/GenAI/PyAV)" }
$requirements = [System.Collections.Generic.List[string]]::new()
foreach ($w in $ourWheels) {
    foreach ($r in (Get-WheelRequirements $w.FullName)) { if (-not $requirements.Contains($r)) { $requirements.Add($r) } }
}
if (-not ($requirements | Where-Object { (Get-RequirementName $_) -eq 'numpy' })) { $requirements.Add('numpy') }   # cv2 imports numpy; the installed module carries no metadata
Write-Host "Target python deps: $($ourWheels.Count) bundle wheel(s) declare $($requirements.Count) first-touch requirement(s): $($requirements -join ' | ')"

# A gate that gets greener as requirements vanish hides defects, such as an empty Requires-Dist parse.
if ($MinBundleWheels -gt 0 -and $ourWheels.Count -lt $MinBundleWheels) {
    throw "Target python deps: $($ourWheels.Count) bundle wheel(s) is below the floor of $MinBundleWheels — a wheel disappeared from the bundle (run-34/35 defect class)."
}
if ($MinFirstTouchRequirements -gt 0 -and $requirements.Count -lt $MinFirstTouchRequirements) {
    throw "Target python deps: $($requirements.Count) first-touch requirement(s) is below the floor of $MinFirstTouchRequirements — requirements disappeared (empty Requires-Dist = greener gate hiding a defect, run-34/35 class)."
}

# 2. Download for the target only what the bundle lacks: PyPI has no win_arm64 build of our own ORT wheel; gate (b) still checks it.
$bundled = @{}
foreach ($w in $ourWheels) { $bundled[(Get-WheelDistName $w.Name)] = $w.Name }
$external = @($requirements | Where-Object { $n = Get-RequirementName $_; -not ($n -and $bundled.ContainsKey($n)) })
$inBundle = @($requirements | Where-Object { $n = Get-RequirementName $_; $n -and $bundled.ContainsKey($n) })
if ($inBundle.Count -gt 0) { Write-Host "Target python deps: $($inBundle.Count) requirement(s) satisfied by the bundle's own wheels, not downloaded: $($inBundle -join ' | ')" }
if ($external.Count -gt 0) {
    Save-TargetRequirement -Requirement $external -Dir $WheelDir -Abi @($abiTag, 'none', 'abi3') -Label 'target platform'
} else {
    Write-Host "Target python deps: nothing external to download -- every first-touch requirement is a bundle wheel"
}

# 3. Gate: (a) every wheel is pure or target-tagged, (b) every Requires-Dist resolves inside the store.
$store = Get-StoreWheel $WheelDir
$machine = switch ($targetTag) { 'win_arm64' { 'ARM64' } 'win_amd64' { 'AMD64' } default { throw "Target python deps: no platform_machine for $targetTag" } }
$onTarget = @{ PythonExe = $py.Exe; PythonVersion = $pyVer; Machine = $machine }
$missing = @(Get-UnresolvedTargetRequirement -Wheel $store -TargetTag $targetTag @onTarget)
if (-not @($store | Where-Object { (Get-WheelDistName $_.Name) -eq 'numpy' }).Count) { $missing += "cv2 -> numpy" }
$unexplained = @($missing | Where-Object { -not ($KnownUnavailable -and ($_ -match $KnownUnavailable)) })
Write-Host ("Target python deps: store holds {0} wheel(s); {1} requirement edge(s) unresolved ({2} known-unavailable)" -f $store.Count, $missing.Count, ($missing.Count - $unexplained.Count))
Assert-TargetEdgeResolved -Edge $unexplained -Why "have no wheel in $WheelDir for $targetTag -- the device could not import the bundle's Python surface (#126). Stage them, or record a measured reason in -KnownUnavailable."
Write-Host "Target python deps OK: every Requires-Dist of the $($store.Count) staged wheels resolves inside $WheelDir for $targetTag"

# 4. The cp3XYt twins' dependencies, for the free-threaded target, into the twins' store's deps\ (BACKLOG CON79).
if (-not $FreeThreadedWheelDir) { $FreeThreadedWheelDir = Get-FreeThreadedWheelStore }
$twins = Get-StoreWheel $FreeThreadedWheelDir
if ($twins.Count -eq 0) {
    Write-Host "Target python deps: no cp3XYt twin in $FreeThreadedWheelDir, so no free-threaded dependency to stage"
    exit 0
}
$ftAbi = "${abiTag}t"
$ftDepsDir = Join-Path $FreeThreadedWheelDir 'deps'
New-Item -Path $ftDepsDir -ItemType Directory -Force | Out-Null
$twinNames = @($twins | ForEach-Object { Get-WheelDistName $_.Name })
$ftRequirements = @(Get-TargetRequirement -Wheel $twins @onTarget | Where-Object Name -NotIn $twinNames | ForEach-Object Requirement | Select-Object -Unique)
Save-TargetRequirement -Requirement $ftRequirements -Dir $ftDepsDir -Abi @($ftAbi, 'none') -Label 'free-threaded target'
$ftDeps = Get-StoreWheel $ftDepsDir
$foreign = @(Get-ForeignAbiWheel -Wheel $ftDeps -Abi $ftAbi)
if ($foreign.Count -gt 0) { throw "Target python deps: $($foreign -join ', ') in $ftDepsDir is neither $ftAbi nor ABI-free, so a free-threaded venv could not load it" }
Assert-TargetEdgeResolved -Edge @(Get-UnresolvedTargetRequirement -Wheel (@($twins) + @($ftDeps)) -TargetTag $targetTag @onTarget) `
    -Why "of the $ftAbi twins have no wheel in $FreeThreadedWheelDir or its deps\ -- a free-threaded venv on the device could not install them offline"
Write-Host "Target python deps OK ($ftAbi): the $($twins.Count) twin(s) and $($ftDeps.Count) dependency wheel(s) in deps\ resolve every Requires-Dist for $targetTag"
exit 0
