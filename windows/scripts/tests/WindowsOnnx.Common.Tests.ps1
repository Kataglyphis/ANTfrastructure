#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# WindowsOnnx.Common after the owner rule of 2026-09-23: NuGet ORT is refused by id, by dependency and by content,
# the NuGet layout helper refuses, and Get-OnnxChainLayout accepts only the chain install for the target machine.
# NOT covered: real nuget.exe or network (a global `nuget` stand-in answers), byte provenance of a chain install.

# Lays out files relative to a root, creating directories; content is irrelevant to every check here.
function Write-OnnxTestTree([string]$Root, [string[]]$Relative) {
    foreach ($rel in $Relative) {
        $p = Join-Path $Root $rel
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent)
        [IO.File]::WriteAllText($p, $rel)
    }
}

Describe 'WindowsOnnx.Common: NuGet ONNX Runtime is refused' {

    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsOnnx.Common.psm1') -Force -DisableNameChecking

    # Stands in for nuget.exe: logs each call, 'list' answers ONNX_TEST_NUGET_OFFER, 'install' lays out ONNX_TEST_NUGET_LAYOUT.
    function global:nuget {
        Add-Content -LiteralPath $env:ONNX_TEST_NUGET_LOG -Value ($args -join ' ')
        if ($args[0] -eq 'list') { return $env:ONNX_TEST_NUGET_OFFER }
        if ($args[0] -ne 'install') { return }
        $out = $args[[array]::IndexOf($args, '-OutputDirectory') + 1]
        foreach ($rel in @($env:ONNX_TEST_NUGET_LAYOUT -split ';' | Where-Object { $_ })) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $out $rel) -Parent)
            [IO.File]::WriteAllText((Join-Path $out $rel), 'nupkg')
        }
    }
    # Runs $Body with the stand-in answering $Offer/$Layout; $Body gets the output directory and the call log.
    function Invoke-WithNuGetStandIn([string]$Offer, [string[]]$Layout, [scriptblock]$Body) {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'nuget-calls.log'
            Invoke-WithEnv @{ ONNX_TEST_NUGET_OFFER = $Offer; ONNX_TEST_NUGET_LAYOUT = ($Layout -join ';'); ONNX_TEST_NUGET_LOG = $log } {
                & $Body (Join-Path $dir 'out') $log
            }
        }
    }
    $okPackage = @('Some.Package.1.0.0\Some.Package.1.0.0.nupkg', 'Some.Package.1.0.0\lib\native\some.dll')

    try {
        It 'refuses every ONNX Runtime package id before any NuGet call (mutation)' {
            foreach ($id in 'Microsoft.ML.OnnxRuntime', 'Microsoft.ML.OnnxRuntime.DirectML', 'Microsoft.ML.OnnxRuntime.Gpu.Windows',
                'microsoft.ml.onnxruntimegenai.directml', 'Microsoft.ML.OnnxRuntimeGenAI.Cuda', 'Intel.ML.OnnxRuntime.OpenVino',
                'Microsoft.AI.MachineLearning', 'Microsoft.Windows.AI.MachineLearning') {
                Invoke-WithNuGetStandIn -Offer "$id 1.2.3" -Layout @("$id.1.2.3\$id.1.2.3.nupkg") { param($out, $log)
                    Assert-Throws { Install-OptionalNuGetPackage -PackageId $id -Version '1.2.3' -OutputDirectory $out } `
                        -MessagePattern 'is an ONNX Runtime package and is refused.*chain build only.*ONNX_ROOT' $id
                    Assert-False (Test-Path -LiteralPath $out) "$id left files behind"
                    Assert-False (Test-Path -LiteralPath $log) "$id reached nuget"
                }
            }
        }

        It 'installs a package that carries no ONNX Runtime and returns exactly $true' {
            Invoke-WithNuGetStandIn -Offer 'Some.Package 1.0.0' -Layout $okPackage { param($out, $log)
                $r = @(Install-OptionalNuGetPackage -PackageId 'Some.Package' -Version '1.0.0' -OutputDirectory $out)
                Assert-Equal 1 $r.Count 'nuget output must not leak into the return value'
                Assert-True ($r[0] -is [bool] -and $r[0])
                Assert-True (Test-Path -LiteralPath (Join-Path $out 'Some.Package.1.0.0\lib\native\some.dll'))
                Assert-Match '^install Some\.Package ' @(Get-Content -LiteralPath $log)[-1]
            }
        }

        It 'refuses ORT that arrives as a dependency, bundled under another id, or already there on a re-run (mutation)' {
            $cases = @(
                @{ Why = 'dependency'; Layout = $okPackage + 'Microsoft.ML.OnnxRuntime.1.2.3\Microsoft.ML.OnnxRuntime.1.2.3.nupkg'
                    Pattern = 'Microsoft\.ML\.OnnxRuntime\.1\.2\.3' }
                @{ Why = 'bundled'; Layout = $okPackage + 'Some.Package.1.0.0\runtimes\win-x64\native\onnxruntime.dll'
                    Pattern = 'Some\.Package\.1\.0\.0\\runtimes\\win-x64\\native\\onnxruntime\.dll' }
                @{ Why = 'bundled GenAI'; Layout = $okPackage + 'Some.Package.1.0.0\runtimes\win-x64\native\onnxruntime-genai.dll'
                    Pattern = 'Some\.Package\.1\.0\.0\\runtimes\\win-x64\\native\\onnxruntime-genai\.dll' }
                @{ Why = 're-run'; Layout = $okPackage; Before = 'microsoft.ml.onnxruntime.directml\1.2.3\microsoft.ml.onnxruntime.directml.1.2.3.nupkg'
                    Pattern = 'microsoft\.ml\.onnxruntime\.directml' }
            )
            foreach ($case in $cases) {
                Invoke-WithNuGetStandIn -Offer 'Some.Package 1.0.0' -Layout $case.Layout { param($out)
                    if ($case.ContainsKey('Before')) { Write-OnnxTestTree -Root $out -Relative @($case.Before) }
                    Assert-Throws { Install-OptionalNuGetPackage -PackageId 'Some.Package' -Version '1.0.0' -OutputDirectory $out } `
                        -MessagePattern ('Some\.Package left ONNX Runtime.*' + $case.Pattern) $case.Why
                }
            }
        }

        It 'does not count an onnxruntime.dll that sits outside every NuGet package directory' {
            # A staged chain copy under the workspace (the default -OutputDirectory is '.') is not a package.
            Invoke-WithNuGetStandIn -Offer 'Some.Package 1.0.0' -Layout $okPackage { param($out)
                Write-OnnxTestTree -Root $out -Relative @('build\bin\onnxruntime.dll')
                Assert-True (Install-OptionalNuGetPackage -PackageId 'Some.Package' -Version '1.0.0' -OutputDirectory $out)
            }
        }

        It 'returns $false and installs nothing when the version is not on NuGet' {
            Invoke-WithNuGetStandIn -Offer $null -Layout $okPackage { param($out)
                Assert-False (Install-OptionalNuGetPackage -PackageId 'Some.Package' -Version '9.9.9' -OutputDirectory $out)
                Assert-False (Test-Path -LiteralPath $out)
            }
        }
    } finally {
        Remove-Item -LiteralPath 'function:global:nuget' -ErrorAction SilentlyContinue
    }
}

Describe 'WindowsOnnx.Common: the chain layout' {

    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsOnnx.Common.psm1') -Force -DisableNameChecking

    $root = Join-Path ([IO.Path]::GetTempPath()) ("onnxchain-" + [guid]::NewGuid().ToString('N'))
    $chain = Join-Path $root 'onnxruntime-source'
    New-TestPeFile (Join-Path $chain 'bin\onnxruntime.dll') -Tag 'chain'
    Write-OnnxTestTree -Root $chain -Relative @('lib\onnxruntime.lib', 'include\onnxruntime\onnxruntime_c_api.h')
    $genai = Join-Path $root 'onnxruntime-genai-source'
    New-TestPeFile (Join-Path $genai 'lib\onnxruntime-genai.dll') -Tag 'genai'
    Write-OnnxTestTree -Root $genai -Relative @('include\ort_genai.h')
    $zip = Join-Path $root 'onnxruntime-win-x64-1.25.1'
    New-TestPeFile (Join-Path $zip 'lib\onnxruntime.dll') -Tag 'release-zip'
    $nuget = Join-Path $root 'nuget'
    New-TestPeFile (Join-Path $nuget 'Microsoft.ML.OnnxRuntime.1.2.3\runtimes\win-x64\native\onnxruntime.dll') -Tag 'nuget'
    $arm = Join-Path $root 'ort-arm64'
    New-TestPeFile (Join-Path $arm 'bin\onnxruntime.dll') -Machine 0xAA64 -Tag 'arm64'

    Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = $null; ONNX_ROOT = $null; ONNX_GENAI_ROOT = $null } {

        It 'Get-OnnxPackageLayout refuses in both call shapes and points at the chain (mutation)' {
            Assert-Throws { Get-OnnxPackageLayout -OnnxRoot $nuget -OnnxVersion '1.2.3' -OnnxGenAiVersion '0.1.0' -OnnxDirectMlVersion '1.2.3' } `
                -MessagePattern 'NuGet Microsoft\.ML\.OnnxRuntime layout.*is refused.*Get-OnnxChainLayout'
            Assert-Throws { Get-OnnxPackageLayout $nuget '1.2.3' '0.1.0' '1.2.3' } -MessagePattern 'is refused' 'positional'
        }

        It 'Get-OnnxChainLayout describes the chain install (ONNX_ROOT/ONNX_GENAI_ROOT by default), chain bin listed last' {
            $ortOnly = Get-OnnxChainLayout -OnnxRoot $chain -OnnxGenAiRoot ''
            $withGenAi = Invoke-WithEnv @{ ONNX_ROOT = $chain; ONNX_GENAI_ROOT = $genai } { Get-OnnxChainLayout }
            $got = @($ortOnly.DllPath, $ortOnly.ImportLibPath, $ortOnly.IncludeDir, "$($ortOnly.GenAiRoot)", ($ortOnly.RuntimeDirectories -join '+'),
                $withGenAi.GenAiDllPath, ($withGenAi.RuntimeDirectories -join '+'))
            $want = @('bin\onnxruntime.dll', 'lib\onnxruntime.lib', 'include\onnxruntime') | ForEach-Object { Join-Path $chain $_ }
            $want += '', "$chain\lib+$chain\bin", "$genai\lib\onnxruntime-genai.dll", "$genai\lib+$chain\lib+$chain\bin"
            Assert-Equal ($want -join '|') ($got -join '|')
        }

        It 'Get-OnnxChainLayout throws when ONNX_ROOT is unset' {
            Assert-Throws { Get-OnnxChainLayout -OnnxRoot '' } -MessagePattern 'ONNX_ROOT is not set.*ONNX_ROOT is unset'
        }

        It 'Get-OnnxChainLayout refuses a NuGet tree and a release-zip layout (mutation)' {
            Assert-Throws { Get-OnnxChainLayout -OnnxRoot $nuget -OnnxGenAiRoot '' } -MessagePattern 'is not the chain install' 'NuGet'
            Assert-Throws { Get-OnnxChainLayout -OnnxRoot $zip -OnnxGenAiRoot '' } -MessagePattern 'is not the chain install' 'release zip'
        }

        It 'Get-OnnxChainLayout refuses a chain DLL built for another machine (mutation)' {
            Assert-Throws { Get-OnnxChainLayout -OnnxRoot $arm -OnnxGenAiRoot '' } -MessagePattern 'PE machine 0xAA64, expected 0x8664'
            [void](Get-OnnxChainLayout -OnnxRoot $arm -OnnxGenAiRoot '' -Arch 'arm64')
        }

        It 'Get-OnnxChainLayout refuses a GenAI root with its own ORT, or without onnxruntime-genai.dll (mutation)' {
            Invoke-InTestDir { param($dir)
                New-TestPeFile (Join-Path $dir 'lib\onnxruntime-genai.dll') -Tag 'genai'
                Write-OnnxTestTree -Root $dir -Relative @('lib\onnxruntime.lib')
                Assert-Throws { Get-OnnxChainLayout -OnnxRoot $chain -OnnxGenAiRoot $dir } -MessagePattern 'carries its own ONNX Runtime.*onnxruntime\.lib'
            }
            Invoke-InTestDir { param($dir)
                Write-OnnxTestTree -Root $dir -Relative @('include\ort_genai.h')
                Assert-Throws { Get-OnnxChainLayout -OnnxRoot $chain -OnnxGenAiRoot $dir } -MessagePattern 'holds no onnxruntime-genai\.dll'
            }
        }

        It 'Get-OnnxChainLayout refuses a NuGet GenAI package, a GenAI DLL off lib\ and bin\, and one for another machine (mutation)' {
            # The nuget.org Microsoft.ML.OnnxRuntimeGenAI.DirectML nupkg's native payload: no ORT file, so only its layout gives it away.
            $pkg = 'Microsoft.ML.OnnxRuntimeGenAI.DirectML.0.14.1'
            $cases = @(
                @{ Why = 'nuget.org layout'; Pattern = 'is a NuGet package \(.*runtimes'
                    Tree = @("$pkg.nupkg", 'runtimes\win-x64\native\onnxruntime-genai.lib', 'build\native\include\ort_genai.h'); Pe = 'runtimes\win-x64\native\onnxruntime-genai.dll' }
                @{ Why = 'runtimes\ beside lib\'; Pattern = 'is a NuGet package \(runtimes\)'; Tree = @('runtimes\win-x64\native\readme.txt'); Pe = 'lib\onnxruntime-genai.dll' }
                @{ Why = '.nupkg beside lib\'; Pattern = "is a NuGet package \($([regex]::Escape($pkg))\.nupkg\)"; Tree = @("$pkg.nupkg"); Pe = 'lib\onnxruntime-genai.dll' }
                @{ Why = 'deeper than lib\'; Pattern = 'holds no onnxruntime-genai\.dll in lib\\ or bin\\'; Tree = @(); Pe = 'lib\x64\onnxruntime-genai.dll' }
                @{ Why = 'arm64 on x64'; Pattern = 'PE machine 0xAA64, expected 0x8664'; Tree = @(); Pe = 'lib\onnxruntime-genai.dll'; Machine = 0xAA64 }
            )
            foreach ($case in $cases) {
                Invoke-InTestDir { param($dir)
                    Write-OnnxTestTree -Root $dir -Relative $case.Tree
                    New-TestPeFile (Join-Path $dir $case.Pe) -Machine $(if ($case.ContainsKey('Machine')) { $case.Machine } else { 0x8664 }) -Tag 'genai'
                    Assert-Throws { Get-OnnxChainLayout -OnnxRoot $chain -OnnxGenAiRoot $dir } -MessagePattern $case.Pattern $case.Why
                }
            }
            Invoke-InTestDir { param($dir)
                New-TestPeFile (Join-Path $dir 'bin\onnxruntime-genai.dll') -Tag 'genai-bin'
                Assert-Equal (Join-Path $dir 'bin\onnxruntime-genai.dll') (Get-OnnxChainLayout -OnnxRoot $chain -OnnxGenAiRoot $dir).GenAiDllPath 'bin\ is tolerated'
            }
        }

        It 'Get-OnnxRuntimeFile recognises ORT and GenAI files by name, and nothing else' {
            Invoke-InTestDir { param($dir)
                Write-OnnxTestTree -Root $dir -Relative @('onnxruntime.dll', 'ONNXRUNTIME_PROVIDERS_WEBGPU.DLL', 'onnxruntime.lib',
                    'onnxruntime_c_api.h', 'onnxruntime_pybind11_state.pyd', 'Microsoft.AI.MachineLearning.dll',
                    'onnxruntime-genai.dll', 'onnxruntime-genai-cuda.dll', 'onnxruntime_genai.cp314-win_amd64.pyd', 'ort_genai.h',
                    'DirectML.dll', 'onnx.dll', 'onnxruntime.pdb', 'opencv_dnn500.dll', 'sub\onnxruntime.dll')
                $flat = @(Get-OnnxRuntimeFile -Path $dir | ForEach-Object { "$($_.Name)=$($_.Kind)" } | Sort-Object)
                $want = @('onnxruntime.dll=ort', 'ONNXRUNTIME_PROVIDERS_WEBGPU.DLL=ort', 'onnxruntime.lib=ort', 'onnxruntime_c_api.h=ort',
                    'onnxruntime_pybind11_state.pyd=ort', 'Microsoft.AI.MachineLearning.dll=ort', 'onnxruntime-genai.dll=genai',
                    'onnxruntime-genai-cuda.dll=genai', 'onnxruntime_genai.cp314-win_amd64.pyd=genai', 'ort_genai.h=genai') | Sort-Object
                Assert-Equal ($want -join ',') ($flat -join ',')
                Assert-Equal 11 @(Get-OnnxRuntimeFile -Path $dir -Recurse).Count '-Recurse reaches sub\'
                Assert-Equal 0 @(Get-OnnxRuntimeFile -Path (Join-Path $dir 'absent')).Count
            }
        }

        It 'exports exactly the five documented functions' {
            $m = Get-Module -Name 'WindowsOnnx.Common'
            Assert-Equal 'Get-OnnxChainLayout,Get-OnnxPackageLayout,Get-OnnxRuntimeFile,Install-OptionalNuGetPackage,Test-NuGetPackageVersionAvailable' `
                (($m.ExportedFunctions.Keys | Sort-Object) -join ',')
        }
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
