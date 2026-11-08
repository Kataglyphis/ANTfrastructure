#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The onnxinference gate over a fake gst-launch; a real session and the output values are not covered.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsGstPlugins.Common.psm1') -Force -DisableNameChecking

Describe 'onnxinference run gate' {
    It 'hands a sidecar beside the model and an unbroken path, and fails on a failed pipeline (mutation)' {
        $dir = New-TestDir -Prefix 'gst onnx run'
        try {
            $fake = Join-Path $dir 'fake.ps1'
            Set-Content -LiteralPath $fake -Value @'
$arg = @($args | Where-Object { "$_" -like 'model-file=*' })
if ($arg.Count -ne 1) { Write-Output "model-file split into $($arg.Count) arguments: $args"; exit 3 }
$model = "$($arg[0])".Substring('model-file='.Length)
if (-not (Test-Path -LiteralPath $model) -or -not (Test-Path -LiteralPath "$model.modelinfo")) { Write-Output "no model or sidecar at $model"; exit 4 }
if (-not ((Get-Content -LiteralPath "$model.modelinfo" -Raw) -match '(?m)^\[modelinfo\]')) { exit 5 }
exit ([int]$env:FAKE_GST_EXIT)
'@
            $env:FAKE_GST_EXIT = '0'
            Assert-GstOnnxInferenceRun -GstLaunch $fake -WorkDir (Join-Path $dir 'work')
            $env:FAKE_GST_EXIT = '7'
            Assert-Throws { Assert-GstOnnxInferenceRun -GstLaunch $fake -WorkDir (Join-Path $dir 'work') } -MessagePattern 'exit 7'
        } finally {
            Remove-Item Env:\FAKE_GST_EXIT -ErrorAction SilentlyContinue
            Remove-TestDir $dir
        }
    }

    It 'bisects a failed run: the frames alone, ORC off and the onnx log, then restores the environment (mutation)' {
        $crash = "if (-not (`$args -contains 'onnxinference')) { exit 0 }`nif (`$env:ORC_CODE -eq 'backup') { 'orc off'; exit 0 }`n`"gst said `$(`$env:GST_DEBUG)`"; exit 7"
        Invoke-InTestDir -Files @{ 'crash.ps1' = $crash } -Body {
            param($root)
            $why = try { Assert-GstOnnxInferenceRun -GstLaunch (Join-Path $root 'crash.ps1') -WorkDir (Join-Path $root 'diag'); '' } catch { "$_" }
            foreach ($expect in 'without onnxinference: exit 0', 'ORC_CODE=backup: exit 0\s+orc off', 'GST_DEBUG=onnx\*:6: exit 7\s+gst said onnx\*:6') {
                Assert-Match "diagnosis, $expect" $why "the bisect reports '$expect'"
            }
            Assert-True ($null -eq $env:ORC_CODE -and $null -eq $env:GST_DEBUG) 'the probes restore the environment'
        }
    }
}

Describe 'onnxinference wiring' {
    It 'the patch applies fatally and converts the path only on Windows' {
        $patch = Get-TestRepoText 'windows\scripts\patches\gstreamer\003-onnxinference-wide-model-path.patch'
        foreach ($needle in '#ifdef G_OS_WIN32', 'g_utf8_to_utf16', '(const ORTCHAR_T *) model_file_w') { Assert-True ($patch.Contains($needle)) "the patch carries $needle" }
        Assert-Match 'Invoke-RequiredSourcePatch [^\r\n]*003-onnxinference-wide-model-path\.patch' (Get-TestRepoText 'windows\scripts\build\Build-GstreamerFromSource.ps1') 'a patch that stops applying fails the build'
    }

    It 'both gates run real frames' {
        foreach ($gate in 'Test-Container.ps1', 'Test-Arm64Bundle.ps1') {
            Assert-True ((Get-TestRepoText "windows\scripts\build\$gate").Contains('Assert-GstOnnxInferenceRun')) "$gate runs the model"
        }
    }
}
