#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Tests for the pure, docker-free helpers of WindowsContainerBuild.Reuse.psm1.
# Nothing here starts a container: the orchestration function is covered only
# by its parameter surface, which is the contract project wrappers depend on.

Import-Module (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules') 'WindowsContainerBuild.Reuse.psm1') -Force -DisableNameChecking

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
        $p = (Get-Command Invoke-ContainerBuild).Parameters
        foreach ($name in @('DockerExe', 'Image', 'ContainerName', 'RepoRoot', 'BuildCommand',
                'WorkspacePath', 'IncrementalDirs', 'IncrementalExclude', 'OutputDirs', 'VerifyDirs',
                'InboundExclude', 'OutboundExclude', 'KeepDirs', 'CacheEnv', 'IsolationArgs',
                'EntrypointPath', 'ProbeFile', 'UseBindMount', 'FreshContainer')) {
            Assert-True $p.ContainsKey($name) "missing parameter -$name"
        }
    }

    It 'defaults the workspace to C:\ws (shared by both transports so CMake caches stay valid)' {
        $ws = (Get-Command Invoke-ContainerBuild).Parameters['WorkspacePath']
        Assert-Equal 'System.String' $ws.ParameterType.FullName
        Assert-Match 'C:\\ws' ((Get-Command Invoke-ContainerBuild).Definition -split "`n" |
            Where-Object { $_ -match '\$WorkspacePath\s*=' } | Select-Object -First 1)
    }

    It 'requires the parameters that have no sensible default' {
        $p = (Get-Command Invoke-ContainerBuild).Parameters
        foreach ($name in @('DockerExe', 'Image', 'ContainerName', 'RepoRoot', 'BuildCommand')) {
            $mandatory = @($p[$name].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
            Assert-True ($mandatory.Count -gt 0) "-$name should be mandatory"
        }
    }
}
