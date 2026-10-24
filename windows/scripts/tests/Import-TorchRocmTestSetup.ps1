#requires -Version 7.0

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNative.Common.psm1') -DisableNameChecking
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the probe on the image's CPython, and the source build (Torch.RocmSourceBuild.Tests.ps1).

$script:TorchRocmScript = 'windows\scripts\build\Install-TorchRocm.ps1'
$script:TorchRocmCheck = 'windows\scripts\build\rocm-checks\Torch.ps1'
# Everything the pinned-set functions call, lifted together.
$script:TorchRocmSetFunction = @('Get-TorchRocmPinMap', 'ConvertFrom-TorchRocmFileName',
    'Get-TorchRocmPinnedFile', 'Get-TorchRocmGpuTarget', 'Get-TorchRocmWheelSet', 'Add-TorchRocmWheelFileFacts', 'Get-TorchRocmBuiltWheel')
# The torch-rocm-wheels stage's two wheels as this versions.env builds them: their local version is the ROCm release.
$script:TorchRocmVersions = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
$script:TorchRocmRelease = $script:TorchRocmVersions['ROCM_WINDOWS_RELEASE']
# The app venv's tag: the image interpreter, PYTHON_VERSION.
$script:TorchRocmVenvTag = 'cp' + (($script:TorchRocmVersions['PYTHON_VERSION'] -split '\.')[0..1] -join '')
$script:TorchRocmBuiltName = @('torch-2.14.0', 'torchvision-0.29.0' | ForEach-Object { "$_+rocm$($script:TorchRocmRelease)-$($script:TorchRocmVenvTag)-$($script:TorchRocmVenvTag)-win_amd64.whl" })

# A WheelDir holding $Name (default: the two built wheels) as small fake files.
function New-TorchRocmBuiltWheelDir {
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Name = $script:TorchRocmBuiltName)
    $wheels = Join-Path $Dir 'torch-rocm-wheels'
    $files = [ordered]@{}
    foreach ($n in $Name) { $files[$n] = "PK $n" }
    Write-TestFileTree -Root $wheels -Files $files
    if ($Name.Count -eq 0) { [void][System.IO.Directory]::CreateDirectory($wheels) }
    return $wheels
}

# The two built wheels as parsed file objects, no files needed (the venv-fit and requirement cases).
function Get-TorchRocmBuiltWheelFact {
    foreach ($n in $script:TorchRocmBuiltName) {
        $path = "C:\bkmnt\torch-rocm-wheels\$n"
        $w = ConvertFrom-TorchRocmFileName -Url ([uri]$path).AbsoluteUri
        Add-TorchRocmWheelFileFacts -Wheel $w -LocalPath $path -Sha256 ('a' * 64)
    }
}


function Get-TorchRocmTestPin {
    # versions.env as the build sees it (a fresh copy per call, so a case may mutate it).
    $all = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    $pins = @{}
    foreach ($k in $all.Keys) { $pins[$k] = $all[$k] }
    return $pins
}

function Assert-NoTorchRocmPinKeys {
    param([Parameter(Mandatory)][hashtable]$Pins, [Parameter(Mandatory)][string]$Pattern, [string]$Message = '')
    $unexpected = @($Pins.Keys | Where-Object { $_ -match $Pattern })
    Assert-Equal '' ($unexpected -join ',') $Message
}

# The real pinned set as the build resolves it, carrying its versions.env as .Pins.
function Get-TorchRocmTestSet {
    $pins = Get-TorchRocmTestPin
    $set = Get-TorchRocmWheelSet -Pins $pins -Release $pins['ROCM_WINDOWS_RELEASE']
    return ($set | Add-Member -NotePropertyMembers @{ Pins = $pins } -PassThru)
}

# Each case edits a fresh versions.env copy (Key = Value) and/or names a Release; $Resolve must throw matching P.
function Assert-TorchRocmPinRefusal {
    param([Parameter(Mandatory)][hashtable[]]$Case, [Parameter(Mandatory)][scriptblock]$Resolve)
    foreach ($c in $Case) {
        $pins = Get-TorchRocmTestPin
        if ($c.ContainsKey('Key')) { $pins[$c.Key] = $c.Value }
        $release = if ($c.ContainsKey('Release')) { $c.Release } else { $pins['ROCM_WINDOWS_RELEASE'] }
        $label = if ($c.ContainsKey('Key')) { "$($c.Key)='$($c.Value)'" } else { 'pins as measured' }
        Assert-Throws { & $Resolve $pins $release } "$label release '$release'" -MessagePattern $c.P
    }
}

function Get-TorchDockerfileText {
    return [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile.torch'))
}

# APP_REF's default syncs from versions.env, so it is masked; editing a line here changes the cpu/nvidia image.
$script:TorchAppStageGolden = @(@'
ARG APP_REF=<versions.env>
ARG PYTORCH_EXTRA=pytorch-cpu
SHELL ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $PSNativeCommandUseErrorActionPreference = $false;"]
COPY windows\scripts\modules\WindowsNative.Common.psm1 windows\scripts\modules\WindowsTargetArch.Common.psm1 windows\scripts\modules\WindowsUvLock.Common.psm1 C:\temp\scripts\modules\
COPY linux\scripts\03-media\runtime\ort-venv-census.py C:\temp\scripts\
COPY windows\scripts\build\Build-TorchApp.ps1 C:\temp\scripts\
RUN --mount=type=cache,target=C:\uvcache,id=uv-wheels-winamd64,sharing=locked $env:UV_CACHE_DIR = 'C:\uvcache'; $env:PIP_CACHE_DIR = 'C:\uvcache\pip'; & 'C:\temp\scripts\Build-TorchApp.ps1' -AppRef $env:APP_REF -PytorchExtra $env:PYTORCH_EXTRA -Mode all
ENV TORCH_APP_DIR="C:\opt\OrchestrANT"
'@ -split '\r?\n')

# TORCH_ROCM picks only the last stage, so a golden `app` and an ARG/HEALTHCHECK/LABEL tail keep cpu/nvidia unchanged.
function Get-TorchAppStageDifference {
    param([string[]]$Lines, [string[]]$Golden)
    $actual = @($Lines | ForEach-Object { $_ -creplace '^ARG APP_REF=\S+$', 'ARG APP_REF=<versions.env>' })
    for ($index = 0; $index -lt [Math]::Max($actual.Count, $Golden.Count); $index++) {
        $got = if ($index -lt $actual.Count) { $actual[$index] } else { '<none>' }
        $want = if ($index -lt $Golden.Count) { $Golden[$index] } else { '<none>' }
        if ($got -cne $want) { return "app stage differs from the cpu/nvidia golden at instruction $($index + 1): [$got], want [$want]" }
    }
}

function Get-TorchFinalStageProblem {
    param($Stage)
    $extra = @($Stage.Lines | Where-Object { $_ -notmatch '^(ARG|HEALTHCHECK|LABEL)\s' })
    if ($extra.Count -gt 0) { "the final stage may hold only ARG, HEALTHCHECK and LABEL: $($extra -join ' || ')" }
    $declared = @($Stage.Lines | Where-Object { $_ -match '^ARG\s' } | ForEach-Object { ($_ -replace '^ARG\s+', '' -split '=')[0] })
    foreach ($match in [regex]::Matches(($Stage.Lines -join "`n"), '\$\{([A-Z_][A-Z0-9_]*)\}')) {
        $name = $match.Groups[1].Value
        if ($declared -notcontains $name) { "the final stage reads `${$name} without ARG $name (ARGs stop at FROM)" }
    }
}

function Get-TorchDockerfileProblem {
    param([string]$Text = (Get-TorchDockerfileText))
    $df = Get-TestDockerfileStages -Text $Text -JoinContinuations -IgnoreComments -TrimLines
    $byName = $df.ByName
    if ($df.Global -notcontains 'ARG TORCH_ROCM=0') { 'no global ARG TORCH_ROCM=0' }
    if ($df.Stages.Count -eq 0 -or $df.Stages[-1].From -ne 'rocm-${TORCH_ROCM}') { 'the last FROM is not rocm-${TORCH_ROCM}' }
    if (-not $byName['rocm-0'] -or $byName['rocm-0'].From -ne 'app' -or $byName['rocm-0'].Lines.Count -ne 0) { 'rocm-0 is not a bare alias of app' }
    $rocm1 = $byName['rocm-1']
    if (-not $rocm1 -or $rocm1.From -ne 'app') { 'rocm-1 does not build on app' }
    elseif (($rocm1.Lines -join "`n") -notmatch "Install-TorchRocm\.ps1' -TorchRocm 1 ") { 'rocm-1 does not pass -TorchRocm 1 literally (an env read fails open to CPU torch)' }
    $app = $byName['app']
    if (-not $app -or $app.From -ne '${BASE_IMAGE}') { return 'no app stage FROM ${BASE_IMAGE}' }
    Get-TorchAppStageDifference -Lines $app.Lines -Golden $script:TorchAppStageGolden
    Get-TorchFinalStageProblem -Stage $df.Stages[-1]
}

