#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Grading of the DirectML MatMul probe and the source patch's text; a real adapter and a patched ORT build are not covered.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtDmlCheck.Common.psm1') -Force -DisableNameChecking

Describe 'DirectML MatMul verdict' {
    It 'names each outcome (mutation)' {
        $cpu = '"cpu":[321,654,987,1320]'
        $cases = @(
            @{ Text = "{`"adapter`":true,$cpu,`"dml`":[321,654,987,1320]}"; Want = 'Pass' }
            @{ Text = "{`"adapter`":true,$cpu,`"dml`":[6,15,24,33]}"; Want = 'Wrong' }
            @{ Text = "{`"adapter`":true,$cpu,`"dml`":[321]}"; Want = 'Wrong' }
            @{ Text = "{`"adapter`":false,$cpu,`"dml`":null}"; Want = 'NoAdapter' }
            @{ Text = '{"adapter":true,"cpu":[1,2,3,4],"dml":[1,2,3,4]}'; Want = 'ProbeFailed' }
            @{ Text = 'Traceback (most recent call last)'; Want = 'ProbeFailed' }
            @{ Text = ''; Want = 'ProbeFailed' }
        )
        foreach ($case in $cases) {
            Assert-Equal $case.Want (ConvertFrom-OrtDmlMatMulProbe -Text $case.Text).Status "for: $($case.Text)"
        }
        Assert-Equal 'ProbeFailed' (ConvertFrom-OrtDmlMatMulProbe -Text "{`"adapter`":true,$cpu,`"dml`":[321,654,987,1320]}" -ExitCode 1).Status 'a crash beats a printed pass'
    }

    It 'ignores provider warnings printed around the JSON line' {
        $text = "warning: no devices`n{`"adapter`":false,`"cpu`":[321,654,987,1320],`"dml`":null}`n"
        Assert-Equal 'NoAdapter' (ConvertFrom-OrtDmlMatMulProbe -Text $text).Status 'the JSON line decides'
    }

    It 'does not hide an exception as a missing adapter' {
        $source = Get-OrtDmlMatMulProbeSource
        Assert-False ($source -match '\bexcept\b') 'an unexpected Python error must exit non-zero'
    }
}

Describe 'DirectML MatMul wiring' {
    It 'the patch fixes the right input and its failure is fatal' {
        $root = Get-RepoRoot
        $patch = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\patches\onnxruntime\006-dml-matmul-1d-rhs.patch') -Raw
        Assert-True ($patch.Contains('DmlOperatorMatMul.cpp')) 'patches the MatMul operator'
        Assert-True ($patch.Contains('m_inputTensorDescs[1] = TensorDesc(')) 'replaces the right-hand descriptor'
        $build = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\build\Build-OnnxFromSource.ps1') -Raw
        Assert-True ($build -match "(?s)006-dml-matmul-1d-rhs\.patch.*?-Fatal") 'a patch that stops applying fails the build'
    }

    It 'both gates run the probe, and only a missing adapter may skip' {
        $root = Get-RepoRoot
        $smoke = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\build\Test-Container.ps1') -Raw
        Assert-True ($smoke -match "(?s)Invoke-OrtDmlMatMulProbe.*?-eq 'NoAdapter'.*?Skip-Test.*?-eq 'Pass'") 'the image smoke grades it'
        $device = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\build\Test-Arm64Bundle.ps1') -Raw
        Assert-True ($device -match "Status -notin @\('Pass', 'NoAdapter'\)") 'the device gate fails anything else'
        $export = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\build\Export-Arm64Bundle.ps1') -Raw
        Assert-True ($export.Contains('WindowsOrtDmlCheck.Common.psm1')) 'the packing step carries the module'
    }
}
