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

Describe 'Get-FfmpegAmfPlan / Get-FfmpegRocmConfigureArg (rocm lane only)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffScript -FunctionName 'ConvertTo-MsysPath', 'Get-FfmpegAmfPlan', 'Get-FfmpegRocmConfigureArg')

    # A slice of the real amd64 cpu-lane line; the property is that NOTHING is appended to it.
    $script:baseFlags = @('--prefix=/c/runtime/ffmpeg', '--enable-shared', '--disable-static',
        '--enable-gpl', '--enable-version3', '--toolchain=msvc', '--cc=clang-cl', '--ld=lld-link',
        '--disable-indev=vfwcap')
    $script:baseLine = [string]::Join(' ', [string[]]$script:baseFlags)

    # One fixture for every lane: a CUDA root, a HIP tree AND fetched AMF headers all exist, so only GPU_TYPE decides.
    function Invoke-OnGpuLane([string]$Lane, [scriptblock]$Body) {
        Invoke-InTestDir { param($root)
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'lib\cmake\hip') | Out-Null
            $src = Join-Path $root 'src'
            Write-FfRocmTestFile (Join-Path $src 'compat\amf\AMF\core\Version.h')
            $laneEnv = @{ GPU_TYPE = $Lane; CUDA_ROOT = $root; HIP_PATH = $root; ROCM_PATH = $null; TENSORRT_ROOT = ''
                CUDA_PATH = $env:CUDA_PATH; CUDA_HOME = $env:CUDA_HOME; PATH = $env:PATH }
            Invoke-WithEnv $laneEnv { & $Body (Get-GpuEnvironment) $src }
        }
    }

    It 'cpu and nvidia lanes (real Get-GpuEnvironment): no plan, and the configure line is byte-identical' {
        foreach ($lane in @($null, 'cpu', 'nvidia')) {
            Invoke-OnGpuLane $lane { param($gpu, $src)
                Assert-Equal ($lane -eq 'nvidia') $gpu.HasCuda "GPU_TYPE='$lane': fixture is the lane it claims"
                $plan = Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $false -SourceDir $src
                Assert-Null $plan "GPU_TYPE='$lane': no plan -> no fetch, no config.mak gates, no include\AMF"
                Assert-Null (Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $true -SourceDir $src) "GPU_TYPE='$lane': cross, no plan and no throw"
                $withRocm = [string[]]($script:baseFlags + @(Get-FfmpegRocmConfigureArg -AmfPlan $plan))
                Assert-Equal $script:baseLine ([string]::Join(' ', $withRocm)) "GPU_TYPE='$lane': nothing appended, even with a HIP tree"
            }
        }
    }

    It 'rocm lane (real Get-GpuEnvironment): one plan; --enable-amf plus its include dir, nothing else' {
        Invoke-OnGpuLane 'rocm' { param($gpu, $src)
            Assert-True $gpu.HasRocm 'fixture is the rocm lane'
            $plan = Get-FfmpegAmfPlan -GpuEnvironment $gpu -IsCross $false -SourceDir $src
            Assert-Equal (Join-Path $src 'compat\amf') $plan.CompatDir 'headers go to the source tree''s compat\amf'
            Assert-Equal (ConvertTo-MsysPath $plan.CompatDir) $plan.IncludeDir 'configure gets the MSYS form of the same dir'
            Assert-Match '^/[a-z]/.+/compat/amf$' $plan.IncludeDir 'MSYS path'
            Assert-True ($plan.RocmRoot -and $plan.RocmRoot -eq $gpu.RocmRoot) 'the leak gate checks the lane''s real ROCm root'
            $rocm = @(Get-FfmpegRocmConfigureArg -AmfPlan $plan)
            Assert-Equal "--enable-amf|--extra-cflags=-I$($plan.IncludeDir)" ($rocm -join '|') 'exact rocm args, in order'
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
    }

    It 'the configure args come from the plan and are appended once, right after the nvenc args' {
        $src = Join-Path (Get-RepoRoot) $script:ffScript
        $calls = @(Select-String -LiteralPath $src -SimpleMatch -Pattern 'Get-FfmpegRocmConfigureArg -')
        Assert-Equal '$ffRocmFlags = @(Get-FfmpegRocmConfigureArg -AmfPlan $ffAmfPlan)' (($calls | ForEach-Object { $_.Line.Trim() }) -join ' | ') 'one call, fed the plan'
        $appends = @(Select-String -LiteralPath $src -Pattern '^\$confFlags \+= \$(nvencFlags|ffRocmFlags)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        Assert-Equal 'nvencFlags,ffRocmFlags' ($appends -join ',') 'appended once, right after the nvenc args'
    }

    It 'header fetch, config.mak gates and header install each run only under their plan guard (mutation)' {
        $expected = [ordered]@{
            'Install-FfmpegAmfHeader'  = '$ffAmfPlan'
            'Get-FfmpegAmfConfigGap'   = '$ffAmfPlan'
            'Get-FfmpegRocmLeak'       = '$ffAmfPlan'
            'Copy-FfmpegAmfHeaderTree' = '$ffAmfPlan -and $env:FFMPEG_SOURCE_BUILD -eq ''1'''
        }
        $calls = Find-FfScriptLevelNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $expected.Keys }
        $got = ($calls | ForEach-Object { "$($_.GetCommandName()) <- if ($(Get-FfEnclosingGuard $_))" }) -join "`n"
        $want = ($expected.Keys | ForEach-Object { "$_ <- if ($($expected[$_]))" }) -join "`n"
        Assert-Equal $want $got 'each step called once, in order, under exactly its guard'
        $leak = @($calls | Where-Object { $_.GetCommandName() -eq 'Get-FfmpegRocmLeak' })[0].CommandElements
        $at = @(0..($leak.Count - 1) | Where-Object { $leak[$_].Extent.Text -eq '-RocmRoot' })
        Assert-Equal '$ffAmfPlan.RocmRoot' $(if ($at) { $leak[$at[0] + 1].Extent.Text }) 'the leak gate checks the plan''s ROCm root'
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
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ffCheck -FunctionName 'Get-FfmpegAmfExpectation', 'Get-FfmpegAmfListingFinding', 'Get-FfmpegAmfInstallFinding')

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
