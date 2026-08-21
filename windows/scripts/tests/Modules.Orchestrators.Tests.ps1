#requires -Version 7.0
# #144 (2026-08-21): the library modules' ENTRY POINTS had zero tests — suites
# covered leaf helpers only, so the composed paths (the part consumers actually
# call) were unexercised. PATH-fake pattern as in the GitCloneRetry/NinjaRetry
# suites: a .bat on PATH logs its argv and behaves per env knobs.
#
# Covered: Invoke-WasmOpt, Get-ReusableBuildContainer, Invoke-SlangShaderCompile
# (fail-fast contracts), Invoke-VulkanValidationRun (fail-fast contracts).
# NOT covered, deliberately (documented gaps, not fake-greens):
#   Invoke-BuildCodeQL — resolves codeql.exe at a fixed workspace path and
#   DOWNLOADS the CLI when absent; faking needs a real PE there (a renamed
#   .bat is not executable).
#   Invoke-CmakeConfigureAndBuild — needs a full WindowsBuild.Common context
#   session and its tail semantics are consumer-lane territory; belongs in a
#   dedicated suite alongside real rust-lane CI coverage.

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Import-Module (Join-Path $modDir 'WindowsWasmOpt.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsContainerBuild.Reuse.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsSlang.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsVulkanValidation.Common.psm1') -Force -DisableNameChecking

Describe 'Invoke-WasmOpt (orchestrator)' {

    $newFakeWasmOpt = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo WASMOPT %* >> "%WBT_WASMOPT_LOG%"',
            'if "%WBT_WASMOPT_MODE%"=="fail" exit /b 1',
            'if "%WBT_WASMOPT_MODE%"=="failfirst" (',
            '  echo %* | findstr /C:"--all-features" >nul && exit /b 0',
            '  exit /b 1',
            ')',
            'exit /b 0'
        )
        Set-Content -LiteralPath (Join-Path $dir 'wasm-opt.bat') -Value ($lines -join "`r`n") -Encoding ASCII
    }

    It 'succeeds first try with exactly one invocation carrying input and output' {
        Invoke-InTestDir { param($dir)
            & $newFakeWasmOpt $dir
            $log = Join-Path $dir 'wasmopt.log'
            Invoke-WithEnv @{ PATH = "$dir;$env:PATH"; WBT_WASMOPT_LOG = $log; WBT_WASMOPT_MODE = 'ok' } {
                Invoke-WasmOpt -InputPath 'in.wasm' -OutputPath 'out.wasm'
            }
            $calls = @(Get-Content $log)
            Assert-Equal 1 $calls.Count 'exactly one wasm-opt invocation'
            Assert-Match 'in\.wasm' $calls[0] 'input forwarded'
            Assert-Match 'out\.wasm' $calls[0] 'output forwarded'
        }
    }

    It 'retries ONCE with --all-features when the flagged run fails' {
        Invoke-InTestDir { param($dir)
            & $newFakeWasmOpt $dir
            $log = Join-Path $dir 'wasmopt.log'
            Invoke-WithEnv @{ PATH = "$dir;$env:PATH"; WBT_WASMOPT_LOG = $log; WBT_WASMOPT_MODE = 'failfirst' } {
                Invoke-WasmOpt -InputPath 'in.wasm' -OutputPath 'out.wasm'
            }
            $calls = @(Get-Content $log)
            Assert-Equal 2 $calls.Count 'first attempt + one retry'
            Assert-False ($calls[0] -match '--all-features') 'first attempt uses explicit feature flags'
            Assert-Match '--all-features' $calls[1] 'retry escalates to --all-features'
        }
    }

    It 'throws when both attempts fail' {
        Invoke-InTestDir { param($dir)
            & $newFakeWasmOpt $dir
            $log = Join-Path $dir 'wasmopt.log'
            Invoke-WithEnv @{ PATH = "$dir;$env:PATH"; WBT_WASMOPT_LOG = $log; WBT_WASMOPT_MODE = 'fail' } {
                Assert-Throws { Invoke-WasmOpt -InputPath 'in.wasm' -OutputPath 'out.wasm' } 'both attempts failing must throw'
            }
        }
    }
}

Describe 'Get-ReusableBuildContainer (orchestrator)' {

    # FUNCTION fake, not a .bat: the module passes '{{.State.Running}}|{{.Image}}'
    # as one argument, and a .bat goes through cmd.exe, which eats the bare `|`
    # as a pipe (a real docker.EXE receives the raw command line - .bat fakes
    # cannot). `& $DockerExe` resolves function names too, and the fake sets
    # $global:LASTEXITCODE explicitly for the module's native-style checks.
    $newFakeDocker = {
        Set-Item function:global:WbtDockerFake {
            $joined = $args -join ' '
            Add-Content -LiteralPath $env:WBT_DOCKER_LOG -Value ("DOCKER " + $joined)
            if ($joined -match '\{\{\.Id\}\}') {
                if ($env:WBT_D_IMGID) { $global:LASTEXITCODE = 0; return $env:WBT_D_IMGID }
                $global:LASTEXITCODE = 1; return
            }
            if ($joined -match 'State\.Running') {
                if ($env:WBT_D_STATE) { $global:LASTEXITCODE = 0; return $env:WBT_D_STATE }
                $global:LASTEXITCODE = 1; return
            }
            if ($args.Count -gt 0 -and $args[0] -eq 'inspect') {
                $global:LASTEXITCODE = [int]$env:WBT_D_INSPECT_EXIT; return
            }
            $global:LASTEXITCODE = 0
        }
    }
    $removeFakeDocker = { Remove-Item function:global:WbtDockerFake -ErrorAction SilentlyContinue }

    It 'creates a fresh container when nothing exists (Reused=false, docker run invoked)' {
        Invoke-InTestDir { param($dir)
            & $newFakeDocker
            try {
                $log = Join-Path $dir 'docker.log'
                $r = Invoke-WithEnv @{ WBT_DOCKER_LOG = $log; WBT_D_IMGID = ''; WBT_D_STATE = ''; WBT_D_INSPECT_EXIT = '1' } {
                    Get-ReusableBuildContainer -DockerExe 'WbtDockerFake' -Name 'wbt-cont' -Image 'img:tag'
                }
                Assert-Equal $false $r.Reused 'nothing existed - not a reuse'
                Assert-Equal 'wbt-cont' $r.Name 'name unchanged'
                Assert-Match 'run -d --name wbt-cont' ((Get-Content $log) -join "`n") 'docker run created it'
            } finally { & $removeFakeDocker }
        }
    }

    It 'reuses a RUNNING container on the same image without touching docker run' {
        Invoke-InTestDir { param($dir)
            & $newFakeDocker
            try {
                $log = Join-Path $dir 'docker.log'
                $r = Invoke-WithEnv @{ WBT_DOCKER_LOG = $log; WBT_D_IMGID = 'sha256:abc'; WBT_D_STATE = 'true|sha256:abc'; WBT_D_INSPECT_EXIT = '0' } {
                    Get-ReusableBuildContainer -DockerExe 'WbtDockerFake' -Name 'wbt-cont' -Image 'img:tag'
                }
                Assert-Equal $true $r.Reused 'running same-image container is reused'
                Assert-False ((Get-Content $log) -join "`n" -match ' run -d') 'no new container created'
            } finally { & $removeFakeDocker }
        }
    }

    It '-Fresh falls back to a UNIQUE name when the old container survives rm (wcifs lock)' {
        Invoke-InTestDir { param($dir)
            & $newFakeDocker
            try {
                $log = Join-Path $dir 'docker.log'
                # bare inspect exit 0 = the survivor probe finds the old container alive
                $r = Invoke-WithEnv @{ WBT_DOCKER_LOG = $log; WBT_D_IMGID = ''; WBT_D_STATE = ''; WBT_D_INSPECT_EXIT = '0' } {
                    Get-ReusableBuildContainer -DockerExe 'WbtDockerFake' -Name 'wbt-cont' -Image 'img:tag' -Fresh 3>$null
                }
                Assert-True ($r.Name -ne 'wbt-cont') 'survivor forces a unique fallback name'
                Assert-Match '^wbt-cont-' $r.Name 'fallback keeps the base name as prefix'
            } finally { & $removeFakeDocker }
        }
    }
}

Describe 'Invoke-SlangShaderCompile (fail-fast contracts)' {

    It 'missing SourceRoot is a documented SKIP, not an error' {
        Invoke-InTestDir { param($dir)
            # must not throw; the function warns and returns
            Invoke-SlangShaderCompile -ManifestPath (Join-Path $dir 'manifest.json') -SourceRoot (Join-Path $dir 'no-such-dir') 6>$null
            Assert-True $true 'reached: no exception'
        }
    }

    It 'missing manifest is a TERMINATING error (the exit-2 contract, never a silent skip)' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'shaders'
            New-Item -ItemType Directory -Path $src | Out-Null
            Assert-Throws {
                Invoke-SlangShaderCompile -ManifestPath (Join-Path $dir 'missing.json') -SourceRoot $src 6>$null
            } 'module-scope EAP=Stop must make the Write-Error terminating'
        }
    }
}

Describe 'Invoke-VulkanValidationRun (fail-fast contracts)' {

    It 'throws on a missing executable' {
        Invoke-InTestDir { param($dir)
            Assert-Throws {
                Invoke-VulkanValidationRun -ExecutablePath (Join-Path $dir 'nope.exe') -LogPath (Join-Path $dir 'v.log')
            } 'missing exe must throw'
        }
    }

    It 'throws on a missing layer directory / working directory (all preconditions gate)' {
        Invoke-InTestDir { param($dir)
            $exe = Join-Path $dir 'app.bat'
            Set-Content -LiteralPath $exe -Value '@echo off' -Encoding ASCII
            Assert-Throws {
                Invoke-VulkanValidationRun -ExecutablePath $exe -LogPath (Join-Path $dir 'v.log') -LayerPath (Join-Path $dir 'no-layers')
            } 'missing layer dir must throw'
            Assert-Throws {
                Invoke-VulkanValidationRun -ExecutablePath $exe -LogPath (Join-Path $dir 'v.log') -WorkingDirectory (Join-Path $dir 'no-cwd')
            } 'missing working dir must throw'
        }
    }
}
