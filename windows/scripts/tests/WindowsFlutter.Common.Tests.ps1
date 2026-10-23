#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Exercises patch policy and copy argv through a fake transport; real junctions and robocopy I/O remain container coverage.

$flutterModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsFlutter.Common.psm1'
$flutterSource = [IO.File]::ReadAllText($flutterModulePath)
Import-Module $flutterModulePath

function Invoke-FlutterPatchFixture {
    param([AllowEmptyString()][string]$Source, [scriptblock]$Body, [switch]$ReadOnly)
    Invoke-InTestDir { param($dir)
        $plugin = Join-Path $dir 'windows\flutter\ephemeral\.plugin_symlinks\permission_handler_windows\windows\permission_handler_windows_plugin.cpp'
        $null = New-Item -ItemType Directory -Path (Split-Path $plugin -Parent) -Force
        [IO.File]::WriteAllText($plugin, $Source)
        $context = [pscustomobject]@{ LogWriter = [IO.StringWriter]::new(); SuppressConsoleOutput = $true }
        try {
            if ($ReadOnly) { Invoke-FlutterReadOnlyPatch -Workspace $dir -Plugin $plugin -Context $context }
            & $Body $dir $plugin $context
        } finally { $context.LogWriter.Dispose() }
    }
}

function Invoke-FlutterReadOnlyPatch {
    param([string]$Workspace, [string]$Plugin, [object]$Context)
    $Context.LogWriter.GetStringBuilder().Clear() | Out-Null
    $readHandle = [IO.File]::Open($Plugin, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Patch-PermissionHandlerWindows -Context $Context -WorkspaceDir $Workspace }
    finally { $readHandle.Dispose() }
}

function Invoke-FlutterSyncFixture {
    param([int[]]$Codes, [scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = New-TestCallState -Properties @{
        Warnings = [Collections.Generic.List[string]]::new()
        Codes = [Collections.Generic.Queue[int]]::new([int[]]$Codes)
    }
    $prelude = @'
$script:fixtureState = $State
function Write-BuildLog { param($Context, $Message) }
function Write-BuildLogWarning { param($Context, $Message) $script:fixtureState.Warnings.Add($Message) }
function robocopy.exe {
    $script:fixtureState.Calls.Add([string[]]$args)
    $global:LASTEXITCODE = $script:fixtureState.Codes.Dequeue()
}
'@
    Invoke-WithFunctionModule -Text $flutterSource `
        -FunctionName @('Sync-FlutterArtifactTree', 'Sync-FastLocalArtifactsToHost') `
        -Prelude $prelude -FixtureState $state -Body $Body -Find $Find -Replace $Replace
}

function Invoke-FlutterFullSyncCase {
    param([int[]]$Codes, [scriptblock]$Verify, [string]$Find = '', [string]$Replace = '')
    Invoke-FlutterSyncFixture $Codes {
        param($state)
        Invoke-InTestDir { param($dir)
            $build = Join-Path $dir 'host build'
            $rust = Join-Path $dir 'host rust'
            Sync-MutFastLocalArtifactsToHost -Context ([pscustomobject]@{}) -BuildRoot 'source build' `
                -OriginalBuildRoot $build -CargoTargetDir 'source rust' -HostRustTargetDir $rust
            & $Verify $state $build $rust
        }
    } -Find $Find -Replace $Replace
}

Describe 'Flutter plugin patch policy' {
    It 'patches both targets once, keeps UTF-8 without BOM, and avoids a second write' {
        Invoke-FlutterPatchFixture "// naïve`nresult->Success(requestResults);`nfor (int i=0;i<permissions.size();i++)" {
            param($dir, $plugin, $context)
            Update-PermissionHandlerWindows -Context $context -WorkspaceDir $dir
            Assert-Equal "// naïve`nresult->Success(flutter::EncodableValue(requestResults));`nfor (size_t i=0;i<permissions.size();i++)" ([IO.File]::ReadAllText($plugin))
            Assert-False ([IO.File]::ReadAllBytes($plugin)[0] -eq 0xEF)
            Invoke-FlutterReadOnlyPatch -Workspace $dir -Plugin $plugin -Context $context
            Assert-Match 'Success already patched' $context.LogWriter.ToString()
            Assert-Match 'loop already patched' $context.LogWriter.ToString()
            Assert-False ($context.LogWriter.ToString().Contains('WARNING:'))
        }
    }

    It 'keeps the optional missing loop silent and warns only for the missing Success target' {
        Invoke-FlutterPatchFixture 'result->Success(flutter::EncodableValue(requestResults));' -ReadOnly -Body {
            param($dir, $plugin, $context)
            Assert-False ($context.LogWriter.ToString().Contains('WARNING:'))
            [IO.File]::WriteAllText($plugin, 'unrelated plugin text')
            Invoke-FlutterReadOnlyPatch -Workspace $dir -Plugin $plugin -Context $context
            Assert-Equal 1 ([regex]::Matches($context.LogWriter.ToString(), 'WARNING:').Count)
            Assert-Match 'Patch target line not found' $context.LogWriter.ToString()
            Assert-Equal 'unrelated plugin text' ([IO.File]::ReadAllText($plugin))
        }
    }

    It 'warns without rewriting an empty upstream plugin' {
        Invoke-FlutterPatchFixture '' -ReadOnly -Body {
            param($dir, $plugin, $context)
            Assert-Match 'Patch target line not found' $context.LogWriter.ToString()
        }
    }

    It 'keeps an absent plugin untouched' {
        Invoke-InTestDir { param($dir)
            Update-PermissionHandlerWindows -Context ([pscustomobject]@{}) -WorkspaceDir $dir
            Assert-Equal 0 (@(Get-ChildItem -LiteralPath $dir -Force).Count)
        }
    }
}

Describe 'Flutter artifact sync lifecycle' {
    It 'keeps distinct CMake and Rust exclusions and resets successful robocopy exit codes' {
        Invoke-FlutterFullSyncCase @(1, 7) {
            param($state, $build, $rust)
            Assert-Equal 0 $global:LASTEXITCODE
            Assert-True (Test-Path -LiteralPath $build -PathType Container)
            Assert-True (Test-Path -LiteralPath $rust -PathType Container)
            Assert-Equal 2 $state.Calls.Count
            Assert-Equal 0 $state.Warnings.Count
            Assert-Equal ('source build|' + $build + '|/E|/MT:16|/R:1|/W:1|/FFT|/NOOFFLOAD|/XF|*.obj|*.tlog|*.lastbuildstate|*.idb|*.ilk|*.pdb|.ninja*|CMakeCache.txt|/XD|*.dir|CMakeFiles|x64_x64-ClangCL*|/NFL|/NDL|/NJH|/NJS|/nc|/ns|/np|/LOG:nul') ($state.Calls[0] -join '|')
            Assert-Equal ('source rust|' + $rust + '|/E|/MT:16|/R:1|/W:1|/FFT|/NOOFFLOAD|/XF|*.rlib|*.rmeta|*.d|*.o|/XD|.fingerprint|build|deps|incremental|/NFL|/NDL|/NJH|/NJS|/nc|/ns|/np|/LOG:nul') ($state.Calls[1] -join '|')
        }
    }

    It 'reports failures from each copy while still attempting Rust and clearing the exit code' {
        Invoke-FlutterFullSyncCase @(8, 16) {
            param($state)
            Assert-Equal 2 $state.Calls.Count
            Assert-Equal 2 $state.Warnings.Count
            Assert-Match 'build artifacts.*exit code 8' $state.Warnings[0]
            Assert-Match 'Rust artifacts.*exit code 16' $state.Warnings[1]
            Assert-Equal 0 $global:LASTEXITCODE
        }
    }

    It 'does not sync Rust unless both Rust paths are supplied' {
        Invoke-FlutterSyncFixture @(0, 0, 0) {
            param($state)
            Invoke-InTestDir { param($dir)
                $options = @{ Context = [pscustomobject]@{}; BuildRoot = 'build'; OriginalBuildRoot = (Join-Path $dir 'out') }
                Sync-MutFastLocalArtifactsToHost @options -CargoTargetDir 'cargo'
                Sync-MutFastLocalArtifactsToHost @options -HostRustTargetDir 'rust'
                Sync-MutFastLocalArtifactsToHost @options
                Assert-Equal 3 $state.Calls.Count
                Assert-Equal 0 $state.Codes.Count
            }
        }
    }
}

Describe 'Flutter refactor mutation guards' {
    It 'rejects suppressing the robocopy exit 8 warning' {
        Assert-Throws {
            Invoke-FlutterFullSyncCase @(8, 16) -Find '$copyExit -ge 8' -Replace '$copyExit -gt 8' -Verify {
                param($state)
                Assert-Equal 2 $state.Warnings.Count
            }
        } -MessagePattern 'expected \[2\] but got \[1\]'
    }

    It 'rejects disabling the plugin patch replacement' {
        Invoke-WithFunctionModule -Text $flutterSource `
            -FunctionName @('Edit-FlutterPluginText', 'Update-PermissionHandlerWindows') `
            -Find 'return $Content -replace $Patch.Target, $Patch.Replacement' -Replace 'return $Content' `
            -Prelude 'function Write-BuildLog { param($Context, $Message) }' -Body {
                Assert-Throws {
                    Invoke-FlutterPatchFixture 'result->Success(requestResults);' {
                        param($dir, $plugin, $context)
                        Update-MutPermissionHandlerWindows -Context $context -WorkspaceDir $dir
                        Assert-Equal 'result->Success(flutter::EncodableValue(requestResults));' ([IO.File]::ReadAllText($plugin))
                    }
                } -MessagePattern 'Assert-Equal: expected'
            }
    }
}
