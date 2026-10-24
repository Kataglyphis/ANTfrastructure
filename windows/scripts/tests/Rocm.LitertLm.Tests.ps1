#requires -Version 7.0
# The rocm lane's LiteRT-LM GPU backend leaves cpu/nvidia's bazel command untouched; no bazel build, real DLLs or GPU.

Import-Module (Join-Path $PSScriptRoot 'WindowsMedia.WiringFixture.psm1') -DisableNameChecking

$script:LlmBazel = 'windows\scripts\build\Build-LitertLmBazel.ps1'
$script:LlmCheck = 'windows\scripts\build\rocm-checks\LiteRtLm.ps1'
$script:PreRocmCmd = 'build //runtime/engine:litert_lm_main --config=windows --repo_env=ANDROID_NDK_VERSION='

Describe 'Build-LitertLmBazel: the bazel command per lane' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmBazel -FunctionName 'Get-LitertLmBazelArg')

    It 'cpu and nvidia keep the pre-rocm command, byte for byte' {
        foreach ($t in @($null, '', 'cpu', 'nvidia')) {
            Assert-Equal $script:PreRocmCmd ((Get-LitertLmBazelArg -GpuType $t) -join ' ') "GPU_TYPE='$t'"
        }
    }

    It 'rocm adds only the DXC dlls target, whatever the casing' {
        foreach ($t in 'rocm', 'ROCm') {
            Assert-Equal 'build //runtime/engine:litert_lm_main @directx_shader_compiler//:dxc_dlls --config=windows --repo_env=ANDROID_NDK_VERSION=' `
                ((Get-LitertLmBazelArg -GpuType $t) -join ' ') "GPU_TYPE='$t'"
        }
    }

    It 'the script launches bazel once, through that function, with the unchanged startup option' {
        $calls = @(Get-TestScriptCommands -ScriptPath $script:LlmBazel -Name 'Invoke-BazelLogged')
        Assert-Equal 1 $calls.Count 'one bazelisk invocation'
        Assert-Equal 'Invoke-BazelLogged -Bazel C:\bzl-tools\bazel.exe -Argument (@($bazelArgs) + @($bazelCmd) + @($toolchainOpts)) -LogPath C:\bazel-build.log' `
            $calls[0].Extent.Text 'through Invoke-BazelLogged, with its arguments'
        $text = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) $script:LlmBazel) -Raw
        Assert-Match ([regex]::Escape("`$outputBase = 'C:\bzl'")) $text 'output base'
        Assert-Match ([regex]::Escape('$bazelArgs = @(''--output_user_root=C:\bzl-user'', "--output_base=$outputBase")')) $text 'startup options'
        Assert-Match ([regex]::Escape('$bazelCmd = Get-LitertLmBazelArg -GpuType $gpuType')) $text 'command from the function'
    }

    It 'gates exactly where Get-GpuEnvironment says HasRocm' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib\cmake\hip') | Out-Null
            foreach ($t in '', 'cpu', 'rocm', 'ROCm') {
                Invoke-WithEnv @{ GPU_TYPE = $t; HIP_PATH = $dir; ROCM_PATH = $null; TENSORRT_ROOT = '' } {
                    $hasRocm = [bool](Get-GpuEnvironment).HasRocm
                    Assert-Equal $hasRocm ((Get-LitertLmBazelArg -GpuType $env:GPU_TYPE).Count -eq 5) "GPU_TYPE='$t'"
                }
            }
        }
    }
}

Describe 'Build-LitertLmBazel: the script body wires the rocm gate' {
    # The functions are inert unless the body calls them, gated and ordered as below.
    $script:LlmAst = (Get-TestScriptAst -ScriptPath $script:LlmBazel)

    function Get-LlmBodyNode {
        param([scriptblock]$Where)
        @(Get-MediaTestAstNode -Ast $script:LlmAst -Predicate $Where -ScriptLevel)
    }
    function Get-LlmCall {
        param([string]$Name)
        Get-LlmBodyNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }
    }
    function Get-LlmAncestor {
        param($Node, [type]$Type)
        Get-TestAstAncestor -Node $Node -Type $Type -First
    }
    function Test-LlmWithin { param($Inner, $Outer) $Outer.Extent.StartOffset -le $Inner.Extent.StartOffset -and $Inner.Extent.EndOffset -le $Outer.Extent.EndOffset }
    function Get-LlmIfChain {
        # Conditions of every if-clause holding $Node below $Stop, innermost first, joined by ' && '.
        param($Node, $Stop)
        $conds = @(foreach ($p in @(Get-TestAstAncestor -Node $Node -Stop $Stop -Type ([System.Management.Automation.Language.IfStatementAst]))) {
                foreach ($c in $p.Clauses) { if (Test-LlmWithin $Node $c.Item2) { $c.Item1.Extent.Text } }
            })
        $conds -join ' && '
    }
    function Get-LlmWiredCall {
        param([Management.Automation.Language.CommandAst[]]$Command, [string]$Text,
            [string]$Assignment = '', [string]$Condition = '', [ValidateSet('', 'Before', 'After')][string]$BazelPosition = '')
        Assert-TestAstCommand -Command $Command -Text $Text -Assignment $Assignment
        if ($Condition) { Assert-Equal $Condition (Get-LlmIfChain $Command[0] $script:LlmTry.Body) 'lane condition' }
        if ($BazelPosition) {
            $nodes = if ($BazelPosition -eq 'Before') { @($Command[0], $script:LlmBazelCall[0]) } else { @($script:LlmBazelCall[0], $Command[0]) }
            Assert-True ($nodes[0].Extent.EndOffset -lt $nodes[1].Extent.StartOffset) "$BazelPosition bazel"
        }
        return $Command[0]
    }
    $script:LlmBazelCall = @(Get-LlmCall 'Invoke-BazelLogged')
    $script:LlmTry = Get-LlmAncestor $script:LlmBazelCall[0] ([System.Management.Automation.Language.TryStatementAst])

    It 'reads GPU_TYPE once, from the lane env' {
        $assignment = Get-MediaTestAssignment -Ast $script:LlmAst -Variable '$gpuType' -ScriptLevel -Single
        Assert-Equal '[string]$env:GPU_TYPE' $assignment.Right.Extent.Text 'its source'
        Assert-Equal 1 $script:LlmBazelCall.Count 'one bazelisk call'
        Assert-NotNull $script:LlmTry 'bazelisk runs inside a try'
    }

    It 'hides the ROCm tree before the bazel server starts, and restores it in finally' {
        $scrub = @(Get-LlmCall 'Get-BazelRocmEnvScrub')
        Assert-TestAstCommand -Command $scrub -Text 'Get-BazelRocmEnvScrub -GpuType $gpuType -Environment ([Environment]::GetEnvironmentVariables())' -Assignment '$envScrub'
        $set = @(Get-LlmCall 'Set-BazelProcessEnv')
        $apply = @($set | Where-Object { $_.Extent.Text -ceq 'Set-BazelProcessEnv -Values $envScrub' })
        Assert-TestAstCommand -Command $apply -Text 'Set-BazelProcessEnv -Values $envScrub' -Assignment '$restoreEnv'
        Assert-Equal '$envScrub.Count -gt 0' (Get-LlmIfChain $apply[0] $script:LlmTry.Body) 'applied whenever there is something to hide'
        Assert-True ($scrub[0].Extent.EndOffset -lt $apply[0].Extent.StartOffset) 'computed, then applied'
        Assert-True ($apply[0].Extent.EndOffset -lt $script:LlmBazelCall[0].Extent.StartOffset) 'before the first bazelisk call'
        Assert-True (Test-LlmWithin $apply[0] $script:LlmTry.Body) 'inside the try that restores it'
        $restore = @($set | Where-Object { $_.Extent.Text -ceq 'Set-BazelProcessEnv -Values $restoreEnv' })
        Assert-TestAstCommand -Command $restore -Text 'Set-BazelProcessEnv -Values $restoreEnv'
        Assert-True (Test-LlmWithin $restore[0] $script:LlmTry.Finally) 'in the finally block'
        Assert-Equal '$restoreEnv' (Get-LlmIfChain $restore[0] $script:LlmTry.Finally) 'only when something was hidden'
        $init = @(Get-LlmBodyNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -ceq '$restoreEnv = $null' })
        Assert-True ($init.Count -eq 1 -and $init[0].Extent.EndOffset -lt $script:LlmTry.Extent.StartOffset) 'defined before the try (StrictMode in finally)'
    }

    It 'checks the DXC pin on the rocm lane only, before bazel fetches the zip' {
        $null = Get-LlmWiredCall -Command @(Get-LlmCall 'Assert-LitertLmDxcPin') -Text 'Assert-LitertLmDxcPin -Workspace $ws -Expected $env:LITERT_LM_DXC_ZIP_SHA256' -Condition "`$gpuType -eq 'rocm'" -BazelPosition Before
    }

    It 'installs the lane''s GPU payload after the build' {
        $null = Get-LlmWiredCall -Command @(Get-LlmCall 'Get-LitertLmGpuPayload') -Text "Get-LitertLmGpuPayload -GpuType `$gpuType -PrebuiltDir 'C:\llm\prebuilt\windows_x86_64' -DxcDir (Join-Path `$outputBase 'external\directx_shader_compiler')" -Assignment '$gpuPayload' -BazelPosition After
        $null = Get-LlmWiredCall -Command @(Get-LlmCall 'Install-LitertLmGpuPayload') -Text "Install-LitertLmGpuPayload -Payload `$gpuPayload -Root (Join-Path `$InstallDir 'lib\litert-lm')" -Condition '$gpuPayload.Count -gt 0'

    }
}

Describe 'Build-LitertLmBazel: the ROCm tree is hidden from bazel on the rocm lane' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsBazel.Common.psm1' -FunctionName 'Get-BazelRocmEnvScrub', 'Set-BazelProcessEnv')

    function New-RocmLaneEnv {
        # Case-sensitive keys, like [Environment]::GetEnvironmentVariables().
        $e = [System.Collections.Generic.Dictionary[string, string]]::new()
        $e['GPU_TYPE'] = 'rocm'; $e['ROCM_PATH'] = 'C:\TheRock\build'; $e['HIP_PATH'] = 'C:\TheRock\build'
        $e['HIP_PLATFORM'] = 'amd'; $e['HIP_DEVICE_LIB_PATH'] = 'C:\TheRock\build\lib\llvm\amdgcn\bitcode'
        $e['LLVM_PATH'] = 'C:\TheRock\build\lib\llvm'; $e['ROCM_WINDOWS_RELEASE'] = '10.0.0'
        $e['Path'] = 'C:\runtime\bin;C:\TheRock\build\bin;C:\Windows\System32;c:/therock/build/lib/llvm/bin/'
        $e['PKG_CONFIG_PATH'] = 'C:\TheRock\build\lib\pkgconfig'
        $e['INCLUDE'] = 'C:\vs\include;C:\TheRock\build\include'
        $e['OTHER_TREE'] = 'C:\TheRock\buildx\bin'
        return $e
    }

    It 'is empty on the cpu and nvidia lanes, even beside a ROCm-looking env' {
        foreach ($t in @($null, '', 'cpu', 'nvidia')) {
            Assert-Equal 0 (Get-BazelRocmEnvScrub -GpuType $t -Environment (New-RocmLaneEnv)).Count "GPU_TYPE='$t'"
        }
    }

    It 'unsets the ROCm-layer vars and drops ROCm entries from list vars, nothing else' {
        $s = Get-BazelRocmEnvScrub -GpuType 'rocm' -Environment (New-RocmLaneEnv)
        Assert-Equal 'HIP_DEVICE_LIB_PATH,HIP_PATH,HIP_PLATFORM,INCLUDE,LLVM_PATH,Path,PKG_CONFIG_PATH,ROCM_PATH' (@($s.Keys | Sort-Object) -join ',') 'scrubbed names'
        foreach ($n in 'ROCM_PATH', 'HIP_PATH', 'HIP_PLATFORM', 'HIP_DEVICE_LIB_PATH', 'LLVM_PATH', 'PKG_CONFIG_PATH') { Assert-Null $s[$n] "$n unset" }
        Assert-Equal 'C:\runtime\bin;C:\Windows\System32' $s['Path'] 'PATH keeps its non-ROCm entries in order (slash and case spellings caught)'
        Assert-Equal 'C:\vs\include' $s['INCLUDE'] 'mixed list var keeps its other entry'
    }

    It 'leaves GPU_TYPE, the release pin and a same-prefix sibling tree alone' {
        $s = Get-BazelRocmEnvScrub -GpuType 'rocm' -Environment (New-RocmLaneEnv)
        foreach ($n in 'GPU_TYPE', 'ROCM_WINDOWS_RELEASE', 'OTHER_TREE') { Assert-False $s.ContainsKey($n) "$n untouched" }
    }

    It 'reads the live process environment and round-trips it through Set-BazelProcessEnv' {
        Invoke-InTestDir { param($dir)
            $vars = @{ GPU_TYPE = 'rocm'; ROCM_PATH = $dir; HIP_PATH = $null; HIP_PLATFORM = 'amd'; PATH = "$dir\bin;$env:PATH" }
            Invoke-WithEnv $vars {
                $before = $env:PATH
                $s = Get-BazelRocmEnvScrub -GpuType 'rocm' -Environment ([Environment]::GetEnvironmentVariables())
                $prev = Set-BazelProcessEnv -Values $s
                Assert-Null ([Environment]::GetEnvironmentVariable('ROCM_PATH')) 'ROCM_PATH really removed, not set empty'
                Assert-Null ([Environment]::GetEnvironmentVariable('HIP_PLATFORM')) 'HIP_PLATFORM removed'
                Assert-False ($env:PATH -like "*$dir\bin*") 'ROCm bin gone from PATH'
                $null = Set-BazelProcessEnv -Values $prev
                Assert-Equal $dir $env:ROCM_PATH 'ROCM_PATH restored'
                Assert-Equal 'amd' $env:HIP_PLATFORM 'HIP_PLATFORM restored'
                Assert-Equal $before $env:PATH 'PATH restored'
            }
        }
    }
}

Describe 'Build-LitertLmBazel: DXC zip pin' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmBazel -FunctionName 'Assert-LitertLmDxcPin')
    $sha = 'a1e89031421cf3c1fca6627766ab3020ca4f962ac7e2caa7fab2b33a8436151e'
    # The v0.17.1 WORKSPACE shape, with a neighbour so the match cannot run into it.
    $ws = "http_archive(`n    name = `"directx_shader_compiler`",`n    build_file = `"@//:BUILD.directx_shader_compiler`",`n" +
        "    sha256 = `"$sha`",`n    url = `"https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2602/dxc_2026_02_20.zip`",`n)`n" +
        "http_archive(`n    name = `"patchelf_linux_x86_64`",`n    sha256 = `"$('0' * 64)`",`n)`n"

    It 'passes when WORKSPACE pins the zip versions.env pins' { Assert-LitertLmDxcPin -Workspace $ws -Expected $sha; Assert-True $true 'no throw' }

    It 'refuses a different sha, an unset pin and a WORKSPACE without the archive' {
        Assert-Throws { Assert-LitertLmDxcPin -Workspace $ws -Expected ('b' * 64) } 'drift' -MessagePattern 'LITERT_LM_DXC_ZIP_SHA256 says'
        Assert-Throws { Assert-LitertLmDxcPin -Workspace $ws -Expected '' } 'unset' -MessagePattern 'is not set'
        Assert-Throws { Assert-LitertLmDxcPin -Workspace ($ws -replace 'directx_shader_compiler', 'dxc_renamed') -Expected $sha } 'absent' -MessagePattern 'no sha256-pinned'
    }

    It 'versions.env carries it and the stage forwards it' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        Assert-Equal $sha $v['LITERT_LM_DXC_ZIP_SHA256'] 'the pin the tests were written against'
    }
}

Describe 'Build-LitertLmBazel: the GPU payload' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmBazel -FunctionName 'Get-LitertLmGpuPayload', 'Install-LitertLmGpuPayload')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmCheck -FunctionName 'Get-LiteRtLmGpuExport')

    It 'is empty on the cpu and nvidia lanes' {
        foreach ($t in @($null, '', 'cpu', 'nvidia')) {
            Assert-Equal 0 @(Get-LitertLmGpuPayload -GpuType $t -PrebuiltDir 'C:\p' -DxcDir 'C:\d').Count "GPU_TYPE='$t'"
        }
    }

    function Get-LlmPayloadFixture {
        $entries = @(Get-LitertLmGpuPayload -GpuType 'rocm' -PrebuiltDir 'C:\p' -DxcDir 'C:\d')
        return @{ Entries = $entries
            Dlls = @($entries | Where-Object { $_.Dir -eq 'bin' } | ForEach-Object { Split-Path -Leaf $_.Source })
            PinKeys = @($entries | Where-Object { $_.PinKey } | ForEach-Object { $_.PinKey }) }
    }

    It 'ships exactly the DLLs the smoke check probes, next to the exe' {
        $payload = Get-LlmPayloadFixture
        $bin = @($payload.Dlls | Sort-Object) -join ','
        Assert-Equal (@((Get-LiteRtLmGpuExport).Keys | Sort-Object) -join ',') $bin 'payload bin DLLs == smoke-check DLLs'
        Assert-Equal 3 @($payload.Entries | Where-Object { $_.Dir -eq 'licenses\directx-shader-compiler' }).Count 'the three DXC licence texts'
    }

    It 'names every shipped DLL in a Windows deps.json row, which the licence page and SBOM render' {
        $deps = Get-TestJsonFile -Path (Join-Path (Get-RepoRoot) 'docs\deps\deps.json')
        $rows = @(@($deps.sections | Where-Object { $_.title -eq 'Windows Image' }).subsections.entries | Where-Object { $_.spdx })
        $names = @($rows | ForEach-Object { $_.name }) -join "`n"
        $dlls = (Get-LlmPayloadFixture).Dlls
        Assert-Equal 5 $dlls.Count 'the payload DLLs'
        foreach ($dll in $dlls) { Assert-True $names.Contains($dll) "$dll has a deps.json row with an spdx id" }
    }

    It 'pins every prebuilt DLL through versions.env, the media-litert branch args and the stage ARG' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $branch = Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $v
        $merge = Get-MediaMergeVersionArg -VersionTable $v
        $dockerfile = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder') -Raw
        $keys = (Get-LlmPayloadFixture).PinKeys + 'LITERT_LM_DXC_ZIP_SHA256'
        Assert-Equal 4 $keys.Count 'three DLL pins + the DXC zip pin'
        foreach ($k in $keys) {
            Assert-Match '^[0-9a-f]{64}$' $v[$k] "versions.env $k"
            Assert-Equal $v[$k] $branch[$k] "media-litert forwards $k"
            Assert-False $merge.Contains($k) "$k stays out of the merge stage"
            Assert-Match "(?m)^ARG $k=$($v[$k])\r?$" $dockerfile "Dockerfile.media-builder declares $k with the versions.env default"
            Assert-Match "(?m)^\s+$k=`"\`$\{$k\}`"" $dockerfile "and mirrors it to ENV"
        }
    }

    function New-LlmPayloadEntry {
        param([string]$Directory, [string]$Name, [string]$Content, [string]$Destination = 'bin', [string]$PinKey = 'OA_TEST_LLM_PIN')
        Write-TestFileTree -Root $Directory -Files @{ $Name = $Content }
        return @{ Source = Join-Path $Directory $Name; Dir = $Destination; PinKey = $PinKey }
    }

    It 'installs pinned files that match, and lays out bin + licences' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src'; $root = Join-Path $dir 'root'
            $payload = @(
                New-LlmPayloadEntry -Directory $src -Name 'libLiteRtWebGpuAccelerator.dll' -Content 'acc'
                New-LlmPayloadEntry -Directory $src -Name 'LICENSE-MS.txt' -Content 'terms' -Destination 'licenses\directx-shader-compiler' -PinKey ''
            )
            Invoke-WithEnv @{ OA_TEST_LLM_PIN = (Get-FileHash -LiteralPath $payload[0].Source -Algorithm SHA256).Hash.ToLowerInvariant() } {
                Install-LitertLmGpuPayload -Payload $payload -Root $root
            }
            Assert-True (Test-Path (Join-Path $root 'bin\libLiteRtWebGpuAccelerator.dll')) 'DLL next to the exe'
            Assert-True (Test-Path (Join-Path $root 'licenses\directx-shader-compiler\LICENSE-MS.txt')) 'licence staged'
        }
    }

    It 'refuses a hash mismatch, an unset pin and a missing file, before copying' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'root'
            $payload = @(New-LlmPayloadEntry -Directory $dir -Name 'libwebgpu_dawn.dll' -Content 'dawn')
            Invoke-WithEnv @{ OA_TEST_LLM_PIN = ('0' * 64) } {
                Assert-Throws { Install-LitertLmGpuPayload -Payload $payload -Root $root } 'mismatch' -MessagePattern 'pins 0{64}'
            }
            Invoke-WithEnv @{ OA_TEST_LLM_PIN = $null } {
                Assert-Throws { Install-LitertLmGpuPayload -Payload $payload -Root $root } 'unset' -MessagePattern 'is not a SHA256'
            }
            Assert-Throws { Install-LitertLmGpuPayload -Payload @(@{ Source = "$dir\nope.dll"; Dir = 'bin'; PinKey = '' }) -Root $root } 'missing' -MessagePattern 'payload missing'
            Assert-False (Test-Path (Join-Path $root 'bin\libwebgpu_dawn.dll')) 'nothing unverified was copied'
        }
    }
}

Describe 'rocm-checks\LiteRtLm.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmCheck -FunctionName 'Get-LiteRtLmFileFinding', 'Get-LiteRtLmLoadFinding', 'Get-LiteRtLmHelpFinding')

    It 'is a parameterless pwsh 7 check script' {
        $path = Join-Path (Get-RepoRoot) $script:LlmCheck
        Assert-Equal '#requires -Version 7.0' (Get-Content -LiteralPath $path -TotalCount 1) 'first line'
        $ast = (Get-TestScriptAst -ScriptPath $path)
        Assert-Null $ast.ParamBlock 'no params: Test-RocmImage.ps1 runs it bare'
    }

    It 'reports every missing file of an empty install, and nothing else' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ LITERT_LM_ROOT = $dir } {
                $f = @(& (Join-Path (Get-RepoRoot) $script:LlmCheck))
                Assert-Equal 7 $f.Count "exe + 5 DLLs + DXC licence: $($f -join ' | ')"
                Assert-Equal 0 $LASTEXITCODE 'leaves no exit code behind'
            }
        }
    }

    It 'passes a complete layout on file presence' {
        Invoke-InTestDir { param($dir)
            $dll = @('libLiteRtWebGpuAccelerator.dll', 'dxil.dll')
            $files = @{}
            foreach ($rel in @('bin\litert_lm_main.exe', 'licenses\directx-shader-compiler\LICENSE-MS.txt') + @($dll | ForEach-Object { "bin\$_" })) { $files[$rel] = "x`r`n" }
            Write-TestFileTree -Root $dir -Files $files
            Assert-Equal 0 @(Get-LiteRtLmFileFinding -Root $dir -Dll $dll).Count 'complete'
        }
    }

    It 'loads a real DLL and resolves its export in a child process; a bad image or missing export is a finding' {
        Invoke-InTestDir { param($dir)
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\version.dll') -Destination $dir
            Set-Content -LiteralPath (Join-Path $dir 'bad.dll') -Value 'not a PE image'
            Assert-Equal 0 @(Get-LiteRtLmLoadFinding -BinDir $dir -Export ([ordered]@{ 'version.dll' = 'GetFileVersionInfoW' })).Count 'real export'
            $f = @(Get-LiteRtLmLoadFinding -BinDir $dir -Export ([ordered]@{ 'version.dll' = 'LiteRtAcceleratorImpl'; 'bad.dll' = 'X'; 'absent.dll' = 'Y' }))
            Assert-Equal 2 $f.Count "missing export + bad image; an absent file is the file check's: $($f -join ' | ')"
            Assert-Match 'version\.dll .*lacks LiteRtAcceleratorImpl' $f[0] 'names the DLL and the export'
        }
    }

    It 'wants --backend in the --help text' {
        Invoke-InTestDir { param($dir)
            $good = Join-Path $dir 'good.cmd'; Set-Content -LiteralPath $good -Value '@echo   --backend (Executor backend to use); default: "gpu";'
            $bad = Join-Path $dir 'bad.cmd'; Set-Content -LiteralPath $bad -Value '@echo Flags from runtime/engine/litert_lm_main.cc:'
            Assert-Equal 0 @(Get-LiteRtLmHelpFinding -Exe $good).Count 'lists --backend'
            Assert-Equal 1 @(Get-LiteRtLmHelpFinding -Exe $bad).Count 'does not'
            Assert-Equal 0 @(Get-LiteRtLmHelpFinding -Exe (Join-Path $dir 'absent.exe')).Count 'absent exe is the file check''s'
        }
    }
}
Describe 'Build-LitertLmBazel install layout' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmBazel -FunctionName 'Assert-LitertLmBazelLayout')

    It 'requires an exe, a runtime DLL and a public header' {
        Invoke-InTestDir -Files @{ 'bin/litert_lm_main.exe' = "exe`n"; 'bin/runtime.dll' = "dll`n" } -Body { param($dir)
            $bin = Join-Path $dir 'bin'; $inc = Join-Path $dir 'include'
            New-Item -ItemType Directory -Path $inc | Out-Null
            Assert-Throws { Assert-LitertLmBazelLayout -BinOut $bin -IncOut $inc } 'missing header' -MessagePattern 'LITERT_LM_INCLUDE headers'
            Write-TestFileTree -Root $dir -Files @{ 'include/runtime.h' = "header`n" }
            Assert-Null (Assert-LitertLmBazelLayout -BinOut $bin -IncOut $inc) 'complete layout'
        }
    }
}
