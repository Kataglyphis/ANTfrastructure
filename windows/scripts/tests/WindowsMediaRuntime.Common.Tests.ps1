#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# WindowsMediaRuntime.Common: the resolver and the staging copy that replace
# AccelerANTgine's local Get-RuntimeDependencyDirectories /
# Copy-RuntimeDependencies and its three call sites (ClangCL debug, profile and
# release each staged the same closure).
#
# What is pinned here is what a green build cannot show:
#   * an EMPTY result is an empty array, not $null. The local copy carried a
#     comment about exactly this: under Set-StrictMode -Version Latest a
#     pipeline-unrolled empty array lands $null, and $null.Count then throws
#     "The property 'Count' cannot be found on this object" and kills a Critical
#     step AFTER a fully successful compile.
#   * nothing throws when there is no payload - media features are opt-in.
#   * the recursive ONNX probe is pinned to the TARGET rid. A win-arm64 payload
#     staged next to an x64 exe is a wrong-machine DLL load at app start.

Describe 'WindowsMediaRuntime.Common' {

    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMediaRuntime.Common.psm1') -Force -DisableNameChecking

    $root = Join-Path ([IO.Path]::GetTempPath()) ("mediart-" + [guid]::NewGuid().ToString('N'))
    $gstA = Join-Path $root 'gst-a\bin'
    $gstB = Join-Path $root 'gst-b\bin'
    $onnxRoot = Join-Path $root 'nuget'
    $x64Native = Join-Path $onnxRoot 'Microsoft.ML.OnnxRuntime.1.2.3\runtimes\win-x64\native'
    $armNative = Join-Path $onnxRoot 'Microsoft.ML.OnnxRuntime.1.2.3\runtimes\win-arm64\native'
    foreach ($d in @($gstA, $gstB, $x64Native, $armNative)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'gstreamer-1.0-0.dll')
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'glib-2.0-0.dll')
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'notes.txt')
    'b' | Set-Content -LiteralPath (Join-Path $gstB 'gstreamer-1.0-0.dll')
    'x' | Set-Content -LiteralPath (Join-Path $x64Native 'onnxruntime.dll')
    'r' | Set-Content -LiteralPath (Join-Path $armNative 'onnxruntime.dll')

    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $ctx = New-BuildContext -Workspace $root -LogDir $logDir
    $ctx.SuppressConsoleOutput = $true

    It 'returns an EMPTY ARRAY, not $null, when nothing is installed' {
        # The $null.Count trap: the empty case is the one that kills a build step
        # after a successful compile, and it is the case nobody runs by hand.
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @((Join-Path $root 'nope')) -OnnxRoot '' `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-Equal 0 $r.Count
    }

    It 'lists an extra GStreamer root that exists' {
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot '' `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-True ($r -contains (Resolve-Path -LiteralPath $gstA).Path)
    }

    It 'skips a named root that does not exist instead of failing' {
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @((Join-Path $root 'absent'), $gstA) -OnnxRoot '' `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-Equal 1 $r.Count
    }

    It 'de-duplicates two spellings of one directory' {
        $twice = Join-Path (Join-Path $gstA '..') 'bin'
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA, $twice) -OnnxRoot '' `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-Equal 1 $r.Count
    }

    It 'finds a runtimes\<rid>\native tree under the ONNX root' {
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @() -OnnxRoot $onnxRoot `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-True ($r -contains (Resolve-Path -LiteralPath $x64Native).Path)
    }

    It 'does NOT pick up a foreign-rid payload from the same root' {
        # `runtimes\win-*` would look tidier and would stage an arm64
        # onnxruntime.dll next to an x64 exe, which fails as a DLL load at app
        # start with nothing in the message about the arch.
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @() -OnnxRoot $onnxRoot `
                -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-False ($r -contains (Resolve-Path -LiteralPath $armNative).Path)
    }

    It 'skips the NuGet layout when a version is missing, without throwing' {
        # The three versions are part of the paths Get-OnnxPackageLayout builds,
        # so a missing one can only resolve to a directory that cannot exist.
        $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot $onnxRoot `
                -OnnxVersion '1.2.3' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-True ($r.Count -ge 2)
    }

    It 'stages every DLL and reports the distinct count' {
        $target = Join-Path $root 'stage1\bin'
        $n = Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA) `
            -OnnxRoot '' -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion ''
        Assert-Equal 2 $n
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'gstreamer-1.0-0.dll'))
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'glib-2.0-0.dll'))
    }

    It 'copies DLLs only, never the rest of the directory' {
        $target = Join-Path $root 'stage2\bin'
        [void](Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA) `
                -OnnxRoot '' -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-False (Test-Path -LiteralPath (Join-Path $target 'notes.txt'))
    }

    It 'creates the target directory when it does not exist' {
        $target = Join-Path $root 'stage3\deep\bin'
        [void](Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA) `
                -OnnxRoot '' -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion '')
        Assert-True (Test-Path -LiteralPath $target)
    }

    It 'counts a name found in two directories once, and the LAST one wins' {
        # Resolver order is load order; a later directory overwriting an earlier
        # name is the documented precedence, not an accident of enumeration.
        $target = Join-Path $root 'stage4\bin'
        $n = Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA, $gstB) `
            -OnnxRoot '' -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion ''
        Assert-Equal 2 $n
        Assert-Equal 'b' (Get-Content -LiteralPath (Join-Path $target 'gstreamer-1.0-0.dll') -Raw).Trim()
    }

    It 'returns 0 and does not throw when there is no payload at all' {
        # Media features are opt-in; a configuration without them is a legitimate
        # build, and this step runs after a successful compile.
        $target = Join-Path $root 'stage5\bin'
        $n = Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target `
            -GStreamerRoot @((Join-Path $root 'nowhere')) -OnnxRoot '' `
            -OnnxVersion '' -OnnxGenAiVersion '' -OnnxDirectMlVersion ''
        Assert-Equal 0 $n
    }

    It 'exports exactly the two documented functions' {
        $m = Get-Module -Name 'WindowsMediaRuntime.Common'
        Assert-Equal 'Copy-MediaRuntimeBundle,Get-MediaRuntimeDirectory' (($m.ExportedFunctions.Keys | Sort-Object) -join ',')
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
