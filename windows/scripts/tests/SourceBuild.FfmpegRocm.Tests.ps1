#requires -Version 7.0
# FFmpeg's rocm-lane AMF path: the one plan (cpu/nvidia get none) and every site keyed on it, the
# config.mak gates, the SHA-pinned header fetch, rocm-checks/FFmpeg.ps1. NOT covered: a real configure.

$script:ffScript = 'windows\scripts\build\Build-FfmpegFromSource.ps1'
$script:ffCheck = 'windows\scripts\build\rocm-checks\FFmpeg.ps1'

# Writes a fixture file, creating its directory first.
function Write-FfRocmTestFile([string]$Path, [string]$Text = 'x') {
    $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Text)
}

Describe 'Get-FfmpegAmfPlan / Get-FfmpegVulkanPlan / Get-FfmpegRocmConfigureArg (rocm lane only)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'ConvertTo-MsysPath', 'Get-FfmpegAmfPlan', 'Get-FfmpegVulkanPlan', 'Get-FfmpegRocmConfigureArg')

    # A slice of the real amd64 cpu-lane line; the property is that NOTHING is appended to it.
    $script:baseFlags = @('--prefix=/c/runtime/ffmpeg', '--enable-shared', '--disable-static',
        '--enable-gpl', '--enable-version3', '--toolchain=msvc', '--cc=clang-cl', '--ld=lld-link',
        '--disable-indev=vfwcap')
    $script:baseLine = [string]::Join(' ', [string[]]$script:baseFlags)

    # The three Vulkan SDK files the plan requires, laid out as the LunarG installer does.
    function New-FfVulkanSdk([string]$Root, [string[]]$Skip = @()) {
        foreach ($rel in 'Include\vulkan\vulkan.h', 'Include\spirv-headers\spirv.h', 'Bin\glslc.exe') {
            if ($rel -notin $Skip) { Write-FfRocmTestFile (Join-Path $Root $rel) }
        }
        return $Root
    }

    # One fixture for every lane: a CUDA root, a HIP tree, fetched AMF headers AND a Vulkan SDK all exist, so only GPU_TYPE decides.
    function Invoke-OnGpuLane([string]$Lane, [scriptblock]$Body) {
        Invoke-InTestDir { param($root)
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'lib\cmake\hip') | Out-Null
            $src = Join-Path $root 'src'
            Write-FfRocmTestFile (Join-Path $src 'compat\amf\AMF\core\Version.h')
            $vk = New-FfVulkanSdk (Join-Path $root 'vulkan\current')
            $laneEnv = @{ GPU_TYPE = $Lane; CUDA_ROOT = $root; HIP_PATH = $root; ROCM_PATH = $null; TENSORRT_ROOT = ''
                CUDA_PATH = $env:CUDA_PATH; CUDA_HOME = $env:CUDA_HOME; PATH = $env:PATH; VULKAN_SDK = $vk }
            Invoke-WithEnv $laneEnv { & $Body (Get-GpuEnvironment) $src $vk }
        }
    }

    It 'cpu and nvidia lanes (real Get-GpuEnvironment): no plan, and the configure line is byte-identical' {
        foreach ($lane in @($null, 'cpu', 'nvidia')) {
            Invoke-OnGpuLane $lane { param($gpu, $src, $vk)
                Assert-Equal ($lane -eq 'nvidia') $gpu.HasCuda "GPU_TYPE='$lane': fixture is the lane it claims"
                $plan = Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $false -SourceDir $src
                Assert-Null $plan "GPU_TYPE='$lane': no plan -> no fetch, no config.mak gates, no include\AMF"
                Assert-Null (Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $true -SourceDir $src) "GPU_TYPE='$lane': cross, no plan and no throw"
                $vkPlan = Get-FfmpegVulkanPlan -AmfPlan $plan -VulkanSdk $env:VULKAN_SDK
                Assert-Null $vkPlan "GPU_TYPE='$lane': a complete Vulkan SDK in VULKAN_SDK is not a Vulkan plan"
                Assert-Null (Get-FfmpegVulkanPlan -AmfPlan $plan -VulkanSdk '') "GPU_TYPE='$lane': no SDK, no plan and no throw"
                $withRocm = [string[]]($script:baseFlags + @(Get-FfmpegRocmConfigureArg -AmfPlan $plan -VulkanPlan $vkPlan))
                Assert-Equal $script:baseLine ([string]::Join(' ', $withRocm)) "GPU_TYPE='$lane': nothing appended, even with a HIP tree and a Vulkan SDK"
                # Even a stray Vulkan plan cannot reach a line whose lane has no AMF (rocm) plan.
                $stray = @{ IncludeDir = '/c/vk/Include'; Glslc = 'C:/vk/Bin/glslc.exe' }
                Assert-Equal 0 @(Get-FfmpegRocmConfigureArg -AmfPlan $plan -VulkanPlan $stray).Count "GPU_TYPE='$lane': no rocm plan, no Vulkan args"
            }
        }
    }

    It 'rocm lane (real Get-GpuEnvironment): one plan; AMF, then Vulkan with the SDK include and its glslc, nothing else' {
        Invoke-OnGpuLane 'rocm' { param($gpu, $src, $vk)
            Assert-True $gpu.HasRocm 'fixture is the rocm lane'
            $plan = Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $false -SourceDir $src
            Assert-Equal (Join-Path $src 'compat\amf') $plan.CompatDir 'headers go to the source tree''s compat\amf'
            Assert-Equal (ConvertTo-MsysPath $plan.CompatDir) $plan.IncludeDir 'configure gets the MSYS form of the same dir'
            Assert-Match '^/[a-z]/.+/compat/amf$' $plan.IncludeDir 'MSYS path'
            Assert-True ($plan.RocmRoot -and $plan.RocmRoot -eq $gpu.RocmRoot) 'the leak gate checks the lane''s real ROCm root'
            $vkPlan = Get-FfmpegVulkanPlan -AmfPlan $plan -VulkanSdk "$vk\"
            Assert-Equal $vk $vkPlan.SdkRoot 'trailing separator dropped'
            Assert-Equal (ConvertTo-MsysPath (Join-Path $vk 'Include')) $vkPlan.IncludeDir 'SDK Include in MSYS form, like the AMF -I'
            Assert-Equal ((Join-Path $vk 'Bin\glslc.exe') -replace '\\', '/') $vkPlan.Glslc 'glslc as a forward-slash Windows path, like --x86asmexe'
            Assert-Equal "--enable-amf|--extra-cflags=-I$($plan.IncludeDir)" (@(Get-FfmpegRocmConfigureArg -AmfPlan $plan) -join '|') 'AMF alone, as before'
            $rocm = @(Get-FfmpegRocmConfigureArg -AmfPlan $plan -VulkanPlan $vkPlan)
            $want = "--enable-amf|--extra-cflags=-I$($plan.IncludeDir)|--enable-vulkan|--extra-cflags=-I$($vkPlan.IncludeDir)|--glslc=$($vkPlan.Glslc)"
            Assert-Equal $want ($rocm -join '|') 'exact rocm args, in order'
        }
    }

    It 'Get-FfmpegVulkanPlan fails closed on the rocm lane: unset or spaced VULKAN_SDK, or any required SDK file missing (mutation)' {
        $amf = @{ CompatDir = 'C:\s\compat\amf'; IncludeDir = '/c/s/compat/amf'; RocmRoot = 'C:\TheRock\build' }
        Assert-Throws { Get-FfmpegVulkanPlan -AmfPlan $amf -VulkanSdk '' } -MessagePattern 'VULKAN_SDK is not set' 'unset'
        Invoke-InTestDir { param($dir)
            $spaced = New-FfVulkanSdk (Join-Path $dir 'Vulkan SDK')
            Assert-Throws { Get-FfmpegVulkanPlan -AmfPlan $amf -VulkanSdk $spaced } -MessagePattern 'whitespace' 'configure word-splits the glslc path'
        }
        foreach ($missing in 'Include\vulkan\vulkan.h', 'Include\spirv-headers\spirv.h', 'Bin\glslc.exe') {
            Invoke-InTestDir { param($dir)
                $sdk = New-FfVulkanSdk (Join-Path $dir 'vk') -Skip $missing
                Assert-Throws { Get-FfmpegVulkanPlan -AmfPlan $amf -VulkanSdk $sdk } -MessagePattern ([regex]::Escape("no $missing under")) "$missing missing"
            }
        }
    }

    It 'refuses a rocm cross build, and configure args before the headers are fetched' {
        $rocmLane = @{ GpuType = 'rocm'; HasRocm = $true; HasCuda = $false; RocmRoot = 'C:\TheRock\build' }
        Assert-Throws { Get-FfmpegAmfPlan -GpuEnvironment $rocmLane -IsCross $true -SourceDir 'C:\s' } `
            -MessagePattern 'amd64-only' 'rocm is amd64-only'
        Invoke-InTestDir { param($dir)
            $plan = Get-FfmpegAmfPlan -GpuEnvironment $rocmLane -SourceDir $dir
            Assert-Throws { Get-FfmpegRocmConfigureArg -AmfPlan $plan } `
                -MessagePattern 'Install-FfmpegAmfHeader must run before configure' 'no silent AMF-less rocm configure'
        }
    }

}

Describe 'Build-FfmpegFromSource.ps1: every AMF step at script level keys on the one plan' {
    # Structural, because the script is monolithic: a site guarded by anything but $ffAmfPlan
    # ($true, -not $ffCross, $false) would fetch/install AMF on cpu/nvidia or drop a rocm gate.
    $script:ffAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-RepoRoot) $script:ffScript), [ref]$null, [ref]$null)

    # Script-level AST nodes only: calls inside the extracted functions are their own tests' business.
    function Find-FfScriptLevelNode([scriptblock]$Predicate) {
        @($script:ffAst.FindAll({ param($n)
            if (-not (& $Predicate $n)) { return $false }
            for ($p = $n.Parent; $p; $p = $p.Parent) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false } }
            return $true }, $true))
    }

    # Condition of the innermost if/elseif clause whose BODY encloses $Node (an else body has none); '' when unguarded.
    function Get-FfEnclosingGuard([System.Management.Automation.Language.Ast]$Node) {
        for ($child = $Node; $child.Parent; $child = $child.Parent) {
            if ($child.Parent -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
            foreach ($clause in $child.Parent.Clauses) {
                if ([object]::ReferenceEquals($clause.Item2, $child)) { return $clause.Item1.Extent.Text }
            }
        }
        return ''
    }

    It 'the plan is computed once from the real GPU environment; no other script-level code reads HasRocm' {
        $assigns = @(Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ffAmfPlan' })
        Assert-Equal 1 $assigns.Count 'assigned exactly once'
        Assert-Equal 'Get-FfmpegAmfPlan -GpuEnvironment $ffGpu -IsCross $ffCross -SourceDir $srcDir' $assigns[0].Right.Extent.Text 'from Get-GpuEnvironment'
        $hasRocm = Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -eq 'HasRocm' }
        Assert-Equal '' (($hasRocm | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', ') 'a second lane decision'
        $vk = @(Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ffVulkanPlan' })
        Assert-Equal 'Get-FfmpegVulkanPlan -AmfPlan $ffAmfPlan -VulkanSdk ([string]$env:VULKAN_SDK)' (($vk | ForEach-Object { $_.Right.Extent.Text }) -join ' | ') 'Vulkan follows the AMF plan: assigned once, no lane decision of its own'
    }

    It 'the configure args come from the plan and are appended once, right after the nvenc args' {
        $src = Join-Path (Get-RepoRoot) $script:ffScript
        $calls = @(Select-String -LiteralPath $src -SimpleMatch -Pattern 'Get-FfmpegRocmConfigureArg -')
        Assert-Equal '$ffRocmFlags = @(Get-FfmpegRocmConfigureArg -AmfPlan $ffAmfPlan -VulkanPlan $ffVulkanPlan)' (($calls | ForEach-Object { $_.Line.Trim() }) -join ' | ') 'one call, fed both plans'
        $appends = @(Select-String -LiteralPath $src -Pattern '^\$confFlags \+= \$(nvencFlags|ffRocmFlags)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        Assert-Equal 'nvencFlags,ffRocmFlags' ($appends -join ',') 'appended once, right after the nvenc args'
    }

    It 'header fetch, config.mak gates and header install each run only under their plan guard (mutation)' {
        $expected = [ordered]@{
            'Install-FfmpegAmfHeader'   = '$ffAmfPlan'
            'Get-FfmpegAmfConfigGap'    = '$ffAmfPlan'
            'Get-FfmpegRocmLeak'        = '$ffAmfPlan'
            'Get-FfmpegVulkanConfigGap' = '$ffVulkanPlan'
            'Copy-FfmpegAmfHeaderTree'  = '$ffAmfPlan -and $env:FFMPEG_SOURCE_BUILD -eq ''1'''
        }
        $calls = Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $expected.Keys }
        $got = ($calls | ForEach-Object { "$($_.GetCommandName()) <- if ($(Get-FfEnclosingGuard $_))" }) -join "`n"
        $want = ($expected.Keys | ForEach-Object { "$_ <- if ($($expected[$_]))" }) -join "`n"
        Assert-Equal $want $got 'each step called once, in order, under exactly its guard'
        $leak = @($calls | Where-Object { $_.GetCommandName() -eq 'Get-FfmpegRocmLeak' })[0].CommandElements
        $at = @(0..($leak.Count - 1) | Where-Object { $leak[$_].Extent.Text -eq '-RocmRoot' })
        Assert-Equal '$ffAmfPlan.RocmRoot' $(if ($at) { $leak[$at[0] + 1].Extent.Text }) 'the leak gate checks the plan''s ROCm root'
        $gap = @($calls | Where-Object { $_.GetCommandName() -eq 'Get-FfmpegVulkanConfigGap' })[0].CommandElements
        $at = @(0..($gap.Count - 1) | Where-Object { $gap[$_].Extent.Text -eq '-Glslc' })
        Assert-Equal '$ffVulkanPlan.Glslc' $(if ($at) { $gap[$at[0] + 1].Extent.Text }) 'the Vulkan gate checks the plan''s glslc'
    }

    It 'each config.mak gate''s whole result is kept and the next statement throws on any of it (mutation)' {
        $gates = [ordered]@{ 'Get-FfmpegAmfConfigGap' = '$amfGap'; 'Get-FfmpegRocmLeak' = '$rocmLeak'; 'Get-FfmpegVulkanConfigGap' = '$vulkanGap' }
        foreach ($name in $gates.Keys) {
            $var = $gates[$name]
            $cmd = @(Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name })
            Assert-Equal 1 $cmd.Count "$name called once"
            # '| Select-Object -First 0', '| Where-Object ...' or a second assignment would empty the gate silently.
            Assert-Equal 1 $cmd[0].Parent.PipelineElements.Count "$name is not piped into a filter"
            $assign = @(Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var })
            Assert-Equal "$var = @($($cmd[0].Parent.Extent.Text))" (($assign | ForEach-Object { $_.Extent.Text }) -join ' | ') "$var is the gate's whole result, assigned once"
            if ($assign.Count -ne 1) { continue }
            $block = $assign[0].Parent.Statements
            $at = $block.IndexOf($assign[0])
            $next = if ($at + 1 -lt $block.Count) { $block[$at + 1] }
            $shape = if ($next -is [System.Management.Automation.Language.IfStatementAst] -and $next.Clauses.Count -eq 1 -and -not $next.ElseClause) {
                $body = $next.Clauses[0].Item2.Statements
                "if ($($next.Clauses[0].Item1.Extent.Text)) { $(($body | ForEach-Object { $_.GetType().Name }) -join ', ') }"
            } elseif ($next) { $next.Extent.Text } else { '<end of block>' }
            Assert-Equal "if ($var.Count -gt 0) { ThrowStatementAst }" $shape "$var non-empty is fatal, straight after the gate"
        }
    }
}

Describe 'Get-FfmpegAmfConfigGap (post-configure gate)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'Get-FfmpegAmfConfigSymbol', 'Get-FfmpegAmfConfigGap')

    function New-ConfigMak([string[]]$Off = @(), [string]$Eol = "`n") {
        (@(Get-FfmpegAmfConfigSymbol) | ForEach-Object { if ($_ -in $Off) { "!CONFIG_$_=yes" } else { "CONFIG_$_=yes" } }) -join $Eol
    }

    It 'passes when every AMF symbol is on, with LF or CRLF' {
        foreach ($eol in "`n", "`r`n") {
            Assert-Equal '' (@(Get-FfmpegAmfConfigGap -ConfigMakText (New-ConfigMak -Eol $eol)) -join ',') 'no gap'
        }
    }

    It 'names exactly the disabled symbol; CONFIG_AMF_CAPTURE_FILTER never stands in for CONFIG_AMF (mutation)' {
        foreach ($off in 'VP9_AMF_DECODER', 'AMF', 'AMF_CAPTURE_FILTER') {
            Assert-Equal "CONFIG_$off" (@(Get-FfmpegAmfConfigGap -ConfigMakText (New-ConfigMak -Off $off)) -join ',') "$off written as !CONFIG_"
        }
        Assert-Equal @(Get-FfmpegAmfConfigSymbol).Count @(Get-FfmpegAmfConfigGap -ConfigMakText '').Count 'empty config.mak: all missing'
    }

    It 'matches the smoke check''s listed names one to one' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:ffCheck -FunctionName 'Get-FfmpegAmfExpectation')
        $exp = Get-FfmpegAmfExpectation
        $fromSmoke = @($exp.encoders | ForEach-Object { "$($_)_ENCODER".ToUpperInvariant() }) +
            @($exp.decoders | ForEach-Object { "$($_)_DECODER".ToUpperInvariant() }) +
            @($exp.filters | ForEach-Object { if ($_ -eq 'vsrc_amf') { 'AMF_CAPTURE_FILTER' } else { "$($_)_FILTER".ToUpperInvariant() } }) +
            @($exp.hwaccels | ForEach-Object { $_.ToUpperInvariant() })
        Assert-Equal ((@(Get-FfmpegAmfConfigSymbol) | Sort-Object) -join ',') (($fromSmoke | Sort-Object) -join ',') 'build gate and smoke agree'
    }
}

Describe 'Get-FfmpegVulkanConfigGap (post-configure gate)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'Get-FfmpegVulkanConfigSymbol', 'Get-FfmpegVulkanConfigGap')
    $script:vkGlslc = 'C:/Users/ContainerAdministrator/scoop/apps/vulkan/current/Bin/glslc.exe'

    function New-VkConfigMak([string[]]$Off = @(), [string]$Eol = "`n", [string]$Glslc = $script:vkGlslc) {
        $lines = @(Get-FfmpegVulkanConfigSymbol) | ForEach-Object { if ($_ -in $Off) { "!$_=yes" } else { "$_=yes" } }
        (@("GLSLC=$Glslc", 'GLSLCFLAGS= --target-env=vulkan1.4 --target-spv=spv1.6 -std=460 -O') + $lines) -join $Eol
    }

    It 'passes when every Vulkan symbol is on and GLSLC is the plan''s glslc, with LF or CRLF' {
        foreach ($eol in "`n", "`r`n") {
            Assert-Equal '' (@(Get-FfmpegVulkanConfigGap -ConfigMakText (New-VkConfigMak -Eol $eol) -Glslc $script:vkGlslc) -join ',') 'no gap'
        }
    }

    It 'the config.mak lines a real n9.0.2 configure wrote (VULKAN_SDK 1.4.357.0, --glslc, -I<SDK>/Include) pass as they are' {
        # Measured 2026-09-23 on the host (mingw gcc, same configure logic); every Vulkan/SPIR-V line it wrote.
        $real = @'
GLSLC=C:/VulkanSDK/1.4.357.0/Bin/glslc.exe
GLSLCFLAGS= --target-env=vulkan1.4 --target-spv=spv1.6 -std=460 -O
HAVE_SPIRV_HEADERS_SPIRV_H=yes
!HAVE_SPIRV_UNIFIED1_SPIRV_H=yes
!CONFIG_VULKAN_STATIC=yes
CONFIG_VULKAN=yes
CONFIG_VULKAN_1_4=yes
CONFIG_VULKAN_ENCODE=yes
CONFIG_FFV1_VULKAN_ENCODER=yes
CONFIG_PRORES_KS_VULKAN_ENCODER=yes
CONFIG_AV1_VULKAN_ENCODER=yes
CONFIG_H264_VULKAN_ENCODER=yes
CONFIG_HEVC_VULKAN_ENCODER=yes
CONFIG_APV_VULKAN_HWACCEL=yes
CONFIG_AV1_VULKAN_HWACCEL=yes
CONFIG_DPX_VULKAN_HWACCEL=yes
CONFIG_FFV1_VULKAN_HWACCEL=yes
CONFIG_H264_VULKAN_HWACCEL=yes
CONFIG_HEVC_VULKAN_HWACCEL=yes
CONFIG_PRORES_VULKAN_HWACCEL=yes
CONFIG_PRORES_RAW_VULKAN_HWACCEL=yes
CONFIG_VP9_VULKAN_HWACCEL=yes
CONFIG_AVGBLUR_VULKAN_FILTER=yes
CONFIG_BLACKDETECT_VULKAN_FILTER=yes
CONFIG_BLEND_VULKAN_FILTER=yes
CONFIG_BWDIF_VULKAN_FILTER=yes
CONFIG_CHROMABER_VULKAN_FILTER=yes
CONFIG_FLIP_VULKAN_FILTER=yes
CONFIG_GBLUR_VULKAN_FILTER=yes
CONFIG_HFLIP_VULKAN_FILTER=yes
CONFIG_INTERLACE_VULKAN_FILTER=yes
CONFIG_NLMEANS_VULKAN_FILTER=yes
CONFIG_OVERLAY_VULKAN_FILTER=yes
CONFIG_SCALE_VULKAN_FILTER=yes
CONFIG_SCDET_VULKAN_FILTER=yes
CONFIG_TRANSPOSE_VULKAN_FILTER=yes
CONFIG_V360_VULKAN_FILTER=yes
CONFIG_VFLIP_VULKAN_FILTER=yes
CONFIG_XFADE_VULKAN_FILTER=yes
CONFIG_COLOR_VULKAN_FILTER=yes
'@
        Assert-Equal '' (@(Get-FfmpegVulkanConfigGap -ConfigMakText $real -Glslc 'C:/VulkanSDK/1.4.357.0/Bin/glslc.exe') -join ',') 'every gated symbol is one configure writes'
    }

    It 'names exactly the disabled symbol; CONFIG_VULKAN_1_4 never stands in for CONFIG_VULKAN (mutation)' {
        foreach ($off in 'CONFIG_VULKAN', 'CONFIG_VULKAN_1_4', 'CONFIG_VP9_VULKAN_HWACCEL', 'CONFIG_FFV1_VULKAN_HWACCEL',
            'CONFIG_AV1_VULKAN_ENCODER', 'CONFIG_COLOR_VULKAN_FILTER', 'HAVE_SPIRV_HEADERS_SPIRV_H') {
            Assert-Equal $off (@(Get-FfmpegVulkanConfigGap -ConfigMakText (New-VkConfigMak -Off $off) -Glslc $script:vkGlslc) -join ',') "$off written as !$off"
        }
        Assert-Equal (@(Get-FfmpegVulkanConfigSymbol).Count + 1) @(Get-FfmpegVulkanConfigGap -ConfigMakText '' -Glslc $script:vkGlslc).Count 'empty config.mak: all missing, GLSLC too'
    }

    It 'a GLSLC that configure found on PATH instead of the plan''s is a gap (mutation)' {
        foreach ($other in 'glslc', 'glslangValidator', 'C:/VulkanSDK/1.4.357.0/Bin/glslc.exe') {
            Assert-Equal "GLSLC=$($script:vkGlslc)" (@(Get-FfmpegVulkanConfigGap -ConfigMakText (New-VkConfigMak -Glslc $other) -Glslc $script:vkGlslc) -join ',') "GLSLC=$other"
        }
    }

    It 'matches the smoke check''s listed names one to one (VULKAN_1_4 and the SPIR-V header are build-only)' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:ffCheck -FunctionName 'Get-FfmpegVulkanExpectation')
        $exp = Get-FfmpegVulkanExpectation
        $fromSmoke = @($exp.encoders | ForEach-Object { "CONFIG_$($_)_ENCODER".ToUpperInvariant() }) +
            @($exp.filters | ForEach-Object { "CONFIG_$($_)_FILTER".ToUpperInvariant() }) +
            @($exp.hwdecoders | ForEach-Object { "CONFIG_$($_)_VULKAN_HWACCEL".ToUpperInvariant() }) +
            @($exp.hwaccels | ForEach-Object { "CONFIG_$_".ToUpperInvariant() }) + @('CONFIG_VULKAN_1_4', 'HAVE_SPIRV_HEADERS_SPIRV_H')
        Assert-Equal ((@(Get-FfmpegVulkanConfigSymbol) | Sort-Object) -join ',') (($fromSmoke | Sort-Object) -join ',') 'build gate and smoke agree'
    }
}

Describe 'Get-FfmpegRocmLeak (TheRock never reaches the non-CMake configure)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'Get-FfmpegRocmLeak')
    $script:cleanMak = "SRC_PATH=/c/temp/ffmpeg-src/FFmpeg-n9.0.2`nCC=clang-cl`nEXTRALIBS-avutil=user32.lib bcrypt.lib"

    It 'names every line that spells the ROCm root, in any slash, drive or case form (mutation)' {
        foreach ($spelling in 'C:\TheRock\build\lib\zlib.lib', 'c:/therock/build/include', '/c/TheRock/build/lib') {
            $got = @(Get-FfmpegRocmLeak -ConfigMakText "$($script:cleanMak)`nEXTRALIBS=$spelling" -RocmRoot 'C:\TheRock\build\')
            Assert-Equal "EXTRALIBS=$spelling" ($got -join '|') "$spelling is a leak"
        }
    }

    It 'passes the real config.mak shape and a sibling directory that only shares a prefix' {
        Assert-Equal '' (@(Get-FfmpegRocmLeak -ConfigMakText $script:cleanMak -RocmRoot 'C:\TheRock\build') -join '|') 'clean'
        Assert-Equal '' (@(Get-FfmpegRocmLeak -ConfigMakText 'X=C:/TheRock/buildkit/lib' -RocmRoot 'C:\TheRock\build') -join '|') 'buildkit is not build'
        Assert-Equal 'X=C:/TheRock/build' (@(Get-FfmpegRocmLeak -ConfigMakText 'X=C:/TheRock/build' -RocmRoot 'C:\TheRock\build') -join '|') 'the root itself at end of line'
    }
}

Describe 'Install-FfmpegAmfHeader / Copy-FfmpegAmfHeaderTree (SHA-pinned header asset)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'Copy-FfmpegAmfHeaderTree', 'Install-FfmpegAmfHeader')

    # Serves the release asset's shape (amf-headers-<tag>/AMF/core/Version.h) from $Root and
    # installs it into $Root\src\compat\amf; -Sha replaces the real digest.
    function Invoke-AmfInstall([string]$Root, [string]$Sha = '', [switch]$NoVersionH) {
        $tag = 'v9.9.9'
        $core = Join-Path $Root "stage\amf-headers-$tag\AMF\core"
        Write-FfRocmTestFile (Join-Path $core 'Factory.h') '// factory'
        if (-not $NoVersionH) { Write-FfRocmTestFile (Join-Path $core 'Version.h') '#define AMF_VERSION_MAJOR 1' }
        $served = Join-Path $Root "server\$tag"
        $null = [System.IO.Directory]::CreateDirectory($served)
        $asset = Join-Path $served "AMF-headers-$tag.tar.gz"
        # Windows' bsdtar by path: Git's GNU tar (first on PATH under Git Bash) reads C:\ as a remote host.
        & (Join-Path $env:SystemRoot 'System32\tar.exe') -czf $asset -C (Join-Path $Root 'stage') "amf-headers-$tag"
        if ($LASTEXITCODE -ne 0) { throw "fixture: tar exited $LASTEXITCODE" }
        $pin = if ($Sha) { $Sha } else { (Get-FileHash $asset -Algorithm SHA256).Hash }
        Install-FfmpegAmfHeader -Version $tag -Sha256 $pin -Destination (Join-Path $Root 'src\compat\amf') `
            -WorkDir (Join-Path $Root 'work') -BaseUrl ('file:///' + ((Join-Path $Root 'server') -replace '\\', '/')) -MaxAttempts 1
    }

    It 'refuses an empty SHA before any download' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Install-FfmpegAmfHeader -Version 'v1.5.2' -Sha256 '' -Destination $dir -WorkDir (Join-Path $dir 'w') -BaseUrl 'file:///C:/nowhere' } `
                -MessagePattern 'refusing an unverified' 'empty pin is fatal'
            Assert-False (Test-Path (Join-Path $dir 'w')) 'nothing was fetched'
        }
    }

    It 'downloads, verifies, extracts into <Destination>\AMF and removes its work dir' {
        Invoke-InTestDir { param($dir)
            $got = Invoke-AmfInstall -Root $dir
            Assert-Equal (Join-Path $dir 'src\compat\amf\AMF') $got 'returns the AMF dir'
            $tree = @(Get-ChildItem -LiteralPath $got -Recurse -File -Name | Sort-Object)
            Assert-Equal 'core\Factory.h,core\Version.h' ($tree -join ',') 'the asset''s headers in the <AMF/core/...> layout'
            Assert-Equal $false ([System.IO.Directory]::Exists((Join-Path $dir 'work'))) 'work dir removed'
        }
    }

    It 'a SHA mismatch or a missing Version.h is fatal and installs nothing (mutation)' {
        foreach ($case in @(@{ Sha = ('0' * 64); Why = 'SHA256 mismatch' }, @{ Sha = ''; Why = 'no AMF\\core\\Version\.h' })) {
            Invoke-InTestDir { param($dir)
                Assert-Throws { Invoke-AmfInstall -Root $dir -Sha $case.Sha -NoVersionH:($case.Sha -eq '') } -MessagePattern $case.Why $case.Why
                Assert-False (Test-Path (Join-Path $dir 'src\compat\amf\AMF\core')) "$($case.Why): no headers installed"
            }
        }
    }

    It 'Copy-FfmpegAmfHeaderTree replaces a stale AMF dir instead of nesting AMF\AMF' {
        Invoke-InTestDir { param($dir)
            Write-FfRocmTestFile (Join-Path $dir 'inc\AMF\core\Version.h') 'new'
            Write-FfRocmTestFile (Join-Path $dir 'include\AMF\stale.h') 'old'
            $got = Copy-FfmpegAmfHeaderTree -IncludeRoot (Join-Path $dir 'inc') -Destination (Join-Path $dir 'include')
            Assert-Equal 'core\Version.h' (@(Get-ChildItem -LiteralPath $got -Recurse -File -Name) -join ',') 'exactly the new tree: stale header gone, no AMF\AMF'
        }
    }
}

Describe 'rocm-checks/FFmpeg.ps1 (smoke findings)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffCheck -FunctionName 'Test-FfmpegListingRow', 'Get-FfmpegAmfExpectation',
        'Get-FfmpegAmfListingFinding', 'Get-FfmpegAmfInstallFinding', 'Get-FfmpegVulkanExpectation', 'Get-FfmpegVulkanListingFinding',
        'Get-FfmpegVulkanImportFinding')

    # Rows shaped like ffmpeg n9.0.2's listings (opt_common.c print_codecs / show_filters).
    function New-Listing([string[]]$Drop = @(), [switch]$NoAmfHwaccel, [switch]$NoEnableAmf) {
        $exp = Get-FfmpegAmfExpectation
        $rows = { param($names, $flags) (@($names | Where-Object { $_ -notin $Drop }) | ForEach-Object { " $flags $($_.PadRight(20)) AMD AMF thing" }) -join "`n" }
        return @{
            encoders = "Encoders:`n V....D mpeg4                MPEG-4 part 2`n" + (& $rows $exp.encoders 'V....D')
            decoders = "Decoders:`n" + (& $rows $exp.decoders 'V....D')
            filters  = "Filters:`n  T.. = Timeline support`n" + (& $rows $exp.filters 'TC')
            hwaccels = "Hardware acceleration methods:`ndxva2`nd3d11va`n" + $(if ($NoAmfHwaccel) { '' } else { "amf`n" })
            version  = 'configuration: --enable-shared ' + $(if ($NoEnableAmf) { '' } else { '--enable-amf ' }) + '--enable-gpl'
        }
    }

    It 'has no findings when every AMF entry is listed' {
        Assert-Equal 0 @(Get-FfmpegAmfListingFinding -Listing (New-Listing)).Count 'clean listing'
    }

    It 'names each missing entry per listing kind (mutation)' {
        $f = @(Get-FfmpegAmfListingFinding -Listing (New-Listing -Drop 'vsrc_amf'))
        Assert-Equal 1 $f.Count 'one finding'
        Assert-Match '-filters does not list vsrc_amf' $f[0] 'names the filter'
        $f = @(Get-FfmpegAmfListingFinding -Listing (New-Listing -Drop 'hevc_amf'))
        Assert-Equal 2 $f.Count 'hevc_amf is an encoder AND a decoder'
        Assert-Equal 1 @(Get-FfmpegAmfListingFinding -Listing (New-Listing -NoAmfHwaccel)).Count 'hwdevice amf'
        Assert-Match 'lacks --enable-amf' (@(Get-FfmpegAmfListingFinding -Listing (New-Listing -NoEnableAmf))[0]) 'configuration line'
    }

    It 'does not count a name that only appears in a description column' {
        $l = New-Listing -Drop 'h264_amf'
        $l.encoders += "`n V....D h264_mf              wraps h264_amf in prose"
        Assert-True ((@(Get-FfmpegAmfListingFinding -Listing $l) -join ';') -match 'encoders does not list h264_amf') 'prose is not a row'
    }

    # Vulkan rows plus `-h decoder=` pages shaped like n9.0.2's print_codec (opt_common.c).
    function New-VkListing([string[]]$Drop = @(), [string[]]$NoDevice = @(), [switch]$NoVulkanHwaccel, [switch]$NoEnableVulkan) {
        $exp = Get-FfmpegVulkanExpectation
        $rows = { param($names, $flags) (@($names | Where-Object { $_ -notin $Drop }) | ForEach-Object { " $flags $($_.PadRight(20)) Vulkan thing" }) -join "`r`n" }
        $l = @{
            encoders = "Encoders:`r`n V....D mpeg4                MPEG-4 part 2`r`n" + (& $rows $exp.encoders 'V....D')
            filters  = "Filters:`r`n  T.. = Timeline support`r`n" + (& $rows $exp.filters 'TC')
            hwaccels = "Hardware acceleration methods:`r`ndxva2`r`nd3d11va`r`n" + $(if ($NoVulkanHwaccel) { '' } else { "vulkan`r`n" })
            version  = 'configuration: --enable-shared ' + $(if ($NoEnableVulkan) { '' } else { '--enable-vulkan ' }) + '--enable-gpl'
        }
        foreach ($d in $exp.hwdecoders) {
            $devices = 'dxva2 d3d11va d3d11va d3d12va amf' + $(if ($d -in $NoDevice) { '' } else { ' vulkan' })
            $l["decoder=$d"] = "Decoder $d [$d]:`r`n    General capabilities: dr1 delay threads `r`n    Supported hardware devices: $devices `r`n"
        }
        return $l
    }

    It 'Vulkan: no findings when every encoder, filter, the hwdevice and every decoder''s vulkan hwaccel are listed' {
        Assert-Equal '' (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing)) -join ';') 'clean listing'
    }

    It 'Vulkan: names each missing entry, per listing kind and per decoder (mutation)' {
        Assert-Equal 'FFmpeg: ffmpeg -encoders does not list av1_vulkan' (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing -Drop 'av1_vulkan')) -join ';') 'encoder'
        Assert-Equal 'FFmpeg: ffmpeg -filters does not list color_vulkan' (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing -Drop 'color_vulkan')) -join ';') 'the vsrc'
        Assert-Equal 'FFmpeg: ffmpeg -hwaccels does not list vulkan' (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing -NoVulkanHwaccel)) -join ';') 'hwdevice'
        foreach ($d in 'vp9', 'prores_raw') {
            Assert-Equal "FFmpeg: ffmpeg -h decoder=$d does not list the vulkan device (no ${d}_vulkan hwaccel)" `
                (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing -NoDevice $d)) -join ';') "$d hwaccel"
        }
        Assert-Match 'lacks --enable-vulkan' (@(Get-FfmpegVulkanListingFinding -Listing (New-VkListing -NoEnableVulkan)) -join ';') 'configuration line'
    }

    It 'Vulkan: a decoder page that names vulkan outside its device line, or no page at all, is a finding' {
        $l = New-VkListing -NoDevice 'h264'
        $l['decoder=h264'] += "    Supported pixel formats: vulkan yuv420p`r`n"
        $l.Remove('decoder=hevc')
        $f = @(Get-FfmpegVulkanListingFinding -Listing $l)
        Assert-Equal 'h264,hevc' (($f | ForEach-Object { [regex]::Match($_, 'decoder=(\w+)').Groups[1].Value }) -join ',') 'both named'
    }

    It 'Vulkan: an AMF-only listing (no Vulkan keys) is not silently clean' {
        $amfOnly = @{ encoders = ''; decoders = ''; filters = ''; hwaccels = ''; version = '' }
        $count = @(Get-FfmpegVulkanListingFinding -Listing $amfOnly).Count
        $exp = Get-FfmpegVulkanExpectation
        Assert-Equal ($exp.encoders.Count + $exp.filters.Count + 1 + $exp.hwdecoders.Count + 1) $count 'every expectation reports'
    }

    It 'Vulkan: a static or delay import of vulkan-1.dll is a finding, in any case (mutation)' {
        $clean = [ordered]@{ 'avutil-60.dll' = @('KERNEL32.dll', 'bcrypt.dll'); 'ffmpeg.exe' = @('avutil-60.dll', 'avcodec-62.dll') }
        Assert-Equal '' (@(Get-FfmpegVulkanImportFinding -ImportsByFile $clean) -join ';') 'no Vulkan loader import'
        $bad = [ordered]@{ 'avutil-60.dll' = @('KERNEL32.dll', 'VULKAN-1.dll'); 'ffmpeg.exe' = @('avutil-60.dll'); 'avfilter-11.dll' = @('vulkan-1.dll') }
        $f = @(Get-FfmpegVulkanImportFinding -ImportsByFile $bad)
        Assert-Equal 'avutil-60.dll,avfilter-11.dll' (($f | ForEach-Object { ($_ -split ' ')[1] }) -join ',') 'each importer named once'
        Assert-Equal '' (@(Get-FfmpegVulkanImportFinding -ImportsByFile @{ 'avutil-61.dll' = @('vulkan-1.dll.bak', 'myvulkan-1.dll') }) -join ';') 'only the loader itself'
    }

    It 'Vulkan: an import map without avutil-<major>.dll is a finding, not a vacuous pass (mutation)' {
        $want = 'FFmpeg: no avutil-<major>.dll was read for PE imports, so the vulkan-1.dll import check saw nothing'
        foreach ($map in @([ordered]@{}, [ordered]@{ 'ffmpeg.exe' = @('KERNEL32.dll') }, [ordered]@{ 'avutil.dll' = @(); 'avutil-61.lib' = @() })) {
            Assert-Equal $want (@(Get-FfmpegVulkanImportFinding -ImportsByFile $map) -join ';') "files: $(@($map.Keys) -join ',')"
        }
    }

    It 'install findings: headers required, AMD runtime DLL forbidden' {
        Invoke-InTestDir { param($prefix)
            Assert-Match 'Version\.h is missing' (@(Get-FfmpegAmfInstallFinding -Prefix $prefix) -join ';') 'no headers'
            Write-FfRocmTestFile (Join-Path $prefix 'include\AMF\core\Version.h')
            Assert-Equal '' (@(Get-FfmpegAmfInstallFinding -Prefix $prefix) -join ';') 'headers present'
            Write-FfRocmTestFile (Join-Path $prefix 'bin\amfrt64.dll')
            Assert-Match 'proprietary AMF runtime' (@(Get-FfmpegAmfInstallFinding -Prefix $prefix) -join ';') 'shipped runtime is a finding'
        }
    }

    It 'the script itself: no GPU, no params, one finding (not a throw) when ffmpeg.exe is absent' {
        $check = Join-Path (Get-RepoRoot) $script:ffCheck
        Invoke-InTestDir { param($emptyBin)
            $findings = Invoke-WithEnv @{ FFMPEG_BIN = $emptyBin } { @(& $check) }
            Assert-Equal "FFmpeg: $(Join-Path $emptyBin 'ffmpeg.exe') not found" ($findings -join ';') 'exactly one finding, naming the binary'
        }
    }
}

Describe 'rocm-checks/FFmpeg.ps1: the script body feeds every finder real input (structural)' {
    # A dropped call or input loop leaves the unit tests green and the smoke vacuous; no GPU-less run reaches this code.
    $script:ckAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-RepoRoot) $script:ffCheck), [ref]$null, [ref]$null)

    function Find-CkScriptLevelNode([scriptblock]$Predicate) {
        @($script:ckAst.FindAll({ param($n)
            if (-not (& $Predicate $n)) { return $false }
            for ($p = $n.Parent; $p; $p = $p.Parent) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false } }
            return $true }, $true))
    }

    It 'each finder is called once, in order, as a bare top-level statement whose findings reach the pipeline (mutation)' {
        $finders = 'Get-FfmpegAmfListingFinding', 'Get-FfmpegVulkanListingFinding', 'Get-FfmpegAmfInstallFinding', 'Get-FfmpegVulkanImportFinding'
        $calls = Find-CkScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $finders }
        # Parent pipeline directly in the script's end block: not assigned, piped to Out-Null, [void]-cast or under an if.
        $got = ($calls | ForEach-Object {
            $top = $_.Parent.PipelineElements.Count -eq 1 -and [object]::ReferenceEquals($_.Parent.Parent, $script:ckAst.EndBlock)
            "$($_.Extent.Text)$(if (-not $top) { ' (not a bare top-level statement)' })" }) -join "`n"
        $want = @('Get-FfmpegAmfListingFinding -Listing $listing', 'Get-FfmpegVulkanListingFinding -Listing $listing',
            'Get-FfmpegAmfInstallFinding -Prefix (Split-Path $ffBin -Parent)', 'Get-FfmpegVulkanImportFinding -ImportsByFile $imports') -join "`n"
        Assert-Equal $want $got 'every finder runs on the collected input'
    }

    It 'the -h decoder= pages and the delay-load-aware PE imports are collected for every expected name (mutation)' {
        $loops = [ordered]@{
            decoder = @('(Get-FfmpegVulkanExpectation).hwdecoders', '$listing["decoder=$decoder"] = (& $ffExe -hide_banner -h "decoder=$decoder" 2>$null | Out-String)')
            pe      = @('@(Get-ChildItem -LiteralPath $ffBin -File | Where-Object { $_.Extension -in ''.dll'', ''.exe'' })',
                '$imports[$pe.Name] = @(Get-PeImportNames -Path $pe.FullName -IncludeDelayLoad)')
        }
        foreach ($v in $loops.Keys) {
            $loop = @(Find-CkScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq $v })
            Assert-Equal 1 $loop.Count "one foreach over `$$v"
            if ($loop.Count -ne 1) { continue }
            Assert-Equal $loops[$v][0] $loop[0].Condition.Extent.Text "`$$v iterates the full expected set"
            $fill = @($loop[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Extent.Text })
            Assert-True ($loops[$v][1] -in $fill) "`$$v body fills its map: got '$($fill -join ' | ')'"
        }
    }
}
