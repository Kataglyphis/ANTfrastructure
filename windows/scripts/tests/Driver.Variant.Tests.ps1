#requires -Version 7.0
# Build-Buildkit.ps1 -Variant: refusals, golden lane tags, rocm build-args and chain wiring; not a real solve.

Import-Module (Join-Path $PSScriptRoot 'WindowsDriverVariant.Fixture.psm1') -Force

Describe 'Resolve-BkVariant' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' `
        -FunctionName @('Resolve-BkVariant', 'Remove-BkUnsupportedStage', 'Assert-BkRocmStageClosure', 'Assert-BkVariantPushRef'))
    $script:DefaultStages = @('base', 'sdk', 'toolchain', 'media', 'migraphx', 'llama', 'torch', 'final')
    function Invoke-Resolve {
        param([string]$Variant = '', [bool]$Gpu = $false, [string]$TargetArch = 'amd64',
              [string[]]$Stages = $script:DefaultStages, [bool]$StagesBound = $false, [bool]$NoRocmSpikes = $false,
              [string]$PushRef = '')
        return Resolve-BkVariant -Variant $Variant -Gpu $Gpu -TargetArch $TargetArch -Stages $Stages -StagesBound $StagesBound `
            -NoRocmSpikes $NoRocmSpikes -PushRef $PushRef
    }

    It 'gives the default and nvidia lanes the same six stages as before migraphx/llama existed' {
        Assert-Equal '' (Invoke-Resolve).Variant 'default variant'
        foreach ($case in @(@{ Variant = '' }, @{ Variant = 'nvidia' }, @{ Gpu = $true })) {
            $r = Invoke-Resolve @case
            Assert-Equal 'base,sdk,toolchain,media,torch,final' ($r.Stages -join ',') "stages for $($case.Keys) $($case.Values)"
        }
    }

    It 'keeps all eight stages on the rocm lane, and -NoRocmSpikes drops only migraphx' {
        Assert-Equal ($script:DefaultStages -join ',') ((Invoke-Resolve -Variant 'rocm').Stages -join ',') 'rocm default'
        Assert-Equal 'base,sdk,toolchain,media,llama,torch,final' ((Invoke-Resolve -Variant 'rocm' -NoRocmSpikes $true).Stages -join ',') 'rocm -NoRocmSpikes'
    }

    It 'maps -Gpu and -Variant nvidia to the same nvidia lane' {
        Assert-Equal 'nvidia' (Invoke-Resolve -Gpu $true).Variant '-Gpu'
        Assert-Equal 'nvidia' (Invoke-Resolve -Variant 'nvidia').Variant '-Variant nvidia'
    }

    It 'refuses what a variant cannot build, the retired rocm stage, and a rocm stale-parent gap' {
        # Case = the Invoke-Resolve splat; Pattern = the refusal that must fire. Bound stages throughout.
        $refusals = @(
            @{ Pattern = 'sdk stage on -Variant rocm'; Case = @{ Stages = @('rocm', 'torch'); StagesBound = $true } }
            @{ Pattern = 'sdk stage on -Variant rocm'; Case = @{ Variant = 'nvidia'; Stages = @('rocm'); StagesBound = $true } }
            @{ Pattern = 'sdk stage on -Variant rocm'; Case = @{ Variant = 'rocm'; Stages = @('rocm', 'final'); StagesBound = $true } }
            @{ Pattern = 'cannot be combined'; Case = @{ Variant = 'rocm'; Gpu = $true } }
            @{ Pattern = 'amd64-only'; Case = @{ Variant = 'rocm'; TargetArch = 'arm64' } }
            @{ Pattern = 'needs -Variant rocm'; Case = @{ Stages = @('migraphx'); StagesBound = $true } }
            @{ Pattern = 'needs -Variant rocm'; Case = @{ Variant = 'nvidia'; Stages = @('llama', 'final'); StagesBound = $true } }
            @{ Pattern = 'NoRocmSpikes needs -Variant rocm'; Case = @{ NoRocmSpikes = $true } }
            @{ Pattern = 'NoRocmSpikes needs -Variant rocm'; Case = @{ Gpu = $true; NoRocmSpikes = $true } }
            @{ Pattern = 'contradicts -NoRocmSpikes'; Case = @{ Variant = 'rocm'; NoRocmSpikes = $true; Stages = @('migraphx'); StagesBound = $true } }
            @{ Pattern = 'skips migraphx,llama'; Case = @{ Variant = 'rocm'; Stages = @('media', 'torch', 'final'); StagesBound = $true } }
            @{ Pattern = 'skips llama'; Case = @{ Variant = 'rocm'; Stages = @('migraphx', 'torch'); StagesBound = $true } }
            @{ Pattern = 'NoRocmSpikes to skip migraphx'; Case = @{ Variant = 'rocm'; Stages = @('media', 'llama'); StagesBound = $true } }
            # final builds FROM torch on rocm, so skipping torch ships an earlier run's torch.
            @{ Pattern = 'skips torch'; Case = @{ Variant = 'rocm'; Stages = @('llama', 'final'); StagesBound = $true } }
            @{ Pattern = 'skips llama,torch'; Case = @{ Variant = 'rocm'; Stages = @('migraphx', 'final'); StagesBound = $true } }
            @{ Pattern = 'skips migraphx,llama,torch'; Case = @{ Variant = 'rocm'; Stages = @('media', 'final'); StagesBound = $true } }
            @{ Pattern = 'skips llama,torch'; Case = @{ Variant = 'rocm'; NoRocmSpikes = $true; Stages = @('media', 'final'); StagesBound = $true } }
        )
        foreach ($r in $refusals) {
            $case = $r.Case
            $label = ($case.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value -join ',')" }) -join ' '
            Assert-Throws { Invoke-Resolve @case } $label -MessagePattern $r.Pattern
        }
    }

    It 'accepts a contiguous rocm stage list, and never applies the gap rule to the default or nvidia lanes' {
        foreach ($ok in @(@('media'), @('final'), @('torch', 'final'), @('llama', 'torch', 'final'), @('sdk', 'toolchain', 'media'), @('media', 'migraphx'))) {
            Assert-Equal ($ok -join ',') ((Invoke-Resolve -Variant 'rocm' -Stages $ok -StagesBound $true).Stages -join ',') "contiguous $($ok -join ',')"
        }
        Assert-Equal 'media,llama,torch' ((Invoke-Resolve -Variant 'rocm' -NoRocmSpikes $true -Stages @('media', 'llama', 'torch') -StagesBound $true).Stages -join ',') 'no migraphx gap under -NoRocmSpikes'
        Assert-Equal 'media,torch,final' ((Invoke-Resolve -Stages @('media', 'torch', 'final') -StagesBound $true).Stages -join ',') 'default lane'
        Assert-Equal 'media,final' ((Invoke-Resolve -Gpu $true -Stages @('media', 'final') -StagesBound $true).Stages -join ',') 'nvidia lane'
    }

    It 'lets a push go only to the tag of its own variant' {
        $repo = 'ghcr.io/kataglyphis/kataglyphis_beschleuniger'
        Invoke-Resolve -Variant 'rocm' -PushRef "${repo}:winamd64-rocm" | Out-Null
        Invoke-Resolve -PushRef "${repo}:winamd64" | Out-Null
        Invoke-Resolve -Variant 'rocm' -PushRef 'localhost:5000/k:winamd64-rocm' | Out-Null   # a registry port is not the tag
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef "${repo}:winamd64" } 'rocm bytes under the default tag' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef "${repo}@sha256:0123" } 'rocm by digest' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef 'localhost:5000/k' } 'rocm with no tag' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -PushRef "${repo}:winamd64-rocm" } 'default bytes under the rocm tag' -MessagePattern 'not -Variant rocm'
        Assert-Throws { Invoke-Resolve -Gpu $true -PushRef "${repo}:winamd64-rocm" } 'nvidia bytes under the rocm tag' -MessagePattern 'not -Variant rocm'
        # nvidia has a tag of its own too, on both lanes.
        Invoke-Resolve -Gpu $true -PushRef "${repo}:winamd64-nvidia" | Out-Null
        Invoke-Resolve -Variant 'nvidia' -TargetArch 'arm64' -PushRef "${repo}:winarm64-nvidia" | Out-Null
        Assert-Throws { Invoke-Resolve -Gpu $true -PushRef "${repo}:winamd64" } 'CUDA bytes under the default tag' -MessagePattern "':winamd64-nvidia'"
        Assert-Throws { Invoke-Resolve -Gpu $true -TargetArch 'arm64' -PushRef "${repo}:winarm64" } 'CUDA bytes under the default bundle' -MessagePattern "':winarm64-nvidia'"
        Assert-Throws { Invoke-Resolve -PushRef "${repo}:winamd64-nvidia" } 'default bytes under the nvidia tag' -MessagePattern 'not -Variant nvidia'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef "${repo}:winamd64-nvidia" } 'rocm bytes under the nvidia tag' -MessagePattern 'not -Variant nvidia'
    }
}

Describe 'Assert-BkCacheExportRef (no nvidia registry cache in the public package)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Assert-BkCacheExportRef')
    $script:Pub = 'ghcr.io/kataglyphis/kataglyphis_beschleuniger'

    It 'refuses an nvidia cache export into the public package, by tag or by digest' {
        foreach ($ref in "${script:Pub}:cache-nvidia", "${script:Pub}@sha256:0123", $script:Pub) {
            Assert-Throws { Assert-BkCacheExportRef -Variant 'nvidia' -ExportCacheRef $ref -PublicRepo $script:Pub } $ref -MessagePattern 'kataglyphis_beschleuniger-stages, which is private'
        }
    }

    It 'lets it go to the private stage package, and leaves the other lanes and an unset ref alone' {
        Assert-BkCacheExportRef -Variant 'nvidia' -ExportCacheRef "${script:Pub}-stages:cache-nvidia" -PublicRepo $script:Pub
        Assert-BkCacheExportRef -Variant 'nvidia' -ExportCacheRef 'localhost:5000/k:cache' -PublicRepo $script:Pub
        Assert-BkCacheExportRef -Variant 'nvidia' -ExportCacheRef '' -PublicRepo $script:Pub
        foreach ($v in '', 'rocm') { Assert-BkCacheExportRef -Variant $v -ExportCacheRef "${script:Pub}:cache" -PublicRepo $script:Pub }
    }

    It 'is called with the versions.env package before any stage solves' {
        $src = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1') -Raw
        $at = $src.IndexOf("Assert-BkCacheExportRef -Variant `$Variant -ExportCacheRef `$ExportCacheRef -PublicRepo (Get-Ver 'IMAGE_REGISTRY_PREFIX')")
        Assert-True ($at -gt 0 -and $at -lt $src.IndexOf("Invoke-BkStage -Dockerfile 'windows/Dockerfile.base'")) "called at $at, before the base solve"
    }
}

Describe 'Get-BkRocmStageArg (rocm-only build-args)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Add-BkVersionPins', 'Get-BkRocmStageArg')
    # 'KEY=value,...' so a whole result compares in one assertion ('' = no build-arg at all).
    function Format-StageArg([string]$Variant, [string]$Stage, [bool]$NoRocmSpikes = $false, [hashtable]$Pins = @{}) {
        $h = Get-BkRocmStageArg -Variant $Variant -Stage $Stage -NoRocmSpikes $NoRocmSpikes -VersionTable $Pins
        return (($h.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')
    }
    $script:FakePins = @{ TORCH_ROCM_WINDOWS_ROCM_URL = 'u'; TORCH_ROCM_WINDOWS_ROCM_SHA256 = 's'; TVM_REF = 'v1'; ROCM_WINDOWS_RELEASE = '10.0.0' }

    It 'adds nothing on the default and nvidia lanes, whatever -NoRocmSpikes or the pins say' {
        foreach ($s in 'base', 'sdk', 'toolchain', 'media-core', 'media-litert', 'media-tvm', 'migraphx', 'llama', 'torch', 'final', 'smoke-gate') {
            foreach ($v in '', 'nvidia') {
                Assert-Equal '' (Format-StageArg $v $s -Pins $script:FakePins) "variant '$v' stage $s"
                Assert-Equal '' (Format-StageArg $v $s $true $script:FakePins) "variant '$v' stage $s -NoRocmSpikes"
            }
        }
    }

    It 'passes TVM_ROCM to media-tvm and TORCH_ROCM plus the TORCH_ROCM_WINDOWS_* pins to torch on the rocm lane only' {
        Assert-Equal 'TVM_ROCM=1' (Format-StageArg 'rocm' 'media-tvm' -Pins $script:FakePins) 'media-tvm'
        Assert-Equal 'TVM_ROCM=0' (Format-StageArg 'rocm' 'media-tvm' $true) 'media-tvm -NoRocmSpikes'
        Assert-Equal 'TORCH_ROCM=1,TORCH_ROCM_WINDOWS_ROCM_SHA256=s,TORCH_ROCM_WINDOWS_ROCM_URL=u' (Format-StageArg 'rocm' 'torch' -Pins $script:FakePins) 'torch'
        foreach ($s in 'media-litert', 'sdk', 'final') {
            Assert-Equal '' (Format-StageArg 'rocm' $s -Pins $script:FakePins) "rocm stage $s"
        }
    }

    It 'passes ORT_WEBGPU (0 under -NoRocmSpikes) and only the ORT_WEBGPU_WINDOWS_* pins to media-core on the rocm lane' {
        # ORT_WEBGPU_ALLOW_CROSS is the Linux lane's toggle: a looser prefix would forward it too.
        $pins = $script:FakePins + @{ ORT_WEBGPU_WINDOWS_DAWN_SHA256 = 'd'; ORT_WEBGPU_ALLOW_CROSS = 'true'; ORT_ENABLE_WEBGPU = 'true' }
        Assert-Equal 'ORT_WEBGPU=1,ORT_WEBGPU_WINDOWS_DAWN_SHA256=d' (Format-StageArg 'rocm' 'media-core' -Pins $pins) 'media-core'
        Assert-Equal 'ORT_WEBGPU=0,ORT_WEBGPU_WINDOWS_DAWN_SHA256=d' (Format-StageArg 'rocm' 'media-core' $true $pins) 'media-core -NoRocmSpikes'
        foreach ($v in '', 'nvidia') { Assert-Equal '' (Format-StageArg $v 'media-core' -Pins $pins) "variant '$v' media-core" }
    }

    It 'the onnx stage''s ORT_WEBGPU* ARGs are valueless and only in media-core-built-onnx (cpu/nvidia RUN env unchanged)' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder')
        $stage = [regex]::Match($df, '(?s)FROM common AS media-core-built-onnx\r?\n(.*?)\r?\nRUN ')
        Assert-True $stage.Success 'the media-core-built-onnx stage and its RUN'
        Assert-Equal 6 ([regex]::Matches($stage.Groups[1].Value, '(?m)^ARG ORT_WEBGPU\w*\r?$')).Count 'six valueless ARGs before the ORT RUN'
        Assert-Equal 6 ([regex]::Matches($df, '(?m)^ARG ORT_WEBGPU')).Count 'and no other stage (or default) declares one'
    }

    It 'tells the rocm smoke gate which spike mode the image must carry (both modes share their tags)' {
        Assert-Equal 'EXPECT_ROCM_SPIKES=1' (Format-StageArg 'rocm' 'smoke-gate') 'spikes on'
        Assert-Equal 'EXPECT_ROCM_SPIKES=0' (Format-StageArg 'rocm' 'smoke-gate' $true) '-NoRocmSpikes'
    }

    It 'sends Dockerfile.torch and the onnx stage exactly the pins each declares' {
        # A pin two torch stages declare (rocm-1 and torch-rocm-wheels) is still one build-arg.
        foreach ($c in @(@{ Stage = 'torch'; Df = 'windows\Dockerfile.torch'; Pin = 'TORCH_ROCM_WINDOWS_\w+|PYTORCH_VERSION|TORCHVISION_VERSION|ROCM_WINDOWS_GFX_FAMILY'; Switch = 'TORCH_ROCM' }
                @{ Stage = 'media-core'; Df = 'windows\Dockerfile.media-builder'; Pin = 'ORT_WEBGPU_WINDOWS_\w+'; Switch = 'ORT_WEBGPU' })) {
            $sent = @((Get-BkRocmStageArg -Variant 'rocm' -Stage $c.Stage -VersionTable (Get-DriverVariantPin)).Keys | Where-Object { $_ -ne $c.Switch })
            $declared = @(Get-DriverVariantDeclaredArg $c.Df $c.Pin | Sort-Object -Unique)
            Assert-True ($declared.Count -gt 0) "$($c.Df) declares no $($c.Pin) pin"
            Assert-Equal (($declared | Sort-Object) -join ',') (($sent | Sort-Object) -join ',') "declared vs sent, $($c.Stage)"
        }
    }

    It 'every rocm-only build-arg is declared by its consumer, inert: default 0 or valueless' {
        # buildctl silently DROPS a build-arg no ARG declares, so an undeclared key is a no-op, not an error.
        $consumers = @{ TVM_ROCM = 'windows\Dockerfile.media-builder'; TORCH_ROCM = 'windows\Dockerfile.torch'; ORT_WEBGPU = 'windows\Dockerfile.media-builder' }
        $keys = @((Get-BkRocmStageArg -Variant 'rocm' -Stage 'media-tvm').Keys) + @((Get-BkRocmStageArg -Variant 'rocm' -Stage 'torch').Keys) +
            @((Get-BkRocmStageArg -Variant 'rocm' -Stage 'media-core').Keys)
        foreach ($k in $keys) {
            Assert-True $consumers.ContainsKey($k) "no consumer Dockerfile recorded for $k"
            $df = Get-Content -Raw (Join-Path (Get-RepoRoot) $consumers[$k])
            Assert-Match "(?m)^ARG $k(=`"?0`"?)?\s*$" $df "$($consumers[$k]) must declare ARG $k=0 or a valueless ARG $k"
        }
    }
}
