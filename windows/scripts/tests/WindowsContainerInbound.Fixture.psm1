#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# This checks wrapper wiring; it does not stream files or start a container.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Assert-ContainerRootSelection {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$ExcludeEntries,
        [string[]]$ExcludePatterns = @()
    )

    $ast = Get-TestScriptAst -ScriptPath $ScriptPath
    $calls = @($ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.CommandElements.Count -gt 0 -and $node.CommandElements[0].Extent.Text -eq '$runner'
            }, $true))
    Assert-Equal 1 $calls.Count 'one shared container runner call is required'
    $bound = Get-TestCommandArguments -Command $calls[0] -AsAst
    Assert-True ($bound.ContainsKey('ExcludeRootEntries')) 'the runner needs root exclusions'
    Assert-False ($bound.ContainsKey('InboundItems')) 'the wrapper must not select inbound items privately'
    $actualEntries = @($bound['ExcludeRootEntries'].SafeGetValue())
    Assert-Equal ($ExcludeEntries -join '|') ($actualEntries -join '|') 'root exclusions must keep the consumer policy'
    if ($ExcludePatterns.Count -gt 0) { Assert-True ($bound.ContainsKey('ExcludeRootPatterns')) 'the runner needs root patterns' }
    $actualPatterns = if ($bound.ContainsKey('ExcludeRootPatterns')) { @($bound['ExcludeRootPatterns'].SafeGetValue()) } else { @() }
    Assert-Equal ($ExcludePatterns -join '|') ($actualPatterns -join '|') 'root patterns must keep the consumer policy'
    $privateEnumerators = @($ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member.Extent.Text -eq 'GetFileSystemEntries'
            }, $true))
    Assert-Equal 0 $privateEnumerators.Count 'root enumeration belongs to the shared runner'
}

Export-ModuleMember -Function Assert-ContainerRootSelection
