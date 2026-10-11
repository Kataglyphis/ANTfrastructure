#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The helpers live in the script body, not a module, so they are lifted via Get-ScriptFunctionDefinition.

Describe 'stage-target-python-deps: wheel requirement parsing' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Copy-TargetPythonDeps.ps1' `
                -FunctionName 'Get-WheelDistName', 'Get-RequirementName', 'Get-WheelRequirements', 'ConvertTo-CmdSafeRequirement')

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('stagedeps-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null

        # The description after the blank line checks that parsing stops at the headers.
        $script:NewWheel = {
            param([string]$Path, [string]$Name, [string[]]$RequiresDist, [string]$RequiresPython = '>=3.9')
            $distInfo = "$Name.dist-info"
            $meta = "Metadata-Version: 2.1`nName: $Name`nVersion: 1.0.0`nRequires-Python: $RequiresPython`n"
            foreach ($r in $RequiresDist) { $meta += "Requires-Dist: $r`n" }
            $meta += "`nDescription goes here.`n"
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            try {
                $entry = $zip.CreateEntry("$distInfo/METADATA")
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write($meta) } finally { $writer.Dispose() }
            } finally { $zip.Dispose() }
        }
    }

    AfterAll {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Get-WheelDistName

    It 'Get-WheelDistName extracts the distribution name from a PEP 427 filename' {
        Assert-Equal 'onnxruntime' (Get-WheelDistName 'onnxruntime-1.22.0-cp314-cp314-win_amd64.whl') 'simple name'
        Assert-Equal 'onnxruntime-genai' (Get-WheelDistName 'onnxruntime_genai-0.7.0-cp314-cp314-win_arm64.whl') 'underscore normalised to dash'
        Assert-Equal 'apache-tvm-ffi' (Get-WheelDistName 'apache_tvm_ffi-0.1.13.post2-cp314-cp314-win_arm64.whl') 'multi-underscore normalised'
    }

    It 'Get-WheelDistName normalises dots and underscores to dashes' {
        Assert-Equal 'foo-bar' (Get-WheelDistName 'foo.bar-1.0-py3-none-any.whl') 'dot to dash'
        Assert-Equal 'foo-bar' (Get-WheelDistName 'foo_bar-1.0-py3-none-any.whl') 'underscore to dash'
    }

    # Get-RequirementName

    It 'Get-RequirementName extracts the canonical name from a requirement string' {
        Assert-Equal 'numpy' (Get-RequirementName 'numpy>=1.21.6') 'with version bound'
        Assert-Equal 'numpy' (Get-RequirementName 'numpy') 'bare name'
        Assert-Equal 'protobuf' (Get-RequirementName 'protobuf (>=3.20)') 'with parenthesised version'
        Assert-Equal 'coloredlogs' (Get-RequirementName 'coloredlogs') 'single word'
    }

    It 'Get-RequirementName normalises separators to dashes' {
        Assert-Equal 'typing-extensions' (Get-RequirementName 'typing_extensions>=4.5') 'underscore to dash'
        Assert-Equal 'apache-tvm-ffi' (Get-RequirementName 'apache_tvm_ffi>=0.1.13') 'multi-underscore'
    }

    It 'Get-RequirementName returns null for an unparseable string' {
        Assert-Null (Get-RequirementName '; extra == "x"') 'marker-only requirement'
        Assert-Null (Get-RequirementName '') 'empty string'
    }

    # Get-WheelRequirements

    It 'Get-WheelRequirements reads Requires-Dist lines from a wheel METADATA' {
        $p = Join-Path $script:tmp 'test-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'test' -RequiresDist @('numpy>=1.21', 'packaging', 'typing_extensions>=4.5', 'my-extra==1.0')
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 4 $reqs.Count 'four requirements'
        Assert-True ($reqs -contains 'numpy>=1.21') 'numpy present'
        Assert-True ($reqs -contains 'packaging') 'packaging present'
        Assert-True ($reqs -contains 'typing_extensions>=4.5') 'typing_extensions present'
        Assert-True ($reqs -contains 'my-extra==1.0') 'a name containing "extra" is not a marker'
    }

    It 'Get-WheelRequirements drops extras (extra == markers) — optional deps are not first-touch' {
        $p = Join-Path $script:tmp 'extras-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'extras' -RequiresDist @('numpy>=1.21', 'torch ; extra == "gpu"', 'pytest ; extra == "dev"',
                "backports-zstd; (python_version < '3.14') and extra == 'test-full'", 'pytest-perf; sys_platform != "cygwin" and extra == "test"')
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 1 $reqs.Count 'only the non-extra requirement, however the marker is compounded'
        Assert-Equal 'numpy>=1.21' $reqs[0] 'numpy is the first-touch dep'
    }

    It 'ConvertTo-CmdSafeRequirement single-quotes markers so cmd.exe keeps them' {
        Assert-Equal "pytest-perf; sys_platform != 'cygwin' and extra == 'test'" (ConvertTo-CmdSafeRequirement 'pytest-perf; sys_platform != "cygwin" and extra == "test"') 'double quotes become single'
        Assert-Equal 'numpy>=1.21' (ConvertTo-CmdSafeRequirement 'numpy>=1.21') 'a plain requirement is untouched'
    }

    It 'Get-WheelRequirements stops at the first blank line (description is not parsed)' {
        $p = Join-Path $script:tmp 'blank-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'blank' -RequiresDist @('numpy>=1.21')
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 1 $reqs.Count 'only the header requirement, not the description'
    }

    It 'Get-WheelRequirements returns an empty array for a wheel with no Requires-Dist' {
        $p = Join-Path $script:tmp 'bare-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'bare' -RequiresDist @()
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 0 $reqs.Count 'no requirements'
    }

    It 'Get-WheelRequirements throws on a wheel with no dist-info/METADATA' {
        $p = Join-Path $script:tmp 'bad-1.0.0-py3-none-any.whl'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($p, 'Create')
        $zip.CreateEntry('wrong.txt') | Out-Null
        $zip.Dispose()
        $threw = $false
        try { Get-WheelRequirements $p | Out-Null } catch { $threw = $true }
        Assert-True $threw 'missing METADATA throws, not silently empty'
    }
}

BeforeDiscovery {
    # The markers are evaluated by pip's vendored packaging, so these cases need a host Python that carries pip.
    $script:hostPy = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($script:hostPy) { & $script:hostPy -c 'import pip._vendor.packaging.requirements' 2>$null; if ($LASTEXITCODE -ne 0) { $script:hostPy = $null } }
}

Describe 'stage-target-python-deps: requirement markers decide for the target' -Skip:(-not $script:hostPy) {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Copy-TargetPythonDeps.ps1' -FunctionName 'Select-ActiveRequirement')
        $script:py = Get-Command python | Select-Object -First 1 -ExpandProperty Source
        # The active requirements for one target, joined so a whole verdict is one comparison.
        function script:Get-ActiveJoined([string]$Version, [string]$Machine, [string[]]$Reqs) {
            @(Select-ActiveRequirement -PythonExe $script:py -PythonVersion $Version -PlatformMachine $Machine -Requirement $Reqs) -join '|'
        }
    }

    It 'drops a python_version < 3.11 requirement for a 3.14 target and keeps it for 3.10 (pytest 9.1.1, 2026-10-10)' {
        $reqs = @('pluggy<2,>=1.5', 'exceptiongroup>=1; python_version < "3.11"', 'tomli>=1; python_version < "3.11"')
        Assert-Equal 'pluggy<2,>=1.5' (Get-ActiveJoined '3.14' 'ARM64' $reqs) 'only the unmarked requirement is active on 3.14'
        Assert-Equal ($reqs -join '|') (Get-ActiveJoined '3.10' 'ARM64' $reqs) 'all three are active on 3.10'
    }

    It 'evaluates sys_platform and platform_machine for a Windows target' {
        $reqs = @('colorama; sys_platform == "win32"', 'uvloop; sys_platform != "win32"', 'armonly; platform_machine == "ARM64"')
        Assert-Equal "$($reqs[0])|$($reqs[2])" (Get-ActiveJoined '3.14' 'ARM64' $reqs) 'win32 and ARM64 hold on win_arm64'
        Assert-Equal $reqs[0] (Get-ActiveJoined '3.14' 'AMD64' $reqs) 'the ARM64-only requirement drops on win_amd64'
    }

    It 'returns unmarked requirements without starting Python, and throws on a marker it cannot evaluate' {
        $active = @(Select-ActiveRequirement -PythonExe 'C:\no-such\python.exe' -PythonVersion '3.14' -PlatformMachine 'ARM64' -Requirement @('numpy', 'protobuf>=4'))
        Assert-Equal 'numpy|protobuf>=4' ($active -join '|') 'no marker, no Python'
        Assert-Throws { Select-ActiveRequirement -PythonExe $script:py -PythonVersion '3.14' -PlatformMachine 'ARM64' -Requirement @('foo; not a marker') } `
            -MessagePattern 'could not evaluate the markers'
    }
}

Describe 'stage-target-python-deps: the cp3XYt twins'' dependencies (CON79)' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Copy-TargetPythonDeps.ps1' -FunctionName 'Get-WheelDistName', 'Get-RequirementName',
            'Get-WheelRequirements', 'Select-ActiveRequirement', 'Get-TargetRequirement', 'Get-UnresolvedTargetRequirement', 'Get-ForeignAbiWheel')
        $script:depsScript = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\build\Copy-TargetPythonDeps.ps1')
        # A wheel of METADATA alone, which is all the requirement walk reads.
        function script:New-MetadataWheel([string]$Dir, [string]$FileName, [string[]]$RequiresDist) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Dir $FileName), 'Create')
            try {
                $writer = New-Object System.IO.StreamWriter($zip.CreateEntry("$($FileName.Split('-')[0]).dist-info/METADATA").Open())
                try { $writer.Write("Metadata-Version: 2.1`nName: x`nVersion: 1.0`n" + (@($RequiresDist | ForEach-Object { "Requires-Dist: $_`n" }) -join '') + "`n") } finally { $writer.Dispose() }
            } finally { $zip.Dispose() }
        }
    }

    It 'names each requirement edge no wheel of the store resolves' {
        Invoke-InTestDir { param($d)
            New-MetadataWheel $d 'foo-1.0-py3-none-any.whl' @('bar', 'baz>=1')
            New-MetadataWheel $d 'bar-1.0-py3-none-any.whl' @()
            $edges = @(Get-UnresolvedTargetRequirement -Wheel @(Get-ChildItem -LiteralPath $d -Filter '*.whl') -TargetTag 'win_arm64' -PythonExe 'C:\no-such\python.exe' -PythonVersion '3.14' -Machine 'ARM64')
            Assert-Equal 'foo-1.0-py3-none-any.whl -> baz>=1' ($edges -join '|') 'bar is in the store, baz is not'
        }
    }

    It 'refuses a wheel that is neither pure nor tagged for the target' {
        Invoke-InTestDir { param($d)
            New-MetadataWheel $d 'qux-1.0-cp314-cp314-win_amd64.whl' @()
            Assert-Throws { Get-UnresolvedTargetRequirement -Wheel @(Get-ChildItem -LiteralPath $d -Filter '*.whl') -TargetTag 'win_arm64' -PythonExe 'C:\no-such\python.exe' -PythonVersion '3.14' -Machine 'ARM64' } `
                -MessagePattern 'qux-1\.0-cp314-cp314-win_amd64\.whl is neither a pure wheel'
        }
    }

    It 'lets a cp3XYt or ABI-free wheel into deps\ and names a GIL or abi3 one' {
        Invoke-InTestDir { param($d)
            $names = 'numpy-2.5.4-cp314-cp314t-win_arm64.whl', 'protobuf-7.36.2-py3-none-any.whl', 'numpy-2.5.3-cp314-cp314-win_arm64.whl', 'iree_base_runtime-3.12.0-cp312-abi3-win_arm64.whl'
            $foreign = @(Get-ForeignAbiWheel -Wheel @($names | Sort-Object | ForEach-Object { New-Item -ItemType File -Path (Join-Path $d $_) }) -Abi 'cp314t')
            Assert-Equal 'iree_base_runtime-3.12.0-cp312-abi3-win_arm64.whl|numpy-2.5.3-cp314-cp314-win_arm64.whl' ($foreign -join '|') 'a free-threaded venv loads neither'
        }
    }

    It 'downloads the twins'' requirements without abi3 into deps\, then gates twins and deps as one store' {
        Assert-Match "Join-Path \`$FreeThreadedWheelDir 'deps'" $script:depsScript 'the twins'' store keeps its top for twins'
        Assert-Match "Save-TargetRequirement -Requirement \`$ftRequirements -Dir \`$ftDepsDir -Abi @\(\`$ftAbi, 'none'\)" $script:depsScript 'no abi3: the free-threaded ABI has no limited API'
        Assert-Match "Get-UnresolvedTargetRequirement -Wheel \(@\(\`$twins\) \+ @\(\`$ftDeps\)\)" $script:depsScript 'every edge resolves inside the two directories'
    }
}
