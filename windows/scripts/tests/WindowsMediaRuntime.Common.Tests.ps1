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
#   * ORT comes from the chain install only (owner rule 2026-09-23): no NuGet walk, no foreign DLL, chain staged last.
# NOT covered: a real chain install, ORT linked statically into another DLL, bytes the census would call foreign.

Describe 'WindowsMediaRuntime.Common' {

    # New-BuildContext is called here directly. Unforced: a -Force reload after another suite's breaks its guarded Shared import.
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsBuild.Common.psm1') -DisableNameChecking
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMediaRuntime.Common.psm1') -Force -DisableNameChecking

    $root = Join-Path ([IO.Path]::GetTempPath()) ("mediart-" + [guid]::NewGuid().ToString('N'))
    $gstA = Join-Path $root 'gst-a\bin'
    $gstB = Join-Path $root 'gst-b\bin'
    $gstForeign = Join-Path $root 'gst-foreign\bin'
    foreach ($d in @($gstA, $gstB, $gstForeign)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'gstreamer-1.0-0.dll')
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'glib-2.0-0.dll')
    'a' | Set-Content -LiteralPath (Join-Path $gstA 'notes.txt')
    'b' | Set-Content -LiteralPath (Join-Path $gstB 'gstreamer-1.0-0.dll')
    'f' | Set-Content -LiteralPath (Join-Path $gstForeign 'gstreamer-1.0-0.dll')

    # The chain ORT and GenAI installs in the image's layout, a NuGet package planted inside the chain root, a bundled ORT.
    $nugetNative = 'onnxruntime-source\packages\Microsoft.ML.OnnxRuntime.1.2.3\runtimes\win-x64\native'
    $nugetGenAi = 'Microsoft.ML.OnnxRuntimeGenAI.DirectML.0.14.1'
    $peFixture = [ordered]@{
        'gst-foreign\bin\onnxruntime.dll'                         = 'bundled'
        'gst-genai\bin\onnxruntime-genai.dll'                     = 'bundled-genai'
        "$nugetGenAi\runtimes\win-x64\native\onnxruntime-genai.dll" = 'nuget-genai' # GenAI's nupkg holds no ORT file
        'onnxruntime-source\bin\onnxruntime.dll'                  = 'chain-ort'
        'onnxruntime-source\bin\onnxruntime_providers_shared.dll' = 'chain-shared'
        'onnxruntime-source\bin\DirectML.dll'                     = 'dml-ort'
        'onnxruntime-source\lib\onnxruntime_providers_cuda.dll'   = 'chain-cuda'
        "$nugetNative\onnxruntime.dll"                            = 'nuget'
        'onnxruntime-genai-source\lib\onnxruntime-genai.dll'      = 'chain-genai'
        'onnxruntime-genai-source\lib\DirectML.dll'               = 'dml-genai'
    }
    foreach ($rel in $peFixture.Keys) { New-TestPeFile (Join-Path $root $rel) -Tag $peFixture[$rel] }
    [IO.File]::WriteAllText((Join-Path $root 'onnxruntime-source\lib\onnxruntime.lib'), 'lib')
    [IO.File]::WriteAllText((Join-Path $root "$nugetGenAi\$nugetGenAi.nupkg"), 'nupkg')
    $ortRoot, $genRoot = @('onnxruntime-source', 'onnxruntime-genai-source') | ForEach-Object { Join-Path $root $_ }
    $plantedNative, $ortBin, $ortLib, $genLib = @($nugetNative, 'onnxruntime-source\bin', 'onnxruntime-source\lib',
        'onnxruntime-genai-source\lib') | ForEach-Object { (Resolve-Path -LiteralPath (Join-Path $root $_)).Path }

    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $ctx = New-BuildContext -Workspace $root -LogDir $logDir
    $ctx.SuppressConsoleOutput = $true

    Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = $null; ONNX_ROOT = $null; ONNX_GENAI_ROOT = $null } {

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

        It 'resolves the chain ORT: ONNX_ROOT\lib then \bin, after GStreamer (mutation)' {
            $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot $ortRoot)
            Assert-Equal ((@((Resolve-Path -LiteralPath $gstA).Path, $ortLib, $ortBin)) -join '|') ($r -join '|')
        }

        It 'lists the chain GenAI before the chain ORT, so ORT wins a name collision (mutation)' {
            $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @() -OnnxRoot $ortRoot -OnnxGenAiRoot $genRoot)
            Assert-Equal (@($genLib, $ortLib, $ortBin) -join '|') ($r -join '|')
        }

        It 'never walks a NuGet runtimes\<rid>\native tree, even one inside the chain root (mutation)' {
            $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @() -OnnxRoot $ortRoot)
            Assert-False ($r -contains (Resolve-Path -LiteralPath $plantedNative).Path) ($r -join ', ')
            Assert-Equal 2 $r.Count
        }

        It 'refuses an ONNX_ROOT that is not the chain install, before listing anything (mutation)' {
            # Get-OnnxChainLayout owns the rules (NuGet tree, release zip, wrong machine, GenAI with its own ORT); its suite pins them.
            Assert-Throws { Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot (Join-Path $ortRoot 'packages') } `
                -MessagePattern 'not the chain install.*chain build only' 'a NuGet root must not stage anything'
            Assert-Throws { Get-MediaRuntimeDirectory -GStreamerRoot @() -OnnxRoot '' -OnnxGenAiRoot $genRoot } `
                -MessagePattern 'ONNX_ROOT is not set' 'GenAI without the chain ORT'
            # A NuGet GenAI root used to pass and then stage no GenAI at all, silently.
            $target = Join-Path $root 'stage-nuget-genai\bin'
            Assert-Throws { Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -OnnxRoot $ortRoot -OnnxGenAiRoot (Join-Path $root $nugetGenAi) } `
                -MessagePattern 'is a NuGet package.*chain build only' 'a NuGet GenAI root'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $target -Force).Count 'nothing staged before the refusal'
        }

        It 'refuses an ORT DLL bundled in a GStreamer directory (mutation)' {
            Assert-Throws { Get-MediaRuntimeDirectory -GStreamerRoot @($gstForeign) -OnnxRoot $ortRoot } `
                -MessagePattern 'outside the chain install.*onnxruntime\.dll'
            Assert-Throws { Get-MediaRuntimeDirectory -GStreamerRoot @($gstForeign) -OnnxRoot '' } `
                -MessagePattern 'outside the chain install' 'no ONNX_ROOT does not make a bundled ORT acceptable'
            Assert-Throws { Get-MediaRuntimeDirectory -GStreamerRoot @((Join-Path $root 'gst-genai\bin')) -OnnxRoot $ortRoot -OnnxGenAiRoot $genRoot } `
                -MessagePattern 'outside the chain install.*onnxruntime-genai\.dll' 'a bundled GenAI is as foreign as a bundled ORT'
        }

        It 'accepts a chain directory passed as a GStreamer root and still lists it last' {
            $r = @(Get-MediaRuntimeDirectory -GStreamerRoot @($ortBin, $gstA) -OnnxRoot $ortRoot)
            Assert-Equal ((@((Resolve-Path -LiteralPath $gstA).Path, $ortLib, $ortBin)) -join '|') ($r -join '|')
        }

        It 'ignores the NuGet-era version parameters' {
            $with = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot $ortRoot `
                    -OnnxVersion '1.2.3' -OnnxGenAiVersion '0.1.0' -OnnxDirectMlVersion '1.2.3')
            $without = @(Get-MediaRuntimeDirectory -GStreamerRoot @($gstA) -OnnxRoot $ortRoot)
            Assert-Equal ($without -join '|') ($with -join '|')
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

        It 'stages the chain ORT bytes, and the chain DirectML.dll over GenAI''s (mutation)' {
            $target = Join-Path $root 'stage6\bin'
            $n = Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA) `
                -OnnxRoot $ortRoot -OnnxGenAiRoot $genRoot
            Assert-Equal 7 $n 'gst 2 + genai 2 + ort lib 1 + ort bin 3, DirectML.dll counted once'
            foreach ($name in 'onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'DirectML.dll') {
                Assert-Equal (Get-FileHash -LiteralPath (Join-Path $ortBin $name)).Hash (Get-FileHash -LiteralPath (Join-Path $target $name)).Hash $name
            }
            Assert-Equal (Get-FileHash -LiteralPath (Join-Path $genLib 'onnxruntime-genai.dll')).Hash `
                (Get-FileHash -LiteralPath (Join-Path $target 'onnxruntime-genai.dll')).Hash 'onnxruntime-genai.dll'
        }

        It 'refuses a TargetDir left holding ORT or GenAI that is not the chain''s bytes (mutation)' {
            # A stale copy is foreign under Stale's roots; under Clean's the chain overwrites it and the check passes.
            $cases = @(
                @{ Name = 'onnxruntime.dll'; Stale = @{ OnnxRoot = '' }; Clean = @{ OnnxRoot = $ortRoot } }
                @{ Name = 'onnxruntime-genai.dll'; Stale = @{ OnnxRoot = $ortRoot }; Clean = @{ OnnxRoot = $ortRoot; OnnxGenAiRoot = $genRoot } }
            )
            foreach ($case in $cases) {
                $target = Join-Path $root "stage7\$([IO.Path]::GetFileNameWithoutExtension($case.Name))"
                New-TestPeFile (Join-Path $target $case.Name) -Tag "stale-$($case.Name)"
                $stale, $clean = $case.Stale, $case.Clean
                Assert-Throws { Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @($gstA) @stale } `
                    -MessagePattern ('not the chain''s bytes: ' + [regex]::Escape($case.Name) + '\.') $case.Name
                [void](Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @() @clean)
            }
            New-TestPeFile (Join-Path $target 'onnxruntime_providers_webgpu.dll') -Tag 'prebuilt-ep'
            Assert-Throws { Copy-MediaRuntimeBundle -Context $ctx -TargetDir $target -GStreamerRoot @() @clean } `
                -MessagePattern 'not the chain''s bytes: onnxruntime_providers_webgpu\.dll\.' 'an EP the chain did not build is foreign'
        }

        It 'the bundle check compares bytes, not only names (mutation)' {
            # End to end the chain copy always overwrites; a failed or skipped copy is what this catches.
            $check = { param($t, $c) Assert-MediaRuntimeOnnxFromChain -TargetDir $t -ChainDirectory $c }
            $mod = Get-Module -Name 'WindowsMediaRuntime.Common'
            $target = Join-Path $root 'stage8\bin'
            New-TestPeFile (Join-Path $target 'onnxruntime.dll') -Tag 'same-name-other-bytes'
            Assert-Throws { & $mod $check $target @($ortBin) } -MessagePattern 'not the chain''s bytes: onnxruntime\.dll'
            Copy-Item -LiteralPath (Join-Path $ortBin 'onnxruntime.dll') -Destination $target -Force
            & $mod $check $target @($ortBin)
        }

        It 'exports exactly the two documented functions' {
            $m = Get-Module -Name 'WindowsMediaRuntime.Common'
            Assert-Equal 'Copy-MediaRuntimeBundle,Get-MediaRuntimeDirectory' (($m.ExportedFunctions.Keys | Sort-Object) -join ',')
        }
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
