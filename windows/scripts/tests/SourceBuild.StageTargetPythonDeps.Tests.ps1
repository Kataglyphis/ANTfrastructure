#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Copy-TargetPythonDeps.ps1 is the arm64 cross lane's Python dependency
# gate: every Requires-Dist of every staged wheel must resolve to a wheel in
# the store, and a drop in wheel or requirement count is a hard failure (the
# run-34/35 defect class: empty Requires-Dist from a CRLF regex bug made the
# gate greener, not red).
#
# The helpers (Get-WheelDistName, Get-RequirementName, Get-WheelRequirements)
# live inside the script body, not a module, so they are lifted via
# Get-ScriptFunctionDefinition.

Describe 'stage-target-python-deps: wheel requirement parsing' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Copy-TargetPythonDeps.ps1' `
                -FunctionName 'Get-WheelDistName', 'Get-RequirementName', 'Get-WheelRequirements')

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('stagedeps-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null

        # Builds a minimal .whl ZIP with a dist-info/METADATA containing the
        # given Requires-Dist lines (and a body after a blank line).
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

    # ── Get-WheelDistName ─────────────────────────────────────────────────────

    It 'Get-WheelDistName extracts the distribution name from a PEP 427 filename' {
        Assert-Equal 'onnxruntime' (Get-WheelDistName 'onnxruntime-1.22.0-cp314-cp314-win_amd64.whl') 'simple name'
        Assert-Equal 'onnxruntime-genai' (Get-WheelDistName 'onnxruntime_genai-0.7.0-cp314-cp314-win_arm64.whl') 'underscore normalised to dash'
        Assert-Equal 'apache-tvm-ffi' (Get-WheelDistName 'apache_tvm_ffi-0.1.13.post2-cp314-cp314-win_arm64.whl') 'multi-underscore normalised'
    }

    It 'Get-WheelDistName normalises dots and underscores to dashes' {
        Assert-Equal 'foo-bar' (Get-WheelDistName 'foo.bar-1.0-py3-none-any.whl') 'dot to dash'
        Assert-Equal 'foo-bar' (Get-WheelDistName 'foo_bar-1.0-py3-none-any.whl') 'underscore to dash'
    }

    # ── Get-RequirementName ───────────────────────────────────────────────────

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

    # ── Get-WheelRequirements ──────────────────────────────────────────────────

    It 'Get-WheelRequirements reads Requires-Dist lines from a wheel METADATA' {
        $p = Join-Path $script:tmp 'test-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'test' -RequiresDist @('numpy>=1.21', 'packaging', 'typing_extensions>=4.5')
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 3 $reqs.Count 'three requirements'
        Assert-True ($reqs -contains 'numpy>=1.21') 'numpy present'
        Assert-True ($reqs -contains 'packaging') 'packaging present'
        Assert-True ($reqs -contains 'typing_extensions>=4.5') 'typing_extensions present'
    }

    It 'Get-WheelRequirements drops extras (extra == markers) — optional deps are not first-touch' {
        $p = Join-Path $script:tmp 'extras-1.0.0-py3-none-any.whl'
        & $script:NewWheel -Path $p -Name 'extras' -RequiresDist @('numpy>=1.21', 'torch ; extra == "gpu"', 'pytest ; extra == "dev"')
        $reqs = @(Get-WheelRequirements $p)
        Assert-Equal 1 $reqs.Count 'only the non-extra requirement'
        Assert-Equal 'numpy>=1.21' $reqs[0] 'numpy is the first-touch dep'
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
