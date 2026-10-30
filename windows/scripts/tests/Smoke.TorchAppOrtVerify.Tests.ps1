#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The mutation recipes' cases, apart from Smoke.TorchAppOrt.Tests.ps1, whose Windows-path cases fail on the Linux shards.

Import-Module (Join-Path $PSScriptRoot 'WindowsSmoke.TorchAppFixture.psm1') -DisableNameChecking

function script:Assert-RepoFileMatch {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    Assert-Match $Pattern ([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $Path))) $Message
}

Describe 'Smoke §21: the app verify and its census in Test-Container.ps1' {
    $venvBranch = Get-TorchAppVenvBranch
    $venvText = $venvBranch[0].Clauses[0].Item2.Extent.Text

    It 'the app verify must print the ORT census PASS line, and its FAIL lines are the message (mutation)' {
        $rhsOf = { param($name) [regex]::Match($venvText, '(?m)^\s*\$' + $name + ' = (.+?)\r?$').Groups[1].Value }
        Assert-Match '-File \$torchAppScript -AppDir \$torchAppDir -OrtCensusPath "\$torchAppCensus" -Mode verify 2>&1 \| Out-String$' (& $rhsOf 'torchAppVerify') 'the verify output is kept'
        $verdict = [scriptblock]::Create("param(`$torchAppVerify) $(& $rhsOf 'torchAppVerifyOk')")
        $fails = [scriptblock]::Create("param(`$torchAppVerify) $(& $rhsOf 'torchAppCensusFails')")
        $ok = "torch-app-env OK`r`nORT-CENSUS PASS: 2 chain distribution(s) from C:\runtime\wheels`r`n"
        $global:LASTEXITCODE = 0
        Assert-True (& $verdict $ok) 'imports and census both pass'
        Assert-False (& $verdict "torch-app-env OK`r`n") 'a verify without the census line fails'
        Assert-False (& $verdict "torch-app-env OK`r`nnoise ORT-CENSUS PASS`r`n") 'PASS must start its line'
        Assert-False (& $verdict "ORT-CENSUS PASS: 1`r`n") 'the census alone is not the verify'
        $global:LASTEXITCODE = 1
        Assert-False (& $verdict $ok) 'a non-zero exit fails'
        $global:LASTEXITCODE = 0
        $out = "ORT-CENSUS FAIL onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel`r`nORT-CENSUS FAIL two owners`r`nORT-CENSUS FAILED: 2`r`n"
        Assert-Equal 'onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel|two owners' (@(& $fails $out) -join '|') 'each finding, without its CR'
        $verifyAssert = @([regex]::Matches($venvText, '(?s)Assert-Test -Name "torch-app venv verifies.+?-FailMessage "[^\r\n]*'))
        Assert-Equal 1 $verifyAssert.Count 'one app-verify assertion'
        Assert-Match '-Condition \{ \$torchAppVerifyOk \}' $verifyAssert[0].Value 'its condition is the verdict above'
        Assert-Match '-FailMessage "[^"]*\$torchAppEvidence' $verifyAssert[0].Value 'its message carries the evidence'
        $evidence = [scriptblock]::Create("param(`$torchAppCensusFails, `$torchAppVerify) $(& $rhsOf 'torchAppEvidence')")
        Assert-Equal 'a|b' (@(& $evidence @('a', 'b') "x`r`n") -join '|') 'census findings win'
        Assert-Equal 'two|three|four' (@(& $evidence @() "one`r`ntwo`r`n`r`nthree`r`nfour`r`n") -join '|') 'otherwise the last three nonblank lines'
    }

    It 'hands the verifier the image census, which the windows/scripts mount lacks (mutation)' {
        Assert-Match "(?m)^\s*\`$torchAppCensus = Resolve-SmokeCompanion -ScriptRoot \`$PSScriptRoot -Name 'ort-venv-census.py'\r?$" $venvText 'resolved like the other companions'
        Assert-RepoFileMatch -Path 'windows\Dockerfile.torch' -Pattern '(?m)^COPY linux\\scripts\\03-media\\runtime\\ort-venv-census\.py C:\\temp\\scripts\\' -Message 'the image bakes it where the resolver falls back'
        Assert-False (Test-Path (Join-Path (Get-RepoRoot) 'windows\scripts\build\ort-venv-census.py')) 'the mount has no copy, so the fallback is load-bearing'
    }

    It 'compares against the store Build-TorchApp.ps1 installed the venv from' {
        Assert-Match "Resolve-ChainOrtWheel -WheelDir \`$\(if \(\`$env:PYTHON_WHEELS\) \{ \`$env:PYTHON_WHEELS \} else \{ 'C:\\runtime\\wheels' \}\)" $venvText 'PYTHON_WHEELS, else the default'
        Assert-RepoFileMatch -Path 'windows\scripts\build\Build-TorchApp.ps1' -Pattern "\[string\]\`$WheelDir = 'C:\\runtime\\wheels'" -Message 'Build-TorchApp.ps1 installs from the same store'
        Assert-RepoFileMatch -Path 'windows\Dockerfile.media-merge-builder' -Pattern 'PYTHON_WHEELS="C:\\runtime\\wheels"' -Message 'and the image names it PYTHON_WHEELS'
    }
}
