#requires -Version 7.0
# rocm lane's LiteRT-LM GPU backend (Build-LitertLmBazel.ps1 + rocm-checks\LiteRtLm.ps1): cpu/nvidia
# bazel command and env byte-identical, the env scrub, DXC and DLL pins, payload install, the body's
# gating and order, the smoke check. NOT covered: a bazel build, the real prebuilt DLLs, a GPU run.

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
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-RepoRoot) $script:LlmBazel), [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.CommandElements[0].Extent.Text -eq 'C:\bzl-tools\bazelisk.exe' }, $true))
        Assert-Equal 1 $calls.Count 'one bazelisk invocation'
        Assert-Equal '@bazelArgs @bazelCmd' (@($calls[0].CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' ') 'its arguments'
        $text = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) $script:LlmBazel) -Raw
        Assert-Match ([regex]::Escape("`$outputBase = 'C:\bzl'")) $text 'output base'
        Assert-Match ([regex]::Escape('$bazelArgs = @("--output_base=$outputBase")')) $text 'startup option'
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
    $script:LlmAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-RepoRoot) $script:LlmBazel), [ref]$null, [ref]$null)

    function Get-LlmBodyNode {
        param([scriptblock]$Where)
        @($script:LlmAst.FindAll({ param($n)
                    for ($p = $n.Parent; $p; $p = $p.Parent) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false } }
                    return [bool](& $Where $n)
                }, $true))
    }
    function Get-LlmCall {
        param([string]$Name)
        Get-LlmBodyNode { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }
    }
    function Get-LlmAncestor {
        param($Node, [type]$Type)
        for ($p = $Node.Parent; $p; $p = $p.Parent) { if ($p -is $Type) { return $p } }
    }
    function Test-LlmWithin { param($Inner, $Outer) $Outer.Extent.StartOffset -le $Inner.Extent.StartOffset -and $Inner.Extent.EndOffset -le $Outer.Extent.EndOffset }
    function Get-LlmIfChain {
        # Conditions of every if-clause holding $Node below $Stop, innermost first, joined by ' && '.
        param($Node, $Stop)
        $conds = @(for ($p = $Node.Parent; $p -and -not [object]::ReferenceEquals($p, $Stop); $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($c in $p.Clauses) { if (Test-LlmWithin $Node $c.Item2) { $c.Item1.Extent.Text } }
                }
            })
        $conds -join ' && '
    }
    $script:LlmBazelCall = @(Get-LlmCall 'C:\bzl-tools\bazelisk.exe')
    $script:LlmTry = Get-LlmAncestor $script:LlmBazelCall[0] ([System.Management.Automation.Language.TryStatementAst])

    It 'reads GPU_TYPE once, from the lane env' {
        $a = @(Get-LlmBodyNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$gpuType' })
        Assert-Equal 1 $a.Count 'one $gpuType assignment'
        Assert-Equal '[string]$env:GPU_TYPE' $a[0].Right.Extent.Text 'its source'
        Assert-Equal 1 $script:LlmBazelCall.Count 'one bazelisk call'
        Assert-NotNull $script:LlmTry 'bazelisk runs inside a try'
    }

    It 'hides the ROCm tree before the bazel server starts, and restores it in finally' {
        $scrub = @(Get-LlmCall 'Get-LitertLmRocmEnvScrub')
        Assert-Equal 1 $scrub.Count 'one scrub computation'
        Assert-Equal 'Get-LitertLmRocmEnvScrub -GpuType $gpuType -Environment ([Environment]::GetEnvironmentVariables())' $scrub[0].Extent.Text 'over the live env, gated on the lane'
        Assert-Equal '$envScrub' (Get-LlmAncestor $scrub[0] ([System.Management.Automation.Language.AssignmentStatementAst])).Left.Extent.Text 'kept in $envScrub'
        $set = @(Get-LlmCall 'Set-LitertLmProcessEnv')
        $apply = @($set | Where-Object { $_.Extent.Text -ceq 'Set-LitertLmProcessEnv -Values $envScrub' })
        Assert-Equal 1 $apply.Count 'the scrub is applied'
        Assert-Equal '$restoreEnv' (Get-LlmAncestor $apply[0] ([System.Management.Automation.Language.AssignmentStatementAst])).Left.Extent.Text 'its previous values kept'
        Assert-Equal '$envScrub.Count -gt 0' (Get-LlmIfChain $apply[0] $script:LlmTry.Body) 'applied whenever there is something to hide'
        Assert-True ($scrub[0].Extent.EndOffset -lt $apply[0].Extent.StartOffset) 'computed, then applied'
        Assert-True ($apply[0].Extent.EndOffset -lt $script:LlmBazelCall[0].Extent.StartOffset) 'before the first bazelisk call'
        Assert-True (Test-LlmWithin $apply[0] $script:LlmTry.Body) 'inside the try that restores it'
        $restore = @($set | Where-Object { $_.Extent.Text -ceq 'Set-LitertLmProcessEnv -Values $restoreEnv' })
        Assert-Equal 1 $restore.Count 'one restore'
        Assert-True (Test-LlmWithin $restore[0] $script:LlmTry.Finally) 'in the finally block'
        Assert-Equal '$restoreEnv' (Get-LlmIfChain $restore[0] $script:LlmTry.Finally) 'only when something was hidden'
        $init = @(Get-LlmBodyNode { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -ceq '$restoreEnv = $null' })
        Assert-True ($init.Count -eq 1 -and $init[0].Extent.EndOffset -lt $script:LlmTry.Extent.StartOffset) 'defined before the try (StrictMode in finally)'
    }

    It 'checks the DXC pin on the rocm lane only, before bazel fetches the zip' {
        $pin = @(Get-LlmCall 'Assert-LitertLmDxcPin')
        Assert-Equal 1 $pin.Count 'one pin check'
        Assert-Equal 'Assert-LitertLmDxcPin -Workspace $ws -Expected $env:LITERT_LM_DXC_ZIP_SHA256' $pin[0].Extent.Text 'against versions.env'
        Assert-Equal "`$gpuType -eq 'rocm'" (Get-LlmIfChain $pin[0] $script:LlmTry.Body) 'rocm lane only'
        Assert-True ($pin[0].Extent.EndOffset -lt $script:LlmBazelCall[0].Extent.StartOffset) 'before bazel'
    }

    It 'installs the lane''s GPU payload after the build' {
        $get = @(Get-LlmCall 'Get-LitertLmGpuPayload')
        Assert-Equal 1 $get.Count 'one payload lookup'
        Assert-Equal "Get-LitertLmGpuPayload -GpuType `$gpuType -PrebuiltDir 'C:\llm\prebuilt\windows_x86_64' -DxcDir (Join-Path `$outputBase 'external\directx_shader_compiler')" `
            ($get[0].Extent.Text -replace '\s*`\r?\n\s*', ' ') 'gated on the lane, DXC from the output base'
        Assert-Equal '$gpuPayload' (Get-LlmAncestor $get[0] ([System.Management.Automation.Language.AssignmentStatementAst])).Left.Extent.Text 'kept in $gpuPayload'
        $inst = @(Get-LlmCall 'Install-LitertLmGpuPayload')
        Assert-Equal 1 $inst.Count 'one install'
        Assert-Equal "Install-LitertLmGpuPayload -Payload `$gpuPayload -Root (Join-Path `$InstallDir 'lib\litert-lm')" $inst[0].Extent.Text 'into the tree the smoke check reads'
        Assert-Equal '$gpuPayload.Count -gt 0' (Get-LlmIfChain $inst[0] $script:LlmTry.Body) 'whenever the lane has one'
        Assert-True ($script:LlmBazelCall[0].Extent.EndOffset -lt $get[0].Extent.StartOffset) 'after bazel'
    }
}

Describe 'Build-LitertLmBazel: the ROCm tree is hidden from bazel on the rocm lane' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlmBazel -FunctionName 'Get-LitertLmRocmEnvScrub', 'Set-LitertLmProcessEnv')

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
            Assert-Equal 0 (Get-LitertLmRocmEnvScrub -GpuType $t -Environment (New-RocmLaneEnv)).Count "GPU_TYPE='$t'"
        }
    }

    It 'unsets the ROCm-layer vars and drops ROCm entries from list vars, nothing else' {
        $s = Get-LitertLmRocmEnvScrub -GpuType 'rocm' -Environment (New-RocmLaneEnv)
        Assert-Equal 'HIP_DEVICE_LIB_PATH,HIP_PATH,HIP_PLATFORM,INCLUDE,LLVM_PATH,Path,PKG_CONFIG_PATH,ROCM_PATH' (@($s.Keys | Sort-Object) -join ',') 'scrubbed names'
        foreach ($n in 'ROCM_PATH', 'HIP_PATH', 'HIP_PLATFORM', 'HIP_DEVICE_LIB_PATH', 'LLVM_PATH', 'PKG_CONFIG_PATH') { Assert-Null $s[$n] "$n unset" }
        Assert-Equal 'C:\runtime\bin;C:\Windows\System32' $s['Path'] 'PATH keeps its non-ROCm entries in order (slash and case spellings caught)'
        Assert-Equal 'C:\vs\include' $s['INCLUDE'] 'mixed list var keeps its other entry'
    }

    It 'leaves GPU_TYPE, the release pin and a same-prefix sibling tree alone' {
        $s = Get-LitertLmRocmEnvScrub -GpuType 'rocm' -Environment (New-RocmLaneEnv)
        foreach ($n in 'GPU_TYPE', 'ROCM_WINDOWS_RELEASE', 'OTHER_TREE') { Assert-False $s.ContainsKey($n) "$n untouched" }
    }

    It 'reads the live process environment and round-trips it through Set-LitertLmProcessEnv' {
        Invoke-InTestDir { param($dir)
            $vars = @{ GPU_TYPE = 'rocm'; ROCM_PATH = $dir; HIP_PATH = $null; HIP_PLATFORM = 'amd'; PATH = "$dir\bin;$env:PATH" }
            Invoke-WithEnv $vars {
                $before = $env:PATH
                $s = Get-LitertLmRocmEnvScrub -GpuType 'rocm' -Environment ([Environment]::GetEnvironmentVariables())
                $prev = Set-LitertLmProcessEnv -Values $s
                Assert-Null ([Environment]::GetEnvironmentVariable('ROCM_PATH')) 'ROCM_PATH really removed, not set empty'
                Assert-Null ([Environment]::GetEnvironmentVariable('HIP_PLATFORM')) 'HIP_PLATFORM removed'
                Assert-False ($env:PATH -like "*$dir\bin*") 'ROCm bin gone from PATH'
                $null = Set-LitertLmProcessEnv -Values $prev
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

    It 'ships exactly the DLLs the smoke check probes, next to the exe' {
        $p = @(Get-LitertLmGpuPayload -GpuType 'rocm' -PrebuiltDir 'C:\p' -DxcDir 'C:\d')
        $bin = @($p | Where-Object { $_.Dir -eq 'bin' } | ForEach-Object { Split-Path -Leaf $_.Source } | Sort-Object) -join ','
        Assert-Equal (@((Get-LiteRtLmGpuExport).Keys | Sort-Object) -join ',') $bin 'payload bin DLLs == smoke-check DLLs'
        Assert-Equal 3 @($p | Where-Object { $_.Dir -eq 'licenses\directx-shader-compiler' }).Count 'the three DXC licence texts'
    }

    It 'names every shipped DLL in a Windows deps.json row, which the licence page and SBOM render' {
        $deps = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'docs\deps\deps.json') -Raw | ConvertFrom-Json
        $rows = @(@($deps.sections | Where-Object { $_.title -eq 'Windows Image' }).subsections.entries | Where-Object { $_.spdx })
        $names = @($rows | ForEach-Object { $_.name }) -join "`n"
        $dlls = @(Get-LitertLmGpuPayload -GpuType 'rocm' -PrebuiltDir 'C:\p' -DxcDir 'C:\d' | Where-Object { $_.Dir -eq 'bin' } | ForEach-Object { Split-Path -Leaf $_.Source })
        Assert-Equal 5 $dlls.Count 'the payload DLLs'
        foreach ($dll in $dlls) { Assert-True $names.Contains($dll) "$dll has a deps.json row with an spdx id" }
    }

    It 'pins every prebuilt DLL through versions.env, the media-litert branch args and the stage ARG' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $branch = Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $v
        $merge = Get-MediaMergeVersionArg -VersionTable $v
        $dockerfile = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder') -Raw
        $keys = @(@(Get-LitertLmGpuPayload -GpuType 'rocm' -PrebuiltDir 'C:\p' -DxcDir 'C:\d') | Where-Object { $_.PinKey } | ForEach-Object { $_.PinKey }) + 'LITERT_LM_DXC_ZIP_SHA256'
        Assert-Equal 4 $keys.Count 'three DLL pins + the DXC zip pin'
        foreach ($k in $keys) {
            Assert-Match '^[0-9a-f]{64}$' $v[$k] "versions.env $k"
            Assert-Equal $v[$k] $branch[$k] "media-litert forwards $k"
            Assert-False $merge.Contains($k) "$k stays out of the merge stage"
            Assert-Match "(?m)^ARG $k=$($v[$k])\r?$" $dockerfile "Dockerfile.media-builder declares $k with the versions.env default"
            Assert-Match "(?m)^\s+$k=`"\`$\{$k\}`"" $dockerfile "and mirrors it to ENV"
        }
    }

    It 'installs pinned files that match, and lays out bin + licences' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src'; $root = Join-Path $dir 'root'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            $a = Join-Path $src 'libLiteRtWebGpuAccelerator.dll'; Set-Content -LiteralPath $a -Value 'acc' -NoNewline
            $l = Join-Path $src 'LICENSE-MS.txt'; Set-Content -LiteralPath $l -Value 'terms' -NoNewline
            $payload = @(
                @{ Source = $a; Dir = 'bin'; PinKey = 'OA_TEST_LLM_PIN' }
                @{ Source = $l; Dir = 'licenses\directx-shader-compiler'; PinKey = '' }
            )
            Invoke-WithEnv @{ OA_TEST_LLM_PIN = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash.ToLowerInvariant() } {
                Install-LitertLmGpuPayload -Payload $payload -Root $root
            }
            Assert-True (Test-Path (Join-Path $root 'bin\libLiteRtWebGpuAccelerator.dll')) 'DLL next to the exe'
            Assert-True (Test-Path (Join-Path $root 'licenses\directx-shader-compiler\LICENSE-MS.txt')) 'licence staged'
        }
    }

    It 'refuses a hash mismatch, an unset pin and a missing file, before copying' {
        Invoke-InTestDir { param($dir)
            $a = Join-Path $dir 'libwebgpu_dawn.dll'; Set-Content -LiteralPath $a -Value 'dawn' -NoNewline
            $root = Join-Path $dir 'root'
            $payload = @(@{ Source = $a; Dir = 'bin'; PinKey = 'OA_TEST_LLM_PIN' })
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
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
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
            foreach ($rel in @('bin\litert_lm_main.exe', 'licenses\directx-shader-compiler\LICENSE-MS.txt') + @($dll | ForEach-Object { "bin\$_" })) {
                $p = Join-Path $dir $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
                Set-Content -LiteralPath $p -Value 'x'
            }
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
