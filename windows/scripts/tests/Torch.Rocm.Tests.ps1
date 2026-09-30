#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Windows ROCm torch (Install-TorchRocm.ps1, rocm-checks\Torch.ps1, Dockerfile.torch): the lane gate, the
# pinned runtime set (both gfx120X GPUs, PyPI's ai-edge-litert) and its ROCM_WINDOWS_RELEASE coupling, the
# source-built wheels, rocBLAS GPU coverage, the venv fit, the offline install inputs, the hash cache, the
# smoke findings, the one shared venv probe, and that cpu/nvidia still build the unchanged `app` stage.
# NOT covered: the probe on the image's CPython; the source build itself (Torch.RocmSourceBuild.Tests.ps1).

$script:TorchRocmScript = 'windows\scripts\build\Install-TorchRocm.ps1'
$script:TorchRocmCheck = 'windows\scripts\build\rocm-checks\Torch.ps1'
# Everything the pinned-set functions call, lifted together.
$script:TorchRocmSetFunction = @('Get-TorchRocmPinMap', 'Get-TorchRocmExtraPinMap', 'ConvertFrom-TorchRocmFileName',
    'Get-TorchRocmPinnedFile', 'Get-TorchRocmGpuTarget', 'Get-TorchRocmWheelSet', 'Get-TorchRocmExtraWheel', 'Get-TorchRocmBuiltWheel')
# The torch-rocm-wheels stage's two wheels as this versions.env builds them.
$script:TorchRocmBuiltName = @('torch-2.14.0+rocm10.0.0-cp314-cp314-win_amd64.whl', 'torchvision-0.29.0+rocm10.0.0-cp314-cp314-win_amd64.whl')

# A WheelDir holding $Name (default: the two built wheels) as small fake files.
function New-TorchRocmBuiltWheelDir {
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Name = $script:TorchRocmBuiltName)
    $wheels = Join-Path $Dir 'torch-rocm-wheels'
    [void][System.IO.Directory]::CreateDirectory($wheels)
    foreach ($n in $Name) { [System.IO.File]::WriteAllText((Join-Path $wheels $n), "PK $n") }
    return $wheels
}

# The two built wheels as parsed file objects, no files needed (the venv-fit and requirement cases).
function Get-TorchRocmBuiltWheelFact {
    foreach ($n in $script:TorchRocmBuiltName) {
        $path = "C:\bkmnt\torch-rocm-wheels\$n"
        $w = ConvertFrom-TorchRocmFileName -Url ([uri]$path).AbsoluteUri
        $w | Add-Member -NotePropertyMembers @{ Name = $w.Distribution.ToUpperInvariant(); Url = ([uri]$path).AbsoluteUri; Sha256 = ('a' * 64); LocalPath = $path } -PassThru
    }
}

# Repo-relative, or rooted as given (a mutation run points the two paths above at mutant copies).
function Resolve-TorchRocmSuitePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-RepoRoot) $Path)
}

function Get-TorchRocmTestPin {
    # versions.env as the build sees it (a fresh copy per call, so a case may mutate it).
    $all = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    $pins = @{}
    foreach ($k in $all.Keys) { $pins[$k] = $all[$k] }
    return $pins
}

# The real pinned set as the build resolves it, carrying its versions.env as .Pins and the PyPI extras as .Extras.
function Get-TorchRocmTestSet {
    $pins = Get-TorchRocmTestPin
    $set = Get-TorchRocmWheelSet -Pins $pins -Release $pins['ROCM_WINDOWS_RELEASE']
    return ($set | Add-Member -NotePropertyMembers @{ Pins = $pins; Extras = @(Get-TorchRocmExtraWheel -Pins $pins) } -PassThru)
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

# Dockerfile.torch as stages: continuation lines joined, comments dropped.
function Get-TorchDockerfileStage {
    param([string]$Text = (Get-TorchDockerfileText))
    $lines = @(($Text -replace '[ \t]*`\r?\n\s*', ' ') -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    $stages = [System.Collections.Generic.List[object]]::new()
    $global = [System.Collections.Generic.List[string]]::new()
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^FROM\s+(?<from>\S+)(\s+AS\s+(?<name>\S+))?') {
            $current = [pscustomobject]@{ From = $Matches.from; Name = "$($Matches['name'])"; Lines = [System.Collections.Generic.List[string]]::new() }
            $stages.Add($current)
        } elseif ($null -eq $current) {
            $global.Add($line.Trim())
        } else {
            $current.Lines.Add($line.Trim())
        }
    }
    $byName = @{}; foreach ($s in $stages) { if ($s.Name) { $byName[$s.Name] = $s } }
    return [pscustomobject]@{ Global = @($global); Stages = @($stages); ByName = $byName }
}

# The cpu/nvidia `app` stage as it was before the rocm split, continuations joined; APP_REF's
# default is synced from versions.env, so masked. Editing a line here changes that image.
$script:TorchAppStageGolden = @(@'
ARG APP_REF=<versions.env>
ARG PYTORCH_EXTRA=pytorch-cpu
SHELL ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $PSNativeCommandUseErrorActionPreference = $false;"]
COPY windows\scripts\modules\WindowsNative.Common.psm1 windows\scripts\modules\WindowsTargetArch.Common.psm1 C:\temp\scripts\modules\
COPY windows\scripts\build\Build-TorchApp.ps1 C:\temp\scripts\
RUN --mount=type=cache,target=C:\uvcache,id=uv-wheels-winamd64,sharing=locked $env:UV_CACHE_DIR = 'C:\uvcache'; $env:PIP_CACHE_DIR = 'C:\uvcache\pip'; & 'C:\temp\scripts\Build-TorchApp.ps1' -AppRef $env:APP_REF -PytorchExtra $env:PYTORCH_EXTRA -Mode all
ENV TORCH_APP_DIR="C:\opt\OrchestrANT"
'@ -split '\r?\n')

# Why the cpu/nvidia image is unchanged: TORCH_ROCM only picks the last stage, `app` is the golden
# list above, and the tail holds only ARG/HEALTHCHECK/LABEL. One message per breach.
function Get-TorchDockerfileProblem {
    param([string]$Text = (Get-TorchDockerfileText))
    $df = Get-TorchDockerfileStage -Text $Text
    $byName = $df.ByName
    if ($df.Global -notcontains 'ARG TORCH_ROCM=0') { 'no global ARG TORCH_ROCM=0' }
    if ($df.Stages.Count -eq 0 -or $df.Stages[-1].From -ne 'rocm-${TORCH_ROCM}') { 'the last FROM is not rocm-${TORCH_ROCM}' }
    if (-not $byName['rocm-0'] -or $byName['rocm-0'].From -ne 'app' -or $byName['rocm-0'].Lines.Count -ne 0) { 'rocm-0 is not a bare alias of app' }
    $rocm1 = $byName['rocm-1']
    if (-not $rocm1 -or $rocm1.From -ne 'app') { 'rocm-1 does not build on app' }
    elseif (($rocm1.Lines -join "`n") -notmatch "Install-TorchRocm\.ps1' -TorchRocm 1 ") { 'rocm-1 does not pass -TorchRocm 1 literally (an env read fails open to CPU torch)' }
    $app = $byName['app']
    if (-not $app -or $app.From -ne '${BASE_IMAGE}') { return 'no app stage FROM ${BASE_IMAGE}' }
    $got = @($app.Lines | ForEach-Object { $_ -creplace '^ARG APP_REF=\S+$', 'ARG APP_REF=<versions.env>' })
    $want = $script:TorchAppStageGolden
    for ($i = 0; $i -lt [Math]::Max($got.Count, $want.Count); $i++) {
        $g = if ($i -lt $got.Count) { $got[$i] } else { '<none>' }
        $w = if ($i -lt $want.Count) { $want[$i] } else { '<none>' }
        if ($g -cne $w) { "app stage differs from the cpu/nvidia golden at instruction $($i + 1): [$g], want [$w]"; break }
    }
    $final = $df.Stages[-1]
    $extra = @($final.Lines | Where-Object { $_ -notmatch '^(ARG|HEALTHCHECK|LABEL)\s' })
    if ($extra.Count -gt 0) { "the final stage may hold only ARG, HEALTHCHECK and LABEL: $($extra -join ' || ')" }
    $declared = @($final.Lines | Where-Object { $_ -match '^ARG\s' } | ForEach-Object { ($_ -replace '^ARG\s+', '' -split '=')[0] })
    foreach ($m in [regex]::Matches(($final.Lines -join "`n"), '\$\{([A-Z_][A-Z0-9_]*)\}')) {
        $v = $m.Groups[1].Value
        if ($declared -notcontains $v) { "the final stage reads `${$v} without ARG $v (ARGs stop at FROM)" }
    }
}

Describe 'Install-TorchRocm: lane gate (cpu and nvidia unchanged)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName 'Test-TorchRocmLane')

    It 'TORCH_ROCM unset or 0 is a no-op on every lane' {
        foreach ($gpu in @('', 'cpu', 'nvidia', 'rocm')) {
            foreach ($value in @('', '0')) {
                Assert-False (Test-TorchRocmLane -TorchRocm $value -GpuType $gpu) "TORCH_ROCM='$value' GPU_TYPE='$gpu'"
            }
        }
    }

    It 'TORCH_ROCM=1 on the rocm sdk layer installs' {
        Assert-True (Test-TorchRocmLane -TorchRocm '1' -GpuType 'rocm') 'rocm lane'
    }

    It 'TORCH_ROCM=1 off the rocm lane throws instead of putting ROCm torch into a cpu/nvidia image' {
        foreach ($gpu in @('', 'cpu', 'nvidia')) {
            Assert-Throws { Test-TorchRocmLane -TorchRocm '1' -GpuType $gpu } "GPU_TYPE '$gpu'" -MessagePattern 'GPU_TYPE'
        }
    }

    It 'anything but 0 or 1 throws rather than silently meaning cpu' {
        foreach ($bad in @('true', 'yes', '2', 'on', 'rocm')) {
            Assert-Throws { Test-TorchRocmLane -TorchRocm $bad -GpuType 'rocm' } "TORCH_ROCM '$bad'" -MessagePattern "'0' or '1'"
        }
    }

    It 'the script is a no-op with TORCH_ROCM=0, before it imports or touches anything' {
        Invoke-InTestDir { param($dir)
            $script = Resolve-TorchRocmSuitePath $script:TorchRocmScript
            $cache = Join-Path $dir 'cache'
            $out = Invoke-WithEnv @{ GPU_TYPE = 'nvidia'; TORCH_ROCM = $null } {
                & pwsh -NoProfile -NonInteractive -File $script -TorchRocm '0' -AppDir (Join-Path $dir 'no-app') -WheelCache $cache 2>&1 | Out-String
            }
            Assert-Equal 0 $LASTEXITCODE "no-op exit code; output: $out"
            Assert-Match 'keeps its torch' $out 'no-op message'
            Assert-False (Test-Path $cache) 'the no-op must not create the wheel cache'
        }
    }
}

Describe 'Install-TorchRocm: pinned set (versions.env)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName $script:TorchRocmSetFunction)

    It 'versions.env carries one URL and one SHA256 key per pin name, AMD''s and the PyPI extras alike, plus the two source commits' {
        $pins = Get-TorchRocmTestPin
        $names = @((Get-TorchRocmPinMap).Keys) + @((Get-TorchRocmExtraPinMap).Keys)
        $expected = @(@($names | ForEach-Object { "TORCH_ROCM_WINDOWS_${_}_URL"; "TORCH_ROCM_WINDOWS_${_}_SHA256" }) +
            'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT' | Sort-Object)
        $actual = @($pins.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' } | Sort-Object)
        Assert-Equal ($expected -join ',') ($actual -join ',') 'TORCH_ROCM_WINDOWS_* keys'
        foreach ($k in 'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT') { Assert-Match '^[0-9a-f]{40}$' $pins[$k] $k }
    }

    It 'the real pins parse, stay on AMD''s repo and name both GPUs of the gfx120X family, gfx1201 first' {
        $set = Get-TorchRocmTestSet
        $pins = $set.Pins
        Assert-Equal 5 $set.Wheels.Count 'pinned AMD runtime files'
        Assert-Equal 'gfx1201' $set.GfxTarget 'the GPU ROCM_SDK_TARGET_FAMILY names'
        Assert-Equal 'gfx1201,gfx1200' ($set.GfxTargets -join ',') 'GPU targets, in pin order'
        $byDist = @{}; foreach ($w in $set.Wheels) { $byDist[$w.Distribution] = $w }
        foreach ($dist in 'rocm-sdk-core', 'rocm-sdk-libraries', 'rocm-sdk-device-gfx1200', 'rocm-sdk-device-gfx1201') {
            Assert-Equal $pins['ROCM_WINDOWS_RELEASE'] $byDist[$dist].Version $dist
        }
        Assert-True $byDist['rocm'].IsSdist 'rocm ships only as an sdist'
    }

    It 'no torch or torchvision wheel is pinned any more: both are built from source' {
        $pins = Get-TorchRocmTestPin
        $gone = @($pins.Keys | Where-Object { $_ -match '^TORCH_ROCM_WINDOWS_(TORCH|TORCHVISION|BOOTSTRAP|TORCH_DEVICE\w*|TORCHVISION_DEVICE\w*)_(URL|SHA256)$' })
        Assert-Equal '' ($gone -join ',') 'AMD torch pins left in versions.env'
        Assert-Equal '' (@((Get-TorchRocmPinMap).Values | Where-Object { $_ -match '^(torch|torchvision)$' }) -join ',') 'pin map'
    }

    It 'every cp wheel pinned matches PYTHON_VERSION, the interpreter the app venv is built on' {
        $set = Get-TorchRocmTestSet
        $parts = $set.Pins['PYTHON_VERSION'] -split '\.'
        $tag = "cp$($parts[0])$($parts[1])"
        $cp = @(@($set.Wheels) + @($set.Extras) | Where-Object { $_.PythonTag -like 'cp*' })
        Assert-Equal 1 $cp.Count 'cp wheels pinned (ai-edge-litert; the built wheels are held to the venv at install)'
        foreach ($w in $cp) { Assert-Equal $tag $w.PythonTag $w.FileName; Assert-Equal $tag $w.AbiTag $w.FileName }
    }

    It 'the GPU targets belong to ROCM_WINDOWS_GFX_FAMILY, the tarball the sdk layer installs' {
        $set = Get-TorchRocmTestSet
        $familyPrefix = $set.Pins['ROCM_WINDOWS_GFX_FAMILY'] -replace 'X-.*$', ''
        foreach ($gfx in $set.GfxTargets) { Assert-True ($gfx.StartsWith($familyPrefix)) "$gfx vs family $($set.Pins['ROCM_WINDOWS_GFX_FAMILY'])" }
    }

    It 'coupling: a ROCM_WINDOWS_RELEASE bump without re-pinning the wheels throws' {
        $pins = Get-TorchRocmTestPin
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release '10.1.0' } 'release drift' -MessagePattern 'ROCM_WINDOWS_RELEASE=10\.1\.0'
        $pins['TORCH_ROCM_WINDOWS_SDK_CORE_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_CORE_URL'] -replace '10\.0\.0', '10.0.1'
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release '10.0.0' } 'one file drifted' -MessagePattern 'SDK_CORE_URL'
        $pins = Get-TorchRocmTestPin
        $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'] -replace '10\.0\.0', '10.0.1'
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release '10.0.0' } 'the second GPU drifted' -MessagePattern 'SDK_DEVICE_GFX1200_URL'
    }

    It 'refuses a bad release, a bad SHA256, a URL off AMD''s repo, swapped keys and a non-Windows wheel' {
        $core = 'https://stable.repo.amd.com/rocm/core/whl-next'
        Assert-TorchRocmPinRefusal -Resolve { param($Pins, $Release) Get-TorchRocmWheelSet -Pins $Pins -Release $Release } -Case @(
                @{ Release = ''; P = 'x\.y\.z' }
                @{ Release = '10.0'; P = 'x\.y\.z' }
                @{ Release = 'v10.0.0'; P = 'x\.y\.z' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'; Value = ''; P = 'SDK_CORE_SHA256' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'; Value = 'abc'; P = 'SDK_CORE_SHA256' }
                @{ Key = 'TORCH_ROCM_WINDOWS_ROCM_URL'; Value = ''; P = 'ROCM_URL' }
                @{ Key = 'TORCH_ROCM_WINDOWS_ROCM_URL'; Value = 'https://pypi.org/packages/rocm-10.0.0.tar.gz'; P = 'stable\.repo\.amd\.com' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_URL'; Value = "http://stable.repo.amd.com/rocm/core/whl-next/rocm-sdk-core/rocm_sdk_core-10.0.0-py3-none-win_amd64.whl"; P = 'stable\.repo\.amd\.com' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_URL'; Value = "$core/rocm-sdk-libraries/rocm_sdk_libraries-10.0.0-py3-none-win_amd64.whl"; P = 'expected rocm-sdk-core' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_DEVICE_URL'; Value = "$core/rocm-sdk-device-gfx1201/rocm_sdk_device_gfx1201-10.0.0-py3-none-manylinux_2_28_x86_64.whl"; P = 'win_amd64' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'; Value = "$core/rocm-sdk-device-gfx1201/rocm_sdk_device_gfx1201-10.0.0-py3-none-win_amd64.whl"; P = 'SDK_DEVICE_GFX1200_URL names rocm-sdk-device-gfx1201, expected rocm-sdk-device-gfx1200' })
    }

    It 'one GPU pinned twice, a device pin with no SDK_DEVICE pin, and no device pin at all are refused' {
        $pins = Get-TorchRocmTestPin
        $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL']
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release '10.0.0' } 'gfx1200 twice' -MessagePattern 'pins gfx1200 a second time'
        $set = Get-TorchRocmTestSet
        $byName = [ordered]@{}
        foreach ($w in $set.Wheels) { $byName[$w.Name] = $w }
        $byName['EXTRA_DEVICE'] = $set.Wheels[0]
        Assert-Throws { Get-TorchRocmGpuTarget -ByName $byName } 'orphaned device pin' -MessagePattern 'no SDK_DEVICE pin.*EXTRA_DEVICE'
        $none = [ordered]@{}
        foreach ($w in $set.Wheels) { if ($w.Name -notlike 'SDK_DEVICE*') { $none[$w.Name] = $w } }
        Assert-Throws { Get-TorchRocmGpuTarget -ByName $none } 'no device pins' -MessagePattern 'no TORCH_ROCM_WINDOWS_SDK_DEVICE pin'
    }
}

Describe 'Install-TorchRocm: the source-built wheels (torch-rocm-wheels stage)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName $script:TorchRocmSetFunction)

    It 'reads exactly the torch and torchvision wheels, with their own SHA256 and path' {
        Invoke-InTestDir { param($dir)
            $wd = New-TorchRocmBuiltWheelDir -Dir $dir
            $built = @(Get-TorchRocmBuiltWheel -WheelDir $wd -Release '10.0.0')
            Assert-Equal 'torch,torchvision' (($built | ForEach-Object Distribution) -join ',') 'torch first, then torchvision'
            Assert-Equal '2.14.0+rocm10.0.0,0.29.0+rocm10.0.0' (($built | ForEach-Object Version) -join ',') 'versions'
            foreach ($w in $built) {
                Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $w.LocalPath).Hash.ToLowerInvariant() $w.Sha256 "$($w.FileName) hash"
                Assert-True (Test-Path -LiteralPath $w.LocalPath -PathType Leaf) "$($w.FileName) path"
            }
        }
    }

    It 'refuses a missing directory, a stray file, a second torch, another platform, another ROCm and a missing torchvision' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Get-TorchRocmBuiltWheel -WheelDir (Join-Path $dir 'none') -Release '10.0.0' } 'no dir' -MessagePattern 'no source-built wheels'
            $i = 0
            foreach ($c in @(
                    @{ N = $script:TorchRocmBuiltName + 'numpy-2.3.0-cp314-cp314-win_amd64.whl'; P = 'only the torch and torchvision wheels' }
                    @{ N = $script:TorchRocmBuiltName + 'torch-2.14.0+rocm10.0.0-cp313-cp313-win_amd64.whl'; P = 'two torch wheels' }
                    @{ N = @('torch-2.14.0+rocm10.0.0-cp314-cp314-linux_x86_64.whl', $script:TorchRocmBuiltName[1]); P = 'linux_x86_64 wheel' }
                    @{ N = @('torch-2.14.0+rocm10.1.0-cp314-cp314-win_amd64.whl', $script:TorchRocmBuiltName[1]); P = "not a '\+rocm10\.0\.0' build" }
                    @{ N = @($script:TorchRocmBuiltName[0]); P = 'has no torchvision wheel' })) {
                $wd = New-TorchRocmBuiltWheelDir -Dir (Join-Path $dir "case$i") -Name $c.N
                Assert-Throws { Get-TorchRocmBuiltWheel -WheelDir $wd -Release '10.0.0' } "case $i" -MessagePattern $c.P
                $i++
            }
        }
    }
}

Describe 'Install-TorchRocm: the venv''s PyPI extra (ai-edge-litert)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName $script:TorchRocmSetFunction)

    It 'the real pin parses: ai-edge-litert, from PyPI, as a cp314 Windows x64 wheel' {
        $extras = @((Get-TorchRocmTestSet).Extras)
        Assert-Equal 'ai-edge-litert' (($extras | ForEach-Object { $_.Distribution }) -join ',') 'extras, in pin order'
        foreach ($w in $extras) {
            Assert-Equal 'win_amd64' $w.Platform $w.FileName
            Assert-Equal 'cp314' $w.PythonTag $w.FileName
            Assert-True $w.Url.StartsWith('https://files.pythonhosted.org/packages/') "PyPI host: $($w.Url)"
        }
    }

    It 'no prebuilt ORT EP is pinned any more (owner rule 2026-09-23: the chain ORT builds its WebGPU EP)' {
        $pins = Get-TorchRocmTestPin
        Assert-Equal '' (@($pins.Keys | Where-Object { $_ -match 'ORT_EP|EP_WEBGPU' }) -join ',') 'versions.env keys'
        Assert-Equal '' (@((Get-TorchRocmExtraPinMap).Values | Where-Object { $_ -match 'onnxruntime' }) -join ',') 'extra pin map'
        Assert-False ((Get-TorchDockerfileText) -match 'onnxruntime[_-]ep') 'Dockerfile.torch'
    }

    It 'refuses another host (AMD''s too), another distribution, a non-Windows wheel and a bad SHA256' {
        $pypi = 'https://files.pythonhosted.org/packages/aa/bb/cc'
        # Pin key -> (bad value -> the refusal it must raise).
        $bad = [ordered]@{
            TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL    = [ordered]@{
                'https://pypi.org/simple/ai_edge_litert-2.2.0-cp314-cp314-win_amd64.whl'                          = 'files\.pythonhosted\.org'
                'https://stable.repo.amd.com/rocm/core/whl-next/x/ai_edge_litert-2.2.0-cp314-cp314-win_amd64.whl' = 'files\.pythonhosted\.org'
                "$pypi/ai_edge_litert_nightly-2.3.0-cp314-cp314-win_amd64.whl"                                     = 'expected ai-edge-litert'
                "$pypi/ai_edge_litert-2.2.0-cp314-cp314-manylinux_2_27_x86_64.whl"                                 = 'win_amd64'
            }
            TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_SHA256 = [ordered]@{ 'not-a-sha' = 'AI_EDGE_LITERT_SHA256' }
        }
        $cases = foreach ($key in $bad.Keys) { foreach ($value in $bad[$key].Keys) { @{ Key = $key; Value = $value; P = $bad[$key][$value] } } }
        Assert-TorchRocmPinRefusal -Resolve { param($Pins) @(Get-TorchRocmExtraWheel -Pins $Pins) } -Case $cases
    }
}

Describe 'Install-TorchRocm: the wheels must fit the app venv' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Assert-TorchRocmVenvMatch'))
    $testSet = Get-TorchRocmTestSet
    $script:TorchRocmWheels = @(Get-TorchRocmBuiltWheelFact) + @($testSet.Wheels) + @($testSet.Extras)
    function New-TorchRocmVenvFact { param([hashtable]$Override = @{})
        $v = @{ tag = 'cp314'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }
        foreach ($k in $Override.Keys) { $v[$k] = $Override[$k] }
        return $v
    }

    It 'accepts the venv uv sync builds today (cp314, the app lock''s torch 2.14.0 / torchvision 0.29.0)' {
        Assert-TorchRocmVenvMatch -Wheels $script:TorchRocmWheels -Venv (New-TorchRocmVenvFact)
        Assert-True $true 'no throw'
    }

    It 'refuses another interpreter, another app torch, no torch and no setuptools' {
        foreach ($case in @(
                @{ O = @{ tag = 'cp313' }; P = 'cp313' }
                @{ O = @{ tag = 'cp314t' }; P = 'cp314t' }
                @{ O = @{ torch = '2.13.0+cpu' }; P = 'PYTORCH_VERSION/TORCHVISION_VERSION' }
                @{ O = @{ torchvision = '0.28.0' }; P = 'the ROCm build is 0\.29\.0' }
                @{ O = @{ torch = '' }; P = 'PYTORCH_EXTRA' }
                @{ O = @{ setuptools = '' }; P = 'setuptools' })) {
            Assert-Throws { Assert-TorchRocmVenvMatch -Wheels $script:TorchRocmWheels -Venv (New-TorchRocmVenvFact -Override $case.O) } `
                ($case.O | ConvertTo-Json -Compress) -MessagePattern $case.P
        }
    }

    It 'the cp-tagged ai-edge-litert pin is held to the venv''s interpreter too' {
        $pins = Get-TorchRocmTestPin
        $pins['TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL'] = $pins['TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL'] -replace 'cp314', 'cp313'
        $wheels = @(Get-TorchRocmBuiltWheelFact) + @($testSet.Wheels) + @(Get-TorchRocmExtraWheel -Pins $pins)
        Assert-Throws { Assert-TorchRocmVenvMatch -Wheels $wheels -Venv (New-TorchRocmVenvFact) } 'litert cp313 in a cp314 venv' -MessagePattern 'ai_edge_litert-2\.2\.0-cp313'
    }
}

Describe 'Install-TorchRocm: rocBLAS GPU coverage and the chain onnxruntime' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Assert-TorchRocmGpuCoverage', 'Assert-TorchRocmOrtUnchanged'))

    It 'the real pins cover the GPUs the gfx120X-all rocBLAS serves (gfx1200, gfx1201)' {
        Assert-TorchRocmGpuCoverage -GfxTarget (Get-TorchRocmTestSet).GfxTargets -RocmGpu @('gfx1200', 'gfx1201')
        Assert-True $true 'no throw'
    }

    It 'a GPU rocBLAS serves without device pins throws, and so does an empty rocBLAS set' {
        Assert-Throws { Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201') -RocmGpu @('gfx1200', 'gfx1201') } 'gfx1201 only (the old pin set)' -MessagePattern 'serves gfx1200, the device pins cover only gfx1201'
        Assert-Throws { Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201', 'gfx1200') -RocmGpu @() } 'no rocBLAS GPU' -MessagePattern 'names no GPU'
    }

    It 'more pinned GPUs than rocBLAS serves is fine: the rocm-sdk wheels carry their own ROCm runtime' {
        Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201', 'gfx1200', 'gfx1036') -RocmGpu @('gfx1201')
        Assert-True $true 'no throw'
    }

    It 'the install must leave the chain onnxruntime exactly as it found it' {
        Assert-TorchRocmOrtUnchanged -Before 'abc' -After 'abc'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before 'abc' -After 'def' } 'replaced' -MessagePattern 'replaced the venv''s onnxruntime'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before 'abc' -After '' } 'uninstalled' -MessagePattern 'replaced the venv''s onnxruntime'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before '' -After '' } 'never there' -MessagePattern 'has no onnxruntime'
    }
}

Describe 'Install-TorchRocm: offline install inputs' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Get-TorchRocmCachedPath', 'Get-TorchRocmRequirement', 'Get-TorchRocmInstallCommand'))

    It 'writes one hash-pinned reference per file: the pinned ones from the hash-keyed cache, the built ones where they are mounted' {
        $set = Get-TorchRocmTestSet
        $pins = $set.Pins
        $built = @(Get-TorchRocmBuiltWheelFact)
        $lines = @(Get-TorchRocmRequirement -Wheels ($built + @($set.Wheels) + @($set.Extras)) -CacheDir 'C:\uvcache\torch-rocm')
        Assert-Equal 8 $lines.Count 'requirement lines (2 built, 5 AMD runtime, 1 PyPI extra)'
        foreach ($l in @($lines | Select-Object -Skip 2)) { Assert-Match '^[a-z0-9-]+ @ file:///C:/uvcache/torch-rocm/[0-9a-f]{64}/\S+ --hash=sha256:[0-9a-f]{64}$' $l 'pinned requirement shape' }
        Assert-Equal "torch @ file:///C:/bkmnt/torch-rocm-wheels/$($script:TorchRocmBuiltName[0]) --hash=sha256:$('a' * 64)" $lines[0] 'the built torch, from its mount'
        Assert-Equal "torchvision @ file:///C:/bkmnt/torch-rocm-wheels/$($script:TorchRocmBuiltName[1]) --hash=sha256:$('a' * 64)" $lines[1] 'the built torchvision'
        $core = @($lines | Where-Object { $_ -like 'rocm-sdk-core @ *' })[0]
        Assert-True $core.EndsWith("--hash=sha256:$($pins['TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'])") 'rocm-sdk-core hash'
        foreach ($dist in 'rocm', 'rocm-sdk-libraries', 'rocm-sdk-device-gfx1200', 'rocm-sdk-device-gfx1201', 'ai-edge-litert') {
            Assert-Equal 1 @($lines | Where-Object { $_ -like "$dist @ *" }).Count "one line for $dist"
        }
    }

    It 'installs offline and exactly: no index, no deps, no build isolation, hashes required' {
        $cmd = Get-TorchRocmInstallCommand -VenvPython 'C:\opt\OrchestrANT\.venv\Scripts\python.exe' -RequirementsFile 'C:\t\req.txt' -GfxTarget (Get-TorchRocmTestSet).GfxTarget
        foreach ($flag in '--no-index', '--no-deps', '--no-build-isolation', '--require-hashes', '--force-reinstall') {
            Assert-True $cmd.Contains($flag) "missing $flag in: $cmd"
        }
        Assert-True $cmd.Contains('--python "C:\opt\OrchestrANT\.venv\Scripts\python.exe"') 'venv interpreter, quoted'
        Assert-True $cmd.EndsWith('-r "C:\t\req.txt"') 'requirements file, quoted'
        $uv = $cmd.IndexOf('uv pip install')
        foreach ($set in 'set "UV_NO_CACHE=1" && ', 'set "UV_LINK_MODE=copy" && ', 'set "ROCM_SDK_TARGET_FAMILY=gfx1201" && ', 'set "ROCM_BOOTSTRAP_DISABLE_DETECTION=1" && ') {
            $at = $cmd.IndexOf($set)
            Assert-True ($at -ge 0 -and $at -lt $uv) "missing, or after uv: $set in: $cmd"
        }
        Assert-Throws { Get-TorchRocmInstallCommand -VenvPython 'p' -RequirementsFile 'r' -GfxTarget 'gfx1201 & calc' } 'a GPU target cmd would run' -MessagePattern 'GfxTarget'
    }

    It 'the env reaches the command through cmd and never the calling process' {
        $cmd = Get-TorchRocmInstallCommand -VenvPython 'p' -RequirementsFile 'r' -GfxTarget 'gfx1201'
        $probe = $cmd.Substring(0, $cmd.IndexOf('uv pip install')) + 'set ROCM_'
        $out = Invoke-WithEnv @{ ROCM_SDK_TARGET_FAMILY = $null; ROCM_BOOTSTRAP_DISABLE_DETECTION = $null } {
            @(& cmd.exe /s /c " $probe 2>&1")
            Assert-Null $env:ROCM_SDK_TARGET_FAMILY 'the calling process env stays untouched'
        }
        Assert-True (@($out) -contains 'ROCM_SDK_TARGET_FAMILY=gfx1201') "cmd saw: $($out -join ' | ')"
        Assert-True (@($out) -contains 'ROCM_BOOTSTRAP_DISABLE_DETECTION=1') "cmd saw: $($out -join ' | ')"
    }
}

Describe 'Install-TorchRocm: hash-keyed wheel cache' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName 'Get-TorchRocmCachedPath', 'Save-TorchRocmWheel')
    function New-TorchRocmFakeWheel { param([string]$Dir)
        $src = Join-Path $Dir 'src\fake_pkg-1.0-py3-none-any.whl'
        New-Item -ItemType Directory -Force -Path (Split-Path $src -Parent) | Out-Null
        [System.IO.File]::WriteAllBytes($src, [byte[]](@(0x50, 0x4B) + [System.Text.Encoding]::ASCII.GetBytes('fake wheel body')))
        return [pscustomobject]@{
            FileName = 'fake_pkg-1.0-py3-none-any.whl'; Url = ([uri]$src).AbsoluteUri; IsSdist = $false
            Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant(); Cache = (Join-Path $Dir 'cache')
        }
    }
    # The fake wheel, already fetched once into its cache (.Path).
    function Save-TorchRocmFakeWheel { param([string]$Dir)
        $w = New-TorchRocmFakeWheel -Dir $Dir
        return ($w | Add-Member -NotePropertyName Path -NotePropertyValue (Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0) -PassThru)
    }

    It 'fetches into <cache>\<sha256>\<file>, then serves that copy with the source gone' {
        Invoke-InTestDir { param($dir)
            $w = Save-TorchRocmFakeWheel -Dir $dir
            Assert-Equal (Join-Path $w.Cache "$($w.Sha256)\$($w.FileName)") $w.Path 'cache layout'
            $w.Url = ([uri](Join-Path $dir 'nowhere\fake_pkg-1.0-py3-none-any.whl')).AbsoluteUri
            Assert-Equal $w.Path (Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0) 'cached copy reused offline'
        }
    }

    It 'a cached copy that fails its SHA256 is fetched again, never used' {
        Invoke-InTestDir { param($dir)
            $w = Save-TorchRocmFakeWheel -Dir $dir
            [System.IO.File]::WriteAllText($w.Path, 'PK tampered')
            [void](Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0 3>$null)
            Assert-Equal $w.Sha256 (Get-FileHash -Algorithm SHA256 -LiteralPath $w.Path).Hash.ToLowerInvariant() 'refetched bytes'
        }
    }

    It 'a download that does not match its pin throws and leaves nothing in the cache' {
        Invoke-InTestDir { param($dir)
            $w = New-TorchRocmFakeWheel -Dir $dir
            $w.Sha256 = '0' * 64
            Assert-Throws { Save-TorchRocmWheel -Wheel $w -CacheDir $w.Cache -InitialDelaySeconds 0 } 'SHA256 mismatch' -MessagePattern 'SHA256 mismatch'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $w.Cache -Recurse -File -ErrorAction SilentlyContinue).Count 'no file left behind'
        }
    }

    It 'renames nothing on the cache mount, where a rename failed ERROR_PATH_NOT_FOUND (2026-09-25)' {
        $body = (Get-Command Save-TorchRocmWheel).Definition
        Assert-Match 'Invoke-DownloadWithRetry -Url \$Wheel\.Url -DestinationPath \$dest ' $body 'downloads to the cache path itself'
        # \b: -match ignores case, and Remove-Item ends in 'move-Item'.
        Assert-False ($body -match '\b(Move|Rename)-Item\b|\[System\.IO\.File\]::Move') 'no rename'
    }
}

Describe 'rocm-checks\Torch.ps1: findings' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmProbeSource', 'Get-TorchRocmReportSection',
        'Get-TorchRocmExtraFinding', 'Get-TorchRocmFinding', 'Get-TorchRocmRocblasGpu', 'Get-TorchRocmImageFinding')
    $script:TorchRocmGpu = @('gfx1200', 'gfx1201')
    function New-TorchRocmReport { param([hashtable]$Override = @{})
        $r = @{
            torch = '2.14.0+rocm10.0.0'; hip = '7.15.26333'; rocm = '10.0.0'; arch = 'gfx1200 gfx1201'
            torchvision = '0.29.0+rocm10.0.0'; rocm_sdk = '10.0.0'; stderr = ''
            dists = @{
                'rocm' = '10.0.0'; 'rocm-sdk-core' = '10.0.0'; 'rocm-sdk-libraries' = '10.0.0'
                'rocm-sdk-device-gfx1201' = '10.0.0'; 'rocm-sdk-device-gfx1200' = '10.0.0'
            }
            ort = @{ dml = $true }
            litert = @{ version = '2.2.0'; unmet = @(); interpreter = $true; accelerator = 'C:\x\libLiteRtWebGpuAccelerator.dll'; accelerator_entry = $true }
        }
        foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
        return $r
    }

    It 'a ROCm venv for the release, with both GPUs, the chain ORT and ai-edge-litert, passes' {
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 0 $f.Count "findings: $($f -join ' | ')"
    }

    It 'the CPU torch the app lock installs is caught' {
        $cpu = New-TorchRocmReport -Override @{ torch = '2.14.0+cpu'; hip = $null; rocm = $null; torchvision = '0.29.0+cpu'; rocm_sdk = $null; arch = ''; dists = @{} }
        $f = @(Get-TorchRocmFinding -Report $cpu -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        foreach ($p in "torch is '2\.14\.0\+cpu'", 'torchvision is', 'torch\.version\.hip is empty', 'no rocm-sdk-device-', 'no compiled GPU arch') {
            Assert-Match $p $f 'CPU torch finding'
        }
    }

    It 'each single defect yields a finding' {
        $cases = @(
            @{ Release = '10.1.0'; O = @{}; P = 'rocm10\.1\.0' }
            @{ Release = '10.0.0'; O = @{ error = 'OSError: [WinError 126] amdhip64_7.dll' }; P = 'import.*failed.*WinError 126' }
            @{ Release = '10.0.0'; O = @{ hip = '' }; P = 'hip is empty' }
            @{ Release = '10.0.0'; O = @{ rocm = '10.0.1' }; P = 'torch\.version\.rocm' }
            @{ Release = '10.0.0'; O = @{ rocm_sdk = '9.9.9' }; P = 'rocm_sdk is' }
            @{ Release = '10.0.0'; O = @{ arch = 'gfx1201' }; P = 'torch was built for gfx1201, not gfx1200' }
            @{ Release = '10.0.0'; O = @{ arch = '' }; P = 'no compiled GPU arch' }
            @{ Release = ''; O = @{}; P = 'ROCM_WINDOWS_RELEASE is not set' }
        )
        foreach ($c in $cases) {
            $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport -Override $c.O) -Release $c.Release -RocmGpu $script:TorchRocmGpu) -join "`n"
            Assert-Match $c.P $f "case $($c.O | ConvertTo-Json -Compress) release '$($c.Release)'"
        }
        Assert-Match 'no report' (@(Get-TorchRocmFinding -Report $null -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join ' ') 'null report'
    }

    It 'dist defects: a missing runtime, a device wheel at the wrong version' {
        foreach ($c in @(
                @{ Drop = 'rocm-sdk-libraries'; Set = $null; P = 'rocm-sdk-libraries is' }
                @{ Drop = 'rocm-sdk-core'; Set = $null; P = 'rocm-sdk-core is' }
                @{ Drop = $null; Set = @('rocm-sdk-device-gfx1200', '10.0.1'); P = 'rocm-sdk-device-gfx1200 is' })) {
            $r = New-TorchRocmReport
            $dists = @{}
            foreach ($k in $r.dists.Keys) { if ($k -ne $c.Drop) { $dists[$k] = $r.dists[$k] } }
            if ($c.Set) { $dists[$c.Set[0]] = $c.Set[1] }
            $r.dists = $dists
            Assert-Match $c.P (@(Get-TorchRocmFinding -Report $r -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n") "dist case $($c.P)"
        }
    }

    It 'every GPU ROCm''s rocBLAS serves needs torch kernels compiled for it and its rocm-sdk device dist' {
        $r = New-TorchRocmReport
        $r.dists.Remove('rocm-sdk-device-gfx1200')
        $f = @(Get-TorchRocmFinding -Report $r -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 1 $f.Count "dropping rocm-sdk-device-gfx1200; findings: $($f -join ' | ')"
        Assert-Match "no rocm-sdk-device-gfx1200 dist: ROCm's rocBLAS serves gfx1200" $f[0] 'library kernels'
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport -Override @{ arch = 'gfx1201;gfx1100' }) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
        Assert-Equal 1 $f.Count "torch without gfx1200 kernels; findings: $($f -join ' | ')"
        Assert-Match 'torch was built for gfx1201, gfx1100, not gfx1200' $f[0] 'torch kernels, any separator'
        $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu @('gfx1036', 'gfx1201')) -join "`n"
        Assert-Match 'no rocm-sdk-device-gfx1036 dist' $f 'a GPU rocBLAS serves: library kernels'
        Assert-Match 'not gfx1036' $f 'a GPU rocBLAS serves: torch kernels'
        Assert-Match "names no GPU" (@(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0') -join "`n") 'no rocBLAS set given'
    }

    It 'no ROCm root, a missing rocBLAS dir or one without GPUs is a finding, never a StrictMode throw that loses the others' {
        Invoke-InTestDir { param($dir)
            $r = New-TorchRocmReport -Override @{ ort = @{ error = 'import onnxruntime: ModuleNotFoundError: x' } }
            [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'empty\bin\rocblas\library'))
            foreach ($root in '', (Join-Path $dir 'none'), (Join-Path $dir 'empty')) {
                $f = @(Get-TorchRocmImageFinding -Report $r -Release '10.0.0' -RocmRoot $root 6>$null) -join "`n"
                Assert-Match 'names no GPU' $f "ROCm root '$root'"
                Assert-Match "the venv's onnxruntime: import onnxruntime" $f "ROCm root '$root': the other findings survive"
            }
            Assert-Match 'names no GPU' (@(Get-TorchRocmFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmGpu $null) -join "`n") 'a $null set'
        }
    }

    It 'the script body reads the GPU set from <ROCm root>\bin\rocblas\library, one GPU or several' {
        Invoke-InTestDir { param($dir)
            $lib = Join-Path $dir 'bin\rocblas\library'
            [void][System.IO.Directory]::CreateDirectory($lib)
            [System.IO.File]::WriteAllText((Join-Path $lib 'TensileLibrary_lazy_gfx1201.dat'), 'x')
            $f = @(Get-TorchRocmImageFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmRoot $dir 6>$null)
            Assert-Equal 0 $f.Count "gfx1201 alone (a one-GPU set unwraps to a string); findings: $($f -join ' | ')"
            [System.IO.File]::WriteAllText((Join-Path $lib 'TensileLibrary_lazy_gfx1036.dat'), 'x')
            $f = @(Get-TorchRocmImageFinding -Report (New-TorchRocmReport) -Release '10.0.0' -RocmRoot $dir 6>$null) -join "`n"
            Assert-Match 'no rocm-sdk-device-gfx1036 dist' $f 'a GPU rocBLAS serves that the venv lacks'
        }
    }

    It 'venv extras: each defect yields its own finding' {
        $lite = (New-TorchRocmReport).litert
        $with = { param($Base, [hashtable]$Change) $h = @{}; foreach ($k in $Base.Keys) { $h[$k] = $Base[$k] }; foreach ($k in $Change.Keys) { $h[$k] = $Change[$k] }; $h }
        foreach ($c in @(
                @{ O = @{ ort = @{ error = 'import onnxruntime: ImportError: DLL load failed' } }; P = "the venv's onnxruntime: import onnxruntime: ImportError" }
                @{ O = @{ ort = @{ dml = $false } }; P = 'no DmlExecutionProvider' }
                @{ O = @{ litert = @{ error = 'import ai_edge_litert.interpreter: ModuleNotFoundError: No module named ''ai_edge_litert''' } }; P = 'ai-edge-litert: import ai_edge_litert' }
                @{ O = @{ litert = (& $with $lite @{ interpreter = $false }) }; P = 'has no Interpreter' }
                @{ O = @{ litert = (& $with $lite @{ accelerator = '' }) }; P = 'ships no libLiteRtWebGpuAccelerator\.dll' }
                @{ O = @{ litert = (& $with $lite @{ accelerator_entry = $false }) }; P = 'without its LiteRtAcceleratorImpl export' }
                @{ O = @{ litert = (& $with $lite @{ unmet = @('ml_dtypes') }) }; P = 'ai-edge-litert is installed --no-deps and the venv lacks its requirement ml_dtypes' })) {
            $f = @(Get-TorchRocmFinding -Report (New-TorchRocmReport -Override $c.O) -Release '10.0.0' -RocmGpu $script:TorchRocmGpu)
            Assert-Equal 1 $f.Count "case /$($c.P)/; findings: $($f -join ' | ')"
            Assert-Match $c.P $f[0] 'venv extras finding'
        }
    }

    It 'a report without the ORT or LiteRT section, or a failed torch import, still reports the extras' {
        $old = New-TorchRocmReport
        $old.Remove('ort'); $old.Remove('litert')
        $f = @(Get-TorchRocmFinding -Report $old -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        Assert-Match "the venv's onnxruntime lists no DmlExecutionProvider" $f 'no ORT section'
        Assert-Match 'ai-edge-litert: ai_edge_litert\.interpreter has no Interpreter' $f 'no LiteRT section'
        $broken = New-TorchRocmReport -Override @{ error = 'ImportError: torch'; ort = @{ error = 'import onnxruntime: ModuleNotFoundError: x' } }
        $f = @(Get-TorchRocmFinding -Report $broken -Release '10.0.0' -RocmGpu $script:TorchRocmGpu) -join "`n"
        Assert-Match 'importing torch/torchvision/rocm_sdk failed' $f 'torch finding'
        Assert-Match "the venv's onnxruntime: import onnxruntime" $f 'ORT finding survives the torch return'
    }

    It 'the whole script reports a missing app venv as one finding instead of passing' {
        Invoke-InTestDir { param($dir)
            $check = Resolve-TorchRocmSuitePath $script:TorchRocmCheck
            $out = @(Invoke-WithEnv @{ TORCH_APP_DIR = $dir; ROCM_WINDOWS_RELEASE = '10.0.0' } { & $check 6>$null })
            Assert-Equal 1 $out.Count "findings: $($out -join ' / ')"
            Assert-Match '^Torch: app venv python not found at ' $out[0] 'missing venv finding'
        }
    }

    It 'needs no GPU: no torch.cuda, no plugin EP; the LiteRT accelerator load is the only native step' {
        $src = Get-TorchRocmProbeSource
        Assert-False ($src -match 'torch\.cuda') 'probe source calls torch.cuda (it needs a GPU)'
        Assert-Match 'torch\._C\._cuda_getArchFlags\(\)' $src 'the compiled arch list: build-time data, no GPU needed'
        Assert-False ($src -match 'onnxruntime_ep_webgpu|register_execution_provider_library') 'no prebuilt plugin EP (the chain ORT carries WebGPU; rocm-checks\OrtWebGpu.ps1 checks it)'
        Assert-Match '"dml"\] = "DmlExecutionProvider" in ort\.get_available_providers\(\)' $src 'the chain wheel''s DML EP is read'
        Assert-Match 'ctypes\.WinDLL\(path\), "LiteRtAcceleratorImpl"' $src 'accelerator loaded and its entry export resolved'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-TorchRocmSuitePath $script:TorchRocmCheck), [ref]$null, [ref]$null)
        Assert-Null $ast.ParamBlock 'rocm-checks scripts take no parameters (Test-RocmImage.ps1 runs them bare)'
    }
}

Describe 'rocm-checks\Torch.ps1: the GPUs ROCm''s rocBLAS serves' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmRocblasGpu')

    It 'reads them from TensileLibrary_lazy_<gfx>.dat only, sorted and unique' {
        Invoke-InTestDir { param($dir)
            foreach ($n in 'TensileLibrary_lazy_gfx1201.dat', 'TensileLibrary_lazy_gfx1200.dat', 'TensileLibrary_lazy_gfx1201.dat.zlib',
                'TensileLibrary_lazy_gfx1036.dat.zlib', 'TensileLibrary_lazy_gfx1030.datx', 'TensileLibrary_gfx1100.dat', 'Kernels.so-000-gfx1102.hsaco') {
                [System.IO.File]::WriteAllText((Join-Path $dir $n), 'x')
            }
            Assert-Equal 'gfx1200,gfx1201' ((Get-TorchRocmRocblasGpu -RocblasLibraryDir $dir) -join ',') 'GPU set'
        }
    }

    It 'a missing or empty directory is an empty set (the finding then says so)' {
        Invoke-InTestDir { param($dir)
            Assert-Equal 0 @(Get-TorchRocmRocblasGpu -RocblasLibraryDir $dir).Count 'empty dir'
            Assert-Equal 0 @(Get-TorchRocmRocblasGpu -RocblasLibraryDir (Join-Path $dir 'nope')).Count 'missing dir'
        }
    }
}

Describe 'rocm-checks\Torch.ps1: the one venv probe, shared with Install-TorchRocm' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmCheck -FunctionName 'Get-TorchRocmProbeSource', 'Get-TorchRocmVenvReport')
    # A stand-in interpreter: keeps a copy of the probe it was handed, prints $Lines, exits $Rc.
    function New-TorchRocmFakePython { param([string]$Dir, [string[]]$Lines, [int]$Rc = 0)
        $cmd = Join-Path $Dir "python-$([guid]::NewGuid().ToString('N')).cmd"
        $body = @('@echo off', "echo %1> ""$Dir\probe-path.txt""", "copy /y %1 ""$Dir\probe-copy.py"" >nul") +
            @($Lines | ForEach-Object { "echo $_" }) + @("exit /b $Rc")
        Set-Content -LiteralPath $cmd -Value $body -Encoding ascii
        return $cmd
    }
    # An installer run up to its first refusal: fake venv python, pins from versions.env, a check that reports $Venv.
    function Invoke-TorchRocmInstallerTo { param([string]$Dir, [string]$Venv, [hashtable]$Env = @{}, [string]$WheelDir = '')
        if (-not $WheelDir) { $WheelDir = New-TorchRocmBuiltWheelDir -Dir $Dir }
        $app = Join-Path $Dir 'app'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $app '.venv\Scripts'))
        [System.IO.File]::WriteAllBytes((Join-Path $app '.venv\Scripts\python.exe'), [byte[]]@())
        $fake = Join-Path $Dir 'FakeCheck.ps1'
        $real = Resolve-TorchRocmSuitePath $script:TorchRocmCheck
        [System.IO.File]::WriteAllLines($fake, [string[]]@(". '$real'", "function Get-TorchRocmVenvReport { param(`$Python) @{ venv = $Venv } }",
                "if (`$MyInvocation.InvocationName -eq '.') { return }", "'Torch: the fake check ran as a check'"))
        $pins = Get-TorchRocmTestPin
        # A dead proxy: a regression that reaches the downloads fails fast instead of pulling ~2 GB from AMD.
        $vars = @{ GPU_TYPE = 'rocm'; TORCH_ROCM = $null; HIP_PATH = $null; ROCM_PATH = $null
            HTTPS_PROXY = 'http://127.0.0.1:9'; HTTP_PROXY = 'http://127.0.0.1:9'; NO_PROXY = $null }
        foreach ($k in @($pins.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' -or $_ -eq 'ROCM_WINDOWS_RELEASE' })) { $vars[$k] = $pins[$k] }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $installer = Resolve-TorchRocmSuitePath $script:TorchRocmScript
        $out = Invoke-WithEnv $vars {
            & pwsh -NoProfile -NonInteractive -File $installer -TorchRocm 1 -AppDir $app -WheelDir $WheelDir -WheelCache (Join-Path $Dir 'cache') -CheckScript $fake 2>&1 | Out-String
        }
        return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = $out; CacheMade = (Test-Path (Join-Path $Dir 'cache')) }
    }
    # A refusal: a non-zero exit, the named reason in the output, and no wheel cache created.
    function Assert-TorchRocmInstallRefused { param([object]$Result, [string]$Pattern, [string]$Why)
        Assert-True ($Result.Rc -ne 0) "exit code $($Result.Rc); output: $($Result.Out)"
        Assert-Match $Pattern $Result.Out $Why
        Assert-False $Result.CacheMade 'refused before any download'
    }

    It 'returns the last JSON line as a hashtable, ran the probe source and removed its file' {
        Invoke-InTestDir { param($dir)
            $py = New-TorchRocmFakePython -Dir $dir -Lines @('noise', '{"n": 1}', '{"venv": {"tag": "cp314"}, "n": 2}', 'tail noise')
            $report = Get-TorchRocmVenvReport -Python $py
            Assert-Equal 2 $report['n'] 'the last JSON line wins'
            Assert-Equal 'cp314' $report['venv']['tag'] 'nested venv facts'
            Assert-Equal (Get-TorchRocmProbeSource).Trim() ([System.IO.File]::ReadAllText((Join-Path $dir 'probe-copy.py'))).Trim() 'the probe source ran'
            $probe = ([System.IO.File]::ReadAllText((Join-Path $dir 'probe-path.txt'))).Trim()
            Assert-False (Test-Path -LiteralPath $probe) "probe file left behind: $probe"
        }
    }

    It 'a probe that exits non-zero or prints no report throws' {
        Invoke-InTestDir { param($dir)
            foreach ($case in @(@{ Lines = @('{"venv": {}}'); Rc = 3; P = 'exited 3' }, @{ Lines = @('no json here'); Rc = 0; P = 'without a report' })) {
                $py = New-TorchRocmFakePython -Dir $dir -Lines $case.Lines -Rc $case.Rc
                Assert-Throws { Get-TorchRocmVenvReport -Python $py } "rc $($case.Rc)" -MessagePattern $case.P
            }
        }
    }

    It 'the probe reads the venv facts, the chain onnxruntime''s RECORD digest included, before any import' {
        $src = Get-TorchRocmProbeSource
        $facts = $src.IndexOf('report = {"venv"')
        Assert-True ($facts -ge 0 -and $facts -lt $src.IndexOf('import torch') -and $facts -lt $src.IndexOf('import onnxruntime')) 'venv facts come first'
        foreach ($p in 'Py_GIL_DISABLED', '"torch": version\("torch"\)', '"torchvision": version\("torchvision"\)', '"setuptools": version\("setuptools"\)',
            '"onnxruntime_record": record_digest\("onnxruntime"\)') {
            Assert-Match $p $src 'venv fact'
        }
    }

    It 'dot-sourcing the check defines the runner and runs no check' {
        Invoke-InTestDir { param($dir)
            $check = Resolve-TorchRocmSuitePath $script:TorchRocmCheck
            $cmd = ". '$check'; if (Get-Command Get-TorchRocmVenvReport -ErrorAction SilentlyContinue) { 'RUNNER' }"
            $out = @(Invoke-WithEnv @{ TORCH_APP_DIR = $dir } { & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 })
            Assert-Equal 'RUNNER' ($out -join ' | ') 'dot-source output (a finding here means the check ran)'
        }
    }

    It 'Install-TorchRocm checks the wheels against the check''s venv report, before any download' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv "@{ tag = 'cp313'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }"
            Assert-TorchRocmInstallRefused $r 'the app venv runs cp313' 'the report''s venv facts reached the wheel check'
        }
    }

    It 'Install-TorchRocm refuses, before any download, a missing source-built wheel directory' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv "@{ tag = 'cp314'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }" -WheelDir (Join-Path $dir 'nowhere')
            Assert-TorchRocmInstallRefused $r 'no source-built wheels at' 'the torch-rocm-wheels mount is required'
        }
    }

    It 'Install-TorchRocm refuses, before any download, a rocBLAS GPU the device pins miss, and a missing ROCm root' {
        Invoke-InTestDir { param($dir)
            $venv = "@{ tag = 'cp314'; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0'; onnxruntime_record = 'x' }"
            $lib = Join-Path $dir 'rocm\bin\rocblas\library'
            New-Item -ItemType Directory -Force -Path $lib | Out-Null
            foreach ($gfx in 'gfx1036', 'gfx1200', 'gfx1201') { [System.IO.File]::WriteAllText((Join-Path $lib "TensileLibrary_lazy_$gfx.dat"), 'x') }
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv $venv -Env @{ HIP_PATH = (Join-Path $dir 'rocm') }
            Assert-TorchRocmInstallRefused $r "rocBLAS serves gfx1036, the device pins cover only gfx1201, gfx1200" 'coverage refusal'
            $r = Invoke-TorchRocmInstallerTo -Dir $dir -Venv $venv
            Assert-TorchRocmInstallRefused $r 'neither HIP_PATH nor ROCM_PATH is set' 'no ROCm root'
        }
    }
}

Describe 'Dockerfile.torch: cpu and nvidia build the unchanged app stage' {
    $df = Get-TorchDockerfileStage
    $byName = $df.ByName

    It 'TORCH_ROCM only selects the last stage; app is the golden list; the tail holds only ARG/HEALTHCHECK/LABEL' {
        $problems = @(Get-TorchDockerfileProblem)
        Assert-Equal 0 $problems.Count "problems: $($problems -join ' | ')"
        Assert-Match 'image\.version="\$\{APP_REF\}"' ($df.Stages[-1].Lines -join "`n") 'the tail still stamps APP_REF, so its ARG check is live'
    }

    It 'goes red on each way to change the cpu/nvidia image' {
        $text = Get-TorchDockerfileText
        $lastAppRef = $text.LastIndexOf('ARG APP_REF=')
        $tail = 'FROM rocm-${TORCH_ROCM}'
        $appDiff = 'app stage differs from the cpu/nvidia golden'
        $tailOnly = 'may hold only ARG, HEALTHCHECK and LABEL'
        $mutations = @(
            @{ Why = 'TORCH_ROCM reaches the app RUN'; P = $appDiff; T = $text -replace '(?m)^(ARG PYTORCH_EXTRA=\S+)\r?$', "`$1`nARG TORCH_ROCM" }
            @{ Why = 'a new ARG in app'; P = $appDiff; T = $text -replace '(?m)^(ARG PYTORCH_EXTRA=\S+)\r?$', "`$1`nARG EXTRA_KNOB=1" }
            @{ Why = 'the PYTORCH_EXTRA default changes'; P = $appDiff; T = $text.Replace('ARG PYTORCH_EXTRA=pytorch-cpu', 'ARG PYTORCH_EXTRA=pytorch-cu130') }
            @{ Why = 'the app RUN changes'; P = $appDiff; T = $text.Replace('-Mode all', '-Mode install') }
            @{ Why = 'the app ENV changes'; P = $appDiff; T = $text.Replace('ENV TORCH_APP_DIR="C:\opt\OrchestrANT"', 'ENV TORCH_APP_DIR="C:\opt\Other"') }
            @{ Why = 'an app COPY is dropped'; P = $appDiff; T = $text -replace '(?m)^COPY windows\\scripts\\build\\Build-TorchApp\.ps1 C:\\temp\\scripts\\\r?\n', '' }
            @{ Why = 'the app SHELL changes'; P = $appDiff; T = $text.Replace('"-ExecutionPolicy", "Bypass", ', '') }
            @{ Why = 'rocm-0 grows an instruction'; P = 'rocm-0 is not a bare alias'; T = $text.Replace('FROM app AS rocm-0', "FROM app AS rocm-0`nENV X=1") }
            @{ Why = 'rocm-1 reads TORCH_ROCM from the env'; P = '-TorchRocm 1 literally'; T = $text.Replace("-TorchRocm 1 ", '-TorchRocm $env:TORCH_ROCM ') }
            @{ Why = 'the global default flips'; P = 'TORCH_ROCM=0'; T = $text.Replace('ARG TORCH_ROCM=0', 'ARG TORCH_ROCM=1') }
            @{ Why = 'the select is hard-wired'; P = 'last FROM'; T = $text.Replace($tail, 'FROM rocm-1') }
            @{ Why = 'the tail adds a layer'; P = $tailOnly; T = $text.Replace($tail, "$tail`nRUN echo x") }
            @{ Why = 'the tail sets an ENV'; P = $tailOnly; T = $text.Replace($tail, "$tail`nENV GPU_TORCH=rocm") }
            @{ Why = 'the tail switches USER'; P = $tailOnly; T = $text.Replace($tail, "$tail`nUSER ContainerUser") }
            @{ Why = 'the tail COPYs'; P = $tailOnly; T = $text.Replace($tail, "$tail`nCOPY windows\scripts\build\Build-TorchApp.ps1 C:\temp\") }
            @{ Why = 'the tail forgets APP_REF'; P = 'APP_REF'; T = $text.Remove($lastAppRef, $text.IndexOf("`n", $lastAppRef) - $lastAppRef + 1) }
        )
        foreach ($m in $mutations) {
            Assert-False ($m.T -ceq $text) "mutation '$($m.Why)' did not apply"
            Assert-Match ([regex]::Escape($m.P)) (@(Get-TorchDockerfileProblem -Text $m.T) -join ' | ') $m.Why
        }
    }

    It 'an APP_REF bump alone is not a cpu/nvidia change the golden refuses' {
        $bumped = (Get-TorchDockerfileText) -replace 'ARG APP_REF=\S+', 'ARG APP_REF=v9.9.9'
        Assert-False ($bumped -ceq (Get-TorchDockerfileText)) 'the bump did not apply'
        $problems = @(Get-TorchDockerfileProblem -Text $bumped)
        Assert-Equal 0 $problems.Count "problems: $($problems -join ' | ')"
    }

    It 'rocm-1 and torch-rocm-wheels declare the pins each uses, with the versions.env default, and together all of them' {
        $pins = Get-TorchRocmTestPin
        $declaredIn = { param($Stage)
            $d = @{}
            foreach ($l in @($byName[$Stage].Lines | Where-Object { $_ -match '^ARG\s+(TORCH_ROCM_WINDOWS_|PYTORCH_VERSION=|TORCHVISION_VERSION=|ROCM_WINDOWS_GFX_FAMILY=)' })) {
                $k, $v = ($l -replace '^ARG\s+', '') -split '=', 2
                $d[$k] = $v
            }
            $d
        }
        $rocm1 = & $declaredIn 'rocm-1'
        $wheels = & $declaredIn 'torch-rocm-wheels'
        foreach ($d in $rocm1, $wheels) { foreach ($k in $d.Keys) { Assert-Equal $pins[$k] $d[$k] "ARG $k default" } }
        $keys = @($pins.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' } | Sort-Object)
        $all = @(@($rocm1.Keys) + @($wheels.Keys) | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' } | Sort-Object -Unique)
        Assert-Equal ($keys -join ',') ($all -join ',') 'every pin is declared where it is used'
        Assert-Equal '' (@($rocm1.Keys | Where-Object { $_ -match 'COMMIT$' }) -join ',') 'the source commits belong to the build stage only'
        foreach ($k in 'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT', 'PYTORCH_VERSION', 'TORCHVISION_VERSION', 'ROCM_WINDOWS_GFX_FAMILY') {
            Assert-True $wheels.ContainsKey($k) "torch-rocm-wheels declares $k"
        }
    }

    It 'no TORCH_ROCM_WINDOWS_* pin is declared outside rocm-1 and torch-rocm-wheels (a global or app ARG would re-key the cpu/nvidia solve)' {
        $outside = @($df.Global) + @($df.Stages | Where-Object { $_.Name -notin @('rocm-1', 'torch-rocm-wheels') } | ForEach-Object { $_.Lines })
        $leak = @($outside | Where-Object { $_ -match 'TORCH_ROCM_WINDOWS_' })
        Assert-Equal 0 $leak.Count "declared outside rocm-1: $($leak -join ' || ')"
    }

    It 'torch-rocm-wheels builds on BASE_IMAGE, never on app, so an APP_REF move cannot re-run the compile' {
        $w = $byName['torch-rocm-wheels']
        Assert-NotNull $w 'the stage exists'
        Assert-Equal '${BASE_IMAGE}' $w.From 'FROM the rocm base, not app'
        Assert-False (($w.Lines -join "`n") -match 'APP_REF') 'no APP_REF in the stage'
        Assert-False ((@($byName['rocm-0'].Lines) + @($byName['app'].Lines)) -join "`n" -match 'torch-rocm-wheels') 'only rocm-1 reaches it, so cpu/nvidia never build it'
        Assert-Equal 1 @($w.Lines | Where-Object { $_ -match '^ARG SCCACHE_WEBDAV_ENDPOINT$' }).Count 'a compiling stage declares the build-host sccache ARG'
    }

    It 'torch-rocm-wheels: a torch RUN, then a torchvision RUN, each with Import-Versions, both sccache caches and the module closure' {
        $lines = @($byName['torch-rocm-wheels'].Lines)
        $runs = @($lines | Where-Object { $_ -match '^RUN\s' })
        Assert-Equal 2 $runs.Count 'torch and torchvision are two RUNs, so a torchvision failure keeps the torch layer'
        $builder = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchRocmFromSource.ps1'))
        $closure = Get-ModuleImportClosure -Seed @([regex]::Matches($builder, "'(Windows[A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value })
        foreach ($run in $runs) {
            foreach ($m in 'target=C:\sccache,id=sccache-winamd64-2', 'target=C:\sccache-logs,id=sccache-logs-winamd64',
                'source=windows/scripts/build/Build-TorchRocmFromSource.ps1,target=C:\bkmnt\Build-TorchRocmFromSource.ps1',
                'source=windows/scripts/build/Import-Versions.ps1,target=C:\bkmnt\Import-Versions.ps1') {
                Assert-True $run.Contains($m) "mount $m"
            }
            foreach ($m in $closure) {
                Assert-True $run.Contains("source=windows/scripts/modules/$m.psm1,target=C:\bkmnt\modules\$m.psm1") "module $m not mounted"
            }
        }
        Assert-Match "Build-TorchRocmFromSource\.ps1' -OutputDir 'C:\\torch-rocm-wheels' -WorkDir 'C:\\b'$" $runs[0] 'the torch RUN'
        Assert-False $runs[0].Contains('Build-TorchvisionRocmFromSource') 'the torch RUN is not keyed by the torchvision script'
        Assert-True $runs[1].Contains('source=windows/scripts/build/Build-TorchvisionRocmFromSource.ps1,target=C:\bkmnt\Build-TorchvisionRocmFromSource.ps1') 'torchvision script mount'
        Assert-Match "Build-TorchvisionRocmFromSource\.ps1' -OutputDir 'C:\\torch-rocm-wheels' -WorkDir 'C:\\b'$" $runs[1] 'same output and work dir'
        $torchRun = [array]::IndexOf($lines, $runs[0])
        foreach ($k in 'TORCHVISION_VERSION', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT') {
            $at = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^ARG $k=") { $i } })
            Assert-Equal 1 $at.Count "one ARG $k"
            Assert-True ($at[0] -gt $torchRun) "ARG $k comes after the torch RUN, so a torchvision bump keeps its cache"
        }
    }

    It 'rocm-1 mounts the installer, its check and its whole module closure, then re-verifies the app' {
        $run = @($byName['rocm-1'].Lines | Where-Object { $_ -match '^RUN\s' })
        Assert-Equal 1 $run.Count 'one RUN in rocm-1'
        $run = $run[0]
        Assert-True $run.Contains('source=windows/scripts/build/Install-TorchRocm.ps1,target=C:\bkmnt\Install-TorchRocm.ps1') 'installer mount'
        Assert-True $run.Contains('source=windows/scripts/build/rocm-checks/Torch.ps1,target=C:\bkmnt\rocm-checks\Torch.ps1') 'check mount (the installer''s default -CheckScript)'
        $scriptText = [System.IO.File]::ReadAllText((Resolve-TorchRocmSuitePath $script:TorchRocmScript))
        $modules = @([regex]::Matches($scriptText, "'(Windows[A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-True ($modules.Count -ge 2) "module scan found: $($modules -join ',')"
        foreach ($m in $modules) {
            Assert-True $run.Contains("source=windows/scripts/modules/$m.psm1,target=C:\bkmnt\modules\$m.psm1") "module $m not mounted"
            $sibling = [regex]::Matches([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) "windows\scripts\modules\$m.psm1")), "PSScriptRoot\s+'([A-Za-z0-9._]+)\.psm1'")
            Assert-Equal 0 $sibling.Count "$m imports a sibling module the RUN does not mount"
        }
        Assert-Match "Install-TorchRocm\.ps1' -TorchRocm 1 .*Build-TorchApp\.ps1' -Mode verify" $run 'install, then the app verify on ROCm torch'
        Assert-True $run.Contains('from=torch-rocm-wheels,source=/torch-rocm-wheels,target=C:\bkmnt\torch-rocm-wheels') 'the built wheels, from the build stage (source Unix-style)'
        Assert-True $run.Contains("-WheelDir 'C:\bkmnt\torch-rocm-wheels'") 'the installer reads them there'
    }
}

Describe 'Driver contract: TORCH_ROCM reaches Dockerfile.torch on the rocm lane only' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Get-BkRocmStageArg')

    It 'cpu and nvidia get no torch build-arg; rocm gets TORCH_ROCM=1' {
        foreach ($variant in @('', 'nvidia')) {
            Assert-Equal 0 (Get-BkRocmStageArg -Variant $variant -Stage 'torch').Count "variant '$variant'"
        }
        $rocm = Get-BkRocmStageArg -Variant 'rocm' -Stage 'torch'
        Assert-Equal '1' $rocm['TORCH_ROCM'] 'rocm torch arg'
    }

    It 'the rocm lane forwards the pins by prefix and the source build''s versions; cpu/nvidia forward none' {
        $pins = Get-TorchRocmTestPin
        $new = 'TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL', 'TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_SHA256', 'TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_URL',
            'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT', 'PYTORCH_VERSION', 'TORCHVISION_VERSION', 'ROCM_WINDOWS_GFX_FAMILY'
        $sent = @{ rocm = Get-BkRocmStageArg -Variant 'rocm' -Stage 'torch' -VersionTable $pins }
        foreach ($lane in '', 'nvidia') { $sent[$lane] = Get-BkRocmStageArg -Variant $lane -Stage 'torch' -VersionTable $pins }
        Assert-Equal '' (@($new | Where-Object { $sent.rocm[$_] -cne $pins[$_] }) -join ',') 'rocm must forward these with their versions.env values'
        Assert-Equal '0,0' (('', 'nvidia' | ForEach-Object { $sent[$_].Count }) -join ',') 'cpu, nvidia: no torch build-arg even with the full pin table'
    }
}
