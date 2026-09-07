#requires -Version 7.0
# #144 (2026-08-21): the library modules' ENTRY POINTS had zero tests — suites
# covered leaf helpers only, so the composed paths (the part consumers actually
# call) were unexercised. PATH-fake pattern as in the GitCloneRetry/NinjaRetry
# suites: a .bat on PATH logs its argv and behaves per env knobs.
#
# Covered: Invoke-WasmOpt, Get-ReusableBuildContainer, Wait-ContainerExit,
# Invoke-SlangShaderCompile (fail-fast contracts), Invoke-VulkanValidationRun
# (fail-fast contracts).
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

Describe 'Wait-ContainerExit (the client exit code is not evidence)' {

    # FUNCTION fake for the same reason as Get-ReusableBuildContainer's above:
    # '{{.State.Status}}' is one argument and a .bat would route it through
    # cmd.exe. WBT_W_STATUS is a comma-separated SCRIPT of answers, one per
    # probe (the last one repeats), so a wait can be driven through several
    # states in one test; 'ERR:<text>' makes that probe exit 1 with <text> on
    # stderr, which is how docker reports both a missing container and a dead
    # daemon.
    $newFakeDocker = {
        Set-Item function:global:WbtWaitDockerFake {
            $joined = $args -join ' '
            if ($joined -match 'State\.Status') {
                $seq = @($env:WBT_W_STATUS -split ',')
                $i = [int]$env:WBT_W_CALL
                $env:WBT_W_CALL = "$($i + 1)"
                $answer = if ($i -lt $seq.Count) { $seq[$i] } else { $seq[-1] }
                if ($answer -like 'ERR:*') {
                    $global:LASTEXITCODE = 1
                    Write-Error $answer.Substring(4) -ErrorAction Continue
                    return
                }
                # 'NOISY:<answer>' = exit 0 with a stderr notice FIRST, the way
                # docker prints client warnings before its stdout value.
                if ($answer -like 'NOISY:*') {
                    Write-Error 'WARNING: DOCKER_HOST env var is deprecated' -ErrorAction Continue
                    $global:LASTEXITCODE = 0
                    return $answer.Substring(6)
                }
                $global:LASTEXITCODE = 0
                return $answer
            }
            if ($joined -match 'State\.ExitCode') {
                if ($env:WBT_W_EXIT -like 'ERR:*') {
                    $global:LASTEXITCODE = 1
                    Write-Error $env:WBT_W_EXIT.Substring(4) -ErrorAction Continue
                    return
                }
                if ($env:WBT_W_EXIT -like 'NOISY:*') {
                    Write-Error 'WARNING: DOCKER_HOST env var is deprecated' -ErrorAction Continue
                    $global:LASTEXITCODE = 0
                    return $env:WBT_W_EXIT.Substring(6)
                }
                $global:LASTEXITCODE = 0
                return $env:WBT_W_EXIT
            }
            $global:LASTEXITCODE = 0
        }
    }
    $removeFakeDocker = { Remove-Item function:global:WbtWaitDockerFake }

    # Installs the fake and the answer script, and always removes the fake, so
    # a failing case cannot leak its state into the next one.
    $withFake = {
        param([string]$Status, [string]$ExitCode, [scriptblock]$Body)
        & $newFakeDocker
        try {
            Invoke-WithEnv @{ WBT_W_CALL = '0'; WBT_W_STATUS = $Status; WBT_W_EXIT = $ExitCode } $Body
        } finally { & $removeFakeDocker }
    }

    It 'returns the real exit code of a container that has already stopped' {
        & $withFake 'exited' '0' {
            Assert-Equal 0 (Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w')
        }
    }

    It 'reports a genuine build failure faithfully (nothing is swallowed)' {
        & $withFake 'exited' '7' {
            Assert-Equal 7 (Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w')
        }
    }

    It 'keeps waiting while the container runs on after the client returned' {
        & $withFake 'running,running,exited' '0' {
            Assert-Equal 0 (Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' -PollSeconds 1 6>$null)
            Assert-Equal '3' $env:WBT_W_CALL 'it polled until the state stopped saying running'
        }
    }

    It 'throws NAMING the vanished container instead of reporting a bogus "exit "' {
        & $withFake 'ERR:Error: No such object: wbt-w' '0' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'a container that cannot be inspected is not a zero exit' -MessagePattern 'no longer exists'
        }
    }

    It 'retries an unreachable daemon (the fault it exists for) and says so when it gives up' {
        & $withFake 'ERR:error during connect: open //./pipe/docker_engine: The system cannot find the file specified.' '0' {
            Assert-Throws {
                Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' -PollSeconds 1 -TimeoutMinutes 0.02 3>$null
            } 'an unreachable daemon says nothing about the container' -MessagePattern 'daemon was unreachable for \d+ consecutive'
        }
    }

    It 'throws immediately on an inspect failure that is neither of those' {
        & $withFake 'ERR:Cannot read the state: access is denied' '0' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'an unclassified inspect failure must not be waited out' `
                -MessagePattern 'neither a missing container nor an unreachable daemon'
        }
    }

    It 'has a real timeout instead of looping forever' {
        & $withFake 'running' '0' {
            Assert-Throws {
                Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' -PollSeconds 1 -TimeoutMinutes 0.02 6>$null
            } 'a container that never stops must not hang the lane' -MessagePattern "gave up after .* still 'running'"
        }
    }

    It 'refuses to call a container that never started a success' {
        & $withFake 'created' '0' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                "state 'created' has ExitCode 0 without having run anything" -MessagePattern 'never started'
        }
    }

    It 'refuses to guess when the exit code itself cannot be read' {
        & $withFake 'exited' 'ERR:Error: No such object: wbt-w' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'an unreadable exit code is not a zero one' -MessagePattern 'exit code could not be read'
        }
    }

    It 'throws on a non-numeric exit code rather than coercing it to 0' {
        & $withFake 'exited' 'not-a-number' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'a non-numeric code means the format changed under us' -MessagePattern 'non-numeric exit code'
        }
    }

    It 'a stderr notice on a ZERO-exit inspect is never the value (status nor exit code)' {
        # A merged stream once made the notice the "value": a clean container
        # read as a non-numeric exit code, a running one as finished.
        & $withFake 'NOISY:exited' 'NOISY:0' {
            Assert-Equal 0 (Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w')
        }
    }

    It 'fails CLOSED on a state it does not recognise instead of calling it finished' {
        & $withFake 'weird-new-state' '0' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'an unknown state must not read as a finished container' `
                -MessagePattern 'does not understand'
        }
    }

    It 'fails CLOSED on an EMPTY state string too' {
        & $withFake '' '0' {
            Assert-Throws { Wait-ContainerExit -DockerExe 'WbtWaitDockerFake' -Name 'wbt-w' } `
                'an empty state is unknown, not finished' -MessagePattern 'does not understand'
        }
    }
}

Describe 'Invoke-ContainerBuild bind-mount transport (client vs container)' {

    # The wiring of Wait-ContainerExit into the orchestrator. The WAITING is
    # covered above; what is pinned here is that the container's verdict wins,
    # that the happy path is untouched, and that the run stays off both --rm
    # (which would delete the exit code) and the reusable container's name
    # (which would delete the build tree that makes reuse worth doing).
    $newFakeDocker = {
        Set-Item function:global:WbtBindDockerFake {
            $joined = $args -join ' '
            Add-Content -LiteralPath $env:WBT_B_LOG -Value ("DOCKER " + $joined)
            if ($joined -match 'State\.Status') {
                # 'MISSING' = docker run failed before a container existed.
                if ($env:WBT_B_STATUS -eq 'MISSING') {
                    $global:LASTEXITCODE = 1
                    Write-Error 'Error: No such object: wbt-reusable-bindmount' -ErrorAction Continue
                    return
                }
                $global:LASTEXITCODE = 0
                return $env:WBT_B_STATUS
            }
            if ($joined -match 'State\.ExitCode') { $global:LASTEXITCODE = 0; return $env:WBT_B_EXIT }
            # A bare 'inspect <name>' is Remove-BuildContainerSafe's survivor
            # probe; WBT_B_SURVIVE=1 fakes the wcifs lock (the survivor lives).
            if ($args[0] -eq 'inspect') {
                $global:LASTEXITCODE = if ($env:WBT_B_SURVIVE -eq '1') { 0 } else { 1 }
                return
            }
            # --rm marks Test-ContainerBindMount's probe run, which is allowed
            # to use it (it inspects nothing afterwards).
            if ($args[0] -eq 'run' -and $joined -match '--rm') { $global:LASTEXITCODE = 0; return }
            if ($args[0] -eq 'run') { $global:LASTEXITCODE = [int]$env:WBT_B_RUN_EXIT; return }
            $global:LASTEXITCODE = 0
        }
    }
    $removeFakeDocker = { Remove-Item function:global:WbtBindDockerFake }

    # $Body receives the docker log path and the build's return value.
    $build = {
        param([string]$ClientExit, [string]$Status, [string]$ContainerExit, [scriptblock]$Body)
        Invoke-InTestDir { param($dir)
            & $newFakeDocker
            try {
                $log = Join-Path $dir 'docker.log'
                Invoke-WithEnv @{ WBT_B_LOG = $log; WBT_B_STATUS = $Status; WBT_B_EXIT = $ContainerExit
                    WBT_B_RUN_EXIT = $ClientExit; WBT_B_SURVIVE = '0'
                } {
                    & $Body $log $dir
                }
            } finally { & $removeFakeDocker }
        }
    }

    $common = @{
        DockerExe = 'WbtBindDockerFake'; Image = 'img:tag'; ContainerName = 'wbt-reusable'
        BuildCommand = @('build.cmd'); UseBindMount = $true
    }

    It 'a clean build is unchanged: it runs, reads exit 0, and returns the bindmount transport' {
        & $build '0' 'exited' '0' { param($log, $dir)
            $r = Invoke-ContainerBuild @common -RepoRoot $dir
            Assert-Equal 'bindmount' $r.Transport
            Assert-Match '(?m)^DOCKER run --name wbt-reusable-bindmount' ((Get-Content $log) -join "`n")
        }
    }

    It 'the build run carries no --rm (with it the daemon deletes the exit code)' {
        & $build '0' 'exited' '0' { param($log, $dir)
            $null = Invoke-ContainerBuild @common -RepoRoot $dir
            $runLine = @(Get-Content $log | Where-Object { $_ -match '^DOCKER run --name' })
            Assert-Equal 1 $runLine.Count 'exactly one build run'
            Assert-False ($runLine[0] -match '--rm') 'the build run must outlive its client'
        }
    }

    It 'never removes the REUSABLE container - only its own bindmount one' {
        & $build '0' 'exited' '0' { param($log, $dir)
            $null = Invoke-ContainerBuild @common -RepoRoot $dir
            $removed = @(Get-Content $log | Where-Object { $_ -match '^DOCKER rm -f ' })
            Assert-True ($removed.Count -ge 1) 'it removes what it created'
            Assert-Equal 0 @($removed | Where-Object { $_ -notmatch 'wbt-reusable-bindmount$' }).Count `
                'a bind-mount run that removed wbt-reusable would throw away the incremental build tree'
        }
    }

    It 'trusts the container over a client that dropped its pipe (the whole point)' {
        # Client says 1, container exited 0: the failure that did not happen.
        & $build '1' 'exited' '0' { param($log, $dir)
            $r = Invoke-ContainerBuild @common -RepoRoot $dir 3>$null
            Assert-Equal 'bindmount' $r.Transport 'a completed build must not be reported as failed'
        }
    }

    It 'still fails, with the message it always had, when the CONTAINER failed' {
        & $build '1' 'exited' '1' { param($log, $dir)
            Assert-Throws { Invoke-ContainerBuild @common -RepoRoot $dir 3>$null } `
                'a real failure stays a failure' -MessagePattern 'Container build failed \(exit 1\)'
        }
    }

    It 'reports the CLIENT code when docker run never created a container' {
        # A bad image reference or an unmountable source fails before any
        # container exists; there is nothing to wait on and the client's exit
        # code is the whole story, so the old message stands.
        & $build '125' 'MISSING' '0' { param($log, $dir)
            Assert-Throws { Invoke-ContainerBuild @common -RepoRoot $dir } `
                'a run that never started must not be reported as a vanished container' `
                -MessagePattern 'Container build failed \(exit 125\) - docker run never created a container'
        }
    }

    It 'falls back to a UNIQUE name when the pre-removal cannot free it (wcifs lock)' {
        # A held name makes 'docker run --name' fail 125 and the wait would
        # read the STALE exit code: a build that never ran, reported green.
        & $build '0' 'exited' '0' { param($log, $dir)
            $r = Invoke-WithEnv @{ WBT_B_SURVIVE = '1' } {
                Invoke-ContainerBuild @common -RepoRoot $dir 3>$null
            }
            Assert-Equal 'bindmount' $r.Transport 'the fallback name must still build'
            $runLines = @(Get-Content $log | Where-Object { $_ -match '^DOCKER run --name' })
            Assert-Equal 1 $runLines.Count 'exactly one build run'
            Assert-Match '--name wbt-reusable-bindmount-[0-9a-f]{6} ' $runLines[0] `
                'the held name must never be reused for the run'
        }
    }

    It 'refuses to touch a leftover that is still RUNNING under its name' {
        # Force-removing it would kill a concurrent build of this tree, or the
        # evidence a timed-out wait deliberately kept.
        & $build '0' 'running' '0' { param($log, $dir)
            Assert-Throws { Invoke-ContainerBuild @common -RepoRoot $dir } `
                'a live container must not be force-removed' -MessagePattern 'already running'
            Assert-Equal 0 @(Get-Content $log | Where-Object { $_ -match '^DOCKER (rm -f|run --name) ' }).Count `
                'neither a removal nor a build run may happen while the name is live'
        }
    }

    It 'keeps the container on failure so the docker logs advice stays runnable' {
        & $build '1' 'exited' '1' { param($log, $dir)
            Assert-Throws { Invoke-ContainerBuild @common -RepoRoot $dir 3>$null } `
                'a real failure stays a failure' -MessagePattern 'Container build failed \(exit 1\)'
            $lines = @(Get-Content $log)
            $runAt = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^DOCKER run --name' })[0]
            Assert-Equal 0 @($lines[($runAt + 1)..($lines.Count - 1)] | Where-Object { $_ -match '^DOCKER rm -f ' }).Count `
                'removing the container after the throw would destroy the logs it points at'
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
