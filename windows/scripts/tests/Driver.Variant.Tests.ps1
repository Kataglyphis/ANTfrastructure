#requires -Version 7.0
# Build-Buildkit.ps1 -Variant: the resolver's refusals, the lane tags (a golden table locks cpu/nvidia),
# the rocm-only build-args and the rocm chain's wiring (sdk slot, migraphx/llama). NOT covered: a real solve.

# The two sides of every build-arg parity check below: the ARGs a Dockerfile declares, and versions.env.
function Get-DriverVariantDeclaredArg([string]$Dockerfile, [string]$NamePattern = '\w+') {
    $path = Join-Path (Get-RepoRoot) $Dockerfile
    if (-not (Test-Path -LiteralPath $path)) { throw "$Dockerfile does not exist, but the driver solves it" }
    return @(Select-String -LiteralPath $path -Pattern "^ARG ($NamePattern)" -CaseSensitive | ForEach-Object { $_.Matches[0].Groups[1].Value })
}
function Get-DriverVariantPin { return ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env') }

Describe 'Resolve-BkVariant' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Resolve-BkVariant')
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
    }
}

Describe 'Get-BkRocmStageArg (rocm-only build-args)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Get-BkRocmStageArg')
    # 'KEY=value,...' so a whole result compares in one assertion ('' = no build-arg at all).
    function Format-StageArg([string]$Variant, [string]$Stage, [bool]$NoRocmSpikes = $false, [hashtable]$Pins = @{}) {
        $h = Get-BkRocmStageArg -Variant $Variant -Stage $Stage -NoRocmSpikes $NoRocmSpikes -VersionTable $Pins
        return (($h.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')
    }
    $script:FakePins = @{ TORCH_ROCM_WINDOWS_TORCH_URL = 'u'; TORCH_ROCM_WINDOWS_TORCH_SHA256 = 's'; TVM_REF = 'v1'; ROCM_WINDOWS_RELEASE = '10.0.0' }

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
        Assert-Equal 'TORCH_ROCM=1,TORCH_ROCM_WINDOWS_TORCH_SHA256=s,TORCH_ROCM_WINDOWS_TORCH_URL=u' (Format-StageArg 'rocm' 'torch' -Pins $script:FakePins) 'torch'
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
        foreach ($c in @(@{ Stage = 'torch'; Df = 'windows\Dockerfile.torch'; Pin = 'TORCH_ROCM_WINDOWS_\w+'; Switch = 'TORCH_ROCM' }
                @{ Stage = 'media-core'; Df = 'windows\Dockerfile.media-builder'; Pin = 'ORT_WEBGPU_WINDOWS_\w+'; Switch = 'ORT_WEBGPU' })) {
            $sent = @((Get-BkRocmStageArg -Variant 'rocm' -Stage $c.Stage -VersionTable (Get-DriverVariantPin)).Keys | Where-Object { $_ -ne $c.Switch })
            $declared = @(Get-DriverVariantDeclaredArg $c.Df $c.Pin)
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

Describe 'Get-BkTag: lane tags (golden table)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Get-BkTag')
    $driverPath = Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1'
    $driverAst = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$null, [ref]$null)
    # The driver's own assignment right-hand sides, evaluated here: the test uses the shipped values.
    function Get-DriverAssignment([string]$Left) {
        $a = @($driverAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Left }, $true))
        if ($a.Count -ne 1) { throw "expected one '$Left' assignment in Build-Buildkit.ps1, found $($a.Count)" }
        return [scriptblock]::Create("param(`$Variant)`n" + $a[0].Right.Extent.Text)
    }
    $script:NoSuffixTags = @(& (Get-DriverAssignment '$script:NoSuffixTags'))
    $infixBlock = Get-DriverAssignment '$script:BkVariantInfix'
    function Get-LaneTag([string]$Variant, [string]$Arch, [string]$Name) {
        $script:BkVariantInfix = & $infixBlock $Variant
        # Get-BkTag reads the script param $TargetArch; a local here is what it sees (dynamic scope).
        Set-Variable -Name 'TargetArch' -Value $Arch
        return Get-BkTag $Name
    }
    $p = 'docker.io/local/kataglyphis:bk-'
    # Today's names, written out: a cpu or nvidia tag that moves is a regression, not a refactor.
    $script:Golden = [ordered]@{
        'windows-base'             = @('windows-base', 'windows-base')
        'windows-sdk'              = @('windows-sdk', 'windows-sdk')
        'windows-toolchain'        = @('windows-toolchain', 'windows-toolchain')
        'windows-media-core-onnx'  = @('windows-media-core-onnx', 'windows-media-core-onnx-arm64')
        'windows-media-core-ffmpeg' = @('windows-media-core-ffmpeg', 'windows-media-core-ffmpeg-arm64')
        'windows-media-core-opencv' = @('windows-media-core-opencv', 'windows-media-core-opencv-arm64')
        'windows-media-core-hailo' = @('windows-media-core-hailo', 'windows-media-core-hailo-arm64')
        'windows-media-core'       = @('windows-media-core', 'windows-media-core-arm64')
        'windows-media-litert'     = @('windows-media-litert', 'windows-media-litert-arm64')
        'windows-media-tvm'        = @('windows-media-tvm', 'windows-media-tvm-arm64')
        'windows-media'            = @('windows-media', 'windows-media-arm64')
        'windows-torch'            = @('windows-torch', 'windows-torch-arm64')
        'winamd64'                 = @('winamd64', 'winamd64')
        'winarm64'                 = @('winarm64', 'winarm64')
    }
    $script:RocmGolden = [ordered]@{
        'windows-base'              = 'windows-base'
        'windows-sdk'               = 'windows-sdk-rocm'
        'windows-toolchain'         = 'windows-toolchain-rocm'
        'windows-media-core-onnx'   = 'windows-media-core-onnx-rocm'
        'windows-media-core-ffmpeg' = 'windows-media-core-ffmpeg-rocm'
        'windows-media-core-opencv' = 'windows-media-core-opencv-rocm'
        'windows-media-core-hailo'  = 'windows-media-core-hailo-rocm'
        'windows-media-core'        = 'windows-media-core-rocm'
        'windows-media-litert'      = 'windows-media-litert-rocm'
        'windows-media-tvm'         = 'windows-media-tvm-rocm'
        'windows-media'             = 'windows-media-rocm'
        'windows-media-migraphx'    = 'windows-media-migraphx-rocm'
        'windows-media-llama'       = 'windows-media-llama-rocm'
        'windows-torch'             = 'windows-torch-rocm'
        'winamd64-rocm'             = 'winamd64-rocm'
    }

    It 'keeps every default and nvidia tag byte-identical on amd64 and arm64' {
        foreach ($v in '', 'nvidia') {
            foreach ($name in $script:Golden.Keys) {
                Assert-Equal "$p$($script:Golden[$name][0])" (Get-LaneTag $v 'amd64' $name) "variant '$v' amd64 $name"
                Assert-Equal "$p$($script:Golden[$name][1])" (Get-LaneTag $v 'arm64' $name) "variant '$v' arm64 $name"
            }
        }
    }

    It 'gives the rocm lane its own tag from sdk on, shares base, and never doubles the suffix' {
        foreach ($name in $script:RocmGolden.Keys) {
            Assert-Equal "$p$($script:RocmGolden[$name])" (Get-LaneTag 'rocm' 'amd64' $name) "rocm $name"
        }
    }

    It 'covers every tag name the driver asks for (a new stage must join the golden table)' {
        $src = Get-Content -Raw $driverPath
        $names = @([regex]::Matches($src, "Get-BkTag '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        # Dynamic names: "windows-$branch" for the aux branches and the final tag variable.
        $names += @('windows-media-litert', 'windows-media-tvm', 'winamd64', 'winarm64', 'winamd64-rocm')
        Assert-True ($names.Count -ge 12) "scanner found only $($names.Count) tag names"
        $missing = @($names | Sort-Object -Unique | Where-Object { -not $script:Golden.Contains($_) -and -not $script:RocmGolden.Contains($_) })
        Assert-Equal '' ($missing -join ',') 'tag names with no golden row'
    }
}

Describe 'Build-Buildkit.ps1: rocm chain wiring' {
    $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')
    # The sdk block runs up to the toolchain block that follows it.
    $sdkAt = $src.IndexOf("if (`$Stages -contains 'sdk')")
    $sdkBlock = if ($sdkAt -ge 0) { $src.Substring($sdkAt, $src.IndexOf("if (`$Stages -contains 'toolchain')") - $sdkAt) } else { '' }

    It 'builds Dockerfile.rocm in the sdk slot FROM the plain base, and leaves the nvidia and cpu branches alone' {
        Assert-True ($sdkBlock.Length -gt 0) 'sdk block not found'
        Assert-Match "(?s)if \(\`$isNvidia\) \{.+?Dockerfile\.nvidia' -Context 'windows' -Tag \(Get-BkTag 'windows-sdk'\)" $sdkBlock 'nvidia branch first, unchanged'
        Assert-Match "(?s)\} elseif \(\`$Variant -eq 'rocm'\) \{\s+#[^\r\n]*\s+Invoke-BkStage -Dockerfile 'windows/Dockerfile\.rocm' -Tag \(Get-BkTag 'windows-sdk'\) -BuildArgs @\{\s+BASE_IMAGE\s+= Get-BkTag 'windows-base'" $sdkBlock 'rocm branch'
        foreach ($k in 'ROCM_WINDOWS_RELEASE', 'ROCM_WINDOWS_GFX_FAMILY', 'ROCM_WINDOWS_TARBALL_SHA256') {
            Assert-Match "$k\s+= Get-Ver '$k'" $sdkBlock "rocm sdk gets $k"
        }
        Assert-Match "(?s)\} else \{.+?-Label 'bk-cpu-alias'" $sdkBlock 'cpu alias last, unchanged'
    }

    It 'has no post-media rocm stage left' {
        Assert-False ($src -match "Get-BkTag 'windows-rocm'") 'bk-windows-rocm is gone'
        Assert-False ($src -match "Get-BkTag 'windows-torch-rocm'") 'the torch tag comes from the lane infix alone'
        Assert-Equal 1 @([regex]::Matches($src, "windows/Dockerfile\.rocm'")).Count 'Dockerfile.rocm is solved exactly once'
        Assert-Match "windows/Dockerfile\.rocm'" $sdkBlock 'and that once is in the sdk block'
    }

    It 'builds migraphx FROM the merged media and llama FROM migraphx (or media under -NoRocmSpikes)' {
        Assert-Match "\`$migraphxTag = Get-BkTag 'windows-media-migraphx'" $src 'migraphx handoff tag'
        Assert-Match "\`$llamaTag = Get-BkTag 'windows-media-llama'" $src 'llama handoff tag'
        Assert-Match "(?s)\`$migraphxArgs = @\{\s+BASE_IMAGE\s+= Get-BkTag 'windows-media'\s" $src 'migraphx base'
        Assert-Match "Dockerfile\.rocm-migraphx' -Target 'built' -Tag \`$migraphxTag -BuildArgs \`$migraphxArgs" $src 'migraphx stage'
        Assert-Match "BASE_IMAGE\s+= \`$\(if \(\`$NoRocmSpikes\) \{ Get-BkTag 'windows-media' \} else \{ \`$migraphxTag \}\)" $src 'llama base'
        Assert-Match "Dockerfile\.rocm-llama' -Target 'built' -Tag \`$llamaTag -BuildArgs \`$llamaArgs" $src 'llama stage'
    }

    It 'passes every versions.env pin migraphx and llama declare, and nothing they do not declare' {
        # An ARG the driver never sends falls back to its baked default (a stale pin); a sent key no ARG declares is dropped.
        $pins = Get-DriverVariantPin
        foreach ($stage in @(@{ Var = 'migraphxArgs'; Df = 'windows\Dockerfile.rocm-migraphx' }, @{ Var = 'llamaArgs'; Df = 'windows\Dockerfile.rocm-llama' })) {
            # The block runs to the end of its assignment line: explicit Get-Ver keys, plus a shared map if it calls one.
            $block = [regex]::Match($src, "(?s)\`$$($stage.Var) = @\{(.+?\r?\n\s*\}[^\r\n]*)").Groups[1].Value
            Assert-True ($block.Length -gt 0) "`$$($stage.Var) block not found"
            $sent = @()
            foreach ($m in [regex]::Matches($block, "(?m)^\s*(\w+)\s*= Get-Ver '(\w+)'")) {
                Assert-Equal $m.Groups[1].Value $m.Groups[2].Value "$($stage.Var): build-arg and versions.env key differ"
                $sent += $m.Groups[1].Value
            }
            foreach ($m in [regex]::Matches($block, "Get-MediaBranchVersionArg -Branch '([\w-]+)' -VersionTable \`$versions")) {
                $sent += @((Get-MediaBranchVersionArg -Branch $m.Groups[1].Value -VersionTable $pins).Keys)
            }
            Assert-True ($sent.Count -gt 0) "$($stage.Var) sends no versions.env pin at all"
            $declared = Get-DriverVariantDeclaredArg $stage.Df
            $undeclared = @($sent | Where-Object { $_ -notin $declared })
            Assert-Equal '' ($undeclared -join ',') "$($stage.Df) declares no ARG for these driver build-args"
            $unsent = @($declared | Where-Object { $pins.Contains($_) -and $_ -notin $sent })
            Assert-Equal '' ($unsent -join ',') "$($stage.Df) declares these versions.env pins but the driver never sends them"
        }
    }

    It 'builds torch FROM llama on rocm and FROM media elsewhere, with the cpu/nvidia torch extra unchanged' {
        Assert-Match "\`$torchTag = Get-BkTag 'windows-torch'" $src 'one torch tag expression'
        Assert-Match "BASE_IMAGE = \`$\(if \(\`$Variant -eq 'rocm'\) \{ \`$llamaTag \} else \{ Get-BkTag 'windows-media' \}\)" $src 'torch base'
        Assert-Match "PYTORCH_EXTRA = \`$\(if \(\`$isNvidia\) \{ 'pytorch-cu130' \} else \{ 'pytorch-cpu' \}\)" $src 'torch extra'
        Assert-Match "\} \+ \(Get-BkRocmStageArg -Variant \`$Variant -Stage 'torch' -VersionTable \`$versions\)\)" $src 'TORCH_ROCM only through the rocm helper'
    }

    It 'sends TVM_ROCM and ORT_WEBGPU through the media branch loop, and forwards the lane to the -ConcurrentAux children' {
        Assert-Match "\+ \`$archArgs \+ \(Get-BkRocmStageArg -Variant \`$Variant -Stage \`$branch -NoRocmSpikes \(\[bool\]\`$NoRocmSpikes\) -VersionTable \`$versions\)" $src 'branch args (with the pins)'
        Assert-Match "if \(\`$isNvidia\) \{ \`$auxArgs \+= '-Gpu' \}" $src 'nvidia children keep -Gpu'
        Assert-Match "if \(\`$Variant -eq 'rocm'\) \{ \`$auxArgs \+= @\('-Variant', 'rocm'\) \+ @\(if \(\`$NoRocmSpikes\) \{ '-NoRocmSpikes' \}\) \}" $src 'rocm children get -Variant rocm and -NoRocmSpikes'
    }

    It 'refuses every post-merge stage when the merge is skipped (stale media, backlog #39)' {
        Assert-Match "\`$downstream = @\('migraphx', 'llama', 'torch', 'final'\)" $src 'fail-closed list'
    }

    It 'keeps the rocm final tag and the lane''s own torch as the final base' {
        Assert-Match "elseif \(\`$Variant -eq 'rocm'\) \{ 'winamd64-rocm' \}" $src 'separate final tag'
        Assert-Match "\`$finalBase = if \(\`$TargetArch -eq 'amd64'\) \{ \`$torchTag \}" $src 'final builds on the lane''s own torch'
    }

    It 'turns the ROCm smoke checks on for the rocm lane with its spike mode, and the smoke Dockerfile runs them' {
        Assert-Match "EXPECT_ROCM = \`$\(if \(\`$Variant -eq 'rocm'\)" $src 'driver passes EXPECT_ROCM'
        # The spike mode comes from the rocm helper (@{} on cpu/nvidia) and reaches the amd64 gate's solve.
        Assert-Match "(?s)\`$smokeArgs = Get-BkRocmStageArg -Variant \`$Variant -Stage 'smoke-gate' -NoRocmSpikes \(\[bool\]\`$NoRocmSpikes\)\s+\`$smokeArgs \+= @\{.+?Dockerfile\.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs \`$smokeArgs -MaxAttempts 1" $src 'smoke-gate args'
        $gate = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.smoke-gate')
        Assert-Match '(?m)^ARG EXPECT_ROCM=0' $gate 'smoke Dockerfile declares EXPECT_ROCM'
        # A valueless ARG adds nothing to the cpu/nvidia RUN env, and an unset value fails Test-RocmImage.ps1.
        Assert-Match '(?m)^ARG EXPECT_ROCM_SPIKES\s*$' $gate 'EXPECT_ROCM_SPIKES declared without a default'
        Assert-Match "EXPECT_ROCM -eq '1'.*Test-RocmImage\.ps1" ($gate -replace '\s+', ' ') 'and runs Test-RocmImage.ps1 on it'
        $rocmImage = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-RocmImage.ps1')
        Assert-Match "\`$ExpectSpikes = \`$env:EXPECT_ROCM_SPIKES" $rocmImage 'Test-RocmImage.ps1 reads the mode from the env'
        # The gate bind-mounts windows/scripts, so rocm-checks\ reaches Test-RocmImage.ps1's default path.
        Assert-Match 'source=windows/scripts,target=C:\\gate\\scripts' $gate 'scripts mount'
    }

    It 'gives the rocm sdk a floor sized for the ROCm tree, without touching the other stages' {
        Assert-True ((Get-StageDiskFloorGb -Label 'Dockerfile.rocm') -gt (Get-StageDiskFloorGb -Label 'something-new')) 'rocm sdk above the default'
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'Dockerfile.rocm-migraphx:built') 'the sdk rule is anchored'
        Assert-Equal 60 (Get-StageDiskFloorGb -Label 'Dockerfile.nvidia') 'nvidia sdk unchanged'
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'bk-cpu-alias') 'cpu alias unchanged'
    }
}
