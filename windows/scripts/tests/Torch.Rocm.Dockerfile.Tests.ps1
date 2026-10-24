#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Torch ROCm fixture setup is shared by installer, smoke and Dockerfile contracts.

. (Join-Path $PSScriptRoot 'Import-TorchRocmTestSetup.ps1')

Describe 'Dockerfile.torch: cpu and nvidia build the unchanged app stage' {
    $df = Get-TestDockerfileStages -Text (Get-TorchDockerfileText) -JoinContinuations -IgnoreComments -TrimLines
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
            @{ Why = 'the app COPY drops the ORT lock parser'; P = $appDiff; T = $text.Replace('windows\scripts\modules\WindowsUvLock.Common.psm1 ', '') }
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
        Assert-NoTorchRocmPinKeys -Pins $rocm1 -Pattern 'COMMIT$' -Message 'the source commits belong to the build stage only'
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
        Assert-Equal 0 @($w.Lines | Where-Object { $_ -match '^ARG SCCACHE_WEBDAV_ENDPOINT$' }).Count 'the endpoint is a secret mount, never an ARG the history records'
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
            $at = @($lines | Select-String -Pattern "^ARG $k=" | ForEach-Object { $_.LineNumber - 1 })
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
        $scriptText = (Get-TestScriptAst -ScriptPath $script:TorchRocmScript).Extent.Text
        $modules = @([regex]::Matches($scriptText, "'(Windows[A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-True ($modules.Count -ge 2) "module scan found: $($modules -join ',')"
        foreach ($m in $modules) {
            Assert-True $run.Contains("source=windows/scripts/modules/$m.psm1,target=C:\bkmnt\modules\$m.psm1") "module $m not mounted"
            $sibling = [regex]::Matches([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) "windows\scripts\modules\$m.psm1")), "PSScriptRoot\s+'([A-Za-z0-9._]+)\.psm1'")
            Assert-Equal 0 $sibling.Count "$m imports a sibling module the RUN does not mount"
        }
        Assert-Match "Install-TorchRocm\.ps1' -TorchRocm 1 .* -ModuleRoot 'C:\\bkmnt'.*Build-TorchApp\.ps1' -Mode verify" $run 'install from the flat module mount, then verify the app on ROCm torch'
        Assert-True $run.Contains('from=torch-rocm-wheels,source=/torch-rocm-wheels,target=C:\bkmnt\torch-rocm-wheels') 'the built wheels, from the build stage (source Unix-style)'
        Assert-True $run.Contains("-WheelDir 'C:\bkmnt\torch-rocm-wheels'") 'the installer reads them there'
    }
}

Describe 'Driver contract: TORCH_ROCM reaches Dockerfile.torch on the rocm lane only' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Add-BkVersionPins', 'Get-BkRocmStageArg')

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
