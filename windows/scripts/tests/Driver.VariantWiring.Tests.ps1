#requires -Version 7.0
# Build-Buildkit.ps1 -Variant: refusals, golden lane tags, rocm build-args and chain wiring; not a real solve.

Import-Module (Join-Path $PSScriptRoot 'WindowsDriverVariant.Fixture.psm1') -Force

. (Get-ScriptFunctionDefinition -ScriptPath 'windows/Build-Buildkit.ps1' -FunctionName 'Add-BkVersionPins', 'Get-BkRocmStageArg')

Describe 'Get-BkTag: lane tags (golden table)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Get-BkTag')
    $driverPath = Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1'
    $driverAst = (Get-TestScriptAst -ScriptPath $driverPath)
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
    # nvidia gets its own tag from sdk on, like rocm, on both arches (arm64 after the infix).
    $script:NvidiaGolden = [ordered]@{
        'windows-base'              = @('windows-base', 'windows-base')
        'windows-sdk'               = @('windows-sdk-nvidia', 'windows-sdk-nvidia')
        'windows-tensorrt-sdk'      = @('windows-tensorrt-sdk-nvidia', 'windows-tensorrt-sdk-nvidia')
        'windows-toolchain'         = @('windows-toolchain-nvidia', 'windows-toolchain-nvidia')
        'windows-media-core-onnx'   = @('windows-media-core-onnx-nvidia', 'windows-media-core-onnx-nvidia-arm64')
        'windows-media-core-ffmpeg' = @('windows-media-core-ffmpeg-nvidia', 'windows-media-core-ffmpeg-nvidia-arm64')
        'windows-media-core-opencv' = @('windows-media-core-opencv-nvidia', 'windows-media-core-opencv-nvidia-arm64')
        'windows-media-core-hailo'  = @('windows-media-core-hailo-nvidia', 'windows-media-core-hailo-nvidia-arm64')
        'windows-media-core'        = @('windows-media-core-nvidia', 'windows-media-core-nvidia-arm64')
        'windows-media-litert'      = @('windows-media-litert-nvidia', 'windows-media-litert-nvidia-arm64')
        'windows-media-tvm'         = @('windows-media-tvm-nvidia', 'windows-media-tvm-nvidia-arm64')
        'windows-media'             = @('windows-media-nvidia', 'windows-media-nvidia-arm64')
        'windows-torch'             = @('windows-torch-nvidia', 'windows-torch-nvidia-arm64')
        'winamd64-nvidia'           = @('winamd64-nvidia', 'winamd64-nvidia')
        'winarm64-nvidia'           = @('winarm64-nvidia', 'winarm64-nvidia')
    }
    $finalBlock = Get-DriverAssignment '$script:FinalTagName'

    It 'keeps every default tag byte-identical, and gives nvidia its own from sdk on, on amd64 and arm64' {
        foreach ($lane in @(@{ V = ''; Rows = $script:Golden }, @{ V = 'nvidia'; Rows = $script:NvidiaGolden })) {
            foreach ($name in $lane.Rows.Keys) {
                Assert-Equal "$p$($lane.Rows[$name][0])" (Get-LaneTag $lane.V 'amd64' $name) "variant '$($lane.V)' amd64 $name"
                Assert-Equal "$p$($lane.Rows[$name][1])" (Get-LaneTag $lane.V 'arm64' $name) "variant '$($lane.V)' arm64 $name"
            }
        }
    }

    It 'names the final image after its lane and variant' {
        foreach ($c in @(
                @{ V = ''; A = 'amd64'; Want = 'winamd64' }, @{ V = ''; A = 'arm64'; Want = 'winarm64' },
                @{ V = 'nvidia'; A = 'amd64'; Want = 'winamd64-nvidia' }, @{ V = 'nvidia'; A = 'arm64'; Want = 'winarm64-nvidia' },
                @{ V = 'rocm'; A = 'amd64'; Want = 'winamd64-rocm' })) {
            $script:BkVariantInfix = & $infixBlock $c.V
            Set-Variable -Name 'TargetArch' -Value $c.A
            Assert-Equal $c.Want (& $finalBlock $c.V) "variant '$($c.V)' on $($c.A)"
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
        $names += @('windows-media-litert', 'windows-media-tvm', 'winamd64', 'winarm64', 'winamd64-nvidia', 'winarm64-nvidia', 'winamd64-rocm')
        Assert-True ($names.Count -ge 12) "scanner found only $($names.Count) tag names"
        $missing = @($names | Sort-Object -Unique | Where-Object {
                -not $script:Golden.Contains($_) -and -not $script:NvidiaGolden.Contains($_) -and -not $script:RocmGolden.Contains($_) })
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
        Assert-False ($src -match '\$sccache\b') 'the cache settings are secrets on every solve, never build args a history records'
    }

    It 'sends TVM_ROCM and ORT_WEBGPU through the media branch loop, and forwards the lane to the -ConcurrentAux children' {
        Assert-Match "\+ \`$archArgs \+ \(Get-BkRocmStageArg -Variant \`$Variant -Stage \`$branch -NoRocmSpikes \(\[bool\]\`$NoRocmSpikes\) -VersionTable \`$versions\)" $src 'branch args (with the pins)'
        $options = (Get-ScriptFunctionDefinition -ScriptPath 'windows/Build-Buildkit.ps1' -FunctionName 'Add-BkAuxConditionalArguments').ToString()
        Assert-Match '\$auxArgs = Add-BkAuxConditionalArguments -Arguments \$auxArgs -Group Platform' $src 'child arguments include the platform helper'
        Assert-Match "When = \`$isNvidia; Options = @\('-Gpu'\)" $options 'nvidia children keep -Gpu'
        Assert-Match "When = \(\`$Variant -eq 'rocm'\); Options = @\('-Variant', 'rocm'\)" $options 'rocm children get -Variant rocm'
        Assert-Match "When = \(\`$Variant -eq 'rocm' -and \`$NoRocmSpikes\); Options = @\('-NoRocmSpikes'\)" $options 'rocm children keep the spike mode'
        Assert-Match '\$Arguments \+= \$choice.Options' $options 'selected options reach the child argv'
    }

    It 'keeps optional child arguments ordered and catches a selector that drops them' {
        $prelude = @'
$TargetArch = 'amd64'
$isNvidia = $false
$Variant = 'rocm'
$NoRocmSpikes = $true
$SccacheEndpoint = 'https://cache'
$BuildCtl = 'C:\buildctl.exe'
$SkipHostChecks = $true
$SkipRdna4Gate = $false
$SkipStepLogGate = $false
$NoSccache = $false
$driverParameters = @{ MinFreeGb = 30 }
$MinFreeGb = 30
$HostReserveGb = 4
$BuildArg = @('X=1')
'@
        Invoke-WithFunctionModule -ScriptPath 'windows/Build-Buildkit.ps1' -FunctionName @('Add-BkAuxConditionalArguments') -Prelude $prelude -Body {
            $platform = Add-MutBkAuxConditionalArguments -Arguments @('seed') -Group Platform
            $hostArgs = Add-MutBkAuxConditionalArguments -Arguments @('seed') -Group Host
            Assert-Equal 'seed,-Variant,rocm,-NoRocmSpikes,-SccacheEndpoint,https://cache' ($platform -join ',')
            Assert-Equal 'seed,-BuildCtl,C:\buildctl.exe,-SkipHostChecks,-NoResourceLog,-MinFreeGb,30,-BuildArg,X=1' ($hostArgs -join ',')
        }
        Invoke-WithFunctionModule -ScriptPath 'windows/Build-Buildkit.ps1' -FunctionName @('Add-BkAuxConditionalArguments') -Prelude $prelude `
            -Find 'if ($choice.When) { $Arguments += $choice.Options }' -Replace 'if ($false) { $Arguments += $choice.Options }' -Body {
            $platform = Add-MutBkAuxConditionalArguments -Arguments @('seed') -Group Platform
            Assert-False (($platform -join ',') -eq 'seed,-Variant,rocm,-NoRocmSpikes,-SccacheEndpoint,https://cache')
        }
    }

    It 'refuses every post-merge stage when the merge is skipped (stale media, backlog #39)' {
        Assert-Match "\`$downstream = @\('migraphx', 'llama', 'torch', 'final'\)" $src 'fail-closed list'
    }

    It 'keeps the rocm final tag and the lane''s own torch as the final base' {
        Assert-Match "\`$script:FinalTagName = .+\) \+ \`$script:BkVariantInfix" $src 'separate final tag: the lane plus the variant infix'
        Assert-Match "\`$finalBase = if \(\`$TargetArch -eq 'amd64'\) \{ \`$torchTag \}" $src 'final builds on the lane''s own torch'
    }

    function Assert-RocmSmokeDockerfile {
        $gate = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.smoke-gate')
        Assert-Match '(?m)^ARG EXPECT_ROCM=0' $gate 'smoke Dockerfile declares EXPECT_ROCM'
        Assert-Match '(?m)^ARG EXPECT_ROCM_SPIKES\s*$' $gate 'EXPECT_ROCM_SPIKES declared without a default'
        Assert-Match "EXPECT_ROCM -eq '1'.*Test-RocmImage\.ps1" ($gate -replace '\s+', ' ') 'and runs Test-RocmImage.ps1 on it'
        $rocmImage = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-RocmImage.ps1')
        Assert-Match "\`$ExpectSpikes = \`$env:EXPECT_ROCM_SPIKES" $rocmImage 'Test-RocmImage.ps1 reads the mode from the env'
        Assert-Match 'source=windows/scripts,target=C:\\gate\\scripts' $gate 'scripts mount'
    }

    It 'turns the ROCm smoke checks on for the rocm lane with its spike mode, and the smoke Dockerfile runs them' {
        Assert-Match "EXPECT_ROCM = \`$\(if \(\`$Variant -eq 'rocm'\)" $src 'driver passes EXPECT_ROCM'
        # The spike mode comes from the rocm helper (@{} on cpu/nvidia) and reaches the amd64 gate's solve.
        Assert-Match "(?s)\`$smokeArgs = Get-BkRocmStageArg -Variant \`$Variant -Stage 'smoke-gate' -NoRocmSpikes \(\[bool\]\`$NoRocmSpikes\)\s+\`$smokeArgs \+= @\{.+?Dockerfile\.smoke-gate' -Label 'smoke-gate' -NoOutput -BuildArgs \`$smokeArgs -MaxAttempts 1" $src 'smoke-gate args'
        Assert-RocmSmokeDockerfile
    }

    It 'gives the rocm sdk a floor sized for the ROCm tree, without touching the other stages' {
        Assert-True ((Get-StageDiskFloorGb -Label 'Dockerfile.rocm') -gt (Get-StageDiskFloorGb -Label 'something-new')) 'rocm sdk above the default'
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'Dockerfile.rocm-migraphx:built') 'the sdk rule is anchored'
        Assert-Equal 60 (Get-StageDiskFloorGb -Label 'Dockerfile.nvidia') 'nvidia sdk unchanged'
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'bk-cpu-alias') 'cpu alias unchanged'
    }
}
