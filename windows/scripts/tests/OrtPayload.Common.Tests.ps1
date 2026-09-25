#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# WindowsOrtPayload.Common: the chain ORT staged beside an exe, and a shipped tree proved, over synthetic PE
# trees and a throwaway chain install that G6 takes as its reference through ONNX_ROOT. The cases came from
# OxidANT's suite (scripts/windows/tests/OrtPayload.Tests.ps1), where the functions lived until 2026-09-25.
# NOT covered: a real chain install, and which copy a process loads beyond G6's modelled loader order.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtPayload.Common.psm1') -Force -DisableNameChecking

$script:ChainSrc = 'C:\temp\onnx-src\onnxruntime\core\session\inference_session.cc'
$script:ForeignSrc = 'C:\__w\1\s\onnxruntime\core\session\inference_session.cc'

# A chain install as the image lays it out, with an EP sidecar, and a release dir whose exe loads ORT
# (names OrtGetApiBase) or not.
function New-PayloadCase {
    param([Parameter(Mandatory)][string]$Dir, [switch]$PlainExe)
    $chainFiles = [ordered]@{
        'onnxruntime.dll'                  = @($script:ChainSrc, 'OrtGetApiBase')
        'onnxruntime_providers_shared.dll' = @('provider bridge')
        'DirectML.dll'                     = @('directml')
        'QnnHtp.dll'                       = @('an EP sidecar')
    }
    foreach ($name in $chainFiles.Keys) { New-OrtTestPe -Path "$Dir\onnx\bin\$name" -Text $chainFiles[$name] }
    New-OrtTestPe -Path "$Dir\release\app.exe" -Text @($(if ($PlainExe) { 'main' } else { 'OrtGetApiBase' }))
    return [pscustomobject]@{ Chain = "$Dir\onnx"; Release = "$Dir\release"; Exe = "$Dir\release\app.exe"; Payload = "$Dir\payload" }
}

# One case in a throwaway directory, the chain as G6's reference and, unless -Unstaged, its ORT staged
# beside the exe; -Body gets the case.
function Invoke-PayloadCase {
    param([Parameter(Mandatory)][scriptblock]$Body, [switch]$PlainExe, [switch]$Unstaged)
    Invoke-InTestDir { param($dir)
        $case = New-PayloadCase -Dir $dir -PlainExe:$PlainExe
        Invoke-WithEnv @{ ONNX_ROOT = $case.Chain; ONNX_GENAI_ROOT = $null } {
            if (-not $Unstaged) { $null = Copy-ChainOrtBeside -OnnxRoot $case.Chain -Destination $case.Release }
            & $Body $case
        }
    }
}

# What New-OrtProvenPayload refuses the case's release dir with; empty when the payload ships.
function Get-PayloadRefusal {
    param([Parameter(Mandatory)][object]$Case, [string[]]$IncludeDirectory = @())
    try { $null = New-OrtProvenPayload -ExePath $Case.Exe -Destination $Case.Payload -IncludeDirectory $IncludeDirectory } catch { return "$($_.Exception.Message)" }
    return ''
}

function Get-SortedLeaf {
    param([string[]]$Path)
    $names = [string[]]@($Path | ForEach-Object { Split-Path $_ -Leaf })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return ($names -join ',')
}

Describe 'WindowsOrtPayload.Common: staging' {
    It 'tells an ORT consumer from a plain exe the way G6 does' {
        Invoke-InTestDir { param($dir)
            Assert-True (Test-ExeLoadsOrt -Path (New-PayloadCase -Dir "$dir\c").Exe) 'names OrtGetApiBase'
            Assert-False (Test-ExeLoadsOrt -Path (New-PayloadCase -Dir "$dir\p" -PlainExe).Exe) 'names nothing of ORT'
        }
    }

    It 'stages the three runtime files over stale ones; -All stages the EP sidecars too' {
        Invoke-PayloadCase -Unstaged { param($c)
            New-OrtTestPe -Path "$($c.Release)\onnxruntime-genai.dll" -Text @('stale')
            $copied = @(Copy-ChainOrtBeside -OnnxRoot $c.Chain -Destination $c.Release)
            Assert-Equal 'DirectML.dll,onnxruntime.dll,onnxruntime_providers_shared.dll' (Get-SortedLeaf $copied) 'the default set'
            Assert-False (Test-Path "$($c.Release)\onnxruntime-genai.dll") 'a stale family DLL is removed'
            Assert-False (Test-Path "$($c.Release)\QnnHtp.dll") 'no sidecar without -All'
            # A provider the chain ships is no STRAY: the proof reads the chain's names, not a fixed list.
            New-OrtTestPe -Path "$($c.Chain)\bin\onnxruntime_providers_qnn.dll" -Text @('qnn provider')
            $all = @(Copy-ChainOrtBeside -OnnxRoot $c.Chain -Destination $c.Release -All)
            Assert-Equal 'DirectML.dll,QnnHtp.dll,onnxruntime.dll,onnxruntime_providers_qnn.dll,onnxruntime_providers_shared.dll' (Get-SortedLeaf $all) 'every DLL of the chain'
            Assert-Equal '' (Get-PayloadRefusal $c) 'and that payload proves'
        }
    }

    It 'refuses to stage from no chain install' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Copy-ChainOrtBeside -OnnxRoot '' -Destination "$dir\out" } -MessagePattern 'ONNX_ROOT is not set'
            Assert-Throws { Copy-ChainOrtBeside -OnnxRoot "$dir\nowhere" -Destination "$dir\out" } -MessagePattern 'not the chain install'
        }
    }
}

Describe 'WindowsOrtPayload.Common: proof' {
    It 'ships a payload G6 passes, the chain runtime files and nothing else of ORT' {
        Invoke-PayloadCase { param($c)
            $payload = New-OrtProvenPayload -ExePath $c.Exe -Destination $c.Payload
            Assert-True $payload.LoadsOrt 'the exe loads ORT'
            Assert-Equal 'DirectML.dll,onnxruntime.dll,onnxruntime_providers_shared.dll' (Get-SortedLeaf $payload.OrtDlls) 'the shipped ORT'
        }
    }

    It 'refuses a foreign, a stale and a missing ORT (G6 verdicts)' {
        Invoke-PayloadCase { param($c)
            $ort = "$($c.Release)\onnxruntime.dll"
            New-OrtTestPe -Path $ort -Text @($script:ForeignSrc)
            Assert-Match 'FOREIGN' (Get-PayloadRefusal $c)
            New-OrtTestPe -Path $ort -Text @($script:ChainSrc, 'FileVersion 1.27.0')
            Assert-Match 'STALE' (Get-PayloadRefusal $c)
            Remove-Item -LiteralPath $ort
            Assert-Match '(?s)MISSING.*UNRESOLVED' (Get-PayloadRefusal $c)
        }
    }

    It 'refuses what G6 does not grade: a stray family name and another DirectML.dll' {
        Invoke-PayloadCase { param($c)
            New-OrtTestPe -Path "$($c.Release)\onnxruntime_extra.dll" -Text @('extra')
            Assert-Match 'STRAY .*onnxruntime_extra' (Get-PayloadRefusal $c)
            Remove-Item -LiteralPath "$($c.Release)\onnxruntime_extra.dll"
            New-OrtTestPe -Path "$($c.Release)\DirectML.dll" -Text @('other directml')
            Assert-Match 'CHANGED .*DirectML' (Get-PayloadRefusal $c)
        }
    }

    It 'counts the chain GenAI install as the chain: its DLL is STRAY only without ONNX_GENAI_ROOT' {
        Invoke-PayloadCase { param($c)
            $genAi = Join-Path (Split-Path $c.Chain -Parent) 'genai'
            New-OrtTestPe -Path "$genAi\lib\onnxruntime-genai.dll" -Import @('onnxruntime.dll') -Text @('genai')
            Copy-Item -LiteralPath "$genAi\lib\onnxruntime-genai.dll" -Destination $c.Release
            Assert-Match 'STRAY .*onnxruntime-genai' (Get-PayloadRefusal $c)
            Invoke-WithEnv @{ ONNX_GENAI_ROOT = $genAi } { Assert-Equal '' (Get-PayloadRefusal $c) 'the chain GenAI ships' }
        }
    }

    It 'ships a plain exe without ORT, and refuses a renamed ORT beside it' {
        Invoke-PayloadCase -PlainExe -Unstaged { param($c)
            New-OrtTestPe -Path "$($c.Release)\onnxruntime.dll" -Text @($script:ChainSrc)
            $payload = New-OrtProvenPayload -ExePath $c.Exe -Destination $c.Payload
            Assert-False $payload.LoadsOrt 'a plain exe'
            Assert-Equal 0 @($payload.OrtDlls).Count 'its payload carries no ORT'
            New-OrtTestPe -Path "$($c.Release)\helper.dll" -Text @($script:ChainSrc)
            Assert-Match 'UNEXPECTED .*helper\.dll' (Get-PayloadRefusal $c)
        }
    }

    It 'counts an ORT-consuming DLL beside a plain exe: refused without ORT, proved with the chain one (mutation)' {
        Invoke-PayloadCase -PlainExe -Unstaged { param($c)
            Assert-False (Test-PayloadLoadsOrt -ExePath $c.Exe) 'nothing loads ORT yet'
            New-OrtTestPe -Path "$($c.Release)\oxidant.dll" -Text @('OrtGetApiBase')
            Assert-True (Test-PayloadLoadsOrt -ExePath $c.Exe) 'the DLL beside it does'
            Assert-Match '(?s)MISSING.*UNRESOLVED .*oxidant\.dll' (Get-PayloadRefusal $c)
            $null = Copy-ChainOrtBeside -OnnxRoot $c.Chain -Destination $c.Release
            Assert-Equal '' (Get-PayloadRefusal $c) 'proved with the chain ORT'
        }
    }

    It 'ships an -IncludeDirectory tree whole, and G6 grades it with the rest (mutation)' {
        Invoke-PayloadCase { param($c)
            New-OrtTestPe -Path "$($c.Release)\lib\gstreamer-1.0\gstapp.dll" -Text @('plugin')
            $payload = New-OrtProvenPayload -ExePath $c.Exe -Destination $c.Payload -IncludeDirectory 'lib', 'absent'
            Assert-True (Test-Path "$($c.Payload)\lib\gstreamer-1.0\gstapp.dll") 'the plugin ships'
            Assert-Equal "$($c.Payload)\lib" ($payload.Included -join ',') 'only the tree that exists'
            New-OrtTestPe -Path "$($c.Release)\lib\gstreamer-1.0\onnxruntime.dll" -Text @($script:ForeignSrc)
            Assert-Match 'FOREIGN .*gstreamer-1\.0' (Get-PayloadRefusal $c -IncludeDirectory 'lib')
        }
    }

    It 'grades where the exe loads ORT from, and -WaiveUnresolved spares only UNRESOLVED' {
        Invoke-PayloadCase -Unstaged { param($c)
            # A Python package: a .pyd importing onnxruntime.dll, the chain ORT in a libs\ it registers.
            $pkg = Join-Path (Split-Path $c.Release -Parent) 'site\pkg'
            New-OrtTestPe -Path "$pkg\native.pyd" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            $null = Copy-ChainOrtBeside -OnnxRoot $c.Chain -Destination "$pkg\libs"
            Assert-Throws { Assert-ChainOrtTree -Root $pkg } -MessagePattern '(?s)MISSING .*pkg\\onnxruntime\.dll.*UNRESOLVED'
            Assert-Throws { Assert-ChainOrtTree -Root $pkg -OrtDirectory "$pkg\libs" } -MessagePattern 'UNRESOLVED'
            Assert-NotNull (Assert-ChainOrtTree -Root $pkg -OrtDirectory "$pkg\libs" -WaiveUnresolved) 'passes, and returns the census'
            New-OrtTestPe -Path "$pkg\libs\onnxruntime.dll" -Text @($script:ForeignSrc)
            Assert-Throws { Assert-ChainOrtTree -Root $pkg -OrtDirectory "$pkg\libs" -WaiveUnresolved } -MessagePattern 'FOREIGN'
        }
    }
}
