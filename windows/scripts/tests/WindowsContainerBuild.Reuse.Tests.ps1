#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Docker-free: the orchestration function is covered only by its parameter surface, the contract wrappers use.

Import-Module (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules') 'WindowsContainerBuild.Reuse.psm1') -Force -DisableNameChecking

function Assert-ReuseCommandParameters {
    param([string]$CommandName, [string[]]$Name, [switch]$Mandatory)
    $parameters = (Get-Command $CommandName).Parameters
    foreach ($parameterName in $Name) {
        Assert-True $parameters.ContainsKey($parameterName) "missing parameter -$parameterName"
        if ($Mandatory) {
            $required = @($parameters[$parameterName].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
            Assert-True ($required.Count -gt 0) "-$parameterName should be mandatory"
        }
    }
}

function New-TarDockerFixture {
    param([int]$Code, [string]$Reply = '')
    return [pscustomobject]@{ Calls = [System.Collections.Generic.List[object]]::new(); Code = $Code; Reply = $Reply }
}

function Get-ContainerInboundFixtureFiles {
    return [ordered]@{
        'README.md' = ''
        'src/build/keep.cpp' = ''
        'build/skip.cpp' = ''
        'BUILD-temp/skip.cpp' = ''
        'build_cache/skip.cpp' = ''
        'Logs/skip.txt' = ''
        'dist/skip.txt' = ''
        'assets/logo.svg' = ''
    }
}

Describe 'WindowsContainerBuild.Reuse: root-only inbound selection' {

    It 'keeps filesystem order and nested names while excluding root names and patterns case-insensitively' {
        Invoke-InTestDir -Files (Get-ContainerInboundFixtureFiles) -Body {
            param($root)
            $raw = @([System.IO.Directory]::GetFileSystemEntries($root) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
            $items = @(Get-ContainerInboundItems -RepoRoot $root -ExcludeEntries @('logs', 'dist') -ExcludePatterns @('build', 'build-*', 'build_*'))
            Assert-Equal 3 $items.Count
            foreach ($name in @('README.md', 'src', 'assets')) { Assert-True ($items -contains $name) "missing root item $name" }
            foreach ($name in @('build', 'BUILD-temp', 'build_cache', 'Logs', 'dist')) { Assert-False ($items -contains $name) "excluded root item $name survived" }
            Assert-True (Test-Path -LiteralPath (Join-Path $root 'src/build/keep.cpp')) 'a nested build path belongs to the selected src item'
            $positions = @($items | ForEach-Object { [array]::IndexOf($raw, $_) })
            Assert-Equal ($positions -join ',') ((@($positions | Sort-Object)) -join ',')
        }
    }

    It 'fails before transfer when every root entry is excluded' {
        Invoke-InTestDir -Files ([ordered]@{ 'build/skip.cpp' = '' }) -Body {
            param($root)
            Assert-Throws { Get-ContainerInboundItems -RepoRoot $root -ExcludeEntries @('build') } -MessagePattern 'No inbound root entries remain'
        }
    }

    It 'rejects a selector mutant that would keep the excluded root and drop source' {
        Invoke-InTestDir -Files ([ordered]@{ 'src/keep.cpp' = ''; 'build/skip.cpp' = '' }) -Body {
            param($root)
            Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsContainerBuild.Reuse.psm1' `
                -FunctionName Get-ContainerInboundItems -Find 'if ($name -in $ExcludeEntries)' `
                -Replace 'if ($name -notin $ExcludeEntries)' -Expected 'source root must survive' -IncludeControl `
                -Body { param($path)
                    $items = @(Get-MutContainerInboundItems -RepoRoot $path -ExcludeEntries @('build'))
                    Assert-True ($items -contains 'src') 'source root must survive'
                    Assert-False ($items -contains 'build') 'build root must be excluded'
                } -BodyArgumentList @($root)
        }
    }

    It 'rejects ambiguous runner arguments before resolving Docker' {
        Invoke-InTestDir -Body {
            param($root)
            $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'build/Invoke-RepoContainerBuild.ps1'
            Assert-Throws { & $runner -RepoRoot $root -ContainerName fixture -BuildCommand @('pwsh') -InboundItems @('src') -ExcludeRootEntries @('build') -WhatIf } -MessagePattern 'Choose -InboundItems or root exclusions'
        }
    }

    It 'wires the shared selector into the runner for root exclusions' {
        $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'build/Invoke-RepoContainerBuild.ps1'
        $source = [System.IO.File]::ReadAllText($runner)
        Assert-Match '\$InboundItems = @\(Get-ContainerInboundItems -RepoRoot \$RepoRoot' $source
        Assert-Match 'InboundItems\s*=\s*\$InboundItems' $source
    }

    It 'reports only selected root names under runner WhatIf without contacting Docker' {
        Invoke-InTestDir -Files (Get-ContainerInboundFixtureFiles) -Body {
            param($root)
            $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'build/Invoke-RepoContainerBuild.ps1'
            $pwshExe = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
            $records = @(Invoke-WithEnv -Vars @{ ProgramFiles = $root } -Body {
                    & $runner -RepoRoot $root -ContainerName fixture -BuildCommand @('pwsh', '-v') `
                        -Image fixture-image -DockerExe $pwshExe -ExcludeRootEntries @('build', 'logs', 'dist') `
                        -ExcludeRootPatterns @('build-*', 'build_*') -WhatIf -Verbose 4>&1 6>&1
                })
            $selection = @($records | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like 'Inbound root entries:*' })
            Assert-Equal 1 $selection.Count
            $items = @($selection[0].Message.Substring('Inbound root entries: '.Length) -split '\|')
            Assert-Equal 3 $items.Count
            Assert-True ($items -contains 'README.md')
            Assert-True ($items -contains 'src')
            Assert-True ($items -contains 'assets')
            Assert-False (@($items | Where-Object { $_ -match 'What if|build|logs|dist' }).Count -gt 0) 'WhatIf and excluded names must not enter tar items'
        }
    }
}

Describe 'WindowsContainerBuild.Reuse: Get-ContainerEnvArgs' {

    It 'returns an empty array for an empty dictionary' {
        Assert-Equal 0 (@(Get-ContainerEnvArgs -Environment @{}).Count)
    }

    It 'emits -e NAME=VALUE pairs' {
        $a = @(Get-ContainerEnvArgs -Environment @{ FOO = 'bar' })
        Assert-Equal 2 $a.Count
        Assert-Equal '-e' $a[0]
        Assert-Equal 'FOO=bar' $a[1]
    }

    It 'sorts unordered hashtable keys so the command line is deterministic' {
        $a = @(Get-ContainerEnvArgs -Environment @{ ZED = '1'; ALPHA = '2'; MID = '3' })
        Assert-Equal 'ALPHA=2' $a[1]
        Assert-Equal 'MID=3' $a[3]
        Assert-Equal 'ZED=1' $a[5]
    }

    It 'preserves insertion order for an ordered dictionary' {
        $a = @(Get-ContainerEnvArgs -Environment ([ordered]@{ ZED = '1'; ALPHA = '2' }))
        Assert-Equal 'ZED=1' $a[1]
        Assert-Equal 'ALPHA=2' $a[3]
    }
}

Describe 'WindowsContainerBuild.Reuse: Get-SccacheContainerEnv' {

    It 'defines the four sccache variables' {
        $e = Get-SccacheContainerEnv
        Assert-Equal 'C:\sccache-local' $e['SCCACHE_DIR']
        Assert-Equal '20G' $e['SCCACHE_CACHE_SIZE']
        Assert-Equal 'C:\sccache-error.log' $e['SCCACHE_ERROR_LOG']
        Assert-Equal 'warn' $e['SCCACHE_LOG']
    }

    It 'keeps the error log outside the cache directory (server opens it first)' {
        $e = Get-SccacheContainerEnv -CacheDir 'C:\cache' -ErrorLogPath 'C:\err.log'
        Assert-False ($e['SCCACHE_ERROR_LOG'].StartsWith($e['SCCACHE_DIR']))
    }

    It 'accepts caller overrides' {
        $e = Get-SccacheContainerEnv -CacheSize '5G' -LogLevel 'trace'
        Assert-Equal '5G' $e['SCCACHE_CACHE_SIZE']
        Assert-Equal 'trace' $e['SCCACHE_LOG']
    }

    It 'is mergeable with caller-supplied entries' {
        $e = Get-SccacheContainerEnv
        $e['KATAGLYPHIS_KEEP_BUILD_ROOT'] = '1'
        $a = @(Get-ContainerEnvArgs -Environment $e)
        Assert-True ($a -contains 'KATAGLYPHIS_KEEP_BUILD_ROOT=1')
        Assert-True ($a -contains 'SCCACHE_DIR=C:\sccache-local')
    }
}

# The image stopped carrying the build host's endpoint (2026-09-23); the host forwards it at run time.
Describe 'WindowsContainerBuild.Reuse: Add-HostSccacheRemoteEnv' {

    $reuse = @(Get-Module WindowsContainerBuild.Reuse)[0]
    $merge = { param($e) & $reuse { param($x) Add-HostSccacheRemoteEnv -CacheEnv $x 6>$null } $e }
    $hostTier = @{ SCCACHE_WEBDAV_ENDPOINT = 'http://10.9.8.7:5000'; SCCACHE_MULTILEVEL_CHAIN = 'disk,webdav' }

    It 'adds this host''s endpoint and chain when the caller set neither' {
        Invoke-WithEnv $hostTier {
            $r = & $merge (Get-SccacheContainerEnv)
            Assert-Equal 'http://10.9.8.7:5000' $r['SCCACHE_WEBDAV_ENDPOINT']
            Assert-Equal 'disk,webdav' $r['SCCACHE_MULTILEVEL_CHAIN']
            Assert-Equal 'C:\sccache-local' $r['SCCACHE_DIR'] 'the caller''s entries stay'
        }
    }

    It 'a key the caller set wins, an empty one included (the opt-out)' {
        Invoke-WithEnv $hostTier {
            $r = & $merge ([ordered]@{ SCCACHE_WEBDAV_ENDPOINT = '' })
            Assert-Equal '' $r['SCCACHE_WEBDAV_ENDPOINT']
            Assert-Equal 'disk,webdav' $r['SCCACHE_MULTILEVEL_CHAIN']
        }
    }

    It 'adds nothing on a host without a remote tier (a CI runner)' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = $null; SCCACHE_MULTILEVEL_CHAIN = $null } {
            $r = & $merge (Get-SccacheContainerEnv)
            Assert-False ($r.Contains('SCCACHE_WEBDAV_ENDPOINT')) 'nothing to forward'
            Assert-False ($r.Contains('SCCACHE_MULTILEVEL_CHAIN'))
        }
    }

    It 'never modifies the caller''s dictionary, and keeps its kind (a hashtable still sorts)' {
        Invoke-WithEnv $hostTier {
            $mine = @{ ZED = '1' }
            $r = & $merge $mine
            Assert-Equal 1 $mine.Count 'the caller''s hashtable was modified'
            Assert-True ($r -is [hashtable]) 'a hashtable came back as another kind'
            Assert-Equal 'SCCACHE_MULTILEVEL_CHAIN=disk,webdav' @(Get-ContainerEnvArgs -Environment $r)[1]
        }
    }

    It 'Invoke-ContainerBuild sends its -CacheEnv through it (both transports read $cacheArgs)' {
        $src = [IO.File]::ReadAllText($reuse.Path)
        Assert-Match '\$cacheArgs = Get-ContainerEnvArgs -Environment \(Add-HostSccacheRemoteEnv -CacheEnv \$CacheEnv\)' $src
        Assert-Equal 1 ([regex]::Matches($src, '(?m)^\s*\$cacheArgs\s*=').Count) 'a second $cacheArgs assignment would bypass the forward'
    }
}

Describe 'WindowsContainerBuild.Reuse: Resolve-ContainerBuildCommand' {

    It 'passes the workspace path to a scriptblock' {
        $sb = { param([string]$Ws) @('pwsh', '-File', "$Ws\build.ps1") }
        $a = Resolve-ContainerBuildCommand -BuildCommand $sb -WorkspacePath 'C:\ws'
        Assert-Equal 'C:\ws\build.ps1' $a[2]
    }

    It 'passes a string array through unchanged' {
        $a = Resolve-ContainerBuildCommand -BuildCommand @('a', 'b') -WorkspacePath 'C:\ws'
        Assert-Equal 2 $a.Count
        Assert-Equal 'b' $a[1]
    }

    It 'drops nulls and stringifies every token' {
        $a = Resolve-ContainerBuildCommand -BuildCommand @('a', $null, 7) -WorkspacePath 'C:\ws'
        Assert-Equal 2 $a.Count
        Assert-Equal '7' $a[1]
    }

    It 'throws when the command is empty' {
        Assert-Throws { Resolve-ContainerBuildCommand -BuildCommand @() -WorkspacePath 'C:\ws' }
    }
}

Describe 'WindowsContainerBuild.Reuse: Invoke-ContainerBuild contract' {

    It 'exports the orchestration entry point' {
        Assert-NotNull (Get-Command Invoke-ContainerBuild -ErrorAction SilentlyContinue)
    }

    It 'exposes every parameter a project wrapper depends on' {
        Assert-ReuseCommandParameters -CommandName Invoke-ContainerBuild -Name @('DockerExe', 'Image', 'ContainerName', 'RepoRoot', 'BuildCommand',
                'WorkspacePath', 'IncrementalDirs', 'IncrementalExclude', 'OutputDirs', 'VerifyDirs',
                'InboundExclude', 'InboundItems', 'OutboundExclude', 'KeepDirs', 'CacheEnv', 'IsolationArgs',
                'EntrypointPath', 'ProbeFile', 'WaitTimeoutMinutes', 'UseBindMount', 'FreshContainer')
    }

    It 'defaults the workspace to C:\ws (shared by both transports so CMake caches stay valid)' {
        $ws = (Get-Command Invoke-ContainerBuild).Parameters['WorkspacePath']
        Assert-Equal 'System.String' $ws.ParameterType.FullName
        Assert-Match 'C:\\ws' ((Get-Command Invoke-ContainerBuild).Definition -split "`n" |
            Where-Object { $_ -match '\$WorkspacePath\s*=' } | Select-Object -First 1)
    }

    It 'streams the inbound item list through to the transfer' {
        Assert-Match '-Items \$InboundItems' ((Get-Command Invoke-ContainerBuild).Definition -split "`n" |
            Where-Object { $_ -match '-Items \$InboundItems' } | Select-Object -First 1)
    }

    It 'requires the parameters that have no sensible default' {
        Assert-ReuseCommandParameters -CommandName Invoke-ContainerBuild -Name @('DockerExe', 'Image', 'ContainerName', 'RepoRoot', 'BuildCommand') -Mandatory
    }
}

Describe 'WindowsContainerBuild.Reuse: tar-pipe build result' {
    $reuse = @(Get-Module WindowsContainerBuild.Reuse)[0]

    It 'returns the docker exec exit status after the temporary environment is restored' {
        $state = New-TarDockerFixture -Code 17
        Invoke-WithTestNativeCommand -Name WbtTarDockerFake -FixtureState $state -Implementation {
            param($fixture, $commandArgs)
        } -Body {
            param($fixture)
            $status = & $reuse {
                Invoke-TarPipeBuildCommand -DockerExe WbtTarDockerFake -Container build-box `
                    -WorkspacePath 'C:\ws' -EntrypointPath 'C:\entrypoint.cmd' -BuildArgs @('pwsh', '-File', 'build.ps1')
            }
            Assert-Equal 17 $status 'docker exec status must survive the environment callback'
            Assert-Equal 'exec' $fixture.Calls[0][0]
            Assert-True ($fixture.Calls[0] -contains 'build-box') 'the build runs in the reusable container'
        }
    }

    It 'distinguishes a compile failure from a vanished or stopped container' {
        foreach ($case in @(
                @{ Reply = 'running'; Code = 0; Pattern = 'Container build failed \(exit 17\)' },
                @{ Reply = 'Error: No such object: build-box'; Code = 1; Pattern = 'disappeared while the build was running' },
                @{ Reply = 'exited'; Code = 0; Pattern = 'stopped \(state .exited.\)' }
            )) {
            $state = New-TarDockerFixture -Code $case.Code -Reply $case.Reply
            Invoke-WithTestNativeCommand -Name WbtTarDockerFake -FixtureState $state -Implementation {
                param($fixture, $commandArgs)
                $fixture.Reply
            } -Body {
                param($fixture)
                Assert-Throws { & $reuse { Assert-TarPipeBuildSucceeded -DockerExe WbtTarDockerFake -Container build-box -BuildExit 17 } } `
                    -MessagePattern $case.Pattern
            }
        }
    }
}

Describe 'WindowsContainerBuild.Reuse: Wait-ContainerExit contract' {

    # Behaviour is in Modules.Orchestrators.Tests.ps1; this pins the exported surface a consumer breaks on.
    It 'is exported (OxidANT hand-rolled this loop for want of it)' {
        Assert-NotNull (Get-Command Wait-ContainerExit -ErrorAction SilentlyContinue)
    }

    It 'exposes the parameters a caller waits on a container with' {
        Assert-ReuseCommandParameters -CommandName Wait-ContainerExit -Name @('DockerExe', 'Name', 'PollSeconds', 'TimeoutMinutes', 'Label')
    }

    It 'requires the container it is asked to wait for' {
        Assert-ReuseCommandParameters -CommandName Wait-ContainerExit -Name @('DockerExe', 'Name') -Mandatory
    }

    It 'bounds the wait - a lane must not be hangable by a container that never stops' {
        $range = @((Get-Command Wait-ContainerExit).Parameters['TimeoutMinutes'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        Assert-Equal 1 $range.Count '-TimeoutMinutes must carry a ValidateRange'
        Assert-True ($range[0].MaxRange -le 10080) 'an unbounded timeout is the bug this replaced'
    }

    It 'keeps the inspect-classifying helper internal' {
        # Exporting it would make the read/gone/unreachable classification a consumer contract.
        Assert-Null (Get-Command Get-ContainerInspectField -ErrorAction SilentlyContinue)
    }
}

Describe 'WindowsContainerBuild.Reuse: Resolve-NerdctlExe' {

    It 'takes -Override, NERDCTL_EXE, PATH, then Rancher Desktop''s copy, and skips Stevedore''s Windows nerdctl' {
        Invoke-InTestDir { param($d)
            $exe = @{ stevedore = "$d\pf\Stevedore\bin\nerdctl.exe"; rancher = "$d\pf\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
                other = "$d\other\nerdctl.exe"; env = "$d\env\nerdctl.exe"; override = "$d\override\nerdctl.exe" }
            foreach ($path in $exe.Values) { $null = New-Item -ItemType File -Force -Path $path }
            $resolve = { param($Path, [string]$Override = '') Invoke-WithEnv @{ ProgramFiles = "$d\pf"; PATH = $Path; NERDCTL_EXE = $null } { Resolve-NerdctlExe -Override $Override } }
            Assert-Equal $exe.rancher (& $resolve "$d\pf\Stevedore\bin") 'Stevedore''s copy drives the Windows containerd'
            Assert-Equal $exe.other (& $resolve "$d\pf\Stevedore\bin;$d\other")
            Assert-Equal $exe.override (& $resolve "$d\other" $exe.override)
            Invoke-WithEnv @{ ProgramFiles = "$d\pf"; PATH = "$d\other"; NERDCTL_EXE = $exe.env } { Assert-Equal $exe.env (Resolve-NerdctlExe) }
        }
    }

    It 'throws without a nerdctl, and returns $null with -AllowMissing' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ ProgramFiles = $d; PATH = $d; NERDCTL_EXE = $null } {
                Assert-Throws { Resolve-NerdctlExe } -MessagePattern 'nerdctl not found'
                Assert-Null (Resolve-NerdctlExe -AllowMissing)
            }
        }
    }
}
