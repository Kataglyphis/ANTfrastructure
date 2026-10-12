#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# CON91: the Windows CI drivers name no Python; an empty -PythonVersion takes the pin, so an upgrade moves them too.

Describe 'Invoke-CiPackaging and Invoke-CiStaticAnalysis: the pinned Python by default (CON91)' {

    $repoRoot = Get-RepoRoot
    foreach ($name in 'Invoke-CiPackaging.ps1', 'Invoke-CiStaticAnalysis.ps1') {
        $driver = Join-Path $repoRoot "windows\scripts\python\$name"
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$parseErrors)
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PythonVersion' })
        $init = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-CiEnvironment' }, $true)) | Select-Object -First 1
        $modules = @(if ($init) { $init.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ArrayExpressionAst] } | ForEach-Object { $_.SafeGetValue() } })

        It "$name defaults -PythonVersion to '' and fills it from Get-PinnedPythonVersion" {
            Assert-Equal 0 @($parseErrors).Count 'the driver parses'
            Assert-Equal 1 $param.Count 'one -PythonVersion'
            Assert-Equal "''" $param[0].DefaultValue.Extent.Text 'no version literal'
            Assert-Match '(?m)^if \(-not \$PythonVersion\) \{ \$PythonVersion = \(Get-PinnedPythonVersion\)\.MajorMinor \}' $ast.Extent.Text 'the pin fills an empty value'
        }

        It "$name loads a module list that resolves Get-PinnedPythonVersion in a cold session" {
            Assert-True ($modules -contains 'WindowsPythonWheel.Common') "Initialize-CiEnvironment -Modules: $($modules -join ', ')"
            $paths = ($modules | ForEach-Object { "'$(Join-Path $repoRoot "windows\scripts\modules\$_.psm1")'" }) -join ','
            $out = & pwsh -NoProfile -NonInteractive -Command "foreach (`$m in @($paths)) { Import-Module `$m -DisableNameChecking }; (Get-Command Get-PinnedPythonVersion -ErrorAction Stop).Source" 2>&1
            Assert-Equal 0 $LASTEXITCODE "cold import: $out"
            Assert-Equal 'WindowsPythonWheel.Common' "$out".Trim() 'the helper comes from the wheel module'
        }
    }
}
