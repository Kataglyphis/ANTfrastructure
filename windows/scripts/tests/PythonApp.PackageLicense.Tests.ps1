#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Checks package-verifier wiring; native WiX, ZIP and MSIX builders are exercised by the image lane.

Describe 'Python application package license checks' {
    It 'checks the project and optional ONNX texts before the start test' {
        $path = 'windows/scripts/python/New-PythonAppPackage.ps1'
        $ast = Get-TestScriptAst -ScriptPath $path
        Assert-Equal 1 @(Get-TestAstCommands -Ast $ast -Name 'Resolve-PythonOrtLicenses').Count
        foreach ($case in @(
            @{ Function = 'Invoke-ZipPackage'; Pattern = '"$stem/LICENSE"'; Build = 'tar.exe'; Artifact = '$zip'; Ort = 'Assert-PythonAppArchiveLicenses -Path $zip -ArchivePrefix $stem' },
            @{ Function = 'Invoke-MsiAppPackage'; Pattern = '$licenseId'; Build = '$wix build'; Artifact = '$msi'; Ort = 'if ($ortLicenses) { Assert-OrtWheelLicensesInPackage -Path $msi -LicenseDirectory $ortLicenses -Format msi -WixPath $wxs }' },
            @{ Function = 'Invoke-MsixAppPackage'; Pattern = "'LICENSE'"; Build = "'makeappx.exe'"; Artifact = '$msix'; Ort = 'Assert-PythonAppArchiveLicenses -Path $msix' }
        )) {
            $body = (Get-ScriptFunctionDefinition -ScriptPath $path -FunctionName $case.Function).ToString()
            $check = 'Assert-PackageLicense -Path ' + $case.Artifact + ' -Pattern ' + $case.Pattern + ' -LicensePath $licensePath'
            Assert-True ($body.Contains($check)) "$($case.Function) checks the project license"
            Assert-True ($body.IndexOf($case.Build) -lt $body.IndexOf($check)) "$($case.Function) checks after building"
            Assert-True ($body.IndexOf($check) -lt $body.IndexOf('if (-not $test)')) "$($case.Function) checks even with SkipTest"
            Assert-True ($body.Contains($case.Ort)) "$($case.Function) checks optional ONNX Runtime texts"
            Assert-True ($body.IndexOf($case.Ort) -lt $body.IndexOf('if (-not $test)')) "$($case.Function) checks ORT even with SkipTest"
        }
        $msi = (Get-ScriptFunctionDefinition -ScriptPath $path -FunctionName 'Invoke-MsiAppPackage').ToString()
        Assert-True ($msi.Contains("Get-WixSourceFileId -WixPath `$wxs -SourcePath (Join-Path `$Bundle 'LICENSE')")) 'MSI maps this bundle license dynamically'
        $archive = (Get-ScriptFunctionDefinition -ScriptPath $path -FunctionName 'Assert-PythonAppArchiveLicenses').ToString()
        foreach ($required in @('if ($ortLicenses)',
                'Assert-OrtWheelLicensesInPackage -Path $Path -LicenseDirectory $ortLicenses -Format archive -ArchivePrefix $ArchivePrefix',
                "-ArchiveDirectory 'runtime/Lib/site-packages/onnxruntime'")) {
            Assert-True ($archive.Contains($required)) "archive check needs $required"
        }
    }
}
