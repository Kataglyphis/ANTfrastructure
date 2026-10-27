#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A re-indented multi-line literal once changed the text this patch writes, so its own check refused it mid-chain; NOT covered: a real MSVC header.

# Harness-style (no BeforeAll) so the Linux mutation shards, which carry no Pester, can run it.
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Patches.psm1') -Force -DisableNameChecking
. (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-OnnxGenaiFromSource.ps1' -FunctionName 'Install-GenaiClangStlPatch')
$script:YvalsDefine = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
function script:Invoke-OnYvals([string]$Text, [int]$Times = 1) {
    Invoke-InTestDir { param($root)
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'include')
        $header = Join-Path $root 'include\yvals_core.h'
        [IO.File]::WriteAllText($header, $Text)
        $script:MsvcRoot = $root
        for ($n = 0; $n -lt $Times; $n++) { Install-GenaiClangStlPatch 6>$null }
        [IO.File]::ReadAllText($header)
    }
}
function script:Get-MsvcToolsRoot { $script:MsvcRoot }

Describe 'Install-GenaiClangStlPatch: the MSVC yvals_core.h clang no-op' {

    It 'wraps the define for clang with its lines unindented, once across two runs (mutation)' {
        $out = Invoke-OnYvals "// header`r`n$script:YvalsDefine`r`n// tail`r`n" -Times 2
        Assert-Match '#ifdef __clang__\r\n#define _EMIT_STL_ERROR\(NUMBER, MESSAGE\)\r\n#else\r\n#define _EMIT_STL_ERROR' $out 'the clang branch, unindented'
        Assert-Equal 1 ([regex]::Matches($out, '#ifdef __clang__')).Count 'applied once'
    }

    It 'still refuses a header whose define changed format' {
        Assert-Throws { Invoke-OnYvals "#define _EMIT_STL_ERROR(N, M) static_assert(false, M)`r`n" } -MessagePattern 'exact patch target did not match'
    }
}
