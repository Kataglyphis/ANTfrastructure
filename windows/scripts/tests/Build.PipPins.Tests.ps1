#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# CON89: a floating pip install in the chain builds differently every day, and any new release runs code in the build.

Describe 'Get-PipPin and the chain''s pip installs (CON89)' {

    It 'turns each name into name==its PY_<NAME>_VERSION pin, dashes and dots folded, and refuses an unpinned one' {
        Invoke-WithEnv @{ PY_SCIKIT_BUILD_CORE_VERSION = '9.8.7'; PY_TYPING_EXTENSIONS_VERSION = '1.2'; PY_WBT_ABSENT_VERSION = $null } {
            Assert-Equal 'scikit-build-core==9.8.7|typing_extensions==1.2' ((Get-PipPin scikit-build-core, typing_extensions) -join '|') 'two pins'
            Assert-Throws { Get-PipPin wbt.absent } -MessagePattern 'PY_WBT_ABSENT_VERSION is not set: refusing a floating pip install of wbt\.absent'
        }
    }

    It 'every package an Invoke-CpythonPip install names carries a version, and every PY_ pin it needs exists (mutation)' {
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $bare = [System.Collections.Generic.List[string]]::new()
        $pinned = [System.Collections.Generic.List[string]]::new()
        $unpinnedDeps = [System.Collections.Generic.List[string]]::new()
        # A branch without the dependency yet resolves it to the newest release, and the media merge refuses mixed versions.
        $toolDeps = @{ 'scikit-build-core' = 'packaging'; 'setuptools-scm' = 'packaging'; 'wheel' = 'packaging' }
        foreach ($script in Get-Item -Path (Join-Path (Get-RepoRoot) 'windows\scripts\build\*.ps1')) {
            $ast = Get-TestScriptAst -ScriptPath $script.FullName
            foreach ($call in Get-TestAstCommands -Ast $ast -Name 'Invoke-CpythonPip') {
                $arguments = (Get-TestCommandArguments -Command $call -AsAst).Arguments
                $consts = @($arguments.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord' }, $true) | ForEach-Object Value)
                if ($consts.Count -eq 0 -or $consts[0] -cne 'install') { continue }
                foreach ($c in @($consts | Select-Object -Skip 1)) {
                    if ($c -match '^[A-Za-z][A-Za-z0-9_.-]*$') { $bare.Add("$($script.Name):$($call.Extent.StartLineNumber) $c") }
                }
            }
            foreach ($install in Get-TestAstCommands -Ast $ast -Name 'Install-CpythonPipPin') {
                $names = (Get-TestCommandArguments -Command $install -AsAst).Name
                $callNames = @($names.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
                foreach ($name in $callNames) {
                    $pinned.Add($name)
                    foreach ($dep in @($toolDeps[$name])) {
                        if ($dep -and $dep -cnotin $callNames) { $unpinnedDeps.Add("$($script.Name):$($install.Extent.StartLineNumber) $name needs $dep") }
                    }
                }
            }
        }
        Assert-Equal '' ($bare -join '; ') 'install names a bare package; install it through Install-CpythonPipPin'
        Assert-Equal '' ($unpinnedDeps -join '; ') 'a build tool''s dependency floats; pin it in the same Install-CpythonPipPin call'
        Assert-True ($pinned.Count -ge 10) "the scan sees the Install-CpythonPipPin calls ($($pinned.Count))"
        foreach ($name in $pinned | Sort-Object -Unique) {
            $key = 'PY_{0}_VERSION' -f ($name.ToUpperInvariant() -replace '[-.]', '_')
            Assert-True ($pins.Contains($key)) "$key in versions.env for $name"
        }
    }
}
